# Phase 1 CUJ: Toolchain and the Tangerine Gate

Technical implementation document. Companion to `PLAN.md` in this directory, which
covers why. This covers how.

**The gate question is already answered.** `RESULTS.md` in this directory records the
verdict, determined by reading the Chez and Racket source rather than by probing. Nobody
implements R7RS-large Tangerine. Chez has no R7RS support at all and ships full R6RS
instead. Racket's SRFI package stops at SRFI 98.

## Journey summary

The operator installs toolchains, spends five minutes confirming the packaged builds
match what upstream source says, then determines whether `assume` is honored as an
optimization license by reading emitted code. Then the ahead-of-time compilation recipes
get written and verified against a deliberate trap: touch the source mtime and confirm
the reported time does not move. The phase ends with working recipes and a runtime
answer on `sb-simd` and `perf`.

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

## Step 2: confirm the Tangerine verdict at runtime

**Already answered by reading source. See `RESULTS.md` in this directory.** Neither Chez
nor Racket ships the Tangerine numeric libraries. Chez has no R7RS support at all and
ships full R6RS instead, including `(rnrs arithmetic fixnums)` and
`(rnrs arithmetic flonums)`. Racket's SRFI package stops at SRFI 98.

Both are open source. Designing a runtime probe to discover this was the wrong move and
the probe design that used to live here has been deleted.

What remains is a five-minute confirmation that the installed packages match what the
upstream source says, since a distribution can patch or backport:

```
echo '(import (rnrs arithmetic flonums)) (display (fl+ 1.0 2.0))' \
  | chezscheme -q --program /dev/stdin
racket -e '(require racket/flonum) (displayln (fl+ 1.0 2.0))'
racket -e '(require srfi/144)'          # expect: collection not found
```

If any of these disagree with `RESULTS.md`, the distribution patched something and
`RESULTS.md` needs correcting.

### What configuration 2 becomes

Since portable Tangerine is not writeable, configuration 2 splits in two. Both get
measured; see `../../PLAN.md` section 2.

- **2a, R6RS portable.** `(rnrs arithmetic flonums)` and `(rnrs arithmetic fixnums)`,
  which Chez actually ships. This is the real standardized instruction-level hatch and
  it has existed since 2007.
- **2b, Tangerine over a shim.** Ship SRFI 144 and SRFI 160 reference implementations
  ourselves and import them as `(scheme flonum)` and `(scheme vector f64)`. Measures
  what Tangerine would give you if anyone implemented it. The shim is a cost that gets
  reported alongside the number.

## Step 3: does anything honor an assumption as an optimization license?

Neither implementation ships SRFI 145, so `assume` has to be defined locally before it
can be tested at all. That reframes the question usefully: the interesting thing is not
whether `assume` works, it is whether either compiler will delete a check when told the
type another way.

Two experiments, both read from emitted code rather than from timing, because timing
cannot distinguish "treated as a no-op" from "treated as a cheap check" at this scale.

**Experiment one, Chez.** Chez's source optimizer (`cp0.ss`) and its type recovery pass
(`cptypes.ss`, `cptypes-lattice.ss`) already know about `flvector`, which the source read
confirmed. So Chez has an internal type lattice. The question is whether a user-visible
form can feed it.

```scheme
;; does a predicate test upstream let cptypes drop the check downstream?
(define (ref-guarded v i)
  (if (and (flvector? v) (fixnum? i))
      (flvector-ref v i)
      (error 'ref "bad")))
(define (ref-bare v i) (flvector-ref v i))
```

Inspect with `(expand/optimize ...)` for source-level output, and the assembly-output
parameter for machine code. Compare against the same procedure at `optimize-level 3`,
which is known to remove checks. If the guarded version at level 2 matches the level 3
output, then Chez's existing type recovery is already doing what a declaration would ask
for, and the gap is smaller than the standards analysis implies. That would be a
significant finding and it would change `../../PROPOSAL.md`.

**Experiment two, Racket.** `raco decompile` on the compiled zo. Compare
`flvector-ref` against `unsafe-flvector-ref` to establish what check removal looks like
in that output, then check whether any safe form reaches it.

**Baseline, SBCL.** `(disassemble #'f)` with and without `(declare (type fixnum i))` at
`(safety 0)`. This is the reference for what a declaration-driven compiler emits, and it
is what configurations 2a and 2b are ultimately being measured against.

Record per implementation: does a user-writable form cause a check to disappear, yes or
no, with the emitted code as evidence.

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
