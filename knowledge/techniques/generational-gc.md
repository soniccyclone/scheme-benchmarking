---
type: technique
title: Generational garbage collection
description: A precise copying collector that segregates objects by age, so allocation is a pointer bump and collection time is proportional to live young data rather than heap size; costs a write barrier, a 2x to 3x memory headroom factor, and stack maps from the compiler.
tags: [generational-gc, copying-collection, write-barrier, bibop, allocation, precise-roots]
sources:
  - resource: /works/appel-simple-generational-garbage-collection-and-fast-allo.md
  - resource: /works/dybvig-et-al-bibop.md
  - resource: /works/abelson-sussman-sicp.md
  - resource: /works/chambers-ungar-an-efficient-implementation-of-self-oopsla-.md
  - resource: /works/dybvig-et-al-the-development-of-chez-scheme-icfp-2006.md
  - resource: /works/leroy-unboxed-objects-and-polymorphic-typing-popl-1992.md
  - resource: /works/hieb-dybvig-bruggeman-representing-control-in-the-presence.md
implemented_by: [/implementations/chez.md, /implementations/sbcl.md]
absent_from: []
pipeline_stage: n/a
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

Allocation must cost about what the stores you were going to do anyway cost, and collection
must cost time proportional to *live* data rather than to heap size. Both follow from the
collector being precise and copying, and neither is available from a conservative mark-sweep
collector: Boehm cannot move objects, so it cannot give you a bump allocator; it cannot
compact, so locality degrades; and conservative roots mean an integer that looks like a
pointer keeps memory alive.

This document absorbs `stop-and-copy-gc`, because a generational collector's nursery
collection *is* stop-and-copy. Generations add a promotion policy and a write barrier;
nothing in the copy loop changes.

# Mechanism

**The copy loop (Cheney).** Use the destination region as its own BFS queue. Two pointers
into the destination, `scan` and `next`.

```
forward(R):  if R points into source:
                 if R[1] points into destination: return R[1]      ; already moved
                 copy the record to next; R[1] <- next             ; forwarding pointer
                 next <- next + size(R); return the old next
apply forward to every root
while scan < next: apply forward to the word at scan; scan++
```

Pointer-free objects identifiable from their first word let `scan` skip to their end. No
auxiliary stack, ever. SICP §5.3.2 is this same algorithm as about 40 register-machine
instructions, with a broken-heart tag in the from-space `car` and the forwarding address in
the `cdr`; it is worth keeping as an executable reference to check a nursery evacuation loop
against.

**Generations and layout.** Appel: two of them, in one heap area, laid out
`[bss][older][reserve][newer][free][inaccessible]`. The nursery grows up into `free`. A minor
collection copies the nursery's live data `x` onto the end of `older`, then splits the
remaining space into a new `reserve` and `free`; the nursery boundary moves by `|x|/2` each
cycle. When `x` straddles the heap midpoint, do a major collection: copy `older`'s live data
into the reserve to the *right* of `x`, leaving `x` in place, because `x`'s pointers are
still roots for `older`. Since all of `x` is known live, the copied residue is `A - |x|` and
is guaranteed to fit. Then block-move `x` and `older'` to the start of the heap.

Chez runs five generations, generation 4 static, collecting generation *n* every 4^n
collections. Dybvig is candid that this "rather arbitrary strategy was initially just a hack
for testing, but it turned out to work well, indeed better than several more elaborate
strategies we tried."

**Heap growth, which most collectors simply lack.** Let `γ = M/A`, memory over live data.
Below 2 the collector fails, near 2 it thrashes, 3 or more is healthy. Ask the OS for more
memory on three triggers: after a major collection when `γ < γ₀`; when the copy of `older`
into `reserve` runs out, which means `γ < 2` unconditionally; and when after a minor
collection `free` is barely larger than the request that triggered the collection. No special
case is needed for a request so large that one growth is insufficient, since `M` grows on
each failure until it fits. Vegdahl's footnote qualifies the headline invariant: with
old-to-new pointers from assignments, the collector can be driven to ask for more memory even
when `A < M/2`.

**Write barrier, two designs.** Appel records *every* assignment destination in a list and
filters at collection time, keeping `(R,P)` only when `R` is outside the collected space and
`P` is inside; duplicates are harmless because the first visit rewrites `R` with a
recognizable destination pointer. About 4 instructions to append and 4 to examine, roughly
10x a bare store; with pointer stores under 1% dynamically in SML that is 5-30% on stores and
negligible overall. Crucially, with exactly two generations and merge-on-promotion, **the
list is discarded after every minor cycle**. That is the whole reason two generations is
simple.

