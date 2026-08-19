;;; Loop unrolling over Lanf.
;;;
;;; A loop in this compiler is a letrec-bound procedure that tail-calls itself.
;;; Unrolling it by two is exactly one thing: replacing that self tail call with
;;; a copy of the body.
;;;
;;;     (letrec ([loop (lambda (i acc)
;;;                      (if (< i n) (loop (+ i 1) (f acc i)) acc))])
;;;       ...)
;;;
;;; becomes
;;;
;;;     (letrec ([loop (lambda (i acc)
;;;                      (if (< i n)
;;;                          (if (< i+1 n) (loop (+ i+2 ...) ...) acc')
;;;                          acc))])
;;;       ...)
;;;
;;; The guard comes for free, because the body being copied already contains its
;;; own exit test. NO TRIP COUNT IS NEEDED and none is consulted: this is correct
;;; for a loop that runs zero times, an odd number of times, or a number nobody
;;; can compute.
;;;
;;; ## Why it is worth doing at all
;;;
;;; Measured, on nbody: we issue 392 integer ops per step against `gcc -O3
;;; -march=native`'s 23.8, for the same arithmetic. Reading gcc's output explains
;;; the 24 -- it did not write tighter loop control, it DELETED the loop. `main`
;;; contains four separate `vsqrtsd` sites because the pair loop was fully
;;; unrolled, and every access became a constant displacement off one base
;;; register. No counter, no bound, no index scaling, no back edge.
;;;
;;; Everything a loop pays per iteration -- the compare, the branch, the counter
;;; increment, the index scaling, and the parallel copy on the back edge -- is
;;; paid once per unrolled body instead of once per iteration.
;;;
;;; ## Why this is not inline.ss
;;;
;;; That pass refuses recursive procedures by rule 4, and its header says why:
;;; unrolling has a different cost model. Its rule 3 (a procedure already being
;;; inlined is refused) is the termination proof and is deliberately independent
;;; of rule 4, so that relaxing rule 4 could not make THAT pass diverge.
;;;
;;; This pass does not need rule 3, because it does not recurse into the copy it
;;; makes. The copy is inserted verbatim and never rescanned, so exactly one
;;; unroll happens and termination is immediate rather than argued.
;;;
;;; ## Only tail positions
;;;
;;; The walk that finds the self call visits the body's TAIL POSITIONS only. A
;;; `tailcall` is by construction in tail position, so nothing is missed; and a
;;; lambda nested inside the body sits in a `SimpleExpr`, which the walk never
;;; enters. That matters: a call to the loop from a nested lambda is an ordinary
;;; call, not a back edge, and copying the body there would be inlining under
;;; another name.
;;;
;;; ## What makes the copy safe
;;;
;;; `freshen` renames every binder in the copy, so the two bodies share no names.
;;; Substituting the parameters by the call's actuals cannot duplicate work,
;;; because Lanf operands are already ATOMS -- a parameter is replaced by a
;;; variable, never by the expression that computed it. That is the same property
;;; inline.ss relies on and the reason both passes want ANF rather than a general
;;; term language.

(library (sonic unroll)
  (export unroll-program unroll-program/report unroll-size-budget
          unroll-stats unroll-stats? unroll-stats-unrolled unroll-stats-names)
  (import (chezscheme) (nanopass) (sonic lang) (sonic inline))

  ;; The NAMES as well as the count. A pass that unrolls three loops and buys
  ;; nothing has either unrolled the wrong three or unrolled nothing hot, and the
  ;; count alone cannot tell those apart -- which cost one measurement to learn.
  (define-record-type (unroll-stats make-unroll-stats unroll-stats?)
    (fields (mutable unrolled) (mutable names)))

  ;; A loop body is two orders of magnitude larger than anything inline.ss will
  ;; take (its budget is 12 nodes), because a loop body is a whole computation
  ;; rather than an accessor. nbody's pairwise force loop is a little over 300
  ;; Lanf nodes and its enclosing loop over 800, both of which are ordinary
  ;; hand-written loops.
  ;;
  ;; So the ceiling is not tuned -- it is set above anything a person writes as
  ;; one loop, and exists to refuse machine-generated bodies where doubling the
  ;; code would cost more in instruction cache than the loop control it saves.
  ;; Every loop in these benchmarks is admitted, and raising it further changes
  ;; nothing: measured, 1000 and 5000 produce identical programs.
  (define unroll-size-budget (make-parameter 0))

  ;; Does `body` tail-call `f`? Tail positions only -- see the header.
  (define (self-tail-recursive? f body)
    (let walk ((e body))
      (nanopass-case (Lanf Expr) e
        [(tailcall ,x ,x* ...) (eq? x f)]
        [(if ,x ,e0 ,e1) (or (walk e0) (walk e1))]
        [(seq ,e0 ,e1) (walk e1)]
        [(let ([,x ,se]) ,body) (walk body)]
        [(letrec ([,x* ,e*] ...) ,body) (walk body)]
        [(declare ([,x* ,prem*] ...) ,body) (walk body)]
        ;; NOT optional. Every procedure whose parameters were declared distinct
        ;; -- which in nbody is every kernel taking vectors -- has its whole body
        ;; wrapped in one, so omitting it makes this predicate answer #f for
        ;; exactly the loops worth unrolling. It cost one measurement.
        [(declare-distinct (,x* ...) ,body) (walk body)]
        [(policy ([,pn* ,b*] ...) ,body) (walk body)]
        [else #f])))

  ;; Replace every self tail call in `body` with a freshened copy of `body`.
  ;;
  ;; `original` is captured before any rewriting and the copy is NOT rescanned,
  ;; which is the whole termination argument: each self call is expanded once and
  ;; the copy's own self call is left as the new back edge.
  (define (unroll-body f params body)
    (let replace ((e body))
      (with-output-language (Lanf Expr)
        (nanopass-case (Lanf Expr) e
          [(tailcall ,x ,x* ...)
           (if (eq? x f)
               (freshen body (map cons params x*))
               e)]
          [(if ,x ,e0 ,e1) `(if ,x ,(replace e0) ,(replace e1))]
          ;; only the second half of a seq is in tail position
          [(seq ,e0 ,e1) `(seq ,e0 ,(replace e1))]
          [(let ([,x ,se]) ,body) `(let ([,x ,se]) ,(replace body))]
          [(letrec ([,x* ,e*] ...) ,body)
           `(letrec ([,x* ,e*] ...) ,(replace body))]
          [(declare ([,x* ,prem*] ...) ,body)
           `(declare ([,x* ,prem*] ...) ,(replace body))]
          [(declare-distinct (,x* ...) ,body)
           `(declare-distinct (,x* ...) ,(replace body))]
          [(policy ([,pn* ,b*] ...) ,body)
           `(policy ([,pn* ,b*] ...) ,(replace body))]
          [else e]))))

  (define (unroll-program e)
    (let-values (((out st) (unroll-program/report e))) out))

  ;; THE INPUT IS A Program, NOT AN Expr, and that distinction is D32.
  ;;
  ;; Lcore grew `(top ([x* e*] ...) (x2* ...) body)` so the expander had
  ;; somewhere to put top-level definitions. A pass that pattern-matches only on
  ;; Expr therefore matches NOTHING a real program presents, falls through its
  ;; `else`, and returns its input unchanged while reporting success. Five passes
  ;; had this exact defect before; this one had it too, for one measurement.
  ;;
  ;; The top-level bindings are walked as BINDINGS rather than as expressions,
  ;; because a top-level procedure that tail-calls itself is a loop in precisely
  ;; the sense this pass means -- nbody's `subtract-pairs` and `energy-from` both
  ;; are -- and reaching them requires knowing the name each body is bound to.
  (define (unroll-program/report prog)
    (let ((stats (make-unroll-stats 0 '())))

      ;; A letrec binding that is a self-tail-recursive lambda within budget.
      ;; Nothing requires the name to be KNOWN in inline.ss's sense: this rewrites
      ;; the procedure's own body and removes nothing, so who else calls it does
      ;; not enter into it.
      ;; A letrec's right-hand sides are Exprs, not SimpleExprs: Lanf moves
      ;; `lambda` INTO SimpleExpr without removing it from Expr, so a letrec-bound
      ;; procedure is the Expr production.
      (define (Binding nm rhs)
        (with-output-language (Lanf Expr)
          (nanopass-case (Lanf Expr) rhs
            [(lambda (,x* ...) ,body)
             (let ((body (Expr body)))
               (if (and (self-tail-recursive? nm body)
                        (<= (expr-size body) (unroll-size-budget)))
                   (begin
                     (unroll-stats-unrolled-set!
                      stats (+ 1 (unroll-stats-unrolled stats)))
                     (unroll-stats-names-set!
                      stats (cons nm (unroll-stats-names stats)))
                     `(lambda (,x* ...) ,(unroll-body nm x* body)))
                   `(lambda (,x* ...) ,body)))]
            [else (Expr rhs)])))

      (define (SimpleExpr se)
        (with-output-language (Lanf SimpleExpr)
          (nanopass-case (Lanf SimpleExpr) se
            [(lambda (,x* ...) ,body) `(lambda (,x* ...) ,(Expr body))]
            [else se])))

      (define (Expr e)
        (with-output-language (Lanf Expr)
          (nanopass-case (Lanf Expr) e
            [(if ,x ,e0 ,e1) `(if ,x ,(Expr e0) ,(Expr e1))]
            [(seq ,e0 ,e1) `(seq ,(Expr e0) ,(Expr e1))]
            [(let ([,x ,se]) ,body) `(let ([,x ,(SimpleExpr se)]) ,(Expr body))]
            [(lambda (,x* ...) ,body) `(lambda (,x* ...) ,(Expr body))]
            [(letrec ([,x* ,e*] ...) ,body)
             (let ((e1* (map Binding x* e*)))
               `(letrec ([,x* ,e1*] ...) ,(Expr body)))]
            [(declare ([,x* ,prem*] ...) ,body)
             `(declare ([,x* ,prem*] ...) ,(Expr body))]
            [(declare-distinct (,x* ...) ,body)
             `(declare-distinct (,x* ...) ,(Expr body))]
            [(policy ([,pn* ,b*] ...) ,body)
             `(policy ([,pn* ,b*] ...) ,(Expr body))]
            [else e])))

      (define (Program prog)
        (with-output-language (Lanf Program)
          (nanopass-case (Lanf Program) prog
            [(top ([,x* ,e*] ...) (,x2* ...) ,body)
             (let ((e1* (map Binding x* e*)))
               `(top ([,x* ,e1*] ...) (,x2* ...) ,(Expr body)))])))

      (values (Program prog) stats)))
  )
