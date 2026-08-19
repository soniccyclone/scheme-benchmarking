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
- **The annotation mechanism already exists.** `prim-table` declares per-primitive named controls that
  ride through every pass and take values from lexically scoped `policy` regions; `fp-contract` proves
  the path end to end. New semantics should extend this rather than introduce a second mechanism.

## Approach

**Fix the miscompile first, as a control rather than a concept.** Add `volatile` to the memory
primitives' control list and teach the passes that may move or delete a load — common-subexpression
elimination, address folding, the peephole, the interval domain — to refuse when it is set. This is
the same shape as `fp-contract` and the check suppressions, so it inherits their spelling, their
scoping and their tests. It is first because it constrains passes that already exist and are already
tested, which is the expensive kind of change, and because every driver written before it is written
against a compiler that silently drops reads.

**Grow the language in the order a kernel needs it, not in R7RS order.** Records, bit manipulation and
fixed-width integers come before continuations, because a page table needs the first three and no
kernel needs `call/cc` to boot. Each addition carries its own differential test against the existing
oracle.

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

## Open questions

| Question | Why it cannot be settled by reading or running |
| --- | --- |
| Full `call/cc` or escape-only continuations? | Full first-class continuations interact with the calling convention, D97/D98 frame reuse and GC metadata, and cost the kernel something at every call. What the OS needs is a design intention, not a fact about the code. |
| Is `volatile` region-scoped, like `policy`, or attached to an object, like C's `volatile T*`? | Region-scoped is far cheaper given the existing control machinery; object-scoped matches how driver code is conventionally written. The choice is about how the OS will be written, which does not exist yet. |
| May the collector run in kernel context at all? | Decides whether the GC needs a bounded worst-case pause or a hard prohibition with allocation-free proofs on those paths. It is a policy about the OS's design, not a measurable property. |
| Does the OS need a numeric tower, or are fixnums and flonums enough? | Bignums cost allocation on arithmetic, which conflicts with allocation-free kernel paths. Whether any kernel code needs them is a question about the OS. |
