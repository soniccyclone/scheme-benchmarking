---
type: paper
title: "Iterated Register Coalescing"
description: Interleaves Chaitin-style simplification with Briggs-style conservative coalescing so that graph-coloring allocation removes far more copies without ever introducing a spill.
resource: knowledge/sources/george-appel-iterated-register-coalescing-toplas-1996.pdf
tags: [register-allocation, graph-coloring, coalescing, copy-propagation, cps]
authors: [Lal George, Andrew W. Appel]
year: 1996
venue: "TOPLAS 18(3), May 1996, pp. 300-324"
informs: [/techniques/register-allocation.md, /techniques/closure-conversion.md]
pipeline_stage: 12-regalloc
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

One idea, stated in a sentence: put `simplify` *before* `coalesce` and loop. Chaitin
coalesces recklessly and creates spills. Briggs coalesces conservatively (only when the
merged node has fewer than K significant-degree neighbors) and is safe but leaves most moves
behind. George and Appel observe that Briggs's test is applied to the *wrong graph* — run
simplification first and the degrees of the neighbors drop, so the same conservative test
now succeeds on nodes it previously rejected. Nothing about the safety argument changes.

The measured result on SML/NJ: conservative coalescing alone kills 24% of moves, biased
selection adds 39% more, leaving 37% in the program. Iterated coalescing leaves 16%. Code
size drops 5%, and execution time drops 4.4%, which is more than move-elimination should
buy and is credited to I-cache.

The paper also adds `freeze`, the phase that makes the loop terminate, and it kills the need
for biased coloring entirely.

# Mechanism

Five phases in a loop; the backward edge from coalesce to simplify is the contribution.

1. **Build.** Walk each block backward over `liveOut(b)`. For a move `d := s`, first remove
   `use(I)` from `live` so no artificial `s`-`d` interference is created, and register the
   move in `moveList[n]` for both operands and in `worklistMoves`. Then add edges from each
   `d ∈ def(I)` to everything in `live`. (The paper flags a bug in Briggs-Torczon's
   pseudocode here: they remove the *destination* from the live set instead of the source.)
2. **Simplify.** Pop a low-degree, *non-move-related* node, push on `selectStack`,
   decrement neighbors' degrees.
3. **Coalesce.** Briggs test on the reduced graph.
4. **Freeze.** If neither applies, take a low-degree move-related node and abandon its
   moves. It becomes non-move-related and simplification resumes. Freezes turn out to be
   rare, so the selection heuristic barely matters.
5. **Select.** Pop and color. No biased selection.

`Main` is: `LivenessAnalysis; Build; MkWorklist; repeat { Simplify | Coalesce | Freeze |
SelectSpill } until all four worklists empty; AssignColors; if spilled then RewriteProgram;
Main()`.

**Safety proof, in full.** Nodes removed during simplify are colored *after* everything left
in G′, so they cannot constrain colors in G′. Therefore conservative coalescing applied
inside G′ cannot affect G's colorability. That is the whole theorem — three sentences, and
it is why the technique is free.

**Two coalescing tests, not one.** `Conservative(nodes)` counts neighbors of degree ≥ K and
requires the count < K. That is Briggs. But machine registers are precolored with degree ∞
and enormous adjacency lists, so their adjacency lists are deliberately *not* materialized.
Coalescing a pseudo `v` into a precolored `u` therefore uses a per-neighbor test
`OK(t,u) = degree[t] < K ∨ t ∈ precolored ∨ (t,u) ∈ adjSet` applied to every `t ∈
Adjacent(v)`. Each condition means "merging cannot push `t` from insignificant to
significant." Condition 3 could be weakened to "fewer than K−1 significant neighbors" for
more aggressive coalescing at higher cost.

**Move states.** Every move sits in exactly one of `coalescedMoves`, `constrainedMoves`
(source and target now interfere — permanently dead as a coalescing candidate, and it stops
marking its nodes move-related), `frozenMoves`, `worklistMoves`, `activeMoves`. The
`active → worklist` transition (`EnableMoves`) fires when a neighbor's degree drops from K
to K−1, which is precisely the moment a previously-blocked coalesce might now pass.

