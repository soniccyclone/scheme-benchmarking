---
type: paper
title: "Soft Typing with Conditional Types"
description: Reduces soft typing to satisfiability of type inclusion constraints over a type language with unions, intersections and conditional types, so that control-flow narrowing at case expressions falls out of type inference rather than being bolted on.
resource: knowledge/sources/aiken-wimmers-lakshman-soft-typing-with-conditional-types-.pdf
tags: [soft-typing, conditional-types, predicate-narrowing, type-inclusion-constraints, set-based-analysis]
authors: [Alexander Aiken, Edward L. Wimmers, T. K. Lakshman]
year: 1994
venue: "POPL 1994 (21st ACM SIGPLAN-SIGACT Symposium on Principles of Programming Languages)"
informs: [/techniques/predicate-narrowing.md, /techniques/soft-typing.md, /techniques/type-inclusion-constraints.md]
pipeline_stage: 05-intervals
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Control-flow narrowing expressed as a typing rule instead of an ad hoc analysis pass. Prior soft
typers (Cartwright and Fagan) and prior abstract interpreters (Shivers' type recovery, Aiken and
Murphy) all had a special-purpose step that constrained the types of a conditional's branches
using information about the predicate. This paper introduces *conditional types* and shows that
the step disappears: it is just what the `case` rule does. The three claimed contributions are
accuracy (they believe it infers the most accurate types of any proposed inference system for
dynamically or statically typed languages), the reduction of control-flow analysis to type
inference, and the observation that several existing dynamic-language analyses are special cases
of solving type inclusion constraints.

The second contribution is the one that matters for us, and it is the closest existing formalism
to the predicate narrowing our design depends on.

# Mechanism

Types are ideals: non-empty, downward-closed, directed-closed subsets of the semantic domain not
containing `wrong`. The type language is

```
tau ::= tau -> tau | c(tau,...,tau) | alpha | tau ∪ tau | tau ∩ tau | tau ? tau | 0 | 1
```

`0` is `{bottom}`, the least type. `1` is the whole domain minus `wrong`, the greatest type.
Recursive types are not primitive; they are definable by constraints, so `alpha = cons(beta, alpha) ∪ nil`
uniquely determines the lists over `beta`.

A **conditional type** `tau1 ? tau2`, read "tau1 if tau2," denotes `tau1` when `tau2` is
inhabited, and `{bottom}` otherwise. That is the whole idea. A branch's contribution collapses to
nothing exactly when the branch's guard type is uninhabited.

Type schemes carry subsidiary constraints, `forall a1..an . tau where S`, denoting the
intersection of `tau` over all solutions of `S`. This is bounded quantification by constraint set
rather than by a single upper bound, and it is how a function's domain restriction gets recorded.

The **[CASE] rule** is the payload. For `case e of p1: e1; ...; pn: en` with `e : tau`, `ei : taui`,
and `⌈pi⌉` the type of all values matching pattern `pi`:

```
result type:  ∪i  taui ? (tau ∩ ⌈pi⌉)
constraint:   tau ⊆ ∪i ⌈pi⌉
```

Branch `i` contributes `taui` only if `tau ∩ ⌈pi⌉` is inhabited. When the scrutinee's type cannot
match pattern `i`, `tau ∩ ⌈pi⌉ = 0`, so `taui ? 0 = 0` and the branch vanishes from the result.
The constraint does double duty: it checks that the branches are exhaustive over `tau`, and it
propagates `e`'s type down into the pattern variables of each branch.

Worked out, `\y. case y of true: zero; false: succ(zero)` gets

```
forall a. a -> (zero ? (a ∩ true)) ∪ (succ(zero) ? (a ∩ false))   where { a ⊆ true ∪ false }
```

Substituting `a := true` simplifies to `true -> zero`. The input-output dependency is captured
exactly, in the type, with no separate analysis. Similarly `car` gets a type accurate even on
heterogeneous lists, since only the head's type appears. The paper's substantial example is a
`last` function defined via a strict Y combinator and used polymorphically on both a homogeneous
list of `zero` and a heterogeneous list of booleans ending in `zero`; the inferred type is
`forall a. X -> a where { X = cons(1,X) ∪ cons(a,nil) }`, X being lists of length at least one
ending in `a`, and the whole program types as `zero` with no run-time checks required.

**Inference.** A *most general derivation* is pinned down syntactically (every assumption is a
distinct variable, [APP] uses fresh variables, [GEN] applied once per `let` quantifying maximally
and once at the end, [INST] immediately after [VAR], nowhere else). It is unique up to renaming and
yields the *minimal* type. Minimal is not principal: many type expressions denote the same type,
so principal types do not exist here, but minimal ones do and that is what an implementation
needs.

**Solving.** Reduces to solvability of *proper* systems `{Li ⊆ Ri}` from Aiken and Wimmers,
FPCA '93. The L and R grammars are deliberately asymmetric: within an L type, `L1 ∩ L2` requires
`L2` to be a monotype and upward-closed; within an R type, `R1 ∪ R2` requires the disjuncts to be
provably disjoint. Those two restrictions rule out exactly the two forms nobody knows how to
resolve, intersection on the left and union on the right. Conditional types extend the L grammar
with `L1 ? L2` and decompose by

```
{ L1 ? L2 ⊆ R }  ==  { L1 ⊆ R }  or  { L2 ⊆ 0 }
```

a disjunction over solution sets, which is where the exponential worst case comes from.

