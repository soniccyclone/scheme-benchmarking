---
type: technique
title: Global value numbering
description: Finds computations that produce the same value across the whole procedure by hashing over SSA names, and deletes all but one, at the price of needing a separate pass to decide where the survivor goes.
tags: [global-value-numbering, redundancy-elimination, code-motion, congruence, ssa-form]
sources:
  - resource: /works/click-global-value-numbering-and-code-motion.md
  - resource: /works/rastello-et-al-ssa-based-compiler-design-the-ssa-book.md
  - resource: /works/braun-et-al-simple-and-efficient-construction-of-static-si.md
  - resource: /works/willsey-et-al-egg-fast-and-extensible-equality-saturation-.md
  - resource: /works/cytron-et-al-efficiently-computing-ssa-toplas-1991.md
implemented_by: []
absent_from: []
pipeline_stage: 07-loops
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

The same value gets computed twice in different places, and the two computations are not in
the same basic block, so local common-subexpression elimination misses them. Address
arithmetic in a loop body, a length reloaded on every iteration, and the index expressions
a bounds check inserts are the shapes that matter for us. The engineering question is what
"same value" should mean, how to decide it cheaply, and what to do about the fact that the
surviving computation now has to live somewhere legal.

# Mechanism

**Value numbering, local.** Hash an expression tree bottom-up: each internal node hashes on
its operator plus the value numbers of its operands, leaves hash on themselves. Assign the
RHS value number to the assigned variable. In non-SSA code an assignment also *kills* every
value number that referred to that variable, which is why the classical algorithm cannot
leave the block. Under SSA each version has at most one static value, so nothing is ever
killed and the same hash table works over the whole procedure.

**Click's GVN, one pass.** Represent the program as SSA where variable names are replaced
by pointers to the defining instruction, so the instruction stream is a data-dependence
graph. Walk it in reverse postorder and at each instruction do three things in order:

1. Fold if all inputs are constant, or one input is a special constant (multiply by zero).
2. Check for an algebraic identity on an input (add of zero, a copy, `x MAX x`); if so,
   rewrite the uses to that input.
3. Hash the operation together with its input pointers, look it up, and on a hit rewrite the
   uses to the earlier instruction.

Commutative operations hash and compare order-insensitively. The table is never reset at
block boundaries, because blocks play no part. There is no fixpoint. Reverse postorder
numbers inputs before uses except across back edges, so a second pass can find a little
more, though one is usually enough.

**Why it is one pass: it deletes the schedule.** GVN replaces each set of value-equivalent
instructions by one instruction and places it *nowhere*. The output program is incorrect by
construction, which is exactly what removes the complexity: the classical algorithms are
hard because they must preserve a legal schedule while optimizing. A following Global Code
Motion pass picks a legal block for every floating instruction from dependence edges alone:

1. Dominator tree, annotate each block with dominator depth.
2. Loop tree and loop nesting depth per block.
3. **Schedule early.** Post-order DFS over inputs, seeded from pinned instructions. Place
   each instruction in the block of its deepest-dominator-depth input. Maximum hoisting,
   enormous live ranges.
4. **Schedule late.** Post-order DFS over uses, again seeded from pinned instructions.
   Compute the LCA in the dominator tree of all use blocks. For a use inside a phi, the use
   site is not the phi's block but the CFG predecessor matching that operand index. That
   detail is what makes loop-carried values behave, and it is easy to get wrong.
5. **Select.** The early block dominates the late block, so the dominator-tree path between
   them is the legal range. Walk it upward and keep the deepest block at the shallowest loop
   nest: outside as many loops as possible, then on as few paths as possible.

Selection happens during the late walk rather than after it, because placing one instruction
changes the latest legal block for its inputs.

