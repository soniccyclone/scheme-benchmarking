---
type: technique
title: Partial redundancy elimination
description: Deletes a computation that is redundant on only some paths by inserting it on the paths that lack it, with safety, computational and lifetime optimality as explicit criteria; subsumes global CSE and loop-invariant code motion.
tags: [partial-redundancy-elimination, ssapre, code-motion, register-promotion, speculation]
sources:
  - resource: /works/rastello-et-al-ssa-based-compiler-design-the-ssa-book.md
  - resource: /works/click-global-value-numbering-and-code-motion.md
  - resource: /works/bod-k-gupta-sarkar-abcd-eliminating-array-bounds-checks-on.md
  - resource: /works/cytron-et-al-efficiently-computing-ssa-toplas-1991.md
implemented_by: []
absent_from: [/implementations/chez.md]
pipeline_stage: 08-represent
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

A computation occurs on some paths reaching a point and not others. Deleting the later
occurrence requires inserting the computation on the paths that lacked it, and the insertion
must not add work to any path that did not already have it. Get this right and you have
subsumed global common subexpression elimination and loop-invariant code motion in one
algorithm, plus register promotion as a special case. Get it wrong and you have lengthened a
cold path or extended a live range across a loop for no gain.

**Source thinness, stated up front.** This bundle supports the technique through essentially
one primary source, chapter 11 of the SSA Book, which is an unfinished 2018 draft rather
than the 2022 Springer edition. The classical bit-vector line (Morel and Renvoise's original
formulation, Knoop et al.'s lazy code motion, Xue and Cai's profile-optimal speculative PRE)
is present only as citations inside that chapter's further-readings section. We hold no
measurement of PRE at all; the only PRE numbers in the bundle come from Click, arguing
against it. Everything below is reported at that confidence.

# Mechanism

**Why SSA and PRE are the same shape.** In the region of the CFG dominated by an occurrence
of `a + b`, any further occurrence is fully redundant. Past the dominance frontier, any
further occurrence is only partially redundant. Dominance frontiers are where phis go, so
partial redundancy begins exactly where phis begin, and the sparse structure that models
use-def relations among versions of a variable also models redundancy relations among
occurrences of an expression.

**Build the factored redundancy graph.** Introduce a hypothetical temporary `h`, the
temporary that would hold the expression's value. Insert `Phi` (upper case, for expressions)
at the iterated dominance frontier of the expression's occurrences, plus `Phi`s caused by
*expression alteration*, meaning a phi exists for one of the operand variables in that
block. Then rename in a dominator-tree pre-order carrying a renaming stack for the
expression alongside the stacks for the variables. A real occurrence gets the top h-version
if every variable version matches the top of the expression stack, otherwise a new version.
A `Phi`-use whose versions do not match gets the special class bottom, meaning the value is
unavailable at that point. The FRG is the SSA form for expressions, and it contains exactly
the information needed to choose the placement.

**Three linear passes over the FRG.** In this order.

*DownSafety*, backward. A `Phi` is not downsafe if there is a path to exit or to an
alteration along which the `Phi` result is never used, or transitively if its result is an
operand of a non-downsafe `Phi`. A `has_real_use` flag on each `Phi` operand, set during
renaming when the path from its defining `Phi` crosses a real occurrence, blocks the
transitive propagation:

    for each Phi f: if some path to exit or alteration does not use f, downsafe(f) <- false
    for each Phi f with not downsafe(f):
      for each operand w of f: if not has_real_use(w): Reset_downsafe(w)

    Reset_downsafe(X):
      if def(X) is not a Phi: return
      f <- def(X); if not downsafe(f): return
      downsafe(f) <- false
      for each operand w of f: if not has_real_use(w): Reset_downsafe(w)

*CanBeAvail*, forward. `can_be_avail(Phi) = downsafe(Phi) or avail(Phi)`. Rather than run a
separate availability analysis whose answers are useless inside the downsafe region,
initialize `not can_be_avail` at any `Phi` that is not downsafe and has a bottom operand,
then propagate forward through non-downsafe `Phi`s whose operand is defined by a
`not can_be_avail` `Phi` and is not `has_real_use`.

