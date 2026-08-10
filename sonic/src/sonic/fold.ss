;;; Constant folding over Lanf.
;;;
;;; The compiler did not have any. `(fx* 2 3)` emitted an `imul`, and so did
;;; `(let ([i 2]) (fx* i 3))`. That is worth fixing on its own -- it is the most
;;; basic optimisation there is -- but the reason it was FOUND is worth
;;; recording, because it says what this pass is for.
;;;
;;; ## Why it turned up now
;;;
;;; nbody's remaining gap to `gcc -O3 -march=native` is entirely integer: 370
;;; operations per step against 36. gcc's 36 is not tighter loop control, it is
;;; the ABSENCE of a loop -- it fully unrolled the ten-pair nest, and once `i`
;;; and `j` are literals every `bi = i*3` folds to a constant displacement.
;;;
;;; Unrolling without folding buys nothing: applying the existing x2 unroller
;;; repeatedly was measured at 16 -> 28 -> 36 `imul`s, growing rather than
;;; folding, because the counter stays symbolic on every path. Folding is the
;;; half that turns a substituted literal into a deleted instruction, so it has
;;; to exist before full unrolling is worth writing.
;;;
;;; ## What it folds
;;;
;;; A primcall whose operands are all literals, where the primitive is one this
;;; file can evaluate exactly. That is fixnum arithmetic and the fixnum
;;; comparisons -- nothing else, and the exclusions are deliberate:
;;;
;;;   - NO FLONUM ARITHMETIC. Folding `(fl+ 1.0 2.0)` means this pass and the
;;;     target must round identically, and the whole project rests on a
;;;     bit-exact oracle. Chez's flonums are IEEE binary64 and so are ours, so
;;;     it would probably agree -- "probably" is the wrong standard for the one
;;;     property everything else is measured against. D24 already refuses
;;;     contraction by default for a smaller version of this reason.
;;;
;;;   - NO DIVISION BY ZERO, and no folding of a quotient or remainder whose
;;;     divisor is zero: the program may be relying on the trap.
;;;
;;;   - NOTHING THAT OVERFLOWS. A fixnum here is 61 bits (numeric.ss): the range
;;;     is [-2^60, 2^60-1]. A fold whose result leaves that range is not a
;;;     constant this compiler can materialise, and silently producing a bignum
;;;     would be a wrong answer rather than a missed fold. The overflow CHECK on
;;;     the operation is a separate matter and elide.ss owns it; this pass just
;;;     declines the fold and leaves the instruction alone.
;;;
;;; ## Copy propagation, only for literals
;;;
;;; ANF names everything, so `(fx* i 3)` where `i` is bound to `2` is two
;;; bindings and the operand is a variable. This tracks let-bound variables
;;; whose right-hand side folded to a literal and substitutes them. It does NOT
;;; do general copy propagation -- a variable bound to another variable is left
;;; alone, because that is register allocation's business and this pass would
;;; only lengthen live ranges guessing at it.
;;;
;;; ## NO COMPARISONS, and the reason is a storage class rather than taste
;;;
;;; Folding `(fx< 1 2)` to `(quote #t)` looks like the obvious next step and it
;;; is a WRONG-CODE BUG. repr.ss classifies the fixnum comparisons as
;;; `raw-word` -- a boolean-valued machine word holding 0 or 1 -- while
;;; `datum-class` classifies the datum `#t` as `tagged`, because a Scheme
;;; boolean is the immediate numeric.ss calls sonic-true. Those are different
;;; representations in different register files, so the fold silently
;;; reclassifies the value.
;;;
;;; It does not fail where you would notice, either. Measured: nbody stopped
;;; compiling with `(vmulsd xmm8 xmm6 rbx)` -- a float multiply reading a
;;; VALUE-class register -- several passes downstream of the fold, because the
;;; class change propagated through repr.ss's fixpoint into an unrelated
;;; expression.
;;;
;;; Getting it right means folding to the raw-word 0/1 that the comparison
;;; would have produced, and checking that every consumer of a boolean agrees
;;; on which representation it is looking at. That is worth doing -- it unlocks
;;; deleting the branch, which is where the cascade lives -- and it is a
;;; separate change from this one.

