# SonicScheme

CHEZ ?= scheme
LIBS  = --libdirs src:vendor/nanopass

.PHONY: help test clean

help:
	@echo "make test   run the test suite"
	@echo "make clean  remove compiled artifacts"

test:
	@$(CHEZ) -q $(LIBS) --script test/lang-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/read-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/numeric-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/fixtures-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/gcmeta-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/gcell-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/preempt-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/select-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/regalloc-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/essa-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/emit-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/expand-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/alias-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/inline-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/interval-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/analyze-test.ss

clean:
	@find . -name '*.so' -delete
