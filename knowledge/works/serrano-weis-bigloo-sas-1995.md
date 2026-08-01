---
type: paper
title: "Bigloo: a portable and optimizing compiler for strict functional languages"
description: The Bigloo system overview: one n-ary lambda-calculus core compiled to handwritten-looking C, shared by Scheme and ML front ends, with four source-to-source transformations (eta, uncurry, if-to-case, inlining) whose common purpose is eliminating heap allocation for control.
resource: knowledge/sources/serrano-weis-bigloo-sas-1995.pdf
tags: [scheme, ml, compiler-architecture, closure-conversion, inlining, c-backend, uncurrying]
authors: [Manuel Serrano, Pierre Weis]
year: 1995
venue: "Static Analysis Symposium (SAS 1995), LNCS"
informs: [/techniques/closure-conversion.md, /techniques/procedure-inlining.md, /techniques/control-flow-analysis.md, /techniques/tail-call-optimization.md]
pipeline_stage: 08-represent
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-08-01T00:00:00Z" }
---

# Contribution

The system paper for Bigloo, and it is the design-rationale companion to Serrano's SAC'95
closure-analysis paper rather than a duplicate of it. Three claims.

First, one compiler core can serve full Scheme and full Caml well, if the core language is
chosen correctly. The choice is `λ_n`, untyped n-ary lambda calculus, and the mechanism for
adapting it is a preprocessor per source language plus a replaceable primitive library. The
core assumes nothing — not even that the source is type-checked, statically or dynamically;
if runtime type tests are needed, the front end must make them explicit before Bigloo sees
the program.

Second, an optimizing compiler that targets C must generate C that *looks handwritten*, not
C that emulates an abstract machine. This is stated as a claim and defended.

Third, and this is the thesis the paper actually argues: every optimization worth doing in a
strict functional language compiler is the same optimization, namely the reduction of heap
allocation, and mostly heap allocation for *control* rather than for data.

# Mechanism

**The core language.** `λ_n` is the n-ary lambda calculus with an arity consistency check.
`λ¹x.λ¹y.x` and `λ²xy.x` are distinct terms and not interconvertible: the first must be
applied one argument at a time via `@¹`, the second must be applied to two at once via `@²`.
Extended with `let` (recursive, and the bound variables are assignable, which is how
imperative source features land), `if`, an integer `case`, and constants. Call-by-value,
semantics by weak β-reduction with parallel substitution.

That arity distinction is the paper's central representational decision. Because arity is in
the term rather than inferred, the compiler can see when a function is really n-ary and emit
an n-ary C function with no intermediate closure.

**Why natural C.** The alternative — C as portable assembler, no C functions, C variables as
abstract-machine registers, the C stack unused — makes `call/cc` and precise GC easy, since
the compiler controls the whole runtime picture. Serrano and Weis reject it on the ground
that C compilers will not optimize code that no C programmer would write, so you forfeit the
entire back end you chose C to get. Natural projection costs them exactly that: `call/cc`
becomes hard (it is a C library function, not a core construct), and GC must tolerate
ambiguous roots because live values sit in the C stack, hence Boehm's conservative collector.
Source functions become C functions, or C `goto` loops when tail-recursive; source variables
become C variables.

**Closure analysis** is deferred to the companion paper (reference [13], Serrano's SAC'95
piece, which is the other Bigloo-slugged PDF in this bundle). What this paper adds is the
result shape, by example: non-escaping and always-tail-called mutual recursion compiles to
labels and `goto` in one C function body; non-escaping n-ary functions compile to n-ary C
functions; only genuinely escaping functions get heap closures. Closures are **flat** — the
environment block holds exactly the free variables — and linked environments are rejected
explicitly, not on speed grounds but because they leak memory in a way the user cannot work
around. Each closure carries free variables, code pointers, and an **arity slot**. The arity
slot is obviously needed for dynamically typed languages; the interesting observation is that
it pays off in statically typed ones too, because it lets a computed call check at runtime
whether the application is total and, if so, jump to the uncurried entry point, avoiding a
closure allocation.

