# Business Card Data Extractor (bcde). Run `make` to list the commands.

# ── Settings (override on the command line: make scan CARDS=~/Cards OUT=~/Desktop) ──
CARDS ?=
OUT   ?= out
DB    ?= $(OUT)/cards.db
JOBS  ?=
LIMIT ?=
FILE  ?=
ARGS  ?=

BIN     := bin/bcde
SOURCES := Package.swift $(wildcard Sources/bcde/*.swift)
ARCHS   := --arch arm64 --arch x86_64

# make doesn't expand a leading ~ in variables, so do it here.
expand = $(patsubst ~%,$(HOME)%,$(1))
COMMON = --db "$(call expand,$(DB))" --out "$(call expand,$(OUT))"

# Color only when talking to a terminal, and never when NO_COLOR is set.
ifeq ($(NO_COLOR)$(shell test -t 2 && echo tty),tty)
BOLD   := \033[1m
DIM    := \033[2m
CYAN   := \033[36m
YELLOW := \033[33m
RED    := \033[31m
RESET  := \033[0m
endif

.DEFAULT_GOAL := help
.PHONY: help build scan trial export csv xlsx ocr clean require-cards require-db

help:
	@printf "\n$(BOLD)Business Card Data Extractor (bcde)$(RESET)\n"
	@printf "\nUsage: make $(CYAN)<command>$(RESET) [$(YELLOW)VAR$(RESET)=value ...]\n"
	@awk 'BEGIN { FS = ":.*## " } \
		/^##@/ { printf "\n$(BOLD)%s$(RESET)\n", substr($$0, 5) } \
		/^[a-z][a-z-]*:.*## / { printf "  $(CYAN)%-8s$(RESET) %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\n$(BOLD)Variables$(RESET)\n"
	@printf "  $(YELLOW)%-8s$(RESET) %s $(DIM)%s$(RESET)\n" \
		CARDS "folder of card scans"              "(required for scan, trial)" \
		OUT   "where the database and exports go" "(default: out)" \
		DB    "SQLite database"                   "(default: \$$OUT/cards.db)" \
		LIMIT "only process the first N cards"    "(trial default: 50)" \
		JOBS  "OCR worker processes"              "(default: CPU cores - 2, max 8)" \
		FILE  "a single card file"                "(for ocr)" \
		ARGS  "extra bcde options"               "(e.g. --force, --fast, --pair-regex ...)"
	@printf "\n$(BOLD)Examples$(RESET)\n"
	@printf "  make trial CARDS=~/Cards           $(DIM)# try the first 50 cards$(RESET)\n"
	@printf "  make scan  CARDS=~/Cards           $(DIM)# all cards → out/cards.db, .csv, .xlsx$(RESET)\n"
	@printf "  make xlsx  OUT=~/Desktop/cards     $(DIM)# re-export just the spreadsheet$(RESET)\n"
	@printf "  make scan  CARDS=~/Cards ARGS=--force  $(DIM)# re-process cards already done$(RESET)\n\n"

##@ Build
build: ## Build bin/bcde (universal: Apple silicon + Intel)
	@printf "$(DIM)Building universal binary…$(RESET)\n"
	@set -o pipefail; swift build -c release $(ARCHS) 2>&1 | grep -v "x86_64 architecture is deprecated"
	@mkdir -p bin
	@cp "$$(swift build -c release $(ARCHS) --show-bin-path)/bcde" $(BIN)
	@printf "Built $(BOLD)$(BIN)$(RESET) $(DIM)(%s)$(RESET)\n" "$$(lipo -archs $(BIN))"

clean: ## Remove build output (keeps the database and exports)
	rm -rf .build bin

##@ Extract
scan: require-cards $(BIN) ## Read every card in CARDS → database + CSV + XLSX
	@mkdir -p "$(dir $(call expand,$(DB)))"
	@$(BIN) scan "$(call expand,$(CARDS))" $(COMMON) $(if $(JOBS),--jobs $(JOBS)) $(if $(LIMIT),--limit $(LIMIT)) $(ARGS)

trial: ## Same as scan, but only the first 50 cards (or LIMIT)
	@$(MAKE) --no-print-directory scan LIMIT=$(or $(LIMIT),50)

##@ Export (from the database, without re-scanning)
export: require-db $(BIN) ## Write both cards.csv and cards.xlsx
	@$(BIN) export $(COMMON) --format both $(ARGS)

csv: require-db $(BIN) ## Write cards.csv only
	@$(BIN) export $(COMMON) --format csv $(ARGS)

xlsx: require-db $(BIN) ## Write cards.xlsx only
	@$(BIN) export $(COMMON) --format xlsx $(ARGS)

##@ Troubleshooting
ocr: $(BIN) ## Show OCR lines, scores and fields for one card (FILE=...)
	@test -n "$(FILE)" || { printf "$(RED)FILE is required$(RESET), e.g. make ocr FILE=~/Cards/card0042.jpg\n"; exit 2; }
	@$(BIN) ocr "$(call expand,$(FILE))" $(ARGS)

# The other commands build automatically, but only when a source file changed.
$(BIN): $(SOURCES)
	@$(MAKE) --no-print-directory build

require-cards:
	@test -n "$(CARDS)" || { printf "$(RED)CARDS is required$(RESET), e.g. make $(MAKECMDGOALS) CARDS=~/Cards\n"; exit 2; }
	@test -d "$(call expand,$(CARDS))" || { printf "$(RED)Not a folder:$(RESET) $(CARDS)\n"; exit 2; }

require-db:
	@test -f "$(call expand,$(DB))" || { printf "$(RED)No database at $(DB)$(RESET) — run $(BOLD)make scan CARDS=...$(RESET) first\n"; exit 2; }
