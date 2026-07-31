---
type: paper
title: "An Incremental Approach to Compiler Construction"
description: Builds a Scheme-to-x86 compiler in 24 steps, each of which is a complete working compiler for a growing subset, with a test-driven loop and a concrete tagging and calling-convention design.
resource: knowledge/sources/ghuloum-an-incremental-approach-to-compiler-construction-2.pdf
tags: [scheme, code-generation, tagged-representation, closure-conversion, bootstrap, x86]
authors: [Abdulaziz Ghuloum]
year: 2006
venue: "Scheme and Functional Programming Workshop 2006 (University of Chicago TR-2006-06, pp. 27-37)"
informs: [/techniques/closure-conversion.md, /techniques/storage-class-assignment.md, /techniques/instruction-selection.md]
pipeline_stage: 13-assemble
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

A methodology claim with a worked instance. The claim: the reason compilers seem hard is that
books present a finished pass structure, so nothing works until the last pass is written.
Ghuloum inverts it — pick a subset small enough to compile directly to assembly, write the
tests, write the compiler, refactor, then grow the subset by one small step. Every step ends
with a *complete working compiler* that emits real x86 and links against a C driver. Twenty-
four steps take you from "the language of fixnums" to a compiler capable of compiling an
interactive evaluator, covering most of R5RS.

The instance is the valuable part: a specific, coherent set of representation and
calling-convention decisions for a Scheme on 32-bit x86, each introduced at the moment it is
forced. There is no analysis and no optimization anywhere in the 24 steps, which is the point
— it isolates the irreducible core of "make Scheme run on metal."

# Mechanism

**Tagging.** Low bits carry type. Fixnums: mask `11b`, tag `00b`, so 30 value bits and
arithmetic works without untagging. Characters: 8-bit tag `00001111b`. Booleans: 7-bit tag
`0011111b` with a 1-bit value. Empty list: `00101111b`. Heap pointers get a 3-bit tag — pairs
`001`, vectors `010`, strings `011`, symbols `101`, closures `110` — which requires every
heap object to be allocated at an 8-byte boundary so the low three bits are free. The tag
choices are not arbitrary: `integer->char` is a shift by 6 plus an or, because the fixnum and
char tags were picked to make it so.

**Registers and memory.** `%eax` is the value register. `%esi` is the allocation pointer,
bumped past each object and realigned to the next 8-byte boundary for variable-length objects.
`%edi` is the closure pointer. `%esp` is the stack; `0(%esp)` holds the return point and
everything above it (negative offsets) is free. The code generator threads a *stack index*
`si`, starting at −4 and decremented by 4 per saved value, which is the entire "register
allocator" — binary primitives compile as: evaluate operand 2, `movl %eax, si(%esp)`, evaluate
operand 1 with `si - wordsize`, then combine.

**Calling convention.** Scheme arguments go *above* the return point; C arguments go *below*
it in reverse order (Figure 4), so `foreign-call` evaluates in reverse and adjusts `%esp`
around the call. The SysV i386 ABI guarantees callees preserve `%edi`, `%esi`, `%ebp`, `%esp`,
so the allocation and closure pointers survive a foreign call for free. Argument count travels
in `%eax`, which does double duty as the arity check and as the input to variadic list
construction.

**Closure conversion, in two mechanical steps.** First, annotate every `lambda` with its free
variables. Then rewrite into `labels`/`code`/`closure`:

```scheme
(let ((x 5)) (lambda (y) (lambda () (+ x y))))
=>
(labels ((f0 (code () (x y) (+ x y)))
         (f1 (code (y) (x)  (closure f0 x y))))
  (let ((x 5)) (closure f1 x)))
```

A `closure` form is a `vector` call whose slot 0 is a code label. `code` binds formals to the
first stack slots and free variables to displacements off `%edi`. `funcall` skips *two* stack
slots (one for the saved closure pointer, one for the return point), evaluates the operator
into `%edi`, and does an indirect call through the closure's first cell.

**Tail calls.** Evaluate arguments as usual, put the operator in `%edi`, then copy the
arguments down over the current frame and `jmp` indirect rather than `call`. Ghuloum names
this as the simple-but-wasteful version and points at greedy shuffling as the fix.

**Assignment conversion.** Assignable variables cannot live on the stack because closures have
indefinite extent, and copying a value into multiple closures breaks `set!` semantics. So each
assignable variable becomes a heap-allocated 1-element vector; `set!` becomes `vector-set!`,
reference becomes `vector-ref`.

**Complex constants.** `(eq? (f) (f))` must be true for a quoted structure, so constants
cannot be rebuilt per call. Naively lifting them into an enclosing `let` makes them free
variables and bloats every enclosing closure. The right answer is a global data label plus
`constant-ref` / `constant-init`, initialized once before the program runs. The same
machinery, with `primitive-ref` / `primitive-set!`, gives separately compiled libraries — the
alternative of wrapping user code in a giant `letrec` is rejected because mixing library and
user code makes the compiler undebuggable.

**Error checking, two strategies.** Open-code the check at every primitive call (`car` becomes
`movl %eax,%ebx; andl $7,%ebx; cmpl $1,%ebx; jne L_car_error; movl -1(%eax),%eax`), or restrict
the compiler to *unsafe* primitives and make safe primitives real procedure calls that check
themselves. The second is slower and much simpler, and Ghuloum recommends it for the tutorial.

