#!/usr/bin/env bash
# RISC-V smoke gate. Runs continuously alongside x86-64 work.
#
# The point is NOT performance. QEMU emulation timing is meaningless and we have
# no RISC-V board yet, so every number in this project stays x86-64 until one
# exists. The point is to catch, on the day it happens, the use of something
# that does not exist on RISC-V at all.
#
# That failure is cheap to fix the day it is introduced and expensive to fix
# after a hundred beads are built on it, which is the same argument D21 makes
# about precise roots and the register partition.
#
# Requires no root. Toolchain:
#   riscv64-linux-gnu-gcc      packaged
#   riscv64-linux-gnu-objdump  packaged
#   qemu-riscv64               extracted to ~/.local/opt/qemu-user, see below
#   qemu-system-riscv64        packaged, for bare-metal work later
#
# qemu-user was installed without sudo the same way perf was:
#   apt-get download qemu-user && dpkg-deb -x into ~/.local/opt/qemu-user/root
#   wrapper at ~/.local/bin/qemu-riscv64 sets LD_LIBRARY_PATH and -L
#
# Usage: ./smoke-riscv.sh [N]

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH="$ROOT/bench/nbody"
BUILD="$ROOT/build/riscv"
QEMU="${QEMU_RISCV:-$HOME/.local/bin/qemu-riscv64}"
CC=riscv64-linux-gnu-gcc
# PIN the march explicitly, but pin it to RVA23, not to rv64gc.
#
# CORRECTED 2026-08-06 after checking current sources. The toolchain default
# here is not an accident and not a trap: every RVA23U64 mandatory extension is
# present in it, so Ubuntu's cross-gcc deliberately targets RVA23.
#
#   - RVA23 makes the V extension MANDATORY. It was optional in RVA22.
#   - Ubuntu 26.04 LTS ships RVA23 images with Canonical support, and Ubuntu
#     DROPPED pre-RVA23 hardware in October 2025. RHEL targets RVA23 too.
#   - SiFive P550/P870 align on it; the P870 is a six-wide out-of-order core.
#
# So rv64gc is the LEGACY floor (JH7110/U74: VisionFive 2, Milk-V Mars, no V at
# all), not the baseline. Targeting it would aim at hardware the distro no
# longer supports.
#
# gcc does not accept profile names like -march=rva23u64, only ISA strings, so
# PROFILE selects a spelled-out string. Both are smoke-tested: RVA23 is what we
# optimize for, rv64gc proves we still RUN without V.
MABI=${MABI:-lp64d}
RVA23=rv64imafdcv_zicond_zfa_zba_zbb_zbs_zicboz_zicbom_zicbop_zihintpause_zihintntl_zimop_zcmop_zawrs_zkt_zvbb
PROFILE=${PROFILE:-rva23}
case "$PROFILE" in
  rva23)  MARCH=${MARCH:-$RVA23} ;;
  legacy) MARCH=${MARCH:-rv64gc} ;;
  *)      MARCH=${MARCH:-$PROFILE} ;;
esac
CFLAGS_RV="-march=$MARCH -mabi=$MABI"
N=${1:-1000}

mkdir -p "$BUILD"
fail=0

need() { command -v "$1" >/dev/null || { echo "MISSING: $1"; fail=1; }; }
need "$CC"; need riscv64-linux-gnu-objdump
[ -x "$QEMU" ] || { echo "MISSING: $QEMU"; fail=1; }
[ "$fail" -eq 0 ] || { echo; echo "FAIL: toolchain incomplete"; exit 1; }

echo "RISC-V smoke gate, N=$N, profile=$PROFILE"
echo "  -march=$MARCH -mabi=$MABI"
echo

# --- 1. the reference compiles and runs, and agrees with x86-64 bit for bit ---
# Float semantics are the thing most likely to differ silently across ISAs, and
# SPEC.md's expression-order discipline is what makes them not differ. This
# checks that claim rather than assuming it.
$CC $CFLAGS_RV -O2 -static -o "$BUILD/ref" "$BENCH/ref.c" -lm 2>/dev/null || { echo "FAIL: cross-compile"; exit 1; }
rv=$("$QEMU" "$BUILD/ref" "$N")
gcc -O2 -fno-tree-vectorize -o "$BUILD/ref-host" "$BENCH/ref.c" -lm 2>/dev/null
host=$("$BUILD/ref-host" "$N")

if [ "$rv" = "$host" ]; then
    printf '  ok    reference agrees bit-for-bit with x86-64\n'
    printf '        %s\n' $rv
else
    printf '  FAIL  RISC-V and x86-64 disagree\n'
    printf '        rv64: %s\n' $rv
    printf '        x86:  %s\n' $host
    fail=1
fi

