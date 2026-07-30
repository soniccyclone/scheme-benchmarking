# Phase 3 CUJ: Core Measurement

Technical implementation document. The journey is an operator writing nine variants of
one program, each expressing exactly one constraint, and coming out with the number the
project exists for.

Companion to `PLAN.md` in this directory.

## Journey summary

The operator writes nbody nine times. Each variant differs from its neighbor by one
standards-level feature, so the timing difference between adjacent variants isolates
that feature. Every variant is verified against the upstream output fixture before any
timing is trusted. The phase ends with five deltas, of which one, configuration 2 to
configuration 4, is the answer.

## Preconditions

Phase 1 complete, with a resolved Tangerine verdict, because it determines whether
configuration 2 is writeable as specified. Phase 2 complete, so N values, the noise
floor, and the reporting convention are fixed.

## The program

nbody, from the Benchmarks Game. Five bodies, symplectic integrator, fixed step.

Structure, identical across all nine variants so the only difference is how values are
represented and which operations are used:

```
setup:    five bodies with position, velocity, mass. Offset momentum so the
          system's total momentum is zero.
advance:  for each pair of bodies, compute separation, distance, magnitude,
          update both velocities. Then update all positions.
energy:   kinetic plus potential over all pairs.
main:     print energy, run advance N times, print energy.
```

Output is two lines of energy to nine decimal places. That is what gets checked against
the fixture, and it is the reason floating point evaluation order must stay identical
across variants: reordering the pair loop changes the last digits.

Hold constant across all nine: loop order, pair iteration order, the arithmetic
expression tree, and the number of temporaries. Vary only representation and operator
selection.

## The nine variants

Directory layout, one file per variant:

```
bench/programs/nbody/
  01-r7rs-generic.scm        config 1
  02-tangerine.scm           config 2
  03-tangerine-assume.scm    config 3
  04-chez-native.ss          config 4, Chez
  04-racket-native.rkt       config 4, Racket
  05-sbcl-declared.lisp      config 5
  06-c-scalar.c              config 6, built two ways
  expected.txt               fixture from upstream
```

### Configuration 1: portable R7RS-small, the floor

Generic arithmetic, plain `vector` for storage. No hatches, because none exist in
R7RS-small.

```scheme
(import (scheme base) (scheme write) (scheme inexact))

;; positions in a plain vector of flonums: every element is a heap object
(define (advance bodies dt)
  (let loop ((i 0))
    (when (< i (vector-length bodies))
      ;; generic + - * / throughout, full numeric tower live
      ...)))
```

The point of this variant is to be honestly naive. Do not sneak in a manual unboxing
trick. It represents what a programmer gets from the standard alone.

### Configuration 2: Tangerine

Type-specific operators plus unboxed storage, both standard as of the Tangerine
edition.

```scheme
(import (scheme base) (scheme write)
        (scheme flonum)        ; SRFI 144: fl+ fl* fl- fl/ flsqrt
        (scheme vector f64)    ; SRFI 160: f64vector, unboxed
        (scheme fixnum))       ; SRFI 143: fx+ fx<? for loop indices

(define (advance xs ys zs vxs vys vzs ms dt)
  ;; every arithmetic site written explicitly as fl*
  (let ((dx (fl- (f64vector-ref xs i) (f64vector-ref xs j))))
    ...))
```

Note what this variant demonstrates by being tedious to write: every single arithmetic
site needs its operator chosen by hand, and one missed `fl*` reboxes the value and
undoes the work downstream. That tedium is the argument for declarations, and it should
be visible in the diff against configuration 4.

If phase 1 found Tangerine unimplemented, substitute the fallback it recorded and note
it in the results.

### Configuration 3: Tangerine plus `assume`

Configuration 2 with SRFI 145 assumptions at procedure boundaries.

```scheme
(import (scheme base) (srfi 145))

(define (advance xs ys zs vxs vys vzs ms dt)
  (assume (f64vector? xs))
  (assume (flonum? dt))
  ...)
```

Expected to change nothing, per phase 1's probe. Measure it anyway: it is the only
available data point on what ratifying `assume` would buy.

### Configuration 4: implementation-specific maximum

Two files. This is the folklore ceiling and the target configuration 2 is being
measured against.

Chez: `optimize-level 3`, which eliminates checks, plus native `fl` operators and
`flvector`.

```scheme
;; compiled with (optimize-level 3)
(let ([dx (fl- (flvector-ref xs i) (flvector-ref xs j))]) ...)
```

