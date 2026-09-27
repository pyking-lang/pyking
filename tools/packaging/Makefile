# Pyking's installable packages, and publishing them.
#
#   make setup           make the build toolchains (once)
#   make                 build every package into build/
#   make FORMATS=linux   only some formats (homebrew, linux)
#   make ARCHS=arm64     only some architectures (not for publishing)
#   make install-local   install the local build on this machine
#   make uninstall-local remove it again
#   make release         publish the build: pyking-lang/pyking-releases
#                        and the formula in pyking-lang/homebrew-tap
#   make clean           remove build/
#
# Homebrew packages are built on an Apple Silicon Mac, Linux ones in
# Docker: see README.md for the one-time setup. `make packaging` at the
# repository root builds the compiler and downloads the browser libraries
# first, which this relies on.

PYTHON  ?= python3
FORMATS ?=
ARCHS   ?=

.PHONY: all build setup install-local uninstall-local release clean help

all: build

build:
	@$(PYTHON) packaging.py build $(if $(FORMATS),--formats $(FORMATS)) \
		$(if $(ARCHS),--archs $(ARCHS))

setup:
	@$(PYTHON) packaging.py setup $(if $(FORMATS),--formats $(FORMATS))

install-local:
	@$(PYTHON) packaging.py install-local

uninstall-local:
	@$(PYTHON) packaging.py uninstall-local

# Asks before publishing; YES=1 does not.
release:
	@$(PYTHON) packaging.py release $(if $(YES),--yes)

clean:
	@rm -rf build
	@echo "clean: removed tools/packaging/build/"

help:
	@echo "make setup            make the build toolchains: the Mac's two opam"
	@echo "                      switches and the Linux Docker images, skipping"
	@echo "                      what is done already, and say whether they are"
	@echo "                      ready"
	@echo "make                  build every package into build/"
	@echo "make FORMATS=linux    only those formats (homebrew, linux)"
	@echo "make ARCHS=arm64      only that architecture (not for publishing)"
	@echo "make install-local    install the local build here: with Homebrew on"
	@echo "                      a Mac, with install.sh into ~/.local on Linux"
	@echo "make uninstall-local  remove it again"
	@echo "make release          publish the build: one release of"
	@echo "                      pyking-lang/pyking-releases with every platform,"
	@echo "                      and the formula in pyking-lang/homebrew-tap,"
	@echo "                      then asks whether to tag HEAD in"
	@echo "                      pyking-lang/pyking as release-<VERSION>;"
	@echo "                      asks first (YES=1 does not)"
	@echo "make clean            remove build/"
	@echo
	@echo "variables:  FORMATS=$(FORMATS)  ARCHS=$(ARCHS)  PYTHON=$(PYTHON)"
	@echo "            PYK_ARM64, PYK_X86_64 (environment): the command prefixes"
	@echo "            that run the Mac's release toolchains; see README.md"
