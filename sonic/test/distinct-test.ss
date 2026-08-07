;;; `declare-distinct`: the surface form, and what it buys.
;;;
;;; The premise existed in Lcore and `(sonic alias)` consumed it correctly from
;;; hand-built IR, but there was no special form, so no programmer could write
;;; it and nbody's real entry point still got `may` for everything. This file
;;; tests the path that was missing, in the three places it can break:
;;;
;;;   1. the SURFACE form lowers to `declare-distinct`, hygienically, with the
;;;      renamed binders the rest of the expander produces;
;;;   2. `parse` carries it into Lcore;
;;;   3. two parameters under it answer `must-not` from `alias-query`, and the
;;;      same two without it answer `may`. That one pair is the whole point:
;;;      it is the difference between vectorizing nbody's inner loop and not.
;;;
;;; THE SPELLING. `declare-distinct`, the same name the core language uses. C99
;;; writes `restrict` as a qualifier on a pointer declarator and Scheme has no
;;; declarator to hang it on; Ada writes it as a pragma, which is this shape.
;;; Not `assert-distinct`, because `assert` names something checked at run time
;;; in every Scheme that has one, and this is checked nowhere, ever.
;;;
;;; Run: scheme -q --libdirs src:vendor/nanopass --script test/distinct-test.ss
;;;      (from sonic/)

(import (chezscheme) (nanopass)
        (sonic lang) (sonic read) (sonic expand) (sonic parse) (sonic alias))

(define failures 0)
(define checks 0)

(define (check! name ok)
  (set! checks (+ checks 1))
  (unless ok
    (set! failures (+ failures 1))
    (printf "FAIL: ~a\n" name)))

(define (check-equal! name got want)
  (set! checks (+ checks 1))
  (unless (equal? got want)
    (set! failures (+ failures 1))
    (printf "FAIL: ~a\n  got:  ~s\n  want: ~s\n" name got want)))

