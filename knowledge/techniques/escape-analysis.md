---
type: technique
title: Escape analysis
description: Proving a value does not outlive the activation that created it, which is what licenses stack allocation, closure elimination, and keeping an unboxed flonum in a register; the bundle has no dedicated source for this and the data half is assembled from closure and points-to work.
tags: [escape-analysis, stack-allocation, closure-conversion, points-to-analysis, dynamic-extent]
sources:
  - resource: /works/keep-hearn-dybvig-optimizing-closures-in-o-0-time.md
  - resource: /works/keep-a-nanopass-framework-for-commercial-compiler-developm.md
  - resource: /works/serrano-weis-bigloo-a-portable-and-optimizing-compiler-for.md
  - resource: /works/steensgaard-points-to-analysis-in-almost-linear-time-popl-.md
  - resource: /works/dybvig-three-implementation-models-for-scheme-1987.md
  - resource: /works/hieb-dybvig-bruggeman-representing-control-in-the-presence.md
  - resource: /works/steele-rabbit-a-compiler-for-scheme-1978.md
  - resource: /works/shivers-control-flow-analysis-of-higher-order-languages-19.md
  - resource: /works/burger-waddell-dybvig-register-allocation-pldi-1995.md
implemented_by: [/implementations/chez.md]
absent_from: [/implementations/sbcl.md]
pipeline_stage: 09-alias
status: draft
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

Which values can live in a frame that gets popped, rather than in a heap that must be
collected. Equivalently, and more usefully for us: which flonum can stay unboxed in an
`xmm` register for its whole lifetime, and which closure needs no heap object at all. The
predicate is "v does not outlive the activation that created it."

Common Lisp makes the programmer answer with `dynamic-extent`, unchecked. Automating it is
one of four capabilities where our plan claims to exceed SBCL. **Caveat up front: this
bundle contains no dedicated escape analysis paper.** Choi et al. (connection graphs,
OOPSLA 1999) and Blanchet (escape analysis for ML by type height, POPL 1998 / TOPLAS 2003)
are recorded gaps. What follows is closure analysis and points-to analysis pressed into
service, plus one framework for the "inevitably does X" question. The closure half is
sourced. The data half is inference and is marked as such.

# Mechanism

Three approximations at three granularities.

**1. Syntactic well-knownness, for closures.** A procedure is *known* at a call site if that
site provably invokes exactly that lambda. It is *well-known* if its value is never used
anywhere except at sites where it is known, which is to say it never escapes. A well-known
procedure's code pointer is dead, because every call jumps to a direct-call label.

The analysis is a single linear pass, and this is the cheapest real result in the bundle:
give each `letrec` lambda a fresh label, optimistically mark it well-known, and demote it on
any reference outside call-operator position. No call graph, no fixpoint. It requires
assignment conversion and letrec purification first. Measured: 56.94% of closures and
44.89% of free variables eliminated statically, 58.25% of closure allocation and 58.58% of
closure-related memory references eliminated dynamically, over 67 R6RS benchmarks.

**2. Three-valued classification from 0CFA, for procedures.** Serrano's Bigloo work. 0CFA
gives `A(f)`, the callable set at each site; invert it to `USE(f)`, the sites that can
invoke `f`. Then three nested predicates, `S ⇒ X ⇒ T`, each with a cheaper representation:

- `S(f)`: not escaping and `USE(f)` is empty, so `f` never reaches a `funcall` at all. No
  closure, no environment, every call a direct branch, free variables lambda-lifted into
  the parameter list. Proposition 2 is the practical one: **any function never passed as an
  argument and never returned satisfies S.**
- `X(f)`: not escaping and `A(g) = {f}` exactly at every use site. No closure structure,
  though an environment may remain.
- `T(f)`: a family always applied at the same places. Closure shrinks to a single
  entry-point slot, no tag, no arity field, and the call site drops the type and arity check.

