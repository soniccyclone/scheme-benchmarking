#!/usr/bin/env bash
# Retired instructions per step, per configuration.
#
# Two N values, and we report the SLOPE. Process startup ranges from ~4ms to
# ~200ms across the runtimes in this matrix and would otherwise dominate at dev
# sizes; differencing two N values cancels it exactly. See LEDGER.md D17 for why
# instruction count and not wall time is the primary instrument here.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/configs.sh"

N1=${N1:-1000000}
N2=${N2:-2000000}
# COUNTED BY SIMULATION, NOT BY THE PMU. perf does not work rootless on this
# host and no container flag reaches it (D58/D60), so counts come from
# callgrind. For THIS script that is close to a pure win: it was already built
# on instructions because they are deterministic, and callgrind makes that
# exactly true rather than nearly so.
#
# The cost is wall time -- callgrind runs the program perhaps 50x slower -- and
# nbody at N=2,000,000 is not a short run to begin with. Lower N1/N2 if you are
# iterating; the slope cancels startup at any pair.

# WHICH EVENT, and how many samples of it.
#
# Instructions are deterministic -- every repetition of a given build returns
# the same count -- so one sample is the whole answer and REPS defaults to 1.
# CYCLES ARE NOT. D34 is the entry: instruction count stopped predicting cycles,
# so the ratio that matters is measured in cycles, as a MEDIAN with the spread
# printed, because the spread is how you find out the instrument is inadequate.
#
#   REPS=7 harness/measure.sh c-native sonic   (REPS buys nothing: exact)
#
# This is what harness/measure-sonic.sh used to do for one configuration. It
# does it for all of them now, which is the point: a number for SonicScheme that
# cannot be produced for Chez or gcc is not a comparison.
# REPS defaults to 1 and there is now no reason to raise it: a simulated count
# is the same integer every time. It is kept so the min/max columns still work
# if someone wants to prove that to themselves.
REPS=${REPS:-1}

here_m="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

count() {  # exact instruction count for one run
    # $1 is a command line, deliberately unquoted so its arguments split -- the
    # same shape the perf invocation this replaces had.
    "$here_m/harness/count-instructions.sh" $1 2>/dev/null | cut -f1
}

# The slope between N1 and N2, sampled REPS times; prints "median min max".
slope() {  # $1 = run command at N1, $2 = run command at N3
    local i a b
    for i in $(seq "$REPS"); do
        a=$(count "$1"); b=$(count "$2")
        [ -z "$a" ] || [ -z "$b" ] && { echo ""; return; }
        awk -v a="$a" -v b="$b" -v d="$((N2 - N1))" 'BEGIN{printf "%.2f\n", (b-a)/d}'
    done | sort -n | awk '{v[NR]=$1} END{printf "%s %s %s", v[int((NR+1)/2)], v[1], v[NR]}'
}

if [ "$REPS" -gt 1 ]; then
    printf '%-12s %14s %14s %14s %10s\n' config "per-step" min max vs-C
    printf '%-12s %14s %14s %14s %10s\n' ------ -------------- -------------- -------------- ----------
else
    printf '%-12s %16s %16s %14s %10s\n' config "N=$N1" "N=$N2" per-step vs-C
    printf '%-12s %16s %16s %14s %10s\n' ------ ---------------- ---------------- -------------- ----------
fi

base=""
for c in ${*:-$CONFIGS}; do
    if [ "$REPS" -gt 1 ]; then
        read -r per lo hi <<< "$(slope "$(cfg_run "$c" "$N1")" "$(cfg_run "$c" "$N2")")"
        [ -z "$per" ] && { printf '%-12s  measurement failed\n' "$c"; continue; }
        [ -z "$base" ] && base="$per"
        rel=$(awk -v p="$per" -v b="$base" 'BEGIN{printf "%.2fx", p/b}')
        printf '%-12s %14s %14s %14s %10s\n' "$c" "$per" "$lo" "$hi" "$rel"
    else
        i1=$(count "$(cfg_run "$c" "$N1")")
        i2=$(count "$(cfg_run "$c" "$N2")")
        [ -z "$i1" ] && { printf '%-12s  measurement failed\n' "$c"; continue; }
        per=$(awk -v a="$i1" -v b="$i2" -v n1="$N1" -v n2="$N2" 'BEGIN{printf "%.2f", (b-a)/(n2-n1)}')
        [ -z "$base" ] && base="$per"
        rel=$(awk -v p="$per" -v b="$base" 'BEGIN{printf "%.2fx", p/b}')
        printf '%-12s %16d %16d %14s %10s\n' "$c" "$i1" "$i2" "$per" "$rel"
    fi
done
