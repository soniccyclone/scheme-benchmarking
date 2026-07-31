---
type: implementation
title: Stalin
description: Whole-program optimizing Scheme compiler. C-competitive on numeric code, catastrophic on allocation-heavy code.
resource: https://github.com/barak/stalin
tags: [scheme, whole-program, inference, ceiling]
implements: [/techniques/control-flow-analysis.md, /techniques/storage-class-assignment.md, /techniques/escape-analysis.md, /techniques/closure-conversion.md, /techniques/procedure-inlining.md]
lacks: [/techniques/generational-gc.md]
status: stable
---
# What it is

The counterexample to "Scheme is slow", and the control on this project's whole approach.
Reaches C-competitive numeric code by *inference* rather than declaration. Version 0.11,
October 2006, unmaintained, targets full R4RS.

# Mechanism

One decision licenses everything: a closed world, the entire program visible at once, no
code added later. From Siskind's own announcement the pass list is polyvariant
interprocedural flow analysis, flow-directed interprocedural escape analysis, lightweight
CPS and closure conversion, interprocedural lifetime analysis, automatic inlining, unboxing,
and program-point-specific representation selection.

Two passes matter most. **Representation selection** derives a precise type per expression
and picks the machine representation per program point, so a value known to be a double
becomes a raw unboxed C double. **Lifetime analysis** estimates the lifetime at each
allocation point and chooses stack, region, or heap. Whatever it cannot bound falls to the
heap, and the heap is Boehm.

# The measured profile

From `ecraven/r7rs-benchmarks`, against Chez 10.3.0 on 31 shared benchmarks. Median 0.77,
geometric mean 0.63.

| wins | ratio | losses | ratio |
|---|---|---|---|
| mbrot | 3.87x | diviter | 0.06 |
| pnpoly | 2.80x | divrec | 0.07 |
| array1 | 2.23x | ack | 0.08 |
| simplex | 1.83x | graphs | 0.11 |

Bimodal, and the mechanism explains it exactly. Where the analysis succeeds and
representation selection unboxes, Stalin beats a 2026 Chez by 2x to 4x. Where lifetime
analysis cannot bound the data and everything falls through to Boehm, it loses by 5x to 16x.
**The wins come from the analysis; the losses come from the collector it falls back to.**

# Why this matters to us

Whole-program inference is all-or-nothing and **nothing in the source tells you which case
you are in**. That is the performance shadow of the usability failure recorded in
[type-recovery](/techniques/type-recovery.md), and it is the argument for declarations on
*predictability* rather than on achievable speed. Inference reaches higher where it works.

It is also why our runtime uses a precise generational collector rather than Boehm: adopting
Boehm would import Stalin's exact failure mode.

# Caveats

Version 0.11 is from 2006; Chez 10.3.0 is current. Absolute comparison is unfair to Stalin
by twenty years of compiler work, and its wins are more impressive than they look. It
completed 33 of 57 benchmarks; the 23 failures are R4RS-versus-R7RS language coverage, not
optimizer limits.
