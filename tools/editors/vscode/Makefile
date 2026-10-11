# Builds the VS Code / Cursor extension as a .vsix. See README.md.

ROOT := $(abspath $(CURDIR)/../../..)
VERSION := $(shell cat $(ROOT)/VERSION)
OUT ?= $(CURDIR)
VSIX := $(abspath $(OUT))/pyking-$(VERSION).vsix
FILES := package.json package-lock.json extension.js language-configuration.json README.md .vscodeignore

.PHONY: vsix clean help
.DEFAULT_GOAL := vsix

help:
	@echo "make vsix [OUT=dir]  build pyking-$(VERSION).vsix into OUT (default: here)"
	@echo "make clean           remove build/ and the .vsix files here"

# The extension is staged in build/, where its version is set from
# VERSION and its dependencies installed, so the tree is left as it was.
vsix:
	rm -rf build
	mkdir -p build/syntaxes $(abspath $(OUT))
	cp $(FILES) build/
	cp syntaxes/pyking.tmLanguage.json build/syntaxes/
	cp $(ROOT)/LICENSE build/
	cd build && npm version --no-git-tag-version --allow-same-version $(VERSION)
	cd build && npm ci --ignore-scripts --no-audit --no-fund
	cd build && npx vsce package --allow-missing-repository --out $(VSIX)
	rm -rf build
	@echo "wrote $(VSIX)"

clean:
	rm -rf build
	rm -f pyking-*.vsix
