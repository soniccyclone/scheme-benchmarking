# scheme-benchmarking

.PHONY: help setup guard test smoke bench containment

help:
	@echo "make setup       everything a fresh clone needs before make test works"
	@echo "make guard       re-apply the no-push-upstream guard on vendored submodules"
	@echo "make test        run the SonicScheme test suite"
	@echo "make containment prove the container limits actually hold"
	@echo "make smoke       run the RISC-V smoke gate"
	@echo "make bench       wall-clock benchmark with bootstrap CIs"

# D30 declared the limits and nothing ever checked them. This tries to violate
# each one -- memory runaway, fork bomb, infinite loop -- and fails if any
# succeeds. Run it after touching docker-compose.yml or tools/container.sh.
containment:
	@./tools/test-containment.sh

# THREE OF THE FOUR PREREQUISITES LIVE OUTSIDE THIS REPOSITORY, so cloning it is
# not enough: podman ships no compose provider, sonic/vendor/nanopass is a
# submodule, and the push guard is local git config that is never cloned. Each
# failure reads like something else -- a podman problem, a compiler bug, or
# nothing at all until an accidental push succeeds.
setup:
	@./tools/setup.sh

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
