---
type: paper
title: "Representing Control in the Presence of One-Shot Continuations"
description: Introduces call/1cc and a segmented-stack representation in which capturing and invoking a one-shot continuation costs no stack copying at all, with promotion to multi-shot when captured inside call/cc.
resource: knowledge/sources/bruggeman-waddell-dybvig-representing-control-in-the-prese.pdf
tags: [one-shot-continuations, stack-segment-continuations, call-cc, thread-systems, stack-overflow]
authors: [Carl Bruggeman, Oscar Waddell, R. Kent Dybvig]
year: 1996
venue: "PLDI 1996, 99-107"
informs: [/techniques/stack-segment-continuations.md, /techniques/one-shot-continuations.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Most continuations are invoked exactly once, and if you tell the implementation that, the copying
cost of `call/cc` disappears entirely. The paper introduces `call/1cc`, gives a representation in
which one-shot capture and invocation involve no stack copying at any size, works out how one-shot
and multi-shot continuations interact (promotion), and measures where the distinction actually
pays.

The strongest practical result is not about `call/1cc` as a user-facing primitive. It is that a
stack-based implementation should treat stack overflow as an implicit `call/1cc` internally
whether or not it exposes the primitive, because that removes the copying on stack underflow and
buys 300% on deeply recursive programs.

# Mechanism

This builds directly on the segmented stack of Hieb, Dybvig and Bruggeman (PLDI 1990), which is a
separate paper and a separate file in this corpus.

**Base representation.** The control stack is a linked list of stack segments, each a true stack
of frames. A *stack record* per segment holds the base pointer, a link to the next record, the
segment size, and the return address displaced by the underflow handler's address. There are no
dynamic links between frames: only a frame pointer is maintained, no stack pointer, and `fp` is
adjusted by a single add before a call and a single subtract after it, using a displacement the
compiler knows statically. Stack walking is possible anyway because the compiler places the frame
size as a word in the code stream immediately before the return point, so a return address yields
the size of its frame.

**call/cc.** Seal the occupied portion of the current segment: set the stack record's size field
to the current `fp` offset, store the current return address in the record, and overwrite the
frame's return address with the underflow handler. Allocate a new current stack record whose base
is just above the occupied portion, whose link is the old record (now the continuation), and whose
size is the remainder of the segment. No copying at capture. The stack shortens with each capture,
so overflow eventually happens, which is why the initial segment is large.

**call/1cc.** The entire current segment goes into the continuation and a fresh segment becomes
current. This requires two size fields, total size and current size (the `fp` offset). The
invariant is the whole trick:

```
multi-shot  <=>  size == current_size
one-shot    <=>  size != current_size
shot        <=>  size == current_size == -1
```

**Invocation.** Multi-shot: copy the saved segment into the current segment, allocating a bigger
one if needed, bounded by a copy bound; if the saved segment exceeds the bound it is first split
so the top piece fits. One-shot: no copy at any size. Discard the current segment, reinstall the
continuation's base, link and size into the current stack record, reset `fp`, then mark the
continuation shot by setting both size fields to -1.

**Tail calls.** If the current segment is empty at capture time, nothing changes and the link
field of the current record is the continuation. This is what keeps tail recursion proper.

**Promotion.** A one-shot captured inside a multi-shot continuation must become multi-shot,
otherwise composing an abstraction built on `call/1cc` with one built on `call/cc` is unsound.
Promotion is `size := current_size`. Since the current continuation may be a chain of one-shots,
`call/cc` walks the chain resetting each until it reaches a multi-shot, and stops there because
whatever created that multi-shot already promoted everything below it. There is no quadratic
blowup, since each one-shot is promoted at most once, but `call/cc` is no longer bounded-time.
The proposed but unimplemented fix is a boxed flag shared by all one-shots in a chain, promoting
the whole chain by setting one flag.

**Two implementation details that are load-bearing, not optional.** A stack segment cache, a
simple internally linked free list, is required: the common `call/1cc` pattern allocates a fresh
segment and discards it almost immediately, and without the cache the authors found `call/1cc`
programs "unacceptably slow, much slower than the equivalent programs written in terms of
`call/cc`." And a fragmentation policy is required: one-shot continuations encapsulate whole
segments including unused space, so 100 threads at a 16KB default cost 1.6MB mostly wasted. Their
fix is to seal the current segment at a fixed displacement above the occupied portion and use the
remainder as the new current segment rather than allocating fresh.

**Overflow.** Treating overflow as implicit `call/cc` avoids bouncing (overflow, immediate
underflow, overflow again) because the whole new stack must be refilled before the next overflow.
Treating it as implicit `call/1cc` naively reintroduces bouncing, since an immediate underflow
switches back to the saved full stack and the next call is guaranteed to overflow. The fix is
hysteresis: copy several frames up from the old segment into the new one on overflow, so the
overflow continuation holds only the uncopied part. The same mechanism appears in the Spineless
Tagless G-machine for the same reason.

# Applicability

`call/1cc` is a language change, not just an implementation technique, and invoking a one-shot
twice is an error the system detects but cannot prevent statically. One-shot continuations cover
non-local exit, coroutines, non-blind backtracking and thread systems. They cannot express
nondeterminism in the Prolog sense, where a continuation is deliberately re-invoked to yield more
answers; that still needs `call/cc`.

The technique presupposes the segmented stack representation. In a heap-allocated-frame or CPS
runtime the one-shot distinction buys nothing, because there was no copying to avoid.

Costs: one extra word per stack record, a promotion walk on every `call/cc`, and internal
fragmentation proportional to the segment size times the number of live one-shot continuations.

Measured, on a 96MB DEC Alpha 3000/600 under OSF/1:

- `tak` modified so every call captures and invokes a continuation: `call/1cc` is 13% faster and
  allocates 23% less than `call/cc`.
- Thread systems with 10, 100 and 1000 threads each computing `fib(20)`, context switch frequency
  varied from every call to every 512 calls. `call/1cc` is consistently faster than `call/cc` but
  the margin is a few percent below one switch per 128 calls. CPS threads beat both only when
  switching more often than roughly once every four calls, and lose their advantage quickly.
- Deeply recursive program, one million calls with little work between: overflow handling via
  one-shot is 300% faster and allocates far less, because after the first recursion the stack
  cache always has a fresh segment ready.

# Relevance

Two things to take.

The first is the overflow result, which applies to us regardless of whether we ever expose
`call/1cc`. The runtime in CUJ Step 5 needs a stack overflow path, and handling it as an implicit
one-shot capture removes the copying on underflow for free. Implement the hysteresis (copy several
frames up on overflow) at the same time, because the bouncing pathology is not something to
discover later under a profiler.

The second is that the segmented stack is what makes precise GC roots tractable, which is the
CUJ's stated reason for owning the back end. Frames are contiguous within a segment, the frame-size
word in the code stream drives the walk, and the stack maps stage 13 emits attach to exactly those
return points. The whole scheme composes: one representation serves continuations, exception
handling, debugging and precise collection.

The number to keep is 0.1 instructions per frame of continuation overhead across a large benchmark
set, which is what a direct-style stack-based Chez actually costs. That is the figure that
justifies choosing a stack over a CPS heap for a Scheme meant to match SBCL, and it is far below
the 7.4 instructions per frame that Appel and Shao's simulated stack model reports.

# Notes

**Identity confirmed, and the bibliography's earlier concern is resolved correctly.** The title
page reads "Representing Control in the Presence of One-Shot Continuations," by Bruggeman, Waddell
and Dybvig, Proceedings of PLDI 1996, pages 99-107. The file is 9 pages and was fetched from
`call1cc.pdf`. It is a genuinely different paper from `hieb-dybvig-bruggeman-representing-control-in-the-presence`,
which is 12 pages, titled "Representing Control in the Presence of First-Class Continuations," by
Hieb, Dybvig and Bruggeman, PLDI 1990, fetched from `stack.pdf`, and cited by this paper as [16].
Both slugs are correct, both entries in the plan (lines 370-371) are correct, and the note at lines
285-286 that `oneshot.pdf` never existed and there is no separate Dybvig and Hieb `call/1cc` paper
is confirmed. No correction to make.

The rebuttal of Appel and Shao in section 5 deserves attention because it is a methodological
point, not a scoring dispute. Appel and Shao measured roughly equal per-frame overhead for
heap-based and stack-based control (7.5 versus 7.4 instructions per frame), attributing 3.4 of the
stack-based figure to closure creation, and reported 5.75 instructions per frame of closure
overhead on Boyer. Chez allocates *no* closures at all on Boyer and measures about 0.1 instructions
per frame overall. The explanation offered is that Appel and Shao's "stack-based" model is a CPS
compiler with stack-allocated continuations, which forbids the frame sharing a direct-style
compiler gets for free: a variable live across several calls must be copied into each continuation
frame in their model, and stays in one stack slot in Chez. Any future comparison of control
representations in our own work should avoid the same trap.

The paper is honest about where one-shot continuations do not pay: below one context switch per
128 procedure calls the advantage over `call/cc` is a few percent, and it says so in the
conclusion.
