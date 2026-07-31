---
type: paper
title: "LLVM: A Compilation Framework for Lifelong Program Analysis & Transformation"
description: Defines a low-level, typed, SSA-form code representation plus a compiler architecture that keeps that representation resident through link time, run time and idle time, so analysis and optimization can happen at any point in a program's life.
resource: knowledge/sources/lattner-adve-llvm-a-compilation-framework-for-lifelong-pro.pdf
tags: [intermediate-representation, ssa, type-system, link-time-optimization, code-generation]
authors: [Chris Lattner, Vikram Adve]
year: 2004
venue: "CGO 2004"
informs: [/techniques/ssa-construction.md, /techniques/instruction-selection.md, /techniques/points-to-analysis.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Two things, and the second is the one people forget. The first is a code representation: an
abstract RISC in SSA form, 31 opcodes, with a language-independent type system, a
type-preserving address-arithmetic instruction, and two instructions that expose exceptional
control flow in the CFG. The second is an argument that five capabilities (persistent program
information, offline code generation, end-user profiling, a transparent runtime model, and
uniform whole-program compilation) are individually available in prior systems but never all
five together, and that a low-level typed IR retained for the program's whole lifetime is what
buys all five at once.

The measured claims are narrow and honest. Type information is *checkable* for 68 percent of
static memory accesses across SPEC CPU2000 C, near 100 percent for disciplined code. The
bitcode is about the size of x86 and 25 percent smaller than SPARC despite carrying types,
SSA and an infinite register set. Interprocedural passes over whole programs cost fractions of
a second against tens of seconds for GCC to compile the same program. Notably absent: any
claim about the quality of generated code. The paper says so explicitly.

# Mechanism

Instruction set. Three-address, load/store, infinite typed virtual registers in SSA form, with
an explicit `phi`. Memory is deliberately *not* in SSA form, because a single store through a
pointer may modify many locations and no compact explicit representation exists. Every function
is an explicit CFG of basic blocks, each ending in exactly one terminator (`br`, `ret`,
`unwind`, `invoke`), and each terminator names its successors. Opcode count stays at 31 by
overloading on operand type and by refusing redundancy: no `not` or `neg`, they are `xor` and
`sub`.

Type system. Primitives with fixed sizes (void, bool, signed and unsigned 8 to 64 bit ints,
f32, f64) plus exactly four derived types: pointer, array, structure, function. The claim is
that these four are enough to express the operational behavior of high-level types, and enough
for the analyses that consume types (field-sensitive points-to, call-graph construction, scalar
promotion of aggregates, field reordering, array dependence). C++ classes with inheritance
become nested structures; a vtable is a global constant array of typed function pointers.

Declared types are not trusted, because the source language may not be type-safe. `cast` is the
only way to change a type, so a cast-free program is type-safe modulo memory errors, and a
pointer analysis is used to decide which declared types are actually reliable. LLVM's is Data
Structure Analysis: flow-insensitive, field-sensitive, context-sensitive, using declared types
speculatively and checking conservatively that all accesses to an object agree with them.

Address arithmetic. `getelementptr` computes the address of a sub-element of an aggregate from
a typed pointer and an index list, preserving the type. `load` and `store` take a single pointer
and never index. This is the design decision that lets reassociation and redundancy elimination
see address computations without destroying the type information they depend on.

Memory model. `malloc`, `free`, `alloca` are instructions, and they are typed. All addressable
objects are explicitly allocated; a global definition names an address, not an object. There is
no address-of operator because there is nothing to take the address of implicitly.

Exceptions. `invoke` is a call that additionally names a handler block; `unwind` logically pops
activation records until it removes one created by an `invoke`, then branches to that invoke's
handler. Language-specific semantics (which catch clause matches, exception object lifetime)
live in a runtime library called from generated code; the *control flow* stays in the CFG. The
payoff is concrete: because the unwinding branch is in the caller's CFG, inlining can turn an
unwind into a direct branch, and interprocedural analysis can delete unreachable handlers. The
same two instructions implement C `setjmp`/`longjmp`.

Architecture. Front ends emit bitcode; the linker performs interprocedural optimization over the
whole program; a code generator runs offline at link or install time and embeds a copy of the
bitcode in the executable along with lightweight instrumentation; a runtime optimizer detects hot
loop regions, forms traces, re-optimizes them in LLVM form and regenerates native code into a
software trace cache; an idle-time reoptimizer uses end-user profiles. The front end is told not
to bother constructing SSA: allocate locals with `alloca` and let the stack-promotion and
scalar-expansion passes build SSA.

# Applicability

What it needs. A pointer analysis before declared types can be believed, since the
representation itself guarantees nothing. Whole-program availability at link time for the
interesting passes, which shared and system libraries can defeat. A front end willing to lower
everything: C complex numbers, structure copies, unions, bit-fields, variable-sized arrays and
`setjmp`/`longjmp` all have to be lowered before LLVM sees them.

What it explicitly does not do. It is not a universal IR and the authors say so. No high-level
language constructs, so no language-dependent transformations. No runtime system or object
model, so a language needing one implements it in LLVM. No type-safety or memory-safety
guarantee. No machine-dependent features, so it must be lowered further before a back end can
use it. Whether languages with sophisticated runtimes (their example is Java) benefit at all is
called an open question.

Where the type story leaks: 176.gcc lands at 43.7 percent typed accesses, 177.mesa at 12.5
percent, 253.perlbmk at 30.3 percent. The named causes are custom allocators, the same object
being described by different struct types in different places, and imprecision in DSA. If a
program does the things real C programs do, the type information is present but unusable for
half the accesses.

# Relevance

We rejected LLVM as a back end. This paper is the bill of what we gave up, and it is worth being
precise about it rather than comfortable.

Given up, and expensive to rebuild: a well-tested instruction selector and register allocator for
multiple targets; a mature SSA infrastructure with the passes already written; the offline/JIT
duality; and the ability to link Scheme code against C code in one optimizable unit.

Given up, and cheaply replaced or not wanted: the type system. LLVM's four derived types exist to
recover, by analysis, structure information that C erased. We do not erase it. A Scheme compiler
with declaration-anchored inference knows its representations by construction, so the whole
`cast` plus DSA plus "68 percent of accesses are checkable" apparatus is solving a problem we do
not have. Likewise the exception mechanism: `invoke`/`unwind` is a stack-unwinding model, and it
is the wrong primitive for full `call/cc`. Hieb, Dybvig and Bruggeman's stack segments cannot be
expressed on top of `invoke`/`unwind` without leaving the abstraction, which is the specific
reason owning the back end puts `call/cc` back on the table.

What to steal. The offline/in-memory/textual equivalence with no semantic conversion between them
is a debugging discipline, not a feature, and it is worth adopting for our own IR from the start.
The advice to let the front end use stack slots and have a promotion pass build SSA is the right
division of labor and it is what Braun et al. formalize. `getelementptr`'s separation of address
computation from access, so that reassociation sees the arithmetic without losing the aggregate
structure, is directly applicable to how we represent vector and record accesses feeding
`10-vectorize` and `09-alias`. Timing interprocedural passes against a full GCC compile, and
reporting representation size, are the right things to measure about an IR.

The comparison to keep in view: LLVM's design pressure is *recovering* high-level structure from
low-level code across many languages. Ours is *retaining* structure that a single language already
gives us. Those are different problems, and adopting the artifact built for the first would have
imported its compromises.

# Notes

Title and authors verified against page 1: Chris Lattner and Vikram Adve, University of Illinois
at Urbana-Champaign. The title page carries no venue or date; this is the author copy of the
CGO 2004 paper (the URL in the bibliography is `2004-01-30-CGO-LLVM.pdf`, matching). The
bibliography's description, "the reference architecture we are deliberately not using, worth
understanding before rejecting", is accurate and the year is right, but note that the venue is not
printed on the document itself.

Historically interesting and easy to miss twenty years on: at the time of writing LLVM supported
only C and C++, targeted SPARC V9 and x86, and the idle-time reoptimizer described in Section 3.6
did not exist (footnote 1 says so). Section 4.2.1 says other groups were "exploring" LLVM. The
paper is a design document with early measurements, not a report on a mature system, and reading
it as a description of LLVM-as-it-is-now will mislead.

The claim that no previous system provides all five capabilities is a scorecard argument, and
scorecards are chosen by the people who win them. Each row is defensible; the framing is
promotional.

One prediction aged badly in an instructive way. Section 4.1.2 asserts that "similarly clean LLVM
implementations exist for most constructs in other language families like Scheme, the ML family,
SmallTalk, Java and Microsoft CLI," with preliminary work on JVM and OCaml front ends. Two decades
of experience says the hard parts for those families are exactly the ones LLVM declined to
represent: precise garbage collection over an arbitrary stack layout, and first-class control.
Both have needed extensions bolted on rather than clean implementations, which is the empirical
support for our decision to own the back end.
