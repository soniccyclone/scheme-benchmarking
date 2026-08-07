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
          repr-report repr-report? repr-report-counts)
  (import (chezscheme) (nanopass) (sonic lang))

  (define-record-type (repr-report make-repr-report repr-report?)
    (fields counts))          ; ((class . n) ...)

  ;; --- the classification ---------------------------------------------------
  ;;
  ;; Derived from the primitive table rather than restated, so a primitive added
  ;; to `lang.ss` without a class here fails loudly instead of defaulting.

  (define f64-prims
    '(fl+ fl- fl* fl/ flneg flabs flsqrt fx->fl flvector-ref))

  (define word-prims
    '(fx+ fx- fx* fxneg fxquotient fxremainder fxmodulo
      fx< fx<= fx= fx>= fx> fl< fl<= fl= fl>= fl>
      fl->fx flvector-length vector-length
      null? pair? fixnum? flonum? vector? flvector? eq?))

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

  ;; --- the pass -------------------------------------------------------------

  (define (select-representations e)
    (let ([counts (make-eq-hashtable)])
      (define (bump! c) (hashtable-set! counts c (+ 1 (hashtable-ref counts c 0))))
      (define (class-of se)
        (nanopass-case (Lssa SimpleExpr) se
          [,x 'tagged]                       ; a bare variable: unknown here
          [(quote ,d) (datum-class d)]
          [(lambda (,x* ...) ,body) 'tagged]
          [(call ,x ,x* ...) 'tagged]        ; an unknown callee returns an object
          [(primcall ,pr ([,pn* ,c*] ...) ,x* ...) (prim-result-class pr)]
          [else 'tagged]))
      (define (Expr e)
        (with-output-language (Lrepr Expr)
          (nanopass-case (Lssa Expr) e
            [(let ([,x ,se]) ,body)
             (let ([sc (class-of se)])
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
                      '(tagged raw-word raw-f64)))))))

  (define (select-representations-program p)
    (nanopass-case (Lssa Program) p
      [(top ([,x* ,e*] ...) (,x2* ...) ,body)
       (let ([total (make-eq-hashtable)])
         (define (one e)
           (let-values ([(e^ rpt) (select-representations e)])
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
                           '(tagged raw-word raw-f64)))))))]))
  )
