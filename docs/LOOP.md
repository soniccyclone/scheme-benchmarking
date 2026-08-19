# The plan the loop follows

Read this at the start of every autonomous iteration, then `bd ready`. It exists
because a loop that re-derives its priorities each time it wakes will drift, and
because the ordering below is not obvious from the bead graph alone.

Nathan set this running and is not watching each iteration. That is the whole
reason for the boundaries in the last section: the cost of a wrong call is not a
wasted hour, it is a wrong number in the ledger that later work is built on.

---

## Where the project actually stands

**CHECKS EMITTED, which is what D5 and D24 make this project about.** Both
benchmarks, counted on the finished binary by the label each trap branches to:

| | bounds | overflow | before D153-D157 |
|---|---|---|---|
| nbody | 0 | 1 | 29 traps |
| fannkuch | 0 | 3 | 8 traps |

nbody's one is `(fx+ i 1)` against a command-line `n` -- no round count reaches an
unbounded parameter, so one is the correct answer for that program, and the suite
pins it at one. fannkuch had never emitted zero bounds checks in this ledger
before. What moved was `ascent-rounds`, 4 to 16: a constant justified on a single
example and never re-derived (D157).

**Cycles, four layout-pad values per arm per D105:**

| | before | after | |
|---|---|---|---|
| fannkuch | 9,926.6M | 9,331.0M | **-6.0%**, ranges non-overlapping |
| nbody | 943.5M | 943.9M | unchanged, on 6.9% MORE instructions (D89) |

The 6% decomposes: 1.5% from merging identical functions (D121, D130), 4.5% from
turning `unroll-program` off -- which only became possible because the round count
made check elision independent of the duplicated induction step. **The speedup
came from deleting a transformation.**

---

Slope of N=1,000,000 to 2,000,000, **40 reps**, bootstrap CI, baseline sonic:

| config | ns/step | ratio vs sonic | verdict |
|---|---|---|---|
| **sonic** | **65.03** | — | baseline |
| c-native (`gcc -O3 -march=native`) | 56.88 | 0.8746, CI [0.8288, 0.9464] | **real** |
| c-scalar | 62.77 | 0.9653, CI [0.8932, 1.0352] | no detected difference |
| sbcl-5 | 374.95 | 0.1709, CI [0.1552, 0.1843] | **real** (sonic 5.85x ahead) |

REP COUNT IS LOAD-BEARING AND 15 IS NOT ENOUGH. The same c-native comparison at
15 reps gave CI [0.8011, 1.0024] — an interval containing 1.0, i.e. no detected
difference. At 40 it is [0.8288, 0.9464] and real. Any claim about the gap to C
needs 40; a table of min-of-N wall clock at one N, which is what this section
used to hold, is not a result at all.

This table names its own baseline, which the script that produced it did not:
`bench.sh` printed `BASELINE` in the header and divided by whichever config
measured first (D70), and `measure.sh` had the same bug under a `vs-C` heading
(D69). Both compute the label from the divisor now. When re-measuring, check that
the row marked `(baseline)` is the row the header names — that mismatch is the
only thing that gave either bug away.

**Instructions, and they now agree with wall clock.** sonic retires 664.00
instructions/step against c-scalar's 654.00 — **1.02x**, not the parity-or-better
the mislabelled column implied. Wall clock says the same thing: ratio 1.0507, CI
[0.9926, 1.0979], no detected difference. Two instruments telling one story about
where we stand against C is new as of D69/D70.

Two things fall out and they set the order of everything below. **Milestone 3 is
MET AND CLOSED**, both arms: 5.95x on wall clock (CI [0.1630, 0.1829]) and 3.16x
fewer instructions, the latter with both sides forced onto qemu so the comparison
is single-instrument (D68). And sonic is at PARITY with
scalar C while 1.14x behind `gcc -O3 -march=native`.

**THE GAP TO M5 IS FMA, NOT VECTORIZATION — this section said the opposite for a
long time and sent four routes' worth of work the wrong way (D79).** Counted from
the emitted binaries:

