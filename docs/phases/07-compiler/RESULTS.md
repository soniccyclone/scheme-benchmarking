# Phase 7 Results: SonicScheme

2026-08-07. The compiler exists and most of it works. This records what is measured, what
is not, and the one thing the plan got wrong.

## What runs

`bench/nbody/config-sonic.sps` — a real nbody in SonicScheme's surface syntax, verified
bit-exact against `config2a.sps` and against `bench/nbody/SPEC.md` at N=1,000 and
N=100,000 — passes through **eleven stages**:

```
read → expand → parse → policy → anf → assign → inline → essa → elide → repr → lower
```

and comes out a 16-block `Lmach` CFG. **40 test suites, all green.**

## The numbers

| measurement | value |
|---|---|
| checks **proved** by the analysis | **50** |
| checks kept | 177 |
| checks suppressed by policy | **0** |
| bindings unboxed as `raw-f64` | 152 |
| bindings unboxed as `raw-word` | 143 |
| bindings `tagged` | 27 |
| blocks after lowering | 16 |

Every one of the 50 is a **proof**, not a permission. `lower.ss` counts `proved` and
`unchecked` apart precisely so that claim can be made honestly: the two emit identical code
and mean opposite things, and reporting the second as the first would be the most
flattering possible way to lie about the result.

Most bindings are unboxed and doubles dominate, which is what nbody is and what
`PROPOSAL.md` predicts.

## Both back ends emit real objects

Verified **differentially against the real assembler**, not against our own expectations —
hand-derived encodings are wrong more often than not.

| target | instructions byte-verified | notes |
|---|---|---|
| x86-64 | 63 | 36 carrying a REX prefix |
| RV64 | 68 | each also disassembling back to its mnemonic |

SonicScheme's own RV64 output, read back by `riscv64-linux-gnu-objdump`:

```
addi t0,zero,7 / mul a2,a1,t0 / add a3,a2,a4
slli t1,a3,0x3 / add t1,a0,t1 / fld fa0,0(t1) / jalr zero,0(ra)
```

The RISC-V smoke gate asserts this on every run and that nothing above the pinned `rv64gc`
baseline crept in.

## What does not work

**A multi-argument call.** `Lmach`'s `call` has no fixed arity and neither selector lowers
it into argument moves plus a jump, so the whole lowered program stops at selection with an
arity error. `callconv.ss` defines the argument registers, return register and
caller/callee split for both targets, and precoloring exists as a pre-pass over the
allocator. Nothing joins them to the selector. **Milestone 1 and everything downstream wait
on exactly this.**

**Tail calls** currently lower to ordinary calls, losing the one performance guarantee R5RS
made that ANSI CL never did.

**Vectorization** has legality in progress and no emission.

## What the plan got right, and the one thing it got wrong

`EXECUTION.md` §1 bet that freezing the IR contracts before writing any pass would convert
a depth-13 chain into a wide DAG. **It held.** Seven agents built passes in parallel
against hand-written fixtures, and when those passes were finally composed on a real
program they fit together with three gaps — all plumbing rather than design.

The cost is the thing worth recording. Two passes were missing a program-level entry point,
and one pass, `repr.ss`, had been **claimed and never written**. All three went unnoticed
*because nothing composed the passes until then*. Fixture-tested passes can every one pass
while the pipeline does not exist.

The worst of the three was not the missing pass. `elide` had no program entry, so a whole
program fell through its expression dispatch, walked nothing, and reported **"proved 0,
kept 0"** — which reads exactly like a program containing no checks rather than a pass that
never ran. For a pass whose entire output is a count, silently correct-looking is the worst
failure mode available, and that zero was nearly written down as a result.

The countermeasure is `sonic/test/pipeline-test.ss`: it runs the real benchmark through
every stage and reports the reach as a **number**, so "how far does the compiler get" stops
being an impression.

## Errors found in the literature, while building

Recorded because they are implementation hazards, not trivia. These join the Kildall,
Pentagons, Chaitin and Allen-Kennedy errors already in `LEDGER.md`.

**ABCD's neutral-cycle rule is unsound as stated.** "Revisit an active vertex at the same
slack, conclude true" assumes the cycle you closed was a loop iteration. An equality edge
pair — a length and its alias — is a zero-weight two-cycle with no phi on it, and reading
that as an iteration proves *every* inequality about that length, including the false ones.
The fix is to count meet vertices on the active path and refuse a cycle that crossed none:
the coinduction needs a merge point to induct over.

## Design decisions this phase produced

Ratified into `LEDGER.md`: PC-total GC metadata with a static register partition (D21),
RISC-V as a first-class target (D22), nanopass vendored (D23), FP contraction as a named
lexically-scoped permission defaulting off (D24), the runtime written in Scheme with no
libc anywhere in the running system (D25), and keeping our callee-saved set inside System
V's rather than claiming `rcx`/`rdx` (D26).
