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
;;; ## COMPARISONS FOLD TO 0 AND 1, NOT TO #f AND #t
;;;
;;; Folding `(fx< 1 2)` to `(quote #t)` is the obvious spelling and it is a
;;; WRONG-CODE BUG. repr.ss classifies the fixnum comparisons `raw-word` -- a
;;; boolean-valued machine word holding 0 or 1 -- while `datum-class`
;;; classifies the datum `#t` as `tagged`, because a Scheme boolean is the
;;; immediate numeric.ss calls sonic-true. Different representations, different
;;; register files, so that fold silently reclassifies the value.
;;;
;;; It does not fail where you would notice. Measured: nbody stopped compiling
;;; with `(vmulsd xmm8 xmm6 rbx)` -- a float multiply reading a VALUE-class
;;; register -- several passes downstream, because the class change propagated
;;; through repr.ss's fixpoint into an unrelated expression.
;;;
;;; So a comparison folds to the fixnum 0 or 1, which `datum-class` puts in
;;; `raw-word` -- exactly where the comparison already was. Every consumer
;;; downstream already expects a raw word there, because that is what `fx<`
;;; produced before it was folded.
;;;
;;; WHICH MEANS THE TRUTH VALUE IS NOT SCHEME'S. In Scheme every object but
;;; `#f` is true, so `(if 0 a b)` takes `a`. In this representation 0 IS false:
;;; `branch-if` lowers to `cmp r, 0` and `jne`. Reading the literal back with
;;; Scheme's rule would fold the branch the wrong way, so folded comparisons
;;; are tracked in their own table with their boolean meaning attached, and
;;; only that table decides a branch. A fixnum that merely happens to be 0
;;; never does.

(library (sonic fold)
  (export fold-program fold-stats fold-stats? fold-stats-folded fold-stats-branches)
  (import (chezscheme) (nanopass) (sonic lang))

  (define-record-type (fold-stats make-fold-stats fold-stats?)
    (fields (mutable folded) (mutable branches)))

  ;; numeric.ss: 61-bit fixnums, so [-2^60, 2^60-1].
  (define fx-greatest (- (expt 2 60) 1))
  (define fx-least (- (expt 2 60)))
  ;; `integer?` FIRST, and the order is load-bearing rather than stylistic:
  ;; `exact?` is a numeric predicate and RAISES on a non-number. Asking it about
  ;; the empty list -- which is what `(quote ())` is, and which any program
  ;; building a list writes -- crashed the compiler in this pass with
  ;; "exact?: () is not a number".
  (define (fixnum-range? n) (and (integer? n) (exact? n) (<= fx-least n fx-greatest)))

  (define (int? d) (and (integer? d) (exact? d)))   ; see fixnum-range? above

  ;; The primitives whose folded 0/1 is a TRUTH VALUE rather than a number.
  (define (boolean-prim? pr) (and (memq pr '(fx< fx<= fx= fx>= fx>)) #t))

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
              ;; To 0 and 1, not to #f and #t -- see the header. `boolean-prim?`
              ;; is what tells the caller this result is a TRUTH VALUE in the
              ;; raw-word representation rather than an ordinary fixnum.
              ((and (eq? pr 'fx<) (arity 2)) (if (< (a) (b)) 1 0))
              ((and (eq? pr 'fx<=) (arity 2)) (if (<= (a) (b)) 1 0))
              ((and (eq? pr 'fx=) (arity 2)) (if (= (a) (b)) 1 0))
              ((and (eq? pr 'fx>=) (arity 2)) (if (>= (a) (b)) 1 0))
              ((and (eq? pr 'fx>) (arity 2)) (if (> (a) (b)) 1 0))
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
    (let ((lits (make-eq-hashtable))
          (bools (make-eq-hashtable)))

      ;; WRAPPED for the same reason `fold-prim` is: a variable can be bound to
      ;; the datum `#f`, and an unwrapped table cannot tell that from absence.
      ;; The table stores `(datum)`; #f means "not a known literal".
      (define (lit-of x) (and (symbol? x) (hashtable-ref lits x #f)))
      ;; Only variables bound to a FOLDED COMPARISON. A fixnum that happens to
      ;; be 0 is not a false, and must never decide a branch.
      (define (bool-of x) (and (symbol? x) (hashtable-ref bools x #f)))
      (define (known-val? v) (and (pair? v) #t))
      (define (unwrap v) (car v))
      (define (known? x) (known-val? (lit-of x)))

      ;; Set by `SimpleExpr` when the primcall it just folded was a comparison,
      ;; and read by the `let` that binds the result. A flag rather than a
      ;; richer return type because `SimpleExpr` has to keep returning an
      ;; Lanf SimpleExpr for the nanopass template.
      (define last-was-boolean #f)

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
                                (set! last-was-boolean (boolean-prim? pr))
                                `(quote ,(car r)))
                         `(primcall ,pr ([,pn* ,c*] ...) ,x* ...)))
                   `(primcall ,pr ([,pn* ,c*] ...) ,x* ...)))]
            [(lambda (,x* ...) ,body) `(lambda (,x* ...) ,(Expr body))]
            [else se])))

      (define (Expr e)
        (with-output-language (Lanf Expr)
          (nanopass-case (Lanf Expr) e
            [(let ([,x ,se]) ,body)
             (set! last-was-boolean #f)
             (let ((se1 (SimpleExpr se)))
               (nanopass-case (Lanf SimpleExpr) se1
                 [(quote ,d)
                  (hashtable-set! lits x (list d))
                  (when last-was-boolean
                    (hashtable-set! bools x (list (not (eqv? d 0)))))]
                 [else (void)])
               `(let ([,x ,se1]) ,(Expr body)))]
            ;; A KNOWN TRUTH VALUE TAKES ITS ARM, and only a value this pass
            ;; folded FROM A COMPARISON counts as one. The deleted arm may hold
            ;; side effects and that is the point -- it is unreachable.
            [(if ,x ,e0 ,e1)
             (let ((b (bool-of x)))
               (if b
                   (begin (fold-stats-branches-set!
                           stats (+ 1 (fold-stats-branches stats)))
                          (Expr (if (unwrap b) e0 e1)))
                   `(if ,x ,(Expr e0) ,(Expr e1))))]
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
