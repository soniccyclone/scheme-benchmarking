;;; Tests for merge-identical-functions -- identical code becomes one function.
;;;
;;; WHY THE PASS EXISTS. `unroll-program` duplicates a loop body and `lift.ss`
;;; makes each copy its own function, so a hot loop arrives at code generation as
;;; several functions with the same instructions under different label names.
;;; That duplication is what lets the interval analysis discharge nbody's bounds
;;; checks (D118), and it is what costs fannkuch: 25.2% of its cycles are
;;; front-end stalled on mispredicts (D112) and duplicating a hot loop doubles
;;; its branch targets. Merging after finalization keeps the first and removes
;;; the second.
;;;
;;; WHAT MUST NOT HAPPEN is the first assertion below, and it is not
;;; hypothetical: the original pass canonicalised EVERY label, so a call to `foo`
;;; and a call to `bar` both became "the nth label" and two functions calling
;;; DIFFERENT functions compared as identical. The suite caught it as `label
;;; defined twice`, which is the mild symptom; merging two functions that do
;;; different things is the severe one.

(import (chezscheme) (sonic finalize))

(define checks 0)
(define failures 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok
      (begin (display "  ok   ") (display name) (newline))
      (begin (display "  FAIL ") (display name) (newline)
             (set! failures (+ failures 1)))))

;; A FUNCTION'S LISTING DEFINES A LABEL OF ITS OWN NAME, and the fixtures below
;; do too, because the pass depends on it: that is how a call naming the function
;; gets redirected when the function is dropped. `finalize-function` emits it --
;; a disassembly shows `=== loop%2.372 ===` and `=== loop%2.372.loop ===` as two
;; blocks -- and a fixture without it exercises a shape the compiler never
;; produces.
(define (fn name listing) (make-finalized name (cons name listing) #f '()))
(define (names fs) (map finalized-name fs))
(define (listing-of fs n)
  (let loop ((fs fs))
    (cond ((null? fs) #f)
          ((eq? (finalized-name (car fs)) n) (finalized-listing (car fs)))
          (else (loop (cdr fs))))))

;; --- the basic case ---------------------------------------------------------

(define a-body '(a.loop (mov rax rcx) (add rax (imm 1)) (jmp (label a.loop))))
(define b-body '(b.loop (mov rax rcx) (add rax (imm 1)) (jmp (label b.loop))))

(ck! "two functions identical under label renaming become one"
     (equal? (names (merge-identical-functions (list (fn 'a a-body) (fn 'b b-body))))
             '(a)))

(ck! "and the one that survives is the FIRST, not whichever hashes first"
     (equal? (names (merge-identical-functions (list (fn 'b b-body) (fn 'a a-body))))
             '(b)))

(ck! "a function with different instructions is untouched"
     (equal? (names (merge-identical-functions
                     (list (fn 'a a-body)
                           (fn 'c '(c.loop (mov rax rcx) (sub rax (imm 1))
                                           (jmp (label c.loop)))))))
             '(a c)))

;; --- THE SOUNDNESS PROPERTY -------------------------------------------------
;;
;; Same instructions, different callee. Merging these would redirect a call.

(ck! "two functions differing ONLY in whom they call are NOT merged"
     (equal? (names (merge-identical-functions
                     (list (fn 'p '(p.loop (mov rax rcx) (call (label foo))))
                           (fn 'q '(q.loop (mov rax rcx) (call (label bar)))))))
             '(p q)))

(ck! "and differing only in a jump target outside themselves are not merged"
     (equal? (names (merge-identical-functions
                     (list (fn 'p '(p.loop (mov rax rcx) (jmp (label foo))))
                           (fn 'q '(q.loop (mov rax rcx) (jmp (label bar)))))))
             '(p q)))

;; --- references to a dropped function's INTERNAL labels ----------------------
;;
;; D97's frame reuse retargets a tail call to `<name>.loop`, so a dropped
;; function's internal labels are named from outside it.

(ck! "a reference to the dropped function's own label is redirected"
     (let* ((out (merge-identical-functions
                  (list (fn 'a a-body)
                        (fn 'b b-body)
                        (fn 'z '(z.loop (jmp (label b.loop)))))))
            (zl (listing-of out 'z)))
       (and (equal? (names out) '(a z))
            (equal? zl '(z z.loop (jmp (label a.loop)))))))

(ck! "and a call naming the dropped FUNCTION is redirected too"
     (let* ((out (merge-identical-functions
                  (list (fn 'a a-body)
                        (fn 'b b-body)
                        (fn 'z '(z.loop (call (label b)))))))
            (zl (listing-of out 'z)))
       (and (equal? (names out) '(a z))
            (equal? zl '(z z.loop (call (label a)))))))

;; --- the fixpoint -----------------------------------------------------------
;;
;; p and q differ only in calling foo versus bar. Once foo and bar merge, p and
;; q become identical -- which one round cannot see.

(ck! "merging is iterated: callers become identical once their callees merge"
     (equal? (names (merge-identical-functions
                     (list (fn 'foo '(foo.loop (mov rax (imm 7))))
                           (fn 'bar '(bar.loop (mov rax (imm 7))))
                           (fn 'p '(p.loop (mov rcx rdx) (call (label foo))))
                           (fn 'q '(q.loop (mov rcx rdx) (call (label bar)))))))
             '(foo p)))

(ck! "nothing to merge leaves the list alone"
     (equal? (names (merge-identical-functions
                     (list (fn 'a a-body)
                           (fn 'c '(c.loop (sub rax rcx))))))
             '(a c)))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
