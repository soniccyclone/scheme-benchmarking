---
type: paper
title: "RABBIT: A Compiler for SCHEME (A Dialect of LISP). A Study in Compiler Optimization Based on Viewing LAMBDA as RENAME and PROCEDURE CALL as GOTO"
description: The first optimizing Scheme compiler, which converts to continuation-passing style expressed as a subset of the source language and then decides per lambda whether a closure is needed at all.
resource: knowledge/sources/steele-rabbit-a-compiler-for-scheme-1978.pdf
tags: [continuation-passing-style, closure-conversion, tail-calls, source-to-source-optimization, macro-expansion, register-allocation]
authors: [Guy Lewis Steele Jr.]
year: 1978
venue: "MIT AI Lab Technical Report 474 (May 1978)"
informs: [/techniques/continuation-passing-style.md, /techniques/closure-conversion.md, /techniques/tail-call-optimization.md, /techniques/procedure-inlining.md, /techniques/escape-analysis.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Three ideas, each of which survived into every Scheme compiler since.

First, the language the compiler knows is tiny: LAMBDA, IF, QUOTE, LABELS, ASET', CATCH,
and combinations. AND, OR, COND, BLOCK, DO, PROG with GO and RETURN are *macros only*, with
no compiler support whatsoever. Steele's argument for this is not economy but leverage: over
a small basis a handful of transformations combine "multiplicatively" instead of additively,
so `(IF (AND P1 P2) X Y)` collapses to good code through generic beta-substitution and a
nested-IF rule with no knowledge of AND anywhere in the compiler (pp. 54-56).

Second, the intermediate representation is continuation-passing style written in a *subset
of SCHEME itself*. Because the CPS form is a legal source program, the existing interpreter
runs it, the existing optimizer could be re-run on it, and its semantics need no separate
definition. Two properties make it a compiler IR rather than a curiosity: no combination may
have a non-trivial argument, so no control stack is needed and every intermediate value is a
named variable, and no function ever returns, so the order of evaluation is fully committed.
That is the origin of CPS as a compilation IR.

Third, and the part usually left out of the summary: closures are mostly not built. Because
lexical scoping means only code this compiler emits can ever reference a given environment,
the compiler owns the environment format outright, and post-CPS analysis discovers that most
lambdas need no runtime object at all.

# Mechanism

Six phases (p. 44). Phases 1-3 build and rewrite a NODE tree; phase 4 builds a separate
cnode tree; 5-6 annotate and emit.

**Alpha-conversion and macro expansion.** Recursive tree walk copying the source into NODE
structures, renaming every bound variable to a gensym. All information that must travel
*laterally* between branches lives on the property list of those gensyms. Steele notes this
is not luck: relating textually separated constructions is exactly what identifiers are for
(p. 46).

**Pass-1 analysis, three tree walks.** ENV-ANALYZE computes per node REFS (free local
variables at or below) and ASETVARS, plus per-variable read and write reference lists.
TRIV-ANALYZE computes TRIVP, "MacLISP could evaluate this itself with no SCHEME control
structure": constants and variables are trivial, a combination is trivial iff its function is
a MacLISP primitive or a lambda with trivial body and all arguments are trivial. Lambdas are
declared non-trivial deliberately, which Steele calls a white lie, so that every closure is
forced through CPS conversion. EFFS-ANALYZE computes side-effect classes (ASET, RPLACA,
RPLACD, FILE, CONS) in two estimates: a liberal one used only to warn about argument-order
dependence, and a conservative one the optimizer must satisfy. Per-primitive effect and
affectability sets come from an EFFDEF table, so `CADR` is known effect-free and affected
only by RPLACA/RPLACD. CONS is special: it affects nothing, but performing it twice yields
non-EQ results, which is what makes closure creation non-duplicable.

**META-EVALUATE.** Source-to-source, memoized by a METAP flag per node with incremental
REANALYZE1 to repair pass-1 slots after a rewrite. Rules: `((LAMBDA () body))` reduces to
body; unreferenced parameters with effect-free arguments are dropped; an argument is
beta-substituted for a parameter when PASSABLE proves the effect sets commute, gated by a
deliberately timid size heuristic (parameter referenced once, or argument is a constant,
variable, or a lambda whose body is a constant, variable, or small combination). Constant
folding on effect-free primitives. Dead-arm elimination on constant predicates. The
interesting rule is nested IF: rather than Standish's `(IF (IF a b c) d e)` => `(IF a (IF b d
e) (IF c d e))`, which duplicates d and e, RABBIT binds them to Q1 and Q2 and rewrites the
arms as calls `(Q1)`/`(Q2)`. Those calls later compile to plain GOTOs. This is a join point
represented as a lambda, twelve years before SSA phi nodes.

**CONVERT.** CPS conversion onto a cnode tree, distinguishing CLAMBDA from CONTINUATION and
CCOMBINATION from RETURN. Trivial subforms are kept as TRIVIAL cnodes pointing back into the
pass-1 tree. Arguments split into "trivially evaluable" (trivial forms plus lambdas, passed
directly in the final call) and the rest, which get strung-out continuations generated in
reverse so that evaluation runs left to right. One optimization is done here rather than in
the optimizer: a continuation variable is substituted for another, which removes register
shuffling of continuations (p. 94, added after the dissertation).

**Environment and closure analysis, four passes.** CENV-ANALYZE redoes ENV/REFS over the CPS
form and marks VARIABLE-REFP on any variable referenced outside function position.
BIND-ANALYZE then assigns each lambda one of three closure classes (pp. 60-61, 192):

- NIL, a full CBETA closure of code pointer plus environment, needed when the function is
  ever treated as data.
- EZCLOSE, environment consed up but no code pointer attached, when every call site knows
  the name and can GO to the code, but some of those sites sit inside other closures and
  therefore need a complete copy of the environment.
- NOCLOSE, no runtime object at all, when the environment is always recoverable from the
  environment at the point of call.

Mutually recursive LABELS cannot be decided sequentially, so all functions in one LABELS are
forced to share a class, tentatively NOCLOSE, and retroactively patched. Variables provably
bound to a known lambda get a KNOWN-FUNCTION property pointing at its cnode. DEPTH-ANALYZE is
register allocation: closed functions take arguments in the fixed registers `**CONT**`,
`**ONE**`..`**EIGHT**`; NOCLOSE functions get a "depth" equal to the enclosing depth plus the
enclosing function's argument count, a purely stack-like walk into the register file and then
into unbounded pseudo-locations `-11-`, `-12-`. CLOSE-ANALYZE lays out the heap environment,
which is a flat CDR-chained list of values with sharing of tails; per closed lambda it
computes three sets, already present, must be consed on, and must be moved in on entry. The
third exists only because of ASET': a mutated variable must have exactly one home, so it is
forced out of registers into the shared environment before any closure is built.

**Code generation.** One module is one MacLISP DEFUN whose body is a single PROG; every
function is a tag. A closure's code pointer is therefore a pair (SUBR pointer, tag), and
module entry is `(GO (PROG2 NIL (CAR **ENV**) (SETQ **ENV** (CDR **ENV**))))`, since MacLISP
cannot make a pointer into the middle of a PROG. A call to a KNOWN-FUNCTION becomes an
environment adjustment (ADJUST-KNOWNFN-CENV emits some number of CDRs off `**ENV**`, since
for NOCLOSE the callee environment is provably a tail of the caller's) followed by a GO.
Everything else sets `**FUN**`, the argument registers, and `**NARGS**`, then does
`(RETURN NIL)` to reach the UUO handler. Argument setup goes through PSETQIFY, a parallel
assignment, because argument expressions may read registers being written.

# Applicability

The whole design rests on the compiler owning the environment format, which holds only
because no interpreted code, no separately compiled code, and no debugger can reach into a
compiled environment. Weaken that and BIND-ANALYZE/CLOSE-ANALYZE collapse to full closures.

Assignment is the enemy. RABBIT forbids ASET' on globals that name primitives and on
LABELS-bound variables, and gets away with it: Steele reports a dozen uses in roughly a
hundred pages of Scheme by three people (p. 93). Escape procedures are worse. If a
side-effecting expression is substituted past a call to an unknown function, and that
function performs a CATCH whose escape procedure is later invoked twice, the effect happens
twice. Steele states flatly that there is no way to decide this short of fearing every
unknown call, that fearing them defeats most optimization, and that RABBIT therefore ignores
the problem (p. 92). Restricting escapes to one-shot use is what lets other languages use a
stack rather than a tree for control.

Known weak spots, all admitted: no data-type analysis, so `(IF (OR A B) X Y)` becomes
`(IF A (IF A X Y) (IF B X Y))` and the inner test stays; register allocation is naive
depth-stacking with no liveness; the environment is an O(n) CDR chain rather than a chain of
contour vectors with a display; no general procedure integration across user functions; no
common-subexpression elimination, though Steele sketches how lambda-binding expresses it.
Cost: the optimizer roughly doubles compile time, and the pairwise argument conflict check
adds twenty to thirty percent on top.

What Steele actually measured (pp. 86-87), which is less than the reputation suggests.
Compiled unoptimized over interpreted is 25x overall, 17x excluding GC. Optimized over
unoptimized compiled is only **1.2x** overall, 1.37x excluding GC. Consing barely moved,
because the phase-2 closure analysis had already eliminated most of it. Combined, about 30x
over the interpreter. There is no cycles-per-call figure and no comparison against a
traditional compiler for the same program. "Function calls are not expensive when compiled
correctly" is argued structurally, from the fact that a known call compiles to a GOTO after
an environment adjustment, and is exhibited on a factorial loop; it is not benchmarked.

# Relevance

This is the load-bearing ancestor of the front half of our pipeline, and the useful reading
is at the level of decisions rather than slogans.

The three-way closure classification is the thing to steal and then improve. NOCLOSE is
escape analysis on procedures, EZCLOSE is the flat-environment-without-code-pointer case, NIL
is the fallback. Keep, Hearn, and Dybvig generalize exactly this, so
`keep-hearn-dybvig-optimizing-closures-in-o-0-time` should be read as the sequel and RABBIT
read for why the categories exist. RABBIT's rule for the third CLOSE-ANALYZE set is the precondition our
storage-class stage inherits: assignment converted variables need a single home, so
assignment and escape analysis must precede register assignment, not follow it.

DEPTH-ANALYZE is a warning, not a model. It shows what a nanopass front end looks like when
the register assignment is an afterthought, and Steele's own worked example (p. 85) shows the
resulting shuffling. Our stages 11-13 are the modern replacement; nothing about RABBIT's
register handling transfers, because its target was MacLISP source and the real allocation
happened downstream in NCOMPLR.

The KNOWN-FUNCTION property plus direct GO is the direct-call optimization our call sites
need, and RABBIT establishes the cheapest version: a property on the variable set during
binding analysis, consumed at code generation, with the environment adjustment computed as a
suffix relation on a chained environment.

Finally, the nested-IF-with-lambda-join-points rule is worth implementing early. It gives
short-circuit control flow, evaluation-for-control, and evaluation-for-effect for free, all
three of which Steele points out fall out with no special machinery once AND/OR/NOT are
macros over IF (pp. 96-97).

# Notes

**Bibliography check: the entry is correct.** `docs/phases/00-compiler-research/PLAN.md` line
349 lists Steele, *RABBIT: A Compiler for SCHEME* (1978), "the first optimizing Scheme
compiler," and every part of that holds. Two refinements. The document is a *revised* version
of a Master's dissertation submitted 1977-05-12 under a different title, "Compiler
Optimization Based on Viewing LAMBDA as RENAME plus GOTO," supervised by Gerald Jay Sussman;
passages marked "since the dissertation was written" are 1978 additions and include the
continuation-variable substitution and the generalized LABELS. And RABBIT is not the first
Scheme compiler: CHEAPY was, a throwaway with almost no optimization, described on p. 10.
"First optimizing" is the right claim. The PLAN layout sketch at line 64 names the file
`steele-1978-rabbit.md`; the actual slug is `steele-rabbit-a-compiler-for-scheme-1978`.

Slightly more than half the document is Appendix material: the complete annotated RABBIT
source, code on odd pages and commentary facing on even pages, from p. 117 to the symbol
table at the end. The commentary is where the real algorithm lives; the main text is
explicitly a qualitative overview (p. 3 lists five reading depths).

**Steele's own IR design post-mortem, p. 174.** Splitting CLAMBDA from CONTINUATION and
CCOMBINATION from RETURN into distinct data types "was somewhat of a design error." The
dichotomy is real semantically, but it forced a great deal of pass-2 code to be written
twice. He recommends one structure with a flag. That is a direct argument against
over-refining IR types in a nanopass design, from the person who invented the style.

Other candid admissions worth having: PSETQIFY carries a third code-generation method that
exists solely to route around a bug in the MacLISP compiler whose maintainer was on leave for
a year (p. 234); the reproduction of the older CPS converter in the Notes still carries a
known bug in CPC-FORM around side-effected variables, left unfixed to keep the printed
examples readable (p. 107); and the whole compiler was written for clarity, retaining
analysis it never uses, to the point that its larger functions "can just barely be compiled
with a memory size of 256K words on a PDP-10" (p. 117).

Dated and oversold in one place. Thesis point 9 pitches SCHEME as an UNCOL at two levels,
applicative and CPS. The UNCOL framing is a period artifact, though the technical content
(a small applicative core plus a CPS level that maps to machine code) is roughly what LLVM
IR eventually delivered. Implementation effort is quoted three ways in the document, one
month part-time for the first working version (p. 14), one man-month before the optimizer,
and three man-months total including a full optimizer rewrite (p. 117); the last is the
honest number.
