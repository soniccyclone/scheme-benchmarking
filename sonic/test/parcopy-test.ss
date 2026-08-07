(import (chezscheme) (sonic regs) (sonic parcopy))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define (scr r) (if (memq r (arch-float arch-rv64)) 'ft11 't0))
(define (run ms) (let ([s (make-parcopy-stats 0)])
                   (list (resolve-parallel-copy ms scr s)
                         (parcopy-stats-cycles-broken s))))

;; --- an EXECUTABLE oracle: simulate the emitted sequence ------------------
;; The property is not "it emitted some moves". It is that running the emitted
;; sequence produces the same final state as a true parallel copy, and the only
;; way to know that is to run both.
(define (simulate moves seq)
  (let ([st (make-eq-hashtable)])
    ;; every register starts holding a unique marker for itself
    (for-each (lambda (m)
                (hashtable-set! st (car m) (string->symbol (format "~a0" (car m))))
                (hashtable-set! st (cdr m) (string->symbol (format "~a0" (cdr m)))))
              moves)
    (hashtable-set! st 't0 't00) (hashtable-set! st 'ft11 'ft110)
    (let ([before (let ([h (make-eq-hashtable)])
                    (for-each (lambda (k) (hashtable-set! h k (hashtable-ref st k #f)))
                              (vector->list (hashtable-keys st)))
                    h)])
      ;; run the emitted sequence
      (for-each (lambda (m) (hashtable-set! st (car m) (hashtable-ref st (cdr m) #f))) seq)
      ;; the true parallel copy reads everything from `before`
      (let ([ok #t])
        (for-each (lambda (m)
                    (unless (eq? (hashtable-ref st (car m) #f)
                                 (hashtable-ref before (cdr m) #f))
                      (set! ok #f)))
                  moves)
        ok))))

(define (parallel-correct? ms)
  (let ([r (run ms)]) (simulate ms (car r))))

;; --- acyclic: order is chosen, no scratch needed --------------------------
(ck! "an acyclic copy is reordered and needs no scratch"
     (let ([r (run '((a1 . a0) (a2 . a1)))])
       (and (= (cadr r) 0) (parallel-correct? '((a1 . a0) (a2 . a1))))))

;; --- THE BUG: a two-cycle -------------------------------------------------
;; Emitted naively this gives both registers the same value, silently.
(ck! "a two-cycle is resolved correctly, and needs one scratch"
     (let ([r (run '((a0 . a1) (a1 . a0)))])
       (and (= (cadr r) 1) (parallel-correct? '((a0 . a1) (a1 . a0))))))

(ck! "a naive sequential emission of that same swap is WRONG"
     (not (simulate '((a0 . a1) (a1 . a0)) '((a0 . a1) (a1 . a0)))))

;; --- longer cycles and mixtures ------------------------------------------
(ck! "a three-cycle is resolved" (parallel-correct? '((a0 . a1) (a1 . a2) (a2 . a0))))
(ck! "a cycle plus a chain is resolved"
     (parallel-correct? '((a0 . a1) (a1 . a0) (a3 . a2) (a4 . a3))))
(ck! "two independent cycles need two scratch breaks"
     (let ([r (run '((a0 . a1) (a1 . a0) (a2 . a3) (a3 . a2)))])
       (= (cadr r) 2)))

;; --- self-moves are dropped, not treated as one-element cycles ------------
(ck! "a self-move is dropped"
     (let ([r (run '((a0 . a0) (a2 . a1)))])
       (and (= (length (car r)) 1) (= (cadr r) 0))))

;; --- a float cycle must break through a FLOAT scratch ---------------------
;; Breaking it through an integer register would move a double through a GPR,
;; which on RV64 is a different register file entirely.
(ck! "a float cycle breaks through the float scratch, not an integer one"
     (let ([r (run '((fa0 . fa1) (fa1 . fa0)))])
       (and (= (cadr r) 1)
            (memq 'ft11 (append (map car (car r)) (map cdr (car r))))
            (not (memq 't0 (append (map car (car r)) (map cdr (car r))))))))

;; --- scratch registers are outside every allocatable pool -----------------
;; That is what makes them safe here: no live range can be occupying one.
(ck! "the scratch used is not allocatable"
     (and (not (memq 't0 (arch-raw arch-rv64)))
          (not (memq 'ft11 (arch-float arch-rv64)))))

;; --- block rewriting ------------------------------------------------------
(define (mov-of i) (and (pair? i) (eq? (car i) 'mv) (cons (cadr i) (caddr i))))
(define (emit-mov d s) (list 'mv d s))
(let-values ([(out st) (resolve-moves-in-block
                        arch-rv64
                        '((mv a0 a1) (mv a1 a0) (jalr zero ra 0))
                        mov-of emit-mov)])
  (ck! "a run of moves in a block is rewritten as a parallel copy"
       (= (parcopy-stats-cycles-broken st) 1))
  (ck! "and the non-move instruction is preserved, in place"
       (equal? (car (reverse out)) '(jalr zero ra 0))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
