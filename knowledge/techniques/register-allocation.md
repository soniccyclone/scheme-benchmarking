---
type: technique
title: Register allocation
description: Map unbounded virtual registers onto a fixed machine register file and decide what to spill, using either a flattened interval scan, a dominator-tree scan, or a coloring of the interference graph.
tags: [register-allocation, liveness-analysis, live-intervals, graph-coloring, linear-scan, spilling]
sources:
  - resource: /works/george-appel-iterated-register-coalescing-toplas-1996.md
  - resource: /works/poletto-sarkar-linear-scan-register-allocation-toplas-1999.md
  - resource: /works/wimmer-franz-linear-scan-register-allocation-on-ssa-form-c.md
  - resource: /works/burger-waddell-dybvig-register-allocation-pldi-1995.md
  - resource: /works/rastello-et-al-ssa-based-compiler-design-the-ssa-book.md
  - resource: /works/keep-dybvig-nanopass-preprint.md
  - resource: /works/dybvig-et-al-the-development-of-chez-scheme-icfp-2006.md
implemented_by: [/implementations/chez.md, /implementations/sbcl.md]
absent_from: []
pipeline_stage: 12-regalloc
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

Which virtual registers can share one of K machine registers, and which values go to memory
when they cannot. We ask it twice over independent files: GPRs for tagged values and untagged
integers, `xmm`/`zmm` for unboxed f64. Two sub-problems fold in here rather than standing
alone. *Liveness* is "where is v live," and *live interval analysis* is the choice of shape for
that answer: one interval, intervals with holes, or a dominator subtree. The shape decision
determines everything downstream, so it is the allocator design, not a separate pass.

# Mechanism

**Liveness, three costs.** Burger, Waddell and Dybvig track liveness of *registers* rather than
variables, as an n-bit machine integer: union is `or`, intersection `and`, singleton a shift,
computed bottom-up over the AST. Wimmer and Franz get variable liveness with no fixed point,
given SSA and a block order where every predecessor precedes its block except across back edges
and all blocks of a loop are contiguous:

```
for each block b in reverse order:
  live = union of successor.liveIn over successors of b
  for each phi in successors of b: live.add(phi.inputOf(b))
  for each opd in live: intervals[opd].addRange(b.from, b.to)
  for each op in b, reverse:
      for each output opd: intervals[opd].setFrom(op.id); live.remove(opd)
      for each input  opd: intervals[opd].addRange(b.from, op.id); live.add(opd)
  for each phi of b: live.remove(phi.output)
  if b is a loop header:
      for each opd in live: intervals[opd].addRange(b.from, lastBlockOfLoop.to)
  b.liveIn = live
```

A use is always seen before its definition in this order, so the over-long range opened at the
block head is trimmed by `setFrom`; the loop fixup replaces the fixed point with one spanning
range. SSA Book ch. 9 is the third route: post-order over the back-edge-free CFG, then push
loop-header live sets down the loop nesting forest, redirecting each edge `s→t` to `t.OLE(s)`
for irreducibility.

**Interval scan.** Poletto and Sarkar give each variable one interval `[i,j]`, holes ignored,
and sweep in increasing start point with an `active` list keyed on increasing end point. On
overflow evict the interval in `active` ending furthest away. O(V) for fixed R, O(V log R) with
a tree for `active`. Forty lines, correct back end immediately.

**Tree scan.** Under strict SSA every live range is a dominator subtree, so the interference
graph is chordal (Gavril 1974), greedy coloring is exact, and `Maxlive` is the exact register
requirement. Tree scan (SSA Book Alg. 22.1) walks the dominance tree, frees colors at last
uses, picks any free color at each definition; at a definition at most `Maxlive - 1` others are
live, so a color always exists. The book decouples the phases: spill until `Maxlive ≤ R`, then
assign, and assignment cannot fail.

**Coalescing.** George and Appel's contribution is one edge in a state machine: run `simplify`
before `coalesce`, then loop back. Briggs's conservative test was being applied to the wrong
graph; after simplification the neighbors' degrees have dropped and the same test passes. The
safety argument is three sentences. Nodes removed during simplify are colored after everything
left in G', so they cannot constrain colors in G', so conservative coalescing inside G' cannot
affect G's colorability. `freeze` (abandon the moves of a low-degree move-related node) makes
the loop terminate and removes the need for biased coloring. Precolored registers get a
per-neighbor test instead, since their adjacency lists are deliberately not materialized:
`OK(t,u) = degree[t] < K ∨ t ∈ precolored ∨ (t,u) ∈ adjSet`, applied to every `t ∈ Adjacent(v)`.
`adjSet` is a hash table of integer pairs, 256KB against 1MB for a half-matrix at n ≈ 4000.

**Save placement, orthogonal to all of the above.** *Effective* leaf routines, those making no
call on the path actually taken, are over two thirds of Scheme activations against under a
third for syntactic leaves. So save exactly when a call becomes inevitable. `St[E]` and `Sf[E]`
are the registers to save if `E` evaluates true and false, with `R` standing for an impossible
path so it imposes no constraint through the intersection:

```
St[true]=∅   Sf[true]=R      St[false]=R   Sf[false]=∅
St[call]=Sf[call]= { r | r live after the call }
St[(seq E1 E2)] = (St[E1] ∩ Sf[E1]) ∪ St[E2]
St[(if E1 E2 E3)] = (St[E1] ∪ St[E2]) ∩ (Sf[E1] ∪ St[E3])
Sf[(if E1 E2 E3)] = (St[E1] ∪ Sf[E2]) ∩ (Sf[E1] ∪ Sf[E3])
```

