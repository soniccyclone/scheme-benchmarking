;;; Top-level bindings whose value is a literal become that literal.
;;;
;;; WHY. `globals.ss` makes every non-procedure top-level binding into STORAGE,
;;; read from memory at each use, and its header argued the cost lands outside
;;; the loops. D87 measured that and it is false: nbody's innermost pair loop
;;; reloads three globals per iteration.
;;;
;;; The larger cost is not the loads. `(define n-bodies 5)` is a global too, so
;;; `(fx< i n-bodies)` emits a register compare rather than `cmp $5`, no loop
;;; trip count is ever a constant, and nothing downstream can unroll -- which is
;;; where our 4.6x branch gap against gcc on nbody comes from. gcc flattens the
;;; same ten-iteration pair loop precisely because it knows the bound.
;;;
;;; ## Why this is sound, and why it is the CHEAP half
;;;
;;; A binding never targeted by `set!` has one value for the whole program's
;;; life, so substituting it is sound wherever it is not shadowed. `globals.ss`
;;; worried it would need an interprocedural "does this callee assign the cell"
;;; analysis; that is true for a binding that IS assigned, and unnecessary here.
;;; We compile whole programs, so "is this name ever a `set!` target" is a scan.
;;;
;;; This pass deliberately handles only a LITERAL initializer -- `(quote d)`.
;;; nbody's `solar-mass` is `(fl* 4.0 (fl* pi pi))`, a computation that folds to
;;; a constant only after `fold-program`, which runs later and on a different
;;; language. Doing the easy half first gets the trip counts, which is the part
;;; that unblocks unrolling; the folded half can come later and is `qaq.17`
;;; stage 2 along with pointer-valued globals.
;;;
;;; ## The binding STAYS
;;;
;;; Substitution removes the uses, not the definition. Dropping it here would
;;; mean reasoning about whether anything else in the pipeline still expects the
;;; name, for a saving of one store executed once at startup. Uses are what the
;;; loops pay for.
;;;
;;; ## Shadowing is the one real hazard
;;;
;;; `(let ((n-bodies 3)) ...)` binds a DIFFERENT n-bodies, and substituting the
;;; top-level literal inside it would be a wrong-code bug rather than a missed
;;; optimization. Every binding form removes its names from the substitution on
;;; the way into its body.

