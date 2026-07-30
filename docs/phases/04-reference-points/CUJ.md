# Phase 4 CUJ: Reference Points

Technical implementation document. The journey is an operator measuring three things
that each attack a different assumption the project rests on.

Companion to `PLAN.md` in this directory.

## Journey summary

The operator builds nbody in Ada three times with different check suppression, to find
out whether the design decision in `../../PROPOSAL.md` section 2b is worth anything.
Then runs the existing Common Lisp source under ECL and CLISP to separate "Common Lisp
is fast" from "SBCL is fast." Then, optionally, ports nbody to a 2006 R4RS compiler to
see how high inference reaches. The phase ends with a verdict on the design decision.

## Preconditions

Phase 3 complete. These are reference points for a result that already exists, so
running them before phase 3 risks wasted effort if phase 3 kills the project.

## Part A: Ada, configuration 8

The one that tests a decision we already made. Highest value here, so it runs first.

### The three builds

Identical source, three check configurations, `-O` held constant so check suppression
is the only variable.

```ada
--  Build 1: all checks on. The Ada default.
--  no pragma

--  Build 2: named suppression, the checks a numeric kernel can safely drop
pragma Suppress (Index_Check);
pragma Suppress (Range_Check);
pragma Suppress (Overflow_Check);

--  Build 3: everything
pragma Suppress (All_Checks);
```

Placement matters and is part of what we are measuring. Ada allows these in a
declarative part, a package specification, or as a configuration pragma. Put them in the
declarative part of the compute unit rather than globally, because scoped suppression is
precisely the property `../../PROPOSAL.md` claims is better than CL's global dial. Then
verify that scoping actually works by confirming build 2 differs from build 1.

### Structure

```ada
with Ada.Real_Time;
with Ada.Text_IO;

procedure NBody is
   type Real is new Long_Float;             --  IEEE binary64
   type Body_Index is range 1 .. 5;
   type Vector3 is array (1 .. 3) of Real;

   --  arrays of Real are naturally unboxed, no annotation needed
   Positions  : array (Body_Index) of Vector3;
   Velocities : array (Body_Index) of Vector3;
   Masses     : array (Body_Index) of Real;

   procedure Advance (Dt : Real) is
      pragma Suppress (Index_Check);        --  build 2 scoping
   begin
      ...
   end Advance;
begin
   ...
end NBody;
```

Note what Ada gives for free that the Scheme variants had to work for: an array of a
float type is unboxed by definition, with no declaration required. Ada never had a
boxing problem, so configuration 8 measures check elision alone, not check elision plus
unboxing. State that when comparing against configuration 2, or the comparison will be
read as stronger than it is.

### Build

```
gnatmake -O2 -gnatp nbody.adb        # -gnatp suppresses all checks, compiler-wide
gnatmake -O2 nbody.adb               # checks per the pragmas in source
```

Use source pragmas rather than `-gnatp` for builds 1 and 2, so the measurement reflects
the standardized mechanism rather than a GNAT flag. Build 3 can use either; if they
differ, that is itself worth recording.

### What the three numbers mean

| comparison | question |
|---|---|
| build 1 to build 2 | what named suppression of the safe checks buys |
| build 2 to build 3 | whether granularity costs performance |
| build 3 to config 6 scalar | does Ada with checks off reach scalar C |

The second row is the interesting one and the reason for three builds rather than two.
If build 2 and build 3 are indistinguishable, named suppression costs nothing relative
to the blunt instrument, and `../../PROPOSAL.md` section 2b is vindicated: you can have
granularity for free. If build 3 is meaningfully faster than build 2, then granularity
has a price, and CL's cruder dial has a real argument behind it that the proposal
currently dismisses.

### Verdict to record

A written answer to: does per-check suppression approach scalar C, and does granularity
cost anything? If Ada with checks suppressed stays well off scalar C, per-check
suppression buys less than the Ada manual implies and section 2b needs rewriting.

## Part B: ECL and CLISP, configuration 9

Cheapest item in the matrix. Run configuration 5's source unchanged.

