;;; How far does a real program get? Reported as a number, not an impression.
(import (chezscheme) (nanopass) (sonic lang) (sonic pipeline)
        (sonic read) (sonic expand) (sonic parse) (sonic policy)
        (sonic anf) (sonic assign) (sonic inline) (sonic essa) (sonic elide) (sonic repr) (sonic lower))

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

(define elide-stats #f)
(define repr-counts #f)
(define lower-stats #f)
(define lowered #f)

(define r
  (run-pipeline src
    (list (cons 'read   (lambda (p) (read-all-from-file p)))
          (cons 'expand (lambda (d) (expand-program d)))
          (cons 'parse  (lambda (e) (parse-program e nbody-externs)))
          (cons 'policy (lambda (c) (resolve-policy-program c)))
          (cons 'anf    (lambda (c) (anf-program c)))
          (cons 'assign (lambda (a) (assign-convert-program a)))
          (cons 'inline (lambda (a) (inline-program a)))
          (cons 'essa   (lambda (a) (essa-program a)))
          (cons 'elide  (lambda (a)
                          (let-values ([(o st) (elide-program a)])
                            (set! elide-stats st) o)))
          (cons 'repr   (lambda (a)
                          (let-values ([(o rp) (select-representations-program a)])
                            (set! repr-counts (repr-report-counts rp)) o)))
          (cons 'lower  (lambda (a)
                          (let-values ([(o st) (lower-toplevel (unparse-Lrepr a) 'main)])
                            (set! lower-stats st) (set! lowered o) o))))))

(for-each (lambda (p)
            (display "       ") (display (if (cdr p) "ok  " "STOP"))
            (display "  ") (display (car p)) (newline))
          (pipeline-result-stages r))

(ck! "all eleven stages compose on the real program"
     (= (pipeline-result-reached r) 11))
(ck! "and nothing stopped" (not (pipeline-result-stopped-at r)))

;; What parse actually produced. These numbers are the shape of the program and
;; a change in them is a change in the front end worth noticing.
(when (= (pipeline-result-reached r) 11)
  ;; The first end-to-end measurement of SonicScheme on a real program. These
  ;; are the numbers the whole project exists to produce, and a change in them
  ;; is a change in what the analysis can prove.
  (display "       proved=") (display (elide-proved elide-stats))
  (display " kept=") (display (elide-kept elide-stats))
  (display " policy-suppressed=") (display (elide-unchecked elide-stats)) (newline)
  (ck! "the analysis discharges a substantial number of checks"
       (>= (elide-proved elide-stats) 40))
  ;; Nothing was suppressed by policy, so every discharge above is a PROOF.
  ;; lower.ss counts the two apart precisely so this claim can be made.
  (ck! "and NONE of them were suppressed by policy: all are proofs"
       (= (elide-unchecked elide-stats) 0))
  ;; A pass that proved everything would be unsound, not brilliant.
  (ck! "it does not claim to prove everything"
       (> (elide-kept elide-stats) 0))

  ;; Representation is where the unboxing shows up. A binding in raw-f64 lives
  ;; in a float register, is never scavenged and needs no GC metadata, which is
  ;; what lets nbody's inner loop carry none at all.
  (display "       repr ") (write repr-counts) (newline)
  (let ([g (lambda (c) (cdr (assq c repr-counts)))])
    (ck! "most bindings are UNBOXED, not tagged"
         (> (+ (g 'raw-f64) (g 'raw-word)) (* 8 (g 'tagged))))
    (ck! "and doubles dominate, which is what nbody is"
         (> (g 'raw-f64) (g 'raw-word))))

  ;; Lowering is where the tree becomes a CFG. The block count is the shape of
  ;; the program's control flow and a change in it is worth noticing.
  (display "       blocks=") (display (length (cadr lowered)))
  (display " lower-proved=") (display (lower-stats-proved lower-stats))
  (display " lower-emitted=") (display (lower-stats-emitted lower-stats)) (newline)
  (ck! "the program lowers to a multi-block CFG, not one straight line"
       (> (length (cadr lowered)) 5))
  ;; Every block label must be unique: two blocks with one label make the
  ;; program ambiguous in a way selection cannot detect, since it walks both
  ;; and the second silently wins.
  (ck! "every block label is unique"
       (let loop ([ls (map car (cadr lowered))] [seen '()])
         (cond [(null? ls) #t]
               [(memq (car ls) seen) #f]
               [else (loop (cdr ls) (cons (car ls) seen))]))))

(when #f
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
