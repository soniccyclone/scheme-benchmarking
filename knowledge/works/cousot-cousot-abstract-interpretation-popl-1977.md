---
type: paper
title: "Abstract Interpretation: A Unified Lattice Model for Static Analysis of Programs by Construction or Approximation of Fixpoints"
description: Establishes that program analyses are fixpoints of order-preserving interpretations over lattices, and introduces widening and narrowing to force termination when those fixpoints are not reachable in finitely many steps.
resource: knowledge/sources/cousot-cousot-abstract-interpretation-popl-1977.pdf
tags: [abstract-interpretation, fixpoint-approximation, widening, narrowing, interval-domain]
authors: [Patrick Cousot, Radhia Cousot]
year: 1977
venue: "POPL 1977, pp. 238-252"
informs: [/techniques/interval-domain.md, /techniques/dataflow-analysis.md, /techniques/loop-analysis.md, /techniques/pentagon-domain.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

The paper's real claim is a reduction: every static analysis they could find (Kildall's constant
propagation, available expressions, live variables, type checking, Floyd/Hoare deductive
semantics, even program performance analysis via Kirchhoff's law) is the same object viewed at
different resolution. A program is a flowchart. Its concrete static semantics is the least
fixpoint of `Cv = F-cont(Cv)` over `Context-Vectors = Arcs⁰ → 2^Env`. An *abstract
interpretation* is a tuple `I = ⟨A-Cont, ∘, ≤, ⊤, ⊥, Int⟩` where `A-Cont` is a complete
join-semilattice and `Int : Arcs⁰ × Ã-Cont → A-Cont` is order-preserving; the analysis result is
an extreme fixpoint of `Cv = Ĩnt(Cv)`, which exists by Tarski. Analyses are then classified on
three independent axes — join vs meet, forward vs backward, maximal vs minimal solution — giving
the eight-vertex cube of section 5.2. Kildall is `(∩,→,↑)`; Wegbreit is `(∪,→,↓)`.

The second and, for us, more important contribution is section 9: what to do when the Kleene
sequence does not terminate. This is the origin of **widening** and **narrowing**.

# Mechanism

**Consistency (§6).** Two interpretations are related by a pair `α : C-Cont → A-Cont`,
`γ : A-Cont → C-Cont` satisfying 6.1-6.4: both order-preserving, `∀x̄ ∈ A-Cont. x̄ = α(γ(x̄))`,
and `∀x ∈ C-Cont. x ≤ γ(α(x))`. Rather than proving global soundness directly, they prove the
*local* condition 6.5 on the primitive transfer functions, `γ(Int(a,x̄)) ≥ Int(a,γ(x̄))` (and its
equivalent dual, lemma L2), and then transfer it to fixpoints via theorems T1/T2. That is the
whole soundness recipe: verify per-instruction, get per-program for free.

**Termination (§8.2).** The abstract evaluation `Cv := (C := ⊥̃; until C = Ĩnt(C) do C := Ĩnt(C))`
terminates iff the Kleene sequence is finite: `A-Cont` finite, of finite length `m`, or satisfying
the ascending chain condition. Intervals satisfy none of these.

**Widening (§9.1.3).** Define `∇ : A-Cont × A-Cont → A-Cont` with

- 9.1.3.2 `C ∘ C' ≤ C ∇ C'` (it is an upper bound of both), and
- 9.1.3.3 every sequence `s₀ = C₀, sₙ = sₙ₋₁ ∇ Cₙ` is *not strictly increasing*.

Pick `W-arcs`, a minimal set of arcs such that every cycle of the equation system contains at
least one. On a reducible forward graph these can be the exit arcs of junction nodes that are
interval headers — i.e. loop back-edges. Then

    A-int(q, Cv) = if q ∈ W-arcs then Cv(q) ∇ Int(q, Cv) else Int(q, Cv)

and the sequence `S₀ = ⊥̃, Sₙ₊₁ = if not(Ĩnt(Sₙ) ⊑ Sₙ) then Ã-int(Sₙ) else Sₙ` is increasing,
stabilises at some finite `m`, and `Sₘ ⊒ lfp`. Widening is applied only at loop heads; everywhere
else you keep the exact transfer function.

**Narrowing (§9.3.4).** Dually, `Δ` with `C ≥ C' ⟹ C ≥ C Δ C' ≥ C'` and no strictly decreasing
`Δ`-sequence. `D-int` uses `Δ` at the same `W-arcs`. Starting the descending sequence from `Sₘ`
keeps every iterate inside the partition `{X | X ⊒ Ĩnt(X)}`, so the limit `S'ₚ` is still above the
least fixpoint — that is the whole reason narrowing is sound where a plain descending Kleene
sequence from `⊤` is not.

**The interval instance (§9.2, §9.4).** With `[a,b]` meaning `a ≤ x ≤ b`:

    [i,j] ∇ [k,l] = [ if k < i then -∞ else i ,  if l > j then +∞ else j ]
    [i,j] Δ [k,l] = [ if i = -∞ then k else min(i,k) ,  if j = +∞ then l else max(j,l) ]

Widening discards any bound that moved; narrowing only refines bounds that are infinite, never
touching a finite one. On `x := 1; while x ≤ 100 do x := x+1`, the widened system gives
`C2 = [1,+∞]`, `C5 = [101,+∞]`. The narrowing pass then recovers `C2 = [1,101]` and
`C5 = [101,101]` — exactly the fact an array-bounds check needs.

**§9.5** partitions the lattice and shows the ascending approximation sequence and the truncated
descending sequence are *not* duals: AAS from `⊥̃` bounds `lfp` from above, TDS from `⊤̃` bounds
`gfp` from above. Running all four (AAS, TDS, DAS, TAS) brackets both extreme fixpoints. They
close by admitting no general "fixpoint improvement method" exists: once you land on a
non-extremal fixpoint, nothing in this framework gets you off it.

# Applicability

`Int` must be order-preserving; that is the only structural requirement, and it is why the model
covers so much. Best-precision results need more (complete morphism gives the exact least
fixpoint; continuity gives the Kleene limit; mere isotony gives only an approximation `⊑ lfp`).
Requirement 6.3 is an *equality*, `α ∘ γ = id`, which makes `α` surjective and `γ` injective —
this is a Galois insertion, not the general adjunction. Domains where distinct abstract elements
denote the same concrete set (an unreduced product; a DBM before closure) do not satisfy it as
stated. Widening's cost is precision: their own worked example calls it "a very rough operation
which introduces a great loss of information," and they recommend seeding with declared bounds
before falling back to infinity. The `W-arcs` choice is a real design decision — on irreducible
graphs it is arbitrary, and a bad cut widens more than necessary.

# Relevance

Stage `05-intervals` needs §9.1.3 and §9.3.4 verbatim: the widening operator, the `W-arcs`
selection, and the descending narrowing pass. The narrowing pass is the cheap part and it is what
turns `[1,+∞]` into `[1,101]`, so skipping it forfeits most loop-bounds checks. Their
widening-with-declared-bounds hint is the ancestor of Miné's widening with thresholds and is worth
implementing before the plain `-∞/+∞` form. Section 6's local-consistency recipe is how we should
prove our transfer functions sound: per-instruction obligations, not whole-program arguments.

# Notes

**Bibliography correction.** Our plan describes this paper as the source of "Galois connections,
widening, narrowing, fixpoint approximation." Widening, narrowing, and fixpoint approximation are
all here. **Galois connections are not.** The phrase does not appear anywhere in the paper. What
appears is the `α`/`γ` pair under hypotheses 6.1-6.4 with `α ∘ γ = id`, which in modern terms is a
Galois *insertion*. The adjunction formulation `α(c) ⊑ d ⟺ c ≤ γ(d)` — the one Logozzo and Miné
both cite as "[13]"/"[18]" and attribute here — is actually from Cousot & Cousot, *Systematic
Design of Program Analysis Frameworks*, POPL 1979. Anyone reading this PDF looking for a Galois
connection will not find one, and the citation chain that credits it to POPL'77 is folklore.

The PDF is a 16-page scan of the ACM proceedings with no text layer (page 1 is the conference
cover; the paper runs pp. 238-252). It was read by rendering each page as an image.

Section 9.2 opens with "In a PASCAL program operating on arrays, the compiler should ensure that
arrays are subscripted only by indices within bounds." Bounds-check elimination is the paper's own
motivating example for the interval domain, which is a nice thing to know when justifying stage
05 and 06 to anyone who thinks abstract interpretation is a verification-only idea.
