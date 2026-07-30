# Phase 1 CUJ: Toolchain and the Tangerine Gate

Technical implementation document. The journey here is an operator sitting down at a
clean machine and ending with a written verdict on whether portable tuned numeric
Scheme is expressible at all.

Companion to `PLAN.md` in this directory, which covers why. This covers how.

## Journey summary

The operator installs toolchains, then runs a probe per implementation that attempts
to import each Tangerine numeric library and reports what resolved. Then a second,
harder probe determines whether `assume` actually buys anything by reading emitted
code rather than trusting a timing. Then the ahead-of-time compilation recipes get
written and verified against a deliberate trap: touch the source mtime and confirm
the reported time does not move. The phase ends with a support matrix and a go or
no-go on configurations 2 and 3.

## Preconditions

- Ubuntu 26.04 on WSL2, kernel 6.18.33.2-microsoft.
- `gcc` 15.2.0 present.
- Repo checked out, `docs/` populated.
- Benchmarks Game corpus available. Already fetched to the session scratchpad; if
  absent, re-clone from `salsa.debian.org/benchmarksgame-team/benchmarksgame`.

## Step 1: install

```
sudo apt-get install --no-install-recommends \
    sbcl chezscheme racket hyperfine unzip \
    gnat-15 ecl clisp
```

`stalin` is deliberately not in this line. Install it only if phase 4 gets that far.

Expected: about 1.1 GB across roughly 40 packages. No sudo elsewhere in this phase.

Verification, one command per toolchain, recording versions into the support matrix:

```
sbcl --version
chezscheme --version          # or: scheme --version
racket --version
hyperfine --version
gnatmake --version
ecl --version
clisp --version
gcc --version
```

Failure branch: if `chezscheme` installs a binary under a different name, find it with
`dpkg -L chezscheme | grep bin/` and record the real invocation. Do not guess.

## Step 2: the Tangerine probe

This is the phase's reason for existing. Write one probe per implementation that
attempts each import independently, so a single failure does not mask the rest.

Target libraries, from the Tangerine edition:

| library | SRFI | what it gives |
|---|---|---|
| `(scheme flonum)` | 144 | `fl+`, `fl*`, `flsqrt` and the rest |
| `(scheme fixnum)` | 143 | `fx+`, `fx*` and the rest |
| `(scheme vector f64)` | 160 | `f64vector`, `f64vector-ref`, unboxed storage |
| `(scheme bitwise)` | 151 | not needed for nbody, probe anyway |

Probe shape, one import per file so failures isolate:

```scheme
;; probe-scheme-flonum.scm
(import (scheme base) (scheme write) (scheme flonum))
(display (fl+ 1.0 2.0)) (newline)
```

```scheme
;; probe-scheme-vector-f64.scm
(import (scheme base) (scheme write) (scheme vector f64))
(let ((v (make-f64vector 4 1.5)))
  (display (f64vector-ref v 2)) (newline))
```

Run each under each implementation's R7RS mode. Exact invocations are
implementation-specific and are themselves an output of this step, so record them:

- Chez: R7RS library support exists but the invocation for loading an R7RS program
  differs from loading a script. Determine and record it.
- Racket: R7RS support arrives through a package rather than the core distribution.
  Determine whether it is installed, and if not whether `raco pkg install r7rs`
  is needed.

Then probe the native equivalents separately, because these are what configuration 4
will actually use and they are near-certain to exist:

```scheme
;; Chez native
(display (fl+ 1.0 2.0))
(let ((v (make-flvector 4 1.5))) (display (flvector-ref v 2)))
```

```racket
#lang racket/base
(require racket/flonum racket/unsafe/ops)
(displayln (fl+ 1.0 2.0))
(define v (make-flvector 4 1.5))
(displayln (flvector-ref v 2))
(displayln (unsafe-flvector-ref v 2))
```

Record into a matrix with four states per cell: native, via portable SRFI shim,
absent, or unknown. Do not collapse "absent" and "absent under the R7RS shim" into one
value, because they have different consequences for the proposal.

Failure branch, the one that matters: if `(scheme flonum)` and `(scheme vector f64)`
resolve nowhere, configuration 2 cannot be written as specified. Fall back in this
order, and record which was used:

1. Standalone SRFI 143, 144 and 160 reference implementations, loaded as libraries.
2. Native `flvector` plus native `fl` operators, with a portability caveat attached to
   every number derived from it.

Either fallback is a publishable finding. "The standard exists and nobody ships it" is
a stronger result than a small performance delta would be.

## Step 3: the `assume` optimization-license probe

Harder, because a conforming implementation may treat `(assume expr)` as a checked
assertion, as a no-op, or as an optimization license, and timing alone will not
distinguish the first two from each other reliably at this scale.

Read the emitted code. Write two versions of one procedure, identical except for the
assumption:

```scheme
(define (ref-checked v i) (f64vector-ref v i))
(define (ref-assumed v i)
  (assume (fixnum? i))
  (assume (f64vector? v))
  (f64vector-ref v i))
```

Then inspect, per implementation:

- Chez: `(expand/optimize '(lambda (v i) ...))` shows source-level output after the
  optimizer. For machine code, set the assembly-output parameter. Compare whether a
  bounds or type check disappears.
- Racket: `raco decompile` on the compiled zo file.
- SBCL, for the comparison baseline: `(disassemble #'ref-assumed)` against the same
  procedure with `(declare (type fixnum i))`.

Record a three-way verdict per implementation: honors as optimization license, treats
as runtime check, or ignores entirely.

Expected outcome, stated so we notice if it is wrong: no implementation honors it as a
license. SRFI 145 sits in no ratified edition, and support is likely to be a plain
assertion where it exists at all. If that holds, configuration 3 measures the cost of
an unratified proposal, which is still worth one data point.

## Step 4: the `sb-simd` check

```lisp
(require :sb-simd)
(describe 'sb-simd:f64.4+)
```

Confirm it loads on packaged SBCL 2.6.0 and that AVX-512 is detected. Only needed to
confirm configuration 5 correctly excludes it. If the Ubuntu build omits the contrib,
record that and note that SBCL from source would be required to measure the SIMD
ceiling later.

## Step 5: AOT recipes

The trap this step exists to avoid: Racket without `raco make` recompiles from source
on every invocation, which would make it look catastrophically slow for reasons
unrelated to Racket. Chez without `compile-program` interprets. Both would silently
produce a wrong answer.

Write one recipe per implementation into `harness/compile.sh`, dispatching on
configuration name:

| implementation | compile step | run step |
|---|---|---|
| Chez | `compile-program` or `compile-file` | run the compiled object |
| Racket | `raco make` | `racket` on the compiled module |
| SBCL | `compile-file` to fasl, or `save-lisp-and-die` for a core | run the core or load the fasl |
| gcc | `gcc -O2 -fno-tree-vectorize` and `-O3 -march=native` | run the binary |
| GNAT | `gnatmake` | run the binary |
| ECL, CLISP | `compile-file` | load the compiled output |

## Step 6: the recompilation trap test

This is the acceptance gate for step 5 and it must be automated, because it is easy to
pass by accident and easy to fail without noticing.

For every configuration:

1. Compile.
2. Run once, record time A.
3. Run again, record time B. Assert B is not meaningfully greater than A.
4. `touch` the source file.
5. Run again, record time C. Assert C is within noise of B.

If C exceeds B, the run step is recompiling and the recipe is wrong. This catches the
Racket and Chez failure modes directly.

## Step 7: perf counters

```
perf stat -e cycles,instructions /bin/true
```

Expected: either it works, or hardware events report as not supported while software
events still function. A `cpu` PMU node exists at
`/sys/bus/event_source/devices/cpu` with type 4, and `perf_event_paranoid` is 2, so
lowering that to 1 may be required.

Do not block on this. If hardware counters fail, the fallback is reading emitted code,
which is the ground truth for this investigation regardless.

## Step 8: extract the nbody sources

```
python3 -c "
import zipfile
z = zipfile.ZipFile('<corpus>/public/download/benchmarksgame-sourcecode.zip')
for n in z.namelist():
    if n.startswith('nbody/'):
        print(n)
"
```

Extract the SBCL, Racket, gcc and Rust nbody entries plus the output fixture into
`vendor/bgame/nbody/`, preserving the per-program `LICENSE` and the attribution
headers. Per-entry compiler flags are not in the zip; they live in
`public/program/nbody-<lang>-<n>.html` and need a small extraction step.

## Artifacts produced

```
harness/compile.sh                  per-implementation AOT recipes
harness/probe/                       the Tangerine and assume probes
vendor/bgame/nbody/                  upstream sources, licenses preserved
docs/phases/01-toolchain-gate/RESULTS.md   support matrix and verdicts
```

## Support matrix schema

One row per implementation, recorded in `RESULTS.md`:

```
implementation | version | (scheme flonum) | (scheme fixnum) | (scheme vector f64) |
native flonum ops | native unboxed vector | assume verdict | AOT recipe | trap test
```

## Exit gates

- Every toolchain reports a version.
- The support matrix is complete, with no cell left unknown.
- Every configuration passes the step 6 trap test.
- A written go or no-go on configurations 2 and 3, with the fallback recorded if taken.
- A yes or no on perf hardware counters.

## Task decomposition notes

Steps 1, 7 and 8 are independent and can run in any order or in parallel. Step 2 gates
the go or no-go decision and is the critical path. Step 3 depends on step 2 only for
the import mechanics. Steps 5 and 6 are one unit: a recipe without its trap test is
not done.
