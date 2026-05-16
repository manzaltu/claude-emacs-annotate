EMACS ?= emacs

EL_FILES := $(wildcard lisp/*.el)
TEST_FILES := $(wildcard test/*-test.el)

.PHONY: all compile checkdoc test clean

all: compile checkdoc test

test:
	$(EMACS) -Q -batch -L lisp -L test \
	  --eval "(setq load-prefer-newer t)" \
	  $(patsubst %,-l %,$(TEST_FILES)) \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q -batch -L lisp \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(EL_FILES)

checkdoc:
	$(EMACS) -Q -batch -l test/checkdoc-batch.el $(EL_FILES)

clean:
	rm -f lisp/*.elc
