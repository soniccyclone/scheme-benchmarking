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

## Standing, 2026-08-28

```
01-uart.sps     wants  bytevector bytevector-length bytevector-u8-ref
                       mmio-u8-ref mmio-u8-set! u64and u64= +
                stops  undefined label [+]

02-pagewalk.sps wants  mmio-u64-ref u64+ u64and u64ior u64shl u64shr u64=
                stops  display refuses a tagged argument

03-ring.sps     wants  (nothing unbound -- define-record-type swallows the file)
                stops  a top-level definition after a top-level expression

04-irq.sps      wants  mmio-u8-ref u64and u64= +
                stops  display refuses a raw-word argument
```

Two of those were not in `cuj.md` and are recorded in `docs/LEDGER.md` D207: there
is no generic `+`, and `display` accepts `raw-f64` alone, so nothing in this
fixture can print its own answer.
