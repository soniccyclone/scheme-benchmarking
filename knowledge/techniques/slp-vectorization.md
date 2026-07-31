---
type: technique
title: Superword level parallelism (SLP) vectorization
description: Vectorize inside a basic block by seeding packs from adjacent memory references and growing them along def-use chains under a cost model, replacing loop-nest dependence testing with unrolling plus scalar renaming.
tags: [slp-vectorization, simd, alignment-analysis, basic-block-analysis, uncommon-branch, loop-unrolling]
sources:
  - resource: /works/larsen-amarasinghe-exploiting-superword-level-parallelism-.md
  - resource: /works/h-lzle-ungar-optimizing-dynamically-dispatched-calls-with-.md
  - resource: /works/chambers-ungar-customization-optimizing-compiler-technolog.md
  - resource: /works/click-global-value-numbering-and-code-motion.md
  - resource: /works/rastello-et-al-ssa-based-compiler-design-the-ssa-book.md
implemented_by: []
absent_from: [/implementations/chez.md, /implementations/sbcl.md]
pipeline_stage: 10-vectorize
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

Turn scalar f64 arithmetic into packed SIMD without building a loop-dependence framework.
Classical vectorization asks "is this loop nest a legal vector loop," which fails
catastrophically: one bad statement sequentializes the whole loop, and partially vectorizable
loops need fission, scalar expansion and dependence testing to salvage. SLP asks the local
question. Are there n isomorphic independent statements next to each other in one basic block,
and is the packed form cheaper. Vector parallelism becomes a strict *subset* of superword level
parallelism, because unrolling turns a vector loop into exactly the straight-line pattern the
algorithm was going to look for anyway.

*Alignment analysis* folds in here rather than standing alone. In SLP alignment is not a
separate analysis but a per-statement attribute that propagates along the same chains the
packing search walks, and that prunes that search.

# Mechanism

A *Pack* is an n-tuple of independent isomorphic statements from one basic block, isomorphic
meaning the same operations in the same order. A *Pair* is a Pack of size two with a designated
left and right element. During pairing a statement may belong to two packs provided it is left
in one and right in the other, and that invariant is what lets the combination phase chain pairs
into datapath-width groups.

1. **Unroll early**, at high IR level. The factor comes from the smallest data type against the
   datapath width. For f64 on 512-bit `zmm`, that is 8.
2. **Alignment analysis.** Annotate every load and store with its alignment modulo the datapath
   width. Flow-insensitive and context-insensitive, breadth-first over the call graph for
   Fortran; C needs a pointer analysis that also supplies location sets so dependences can be
   checked more carefully.
3. **Flatten to three-address form**, then constant propagation, copy propagation, DCE, CSE,
   LICM, redundant load/store elimination, and finally scalar renaming to kill output and
   anti-dependences. Annotate address computations with adjacency *before* flattening, because
   adjacency is easy to see in tree form and hard afterward.
4. **`find_adj_refs`.** Scan for independent pairs of statements containing adjacent memory
   references and seed the PackSet. In practice a reference is adjacent to at most two others.
5. **`extend_packlist`.** Iterate to a fixpoint, following use-def chains to produce operands
   already packed and def-use chains to consume packed results. Admit a candidate pair only if
   the statements are isomorphic and independent, neither is already packed in the corresponding
   position, alignments are consistent, and `est_savings` says the SIMD form costs less.
   Alignment propagates from the seeds along the chains, and since a statement holds only one
   alignment, that constraint prunes the search.
6. **`combine_packs`.** Merge pack `p` ending in `s_n` with pack `p'` beginning in `s_n`, to a
   fixpoint. Because seeds never straddle an alignment boundary and all alignments descend from
   the seeds, no combined group can exceed the datapath width.
7. **`schedule`.** Emit in original order, scheduling a statement when its dependences are
   satisfied and a pack only when every member's are. A cycle in the dependence graph *between
   packs* means the chosen set is invalid; break it by splitting the pack containing the
   earliest unscheduled statement. Reported as extremely rare, handled for correctness.

Cost model: count instructions added and removed including packing and unpacking, charging n-1
instructions to pack n values, but zero if the packed operand already exists in the PackSet.
That one rule is what makes chain-following worth doing, because the algorithm is then trying to
build chains where packed data flows producer to consumer without touching memory.

**Getting a clean body to vectorize.** SLP needs an unconditional straight-line block, and a
Scheme numeric loop is not one until the representation guards are gone. The mechanism is
*uncommon branch elimination*, credited to John Maloney and first implemented in SELF-91, read
backwards from its original use. Do not guard per operation and merge back:

```
if (rep(x) != unboxed_f64) goto general_version;   // separate copy, never merges back
...loop body, every value known unboxed f64...
```

The non-merging copy is the load-bearing part. If the two versions rejoin, the fast path's
dataflow is polluted at the join by pessimistic alias and kill information from the general
case, and the representation facts are lost one statement later. Hölzle and Ungar are explicit
that this, not the guard itself, is what makes a guard useful rather than merely correct.
Chambers and Ungar state the goal from the other direction in their section 6.1: split off
entire sections of the control flow graph corresponding to the most common data types, so that
along those sections every variable's type is known and no run-time checks remain, with
exceptional cases transferring control out to a more general section. That is our precondition
list, arrived at from message dispatch.

# Preconditions

Three-address IR, or isomorphism matching degenerates into requiring syntactically identical
expression trees. Scalar renaming, which SSA supplies free. Alignment information, or every wide
access needs defensive merge code. Adjacency preserved across flattening. Analysis stops at the
basic block boundary, so packed values are unpacked at block exits and any loop with control
flow in its body pays that per iteration.