**The partition-based alternative.** Alpern, Wegman and Zadeck's algorithm is optimistic and
top-down. It starts with all expressions sharing an operator in one congruence class, then
subdivides: if two expressions in a class have operands at the same position in different
classes, they may compute different values and must be split. Iterate until no subdivision
occurs. It is not obstructed by back edges, which is its whole advantage. The hash-based
method is pessimistic and demonstrably fails on the loop case:

    i2 <- phi(i3, i1)     j2 <- phi(j3, j1)
    i3 <- i2 + 4          j3 <- j2 + 4

When the hash method reaches the phis, `i3` and `j3` have no value numbers yet, so `i2` and
`j2` must get different ones, and the equivalence is lost. Partitioning finds it. The SSA
Book's recommendation is to run both independently and combine the results.

**The maximal version.** Equality saturation replaces "pick a representative" with "keep all
of them": an e-graph is a union-find over e-class ids plus a hashcons from canonical e-node
to id, congruence is maintained as an invariant, and rewrites add equalities instead of
rewriting in place. egg's contribution is deferring the invariant restoration to once per
iteration so a deduplicating worklist can coalesce overlapping upward-merge paths, measured
at 88x geomean on congruence maintenance. It is the right frame for knowing what congruence
finding could find, and the wrong tool for a whole optimizer: extraction is only cheap when
the cost function is local, and a Scheme compiler's real cost model (allocation, closure
creation, register pressure) is not.

**Turning congruence into deletion.** Two computations with the same value number are
redundant only if there is a control-flow path from one to the other. Full redundancy
elimination among equal value numbers is the affordable point. Partial redundancy over
value numbers has an extra problem the syntax-driven version does not: the same value can
come from different expression forms at different points, so an insertion point must pick a
form, and any insertion point outside the live range of every variable version that can
compute the value has to be disqualified.

# Preconditions

SSA form. Without it, value numbers are killed at every assignment and nothing survives a
block boundary.

For Click's version specifically, and these are not optional: all dependence must be
explicit, because the original order is discarded. Loads and stores are threaded by a memory
token. Faulting instructions (loads, stores, division, calls) carry an explicit control
input pinning them to their original block or later, never earlier. And the CFG must be
shaped first, splitting control-dependent edges and inserting loop landing pads, or there is
often no block to sink into.

Do not apply the identity `x = phi(x, top)`. Click's Figure 3 has `x` defined in block 4 and
used in block 5 where block 4 does not dominate block 5, so there is no legal placement at
all. The phi merging the definition with the undefined value is what certifies the value is
available on all paths, and simplifying it destroys the information scheduling needs.
Declining an obvious simplification is the best thing in that paper.

Both GVN and GCM work on irreducible graphs. Rosen, Wegman and Zadeck's earlier GVN does
not, because it leans on program structure.

# Cost

GVN is one linear pass with no fixpoint. Partitioning is `O(n log n)` and needs the whole
program up front. GCM is near-linear; `Find_LCA` is a naive walk that raises the deeper node
by immediate dominator until depths match then raises both, `O(n)` worst case with a small
constant.

Measured on 52 procedures from Spec89, the Forsythe-Malcolm-Moler routines, and cplex over
the ILOC virtual machine: GVN plus GCM beats one round of global congruence finding, PRE and
conditional constant propagation by 4.3 percent average, 5.9 percent with reassociation
first. Against *two* rounds the margin drops to about 2.4 percent, and Click reads that
himself as the second round exploiting constants the first round's CCP found, a
phase-ordering problem GVN does not have because it folds constants and finds congruences in
the same pass.

Treat 4.3 percent as an upper bound. ILOC has infinite registers and one-cycle latency for
everything including loads, stores and jumps, which erases GCM's largest real cost:
scheduling early creates enormous live ranges and aggressive hoisting raises register
pressure, so on a machine with 16 registers some of the win comes back as spills. Read the
per-procedure table rather than the average: `doduc/parol` gains 23.3 percent, eight
procedures are negative, and `cplex/xielem` loses 24.4 percent under the reassociate variant.

