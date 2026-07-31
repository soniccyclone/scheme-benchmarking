---
type: technique
title: Stack segment continuations
description: Represent the control stack as a linked list of segments so capturing a continuation seals the current segment in constant time and reinstating one copies a bounded prefix, giving full call/cc without taxing ordinary calls.
tags: [first-class-continuations, stack-segments, call-cc, one-shot-continuations, stack-overflow, activation-records]
sources:
  - resource: /works/hieb-dybvig-bruggeman-representing-control-in-the-presence.md
  - resource: /works/bruggeman-waddell-dybvig-representing-control-in-the-prese.md
  - resource: /works/dybvig-three-implementation-models-for-scheme-1987.md
  - resource: /works/dybvig-et-al-the-development-of-chez-scheme-icfp-2006.md
  - resource: /works/steele-sussman-lambda-the-ultimate-imperative-1976.md
  - resource: /works/sussman-steele-scheme-an-interpreter-for-extended-lambda-c.md
  - resource: /works/flanagan-sabry-duba-felleisen-the-essence-of-compiling-wit.md
implemented_by: [/implementations/chez.md]
absent_from: [/implementations/sbcl.md]
pipeline_stage: 08-represent
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

`call/cc` and cheap procedure calls were assumed to trade off, and the three prior positions
each pay somewhere. Heap-allocated frames (Sussman and Steele's `CLINK` chain, and every
naive Scheme after it) give constant-time capture, but every call pays an extra write and
read to save and restore the frame pointer, frames can never be reused or mutated, and the
collector must trace them. Naive stack copying, which is Dybvig's own 1987 snapshot
continuation, gives cheap calls but makes continuation cost proportional to live stack depth
on both capture and reinstatement, with unbounded retention. A bounded stack cache bounds
continuation cost, but the bound on continuation cost is the same knob as the bound on
recursion depth, so a small cache makes deep recursion expensive and admits the *bouncing*
pathology, where a loop straddling the cache boundary makes every call an overflow.

The segmented model separates the two knobs. Segments can be arbitrarily large so overflow is
rare, while the amount copied on reinstatement is capped independently by splitting a segment.

# Mechanism

The control stack is a linked list of stack segments, each a true stack of frames. Every
segment has a *stack record* holding a base pointer, a link to the next record, the segment
size, and the return address of the topmost frame.

**Frame layout.** Word zero at the frame base is the return address of the active procedure,
then actual parameters (or pointers to heap cells for assignable ones), then locals,
temporaries and partial frames for calls in progress. A frame pointer register `fp` points at
the base of the current frame, always in the topmost segment. There is deliberately no stack
pointer, so a gap often sits between `fp` and the last used word, which is fine only if
nothing else uses the stack, asynchronous interrupt handling included. Dropping the stack
pointer removes the increment and decrement pairs that RISC machines cannot fold into
addressing modes.

**No dynamic link.** `fp` is adjusted by a compile-time constant immediately before a call
and by the same constant after it returns, one add and one subtract. To walk the stack
backward anyway, the compiler emits a data word holding the frame size into the code stream
immediately before each return point. Given a return address, read the preceding word for the
frame size, subtract to reach the next frame's base, read its return address, repeat. The
authors considered recovering the size by disassembling the `fp` adjustment and rejected it,
because it constrains the compiler, which otherwise can move `fp` straight to the base of the
next call's frame.

**Capture, constant time.** Seal the occupied portion of the current segment: set the stack
record's size field to the current `fp` offset and store the current return address in the
record. Overwrite the return address in the current frame with the address of the underflow
handler. Allocate a new stack record whose base is the word above the sealed region, whose
link is the old record (now the continuation), and whose size is the segment remainder.
Nothing is copied. The stack shortens with each capture, so overflow eventually fires and a
fresh segment arrives, which is how repeated capture degrades gracefully toward the heap
model. Capturing before every call gives exactly the heap model, one frame per segment.

The tail-recursion special case is not optional: if the current segment is *empty* at capture
time, change nothing and return the existing link field. Without it,
`(define looper (lambda () (call/cc (lambda (k) (looper)))))` adds a link per iteration and
exhausts memory.

**Reinstatement, bounded.** Copy the continuation's segment over the current segment and set
`fp` to its top frame, allocating a larger segment if it does not fit. Cap the copy: if the
saved segment exceeds the copy bound, split it first. Walk backward using the code-stream
frame sizes until one more frame would exceed the bound, then split there, taking as much as
possible because the split itself has overhead. Splitting mirrors capture.