```
sonic        scalar=161  packed=36  fma=0
ref-native   scalar=175  packed=25  fma=81
```

We already emit MORE packed arithmetic than c-native does, and c-native uses no
256-bit at all — 748 xmm, zero ymm, zero zmm; its EVEX encodings buy xmm16-31
for spills, not width. What it has and stock sonic has none of is 81 fused
multiply-adds. `contract.ss` can produce them and is wired in; `fp-contract` is
a permission defaulting to OFF (D24) that the benchmark never granted, while
gcc -O3 takes `-ffp-contract=fast` by default. See the `sonic-fma` configuration.

That is not idle advice: raising the unroller's growth budget was tried and
measured, unrolls hard (902 instructions to 1734, packed functions 5 to 17), and
is definitively WORSE, by counters (D87): 962.6M cycles, 3421.8M instructions
and 320.3M branches against sonic's 944.6M / 3321.8M / 300.3M. The old wall-clock
reading — ratio 1.0023, CI [0.8708, 1.1030], "no detected difference" — had an
interval too wide to detect anything. Growing the specializer budget without a
known trip count duplicates work instead of removing control flow. It is kept as
the `sonic-u4`
configuration so the negative result stays measurable.

fannkuch stands at roughly 1.2x behind gcc (D57), and instructions retired are
2.51x at n=11 (D60). That gap is instructions, not scheduling, which is the
opposite of nbody's diagnosis (D37).

---

## The queue, in dependency order

**11 of 132 open, and TWO OF THEM ARE DECISIONS FOR NATHAN.** The shape of the
queue changed: it is no longer a list of work waiting for effort.

| what | state |
| --- | --- |
| `qaq.7` | Nathan's call. D127 showed it cannot be settled by measuring harder |
| `qaq.13.4` | Nathan's call. Does RV64 output require V? (D176) |
| `qaq.13`, `qaq.13.2` | blocked on `qaq.13.4` |
| `qaq.15`, `qaq.18`, `qaq.26` | blocked on `qaq.33` |
| `qaq.23`, `qaq.33` | P4, and see below |
| the two epics | close when their children do |

**The four remaining P4s share one property and it should be said plainly: their
payoff has been MEASURED, and it is zero wall clock.** D120 audited all of them
against D89, D111 and D112. D167 then tested the strongest counter-argument
anyone had — that removing register copies relieves the front-end stall D112
measured — by removing 9.9% of fannkuch's instructions and 2.9% of nbody's. The
clock did not move on either.

So `qaq.33` (cross-block liveness) would be a dataflow analysis over the finished
listing, written to unblock three beads whose combined measured value is zero
seconds. It is real work with real wrong-code risk — liveness that is wrong in the
optimistic direction deletes a live definition. **The recommendation is not to
build it**, and to close `qaq.15`, `qaq.18`, `qaq.26` and `qaq.33` together with
D161's diagnosis as the record of why. That is a scope decision, so it is Nathan's
rather than an agent's to take unilaterally.

`qaq.23` is the same shape with its own ceiling now measured: D162 found the
spill traffic real and confined to two call-graph-cycle members, and D163 measured
those at 10.47% of the profile with none of the four hottest blocks spilling at
all.

### `qaq.7` — Milestone 5: within a few percent, and which side depends on the day

Measured symmetrically (contracted against contracted, D80), 40 reps, baseline
c-native. TWO sessions of the same compiler, because the difference between them
is the point:

| config | D86 ratio | D127 ratio | D180 ratio (**build verified**) |
| --- | --- | --- | --- |
| c-native (`gcc -O3 -march=native`) | (baseline) | (baseline) | (baseline) |
| sonic-fma | 1.0414, CI **spans 1.0** | 1.0811, CI **excludes it** | 1.0345, CI **spans 1.0** |
| c-scalar (`gcc -O3`) | 1.0874 | 1.1076 | not run |
| sonic | 1.0969 | 1.1743 | 1.1216 |

