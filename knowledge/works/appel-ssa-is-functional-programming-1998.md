---
type: paper
title: "SSA is Functional Programming"
description: A four-page column establishing the dictionary between SSA form and lexically nested functions — a block is a function, a phi-node is a formal parameter, an in-edge is a call site, and minimal phi-placement via dominance frontiers is optimal function nesting.
resource: knowledge/sources/appel-ssa-is-functional-programming-1998.pdf
tags: [ssa-construction, dominance-frontiers, functional-intermediate-representation, cps, dataflow-analysis]
authors: [Andrew W. Appel]
year: 1998
venue: "ACM SIGPLAN Notices 33(4), Functional Programming column"
informs: [/techniques/ssa-construction.md, /techniques/dataflow-analysis.md, /techniques/bounds-check-elimination.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

The dictionary, stated in four pages with a worked example:

| SSA | functional |
|---|---|
| basic block | function |
| `φ`-assignment left-hand side | formal parameter |
| `φ` argument on the *k*th in-edge | actual parameter at the *k*th call site |
| control-flow edge | tail call |
| no `φ` needed for `x` in block *b* | *b*'s function is lexically nested inside `x`'s binder |
| "definition dominates every use" | lexical scope |

And the punchline: **the algorithm for minimal `φ`-placement is the algorithm for optimal function
nesting.** Splitting every variable at every block boundary corresponds to the flat mutual
recursion where every function takes every live variable; dominance-frontier placement corresponds
to nesting functions so inner ones can reference non-locals instead of taking parameters. Appel
credits Kelsey (1995) for the CPS↔SSA correspondence and Zadeck for telling him repeatedly that
SSA is a functional program.

# Mechanism

**Why `φ` is not a function.** In `j₂ ← φ(j₇, j₁)`, compare with `f₂(…, j₂, …) = …` and the two
calls `f₂(…, j₇, …)`, `f₂(…, j₁, …)`. The left-hand side of the `φ` is the formal; each right-hand
argument is an actual at some call site. The correspondence is inside-out — the `φ` node collects
into the callee what the functional form distributes across the callers.

**Dominance.** `a` dominates `b` if every path from the start node to `b` goes through `a`. The
dominance frontier `DF(a)` is `{c | ∃ edge b→c, a dom b, a not strictly dom c}` — the border of
`a`'s dominated region.

**The placement rule.** Assuming every variable has an initialising definition at the start node,
if node `n` contains a definition of `x`, then every node in `DF(n)` needs a `φ` for `x`. That is
because any node on `a`'s dominance frontier is reachable from two different definitions of `x`:
the one in `n` and the one at entry. Iterate to a fixpoint, since inserted `φ`s are themselves
definitions.

Appel's example graph is worth keeping: node 5's dominance frontier is `{4, 5, 12, 13}`, crossed by
edges 6→4, 8→5, 8→13, 7→12. **A node can be in its own dominance frontier** — that is exactly the
loop-header case, and it is the detail that trips up first implementations.

**The invariant.** In SSA, a variable's definition dominates every use (for a use inside a `φ`, it
dominates the corresponding predecessor). Appel's observation is that this is "often unstated in
explanations of SSA, but it is necessary for many of the analyses and optimizations on SSA — it is
part of SSA's semantics." In a nested functional program it is not a side condition to be
maintained; it is enforced by the structure of function nesting.

# Applicability

This is a correspondence, not an algorithm. It buys nothing on its own; what it buys is the right
to transport algorithms across the boundary, and to stop maintaining an invariant by hand that
lexical scope already enforces.

Scalars only. Appel is explicit that arrays require dependence analysis, which he characterises as
"another way of extracting the functional program hiding inside the imperative one" — a nice line,
but it means the correspondence stops at exactly the point our bounds-check work starts caring
about memory.

The correspondence is between SSA and *tail-called, lexically nested* functions in ANF or CPS —
Appel notes his notation is a variant of ANF or CPS, and that CPS binds every non-trivial value to
a variable. A functional IR that has not been through that normalisation is not automatically SSA.

Nothing is proved here and nothing is measured. The formal correspondence with conversion
algorithms in both directions is Kelsey's, not this paper's.

# Relevance

This is the licence to skip a pass. After `03-parse` our core language is already the nested-lambda
form; loop headers are `letrec`-bound procedures whose formal parameters are the loop-carried
variables. Which means:

- There is **no SSA construction pass to write**. `φ`-nodes are the formals of loop-header lambdas.
  An "SSA name" is a lexical binding, and it is already unique because the expander and `cp0`
  α-convert.
- The precondition that SSA-based analyses rely on — definition dominates use — holds by
  construction. ABCD, sparse conditional constant propagation, and global value numbering all
  assume it; we get it from scope rather than from a checked invariant.
- ABCD's inequality graph can be built directly over our variables. Each `letrec`-bound procedure's
  formals are the merge points where the graph needs its `φ`-analogue, and the back-edge is the
  call from the body to the header.

The reverse direction matters too. If we want any algorithm from the SSA literature stated in terms
of dominators — and dominance frontiers show up in more than `φ`-placement — we need a CFG view of
our `letrec`-bound continuations and a dominator tree over it. The paper tells us what that view is
without our having to invent the mapping.

Appel's closing observation is also worth taking seriously as a working practice: SSA people draw
flowcharts because flowcharts are better for explaining transformations, and "functional
programmers often get lost in the notation of functional programming." When arguing about a pass in
`docs/`, draw the graph.

# Notes

This is a **SIGPLAN Notices column**, not a refereed paper. Four pages, no evaluation, no new
algorithm, and about a third of it is an advertisement for chapter 19 of *Modern Compiler
Implementation*. The value is entirely in the dictionary, and the dictionary is correct and
useful — but this should not be cited as if it were a result.

Two typos in the flat functional program on page 2, both against the CFG in the same figure:
`k₁ = 1` in the first `let` should be `k₁ = 0`, and `f₆`'s body has `k₉ = k₆ + 1` where the block
diagram and the whole point of the example say `k₆ + 2`.

The plan describes this work as "the bridge between our functional core and SSA-based analyses."
That description is accurate — unusually so for a one-line bibliography entry.
