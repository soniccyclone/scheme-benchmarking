# The plan the loop follows

Read this at the start of every autonomous iteration, then `bd ready`. It exists
because a loop that re-derives its priorities each time it wakes will drift, and
because the ordering below is not obvious from the bead graph alone.

Nathan set this running and is not watching each iteration. That is the whole
reason for the boundaries in the last section: the cost of a wrong call is not a
wasted hour, it is a wrong number in the ledger that later work is built on.

---

## Where the project actually stands

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

Two things fall out and they set the order of everything below. **Milestone 3 is
met on wall clock** — 5.85x with the interval nowhere near 1.0 — and needs only
the decision in qaq.10 about its second instrument. And sonic is at PARITY with
scalar C while 1.14x behind vectorized C, both established at 40 reps, which
means **the whole remaining gap to Milestone 5 is the vectorization gap** — E5,
not scalar tuning. Do not spend iterations shaving scalar code to reach M5.

That is not idle advice: raising the unroller's growth budget was tried and
measured, unrolls hard (902 instructions to 1734, packed functions 5 to 17), and
is NOT faster — ratio 1.0023, CI [0.8708, 1.1030]. It is kept as the `sonic-u4`
configuration so the negative result stays measurable.

fannkuch stands at roughly 1.2x behind gcc (D57), and instructions retired are
2.51x at n=11 (D60). That gap is instructions, not scheduling, which is the
opposite of nbody's diagnosis (D37).

---

## The queue, in dependency order

102 of 112 closed. What remains is four DECISIONS and the work gated behind
them. E1, E2, E4 and E7 are closed; every pass in the tree now has a test.

### Waiting on Nathan — do not decide these autonomously

**`1mp.5` / `1mp.4` — how four lanes become reachable.** Both capabilities
already exist: slp.ss has a complete four-lane arm behind the
`four-lane-packing?` parameter, and vectorize.ss has the linearization. Neither
helps, because four ADJACENT elements are never visible in one block --
`store-at` needs the same base AND index vreg with differing offsets, and one
iteration of nbody's position update writes three. Two ways out, and the first
is not the agent's call:
  (a) a padded four-wide layout, which CHANGES THE BENCHMARK;
  (b) unrolling until indices fold to literals, which does not.
Raising `specialize-growth-budget` was tried as (b) and does not get there --
see `sonic-u4`.

**`qaq.10` — one question left, and it is narrow now.** A second counter exists
(`harness/qemu-count.sh`) and `measure.sh` picks between them, labels which
answered, and refuses rather than printing a number for a broken run — see D63.
So M3's instruction arm IS obtainable: sonic 664.13 instructions/step against
sbcl-5's 2231.77, a factor of 3.36, alongside the wall-clock 5.85x. The only
open question is whether a milestone may be answered by TWO instruments that
agree to ~1% rather than exactly. c-native remains uncountable by anything here,
so Milestone 5's instruction comparison needs a reword regardless.

**`xei` (E3) — the acceptance names an artifact that does not exist**, a
hand-written core fixture. parse-test.ss does something stronger and passes.
Reword or add the fixture.

**`qaq.5` (M3) and `qaq.6` (M4)** are gated on the two above: M3 on `qaq.10`,
M4 on `1mp.5`. Neither should be closed until its gate is decided -- M4 in
particular must NOT close on vectorize-test.ss passing, since that assertion
runs on a kernel that never ships.

### Actionable without a decision

**`qaq.8` — Milestone 6: fannkuchredux.** Oracle arm already passes. The elision
arm is open, and it is the same shape as M2: verify on the real compiled binary,
assert in the suite with a control that can fail, file findings as beads.

**`qaq.7` — Milestone 5** is 1.14x away and the gap is vectorization, so it
follows E5 rather than leading it.

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

Three instruments, and which one you may use is not a free choice.

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

## Before closing ANYTHING

```
make -C sonic test        # the suite
make smoke                # the RISC-V gate
make containment          # the limits still hold
```

All three, every time a bead closes. The image and the harness both changed
underneath this project twice this month; the gates are what noticed.

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

So: when a gate passes, occasionally ask what it would take for it to fail, and
check that that is still possible. When adding a gate, make it fail once on
purpose before trusting it. This is the single highest-value habit on this
project and it has paid out five times in one month.

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

**Stop and ask.** Anything that changes what a number MEANS: the oracle, the
measurement methodology, the benchmark set, the reported N. Reversing a
D-numbered decision. Suppressing a check to gain speed — that needs a named,
lexically-scoped permission per D5 and D24, and adding a new permission is
Nathan's call. Any change to `bench/*/SPEC.md` or `docs/METHOD.md`.

**When the ready queue is empty**, do not invent work. Do the epic-hygiene audit
above, then the E5 decomposition audit, then report that the queue is dry and
what would unblock it. A loop that manufactures tasks to look busy is worse than
one that idles.