**Underflow** is the same mechanism inverted. The base of every segment except the initial one
holds the underflow handler's address, which reinstates the continuation in the current
record's link field. The initial segment's base holds an exit routine.

**Overflow detection.** Keep an end-of-stack pointer `esp` in a register, offset a constant
distance before the true end, so overflow is a register compare and branch with no memory
reference. Enlarge the offset to reserve room for two frames and a procedure making no
non-tail calls needs no check at all, because any procedure that does make one has already
reserved space. Leaf routines and tail-recursive loops check nothing. Static analysis removes
more: sink the check to where a recursive call is known to happen, and skip it when the
callee's stack usage is known and the sum with the current frame fits in the reserve.

**One-shot continuations** are a refinement on the same representation. `call/1cc` puts the
entire current segment into the continuation and makes a fresh segment current, which needs a
second size field. The invariant carries the whole trick:

```
multi-shot  <=>  size == current_size
one-shot    <=>  size != current_size
shot        <=>  size == current_size == -1
```

Invoking a one-shot copies nothing at any size: discard the current segment, reinstall the
continuation's base, link and size, reset `fp`, then mark it shot. A one-shot captured inside
a multi-shot must be promoted (`size := current_size`), so `call/cc` walks the chain of
one-shots resetting each until it reaches a multi-shot and stops, since whatever created that
multi-shot already promoted everything below. No quadratic blowup, but `call/cc` is no longer
bounded-time. Two implementation details are load-bearing rather than optional: a stack
segment cache as a simple free list, without which the authors found `call/1cc` programs
"unacceptably slow, much slower than the equivalent programs written in terms of `call/cc`";
and a fragmentation policy, since one-shots encapsulate whole segments including unused
space, so 100 threads at a 16KB default cost 1.6MB mostly wasted.

# Preconditions

The compiler must own frame layout and the calling convention. Specifically: return address
at a known offset in the frame, ideally the base so tail calls need not move it; a frame-size
word emitted into the code stream before every return point; `fp` adjusted by a constant on
each side of a call; `esp` held in a register. None of these are expressible through a back
end that owns its own frame layout, which is the concrete content of "LLVM would have cost us
`call/cc`". LLVM's `invoke`/`unwind` unwinds and discards; this model seals and retains, and
the difference is not bridgeable at the IR level.

The stack must not be used for anything else, since there is no stack pointer and a gap sits
above `fp`. The code stream must be readable and adjacent to return addresses; under W^X, or
with signed pointers or any return address that is not a raw code pointer, the frame-size
trick needs a side table instead. That is the one part of the 1990 design that does not
transfer unchanged.

Bounding the worst case requires bounding frame size, which in turn means bounding argument
count (extras to an auxiliary structure), bounding local bindings (turn binding blocks into
unnamed procedures), and spilling pending-call temporaries to a heap list. The authors did
not implement the bound in Chez and report from static analysis that 99 percent of Chez's own
frames are under 30 words.

# Cost

Capture is constant time and allocates one stack record. Reinstatement is bounded by the copy
bound, with at least one whole frame as the floor, hence the frame bound. Unlike the
Clinger/Hartheimer/Ost hybrid, this model *does* duplicate frames when the same continuation
is reinstated repeatedly; the segment size bound caps the duplication at a constant factor
over the hybrid. One-shots add one word per stack record plus the promotion walk. Recovery
from overflow is deliberately not optimized, since segments are large and there is no
bouncing, so arbitrarily much computation happens between overflows.

**The 1990 paper contains no measurements.** Its abstract asserts that the approach is faster
than naive stack allocation, at worst a constant factor slower than heap allocation for
continuation-intensive programs, and significantly faster for typical programs. No table, no
benchmark and no figure supports any of the three claims anywhere in the twelve pages. The
mechanism is described precisely enough to implement and the asymptotic arguments are sound,
but the performance claims are assertions. Chez Scheme's subsequent thirty years is the real
evidence and that evidence is not in this paper. Two further loose ends: the copy bound "can
be determined only by experimentation" for a given machine with no guidance on the shape of
the tradeoff curve, and the frame-size bound the abstract advertises was unenforced in the
shipping implementation at publication.

