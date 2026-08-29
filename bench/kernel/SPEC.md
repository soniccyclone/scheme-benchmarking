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

**2026-08-28, after the variable shifts** (D212):

```
01-uart.sps     wants  bytevector bytevector-length bytevector-u8-ref
02-pagewalk.sps COMPILES
03-ring.sps     wants  (nothing -- define-record-type swallows the file)
04-irq.sps      COMPILES
```

**Two of four compile.** Both are the driver-shaped ones.

`04-irq.sps`: four `mmio-u8-ref` calls become four `movzx`-from-memory in the
image -- including the one in `irq-ack` whose value is discarded, which is what
clears an interrupt and what DCE used to reap. 68 instructions.

`02-pagewalk.sps`: 112 instructions, four variable shifts through BMI2's `shrx`,
and the NX constant materialised exactly as `mov rcx, 0x8000000000000000`.

Neither can be RUN hosted: both read `0x10000000`, a device window on qemu
`virt` and a segfault under Linux. Running them is `4qp.1`.

| still missing | bead |
| --- | --- |
| bytevectors | `0wr.1` |
| `define-record-type`, `raise`, `guard` | `9yp` |

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
