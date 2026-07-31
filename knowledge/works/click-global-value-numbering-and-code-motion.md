---
type: paper
title: "Global Code Motion Global Value Numbering"
description: Separates value optimization from scheduling so that a one-pass hash-based GVN can ignore placement entirely, then a two-pass early/late dominator-tree scheduler reconstructs a legal and better schedule.
resource: knowledge/sources/click-global-value-numbering-and-code-motion.pdf
tags: [global-value-numbering, code-motion, sea-of-nodes, ssa-construction, loop-analysis]
authors: [Cliff Click]
year: 1995
venue: "PLDI 1995 (SIGPLAN '95, La Jolla, pp. 246-257)"
informs: [/techniques/loop-analysis.md, /techniques/global-value-numbering.md, /techniques/ssa-construction.md]
pipeline_stage: 07-loops
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

The thesis is a separation of concerns, and the paper argues it is *the* source of complexity
in PRE and in global congruence finding: those algorithms are hard because they must preserve
a legal schedule while they optimize. Click's move is to let the optimizer produce an
*illegal* program on purpose.

GVN replaces each set of value-equivalent instructions with one instruction and places it
nowhere — the result is incorrect by construction. A following Global Code Motion pass picks
a legal block for every floating instruction using only dependence edges, ignoring the
original schedule entirely. Because GVN never has to build a correct schedule, it collapses
to the local hash-table value-numbering algorithm with the basic-block boundaries deleted:
one linear pass.

GCM is not merely a repair pass. It hoists out of loops more aggressively than PRE (it will
hoist control-dependent code, which PRE refuses because it can lengthen a path) and it sinks
code down into conditionals, giving an effect similar to partial dead code elimination. Both
in near-linear time.

This is also the paper that introduces, without naming it, the "sea of nodes" IR that went
into the HotSpot server compiler.

# Mechanism

**Representation.** SSA, with variable names replaced by *pointers to the defining
instruction*, turning the instruction stream into a data-dependence graph. Not a DAG —
phi-functions are ordinary expressions and can take back edges. Basic blocks are themselves
a kind of instruction (region nodes, after Ferrante-Ottenstein-Warren), which lets constant
folding apply to blocks: folding a block means removing a constant test and its unreachable
edge, which then simplifies the dependent phis.

Correctness requires *all* dependence to be explicit, since the original order is discarded:
loads and stores are threaded by a memory token, and faulting instructions (loads, stores,
division, calls) carry an explicit control input pinning them to their original block or
later, never earlier.

**GCM, five steps.**

1. Dominator tree (Lengauer-Tarjan), annotate each block with dominator depth.
2. Loop tree and loop nesting depth per block (modified Tarjan reducibility test, per Vick).
3. **Schedule early.** Post-order DFS over *inputs*, seeded from pinned instructions (phis,
   branches, returns, faulting ops). Place each instruction in the block of its
   deepest-dominator-depth input. Maximum hoisting, lots of speculation, very long live
   ranges.
4. **Schedule late.** Post-order DFS over *uses*, again seeded from pinned instructions.
   Compute the LCA in the dominator tree of all use blocks. For a phi use, the use site is
   not the phi's block but the CFG predecessor matching that operand index — this detail is
   easy to get wrong and it is what makes loop-carried values behave.
5. **Select.** Early block dominates late block, so the dominator-tree path between them is
   the legal range. Walk it upward and keep the *deepest* block at the *shallowest* loop
   nest. Outside as many loops as possible, then on as few paths as possible.

`Find_LCA` is a naive linear walk: raise the deeper of the two by immediate dominator until
depths match, then raise both until equal. O(n) worst case, small constant in practice.

Selection happens *during* the late walk rather than after it, because placing one
instruction changes the latest legal block for its inputs (put `b := a+1` before the loop and
the constant `1` can also go before the loop).

**The subtle correctness point, and it is the best thing in the paper.** Scheduling early
assumes every instruction's inputs dominate its uses. They do not always. Click's Figure 3:
`x` is defined in block 4 and used in block 5, block 4 does not dominate block 5, so there is
no legal placement. The resolution is that SSA conversion inserts phis merging `x`'s
definition with the undefined value ⊤, and *those phis are load-bearing*. They encode the
programmer's assertion that a value will be available. So GVN must **not** apply the identity
`x = φ(x, ⊤)`. Deliberately declining an obvious simplification, because it carries the
information that makes scheduling possible.

**GVN.** Reverse-postorder walk over dependence edges. At each instruction: (1) fold if all
inputs are constant or one input is a special constant (multiply by zero); (2) check for an
algebraic identity on an input (add of zero, copy, `x MAX x`), and if so rewrite uses to the
input; (3) hash operation + input pointers, look up, and on a hit rewrite uses to the earlier
instruction. Commutative ops hash and compare order-insensitively. The table is never reset
at block boundaries — blocks play no part. RPO means inputs are usually numbered first;
loops are the exception, so a second GVN pass can find more, though one is usually enough.
No fixpoint.

# Applicability

