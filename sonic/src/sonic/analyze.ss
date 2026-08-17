;;; SonicScheme: interval analysis over the core language.
;;;
;;; Stages 05 and 07-09, in prototype form. Takes a core-language program,
;;; runs the interval domain to a fixpoint with widening and narrowing, and
;;; reports for each vector reference whether its bounds check is provably dead.
;;;
;;; THE READER AND EXPANDER EXIST NOW. This header used to say "there is no
;;; reader and no expander yet", which recorded the deliberate ordering -- a
;;; reader is a solved problem and interval analysis is not, so this went first.
;;; That ordering held, and then E3 landed: read.ss and expand.ss are both
;;; written, tested (16 and 27 assertions), and imported by driver.ss.
;;;
;;; What is still true, and is the part that matters here, is that THIS PASS
;;; takes the core language directly as s-expressions. It does not go through
;;; the reader, and nothing upstream of the core language is its concern.
;;;
;;; Core language, A-normalized. Every intermediate is named, which is a
;;; PRECONDITION rather than a nicety: the analysis attaches an abstract value
;;; to each variable, so an unnamed subexpression has nowhere to hang its
;;; interval and the transfer functions cannot compose.
;;;
;;;   e ::= (const n)
;;;       | (var x)
;;;       | (let x e body)
;;;       | (if (cmp x y) e1 e2)          cmp: see below
;;;       | (prim op x y)                 op in + - *
;;;       | (vref v x)                    the reference whose check we want gone
;;;       | (loop x lo hi body)           x from lo below hi
;;;       | (begin e ...)
;;;
;;; A comparison is spelled either bare (< <= > >= =), which means the totally
;;; ordered one, or with its primitive name from lang.ss (fx< ... fl< ...). The
;;; flonum spellings are not decoration: an `fl` comparison's FALSE edge refines
;;; nothing, because NaN makes every comparison false and so the negation is
;;; true where the opposite ordering is not. `iv-refine` in (sonic interval)
;;; carries that rule; this file only says which edge it is on.
;;;
;;; `loop` is a primitive rather than sugar over letrec on purpose. The whole
;;; problem is proving a fact about the induction variable, and a loop form
;;; states the induction variable's range in the syntax where the analysis can
;;; see it. Recovering that from a general fixpoint is a later stage; making it
;;; visible first is how the useful case gets working early.

