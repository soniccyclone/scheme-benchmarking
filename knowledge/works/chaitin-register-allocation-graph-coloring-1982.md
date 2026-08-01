---
type: paper
title: "Retrospective: Register Allocation and Spilling via Graph Coloring (bundled with a facsimile reprint of \"Register Allocation & Spilling via Graph Coloring\", SIGPLAN '82)"
description: A one-page 2003 retrospective bound with a scanned reprint of Chaitin's 1982 paper, which folds spilling into the graph-coloring register allocator itself by making the simplify-stack algorithm choose a spill node on cost-over-degree whenever it blocks, then rebuild and repeat.
resource: knowledge/sources/chaitin-register-allocation-graph-coloring-1982.pdf
tags: [register-allocation, graph-coloring, spilling, coalescing, interference-graph, rematerialization]
authors: [Gregory J. Chaitin]
year: 2003
venue: "20 Years of the ACM/SIGPLAN Conference on PLDI (1979-1999): A Selection, 2003, pp. 66-74; reprint of SIGPLAN '82 Symposium on Compiler Construction, pp. 98-105"
informs: [/techniques/register-allocation.md, /techniques/liveness-analysis.md, /techniques/live-interval-analysis.md]
pipeline_stage: 12-regalloc
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-08-01T00:00:00Z" }
---

# Contribution

Read the `# Notes` section for the file's structure. The paper proper is the 1982 reprint.

The 1981 predecessor (Chaitin, Auslander, Chandra, Cocke, Hopkins, Markstein, *Computer
Languages* 6, reference (4) here) had already established graph coloring for allocation.
What it did badly was spilling: when the graph would not `k`-color, ad hoc heuristics chose
what to spill, producing poor code and consuming large amounts of compile time. This paper's
contribution is that spilling is *not a separate problem*. The same simplify-stack algorithm
that finds a coloring, when it blocks, deletes a node — and deleting a node from the graph
is exactly the decision to spill the computation it represents. Chaitin's own summary: "It is
not far from the truth to say that the algorithm for obtaining 32-colorings will either do
so or will modify the program and its graph until it can."

The paper also contributes three things that are less often credited to it: the two-pass
interference graph construction, the dual bit-matrix-plus-adjacency-vector representation,
and the observation that rematerializable values can have *negative* spill cost.

# Mechanism

Target is the IBM 801, 32 general-purpose registers, three-address register-to-register
instructions, separate load/store. Allocator sits between optimization and code emission,
and maps unboundedly many symbolic registers onto 32.

**Interference.** Nodes are symbolic registers. Two nodes interfere if one is live at a
definition point of the other. Note this is the definition-point formulation, not
"simultaneously live", and Chaitin says so explicitly.

**Representation, dual.** A symmetric `N × N` bit matrix, excellent for the random-access
query "do `i` and `j` interfere", plus one adjacency vector per node giving its neighbour
set, for sequential traversal. The matrix alone is too sparse to scan; the vectors alone
cannot answer the query. Construction is therefore two passes over the IL: pass one fills
the bit matrix and counts degrees, then the `N` adjacency vectors are allocated at exactly
their known lengths, then pass two fills them. He states this beats the one-pass segmented
scheme of (4) because non-segmented vectors process more simply and quickly.

**Coalescing (he calls it subsumption).** For each `copy` instruction whose source and target
do not interfere, merge the nodes; the copy becomes dead. Coalescing is done keeping the bit
matrix current and chaining the merged nodes' adjacency vectors, which leaves duplicate
entries in those vectors. Duplicates break the colorer, which infers degree from vector
length. So the fix is brutal and simple: rewrite the IL in terms of coalesced registers and
*re-run the whole two-pass graph build* on the shorter IL. Repeat until no further coalesces
are found. Two or three iterations in practice. The graph handed to the colorer is thus
"unspoilt by coalescing".

