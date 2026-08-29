# The kernel fixture

Four programs that a kernel author would write and this compiler cannot yet
accept. They exist so that "what does an OS need from the language" is answered
by a compile error rather than by an opinion.

`./compile-all.sh` compiles each and prints every name it wants. It re-execs into
the container like everything else.

| program | what it exercises |
| --- | --- |
| `01-uart.sps` | a 16550 on qemu `virt`: MMIO byte access at a literal address, a polling loop on a status bit, bytes out of a bytevector |
| `02-pagewalk.sps` | Sv39 translation and a leaf PTE, including x86-64's NX at bit 63 -- the constant probe 9 measured a 61-bit fixnum cannot hold |
| `03-ring.sps` | an SPSC ring between a handler and a thread: a record with named mutable fields, byte storage, and `raise`/`guard` for "the ring was empty" |
| `04-irq.sps` | the two shapes optimisation gets wrong -- a read whose value is discarded (probe 5: DCE reaps it) and two reads of one address (probe 7: CSE folds them) |

## Standing

Re-run `./compile-all.sh` after any language change and replace this block.

**2026-08-28, after bytevectors** (D213):

```
01-uart.sps     COMPILES
02-pagewalk.sps COMPILES
03-ring.sps     wants  (nothing -- define-record-type swallows the file)
04-irq.sps      COMPILES
```

**Three of four.** What each one proves, read off the emitted image rather than
off the source:

| program | evidence |
| --- | --- |
| `01-uart` | a polling loop on a status bit, and a message walked byte by byte out of a bytevector |
| `02-pagewalk` | 112 instructions, four variable shifts through `shrx`, NX materialised as `mov rcx, 0x8000000000000000` |
| `04-irq` | 68 instructions, and four source device reads are four `movzx`-from-memory -- including the discarded one that clears the interrupt |

`03-ring` is the last, and it needs `define-record-type`, `raise` and `guard`
(bead `9yp`).

None of the three can be RUN hosted: all read `0x10000000`, a device window on
qemu `virt` and a segfault under Linux. Running them is `4qp.1`.

`01-uart` spells its message out one `bytevector-u8-set!` at a time. R7RS writes
that `#u8(72 101 ...)`, which this compiler does not read, and `(bytevector 72
101 ...)`, which is variadic and `prim-table` fixes every arity on purpose. Bead
`f0z`.

### Earlier runs, so the movement is visible

```
2026-08-28, first run, before anything landed:
01-uart      bytevector bytevector-length bytevector-u8-ref mmio-u8-ref mmio-u8-set! u64and u64= +
02-pagewalk  mmio-u64-ref u64+ u64and u64ior u64shl u64shr u64=
03-ring      (nothing)
04-irq       mmio-u8-ref u64and u64= +

after mmio-u8 and mmio-u64:
01-uart      bytevector bytevector-length bytevector-u8-ref u64and u64= +
02-pagewalk  u64+ u64and u64ior u64shl u64shr u64=
04-irq       u64and u64= +
```