**Check insertion.** Only three constraint forms arise: `alpha ⊆ beta` from [APP]'s argument,
`tau ⊆ beta -> gamma` from [APP], and `tau ⊆ ∪i ⌈pi⌉` from [CASE]. The first is always satisfiable
by `alpha := 1`, so only the latter two can fail, and they correspond exactly to the only two
run-time checks the language needs: is it a function, and is the case exhaustive. Ill-typed
programs are repaired with *narrowers*: `Check_X` is the identity on `X` and `bottom` elsewhere,
with type `forall a. a -> a ∩ X`. Wrapping every application and every case scrutinee always
suffices, which is the conservative bound.

The interesting part is minimizing checks. Extend each failable constraint with an *error term*
carrying a fresh error variable `eps`:

```
tau ⊆ (beta -> gamma) ∪ (eps ∩ ¬(1 -> 1))
tau ⊆ (∪i taui')    ∪ (eps ∩ ¬∪i taui')
```

where `¬X` is the largest type disjoint from `X`. The extended system always has a solution (set
everything to `1`), so the solver always terminates successfully. Then consider each `eps` in
turn: if `S ∪ {eps = 0}` is solvable, permanently add `eps = 0` and emit no check; if not, emit
the check and leave `S` alone. Setting every `eps` to zero recovers the original system, that is,
a well-typed program.

# Applicability

The narrowing is *syntactic*, driven by pattern shapes in `case`. Scheme narrows through
predicate applications in `if`, not through patterns, so a front-end translation from
`(if (fixnum? x) A B)` into a case-like discrimination on `x` is required before any of this
applies. That translation is the gap between this paper and our use of it, and the paper does not
address it.

The language is strict, higher-order, purely functional. Imperative features "should be extensible
using standard techniques," citing Tofte, which means not done. Mutation, `set!`, vectors, and
therefore most of a real Scheme heap are outside the formalism.

The solver is exponential in the worst case. Measured behaviour on a test suite of FL programs
ranging from small utilities to several-hundred-line modules is much better, with the growth curve
staying mild at realistic module sizes. Notably, only a minority of run time is in the constraint
solver; the majority goes to simplifying type expressions and deciding where to insert checks,
and that part was not tuned. Two implementations exist, one small one for the toy language L and a
considerably larger one for FL, both in Lisp on a shared inclusion-constraint solver, both
measured on an IBM RS/6000 under Lucid Common Lisp.

The type language deliberately keeps `true` and `false` distinct rather than a `bool` type, and
`nil` and `cons` distinct rather than `list`, in order to type case branches precisely. That
choice is load-bearing.

Section 6.3 argues against abstract interpretation on two grounds worth taking seriously: those
techniques implicitly assume the whole program is available at once, and it is difficult to prove
anything useful about the *quality* of what they compute, so a programmer cannot predict which
programs will analyse well. This inference algorithm is compositional and bottom-up, so it works
under separate compilation and comes with lemmas a programmer can reason from.

# Relevance

Take the shape of the [CASE] rule, not the type language. Translated into an abstract-domain
setting, the rule says: a branch's outgoing abstract state is guarded by the *satisfiability* of
the branch condition met with the incoming state, and an infeasible branch contributes bottom
rather than joining garbage into the merge. That is exactly the property that makes

```scheme
(if (and (fixnum? i) (< i (vector-length v))) (vector-ref v i) ...)
```

drop its bounds check at stage 5, and it is what Wegman-Zadeck conditional constant propagation
does for constants. This paper is the version of it stated over a type lattice rich enough to
express representation sets, which is what stage 8 consumes.

The error-variable construction is directly applicable and is better than what most check-removal
schemes do. Instead of asking "is the program well typed," ask, per check site, "is the system
still solvable if I assert this check never fails." One satisfiability query per check, with a
guaranteed-terminating solver, and a principled minimal answer rather than a heuristic. Our bounds
check elimination and our type check elimination should both be framed this way, with the domain
substituted for the type language.

The warning is the type language itself. Set-theoretic types with unions, intersections,
conditionals and recursion over an infinite constructor domain give an exponential solver whose
majority cost is not even the solving. Our intervals plus pentagon domain is deliberately far
weaker and far cheaper, and it should stay that way. Import the narrowing rule and the
check-minimization framing; do not import the lattice.

Finally, the compositional bottom-up argument matters independently. If we want separately
compilable Scheme modules with cross-module optimization, a whole-program abstract interpretation
is the wrong architecture, and this paper articulates why better than most.

# Notes

Venue confirmed from the header on page 1: "To appear in Proceedings of the 21st Annual ACM
SIGPLAN-SIGACT Symposium on Principles of Programming Languages," which is POPL 1994, as the
bibliography states. Aiken and Wimmers are at IBM Almaden with Aiken's current address given as
UC Berkeley; Lakshman is at UIUC and did the work while visiting Almaden. No correction to record.

**Extraction warning.** This PDF uses a Type-1 font whose digit glyphs are unmapped, so every
numeral is dropped by text extraction. Section numbers, citation numbers, figure numbers, line
counts, percentages, memory figures and page numbers are all unreadable in the extracted text.
Everything quantitative above is stated qualitatively for that reason and not guessed. Anyone
needing the exact implementation size, solver time percentage, or test suite count must read the
rendered pages rather than extracted text. The text layer is also one word per line and reflows
badly, but the prose reconstructs unambiguously.

The paper is candid that it does not know how it compares empirically to Cartwright and Fagan's
soft typing, only that its type language is strictly more expressive (theirs lacks intersection
types and conditional types, and its unions must be discriminative). That comparison is still
open, and `cartwright-fagan-soft-typing-retrospective` in this corpus is the other side of it.
