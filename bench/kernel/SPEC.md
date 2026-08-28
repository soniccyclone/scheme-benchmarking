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

**2026-08-28, after `mmio-u8` and `mmio-u64` landed** (D207, D208):

```
01-uart.sps     wants  bytevector bytevector-length bytevector-u8-ref u64and u64= +
                stops  undefined label [+]

02-pagewalk.sps wants  u64+ u64and u64ior u64shl u64shr u64=
                stops  display refuses a tagged argument

03-ring.sps     wants  (nothing unbound -- define-record-type swallows the file)
                stops  a top-level definition after a top-level expression

04-irq.sps      wants  u64and u64= +
                stops  display refuses a raw-word argument
```

Every `mmio-*` name is gone from every list. What is left is three groups: the
`u64` arithmetic and comparison (bead `0wr.2`), bytevectors (`0wr.1`), and
`define-record-type` (`9yp`) -- plus the two gaps D207 found that were in no
bead: `display` accepts `raw-f64` alone (`0rb`) and there is no generic `+`.

**2026-08-28, first run, before anything landed:**

```
01-uart.sps     wants  bytevector bytevector-length bytevector-u8-ref
                       mmio-u8-ref mmio-u8-set! u64and u64= +
02-pagewalk.sps wants  mmio-u64-ref u64+ u64and u64ior u64shl u64shr u64=
03-ring.sps     wants  (nothing)
04-irq.sps      wants  mmio-u8-ref u64and u64= +
```
