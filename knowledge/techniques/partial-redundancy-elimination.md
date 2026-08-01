---
type: technique
title: Partial redundancy elimination
description: Deletes a computation that is redundant on only some paths by inserting it on the paths that lack it; subsumes global CSE and loop-invariant code motion in one algorithm, available either as five Boolean bit-vector systems or as a sparse analysis over an SSA form for expressions.
tags: [partial-redundancy-elimination, ssapre, code-motion, bit-vector, register-promotion, speculation]
sources:
  - resource: /works/morel-renvoise-partial-redundancy-elimination-1979.md
  - resource: /works/rastello-et-al-ssa-based-compiler-design-the-ssa-book.md
  - resource: /works/click-global-value-numbering-and-code-motion.md
  - resource: /works/bod-k-gupta-sarkar-abcd-eliminating-array-bounds-checks-on.md
  - resource: /works/cytron-et-al-efficiently-computing-ssa-toplas-1991.md
  - resource: /works/kildall-unified-approach-global-optimization-1973.md
implemented_by: []
absent_from: [/implementations/chez.md]
pipeline_stage: 08-represent
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-08-01T00:00:00Z" }
---

# Problem

A computation occurs on some paths reaching a point and not others. Deleting the later
occurrence requires inserting the computation on the paths that lacked it, and the insertion
must not add work to any path that did not already have it.

The reason to care is subsumption, and Morel and Renvoise prove it rather than assert it. A
loop-invariant computation *is* partially redundant: if the expression is transparent
throughout the loop then any block in the loop containing a computation has
`ANTLOC = COMP = TRUE`, so `PAVOUT = TRUE`, and the cycle back through the loop makes
`PAVIN = TRUE` at that same block, which is the definition. A fully redundant computation is
trivially partially redundant. So one algorithm replaces global common subexpression
elimination, loop-invariant code motion, and partial redundancy suppression, and their
measurement of that replacement is a 7200-line optimizer becoming 2500 lines and running 30
to 60 percent faster. Register promotion falls out as a special case.

Get it wrong and you have lengthened a cold path, or extended a live range across a loop for
no gain.

**Source status.** Two primary sources now, and they are the two ends of the line: Morel and
Renvoise's CACM 1979 paper, which originated the transformation and gives the classical
bit-vector formulation, and chapter 11 of the SSA Book for Chow's SSAPRE. The SSA Book copy
is an unfinished 2018 draft, not the 2022 Springer edition, so its chapter and figure numbers
will not match. Knoop-Rüthing-Steffen's lazy code motion and Xue and Cai's speculative PRE
are still citations only, and we hold no independent measurement of PRE — the only PRE
numbers in the bundle are Click's, arguing against it, and Morel and Renvoise's own, arguing
for their version against their own earlier one.

# Mechanism

## The classical formulation (Morel and Renvoise)

Basic blocks; assignments split so each expression is one binary operation assigned to a
temporary. Three local Boolean properties per (expression, block):

- `TRANSP_i` — no command in `i` modifies the expression's operands.
- `COMP_i` — locally available: computed in `i`, operands not modified after the last such
  computation.
- `ANTLOC_i` — locally anticipable: computed in `i`, operands not modified before the first.

Three classical global systems, each a Kildall dataflow problem over the two-point lattice,
all solved by direct iteration and all bit-vectored so that 32 expressions ride in one word:

    AVIN_i   = FALSE if entry, else ∏_{j ∈ Pred(i)} AVOUT_j
    AVOUT_i  = COMP_i + TRANSP_i · AVIN_i            # largest solution, init TRUE

    ANTOUT_i = FALSE if exit, else ∏_{j ∈ Succ(i)} ANTIN_j
    ANTIN_i  = ANTLOC_i + TRANSP_i · ANTOUT_i        # largest solution, init TRUE

    PAVIN_i  = FALSE if entry, else Σ_{j ∈ Pred(i)} PAVOUT_j
    PAVOUT_i = COMP_i + TRANSP_i · PAVIN_i           # smallest solution, init FALSE

Conjunctive systems take the largest solution and initialize all TRUE; the disjunctive one
takes the smallest and initializes FALSE. A computation in `i` is partially redundant exactly
when `ANTLOC_i · PAVIN_i`.

Then the placement system, which is the paper's actual contribution. Define

    CONST_i = ANTIN_i · [ PAVIN_i + (¬ANTLOC_i) · TRANSP_i ]

true for blocks holding a partial redundancy and for blocks empty with respect to the
expression where it can still be anticipated. Then

    PPIN_i  = FALSE if entry, else
              CONST_i · ∏_{j ∈ Pred(i)} (PPOUT_j + AVOUT_j)
                      · (ANTLOC_i + TRANSP_i · PPOUT_i)
    PPOUT_i = FALSE if exit, else ∏_{k ∈ Succ(i)} PPIN_k

    INSERT_i = PPOUT_i · ¬AVOUT_i · (¬PPIN_i + ¬TRANSP_i)

