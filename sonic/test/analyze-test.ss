;;; End-to-end: does the analysis actually delete a bounds check?
;;;
;;; Each case states a program and the expected verdict per vector reference.
;;; The cases that must be REFUSED matter as much as the ones that must be
;;; eliminated: an analysis that says yes to everything is not an analysis.

(import (rnrs base)
        (rnrs lists)
        (rnrs control)
        (rnrs io simple)
        (sonic interval)
        (sonic analyze))

(define failures 0)
(define checks 0)

(define (expect name prog lengths expected)
  (set! checks (+ checks 1))
  (let* ((decs (analyze-program prog lengths))
         (got (map decision-eliminable? decs)))
    (if (equal? got expected)
        (begin (display "  ok   ") (display name)
               (display "  -> ") (display got) (newline))
        (begin (set! failures (+ failures 1))
               (display "  FAIL ") (display name)
               (display "  expected ") (display expected)
               (display " got ") (display got) (newline)
               (for-each (lambda (d)
                           (display "        ") (display (decision-site d))
                           (display " index ") (display (iv->string (decision-index d)))
                           (newline))
                         decs)))))

(display "bounds check elision:") (newline)

;; 1. The canonical case. for i from 0 below 35, b[i], b has length 35.
(expect "loop 0..34 over length-35 vector"
        '(loop i 0 35 (vref b i))
        '((b . 35))
        '(#t))

;; 2. Must refuse: the loop runs one past the end.
(expect "loop 0..35 over length-35 vector is NOT safe"
        '(loop i 0 36 (vref b i))
        '((b . 35))
        '(#f))

;; 3. Must refuse: unknown length.
(expect "unknown vector length"
        '(loop i 0 35 (vref b i))
        '()
        '(#f))

;; 4. Must refuse: index can go negative.
(expect "loop -1..34 is NOT safe"
        '(loop i -1 35 (vref b i))
        '((b . 35))
        '(#f))

;; 5. nbody's real pattern: b[i*7 + k], i in [0,5), k in [0,7), length 35.
(expect "nbody b[i*7+k], nested loops"
        '(loop i 0 5
               (loop k 0 7
                     (let off (prim * i seven)
                       (let off2 (prim + off k)
                         (vref b off2)))))
        '((b . 35))
        '(#f))                    ; `seven` is unbound, so top: correctly refused

;; 5b. Same, with the constant actually bound.
(expect "nbody b[i*7+k] with the stride bound"
        '(let seven (const 7)
           (loop i 0 5
                 (loop k 0 7
                       (let off (prim * i seven)
                         (let off2 (prim + off k)
                           (vref b off2))))))
        '((b . 35))
        '(#t))

;; 6. Refinement through a guard, with no loop at all.
(expect "guarded by (< i n) and (>= i 0)"
        '(let zero (const 0)
           (let n (const 35)
             (if (< i n)
                 (if (>= i zero) (vref b i) (const 0))
                 (const 0))))
        '((b . 35))
        '(#t))

;; 7. Must refuse: only the upper guard, so i can still be negative.
(expect "guarded by (< i n) only"
        '(let n (const 35)
           (if (< i n) (vref b i) (const 0)))
        '((b . 35))
        '(#f))

;; 8. Two references, one safe and one not, in the same program. Catches an
;;    analysis that collapses all decisions into a single verdict.
(expect "mixed: first safe, second not"
        '(let seven (const 7)
           (loop i 0 5
                 (begin (vref b i)
                        (let big (prim * i seven)
                          (let huge (prim * big seven)
                            (vref b huge))))))
        '((b . 35))
        '(#t #f))

;; 9. Derived index through two primops: acc = i+1 in [1,5], acc2 = acc*acc in
;;    [1,25], which fits in 35. This was written expecting a refusal, on the
;;    theory that acc "accumulates". It does not: the core language is pure and
;;    has no loop-carried state, so acc is recomputed from i every iteration and
;;    nothing can grow. The analyzer was right and the expectation was wrong.
;;
;;    Consequence worth recording: WIDENING TERMINATION CANNOT BE EXERCISED
;;    HERE. There is no way to write a divergent fixpoint in this core language
;;    yet. interval-test.ss covers the widening operator directly; a program
;;    level test has to wait for mutable or loop-carried variables.
(expect "index derived through two primops, still provable"
        '(let one (const 1)
           (loop i 0 5
                 (let acc (prim + i one)
                   (let acc2 (prim * acc acc)
                     (vref b acc2)))))
        '((b . 35))
        '(#t))

;; 10. The same shape, but the derived index escapes the vector.
(expect "derived index that overruns is refused"
        '(let ten (const 10)
           (loop i 0 5
                 (let acc (prim + i ten)
                   (let acc2 (prim * acc acc)
                     (vref b acc2)))))
        '((b . 35))
        '(#f))

(newline)
(display checks) (display " cases, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