**The C-transformation (uncurrying).** For a curried `f = λ¹x₁ … λ¹xₙ.M`, generate two
definitions: `f₂ = λⁿx₁…xₙ.M` for total applications and `f₁ = λ¹x₁…λ¹xₙ.@ⁿ(f₂, x₁, …)` for
partial ones. Spines of unary applications collapse to a single n-ary application. `f₁` and
`f₂` are related by naming convention, so the transformation works across module boundaries,
and they are dynamically linked so n-ary computed calls benefit too. Measured on the Caml
compiler bootstrap (12,000 lines): a factor of two.

**The eta-transformation.** Wraps a definition in extra abstractions so that a function whose
arity is hidden by a partial application becomes visibly n-ary, at which point C applies.
Their example is `let do_list f = let rec loop = … in loop` becoming
`let do_list f new = let rec loop = … in loop new`. They are careful to distinguish this from
the η-rule of λ-calculus, which is invalid under side effects; the transformation is only
applied to syntactic functions, where η is always valid. Impact where it applies is large:
the `kb` benchmark and the Coq proof assistant (20,000 lines of Caml, a 30-minute run
allocating 12 GB) both run twice as fast.

**The I-transformation.** Cascaded `if n_c = i₀ then … else if n_c = i₁ …` becomes a `case`.
Preconditions: every test compares the *same* expression to an integer literal, and that
expression is side-effect free, since after rewriting it is evaluated once. The point is
organizational — ML and extended-Scheme pattern-match compilers no longer need to do this
themselves.

**Inlining.** Two admission rules: the function is called exactly once in the whole program
(no growth), or its `λ_n` AST is smaller than a threshold `S` that varies with parameter
count and optimization level. Two exclusions: no inlining of `f` inside the body of `f`
(which is what makes mutual recursion terminate), and a hard cap on nesting depth, because a
chain of individually-small functions defeats the size rule. Non-recursive inlining is the
obvious `L_let` substitution. Recursive inlining is the part they call original: rather than
unrolling to some depth, create a *local recursive definition* `f'` at the call site with
`f` renamed to `f'` in its body, and call that. Their worked example is worth reading in
full, because the win comes from the *next* pass: `map succ l` inlines `map` locally, then a
loop-invariant argument pass notices `f` never changes and substitutes `succ` for it, then
`succ` inlines, and the result is a specialized monomorphic loop with no closure and no
indirect call. Measured 20% (Sparc) to 30% (Mips) speedup for 5% code growth on a corpus
including Bigloo's own 30,000-line bootstrap.

**Front ends.** Scheme's is thin — mostly making dynamic type tests explicit, after which the
core's dataflow optimizer removes most of them; `call/cc` is an ordinary primitive
implemented in C. Caml's does type reconstruction, pattern-match expansion, and one real
optimization: ML `ref` cells become `λ_n` assignable variables (hence C variables) whenever
the reference is not used as a first-class value. The `sort` benchmark runs 50% faster from
that alone. `try`/`raise` are library functions.

# Applicability

The whole design presumes C as target, which buys portability across every Unix of the era
and costs precise GC, cheap first-class continuations, and control over calling conventions.
Bigloo's answers are: conservative Boehm collection, `call/cc` in C, and lean on the C
compiler. If any of those three is unacceptable, the natural-projection argument does not
transfer.

The uncurrying and eta transformations pay only where the source language encodes n-ary
functions as curried unary ones. Their own benchmark table makes the trade visible: `takc`
(curried) versus `taku` (tuple) shows Bigloo, Camlc and Camlot fast on the curried encoding
and slow on the tupled one, while SML/NJ and sml2c are the reverse. The paper concedes in
section 8 that "the optimization of n-ary uncurried functions is badly missing."

Inlining's admission rules are heuristic and unproven, and the depth cap is an admitted
patch rather than a criterion.

# Relevance

The natural-projection argument is a decision we have to make consciously, and this is the
best available statement of the *cost* side. We are not targeting C, so the argument does not
bind us; what does transfer is the observation that a compiler generating code for a
downstream optimizer must generate code the downstream optimizer recognizes. Substitute
"machine code the hardware's branch predictor and register renamer recognize" and the same
reasoning applies to our back end.

The `λ_n` arity decision is directly relevant to our IR. Making arity a property of the term
rather than something recovered by analysis is what lets uncurrying be a source-to-source
rewrite instead of an interprocedural analysis, and it is why Bigloo can uncurry across
module boundaries with nothing but a naming convention. Our IR should carry arity the same
way.

