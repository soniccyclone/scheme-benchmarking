---
type: paper
title: "An Efficient Implementation of SELF, a Dynamically-Typed Object-Oriented Language Based on Prototypes"
description: Makes a language with no classes, no type declarations, and no variables (only message sends) run twice as fast as the fastest Smalltalk, using maps for storage layout and customization, message splitting, and type prediction to manufacture static type information the source never contained.
resource: knowledge/sources/chambers-ungar-an-efficient-implementation-of-self-oopsla-.pdf
tags: [type-feedback, procedure-inlining, customization, dynamic-typing, generational-gc, deoptimization]
authors: [Craig Chambers, David Ungar, Elgin Lee]
year: 1989
venue: "OOPSLA '89 (SIGPLAN Notices 25(10), 49-70); this copy is the reprint in Lisp and Symbolic Computation 4(3), 1991"
informs: [/techniques/type-feedback.md, /techniques/procedure-inlining.md, /techniques/customization.md, /techniques/generational-gc.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

The thesis is in the last line of the conclusions: "Researchers seeking to improve
performance should improve their compilers instead of compromising their languages." Every
prior attempt to make a dynamically typed OO language fast had compromised something.
Smalltalk-80 hard-wired `ifTrue:ifFalse:`, `whileTrue:`, `==`, `+`, and `<` into the parser
as special bytecodes, which means the source for those methods is documentation and
redefining them does nothing. Atkinson's Hurricane and Johnson's Typed Smalltalk added type
declarations, which hinders the reuse the language exists to provide.

SELF is a harder target than Smalltalk in three independent ways: no classes, so no
class-based inline caching or type inference; no variables, since every state access is a
message send; and user-defined control flow built from blocks, so even `if` is a send. The
paper gets 2x the fastest Smalltalk anyway, within 4-5x of optimized C, with full overflow
checks, bounds checks, and stack-overflow checks intact, and with a working source-level
debugger and sub-second edit-recompile turnaround. It matches Typed Smalltalk's performance
without any declarations, which is the paper's sharpest single result: the compiler
reconstructs everything the declarations would have told it.

# Mechanism

**Maps (section 3.1).** A prototype and everything cloned from it, differing only in
assignable slot values, form a *clone family*. All members share an immutable **map**. The
object holds two header words (mark word, map pointer) plus its assignable slot values,
nothing else. The map holds, per slot: name, whether it is a parent, priority, and a third
word that is either the slot's contents (constant slot), its offset in the object
(assignable data slot), or the index of the data slot it writes (assignment slot). Space for
a family of *n* objects with *s* slots of which *a* are assignable is `(2 + a)n + 5s + 8`
words, so 4n + 33 for a cartesian point, matching Smalltalk's per-object cost. Changing an
object's format or a constant slot's value mints a new map and starts a new family. This is
the hidden-class idea; maps are class-shaped at the implementation level and invisible at the
language level.

**Segregation (3.2).** Each Generation Scavenging space is split: byte arrays grow down from
one end, everything containing references grows up from the other. Reference scans therefore
never touch byte arrays and never parse object headers. A sentinel word past the end of the
space, chosen to match the scan criterion, removes the bounds check from the inner loop.
3 MB/s versus 1.6 MB/s for non-segregated Smalltalk on the same 68020. To recover the
*object* containing a matching reference, scan backward to the mark word, identified by a
dedicated tag.

**Tags.** 2-bit low tags on 32-bit words: integer immediate, heap-object reference, float
immediate (30 bits of IEEE), mark word. Integers need a shift to convert and nothing at all
to add, subtract, or compare.

**Customization (5.1).** Compile a *separate* machine-code version of a source method per
receiver map. Inside each version the type of `self` is a compile-time constant. This is the
lever the entire compiler rests on: it converts the dynamic receiver type into static
knowledge for free, since the compiler is invoked lazily on first call anyway.

**Message inlining (5.2).** With the receiver type known, do the lookup at compile time.
Then, by slot kind: method slot becomes an inlined body if short and non-recursive; block
`value` method becomes an inlined body, and if no use of the block object survives, the
closure creation is deleted; constant data slot becomes a literal; assignable data slot
becomes a load; assignment slot becomes a store. The last three are what make "everything is
a message send" free. All variable accesses inline away first.

**Primitive inlining (5.3).** Common primitives (integer arithmetic, comparison, array
access) are open-coded instead of called. Side-effect-free primitives with compile-time-known
arguments are executed at compile time, which is SELF's constant folding.

**Message splitting (5.4).** When a control-flow merge destroys type information, copy the
message *following* the merge back onto each incoming branch and postpone the merge. On
branches where the type is known, inline. On branches where it is not, emit a real send, so
semantics are preserved for all receivers.

**Type prediction (5.5).** When the receiver type is unknown, guess from the message name:
`+` and `<` predict integer, `ifTrue:False:` predicts `true`/`false`. Emit a run-time test
and conditional branch, then *use message splitting* on the two branches. The success branch
inlines; the failure branch does a real send. This is the whole of Smalltalk's hard-wiring,
recovered as an optimization rather than a language change, and it costs almost nothing to
implement because splitting and inlining already exist.

The worked `min:` example runs all five in sequence and lands on two compare-and-branch
sequences for two integers, from source that is nothing but message sends.

**Dependency-based invalidation (6.1).** Everything the compiler consults lives in maps, so
dependency links live there too. Four link kinds: the slot holding the method being compiled;
the slot matched by any inlined message; any parent slot traversed during a compile-time
lookup; and the map of any object searched *unsuccessfully*, in case a matching slot is added
later. The last two are the subtle ones and are what make the scheme sound. Links are
doubly-linked circular lists so removal on invalidation or map collection is cheap. Known
hole: a method invalidated while executing cannot be flushed, and the fix (recompile and
rebuild the stack) was unimplemented.

**Debugging (6.2).** Each compiled method carries scope descriptions, one per inlined
method or block, each pointing at its virtual caller and, for blocks, its lexical enclosure;
per slot it records either the compile-time value or the register/stack location. Plus a
bidirectional PC-to-bytecode map, which is many-to-many in both directions because inlining
collapses bytecodes onto one PC and splitting duplicates one bytecode across PCs.
Disambiguation rule: take the latest PC entry <= current PC, then the latest bytecode mapped
to it. This is the ancestor of every deoptimization mechanism since.

# Applicability

Requires dynamic compilation and a code cache, since customization multiplies code per
receiver type and only pays if compilation is demand-driven. Requires the ability to
invalidate, so it does not transfer to ahead-of-time compilation without a fallback path.

The stated failure modes are specific. Compile-time lookup fails entirely if any traversed
parent slot is assignable, i.e. under dynamic inheritance. Method *arguments* remain the
largest source of unknown types, since only the receiver is customized. The inliner's
stopping rule is a fixed bytecode-count cutoff, which the authors call "not a very good
algorithm." Type prediction hard-wires both message name and predicted type in the compiler,
so it is a static table, not feedback. Compile time is the real cost: 7 seconds for 900 lines
of the Stanford benchmarks, 3 seconds for Richards, which the authors concede is "not yet
fast enough for our interactive programming environment."

The remaining 4-5x gap to C is attributed to three causes in order: a weak register allocator
and peephole optimizer, the retained safety checks, and missing type information for
arguments and assignable slots.

# Relevance

This is the tradition our project sits in and it is worth being precise about why. Chez gets
its speed from *representation* decisions: flat closures, inline allocation, no
`procedure?` check on known calls, segmented stacks. SELF gets its speed from *manufacturing
type information that the program never stated*. Those are orthogonal, and our plan needs
both. Stages 5 through 8 are the SELF half: prove a value is a fixnum in range, prove a
flonum does not escape, and then use the proof to pick a cheaper representation.

Three specific transfers.

**Customization generalizes to specialization on any proven property, not just receiver
type.** We do not have receivers, but we do have the same problem, which is that a procedure
called with flonums from one site and generic numbers from another gets compiled once for the
worst case. Compiling a specialized entry point per proven argument shape, with the generic
version retained for correctness, is exactly this technique. The authors flag argument
customization as their own top open issue.

**Message splitting is how you defeat join-point information loss, and our interval and
Pentagon domains have precisely that problem.** Where the domains lose a bound at a merge, the
choices are widening (lose it) or splitting (duplicate the following code onto each branch
and keep it). Splitting is strictly more precise and costs code size. Worth knowing this
exists before we write the join operator, because the abstract-interpretation literature
tends to present widening as the only answer.

**Type prediction is the cheap version of everything we are building.** A static table saying
"`+` is probably fixnum, emit a guarded fast path" gets most of the win for none of the
analysis. It is our floor. If the interval and Pentagon domains do not beat a guarded
fast-path scheme by a clear margin on the benchmark kernels, they are not paying for
themselves and we should know that early. This is a useful control experiment, not a
competitor.

Two smaller things. The segregation trick (byte arrays at one end, references at the other,
sentinel instead of a bound check) is directly applicable to an flvector-heavy heap and
costs nothing. And the scope-description plus PC-map machinery is the honest answer to "how
do we debug after aggressive inlining"; we will need it, and it is cheaper to design in than
to retrofit.

# Notes

**Bibliography corrections, two.**

1. **Third author omitted.** The title page lists **Craig Chambers, David Ungar, and Elgin
   Lee**, all of the Computer Systems Laboratory, Stanford. The slug and any two-author
   citation drop Lee, who wrote the object storage system (his Engineer's thesis is reference
   16 and section 3 is largely his work). Running heads throughout read "CHAMBERS, UNGAR, AND
   LEE."

2. **Version mismatch, the kind the brief warns about.** The header reads "To be published
   in: LISP AND SYMBOLIC COMPUTATION: An International Journal, 4, 3, 1991, (c) 1991 Kluwer",
   with a footnote: "This paper was originally published in OOPSLA '89 Conference Proceedings
   (SIGPLAN Notices, 25, 10 (1989) 49-70)." So this artifact is the **1991 Kluwer journal
   reprint**, not the OOPSLA proceedings copy, and it is *not* textually identical: footnote 6
   is an addition stating that "since this paper was originally published, these performance
   numbers have improved significantly, by a factor of two or three," pointing at Chambers and
   Ungar's PLDI '90 iterative type analysis work. Page numbers run 57-96, not 49-70. Cite as
   OOPSLA '89, but if anyone quotes a page number from this PDF against the proceedings, it
   will not match.

**Do not confuse this with the companion paper.** Reference 6 is Chambers and Ungar,
"Customization: Optimizing Compiler Technology for SELF", PLDI '89. That is a different
work already in this bundle as
`chambers-ungar-customization-optimizing-compiler-technolog`. Section 5 here is explicitly a
*summary* of that paper ("originally published in [6]"). The unique content of *this* paper is
maps, segregation, object formats, the bytecode set, dependency-based invalidation, and the
debugging information. If both documents exist in `works/`, the split should follow that line.

**Where it is dated or oversold.** The MiMS metric (millions of messages per second) proposed
in section 7 went nowhere, and deservedly. It is unnormalized across languages with
different message granularity, and the paper's own definition has to carve out an exception
for local slot access. Type prediction as implemented is a hard-coded table; the authors
themselves note that "a more dynamic implementation that used dynamic profile information
... might produce better, more adapting results," which is precisely the Hölzle-Ungar
polymorphic-inline-cache work that followed and is the version everyone actually uses today.
Read the type prediction section as the seed of type feedback rather than as the technique.

The performance comparison is apples-to-oranges in one respect the paper is upfront about:
Smalltalk times are real time, SELF and C times are CPU time. It argues the two coincide for
SELF and C on that machine, which is plausible but unverified for the Smalltalk numbers.
