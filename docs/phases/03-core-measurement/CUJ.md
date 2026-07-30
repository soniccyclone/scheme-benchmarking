# Phase 3 CUJ: Core Measurement

Technical implementation document. The journey is an operator writing ten variants of
one program, each expressing exactly one constraint, and coming out with the number the
project exists for.

Companion to `PLAN.md` in this directory.

## Journey summary

The operator writes nbody ten times, one per configuration variant. Each variant differs from its neighbor by one
standards-level feature, so the timing difference between adjacent variants isolates
that feature. Every variant is verified against the upstream output fixture before any
timing is trusted. The phase ends with five deltas, of which one, configuration 2a to
configuration 4, is the answer.

## Preconditions

Phase 1 complete. Its Tangerine verdict was no, which is why configuration 2 split into
2a and 2b. Phase 2 complete, so N values, the noise
floor, and the reporting convention are fixed.

## The program

nbody, from the Benchmarks Game. Five bodies, symplectic integrator, fixed step.

Structure, identical across all variants so the only difference is how values are
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

Hold constant across every variant: loop order, pair iteration order, the arithmetic
expression tree, and the number of temporaries. Vary only representation and operator
selection.

## The variants

Directory layout, one file per variant:

```
bench/programs/nbody/
  01-r7rs-generic.scm        config 1
  02a-r6rs.sls               config 2a, R6RS operators
  02b-tangerine-shim.scm     config 2b, over our vendored SRFI shim
  03-assumed.scm             config 3, if phase 1 found any workable form
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

### Configuration 2a: R6RS, the path that actually exists

Chez ships `(rnrs arithmetic flonums)` and `(rnrs arithmetic fixnums)`, standardized in
2007. This is the only standardized instruction-level hatch with a real implementation
behind it. Chez's native `flvector` supplies unboxed storage, though note that `flvector`
is a Chez extension rather than an R6RS library, so this configuration is R6RS operators
plus one implementation-specific storage type. Record that caveat with the number.

```scheme
#!r6rs
(import (rnrs base) (rnrs arithmetic flonums) (rnrs arithmetic fixnums)
        (only (chezscheme) flvector flvector-ref flvector-set! make-flvector))

(define (advance xs ys zs vxs vys vzs ms dt)
  ;; every arithmetic site written explicitly as fl*
  (let ((dx (fl- (flvector-ref xs i) (flvector-ref xs j))))
    ...))
```

### Configuration 2b: Tangerine over a shim we ship

Nobody implements `(scheme flonum)` or `(scheme vector f64)`, so to measure what
Tangerine would give you we have to supply it. Vendor the SRFI 144 and SRFI 160 reference
implementations and import them under their Tangerine names.

```scheme
(import (scheme base) (scheme write)
        (scheme flonum)        ; SRFI 144, from our vendored shim
        (scheme vector f64)    ; SRFI 160, from our vendored shim
        (scheme fixnum))       ; SRFI 143, from our vendored shim
```

The shim's own overhead is part of what gets measured and must be reported, because a
portable reference implementation of `f64vector` is not necessarily unboxed. Check what
the SRFI 160 reference implementation actually does for storage before trusting this
configuration: if it lowers to a plain vector of boxed flonums, then 2b measures the shim
rather than the standard, and that fact belongs in the results.

Both 2a and 2b share the property that makes them tedious: every arithmetic site needs
its operator chosen by hand, and one missed `fl*` reboxes the value and undoes the work
downstream. That tedium is the argument for declarations and it should be visible in the
diff against configuration 5.

### Configuration 3: an assumption as an optimization license

Neither implementation ships SRFI 145, so `assume` must be defined locally, which makes
the original framing of this configuration moot. Phase 1's step 3 reframed it: the
question is whether either compiler will delete a check when told the type by any
user-writable means.

Build this configuration from whatever phase 1 found worked. If nothing did, record that
and report configuration 3 as unmeasurable rather than inventing a number for it.

### Configuration 4: implementation-specific maximum

Two files. This is the folklore ceiling and the target configurations 2a and 2b are
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

The contrast with configurations 2a and 2b is the whole point: `+` and `*` stay generic in the
source, and SBCL's type inference derives that they are double-float operations from the
declarations. Those had to say `fl*` at every site.

### Configuration 6: C reference, two builds

```
gcc -O2 -fno-tree-vectorize -o nbody-scalar nbody.c -lm
gcc -O3 -march=native        -o nbody-vector nbody.c -lm
```

Both, because the pair separates "no vectorizer" from "worse scalar code generation."
The published ratios collapse those two effects and that is misleading on a part with
AVX-512.

## Verification before timing

No timing is trusted until output matches. Run this for every variant before measuring
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
| 1 to 2a | what R6RS bought Scheme in 2007 |
| 2a to 2b | whether Tangerine over a shim beats the R6RS path, or just adds shim cost |
| 2b to 3 | what a premise buys, where one can be expressed at all |
| **2a to 4** | **the cost of the missing policy switch. The project's answer.** |
| 4 to 5 | does CL's inference beat hand-written Scheme instructions, both fully tuned |
| 5 to 6 | Verna's claim, re-run on 2026 hardware |

Report each as a ratio with its spread. Any delta smaller than the noise floor is
reported as "inside the noise floor" rather than as a number, because quoting a 4%
difference against 8% noise would be dishonest.

## The decision this phase forces

If the 2a-to-4 delta is inside the noise floor, or small enough not to matter, then the
missing policy switch costs little on this workload. The honest conclusion is that the
Tangerine operators were the load-bearing part, no further standardization is needed,
and `../../PROPOSAL.md` should be abandoned. Record that outcome as clearly as a
positive one and skip to phase 6.

Phase 5 depends entirely on this going the other way.

## Artifacts produced

```
bench/programs/nbody/*                   the variants
results/<config>-<N>.json                per-run data
docs/phases/03-core-measurement/RESULTS.md   deltas, verdict, go or no-go
```

## Exit gates

- All variants produce output identical to the fixture.
- All nine pass phase 1's recompilation trap test.
- Five deltas reported with spread, each either above the noise floor or explicitly
  declared unmeasurable.
- A written go or no-go on `../../PROPOSAL.md`.

## Task decomposition notes

The variants are independent and parallelizable. Configuration 6 is the smallest
piece of work and makes a good first task, since it establishes the reference the others
are read against. Configurations 1, 2a and 2b are the largest, because each needs an
operator chosen at every arithmetic site, and 2b also needs the SRFI shim vendored. Configuration 3 is a small diff on top of
configuration 2b. Configuration 4 is two files and depends on nothing else. Verification
is one unit of work covering all of them and must complete before any timing task starts.
