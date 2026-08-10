;;; SonicScheme: procedure inlining. Lanf -> Lanf.
;;;
;;; Stage 04b. Four later stages assume this has run, for three different
;;; reasons, all of them recorded in CUJ's wave-2 ordering corrections: Leroy,
;;; because storage class assignment before inlining leaves coercion redexes
;;; that never cancel; Hoelzle and Ungar, because narrowing is much cheaper
;;; after inlining and running the domain first invites declaring victory early;
;;; and Waddell and Dybvig via Ashley, because inlining invalidates the flow
;;; information that justified it, so the order matters in both directions.
;;;
;;; CARRY THIS NUMBER. nbody is the single benchmark on which Chez's `cp0` does
;;; NOT help: Waddell and Dybvig report 0.92 to 1.05 on the R4400 and attribute
;;; it to cache effects from three-level nested array indexing, without
;;; measuring that attribution. nbody is also the program every milestone in
;;; this phase is written against. So a measured effect of nothing on nbody is
;;; the EXPECTED result for this pass, not a defect in it, and nothing in this
;;; file is tuned toward a win that the literature says is not there. What the
;;; pass is actually for is downstream: it removes the call boundaries that cap
;;; `(sonic alias)` and `(sonic analyze)`, both of which lose everything at a
;;; call to a procedure they cannot enumerate the callers of.
;;;
;;; --- WHAT MAY BE INLINED -------------------------------------------------
;;;
;;; 1. KNOWN. The callee is bound exactly once, to a lambda, by `let` or
;;;    `letrec`, and its name appears nowhere except as the operator of a `call`
;;;    or `tailcall`. That last condition is what makes the binding's lambda the
;;;    only thing the name can denote.
;;;
;;; 2. SMALL. The callee body is at most `inline-size-budget` Lanf nodes.
;;;
;;; 3. NOT ALREADY BEING INLINED. A callee on the active inline stack is
;;;    refused. THIS IS THE TERMINATION PROOF: the stack holds distinct names
;;;    drawn from the program's finite set of binders, so the recursion in this
;;;    pass is well founded regardless of what rule 4 does. Depth is
;;;    additionally capped at `inline-depth-budget`, which bounds code growth
;;;    rather than proving termination.
;;;
;;; 4. NOT RECURSIVE. A procedure that can reach itself through the call graph
;;;    is never inlined. Rule 3 already makes such a call terminate, by
;;;    unrolling exactly once and stopping; rule 4 refuses the unroll outright,
;;;    because unrolling a loop is a different transformation with a different
;;;    cost model and this pass is not it. The two rules are kept separate so
;;;    that relaxing rule 4 into a real unroller cannot make the pass diverge.
;;;
;;; 5. SPLICEABLE, at non-tail call sites only. `(let ([r (call f a ...)]) k)`
;;;    has to put `k` after the callee's result, and if the callee body ends in
;;;    a conditional there is more than one place to put it. Copying `k` into
;;;    every branch is code duplication, so instead the callee is required to
;;;    have exactly one tail position. A `(tailcall f a ...)` has no `k` at all
;;;    and carries no such restriction.
;;;
;;; --- WHAT IS PRESERVED ---------------------------------------------------
;;;
;;; NO DUPLICATED EFFECTS. Lanf operands are already atoms, so a parameter is
;;; substituted by a VARIABLE, never by the expression that produced it. A
;;; parameter used twice therefore yields two references to one binding, and the
;;; `let` that computed it stays exactly where it was, evaluated once. This is
;;; the property that a beta-substituting inliner over a non-ANF language has to
;;; work for and that ANF hands us.
;;;
;;; THE ANF INVARIANT. Every intermediate stays named. The nanopass grammar
;;; enforces the syntactic half at compile time; the part it cannot enforce is
;;; that the result of an inlined body still gets bound where the original
;;; call's result was bound, which is what `splice` does.
;;;
;;; NO CAPTURE. Every binder in an inlined copy is renamed. The callee's FREE
;;; variables are left alone, which is correct because a call site is always
;;; lexically inside the scope of the callee's binding, so everything free in
;;; the callee is in scope at the call. That argument needs binder names to be
;;; globally unique, which is what the expander guarantees; a shadowing rebind
;;; between the definition and the call would break it.
;;;
;;; DEAD BINDINGS ARE LEFT BEHIND. Once every call site of `f` is inlined, the
;;; `(let ([f (lambda ...)]) ...)` is dead. Removing it is dead code
;;; elimination, which is a different pass, and doing it here would mean this
;;; pass had two jobs.

