# Configuration table. Sourced by compile.sh, run.sh and trap-test.sh.
#
# One entry per measurable configuration. Adding a configuration means adding a
# source file under bench/<program>/ and three functions here:
#
#   cfg_src_<name>      the source file, relative to BENCH
#   cfg_compile_<name>  ahead-of-time compile; must leave a runnable artifact
#   cfg_run_<name>      print the command that runs it, given $1 = N
#
# Every configuration is AOT compiled. A configuration that interprets or that
# recompiles per invocation produces a number about the toolchain's startup
# path rather than about its code generation, which is the single most common
# way a benchmark of this kind goes wrong. trap-test.sh is the gate.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH="$ROOT/bench/nbody"
BUILD="$ROOT/build/nbody"

CONFIGS="c-scalar c-native chez-2a racket-2a chez-4 racket-4 sbcl-5"

mkdir -p "$BUILD"

# --- configuration 6: C, the reference -------------------------------------
# Two flag sets, because the pair separates "no vectorizer" from "worse scalar
# code generation" and published ratios hide that distinction.

cfg_src_c_scalar() { echo "ref.c"; }
cfg_compile_c_scalar() {
    gcc -O2 -fno-tree-vectorize -o "$BUILD/ref-scalar" "$BENCH/ref.c" -lm
}
cfg_run_c_scalar() { echo "$BUILD/ref-scalar $1"; }

cfg_src_c_native() { echo "ref.c"; }
cfg_compile_c_native() {
    gcc -O3 -march=native -o "$BUILD/ref-native" "$BENCH/ref.c" -lm
}
cfg_run_c_native() { echo "$BUILD/ref-native $1"; }

# --- configuration 2a: portable R6RS, on both implementations --------------
# The same source file runs under both. Chez ships (rnrs arithmetic flonums)
# natively; Racket provides it through #lang r6rs. See LEDGER.md D11.

cfg_src_chez_2a() { echo "config2a.sps"; }
cfg_compile_chez_2a() {
    cp "$BENCH/config2a.sps" "$BUILD/chez-2a.sps"
    # compile-program, not compile-file: without it Chez interprets the program.
    scheme -q --optimize-level 2 >/dev/null <<EOF
(compile-program "$BUILD/chez-2a.sps")
EOF
    test -f "$BUILD/chez-2a.so"
}
cfg_run_chez_2a() { echo "scheme --program $BUILD/chez-2a.so $1"; }

cfg_src_racket_2a() { echo "config2a.sps"; }
cfg_compile_racket_2a() {
    cp "$BENCH/config2a.sps" "$BUILD/racket-2a.sps"
    # Without raco make, racket recompiles from source on every invocation and
    # looks catastrophically slow for reasons unrelated to Racket.
    raco make "$BUILD/racket-2a.sps" >/dev/null
    test -f "$BUILD/compiled/racket-2a_sps.zo"
}
# PLT_COMPILED_FILE_CHECK=exists is load-bearing. Racket's default is
# modify-seconds: it stats the source on every startup and recompiles when the
# source is newer than the .zo. trap-test.sh measured that at 1.86x on a
# touched source, which would land straight in the reported time.
cfg_run_racket_2a() {
    echo "env PLT_COMPILED_FILE_CHECK=exists racket -I r6rs $BUILD/racket-2a.sps $1"
}

# --- configuration 4: implementation-specific maximum ----------------------
# The folklore ceiling, and note the two implementations do not even offer the
# same KIND of mechanism. Chez has a global policy (optimize-level 3); Racket
# has per-call-site unchecked operators (racket/unsafe/ops). Neither is
# standardized. That is the portability problem stated concretely.

cfg_src_chez_4() { echo "config4-chez.ss"; }
cfg_compile_chez_4() {
    cp "$BENCH/config4-chez.ss" "$BUILD/chez-4.ss"
    # optimize-level is a global compile-time parameter, not a lexical form, so
    # it is set HERE and cannot be scoped inside the source. Wall 3 of the four
    # in docs/phases/07-compiler/PLAN.md.
    scheme -q --optimize-level 3 >/dev/null <<EOF
(optimize-level 3)
(compile-file "$BUILD/chez-4.ss")
EOF
    test -f "$BUILD/chez-4.so"
}
cfg_run_chez_4() { echo "scheme -q --optimize-level 3 --script $BUILD/chez-4.so $1"; }

cfg_src_racket_4() { echo "config4-racket.rkt"; }
cfg_compile_racket_4() {
    cp "$BENCH/config4-racket.rkt" "$BUILD/racket-4.rkt"
    raco make "$BUILD/racket-4.rkt" >/dev/null
    test -f "$BUILD/compiled/racket-4_rkt.zo"
}
cfg_run_racket_4() {
    echo "env PLT_COMPILED_FILE_CHECK=exists racket $BUILD/racket-4.rkt $1"
}

# --- configuration 5: tuned conformant Common Lisp -------------------------
# save-lisp-and-die rather than a fasl: a core has no load step at all, which
# keeps startup out of the dev-N numbers where it would otherwise dominate.

cfg_src_sbcl_5() { echo "config5.lisp"; }
cfg_compile_sbcl_5() {
    cp "$BENCH/config5.lisp" "$BUILD/sbcl-5.lisp"
    rm -f "$BUILD/sbcl-5.core"
    sbcl --noinform --non-interactive \
         --load "$BUILD/sbcl-5.lisp" \
         --eval "(save-lisp-and-die \"$BUILD/sbcl-5.core\" :toplevel #'main :executable nil)" \
         >/dev/null 2>&1
    test -f "$BUILD/sbcl-5.core"
}
cfg_run_sbcl_5() { echo "sbcl --core $BUILD/sbcl-5.core --noinform --end-runtime-options $1"; }

# --- dispatch --------------------------------------------------------------
# Config names carry hyphens for readability; shell function names cannot.

cfg_fn() { echo "$1" | tr '-' '_'; }
cfg_src()     { "cfg_src_$(cfg_fn "$1")"; }
cfg_compile() { "cfg_compile_$(cfg_fn "$1")"; }
cfg_run()     { "cfg_run_$(cfg_fn "$1")" "$2"; }