Chez uses card marking, one *byte* per 1K card, four cards to a segment, word-aligned so the
collector can scan four cards with a single 32-bit compare against `ffffffff`. Bytes rather
than bits deliberately: a byte store beats a read-modify-write bit set, and the byte value
carries the *youngest generation reachable from this card*, refined by the collector on each
sweep. The mutator barrier is two instructions inline — extract the card index from the
destination address, store zero. With more than two generations this is what stops the
collector sweeping every dirty card on every minor collection.

**Collector metadata (BIBOP).** A pointer decomposes as `[segment number | segment offset |
3-bit tag]`, with 4K segments and 8-byte alignment. The segment number indexes a segment
table carrying a metatype tag, a generation number, a large-object flag and an old-space
flag. Metatypes: hole (memory owned by another runtime, never touched), executable,
pointer-free, pointer-containing read-only, pointer-containing read-write, stack, weak-pair,
and "new". The trick that revived BIBOP is *delaying* metatype assignment until an object
survives its first collection, so newly allocated objects all go into one "new" area behind
one allocation pointer. Compiled code is bit-identical to what a flat-heap model would emit;
all the BIBOP cost sits inside the collector. Large objects simply span segments, are copied
once on first collection into a run of contiguous segments, and thereafter are forwarded by
editing a segment-table entry. No large-object area, no free list, no header indirection.

The immutable/mutable metatype split looks minor and is not: it removes whole segments from
the dirty-card scan, since only writable pointer-containing segments can hold an old-to-young
pointer.

**Precise roots.** Behind each return point *in the instruction stream* the compiler stores
three words: frame size, live-pointer mask, and code-object offset. The collector walks the
stack using the frame size, sweeps only masked slots, and uses the code-object offset to
forward the untagged return address into the middle of a code object. Large frames get a
heap-allocated mask pointed at from that slot. Code objects carry a relocation table of
(code offset, item offset, addressing mode) per embedded pointer, and the header self-pointer
is updated last so PC-relative displacements can be recomputed from the old-to-new
displacement. **This is the mechanism that makes an unboxed float in a stack slot safe.**

**Segregation (Chambers, Ungar and Lee).** Split each space: byte arrays grow down from one
end, everything containing references grows up from the other. Reference scans then never
touch byte arrays and never parse object headers, and a sentinel word past the end, matching
the scan criterion, removes the bounds check from the inner loop. 3 MB/s against 1.6 MB/s for
a non-segregated Smalltalk on the same 68020.

**Flonums (Chez v4).** The collector never forwards a flonum; it may duplicate it. Legal
because `eq?` on numbers may always return `#f`. Halves flonum size and lets an inexact
complexnum be two adjacent doubles.

# Preconditions

Assignments into already-initialized records must be rare. Appel says so outright:
generational collection is probably *not* appropriate for Algol-like languages where
assignment is the main way to build structure, and is worthwhile for Lisp, ML and Prolog.

`M ≥ 2A` to guarantee progress and `M ≥ 3A` for decent throughput. That is the real price of
copying collection and it is not negotiable.

The compiler must emit live-pointer maps and relocation tables. Leroy's alternative is to
make every value of unknown type a valid heap pointer by boxing wrapped integers, which buys
an exact collector without maps at the cost of boxed fixnums; he names ambiguous-roots
collection as the option he rejected.

Nothing else. BIBOP needs 8-byte alignment and an OS that hands back memory on demand. No
virtual memory tricks, no page protection, no OS cooperation beyond allocation.

It is stop-the-world. Pause is proportional to live data, which for a major collection is
whole-heap residency.

# Cost

Appel's measurements: SML/NJ allocates a word per ~30 instructions; total overhead 11% at
`γ = 3` and 6% at `γ = 7`; the collector is ~500 lines of C; a 1 MB major collection takes
about 2s on a VAX-8650 and a minor about 40 ms.

BIBOP costs an extra memory reference for any type test that goes through the table, which is
precisely why primary types stay in the pointer; a few bytes of table per 4K segment;
intra-segment fragmentation when a metatype is extended before its segment fills, which the
4K size is chosen to bound and which the authors report is not a problem in practice without
giving numbers; and slightly more work per copied object, since multiple destination
allocation pointers are live, mitigated by pinning the common ones in registers during
collection.