**Coloring, the simplify stack.** The observation: if `G` has a node `N` of degree `< k`,
then `G` is `k`-colorable iff `G \ N` is. So repeatedly remove nodes of degree `< 32`,
pushing them; this usually cascades until the graph is empty. Then pop, assigning each node
a color not used by its (already colored) neighbours. Linear time in the size of the graph.
Chaitin is clear that a real NP-complete `k`-coloring algorithm "is of course out of the
question" and that this heuristic is what makes it practical.

**Spilling, the whole point.** The algorithm blocks only when every remaining node has
degree `≥ 32`. Then pick a node to spill, delete it from the graph, and continue; the
deletion typically cascades new low-degree nodes into range. Spilling a node is *not* the
same as removing it, because the value still needs a store at each definition and a load at
each use, and those short live ranges are new nodes. Doing that exactly would mean replacing
one globally live node with several momentarily live ones, which he judges too expensive.
So: make all spill decisions, then insert spill code, then *rebuild the interference graph
from scratch* and re-attempt. Usually succeeds second time; occasionally loops again.
Convergence is rapid, and compile time is dominated by the first graph build since every
subsequent graph is substantially smaller.

**The spill choice.** Minimize `cost(node) / degree(node)` among remaining nodes. Cost is
the estimated execution-time increase from spilling: number of definitions plus number of
uses, each weighted by estimated execution frequency, under the model that every instruction
is one cycle and a loop body executes ten times more than the same code outside. Three
refinements:

- Some computations can be *recomputed* instead of spilled and reloaded. (Rematerialization,
  in one sentence, in 1982.)
- If the source or target of a copy is spilled, the copy disappears. Combined with the
  previous point, a rematerializable value used as a copy source "can have negative cost".
- Locality patch: if a spilled value has several uses in one basic block and nothing goes
  dead between the first and last use, load once before the first use and keep it in the
  register. And if a computation is local to a basic block with nothing going dead between
  its definition and last use, spilling it *cannot* help make the program colorable, so its
  cost is set to infinity. That second clause also prevents the allocator from re-spilling
  what it has already spilled, which is what stops the outer loop from diverging.

**Driver.**

    read il; read colors
    if color_il() fails:
        estimate_spill_costs
        decide_spills
        insert_spill_code
        color_il

    color_il = build_graph; coalesce_nodes; color_graph; rewrite_il

# Applicability

Whole-procedure. Needs global liveness from ordinary dataflow analysis, delivered in a
specific IL shape: each basic block header pseudo-op carries the registers live on entry,
and every operand of every instruction carries a `dead` bit saying whether that reference is
the last. The graph builder is a single linear scan over that IL maintaining a liveness
multiset, which is why the `dead` bits are worth the IL complexity.

Costs, stated honestly in the conclusions: register allocation including spilling now takes
compile time "comparable with the more traditional optimization algorithms", but "a fair
amount of virtual storage is needed to hold the program IL and interference graph in core."
The `N × N` bit matrix is the reason, and it is quadratic in symbolic register count.

Known limits the paper does not address: coalescing is unconstrained, so it can raise degree
and force spills that would not otherwise occur — the problem George and Appel's iterated
coalescing solves fourteen years later. There is no split/live-range-splitting alternative to
spilling. Spill cost estimation uses a static ten-per-loop-level model, not profile data.

# Relevance

Stage 12. This is the baseline every later allocator in our bundle is measured against:
Briggs's optimistic coloring, George and Appel's iterated coalescing, Poletto and Sarkar's
linear scan, Wimmer and Franz's SSA linear scan, and Burger-Waddell-Dybvig's Chez allocator
all cite or react to this construction.

Two mechanisms transfer directly regardless of which allocator we build. The dual
representation is the right answer to "I need both an interference query and a neighbour
iteration" and there is no cleverer one; take it as given. And the infinite-cost rule for
block-local values with no deaths in between is a correctness-adjacent guard, not a
heuristic: it is what makes the spill-insert-rebuild loop terminate. Any allocator that
iterates spill insertion needs an equivalent, or it can loop forever spilling what it just
spilled.

The negative-cost observation is the one to actually chase for a Scheme compiler. Our
constants, immediates, closure-pointer derefs, and global-variable addresses are all
rematerializable, and rematerializing an argument to a `move` costs strictly less than
nothing. Chez already does the adjacent thing; this is the citation for why.

