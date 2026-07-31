---
type: technique
title: Control-flow analysis for higher-order languages
description: Recovers which lambdas a call site can invoke by abstract interpretation over a finite set of binding contours, giving 0CFA and its context-sensitive refinements, plus the cheaper monovariant answers a compiler can usually afford instead.
tags: [control-flow-analysis, abstract-interpretation, closure-conversion, escape-analysis, polyvariance]
sources:
  - resource: /works/shivers-control-flow-analysis-of-higher-order-languages-19.md
  - resource: /works/serrano-weis-bigloo-a-portable-and-optimizing-compiler-for.md
  - resource: /works/steensgaard-points-to-analysis-in-almost-linear-time-popl-.md
  - resource: /works/waddell-dybvig-fast-and-effective-procedure-inlining-sas-1.md
  - resource: /works/keep-hearn-dybvig-optimizing-closures-in-o-0-time.md
  - resource: /works/steele-rabbit-a-compiler-for-scheme-1978.md
  - resource: /works/dybvig-et-al-the-development-of-chez-scheme-icfp-2006.md
  - resource: /works/cousot-cousot-abstract-interpretation-popl-1977.md
implemented_by: [/implementations/bigloo.md]
absent_from: [/implementations/chez.md]
pipeline_stage: 09-alias
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

Which lambdas can this call site invoke. Without the answer there is no direct call, no
representation choice for a closure, no inlining decision that is not a guess, and no dataflow
analysis at all, because in Scheme finding the control-flow graph *is* a flow analysis. Shivers'
contribution is the escape from that circularity.

# Mechanism

**The abstraction.** Take the standard semantics, instrument it to record every call in a *call
cache* `CCache = (LAB x BEnv) -> Proc`, then make exactly one thing finite. The environment is
*factored*, which is the decision that makes it work:

```
CN                                contours
BEnv = LAB -> CN                  contour environment, lexical
VEnv = (VAR x CN) -> D            variable environment, global
Clo  = LAM x BEnv                 closure is a lambda plus a contour environment
```

A contour is allocated on each lambda entry; a binding is a `(var, contour)` pair. Factoring
exposes one infinite structure, the contour set, to abstraction. Three changes then give the
abstract semantics: make the contour set finite, branch both ways at conditionals and join the
result caches, and drop basic values entirely since only procedures matter for control flow, so
every expression evaluates to a *set* and cache updates become joins rather than overwrites.

**0CFA** takes one contour. Everything degenerates: contour environments vanish, closures
collapse to lambdas, `CCache = LAB -> D-hat`, `VEnv = VAR -> D-hat`. It answers the question
directly and merges call contexts, admitting spurious paths where a call at one site returns to
another site's continuation.

**1CFA** takes the contour to be the call site the lambda was entered from. Exact contours become
call strings and the abstraction takes the last element, so values arriving from different call
sites stay distinct.

**The algorithm.** Both abstract functions have the shape `f x = g x join (join over f(R x))`
for a local contribution `g` and a recursion set `R`, over a finite domain. The least solution
is computed by depth-first search with a visited set:

```
f(x) = S := {}; ans := bottom
       loop(y) = if y not in S then
                   ans := ans join g(y); S := S union {y}
                   for each z in R(y): loop(z)
       loop(x); ans
```

Two optimizations, both proved correct. *Aggressive cutoff*: by monotonicity, replace
`y not in S` with `not (y <= z for some z in S)`, which subsumes the basic test. *Time stamps*:
keep the variable environment and store in globals, never restore them across recursive calls,
and let them only grow; the sequence of values is then totally ordered and can be memoized by an
integer counter, so the memo table is `<call, benv> -> (venv-ts, store-ts)`, one entry per call
context. That is the version Shivers implemented.

**Extensions worth the space.** Side effects through `new`/`set`/`contents` cells with the
crudest useful store abstraction, all addresses merged into one, under which the escaped-procedure
set and the abstract store are literally the same set. External procedures and calls, `xproc` and
`xcall`, with three rules: anything passed to `xproc` escapes, anything escaped can be called from
`xcall`, anything called from `xcall` can receive any escaped procedure. And the
user-procedure/continuation partition, which is a large precision win for free and arrives free in
ANF where a tail call and a let-bound call are syntactically distinct.

