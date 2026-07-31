---
type: technique
title: Loop analysis
description: Recognize loops, characterize their induction variables as chains of recurrences, derive trip counts and index ranges, and use the result to hoist or sink work out of the loop body.
tags: [loop-analysis, induction-variables, code-motion, chains-of-recurrences, widening, trip-count]
sources:
  - resource: /works/rastello-et-al-ssa-based-compiler-design-the-ssa-book.md
  - resource: /works/click-global-value-numbering-and-code-motion.md
  - resource: /works/bod-k-gupta-sarkar-abcd-eliminating-array-bounds-checks-on.md
  - resource: /works/cousot-cousot-abstract-interpretation-popl-1977.md
  - resource: /works/cooper-harvey-kennedy-a-simple-fast-dominance-algorithm.md
  - resource: /works/larsen-amarasinghe-exploiting-superword-level-parallelism-.md
  - resource: /works/dybvig-et-al-the-development-of-chez-scheme-icfp-2006.md
  - resource: /works/mine-octagon-abstract-domain-hosc-2006.md
implemented_by: [/implementations/sbcl.md]
absent_from: [/implementations/chez.md]
pipeline_stage: 07-loops
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

Three questions that have to be answered in order before any later stage can do anything
interesting with a loop. Where are the loops. Which variables advance by a fixed amount per
iteration, and through what range. And given both, what work can move out of the body, either
upward to the preheader or downward onto a cold path. Without this, a bounds check can only be
proven locally inside the body and must be re-proven every iteration, and a vectorizer has no
trip count from which to pick an unroll factor.

# Mechanism

**Recognition.** In our core language a loop is a `letrec`-bound procedure called in tail
position from its own body, which is the standard Scheme idiom and much easier to detect than
natural-loop analysis on a general CFG. The CFG route, if we need it, is dominators plus back
edges: Cooper, Harvey and Kennedy's iterative solver with `Dom` sets stored implicitly as a
`doms[]` array holding `IDom(b)`, and intersection as a two-finger walk toward the root over
postorder numbers. Forty lines, no union-find, and it hands back the dominator tree directly.
Click's pipeline builds the loop tree from a modified Tarjan reducibility test and annotates
each block with loop nesting depth.

**Induction variables via the SSA graph.** SSA Book ch. 10 does not need the CFG at all. A
loop shows up in the SSA graph as a `φ` whose definition refers to itself through a circuit:

```
i ← φ_entry(3, i + 1)          # loop-φ: one invariant argument, one self-reference
k ← φ_exit(i ≥ N, i)           # close-φ: first value of i satisfying the exit condition
```

Two `φ` kinds are needed and vanilla SSA has only the first. `φ_entry` carries an invariant
argument plus a self-reference; `φ_exit` closes the set of uses of names defined in the loop
and, in the book's extension, records the exit predicate, which plain SSA pretty-printing
loses. Canonical form limits `φ_entry` to two arguments and `φ_exit` to one.

Stride detection is then finding strongly connected components of the SSA graph by traversing
use-def chains and noticing that some definitions are visited twice. For a self-referring
chain, the step is the overall effect of one iteration on the loop-`φ`. When the step depends
on another cyclic definition, analyze the inner cycle first. Some SCCs cannot be characterized
at all and the recursion must be cut, and the book gives the case:

```
a ← φ_entry(0, b)      c ← φ_entry(1, d)
b ← c + 2              d ← a + 3
```

Two inter-dependent circuits, the first stepping by `c + 2` and the second by `a + 2`, which
loops endlessly unless detected.

Results are translated to *chains of recurrences* `{base, +, step}_x`, where `x` names the
loop. The analysis is deliberately two-phase: first derive `{c0, +, s}_x` with the step left
symbolic, then instantiate, and if `s = {c1, +, c2}_x` the result is a higher-degree polynomial
`{c0, +, c1, +, c2}_x`. Instantiation covers induction variables in outer loops, the last value
of a preceding loop's counter, and loop invariants defined earlier; anything outside the region
stays a symbolic parameter. Trip count is the minimal integer solution of a Diophantine
inequality, and applying `φ_exit` to it gives the exit value. The book works a nested example
where `x4 = φ¹_exit(i < N, x1) = {0, +, M}_1(N) = M × N`.

**The cheap alternative, which we may already be getting for free.** ABCD needs no induction
variable pass. Its `active[v]` mechanism compares the propagated constant against its value one
cycle ago during the demand-driven proof walk; a strict increase along a cycle means unbounded
growth, an *amplifying* cycle, and the walk cuts there. Harmless cycles are broken automatically
at `max` vertices, because every cycle in the inequality graph comes from cyclic control flow
and therefore contains a `φ` with an argument defined outside the cycle, where
`v₁ ≤ max{v₂, v₁+c} = v₂`. So the discrimination between "index advances without bound" and
"index is bounded by a loop-invariant" falls out of the bounds-check query itself.