Take the pessimistic-coloring caveat as read. Chaitin spills as soon as the graph blocks;
Briggs later showed that pushing the blocked node onto the stack anyway and only spilling if
no color is available at pop time is strictly better, because a node of degree `≥ k` may
still have `< k` *distinct* colors among its neighbours. If we build Chaitin-style, build
Briggs-style.

# Notes

**File structure, since the assignment asked.** Nine PDF pages, footer-paginated 66-74
within the reprint volume.

- **PDF page 1 (printed p. 66): the 2003 retrospective.** Born-digital, single page, signed
  Gregory Chaitin, IBM T. J. Watson. Content is historical: the 801 project under John
  Cocke, everyone in one room, hardware and software co-evolving, register allocation redone
  many times. Two substantive claims. First, that the register allocator fed back into the
  *architecture*: instructions were omitted from the 801 because they would have complicated
  allocation, and the register file was enlarged from 16 to 32 once the scheme proved out.
  Second, his framing of the contribution: "spill decisions were made globally, not locally,
  in order to transform the register interference graph into one that could be colored,"
  which he calls "a triumph of the power of a simple mathematical idea over ad hoc hacking."
  Points at the sibling papers in the same volume (Auslander and Hopkins on the PL.8
  compiler, Markstein-Cocke-Markstein on range checking, Chow and Hennessy, and Briggs et
  al.). No technical content beyond that.
- **PDF pages 2-9 (printed pp. 67-74): the original 1982 paper**, as a 300 dpi CCITT-G4
  scan with no text layer. Original pagination is recoverable from the copyright block,
  `© 1982 ACM 0-89791-074-5/82/006/0098 $00.75`, so pp. 98-105 of the SIGPLAN '82 Symposium
  on Compiler Construction proceedings. Sections: 1 Introduction, 2 Overview of Register
  Allocation, 3 The Interference Graph, 4 Subsumption, 5 Spilling, 6 Conclusions,
  References, then **two** appendices — an executable SETL specification of the entire
  allocator, and a PL/I declaration of the IL structure with a `register_rename` procedure
  showing how renaming walks it.

This document was produced by OCR (tesseract via ocrmypdf) plus direct visual inspection of
the pages where the OCR was doubtful. Two OCR artifacts worth recording so nobody repeats
the check: the section heading "5. SPILLING." reads as "3." in the extracted text (verified
visually as 5, so the original is *not* misnumbered), and the SETL set-theoretic operators
are unreliable throughout.

**A real discrepancy between the prose and the SETL appendix.** Section 5 says the blocked
colorer spills the node minimizing `cost / degree`. The `decide_spills` procedure in the
SETL appendix does not divide:

    node := arb { x ∈ n | cost(x) = min/ { cost(y) : y ∈ n } }

Plain minimum cost, degree ignored. Likewise `estimate_spill_costs` in the appendix is just
the sum of block frequency over definition and use occurrences, with none of the
rematerialization, copy-elision, or infinite-cost-for-block-local refinements the prose
describes. The appendix is a simplified outline ("outlines in executable form the main
ideas"), not the shipped allocator. Implement from the prose; the appendix is a skeleton,
and the cost-over-degree ratio is the part everyone cites.

**Title and author, exactly as printed on the reprint:** "REGISTER ALLOCATION & SPILLING VIA
GRAPH COLORING", G. J. Chaitin, IBM Research, P.O. Box 218, Yorktown Heights. Single author.
The five co-authors people sometimes attach to this paper belong to reference (4), the 1981
*Computer Languages* paper, which is a different work and is not in this bundle.

**Dated in one specific way.** The whole design assumes the interference graph fits in core
and that graph construction dominates compile time, which is why the rebuild-everything
strategy (three times for coalescing, again after every spill round) is acceptable. On a
modern JIT budget it is not, and that is the pressure that produced linear scan. The
allocation *quality* argument has never been beaten; the compile-time argument has.
