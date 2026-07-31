---
type: technique
title: A-normal form
description: Normalize the source so every operand is a value and every non-tail call is let-bound, which is provably what a CPS compiler's back end sees after administrative simplification, reached in one pass instead of three.
tags: [a-normal-form, intermediate-representation, continuation-passing-style, tail-calls, normalization]
sources:
  - resource: /works/flanagan-sabry-duba-felleisen-the-essence-of-compiling-wit.md
  - resource: /works/steele-rabbit-a-compiler-for-scheme-1978.md
  - resource: /works/steele-lambda-the-ultimate-declarative-1976.md
  - resource: /works/shivers-control-flow-analysis-of-higher-order-languages-19.md
  - resource: /works/serrano-weis-bigloo-a-portable-and-optimizing-compiler-for.md
  - resource: /works/appel-ssa-is-functional-programming-1998.md
  - resource: /works/hieb-dybvig-bruggeman-representing-control-in-the-presence.md
  - resource: /works/waddell-dybvig-fast-and-effective-procedure-inlining-sas-1.md
implemented_by: []
absent_from: []
pipeline_stage: 03-parse
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

A CPS compiler runs three phases to get to code: CPS-convert, simplify the administrative
redexes that conversion introduced, then generate code with a back end that knows about
continuations. The question A-normal form answers is whether the first two phases are doing
any work the third can see. They are not, and the proof is machine-level rather than
aesthetic. So: how do you reach the same IR the CPS back end actually consumes, in one
source-to-source pass, keeping a term small and readable enough to inspect between nanopass
stages.

# Mechanism

Source is Core Scheme: values (constants, variables, lambdas) plus `let`, `if0`, application
and primop application, with the CEK machine as semantics. Normalization is three rewrites
over evaluation contexts

```
E ::= [] | (let (x E) M) | (if0 E M M) | (F V ... V E M ... M)     where F = V or F = O

(A1)  E[(let (x M) N)]     -> (let (x M) E[N])           E != [], x not free in E
(A2)  E[(if0 V M1 M2)]     -> (if0 V E[M1] E[M2])        E != []
(A3)  E[(F V1 ... Vn)]     -> (let (t (F V1 ... Vn)) E[t])
      where E != [], E is not E'[(let (z []) M)], t not free in E
```

A1 and A2 merge code blocks across declarations and conditionals. A3 lifts a redex out of its
evaluation context and names the intermediate result. The system is strongly normalizing, so
"the" A-normal form is whatever any strategy run to a normal form produces. The grammar that
results:

```
M ::= V | (let (x V) M) | (if0 V M M) | (V V1 ... Vn)
    | (let (x (V V1 ... Vn)) M) | (O V1 ... Vn) | (let (x (O V1 ... Vn)) M)
V ::= c | x | (lambda (x1 ... xn) M)
```

Every operand is a value. Every non-tail call is bound by a `let`. The difference between a
tail call and a non-tail call is syntactically apparent. That is the same shape as the
beta-normal CPS grammar with the continuation variable `k` erased, which is the whole point.

**Why the erasure is sound.** Take the abstract machine a realistic CPS back end implements.
Return sites carry a continuation variable the machine never reads, because a return uses the
dedicated continuation register. Calls pass a continuation parameter the callee never binds,
because the caller's continuation is already in that register. Formally, the C_cps-EK machine
(continuation closures tagged as activation records, continuation in its own environment
component) and the C_a-EK machine (CEK specialized to A-normal forms) have transition
functions identical modulo the syntax of control strings, with a bijection between their
states that commutes with the transitions. Theorems 5.1 and 5.3.

**The normalizer.** The appendix gives a linear-time algorithm, written in CPS in the
Danvy-Filinski style, with `normalize`, `normalize-name` and `normalize-name*`. The one that
matters is `normalize-name`: normalize a subterm, and if the result is not a value, bind it to
a fresh `t` and hand `t` to the continuation. The conditional case calls `normalize-name` on
the test but `normalize-term`, a fresh top-level normalization, on both branches. That is what
prevents the exponential blowup you get from duplicating the enclosing evaluation context into
both arms. The naive CPS transformation carries the identical hazard from duplicating `k`, and
RABBIT and `CPC-IF` both dodge it by naming the join continuation once.

**Optimizations transfer.** Every CPS optimization expressible as a sequence of beta and eta
reductions has an ANF counterpart. The worked example is tail-call recognition: the CPS eta
step turning `(W (lambda (x) (k x)) W1 ... Wn)` into `(W k W1 ... Wn)` is, in ANF,

```
(let (x (V V1 ... Vn)) x)  ->  (V V1 ... Vn)
```

**The partial-evaluation benefit is real and cheap.** A1 exposes `(add1 (let (x (f 5)) 0))` as
`(let (x (f 5)) (add1 0))`, which then folds. Direct compilers do these reductions ad hoc and
incompletely. Making the phase complete is the actual deliverable, and it is a stronger reason
to normalize than the pass-count argument.

