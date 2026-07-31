---
type: paper
title: "The Octagon Abstract Domain"
description: The ten-page workshop original of the octagon domain — the coherent-DBM encoding, the strong closure algorithm, and the operator set, stated without proofs, without the integer case, and without any evidence that it scales.
resource: knowledge/sources/mine-octagon-ast-2001.pdf
tags: [octagon-domain, abstract-interpretation, weakly-relational, difference-bound-matrices, numerical-domains]
authors: [Antoine Miné]
year: 2001
venue: "AST 2001 in WCRE 2001, IEEE Computer Society, pp. 310-319. PDF is the author's arXiv reprint cs/0703084v2, 16 Mar 2007"
informs: [/techniques/octagon-domain.md, /techniques/pentagon-domain.md]
pipeline_stage: 06-pentagon
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

This is the short version of `mine-octagon-abstract-domain-hosc-2006`. **Confirmed: the two files
are the workshop and journal versions of the same work, and the journal article says so in its own
first footnote** — "This paper is the journal version of an earlier conference paper [44] sharing
this title," where reference [44] is `Miné, A.: 2001b, 'The Octagon Abstract Domain'. In: AST 2001
in WCRE 2001. pp. 310-319`. That is exactly this document. The journal footnote continues: "the
present version, extracted from the author's PhD, is extended in many ways and enriched with new
experimental results."

The workshop paper's own contribution, relative to Miné's earlier PADO-II difference-bound-matrix
domain, is the extension from `x - y ≤ c` to `±x ± y ≤ c` via the positive/negative variable
doubling, and the strong closure algorithm needed to normalise the resulting matrices.

# Mechanism

Everything structural is already here and unchanged in the journal version:

- **The `2N × 2N` coherent DBM.** Each `vᵢ` gets `v⁺ᵢ` at index `2i` and `v⁻ᵢ` at `2i+1`; the
  translation table (Fig. 5) maps each octagonal constraint to its one or two potential
  constraints; `ī = i ⊕ 1` via bitwise xor; coherence is `m⁺ᵢⱼ = m⁺_{j̄ī}` (Thm. 1).
- **`V⁺`-domain concretization** `D⁺(m⁺) = {(s₀..s_{N-1}) | (s₀,-s₀,…) ∈ D(m⁺)}`.
- **Closure vs strong closure.** Floyd-Warshall closure (Fig. 7) is a normal form for potential
  sets (Thm. 3) but not for octagons, because the deduction of `v⁺ᵢ - v⁻ⱼ ≤ (c+d)/2` from
  `v⁺ᵢ - v⁻ᵢ ≤ c` and `v⁺ⱼ - v⁻ⱼ ≤ d` is not a path. Strong closure (Def. 1, algorithm Fig. 8)
  interleaves `S⁺(n⁺)ᵢⱼ = min(n⁺ᵢⱼ, (n⁺ᵢī + n⁺_{j̄j})/2)` with the five-term `C⁺ₖ`, `O(N³)`.
  Saturation and normal form are Thm. 4. Miné already writes here that "there is no simple
  explanation for the complexity of `C⁺ₖ`."
- **Operators.** Inclusion/equality via strong closure (Thm. 5); projection to an interval from the
  diagonal-adjacent entries (Thm. 6); `∧ = min` exact, `∨ = max` best only on strongly closed
  arguments (Thm. 7), and the observation — with an explicit shot at Shaham, Kolodner & Sagiv's
  CC2000 paper — that closing *after* a union is useless work while closing after an intersection
  is necessary.
- **The widening/closure hazard.** Already stated, with the counterexample (Fig. 10): closing the
  left argument of `▽` admits a strictly increasing infinite chain, so fixpoints must be computed
  in the un-closed lattice `M⁺⊥`, not in `M•⊥`.
- **Two lattices.** `M⁺⊥` (coherent DBMs, used for fixpoint transfer) and `M•⊥` (strongly closed
  DBMs, one-to-one with non-empty octagons), the latter carrying a canonical Galois insertion
  `P(V⁺ ↦ I) ⇄ M•⊥` (Thm. 10).
- **Guards and assignments** (Def. 2), and the abstract-execution driver for a toy
  assignment/if/while language (§VIII.A).

# What the journal version adds

This is the section the ingest exists for. The 90-page HOSC 2006 article contains, and this
10-page paper does not:

1. **All the proofs.** §I here says outright: "For the sake of brevity, we omit proofs of theorems
   in this article. The complete proof for all theorems can be found in the author's Master
   thesis." The journal version carries a 17-page appendix (pp. 74-90) proving Thms. 1-18,
   including the three lemmas and 25-case analysis that justify the exact shape of `C⁺ₖ`.
   **This is the closure-algorithm proof material. Treating the two files as one work loses it
   entirely**, and with it any ability to check a closure implementation against its correctness
   argument.
2. **The integer case, solved.** This paper identifies the problem (§V.D: strong closure does not
   give the smallest DBM over `Z`; the normal form must additionally require `m⁺ᵢī` even) and then
   gives up: "We were unable, at the time of writing, to design such an algorithm and keep a
   `O(N³)` time cost." It recommends analysing integers as rationals. The journal version defines
   *tight closure* (Def. 3), adapts Harvey & Stuckey's incremental algorithm to this encoding
   (Def. 4, `IncT`, `O(n²)` per constraint, `O(n⁴)` from scratch), and proves **Thm. 7 — saturation
   and the normal-form property hold for tightly closed DBMs over `Z`** — which the journal calls
   "an important theoretical contribution of this article." It also gives two sound rounded
   fallbacks and states what precision they cost (semi-tests instead of tests; non-best union and
   forget).
3. **Incremental strong closure** `Inc•` (§3.4). Absent here. This is the operator that restores
   the normal form in `O(n²)` after one variable's constraints change, and it is what makes the
   domain practical — 6% of Astrée's total runtime, with the non-incremental closure "a negligible
   fraction."
4. **A real transfer-function taxonomy.** Here there is one exact case per shape and a single
   crude fallback (Def. 2.6), with an interval-arithmetic improvement sketched informally in prose.
   The journal gives four tiers per operator (`exact` / `nonrel` / `rel` / `poly`), the interval
   linear form representation `[a₀,b₀] + Σ[aₖ,bₖ]·Vₖ` with the `⊕`/`⊖` formal-cancellation
   operators, the summary table Fig. 27 recording each operator's cost, precision, and closure
   requirements, and the octagon ↔ interval ↔ polyhedron conversion operators including
   polyhedron-to-octagon via the frame (vertex/ray) representation.
5. **Backward assignment** (§4.6), all four tiers. Entirely absent here.
6. **Widening with thresholds** `▽th` and the standard **narrowing** `Δstd`. This paper has only
   the plain widening and no narrowing at all.
7. **Astrée** (§6): the packing algorithm, the float implementation with directed rounding, and
   results on 370 to 400,000 lines of avionics C. Where this paper's §VIII.C says "Because a fully
   featured tool using our domain is not yet available, we do not know how well this analysis
   scales up to large programs" and the conclusion says "our prototype implementation did not allow
   us to test our domain on real-life programs and we still do not know if it will scale up," the
   journal reports 804 false alarms reduced to 0 with a 30% memory increase and a *shorter* total
   analysis time.
8. **Worked examples.** Here: the random walk (Fig. 1/11), plus a mention of bubble sort, heap
   sort, and Lamport's bakery algorithm. The journal adds the increasing and decreasing loop
   counters, absolute value, and the rate limiter — the last being the one honest example where
   polyhedra strictly beat octagons.
9. **A correction, not just an expansion.** Here the Galois insertion is built on the strongly
   closed lattice `M•⊥` and completeness is claimed for `I = Z` or `R` "but not `Q`". The journal
   puts the connection on `CDBM` directly and works out that over `Q` the abstraction function
   `α_Oct` is a *partial* function, giving only a partial Galois connection.

Unchanged between the two: the encoding, the coherence condition, the xor index trick, the strong
closure formulation, the `O(n²)` memory / `O(n³)` time headline, the emptiness test, the
union/intersection closure asymmetry, and the widening/closure divergence warning.

# Applicability

Same domain, same limits — `±x ± y ≤ c` only, needs `Q`/`R` for the cubic algorithms, no packing
and therefore no scalability story. As a document, its practical scope is narrower than its
successor's: it will get you a correct encoding and a correct-looking closure, and leave you
stranded on integers, on incrementality, on precision tuning, and on scale.

# Relevance

Read this one for orientation — it is ten pages and it states the whole idea cleanly. Implement or
argue from the journal version. For our purposes, the interesting sentence is in §VIII.C: even in
2001, before packing, Miné knew he had no evidence the domain scaled, and the honest scaling answer
took five more years and an industrial deployment to produce. That is the historical shape of the
argument for choosing Pentagon at stage 06: the relational domain that is cheap enough to run
unconditionally was not the one with the better precision bound.

# Notes

**Bibliography correction, and it is the one this batch was assigned to settle.**
`docs/phases/00-compiler-research/PLAN.md` lists a single work — "Miné, *The Octagon Abstract
Domain* (2006)" — with `https://arxiv.org/abs/cs/0703084` as its resource and
`https://hal.science/hal-00136664/document` as an "alternate host." **These are two different
papers.** arXiv `cs/0703084` is this ten-page IEEE-formatted AST 2001 workshop paper; the HAL
document is the 90-page HOSC 2006 journal article. They are not two hosts of one PDF. The manifest
correctly resolved them to two slugs from two distinct URLs
(`arxiv.org/pdf/cs/0703084` and a web.archive copy of `article-mine-HOSC06.pdf`), so the source
cache is right and only the plan's bibliography entry is wrong. It should be split into two
entries with the journal version marked as the citable one for the closure algorithms and their
proofs.

The PDF is arXiv `cs/0703084v2`, posted 16 March 2007 — an author reprint, six years after the
workshop. The venue string on the title page is only "École Normale Supérieure de Paris"; the AST
2001 / WCRE 2001 attribution comes from the journal version's reference list, not from this
document's own front matter, which is why the conflation was easy to make.

Typo in Fig. 5: the encoding of `vᵢ ≥ c` is printed as `v⁻ᵢ - v⁺ᵢ ≤ -2`, missing the `c`; the body
text two paragraphs later has it right as `-2c`. The strong closure algorithm in Fig. 8 indexes
`C⁺_{2k}` where the journal's Def. 2 indexes `C_{2k-1}`; this is a 0-based vs 1-based convention
difference, not a discrepancy in the algorithm. The paper also mixes `N` and `n` for the variable
count between the body and the conclusion.
