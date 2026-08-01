---
type: technique
title: Dataflow analysis
description: The monotone-framework recipe for computing a sound fact at every program point, its dense and sparse solvers, and what widening costs when the lattice has no finite height.
tags: [dataflow-analysis, lattice, fixpoint, worklist, widening, sparse-analysis]
sources:
  - resource: /works/kildall-unified-approach-global-optimization-1973.md
  - resource: /works/cousot-cousot-abstract-interpretation-popl-1977.md
  - resource: /works/wegman-zadeck-constant-propagation-with-conditional-branch.md
  - resource: /works/rastello-et-al-ssa-based-compiler-design-the-ssa-book.md
  - resource: /works/cooper-harvey-kennedy-a-simple-fast-dominance-algorithm.md
  - resource: /works/bod-k-gupta-sarkar-abcd-eliminating-array-bounds-checks-on.md
  - resource: /works/willsey-et-al-egg-fast-and-extensible-equality-saturation-.md
implemented_by: [/implementations/chez.md, /implementations/sbcl.md]
absent_from: []
pipeline_stage: 05-intervals
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

Given a program and a property (which variables are live, what constant a variable holds,
what range it is in, which blocks are reachable), compute a fact at every program point
that is true on every execution, in bounded time. Everything in stages 05 through 09 of our
pipeline is an instance. The framework is the same each time; what differs is the lattice,
the transfer functions, and whether the fixpoint is reachable in finitely many steps.

# Mechanism

**The framework.** A dataflow problem is a complete lattice `L` representing the property
space, a flow graph, and a transfer function per operation, with meet or join applied where
edges merge. Cousot and Cousot's formulation is more general and worth keeping as the
definition: an abstract interpretation is a tuple `<A-Cont, o, <=, top, bottom, Int>` where
`Int` is order-preserving, and the analysis result is an extreme fixpoint of `Cv = Int~(Cv)`,
which exists by Tarski. Analyses classify on three independent axes, join versus meet,
forward versus backward, maximal versus minimal solution, giving eight vertices. Kildall's
constant propagation is `(intersect, forward, ascending)`; Wegbreit's is
`(union, forward, descending)`.

**The soundness recipe.** Relate concrete and abstract by `alpha` and `gamma`, then prove
the *local* condition `gamma(Int(a, x)) >= Int(a, gamma(x))` on each primitive transfer
function and transfer it to fixpoints by their theorems T1 and T2. Per-instruction
obligations, whole-program result for free. Note that their hypothesis 6.3 is the equality
`alpha o gamma = id`, which is a Galois insertion rather than the general adjunction.

**Dense solving.** In and out sets per node, worklist over flow-graph edges, iterate until
stable. With lattice height `h` and graph `G = (V,E)`, the maximal fixed point is computed
in `O(|E| * h)`, and since `|E| <= |V|^2` that is `O(|V|^2 * h)` in general. Two practical
notes. Reverse postorder is not a detail: the dominance problem solved in reverse postorder
halts in at most `d(G) + 3` passes, where `d(G)` is loop connectedness, measured at 1.11
average on real code. And the representation, not the equations, is where the time goes.
Cooper, Harvey and Kennedy's bit-vector implementation of dominance was 900 times slower
than Lengauer-Tarjan and SparseSets were worse; replacing the sets with a single `idom`
array and a two-finger `intersect` walk on postorder numbers made the same equations the
fastest known implementation. The general lesson is to pick the representation that makes
meet cheap, then stop worrying about the asymptotics.

**Sparse solving.** If every fact is attached to a variable with a single definition, the
propagation can skip every program point that neither defines nor uses it. Wegman and
Zadeck's SCCP is the canonical shape, and the SSA Book's chapter 8 generalizes it to any
monotone lattice:

    FlowWorkList  <- out-edges of start node       # CFG edges
    SSAWorkList   <- empty                         # def-use edges
    every CFG edge: ExecutableFlag = false
    every LatticeCell = top

    pop from either list until both empty:
      CFG edge:  if already executable, skip. Otherwise mark executable;
                 Visit-phi every phi at the destination;
                 if this is the first executable in-edge, VisitExpression the node;
                 if the node has one out-edge, push it.
      SSA edge:  phi target -> Visit-phi.
                 ordinary target -> VisitExpression only if some in-edge is executable.

`Visit-phi` takes the meet over operands but reads an operand as *top* when its
corresponding CFG in-edge is not yet executable. That one rule is the whole of the
conditional-constant power expressed sparsely. `VisitExpression` pushes all outgoing SSA
edges when a cell lowers, and for a branch pushes the single taken edge if the condition is
constant or all edges if it is bottom.

