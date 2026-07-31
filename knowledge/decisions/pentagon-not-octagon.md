---
type: decision
title: Pentagon domain, not Octagon
description: Target intervals plus strict upper bounds at stage 06. Octagon is more precise, more expensive, and carries a widening hazard Pentagon structurally avoids.
status: stable
tags: [abstract-domain, stage-06]
sources:
  - resource: /techniques/pentagon-domain.md
  - resource: /techniques/octagon-domain.md
  - resource: /techniques/interval-domain.md
  - resource: /techniques/bounds-check-elimination.md
generated: { by: "human:nathan", at: "2026-07-30T00:00:00Z" }
---
# Decision

Stage 06 implements Pentagon: `x ∈ [a,b] ∧ x < y`. Level 3 in the hierarchy.

# Why

**The authors' own measurement.** Pentagons §8.1 reports that closure made the domain *less*
precise on three of four .NET assemblies (82.77% against 83.19% on mscorlib) while tripling
analysis time. That is the strongest evidence for this choice and it is buried where most
readers skip.

**An architectural argument, not just a cost one.** Miné exhibits a four-line program that
produces a strictly increasing infinite chain if you strongly close the left argument of a
widening. Pentagon's `Sub` has no closure operation at all, so the hazard does not arise.

# What we are giving up, honestly

The "octagons do not scale" claim needs a qualifier. Miné and Logozzo genuinely conflict:
400k lines with analysis time going *down*, against 1h39m and 35 timeouts, same domain. The
difference is packing, and Logozzo states MSIL admits no workable packing because nested
scopes are compiled away. Our `let`/`letrec` core language would admit one better than MSIL
does. The cost argument alone is therefore weaker than usually stated; the closure and
widening arguments above carry the decision independently.

# Cheap fallback

Logozzo's Figures 11 and 12: an *unreduced* Cartesian product of intervals and strict upper
bounds validates 88.82% against 88.89% for full Pentagons. The entire reduced-product
machinery is worth 0.07 percentage points. Build the side-by-side version first.

# Implementation warning

The Pentagons paper prints four transcription errors, including a widening unsound in both
halves that is **masked whenever the iterate sequence is monotone increasing** — exactly what
a naive test suite produces. Re-derive every formula. Detail in
[pentagon-domain](/techniques/pentagon-domain.md).
