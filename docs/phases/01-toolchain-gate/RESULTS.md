# Phase 1 Results: The Tangerine Gate

Determined by reading implementation source, 2026-07-29. Not by probing. Both
implementations are open source and the question was answerable by reading them.

## Verdict: nobody implements Tangerine

Neither Chez Scheme nor Racket ships R7RS-large Tangerine's numeric libraries. The
standard is a dead letter seven years after it was assembled.

## Chez Scheme

Read from `cisco/ChezScheme` at commit `2026-06-10`, 35 MB shallow clone.

**No R7RS support of any kind.** A grep across every `.ss`, `.sls` and `.sps` file for
`(scheme base)`, `(scheme flonum)`, `(scheme fixnum)` and `(scheme vector` returns
nothing. The only occurrences of the string "r7rs" in the entire codebase are two
incidental comments, one in `s/read.ss:484` about R7RS boolean syntax and one in
`mats/6.ms:2060` noting that R7RS-style booleans are not R6RS.

**Full R6RS support, including both instruction-level hatches.** Shipped libraries
include:

```
(rnrs arithmetic bitwise)
(rnrs arithmetic fixnums)
(rnrs arithmetic flonums)
(rnrs base)
(rnrs bytevectors)
(rnrs chezscheme)
...
```

`(rnrs arithmetic fixnums)` and `(rnrs arithmetic flonums)` are exactly the 2007
standardized operator libraries that R7RS-small dropped.

**Native unboxed float storage.** `flvector` is a first-class primitive with a complete
set of operations defined in `s/5_1.ss`: `make-flvector`, `flvector-ref`,
`flvector-set!`, `flvector-length`, `flvector-fill!`, `flvector?`, plus
`flvector-pred`, `flvector*-pred` and `flvector-dispatch-table` internals. It appears
in `cptypes.ss` and `cptypes-lattice.ss`, which means the type recovery pass knows
about it, and in `cp0.ss`, the source optimizer.

**Native flonum operators.** `flsqrt`, `flabs`, `flfloor`, `flround` and the arithmetic
operators are primitives.

## Racket

Read from `racket/srfi`, 4.9 MB.

**The SRFI package tops out at SRFI 98.** Complete list of SRFIs shipped:

```
1 2 5 6 8 9 11 13 14 16 17 18 19 23 25 26 27 28 29 31 38 39
41 42 43 45 48 54 57 59 60 61 63 64 66 67 69 71 74 78 86 87 98
```

No SRFI 143 (fixnums), no 144 (flonums), no 145 (assumptions), no 160 (homogeneous
numeric vectors), no 253 (data type-checking).

**Native equivalents exist.** `racket/flonum` provides `flvector` and the `fl`
operators. `racket/unsafe/ops` provides unchecked variants including
`unsafe-flvector-ref`.

## How the r7rs-benchmarks corpus actually runs Chez

Worth recording, because it retroactively qualifies the numbers in `RESEARCH.md`
sections 3 and 4.

From `ecraven/r7rs-benchmarks`, the `bench` script, line 684:

```
time "${CHEZ}" --optimize-level 2 --compile-imported-libraries \
     --libdirs /home/nex/scheme/chez --program "$1" < "$2"
```

Three things follow.

First, Chez runs those benchmarks in R6RS top-level program mode via `--program`, with
`--libdirs` pointing at a hand-maintained local directory of shim libraries on the
author's machine. Chez's apparent R7RS support in that corpus is entirely a private
shim, not anything Chez ships.

Second, `--optimize-level 2`, not 3. So every Chez number quoted in `RESEARCH.md` is
safe-mode with checks on. The Chez-versus-Racket comparison remains fair, since both ran
safe. The Chez-versus-Stalin comparison understates Chez, because Stalin compiles with
its analysis fully applied while Chez was held at its safe default.

Third, the benchmark programs import only R7RS-small: `(scheme base)`, `(scheme write)`,
`(scheme time)`, `(scheme read)`, `(scheme file)`, `(scheme cxr)`, `(scheme char)`,
`(scheme inexact)`, `(scheme complex)`. Zero Tangerine imports anywhere in the corpus.
That corroborates the caveat already recorded in `RESEARCH.md` section 4: the corpus
measures each implementation's generic safe path.

## Consequences for the experiment

**Configuration 2 as originally specified is not writeable.** There is no
implementation on which `(import (scheme flonum) (scheme vector f64))` resolves. The
configuration has to be redefined.

**The portable path that actually exists is R6RS, not R7RS-large.** Chez ships
`(rnrs arithmetic flonums)` and `(rnrs arithmetic fixnums)`. Racket does not ship the
R6RS arithmetic libraries either, but Racket has native equivalents. So R6RS is the only
standardized instruction-level hatch with a real implementation behind it, and it has
been available since 2007.

**The finding is stronger than a measured delta.** The escape hatches were standardized
in R6RS in 2007, removed by R7RS-small in 2013, nominally restored by R7RS-large
Tangerine in 2019, and remain unimplemented by either leading implementation in 2026.
That is a more interesting result than any number this project was going to produce, and
it should lead the write-up.

---

# Runtime results, 2026-08-06

Run against the installed toolchains. Four of the five outstanding items are now answered.

## SRFI 145 is unobtainable, so configuration 3 needs redefining too

Confirmed at runtime what the source reading predicted:

```
$ echo '(import (srfi :145))' | scheme -q
Exception: library (srfi :145) not found

$ racket -e '(require srfi/145)'
open-input-file: cannot open module file
  path: /usr/share/racket/pkgs/srfi-lite-lib/srfi/145.rkt
```

Racket's SRFI 144 is absent by the same path. The R6RS flonum library does work in Chez
with no `--libdirs` shim needed:

