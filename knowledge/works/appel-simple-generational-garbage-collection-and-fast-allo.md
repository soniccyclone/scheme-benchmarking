---
type: paper
title: "Simple Generational Garbage Collection and Fast Allocation"
description: A two-generation copying collector for stock hardware whose allocation path costs zero instructions of overhead, with a page-fault-driven heap-limit check and a heuristic for when to ask the OS for more memory.
resource: knowledge/sources/appel-simple-generational-garbage-collection-and-fast-allo.pdf
tags: [generational-gc, copying-collection, allocation, write-barrier, runtime]
authors: [Andrew W. Appel]
year: 1988
venue: "Princeton University CS-TR-143-88, March 1988, revised September 1988 (journal version: Software-Practice and Experience 19(2), 1989)"
informs: [/techniques/generational-gc.md, /techniques/storage-class-assignment.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Not a new algorithm. A *recipe*: the cheapest generational copying collector you can build
on a stock Unix machine with no special hardware, no page-protection support beyond
segmentation faults, and no OS cooperation beyond `brk()`. Three specific results. Allocation
overhead can be driven to literally zero instructions beyond the stores you had to do
anyway. Two generations beat many, because two maximizes the size of the nursery and
therefore minimizes the chance any young object is ever copied. And there is a robust
heuristic for when to grow the heap, which the paper notes most collected environments
simply do not have.

# Mechanism

**Copying core.** Cheney's algorithm, using the destination region as its own BFS queue.
Two pointers into the destination, `scan` and `next`. `forward(R)`: if `R` points into
source, and `R[1]` already points into destination, return `R[1]`; else copy the record to
`next`, store `next` into `R[1]` as the forwarding pointer, bump `next`, return. Apply
`forward` to each root, then sweep `scan` forward applying `forward` to each word until
`scan` catches `next`. Pointer-free objects identifiable from their first word cause `scan`
to skip to their end. No auxiliary stack.

**Allocation fast path.** With a compacting collector free memory is one contiguous region,
so `(cons A B)` is: test free pointer against limit, branch to collector, decrement free
pointer by 2, store A, store B, return. The test and branch are removed by mapping an
inaccessible page immediately past the free region: the store itself faults, the handler
runs the collector. On a VAX this collapses to `movl B,-(fsp)` / `movl A,-(fsp)`, two
instructions, which is exactly the two stores the values needed anyway. Zero overhead.

**Variable-sized records.** The trap must fire before any of the record is written, or you
are left with a half-allocated object. Since a record can straddle a page boundary you
cannot rely on the first store faulting, so store the *last* word first; if that succeeds
every other store is guaranteed (given the record is not larger than a page, or given
several inaccessible pages in a row). Records are allocated upward, so the sequence is
last-word store, remaining stores descending, format descriptor at offset 0, save pointer,
bump `fsp`. Three schemes for record format are listed and the tag-word one is chosen:
per-record tag, per-region layout lookup by address (this is BIBOP), or a compiler-supplied
map of the static type system.

**Heap layout.** Under Unix the only conveniently inaccessible page is at the program break,
so both generations live in the heap area, laid out
`[bss][older][reserve][newer][free][inaccessible]`. The nursery grows up into `free` until
it faults. A minor collection copies the nursery's live data `x` onto the end of `older`,
then splits the remaining space into a new `reserve` and `free`. Note the nursery boundary
moves by `|x|/2` each cycle. When `x` straddles the midpoint `h` of the heap, do a major
collection: copy the live data of `older` into the reserve to the right of `x`, *leaving x
in place* (its pointers must still be scanned, since they are roots for `older`). Since all
of `x` is known live, the copied residue is `A - |x|`, which is guaranteed to fit. Then
block-move `x` and `older'` to the start of the heap.

**Invariant and heap growth.** If live data `A` is less than half of memory `M`, the
collector never runs out. Let `gamma = M/A`. Below 2 it fails, near 2 it thrashes, 3 or more
is healthy. Ask `brk()` for more after a major collection when `gamma < gamma_0`; or when
the copy of `older` into `reserve` runs out (then `gamma < 2` unconditionally); or when
after a minor collection `free` is barely larger than the request that triggered collection
(a large-object request that would push `A` over `M/gamma_0`). No special case is needed for
a request so large that one growth is insufficient; `M` grows on each failure until it fits.

**Write barrier.** Not Lieberman-Hewitt's indirection through an assignment table (every
*fetch* pays), not Moon's ephemeral-GC hardware (needs VM hardware), but Ungar's list of
assigned-into records, simplified: record *every* assignment destination, filter at
collection time. The collector keeps `(R,P)` only when `R` is outside the collected space
and `P` is inside; duplicates are harmless because the first visit rewrites `R` with a
destination pointer and destination pointers are recognizable. Cost is about 4 instructions
to append and about 4 to examine, roughly 10x the cost of a bare store; with pointer stores
under 1% dynamically in SML, that is 5-30% on stores and negligible overall. The list can be
allocated from the ordinary free area. Crucially, with exactly two generations and
merge-on-promotion, *the assignment list is discarded after every minor cycle*. That is the
whole reason two generations is simple; with more, you need several root sets and a pruned
survivor list.

