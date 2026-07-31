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
    (primcall pr e* ...)
    (declare (x* p*) ... body)      ; premises
    (policy (c* ...) body)))        ; lexical check policy
```

The last two forms are the point. `declare` binds a predicate to a variable for a scope.
`policy` carries per-check suppression lexically, which is wall 3 from `PLAN.md` removed
by construction: the policy lives in the environment threaded through the passes, not in
a global parameter.

## Step 3: the abstract domain

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

Widening is required for termination on loops. Use the standard approach: widen to
unbounded after a fixed iteration count, then optionally narrow. Cousot and Cousot 1977 is
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

Pentagon rather than Octagon deliberately: the paper's whole argument is that Pentagon is
the cheap domain that still proves most array accesses safe. Octagon at O(n²) space and
O(n³) time is over-engineering until measurement says otherwise.

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

**Precise GC roots are why this is worth the work.** At every call site the allocator knows
which registers and stack slots hold live references, so emit a stack map. That is what a
precise generational collector needs and what a C back end cannot provide.

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
2. **Pass tests.** Each pass on fixtures, asserting the output core language.
3. **End-to-end differential testing.** Compile each benchmark, diff output against the
   Benchmarks Game fixture. Compile the same program with all optimization disabled and
   diff the two outputs against each other. Any divergence is an unsound analysis.
4. **Disassembly assertions.** Milestones are verified in emitted code, not by timing.
   Assert no bounds-check branch remains in nbody's inner loop (milestone 2) and that
   `vfmadd231pd` on a `zmm` register appears (milestone 4). Both are greps over our own
   disassembler output and both should be tests rather than observations.

## Milestone checkpoints

| milestone | check |
|---|---|
| 1 | nbody compiles to native code, runs, matches the fixture |
| 2 | no bounds-check branch in the inner loop, verified in disassembly |
| 3 | beats phase 3 configuration 5, tuned scalar SBCL |
| 4 | packed AVX-512 in the inner loop, verified in disassembly |
| 5 | beats phase 3 configuration 6 at `-O3 -march=native` |
| 6 | Pentagon and loop analysis carry fannkuchredux |

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
