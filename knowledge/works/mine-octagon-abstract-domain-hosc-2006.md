---
type: paper
title: "The Octagon Abstract Domain"
description: The full journal treatment of the domain of ±X ± Y ≤ c — strong closure with proofs, a tight closure for integers, incremental closure, a four-tier taxonomy of transfer functions, and the variable-packing strategy that let it scale to 400k lines inside Astrée.
resource: knowledge/sources/mine-octagon-abstract-domain-hosc-2006.pdf
tags: [octagon-domain, abstract-interpretation, weakly-relational, difference-bound-matrices, widening, numerical-domains]
authors: [Antoine Miné]
year: 2006
venue: "Higher-Order and Symbolic Computation 19(1):31-100"
informs: [/techniques/octagon-domain.md, /techniques/pentagon-domain.md, /techniques/interval-domain.md, /techniques/loop-analysis.md]
pipeline_stage: 06-pentagon
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Invariants of the form `±Xᵢ ± Xⱼ ≤ c` in `O(n²)` memory and `O(n³)` time per operation, sitting
between intervals (linear, non-relational) and polyhedra (exponential in practice). The
representation trick is old-ish; the contributions this 90-page version actually delivers are the
*normal form* and everything downstream of it. A shortest-path closure is not enough, because two
closed DBMs can denote the same octagon. Miné adds a second local propagation step and proves the
resulting **strong closure** satisfies a saturation property (Thm. 3): every finite entry of a
strongly closed matrix is attained by an actual point of the octagon. Saturation is what makes the
normal form a normal form (Thm. 4) and what makes the union, forget, and projection operators
*best* abstractions rather than merely sound ones.

Over the AST 2001 workshop paper, the new material is: all the proofs, the integer case solved via
tight closure, incremental closure, a four-tier taxonomy of transfer functions per operator,
backward assignment, widening with thresholds, narrowing, and the Astrée deployment.

# Mechanism

**Encoding.** `n` program variables become `2n` DBM variables: `V'₂ᵢ₋₁ ≡ Vᵢ`, `V'₂ᵢ ≡ -Vᵢ`. Then
`Vᵢ + Vⱼ ≤ c` is the potential constraint `V'₂ᵢ₋₁ - V'₂ⱼ ≤ c`, and `Vᵢ ≤ c` is
`V'₂ᵢ₋₁ - V'₂ᵢ ≤ 2c` — no phantom zero variable is needed. Index flipping is `ī = i xor 1` on
0-based indices. Each octagonal constraint has two encodings, so matrices are kept *coherent*:
`mᵢⱼ = m_{j̄ī}`. Concretization
`γ_Oct(m) = {(v₁..vₙ) | (v₁,-v₁,…,vₙ,-vₙ) ∈ γ_Pot(m)}`.

**Order and lattice.** `⊑_DBM` is pointwise `≤`; `⊔` is pointwise `max`, `⊓` pointwise `min`, plus
an adjoined `⊥_DBM`. `⊑_DBM ⟹ ⊆` but not conversely. For `I ∈ {Z,R}` the lattice is complete and
there is a Galois connection `P(V→I) ⇄ CDBM`; for `I = Q` it is only a *partial* Galois connection
(`α_Oct({x ∈ Q | x² ≤ 2})` would need `2√2`).

**Emptiness.** `γ_Pot(m) = ∅` iff `G(m)` has a strictly negative simple cycle (Bellman-Ford,
`O(n·s + n²)`). For `Q, R`, `γ_Oct(m) = ∅ ⟺ γ_Pot(m) = ∅` (Thm. 2, proved by a convexity/midpoint
argument). For `Z` the converse fails: a DBM can be potential-satisfiable with only half-integer
octagon solutions.

**Strong closure (Def. 1).** `m` is strongly closed iff `mᵢᵢ = 0`, `mᵢⱼ ≤ mᵢₖ + mₖⱼ`, and
`mᵢⱼ ≤ (mᵢī + m_{j̄j})/2`. The third condition is the extra propagation: from `2Vᵢ ≤ c` and
`2Vⱼ ≤ d` derive `Vᵢ + Vⱼ ≤ (c+d)/2`, which is *not* a path in the potential graph and therefore
invisible to Floyd-Warshall. The algorithm (Def. 2, in-place version Fig. 9) runs `n` steps of
`mᵏ = S(C_{2k-1}(mᵏ⁻¹))` where

    Cₖ(n)ᵢⱼ = min( nᵢⱼ, nᵢₖ+nₖⱼ, nᵢk̄+nk̄ⱼ, nᵢₖ+nₖk̄+nk̄ⱼ, nᵢk̄+nk̄ₖ+nₖⱼ )
    S(n)ᵢⱼ  = min( nᵢⱼ, (nᵢī + n_{j̄j})/2 )

