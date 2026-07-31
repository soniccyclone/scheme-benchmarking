---
type: book
title: "SSA-based Compiler Design"
description: Edited 24-chapter volume covering SSA construction, its analysis flavors (SSI, gated, psi, hashed, array), and its use through machine code generation, SSA destruction, and register allocation.
resource: knowledge/sources/rastello-et-al-ssa-based-compiler-design-the-ssa-book.pdf
tags: [ssa-form, register-allocation, sparse-dataflow, ssa-destruction, code-generation, liveness]
authors: [Fabrice Rastello, et al.]
year: 2018
venue: "Springer, unpublished draft dated 8 June 2018"
informs:
  - /techniques/ssa-construction.md
  - /techniques/ssa-destruction.md
  - /techniques/register-allocation.md
  - /techniques/liveness-analysis.md
  - /techniques/dataflow-analysis.md
  - /techniques/bounds-check-elimination.md
  - /techniques/loop-analysis.md
  - /techniques/partial-redundancy-elimination.md
  - /techniques/instruction-selection.md
pipeline_stage: 12-regalloc
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Not a paper with a result. It consolidates twenty years of SSA engineering into one argument: SSA
is not a middle-end convenience you destroy before the back end, it is a structural property worth
carrying as deep as register allocation, because the structure buys exact algorithms where the
general problem is NP-complete. The through-line is one theorem. Under *strict* SSA (every use
dominated by its definition) every live range is a subtree of the dominator tree; therefore the
interference graph is chordal; therefore greedy coloring is exact, `Maxlive` is the exact register
requirement, and the spill test stops being a heuristic. All of Part IV descends from that. The
rest is the accounting of what it costs to get there on real machine code, which is where most SSA
literature stops and this book keeps going.

# Mechanism

**Construction (ch. 3-4).** Two phases. φ placement at `DF+(Defs(v))`, where `DF(x)` is computed
by walking, for each CFG edge `(a,b)`, from `a` up the idom chain adding `b` to `DF` until you
reach a strict dominator of `b`; iterate with a worklist and an inserted-flag set. Renaming is a
dominator-tree DFS with a per-variable `reachingDef` slot rather than the classical stack — same
result, reuses an existing scratch field, and `updateReachingDef` walks the `reachingDef` chain
until it finds a definition that dominates the current instruction. Three faster DF+ schemes are
given: Sreedhar-Gao DJ-graphs (visit nodes deepest-first, peek at J-edges with
`z.depth <= current.depth`, never revisit a subtree); a top-down data-flow formulation with an
inconsistency check driving re-iteration; and Ramalingam's loop-nesting-forest identity
`DF+(S) = HLC(S) ∪ DF+_fwd(S ∪ HLC(S))`, where `HLC` is the set of headers of loops containing
`S` and `DF+_fwd` runs on the back-edge-free CFG. Two field observations worth more than the
algorithms: minimality is never actually required by any optimization, and in production compilers
renaming, not φ placement, is the expensive phase.

Flavors are the vocabulary the rest of the book uses: *minimal*, *pruned* (suppress dead φ,
equivalently run DCE after), *semi-pruned* (filter block-local variables first — usually the
right cost/benefit point), *strict* (dominance property), and *conventional* vs *transformed*
(whether the φ-web is interference-free). Copy propagation is what turns conventional into
transformed, and that is the whole difficulty of destruction.

**Reconstruction (ch. 5).** When spilling or jump threading breaks SSA, do not rebuild. Two
repair drivers sharing `FindDefFromBottom`/`FindDefFromTop`: a DF+-based one, and a search-based
one (Braun/Click) that walks predecessors depth-first, plants a `pending_φ` before recursing to
break cycles, then deletes it if all reaching definitions agree. The second needs no dominance
information at all, so it survives passes that rewrite control flow; it only guarantees minimality
on reducible graphs.

**Destruction (ch. 21).** The chapter that changes how you would implement this. Naive
"replace φ with copies in predecessors" is wrong — lost-copy and swap. The fix is to isolate the
φ by inserting parallel copies on *both* sides: one per argument at the end of each predecessor,
and one for the result at the top of the block. Isolating the result is what removes the
requirement to split critical edges, which matters because some edges cannot be split
(abnormal edges, region boundaries, PowerPC `bclr`-style branch-with-decrement where the counter
is defined by the branch itself). Machine constraints are normalized by rewriting *operand*
pinning into *live-range* pinning (wrap the operation in parallel copies to/from pre-colored
temporaries), then `pin-φ-webs` are found by union-find over φ arguments and shared physical
resources; any interference surviving inside a web is a *strong* interference that copy insertion
cannot fix and must be reported, not papered over.

