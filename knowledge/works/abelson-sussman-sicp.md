---
type: book
title: "Structure and Interpretation of Computer Programs, second edition"
description: Descends Scheme from source semantics to a running register machine via a metacircular evaluator, an explicit-control evaluator, and a small compiler whose entire optimizer is one stack-traffic elision rule.
resource: knowledge/sources/abelson-sussman-sicp.pdf
tags: [register-machine, explicit-control-evaluator, tail-calls, lexical-addressing, stop-and-copy-gc]
authors: [Harold Abelson, Gerald Jay Sussman, Julie Sussman]
year: 1996
venue: "MIT Press / McGraw-Hill, 2nd edition"
informs:
  - /techniques/explicit-control-evaluator.md
  - /techniques/tail-call-optimization.md
  - /techniques/lexical-addressing.md
  - /techniques/closure-conversion.md
  - /techniques/stop-and-copy-gc.md
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Nothing here is new as research. What the book contributes to an implementer is a
complete executable descent from Scheme semantics to hardware in four successively less
forgiving models: substitution (ch. 1), environments (ch. 3), metacircular evaluation
(4.1), and register machines with an explicit-control evaluator and a compiler (ch. 5).
Each model is introduced by exhibiting a question the previous one cannot answer. The
metacircular evaluator is discarded in chapter 5 precisely because it inherits control
structure from the host and so says nothing about where stack space goes. That framing —
tail recursion as a property of the evaluator, not of the source syntax — originates here.

# Mechanism

**Register-machine language (5.1).** Seven instructions: `assign`, `perform`, `test`,
`branch`, `goto`, `save`, `restore`; operands are `(reg r)`, `(const c)`, `(label L)`,
`(op name)`. Two extensions carry all the weight. Labels are storable in registers, so
`(goto (reg continue))` is a subroutine return; and a stack makes recursion possible by
saving the registers a subproblem will clobber. `save`/`restore` are untyped — restore
pops whatever was pushed last, regardless of source register (5.2.3, exercise 5.11).

**Assembler (5.2.2–5.2.3).** A closure-generating pass, not an interpreter.
`extract-labels` walks the controller text with a CPS `receive` procedure, splitting
labels from instructions and building an alist mapping each label to the shared tail of
the instruction list it designates. `update-insts!` then side-effects each instruction
with an execution thunk from `make-execution-procedure`, which dispatches on the
instruction tag exactly once, at assembly time: register names become register objects,
labels become list tails, operand expressions become nullary thunks. The run loop is
then `((instruction-execution-proc (car insts)))` plus `advance-pc`. This is the same
analyze/execute split as 4.1.7 — partial evaluation, not compilation.

**Storage (5.3).** Typed pointers into parallel `the-cars`/`the-cdrs` vectors; `cons` is
two `vector-set!` plus a `free` increment; symbols interned through an obarray so `eq?`
is pointer equality. 5.3.2 is Cheney stop-and-copy as ~40 register-machine instructions:
`free` and `scan` into to-space, `relocate-old-result-in-new` returning through
`relocate-continue`, a broken-heart tag in the from-space `car` with the forwarding
address in the `cdr`, termination when `scan` overtakes `free`, `gc-flip` swapping the
space registers. The scan pointer is the implicit worklist, so no auxiliary stack.

**Explicit-control evaluator (5.4).** Registers `exp env val continue proc argl unev`
plus a stack. `eval-dispatch` is a linear `test`/`branch` chain on syntactic type (the
book notes a real machine would use a `dispatch-on-type` instruction). Recursion is
`(save continue)` … `(goto (label eval-dispatch))` … label. Two economies do everything:
`ev-appl-last-arg` skips saving `env` and `unev` before the final operand (evlis tail
recursion), and `ev-sequence-last-exp` *restores* `continue` before jumping to
`eval-dispatch`, so the last expression of a body returns straight to the caller's
continuation. That second one is the entire implementation of proper tail calls. The
book then shows the naive alternative — a uniform save/restore cycle plus
`ev-sequence-end` — and demonstrates it converts constant-space iteration into linear.
Measured: `(factorial 5)` interpreted costs 144 pushes, max depth 28.

**Compiler (5.5).** `(compile exp target linkage)` returns an instruction sequence
represented as a triple `(needs, modifies, statements)`. `target` names the destination
register (`val` everywhere except the operator of a combination, which targets `proc`);
`linkage` is `next`, `return`, or a label. Four combiners:

- `append-2-sequences`: `needs = needs(s1) ∪ (needs(s2) − modifies(s1))`,
  `modifies = modifies(s1) ∪ modifies(s2)`.
- `preserving regs s1 s2`: for each `r` in `regs`, wrap `s1` in `save`/`restore` only if
  `s1` modifies `r` *and* `s2` needs `r`. No code generator ever emits a stack
  instruction itself. This is the whole optimizer: a linear, purely local liveness
  approximation over register-name sets.
