---
type: paper
title: "The Essence of Compiling with Continuations"
description: Proves that a CPS compiler's three phases (CPS conversion, administrative-redex simplification, and continuation-aware code generation) compose into a source-to-source transformation into A-normal form, so a direct compiler on ANF emits identical code in fewer passes.
resource: knowledge/sources/flanagan-sabry-duba-felleisen-the-essence-of-compiling-wit.pdf
tags: [a-normal-form, continuation-passing-style, intermediate-representation, abstract-machine, scheme]
authors: [Cormac Flanagan, Amr Sabry, Bruce F. Duba, Matthias Felleisen]
year: 1993
venue: "PLDI 1993"
informs: [/techniques/a-normal-form.md, /techniques/closure-conversion.md, /techniques/procedure-inlining.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

The argument is machine-level, not aesthetic. Take the abstract machine that a realistic CPS
compiler's back end actually implements, and the CPS-specific structure in the control string
turns out to be information the machine ignores. Return sites carry a continuation variable
`k` that the machine never reads, because a return uses the dedicated continuation register.
Calls pass a continuation parameter that the callee never binds, because the caller's
continuation is already in that register. Deleting the redundancy is exactly an inverse CPS
transformation. Therefore CPS-convert, beta-simplify, then generate code equals one
source-level normalization: A-normalization.

Formally: the C_cps-EK machine (realistic CPS back end, with continuation closures tagged as
activation records and the continuation held in its own environment component) and the C_a-EK
machine (CEK specialized to A-normal forms) have transition functions that are identical
modulo the syntax of control strings, and there is a bijection between their states that
commutes with the transitions. Two theorems, 5.1 and 5.3.

The point is not that ANF is prettier. It is that a direct compiler on ANF can use the *same*
code-generation techniques as a CPS compiler and produce the *same* code, having done less
work to get there.

# Mechanism

Source language is Core Scheme: values (constants, variables, lambdas) plus `let`, `if0`,
application, and primop application. Semantics is the CEK machine.

The A-reductions, over evaluation contexts

    E ::= [] | (let (x E) M) | (if0 E M M) | (F V ... V E M ... M)   where F = V or F = O

are three rules:

    (A1)  E[(let (x M) N)]      -> (let (x M) E[N])            E != [], x not free in E
    (A2)  E[(if0 V M1 M2)]      -> (if0 V E[M1] E[M2])         E != []
    (A3)  E[(F V1 ... Vn)]      -> (let (t (F V1 ... Vn)) E[t])
          where E != [], E is not E'[(let (z []) M)], t not free in E

A1 and A2 merge code blocks across declarations and conditionals. A3 lifts redexes out of
evaluation contexts and names intermediate results. The system is strongly normalizing, so
"the" A-normalization is any strategy run to a normal form. The resulting grammar:

    M ::= V | (let (x V) M) | (if0 V M M) | (V V1 ... Vn)
        | (let (x (V V1 ... Vn)) M) | (O V1 ... Vn) | (let (x (O V1 ... Vn)) M)
    V ::= c | x | (lambda (x1 ... xn) M)

Every operand is a value; every non-tail call is bound by a `let`; the difference between
tail call and non-tail call is syntactically apparent. This is the same shape as the
beta-normal CPS grammar with `k` erased, which is the whole point.

The appendix gives a linear-time normalizer, written in CPS in the Danvy-Filinski style, with
`normalize`, `normalize-name` and `normalize-name*`. `normalize-name` is the one that matters:
it normalizes a subterm and, if the result is not a value, binds it to a fresh `t` and hands
`t` to the continuation. The conditional case calls `normalize-name` on the test and
`normalize-term` (a fresh top-level normalization) on both branches, which is precisely what
prevents the exponential blowup you get from duplicating the enclosing evaluation context
into both arms. The naive CPS transformation has the same hazard, from duplicating `k` in the
conditional case.

Optimizations transfer. Every CPS optimization expressible as a sequence of beta and eta
reductions has an ANF counterpart. The example given is tail-call recognition: the CPS eta
step turning `(W (lambda (x) (k x)) W1 ... Wn)` into `(W k W1 ... Wn)` is, in ANF,

    (let (x (V V1 ... Vn)) x)  ->  (V V1 ... Vn)

# Applicability

Preconditions are light. Variables must be uniquely renamed for the A1 side condition to
hold; the front end does that anyway. Assignments and even control operators are stated as
orthogonal to the analysis, since the argument concerns the CPS compilation strategy rather
than the language's effects. Static or dynamic typing is irrelevant.

Where it does not settle the question: ANF is not closed under the beta reductions that
inlining performs. Substituting a `let`-bound call into a nested position produces a term
that is no longer in normal form, so an ANF compiler must renormalize after inlining. CPS is
closed under its beta rule. The paper does not discuss this and it is the main practical
argument the CPS camp has kept.

The measured result is a weak one and the authors say so: A-normalizing the intermediate
language of the non-optimizing CAML Light compiler and rewriting the bytecode interpreter as
a C_a-EK machine gave 50 to 100 percent speedups on a dozen small benchmarks, with the
explicit caveat that the gains would be smaller in an optimizing compiler. That number
measures interpreter dispatch, not compiled-code quality.

The partial-evaluation benefit is real and cheap: A1 exposes `(add1 (let (x (f 5)) 0))` as
`(let (x (f 5)) (add1 0))`, which then folds. Direct compilers do these reductions ad hoc and
incompletely; making the phase complete is the actual deliverable.

# Relevance

This settles our core language question in favor of ANF, and it settles it with a proof rather
than a preference. We get the CPS back end's code quality without CPS's term-size blowup and
without the administrative-redex cleanup pass, and the IR stays readable, which matters for a
nanopass pipeline where every intermediate form is inspected.

Concretely, the ANF grammar above is close to the right core language for stages after macro
expansion. The syntactic tail-call/non-tail-call distinction is what `08-represent` and the
stack-segment continuation machinery need: a non-tail call is exactly a `let` whose right-hand
side is an application, and that is where a frame is pushed. Hieb, Dybvig and Bruggeman's
stack model wants precisely this distinction to decide which calls need an overflow check.

The commuting-conversions A1 and A2 are also what makes the numeric domains see anything.
Facts established in a `let` body are in scope for the continuation of the whole expression
only after A1 hoists the binding out, and a conditional's branches only get separate abstract
states after A2 pushes the context into both arms. Do the A-normalization before
`05-intervals`, not after.

Two caveats to carry into design. First, renormalize after inlining; budget for it in
`cp0`-style inlining. Second, use the appendix's algorithm rather than a naive one, and keep
the conditional case's context-avoidance, or the IR grows exponentially on nested `if`.

# Notes

Title, authors and venue verified against page 1: Flanagan, Sabry, Duba and Felleisen, Rice
University, "To appear in: 1993 Conference on Programming Language Design and Implementation,
June 21-25 1993, Albuquerque". The bibliography entry ("A-normal form. Why you may not need
full CPS") is accurate. This copy is the camera-ready preprint, not the ACM proceedings
pagination; it prints "Page 1" through "Page 11" rather than proceedings page numbers.

The text extraction of this PDF is poor: the font encoding renders many characters as `/`
followed by a digit, so quoted grammar and formulas in this document were reconstructed from
context. The prose is unambiguous; the figures require care.

Footnote 1 credits the observation that direct compilers already do these reductions ad hoc
to personal communication from Boehm, Dybvig and Hieb in April 1992. So the Indiana line knew
this before it was published, which is consistent with Chez's design.

Where the paper oversells: the abstract says "fully developed CPS compilers do not need to
employ the CPS transformation," and the machine-equivalence theorem does support that for the
back end. But the theorem is about one specific pair of machines with one specific set of
back-end optimizations (the continuation-variable hack, activation-record tagging). It does
not show that every CPS-based analysis has an ANF counterpart, and Section 6 only claims the
beta-eta-expressible ones transfer. Shivers' CFA, for one, exploits the CPS partition of
procedures into user procedures and continuations for its own purposes; that structure is not
free in ANF.
