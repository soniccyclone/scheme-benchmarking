---
type: technique
title: Equality saturation and the phase-ordering problem
description: Keeps every rewritten form of a program in an e-graph and extracts the cheapest at the end, so rewrite order stops mattering; absorbs phase ordering, whose three cheaper answers are fusion, separation, and online transformation.
tags: [equality-saturation, e-graphs, phase-ordering, rewriting, congruence-closure]
sources:
  - resource: /works/willsey-et-al-egg-fast-and-extensible-equality-saturation-.md
  - resource: /works/click-global-value-numbering-and-code-motion.md
  - resource: /works/wegman-zadeck-constant-propagation-with-conditional-branch.md
  - resource: /works/waddell-dybvig-fast-and-effective-procedure-inlining-sas-1.md
  - resource: /works/keep-hearn-dybvig-optimizing-closures-in-o-0-time.md
  - resource: /works/leroy-unboxed-objects-and-polymorphic-typing-popl-1992.md
  - resource: /works/cousot-cousot-abstract-interpretation-popl-1977.md
implemented_by: []
absent_from: [/implementations/chez.md, /implementations/sbcl.md]
pipeline_stage: 11-select
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

Passes destroy each other's opportunities. Strength reduction rewrites `(a*2)/2` into a shift and
kills the cancellation. Inlining invalidates the flow information that justified it, so the
analysis has to be re-run (Ashley's finding, reported by Waddell and Dybvig). Closure elimination
creates unreferenced variables and aliases, so it must either run to a fixpoint with copy and
constant propagation or be scheduled after them and re-run. The usual response is to pick an order,
run some passes twice, and stop asking. Equality saturation's pitch is that you can stop ordering
passes entirely: apply every rewrite, keep every result, and choose at the end.

# Mechanism

**The data structure.** An e-graph is a triple `(U, M, H)`: a union-find `U` over e-class ids, a
map `M` from canonical id to e-class (a set of e-nodes), and a hashcons `H` from canonical e-node
to id. An e-node is a function symbol plus a list of child e-class ids. E-classes have identity;
e-nodes do not. Two invariants: congruence (the equivalence over e-nodes is closed under
`f(a_i) ~ f(b_i)` when `a_i = b_i`) and hashcons consistency.

**Rebuilding is the contribution, and it is about *when*, not *what*.** Traditional maintenance is
upward merging: each e-class keeps a parent list, and `merge` recursively re-canonicalizes and
re-hashconses parents, possibly merging further. Cost is dominated by this, and the traced paths
overlap substantially when merges arrive in bursts. Equality saturation, unlike an SMT solver,
never backtracks, so the congruence invariant does not have to hold continuously.

```
merge(a, b):   union in U; push the new id onto worklist; return
rebuild():     drain the worklist in chunks
                 canonicalize and deduplicate each chunk
                 repair(c) on each survivor
repair(c):     rewrite hashcons entries for c's parents
               deduplicate the parent map, merging newly congruent parents
               (which pushes back onto the worklist)
```

Termination and correctness: let `I` be the incongruent-pair set and `W` the worklist; each
`repair` decreases `(|I|, |W|)` lexicographically, so rebuild terminates with congruence restored.
Calling `rebuild` immediately after each `merge` reproduces the traditional behavior exactly, so
this is a generalization. Two worked cost cases: merging `x` with `y_1..y_n` when `f_1(x)..f_n(x)`
exist takes O(n^2) hashcons updates eagerly and O(n) deferred; a group of `w` terms each nested `d`
deep takes O(wd) `repair` calls eagerly and O(d) deferred, because after deduplication the worklist
holds exactly one class per layer.

**The part that actually addresses phase ordering** is the restructured saturation loop, and it is
independent of e-graphs. Iterate: e-match every rule against the *frozen* e-graph collecting
`(rule, subst, eclass)` triples; then apply all of them; then `rebuild()` once. The read phase and
the write phase are separated, and that is what makes results independent of rule ordering. The
traditional interleaved loop is not order-independent when saturation is not reached.

**E-class analyses** are abstract interpretation lifted to the e-class level, which is where our
domains would attach. An analysis is `(D, make, join, modify)` with `D` a join-semilattice.
`make(n)` abstracts a new e-node from its children's data, `join` merges data when e-classes merge,
`modify(c)` may write back into the e-graph and must be idempotent. The invariant is that each
class's datum is the join of `make(n)` over its e-nodes. Maintenance folds into `repair`: after
parent deduplication, re-`make` each parent and join into its data, pushing it back on the worklist
if the data changed. Constant folding falls out with `D = Option<Constant>`, `make` as the
abstraction function and `modify` as the concretization that adds the folded constant e-node back
into the class. Extraction with a local cost function is itself an analysis over
`(best e-node, cost)`. Rewrites generalize to an `apply` function that sees the analysis data,
giving conditional rewrites (`x/x -> 1` when the class is provably nonzero) and dynamic rewrites.

# Preconditions

The workload must be additive and backtrack-free. An SMT solver cannot use deferred rebuilding at
all.

The analysis domain must genuinely be a join-semilattice with an idempotent `modify`. The paper
says plainly that egg will fail to restore the invariant or fail to terminate otherwise, and it
does not check. Our interval domain is a lattice but needs widening for termination, and widening
is not a join; Cousot's widening is applied only at loop-head arcs, and there is no loop head in an
e-graph. That mismatch is not addressed anywhere in the paper.

The extraction cost function must be **local**: a term's cost a function of its symbol and its
children's costs. Any cost model with sharing, register pressure, or scheduling in it is not local.
The paper points at pseudo-boolean solvers and ILP for those without endorsing them.

Binding is unsolved. The lambda example uses explicit substitution rewrites and is called "rather
high in performance cost," with better binding support listed as future work. Alpha-equivalence is
not free.

# Cost

88x geometric mean on congruence maintenance and 21x on whole runs across 32 tests, with the
speedup growing with problem size. Herbie's simplification went from 5022 minutes (98% of run time)
to 1.4 minutes. Verifying TASO's synthesized equalities: Z3 at 24.65s, egg at 1.56s and 0.52s
batched. The library is roughly 5000 lines of Rust, generic over language, analysis and cost
function.

Read the attribution carefully. Figure 12 decomposes Herbie's 3000x: 5022 to 49.4 minutes from
*batching*, 49.4 to 22.4 from deferred rebuilding, 22.4 to 1.4 from switching to Rust. Attributing
the whole 3000x to rebuilding is wrong. The isolated rebuilding contribution is the 88x/21x on
egg's own test suite, and that suite is two applications, a small CAS and a lambda partial
evaluator, which is a thin basis for an asymptotic claim. No theoretical analysis of rebuilding in
the online setting is offered.

The cost the abstract does not mention is blowup. Expansive rules such as associativity and
distributivity grow the e-graph exponentially, which is why egg ships a backoff scheduler that
temporarily bans rules matching in exponentially growing numbers of locations. That is a heuristic,
not a bound, and it means saturation is usually not reached in practice.

# Disagreements

The sources agree on the diagnosis and disagree completely on the cure. Four positions.

**Saturate.** Willsey et al. Keep every form, extract at the end. Works, for a *local algebraic*
rewrite set over straight-line expressions. The paper offers no story for control flow, loops, or
effects beyond "Tate's PEGs are a user-defined language you could port," and the claim to dissolve
phase ordering should be read as scoped to that fragment.

**Separate.** Click's answer is the opposite architecture. Let the optimizer produce an
*intentionally illegal* program (value numbering places instructions nowhere) and reconstruct a
legal schedule afterward with a two-pass dominator-tree scheduler. Global value numbering then
collapses to the local hash-table algorithm with basic-block boundaries deleted: one linear pass, no
fixpoint, no search. Click's own reading of his 4.3% average win is the honest one and it cuts
against the whole framing: GVN-GCM beats *one* round of GCF+PRE+CCP by 4.3% and *two* rounds by
2.4%, so most of the win was a phase-ordering artifact of the competition rather than a stronger
analysis. His durable claim is "comparable results, far simpler implementation, one pass," and his
measurements come from a simulated machine with infinite registers and one-cycle latency for
everything, so treat 4.3% as an upper bound.

**Fuse.** Wegman and Zadeck's SCCP does constant propagation and unreachable-code elimination
*simultaneously* in one worklist fixpoint, precisely because doing them in sequence loses
information in both orders. That is why Click's second round of GCF+PRE+CCP closed half his gap.
Fusion is far cheaper than saturation, gives a complexity bound (each SSA edge examined at most
twice), and needs no extraction step. It only works for passes whose lattices compose, which is a
real restriction, but our stages 05 and 06 are exactly such a pair.

**Transform online.** Waddell and Dybvig argue that any offline decision procedure must *estimate*
what subsequent optimization will do, and that both directions of error hurt. Their inliner instead
performs the transformation speculatively, measures the actual optimized residual, and aborts on an
effort or size budget. Chez's whole design follows this, and Dybvig's stated reason for the fixed
cutoff is that "heuristics inevitably inhibit or allow more inlining than they should." This is a
search too, but with a linear-time guarantee obtained from a fixed number of sites times a fixed
budget, which is the property egg's backoff scheduler does not have.

**Not every ordering hazard is real, and this is worth checking before building anything.** Leroy
shows that inlining a polymorphic function either creates `wrap(unwrap(a))` redexes that cancel, or
(if done first) gives the callee a more specific type and better representations. Either order
pays. Keep, Hearn and Dybvig's closure cascade is the opposite case, a genuine one: eliminating a
closure creates unreferenced variables, replacing a one-free-variable closure with its variable
creates aliases, and sharing creates more aliases, so the pass must run to fixpoint with
copy/constant propagation or be re-run. Chez does the latter and handles the residue in-pass.

**The packaging claim is not a technical one.** "The first general-purpose, reusable e-graph
implementation" is about the library, not the data structure. The congruence algorithm is Downey,
Sethi and Tarjan (1980) rearranged; the paper says so in related work and states its contribution
precisely as "not how it restores the invariants but when."

# For us

The honest read is narrow. Stages 05 through 07 are abstract interpretation over a CFG. E-class
analyses are the right *shape* only in the sense that both are semilattices, and the widening
mismatch above means our interval domain does not drop into the interface as written.

Two places it plausibly pays. First, an algebraic simplifier over the pure numeric fragment between
stage 04 and stage 05, which is exactly where the classic hazard bites and where the rewrite set is
local, algebraic, and over straight-line expressions, the fragment the paper's own claims cover.
Second, stage 11, if instruction selection is expressed as rewrites with a local cost model. That is
tree-pattern matching with a saturated search instead of a greedy one, and the cost model at that
level (instruction counts and immediate forms) is closer to local than anything higher up. A Scheme
compiler's *real* cost model, involving allocation, closure creation and register pressure, is not
local, so treat this as a candidate for a sub-optimizer and never for the whole of phase 7.

Three mechanisms are worth stealing without adopting e-graphs at all. The read-phase/write-phase
split makes any rewrite engine order-independent and costs nothing to adopt. The deduplicating
worklist is a general amortization trick for restoring any invariant in any pass. And `modify` as
concretization is the pattern that would let our interval domain feed a rewriter: a class proven to
hold a constant gets that constant inserted as an e-node, and every downstream rewrite sees it for
free.

Before committing, size it against the cheaper answers. Wegman-Zadeck-style fusion of stages 05 and
06 is a smaller change with a complexity bound, and Waddell-Dybvig's effort-and-size counter pair is
the shape our stage 10 vectorizer wants regardless. Egg is the most expensive answer to the
smallest version of the problem we have.
