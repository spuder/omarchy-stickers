# Omarchy: plain `inkscape` from PATH (pacman -S inkscape). macOS without it
# on PATH: tile-svg.sh itself falls back to the Inkscape.app bundle.
# Override here or via `make INKSCAPE=...` only if your install lives
# somewhere unusual.
INKSCAPE ?= inkscape

# Page sizes to generate a sheet for, every time. Each gets its own output
# file (see page_slug below): a4 -> "-a4.pdf", letter -> "-8.5x11.pdf".
PAGE_SIZES ?= a4 letter

MARGIN   ?= 2        # outer page margin, mm
GAP      ?= 0        # spacing between tiles, mm -- 0 packs edge to edge
ROTATE   ?= auto     # auto | yes | no -- auto rotates landscape artwork 90deg to pack tighter
SHADOW   ?= 0        # 1 = add a white halo/drop-shadow behind each tile
BLUR     ?= 0.8      # halo blur radius, mm, only used with SHADOW=1
WIDTH    ?=          # global default tile width, mm -- usually left empty; set per-sticker below instead

# Flags shared by every page size (page itself is passed separately, per rule).
TILE_FLAGS = -m $(MARGIN) -g $(GAP) -r $(ROTATE) -b $(BLUR) \
             $(if $(filter 1,$(SHADOW)),-s) $(if $(WIDTH),-w $(WIDTH))

# --- Machinery (defined before use below) --------------------------------
# a4 -> "a4", letter -> "8.5x11", used in output filenames.
page_slug = $(if $(filter letter,$(1)),8.5x11,$(1))
# source path + page size -> pdf/<name>-<slug>.pdf (".single" stripped so
# old-style *.single.svg sources don't end up as foo.single-a4.pdf).
sheet_name = pdf/$(patsubst %.single,%,$(basename $(notdir $(1))))-$(call page_slug,$(2)).pdf

# Per-sticker width override (mm, preserving aspect ratio), applied to all
# of that sticker's page sizes via a target-specific variable. Called from
# the STICKERS section below.
define set_width
$(foreach p,$(PAGE_SIZES),$(eval $(call sheet_name,$(1),$(p)): WIDTH := $(2)))
endef

# --- Stickers ---------------------------------------------------------
# Every PNG and SVG in the repo root becomes a sticker automatically --
# nothing to register by hand. If a PNG has an identically-named SVG next
# to it (e.g. foo.png + foo.svg), the PNG is skipped: the SVG is assumed
# to be the better (vector) source for the same artwork, so each piece of
# artwork only turns into one sticker. Each produces one
# pdf/<name>-<page>.pdf per entry in PAGE_SIZES.
ROOT_SVGS        := $(wildcard *.svg)
ROOT_PNGS        := $(wildcard *.png)
PNG_BASENAMES_WITH_SVG := $(filter $(basename $(ROOT_SVGS)),$(basename $(ROOT_PNGS)))
PNGS_WITHOUT_SVG := $(filter-out $(addsuffix .png,$(PNG_BASENAMES_WITH_SVG)),$(ROOT_PNGS))
STICKERS := $(ROOT_SVGS) $(PNGS_WITHOUT_SVG)

# Per-sticker width override (mm, preserving aspect ratio), applied to all
# of that sticker's page sizes. Add one call per sticker that needs a
# specific size instead of its natural one. Example from the request this
# table was built for: myComputerMyRules at 50mm wide.
$(call set_width,myComputerMyRules.png,50)

SHEETS := $(foreach s,$(STICKERS),$(foreach p,$(PAGE_SIZES),$(call sheet_name,$(s),$(p))))

.PHONY: all tile clean-sheets tile-one

all: tile

tile: $(SHEETS)

# One explicit rule per sticker x page size (rather than one pattern rule)
# because sources are heterogeneous: different directories, and PNG vs SVG.
define STICKER_RULE
$(call sheet_name,$(1),$(2)): $(1) scripts/tile-svg.sh
	INKSCAPE=$$(INKSCAPE) scripts/tile-svg.sh -i $(1) -o $$@ -p $(2) $$(TILE_FLAGS)
endef
$(foreach s,$(STICKERS),$(foreach p,$(PAGE_SIZES),$(eval $(call STICKER_RULE,$(s),$(p)))))

# One-off / non-convention paths:
#   make tile-one SRC=... OUT=... [PAGE=a4|letter] [WIDTH=] [MARGIN=] [GAP=] [ROTATE=] [SHADOW=1] [BLUR=]
PAGE ?= a4
tile-one:
	INKSCAPE=$(INKSCAPE) scripts/tile-svg.sh -i $(SRC) -o $(OUT) -p $(PAGE) $(TILE_FLAGS)

clean-sheets:
	rm -f $(SHEETS)
