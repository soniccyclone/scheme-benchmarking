# Phase 3 Results: Core Measurement

Preliminary, 2026-08-06. Seven of the ten configurations built and measured.
Instrument is retired instructions, per `LEDGER.md` D17. Wall-clock timing and its
bootstrap intervals are still owed; see "What is not here" at the bottom.

## The table

Retired user-space instructions per step, from the N=1,000,000 and N=2,000,000 pair so
process startup cancels exactly. Measured with `harness/measure.sh`.

| # | configuration | instr/step | vs scalar C |
|---|---|---|---|
| 6 | `c-native` — gcc -O3 -march=native | 333.00 | 0.51x |
| 6 | `c-scalar` — gcc -O2 -fno-tree-vectorize | 654.00 | 1.00x |
| 4 | **`racket-4`** — flvector + `racket/unsafe/ops` | **1494.07** | **2.28x** |
| 4 | **`chez-4`** — flvector + `optimize-level 3` | **1788.41** | **2.73x** |
| 5 | **`sbcl-5`** — tuned ANSI CL, `(safety 0)`, scalar | **2015.00** | **3.08x** |
| 2a | `chez-2a` — portable R6RS | 9546.77 | 14.60x |
| 2a | `racket-2a` — portable R6RS | 9843.97 | 15.05x |

All seven produce bit-identical output. C and SBCL print `%.9f` / `~,9f`; the Schemes
print full precision and round to the same nine decimals.

## Finding 1: both Scheme ceilings beat tuned Common Lisp

`racket-4` at 2.28x and `chez-4` at 2.73x are **both faster than `sbcl-5` at 3.08x**, on
declared, `(safety 0)`, scalar-tuned ANSI Common Lisp.

This is the answer to the question the project opened with, and it is not the answer the
framing anticipated. Scheme is not slower than Common Lisp. Tuned Scheme is *faster* than
tuned Common Lisp on this program, on both leading implementations.

What Scheme lacks is not speed. It is the ability to **say so portably**. `racket-4`
reaches 2.28x by calling `unsafe-flvector-ref`, and `chez-4` reaches 2.73x by being
compiled at `optimize-level 3`. Neither spelling exists in any Scheme standard, and the two
are not even the same *kind* of mechanism: Racket's is a per-call-site instruction, Chez's
is a global compile-time policy. A program tuned for one does not run tuned on the other.

Common Lisp's advantage was never the code its compilers emit. It is that `(declaim
(optimize (speed 3) (safety 0)))` and `(declare (type double-float x))` are in the
standard, so the tuned program stays conformant.

## Finding 2: the 2a-to-4 delta is the cost of the missing hatches

This is the number `PLAN.md` said the project exists for.

| implementation | portable R6RS | implementation max | delta |
|---|---|---|---|
| Chez | 9546.77 | 1788.41 | **5.34x** |
| Racket | 9843.97 | 1494.07 | **6.59x** |

Better than five-fold, on both. The best a portable standardized Scheme program can do is
between five and seven times more work than the same algorithm expressed in the
implementation's own dialect.

Two components are bundled in that delta and phase 3 is not yet able to separate them:
R6RS standardized flonum **operators** and no unboxed flonum **storage**, so configuration
2a pays for boxing *and* for checks at once. Configurations 2b and 2c exist to split it and
are not yet written.

## Finding 3: the implementations agree closely, in both regimes

`RESEARCH.md` section 4 predicted Chez and Racket within 15% on numeric code, from the
`r7rs-benchmarks` corpus, and `PLAN.md` flagged any large divergence as itself a finding.
No divergence:

- portable R6RS: 9546.77 vs 9843.97, **3.1% apart**
- implementation max: 1788.41 vs 1494.07, **19.7% apart**

The second gap is wider but still inside the prediction's spirit, and it runs the opposite
way from the folklore that Chez is the fast one.

## Finding 4: vectorization is worth 2x, and nothing in the Lisp family has it

`c-native` retires 333.00 instructions per step against `c-scalar`'s 654.00, so
`-O3 -march=native` on this Zen 5 part halves the instruction count.

Nothing else in the matrix can do that. `docs/phases/07-compiler/PLAN.md` established by
reading both back ends that Chez emits only scalar SSE (`addsd`, `mulsd`, no packed
encodings at all) and that SBCL can *encode* AVX-512 but has no auto-vectorization pass, so
vector code appears only where a human wrote an intrinsic. `sb-simd` moreover stops at AVX2
(`LEDGER.md` D15).

So the 0.51x row is the open field, and it is what SonicScheme's stage 10 aims at.

## The correction that produced these numbers

The first run of this table reported `chez-4` at 5703.42 instr/step, 8.72x, making Chez
look 3.8x worse than Racket. **That was a defect in our Chez source, not in Chez.**

`config4-chez.ss` computed its array offsets with generic `+` and `*` while
`config4-racket.rkt` used `unsafe-fx+` and `unsafe-fx*`, and `slots` was a global variable
rather than a syntactic constant, so Chez had to reload and re-dispatch on it at every
reference. Rewriting the index arithmetic with `fx` operators and folding the constant took
`chez-4` from 5703.42 to 1788.41, a 3.2x improvement with no change to the algorithm.

This is exactly the "entry-quality contamination" risk `PLAN.md` names: accidentally tuning
one configuration harder than another. It survived a bit-exactness check, because output
correctness says nothing about whether two variants were written with equal care. Guard
against it by diffing configurations against each other for *operator class*, not only for
expression order.

A hypothesis was killed on the way: Chez was suspected of boxing flonum intermediates.
Measured with `bytes-allocated` around a tight `fl+`/`fl*` loop, Chez allocates **0.18
bytes per iteration** at `optimize-level 3` and 0.22 at level 2, which is GC bookkeeping
and not boxing. The suspicion was wrong.

`optimize-level` was separately confirmed to be doing real work, since the same source
compiled at levels 0, 2 and 3 retires 10841.41, 10841.42 and 5703.41 instructions per step.
Levels 0 and 2 are indistinguishable; level 3 halves it.

## What is not here

- **Wall-clock time and bootstrap confidence intervals.** Instruction count is
  deterministic and needs no interval, but it is not the whole story: it says nothing about
  IPC, cache behaviour or branch misprediction, and a configuration can retire fewer
  instructions while running slower. Every time-based delta still owes the D13 protocol.
- **Configurations 1, 2b, 2c, 7, 8, 9.** Config 1's floor must be written in R5RS rather
  than R7RS-small, per phase 1. 2b needs the SRFI 144/160 shim. 2c is the experiment that
  splits boxing from checks and is the most valuable of the three.
- **ECL and CLISP** running `config5.lisp` unchanged, which is configuration 9 and tests
  whether the result is about Common Lisp or about SBCL.
