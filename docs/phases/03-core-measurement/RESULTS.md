# Phase 3 Results: Core Measurement

Preliminary, 2026-08-06. Ten configurations built and measured; 1, 2b, 2c, 7 and 8 outstanding.
Instrument is retired instructions, per `LEDGER.md` D17. Wall-clock timing and its
bootstrap intervals are still owed; see "What is not here" at the bottom.

## The table

Retired user-space instructions per step, from the N=1,000,000 and N=2,000,000 pair so
process startup cancels exactly. Measured with `harness/measure.sh`.

| # | configuration | instr/step | vs scalar C |
|---|---|---|---|
| 6 | `c-native` — gcc -O3 -march=native | 333.00 | 0.51x |
| 6 | `c-scalar` — gcc -O2 -fno-tree-vectorize | 654.00 | 1.00x |
| 4 | **`racket-4`** — flvector + `racket/unsafe/ops` | **1494.37** | **2.28x** |
| 4 | **`chez-4`** — flvector + `optimize-level 3` | **1788.41** | **2.73x** |
| 5 | **`sbcl-5`** — tuned ANSI CL, `(safety 0)`, scalar | **2015.00** | **3.08x** |
| — | `chez-4-safe` — as `chez-4` but `optimize-level 2` | 8521.41 | 13.03x |
| 2c | `chez-2c` — predicate-guarded, `optimize-level 2` | 8533.41 | 13.05x |
| 2a | `racket-2a` — portable R6RS | 9367.26 | 14.32x |
| 2a | `chez-2a` — portable R6RS | 9546.76 | 14.60x |
| 9 | `ecl-9` — same CL source, ECL | 159625.85 | 244.08x |
| 9 | `clisp-9` — same CL source, CLISP | 421988.68 | 645.24x |

All ten produce bit-identical output. C and SBCL print `%.9f` / `~,9f`; the Schemes
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

## Finding 2b: checks are the whole story, and storage is 12%

`chez-4-safe` is `config4-chez.ss` compiled at `optimize-level 2` instead of 3. Same
source, same `flvector` storage, same operators. The only difference is whether Chez emits
checks, which makes it the control that separates the two components bundled in finding 2.

| configuration | storage | checks | instr/step |
|---|---|---|---|
| `chez-2a` | boxed `vector` | on | 9546.77 |
| `chez-4-safe` | unboxed `flvector` | on | 8521.42 |
| `chez-4` | unboxed `flvector` | **off** | 1788.41 |

Read down the column:

- **Unboxing, with checks held on: 9546.77 to 8521.42, a 1.12x win.**
- **Removing checks, with storage held unboxed: 8521.42 to 1788.41, a 4.77x win.**

**This inverts the prediction in `RESEARCH.md` section 1**, which said portable Tangerine
Scheme "should close most of the boxing and storage gap and none of the check-elision
gap", on the assumption that boxing and storage were the large term. They are not. On this
program they are worth 12%, and check elision is worth 4.77x.

The consequence for the standards argument is sharp, and it is the strongest result the
project has produced. **R7RS-large Tangerine, even if every implementation shipped it
tomorrow, would buy roughly 12%.** Tangerine standardizes `(scheme flonum)` operators and
`(scheme vector f64)` unboxed storage, and no policy switch. It is the 1.12x. The 4.77x is
the thing no Scheme standard has ever contained.

So the finding is not merely that Scheme never standardized a policy switch. It is that the
policy switch is *the part that mattered*, and the parts Scheme did standardize, twice, in
2007 and again in 2019, are the small term.

One caveat to carry into the wall-clock phase: instruction count charges boxing only for
the instructions retired, including in the collector. If unboxing's real cost is
concentrated in GC pauses or cache pressure rather than retired instructions, wall time
will show a larger storage term than 1.12x. That is a reason to measure it, not a reason to
discount this.

## Finding 2c: predicate guards buy nothing, and the residual is pure bounds checking

`PLAN.md` section 5 asked whether Chez's `cptypes` already does our job at
`optimize-level 2` when fed a predicate guard. `fold-primref/try-unsafe`
(`cptypes.ss:1963`) promotes safe primitives to unsafe twins for 270 primitives once
argument types check out, and predicate tests are the one user-visible way to feed that
lattice. `config2c-chez.ss` is byte-identical to `config4-chez.ss` apart from
`flvector?` and `fixnum?` guards on every hot entry.