Insert at the exit of every block with `INSERT`; delete the first computation in every block
with `ANTLOC_i · PPIN_i`. Largest solution, but in practice initialize `PPIN_i` to `CONST_i`,
which is an upper bound, and it converges in three iterations on real code.

**Where the bidirectionality lives, precisely.** The term `TRANSP_i · PPOUT_i` inside
`PPIN_i` makes a block's entry property depend on its own exit property, which depends on its
successors. That single term is what the next fifteen years of literature was spent removing,
and it is worth knowing exactly where to look for it in any implementation.

**What is proved, and it is both directions.** Lemma 1: after insertion, any block with
`PPIN = TRUE` has `AVIN' = TRUE`; Theorem 1 follows, so every deleted computation is genuinely
redundant at the point of deletion. Lemma 2: every path leaving an insertion point contains a
computation that will be deleted. Lemma 3: no path hits two insertions before a deletion.
Theorem 2 follows, so no path ends up with more computations than it started with.
Correctness and non-degradation, separately. Note what is *not* proved: optimality. Morel and
Renvoise never claim it.

## The modern formulation (SSAPRE, from the SSA Book)

**Why SSA and PRE are the same shape.** In the region dominated by an occurrence of `a + b`,
any further occurrence is fully redundant. Past the dominance frontier, any further
occurrence is only partially redundant. Dominance frontiers are where phis go, so partial
redundancy begins exactly where phis begin, and the sparse structure that models use-def
relations among versions of a variable also models redundancy relations among occurrences of
an expression.

**Build the factored redundancy graph.** Introduce a hypothetical temporary `h`. Insert `Phi`
(upper case, for expressions) at the iterated dominance frontier of the expression's
occurrences, plus `Phi`s caused by *expression alteration*, meaning a phi exists for one of
the operand variables in that block. Rename in dominator-tree pre-order carrying a renaming
stack for the expression alongside the stacks for the variables. A real occurrence gets the
top h-version if every variable version matches the top of the expression stack, otherwise a
new version. A `Phi`-use whose versions do not match gets the class bottom, meaning
unavailable. The FRG is SSA form for expressions, and it holds exactly what is needed to
choose the placement.

**Three linear passes over the FRG**, in this order.

*DownSafety*, backward. A `Phi` is not downsafe if there is a path to exit or to an
alteration along which its result is never used, or transitively if its result is an operand
of a non-downsafe `Phi`. A `has_real_use` flag per operand, set during renaming when the path
from its defining `Phi` crosses a real occurrence, blocks the transitive propagation:

    for each Phi f: if some path to exit or alteration does not use f, downsafe(f) <- false
    for each Phi f with not downsafe(f):
      for each operand w of f: if not has_real_use(w): Reset_downsafe(w)

    Reset_downsafe(X):
      if def(X) is not a Phi: return
      f <- def(X); if not downsafe(f): return
      downsafe(f) <- false
      for each operand w of f: if not has_real_use(w): Reset_downsafe(w)

*CanBeAvail*, forward. `can_be_avail(Phi) = downsafe(Phi) or avail(Phi)`. Rather than a
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
ordinary full redundancy elimination, which is what discharges correctness.

The correspondence to the classical version is exact and worth holding: `DownSafety` is
anticipability, `CanBeAvail` is availability plus partial availability, `Later` is the
lifetime-optimality criterion Morel and Renvoise did not have, and the whole three-pass
sequence is unidirectional where `PPIN`/`PPOUT` was not.

## Speculation

Dropping the safety requirement gives speculative code motion, profitable whenever the paths
burdened with extra computation run less often than the paths whose redundancy is removed.
Morel and Renvoise refuse this explicitly — their Figures 7-8 show a safe insertion that
creates a *new* partial redundancy elsewhere, and they decline it on the ground that
"execution frequency measurements are needed to guarantee the effectiveness of the
transformation." That is the same judgment ABCD reverses with profile data.

Without profile data, restrict speculation to loop invariants by marking `Phi`s at the start
of loop bodies as downsafe. Dangerous computations, meaning anything that can fault (indirect
loads, divides, and for us bounds checks), must not be speculated unless the guard is present.
The mechanism is a `tau` variable: each runtime test that succeeds defines a `tau` on its
fall-through path, dangerous computations take the relevant `tau` as an extra operand, and
`tau`s are themselves in SSA. A defined `tau` operand means the computation is fault-safe and
can be speculated inside the guarded region; the `tau` definition simultaneously prevents
hoisting the computation above its own test. `tau` definitions are abstract, take no part in
optimization, and are dropped after the phase.

