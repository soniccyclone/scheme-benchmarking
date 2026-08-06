# SonicScheme execution plan

How the compiler gets built, structured so that decomposition into a `bd` bead graph is
mechanical rather than a design exercise.

**This is not a re-specification.** `CUJ.md` in this directory is the technical spec: stage
list, core language, milestone checkpoints, verification strategy, the numbers from the
literature. `PLAN.md` is the argument for why the compiler exists. This document is the
third thing, the one neither of those contains: **the dependency structure of the work, and
the reasoning about what can proceed in parallel.**

Read `CUJ.md` first if you want to know *what* stage 10 does. Read this if you want to know
*when it can start and who is blocked on it.*

---

## 1. The move that makes this tractable

A compiler pipeline reads as a chain. Thirteen stages, each consuming the previous stage's
output. Decomposed naively that is a critical path of depth 13 with width 1, which is the
worst possible shape for parallel execution and the reason "write a compiler" sounds like a
year of serial work.

It is not actually that shape, and the thing that changes it is **freezing the
intermediate representations before writing any pass that operates on them.**

Once the IR between stage *n* and stage *n+1* is a fixed, documented, constructible data
type, stage *n+1* no longer depends on stage *n* being finished. It depends only on the
contract. Its author writes synthetic IR fixtures by hand, tests against those, and the two
stages meet when both are done. This is precisely why nanopass-style compilers are built as
they are, and `CUJ.md` already assumes it in its verification section: "Every stage gets
tested in isolation on core-language fixtures."

So the DAG is:

```
  substrate ──► IR CONTRACTS ──┬──► pass ──┐
                               ├──► pass ──┤
                               ├──► pass ──┼──► integration ──► milestone
                               ├──► pass ──┤
                               └──► pass ──┘
```

Depth 4, width bounded by the number of passes. **The IR contract bead is the single
highest-leverage item in the entire project**, and it is the one place where getting it
wrong is expensive, because every downstream bead has to be revised.

We have already proved this works here. `sonic/src/sonic/interval.ss` and `analyze.ss` were
built and tested standalone against hand-written fixtures, with no reader, no expander and
no back end in existence. 6101 domain checks and 11 analysis cases pass against a compiler
that cannot yet compile anything. That is the pattern, validated on the highest-risk
component, before committing to it.

## 2. What is already done

| component | state | where |
|---|---|---|
| interval domain (stage 05/06 core) | working, 6101 checks | `sonic/src/sonic/interval.ss` |
| fixpoint analysis + elision decision | working prototype, 11 cases | `sonic/src/sonic/analyze.ss` |
| core language sketch | s-expression form, A-normalized | `analyze.ss` header |

Two consequences for planning. The riskiest analysis component is de-risked, so it should
*not* be treated as an unknown in scheduling. And the core language already exists in
prototype, so the IR contract bead is a formalization job rather than a from-scratch design.

## 3. Bead boundary rules

What makes one bead here, so that the breakdown does not require judgement calls per item.

**A bead is one pass, one runtime component, or one IR contract.** Not one function, not one
milestone. A pass is the right grain because it has a natural interface (IR in, IR out), a
natural test (fixtures at that interface), and a natural definition of done.

**Every bead states its acceptance in terms of a test that exists when it is closed.**
`bd create --acceptance` takes this. For passes: named fixtures produce named output. For
the back end: a disassembly assertion. For the runtime: a C unit test. No bead closes on
"looks right."

**A bead that cannot be tested without another incomplete bead is drawn wrong.** That is the
signal to split out an IR contract or a fixture-generator bead. This rule is what keeps the
DAG wide.

**Anything with a number from the literature attached carries that number in its bead.**
`CUJ.md` has several that change what "done" means, and they are easy to lose in a
breakdown:

- Milestone 2 is a **gate, not a result**. ABCD removed 45% of bounds checks for ~10%
  speedup because Jalapeño had no global code motion to consume the freedom. A bead that
  closes on "checks removed" and stops has misread the point; the consumer is stage 10.
- **nbody is the one benchmark where `cp0` inlining does not help** (0.92-1.05, Waddell and
  Dybvig). An inlining bead showing nothing on nbody is the expected result, not a bug.
- **Stage 07 gates stage 10's unroll factor**, not just check hoisting. Larsen's `applu`
  goes from 22.56% vectorizable at 256 bits to 0.01% at 1024 when a vectorizer guesses a
  trip count.

## 4. Epic structure and the dependency spine

Seven epics. The edges between them are the real content of this section; the work items
inside each are listed at the grain a bead should take, without being enumerated as a task
breakdown.

### E1. Substrate and machine model contracts — *blocks everything*

The critical epic, and materially larger than a first pass suggests. `PREEMPTION.md` (D21)
puts four cross-target decisions here that cannot be deferred, because all four constrain
the register allocator and one of them constrains every backend instruction.

- Substrate: nanopass or hand-rolled, `boot.ss`, the identity-pass smoke test.
- The core language, formalized from `sonic/src/sonic/analyze.ss`, plus every inter-stage
  IR contract.
