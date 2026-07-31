---
type: paper
title: "A Nanopass Framework for Compiler Education"
description: The original nanopass formulation: formally specified and enforced intermediate-language grammars, language inheritance, and a pass expander that supplies every traversal clause the author did not write.
resource: knowledge/sources/sarkar-waddell-dybvig-a-nanopass-infrastructure-for-compil.pdf
tags: [nanopass, compiler-architecture, intermediate-language, dsl, syntax-case]
authors: [Dipanwita Sarkar, Oscar Waddell, R. Kent Dybvig]
year: 2004
venue: "Educational Pearl, submitted to J. Functional Programming; preliminary version at ICFP 2004"
informs: [/techniques/nanopass-framework.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

The starting point is a *micropass* compiler — many single-task passes, hand-written, which
Indiana had already been teaching for a few years. Students built a 50-pass compiler from
s-expressions to Sparc assembly, including a graph-coloring register allocator, in one
semester. It worked, and it had three specific problems: the traversal and rewriting
boilerplate drowned the meaningful transformation, the output grammars written as
documentation were not *enforced*, and the compiler was slow enough to give students a wrong
impression of what compilers cost.

Nanopass is micropass plus three fixes. (1) Intermediate-language grammars are formally
specified and enforced. (2) A pass contains traversal code only for the forms it actually
changes; a *pass expander* fills in the rest by consulting the input and output grammars.
(3) Intermediate code is records internally, s-expressions in every interaction with the
programmer.

The word "nanopass" names both the pass granularity and the amount of source needed per
pass. Measured: `remove-not` went from 25 lines to 7; `convert-assigned` from 55 to 20.

# Mechanism

**Pass taxonomy**, the part most often dropped from later summaries:

- *Simplification* — translate into a simpler language (pattern matching to primitives).
- *Verification* — check invariants the grammar cannot express (all bound variables unique).
- *Conversion* — make explicit an abstraction the target lacks (closure conversion).
- *Analysis* — record information as annotations on the output program (free variables per
  lambda).
- *Improvement* — reduce run time or resource use.

Verification and improvement passes have the same input and output language, which is exactly
what makes them individually switchable: verification runs only during compiler development,
and improvement passes can be disabled for compile-time speed or for regression testing where
an optimization masks a bug elsewhere.

**`define-language`.**

```
(define-language name {over tspec+} where production+)
tspec      ::= (metavariable+ in terminal)
production ::= ({metavariable+ in} nonterminal alternative+)
             | ({metavariable+ in} (nonterminal common+) alternative+)
```

A metavariable declaration for `x` implicitly gives `x1`, `x2`, … . Alternatives are
disambiguated by the leading keyword, so *at most one* alternative per nonterminal may be a
parenthesized form without one — that slot is spent on application, giving natural
s-expression call syntax. The `common+` field holds annotations shared by all alternatives of
a nonterminal (source locations, analysis byproducts). The `=>` property gives a *translates-to*
form, e.g. `(seq c1 e2) => (begin c1 e2)`, which is how an intermediate-language program
acquires a host-language meaning.

That last point is load-bearing and later versions drop it. Because every production has an
implicit or explicit translation into Scheme, the output of *any* pass can be evaluated and
compared against the reference implementation. The test driver does exactly this: run the
compiler on each test program and check that every pass's output evaluates to the same result.
That is a stronger correctness discipline than "the final binary works."

**`extends`.** `(define-language name extends base {over {mod tspec}+} {where {mod
production}+})` where `mod` is `+` or `-`. Purely notational — a complete definition is
generated and behaves as if written out.

**`define-pass`.** `(define-pass name input-language -> output-language transform*)`, with
special output languages `void` (analysis run for effect) and `datum` (traverse to compute a
non-AST result, e.g. code-size estimate). Each transform:

```
(name : nonterminal arg* -> val+
  {(input-pattern {guard} output-expression)}*)
```

Subpattern forms, in increasing sugar: `,a` binds a form of `A`; `,[f : a -> b]` also binds
`b` to `(f a)`, erroring if the result is not a form of `B`; `,[a -> b]` is that when `f` is
the unique transformer `A → B`; `,[b]` drops the input binding. All extend to
`,[f : a x* -> b y*]` for transformers with extra arguments and extra return values, and
pattern variables bound earlier may appear among the `x*` — that is how analysis results thread
through the recursion.

Output is a quasiquote rebound to build *records*, not lists. `‘(if (not ,e1) ,e2 ,e3)` errors
at construction if any inserted subform is not a form of the right output nonterminal.

**The example is the argument.** Assignment conversion in two passes:

```scheme
(define-pass mark-assigned L1 -> void
  (process-command : Command -> void
    [(set! ,x ,[e]) (set-variable-assigned! x #t)]))

(define-pass convert-assigned L1 -> L2
  (process-expr : Expr -> Expr
    [,x (variable-assigned x) ‘(primapp car ,x)]
    [(lambda (,x ...) ,[body])
     (let-values ([(xi xa xr) (split-vars x)])
       ‘(lambda (,xi ...) (let ((,xa (primapp cons ,xr #f)) ...) ,body)))])
  (process-command : Command -> Command
    [(set! ,x ,[e]) ‘(primapp set-car! ,x ,e)]))
```

`L2` is `(define-language L2 extends L1 where - (Command (set! x e)))` — one line, and it is
what makes any later pass that still emits `set!` fail to compile. Three clauses total for a
transformation that touches the entire program.

**Implementation.** A `define-language` form generates: a record type per language, a subtype
per nonterminal carrying its common fields, a subtype per alternative; a *parser* s-expr →
records; an *unparser* records → s-expr (each record type stores enough to unparse itself, so
one unparse procedure serves all languages); and a *partial parser* mapping s-expression
patterns and templates to record *schemas*, which is what the macro expander compiles into
matching and construction code. All packaged as a module. Built on `syntax-case`, so the full
host language is available for auxiliary procedures — which the paper notes matters
specifically for complex passes like register allocation.

# Applicability

Preconditions: a host language with procedural macros. `syntax-case` is doing real work here —
the DSL is an extension of Scheme, not a separate tool with a separate build step.

The stated limitation is compile speed: "we are also interested in using the nanopass
technology to construct production compilers, where the overhead of many traversals of the
code may be unacceptable." The proposed remedy is a *pass combiner* using deforestation to
fuse passes on demand. As far as the later record shows, that combiner was never built —
Keep and Dybvig 2013 answered the compile-time question empirically (1.64-1.75x) rather than
by fusion.

Where nanopass gives nothing: the code generator "must explicitly handle every grammar
element," so passes at the boundary get no savings from the pass expander. The savings are
proportional to how much of the language a pass ignores.

# Relevance

The 50-pass course compiler in Table 1 is a closer model for our phase 7 than the Chez back end
is, because it is a working decomposition someone has actually taught. Week 3 is closure
conversion in eleven passes — `optimize-direct-call`, `remove-anon-lambda`,
`sanitize-binding-forms`, `uncover-free`, `convert-closure`, `optimize-known-call`,
`uncover-well-known`, `optimize-free`, `optimize-self-reference`, `analyze-closure-size`,
`lift-letrec` — all of which our CUJ collapses into unnamed work between stages 04 and 08.
Week 10 is `uncover-call-live`, `optimize-save-placement`, `eliminate-redundant-saves`,
`rewrite-saves/restores`: Burger-Waddell-Dybvig lazy saves in four passes. That is the
granularity target.

Two design rules to adopt now rather than discover later.

**Verification passes are first-class, typed `L -> L`, and disableable.** Our CUJ has none.
`verify-scheme`, `verify-a1-output`, … appear seven times in Table 1, instructor-supplied,
because they catch upstream bugs at the boundary where they were introduced rather than three
passes later. For us: after stage 04, verify every `declare` premise names a bound variable;
after stage 06, verify no check survives that the domain claimed to prove; after stage 09,
verify every claimed non-aliasing pair traces to distinct `make-flvector` sites. That turns
stage 10 miscompiles into stage 09 assertion failures.

**The `=>` translates-to property.** Every production should carry a host-language meaning, so
any pass's output can be *run* under Chez and compared against the reference. A differential
test harness for free, and far stronger than end-to-end benchmark output. Present here, absent
from the 2013 framework's description; if `nanopass-framework-scheme` still supports it we
should use it from stage 03 onward.

And what `extends` buys for `policy` and `declare`: they live in `Lcore` and should be
*removed* by the language delta at the stage that consumes them, so any later pass still
mentioning them fails at expansion time instead of silently ignoring them.

# Notes

**Bibliography correction, flagged.** The slug and bibliography say "A Nanopass
Infrastructure for Compiler Education." The title page of this PDF reads **"A Nanopass
Framework for Compiler Education"**, marked `EDUCATIONAL PEARL` and `Under consideration for
publication in J. Functional Programming`, with a footnote: "A preliminary version of this
article was presented at the 2004 International Conference on Functional Programming." So:

- The ICFP 2004 paper is *A Nanopass Infrastructure for Compiler Education* (Sarkar, Waddell,
  Dybvig, ICFP '04, pp. 201-212) — that is what the slug names.
- This file is the *later, expanded JFP submission* under a different title, **Framework**
  rather than **Infrastructure**.

Same authors, same content lineage, different title and different venue. Affiliations on the
title page are also post-ICFP: Sarkar at Microsoft, Waddell at Abstrax Inc., only Dybvig still
at Indiana. Anyone citing this as "ICFP 2004, pages 201-212" will be citing a document with a
different title and different pagination. Worth a bibliography fix; it is a version mismatch
of exactly the kind the brief calls out.

**Syntax drift is significant and will trip up anyone reading this as documentation.** The
surface syntax here is *not* what `nanopass-framework-scheme` ships:

| here (2004) | Keep-Dybvig (2013) and the shipping library |
|---|---|
| `(define-language L over (x in var) where (Expr …))` | `(define-language L (terminals (var (x))) (Expr (e) …))` |
| `(define-pass p L1 -> L2 (f : Expr -> Expr …))` | `(define-pass p : L1 (x) -> L2 () …)` |
| `,[f : a -> b]` subpattern | same idea, different spelling |
| `void` / `datum` output languages | passes with no output language |

Read this paper for the *methodology* — pass taxonomy, verification discipline, translates-to,
the 50-pass decomposition — and read Keep and Dybvig 2013 plus the library source for the
syntax we actually write.

The 2013 paper exists because the ICFP committee refused to believe this generalized past
education. Read together, the objection was reasonable and wrong: compile time really is the
risk, it really did cost 1.7x, and that was affordable. The deforestation-based pass combiner
proposed here in Section 6 as the answer was never needed.
