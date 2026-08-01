---
type: technique
title: Closure conversion
description: Turn lexically scoped lambdas into explicit data by assigning lexical addresses, boxing assigned variables, and selecting a per-lambda representation, so most lambdas need no runtime object at all.
tags: [closure-conversion, lexical-addressing, assignment-conversion, flat-closures, escape-analysis, representation-selection]
sources:
  - resource: /works/steele-rabbit-a-compiler-for-scheme-1978.md
  - resource: /works/dybvig-three-implementation-models-for-scheme-1987.md
  - resource: /works/keep-hearn-dybvig-optimizing-closures-in-o-0-time.md
  - resource: /works/keep-a-nanopass-framework-for-commercial-compiler-developm.md
  - resource: /works/serrano-cfa-closure-allocation-sac-1995.md
  - resource: /works/dybvig-et-al-the-development-of-chez-scheme-icfp-2006.md
  - resource: /works/steele-lambda-the-ultimate-declarative-1976.md
  - resource: /works/steele-sussman-lambda-the-ultimate-imperative-1976.md
  - resource: /works/sussman-steele-scheme-an-interpreter-for-extended-lambda-c.md
  - resource: /works/abelson-sussman-sicp.md
  - resource: /works/ghuloum-an-incremental-approach-to-compiler-construction-2.md
  - resource: /works/flanagan-sabry-duba-felleisen-the-essence-of-compiling-wit.md
  - resource: /works/hieb-dybvig-bruggeman-representing-control-in-the-presence.md
  - resource: /works/waddell-dybvig-fast-and-effective-procedure-inlining-sas-1.md
  - resource: /works/george-appel-iterated-register-coalescing-toplas-1996.md
implemented_by: [/implementations/chez.md]
absent_from: []
pipeline_stage: 08-represent
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

A lambda can outlive the frame that created it, so its free variables must survive that
frame. The naive answer is a heap environment chain, which Sussman and Steele 1975 built and
then diagnosed: lookup walks the chain, so cost scales with lexical distance, and the upward
funarg problem forces the environment to be a tree rather than a stack. Dybvig's profiling of
C-Scheme put over half of run time in variable lookup and function call. The real question is
therefore not how to represent an environment. It is which lambdas need a runtime object at
all, and what is the cheapest shape for the ones that do.

# Mechanism

**Lexical addressing.** Thread a compile-time environment through the walk. SICP 5.5.6
resolves each reference to `(frame-number displacement)`. Dybvig collapses it further: once
free values are copied into the closure, the compile-time environment is one pair
`(locals . free)`, so a reference is `refer-local n` off the frame pointer or `refer-free n`
off the closure register. One instruction, against `m+n+2` memory references for a rib-cage
lookup at depth `(m,n)`. `find-free` computes free sets by structural recursion carrying the
bound set; `find-sets` records which formals are assigned.

**Assignment conversion.** A flat closure copies *values*, so an assigned variable can exist
at once in the live stack, several closures, and any captured continuation. Allocate one heap
cell per assigned variable and copy the pointer instead. Dybvig has the *callee* emit `box n`
on entry, since the caller cannot know which arguments the callee assigns; Ghuloum uses a
one-element vector. RABBIT arrives from the other side: CLOSE-ANALYZE's third set exists only
because of `ASET'`, forcing a mutated variable out of registers into the shared environment
before any closure is built. Only assigned variables pay, one indirect each.

**Representation selection**, in three generations of one table. RABBIT's BIND-ANALYZE gives
each lambda NIL (code pointer plus environment, when the function is treated as data),
EZCLOSE (environment consed, no code pointer), or NOCLOSE (no runtime object; the environment
is recoverable at the point of call). Serrano derives the same shape from a 0CFA call graph
inverted into `USE(f)`, the sites that can invoke `f`, yielding nested predicates
`S => X => T`: `S` never reaches a `funcall`, so no closure and no environment; `X` is the
unique callee everywhere, so no closure structure; `T` is a family always applied at the same
sites, so the closure shrinks to one entry-point slot with no tag, no arity field and no
variable-arity entry.

Keep, Hearn and Dybvig, and Keep's dissertation chapter 5 at length, key instead on two facts
a closure pass already has, whether the lambda is *well-known* (its value is used only where
it is provably the callee) and its free-variable count:

```
well-known,      0 fv -> delete the closure
well-known,      1 fv -> replace every use with the variable itself
well-known,      2 fv -> a pair, 2 words instead of 3
well-known,    >=3 fv -> a vector: same size, but a small length beats a full-word
                         code pointer, and vectors are legal to share
not well-known,  0 fv -> statically allocated constant closure
not well-known,>=1 fv -> a real closure. No win.
```

Six free-variable eliminations follow: variables left unreferenced by a deleted closure,
globals (address in the code stream), constants, aliases, **self-references**, and mutual
references in a strongly connected group whose only free variables are each other's names,
the closed `even?`/`odd?` case. Two sharing cases are safe: same lifetime with at most one
code pointer, approximated by SCCs of the free-variable graph in a `letrec`; and identical
free-variable sets with no code pointers, safe across unrelated bindings because the shared
closure retains no more than each original retained indirectly.

Algorithm, believed linear in total free-variable count with a `seen` flag per variable: mark
every letrec lambda optimistically well-known and demote on any reference outside
call-operator position; partition each `letrec` into SCCs, one nested `letrec` per component
in dependency order; choose sharing subsets; compute required free variables by an
outermost-to-innermost traversal carrying `rho : Var -> Exp + bottom`; select
representations; rebuild into `labels` plus explicit closure-pointer parameters and
`closure-ref`/`car`/`cdr`/`vector-ref`. Cycles within a component force
allocate-all-then-`closure-set!`-all.