Escape here is a flag on the variable, not a derived fact: `ESC` (exported or imported) and
`FOR` (foreign) poison the arguments and body to unknown immediately. That is the honest
model for separate compilation.

**3. Storage shape graph reachability, for data.** Steensgaard. Points-to analysis recast as
type inference over a non-standard type system and solved by union-find, in O(N α(N,N)) time
and O(N) space. A location escapes iff its equivalence class representative is reachable
from a global, a parameter, or a returned value. The paper says as much itself about
Table 3: variables whose type variable describes nothing else "are candidates for global
optimizations such as being represented by a register rather than a memory location." That
is storage class assignment. One pass feeds non-escape to stage 08 and non-aliasing to
stage 10.

**4. The "inevitably" framework.** Burger, Waddell and Dybvig's `St`/`Sf` split answers "does
this expression inevitably do X" on an AST, in one bottom-up linear pass. Union along a path,
intersection across paths, and the whole register set `R` for impossible paths so they impose
no constraint. That is the shape our escape predicate wants, and the `R`-for-impossible-paths
trick is the non-obvious part. **Carry the correction:** the callee-save criterion
`ret ∈ St[E] ∩ Sf[E]` is wrong as printed in the ACM proceedings; our copy has the fix in
footnote 2 on page 5.

Our predicate, defaulting to escape:

```
escapes?(v) :=  v is stored into a heap object not itself proven non-escaping
             |  v is passed to a call whose callee is not known
             |  v is returned from the procedure that created it
             |  v occurs free in a lambda that is not well-known
             |  a continuation may be captured in v's scope   ; see Preconditions
```

# Preconditions

Assignment conversion and letrec purification, or well-knownness is unsound.

**Continuation capture is the hard one, and it is where this bundle earns its keep.** Dybvig
§4.5: a box may be skipped when an assigned variable occurs free in no closure *and* no
continuation can be captured in its scope. The first is a syntactic check on free-variable
lists. The second, the dissertation says plainly, needs significant analysis, because any
call outside the variable's scope might capture a continuation. That is a k-CFA-shaped
question. Chez did not have that analysis in 1987 and mostly still relies on the syntactic
check. Any claim we make about automated escape analysis lands on this problem.

**The control representation decides what stack allocation even means.** Under Hieb, Dybvig
and Bruggeman's segmented stack, capture *seals* the current segment rather than copying it,
so objects with dynamic extent may be stack-allocated and *mutated*. That is not sound under
the naive copy model or under the Clinger-Hartheimer-Ost hybrid. So escape analysis is worth
strictly more under segmented continuations than under snapshot continuations. That is a
representation choice enabling an analysis, and it should be recorded that way.

**RABBIT's negative result has not been retracted by anything else in this bundle.** Steele,
p. 92: if a side-effecting expression is substituted past a call to an unknown function, and
that function performs a `CATCH` whose escape procedure is later invoked twice, the effect
happens twice. There is no way to decide this short of fearing every unknown call, fearing
them defeats most optimization, and RABBIT therefore ignores the problem. Every escape
analysis in a language with first-class continuations inherits that choice.

Whole-program or module-closed, for anything CFA-based. Separate compilation costs precision
directly.

# Cost

Well-knownness: one linear pass, compile time change under 1%. Effectively free.

0CFA: worst case O(n³) in functions plus call sites; iteration counts to fixpoint were at
most 5 on real programs, but the wall clock is real — 60.5s against 6.4s on `conform`, an
845% increase in Scheme-side compile time. Bigloo repays it because it emits C and better C
compiles faster.

Steensgaard: about 4x the cost of traversing the program representation; ~27 seconds on
75,000 lines of C on 1996 hardware.

k-CFA for k ≥ 1 is exponential in the worst case, and 0CFA is cubic. Shivers offers no
complexity analysis and says so; those results came later and settled it against him.

