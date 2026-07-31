# Phase 7 CUJ: The Compiler

Technical implementation document. Companion to `PLAN.md` in this directory.

The journey is an operator going from an empty directory to a native x86-64 compiler that
emits packed AVX-512 for an f64 loop, which no Lisp-family compiler currently does.

## Preconditions

Phase 1 complete, so Chez is installed as the host. Nothing else.
This phase does not wait on phases 2 through 5.

## Repo layout

```
compiler/
  Makefile
  boot.ss                 loads nanopass and the passes in order
  lang/
    core.ss               nanopass language definitions, one per stage
  passes/
    01-read.ss            reader
    02-expand.ss          syntax-rules expander
    03-parse.ss           surface to core
    04-declare.ss         declaration forms into the environment
    04b-inline.ss         procedure inlining. See the ordering note below
    05-intervals.ss       level 2 domain
    06-pentagon.ss        level 3 domain
    07-loops.ss           loop recognition, induction variables
    08-represent.ss       storage class assignment
    09-alias.ss           alias analysis
    10-vectorize.ss       scalar f64 loop to packed, the pass nobody has
    11-select.ss          instruction selection
    12-regalloc.ss        linear scan register allocation
    13-assemble.ss        x86-64 + AVX-512 encoding, emit an object file
  runtime/
    gc.c gc.h             precise generational copying collector
    rt.c rt.h             entry point, foreign boundary
  tests/
    pass/                 one test per pass, on core-language fixtures
    programs/             end-to-end: nbody, fannkuchredux, spectralnorm
```

## Step 1: substrate

```
git submodule add https://github.com/nanopass/nanopass-framework-scheme vendor/nanopass
```

`boot.ss` loads it and the passes. Verify with a trivial identity pass over a two-form
language before writing anything real, because nanopass's `define-language` and
`define-pass` error messages are hard to read cold and you want a known-good baseline.

Reference: Keep and Dybvig, "A Nanopass Framework for Commercial Compiler Development,"
ICFP 2013. Chez itself is built this way.

## Step 2: the core language

Keep it small. Everything after stage 3 operates on this.

```scheme
(define-language Lcore
  (terminals
    (symbol (x))
    (primitive (pr))
    (datum (d)))
  (Expr (e body)
    x
    (quote d)
    (if e0 e1 e2)
    (let ([x* e*] ...) body)
    (letrec ([x* e*] ...) body)
    (lambda (x* ...) body)
    (call e0 e* ...)
    (primcall pr c e* ...)          ; c is a control input, see below
    (declare (x* p*) ... body)      ; premises
    (policy (c* ...) body)))        ; lexical check policy
```

**Faulting primitives need a control input, and stage 10 depends on it.** `primcall` above
carries `c` for exactly this. Click's discipline is that loads, stores, division, calls and
anything else that can trap take an explicit control input, so code motion on them is only
ever downward and a trapping operation can never be hoisted above the test that guards it.
Without it, nothing in the IR distinguishes a `flvector-ref` that may fault from a pure
arithmetic node, and the vectorizer at stage 10 is free to move it somewhere it must not go.
This belongs in the language definition rather than in a later pass, because retrofitting it
means revisiting every pass that constructs a `primcall`. Chow's `tau` variables are the
same idea pointed the other way, for speculation.

**If we move to SSA for ABCD, go to e-SSA directly.** ABCD does not run on vanilla SSA. It
needs sigma-assignments on both arms of every conditional over the variables in the test,
plus a fresh name after every checked access, or a check trivially proves itself redundant.
The SSA Book ch. 13 tabulates the splitting strategy per client, and ABCD's row is
`Defs↓ ∪ Out(Conds)↓`. Budget the `clean` pass alongside it.

**Resist over-refining these types.** Steele's own post-mortem on RABBIT (p. 174) argues
against having split `CLAMBDA`/`CONTINUATION` and `CCOMBINATION`/`RETURN` into distinct IR
node types, because it forced the second pass to be written twice over near-identical
shapes. That is an argument against fine-grained IR types from the person who invented this
style of compiler, and nanopass makes adding a type cheap enough that the temptation is
real. Prefer one node with a discriminating field over two nodes whose passes diverge only
in a line or two.

The last two forms are the point. `declare` binds a predicate to a variable for a scope.
`policy` carries per-check suppression lexically, which is wall 3 from `PLAN.md` removed
by construction: the policy lives in the environment threaded through the passes, not in
a global parameter.

