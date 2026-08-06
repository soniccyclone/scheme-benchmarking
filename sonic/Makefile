# SonicScheme

CHEZ ?= scheme
LIBS  = --libdirs src

.PHONY: help test clean

help:
	@echo "make test   run the test suite"
	@echo "make clean  remove compiled artifacts"

test:
	@$(CHEZ) -q $(LIBS) --script test/interval-test.ss

clean:
	@find . -name '*.so' -delete
