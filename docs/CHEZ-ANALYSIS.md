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

## 4. The real gap, stated precisely

ANSI Common Lisp standardized **integer range types**. `(integer 0 9)`, `(mod 10)`,
`(unsigned-byte 8)` are standard type specifiers, so every conforming implementation has to
understand ranges as types. That is what lets SBCL elide a bounds check from a declaration:
the declared type of the index and the derived length of the array are both range facts in
the same lattice, and the comparison is a lattice operation.

Scheme standardized **no type language at all**. So its implementations built lattices out
of flat predicates, because predicates are what the language gave them to work with. Chez's
lattice is good, and it is a lattice of *categories* rather than *values with ranges*.

So the folk claim partly reduces to something much more specific and much more
interesting than "CL is faster than Scheme":

**SBCL's type lattice carries integer ranges and Chez's does not, and the reason is that
CL's standard type language demanded ranges while Scheme's absent type language demanded
nothing.**

That is a compiler capability difference caused by a standards difference. It is a sharper
version of the thesis in `PLAN.md` section 1, and it is measurable: nbody's inner loop is
bounds-check dominated once the arithmetic is unboxed.

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

**The compiler requirement list narrows usefully.** From `phases/05-portable-library/CUJ.md`,
the "what this phase tells the compiler" section, the top item is now specific: our lattice
needs integer ranges, not just categories. That single capability is what unlocks
declaration-driven bounds elision, and it is what Chez is missing while SBCL has it because
the CL standard required it.

**Do not build a whole compiler to test this.** The 2c measurement establishes how much of
the gap is arithmetic (already solved by a macro) versus bounds (needs the lattice work).
If arithmetic is most of it, the SRFI is a macro and the compiler is optional. If bounds are
most of it, the compiler has one clear job.
