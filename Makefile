# The Pyking compiler.
#
#   make            build the compiler and build/pyking.js
#   make test       the compiler's own test suite, run in parallel
#                   (TARGET=c23 or TARGET=c for one target or family)
#   make stest      the same suite, one test at a time
#   make clean      remove what has been generated
#
# Run `make help` for the full list. The compiler is OCaml in src/,
# built by dune into the executable this directory calls ./pyk.

.PHONY: all help build test stest playground clean clean-pycache clean-build \
	distclean

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
	@mkdir -p build
	@cp -f _build/default/src/web/pyking_web.bc.js build/pyking.js
	@echo "build: ./pyk and build/pyking.js"

# Kept in the same shape as `make -C tools/playground help`, so the two
# read alike. Both are hand-written and neither has anything to generate
# them from, so update this list whenever a target is added or renamed.
help:
	@echo "make              build the compiler into ./pyk"
	@echo "make test         the compiler's own suite: every tests/*.pyk on every"
	@echo "                  target tests/test_cases.toml lists it for, run in"
	@echo "                  parallel (JOBS=n to say how parallel), then the"
	@echo "                  REPL's own cases in tests/repl/"
	@echo "                  TARGET=c23 runs one target; TARGET=c runs every"
	@echo "                  version of that family"
	@echo "make stest        the same suite, one test at a time"
	@echo "make playground   build and serve the web playground, then print a link"
	@echo "make clean        remove generated files: _build/, ./pyk, __pycache__/"
	@echo "                  and the playground's build/"
	@echo "make distclean    also remove the playground's vendor/ download cache"
	@echo "                  (~1 MB; refetching it needs the network)"
	@echo
	@echo "tools/playground has options of its own (PORT=, CDN=, ...):"
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
test: build
	python3 tests/test_script.py $(if $(JOBS),--jobs $(JOBS)) \
		$(if $(TARGET),--target $(TARGET))
	@if [ -z "$(TARGET)" ]; then python3 tests/test_repl.py; \
	else echo "repl: skipped (TARGET=$(TARGET) selected)"; fi

# The same suite with no pool at all, for when a parallel run's timing is
# itself in question.
stest: build
	python3 tests/test_script.py --jobs 1 $(if $(TARGET),--target $(TARGET))
	@if [ -z "$(TARGET)" ]; then python3 tests/test_repl.py; \
	else echo "repl: skipped (TARGET=$(TARGET) selected)"; fi

# Delegates entirely to tools/playground's own Makefile (its default
# target: vendor, build, check, then serve and print a URL). `-C` runs
# make with that directory as its cwd, which is what keeps every file
# generator.py writes (build/, vendor/) inside tools/playground instead
# of wherever `make playground` happened to be invoked from.
playground:
	$(MAKE) -C tools/playground

# What "generated" means here is narrow, and deliberately so: what dune
# built, the copy of the executable beside it, Python's bytecode caches
# (the test harness and the playground generator are Python), and
# whatever tools/playground built (delegated to its own Makefile, which
# owns those files -- see the `-C` note above).
#
# Compiled *programs* are left alone. `pyk` writes its output wherever the
# caller asked for it, under names that are ordinary source names in every
# target language -- hello.py, hello.js, Hello.java -- so a rule that
# guessed at them from the filesystem would sooner or later delete a file
# nobody generated. Removing those is the caller's business, since only
# the caller knows which ones they are. ./pyk is the exception that
# shows the rule: `make build` chose that name itself, so this knows it.
clean: clean-build clean-pycache
	@$(MAKE) --no-print-directory -C tools/playground clean

# `distclean` depends on these rather than on `clean`, so that the
# playground's own `distclean` -- which already runs its `clean` first --
# is invoked exactly once and reports each removal exactly once.
distclean: clean-build clean-pycache
	@$(MAKE) --no-print-directory -C tools/playground distclean

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
