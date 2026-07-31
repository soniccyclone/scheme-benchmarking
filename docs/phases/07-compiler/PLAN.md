# Phase 7: The Compiler

## Goal

Build an optimizing Scheme compiler whose analysis can reach Common Lisp levels of
optimization and then exceed them.

## Why this is required rather than optional

An earlier revision of this plan argued against building a compiler on the grounds that
you should not write one to prove a claim about a standard. That argument was answering
the wrong question. It holds for the standards question, which a five-line macro and a
measurement can settle (`../../CHEZ-ANALYSIS.md` section 2). It does not hold for the
question of whether Scheme can reach and beat CL-level optimization, because that is a
compiler question and there is no way to answer it without a compiler.

Chez cannot host the experiment. Four walls, all architectural, none reachable from
outside the implementation:

1. **The type lattice is level 1.** `cptypes-lattice.ss` is a finite lattice of
   categories. `index`, `length` and `sub-index` collapse to `fixnum-pred`. It cannot
   represent `i ∈ [0,5)`, so bounds check elimination is unrepresentable, not merely
   unimplemented.
2. **There is no loop analysis at all.** No induction variables, no LICM, no loop
   recognition anywhere in `s/*.ss`. Every classical bounds-check-elimination technique
   is loop-based.
3. **`optimize-level` is a global compile-time parameter, not a lexical form.** Scoped
   check suppression has no faithful target.
4. **There is no user-facing way to feed the lattice** beyond predicate tests, and
   predicates cannot express relational facts.

Each of these is a design decision inside Chez, made deliberately for compile speed.
None can be macro'd around. So experimenting on Chez measures Chez's ceiling, not the
design's.

The tractability objection also does not hold. The nanopass framework exists and is
maintained, and Chez itself is written in nanopass style by the people who invented it.
This is a known-shape project, not a research gamble.

One hedge on a claim an earlier draft made here. SICP chapter 5 is often cited as evidence
that writing a Scheme compiler is undergraduate work, and that is true of a *correct*
compiler but not of an *optimizing native* one. Section 5.5's entire optimizer is a single
rule, `preserving`, a local save-and-restore elision with no liveness dataflow. It has no
intermediate representation, and it targets an abstract machine whose primitives include
`extend-environment` and `apply-primitive-procedure`. It also offers no answer to the
precise-GC-root problem that this section uses to rule out a C back end. It is evidence
about shape, not about difficulty.

## The back end is native. Not C.

Emitting C is disqualified, and not only because laundering gcc's optimizer would prove
gcc is fast rather than that Lisp is fast. It structurally caps the compiler at a level
below both reference implementations:

**No precise GC roots.** C will not tell you which registers hold live references at a
call site. That forces a shadow stack or conservative scanning. Chez and SBCL emit native
code precisely so they can have accurate roots in registers, and `RESEARCH.md` section 3
already showed what a conservative collector costs: Stalin loses 5x to 16x on
allocation-heavy code because it falls through to Boehm.

**No calling convention control.** No multiple return values in registers, no custom
register partitioning between Lisp and foreign code, no general tail calls.
`[[gnu::musttail]]` is per-site and does not cover mutual recursion through an unknown
callee.

**Continuations permanently blocked.** C owns the stack, so `call/cc` can never be more
than escape-only. An earlier draft called that an acceptable compromise. It is not: it
means the compiler can never grow up.

**Representation control is the whole point.** SBCL's IR2 assigns values to specific
storage classes and register files. Through C you describe intent and hope gcc infers it.
The thing that makes Lisp fast is exactly the thing C takes away.

So: native x86-64, our own instruction selection, our own register allocator, our own
assembler. Chez's back end is the scale reference at `cpnanopass.ss` (10912 lines) plus
`x86_64.ss` (3504 lines), and it is readable nanopass rather than a wall of macros.

## The open field: nobody in the Lisp family auto-vectorizes

Verified by reading both back ends.

