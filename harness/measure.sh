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
# managed-runtime Lisps it crashes on -- and says which one answered.
#
# THAT COLUMN IS NOT DECORATION. An earlier version of this comment said the two
# instruments "agree to about 1% at scale", unmeasured. Measured, they differed
# by 6.17% on our binaries and 0.0000% on gcc's -- a bug in qemu-count.sh, now
# fixed (D72), after which they agree exactly on both. The column stays because
# callgrind still cannot run four of the configurations here at all, and because
# a cross-check that only ever ran on gcc's output is what hid that bug.
#
# Set SONIC_INSTRUMENT=qemu (or callgrind) to force one across the whole table,
# which is what a milestone comparison needs -- qemu being the only instrument
# that runs sbcl, racket, ecl or clisp at all.
#
# REPS is gone. A simulated count is the same integer every time; repeating it
# measured nothing and only made the table slower.

# THE BASELINE IS NAMED IN THE HEADER, AND IT IS COMPUTED, NOT ASSUMED. This
# column said `vs-C` while the code below took the baseline from whichever
# config happened to be measured FIRST. The default CONFIGS list starts with
# `sonic`, so every table this has ever printed compared against sonic under a
# header claiming C -- which for a project whose whole question is "do we beat
# C" is the one column that must not lie. c-scalar reading 0.93x is incoherent
# if you believe the header, and that incoherence is what gave it away.
#
# BASELINE picks it explicitly; otherwise c-scalar when it is in the run, since
# that is the comparison the ledger is written around; otherwise the first
# config, which is the old behaviour and is now stated rather than implied.
run_configs="${*:-$CONFIGS}"
if [ -n "${BASELINE:-}" ]; then
    base_cfg="$BASELINE"
else
    base_cfg=$(printf '%s\n' $run_configs | grep -x c-scalar || printf '%s\n' $run_configs | head -1)
fi

# MEASURE EVERYTHING FIRST, THEN PRINT. The ratio needs the baseline, and the
# baseline is no longer guaranteed to be the first row -- but measuring in one
# pass and printing in another also avoids counting the baseline TWICE, which a
# two-pass version would have done. That is free with callgrind and emphatically
# not with qemu: sbcl under full QEMU logging is minutes, not seconds.
results=$(mktemp)
trap 'rm -f "$results"' EXIT

# ASCII UNIT SEPARATOR, NOT TAB, AND THAT IS NOT FUSSINESS. Tab is IFS
# WHITESPACE, so `read` collapses runs of it and drops empty fields entirely:
# a refused row written as `c-native\t\t\tmessage` came back with the MESSAGE
# sitting in the per-step field, which then tested non-empty and printed as a
# measurement. The row rendered as a refusal followed by a stray ratio column.
# 0x1f is not IFS whitespace, so empty fields survive.
US=$(printf '\037')

for c in $run_configs; do
    out=$("$here_m/harness/count-slope.sh" "$N1" "$N2" "$(cfg_run "$c" @N)" 2>&1)
    per=$(printf '%s' "$out" | awk -F'\t' '/instructions\/step/ {print $1}')
    ins=$(printf '%s' "$out" | awk -F'\t' '/instructions\/step/ {print $3}')
    # The refusal, not a blank. Which one it was matters: "no instrument could
    # count this" and "the count did not change with the work" are different
    # failures and only the second implies a broken measurement.
    why=$(printf '%s' "$out" | sed -n 's/^REFUSED: //p' | head -1)
    printf '%s%s%s%s%s%s%s\n' "$c" "$US" "$per" "$US" "$ins" "$US" "${why:-measurement failed}" >> "$results"
done

base=$(awk -F'\037' -v b="$base_cfg" '$1==b {print $2}' "$results")

printf '%-12s %14s %10s %12s\n' config per-step "vs-${base_cfg}" instrument
printf '%-12s %14s %10s %12s\n' ------ -------------- ---------- ------------

# A BASELINE THAT DID NOT MEASURE MUST NOT SILENTLY BECOME SOMETHING ELSE. The
# old code fell back to the first config that happened to work, which is how a
# mislabelled ratio survives a failed run without anyone noticing.
if [ -z "$base" ]; then
    printf 'NO BASELINE: %s did not measure, so no ratio is shown.\n' "$base_cfg" >&2
fi

while IFS=$US read -r c per ins why; do
    if [ -z "$per" ]; then
        printf '%-12s  %s\n' "$c" "$why"
    elif [ -z "$base" ]; then
        printf '%-12s %14s %10s %12s\n' "$c" "$per" "--" "$ins"
    else
        rel=$(awk -v p="$per" -v b="$base" 'BEGIN{printf "%.2fx", p/b}')
        printf '%-12s %14s %10s %12s\n' "$c" "$per" "$rel" "$ins"
    fi
done < "$results"
