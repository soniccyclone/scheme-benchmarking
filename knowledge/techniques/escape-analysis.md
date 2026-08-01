---
type: technique
title: Escape analysis
description: Proving a value does not outlive the activation that created it, which is what licenses stack allocation, closure elimination, and keeping an unboxed flonum in a register; three Blanchet papers now supply the data half, and they set the cost at O(n log² n) with type information and a proof obligation without it.
tags: [escape-analysis, stack-allocation, closure-conversion, dynamic-extent, abstract-interpretation]
sources:
  - resource: /works/blanchet-escape-analysis-ml-popl-1998.md
  - resource: /works/blanchet-escape-analysis-oopsla-1999.md
  - resource: /works/blanchet-escape-analysis-java-toplas-2003.md
  - resource: /works/keep-hearn-dybvig-optimizing-closures-in-o-0-time.md
  - resource: /works/keep-a-nanopass-framework-for-commercial-compiler-developm.md
  - resource: /works/serrano-cfa-closure-allocation-sac-1995.md
  - resource: /works/steensgaard-points-to-analysis-in-almost-linear-time-popl-.md
  - resource: /works/dybvig-three-implementation-models-for-scheme-1987.md
  - resource: /works/hieb-dybvig-bruggeman-representing-control-in-the-presence.md
  - resource: /works/steele-rabbit-a-compiler-for-scheme-1978.md
  - resource: /works/shivers-control-flow-analysis-of-higher-order-languages-19.md
  - resource: /works/burger-waddell-dybvig-register-allocation-pldi-1995.md
implemented_by: [/implementations/chez.md]
absent_from: [/implementations/sbcl.md]
pipeline_stage: 09-alias
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-08-01T00:00:00Z" }
---

# Problem

Which values can live in a frame that gets popped rather than in a heap that must be collected.
For us, more usefully: which flonum can stay unboxed in an `xmm` register for its whole lifetime,
and which closure needs no heap object at all. The predicate is "v does not outlive the activation
that created it."

Common Lisp makes the programmer answer with `dynamic-extent`, unchecked. Automating it is one of
four capabilities where `docs/phases/07-compiler/PLAN.md` claims we exceed SBCL. This document was
`status: draft` because its data half was extrapolated from Steensgaard's storage shape graph,
which is not what that paper is about. Three Blanchet papers now cover it directly, including a
correctness proof and measurements on a 65,000-line program, so the claim is on evidence.

# Mechanism

Four analyses at three granularities. The first is nearly free and covers closures; the second is
the sourced answer for data; the last two are supporting.

**1. Syntactic well-knownness, for closures.** A procedure is *known* at a call site if that site
provably invokes exactly that lambda, and *well-known* if its value is never used anywhere except
where it is known. A well-known procedure's code pointer is dead: every call jumps to a label.

One linear pass. Give each `letrec` lambda a fresh label, optimistically mark it well-known, demote
on any reference outside call-operator position. No call graph, no fixpoint. Requires assignment
conversion and letrec purification first. Measured over 67 R6RS benchmarks: 56.94% of closures and
44.89% of free variables eliminated statically, 58.25% of closure allocation eliminated dynamically.

**2. Blanchet's analysis, for data.** A backward abstract interpretation over the program's AST or
SSA form, in four levels, each derived from the previous by abstract interpretation with a stated
Galois connection.

*Level 1, access paths (analysis E).* Escape contexts are sets of access paths. In the ML paper,
`Path = l:Path | r:Path | app:Path | ⊤ | ⊥`, where `l` is head-of-list / left-of-pair /
contents-of-ref, `r` is tail / right, and `app` means the value is a function that gets applied.
Contexts must be **non-empty**: under call-by-value an expression is evaluated even when its result
is unused, and that evaluation can cause escape through assignment. Abstract values are *context
transformers*, `Ctx → (Var ∪ Ind) → Ctx`: given the escape context of the result, they yield the
escape context of each free variable and each parameter index. Parameterizing on the calling
context is what makes the analysis context sensitive without reanalyzing a procedure per call site.
E is stated to apply to any functional language, "even untyped," and is explicitly too complex to
implement directly.

*The two-direction fix for mutation.* The ML paper treats a value as escaping the moment it is
stored into another value. That is useless the moment assignment is common. The Java papers replace
it with **bidirectional propagation**: a backward `E` and a forward `ES` ("store-escape"), mutually
dependent. `E` alone cannot see that `o` escapes because it was stored into a parameter, since at
the assignment point a backward analyzer does not yet know the target is a parameter. For `x.f = y`
this yields *two* equations, and the second looks wrong until you see the counterexample:

```
E(y) ⊒ f⁻¹.ES(x)     when x.f escapes, y escapes        (obvious)
E(x) ⊒ f.ES(y)       when y escapes, x.f escapes        (necessary)

C.static_field = y;  x.f = y;  x.f.f' = z;
```

Without the second, `x` has empty escaping parts and `z` is wrongly reported non-escaping — the code
is equivalent to `y.f' = z` and `y` escapes.

*The soundness condition.* δ-transitivity: `f` is δ-transitive if for `y` in the lexical scope of
`x`, `f c x ⊔ [[y]] ⊥ x ⊑ [[y]] (f c y) x` — escape through an intermediate binding is accounted
for. Blanchet's counterexample is `let rec f(x) = ... z := f ... in f(3)`, where the naive
criterion is correct against the correctness predicate yet still concludes wrongly.

*Level 2, integers.* Escaping parts become the *height of the type of the escaping part*.
`⊤₂[bool] = 1`, `⊤₂[τ₁→τ₂] = ⊤₂[τ₂]`, `⊤₂[τ₁×τ₂] = 1 + max`, `⊤₂[τ list] = 1 + ⊤₂[τ]`,
`⊤₂[τ ref] = 1 + ⊤₂[τ]`. Recursive types: all types in one strongly connected component of the
containment graph share a height; +1 between components; O(size of type declarations). An object of
type τ is stack-allocatable when its escape context is strictly below `⊤[τ]`. Higher-order needs
*two* integer analyses, not one, and the reason is specific: a variable captured in a closure may
have a higher level than the closure itself, so the escape function would not be *inferior* and
Knuth's solver would not apply. F1 tracks escape through closures as a boolean, F2 gives levels for
everything else.

*Level 3, one-step representation.* Additivity splits each transformer into `⊔ᵢ gᵢ(cᵢ) ⊔ u`, and each
`gᵢ` is stored as a triple `(s, s⁺, l)` meaning `γ ↦ (if γ ≥ s then s⁺ else 0) ⊔ (γ ⊓ l)`, held
sparsely so only the parameters a context actually depends on are present.

*Solving.* Equations form a tree with edges labeled `λc.(c ⊓ f) ⊔ i`, composed as
`(f₁,i₁) ∘ (f₂,i₂) = (f₁ ⊓ f₂, (i₂ ⊓ f₁) ⊔ i₁)` with Tarjan path compression, solved by Knuth's
generalization of Dijkstra's algorithm after splitting into strongly connected components.

*The transformation, which is half the value.* `letstack x = M in N` stack-allocates the outer
constructor of `x` and frees it at the end of `N`; `letstack'` frees it *before* the tail call of
`N`, so tail call optimization survives. Choose the enclosing context as small as possible to
minimize lifetime, via a second path-compressed tree walk. In a loop, do not allocate fresh each
iteration; the reuse criterion is *assume every variable live just before the allocation escapes,
and if the allocated object still does not escape, the slot can be reused*. Inline small allocating
procedures, but only when doing so actually creates an opportunity.

**3. Serrano's three-valued classification, for procedures.** 0CFA gives the callable set; invert to
get the use sites. Then `S ⇒ X ⇒ T`, each with a cheaper representation. Proposition 2 is the
practical one: **any procedure never passed as an argument and never returned satisfies S** — no
closure, no environment, every call a direct branch, free variables lambda-lifted.

**4. The "inevitably" framework.** Burger, Waddell and Dybvig's `St`/`Sf` split answers "does this
expression inevitably do X" in one bottom-up linear pass: union along a path, intersection across
paths, and the whole register set `R` for impossible paths so they impose no constraint. **Carry the
correction:** the callee-save criterion `ret ∈ St[E] ∩ Sf[E]` is wrong as printed in the ACM
proceedings; our copy has the fix in footnote 2 on page 5.

# Preconditions

**Assignment conversion and letrec purification**, or well-knownness is unsound.

**Type information, for the fast version.** This is the constraint the bundle did not have written
down, and two of the three sources reach it independently. Analysis E is type-free and applies to
untyped languages; analysis L is *defined* by type heights. Without types there are no levels and
the O(n log² n) representation does not exist. **Escape analysis at our cost target is downstream of
type recovery.**

**SSA form, for the good complexity bound.** The TOPLAS version's improvement over OOPSLA is
entirely from analyzing SSA instead of an abstract state per program point: `(l+s)` factors vanish,
equations and unknowns drop from `O(n(l+s))` to `O(n)`. The resulting flow sensitivity is exactly
"as flow sensitive as SSA" — flow sensitive on local variables, flow *insensitive* on assignments to
object fields.