- **The register partition.** Value, raw and dedicated classes, defined for **both** targets.
  Dedicated registers for nil, current CPU and current thread, as arm64 does; RISC-V has no
  segment registers to abuse and that is the better answer anyway.
- **The GC metadata vocabulary, per target from the start.** Not a shared enum with
  per-target semantics. Mezzano's `extra-registers` means "rax holds a tagged value" on
  x86-64 and "x9 holds an interior pointer into x1" on arm64, and a third architecture must
  widen the field or accept another reinterpretation.
- **The PC-total metadata encoding.** Varint step function, function-wide frame bitvector,
  dedupe rule.
- **The redefinition cell.** A pointer store into a data slot, never a patched branch,
  because `FENCE.I` is optional (Zifencei) and local-hart only, so cross-hart instruction
  visibility needs a data fence plus an IPI to every remote hart. The seal bit lives in that
  same cell, and sealed means the compiler may inline through it.
- The fixture vocabulary: constructors and printers per IR, so downstream beads write test
  inputs without importing an upstream pass.

**Define the machine model against both ISAs here even though only one gets implemented
first.** That is what makes RISC-V first-class rather than a port: the abstraction is
designed against two instruction sets, so the second target is mechanical rather than a
retrofit. Designing against one and generalizing later is how you get an x86-shaped
abstraction with a RISC-V adapter bolted on.

**Blocks: E2, E3, E4, E5, E7.** Size it small per item, review it hard, and expect it to be
the slowest epic per line of code produced.

### E2. Back end — *the serial spine, and it comes first*

Split by D22 into machine-independent work and per-target work.

**E2-core**: the lowered machine-independent IR, the instruction selection framework, the
register allocator enforcing E1's partition, metadata emission threaded through codegen,
object emission. This is where the coupling lives and it does not parallelize; treat it as a
short chain, not a swarm.

**E2-x86 / E2-rv64**: selection and encoding per target. These *do* parallelize against each
other once E2-core exists, and each is scoped to the instruction subset the benchmarks need
rather than the full ISA. nbody wants seven float opcodes plus integer address arithmetic.

`CUJ.md`'s ordering note holds and is the reason this epic precedes all analysis: a compiler
that emits correct scalar code is the platform every later measurement is taken against.

**Blocked by: E1. Blocks: E5, E6.**

### E3. Front end — *parallel with the back end*

Reader, `syntax-rules` expander, surface-to-core parse, declaration forms, A-normalization.

Deliberately not first. A reader is a solved problem with no research risk, and starting
here spends weeks before learning anything. On the milestone-1 path, not on the risk path.

**Blocked by: E1. Blocks: E6.**

### E4. Analysis — *the widest epic, and partly done*

Intervals (**done**), the fixpoint analyzer (**done, prototype**), e-SSA, ABCD, check
elision, Pentagon, loop recognition with induction variables and trip counts,
representation and storage-class assignment, alias analysis, inlining, escape analysis.

Every one is testable on fixtures alone, so this is where swarm width lives. Internal edges
are real but shallow: e-SSA before ABCD, ABCD before elision, loops before stage 10's unroll
factor, alias before vectorization.

Free lunch already recorded in `CUJ.md`: ABCD's amplifying-cycle detection supplies
induction-variable discrimination as a side effect, so the loop bead shrinks. It does not
vanish, because ABCD does not supply a trip count.

**Blocked by: E1. Blocks: E5.**

### E5. Vectorization — *the headline, and last*

Scalar f64 loop to packed. The capability no Lisp-family compiler has: Chez emits only
scalar `sd` forms, SBCL can encode AVX-512 but has no auto-vectorization pass at all, and
`sb-simd` stops at AVX2.

**The two targets are not the same problem.** AVX-512 is fixed-width; RISC-V Vector is
length-agnostic, with the vector length a runtime value the loop reads and adapts to. That
is a different legality argument and a different emission strategy, and it should be
scoped as two beads sharing one legality analysis rather than one bead with a flag.

**Blocked by: E2, E4. Blocks: E6 milestones 4 and 5.**

### E6. Verification and milestones

The correctness oracle wired to the compiler, differential testing (optimized against
all-optimization-disabled; any divergence is an unsound analysis), disassembly assertions,
the six milestone gates.

Not a phase at the end. Each milestone bead closes by the epic that reaches it, and the
differential harness must exist **before** milestone 1.

**Blocked by: E2, E3 for milestone 1.**

### E7. Runtime — *fully parallel, start any time*

Precise generational copying collector, calling convention, foreign boundary, numeric tower
for fixnum and flonum, primitives.

Four mechanisms to copy outright rather than invent, all from the OS bundle:

- **Alias the allocation check with the remembered-set overflow check.** Allocation pointer
  grows up from the nursery base, remembered-set pointer grows down from its top. Running
  out of either is the same event on the same path, so the store buffer's dedicated limit
  register and bound check are both free.
