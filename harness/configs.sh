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

# THE DRIVER SCRIPT IS WRITTEN HERE AND READ THERE.
#
# Each cfg_compile_* writes a little Chez script and then runs it -- but the
# running happens INSIDE the container, because every Chez invocation in this
# tree does (the hard rule in CLAUDE.md). The file's PATH was translated for
# that hop and its CONTENTS were not, so a script written on the host asked for
# /home/<user>/.../bench/nbody/config-sonic.sps, which does not exist there, and
# every host-side `compile.sh sonic` died on it.
#
# It failed loudly and then did not matter, which is the dangerous part: nothing
# downstream rebuilds. `bench.sh` and `measure.sh` run whatever binary is on
# disk, so a failed compile leaves the PREVIOUS one in place and they measure
# that instead -- silently, and with a number that looks entirely normal. That
# is D94 exactly, wired in as the default behaviour rather than as a mistake
# someone has to make.
#
# The repo is mounted at /work, and inside the container ROOT is /work, so these
# are correct on both sides of the hop. Use them for anything that appears
# INSIDE a generated script; keep $BUILD for the path the script is written to.
CBENCH="/work/bench/nbody"
CBUILD="/work/build/nbody"

# COMPILE BEFORE MEASURING, ALWAYS, AND REFUSE TO MEASURE IF IT FAILS.
#
# bench.sh and measure.sh used to take a configuration name, look up cfg_run_*,
# and time whatever binary was at that path. Neither compiled. So a compile that
# failed -- or was never run -- left the PREVIOUS binary in place and both
# harnesses measured it and printed a number that looked entirely normal. D166
# is the case that found it: an allocator change came back as 696.00
# instructions/step both with the change and without it, off a binary that
# predated it by fifty-one minutes.
#
# disasm-sonic.sh reached the same conclusion first and its header says why: it
# COMPILES rather than accepting a binary, and there is no way to pass it one,
# because analysing a stale artifact produces addresses that look plausible and
# are not. These two are the instruments this project's headline numbers come
# from, so they get the same rule.
#
# Unconditional, with no mtime check. A compile is seconds against measurement
# runs of minutes, and a freshness test is one more thing that can be wrong in
# the direction of silence -- which is the failure being fixed.
cfg_build_all() {
    local c
    for c in "$@"; do
        printf '%-12s ' "$c" >&2
        if cfg_compile "$c" >/dev/null 2>&1; then
            printf '[built]\n' >&2
        else
            printf '[FAIL]\n' >&2
            printf 'refusing to measure: %s did not compile, and the binary on disk\n' "$c" >&2
            printf 'is whatever a previous run left there. See LEDGER.md D166.\n' >&2
            return 1
        fi
    done
}

CONFIGS="sonic sonic-fma sonic-u4 sonic-pad4 c-scalar c-native chez-1 racket-1 chez-2a racket-2a chez-2b racket-2b chez-2c chez-4-safe chez-4 racket-4 sbcl-5 ecl-9 clisp-9 ada-8-checked ada-8-named ada-8-all"

mkdir -p "$BUILD"

# --- SonicScheme, this project's own compiler -------------------------------
#
# It took three bespoke harnesses to measure this before now, because the
# emitted programs had no command line: `command-line` returned the empty list
# and `length` returned 1, so N had to be baked in at compile time and the
# `cfg_run_<name> $N` contract below could not be met. argv is decoded into
# real strings at _start now, so it can be driven like anything else here.
#
# COMPILED IN THE CONTAINER, like every Chez invocation in this tree -- see the
# hard rule in CLAUDE.md. compile.sh may itself already be inside one, so this
# checks rather than assuming: an unguarded `scheme` here is exactly the second
# way of running things that rule exists to prevent.
cfg_src_sonic() { echo "config-sonic.sps"; }
cfg_compile_sonic() {
    local drv="$BUILD/sonic-build.ss"
    cat > "$drv" <<EOF
(import (chezscheme) (sonic driver) (sonic pipeline))
(compile-sonic-to-file "$CBENCH/config-sonic.sps" nbody-externs "$CBUILD/sonic")
EOF
    . "$ROOT/tools/container.sh"
    if sonic_in_container; then
        # `|| return 1` on BOTH branches, not just the re-exec one. Without it
        # the chmod below is the function's last command, it succeeds whatever
        # the compile did, and the caller is told the build worked. That is how
        # D166's guard came to be inert on its first outing: cfg_compile_sonic
        # returned 1 from the host and 0 from inside the container, for the same
        # failed compile.
        scheme -q --libdirs "$ROOT/sonic/src:$ROOT/sonic/vendor/nanopass" --script "$drv" \
            || return 1
    else
        "$ROOT/tools/container.sh" bash -c \
            "scheme -q --libdirs /work/sonic/src:/work/sonic/vendor/nanopass --script /work/build/nbody/sonic-build.ss" \
            || return 1
    fi
    chmod +x "$BUILD/sonic"
}
cfg_run_sonic() { echo "$BUILD/sonic $1"; }