**Whole-program or module-closed** for anything CFA-based, and for the Java version, a resolved call
graph before analysis. Separate compilation is supported but costs precision directly.

**Continuation capture is the hard one and none of the three sources touch it.** Blanchet's
semantics has no control operator. Dybvig §4.5: a box may be skipped when an assigned variable
occurs free in no closure *and* no continuation can be captured in its scope; the first is
syntactic, the second needs significant analysis. RABBIT's negative result stands unretracted
(Steele p. 92): substituting a side-effecting expression past an unknown call that performs a
`CATCH` whose escape procedure is invoked twice makes the effect happen twice, there is no way to
decide it short of fearing every unknown call, and fearing them defeats most optimization.

**The control representation decides what stack allocation means.** Under Hieb, Dybvig and
Bruggeman's segmented stack, capture *seals* the current segment rather than copying it, so
dynamic-extent objects may be stack-allocated *and mutated*. Not sound under the naive copy model.
Escape analysis is worth strictly more under segmented continuations.

# Cost

Well-knownness: one linear pass, compile time change under 1%. Effectively free.

Blanchet on ML: **O(n log² n)**, measured near-linear in practice because each recursive declaration
is analyzed independently. Analysis alone 16-19% of compile time; total compile 19-21% longer
because the transformed code also takes longer to compile.

Blanchet on Java: worst case `O(n²pp'²H)` on SSA form (`O(n²(l+s)²pp'²H)` without SSA), but
iterations to fixpoint were at most 17 with an average of 3.9 per equation, and the analysis was
about 10% of compile time with 29% total compile overhead. Splitting the dependence graph into
strongly connected components before iterating took `jess` from 156 s to 129 s.

0CFA: worst case cubic; on `conform`, 60.5 s against 6.4 s, an 845% increase in Scheme-side compile
time. Steensgaard: about 4× the cost of traversing the program representation.

**What it buys, honestly.** Coq, 65,000 lines, 5.25 gigawords allocated: 17% stack-allocated
preserving recursive tail calls, 25% without — for a **3.0-4.3% speedup**. Small benchmarks do much
better (`taku` 74% of memory, 25% speedup) but Coq is the honest number at scale. Without inlining,
Coq could not exceed 11%. On Java, 13-95% of data stack-allocated for a 21% geometric-mean speedup,
but roughly half of that comes from synchronization elimination, which we have no analogue for.

**Two negative results to budget for.** Stack overflow is a real failure mode: without the loop-reuse
criterion the stack grows by a factor of 10 on `javacc` and 129% on `JLex`. And stack allocation can
*hurt* locality — in `javacc`, stack-allocated arrays became unreachable at the next iteration
without the analysis seeing it, leaving gaps in the stack unreused until return, where heap
allocation would have let the collector reclaim them.

**The calibration number for the closure half.** Keep's full closure optimization — six free-variable
eliminations plus representation selection plus sharing plus borrowing — moves benchmark run time by
an average of **3.6%**, range negligible to 20%, with a few benchmarks getting *slower* from cache
effects. Eliminating 58% of closure allocation buys 3.6% wall clock, because Chez's inline
allocation is already about three instructions plus a store per field.

# Disagreements

**Where the speedup comes from, and Blanchet contradicts himself across two papers.** POPL 1998:
almost none of it is GC; the speedup is data locality, because stack allocation catches short-lived
data and short-lived data is exactly what a generational minor collection never scans. OOPSLA 1999:
roughly half is GC, a quarter locality, a quarter allocation time. He names the cause — the JDK used
mark-and-sweep, CSL used a generational collector. **This is not a disagreement about escape
analysis, it is a disagreement about collectors, and it resolves for us in favour of the ML answer**,
because our plan specifies a precise generational copying collector. Expect locality and unboxing
wins; do not justify the pass by GC pressure.

**Integers versus graphs.** Blanchet abstracts escaping parts to a single integer per value. Choi et
al. (connection graphs) and Whaley and Rinard (points-to escape graphs) are, in Blanchet's own
words, "more precise than our analysis because they distinguish different fields of objects and are
flow sensitive." His counter is cost, plus one structural argument that is decisive:
**Choi et al. consider a `new` stack-allocatable only when it is so in all calling contexts, so
inlining cannot be used to increase stack allocation opportunities.** Blanchet's own data says
inlining is what takes Coq from 11% to 25%. Note the integer abstraction's own weak spot, stated by
Blanchet: integers cannot distinguish different fields of the same object, so precision degrades the
deeper into a data structure you go — which he argues does not matter, because the top of a
structure is what you can usually stack-allocate anyway.

