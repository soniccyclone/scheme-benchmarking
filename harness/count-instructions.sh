#!/usr/bin/env bash
# Exact instruction counts for an emitted program, with no hardware counters.
#
# WHY THIS EXISTS RATHER THAN `perf stat -e instructions`. This host runs
# `kernel.perf_event_paranoid=4`, under which perf_event_open is denied to every
# unprivileged process -- not just hardware events, ALL of them; a software
# event like `task-clock` fails identically. The obvious fix, adding
# CAP_PERFMON, does not work either, and the reason is worth stating because it
# is not guessable from the error: `perfmon_capable()` tests that capability
# against the INITIAL user namespace, and a rootless container's capabilities
# live in its own. Measured on this host, all EACCES:
#
#     seccomp unconfined                    rootless   EACCES
#     + --cap-add=CAP_PERFMON               rootless   EACCES
#     + --privileged                        rootless   EACCES
#     --sysctl kernel.perf_event_paranoid=2            REFUSED (not namespaced)
#
# So `--privileged` is not a stronger `--cap-add` here; it is the same nothing.
#
# AND IT IS THE BETTER INSTRUMENT ANYWAY, which is the part that matters beyond
# this one host. callgrind counts by simulation, so its answer is DETERMINISTIC:
# the same binary yields the same number, exactly, on a busy machine or an idle
# one. D57 records the standing drifting 1% with the code byte-identical and
# recommends reporting the min of nine samples to cope; a simulated count has no
# spread to report. What it does NOT measure is time -- there is no cache or
# branch-predictor model here, so this answers "how much work" and never "how
# fast". Wall clock still comes from harness/measure-fannkuch.sh.
#
# Ratios between two builds are the honest use. The absolute number includes the
# runtime prologue and the process's own startup, which is a fixed few hundred
# instructions and irrelevant at the scale anything here runs at.
#
#   harness/count-instructions.sh <binary> [args...]
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

. "$here/tools/container.sh"
sonic_reexec sonic bash /work/harness/count-instructions.sh "$@"

BIN=${1:-}
[ -n "$BIN" ] || { echo "usage: count-instructions.sh <binary> [args...]"; exit 2; }
[ -x "$BIN" ] || { echo "not executable: $BIN"; exit 2; }
shift

# --callgrind-out-file=/dev/null: the profile is not wanted, only the total.
# The count lands on stderr as `I   refs: N`, so stdout stays the program's.
out=$(valgrind --tool=callgrind --callgrind-out-file=/dev/null "$BIN" "$@" 2>&1 >/dev/null)

if echo "$out" | grep -q 'unhandled instruction'; then
    # TO STDERR, ALL OF IT. A caller reads this script's stdout as a number, so
    # a diagnostic printed there is captured and parsed as one -- measure.sh
    # fell straight into that and reported the refusal text as a count.
    echo "REFUSED: valgrind could not decode an instruction in $BIN." >&2
    echo >&2
    echo "$out" | grep -A2 'unhandled instruction' | head -4 >&2
    echo >&2
    echo "If those bytes start 0xC5 or 0x62 this is an AVX-512 form, which VEX" >&2
    echo "does not decode. Two things reach this: our own three-lane work, and" >&2
    echo "gcc -march=native on an AVX-512 host -- so c-native lands here too." >&2
    echo "harness/qemu-count.sh counts what this cannot." >&2
    exit 1
fi

n=$(echo "$out" | sed -n 's/.*I   refs:[[:space:]]*//p' | tr -d ',')
[ -n "$n" ] || { echo "no count from callgrind:" >&2; echo "$out" | tail -5 >&2; exit 1; }
printf '%s\t%s\n' "$n" "$(basename "$BIN")"