# --- the same compiler, with the unroller allowed to grow the program -------
#
# `specialize-growth-budget` defaults to 1, meaning the program may not exceed
# its starting size -- so `unroll-fully` stops almost immediately and every loop
# index stays symbolic. Raising it is the half fold.ss was written for: "gcc's
# 36 is not tighter loop control, it is the ABSENCE of a loop", and folding is
# what turns a substituted literal into a deleted instruction.
#
# A SEPARATE CONFIGURATION rather than a change to `sonic`, so the standing
# number stays comparable and the two can be measured against each other in one
# run -- which is what D57 says a 1% claim requires.
#
# MEASURED AND IT BUYS NOTHING, which is why it is a row here rather than a new
# default. Budget 4 unrolls hard -- 902 instructions become 1734, and the number
# of functions carrying packed arithmetic goes from 5 to 17 -- and the program
# is not faster: 63.93 ns/step against 63.78, ratio 1.0023, 95% CI
# [0.8708, 1.1030], no detected difference. Budget 16 grows the program to 6306
# instructions and is no better.
#
# A first pass at this with min-of-5 at one N said 5% faster. It was noise, and
# D57 is exactly about that. Kept as a configuration so the negative result
# stays measurable rather than becoming folklore.
cfg_src_sonic_u4() { echo "config-sonic.sps"; }
cfg_compile_sonic_u4() {
    local drv="$BUILD/sonic-u4-build.ss"
    cat > "$drv" <<EOF
(import (chezscheme) (sonic driver) (sonic pipeline) (sonic specialize))
(parameterize ((specialize-growth-budget 4))
  (compile-sonic-to-file "$CBENCH/config-sonic.sps" nbody-externs "$CBUILD/sonic-u4"))
EOF
    . "$ROOT/tools/container.sh"
    if sonic_in_container; then
        # `|| return 1` on BOTH branches, not just the re-exec one. Without it
        # the chmod below is the function's last command, it succeeds whatever
        # the compile did, and the caller is told the build worked. That is how
        # D166's guard came to be inert on its first outing: cfg_compile_sonic
        # returned 1 from the host and 0 from inside the container, for the same
        # failed compile.
        scheme -q --libdirs "$ROOT/sonic/src:$ROOT/sonic/vendor/nanopass" --script "$drv" \
            || return 1
    else
        "$ROOT/tools/container.sh" bash -c \
            "scheme -q --libdirs /work/sonic/src:/work/sonic/vendor/nanopass --script /work/build/nbody/sonic-u4-build.ss" \
            || return 1
    fi
    chmod +x "$BUILD/sonic-u4"
}
cfg_run_sonic_u4() { echo "$BUILD/sonic-u4 $1"; }

