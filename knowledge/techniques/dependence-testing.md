---
type: technique
title: Dependence testing
description: Deciding whether two array references in a loop nest can touch the same location, which is the precondition for every loop transformation and for vectorization.
tags: [dependence, loop-analysis, vectorization]
sources:
  - resource: /works/allen-kennedy-advanced-compiling-high-performance.md
  - resource: /works/larsen-amarasinghe-exploiting-superword-level-parallelism-.md
implemented_by: []
absent_from: [/implementations/chez.md, /implementations/sbcl.md]
pipeline_stage: 07-loops
status: draft
generated: { by: "wave3-topup/claude", at: "2026-07-30T00:00:00Z" }
---
# Problem

Before any loop can be reordered, fused, distributed, or vectorized, you must know whether
two array references can refer to the same location on different iterations. Get it wrong in
the permissive direction and you miscompile silently. Get it wrong in the conservative
direction and no loop transformation is ever legal.

This is the precondition for pipeline stage 10, and it is the substantial thing our corpus
gained from Allen and Kennedy chapter 3.

# Mechanism

The suite is a decision cascade, cheapest test first, each answering "independent",
"dependent", or "unknown" (which must be read as dependent).

1. **Partition subscripts** into separable and minimal coupled groups. A subscript is
   separable if its index variables appear in no other subscript; those are tested
   independently. Coupled groups must be tested jointly.
2. **Classify by index-variable count.** ZIV (zero index variables) is a constant comparison.
   SIV (single) admits closed-form tests. MIV (multiple) needs the general machinery.
3. **SIV has four variants**, each with its own closed-form test *and* its own remediating
   transformation when a dependence is found: strong, weak, weak-zero, weak-crossing. Exact
   SIV goes through the extended GCD.
4. **GCD and Banerjee** for the general case, with a trapezoidal variant for non-rectangular
   iteration spaces.
5. **The Delta test** for coupled subscripts, propagating constraints between them.

# Preconditions

Subscripts must be affine in the loop induction variables. Anything else falls to "unknown"
and blocks the transformation. Induction variables must already be recognized, which is why
this sits at stage 07 and depends on the induction-variable substitution described there.

# Cost

Cheap in the common case, because the cascade exits early: ZIV and SIV cover most real
subscripts and are closed-form. Banerjee and Delta are the expensive tail.

# Disagreements

Allen and Kennedy's whole framework is **loop-based**: it reasons about iteration spaces and
dependence distance. Larsen and Amarasinghe's SLP is **basic-block based** and needs no
dependence testing at all, only that the statements being packed are independent within one
block. These are complementary rather than competing, and our stage 10 will want both:
SLP for straight-line f64 bodies, loop dependence for anything crossing iterations.

# For us

Stage 07 feeds stage 10, and this is the mechanism by which. Note that neither Chez nor SBCL
has any of it, which is consistent with neither having an autovectorizer.

**This document is `status: draft` and thin relative to its source.** Chapter 3 is roughly
fifty pages of algorithm with its own vocabulary, and this summary is written from a
synthesis report rather than from a full reading of that chapter. Expand it before
implementing stage 07.