Then the copies are removed by aggressive coalescing, and the enabling trick is value-based
interference. Under strict SSA "has-the-same-value" is an equivalence relation, computed in one
dominance-order traversal by folding copies (`V(b) = V(a)` for `b <- a`, else `V(b) = b`). So

    interfere(a,b)  ⟺  intersect(a,b) ∧ V(a) ≠ V(b)

and `intersect` reduces, again by the subtree property, to "one definition dominates the other
and the dominated definition point is inside the other's live range" — answerable by a liveness
*check* query with no liveness sets and no interference graph. Coalescing then becomes
de-coalescing: optimistically merge everything copy-related, then traverse each merged set once
in dominance pre-order maintaining `idom` and `eanc` (nearest intersecting dominator of equal
value) links, evicting on conflict. Copies are *virtualized* — the φ itself is the placeholder for
its local variables, and only the copies that survive de-coalescing are ever materialized. That is
what makes this affordable for a JIT. Final parallel copies are sequentialized by the
windmill-farm traversal (Alg. 21.6): emit copies whose destination is not a pending source, and
break each remaining cycle with exactly one extra temporary.

**Register allocation (ch. 22).** Decouple. Phase 1 lowers `Maxlive` to `R` by spilling; phase 2
assigns, and is guaranteed to succeed. Assignment is either the unmodified graph-coloring
simplify scheme (which on a chordal graph never gets stuck) or *tree scan* (Alg. 22.1): walk the
dominance tree, free colors at last uses, pick any free color at each definition — at a definition
at most `Maxlive - 1` other variables are live, so a color always exists. Linear scan is this
algorithm with the tree flattened into an interval, which is exactly why it over-approximates live
ranges and spills variables it did not need to.

Spilling is where the judgement lives. In-block, furthest-first (Belady) is near-optimal. Across a
CFG, "distance to next use" is replaced by
`spill_profitability(v,p) = Σ_{q ∈ v.HP(p)} freq(q)` where `v.HP(p)` is the set of program points
where `v` is live, register pressure exceeds `R`, and some path from `p` reaches `q` with no
intervening use or definition of `v`. That single change makes the allocator prefer spilling a
variable across a hot loop it is not used in over one whose next use is inside the loop. Block-entry
register sets are seeded from `∩ preds.in_regs` and topped up from `∪ preds.in_regs` by
profitability; loop headers are seeded from scratch instead, capped at
`R + |livein| - L.Maxlive`, so live-through variables that must die anyway die before the loop
rather than at every iteration. Coalescing after allocation uses Briggs and George conservatively,
plus a "brute" rule that simply re-runs `Simplify` to test whether a merge breaks
greedy-`R`-colorability — more expensive per query, but it removes the IRC's freeze/unfreeze
machinery and coalesces more.

**Value range and relational analysis on SSA (ch. 8, 13).** Ch. 8 is the sparse propagation engine:
Wegman-Zadeck SCCP generalized to any monotone lattice, two worklists (CFG edges marked
executable, SSA def-use edges), `O(|E_SSA|·h + |E_CFG|)`. Ch. 13 is the chapter that matters for
bounds checks. It formalizes when a sparse analysis is legal — *Partitioned Lattice per Variable*,
`L = L_v1 × ... × L_vn` — and states the Static Single Information property as four conditions
(Split, Info, Link, Version) under which analysis facts can be attached to *variables* instead of
(variable, program point) pairs. Vanilla SSA satisfies SSI only for analyses that take information
at definitions. Range analysis takes information at conditional branches too, so it needs extra
splitting: σ-functions at branch exits (the dual of φ, one new name per successor), parallel copies
at interior nodes, and the split set computed by `DF+` forward plus *iterated post-dominance
frontier* `pDF+` backward. The book tabulates the splitting strategy per client, and the row for
ABCD, taint analysis, and range analysis is `Defs↓ ∪ Out(Conds)↓` — which is precisely Bodík's
e-SSA. Construction is `split`, `rename`, `clean` (the last one prunes σ/φ/copies not connected to
a real definition and a real use, in two worklist passes over def-use and use-def chains).

