#!/usr/bin/env bash
# Where does a SonicScheme program spend its cycles, by FUNCTION.
#
# WHY THIS IS NOT `perf report`. The executables this compiler emits have no
# symbol table and no section headers -- `readelf -S` says "There are no
# sections in this file" -- because build-executable writes two program headers
# and the code, and nothing else. perf therefore attributes every sample to a
# bare address, and answering "which function is that?" has meant disassembling
# by hand around whatever address came out on top. That is slow and it is how
# a profile gets misread: 7.2% of fannkuch's cycles land on flip-prefix's
# PROLOGUE, which reads as call overhead and is actually branch-mispredict skid
# on the call target. Inlining it by hand bought 0.4%.
#
# HOW THE MAP IS OBTAINED. compiled-listing hands back the assembly listing with
# its labels still in it, and label offsets are exactly what driver.ss already
# computes to find `_start`. Walking the listing and summing instruction-size
# gives every label an address, and elf-text-vaddr turns that into the address
# perf will report. No debug format, no symbol table, no guessing.
#
# BLOCK LABELS FOLD INTO THEIR FUNCTION. A label spelled `L.something` is a
# basic block inside the function whose label precedes it, so `L.then5` at 28%
# is not an answer to anything. Folding them is what turns a list of blocks into
# "flip-prefix's inner loop is 52% of this program".
#
#   harness/profile-sonic.sh <program.sps> [externs]
#
# `externs` is the Lcore extern list, spelled as a Scheme datum, and defaults to
# fannkuch's `(display newline)`. nbody wants `(command-line length cadr
# string->number display newline)`.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

# NOTHING RUNS ON THE HOST -- the hard rule in CLAUDE.md. This compiles (a Chez
# process) and runs an emitted binary under perf, so it needs the `bench`
# service, which is `sonic` plus the seccomp exception perf_event_open wants.
#
# The seccomp exception is necessary and no longer sufficient: this host runs
# kernel.perf_event_paranoid=4, so perf_event_open needs CAP_PERFMON, which a
# rootless container cannot hold. Run bench rootful -- sonic_assert_perf says
# how, and it costs nothing on the host. See D58.
. "$here/tools/container.sh"
sonic_reexec bench bash /work/harness/profile-sonic.sh "$@"

sonic_assert_perf || exit 1

SRC=${1:-}
EXTERNS=${2:-"(display newline)"}
PERIOD=${PERIOD:-200000}
TOP=${TOP:-15}
[ -n "$SRC" ] || { echo "usage: profile-sonic.sh <program.sps> [externs]"; exit 2; }
[ -f "$SRC" ] || { echo "no such file: $SRC"; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/build.ss" <<EOF
(import (chezscheme) (sonic driver) (sonic object) (sonic elfexec))
(let* ((c (compile-sonic "$SRC" '$EXTERNS))
       (listing (compiled-listing c)))
  (write-executable "$WORK/prog" (compiled-image c))
  ;; vaddr(label) = elf-text-vaddr + its offset in the listing, which is what
  ;; driver.ss's own label-offset computes; \`_start\` at 0x401000 confirms it.
  (with-output-to-file "$WORK/labels.txt"
    (lambda ()
      (let loop ((xs listing) (pc 0))
        (cond ((null? xs) (void))
              ((symbol? (car xs))
               (display (number->string (+ elf-text-vaddr pc) 16))
               (display " ") (display (car xs)) (newline)
               (loop (cdr xs) pc))
              (else (loop (cdr xs) (+ pc (instruction-size 'x86-64 (car xs))))))))))
EOF

timeout 900 scheme -q --libdirs "$here/sonic/src:$here/sonic/vendor/nanopass" \
    --script "$WORK/build.ss" || { echo "compile FAILED"; exit 1; }
chmod +x "$WORK/prog"

perf record -q -e cycles:u -c "$PERIOD" -o "$WORK/perf.data" "$WORK/prog" >/dev/null 2>&1
perf script -i "$WORK/perf.data" -F ip 2>/dev/null > "$WORK/ips.txt"

TOP=$TOP python3 - "$WORK/labels.txt" "$WORK/ips.txt" <<'PY'
import sys, bisect, os
from collections import Counter
labs = []
for line in open(sys.argv[1]):
    p = line.split()
    if len(p) == 2:
        labs.append((int(p[0], 16), p[1]))
labs.sort()

# A label spelled L.* is a basic block belonging to the function whose label
# came before it. Anything else opens a new function region.
owner, cur = [], '?'
for a, n in labs:
    if not n.startswith('L.'):
        cur = n
    owner.append((a, cur))
addrs = [a for a, _ in owner]

c, tot = Counter(), 0
for line in open(sys.argv[2]):
    line = line.strip()
    if not line:
        continue
    ip = int(line, 16); tot += 1
    i = bisect.bisect_right(addrs, ip) - 1
    c[owner[i][1] if i >= 0 else '(below the first label)'] += 1

if not tot:
    sys.exit("no samples -- is perf_event_open permitted? use the bench service")
print("cycles by function, %d samples" % tot)
run = 0.0
for name, k in c.most_common(int(os.environ.get("TOP", "15"))):
    pct = 100.0 * k / tot
    run += pct
    print("  %6.2f%%  (cum %5.1f%%)  %s" % (pct, run, name))
PY
