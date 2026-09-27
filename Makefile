# The Pyking compiler.
#
#   make            build the compiler and build/pyking.js
#   make test       the compiler's own test suite, run in parallel
#                   (TARGET=c23 or TARGET=c for one target or family)
#   make stest      the same suite, one test at a time
#   make notebook   open PYKING-TUTORIAL.md as a notebook in the browser
#   make clean      remove what has been generated
#
# Run `make help` for the full list. The compiler is OCaml in src/,
# built by dune into the executable this directory calls ./pyk.

.PHONY: all help build test stest check-node playground notebook vendor \
	clean clean-pycache clean-build distclean

# `make` builds the compiler: it is the one thing someone typing `make`
# in a compiler's directory is asking for.
all: build

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
	@mkdir -p build
	@cp -f _build/default/src/web/pyking_web.bc.js build/pyking.js
	@echo "build: ./pyk and build/pyking.js"

# Kept in the same shape as `make -C tools/playground help`, so the two
# read alike. Both are hand-written and neither has anything to generate
# them from, so update this list whenever a target is added or renamed.
help:
	@echo "make              build the compiler into ./pyk"
	@echo "make test         all five suites, then a combined summary: every"
	@echo "                  tests/*.pyk on every target tests/test_cases.toml"
	@echo "                  lists it for, run in parallel (JOBS=n to say how"
	@echo "                  parallel), then the REPL's own cases in tests/repl/,"
	@echo "                  then the library search path's, then the"
	@echo "                  playground's compiler bundle, then the notebook's"
	@echo "                  renderer and server. Every suite runs even"
	@echo "                  if an earlier one failed"
	@echo "                  TARGET=c23 runs one target; TARGET=c runs every"
	@echo "                  version of that family (the last four suites are"
	@echo "                  skipped, since none of them is a target)"
	@echo "make stest        the same suite, one test at a time"
	@echo "make playground   serve the web playground (pyk playground), then print"
	@echo "                  a link"
	@echo "make notebook     serve PYKING-TUTORIAL.md as a notebook (pyk notebook),"
	@echo "                  then print a link. PORT=n picks the port for both"
	@echo "make vendor       download Ace and KaTeX into tools/webrun/vendor/, once"
	@echo "                  (~1 MB; the two above need it and run it first)"
	@echo "make clean        remove generated files: _build/, ./pyk, __pycache__/"
	@echo "make distclean    also remove tools/webrun/vendor/, the download cache"
	@echo "                  (refetching it needs the network)"
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
# The JavaScript targets are named for the node they promise to run on
# -- node24, web24, iweb24 -- and tests/test_playground.py drives the
# compiler bundle under node as well, so an older one cannot run any of
# it. Checked once, here, because a version failure inside a runner
# reads as a broken test rather than as a missing tool. Skipped for a
# TARGET that needs no node at all.
check-node:
	@case "$(TARGET)" in \
	  ""|*node*|*web*) ;; \
	  *) exit 0 ;; \
	esac; \
	if ! command -v node >/dev/null 2>&1; then \
	  echo "make: node not found, and node 24 or above is required."; \
	  echo "      The JavaScript targets are node24, web24 and iweb24, and"; \
	  echo "      the playground suite runs the compiler under node too."; \
	  exit 1; \
	fi; \
	version=$$(node --version 2>&1); \
	major=$$(printf '%s' "$$version" | sed 's/^v//; s/\..*//'); \
	case "$$major" in \
	  ''|*[!0-9]*) \
	    echo "make: could not read node's version from '$$version'."; \
	    echo "      node 24 or above is required."; \
	    exit 1 ;; \
	esac; \
	if [ "$$major" -lt 24 ]; then \
	  echo "make: found node $$version, but node 24 or above is required."; \
	  echo "      The JavaScript targets are named for it -- node24, web24"; \
	  echo "      and iweb24 -- and the playground suite runs the compiler"; \
	  echo "      under node too."; \
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

# What "generated" means here is narrow, and deliberately so: what dune
# built, the copy of the executable beside it, Python's bytecode caches
# (the test harness and the web tools' servers are Python), and nothing
# else: the web tools are served from source and build nothing.
#
# Compiled *programs* are left alone. `pyk` writes its output wherever the
# caller asked for it, under names that are ordinary source names in every
# target language -- hello.py, hello.js, Hello.java -- so a rule that
# guessed at them from the filesystem would sooner or later delete a file
# nobody generated. Removing those is the caller's business, since only
# the caller knows which ones they are. ./pyk is the exception that
# shows the rule: `make build` chose that name itself, so this knows it.
clean: clean-build clean-pycache

# tools/webrun/vendor/ is a download cache, so it survives `clean` and
# only goes on request -- rebuilding it needs the network again.
distclean: clean
	@rm -rf tools/webrun/vendor
	@echo "distclean: removed tools/webrun/vendor/"

# What `dune build` wrote, and the copy of its executable that `make
# build` puts here. Both are this Makefile's own output, under names it
# chose itself -- which is exactly what a *compiled program* is not (see
# the note on `clean` above).
clean-build:
	@rm -rf _build build
	@rm -f pyk
	@echo "clean: removed _build, build/ and ./pyk"

# .venv/ and .git/ are pruned rather than filtered: their caches belong to
# installed packages and to git, not to anything this repository builds,
# and .venv in particular holds enough files for the walk to be worth
# skipping outright.
clean-pycache:
	@find . -name .venv -prune -o -name .git -prune -o \
		-name __pycache__ -type d -prune -exec rm -rf {} +
	@echo "clean: removed __pycache__ directories"