(library (sonic inline)
  (export inline-program inline-program/report
          inline-size-budget inline-depth-budget
          ;; For the unroller, which is a different transformation with a
          ;; different cost model (see rule 4) but needs the same two tools:
          ;; capture-avoiding copying, and a node count to budget against.
          freshen expr-size)
  (import (chezscheme) (nanopass) (sonic lang))

  ;; --- the budgets ---------------------------------------------------------
  ;;
  ;; SIZE, 12 Lanf nodes. Set from the shape of the target program rather than
  ;; from a stopwatch. An ANF'd accessor of nbody's shape, a couple of
  ;; flvector-refs and one flonum operation with each intermediate named, counts
  ;; 8 to 12 under `expr-size` below; a whole loop body counts several times
  ;; that. So 12 admits the helpers whose call overhead is a real fraction of
  ;; their work and refuses the ones where it is not.
  ;;
  ;; The reason there is a ceiling at all is that inlining trades call overhead
  ;; for instruction cache footprint, and nbody is precisely the program where
  ;; that trade is reported to come out flat. Tuning this number against nbody's
  ;; wall clock would be fitting to noise, so it is not tuned against anything.
  ;; ZERO, WHICH DISABLES THE PASS, and that is a measurement rather than a
  ;; retreat. Until 2026-08-08 this pass had never run at all: it matched only
  ;; on Expr while the pipeline hands a Program, and it stopped at the
  ;; `declare-distinct` that wraps every kernel here. Both are fixed, so the
  ;; question "is it worth running" could finally be asked, and nbody answers:
  ;;
  ;;   inline-budget    instr/step   fp     int    elide sites proved
  ;;   0 (off)               775.5   420    348.5              157 of 227
  ;;   12                    775.5   420    348.5              139 of 227
  ;;
  ;; Identical code, and eighteen facts the interval analysis can no longer
  ;; discharge. The header above says a measured effect of nothing on nbody is
  ;; the EXPECTED result -- Waddell and Dybvig report 0.92 to 1.05 for cp0 on
  ;; this exact benchmark -- and that the pass's real value is downstream, in
  ;; removing call boundaries that cap `(sonic alias)` and `(sonic analyze)`.
  ;; On this program it removes one boundary, around a wrapper called twice
  ;; outside every loop, and costs the analysis more than it buys.
  ;;
  ;; So it is off by evidence, not by accident, and the knob is the pass's own.
  ;;
  ;; ASKED AGAIN ON FANNKUCH-REDUX, 2026-08-10, which is the benchmark this note
  ;; nominated. THE ANSWER IS NO, and for a reason worth writing down rather
  ;; than re-deriving:
  ;;
  ;;     fannkuch  budget 0   448 instructions, 4 bounds checks
  ;;     fannkuch  budget 12  448 instructions, 4 bounds checks
  ;;     fannkuch  budget 24  448 instructions, 4 bounds checks
  ;;     nbody     budget 12  878 instructions, 14 bounds checks (from 810, 0)
  ;;
  ;; Byte-identical at every budget. fannkuch HAS many small procedures --
  ;; `flip-prefix`, `count-flips`, `copy-perm`, `fill-counts`, `rotate`, `init`
  ;; -- and every one of them is SELF-RECURSIVE, because a loop in this
  ;; compiler is a procedure that tail-calls itself. Rule 4 refuses recursion,
  ;; so there is nothing here to inline at any size.
  ;;
  ;; "Many small procedures" was the wrong predictor. The one that matters is
  ;; many small NON-LOOP procedures, and a Scheme benchmark written in the
  ;; natural style has few: the small things are loops and the big things are
  ;; kernels. That is a property of the language rather than of these two
  ;; programs, so raising this budget is unlikely to pay on the next benchmark
  ;; either -- ask with a measurement, not with an intuition.
  ;;
  ;; nbody at 12 is the same result the note above records, now with the
  ;; elision cost in instructions: one call boundary removed, 68 more
  ;; instructions, and fourteen bounds checks that used to be discharged.
  (define inline-size-budget (make-parameter 0))

  ;; DEPTH, 2. Inlining a callee into an already-inlined callee is where growth
  ;; turns multiplicative. Two levels covers accessor-into-kernel, which is the
  ;; only nesting these benchmarks have.
  (define inline-depth-budget (make-parameter 2))

  ;; --- fresh names ---------------------------------------------------------
  ;; Readable rather than `gensym`, because these names end up in test output
  ;; and in unparsed IR that a human has to read. Uniqueness comes from the
  ;; counter; a collision would need the source to already contain a name of the
  ;; form `foo.17`, which the expander does not emit.
  (define name-counter 0)
  (define (fresh x)
    (set! name-counter (+ name-counter 1))
    (string->symbol (string-append (symbol->string x) "." (number->string name-counter))))

  ;; --- size and tail counting ----------------------------------------------

  (define (expr-size e)
    (nanopass-case (Lanf Expr) e
      [,x 1]
      [(quote ,d) 1]
      [(if ,x ,e0 ,e1) (+ 1 (expr-size e0) (expr-size e1))]
      [(seq ,e0 ,e1) (+ 1 (expr-size e0) (expr-size e1))]
      [(let ([,x ,se]) ,body) (+ 1 (se-size se) (expr-size body))]
      [(tailcall ,x ,x* ...) (+ 1 (length x*))]
      [(lambda (,x* ...) ,body) (+ 1 (length x*) (expr-size body))]
      [(letrec ([,x* ,e*] ...) ,body)
       (+ 1 (apply + (map expr-size e*)) (expr-size body))]
      [(declare ([,x* ,prem*] ...) ,body) (+ 1 (expr-size body))]
      ;; Without this a procedure whose body is wrapped in one measures 1 node,
      ;; so every size budget passes it and none of them means anything.
      [(declare-distinct (,x* ...) ,body) (+ 1 (expr-size body))]
      [(policy ([,pn* ,b*] ...) ,body) (+ 1 (expr-size body))]
      [else 1]))

  (define (se-size se)
    (nanopass-case (Lanf SimpleExpr) se
      [,x 1]
      [(quote ,d) 1]
      [(lambda (,x* ...) ,body) (+ 1 (length x*) (expr-size body))]
      [(call ,x ,x* ...) (+ 1 (length x*))]
      [(primcall ,pr ([,pn* ,c*] ...) ,x* ...) (+ 1 (length x*))]
      [else 1]))

  ;; How many places a value can leave this expression from. Exactly one is what
  ;; rule 5 requires; a conditional in tail position gives two.
  (define (tail-count e)
    (nanopass-case (Lanf Expr) e
      [(if ,x ,e0 ,e1) (+ (tail-count e0) (tail-count e1))]
      [(seq ,e0 ,e1) (tail-count e1)]
      [(let ([,x ,se]) ,body) (tail-count body)]
      [(letrec ([,x* ,e*] ...) ,body) (tail-count body)]
      [(declare ([,x* ,prem*] ...) ,body) (tail-count body)]
      ;; Falling through to `else` counted a wrapped body as ONE tail position,
      ;; which is the right number by accident and the wrong reason: rule 5 then
      ;; admitted a body `splice` could not walk, and the two drifted apart in
      ;; exactly the way the note on `splice`'s else case predicted.
      [(declare-distinct (,x* ...) ,body) (tail-count body)]
      [(policy ([,pn* ,b*] ...) ,body) (tail-count body)]
      [else 1]))

  ;; The widest tail call in a body, in ARGUMENTS. Tail positions only: a call
  ;; that is not in tail position becomes an ordinary call with its own frame and
  ;; writes its arguments into this procedure's outgoing area, which the frame
  ;; layout already sizes for.
  (define (max-tail-arity e)
    (nanopass-case (Lanf Expr) e
      [(if ,x ,e0 ,e1) (max (max-tail-arity e0) (max-tail-arity e1))]
      [(seq ,e0 ,e1) (max-tail-arity e1)]
      [(let ([,x ,se]) ,body) (max-tail-arity body)]
      [(letrec ([,x* ,e*] ...) ,body) (max-tail-arity body)]
      [(declare ([,x* ,prem*] ...) ,body) (max-tail-arity body)]
      [(declare-distinct (,x* ...) ,body) (max-tail-arity body)]
      [(policy ([,pn* ,b*] ...) ,body) (max-tail-arity body)]
      [(tailcall ,x ,x* ...) (length x*)]
      [else 0]))

  ;; The arity of the procedure whose body is being walked. A dynamic parameter
  ;; rather than a threaded argument because every `Expr` call site would
  ;; otherwise grow one, and this is read in exactly one place.
  (define current-arity (make-parameter 0))

  ;; --- which names are known procedures ------------------------------------

  (define-record-type proc (fields params body size sites))

  ;; Returns (values procs recursive), both eq-hashtables keyed on name.
  (define (scan e)
    (let ([binds (make-eq-hashtable)]      ; name -> binding occurrences
          [lam (make-eq-hashtable)]        ; name -> (params . body)
          [nonop (make-eq-hashtable)]      ; name -> #t, seen other than as operator
          [calls (make-eq-hashtable)]
          [sites (make-eq-hashtable)])
      (define (bind! x) (hashtable-update! binds x (lambda (n) (+ n 1)) 0))
      (define (use! x) (hashtable-set! nonop x #t))
      (define (site! x) (hashtable-update! sites x (lambda (n) (+ n 1)) 0))
      (define (edge! from to)
        (when from (hashtable-update! calls from (lambda (s) (cons to s)) '())))
      (define (Expr e from)
        (nanopass-case (Lanf Expr) e
          [,x (use! x)]
          [(quote ,d) (void)]
          [(if ,x ,e0 ,e1) (use! x) (Expr e0 from) (Expr e1 from)]
          [(seq ,e0 ,e1) (Expr e0 from) (Expr e1 from)]
          [(let ([,x ,se]) ,body)
           (bind! x)
           (nanopass-case (Lanf SimpleExpr) se
             [(lambda (,x1* ...) ,body1)
              (hashtable-set! lam x (cons x1* body1))
              (for-each bind! x1*)
              (Expr body1 x)]
             [else (SimpleExpr se from)])
           (Expr body from)]
          [(tailcall ,x ,x* ...) (edge! from x) (site! x) (for-each use! x*)]
          [(lambda (,x* ...) ,body) (for-each bind! x*) (Expr body from)]
          [(letrec ([,x* ,e*] ...) ,body)
           (for-each bind! x*)
           (for-each (lambda (nm rhs)
                       (nanopass-case (Lanf Expr) rhs
                         [(lambda (,x1* ...) ,body1)
                          (hashtable-set! lam nm (cons x1* body1))
                          (for-each bind! x1*)
                          (Expr body1 nm)]
                         [else (Expr rhs from)]))
                     x* e*)
           (Expr body from)]
          [(declare ([,x* ,prem*] ...) ,body) (for-each use! x*) (Expr body from)]
          ;; Same treatment as `declare`: it NAMES variables rather than binding
          ;; them, and every kernel taking vectors is wrapped in one. Without it
          ;; this walk stops at the top of every procedure in the benchmark.
          [(declare-distinct (,x* ...) ,body) (for-each use! x*) (Expr body from)]
          [(policy ([,pn* ,b*] ...) ,body) (Expr body from)]
          [else (void)]))
      (define (SimpleExpr se from)
        (nanopass-case (Lanf SimpleExpr) se
          [,x (use! x)]
          [(quote ,d) (void)]
          [(lambda (,x* ...) ,body) (for-each bind! x*) (Expr body from)]
          [(call ,x ,x* ...) (edge! from x) (site! x) (for-each use! x*)]
          [(primcall ,pr ([,pn* ,c*] ...) ,x* ...) (for-each use! x*)]
          [else (void)]))
      ;; TOP-LEVEL BINDINGS ARE PROCEDURES TOO, and reaching them is the whole
      ;; of D32 here. A top-level `(define (f ...) ...)` is bound exactly once,
      ;; by the Program rather than by a `let`, so it satisfies rule 1 for the
      ;; same reason a letrec binding does -- and assign conversion has already
      ;; run, so a name still bound to a bare lambda is one nothing assigns to.
      ;; ACCEPTS EITHER SHAPE. The pipeline hands a Program; the fixtures in this
      ;; tree hand a bare Expr, and both are legitimate inputs -- assign.ss keeps
      ;; two named entry points for the same reason, which is the tidier answer
      ;; and would rename a function every test in this tree calls.
      (define (Program prog)
        (nanopass-case (Lanf Program) prog
          [(top ([,x* ,e*] ...) (,x2* ...) ,body)
           (for-each bind! x*)
           (for-each (lambda (nm rhs)
                       (nanopass-case (Lanf Expr) rhs
                         [(lambda (,x1* ...) ,body1)
                          (hashtable-set! lam nm (cons x1* body1))
                          (for-each bind! x1*)
                          (Expr body1 nm)]
                         [else (Expr rhs #f)]))
                     x* e*)
           (Expr body #f)]
          [else (Expr prog #f)]))
      (Program e)
      (let ([procs (make-eq-hashtable)])
        (vector-for-each
         (lambda (nm)
           (when (and (= 1 (hashtable-ref binds nm 0))
                      (not (hashtable-ref nonop nm #f)))
             (let ([pb (hashtable-ref lam nm #f)])
               (hashtable-set! procs nm
                               (make-proc (car pb) (cdr pb) (expr-size (cdr pb))
                                          (hashtable-ref sites nm 0))))))
         (hashtable-keys lam))
        (values procs (self-reaching procs calls)))))

  ;; Transitive closure of the call graph, then ask each procedure whether it
  ;; can reach itself. Direct recursion and mutual recursion fall out together.
  (define (self-reaching procs calls)
    (let ([rec (make-eq-hashtable)])
      (vector-for-each
       (lambda (nm)
         (let loop ([work (hashtable-ref calls nm '())] [seen '()])
           (cond
            [(null? work) (void)]
            [(memq (car work) seen) (loop (cdr work) seen)]
            [(eq? (car work) nm) (hashtable-set! rec nm #t)]
            [else (loop (append (hashtable-ref calls (car work) '()) (cdr work))
                        (cons (car work) seen))])))
       (hashtable-keys procs))
      rec))

  ;; --- alpha renaming ------------------------------------------------------
  ;; Every binder in the copy gets a new name; free variables pass through
  ;; unchanged. `sub` starts as the parameter-to-actual map, which is what makes
  ;; the substitution variable-for-variable and therefore effect-free.

  (define (rn x sub) (cond [(assq x sub) => cdr] [else x]))

  (define (freshen e sub)
    (with-output-language (Lanf Expr)
      (nanopass-case (Lanf Expr) e
        [,x (let ([x (rn x sub)]) `,x)]
        [(quote ,d) `(quote ,d)]
        [(if ,x ,e0 ,e1)
         (let ([x (rn x sub)]) `(if ,x ,(freshen e0 sub) ,(freshen e1 sub)))]
        [(seq ,e0 ,e1) `(seq ,(freshen e0 sub) ,(freshen e1 sub))]
        [(let ([,x ,se]) ,body)
         ;; The right-hand side is renamed under the OLD substitution: a `let`
         ;; does not scope over its own initializer.
         (let* ([se1 (freshen-se se sub)]
                [x1 (fresh x)]
                [sub1 (cons (cons x x1) sub)])
           `(let ([,x1 ,se1]) ,(freshen body sub1)))]
        [(tailcall ,x ,x* ...)
         (let ([x (rn x sub)] [x* (map (lambda (a) (rn a sub)) x*)])
           `(tailcall ,x ,x* ...))]
        [(lambda (,x* ...) ,body)
         (let* ([x1* (map fresh x*)]
                [sub1 (append (map cons x* x1*) sub)])
           `(lambda (,x1* ...) ,(freshen body sub1)))]
        [(letrec ([,x* ,e*] ...) ,body)
         (let* ([x1* (map fresh x*)]
                [sub1 (append (map cons x* x1*) sub)]
                [e1* (map (lambda (r) (freshen r sub1)) e*)])
           `(letrec ([,x1* ,e1*] ...) ,(freshen body sub1)))]
        [(declare ([,x* ,prem*] ...) ,body)
         (let ([x1* (map (lambda (a) (rn a sub)) x*)])
           `(declare ([,x1* ,prem*] ...) ,(freshen body sub)))]
        ;; NOT an `else` case, and the difference is name capture. Falling
        ;; through returns the node UNCHANGED -- every binder inside it keeps
        ;; its original name, so the copy and the original share names and the
        ;; program has two definitions of one variable. It was unreachable only
        ;; because this pass never matched a real program at all (see the note
        ;; on `Expr`); the unroller reaches it.
        ;;
        ;; Like `declare`, this NAMES existing variables rather than binding
        ;; them, so the names are renamed through the substitution and the body
        ;; is freshened under the same one.
        [(declare-distinct (,x* ...) ,body)
         (let ([x1* (map (lambda (a) (rn a sub)) x*)])
           `(declare-distinct (,x1* ...) ,(freshen body sub)))]
        [(policy ([,pn* ,b*] ...) ,body)
         `(policy ([,pn* ,b*] ...) ,(freshen body sub))]
        [else e])))

  (define (freshen-se se sub)
    (with-output-language (Lanf SimpleExpr)
      (nanopass-case (Lanf SimpleExpr) se
        [,x (let ([x (rn x sub)]) `,x)]
        [(quote ,d) `(quote ,d)]
        [(lambda (,x* ...) ,body)
         (let* ([x1* (map fresh x*)]
                [sub1 (append (map cons x* x1*) sub)])
           `(lambda (,x1* ...) ,(freshen body sub1)))]
        [(call ,x ,x* ...)
         (let ([x (rn x sub)] [x* (map (lambda (a) (rn a sub)) x*)])
           `(call ,x ,x* ...))]
        [(primcall ,pr ([,pn* ,c*] ...) ,x* ...)
         (let ([x* (map (lambda (a) (rn a sub)) x*)])
           `(primcall ,pr ([,pn* ,c*] ...) ,x* ...))]
        [else se])))

  ;; --- splicing a continuation onto an inlined body ------------------------
  ;; Rewrites the single tail position of `b` into `(let ([r <tail>]) k)`. This
  ;; is the step that keeps the ANF invariant: the inlined body's result is
  ;; named by exactly the binding the original call's result was named by.
  ;;
  ;; A `tailcall` in the callee becomes an ordinary `call` in the caller, which
  ;; is the correct reading: the frame the tail call was going to reuse is now
  ;; the caller's, and it still has `k` left to run.

  (define (splice b r k)
    (with-output-language (Lanf Expr)
      (nanopass-case (Lanf Expr) b
        [,x `(let ([,r ,x]) ,k)]
        [(quote ,d) `(let ([,r (quote ,d)]) ,k)]
        [(lambda (,x* ...) ,body)
         (let ([l (with-output-language (Lanf SimpleExpr) `(lambda (,x* ...) ,body))])
           `(let ([,r ,l]) ,k))]
        [(tailcall ,x ,x* ...)
         (let ([c (with-output-language (Lanf SimpleExpr) `(call ,x ,x* ...))])
           `(let ([,r ,c]) ,k))]
        [(let ([,x ,se]) ,body) `(let ([,x ,se]) ,(splice body r k))]
        [(seq ,e0 ,e1) `(seq ,e0 ,(splice e1 r k))]
        [(letrec ([,x* ,e*] ...) ,body) `(letrec ([,x* ,e*] ...) ,(splice body r k))]
        [(declare ([,x* ,prem*] ...) ,body) `(declare ([,x* ,prem*] ...) ,(splice body r k))]
        [(declare-distinct (,x* ...) ,body) `(declare-distinct (,x* ...) ,(splice body r k))]
        [(policy ([,pn* ,b*] ...) ,body) `(policy ([,pn* ,b*] ...) ,(splice body r k))]
        ;; Unreachable: rule 5 checked tail-count = 1 before we got here. If it
        ;; fires, the check and this walk have drifted apart.
        [else (error 'splice "more than one tail position" (unparse-Lanf b))])))

  ;; --- the pass ------------------------------------------------------------

  (define (inline-program e)
    (let-values ([(out report) (inline-program/report e)]) out))

  ;; Second value is the list of procedure names inlined, in the order the
  ;; decisions were taken. Reported rather than counted internally, because the
  ;; number this pass is judged on is a measurement downstream and the only
  ;; honest thing to hand upward is what it actually did.
  (define (inline-program/report e)
    (let-values ([(procs recursive) (scan e)])
      (let ([report '()])

        ;; RULE 6. A TAIL call site may not receive a body that tail-calls
        ;; something wider than the enclosing procedure.
        ;;
        ;; A tail call writes its stack arguments over the enclosing procedure's
        ;; INCOMING argument area, because the jump pushes no return address and
        ;; the callee reads its arguments exactly where the caller's were. That
        ;; is sound only while the callee needs no more words than this procedure
        ;; received; needing more means writing past that area into the caller's
        ;; caller's live frame, and finalize.ss refuses it rather than emitting
        ;; the write. Growing the stack instead needs a frame shuffle this
        ;; compiler does not have, and could not simply be added: in a cycle of
        ;; mutually tail-calling procedures a per-call growth never unwinds.
        ;;
        ;; nbody reaches this immediately. `energy` takes three arguments and
        ;; tail-calls `energy-from` with five; x86-64 has two tagged argument
        ;; registers, so the fifth rides on the stack, and inlining `energy` into
        ;; a narrower procedure asks for exactly the write that is refused.
        ;;
        ;; ARITY IS A PROXY for stack words, deliberately. What actually decides
        ;; is how many arguments overflow their class's registers, which depends
        ;; on storage classes that repr.ss has not assigned yet. Comparing counts
        ;; is conservative in the safe direction: it refuses some inlines that
        ;; would have fit, and admits none that would not.
        (define (tail-fits? p)
          (<= (max-tail-arity (proc-body p)) (current-arity)))

        (define (candidate? f nargs stack)
          (let ([p (hashtable-ref procs f #f)])
            (and p
                 (= (length (proc-params p)) nargs)
                 (not (memq f stack))                       ; rule 3
                 (not (hashtable-ref recursive f #f))       ; rule 4
                 (or (<= (proc-size p) (inline-size-budget))
                     (= 1 (proc-sites p)))
                 (< (length stack) (inline-depth-budget))
                 p)))

        ;; The freshened, already-transformed body of a call to f with actuals
        ;; a*, or #f if f is not a candidate.
        (define (expand f a* stack)
          (let ([p (candidate? f (length a*) stack)])
            (and p
                 (let ([b (freshen (proc-body p) (map cons (proc-params p) a*))])
                   (Expr b (cons f stack))))))

        (define (Expr e stack)
          (with-output-language (Lanf Expr)
            (nanopass-case (Lanf Expr) e
              [,x e]
              [(quote ,d) e]
              [(if ,x ,e0 ,e1) `(if ,x ,(Expr e0 stack) ,(Expr e1 stack))]
              [(seq ,e0 ,e1) `(seq ,(Expr e0 stack) ,(Expr e1 stack))]
              [(let ([,x ,se]) ,body)
               (let ([k (Expr body stack)])
                 (or (try-let x se k stack)
                     `(let ([,x ,(SimpleExpr se stack)]) ,k)))]
              [(tailcall ,x ,x* ...)
               (let* ([p (hashtable-ref procs x #f)]
                      [b (and p (tail-fits? p) (expand x x* stack))])
                 (cond [b (set! report (cons x report)) b]
                       [else e]))]
              [(lambda (,x* ...) ,body)
               `(lambda (,x* ...)
                  ,(parameterize ([current-arity (length x*)])
                     (Expr body stack)))]
              [(letrec ([,x* ,e*] ...) ,body)
               (let ([e1* (map (lambda (r) (Expr r stack)) e*)])
                 `(letrec ([,x* ,e1*] ...) ,(Expr body stack)))]
              [(declare ([,x* ,prem*] ...) ,body)
               `(declare ([,x* ,prem*] ...) ,(Expr body stack))]
              [(declare-distinct (,x* ...) ,body)
               `(declare-distinct (,x* ...) ,(Expr body stack))]
              [(policy ([,pn* ,b*] ...) ,body)
               `(policy ([,pn* ,b*] ...) ,(Expr body stack))]
              [else e])))

        ;; Rule 5 is checked on the body AFTER it has itself been inlined into,
        ;; not before. Inlining a conditional callee into the tail of this one
        ;; turns one tail position into two, and checking the original body
        ;; would miss that and hand `splice` something it cannot rewrite.
        (define (try-let r se k stack)
          (nanopass-case (Lanf SimpleExpr) se
            [(call ,x ,x* ...)
             ;; The expansion is speculative, so the report has to roll back
             ;; with it. Otherwise a refused inline still shows up as one.
             (let ([saved report])
               (let ([b (expand x x* stack)])
                 (cond [(and b (= 1 (tail-count b)))
                        (set! report (cons x report))
                        (splice b r k)]
                       [else (set! report saved) #f])))]
            [else #f]))

        (define (SimpleExpr se stack)
          (with-output-language (Lanf SimpleExpr)
            (nanopass-case (Lanf SimpleExpr) se
              [(lambda (,x* ...) ,body)
             `(lambda (,x* ...)
                ,(parameterize ([current-arity (length x*)]) (Expr body stack)))]
              [else se])))

        (define (Program prog)
          (nanopass-case (Lanf Program) prog
            [(top ([,x* ,e*] ...) (,x2* ...) ,body)
             (let ([e1* (map (lambda (r) (Expr r '())) e*)])
               (with-output-language (Lanf Program)
                 `(top ([,x* ,e1*] ...) (,x2* ...) ,(Expr body '()))))]
            [else (Expr prog '())]))

        (let ([out (Program e)])
          (values out (reverse report))))))
  )
