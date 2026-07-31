---
type: technique
title: Points-to and alias analysis
description: Decides whether two references can name the same location, by unification over a non-standard type system in almost linear time; stage 09's single question is a much easier one, and the analysis answers escape at the same time.
tags: [points-to-analysis, alias-analysis, escape-analysis, unification, union-find]
sources:
  - resource: /works/steensgaard-points-to-analysis-in-almost-linear-time-popl-.md
  - resource: /works/shivers-control-flow-analysis-of-higher-order-languages-19.md
  - resource: /works/wegman-zadeck-constant-propagation-with-conditional-branch.md
  - resource: /works/lattner-adve-llvm-a-compilation-framework-for-lifelong-pro.md
  - resource: /works/keep-hearn-dybvig-optimizing-closures-in-o-0-time.md
  - resource: /works/sarkar-waddell-dybvig-a-nanopass-infrastructure-for-compil.md
  - resource: /works/serrano-weis-bigloo-a-portable-and-optimizing-compiler-for.md
implemented_by: [/implementations/llvm.md]
absent_from: [/implementations/chez.md]
pipeline_stage: 09-alias
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

Stage 10 rewrites `a[i] = a[i] + s * b[i]` into packed AVX-512. That is only legal if `a` and `b`
are provably distinct objects. Getting it wrong does not produce a slow program, it produces a
wrong one, so the analysis must default to "may alias" and claim distinctness only when proven.
Our question is narrower than the general one: are these two flvectors provably distinct. The
general literature answers a much harder question and the mismatch cuts both ways.

# Mechanism

Steensgaard's formulation is the one to build, because it is one pass with no worklist and no
fixpoint. Recast points-to analysis as type inference over a non-standard type system, where a
type *is* a node in a storage shape graph describing a set of locations and what they may contain.
Inferring the minimal well-typing is the analysis.

```
alpha ::= tau x lambda                              value type
tau   ::= bottom | ref(alpha)                       location type
lambda::= bottom | lam(a1..an)(an+1..an+m)          function signature type
```

A value may point to a location *or* to a function, so a value type is a pair of both. `bottom`
means "not a pointer." Types may be recursive, so equality is by *type variable identity*, not
structural: two structurally identical types are distinct types.

**Inequalities, not equalities, and this is the part people drop.** The obvious rule for `x = y`
forces `x` and `y` to share a content type. That is too strict, as `a = 4; x = a; y = a;`
demonstrates: under equality, if `x` later holds a pointer the analysis reports that `y` and `a`
may hold it too, deduced from integer assignments. So define

```
t1 <= t2   iff   (t1 = bottom) or (t1 = t2)
```

and the rule becomes: given `x : ref(alpha1)` and `y : ref(alpha2)`, `x = y` is well typed when
`alpha2 <= alpha1`. Each component must be bottom or equal to the corresponding component.
Non-pointers cost nothing. Primitive operations `x = op(y1..yn)` require `alphai <= alpha` for
every operand, because pointer subtraction yields a non-pointer from which either operand can be
*reconstituted* given the other.

**Inference.** Every variable starts as its own equivalence class representative typed
`ref(bottom x bottom)`. Process each statement exactly once. Equality constraints join
immediately; inequality constraints cannot, because if the left type variable is currently bottom
no join is needed *yet* but a later statement may change that. So each bottom-typed ECR carries a
pending set:

```
cjoin(e1, e2):  if type(e2) = bottom then pending(e2) := {e1} union pending(e2)
                else join(e1, e2)

settype(e, t):  type(e) := t;  for x in pending(e) do join(e, x)
```

`join` does the union-find union, takes whichever type is non-bottom, and either merges the
pending sets (both bottom), flushes one (one bottom), or calls `unify` (neither). `unify` on two
`ref`s joins their components pairwise; on two `lam`s, joins arguments and results pairwise. Joins
happen only when required for well-typedness, so the fixpoint reached is the *minimal* solution.

**Functions are just another pointer.** A function definition sets the function component of its
name to a `lam` built from formals and return parameters. A call looks up the `lam` (creating one
if bottom) and cjoins actuals into formals and results out into targets. Indirect calls, recursion
and function pointers fall out with no call graph and no special case. This is why the abstract
claims equivalence to a flow-insensitive alias analysis *and control flow analysis*: in Scheme
those are the same problem.

**Escape falls out of the same graph.** A location escapes if its ECR is reachable from a global,
a parameter, or a returned value. The paper notes that variables whose type variable describes
nothing else "are candidates for global optimizations such as being represented by a register
rather than a memory location," which is stage 08's storage class assignment stated in 1996.

ECR count is proportional to program size, joins are bounded by ECR count, and everything else is
find operations, giving O(N alpha(N,N)) time and O(N) space. Pending sets as binary trees keep
cjoin constant.

# Preconditions

Programs "as well-behaved as (mostly) portable C." Constructing pointers from scratch, bitwise
duplication, or relying on compiler-specific variable layout breaks it; XOR on pointers is fine,
because there is a real flow of values. Flow-insensitive, context-insensitive and monomorphic;
the paper flags polymorphic inference as the route to context sensitivity and names it as future
work.

Two deliberate imprecisions buy the linear bound. A pointer's whole target set is one type, and
*all fields of a composite object share one type*, because per-field types make the graph
potentially exponential for languages with heavy struct nesting. The composite imprecision is, for
once, free for us: fields sharing a type is irrelevant when the question is flvector *identity*
rather than contents.

For our IR the preconditions are unique names and a distinguishable allocation site per
`make-flvector`. Assignment conversion should already have run, since the analysis is defined over
assignment to variables.

