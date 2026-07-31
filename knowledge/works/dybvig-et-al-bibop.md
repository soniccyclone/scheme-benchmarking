---
type: paper
title: "Don't Stop the BIBOP: Flexible and Efficient Storage Management for Dynamically Typed Languages"
description: Describes Chez Scheme's hybrid tagging scheme, where low-tagged pointers carry primary types and a per-segment BIBOP table carries collector-facing metatypes, so a segmented heap still allocates from one inline pointer.
resource: knowledge/sources/dybvig-et-al-bibop.pdf
tags: [bibop, storage-management, generational-gc, object-representation, card-marking]
authors: [R. Kent Dybvig, David Eby, Carl Bruggeman]
year: 1994
venue: "Indiana University Computer Science Department Technical Report #400, March 1994"
informs: [/techniques/generational-gc.md, /techniques/storage-class-assignment.md, /techniques/tagging.md]
pipeline_stage: 08-represent
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

BIBOP had been written off by 1994 because per-type allocation pointers kill the inline
allocation fast path and because large objects were thought to be awkward. This paper kills
both objections. The trick is to *split* typing into two layers with different consumers:
primary types the mutator cares about live in the low three bits of the pointer, and
metatypes only the collector cares about live in a per-segment table. Then delay metatype
assignment until an object survives its first collection, so newly allocated objects all go
into one "new" area behind one allocation pointer. The compiled code is bit-identical to
what a flat-heap model would produce; all the BIBOP cost is inside the collector.

# Mechanism

Address decomposition: pointer = [segment number | segment offset | 3-bit tag]. Segments are
4K. All objects are 8-byte aligned so the low three bits are free. Three bits do not cover
Scheme's type set, so one primary tag is an escape to a *typed object* whose header carries
a secondary type; length and type tag can be packed together since length is usually loaded
anyway for a bounds check.

The segment number indexes two parallel tables:

- **Segment table**, one entry per 4K segment: metatype tag, generation number, plus three
  subfields (large-object flag, old-space flag, general metatype). Metatypes in use include
  "hole" (memory owned by another language's runtime, never touched), "executable" (code,
  kept off data pages so instruction-cache flushing is bounded), pointer-free, pointer-
  containing read-only, pointer-containing read-write, stack, weak-pair, and "new".
- **Dirty vector**, one *byte* per 1K card, four cards to a segment, word-aligned so the
  collector can scan four cards with a single 32-bit compare against `ffffffff`.

Allocation: bump one register-held pointer, compare against a register-held end pointer.
The check is hoisted to procedure entry/reentry rather than per-allocation. Only code
objects and weak pairs get their own allocation pointer at birth; everything else is sorted
into metatypes by the collector when it copies the object, and the collector needs the
primary type to copy correctly anyway, so the sort is nearly free.

Card marking with bytes rather than bits, deliberately. A byte store is cheaper than a
read-modify-write bit set, and the byte value carries the *youngest generation reachable
from this card*, refined by the collector on each sweep. The mutator's write barrier is
just: extract card index from the destination address, store zero into the dirty vector.
Inline, no out-of-line call. With more than two generations this is what stops the
collector sweeping every dirty card on every minor collection.

Large objects: objects simply span segment boundaries, since metatype lives outside the
segment. On first collection a large object is copied once into its own run of contiguous
segments, marked "large", and thereafter is forwarded by editing its segment-table entry
and queueing it for sweeping. Objects too big for the current new area skip the first copy
entirely. No separate large-object area, no free list, no header indirection (contrast
Ungar, contrast Hudson).

Stacks get a metatype because frames mix pointers, floats, and alignment holes. Behind each
return point in the *instruction stream* the compiler stores three words: frame size,
live-pointer mask, and code-object offset. The collector walks the stack with the frame
size, sweeps only masked slots, and uses the code-object offset to forward the untagged
return address into the middle of a code object. Large frames get a heap-allocated mask
pointed to from that slot. Code objects carry a relocation table listing (code offset, item
offset, addressing mode) per embedded pointer; the header's self-pointer is updated last so
PC-relative displacements can be recomputed from the old-to-new displacement.

Segment table is resizable, kept contiguous so indexing is a shift and add, and relocated
when the next contiguous segment is unavailable.

# Applicability

Costs an extra memory reference for any type test that goes through the table, which is why
the primary types stay in the pointer. Costs a few bytes of table per 4K segment. Costs
intra-segment fragmentation when a metatype is extended before its current segment is full;
the 4K segment size is chosen to bound that, and the authors report it is not a problem in
practice without giving numbers. Costs the collector slightly more per copied object,
because multiple destination allocation pointers are live; mitigated by pinning the common
ones in registers during collection.

Preconditions: 8-byte alignment, an OS that can hand back more memory on demand (`sbrk`),
and a compiler willing to emit live-pointer masks and relocation tables. Nothing else. No
virtual-memory tricks, no page protection, no OS cooperation beyond allocation.

# Relevance

This is our runtime. Take the layer split as the design rule: the mutator sees low tags and
never consults the table; the table is a collector-private index. That keeps `08-represent`
honest, because storage class assignment then only has to decide primary representation
(immediate fixnum, immediate char, low-tagged pointer, escape to typed object) and can
ignore everything the GC needs.

Concrete items to lift: byte-per-card dirty vector with the youngest-generation refinement,
the inline two-instruction write barrier, the hoist of the allocation-limit check to
procedure entry, and the behind-the-return-point live mask. That last one is what makes
unboxed floats on the stack safe, which is precisely what `08-represent` and `10-vectorize`
need in order for packed f64 work to survive a collection. Hole metatypes are also what let
us link against C libraries without pinning the heap layout.

The immutable/mutable metatype split is worth taking even though it looks minor: it removes
whole segments from the dirty-card scan, since only writable pointer-containing segments
can ever hold an old-to-young pointer.

# Notes

**Bibliography correction.** The plan lists this only as "Dybvig et al., BIBOP" with no
title, year, or venue. The PDF's own title page reads *Don't Stop the BIBOP: Flexible and
Efficient Storage Management for Dynamically Typed Languages*, by R. Kent Dybvig, David Eby,
and Carl Bruggeman, Indiana University Computer Science Department Technical Report #400,
March 1994. This was never a conference or journal paper as far as the document shows; cite
it as a tech report. "Dybvig et al." also under-credits Eby and Bruggeman, who are named
authors, not et al.

Note the deliberate rejection of the page-protection allocation trick that Appel recommends
(map the page past the new area read-only, let the store fault). The authors implemented
explicit checks instead and report the checks "have not been a performance problem in
practice." Given that a fault costs microseconds and a compare costs a cycle, and that the
trick requires the compiler to guarantee one write per page before the allocation is
considered done, this is the correct call and we should follow it.

The forward-looking section on tagless collection for ML is honest about what it does not
solve: segregating by *type* rather than by characteristic fragments badly when a program
defines many types with few instances each. The proposed hybrid, common types get their own
metatype and the tail share a tagged metatype, with the split decided dynamically from
object counts, is sketched but not implemented.
