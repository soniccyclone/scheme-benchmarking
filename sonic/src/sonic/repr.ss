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
          prim-result-class datum-class
          parameter-classes
          repr-report repr-report? repr-report-counts repr-report-classes)
  (import (chezscheme) (nanopass) (sonic lang))

  (define-record-type (repr-report make-repr-report repr-report?)
    (fields counts          ; ((class . n) ...)
            classes))       ; vreg -> storage class, INCLUDING parameters

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
    (cond ((memq pr fixnum-word-prims) 'fixnum)
          ((memq pr boolean-word-prims) 'boolean)
          (else #f)))

  (define tagged-prims
    '(make-flvector make-vector vector-ref cons car cdr error))

  ;; flvector-set! and vector-set! have no useful result; they are classified
  ;; raw-word so the unused destination does not pull a value register.
  (define effect-prims '(flvector-set! vector-set!))

  (define (prim-result-class pr)
    (cond ((memq pr f64-prims) 'raw-f64)
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
    (let ((classes (make-eq-hashtable))     ; vreg -> class
          (params  (make-eq-hashtable))     ; procedure -> (param ...)
          (bodies  (make-eq-hashtable))     ; procedure -> body expr
          (results (make-eq-hashtable))     ; procedure -> result class
          (lets '())                        ; (x . simple-expr)
          (merges '())                      ; (x . (expr ...)) from phi/sigma
          (booleans (make-eq-hashtable))    ; raw words that hold 0/1, not a fixnum
          (sites '()))                      ; (name . (arg ...))

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
          ;; Answering `tagged` here regardless is what the join used to do, and
          ;; it is memory corruption rather than a wrong number: a comparison's
          ;; 0/1 lands in the VALUE class, and under D21 the collector scavenges
          ;; that unconditionally and chases address 0 or 1. So it raises, and
          ;; names the conversion that is missing.
          (when (hashtable-ref booleans v #f)
            (error 'select-representations
                   (string-append
                    "a boolean-valued raw word is being merged with a tagged "
                    "value, which needs the conversion (x << 3) | 7 to reach "
                    "sonic-false/sonic-true; no pass inserts representation "
                    "conversions yet, and answering `tagged` without one puts "
                    "0 or 1 in the value class for the collector to chase")
                   v a b))
          'tagged)
         (else
          (error 'select-representations
                 (string-append
                  "cannot merge these storage classes: a double and a "
                  "non-double have no common representation short of boxing "
                  "the double on the heap, which is a later bead")
                 v a b))))

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
                            'tagged))
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
                                 'tagged))
            ((primcall) (prim-result-class (cadr e)))
            ((lambda) 'tagged)
            ;; An unspecified value. Classified raw-word to match what lower.ss
            ;; materialises for it, and because it is not a pointer: putting it
            ;; in the value class would have the collector scavenge it.
            ((void) 'raw-word)
            ((set!) 'raw-word)
            (else #f)))))

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
            ((call tailcall) (set! sites (cons (cons (cadr x) (cddr x)) sites))))
          (for-each walk x)))

      ;; --- fixpoint ---
      ;;
      ;; Iterating is not an optimisation here, it is required. A loop is a
      ;; letrec whose tailcall passes the loop variable back to itself, so the
      ;; argument in position i IS the parameter in position i, and a single
      ;; pass would ask for a class still being computed. Classes are only ever
      ;; joined upward, and the lattice has three points, so it settles.
      (let fix ()
        (let ((changed #f))
          (for-each (lambda (l)
                      (when (note! (car l) (class-of-simple (cdr l)))
                        (set! changed #t)))
                    lets)
          (for-each (lambda (m)
                      (for-each (lambda (op)
                                  (when (note! (car m) (tail-class op))
                                    (set! changed #t)))
                                (cdr m)))
                    merges)
          (vector-for-each
           (lambda (f)
             (when (note-into! results f (tail-class (hashtable-ref bodies f #f)))
               (set! changed #t)))
           (hashtable-keys bodies))
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
          (when changed (fix))))
      classes))

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
          [known (if (pair? opt) (car opt) (parameter-classes (unparse-Lssa e)))])
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
               (error 'select-representations
                      (string-append
                       "no storage class for this binding; classifying it "
                       "wrongly would either lose a GC root or put a double in "
                       "an integer register, and there is no safe default")
                      x)])))
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
                 known)))))

  (define (select-representations-program p)
    (nanopass-case (Lssa Program) p
      [(top ([,x* ,e*] ...) (,x2* ...) ,body)
       (let ([total (make-eq-hashtable)]
             ;; ONE fixpoint over the whole program. Per-binding would be
             ;; wrong: a call crosses top-level bindings, so the class of what
             ;; a procedure returns is not derivable from the binding that
             ;; contains the call.
             [known (parameter-classes (unparse-Lssa p))])
         (define (one e)
           (let-values ([(e^ rpt) (select-representations e known)])
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
                      known)))))]))
  )
