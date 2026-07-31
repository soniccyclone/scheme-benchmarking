# What Chez Already Does, and What It Actually Needs

Read from `cisco/ChezScheme` source at commit dated 2026-06-10. `s/cptypes.ss` is 2534
lines, `s/cptypes-lattice.ss` is 1547, `s/primdata.ss` holds the primitive signature
database.

The question: what does Chez need before a programmer can tell it what it needs to know?
The answer splits in two, and one half needs nothing at all.

---

## 1. What Chez already has

Four pieces, all present and working at `optimize-level 2`, which is the safe default.

### A type lattice

`cptypes-lattice.ss` defines roughly a hundred predicates with a subtype ordering,
`predicate-implies?`, `predicate-intersect`, `predicate-union`, and a bottom element. The
numeric part includes `fixnum`, `flonum`, `bignum`, `ratnum`, `exact-integer`, plus
narrower categories like `index`, `length`, `bit`, `u8`, `sub-index`, `pflonum`,
`nflonum`.

### Flow-sensitive narrowing from predicate tests

This is the important one. From the header comment of `cptypes.ss`:

```
(cptypes ir ctxt types) -> (values ir ret types t-types f-types)
  t-types: types to be used in case the expression is not #f, to be used in
           the "then" branch of an if.
  f-types: idem for the "else" branch.
```

So `cptypes` is a flow-sensitive pass that returns separate type environments for the two
branches of a conditional. `pred-env-add`, `pred-env-add/not` and `pred-env-add/ref`
(lines 499, 505, 644) record a predicate against a variable's `prelex` counter.

Concretely: inside the then-branch of `(if (flonum? x) A B)`, Chez knows `x` is a flonum.

### Automatic promotion to unsafe primitives

`fold-primref/try-unsafe`, line 1963. The mechanism:

```scheme
[to-unsafe (and (not unsafe)
                (all-set? (prim-mask safeongoodargs) (primref-flags pr)))]
...
(and to-unsafe (predicate-implies? r pred*))   ; per argument
...
(let ([pr (if to-unsafe (primref->unsafe-primref pr) pr)]) ...)
```

For each argument it intersects the inferred type with the primitive's declared argument
predicate. If every argument's inferred type *implies* the required predicate, the
primitive is replaced by its unsafe variant.

**This is automatic type-driven check elision, at the safe optimize level, already
shipping.** It is gated on the `safeongoodargs` flag, which 270 primitives carry.

### A primitive signature database

`primdata.ss` gives every primitive a type signature and flags:

```scheme
(fl+ [sig [(flonum ...) -> (flonum)]]
     [flags arith-op partial-folder safeongoodargs unboxed-arguments])
(flvector-length [sig [(flvector) -> (length)]]
     [flags pure mifoldable discard true safeongoodargs])
(flvector-ref [sig [(nonempty-flvector sub-index) -> (flonum)]]
     [flags mifoldable discard cp02])
```

Note `unboxed-arguments` on `fl+`. The representation-selection information is there too.

---

## 2. The arithmetic half: Chez needs nothing

`fl+` carries `safeongoodargs`. So if `cptypes` can prove both arguments are flonums, `fl+`
becomes its unsafe variant automatically. The same holds for the rest of the flonum
arithmetic.

And because narrowing already flows from predicate tests, **a programmer can inject the
fact today with a plain `if`.** No compiler change, no new form, nothing.

```scheme
(if (and (flonum? x) (flonum? y))
    (fl+ (fl* x x) (fl* y y))     ; every fl op here promotes to unsafe
    (error 'f "not flonums"))
```

A declaration form is then a five-line `syntax-rules` macro over that:

```scheme
(define-syntax declare-types
  (syntax-rules ()
    ((_ ((x pred) ...) body ...)
     (if (and (pred x) ...)
         (let () body ...)
         (error 'declare-types "type assertion failed")))))
```

One check per declared variable at scope entry, then unchecked inside. That is **sounder
than Common Lisp's `(safety 0)`**, which trusts the declaration and corrupts memory if you
lied. Here the boundary check is real and the interior is fast because the check proved the
fact.

So for arithmetic, unboxing, and the ~270 `safeongoodargs` primitives, the answer to "what
does Chez need" is: nothing. The machinery is complete and reachable from portable-looking
source.

### This is SRFI 253, and nobody appears to have noticed

`SRFI 253`'s `lambda-checked` attaches a predicate to each parameter and checks it on
entry. That is exactly the shape above. Its abstract says data validation makes for "faster
code too, sometimes," and that implementations "can turn these primitives into cheap and
strong type checks."

On Chez the effect is stronger than that hedge suggests. The check is not merely cheap, it
*unlocks unsafe promotion for every downstream operation in the body*. SRFI 253 may already
be a significant performance feature on Chez. Worth measuring in phase 3 and worth saying
out loud, because as far as this research found, nobody has.

---

