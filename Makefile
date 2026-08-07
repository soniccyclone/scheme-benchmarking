# scheme-benchmarking

.PHONY: help guard test smoke bench

help:
	@echo "make guard  re-apply the no-push-upstream guard on vendored submodules"
	@echo "make test   run the SonicScheme test suite"
	@echo "make smoke  run the RISC-V smoke gate"
	@echo "make bench  wall-clock benchmark with bootstrap CIs"

# The guard lives in local git config and is NOT cloned. Re-apply after any
# fresh clone or `git submodule update --init`. See the hard rule in CLAUDE.md.
guard:
	@git -C sonic/vendor/nanopass config remote.origin.pushurl \
		"NO-PUSH-UPSTREAM--ask-Nathan-first--see-CLAUDE.md" 2>/dev/null \
		&& echo "[guard] nanopass push disabled" \
		|| echo "[guard] nanopass submodule not initialised, nothing to guard"

test:
	@$(MAKE) -C sonic test

smoke:
	@./harness/smoke-riscv.sh

bench:
	@./harness/bench.sh
