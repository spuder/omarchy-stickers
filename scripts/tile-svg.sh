#!/usr/bin/env bash
# Tile a single piece of artwork (PNG, JPEG, or SVG -- raster or vector, any
# native size/unit) across a page as a grid of <use> clones, using Inkscape
# itself to do the SVG surgery (group, measure, scale, rotate, clone, place).
#
# Works on macOS and Omarchy: only assumes `inkscape` and `xmllint`/`awk`/`sed`,
# all standard package-manager installs (`pacman -S inkscape libxml2` on
# Omarchy, `brew install --cask inkscape` + `brew install libxml2` on macOS).
#
# Pipeline (each stage is a separate Inkscape process, because the shell has
# to make a decision -- rotate? what scale factor? how many fit? -- between
# stages, based on that stage's query output):
#   1. measure : open SRC, group everything into one object, query its
#                natural bounding box.
#   2. prepare : rotate 90 deg if the artwork is wider than tall (packs
#                tighter on a portrait page), scale to -w WIDTH if given,
#                query the final bounding box.
#   3. populate: compute the grid from that final size, move the prepared
#                object into slot 0, clone it into every other slot, tag
#                every tile, optionally add the white-halo filter, export.
#
# Inkscape's query/transform-* actions always operate in real physical
# pixels (96/inch) regardless of the document's own declared units --
# confirmed empirically, not documented -- so PX_PER_MM converts between
# that and the millimeters this script (and its -m/-g/-w/-b flags) works in.
set -euo pipefail

PX_PER_MM=3.7795275591

INKSCAPE="${INKSCAPE:-inkscape}"
if ! command -v "$INKSCAPE" >/dev/null 2>&1 && [[ -x "/Applications/Inkscape.app/Contents/MacOS/inkscape" ]]; then
  INKSCAPE="/Applications/Inkscape.app/Contents/MacOS/inkscape"
fi
command -v "$INKSCAPE" >/dev/null 2>&1 || { echo "error: inkscape not found (set INKSCAPE=/path/to/inkscape)" >&2; exit 1; }
command -v xmllint >/dev/null 2>&1 || { echo "error: xmllint not found (Omarchy: pacman -S libxml2)" >&2; exit 1; }

# Defaults favor tight packing: no gap, minimal margin.
MARGIN=2
GAP=0
PAGE="a4"     # "a4" | "letter"
SHADOW=0      # 1 = add a white halo/drop-shadow behind each tile
BLUR=0.8      # feGaussianBlur stdDeviation, mm, only used with SHADOW
WIDTH=""      # target width of each tile, mm (preserves aspect ratio); "" = natural size
ROTATE=auto   # auto | yes | no -- auto rotates landscape artwork 90deg to pack tighter
SRC=""
OUT=""

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") -i SRC -o OUT [options]

  -i SRC     source image: PNG/JPEG, or SVG (vector or with one embedded image)
  -o OUT     output path -- .pdf or .svg, chosen by OUT's extension
  -p PAGE    page size: 'a4' (210x297mm) or 'letter' (215.9x279.4mm) (default: $PAGE)
  -w WIDTH   scale each tile to this rendered width, mm (default: natural size)
  -m MARGIN  outer page margin, mm (default: $MARGIN)
  -g GAP     spacing between tiles, mm (default: $GAP -- packs edge to edge)
  -r MODE    rotate landscape artwork 90deg to pack tighter: auto|yes|no (default: $ROTATE)
  -s         add a white halo/drop-shadow behind each tile (default: off)
  -b BLUR    halo blur radius, mm, only used with -s (default: $BLUR)
EOF
  exit 1
}

