#!/usr/bin/env bash
# Instructions per step, by slope, with the validity check built in.
#
# WHY A SLOPE AND NOT A COUNT. A single instruction count answers "how many
# instructions did this process execute", which includes startup and includes
# whatever the counter managed to observe before something went wrong. The
# slope between two N answers "how many per step", which is the number anyone
# actually wants -- and, far more importantly, it CANNOT BE COMPUTED FROM A
# BROKEN MEASUREMENT.
#
# That second property is the whole point of this script, and it was learned
# the expensive way. Two separate counters returned confident, plausible,
# entirely wrong numbers during one afternoon:
#
#   c-native   `gcc -O3 -march=native` emits AVX-512 on this host. valgrind
#              prints "unhandled instruction bytes: 0x62 ..." AND "I refs:
#              117,666" -- the count up to the failure. QEMU dies with "uncaught
#              target signal 4" and its log summed to 103,015. Both look like
#              instruction counts. Neither is one.
#
#   clisp-9    exits 0, prints the correct energies, and responds to N. Its
#              QEMU log is nevertheless BYTE-IDENTICAL at N=50 and N=200 --
#              34,578 lines, 22,542 traces -- because clisp re-executes itself
#              and the child's log replaces the parent's. What gets counted is
#              a prologue.
#
# Nothing about 117,666 or 103,015 or 115,154 looked wrong. What gave all three
# away was that they DID NOT CHANGE WHEN THE WORK CHANGED. A real count varies
# with N; a crashed or truncated one does not.
#
# So the check is not a step someone has to remember to run. Asking for a slope
# makes it structural: two equal counts have zero slope, and this refuses rather
# than reporting an instructions-per-step of 0.00, which is what measure.sh
# printed for c-native before anyone noticed.
#
# This is the same argument D30 makes about the container limits -- a guarantee
# you have to remember to apply fails exactly when it matters -- applied to a
# measurement instead of to memory.
#
# EITHER COUNTER, whichever can do the job. callgrind is preferred because every
# instruction figure in the ledger came from it; qemu-count.sh answers for the
# programs it crashes on. The instrument used is REPORTED IN THE OUTPUT, and
# that column is load-bearing rather than informational.
#
# AN EARLIER VERSION OF THIS COMMENT SAID THE TWO AGREE "to within about 1% at
# scale". I wrote that without measuring it, and when measured it was worse than
# claimed: exact on gcc's output, 6.17% on ours. That turned out to be a bug in
# qemu-count.sh -- it counted objdump's continuation line for any instruction
# longer than 7 bytes as a second instruction, and we emit such forms where gcc
# -O2 does not. Fixed; see that script's header. Measured after the fix, slope
# between N=200 and N=400:
#
#     ref-scalar (gcc -O2)   callgrind 653.90   qemu 653.90   exact
#     sonic                  callgrind 664.00   qemu 664.00   exact
#
# So the instruments now agree to the hundredth on both. The instrument column
# stays, because "they agree today on these two binaries" is not "they are
# interchangeable" -- callgrind still cannot run four configurations at all, and
# the whole reason the 6% went unnoticed for so long is that the cross-check had
# only ever been run on a binary that did not exercise the difference.
#
# SONIC_INSTRUMENT FORCES ONE, and it is still worth having now that the two
# agree. Set it to `qemu` or `callgrind` and a comparison ACROSS configs becomes
# single-instrument, so the ratio holds whatever either tool is doing in the
# absolute -- which is the property that let Milestone 3 be answered while the
# 6% was still unexplained. Forcing an instrument that cannot run the program
# REFUSES rather than falling back, because a fallback would silently reintroduce
# the mix the force exists to prevent.
#
# So a milestone that compares sonic against sbcl runs both under qemu, since
# qemu is the only instrument that can run sbcl at all. The default -- prefer
# callgrind, fall back -- stays right for looking at ONE config, where the
# ledger's existing callgrind figures are the comparable ones.
#
#   harness/count-slope.sh <N1> <N2> <command with @N for the step count>
#
#   harness/count-slope.sh 50 200 "build/nbody/sonic @N"
#   harness/count-slope.sh 50 200 "env NBODY_N=@N /usr/bin/sbcl --core c.core ..."
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

. "$here/tools/container.sh"
sonic_reexec sonic bash /work/harness/count-slope.sh "$@"

N1=${1:-}; N2=${2:-}; TEMPLATE=${3:-}
[ -n "$N1" ] && [ -n "$N2" ] && [ -n "$TEMPLATE" ] || {
    echo "usage: count-slope.sh <N1> <N2> <command with @N>" >&2; exit 2; }
[ "$N1" != "$N2" ] || { echo "N1 and N2 must differ" >&2; exit 2; }