## Two ordering corrections, found in wave 2

The pass list above is numbered for readability, not as a dependency order. Two of its
implied orderings are wrong, and both were caught by synthesis agents reading the sources
against the plan.

**Stage 08 depends on stage 09, not the reverse.** Storage class assignment keys its table
on "proven flonum, does not escape", and escape analysis is the pass that proves it. Either
alias and escape analysis runs before representation selection, or representation runs twice,
or the escape-conditioned rows of that table are dead on arrival. Two independent
sources reached this: the escape-analysis synthesis and the Steensgaard work document.

**There was no inlining pass at all, and four stages depend on one.** `01-read` through
`13-assemble` contained no inliner, no closure conversion and no assignment conversion, while
stages 05, 06, 08 and 10 all assume inlining has run. Three sources demand inline-first, for
different reasons: Leroy, because storage class assignment before inlining leaves coercion
redexes that never cancel; Hölzle and Ungar, because narrowing is much cheaper after inlining
and running the domain first invites declaring victory early; and Waddell and Dybvig via
Ashley, because inlining invalidates the flow information that justified it, so the order
matters in both directions. `04b-inline.ss` is added above, between declaration processing
and the first domain pass, and A-normalization should be re-run after it per Flanagan et al.

Note that documents already in `knowledge/` carry `pipeline_stage` values keyed to the old
numbering. Those references are stale in numbering only, not in meaning.

## Step 3: the abstract domain

**A-normalize before stage 05. It is a precondition, not an ordering preference.**
Flanagan et al.'s A1 rule is what brings a fact established inside a `let` body into scope
for the enclosing continuation, and A2 is what gives a conditional's two branches separate
abstract states. Run the interval domain over un-normalized code and it sees strictly less,
for reasons that have nothing to do with the domain's precision. Re-run normalization after
`04b-inline`, since inlining reintroduces nesting.

This is the contribution. Implement it as its own module with a tested interface before
wiring it into a pass, because every later stage depends on it being right.

### Stage 5, the interval domain (level 2)

```scheme
;; an abstract value
(define-record-type absval
  (fields kind        ; 'flonum 'fixnum 'flvector 'other 'bottom
          lo hi       ; inclusive integer bounds, or #f for unbounded
          len))       ; for vectors: known length, or #f
```

Operations needed, standard lattice interface: `join`, `meet`, `widen`, `implies?`,
`bottom?`. Transfer functions for the arithmetic primitives.

Widening is required for termination on loops. **Use widening with thresholds, not the
plain jump to unbounded.** Astrée used a single untuned dense ramp of a few dozen values
across every program it analysed, and every bound stabilised at the smallest threshold above
the concrete bound. Cousot and Cousot anticipate the technique in §9 of the 1977 paper. It
is nearly free and it is the difference between recovering `[1,101]` and recovering nothing
on a loop whose bound is not syntactically obvious. Cousot and Cousot 1977 is
the framework; any abstract interpretation text has the interval instance.

The bounds check transfer function is the payoff:

```
at (primcall flvector-ref v i):
  if absval(i).lo >= 0 and absval(i).hi < absval(v).len
     then emit unchecked access
     else emit checked access
```

For nbody this suffices, because the arrays are length 5 and the length is a compile-time
constant, so `absval(v).len` is known and the loop indices have derivable bounds. Theory
predicts milestone 2 falls out of stage 5 alone.

### Stage 6, Pentagon (level 3)

Add a strict upper-bound relation per variable, following Logozzo and Fähndrich 2008:

```scheme
;; pentagon = intervals + a map x -> set of y such that x < y
(define-record-type pentagon (fields intervals strict-lt))
```

Needed when the array length is not a compile-time constant, which is
`fannkuchredux` and most real code. The check becomes provable when `i` is in the
`strict-lt` set of the variable holding the length.

**Cheap fallback if the reduced product proves fiddly.** Logozzo's own Figures 11 and 12
report that an *unreduced* Cartesian product of intervals and strict upper bounds validates
88.82% of accesses, against 88.89% for full Pentagons. The entire reduced-product machinery,
the refined order and the cross-checking join, is worth 0.07 percentage points. Running the
two domains side by side captures essentially all of the value, so build that first and add
reduction only if measurement demands it.

