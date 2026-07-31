---
type: paper
title: "Points-to Analysis in Almost Linear Time"
description: Casts flow-insensitive interprocedural points-to analysis as non-standard type inference solved by union-find, giving a linear-size storage shape graph in O(N α(N,N)) time.
resource: knowledge/sources/steensgaard-points-to-analysis-in-almost-linear-time-popl-.pdf
tags: [points-to-analysis, unification, type-inference, union-find, escape-analysis]
authors: [Bjarne Steensgaard]
year: 1996
venue: "POPL 1996 (see Notes on the copyright line)"
informs: [/techniques/points-to-analysis.md, /techniques/escape-analysis.md]
pipeline_stage: 09-alias
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Reformulate points-to analysis as type inference over a non-standard type system, then solve
it with union-find. The types have nothing to do with `int` or `struct` — a type *is* a node
in a storage shape graph, describing a set of locations and what those locations may contain.
Inferring the minimal well-typing of a program *is* the points-to analysis.

Cost: O(N α(N,N)) time, O(N) space. Measured at ~27 seconds on a 75,000-line C program on an
SGI Indigo2, about 4× the cost of merely traversing the program representation. Contemporary
interprocedural analyses had not been reported working above ~10,000 lines. Andersen's
context-insensitive solution is O(A²) in the number of abstract locations; Steensgaard's is
O(N).

Three stated contributions: a type system giving a universally valid storage shape graph in
linear space; a constraint system using *inequalities* rather than the obvious equalities,
which is strictly more precise; and the almost-linear solver.

The precision claim is deliberately modest — results "roughly comparable to" Weihl's cubic-time
flow-insensitive analysis, worse than flow-sensitive analyses, "equivalent to a flow-insensitive
alias analysis (and control flow analysis) that assumes alias relations are reflexive and
transitive."

# Mechanism

**Types.**

```
α ::= τ × λ                                    value type
τ ::= ⊥ | ref(α)                               location type
λ ::= ⊥ | lam(α₁…αₙ)(αₙ₊₁…αₙ₊ₘ)               function signature type
```

A value can be a pointer to a location *or* to a function, so a value type is a pair of both.
`⊥` means "not a pointer." Types may be recursive (cyclic storage shape graphs), so equality
is by *type variable identity*, not structural — two structurally identical types are distinct
types.

Two deliberate imprecisions buy the linear bound: a pointer's whole target set is one type,
and *all fields of a composite object share one type*. Per-field types would make the graph
potentially exponential in program size for languages with heavy `typedef`/`struct` nesting.

**Inequalities, not equalities.** The obvious rule for `x = y` forces `x` and `y` to have the
same content type. Too strict. Consider:

```
a = 4;  x = a;  y = a;
```

Under equality, `a`, `x`, `y` all share a content type, so if `x` later holds a pointer, the
analysis reports `y` and `a` may hold it too — from integer assignments. So define

```
t₁ ≤ t₂  ⟺  (t₁ = ⊥) ∨ (t₁ = t₂)
```

and the rule becomes: `A ⊢ x : ref(α₁), A ⊢ y : ref(α₂), α₂ ≤ α₁ ⟹ welltyped(x = y)`. Each
component of `α₂` must be `⊥` or equal to the corresponding component of `α₁`. Non-pointers
cost nothing.

**Primitive operations.** `x = op(y₁…yₙ)` requires `αᵢ ≤ α` for every operand. The reasoning
is worth noting: pointer subtraction yields a non-pointer, but either operand pointer can be
*reconstituted* from the result given the other, so the result must carry the same type.
Comparisons cannot reconstitute, so they need not — but the paper treats all primitives
identically for simplicity, and only the implementation weakens the rule for boolean-returning
operations.

**Inference.** Every variable starts with its own equivalence class representative (ECR),
typed `ref(⊥ × ⊥)`. Process each statement *exactly once*, joining ECRs as needed. Joining
unifies the associated types, recursively joining components.