# Preconditions

Lexical scoping, and the compiler owning the environment format outright. RABBIT rests on no
interpreted code, no separately compiled code and no debugger reaching into a compiled
environment; weaken that and BIND-ANALYZE and CLOSE-ANALYZE collapse to full closures. Unique
names from alpha-conversion. Internal defines scanned out, or frame layout is not statically
known (SICP 4.1.6). Assignment conversion and letrec purification first, so selection sees
only unassigned left-hand sides bound to lambdas. A call graph good enough for well-knownness;
Serrano additionally needs whole-module scope, since anything exported, imported or foreign
poisons its arguments and body at once. Globals sit outside the scheme: SICP falls back to a
runtime search because they can be redefined interactively, Chez wires a box into the code
stream instead.

# Cost

Access is one memory reference, unconditionally. Creation is `n+1` cells, so a flat closure is
*cheaper* than a heap environment pair at `n=0` and `n=1`, and `n=0` closures can be built at
compile or load time. Keep's closure pass moves compile time under one percent. Serrano's
0CFA costs 60.5s against 6.4s on `conform`, an 845 percent rise in Scheme-side compile time,
repaid only because Bigloo emits C and better C compiles faster.

**On the headline numbers, be careful.** The Keep/Hearn/Dybvig workshop PDF in this bundle is
a broken preprint: citations render `[? ]`, cross-references `Section ??`, and section 4
"Results" is three sentences ending "We hope to provide a full break down of these numbers in
a future version of this paper." Its 56.94 percent of closures and 58.25 percent of closure
allocation have nothing behind them *in that document*. The figures are supported elsewhere in
this bundle: Keep's dissertation Table 5.1 carries the per-optimization breakdown, and the
breakdown is the more useful result. Self-reference elimination alone accounts for 25.41
percent of free variables and 45.64 percent of memory references, while sharing accounts for
1.91 percent and borrowing 0.20 percent. Cite the dissertation, and note that the cheap
syntactic optimizations beat the clever ones by an order of magnitude. Serrano's 87 to 95
percent of closure allocations removed is measured against a baseline with no closure
optimization at all, which is not Chez, so that number does not transfer either.

The other cost is register pressure. George and Appel report SML/NJ *regressing* from three
to six callee-save registers until the allocator's copy propagation improved. If closure work
makes things slower, check coalescing quality before redesigning the closure.

# Disagreements

**Minimal capture is not always cheapest.** Steele argues against the rule in *Ultimate
Declarative*: six sibling closures over four variables cost twelve slots minimally against
four slots sharing one environment. The choice is a cost model, not a rule. Nobody in the
bundle defends unconditional minimal capture.

**Lambda lifting.** Serrano lifts free variables into the parameter list for `S` and treats it
as free. Keep, Hearn and Dybvig reject general lambda lifting outright: it trades one package
for `n` arguments and can raise register pressure and stack traffic, violating their
never-do-harm constraint. Both are right about their own target. Bigloo emits C and lets the C
compiler sort out registers; Chez owns its allocator and must not regress it.

**How much analysis to buy.** Serrano's thesis is that closure representation is the specific
optimization 0CFA had been missing and is worth its price. Chez's payback rule, that an
optimization must repay its analysis time out of the speedup it gives the compiler compiling
itself, fails 0CFA at 845 percent. Keep's single linear well-knownness pass is what survives
that rule, and Table 5.1 suggests it captures most of the value anyway.

**Where escape analysis lives.** Keep treats well-knownness on the call graph as the escape
analysis. Dybvig 4.7.4 states a stronger data-flow condition for stack-allocating a closure,
and 4.5 a condition for skipping a box (the variable occurs free in no closure *and* no
continuation can be captured in its scope). The second half needs k-CFA-style analysis, and
Chez mostly still uses the syntactic check.

Chain against flat is settled. Sussman and Steele 1975 and SICP use chains; RABBIT's flat
CDR-chained list still has an O(n) walk Steele lists as a weak spot; Dybvig and Cardelli
independently arrive at the flat vector of copied values, and that is what everyone uses now.

# For us

Stage `08-represent` for procedures, and where the storage-class table gains a closure row
rather than a separate mechanism: representation keyed on a proven property plus a count is
the same shape as storage class keyed on proven type plus escape.

Take Dybvig's four decisions directly. Display closures as a flat vector of copied values with
compile-time slot indices. Assignment conversion boxing only assigned variables, callee
creating the boxes. The `(locals . free)` compile-time environment. The frame layout with the
header below the arguments. Take the never-do-harm rule verbatim as a project constraint; an
optimization that sometimes regresses makes the cost model unteachable.

Pass ordering is load-bearing because of the cascade. Deleting a closure creates unreferenced
variables; replacing a one-fv closure with its variable creates aliases; sharing creates more.
So closure optimization either runs to a fixpoint with copy and constant propagation or is
scheduled after them and re-run, which is what Chez does. And since `cp0`-style inlining can
*add* free variables to closures when the call site is already inside the procedure's scope,
an interaction Waddell and Dybvig flag as unresolved, closure conversion runs after inlining.

One RABBIT fact belongs in the plan rather than a footnote. Its optimizer bought only **1.2x**
over unoptimized compiled code, 1.37x excluding GC, because the phase-2 closure analysis had
already eliminated most of the consing before the optimizer ran. Representation beat
optimization by a wide margin, which argues for spending stage 08's budget on the closure
decision rather than on more rewriting upstream.