*Later*, forward. Optimistically mark every `can_be_avail` `Phi` as `later`, except one with
an operand defined by a real computation (the initialization) or an operand that is a
`can_be_avail`, not-`later` `Phi` (the propagation). `later` means a later insertion is
possible, so inserting here would extend a live range for nothing.

Insert at `will_be_avail = can_be_avail and not later`, at each operand that is bottom, or
that has `has_real_use` false and is defined by a `not will_be_avail` `Phi`. Then run
ordinary full redundancy elimination, which is what discharges the correctness criterion.

**Speculation.** Dropping the safety requirement gives speculative code motion, profitable
whenever the paths burdened with extra computation run less often than the paths whose
redundancy is removed. Without profile data, restrict it to loop invariants by marking
`Phi`s at the start of loop bodies as downsafe. Dangerous computations, meaning anything
that can fault (indirect loads, divides, and for us bounds checks), must not be speculated
unless the guard is present. The mechanism is a `tau` variable: each runtime test that
succeeds defines a `tau` on its fall-through path, dangerous computations take the relevant
`tau` as an extra operand, and `tau`s are themselves in SSA. A defined `tau` operand means
the computation is fault-safe and can be speculated inside the guarded region; the `tau`
definition simultaneously prevents hoisting the computation above its own test. `tau`
definitions are abstract, take no part in optimization, and are dropped after the phase.

**Register promotion as two PREs.** Loads behave like expressions, so the later occurrences
are deleted. Stores are the dual, so the earlier occurrences are deleted, which makes store
PRE a partial dead code elimination that moves stores forward. Run load PRE first, then
store PRE: load PRE is unaffected by store PRE, but it deletes loads that would otherwise
block store sinking. Store PRE needs the dual representation, static single use form, with
`sigma`-functions factoring use-def edges at divergence points, and the dual analyses
`UpSafety`, `CanBeAnt` and `Earlier`. Stores must be treated as l-value occurrences during
load PRE: `X <- expr` is `r <- expr; X <- r`, so a later load of `X` can reuse `r`. Both
phases need speculation to do a decent job in loops.

**PRE of checks, ABCD's version.** Insertion edges are collected during the backtracking of
the proof itself. A check goes into a phi-node's in-edge exactly when some arguments proved
True and others False; the False ones are the insertion set. The compensating index
expression is free, always `v_i + d` where `v_i` is the argument inserted into and `d` is the
constant propagated there. At a min vertex take the insertion set with lower execution
frequency; at a max vertex merge. Profitability is decided by profile counts, that is, by
speculation, not by classical anticipability.

# Preconditions

Conventional SSA, meaning every phi-web is interference-free and the live ranges of the
versions of a variable do not overlap, plus HSSA to model aliasing completely. GVN-PRE and
A-SSAPRE exist specifically to remove this requirement.

Maximal expression tree form. The algorithm optimizes one lexically identical expression at
a time, so `a + b * c - d` must be representable as a tree without naming the intermediates.
If the IR is triplets, where every operation's result lands in a temporary, lexical identity
is the wrong key and the value-based variants are the right starting point.

All critical edges split, since insertions are performed at `Phi`-uses and materialized at
the end of the predecessor block.

Expressions only. Statements have side effects and are not candidates. Anything that can
fault needs the `tau` treatment before it can be speculated.

Speculation needs execution frequencies, or the conservative substitute of restricting it to
loop invariants.

# Cost

Each of the three analyses is linear in the FRG, and the FRG is sparse, but the whole
procedure is repeated once per lexically distinct expression in the program. That is the
real cost model, and it is why the value-based variants that share work across expressions
are attractive despite their extra complexity.

Against the classical alternative: bit-vector PRE works at basic-block granularity, so it
needs a separate algorithm to detect and suppress local common subexpressions, and Morel and
Renvoise's original formulation is bidirectional, which costs more than a unidirectional
analysis and does not always yield optimal results. Lazy code motion removed the
bidirectionality and proved optimality. SSAPRE is an adaptation of lazy code motion that
avoids the bit-vector encoding and the separate local pass.

