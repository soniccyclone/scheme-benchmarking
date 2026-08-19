;;; Tests for gconst.ss -- top-level literal bindings become their literal.
;;;
;;; WHY THE PASS EXISTS. globals.ss makes every non-procedure top-level binding
;;; into storage read from memory at each use. D87 measured what that costs: not
;;; mainly the loads, but that `(define n-bodies 5)` makes `(fx< i n-bodies)` a
;;; register compare, so no loop trip count is ever a constant.
;;;
;;; WHAT MUST NOT HAPPEN is where the assertions concentrate, because both
;;; failures are silent wrong-code rather than a missed optimization:
;;;
;;;   - a binding that is `set!` ANYWHERE is not a constant, even if its
;;;     initializer is a literal and even if the assignment is unreachable. The
;;;     scan is whole-program for exactly this reason.
;;;   - a SHADOWING binder introduces a different variable of the same name.
;;;     Substituting the top-level literal into `(let ((n-bodies 3)) n-bodies)`
;;;     would produce 5 where the program says 3.
;;;
;;; `(quote #f)` gets its own check: a literal whose datum is itself false is
;;; the one case where "did I find a literal" and "what was the literal" cannot
;;; share a return value, and the pass carries it in a list to keep them apart.

(import (chezscheme) (sonic lang) (sonic parse) (sonic expand) (sonic gconst)
        (sonic read) (sonic pipeline))

(define checks 0)
(define failures 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok
      (begin (display "  ok   ") (display name) (newline))
      (begin (display "  FAIL ") (display name) (newline)
             (set! failures (+ failures 1)))))

(define (run forms)
  (let-values (((p st) (propagate-top-constants/report
                        (parse-program (expand-program forms) '()))))
    (values p st)))

(define (counts forms)
  (let-values (((p st) (run forms)))
    (cons (gconst-stats-propagated st) (gconst-stats-substituted st))))

;; Does the output still mention the name as a USE anywhere in the body? Written
;; over the printed form deliberately: the point is that no reference survives,
;; and reaching into Lcore to ask that is more machinery than the claim needs.
(define (body-mentions? forms name)
  (let-values (((p st) (run forms)))
    (let ((s (with-output-to-string (lambda () (write (unparse-Lcore p))))))
      (and (string-search s (symbol->string name)) #t))))

(define (string-search hay needle)
  (let* ((hl (string-length hay)) (nl (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i nl) hl) #f)
            ((string=? (substring hay i (+ i nl)) needle) #t)
            (else (loop (+ i 1)))))))

(ck! "a literal binding is propagated and its use substituted"
     (equal? (counts '((define n 5) (fx< 1 n))) '(1 . 1)))

(ck! "a use in a nested lambda body is substituted too"
     (equal? (counts '((define n 5) (lambda (i) (fx< i n)))) '(1 . 1)))

(ck! "two uses of one binding are both substituted"
     (equal? (counts '((define n 5) (fx+ n n))) '(1 . 2)))

(ck! "a non-literal initializer is left alone"
     (equal? (counts '((define n (fx+ 2 3)) (fx< 1 n))) '(0 . 0)))

;; The set! rule. Three shapes, because a whole-program scan is the only thing
;; that catches all of them and a body-only or initializer-only scan catches
;; some.
(ck! "a binding assigned in the body is NOT a constant"
     (equal? (counts '((define n 5) (set! n 6) (fx< 1 n))) '(0 . 0)))

(ck! "a binding assigned inside a lambda is NOT a constant"
     (equal? (counts '((define n 5) (lambda () (set! n 6)) (fx< 1 n))) '(0 . 0)))

(ck! "a binding assigned in ANOTHER binding's initializer is NOT a constant"
     (equal? (counts '((define n 5) (define m (begin (set! n 6) 1)) (fx< 1 n)))
             '(0 . 0)))

(ck! "an assignment that can never run still disqualifies the binding"
     (equal? (counts '((define n 5) (if #f (set! n 6) 0) (fx< 1 n))) '(0 . 0)))

;; Shadowing. Substituting here is a wrong-code bug, not a missed win.
(ck! "a let-bound name of the same spelling is NOT substituted"
     (equal? (counts '((define n 5) (let ((n 3)) n))) '(1 . 0)))

(ck! "a lambda parameter of the same spelling is NOT substituted"
     (equal? (counts '((define n 5) (lambda (n) n))) '(1 . 0)))

(ck! "a letrec-bound name of the same spelling is NOT substituted"
     (equal? (counts '((define n 5) (letrec ((n (lambda () 1))) n))) '(1 . 0)))

(ck! "shadowing is scoped: the use OUTSIDE the let is still substituted"
     (equal? (counts '((define n 5) (fx+ (let ((n 3)) n) n))) '(1 . 1)))

(ck! "a let INITIALIZER is outside the new scope, so it substitutes"
     (equal? (counts '((define n 5) (let ((n n)) 0))) '(1 . 1)))

;; The datum that is itself false.
(ck! "a binding whose literal is #f is still propagated"
     (equal? (counts '((define f (quote #f)) (if f 1 2))) '(1 . 1)))

(ck! "and one whose literal is the empty list"
     (equal? (counts '((define e (quote ())) (eq? e e))) '(1 . 2)))

(ck! "a flonum literal propagates"
     (equal? (counts '((define dt 0.01) (fl* dt dt))) '(1 . 2)))

;; The binding itself stays; only uses go. Removing it is a separate decision
;; and gconst.ss says why it is not taken here.
(ck! "the top-level binding is NOT removed, only its uses"
     (body-mentions? '((define n 5) (fx< 1 n)) 'n))

;; --- THE PASS IS NOT INERT ON A REAL PROGRAM --------------------------------
;;
;; Everything above is a fixture. D132 is what this guards against: the merge
;; pass shipped and did nothing at all on RV64 for two entries' worth of work,
;; because every check asked whether the output was CORRECT and none asked
;; whether the pass did ANYTHING. A fixture cannot catch that -- it tests the
;; shape it was written for, which is by construction a shape the pass handles.
;;
;; nbody defines `n-bodies`, `dt`, `pi` and `days-per-year` as top-level
;; literals and uses them in its loop guards, so a working pass must substitute
;; several of them. If a later change makes this pass inert, the count goes to
;; zero and this fails.

(define nb "../bench/nbody/config-sonic.sps")

(let-values (((p st) (propagate-top-constants/report
                      (parse-program (expand-program (read-all-from-file nb))
                                     nbody-externs))))
  (ck! "nbody's top-level literals are propagated: the pass is not inert"
       (> (gconst-stats-propagated st) 0))
  (ck! "and their uses are substituted, not merely counted"
       (> (gconst-stats-substituted st) 0))
  (unless (and (> (gconst-stats-propagated st) 0)
               (> (gconst-stats-substituted st) 0))
    (display "       propagated=") (display (gconst-stats-propagated st))
    (display " substituted=") (display (gconst-stats-substituted st)) (newline)))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