Equality constraints join immediately. Inequality constraints cannot: if the left-hand type
variable is currently `⊥`, no join is needed *yet*, but a later statement may change it. So
each `⊥`-typed ECR carries a `pending` set:

```
cjoin(e₁, e₂):  if type(e₂) = ⊥ then pending(e₂) ← {e₁} ∪ pending(e₂)
                else join(e₁, e₂)

settype(e, t):  type(e) ← t;  for x ∈ pending(e) do join(e, x)
```

`join(e₁,e₂)` does `ecr-union`, takes whichever type is non-`⊥`, and either merges the pending
sets (both `⊥`), flushes one pending set (one `⊥`), or calls `unify` (both non-`⊥`). `unify`
on two `ref`s joins their components pairwise; on two `lam`s, joins argument and result types
pairwise.

Because joins only happen when required for well-typedness, the fixpoint is the *minimal*
solution.

**Complexity argument.** ECR count is proportional to program size (constant per statement,
or proportional to variable count for a call). Joins are bounded by ECR count. Everything
else is find operations, N of which cost O(N α(N,N)). Pending sets as binary trees make cjoin
constant-time.

**Functions are just another pointer.** `x = fun(f₁…fₙ)→(r₁…rₘ) S*` sets `x`'s function
component to a `lam` type whose argument types are the formals' types and whose result types
are the return parameters' types. A call `x₁…xₘ = p(y₁…yₙ)` looks up `p`'s `lam` type
(creating one if `⊥`) and cjoins actuals into formals and results out into targets. Indirect
calls, recursion, and function pointers all fall out with no call graph and no special case.

# Applicability

Preconditions: programs "as well-behaved as (mostly) portable C." Constructing pointers from
scratch, bitwise duplication, or relying on compiler-specific variable layout breaks it.
XOR on pointers is fine, because there is a real flow of values.

Flow-insensitive, context-insensitive, monomorphic. The paper is explicit that context
sensitivity would follow from polymorphic type inference, and flags it as future work.

The measured precision, from Tables 1-3: a substantial number of type variables describe
exactly one program variable, most describe a small number, and there are a few catastrophic
outliers describing hundreds. The paper examines the worst one — in LambdaMOO, the type
variable covering 624 locations is *all global constant strings passed to user-defined logging
and tracing procedures*. Any context-insensitive analysis merges those. That is a precise
and honest diagnosis of where the technique breaks, and it points directly at polymorphism as
the fix.

The stated serious weakness: "many programs use data structures such as trees and lists as
central data structures. For these programs the inability to distinguish between structure
elements is a serious loss." The type system extends to per-field types, but the extension
loses the almost-linear bound.

# Relevance

Stage 09 currently has no literature behind it, and the CUJ scopes it to one question: are
these two flvectors provably distinct? That is a much easier question than what this paper
answers, and the mismatch cuts both ways.

**What transfers.** The union-find core is exactly right for our scale and our IR. Every
`make-flvector` call site gets a fresh ECR; assignment, argument passing, and return join ECRs;
two flvector values are provably distinct iff their ECRs differ *and* neither has been unified
with anything unknown. The conditional-join machinery (`pending` sets) is what makes a
single pass suffice — no fixpoint iteration, no worklist. In a nanopass stage that is maybe
150 lines.

The `lam` types matter more than they first appear. The abstract says the results are
equivalent to a flow-insensitive alias analysis *and control flow analysis*. For Scheme those
are the same problem: "which closures can this call site invoke" is "what does this variable
point to." Steensgaard therefore gives us a 0CFA-strength control flow analysis in almost
linear time, unified with the alias analysis, with no call graph precomputed. Shivers' CFA is
the usual reference for Scheme and is far more expensive. If stage 09 produces a call-target
map as a side effect, that feeds `optimize-known-call`-style direct calls at stage 11 for free.

