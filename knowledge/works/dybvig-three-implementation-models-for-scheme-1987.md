---
type: paper
title: "Three Implementation Models for Scheme"
description: Develops the stack-based implementation model for Scheme, in which call frames and variable bindings live on a true stack and first-class functions, assignment and continuations are paid for by display closures, boxes and snapshot continuations respectively, plus a string-based model for the FFP reduction machine.
resource: knowledge/sources/dybvig-three-implementation-models-for-scheme-1987.pdf
tags: [display-closures, stack-allocation, first-class-continuations, assignment-conversion, virtual-machine]
authors: [R. Kent Dybvig]
year: 1987
venue: "PhD dissertation, University of North Carolina at Chapel Hill (TR 87-011)"
informs: [/techniques/closure-conversion.md, /techniques/stack-segment-continuations.md, /techniques/storage-class-assignment.md, /techniques/escape-analysis.md, /techniques/assignment-conversion.md]
pipeline_stage: 08-represent
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Kills the belief that first-class closures and first-class continuations force heap allocation
of call frames and environments. The dissertation builds a stack-based model in a sequence of
seven small, individually verifiable steps, each with working Scheme code for the compiler and
the virtual machine, ending at the model Chez Scheme shipped in 1985. Three data structures do
all the work: the *display closure* (a flat vector of code pointer plus copied free-variable
values), the *box* (a one-cell heap object holding an assigned variable's value), and the
*snapshot continuation* (a copy of the live stack). The design principle behind all of it is
stated plainly in Chapter 6, and it is the reason the model works: make the common operations
fast even if that means the rare ones get slower, and support an awkward feature inefficiently
rather than leaving it out.

The measurement that motivates the whole thing is in the first paragraph of Chapter 4. Profiling
C-Scheme, the author's own heap-based system, showed more than half of running time in variable
lookup and function call, and an insignificant fraction in creating or invoking continuations.
The heap-based model had optimized the operations nobody performs.

Second contribution, unimplemented then and irrelevant now except as an idea: a string-based
model that compiles Scheme into a purpose-designed FFP language for Magó's FFP machine, a
small-grain string-reduction multiprocessor.

# Mechanism

The virtual machine starts with five registers: `a` accumulator, `x` next expression, `e`
environment, `r` current value rib, `s` stack. Heap-based instruction set is twelve
instructions: `halt refer constant close test assign conti nuate frame argument apply return`.
A call frame is (return expression, environment, rib, next frame); an environment is a rib cage,
a list of (variable rib . value rib) pairs. Arguments are evaluated last to first so `cons`ing
onto the rib puts them in order. Tail calls are handled by not emitting `frame`, detected by
`(eq? (car next) 'return)`.

First improvement, still heap-based: replace variable names with `(rib . elt)` lexical addresses
computed by a compile-time environment. Variable ribs disappear from the runtime environment,
and `lookup` becomes two counted walks instead of two searches.

The stack model is then built in five steps.

*Dynamic chain to the stack.* Call frames go on a true stack. `conti` copies the live stack into
a fresh vector (`save-stack`); `nuate` copies it back (`restore-stack`). The justification is
amortization, argued rather than measured: a program with no continuations heap-allocates no
frames at all; a program with few calls has small stacks to copy; a program that alternately
grows and shrinks the stack pays for only the frames a continuation actually captures. The one
adversarial case is named honestly: build a deep stack, capture several continuations while it
is intact, then return through it without further calls. Then every frame ends up in the heap
more than once. (The footnote notes PC Scheme's alternative, moving the stack into the heap and
leaving a link, which requires copying back when the `call/cc` argument returns normally too.)

*Static chain to the stack.* Arguments go directly into the call frame. Frame layout is chosen
deliberately: dynamic link pushed first, then return address, then arguments, then static link.
That order is what makes the tail-call shift cheap; with the header above the arguments, a tail
call would have to save and rebuild it.

*Display closures.* A traditional display is an array of pointers to frames. Take two steps
further: point at individual *values* rather than frames, then store the values themselves
rather than pointers. Now the closure is self-contained and the static chain need not survive on
the stack at all, which is exactly what first-class functions require. A closure is a vector:
slot 0 is the code, slots 1..n are the free-variable values. `find-free` computes the free set
by structural recursion carrying the bound set; `collect-free` emits a `refer` plus `argument`
per free variable to push the values, and `close n body` builds the vector from the top n stack
items. Variable reference splits into `refer-local n` (index off the frame pointer `f`) and
`refer-free n` (index off the current closure `c`). The compile-time environment collapses to a
pair: `(locals . free)`, so lookup is two flat searches, and reference is one instruction.

*Boxes.* With bindings on the stack, a binding can exist in several places at once: the live
stack, one or more snapshot continuations, and one or more display closures. That is harmless
until someone assigns it. Rather than run-time bookkeeping to find and update every copy,
allocate one heap cell per *assigned* variable and copy the pointer instead of the value.
`find-sets` finds which of a lambda's formals are assigned; `make-boxes` emits a `box n`
instruction per assigned formal, executed by the callee on entry, before its body. Reference to
a boxed variable is the normal reference plus an `indirect`; assignment is `assign-local` or
`assign-free`, always through `set-box!`. Only assigned variables pay. Lexical scoping is what
makes this decidable at compile time; without it the system would have to box everything
pessimistically.

*Tail calls.* Since the frame header does not depend on the callee, a tail call reuses it. The
callee's arguments have already been pushed above the caller's, so a `shift n m` instruction
moves the top n cells down m places and drops the stack pointer by m.

The final VM has eighteen instructions and four registers (`a x f c s`, plus the implicit stack).

Section 4.7 lists the optimizations a real compiler adds on top, and this is the roadmap Chez
actually followed: global variables referenced through boxes wired directly into the code rather
than carried in closures; direct lambda invocations (`let`) compiled as frame extensions rather
than closure creation plus call; self tail recursion compiled to a direct jump when the name is
never assigned; stack allocation or elimination of closures that provably do not escape; and
recognizing `call/cc` used purely as a nonlocal exit, compiling it to a label and a jump instead
of a stack copy.

# Applicability

The model needs lexical scoping (to decide boxing and free sets statically), and it needs the
compiler to compute free variables and assigned variables per lambda. It does not need a type
system, garbage collector cooperation beyond ordinary heap objects, or hardware support.

Costs, measured in Appendix A on fib computing F(10) under two instrumented VMs, allocation in
cells and memory references:

| program | heap alloc | heap refs | stack alloc | stack refs |
|---|---|---|---|---|
| `fib` (calls only) | 22302 | 45806 | 0 | 19145 |
| `fibk` (CPS, closures) | 22956 | 48199 | 617 | 23261 |
| `fibc` (`call/cc`) | 25426 | 52521 | 8023 | 53945 |
| `fib!` (assignments) | 22592 | 46889 | 177 | 19793 |

`fibc` is the one case where the stack model loses on memory references, and it loses by three
percent while still allocating a third as much. That is the shape of the tradeoff.

The VAX instruction sequences in A.2 are the more useful numbers because they are per-operation.
Variable reference: heap-based needs m+n+2 memory references and up to m+n instructions for
lexical address (m,n); stack-based needs one instruction and one or two references, always.
Non-tail call with n arguments: heap-based 5n+9 instructions, 2n+5 references, 2n+4 cells
allocated; stack-based n+3 instructions, n+3 references, zero allocated. Tail call: heap-based
5n+1 instructions and 2n cells; stack-based n+2 instructions and no allocation when the caller
had no arguments, 2n+2 instructions and 3n+1 references when it did (the shift). Closure
creation: heap-based always 2 cells; display closure n+1 cells, so it is *cheaper* for the
common cases n=0 and n=1, and n=0 closures can be built at compile or load time. Continuation
creation: heap-based 4 instructions and 2 cells; snapshot 7 instructions, 2n+2 references and
n+2 cells for a stack of n. Continuation application: 2 instructions heap-based, 4 instructions
and 2n+2 references stack-based.

Where the model is weak, and where the successor work goes. Snapshot continuations are
unbounded: cost is proportional to live stack depth on both capture and reinstatement, and
repeated capture of a deep stack retains many copies. The dissertation's own text at page 113
gestures at a segmented stack as the fix without developing it. That fix is Hieb, Dybvig and
Bruggeman 1990, which makes capture constant-time and bounds reinstatement, and it is the
missing piece of this dissertation. Read the two together; neither is complete alone.

# Relevance

This is the specification for our `08-represent` stage, and it is unusually literal: the
compiler and VM are given as executable Scheme, so the passes can be transcribed and then
optimized rather than designed from scratch.

Four decisions to take directly. Display closures, not environment chains: a flat vector of
copied values, closure slot indices assigned at compile time, free variables computed per
lambda. Assignment conversion by boxing only the assigned variables, driven by a `find-sets`
pass, with the *callee* creating the boxes on entry because the caller cannot know which of its
arguments the callee assigns. The `(locals . free)` two-level compile-time environment, which
makes variable reference a single indexed load off one of two registers. And the frame layout
with the header below the arguments, so tail calls are a shift and nothing else.

Where we diverge from 1987. Snapshot continuations should not be implemented; go straight to
stack segments. The `shift` on tail calls is unnecessary when the callee's arity matches the
caller's, which after inlining is the common case for self-recursive loops, and Section 4.7.3's
direct-jump compilation for self tail recursion removes it entirely. That is the single highest
value optimization in Section 4.7 for us, because it turns Scheme loops into machine loops that
`07-loops` and `10-vectorize` can then analyze as loops.

The escape-analysis connection is worth stating precisely, because this is where our analysis
budget buys something. Section 4.7.4 says a closure can be stack-allocated or elided when the
compiler can prove it does not outlive its creator. Section 4.5 says a box can be skipped when
an assigned variable occurs free in no closure *and* no continuation can be captured in its
scope. The first condition is a syntactic check on free-variable lists. The second, the
dissertation says, needs significant analysis because any call outside the variable's scope
might capture a continuation. That is exactly a k-CFA-style question, and it is a concrete
example of what higher-order flow analysis would buy us: elimination of boxes, not just
inlining. Chez did not have that analysis in 1987 and mostly still relies on the syntactic
check.

The Chapter 6 principle is the one to write on the wall. The heap-based model made the least
frequent operations (continuation capture and invocation) the most efficient, at the cost of the
most frequent ones (variable reference and call). Any time our pipeline makes an analysis
decision, ask which frequency class it optimizes.

# Notes

Title, author, degree and year verified against the title page: "Three Implementation Models for
Scheme", R. Kent Dybvig, University of North Carolina at Chapel Hill, 1987, under the direction
of Gyula A. Magó. The bibliography's description ("heap, stack and string models. The stack
model is why Chez is fast") is accurate. The bibliography records no venue; the correct citation
is a UNC Chapel Hill PhD dissertation, and the technical report number, TR 87-011, is given in
Hieb, Dybvig and Bruggeman's reference [6] rather than on this document's own title page.

Two internal cross-reference errors in the dissertation, both on page 113 (Section 4.7's opening
paragraph). It says "the use of a segmented stack (Section 4.5) and the avoidance of boxed
variables (Section 4.7)". Section 4.5 is about boxes and does not discuss segmented stacks at
all; segmented stacks are not in this dissertation. And "Section 4.7" is the section doing the
citing. Read that sentence as forward references to work that had not been written yet, which
became the 1990 PLDI paper. Also on page 47, "The improvement described in Section 3.4" should
read 3.5.

A real bug in the example code, Section 2.3.1, the `stack` object:
`[(pop) (let ([x (car s)]) (set! x (cdr s)) x)]`. The assignment should be `(set! s (cdr s))`.
As written, `pop` never removes anything. It is an example, not part of any model, but anyone
transcribing the code will inherit it.

Historically the interesting bit is Chapter 1's citation of the 1982 T paper: "escape procedures
are not valid outside the dynamic extent of the CATCH-expression which creates them; this ensures
that the control stack behaves in a stack-like way, unlike in Scheme, where the control stack must
be heap-allocated." Yale deliberately weakened the language to get a stack. This dissertation and
the 1986 Orbit paper together retract that concession. Cardelli's Functional Abstract Machine
arrived at essentially the same closure object independently and at about the same time, but for
ML, which has no assignment (it has `ref` cells the programmer writes explicitly) and no
continuations, so he needed neither boxes nor snapshots.

Where it is dated. Chapter 5 is a third of the dissertation and it targets a machine that was
never built. Read it for one transferable idea (compile a high-level language to a
purpose-designed intermediate language and implement *that* in the machine's microcode, rather
than targeting the machine's existing assembly language) and for the environment-trimming
technique, which is display-closure logic applied at every expression rather than only at lambda,
and which is a sharper version of live-variable-driven environment minimization than most
compilers do. The rest is FFP machine engineering.

Where it oversells, mildly: "Chez Scheme is among the fastest available Lisp systems for standard
computer architectures" is supported by "published benchmark figures for existing Lisp systems"
with no table and no citation. The Appendix A numbers are honest and are about the *models*, not
about Chez.