D180 is the first of these taken with the harness verified to have REBUILT.
`bench.sh` never compiled, and `compile.sh` was broken from the host from
2026-08-10 until D166 — which covers both earlier columns. Two of the three
sessions now say "no detected difference" for sonic-fma, and D127 is the odd one
out.

Between D86 and D127 **our own figure moved +0.45% (60.05 to 60.44 ns/step) and
the reference moved -3.05% (57.66 to 55.90)**, so the verdict flipped from "no
detected difference" to "real" without the compiler changing. fannkuch gives the
exact control: its instruction count was seven apart out of twenty-seven billion
across that interval -- provably identical work -- and its wall clock moved 1.50%
(D127). D180's reference came in at 56.88, between the two.

So do not quote any single row as the standing. The supportable claim is that
**sonic-fma and c-native are within a few percent of each other, and which side
of the line the interval falls on depends on the day.** What reproduces is the
instruction counts, which are stable to 0.002%:

| | sonic | reference | ratio |
| --- | --- | --- | --- |
| nbody, per step | 676.00 | not countable* | -- |
| fannkuch, n=11 | 26,912,083,639 | 10,992,262,824 | 2.45x |

\* callgrind cannot count `gcc -O3 -march=native` output on this host.

Both fell in D167 (live-range-scoped precoloring): nbody 696.00 -> 676.00 per
step, fannkuch 29.88G -> 26.91G. The fannkuch figure had risen to 29.88G when
unrolling went default-off, which bought 6.0% of cycles, so do not read that
earlier rise as a regression either (D164).

fannkuch's wall clock at n=11, 9 reps, freshly built: sonic 3258.8 ms min against
c-native's 2738.4 ms, **1.19x behind**. nbody is ratio 1.1036 against c-native
with CI [0.9884, 1.1646] -- no detected difference. The mapped cycle profile is
in D163.

**Ten percent of fannkuch's instructions came out in D167 and its wall clock did
not move.** That is the third measurement saying the same thing (D89, D111, D167)
and the one that killed a specific argument for why this case would differ. Do
not schedule work on this benchmark expecting instruction count to buy time.

**REBUILD BEFORE YOU MEASURE.** `bench.sh` and `measure.sh` do not compile; they
run whatever binary is on disk, and `compile.sh` was silently broken on this host
until D166. Run `harness/compile.sh <config>` first and check it says `[built]`.
`measure-fannkuch.sh` compiles on its own.

Read the intervals, not the point estimates. Plain `sonic` is genuinely behind C
in both sessions.

**NO LONGER BLOCKED ON MEASUREMENT.** `harness/vm-perf.sh` gives hardware
counters through a KVM guest — `perf_event_paranoid` is a property of A kernel,
so booting a second one where we are root settles it, with nothing on the host
changed (D85).

**AND THE DIAGNOSIS THIS SECTION USED TO CARRY WAS WRONG.** It said IPC or a
dependency chain. The counters say the opposite — nbody at N=5e6:

```
                 cycles    instructions    IPC     branches
sonic-fma   888,081,464   2,981,677,267   3.36   300,284,364
ref-native  850,528,398   1,667,502,723   1.96    65,433,871
```

Cycle ratio 1.0442, confirming the wall clock from an independent instrument. We
run **1.79x the instructions at 1.71x the IPC**. At 3.36 we are near issue width
and are not stalling; the extra work is already hidden behind superscalar width
and the 4.4% is what will not fit. M5 is an INSTRUCTION-COUNT problem wearing a
latency problem's clothes.

Follow the branches: **300M against C's 65M**, mispredicted at 0.02% — cheap,
perfectly predicted, still occupying issue slots. That is the shape of bounds and
type checks. fannkuch agrees from the other direction (2.51x instructions for
1.24x time), so two benchmarks now tell one story. Filed as `qaq.16`.

