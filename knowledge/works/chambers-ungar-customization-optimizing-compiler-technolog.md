---
type: paper
title: "Customization: Optimizing Compiler Technology for SELF, a Dynamically-Typed Object-Oriented Programming Language"
description: Compiles one machine-code copy of each method per receiver type so the receiver's type is a compile-time constant, then combines that with message splitting and static type prediction to eliminate nearly all dispatch.
resource: knowledge/sources/chambers-ungar-customization-optimizing-compiler-technolog.pdf
tags: [customization, monomorphization, message-splitting, type-prediction, inline-caching, maps]
authors: [Craig Chambers, David Ungar]
year: 1989
venue: "PLDI 1989, SIGPLAN Notices 24(7), 146-160"
informs: [/techniques/customization.md, /techniques/message-splitting.md, /techniques/type-feedback.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Three techniques for manufacturing static type information in a language that has none, and the
observation that the three compose into something much stronger than any one of them.
*Customization* compiles a separate copy of each method per receiver type, which makes `self`'s
type a compile-time constant. *Message splitting* compiles a copy of a send on each incoming
control path so that types known per-branch survive the merge. *Static type prediction* inserts a
speculative tag test plus a split for messages whose receiver type is empirically predictable.
Together with compile-time message lookup and aggressive inlining, they doubled the performance
of dynamically typed object-oriented languages, landing SELF at 4 to 5 times slower than
optimized C where the best Smalltalk was over 10 times slower.

The paper's other lasting contribution is *maps*, the representation that makes all of this
possible on a prototype language.

# Mechanism

**Maps.** Objects cloned from the same prototype form a *clone family*. The shared immutable map
holds, per slot, the name, the parent flag, and either the in-object offset (assignable slots) or
the contents itself (constant slots, including methods), plus a pointer to the byte code object
if the object is a method. An object is therefore just its assignable slot contents plus a map
pointer, which recovers class-like space efficiency without classes. Changing an object's format
or a constant slot mints a new map and starts a new family. The map is the compiler's notion of
type: absent dynamic inheritance, all members of a clone family have identical inheritance
structure, so a method that applies to one applies to all.

**Compile-time message lookup.** Given the receiver's map, search it for a matching slot; if
absent, recurse through the *constant* parent slots, whose contents are in the map. Success turns
a send into a statically bound call, which makes it an inlining candidate. Failure happens
exactly when a traversed parent is assignable, that is, under dynamic inheritance.

**Customization.** Compile one version of the source method per receiver map, usable only by that
clone family. Now every send to `self` resolves at compile time. The `sumTo:` worked example is
the most valuable part of the paper and worth reading in full: starting from a three-send method,
customization for integer receivers resolves and inlines `to:Do:`, then `to:By:Do:`, at which
point `1 = 0` and `1 < 0` constant-fold, collapsing the guard structure of the general iteration
method, then `ifTrue:False:`, `whileTrue:`, `loop`, `value` and `value:` all inline in turn
because their receivers are compile-time constants (literal blocks, `true`, `false`). What was a
cascade of message sends through four library methods becomes a loop with a register-allocated
index. Every block literal but two is inlined and therefore never cloned at run time, which
matters because SELF implements all control structures with blocks.

**Message splitting.** Primitives have multiple exits: success with a known result type, failure
with an unknown one, and comparison primitives have separate true and false success exits.
Normally control rejoins and the merged type is the least specific one, which is usually unknown.
Splitting pushes the *following* send back through the merge point, producing one copy per
incoming branch, each compiled against that branch's specific type. Applied to
`0 = i ifTrue: [...]`, the `ifTrue:` send gets three copies: one for `true`, one for `false`, one
for the primitive-failure path. The first two inline to compile-time constants and vanish, so the
boolean object is never materialized and the flow of control carries the result, as the paper puts
it, "just like a good C compiler would."

**Static type prediction.** For messages whose receivers are empirically monomorphic, insert a tag
check and split. Ungar's Smalltalk measurements are the justification: `+`, `-`, `<` had integer
arguments 90% of the time, `ifTrue:` had boolean receivers 100% of the time. The predicted branch
inlines, the other stays a full send. Unlike Smalltalk implementations that hardwire the source of
`ifTrue:` and `+` into the parser, this is purely a compiler bet: the programmer can redefine
integer `+` at any time and behaviour updates immediately.

Supporting machinery: dynamic (per-method, on first invocation) translation with a compiled-code
cache, Deutsch-Schiffman inline caching with a map check in the method prologue and roughly 95%
hit rate, stack-allocated activation records, Generation Scavenging at about 3% of CPU, tagged
words, no object table.

# Applicability

Space is the direct cost: one compiled body per receiver type. Overcustomization is real, and the
1994 type feedback paper traces DeltaBlue's code bloat to customizing constraint methods for three
constraint types, noting that with type feedback you can customize less aggressively.

Customization only helps sends to `self`. Arguments, the receiver's own assignable slot contents,
and method locals stay unknown, and the authors name this as the largest remaining source of
unknown types. In `sumTo:` this is exactly why the first-generation compiler stalls at
`i <= upperBound`: it does not know the type of the assignable slot `i`, which is why prediction
and splitting have to finish the job. Customizing on argument types too is proposed as future
work, weighed against the cost of checking arguments in the prologue.

Dynamic inheritance breaks compile-time lookup outright. The second-generation answer is to add
the values of any traversed assignable parents to the customization key and check them in the
prologue.

Two constraints of theirs we do not share. The compiler abstains from any optimization that would
break the illusion of byte code interpretation or source-level debugging, which specifically
forbids tail call elimination because it destroys frames the debugger needs. And compile time was
a problem: 7 seconds for the ~900-line Stanford integer benchmarks, 3 seconds for Richards, too
slow for their interactive environment. Their proposed fix, a fast non-optimizing compiler with
background reoptimization, is exactly what SELF-93 became.

# Relevance

Customization is monomorphization keyed on run-time representation rather than on a static type
parameter, and that is precisely the shape our stage 8 needs. The storage classes in the CUJ
(unboxed f64 in xmm, boxed flonum, tagged fixnum, untagged loop index, tagged descriptor) are a
small finite lattice, so specializing a procedure per argument representation set is a bounded,
tractable version of what SELF did over an unbounded space of maps. The pattern to copy is a
specialized entry point whose prologue checks representations, a general entry point, and a
specialized body that assumes the representations throughout with no further checks.

Message splitting is the direct ancestor of what stage 10 needs, and section 6.1 states the goal
in terms we could paste into the CUJ: split off entire sections of the control flow graph
corresponding to the most common data types, so that along those sections every variable's type
is known at compile time and there are no run-time type checks, with exceptional cases
transferring control out to a more general section. That is the precondition list for
vectorization, arrived at from the other direction.

The claim to argue with is in section 7: "Type inferencing holds little promise for improving the
performance of object-oriented dynamically-typed languages." Note what it is about. Their evidence
is Smalltalk type inference work (Suzuki, Borning and Ingalls, Curtis) defeated by user-defined
control structures, `nil` initialization, `perform:` and `become:`. Scheme has none of those. The
stronger evidence against static analysis is the 1994 measurement that SELF-91's iterative type
analysis performed no better than no analysis, and that is the sentence to hold onto, not this one.

# Notes

Title on the title page is the full "Customization: Optimizing Compiler Technology for SELF, a
Dynamically-Typed Object-Oriented Programming Language." The bibliography truncates it to
"...for SELF," which is harmless but the full string is recorded above. Venue confirmed from the
ACM copyright line: SIGPLAN '89 Conference on Programming Language Design and Implementation,
Portland, pages 146-160, SIGPLAN Notices 24(7).

Authors are Chambers and Ungar only, both at Stanford. This is worth stating because it is easy to
conflate with the OOPSLA '89 paper, which this one cites as [CUL89] with the author list "Craig
Chambers, David Ungar, and Elgin Lee, An Efficient Implementation of SELF, a Dynamically-Typed
Object-Oriented Language Based on Prototypes." Our corpus has that paper as
`chambers-ungar-an-efficient-implementation-of-self-oopsla-`, whose slug omits Lee. Whoever
ingests that file should check the title page: if Lee is on it, the slug and any bibliography entry
derived from it are missing a third author.

The abstract's "doubled the performance" and the conclusion's "four to five times slower than
optimized C" describe the same measurements from opposite ends. The comparison against Johnson's
Typed Smalltalk (`sumTo:` at 16ms in SELF versus 62ms in TS) crosses machine architectures, a
7-8 MIPS SPARC against a 2 MIPS 68020, and should not be quoted as a 4x win.

Text extraction from this PDF is a poor OCR of a scan. Code fragments in the `sumTo:` derivation
are garbled (`iffrue:` for `ifTrue:`, `got0` for `goto`, `l` for `1`). The prose is legible and
everything above is from prose or from unambiguous context; the exact benchmark ratio table on
page 11 is not reliably readable and its numbers have not been quoted here beyond what the
conclusion states in words.
