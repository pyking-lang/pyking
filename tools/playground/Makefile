# The Pyking web playground.
#
#   make            vendor, build, check, then serve and print the URL
#   make build      regenerate build/ only
#   make serve      serve an existing build/
#   make CDN=1      build against a CDN instead of vendoring 12 MB
#   make PORT=9000  serve somewhere other than 8000
#
# Nothing under build/ or vendor/ is checked in: generator.py is the single
# source for every generated file, and `make` is the only way to produce them.

PYTHON ?= python3
PORT   ?= 8000
CDN    ?= 0

ifeq ($(CDN),1)
CDNFLAG := --cdn
else
CDNFLAG :=
endif

GENERATOR := $(PYTHON) generator.py

.PHONY: all build vendor check serve clean distclean help

# Serving is last, and blocks -- that is the point: `make` leaves you with a
# running server and a link to click.
all: vendor build check serve

vendor:
	@$(GENERATOR) vendor $(CDNFLAG)

build:
	@$(GENERATOR) build $(CDNFLAG)

check:
	@$(GENERATOR) check

serve:
	@$(GENERATOR) serve --port $(PORT)

clean:
	@rm -rf build
	@echo "clean: removed build/"

# vendor/ is a download cache, so it survives `clean` and only goes on
# request -- rebuilding it needs the network again.
distclean: clean
	@rm -rf vendor
	@echo "distclean: removed vendor/ (next build re-downloads ~12 MB)"

help:
	@echo "make            vendor + build + check + serve (prints a clickable URL)"
	@echo "make build      regenerate build/ from generator.py"
	@echo "make check      compile every example headlessly, no browser needed"
	@echo "make serve      serve build/ on http://localhost:\$$(PORT)/"
	@echo "make clean      remove build/"
	@echo "make distclean  also remove the vendor/ download cache"
	@echo
	@echo "variables:  PORT=$(PORT)   CDN=$(CDN)   PYTHON=$(PYTHON)"
