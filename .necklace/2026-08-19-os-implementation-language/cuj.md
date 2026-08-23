# CUJ document: SonicScheme as an operating-system implementation language

Derived from `spec.md` in this directory. One CUJ per actor-outcome pair.

Tests in this repo are `(ck! "<prose claim>" <expr>)` inside `sonic/test/<name>-test.ss`, so the
Test column names the file and the claim rather than a camel-case function.

---

## CUJ-01: Driver author reads a device register twice and it is read twice

**Actor:** driver author
**Trigger:** writes a polling loop that reads one hardware register repeatedly
**Journey:**
1. Driver author marks the access volatile, in whatever spelling CUJ-02 settles
2. Driver author compiles and disassembles the emitted listing
3. System emits one load per source read, at every optimisation setting

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `cse-test.ss`: "a volatile load is not rewritten to an earlier load of the same address" | two volatile reads of one address, no intervening write | after `cse-program`, the consumer still names two distinct vregs | REPL probe 7: `lmach/pre-cse` had `add t.5 t.7`, `lmach` had `add t.5 t.5` — CSE rewrites the use |
| `dce-test.ss`: "a volatile load whose result is unused is NOT dead" | a volatile read whose value is discarded | the load survives `dce-program` | REPL probe 5: loads went 4→2 at DCE; discarding a read is how an interrupt is cleared |
| `cse-test.ss`: "a NON-volatile load of the same address still folds" | the same shape without the control | still one value after CSE | guards against fixing this by disabling CSE |
| `addrfold-test.ss`: "a volatile access keeps its own address computation" | volatile read at `base+idx` next to a non-volatile one | the volatile access is not merged into a shared folded address | probe 7 showed addrfold did not participate for this shape; the test decides whether it can |
| `run-x86-64-test.ss`: "a program that reads one address twice emits two loads" | volatile double read, compiled end to end | exactly two loads at that address in the final listing | probe 1: today this emits one load and adds the register to itself |

**Done when:** the tests above pass. All must be red when created.

**Beads:** scheme-benchmarking-4f0

---

## CUJ-02: Driver author expresses volatility at all

**Actor:** driver author
**Trigger:** needs to say "this access talks to hardware"
**Journey:**
1. Driver author writes the annotation in source
2. System carries it to every pass entitled to move or delete the access
3. System refuses, or ignores it, in a way the author can see

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `lang-test.ss`: "the memory primitives declare a volatile control" | `prim-table` entries for vector and flvector access | each carries `volatile` alongside its existing controls | REPL: `prim-table` is `(name arity control...)`, e.g. `(fxquotient 2 div-check overflow-check)` |
| `alias-test.ss`: "accesses through a marked object are volatile and accesses through others are not" | one expression reading a marked object and writing an unmarked one | the read keeps its control, the write does not | REPL probe 8: that expression emits four memory accesses, only one of which may be volatile |
| `alias-test.ss`: "the mark follows the object into a called procedure" | marked object passed as an argument | accesses inside the callee are volatile | `declare-distinct` runs out at the procedure boundary; this must not |
| `expand-test.ss`: "a volatile setting on a primitive that has no such control is refused" | `volatile` applied where it means nothing | expansion errors rather than silently ignoring it | D5's rule that a control is refused rather than dropped |

**Done when:** the tests above pass. All must be red when created.

**Beads:** scheme-benchmarking-2xc

---

## CUJ-03: Driver author manipulates bits and byte-addressed memory

**Actor:** driver author
**Trigger:** writes a page-table entry or decodes a device descriptor
**Journey:**
1. Driver author shifts, masks and combines fixed-width integer fields
2. Driver author reads and writes individual bytes and words of a memory region
3. System compiles each to the machine instruction that does it, on both ISAs

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `numeric-test.ss`: "shift and mask agree with the model at the 61-bit boundary" | values at and past the fixnum modulus | machine result equals the model's, including where the tag bits fall | REPL: 33 primitives, none of them shifts or masks; the model fixes a 61-bit modulus |
| `x86-64-test.ss`: "bit operations encode byte-for-byte against gas" | each new operation | encoding matches the assembler | 81 instructions are already verified this way |
| `rv64-test.ss`: "the same operations encode against binutils" | each new operation | matches `riscv64-linux-gnu-objdump` | D132/D160: features have silently done nothing on RV64 |
| `numeric-test.ss`: "a byte store writes one byte and leaves its neighbours alone" | write to the middle of a region, read the neighbours | neighbours unchanged | today only word-width vector access exists |

