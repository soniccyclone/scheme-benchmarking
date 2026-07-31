---
type: technique
title: Type recovery from untyped code
description: Recovers a static representation type for values in a latently typed program, by predicate narrowing, inclusion constraints, or unification, so that a check can be dropped and a storage class assigned; the whole declaration-anchored design rests on this.
tags: [type-recovery, soft-typing, predicate-narrowing, type-inclusion-constraints, check-elision]
sources:
  - resource: /works/cartwright-fagan-soft-typing-retrospective.md
  - resource: /works/aiken-wimmers-lakshman-soft-typing-with-conditional-types-.md
  - resource: /works/shivers-control-flow-analysis-of-higher-order-languages-19.md
  - resource: /works/wegman-zadeck-constant-propagation-with-conditional-branch.md
  - resource: /works/h-lzle-ungar-optimizing-dynamically-dispatched-calls-with-.md
  - resource: /works/chambers-ungar-customization-optimizing-compiler-technolog.md
  - resource: /works/leroy-unboxed-objects-and-polymorphic-typing-popl-1992.md
  - resource: /works/dybvig-et-al-the-development-of-chez-scheme-icfp-2006.md
implemented_by: [/implementations/chez.md, /implementations/sbcl.md]
absent_from: []
pipeline_stage: 04-declare
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

Given `(fl+ (fl* x x) (fl* y y))` in a language with no type declarations, decide whether `x`
and `y` are flonums. If you can decide it, the safe primitive becomes its unsafe variant, the
values get an unboxed storage class at stage 08, and the loop body becomes a candidate for
stage 10. If you cannot, every operation carries a tag test and a heap allocation. This is the
analysis every later stage of our pipeline consumes, and the one our design proposes to anchor
in programmer-written declarations rather than in a global fixpoint.

# Mechanism

Four families, in increasing cost and decreasing predictability.

**Predicate narrowing, flow-sensitive.** The abstract state is a map from variable to
predicate over a finite lattice. At a conditional, recurse into the arms under different
states. Chez's `cptypes` is exactly this shape, and its signature is the specification:

```
(cptypes ir ctxt types) -> (values ir ret types t-types f-types)
  t-types: environment for the "then" arm    f-types: environment for the "else" arm
```

At `(if (P x) A B)` the then-arm environment is `env` met with `P(x)` and the else-arm
environment is `env` met with the complement. Merges join. A primitive signature database
supplies the transfer functions (`(fl+ [sig [(flonum ...) -> (flonum)]])`). Check elision is
then one predicate test per argument: if the inferred type implies the primitive's declared
argument predicate, swap in the unsafe variant. Cost is one pass, and the lattice is finite so
no widening is needed.

**Conditional types.** Aiken, Wimmers and Lakshman make the narrowing a typing rule instead of
a separate pass. A conditional type `tau1 ? tau2` denotes `tau1` when `tau2` is inhabited and
`{bottom}` otherwise. The `[CASE]` rule for `case e of p1: e1; ...` with `e : tau` is

```
result:      union over i of  taui ? (tau  intersect  ceiling(pi))
constraint:  tau  subset-of  union over i of ceiling(pi)
```

A branch whose guard cannot match contributes `taui ? 0 = 0` and vanishes from the result. The
constraint checks exhaustiveness and pushes the scrutinee's type into each branch's pattern
variables. Solving reduces to proper inclusion systems, with `{L1 ? L2 subset R}` decomposing
to `{L1 subset R}` or `{L2 subset 0}`, a disjunction over solution sets.

**Unification-based soft typing.** Cartwright and Fagan encode union and recursive types so
that unmodified Algorithm W infers them. Restrict to *tidy* types (every `fix` contractive,
every union discriminative), introduce one polymorphic constructor `R` with a flag slot per
type constructor and a pattern slot per argument, and map each type to `R+(t)` (its
supertypes) and `R-(t)` (its subtypes), mutually recursive because `->` is antimonotonic in
its first argument. Union disappears into flag instantiation, which plain unification already
does. Circular unification handles recursion. Check insertion runs in two phases: propagate
positive information with every `-` flag replaced by a fresh variable, so unification cannot
fail; then per primitive occurrence unify against the original encoded type and insert a
narrower where that fails.

