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

## Probe 4 — allocation-free code is already expressible

`repl/04-alloc-free.sps`. Falsifiable: any allocator call inside the leaf.

```
401574  mov  0xf(%rbx),%r10
401578  imul $0x3,%r10,%r13
40157c  lea  -0x1(%r10),%rcx
401583  add  %rcx,%r10
```

No heap traffic, no checks, no calls. The only two calls in the program are the
top-level `make-vector` and `display`. **The back end already emits what a kernel
path needs**, which is the most load-bearing good news in this round: the gap to
an OS language is not code quality, and none of the work below is about making
the compiler emit better instructions.

Third occurrence of the CSE fold, incidentally -- `(vector-ref v i)` twice, one
load -- so probe 1 was not a special case of a constant index.

## Finding — `volatile` is a control, not a concept

`lang.ss`'s `prim-table` declares each primitive with its arity and its named
controls:

```
(fxquotient 2 div-check overflow-check)
(fl+ 2 fp-contract)
(flvector-ref 2 type-check bounds-check)
```

A control is a name that rides on the instruction through every pass and takes a
value from a lexically scoped `(policy ([name boolean]) ...)` region or a per-call
spelling. `fp-contract` proves the path works end to end (D24), and the checks
prove passes act on it.

So MMIO does not need a new mechanism. It needs a `volatile` control on the memory
primitives plus the passes that currently move or remove loads -- CSE, addrfold,
the peephole, the interval domain -- taught to refuse when it is set. That is a
much better position than "add a volatile type", and it is why the spec treats
the systems work as extending an existing vocabulary rather than inventing one.

## Judgment calls I did NOT make

- Whether `call/cc` is full or escape-only. Full first-class continuations
  interact with the calling convention, D97/D98 frame reuse, and GC metadata, and
  a kernel may not want them at any price. Neither reading nor running settles
  what the OS needs. **For Nathan.**
- Whether volatile is region-scoped (`policy`) or attached to an object, the way
  C's `volatile T*` is. Region-scoped is far cheaper given the machinery above;
  object-scoped matches how driver code is usually written. **For Nathan.**
- Whether the GC is permitted to run in kernel context at all, which decides
  whether the collector needs a pause bound or simply a prohibition.

## Probes 5-7 — which pass folds the volatile read, and one wrong answer on the way

The CUJ needs to name the passes that must honour `volatile`, so "CSE probably"
is not good enough.

**Probe 5** counted loads at each stage: 4 at `lmach/pre-cse`, 4 after addrfold,
2 after DCE. Read alone that says DCE folds them, which is wrong.

**Probe 6** ran `cse-program` on the captured pre-CSE program and printed the
block before and after. It reported the `add` already reading one value BEFORE
CSE, so I concluded the fold was upstream of Lmach entirely.

**That was an instrument error.** `cse-program` mutates its input, and I printed
both snapshots after calling it -- so "BEFORE" was showing the post-CSE state.
Same species as D126 in docs/LEDGER.md, and the same lesson: a snapshot taken
after the transform is not a snapshot of the input.

**Probe 7** avoids it by observing the live pipeline at each stage rather than
re-running a pass:

```
lmach/pre-cse   add ... t.5 t.7     two distinct values
lmach           add ... t.5 t.5     one value
lmach/dce       (the dead load is gone)
```

So the sequence is: **CSE rewrites the second use to the first value; DCE then
reaps the load nobody reads.** Both have to honour volatile, and for different
reasons -- CSE must not rewrite the use, and DCE must not delete a volatile load
even when its result is unused, because a read whose value is discarded is how
you clear an interrupt on real hardware.

`addrfold` and the peephole did not participate here, but both move or rewrite
memory operands and neither was exercised by this one shape. The CUJ names all
four and expects the tests to tell us which actually needed it.

## Probe 8 — the volatile scoping question, answered rather than asked

Nathan, on the spec's open questions: this one sounds answerable by more probing,
and it was. He is right on both counts -- I listed it in a closing paragraph
instead of asking, and necklace-spec's own rule says a question naming an existing
mechanism is factual and gets resolved rather than handed over. `policy` and
`declare-distinct` are both mechanisms in this tree.

**What I had missed: object-scoped annotation already exists here.**
`(declare-distinct (a b) body)` is C99's `restrict` -- a premise attached to
NAMES, scoped to a body, flowing to the alias analysis. So the choice was never
"invent one or the other". Both shapes are already built.

