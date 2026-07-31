---
type: paper
title: "An Efficient Method of Computing Static Single Assignment Form"
description: Places minimal phi-functions at the iterated dominance frontier of a variable's assignment set, and shows control dependence is the same computation on the reverse CFG.
resource: knowledge/sources/cytron-ferrante-rosen-wegman-zadeck-efficiently-computing-.pdf
tags: [ssa-construction, dominance-frontier, control-dependence, dataflow-analysis, compiler-ir]
authors: [Ron Cytron, Jeanne Ferrante, Barry K. Rosen, Mark N. Wegman, F. Kenneth Zadeck]
year: 1989
venue: "POPL 1989 (ACM 0-89791-294-2/89, pp. 25-35)"
informs: [/techniques/ssa-construction.md, /techniques/dataflow-analysis.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Two results, and the second one is the sleeper.

First: the placement of phi-functions for a variable `V` is exactly the *iterated dominance
frontier* of the set of nodes that assign to `V`. This turns an iterative fixpoint over
"join nodes reachable by two definition-carrying paths" into a worklist walk over a
precomputed graph structure whose size depends only on control flow, not on the number of
variables. Prior algorithms were effectively quadratic in E × V; this one is
O(E + T + |DF|), where T counts ordinary assignments plus phi-functions.

Second: control dependence is dominance frontier on the reverse CFG. `Y` is control
dependent on `X` in the CFG iff `X ∈ DF(Y)` in the RCFG. One piece of machinery, two
structures. Prior control-dependence algorithms used quadratic intermediate space and
multiple dominator-tree passes.

# Mechanism

**Dominance frontier.** `DF(X) = { Y | (∃P ∈ Pred(Y)) X dom P and X !sdom Y }`. Computing
it from the definition costs a dominator-tree search per node, so it is decomposed into a
local part and an up part:

```
DF(X) = DF_local(X) ∪ ⋃_{Z ∈ Children(X)} DF_up(Z)
DF_local(X) = { Y ∈ Succ(X)  | idom(Y) ≠ X }
DF_up(Z)    = { Y ∈ DF(Z)    | idom(Y) ≠ X }, X = idom(Z)
```

The equality tests are the whole trick: `X sdom Y` for `Y ∈ Succ(X)` reduces to
`idom(Y) = X`, because strict dominance is the transitive closure of immediate dominance.
So the algorithm is a single bottom-up walk of the dominator tree:

```
for each X in bottom-up traversal of dominator tree:
  DF(X) = {}
  for Y in Succ(X):        if idom(Y) != X: DF(X) ∪= {Y}   /* local */
  for Z in Children(X):
    for Y in DF(Z):        if idom(Y) != X: DF(X) ∪= {Y}   /* up   */
```

O(E + N²) worst case, linear in |DF| in practice. Requires a dominator tree first
(Lengauer-Tarjan, O(E α(E))).

**Phi placement.** Per variable `V`, seed a worklist `W` with `A(V)`, the nodes assigning
to `V`. Pop `X`, and for each `Y ∈ DF(X)` not already carrying a phi for `V`: insert
`V ← φ(V,…)` with arity = |Pred(Y)|, mark it, and if `Y` was never on the worklist push it.
Two flag arrays (`Work`, `DomFronPlus`) keep each node visited at most once per variable.
The termination argument is Theorem 2: the fixpoint of `J⁺(S)` (iterated join) equals
`DF⁺(S)` — provable because `Entry` is treated as assigning every variable.

**Renaming.** DFS the *dominator tree* carrying `S(V)`, a stack of version numbers per
variable, and `C(V)`, a monotone counter. At each node: rewrite RHS uses to `V_top(S(V))`;
for each assignment, allocate `i = C(V)`, rewrite the LHS to `V_i`, push `i`, increment.
Then for each CFG successor `Y`, fill in the `j`-th operand of each phi in `Y` where
`j = WhichPred(Y,X)`. Then recurse into dominator-tree children. On exit, pop one entry per
assignment in the block. Note the asymmetry that makes it work: phi *operands* are filled
along CFG edges, everything else walks the dominator tree.

**Control dependence.** Build RCFG (reverse every edge, swap Entry/Exit), build its
dominator tree (= postdominator tree of CFG), run the same DF algorithm to get RDF, then
invert: `CD(X) = { Y | X ∈ RDF(Y) }`. The Entry→Exit edge is added so the resulting
relation is rooted at Entry.

# Applicability

Preconditions: every node on a path from Entry and on a path to Exit; only simple unaliased
scalars (no arrays, no pointer values — aliasing must be pre-resolved by a separate
analysis). Arbitrary, including irreducible, control flow is fine; that is the point of
the EISPACK evaluation.

Costs: `|DF|` is O(N²) in the worst case and the paper builds the witness itself — a nest
of n `repeat-until` loops has O(n²) total dominance frontier size while needing only O(n)
phi-functions. So DF computation can dominate the phi placement it exists to serve. On the
61 EISPACK routines the measured DF-arcs-per-statement ratio ran 1.3 to 2.4 and looked
linear, which is evidence, not a bound.

The "minimal" in minimal SSA means minimal *given* the assignment sets, not minimal in the
live sense. Phis are placed for variables dead at the join. Pruned SSA (liveness-filtered)
and semi-pruned SSA come later and are not in this paper.

# Relevance

Our pipeline is nanopass over a Scheme core language, not a CFG of basic blocks, and the
CUJ deliberately recognizes loops as self-tail-calling `letrec` procedures rather than
running a general natural-loop analysis. In that representation SSA is already the ambient
condition: a `letrec`-bound loop procedure's parameters *are* the phi-functions, and the
tail call *is* the operand-filling step. Appel's "SSA is Functional Programming" makes the
correspondence explicit.

So the direct value here is not the construction algorithm. It is that ABCD (stage 06 and
07) is specified against an SSA inequality graph with phi-nodes, and this paper defines
what those phis mean and where they legally sit. If we ever need a real CFG — likely at
stage 11 or 12, once control flow is explicit and the `letrec` structure is gone — this is
the reference, though Braun et al. is the algorithm we would actually type.

The control-dependence half is worth keeping in view for stage 07 hoisting: knowing which
branch a bounds check is control dependent on is exactly the question "can I hoist this
check out of the loop, and if so what guard must I replicate."

# Notes

**Bibliography correction, flagged.** The bibliography calls this "the canonical SSA paper,
TOPLAS 1991," and the slug reads `efficiently-computing-`. The PDF is neither. Title page
reads *"An Efficient Method of Computing Static Single Assignment Form"*, ACM copyright
line `0-89791-294-2/89/0001/0025`, pages 25-35 — the POPL 1989 conference paper. The
TOPLAS 1991 article is a different, longer document ("Efficiently Computing Static Single
Assignment Form and the Control Dependence Graph," TOPLAS 13(4):451-490) with expanded
complexity analysis and the `A_φ`/`work`/`hasAlready` pseudocode everyone quotes. The
conference version is a legitimate ancestor and covers the same two theorems, but if a
downstream document cites a page number or the TOPLAS complexity discussion it will not
find it here. Slug and bibliography entry both want fixing, or a second fetch.

The paper is honest about its own weak point in a way that later summaries are not: Section
6 concedes the dominance frontier mapping can be quadratic while the phi count stays
linear, and that most of DF is never used. Cooper-Harvey-Kennedy later attack exactly this
by making dominator and DF computation cheap enough that the asymptotics stop mattering at
realistic sizes.

Also dated: the extraction of def-use chain savings ("at most E def-use chains, versus
D × U") is stated as motivation, but the modern reason to want SSA — that it gives every
value a name usable as an analysis key — is barely argued. The paper is selling SSA to an
audience that had not yet accepted it.
