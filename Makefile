# scheme-benchmarking

.PHONY: help setup build clean guard test smoke bench containment

help:
	@echo "make setup       everything a fresh clone needs before make test works"
	@echo "make build       build the toolchain image, deliberately rather than mid-test"
	@echo "make clean       remove build artifacts (not the image)"
	@echo "make guard       re-apply local git state a clone does not carry: the"
	@echo "                 submodule no-push guard, and the beads export"
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
# LOCAL GIT STATE THAT IS NOT CLONED, RE-APPLIED.
#
# Both halves exist because `.git/` does not travel. The nanopass pushurl lives
# in `.git/modules/`, and git hooks live in `.git/hooks/`, so a fresh clone or a
# move between machines silently loses them -- which is what happened when this
# host went from WSL+Docker to native Ubuntu.
guard:
	@git -C sonic/vendor/nanopass config remote.origin.pushurl \
		"NO-PUSH-UPSTREAM--ask-Nathan-first--see-CLAUDE.md" 2>/dev/null \
		&& echo "[guard] nanopass push disabled" \
		|| echo "[guard] nanopass submodule not initialised, nothing to guard"
	@# The beads export is the SHAREABLE copy; the Dolt DB under
	@# .beads/embeddeddolt/ is gitignored, and CLAUDE.md records that beads
	@# recovered from this file when the host moved. It went six days and 46
	@# issues stale because nothing refreshes it. Refreshing is idempotent, so
	@# it runs every time rather than being conditional on noticing.
	@# NEVER SHRINKS THE FILE, and that guard is not paranoia. The export is
	@# git-tracked and the Dolt DB is not, so on a FRESH CLONE the database does
	@# not exist yet -- and `tools/setup.sh` runs this target. An export from an
	@# empty database would write zero issues over the committed graph, which is
	@# the recovery path CLAUDE.md says beads restored itself from when this host
	@# moved. Writing to a temporary file and comparing counts first costs
	@# nothing and makes the failure impossible rather than unlikely.
	@if command -v bd >/dev/null 2>&1; then \
		tmp=$$(mktemp); \
		if bd export -o "$$tmp" >/dev/null 2>&1; then \
			new=$$(grep -c '' "$$tmp" 2>/dev/null || echo 0); \
			old=$$(grep -c '' .beads/issues.jsonl 2>/dev/null || echo 0); \
			if [ "$$new" -ge "$$old" ] && [ "$$new" -gt 0 ]; then \
				mv "$$tmp" .beads/issues.jsonl; \
				echo "[guard] beads export refreshed ($$new issues)"; \
			else \
				rm -f "$$tmp"; \
				echo "[guard] beads export REFUSED: database has $$new issues, the"; \
				echo "        committed export has $$old. Not overwriting. If the"; \
				echo "        database is empty this is a fresh clone -- run any bd"; \
				echo "        command to import, then re-run make guard."; \
			fi; \
		else rm -f "$$tmp"; echo "[guard] beads export FAILED -- .beads/issues.jsonl may be stale"; fi; \
	else echo "[guard] bd not on PATH, beads export not refreshed"; fi
	@# Hooks are NOT installed here. `bd hooks install` also adds
	@# prepare-commit-msg, which rewrites commit messages with agent identity
	@# trailers, and that is a change to how Nathan's own commits look rather
	@# than a guard. Reported so the choice is visible.
	@if command -v bd >/dev/null 2>&1 && bd hooks list 2>/dev/null | grep -q "not installed"; then \
		echo "[guard] beads git hooks are NOT installed; 'bd hooks install' if you want them"; fi

test:
	@$(MAKE) -C sonic test

smoke:
	@./harness/smoke-riscv.sh

bench:
	@./harness/bench.sh
