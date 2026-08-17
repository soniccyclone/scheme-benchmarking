#!/usr/bin/env bash
# Retired instructions per step, per configuration.
#
# Two N values, and we report the SLOPE. Process startup ranges from ~4ms to
# ~200ms across the runtimes in this matrix and would otherwise dominate at dev
# sizes; differencing two N values cancels it exactly. See LEDGER.md D17 for why
# instruction count and not wall time is the primary instrument here.
set -uo pipefail
HERE_M="$(dirname "${BASH_SOURCE[0]}")"
# NOTHING RUNS ON THE HOST -- and this one both compiles and RUNS emitted
# binaries under callgrind. It also needs the toolchains that live in the image
# rather than on the host (D61).
. "$(cd "$HERE_M/.." && pwd)/tools/container.sh"
sonic_reexec sonic bash /work/harness/measure.sh "$@"

source "$HERE_M/configs.sh"

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
here_m="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ONE SLOPE PER CONFIGURATION, THROUGH count-slope.sh, and the delegation is the
# point rather than tidiness. That script refuses a measurement whose count does
# not change with N, which is the only thing that has ever caught a broken one
# here: callgrind reports a total alongside "unhandled instruction" and QEMU
# sums a log up to an "uncaught target signal", so both hand back plausible
# numbers for runs that died. This table printed a per-step of 0.00 for c-native
# on exactly that basis before anyone looked twice.
#
# It also picks the instrument -- callgrind first, because every instruction
# figure in the ledger came from it, then qemu-count for the four
# managed-runtime Lisps it crashes on -- and says which one answered. A
# callgrind number and a qemu number agree to about 1% at scale and NOT exactly,
# so the column is there to stop the two being read as interchangeable.
#
# REPS is gone. A simulated count is the same integer every time; repeating it
# measured nothing and only made the table slower.

printf '%-12s %14s %10s %12s\n' config per-step vs-C instrument
printf '%-12s %14s %10s %12s\n' ------ -------------- ---------- ------------

base=""
for c in ${*:-$CONFIGS}; do
    out=$("$here_m/harness/count-slope.sh" "$N1" "$N2" "$(cfg_run "$c" @N)" 2>&1)
    per=$(printf '%s' "$out" | awk -F'\t' '/instructions\/step/ {print $1}')
    ins=$(printf '%s' "$out" | awk -F'\t' '/instructions\/step/ {print $3}')
    if [ -z "$per" ]; then
        # The refusal, not a blank. Which one it was matters: "no instrument
        # could count this" and "the count did not change with the work" are
        # different failures and only the second implies a broken measurement.
        why=$(printf '%s' "$out" | sed -n 's/^REFUSED: //p' | head -1)
        printf '%-12s  %s\n' "$c" "${why:-measurement failed}"
        continue
    fi
    [ -z "$base" ] && base="$per"
    rel=$(awk -v p="$per" -v b="$base" 'BEGIN{printf "%.2fx", p/b}')
    printf '%-12s %14s %10s %12s\n' "$c" "$per" "$rel" "$ins"
done
