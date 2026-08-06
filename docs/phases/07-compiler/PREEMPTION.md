# Preemption and root discovery: two designs, costed

A decision that has to land in E1, before the register allocator exists, because both
options constrain the IR and one of them constrains the register file.

The forcing fact is from `compare-operating-systems`, `bundle/axes/scheduling.md`:

> the loop that makes a Scheme match C is a tight numeric loop with no procedure calls, no
> allocation and unboxed values in registers, which is **by construction a loop with no
> safepoint**, and Chez and Racket put their safepoints exactly where Go puts its.

That describes the exact code SonicScheme exists to emit. Our measured 4.77x comes from
making nbody's inner loop that shape. So "fast" and "preemptible" are in tension here in a
way they are not for a general-purpose Scheme, and `sonic/src/sonic/analyze.ss` already has
a `loop` primitive that compiles to a jump rather than a call, which is the precise
construct the axis says kills the guarantee silently.

Two ways out. Both need stack maps; they differ in where.

---

## Option A: metadata total over the program counter

Mezzano's design. No poll instruction anywhere in compiler output, no suspend flag the
mutator reads, no list of allowed stopping points. A thread is stopped by an interrupt
wherever it is, and the collector reads its registers and stack directly. Every byte offset
in every function has a defined answer to "which stack slots and registers hold Lisp values
here."

Three structural pieces make it affordable, and the first is the one that matters:

**1. The register half is not metadata at all.** It is a static partition enforced by the
register allocator. On x86-64 a `:value` virtual may only land in r8, r9, r10, r11, r12,
r13 or rbx; an `:integer` virtual, a raw machine word, only in rax, rcx, rdx, rsi or rdi.
The collector mirrors it exactly and scavenges r8-r15 plus rbx unconditionally from any
stopped thread **without consulting any metadata**. rsi and rdi are never scavenged. Only
rax, rcx and rdx need a two-bit escape hatch for the windows where they transiently hold a
value.

**2. The stack half is one function-wide bitvector**, one bit per slot, computed once. Slots
are tagged `:value` or `:raw` at allocation and the allocator asserts if called after the
layout is frozen. Frame layout does not change within a function, so it is paid for once.

**3. Per-point entries carry only transient calling-convention state**, and the assembler
drops any entry identical to its predecessor. What is stored is a **step function**; what is
queried is any point on it. The compiler emits an entry before every backend instruction,
but the table retains one only where the answer changes.

## Option B: polls, strip-mined, omitted where provably short

The conventional design plus two refinements our analysis already supports.

Poll in the function prologue, as BEAM, Go and Gambit all independently converged on. That
is sound for a Scheme only while iteration is tail recursion. The moment a `do` loop or
named `let` compiles to a jump, add:

**Strip-mining.** Emit the poll in an outer loop that runs every `k` iterations, so the
inner loop stays clean. Cost is one decrement-and-branch per `k` iterations, and critically
the *inner* loop keeps no branch, so vectorization and scheduling are unaffected.

**Trip-count omission.** Where `sonic/src/sonic/analyze.ss` proves the trip count and the
body is leaf, worst-case execution is statically bounded and the poll can be dropped
entirely. This is free: it is the same interval fact that deletes the bounds check.

Note the sharp limit, because I overstated this when I first raised it. **Proving a trip
count does not bound latency.** Proving `i in [0, 50000000)` proves the loop is finite, not
that it is short. Omission is legal only when `trip_count × body_cost` is inside the latency
budget, which for nbody's inner loops (5 and 7 iterations) it is and for the driver loop
(50M) it is not. The driver loop gets strip-mined instead.

---

## Space

Let `c` be calling-convention transition points in a function, `s` stack slots, `n`
instructions, `d` stack depth at collection.

| | option A | option B |
|---|---|---|
| register map | **none**, static partition | none, live regs spilled at safepoints |
| frame map | one bitvector, `s` bits, per function | `s` bits per safepoint |
| point entries | `O(c)`, ~5 + s/8 bytes each | `O(c + loops)`, ~s/8 bytes each |
| **total** | **`O(c · s/8)`** | **`O(c · s/8)`** |

**These are the same order, and that is the counterintuitive result.** "Total over the
program counter" sounds like one entry per instruction and is not: the assembler dedupes to
a step function whose breakpoints are calling-convention transitions, which is the same
population conventional stack maps use. The static register partition then deletes the
register half outright, which conventional safepoint maps must carry.

The real difference is a constant factor of roughly **2-3x**, coming from A emitting extra
entries *inside* instruction expansions. Mezzano's `cmpxchg16b` is the illustration: three
metadata updates, one after each of the three loads, declaring `:rax`, then `:rax-rcx`, then
`:rax-rcx-rdx`, so an interrupt between any two `mov`s still gets a correct map.

**For our hot code the difference collapses to nothing.** A tight numeric loop with
everything in registers, no calls and no allocation has no calling-convention transitions,
so A stores approximately one entry for the whole loop. The metadata cost of option A is
proportional to how call-heavy the code is, and the code this project optimizes is the least
call-heavy code there is.

## Time

