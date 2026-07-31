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

`call/cc` and cheap procedure calls were assumed to trade off, and each prior position pays
somewhere. Heap-allocated frames (Sussman and Steele's `CLINK` chain and every naive Scheme
after it) give constant-time capture, but every call pays an extra write and read to save and
restore the frame pointer, frames can never be reused or mutated, and the collector must
trace them. Naive stack copying, which is Dybvig's own 1987 snapshot continuation, gives
cheap calls but makes continuation cost proportional to live stack depth on both capture and
reinstatement, with unbounded retention. A bounded stack cache bounds continuation cost, but
that bound is the same knob as the bound on recursion depth, so a small cache makes deep
recursion expensive and admits the *bouncing* pathology, where a loop straddling the cache
boundary turns every call into an overflow. The segmented model separates the two knobs.

# Mechanism

The control stack is a linked list of stack segments, each a true stack of frames. Every
segment has a *stack record*: base pointer, link to the next record, segment size, and the
return address of the topmost frame.

**Frame layout.** Word zero at the frame base is the return address of the active procedure,
then parameters (pointers to heap cells for assignable ones), locals, temporaries, and partial
frames for calls in progress. `fp` points at the base of the current frame, always in the
topmost segment. There is deliberately no stack pointer, so a gap often sits above `fp`.
Dropping it removes the increment/decrement pairs RISC machines cannot fold into addressing
modes.

**No dynamic link.** `fp` moves by a compile-time constant before a call and back after it.
To walk the stack backward anyway, the compiler emits a data word holding the frame size into
the code stream immediately before each return point: given a return address, read the
preceding word for the frame size, subtract to reach the next frame's base, repeat. Recovering
the size by disassembling the `fp` adjustment was considered and rejected, because it
constrains the compiler, which otherwise can move `fp` straight to the base of the next
call's frame.

**Capture, constant time.** Seal the occupied portion of the current segment: set the stack
record's size field to the current `fp` offset, store the current return address in the
record, and overwrite the return address in the current frame with the underflow handler's
address. Allocate a new stack record based just above the sealed region, linked to the old
record, which is now the continuation. Nothing is copied. The stack shortens with each
capture, so overflow eventually fires and a fresh segment arrives, which is how repeated
capture degrades gracefully toward the heap model. Capturing before every call gives exactly
the heap model, one frame per segment.

The tail-recursion special case is not optional: if the current segment is *empty* at capture,
change nothing and return the existing link field. Without it,
`(define looper (lambda () (call/cc (lambda (k) (looper)))))` adds a link per iteration and
exhausts memory.

**Reinstatement, bounded.** Copy the continuation's segment over the current one and set `fp`
to its top frame, allocating a larger segment if it does not fit. If the saved segment exceeds
the copy bound, split it first: walk backward using the code-stream frame sizes until one more
frame would exceed the bound, then split there, taking as much as possible because the split
has overhead. Splitting mirrors capture. **Underflow** is the same mechanism inverted: the base
of every segment but the first holds the underflow handler, which reinstates the continuation
in the current record's link field.

**Overflow detection.** Hold an end-of-stack pointer `esp` in a register, offset a constant
before the true end, so overflow is a register compare with no memory reference. Widen the
offset to reserve two frames and a procedure making no non-tail calls needs no check at all,
since any procedure that does make one has already reserved the space. Leaf routines and
tail-recursive loops check nothing. Static analysis removes more: sink the check to where a
recursive call is known to happen, and skip it when the callee's stack usage is known and the
sum fits in the reserve.

**One-shot continuations** refine the same representation. `call/1cc` puts the whole current
segment into the continuation and makes a fresh one current, which needs a second size field:

```
multi-shot  <=>  size == current_size
one-shot    <=>  size != current_size
shot        <=>  size == current_size == -1
```

Invoking a one-shot copies nothing at any size. A one-shot captured inside a multi-shot must
be promoted (`size := current_size`), so `call/cc` walks the chain resetting each until it
reaches a multi-shot and stops there, since whatever created that multi-shot already promoted
everything below. No quadratic blowup, but `call/cc` is no longer bounded-time. Two details
are load-bearing rather than optional: a stack segment cache as a free list, without which the
authors found `call/1cc` programs "unacceptably slow, much slower than the equivalent programs
written in terms of `call/cc`"; and a fragmentation policy, since one-shots encapsulate whole
segments including unused space, so 100 threads at a 16KB default cost 1.6MB mostly wasted.

# Preconditions

The compiler must own frame layout and calling convention: return address at a known offset,
ideally the base so tail calls need not move it; a frame-size word in the code stream before
every return point; `fp` adjusted by a constant either side of a call; `esp` in a register.
None of these are expressible through a back end that owns its own frame layout, which is the
concrete content of "LLVM would have cost us `call/cc`". LLVM's `invoke`/`unwind` unwinds and
discards; this model seals and retains, and the difference is not bridgeable at the IR level.

The stack must not be used for anything else, asynchronous interrupt handling included. The
code stream must be readable and adjacent to return addresses; under W^X, or with signed
pointers, the frame-size trick needs a side table. That is the one part of the 1990 design
that does not transfer unchanged. Bounding the worst case requires bounding frame size, which
means bounding argument count, bounding local bindings, and spilling pending-call temporaries
to a heap list. Chez implemented none of it, reporting from static analysis that 99 percent of
its own frames are under 30 words.

