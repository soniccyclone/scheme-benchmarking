# SonicScheme
#
# NOTHING RUNS ON THE HOST. `make test` builds the image if needed and runs the
# suite inside it, under the memory and wall-clock limits in
# ../tools/container.sh.
#
# That is not tidiness. An unguarded loop in a compiler pass once consed until a
# single Chez process held 31GB -- the whole WSL VM -- and the OOM killer took
# everything else with it, three times. A limit you have to remember to apply is
# a limit that fails exactly when a bug is already eating the machine. The
# container carries its own.
#
# `test-suite` is the real work and refuses to run outside a container, so there
# is ONE way to run the tests and no second path for anyone to reach for.

CHEZ ?= scheme
LIBS  = --libdirs src:vendor/nanopass
# The limits still live in ../docker-compose.yml (D30). This goes through
# tools/container.sh so that ONE place picks the engine -- `podman compose`
# here, `docker compose` in CI -- and so that the limits are verified from
# inside the cgroup before anything runs. See D58.
RUN  ?= ../tools/container.sh

.PHONY: help test test-suite shell clean

help:
	@echo "make test        run the suite in its container (the only way)"
	@echo "make shell       a shell in that container"
	@echo "make test-suite  the suite itself -- refuses to run outside a container"
	@echo "make clean       remove compiled artifacts"

test:
	@$(RUN) make test-suite

shell:
	@$(RUN) --shell

# The guard is mechanical rather than a comment, because a comment is advice and
# this needs to be a wall: an agent reaching for `make test-suite` on the host is
# reaching for the thing that took the machine down.
#
# It tests for BOTH engines' markers. Docker writes /.dockerenv and podman
# writes /run/.containerenv; when the host moved to podman this guard rejected
# the container it was standing inside, which is the failure mode of hardcoding
# one engine's implementation detail as if it meant "am I contained".
test-suite:
	@$(RUN) --assert-inside
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
	@$(CHEZ) -q $(LIBS) --script test/clobber-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/unroll-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/addrfold-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/slp-test.ss
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
	@$(CHEZ) -q $(LIBS) --script test/run-x86-64-test.ss
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
	@$(CHEZ) -q $(LIBS) --script test/convert-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/callseq-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/pentagon-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/veclegal-test.ss
	@echo
	@$(CHEZ) -q $(LIBS) --script test/vectorize-test.ss
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
	@echo
	@$(CHEZ) -q $(LIBS) --script test/shapes-test.ss

clean:
	@find . -name '*.so' -delete
