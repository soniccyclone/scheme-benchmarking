# scheme-benchmarking

.PHONY: help setup build clean guard test smoke bench containment

help:
	@echo "make setup       everything a fresh clone needs before make test works"
	@echo "make build       build the toolchain image, deliberately rather than mid-test"
	@echo "make clean       remove build artifacts (not the image)"
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

# DELIBERATELY, RATHER THAN AS A SURPRISE. The image builds Chez from source, so
# the first `make test` on a fresh clone stalls for several minutes with no
# explanation -- which reads like a hung test rather than a one-time compile.
# Nothing else needs this target: compose builds the image on demand, so it is
# here to make the cost visible and schedulable.
build:
	@$(if $(shell command -v podman 2>/dev/null),podman,docker) build -t sonic-scheme:dev .

# The BUILD DIRECTORY, not the image. Benchmark artifacts accumulate -- compiled
# cores, .fas and .zo files, emitted binaries, one subdirectory per benchmark --
# and are all reproducible from `harness/compile.sh`. The image is left alone
# because rebuilding it costs a Chez compile; `podman rmi sonic-scheme:dev` if
# that is what you meant.
clean:
	@rm -rf build
	@$(MAKE) -C sonic -s clean
	@echo "[clean] removed build/ and compiled Scheme artifacts"

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
