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

## Still outstanding

- **Configuration 7, Stalin.** The Scheme ceiling reached by whole-program inference
  instead of declaration, and the control on the entire approach.