## Register promotion as two PREs

Loads behave like expressions, so later occurrences are deleted. Stores are the dual, so
earlier occurrences are deleted, which makes store PRE a partial dead code elimination that
moves stores forward. Run load PRE first, then store PRE: load PRE is unaffected by store PRE,
but it deletes loads that would otherwise block store sinking. Store PRE needs the dual
representation, static single use form, with `sigma`-functions factoring use-def edges at
divergence points, and the dual analyses `UpSafety`, `CanBeAnt` and `Earlier`. Stores must be
treated as l-value occurrences during load PRE: `X <- expr` is `r <- expr; X <- r`, so a later
load of `X` can reuse `r`. Both phases need speculation to do a decent job in loops.

## PRE of checks, ABCD's version

Insertion edges are collected during the backtracking of the proof itself. A check goes into a
phi-node's in-edge exactly when some arguments proved True and others False; the False ones
are the insertion set. The compensating index expression is free, always `v_i + d` where `v_i`
is the argument inserted into and `d` is the constant propagated there. At a min vertex take
the insertion set with lower execution frequency; at a max vertex merge. Profitability is
decided by profile counts, that is, by speculation, not by classical anticipability.

# Preconditions

**Classical.** Initialization blocks, which is critical edge splitting under a different name:
Morel and Renvoise's Definition 5 requires that if a block with several successors is the only
predecessor of a loop entry, a new empty block is inserted on that edge. Insertion points must
be anticipable, so a partial redundancy whose expression cannot be anticipated at the
insertion point is simply not removed — their Figure 5, where `A+B` in node 4 cannot be
anticipated on exit from node 1, needs a new node on edge (1,4) and they decline to discuss
graph modification. Nothing else: no dominators, no intervals, no loop identification, no
reducibility, no single-entry restriction. That last point is the classical formulation's
strongest selling point and is easy to forget.

**SSAPRE.** Conventional SSA, meaning every phi-web is interference-free and the live ranges
of the versions of a variable do not overlap, plus HSSA to model aliasing completely. GVN-PRE
and A-SSAPRE exist specifically to remove this requirement.

Maximal expression tree form. The algorithm optimizes one lexically identical expression at a
time, so `a + b * c - d` must be representable as a tree without naming the intermediates. If
the IR is triplets, where every operation's result lands in a temporary, lexical identity is
the wrong key and the value-based variants are the right starting point. The classical
formulation has the same requirement in a different dress: Morel and Renvoise split every
assignment into binary operations over named temporaries and then treat each *expression* as
a bit position, so lexical identity is still the key.

All critical edges split, since insertions are performed at `Phi`-uses and materialized at
the end of the predecessor block.

**Both.** Expressions only; statements have side effects and are not candidates. Anything that
can fault needs the `tau` treatment before it can be speculated. Speculation needs execution
frequencies, or the conservative substitute of restricting it to loop invariants.

# Cost

**Classical.** Five Boolean systems, one bit per expression, 32 expressions per machine word,
solved by direct iteration. Morel and Renvoise measured on 50,000+ lines of LIS with
procedures up to 420 blocks: the `PPIN`/`PPOUT` system "never exceeded three" iterations, and
the classical systems ran near three as well when blocks were numbered in creation order,
which approximates reverse postorder. Execution time nearly linear in program size and "very
slightly" dependent on graph shape. Take the linearity as an empirical result on
well-structured code, not a bound — they say outright that "a meaningful theoretical
evaluation seems to be very difficult." On machine-generated or adversarial graphs, assume
neither the iteration count nor the linearity holds. The whole analysis was 800 lines of code.

**SSAPRE.** Each of the three analyses is linear in the FRG, and the FRG is sparse, but the
whole procedure repeats once per lexically distinct expression in the program. That is the
real cost model, and it is why the value-based variants that share work across expressions are
attractive despite their extra complexity.

**Precision given up.** Bit-vector PRE works at basic-block granularity, so it needs a
separate algorithm to detect and suppress local common subexpressions. Morel and Renvoise's
formulation is bidirectional, which costs more than a unidirectional analysis and does not
always yield optimal results; lazy code motion removed the bidirectionality and proved
optimality; SSAPRE is an adaptation of lazy code motion that avoids the bit-vector encoding
and the separate local pass.

Two specific losses Morel and Renvoise admit and that carry into any implementation of the
classical version. It does not minimize the number of insertions — their Figures 9-11 show a
case where one insertion into a common successor beats two into two predecessors, and their
answer is a separate space-saving "temporization" pass afterwards. And it refuses safe
insertions that create a new partial redundancy elsewhere, for want of frequency data.

