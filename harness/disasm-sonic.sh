#!/usr/bin/env bash
# Annotated disassembly of a SonicScheme program: every instruction labelled
# with the function and block it belongs to.
#
# WHY THIS EXISTS. Reading the emitted code means pairing a disassembly with a
# label map, and nothing checks that the two came from the same build. The map
# is produced by COMPILING; the binary is whatever is on disk. Analysing a
# stale binary against a fresh map produces addresses that look plausible and
# are not, and it cost two wrong findings in one session -- a hot loop reported
# as having one divider chain when it has two, and a whole issue filed on the
# claim that the second-hottest function did no arithmetic. The tell was a
# `call` whose target carried no label; the instruction there was an `imul`.
#
# So this compiles ONCE and emits both from that compile. There is no way to
# pass it a binary.
#
# IT ALSO STOPS AT THE END OF THE CODE. `objdump -D -b binary` disassembles
# linearly from offset zero, so it runs straight into the constant pool and
# decodes doubles as instructions. The code size is the sum of instruction-size
# over the listing, which is what driver.ss uses to place the pool, so it is
# exactly where to stop.
#
#   harness/disasm-sonic.sh <program.sps> [externs] [function-name-filter]
#
# `externs` is the Lcore extern list as a Scheme datum and defaults to
# fannkuch's `(display newline)`. nbody wants
# `(command-line length cadr string->number display newline)`.
#
# With a third argument, only functions whose name contains it are printed --
# `harness/disasm-sonic.sh prog.sps '(display newline)' inner%24`.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

# NOTHING RUNS ON THE HOST -- the hard rule in CLAUDE.md. This compiles, which
# is a Chez process, and that is the thing the container limits exist for.
. "$here/tools/container.sh"
sonic_reexec sonic bash /work/harness/disasm-sonic.sh "$@"

SRC=${1:-}
EXTERNS=${2:-"(display newline)"}
FILTER=${3:-}
[ -n "$SRC" ] || { echo "usage: disasm-sonic.sh <program.sps> [externs] [filter]"; exit 2; }
[ -f "$SRC" ] || { echo "no such file: $SRC"; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/build.ss" <<EOF
(import (chezscheme) (sonic driver) (sonic object) (sonic elfexec))
(let* ((c (compile-sonic "$SRC" '$EXTERNS))
       (listing (compiled-listing c)))
  (write-executable "$WORK/prog" (compiled-image c))
  ;; The map and the image come from THIS compile and no other.
  (with-output-to-file "$WORK/labels"
    (lambda ()
      (let loop ((xs listing) (pc 0))
        (cond ((null? xs)
               ;; last line is the end of code, so the reader knows where to stop
               (display "END ") (display (+ elf-text-vaddr pc)) (newline))
              ((symbol? (car xs))
               (display (+ elf-text-vaddr pc)) (display " ")
               (display (car xs)) (newline)
               (loop (cdr xs) pc))
              (else (loop (cdr xs) (+ pc (instruction-size 'x86-64 (car xs)))))))))
  )
EOF

timeout 900 scheme -q --libdirs "$here/sonic/src:$here/sonic/vendor/nanopass" \
    --script "$WORK/build.ss" || { echo "compile FAILED"; exit 1; }

objdump -D -b binary -m i386:x86-64 --adjust-vma=0x400000 "$WORK/prog" 2>/dev/null \
  | awk -F'\t' 'NF>1 {gsub(/ /,"",$1); sub(/:$/,"",$1); print $1 "\t" $3}' \
  > "$WORK/dis"

FILTER="$FILTER" python3 - "$WORK/labels" "$WORK/dis" <<'PY'
import sys, os, bisect
labels_path, dis_path = sys.argv[1], sys.argv[2]
flt = os.environ.get("FILTER", "")

end = None
labs = []
for line in open(labels_path):
    p = line.split()
    if len(p) != 2:
        continue
    if p[0] == "END":
        end = int(p[1]); continue
    labs.append((int(p[0]), p[1]))
labs.sort()
addrs = [a for a, _ in labs]

# A label spelled L.* is a block inside the function whose label precedes it.
owner, cur = [], "?"
for a, n in labs:
    if not n.startswith("L."):
        cur = n
    owner.append((a, cur, n))

rows = []
for line in open(dis_path):
    line = line.rstrip("\n")
    if "\t" not in line:
        continue
    a, t = line.split("\t", 1)
    try:
        addr = int(a, 16)
    except ValueError:
        continue
    if end is not None and addr >= end:
        break            # past the code: the rest is the constant pool
    rows.append((addr, t.strip()))

shown = 0
last_fn = last_blk = None
for addr, text in rows:
    i = bisect.bisect_right(addrs, addr) - 1
    if i < 0:
        continue
    _, fn, blk = owner[i]
    if flt and flt not in fn:
        continue
    if fn != last_fn:
        print("\n=== %s ===" % fn); last_fn, last_blk = fn, None
    if blk != last_blk and blk.startswith("L."):
        print("  %s:" % blk); last_blk = blk
    print("    %06x  %s" % (addr, text))
    shown += 1
if shown == 0:
    print("no instructions matched" + (" filter %r" % flt if flt else ""))
PY
