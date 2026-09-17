#!/usr/bin/env bash
# Tile a single piece of artwork (PNG, JPEG, or SVG -- raster or vector, any
# native size/unit) across a page as a grid of copies, sized to fit as many
# as possible.
#
# Works on macOS and Omarchy: only assumes `inkscape`, `base64`, `awk`, and
# `sed` (`pacman -S inkscape` on Omarchy, `brew install --cask inkscape` on
# macOS; base64/awk/sed ship with both).
#
# Pipeline:
#   1. measure    : open SRC, group everything into one object, query its
#                   natural size (Inkscape's query/export actions always
#                   operate in real physical pixels at 96/inch, regardless
#                   of the source's own declared units -- confirmed
#                   empirically -- so this works the same for a raw PNG, a
#                   plain vector SVG, or an SVG with an embedded image).
#   2. rasterize  : rotate 90deg if the artwork is wider than tall (packs
#                   tighter on a portrait page), then export it to a PNG at
#                   the exact target print size, at DPI resolution.
#   3. assemble   : compute the grid from that size and author the output
#                   page directly as SVG text -- one <image> in <defs>,
#                   one <use> per grid cell. No further SVG surgery, so
#                   none of the viewBox/unit/transform-anchor pitfalls that
#                   come with editing arbitrary source SVGs in place.
#   4. (if -o is .pdf) convert the assembled SVG to PDF.
set -euo pipefail

export LC_ALL=C
PX_PER_MM=3.7795275591 # Inkscape query/export actions' fixed 96dpi convention

INKSCAPE="${INKSCAPE:-inkscape}"
if ! command -v "$INKSCAPE" >/dev/null 2>&1 && [[ -x "/Applications/Inkscape.app/Contents/MacOS/inkscape" ]]; then
  INKSCAPE="/Applications/Inkscape.app/Contents/MacOS/inkscape"
fi
command -v "$INKSCAPE" >/dev/null 2>&1 || { echo "error: inkscape not found (set INKSCAPE=/path/to/inkscape)" >&2; exit 1; }

# Defaults favor tight packing but leave a visible cut line between tiles
# and a safe, printable margin around the page edge.
MARGIN=8
GAP=2
PAGE="a4"      # "a4" | "letter"
BORDER=0       # 1 = add a solid white perimeter + outline around each tile
WHITE_W=3      # white perimeter thickness, mm, only used with BORDER
BLACK_W=0.3    # outline thickness, mm, only used with BORDER
OUTLINE_COLOR="#cccccc" # outline color, only used with BORDER
WIDTH=""       # target width of each tile, mm (preserves aspect ratio); "" = natural size, capped to MAXWIDTH
MAXWIDTH=152.4 # 6in -- cap applied only when -w isn't given; artwork is only ever scaled down, never up
ROTATE=auto    # auto | yes | no -- auto rotates landscape artwork 90deg to pack tighter
DPI=300        # print resolution for the rasterized tile
SRC=""
OUT=""

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") -i SRC -o OUT [options]

  -i SRC     source image: PNG/JPEG, or SVG (vector or with one embedded image)
  -o OUT     output path -- .pdf or .svg, chosen by OUT's extension
  -p PAGE    page size: 'a4' (210x297mm) or 'letter' (215.9x279.4mm) (default: $PAGE)
  -w WIDTH   scale each tile to this rendered width, mm (default: natural size, capped to -x)
  -x MAXWIDTH  cap on natural size when -w isn't given, mm (default: $MAXWIDTH = 6in; never enlarges)
  -m MARGIN  outer page margin, mm (default: $MARGIN)
  -g GAP     spacing between tiles, mm (default: $GAP; 0 packs edge to edge)
  -r MODE    rotate landscape artwork 90deg to pack tighter: auto|yes|no (default: $ROTATE)
  -s         add a solid white perimeter + outline around each tile (default: off)
  -b WHITE_W white perimeter thickness, mm, only used with -s (default: $WHITE_W)
  -k BLACK_W outline thickness, mm, only used with -s (default: $BLACK_W)
  -c COLOR   outline color, only used with -s (default: $OUTLINE_COLOR)
  -d DPI     rasterization resolution (default: $DPI)