## 3. The bounds-check half: a macro is not enough

`flvector-ref` deliberately lacks `safeongoodargs`, and the omission is correct.

Its signature is `[(nonempty-flvector sub-index) -> (flonum)]`. Proving both argument types
does **not** make the operation safe: knowing `i` is a `sub-index` says it is a non-negative
fixnum in the representable index range, not that it is less than *this vector's* length.
The fact needed is relational, `i < (flvector-length v)`, and no type predicate can express
it.

### The lattice has no ranges

Checked directly. From `cptypes-lattice.ss` lines 573 to 574:

```scheme
[(sub-fixnum sub-length pfixnum nfixnum sub-ufixnum sub-index) (cons 'bottom fixnum-pred)]
[(bit length ufixnum dfixnum index u8 s8 u8/s8) (cons 'fxzero-rec fixnum-pred)]
```

`index`, `length`, `sub-index`, `u8` and the rest are flat categories that collapse to
`fixnum-pred`. They are not intervals. There is no interval or relational reasoning
anywhere in the lattice.

And there is no comparison-driven narrowing: grepping `cptypes.ss` for `fx<` and `fx=`
turns up only the pass's own internal arithmetic over arities and sizes. No
`define-specialize` exists for `vector-ref` or `flvector-ref` at all. So writing
`(if (fx< i (flvector-length v)) (flvector-ref v i) ...)` by hand buys nothing. Chez does
not connect the comparison to the reference.

### So bounds elision needs one of

1. **Extend the lattice with intervals and relational facts.** Real compiler work, and it is
   the classic array-bounds-check-elimination problem.
2. **A user-facing way to assert the relational fact directly.** This is where SRFI 145
   `assume` would genuinely earn its keep, and Chez does not ship it.
3. **Use the unsafe primitives or `optimize-level 3`.** What everyone does today, and it
   discards safety globally rather than locally.

---

## 4. The real gap, placed in the abstract-domain hierarchy

Bounds check elimination is one of the most studied problems in compiler optimization, so
the answer does not need guessing or measuring. It needs placing both compilers on the
known hierarchy of numerical abstract domains, which dates to Cousot and Cousot's 1977
abstract interpretation framework.

| level | domain | expresses | can eliminate bounds checks? |
|---|---|---|---|
| 1 | finite type/category lattice | membership in a fixed set of categories | no, cannot represent an index range at all |
| 2 | Interval | `x ∈ [a,b]` | only when the array length is a compile-time constant |
| 3 | **Pentagon** (Logozzo & Fähndrich 2008) | `x ∈ [a,b] ∧ x < y` | **yes. Purpose-built for this** |
| 4 | Octagon (Miné 2006) | `±x ± y ≤ c` | yes, at O(n²) space and O(n³) time |
| 5 | Polyhedra (Cousot & Halbwachs 1978) | general linear inequalities | yes, exponential worst case |

Pentagons were designed for exactly this problem. From the paper: the domain "captures
properties of the form `x in [a, b] & x < y`", is "more precise than the well-known
Interval domain, but less precise than the Octagon domain", and exists to "quickly prove
the safety of most array accesses, restricting the use of more precise (but also more
expensive) domains to only a small fraction of the code."

### Where each compiler sits

**Chez is at level 1.** `cptypes-lattice.ss` is a finite lattice of categories. `index`,
`length`, `sub-index` and `u8` all collapse to `fixnum-pred` (lines 573 to 574). There is
no numeric range, so Chez cannot even express "i is in [0,5)", let alone relate it to a
vector's length. Bounds check elimination is not merely unimplemented, it is
unrepresentable in the current domain.

**SBCL sits at roughly level 3, by two separate mechanisms.**

Interval reasoning comes from the standard type language. `src/compiler/array-tran.lisp`,
`check-bound-empty-p` at line 2183:

```lisp
(defun check-bound-empty-p (bound index)
  (let* ((bound-type (make-numeric-type 'mod (cond ((constant-lvar-p bound) ...))))
         (index-type (lvar-type index)))
    (eq (type-intersection bound-type index-type) *empty-type*)))
```

It builds a `mod` type from the bound, intersects it with the index's type, and folds the
check when the intersection is empty. That is interval arithmetic performed in CL's
standard type lattice. `srctran.lisp` contains 598 references to `interval`, so the
interval machinery is extensive.

The relational part comes from `src/compiler/constraint.lisp`, 1791 lines of global flow
analysis. Line 95 defines the constraint kinds:

```lisp
(kind nil :type (member typep < > = >= <= eql equality set))
```

`<`, `>`, `<=`, `>=` between variables is precisely the strict-inequality component of a
Pentagon. `equality-constraints.lisp` adds another 1366 lines.

### Two independent gaps, not one

The domain is the first. The second is structural and I missed it initially:

