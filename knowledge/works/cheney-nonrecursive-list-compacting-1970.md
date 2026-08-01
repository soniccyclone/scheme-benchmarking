---
type: paper
title: "A Nonrecursive List Compacting Algorithm"
description: The two-page note introducing the copying collector's scan/next Cheney loop, which replaces the recursion or pointer-reversal of earlier compactors by using the partially built to-space as its own worklist.
resource: knowledge/sources/cheney-nonrecursive-list-compacting-1970.pdf
tags: [garbage-collection, copying-collector, compaction, list-structures, breadth-first]
authors: [C. J. Cheney]
year: 1970
venue: "Communications of the ACM 13(11), November 1970, pp. 677-678"
informs: [/techniques/generational-gc.md, /techniques/tagging.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-08-01T00:00:00Z" }
---

# Contribution

Hansen (CACM 1969) and Fenichel and Yochelson (CACM 1969) had both published compacting
collectors, and both recursed on encountering a list pointer, so both needed a stack
proportional to structure depth — precisely the resource you do not have when you are
collecting because you ran out of memory. Fenichel and Yochelson suggested a nonrecursive
version could be built on Deutsch-Schorr-Waite pointer reversal, which trades the stack for
a destructive traversal and a tag bit per cell.

Cheney's note is two pages and says: neither. The partially built copy in the new area is
itself a perfectly good record of what has been copied and what has not. Keep two pointers
into it, `SCAN` (how far you have processed) and `NEXT` (how far you have filled), and the
gap between them is exactly the worklist. Termination is `SCAN = NEXT`. No stack, no tag
bits, no recursion, no extra space at all beyond two words.

This is the algorithm every copying and generational collector still runs. Its cost is that
the traversal order becomes breadth-first, which is a locality regression from the
depth-first order the recursive versions produced, and which is why later work (Moon's
approximately-depth-first, hierarchical decomposition) exists.

# Mechanism

The data model is Hansen's compact list representation. A cell is an item, a *nonitem*, an
atom, a list pointer, or NIL. Nonitems are the connective cells that chain a list in the CDR
direction and carry no data; they double as the forwarding-pointer mechanism, which is the
economy that makes the algorithm need no extra bit.

**Main loop.**

    1. SCAN <- NEXT <- start of new area
    2. root <- COPYLIST(root)
    3. if the cell at SCAN is a list pointer:
           its contents <- COPYLIST(that pointer)
    4. SCAN <- SCAN + 1; if SCAN /= NEXT goto 3; else done

**COPYLIST(POINTER)**, by value, returns the new-area address of the copied list:

     1. while POINTER points to a nonitem: POINTER <- what the nonitem points to
     2. if POINTER is already in the new area: return POINTER
     3. V <- NEXT
     4. if POINTER is in the new area:            # already-copied sublist
            make the cell at NEXT a nonitem pointing at POINTER; goto 11
     5. copy the cell at POINTER to the cell at NEXT
     6. if POINTER points to NIL: goto 11
     7. make the cell at POINTER a nonitem pointing at NEXT   # forwarding address
     8. NEXT <- NEXT + 1; POINTER <- POINTER + 1
     9. while POINTER points to a nonitem: POINTER <- what the nonitem points to
    10. goto 4
    11. NEXT <- NEXT + 1; return V

Read step 7 carefully, because it is the whole trick used twice. Overwriting the old cell
with a nonitem pointing to its new home is the forwarding pointer; step 1 and step 9 then
chase forwarding chains transparently, since a forwarded cell is indistinguishable from an
ordinary connective nonitem. One representation serves both purposes, so no mark bit is
needed and no separate "has this been copied" test exists beyond the address comparison in
steps 2 and 4.

The COPYLIST inner loop (4-10) walks a list in the CDR direction copying items and skipping
the source structure's nonitems, so the copy is compact: connectives are elided and the
copied items land in consecutive cells. Steps 4 and 11 handle the case where the CDR chain
reaches a cell already in the new area, which is how looped lists terminate — a nonitem is
placed in the new area pointing back at the earlier copy, and Figure 2 walks that case.

Sublists are not copied by COPYLIST. They are left as raw old-area pointers in the new area,
and the linear SCAN pass in the main loop picks them up later. That is the inversion that
removes the recursion: depth becomes breadth, and the stack becomes an interval of the
output.

Cost per transferred item, measured: 30 to 40 instructions on an Atlas, in a hand-written
assembly implementation.

# Applicability

Preconditions are structural, not analytical. You need a *contiguous* new area, since `SCAN`
and `NEXT` are linear cursors and the termination test is pointer equality. You need to be
able to tell, by address comparison, whether a pointer is into the old area or the new one —
Cheney says "e.g. by comparing core addresses". You need cells to be self-describing enough
to distinguish nonitem, atom, NIL, and list pointer.

You need to be willing to destroy the old area, since forwarding overwrites it. That is
fine for a semispace collector and is exactly why the algorithm suits one.

Where it fails, or costs: the copy order is breadth-first by construction, so objects that
are used together are separated by the depth of the structure rather than kept adjacent.
Cheney does not discuss locality at all, which is reasonable for 1970 and is the single
biggest thing the note does not tell you. Also there is no provision for pinned objects,
interior pointers, or ambiguous roots; a conservative collector cannot use this directly.
The note says the algorithm "with some modification can be applied to LISP-type structures,"
and does not say what the modification is.

# Relevance

This is the collector our runtime uses, and the reason to hold the primary source rather
than a textbook restatement is the forwarding-pointer economy. The nonitem doing double duty
as connective and forwarding address is the pattern that generalizes to "overwrite the
from-space header with the to-space address and let the copy routine test for it," which is
what every modern implementation does. Our object headers need a representation for that
state, and it should be a state the copier already has to test for, not a new bit.

The scan/next interval as the worklist is the reason a copying nursery collection is
allocation-proportional rather than heap-proportional, and it is the reason a generational
collector's minor collection costs nothing when the nursery is mostly garbage: the loop
terminates the moment `SCAN` catches `NEXT`, and dead objects are never touched. Appel's
simple generational scheme is this algorithm plus a remembered set.

The locality regression is the thing to plan around, not to ignore. For a Scheme heap where
a pair's car and cdr are almost always used together, breadth-first copying is close to the
worst possible layout. If we want Moon-style approximately-depth-first copying, the change is
local to the main loop (scan the most recently allocated partially filled page first rather
than advancing `SCAN` linearly), so the decision does not have to be made up front, but the
`SCAN`/`NEXT` invariant is what a variant has to preserve.

# Notes

**Read the extraction warning before trusting any text tool on this file.** The PDF's first
column is the tail of a *different* CACM article — the conclusion and reference list of a
hash-coding paper, discussing reduction modulo `n` and citing Morris, Maurer, Bell and
Radke on scatter storage. `pdftotext` opens on that modular arithmetic. Cheney's paper
begins partway down the first page, under the title "A Nonrecursive List Compacting
Algorithm", author C. J. Cheney, University Mathematical Laboratory, Cambridge, England.
Both pages of the actual paper are present and complete: p. 677 (abstract, Figure 1,
narrative walk-through) and p. 678 (Figure 2, the numbered algorithm, acknowledgments,
references). Everything in this document comes from those two pages.

**Bibliographic facts as printed.** CACM 13(11), November 1970, pp. 677-678. Received March
1970, revised June 1970. CR categories 4.19, 4.49. Key words: list compacting, garbage
collection, compact list, LISP. Single author. Acknowledges N. E. Wiseman for discussions
and M. V. Wilkes for criticism of the draft.

**It is a note, not a paper.** Two pages, no evaluation, no comparison, one performance
number, no proof of correctness or termination. The argument for correctness is entirely by
worked figure. That is worth knowing before citing it as if it established properties it
merely exhibits: there is no argument here that the algorithm terminates on arbitrary
structures, no bound on the new area size, and no treatment of what happens if the new area
is too small.

**The name.** Nothing in the paper calls this a "copying collector," a "semispace," a
"Cheney loop," or "breadth-first." Those are all later. The paper's own framing is
compaction of Hansen-style compact lists, and the copying is incidental to compacting. That
framing has a consequence people miss: COPYLIST deliberately *drops* the source structure's
nonitems, so the output is not an isomorphic copy of the input, it is a compacted one. A
modern copying collector preserves object structure exactly and does not do this.

**Figure quality.** The two figures are the load-bearing part of the exposition and they are
degraded in this scan — the ASCII extraction of them is unusable, and even visually the cell
diagrams are faint. The numbered algorithm on p. 678 is clean and is sufficient to implement
from without them.
