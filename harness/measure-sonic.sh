#!/usr/bin/env bash
# SonicScheme against gcc -O3 -march=native, cycles and instructions per step.
#
# Separate from measure.sh, and the reason is a limitation rather than a taste:
# every configuration in configs.sh takes N on its command line, and SonicScheme
# emits programs that have no command line. runtime.ss says why -- `command-line`
# returns the empty list, so nbody takes its default branch -- and giving it a
# real one needs pairs, strings and `string->number` in hand-written assembly.
# Until that exists, N is baked in at compile time and the harness's
# `cfg_run_<name> $N` contract cannot be met. Filed; see the beads.
#
# WHY THIS FILE EXISTS AT ALL. The number was previously produced by whatever
# shell was convenient at the time, and one of those used N=1000 -> N=3000. At
# that size a two-point slope is startup noise: seven samples of c-native came
# back -118.3 163.7 174.7 177.1 192.1 231.1 236.8, and a NEGATIVE slope means
# the larger run retired fewer cycles than the smaller one. Two different ratios
# (1.07 and 1.13) were quoted from measurements that could not tell them apart.
# measure.sh's own default has been N=1000000 all along; the ad-hoc scripts were
# the problem, so the fix is to stop writing ad-hoc scripts.
#
# At N=1e6 -> 3e6 the difference is ~2e6 steps against a process startup of a
# few milliseconds, and the spread collapses to well under one percent.
#
# TWO N VALUES AND A SLOPE (METHOD.md), and the MEDIAN of several repetitions
# with the spread printed (D34). The spread is not decoration: it is how you
# find out the instrument is inadequate, which is exactly what happened here.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

# NOTHING RUNS ON THE HOST -- the hard rule in CLAUDE.md. This compiles (a Chez
# process, the thing that once reached 31GB and took the VM with it) and runs
# binaries this compiler emitted. The `bench` service is `sonic` plus the one
# seccomp exception `perf_event_open` needs; see docker-compose.yml.
# The path is absolute because the service's working_dir is /work/sonic, which
# is right for the compiler and wrong for anything in harness/.
if [ ! -f /.dockerenv ]; then
  exec docker compose -f "$here/docker-compose.yml" run --rm -T \
       --entrypoint bash bench /work/harness/measure-sonic.sh "$@"
fi

N1=${N1:-1000000}
N2=${N2:-3000000}
REPS=${REPS:-7}
BENCH="$here/bench/nbody"
BUILD="$here/build/nbody"
mkdir -p "$BUILD"

# N is baked in by rewriting the `command-line` preamble to a constant. Textual
# because the alternative is a second copy of the benchmark per N, and two
# sources that must stay identical except for one number is how a benchmark
# quietly starts measuring two different programs.
bake() {   # $1 = N, $2 = output .sps
  python3 - "$1" "$BENCH/config-sonic.sps" "$2" <<'PY'
import sys
n, src, out = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()
old = """(let* ((args (command-line))
         (n (if (fx> (length args) 1)
                (string->number (cadr args))
                1000)))"""
if old not in s:
    sys.exit("measure-sonic: the command-line preamble in config-sonic.sps "
             "is not the shape this script rewrites; update both together")
open(out, "w").write(s.replace(old, "(let* ((n %s))" % n))
PY
}

echo "building..."
bake "$N1" "$BUILD/sonic-n1.sps" || exit 1
bake "$N2" "$BUILD/sonic-n2.sps" || exit 1
cat > "$BUILD/build.ss" <<EOF
(import (chezscheme) (sonic driver) (sonic pipeline))
(for-each (lambda (p)
            (compile-sonic-to-file (string-append "$BUILD/sonic-" p ".sps")
                                   nbody-externs
                                   (string-append "$BUILD/sonic-" p)))
          '("n1" "n2"))
EOF
timeout 900 scheme -q --libdirs "$here/sonic/src:$here/sonic/vendor/nanopass" \
    --script "$BUILD/build.ss" || { echo "sonic build FAILED"; exit 1; }
chmod +x "$BUILD/sonic-n1" "$BUILD/sonic-n2"
gcc -O3 -march=native -o "$BUILD/ref-native" "$BENCH/ref.c" -lm || exit 1

count() { perf stat -x, -e "$2" $1 2>&1 >/dev/null | cut -d, -f1; }

report() {  # $1 = label, $2 = cmd at N1, $3 = cmd at N2, $4 = event
  local samples=()
  for _ in $(seq "$REPS"); do
    local a b
    a=$(count "$2" "$4"); b=$(count "$3" "$4")
    [ -z "$a" ] || [ -z "$b" ] && { echo "  $1: measurement failed"; return; }
    samples+=("$(awk -v a="$a" -v b="$b" -v d="$((N2 - N1))" \
                     'BEGIN{printf "%.2f", (b-a)/d}')")
  done
  printf '%s\n' "${samples[@]}" | sort -n |
    awk -v n="$1" '{v[NR]=$1}
                   END{printf "  %-10s median %9.2f    min %9.2f  max %9.2f  (%+.2f%%)\n",
                              n, v[int((NR+1)/2)], v[1], v[NR],
                              100*(v[NR]-v[1])/v[int((NR+1)/2)]}'
}

echo
echo "nbody, slope from N=$N1 to N=$N2, $REPS repetitions"
for ev in cycles:u instructions:u; do
  echo "--- $ev per step ---"
  report c-native "$BUILD/ref-native $N1" "$BUILD/ref-native $N2" "$ev"
  report sonic    "$BUILD/sonic-n1"       "$BUILD/sonic-n2"       "$ev"
done
