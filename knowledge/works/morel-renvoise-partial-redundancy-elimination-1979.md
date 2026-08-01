---
type: paper
title: "Global Optimization by Suppression of Partial Redundancies"
description: Shows that global CSE and loop-invariant code motion are both special cases of eliminating computations redundant on only some paths, and gives a purely Boolean, bidirectional bit-vector algorithm that does all three at once with no control-flow analysis and no restriction on graph shape.
resource: knowledge/sources/morel-renvoise-partial-redundancy-elimination-1979.pdf
tags: [partial-redundancy-elimination, code-motion, dataflow-analysis, bit-vector, loop-invariant]
authors: [E. Morel, C. Renvoise]
year: 1979
venue: "Communications of the ACM 22(2), February 1979, pp. 96-103"
informs: [/techniques/partial-redundancy-elimination.md, /techniques/dataflow-analysis.md, /techniques/loop-analysis.md]
pipeline_stage: 08-represent
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-08-01T00:00:00Z" }
---

# Contribution

Two claims, and the second is the one that made the paper famous.

First, that redundancy elimination and loop-invariant motion are not two optimizations but
one. A loop-invariant computation *is* partially redundant: if the expression is transparent
throughout the loop, any block in the loop containing a computation has `TRANSP = TRUE`,
hence `ANTLOC = COMP = TRUE`, hence `PAVOUT = TRUE`, and the cycle back through the loop
makes `PAVIN = TRUE` at that same block, which is the definition of partial redundancy. The
paper proves this in two paragraphs. A fully redundant computation is trivially partially
redundant. So one algorithm subsumes both classical passes.

Second, that the algorithm can be *nongraphical*. No intervals, no dominators, no loop
identification, no restriction to reducible or single-entry graphs. Loops get optimized
because the Boolean system's fixpoint discovers them, not because a preliminary pass found
them. The practical payoff they measure is a 7200-line optimizer replaced by 2500 lines, of
which 800 lines are the analysis proper, running 30 to 60 percent faster.

# Mechanism

**Program model.** Basic blocks; assignments split so each expression is a binary operation
assigned to a temporary. Four local Boolean properties per (expression, block):

- `TRANSP_i` — no command in `i` modifies the expression's operands.
- `COMP_i` — locally available: the expression is computed in `i` and its operands are not
  modified after the last such computation.
- `ANTLOC_i` — locally anticipable: computed in `i`, operands not modified before the first
  such computation.

**Three global systems**, all solved by direct iteration, all bit-vectored 32 expressions at
a time on a 32-bit word:

    AVIN_i   = FALSE if entry, else ∏_{j ∈ Pred(i)} AVOUT_j
    AVOUT_i  = COMP_i + TRANSP_i · AVIN_i            # largest solution, init TRUE

    ANTOUT_i = FALSE if exit, else ∏_{j ∈ Succ(i)} ANTIN_j
    ANTIN_i  = ANTLOC_i + TRANSP_i · ANTOUT_i        # largest solution, init TRUE

    PAVIN_i  = FALSE if entry, else Σ_{j ∈ Pred(i)} PAVOUT_j
    PAVOUT_i = COMP_i + TRANSP_i · PAVIN_i           # smallest solution, init FALSE

Availability and anticipability take the largest solution (conjunctive system, initialize
all TRUE); partial availability takes the smallest (disjunctive, initialize FALSE). A
computation in `i` is partially redundant iff `ANTLOC_i · PAVIN_i`.

**The placement system.** Define a constant term

    CONST_i = ANTIN_i · [ PAVIN_i + (¬ANTLOC_i) · TRANSP_i ]

true for blocks containing a partial redundancy and for blocks empty with respect to the
expression where it can still be anticipated. Then

    PPIN_i  = FALSE if entry, else
              CONST_i · ∏_{j ∈ Pred(i)} (PPOUT_j + AVOUT_j) · (ANTLOC_i + TRANSP_i · PPOUT_i)
    PPOUT_i = FALSE if exit, else ∏_{k ∈ Succ(i)} PPIN_k

Note the `TRANSP_i · PPOUT_i` term inside `PPIN_i`: `PPIN` depends on `PPOUT` of the *same*
block, which depends on `PPIN` of successors. That is what makes the system bidirectional,
and it is the structural feature the whole subsequent literature spent fifteen years
removing. Largest solution, initialized all TRUE; in practice they initialize `PPIN_i` to
`CONST_i`, which is an upper bound of the solution, and never observe more than three
iterations.

**Insertion and deletion.**

    INSERT_i = PPOUT_i · ¬AVOUT_i · (¬PPIN_i + ¬TRANSP_i)

Insert a computation at the exit of every block with `INSERT = TRUE`; delete the first
computation in every block with `ANTLOC_i · PPIN_i = TRUE`.

**The proof obligations, and they discharge both directions.** Lemma 1: after insertion, any
block with `PPIN = TRUE` has `AVIN' = TRUE`. Theorem 1 follows: every deleted computation is
genuinely redundant at the point of deletion, so the transformation is correct. Lemma 2:
every path leaving an insertion point contains a computation that will be deleted, so the
insertion is paid for. Lemma 3: no path hits two insertions before hitting a deletion.
Theorem 2 follows: no path in the graph ends up with more computations than it started with.
Correctness and non-degradation, separately proved.

