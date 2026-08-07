;;; How far does a real program get? Reported as a number, not an impression.
(import (chezscheme) (nanopass) (sonic lang) (sonic pipeline)
        (sonic read) (sonic expand) (sonic parse))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define src (let loop ([ps '("../bench/nbody/config-sonic.sps"
                             "bench/nbody/config-sonic.sps")])
              (cond [(null? ps) #f]
                    [(file-exists? (car ps)) (car ps)]
                    [else (loop (cdr ps))])))

(ck! "the SonicScheme nbody variant exists" (and src #t))

(define r
  (run-pipeline src
    (list (cons 'read   (lambda (p) (read-all-from-file p)))
          (cons 'expand (lambda (d) (expand-program d)))
          (cons 'parse  (lambda (e) (parse-program e nbody-externs))))))

(for-each (lambda (p)
            (display "       ") (display (if (cdr p) "ok  " "STOP"))
            (display "  ") (display (car p)) (newline))
          (pipeline-result-stages r))

(ck! "read, expand and parse all compose on the real program"
     (= (pipeline-result-reached r) 3))
(ck! "and nothing stopped" (not (pipeline-result-stopped-at r)))

;; What parse actually produced. These numbers are the shape of the program and
;; a change in them is a change in the front end worth noticing.
(when (= (pipeline-result-reached r) 3)
  (let* ([u (unparse-Lcore (pipeline-result-note r))]
         [count (lambda (sym) (let f ([x u]) (cond [(pair? x) (+ (f (car x)) (f (cdr x)))]
                                                   [(eq? x sym) 1] [else 0])))])
    (display "       primcall=") (display (count 'primcall))
    (display " set!=") (display (count 'set!))
    (display " declare-distinct=") (display (count 'declare-distinct))
    (display " lambda=") (display (count 'lambda)) (newline)
    (ck! "the program reaches Lcore with primcalls, not surface forms"
         (> (count 'primcall) 100))
    ;; The number LEDGER.md records: nbody boxes nothing, because idiomatic
    ;; Scheme carries loop state in tail-call parameters and updates arrays
    ;; through flvector-set!, which is a store rather than an assignment.
    (ck! "ZERO set! forms, so assignment conversion boxes nothing"
         (= (count 'set!) 0))
    ;; The premise that makes the arrays provably distinct. Without it
    ;; alias-query answers `may` for a kernel that receives its arrays as
    ;; parameters, which is what a real entry point looks like.
    (ck! "declare-distinct survives to Lcore" (>= (count 'declare-distinct) 1))))

;; An UNDECLARED external must be refused, not silently treated as opaque.
;; This is the extern list earning its place: without it a typo reads as a
;; deliberate reference to something outside the compilation unit.
(set! checks (+ checks 1))
(let ([caught #f])
  (guard (e (#t (set! caught #t)))
    (parse-program (expand-program (read-all-from-file src)) '()))
  (if caught
      (display "  ok   parsing with an EMPTY extern list is refused: the names are unbound\n")
      (begin (set! failures (+ failures 1))
             (display "  FAIL an unbound name was silently accepted as external\n"))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
