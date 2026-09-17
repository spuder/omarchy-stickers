# Omarchy: plain `inkscape` from PATH (pacman -S inkscape). macOS without it
# on PATH: tile-svg.sh itself falls back to the Inkscape.app bundle.
# Override here or via `make INKSCAPE=...` only if your install lives
# somewhere unusual.
INKSCAPE ?= inkscape

# Each sheet needs 2-3 separate Inkscape process launches (measure,
# rasterize, and -- for PDF output -- convert), so building all of them
# serially is slow (136 sheets x ~1.5s Inkscape startup x up to 3 = 10+
# min). Sheets don't depend on each other, so run them in parallel across
# CPU cores instead. nproc is Linux (Omarchy); sysctl is macOS.
NPROC := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
MAKEFLAGS += -j$(NPROC)

# Page sizes to generate a sheet for, every time. Each gets its own output
# file (see page_slug below): a4 -> "-a4.pdf", letter -> "-8.5x11.pdf".
PAGE_SIZES ?= a4 letter

MARGIN   ?= 8        # outer page margin, mm -- most printers can't print edge-to-edge anyway
GAP      ?= 2        # spacing between tiles, mm -- for a visible cut line between stickers
ROTATE   ?= auto     # auto | yes | no -- auto rotates landscape artwork 90deg to pack tighter
BORDER   ?= 1        # 1 = add a solid white perimeter + outline around each tile
WHITE_W  ?= 3        # white perimeter thickness, mm, only used with BORDER=1
BLACK_W  ?= 0.3      # outline thickness, mm, only used with BORDER=1
OUTLINE_COLOR ?= \#cccccc # outline color, only used with BORDER=1 (escaped: # starts a Makefile comment)
WIDTH    ?=          # global default tile width, mm -- usually left empty; set per-sticker below instead
MAXWIDTH ?= 152.4    # 6in -- cap on natural size when a sticker has no WIDTH override; never enlarges

# Flags shared by every page size (page itself is passed separately, per rule).
TILE_FLAGS = -m $(MARGIN) -g $(GAP) -r $(ROTATE) -b $(WHITE_W) -k $(BLACK_W) -c "$(OUTLINE_COLOR)" -x $(MAXWIDTH) \
             $(if $(filter 1,$(BORDER)),-s) $(if $(WIDTH),-w $(WIDTH))

# --- Machinery (defined before use below) --------------------------------
# a4 -> "a4", letter -> "8.5x11", used in output filenames.
page_slug = $(if $(filter letter,$(1)),8.5x11,$(1))
# source path + page size -> pdf/<name>-<slug>.pdf (".single" stripped so
# old-style *.single.svg sources don't end up as foo.single-a4.pdf).
sheet_name = pdf/$(patsubst %.single,%,$(basename $(notdir $(1))))-$(call page_slug,$(2)).pdf

# Per-sticker overrides (target-specific variables, applied to all of that
# sticker's page sizes). Called from the STICKERS section below.
define set_width
$(foreach p,$(PAGE_SIZES),$(eval $(call sheet_name,$(1),$(p)): WIDTH := $(2)))
endef
define set_rotate
$(foreach p,$(PAGE_SIZES),$(eval $(call sheet_name,$(1),$(p)): ROTATE := $(2)))
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

# The oma-logo-* family was rendering at MAXWIDTH (or larger, height-capped)
# -- basically poster-sized, one per page. Hardcoded to half that (3in).
# These are naturally wide/short (landscape); auto-rotate flips them to
# portrait based on raw aspect ratio, which made sense before a fixed width
# was applied, but once width is fixed, portrait makes each tile much
# TALLER (short axis becomes the free one) -- 2 per page instead of 16.
# So rotation is turned off for this family specifically.
$(foreach f,$(wildcard oma-logo-*.svg),$(call set_width,$(f),76.2))
$(foreach f,$(wildcard oma-logo-*.svg),$(call set_rotate,$(f),no))

# omarchy-wordmark-* is a wide horizontal text lockup (~4.3:1). Auto-rotate
# turned it sideways and, combined with the page-height cap, made each
# sticker nearly a full page long (~275-293mm). Kept unrotated (also just
# more correct -- wordmarks read horizontally) and capped under 4in.
$(foreach f,$(wildcard omarchy-wordmark-*.svg),$(call set_width,$(f),100))
$(foreach f,$(wildcard omarchy-wordmark-*.svg),$(call set_rotate,$(f),no))

# omarchy-logo-* (square, unlike oma-logo-*) was rendering at MAXWIDTH
# (152.4mm, 1 per page). 55mm fits 3 across on both A4 and Letter.
$(foreach f,$(wildcard omarchy-logo-*.svg),$(call set_width,$(f),55))

SHEETS := $(foreach s,$(STICKERS),$(foreach p,$(PAGE_SIZES),$(call sheet_name,$(s),$(p))))

.PHONY: all tile clean tile-one

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
#   make tile-one SRC=... OUT=... [PAGE=a4|letter] [WIDTH=] [MAXWIDTH=] [MARGIN=] [GAP=] [ROTATE=] [BORDER=0] [WHITE_W=] [BLACK_W=]
PAGE ?= a4
tile-one:
	INKSCAPE=$(INKSCAPE) scripts/tile-svg.sh -i $(SRC) -o $(OUT) -p $(PAGE) $(TILE_FLAGS)

clean:
	rm -f $(SHEETS)