**Worked example.** Their Figures 3-4: `a+b` computed in blocks 6, 7, 8, 9, one operand
modified in block 4, block 7's computation loop-invariant, block 9's redundant, blocks 6 and
8 partially redundant. The systems put `PPIN` TRUE on 5-9, `PPOUT` TRUE on 3-7,
`INSERT` TRUE on exactly nodes 3 and 4, and delete all four original computations. One run
of one algorithm did redundancy elimination, invariant hoisting out of a loop, and partial
redundancy suppression.

# Applicability

Requires initialization blocks: if a block with several successors is the only predecessor of
a loop entry, a new empty block must be inserted on that edge. This is critical edge
splitting under a different name, and they state it as a graph precondition (Definition 5).

Requires the expression to be anticipable wherever insertion would occur, since inserting a
computation on a path that did not have it is unsafe. They are explicit that this loses
optimizations: their Figure 5, where `A+B` in node 4 is partially redundant but `A+B` cannot
be anticipated on exit from node 1, is unsolvable without adding a node on edge (1,4), and
they decline to discuss graph modification.

Two other admitted losses. Safe insertions that create a *new* partial redundancy elsewhere
(Figures 7-8) are refused, because without execution frequency data there is no way to know
whether the trade is profitable. And the algorithm does not minimize the number of inserted
computations: Figures 9-11 show a case where inserting once into a common successor beats
inserting twice into two predecessors. Their answer is a separate space-saving
"temporization" pass afterward.

Cost is dominated by the three-to-four iterations of five Boolean systems, bit-vectored 32
expressions per word. Measured on 50,000+ lines of LIS with procedures up to 420 blocks:
"never exceeded three" iterations for the `PPIN`/`PPOUT` system, and iteration counts near
three for the classical systems. Execution time is nearly linear in program size and
"very slightly" dependent on graph shape.

# Relevance

This is the primary source under `techniques/partial-redundancy-elimination.md`, which
previously rested on SSA Book chapter 11 alone and said so. Three things it settles that the
secondary account only gestured at.

The subsumption argument is the reason to care. If we build PRE at all, we do not
additionally build LICM, and we do not build global CSE. Their section 3.4 checks the
subsumption case by case: classical redundancy elimination deletes where
`ANTLOC · AVIN`, and those blocks always satisfy `ANTLOC · PPIN`; classical invariant motion
places at the initialization block `i` of the outermost loop, and that block always satisfies
`PPOUT_i = TRUE`. It also handles multi-entry loops, which the classical technique usually
cannot.

The bidirectionality is the reason to reach for Knoop-Rüthing-Steffen's lazy code motion
instead, and now we can see exactly *where* it lives, in the `TRANSP_i · PPOUT_i` term of
`PPIN_i`. That is a concrete thing to look for in any PRE implementation we read.

The Boolean formulation is worth respecting on its own terms for our purposes. Five systems
of one-bit-per-expression equations, 32 expressions per word, three iterations. For a
compiler that wants a cheap PRE over `flvector-length` and indexed loads, this is a far
smaller thing to build than SSAPRE's factored redundancy graph plus DownSafety plus
CanBeAvail plus Later, and it does not need conventional SSA or maximal expression trees.
The SSAPRE machinery buys sparseness and lifetime optimality; if we do not need those, this
is the cheaper correct answer.

# Notes

**The venue and pagination check out exactly**: CACM 22(2), February 1979, pp. 96-103,
copyright line `© 1979 ACM 0001-0782/79/0200-0096`. Authors E. Morel and C. Renvoise, CII
Honeywell Bull, Louveciennes, France. Received November 1976, revised September 1978. The
PDF opens with the tail of the preceding article's reference list (an APL arrays-of-arrays
piece); the paper itself starts partway down p. 96.

**This paper is not where the classical algorithm's name comes from.** It calls the
transformation "suppression of partial redundancies"; "partial redundancy elimination" and
"the Morel-Renvoise algorithm" are later coinages. Their own earlier work is cited as [12]
(1974 thesis, an expression-by-expression version they call too costly) and [13] (1976,
Second International Symposium on Programming, the first nongraphical version). So the CACM
paper is the third iteration of the idea, not the first.

**The known defect is visible in the text if you look for it.** The `PPIN`/`PPOUT` system is
bidirectional and, as the subsequent literature established, its placement is not optimal:
it can hoist a computation further than necessary, lengthening live ranges for no gain. The
paper does not claim optimality anywhere. Theorem 2 claims only that no path gets worse.
Section 3.4 explicitly admits the non-minimal insertion count and the refusal to trade one
partial redundancy for another. Read the later claim "Morel-Renvoise is suboptimal" as
correct but not a discovery; the authors bounded their own claim honestly.

**The complexity claim is empirical, not proved.** "A meaningful theoretical evaluation seems
to be very difficult and we have only experimentally measured the number of iterations."
The near-linearity is a measurement on well-structured LIS programs whose blocks were
numbered in creation order, which is close to reverse postorder. On adversarial or
machine-generated graphs neither the iteration count nor the linearity should be assumed.

**Solid attributions inside.** The partial-redundancy notion is credited to their own [12].
Redundancy elimination and invariant removal go to Allen and Cocke [2,3,4] via intervals.
The iterative Boolean alternative goes to Hecht and Ullman, Kildall, and their own thesis
[6,9,12]. Kennedy [8] is cited for the interval-versus-iteration comparison, including the
concession that graph families exist where iteration does more bit-vector work. The
"average upper bound of the number of iterations is 4.75" figure comes from Hecht and
Ullman applying Knuth's 50-Fortran-program study, not from the authors' own data.
