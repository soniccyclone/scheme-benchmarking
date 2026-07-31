---
type: paper
title: "Constant Propagation with Conditional Branches"
description: Introduces Sparse Conditional Constant propagation (SCCP), which fuses optimistic constant propagation over SSA def-use edges with unreachable-code elimination in a single worklist fixpoint.
resource: knowledge/sources/wegman-zadeck-constant-propagation-with-conditional-branch.pdf
tags: [constant-propagation, dataflow-analysis, ssa, lattice, unreachable-code-elimination]
authors: [Mark N. Wegman, F. Kenneth Zadeck]
year: 1991
venue: "TOPLAS 13(2), April 1991, pp. 181-210"
informs: [/techniques/dataflow-analysis.md, /techniques/interval-domain.md, /techniques/type-feedback.md]
pipeline_stage: 05-intervals
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Four algorithms presented in order of increasing power, of which the fourth is new. Simple
Constant (Kildall), Sparse Simple Constant (Reif/Lewis, restated over SSA), Conditional
Constant (Wegbreit's Algorithm 3.1 specialized), and Sparse Conditional Constant. SCCP is
the contribution: it gets CC's precision (branches with constant conditions prune the
program) at SSC's cost (linear in the SSA graph). Two secondary claims matter as much as
the algorithm. First, *optimistic* initialization is what lets propagation cross loop
back-edges; pessimistic algorithms that start at bottom and raise cannot, and so compute a
fixed point that is not maximal. Second, executability must be tracked on flow-graph
*edges*, not nodes, or you lose constants in loops with multiple exits.

# Mechanism

Lattice is three-level per variable, not per program state: top (as-yet-undetermined
constant), an infinite antichain of constants c_i, bottom (not constant). Meet is the
obvious one. Kildall's lattice was per-state; splitting it per-variable is what drops the
bound from cubic to quadratic and makes the sparse formulation possible.

SCCP runs two worklists over a minimal-SSA program:

- `FlowWorkList` of CFG edges, seeded with the start node's out-edges.
- `SSAWorkList` of def-use edges, initially empty.
- Every CFG edge carries an `ExecutableFlag`, initially false. Every LatticeCell is top.

Pop from either list until both are empty.

CFG edge popped: if already executable, do nothing. Otherwise mark it executable; run
`Visit-phi` on every phi at the destination; if this is the *first* executable in-edge to
the node, run `VisitExpression` on the node's expression; if the node has exactly one
out-edge, push it.

SSA edge popped: if the target is a phi, `Visit-phi`. If the target is an ordinary
expression, run `VisitExpression` only if at least one in-edge of that node is already
executable; otherwise ignore it.

`Visit-phi` takes the meet over operands, but reads an operand as *top* when its
corresponding CFG in-edge is not yet executable. That single rule is the whole of the
conditional-constant power, expressed sparsely.

`VisitExpression` evaluates with the operand cells and special rules for short-circuiting
operators (`x or true = true` even when x is bottom). If the result cell lowers: for an
assignment, push all outgoing SSA edges; for a branch condition, push the single taken
out-edge if the condition is a constant, or all out-edges if it is bottom.

Complexity: each SSA edge is examined at most twice (its def can only lower twice), each
node once per in-edge, so O(E + |SSA edges|), linear in practice. Compare SC at O(E*V^2)
and CC at the same. Def-use chains are explicitly rejected as the sparse representation:
they can be N^2 per variable, and they carry values along non-executable paths, so a
def-use SCCP silently loses constants that SSA-SCCP finds.

# Applicability

Needs minimal SSA and needs the analysis run to completion. Optimistic algorithms produce
*wrong* answers if stopped early, unlike pessimistic ones. Uninitialized variables must be
seeded bottom in languages where reading them is legal-but-undefined (Fortran); top is
only safe when the language forbids the read. Expressions that cannot be folded at compile
time (a read) must be seeded bottom by inspection before the worklist starts. Arrays are
punted: any store to an array is a store of bottom unless the array is always
constant-indexed. Aliasing is handled by an explicit and clever encoding: insert
`if IsAliased(a,b) then b := a` after each assignment to a maybe-aliased variable, so the
alias merge becomes an ordinary phi, and `IsAliased` itself becomes a lattice cell that
inlining can later resolve to true or false. This blows up by a factor of V in the worst
case; the recommended fallback is to assign bottom to heavily-aliased variables.

# Relevance

Our interval domain is the same algorithm with a taller lattice. Keep the two-worklist
structure and the executable-edge flag verbatim; replace the three-level lattice with
intervals and add widening, since the paper's termination argument rests entirely on "a
cell can only lower twice" and a lattice of infinite height does not give that. Section 7
says this explicitly: range propagation is the same shape with an infinite-height lattice,
and is listed as open work. That is the gap `05-intervals.ss` fills.

Two details to lift directly. The edge-versus-node observation (Figure 13) tells us to put
executability on edges in our own CFG representation from the start. The alias-as-phi
encoding is a cheap way to make `09-alias.ss` results visible to the numeric domains
without a separate merge machinery.

Section 6.2's procedure-integration variant is directly usable for `07-compiler` inlining:
instead of an `ExecutableFlag`, use a hash table keyed by (call site, node), instantiating
blocks lazily as flow edges are popped. Constant propagation then costs time linear in the
*specialized* code, not the generic code, and you never copy blocks you would immediately
delete. That is strictly better than inline-then-analyze.

Type determination over the type field as a lattice variable (Figure 14) is the same pass,
and it eliminates run-time type checks from macro-expanded arithmetic. For a Scheme
compiler this is not a footnote, it is a primary use.

# Notes

Title verified against page 1: "Constant Propagation with Conditional Branches", Wegman and
Zadeck, IBM T. J. Watson. Published TOPLAS 13(2), April 1991, pp. 181-210; received Feb
1988, accepted Oct 1990. A preliminary version is POPL 1985, pp. 291-299. The bibliography
entry gives no year or venue, so record TOPLAS 1991 rather than 1985, since the journal
version is what this PDF is and it contains the interprocedural material the POPL paper
does not.

Dated in one respect worth noting: the running-time argument leans on "worst case is rarely
achieved, it is our intuition" without measurement, and the space-locality worry in
footnote 8 is answered with "no hard data is available to resolve this." The complexity
claims are sound; the empirical claims are assertions.

The paper's own honesty about procedure integration is refreshing and should temper our
inlining expectations. It cites Richardson and Ganapathi finding that integration and
optimization together bought no more than the product of their separate benefits, against
Ball and Appel/Jim reporting positive results, and concludes no single study settles it.