(library (sonic gconst)
  (export propagate-top-constants propagate-top-constants/report
          gconst-stats? gconst-stats-propagated gconst-stats-substituted)
  (import (chezscheme) (nanopass) (sonic lang))

  (define-record-type gconst-stats
    (fields (mutable propagated) (mutable substituted)))

  ;; `(quote d)` -> (list d), anything else -> #f. A LIST rather than the datum:
  ;; `(quote #f)` is a perfectly good literal whose datum is indistinguishable
  ;; from "not a literal" if returned bare.
  (define (literal-init e)
    (nanopass-case (Lcore Expr) e
      [(quote ,d) (list d)]
      [else #f]))

  ;; Every name appearing as a `set!` TARGET, anywhere. Unsound to miss one, so
  ;; every production is spelled out and there is no `else`: a production added
  ;; to Lcore later must be considered here rather than silently skipped, which
  ;; would let an assigned binding be treated as constant.
  (define (assigned-names e acc)
    (define (walk* es acc) (fold-left (lambda (a x) (walk x a)) acc es))
    (define (walk e acc)
      (nanopass-case (Lcore Expr) e
        [,x acc]
        [(quote ,d) acc]
        [(void) acc]
        [(set! ,x ,e0) (walk e0 (cons x acc))]
        [(if ,e0 ,e1 ,e2) (walk e2 (walk e1 (walk e0 acc)))]
        [(let ([,x* ,e*] ...) ,body) (walk body (walk* e* acc))]
        [(letrec ([,x* ,e*] ...) ,body) (walk body (walk* e* acc))]
        [(letrec* ([,x* ,e*] ...) ,body) (walk body (walk* e* acc))]
        [(lambda (,x* ...) ,body) (walk body acc)]
        [(call ,e0 ,e* ...) (walk* e* (walk e0 acc))]
        [(primcall ,pr ([,pn* ,c*] ...) ,e* ...) (walk* e* acc)]
        [(declare ([,x* ,prem*] ...) ,body) (walk body acc)]
        [(declare-distinct (,x* ...) ,body) (walk body acc)]
        [(policy ([,pn* ,b*] ...) ,body) (walk body acc)]
        [(begin ,e* ... ,e0) (walk e0 (walk* e* acc))]))
    (walk e acc))

  ;; --- the pass -------------------------------------------------------------

  (define (Expr e sub st)
    (with-output-language (Lcore Expr)
      ;; Entering a binding form: its names shadow the top level inside its body.
      (define (shadow x*)
        (let ([t (make-eq-hashtable)])
          (let-values ([(k v) (hashtable-entries sub)])
            (vector-for-each (lambda (k v) (hashtable-set! t k v)) k v))
          (for-each (lambda (x) (hashtable-delete! t x)) x*)
          t))
      (define (rec a) (Expr a sub st))
      (nanopass-case (Lcore Expr) e

        [,x (let ([hit (hashtable-ref sub x #f)])
              (if hit
                  (begin
                    (gconst-stats-substituted-set!
                     st (+ 1 (gconst-stats-substituted st)))
                    `(quote ,(car hit)))
                  e))]

        [(quote ,d) e]
        [(void) e]
        ;; The TARGET of a set! is a binding occurrence, not a use, and a name
        ;; reaching here is by construction not one we substitute.
        [(set! ,x ,e0) `(set! ,x ,(rec e0))]
        [(if ,e0 ,e1 ,e2) `(if ,(rec e0) ,(rec e1) ,(rec e2))]

        [(let ([,x* ,e*] ...) ,body)
         ;; Initializers are OUTSIDE the scope of the names being bound; the
         ;; body is inside. `let` is not `letrec`.
         (let ([inner (shadow x*)])
           `(let ([,x* ,(map rec e*)] ...) ,(Expr body inner st)))]
        [(letrec ([,x* ,e*] ...) ,body)
         (let ([inner (shadow x*)])
           `(letrec ([,x* ,(map (lambda (a) (Expr a inner st)) e*)] ...)
              ,(Expr body inner st)))]
        [(letrec* ([,x* ,e*] ...) ,body)
         (let ([inner (shadow x*)])
           `(letrec* ([,x* ,(map (lambda (a) (Expr a inner st)) e*)] ...)
              ,(Expr body inner st)))]
        [(lambda (,x* ...) ,body)
         `(lambda (,x* ...) ,(Expr body (shadow x*) st))]

        [(call ,e0 ,e* ...) `(call ,(rec e0) ,(map rec e*) ...)]
        [(primcall ,pr ([,pn* ,c*] ...) ,e* ...)
         `(primcall ,pr ([,pn* ,c*] ...) ,(map rec e*) ...)]
        [(declare ([,x* ,prem*] ...) ,body)
         `(declare ([,x* ,prem*] ...) ,(rec body))]
        [(declare-distinct (,x* ...) ,body)
         `(declare-distinct (,x* ...) ,(rec body))]
        [(policy ([,pn* ,b*] ...) ,body)
         `(policy ([,pn* ,b*] ...) ,(rec body))]
        [(begin ,e* ... ,e0) `(begin ,(map rec e*) ... ,(rec e0))]

        ;; No `else`, for the reason given on `assigned-names`.
        )))

  (define (propagate-top-constants/report prog)
    (nanopass-case (Lcore Program) prog
      [(top ([,x* ,e*] ...) (,x2* ...) ,body)
       (let* ([st (make-gconst-stats 0 0)]
              [assigned (fold-left (lambda (a e) (assigned-names e a))
                                   (assigned-names body '()) e*)]
              [sub (make-eq-hashtable)])
         (for-each
          (lambda (x e)
            (let ([lit (literal-init e)])
              (when (and lit (not (memq x assigned)))
                (gconst-stats-propagated-set!
                 st (+ 1 (gconst-stats-propagated st)))
                (hashtable-set! sub x lit))))
          x* e*)
         (let ([v* (map (lambda (e) (Expr e sub st)) e*)]
               [b (Expr body sub st)])
           (values (with-output-language (Lcore Program)
                     `(top ([,x* ,v*] ...) (,x2* ...) ,b))
                   st)))]))

  (define (propagate-top-constants prog)
    (let-values ([(p st) (propagate-top-constants/report prog)]) p))
  )
