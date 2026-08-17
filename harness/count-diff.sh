#!/usr/bin/env bash
# Localise a disagreement between our two instruction counters to an ADDRESS.
#
# WHY THIS EXISTS. callgrind and qemu-count.sh once agreed to +0.0000% on gcc's
# output and differed by 6.17% on ours -- a stable 41 instructions per step that
# no N washed out (D68/D72, bead qaq.11). Two totals cannot tell you WHERE they
# differ, and every cheaper hypothesis had already been eliminated by comparing
# aggregates: the block byte stream matched the file exactly, no block executions
# went uncounted, and the slope cancels startup.
#
# So this compares them PER INSTRUCTION ADDRESS, and that is what found it. 954
# addresses agreed; 114 were counted by qemu and given zero by callgrind; NOTHING
# went the other way. callgrind's address set being a strict SUBSET of ours is
# the signature of over-decoding, not of a disagreement about execution -- and
# the cause was objdump wrapping any instruction longer than 7 bytes onto a
# continuation line that carries an address but no mnemonic, which qemu-count.sh
# was counting as a second instruction.
#
# KEEP IT. The two agree now, but this is the tool that turns "these two large
# numbers differ" into "they differ at THIS address", which is the only form of
# the question that was ever answerable.
#
#   harness/count-diff.sh <absolute-binary> [args...]
#
# Reading the output: an address where qemu is HIGHER is one qemu thinks ran more
# often, or one callgrind never attributed. Look it up with
# `objdump -D --start-address=... build/nbody/sonic` -- and note our emitted ELF
# has NO SECTION HEADERS, so plain `objdump -d` prints nothing and exits 0.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

. "$here/tools/container.sh"
sonic_reexec sonic bash /work/harness/count-diff.sh "$@"

BIN=${1:-}
[ -n "$BIN" ] || { echo "usage: count-diff.sh <absolute-binary> [args...]" >&2; exit 2; }
case "$BIN" in
  /*) ;;
  *) echo "REFUSED: qemu-user needs an absolute path; got '$BIN'." >&2; exit 2 ;;
esac
[ -x "$BIN" ] || { echo "not executable: $BIN" >&2; exit 2; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

valgrind --tool=callgrind --dump-instr=yes --dump-line=no \
         --callgrind-out-file="$W/cg.out" "$@" >/dev/null 2>"$W/cg.err" || true
grep -q 'unhandled instruction' "$W/cg.err" && {
    echo "REFUSED: callgrind could not decode an instruction in $BIN." >&2; exit 1; }
[ -s "$W/cg.out" ] || { echo "callgrind produced no dump" >&2; exit 1; }

qemu-x86_64 -d in_asm,exec,nochain -D "$W/q.log" "$@" >/dev/null 2>"$W/q.err"
grep -q 'uncaught target signal' "$W/q.err" && {
    echo "REFUSED: $BIN did not run to completion under qemu." >&2; exit 1; }
[ -s "$W/q.log" ] || { echo "qemu produced no log" >&2; exit 1; }

python3 "$here/harness/count-diff.py" "$W"