Do not fill this with a theory. Two have been refuted here already: register
pressure (the per-function breakdown put every spill in `join.10`, which carries
no float arithmetic at all) and latency (the counters above). Measure first —
the instrument exists now.

### `qaq.13` — Milestone 4 on RV64 (reparented under E5, where it belongs)

RVV lowering. The encoder is ready and byte-verified (`vsetvli`, `vfadd.vv`,
`vfmul.vv`, `vfmacc.vv`, `vle64.v`, `vse64.v`), and RV64 is now measurable (D83),
so the acceptance's "not slower" clause is answerable by instruction count.

**The register class is the cheap half** — `pool-for` is a three-case dispatch and
the arch record already carries a `mask` pool for AVX-512 k registers, so a
`vector` pool is precedented. Perhaps an hour.

**The expensive half is a design tension in `slp.ss`, and it should be understood
before starting.** slp's whole premise is that a packed value is an ORDINARY
`raw-f64` vreg — its header: *"the register allocator, the static partition and
the collector need no changes at all, because a pair lives exactly where a scalar
double lives."* True on x86-64, where one `xmm` holds both lanes. **False on
RV64**: `f` registers are 64 bits, so a 2-lane pack needs a `v` register, a
different file. slp would have to emit a target-dependent storage class, which is
the property its design exists to avoid.

So this is not "extend slp" — it is a separate RVV path, which is what
`vectorize.ss` and `vec-rv64.ss` were written for. They carry the RVV knowledge
and 17 green assertions and emit LISTINGS rather than vregs (D67); the work is to
produce vector-class vregs from that knowledge. `vsetvli` is also stateful: a
region must be re-entered at its `vsetvli` if control rewinds into it, so it
cannot be emitted per-operation for free and a peephole cannot safely move it.

**Why it is still worth doing** (D83): contraction gains 10.2% on x86-64 and 6.9%
on RV64, and the difference IS this bead — on x86 a fused multiply-add folds two
PACKED operations, on RV64 two scalar ones. Packing does not merely add its own
saving; it doubles what every subsequent fused multiply-add is worth.

## Definition of done, per kind of bead

An **assertion milestone** (M2, M4, M6) is done when the assertion lives in the
suite and fails if the property regresses. Prove it can fail — `differential-test.ss`
spends most of its length proving its own oracle can fail, and that is the
standard here. An assertion that cannot fail proves nothing.

A **performance milestone** (M3, M5) is done when the bootstrap CI excludes 1.0
and the numbers are in the ledger with the N, the repetition count, and which
instrument produced them. Wall clock and instructions retired are different
claims; never let one stand in for the other.

An **implementation bead** is done when the suite, the smoke gate and the
containment gate are all green and the change has a ledger entry if it involved
a decision.

---

## Measuring anything

**Do not edit a script while a long measurement is running it.** The container
mounts the repo live and every harness script re-execs into it, so a script is
read from disk as the job runs. Editing `measure.sh`'s header mid-run killed a
20-minute sbcl-under-qemu measurement with `unexpected EOF while looking for
matching quote` — a syntax error in a file that was syntactically fine both
before and after. Queue the edit, or let the run finish.


**A FOURTH INSTRUMENT EXISTS NOW: hardware counters.** `harness/vm-perf.sh
<command>` runs the workload under a KVM guest where we are root and
`perf_event_paranoid` is ours to set, so `perf` works with no change to the host
(D85). `MODE=record` gives a sampled by-function profile; `EVENTS=...` picks
counters. perf against the HOST kernel is still impossible and no flag fixes it.

**The three rules that make its numbers mean anything.** Every one of them was
learned by getting it wrong in this ledger, and the entries are cited so the
evidence is checkable rather than taken on faith.

1. **Instruction counts are sound; cycle counts are not.** Five runs of one
   fannkuch binary vary 0.002% in instructions and 1.96% in cycles (D94). A
   single-run cycle comparison at the one-to-two percent level says nothing. Use
   instruction counts for A/B work.

