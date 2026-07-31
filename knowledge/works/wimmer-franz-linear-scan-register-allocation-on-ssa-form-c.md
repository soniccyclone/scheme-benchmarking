---
type: paper
title: "Linear Scan Register Allocation on SSA Form"
description: Runs linear scan directly on SSA-form LIR, which removes the iterative dataflow liveness pass, removes most interval-intersection tests, and folds SSA deconstruction into the existing resolution phase.
resource: knowledge/sources/wimmer-franz-linear-scan-register-allocation-on-ssa-form-c.pdf
tags: [register-allocation, linear-scan, ssa-form, liveness-analysis, jit-compilation]
authors: [Christian Wimmer, Michael Franz]
year: 2010
venue: "CGO 2010, pp. 170-179"
informs: [/techniques/register-allocation.md, /techniques/liveness-analysis.md, /techniques/ssa-construction.md]
pipeline_stage: 12-regalloc
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Every production linear-scan allocator of the era (HotSpot client, Jikes RVM, LLVM)
destroyed SSA before allocating, even though all three used SSA for their global
optimizations. This paper shows that keeping SSA through register allocation costs nothing
and buys three specific things: lifetime intervals can be built in a single backward sweep
with no fixed-point iteration, the interval-intersection loops inside the allocator become
provably redundant for un-split intervals, and phi elimination collapses into the resolution
phase that a splitting allocator already needs. Net effect on a production JIT: back-end
time down 13-19%, allocator source 200 lines shorter, generated code the same or marginally
better.

The intellectual content is small and that is the point. It is an engineering result: the
SSA dominance property is worth more to a linear-scan allocator than it is expensive to
preserve.

# Mechanism

**Precondition on block order.** The CFG is flattened to a list such that (a) every
predecessor of a block precedes it except loop back edges, which implies every dominator
precedes it, and (b) all blocks of a loop are contiguous. Operations are numbered by two in
this order.

**Interval construction (Fig. 4), one reverse pass, no dataflow.** For each block `b` in
reverse order:

```
live = union of successor.liveIn over successors of b
for each phi in successors of b: live.add(phi.inputOf(b))
for each opd in live: intervals[opd].addRange(b.from, b.to)
for each op in b, reverse:
    for each output opd: intervals[opd].setFrom(op.id); live.remove(opd)
    for each input  opd: intervals[opd].addRange(b.from, op.id); live.add(opd)
for each phi of b: live.remove(phi.output)
if b is a loop header:
    loopEnd = last block of the loop
    for each opd in live: intervals[opd].addRange(b.from, loopEnd.to)
b.liveIn = live
```

The correctness argument is that a use is always seen before its definition in this order,
so an over-long range opened at the block head is later trimmed by `setFrom`. Loops are the
one place where the successor (the header) has not been processed when the loop end is; the
fix is the contiguity property, which lets a single range spanning header-to-loopEnd stand
in for the whole fixed point. `liveIn` is a scratch structure only, and is left stale by
the loop fixup.

**Phi handling.** Phis are attached to the block label rather than given operation numbers,
because a block's phis are a parallel copy, not an ordered sequence. Consequence: all
intervals defined by phis of a block start at the same position, so the allocator gets free
choice of processing order at high register pressure, and phi intervals lose the lifetime
hole they had under pre-deconstruction (where the inserted moves created a second definition
point).

**Allocation.** The core algorithm (unhandled / active / inactive / handled, split-and-spill,
no backtracking) is unchanged from Wimmer's earlier HotSpot allocator. The saving is in
`TRYALLOCATEFREEREG` and `ALLOCATEBLOCKEDREG`: both iterate `inactive` testing intersection
with `current`, and `inactive` is not bounded by the register count. Under SSA every inactive
interval starts before `current` and has a hole at `current`'s definition, so by the
dominance property it cannot intersect. The loops are guarded by "is `current` a split
child?" and skipped otherwise, eliminating 59-79% of intersection tests. Splitting destroys
SSA, hence the guard.

