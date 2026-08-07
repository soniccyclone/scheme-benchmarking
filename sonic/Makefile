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
	@$(CHEZ) -q $(LIBS) --script test/rv64-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/x86-64-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/lower-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/callconv-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/alloc-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/loops-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/twoaddr-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/object-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/peephole-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/gc-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/escape-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/litpool-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/assign-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/distinct-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/parse-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/reloc-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/pipeline-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/emit-nbody-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/abcd-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/elide-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/anf-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/policy-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/differential-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/disasm-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/repr-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/callseq-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/pentagon-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/veclegal-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/parcopy-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/vec-x86-64-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/vec-rv64-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/interval-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/analyze-test.ss

clean:
	@find . -name '*.so' -delete