(define (must-fail name thunk)
  (set! checks (+ checks 1))
  (let ([ok (guard (e (#t #t)) (thunk) #f)])
    (unless ok
      (set! failures (+ failures 1))
      (printf "FAIL: ~a  (expected an error, got none)\n" name))))

(define (find head form)
  (cond [(and (pair? form) (eq? (car form) head)) form]
        [(pair? form) (or (find head (car form)) (find head (cdr form)))]
        [else #f]))

(define (count head form)
  (cond [(and (pair? form) (eq? (car form) head))
         (+ 1 (apply + (map (lambda (f) (count head f)) (cdr form))))]
        [(pair? form) (+ (count head (car form)) (count head (cdr form)))]
        [else 0]))

(printf "declare-distinct:\n")

;; ===========================================================================
;; 1. the surface form lowers to declare-distinct
;; ===========================================================================

(define lowered
  (expand-expression '(lambda (p v) (declare-distinct (p v) (flvector-length p)))))

(let ([dd (find 'declare-distinct lowered)])
  (check! "a surface declare-distinct survives expansion" (and dd #t))
  (check-equal! "with two names" (length (cadr dd)) 2)
  (check! "and they are the lambda's renamed binders, not the source spelling"
          (equal? (cadr dd) (cadr lowered)))
  (check! "the source names are gone"
          (not (memq 'p (cadr dd)))))

;; Hygiene goes through the same door as every other keyword: a macro whose
;; template says `declare-distinct` still gets the special form, and a body
;; introduced by the macro cannot capture the names.
(check! "a macro may generate the form"
        (and (find 'declare-distinct
                   (car (expand-program
                         '((define-syntax kernel
                             (syntax-rules ()
                               ((_ (a b) body) (declare-distinct (a b) body))))
                           (lambda (x y) (kernel (x y) (flvector-length x)))))))
             #t))

;; --- the refusals ----------------------------------------------------------
;;
;; Both of these are typos every time, and this is the one place either can be
;; caught cheaply: `alias-query` will not answer `must-not` for a name against
;; itself, so a group that names one variable, or names one twice, asserts
;; exactly nothing.

(must-fail "a group of one is refused"
           (lambda () (expand-expression '(lambda (p) (declare-distinct (p) p)))))

(must-fail "a repeated name is refused"
           (lambda () (expand-expression '(lambda (p) (declare-distinct (p p) p)))))

(must-fail "a non-identifier is refused"
           (lambda () (expand-expression '(lambda (p) (declare-distinct (p 1) p)))))

(must-fail "an empty body is refused"
           (lambda () (expand-expression '(lambda (p v) (declare-distinct (p v))))))

;; ===========================================================================
;; 2. it reaches Lcore
;; ===========================================================================

(let* ([core (unparse-Lcore (parse-expression lowered))]
       [dd (find 'declare-distinct core)])
  (check! "declare-distinct reaches Lcore" (and dd #t))
  (check-equal! "carrying both names" (length (cadr dd)) 2))

;; parse refuses the same two shapes, so hand-written core input cannot smuggle
;; a vacuous premise past the expander.
(must-fail "parse refuses a group of one"
           (lambda () (parse-expression '(declare-distinct (a) a))))

;; ===========================================================================
;; 3. THE ONE THAT MATTERS: must-not with the premise, may without it
;; ===========================================================================
;;
;; This is nbody's real entry point in miniature. The kernel takes its arrays as
;; ARGUMENTS, so their points-to sets are top and they count as escaped, and
;; every test in `alias-query` below the premise answers `may`. The premise is
;; the only thing that can change the answer, and it is the answer stage 10
;; needs before it may reorder a read against a write.

(define (kernel-with-premise)
  (with-output-language (Lanf Expr)
    `(lambda (p v)
       (declare-distinct (p v)
         (seq p v)))))

(define (kernel-without-premise)
  (with-output-language (Lanf Expr)
    `(lambda (p v)
       (seq p v))))

(let ([tbl (alias-analyze (kernel-with-premise))])
  (check-equal! "two parameters under declare-distinct answer must-not"
                (alias-query tbl 'p 'v) 'must-not)
  (check-equal! "and symmetrically"
                (alias-query tbl 'v 'p) 'must-not)
  (check! "the premise is visible on its own"
          (alias-declared-distinct? tbl 'p 'v))
  ;; A name is never distinct from itself, whatever the programmer wrote. Two
  ;; occurrences of one variable are one object.
  (check-equal! "but a parameter still may-aliases itself"
                (alias-query tbl 'p 'p) 'may))

(let ([tbl (alias-analyze (kernel-without-premise))])
  (check-equal! "the same two parameters without the premise answer may"
                (alias-query tbl 'p 'v) 'may)
  (check! "and no premise is recorded"
          (not (alias-declared-distinct? tbl 'p 'v))))

;; Three names in one group is three distinct pairs, which is the shape
;; config-sonic's kernels actually use.
(let ([tbl (alias-analyze
            (with-output-language (Lanf Expr)
              `(lambda (p v m)
                 (declare-distinct (p v m)
                   (seq p (seq v m))))))])
  (check-equal! "p against v" (alias-query tbl 'p 'v) 'must-not)
  (check-equal! "p against m" (alias-query tbl 'p 'm) 'must-not)
  (check-equal! "v against m" (alias-query tbl 'v 'm) 'must-not))

;; ===========================================================================
;; 4. the benchmark variant
;; ===========================================================================

(define (find-bench-dir)
  (let loop ([cands '("../bench/nbody/" "bench/nbody/" "./bench/nbody/")])
    (cond [(null? cands) #f]
          [(file-exists? (string-append (car cands) "config-sonic.sps")) (car cands)]
          [else (loop (cdr cands))])))

(define bench-dir (find-bench-dir))

(newline)
(if (not bench-dir)
    (begin (printf "FAIL: cannot find bench/nbody; run this from sonic/\n")
           (set! failures (+ failures 1)))
    (let* ([source (read-all-from-file (string-append bench-dir "config-sonic.sps"))]
           [expanded (expand-program source)])
      (printf "bench/nbody/config-sonic.sps:\n")
      (check-equal! "three kernels declare their arrays distinct"
                    (count 'declare-distinct expanded) 3)
      ;; The names under each group are the kernel's own parameters, renamed.
      ;; If they were not, the premise would be about something else entirely.
      (let ([groups (let walk ([f expanded] [acc '()])
                      (cond [(and (pair? f) (eq? (car f) 'declare-distinct))
                             (walk (cddr f) (cons (cadr f) acc))]
                            [(pair? f) (walk (cdr f) (walk (car f) acc))]
                            [else acc]))])
        (check-equal! "and every group has at least two names"
                      (map (lambda (g) (>= (length g) 2)) groups)
                      '(#t #t #t))
        (check! "no group repeats a name"
                (for-all (lambda (g)
                           (let dup ([ns g] [seen '()])
                             (cond [(null? ns) #t]
                                   [(memq (car ns) seen) #f]
                                   [else (dup (cdr ns) (cons (car ns) seen))])))
                         groups))
        (printf "  groups: ~s\n" (reverse groups)))))

(newline)
(printf "~a checks, ~a failures\n" checks failures)
(if (> failures 0) (exit 1) (begin (printf "PASS\n") (exit 0)))
