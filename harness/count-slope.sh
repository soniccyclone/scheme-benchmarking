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
# programs it crashes on. The instrument used is reported, because a callgrind
# number and a qemu number agree to within about 1% at scale and NOT exactly.
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
    n=$("$here/harness/count-instructions.sh" $cmd 2>/dev/null | cut -f1)
    if [ -n "$n" ]; then echo "$n	callgrind"; return 0; fi

    envpart=""; rest="$cmd"
    while :; do
        case "$rest" in
            env\ *)             rest="${rest#env }" ;;
            [A-Za-z_]*=*\ *)    envpart="$envpart ${rest%% *}"; rest="${rest#* }" ;;
            *)                  break ;;
        esac
    done
    prog="${rest%% *}"; args="${rest#* }"
    abs=$(command -v "$prog" 2>/dev/null || echo "$prog")
    n=$(env $envpart "$here/harness/qemu-count.sh" "$abs" $args 2>/dev/null | cut -f1)
    if [ -n "$n" ]; then echo "$n	qemu"; return 0; fi
    echo "	none"
}

# THE INSTRUMENT COMES BACK IN THE OUTPUT, not in a variable. count_one is
# called in a $(...) subshell, so an assignment inside it cannot reach here --
# a first version set a global and silently reported an empty column.
r1=$(count_one "${TEMPLATE//@N/$N1}"); a=${r1%%	*}; ia=${r1##*	}
r2=$(count_one "${TEMPLATE//@N/$N2}"); b=${r2%%	*}; ib=${r2##*	}

if [ -z "$a" ] || [ -z "$b" ]; then
    echo "REFUSED: no instrument could count this program." >&2
    echo "callgrind and qemu-count both declined; see their messages with 2>&1." >&2
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