The precision cost of unification is the one that will hurt us. One `x = y` merges two
points-to sets permanently, symmetrically, everywhere. `(let ([v (if p a b)]) ...)` merges
`a` and `b` for the whole program. In a numeric kernel where arrays flow through a shared
helper, that is the common case, not the rare one. The direction of error is safe (merging
loses distinctness claims, never invents them) but it degrades fast.

**The calibration number.** Keep's full closure optimization, all six free-variable
eliminations plus representation selection plus sharing plus borrowing, moves benchmark run
time by an average of **3.6%**, range negligible to 20%, with a few benchmarks getting
*slower* from cache effects. Eliminating 58% of closure allocation buys 3.6% wall clock,
because Chez's inline allocation is already about three instructions plus a store per field.
Size any escape-analysis proposal against that ratio before building it.

# Disagreements

**Is flow analysis worth it for escape?** Serrano says yes: 0CFA pays because it enables a
specific representation choice nobody had named before, and he rejects 1CFA outright ("what
can be done with this information in a compiler? We have found no answers"). Keep, Hearn and
Dybvig get their entire result from a linear syntactic pass with no CFA at all, and their
numbers are in the same range as Serrano's. Serrano's dismissal of 1CFA has aged badly for
exactly our case: polyvariant CFA is how you get type specialization, which is what unboxing
wants.

**Escape at what granularity?** Prior closure analyses (Kranz's ORBIT, Séniak's SQIL)
partition procedures into allocates and does-not-allocate. Serrano argues that partition is
exactly the weakest of his three predicates and that the two stronger classes admit strictly
cheaper representations the binary analysis throws away. The subsumption claim is stated, not
proved, and rests on reading their algorithms as computing exactly `S`.

**Manual versus automatic.** No source in this bundle argues for the manual `dynamic-extent`
form. Equally, no source in this bundle demonstrates a sound automatic escape analysis for
*data* as opposed to closures. The gap runs in both directions and we should not pretend
otherwise.

**The source gap, stated plainly.** This technique needs a source we do not hold. Everything
above about data escape is extrapolated from Steensgaard's points-to graph and from
Steensgaard's own aside about register candidacy. That is a legitimate reading of the paper
and it is not what the paper is about. Before we commit stage 09 to a design, fetch Choi et
al. 1999 and Blanchet's TOPLAS 2003. Blanchet in particular is the one aimed at a functional
language with closures, which is our shape.

# For us

Stage `09-alias` produces the fact; stage `08-represent` consumes it. **The CUJ orders 08
before 09, and that is backwards.** Stage 08's table keys on "proven flonum, does not
escape", which stage 09 is the thing that proves. Either 09 moves ahead of 08, or 08 runs
twice, or the escape half of 08's table is dead on arrival. Steensgaard's work document
reaches the same conclusion from the other side.

Build order, cheapest first:

1. Well-knownness. Linear, ~free, and it is what decides whether a closure exists at all.
   Keep's per-optimization breakdown says self-reference elimination alone accounts for
   25.41% of free variables and 45.64% of eliminated memory references, and mutual-reference
   elimination another 7.91%/32.55% — the two simplest transformations carry most of it.
   Sharing and borrowing together are 2.11% and can be skipped.
2. Serrano's `S` predicate, which needs only "never passed as an argument, never returned"
   and covers most functions in most programs.
3. Steensgaard's union-find core for data. Maybe 150 lines as a nanopass stage: fresh ECR
   per `make-flvector` site, join on assignment/argument/return, escape iff reachable from a
   global, a parameter or a return. The `pending`-set conditional join is what makes one
   pass suffice, with no fixpoint and no worklist.

Do not reach for k-CFA. If unification proves too coarse, the escape hatch is context
sensitivity (polymorphic inference), not Andersen's inclusion-based analysis — our precision
problem will be about context, not about inclusion versus unification.

And hold the honest position on the SBCL comparison. Automating `dynamic-extent` is a real
capability gap, but the bundle does not contain the paper that shows how to close it for
data, and Keep's 3.6% is the calibration for the closure half. The flonum half is the part
that could actually matter on `nbody`, and no source here measures it.
