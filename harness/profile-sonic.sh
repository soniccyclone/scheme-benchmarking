#!/usr/bin/env bash
# Where does a SonicScheme program spend its cycles, by FUNCTION.
#
# WHY THIS IS NOT `perf report`. Two reasons now. perf does not work rootless on
# this host at all (D58), and it was never the right instrument anyway: the
# executables this compiler emits have no
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
# process) and runs an emitted binary, both of which belong inside the limits.
#
# No perf event is opened here any more, so no seccomp exception is needed and
# the `bench` service that carried one is gone. See D60.
. "$here/tools/container.sh"
sonic_reexec sonic bash /work/harness/profile-sonic.sh "$@"

SRC=${1:-}
EXTERNS=${2:-"(display newline)"}
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

# SIMULATED, NOT SAMPLED, and that is an upgrade rather than a fallback.
#
# This used `perf record -e cycles:u`, which needs perf_event_open and therefore
# does not work rootless on this host at all (D58: paranoid=4, and CAP_PERFMON
# is tested against the initial user namespace so no container flag reaches it).
# callgrind needs no capability. Three things change, and two of them are worth
# having on their own:
#
#   EXACT, NOT SAMPLED. Every instruction is counted, so a function that never
#   caught a sample is no longer invisible and small functions stop being noise.
#
#   NO SKID. The header above describes 7.2% of fannkuch's cycles landing on
#   flip-prefix's PROLOGUE and reading as call overhead when it was really
#   branch-mispredict skid -- the sampled IP is not where the cost was incurred.
#   A simulator attributes to the instruction that actually did the work, so
#   that class of misreading cannot happen here. The mispredicts are reported
#   too (Bcm), attributed correctly, which is what that finding actually needed.
#
#   INSTRUCTIONS AND MODELLED MISSES, NOT CYCLES. This is the real loss and it
#   is stated in the output rather than left to be discovered: there is no
#   pipeline model here, so a divider chain and an add cost the same Ir. Read
#   this to find WHERE THE WORK IS; read wall clock for how fast it is.
#
# --dump-instr=yes is what makes the existing label map usable: costs come out
# per instruction address, the same thing `perf script -F ip` produced, only
# weighted and complete.
valgrind --tool=callgrind --dump-instr=yes --branch-sim=yes \
         --callgrind-out-file="$WORK/cg.out" "$WORK/prog" >/dev/null 2>&1 \
  || { echo "callgrind FAILED"; exit 1; }

TOP=$TOP python3 - "$WORK/labels.txt" "$WORK/cg.out" <<'PY'
import sys, bisect, os
from collections import defaultdict

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

# --- the callgrind format ---------------------------------------------------
#
# `positions:` names the position fields on every cost line (here `instr line`)
# and `events:` names the costs after them. Positions use SUBPOSITION
# COMPRESSION: an absolute value is written 0x..., and a relative one as +n/-n
# against the previous line's value, with * meaning unchanged. Getting that
# wrong does not error, it silently attributes cost to the wrong address, so it
# is decoded explicitly rather than by assuming absolutes.
#
# The line after `calls=` is the INCLUSIVE cost of a call and would double-count
# every callee against its caller, so it is skipped.
def parse_pos(tok, prev):
    if tok == '*':            return prev
    if tok[0] in '+-':        return prev + int(tok)
    if tok.startswith('0x'):  return int(tok, 16)
    return int(tok)

positions, events, declared = ['line'], [], None
cost = defaultdict(lambda: defaultdict(int))   # addr -> event -> count
prev = {}
skip_next_cost = False

for raw in open(sys.argv[2]):
    line = raw.rstrip('\n')
    if not line or line.startswith('#'):
        continue
    # A COST LINE ALWAYS STARTS WITH A POSITION, and a position is a number,
    # a +/- delta or *. Everything else is metadata -- name records (ob= fl=
    # fn= cob= cfn=) and headers (version: creator: cmd: part: summary:).
    # Dispatching on "does the first token contain '='" missed `version:` and
    # fed it to the integer parser, which is the kind of thing that would have
    # silently mis-attributed cost had the token happened to parse.
    if not (line[0].isdigit() or line[0] in '+-*'):
        if line.startswith('positions:'):
            positions = line.split(':', 1)[1].split(); prev = {}
        elif line.startswith('events:'):
            events = line.split(':', 1)[1].split()
        elif line.startswith('calls='):
            skip_next_cost = True
        elif line.startswith('summary:'):
            declared = line.split(':', 1)[1].split()
        continue
    tok = line.split()
    if len(tok) < len(positions):
        continue
    pos = {}
    for k, name in enumerate(positions):
        pos[name] = prev[name] = parse_pos(tok[k], prev.get(name, 0))
    if skip_next_cost:                # inclusive cost of the call above
        skip_next_cost = False
        continue
    vals = tok[len(positions):]
    ip = pos.get('instr')
    if ip is None:
        continue
    for ev, v in zip(events, vals):
        try:
            cost[ip][ev] += int(v)
        except ValueError:
            pass

if not cost:
    sys.exit("no costs parsed from callgrind output -- format change?")

# CROSS-CHECK AGAINST CALLGRIND'S OWN TOTAL, because the two ways this parser
# can be wrong are both silent. Subposition compression decoded as absolutes
# would attribute cost to invented addresses, and failing to skip the cost line
# after `calls=` would add every callee's inclusive cost to its caller again.
# Either produces a plausible-looking profile. The summary line is callgrind's
# arithmetic, so disagreeing with it means the parse is wrong, not the program.
if declared:
    for k, ev in enumerate(events):
        if k >= len(declared):
            break
        mine = sum(f.get(ev, 0) for f in cost.values())
        theirs = int(declared[k])
        if mine != theirs:
            sys.exit("parse disagrees with callgrind's summary for %s: "
                     "%d parsed, %d declared. Refusing to report a profile "
                     "built on a misparse." % (ev, mine, theirs))

by_fn = defaultdict(lambda: defaultdict(int))
for ip, evs in cost.items():
    i = bisect.bisect_right(addrs, ip) - 1
    name = owner[i][1] if i >= 0 else '(below the first label)'
    for ev, v in evs.items():
        by_fn[name][ev] += v

tot_ir = sum(f.get('Ir', 0) for f in by_fn.values())
tot_bcm = sum(f.get('Bcm', 0) for f in by_fn.values())
if not tot_ir:
    sys.exit("callgrind reported no instructions")

print("INSTRUCTIONS by function (Ir), %d total. Simulated and exact:" % tot_ir)
print("no sampling, no skid -- but no pipeline model either, so this is WHERE")
print("THE WORK IS, not how fast it is. Bcm is conditional-branch mispredicts.")
print()
print("     %Ir   (cum)        Bcm    %Bcm  function")
run = 0.0
top = int(os.environ.get("TOP", "15"))
for name, evs in sorted(by_fn.items(), key=lambda kv: -kv[1].get('Ir', 0))[:top]:
    ir = evs.get('Ir', 0); bcm = evs.get('Bcm', 0)
    pct = 100.0 * ir / tot_ir
    run += pct
    pbcm = (100.0 * bcm / tot_bcm) if tot_bcm else 0.0
    print("  %6.2f%%  (%5.1f%%)  %9d  %5.1f%%  %s" % (pct, run, bcm, pbcm, name))
if tot_bcm:
    print("\n  %d conditional-branch mispredicts total" % tot_bcm)
PY
