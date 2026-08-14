#!/usr/bin/env bash
# Run one source under SonicScheme and under Chez, and compare the answers.
#
# This is the instrument that found the last four wrong-answer bugs, and it
# lives here rather than in /tmp because every one of them was found by
# shrinking a failing program one line at a time -- which is a loop you run
# fifty times, not once.
#
# Chez runs the SAME FILE through bench/nbody/sonic-compat.sls, which defines
# the four declaration forms as no-ops. That is sound by construction: they are
# premises and permissions, so dropping them changes what a compiler may
# assume, never what the program computes.
#
# SonicScheme's `display` writes a double's eight raw bytes (see runtime.ss on
# why that is right for an oracle), so the two outputs are compared as numbers
# rather than as text.
#
# Usage:  tools/diff-run.sh < program.sps
#         echo '(define (main) ...) (main)' | tools/diff-run.sh
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"

# NOTHING RUNS ON THE HOST -- see the hard rule in CLAUDE.md. This script both
# compiles (a Chez process, the thing that once reached 31GB and took the VM)
# and EXECUTES a binary this compiler emitted, and this compiler demonstrably
# emits programs that loop forever. Both belong inside the limits.
#
# Re-exec rather than document, because a script that merely says "run me in a
# container" is a script someone runs on the host. The runner attaches stdin and
# allocates no tty, which matters both ways: the program under test arrives on
# stdin, and a tty would mangle the raw doubles the emitted program writes back.
. "$here/../tools/container.sh"
sonic_reexec sonic bash /work/sonic/tools/diff-run.sh "$@"
work="${TMPDIR:-/tmp}/sonic-diff.$$"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

cat > "$work/x.sps"

cat > "$work/drv.ss" <<EOF
(import (chezscheme) (sonic driver) (sonic pipeline))
(compile-sonic-to-file "$work/x.sps"
                       (if (getenv "NBODY") nbody-externs '(display newline))
                       "$work/x.bin")
EOF

if ! timeout 600 scheme -q --libdirs "$here/src:$here/vendor/nanopass" \
        --script "$work/drv.ss" > "$work/build.log" 2>&1; then
  echo "  BUILD FAIL: $(tail -1 "$work/build.log")"
  exit 1
fi

chmod +x "$work/x.bin"
timeout 60 "$work/x.bin" > "$work/sonic.bin" 2>/dev/null
sonic_exit=$?

{ echo '(import (chezscheme) (sonic-compat))'; cat "$work/x.sps"; } > "$work/x-chez.sps"
timeout 60 scheme --libdirs "$here/../bench/nbody" --program "$work/x-chez.sps" \
    > "$work/chez.txt" 2> "$work/chez.err"

python3 - "$work" "$sonic_exit" <<'PY'
import struct, sys, os
work, code = sys.argv[1], sys.argv[2]
raw = open(os.path.join(work, "sonic.bin"), "rb").read()
got = [struct.unpack("<d", raw[i:i+8])[0] for i in range(0, len(raw) - 7, 8)]
try:
    want = [float(t) for t in open(os.path.join(work, "chez.txt")).read().split()]
except ValueError:
    want = None
print("  sonic exit=%s: %s" % (code, got))
if want is None:
    print("  chez FAILED: %s" % open(os.path.join(work, "chez.err")).read()[:160].strip())
else:
    print("  chez        : %s" % want)
    print("  MATCH" if got == want else "  DIFFER")
PY
