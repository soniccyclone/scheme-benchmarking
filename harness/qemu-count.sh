#!/usr/bin/env bash
# Exact instruction counts under QEMU, for the configurations callgrind cannot
# run at all.
#
# WHY A SECOND COUNTER EXISTS. harness/count-instructions.sh uses callgrind,
# which is deterministic and exact and crashes outright on four of this
# project's nineteen configurations -- racket, sbcl, ecl and clisp, the
# managed-runtime Lisps. On sbcl it does not decline, it hits its own internal
# assertion and prints the "send all the above text in the bug report" banner.
# That left the instruction arm of every milestone naming one of them
# unmeasurable (bead qaq.10).
#
# QEMU runs all four. Measured, each producing the correct energies:
#
#     sbcl-5    /usr/bin/sbcl     -0.169075164
#     racket-4  /usr/bin/racket   -0.16907516382852447
#     ecl-9     /usr/bin/ecl      -0.169075164
#     clisp-9   /usr/bin/clisp    -0.169075164
#
# HOW IT COUNTS. QEMU translates the guest a basic block at a time and can log
# both halves: `-d in_asm` emits one record per translated block, and `-d exec`
# one line per block EXECUTION. Guest instruction count is therefore
# sum over blocks of (times executed x instructions in block), which is exact
# and deterministic -- the same class of measurement callgrind gives, by a
# different route.
#
# The awkward part is that Ubuntu's qemu is built with no disassembler linked
# in, so `in_asm` prints `OBJD-T:` raw hex rather than one line per
# instruction. The bytes are enough: objdump decodes them, and the instruction
# count per block is however many it finds.
#
# TWO INVOCATION TRAPS, both of which produce a confident wrong answer rather
# than an error, and both of which caught me:
#
#   - qemu-user needs an ABSOLUTE PATH to the program. A bare name that the
#     shell would have found on PATH simply fails, and a whole matrix reports
#     "does not run", which reads exactly like a real limitation.
#   - the `env VAR=value` prefix that configs.sh emits must be PRESERVED.
#     Stripping it runs the program with no N.
#
#   harness/qemu-count.sh <absolute-binary> [args...]
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

. "$here/tools/container.sh"
sonic_reexec sonic bash /work/harness/qemu-count.sh "$@"

BIN=${1:-}
[ -n "$BIN" ] || { echo "usage: qemu-count.sh <absolute-binary> [args...]"; exit 2; }
case "$BIN" in
  /*) ;;
  *) echo "REFUSED: qemu-user needs an absolute path; got '$BIN'." >&2
     echo "A bare name fails silently and looks like the program cannot run." >&2
     exit 2 ;;
esac
[ -x "$BIN" ] || { echo "not executable: $BIN"; exit 2; }
shift

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# `nochain` IS LOAD-BEARING AND ITS ABSENCE IS SILENT. QEMU links translated
# blocks together and then jumps between them directly, without logging -- so
# `-d exec` alone counts only the executions that happen to cross an unlinked
# edge. Cross-checked against callgrind on one gcc binary: 29,396 against
# 243,031, an eight-fold undercount that looks like a plausible number.
# qemu's own help for the flag says it plainly: "do not chain compiled TBs so
# that exec and cpu show".
qemu-x86_64 -d in_asm,exec,nochain -D "$WORK/q.log" "$BIN" "$@" \
    >/dev/null 2>"$WORK/q.err"
rc=$?

[ -s "$WORK/q.log" ] || { echo "qemu produced no log for $BIN" >&2; exit 1; }

# A CRASHED RUN STILL LEAVES A LOG, AND COUNTING IT GIVES A PLAUSIBLE NUMBER.
# This is the trap callgrind falls into on the same binaries: it prints
# "unhandled instruction" AND an `I refs:` total, and that total is the count up
# to the failure. Reading it as the program's instruction count is silently
# wrong.
#
# Measured here: `gcc -O3 -march=native` emits AVX-512 on this host, QEMU's TCG
# does not implement AVX-512, and c-native dies with "uncaught target signal 4
# (Illegal instruction)". The partial count was 103,015 -- and IDENTICAL at
# N=200, 400 and 800, because the program always dies in the same place. That
# invariance is the only thing that gave it away.
if grep -q 'uncaught target signal' "$WORK/q.err"; then
    echo "REFUSED: $BIN did not run to completion under qemu." >&2
    grep 'uncaught target signal' "$WORK/q.err" | head -1 >&2
    echo "Counting a crashed run yields a partial total that looks like a real" >&2
    echo "one and does not vary with N. QEMU's TCG does not implement AVX-512," >&2
    echo "so anything built with -march=native on this host lands here." >&2
    exit 1
fi
if [ "$rc" -ne 0 ]; then
    echo "REFUSED: $BIN exited $rc under qemu; a partial count is not a count." >&2
    exit 1
fi

python3 - "$WORK/q.log" "$WORK" <<'PY'
import sys, re, subprocess, collections, os

log, work = sys.argv[1], sys.argv[2]

# in_asm: a block is "IN:" then "0x<addr>:" then one or more "OBJD-T: <hex>".
# exec:   "Trace 0: 0x<host> [.../<guest-pc>/...]" -- the guest pc is field 1
#         inside the brackets.
blocks = {}          # guest addr -> hex bytes
execs  = collections.Counter()

addr = None
for line in open(log, errors="replace"):
    if line.startswith("OBJD-T:"):
        if addr is not None:
            blocks[addr] = blocks.get(addr, "") + line.split(":", 1)[1].strip()
    elif line.startswith("0x") and line.rstrip().endswith(":"):
        addr = int(line.split(":")[0], 16)
    elif line.startswith("Trace "):
        m = re.search(r"\[[0-9a-f]+/([0-9a-f]+)/", line)
        if m:
            execs[int(m.group(1), 16)] += 1
    elif line.startswith("IN:"):
        addr = None

if not blocks or not execs:
    sys.exit("parsed no blocks (%d) or no executions (%d) -- qemu log format changed?"
             % (len(blocks), len(execs)))

# Instructions per block, by decoding the bytes objdump was given.
def count_insns(hexbytes):
    raw = bytes.fromhex(hexbytes)
    p = os.path.join(work, "blk.bin")
    open(p, "wb").write(raw)
    out = subprocess.run(["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", p],
                         capture_output=True, text=True).stdout
    # one instruction per line of the form "   0:\t<bytes>\t<mnemonic>"
    return sum(1 for l in out.splitlines() if re.match(r"^\s+[0-9a-f]+:\t", l))

sizes, total, unknown = {}, 0, 0
for a, n in execs.items():
    if a not in blocks:
        unknown += n
        continue
    if a not in sizes:
        sizes[a] = count_insns(blocks[a])
    total += n * sizes[a]

print("%d\tinstructions" % total)
if unknown:
    print("  note: %d block executions had no in_asm record and are NOT counted"
          % unknown, file=sys.stderr)
PY
