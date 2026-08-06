# Phase 4 Results: Reference Points

2026-08-06. Configurations 8 and 9 measured. Configuration 7 (Stalin) pending.
Instrument is retired instructions per step, per `LEDGER.md` D17.

## Configuration 8: Ada, and D5 is ratified

One source, `bench/nbody/nbody.adb`, three builds differing **only** in the pragmas.

| configuration | policy | instr/step | vs scalar C |
|---|---|---|---|
| `ada-8-checked` | Ada's default: every check on | 3195.00 | 4.89x |
| `ada-8-named` | `pragma Suppress` per named check | **801.00** | **1.22x** |
| `ada-8-all` | `-gnatp`, i.e. `Suppress (All_Checks)` | **801.00** | **1.22x** |

**Named suppression and `All_Checks` are identical to the instruction.** 801.00 against
801.00, from 803124427 and 803124418 raw counts at N=1,000,000. The eight-instruction
difference is startup, and it cancels in the slope.

`LEDGER.md` D5 adopted Ada's named per-check suppression over Common Lisp's 0-to-3 safety
dial, and carried `status: draft` pending exactly this measurement, on the stated condition
that if `All_Checks` beat named suppression meaningfully then granularity has a price and
the design needed rewriting. **It does not. Granularity is free.** D5 is ratified.

Two further things fall out.

**The mechanism is validated at the language level.** `PLAN.md` set the bar: "If GNAT with
`pragma Suppress` lands at or near scalar C on this program, the mechanism is validated and
we are copying something that demonstrably works." It lands at 1.22x scalar C. We are
copying something that works.

**Ada's check cost is 3.99x**, which is the same order as Chez's 4.77x from phase 3's
`chez-4-safe` to `chez-4`. Two unrelated language implementations, two unrelated check
architectures, and the cost of checking lands within 20% of each other. That is
corroboration that the phase 3 number is a property of the workload rather than an artifact
of Chez.

Worth stating because it is easy to miss: **Ada's default is stronger than C's.**
`Index_Check`, `Range_Check` and `Overflow_Check` are all on unless suppressed, so
`ada-8-checked` at 4.89x is not a badly-written baseline. It is a language that checks
integer overflow by default, which C does not.

## Configuration 9: the same CL source under three implementations

Covered in `../03-core-measurement/RESULTS.md` finding 3b, and restated here because it is
a reference point rather than a core measurement. `bench/nbody/config5.lisp` unchanged:

| implementation | instr/step | vs SBCL |
|---|---|---|
| SBCL 2.6.0 | 2015.00 | 1.0x |
| ECL 24.5.10 | 159625.85 | 79.2x |
| CLISP 2.49 | 421988.68 | 209.4x |

ECL reports `:NATIVE-C`, so this is native code 79x off SBCL's from identical declarations.

## The ranking, with Ada in it

| configuration | instr/step | vs scalar C |
|---|---|---|
| `c-native` | 333.00 | 0.51x |
| `c-scalar` | 654.00 | 1.00x |
| **`ada-8-named`** | **801.00** | **1.22x** |
| `racket-4` | 1494.37 | 2.28x |
| `chez-4` | 1788.41 | 2.73x |
| `sbcl-5` | 2015.00 | 3.08x |
| `ada-8-checked` | 3195.00 | 4.89x |
| `chez-4-safe` | 8521.41 | 13.03x |
| `chez-2a` | 9546.76 | 14.60x |

**Ada with named suppression beats every Lisp in the matrix**, and it does so while
remaining fully standard, fully portable Ada. That is the whole argument of
`PROPOSAL.md` in one row: the language whose standard names each check and lets you
suppress it at any scope gets closest to C, and it gets there without leaving the standard.

Both Scheme ceilings and SBCL's require leaving the standard entirely. Ada's does not.

## Configuration 7: Stalin computes in single precision, and does not win

Stalin was the control on this entire project. `PLAN.md`: "If Stalin already beats every
declaration-based configuration by a wide margin, then the interesting problem is inference
and not standardization, and this project is aimed at the wrong target."

Two findings, and the first one qualifies the second.

### Stalin's flonums are IEEE single precision, with no option to change that

```
$ stalin -On prec.sc && ./prec        $ scheme -q < prec.ss
4.84143161773681640625                4.841431442464721
3.333333492279052734375e-1            0.3333333333333333
```

The generated C confirms it: `stalin -On -c` on our nbody emits **335 occurrences of
`float` and zero of `double`**, and the constant `4.84143144246472090` is emitted as
`4.84143161773681640625`, which is its float32 rounding.

This is not a flag we failed to find. The man page has zero mentions of flonum precision,
real-number representation or IEEE anything; the only precision options control the
precision of *flow analysis*, not of arithmetic.

**So Stalin cannot express this benchmark.** Its output diverges from every other
configuration at the seventh significant figure and it fails the correctness oracle
outright. Configuration 7 is not measurable on equal terms, and no amount of care with
expression order fixes a data-width difference.

### Even with that advantage, it does not beat a tuned Chez

Measured anyway, for information, and never to be placed in the main ranking:

| configuration | instr/step | precision |
|---|---|---|
| `chez-4` | 1788.41 | **binary64** |
| `stalin-7` | 1889.99 | **binary32** |
| `sbcl-5` | 2015.00 | binary64 |

Stalin retires **5.7% more instructions than Chez's ceiling while doing half-width
arithmetic**. Single precision should be an advantage; it still loses.

`RESEARCH.md` section 3 records Stalin as 2x to 4x faster than Chez on float and array
benchmarks, taken from the `r7rs-benchmarks` corpus. **That comparison is now suspect on
its face.** Those benchmarks were comparing Stalin's binary32 against Chez's binary64, and
phase 1 already established that the same corpus ran Chez at `--optimize-level 2`, safe
mode with checks on. So the published gap is a single-precision program with a private shim
measured against a double-precision program running safe. It is not a compiler-quality
result.

### What this does to the argument

**The control passes: this project is aimed at the right target.** Whole-program inference,
in the one implementation famous for it, does not beat declaration-plus-policy. It ties
Chez's ceiling while cheating on precision.

It also strengthens `LEDGER.md` D7 with a second independent reason. D7 rejected
annotation-free whole-program inference because Stalin's performance is bimodal and nothing
in the source tells you which mode you are in. Compiling `config1.scm` unmodified showed
that mechanism directly: every warning Stalin emitted originated in `read`, and an
unprovable region did not stay local, it poisoned everything downstream that touched it.
Removing `read` silenced all of them. With no declarations to anchor on, there is nothing
to stop that propagation.

## Still outstanding

Nothing in phase 4. Configuration 7 is closed as **not measurable on equal terms**, which
is a result rather than a gap.