Pentagon rather than Octagon deliberately, and the Pentagons paper's own §8.1 is stronger
evidence than its abstract: **closure made Pentagons less precise, not more**, on three of
four .NET assemblies (82.77% against 83.19% on mscorlib) while tripling analysis time. Our
stage-06 design is validated by the authors' own measurements, buried where most readers
would miss them.

**Three implementation warnings, all from reading the source papers rather than summaries:**

1. **The Pentagons paper prints four transcription errors, and one is an unsound
   widening in both halves.** Figure 3 reads
   `[a₁ ≤ a₂ ? a₂ : -∞, b₁ ≥ b₂ ? b₂ : +∞]`; the intent is `a₁` and `b₁` in the true
   branches, and as printed it tightens both bounds. **The bug is masked whenever the
   iterate sequence is monotone increasing**, which is exactly what a naive test suite
   produces, so it will pass tests and fail on real input. Figure 5's `Sub` widening carries
   the identical one-operand substitution, and §6.2.2's `rem` transfer function assigns to
   `x` where the statement's variable is `r`, with an unbalanced bracket. Figure 3's `sub`
   also prints `b(inf(y))` for `inf(b(y))`. Treat every formula in that paper as
   transcription-suspect and re-derive.
2. **Never strongly-close the left argument of a widening.** Miné exhibits a four-line
   program that produces a strictly increasing infinite chain if you do. Pentagon's `Sub`
   has no closure operation at all, so the hazard simply does not arise. That is an
   architectural reason for this choice, not merely a cost one.
3. Take three things from Miné without implementing octagons: **widening with thresholds**
   (a dense ramp of a few dozen values, reused untuned across all of Astrée), **interval
   linear forms** with formal cancellation performed before interval evaluation, and the
   **packing algorithm** if a relational domain is ever added.

### Stage 7, loops and induction variables

Wall 2 removed. Required before any check can be hoisted out of a loop rather than proven
inside it.

1. Recognize loops. In the core language a loop is a `letrec`-bound procedure called in
   tail position from its own body, which is the standard Scheme idiom and easier to
   detect than a general natural-loop analysis on a CFG.
2. Identify induction variables: parameters whose argument at the recursive tail call is
   the parameter plus a constant.
3. Derive the range from the loop guard. If the body is
   `(if (fx<? i n) ... (loop (fx+ i 1)))` then `i ∈ [i₀, n)` throughout the body.
4. Hoist. If every access in the body is provable from the derived range, emit the check
   once before the loop instead of per iteration.

Reference algorithms: Gupta 1993 for the flow-analysis formulation, and ABCD
(Bodík, Gupta and Sarkar, PLDI 2000) for the demand-driven version on SSA. ABCD's
inequality-graph approach is the better fit if the representation moves to SSA later.

## Step 4: representation, vectorization, and native emission

### Stage 8, storage class assignment

Follow SBCL's IR2 model. Each value gets a storage class, not just a type.

```
proven flonum, does not escape          ->  xmm register, unboxed f64
proven flonum, escapes                  ->  boxed, tagged pointer
proven fixnum, bounds fit 61-bit tag    ->  general register, tagged
proven fixnum, loop index only          ->  general register, untagged
flvector                                ->  pointer plus known or derived length
anything unproven                        ->  tagged descriptor
```

The untagged loop index case matters more than it looks. A tagged fixnum needs a shift for
multiplication; an untagged index used only for addressing does not. SBCL wins some of its
margin here.

### Stage 9, alias analysis

**Steensgaard's precision limit is our common case, not a corner case.** Unification is
symmetric and permanent, so a single `(let ([v (if p a b)]) ...)` merges `a` and `b`
program-wide and forever. In a numeric kernel where several arrays flow through one shared
helper, that is the ordinary shape rather than a pathological one. Budget for it: either
accept the merge and lose `restrict` on those arrays, or use an inclusion-based analysis for
the arrays specifically. Do not assume almost-linear time comes for free at our precision
requirement.

Note also that the same pass pays for itself twice. Steensgaard's `lam` component yields
0CFA-strength call-target information, which feeds direct-call selection at stage 11 and
closure representation at stage 08. That is a second reason this stage should land before
stage 08 finishes rather than after it.

Only needs to answer one question: are these two flvectors provably distinct? Two values
from distinct `make-flvector` calls that do not escape are distinct, which is decidable
locally and covers the numeric kernel shapes. Anything unproven is assumed to alias.

