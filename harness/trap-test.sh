#!/usr/bin/env bash
# The recompilation trap test. Phase 1's acceptance gate.
#
# A configuration that recompiles per invocation, or that interprets, reports a
# number about its startup path rather than its code generation. That is the
# most common way a benchmark of this kind silently goes wrong, and it is easy
# to miss because the number looks plausible.
#
# For each configuration:
#   1. compile
#   2. run, time A
#   3. run again, time B          -> B must not exceed A meaningfully
#   4. touch the source
#   5. run again, time C          -> C must be within noise of B
#
# N is deliberately SMALL. Recompilation is a fixed cost, so the smaller the
# real work, the larger it looms. At N=1000 a recompile is unmissable; at
# N=10000000 it would hide inside the run.
#
# Usage: ./trap-test.sh [config ...]

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/configs.sh"

N=1000
TOLERANCE=1.25   # ratio above which we call it a recompile

ms() {  # median of 3, in milliseconds, to blunt scheduler noise
    local cmd="$1" t best=() i s
    for i in 1 2 3; do
        s=$( { /usr/bin/time -f '%e' bash -c "$cmd >/dev/null 2>&1"; } 2>&1 )
        best+=("$s")
    done
    printf '%s\n' "${best[@]}" | sort -n | sed -n 2p | awk '{printf "%.0f", $1*1000}'
}

ratio() { awk -v a="$1" -v b="$2" 'BEGIN{ if (a<1) a=1; printf "%.2f", b/a }'; }

fail=0
printf '%-12s %7s %7s %7s   %s\n' config A B C verdict
printf '%-12s %7s %7s %7s   %s\n' ------ ---- ---- ---- -------

for c in ${*:-$CONFIGS}; do
    cfg_compile "$c" >/dev/null 2>&1 || { printf '%-12s compile FAILED\n' "$c"; fail=1; continue; }
    cmd="$(cfg_run "$c" "$N")"
    src="$BENCH/$(cfg_src "$c")"

    a=$(ms "$cmd")
    b=$(ms "$cmd")
    touch "$src"
    # The copy in build/ is what the run step actually reads, so touch both;
    # touching only the pristine source would test nothing.
    for f in "$BUILD"/"$c".sps "$BUILD"/"${c}".c; do [ -f "$f" ] && touch "$f"; done
    c_t=$(ms "$cmd")

    rb=$(ratio "$a" "$b")
    rc=$(ratio "$b" "$c_t")
    verdict="ok"
    awk -v r="$rb" -v t="$TOLERANCE" 'BEGIN{exit !(r>t)}' && { verdict="RERUN SLOWER (${rb}x)"; fail=1; }
    awk -v r="$rc" -v t="$TOLERANCE" 'BEGIN{exit !(r>t)}' && { verdict="RECOMPILES ON MTIME (${rc}x)"; fail=1; }

    printf '%-12s %6sms %6sms %6sms   %s\n' "$c" "$a" "$b" "$c_t" "$verdict"
done

echo
if [ "$fail" -eq 0 ]; then
    echo "PASS: every configuration is ahead-of-time compiled and mtime-stable."
else
    echo "FAIL: at least one configuration recompiles or interprets. Numbers from it"
    echo "      would measure the startup path, not code generation."
fi
exit "$fail"