Five terms, not two. Miné is candid: "there does not seem to exist a simple and intuitive reason
for the exact formulas"; they are what makes the interleaved `S` and `C` passes not destroy each
other, and the 25-case proof is in the appendix (Lemmas 1-3 behind Thm. 5). `O(n³)`. Thm. 6:
`γ_Oct(m) = ∅ ⟺ ∃i. mⁿᵢᵢ < 0`, so closure doubles as the emptiness test.

**Incremental strong closure (§3.4).** If `m` is already strongly closed and only rows/columns for
`c` variables changed, the first `n-c` iterations are no-ops; cost is `(n-c)·n²`. `Inc•ᵢ` restores
the normal form in `O(n²)` after *all* constraints touching one variable change. It is not
decomposable: `Inc•_{i₁,i₂} ≠ Inc•_{i₁} ∘ Inc•_{i₂}`, all modified rows must be handled at once.
This is the operator that makes the domain affordable in practice — in Astrée it accounts for 6% of
total analysis time, and the non-incremental closure is a rounding error because it is rarely
called.

**Integer case (§3.5).** A tightly closed DBM additionally has `mᵢī` even. Thm. 7 (the main new
theorem here) is that saturation and the normal-form property hold for tight closure in `Z`. The
algorithm is Harvey & Stuckey's, adapted to this encoding as `IncTᵢ₀ⱼ₀` (Def. 4), `O(n²)` per added
constraint; closing an arbitrary matrix means starting from `⊤` and adding all entries, so `O(n⁴)`.
Miné does not know whether that is tight and suspects it is. Practical alternatives: floor the `S`
pass, `S(n)ᵢⱼ = min(nᵢⱼ, ⌊(nᵢī + n_{j̄j})/2⌋)`, or the sharper variant that also forces
`2⌊nᵢⱼ/2⌋` when `i = j̄`. Both are sound and much smaller than `m`, but neither saturates, so
inclusion and equality tests degrade to semi-tests and union/forget stop being best abstractions.
Astrée uses the cheap one; Miné reports never finding a real program that needed tight closure.

    operator        domain      incr-1 / incr-var / full
    closure         potential   O(n²) / O(n²) / O(n³)     Z,Q,R
    strong closure  octagons    O(n²) / O(n²) / O(n³)     Q,R
    tight closure   octagons    O(n²) / O(n³) / O(n⁴)     Z

**Set operations.** `∩ = min`: exact, arguments need not be closed, result rarely is.
`∪ = max on strongly closed arguments`: this is the best abstraction (Thm. 10) *only* if both
arguments are closed, and the result is then automatically closed (Thm. 11). The asymmetry is the
practical rule of thumb — close before joining, don't bother before meeting. Forget (`Vf ← ?`):
drop row/column `2f-1, 2f`; exact iff the argument is closed (otherwise you destroy implicit
constraints that routed through `Vf`), preserves closure.

**Transfer functions come in four tiers per operator**, summarised in Fig. 27:

- `exact` — assignments `V ← [a,b]`, `V ← ±V + [a,b]`, `V ← ±Vᵢ + [a,b]`; tests that are already
  octagonal constraints. `O(n)` or `O(1)`; result restorable to closed form by `Inc•` in `O(n²)`.
  `V ← ±V + [a,b]` is *invertible*: it needs no closed argument and preserves closure.
- `nonrel` — project to intervals, evaluate with interval arithmetic, push back. Poor. Infers no
  relations and ignores the ones it has.
