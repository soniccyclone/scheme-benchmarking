#!/usr/bin/env bash
# Everything a fresh clone needs before `make test` can work, and nothing else.
#
# WHY THIS EXISTS. Three of the four prerequisites live OUTSIDE the repository,
# so cloning it is not enough and the failures are not obvious:
#
#   THE COMPOSE PROVIDER. `podman compose` is a shim that shells out to
#   docker-compose or podman-compose if one is on PATH. Podman ships neither. A
#   clone without one fails at the first `make test` with "looking up compose
#   provider failed", which reads like a podman installation problem rather than
#   a missing package.
#
#   THE SUBMODULE. sonic/vendor/nanopass is a submodule, and a clone without
#   --recursive leaves the directory empty. The failure is "Exception: library
#   (nanopass) not found", four stages into a compile, which reads like a
#   compiler bug.
#
#   THE PUSH GUARD. It lives in .git/modules/... which is LOCAL CONFIG AND IS
#   NOT CLONED. Without it, an accidental push to somebody else's project
#   succeeds. See the hard rule at the top of CLAUDE.md.
#
# NO SUDO, and that is a project rule rather than a preference. podman-compose
# is a Python program, so it goes in a venv under ~/.local/opt with a symlink on
# PATH. Homebrew has the formula and it is DECLINED: it depends on the `podman`
# formula, so it would install a second podman beside the system one, and two
# podmans is the same shape of mistake as two ways to run the tests.
#
# IDEMPOTENT. Every step checks before acting, so running it twice is free and
# running it after a partial failure resumes.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ok()   { printf '  [ok]   %s\n' "$1"; }
did()  { printf '  [did]  %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1" >&2; exit 1; }

echo "container engine"
if command -v podman >/dev/null 2>&1; then ok "podman $(podman --version | awk '{print $3}')"
elif command -v docker >/dev/null 2>&1; then ok "docker present"
else fail "install podman (or docker); nothing in this tree runs on the host"; fi

echo "compose provider"
if podman compose version >/dev/null 2>&1 || docker compose version >/dev/null 2>&1; then
    ok "a compose provider is already resolvable"
else
    VENV="$HOME/.local/opt/podman-compose"
    if [ ! -x "$VENV/bin/podman-compose" ]; then
        # Ubuntu's system python has no ensurepip and is marked
        # externally-managed, so `python3 -m venv` fails outright there. Any
        # python with ensurepip will do; brew's is the one this host has.
        PY=""
        for cand in /home/linuxbrew/.linuxbrew/bin/python3 python3.13 python3.12 python3; do
            if command -v "$cand" >/dev/null 2>&1 &&
               "$cand" -c 'import ensurepip' >/dev/null 2>&1; then PY="$cand"; break; fi
        done
        [ -n "$PY" ] || fail "no python with ensurepip; install python3-venv or use brew's python"
        "$PY" -m venv "$VENV" >/dev/null 2>&1 || fail "could not create $VENV"
        "$VENV/bin/pip" install --quiet podman-compose >/dev/null 2>&1 \
            || fail "pip could not install podman-compose into $VENV"
        did "installed podman-compose into $VENV"
    else
        ok "podman-compose already in $VENV"
    fi
    mkdir -p "$HOME/.local/bin"
    ln -sf "$VENV/bin/podman-compose" "$HOME/.local/bin/podman-compose"
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) did "symlinked into ~/.local/bin, which is on PATH" ;;
        *) printf '  [WARN] ~/.local/bin is NOT on your PATH; `podman compose` will not find it\n' ;;
    esac
fi

echo "nanopass submodule"
if [ -f "$here/sonic/vendor/nanopass/nanopass.sls" ] ||
   [ -n "$(ls -A "$here/sonic/vendor/nanopass" 2>/dev/null)" ]; then
    ok "present at $(git -C "$here" submodule status | awk '{print $1}' | cut -c1-8)"
else
    git -C "$here" submodule update --init --recursive >/dev/null 2>&1 \
        || fail "git submodule update --init --recursive"
    did "checked out sonic/vendor/nanopass"
fi

echo "no-push-upstream guard"
# Re-applied unconditionally: it is local config, it is not cloned, and it is
# cheap. The hard rule it enforces is that we never push to a repo Nathan does
# not own.
make -C "$here" -s guard
ok "verified: $(git -C "$here/sonic/vendor/nanopass" config --get remote.origin.pushurl)"

echo
# SINGLE QUOTES. Backticks inside double quotes are command substitution, and the
# first version of this line ran the entire test suite to print a sentence about
# it -- the third time this session a backtick in prose executed something.
echo 'ready. `make test` builds the image on first run (Chez is compiled from'
echo 'source, so expect several minutes once), then runs the suite in it.'
