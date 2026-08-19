;;; Tests for specialize.ss -- the pass had no test file at all.
;;;
;;; WHY THIS EXISTS AND WHY IT IS SHORT. D132 found `merge-identical-functions`
;;; doing nothing on RV64 for two entries, invisible because every check in this
;;; tree asks whether the output is CORRECT and none asked whether a pass did
;;; ANYTHING. D135's audit then found `specialize` with no test file, so nothing
;;; would notice if it stopped firing -- and D89 measured its output as a net
;;; loss on cycles at every budget tested, which makes "is it still running" a
;;; question someone will eventually need answered rather than assumed.
;;;
;;; This is the not-inert assertion only. The pass's behaviour is covered
;;; indirectly and substantially by unroll-test.ss, which measures what
;;; `unroll-fully` -- specialisation's only caller -- produces on nbody.

(import (chezscheme) (sonic specialize) (sonic driver) (sonic pipeline))

(define checks 0)
(define failures 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok
      (begin (display "  ok   ") (display name) (newline))
      (begin (display "  FAIL ") (display name) (newline)
             (set! failures (+ failures 1)))))

;; Captured through the driver's stage hook, at the point `unroll-fully` hands a
;; program to specialisation. A fixture cannot catch inertness: it tests the
;; shape it was written for, which the pass by construction handles.
(define captured #f)
(parameterize ((compile-stage-hook
                (lambda (stage prog)
                  (unless captured
                    (when (eq? stage 'lanf/pre-specialize) (set! captured prog))))))
  (compile-sonic "../bench/nbody/config-sonic.sps" nbody-externs))

(ck! "the stage hook delivered the program specialisation is handed"
     (and captured #t))

(when captured
  (let-values (((out st) (specialize-program/report captured)))
    (ck! "specialisation fires on nbody: the pass is not inert"
         (> (specialize-stats-specialized st) 0))
    (unless (> (specialize-stats-specialized st) 0)
      (display "       specialized=") (display (specialize-stats-specialized st))
      (newline))
    (ck! "and it names what it specialised, so a caller can ask which"
         (pair? (specialize-stats-names st)))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