Precision given up: GVN is bottom-up, so it cannot find congruences among values that form
dependence cycles, which is exactly the class partitioning finds. The trade is that GVN gets
constant folding and algebraic identities, which partitioning cannot do. GCM is also
explicitly not optimal and lengthens some paths; hoisting control-dependent code out of a
loop wins if the loop runs at least once, and that is a heuristic stated as one.

# Disagreements

**Hash-based versus partition-based.** Neither dominates. Hash gets folding, algebraic
identities and commutativity; partitioning gets cycles and is immune to back edges. Click's
own thesis combines them and he calls the result "quite complex", leaving the compiler
writer to trade expected gain against implementation cost. The SSA Book says to run both and
merge. That is an unusually honest place for the literature to land, and it means there is
no default answer to inherit.

**Whether value numbering needs code motion at all.** Click's thesis is that separating them
is what makes GVN one linear pass. The SSAPRE line keeps placement inside the algorithm and
gets computational and lifetime optimality guarantees that Click does not claim, at the cost
of a much larger algorithm. Click's measurement does not settle this, and section 4.3 says
so: the durable claim is "comparable results, far simpler implementation, one pass", not
"finds more".

**Whether value-based PRE is worth building.** The SSA Book expects strictly partial
redundancy to be rare among computations that yield the same value, and concludes full
redundancy elimination over value numbers is probably sufficient. VanDrunen and Hosking's
GVN-PRE is claimed to subsume both PRE and GVN. The book reports the claim without
endorsing it.

**Whether to prune the SSA that GVN runs on.** Cytron's Figure 16 argues explicitly for
keeping dead phi-functions rather than pruning, on the grounds that they expose
value-numbering opportunities. Modern practice prunes by default because dead phis inflate
the IR every later pass walks. Cytron is right that pruning can cost an equivalence and
wrong about the balance for a compiler with many passes, but if GVN is the only consumer the
argument is live again.

**Title correction.** The Click paper's title page reads *Global Code Motion Global Value
Numbering*, code motion first, no conjunction. That word order is the argument, not a
typographic accident: code motion is the enabling pass and value numbering is what becomes
simple once you have it. Our slug and bibliography have it backwards.

# For us

The trick that makes Click's GVN cheap fits nanopass badly, and it should be said plainly.
Nanopass wants each pass to produce a well-formed term in a declared output language, and a
pass whose output is provably incorrect until a later pass repairs it cannot be typed that
way honestly. The output language would have to admit unplaced instructions, which is the
sea of nodes, not a Scheme core language. If we want it, the honest encoding is a distinct
intermediate language where placement is genuinely optional, not a fudge in `Lcore`.

Two pieces transfer regardless of representation.

The GCM placement heuristic is stage 07's hoist rule already: the CUJ specifies hoisting a
bounds check out of a loop once the derived range proves it for every iteration, which is
"schedule late, then walk up the dominator tree to the shallowest loop nest". The same
machinery also sinks, so for a check we cannot hoist, moving it onto the cold path falls out
of the same walk rather than needing a second mechanism.

The pinning discipline is an IR safety rule for us, not an optimization. Our checked
accesses, allocations, and anything that can raise are faulting instructions and need an
explicit control input so motion can only ever be downward. Get that wrong and stage 10 will
happily hoist a trap above its guard. ABCD's speedup was 10 percent for a 45 percent check
reduction precisely because Jalapeno had no global code motion to exploit the freed-up
scheduling, so the value of stage 06 is realized here or not at all.

If we do build a CFG-based IR, note that local value numbering comes free with Braun-style
SSA construction: its peephole set is arithmetic simplification, CSE by value number,
constant folding and copy propagation, applied at IR-node construction time, which shrank
the graph to 88.2 percent of its nodes for a net compile-time win. That is a smaller graph
for the interval and pentagon domains to walk, before any dedicated GVN pass exists.

The top-phi observation has a direct analogue in our representation: a `letrec` loop
parameter that appears to be passed through unchanged is not necessarily removable, because
it may be the only thing certifying that a value is available on all paths into the loop.