2. **fannkuch's cycles move 4.97% on CODE ALIGNMENT ALONE.** Appending
   unreachable instructions -- no semantic change whatever -- swings it from
   9,430.7M to 9,900.1M cycles with instruction counts constant to 0.003%
   (D105). `(layout-pad n)` in `runtime.ss` is the control: to compare two
   fannkuch builds, sweep BOTH across several pad values and compare
   distributions. Comparing one build of each measures alignment luck, which is
   how D104 rejected a correct change. **nbody moves 0.26% over the same sweep**
   and needs no such care.

3. **A RATIO RECORDED IN THE LEDGER DOES NOT COMPARE TO ONE YOU MEASURE TODAY.**
   `bench.sh` measures every configuration in the same run, so a uniform machine
   change cancels in the ratio -- and the ratio drifts anyway, because the two
   programs do not respond to machine state alike. Measured (D127): with
   fannkuch's instruction count seven apart out of twenty-seven billion, so the
   work is provably identical, its wall clock moved 1.50%; nbody's `sonic-fma`
   moved +0.45% while `c-native` moved -3.05%, taking the ratio from 1.0414 to
   1.0811 and the confidence interval from spanning 1.0 to excluding it. Compare
   a measurement to one taken the same day, or compare instruction counts, which
   reproduce to 0.002%.

4. **REBUILD BEFORE YOU MEASURE.** `disasm-sonic.sh` compiles rather than
   accepting a binary, and its header explains why; `vm-perf.sh` takes a command
   line and cannot, so the trap is open there. D94 compared a binary built before
   `gconst` against a listing compiled after it and read the difference as an
   effect of the change under test.

**THE TWO BENCHMARKS HAVE OPPOSITE COST STRUCTURES. Nothing learned on one
transfers to the other**, and assuming otherwise has cost this project several
sessions:

- **nbody is dependency-bound.** llvm-mca puts it at 85.65% register
  dependencies (D90). Removing instructions makes it SLOWER -- measured, 465M
  fewer instructions and 120M fewer branches for 18M more cycles (D89). Its IPC
  is already 3.5 against gcc's 2.0; the surplus work is nearly free.
- **fannkuch is dispatch-limited.** Its hot blocks issue at ~6 instructions per
  cycle, the dispatch width, and llvm-mca reports no bottleneck at all (D101).
  Instruction count IS the lever here. It also spends 18-29% of its cycles on
  branch mispredicts -- and gcc spends MORE, so that is not where we lose.

`llvm-mca -mcpu=znver5 -bottleneck-analysis` on an extracted block is how both of
those were established, and it needs no privileges at all.

---

Three instruments below, and which one you may use is not a free choice.

**Wall clock** — `harness/bench.sh`. Slope between two N, bootstrap CI. USE 40
REPS, not 15: the c-native comparison at 15 gives an interval containing 1.0 and
at 40 gives [0.8288, 0.9464]. A min-of-N at a single N is not a result and D57 is
the entry about why.

**Instructions per step** — `harness/measure.sh`, which drives
`harness/count-slope.sh`. It picks callgrind first (every instruction figure in
the ledger came from it), falls back to `harness/qemu-count.sh` for the
managed-runtime Lisps callgrind crashes on, reports WHICH instrument answered,
and refuses rather than printing a number for a broken run.

**Never quote a single instruction count.** Ask for a slope. Two equal counts
have zero slope, and that is the only check that has ever caught a broken
measurement here — callgrind prints a total alongside "unhandled instruction",
QEMU sums a log up to an "uncaught target signal", and clisp's log stops early
because it re-executes itself. Three plausible wrong numbers, all found by the
count not changing when the work changed, none by anything else. D63.

What cannot be counted on this host at all: **c-native** (`-march=native` emits
AVX-512; neither valgrind's VEX nor QEMU's TCG decodes it) and **clisp-9**.
racket and ecl produce a count but cannot be validated — the two-N check does not
finish. c-native being uncountable is why Milestone 5's instruction comparison
needs rewording rather than an instrument.

---