**Data structures.** Adjacency lists plus a *hash table of integer pairs* for `adjSet`, not
a bit matrix. At n ≈ 4000 with average degree 16, the sparse table is 256KB against 1MB for
the half-matrix. `alias[]` with path-following `GetAlias` is a union-find in disguise. Four
worklists (`simplifyWorklist`, `worklistMoves`, `freezeWorklist`, `spillWorklist`) with
stated invariants keep every step O(1) amortized and avoid quadratic scanning.

**Spill interaction.** Compatible with either pessimistic or optimistic (Briggs) coloring.
Under pessimistic, no new spills, guaranteed. Under optimistic, no new *potential* spills;
actual spills may vary. If a spill happens, the simple variant discards all coalescings and
restarts — but the paper recommends keeping every coalesce found before the first
`SelectSpill`, which is provably safe and makes the rebuilt graph much smaller.

# Applicability

Preconditions: an interference graph from real liveness analysis, and K uniform registers.
Nothing about SSA is required, though SSA phi-elimination is one of the move sources it
exists to clean up.

Where it fails: it does nothing for compilers that already do copy propagation before
allocation or that generate few temporaries. The authors say this outright. The gain is
proportional to how freely earlier phases were allowed to emit moves.

The precolored-register story is the real constraint. SML/NJ can potentially precolor *all*
registers for parameter passing, which is why Chaitin's reckless coalescing is not merely
suboptimal for them but produces *uncolorable* graphs: a temporary interfering with K
distinct precolored nodes has nowhere to be fetched back into. Any compiler with a small
number of precolored nodes has an easier problem and will see a smaller win.

Cost: each round is linear, and the first simplify round removes so many nodes that
coalescing typically converges in one pass. Spilling forces a full rebuild.

# Relevance

Our stage 12 is specified as *linear scan*, not graph coloring, so this is not the allocator
we build. It matters for two other reasons.

First, the register-pressure profile is ours. Section 4 lists exactly the optimizations that
make allocation hard: known-call-site procedures with custom parameter temporaries, free
variables of nested functions passed in registers, representation analysis spreading an n-tuple
into n registers, callee-save closure analysis spreading context across registers. That is the
SML/NJ closure-conversion pipeline, close to what stage 08 plus closure conversion will do to
us. The finding to internalize: SML/NJ *regressed* going from three to six callee-save
registers until the allocator got good enough at copy propagation, then improved. If our
closure representation gets aggressive and performance goes the wrong way, coalescing quality
is the first thing to check, not the closure design.

Second, it sets the yardstick. If our allocator leaves more than ~16% of moves on closure-heavy
code, we are losing what a 1996 algorithm knew how to get, and the question becomes whether to
bolt coalescing onto linear scan (Wimmer-Franz covers the SSA variant) or accept it.
Burger-Waddell-Dybvig — what Chez actually does — builds no interference graph at all, so the
comparison between these two papers is the live design question for stage 12.

The `OK`/`Conservative` split transfers to linear scan with fixed register constraints too:
"does merging these two live ranges push any neighbor over K" is the same question regardless
of allocator shape.

# Notes

**Identity verified.** The bibliography flagged this one as filename-inferred. Page one
reads *"Iterated Register Coalescing"*, Lal George (Lucent Technologies, Bell Labs
Innovations) and Andrew W. Appel (Princeton), ACM copyright `0164-0925/96/0500-0300`, TOPLAS
Vol. 18 No. 3, May 1996, pages 300-324, received October 1995 / accepted February 1996. The
slug is correct in every particular. No correction needed.

The Section 8 comparison is weaker than the headline, and the authors say so. They do not
compare against Chaitin or published Briggs, because both produce uncolorable graphs on their
input. They compare against the *safe subset* of Briggs — one-round conservative coalescing
plus biased selection, reckless same-tag coalescing removed. So "84% vs 62%" is iterated
coalescing against a hobbled Briggs, on one compiler, on ML. Disclosed, but not a clean
head-to-head.

`nucleic` is the outlier showing where the technique strains: 701 spilled nodes against 0-24
for everything else, average machine-register degree 46. Heavy floating point with long
simultaneous live ranges is what coalescing cannot rescue, and it is close in shape to nbody
and spectralnorm. Note the speedup split too: `nucleic` and `ray` got 11% and 10%, the symbolic
benchmarks 2-3%.

Honest gap: they never measured compile time against Briggs, lacking his implementation. They
argue each round is linear like his and that his needs an extra round to coalesce with machine
registers. Plausible, unmeasured.
