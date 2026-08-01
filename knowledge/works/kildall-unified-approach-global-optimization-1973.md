---
type: paper
title: "A Unified Approach to Global Program Optimization"
description: Defines the meet-semilattice dataflow framework, the worklist algorithm over it, and four optimizing functions (constant propagation, common subexpression elimination, their combination, live expressions) that plug into it; the framework everything since sits inside, and the paper whose correctness theorem is wrong for its own headline example.
resource: knowledge/sources/kildall-unified-approach-global-optimization-1973.pdf
tags: [dataflow-analysis, lattice, fixpoint, constant-propagation, common-subexpression-elimination, value-numbering]
authors: [Gary A. Kildall]
year: 1973
venue: "Conference Record of the ACM Symposium on Principles of Programming Languages (POPL), Boston, October 1973, pp. 194-206"
informs: [/techniques/dataflow-analysis.md, /techniques/global-value-numbering.md, /techniques/liveness-analysis.md, /techniques/register-allocation.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-08-01T00:00:00Z" }
---

# Contribution

Before this paper, each global optimization was its own algorithm with its own proof.
Kildall's move is to factor the problem in two: a *program-independent* propagation
algorithm that does all the graph reasoning, and a *program-point-local* "optimizing
function" that does all the semantic reasoning. Write a function that optimizes a
straight-line sequence, hand it to Algorithm A, and you get the global version for free.
That factoring is the reason everything from SCCP to abstract interpretation to the
interval domain can be described in a paragraph today.

The concrete deliverables are the semilattice formulation, the worklist algorithm, a
finiteness theorem, an `O(n^2)` bound, a correctness theorem, and four optimizing
functions demonstrating the framework covers constant propagation, common subexpression
elimination, both at once, and live-expression (dead-code) analysis on the reversed graph.

# Mechanism

**The lattice.** `P` is the finite set of optimizing pools with a meet `∧` that is
commutative and associative, giving a finite meet-semilattice. Ordering is defined *from*
the meet: `x ≤ y ⟺ x ∧ y = x`. `P` has a zero element `0 ≤ x` for all `x`. Kildall then
adjoins an artificial unit `1` above everything, `P' = P ∪ {1}`, and initializes every
node's pool to `1`. That is a real detail and not decoration: because `1 ∉ P`, the first
visit to any node always strictly lowers its pool, which forces the algorithm to consider
every reachable node at least once. This is the optimistic-initialization trick, stated in
1973.

**The optimizing function.** `f : N × P → P`, required to satisfy the *homomorphism
property* `f(N, x ∧ y) = f(N, f x) ∧ f(N, y)`. This is distributivity, and it is
strictly stronger than monotonicity. Hold that thought.

**Algorithm A**, verbatim in shape:

    A1  L <- entry pool set {(e, x)}
    A2  if L empty, halt
    A3  pick any (N, P_i) from L, remove it
    A4  if P_N <= P_i, goto A2                  # no new information
    A5  P_N <- P_N ∧ P_i
        L <- L ∪ {(N', f(N, P_N)) : N' ∈ I(N)}  # I = immediate successors
    A6  goto A2

Selection order in A3 is explicitly arbitrary (Corollary 1: the final pools are unique
regardless), and Kildall notes that treating access to `L` as a critical section makes the
algorithm parallel.

**Complexity.** Let `n = |N|` and `h(P')` be the maximum chain length in the lattice. A5
fires at most `h(P')` times per node, so at most `n · h(P')` times overall. For constant
propagation, `|U| = |V| × |C|` grows linearly with `n`, so `h` grows with `n` and the bound
is `O(n^2)`.

**f1, common subexpression elimination.** The pool is a *partition* of expressions into
equivalence classes, and the meet is intersection-by-class: `P(c) = P1(c) ∩ P2(c)` over
expressions `c` common to both. The key operation is *structuring* the pool: when a new
expression `e` is added, every other expression in the program whose operands are already
class-equivalent to `e`'s is added to `e`'s class. That is why `(a+b)+x` is caught as
redundant at node V after `r := a+b; r+x` at node U: the structuring step put `(a+b)+x`
into the class of `r+x`. On assignment `d := e`, kill every expression containing `d`, then
for each surviving `e'` containing `e`, create `e''` with `d` substituted and put it in
`e'`'s class.

**Value numbers.** Section 8 is the origin of value numbering as an implementation
technique. Assign a unique integer per class, rewrite `b+c` as `(1)+(2)`, and the pool
becomes linear in the number of expressions in the block rather than in the (exponential)
expanded class contents. The meet on value-number form is worked as an explicit algorithm:
a class-count list `C` tracking remaining members per class in `P1`, a mapping list `R` of
`v(v1, v2)` triples recording that class `v1` of `P1` and `v2` of `P2` fuse to class `v` of
the result, built lazily while scanning `P1`. Expression nodes `(n1) ⊕ (m1)` are deferred
until both operand classes are exhausted. The predicate `P2 ≥ P1` falls out of the same
scan.

**f2** extends `f1` with constants: when the operands of `e` are in classes containing
constants, evaluate `e` and merge its class with the class of the resulting constant. One
function does folding and CSE simultaneously.

**f3, live expressions.** Run Algorithm A on the *reversed* graph with exit nodes as entries,
meet is set union, ordering is `⊆`, zero is `∅`, all pools initialize to `∅`. At each node,
kill expressions containing the assignment's destination, then add every partial computation
appearing. Kildall's extension: attach to each live expression the minimum distance to its
next occurrence, meet being union plus min on distances, and spill the register holding the
farthest-away live expression. That is Belady's rule, derived from a dataflow analysis.

# Applicability

The framework needs: a finite semilattice (or the algorithm may not terminate), an
optimizing function satisfying the homomorphism property (or Theorem 2 does not hold), and
a program graph in which every node is reachable from an entry. Unreachable nodes are
detected as a by-product, since they never appear in the `N` column, and Kildall says to
delete them.

The implementation notes are practical and still correct. Approximate pools per basic block
must be retained across the analysis; output pools can be intersected into successors
immediately and discarded. Bit strings for set-valued domains, lists for ordered pairs.
Partitions are the hard case, and the two mitigations offered are (a) prescan the program
for an expression list and only structure with expressions on it, and (b) run live-expression
analysis *first* so partitions are limited to expressions live at that point, which both
shrinks the pools and improves the convergence rate.

# Relevance

This is the substrate for stages 05 through 09. Our interval and pentagon domains are
Kildall lattices with an infinite-height twist; the worklist in `05-intervals.ss` is
Algorithm A with widening bolted onto A5. Three specific things to take:

The optimistic unit element. Initializing to a value *outside* the lattice, so that the
first visit is guaranteed to lower, is cheaper and cleaner than a separate "visited" flag
and it is the same argument SCCP makes for initializing to top. Do it that way.

Value numbering as the representation for a partition lattice. Our type-recovery and GVN
passes both want an equivalence-class domain, and Kildall's `C`/`R` meet algorithm is a
concrete, linear-space implementation of the meet on that domain. It predates and is
simpler than the hash-based schemes.

Live analysis before CSE, not after. The ordering advice in section 8 is a phase-ordering
constraint with a real justification: live analysis shrinks the CSE lattice. Cheap to
respect, and our phase list should.

The f3 minimum-distance extension is the honest version of what stage 12 wants from
liveness. Chaitin-style allocation asks liveness for interference only; Kildall's distance
lattice gives the spill heuristic directly, and it composes with our existing liveness pass
at the cost of one integer per live expression.

# Notes

**The correctness theorem is wrong for the paper's own headline example, and this matters.**
Theorem 2 claims Algorithm A computes `P_N = ⋀{f(p_n, ..., f(p_1, P))}` over all paths to
`N`, i.e. the meet-over-all-paths solution. The proof depends on the homomorphism property
`f(N, x ∧ y) = f(N, x) ∧ f(N, y)` (Lemmas 1 and 2 both use it). Kildall's constant
propagation function does not have it. Take a node `N` computing `d := a + b`, with
`P1 = {(a,1),(b,2)}` and `P2 = {(a,2),(b,1)}`. Then `P1 ∧ P2 = ∅` and `f(N, ∅) = ∅`,
but `f(N, P1) ∧ f(N, P2) = {(d,3)}`. MOP finds `d = 3`; the algorithm does not. The
function is monotone but not distributive, so what Algorithm A actually computes is the
maximal fixed point, which is a *sound under-approximation* of MOP, not MOP. Kam and Ullman
(1977) supplied the corrected statement. Note also that Kildall does not prove `f1` or `f2`
distributive in this paper; he asserts it and defers to his tech report [33]. Anyone
implementing from this paper should read the framework as the monotone framework, and the
"the result is MOP" claim as false in general.

**Attribution to fix downstream.** `techniques/dataflow-analysis.md` currently cites this
work only at second hand, through Cousot and Cousot's classification table and through
Wegman and Zadeck's complexity comparison. Both citations are accurate but neither is the
paper. Specifically, the phrase "Kildall's simple constant at `O(E · V^2)`" in that document
is Wegman and Zadeck's restatement; Kildall's own bound is `n · h(P')` with `h` growing
linearly in `n` for constant propagation, giving `O(n^2)` node-visits, which is not the same
accounting.

**Constant propagation intersects; it does not join.** Kildall's pools are sets of
`(variable, constant)` pairs and the meet is set intersection, so the lattice is ordered by
containment with `∅` at the bottom. Readers arriving from the modern flat constant lattice
(`⊤`, constants, `⊥`) will find the direction inverted relative to what they expect.

The scan is legible throughout, including both appendices (Appendix A traces the algorithm
on the Figure 1 program; Appendix B is the proof of Theorem 2), though the OCR text layer
mangles subscripts and the tabular examples in Tables I-III badly. The prose and the
algorithm statements are unambiguous.

Section 6 concedes that global register allocation is unsolved ("No complete solution to the
global register allocation problem is known by the author at this time") and points at Day's
integer-programming formulation. Chaitin's graph-coloring answer is nine years away.