**Type recovery over a control-flow analysis.** Shivers, chapter 9, is quantity-based: types
attach to qnames, variables bind to qnames, and the answer is a type cache
`(REF x CN) -> Type`, so types belong to variable *references*, not variables. Information
arrives from conditional branches, from primitives (`(car p)` implies `p` is a pair afterward,
because `car` really is `(if (pair? p) (cont (%car p)) ($))`), and from user declarations,
where `enforce` is a checked test and `proclaim` is `(if (pred val) val ($))` with an
undefined-effect arm the compiler may elide. That declaration pair is our `declare` form,
named and specified in 1991.

**Check minimization.** Aiken et al. give the framing worth copying regardless of lattice.
Extend each failable constraint with an error term carrying a fresh error variable `eps`, so
the extended system is always solvable. Then per check site ask: is the system still solvable
with `eps = 0` asserted? If yes, permanently add it and emit no check. One satisfiability
query per site, guaranteed-terminating solver, principled minimal answer instead of a
heuristic. Substitute our interval domain for the type language and this is our bounds-check
and type-check elimination pass.

# Preconditions

Constructor sets must be finite and disjoint for the unification encoding, since `R`'s arity
is computed from them; a real Scheme's constructor set makes those terms large. Tidiness rules
out `fix x.x` and `cons(x) + cons(y)`. Narrowing is *syntactic* on `case` patterns in Aiken et
al., so Scheme needs a front-end translation from `(if (fixnum? x) A B)` into a case-like
discrimination before any of it applies, and the paper does not supply that translation.
Neither soft-typing paper covers mutation or `call/cc`; the retrospective credits Wright and
Cartwright (LFP 1994) with that.

Two harder preconditions. First, narrowing is unsound across merged analysis contexts. Shivers
proves the rule: an analysis is safe under contour merging only if it moves monotonically
toward approximation, and narrowing does not, which is why type recovery needs reflow where
plain CFA does not. If we inline one procedure into two call sites and analyze the merged
body, we inherit that bug. Second, integer does not mean fixnum. Shivers is explicit that
bignums defeat fixnum recovery entirely, because two's complement fixnums are not closed under
addition, subtraction, multiplication, negation or division. Type recovery can prove every
operation in `fact` is integer arithmetic and still not license an `add`. Only range analysis
closes that gap, which is why stage 05 and not this technique is load-bearing for our numeric
benchmarks.

# Cost

Predicate narrowing is one pass over the term with a finite lattice; Chez ships it at the safe
optimize level and it does not appear in any compile-time complaint. Unification-based soft
typing inherits ML's profile: linear in practice, exponential in nested `let` in the worst
case, which the authors report never observing. Set-based analysis, the successor, is O(n^3)
without polyvariance and exponential with it. Aiken's solver is exponential in the worst case
and mild in practice, with the notable detail that a *minority* of run time is in the
constraint solver and the majority goes to simplifying type expressions and deciding where to
insert checks, a part that was never tuned. Shivers' type recovery over 1CFA cost 5.1 to 7.8
seconds on programs under twenty lines, roughly an order of magnitude more than the underlying
1CFA, because reflow re-runs the abstract interpretation once per call context.

Precision given up is stated most clearly by the failure to have principal types, below.

# Disagreements

**Hölzle and Ungar measured static type analysis performing no better than no analysis at
all.** SELF-91 ran an iterative static type analysis. SELF-93 with type feedback disabled ran
none. The 1994 measurement across nine real programs is that SELF-91 is only marginally faster
in run time and performs about the *same number of calls*. A profile counter, by contrast,
delivered 1.7x. This is the strongest single piece of evidence against our architecture, and
it is a measurement on real programs rather than a rhetorical claim. The defense is that
SELF's problem was receiver dispatch over an open, user-extensible object graph with dynamic
inheritance, whereas ours is a closed finite set of numeric representations pinned by
declarations, which predicate narrowing genuinely does resolve. That defense is plausible and
unproven. It should be tested against nbody before it is believed, and it is not evidence
until it is.

Chambers and Ungar's earlier and more quotable line, "Type inferencing holds little promise for
improving the performance of object-oriented dynamically-typed languages" (1989, section 7), is
the *weaker* claim of the two and should not be cited in its place. Its evidence is Smalltalk
type inference defeated by user-defined control structures, `nil` initialization, `perform:`
and `become:`. Scheme has none of those. The 1994 measurement is the sentence to hold onto.

