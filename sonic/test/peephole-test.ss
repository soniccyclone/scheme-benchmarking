(import (chezscheme) (sonic peephole))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define (run t is) (let-values ([(o s) (peephole t is)]) (list o (peephole-stats-fused s))))

;; --- the fusion ------------------------------------------------------------
(let* ([in '((cmp v-a v-b) (setl v-t) (cmp v-t 0) (jne L1) (ret v-x))]
       [r (run 'x86-64 in)])
  (ck! "cmp/setl/cmp/jne collapses to cmp/jl"
       (equal? (car r) '((cmp v-a v-b) (jl L1) (ret v-x))))
  (ck! "and is counted" (= (cadr r) 1)))

;; (je L) on the boolean means branch when the condition FAILED, so the jump
;; inverts. Getting this backwards is a wrong branch, not a slow one.
(let* ([in '((cmp v-a v-b) (setl v-t) (cmp v-t 0) (je L1) (ret v-x))]
       [r (run 'x86-64 in)])
  (ck! "je on the boolean inverts the jump: jl becomes jge"
       (equal? (car r) '((cmp v-a v-b) (jge L1) (ret v-x)))))

;; --- the liveness condition, which is the whole safety of the pass ---------
(let* ([in '((cmp v-a v-b) (setl v-t) (cmp v-t 0) (jne L1) (ret v-t))]
       [r (run 'x86-64 in)])
  (ck! "NO fusion when the boolean is used after the branch"
       (equal? (car r) in))
  (ck! "and nothing is counted" (= (cadr r) 0)))

(let* ([in '((cmp v-a v-b) (setl v-t) (cmp v-t 0) (jne L1) (store v-o v-t))]
       [r (run 'x86-64 in)])
  (ck! "NO fusion when the boolean is stored: it is a value someone reads"
       (equal? (car r) in)))

;; --- non-patterns are untouched -------------------------------------------
(let* ([in '((add v-a v-b v-c) (mul v-d v-a v-a) (ret v-d))]
       [r (run 'x86-64 in)])
  (ck! "ordinary arithmetic passes through unchanged" (equal? (car r) in)))

(let* ([in '((cmp v-a v-b) (setl v-t) (cmp v-u 0) (jne L1))]
       [r (run 'x86-64 in)])
  (ck! "no fusion when the branch tests a DIFFERENT vreg" (equal? (car r) in)))

;; --- RV64 needs no fusion at all ------------------------------------------
;; Its branches ARE compare-and-branch, so the selector emits the fused form
;; directly. This is the mirror of the two-address pass: x86-64 needs it, RV64
;; does not.
(let* ([in '((blt v-a v-b L1) (ret v-x))]
       [r (run 'rv64 in)])
  (ck! "rv64 stream is returned untouched" (equal? (car r) in))
  (ck! "and nothing is fused" (= (cadr r) 0)))

;; An unknown target RAISES rather than defaulting to no-fusion, because a
;; quiet default silently leaves five instructions where two would do, forever.
(set! checks (+ checks 1))
(let ([caught #f])
  (guard (e (#t (set! caught #t))) (peephole 'arm64 '()))
  (if caught (display "  ok   an unknown target RAISES rather than silently skipping\n")
             (begin (set! failures (+ failures 1))
                    (display "  FAIL unknown target silently skipped\n"))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