```
$ echo '(import (rnrs arithmetic flonums)) (display (flsqrt 2.0))' | scheme -q
1.4142135623730951
```

**This is the same finding as configuration 2, one level up, and it is worth more than
the delta configuration 3 was going to measure.** There is no implementation on which a
*premise* can be portably expressed at all. SRFI 145 is the only standardized notation
for one and neither leading implementation ships it. So configuration 3 is not writeable
as specified, and it should be rebuilt around what each implementation actually accepts
as a premise: a predicate guard that Chez's `cptypes` narrows on, which is exactly
configuration 2c, and nothing at all on the Racket side, since `racket/unsafe/ops` has no
premise notion and only an unchecked-operator notion.

The R7RS-large story and the premise story are therefore the same story: standardized,
then unimplemented.

## sb-simd loads, and tops out two vector widths below the hardware

`(require :sb-simd)` succeeds on packaged SBCL 2.6.0. The packages it defines:

```
SB-SIMD  SB-SIMD-AVX  SB-SIMD-AVX2  SB-SIMD-FMA  SB-SIMD-INTERNALS
SB-SIMD-SSE  SB-SIMD-SSE2  SB-SIMD-SSE3  SB-SIMD-SSE4.1  SB-SIMD-SSE4.2
SB-SIMD-SSSE3  SB-SIMD-X86-64
```

**There is no `SB-SIMD-AVX512` package.** The contrib stops at AVX2, 256-bit.

The machine is an AMD Ryzen AI MAX+ PRO 395 (Zen 5) and `/proc/cpuinfo` reports
`avx512f avx512dq avx512cd avx512bw avx512vl avx512_vnni avx512_bf16 avx512vbmi
avx512_vbmi2 avx512ifma avx512_bitalg avx512_vpopcntdq avx512_vp2intersect`. Full
512-bit AVX-512 is present and `gcc -O3 -march=native` can reach it.

Two consequences, and the second one matters more than the first.

**It strengthens the case for excluding `sb-simd` from configuration 5**, which was
already the decision. A comparison that pitted 256-bit hand-written CL intrinsics against
512-bit gcc autovectorization would be measuring vector width, not language.

**It hands phase 7 stage 10 a target that SBCL structurally cannot reach.** The
CL-versus-C vectorization gap on this hardware is not a tuning gap; the intrinsics simply
do not exist in the implementation. A Scheme compiler emitting x86-64 directly has no such
ceiling. This is the clearest instance so far of the project's thesis, and it arrived from
a `require` rather than from a benchmark.

## perf works, needs no sudo, and is exactly deterministic

`perf` was absent and `linux-perf` wants root to install. It does not have to be
installed. Extracted to the scratchpad instead, same technique as the earlier
`libasound` fix:

```
apt-get download linux-perf libdw1t64 libdebuginfod1t64 libtraceevent1
dpkg-deb -x each .deb into a prefix
LD_LIBRARY_PATH=<prefix>/usr/lib/x86_64-linux-gnu <prefix>/usr/bin/perf
```

`perf version 7.0.12`, running unprivileged at `perf_event_paranoid` 2.

**The counters are real hardware counters, not synthetic.** A `gcc -O1
-fno-tree-vectorize` accumulation loop, three problem sizes:

| N | instructions | delta |
|---|---|---|
| 10,000,000 | 70,123,493 | |
| 20,000,000 | 140,123,501 | 70,000,008 |
| 40,000,000 | 280,123,513 | 140,000,012 |

Exactly 7.0000 instructions per iteration with ~123,485 constant startup, linear across
a 4x range. A synthetic or sampled counter cannot produce that.

**This changes the instrument, not just the diagnostics.** This machine has no `cpufreq`
access, so wall-clock ratios drift and only closely-spaced comparisons are trustworthy.
Retired instruction counts do not drift. A bounds check that gets elided is a
compare-and-branch that stops being retired, so **instruction count measures check
elision directly and noise-free** — which is the single number phase 3 exists to
produce. Bootstrap CIs still govern every time-based delta; counts do not need them.

## Docker would not help, and the reason is architectural

Considered running the benchmarks in Docker Desktop to escape WSL2 overhead. It does not
escape anything: WSL2 runs **one** utility VM shared by all distros, and Docker Desktop's
engine is a distro inside it.

```
this shell:  boot_id 53fc36a4-47e6-49ab-80e2-9f33bd761e37  MemTotal 12242652 kB
container:   boot_id 53fc36a4-47e6-49ab-80e2-9f33bd761e37  MemTotal 12242652 kB
```

Same kernel instance, same memory pool, uptimes three seconds apart. `docker info`
reporting 12,536,475,648 bytes is this VM's `memory=12GB` from `.wslconfig`, not an
allocation Docker manages. Its cgroup limits are ceilings *below* the shared pool and
can only constrain. `cpufreq` is absent inside containers too, and the L3 sibling list
still reads `0-31`, so neither real WSL2 cost is addressed.

**One actionable finding from looking:** `.wslconfig` sets
`autoMemoryReclaim=gradual`, which periodically walks and returns memory to Windows.
That is a background stall source and it belongs to the noise floor phase 2 measures.
Turn it off before calibrating, or the floor absorbs it.

## Still outstanding

- The AOT recipes, one per implementation.
- The recompilation trap test, which is the acceptance criterion that catches the single
  most common failure mode for a benchmark of this kind.
- `bench/nbody/SPEC.md`: the initial conditions, expected energies and expression order
  that every variant is written against. **Not** an extraction from the Benchmarks Game
  zip, which per `LEDGER.md` D16 we no longer depend on in any form.
