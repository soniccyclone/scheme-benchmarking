---
type: technique
title: Continuation-passing style as a compilation strategy
description: Name every return address, temporary and evaluation-order decision by making functions take an explicit continuation, giving an IR where no combination has a non-trivial argument and no function returns.
tags: [continuation-passing-style, intermediate-representation, tail-calls, source-to-source-transformation, join-points]
sources:
  - resource: /works/steele-rabbit-a-compiler-for-scheme-1978.md
  - resource: /works/steele-lambda-the-ultimate-declarative-1976.md
  - resource: /works/steele-sussman-lambda-the-ultimate-imperative-1976.md
  - resource: /works/flanagan-sabry-duba-felleisen-the-essence-of-compiling-wit.md
  - resource: /works/shivers-control-flow-analysis-of-higher-order-languages-19.md
  - resource: /works/serrano-cfa-closure-allocation-sac-1995.md
  - resource: /works/appel-ssa-is-functional-programming-1998.md
  - resource: /works/sussman-steele-scheme-an-interpreter-for-extended-lambda-c.md
implemented_by: []
absent_from: [/implementations/chez.md]
pipeline_stage: 03-parse
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

In a direct-style term, three things are implicit and live only in the compiler's head: where
return addresses go, what the intermediate temporaries are, and what order subexpressions
evaluate in. Any back end has to commit to all three. CPS makes the commitment part of the
term itself. The engineering question is whether paying that in term size and pass count buys
enough downstream to be worth it.

# Mechanism

A function takes an explicit continuation and calls it with the answer instead of returning.
Two properties turn that from a semantics exercise into a compiler IR, and RABBIT states both:
no combination may have a non-trivial argument, so no control stack is needed and every
intermediate value is a named variable; and no function ever returns, so evaluation order is
fully committed. Steele and Sussman add the structural observation that makes it usable: the
control stack of a direct-style interpreter is exactly the environment structure of the CPS
version.

RABBIT's further trick is that the CPS form is written in a *subset of Scheme itself*, so the
existing interpreter runs it, the existing optimizer can be re-run on it, and its semantics
need no separate definition.

**The converter.** Steele's `CPC` in *Ultimate Declarative* Appendix A is working code and the
clearest specification available. It dispatches on `ATOM`, `QUOTE`, `LAMBDA`, `IF`, `CATCH`,
`LABELS`, macro, and form.

- `CPC-LAMBDA` appends a generated continuation parameter.
- `CPC-IF` names the join continuation `KN` **once** so both arms share it instead of
  duplicating code, then converts the predicate under `(LAMBDA (PN) (IF PN ...))`. This is not
  a nicety. Duplicating `k` into both arms is the exponential-blowup hazard, and the same
  hazard exists in A-normalization's conditional case.
- `CPC-CATCH` eliminates `CATCH` outright by binding the catch tag to `(LAMBDA (V C) (EN V))`,
  a procedure that discards its own continuation.
- `CPC-FORM` runs two passes: pass one walks the argument list, converting trivially-evaluable
  arguments with a null continuation into `Y` and stashing non-trivial ones in `Z` under fresh
  temporaries; pass two folds `Z` inside-out into nested continuations.
- Appendix B extends this to multiple value return by letting a continuation take `n`
  arguments, which then ride in registers exactly like ordinary arguments.

RABBIT's `CONVERT` is the same shape on a separate cnode tree, distinguishing `CLAMBDA` from
`CONTINUATION` and `CCOMBINATION` from `RETURN`. Trivial subforms stay as `TRIVIAL` cnodes
pointing back into the pass-1 tree. Arguments split into trivially evaluable (trivial forms
plus lambdas, passed directly in the final call) and the rest, whose strung-out continuations
are generated in reverse so that evaluation runs left to right. One optimization happens here
rather than in the optimizer: a continuation variable is substituted for another, which
removes register shuffling of continuations.

**Administrative redexes.** Naive conversion introduces beta-redexes that exist only to plumb
continuations. A CPS compiler simplifies them away as a separate phase, and that phase is
half of what Flanagan et al. later prove is redundant.

**What the IR enables downstream.** Closure conversion runs on the CPS form; RABBIT's
BIND-ANALYZE and CLOSE-ANALYZE operate on cnodes, not on source. Shivers' CFA takes CPS Scheme
as its IR precisely because every transfer of control (sequencing, looping, call, return,
conditional) is a tail call there, so one abstract-interpretation rule covers all of them.
And RABBIT's nested-`IF` rule, which binds the two arms to `Q1` and `Q2` and rewrites the arms
as calls that compile to plain `GOTO`s, is a join point represented as a lambda twelve years
before SSA phi nodes. Appel and Kelsey later close that loop formally: a basic block is a
function, an in-edge is a tail call, and a phi node is a formal parameter.

# Preconditions

Alpha-renaming, so every bound variable is unique.

Argument triviality has to be defined correctly, and both Steele documents get it wrong in the
same place and admit it. `CPC-FORM` treats variables as trivially evaluable, which is unsound
under side effects; the fix is to generate temporaries for them too, and Steele left the bug in
to keep the printed examples readable. RABBIT's Notes reproduce the older converter with the
same bug around side-effected variables, also left unfixed. **Anyone transcribing either
listing inherits it.** The related claim in *Ultimate Imperative*, that under CPS evaluation
order becomes irrelevant because trivially evaluable expressions have no side effects, rests
on exactly the definition the bug violates.

