# Register partition

E1 deliverable. The contract the register allocator enforces and the collector mirrors.

Per D21, the collector scavenges the **value class unconditionally, consulting no
metadata**. That is what makes PC-total roots affordable, and it is only sound if the
partition is a static invariant the allocator can never violate. A `:value` virtual landing
in a raw register is not a performance bug; it is a root the collector will not find, so it
is silent memory corruption.

Three classes:

- **value** — may hold a tagged Scheme object. Scavenged unconditionally.
- **raw** — may hold an untagged machine word or a double. **Never** scavenged.
- **structural** — stack pointer, frame pointer, nil, current thread, current CPU. Handled
  by name.

Floating-point registers are **raw in their entirety on both targets** and are never
partitioned, because a double can never be a tagged pointer. That is 32 registers on RV64
and 16 on x86-64 that cost nothing under this scheme, and it is why D21's register-pressure
objection nearly vanishes for the numeric code this project measures.

---

## RV64 (RVA23 baseline, `lp64d`)

| register | ABI name | class | role |
|---|---|---|---|
| x0 | zero | structural | hardwired zero |
| x1 | ra | structural | return address; a code pointer, collector handles by name |
| x2 | sp | structural | stack pointer |
| x3 | gp | structural | **nil** |
| x4 | tp | structural | **current thread** (this is what `tp` already means) |
| x5-x7 | t0-t2 | **raw** | 3 |
| x8 | s0/fp | structural | frame pointer |
| x9 | s1 | structural | **current CPU** |
| x10-x17 | a0-a7 | **value** | 8 |
| x18-x23 | s2-s7 | **value** | 6 |
| x24-x27 | s8-s11 | **raw** | 4 |
| x28-x31 | t3-t6 | **raw** | 4 |
| f0-f31 | — | **raw** | 32, never scavenged |

**14 value, 11 raw, 32 float.**

Following the bundle's §8 recommendation, nil, current CPU and current thread get dedicated
registers as arm64 does with x26/x27/x28. RISC-V has no segment registers to abuse, and
`tp` already carries the current-thread meaning in the standard ABI, so this costs nothing
in clarity.

## x86-64 (System V)

| register | class | role |
|---|---|---|
| rsp | structural | stack pointer |
| rbp | structural | frame pointer |
| r15 | structural | **nil** |
| rbx, r8-r14 | **value** | 8 |
| rax, rcx, rdx, rsi, rdi | **raw** | 5 |
| xmm0-15 | **raw** | 16, never scavenged |

**8 value, 5 raw, 16 float.**

Current CPU and current thread live behind the **GS base** rather than burning two GPRs:
`GS:0` is the per-CPU area and holds the current-thread pointer. Mezzano's document calls
using FS/GS "a downgrade in clarity" against arm64's dedicated registers, and it is, but on
a register file this small the clarity is worth less than the two registers. This is why we
get 8 value registers where Mezzano gets 7.

## The comparison, quantified

| | x86-64 | RV64 | RV64 advantage |
|---|---|---|---|
| value | 8 | 14 | +75% |
| raw | 5 | 11 | +120% |
| float | 16 | 32 | +100% |

This is D21's argument with numbers on it. The partition is genuinely tight on x86-64 —
five raw integer registers for address arithmetic, index computation and loop control is
not much — and it is comfortable on RV64. Since RISC-V is the target that matters for
performance (D22), the design's dominant cost lands on the target we care about least.

---

## Things this constrains, and one trap

**The allocator asserts, it does not warn.** A `:value` virtual reaching a raw register must
be a hard compile-time failure, per the silent-corruption argument above.

**Return addresses are not ordinary values.** `ra` on RV64 and the pushed return address on
x86-64 point *into* a function object that a moving collector may relocate. They are
structural and the collector adjusts them by name, the same way Mezzano's arm64 port treats
`x9` as an interior pointer into `x1` and reconstructs the offset. This is exactly the case
the bundle warns is not architecture-neutral, which is why the metadata vocabulary is
per-target (E1-GCVOCAB).

**Argument registers are in the value class on RV64 and that is deliberate.** `a0-a7` carry
Scheme objects at every call, so making them raw would force a shuffle at every boundary.
Foreign calls to C are the exception and shuffle explicitly at the boundary.

### The trap: the distro default `-march` is much richer than real hardware

Measured, not assumed. `riscv64-linux-gnu-gcc` on this box defaults to:

```
rv64imafdcbv_zic64b_zicbom_..._zba_zbb_zbs_zkt_zvbb_zve32f_..._zve64d_...
-mabi=lp64d
```

That is RVA23-class: **RVV 1.0 vectors, Zba, Zbb, Zbs, Zfa, Zicond**, all on by default.
`__riscv_v` is `1000000` and `__riscv_flen` is 64.

It is also far more than a typical devboard has. A JH7110 / U74 board is `rv64gc` with **no
V extension at all**, and much of the current shipping fleet is the same. So developing
against the default `-march` will happily emit RVV that the hardware you eventually buy
cannot execute.

Two consequences:

1. **Pin `-march` explicitly in the smoke gate and in SonicScheme's target description.**
   Never inherit the toolchain default. Baseline is `rv64gc`; anything above it is a named,
   detected feature.
2. **RVV is a feature, not the baseline** (E5-RVV). The vectorizer must have a scalar
   fallback path, and `E2-RVSEL` should target `rv64gc` only.

Two concrete demonstrations, both from this tree:

- `sh3add` appears in the disassembly of a trivial indexing loop. gcc reached for a **Zba**
  instruction unasked, on a default target string, for code as ordinary as `p[k]`.
- `fli.d` appeared in nbody's RISC-V instruction list under the default `-march` and
  **disappears under `rv64gc`**. It is a **Zfa** load-immediate. Nothing warned; the
  instruction set simply got smaller when asked honestly.

`harness/smoke-riscv.sh` now pins `MARCH=rv64gc MABI=lp64d` and never inherits the default.
