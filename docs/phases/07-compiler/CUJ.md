# Phase 7 CUJ: The Compiler

Technical implementation document. Companion to `PLAN.md` in this directory.

The journey is an operator going from an empty directory to a compiler that emits C which
gcc vectorizes, beating tuned scalar SBCL on nbody.

## Preconditions

Phase 1 complete, so Chez is installed as the host and gcc is verified. Nothing else.
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
    08-represent.ss       representation selection
    09-alias.ss           alias analysis for restrict
    10-emit-c.ss          C emission
  runtime/
    gc.c gc.h             precise generational copying collector
    rt.c rt.h             primitives, entry point
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

## Step 4: representation selection and C emission

### Stage 8, representation

Once the domain proves a value is a flonum and never escapes as a general object, give it
a native C type.

```
absval kind 'flonum, does not escape   ->   double
absval kind 'fixnum, bounds fit i64    ->   int64_t
flvector                                ->   double*  plus a length
everything else                         ->   tagged word
```

This is SBCL's IR2 representation selection, and it is the pass that produces the actual
speed.

### Stage 9, alias analysis

Only needs to be good enough to emit `restrict`. Two vectors do not alias if they come
from distinct `make-flvector` calls that both do not escape, which is decidable locally
for the benchmark shapes and is the common case in numeric kernels.

Emitting `restrict` wrongly is undefined behavior, so be conservative: emit it only when
provable, never by default.

### Stage 10, C emission

Target shape, which is what gcc vectorizes:

```c
static void advance(double * restrict xs, double * restrict ys,
                    double * restrict vxs, double s, long n) {
  for (long i = 0; i < n; i++) {      /* no bounds check inside */
    vxs[i] += s * xs[i];
  }
}
```

Rules that matter for the vectorizer:

- No bounds checks inside the loop. Stage 5 or 7 must have removed them.
- `restrict` on every non-aliasing pointer parameter. Stage 9.
- Loop bound in a local variable, not reloaded from memory each iteration.
- No function calls in the body unless inlined. Emit `static inline` and let gcc decide.
- Prefer `long` for induction variables so gcc does not worry about wraparound.

Tail calls: `[[gnu::musttail]]`, verified working on gcc 15.2. Self tail calls can also be
a plain `goto` to the top of the function, which is cheaper and always available.

Build: `gcc -O3 -march=native`. Check the vectorizer with
`-fopt-info-vec-optimized` and diagnose failures with `-fopt-info-vec-missed`.

## Step 5: the runtime

Deliberately small. A precise generational copying collector, not Boehm, because
`../../RESEARCH.md` section 3 showed Boehm is where Stalin loses 5x to 16x on
allocation-heavy code.

Minimum viable: two generations, bump allocation in the nursery, Cheney scan on
collection, a shadow stack or explicit root registration since C owns the real stack.
Precise beats conservative here and the nursery is where nbody's few allocations live.

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
4. **Emitted-code assertions.** For nbody, assert `-fopt-info-vec-optimized` reports the
   inner loop vectorized. That is milestone 3 and it should be a test, not an observation.

## Milestone checkpoints

| milestone | check |
|---|---|
| 1 | nbody compiles and matches the fixture, no optimization |
| 2 | bounds checks gone from nbody's inner loop, verified in emitted C |
| 3 | gcc reports the inner loop vectorized |
| 4 | beats phase 3 configuration 5, tuned scalar SBCL |
| 5 | beats phase 3 configuration 6 scalar C |
| 6 | Pentagon and loop analysis carry fannkuchredux |

Measure with the phase 2 harness, same pinning and the same reporting convention, so the
numbers are directly comparable to the rest of the project.

## Task decomposition notes

Steps 1 and 2 gate everything. The domain module in step 3 is the critical path and the
highest-risk item; build and test it standalone before wiring it into a pass. Stage 5 alone
should reach milestone 2, so stages 6 and 7 can be deferred until nbody works. Step 5, the
runtime, is independent of the whole analysis track and parallelizable; a stub allocator
that never collects is enough to reach milestone 3 on nbody, which allocates almost
nothing. Stage 9 is small and gates milestone 3, so it should not be left to last despite
appearing late in the pipeline order.
