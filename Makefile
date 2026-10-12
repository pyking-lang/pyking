# The Pyking compiler.
#
#   make            build the compiler, build/pyking.js and the library
#                   plugins the interpreter loads
#   make test       the compiler's own test suite, run in parallel
#                   (TARGET=c23 or TARGET=c for one target or family)
#   make stest      the same suite, one test at a time
#   make notebook   open PYKING-TUTORIAL.md as a notebook in the browser
#   make help       open the help (getting started, the language reference,
#                   the libraries) in the browser
#   make website    build the website into website/
#   make packaging  build the installable packages (macOS and Linux)
#   make clean      remove what has been generated
#
# Run `make targets` for the full list. The compiler is OCaml in src/,
# built by dune into the executable this directory calls ./pyk.

.PHONY: all help targets build libs test stest check-node playground notebook vendor \
	website website-dev \
	packaging packaging-setup packaging-install packaging-uninstall \
	release \
	clean clean-pycache clean-build clean-website distclean

# `make` builds the compiler: it is the one thing someone typing `make`
# in a compiler's directory is asking for. The standard library's
# plugins are part of that, since the interpreter loads them.
all: build libs

# dune writes the executable into _build/default/src, where nobody would
# think to run it from, so it is copied out to ./pyk. `cp -f` rather than
# `cp`: dune leaves what it builds read-only, and so is the copy, which a
# second `make` would otherwise fail to overwrite.
#
# build/pyking.js is the same compiler as JavaScript -- the interpreter
# the `iweb` target ships and the playground runs. It is built here so
# there is one copy: tools/playground reuses this rather than running a
# dune build of its own.
build:
	dune build src/pyk.exe src/web/pyking_web.bc.js
	@cp -f _build/default/src/pyk.exe pyk
	@./pyk --help >/dev/null 2>&1 || { \
	  echo "build: ./pyk was copied, but it will not run on this machine:"; \
	  echo "       $$(file -b pyk 2>/dev/null || echo 'unrecognised format')"; \
	  echo ""; \
	  echo "       _build/ and ./pyk are this machine's build output. One of"; \
	  echo "       them has come from another machine -- a shared or synced"; \
	  echo "       working tree will do it -- and dune reads a _build/ it did"; \
	  echo "       not write as up to date, so it copies out a binary for the"; \
	  echo "       wrong platform."; \
	  echo ""; \
	  echo "       Run 'make clean' and build again. To stop it recurring,"; \
	  echo "       keep _build/, ./pyk and build/ out of whatever syncs the"; \
	  echo "       tree; .gitignore already lists all three."; \
	  exit 1; }
	@mkdir -p build build/plugin
	@cp -f _build/default/src/web/pyking_web.bc.js build/pyking.js
	@cp -f _build/default/src/plugin/.pyk_plugin.objs/byte/pyk_plugin.cmi \
	  build/plugin/pyk_plugin.cmi
	@python3 tools/help/help.py build/help
	@echo "build: ./pyk, build/pyking.js, build/plugin/ and build/help/"

# The interpreter reaches a library implemented in a target language
# through its OCaml implementation, compiled to a plugin it loads
# (src/plugin_host.ml). This builds one beside each implementation under
# lib/, so the standard library runs with no OCaml installed; a plugin
# already newer than what it is built from is left alone.
libs: build
	@./pyk plugins lib

# The help, as `pyk help` serves it: the pages tools/help/help.py wrote
# into build/help/ when the compiler was built, which the website and
# the playground's Help tab show too.
help: build vendor
	./pyk help $(if $(PORT),--port $(PORT))