Two design points that are stated as results rather than taste. Optimism: initializing to
top and lowering is what lets propagation cross loop back edges. A pessimistic algorithm
that starts at bottom and raises cannot, and computes a fixpoint that is not maximal.
Edges, not nodes: executability must be tracked on flow-graph edges or constants are lost
in loops with multiple exits.

**Demand-driven solving.** A third shape, for when only a few facts are ever asked for.
ABCD never computes a fixpoint over the whole graph; it answers `prove(a, v, c)`, "is
`v - a <= c`", by a memoized backward DFS from the query vertex, meeting at merge vertices
and joining elsewhere, with the memo table keyed by a *threshold* rather than a value. A
stronger already-proven fact answers True, a weaker already-disproven fact answers False,
and a node may be revisited once per progressively stronger question. Computing a
topological order would require touching the whole graph and defeat the point. Measured
under ten `prove` invocations per query. Take this as the pattern for any analysis where
the number of interesting program points is far smaller than the program.

**Termination on a tall lattice.** Intervals satisfy neither finiteness nor the ascending
chain condition, so the Kleene sequence does not stabilize. Pick `W-arcs`, a minimal arc
set such that every cycle of the equation system contains at least one (on a reducible
forward graph, the loop back edges), and apply a widening only there:

    [i,j] widen [k,l] = [ if k < i then -inf else i , if l > j then +inf else j ]
    [i,j] narrow [k,l] = [ if i = -inf then k else min(i,k) ,
                           if j = +inf then l else max(j,l) ]

Widening discards any bound that moved. Narrowing only refines bounds that are infinite and
never touches a finite one, which is why starting the descending sequence from the widened
limit keeps every iterate inside `{X | X >= Int(X)}` and therefore still above the least
fixpoint. On `x := 1; while x <= 100 do x := x+1` the widened system gives `[1,+inf]` and
`[101,+inf]`, and the narrowing pass recovers `[1,101]` and `[101,101]`.

# Preconditions

Transfer functions must be order-preserving. That is the only structural requirement, and
it is why the framework covers so much. Precision needs more: a complete morphism gives the
exact least fixpoint, continuity gives the Kleene limit, mere isotony gives an
approximation above it.

Termination needs finite height, the ascending chain condition, or a widening. Optimistic
algorithms must run to completion; stopping early gives wrong answers, unlike pessimistic
ones.

Sparse propagation over the SSA graph is forward-only and def-use-only. Available
expressions is the standard counterexample, because its facts change at points that neither
define nor use the operands. The general legality condition is *Partitioned Lattice per
Variable*, `L = L_v1 x ... x L_vn`, plus the four Static Single Information conditions
(Split, Info, Link, Version). Vanilla SSA satisfies them only for analyses that take
information at definitions; an analysis that also takes information at conditional branches
needs sigma-functions and a split set of `DF+` forward plus `pDF+` backward.

SCCP's own preconditions are specific and easy to get wrong. Uninitialized variables must
be seeded bottom in languages where reading them is legal but undefined. Expressions that
cannot be folded at compile time (a read) must be seeded bottom by inspection before the
worklist starts. Any store to an array is a store of bottom unless the array is always
constant-indexed. Aliasing is handled by inserting `if IsAliased(a,b) then b := a` after
each assignment to a maybe-aliased variable, which turns the alias merge into an ordinary
phi and makes `IsAliased` itself a lattice cell that inlining can later resolve; the
encoding blows up by a factor of V in the worst case.

# Cost

Dense: `O(|E| * h)` time and in/out sets at every program point, where the lattice height
often depends on the program (copy propagation's lattice is a product over all variables,
so `h` scales with variable count).

Sparse: `O(|E_SSA| * h + |E_CFG|)`, with one cell per SSA name and no in/out sets at all.
SSA graph growth over the non-SSA program is measured linear. For SCCP specifically the
bound is tighter, `O(E + |SSA edges|)`, because a three-level cell can only lower twice, so
each SSA edge is examined at most twice. Kildall's own bound is `n · h(P')` step-A5 executions, with `h` growing linearly in `n` for constant propagation, giving O(n²) node-visits. (The `O(E·V²)` figure often attributed to him is Wegman and Zadeck's restatement in different units).

Precision given up: widening is, in the authors' own words, "a very rough operation which
introduces a great loss of information". The narrowing pass is the cheap part and it is
what turns `[1,+inf]` into `[1,101]`, which is exactly the fact a bounds check needs, so
skipping it forfeits most loop-bounds checks. The `W-arcs` choice is a real design decision
and on an irreducible graph it is arbitrary; a bad cut widens more than necessary.

# Disagreements

**Kildall's Theorem 2 is false as stated, for his own example analysis.** The proof requires
the homomorphism property `f(N, x ∧ y) = f(N,x) ∧ f(N,y)`, which is *distributivity*, not the
monotonicity his framework assumes. His constant-propagation function fails it: with
`P1={(a,1),(b,2)}` and `P2={(a,2),(b,1)}` meeting at `d := a+b`, `f(N, P1∧P2) = ∅` while
`f(N,P1) ∧ f(N,P2) = {(d,3)}`. So Algorithm A computes **MFP, not MOP**. Kam and Ullman
(1977) supplied the correction. This is load-bearing for stages 05 through 07: MFP is sound,
but a document claiming MOP is claiming more precision than the algorithm delivers. Read the
paper as the monotone framework, and note that `# Preconditions` above is right about
soundness and would be wrong if it were read as licensing MOP.