(library (sonic analyze)
  (export analyze-program
          env-empty env-ref env-set
          decision-site decision-index decision-eliminable? decision?)
  (import (rnrs base)
          (rnrs lists)
          (rnrs control)
          (rnrs records syntactic)
          (rnrs io simple)
          (sonic interval))

  (define-record-type (decision make-decision decision?)
    (fields site index eliminable?))

  ;; --- environments: variable -> interval ---------------------------------
  ;; Association lists. The programs are small and a hash table would obscure
  ;; the join, which has to walk both environments anyway.

  (define env-empty '())

  (define (env-ref env x)
    (let ((p (assq x env)))
      (if p (cdr p) iv-top)))          ; unknown variables are top, never bottom

  (define (env-set env x v) (cons (cons x v) env))

  (define (env-vars env) (map car env))

  (define (env-join a b)
    (let loop ((xs (append (env-vars a) (env-vars b))) (acc env-empty))
      (cond ((null? xs) acc)
            ((assq (car xs) acc) (loop (cdr xs) acc))
            (else (loop (cdr xs)
                        (env-set acc (car xs)
                                 (iv-join (env-ref a (car xs))
                                          (env-ref b (car xs)))))))))

  (define (env-widen old new)
    (let loop ((xs (append (env-vars old) (env-vars new))) (acc env-empty))
      (cond ((null? xs) acc)
            ((assq (car xs) acc) (loop (cdr xs) acc))
            (else (loop (cdr xs)
                        (env-set acc (car xs)
                                 (iv-widen (env-ref old (car xs))
                                           (env-ref new (car xs)))))))))

  (define (env-equal? a b)
    (let ((xs (append (env-vars a) (env-vars b))))
      (for-all (lambda (x)
                 (let ((u (env-ref a x)) (v (env-ref b x)))
                   (and (iv-leq u v) (iv-leq v u))))
               xs)))

  ;; --- abstract evaluation -------------------------------------------------

  (define (eval-atom e env)
    (cond ((eq? (car e) 'const) (iv-const (cadr e)))
          ((eq? (car e) 'var) (env-ref env (cadr e)))
          (else (error 'eval-atom "not an atom" e))))

  ;; Refine both operands of a comparison on one edge of the branch. This is the
  ;; step cptypes cannot take at all, and it is where elision ultimately comes
  ;; from.
  ;;
  ;; WHAT THE EDGE MEANS IS NOT DECIDED HERE. `true?` says which edge we are on
  ;; and the comparison says what was written; `iv-refine` owns the conclusion,
  ;; because that conclusion depends on the operand type and gets the NaN case
  ;; wrong if it is spread over two files. The false edge of a flonum comparison
  ;; comes back unrefined, and that is the correct answer, not a gap.
  (define (refine env cmp x y true?)
    (let-values (((vx vy) (iv-refine cmp (not true?)
                                     (env-ref env x) (env-ref env y))))
      ;; (< i i) constrains one variable, not two, so the second env-set must
      ;; not simply overwrite the first.
      (if (eq? x y)
          (env-set env x (iv-meet vx vy))
          (env-set (env-set env x vx) y vy))))

  (define (apply-prim op a b)
    (cond ((eq? op '+) (iv-add a b))
          ((eq? op '-) (iv-sub a b))
          ((eq? op '*) (iv-mul a b))
          (else iv-top)))

  ;; Walk an expression, threading the environment and collecting decisions.
  ;; Returns (values interval env decisions).
  (define (walk e env decs lengths)
    (cond
     ((eq? (car e) 'const) (values (iv-const (cadr e)) env decs))
     ((eq? (car e) 'var)   (values (env-ref env (cadr e)) env decs))

     ((eq? (car e) 'prim)
      (values (apply-prim (cadr e)
                          (env-ref env (caddr e))
                          (env-ref env (cadddr e)))
              env decs))

     ((eq? (car e) 'let)
      (let-values (((v env1 decs1) (walk (caddr e) env decs lengths)))
        (walk (cadddr e) (env-set env1 (cadr e) v) decs1 lengths)))

     ((eq? (car e) 'begin)
      (let loop ((es (cdr e)) (env env) (decs decs) (last iv-top))
        (if (null? es)
            (values last env decs)
            (let-values (((v env1 decs1) (walk (car es) env decs lengths)))
              (loop (cdr es) env1 decs1 v)))))

     ((eq? (car e) 'if)
      (let* ((c (cadr e)) (cmp (car c)) (x (cadr c)) (y (caddr c)))
        (let-values (((v1 e1 d1) (walk (caddr e) (refine env cmp x y #t) decs lengths)))
          (let-values (((v2 e2 d2) (walk (cadddr e) (refine env cmp x y #f) d1 lengths)))
            (values (iv-join v1 v2) (env-join e1 e2) d2)))))

     ;; The elision decision. The check is dead when the index interval is
     ;; provably inside [0, len).
     ((eq? (car e) 'vref)
      (let* ((v (cadr e)) (x (caddr e))
             (idx (env-ref env x))
             (len (let ((p (assq v lengths)))
                    (if p (iv-const (cdr p)) iv-top))))
        (values iv-top env
                (cons (make-decision (list 'vref v x) idx (iv-within? idx len))
                      decs))))

     ;; (loop x lo hi body). x ranges over [lo, hi-1]. We still run the
     ;; fixpoint rather than trusting the syntax, because the body may assign
     ;; other variables whose intervals must converge, and widening is what
     ;; makes that terminate.
     ((eq? (car e) 'loop)
      (let* ((x (cadr e)) (lo (caddr e)) (hi (cadddr e)) (body (car (cddddr e)))
             (ivx (iv-range lo (- hi 1))))
        (let fix ((cur (env-set env x ivx)) (n 0))
          (if (> n 50)
              (error 'walk "fixpoint did not converge")
              (let-values (((v env1 _) (walk body cur '() lengths)))
                (let ((wid (env-set (env-widen cur (env-join cur env1)) x ivx)))
                  (if (env-equal? wid cur)
                      ;; Converged. Re-walk once with the stable environment so
                      ;; the decisions recorded are the ones that hold at the
                      ;; fixpoint, not the ones from an intermediate iterate.
                      (let-values (((v2 env2 decs2) (walk body cur decs lengths)))
                        (values iv-top env decs2))
                      (fix wid (+ n 1)))))))))

     (else (error 'walk "unknown form" e))))

  ;; lengths is an alist of vector-name . known-length
  (define (analyze-program e lengths)
    (let-values (((v env decs) (walk e env-empty '() lengths)))
      (reverse decs)))
  )