# Kept in the same shape as `make -C tools/playground help`, so the two
# read alike. Both are hand-written and neither has anything to generate
# them from, so update this list whenever a target is added or renamed.
targets:
	@echo "make              build the compiler into ./pyk and build/, the help"
	@echo "                  into build/help/, then make libs"
	@echo "make libs         compile each lib/*/<name>_external.ml into the"
	@echo "                  plugin the interpreter loads, <name>_external.cmxs"
	@echo "make test         all eight suites, then a combined summary: every"
	@echo "                  tests/*.pyk on every target tests/test_cases.toml"
	@echo "                  lists it for, run in parallel (JOBS=n to say how"
	@echo "                  parallel), then the REPL's own cases in tests/repl/,"
	@echo "                  then the library search path's, then the"
	@echo "                  playground's compiler bundle, then the notebook's"
	@echo "                  renderer and server, then the packaged tree's,"
	@echo "                  then the website's pages and library docs, then"
	@echo "                  tinyweb's pages and servers (in Chromium where one"
	@echo "                  is found)."
	@echo "                  Every suite runs even"
	@echo "                  if an earlier one failed"
	@echo "                  TARGET=c23 runs one target; TARGET=c runs every"
	@echo "                  version of that family (the last seven suites are"
	@echo "                  skipped, since none of them is a target)"
	@echo "make stest        the same suite, one test at a time"
	@echo "make playground   serve the web playground (pyk playground), then print"
	@echo "                  a link"
	@echo "make notebook     serve PYKING-TUTORIAL.md as a notebook (pyk notebook),"
	@echo "                  then print a link. PORT=n picks the port for both"
	@echo "make help         serve the help (pyk help) -- getting started, the"
	@echo "                  language reference and the libraries, generated"
	@echo "                  into build/help/ by make -- then print a link"
	@echo "make targets      this list"
	@echo "make vendor       download Ace, KaTeX and Monaco into tools/webrun/vendor/, once"
	@echo "                  (~26 MB; the two above need it and run it first)"
	@echo "make website      build the website (Astro and Starlight, from sitesrc/"
	@echo "                  and lib/) into website/; runs npm ci in tools/site/"
	@echo "                  the first time (needs node 22.12 or later)"
	@echo "make website-dev  the same site, served by Astro's dev server;"
	@echo "                  both need make vendor and run it first"
	@echo "make packaging    build the installable packages into"
	@echo "                  tools/packaging/build/: a universal macOS pyk for"
	@echo "                  Homebrew (on an Apple Silicon Mac), and static"
	@echo "                  Linux ones, tarball and .deb (in Docker)."
	@echo "                  FORMATS=linux or ARCHS=arm64 build part of it"
	@echo "make packaging-setup      make the toolchains make packaging needs"
	@echo "                          (once; FORMATS= as for make packaging)"
	@echo "make packaging-install    install that build here (Homebrew on a Mac,"
	@echo "                          install.sh into ~/.local on Linux)"
	@echo "make packaging-uninstall  and remove it again"
	@echo "make release              publish that build: one release of"
	@echo "                          pyking-lang/pyking-releases with every"
	@echo "                          platform, and the formula in"
	@echo "                          pyking-lang/homebrew-tap, then (asked) the"
	@echo "                          tag release-<VERSION> in pyking-lang/pyking"
	@echo "                          (asks first; YES=1 does not)"
	@echo "make clean        remove generated files: _build/, ./pyk, lib/'s"
	@echo "                  plugins, __pycache__/, tools/packaging/build/,"
	@echo "                  website/ and tools/site/build/"
	@echo "make distclean    also remove tools/webrun/vendor/ and"
	@echo "                  tools/site/node_modules/, the download caches"
	@echo "                  (refetching them needs the network)"
	@echo
	@echo "tools/playground has targets of its own (check, e2e, ...):"
	@echo "run 'make -C tools/playground help' for those."

# The suite's runs are independent of each other -- each compiles into a
# temporary directory of its own -- so it runs them in parallel, one per
# usable CPU unless JOBS= or $PYK_TEST_JOBS says otherwise. What it
# prints does not depend on that: results are reported in the order the
# manifest lists them however they were scheduled, so this and `stest`
# produce the same transcript.
#
# tests/test_repl.py runs after it, and is a suite of its own because it
# runs *sessions* rather than (program, target) pairs: the .pyk suite
# compiles files, so nothing in it reaches the REPL.
# The JavaScript targets run under node, and tests/test_playground.py
# and tests/test_tinyweb.py drive the compiler bundle and Chromium under
# node as well. 22.7 is the oldest node the suites run on: it is the
# first with --no-experimental-detect-module, which every JavaScript
# runner passes, and it has the WebSocket tests/tinyweb/chrome.mjs uses.
# Checked once, here, because a version failure inside a runner reads
# as a broken test rather than as a missing tool. Skipped for a TARGET
# that needs no node at all.
check-node:
	@case "$(TARGET)" in \
	  ""|*node*|*web*) ;; \
	  *) exit 0 ;; \
	esac; \
	if ! command -v node >/dev/null 2>&1; then \
	  echo "make: node not found, and node 22.7 or above is required."; \
	  echo "      The JavaScript targets are node24, web24 and iweb24, and"; \
	  echo "      the playground and tinyweb suites run under node too."; \
	  exit 1; \
	fi; \
	version=$$(node --version 2>&1); \
	major=$$(printf '%s' "$$version" | sed 's/^v//; s/\..*//'); \
	minor=$$(printf '%s' "$$version" | sed 's/^v[0-9]*\.//; s/\..*//'); \
	case "$$major.$$minor" in \
	  .*|*.|*[!0-9.]*) \
	    echo "make: could not read node's version from '$$version'."; \
	    echo "      node 22.7 or above is required."; \
	    exit 1 ;; \
	esac; \
	if [ "$$major" -lt 22 ] || { [ "$$major" -eq 22 ] && [ "$$minor" -lt 7 ]; }; then \
	  echo "make: found node $$version, but node 22.7 or above is required."; \
	  echo "      It is the first node with --no-experimental-detect-module,"; \
	  echo "      which the JavaScript tests pass so that node cannot guess"; \
	  echo "      what the compiler did not declare."; \
	  exit 1; \
	fi

