# Pyking's installable packages.
#
#   make setup           make the release toolchains (once, on a Mac)
#   make                 build every package into build/
#   make ARCHS=arm64     one architecture only, for trying it locally
#   make install-local   brew install the local build (a Mac with brew)
#   make uninstall-local remove it again
#   make clean           remove build/
#
# Only the Homebrew package exists so far, and it is built on an Apple
# Silicon Mac: see README.md for the one-time setup of the two release
# toolchains it builds with.
# `make packaging` at the repository root builds the compiler and
# downloads the browser libraries first, which this relies on.

PYTHON ?= python3
ARCHS  ?=

.PHONY: all build setup install-local uninstall-local clean help

all: build

build:
	@$(PYTHON) packaging.py build $(if $(ARCHS),--archs $(ARCHS))

setup:
	@$(PYTHON) packaging.py setup

install-local:
	@$(PYTHON) packaging.py install-local

uninstall-local:
	@$(PYTHON) packaging.py uninstall-local

clean:
	@rm -rf build
	@echo "clean: removed tools/packaging/build/"

help:
	@echo "make setup            make the two release toolchains, skipping what"
	@echo "                      is done already, and say whether they are ready"
	@echo "make                  build every package into build/"
	@echo "make ARCHS=arm64      only that architecture (not for publishing)"
	@echo "make install-local    brew install the local build, through the"
	@echo "                      tap pyking-lang/local, and run its brew test"
	@echo "make uninstall-local  uninstall it and remove that tap"
	@echo "make clean            remove build/"
	@echo
	@echo "variables:  ARCHS=$(ARCHS)   PYTHON=$(PYTHON)"
	@echo "            PYK_ARM64, PYK_X86_64 (environment): the command prefixes"
	@echo "            that run each release toolchain; see README.md"
