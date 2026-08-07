(import (chezscheme) (nanopass) (rnrs io simple)
        (sonic lang) (sonic fixtures) (sonic select))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

;; A toy target. The point is that the FRAMEWORK is target-parametric: this
;; file contains no x86-64 and no RV64 knowledge, and neither does select.ss.
(define toy
  (make-selector 'toy
    (list (cons 'const (lambda (d sc srcs) `((t.li ,d ,(car srcs)))))
          (cons 'mul   (lambda (d sc srcs) `((t.mul ,d ,@srcs))))
          (cons 'add   (lambda (d sc srcs) `((t.add ,d ,@srcs))))
          (cons 'load  (lambda (d sc srcs) `((t.ld ,d ,@srcs))))
          (cons 'ret   (lambda (d sc srcs) `((t.ret ,@srcs)))))
    'toy-partition))

;; --- coverage is a question, not a crash ---------------------------------
(ck! "the toy target covers nbody's lowered inner loop"
     (selector-covers? toy (nbody-inner-mach)))
(ck! "and reports nothing missing"
     (null? (missing-rules toy (nbody-inner-mach))))

(define partial
  (make-selector 'partial
    (list (cons 'const (lambda (d sc srcs) '()))
          (cons 'ret   (lambda (d sc srcs) '())))
    'none))
(ck! "an incomplete target REPORTS what it still owes rather than dying"
     (let ((m (missing-rules partial (nbody-inner-mach))))
       (and (memq 'mul m) (memq 'add m) (memq 'load m))))

;; --- selection over the real fixture -------------------------------------
(define out (select-program toy (nbody-inner-mach)))
(ck! "selection produces a program" (eq? (car out) 'selected))

(define (flat x) (cond ((pair? x) (append (flat (car x)) (flat (cdr x))))
                       ((symbol? x) (list x)) (else '())))
(let ((syms (flat out)))
  (ck! "every Lmach op became a target instruction"
       (and (memq 't.li syms) (memq 't.mul syms)
            (memq 't.add syms) (memq 't.ld syms) (memq 't.ret syms)))
  (ck! "no Lmach op name survived selection"
       (not (or (memq 'mul syms) (memq 'add syms) (memq 'load syms)))))

;; --- the failures that must be loud --------------------------------------
;; A missing rule that silently emits nothing is a wrong-code bug that surfaces
;; as a crash somewhere else entirely.
(set! checks (+ checks 1))
(let ([caught #f])
  (guard (e (#t (set! caught #t))) (select-program partial (nbody-inner-mach)))
  (if caught (display "  ok   selecting with a missing rule RAISES\n")
             (begin (set! failures (+ failures 1))
                    (display "  FAIL missing rule silently emitted nothing\n"))))

;; A `proved` check reaching selection means the elision pass is broken. Emitting
;; the check anyway would silently undo the analysis; we refuse instead.
(set! checks (+ checks 1))
(let ([caught #f])
  (guard (e (#t (set! caught #t)))
    (select-instr toy '(chk bounds-check proved v0 v1)))
  (if caught
      (display "  ok   a `proved` check reaching selection RAISES, not emits\n")
      (begin (set! failures (+ failures 1))
             (display "  FAIL a discharged check was silently re-emitted\n"))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
