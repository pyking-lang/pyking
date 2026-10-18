# The Pyking web playground.
#
#   make            vendor, check, then serve and print the URL
#   make serve      serve the page
#   make check      check every example headlessly
#   make PORT=9000  serve somewhere other than 8000
#
# Nothing is built: `pyk playground` serves assets/, the shared files in
# ../webrun/ and the compiler bundle ../../share/pyking.js from where they
# sit. `make` at the repository root builds that bundle and ../../pyk.

PYTHON ?= python3
PYK    ?= ../../pyk
PORT   ?=

.PHONY: all vendor check e2e serve help

# Serving is last, and blocks -- that is the point: `make` leaves you with a
# running server and a link to click.
all: vendor check serve

vendor:
	@$(PYTHON) ../webrun/server.py vendor

check:
	@$(PYTHON) playground.py check

# Browser tests. Separate from `check` because this is the one part of the
# tool that needs a dependency (Playwright); without it the script says so
# and exits cleanly rather than failing.
e2e:
	@node e2e.mjs

serve:
	@$(PYK) playground $(if $(PORT),--port $(PORT))

help:
	@echo "make            vendor + check + serve (prints a clickable URL)"
	@echo "make vendor     download Ace, KaTeX and Monaco into ../webrun/vendor/ (once)"
	@echo "make check      check every example headlessly, no browser needed"
	@echo "make e2e        browser tests (needs Playwright; skips if absent)"
	@echo "make serve      serve the page on http://localhost:\$$(PORT)/"
	@echo "                (8000, or the next free port, when PORT is unset)"
	@echo
	@echo "variables:  PORT=$(PORT)   PYTHON=$(PYTHON)   PYK=$(PYK)"
