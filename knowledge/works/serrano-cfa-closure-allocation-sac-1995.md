---
type: paper
title: "Control Flow Analysis: a Functional Languages Compilation Paradigm"
description: Uses 0CFA in the Bigloo Scheme compiler to classify every procedure into one of three nested predicates, then picks a cheaper closure representation for each class; removes ~87-95% of closure allocations and roughly halves run time.
resource: knowledge/sources/serrano-cfa-closure-allocation-sac-1995.pdf
tags: [control-flow-analysis, closure-conversion, escape-analysis, scheme, bigloo]
authors: [Manuel Serrano]
year: 1995
venue: "ACM Symposium on Applied Computing (SAC '95), pp. 118-122 (venue not printed on this copy; see Notes)"
informs: [/techniques/closure-conversion.md, /techniques/control-flow-analysis.md, /techniques/escape-analysis.md]
pipeline_stage: 08-represent
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

**Read the Notes section first: this file is not the paper the slug names.** It is Serrano's
SAC'95 paper on closure representation in Bigloo, not Serrano and Weis's SAS'95 Bigloo
overview.

The paper's argument is that 0CFA had, by 1995, been studied to death as theory and used
almost nowhere in a real compiler, because nobody had shown a *specific* optimization it
pays for. Serrano supplies one: closure representation selection. Prior closure analyses
(Kranz's ORBIT thesis, Séniak's SQIL thesis) partition procedures into two sets, allocates
and does-not-allocate. Serrano shows that partition is exactly the weakest of three nested
predicates derivable from a 0CFA call graph, and that the two stronger classes admit
strictly cheaper representations that the binary analysis throws away. The claim is
subsumption: any function the older analyses optimize, this one optimizes too, plus more.

# Mechanism

**IR.** Direct style, not CPS, and explicitly so. The grammar is a Lisp-shaped Scheme:
`define`, `set!`, `if`, `labels`, `function`, `funcall`, plus a `failure` form whose
continuation is never invoked, plus module-level import/export/static. There is no `lambda`;
`(lambda (x) e)` is written `(labels ((id (x) e)) (function id))`. That factoring is the
whole trick, because it syntactically separates *code* (`labels`) from *first-class
reference to code* (`function`), which is precisely the distinction the optimization
exploits. `call/cc` is an ordinary library procedure and needs no special case.

**0CFA.** Abstract values are subsets of `R = {T, bottom} union FunId`; `T` means unknown.
All approximations start at `{bottom}`; the only operation is `add-app!`, which joins a
value into a variable's approximation. Variables carry four locality flags: `LOC`/`GLO` for
ordinary variables and `FOR`(foreign, defined in C/asm)/`ESC`(exported or imported) for
functions. The analysis is a fixed-point iteration of a case analysis over the AST
(`Ocfa-exp`), with the interesting cases being:

- `(funcall fun a...)`: union over `f` in `A(fun)` of `Ocfa-try-app(f, ...)`.
- known application to an `ESC` or `FOR` target: `set-top!` the arguments and the body,
  i.e. surrender.
- otherwise: bind each argument approximation into the callee's `i`th formal via `add-app!`
  and recur into the body.

Self-recursion is cut with a stamp so a function is approximated once per iteration. Worst
case is O(n^3) in functions-plus-call-sites; measured iteration counts to fixpoint were at
most 5 on real programs.

**The dual map.** `A(f)` at a call site gives the callable set. Invert it: for each
function `f`, `USE(f) = { s = (funcall g ...) : f in A(g) }`, the set of sites that can
invoke `f`.

**The three predicates**, from weakest to strongest, with `S => X => T`:

- `T(f)`: not escaping, and at every site in `USE(f)`, every other member of the
  approximation set is also a function satisfying `T`. This is a *family*: a set of
  procedures always applied at the same places.
- `X(f)`: not escaping, and at every site in `USE(f)`, `A(g) = {f}` exactly. `f` is the
  unique callee everywhere it can be called.
- `S(f)`: not escaping, and `USE(f)` is empty. `f` never reaches a `funcall` at all.

**What each buys.** Baseline procedure representation is >= 4 words: tag, arity, and two
entry points (fixed-arity and variable-arity), because Scheme is dynamically typed and every
computed call must check applicability and arity.

- `S`: no closure and no environment. Every call is a direct branch; free variables are
  lambda-lifted into the parameter list. Proposition 2 is the practically important one:
  any function never passed as an argument and never returned satisfies `S`.
- `X`: no closure *structure*, though an environment may remain. With zero or one free
  variable the `(function f)` form is replaced by the free variable itself; with several, by
  a bare list of free variables. Call sites become direct calls after lambda lifting.
