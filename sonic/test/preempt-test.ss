(import (rnrs base) (rnrs lists) (rnrs control) (rnrs exceptions)
        (rnrs io simple) (sonic preempt) (sonic fixtures) (sonic lang))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

;; --- restart regions ------------------------------------------------------
(define alloc (make-region 'alloc-fast-path 100 120))
(define tbl (region-table-add! (make-region-table) alloc))

(ck! "a PC inside the claim-then-fill window rewinds to the region start"
     (= (rewind-pc tbl 110) 100))
(ck! "a PC at the region start rewinds to itself" (= (rewind-pc tbl 100) 100))
(ck! "the region is half-open: its end is OUTSIDE" (= (rewind-pc tbl 120) 120))
(ck! "a PC outside every region is untouched, which is the common case"
     (and (= (rewind-pc tbl 50) 50) (= (rewind-pc tbl 999) 999)))

;; Overlap is a bug, not a configuration: a PC in both has two rewind targets.
(set! checks (+ checks 1))
(let ([caught #f])
  (guard (e (#t (set! caught #t)))
    (region-table-add! tbl (make-region 'other 110 130)))
  (if caught
      (display "  ok   overlapping restart regions are REFUSED\n")
      (begin (set! failures (+ failures 1))
             (display "  FAIL overlapping regions accepted; rewind is ambiguous\n"))))

;; Adjacent, non-overlapping regions are fine.
(set! checks (+ checks 1))
(let ([caught #f])
  (guard (e (#t (set! caught #t)))
    (region-table-add! tbl (make-region 'next 120 140)))
  (if caught
      (begin (set! failures (+ failures 1))
             (display "  FAIL adjacent regions wrongly refused\n"))
      (display "  ok   adjacent non-overlapping regions are accepted\n")))

;; --- the no-poll invariant ------------------------------------------------
(ck! "ordinary arithmetic is poll-free" (poll-free? '(add mul load store ret)))
(ck! "a poll is detected" (not (poll-free? '(add poll mul))))
(ck! "a yield is detected" (not (poll-free? '(add yield))))
(ck! "a safepoint is detected" (not (poll-free? '(safepoint add))))

;; The one that matters: nbody's lowered inner loop, which is the hot path this
;; whole design exists to keep clean. Walk the real fixture and assert no
;; opcode in it is a poll.
(define (mach-opcodes prog)
  (let walk ((x (unparse-Lmach prog)) (acc '()))
    (cond ((pair? x) (walk (car x) (walk (cdr x) acc)))
          ((symbol? x) (cons x acc))
          (else acc))))

(ck! "nbody's lowered inner loop contains NO poll, yield or safepoint"
     (poll-free? (mach-opcodes (nbody-inner-mach))))

;; And the negative control: if a poll HAD been emitted, this test would catch
;; it. Otherwise the assertion above is vacuous.
(ck! "the check is not vacuous: an injected poll is caught"
     (not (poll-free? (cons 'poll (mach-opcodes (nbody-inner-mach))))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