**Def-use chains versus SSA as the sparse representation.** Wegman and Zadeck reject def-use
chains explicitly. They can be `N^2` per variable, and they carry values along
non-executable paths, so a def-use SCCP silently loses constants that SSA-SCCP finds. This
is a correctness-of-precision argument, not a performance one.

**Can SSA support backward problems.** Section 8.2.4 of the SSA Book asserts flatly that it
cannot, and carries an untranslated marginal note from one author to another saying the
framing is a misconception. Chapter 13 then builds backward sparse analyses on SSI and
contradicts 8.2.4 directly. Read 8.2.4 as "vanilla SSA cannot". Our copy of the book is the
unfinished 2018 draft, which is why the editorial note is still visible; section numbers
will not match the 2022 Springer edition.

**Ascending and descending sequences are not duals.** Cousot's section 9.5 shows the
ascending approximation sequence from bottom bounds the least fixpoint from above, while
the truncated descending sequence from top bounds the *greatest* fixpoint from above.
Running all four brackets both. They also concede that no general fixpoint improvement
method exists: land on a non-extremal fixpoint and nothing in the framework gets you off it.

**Attribution errors that propagate.** The iterative dominance algorithm is Allen and Cocke
1972, not Purdom and Moore as the dragon book has it. Buchsbaum et al.'s asymptotically
better dominance algorithm runs 10 to 20 percent slower than the Lengauer-Tarjan it
improves on. And Galois *connections* are not in Cousot and Cousot 1977; the adjunction
formulation is the 1979 POPL paper, and the citation chain crediting it to 1977 is folklore.

**Empirical honesty.** Wegman and Zadeck's running-time argument rests on "worst case is
rarely achieved, it is our intuition" with no measurement, and their space-locality footnote
says outright that no hard data exists. The complexity claims are sound; the empirical ones
are assertions. Cooper et al.'s measurements are all warm-cache, taking the minimum of ten
runs over 10,000 repetitions, which is correct for deterministic algorithms but says
nothing about the cold-cache case where a CFG is touched once.

# For us

Stage 05 is SCCP with a taller lattice. Keep the two-worklist structure and the
executable-edge flag verbatim, replace the three-level lattice with intervals, and add
widening at back edges plus the descending narrowing pass, because the termination argument
"a cell can only lower twice" does not survive an infinite-height lattice. Wegman and
Zadeck's section 7 says range propagation is the same shape with an infinite-height lattice
and lists it as open work. That is precisely the gap `05-intervals.ss` fills.

Put executability on edges in our CFG representation from the start, not on nodes. It costs
nothing early and cannot be retrofitted cheaply.

Type determination over the type field as a lattice variable is the same pass and it
eliminates run-time type checks from macro-expanded arithmetic. For a Scheme compiler that
is a primary use, not a footnote, and it is the mechanism Chez already has half of: per
`docs/CHEZ-ANALYSIS.md`, `cptypes` is flow-sensitive and returns separate type environments
for the two arms of a conditional, but its lattice is a finite category lattice with no
ranges and no comparison-driven narrowing. SBCL runs the same shape at a taller level, with
interval arithmetic in `srctran.lisp` and relational constraints in `constraint.lisp`.

The alias-as-phi encoding is a cheap channel from `09-alias` into the numeric domains
without building separate merge machinery.

Section 6.2's procedure-integration variant is directly usable for inlining: instead of a
boolean executable flag, key a hash table by (call site, node) and instantiate blocks
lazily as flow edges are popped. Constant propagation then costs time linear in the
specialized code rather than the generic code, and blocks that would immediately be deleted
are never copied. That is strictly better than inline-then-analyze.

For soundness, prove each transfer function against Cousot's local condition rather than
arguing about the whole program. That is what the CUJ's domain unit tests should actually
be asserting, alongside monotonicity and termination of `widen`.

One adjacent mechanism worth knowing about: egg's e-class analyses are this same framework
lifted to equivalence classes, with a join-semilattice `D`, a `make` abstraction, a `join`,
and a `modify` write-back. If we ever build an e-graph, `modify` as concretization is what
lets the interval domain feed the rewriter. It gives no story for control flow, loops, or
effects, so it is a candidate for a sub-optimizer over the pure numeric fragment, not for
stages 05 through 07.
