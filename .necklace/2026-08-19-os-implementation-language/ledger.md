# Ledger — SonicScheme as an OS implementation language

Append-only. Discussion, rejections, findings, judgment calls and who made them.
`spec.md` holds only the design as it currently stands.

## 2026-08-19 — where this came from

Nathan: SonicScheme will be used to write an entire operating system, and the
benchmarking done so far (nbody, fannkuch) is toy algorithm code. Both halves are
the point: the language has to become writable-in, and the measurements have to
resemble the workload.

I had been treating the project as a benchmarking study and closed the bead queue
on that reading. That was wrong about the goal, not about the measurements --
docs/LEDGER.md D1-D206 stands, but it is evidence about two numeric kernels with
no allocation, no strings, no polymorphism and no GC pressure, which is close to
the opposite of a kernel.

## Starting facts, read off the tree before any probe

- Special forms: `and begin cond declare declare-distinct if import lambda let or
  policy quote syntax-rules`. Absent: `call/cc`, `dynamic-wind`,
  `define-record-type`.
- Primitives: `car cdr fx+ fx- fx* fx->fl fl->fx flabs flsqrt` plus vector and
  flvector operations. No integer division, no shifts, no masks, no fixed-width
  integer types, no bytevector accessors.
- Runtime issues Linux syscalls directly (`write`, `exit`), no libc.
- GC is a precise two-generation copying collector, Cheney scan, written in Scheme.
- Targets x86-64 and RV64, both emitting ELF.

These are the starting point for the probes, not conclusions. Reading tells you
what was intended.

## Probe 1 — MMIO: the optimiser folds two reads of one address

`repl/01-mmio-double-read.sps`. Question: does a device-register read written
twice happen twice? Falsifiable: two loads in the listing would prove me wrong.

```
(fx+ (vector-ref reg 0) (vector-ref reg 0))

401574  mov  -0x1(%rbx),%r10     ONE load
401578  mov  %r10,%r13
40157b  add  %r10,%r13           the same register added to itself
```

One load. **Memory-mapped I/O is a wrong-code bug in this compiler today**, and
not a missing primitive -- the read is expressible, it just does not survive. A
`volatile` concept has to reach CSE, `addrfold`, the peephole and the interval
domain, because each of them is separately entitled to remove or move that load.

This is the finding that most changes the shape of the work. Everything else on
the systems list is additive; this one constrains passes that already exist and
are already tested, which is the expensive kind.

Incidental: `display` accepts only `raw-f64`. The output surface is float-only,
so even a debug print of an integer costs a conversion today.

## Probe 2 — a bad probe, and what it cost

First version asked whether `fxquotient` compiles, using `(fxquotient 7 2)`. It
compiled, and that proved nothing: constant folding removes the call before
selection sees it. necklace-spec's rule caught it -- a probe that cannot fail
proves nothing -- and the tell was that `prim-names` does not list `fxquotient`
while the program built anyway.

Corrected version takes both operands from a vector the folder cannot see
through:

```
401574  mov  -0x1(%rbx),%r10
401578  mov  0x7(%rbx),%r13
401582  call 0x40138c            -> %fxquotient
40158a  jo   0x401514            overflow check on the quotient
```

**Integer division IS reachable.** My starting fact was wrong.

## Finding — there are TWO callable surfaces, and one inventory

Asking the compiler (`repl/03-prim-inventory.ss`) gives 33 primitives:

```
car cdr cons eq? fl* fl+ fl- fl->fx fl/ fl< fl<= fl= flabs flsqrt
flvector-length flvector-ref flvector-set! fx* fx+ fx- fx->fl fx< fx<= fx=
fx> fx>= make-flvector make-vector null? pair? vector-length vector-ref
vector-set!
```

`fxquotient` is not among them and works anyway, because runtime routines
(`%fxquotient`, `%fxremainder`, `%fxmodulo`, `%cons`, `%cstr->string`, ...) are
reachable by name as well. So "what can a program call" is the union of two lists
and neither one is authoritative alone. Three separate greps of `prims.ss`
disagreed with each other and with the compiler before I stopped guessing.

Consequence for scoping: any inventory of "what is missing" has to be produced by
compiling programs, not by reading the primitive table.