The conditional case must share one join continuation, or term size grows exponentially on
nested conditionals.

RABBIT declares lambdas non-trivial deliberately, which Steele calls a white lie, so that every
closure is forced through CPS conversion. That is a precondition of its closure analysis, not
of CPS.

# Cost

Term size grows, and the administrative redexes have to be simplified back out, which is a
separate pass. Steele's own IR post-mortem (RABBIT p. 174) is that splitting `CLAMBDA` from
`CONTINUATION` and `CCOMBINATION` from `RETURN` into distinct data types "was somewhat of a
design error": the dichotomy is real semantically but it forced a great deal of pass-2 code to
be written twice over near-identical shapes. He recommends one structure with a flag.

Measured cost, and it is thinner than the reputation. RABBIT's compiled unoptimized code is
25x the interpreter, 17x excluding GC. The optimizer over unoptimized compiled code is
**1.2x** overall, 1.37x excluding GC, and consing barely moved because the phase-2 closure
analysis had already eliminated most of it. Combined, about 30x over the interpreter. There is
no cycles-per-call figure and no comparison against a traditional compiler on the same
program. "Function calls are not expensive when compiled correctly" is argued structurally,
from the fact that a known call compiles to a `GOTO` after an environment adjustment, and
exhibited on a factorial loop. It is not benchmarked. The optimizer roughly doubles compile
time and the pairwise argument conflict check adds another twenty to thirty percent.
*Ultimate Declarative* measures nothing at all: no implementation, no benchmark, no GC
discussion.

The analysis cost is the subtler one. Serrano's position is that CPS makes control artificially
dynamic, so a control-flow analysis becomes mandatory just to recover what direct style never
lost. Bigloo skips CPS for that reason and gets away with 0CFA where a CPS compiler would need
more.

# Disagreements

This is a genuine three-way split, not a spectrum.

**CPS against ANF.** Flanagan, Sabry, Duba and Felleisen argue the CPS-specific structure is
information the back-end machine ignores: return sites carry a continuation variable `k` the
machine never reads, because a return uses the dedicated continuation register, and calls pass
a continuation parameter the callee never binds, because the caller's continuation is already
in that register. Deleting the redundancy is exactly an inverse CPS transformation, so
CPS-convert, beta-simplify and generate code equals one source-level normalization. Two machine
theorems back it. The CPS camp keeps one argument the paper does not address: **ANF is not
closed under the beta reductions inlining performs**, so an ANF compiler must renormalize after
inlining, while CPS is closed under its beta rule.

**What analyses need the CPS partition.** Flanagan et al. claim only that CPS optimizations
expressible as beta and eta reductions have ANF counterparts. Shivers' CFA exploits the CPS
partition of procedures into user procedures and continuations for its own purposes, and that
structure is not free in ANF. So "you do not need CPS" is true of the back end and unproven of
the analyses.

**CPS against a stack representation for control.** RABBIT's `CPC-CATCH` rewrites `CATCH` away
entirely. Steele and Sussman's own conclusion in *Ultimate Imperative* is that escape
expressions and general L-values are **not syntactically local** and should be primitives
rather than source-to-source rewrites, which is a negative result from the paper that made
everything else a rewriting. RABBIT is candid about the consequence it ignores: if a
side-effecting expression is substituted past a call to an unknown function and that function
performs a `CATCH` whose escape procedure is later invoked twice, the effect happens twice;
there is no way to decide this short of fearing every unknown call, and fearing them defeats
most optimization. The stack-segment representation is the other answer, and it keeps ordinary
calls at stack cost. See `stack-segment-continuations.md`.

**How much of this is notation.** Appel's dictionary makes CPS and SSA the same object viewed
from two sides, crediting Kelsey 1995 for the correspondence. That weakens the CPS-against-ANF
argument into a question about which redundancies your passes have to skip over, which is
where Flanagan et al. leave it.

# For us

Our core language after `03-parse` is ANF-shaped, per `a-normal-form.md`, so this document is
mostly about what to salvage rather than what to build. Four things salvage cleanly.

The join-continuation-as-lambda rule. RABBIT's nested-`IF` treatment binds the arms to `Q1`
and `Q2` and rewrites the arms as calls, which compile to `GOTO`s, rather than Standish's rule
that duplicates both arms. Implement it early: it gives short-circuit control flow,
evaluation for control, and evaluation for effect with no special machinery once `AND`, `OR`
and `NOT` are macros over `IF`.

Continuation-variable substitution, RABBIT's one conversion-time optimization, which is what
keeps continuations from being shuffled between registers. The equivalent in our pipeline is
a copy-propagation obligation at `11-select`.

Multiple value return as an `n`-ary continuation with values riding in argument registers,
which is the representation Chez's rewritten back end also reaches.

And the warning. RABBIT is the load-bearing ancestor of the front half of our pipeline, and its
optimizer bought **1.2x**. The closure analysis had already taken the consing before the
source-to-source rewriter ran. Budget accordingly: representation decisions at `08-represent`
outrank another round of term rewriting at `03-parse`.