Ours on top of the paper's: no bounds check left in the body, array operands provably
non-aliasing, every value a proven unboxed f64, no calls and no allocation. And Click's pinning
discipline applies as an IR invariant, not an optimization. Checked accesses, allocations and
anything that can raise carry an explicit control input so motion is only ever downward. Get
that wrong and vectorization will hoist a trap above its guard.

The paper's own failure modes are about trip counts, not dependences. Wide datapaths can hurt:
`applu` drops from 22.56% vectorizable at 256 bits to 0.01% at 1024 bits, because the unroll
factor needed to fill the datapath exceeds the dynamic trip count and the unrolled loop is never
entered. `turb3d` peaks at 256 bits, `fpppp` at 192 because its hottest loop is already unrolled
by three. Optimum datapath width is a property of loop trip counts, and their compiler had no
fallback when the unrolled loop is not entered.

# Cost

Linear in program size, no global analysis. That plus robustness (failing to pack a few
statements degrades gracefully), simplicity, and portability (basic blocks exist in all code,
loops over arrays do not) are the four properties the authors argue will make SLP adopted where
loop vectorization was not. Measured: 46% of dynamic instructions eliminated on average,
speedups 1.24 to 6.70 on a 450 MHz MPC7400 with AltiVec. Vectorizable fraction on SPEC95fp:
`mgrid` 34.29% to 55.13%, `apsi` 15.89% to 29.93%, `fpppp` 0.00% to 8.14%, with about 20% of
the instruction savings from sequences no vectorizer can reach.

The precision you give up is reassociation, and it is not optional to decide. Element-wise
operations are exact, since each lane computes what the scalar loop computed for that index.
Reductions are not: vectorizing a sum reassociates the additions and changes the result. Our
nbody output is diffed to nine decimal places, so reductions stay scalar or use an ordered
reduction. Never silently reassociate.

# Disagreements

The sources do not conflict on the algorithm. The paper conflicts with its own headline. "46% of
dynamic instructions" and "speedups 1.24 to 6.70" are different benchmark sets measured
differently. The 46% is an instrumented instruction count over all fifteen benchmarks at a
hypothetical datapath width, counting all instructions equally including SIMD ones. The speedups
are wall clock on seven benchmarks with **optimization disabled**, because the AltiVec gcc
extensions were experimental, so both base and SLP versions are unoptimized code. Most SPEC95fp
benchmarks could not run at all, needing double precision their AltiVec target lacked. The 6.70
is YUV, a 16-bit fully vectorizable kernel and the best case by a wide margin; the median real
speedup in Table 4 is about 1.5. Plan against 1.5.

The claim that vector parallelism is a strict subset of SLP is supported by Table 3 for every
benchmark measured, multimedia kernels tying exactly and scientific codes always favoring SLP.
That is the paper's strongest result and it holds.

Transcription notes: `SLP_extract` in Figure 5 calls `extend_packlist` while section 3.5 calls
the same routine `extend_packset`, and the PDF's text layer loses `fi` and `fl` ligatures
throughout ("dicult", "signicant", "protable").

# For us

Stage 10, and the whole justification for the stage is a gap verified by reading two back ends
rather than inferred.

**Chez emits only scalar SSE.** `s/x86_64.ss` contains `addsd`, `mulsd`, `subsd`, `divsd`,
`sqrtsd`, `movsd`, `cvtsi2sd`. Every one is an `sd`, scalar double. There are no packed
encodings in the file at all; the three `xmm` mentions are comments about which registers the C
calling convention preserves. **SBCL can encode AVX-512 but has no autovectorizer.**
`src/compiler/x86-64/` has `avx512-insts.lisp` and `avx2-insts.lisp`, so the assembler knows the
encodings, and `contrib/sb-simd` exposes them as user-callable intrinsics, but
`grep -rlin vectoriz src/compiler/*.lisp` returns nothing. Vector code exists in SBCL only where
a human wrote an intrinsic. See `docs/CHEZ-ANALYSIS.md`. No Lisp-family compiler turns an
ordinary scalar loop into packed arithmetic, so this pass is the concrete way to exceed Common
Lisp and the reason to own the back end.

The fit is structural, not incidental. Scheme numeric kernels after A-normalization and inlining
are long straight-line blocks of three-address operations with named intermediates and adjacent
flonum vector accesses, which is precisely SLP's input, so the A-normalization we are doing for
other reasons hands the pass its precondition free.

The seeding decision is the dependency to watch. The algorithm keys on adjacent memory
references because the operands are pre-packed and one address computation replaces n. For us
that means `f64vector` and bytevector accesses with statically adjacent indices. If stage 08
does not produce unboxed adjacent flonum layouts, the seed set is empty and the pass finds
nothing. SLP is downstream of representation in a hard sense, not merely a pipeline-ordering one.

Two adaptations. Modern targets have the register-to-register moves and unaligned accesses whose
absence dominated the AltiVec measurements, so our packing costs are far lower and the cost
model should be re-tuned rather than copied. And guard the unroll-factor hazard: take the factor
from stage 07's trip-count estimate where one exists, and always keep a scalar remainder loop,
which they did not.

Build the non-merging duplicate into the core language early. Retrofitting a copy that never
rejoins onto a merge-based CFG is painful, and the precondition list above is unsatisfiable
without it whenever the representation proof is probable rather than certain. Loop-closed SSA
(SSA Book 6.2.3) is the companion discipline, since placing a function at the head of the loop
it exits is what lets us name the loop's exit value at all, which both the remainder loop and
the general-version copy need.