- `parallel-instruction-sequences` for branch arms: `needs` is the union of both arms,
  since a register needed by the untaken arm is still needed by the combined sequence.
- `tack-on-instruction-sequence` for out-of-line lambda bodies: register sets discarded,
  because the body is not in line.

`compile-application` is
`(preserving '(env continue) proc-code (preserving '(proc continue) arglist-code call-code))`.
The argument list is built last-to-first so that successive `cons` yields left-to-right
order, with `argl` preserved around every operand but the first and `env` around every
one but the last. `compile-proc-appl` splits on `target = val` × `linkage = return`; the
(val, return) case emits only `(assign val (op compiled-procedure-entry) (reg proc))`
and `(goto (reg val))` — no `continue` setup at all — which *is* the tail call. It
declares itself as needing `continue` and modifying `all-regs`. Compiled `(factorial 5)`:
31 pushes, max depth 14.

**Lexical addressing (5.5.6).** A compile-time environment, a list of frames of names,
threaded through `compile` and extended by `compile-lambda-body`. `find-variable` yields
`(frame-number displacement)`, and `lexical-address-lookup` replaces the deep-binding
scan. It requires internal defines to be scanned out first (4.1.6: bind to
`*unassigned*`, then `set!`) or frame layout is not statically known. Globals fall back
to the runtime search because they can be redefined interactively.

# Applicability

The compiler is correct because it targets the interpreter's own data paths and register
conventions — the calling convention is fixed by fiat, not derived. `preserving` is sound
only because `needs`/`modifies` are conservative and `compile-proc-appl` declares
`all-regs` modified. Arguments live in a heap-allocated list in `argl`, so there is no
register argument passing and no stack frames; that is exactly what makes tail calls
trivial and everything else slow. Footnote 40 concedes the point and cites Hanson 1990.

Absent: register allocation (registers are named by hand), type information, inlining,
representation selection, and every form of dataflow analysis — there is no CFG and no
IR. Primitives go through `apply-primitive-procedure` behind a runtime
`primitive-procedure?` test on every call; open-coding is exercise 5.38 and never
integrated. Exercise 5.45b concedes the hand-written machine of Figure 5.11 badly beats
the compiled code. A correctness-and-structure artifact, not a performance one.

# Relevance

`preserving` is the degenerate ancestor of our register allocator, worth having read
because it makes the failure mode legible: local save/restore elision with no liveness
dataflow across control flow. Burger/Waddell/Dybvig is that problem taken seriously.
Lexical addressing plus scan-out-defines is the minimal correct statement of a
closure-conversion precondition — frame offsets are not computable until internal
definitions are hoisted — which is where Keep/Hearn/Dybvig's O(0) closures begin. The
tail-call material (5.4.2 plus `compile-proc-appl` case 3) is the one genuinely
definitive thing here and is usable as a specification. 5.3.2 is an executable Cheney
reference for checking a generational nursery's evacuation loop, since Appel 1989's
young-generation collector is this algorithm. Chapters 1–3 are not load-bearing: 2.4.3's
data-directed dispatch table and 3.5.4's collision between mutation and delayed
evaluation are the only parts with implementation content, both better covered elsewhere.

# Notes

**No intermediate representation.** `compile` walks source syntax directly to
register-machine instructions. Nanopass, CPS/ANF and SSA exist because that does not
scale, and the book never says so — which matters, since we are planning around nanopass.

**Figure 5.17 rewards close reading.** Compiled `factorial` saves `continue` and `env`
around the predicate `(= n 1)` solely because a procedure call is declared to modify
`all-regs`. Open-code `=` and both saves vanish. The book splits this across 5.5.5 and
exercise 5.38 and never combines them, understating how much residual stack traffic is an
artifact of generic application rather than of `preserving`'s weakness.

**Bibliography correction.** `docs/phases/00-compiler-research/PLAN.md` §13 lists this as
`Abelson & Sussman, *SICP*` with no year, edition, or venue. The title page credits three
people — Harold Abelson and Gerald Jay Sussman *with Julie Sussman*, foreword by Alan J.
Perlis — second edition, ©1996 MIT Press and McGraw-Hill.

**Version mismatch.** The downloaded PDF is not the MIT Press original. It is "Unofficial
Texinfo Format 2.andresraba5.6 (February 2, 2016)", a CC BY-SA 4.0 re-typeset descended
from neilvandyke4 (2007). Text and section numbering are faithful to the 2nd edition;
pagination is not — 883 PDF pages against 657 printed, so page citations must say which.
Extraction silently drops the "Th" and "tt" ligatures ("e" for "The", "aer" for "after"),
which will corrupt automated quotation.

**Scope caveat on a plan claim.** `docs/phases/07-compiler/PLAN.md` argues tractability
with "SICP chapter 5 is a compiler." True, but §5.5 has one optimization and targets an
abstract machine whose primitives include `extend-environment` and
`apply-primitive-procedure`. That is not evidence about the tractability of an
*optimizing native* compiler; the distance from §5.5 to precise GC roots in registers is
where the work lives.
