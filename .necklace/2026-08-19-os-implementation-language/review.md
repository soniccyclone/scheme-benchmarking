# Review: how to reach an OS-capable SonicScheme faster

Fable 5, 2026-08-28, at Nathan's request. Read `spec.md`, `cuj.md`, the necklace
`ledger.md`, `docs/LEDGER.md` D147-D206, and the sources named below. Evidence for each
claim is a file:line. Nothing here is implemented; it is the plan for the next agent.

## The diagnosis

206 ledger entries and 588 commits, and the language has 33 primitives, no strings, no
records, no bit operations. About 150 of those entries chase single-digit percentages on
two numeric kernels. The back end is excellent; the front end is a benchmark harness. The
fastest route to an OS is to stop touching the back end and widen the front. Everything
below follows from that.

## 1. Fold CUJ-01 and CUJ-02 into CUJ-03. Volatile is a primitive family, not an annotation.

Probe 8's motivating case is `(vector-set! buf i (vector-ref dev 0))` with `dev` a Scheme
vector. A device register is a raw physical address with a fixed width, not a GC'd object
with a length header. Once CUJ-03 gives raw-address accessors, volatile needs no carrier:

| pass | what exists | change |
| --- | --- | --- |
| DCE | `pure-ops` allowlist, `sonic/src/sonic/dce.ss:78`; unlisted ops are kept | do not list `mmio-load` |
| CSE | `clobber-ops '(store store-at call)`, `sonic/src/sonic/cse.ss:229` | add `mmio-load mmio-store` |
| addrfold, peephole | match by op name | new names match nothing |
| selectors | one rule per op per target | `mmio-*` encodes as the plain load/store |

That is two list entries and four selector rules. It is what every shipped kernel does:
Linux `readl`/`writel` (`volatile-considered-harmful.rst`, 2006), Rust `ptr::read_volatile`.
2xc's five-place refusal was the codebase rejecting the shape, not the slot.

Spelling: R6RS bytevector names, nothing invented. `bytevector-u8-ref`,
`bytevector-u32-native-ref`, `bytevector-u64-native-set!` and friends for RAM;
`mmio-u8-ref` .. `mmio-u64-set!` for hardware. A headerless bytevector at a fixed address
covers the device window and the page-table region alike.

Bead action: close 2xc and 4f0 into 0wr with this note.

## 2. Model `u64` on `raw-f64`. The path is already proven.

`sonic/src/sonic/repr.ss:18` defines `raw-word`, an untagged never-scavenged machine word
in the value file. Flonums already prove unboxed values with boxing on escape to a tagged
slot. `u64` is the same shape in the other register file:

- storage class `raw-word`, wraparound arithmetic, no overflow-check
- `u64+ u64- u64* u64and u64ior u64xor u64not u64shl u64shr u64sar`, plus `fx->u64`,
  `u64->fx` (the latter overflow-checked: 61 value bits, probe 9)
- `sonic/src/sonic/lower.ss:48` maps `fx+ -> add` by table; the bit ops are the same row
  shape with new mach-ops `and or xor shl shr sar`
- both encoders already verify against gas and binutils, so each op is one encoding test
  per target

The per-primitive cost is about eight files (grep `fxquotient`), mechanical. Ten prims,
two targets, one sitting.

Bead action: split 0wr into (a) bytevectors + mmio, (b) `u64` + bit ops. (a) first; (b)
needs (a) for its stores to have somewhere to go.

## 3. Write the kernel fixture before the next feature. New CUJ-00.

Nothing in the tree is a kernel. `bench/kernel/` with roughly 150 lines: a UART driver
(RV64 virt: byte store to `#x10000000`), a Sv39 page-table walker, a ring buffer, an
interrupt-flag clear. It will not compile. Its first error is the top of the queue. This
replaces every "what does a kernel need" judgment with a compile error, and it becomes
CUJ-09's benchmark, which today asks for a string workload in a language with no strings.

## 4. RV64 bare metal first, alone. Break the two-targets-together rule for CUJ-07 only.

- The heap is already `.bss` (`sonic/src/sonic/runtime.ss:85`, `elfexec.ss:13`), so the
  collector needs no OS-provided memory today.
- Freestanding is the eight `syscall`/`ecall` sites in `runtime.ss` (lines 247-860, 941,
  1102, 1196) behind a hook, plus a `_start` that sets `sp` and jumps to the entry.
- qemu `virt`: `-bios none -kernel image -nographic`, entry `#x80000000`, UART at
  `#x10000000`, no mode switch. One day.
- x86 needs multiboot2, GDT, long-mode entry and paging before your first instruction.
  Weeks. Port after RV64 boots.

Confirmed in the container: `/usr/bin/qemu-system-x86_64` and `/usr/bin/qemu-riscv64`
present, `qemu-system-riscv64` absent. `Dockerfile:159` installs `qemu-system-x86`; add
`qemu-system-misc` for riscv64. The two-targets rule exists to stop silent RV64 rot; it
does not need to sequence a bring-up.

Bead action: split 4qp into RV64 (first) and x86 (blocked on RV64).

## 5. Records and exceptions cost nearly nothing. Prelude, not compiler.

- `define-record-type` as a `syntax-rules` macro over `make-vector`/`vector-ref` with a
  descriptor in slot 0. The expander has `syntax-rules` (`expand.ss:220`), constant-index
  checks already elide. One hour. Raw fields arrive with item 2.
- Exceptions escape-only: a handler stack in the runtime, `guard`/`raise`, `with-exception-
  handler`. Probe 11 is right that full `call/cc` is cheap at call sites; a kernel still
  does not need it. Defer until something asks.

## 6. Reordered queue

| now | proposed |
| --- | --- |
| 2xc, 4f0 | close into 0wr (item 1) |
| 0wr | split (a) bytevectors + mmio, (b) `u64` + bit ops |
| 4qp | split RV64 first, x86 blocked on it; add `qemu-system-misc` |
| nw4 | the benchmark is the kernel fixture; drop the string workload until strings exist |
| iw8 | one hour, off the critical path, any time |
| new CUJ-00 | the kernel fixture, first |

Order: fixture -> bytevectors + mmio -> u64 + bits -> records macro -> RV64 boot ->
allocation-free mark (5em) -> interrupts (w7q) -> x86 boot -> exceptions -> editors.

## 7. Process

Ledger entries per feature, not per probe, for this phase. The D-entries earned their cost
when the question was "why is fannkuch 6% slower"; for "add `bytevector-u8-ref`" they are
overhead. Keep the differential test and the bit-exact oracle as the gate. Stop
re-measuring nbody and fannkuch until the kernel fixture runs.