EOF
  exit 1
}

while getopts "i:o:p:w:x:m:g:r:b:k:c:d:sh" opt; do
  case "$opt" in
    i) SRC="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    p) PAGE="$OPTARG" ;;
    w) WIDTH="$OPTARG" ;;
    x) MAXWIDTH="$OPTARG" ;;
    m) MARGIN="$OPTARG" ;;
    g) GAP="$OPTARG" ;;
    r) ROTATE="$OPTARG" ;;
    s) BORDER=1 ;;
    b) WHITE_W="$OPTARG" ;;
    k) BLACK_W="$OPTARG" ;;
    c) OUTLINE_COLOR="$OPTARG" ;;
    d) DPI="$OPTARG" ;;
    *) usage ;;
  esac
done

[[ -z "$SRC" || -z "$OUT" ]] && usage
[[ -f "$SRC" ]] || { echo "error: source not found: $SRC" >&2; exit 1; }

case "$PAGE" in
  a4)     PAGE_W=210;   PAGE_H=297 ;;
  letter) PAGE_W=215.9; PAGE_H=279.4 ;;
  *)      echo "error: -p must be 'a4' or 'letter', got: $PAGE" >&2; exit 1 ;;
esac
case "$ROTATE" in auto|yes|no) ;; *) echo "error: -r must be auto|yes|no, got: $ROTATE" >&2; exit 1 ;; esac

mm() { awk -v px="$1" -v k="$PX_PER_MM" 'BEGIN{printf "%.6f", px/k}'; }

mkdir -p "$(dirname "$OUT")"
# A scratch dir with fixed filenames inside it, rather than a suffixed
# mktemp template: BSD/macOS mktemp only substitutes a trailing run of X's,
# so a template like "file.XXXXXX.png" silently returns the literal path
# unchanged on macOS (GNU mktemp supports a suffix; BSD doesn't) -- and
# Inkscape, confusingly, needs the real ".png"/".svg" extension on the
# filename it's told to export to, or it silently writes an empty file.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
TILE_PNG="$SCRATCH/tile.png"

# --- Stage 1: measure ---------------------------------------------------
# Group everything in the source into one object and read its natural size.
read -r NAT_W0 NAT_H0 <<EOF
$("$INKSCAPE" "$SRC" --actions="select-all;selection-group;query-width;query-height" 2>/dev/null | tr '\n' ' ')
EOF
[[ -n "$NAT_W0" && -n "$NAT_H0" ]] || { echo "error: could not measure artwork in $SRC" >&2; exit 1; }
NAT_W0_MM=$(mm "$NAT_W0"); NAT_H0_MM=$(mm "$NAT_H0")

DO_ROTATE=0
case "$ROTATE" in
  yes) DO_ROTATE=1 ;;
  no)  DO_ROTATE=0 ;;
  auto) awk -v w="$NAT_W0_MM" -v h="$NAT_H0_MM" 'BEGIN{exit !(w>h)}' && DO_ROTATE=1 || DO_ROTATE=0 ;;
esac

# Target tile size: whichever natural axis ends up as the on-page width, so
# "-w 50" always means "50mm wide as printed" even if that axis started out
# as the artwork's natural height pre-rotation. With no explicit width, cap
# to MAXWIDTH and to the page's available height, so an odd aspect ratio
# (e.g. a very tall logo) can't produce a tile too big to fit the page.
if [[ "$DO_ROTATE" -eq 1 ]]; then BASIS_W_MM="$NAT_H0_MM"; BASIS_H_MM="$NAT_W0_MM"
else BASIS_W_MM="$NAT_W0_MM"; BASIS_H_MM="$NAT_H0_MM"; fi
if [[ -n "$WIDTH" ]]; then
  SCALE=$(awk -v w="$WIDTH" -v b="$BASIS_W_MM" 'BEGIN{printf "%.8f", w/b}')
