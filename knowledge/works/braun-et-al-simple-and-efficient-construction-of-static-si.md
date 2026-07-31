---
type: paper
title: "Simple and Efficient Construction of Static Single Assignment Form"
description: Constructs pruned and (on reducible CFGs) minimal SSA lazily by demand-driven backward search, with no dominance tree, no dominance frontiers, and no liveness analysis.
resource: knowledge/sources/braun-et-al-simple-and-efficient-construction-of-static-si.pdf
tags: [ssa-construction, value-numbering, ir-construction, on-the-fly-optimization, cps]
authors: [Matthias Braun, Sebastian Buchwald, Sebastian Hack, Roland Leißa, Christoph Mallon, Andreas Zwinkau]
year: 2013
venue: "CC 2013 (venue not printed on this copy; see Notes)"
informs: [/techniques/ssa-construction.md, /techniques/dataflow-analysis.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Cytron et al. is eager and forward: collect all definitions, compute dominance frontiers,
push definitions down. That requires the program to already exist as a non-SSA CFG, plus a
dominator tree, plus a liveness pass if you want pruned form. Braun et al. invert the
direction: nothing is computed until a variable is *read*, at which point the algorithm
searches backward through predecessors and materializes phi-functions on the way. The IR is
in SSA at every intermediate moment, so peephole optimizations run *during* construction.

The result is pruned SSA for all programs, and minimal SSA (in Cytron's sense) for reducible
CFGs, from an algorithm that fits in four short procedures and depends on no other analysis.
Two extras earn their keep: a post-pass that recovers minimality under irreducible control
flow by contracting redundant phi SCCs, and a definition of redundancy stricter than
Cytron's.

# Mechanism

Two maps and a per-block state flag are the whole data structure:

- `currentDef[variable][block]` — the reaching definition, memoized.
- `incompletePhis[block][variable]` — placeholder phis awaiting operands.
- Each block is *filled* (all its instructions emitted; only then may it gain successors)
  and separately *sealed* (no further predecessors will be added).

```
writeVariable(v, b, val):  currentDef[v][b] = val

readVariable(v, b):
  if currentDef[v] has b: return currentDef[v][b]      # local value numbering
  return readVariableRecursive(v, b)

readVariableRecursive(v, b):
  if b not sealed:                # CFG still under construction
      val = new Phi(b); incompletePhis[b][v] = val
  elif |b.preds| == 1:            # common case: no phi needed
      val = readVariable(v, b.preds[0])
  else:
      val = new Phi(b)
      writeVariable(v, b, val)    # break cycles BEFORE recursing
      val = addPhiOperands(v, val)
  writeVariable(v, b, val); return val

addPhiOperands(v, phi):
  for p in phi.block.preds: phi.appendOperand(readVariable(v, p))
  return tryRemoveTrivialPhi(phi)

sealBlock(b):
  for v in incompletePhis[b]: addPhiOperands(v, incompletePhis[b][v])
  sealedBlocks.add(b)
```

The cycle-breaking line is the crux: the operandless phi is recorded as the current
definition *before* the recursive lookup, so a loop back-edge that re-reaches the block
terminates against it.

**Trivial phi removal.** `vφ : φ(x₁…xₙ)` is trivial iff every `xᵢ ∈ {vφ, v}` for one other
value `v`. Replace it by `v`, then recursively re-check every phi that used it (removal can
cascade). If there is no other value at all, the block is unreachable or is the entry block:
substitute an undef. Because the rule fires the moment operands are first set and again on
any operand change, every phi has been checked with its final arguments — which is what the
minimality proof leans on. Non-triviality checks are cached by remembering the first two
distinct witness operands.

**Minimality for irreducible flow.** A *set* P of phis is redundant iff all their operands
lie in `P ∪ {v}` for a single outside value `v`. Lemma 1: any redundant P contains a
redundant SCC (condense P, take a leaf). So compute the SCCs of the phi-induced subgraph,
process in topological order, and per SCC collect `outerOps` (operands outside the SCC) and
`inner` (phis whose operands lie entirely inside). Zero outer ops means unreachable; exactly
one means replace the whole SCC by that value; more than one means the boundary phis are
genuinely needed, so recurse on `inner`. This is Aycock-Horspool's local simplification
generalized, and it also cleans up SCCs that copy propagation creates after Cytron-style
construction.

**Complexity.** Base algorithm Θ(P + (B+E)·V), which matches the stated lower bound.
On-the-fly phi optimization O(B²V²) with the witness cache. SCC contraction
O(P + B·(B+E)·V²).

**Variants that cut temporary phis.** *Marker*: mark the block visited instead of placing a
phi, and only materialize on re-entry or on differing predecessor definitions — no temporary
phis at all in acyclic dataflow. *SCC*: use Tarjan during the recursion to find dataflow
cycles up front and place phis only at cycle entries.

# Applicability

Preconditions are about *construction discipline*, not about the program: fill before
adding successors, seal only when the predecessor set is final. Building a `while` means
sealing the header only after the back edge is added, and sealing the exit only after all
`break` edges are in. Get the order wrong and you get incomplete phis that never receive
operands.

Minimality holds only for reducible CFGs (Theorem 1, via Lemmas 2-3 and the SSA property).
Irreducible flow needs the SCC post-pass. Pruned form is unconditional, since phis are only
created when something asks for a value.

On CPS output there is a cost asymmetry worth knowing: deleting a phi is cheap, but deleting
a continuation *parameter* means fixing the function's type and every call site, so the
marker/SCC variants matter much more in that setting.

Measured against LLVM 3.1's tuned Cytron implementation on SPEC CINT2000: instruction counts
within a fraction of a percent, executed x86 instructions 99.72% of Cytron's. On-the-fly
optimizations cost 0.84s of construction time and returned 1.49s of total compile time by
shrinking the graph to 88.2% of its nodes. Also: 25% of the instructions LLVM's front end
emits are alloca/load/store scaffolding that SSA construction immediately deletes.

# Relevance

This is the construction algorithm to reach for if any stage of our pipeline ever needs a
real CFG in SSA form — most plausibly stage 11 or 12, once `letrec` loops have been lowered
to explicit control flow and the functional phi-by-parameter correspondence stops holding.
The reason is specific: it needs no dominator tree. Our pipeline is a nanopass chain where
passes rewrite structure aggressively, and any pass that changes control flow invalidates a
dominance computation. Braun's `writeVariable`/`readVariableRecursive` pair is directly
usable as *SSA reconstruction* after such a rewrite (Section 5.1 uses jump threading as the
motivating case, exactly because iterated jump threading would otherwise recompute dominance
every round).

Section 5.2 is the part that matters most for us though: the same algorithm converts an
imperative program straight to CPS, with continuation parameters in place of phis and call
arguments in place of phi operands. That is the direction our compiler already sits in, and
it says the SSA and functional views are the same construction, not two representations to
bridge. If ABCD (stage 06/07) wants an SSA inequality graph, we can build one over
`letrec`-parameter phis without ever leaving the functional IR.

The on-the-fly optimization story fits nanopass badly and well at once: badly because nanopass
wants each pass to be one semantic step, well because the peephole set (arith simplification,
CSE by value number, constant folding, copy propagation) is what an IR-node constructor can do
for free, and it is why our interval and pentagon domains would see a smaller graph.

# Notes

The paper is unusually honest about its own failure case. Figure 5 is a `goto` into a loop
body — irreducible — where the algorithm produces `v1: φ(v0,v2)` and `v2: φ(v0,v1)` when
`v0` alone would do. It does not hide this behind "in practice"; it builds the SCC pass and
proves the containment lemma. That is worth more than the headline result.

The stricter-than-Cytron redundancy definition is a small contribution that gets lost in
summaries: 3 of 11 non-trivial phi SCCs in the SPEC measurements did *not* come from
irreducible control flow, meaning Cytron's algorithm leaves them behind too. Algorithm 5 is
useful as a cleanup pass regardless of which constructor you use.

**On the metadata.** This PDF carries no conference header, page numbers, or copyright line —
an author preprint, not the publisher's copy. The venue is CC 2013 (22nd International
Conference on Compiler Construction, LNCS 7791, pp. 102-122) from external knowledge, not from
this file. Title, six authors, and the KIT/Saarland affiliations are read off the title page.
The bibliography's "CC 2013" is consistent with the document but not confirmable *from* it.

One claim is thin: "the runtime of our algorithm is on par with Cytron et al.'s." The 0.28%
instruction-count edge is inside the noise between two implementations in two codebases, and
they compare their *unoptimized* implementation against LLVM's tuned one, which cuts the other
way. The honest claim is that the simple algorithm is not slower in any way that matters.
