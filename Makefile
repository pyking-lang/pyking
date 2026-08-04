# The Pyking compiler.
#
#   make            this help
#   make test       the compiler's own test suite
#   make clean      remove what has been generated
#
# Run `make help` for the full list. There is no build rule: the compiler
# is a set of Python scripts run in place (see ./pyk), so nothing here
# produces the compiler itself.

.PHONY: all help test test-py2pyk playground clean clean-pycache distclean

# A bare `make` prints the help rather than building anything. There is
# nothing to build, so someone typing `make` is almost always asking what
# they *can* do -- which is exactly what `help` answers.
all: help

# Kept in the same shape as `make -C tools/playground help`, so the two
# read alike. Both are hand-written and neither has anything to generate
# them from, so update this list whenever a target is added or renamed.
help:
	@echo "make              this help"
	@echo "make test         the compiler's own suite: every tests/*.pyk on every"
	@echo "                  target tests/test_cases.toml lists it for"
	@echo "make test-py2pyk  the tools/py2pyk suite: each .py translated to Pyking,"
	@echo "                  compiled back, run and diffed"
	@echo "make playground   build and serve the web playground, then print a link"
	@echo "make clean        remove generated files: __pycache__/ and the"
	@echo "                  playground's build/"
	@echo "make distclean    also remove the playground's vendor/ download cache"
	@echo "                  (~13 MB; refetching it needs the network)"
	@echo
	@echo "tools/playground has options of its own (PORT=, CDN=, ...):"
	@echo "run 'make -C tools/playground help' for those."

test:
	python3 tests/test_script.py

# Delegates entirely to tools/py2pyk's own Makefile; see that file for
# what "test" means there (translating tools/py2pyk/tests/*.py to Pyking
# and back, diffing stdout).
test-py2pyk:
	$(MAKE) -C tools/py2pyk test

# Delegates entirely to tools/playground's own Makefile (its default
# target: vendor, build, check, then serve and print a URL). `-C` runs
# make with that directory as its cwd, which is what keeps every file
# generator.py writes (build/, vendor/) inside tools/playground instead
# of wherever `make playground` happened to be invoked from.
playground:
	$(MAKE) -C tools/playground

# What "generated" means here is narrow, and deliberately so: Python's own
# bytecode caches, and whatever tools/playground built (delegated to its
# own Makefile, which owns those files -- see the `-C` note above).
#
# Compiled *programs* are left alone. `pyk` writes its output wherever the
# caller asked for it, under names that are ordinary source names in every
# target language -- hello.py, hello.js, Hello.java -- so a rule that
# guessed at them from the filesystem would sooner or later delete a file
# nobody generated. Removing those is the caller's business, since only
# the caller knows which ones they are.
clean: clean-pycache
	@$(MAKE) --no-print-directory -C tools/playground clean

# `distclean` depends on this rather than on `clean`, so that the
# playground's own `distclean` -- which already runs its `clean` first --
# is invoked exactly once and reports each removal exactly once.
distclean: clean-pycache
	@$(MAKE) --no-print-directory -C tools/playground distclean

# .venv/ and .git/ are pruned rather than filtered: their caches belong to
# installed packages and to git, not to anything this repository builds,
# and .venv in particular holds enough files for the walk to be worth
# skipping outright.
clean-pycache:
	@find . -name .venv -prune -o -name .git -prune -o \
		-name __pycache__ -type d -prune -exec rm -rf {} +
	@echo "clean: removed __pycache__ directories"
