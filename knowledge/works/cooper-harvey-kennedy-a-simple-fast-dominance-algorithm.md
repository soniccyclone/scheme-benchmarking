---
type: paper
title: "A Simple, Fast Dominance Algorithm"
description: Shows that an iterative dataflow solver for dominance, with the Dom sets represented implicitly as the dominator tree, beats Lengauer-Tarjan on real control-flow graphs, and rederives a faster dominance-frontier algorithm from the same representation.
resource: knowledge/sources/cooper-harvey-kennedy-a-simple-fast-dominance-algorithm.pdf
tags: [dominance, dominator-tree, dominance-frontier, ssa-construction, dataflow-analysis]
authors: [Keith D. Cooper, Timothy J. Harvey, Ken Kennedy]
year: 2001
venue: "Rice University Computer Science TR-06-33870"
informs: [/techniques/ssa-construction.md, /techniques/dataflow-analysis.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

No new algorithm. The claim is an engineering one, backed by measurement: the classic
iterative formulation of dominance, given the right data structure, runs about 2.5x faster
than Lengauer-Tarjan on the control-flow graphs a compiler actually sees, and the two are
roughly equal at 30,000 nodes, which is forty times larger than the biggest CFG in the
authors' SPEC-derived Fortran suite. The asymptotic advantage of union-find never pays for
itself at realistic sizes. A second contribution, credited back to Ferrante, Ottenstein and
Warren's control-dependence work, is a dominance-frontier algorithm that walks up from join
points rather than down from the dominator tree, and beats the Cytron et al. formulation by
25 to 33 percent.

The paper is also a small piece of citation archaeology. It documents that Aho and Ullman's
dragon book credits the iterative dominance algorithm to Purdom and Moore when it belongs to
Allen and Cocke, and that Buchsbaum et al.'s asymptotically better algorithm runs ten to
twenty percent *slower* than the Lengauer-Tarjan it improves on.

# Mechanism

The dataflow equations are the obvious ones over a distributive, rapid framework:

    Dom(n0) = {n0}
    Dom(n)  = ({ intersect over p in preds(n) of Dom(p) }) union {n}

Solved in reverse postorder, this halts in at most d(G) + 3 passes, where d(G) is loop
connectedness. Knuth measured d(G) <= 3 for typical CFGs; the authors' own suite averages
1.11.

The naive bit-vector implementation is 900x slower than Lengauer-Tarjan, and SparseSets are
worse because of memory. The fix is the whole paper. Observe that for every node but the
entry,

    Dom(b) = {b} union IDom(b) union IDom(IDom(b)) ... union {n0}

so an ordered Dom set is exactly the root-to-b path in the dominator tree. Therefore do not
store sets. Store one array `doms[]`, indexed by node, where `doms[b]` holds IDom(b).
Walking `doms` from b reconstructs both the tree path and the Dom set. Intersection becomes
a two-finger walk toward the root:

    function intersect(b1, b2)
      finger1 <- b1; finger2 <- b2
      while finger1 != finger2
        while finger1 < finger2: finger1 <- doms[finger1]
        while finger2 < finger1: finger2 <- doms[finger2]
      return finger1

Comparisons are on postorder numbers, so nodes higher in the dominator tree have higher
numbers, and the finger with the smaller number moves. The main loop initializes
`doms[start] <- start`, all others undefined, then iterates in reverse postorder: pick the
first already-processed predecessor as `new_idom`, fold `intersect` over the remaining
processed predecessors, and record. Repeat until nothing changes.

Cost per iteration is O(N + E*D) with D the largest Dom set. The win is not asymptotic: it
is the elimination of allocation, initialization, copying, and set representation. IDom
falls out for free, which fixes the standard complaint that iterative formulations give you
Dom but not IDom.

Dominance frontiers, in five lines:

    for all nodes b with >= 2 predecessors
      for all predecessors p of b
        runner <- p
        while runner != doms[b]
          add b to DF(runner)
          runner <- doms[runner]

Every node with two or more in-edges is a join point; walk up the dominator tree from each
predecessor and stop at the join's immediate dominator. Work is exactly the sum of the sizes
of all DF sets, which is optimal in the sense that the sets cannot be built with fewer
touches. Duplicate suppression needs a side SparseSet since the implementation uses linked
lists for the DF sets.

# Applicability

Needs a reverse-postorder numbering, so a DFS, so O(N) preprocessing. Correctness is
independent of reducibility, but running time is not: on an irreducible graph, d(G) depends
on which spanning tree the DFS produced, so traversal order changes the pass count.
Lengauer-Tarjan always takes two passes regardless of shape, which is why the crossover
exists at all.

The measured crossover is around 30,000 nodes for the dominance computation alone, and the
frontier algorithm is faster at every size measured, so the combined cost is still about 12
percent better even on the 30,000-node random graphs. The random-graph generator produced
d(G) slightly over 3 against 1.11 for real code, which biases the experiment *against* the
iterative algorithm, so the crossover on real code is further out than reported.

The honest caveat the authors state themselves: on real programs both algorithms are so fast
that the choice does not affect compile time. The largest CFG in their suite (744 blocks,
from `field`) registered one hundredth of a second. The argument for the iterative scheme is
therefore simplicity and confidence in correctness, with speed as a bonus.

Postdominance is the same code on the reversed CFG, and irreducibility is markedly more
common there, since a jump out of the middle of a loop becomes a jump into one when edges
are reversed. If we compute control dependence, expect the irreducible cases to show up in
the reverse problem, not the forward one.

# Relevance

We need dominators for SSA construction and for anything downstream that reasons about
placement (loop recognition in `07-loops`, code motion, safety of speculative hoisting).
This is the version to implement. It is about forty lines of Scheme, it produces the
dominator tree directly rather than as a post-pass, and there is no union-find to get wrong.

The `doms` array is also the right representation to keep resident. Dominator-tree ancestry
queries reduce to the same two-finger walk, and "does a dominate b" is a walk from b that
stops when the postorder number exceeds a's. That covers the queries the interval and
pentagon domains need when deciding whether a fact established on one edge is valid at a
later program point.

If we adopt Braun et al.'s on-the-fly SSA construction, we may not need dominance frontiers
at all for phi placement. Keep this algorithm anyway: dominators themselves are needed
regardless, and the frontier routine is five lines on top of what we already have.

# Notes

The PDF's title page carries no date and no venue beyond "Rice Computer Science
TR-06-33870". The bibliography's description ("prerequisite for SSA construction. Title
confirmed") is accurate, and the title is exactly as printed. The commonly cited date is
2001, which is consistent with the newest reference in the bibliography (Allen and Kennedy's
book, 2001); the "06" in the TR number reflects a later deposit into the Rice repository,
not the year of writing. Record 2001 but treat the year as inferred, not printed.

Two errors in the historical record that the paper corrects, both worth carrying forward
because they propagate into other bibliographies: the iterative dominance algorithm is Allen
and Cocke 1972, not Purdom and Moore 1972 as Aho and Ullman have it; and the
dominance-frontier-by-upward-walk algorithm first appeared in Ferrante, Ottenstein and
Warren 1987 in the guise of control dependence, not in this paper.

The experimental method is worth imitating and worth criticizing. Taking the *minimum* of
ten runs rather than the mean is correct for deterministic algorithms and stated as such.
Running each graph 10,000 times to get above the timer's one-hundredth-of-a-second
granularity is honest but means the measurements are all warm-cache; the real-world cost,
where the CFG is touched once, will favor whichever algorithm has the smaller working set,
and that comparison is not made.