Steps 17-24 build outward with no architecture change: variadic procedures (loop building a
list from the stack), `apply` (splice a list onto the stack via an `L_apply` label), ports as
tagged vectors with a 4096-byte buffer, `write`/`display` in Scheme, a tokenizer as an explicit
DFA, a 40-line recursive-descent reader, and an environment-passing interpreter reusing the
compiler's first pass.

# Applicability

Preconditions: none beyond a Scheme to write the compiler in and gcc to assemble and link. The
compiler *is* a Scheme procedure `compile-program` taking an s-expression, which is what makes
the test harness trivial — compile, link with a C driver, run, diff against an expected output
string.

Where it deliberately stops: no register allocation (everything spills to the stack), no
inlining, no constant folding, no letrec optimization, no GC (the heap is preallocated and
never overflows), no stack overflow handling, no `call/cc`. Section 4 lists these as the next
axes, with citations, and is effectively a roadmap.

The costs of the simplifications are stated concretely, and the letrec one is the biggest:
proper letrec treatment (Waddell-Sarkar-Dybvig) would make most letrec-bound variables
unassignable (killing heap boxes), eliminate closures with no free variables, turn indirect
calls into direct calls to known labels, and drop the procedure check, the argument-count
check, and the closure re-evaluation on recursive calls. That is seven wins from one pass.

Also 32-bit x86 specific throughout: `%eax`/`%esi`/`%edi`, 4-byte words, 30-bit fixnums, SysV
i386 ABI. Every number in the tagging scheme changes on x86-64.

# Relevance

This is the map for the part of our build that the CUJ compresses into "stage 13: x86-64 +
AVX-512 encoding, emit an object file." Everything between a working core language and a
running binary — tags, the C driver boundary, closure layout, the two calling conventions, the
stack discipline — is here in executable detail, and none of it is in the analysis papers.

The sequencing lesson is worth taking literally. Our CUJ orders passes 01 through 13 and puts
the interesting work (intervals, pentagon, vectorization) in the middle. Ghuloum's argument is
that you should be able to run *something* from day one, which means building a degenerate
version of stages 11-13 before stages 05-10 exist at all. Concretely: get `(+ 1 2)` compiling
to an object file that runs, with the stack-index code generator and no register allocation,
and only then start on the abstract domain. Otherwise stages 05 and 06 are being written
against an emitter that has never emitted anything.

Two specific decisions to inherit and one to reject. Inherit the tagging discipline — 3-bit
pointer tags with 8-byte alignment, and tag choices selected so conversions are shifts. Our
stage 08 storage-class table already assumes "proven fixnum, bounds fit 61-bit tag," which is
this scheme widened to 64-bit, so the interaction between tag width and the untagged-loop-index
case is exactly Ghuloum's `integer->char` problem in another costume. Inherit the
`constant-ref`/`primitive-ref` global-label approach, since it is what makes separate
compilation and a real library possible without the closure bloat.

Reject the stack-index code generator as anything but a bootstrap. Ghuloum himself flags it:
`(+ e 4)` becomes `(let ((t0 e)) (+ t0 4))` with a pointless store and reload. That is the
exact opposite of what stage 08 and stage 12 are for. Useful as the thing to beat, and as the
fallback path when a value has no register home.

The paper also confirms two of our dependencies from the inside. It cites Burger-Waddell-Dybvig
greedy shuffling as the fix for its own tail-call copying, and Waddell-Sarkar-Dybvig letrec as
the highest-payoff single pass to add. Both are in this bundle, which is a good sign the
bibliography is coherent.

# Notes

**Identity and venue.** Title page: *An Incremental Approach to Compiler Construction*,
Abdulaziz Ghuloum, Department of Computer Science, Indiana University. Page footers read
"Scheme and Functional Programming, 2006" and page 1 carries "Proceedings of the 2006 Scheme
and Functional Programming Workshop, University of Chicago Technical Report TR-2006-06,"
pages 27-37. So this is the *workshop paper*, not the widely circulated 100-page extended
tutorial ("Compilers: Backend to Frontend and Back to Front Again"). The workshop paper
summarizes the 24 steps in about a paragraph each; the tutorial is what people actually work
through. The trailing `-2` in the slug is unexplained and may indicate a second fetch of the
same document. Anyone expecting the tutorial from this slug will be disappointed — the paper
points at the author's IU website for it, a URL that has been dead for well over a decade.

The paper is a period piece in one respect that matters: it is 32-bit x86 throughout, written
in 2006, and the register allocation advice cites Traub-Holloway-Smith linear scan. Nothing is
wrong, but every constant needs doubling and the ABI section needs rewriting for x86-64 (six
integer argument registers, different callee-saved set, red zone). Do not copy the stack
layout diagrams verbatim.

One genuine flaw in the exposition: step 3.16 presents open-coded primitive checks *and* the
safe-primitive-call alternative, then recommends the latter, but steps 17 onward assume the
open-coded fast paths exist when discussing performance. The two strategies are not reconciled,
and a reader following the tutorial will hit the seam.

The framing in the introduction is polemical and mostly earned. Quoting Wirth on postulating a
fictitious architecture, and Muchnick on restricting the book to languages "well suited for
compilation," to argue that the textbooks route around exactly the problems a Scheme
implementor has, is a fair hit. It is also the paper's whole novelty claim — there is no new
technique here, and Ghuloum does not pretend otherwise.
