;;; Tests for fold.ss -- constant folding over Lanf.
;;;
;;; WHY IT EXISTS AT ALL. nbody's remaining gap to `gcc -O3 -march=native` is
;;; entirely integer -- 370 operations per step against 36 -- and gcc's 36 is
;;; not tighter loop control, it is the ABSENCE of a loop: it fully unrolled the
;;; ten-pair nest, and once `i` and `j` are literals every `bi = i*3` folds to a
;;; constant displacement. Unrolling WITHOUT folding buys nothing; applying the
;;; x2 unroller repeatedly was measured at 16 -> 28 -> 36 `imul`s, growing
;;; rather than folding, because the counter stays symbolic on every path.
;;;
;;; THE SPELLING OF A FOLDED COMPARISON IS A WRONG-CODE TRAP, and it has the
;;; longest test here. `(fx< 1 2)` must fold to `(quote 1)` and NOT to
;;; `(quote #t)`: repr.ss classifies the fixnum comparisons `raw-word`, a
;;; machine word holding 0 or 1, while `datum-class` classifies the datum `#t`
;;; as `tagged`, because a Scheme boolean is the immediate numeric.ss calls
;;; sonic-true. Different representations. The obvious spelling is the bug.

(import (chezscheme) (nanopass) (sonic lang) (sonic fold)
        (sonic driver) (sonic pipeline))

(define checks 0)
(define failures 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok
      (begin (display "  ok   ") (display name) (newline))
      (begin (display "  FAIL ") (display name) (newline)
             (set! failures (+ failures 1)))))

;; A WHOLE PROGRAM, not an Expr. `fold-program` matches `(top ...)` and returns
;; anything else UNCHANGED via its `[else prog]` arm -- so a fixture built as an
;; (Lanf Expr) folds nothing, every positive assertion fails, and every refusal
;; passes for the wrong reason. That is what this file did first.
(define (folded body)
  (unparse-Lanf
   (fold-program
    (with-output-language (Lanf Program)
      `(top () (display) ,body)))))

;; The value a named binding ended up with, found in the unparsed output.
(define (binding-of out x)
  (let walk ((d out))
    (cond ((not (pair? d)) #f)
          ((and (eq? (car d) 'let) (pair? (cadr d))
                (eq? (car (car (cadr d))) x))
           (cadr (car (cadr d))))
          (else (let try ((xs d))
                  (cond ((not (pair? xs)) #f)
                        ((walk (car xs)))
                        (else (try (cdr xs)))))))))

(display "\n-- fixnum arithmetic --\n")

(let ((out (folded (with-output-language (Lanf Expr)
                     `(let ([a (quote 2)])
                        (let ([b (quote 3)])
                          (let ([c (primcall fx* ([overflow-check checked]) a b)])
                            c)))))))
  (ck! "a primcall over two literal-bound variables folds"
       (equal? (binding-of out 'c) '(quote 6))))

