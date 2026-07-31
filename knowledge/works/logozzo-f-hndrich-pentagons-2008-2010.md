---
type: paper
title: "Pentagons: A Weakly Relational Abstract Domain for the Efficient Validation of Array Accesses"
description: A numerical abstract domain of x in [a,b] AND x < y, built as an abstraction of the reduced product of intervals with strict-upper-bound maps, that validates ~89% of .NET array accesses in minutes by deliberately refusing to compute a transitive closure.
resource: knowledge/sources/logozzo-f-hndrich-pentagons-2008-2010.pdf
tags: [pentagon-domain, abstract-interpretation, bounds-check-elimination, weakly-relational, numerical-domains]
authors: [Francesco Logozzo, Manuel Fähndrich]
year: 2010
venue: "Science of Computer Programming 75(9); preprint dated 24 March 2009. Earlier conference version at ACM SAC 2008"
informs: [/techniques/pentagon-domain.md, /techniques/bounds-check-elimination.md, /techniques/interval-domain.md]
pipeline_stage: 06-pentagon
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Pentagons sit between Intervals and Octagons and are engineered for one job: discharge the
easy array-bounds obligations fast, so an adaptive analyzer can spend its budget on the hard ones.
The domain is `x ∈ [a,b] ∧ x < y`. The genuinely novel part is not the element shape — that is
just intervals paired with strict inequalities — but the deliberate refusal to close. A closed
domain of strict upper bounds costs `O(n³)`; Pentagons drop the transitivity saturation entirely,
push the lost precision into hand-written transfer functions, and use an approximate join that
materialises no new symbolic constraints. The result validated 88.9% of array accesses across four
.NET framework assemblies in about three minutes each, against 81.5% for intervals alone, and
against Octagons which took 1h39m on `mscorlib.dll` with 20 method-level timeouts.

The second, less advertised result is empirical and counterintuitive: the closure-based join
`⊔*ₚ` is **not** more precise than the cheap join `⊔ₚ` in practice. On `mscorlib.dll` it validated
*fewer* accesses (82.77% vs 83.19%) while taking 10:33 instead of 3:10.

# Mechanism

An element is a pair `⟨b, s⟩`.

**`b : Vars → Intv`** — an interval environment (`Boxes`), pointwise lifting of the interval
lattice. Interval order is inclusion (`[a₁,b₁] ⊑ᵢ [a₂,b₂] ⟺ a₁ ≥ a₂ ∧ b₁ ≤ b₂`), `⊥ᵢ` iff `a > b`,
join = convex hull, meet = intersection, widening keeps stable bounds and sends unstable ones to
`±∞`. `γ_Intv([i,s]) = {z | i ≤ z ≤ s}`.

**`s : Vars → P(Vars)`** — strict upper bounds (`Sub`), a map `x ↦ {y₁..yₙ}` meaning `x < yᵢ` for
each. Implement as a var-indexed array of bitsets. Its lattice is *reverse* inclusion, since fewer
constraints is less information:

    order:      s₁ ⊑ₛ s₂  ⟺  ∀x ∈ s₂. s₁(x) ⊇ s₂(x)
    bottom:     ∃x,y. y ∈ s(x) ∧ x ∈ s(y)          (a contradiction x < y ∧ y < x)
    top:        ∀x. s(x) = ∅
    join:       λx. s₁(x) ∩ s₂(x)                   (keep what holds on both branches)
    meet:       λx. s₁(x) ∪ s₂(x)
    widening:   λx. if s₁(x) ⊆ s₂(x) then s₂(x) else ∅

`γ_Sub(s) = ⋂_{x∈s} {σ | y ∈ s(x) ⟹ σ(x) < σ(y)}`.

**The pentagon operations** (Fig. 6). The order is a refined pairwise order: `⟨b₁,s₁⟩ ⊑ₚ ⟨b₂,s₂⟩`
iff `b₁ ⊑_b b₂` and every symbolic constraint `x < y` in `s₂` is either explicit in `s₁` or implied
numerically by `b₁`, i.e. `sup(b₁(x)) < inf(b₁(y))`. Bottom if either component is bottom; top if
both are. Meet and widening simply delegate componentwise — **no closure is performed before
widening**, deliberately, to dodge the closure/widening divergence Miné documents for Octagons.

The join is the interesting operator:

    ⟨b₁,s₁⟩ ⊔ₚ ⟨b₂,s₂⟩ =
      b⊔ = b₁ ⊔_b b₂
      s⊔ = λx. s′(x) ∪ s″(x) ∪ s‴(x)
        where s′  = λx. s₁(x) ∩ s₂(x)
              s″  = λx. { y ∈ s₁(x) | sup(b₂(x)) < inf(b₂(y)) }
              s‴  = λx. { y ∈ s₂(x) | sup(b₁(x)) < inf(b₁(y)) }

That is: keep constraints present in both, plus constraints present in one operand and *implied by
the other operand's intervals*. Nothing new is invented at the join point. Implied relations that
were dropped can often be recovered lazily afterwards, since `x < y` can be re-derived from the
numeric part by two table lookups and a comparison.

**The closure, for reference and for not implementing.**

    b* = ⨅_{x<y ∈ s} ⟦x < y⟧(b)
    s* = λx. s(x) ∪ { y ∈ b | x ≠ y ⟹ sup(b*(x)) < inf(b*(y)) }
    ⊔*ₚ = ⟨b₁* ⊔_b b₂*, s₁* ⊔ₛ s₂*⟩