**Trap handling.** Roots are globals, the stack, machine registers, and the assignment list.
The kernel pushes some registers on segfault, the handler pushes the rest; modify the saved
copies and let the kernel restore them. The push order is undocumented and version-dependent,
so the runtime *discovers it at startup*: load known values into registers, deliberately
fault, and find them on the stack. Some registers get pushed twice. On some machines the
saved PC does not point at the faulting instruction and must be adjusted.

Measured: SML/NJ allocates a word per ~30 instructions; overhead 11% at `gamma = 3`, 6% at
`gamma = 7`; collector is ~500 lines of C; 1 MB major collection ~2s on a VAX-8650, minor
~40 ms.

# Applicability

Depends entirely on assignments to already-initialized records being rare. The paper says so
directly: generational collection is probably *not* appropriate for Algol-like languages
where assignment is the main way to build structure, and is worthwhile for Lisp, ML, Prolog.
It is a stop-the-world collector, not incremental; pause is proportional to live data, which
for a major collection is the whole heap residency.

The zero-overhead allocation trick has preconditions people forget: an inaccessible page you
control, a signal handler that can resume the faulting instruction, records no larger than a
page (or a run of inaccessible pages), and the last-word-first store order. Take any of them
away and you are back to an explicit compare, which costs one cycle and is what Chez
actually does.

Requires `M >= 2A` to guarantee progress and `M >= 3A` for decent throughput. That is the
real price of copying collection and it is not negotiable.

# Relevance

This is our collector, and it is the reason rejecting Boehm was correct. Boehm is a
mark-sweep conservative collector: it cannot move objects, so it cannot give you a bump
allocator, so the allocation path is a free-list search rather than two stores; it cannot
compact, so locality degrades; and conservative roots mean it must treat integers that look
like pointers as live. Everything cheap in this paper (bump allocation, zero-instruction
fast path, no free list, time proportional to live data rather than heap size, immediate
reuse of vacated pages) follows from the collector being *precise* and *copying*, which is
also why the compiler must emit live-pointer maps. The BIBOP paper's behind-the-return-point
live mask is the mechanism; this paper is why we pay for it.

What to take directly: Cheney with the destination as queue; the `gamma`-based heap growth
heuristic with its three trigger conditions, since a collector with no growth policy is a
collector that dies under a workload you did not benchmark; and the "record every assignment,
filter at collection" barrier as the *baseline* against which to justify anything fancier.
Chez's card marking is the fancier thing, and BIBOP explains why it wins once you have more
than two generations, but Appel's list is what makes two generations nearly free.

What to reject: the page-fault allocation trick. Two instructions saved per allocation is not
worth a signal handler that must resume a faulting instruction, discover kernel register-save
order at startup, and adjust the PC per architecture. On x86-64 with a register-pinned
allocation pointer, the compare is a cycle and predicts perfectly. Dybvig et al. reached the
same conclusion and say explicitly that explicit checks "have not been a performance problem
in practice."

The two-generations argument deserves scrutiny rather than acceptance. It rests on
maximizing nursery size to minimize young-object copying, and on the assignment list being
discardable per minor cycle. Chez runs a tunable number of generations and pays for it with
the youngest-generation byte in each dirty card. Both designs are coherent; the choice
depends on whether our workloads have a mature-object population large enough that repeated
major collections dominate.

# Notes

**Bibliography correction (year and document type).** The plan lists this as "Appel, *Simple
Generational Garbage Collection and Fast Allocation* (1989)". The PDF's title page reads
"March 1988, revised September 1988" and is Princeton tech report CS-TR-143-88; the URL in
the plan (`papers/143.pdf`) matches that report number. The 1989 date belongs to the journal
version in *Software-Practice and Experience* 19(2):171-183. The document we hold is the
1988 tech report and should be catalogued as such, citing the journal version as the
published form.

Amusing cross-check on the title: the BIBOP paper (also in this bundle) cites this same
report as "Simple garbage collection and fast allocation", dropping "generational". The word
is present in this PDF's title. BIBOP's citation is the wrong one.

Dated in the obvious places, and worth reading past them. The VAX auto-decrement trick, the
`brk()` interface, and the whole section on reverse-engineering the kernel's register push
order are period artifacts. The startup-time discovery of the register save layout is
genuinely good engineering (dynamic lookup instead of a hardcoded per-platform table) and
the pattern is worth keeping even though the specific problem is gone.

One claim is quietly hedged in a footnote and matters: Steve Vegdahl pointed out that with
old-to-new pointers from assignments, the collector can be driven to ask for more memory
even when `A < M/2`, so the headline invariant is not quite unconditional.
