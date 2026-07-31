---
type: paper
title: "Representing Control in the Presence of First-Class Continuations"
description: Represents the control stack as a linked list of stack segments, so capturing a continuation seals the current segment in constant time without copying, and reinstating one copies at most a bounded prefix, making call/cc bounded while keeping ordinary calls at stack-model cost.
resource: knowledge/sources/hieb-dybvig-bruggeman-representing-control-in-the-presence.pdf
tags: [first-class-continuations, stack-segments, activation-records, stack-overflow, call-cc]
authors: [Robert Hieb, R. Kent Dybvig, Carl Bruggeman]
year: 1990
venue: "PLDI 1990, pp. 66-77"
informs: [/techniques/stack-segment-continuations.md, /techniques/closure-conversion.md, /techniques/escape-analysis.md]
pipeline_stage: 08-represent
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Breaks the assumed tradeoff between cheap procedure calls and cheap first-class continuations.
The prior options were heap-allocated frames (constant-time `call/cc`, but every call pays an
extra memory write and read to save and restore the frame pointer, frames can never be reused
or mutated, and the collector must trace them), naive stack copying (cheap calls, but
continuation cost proportional to stack depth and unbounded memory retention), and a bounded
stack cache (bounded continuation cost, but the bound on continuation cost is the same knob as
the bound on recursion depth, so a small cache makes deep recursion expensive and admits the
"bouncing" pathology where a loop straddling the cache boundary makes every call cost an
overflow).

The segmented model separates those two knobs. Segments can be arbitrarily large, so overflow
is rare, while the amount copied on reinstatement is capped independently by splitting the
segment. Capture does not copy at all.

The secondary result matters as much in practice: stack overflow and underflow become special
cases of continuation capture and reinstatement, so one mechanism handles both, and the paper
gives a method for detecting overflow with a register compare rather than memory-management
tricks.

# Mechanism

The control stack is a linked list of stack segments. Each segment is a true stack of frames.
Each has an associated *stack record* holding: a pointer to the segment base, a pointer to the
next stack record, the segment size, and the return address of the topmost frame.

Frame layout. Word zero at the frame base is the return address of the currently active
procedure, then n actual parameters (or pointers to heap cells for assignable ones), then
locals, temporaries, and partial frames for calls in progress. A frame pointer register `fp`
points to the base of the current frame, which is always in the topmost segment. There is no
stack pointer, so there is often a gap between `fp` and the last used word; that is fine
provided the stack is not used for anything else such as asynchronous interrupt handling.
Dropping the stack pointer removes the increment and decrement pairs that RISC machines cannot
fold into addressing modes, and it simplifies argument access.

No dynamic link. The frame pointer is adjusted by a constant immediately before a call and by
the same constant after the call returns, one add and one subtract, and the compiler tracks the
displacement. For the return address to be found on return, it lives at a known offset in the
frame (the base, so tail calls need not move it). To walk the stack backward, the compiler
emits a data word holding the frame size into the code stream immediately before each return
point. Given a return address, read the word before it to get the frame size, subtract to reach
the next frame's base, read its return address, repeat. The authors note the frame size could
be recovered by disassembling the frame-pointer adjustment at the return point, but reject it
because it constrains the compiler, which otherwise can move `fp` directly to the base of the
next call's frame.

Capture, constant time. Seal the occupied portion of the current segment: convert the current
stack record into the continuation object by setting its size field and storing the current
return address into its return-address field. Overwrite the return address in the current frame
with the address of the underflow handler. Allocate a new stack record whose base is the word
above the sealed region, whose link is the old stack record, and whose size is the remaining
space in the segment. No copying. The stack gets shorter with each capture, which eventually
triggers overflow and a fresh segment, which is the mechanism by which repeated capture
degrades gracefully toward the heap model. Capturing before every call would give exactly the
heap model, one frame per segment.

The tail-recursion special case: if the current segment is *empty* at capture time, make no
changes and return the existing link field as the continuation. Without this, the loop
`(define looper (lambda () (call/cc (lambda (k) (looper)))))` would add a link per iteration
and exhaust memory.

Reinstatement, bounded. Copy the continuation's segment over the current segment and set `fp`
to its top frame; allocate a larger current segment if it does not fit. Since segments are
deliberately large, cap the copy: if the saved segment exceeds the copy bound, split it first.
Walk backward through the segment (using the code-stream frame sizes) until adding another
frame would exceed the bound, then split there, taking as much as possible rather than a single
frame because the split itself has overhead. Splitting mirrors capture: a new stack record gets
the old record's base and link plus the return address from the frame above the split point;
the old record's base becomes the split point and its size the portion above; the return address
in the frame at the split point is replaced with the underflow handler; the new record becomes
the old one's link.

Two bounds, two purposes. The *copy bound* determines average-case reinstatement cost. The
*frame bound* determines worst case, since at least one whole frame must be copied. Bounding
frame size means bounding argument count (extras go in an auxiliary structure), bounding local
bindings (turn binding blocks into unnamed procedures), and spilling intermediate results for
pending calls into a heap-allocated list. The authors report that in practice, with a reasonably
large frame bound, none of this is needed.

Underflow. The base of every segment except the initial one holds the address of the underflow
handler, which simply reinstates the continuation in the current stack record's link field. The
initial segment's base holds an exit routine.

