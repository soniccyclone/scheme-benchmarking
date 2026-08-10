;;; Representation selection: Lssa to Lrepr.
;;;
;;; cqs.6, stage 08. Every binding gets a storage class, and the storage class
;;; is what the register allocator reads.
;;;
;;; ## Why this is where the project's number comes from
;;;
;;; Phase 3 measured that unboxing is worth 1.12x and check elision 4.77x, so
;;; this pass is not the headline. But it is the pass that makes the headline
;;; REACHABLE: a value in `raw-f64` lives in a float register, is never
;;; scavenged, and needs no GC metadata, so nbody's inner loop can be free of
;;; metadata entirely. A value that lands in `tagged` by mistake goes to the
;;; value class, gets scavenged unconditionally, and drags the metadata back in.
;;;
;;; ## The three classes, from sonic/doc/register-partition.md
;;;
;;;   tagged     may hold a Scheme object. Scavenged unconditionally.
;;;   raw-word   an untagged machine word. Never scavenged.
;;;   raw-f64    an IEEE double. Never scavenged, lives in the float file.
;;;
;;; ## Soundness direction
;;;
;;; The two errors are NOT symmetric and neither is recoverable at run time.
;;;
;;; Calling a tagged value `raw` loses a GC root: the collector never scavenges
;;; it, and the object it points to is freed under a live reference. Calling a
;;; raw value `tagged` makes the collector scavenge a non-pointer, which
;;; corrupts whatever the bit pattern happens to address.
;;;
;;; So there is no safe default to fall back on, and `tagged` is NOT one. The
;;; pass answers from the primitive's result type, which is known exactly, and
;;; refuses anything it cannot type rather than guessing. A compiler that cannot
;;; classify a binding has found a gap in its own primitive table, and saying so
;;; is cheaper than either kind of corruption.