## Before STARTING anything: re-read the bead against the tree

A bead's claims are measurements, and measurements go stale three ways here --
the program changes, the machine drifts (D127), and the instrument was wrong
(D124, D126). A bead written before the work around it will contain numbers that
no longer hold and instructions that no longer apply.

Two found in one evening, both by acting on the bead rather than reviewing it:

- **`qaq.13` prescribed finishing a gap that had been closed three days earlier**
  -- "the RV64 target does not yet run nbody at all" -- fixed by D81, asserted in
  the suite, and still the first half of the bead's plan (D142).
- **`qaq.21` counted 130 register-to-register moves**; there are 118, because a
  pass added since removed the duplicate functions carrying twelve of them
  (D143).

Neither was wrong when written. So: **before starting a bead, check its numbers
against a fresh build and its plan against what has landed since.** It costs one
compile. Acting on a stale prescription costs a session -- D123's, D124's and
D125's prescriptions were each withdrawn by the next entry, and each had been
written into a bead where the next reader would have followed it.

---

## Before closing ANYTHING

```
make -C sonic test        # the suite
make smoke                # the RISC-V gate
make containment          # the limits still hold
```

All three, every time a bead closes. The image and the harness both changed
underneath this project twice this month; the gates are what noticed.

**AND IF YOU TOUCHED A PASS: does its test still prove the pass DOES something?**
Every optimisation pass here now carries an assertion that it fires on nbody, and
every one was validated by deliberately breaking its pass and watching the
assertion fail. That convention exists because `merge-identical-functions`
shipped and did nothing at all on RV64 for two ledger entries -- no test failed,
no measurement looked wrong, and the x86-64 numbers were real, because every
check in this tree asked whether the OUTPUT was correct and none asked whether
the pass had run (D132-D140).

Two traps, both hit while writing those assertions:

- **An assertion that cannot fail.** The first `peephole` one checked that the
  pass returned without error. No change could ever have broken it.
- **An assertion at the wrong stage.** `fold` reports zero on the program it is
  first handed -- what it folds are guards that specialisation turns into
  literals -- so asserting there would have pinned a zero and passed forever.

Both looked like coverage. The rule that catches them: **write the assertion,
then break the pass and watch it fail.** If you cannot make it fail, it is not an
assertion.

`compile-stage-hook` is how a pass whose effect is consumed downstream gets
asserted at all. It is a parameter in `finalize.ss`, re-exported by `driver.ss`,
called with a stage name and the program at each point the driver binds one:

```
lanf   lanf/pre-specialize   lanf/specialized   lmach   lmach/pre-cse
lmach/addrfold   lmach/dce   listing/pre-peephole
```

Default ignores both arguments, so compilation is unchanged when nobody is
looking. `dce-test.ss` is the shortest example.

---

## Filing new beads

Expect to file more than you close for a while — optimization runs produce
findings, and a finding recorded is worth more than a finding acted on
immediately and forgotten.

- A finding that is not the bead you are on becomes a NEW bead. Do not widen
  scope to absorb it.
- Put the measurement in the bead. "count-flips is 22.7% of fannkuch" is a bead;
  "count-flips looks slow" is not.
- Convert relative dates to absolute, and name the instrument (callgrind Ir,
  wall clock min-of-N) so a later reader knows what the number means.
- If a finding contradicts a ratified decision, file it and STOP. Do not
  re-litigate a D-numbered decision autonomously.

## Ledger discipline

Every decision gets a D-numbered entry in `docs/LEDGER.md`, newest last, next
number after the highest present (D61 as of writing). Record what was decided,
what was measured, and what was rejected and why. Entries that record a REJECTED
approach have paid for themselves repeatedly this month — three of the perf
entries exist only to stop the next agent re-testing the same dead flags.

---

## THE FAILURE MODE THIS PROJECT KEEPS PRODUCING

A check that silently stops checking looks exactly like a check that passes.
Five instances, all found by going and looking, none by anything failing:

| | |
|---|---|
| `deploy.resources.limits.memory` | parses, validates, ignored outside Swarm (D30) |
| `timeout --signal=KILL` | uutils accepts it and never delivers the signal |
| `command -v scheme` | smoke gate skipped its compile and exited GREEN (D58) |
| `N=11 REPS=9` | never crossed the container boundary; defaults used silently (D60) |
| ten nbody configs | toolchains absent, oracle quietly ran on 9 of 19 (D61) |
| `[n rejected as parallel]` | `REJECTED` set in a subshell; note always empty (D71) |
| `vs-C` / `baseline %s` | header named one config, arithmetic used another (D69, D70) |

So: when a gate passes, occasionally ask what it would take for it to fail, and
check that that is still possible. When adding a gate, make it fail once on
purpose before trusting it. This is the single highest-value habit on this
project and it has paid out seven times now.

**A guard whose failure path cannot be reached is not a guard.** `bench.sh`'s
serial-only threshold was hard-coded at 1.3, which a single-threaded nbody never
reaches — so the reject-and-report path could not be exercised at all, and that
is exactly why the broken note above survived. It is a parameter now
(`PARALLEL_MAX`) *so that it can be made to fail*. Prefer a threshold you can
inject over one you have to trust.

**A label and its arithmetic drift apart unless one is computed from the other.**
Both baseline bugs had the same shape: a name printed in a header, and a divisor
picked independently by the code. Neither number was wrong — they just were not
the numbers the columns claimed. Compute the label FROM the thing it labels, and
refuse rather than fall back when the named thing is missing; a fallback is what
lets the two disagree quietly.

### Values crossing a `$( )` boundary travel in stdout, never in a variable

Six occurrences now: `measure.sh` COUNTER, `count-slope.sh` INSTRUMENT,
`bench.sh` rc, FAILED_WHY, and REJECTED, plus two preflight checks that had to
move to the main shell. A function invoked as `x=$(f)` runs in a subshell, so
every assignment it makes is discarded the moment it returns — silently, with the
caller reading a default that looks plausible. In these scripts, if the caller
needs it, **print it**; `count-slope.sh` returning `count<TAB>instrument` is the
pattern to copy.

---

## Autonomy boundaries

**Do freely.** Read anything. Run the suite, the gates, the harnesses, the
benchmarks. Implement beads that are ready. File beads. Write ledger entries.
Commit straight to `main` — Nathan asked for that explicitly, no branch, no PR.

**Never.** Push, PR, or send anything to a remote Nathan does not own — the hard
rule in `CLAUDE.md`, and `sonic/vendor/nanopass` is somebody else's project.
Run anything outside the container. Add a second way to run things. Use sudo.
Weaken, delete or loosen a test, an assertion or an oracle to make something
pass.

**DECIDE, as of 2026-08-18.** Nathan's instruction: "make as many decisions on
your own as possible since creating this more performant scheme is all obvious
optimizations and capabilities we are adding." That supersedes the
waiting-on-Nathan set below for ACCEPTANCE WORDING and ROUTE CHOICE. Record the
decision and its reasoning in the ledger, and make it reversible.

It does NOT supersede the two rules under **Never**, and the distinction is the
one that matters: rewording an acceptance to describe what is ACTUALLY VERIFIED
is a decision; rewording it so a weaker check passes is weakening a gate. If a
reword would lower the bar, the honest move is to say the milestone is unmet.

**Stop and ask.** Anything that changes what a number MEANS: the oracle, the
measurement methodology, the benchmark set, the reported N. Reversing a
D-numbered decision. Suppressing a check to gain speed — that needs a named,
lexically-scoped permission per D5 and D24, and adding a new permission is
Nathan's call. Any change to `bench/*/SPEC.md` or `docs/METHOD.md`.

**When the ready queue is empty**, do not invent work. Do the epic-hygiene audit
above, then the E5 decomposition audit, then report that the queue is dry and
what would unblock it. A loop that manufactures tasks to look busy is worse than
one that idles.