**Chez emits only scalar SSE.** `s/x86_64.ss` contains `addsd`, `mulsd`, `subsd`,
`divsd`, `sqrtsd`, `movsd`, `cvtsi2sd`. Every one is an `sd`, scalar double. There are no
packed instruction encodings at all. The three `xmm` mentions in the file are comments
about which registers the C calling convention preserves.

**SBCL can encode vectors but never generates them.** `src/compiler/x86-64/`
has `avx512-insts.lisp` and `avx2-insts.lisp`, so the assembler knows the encodings, and
`contrib/sb-simd` exposes them as user-callable intrinsics. But
`grep -rlin 'vectoriz' src/compiler/*.lisp` returns nothing. There is no
auto-vectorization pass. Vector code exists in SBCL only where a human wrote an intrinsic,
which is why Bela Pecsek's fast entries are hand transliterations of Zig.

So no Lisp-family compiler turns an ordinary scalar loop into packed arithmetic. That is
the concrete, verified way to exceed Common Lisp, and it is the reason to own the back end
rather than borrow one.

The mechanism is not exotic. Once the interval domain proves the trip count and the
absence of bounds violations, and alias analysis proves the arrays are distinct, emitting
`vfmadd231pd` on `zmm` registers for an f64 loop is mechanical code generation. The
analysis is what makes it legal; the emission is bookkeeping.

## Scope discipline

What we deliberately do not implement in the first version, with reasons. Each of these
is a real R7RS feature and each one is expensive.

**Full `call/cc` is a goal, not an exclusion.** Owning the back end means owning the
stack, so the earlier compromise is gone. Ordering is still escape-only first because it is
simpler and unblocks the benchmarks, but the design must not foreclose the general case.
Chez's stack-segment approach is the reference, and `RESEARCH.md` section 4 already showed
it makes ordinary calls cheap: Chez beats Racket by about 2.5x on `ctak` and `fibc`. That is
an existence proof that full continuations need not tax the common path.

**Numeric tower: fixnum and flonum only.** No bignum, ratnum, or complex initially. The
benchmarks need neither, and the tower is where a naive implementation loses all its
performance anyway.

**`syntax-rules` only, not full `syntax-case`.** Enough for the declaration forms and the
benchmark programs.

**Garbage collection: a simple precise generational copying collector.** Not Boehm.
`../../RESEARCH.md` section 3 showed Boehm is exactly where Stalin loses 5x to 16x on
allocation-heavy code, so adopting it would import a known bottleneck. Region inference
(Tofte-Talpin, MLKit) is a later option.

This subset compiles nbody, fannkuchredux, and spectralnorm. That is sufficient to
answer the question.

## How we would exceed SBCL, concretely

Not aspiration. Four specific capabilities SBCL lacks or does manually.

| capability | SBCL | us |
|---|---|---|
| auto-vectorization | can encode AVX-512, has no vectorizer pass | **our own vectorizer, driven by our own interval domain** |
| abstract domain | roughly Pentagon (intervals plus `< > <= >=`) | Pentagon, then Octagon where it pays |
| stack allocation | manual `dynamic-extent` declaration | automatic escape analysis, as .NET 9/10 now does |
| inference model | declaration-anchored, local | declaration-anchored local **plus** opportunistic global |

That last row is the novel one. SBCL does local inference from declarations. Stalin does
global inference from nothing. Nobody does declarations as anchors with opportunistic
global analysis layered on top, which is the architecture argued for in
`../../PROPOSAL.md` section 4d. It should get Stalin's wins where the analysis succeeds
while keeping Stalin's failures from being silent, because the declared paths have a
guaranteed floor.

## Architecture

Host language: Chez. A poor experiment and an excellent host.

Framework: nanopass (Keep and Dybvig, ICFP 2013), `nanopass-framework-scheme`, last
commit 2025-12-29.

Pipeline, with the contribution concentrated in stages 4 through 7:

1. Reader and `syntax-rules` expander.
2. Core language in nanopass. Small: lambda, application, `if`, `let`, `letrec`,
   primitives, literals.
