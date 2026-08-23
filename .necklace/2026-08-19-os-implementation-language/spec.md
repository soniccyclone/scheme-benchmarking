# SonicScheme as an operating-system implementation language

No ticket. Constraint stated by Nathan on 2026-08-19: SonicScheme will be used to write an entire
operating system, and the benchmarking to date is toy algorithm code.

## The problem

SonicScheme compiles the two programs in `bench/` very well and is not yet a language anyone can
write a kernel in. Three gaps, each measured rather than assumed.

**It miscompiles memory-mapped I/O.** Two reads of one address fold to a single load
(`repl/01-mmio-double-read.sps`): `(fx+ (vector-ref reg 0) (vector-ref reg 0))` emits one `mov` and
adds the register to itself. A device register read written twice happens once. This reproduced three
times across probes, including with a non-constant index.

**The language is benchmark-shaped.** Asking the compiler for its own inventory gives 33 primitives:
fixnum and flonum arithmetic, comparisons, `car`/`cdr`/`cons`, and vector and flvector access. Special
forms are `and begin cond declare declare-distinct if import lambda let or policy quote syntax-rules`.
`call/cc`, `dynamic-wind` and `define-record-type` are absent. There are no shifts, no masks and no
fixed-width integer types, so a page-table entry or a device descriptor cannot be expressed. `display`
accepts only `raw-f64`, so printing an integer costs a conversion.

**The runtime assumes Linux.** It issues `write` and `exit` syscalls directly, and the collector
assumes memory exists. A kernel provides both rather than consuming them.

What is *not* a problem, and this bounds the work: code quality. A leaf function compiles to
straight-line register arithmetic with no heap traffic and no checks (`repl/04-alloc-free.sps`).
Allocation-free code is already expressible, and nothing below is about making the back end emit
better instructions.

## Actors

- Kernel author — writes the operating system in SonicScheme
- Compiler maintainer — extends SonicScheme without breaking the correctness evidence it already has
- Driver author — writes code that talks to hardware registers and interrupts
- Editor user — reads and edits SonicScheme in Emacs or VSCode

## Actor-outcome pairs

| Actor | Must be able to observe |
| --- | --- |
| Kernel author | A program using records, exceptions and the full binding forms compiles and runs; a kernel path can be shown to allocate nothing |
| Kernel author | An image that boots on bare metal with no OS beneath it, on both x86-64 and RV64 |
| Driver author | A device-register read written N times executes N times, verified in the emitted listing, and unaffected by any optimisation level |
| Driver author | Bit manipulation, fixed-width integer types and byte-addressed memory expressible directly, without going through flonums |
| Driver author | An interrupt handler that saves and restores what the hardware requires and provably cannot allocate |
| Compiler maintainer | The eleven-way bit-exact oracle and both differential gates still pass after every addition |
| Compiler maintainer | Performance measured on workloads that allocate, manipulate strings and stress the collector — not only on two numeric kernels |
| Editor user | SonicScheme's own annotations (`declare`, `policy`, `declare-distinct`) highlighted distinctly from ordinary identifiers, in both editors |

## Constraints

- **The bit-exact oracle is load-bearing and must survive.** D24 records it as the project's strongest
  correctness evidence, and the check-elision passes are unsound-in-the-small precisely where a
  tolerance oracle would hide it. Every addition below is additive to it or is refused.
- **Two targets, always.** x86-64 and RV64 both ship, and D132/D160 record features that silently did
  nothing on RV64 for entries at a time because only one target was exercised.
- **Nothing runs on the host.** Every Chez invocation and every emitted binary runs in the container
  (CLAUDE.md), and that predates a 31 GB OOM incident.
- **A fixnum cannot hold a 64-bit hardware value.** 3 tag bits leave 61 value bits, so a page-table
  entry with the NX bit set does not fit. Fixed-width integer types are required rather than
  preferred, and a numeric tower does not substitute because bignums allocate.
- **Every collector pause is already bounded by the nursery, and there is no major collection.**
  `gc-reserve-ok?` refuses to begin unless old space can absorb the worst case, so a collection never
  half-completes. The cost that is unbounded is old-space growth, not latency.
- **The annotation mechanism already exists.** `prim-table` declares per-primitive named controls that
  ride through every pass and take values from lexically scoped `policy` regions; `fp-contract` proves
  the path end to end. New semantics should extend this rather than introduce a second mechanism.

## Approach

**Fix the miscompile first, as a control rather than a concept.** Add `volatile` to the memory
primitives' control list and teach the passes that may move or delete a load — common-subexpression
elimination, address folding, the peephole, the interval domain — to refuse when it is set. This is
the same shape as `fp-contract` and the check suppressions, so it inherits their spelling and their
tests.

**Attach it to the object, not to a region.** `declare-distinct` is already C99's `restrict` here — a
premise attached to names and scoped to a body — so object-scoped annotation is a mechanism this
compiler has rather than one it needs. A region cannot express the ordinary driver case: copying a
device register into RAM is one expression touching four memory locations, of which exactly one may
be volatile, and the device read cannot be enclosed without its own address computation. Marking the
object leaves the other three optimisable. Unlike `declare-distinct`, a wrong annotation here costs
only speed: volatile removes permission and never grants it, so it cannot miscompile. It is first because it constrains passes that already exist and are already
tested, which is the expensive kind of change, and because every driver written before it is written
against a compiler that silently drops reads.

**Grow the language in the order a kernel needs it, not in R7RS order.** Records, bit manipulation and
fixed-width integers come first, because a page-table entry needs all three and does not fit in a
fixnum at all. Each addition carries its own differential test against the existing oracle.

**Continuations are not a choice between full and escape-only.** `gcmeta` is PC-total — every byte
offset in every function has a stack map — which is precisely what capturing a stack requires, and
stronger than the safepoint tables most implementations settle for. Full capture is therefore
implementable on machinery that exists and costs nothing at call sites; what it costs is an
allocation at capture. Escape continuations allocate nothing and work everywhere, including interrupt
handlers. The allocation-free mark decides which is available where, so this needs no global
decision.

**Separate the freestanding target from the hosted one.** The Linux-syscall runtime keeps working and
keeps being what the benchmarks measure; a second runtime provides what a kernel provides. Both ISAs
gain it together, per the two-target constraint.

**Re-benchmark against the actual workload.** Every performance conclusion in `docs/LEDGER.md` is
drawn from two allocation-free numeric kernels, and the repeated finding that instruction count does
not convert to time (D89, D111, D167) may be a property of those two programs rather than of the
compiler. Workloads that allocate, build strings, and stress the collector are needed before any of
those conclusions transfer, and worst-case GC pause matters more than throughput for a kernel.

**Editor support last and small.** It is genuinely independent of everything above, and it needs only
the annotation vocabulary, which is already stable.