else
  AVAIL_H=$(awk -v h="$PAGE_H" -v m="$MARGIN" 'BEGIN{printf "%.6f", h-2*m}')
  SCALE=$(awk -v mw="$MAXWIDTH" -v bw="$BASIS_W_MM" -v ah="$AVAIL_H" -v bh="$BASIS_H_MM" \
    'BEGIN{s=(bw>mw)?mw/bw:1; sh=(bh*s>ah)?ah/bh:1; printf "%.8f", (s<sh)?s:sh}')
fi
IMG_W=$(awk -v b="$BASIS_W_MM" -v s="$SCALE" 'BEGIN{printf "%.6f", b*s}')
IMG_H=$(awk -v b="$BASIS_H_MM" -v s="$SCALE" 'BEGIN{printf "%.6f", b*s}')

# --- Stage 2: rasterize --------------------------------------------------
PX_W=$(awk -v mm="$IMG_W" -v d="$DPI" 'BEGIN{printf "%.0f", mm/25.4*d}')
PX_H=$(awk -v mm="$IMG_H" -v d="$DPI" 'BEGIN{printf "%.0f", mm/25.4*d}')

actions="select-all;selection-group;object-set-attribute:id,tileSource"
[[ "$DO_ROTATE" -eq 1 ]] && actions+=";object-rotate-90-cw"
actions+=";export-id:tileSource;export-id-only;export-type:png;export-width:${PX_W};export-height:${PX_H};export-filename:${TILE_PNG};export-do"
"$INKSCAPE" "$SRC" --actions="$actions" 2>/dev/null
[[ -s "$TILE_PNG" ]] || { echo "error: could not rasterize artwork from $SRC" >&2; exit 1; }

# The border filter (below) dilates outward from the artwork's own edge,
# past its declared width/height -- so grid spacing has to reserve that
# extra room on all sides, or neighboring tiles' borders overlap. Treat
# each tile as if it were BORDER_PAD bigger on every side for spacing
# purposes; the raw image is then inset by BORDER_PAD within that padded
# cell so the border has room to bleed into without touching the neighbor.
BORDER_PAD=0
[[ "$BORDER" -eq 1 ]] && BORDER_PAD=$(awk -v w="$WHITE_W" -v b="$BLACK_W" 'BEGIN{printf "%.6f", w+b}')

