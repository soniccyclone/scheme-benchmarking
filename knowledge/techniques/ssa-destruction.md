---
type: technique
title: SSA destruction
description: Lowers phi-functions to real copies without hitting the lost-copy or swap bugs, then coalesces almost all of those copies away using value-based interference.
tags: [ssa-destruction, phi-isolation, parallel-copy, coalescing, register-allocation]
sources:
  - resource: /works/rastello-et-al-ssa-based-compiler-design-the-ssa-book.md
  - resource: /works/cytron-et-al-efficiently-computing-ssa-toplas-1991.md
  - resource: /works/wimmer-franz-linear-scan-register-allocation-on-ssa-form-c.md
  - resource: /works/braun-et-al-simple-and-efficient-construction-of-static-si.md
  - resource: /works/appel-ssa-is-functional-programming-1998.md
  - resource: /works/george-appel-iterated-register-coalescing-toplas-1996.md
implemented_by: []
absent_from: [/implementations/chez.md]
pipeline_stage: 12-regalloc
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

A phi-function is not a machine instruction. Before code generation it has to become real
copies. The naive lowering is two lines and it is wrong, and even when it is right it
leaves a function full of register-to-register moves that nothing downstream removes. The
engineering question is: what is the correct lowering, what does it cost, and how do the
copies get removed again.

# Mechanism

**The naive version and why it breaks.** Cytron's TOPLAS Section 7 replaces each k-input
phi with k ordinary copies at the ends of the predecessors. Two failure modes, both named
in the SSA Book's chapter 21. In the *lost-copy problem*, the phi's result `a0` is used in
a successor of some `Bi != B0` and the edge `Bi -> B0` is critical, so the copy lands
somewhere it also reaches the other successor. In the *swap problem*, `a0` is used in `B0`
as an argument to another phi; phis have parallel semantics, so `a0` is dead before `a_i'`
is defined, but sequentializing the copies blindly extends `a0`'s live range past that
definition and renaming then produces wrong code.

**Fix one, splitting.** Split every critical edge, then emit a *parallel copy* pseudo
instruction at the end of each predecessor (Algorithm 3.5 in the draft). Correct, simple,
and it fails whenever an edge cannot be split.

**Fix two, phi isolation.** Treat uses and definition symmetrically. Insert one empty
parallel copy at the top of every block and one at the end of every block. For each
`a0 = phi(B1: a1, ..., Bn: an)`, add `a_i' <- a_i` to the parallel copy at the end of `Bi`,
add `a0 <- a0'` to the parallel copy at the top of `B0`, and rewrite the phi over the primed
names. Isolating the *result* is what removes the requirement to split critical edges. All
the `a_i'` can then be coalesced and the phi deleted.

**Normalizing machine constraints.** Rewrite *operand* pinning into *live-range* pinning by
wrapping the operation in parallel copies to and from pre-colored temporaries. Then compute
`pin-phi-webs` by union-find over phi arguments and shared physical resources (Algorithm
21.2, the generalization of the classic phi-web discovery in Algorithm 3.4). A variable and
a physical resource do not interfere; two distinct physical resources do. Any interference
surviving inside a web is a strong interference that copy insertion cannot fix, and it must
be reported rather than papered over.

**Removing the copies.** This is the part that decides code quality, and the enabling trick
is value-based interference. Under strict SSA, "carries the same value" is an equivalence
relation computable in one dominance-order traversal that folds copies: `V(b) = V(a)` for
`b <- a`, otherwise `V(b) = b`. Then

    interfere(a,b)  <=>  intersect(a,b) and V(a) != V(b)

and `intersect` reduces, by the dominator-subtree property of strict-SSA live ranges, to
"one definition dominates the other and the dominated definition point lies inside the
other's live range". That is a liveness *check* query. No liveness sets, no interference
graph.

Coalescing then runs backwards as de-coalescing: optimistically merge everything
copy-related, traverse each merged set once in dominance pre-order maintaining `idom` and
`eanc` (nearest intersecting dominator of equal value), and evict on conflict. Copies are
*virtualized*, meaning the phi itself is the placeholder for its local variables and only
the copies that survive de-coalescing are ever materialized. That is what makes the whole
thing affordable in a JIT.

**Sequentialization.** Parallel copies are kept parallel until the end, then turned into a
sequence by the windmill-farm traversal (Algorithm 21.6): `loc(a)` remembers the last place
the initial value of `a` is available, `pred(b)` the value that must reach `b`, a `ready`
list holds destinations whose old value is no longer needed, and each remaining cycle is
broken with exactly one extra temporary. Postponing sequentialization matters, because
emitting `a1 <- a2; b1 <- b2` in a fixed order introduces interference that did not exist.

**The other route: do not destroy first.** Wimmer and Franz keep SSA through linear-scan
allocation and fold deconstruction into the resolution phase the allocator already needs
for split intervals. For each CFG edge, for each interval live at the successor head: if
the interval starts exactly at the successor head it was defined by a phi, so the source is
the interval of that phi's input for this predecessor; otherwise the source is the
interval's own location at the predecessor's end. Collect, order, emit as a parallel copy.
Twenty lines added, 180 lines of pre-allocation deconstruction deleted.

**Do the dead-code pass first.** Cytron's Figure 17 marks everything dead, seeds a worklist
with `PreLive` (I/O, side effects) and propagates liveness backwards through both
`Definers(S)` and `CD^-1`, so a branch is live only when something control-dependent on it
is live. That is broader than textbook DCE, which pins every conditional live, and it
deletes phis before they become copies.

# Preconditions

