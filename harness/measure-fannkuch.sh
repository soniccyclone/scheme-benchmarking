#!/usr/bin/env bash
# fannkuch-redux under SonicScheme against gcc -O3 -march=native.
#
# WHY THIS EXISTS SEPARATELY FROM harness/measure.sh. That script measures by a
# SLOPE between two N, because nbody's work is linear in its step count and a
# slope cancels process startup. fannkuch is n!, so there is no slope to take:
# n=10 and n=11 are not two points on a line, they are two different programs
# with an order of magnitude between them. This measures TOTAL cycles at one n
# instead, which is honest here precisely because the run is long enough that
# startup does not register -- n=11 is ~8 seconds of work.
#
# AND WHY IT IS WORTH MEASURING AT ALL. Both variants ship with n baked at 7,
# which is 5040 permutations and finishes before it starts; the suite uses that
# size because it is checking an ANSWER against SPEC.md's oracle, not a time.
# Every timing anyone quoted from n=7 was measuring process startup. At n=11 the
# ratio is 1.4-ish and the gap is instructions, which is the opposite of nbody's
# diagnosis (D37) and the reason both benchmarks have to be measured rather than
# one of them generalised.
#
# AND THIS ONE IS STILL AD HOC, which is worth saying rather than leaving to be
# found. configs.sh is nbody-only -- one BENCH directory, one CONFIGS list -- so
# fannkuch has no configuration table to be driven from, and this script
# hard-codes the two builds it compares. The right fix is a second table, not a
# third harness: `sonic` became an ordinary configuration the moment argv could
# be read, and fannkuch could too.
#
# N IS BAKED IN TWO PLACES AND THEY MUST MOVE TOGETHER. `(define n 7)` sets the
# permutation size and `(make-vector 7 0)` sizes the three arrays. Changing only
# the first produces a program that indexes past its own vectors and exits 102
# on the bounds check -- correctly, which is how this was found.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

# NOTHING RUNS ON THE HOST -- the hard rule in CLAUDE.md. `bench` is `sonic`
# plus the seccomp exception perf_event_open needs; see docker-compose.yml.
if [ ! -f /.dockerenv ]; then
  exec docker compose -f "$here/docker-compose.yml" run --rm -T \
       --entrypoint bash bench /work/harness/measure-fannkuch.sh "$@"
fi

N=${N:-11}
REPS=${REPS:-5}
BENCH="$here/bench/fannkuch"
BUILD="$here/build/fannkuch"
mkdir -p "$BUILD"

bake() {   # $1 = n
  python3 - "$1" "$BENCH/config-sonic.sps" "$BUILD/fk.sps" \
             "$BENCH/ref.c" "$BUILD/fkref.c" <<'PY'
import sys
n, ssrc, sout, csrc, cout = sys.argv[1:6]
s = open(ssrc).read()
if "(define n 7)" not in s or "(make-vector 7 0)" not in s:
    sys.exit("measure-fannkuch: config-sonic.sps no longer has the `(define n 7)` "
             "and `(make-vector 7 0)` shapes this rewrites; update both together")
s = s.replace("(define n 7)", "(define n %s)" % n)
s = s.replace("(make-vector 7 0)", "(make-vector %s 0)" % n)
open(sout, "w").write(s)
c = open(csrc).read()
if "#define N 7" not in c:
    sys.exit("measure-fannkuch: ref.c no longer spells its size `#define N 7`")
open(cout, "w").write(c.replace("#define N 7", "#define N %s" % n))
PY
}

echo "building at n=$N..."
bake "$N" || exit 1
cat > "$BUILD/build-fk.ss" <<EOF
(import (chezscheme) (sonic driver))
(compile-sonic-to-file "$BUILD/fk.sps" '(display newline) "$BUILD/fk")
EOF
timeout 900 scheme -q --libdirs "$here/sonic/src:$here/sonic/vendor/nanopass" \
    --script "$BUILD/build-fk.ss" || { echo "sonic build FAILED"; exit 1; }
chmod +x "$BUILD/fk"
gcc -O3 -march=native -o "$BUILD/fkref" "$BUILD/fkref.c" || exit 1

# THE ANSWER FIRST. A faster program that computes a different checksum is not
# a result, and both variants write two raw doubles rather than text.
a=$("$BUILD/fk"    | od -An -tf8 | tr -s ' ')
b=$("$BUILD/fkref" | od -An -tf8 | tr -s ' ')
echo "  sonic:$a"
echo "  gcc:  $b"
[ "$a" = "$b" ] && echo "  answers AGREE" || { echo "  answers DIFFER -- stop"; exit 1; }

report() {  # $1 = label, $2 = cmd, $3 = event
  local samples=()
  for _ in $(seq "$REPS"); do
    samples+=("$(perf stat -x, -e "$3" $2 2>&1 >/dev/null | cut -d, -f1)")
  done
  printf '%s\n' "${samples[@]}" | sort -n |
    awk -v n="$1" '{v[NR]=$1}
                   END{printf "  %-10s median %14d    (%+.2f%% spread)\n",
                              n, v[int((NR+1)/2)],
                              100*(v[NR]-v[1])/v[int((NR+1)/2)]}'
}

echo
echo "fannkuch-redux n=$N, total, $REPS repetitions"
for ev in cycles:u instructions:u; do
  echo "--- $ev ---"
  report c-native "$BUILD/fkref" "$ev"
  report sonic    "$BUILD/fk"    "$ev"
done