while getopts "i:o:p:w:m:g:r:b:sh" opt; do
  case "$opt" in
    i) SRC="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    p) PAGE="$OPTARG" ;;
    w) WIDTH="$OPTARG" ;;
    m) MARGIN="$OPTARG" ;;
    g) GAP="$OPTARG" ;;
    r) ROTATE="$OPTARG" ;;
    s) SHADOW=1 ;;
    b) BLUR="$OPTARG" ;;
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
px() { awk -v m="$1"  -v k="$PX_PER_MM" 'BEGIN{printf "%.6f", m*k}'; }
# Length string ("210mm", "1448" (bare = px per SVG default), "8.5in", ...) -> mm.
to_mm() {
  awk -v s="$1" '
    BEGIN {
      match(s, /^[0-9.]+/)
      num = substr(s, RSTART, RLENGTH) + 0
      unit = substr(s, RLENGTH + 1)
      if (unit == "mm")      printf "%.10f", num
      else if (unit == "cm") printf "%.10f", num * 10
      else if (unit == "in") printf "%.10f", num * 25.4
      else if (unit == "pt") printf "%.10f", num * 25.4 / 72
      else                   printf "%.10f", num * 25.4 / 96
    }'
}

mkdir -p "$(dirname "$OUT")"
TMP="$(mktemp "${OUT}.XXXXXX.svg")"
trap 'rm -f "$TMP"' EXIT

# --- Stage 1: measure -------------------------------------------------
# Group everything in the source into one object (id=tileSource) and read
# its natural bounding box. Works identically for a raw PNG, a plain vector
# SVG, or an SVG with one embedded <image> -- Inkscape just opens it.
# Inkscape's query-* actions each print their value on its own line, so
# collapse to one space-separated line before `read` splits it into fields.
read -r NAT_X0 NAT_Y0 NAT_W0 NAT_H0 <<EOF
$("$INKSCAPE" "$SRC" --actions="select-all;selection-group;object-set-attribute:id,tileSource;query-x;query-y;query-width;query-height;export-filename:${TMP};export-plain-svg;export-do" 2>/dev/null | tr '\n' ' ')
EOF
[[ -n "$NAT_W0" && -n "$NAT_H0" ]] || { echo "error: could not measure artwork in $SRC" >&2; exit 1; }
NAT_W0_MM=$(mm "$NAT_W0"); NAT_H0_MM=$(mm "$NAT_H0")

DO_ROTATE=0
case "$ROTATE" in
  yes) DO_ROTATE=1 ;;
  no)  DO_ROTATE=0 ;;
  auto) awk -v w="$NAT_W0_MM" -v h="$NAT_H0_MM" 'BEGIN{exit !(w>h)}' && DO_ROTATE=1 || DO_ROTATE=0 ;;
esac

# Scale is computed against whichever natural axis will end up as the
# on-page width, so "-w 50" always means "50mm wide as printed", even if
# that axis started out as the artwork's natural height pre-rotation.
if [[ "$DO_ROTATE" -eq 1 ]]; then SCALE_BASIS_MM="$NAT_H0_MM"; else SCALE_BASIS_MM="$NAT_W0_MM"; fi
if [[ -n "$WIDTH" ]]; then
  SCALE=$(awk -v w="$WIDTH" -v b="$SCALE_BASIS_MM" 'BEGIN{printf "%.8f", w/b}')
else
  SCALE=1
fi

# --- Stage 2: prepare ---------------------------------------------------
prep_actions="select-clear;select-by-id:tileSource"
[[ "$DO_ROTATE" -eq 1 ]] && prep_actions+=";object-rotate-90-cw"
[[ "$SCALE" != "1" ]] && prep_actions+=";transform-scale:${SCALE}"
prep_actions+=";query-x;query-y;query-width;query-height;export-filename:${TMP};export-plain-svg;export-do"

read -r X1 Y1 W1 H1 <<EOF
$("$INKSCAPE" "$TMP" --actions="$prep_actions" 2>/dev/null | tr '\n' ' ')
EOF
[[ -n "$W1" && -n "$H1" ]] || { echo "error: could not prepare artwork from $SRC" >&2; exit 1; }
X1_MM=$(mm "$X1"); Y1_MM=$(mm "$Y1"); IMG_W=$(mm "$W1"); IMG_H=$(mm "$H1")

