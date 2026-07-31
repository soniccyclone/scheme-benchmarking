---
type: paper
title: "Optimizing Closures in O(0) time"
description: A catalogue of flat-closure optimizations used in Chez Scheme, keyed on well-knownness and free-variable count, that eliminates or shrinks over half of closures and free-variable accesses without ever making the naive case worse.
resource: knowledge/sources/keep-hearn-dybvig-optimizing-closures-in-o-0-time.pdf
tags: [closure-conversion, escape-analysis, flat-closures, safe-for-space, letrec]
authors: [Andrew W. Keep, Alex Hearn, R. Kent Dybvig]
year: 2012
venue: "Workshop on Scheme and Functional Programming 2012 (preprint; citations unresolved in this copy)"
informs: [/techniques/closure-conversion.md, /techniques/escape-analysis.md, /techniques/storage-class-assignment.md, /techniques/procedure-inlining.md]
pipeline_stage: 08-represent
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Not a new closure representation. The paper keeps Cardelli's flat closure (code pointer plus
one slot per free variable, one indirect per access, safe for space) and asks a narrower
question: given that representation, which closures can be deleted, shrunk, statically
allocated, or shared, using only information a closure-conversion pass already has? The
answer is a decision table on two facts per lambda, whether it is *well-known* and how many
free variables it has, plus a strongly-connected-components partition of each `letrec`.

The framing claim is the interesting one and is a design constraint, not a result: every
optimization here is required to *never do harm*. Nothing may add an allocation or a memory
operation relative to naive flat closures. That is why the paper rejects general lambda
lifting, which trades one package for `n` arguments and can raise register pressure and
stack traffic. The programmer's worst case stays predictable; optimization only improves it.

# Mechanism

Definitions. A procedure is *known* at a call site if that site provably invokes exactly
that lambda. It is *well-known* if its value is never used anywhere except at sites where it
is known, i.e. it never escapes. A well-known procedure's code pointer is dead, because every
call can jump to a direct-call label.

Avoiding closures, by (well-knownness, free-variable count):

- well-known, 0 fv: delete the closure entirely.
- well-known, 1 fv `x`: replace the closure with `x` at every use.
- well-known, 2 fv `x, y`: replace with a pair, two words instead of three.
- well-known, >=3 fv: closure or vector, same size. Choose the vector, because a small
  constant length is cheaper to store than a full-word code pointer on 64-bit, and because
  vectors make sharing legal (see below).
- not well-known, 0 fv: the closure is the same object on every evaluation of the lambda, so
  allocate it statically and treat it as a constant.
- not well-known, >=1 fv: allocate at run time. No win.

Eliminating free variables, six cases: (1) variables that became unreferenced because case
1a deleted a closure; (2) globals, whose fixed addresses go in the code stream with linker
support; (3) variables bound to constants, via constant propagation, which includes closures
statically allocated by case 2a; (4) aliases `(let ([x y]) ...)`, via copy propagation, which
arise fresh from case 1b and from sharing; (5) self-references, since a link at a known
offset that always points back to itself is by definition unnecessary; (6) mutual references
in a strongly connected group where the members' only free variables are each other's names,
as in the closed `even?`/`odd?` pair, where both closures vanish.

Sharing, two safe cases. (1) Same lifetime, at most one code pointer: any strongly connected
set of bindings, since a call from one can reach all others. (2) Same free-variable set, no
code pointers: a set of well-known procedures with identical free variables (ignoring
members' own names, which become self-references) may share regardless of lifetime, because
the shared closure retains no more than each original retained indirectly.

The algorithm is six steps: gather free variables and well-knownness; partition each
`letrec`'s bindings into SCCs and emit one nested `letrec` per component, ordered by
dependency; decide sharing within each component; compute required free variables; select
representations, including whether to share with an enclosing component's closure; rebuild.
Input must be pure `letrec` (unassigned left-hand sides, lambda right-hand sides), so
assignment conversion and letrec purification run first.

# Applicability

Preconditions: assignment conversion done (boxes for mutated variables), letrec purification
done, and a call-graph analysis good enough to decide well-knownness. Everything else is
local. Cost is one SCC pass over binding graphs, negligible, and the paper argues the pass
pays for itself downstream by handing later passes less code, hence the joke title.

Where it does not apply: sharing across differing lifetimes is unsafe for space unless the
free-variable sets coincide, and even then a retained code pointer is a problem in a system
that GCs dynamically generated code. Chez hits this because `eval` compiles on the fly; a
system with only static code can share more freely. Case 1d's vector choice exists partly to
dodge this.

Reported results: 56.94% of closures and 44.89% of free variables statically eliminated,
58.25% of closure allocation and 58.58% of closure-related memory references dynamically
eliminated, averaged over 67 R6RS benchmarks.

# Relevance

This is the concrete content of our stage 8 for procedures. Well-knownness *is* the escape
analysis we need at stage 9's granularity, computed on the call graph rather than on data
flow, and it is exactly the predicate that decides whether a closure needs a heap object at
all. Three things transfer directly:

The decision table is small enough to implement as-is in a nanopass, and it is the right
shape: representation selection keyed on a proven property plus a count, matching how our
stage 8 keys storage class on proven type plus escape. Adding a "closure" row to the storage
class table is a natural extension rather than a separate mechanism.

The never-do-harm rule should be adopted verbatim as a project constraint. Our whole pitch is
predictable performance from declarations; an optimization that sometimes regresses is worse
than none, because it makes the cost model unteachable.

The cascade matters for pass ordering. Eliminating a closure creates unreferenced variables;
replacing a one-fv closure with its variable creates aliases; sharing creates more aliases.
So closure optimization must either run to a fixpoint with copy/constant propagation or be
scheduled after them and re-run. Chez does the latter and then handles the residue with cases
1, 3, and 4 in-pass.

# Notes

Version caveat, worth flagging. This copy is a **preprint**, not a finished paper. Every
citation renders as `[? ]` and every internal cross-reference as `Section ??`; the
bibliography failed to compile and the related-work section refers to sources by raw BibTeX
key (`Serrano:cfa`, `steckler:lightweight`, `kranz:orbit`, `Shao:2000`,
`appelCompilingWithContinuationsCh10`). Section 4 is three sentences long and says outright
"We hope to provide a full break down of these numbers ... in a future version of this
paper." The PDF was produced 2013-05-13 with pdfTeX 1.40.11.

Consequences for us: the empirical claims have no per-optimization breakdown, no benchmark
table, no machine description, and no compile-time measurement despite the title's joke
resting on one. Treat the 50%+ figures as directional. Section 3's "algorithm" is a six-step
sketch, not an algorithm; the paper explicitly bills itself as a description of the
optimizations and their relationships rather than an implementation account. If we want the
sharing decision precisely, we will need Chez's source, not this document.

The honest part is admirable and rare: the related-work section concedes that a few of these
optimizations have been in Chez since 1992 and that similar things exist in other systems,
with the actual claim being that nobody wrote them down. That is the correct claim.

One footgun the paper only half-addresses. Case 3, variables bound to constants, warns that
for structured data such as statically allocated closures, care is needed not to replicate
the structure when the variable is referenced at several points. It says downstream passes
plus the linker guarantee this in Chez, without saying how. Anyone reimplementing needs to
solve that themselves, and getting it wrong silently duplicates objects that `eq?` should
identify.