(library (sonic fold)
  (export fold-program fold-stats fold-stats? fold-stats-folded fold-stats-branches)
  (import (chezscheme) (nanopass) (sonic lang))

  (define-record-type (fold-stats make-fold-stats fold-stats?)
    (fields (mutable folded) (mutable branches)))

  ;; numeric.ss: 61-bit fixnums, so [-2^60, 2^60-1].
  (define fx-greatest (- (expt 2 60) 1))
  (define fx-least (- (expt 2 60)))
  (define (fixnum-range? n) (and (exact? n) (integer? n) (<= fx-least n fx-greatest)))

  (define (int? d) (and (exact? d) (integer? d)))

  ;; The primitives this file can evaluate, and nothing else. Flonum arithmetic
  ;; is absent on purpose -- see the header.
  (define (fold-prim pr args)
    (define (all-int?) (for-all int? args))
    (define (a) (car args))
    (define (b) (cadr args))
    (define (arity n) (= (length args) n))
    (let ((v (cond
              ((not (all-int?)) #f)
              ((and (eq? pr 'fx+) (arity 2)) (+ (a) (b)))
              ((and (eq? pr 'fx-) (arity 2)) (- (a) (b)))
              ((and (eq? pr 'fx*) (arity 2)) (* (a) (b)))
              ((and (eq? pr 'fxneg) (arity 1)) (- (a)))
              ;; Division by zero is left alone: the program may want the trap.
              ((and (eq? pr 'fxquotient) (arity 2) (not (zero? (b))))
               (quotient (a) (b)))
              ((and (eq? pr 'fxremainder) (arity 2) (not (zero? (b))))
               (remainder (a) (b)))
              ((and (eq? pr 'fxmodulo) (arity 2) (not (zero? (b))))
               (modulo (a) (b)))
              (else #f))))
      ;; Wrapped so "did not fold" and a fold that produced 0 stay distinct.
      ;; The result must fit a fixnum, or the fold would invent a number the
      ;; compiler cannot materialise.
      (if (and (number? v) (fixnum-range? v)) (list v) #f)))

  (define (fold-program prog)
    (let-values (((out st) (fold-program/report prog))) out))

  ;; A FIXPOINT, not one sweep: folding one binding makes the next one's operand
  ;; a literal, and ANF chains them. Bounded because every round that changes
  ;; anything replaces a primcall with a literal and the program is finite.
  (define (fold-program/report prog)
    (let ((stats (make-fold-stats 0 0)))
      (let loop ((p prog) (round 0))
        (let* ((before (+ (fold-stats-folded stats) (fold-stats-branches stats)))
               (p1 (fold-once p stats)))
          (if (or (= before (+ (fold-stats-folded stats) (fold-stats-branches stats)))
                  (> round 8))
              (values p1 stats)
              (loop p1 (+ round 1)))))))

  (define (fold-once prog stats)
    ;; var -> the datum it is bound to, for variables whose binding folded to a
    ;; literal. Scoped by construction: Lanf is alpha-converted, so one table
    ;; over the whole program cannot confuse two bindings of one name.
    (let ((lits (make-eq-hashtable)))

      ;; WRAPPED for the same reason `fold-prim` is: a variable can be bound to
      ;; the datum `#f`, and an unwrapped table cannot tell that from absence.
      ;; The table stores `(datum)`; #f means "not a known literal".
      (define (lit-of x) (and (symbol? x) (hashtable-ref lits x #f)))
      (define (known-val? v) (and (pair? v) #t))
      (define (unwrap v) (car v))
      (define (known? x) (known-val? (lit-of x)))

      (define (SimpleExpr se)
        (with-output-language (Lanf SimpleExpr)
          (nanopass-case (Lanf SimpleExpr) se
            [(primcall ,pr ([,pn* ,c*] ...) ,x* ...)
             (let ((vals (map lit-of x*)))
               (if (and (pair? x*) (for-all known-val? vals))
                   (let ((r (fold-prim pr (map unwrap vals))))
                     (if r
                         (begin (fold-stats-folded-set!
                                 stats (+ 1 (fold-stats-folded stats)))
                                `(quote ,(car r)))
                         `(primcall ,pr ([,pn* ,c*] ...) ,x* ...)))
                   `(primcall ,pr ([,pn* ,c*] ...) ,x* ...)))]
            [(lambda (,x* ...) ,body) `(lambda (,x* ...) ,(Expr body))]
            [else se])))

      (define (Expr e)
        (with-output-language (Lanf Expr)
          (nanopass-case (Lanf Expr) e
            [(let ([,x ,se]) ,body)
             (let ((se1 (SimpleExpr se)))
               (nanopass-case (Lanf SimpleExpr) se1
                 [(quote ,d) (hashtable-set! lits x (list d))]
                 [else (void)])
               `(let ([,x ,se1]) ,(Expr body)))]
            [(if ,x ,e0 ,e1) `(if ,x ,(Expr e0) ,(Expr e1))]
            [(seq ,e0 ,e1) `(seq ,(Expr e0) ,(Expr e1))]
            [(lambda (,x* ...) ,body) `(lambda (,x* ...) ,(Expr body))]
            [(letrec ([,x* ,e*] ...) ,body)
             (let ((e1* (map Expr e*))) `(letrec ([,x* ,e1*] ...) ,(Expr body)))]
            [(declare ([,x* ,prem*] ...) ,body)
             `(declare ([,x* ,prem*] ...) ,(Expr body))]
            [(declare-distinct (,x* ...) ,body)
             `(declare-distinct (,x* ...) ,(Expr body))]
            [(policy ([,pn* ,b*] ...) ,body)
             `(policy ([,pn* ,b*] ...) ,(Expr body))]
            [else e])))

      ;; D32. The pipeline hands a Program, and a pass that matches only Expr
      ;; falls through its `else` and returns its input unchanged while
      ;; reporting success. Six passes had that defect before this one existed.
      (with-output-language (Lanf Program)
        (nanopass-case (Lanf Program) prog
          [(top ([,x* ,e*] ...) (,x2* ...) ,body)
           ;; Top-level bindings first, so a `(define n-bodies 5)` is a literal
           ;; before any body that reads it is walked.
           (let ((e1* (map (lambda (x e)
                             (let ((e1 (Expr e)))
                               (nanopass-case (Lanf Expr) e1
                                 [(quote ,d) (hashtable-set! lits x (list d))]
                                 [else (void)])
                               e1))
                           x* e*)))
             `(top ([,x* ,e1*] ...) (,x2* ...) ,(Expr body)))]
          [else prog]))))
  )