Overflow detection. Keep an end-of-stack pointer `esp` in a register, offset a constant distance
before the true end, so overflow is a register compare and branch with no memory reference and
no need to account for the frame size (given a frame bound). Enlarge the offset to reserve room
for two frames, and then a procedure that makes no non-tail calls needs no check at all,
because any procedure that does make one has already reserved space for it. Leaf routines and
tail-recursive loops therefore check nothing. Further checks are removed by static analysis:
sink the check to the point where a recursive call is known to happen (without duplicating it),
and skip it entirely when the callee's stack usage is known and the sum with the current frame
fits in the reserve.

# Applicability

What it requires from the compiler. A known return-address offset in the frame, or the offset
stored alongside the frame size in the code stream. A frame-size word emitted before every
return point. A frame-size bound if the worst case is to be bounded, though the authors did not
implement the enforcement in Chez and report from static analysis that 99 percent of Chez
Scheme's own frames are under 30 words. Dynamic-extent objects may be stack-allocated and
mutated, which is the property the copy model destroys.

What it costs relative to the heap model. Continuation operations are more expensive, though by
at most a constant factor, and unlike the hybrid stack/heap model of Clinger, Hartheimer and Ost
it does duplicate frames when the same continuation is reinstated repeatedly. The bound on
segment size bounds the duplication, so the extra memory is at worst a constant factor over the
hybrid model.

What breaks the overflow story. On architectures where the memory management unit can be used to
trap overflow this is free, but the paper reports that across the machines on which they
implemented Scheme they generally could not either generate the fault reliably or recover enough
machine state afterward, so the explicit check is the portable answer. Their model also *requires*
new stack areas on demand, so the trap approach needs selectively mprotect-able memory.

Recovery cost is deliberately not optimized: since segments are large and there is no bouncing,
arbitrarily much computation happens between overflows, so overflow handling can be slow.

# Relevance

This is the paper that makes owning the back end pay for itself, and it is the reason full
`call/cc` is on the table rather than a restricted escape-only construct.

The requirements it places on our code generator are specific and cheap, and every one of them is
a decision `08-represent` and `13-assemble` have to make anyway: return address at the frame base,
frame size in the code stream before each return point, `fp` adjusted by a constant on either side
of a call, `esp` in a register. None of these are expressible through an existing back end that
owns its own frame layout and calling convention, which is the concrete content of "LLVM would have
cost us `call/cc`". LLVM's `invoke`/`unwind` unwinds and discards; this model seals and retains,
and the difference is not bridgeable at the IR level.

Direct pipeline consequences:

The ANF distinction between tail and non-tail calls is exactly the distinction between calls that
need no overflow check and calls that do. Flanagan et al.'s `let`-bound application is the syntactic
marker for a frame push, and the overflow-check elimination rules key off it.

Escape analysis gets stronger here than under the heap model. Because a captured continuation does
not move the stack segment, objects with dynamic extent can be stack-allocated *and mutated*, which
is not sound under the copy model or the hybrid model. That is a real optimization enabled by the
representation choice, and it should be recorded as such when `09-alias` and escape analysis are
designed.

The static overflow-check elimination in Section 5 is a small, high-value pass: leaf and
tail-recursive procedures pay nothing, and callee stack-usage summaries let ordinary calls skip the
check too. Do this at `13-assemble` where frame sizes are known.

If we bound frame size to bound worst-case reinstatement, the three conversions named (extra
arguments to a heap vector, local binding blocks to procedures, pending-call temporaries to a heap
list) are pipeline passes with real cost. The authors' own answer, that Chez did not implement the
bound and 99 percent of frames are under 30 words, is the right default: measure first, and do not
pay for the worst case unless a benchmark demands it.

# Notes

Title, authors and venue verified against page 1: Robert Hieb, R. Kent Dybvig and Carl Bruggeman,
Indiana University, with a footer reading "Proceedings of the SIGPLAN '90 Conference on Programming
Language Design and Implementation, 66-77, June 1990". The bibliography's description ("**the**
stack-segment paper. How to have `call/cc` and cheap calls") is accurate in author list, year and
venue.

Distinct from `bruggeman-waddell-dybvig-representing-control-in-the-prese.pdf`, which is the PLDI
1996 one-shot continuations paper. Same title stem, different paper, different author order. The
two are easy to conflate from filename alone and both are in `knowledge/sources/`.

The paper contains no measurements. The abstract asserts that the approach "is faster than the naive
stack allocation approach", that it is "at worst a constant factor slower" than heap allocation for
continuation-intensive programs, and "significantly faster" for typical programs. No table, no
benchmark, no figure supports any of those three claims in this twelve-page document. The mechanism
is described precisely enough to implement and the asymptotic arguments are sound, but the
performance claims are assertions. Chez Scheme's subsequent thirty years is the real evidence, and
that evidence is not in this paper.

Two loose ends the authors leave open. The copy bound "can be determined only by experimentation"
for a given machine, with no guidance on the shape of the tradeoff curve. And the frame-size bound
was never enforced in the shipping implementation, so the worst-case bound the abstract advertises
was, at publication, unenforced.

Dependency worth noting: the frame-size-in-the-code-stream trick assumes the code stream is
readable and adjacent to return addresses. On a target with W^X or with return addresses that are
not raw code pointers (signed pointers, for example), the mechanism needs a side table instead. That
is a modern concern the 1990 paper had no reason to consider, and it is the one part of the design
that does not transfer unchanged.
