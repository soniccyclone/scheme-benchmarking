---
type: paper
title: "Retrospective: Soft Typing (bundled with a facsimile reprint of \"Soft Typing\", PLDI 1991)"
description: A two-page 2003 retrospective on the 1991 PLDI soft typing paper, bound together with a scanned reprint of the original paper, which encodes union and recursive types into Remy-style flag fields so that unmodified ML unification can infer them and insert run-time checks where inference fails.
resource: knowledge/sources/cartwright-fagan-soft-typing-retrospective.pdf
tags: [soft-typing, type-inference, union-types, recursive-types, unification, run-time-checks]
authors: [Robert Cartwright, Mike Fagan]
year: 2003
venue: "SIGPLAN Notices 39(4), 20 Years of PLDI (1979-1999): A Selection, 2003, pp. 412-428; reprint of PLDI 1991, pp. 278-292"
informs: [/techniques/type-feedback.md, /techniques/storage-class-assignment.md, /techniques/dataflow-analysis.md]
pipeline_stage: 08-represent
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Two documents in one file. Pages 412-413 are the retrospective proper, born-digital: a
four-section note on where soft typing came from (Milner, Damas, Tofte for HM; Remy for
record typing; Colmerauer for circular unification; slack variables borrowed from
optimization), what the 1991 paper claimed, and what built on it. Pages 414-428 are a
scanned facsimile of the original PLDI 1991 paper, complete with both appendices.

The original contribution is a static type checker that is forbidden to reject. Where a
conventional checker fails, soft typing inserts an explicit run-time narrower and keeps
going, so the output is always a statically type-correct program in a typed sublanguage.
The technical contribution that makes this practical is the encoding: full set-theoretic
union types and recursive types are represented so that the *unmodified* Hindley-Milner
type assignment algorithm infers them, with circular unification substituted for ordinary
unification.

# Mechanism

The type language `Typ` extends ML types with `+` (union) and `fix x.T` (recursive), then
restricts to *tidy* expressions: every `fix` is formally contractive, and every `u + v` is
*discriminative*, meaning neither side is a bare type variable and each type constructor
appears at most once at top level. Discriminativeness is what makes the encoding invertible.

The encoding follows Remy's record trick. Introduce one highly polymorphic constructor `R`
whose arity is `sum over c in C of (1 + arity(c))`: one *flag* slot per type constructor,
plus one *pattern* slot per type argument. Flags are instantiated to the 0-ary constants
`+` ("must appear") or `-` ("must not appear"), or left as variables ("may"). A tidy type
`t` maps to two parametric terms, `R+(t)` encoding the set of all supertypes of `t` and
`R-(t)` all subtypes, defined mutually recursively because `->` is antimonotonic in its
first argument, so the `->` slot swaps `R+` and `R-`. Union disappears entirely: subtyping
and supertyping become flag instantiation, which plain unification already does.

The assignment algorithm is then three steps. (1) Encode the type of every primitive
operation as `R+` of its declared type, so any supertype is a legal typing (justified by
the `SUB` rule). (2) Run Algorithm W with circular unification. (3) Decode: enumerate the
*splitting* flag substitutions of the resulting term (a flag occurring both positively and
negatively is splitting; a term with `k` of them has valence `2^k`) and apply `R^-1` to
each, yielding the set of tidy types the term denotes.

Check insertion reuses the same machinery, partitioned into positive and negative phases.
Encode supertypes with all `-` flags replaced by *fresh variables*, erasing all negative
information; run W, which now cannot fail because unification only ever fails on `+` versus
`-`; then, per primitive occurrence, unify the positive type against the original encoded
type and, where that fails, insert the narrower `down-arrow S->T` that repairs it. A
narrower is the identity on `T`, yields the exceptional value `fault` on `S - T`, and
`wrong` otherwise. Because `fault` is in every ideal in the type semantics (Appendix B,
built on MacQueen-Plotkin-Sethi ideals) but `wrong` is in none, narrowers have a legitimate
static type and undefined applications remain untypable.

# Applicability

Preconditions are stiff. All data constructors must be disjoint and the constructor set
finite, since the arity of `R` is computed from it: a program with `n` constructors gets an
`R` of roughly `n` plus total arity slots, and the VAX-scale constructor sets of a real
Scheme make these terms large. Tidiness must hold, so `fix x.x` and `cons(x) + cons(y)` are
outside the language. Assignment converts to ML's cost profile: linear in practice,
exponential in nested `let` in the worst case, which the authors report never observing.

The paper does not extend the treatment to mutation or `call/cc`; the retrospective credits
Wright and Cartwright (LFP 1994) with that. Set-based analysis (Flanagan et al., PLDI 1996)
is more precise but costs `O(n^3)` without polyvariance and exponential with it.

# Relevance

This is the strongest available argument for our declarations-first design, but the argument
is in the *reprint*, not the retrospective. Two results matter directly.

First, adding the `SUB` rule destroys principal types (Example 4). `(f1 f2)` has both
`a -> a` and `a+b -> a+b` and neither is best; the only common supertype, `forall x. x -> x`,
is not a valid typing. A programmer cannot predict which typing the compiler will pick, so
cannot predict which run-time checks survive, so cannot predict whether the inner loop
unboxes.

Second, and worse for us, Example 9: `N2 = \f. if f(true) then f(5) else f(7)` gets a
perfectly reasonable inferred type, and yet `N2 (\x.x)` is well-defined but does not type
check. The inference result at a definition silently constrains what is legal at a *distant*
call site. That is exactly the failure mode a `declare` form does not have. A declaration is
a local, readable contract; the storage class assigned at stage 8 follows from something the
programmer wrote, not from a global fixpoint whose outcome depends on unrelated code.

The useful positive lesson is the check-insertion split: propagate positive information
first, then negative, and place a narrower only where the two clash. That is the right shape
for our guard-placement pass, and it is why a soft-typing-style engine remains valuable as a
*checker for undeclared code*, downstream of declarations rather than in place of them.

# Notes

Correction to the bibliography, and it matters. `docs/phases/00-compiler-research/PLAN.md`
line 422 describes this work as "why inference-first lost on usability, which is our
argument for declarations." **The retrospective contains no such account.** It has four
sections: history of the concept, prior work that influenced it, contributions of the 1991
paper, and subsequent work. There is no discussion of adoption, of standardization, of
R5RS/R6RS, or of why soft typing did not become part of any Scheme standard. Its tone is
matter-of-fact and mildly triumphant, ending on Pessaux and Leroy's use of the encoding for
ML exception analysis. The only hint of the adoption story is oblique: soft typing landed in
DrScheme's static debugger (MrSpidey, later MrFlow), which is a *tool*, not a language
feature.

The argument our plan wants is real, but it must be sourced to the technical content of the
reprinted 1991 paper (loss of principal types; the Example 9 anomaly) and to the cost
figures the retrospective quotes for the SBA successor, not to any claim the retrospective
makes.

Second correction, minor: the slug says "retrospective" and the plan treats the file as the
retrospective alone. Two of the seventeen pages are the retrospective. Fifteen are a scanned
reprint of the full PLDI 1991 paper including Appendix A (denotational semantics of `Exp`
via a data tableau) and Appendix B (ideal-model type semantics). Anyone citing this file for
the original paper's content is on solid ground; the file contains it.

Dated in one respect worth flagging: the paper's framing assumes the only alternatives are
"reject" and "insert a check." Gradual typing's later answer, blame tracking at declared
boundaries, is absent, and the retrospective written in 2003 does not mention it either.