Add a caller-save return-address register `ret` and "E inevitably calls" is
`ret ∈ St[E] ∩ Sf[E]`. **That criterion is wrong in the ACM proceedings.** Our PDF is a
corrected version: page 5, footnote 2, "This was in error in the proceedings," attached to
exactly that condition. Implement from our copy, not the published page image.

# Preconditions

Coloring needs real liveness, K uniform registers, and a precolored-node story. Linear scan
needs a total instruction order and virtual registers in the IR; Poletto and Sarkar state
plainly that precolored registers are awkward, because coarse intervals let two intervals
needing the same physical register overlap, and that the honest fix is to become binpacking.
Wimmer and Franz need strict SSA at the allocation boundary plus both block-order properties,
and their construction is *wrong* on irreducible loops, missing a value entering through the
second entry; they dodge it by keeping conservative phis at those headers, which works only
because HotSpot does not prune them. Tree scan needs strict SSA with phis present, so allocate
before destroying SSA or chordality buys nothing, and `Maxlive ≤ R` is sufficient only on an
idealized machine (two-address instructions, ABI pinning, register pairing and memory-operand
restrictions can force extra spills). Burger's scheme needs assignment conversion done, tail
calls treated as jumps, and argument evaluation order still free at allocation time, which is
what forces liveness, shuffling and allocation into one pass.

# Cost

Poletto and Sarkar against George-Appel coloring: fpppp 1.02, li 1.10, espresso 1.18, wc 1.43.
Repeat that qualified spread, not the "within 12%" headline. At 512 simultaneously live
variables their coloring compile time is over 600x linear scan's. George and Appel leave 16% of
moves against 37% for one-round conservative coalescing plus biased selection, code size down
5%, run time down 4.4%. Wimmer and Franz save 13-19% of back-end time and delete 200 lines.
Burger's allocator is 7% of compile time in two linear passes, removing 72% of stack references
for 43% average speedup, though the four large programs sit at 22-47% and the mean is pulled by
tiny call-recursion benchmarks.

Precision surrendered: plain linear scan gives up lifetime holes, live-range splitting and
coalescing, so a variable defined before a loop nest and used after it holds a register through
the whole nest. Tree scan gives up nothing over coloring on SSA input. Coalescing under SSA is
unavailable by construction; register hints on phi inputs and outputs substitute.

# Disagreements

**The linear-scan-versus-graph-coloring framing is wrong**, per SSA Book ch. 22. Linear scan
*is* tree scan with the dominance tree flattened into a linear interval, and that flattening is
exactly what produces its over-approximated live ranges. Tree scan strictly dominates it:
simpler, same memory profile, exact rather than over-approximating, same cost. On SSA input the
classical simplify scheme is already exact, so the two converge rather than trading off.
`docs/phases/07-compiler/CUJ.md` has been corrected to match and this document agrees with it.
Poletto and Sarkar predate the chordality result, so this is a superseded framing surviving in
folklore rather than a live dispute.

Chez disagrees with itself across twenty years. Dybvig rejected coloring in 1991 on two grounds,
that it gives no special help for calls and that its compile time was unacceptable for
interactive use. Keep and Dybvig moved to coloring with move biasing in 2013 and called it "the
biggest contributing factor" in a 15-27% speedup. That measurement bundles the allocator with
the entire nanopass rewrite, the authors say they lacked resources to separate them, and the new
allocator *dropped* lazy saves for a cost heuristic that "sometimes underperforms the original."
The "no special help for calls" objection still stands, and it is the one the Fortran-derived
allocation literature never answers.

Smaller conflicts between claim and evidence. Wimmer and Franz's prettiest result, that SSA
dominance makes interval-intersection tests redundant, removes 59-79% of those tests and "does
not gain a measurable speedup"; their whole win is deleting the dataflow pass and the
pre-allocation phi deconstruction. George and Appel never measured compile time against Briggs,
lacking his implementation, and their headline comparison is against a hobbled Briggs, since
real Briggs and Chaitin both produce uncolorable graphs on SML/NJ input. Burger's claim that
`St`/`Sf` placement "is never too eager" is asserted with a worked example and no proof.

# For us

Stage 12. Build Poletto-Sarkar first because it is forty lines and unblocks milestone 1, then
replace it, and treat the replacement as decided rather than open. If the IR is SSA at the
stage 11/12 boundary, build tree scan and take Wimmer-Franz's construction for liveness. If it
is not, Burger-Waddell-Dybvig fits a nanopass tree IR better than either, since it never leaves
the AST. Run the allocator once per register file with its own R; the two files are independent
and both chordal under SSA.

The acceptance test is unchanged: count spills in the emitted inner loop, and if any unboxed f64
spills across the loop body the allocator is erasing the analysis. Plain linear scan fails this
and its spill heuristic makes it worse, because the interval ending furthest away in a
vectorized loop is typically the loop-carried accumulator or an array base pointer, and Belady's
argument assumes one definition and one use. The SSA Book's answer is
`spill_profitability(v,p) = Σ_{q ∈ v.HP(p)} freq(q)` over points where v is live and pressure
exceeds R, plus the loop-header rule (Alg. 22.4) seeding `in_regs` from scratch capped at
`R + |livein| - L.Maxlive`, so a live-through unboxed float dies before the loop rather than
reloading every iteration.

Two things transfer whichever allocator wins. `St`/`Sf` is a general answer to "does this
expression inevitably do X," the shape stage 07 needs for hoisting and stage 08 for escape, and
the `R`-for-impossible-paths trick is the reusable part. And George and Appel's section 4
pressure profile is ours: known-call-site procedures with custom parameter temporaries, free
variables passed in registers, representation analysis spreading a tuple across registers.
SML/NJ *regressed* going from three to six callee-save registers until the allocator got good at
copy propagation, so if our closure representation gets aggressive and performance goes the
wrong way, check coalescing quality before redesigning closures.