**The deciding shape** is a driver copying from a device register into RAM, which
is one expression touching two objects with different volatility
(`repl/08-mixed-access.sps`):

```
(vector-set! buf i (vector-ref dev 0))

4015c7  mov 0x600048,%rbx              dev's global cell
4015cf  mov -0x1(%rbx),%rdx            the device read      MUST be volatile
4015d3  mov 0x600040,%rbx              buf's global cell
4015db  mov %rdx,-0x1(%rbx,%rcx,8)     the RAM write        must NOT be
```

Four memory accesses from one source expression. A region-scoped `volatile`
marks all four: it would make the two compiler-internal global-cell loads
volatile, which is exactly the global hoisting D93 measured as worth having, and
the RAM store as well.

**And no smaller region helps.** The device read cannot be enclosed without its
own address computation, because they are the same expression. So region-scoping
does not merely cost performance -- it CANNOT express the case, which is a
different and stronger objection.

**Answer: object-scoped, on `declare-distinct`'s template.** Mark the object;
accesses through it are volatile and nothing else is. It reuses a mechanism that
exists, is already understood as a programmer-supplied premise, and already
reaches the analysis that decides what may move.

One difference from `declare-distinct` worth carrying into the design: that one is
a premise the compiler cannot check and violating it miscompiles silently.
Volatile is the opposite -- it only ever REMOVES permission, so a wrong volatile
annotation costs speed and cannot cost correctness. That asymmetry means it does
not need the same care in its scoping rules.

The open question is struck from spec.md and CUJ-02 is unblocked.

## Probes 9-11 — the remaining three questions, answered by probing

Nathan: don't ask, probe -- that is what the skill says. It does, and I had left
three questions in the document that reading and running settle.

### Probe 9 — a fixnum cannot hold a 64-bit hardware value

`repl/09-fixnum-width.ss`. 3 tag bits, 61 value bits, 64 word bits.

```
range: -1152921504606846976 .. 1152921504606846975
PTE 0xFFFFFFFFFFFFF003 fits?           #f
48-bit phys addr 0xFFFFFFFFF000 fits?  #t
32-bit MMIO word 0xFFFFFFFF fits?      #t
```

A 64-bit page-table entry does not fit: the NX bit is bit 63. **This settles the
numeric-tower question by making it the wrong question.** A tower would represent
the value, but bignums allocate, and probe 4 plus CUJ-05 make allocation-free
paths the requirement for kernel code. Fixed-width `u64` is required and the tower
is separate, optional, and non-blocking.

### Probe 10 — the collector's pause is already bounded, and by a tunable

Read off `gc.ss`'s own reservation logic rather than guessed:

- `gc-worst-case` is the whole mutator-usable nursery -- a minor collection copies
  at most that.
- `gc-reserve-ok?` refuses to START unless old space can absorb the worst case, so
  "there is no state in which it has half-copied the heap and run out."
- Cheney needs no auxiliary storage; the to-space is the work queue.
- There is no major collection. No `collect-old`, no full collection, nothing in
  the exports. Old space grows monotonically and exhaustion surfaces as a
  catchable condition.

**So the collector may run in kernel context, and its pause is a number you
choose** -- size the nursery to the interrupt-latency budget. The real cost is not
latency at all: it is that old space is never reclaimed, so long-lived kernel code
either avoids promotion or accepts monotonic growth. That is a much more useful
thing to have found than the question I was going to ask.

### Probe 11 — full call/cc costs nothing at call sites, and my spec said otherwise

`gcmeta.ss` is **PC-total**: "every byte offset in every function has a defined
answer to 'which stack slots hold tagged values here'", a step function rather
than a safepoint table, at O(calling-convention transitions) in space.

That is exactly what capturing a stack precisely needs, and it is stronger than
what most implementations have -- capture is possible at ANY PC, not only at
safepoints. So:

- Full `call/cc` is implementable on machinery that already exists.
- It costs **nothing at call sites**. My spec.md claim that it "costs the kernel
  something at every call" was wrong; capture is O(depth) at capture time.
- Capture allocates, being a copy of the stack, so it is unavailable exactly where
  CUJ-05's allocation-free mark applies.

**So it was never a choice between full and escape-only.** Escape continuations
need no allocation and work everywhere including interrupt handlers; full capture
works wherever allocation is allowed. The allocation-free mark already decides
which is available where, so the OS does not choose globally and nobody has to
decide this in advance.

### What is left for Nathan

Nothing in spec.md. Every open question is struck.
