---
type: paper
title: "Linear Scan Register Allocation"
description: A greedy single-pass global register allocator over coarse live intervals that runs in O(V) time and produces code within roughly 10% of an aggressive graph-coloring allocator.
resource: knowledge/sources/poletto-sarkar-linear-scan-register-allocation-toplas-1999.pdf
tags: [register-allocation, linear-scan, live-intervals, jit-compilation, spilling]
authors: [Massimiliano Poletto, Vivek Sarkar]
year: 1999
venue: "TOPLAS 21(5), September 1999, 895-913"
informs: [/techniques/register-allocation.md, /techniques/live-interval-analysis.md]
pipeline_stage: 12-regalloc
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Global register allocation without an interference graph. The graph-coloring framework costs
worst-case quadratic space in the number of live ranges, and the paper's own pathological
benchmarks show that cost is real, not theoretical: at 512 simultaneously live variables,
whole-compilation time with coloring is over 600 times that with linear scan. Linear scan
replaces the graph with a list of live intervals sorted by start point and one greedy forward
pass. The contribution is as much the measurement as the algorithm: it establishes what the
quality penalty actually is against a serious coloring allocator (George and Appel's iterated
register coalescing) rather than against a strawman.

# Mechanism

A live interval for `v` is the single pair `[i, j]` such that no instruction numbered below `i`
or above `j` has `v` live. Subranges within `[i, j]` where `v` is dead are ignored. This is the
entire representational commitment of the algorithm and the source of all its weaknesses. The
numbering can be depth-first (reverse postorder) or layout order; the paper measures both and
they produce near-identical code.

```
LinearScanRegisterAllocation:
  active <- {}
  foreach interval i in increasing start point:
    ExpireOldIntervals(i)
    if length(active) = R: SpillAtInterval(i)
    else:
      register[i] <- a register from the free pool
      insert i into active, keyed on increasing end point

ExpireOldIntervals(i):
  foreach j in active in increasing end point:
    if endpoint[j] >= startpoint[i]: return
    remove j from active; free register[j]

SpillAtInterval(i):
  spill <- last interval in active            # the one ending furthest away
  if endpoint[spill] > endpoint[i]:
    register[i] <- register[spill]
    location[spill] <- new stack slot
    remove spill from active; insert i into active
  else:
    location[i] <- new stack slot
```

`active` is bounded by `R`, so `ExpireOldIntervals` touches exactly the intervals it removes
plus at most one. Complexity is O(V) for fixed R, O(V log R) if insertion into `active` uses a
balanced tree, O(V·R) with the linear insertion the authors actually implemented and measured.

The spill heuristic is Belady-flavored: evict whatever ends furthest from the current point.
On straight-line code with one definition and one use per interval this is provably minimal in
spill count. The paper also tries an interval-weight (estimated usage count) heuristic; results
are identical everywhere except `fpppp`, where interval length wins by more than a factor of
two, 90.8s versus 198.6s. Length also needs no usage-count bookkeeping, so it wins twice.

Section 6.1 offers an SCC-based approximate liveness that skips iterative dataflow: decompose
the flow graph into strongly connected components, take each variable's interval as spanning
from the lowest to the highest DFN of any SCC that mentions it. It is much faster and the
generated code is much worse on anything large (`espresso` goes from 1.18x graph coloring to
6.68x, `fpppp` from 1.02x to 5.43x). The authors' verdict is that it is not a substitute for
full liveness, and that is a settled question rather than an open one.

# Applicability

Preconditions: live variable information already computed, a total order on pseudo-instructions,
and virtual registers rather than physical ones in the IR. What the algorithm does not do, all
of it deliberate:

- **No live-range splitting and no lifetime holes.** A variable defined before a loop nest and
  used after it occupies a register for the whole nest.
- **No coalescing.** They sketch an extension to `ExpireOldIntervals` for the case where `v1`'s
  interval ends exactly where `v2 <- v1` begins, and then admit that without splitting the
  opportunities occur only outside loops.
- **No renaming.** They suggest webs or SSA renaming as an optional prepass and leave the
  cost/benefit open.
- **Pre-colored registers are awkward.** When the scan meets a pre-allocated interval it must
  evict whatever in `active` holds that register, and because intervals are coarse, two
  intervals both needing the same physical register can overlap. The authors state plainly that
  the fix is to let a variable live in different locations over its lifetime, which is to say,
  to become binpacking.
- **Caller-saved registers.** Either use all registers and insert saves/restores around calls
  afterwards, or import binpacking's notion of a register lifetime hole. They did one in each
  of their two implementations.

Measured quality against iterated register coalescing (Machine SUIF, Alpha 21164): fpppp 1.02,
alvinn 1.06, tomcatv 1.06, sort 1.06, swim 1.09, li 1.10, compress 1.12, espresso 1.18, wc 1.43.
Against second-chance binpacking, similar output quality but linear scan is two to three times
faster in the core allocation routine, and considerably more than that if lifetime-hole
computation is excluded (twldrv.f: 0.49s versus 2.28s). A usage-count allocator, the obvious
cheap alternative, is 1.15x to 11.64x worse than coloring.

# Relevance

This is our documented baseline for stage 12, and the CUJ already states the acceptance test
that will fail it: if any unboxed f64 spills across the loop body, the allocator is erasing the
analysis. Plain linear scan will hit that case, and its spill choice makes it worse. In a
vectorized inner loop the interval that ends furthest away is typically the loop-carried
accumulator or the base pointer of an array, which is exactly the value that must stay in a
register. The Belady argument that justifies the heuristic assumes one definition and one use;
a loop-carried value violates that assumption maximally.

Two things do work in our favour. The two register files (GPR for tagged and untagged integers,
xmm/zmm for unboxed f64) are independent allocation problems, so the algorithm runs once per
file with its own `R`, and the f64 file's pressure is exactly what stage 10 controls. And
compile time genuinely matters for us in the same way it does for a JIT, since a nanopass
compiler with a dozen stages cannot afford a quadratic back end.

The honest position is that this paper is the floor, not the target. `wimmer-franz-linear-scan-register-allocation-on-ssa-form-c` in this same corpus adds interval splitting and lifetime holes on SSA and is what every production "linear scan" actually is, and
`george-appel-iterated-register-coalescing-toplas-1996` is the allocator this paper measures
itself against. Implement this first because it is 40 lines and gives a correct back end
immediately, then measure spills in the nbody inner loop and replace it if the count is nonzero.

# Notes

The paper's headline claim, "within 12%," is qualified in its own abstract as holding for all
but two benchmarks, and Table II shows `wc` at 1.43 and `espresso` at 1.18. Repeat the qualified
version, not the headline.

The algorithm as published here is not the algorithm most people mean by "linear scan." Traub,
Holloway and Smith's second-chance binpacking (PLDI 1998, cited throughout) already had lifetime
holes and split lifetimes when this paper appeared, and Wimmer and Franz later put splitting on
SSA. The version in this paper, with one interval per variable and no holes, is the simplest
member of the family and the one that leaves the most on the table.

Bibliography entry checks out: Poletto and Sarkar, TOPLAS 1999, described as the documented
baseline. Affiliations on the title page are MIT LCS and IBM T. J. Watson. The algorithm first
appeared in synopsis form in the tcc paper, Poletto, Engler and Kaashoek, PLDI 1997.