**Range derivation without either, by abstract interpretation.** Cousot and Cousot's widening
plus narrowing over the interval domain gives loop index bounds directly from the fixpoint.
Widening on the selected `W-arcs` forces termination; the descending narrowing pass is what
turns `[1, +∞]` into `[1, 101]`, so skipping narrowing forfeits most loop-bounds checks. Their
widening-with-declared-bounds hint is the ancestor of Miné's widening with thresholds, a dense
ramp of a few dozen values that Astrée reused untuned across all its analyses. Implement
thresholds before the plain `-∞/+∞` form.

**Hoisting and sinking, as placement rather than as a loop transformation.** Click's Global
Code Motion is the cleanest formulation. Schedule early (post-order DFS over inputs, seeded
from pinned instructions, place each instruction in the block of its deepest-dominator-depth
input), schedule late (post-order DFS over uses, LCA in the dominator tree of all use blocks),
then walk the dominator-tree path between the two and keep the *deepest block at the
shallowest loop nest*. Outside as many loops as possible, then on as few paths as possible.
Selection happens during the late walk rather than after it, because placing one instruction
changes the latest legal block for its inputs. One detail is easy to get wrong and it is what
makes loop-carried values behave: for a `φ` use, the use site is not the `φ`'s block but the
CFG predecessor matching that operand index.

# Preconditions

Recognition on a CFG needs reverse postorder, so a DFS. Correctness of the iterative dominance
solver is independent of reducibility but its running time is not; on irreducible graphs the
pass count depends on the spanning tree the DFS produced. The chains-of-recurrences analysis is
restricted to reducible loops, and the two-pass liveness and loop-nesting-forest `DF+` schemes
assume reducibility too, each with an irreducible variant costing one extra concept rather than
a blowup. Scheme produces irreducible control flow more readily than Java does, since tail calls
and `call/cc`-shaped control are not bound to structured loops.

Loop-closed SSA is the structural precondition for naming an exit value at all. SSA Book 6.2.3
places a function at the *head* of the loop it exits so that its parameter survives parameter
dropping. Our nanopass IR is already in the functional form ch. 6 describes, so what we
implement is the inverse reading of that chapter, and the `φ` we cannot drop is exactly a
loop-carried value.

GCM needs SSA, explicit memory dependence edges, explicit control inputs on faulting
instructions, and CFG shaping first (split control-dependent edges, insert loop landing pads).
Without the shaping there is often no block to sink into.

Where induction variable analysis fails: a multiply or a non-constant stride makes ABCD's
variable unconstrained and the check unprovable. Chains of recurrences handle polynomial
strides but not arbitrary ones.

# Cost

Dominance is effectively free. Cooper, Harvey and Kennedy measure the iterative version at
about 2.5x Lengauer-Tarjan on real CFGs, with the crossover near 30,000 nodes against a
744-block largest real CFG timed at one hundredth of a second, and they say plainly that on
real programs the choice does not affect compile time. Their dominance frontier routine is five
lines and 25-33% faster than the Cytron formulation.

GCM is near-linear, with `Find_LCA` a naive walk that is O(n) worst case and small in practice.
Measured on 52 procedures from Spec89 plus cplex, GVN-GCM beats one round of GCF+PRE+CCP by
4.3%, or 5.9% with reassociation first. That number is an upper bound and should be read as
one: ILOC's simulated machine has infinite registers and one-cycle latency for everything
including loads, which erases GCM's largest real cost, since early scheduling creates enormous
live ranges and aggressive hoisting raises register pressure. Read the per-procedure table too.
`doduc/parol` gets 23.3%, but eight procedures are negative, `cplex/xielem` at -24.4%.

ABCD costs under 10 `prove` invocations per check, about 4ms per check, removing 45% of dynamic
upper-bound checks for roughly 10% speedup. The authors call that speedup lower than expected
and attribute it to Jalapeño lacking the downstream optimizations, global code motion in
particular, that check removal is supposed to unblock.

Precision given up: GCM is explicitly not optimal and lengthens some paths. Hoisting
control-dependent code out of a loop wins if the loop runs at least once, and usually it does,
but this is a heuristic and it is stated as one.

# Disagreements

**Whether a dedicated induction variable pass is needed at all.** The SSA Book builds a full
chains-of-recurrences analysis with symbolic step instantiation and Diophantine trip counts.
ABCD gets the same discrimination as a side effect of its amplifying-cycle detection, with no
IV pass. The book's version is strictly more informative (it produces a trip count, which ABCD
does not, and a trip count is what stage 10 needs to choose an unroll factor). ABCD's is
strictly cheaper. Both are right about different clients, and the resolution for us is that if
we build ABCD for stage 06, stage 07 is thinner than the CUJ plans, but it does not disappear,
because the vectorizer wants the number ABCD never computes.

