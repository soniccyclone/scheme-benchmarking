# What Scheme's standards left out, and what it cost

Measured on one program, nbody, on one machine, in August 2026. Every number here comes
from `harness/` and is reproducible with `make`-scale effort. The full tables are in
`../03-core-measurement/RESULTS.md` and `../04-reference-points/RESULTS.md`; the reasoning
that produced each decision is in `../../LEDGER.md`.

---

## The question, and how it changed

The project began from a claim about Common Lisp: that SBCL can approach C because ANSI CL
put the optimization escape hatches *in the standard*, so a tuned program stays conformant.
The question was whether any Scheme standard ever did the same.

Three things were expected. That Scheme would turn out slower than Common Lisp. That the
gap would be mostly boxing and unboxed storage. That R7RS-large Tangerine, which
standardized flonum operators and `f64vector` storage in 2019, would therefore have been
most of a fix.

All three were wrong, and the third is wrong in a way that matters.

---

## 1. Every hatch standardized after 2007 is unimplemented

Determined by reading the Chez and Racket source, then confirmed at runtime.

| configuration | standard | year | Chez | Racket |
|---|---|---|---|---|
| 1 | R7RS-small | 2013 | no | no (add-on package) |
| 2b | R7RS-large Tangerine | 2019 | no | no |
| 3 | SRFI 145 `assume` | 2016 | no | no |
| **2a** | **R6RS** | **2007** | **yes** | **yes** |
| floor | R5RS | 1998 | yes | yes |

`(import (scheme base))` resolves on neither implementation. Chez contains no R7RS support
at all; the only occurrences of "r7rs" in its source are two incidental comments. Racket's
SRFI package stops at SRFI 98.

So the portable paths that actually execute are R5RS, which has no hatches, and R6RS, which
has instruction-level operators and neither a premise nor a policy switch. **Three of the
ten planned configurations had to be rebuilt because they were specified against standards
nothing implements.**

## 2. Checks are 4.77x. Storage is 1.12x.

The decomposition, holding one variable at a time, on Chez:

| storage | checks | instr/step |
|---|---|---|
| boxed `vector` | on | 9546.77 |
| unboxed `flvector` | on | 8521.41 |
| unboxed `flvector` | **off** | 1788.41 |

Unboxing with checks held on buys **1.12x**. Removing checks with storage held unboxed buys
**4.77x**.

This inverts the expectation the project was built on. The parts Scheme standardized, in
R6RS in 2007 and again in Tangerine in 2019, are the small term. The part no Scheme
standard has ever contained is the large one.

**R7RS-large Tangerine, fully implemented tomorrow, would buy about 12%.**

## 3. The portable spelling of unboxed storage can cost 6.35x

`bytevector-ieee-double-native-ref/set!` is portable R6RS, from `(rnrs bytevectors)`,
standardized in 2007 and shipped by both implementations. It is what SRFI 160's `f64vector`
amounts to. So the half of Tangerine that R6RS supposedly lacks has been expressible in
portable R6RS for nineteen years, under a name nobody associates with numerics.

| configuration | instr/step | vs its boxed twin |
|---|---|---|
| `chez-2b` | 9400.48 | 0.98x |
| `racket-2b` | **59526.49** | **6.35x worse** |

On Chez it buys 1.6%. On Racket it costs 6.35x, because Racket's R6RS bytevector layer does
not lower to its native byte operations on this path.

Both implementations are conformant. **One of them makes the standard's own unboxed
accessor six times slower than not using it.** That is what standardizing notation is worth
when an implementation has not invested in lowering it, and it is the strongest available
argument that Tangerine was never the remedy.

## 4. The residual is pure bounds checking, and no user-level trick reaches it

Chez's `cptypes` has `fold-primref/try-unsafe`, which promotes 270 safe primitives to
unsafe twins once argument types check out. Predicate tests are the one user-visible way to
feed that lattice. So: guard every hot entry with `flvector?` and `fixnum?`, compile at
`optimize-level 2`, and see how far toward level 3 it gets.

| configuration | instr/step |
|---|---|
| guarded, level 2 | 8533.41 |
| unguarded, level 2 | 8521.42 |
| unguarded, level 3 | 1788.41 |

**The guards cost 12 instructions per step and recover nothing.** `cptypes` had already
narrowed `b` to `flvector` unaided from its `make-flvector` definition, so the guard
supplied no information the pass did not have.

Which means the whole 4.77x is bounds checking, not type dispatch. And bounds-check elision
is precisely what `cptypes-lattice.ss` cannot express: it is a level-1 lattice of categories
in which `index`, `length` and `sub-index` all collapse to `fixnum-pred`, so `i is in
[0,35)` is not a representable fact. Not unimplemented. Unrepresentable.

## 5. Tuned Scheme already beats tuned Common Lisp, by 3.2x

Wall clock, 11 reps, bootstrap 95% intervals on the ratio, baseline scalar C:

| configuration | ns/step | ratio (95% CI) |
|---|---|---|
| `c-native` | 33.92 | 0.91 [0.88, 0.94] |
| `c-scalar` | 37.41 | 1.00 |
| `ada-8-all` | 41.51 | 1.11 [1.08, 1.14] |
| `ada-8-named` | 42.33 | 1.13 [1.08, 1.18] |
| **`racket-4`** | **69.80** | **1.87 [1.65, 1.96]** |
| `chez-4` | 82.98 | 2.22 [2.16, 2.29] |
| **`sbcl-5`** | **221.87** | **5.93 [5.86, 6.07]** |
| `racket-2a` | 269.41 | 7.20 [6.30, 8.16] |
| `chez-2a` | 288.82 | 7.72 [7.63, 8.03] |
| `chez-1` (R5RS) | 826.33 | 22.09 [21.61, 22.89] |

Every interval excludes 1.0.

Tuned Racket is **3.2x faster than tuned SBCL** on declared, `(safety 0)`, scalar Common
Lisp. It retires only 35% fewer instructions but takes a third of the time, so the
difference is IPC.

**Scheme's problem was never speed. It is that neither fast spelling is standardized**, and
the two implementations do not even offer the same *kind* of mechanism: Racket has
per-call-site unchecked operators, Chez has a global compile-time policy. A program tuned
for one runs untuned on the other. That is the portability problem stated as concretely as
it can be stated.

## 6. "Common Lisp is fast" is really "SBCL is fast"

The same file, `config5.lisp`, unchanged, under three conforming implementations:

| implementation | instr/step | vs SBCL |
|---|---|---|
| SBCL 2.6.0 | 2015.00 | 1.0x |
| ECL 24.5.10 | 159625.85 | 79.2x |
| CLISP 2.49 | 421988.68 | 209.4x |

A 209-fold spread inside conformant ANSI Common Lisp. ECL is not a bytecode excuse: it
compiles through C and reports `:NATIVE-C`, so that is native code 79x off SBCL's from
identical declarations.

This qualifies the argument the project started from. Standardizing the notation obliges
implementors to *accept* `declare` and `optimize`; it does not oblige them to *act*, and
two of three do not meaningfully act. "The standard is what made CL fast" is too strong.
SBCL is what made CL fast. What the standard did was make the tuned program *expressible
without leaving the language* — which is exactly the thing Chez and Racket users cannot do
today.

## 7. Ada is the design that works, and granularity is free

One source, three builds, differing only in the pragmas:

| policy | instr/step | vs scalar C |
|---|---|---|
| every check on (Ada's default) | 3195.00 | 4.89x |
| `pragma Suppress` per named check | **801.00** | **1.22x** |
| `-gnatp`, i.e. `Suppress (All_Checks)` | **801.00** | **1.22x** |

**Identical to the instruction.** Named per-check suppression costs nothing against the
blunt instrument, which was the open question behind the design decision and is now closed.

Ada with named suppression reaches 1.13x scalar C by wall clock and **beats every Lisp in
the matrix**, while remaining fully standard, fully portable Ada. Note also that Ada's
default is stronger than C's: `Overflow_Check` is on unless suppressed, so the 4.89x
baseline is not a strawman.

Both Scheme ceilings and SBCL's require leaving the standard. Ada's does not. That is the
entire argument in one table.

## 8. Whole-program inference is not the answer either

Stalin was the control: if inference without declarations already beat declaration-plus-
policy by a wide margin, this project would be aimed at the wrong target.

**Stalin computes in IEEE single precision, with no option to change it.** Its generated C
has 335 occurrences of `float` and zero of `double`; `(/ 1.0 3.0)` returns
`0.3333333492279052734375`. It fails the correctness oracle outright and configuration 7 is
not measurable on equal terms.

Measured anyway, for information: **1889.99 instructions per step against `chez-4`'s
1788.41**. Stalin retires 5.7% *more* than Chez's ceiling while doing half-width arithmetic.

This also corrects a claim carried into this project's own research notes. The published
"Stalin is 2-4x faster than Chez on float benchmarks" figure comes from a corpus that was
comparing Stalin's binary32 against Chez's binary64, with Chez additionally held at
`--optimize-level 2` with checks on. It is not a compiler-quality result.

The control passes. Inference does not win.

---

## What follows

The four facts that constrain any fix:

1. The cost is bounds checking, not boxing and not type dispatch.
2. Bounds-check elision needs a domain that can represent `i in [0,n)`. Every Scheme
   implementation examined has a level-1 category lattice that cannot.
3. Standardizing notation without obliging lowering can make the standard path *slower*,
   as Racket's conformant bytevectors demonstrate at 6.35x.
4. Named, scoped suppression costs nothing over a global switch, so there is no efficiency
   argument for CL's blunt dial over Ada's granularity.

Which is why the project's remaining work is a compiler and not a SRFI. A portable macro
layer can reach monomorphic operator selection, and phase 3 measured what that is worth:
about 12%. It cannot reach check elision, because check elision is a property of the
implementation's abstract domain and no amount of user-level notation supplies one.

SonicScheme (`sonic/`) starts at that domain rather than at a reader, because that is where
the measurements point. Its target is Ada's 1.13x with suppression kept scoped and named,
reached by making elision provable instead of asserted.