Getting this wrong makes vectorization miscompile, so default to aliasing and only claim
distinctness when proven.

### Stage 10, vectorization

The pass no Lisp compiler has. Preconditions, all supplied by earlier stages:

1. The loop is recognized and has an induction variable with a derived range (stage 7).
2. No bounds check remains in the body (stage 5 or 6).
3. Array operands are provably non-aliasing (stage 9).
4. Every value in the body is a proven unboxed f64 (stage 8).
5. The body has no calls, no allocation, and no control flow.

Then rewrite:

```
for i in [0, n):  a[i] = a[i] + s * b[i]

becomes

vbroadcastsd  zmm2, s
for i in [0, n - n mod 8) step 8:
    vmovupd       zmm0, [a + i*8]
    vmovupd       zmm1, [b + i*8]
    vfmadd231pd   zmm0, zmm1, zmm2
    vmovupd       [a + i*8], zmm0
for i in [n - n mod 8, n):        ; scalar remainder
    a[i] = a[i] + s * b[i]
```

**The floating point trap, decided per loop and not discovered later.** Element-wise
operations like the above are safe: each lane computes exactly what the scalar loop
computed for that index. Reductions are not. Vectorizing a sum reassociates the additions
and changes the result, and nbody's output is diffed against a fixture to nine decimal
places. So: vectorize element-wise loops freely, and for reductions either keep them scalar
or use an ordered reduction. Never silently reassociate.

### Stages 11 through 13, native emission

Instruction selection over the core language after representation assignment.

**On register allocation, the linear-scan-versus-graph-coloring framing is wrong**, per
ch. 22 of the SSA Book. Linear scan *is* tree scan with the dominance tree flattened into a
linear interval, and that flattening is precisely the source of its over-approximated live
ranges. Tree scan strictly dominates it at the same cost. Further, on SSA input the
classical simplify scheme is already exact, so the two approaches converge rather than
trading off. If the representation moves to SSA, build tree scan and stop treating this as
a choice.

Either way the acceptance test is the same: count spills in the emitted inner loop. If any
unboxed f64 spills across the loop body, the allocator is erasing the analysis and needs
replacing.

Two separate register files to allocate: general purpose for tagged values and untagged
integers, and `xmm`/`zmm` for unboxed floats. Respect the platform ABI only at the foreign
boundary; inside Lisp code the convention is ours, which is one of the reasons for owning
the back end.

For encodings, `sbcl/src/compiler/x86-64/avx512-insts.lisp` and `avx2-insts.lisp` are the
reference. For register allocation structure, Chez's `s/x86_64.ss` and `s/np-register.ss`
(168 lines, small and readable) are the reference.

**One modern caveat on the 1990 design.** Hieb, Dybvig and Bruggeman's stack walking reads
the frame size out of the code stream adjacent to each return address. That assumes the code
stream is readable and co-located, which W^X and pointer-authenticated or signed return
addresses both break. It is the one part of the design that does not transfer unchanged, and
our precise-GC-roots argument leans on it, so budget a side table mapping return addresses
to frame descriptors rather than assuming the original trick works.

**Precise GC roots are why this is worth the work.** At every call site the allocator knows
which registers and stack slots hold live references, so emit a stack map. That is what a
precise generational collector needs and what a C back end cannot provide.

## A measured pass budget

Keep's dissertation makes the cost of adding passes concrete, which the nanopass style
otherwise invites hand-waving about. Marginal per-pass cost is 0.20 to 0.26% of back-end
time before primitive expansion, against 2.18 to 2.20% after instruction selection, with a
68.5 to 69.0% traversal overhead overall. Stages 05 through 10 all sit in the cheap region,
so the analysis passes this document adds cost a few percent of compile time, not a
multiple.

One caution from the same source: per-benchmark compile-time ratios ranged from 1.00x to
4.73x with no correlation to program size, and the authors could not explain the spread. Do
not treat a single benchmark's compile time as representative.

## Step 5: the runtime

Deliberately small. A precise generational copying collector, not Boehm, because
`../../RESEARCH.md` section 3 showed Boehm is where Stalin loses 5x to 16x on
allocation-heavy code.

Minimum viable: two generations, bump allocation in the nursery, Cheney scan on collection,
and precise roots from the stack maps stage 13 emits. No shadow stack is needed, because we
own the frame layout.