**Done when:** the tests above pass. All must be red when created.

**Beads:** scheme-benchmarking-0wr

---

## CUJ-04: Kernel author writes a program in a language that has records and exceptions

**Actor:** kernel author
**Trigger:** needs a process table entry, a device descriptor, or an error path
**Journey:**
1. Kernel author defines a record type and constructs, reads and updates it
2. Kernel author raises a condition and handles it
3. Kernel author uses the binding and iteration forms real code is written with

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `expand-test.ss`: "a record field read compiles to a load at a fixed offset" | a two-field record | the emitted access is one load, not a search | probe 4: field access should be as cheap as the vector access already is |
| `gc-test.ss`: "a record's tagged fields are found by the collector and its raw fields are not" | record with one pointer field and one raw field | collector scans the first and not the second | the collector is precise, and D21/register-partition.md make that the invariant |
| `expand-test.ss`: "an exception unwinds to the nearest handler and runs no further body" | nested handlers, raise from the inner body | outer handler untouched, inner body stops | |
| `run-x86-64-test.ss`: "a program using records and exceptions produces the same answer under both targets" | one program, both ISAs | bit-identical output | the eleven-way oracle is the constraint spec.md names |

**Done when:** the tests above pass. All must be red when created.

**Beads:** scheme-benchmarking-9yp

---

## CUJ-05: Kernel author proves a path allocates nothing

**Actor:** kernel author
**Trigger:** writing an interrupt handler or an early-boot path where the heap does not exist
**Journey:**
1. Kernel author marks a procedure as allocation-free
2. System compiles it, or refuses with the allocation site named
3. Kernel author sees the refusal at compile time, not at 3am on real hardware

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `escape-test.ss`: "an allocation-free procedure containing an allocation is REFUSED, naming the site" | marked procedure that conses | compile error naming the form | probe 4: leaf fixnum work already allocates nothing, so the guarantee is checkable today |
| `escape-test.ss`: "a procedure that allocates nothing compiles unchanged" | the probe-4 shape, marked | identical listing to unmarked | the mark must cost nothing when satisfied |
| `escape-test.ss`: "the check follows calls, not just the immediate body" | marked procedure calling an allocating one | refused | otherwise the guarantee stops at the first call |

**Done when:** the tests above pass. All must be red when created.

**Beads:** scheme-benchmarking-5em

---

## CUJ-06: Kernel author writes an interrupt handler

**Actor:** kernel author
**Trigger:** the hardware delivers an interrupt
**Journey:**
1. Kernel author defines a handler with the interrupt calling convention
2. System emits an entry that saves what the hardware does not, and the correct return
3. Handler runs with no allocation and no collector

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `callconv-test.ss`: "an interrupt handler saves every register it writes, including caller-saved ones" | handler writing a caller-saved register | prologue saves it, epilogue restores it | ordinary conventions save neither; D171 records that all v registers are caller-saved |
| `callconv-test.ss`: "an interrupt handler returns with the interrupt-return instruction" | handler on each target | `iret`/`sret` rather than `ret` | |
| `escape-test.ss`: "an interrupt handler is allocation-free by construction" | handler that conses | refused at compile time | reuses CUJ-05's machinery rather than a second mechanism |

**Done when:** the tests above pass. All must be red when created.

**Depends on:** CUJ-05

**Beads:** scheme-benchmarking-w7q

---

## CUJ-07: Kernel author boots an image on bare metal

**Actor:** kernel author
**Trigger:** wants to run the OS on hardware or an emulator with no Linux beneath it
**Journey:**
1. Kernel author compiles for the freestanding target
2. System emits an image with no syscalls and no assumption that memory was provided
3. Image boots under an emulator on both ISAs and produces observable output

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `elfexec-test.ss`: "a freestanding image contains no syscall instruction" | any program, freestanding target | zero `syscall`/`ecall` in the emitted image | REPL: the runtime issues `write` and `exit` directly today |
| `gc-test.ss`: "the collector takes its memory from a supplied region rather than assuming one" | collector initialised over a fixed region | allocation succeeds within it and fails past its end | the collector assumes memory exists |
| `run-x86-64-test.ss`: "a freestanding image boots under an emulator and produces its output" | smoke program, both ISAs | expected output, no host OS involved | the RISC-V gate already boots emitted code |
| `elfexec-test.ss`: "the hosted target is byte-identical to before" | existing benchmark programs | same image as the current build | the hosted runtime must keep working; D182 used image equality this way |

