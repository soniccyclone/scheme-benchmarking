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

# Nanosecond timing, not /usr/bin/time. Its %e is 10ms-granular and these runs
# are 40-70ms, so quantization alone produced a spurious 1.5x on the first
# version of this script.
#
# hyperfine cannot do this job either, and the reason is worth recording: the
# FIRST run after a touch is the one that recompiles and rewrites the cache, so
# any warmup or repeat run masks exactly what we are testing. Each post-touch
# sample must be a genuinely cold single run.
one_run_ns() {
    local t0 t1
    t0=$(date +%s%N)
    eval "$1" >/dev/null 2>&1
    t1=$(date +%s%N)
    echo $(( (t1 - t0) / 1000000 ))
}

steady() {  # median of 3, no touching
    local cmd="$1" v=()
    for _ in 1 2 3; do v+=("$(one_run_ns "$cmd")"); done
    printf '%s\n' "${v[@]}" | sort -n | sed -n 2p
}

post_touch() {  # median of 3, each sample preceded by its own touch
    local cmd="$1" v=() f
    for _ in 1 2 3; do
        for f in "${TOUCH[@]}"; do [ -e "$f" ] && touch "$f"; done
        v+=("$(one_run_ns "$cmd")")
    done
    printf '%s\n' "${v[@]}" | sort -n | sed -n 2p
}

ratio() { awk -v a="$1" -v b="$2" 'BEGIN{ if (a<5) a=5; printf "%.2f", b/a }'; }

fail=0
printf '%-12s %7s %7s %7s   %s\n' config A B C verdict
printf '%-12s %7s %7s %7s   %s\n' ------ ---- ---- ---- -------

for c in ${*:-$CONFIGS}; do
    cfg_compile "$c" >/dev/null 2>&1 || { printf '%-12s compile FAILED\n' "$c"; fail=1; continue; }
    cmd="$(cfg_run "$c" "$N")"

    # Touch every source the run step could plausibly consult: the pristine
    # source, and the build-directory copy the artifact was compiled from.
    TOUCH=("$BENCH/$(cfg_src "$c")")
    for f in "$BUILD/$c".* ; do
        case "$f" in *.so|*.zo|*.core|*.dep) ;; *) TOUCH+=("$f") ;; esac
    done

    a=$(steady "$cmd")
    b=$(steady "$cmd")
    c_t=$(post_touch "$cmd")

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