**Serrano's direct-style version is the one that shipped.** Bigloo's IR has no `lambda`:
`(lambda (x) e)` is `(labels ((id (x) e)) (function id))`, syntactically separating code from
first-class reference to code. Abstract values are subsets of `{T, bottom} union FunId`, the only
operation is `add-app!` joining a value into a variable's approximation, and variables carry four
locality flags (`LOC`/`GLO` for variables, `FOR`/`ESC` for functions). Self-recursion is cut with
a stamp. Worst case is cubic in functions plus call sites; measured iteration counts to fixpoint
were at most five on real programs. Invert the call graph to get `USE(f)`, the set of sites that
can invoke `f`, and three nested predicates fall out with `S implies X implies T`:

- `T(f)`: not escaping, and at every site in `USE(f)` every other member of the approximation set
  is a function satisfying `T`. A *family*, always applied at the same places.
- `X(f)`: not escaping, and at every site in `USE(f)` the approximation is exactly `{f}`.
- `S(f)`: not escaping, and `USE(f)` is empty. `f` never reaches a computed call at all.

Baseline procedure representation is at least four words: tag, arity, and two entry points, because
every computed call must check applicability and arity. `S` gives no closure and no environment:
direct branch, free variables lambda-lifted into the parameter list. Proposition 2 is the
practically useful one, that any function never passed as an argument and never returned satisfies
`S`. `X` gives no closure structure, though an environment may remain. `T` shrinks the closure to a
single entry-point slot with no tag, no arity field and no variable-arity entry, because the family
is known statically, so the call site becomes a computed application with no checks.

**The cheap answers, and both are usually enough.** Keep, Hearn and Dybvig compute *well-knownness*
during closure conversion in a single linear pass: fresh label per letrec lambda, optimistically
mark well-known, demote on any reference outside call-operator position. A well-known procedure's
code pointer is dead. That is Serrano's `X` without a fixpoint. Steele's RABBIT is cheaper still, a
`KNOWN-FUNCTION` property set during binding analysis and consumed at code generation as an
environment adjustment followed by a `GO`. And Steensgaard's points-to analysis produces
0CFA-strength call-target information as a side effect in almost linear time, because his `lam`
types make "which closures can this call site invoke" and "what does this variable point to" the
same question.

# Preconditions

Shivers requires CPS with assignment conversion already done, alphatised and closed programs, and
primitives that are not first class with statically checked arity. Serrano requires none of that
and argues the direct-style choice is why 0CFA suffices for him: with CPS, control is artificially
dynamic and CFA is mandatory just to recover what direct style never lost. Our IR should not create
work for our analyses.

Whole-program, or the escape machinery, which yields very weak information. Shivers notes that
known primitives like `print` and `length` deserve hand-written summaries rather than worst-case
treatment, which is a cheap and large win. In Bigloo anything exported, imported or foreign poisons
its arguments and body immediately, and global variables read as unknown unconditionally, so
separate compilation directly costs precision.

Any analysis built on top that *narrows* is unsound on merged contours. That is the environment
problem, and the rule is precise: contour merging is safe only for analyses that move monotonically
toward approximation. Control-flow analysis and useless-variable elimination do. Type recovery does
not, because a conditional test narrows a type. Reflow analysis recovers it by restarting the
interpretation from a given call context with one *special* contour that is never identified with
any other binding, once per call context in the domain of the call cache.

# Cost

There is no complexity analysis in the dissertation. Section 11.1 says so explicitly and defers it
on the grounds that complexity depends on the choice of abstraction; the empirical argument for
scalability is "I have no reason to believe the analyses will not scale reasonably," with the
fallback that optimization can be switched off during development. Subsequent work settled it
against him: 0CFA is cubic and k >= 1 is exponential in the worst case, results not known in 1991.

Measured numbers, such as they are. 1CFA in interpreted T on a DECstation 3100: iterative factorial
0.58s, the puzzle 0.67s, `delq` 1.8s. Type recovery on the same three: 7.8s, 5.1s, 5.3s. The
implementation is 450 lines over a 2100-line modified ORBIT front end, was applied "to at most a few
hundred lines of code," and was never connected to a code generator, so no optimized program was
ever timed. Bigloo's 0CFA on `conform` is 60.5s against 6.4s without, an 845% increase in
Scheme-side compile time, repaid only because Bigloo emits C and the C compiler is the bottleneck;
its own 30,000-line bootstrap goes from 45 to 55 minutes. Serrano reports 87 to 95% of closure
allocations removed and roughly 70% run-time improvement against a baseline with no closure
optimization at all, so that number does not transfer to a Chez-class baseline.