# One count, by whichever instrument can produce one. Prints the number, sets
# INSTRUMENT. Both invocation traps are handled here rather than left to the
# caller: qemu-user needs an ABSOLUTE path, and a leading `env VAR=` must be
# preserved -- getting either wrong makes a working program look unrunnable.
count_one() {
    local cmd="$1" n envpart rest prog args abs

    # SPLIT OFF ANY `env VAR=value` PREFIX FIRST, for BOTH instruments. The
    # previous version did this only on the qemu path and handed the raw string
    # to callgrind, so a config carrying an env prefix invoked
    # count-instructions.sh with "env" as the binary. It never showed, because
    # every env-prefixed config here is a managed Lisp that callgrind declines
    # anyway -- the bug was masked by a second failure.
    envpart=""; rest="$cmd"
    while :; do
        case "$rest" in
            env\ *)             rest="${rest#env }" ;;
            [A-Za-z_]*=*\ *)    envpart="$envpart ${rest%% *}"; rest="${rest#* }" ;;
            *)                  break ;;
        esac
    done
    prog="${rest%% *}"; args="${rest#* }"
    [ "$args" = "$rest" ] && args=""

    # RESOLVE TO AN ABSOLUTE PATH BEFORE EITHER INSTRUMENT RUNS, AGAINST THE
    # REPO ROOT AS WELL AS THE CWD. The container's working_dir is /work/sonic,
    # because that is where the test suite runs -- but every caller, and this
    # script's own usage example, writes paths relative to the REPO ROOT. So
    # `build/nbody/sonic` did not resolve, and the refusal that came back said
    # "no instrument could count this program": a path that was never found,
    # reported as a limitation of the instruments. qemu-count.sh needs the
    # absolute form regardless, and its own header says a bare name there fails
    # in a way that looks like a real limitation.
    if [ -x "$prog" ]; then
        abs=$(cd "$(dirname "$prog")" && pwd)/$(basename "$prog")
    elif [ -x "$here/$prog" ]; then
        abs="$here/$prog"
    else
        abs=$(command -v "$prog" 2>/dev/null || echo "$prog")
    fi
    # DISTINGUISHED FROM `none`, so the caller can say which of the two things
    # went wrong instead of blaming the instruments for a missing file.
    [ -x "$abs" ] || { printf '\tnotfound\n'; return 0; }

    if [ "${SONIC_INSTRUMENT:-}" != qemu ]; then
        n=$(env $envpart "$here/harness/count-instructions.sh" "$abs" $args 2>/dev/null | cut -f1)
        if [ -n "$n" ]; then echo "$n	callgrind"; return 0; fi
        # Forced callgrind must FAIL rather than fall through, or the force is
        # advisory and the caller silently gets the mix it was avoiding.
        if [ "${SONIC_INSTRUMENT:-}" = callgrind ]; then printf '\tnone\n'; return 0; fi
    fi
    n=$(env $envpart "$here/harness/qemu-count.sh" "$abs" $args 2>/dev/null | cut -f1)
    if [ -n "$n" ]; then echo "$n	qemu"; return 0; fi
    printf '\tnone\n'
}

# THE INSTRUMENT COMES BACK IN THE OUTPUT, not in a variable. count_one is
# called in a $(...) subshell, so an assignment inside it cannot reach here --
# a first version set a global and silently reported an empty column.
r1=$(count_one "${TEMPLATE//@N/$N1}"); a=${r1%%	*}; ia=${r1##*	}
r2=$(count_one "${TEMPLATE//@N/$N2}"); b=${r2%%	*}; ib=${r2##*	}

if [ "$ia" = notfound ] || [ "$ib" = notfound ]; then
    echo "REFUSED: the program was not found, so nothing was measured." >&2
    echo "  looked for: ${TEMPLATE//@N/$N1}" >&2
    echo "  relative to the cwd ($PWD) and to the repo root ($here)." >&2
    echo "This is DELIBERATELY a different message from the one below: a missing" >&2
    echo "file used to be reported as the instruments declining, which sent me" >&2
    echo "looking at callgrind instead of at the path." >&2
    exit 1
fi
if [ -z "$a" ] || [ -z "$b" ]; then
    echo "REFUSED: no instrument could count this program." >&2
    if [ -n "${SONIC_INSTRUMENT:-}" ]; then
        echo "SONIC_INSTRUMENT=$SONIC_INSTRUMENT was forced, so there was no" >&2
        echo "fallback; unset it to let the other instrument try." >&2
    else
        echo "callgrind and qemu-count both declined; see their messages with 2>&1." >&2
    fi
    exit 1
fi
if [ "$ia" != "$ib" ]; then
    echo "REFUSED: the two points were counted by different instruments" >&2
    echo "($ia at N=$N1, $ib at N=$N2). A slope across instruments is not a slope." >&2
    exit 1
fi

# THE CHECK, and it is the reason this script exists.
if [ "$a" = "$b" ]; then
    echo "REFUSED: the count did not change with the work." >&2
    echo "  N=$N1 -> $a" >&2
    echo "  N=$N2 -> $b" >&2
    echo "A real count varies with N. An identical one means the measurement is" >&2
    echo "not measuring the program: a crashed run counted up to the fault, or a" >&2
    echo "log that stopped early. Both have happened here -- see the header." >&2
    exit 1
fi

awk -v a="$a" -v b="$b" -v n1="$N1" -v n2="$N2" -v i="$ia" \
    'BEGIN{ printf "%.2f\tinstructions/step\t%s\n", (b-a)/(n2-n1), i }'