Liveness (ch. 9) needs no fixpoint: post-order over the back-edge-free CFG, then push loop-header
live sets down the loop nesting forest, with irreducibility handled by redirecting each edge `s→t`
to `t.OLE(s)` (outermost loop excluding) on the fly rather than transforming the graph. The
liveness *check* query system built from `OLE` plus modified-forward reachability is precomputed
per-CFG and therefore stays valid as variables are added and deleted. Induction variables (ch. 10)
come from strongly connected components of the SSA graph, translated into chains of recurrences
`{base,+,step}_x` with symbolic steps instantiated in a second phase; trip count is the minimal
integer solution of a Diophantine inequality, and `φ_exit` applied to it gives the exit value.

# Applicability

The central theorem needs *strict* SSA with φ functions still present. Copy propagation destroys
conventionality; SSA destruction destroys the subtree property outright. So the ordering is forced:
allocate registers before you destroy SSA, or you get chordality for nothing. Reducibility is
assumed by several algorithms (loop-nesting-forest DF+, two-pass liveness, chains of recurrences)
but each comes with an irreducible variant that costs one extra concept, not an exponential blowup.

`Maxlive ≤ R` is sufficient only under an idealized machine. The book is unusually honest that the
gap to a real ISA is where implementations die: two-address instructions, ABI-pinned operands,
register aliasing/pairing for vector registers, operands that cannot be memory (so spilling leaves
"chads" of live range around each use rather than deleting a node), and non-splittable abnormal
edges. Ch. 18 catalogues the same problem for the IR itself — φ over a status register with
independent sticky bit-fields is not a killing definition, so it does not belong in SSA at all
without coarsening.

Sparse propagation over the SSA graph is forward-only and def-use-only. Problems whose facts
change at points that neither define nor use the variable (available expressions is the stated
example) cannot be modelled; ch. 13 is the answer, at the cost of more names.

Cost profile: the naive C-SSA path (materialize all copies, build liveness sets, build an
interference graph, coalesce) is correct and simple and unaffordable in a JIT. The virtualized
path in ch. 21 gets the same output with no interference graph and no liveness sets.

# Relevance

Chapter 6 is the bridge for us and is the chapter to read first. It establishes the correspondence
table — let-binding ≡ assignment, α-renaming ≡ variable renaming, formal parameter of a local
function ≡ φ, lexical scope ≡ dominance region, function nesting ≡ dominator tree — and then shows
that constructing minimal SSA from a naive functional encoding is exactly λ-dropping: *block
sinking* (nest each function inside its dominator, placed near its call sites) followed by
*parameter dropping* (delete a parameter whose binding at the declaration site coincides with the
binding at every call site). Our nanopass IR is already in this form. That means we do not
implement chapters 3-5 at all; we implement the inverse reading of chapter 6, and the φ we cannot
drop is exactly a loop-carried value. The loop-closed-SSA discipline in 6.2.3 (place a function at
the *head* of the loop it exits so its parameter survives dropping) is what stages 7 and 10 need to
name a loop's exit value.

For stages 5 and 6 the operative result is that vanilla SSA is the wrong form. Interval and Pentagon
refinement happens at `(i < n)?`, not at `i`'s definition, so a def-only SSA gives one lattice
element per variable for the whole live range and loses the branch. Chapter 13's
`Defs↓ ∪ Out(Conds)↓` with σ-functions is the minimum extension and is the same form ABCD assumes:
if we move to SSA in order to run ABCD, go to e-SSA directly. Budget for `clean` as well —
σ-splitting inflates the name space and dead/undefined elimination is what keeps it affordable.

For stage 12, this book contradicts the CUJ's baseline. The CUJ documents linear scan with graph
coloring as "the better answer"; chapter 22 says the choice is false, that tree scan dominates
linear scan on every axis (simpler, same memory profile, exact instead of over-approximating), and
that on SSA input the classical simplify scheme is already exact so the two converge. Our spill
criterion in the CUJ — "if any unboxed f64 spills across the loop body the allocator is erasing the
analysis" — is precisely what `spill_profitability` is designed to prevent, and the loop-header
`in_regs` rule (Alg. 22.4) is the piece that stops a live-through unboxed float being reloaded
every iteration. Our two register files are independent chordal problems, so tree scan runs twice
with different `R`.