- **No generation check in the emitted barrier.** Store, test one tag bit, push the slot
  address if not a fixnum. The mutator never reads the segment table; all filtering is
  deferred and batched. About ten instructions per pointer store. Note the barrier is the
  price of choosing *generations*, not of mutation: Loko, Gambit and Guile all have full
  mutation and no barrier because none is generational.
- **Constant per-byte assist, not a feedback pacer.** A control loop has transients and an
  unbounded assist charge can land inside a lock or an interrupt handler.
- **Reserve the collection worst case before you need it.** The only systems in the bundle
  that survive heap exhaustion do this; Linux, Chez and Mirage all die instead.

Plus **restart regions** for the allocator's claim-then-fill window, per D21, which cost
nothing on the fast path and nothing when no collection happens.

`CUJ.md` is right that a bump allocator that never collects suffices through milestone 5,
because nbody allocates almost nothing. So the GC bead is real but low-urgency and can
absorb slack.

**Blocked by: E1** for the stack-map and partition contracts.

## 5. Critical path

```
E1 contracts ──► E2-core ──► E2-<target> ──► E6 milestone 1 ──► E4 elision ──► E5 ──► E6 m4/m5
```

Everything else has slack. Two implications worth stating before the breakdown:

**The back end determines the schedule.** If total time needs to come down, it comes down by
narrowing E2's scope, not by adding parallelism elsewhere. The scope lever available is the
instruction subset: nbody needs `addsd`, `subsd`, `mulsd`, `divsd`, `sqrtsd`, `movsd`,
`cvtsi2sd` and integer address arithmetic, and nothing else. Encoding the full x86-64 ISA is
not on the path to any milestone.

**Adding agents to E4 does not shorten the project**, it only front-loads analysis work that
then waits on E2. Worth doing anyway, since the alternative is idle, but the plan should not
claim a speedup it will not deliver.

## 6. What "one shot" can and cannot mean

Honestly: the DAG above supports substantial parallel execution and the analysis epic in
particular is well-suited to it. What it does not support is a single pass that produces a
finished optimizing native compiler, and the reason is E2 rather than any failure of
planning. Instruction selection, register allocation and encoding are mutually coupled
through the machine model, they are the least parallelizable work in the project, and they
sit on the critical path before the first milestone.

A realistic shape: E1 as one careful reviewed unit, then E3, E4 and E7 running wide while
E2 proceeds as a focused chain, converging at milestone 1. Everything after milestone 1 is
genuinely incremental and each subsequent milestone is a real deliverable on its own.

Planning it as one shot invites the failure mode where E2 is under-scoped because it is
inconvenient, and the whole thing stalls at the first attempt to emit an object file.

## 7. Decisions needed before breakdown

Three, and the first is the only one that blocks.

**Which target is implemented first?** RISC-V is first-class (D22) but the machine that
holds every measured baseline in phases 3 and 4 is this x86-64 box, and running SonicScheme
under QEMU would confound the comparison the whole project exists to make.
**Recommendation: x86-64 implemented first, both machine models designed in E1.** RISC-V
lands second and its landing is the proof that the abstraction was real. The counter-argument
is that implementing the second target first is the honest test of the abstraction, and it
has weight; QEMU works and the RV64 boot prologue is already assembled and booted in
`compare-operating-systems`.

**Nanopass, or hand-rolled?** `CUJ.md` step 1 says `git submodule add
nanopass-framework-scheme`. That is a real dependency in a public repo, and the counter-
evidence is that `sonic/` already works without it: the interval domain and analyzer are
plain R6RS libraries with no framework at all. Nanopass buys real leverage for a 13-stage
pipeline with many near-identical language definitions, which is exactly our shape, and it
is by the people who wrote Chez. Against: it is a submodule, a build step, and unreadable
error messages cold. **Recommendation: vendor it.** The leverage is largest precisely where
we are heaviest, and hand-rolling thirteen language definitions is the kind of self-indulgent
custom tooling that the project's own rules say to avoid when a maintained tool exists. But
it is a dependency decision on a public repo and it is yours.

**Does SonicScheme live in this repo or its own?** It is currently `sonic/` here, which
keeps the measurements and the compiler in one history and makes the `harness/` comparison
trivial. It will eventually be much larger than the thing it is nested inside.

**Which benchmark set does milestone 6 use?** `CUJ.md` names fannkuchredux and spectralnorm
alongside nbody. Both need writing under the `bench/nbody/SPEC.md` discipline first, and
neither exists.

## 8. What a bead looks like when this is broken down

Not the breakdown, the shape one takes, so the mechanical step has no ambiguity:

- **type**: `epic` for E1-E7, `task` for work items, `decision` for §7
- **parent**: the epic
- **deps**: `blocks:` edges from §4, which are already a DAG and should pass
  `bd dep cycles` clean
- **acceptance**: the test that exists when it closes, per §3
- **labels**: the stage number from `CUJ.md`, so the bead graph and the spec stay
  cross-referenced
- **priority**: critical path (§5) at P0/P1, slack work at P2+

`bd swarm validate` wants an epic with a child DAG, which is exactly this structure, so
E4 should swarm cleanly and E2 should not be swarmed at all.