The SSA must be *conventional*: every phi-web is interference-free. Freshly constructed SSA
is conventional, and destruction is then just renaming each web to one representative.
Copy propagation is what breaks conventionality, and restoring it is the entire cost.

Order relative to register allocation is forced. Strict SSA live ranges are dominator
subtrees, so the interference graph is chordal and greedy coloring is exact. Destruction
destroys the subtree property outright, so allocating after destroying buys nothing from
SSA at all.

Some edges cannot be split: abnormal edges, region boundaries, and instructions that define
values after the copy insertion point. The book's example is the PowerPC `bclr` family,
where the branch itself decrements a counter used by a phi in a successor. Phi isolation
does not save this case, and the four available fixes are all unpleasant: design the SSA
optimization more carefully, keep the counter out of SSA, change the instruction selection,
or split the edge anyway.

A block can also end up with the same predecessor twice, from copy folding followed by
empty-block elimination. There is no copy insertion that implements the control dependence
in that case; it needs predication or reinsertion of a block.

Wimmer and Franz's route needs a block order where every predecessor except back edges
precedes its block and all blocks of a loop are contiguous, and their interval construction
is *wrong* on irreducible loops. Their fix is to leave conservatively inserted phis at
irreducible headers, which works only because HotSpot does not prune them.

# Cost

The clean C-SSA path (materialize all copies, build liveness sets, build an interference
graph, coalesce, rename webs) is correct and simple and unaffordable in dynamic
compilation, because the transitional program has a substantial number of extra variables
and the liveness sets and interference graph scale with them. The virtualized path produces
the same output with neither structure.

Wimmer and Franz measured the SSA-through-allocation route at 13 to 19 percent less
back-end time on a production JIT, with the allocator 200 lines shorter and generated code
the same or marginally better. The cost is two new move categories, constant-to-stack and
stack-to-stack, both arising when a phi interval is given a stack slot at its definition;
stack-to-stack needs a scratch register or a push/pop pair. Runtime impact was below noise
except SciMark FFT at 1 percent.

The cost of skipping the coalescing is a copy storm. Cytron says so directly: naive
lowering with no coloring pass is correct and produces garbage.

# Disagreements

**Cytron Section 7 versus SSA Book chapter 21.** Cytron's lowering is precisely the
algorithm chapter 21 opens by calling incorrect. The disagreement is narrower than it
looks: Cytron's *pipeline* (dead code elimination, then coloring to coalesce, most inserted
copies becoming `V <- V` and vanishing) is right, and his *lowering step* is the naive one.
Note that only the TOPLAS journal article contains Section 7 at all; the POPL 1989 paper
does not cover translating out of SSA, so it cannot be cited here.

**Split critical edges, or isolate the phi.** Chapter 3 of the same book splits; chapter 21
isolates and demonstrates that splitting is then unnecessary. Chapter 21 is the later
answer and is the one to implement, since non-splittable edges are a real machine
constraint rather than a corner case.

**Destroy before or after register allocation.** Every production linear-scan allocator
before 2010 (HotSpot client, Jikes RVM, LLVM) destroyed SSA first, while using SSA for its
own global optimizations. Wimmer and Franz and the SSA Book's chapter 22 both say that is
backwards. Their own honest reading is worth carrying: the prettiest theoretical result,
that SSA makes the interval-intersection tests provably redundant, produced no measurable
speedup. All the compile-time win came from deleting a dataflow pass and deleting a
lowering pass.

**Aggressive versus conservative coalescing.** Aggressive coalescing before allocation
ignores colorability; conservative coalescing inside allocation preserves it. George and
Appel's iterated coalescing is the strongest version of the second option, and its result
bounds what a copy-removal pass can hope for: conservative coalescing alone kills 24 percent
of moves, iteration leaves 16 percent in the program, and 4.4 percent of execution time
comes back, credited to instruction cache rather than to the moves themselves. The SSA Book
takes the first option instead, running aggressive coalescing on conventional SSA and
adding a "brute" rule that re-runs `Simplify` to test whether a merge breaks
greedy-R-colorability. It is more expensive per query, but it removes the freeze and
unfreeze machinery that makes iterated coalescing terminate, and it coalesces more.

**Section numbers.** Our SSA Book PDF is an unfinished draft dated 8 June 2018, not the
2022 Springer edition, so chapter, section and algorithm numbers cited above will not match
the published book. The pseudocode is finished and trustworthy; the scaffolding is not.

# For us

If we ever adopt SSA we will destroy it, before scheduling and before emission, so this is
a stage 12 to 13 concern. Two things change the shape of the work for our pipeline.

First, in a functional IR the problem is stated differently and is smaller. Chapter 6.2.4
of the book puts it exactly: a functional program converts directly to non-SSA imperative
form when the argument list of every call coincides with the formal parameter list of the
callee, so SSA destruction *is* the task of making those lists coincide, achieved by
introducing `let` bindings. The local algorithm given there considers each call site
individually and avoids both the lost-copy and swap problems, scaling with the number and
size of cycles that span identically named arguments and parameters and using a single
extra variable to break each cycle. That is the windmill-farm sequentializer restated in
our own language, and it is the version we would write.

Second, if stage 12 is on SSA input we never write a standalone destruction pass at all,
because resolution absorbs it. The CUJ specifies linear scan; chapter 22 argues linear scan
is tree scan with the dominance tree flattened, and that the flattening is precisely the
source of its over-approximated live ranges. Either allocator needs the same resolution
phase, and that phase is where the phis go.

Regardless of route, keep the parallel-copy representation until the last moment and use
value-based interference for coalescing. The alternative is what the CUJ's own acceptance
test forbids: unboxed f64 values spilling across the loop body because the allocator could
not tell that two overlapping live ranges carry the same value.
