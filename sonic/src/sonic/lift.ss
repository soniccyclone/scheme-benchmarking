;;; Lambda lifting: a nested procedure's free variables become its parameters.
;;;
;;; A named `let loop` becomes a letrec-bound lambda, and a letrec-bound lambda
;;; becomes its own FUNCTION -- something calls it, so it is a call target, so
;;; `partition-into-functions` gives it its own register allocation. Its free
;;; variables were left as bare vregs, which means it read them out of registers
;;; the ENCLOSING function had allocated. Two independent allocations agree only
;;; by coincidence.
;;;
;;; The coincidence is what made this hard to find. A capturing loop with two
;;; parameters works; the same loop with four traps, because the extra live
;;; values push the two allocations apart. Identical computation:
;;;
;;;   (define (om v m)
;;;     (let loop ((i 0) (px 0.0) (py 0.0) (pz 0.0))   ; captures v, m
;;;       ...))                                        -> bounds trap
;;;
;;;   (define (loop2 v m i px py pz) ...)              ; lifted by hand
;;;   (define (om v m) (loop2 v m 0 0.0 0.0 0.0))      -> correct
;;;
;;; This pass does the second mechanically.
;;;
;;; ## Why lifting and not closure conversion
;;;
;;; Closure conversion is the general answer and is not needed here. Every
;;; procedure in this compiler is top-level or letrec-bound and every call names
;;; it directly, so no procedure escapes and there is nothing to allocate a
;;; closure for. Lifting is the whole job until first-class procedures arrive,
;;; and it costs nothing at run time: the free variables were already live
;;; across the call, so passing them explicitly moves no more data than the
;;; caller was already keeping alive.
;;;
;;; ## The fixpoint
;;;
;;; Lifting one lambda can make a variable free in an ENCLOSING one. If `inner`
;;; captures `v` from `om` and `outer` calls `inner`, then once `inner` takes
;;; `v` as a parameter, `outer`'s call to it mentions `v` -- so `v` is now free
;;; in `outer` and `outer` must take it too. One pass is not enough, and stopping
;;; early leaves exactly the bug this pass exists to remove.
;;;
;;; ## Why names need no freshening
;;;
;;; essa.ss makes every binding unique across the whole program, so a free `v`
;;; inside the loop IS the same name as `v` in the enclosing procedure. Adding
;;; it as a parameter therefore keeps the same name, and the storage-class table
;;; already has an entry for it. That is the one thing that makes this pass
;;; small: no renaming, and no reclassification.