# Cost

About 27 seconds on a 75,000-line C program on an SGI Indigo2, roughly 4x the cost of merely
traversing the program representation. For scale, contemporary interprocedural analyses had not
been reported working above about 10,000 lines. Morgenthaler's implementation of the *earlier*
algorithm ran during parsing and increased parse time by 50%: emacs at 127,000 lines cost about 50
extra seconds, FElt at 273,000 about 82.

Precision, from Tables 1 through 3: many type variables describe exactly one program variable,
most describe a small number, and a few catastrophic outliers describe hundreds. The paper examines
its worst case honestly. In LambdaMOO the type variable covering 624 locations is *all global
constant strings passed to user-defined logging and tracing procedures*. Any context-insensitive
analysis merges those, so the diagnosis points straight at polymorphism rather than at the
unification core.

The stated serious weakness: "many programs use data structures such as trees and lists as central
data structures. For these programs the inability to distinguish between structure elements is a
serious loss."

# Disagreements

**Unification against inclusion.** Andersen's context-insensitive inclusion-based solution is
O(A^2) in the number of abstract locations; Steensgaard's is O(N). The precision claim is
deliberately modest, "roughly comparable to" Weihl's cubic-time flow-insensitive analysis and
worse than any flow-sensitive analysis, and the abstract characterizes it as equivalent to a
flow-insensitive analysis "that assumes alias relations are reflexive and transitive." The escape
hatch the paper names is *not* Andersen. It is polymorphic, that is, context-sensitive, inference.
Our precision problem in a numeric kernel will be about context, not inclusion, so do not reach for
Andersen first.

**Field sensitivity does not rescue you on real code.** LLVM goes the other way with Data Structure
Analysis, flow-insensitive but field-sensitive and context-sensitive. Lattner and Adve report type
information checkable for 68% of static memory accesses across SPEC CPU2000 C, dropping to 43.7% on
176.gcc and 12.5% on 177.mesa, with custom allocators and the same object described by different
struct types in different places as the named causes. The more expensive analysis also fails on half
the accesses in real programs; it fails on different ones.

**A third position: do not build an alias analysis, encode aliasing into the dataflow problem.**
Wegman and Zadeck insert `if IsAliased(a,b) then b := a` after each assignment to a maybe-aliased
variable, so the alias merge becomes an ordinary phi and `IsAliased` becomes a lattice cell that
inlining can later resolve to true or false. It blows up by a factor of V in the worst case, and
their own recommended fallback is to assign bottom to heavily-aliased variables. The idea is worth
having because it makes stage 09's results visible to the numeric domains with no separate merge
machinery.

**A title collision that will retrieve the wrong algorithm.** Reference [Ste95a] in this paper's own
bibliography is "Bjarne Steensgaard, *Points-to analysis in almost linear time*, Technical Report
MSR-TR-95-08, Microsoft Research, March 1995." Identical title, different document, different
algorithm. Section 7 says the POPL paper "is an extension of another almost linear points-to
analysis algorithm [Ste95a]" using "stricter typing rules, implying that the results are more
conservative than they need be," and the equality-versus-inequality improvement is precisely the
difference. Our copy is the stronger one, confirmed by the `<=` typing rules and the
`a = 4; x = a; y = a` example. Separately, the copy in `sources/` has a 1995 ACM copyright line and
no conference header, so its page numbers are unverified against the POPL 1996 proceedings.

**One thin spot.** The paper claims treating all primitive operations identically is acceptable, but
the implementation already deviates for boolean-returning operations, which suggests the uniform
rule was costing real precision.

# For us

Stage 09 as specified in the CUJ asks one question, so build the smallest thing that answers it:
maybe 150 lines as a nanopass stage. Every `make-flvector` site gets a fresh ECR; assignment,
argument passing and return join ECRs; two flvectors are provably distinct iff their ECRs differ
and neither has been unified with anything unknown. Anything unproven aliases.

Three consequences worth planning around.

The `lam` component is worth more than it looks. It gives 0CFA-strength call-target information in
almost linear time, unified with the alias analysis and with no precomputed call graph, where
Shivers' CFA (the usual Scheme reference) is far more expensive. A call-target map falling out of
stage 09 feeds direct-call selection at stage 11 and Serrano's closure classification at stage 08
for free, which argues that stage 09 should land *before* stage 08 is finished rather than after.

The escape query is answered by the same graph, and the CUJ's actual precondition, "two values from
distinct `make-flvector` calls that do not escape are distinct," is as much an escape question as an
aliasing one. One pass feeds non-escaping to stage 08's unboxing decisions and non-aliasing to
stage 10. Note that for *procedures* the cheaper answer is well-knownness computed during closure
conversion, which is escape analysis on the call graph rather than on data flow; use that rather
than routing closures through this pass.

The failure mode to expect is unification's symmetry. One `x = y` merges two points-to sets
permanently, symmetrically, everywhere. That is safe in our required direction, since merging loses
distinctness claims and never invents them, but it degrades fast: a single
`(let ([v (if p a b)]) ...)` merges `a` and `b` for the whole program and every later access
through either becomes may-alias. In a numeric kernel where arrays flow through a shared helper
that is the common case, not the rare one. If it proves too coarse, add context sensitivity.

Finally, this stage is the one that most needs a verification pass in the Sarkar-Waddell-Dybvig
sense: an `L -> L` pass, disableable, asserting that every claimed non-aliasing pair traces to
distinct `make-flvector` sites. That converts a stage 10 miscompile into a stage 09 assertion
failure, which is the difference between a wrong nbody output and a debuggable one.