# Preconditions

Light. Variables must be uniquely renamed for A1's side condition. Assignment and control
operators are orthogonal to the analysis, since the argument concerns the CPS compilation
strategy rather than the language's effects. Static or dynamic typing is irrelevant.

Two hard requirements on the implementation. Use the appendix algorithm and keep the
conditional case's context avoidance, or the IR grows exponentially on nested `if`. And
**renormalize after inlining**: ANF is not closed under the beta reductions inlining performs,
because substituting a `let`-bound call into a nested position produces a term that is no
longer in normal form. Waddell and Dybvig's `cp0` performs exactly those substitutions, so the
renormalization is not hypothetical.

One documentation hazard. The camera-ready PDF in this bundle has poor font encoding, with
many characters rendering as `/` followed by a digit, so the grammar and formulas in the work
document were reconstructed from context. The prose is unambiguous; check the figures against
the PDF before transcribing them into a pass.

# Cost

One normalization pass replaces conversion plus administrative simplification. Term size stays
linear in the source; the blowup cases are the conditional context duplication, which the
algorithm avoids, and the renormalization after inlining, which is a recurring cost
proportional to how much got inlined.

The measured result is weak and the authors say so. A-normalizing the intermediate language of
the *non-optimizing* CAML Light compiler and rewriting the bytecode interpreter as a C_a-EK
machine gave 50 to 100 percent speedups on a dozen small benchmarks, with the explicit caveat
that the gains would be smaller in an optimizing compiler. That number measures interpreter
dispatch, not compiled-code quality. The real claim of the paper is the machine equivalence,
and the equivalence is what should be cited, not the 50 to 100 percent.

The precision given up is analysis structure rather than code quality: see below.

# Disagreements

**Against full CPS.** The paper's own position is that a direct compiler on ANF can use the
same code-generation techniques as a CPS compiler and produce the same code, having done less
work to get there. The CPS camp's surviving counter is the closure property. CPS is closed
under its beta rule; ANF is not, so inlining forces renormalization. The paper does not
discuss this and it is the main practical argument the CPS side has kept.

**Against CPS for analyses, which is a different question.** Section 6 claims only that
beta-eta-expressible optimizations transfer. Shivers' CFA exploits the CPS partition of
procedures into user procedures and continuations, and that structure is not free in ANF. The
abstract's claim that "fully developed CPS compilers do not need to employ the CPS
transformation" is supported for the back end by one theorem about one pair of machines with
one specific set of back-end optimizations (the continuation-variable hack, activation-record
tagging). It does not show that every CPS-based analysis has an ANF counterpart.

**Against normalizing at all.** Serrano's Bigloo is direct style and explicitly so, arguing
that CPS makes control artificially dynamic and that 0CFA on direct style recovers what CPS
threw away. ANF sits between: it commits evaluation order and names temporaries like CPS, but
keeps returns implicit like direct style. Nobody in the bundle argues that direct style
without normalization is better for a compiler that wants abstract domains, and the reason is
A1 and A2, below.

**Priority, and an agreement worth naming.** Footnote 1 credits the observation that direct
compilers already do these reductions ad hoc to personal communication from Boehm, Dybvig and
Hieb in April 1992. So the Indiana line knew this before it was published, which is consistent
with Chez being a direct-style compiler that never adopted CPS.

**The SSA connection.** Appel's dictionary, crediting Kelsey 1995, makes a basic block a
function, an in-edge a tail call and a phi node a formal parameter. A `let`-bound application
in ANF is a definition point; "definition dominates every use" is lexical scope. That reduces
part of the CPS-against-ANF-against-SSA argument to which redundancies a given pass has to
skip over.

# For us

This settles the `03-parse` core language question in favour of ANF, with a proof rather than
a preference, and the ANF grammar above is close to the right core language after macro
expansion.

**A1 and A2 are what make the numeric domains see anything, and that decides pass order.**
Facts established inside a `let` body are in scope for the continuation of the whole
expression only after A1 hoists the binding out. A conditional's branches only get separate
abstract states after A2 pushes the context into both arms. So A-normalize *before*
`05-intervals`, not after. This is the strongest argument in the bundle for putting
normalization early rather than treating it as cosmetic.

The syntactic tail-call versus non-tail-call distinction is exactly what `08-represent` and the
stack-segment machinery need. A non-tail call is a `let` whose right-hand side is an
application, and that is where a frame is pushed and where an overflow check may be required.
Hieb, Dybvig and Bruggeman's check-elimination rules key off precisely this distinction, so
ANF hands `13-assemble` its input for free.

Two caveats to carry into design. Budget renormalization after `cp0`-style inlining. And use
the appendix's algorithm rather than a naive one, keeping the conditional case's context
avoidance, or the IR grows exponentially on nested `if`.