The 1996 one-shot paper does measure, on a 96MB DEC Alpha 3000/600 under OSF/1. `tak`
modified so every call captures and invokes a continuation: `call/1cc` 13 percent faster,
23 percent less allocation. Thread systems at 10, 100 and 1000 threads: consistently faster
but only by a few percent below one context switch per 128 calls. A deeply recursive program,
one million calls with little work between them: handling overflow as an implicit one-shot is
300 percent faster and allocates far less. And the number worth keeping is 0.1 instructions
per frame of continuation overhead across a large benchmark set, which is what direct-style
stack-based Chez actually costs.

# Disagreements

**Escape-only against full `call/cc`.** T deliberately weakened the language, as Dybvig
quotes: escape procedures are invalid outside the dynamic extent of the `CATCH` that created
them, "this ensures that the control stack behaves in a stack-like way, unlike in Scheme,
where the control stack must be heap-allocated." This model and Orbit together retract that
concession. RABBIT sits on the other side of the argument entirely, ignoring the problem:
Steele states flatly that a side-effecting expression substituted past an unknown call is
unsound if that call captures an escape procedure invoked twice, that there is no way to
decide this short of fearing every unknown call, and that fearing them defeats most
optimization.

**Primitive against source-to-source.** Steele and Sussman's own conclusion in *Ultimate
Imperative* is that escape expressions and general L-values have translations that are **not
syntactically local**, and that if these constructs are wanted they should be primitives.
That is a negative result from the paper that made everything else a rewriting, and it is
direct support for implementing continuations as runtime machinery under a stack-segment
representation rather than through a CPS transform. Compare the CPS position in
`continuation-passing-style.md`, where RABBIT's `CPC-CATCH` eliminates `CATCH` outright by
binding the tag to a procedure that discards its own continuation. Both work. Only one of
them keeps ordinary calls at stack cost.

**Whether the distinction should be user-visible.** The 1996 paper's own conclusion concedes
that below one context switch per 128 calls the advantage of `call/1cc` over `call/cc` is a
few percent, and that invoking a one-shot twice is an error detected but not statically
preventable. Its strongest practical result is not the primitive at all: a stack-based
implementation should treat stack overflow as an implicit `call/1cc` internally whether or not
it exposes the primitive, with hysteresis (copy several frames up from the old segment on
overflow) to avoid reintroducing bouncing. The same hysteresis appears in the Spineless
Tagless G-machine for the same reason.

**Methodology, and this one matters more than the scoring.** Appel and Shao measured roughly
equal per-frame overhead for heap-based and stack-based control, 7.5 against 7.4 instructions
per frame, and 5.75 instructions per frame of closure overhead on Boyer. Chez allocates *no*
closures on Boyer and measures about 0.1 instructions per frame overall. The explanation
offered is that Appel and Shao's "stack-based" model is a CPS compiler with stack-allocated
continuations, which forbids the frame sharing a direct-style compiler gets for free: a
variable live across several calls must be copied into each continuation frame in their
model, and stays in one stack slot in Chez. Any comparison of control representations in our
own work should avoid the same trap.

# For us

This is the paper that makes owning the back end pay for itself and the reason full `call/cc`
is on the table rather than an escape-only construct. Its requirements land on `08-represent`
and `13-assemble`, and each is a decision those stages must make anyway.

The ANF distinction between tail and non-tail calls is exactly the distinction between calls
that need no overflow check and calls that do. A `let`-bound application is the syntactic
marker for a frame push, and the check-elimination rules key off it.

Escape analysis gets stronger under this representation than under any copying model. Because
capture does not move the stack segment, objects with dynamic extent can be stack-allocated
*and mutated*, which is unsound under the copy model and the hybrid. Record that when
`09-alias` and escape analysis are designed.

The static overflow-check elimination is a small, high-value pass at `13-assemble` where
frame sizes are known: leaf and tail-recursive procedures pay nothing, and callee stack-usage
summaries let ordinary calls skip the check.

Do not implement snapshot continuations first. Dybvig's 1987 dissertation gestures at a
segmented stack as the fix on page 113 without developing it, and the two documents should be
read together since neither is complete alone. Take the 1996 overflow result even if
`call/1cc` is never exposed, and implement the hysteresis at the same time rather than
discovering the bouncing pathology later under a profiler.

Finally, the segmented stack is what makes precise GC roots tractable, which is the CUJ's
stated reason for owning the back end. Frames are contiguous within a segment, the
frame-size word drives the walk, and the stack maps stage 13 emits attach to exactly those
return points. One representation serves continuations, exception handling, debugging and
precise collection.