# Cost

Capture is constant time and allocates one stack record. Reinstatement is bounded by the copy
bound with one whole frame as the floor, hence the frame bound. Unlike the
Clinger/Hartheimer/Ost hybrid, this model *does* duplicate frames when a continuation is
reinstated repeatedly; the segment size bound caps the duplication at a constant factor over
the hybrid. One-shots add a word per record plus the promotion walk. Overflow recovery is
deliberately unoptimized, since segments are large and there is no bouncing.

**The 1990 paper contains no measurements.** Its abstract asserts the approach is faster than
naive stack allocation, at worst a constant factor slower than heap allocation for
continuation-intensive programs, and significantly faster for typical programs. No table, no
benchmark, no figure supports any of the three claims anywhere in the twelve pages. The
mechanism is precise enough to implement and the asymptotic arguments are sound, but the
performance is asserted. Chez's subsequent thirty years is the real evidence and it is not in
this paper. Two loose ends: the copy bound "can be determined only by experimentation" with no
guidance on the tradeoff curve, and the frame-size bound the abstract advertises was
unenforced in the shipping implementation.

The 1996 one-shot paper does measure, on a DEC Alpha 3000/600. `tak` modified so every call
captures and invokes a continuation: `call/1cc` 13 percent faster, 23 percent less allocation.
Thread systems at 10, 100 and 1000 threads: faster by a few percent below one context switch
per 128 calls. A million-call deep recursion: handling overflow as an implicit one-shot is 300
percent faster. The number worth keeping is 0.1 instructions per frame of continuation
overhead across a large benchmark set, which is what direct-style stack-based Chez costs.

# Disagreements

**Escape-only against full `call/cc`.** T deliberately weakened the language, as Dybvig
quotes: escape procedures are invalid outside the dynamic extent of the `CATCH` that created
them, "this ensures that the control stack behaves in a stack-like way, unlike in Scheme,
where the control stack must be heap-allocated." This model and Orbit together retract that
concession. RABBIT sits elsewhere again, ignoring the problem: Steele states flatly that a
side-effecting expression substituted past an unknown call is unsound if that call captures an
escape procedure later invoked twice, that nothing short of fearing every unknown call decides
it, and that fearing them defeats most optimization.

**Primitive against source-to-source.** Steele and Sussman's own conclusion in *Ultimate
Imperative* is that escape expressions and general L-values have translations that are **not
syntactically local**, and that if these constructs are wanted they should be primitives. That
is a negative result from the paper that made everything else a rewriting, and it is direct
support for continuations as runtime machinery under a stack-segment representation rather
than through a CPS transform. Compare the CPS position, where RABBIT's `CPC-CATCH` eliminates
`CATCH` outright by binding the tag to a procedure that discards its own continuation. Both
work. Only one keeps ordinary calls at stack cost.

**Whether the one-shot distinction should be user-visible.** The 1996 conclusion concedes that
below one switch per 128 calls the margin is a few percent, and that invoking a one-shot twice
is detected but not statically preventable. Its strongest result is not the primitive: treat
stack overflow as an implicit `call/1cc` internally whether or not you expose it, with
hysteresis (copy several frames up on overflow) so bouncing does not return. The same
hysteresis appears in the Spineless Tagless G-machine for the same reason.

**Methodology, which matters more than the scoring.** Appel and Shao measured roughly equal
per-frame overhead for heap and stack control, 7.5 against 7.4 instructions per frame, and
5.75 instructions per frame of closure overhead on Boyer. Chez allocates *no* closures on
Boyer and measures about 0.1 instructions per frame. The explanation offered is that their
"stack-based" model is a CPS compiler with stack-allocated continuations, which forbids the
frame sharing a direct-style compiler gets free: a variable live across several calls must be
copied into each continuation frame in their model and stays in one stack slot in Chez. Avoid
the same trap in our own comparisons.

# For us

This is what makes owning the back end pay for itself, and the reason full `call/cc` is on the
table rather than an escape-only construct. Its requirements land on `08-represent` and
`13-assemble`, and each is a decision those stages must make anyway.

The ANF distinction between tail and non-tail calls is exactly the distinction between calls
needing no overflow check and calls that do. A `let`-bound application is the syntactic marker
for a frame push and the check-elimination rules key off it. The static overflow-check
elimination is a small, high-value pass at `13-assemble` where frame sizes are known.

Escape analysis gets stronger here than under any copying model: because capture does not move
the segment, objects with dynamic extent can be stack-allocated *and mutated*, which is
unsound under the copy and hybrid models. Record that when `09-alias` and escape analysis are
designed.

Do not implement snapshot continuations first. Dybvig's 1987 dissertation gestures at a
segmented stack as the fix on page 113 without developing it; read the two together, since
neither is complete alone. Take the 1996 overflow result even if `call/1cc` is never exposed,
and implement the hysteresis at the same time rather than finding the bouncing pathology later
under a profiler.

Finally, the segmented stack is what makes precise GC roots tractable, which is the CUJ's
stated reason for owning the back end. Frames are contiguous within a segment, the frame-size
word drives the walk, and stage 13's stack maps attach to exactly those return points. One
representation serves continuations, exception handling, debugging and precise collection.