**What does not transfer, and is the reason to be careful.** Steensgaard's imprecision is
*unification*: one assignment `x = y` merges the two points-to sets permanently and
symmetrically, forever, everywhere. Our CUJ says "getting this wrong makes vectorization
miscompile, so default to aliasing and only claim distinctness when proven." Unification is
safe in that direction — merging can only lose distinctness claims, never invent them. Good.
But it degrades fast: one `(let ([v (if p a b)]) ...)` merges `a` and `b`'s ECRs for the whole
program, and every later access through either is then "may alias." In a numeric kernel where
the arrays flow through a shared helper procedure, that is the common case, not the rare one.

The composite-object imprecision is, unusually, *free* for us. Steensgaard's serious loss —
all fields of a struct share one type — is irrelevant when the question is flvector identity
rather than flvector contents. We do not care what is inside; we care that two pointers differ.

**Practical read.** The CUJ's actual precondition — "two values from distinct `make-flvector`
calls that do not escape are distinct" — is *escape* analysis as much as points-to analysis,
and the storage shape graph answers both: a location escapes if its ECR is reachable from a
global, a parameter, or a returned value. The paper says as much about Table 3 — variables
whose type variable describes nothing else "are candidates for global optimizations such as
being represented by a register rather than a memory location," which is stage 08 storage
class assignment. So one pass feeds non-escaping to stage 08's unboxing decisions and
non-aliasing to stage 10, and stage 09 may want to land before stage 08 is finished.

If unification proves too coarse for our kernels, the escape hatch the paper names is
polymorphic (context-sensitive) inference. Do not reach for Andersen's O(A²) inclusion-based
analysis first; our precision problem will be about *context*, not inclusion vs unification.

# Notes

**Metadata caveat.** This copy has no conference header, no page numbers matching any
proceedings, and its ACM permission block reads "Copyright © 1995 by the Association for
Computing Machinery, Inc." The work is universally cited as POPL 1996 (23rd ACM Symposium on
Principles of Programming Languages, St. Petersburg Beach FL, January 1996, pp. 32-41), and
the slug's `popl-` suffix agrees. The 1995 copyright date on a POPL '96 paper is the sort of
thing that happens with camera-ready preparation, but this file appears to be an author or
MSR copy rather than the proceedings scan, so treat the page numbers in any downstream
citation as unverified from this document.

**Title collision, worth flagging.** Reference [Ste95a] in this paper's own bibliography is
"Bjarne Steensgaard. *Points-to analysis in almost linear time.* Technical Report
MSR-TR-95-08, Microsoft Research, March 1995." Identical title, different document, *different
algorithm* — Section 7 says the present paper "is an extension of another almost linear
points-to analysis algorithm [Ste95a]" using "stricter typing rules, implying that the results
are more conservative than they need be." The equality-vs-inequality improvement in Section 4
is precisely the difference. So a title-based lookup can retrieve the weaker 1995 tech report
instead of this paper, and the two are not interchangeable. This PDF is the stronger,
later one — confirmed by the presence of the `≤` typing rules and the `a = 4; x = a; y = a`
motivating example.

Two things are quietly interesting. Bill Landi "independently arrived at the same earlier
algorithm," per a personal communication at POPL'95, and the prototype is implemented **in
Scheme**, on the Value Dependence Graph representation. A points-to analysis for C, written
in Scheme, at Microsoft Research in 1995.

The performance claim is stronger than the usual "our analysis is fast." Morgenthaler's
implementation of the *earlier* algorithm ran the analysis during parsing and increased parse
time by 50% — emacs (127,000 lines) in ~50 extra seconds, FElt (273,000 lines) in ~82. That
is a genuinely different regime from the flow-sensitive analyses of the period, and it is why
Steensgaard's algorithm is still the default answer when someone needs points-to information
and cannot afford to think about it.

The paper does not oversell. It says outright that results are less accurate than
flow-sensitive analyses, names the exact benchmark and the exact cause of its worst merge,
and lists both improvement directions it is pursuing. The one place it is slightly thin is
the claim that treating all primitive operations identically is acceptable; the implementation
already deviates for boolean-returning operations, which suggests the uniform rule was costing
real precision.
