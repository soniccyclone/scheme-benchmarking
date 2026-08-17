#!/usr/bin/env bash
# Wall-clock measurement with bootstrap confidence intervals.
#
# Complements measure.sh rather than replacing it. Instruction counts are
# deterministic and answer "how much work", but say nothing about IPC, cache
# behaviour or branch misprediction, and a configuration can retire fewer
# instructions while running slower. This is the instrument for that, and it is
# the one that needs statistics (LEDGER.md D13).
#
# TWO N VALUES AND A SLOPE, per METHOD.md. Process startup ranges from ~4ms
# (C) to ~200ms (Racket) across this matrix and would otherwise dominate at dev
# sizes. Each repetition times BOTH N values and contributes one slope sample,
# so startup cancels inside every sample rather than being subtracted from
# aggregates afterwards.
#
# Timing is nanosecond via date +%s%N. /usr/bin/time's %e is 10ms-granular,
# which is the same trap trap-test.sh already fell into once.
#
# Serial-only is ENFORCED, not assumed: cpu-time over elapsed-time above 1.3
# rejects the sample as contaminated. See METHOD.md.
#
# Usage: ./bench.sh [config ...]
#   REPS=20 N1=1000000 N2=2000000 ./bench.sh chez-4 sbcl-5

set -uo pipefail
HERE="$(dirname "${BASH_SOURCE[0]}")"

# NOTHING RUNS ON THE HOST -- the hard rule in CLAUDE.md. This one RUNS THE
# BINARIES THIS COMPILER EMITS, dozens of times each, which is precisely the
# thing the container limits exist for: a miscompiled program that loops for
# ever is a class of bug this project produces, not a hypothetical. It had no
# guard at all, so `make bench` ran every emitted binary on the host.
#
# It also could not see most of its own matrix from out there: racket, sbcl,
# ecl, clisp and gnat live in the image (D61), not on the host.
. "$(cd "$HERE/.." && pwd)/tools/container.sh"
sonic_reexec sonic bash /work/harness/bench.sh "$@"

source "$HERE/configs.sh"

N1=${N1:-1000000}
N2=${N2:-2000000}
REPS=${REPS:-15}
WARMUP=${WARMUP:-3}
BASELINE=${BASELINE:-c-scalar}

# Elapsed nanoseconds for one run, plus a serial-only verdict.
# TIMEFORMAT gives CPU at millisecond precision, which is plenty for a ratio
# test; the elapsed figure used for the measurement is the nanosecond one.
run_ns() {
    local cmd="$1" t0 t1 cpu
    TIMEFORMAT='%3U %3S'
    t0=$(date +%s%N)
    cpu=$( { time eval "$cmd" >/dev/null 2>&1; } 2>&1 | tail -1 )
    t1=$(date +%s%N)
    ELAPSED_NS=$(( t1 - t0 ))
    CPU_MS=$(echo "$cpu" | awk '{printf "%.0f", ($1 + $2) * 1000}')
    RATIO=$(awk -v c="$CPU_MS" -v e="$ELAPSED_NS" 'BEGIN{ if (e<=0) print 0; else printf "%.2f", (c*1000000)/e }')
}

# REPS slope samples, in nanoseconds per step.
slopes() {
    local c="$1" i t1 t2 vals=() rej=0
    local cmd1 cmd2
    cmd1="$(cfg_run "$c" "$N1")"; cmd2="$(cfg_run "$c" "$N2")"
    for ((i = 0; i < WARMUP; i++)); do eval "$cmd1" >/dev/null 2>&1; done
    for ((i = 0; i < REPS; i++)); do
        run_ns "$cmd1"; t1=$ELAPSED_NS; local r1=$RATIO
        run_ns "$cmd2"; t2=$ELAPSED_NS; local r2=$RATIO
        if awk -v a="$r1" -v b="$r2" 'BEGIN{exit !(a>1.3 || b>1.3)}'; then rej=$((rej+1)); continue; fi
        vals+=("$(awk -v a="$t1" -v b="$t2" -v n1="$N1" -v n2="$N2" 'BEGIN{printf "%.4f", (b-a)/(n2-n1)}')")
    done
    REJECTED=$rej
    echo "${vals[@]}"
}

base=""
printf 'slope of N=%s to N=%s, %s reps, baseline %s\n\n' "$N1" "$N2" "$REPS" "$BASELINE"
printf '%-14s %12s  %s\n' config ns/step 'bootstrap 95% CI on ratio vs baseline'
printf '%-14s %12s  %s\n' -------------- ------------ -------------------------------------

for c in ${*:-$CONFIGS}; do
    s=$(slopes "$c")
    [ -z "$s" ] && { printf '%-14s  all samples rejected as parallel\n' "$c"; continue; }
    med=$(printf '%s\n' $s | tr ' ' '\n' | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')
    if [ -z "$base" ]; then base="$s"; ci="(baseline)"
    else ci=$(printf '%s\n%s\n' "$base" "$s" | awk -f "$HERE/bootstrap.awk"); fi
    note=""; [ "${REJECTED:-0}" -gt 0 ] && note=" [${REJECTED} rejected as parallel]"
    printf '%-14s %12s  %s%s\n' "$c" "$med" "$ci" "$note"
done
