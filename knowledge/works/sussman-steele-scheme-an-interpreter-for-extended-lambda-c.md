---
type: paper
title: "SCHEME: An Interpreter for Extended Lambda Calculus"
description: The origin of Scheme, arguing that an actor is a closure, that lexical closure bounds environment depth by lexical depth rather than recursion depth, and that a control frame is only needed when a value must come back.
resource: knowledge/sources/sussman-steele-scheme-an-interpreter-for-extended-lambda-c.pdf
tags: [scheme, lambda-calculus, closures, continuations, tail-calls, interpreter-design]
authors: [Gerald Jay Sussman, Guy Lewis Steele Jr.]
year: 1975
venue: "MIT AI Memo No. 349, December 1975"
informs: [/techniques/closure-conversion.md, /techniques/stack-segment-continuations.md, /techniques/tail-call-optimization.md, /techniques/storage-class-assignment.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Two people set out to understand Hewitt's actors by building an interpreter that mixed
actors and lambda expressions, and discovered the two were the same object. The
acknowledgements say it plainly: "When it was completed, we discovered that the 'actors'
and the lambda expressions were identical in implementation." Section 4 states the
identity as a claim: an actor's *script* is the lambda expression and its set of
*acquaintances* is the environment, so an actor other than a cell or serializer is exactly
a closure. The message-dispatch style survives as an ordinary `LAMBDA` doing `EQ` tests on
its argument.

The real payload, though, is a set of implementation facts that fall out of taking full
lexical closure seriously. Three of them are load-bearing for everything downstream. An
environment is never deeper than the lexical depth of the expression being evaluated, even
under recursion. A control frame is needed only when a value must come back, so applying a
lambda needs none. And a recursive versus iterative program can be distinguished formally
by whether its substitution-semantics reduction sequence grows with the input or cycles
through expressions of bounded size. Those three together are proper tail calls, lexical
addressing, and first-class continuations, described in 1975 without any of those names.

# Mechanism

The interpreter (Section 5) is written in MacLISP as an explicit register machine, on the
rule "think machine language: we must not use recursion in the implementation language to
implement recursion in the language being interpreted." Registers are free LISP variables:
`**EXP**`, `**ENV**`, `**CLINK**`, `**PC**`, `**VAL**`, `**UNEVLIS**`, `**EVLIS**`,
`**TEM**`, plus `**QUEUE**`, `**TICK**`, `**PROCESS**`, `**QUANTUM**` for the scheduler.
`MLOOP` is the dispatch: check `**TICK**`, call `SCHEDULE` if a quantum expired, else
`FASTCALL` the instruction named by `**PC**`. Every "instruction" is a `DEFUN` that sets
registers and falls back to `MLOOP`. There is no host-stack recursion anywhere in the
evaluator.

Environments are virtual substitutions. Rather than reducing `((LAMBDA vars body) args)`
by copying, reduce `body` in `E' = pairlis[vars, args*, E]`. A closure is written
`(BETA (LAMBDA vars body) env)`. Evaluating a lambda in `E` yields `(BETA ... E)`;
applying `(BETA (LAMBDA vars body) E1)` to args in `E2` evaluates the args in `E2` and the
body in `pairlis[vars, args-values, E1]`. `pairlis` is McCarthy's, an alist of `(var val)`
pairs consed on the front, so a binding is a mutable value cell and `ASET` is
`(RPLACA (CDR (ASSQ var **ENV**)) val)`.

The frame discipline is the part worth copying. `SAVEUP` conses
`(**EXP** **UNEVLIS** **ENV** **EVLIS** retag **CLINK**)` onto the `**CLINK**` chain;
`RESTORE` destructures it back. `**VAL**` is deliberately *not* saved, which is what lets a
value survive frame restoration. A frame is built only when "further computation would
result in losing information which might be necessary," which is only when a value must be
obtained to continue in the current state. Applying a lambda expression is not such a case,
so no frame is created. Hence the iterative and continuation-passing styles create no net
frames, while traditional recursion creates one per level because the recursive call sits
as a subexpression of an enclosing combination.

`AEVAL` dispatches on the expression: numbers and primops self-evaluate into `**VAL**` and
`RESTORE`; identifiers `ASSQ` in `**ENV**` and fall back to the LISP value cell; `LAMBDA`
becomes `(BETA exp env)`; an AINT (the FSUBR analogue, found by `GET` of an `AINT` property)
sets `**PC**` to its handler; an AMACRO rewrites `**EXP**` and re-dispatches; anything else
sets up `**EVLIS**`/`**UNEVLIS**` and goes to `EVLIS`. `EVLIS` walks the argument list,
`SAVEUP`ing `EVLIS1` before each subevaluation; `EVLIS1` conses `**VAL**` onto `**EVLIS**`,
pops `**UNEVLIS**`, and returns to `EVLIS`. When the list is empty it `REVERSE`s and applies:
an atom via LISP `APPLY`, a `BETA` by `pairlis` and jump to `AEVAL`, a `DELTA` by installing
its saved `**CLINK**` and `RESTORE`ing. The paper points out that `REVERSE` and not
`NREVERSE` is required, because `CATCH` can re-enter this code.

`CATCH` is three lines: bind the tag to `(DELTA **CLINK**)` in a new environment frame and
evaluate the body. Applying a `DELTA` sets `**CLINK**` from it, puts the argument in
`**VAL**`, and `RESTORE`s. That is a reified continuation as a captured pointer into the
frame chain, re-invocable, which is why the paper's `SQRT` example can use it as both a
`RETURN` and a `GOTO` target. `THROW` is `(LAMBDA (TAG RESULT) (TAG RESULT))`.

`LABELS` ties the recursive knot by construction: build the closure skeleton with `NIL`
environments via `MAPCAR`, cons the resulting frame onto `**ENV**`, then `MAPC` an
`RPLACA` over the `CDDADR` of each closure to clobber the finished environment in.

# Applicability

The preconditions are the language design itself. Every lambda is closed in the
environment it was passed from, which the paper notes has three consequences: the lambda
calculus axioms are preserved so referential transparency holds, there are no fluid
bindings (unlike MacLISP), and the upward funarg problem forces the environment to be a
tree rather than a stack.

That tree is also the limitation. Because the environment is a chain of `pairlis` frames,
lookup requires cdr-ing down rather than indexing, so the cost is proportional to lexical
distance. The paper's own answer is the right one and is the seed of every later
representation decision: since the position is fixed by lexical scope, "this position can
be computed by a compiler at compile time," and it explicitly compares this to ALGOL
display registers.

Call-by-name is ruled out, and the argument is sharp. Under Normal Order, iteration builds
a net thunk structure proportional to the number of iteration steps, mirroring the
expression growth in Normal Order substitution semantics. So iteration cannot be modeled
in a call-by-name interpreter. But pure call-by-value cannot define conditionals as
functions either, so "a practical lambda calculus interpreter cannot be purely call-by-name
or call-by-value; it is necessary to have at least a little of each." `IF` is an AINT for
exactly this reason. The escape hatch is that under pure continuation-passing style no
combination is ever a subcombination of another, so Normal and Applicative Order coincide
and no clinks are needed at all.

Costs: this interpreter is roughly half the speed of the production SCHEME, and everything
here is interpreted, alist-based, and unboxed only by accident. Nothing in the paper is a
compilation technique. The compilation payoff is Rabbit, three years later.

# Relevance

This is the ancestor document for our representation decisions, and the specific
inheritances are worth naming rather than gesturing at.

The frame rule is the specification of proper tail calls stated as a storage property
rather than as a calling convention. "No frame need be created in order to apply a lambda
expression" is exactly the invariant our code generator must preserve through closure
conversion and register allocation. If a pass introduces a save around a call in tail
position, it has broken this, and the 1975 formulation is the cleanest test to write
against.

The observation that environment depth is bounded by lexical depth, and that lookup
position is therefore computable at compile time, is the entire justification for flat
closures and for storage-class assignment at stage 8. Dybvig's three implementation models
and Keep's `O(0)` closure work are refinements of this one paragraph. Read this first, then
those.

The `CLINK` chain is the direct ancestor of the Hieb/Dybvig stack-segment representation.
Here it is a heap-allocated list because that is the only thing that supports re-entrant
`DELTA`s, and the later work is about getting the stack behavior back without losing
re-entrancy. Their design makes more sense once you have seen the naive version this
replaces.

One caution for us specifically. The paper's identification of message dispatch with
closures means our compiler should expect closure-heavy dispatch code, not vtable-shaped
dispatch, in idiomatic Scheme. Type feedback and inline caching from the SELF lineage
applies to closures here, not to classes.

# Notes

The bibliography entry in `docs/phases/00-compiler-research/PLAN.md` is correct: Sussman &
Steele, 1975, "the origin document." Title page confirms MIT AI Memo No. 349, December
1975, ARPA/ONR contract N00014-75-C-0643. Nothing to correct. The plan links to the DSpace
handle while `tools/sources.tsv` fetched the bitstream directly; same document.

Small internal inconsistency worth knowing if anyone quotes page dates: most page headers
read "December 22, 1975" but pages 4 and 13 of the memo read "December 29, 1975." The
memo was clearly retyped in passes. It does not affect content.

Surprises:

The paper is honest about method in a way modern papers are not. The acknowledgements say
"we did **not** bring forth a clean implementation in one brilliant flash of understanding;
we used an experimental and highly empirical approach to bootstrap our knowledge," and they
mention that the first interpreter was call-by-name and they "experimentally discovered how
call-by-name screws iteration" before rewriting it.

`EVALUATE!UNINTERRUPTIBLY` works by binding `*ALLOW*` to `NIL` in the environment, so
uninterruptibility follows *lexical scoping*. A funarg returned from inside such a scope
remains uninterruptible when applied later. The paper presents this as a feature and builds
semaphores on it. It is a genuinely strange design and would be a bug in anything modern;
dynamic-extent is what you want, and `parameterize` is what Scheme eventually got.

This is not yet the Scheme anyone would recognize. `IF` tests non-`NIL`, `NIL` is false,
there is no `SET!` (it is `ASET`), no `let`, no hygiene, `LAMBDA` bodies are single
expressions with no implicit `PROGN`, and `DEFINE` closes in the null environment and
stashes the closure in the host LISP's value cell. The multiprocessing primitives
(`CREATE!PROCESS`, `START!PROCESS`, `STOP!PROCESS`) never made it into any standard, and
the paper's own header for that section is "A Useless Multiprocessing Example."

Where it is oversold: Section 3 argues the recursion/iteration distinction from expression
size under substitution semantics, which is elegant, but the argument quietly assumes the
reduction strategy. Under a different order the same program can reduce differently, and
the paper does acknowledge this in the call-by-name discussion. The clean criterion is the
frame-creation rule in Section 4, not the substitution trace in Section 3.

Scanned typescript, 43 PDF pages, no text layer. Read page by page as rendered images.
Quality is good and nothing here is reconstructed from a doubtful character.