**Resolution plus deconstruction (Fig. 7).** For each CFG edge, for each interval live at
the successor head: if the interval starts exactly at the successor head it was defined by a
phi, so source = the interval of that phi's input for this predecessor (or the constant
itself); otherwise source = the interval's own location at the predecessor's end. Collect
into a mapping, then order and emit as a parallel copy. Twenty lines added; 180 lines of
pre-allocation deconstruction deleted.

**Interference graphs.** The same sweep builds a graph-coloring interference graph: at each
definition, add edges to everything in `live`, plus at a loop header add edges between
everything live there and everything defined in the loop. SSA guarantees interfering values
interfere at one of their definitions, so definition points suffice.

# Applicability

Needs a real SSA IR at the register-allocation boundary and the two block-order properties.
The construction algorithm is *wrong* on irreducible loops: a value entering through the
second entry is missed in `liveIn`. Two fixes are given; the authors take the cheap one,
which is to guarantee no value flows into an irreducible loop by leaving conservatively
inserted phis at those headers. That works only because HotSpot's SSA construction is
conservative and does not prune them. If you build minimal SSA aggressively, you own the
harder loop analysis instead.

No coalescing anywhere: under SSA it would violate the form. Register hints substitute, and
are attached to phi inputs and outputs.

The costs are two new move categories: constant-to-stack and stack-to-stack. Both come from
a phi interval receiving a stack slot at its definition, which is unavoidable when a block
has more phis than the machine has registers. Stack-to-stack needs a scratch register or a
push/pop pair. Pereira's CSSA-form deconstruction avoids this at the cost of more variables.
Run-time impact is below noise on everything except SciMark FFT (1%).

# Relevance

Stage 12 is linear scan by design, and stage 11's output is the LIR analogue. If our IR is
SSA at that boundary, this is the allocator to build, not Poletto-Sarkar and not a
deconstruct-first pipeline: we get liveness for free, and the resolution phase we need
anyway for split intervals absorbs phi elimination. The block-order constraints are cheap to
satisfy in a Scheme compiler because we control CFG layout.

Two caveats specific to us. First, Scheme does produce irreducible control flow more readily
than Java does, since tail calls and `call/cc`-shaped control are not bound to structured
loops; we would land in the branch the authors avoided and need real irreducible-loop
analysis, or the conservative-phi discipline. Second, the paper's measured win is compile
time, and our stage-12 budget is not JIT-tight, so the 13-19% back-end saving matters less
to us than the fact that the allocator is *simpler* and that we can drop a whole iterative
dataflow pass.

The interference-graph note is worth keeping in reserve: if we later want coloring quality
for the numeric kernels, the same sweep gives the graph in one pass.

# Notes

Bibliographic identity confirmed from page 1: exact title, both authors at UC Irvine, ACM
author's-version notice naming CGO'10 (Toronto, April 24-28, 2010) and pages 170-179. The
slug's trailing `-c` is truncation of `-cgo-2010`, not a subtitle. No correction needed.

The honest reading of Figure 10 is that the interval-intersection elimination, which is the
paper's prettiest theoretical result, "does not gain a measurable speedup." All the compile
time comes from deleting the dataflow analysis (lifetime analysis 25-31% faster) and
deleting the pre-allocation deconstruction pass (LIR construction 19-27% faster). Resolution
gets 1-10% *slower*. So the value here is code deletion and structural simplification, and
the SSA-guarantees-non-intersection argument mostly buys confidence rather than cycles.

Also note the claim in section 8 that Mössenböck et al.'s earlier "linear scan on SSA" is
not actually on SSA: they insert phi moves into predecessors during interval construction
and keep the phi only as a placeholder. That distinction is easy to lose when reading the
literature quickly, and it is the difference between getting the dataflow-free construction
and not.
