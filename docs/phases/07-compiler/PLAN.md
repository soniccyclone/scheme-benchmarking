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

The tractability objection also does not hold. SICP chapter 5 is a compiler, the nanopass
framework exists and is maintained, and Chez itself is written in nanopass style by the
people who invented it. This is a known-shape project, not a research gamble.

## The strategy: emit C and inherit gcc's back end

The single most important design decision, and it is what makes "exceed CL" concrete
rather than aspirational.

Verified on this machine, gcc 15.2.0:

```
void axpy(double * restrict a, const double * restrict b, double s, long n){
  for (long i=0;i<n;i++) a[i] += s*b[i];
}
```

```
optimized: loop vectorized using 64 byte vectors
```

gcc auto-vectorizes to AVX-512 given a loop with no bounds checks and `restrict` on the
pointers. **SBCL cannot auto-vectorize at all.** `sb-simd` is manual intrinsics, which is
why Bela Pecsek's fast entries are hand transliterations of Zig.

So the path to exceeding CL is not to out-engineer SBCL's register allocator. It is:

1. Do the analysis SBCL does, reaching level 2 and then level 3 in the domain hierarchy,
   so the bounds checks are gone.
2. Prove non-aliasing so `restrict` can be emitted.
3. Emit clean C and let gcc's vectorizer do what no Lisp compiler does.

This is Stalin's strategy and it is why Stalin beat hand-written C on some benchmarks.
The difference is that Stalin got there by whole-program inference with a closed world,
and we get there by declaration-anchored local inference, which keeps separate
compilation.

Also verified: `[[gnu::musttail]]` compiles and works on gcc 15.2, so proper tail calls
through C are viable without trampolining.

## Scope discipline

What we deliberately do not implement in the first version, with reasons. Each of these
is a real R7RS feature and each one is expensive.

**Full `call/cc`: escape-only at first.** Multi-shot first-class continuations are what
make a C back end hard, because C owns the stack. Escaping continuations cover
`dynamic-wind`-free non-local exit and are exactly what Common Lisp has, so this keeps
the comparison fair while removing the hardest constraint. Full `call/cc` is a later
milestone, and Chez's stack-segment approach is the reference design when we get there.

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
| auto-vectorization | none, `sb-simd` is manual intrinsics | free, via gcc, given bounds-free loops and `restrict` |
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
7. **Representation selection.** Unboxed f64 and raw fixnum, emitted as native C types.
8. Alias analysis sufficient to emit `restrict`.
9. C emission, then `gcc -O3 -march=native`.

## Milestones

1. Compiles and correctly runs nbody with no optimization. Establishes the pipeline.
2. Stage 4 (intervals) removes nbody's bounds checks. Theory says this suffices because
   nbody's arrays are length 5, statically known.
3. Emits `restrict` and gcc vectorizes the inner loop. This is where we pass SBCL.
4. Beats configuration 5 (tuned scalar SBCL) on nbody.
5. Beats configuration 6 scalar C on nbody. Stalin did this; so should we.
6. Stages 5 and 6 on fannkuchredux, which is integer and bounds-dominated with a dynamic
   array length, so it needs Pentagon and loop analysis where nbody did not.

Milestone 4 is the real answer to the original question. Milestone 5 is the interesting
one.

## Risks

**Scope explosion into a general-purpose Scheme.** The mitigation is the scope discipline
section, held firmly. This compiler exists to answer a question, and features that do not
serve nbody, fannkuchredux or spectralnorm are out until it does.

**The C back end constrains us later.** Escape-only continuations are a real limitation
and full `call/cc` may eventually force a native back end. Accept the constraint now,
because it buys gcc's vectorizer, which is the whole strategy.

**gcc refuses to vectorize what we emit.** The verified `axpy` case is the easy shape.
Real emitted code may defeat the vectorizer through aliasing it cannot see through, or
control flow. `-fopt-info-vec-missed` reports why, and this becomes an iteration loop
rather than a wall.

**We beat SBCL only because gcc is doing the work.** A fair objection and it should be
stated in any writeup rather than hidden. The counter is that inheriting a good back end
is a legitimate engineering choice, that Bigloo, Chicken, Gambit and Stalin all make it,
and that the analysis making the C vectorizable is the actual contribution.

## Relationship to the other phases

Phases 1 through 4 stay and stay cheap. They establish the baseline we have to beat, and
`RESEARCH.md` plus `CHEZ-ANALYSIS.md` already told us what to build. Phase 3's
configuration 5 is milestone 4's target and configuration 6 is milestone 5's.

Phase 5, the portable library, is now demoted to optional. It was designed as an
instrument to discover compiler requirements, and reading the Chez and SBCL source
supplied those requirements directly and more precisely than a measurement would have.
Build it only if an SRFI is still wanted.

This phase can begin as soon as phase 1 is done, and does not wait on phases 2 through 5.