| configuration | instr/step |
|---|---|
| `chez-2c` — guarded, `optimize-level 2` | 8533.41 |
| `chez-4-safe` — unguarded, `optimize-level 2` | 8521.42 |
| `chez-4` — unguarded, `optimize-level 3` | 1788.41 |

**The guards buy nothing. They cost 12 instructions per step**, which is the guard tests
themselves. A 0.14% regression, and the answer to the open question is a flat no.

`CHEZ-ANALYSIS.md` predicted this would go *half* way: guards would drop the type check
and leave the bounds check. The real result is cleaner than that prediction and better for
the argument. `cptypes` had **already** narrowed `b` to `flvector` on its own, from its
`(make-flvector ...)` definition, so the guard supplied no information the pass did not
have. Nothing was left for it to recover.

Which means the entire 4.77x residual between level 2 and level 3 is **bounds checking**,
not type dispatch. And bounds-check elision is precisely the capability
`cptypes-lattice.ss` architecturally cannot express: it is a level-1 lattice of categories
in which `index`, `length` and `sub-index` all collapse to `fixnum-pred`, so `i in [0,35)`
is not a representable fact.

This is the closest thing the project has to a direct experimental validation of
`PROPOSAL.md`. The missing capability is not notation and not type inference. It is an
interval or relational abstract domain, which is what SonicScheme's stage 06 exists to
build, and no amount of predicate guarding reaches it from outside.

## Finding 3: the implementations agree closely, in both regimes

`RESEARCH.md` section 4 predicted Chez and Racket within 15% on numeric code, from the
`r7rs-benchmarks` corpus, and `PLAN.md` flagged any large divergence as itself a finding.
No divergence:

- portable R6RS: 9546.77 vs 9843.97, **3.1% apart**
- implementation max: 1788.41 vs 1494.07, **19.7% apart**

The second gap is wider but still inside the prediction's spirit, and it runs the opposite
way from the folklore that Chez is the fast one.

## Finding 3b: "Common Lisp is fast" is really "SBCL is fast"

Configuration 9 runs `config5.lisp` **unchanged** under three implementations. Byte-identical
source, identical declarations, identical `(declaim (optimize (speed 3) (safety 0)))`:

| implementation | instr/step | vs SBCL |
|---|---|---|
| SBCL 2.6.0 | 2015.00 | 1.0x |
| ECL 24.5.10 | 159625.85 | **79.2x** |
| CLISP 2.49 | 421988.68 | **209.4x** |

A 209-fold spread inside conformant ANSI Common Lisp, on one file.

ECL is the interesting row, because it is not a bytecode excuse. ECL compiles through C and
reports `:NATIVE-C`, so this is native code that is 79x slower than SBCL's native code from
the same declarations.

**This sharpens section 1's thesis rather than undermining it, but it also bounds it.**
Standardizing the notation obliges implementors to *accept* `declare` and `optimize`. It
does not oblige them to *act* on either, and two of the three do not meaningfully act. So
"CL went as fast as C because the standard had the hatches" is more precisely: the standard
made it *possible* to write the tuned program portably, and exactly one implementation
turned that possibility into code generation.

That is a real qualification on the argument this project started from, and it cuts both
ways. It weakens "the standard is what made CL fast" — SBCL is what made CL fast. It
strengthens the practical case for the escape hatches, since without them SBCL could not
have offered the tuned path at all without leaving the standard, which is precisely the
position Chez and Racket are in today.

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

## A caveat on the instrument

D17 claims retired instruction counts are deterministic, and for most configurations they
are: `c-scalar` reproduced 654.00 across four separate sweeps, `sbcl-5` reproduced 2015.00
exactly at two different N pairs, and `chez-4` moved by 0.0002%.

**Racket is the exception.** `racket-2a` measured 9843.97 in one sweep and 9367.26 in
another, about 5% apart, with no change to the source or the build. Racket's startup does
work that Chez's and SBCL's do not, and differencing two N values cancels a *constant*
startup but not a *variable* one.

So the D17 instrument is exact for C, Chez and the Lisps, and carries roughly 5% for
Racket. That is well inside the effects being reported here, but it means Racket deltas
under about 10% are not resolvable by instruction count alone and need the wall-clock
protocol.

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