Precision limits the authors identify themselves: the single-address store abstraction means one
procedure stored anywhere can be fetched from anywhere, and `if` branches both ways
unconditionally, so no control-flow arc is ever pruned by a type or value fact.

# Disagreements

**"k-CFA" is the field's later shorthand, not Shivers' term, and it should not be attributed to
him.** The dissertation defines 0CFA and 1CFA, sketches two *incompatible* 2CFA variants (one
extending along the control dimension by pairing the last two calls, one along the environment
dimension by pairing the entering call with the call that entered the lexically superior lambda),
and says explicitly that "0CFA and 1CFA are not intended to be the last word on this subject." The
`k` generalization and the name came later. Do not write "Shivers' k-CFA."

**Is polyvariance worth anything.** Shivers argues 1CFA's advantage over 0CFA entirely by
constructed example (a spurious return path), never by measurement, and later work found k >= 1
buys much less on real code than the example suggests. Serrano tried 1CFA and rejected it outright:
"what can be done with this information in a compiler? We have found no answers." That dismissal
aged badly, since polyvariant CFA is how you get type specialization and therefore unboxing, which
is exactly our use, but it was defensible in 1995 given that 0CFA alone was already cubic.

**Whether a compiler should do this at all.** Chez's answer is no, and it has evidence. Jagannathan
and Wright's flow-directed inlining ran as a prepass and got results too good to ignore at
impractical analysis cost; Ashley reimplemented it faster, still impractical, and exhausted 128 MB
of core plus 100 MB of swap on `interpret`. Waddell and Dybvig's online inliner optimizes whole
programs in under a second and beats both. Ashley's own finding is the sharper argument: inlining
invalidates the flow information that justified it, so the analysis has to be re-run afterward.
Dybvig's compile-time payback rule (an optimization must make the compiler compiling itself faster
by more than it costs) excludes CFA structurally, not accidentally.

**The framing claim is unmeasured.** Shivers' abstract asserts that Scheme and ML compilers are
slower than C and Fortran compilers chiefly because they lack the optimizations that need a flow
graph. Nothing in the dissertation measures the speedup from any of the six optimizations it
develops. His own citation of Steenkiste bounds one piece of the payoff at 25%, that being the
total cost of full run-time type checking in a PSL Lisp on MIPS-X and therefore an *upper* bound
on what type recovery can recover.

**Precision is not the axis on which this loses.** On precision, context-sensitive CFA with a good
store abstraction wins and will keep winning as k rises. It loses on *predictability*: the cost is
a function of the closure structure of the program, no part of which is visible to the person
writing it, and two source files that look equally straightforward can differ by orders of
magnitude because one passes a closure through a data structure. Section 11.1's answer, compile
without optimization during development, concedes the point.

# For us

We have no CFA stage and should not add one. The call-target information we need arrives from two
cheaper places: Steensgaard's unification-based analysis at stage 09, which gives 0CFA-strength
results in almost linear time with no precomputed call graph, and well-knownness computed during
closure conversion, which is Serrano's `X` for free.

What to lift concretely. Serrano's `S` predicate covers most functions in most programs and is
nearly free once a call graph exists; the `T`-family case is the one with the numeric payoff, since
dropping the arity and tag words and the applicability check at the call is exactly what stands
between us and a tight inner loop. Shivers' `xproc`/`xcall`/escaped-set construction is the right
skeleton for separate compilation and for stage 09, and hand-written summaries for known library
procedures are a cheap large win. Section 11.3.4's basic-block collapsing, treating a chain of
lambdas where each is a non-conditional primitive's continuation as one analysis node, maps
directly onto ANF straight-line code and is the highest-leverage speedup he proposes.

The environment problem is the deepest thing here and it is a live hazard for us. Our numeric
domains narrow constantly: stage 05 learns `x < n` from a branch and stage 06 learns `x < y`. Types
in our design are pinned at binding sites by declarations rather than narrowed across merged
environments, which is the mitigation, but the interval and pentagon facts are not pinned. If we
ever merge contexts, for instance by inlining one procedure into two call sites and analyzing the
merged body, that is where to look for unsoundness.