**Done when:** the tests above pass. All must be red when created.

**Beads:** scheme-benchmarking-4qp

---

## CUJ-08: Compiler maintainer sees the correctness evidence survive every addition

**Actor:** compiler maintainer
**Trigger:** any change from CUJ-01 through CUJ-07 lands
**Journey:**
1. Maintainer runs the suite and both differential gates
2. System reports the same answers as before on every existing program
3. Maintainer sees new features exercised on both targets, not one

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `differential-test.ss`: "every new primitive is exercised on both x86-64 and RV64" | the primitive inventory | no primitive is tested on only one target | D132 and D160: features silently did nothing on RV64 for entries at a time |
| `run-x86-64-test.ss`: "the eleven-way bit-exact agreement holds after each addition" | the existing oracle programs | unchanged bit-for-bit | spec.md names this as the load-bearing constraint |
| `prims-test.ss`: "the primitive inventory is generated from the compiler, not maintained by hand" | `prim-names` plus the runtime routines | the documented surface equals the compiler's | REPL: three greps disagreed with each other and with the compiler |

**Done when:** the tests above pass. All must be red when created.

**Beads:** scheme-benchmarking-pcn

---

## CUJ-09: Compiler maintainer measures performance on a workload that resembles an OS

**Actor:** compiler maintainer
**Trigger:** wants to know whether a change helps the code this compiler exists to compile
**Journey:**
1. Maintainer runs a benchmark that allocates, builds strings and stresses the collector
2. System reports throughput and, separately, worst-case collector pause
3. Maintainer compares against C on the same workload

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `bench/`: an allocation-heavy workload with a C reference | a program whose working set exceeds the nursery | both arms agree on the answer; ratio reported with a CI | every existing conclusion comes from two allocation-free numeric kernels |
| `gc-test.ss`: "worst-case pause is measured and reported, not just mean throughput" | collection under a full nursery | maximum pause recorded per run | a kernel cares about the tail, not the mean |
| `bench/`: a string and symbol workload with a C reference | text processing sized past cache | answers agree, ratio reported | nbody and fannkuch touch neither |

**Done when:** the tests above pass. All must be red when created.

**Beads:** scheme-benchmarking-nw4

---

## CUJ-10: Editor user reads SonicScheme with its annotations visible

**Actor:** editor user
**Trigger:** opens a `.sps` file in Emacs or VSCode
**Journey:**
1. Editor user opens a file using `declare`, `policy`, `declare-distinct`
2. Editor highlights those distinctly from ordinary identifiers and from standard Scheme forms
3. Editor indents the forms the way the codebase already writes them

**Tests to create:**

| Test | Input | Assertion | Informed by |
| --- | --- | --- | --- |
| `editor/emacs`: "the annotation forms are fontified as keywords, not as calls" | a file using all three | each is keyword-faced | these change what the compiler is permitted to do; as plain identifiers they are invisible |
| `editor/vscode`: "the same file tokenises identically under the VSCode grammar" | the same file | the same spans classified the same way | two grammars drifting apart is the usual failure |
| `editor/emacs`: "a check-suppression control is visually distinct from a check name" | `[bounds-check unchecked]` | suppression is distinguishable at a glance | D5 made suppression an explicit permission; it should look like one |

**Done when:** the tests above pass. All must be red when created.

**Beads:** scheme-benchmarking-iw8

---

## Carried forward from `docs/LEDGER.md`

Two items closed earlier under a benchmarking reading of the project. Neither is dead; both are
re-scoped by the OS goal and neither has a CUJ yet.

- **RV64 packed arithmetic** — everything below the pass is built and tested; blocked on slp's cost
  model assuming a scalar can read lane 0 of a pack for free, which is true of xmm and false of RVV
  (D183). Whether an OS needs packed arithmetic at all is a question for the OS.
- **The rsqrt accuracy trade** — declined, correctly: it buys ~1.5% and costs the bit-exact oracle
  that spec.md names as load-bearing. It stays declined unless the oracle is retired.
