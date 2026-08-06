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

### E1. Substrate and IR contracts — *blocks everything*

The critical bead. Nanopass or hand-rolled (see §7), `boot.ss`, the identity-pass smoke
test `CUJ.md` calls for, and then the frozen language definitions for every inter-stage IR.

Ships the fixture vocabulary too: constructors and a printer for each IR, so every
downstream bead can write test inputs without importing an upstream pass.

**Blocks: E2, E3, E4, E5.** Nothing starts before this closes. It should be sized
deliberately small and reviewed hard, because a revision here invalidates work everywhere.

### E2. Back end — *the serial spine, and it comes first*

Instruction selection, register allocation, x86-64 and AVX-512 encoding, object emission,
stack maps for precise GC roots.

`CUJ.md`'s decomposition note is emphatic and correct about ordering: **the back end comes
before any analysis**, because a compiler that emits correct scalar code is the platform
every later measurement is taken against. Without it, no analysis bead can be validated
end-to-end and milestone 1 is unreachable.

This epic is where parallel width is genuinely poor. Selection, allocation and encoding are
coupled through the machine model, and splitting them across agents mostly creates merge
conflict. Treat it as a short chain, not a swarm, and expect it to dominate the critical
path.

**Blocked by: E1. Blocks: E6 (milestone 1), E5.**

### E3. Front end — *parallel with the back end*

Reader, `syntax-rules` expander, surface-to-core parse, declaration forms into the
environment.

Deliberately not first. A reader is a solved problem with no research risk, and starting
here is the classic way to spend three weeks before learning anything. It is on the
milestone-1 path but it is not on the *risk* path, so it runs alongside E2.

**Blocked by: E1. Blocks: E6.**

### E4. Analysis — *the widest epic, and partly done*

Intervals (done), Pentagon, e-SSA construction, ABCD, check elision, loop recognition and
induction variables, representation/storage-class assignment, alias analysis, inlining,
escape analysis.

Every one of these is testable on fixtures alone, so this is where swarm width lives. The
internal edges are real but shallow: e-SSA before ABCD, ABCD before elision, loops before
stage 10's unroll factor, alias before vectorization.

Note the free lunch already recorded in `CUJ.md`: if ABCD is built, its amplifying-cycle
detection supplies induction-variable discrimination as a side effect, so the loop bead
shrinks. It does not vanish, because ABCD does not supply a trip count.

**Blocked by: E1. Blocks: E5.**

### E5. Vectorization — *the headline, and last*

Scalar f64 loop to packed AVX-512. The capability no Lisp-family compiler has: Chez emits
only scalar `sd` forms, and SBCL can encode AVX-512 but has no auto-vectorization pass at
all.

Depends on correctness of representation, loops, alias analysis and check elision
simultaneously. Genuinely last, and the plan should not pretend otherwise.

**Blocked by: E2, E4. Blocks: E6 (milestones 4, 5).**

### E6. Verification and milestones

The correctness oracle wired to the compiler, differential testing (optimized against
all-optimization-disabled, any divergence is an unsound analysis), disassembly assertions,
and the six milestone gates.

Not a phase at the end. Each milestone bead is closed by the epic that reaches it, and the
differential harness must exist before milestone 1, not after.

**Blocked by: E2, E3 for milestone 1.**

### E7. Runtime — *fully parallel, start any time*

Precise generational copying collector, calling convention, foreign boundary, numeric tower
for fixnum and flonum, primitives.

`CUJ.md` gets this right: a bump allocator that never collects is enough through milestone
5, because nbody allocates almost nothing. So the GC bead is real but its *urgency* is low,
and it can absorb slack for anyone blocked elsewhere.

Depends on E1 only for the stack-map contract with E2.

## 5. Critical path

```
E1 contracts ──► E2 back end ──► E6 milestone 1 ──► E4 elision ──► E5 vectorize ──► E6 m4/m5
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