The recursive-inlining scheme is the most portable single idea here and we should copy it.
Local recursive redefinition rather than depth-limited unrolling gets the specialization
benefit (the loop-invariant argument becomes a constant, which then inlines) without the code
growth of unrolling, and it composes with a subsequent constant-propagation pass rather than
duplicating it. Compare Waddell and Dybvig's inliner in this bundle, which attacks the same
problem with online demand-driven decisions; the two are complementary, not competing.

The flat-versus-linked closure decision is settled here on grounds we should adopt verbatim.
Linked environments leak, and the leak is not something a user can route around. Take the
allocation cost.

# Notes

**These are two different papers, confirmed from the artifacts.** This bundle contains both
`serrano-weis-bigloo-sas-1995.pdf` and `serrano-cfa-closure-allocation-sac-1995.pdf`,
and the second is *not* what its slug says. Verified:

- This file: 17 pages, LNCS format, "This article was processed using the LATEX macro
  package with LLNCS style" on the last page. Title "Bigloo: a portable and optimizing
  compiler for strict functional languages." **Two authors**, Manuel Serrano (INRIA
  Rocquencourt and Université de Montréal) and Pierre Weis (INRIA Rocquencourt). Eight
  sections, nineteen references, two benchmark tables.
- The other file: 5 pages, ACM two-column, printed pp. 118-122. Title "Control Flow Analysis:
  a Functional Languages Compilation Paradigm." **Serrano alone.** Weis is neither an author
  nor mentioned.

The decisive evidence is internal: **this paper cites that one**, as reference [13],
"M. Serrano. Control Flow Analysis: a Functional Languages Compilation Paradigm. In Symposium
on Applied Computing (SAC '95), Nashville, Tennessee, USA, February 1995." It cites it twice,
in section 5.1, precisely to avoid repeating the closure analysis. So the SAC'95 paper is the
closure-analysis paper and this is the system paper, and this one is downstream of it. The
existing `works/serrano-cfa-closure-allocation-sac-1995.md` reached the
same conclusion from the other side and predicted the SAS paper was still missing from the
bundle; it now is not.

**Slug recommendation, endorsed.** Rename
`serrano-cfa-closure-allocation-sac-1995` to
`serrano-cfa-closure-allocation-sac-1995` (the name that document itself proposes), and keep
`serrano-weis-bigloo-sas-1995` as is, since it is accurate. Anyone reading the current slugs
will conclude the bundle holds one paper twice, which is the opposite of the truth.

**Venue caveat.** "SAS 1995" is not printed on this artifact. The document is plainly LNCS
(LLNCS style, LNCS page geometry, the INRIA affiliations), and the content and date are
consistent with the Static Analysis Symposium held in Glasgow in September 1995, but the
proceedings header, volume number, and page range are absent from the file. Treat the venue
field as inferred from provenance, not read off the paper. The recovery path is also worth
recording: this was reconstructed from gzipped PostScript, which is why the text layer has
systematically lost `ffi`/`fi`/`fl` ligatures ("ecient" for "efficient", "rst" for "first",
"ow" for "flow") and why Greek letters in the transformation figures render inconsistently.
The prose is unambiguous; the two transformation figures (Fig. 1 C, Fig. 2 eta) are degraded
and were reconstructed from the surrounding text and the Scheme/ML examples, which are
intact.

**Where the paper oversells.** "Bigloo is the first compiler for full Scheme and full ML" and
"one of the most efficient compilers now available" are both in the abstract, and neither is
supported by anything in the paper — the Scheme benchmarks are the Gabriel suite, which the
authors themselves note "do not feature higher order functions" and are therefore close to
useless for evaluating the closure optimizations that are the paper's whole point. The ML
comparison is against compilers with different source syntax and different libraries,
requiring "non trivial rewriting," on 2500 lines of programs the authors wrote to test
specific compiler features. The transformation-level measurements (uncurrying 2x on the Caml
bootstrap, eta 2x on Coq, inlining 20-30% on Bigloo's own bootstrap) are on real programs and
are the credible numbers in the paper; the head-to-head tables are not.

**One claim worth flagging as dated and wrong.** Section 7.1 attributes Bigloo's poor
`Div2-rec` result to Sparc register windows penalizing C-targeting compilers on deep
recursion. That is a real Sparc effect, but it is an artifact of one architecture that no
longer exists, and it should not be read as evidence about C as a target language generally.
