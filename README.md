# omarchy-stickers

Turns a single piece of artwork (PNG, JPEG, or SVG) into a printable sticker
sheet: one image tiled edge-to-edge across a page, sized to fit as many
copies as possible.

## Prerequisites

- [Inkscape](https://inkscape.org/) 1.x — does the actual tiling
- `xmllint` (part of `libxml2`) — reads artwork dimensions

```sh
# macOS
brew install --cask inkscape
brew install libxml2   # xmllint is usually already present via Xcode CLT

# Omarchy
sudo pacman -S inkscape libxml2
```

`awk`, `sed`, and `bash` are also required, but ship by default on both.

## Quick start

```sh
make tile
```

This builds every sticker sheet listed in the Makefile's `STICKERS` variable,
at both page sizes (A4 and US Letter), as PDFs in `pdf/`. Output files are
named `<sticker>-a4.pdf` and `<sticker>-8.5x11.pdf`. Rerunning `make tile`
only rebuilds sheets whose source image changed.

To add a new sticker, open the `Makefile` and add one line:

```make
STICKERS += path/to/your-image.png
```

The source can be a raw PNG/JPEG, a plain vector SVG, or an SVG with one
embedded image — any of them work the same way. By default each tile is
sized to the artwork's natural size. To scale it to a specific width
instead (aspect ratio is preserved), add a line right below the `STICKERS`
list:

```make
$(call set_width,path/to/your-image.png,50)
```

That scales `your-image` to 50mm wide on the sheet, in both page sizes.

## Other useful commands

```sh
make tile SHADOW=1          # add a white halo/drop-shadow behind every tile
make tile GAP=2 MARGIN=5    # 2mm between tiles, 5mm page border (default: 0/2, packed tight)
make tile ROTATE=no         # never auto-rotate landscape artwork to pack tighter
make clean-sheets           # delete every generated sheet (sources are untouched)
```

`ROTATE` defaults to `auto`: artwork wider than it is tall gets rotated 90°
automatically, since that usually packs more copies onto a portrait page.

For a one-off sheet outside the `STICKERS` list (a different page size for
a single image, testing a width before adding it permanently, etc.), skip
the Makefile entirely:

```sh
make tile-one SRC=path/to/image.png OUT=pdf/out-letter.pdf PAGE=letter WIDTH=40
```

Or call the script directly for full control. `tile-svg.sh` picks the output
format from `-o`'s extension, so either works:

```sh
scripts/tile-svg.sh -i path/to/image.png -o out.pdf -p a4 -w 50 -s
scripts/tile-svg.sh -i path/to/image.png -o out.svg -p a4 -w 50 -s   # editable SVG instead of PDF
```

Run `scripts/tile-svg.sh` with no arguments to see every flag.