**Is flow analysis worth it for escape?** Serrano says yes and rejects 1CFA outright ("what can be
done with this information in a compiler? We have found no answers"). Keep, Hearn and Dybvig get
their entire closure result from a linear syntactic pass with no CFA at all, in the same numeric
range. Serrano's dismissal of 1CFA has aged badly for our case: polyvariant CFA is how you get type
specialization, which is what unboxing wants.

**Escape at what granularity?** Prior closure analyses (Kranz's ORBIT, Séniak's SQIL) partition
procedures into allocates and does-not-allocate. Serrano argues that partition is exactly the
weakest of his three predicates. The subsumption claim is stated, not proved.

**What no source in the bundle covers.** First-class continuations. Blanchet has no control operator
in any of the three semantics; Dybvig identifies the problem and does not solve it; RABBIT
identifies it and declines. Any claim we make about automated escape analysis in the presence of
`call/cc` is ours to establish, not something we inherit.

**Manual versus automatic.** No source argues for the manual `dynamic-extent` form. All three
Blanchet papers demonstrate the automatic form working at scale on real programs, which closes the
gap this document previously admitted.

# For us

Stage `09-alias` produces the fact; stage `08-represent` consumes it. The CUJ numbers 08 before 09
and the CUJ already carries the correction: storage class assignment keys on "proven flonum, does
not escape," which is what 09 proves. Blanchet does not suggest a different placement — his analysis
is a whole-procedure abstract interpretation that runs once and answers per allocation site, which
is exactly stage 09's shape.

He does suggest two things about *ordering* that we did not have.

**Escape analysis is an input to the inlining decision, not a consumer of it.** In both papers,
inlining exists to create stack-allocation opportunities and is performed only when it does so.
Coq goes 11% → 25% because of it; char arrays are 4% of javac's data, 20% of turboJ's, 29% of
javacc's, entirely from inlining `StringBuffer.ensureCapacity` and `toString`. Our `04b-inline.ss`
sits far upstream of stage 09, so either 09 has to run a cheap pre-pass to inform inlining, or we
accept the un-inlined ceiling. Blanchet's `(j+1)`-cell summary — three constant-size cells per
procedure with an exact fallback that fired 21 times in 2 Mb of classes — is how he gets it without
quadratic blowup, and it is in the OOPSLA paper, not the TOPLAS one.

**Granularity is per-allocation-site with a lifetime, not a boolean per variable.** The predicate
"does not escape" is only half the transformation. The other half is placing the deallocation as
early as possible, which changes `taku`'s stack from 75% larger to 25% larger. And in a Scheme where
every loop is a tail call, `letstack'` versus `letstack` is our default case, not an edge case:
putting a `letstack` in tail position in a recursive loop grows the stack every iteration.

Build order, cheapest first:

1. **Well-knownness.** Linear, free, and it decides whether a closure exists at all. Keep's
   breakdown: self-reference elimination alone is 25.41% of free variables and 45.64% of eliminated
   memory references, mutual-reference elimination another 7.91%/32.55%. Sharing and borrowing
   together are 2.11% and can be skipped.
2. **Serrano's `S` predicate** — never passed as an argument, never returned. Covers most procedures
   in most programs and needs no fixpoint.
3. **Blanchet's analysis E on paths, restricted to flvectors and flonums.** Type-free, so it does not
   wait on type recovery. Backward pass over SSA, contexts as sets of paths, with the bidirectional
   `E`/`ES` pair — because `(vector-set! v 0 x)` is `x.f = y`, and the POPL 1998 store-escapes rule
   would kill exactly the flvector case stage 08 exists to serve.
4. **The integer abstraction, once type recovery lands.** This is what buys O(n log² n). Not before.

Do not reach for k-CFA. Do not build connection graphs first; the ground Blanchet covers is enough
to start, and Choi et al. is a second opinion rather than a prerequisite.

Hold the honest position on the SBCL comparison. Automating `dynamic-extent` is a real capability
gap and it is now demonstrated closeable — Blanchet did it in a production ML compiler and a
production Java compiler, with a proof. The size of the prize is the open question: **3-4% on a
large real program**, per Coq, which is the same order as Keep's 3.6% for the closure half. That is
worth having and it is not a transformative number. The part that could actually matter on `nbody`
is unboxed flonums staying in `xmm` registers, and no source in this bundle measures that.