Safe PRE will not move anything that lengthens any path, which is exactly the transformation
Click's global code motion performs and calls a win. Speculation buys it back only with
frequency information, and lifetime optimality exists to bound the register pressure that the
resulting code motion creates.

# Disagreements

**Click versus Chow, and it is a real fight.** Click's position is that the complexity of PRE
comes entirely from having to preserve a legal schedule while optimizing; drop that
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

**Graphical versus nongraphical, which the modern literature quietly settled the other way.**
Morel and Renvoise's headline practical claim is that PRE needs *no* control-flow analysis:
no intervals, no dominators, no loop identification, and no restriction on graph shape, so
implicit loops, multi-entry loops and exits from nested loops all stop being special cases,
and that is where most of the 7200-to-2500 line reduction comes from. SSAPRE reverses this
completely: it is built on dominance frontiers, needs conventional SSA, and requires all
critical edges split. Both are right about their own cost model. If a compiler already has
SSA and dominators, SSAPRE's prerequisites are free and its sparseness is pure gain. If it
does not, the classical formulation is a smaller thing to build and the reason it is smaller
is exactly the reason it is less precise.

**Draft caveat.** Chapter, section and figure numbers from the SSA Book above come from the
unfinished 8 June 2018 draft in `sources/` and will not match the published Springer edition.
Chapter 11 itself is finished prose with complete algorithms; other chapters in the same file
are outlines. The Morel and Renvoise equations above are transcribed from the CACM 1979 text
directly and need no such caveat.

# For us

Stage 08 is where this lands, and the honest read is that most of PRE's value is already ours
by construction. Our core language binds values with `let`, not memory, so the register
promotion problem that chapter 11.4 solves barely exists for scalars. What is left is real
though: `flvector` element access in a loop is a load PRE problem, and an `flvector-length`
reloaded per iteration is the textbook loop-invariant case.

**Build the classical version first, if we build one at all.** This is a change of position
now that the primary source is in hand. Five Boolean systems over bit vectors, 800 lines in
the original, three iterations to converge, no SSA prerequisite, no dominance frontiers, no
maximal-expression-tree requirement, no critical edge splitting beyond loop initialization
blocks. Against that, SSAPRE needs conventional SSA plus HSSA for aliasing, an FRG construction
per lexical expression, and three analyses. The SSAPRE machinery buys sparseness and lifetime
optimality. For a first cut over the handful of expressions that actually matter to us —
vector lengths, unboxed float temporaries, repeated index computations — we do not need
either, and Morel and Renvoise's non-degradation theorem is enough of a correctness guarantee
to ship behind.

If we do build it, port the bidirectionality knowingly. The `TRANSP_i · PPOUT_i` term is a
known suboptimality, not a bug, and the fix is to reach for lazy code motion's unidirectional
reformulation rather than to patch the equations. We do not hold that paper.

The piece worth taking regardless is the fault-safety mechanism. Our checked accesses are
dangerous computations in exactly Chow's sense. The `tau` variable is the encoding for "this
access sits inside a region where a test already established its safety", which is the same
fact ABCD attaches to a `sigma`-renamed name and Pentagon holds in a flow-sensitive map. The
property that makes it worth copying is that one mechanism does two jobs: a defined `tau`
operand licenses speculation inside the guarded region, and the `tau` definition blocks
hoisting past the guard. That is the discipline stage 07 needs when it moves a check, and it
composes with the control-input pinning rule that stage 10 needs.

Do not build SSAPRE for stage 07's check hoisting. ABCD already produces the insertion set as
a by-product of the redundancy proof, demand-driven per check, rather than running a
placement analysis once per lexical expression in the program. The two would compute
overlapping answers at very different costs.

Do not build a separate loop-invariant code motion pass either, and this is now a sourced
claim rather than an inference. Morel and Renvoise's section 3.4 checks the subsumption case
by case: classical redundancy elimination deletes where `ANTLOC · AVIN`, and those blocks
always satisfy `ANTLOC · PPIN`; classical invariant motion places at the initialization block
`i` of the outermost loop where the computation is invariant, and that block always satisfies
`PPOUT_i = TRUE`. PRE also handles multi-entry loops, which the classical LICM technique
usually cannot.

For dead code, Cytron's control-dependence-driven elimination is the pass to run before any
placement analysis: seed liveness from side effects and propagate backwards through both
definitions and inverse control dependence, so a branch is live only when something control
dependent on it is live. That deletes occurrences before PRE has to reason about them.

Chez is recorded as absent on the basis of `docs/CHEZ-ANALYSIS.md`, which reports that
grepping Chez's sources for `induction`, `loop-invariant`, `licm` and `hoist` returns
nothing and that there is no loop recognition pass in the compiler. PRE subsumes
loop-invariant code motion, so the absence of the latter is evidence for the absence of the
former, though it is not a direct observation of a missing PRE pass.