# --- the same compiler, allowed to fuse a multiply-add ----------------------
#
# THE ONE CAPABILITY c-native HAS AND WE DID NOT USE. Counted from the emitted
# binaries, we already emit MORE packed arithmetic than `gcc -O3 -march=native`
# does -- 36 against 25 -- and c-native uses no 256-bit at all: 748 xmm, zero
# ymm, zero zmm. What it has and stock sonic has none of is 81 fused
# multiply-adds.
#
# contract.ss can produce them, is wired into driver.ss, and has 15 passing
# assertions. It emitted nothing because D24 makes `fp-contract` a named,
# lexically-scoped permission defaulting to OFF, and config-sonic.sps never
# granted it -- while gcc -O3 takes -ffp-contract=fast by default. Milestone 5
# was comparing a non-contracted build against a contracted one.
#
# A SEPARATE CONFIGURATION rather than a change to config-sonic.sps, following
# sonic-u4 and sonic-pad4: the standing number stays comparable and the two can
# be measured against each other in one run.
#
# CORRECTNESS. SPEC.md asks for nine decimal places, not bit exactness, and this
# build agrees there. It is NOT bit-identical to stock -- the second energy
# differs by 2 ULP -- which is the same relationship c-native has to c-scalar,
# both of which publish -0.169087605. A fused multiply-add rounds once where two
# instructions round twice; that is the point of it.
cfg_src_sonic_fma() { echo "config-sonic-fma.sps"; }
cfg_compile_sonic_fma() {
    local drv="$BUILD/sonic-fma-build.ss"
    cat > "$drv" <<EOF
(import (chezscheme) (sonic driver) (sonic pipeline))
(compile-sonic-to-file "$CBENCH/config-sonic-fma.sps" nbody-externs "$CBUILD/sonic-fma")
EOF
    . "$ROOT/tools/container.sh"
    if sonic_in_container; then
        # `|| return 1` on BOTH branches, not just the re-exec one. Without it
        # the chmod below is the function's last command, it succeeds whatever
        # the compile did, and the caller is told the build worked. That is how
        # D166's guard came to be inert on its first outing: cfg_compile_sonic
        # returned 1 from the host and 0 from inside the container, for the same
        # failed compile.
        scheme -q --libdirs "$ROOT/sonic/src:$ROOT/sonic/vendor/nanopass" --script "$drv" \
            || return 1
    else
        "$ROOT/tools/container.sh" bash -c \
            "scheme -q --libdirs /work/sonic/src:/work/sonic/vendor/nanopass --script /work/build/nbody/sonic-fma-build.ss" \
            || return 1
    fi
    chmod +x "$BUILD/sonic-fma"
}
cfg_run_sonic_fma() { echo "$BUILD/sonic-fma $1"; }

