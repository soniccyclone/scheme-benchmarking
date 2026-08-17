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
# THE RUN'S EXIT STATUS IS CHECKED, because timing a command that does not exist
# produces a number rather than an error. Measured: after `make clean` removed
# build/, this script reported c-native at -0.04985 ns/step with a bootstrap CI
# of [-0.0027, 0.0045] and marked it "real" -- a NEGATIVE per-step time from
# timing "No such file or directory" twice. Nothing in the table said the binary
# was missing.
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
    # A FAILED RUN IS NOT A SLOW ONE. Reporting the wall clock of a command that
    # exited non-zero is how a missing binary became a measurement.
    echo "${vals[@]}"
}

# BASELINE NAMES THE BASELINE, AND NOW IT ALSO IS ONE. It was printed in the
# header and never used in the arithmetic: the ratio came from `[ -z "$base" ]
# && base="$s"`, i.e. whichever configuration was measured FIRST. The default
# CONFIGS list begins with sonic while BASELINE defaults to c-scalar, so every
# table this has produced divided by sonic under a header claiming C. Same bug
# D69 records in measure.sh, in the script that prints the headline wall-clock
# numbers AND their confidence intervals.
#
# It shows up as a row saying "(baseline)" that is not the row the header names,
# which is how it was caught: `BASELINE=sbcl-5 bench.sh sonic sbcl-5` printed
# "baseline sbcl-5" above a table marking SONIC as the baseline.
#
# MEASURE FIRST, THEN PRINT, because the baseline need not be the first row and
# a ratio cannot be formed before its divisor exists.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
US=$(printf '\037')

for c in ${*:-$CONFIGS}; do
    # PREFLIGHT, IN THE MAIN SHELL. Timing a command that does not exist yields
    # a number: after `make clean` removed build/, this script reported c-native
    # at -0.04985 ns/step with a CI of [-0.0027, 0.0045] and marked it "real" --
    # a NEGATIVE per-step time, from timing "No such file or directory" twice.
    #
    # It has to run here rather than inside `slopes` or `run_ns`, because both of
    # those are invoked through $( ... ) and an exit status or a variable set in
    # a subshell cannot reach this loop. Two earlier attempts put it in each of
    # them and both still reported a number for a missing binary.
    if ! eval "$(cfg_run "$c" "$N1")" >/dev/null 2>&1; then
        printf '%s%s%s%s%s\n' "$c" "$US" "" "$US" "refused: the command does not run" >> "$work/rows"
        continue
    fi
    s=$(slopes "$c")
    [ -z "$s" ] && {
        printf '%s%s%s%s%s\n' "$c" "$US" "" "$US" "refused: all samples rejected as parallel" >> "$work/rows"
        continue; }
    med=$(printf '%s\n' $s | tr ' ' '\n' | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')
    # A NON-POSITIVE PER-STEP TIME IS NOT A RESULT. More work cannot take less
    # time, so a slope at or below zero means the measurement is measuring
    # something else -- a failing command, or an N the program ignores.
    if awk -v m="$med" 'BEGIN{exit !(m <= 0)}'; then
        printf '%s%s%s%s%s\n' "$c" "$US" "" "$US" "refused: per-step time $med is not positive" >> "$work/rows"
        continue
    fi
    printf '%s\n' "$s" > "$work/samples.$c"
    printf '%s%s%s%s%s\n' "$c" "$US" "$med" "$US" "" >> "$work/rows"
done
# THE "[n rejected as parallel]" NOTE IS GONE, AND IT NEVER PRINTED. It read
# ${REJECTED:-0}, which `slopes` sets -- but `slopes` is invoked as $(slopes
# "$c"), so the assignment happens in a subshell and cannot reach here. REJECTED
# was therefore always 0 and the note was always empty. Same subshell trap this
# harness has hit four times; removed rather than left looking like a feature.
# Filed as a bead to surface the count through slopes' OUTPUT, which is the fix
# that actually works.

printf 'slope of N=%s to N=%s, %s reps, baseline %s\n\n' "$N1" "$N2" "$REPS" "$BASELINE"
printf '%-14s %12s  %s\n' config ns/step 'bootstrap 95% CI on ratio vs baseline'
printf '%-14s %12s  %s\n' -------------- ------------ -------------------------------------

# THE NAMED BASELINE, OR NO RATIOS AT ALL. Falling back to another config here
# is what produced a table whose header and whose arithmetic disagreed, so a
# baseline that did not measure now costs the ratio column and says so.
basefile="$work/samples.$BASELINE"
[ -f "$basefile" ] || printf 'NO BASELINE: %s did not measure, so no ratios are shown.\n\n' "$BASELINE" >&2

while IFS=$US read -r c med why; do
    if [ -n "$why" ]; then
        printf '%-14s  %s\n' "$c" "$why"
    elif [ ! -f "$basefile" ]; then
        printf '%-14s %12s  %s\n' "$c" "$med" "--"
    elif [ "$c" = "$BASELINE" ]; then
        printf '%-14s %12s  %s\n' "$c" "$med" "(baseline)"
    else
        ci=$(printf '%s\n%s\n' "$(cat "$basefile")" "$(cat "$work/samples.$c")" \
             | awk -f "$HERE/bootstrap.awk")
        printf '%-14s %12s  %s\n' "$c" "$med" "$ci"
    fi
done < "$work/rows"