3. Declaration forms lowered to premises in the compilation environment, carrying both
   type facts and per-check policy. Policy is lexical here, which is wall 3 removed.
4. **Interval domain analysis.** Level 2. Handles constant-length arrays, which covers
   nbody.
5. **Pentagon extension.** Level 3. Strict inequalities between variables, handling
   dynamic lengths.
6. **Loop recognition and induction variable analysis.** Wall 2 removed. Required before
   any check can be hoisted rather than proven locally.
7. **Representation selection.** Storage classes, following SBCL's IR2: which values live
   in general registers, which in `xmm`/`zmm`, which are unboxed f64, which stay tagged.
8. **Alias analysis.** Enough to prove two flvectors are distinct, which is what makes
   vectorization legal.
9. **Vectorization.** Given a proven trip count, no bounds violations, and non-aliasing
   arrays, rewrite the scalar f64 loop into packed operations with a scalar remainder
   loop. This is the pass no Lisp compiler has.
10. **Instruction selection, register allocation, assembly.** Native x86-64 with AVX-512.
    SBCL's `avx512-insts.lisp` is the reference for encodings; Chez's `x86_64.ss` is the
    reference for register allocation structure.

## Milestones

1. Compiles and correctly runs nbody, scalar native code, no optimization. Establishes the
   whole pipeline through the assembler.
2. The interval domain removes nbody's bounds checks. Verify in the disassembly, not by
   timing. Theory says intervals suffice here because nbody's arrays are length 5 and the
   length is a compile-time constant.
3. Beats configuration 5, tuned scalar SBCL, on nbody. This is the answer to the original
   question and it is reachable with scalar code alone.
4. **Emits packed AVX-512 for nbody's inner loop.** The pass no Lisp compiler has. Verify
   in the disassembly that `vfmadd231pd` or equivalent appears on `zmm` registers.
5. Beats configuration 6 at `-O3 -march=native`, which is gcc with its vectorizer on. This
   is the real target, and it is honest now because we vectorized it ourselves.
6. Pentagon and loop analysis carry fannkuchredux, which is integer, bounds-dominated, and
   has a dynamic array length, so it needs both where nbody needed neither.

## Risks

**Scope explosion into a general-purpose Scheme.** The mitigation is the scope discipline
section, held firmly. This compiler exists to answer a question, and features that do not
serve nbody, fannkuchredux or spectralnorm are out until it does.

**The back end gates everything, so it comes first.** Nothing downstream can be measured
until the compiler emits correct native code, so instruction selection, register allocation
and the assembler precede every analysis pass. That is a dependency, not a cost.

**A weak register allocator hides every gain from the analysis passes.** If values spill
across the inner loop, no amount of interval reasoning shows up in the timing. Linear scan
is the documented baseline and graph coloring is the better answer; the decision should be
made by measuring spill counts in the emitted loop, not assumed either way.

**An unsound analysis produces wrong code silently.** This is the most dangerous failure
mode in the project, worse than being slow. Every removed bounds check is a memory safety
decision. The mitigation is differential testing: compile every program twice, once with all
analysis disabled, and diff the outputs. Any divergence is a soundness bug.

**Vectorization has correctness traps beyond legality.** Reassociating floating point
changes results, and nbody's output is checked to nine decimal places against a fixture. A
reduction cannot be vectorized without either accepting a different answer or using an
ordered reduction. Decide this explicitly per loop rather than discovering it as a failing
diff.

## Relationship to the other phases

Phases 1 through 4 stay and stay cheap. They establish the baseline we have to beat, and
`RESEARCH.md` plus `CHEZ-ANALYSIS.md` already told us what to build. Phase 3's
configuration 5 is milestone 4's target and configuration 6 is milestone 5's.

Phase 5, the portable library, is now demoted to optional. It was designed as an
instrument to discover compiler requirements, and reading the Chez and SBCL source
supplied those requirements directly and more precisely than a measurement would have.
Build it only if an SRFI is still wanted.

This phase can begin as soon as phase 1 is done, and does not wait on phases 2 through 5.