# Resize the page to the target A4/Letter mm size WITHOUT distorting
# existing content: a raw PNG import declares its root in bare numbers
# (SVG default = px, e.g. width="1448"), not mm, so simply overwriting
# width/height/viewBox with our target numbers would silently rescale
# (non-uniformly, since px and mm width/height ratios differ) everything
# already placed. Instead, derive this document's existing mm-per-viewBox-
# unit scale (k) from its own root, and pick a new viewBox that keeps that
# same k while making width/height exactly the target mm size -- so
# existing coordinates keep meaning exactly what they meant before.
ROOT_W_MM=$(to_mm "$(xmllint --xpath 'string(/*/@width)' "$TMP")")
VB_W=$(xmllint --xpath 'string(/*/@viewBox)' "$TMP" | awk '{print $3}')
K=$(awk -v w="$ROOT_W_MM" -v vb="$VB_W" 'BEGIN{printf "%.10f", w/vb}')
NEW_VB_W=$(awk -v p="$PAGE_W" -v k="$K" 'BEGIN{printf "%.6f", p/k}')
NEW_VB_H=$(awk -v p="$PAGE_H" -v k="$K" 'BEGIN{printf "%.6f", p/k}')

# Only the FIRST width/height/viewBox match is touched -- those belong to
# the root <svg>, which Inkscape always writes before any other element --
# so the artwork's own width/height attributes further down are left alone.
awk -v pw="$PAGE_W" -v ph="$PAGE_H" -v vbw="$NEW_VB_W" -v vbh="$NEW_VB_H" '
  !wdone && /width="[0-9.]+[a-zA-Z%]*"/ { sub(/width="[0-9.]+[a-zA-Z%]*"/, "width=\"" pw "mm\""); wdone=1 }
  !hdone && /height="[0-9.]+[a-zA-Z%]*"/ { sub(/height="[0-9.]+[a-zA-Z%]*"/, "height=\"" ph "mm\""); hdone=1 }
  !vdone && /viewBox="[-0-9.]+ [-0-9.]+ [0-9.]+ [0-9.]+"/ { sub(/viewBox="[-0-9.]+ [-0-9.]+ [0-9.]+ [0-9.]+"/, "viewBox=\"0 0 " vbw " " vbh "\""); vdone=1 }
  { print }
' "$TMP" > "$TMP.tmp"
mv "$TMP.tmp" "$TMP"

