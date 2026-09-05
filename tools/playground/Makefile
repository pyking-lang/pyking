# The Pyking web playground.
#
#   make            vendor, build, check, then serve and print the URL
#   make build      regenerate build/ only
#   make serve      serve an existing build/
#   make CDN=1      build against a CDN instead of vendoring Ace
#   make PORT=9000  serve somewhere other than 8000
#
# Nothing under build/ or vendor/ is checked in: generator.py and assets/
# are the source for every generated file, and `make` is the only way to
# produce them.

PYTHON ?= python3
PORT   ?= 8000
CDN    ?= 0

ifeq ($(CDN),1)
CDNFLAG := --cdn
else
CDNFLAG :=
endif

GENERATOR := $(PYTHON) generator.py

.PHONY: all build vendor check e2e serve clean distclean help

# Serving is last, and blocks -- that is the point: `make` leaves you with a
# running server and a link to click.
all: vendor build check serve

vendor:
	@$(GENERATOR) vendor $(CDNFLAG)

build:
	@$(GENERATOR) build $(CDNFLAG)

check:
	@$(GENERATOR) check

# Browser tests. Separate from `check` because this is the one part of the
# tool that needs a dependency (Playwright); without it the script says so
# and exits cleanly rather than failing.
e2e:
	@node e2e.mjs

serve:
	@$(GENERATOR) serve --port $(PORT)

clean:
	@rm -rf build
	@echo "clean: removed build/"

# vendor/ is a download cache, so it survives `clean` and only goes on
# request -- rebuilding it needs the network again.
distclean: clean
	@rm -rf vendor
	@echo "distclean: removed vendor/ (next build re-downloads ~1 MB)"

help:
	@echo "make            vendor + build + check + serve (prints a clickable URL)"
	@echo "make build      regenerate build/ from generator.py and assets/"
	@echo "make check      compile every example headlessly, no browser needed"
	@echo "make e2e        browser tests (needs Playwright; skips if absent)"
	@echo "make serve      serve build/ on http://localhost:\$$(PORT)/"
	@echo "                (re-copies the compiler from src/ first)"
	@echo "make clean      remove build/"
	@echo "make distclean  also remove the vendor/ download cache"
	@echo
	@echo "variables:  PORT=$(PORT)   CDN=$(CDN)   PYTHON=$(PYTHON)"