- `T`: closure structure shrinks to a single entry-point slot, with no tag, no arity field,
  and no variable-arity entry, because the family is known statically, so type and arity
  correctness are checked at compile time. Variable-arity functions are excluded from `T` to
  keep it to one entry point. Call sites compile to an "easy" computed application with no
  type or arity check.

The `T` case has a nice degenerate use: for a denotational-semantics-shaped program, all
closures for evaluated terms land in one family, so they can be represented as
`<index, env>` pairs and the call site becomes an indexed jump. The optimizer has
mechanically derived a bytecode interpreter.

# Applicability

Whole-program, or at least whole-module with explicit import/export. Anything `ESC` (exported
or imported) or `FOR` (foreign) poisons its arguments and body to `T` immediately, so
separate compilation directly costs precision. Same for global variables, which read as `T`
unconditionally.

Cost is real and the paper does not hide it: 0CFA time on the `conform` benchmark is 60.5s
against 6.4s without, an 845% increase in Scheme-side compile time. It is repaid because
Bigloo emits C and the C compiler is the bottleneck; better C compiles faster, so end-to-end
compile time sometimes *drops* (earley +2%, semantics +20%) and sometimes does not
(conform -52%). Bigloo's own bootstrap, 30k lines, goes from 45 to 55 minutes.

Precision of 0CFA specifically. Serrano tried and rejected 1CFA, arguing the extra
information (how a function reached a call site) has no consumer in a compiler. Unresolved
by the paper, and probably wrong for anything doing type-directed unboxing.

# Relevance

This is the closest published thing to what stage 8 does, one level up. Stage 8 assigns
storage classes to values by asking "does it escape"; Serrano assigns representations to
*procedures* by the same shape of question, and shows the answer is not binary. If we do
closure conversion at all, and we must, the three-way split is the right structure, and
the `S` case alone (never passed, never returned, therefore a direct branch with lifted free
variables) covers most functions in most programs and is nearly free once we have a call
graph.

The direct-style choice matters to us. Serrano is explicit that Bigloo skips CPS and that
this is why 0CFA is enough: with CPS, control is artificially dynamic and CFA is mandatory
just to recover what direct style never lost. Our IR should not create work for our
analyses.

The `T`-family trick is a genuine idea for the numeric path: if a set of small kernels is
provably only ever applied at one site, we can drop the arity and tag words and, more
importantly, drop the applicability check at the call. That is exactly the check that stands
between us and a tight inner loop.

Note the measured ceiling. Serrano reports 87-95% of closure allocations removed and ~70%
run-time improvement, against a baseline with no closure optimization at all. That baseline
is not Chez, so the number does not transfer.

# Notes

**Bibliography correction, high confidence.** The slug
`serrano-cfa-closure-allocation-sac-1995` claims Serrano and Weis,
"Bigloo: a portable and optimizing compiler for strict functional languages", SAS 1995. The
PDF is a different paper:

- Title on page 1: *Control Flow Analysis: a Functional Languages Compilation Paradigm*
- Author: **Manuel Serrano alone**, INRIA-Rocquencourt. Pierre Weis is not an author and is
  not mentioned anywhere in the text or references.
- Five pages, running page numbers 118-122, consistent with SAC'95.

The venue and year are *not printed on the document itself*; the ACM copyright block is the
generic permission notice with no conference line, and the PDF metadata carries only a 1999
scan date. The identification as SAC'95 rests on the fetch URL recorded in
`knowledge/sources/manifest.tsv` (`.../Manuel.Serrano/publi/serrano-sac95.pdf`) and the page
range, not on the artifact. Treat the venue field as inferred.

Recommended action: rename the slug to something like `serrano-cfa-closure-allocation-sac-1995`,
and treat the Serrano-Weis SAS'95 Bigloo paper as still missing from the bundle. Those are
different papers with different content, and the plan appears to want the SAS one.

Two things the paper gets wrong or oversells. First, the subsumption claim against Kranz and
Séniak is stated but not proved, and rests on reading their algorithms as computing exactly
`S`; that is asserted, not demonstrated. Second, the dismissal of 1CFA ("what can be done
with this information in a compiler? We have found no answers") aged badly. Polyvariant
CFA is how you get type specialization, which is precisely what a compiler wants for
unboxing. It was a defensible engineering call in 1995 given the O(n^3) cost of 0CFA alone.

The extracted text is a 1999 OCR scan and is noisy: predicate names render inconsistently
(`7`/`I`/`lr` for `T`, `&SC` for `ESC`, `PCO`/`FLCO` for `GLO`), and the benchmark tables are
partly garbled. The algorithm and the three predicate definitions are legible and unambiguous;
individual digits in the measurement tables are not fully trustworthy. Where this document
gives numbers, they are corroborated by the surrounding prose.