**Inference at a definition silently constrains distant call sites, and the argument is in the
reprint, not the retrospective.** The two-page 2003 retrospective bundled as
`cartwright-fagan-soft-typing-retrospective` never discusses adoption, standardization, or why
soft typing did not enter any Scheme standard. Its four sections are history, prior work,
contributions, and subsequent work. The usability argument lives in the scanned facsimile of
the original PLDI 1991 paper at pages 3 through 17 of the same PDF, and it has two parts.
Example 4: adding the `SUB` rule destroys principal types, because `(f1 f2)` has both `a -> a`
and `a+b -> a+b` with neither best, and the only common supertype is not a valid typing. A
programmer cannot predict which typing the compiler picks, so cannot predict which run-time
checks survive, so cannot predict whether the inner loop unboxes. Example 9 is worse:
`N2 = \f. if f(true) then f(5) else f(7)` gets a perfectly reasonable inferred type, and
`N2 (\x.x)` is well-defined but does not type check. Cite the reprint. Aiken et al. concede the
same loss from the other direction: their system has no principal types either, only *minimal*
ones, which is enough for an implementation but not for a programmer's mental model.

**Compositional inference against whole-program abstract interpretation.** Aiken et al.,
section 6.3, argue against abstract interpretation on two grounds: those techniques implicitly
assume the whole program is available at once, and it is difficult to prove anything useful
about the *quality* of what they compute, so a programmer cannot predict which programs will
analyze well. Shivers concedes the second point by a different route, offering no complexity
analysis at all and falling back on "compile without optimization during development." Neither
side disputes the facts; they disagree on whether unpredictable analysis quality is
disqualifying. Our design takes Aiken's side and should say so.

**Chez already does most of this, which nobody seems to have noticed.** From `s/cptypes.ss` and
`s/cptypes-lattice.ss`: roughly a hundred predicates with a subtype ordering, flow-sensitive
narrowing from predicate tests returning separate then and else environments, and
`fold-primref/try-unsafe` at line 1963 which promotes a safe primitive to its unsafe variant
whenever every argument's inferred type implies the primitive's declared predicate, gated on a
`safeongoodargs` flag carried by 270 primitives. This means a five-line `syntax-rules` macro
over a predicate guard is already a working declaration mechanism on Chez today:

```scheme
(define-syntax declare-types
  (syntax-rules ()
    ((_ ((x pred) ...) body ...)
     (if (and (pred x) ...) (let () body ...)
         (error 'declare-types "type assertion failed")))))
```

One check per declared variable at scope entry, unchecked inside, and *sounder* than Common
Lisp's `(safety 0)`, which trusts the declaration and corrupts memory if you lied. That shape
is SRFI 253's `lambda-checked`, whose abstract hedges that this makes for "faster code too,
sometimes." On Chez the effect is stronger than the hedge: the check unlocks unsafe promotion
for every downstream operation in the body.

# For us

Stage 04 binds a predicate to a variable for a scope; stages 05 and 06 consume it; stage 08
turns it into a storage class. Take the Chez `cptypes` shape verbatim for the narrowing
(separate then and else environments returned from the transformer, per Sarkar-Waddell-Dybvig
extra return values rather than grammar annotations), the `[CASE]` rule's semantics for what a
branch contributes (infeasible branch contributes bottom, never joins garbage into the merge,
which is also what Wegman-Zadeck's executable-edge flag does for constants), and Aiken's
error-variable construction for deciding which checks to keep.

Do not import the lattice. Set-theoretic types with unions, intersections, conditionals and
recursion over an infinite constructor domain give an exponential solver whose majority cost is
not even solving. Our intervals plus pentagon domain is deliberately far weaker and far cheaper.

Two limits to plan around. Type recovery cannot reach the bounds check: `flvector-ref`'s
signature is `[(nonempty-flvector sub-index) -> (flonum)]`, and proving both argument types
does not prove `i < (flvector-length v)`. That fact is relational and no type predicate
expresses it, which is why Chez correctly withholds `safeongoodargs` from `flvector-ref` and
why stages 05 and 06 exist. And storage class assignment must run *after* inlining, per Leroy:
inlining either creates coercion redexes that cancel or gives the callee a more specific type,
and Hölzle and Ungar measured a 27% drop in total type tests from inlining alone, because
constants and known representations flow into callee bodies.
