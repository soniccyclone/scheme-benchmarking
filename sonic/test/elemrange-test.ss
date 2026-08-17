;;; Tests for elemrange.ss -- WHICH vectors may carry an element range at all.
;;;
;;; shapes.ss supplies a vector's LENGTH. This supplies the precondition for
;;; the other half: a bound on what its elements hold, which matters because an
;;; element is so often used as an index. That unknown is what kept fannkuch's
;;; last four bounds checks and what a full unroll needs a trip count from
;;; (D41).
;;;
;;; THE ESCAPE RULE IS THE ENTIRE SOUNDNESS ARGUMENT, so most of this file is
;;; spent on the cases that must be REFUSED. The fixpoint learns a range by
;;; joining every `vector-set!` that names the vector, and that is a bound on
;;; the contents only if there is no other way to write them. A vector passed as
;;; an argument is written through a parameter under a name this analysis never
;;; connects to the global; the join misses that write and claims a range the
;;; program violates. The file's own words: "a wrong-answer bug of the worst
;;; kind: silent, and only on programs whose vectors are shared."
;;;
;;; So the rule is deliberately crude and syntactic -- a vector is tracked only
;;; if EVERY occurrence of its name is the vector operand of `vector-ref`,
;;; `vector-set!` or `vector-length`. Each test below is one way for a name to
;;; occur somewhere else.
;;;
;;; Input is an unparsed Lssa datum: `(top ([x e] ...) (extern ...) body)`.

(import (chezscheme) (sonic elemrange))

(define checks 0)
(define failures 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok
      (begin (display "  ok   ") (display name) (newline))
      (begin (display "  FAIL ") (display name) (newline)
             (set! failures (+ failures 1)))))

(define (tracked? form x) (and (assq x (trackable-vectors form)) #t))
(define (fill-of form x)
  (cond ((assq x (trackable-vectors form)) => cdr) (else #f)))

;; A vector allocated with a literal fill and touched only through the three
;; vector operations. This is the shape the whole analysis exists for.
;; ANF NAMES EVERY OPERAND, including the fill. `alloc-fill` reads the fill
;; through `const-of`, which requires a SYMBOL bound to a known constant -- a
;; literal sitting in the argument position is something ANF never produces, and
;; the pass treats it as unknown. Writing the fixture the way the pipeline
;; actually spells it is the difference between testing the pass and testing a
;; shape it never sees.
(define (only-vector-ops body)
  `(top ([perm (let ([t.1 (quote 8)])
                 (let ([t.0 (quote 0)])
                   (let ([t.2 (primcall make-vector () t.1 t.0)])
                     t.2)))])
        (display)
        ,body))

(display "\n-- tracked --\n")

(let ((f (only-vector-ops
          '(let ([a (primcall vector-ref () perm (quote 0))])
             (let ([b (primcall vector-set! () perm (quote 1) a)])
               (primcall vector-length () perm))))))
  (ck! "a vector touched only by ref, set! and length is tracked"
       (tracked? f 'perm))
  (ck! "and its fill is the integer make-vector was given"
       (equal? (fill-of f 'perm) 0)))

(display "\n-- refused, and each refusal is a way to write the elements --\n")

;; A CALL ARGUMENT. The write happens through a parameter this analysis never
;; connects back, so the join would miss it. This is the case the header calls
;; silent and worst.
(let ((f (only-vector-ops '(call scramble perm))))
  (ck! "passed as a call argument: NOT tracked"
       (not (tracked? f 'perm))))

;; RETURNED. Same reason from the other end -- the caller may write it.
(let ((f (only-vector-ops '(let ([x (primcall vector-ref () perm (quote 0))]) perm))))
  (ck! "returned from the program: NOT tracked"
       (not (tracked? f 'perm))))

;; STORED INTO ANOTHER VECTOR. Here `perm` is the VALUE argument of a
;; vector-set!, not its vector operand -- it occurs inside a vector op and
;; still escapes, which is why the rule is about position 0 and not about
;; which primitive.
(let ((f (only-vector-ops
          '(let ([box (primcall make-vector () (quote 1) (quote 0))])
             (primcall vector-set! () box (quote 0) perm)))))
  (ck! "stored into another vector as a VALUE: NOT tracked"
       (not (tracked? f 'perm))))

;; USED AS AN INDEX. `perm` appears in a vector-ref, but at position 1. A rule
;; that asked "does this name appear in a vector op" rather than "is it the
;; vector operand" would wrongly keep it.
(let ((f (only-vector-ops
          '(let ([other (primcall make-vector () (quote 4) (quote 0))])
             (primcall vector-ref () other perm)))))
  (ck! "used as an INDEX rather than as the vector: NOT tracked"
       (not (tracked? f 'perm))))

;; A bare occurrence with no operation at all.
(let ((f (only-vector-ops 'perm)))
  (ck! "named bare in tail position: NOT tracked"
       (not (tracked? f 'perm))))

(display "\n-- the fill has to be known --\n")

;; An unknown fill means there is no starting range to join against, so there
;; is nothing to track even though the vector never escapes.
(let ((f `(top ([n (primcall read-argument () x)]
                [v (let ([t.1 (quote 4)])
                     (let ([t.2 (primcall make-vector () t.1 n)])
                       t.2))])
               (display)
               (primcall vector-length () v))))
  (ck! "a vector filled with an unknown value is not tracked"
       (not (tracked? f 'v))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