**Whether the hoisting machinery belongs in a nanopass compiler.** Click's central trick is
that GVN deliberately produces an *incorrect* program (instructions placed nowhere) which GCM
then repairs. Nanopass wants every pass to produce a well-formed term in a declared output
language, and a pass whose output is provably incorrect until a later pass fixes it cannot be
typed that way honestly. The output language would have to admit unplaced instructions, which
is the sea of nodes, not a Scheme core language. The honest encoding is a distinct intermediate
language where placement is genuinely optional. That is a real cost and the placement heuristic
is separable from it.

**Whether Chez has loop handling.** `docs/CHEZ-ANALYSIS.md` says Chez has no loop recognition
pass, on grep evidence over `s/*.ss` for `induction`, `loop-invariant`, `licm` and `hoist`. The
ICFP retrospective lists "optimizing letrec expressions and loops" among Version 2's features
and says the same in prose, so Chez has *some* loop handling. The defensible claim is narrower
and still useful: Chez has no *classical* loop optimizer, meaning no induction variable
analysis, no strength reduction, no unrolling, no bounds-check elimination, no vectorization,
and the paper is silent on them rather than reporting them as attempted and rejected. Dybvig's
compile-time payback rule is a general filter that such passes would not survive, which is why
this is our opening and why it is structural rather than accidental.

**Our copy of the SSA Book is a 2018 unfinished draft, and the gap lands here.** Two figures in
ch. 10's stride-detection walkthrough fail to render. §10.2.1 ends with "Warning: Low quality
figure! Please compile with tikz." and a truncated caption reading only "Fig. 10.1 Detection of
the", and the following page carries "TODO: Missing figure ! Please compile with tikz." The
surrounding prose then walks through parts (a), (b) and (c) of Figure 10.1 to explain how a
`φ` argument is followed to an invariant definition, how a longer use-def chain is traversed
until a `φ` is reached, and how the search restarts over unanalyzed uses until the original `φ`
is found, yielding the step "+e". §10.2.3 refers back to the same figure for the instantiation
`{a, +, e}_1 → {3, +, e}_1 → {3, +, {8, +, 5}_1}_1`. **The prose is readable; the worked
example it narrates is not present in our copy.** Do not reconstruct that figure from the
prose. If we implement the SCC traversal, take it from the algorithm text and Pop's thesis
(reference [240] there), and re-derive the walkthrough on our own example. The rest of the
draft's damage is documented in the work entry: Lorem-ipsum dedication, a one-line foreword,
"Chapter ??" cross-references, and untranslated editorial notes between the authors. The
algorithms and pseudocode are finished and trustworthy; the scaffolding is not.

# For us

Stage 07, and it gates more than the CUJ credits it with. Stage 06 can prove a check locally
without it, but cannot hoist. Stage 10 cannot pick an unroll factor without a trip count, and
Larsen and Amarasinghe's `applu` failure (22.56% vectorizable at 256 bits collapsing to 0.01%
at 1024 bits because the unroll factor exceeded the dynamic trip count) is exactly what happens
when a vectorizer guesses. Take the unroll factor from stage 07's estimate and always keep a
scalar remainder loop.

Implement in this order. Recognize the `letrec`-in-tail-position loop shape first, because it
is the cheap 90% and needs no CFG. Identify induction variables as parameters whose argument
at the recursive tail call is the parameter plus a constant, which is the degenerate case of
the SCC traversal and enough for nbody and fannkuchredux. Derive the range from the loop guard:
if the body is `(if (fx<? i n) ... (loop (fx+ i 1)))` then `i ∈ [i₀, n)` throughout. Only then
consider chains of recurrences, and only if a benchmark needs a symbolic or polynomial stride.

Take GCM's placement rule verbatim for hoisting, including the sinking half. For a check we
cannot hoist, sinking it onto the cold path is the next-best outcome and falls out of the same
dominator-tree walk at no extra cost. Take the pinning discipline as an IR invariant rather
than an optimization: checked accesses, allocations, and anything that can raise get an
explicit control input so motion is only ever downward.

One correctness trap worth stating separately, because it is easy to get backward when a single
code path handles both `if` merges and loop headers. Joining at a `letrec` loop header must take
the *weakest* bound, not the strongest. Along one path a variable is bounded by the strongest
constraint; across paths, by the weakest. ABCD encodes this as the min/max vertex split and it
is a soundness condition, not a precision tuning knob.