Racket: `racket/flonum` for `flvector`, `racket/unsafe/ops` for the unchecked
accessors.

```racket
#lang racket/base
(require racket/flonum racket/unsafe/ops)
(define dx (fl- (unsafe-flvector-ref xs i) (unsafe-flvector-ref xs j)))
```

### Configuration 5: SBCL, tuned conformant Common Lisp

Declarations plus `(safety 0)`, scalar only. No `sb-simd`, deliberately, because the
question is what the compiler does with declared types rather than what intrinsics do.

```lisp
(declaim (optimize (speed 3) (safety 0) (debug 0)))

(deftype d64v () '(simple-array double-float (*)))

(defun advance (xs ys zs vxs vys vzs ms dt)
  (declare (type d64v xs ys zs vxs vys vzs ms)
           (type double-float dt))
  ...)
```

The contrast with configuration 2 is the whole point: `+` and `*` stay generic in the
source, and SBCL's type inference derives that they are double-float operations from the
declarations. Configuration 2 had to say `fl*` at every site.

### Configuration 6: C reference, two builds

```
gcc -O2 -fno-tree-vectorize -o nbody-scalar nbody.c -lm
gcc -O3 -march=native        -o nbody-vector nbody.c -lm
```

Both, because the pair separates "no vectorizer" from "worse scalar code generation."
The published ratios collapse those two effects and that is misleading on a part with
AVX-512.

## Verification before timing

No timing is trusted until output matches. Run this for all nine before measuring
anything:

```
for v in bench/programs/nbody/*; do
  out=$(run "$v" 1000)
  diff <(echo "$out") <(head -2 bench/programs/nbody/expected.txt) \
    || echo "FAIL: $v"
done
```

Use a small N for correctness, the calibrated N for timing. If a variant's last digits
differ, the arithmetic order drifted and the variant is not comparable. Fix the order
rather than loosening the comparison.

## Running the sweep

Interleave configurations, per phase 2's convention, so thermal drift is spread evenly:

```
for rep in $(seq 5); do
  for cfg in 01 02 03 04-chez 04-racket 05 06-scalar 06-vector; do
    for N in $N1 $N2; do
      harness/run.sh "$cfg" "$N"
    done
  done
done
```

Run configurations 1 through 4 under both Chez and Racket. `RESEARCH.md` section 4 says
they sit within 15% on numeric code, so a large divergence here contradicts the corpus
the plan was built on and is a stop-and-investigate event rather than a curiosity.

## The deltas

Computed by `harness/report.py`, each with spread, each compared against phase 2's
noise floor:

| delta | question answered |
|---|---|
| 1 to 2 | what the Tangerine edition bought Scheme |
| 2 to 3 | what ratifying SRFI 145 `assume` would buy |
| **2 to 4** | **the cost of the missing policy switch. The project's answer.** |
| 4 to 5 | does CL's inference beat hand-written Scheme instructions, both fully tuned |
| 5 to 6 | Verna's claim, re-run on 2026 hardware |

Report each as a ratio with its spread. Any delta smaller than the noise floor is
reported as "inside the noise floor" rather than as a number, because quoting a 4%
difference against 8% noise would be dishonest.

## The decision this phase forces

If the 2-to-4 delta is inside the noise floor, or small enough not to matter, then the
missing policy switch costs little on this workload. The honest conclusion is that the
Tangerine operators were the load-bearing part, no further standardization is needed,
and `../../PROPOSAL.md` should be abandoned. Record that outcome as clearly as a
positive one and skip to phase 6.

Phase 5 depends entirely on this going the other way.

## Artifacts produced

```
bench/programs/nbody/*                   the nine variants
results/<config>-<N>.json                per-run data
docs/phases/03-core-measurement/RESULTS.md   deltas, verdict, go or no-go
```

## Exit gates

- All nine variants produce output identical to the fixture.
- All nine pass phase 1's recompilation trap test.
- Five deltas reported with spread, each either above the noise floor or explicitly
  declared unmeasurable.
- A written go or no-go on `../../PROPOSAL.md`.

## Task decomposition notes

The nine variants are independent and parallelizable. Configuration 6 is the smallest
piece of work and makes a good first task, since it establishes the reference the others
are read against. Configurations 1 and 2 are the largest, because configuration 2 needs
an operator chosen at every arithmetic site. Configuration 3 is a small diff on top of
configuration 2. Configuration 4 is two files and depends on nothing else. Verification
is one unit of work covering all nine and must complete before any timing task starts.