test: check-node build
	@python3 tests/test_all.py $(if $(JOBS),--jobs $(JOBS)) \
		$(if $(TARGET),--target $(TARGET))

# The same suite with no pool at all, for when a parallel run's timing is
# itself in question.
stest: check-node build
	@python3 tests/test_all.py --jobs 1 $(if $(TARGET),--target $(TARGET))

# The two web tools, started the way a user of a distribution starts
# them: through ./pyk, which finds tools/ beside itself and checks that
# Python is new enough. Neither has a build step; both need the browser
# libraries downloaded once, which `vendor` does and then skips.
playground: build vendor
	./pyk playground $(if $(PORT),--port $(PORT))

notebook: build vendor
	./pyk notebook PYKING-TUTORIAL.md $(if $(PORT),--port $(PORT))

vendor:
	@python3 tools/webrun/server.py vendor

# The website: tools/site/site.py stages sitesrc/, the library pages it
# generates from lib/ and the web tools' runtime, then builds them with
# Astro into website/. The page runs the same compiler bundle and the
# same browser libraries the playground does, so both are made first.
website: build vendor
	@python3 tools/site/site.py build

website-dev: build vendor
	@python3 tools/site/site.py dev $(if $(PORT),--port $(PORT))

# The installable packages, built by tools/packaging/'s own Makefile into
# its build/: the compiler as JavaScript and the browser libraries go in
# every package, so both are made first. The executable is rebuilt there,
# once per architecture, in a dune build directory of its own.
packaging: build vendor
	@$(MAKE) --no-print-directory -C tools/packaging $(if $(FORMATS),FORMATS=$(FORMATS)) \
		$(if $(ARCHS),ARCHS=$(ARCHS))

packaging-setup:
	@$(MAKE) --no-print-directory -C tools/packaging setup $(if $(FORMATS),FORMATS=$(FORMATS))

packaging-install:
	@$(MAKE) --no-print-directory -C tools/packaging install-local

packaging-uninstall:
	@$(MAKE) --no-print-directory -C tools/packaging uninstall-local

release:
	@$(MAKE) --no-print-directory -C tools/packaging release $(if $(YES),YES=$(YES))

# What "generated" means here is narrow, and deliberately so: what dune
# built, the copy of the executable beside it, Python's bytecode caches
# (the test harness and the web tools' servers are Python), and the
# packages tools/packaging/ built (delegated to its own Makefile, which
# owns them). The web tools are served from source and build nothing.
#
# Compiled *programs* are left alone. `pyk` writes its output wherever the
# caller asked for it, under names that are ordinary source names in every
# target language -- hello.py, hello.js, Hello.java -- so a rule that
# guessed at them from the filesystem would sooner or later delete a file
# nobody generated. Removing those is the caller's business, since only
# the caller knows which ones they are. ./pyk is the exception that
# shows the rule: `make build` chose that name itself, so this knows it.
clean: clean-build clean-pycache clean-website
	@$(MAKE) --no-print-directory -C tools/packaging clean

# tools/webrun/vendor/ and tools/site/node_modules/ are download caches,
# so they survive `clean` and only go on request -- rebuilding them needs
# the network again.
distclean: clean
	@rm -rf tools/webrun/vendor tools/site/node_modules
	@echo "distclean: removed tools/webrun/vendor/ and tools/site/node_modules/"

# What `dune build` wrote, and the copy of its executable that `make
# build` puts here. Both are this Makefile's own output, under names it
# chose itself -- which is exactly what a *compiled program* is not (see
# the note on `clean` above).
clean-build:
	@rm -rf _build build
	@rm -f pyk lib/*/*_external.cmxs lib/*/*_external.digest
	@echo "clean: removed _build, build/, ./pyk and lib/'s plugins"

# The website and what tools/site/site.py staged for it. Both are names
# this repository chose, like ./pyk.
clean-website:
	@rm -rf website tools/site/build
	@echo "clean: removed website/ and tools/site/build/"

# .venv/ and .git/ are pruned rather than filtered: their caches belong to
# installed packages and to git, not to anything this repository builds,
# and .venv in particular holds enough files for the walk to be worth
# skipping outright.
clean-pycache:
	@find . -name .venv -prune -o -name .git -prune -o \
		-name __pycache__ -type d -prune -exec rm -rf {} +
	@echo "clean: removed __pycache__ directories"