- `rel` — for *interval linear forms* `[a₀,b₀] + Σ[aₖ,bₖ]·Vₖ. Compute bounds of `expr ⊖ Vⱼ` for
  every `j` to derive `±Vᵢ ± Vⱼ` constraints, with the crucial detail that the subtraction is done
  *formally* on the linear form (Fig. 17) so occurrences cancel before interval evaluation:
  `(Y+Z) ⊖ Y` becomes `Z`, not `max(Y)+max(Z)-min(Y)`. Medium precision, and with the
  remove-one-contribution optimisation, roughly the cost of the interval version.
- `poly` — convert to a polyhedron, do it there, convert back. Best abstraction, exponential.
  Miné implements it only for regression testing.

**Extrapolation (§4.7).** Standard widening `(m ▽ n)ᵢⱼ = mᵢⱼ if mᵢⱼ ≥ nᵢⱼ else +∞`. Widening with
thresholds `▽th` snaps unstable bounds to the next value in a finite set `T` (using `2T` at `i = j̄`
positions, since those bound `±2V`). Narrowing `(m Δ n)ᵢⱼ = nᵢⱼ if mᵢⱼ = +∞ else mᵢⱼ`, refining
only infinite entries.

**The widening/closure hazard, which is the single most transferable warning in the paper.** The
sequence `mᵢ₊₁ = mᵢ ▽ nᵢ₊₁` terminates. The sequence `mᵢ₊₁ = (mᵢ)• ▽ nᵢ₊₁` **does not** — Fig. 25
exhibits a strictly increasing infinite chain, produced by the four-line program of Fig. 26.
Termination of `▽` rests on replacing more and more entries with `+∞`; strong closure fills them
back in. The octagon domain is effectively a reduced product of `2n²` one-constraint domains, and
closure is a `2n²`-way reduction between them; widenings cannot be applied pointwise across a
reduced product. Rule: never close the *left* argument of a widening; the right argument is fine,
and narrowing may close either.

**Astrée (§6).** One octagon over all live variables is impossible (14,000 globals). Packing: map
one pack to each syntactic C block; within a block, take simple expressions only (not `if`/`while`
statements), extract variables from `+ - *`, comparisons, `&& ||`, and the left argument of `/`,
but not from bit operators, calls, array lookups, or address-of; add a whole expression's variables
only if there are at least two; add loop-condition variables and any incremented/decremented
variable to the loop-body pack; discard packs subsumed by larger packs. Measured: average pack size
~3 variables across all code sizes, pack count linear in code size, so cost is **linear in program
size**. On 400k lines: 804 false alarms → 0, memory +30%, and analysis time *dropped* from 20h31
to 13h52 because the relational invariants stabilised in 96 iterations instead of 172.

# Applicability

Needs `Q` or `R` for the cubic closure and for best-precision operators. Integer variables analysed
as rationals is the recommended default and is sound (spurious non-integer points only).

Needs packing. Without it the `O(n²)`/`O(n³)` costs are on the whole variable set and the domain is
unusable; with it, cost is linear but *no information passes between packs* except via pivot
variables, so the packing strategy is where the precision actually gets decided.

Needs a float discipline if implemented in floats: always round upper bounds toward `+∞`.

Fundamentally weaker than polyhedra on any invariant involving three variables. The rate-limiter
example (§5.4) needs `R = X - S` exactly; octagons cannot hold it, get `Y ∈ [-144,144]` instead of
`[-128,128]`, and only find *any* bound at all because of the `rel` interval-linear-form assignment
plus a threshold widening. With the `nonrel` assignment it finds nothing.

The normal form is redundancy-maximal: strong closure makes every implicit constraint explicit, so
octagon representations have very few `+∞` entries. Polyhedra remove redundant constraints and can
therefore be *smaller and faster* on problems where a handful of inequalities suffice.

# Relevance

We are not implementing this. The document exists to say precisely what stage `06-pentagon` gives
up, and to harvest the parts that transfer.

**What Octagon buys that Pentagon cannot:** anything needing a sum. `X + Y ≤ 10` for the
"increment `Y` at most 11 times in a loop counted by `X`" pattern; mutual exclusion
`¬(X ∧ Y)` as `X ≤ 1 ∧ Y ≤ 1 ∧ X + Y ≤ 1`; absolute value `|X| ≤ Y + 1`; and the loop-invariant
`X + I = 17` for counter-up/counter-down pairs. Logozzo measured this as 177 additional validated
array accesses on `mscorlib.dll` — real, but small.

**What it costs:** `O(n²)` memory and `O(n³)` per operation even after packing, plus the
closure/widening hazard, plus a packing heuristic that is itself a source of imprecision and
tuning. Pentagon's `Sub` component has no closure at all, which is exactly why the hazard does not
exist there and why Logozzo can widen componentwise without thinking about it. That is a real
architectural simplification, not just a constant factor.

**Three things worth stealing outright, none of which require octagons:**

1. *Widening with thresholds.* A dense piecewise-linear ramp of a few dozen values, reused across
   all programs without tuning. Astrée's bounds all stabilised at the smallest threshold above the
   concrete bound. This belongs in stage `05-intervals` on day one.
2. *Interval linear forms with formal cancellation* (`⊕`/`⊖`, Fig. 17). Simplify `expr ⊖ Vⱼ`
   symbolically before evaluating it with interval arithmetic. This is a pure precision win inside
   an interval domain and costs almost nothing.
3. *The packing algorithm* (§6.2), if we ever add any relational domain over more than a pair of
   variables. It is domain-independent — Astrée uses the same technique for a decision-diagram
   partitioning domain.

And one warning to internalise: enabling a more precise domain made Astrée *faster*, because fewer
widening iterations were needed. Benchmark the whole fixpoint, not the operator.

# Notes

The paper is honest about its own limits in a way that is unusual. Miné flags that the `C+ₖ`
formula has no intuitive justification; that he does not know the true complexity of integer
closure; that making widening depend on which DBM represents an octagon "is not fully
satisfactory" and that designing a representation-insensitive widening is future work; and that he
cannot fairly compare octagons to polyhedra because no polyhedra library handles interval linear
forms or sound float arithmetic. Footnote 1 on p. 19 and footnote 2 on p. 53 both point at Bagnara
et al. 2005 for a simpler cubic strong closure and better widenings, published while this article
was being written — so the algorithm here is not the last word even on its own terms.

Astrée's C subset excludes recursion, unions, dynamic allocation, library calls, and threads. The
scaling result is real but it is a result about 400k lines of generated fly-by-wire control code
with one giant loop, not about general C.
