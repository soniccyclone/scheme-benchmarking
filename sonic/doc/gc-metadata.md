# GC metadata vocabulary

E1-GCVOCAB. What the collector must be told at each program counter, defined **separately
per target**.

The separation is the whole point of this document, and it comes from a warning in
`compare-operating-systems` `bundle/systems/mezzano/scheduling.md` §8, which names this as
the one machine-specific part that is *not* mechanical and the one that will bite:

> the `extra-registers` field means different things on the two architectures: on x86-64
> `:rax` means rax holds a tagged value, while on arm64 the same encoding means x9 holds an
> interior pointer into x1, so the collector reconstructs the offset, scavenges x1 and
> re-adds it. A third architecture must either widen the two-bit field or accept another
> reinterpretation. Make the metadata vocabulary a per-target definition from the start
> rather than a shared enum with per-target semantics.

We are that third architecture. So there is no shared enum here.

---

## What is shared: the shape, not the vocabulary

Both targets store the same *kind* of thing, per D21:

- **A function-wide frame bitvector.** One bit per stack slot, set if the slot holds a
  tagged value. Computed once, because frame layout does not change within a function.
- **A step function over the program counter.** Entries only where the answer changes; the
  assembler drops any entry identical to its predecessor. Lookup takes the last entry at or
  before the requested offset.
- **No register bitmap at all.** The register partition (`register-partition.md`) makes the
  value class a fixed list the collector scavenges unconditionally.

What differs is the **transient state** each target needs to describe, and that is where the
vocabularies diverge.

---

## x86-64 vocabulary

| field | width | meaning |
|---|---|---|
| `pc-delta` | varint | offset from the previous entry |
| `frame?` | 1 bit | rbp holds a frame pointer, vs. sp-relative |
| `interrupt?` | 1 bit | this is an interrupt frame; the full register file is spilled |
| `restart?` | 1 bit | PC is inside a restart region; rewind rather than scan |
| `scratch-live` | 2 bits | `none` / `rax` / `rax+rcx` / `rax+rcx+rdx`, strictly nesting |
| `incoming-args` | 2 bits + varint | where and how many arguments are live but not yet stored |
| `pushed-values` | signed varint | values pushed beyond the frame, for multiple returns |

`scratch-live` exists because rax, rcx and rdx are in the **raw** class but transiently hold
tagged values during calling-convention sequences. The strict nesting is deliberate: a
multi-load sequence emits one entry per intermediate state, so an interrupt between any two
`mov`s still gets a correct map.

## RV64 vocabulary

| field | width | meaning |
|---|---|---|
| `pc-delta` | varint | offset from the previous entry |
| `frame?` | 1 bit | s0/fp holds a frame pointer, vs. sp-relative |
| `interrupt?` | 1 bit | interrupt frame |
| `restart?` | 1 bit | inside a restart region |
| `ra-live?` | 1 bit | **ra holds a live return address that must be relocated** |
| `scratch-live` | 3 bits | bitmap over t0, t1, t2 |
| `incoming-args` | 3 bits + varint | a0-a7 window that is live but unstored |
| `pushed-values` | signed varint | as x86-64 |
| `vl-live?` | 1 bit | **RVV: vector length configuration is live across this point** |

Three fields have no x86-64 counterpart, and each is a real difference rather than a
renaming.

**`scratch-live` is a bitmap, not a nesting.** RV64 has three scratch registers in the raw
class (t0-t2) that can be written in any order, unlike x86-64's calling convention which
fills rax, then rcx, then rdx. Forcing a nesting here would be inventing a constraint the
ISA does not impose, which is exactly the "accept another reinterpretation" failure the
bundle warns about.

**`ra-live?` is explicit.** On x86-64 the return address is on the stack and covered by the
frame bitvector. On RV64 it lives in a register (`ra`, x1), it is a pointer *into* a
function object, and a moving collector must relocate it. This is the same interior-pointer
problem Mezzano's arm64 port hit with x9 into x1, and giving it its own named bit rather
than overloading `scratch-live` is the whole lesson applied.

**`vl-live?` covers RVV, and this one is new.** Vector registers are raw and unscavenged
like the FPRs, so they need no map. But `vsetvl` establishes machine state — the active
vector length and element width — that is **live across instructions and is not a register
the collector can ignore**. If a preemption lands mid-loop and the restart path does not
restore it, the loop resumes with a different vector length and silently computes the wrong
answer. Since RVA23 makes V mandatory and it is our baseline (not the legacy floor), this
is a first-class field rather than an extension afterthought.

---

## What this constrains downstream

**E1-GCENC encodes two formats, not one parameterised format.** Sharing the varint helpers
is fine; sharing the field layout is the mistake this document exists to prevent.

**E2-META emits against the target's vocabulary**, and the assertion that a value virtual
never reaches a raw register (`register-partition.md`) is what makes the absent register
bitmap sound on both.

**The RVV field is a live question for E5-RVV**, not settled here: whether the restart
region approach extends to a `vsetvl`-established context, or whether vector loops need
their own restart discipline, depends on how E5 structures its loops. Recorded so it is not
discovered late.