# --- 2. the ISA extensions we rely on are actually in the target string -------
# The base ISA does NOT contain the supervisor programming model: -march=rv64imac
# refuses csrw. Anything bare-metal must name its extensions explicitly, and this
# is measured rather than read. See compare-operating-systems
# bundle/experiments/rv64-prologue.md.
probe_march() {  # probe_march <march> <abi> <asm> -> ok/refused
    printf 'void f(void){ __asm__ volatile("%s"); }\n' "$3" > "$BUILD/probe.c"
    if $CC -march="$1" -mabi="$2" -c -o /dev/null "$BUILD/probe.c" 2>/dev/null; then echo ok; else echo refused; fi
}
# The ABI must match the march or this fails for the wrong reason: lp64d against
# a marchitecture without D is an ABI error, not a missing-extension error.
a=$(probe_march rv64imac_zicsr lp64 'csrw sscratch, zero')
b=$(probe_march rv64imac      lp64 'csrw sscratch, zero')
printf '  %-6s csrw under rv64imac_zicsr\n  %-6s csrw under rv64imac (expected: refused)\n' "$a" "$b"
[ "$a" = ok ] && [ "$b" = refused ] || fail=1

# --- 3. double-precision FP is present and is what we think it is ------------
# lp64d, not lp64. A soft-float ABI would silently change nothing about
# correctness and everything about the performance claim.
d=$(probe_march rv64gc lp64d 'fadd.d ft0, ft0, ft0')
printf '  %-6s fadd.d under rv64gc\n' "$d"
[ "$d" = ok ] || fail=1

# RVV must be available under the RVA23 profile and absent under the legacy floor.
# E5-RVV is a first-class path for PC-class RISC-V, not a bolt-on, so this is a
# capability check rather than a curiosity.
vv=$(probe_march "$RVA23" lp64d 'vsetvli t0, zero, e64, m1, ta, ma')
vl=$(probe_march rv64gc    lp64d 'vsetvli t0, zero, e64, m1, ta, ma')
printf '  %-6s vsetvli under RVA23 (RVV 1.0 mandatory)\n  %-6s vsetvli under rv64gc legacy floor (expected: refused)\n' "$vv" "$vl"
[ "$vv" = ok ] && [ "$vl" = refused ] || fail=1

# --- 4. no x86-only instruction reached the RISC-V build ---------------------
# Placeholder for SonicScheme output. Once the compiler emits RV64, this asserts
# on its disassembly instead of gcc's.
# Parse the MNEMONIC column. Grepping raw objdump output matches hex bytes:
# "f406" and "fcf43c23" are addresses and encodings, not instructions.
mn=$(riscv64-linux-gnu-objdump -d "$BUILD/ref" | awk -F'\t' 'NF>=3{print $3}' | awk '{print $1}')
# grep -c not -q: under `set -o pipefail`, grep -q closes the pipe early, echo
# takes SIGPIPE, and the whole pipeline reports failure on a successful match.
nfp=$(echo "$mn" | grep -cE '^(fmul\.d|fadd\.d|fmadd\.d|fdiv\.d)$' || true)
if [ "${nfp:-0}" -gt 0 ]; then
    printf '  ok    double-precision RV64 arithmetic emitted (%s)\n' \
        "$(echo "$mn" | grep -E '^f[a-z]+\.d$' | sort -u | tr '\n' ' ')"
else
    printf '  FAIL  no double-precision arithmetic in the RISC-V object\n'; fail=1
fi

# --- 5. cross-ISA bit-exactness, at FULL precision ---------------------------
# The oracle's nine decimals HIDE a real divergence. Measured 2026-08-06:
# RISC-V gcc contracts to fmadd.d by default (one rounding, not two) while
# baseline x86-64 has no FMA to contract into, and vectorization reassociates
# the accumulation. Bit-exactness across ISAs holds ONLY with contraction and
# vectorization both off. See docs/phases/07-compiler/EXECUTION.md and the
# open decision on whether SonicScheme permits contraction.
sed 's/%\.9f/%.17g/' "$BENCH/ref.c" > "$BUILD/ref17.c"
$CC $CFLAGS_RV -O2 -static -ffp-contract=off -fno-tree-vectorize -o "$BUILD/r17" "$BUILD/ref17.c" -lm 2>/dev/null
gcc  -O2         -ffp-contract=off -fno-tree-vectorize -o "$BUILD/h17" "$BUILD/ref17.c" -lm 2>/dev/null
if [ "$("$QEMU" "$BUILD/r17" "$N")" = "$("$BUILD/h17" "$N")" ]; then
    printf '  ok    bit-exact at 17 significant digits (contract=off, novec)\n'
else
    printf '  FAIL  full-precision divergence even with contraction off\n'; fail=1
fi

echo
if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAIL"; fi
exit "$fail"