# Disagreements

**The allocation fast path. This is a real, named conflict between two sources we hold.**

Appel drives allocation overhead to literally zero instructions. With a compacting collector
free memory is one contiguous region, so `(cons A B)` is a test against a limit, a branch to
the collector, a decrement, and two stores. Map an inaccessible page immediately past the free
region and the test and branch disappear: the store itself faults and the handler runs the
collector. On a VAX this collapses to `movl B,-(fsp)` / `movl A,-(fsp)`, exactly the two
stores the values needed anyway. The preconditions are specific and people forget them: an
inaccessible page you control, a signal handler that can resume the faulting instruction,
records no larger than a page (or a run of inaccessible pages), and last-word-first store
order, because a record can straddle a page boundary and a trap fired halfway through leaves a
half-allocated object.

Dybvig, Eby and Bruggeman explicitly reject it. They implemented explicit compares against a
register-held end pointer, hoisted to procedure entry and reentry rather than done per
allocation, and report that the checks "have not been a performance problem in practice."

Both papers are in this bundle, both authors knew of the other's design, and the disagreement
is substantive rather than an oversight. On modern hardware Chez's side wins on the arithmetic
alone: a fault costs microseconds, a compare against a register costs a cycle and predicts
perfectly. Appel's trick also carries a compiler obligation that is rarely mentioned, namely
guaranteeing one write per page before the allocation counts as done.

**How many generations.** Appel argues two, because two maximizes nursery size and therefore
minimizes the chance any young object is ever copied, and because with two plus
merge-on-promotion the assignment list is discardable per minor cycle. Chez runs five and
pays for it with the youngest-generation byte in each dirty card. Both designs are coherent;
the choice turns on whether the workload has a mature-object population large enough that
repeated major collections dominate.

**The write barrier follows from that choice** and the two designs do not dominate each other.
Appel's unfiltered assignment list is nearly free at two generations and untenable past them;
card marking costs a byte per KB unconditionally and scales.

**Object format.** Appel enumerates three schemes — a tag word per record, a per-region
layout lookup by address (which is BIBOP), and a compiler-supplied map of the static type
system — and picks the tag word. BIBOP picks the second for collector metadata and low tags
for the mutator. Same menu, different answer.

**One citation error to carry forward.** The BIBOP paper cites Appel's report as "Simple
garbage collection and fast allocation", dropping "generational". The word is in Appel's
title. BIBOP's citation is the wrong one.

# For us

Runtime, not a pipeline stage. The CUJ Step 5 specification (two generations, bump allocation
in the nursery, Cheney scan on collection, precise roots from stage 13 stack maps) is Appel's
recipe minus the page-fault trick, and minus it is correct.

Three things the CUJ does not name and should:

1. **The `γ`-based growth heuristic with all three triggers.** A collector with no growth
   policy is a collector that dies under a workload you did not benchmark. The CUJ's "a bump
   allocator that never collects is enough through milestone 5" is true for `nbody` and is
   exactly the reason the growth policy gets skipped and then bites later.
2. **The behind-the-return-point live mask, in the BIBOP form** (frame size, live-pointer
   mask, code-object offset). Stage 13 owes this to the collector *and* to the stack-segment
   continuation machinery, which walks frames the same way. It is also the precondition for
   keeping unboxed f64 in stack slots across a collection, which stages 08 and 10 depend on.
3. **Byte-array/reference segregation with the sentinel.** Free, and aimed directly at an
   flvector-heavy heap.

Do not implement the unforwarded-flonum trick before deciding whether flonums are boxed at
all. If stage 08 does its job on the benchmark kernels there are no flonums in the heap to
collect, and the trick is a fix for a cost we intend not to pay.

Bibliography corrections to carry: Appel's document is Princeton CS-TR-143-88, March 1988,
revised September 1988; the 1989 date belongs to the *Software-Practice and Experience*
19(2):171-183 journal version. The BIBOP paper is *Don't Stop the BIBOP: Flexible and
Efficient Storage Management for Dynamically Typed Languages*, Indiana University CS
Technical Report #400, March 1994, by R. Kent Dybvig, David Eby and Carl Bruggeman — three
named authors, not "et al.", and never a conference or journal paper.
