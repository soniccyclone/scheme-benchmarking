(import (chezscheme) (nanopass) (sonic lang) (sonic fixtures) (sonic lower))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define (ops prog)          ; the instruction opcodes of the entry block, in order
  (map car (cadr (cadr (car (cadr prog))))))
(define (transfer prog) (car (caddr (cadr (car (cadr prog))))))

;; --- nbody's inner loop -----------------------------------------------------
(let-values ([(prog stats) (lower-program (unparse-Lrepr (nbody-inner-repr)) 'entry)])
  ;; The acceptance criterion: same op sequence as the hand-written fixture.
  ;; Compared on OPS rather than on the whole datum, because the fixture names
  ;; its vregs v-off and lowering names them after the source variables, and
  ;; that difference is naming, not structure.
  (ck! "lowers to mul, add, load in that order"
       (equal? (ops prog) '(mul add load)))
  (ck! "and returns" (eq? (transfer prog) 'ret))
  (ck! "no chk instruction survives: every check was discharged or suppressed"
       (not (memq 'chk (ops prog))))

  ;; The number the project exists to produce, separated from the one it does not.
  (ck! "2 checks PROVED away by the analysis" (= (lower-stats-proved stats) 2))
  (ck! "2 checks suppressed by policy, counted APART from the proofs"
       (= (lower-stats-unchecked stats) 2))
  (ck! "0 checks emitted" (= (lower-stats-emitted stats) 0)))

;; --- a check that survives --------------------------------------------------
;; If the analysis cannot discharge it and no policy suppressed it, the check
;; MUST reach codegen. Silently dropping it would be a memory-safety hole.
(let-values ([(prog stats)
              (lower-program
               '(let ([v raw-f64 (primcall flvector-ref
                                           ([type-check checked] [bounds-check checked])
                                           b i)])
                  v)
               'entry)])
  ;; A bounds check needs a LIMIT, and the primcall carries the vector rather
  ;; than its length, so lowering materialises the length with `vlen` first.
  ;; Before this the check was handed the whole operand list and the limit was
  ;; simply absent from the IR.
  (ck! "a checked primcall emits its checks, materialising the bounds limit"
       (equal? (ops prog) '(chk vlen chk load)))
  (ck! "and they are counted as emitted, not proved"
       (and (= (lower-stats-emitted stats) 2)
            (= (lower-stats-proved stats) 0))))

;; --- proved and unchecked emit the SAME code and mean different things ------
(let-values ([(p1 s1) (lower-program
                       '(let ([v raw-f64 (primcall flvector-ref
                                                   ([bounds-check proved]) b i)]) v)
                       'entry)]
             [(p2 s2) (lower-program
                       '(let ([v raw-f64 (primcall flvector-ref
                                                   ([bounds-check unchecked]) b i)]) v)
                       'entry)])
  (ck! "proved and unchecked produce identical instructions"
       (equal? (ops p1) (ops p2)))
  (ck! "but are reported separately, which is the whole point"
       (and (= (lower-stats-proved s1) 1) (= (lower-stats-unchecked s1) 0)
            (= (lower-stats-proved s2) 0) (= (lower-stats-unchecked s2) 1))))

;; --- primitives with no machine op are refused, not silently dropped --------
(set! checks (+ checks 1))
(let ([caught #f])
  (guard (e (#t (set! caught #t)))
    ;; `cons` was the example, then `fxremainder`, and BOTH now lower to a
    ;; runtime call. Every primitive in lang.ss's table has a machine op or a
    ;; runtime entry today, so the example has to be a name that is not a
    ;; primitive at all.
    ;;
    ;; That is a weaker test than it was and it is worth keeping anyway: the
    ;; property is that an unlowerable primcall RAISES rather than being
    ;; dropped, because a dropped primcall is a silently wrong program, and
    ;; the day someone adds a primitive to lang.ss without adding it here is
    ;; the day it matters again.
    (lower-program '(let ([v raw-word (primcall fxgcd () a b)]) v) 'entry))
  (if caught
      (display "  ok   a primitive with no machine op RAISES\n")
      (begin (set! failures (+ failures 1))
             (display "  FAIL unlowerable primitive silently dropped\n"))))

;; --- comparisons lower by operand type -------------------------------------
(let-values ([(pi si) (lower-program '(let ([t raw-word (primcall fx< () a b)]) t) 'entry)]
             [(pf sf) (lower-program '(let ([t raw-word (primcall fl< () a b)]) t) 'entry)])
  (ck! "fx< lowers to cmp-lt and fl< to fcmp-lt, not the same op"
       (and (equal? (ops pi) '(cmp-lt)) (equal? (ops pf) '(fcmp-lt)))))


;; --- a literal's storage class follows its TYPE ---------------------------
;; (define days-per-year 365.24) lowered to (const t raw-word 365.24): a double
;; declared an integer. The allocator would put it in a GPR and every
;; instruction reading it would be the integer one, operating on a bit pattern
;; that is an IEEE double.
(define (const-class-of prog)
  (caddr (car (cadr (cadr (car (cadr prog)))))))

(let-values ([(p st) (lower-program '(let ([x raw-word (quote 365.24)]) x) 'e)])
  (ck! "a flonum literal is raw-f64 even when the binding said raw-word"
       (eq? (const-class-of p) 'raw-f64)))
(let-values ([(p st) (lower-program '(let ([x raw-word (quote 7)]) x) 'e)])
  (ck! "an exact integer literal stays raw-word"
       (eq? (const-class-of p) 'raw-word)))
(let-values ([(p st) (lower-program '(let ([x raw-f64 (quote 1.5)]) x) 'e)])
  (ck! "and a declared raw-f64 binding is left alone"
       (eq? (const-class-of p) 'raw-f64)))

;; A DIVISION CHECK READS THE DIVISOR AND NOTHING ELSE.
;;
;; `check-operands` had no case for it, so it fell through to "hand the check
;; every operand the primcall had" -- two, for a quotient -- and both selectors
;; refused with "division check expects a divisor". So `(fxquotient a 0)` did
;; not compile at all, and the trap it was supposed to reach did not exist.
;;
;; Asserted here rather than end to end because integer division is not
;; implemented on either target yet: the selector refuses `div` itself with
;; "idiv hardwires the rdx:rax pair, which the register partition does not
;; model". That is a separate and much larger gap, and it is filed.
(let-values ([(prog stats)
              (lower-program
               '(let ([q raw-word (primcall fxquotient ([div-check checked]) a b)])
                  q)
               'entry)])
  ;; `call`, not `div`: integer division is a runtime routine, because idiv
  ;; hardwires rdx:rax and regs.ss allocates from disjoint class pools. See
  ;; runtime.ss.
  (ck! "a division check is emitted, before the call that does the dividing"
       (equal? (ops prog) '(chk call)))
  (ck! "and it carries ONE operand, the divisor, not the whole operand list"
       (let ((chk (car (cadr (cadr (car (cadr prog)))))))
         (and (eq? (car chk) 'chk)
              (eq? (cadr chk) 'div-check)
              (= (length (cddddr chk)) 1)
              (eq? (car (cddddr chk)) 'b)))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