(library (sonic repr)
  (export select-representations select-representations-program
          prim-result-class datum-class vector-element-class
          parameter-classes parameter-classes/full
          repr-report repr-report? repr-report-counts repr-report-classes
          repr-report-naturals repr-report-booleans)
  (import (chezscheme) (nanopass) (sonic lang)
          (sonic order))

  (define-record-type (repr-report make-repr-report repr-report?)
    (fields counts          ; ((class . n) ...)
            classes         ; vreg -> storage class, INCLUDING parameters
            ;; What each let-bound variable's INITIALIZER produces, before any
            ;; join. Where this differs from `classes`, a conversion is owed;
            ;; convert.ss is what reads the pair. Keeping both is the whole
            ;; mechanism -- one table can say what a value must be OR what it
            ;; naturally is, and the conversion is the difference.
            naturals
            ;; Raw words holding 0/1 rather than a fixnum. A boolean tags to
            ;; sonic-false/sonic-true (7 and 15); a fixnum tags by shifting
            ;; left 3. Same storage class, different conversion, and conflating
            ;; them was a live memory-corruption bug.
            booleans))

  ;; --- the classification ---------------------------------------------------
  ;;
  ;; Derived from the primitive table rather than restated, so a primitive added
  ;; to `lang.ss` without a class here fails loudly instead of defaulting.

  (define f64-prims
    '(fl+ fl- fl* fl/ flneg flabs flsqrt fx->fl flvector-ref))

  ;; `raw-word` is one STORAGE class -- an untagged machine word, same register
  ;; file -- but it is two different things when it has to become tagged, and
  ;; conflating them was a live memory-corruption bug.
  ;;
  ;; A fixnum-valued word tags by shifting left 3 (numeric.ss, fixnum tag 000).
  ;; A boolean-valued word is 0 or 1 and tags to sonic-false/sonic-true, which
  ;; are 7 and 15. Shifting a boolean gives the FIXNUMS 0 and 1; leaving it
  ;; alone in the value class gives the collector addresses 0 and 1 to chase.
  (define fixnum-word-prims
    '(fx+ fx- fx* fxneg fxquotient fxremainder fxmodulo
      fl->fx flvector-length vector-length))

  (define boolean-word-prims
    '(fx< fx<= fx= fx>= fx> fl< fl<= fl= fl>= fl>
      null? pair? fixnum? flonum? vector? flvector? eq?))

  (define word-prims (append fixnum-word-prims boolean-word-prims))

  (define (word-kind pr)
    (cond ((eq? pr 'vector-ref) 'fixnum)   ; a raw element is a fixnum word
          ((memq pr fixnum-word-prims) 'fixnum)
          ((memq pr boolean-word-prims) 'boolean)
          (else #f)))

  (define tagged-prims
    '(make-flvector make-vector cons car cdr error))

  ;; --- what a general vector's elements are ----------------------------------
  ;;
  ;; A PROPERTY OF THE VECTOR, NOT OF THE PRIMITIVE. `vector-ref` used to be in
  ;; `tagged-prims`, which says every general vector holds Scheme objects. That
  ;; is the safe reading and it was not what the compiler DID: nothing tags what
  ;; it stores, so `(vector-set! v i i)` with a raw loop counter puts a raw word
  ;; in the slot and `(vector-ref v i)` claimed a tagged one came back.
  ;;
  ;; The claim cost a wrong answer rather than a missed optimisation. A value
  ;; joined up to `tagged` gets a `retag` at its definition (convert.ss), and
  ;; the consumers keep reading it raw -- there is no untagging direction, on
  ;; the stated grounds that a merged value never needs one. fannkuch-redux's
  ;; flip loop is the counterexample:
  ;;
  ;;     (let loop ((i 0) (j k)) (if (fx< i j) ... (loop (fx+ i 1) (fx- j 1))))
  ;;
  ;; `k` comes from `(vector-ref perm 0)` so `j` was tagged; `(fx- j 1)` is raw;
  ;; the join tagged `j` on the back edge and the loop then indexed `perm` with
  ;; `j << 3`. It needs two iterations to reach that edge, so it is invisible
  ;; below n=4 and traps the bounds check at n=4 and above.
  ;;
  ;; So the class is computed from the program, OPTIMISTICALLY AND THEN
  ;; VERIFIED: assume `raw-word`, classify, and check every value the program
  ;; writes into a general vector. If they are all raw words the assumption was
  ;; a fixed point; anything else -- a pair, a boxed double, a value whose class
  ;; the fixpoint could not name -- lifts the answer to `tagged` and the second
  ;; pass runs with that. The lattice has two points and the walk only goes up,
  ;; so two passes suffice.
  ;;
  ;; PROGRAM-WIDE, NOT PER-VECTOR, and deliberately. Per-vector needs to know
  ;; which allocation a `vector-set!` reaches, which is aliasing; program-wide
  ;; needs nothing and errs toward `tagged`, so one `(vector-set! v 0 (cons ...))`
  ;; anywhere makes every general vector tagged. That is a real precision loss
  ;; and it is the sound direction.
  (define vector-element-class (make-parameter 'tagged))

  ;; flvector-set! and vector-set! have no useful result; they are classified
  ;; raw-word so the unused destination does not pull a value register.
  (define effect-prims '(flvector-set! vector-set!))

  ;; --- what a primitive requires of its ARGUMENTS ----------------------------
  ;;
  ;; `prim-result-class` says what comes OUT. Nothing said what must go in, and
  ;; for a primitive that lowers to a runtime call that is not a gap in an
  ;; analysis, it is a gap in a CALLING CONVENTION: the routine is hand-written
  ;; assembly reading a fixed register, so it has to know the representation it
  ;; is handed. runtime.ss says so at `%make-vector`, whose fill it simply
  ;; assumes is a raw word -- "a tagged fill would read rdx and store garbage.
  ;; See the bead: the fix is for the compiler to declare argument classes, not
  ;; for this file to guess."
  ;;
  ;; This is that declaration. A requirement here is pushed BACKWARD in the
  ;; fixpoint exactly as a callee's parameter class is, so convert.ss inserts
  ;; the `retag` at the definition and the routine can rely on what arrives.
  ;;
  ;; ONLY WHERE THE REQUIREMENT IS REAL. `cons` stores both fields into a heap
  ;; object the collector SCANS, so a raw word in either one is a machine
  ;; integer being followed as a pointer -- D21's failure, not a wrong answer.
  ;; `car` and `cdr` dereference their argument, so it must be a pointer.
  ;;
  ;; Deliberately NOT listed: the type predicates and `eq?`. Declaring
  ;; `fixnum?`'s argument tagged would force a boxed representation on every
  ;; raw word anyone asks about, which costs more than the predicate does and
  ;; is not needed until those routines exist. `make-vector`'s fill is the
  ;; other real case and belongs here too, but changing it moves every existing
  ;; program's codegen, so it goes with the routine that consumes it.
  ;; THE PREDICATES TAKE TAGGED VALUES TOO, and the reason is not uniformity.
  ;; "Is this a pair" is a question about a SCHEME VALUE; a raw machine word is
  ;; a representation this compiler chose, not a value. Asking it of an untagged
  ;; register asks about the bits rather than about the object, and the routine
  ;; has no way to tell the two apart. For a fixnum the retag is a shift, which
  ;; is what makes the declaration affordable; for a double it is a heap box,
  ;; which is the honest price of asking.
  (define prim-arg-classes
    '((cons tagged tagged)
      (car  tagged)
      (cdr  tagged)
      (null?     tagged)
      (pair?     tagged)
      (fixnum?   tagged)
      (flonum?   tagged)
      (vector?   tagged)
      (flvector? tagged)
      (eq?       tagged tagged)))

  ;; --- what the runtime externs RETURN --------------------------------------
  ;;
  ;; An extern's result is `tagged` because nothing can say more -- true of a
  ;; procedure this compiler does not implement, and false of the handful it
  ;; does. runtime.ss's `length` returns a raw count and its `string->number`
  ;; returns a fixnum; calling those tagged is not conservatism, it is a wrong
  ;; answer waiting for the join to find it.
  ;;
  ;; nbody is where it was found. Its N comes from
  ;;
  ;;     (if (fx> (length args) 1) (string->number (cadr args)) 1000)
  ;;
  ;; so the `if` joined an extern's `tagged` against the literal 1000 and made N
  ;; tagged -- while `(fx< i N)` reads it as a raw word. The program is correct
  ;; today only because the literal was never encoded and the extern arm is dead
  ;; code. Declaring both routines raw-word removes the join, and N is a machine
  ;; word from end to end, which is what every consumer already assumed.
  (define extern-result-classes
    '((length        . raw-word)
      (string->number . raw-word)))

  ;; `tagged` for anything not named: an external procedure returns a Scheme
  ;; object and nothing here can say more. Naming one is a claim about a routine
  ;; in runtime.ss, checked by reading it.
  (define (extern-result-class name)
    (let ((p (assq name extern-result-classes)))
      (if p (cdr p) 'tagged)))

  ;; --- what the RUNTIME-PROVIDED externs require --------------------------
  ;;
  ;; An extern's result is `tagged` because nothing here can say more, and its
  ;; ARGUMENTS were unconstrained for the same reason -- which is wrong for the
  ;; handful of externs this compiler itself implements. runtime.ss's `display`
  ;; reads its double out of xmm0 unconditionally. Hand it a tagged value and
  ;; the call places that value in a VALUE register, xmm0 keeps whatever it last
  ;; held, and eight bytes of a stale double are written to fd 1.
  ;;
  ;; That is not hypothetical and it is why this table exists. `(cons 1.5 2.5)`
  ;; followed by `(display (car q))` printed 2.5 -- the second literal, still in
  ;; xmm0 from boxing it -- because `car` yields a tagged pointer to a boxed
  ;; flonum and nothing objected to passing it where a raw double was expected.
  ;;
  ;; THE REQUIREMENT IS VERIFIED, NOT PROPAGATED, and the difference matters.
  ;; Pushing `raw-f64` backward the way `prim-arg-classes` pushes `tagged` would
  ;; do nothing: the join only ever moves a class UP toward `tagged`, so a
  ;; tagged value asked to become a double stays tagged and the program compiles
  ;; anyway. There is no untagging direction in this compiler, on purpose. So
  ;; the mismatch is a REFUSAL, with a message naming both classes, rather than
  ;; a conversion.
  (define extern-arg-classes
    '((display raw-f64)))

  (define (prim-result-class pr)
    (cond ((eq? pr 'vector-ref) (vector-element-class))
          ((memq pr f64-prims) 'raw-f64)
          ((memq pr word-prims) 'raw-word)
          ((memq pr tagged-prims) 'tagged)
          ((memq pr effect-prims) 'raw-word)
          (else
           (error 'select-representations
                  "primitive has no storage class; add it to repr.ss rather than defaulting"
                  pr))))

  ;; A literal's class follows its type. Note `flonum?` before `number?`: a
  ;; double must not be classified as a word, or it lands in an integer register
  ;; and every arithmetic instruction after it is the wrong one.
  (define (datum-class d)
    (cond ((flonum? d) 'raw-f64)
          ((and (integer? d) (exact? d)) 'raw-word)
          (else 'tagged)))

  ;; --- parameter classes ----------------------------------------------------
  ;;
  ;; A `let` binding gets its class from its initializer, which is right there.
  ;; A LAMBDA PARAMETER has no initializer, and it needs a class for exactly the
  ;; same reasons: a double parameter that lands in the value class is scavenged
  ;; by the collector as if it were a pointer, and a tagged parameter that lands
  ;; in a raw register is a root the collector never finds.
  ;;
  ;; Its class comes from the CALL SITES. Every procedure in this compiler is
  ;; top-level or letrec-bound and every call names it directly -- closures are
  ;; a later bead -- so the argument in position i is known at every site, and
  ;; its class is the parameter's.
  ;;
  ;; This needs a fixpoint rather than one pass, because a loop is a letrec
  ;; whose tailcall passes the loop variable back to itself: the argument in
  ;; position i IS the parameter in position i, so a single pass would ask for
  ;; a class that is still being computed. Iterating from "unknown" and
  ;; assigning only what is known settles because classes are only ever added.
  ;;
  ;; Where two call sites disagree, the parameter is genuinely polymorphic and
  ;; there is no sound answer -- see this file's header: neither error is
  ;; recoverable and `tagged` is NOT a safe default. So it raises.
  (define (parameter-classes form)
    (let-values (((c n b) (parameter-classes/full form))) c))

  ;; Every distinct symbol in the datum. An OVER-count of the variables the
  ;; fixpoint can classify -- primitive names, check names and labels are all
  ;; symbols too -- and over-counting is the safe direction for a bound.
  (define (distinct-names form)
    (let ((seen (make-eq-hashtable)) (n 0))
      (let walk ((x form))
        (cond ((symbol? x)
               (unless (hashtable-ref seen x #f)
                 (hashtable-set! seen x #t)
                 (set! n (+ n 1))))
              ((pair? x) (walk (car x)) (walk (cdr x)))
              ((vector? x) (vector-for-each walk x))
              (else (void))))
      n))

  (define (parameter-classes/full form)
    (let ((classes (make-eq-hashtable))     ; vreg -> class
          (naturals (make-eq-hashtable))    ; vreg -> class of its initializer
          (params  (make-eq-hashtable))     ; procedure -> (param ...)
          (bodies  (make-eq-hashtable))     ; procedure -> body expr
          (results (make-eq-hashtable))     ; procedure -> result class
          (lets '())                        ; (x . simple-expr)
          (merges '())                      ; (x . (expr ...)) from phi/sigma
          (booleans (make-eq-hashtable))    ; raw words that hold 0/1, not a fixnum
          (sites '())                       ; (name . (arg ...))
          (prims '())                       ; every primcall, anywhere
          ;; An upper bound on the variables this fixpoint can classify. See
          ;; the note on the ceiling below: it decides how many rounds are
          ;; possible, so it is computed from the program and not chosen.
          (names (distinct-names form)))
      ;; 2N productive rounds, plus one to observe that nothing changed.
      (define ceiling (+ 2 (* 2 names)))

      ;; Merging two classes.
      ;;
      ;; Call sites CAN legitimately disagree. nbody's own argument handling is
      ;; the case:
      ;;
      ;;   (if (> (length args) 1) (string->number (cadr args)) 1000)
      ;;
      ;; One arm is a call whose result is a tagged object; the other is a
      ;; literal, which repr.ss would otherwise unbox. The join continuation's
      ;; parameter receives both, and a register holds one representation.
      ;;
      ;; `tagged` is the join of tagged and raw-word, and it is reachable
      ;; WITHOUT a conversion instruction whenever the raw side is a literal:
      ;; under numeric.ss's scheme a tagged fixnum's machine word is the value
      ;; shifted left 3 (fixnum tag 000), so the constant is simply materialized
      ;; already tagged, and the selectors honour that.
      ;;
      ;; A double against anything else has no such shortcut -- it needs a heap
      ;; box -- so that raises.
      (define (join-class v a b)
        (cond
         ((eq? a b) a)
         ((and (memq a '(tagged raw-word)) (memq b '(tagged raw-word)))
          ;; A FIXNUM-valued raw word joins to tagged for free: its tagged form
          ;; is the value shifted left 3, so where the raw side is a literal the
          ;; constant is simply materialised already shifted and no conversion
          ;; instruction is needed.
          ;;
          ;; A BOOLEAN-valued raw word does not. It holds 0 or 1 and its tagged
          ;; form is sonic-false or sonic-true -- 7 and 15 -- so the conversion
          ;; is `(x << 3) | 7`, two real instructions that something has to
          ;; emit. Nothing does yet.
          ;;
          ;; Answering `tagged` here WITHOUT a conversion is memory corruption
          ;; rather than a wrong number: a comparison's 0/1 lands in the VALUE
          ;; class, and under D21 the collector scavenges that unconditionally
          ;; and chases address 0 or 1. This used to raise for exactly that
          ;; reason. It no longer has to: `naturals` below records what each
          ;; binding's initializer actually produces, and convert.ss reads the
          ;; two tables and inserts a `retag` wherever they differ.
          ;;
          ;; So the answer is `tagged` and the obligation is recorded, which is
          ;; the difference between a default and a decision.
          'tagged)
         ;; A DOUBLE AND A NON-DOUBLE join to `tagged`, by BOXING the double.
         ;;
         ;; This used to raise, and the reason it could is that unlike the
         ;; fixnum and boolean cases there is no bit pattern that serves: a
         ;; double needs all 64 bits, so the value has to live on the heap and
         ;; be pointed at. That is a runtime facility, not two arithmetic
         ;; instructions, which is why it was a later bead rather than part of
         ;; D31.
         ;;
         ;; It is now `%box-flonum` in runtime.ss, and convert.ss inserts the
         ;; `retag` that calls it, at the definition like every other
         ;; conversion. `naturals` records that the binding is really a double;
         ;; the difference between the two tables is the obligation.
         ((or (and (eq? a 'raw-f64) (eq? b 'tagged))
              (and (eq? a 'tagged) (eq? b 'raw-f64))
              (and (eq? a 'raw-f64) (eq? b 'raw-word))
              (and (eq? a 'raw-word) (eq? b 'raw-f64)))
          'tagged)
         (else
          (error 'select-representations
                 "cannot merge these storage classes" v a b))))

      (define (note-into! tbl v c)
        (if (and (symbol? v) c)
            (let ((old (hashtable-ref tbl v #f)))
              (if (not old)
                  (begin (hashtable-set! tbl v c) #t)
                  (let ((j (join-class v old c)))
                    (if (eq? j old) #f (begin (hashtable-set! tbl v j) #t)))))
            #f))
      (define (note! v c) (note-into! classes v c))

      ;; --- collection ---
      (define (note-procs! binds)
        (for-each (lambda (b)
                    (let ((v (cadr b)))
                      (if (and (pair? v) (eq? (car v) 'lambda))
                          (begin
                            (hashtable-set! params (car b) (cadr v))
                            (hashtable-set! bodies (car b) (caddr v)))
                          ;; A top-level or letrec binding whose value is NOT a
                          ;; procedure -- nbody's `pos`, `vel` and `mass` are
                          ;; all of these. It is an ordinary binding and needs
                          ;; a class like any other; only its syntax differs
                          ;; from a `let`.
                          (set! merges (cons (cons (car b) (list v)) merges)))))
                  binds))
      ;; --- what a SimpleExpr's class is, given what is known so far ---
      ;;
      ;; A bare variable is a COPY and takes its source's class. `class-of` used
      ;; to answer `tagged` here, on the grounds that the class is "unknown" --
      ;; but this file's header says plainly that `tagged` is not a safe
      ;; default, and it is not: a double copied through a let would be
      ;; classified tagged, land in the value class, and be scavenged by the
      ;; collector as though the mantissa were an address.
      ;;
      ;; A CALL likewise used to answer `tagged`, on the grounds that an unknown
      ;; callee returns an object. But no callee here is unknown -- closures are
      ;; a later bead, so every procedure is top-level or letrec-bound and every
      ;; call names it -- and answering `tagged` for a procedure that returns a
      ;; double is not conservative, it is wrong: it forces a merge between a
      ;; double and a tagged value, which has no representation at all.
      (define (class-of-simple se)
        (cond
         ((symbol? se) (hashtable-ref classes se #f))
         ((not (pair? se)) (datum-class se))
         (else
          (case (car se)
            ((quote)    (datum-class (cadr se)))
            ((lambda)   'tagged)
            ;; A known callee's result class; `tagged` for an EXTERN, where it
            ;; is the correct answer rather than a default -- an external
            ;; procedure returns a Scheme object and nothing here can say more.
            ((call)     (if (hashtable-ref bodies (cadr se) #f)
                            (hashtable-ref results (cadr se) #f)
                            (extern-result-class (cadr se))))
            ((primcall) (prim-result-class (cadr se)))
            (else 'tagged)))))

      ;; The class an expression's TAIL produces. This is what a procedure
      ;; returns, and it is a join over the arms of any conditional in tail
      ;; position.
      (define (tail-class e)
        (cond
         ((symbol? e) (hashtable-ref classes e #f))
         ((not (pair? e)) (datum-class e))
         (else
          (case (car e)
            ((quote) (datum-class (cadr e)))
            ((let) (tail-class (caddr e)))
            ((seq) (tail-class (caddr e)))
            ((letrec) (tail-class (caddr e)))
            ((phi) (tail-class (caddr e)))
            ((sigma) (tail-class (list-ref e 6)))
            ((declare declare-distinct policy) (tail-class (caddr e)))
            ((if) (let ((a (tail-class (caddr e))) (b (tail-class (cadddr e))))
                    (cond ((and a b) (join-class '<if> a b)) (a a) (else b))))
            ((tailcall call) (if (hashtable-ref bodies (cadr e) #f)
                                 (hashtable-ref results (cadr e) #f)
                                 (extern-result-class (cadr e))))
            ((primcall) (prim-result-class (cadr e)))
            ((lambda) 'tagged)
            ;; An unspecified value. Classified raw-word to match what lower.ss
            ;; materialises for it, and because it is not a pointer: putting it
            ;; in the value class would have the collector scavenge it.
            ((void) 'raw-word)
            ((set!) 'raw-word)
            (else #f)))))

      ;; The variables in TAIL position, which is where `tail-class` takes its
      ;; join. Structurally parallel to it on purpose: an arm this misses is an
      ;; arm whose class is joined forward and never constrained backward.
      (define (tail-vars e)
        (cond
         ((symbol? e) (list e))
         ((not (pair? e)) '())
         (else
          (case (car e)
            ((let seq letrec phi declare declare-distinct policy) (tail-vars (caddr e)))
            ((sigma) (tail-vars (list-ref e 6)))
            ((if) (append (tail-vars (caddr e)) (tail-vars (cadddr e))))
            (else '())))))

      (let walk ((x form))
        (when (pair? x)
          (case (car x)
            ((let) (let* ((b (car (cadr x))) (se (cadr b)))
                     (when (and (pair? se) (eq? (car se) 'primcall)
                                (eq? (word-kind (cadr se)) 'boolean))
                       (hashtable-set! booleans (car b) #t))
                     (set! lets (cons (cons (car b) se) lets))))
            ;; phi and sigma BIND names, and nothing else in this walk sees
            ;; them. Missing them left every join variable unclassified, which
            ;; then propagated: a procedure whose tail is a phi had no result
            ;; class, so every call to it had none either.
            ((phi)
             (for-each (lambda (b)
                         (set! merges
                               (cons (cons (car b) (map cadr (cdr b))) merges)))
                       (cadr x)))
            ((sigma)
             ;; (sigma x-out x-in pr x-other negated? body): x-out is a
             ;; refinement of x-in and therefore the same representation.
             (set! merges (cons (cons (cadr x) (list (caddr x))) merges)))
            ((letrec top) (note-procs! (cadr x)))
            ;; EVERY primcall, not only a let-bound one: a conditional's TEST
            ;; holds its primcall inline, and that is the shape every predicate
            ;; is written in, so scanning `lets` misses exactly those.
            ((primcall) (set! prims (cons x prims)))
            ((call tailcall) (set! sites (cons (cons (cadr x) (cddr x)) sites))))
          (for-each walk x)))

      ;; --- fixpoint ---
      ;;
      ;; Iterating is not an optimisation here, it is required. A loop is a
      ;; letrec whose tailcall passes the loop variable back to itself, so the
      ;; argument in position i IS the parameter in position i, and a single
      ;; pass would ask for a class still being computed. Classes are only ever
      ;; joined upward, and the lattice has three points, so it settles.
      ;; BOUNDED, like every other fixpoint in this compiler -- and bounded by
      ;; the PROGRAM rather than by a constant.
      ;;
      ;; The termination argument is real: classes only ever join upward through
      ;; a three-point lattice, so each round either adds information or stops.
      ;; An argument is not a guard, though. `resolve-parallel-copy` had an
      ;; equally real one, with an unstated precondition, and when that
      ;; precondition broke it consed until a single process held 31GB and the
      ;; OOM killer took the machine three times in a session. A pass that
      ;; cannot make progress must FAIL.
      ;;
      ;; THE CEILING WAS 200 AND THAT WAS A SCALE LIMIT WEARING A
      ;; STUCK-DETECTOR'S LABEL. Information propagates one EDGE per round --
      ;; a call site pushes its argument's class to a parameter, the next round
      ;; pushes that parameter's class onward -- so a program with a longer
      ;; dependency chain needs more rounds whether or not anything is stuck. A
      ;; fully unrolled nbody (qaq.7.19) reaches 201 legitimately and was told
      ;; it had found a bug in this pass.
      ;;
      ;; So the ceiling comes from the termination argument instead of from a
      ;; guess. Every round that changes anything raises at least one variable's
      ;; class, and the lattice is three points, so a variable can be raised at
      ;; most twice: 2N productive rounds for N variables, plus one to observe
      ;; that nothing changed. `distinct-names` over-counts -- it includes
      ;; primitive names and labels -- which is the safe direction for a bound.
      ;;
      ;; The guarantee is unchanged: this still cannot run forever, and it still
      ;; fails rather than spinning. What changed is that the number now scales
      ;; with the thing it is bounding, and the message says which of the two
      ;; things went wrong.
      (let fix ((round 0))
        (when (> round ceiling)
          (error 'select-representations
                 (string-append
                  "storage-class fixpoint did not settle in " (number->string ceiling)
                  " rounds for a program with " (number->string names)
                  " names; the bound is 2 names + 2, so this is a bug in the pass"
                  " rather than a program too large")
                 round ceiling names))
        (let ((changed #f))
          (for-each (lambda (l)
                      (let ((nat (class-of-simple (cdr l))))
                        ;; Recorded every round; classes only ever join upward,
                        ;; so the last round's answer is the settled one.
                        (when nat (hashtable-set! naturals (car l) nat))
                        (when (note! (car l) nat) (set! changed #t))))
                    lets)
          ;; BACKWARD, from a primitive's declared argument class to whatever
          ;; produces it -- the same direction and the same reason as the
          ;; call-site rule below, except that the callee here is hand-written
          ;; assembly and cannot adapt to what it is handed. See
          ;; `prim-arg-classes`.
          ;; WHEN A GENERAL VECTOR HOLDS SCHEME OBJECTS, what goes into it must
          ;; BE one. `vector-element-class` is computed from the program and
          ;; then verified, so by here it is known; when it says `tagged`, the
          ;; value written by a `vector-set!` is a field the collector will
          ;; scan and has to be a real object.
          ;;
          ;; This is one half of a pair, and neither half works alone. Nothing
          ;; tagged what it stored and nothing untagged what it read, so a raw
          ;; fixnum round-tripped through a tagged-element vector unharmed --
          ;; true only while BOTH halves are missing. lower.ss's `untag-args`
          ;; is the other half.
          ;;
          ;; `make-vector`'s FILL is deliberately not included. runtime.ss's
          ;; %make-vector takes it in rdx, a RAW-word argument register, so
          ;; requiring it tagged would route it to r8 and the routine would
          ;; fill with whatever rdx happened to hold. The fill is 0 in every
          ;; program here and 0 is the same word tagged or raw, which is why
          ;; that hazard stays latent; it belongs with the change that gives
          ;; %make-vector a fill argument it can trust.
          (when (eq? (vector-element-class) 'tagged)
            (for-each
             (lambda (se)
               (let ((args (cdddr se)))
                 (case (cadr se)
                   ((vector-set!)
                    (when (and (>= (length args) 3) (symbol? (caddr args))
                               (note! (caddr args) 'tagged))
                      (set! changed #t)))
                   ((make-vector)
                    (when (and (>= (length args) 2) (symbol? (cadr args))
                               (note! (cadr args) 'tagged))
                      (set! changed #t)))
                   (else (void)))))
             prims))
          (for-each
           (lambda (se)
             (let ((req (assq (cadr se) prim-arg-classes)))
               (when req
                 (let loop ((as (cdddr se)) (cs (cdr req)))
                   (unless (or (null? as) (null? cs))
                     (when (and (symbol? (car as)) (note! (car as) (car cs)))
                       (set! changed #t))
                     (loop (cdr as) (cdr cs)))))))
           prims)
          (for-each (lambda (m)
                      (for-each (lambda (op)
                                  (when (note! (car m) (tail-class op))
                                    (set! changed #t))
                                  ;; BACKWARD, for the same reason the call-site
                                  ;; rule below is backward. Phi elimination
                                  ;; turns each operand into a COPY into the
                                  ;; merge variable's register, so an operand
                                  ;; left in `raw-word` while the merge is
                                  ;; `tagged` moves a raw word into the value
                                  ;; class -- and nothing downstream would ever
                                  ;; look at the pair again to notice.
                                  (let ((mc (hashtable-ref classes (car m) #f)))
                                    (when (and mc (symbol? op) (note! op mc))
                                      (set! changed #t))))
                                (cdr m)))
                    merges)
          (vector-for-each
           (lambda (f)
             (when (note-into! results f (tail-class (hashtable-ref bodies f #f)))
               (set! changed #t))
             ;; BACKWARD into the tail positions. A procedure returns in ONE
             ;; register, so if the join over its arms is `tagged` then an arm
             ;; whose tail is a raw-word variable has to arrive tagged too.
             ;; Without this, a two-armed procedure returning a comparison from
             ;; one arm and an object from the other returns 0 or 1 in the value
             ;; class on half its paths.
             (let ((r (hashtable-ref results f #f)))
               (when r
                 (for-each (lambda (v)
                             (when (note! v r) (set! changed #t)))
                           (tail-vars (hashtable-ref bodies f #f))))))
           (sorted-keys bodies))
          (for-each
           (lambda (site)
             (let ((ps (hashtable-ref params (car site) #f)))
               (when (and ps (= (length ps) (length (cdr site))))
                 (for-each
                  (lambda (p a)
                    (let ((ac (and (symbol? a) (hashtable-ref classes a #f)))
                          (pc (hashtable-ref classes p #f)))
                      (when (and ac (note! p ac)) (set! changed #t))
                      ;; BACKWARD. Once a parameter has joined to `tagged`,
                      ;; every argument feeding it must ARRIVE tagged, or the
                      ;; callee reads a raw word as an object. Pushing the
                      ;; requirement back to the producer is what makes the
                      ;; literal case free: the constant is materialized already
                      ;; shifted and there is no conversion to insert.
                      (when (and pc (symbol? a) (note! a pc)) (set! changed #t))))
                  ps (cdr site)))))
           sites)
          (when changed (fix (+ round 1)))))

      ;; The settled classes are now checked against what the runtime externs
      ;; actually read. See `extern-arg-classes`: this is a refusal rather than
      ;; a conversion, because the direction it would need does not exist.
      (for-each
       (lambda (site)
         (unless (hashtable-ref bodies (car site) #f)
           (let ((req (assq (car site) extern-arg-classes)))
             (when req
               (let loop ((as (cdr site)) (cs (cdr req)) (i 0))
                 (unless (or (null? as) (null? cs))
                   (let ((ac (if (symbol? (car as))
                                 (hashtable-ref classes (car as) #f)
                                 (class-of-simple (car as)))))
                     (when (and ac (not (eq? ac (car cs))))
                       (error 'select-representations
                              (string-append
                               "argument " (number->string i) " of the runtime procedure `"
                               (symbol->string (car site)) "` must be "
                               (symbol->string (car cs)) " and this one is "
                               (symbol->string ac)
                               "; there is no conversion in that direction -- a tagged"
                               " value cannot be untagged into a machine register, so"
                               " the program is refused rather than compiled into a"
                               " call that reads a stale register")
                              (car site) (car as) ac (car cs))))
                   (loop (cdr as) (cdr cs) (+ i 1))))))))
       sites)

      ;; A PROCEDURE NOTHING CALLS CONSTRAINS NOTHING, so its parameters are
      ;; free rather than unknown, and the difference is the whole point.
      ;;
      ;; A parameter's class comes from the call sites, as the note above this
      ;; function says. A procedure with NO call sites therefore leaves its
      ;; parameters unclassified, and lower.ss then hits an `if` in its body
      ;; and cannot say how to copy either arm into the join destination -- so
      ;; a program is REFUSED because of code that cannot run. fannkuch-redux
      ;; shrunk to test `count-flips` alone did exactly that: `rotate` was
      ;; still defined, nothing called it, and `r%10.17` had no class.
      ;;
      ;; UNREACHABLE, not merely uncalled-so-far. Every procedure here is
      ;; top-level or letrec-bound and every call names it directly -- closures
      ;; are a later bead -- so `sites` is the complete set of calls in the
      ;; program. A name absent from it cannot be reached, including the entry,
      ;; which the top-level body calls by name like anything else.
      ;;
      ;; `raw-word` because an unconstrained choice should be the one that
      ;; cannot make work for the collector: a register in the value class is
      ;; scavenged unconditionally under D21, and this code never runs to put
      ;; anything meaningful in it. It is not a default in the sense this
      ;; file's header refuses -- there is no constraint to violate.
      ;;
      ;; The better answer is not to COMPILE an unreachable procedure at all,
      ;; which would save the bytes as well; that needs a reachability pass
      ;; this one is not, and is filed separately.
      (let ((called '()))
        (for-each (lambda (site)
                    (unless (memq (car site) called)
                      (set! called (cons (car site) called))))
                  sites)
        (for-each
         (lambda (f)
           (unless (memq f called)
             (for-each (lambda (p)
                         (unless (hashtable-ref classes p #f)
                           (hashtable-set! classes p 'raw-word)))
                       (hashtable-ref params f '()))))
         (sorted-key-list params)))

      (values classes naturals booleans)))

  ;; The class of an Lrepr/Lssa SimpleExpr given as a datum. A bare variable is
  ;; NOT handled here on purpose: it is a copy, and copies are resolved by the
  ;; fixpoint above rather than guessed at.
  (define (class-of-datum se)
    (cond
     ((not (pair? se)) (datum-class se))
     (else
      (case (car se)
        ((quote) (datum-class (cadr se)))
        ((lambda) 'tagged)
        ((call) 'tagged)
        ((primcall) (prim-result-class (cadr se)))
        (else 'tagged)))))

  ;; --- the pass -------------------------------------------------------------

  ;; `known` is the table `parameter-classes` computed over the whole program.
  ;; It is the authority: it resolves copies, call results and parameters, none
  ;; of which are answerable from a single binding's initializer.
  (define (select-representations e . opt)
    (let ([counts (make-eq-hashtable)]
          [known (if (pair? opt) (car opt) (parameter-classes (unparse-Lssa e)))]
          [naturals (if (and (pair? opt) (pair? (cdr opt))) (cadr opt) (make-eq-hashtable))]
          [booleans (if (and (pair? opt) (pair? (cddr opt))) (caddr opt) (make-eq-hashtable))])
      (define (bump! c) (hashtable-set! counts c (+ 1 (hashtable-ref counts c 0))))
      (define (class-of-binding x se)
        (or (hashtable-ref known x #f)
            ;; Not reached by the whole-program fixpoint: a binding nothing
            ;; ever reads. Its own initializer still answers, and this is the
            ;; only case where the local answer is the whole answer.
            (nanopass-case (Lssa SimpleExpr) se
              [(quote ,d) (datum-class d)]
              [(lambda (,x* ...) ,body) 'tagged]
              [(primcall ,pr ([,pn* ,c*] ...) ,x* ...) (prim-result-class pr)]
              [else
               ;; THE INITIALIZER IS REPORTED, not just the name. A bare
               ;; `t.94` says a binding was missed and nothing about which
               ;; shape the fixpoint failed to reach, and the two candidates --
               ;; a copy of a variable and a call -- want different fixes.
               (error 'select-representations
                      (string-append
                       "no storage class for this binding; classifying it "
                       "wrongly would either lose a GC root or put a double in "
                       "an integer register, and there is no safe default")
                      x (unparse-Lssa se))])))
      (define (Expr e)
        (with-output-language (Lrepr Expr)
          (nanopass-case (Lssa Expr) e
            [(let ([,x ,se]) ,body)
             (let ([sc (class-of-binding x se)])
               (bump! sc)
               `(let ([,x ,sc ,(SimpleExpr se)]) ,(Expr body)))]
            ;; `lambda` is both an Expr and a SimpleExpr: a top-level binding's
            ;; value is an Expr, so a defined procedure arrives here rather than
            ;; through SimpleExpr.
            [(lambda (,x* ...) ,body) `(lambda (,x* ...) ,(Expr body))]
            [(if ,x ,e0 ,e1) `(if ,x ,(Expr e0) ,(Expr e1))]
            [(seq ,e0 ,e1) `(seq ,(Expr e0) ,(Expr e1))]
            [(tailcall ,x ,x* ...) `(tailcall ,x ,x* ...)]
            [(sigma ,x0 ,x1 ,pr ,x2 ,b ,body) `(sigma ,x0 ,x1 ,pr ,x2 ,b ,(Expr body))]
            [(phi ([,x* (,lbl** ,e**) ...] ...) ,body)
             `(phi ([,x* (,lbl** ,(map (lambda (es) (map Expr es)) e**)) ...] ...)
                   ,(Expr body))]
            [(letrec ([,x* ,e*] ...) ,body)
             `(letrec ([,x* ,(map Expr e*)] ...) ,(Expr body))]
            [(declare ([,x* ,prem*] ...) ,body) `(declare ([,x* ,prem*] ...) ,(Expr body))]
            [(declare-distinct (,x* ...) ,body) `(declare-distinct (,x* ...) ,(Expr body))]
            [(policy ([,pn* ,b*] ...) ,body) `(policy ([,pn* ,b*] ...) ,(Expr body))]
            [(set! ,x ,e) `(set! ,x ,(Expr e))]
            [,x `,x]
            [(quote ,d) `(quote ,d)]
            [(void) `(void)]
            [else (error 'select-representations "unhandled Lssa expression" e)])))
      (define (SimpleExpr se)
        (with-output-language (Lrepr SimpleExpr)
          (nanopass-case (Lssa SimpleExpr) se
            [,x `,x]
            [(quote ,d) `(quote ,d)]
            [(lambda (,x* ...) ,body) `(lambda (,x* ...) ,(Expr body))]
            [(call ,x ,x* ...) `(call ,x ,x* ...)]
            [(primcall ,pr ([,pn* ,c*] ...) ,x* ...)
             `(primcall ,pr ([,pn* ,c*] ...) ,x* ...)])))
      (let ([out (Expr e)])
        (values out
                (make-repr-report
                 (map (lambda (c) (cons c (hashtable-ref counts c 0)))
                      '(tagged raw-word raw-f64))
                 known naturals booleans)))))

  ;; Every value the program writes into a general vector: the third argument
  ;; of a `vector-set!` and the fill of a `make-vector`. Read off the datum
  ;; because the shape is uniform there -- `(primcall pr (perms) arg ...)` --
  ;; and a nanopass walk would need a clause per production to find two of them.
  (define (values-stored-into-vectors datum)
    (let ((acc '()))
      (let walk ((x datum))
        (when (pair? x)
          (when (and (eq? (car x) 'primcall) (pair? (cdr x)) (pair? (cddr x)))
            (let ((args (cdddr x)))
              (case (cadr x)
                ;; (vector-set! v i val)
                ((vector-set!)
                 (when (>= (length args) 3) (set! acc (cons (caddr args) acc))))
                ;; (make-vector n fill)
                ((make-vector)
                 (when (>= (length args) 2) (set! acc (cons (cadr args) acc))))
                (else (void)))))
          (for-each walk x)))
      acc))

  ;; The verification half. `known` is the whole-program class table computed
  ;; under the optimistic assumption; a stored value it cannot name is treated
  ;; as tagged, which is the sound direction.
  (define (vector-elements-all-raw? datum known)
    (for-all (lambda (v)
               (eq? 'raw-word
                    (cond ((symbol? v) (hashtable-ref known v #f))
                          ((and (pair? v) (eq? (car v) 'quote)) (datum-class (cadr v)))
                          (else #f))))
             (values-stored-into-vectors datum)))

  (define (program-vector-element-class datum)
    (parameterize ((vector-element-class 'raw-word))
      (let-values ([(known naturals booleans) (parameter-classes/full datum)])
        (if (vector-elements-all-raw? datum known) 'raw-word 'tagged))))

  (define (select-representations-program p)
    (nanopass-case (Lssa Program) p
      [(top ([,x* ,e*] ...) (,x2* ...) ,body)
       ;; ONE fixpoint over the whole program. Per-binding would be wrong: a
       ;; call crosses top-level bindings, so the class of what a procedure
       ;; returns is not derivable from the binding that contains the call.
       (parameterize ((vector-element-class
                       (program-vector-element-class (unparse-Lssa p))))
       (let*-values ([(total) (make-eq-hashtable)]
                     [(known naturals booleans)
                      (parameter-classes/full (unparse-Lssa p))])
         (define (one e)
           (let-values ([(e^ rpt) (select-representations e known naturals booleans)])
             (for-each (lambda (p)
                         (hashtable-set! total (car p)
                                         (+ (cdr p) (hashtable-ref total (car p) 0))))
                       (repr-report-counts rpt))
             e^))
         (with-output-language (Lrepr Program)
           (let* ([v* (map one e*)] [b (one body)])
             (values `(top ([,x* ,v*] ...) (,x2* ...) ,b)
                     (make-repr-report
                      (map (lambda (c) (cons c (hashtable-ref total c 0)))
                           '(tagged raw-word raw-f64))
                      known naturals booleans))))))]))
  )