`O(n²)` because `s*` inspects all interval pairs. The *other* closure — the transitivity saturation
`y ∈ s(x), z ∈ s(y) ⟹ z ∈ s(x)` — is `O(n³)` and is never performed in Clousot. Instead the
transfer functions carry bounded transitivity:

    ⟦x := y - 1⟧(s) = s[x ↦ {y} ∪ s(y)]         (if x does not occur in s)
    ⟦x == y⟧(s)     = s[x, y ↦ s(x) ∪ s(y)]
    ⟦x < y⟧(s)      = s[x ↦ s(x) ∪ s(y) ∪ {y}]
    ⟦x ≤ y⟧(s)      = s[x ↦ s(x) ∪ s(y)]

**Two transfer functions that carry the paper's weight.** Both cross the interval/symbolic
boundary in the direction the other component cannot do alone.

Subtraction (kills array *underflow* checks — the pattern `assume x≥0 & y≥0; if (x>y) r := x-y;
assert r ≥ 0`, which intervals cannot prove because `[1,+∞] - [0,+∞] = ⊤`):

    ⟦r := sub x y⟧⟨b,s⟩ = ⟨ b[r ↦ (b(x) - b(y)) ⊓ᵢ (x ∈ s(y) ? [1,+∞] : ⊤ᵢ)],
                            s[r ↦ inf(b(y)) > 0 ? {x} ∪ s(x) : ∅] ⟩

Remainder (kills array *overflow* checks — `assume len ≥ 0; r := rem x len; assert r < len`, where
intervals have no finite upper bound for `len` and `Sub` alone cannot determine `d`'s sign):

    ⟦r := rem u d⟧⟨b,s⟩ = ⟨ ⟦r := rem u d⟧(b),
                            s[r ↦ inf(b(d)) ≥ 0 ? {d} : ∅] ⟩

**Cost.** `O(n²)` worst case in time and space. In practice the expensive step is skipped or done
lazily and the domain behaves almost linearly.

# Applicability

The analysis runs on a normalised scalar program "similar to SSA form" with the evaluation stack
removed, the heap abstracted, and source-level expressions reconstructed from bytecode. That
front-end work is a precondition, not a detail — the domain is over scalar variables with names.

Pentagons cannot express `x + y ≤ k` or any equality like `x + y == 22`. Any bounds obligation
whose proof needs a relation between two variables and a numeric offset falls outside. Measured:
Octagons validate 177 more array accesses than Pentagons on `mscorlib.dll`. Clousot's answer is to
run a hybrid where constants live only in the Pentagon and the Octagon tracks only `x ± y ≤ k`.

The 88.9% figure is a property of the .NET framework's coding style, not a law. Run on Clousot's
own source, Pentagons validate only 72%. The paper's formal development ignores integer overflow
(the shipping implementation does not).

Because there is no closure, the domain is sensitive to how much the transfer functions bother to
derive. Precision is bought in hand-written cases, not in a general saturation rule, so the domain
gets better only as you write more cases.

# Relevance

This is the specification for stage `06-pentagon`. Concretely, from this paper we take: the two
maps as the representation, `Sub` as var → bitset; the reverse-inclusion lattice for `Sub`; the
approximate join `⊔ₚ` and not `⊔*ₚ`; no transitive closure anywhere; no closure before widening;
and the four bounded-transitivity assignment/guard rules plus the `sub` and `rem` transfer
functions. Both of those last two are directly applicable to Scheme — `fx-` under a known ordering
and `fxmodulo` with a non-negative divisor are exactly the patterns that show up in indexing code.

The join design is the transferable idea beyond this one domain: at a control-flow merge, do not
compute anything new; keep what is already written down on either side and cross-check it against
the cheap component. It costs a table lookup instead of a fixpoint.

The measured Intervals-only baseline (81.45% average) is the number stage 05 alone should be
expected to hit, and the 88.82% for the *unreduced Cartesian product* `Intv × Sub` says most of the
gain comes from simply running both domains side by side. Full pentagons add 0.07 percentage
points over that. If the reduced product turns out to be fiddly, the Cartesian product is worth
almost all of it.

# Notes

**The file is the journal preprint, not the conference paper.** The title page reads "Preprint
submitted to Science of Computer Programming, 24 March 2009"; it was published as
Science of Computer Programming 75(9):796-807, 2010. The slug's "2008" refers to the earlier ACM
SAC 2008 paper of the same title, which this PDF is not. There is no year on the title page.
Author name is *Fähndrich*, printed with the umlaut.

**Three typos worth knowing before implementing from the figures.**

1. Fig. 3, interval widening: printed as `[a₁,b₁] ▽ᵢ [a₂,b₂] = [a₁ ≤ a₂ ? a₂ : -∞, ...]`. Taking
   `a₂` when `a₁ ≤ a₂` tightens the lower bound and is unsound. Use Cousot's form — keep the *old*
   bound `a₁` when it is stable, `-∞` otherwise.
2. §6.2.1, the `sub` transfer function prints `b(inf(y))`, which is not well-typed; it means
   `inf(b(y))`.
3. §6.2.2 reads "the upper bound for `len` is `+∞`, so that any interesting relation between `r`
   and `len` can be inferred" — it means *no* interesting relation.

Fig. 1's caption states the inferred invariant as `0 ≤ num ∧ num2 < array.Length`, which is weaker
than and inconsistent with the body text's `0 ≤ num < array.Length ∧ 0 ≤ num2 < array.Length`.

**The closure result is the most useful finding in the paper and it is buried in §8.1.** Adding
closure to the join made the analysis 3x slower, caused three method timeouts, and produced
*lower* validation rates on three of four assemblies. The mechanism: at joins, closure materialises
a quadratic number of new symbolic constraints out of the distinct integer constants that .NET
methods are full of, and those constraints are almost all meaningless. This is the same failure
mode they diagnose for Octagons (`b = 1, y = 2` for a bool and an int produces four garbage
octagonal constraints). "More precise operator" and "more precise analysis" come apart here, and
the reason is that precision in a domain interacts with iteration budget.
