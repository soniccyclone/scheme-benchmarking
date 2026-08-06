# Phase 3: Core Measurement

## Goal

Run configurations 1 through 6 on nbody and produce the number the whole project
exists for: what the missing policy switch costs portable Scheme.

## The number that matters

The delta from configuration 2 to configuration 4. Configuration 2 is the best a
portable R7RS-large Tangerine program can do. Configuration 4 is the best an
implementation-specific tuned program can do. The gap between them is precisely the
cost of what the Scheme standards never standardized: a premise that propagates, and
a policy switch that turns checks off.

Everything in `../../PROPOSAL.md` is downstream of that one figure. If it is small,
the proposal should be abandoned and the project ends here with a useful negative
result.

## Inputs

Phase 1 complete, including a resolved answer to the Tangerine question. Phase 2
complete, so N values and the noise floor are known.

## Work items

1. Write nbody configuration 1: portable R7RS-small, generic arithmetic, plain
   `vector`. The floor.
2. Write configuration 2: `(scheme flonum)` operators plus `(scheme vector f64)`
   storage, or whichever fallback phase 1 determined is available.
3. Write configuration 3: configuration 2 plus SRFI 145 `assume` at procedure
   boundaries.
4. Write configuration 4 twice, once per implementation. Chez with `optimize-level 3`
   and its native flonum operations, Racket with `racket/flonum` and
   `racket/unsafe/ops`.
5. Write configuration 5: SBCL with `declare` and `(safety 0)`, scalar only, no
   `sb-simd`. Tuned conformant Common Lisp.
6. Build configuration 6: `gcc -O2 -fno-tree-vectorize` and `gcc -O3 -march=native`.
   Both, because the pair separates "no vectorizer" from "worse scalar code
   generation," and the published ratios hide that distinction.
7. Run configurations 1 through 4 on both Chez and Racket. `RESEARCH.md` section 4 says
   they are within 15% on numeric code, so any large divergence here is a finding.
8. Verify every configuration produces identical output against the Benchmarks Game
   fixture before trusting any timing from it.

## Acceptance criteria

- All nine program variants produce byte-identical correct output.
- Every configuration passes phase 1's no-recompilation check.
- Every pre-registered delta carries a **bootstrap 95% confidence interval on the ratio**,
  per `../../METHOD.md`'s statistical protocol. An interval spanning 1.0 is reported as no
  detected difference, never as a small one. Parametric tests are not licensed here: without
  layout re-randomization the samples are not normally distributed, and we cannot run
  Stabilizer because it is an LLVM pass and we emit x86-64 directly.
- Only the seven pre-registered deltas get an interval. No fishing across the other
  comparisons, or the multiple-comparisons problem eats the result.
- Each delta named above has a number attached: 1 to 2, 2 to 3, 2 to 4, 4 to 5, 5 to 6.

## Risks

**The 2-to-4 delta is inside the noise floor.** Then the honest conclusion is that the
missing policy switch costs little on this workload, and the proposal is not worth
pursuing. This is a real possible outcome and the phase is designed to surface it
rather than argue around it.

**Configuration 2 is not writeable as specified.** Depends on phase 1's Tangerine
answer. Fallback is native unboxed vectors with a portability caveat attached to every
resulting number.

**Entry-quality contamination.** We are writing all nine variants ourselves, which is
the whole reason for not reusing the frozen Benchmarks Game entries. Guard against
accidentally tuning one configuration harder than another: each should be the best
honest expression of its own constraint, not a demonstration of a preferred
conclusion.

**Chez and Racket diverge sharply.** Would contradict `RESEARCH.md` section 4. If it
happens, stop and find out why before proceeding, because it would mean the corpus we
built the plan on does not describe tuned code.

## Outputs

- Nine nbody variants, checked in.
- A results table with all five deltas.
- A go or no-go decision on `../../PROPOSAL.md`.