;; A FIXPOINT, not one sweep. ANF chains bindings, so folding `c` is what makes
;; `d`'s operand a literal; one pass would leave d alone.
(let ((out (folded (with-output-language (Lanf Expr)
                     `(let ([a (quote 2)])
                        (let ([b (quote 3)])
                          (let ([c (primcall fx* ([overflow-check checked]) a b)])
                            (let ([d (primcall fx+ ([overflow-check checked]) c a)])
                              d))))))))
  (ck! "and the chain folds too, which needs more than one sweep"
       (equal? (binding-of out 'd) '(quote 8))))

(display "\n-- comparisons fold to 0 and 1, never to #f and #t --\n")

(let ((out (folded (with-output-language (Lanf Expr)
                     `(let ([a (quote 1)])
                        (let ([b (quote 2)])
                          (let ([c (primcall fx< () a b)])
                            c)))))))
  (ck! "a true comparison folds to the raw-word 1"
       (equal? (binding-of out 'c) '(quote 1)))
  ;; Stated as its own assertion because this is the bug, not a detail: `#t` is
  ;; `tagged` and the comparison's class is `raw-word`, so the obvious spelling
  ;; puts a value of the wrong representation into a raw register.
  (ck! "and specifically NOT to the tagged datum #t"
       (not (equal? (binding-of out 'c) '(quote #t)))))

(let ((out (folded (with-output-language (Lanf Expr)
                     `(let ([a (quote 5)])
                        (let ([b (quote 2)])
                          (let ([c (primcall fx< () a b)])
                            c)))))))
  (ck! "a false comparison folds to the raw-word 0"
       (equal? (binding-of out 'c) '(quote 0)))
  (ck! "and specifically NOT to #f"
       (not (equal? (binding-of out 'c) '(quote #f)))))

(display "\n-- what it refuses --\n")

;; Overflow. Evaluating it in Chez's unbounded integers and emitting the result
;; would be a WRONG ANSWER, not a missed fold: the machine wraps. The check on
;; the operation is elide.ss's business; this pass simply declines.
(let ((out (folded (with-output-language (Lanf Expr)
                     `(let ([a (quote 4611686018427387903)])
                        (let ([b (quote 2)])
                          (let ([c (primcall fx* ([overflow-check checked]) a b)])
                            c)))))))
  (ck! "a product that would overflow the fixnum range is NOT folded"
       (not (and (pair? (binding-of out 'c))
                 (eq? (car (binding-of out 'c)) 'quote)))))

;; A primitive this file cannot evaluate exactly is left alone.
(let ((out (folded (with-output-language (Lanf Expr)
                     `(let ([a (quote 2.0)])
                        (let ([b (quote 3.0)])
                          (let ([c (primcall fl* () a b)])
                            c)))))))
  (ck! "flonum arithmetic is not folded, exactness not being available here"
       (not (equal? (binding-of out 'c) '(quote 6.0)))))

;; COPY PROPAGATION IS FOR LITERALS ONLY. A variable bound to another variable
;; is left alone: that is register allocation's business, and substituting here
;; would only lengthen live ranges.
(let ((out (folded (with-output-language (Lanf Expr)
                     `(lambda (n)
                        (let ([m n])
                          (let ([c (primcall fx+ ([overflow-check checked]) m m)])
                            c)))))))
  (ck! "a variable bound to another variable is not propagated"
       (equal? (binding-of out 'm) 'n)))

;; And an operand that is not a literal stops the fold entirely.
(let ((out (folded (with-output-language (Lanf Expr)
                     `(lambda (n)
                        (let ([a (quote 3)])
                          (let ([c (primcall fx* ([overflow-check checked]) a n)])
                            c)))))))
  (ck! "one non-literal operand is enough to decline"
       (not (and (pair? (binding-of out 'c))
                 (eq? (car (binding-of out 'c)) 'quote)))))

;; --- THE PASS IS NOT INERT ON A REAL PROGRAM --------------------------------
;;
;; ASSERTED INSIDE `unroll-fully`, NOT ON THE INITIAL Lanf, and the difference is
;; the whole point. The driver runs fold twice: once on the program straight out
;; of inlining, where it reports ZERO, and again after each specialisation round.
;; What it folds are the guards specialisation turns into literals -- the driver's
;; own comment says so ("substituting a loop body at a call with literal
;; arguments makes the guard foldable"). An assertion on the first call would pin
;; a zero and pass forever, which is worse than none (D138).
(define captured #f)
(parameterize ((compile-stage-hook
                (lambda (stage prog)
                  (unless captured
                    (when (eq? stage 'lanf/specialized) (set! captured prog))))))
  (compile-sonic "../bench/nbody/config-sonic.sps" nbody-externs))

(ck! "the stage hook delivered a specialised Lanf program" (and captured #t))
(when captured
  (let-values (((out st) (fold-program/report captured)))
    (ck! "fold folds something after specialisation: the pass is not inert"
         (> (fold-stats-folded st) 0))
    (unless (> (fold-stats-folded st) 0)
      (display "       folded=") (display (fold-stats-folded st)) (newline))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