# --- Grid math: how many tiles fit, and the offset that centers the
# resulting block on the page. Kept isolated so it's easy to port (e.g. to
# JS for an in-browser version) without touching the Inkscape glue.
read -r COLS ROWS OFFSET_X OFFSET_Y <<EOF
$(awk -v pw="$PAGE_W" -v ph="$PAGE_H" -v iw="$IMG_W" -v ih="$IMG_H" -v m="$MARGIN" -v g="$GAP" '
  BEGIN {
    avail_w = pw - 2*m
    avail_h = ph - 2*m
    cols = int((avail_w + g) / (iw + g))
    rows = int((avail_h + g) / (ih + g))
    if (cols < 1) cols = 1
    if (rows < 1) rows = 1
    grid_w = cols*iw + (cols-1)*g
    grid_h = rows*ih + (rows-1)*g
    ox = (pw - grid_w) / 2
    oy = (ph - grid_h) / 2
    printf "%d %d %.6f %.6f\n", cols, rows, ox, oy
  }')
EOF

TOTAL=$((COLS * ROWS))
echo "$(basename "$SRC"): ${IMG_W}x${IMG_H}mm$( [[ $DO_ROTATE -eq 1 ]] && echo " (rotated)" ) on ${PAGE_W}x${PAGE_H}mm page -> ${COLS}x${ROWS} grid (${TOTAL} tiles)" >&2

# --- Stage 3: populate --------------------------------------------------
# Move the prepared object into slot 0, then clone it into every other slot.
# transform-translate is relative and PX-based (see header note) and always
# composes additively regardless of what's already on the object, so plain
# vector deltas from "current position" work for any content type -- image,
# group, path -- unlike x/y attributes, which only some elements support.
dx0_mm=$(awk -v t="$OFFSET_X" -v c="$X1_MM" 'BEGIN{printf "%.6f", t-c}')
dy0_mm=$(awk -v t="$OFFSET_Y" -v c="$Y1_MM" 'BEGIN{printf "%.6f", t-c}')
actions="select-clear;select-by-id:tileSource;object-set-attribute:class,tile;transform-translate:$(px "$dx0_mm"),$(px "$dy0_mm")"

for ((r = 0; r < ROWS; r++)); do
  for ((c = 0; c < COLS; c++)); do
    [[ $r -eq 0 && $c -eq 0 ]] && continue
    cellX=$(awk -v ox="$OFFSET_X" -v c="$c" -v iw="$IMG_W" -v g="$GAP" 'BEGIN{printf "%.6f", ox + c*(iw+g)}')
    cellY=$(awk -v oy="$OFFSET_Y" -v r="$r" -v ih="$IMG_H" -v g="$GAP" 'BEGIN{printf "%.6f", oy + r*(ih+g)}')
    dx_mm=$(awk -v t="$cellX" -v o="$OFFSET_X" 'BEGIN{printf "%.6f", t-o}')
    dy_mm=$(awk -v t="$cellY" -v o="$OFFSET_Y" 'BEGIN{printf "%.6f", t-o}')
    # select-clear is required: select-by-id otherwise adds to the existing
    # selection, so the next transform/attribute call would also re-stamp
    # the previous clone and drag it on top of the new one.
    actions+=";select-clear;select-by-id:tileSource;clone;object-set-attribute:class,tile;transform-translate:$(px "$dx_mm"),$(px "$dy_mm")"
  done
done

FILTER_ID="whiteDropShadow"
if [[ "$SHADOW" -eq 1 ]]; then
  # feDropShadow isn't supported by Inkscape's own renderer; this is the
  # equivalent built from primitives every renderer supports: blur the
  # alpha silhouette, flood it white, composite behind the original.
  FILTER_XML="<filter id=\"${FILTER_ID}\" x=\"-60%\" y=\"-60%\" width=\"220%\" height=\"220%\" color-interpolation-filters=\"sRGB\"><feGaussianBlur in=\"SourceAlpha\" stdDeviation=\"${BLUR}\" result=\"blur\"/><feFlood flood-color=\"#ffffff\" flood-opacity=\"1\" result=\"white\"/><feComposite in=\"white\" in2=\"blur\" operator=\"in\" result=\"shadow\"/><feMerge><feMergeNode in=\"shadow\"/><feMergeNode in=\"SourceGraphic\"/></feMerge></filter>"
  # defs may already be self-closed (empty) or open with real content
  # (gradients, etc. from the source artwork) -- handle both without
  # clobbering anything. Inkscape's pretty-printer puts a newline between
  # "<defs" and its attributes, so the match has to span lines: flatten the
  # file to one line first (SVG/XML doesn't care about whitespace) rather
  # than fight awk's non-portable multi-line-slurp support (BSD awk's
  # RS="\0" silently falls back to paragraph mode, not a true NUL record
  # separator, and splits on the blank line after the XML header).
  FLAT=$(tr '\n' ' ' < "$TMP")
  if grep -qE '<defs[^>]*/>' <<<"$FLAT"; then
    FLAT=$(sed -E "s|<defs[^>]*/>|<defs>${FILTER_XML}</defs>|" <<<"$FLAT")
  else
    FLAT=$(sed -E "s|<defs[^>]*>|&${FILTER_XML}|" <<<"$FLAT")
  fi
  printf '%s' "$FLAT" > "$TMP"
  actions+=";select-clear;select-by-class:tile;object-set-attribute:filter,url(#${FILTER_ID})"
fi
# Inkscape's PDF export (export-type:pdf) already defaults to the full
# declared page, unlike PNG export -- export-area-page is added anyway
# since relying on that default going unchanged felt riskier than a
# 1-token insurance policy.
case "$OUT" in
  *.pdf) actions+=";export-area-page;export-filename:${OUT};export-type:pdf;export-do" ;;
  *)     actions+=";export-filename:${OUT};export-plain-svg;export-do" ;;
esac

"$INKSCAPE" "$TMP" --actions="$actions" 2>/dev/null

echo "wrote $OUT" >&2