(library (sonic lift)
  (export lift-program free-variables
          lifted-report lifted-report? lifted-report-lifted lifted-report-rounds)
  (import (chezscheme)
          (sonic order))

  (define-record-type (lifted-report make-lifted-report lifted-report?)
    (fields lifted        ; ((procedure . (added ...)) ...)
            rounds))      ; how many times the fixpoint went round

  ;; --- sets, as ordered lists ------------------------------------------------
  ;;
  ;; ORDER MATTERS and must be deterministic: the added parameters have to line
  ;; up with what the rewritten call sites pass, and a hashtable's key order is
  ;; not a promise. So these are lists, kept in first-seen order.

  (define (adjoin x s) (if (memq x s) s (append s (list x))))
  (define (union a b) (fold-left (lambda (acc x) (adjoin x acc)) a b))
  (define (without s xs) (filter (lambda (x) (not (memq x xs))) s))

  ;; --- free variables --------------------------------------------------------

  (define (free-variables e bound)
    (let fv ((e e) (bound bound) (acc '()))
      (cond
       ((symbol? e) (if (memq e bound) acc (adjoin e acc)))
       ((not (pair? e)) acc)
       (else
        (case (car e)
          ((quote) acc)
          ((void) acc)
          ;; Lrepr: (let ([x sc se]) body). Lssa: (let ([x se]) body).
          ((let)
           (let* ((b (car (cadr e)))
                  (x (car b))
                  (se (if (= (length b) 3) (caddr b) (cadr b))))
             (fv (caddr e) (cons x bound) (fv se bound acc))))
          ((lambda)
           (fv (caddr e) (append (cadr e) bound) acc))
          ((if)
           (fv (cadddr e) bound (fv (caddr e) bound (fv (cadr e) bound acc))))
          ((seq)
           (fv (caddr e) bound (fv (cadr e) bound acc)))
          ((call tailcall)
           ;; The callee is a reference too. It is removed later along with every
           ;; other procedure name; treating it as free here keeps this function
           ;; ignorant of which names are procedures.
           (fold-left (lambda (a x) (fv x bound a)) acc (cdr e)))
          ((primcall)
           (fold-left (lambda (a x) (fv x bound a)) acc (cdddr e)))
          ((letrec)
           (let ((names (map car (cadr e))))
             (let ((b* (append names bound)))
               (fv (caddr e) b*
                   (fold-left (lambda (a bnd) (fv (cadr bnd) b* a)) acc (cadr e))))))
          ((phi)
           ;; (phi ([x (pred val) ...] ...) body)
           (let ((names (map car (cadr e))))
             (fv (caddr e) (append names bound)
                 (fold-left
                  (lambda (a bnd)
                    (fold-left (lambda (a2 op) (fv (cadr op) bound a2)) a (cdr bnd)))
                  acc (cadr e)))))
          ((sigma)
           ;; (sigma x-out x-in pr x-other negated? body)
           (fv (list-ref e 6) (cons (cadr e) bound)
               (fv (list-ref e 4) bound (fv (caddr e) bound acc))))
          ((declare)
           ;; (declare ([x premise] ...) body): the x's are REFERENCES.
           (fv (caddr e) bound
               (fold-left (lambda (a bnd) (fv (car bnd) bound a)) acc (cadr e))))
          ((declare-distinct)
           (fv (caddr e) bound
               (fold-left (lambda (a x) (fv x bound a)) acc (cadr e))))
          ((policy)
           (fv (caddr e) bound acc))
          ((set!)
           (fv (caddr e) bound (fv (cadr e) bound acc)))
          (else acc))))))

  ;; --- the pass --------------------------------------------------------------

  ;; `form` is a `top` datum in either Lssa or Lrepr shape.
  (define (lift-program form)
    (unless (and (pair? form) (eq? (car form) 'top))
      (error 'lift-program "not a top-level program" form))
    (let* ((top-names (map car (cadr form)))
           (externs (caddr form))
           ;; What is never free: a top-level binding (it is a global, handled
           ;; by globals.ss), an extern (it has no definition here), and any
           ;; letrec-bound procedure (it is a label, and a call to it is a
           ;; direct branch rather than a value).
           (proc-names (collect-letrec-names form))
           (never-free (append top-names externs proc-names))
           (added (make-eq-hashtable)))     ; procedure -> (param ...)

      (define (added-for f) (hashtable-ref added f '()))

      ;; One round: recompute every procedure's added parameters under the
      ;; current answers, and report whether anything grew.
      (define (round!)
        (let ((changed #f))
          (let walk ((e form))
            (when (pair? e)
              (when (eq? (car e) 'letrec)
                (for-each
                 (lambda (bnd)
                   (let ((f (car bnd)) (v (cadr bnd)))
                     (when (and (pair? v) (eq? (car v) 'lambda))
                       (let* ((params (cadr v))
                              ;; The body is read with the CURRENT added
                              ;; parameters already spliced into every call, so
                              ;; a variable that became free because a callee
                              ;; was lifted is seen this round.
                              (body (rewrite-calls (caddr v)))
                              (fv (without (free-variables body params) never-free))
                              (old (added-for f)))
                         (unless (equal? fv old)
                           (set! changed #t)
                           (hashtable-set! added f fv))))))
                 (cadr e)))
              (for-each walk e)))
          changed))

      ;; Splice the added arguments into every call, without touching anything
      ;; else. Used both to compute free variables under the current answers and
      ;; to produce the final program.
      (define (rewrite-calls e)
        (cond
         ((not (pair? e)) e)
         ((memq (car e) '(call tailcall))
          (let* ((f (cadr e)) (extra (added-for f)))
            (append (list (car e) f) extra (map rewrite-calls (cddr e)))))
         ((eq? (car e) 'quote) e)
         (else (map rewrite-calls e))))

      ;; Add the parameters to each lambda.
      (define (rewrite-lambdas e)
        (cond
         ((not (pair? e)) e)
         ((eq? (car e) 'quote) e)
         ((eq? (car e) 'letrec)
          (list 'letrec
                (map (lambda (bnd)
                       (let ((f (car bnd)) (v (cadr bnd)))
                         (if (and (pair? v) (eq? (car v) 'lambda))
                             (list f (list 'lambda
                                           (append (added-for f) (cadr v))
                                           (rewrite-lambdas (caddr v))))
                             (list f (rewrite-lambdas v)))))
                     (cadr e))
                (rewrite-lambdas (caddr e))))
         (else (map rewrite-lambdas e))))

      (let loop ((n 0))
        (if (and (round!) (< n 50))
            (loop (+ n 1))
            (begin
              (when (>= n 50)
                (error 'lift-program
                       "lambda lifting did not reach a fixpoint; a lifted parameter is making itself free"
                       n))
              (values (rewrite-lambdas (rewrite-calls form))
                      (make-lifted-report
                       (let ((acc '()))
                         (vector-for-each
                          (lambda (f)
                            (let ((ps (hashtable-ref added f '())))
                              (unless (null? ps) (set! acc (cons (cons f ps) acc)))))
                          (sorted-keys added))
                         acc)
                       n)))))))

  (define (collect-letrec-names form)
    (let ((acc '()))
      (let walk ((e form))
        (when (pair? e)
          (when (eq? (car e) 'letrec)
            (for-each (lambda (b)
                        (let ((v (cadr b)))
                          (when (and (pair? v) (eq? (car v) 'lambda))
                            (set! acc (adjoin (car b) acc)))))
                      (cadr e)))
          (for-each walk e)))
      acc))
  )