Preconditions: SSA form, explicit memory dependence edges, explicit control inputs on
faulting instructions, and CFG shaping first — split control-dependent edges, insert loop
landing pads. Without the shaping there is often no block to sink into.

GCM works on irreducible graphs. So does GVN; Rosen-Wegman-Zadeck's GVN does not, because it
leans on program structure.

Where it loses: GVN is *bottom-up*, so it cannot find congruences among values that form
dependence cycles — exactly what Alpern-Wegman-Zadeck's top-down partitioning finds. The
trade is that GVN gets constant folding and algebraic identities, which AWZ cannot do, and
runs in one linear pass rather than O(n log n). Click's own thesis work combines both and is,
he says, "quite complex," leaving the compiler writer to trade expected gain against
implementation cost. That is an unusually honest framing.

GCM is explicitly *not* optimal: it lengthens some paths. Hoisting control-dependent code out
of a loop wins if the loop runs at least once, and usually it does. But this is a heuristic
and it is stated as one.

Measured on 52 procedures from Spec89 (doduc, tomcatv, matrix300, fpppp), the Forsythe-Malcolm-
Moler routines, and cplex, over the ILOC virtual machine: GVN-GCM beats one round of
GCF+PRE+CCP by 4.3% average, or 5.9% with reassociation first. Against *two* rounds of
GCF+PRE+CCP roughly half the advantage disappears, which Click reads as the second round
exploiting constants CCP found in the first — a phase-ordering problem GVN does not have,
because it folds constants and finds congruences in the same pass.

# Relevance

Two distinct things here, and only one of them is for us.

**GCM's placement heuristic is directly applicable to stage 07.** Our CUJ specifies hoisting
a bounds check out of a loop once the derived range proves it for every iteration. That is
exactly "schedule late, then walk up the dominator tree to the shallowest loop nest." More
usefully, GCM says the same machinery also *sinks* — moving a computation from the loop
header down into the branch that actually uses it. For a check we cannot hoist, sinking it
onto the cold path is the next-best outcome, and it falls out of the same walk.

The pinning discipline is the part to copy verbatim. Our checked accesses, allocations, and
anything that can raise are faulting instructions, and they need an explicit control input so
that motion can only ever be downward. Get that wrong and stage 10 vectorization will happily
hoist a trap above its guard. This is a concrete safety rule for the IR, not just an
optimization technique.

**The "GVN produces an incorrect program" trick fits nanopass badly.** Nanopass wants each
pass to produce a well-formed term in a declared output language. A pass whose output is
provably incorrect until a later pass fixes it cannot be typed that way honestly — the output
language would have to admit unplaced instructions, which is precisely the sea-of-nodes
representation and not a Scheme core language. If we ever want this, the honest encoding is a
distinct intermediate language where placement is genuinely optional, not a fudge in `Lcore`.

The ⊤-phi observation is worth carrying regardless of representation: an apparently redundant
merge can be the only thing certifying that a value is available on all paths, and an
optimizer that "simplifies" it destroys information. In our `letrec`-as-loop encoding the
analogue is a loop parameter that appears to be passed unchanged; deleting it as trivially
copyable can break a later hoisting argument.

# Notes

**Title correction, minor but real.** The slug and the bibliography say
"global-value-numbering-and-code-motion." The title page reads **"Global Code Motion Global
Value Numbering"** — code motion first, value numbering second, no conjunction. That word
order is not cosmetic; it is the paper's argument (code motion is the enabling pass, value
numbering is what becomes simple once you have it). Author: **Cliff Click**, Hewlett-Packard
Laboratories, Cambridge Research Office, with a footnote that the work was done at Rice
University's CS department under ARPA/ONR grant N00014-91-J-1989. SIGPLAN '95, La Jolla,
ACM 0-89791-697-2/95/0006, pages 246-257 — so PLDI 1995. Everything except the title word
order is correct.

The experimental setup is the weak point and Click defends it explicitly rather than hiding
it. ILOC's simulated machine has *infinite registers* and *one-cycle latency for everything
including loads, stores, and jumps*. That model erases the single largest cost of GCM: early
scheduling creates enormous live ranges, and aggressive hoisting increases register pressure.
On a real machine with 8 or 16 registers, some of that 4.3% would be given back in spills.
Click's argument is that including memory hierarchy and functional-unit limits would obscure
the machine-independent effect he is measuring, which is fair for the paper's purpose and
useless for predicting real speedup. Treat 4.3% as an upper bound.

Look at the per-procedure table rather than the average. The distribution is wide and
two-sided: `doduc/parol` gets 23.3%, but eight procedures are *negative*, one at −5.7% and
`cplex/xielem` at −24.4% under the reassociate variant. The mean is carried by a handful of
big wins on loop-heavy Fortran. That is a normal shape for a code-motion heuristic, and the
paper does not smooth it over.

Also note what the GVN comparison actually shows. GVN-GCM beats one round of GCF+PRE+CCP by
4.3%; it beats *two* rounds by 2.4%. So most of the win is a phase-ordering artifact of the
competition, not a strictly stronger analysis. Click says this plainly in Section 4.3. The
durable claim is "comparable results, far simpler implementation, one pass" — not "finds more."
