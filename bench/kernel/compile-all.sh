#!/usr/bin/env bash
# What every program in this directory asks for that the compiler does not have.
#
# These programs are EXPECTED TO FAIL today. The failure list is the deliverable:
# it is the queue, in the order the compiler discovers it, rather than in the
# order somebody guessed. When one starts compiling, that is a feature landing,
# and this run is the evidence.
#
# The real work is in `missing.ss`, which feeds each complaint back as an extern
# and asks again, so a program reports EVERY name it wants rather than whichever
# one the parser reached first. A single first-complaint-per-file run is an
# accident of traversal order, not a ranking.
#
# Nothing runs on the host -- see CLAUDE.md. This starts a Chez process, so it
# re-execs into the container the way tools/diff-run.sh does.
set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
. "$here/tools/container.sh"
sonic_reexec sonic bash /work/bench/kernel/compile-all.sh "$@"

exec timeout 600 scheme -q \
     --libdirs /work/sonic/src:/work/sonic/vendor/nanopass \
     --script /work/bench/kernel/missing.ss
