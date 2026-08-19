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