Precision given up: safe PRE will not move anything that lengthens any path, which is exactly
the transformation Click's global code motion performs and calls a win. Speculation buys it
back only with frequency information, and lifetime optimality exists to bound the register
pressure that the resulting code motion creates.

# Disagreements

**Click versus Chow, and it is a real fight.** Click's position is that the complexity of
PRE comes entirely from having to preserve a legal schedule while optimizing; drop that
requirement and GVN plus GCM gets comparable results in one linear pass with a far simpler
implementation, and GCM additionally hoists control-dependent code out of loops, which PRE
refuses because it can lengthen a path. Chow's position is that PRE's placement carries
computational and lifetime optimality proofs, subsumes CSE and LICM, and that the lifetime
criterion exists precisely to avoid the register pressure that schedule-early creates.
Click's own measurement does not settle it: 4.3 percent over one round of the competition
but 2.4 percent over two, on a simulated machine with infinite registers and one-cycle
loads, which is the configuration most favourable to his side. He says so in section 4.3.

**Safety versus speculation.** Chow's four criteria rank safety above optimality. ABCD
abandons anticipability outright and inserts on profile counts. Xue and Cai, and Zhou et al.,
reformulate the choice as a minimum cut over a flow network and recover optimality with
respect to a given profile, the latter over the FRG rather than the CFG so the networks are
smaller. Three defensible positions, no consensus.

**Syntax-driven versus value-driven.** Chapter 11.5.2 argues that value-number PRE has an
insertion-form problem (the same value comes from different expressions at different points,
and an insertion point outside the live range of every version that can compute it must be
disqualified) and concludes that full redundancy elimination among equal value numbers is
probably enough, because strictly partial redundancy among equal-valued computations should
be rare. VanDrunen and Hosking claim GVN-PRE subsumes both. The book reports the claim
without deciding, and offers no measurement either way.

**Whether register promotion deserves its own pass.** Chapter 11.4 says no: it is load PRE
followed by store PRE, and doing it that way gets optimal load and store placement plus
minimized pseudo-register live ranges from the optimality properties already proved.

**Draft caveat.** Chapter, section and figure numbers above come from the unfinished 8 June
2018 draft in `sources/` and will not match the published Springer edition. Chapter 11 itself
is finished prose with complete algorithms; other chapters in the same file are outlines.

# For us

Stage 08 is where this lands, and the honest read is that most of PRE's value is already
ours by construction. Our core language binds values with `let`, not memory, so the register
promotion problem that chapter 11.4 solves barely exists for scalars. What is left is real
though: `flvector` element access in a loop is a load PRE problem, and an `flvector-length`
reloaded per iteration is the textbook loop-invariant case.

The piece worth taking regardless of whether we build SSAPRE is the fault-safety mechanism.
Our checked accesses are dangerous computations in exactly Chow's sense. The `tau` variable
is the encoding for "this access sits inside a region where a test already established its
safety", which is the same fact ABCD attaches to a `sigma`-renamed name and Pentagon holds in
a flow-sensitive map. The property that makes it worth copying is that one mechanism does two
jobs: a defined `tau` operand licenses speculation inside the guarded region, and the `tau`
definition blocks hoisting past the guard. That is the discipline stage 07 needs when it
moves a check, and it composes with the control-input pinning rule that stage 10 needs.

Do not build SSAPRE for stage 07's check hoisting. ABCD already produces the insertion set as
a by-product of the redundancy proof, demand-driven per check, rather than running a
placement analysis once per lexical expression in the program. The two would compute
overlapping answers at very different costs.

For dead code, Cytron's control-dependence-driven elimination is the pass to run before any
placement analysis: seed liveness from side effects and propagate backwards through both
definitions and inverse control dependence, so a branch is live only when something control
dependent on it is live. That deletes occurrences before PRE has to reason about them.

Chez is recorded as absent on the basis of `docs/CHEZ-ANALYSIS.md`, which reports that
grepping Chez's sources for `induction`, `loop-invariant`, `licm` and `hoist` returns
nothing and that there is no loop recognition pass in the compiler. PRE subsumes
loop-invariant code motion, so the absence of the latter is evidence for the absence of the
former, though it is not a direct observation of a missing PRE pass.
