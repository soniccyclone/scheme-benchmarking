---
type: paper
title: "STABILIZER: Statistically Sound Performance Evaluation"
description: Re-randomizes code, stack and heap layout every 500ms during execution so that a single run averages over the layout distribution, which makes execution times Gaussian and licenses parametric tests such as ANOVA.
resource: knowledge/sources/curtsinger-berger-stabilizer-asplos-2013.pdf
tags: [measurement-bias, layout-randomization, benchmarking-methodology, central-limit-theorem, llvm]
authors: [Charlie Curtsinger, Emery D. Berger]
year: 2013
venue: "ASPLOS 2013, Houston TX"
informs: [/techniques/sound-performance-measurement.md, /techniques/generational-gc.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-08-05T00:00:00Z" }
---

# Contribution

The argument first, because the tool is downstream of it. Caches and branch predictors are
indexed by address. Adding a stack variable, reordering two heap allocations, or changing a
function's size shifts the placement of everything after it, and the resulting swing is
large: the authors measure a 57% performance change from link order alone, and cite
Mytkowicz et al. for 300% from environment variable size. So a compiled binary is **one
sample from the space of layouts**, and running it a thousand times gives a thousand
measurements of that one sample. Statistical tests applied to those runs are measuring
run-to-run noise while the dominant term sits constant in the background. Because a code
change alters layout too, the effect of an optimization is not separable from the effect of
its layout perturbation.

Stabilizer's fix is to make layout a random variable that is resampled *during* execution.
One run then averages over many layouts rather than sitting at one, which by the Central
Limit Theorem drives the distribution of total execution time to Gaussian regardless of what
the layout-effect distribution itself looks like. That is the part that matters: it converts
an unknown, possibly multi-modal population into one where the t-test and ANOVA are legal.

The applied result is a suite-wide ANOVA on SPEC CPU2006 finding that LLVM's `-O3` over
`-O2` is not distinguishable from noise.

# Mechanism

**Build path.** Every source file is compiled to LLVM bitcode (clang, or gcc/gfortran with
the dragonegg plugin), run through Stabilizer's `opt` pass, then compiled and linked against
`libstabilizer`. The driver `szc` accepts clang/gcc-compatible flags. The three
randomizations are independently switchable, which is how you evaluate a layout-targeting
optimization: disable the randomization your optimization targets and leave the others on.

**Heap.** A power-of-two size-segregated base allocator (optionally TLSF; originally DieHard,
which proved too slow because it never reuses recently freed memory and shreds the TLB) is
wrapped in a HeapLayers shuffling layer. Per size class there is an array of N pointers,
filled at startup by N `Base::malloc` calls and then Fisher-Yates shuffled. `malloc` takes a
fresh `p` from the base heap, picks random `i` in `[0,N)`, swaps `p` into `array[i]` and
returns what came out. `free` picks random `i`, swaps the freed pointer into `array[i]` and
frees what came out. Each call is one step of the inside-out Fisher-Yates shuffle. N = 256,
chosen as the smallest value at which the returned addresses pass the same six NIST SP800-22
tests that `lrand48` passes. Only the cache index bits need randomizing (bits 6 to 17 on
Core2): randomness below that misaligns allocations, above it pressures the TLB.

**Code, at function granularity.** Executable memory comes from a second randomized heap.
Each relocated function gets a relocation table written immediately after its body, holding
pointers to every global and function it references, addressed PC-relative. Two copies of the
same function do not share a table. Function extents are inferred from the address of the
next symbol because sizes are not read from the symbol table. Non-zero floating point
constants are promoted to globals in the IR so their accesses become indirect through the
table; `fptosi`/`fptoui`/`sitofp`/`uitofp` generate implicit global references that cannot be
rewritten, so they are replaced by calls to per-module conversion helpers, and those helpers
are the only code Stabilizer cannot relocate. `main` is renamed and the runtime supplies its
own, which initializes before running the program's constructors.

Relocation is lazy. Initialization writes an `int3` (0xCC) at each function entry with a
pointer to the function's runtime object just after it. The first call traps, and the SIGTRAP
handler copies the body to a random address, builds its relocation table alongside, overwrites
the original entry with a static jump to the copy, and marks it live.

**Re-randomization.** A 500ms timer re-traps every live function. The actual move happens on
the next trapped call, not in the signal handler, which is what keeps it out of non-reentrant
code. Reclamation is a conservative mark-sweep: old copies go on a "pile", the stack is
walked, anything with a return address on the stack is marked, and the rest is freed back to
the code heap. Copies still on the stack survive to a later cycle.

**Stack.** The pass gives each function a 256-byte stack pad table and a one-byte index. On
entry the function loads `table[index]`, increments the index, multiplies by 16 (x86-64 stack
alignment), moves the stack down by that much before its call and restores after, so padding
is 0 to 4080 bytes in 16-byte steps. The runtime refills every pad table with fresh random
bytes at each re-randomization. The index wraps, so a single function may reuse a pad within
a period, but the position of any frame is the sum of the pads of every frame below it, which
is what supplies the entropy.

**The statistical argument.** Within one execution, runtime is the sum over roughly `T/500ms`
i.i.d. random-layout intervals, so total time is the sample mean over layouts times a
constant. About 30 randomizations suffices for normality. Programs with phases decompose
recursively into subprograms that each reduce to the single-loop case, each normal, and sums
of normals are normal. Verified with Shapiro-Wilk across 18 SPEC benchmarks: without
re-randomization astar, cactusADM, gromacs, h264ref and perlbench are non-normal; with it
only cactusADM remains, and hmmer newly fails. Brown-Forsythe shows re-randomization
*reduces* variance significantly in eight benchmarks, by regression to the mean.

**x86-64 specifics.** Jump displacements are 32-bit, so relocation memory is requested with
`mmap MAP_32BIT`. Where that flag is unavailable (macOS) or low memory is exhausted, a 64-bit
jump is simulated by pushing the target and issuing `ret`, which is much slower, so high
addresses are a last resort. On x86 and PowerPC, data uses absolute addressing, so the
relocation table must sit at a fixed absolute address rather than adjacent to the function.

# Applicability

Overhead with everything enabled is a 6.7% median, under 40% for every benchmark, over 30%
for four. gobmk, gcc and perlbench pay for stack randomization because they have very many
functions and therefore very many 256-byte pad tables, which enlarges the working set;
cactusADM pays for power-of-two rounding on large arrays. The authors' defence of overhead is
correct and worth keeping: overhead shifts both arms of a comparison by the same amount, and
the t-test can resolve differences smaller than the overhead.

Preconditions. The program must have more than one function, or code randomization has
nothing to permute. It must allocate a decent population of short-lived heap objects, which
the authors tie to the generational hypothesis holding in unmanaged code. It must not use a
custom allocator or sub-allocate by hand out of one large array, since Stabilizer cannot see
inside either and cannot split a large allocation. The whole program must be buildable to
LLVM bitcode.

What it does not fix. Live heap objects are never moved, because C and C++ semantics forbid
it, so long-lived data structures keep whatever layout they were born with for the entire
run. Global and BSS placement is not in the randomization set at all (see the paper's own
Table 2, which has columns only for code, stack and heap). Branch predictor *history* is
untouched; basic-block-granularity relocation with branch-sense swapping is listed as future
work. C++ exceptions are unsupported, which cost the evaluation five SPEC C++ benchmarks, and
five Fortran benchmarks failed to build under gfortran plus dragonegg. Most importantly, the
normality claim is explicitly conditioned on "no other large sources of measurement bias":
Stabilizer removes the layout term and says nothing about frequency scaling, co-tenancy or
thermals.

# Relevance

Our planned CI design fans out across nodes and treats each node's full-suite run as an
independent sample. Section 7 of this paper is a direct rebuttal of the weaker version of
that idea. Randomizing the experimental setup (link order, environment size) is Mytkowicz's
proposal, and the authors argue it needs far more runs and does not eliminate the bias:
varying link order only moves inter-module placement, so a change in one function's size
still shifts every function after it, and varying environment size moves the stack base but
not the distance between frames. Per-node one-time randomization buys sampling but not
normality and not variance reduction, both of which come from re-randomizing *inside* a run.

The heap precondition is the one that bites us. Our benchmark programs are nbody,
fannkuchredux and spectralnorm, plus binarytrees. nbody holds one long-lived `flvector`;
binarytrees is a long-lived pointer structure. Under Stabilizer's C-shaped constraint those
layouts are fixed at birth and never resampled. Our runtime does not have that constraint: a
precise generational copying collector already relocates survivors, so a randomized survivor
placement mode is implementable in our GC in a way it is not in C. That is the version of
this paper's heap idea that we can actually have.

The stack randomization interacts badly with stage 10. Pads are multiples of 16 bytes, and
AVX-512 aligned moves want 64. Randomizing stack padding converts the alignment of
stack-resident vector data into a coin flip, and the authors themselves blame hmmer's loss of
normality on alignment-sensitive floating point. Section 2.5 gives the right answer: run with
code and heap randomization on and stack randomization off when the thing under measurement
is alignment-sensitive.

# Notes

**The paper's abstract overstates its own result.** The abstract says "-O2 has a significant
impact relative to -O1", but Section 6.1 reports F(1) = 3.235, p = 0.0898, and then states
plainly that -O2 is significant at 90% but not at 95%. Every other test in the paper uses
alpha = 0.05. By the paper's own threshold, -O2 over -O1 also fails to reach significance
across the suite. The -O3 result (F = 1.335, p = 0.264) is the one that survives as stated.
The per-benchmark t-tests do show -O2 significant for 17 of 18, but Section 6.1 opens by
explaining why those pairwise tests are unreliable (36 tests at alpha = 0.05 gives an
expected 1.8 false positives), so citing them to rescue the abstract would be
self-contradictory.

Three benchmarks got *slower* with -O2 (bzip2, libquantum, milc) and three with -O3 (bzip2,
gobmk, zeusmp), each significantly.

Stabilizer sometimes makes programs faster (astar, hmmer, mcf, namd, under code
randomization). The authors attribute it to eliminating branch aliasing and draw the right
conclusion: the default layout for those benchmarks is worse than the median layout. This is
also the seed of the deployment use case they mention and do not pursue.

Dating. The implementation is LLVM 3.1, gcc 4.6.3, dragonegg, Linux 3.5, evaluated on a Core
i3-550. The paper's own portability caveats are the `MAP_32BIT` dependency and the note that
branch predictor index bits "differ significantly across architectures", which is exactly the
parameter N = 256 was tuned against. The tool is stated to run on x86, x86-64 and PowerPC.
Nothing in the PDF says anything about the artifact's maintenance state after 2013; the URL
given is http://www.stabilizer-tool.org and this document does not fetch it.
