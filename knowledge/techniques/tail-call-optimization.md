---
type: technique
title: Proper tail calls
description: Push a return address when a form is evaluated whose value an enclosing form needs, not when a procedure is called, so a tail call is a jump that allocates nothing; requires lexical scoping and is a Scheme guarantee rather than an optimization.
tags: [tail-calls, calling-convention, lexical-scoping, loop-representation, stack-discipline]
sources:
  - resource: /works/steele-lambda-the-ultimate-declarative-1976.md
  - resource: /works/steele-sussman-lambda-the-ultimate-imperative-1976.md
  - resource: /works/sussman-steele-scheme-an-interpreter-for-extended-lambda-c.md
  - resource: /works/steele-rabbit-a-compiler-for-scheme-1978.md
  - resource: /works/abelson-sussman-sicp.md
  - resource: /works/dybvig-three-implementation-models-for-scheme-1987.md
  - resource: /works/dybvig-et-al-the-development-of-chez-scheme-icfp-2006.md
  - resource: /works/hieb-dybvig-bruggeman-representing-control-in-the-presence.md
  - resource: /works/ghuloum-an-incremental-approach-to-compiler-construction-2.md
  - resource: /works/flanagan-sabry-duba-felleisen-the-essence-of-compiling-wit.md
implemented_by: [/implementations/chez.md]
absent_from: [/implementations/sbcl.md]
pipeline_stage: 11-select
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

A call in tail position should cost a jump and consume no stack, so that iteration written as
recursion runs in constant space. Scheme requires this; ANSI CL does not, and CL
implementations that do it treat it as an optimization they may silently decline. The
engineering question is what has to be true of the calling convention, the binding discipline
and every downstream pass for the property to hold uniformly rather than as a peephole that
sometimes fires.

# Mechanism

**The reframing.** Convention saves the return address when a function is *called*. Steele
saves it when a *form is evaluated whose value some enclosing form needs*. Under that
discipline a tail call pushes nothing and inherits its caller's return address, and `PUSHJ`
stops being the calling primitive: it becomes a peephole fusion of `PUSH [L]; GOTO f`. The MIT
folklore "JRST hack" for tail recursion is reclassified as the general case and the
stack-pushing call as the special case. The hardware justification is two PDP-10 instructions:
`PUSHJ P,FOO` followed by `POPJ P,` is equivalent to `JRST FOO` except that no stack slot is
used.

Section 1.5 of *Ultimate Declarative* finishes the argument by induction over the four shapes a
procedure body can take (trivial value, `IF`, `LABELS`, call): a procedure definable in Scheme
*never pops its own return address*. Only primitives inexpressible in the language pop. Steele
offers that not as an optimization but as the reason the language looks functional at all.

**The storage-side statement**, from Sussman and Steele 1975, is the one to write tests
against. A control frame is built only when "further computation would result in losing
information which might be necessary," which is only when a value must come back. Applying a
lambda expression is not such a case, so no frame is created. `SAVEUP` conses
`(**EXP** **UNEVLIS** **ENV** **EVLIS** retag **CLINK**)` onto the frame chain, and `**VAL**`
is deliberately not saved, which is what lets a value survive frame restoration.

**The evaluator statement.** SICP's framing is that tail recursion is a property of the
evaluator, not of the source syntax, which is why chapter 5 discards the metacircular evaluator:
it inherits control structure from the host and so says nothing about where stack space goes. In
the explicit-control evaluator the entire implementation is one economy, `ev-sequence-last-exp`
*restoring* `continue` before jumping to `eval-dispatch`, so the last expression of a body
returns straight to the caller's continuation. The book then exhibits the naive alternative, a
uniform save/restore cycle plus an `ev-sequence-end` label, and demonstrates that it converts
constant-space iteration into linear. In the compiler, `compile-proc-appl` splits on
`target = val` crossed with `linkage = return`, and the (val, return) case emits only
`(assign val (op compiled-procedure-entry) (reg proc))` and `(goto (reg val))`, with no
`continue` setup at all. That is the tail call.

**The machine-level version.** With frames on a real stack, a tail call reuses the caller's
frame header, which is why Dybvig chooses the frame layout he does: dynamic link, then return
address, then arguments, then static link, so the header sits *below* the arguments and a tail
call need not save and rebuild it. The callee's arguments are already pushed above the
caller's, so a `shift n m` instruction moves the top `n` cells down `m` places and drops the
stack pointer by `m`. Ghuloum's version is the same idea unoptimized: copy the arguments down
over the current frame and `jmp` indirect rather than `call`, which he names as
simple-but-wasteful and points at greedy shuffling as the fix. Chez's Version 4 call-site
shuffler, which reorders arguments to cut saves and place values directly in outgoing
locations, subsumed Version 1's tail-call argument shifting entirely. And Dybvig's section
4.7.3 removes the shift outright for self tail recursion when the procedure's name is never
assigned, compiling it to a direct jump.

**Interaction with first-class continuations.** Under stack segments the capture path needs an
explicit special case: if the current segment is empty at capture time, change nothing and
return the existing link field. Without it,
`(define looper (lambda () (call/cc (lambda (k) (looper)))))` adds a link per iteration and
exhausts memory. Conversely, once continuations are segment-linked, "is this a tail call?"
becomes a pointer `eq?` on continuations, which is how Chez's tracer distinguishes tail from
non-tail calls without an interpreter.

# Preconditions

