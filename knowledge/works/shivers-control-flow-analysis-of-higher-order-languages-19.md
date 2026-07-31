---
type: paper
title: "Control-Flow Analysis of Higher-Order Languages, or Taming Lambda"
description: Recovers a compile-time control-flow graph for Scheme by abstract interpretation of a CPS intermediate representation, collapsing the infinite set of binding contours to a finite one, and shows the resulting call graph enables classical dataflow optimizations plus a reflow extension that solves the environment problem.
resource: knowledge/sources/shivers-control-flow-analysis-of-higher-order-languages-19.pdf
tags: [control-flow-analysis, abstract-interpretation, continuation-passing-style, type-recovery, reflow-analysis]
authors: [Olin Shivers]
year: 1991
venue: "PhD dissertation, Carnegie Mellon University, CMU-CS-91-145"
informs: [/techniques/control-flow-analysis.md, /techniques/type-recovery.md, /techniques/escape-analysis.md, /techniques/procedure-inlining.md, /techniques/dataflow-analysis.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Breaks the circularity that had kept dataflow analysis out of higher-order language compilers:
you need a control-flow graph to do flow analysis, and in Scheme finding the control-flow graph
*is* a flow analysis. The escape is abstract interpretation. Define an exact, uncomputable
semantics that instruments the interpreter to record every call, then abstract it by making one
thing finite (the set of binding contours) and everything else follows.

Three parts, in descending order of how well they held up. First, the analysis itself, with
proofs that it exists, safely approximates the exact semantics, and is computable, plus
algorithms with proofs that the algorithms compute the function. Second, applications:
induction-variable elimination, useless-variable elimination, constant propagation, type
recovery, copy propagation, lambda propagation. Third, *reflow analysis*, an extension for the
"environment problem", which the author flags as unproven research frontier rather than
established result.

The framing claim is the one worth arguing with: that Scheme and ML compilers are slower than
C and Fortran compilers chiefly because they lack the optimizations that need a flow graph.

# Mechanism

Intermediate representation is CPS Scheme, five syntactic classes: lambdas, variables,
constants, primops, calls (plus `letrec`). Every transfer of control (sequencing, looping, call,
return, conditional) is a tail-recursive call. No `set!` (assignment conversion moves variable
mutation into heap cells). No `call/cc` operator (it expands to
`(lambda (f k) (f (lambda (v k') (k v)) k))`). Primops are not first class. Conditionals are
primops taking a boolean and two continuations. Programs are alphatised, closed, and have
syntactically correct primop arity. Every expression carries a unique label.

The environment is *factored*, and this is the design decision that makes the whole thing work:

    CN                                  contours
    BEnv = LAB -> CN                    contour environment, lexical
    VEnv = (VAR x CN) -> D              variable environment, global
    Clo  = LAM x BEnv                   a closure is a lambda plus a contour environment

A contour is allocated on each lambda entry; a variable binding is a `(var, contour)` pair.
Factoring exposes exactly one infinite structure (the contour set) to abstraction. This is
Johnston's contour model.

Exact control-flow semantics instruments the standard semantics to build a *call cache*

    CCache = (LAB x BEnv) -> Proc

recording, for each call site in each contour environment, which procedure was invoked. Primops
need *internal call sites*: `(+ a b (lambda (s) ...))` calls its continuation from inside `+`,
with no syntactic call site, so each primop occurrence gets `ic` labels (one for simple primops,
two for conditionals). Each primop entry allocates a fresh contour even though it binds no
variables, so repeated passes through it stay distinct in the cache.

Abstraction, three changes. Make `CN-hat` finite. Branch both ways at conditionals and join the
result caches. Drop basic values entirely, since only procedures matter for control flow, so
`D-hat = P(Proc-hat)` and every expression evaluates to a *set*. Cache updates become joins
rather than overwrites, which is what keeps the result conservative.

0CFA takes `CN-hat = {1}`. Everything degenerates: contour environments vanish, closures collapse
to lambdas, `CCache = LAB -> D-hat`, `VEnv = VAR -> D-hat`. Fast, and it answers "which lambdas
are called from which call sites" directly, but it merges call contexts, admitting spurious paths
where a call at `c1` returns to the continuation of `c2`.

1CFA takes `CN-hat = CALL`: the contour allocated on entering a lambda is the call site it was
entered from. Exact contours become *call strings*, and the abstraction function takes the last
element. Values arriving from different call sites stay distinct. The generalizations are noted
but not explored: `CN-hat = LAB x LAB` for the last two calls extends 1CFA along the control
dimension, and pairing "the call I came from" with "the call that entered my lexically superior
lambda" extends it along the environment dimension.

Extensions in Section 3.8. Side effects via `new`/`set`/`contents` cells, with the crudest useful
store abstraction: all addresses merged into one, so the abstract store is just the set of
procedures ever stored. External procedures and calls, `xproc` and `xcall`, plus an `ESCAPED`
set, under three rules (anything passed to `xproc` escapes; anything escaped can be called from
`xcall`; anything called from `xcall` can receive any escaped procedure). Under the single-address
store abstraction, `ESCAPED` and the abstract store are the same set. And the
user-procedure/continuation partition: the CPS converter knows which lambdas, variables and call
sites it introduced, and a call site calls only user procedures or only continuations, never both.
That partition is a large precision win for free.

Chapter 4 fixes the equations for proof: `nb : CN -> LAB -> CN` is an increasing gensym carrying
the current call label, so contour allocation commutes with abstraction (`|nb b x| = nb-hat |b| |x|`);
`CState` and `FState` are restricted to *consistent* argument tuples so the semantic functions are
total; the call cache is defined as a relation and then shown to be a partial function. The results:
`H` is continuous so `C` and `F` exist as its least fixed point; the abstract functions conservatively
approximate the exact ones (`f-hat |x| >= |f x|`); and computability follows from the finiteness of
`CN-hat`.

The computability argument gives the algorithm. Both `C-hat` and `F-hat` have the shape

    f x = g x  join  (join over f(R x))

for a local contribution `g` and a recursion set `R`, over a finite domain. The least solution is
`f x = join over i of g(R^i {x})`, computed by depth-first search with a visited set:

    f(x) = S := {}; ans := bottom
           loop(y) = if y not in S then
                       ans := ans join g(y); S := S union {y}
                       for each z in R(y): loop(z)
           loop(x); ans

Two optimizations, both proved correct in Chapter 6. *Aggressive cutoff*: since `C-hat` and `F-hat`
are monotone, replace `y not in S` with `not (y <= z for some z in S)`, which subsumes the basic
test. *Time stamps*: keep the variable environment and store in globals, never restore them across
recursive calls, and let them only grow. Then the sequence of environment values is totally
ordered, so they can be memoized by an integer counter rather than stored. The memo table becomes
`<call, benv> -> (venv-ts, store-ts)`, one entry per call context. This is the version implemented.

Applications, Chapter 7. Induction-variable elimination generalizes from a single C variable to a
*basic induction variable family*: a set of Scheme variables `{j, j', j''}` playing the role of one
C loop counter, since Scheme steps loop variables by rebinding in a tail call rather than by
assignment. Membership conditions are checkable directly off the call cache. Dependent families
are then found, new variables `z_i` are threaded through the lambdas to carry the affine value,
the dependent computation is replaced by a binding, and the result frequently makes the original
counter useless, which UVE then removes. Figure 7.1's five-stage worked example was produced by a
working implementation over 0CFA.

Useless-variable elimination is a backwards mark-and-sweep. A variable is useful if it is the
operand of a call, the predicate of a conditional primop, a continuation, an argument to a
side-effecting or external operation, or the argument to a primop or lambda whose corresponding
result or parameter is useful. The removal phase has a circular constraint (delete a parameter
only if you can delete the argument at every call that reaches the lambda, and vice versa) solved
by iterating two sets `RV` and `RA` to a fixed point, with `xcall`/`xlam` counting as disqualifying.
Constant propagation is one line of change: let the value sets carry constants as well as
procedures.

Chapter 8, the environment problem, is the honest part. In

    (let ((f (lambda (x h) (if (zero? x) (h) (lambda () x)))))
      (f 0 (f 3 '#f)))

the two calls to `f` may map to the same abstract contour. Testing `x = 0` on one binding and then
referencing `x` through `h`, which closes over the *other* binding, yields 3. The rule is precise:
an analysis is safe under contour merging only if it moves through its lattice in the direction of
increasing approximation. Control-flow analysis and UVE do. Type recovery does not, because a
conditional test *narrows* a type, and narrowing is invalid on a merged contour. Reflow analysis
restarts the abstract interpretation from a given call context, allocating one *special* contour
that will never be identified with any past or future binding, and tracks only that contour's
variables. The starting environment is the final `venv` and store from a time-stamped CFA, which
over-approximates every intermediate state. Repeat once per call context in the domain of the call
cache.

Chapter 9 builds type recovery on top. It is a *quantity-based* analysis: types attach to qnames
(named by the first variable binding a value reaches), variables bind to qnames, and a type table
maps qnames to types. The answer is a *type cache* `(REF x CN) -> Type`, so types belong to
variable *references*, not variables, which is the whole point in a latently typed language.
Information comes from conditional branches, from primops (`(car p)` implies `p` is a pair
afterwards, because `car` is really `(if (pair? p) (cont (%car p)) ($))`), and from user
declarations, where `enforce` is a checked test and `proclaim` is `(if (pred val) val ($))` with an
undefined-effect arm the compiler may elide. `delq` and iterative `fact` are typed completely.

Chapter 10 unifies constant, copy and lambda propagation as "super-beta": substituting known
expressions for the variables bound to them. Copy propagation needs reflow because the right
binding must be in scope. Lambda propagation needs *environment consonance*, and the useful
observation is that consonance with the lambda's *innermost* free variable implies consonance with
the rest, so only one contour needs tracking. Combinators are consonant everywhere.

# Applicability

Preconditions. CPS with assignment conversion already done, alphatised and closed, and primops
non-first-class with statically checked arity. Whole-program, or the `xproc`/`xcall` machinery,
which yields very weak information (the author says as much and notes that known primitives like
`print` and `length` deserve better summaries).

Costs, as reported. 1CFA in interpreted T on a DECstation 3100: iterative factorial 0.58s, the
puzzle 0.67s, `delq` 1.8s. Type recovery on the same three: 7.8s, 5.1s, 5.3s, roughly an order of
magnitude more because reflow re-runs the interpretation once per call context. The implementation
is 450 lines of 1CFA over a 2100-line modified ORBIT front end, has been applied "to at most a few
hundred lines of code," and was never connected to a code generator, so no optimized program was
ever timed.

There is no complexity analysis. Section 11.1 says so explicitly and defers it on the grounds that
complexity depends on the choice of abstraction. The empirical argument for scalability is "I have
no reason to believe the analyses will not scale reasonably," followed by the fallback that
optimization can be switched off during development. Subsequent work settled this against him:
k-CFA for k >= 1 is exponential in the worst case, and 0CFA is cubic, results that were not known
in 1991.

Precision limits the author identifies himself. The store abstraction is a single address, so one
procedure stored anywhere can be fetched from anywhere. `if` branches both ways unconditionally,
so no control-flow arc is ever pruned by a type or value fact (Appendix B shows exactly such a
prunable arc surviving in the puzzle's call cache). Bignums defeat fixnum recovery entirely,
because two's complement fixnums are not closed under addition, subtraction, multiplication, or
even negation and division, so integer arithmetic cannot be inferred to be machine arithmetic no
matter how good the type recovery is.

# Relevance

This is the ancestor of higher-order flow analysis and the thing our declaration-anchored
inference has to beat, so it is worth being exact about the axis on which it must be beaten. It is
not precision. On precision, k-CFA with a good store abstraction wins, and it will keep winning as
k rises. It is *predictability*.

The cost of k-CFA is a function of the closure structure of the program, and no part of that
function is visible to the person writing the program. Two source files that look equally
straightforward can differ by orders of magnitude in analysis time because one of them passes a
closure through a data structure. Shivers has no bound to offer, and the bound found later is
exponential. A compiler whose optimization budget is unpredictable in that way is one whose users
learn to distrust it, and Section 11.1's answer, compile without optimization during development
and once with it at release, concedes the point. Declaration-anchored inference has the opposite
property: the analysis cost scales with what the programmer wrote down, and when the compiler
cannot prove something, the fix is a declaration the programmer can see and write. That is the
comparison to make in our benchmarks, and it should be reported as time-to-analyze variance
across inputs, not just as precision on a fixed suite.

The second lesson is the environment problem, and it is the deepest technical content here.
Contour merging is sound only for analyses that move monotonically toward approximation. Every
*narrowing* analysis, meaning every analysis that learns something from a conditional test, is
unsound on merged contours and needs something like reflow to recover. Our numeric domains
narrow constantly: `05-intervals` learns `x < n` from a branch, and `06-pentagon` learns `x < y`.
If we ever merge contexts (inlining the same procedure into two call sites and then analyzing the
merged body, for instance), we inherit exactly this bug. The mitigation in a
declaration-anchored design is that types are pinned at binding sites rather than narrowed
across merged environments, but the interval and pentagon facts are not, and that is where to
look for the unsoundness.

Concrete things to lift. The `xproc`/`xcall`/`ESCAPED` construction is the right skeleton for
separate compilation and for `09-alias`, and the observation that known library procedures deserve
hand-written summaries rather than worst-case treatment is a cheap, large win. The
user-procedure/continuation partition arrives free in ANF, where a tail call and a `let`-bound call
are syntactically distinct. Section 11.3.4's basic-block collapsing, treating a chain of lambdas
where each one is a non-conditional primop's continuation as a single analysis node, is the single
highest-leverage speedup he proposes and it maps directly onto ANF straight-line code. Section
11.3.5's identification of closures whose contour environments differ only on irrelevant lambdas
is the same idea applied to the value domain.

Chapter 9's bignum discussion is the strongest argument in this dissertation for our numeric
pipeline. Type recovery can prove that every arithmetic operation in `fact` is an integer
operation and still not let the compiler emit an `add`, because integer does not mean fixnum. Only
range analysis closes that gap, and `strindex` is his worked example: `string-length` gives a
fixnum, and range analysis on `i` between 0 and that fixnum gives a fixnum index *and* eliminates
the bounds check. That is `05-intervals` doing two jobs at once, and it is why intervals, not
type inference, are the load-bearing analysis for our numeric benchmarks.

Two more items to file. Section 9.6.3's test hoisting, moving a type check earlier or out of a
loop when it is guaranteed to be reached, is a very-busy-expressions problem he leaves open, and
it is the right way to get vector type checks out of the `dot-prod` inner loop before `10-vectorize`
sees it. Section 11.2.1's representation analysis names the boxed-flonum problem precisely
(two loads, an add, a heap allocation and a store where one instruction should do) and that is
what `08-represent` exists to fix.

# Notes

Title verified against the title page: "Control-Flow Analysis of Higher-Order Languages, or Taming
Lambda", Olin Shivers, May 1991, CMU-CS-91-145, School of Computer Science, Carnegie Mellon
University. The bibliography entry ("k-CFA. The foundation of higher-order flow analysis") is
right about the year, author and significance, and the "and Taming Lambda" subtitle is omitted
there but is on the document.

Bibliography nuance rather than error: **the term "k-CFA" does not appear in this dissertation.**
Shivers defines 0CFA and 1CFA, sketches two different 2CFA variants (one extending along the
control dimension, one along the environment dimension), and says explicitly that "0CFA and 1CFA
are not intended to be the last word on this subject". The `k` generalization and the name came
later. If a synthesis document above `works/` says "Shivers' k-CFA", that is the field's shorthand,
not this document's terminology.

The extraction is poor. Chapters 4 and 6 are mathematical and the PDF's font encoding renders
Greek letters, hats, joins and lattice operators as `/#xx` escapes, so every formula quoted in
this document was reconstructed from surrounding prose. The prose is unambiguous; the figures are
not machine-readable.

Where it is oversold. The abstract's premise, that the C-versus-Scheme performance gap is chiefly
attributable to the missing flow-analysis optimizations, is asserted, never measured, and is the
motivating claim of the entire dissertation. Chapter 9's own citation of Steenkiste bounds one
piece of the payoff at 25 percent (that being the total cost of full run-time type checking in a
PSL Lisp on MIPS-X, so an *upper* bound on what type recovery can recover), and Shivers is careful
about how much weight that number can carry. Nothing in the dissertation measures the speedup from
any of the six optimizations it develops, because the implementation was never connected to a back
end. The title's claim, "control-flow analysis is feasible and useful for higher-order languages",
is established for feasibility by construction and proof, and for usefulness by three worked
examples of under twenty lines each.

Where it is admirably honest, and this is rarer. Chapter 8's opening states outright that reflow
analysis is unproven and should be taken "simply as interesting ideas that have not yet been
backed up with rigorous mathematics". Section 11.4 calls the implementation "very much a toy
implementation". Section 11.1 concedes that the NSAS manifesto (unifying semantics and compiler
optimization) is not delivered here any more than it was in Pleban's dissertation. Compare the
LLVM paper's five-capability scorecard for the opposite rhetorical style.

Two smaller things. The 1CFA-versus-0CFA precision argument is made entirely by constructed
example (the spurious `c1 -> l3 -> c3 -> k2` return path), never by measurement, and later work
found that k >= 1 buys much less on real code than the example suggests. And Appendix A opens with
two quoted flames from netnews about the author's code being "horrid", included on purpose, which
tells you something useful about how much polish the implementation had.