Escape analysis for stack allocation is a later milestone and is one of the four
capabilities in `PLAN.md` where we would exceed SBCL, since CL's `dynamic-extent` is
manual.

## Verification

Every stage gets tested in isolation on core-language fixtures, because a wrong abstract
domain silently produces wrong code rather than failing loudly. That is the single most
dangerous failure mode in this project.

1. **Domain unit tests.** These are pure functions with complex logic, which is exactly
   the case where unit tests earn their keep. Test `join`, `meet`, `widen` for
   monotonicity and for termination. An unsound `implies?` removes a check that was
   needed and corrupts memory.

   **Lattice laws are not the soundness obligation, though.** Monotonicity and termination
   say the analysis converges; they say nothing about whether it converges to something
   true. The property that actually guarantees we never delete a needed check is Cousot's
   local consistency condition from §6 of the 1977 paper: for each transfer function,
   `γ(Int(a, x)) ⊇ Int(a, γ(x))`. That is a per-instruction obligation and it is directly
   testable, so test it per primitive rather than trusting the lattice laws to imply it.
2. **Pass tests.** Each pass on fixtures, asserting the output core language.
3. **End-to-end differential testing.** Compile each benchmark, diff output against the
   Benchmarks Game fixture. Compile the same program with all optimization disabled and
   diff the two outputs against each other. Any divergence is an unsound analysis.
4. **Disassembly assertions.** Milestones are verified in emitted code, not by timing.
   Assert no bounds-check branch remains in nbody's inner loop (milestone 2) and that
   `vfmadd231pd` on a `zmm` register appears (milestone 4). Both are greps over our own
   disassembler output and both should be tests rather than observations.

## Milestone checkpoints

**A caveat on every milestone below.** `nbody` is the single benchmark on which Chez's
`cp0` inliner does *not* help: Waddell and Dybvig report 0.92 to 1.05 on the R4400, and
attribute it to cache effects from three-level nested array indexing without measuring that
attribution. It is the one place their "no benchmark regresses" claim is doing real work, and
it is the program all six milestones below are written against. If our own inlining pass
shows nothing on nbody, that is the expected result rather than evidence of a broken pass.

| milestone | check |
|---|---|
| 1 | nbody compiles to native code, runs, matches the fixture |
| 2 | no bounds-check branch in the inner loop, verified in disassembly. **Not independently valuable**, see below |
| 3 | beats phase 3 configuration 5, tuned scalar SBCL |
| 4 | packed AVX-512 in the inner loop, verified in disassembly |
| 5 | beats phase 3 configuration 6 at `-O3 -march=native` |
| 6 | Pentagon and loop analysis carry fannkuchredux |

**Milestone 2 is a means, not an end, and ABCD says so with a number.** Bodík, Gupta and
Sarkar removed 45% of bounds checks and got about 10% speedup, because Jalapeño had no
global code motion and the freed scheduling went unused. Removing a check is only worth
something if a later pass consumes the freedom it creates. For us that consumer is stage 10
(vectorization, which the check made illegal) and stage 11. Treat milestone 2 as a gate on
milestone 4 rather than as a result to celebrate on its own.

Two related notes on stage dependencies. Stage 07 also gates stage 10's unroll factor, not
just check hoisting: Larsen's `applu` case goes from 22.56% vectorizable at 256 bits to
0.01% at 1024 bits, which is what happens when a vectorizer guesses a trip count. And if
ABCD is built for stage 06, its amplifying-cycle detection supplies induction-variable
discrimination for free, so stage 07 shrinks but does not disappear, because ABCD does not
supply a trip count.

Measure with the phase 2 harness, same pinning and the same reporting convention, so the
numbers are directly comparable to the rest of the project.

## Task decomposition notes

Steps 1 and 2 gate everything. The back end (stages 11 through 13) gates milestone 1, so it
comes before any analysis: a compiler that emits correct scalar code is the platform every
later measurement is taken against. The domain module in step 3
is the highest-risk item and should be built and tested standalone before wiring into a
pass, because an unsound domain miscompiles silently. Stage 5 alone should reach milestone 2,
so stages 6 and 7 defer until nbody works. Stage 10, vectorization, depends on 5, 7, 8 and 9
all being correct, so it is last despite being the headline. The runtime is independent and
parallelizable; a bump allocator that never collects is enough through milestone 5, since
nbody allocates almost nothing.