# --- the same compiler, targeting RISC-V --------------------------------------
#
# NOT IN $CONFIGS, and opt-in by name: `harness/measure.sh sonic-rv64`. These run
# under qemu-riscv64, so they are INSTRUCTION-COUNTABLE AND NOT TIMEABLE -- an
# emulator's wall clock measures the emulator. $EMULATED below is what makes that
# refusal automatic rather than remembered.
#
# Worth having because RV64 was unmeasurable until D83: the runtime did not walk
# argv, so nbody ignored its argument, and count-slope.sh correctly refused a
# slope for a program whose count never changed. With argv walking, both
# instruments answer:
#
#     sonic-rv64        1386.00 instructions/step
#     sonic-rv64-fma    1291.00
#     sonic              664.00
#     sonic-fma          596.00
#
# 2.09x, which is the shape a load/store ISA should have -- three instructions to
# address where x86-64 needs zero -- with SLP gated off for want of an RV64
# packed lowering (qaq.13).
cfg_src_sonic_rv64() { echo "config-sonic.sps"; }
cfg_compile_sonic_rv64() {
    local drv="$BUILD/sonic-rv64-build.ss"
    cat > "$drv" <<EOF
(import (chezscheme) (sonic driver) (sonic pipeline))
(compile-sonic-to-file "$CBENCH/config-sonic.sps" nbody-externs "$CBUILD/sonic-rv64" 'rv64)
EOF
    . "$ROOT/tools/container.sh"
    if sonic_in_container; then
        # `|| return 1` on BOTH branches, not just the re-exec one. Without it
        # the chmod below is the function's last command, it succeeds whatever
        # the compile did, and the caller is told the build worked. That is how
        # D166's guard came to be inert on its first outing: cfg_compile_sonic
        # returned 1 from the host and 0 from inside the container, for the same
        # failed compile.
        scheme -q --libdirs "$ROOT/sonic/src:$ROOT/sonic/vendor/nanopass" --script "$drv" \
            || return 1
    else
        "$ROOT/tools/container.sh" bash -c \
            "scheme -q --libdirs /work/sonic/src:/work/sonic/vendor/nanopass --script /work/build/nbody/sonic-rv64-build.ss" \
            || return 1
    fi
    chmod +x "$BUILD/sonic-rv64"
}
# NO `qemu-riscv64` PREFIX. The instruments pick the emulator themselves, from
# the binary's own e_machine byte (D83) -- naming it here instead made callgrind
# count QEMU rather than the guest, and it did not fail: it reported -0.00
# instructions per step, a plausible-looking number about the wrong program.
# That is the exact hazard count-slope.sh's two-N check exists for, arriving by a
# route the check cannot see, because both counts were of a real process.
cfg_run_sonic_rv64() { echo "$BUILD/sonic-rv64 $1"; }

cfg_src_sonic_rv64_fma() { echo "config-sonic-fma.sps"; }
cfg_compile_sonic_rv64_fma() {
    local drv="$BUILD/sonic-rv64-fma-build.ss"
    cat > "$drv" <<EOF
(import (chezscheme) (sonic driver) (sonic pipeline))
(compile-sonic-to-file "$CBENCH/config-sonic-fma.sps" nbody-externs "$CBUILD/sonic-rv64-fma" 'rv64)
EOF
    . "$ROOT/tools/container.sh"
    if sonic_in_container; then
        # `|| return 1` on BOTH branches, not just the re-exec one. Without it
        # the chmod below is the function's last command, it succeeds whatever
        # the compile did, and the caller is told the build worked. That is how
        # D166's guard came to be inert on its first outing: cfg_compile_sonic
        # returned 1 from the host and 0 from inside the container, for the same
        # failed compile.
        scheme -q --libdirs "$ROOT/sonic/src:$ROOT/sonic/vendor/nanopass" --script "$drv" \
            || return 1
    else
        "$ROOT/tools/container.sh" bash -c \
            "scheme -q --libdirs /work/sonic/src:/work/sonic/vendor/nanopass --script /work/build/nbody/sonic-rv64-fma-build.ss" \
            || return 1
    fi
    chmod +x "$BUILD/sonic-rv64-fma"
}
cfg_run_sonic_rv64_fma() { echo "$BUILD/sonic-rv64-fma $1"; }

# Configurations that run under an emulator. Their instruction counts are real --
# qemu counts guest instructions exactly -- and their WALL CLOCK is not, because
# it is the emulator's. bench.sh refuses these by name so nobody has to remember.
EMULATED="sonic-rv64 sonic-rv64-fma"

# --- four-lane packing, which needs a padded layout AND a written pad ---------
#
# The first configuration in this table to emit 256-bit packed arithmetic.
# `bench/nbody/config-sonic-pad4.sps` is config-sonic.sps with a stride of 4
# instead of 3 and the pad slot written; slp.ss's four-lane arm is enabled with
# the parameter it has always had and nothing ever set.
#
# BOTH HALVES ARE REQUIRED AND THAT WAS NOT THE PREDICTION. slp.ss says
# four-lane is "off until a padded layout exists to point it at". A padded
# layout alone changes nothing -- measured, ymm=0 -- because `store-at` seeds
# from four stores sharing a base and an index vreg, and a program that leaves
# slot 3 alone still emits three. With the pad WRITTEN: ymm=2, vmulpd and vaddpd
# on ymm in both halves of the unrolled position update.
#
# The energies are bit-identical to config-sonic.sps, which is the check that
# says the layout changed and the arithmetic did not.
cfg_src_sonic_pad4() { echo "config-sonic-pad4.sps"; }
cfg_compile_sonic_pad4() {
    local drv="$BUILD/sonic-pad4-build.ss"
    cat > "$drv" <<EOF
(import (chezscheme) (sonic driver) (sonic pipeline) (sonic slp))
(parameterize ((four-lane-packing? #t))
  (compile-sonic-to-file "$CBENCH/config-sonic-pad4.sps" nbody-externs "$CBUILD/sonic-pad4"))
EOF
    . "$ROOT/tools/container.sh"
    if sonic_in_container; then
        # `|| return 1` on BOTH branches, not just the re-exec one. Without it
        # the chmod below is the function's last command, it succeeds whatever
        # the compile did, and the caller is told the build worked. That is how
        # D166's guard came to be inert on its first outing: cfg_compile_sonic
        # returned 1 from the host and 0 from inside the container, for the same
        # failed compile.
        scheme -q --libdirs "$ROOT/sonic/src:$ROOT/sonic/vendor/nanopass" --script "$drv" \
            || return 1
    else
        "$ROOT/tools/container.sh" bash -c \
            "scheme -q --libdirs /work/sonic/src:/work/sonic/vendor/nanopass --script /work/build/nbody/sonic-pad4-build.ss" \
            || return 1
    fi
    chmod +x "$BUILD/sonic-pad4"
}
cfg_run_sonic_pad4() { echo "$BUILD/sonic-pad4 $1"; }

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

# --- configuration 1: the floor, R5RS --------------------------------------
# Specified as portable R7RS-small until phase 1 found (scheme base) resolves
# on neither implementation. R5RS is the oldest standard that runs on both.
# N arrives on stdin because R5RS has no command line and no environment.

cfg_src_chez_1() { echo "config1.scm"; }
cfg_compile_chez_1() {
    cp "$BENCH/config1.scm" "$BUILD/chez-1.ss"
    scheme -q >/dev/null <<EOF
(optimize-level 2)
(compile-file "$BUILD/chez-1.ss")
EOF
    test -f "$BUILD/chez-1.so"
}
# A generated wrapper, not an inline pipeline: the run command passes through
# echo and eval in three different scripts, and embedded quoting does not
# survive that intact.
cfg_run_chez_1() {
    cat > "$BUILD/chez-1.sh" <<'EOS'
#!/bin/sh
echo "$2" | scheme -q --script "$1"
EOS
    chmod +x "$BUILD/chez-1.sh"
    echo "$BUILD/chez-1.sh $BUILD/chez-1.so $1"
}

cfg_src_racket_1() { echo "config1.scm"; }
cfg_compile_racket_1() {
    { printf '#lang r5rs\n'; cat "$BENCH/config1.scm"; } > "$BUILD/racket-1.rkt"
    raco make "$BUILD/racket-1.rkt" >/dev/null 2>&1
    test -f "$BUILD/compiled/racket-1_rkt.zo"
}
cfg_run_racket_1() {
    cat > "$BUILD/racket-1.sh" <<'EOS'
#!/bin/sh
echo "$2" | PLT_COMPILED_FILE_CHECK=exists racket "$1"
EOS
    chmod +x "$BUILD/racket-1.sh"
    echo "$BUILD/racket-1.sh $BUILD/racket-1.rkt $1"
}

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

# --- configuration 2b: Tangerine over a shim we ship ------------------------
# Same source as 2a with one change: storage moves from a boxed `vector` to a
# bytevector accessed through bytevector-ieee-double-native-ref/set!, which is
# portable R6RS and is what SRFI 160's f64vector amounts to.

cfg_src_chez_2b() { echo "config2b.sps"; }
cfg_compile_chez_2b() {
    cp "$BENCH/config2b.sps" "$BUILD/chez-2b.sps"
    scheme -q --optimize-level 2 >/dev/null <<EOF
(compile-program "$BUILD/chez-2b.sps")
EOF
    test -f "$BUILD/chez-2b.so"
}
cfg_run_chez_2b() { echo "scheme --program $BUILD/chez-2b.so $1"; }

cfg_src_racket_2b() { echo "config2b.sps"; }
cfg_compile_racket_2b() {
    cp "$BENCH/config2b.sps" "$BUILD/racket-2b.sps"
    raco make "$BUILD/racket-2b.sps" >/dev/null
    test -f "$BUILD/compiled/racket-2b_sps.zo"
}
cfg_run_racket_2b() {
    echo "env PLT_COMPILED_FILE_CHECK=exists racket -I r6rs $BUILD/racket-2b.sps $1"
}

# --- configuration 2c: predicate-guarded at optimize-level 2 ---------------
cfg_src_chez_2c() { echo "config2c-chez.ss"; }
cfg_compile_chez_2c() {
    cp "$BENCH/config2c-chez.ss" "$BUILD/chez-2c.ss"
    scheme -q >/dev/null <<EOF
(optimize-level 2)
(compile-file "$BUILD/chez-2c.ss")
EOF
    test -f "$BUILD/chez-2c.so"
}
cfg_run_chez_2c() { echo "scheme -q --optimize-level 2 --script $BUILD/chez-2c.so $1"; }

# --- the check-isolation control ------------------------------------------
# config4-chez.ss compiled at optimize-level 2 instead of 3. Same source, same
# flvector storage, same operators: the ONLY difference is whether Chez emits
# checks. So (chez-4-safe - chez-4) is the cost of checking with storage held
# constant, which is the one thing the 2a-to-4 delta cannot separate.

cfg_src_chez_4_safe() { echo "config4-chez.ss"; }
cfg_compile_chez_4_safe() {
    cp "$BENCH/config4-chez.ss" "$BUILD/chez-4-safe.ss"
    scheme -q >/dev/null <<EOF
(optimize-level 2)
(compile-file "$BUILD/chez-4-safe.ss")
EOF
    test -f "$BUILD/chez-4-safe.so"
}
cfg_run_chez_4_safe() { echo "scheme -q --optimize-level 2 --script $BUILD/chez-4-safe.so $1"; }

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
cfg_run_sbcl_5() { echo "env NBODY_N=$1 sbcl --core $BUILD/sbcl-5.core --noinform --end-runtime-options"; }

# --- configuration 9: the same CL source under ECL and CLISP ---------------
# Separates "Common Lisp is fast" from "SBCL is fast". CLISP largely ignores
# declarations, so it should be slow, and that result is the demonstration that
# the standard obliges implementors to ACCEPT the notation without obliging
# them to act on it.

cfg_src_ecl_9() { echo "config5.lisp"; }
cfg_compile_ecl_9() {
    cp "$BENCH/config5.lisp" "$BUILD/ecl-9.lisp"
    ecl -norc --eval "(progn (compile-file \"$BUILD/ecl-9.lisp\" :output-file \"$BUILD/ecl-9.fas\") (quit))" >/dev/null 2>&1
    test -f "$BUILD/ecl-9.fas"
}
cfg_run_ecl_9() {
    echo "env NBODY_N=$1 ecl -norc -q --load $BUILD/ecl-9.fas --eval (main) --eval (quit)"
}

cfg_src_clisp_9() { echo "config5.lisp"; }
cfg_compile_clisp_9() {
    cp "$BENCH/config5.lisp" "$BUILD/clisp-9.lisp"
    clisp -q -norc -x "(progn (compile-file \"$BUILD/clisp-9.lisp\") (quit))" >/dev/null 2>&1
    test -f "$BUILD/clisp-9.fas"
}
cfg_run_clisp_9() {
    echo "env NBODY_N=$1 clisp -q -norc -i $BUILD/clisp-9.fas -x (main)"
}

# --- configuration 8: Ada, three check policies ----------------------------
# RESEARCH.md section 2 ranks Ada above Common Lisp because it names each check
# and lets you suppress it at any scope, where CL bundles every risk into one
# 0-3 dial. LEDGER.md D5 adopts that design and is status:draft pending exactly
# this measurement: if All_Checks beats named suppression meaningfully, then
# granularity has a price and the proposal needs rewriting.
#
# One source, three builds. The only difference is the pragmas.

_ada_build() {  # $1 = config name, $2 = pragma block, $3 = extra gnat flags
    local d="$BUILD/$1"
    mkdir -p "$d"
    awk -v repl="$2" '/@SUPPRESS@/{print repl; next} {print}' \
        "$BENCH/nbody.adb" > "$d/nbody.adb"
    ( cd "$d" && gnatmake-15 -O2 $3 nbody.adb -o nbody >/dev/null 2>&1 )
    test -x "$d/nbody"
}

NAMED_PRAGMAS='   pragma Suppress (Index_Check);\n   pragma Suppress (Range_Check);\n   pragma Suppress (Overflow_Check);\n   pragma Suppress (Division_Check);'

# Ada's DEFAULT is stronger than C's: Index_Check, Range_Check and
# Overflow_Check are all on unless suppressed. This row is the honest baseline.
cfg_src_ada_8_checked() { echo "nbody.adb"; }
cfg_compile_ada_8_checked() { _ada_build ada-8-checked "" ""; }
cfg_run_ada_8_checked() { echo "$BUILD/ada-8-checked/nbody $1"; }

# The design we are copying: each check suppressed by name.
cfg_src_ada_8_named() { echo "nbody.adb"; }
cfg_compile_ada_8_named() { _ada_build ada-8-named "$(printf "$NAMED_PRAGMAS")" ""; }
cfg_run_ada_8_named() { echo "$BUILD/ada-8-named/nbody $1"; }

# The blunt instrument: -gnatp is pragma Suppress (All_Checks) program-wide.
cfg_src_ada_8_all() { echo "nbody.adb"; }
cfg_compile_ada_8_all() { _ada_build ada-8-all "" "-gnatp"; }
cfg_run_ada_8_all() { echo "$BUILD/ada-8-all/nbody $1"; }

# --- dispatch --------------------------------------------------------------
# Config names carry hyphens for readability; shell function names cannot.

cfg_fn() { echo "$1" | tr '-' '_'; }
cfg_src()     { "cfg_src_$(cfg_fn "$1")"; }
cfg_compile() { "cfg_compile_$(cfg_fn "$1")"; }
cfg_run()     { "cfg_run_$(cfg_fn "$1")" "$2"; }