| | option A | option B |
|---|---|---|
| mutator, per function | **0 instructions** | ~3-4, prologue poll |
| mutator, per hot loop iteration | **0** | `4/k` amortized, ~0.008% at k=1024, b=50 |
| mutator, inner-loop branch | **none** | none if strip-mined; one if not |
| collector, per frame | `O(c)` linear scan | `O(log c)` binary search |
| collector, per collection | `O(c · d)` | `O(log c · d)` |
| preemption latency | **any instruction** | `k × body`, tunable |

Two things to be honest about.

**A's collector lookup is a linear scan.** `gc-info-for-function-offset` walks entries in
order and stops at the first offset exceeding the request. That is `O(c)` per frame against
`O(log c)` for a sorted safepoint table. It is also trivially fixable by binary search over
the same encoding, and it is dwarfed by the scan of the frame itself, so this is a
constant-factor note rather than a real cost.

**B's poll is cheap only if strip-mined.** An unstripped poll in the inner loop is a branch
in the hottest code in the program, and per Coz's distinction between speedup and
enablement, its cost is not the three instructions but the code motion and vectorization it
inhibits. Strip-mining fixes that by construction, and strip-mining needs loop structure,
which is stage 07, which we need anyway for the vectorizer's unroll factor.

## Register pressure, and why your Q1 answer decides this

This is A's real cost and it is entirely target-dependent.

| target | GPRs | A's partition | binding? |
|---|---|---|---|
| x86-64 | 15 usable | 7 value / 5 raw / 3 dedicated | **yes**, painfully |
| RISC-V | 31 usable | ~15 value / ~12 raw / 4 dedicated | no |

On x86-64, five raw integer registers for address arithmetic and loop control is tight, and
spills in the inner loop are exactly what we are trying to avoid. That is the strongest
argument against A, and it is the reason a naive reading rejects it.

**On RISC-V the argument evaporates.** The bundle's §8 says it directly: "RISC-V has 31
general registers against x86-64's 15, so a generous value class still leaves plenty for raw
arithmetic and addressing."

And there is a second effect it does not mention, which matters more for us specifically:
**floating-point registers need no partition at all.** A double is a raw value; an `f`
register can never hold a tagged pointer. RISC-V has 32 FPRs, x86-64 has 16 xmm/32 zmm, and
all of them sit outside the partition entirely. nbody is pure double-float. **For the exact
workload this project measures, option A's register cost is approximately zero.**

## Effort

| | option A | option B |
|---|---|---|
| register allocator | partition constraint, moderate | unconstrained |
| codegen | metadata emission at every backend instruction, **pervasive** | poll insertion, small |
| loop handling | none required | strip-mining, moderate, needs stage 07 |
| encoder/decoder | small, varint + bitvector | small |
| allocator | restart regions, small but subtle | safepoint at allocation, small |
| analysis reuse | none | trip-count omission is **free**, already built |
| **retrofit cost if deferred** | **an audit of the whole system** | low |

A is more work and, more importantly, **pervasive** work: every backend instruction has to be
metadata-aware. That is exactly why it cannot be deferred. Emacs is the cost of trying:
1842 primitives to audit, and it never happened.

B is less work and reuses the interval domain we already have. Its cost is that correctness
depends on the compiler having decorated every loop, and the bundle's central scheduling
finding is that this is the shared failure mode of four independent systems: BEAM, Go,
Inferno and Emacs all converged on the same placement and the ones that lost the language
property lost the guarantee silently.

---

## Recommendation: A, with B's analysis kept for its original purpose

Given RISC-V as a first-class target, **build option A.**

1. **Its dominant cost is register pressure, and RISC-V does not have that problem.** 31
   GPRs plus 32 unpartitioned FPRs, against x86-64's 15. The decision that looks marginal on
   x86-64 is clearly right on the target you actually want.
2. **Its metadata cost is proportional to call density**, and this project's entire output
   is the least call-dense code that exists. For nbody's inner loop the step function has
   roughly one entry.
3. **Zero mutator cost is the only answer that does not tax the thing being measured.**
   Every poll in a hot loop is a tax on our headline number, and every poll omitted from one
   is a latency hole. A has no such tension because there is nothing to place.
4. **For an OS it is the only defensible choice.** Under B a thread that reaches an
   undecorated loop wedges a core, and CIVICS runs mutually distrusting components. Under A
   the thread does not participate in its own preemption at all.
5. **It cannot be retrofitted.** B can be strengthened later; A cannot be added later.

Keep the trip-count analysis. It just is not a preemption mechanism. It stays what it was
built for: deleting bounds checks, and supplying stage 10 the trip count it needs, since a
vectorizer that guesses one goes from 22.56% vectorizable at 256 bits to 0.01% at 1024.

Three notes to carry into E1, all from §8 of the Mezzano scheduling document.

**Make the metadata vocabulary a per-target definition from the start.** Not a shared enum
with per-target semantics. Mezzano's `extra-registers` field means "rax holds a tagged
value" on x86-64 and "x9 holds an interior pointer into x1" on arm64, and a third
architecture must either widen the field or accept another reinterpretation.

**Dedicate registers for nil, current CPU and current thread.** arm64 uses x26, x27, x28.
x86-64 puts nil in r14 and the other two in FS/GS segment bases, which the document calls a
downgrade in clarity. RISC-V has no segment registers and must do what arm64 does, "and that
is the better answer anyway."

**Restart regions, not a poll, for the allocator's claim-then-fill window.** It costs
nothing on the fast path and nothing in the common case where no collection happens.
