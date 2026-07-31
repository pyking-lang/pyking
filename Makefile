.PHONY: test all test-py2pyk playground

all:

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