Chapter 21 is the one to read before writing any φ lowering. If we ever destroy SSA — and we will,
before scheduling and before emission — value-based interference plus virtualized copies is the
difference between clean code and a function full of register-to-register moves that nothing later
removes.

Chapter 11's register promotion framing (load PRE, then store PRE over SSU with σ-functions) is a
cheaper route to stage 8's goals than a bespoke pass. Chapter 19 (PBQP instruction selection over
SSA graphs, handling multi-result and DAG patterns tree matching cannot express) touches stage 11
but is the one chapter whose cost/benefit looks bad for us. Chapters 15, 16, 17, 20, 23 and 24 are
context, not implementation.

# Notes

**This PDF is not the published book, and the slug and plan should say so.** It is an unfinished
draft dated 8 June 2018. The title page literally reads "Lots of authors / Static Single Assignment
Book"; the title *SSA-based Compiler Design* and the author string "Fabrice Rastello et al." come
only from the PDF metadata. The dedication page is Lorem-ipsum ("To be filled with the actual
beginning of the book..."), the Foreword is one line ("Author: Zadeck"), and the Preface is
"TODO: Roadmap". The plan's bibliography entry is not wrong about what the work is, but a
`works/` document that cites page numbers or section numbers from this file will not match the 2022
Springer edition. **Recommend the bibliography record the version explicitly as a preprint.**

Draft artifacts a reader will hit: chapter 16's Further Readings is an unwritten stub ("Cite the
original paper from Zhou et al.", "Cite work done in the GCC compiler"); chapter 10 has two figures
that failed to render ("Warning: Low quality figure! Please compile with tikz", "TODO: Missing
figure!") in the middle of the induction-variable stride-detection walkthrough, which is exactly
where the figure was load-bearing; chapters 7 and 12 are bullet outlines prefixed "TODO: refine
following key points" rather than prose; several cross-references print as "Chapter ??"; there are
untranslated editorial notes from the authors to each other, including a French one in ch. 8
("flo: reprendre en disant que justement, c'est une misconception") and "TODO: ask Fabrice which
reference he was talking about" in ch. 22's further reading. The algorithms and pseudocode are
finished and trustworthy; the scaffolding around them is not.

That French note is substantive, not cosmetic. Section 8.2.4 asserts flatly that SSA graphs cannot
model backward data-flow problems, and the marginal note is one author telling another that this
framing is a misconception. Chapter 13 then contradicts 8.2.4 directly by building backward sparse
analyses on SSI. Read 8.2.4 as "vanilla SSA cannot", not "SSA cannot".

Two claims are stated more confidently than the evidence supports. Section 18.2.3 argues pre-pass
instruction scheduling gains nothing from SSA and should run on destroyed, coalesced code; the
reasoning is sound (φ add nothing in single-entry regions, def-use ordering is wrong for sticky
status bits, move renaming and inductive relaxation want to *relax* flow dependences) but it is one
team's ST200/LAO experience presented as settled. And the recurring claim that a decoupled
allocator "will not require more spilling" holds only on the idealized machine; §22.4 concedes that
register constraints, pairing, and memory-operand restrictions can force extra spills.

The provenance is worth knowing. Gavril proved in 1974 that intersection graphs of subtrees are
exactly the chordal graphs; the SSA register allocation result is that theorem plus the observation
that strict-SSA live ranges are dominator subtrees. Several groups rediscovered it independently
around 2005, and LaTTe was shipping a tree-scan allocator in the 1990s without the theory. The hard
problem was never coloring — it is coalescing away the copies live-range splitting introduces,
which is why chapters 21 and 22 are the longest in Part IV.

Chapter author bylines, since the title page has none: J. Singer, P. Brisk, F. Rastello, D. Das,
U. Ramakrishna, V. Sreedhar, S. Hack, L. Beringer, M. Schordan, F. Brandner, D. Novillo,
B. Boissinot, S. Pop, A. Cohen, F. Chow, V. Sarkar, F. Pereira, J. Stanier, F. de Ferrière,
M. Mantione, K. Knobe, S. Fink, B. Dupont de Dinechin, D. Ebner, A. Krall, B. Scholz, C. Bruel,
F. Bouchez, P. C. Diniz, P. Biggar, D. Gregg.