# --- Grid math: how many tiles fit, and the offset that centers the
# resulting block on the page. Kept isolated so it's easy to port (e.g. to
# JS for an in-browser version).
read -r COLS ROWS OFFSET_X OFFSET_Y <<EOF
$(awk -v pw="$PAGE_W" -v ph="$PAGE_H" -v iw="$IMG_W" -v ih="$IMG_H" -v m="$MARGIN" -v g="$GAP" -v pad="$BORDER_PAD" '
  BEGIN {
    ew = iw + 2*pad
    eh = ih + 2*pad
    avail_w = pw - 2*m
    avail_h = ph - 2*m
    cols = int((avail_w + g) / (ew + g))
    rows = int((avail_h + g) / (eh + g))
    if (cols < 1) cols = 1
    if (rows < 1) rows = 1
    grid_w = cols*ew + (cols-1)*g
    grid_h = rows*eh + (rows-1)*g
    ox = (pw - grid_w) / 2
    oy = (ph - grid_h) / 2
    printf "%d %d %.6f %.6f\n", cols, rows, ox, oy
  }')
EOF

TOTAL=$((COLS * ROWS))
echo "$(basename "$SRC"): ${IMG_W}x${IMG_H}mm$( [[ $DO_ROTATE -eq 1 ]] && echo " (rotated)" ) on ${PAGE_W}x${PAGE_H}mm page -> ${COLS}x${ROWS} grid (${TOTAL} tiles)" >&2

# --- Stage 3: assemble ---------------------------------------------------
# Author the output SVG directly: a clean mm-based page (no ambiguity about
# units or viewBox origin, since we're writing it, not editing someone
# else's), one embedded <image> template in <defs>, and one <use> per grid
# cell. <use> supports x/y natively for any referenced content, so no
# per-content-type special-casing is needed the way group/path positioning
# would need.
B64=$(base64 <"$TILE_PNG" | tr -d '\n')

FILTER_ID="stickerBorder"
FILTER_DEF=""
FILTER_ATTR=""
if [[ "$BORDER" -eq 1 ]]; then
  # Dilate the artwork's own alpha silhouette (not a bounding box) so the
  # border follows the actual cut shape and works the same whether the
  # source art already has its own white/black edge baked in (the ring
  # just adds outside it, further out) or is a flat shape with none (the
  # ring forms the whole border from scratch). Black is dilated further
  # than white and drawn first, so only the outer sliver between the two
  # radii shows -- a crisp outline around a solid white perimeter.
  R_WHITE="$WHITE_W"
  R_BLACK=$(awk -v w="$WHITE_W" -v b="$BLACK_W" 'BEGIN{printf "%.6f", w+b}')
  FILTER_DEF="<filter id=\"${FILTER_ID}\" x=\"-75%\" y=\"-75%\" width=\"250%\" height=\"250%\" color-interpolation-filters=\"sRGB\"><feMorphology in=\"SourceAlpha\" operator=\"dilate\" radius=\"${R_BLACK}\" result=\"dilated-outline\"/><feFlood flood-color=\"${OUTLINE_COLOR}\" flood-opacity=\"1\" result=\"outline-color\"/><feComposite in=\"outline-color\" in2=\"dilated-outline\" operator=\"in\" result=\"outline-ring\"/><feMorphology in=\"SourceAlpha\" operator=\"dilate\" radius=\"${R_WHITE}\" result=\"dilated-white\"/><feFlood flood-color=\"#ffffff\" flood-opacity=\"1\" result=\"white-color\"/><feComposite in=\"white-color\" in2=\"dilated-white\" operator=\"in\" result=\"white-ring\"/><feMerge><feMergeNode in=\"outline-ring\"/><feMergeNode in=\"white-ring\"/><feMergeNode in=\"SourceGraphic\"/></feMerge></filter>"
  FILTER_ATTR=" filter=\"url(#${FILTER_ID})\""
fi

USES=""
for ((r = 0; r < ROWS; r++)); do
  for ((c = 0; c < COLS; c++)); do
    # Cell pitch uses the padded (image + border bleed) size; the image
    # itself is placed BORDER_PAD in from the cell's top-left so the
    # border has that same margin free on every side to dilate into.
    x=$(awk -v ox="$OFFSET_X" -v c="$c" -v iw="$IMG_W" -v g="$GAP" -v pad="$BORDER_PAD" 'BEGIN{printf "%.6f", ox + c*(iw+2*pad+g) + pad}')
    y=$(awk -v oy="$OFFSET_Y" -v r="$r" -v ih="$IMG_H" -v g="$GAP" -v pad="$BORDER_PAD" 'BEGIN{printf "%.6f", oy + r*(ih+2*pad+g) + pad}')
    USES+="<use x=\"${x}\" y=\"${y}\" xlink:href=\"#tile\"${FILTER_ATTR}/>"
  done
done

ASSEMBLED="$SCRATCH/assembled.svg"
cat >"$ASSEMBLED" <<XML
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     width="${PAGE_W}mm" height="${PAGE_H}mm" viewBox="0 0 ${PAGE_W} ${PAGE_H}">
<defs>${FILTER_DEF}<image id="tile" width="${IMG_W}" height="${IMG_H}" preserveAspectRatio="none" xlink:href="data:image/png;base64,${B64}"/></defs>
${USES}
</svg>
XML

case "$OUT" in
  *.pdf) "$INKSCAPE" "$ASSEMBLED" --actions="export-area-page;export-filename:${OUT};export-type:pdf;export-do" 2>/dev/null ;;
  *)     cp "$ASSEMBLED" "$OUT" ;;
esac

echo "wrote $OUT" >&2