```
ecl --load nbody-sbcl.lisp --eval '(main)'
clisp -c nbody-sbcl.lisp && clisp -x '(load "nbody-sbcl.fas") (main)'
```

Exact invocations need working out and recording, since neither implementation has
SBCL's script conventions. Compile ahead of time in both, per phase 1's recipes, and
apply the recompilation trap test.

The source must not change. That is the entire experiment: identical declarations,
identical `(optimize (speed 3) (safety 0))`, three implementations.

Expected: SBCL fast, ECL middling, CLISP slow, because CLISP largely ignores
declarations. If that holds, then "Common Lisp is fast" is really "SBCL is fast," and
what ANSI CL supplied was portable notation rather than guaranteed performance. That
sharpens `../../PLAN.md` section 1 rather than undermining it, because the thesis is
about the standard making the fast path *reachable*, not about it being mandatory.

One thing to watch: ECL compiles through C, so its result partly reflects the C
compiler. Note that when reporting, and do not read ECL as a pure measure of how well
its own type inference works.

## Part C: Stalin, configuration 7, optional

Highest effort, lowest marginal information, because `RESEARCH.md` section 3 already
extracted Stalin's profile from the existing corpus. Runs last. Drop it if it fights.

### Install

```
sudo apt-get install --no-install-recommends stalin
```

### The porting problem

Stalin 0.11 targets full R4RS with minor omissions and dates from October 2006. It
predates R7RS by seven years. In the existing corpus it failed 23 of 57 benchmarks on
language coverage, including `sumfp` and `fibfp`, so expect friction.

What has to change from configuration 1:

- No R7RS library form. No `import`. Use a flat program.
- No `define-record-type`. Use vectors or closures.
- No bytevectors, no `f64vector`, no SRFI anything.
- `exact->inexact` rather than `exact` and `inexact`.
- Check whether `current-jiffy` exists; if not, drop internal timing here and rely on
  process timing plus the slope method.

The port is essentially configuration 1 rewritten in R4RS. Keep the arithmetic
expression order identical so output still matches the fixture.

### Build

```
stalin -On -copt -O3 nbody-stalin.scm
```

Stalin emits C and invokes the C compiler. Expect a long compile: the whole-program
analysis is the reason it is fast and the reason it is slow to build. Record the compile
time, because it is a real cost of the technique and belongs in the write-up.

### What it tells us

If Stalin beats every declaration-based configuration by a wide margin on this program,
then inference reaches higher than declarations here, and the project is aimed at a
less interesting target than we thought. The existing corpus predicts Stalin will win
this one, since nbody is float and array code, which is exactly the regime where its
representation selection succeeds. That prediction being confirmed is not a problem for
the proposal: `RESEARCH.md` section 3 argues for declarations on predictability rather
than on achievable speed, and one program where inference wins does not touch that
argument.

What would be a problem is Stalin winning *and* being predictable. Watch for it.

## Verification

Same as phase 3. Every variant's output matches the fixture before any timing is
trusted. The Ada builds must all three produce identical output, which is also a check
that suppressing a check did not silently change behavior.

## Artifacts produced

```
bench/programs/nbody/08-ada.adb           three build configurations
bench/programs/nbody/07-stalin.scm        optional, R4RS port
results/<config>-<N>.json
docs/phases/04-reference-points/RESULTS.md
```

## Exit gates

- Ada measured at all three check levels, with a written verdict on
  `../../PROPOSAL.md` section 2b.
- ECL and CLISP measured, with a written verdict on the "Common Lisp or SBCL" question.
- Stalin measured, or explicitly dropped with the reason recorded.
- All variants match the output fixture.

## Task decomposition notes

Part A, part B, and part C are fully independent and can be worked in any order or in
parallel. Part A is the critical path for the design decision and should be scheduled
first regardless of effort. Part B is a few hours at most. Part C is open-ended and
should be timeboxed, with dropping it treated as an acceptable outcome rather than a
failure. The Ada three-build comparison is one unit: a single build in isolation
answers nothing.