**Lexical scoping is not a separate decision. It is the same decision.** This is the sharpest
result in the bundle on this technique and it is easy to state. Take
`(DEFINE BAR (LAMBDA (X Y) (F (G X) (H Y))))`. Under dynamic binding, `X` and `Y` must be
unbound between `F`'s return and `BAR`'s return. Steele's discipline says push a return address
only when an enclosing form needs the value of the form being evaluated, which requires that
nothing happen between the inner return and the outer return. An unbind is something happening.
So `F` cannot inherit `BAR`'s return address and the tail call is destroyed. Lexical scoping is
therefore *derived* in *Ultimate Declarative*, not assumed, and it is why Scheme could make
proper tail calls a language guarantee while Common Lisp could not: CL kept the call-time-push
convention and special binding, and page 13 shows those are one choice, not two.

Second, treating `PUSHJ` as a pure optimization requires that saving the return address and
setting up arguments *commute*. True for the register-passing SUBR convention; false for the
stack-passing LSUBR convention, where both contend for the stack.

Third, something has to pop, so primitives inexpressible in the language must be closed the
right way.

Fourth, and operationally the one that bites: every downstream pass must preserve the
invariant. If a pass introduces a save around a call in tail position it has broken proper tail
calls, and the 1975 frame rule is the cleanest test to write against. In ANF the check is
syntactic, since a non-tail call is exactly a `let` whose right-hand side is an application.

# Cost

Almost none, and less than the alternative. Dybvig's per-operation counts for a tail call with
`n` arguments: heap-based `5n+1` instructions and `2n` cells allocated; stack-based `n+2`
instructions and no allocation when the caller had no arguments, or `2n+2` instructions and
`3n+1` references when it did, that difference being the shift. So the shift is the whole cost,
and it disappears when the callee's arity matches the caller's, which after inlining is the
common case for self-recursive loops, and vanishes entirely under section 4.7.3's direct-jump
compilation.

SICP's measurement of the same effect at interpreter granularity: `(factorial 5)` costs 144
pushes and maximum depth 28 interpreted, 31 pushes and depth 14 compiled.

The cost *not* paid is a pass. Under Steele's discipline a compiler that pushes at
form-evaluation time gets tail calls uniformly with no "is this a tail call" analysis at all.

One cost no source in this bundle discusses, flagged as my inference rather than as a finding:
a proper tail call destroys the caller's frame, so a stack trace cannot show it. Every
implementation that guarantees tail calls pays this in debuggability, and none of the ten works
cited here mentions it.

# Disagreements

**Scheme against Common Lisp, and it is a real disagreement about language design rather than
about implementation.** Steele's argument makes proper tail calls follow from lexical scoping
plus a return-address discipline. CL kept both of the choices that break it. The consequence is
that in Scheme this is a guarantee a program may rely on for space complexity, and in CL it is
a quality-of-implementation matter. This is the cleanest example in the bundle of a standard
determining what an implementation can do, and it parallels the type-language argument in
`docs/CHEZ-ANALYSIS.md` running the other direction.

**Steele against Steele on fluid variables.** *Ultimate Declarative* argues for keeping both
lexical and dynamic binding as distinct mechanisms, while its own page 13 argument shows that
dynamic binding in the ordinary calling path costs tail calls. Scheme dropped fluid variables
from the core, CL kept special variables, and on the binding question the memo aged into CL's
position while its tail-call argument aged into Scheme's. Both cannot be free at once, and the
resolution the language actually took was to make fluid binding a delimited, explicitly scoped
construct rather than the default.

**Optimization or property.** RABBIT and SICP treat it as something that falls out of the code
generator: a known call compiles to a `GOTO` after an environment adjustment, and
`compile-proc-appl`'s (val, return) case simply omits the `continue` setup. Ghuloum implements
the copy-down-and-jump version and calls it wasteful in the same paragraph. Chez arrives at it
through a general shuffler that was not built for tail calls at all. Nobody disagrees about the
semantics; the spread is entirely about machine cost, and it is a maturity gradient rather than
a conflict.

**The trap in SICP's model.** Its tail calls are trivial precisely because arguments live in a
heap-allocated list in `argl`, so there is no register argument passing and no stack frames.
That is exactly what makes everything else slow, and footnote 40 concedes it. The cheapest tail
call in the bundle comes from the most expensive calling convention. Do not read SICP chapter 5
as evidence that a fast implementation gets this for free.

# For us

Stages `11-select` and `13-assemble` own this, and stage `07-loops` depends on it.

The loop representation in the CUJ is Steele's FACT walkthrough verbatim: a self-tail-calling
`letrec` procedure compiled to a jump with parameters in fixed registers. Recognizing a loop in
our core language is recognizing a `letrec`-bound procedure called in tail position from its own
body, which is easier than general natural-loop analysis on a CFG and is available only because
tail calls are already a jump. The consequence for `10-vectorize` is direct: because a tail call
is an unconditional transfer that is non-committal about returning a value, unboxed f64s stay
live in `xmm` registers across the loop back-edge.

Two things to lift from the 1976 papers into stage 08. Note Flowgraph is a compiler note rather
than a language note: after the GO TO transformation the parity example passes `PARITY`
uselessly between `L1` and `L3`, and dataflow analysis proves the loop does not alter it, so it
need not be an argument at all. That is dead-argument elimination stated in 1976, and a
parameter that is never live is a storage class we do not have to assign. And Steele's
preference classes derive coalesce hints from *binding structure* rather than from copy
instructions, which is cheaper than the George/Appel formulation and available to us for the
same reason it was available to him.

Acceptance tests, both cheap and both greps over our own disassembler output: no save or
restore around any call in tail position, and a self tail call with matching arity compiling to
a jump with no argument shift.