**Chez has no *classical* loop optimizer.** (Grep evidence bounds this claim: Chez ships some loop handling per its own Version 2 highlights, but the classical passes are absent.) Grepping `s/*.ss` for `induction`,
`loop-invariant`, `licm` and `hoist` returns nothing. There is no loop recognition pass in
the entire compiler. SBCL has `src/compiler/loop.lisp` with `loop-analyze` and natural-loop
detection.

This matters for *hoisting* a check out of a loop. It matters less for *proving* one
inside a loop than an earlier draft of this section claimed. Clousot is the counterexample:
it has no loop recognition pass and no induction-variable analysis, stores invariants only
at loop headers, and still validates 88.9% of array accesses. A widened-and-narrowed
fixpoint at the header already gives the index's range across all iterations. ABCD makes the
same point from the other side, since its amplifying-cycle detection turns out to be
induction-variable handling as a free side effect. So the loop pass buys hoisting, not
provability, and it can be thinner or land later than the pipeline ordering assumes.
Gupta's 1993 flow-analysis method and the ABCD algorithm (Bodík, Gupta and Sarkar, PLDI
2000) both work by hoisting or coalescing checks across loop iterations using induction
variable information. Without loop structure, even a Pentagon domain would only remove
checks whose safety is locally provable within a basic block, which is a much weaker
result.

So Chez needs a two-level domain lift *and* a loop analysis pass it does not currently
have.

### Why Chez is built this way, stated fairly

This is a deliberate engineering position, not an oversight. Chez's passes are `cp0` for
inlining (Waddell and Dybvig's fast procedure inlining), `cptypes` for cheap type recovery,
and a nanopass backend. Dybvig optimized for compilation speed, and classical loop
optimization is expensive. Chez compiles very fast and produces good code, and the absent
loop optimizer is part of how it achieves the first of those.

### The standards connection, corrected

An earlier draft of this section said SBCL elides bounds checks "because it has ranges."
That was incomplete. Intervals alone suffice only when the array length is a compile-time
constant. For dynamic lengths, the relational constraints from `constraint.lisp` are what
carry it. Both mechanisms exist in SBCL and cover different cases.

The standards point survives, in a narrower form. ANSI CL standardized integer range types:
`(integer 0 9)`, `(mod 10)` and `(unsigned-byte 8)` are standard specifiers, so every
conforming implementation must represent ranges, which puts level 2 in reach by obligation.
Scheme standardized no type language, so its implementations built level 1 lattices,
because flat predicates are what the language offered. The relational layer at level 3 is
beyond what either standard requires, and SBCL built it anyway.

### A prediction that follows from theory, not measurement

nbody uses five bodies. Declared in CL as `(simple-array double-float (5))`, the length is a
compile-time constant, so **level 2 suffices and SBCL will fold the bounds checks with
interval reasoning alone.** Chez at level 1 cannot, regardless of how the source is written,
because no user-writable predicate puts a range into its lattice.

So the 2c-to-4 gap on nbody should be substantial and should be specifically an
interval-domain gap. Pentagon-class relational reasoning is not even required to explain it.
That is a falsifiable prediction derived from reading both codebases against the literature,
and phase 3 tests it rather than discovering it.

---

## 5. Consequences for the plan

**Phase 3 gains a configuration.** Between configuration 2a (R6RS operators, safe) and
configuration 4 (`optimize-level 3`, unsafe) there is now a distinct point worth measuring:
predicate-guarded entry with everything else portable, at `optimize-level 2`. Call it 2c.
It should capture the arithmetic and unboxing wins while still paying bounds checks. The
gap from 2c to 4 then isolates bounds-check elision specifically, which is exactly the
thing the standards analysis says Scheme cannot express.

That is a better decomposition than the original 2-to-4 delta, because it separates two
effects the earlier plan conflated.

**Phase 5's tier one is smaller than designed.** The declaration form is a five-line macro
for the arithmetic half. The suppression form is only needed for the bounds half, and for
that half no macro suffices on Chez.

**The compiler requirement list is now specific and citable.** Two items, in order:

1. Lift the lattice from level 1 to level 2 (intervals). This alone handles
   constant-length arrays, which covers nbody and a large fraction of real numeric code.
2. Add the strict-inequality relations to reach level 3 (Pentagon). This handles dynamic
   lengths. Logozzo and Fähndrich chose Pentagon over Octagon precisely because it is the
   cheap domain that still proves most array accesses safe, so it is the right target and
   Octagon is over-engineering.

A loop analysis pass is a third item and is needed before either domain can hoist a check
out of a loop rather than proving it locally.

**Do not build a whole compiler to test this.** The 2c measurement quantifies how much of
the gap is arithmetic, which a five-line macro already solves, versus bounds, which needs
the domain work. Theory predicts bounds will dominate on nbody. If that prediction holds,
the compiler has one clearly specified job with a named target domain and a published cost
profile. If arithmetic dominates instead, the SRFI is a macro and no compiler is needed.
