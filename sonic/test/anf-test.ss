;;; A-normalization. Lcore -> Lanf.
;;;
;;; Two halves, and the second one is the acceptance criterion.
;;;
;;; UNIT. Every intermediate is named; operands are atoms; EVALUATION ORDER IS
;;; LEFT TO RIGHT and is asserted as an order rather than as "it ran"; a tail
;;; call stays a `tailcall` and a non-tail one does not become one; a compound
;;; `if` test is let-bound because Lanf's `if` takes an atom.
;;;
;;; HOW LEFT-TO-RIGHT IS PROVED. The pass hands out names in the order it emits
;;; bindings, so the numbering of the output IS the evaluation order, and the
;;; output is a straight chain of `let`s whose textual order is that order. So a
;;; test can assert the whole chain: `(fx+ (f 1) (g 2))` must bind the call to
;;; `f` BEFORE the call to `g`, and the assertion is on the sequence of
;;; right-hand sides, not on a count. This matters because
;;; bench/nbody/SPEC.md's oracle compares bit-exactly and the association order
;;; of a flonum sum is observable in the result: see the worked pair at the top
;;; of sonic/src/sonic/numeric.ss, 1.734723475976807e-18 against
;;; 9.020562075079397e-19.
;;;
;;; ACCEPTANCE. bench/nbody/config-sonic.sps goes read -> expand -> parse ->
;;; policy -> anf and comes out as a valid Lanf program, and then survives
;;; assignment conversion, which is the pass that states the ANF invariant as a
;;; requirement on its input.
;;;
;;; Run: scheme -q --libdirs src:vendor/nanopass --script test/anf-test.ss
;;;      (from sonic/)

(import (chezscheme) (nanopass)
        (sonic lang) (sonic read) (sonic expand) (sonic parse)
        (sonic policy) (sonic anf) (sonic assign))

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

;; surface -> Lanf, unparsed.
(define (A form) (unparse-Lanf (anf (parse-expression (expand-expression form)))))

;; The chain of `let` right-hand sides, in the order the output writes them.
;; That order is the evaluation order, which is what these tests are about.
(define (chain form)
  (let loop ([f form] [acc '()])
    (if (and (pair? f) (eq? (car f) 'let))
        (loop (caddr f) (cons (cadr (car (cadr f))) acc))
        (reverse acc))))

(define (count head form)
  (cond [(and (pair? form) (eq? (car form) 'quote)) 0]
        [(and (pair? form) (eq? (car form) head))
         (+ 1 (apply + (map (lambda (f) (count head f)) (cdr form))))]
        [(pair? form) (+ (count head (car form)) (count head (cdr form)))]
        [else 0]))

;; Every operand of every `call`, `primcall`, `tailcall` and `if` in the tree.
;; In Lanf all of them must be symbols; one that is not is an unnamed
;; intermediate and the whole point of the pass has been missed.
(define (operands form)
  (let scan ([f form] [acc '()])
    (cond
     [(and (pair? f) (eq? (car f) 'quote)) acc]
     [(and (pair? f) (memq (car f) '(primcall)))
      (scan (cdddr f) (append (cdddr f) acc))]
     [(and (pair? f) (memq (car f) '(call tailcall)))
      (scan (cdr f) (append (cdr f) acc))]
     [(and (pair? f) (eq? (car f) 'if))
      (scan (cdr f) (cons (cadr f) acc))]
     [(pair? f) (scan (car f) (scan (cdr f) acc))]
     [else acc])))

(printf "A-normalization:\n")

;; ===========================================================================
;; 1. every intermediate is named
;; ===========================================================================

;; The nested arithmetic case, stated in full rather than by a predicate: this
;; is what "fully named" looks like and the exact numbering is the order claim.
(check-equal! "a nested flonum expression is fully named, left to right"
              (A '(fl+ (fl* a b) (fl* c d)))
              '(let ([t.1 (primcall fl* ((fp-contract checked)) a b)])
                 (let ([t.2 (primcall fl* ((fp-contract checked)) c d)])
                   (let ([t.3 (primcall fl+ ((fp-contract checked)) t.1 t.2)])
                     t.3))))

;; Three levels deep, with constants, which also have to be named because Lanf's
;; operands are variables and not data.
(check! "no operand anywhere is a compound expression"
        (for-all symbol?
                 (operands (A '(fx+ (fx* (fx- a b) c) (fx+ d (fx* e f)))))))

(check! "constants are named too; Lanf operands are variables"
        (for-all symbol? (operands (A '(fx+ a 1)))))

;; The exact shape nbody's inner loop has, which fixtures.ss pins by hand.
(check-equal! "nbody's inner access normalizes to the hand-written fixture shape"
              (A '(flvector-ref b (fx+ (fx* i seven) k)))
              '(let ([t.1 (primcall fx* ((overflow-check checked)) i seven)])
                 (let ([t.2 (primcall fx+ ((overflow-check checked)) t.1 k)])
                   (let ([t.3 (primcall flvector-ref
                                        ((type-check checked) (bounds-check checked))
                                        b t.2)])
                     t.3))))

;; ===========================================================================
;; 2. left-to-right evaluation order, asserted as an ORDER
;; ===========================================================================
;;
;; Two calls in one expression are the sharpest instrument available here: a
;; call is the one operand whose evaluation is unmistakably a step, so if the
;; chain names `g` before `f` the order has been swapped.

(check-equal! "the left operand's call is bound before the right operand's"
              (chain (A '(fx+ (f 1) (g 2))))
              '('1
                (call f t.1)
                '2
                (call g t.3)
                (primcall fx+ ((overflow-check checked)) t.2 t.4)))

;; The same claim over four operands, which catches a `map` that happens to run
;; right to left as well as one that reverses.
(check-equal! "four operands are named in source order"
              (chain (A '(fl+ (fl* (p) (q)) (fl* (r) (s)))))
              '((call p)
                (call q)
                (primcall fl* ((fp-contract checked)) t.1 t.2)
                (call r)
                (call s)
                (primcall fl* ((fp-contract checked)) t.4 t.5)
                (primcall fl+ ((fp-contract checked)) t.3 t.6)))

;; The operator position is evaluated before the operands, and before them all.
(check-equal! "a call evaluates its operator first"
              (chain (A '((f) (g) (h))))
              '((call f) (call g) (call h)))

;; A `begin` is a sequence and stays one. This is the same order claim in
;; statement position rather than operand position.
(check-equal! "statement order survives"
              (chain (A '(begin (f 1) (g 2))))
              '('1 (call f t.1) '2))

;; A multi-binding `let` evaluates every init BEFORE any binder exists, so the
;; inits are named in order and the binders attach afterwards. Binding them as
;; we went would be `let*`, and a later init could then see an earlier binder.
(check-equal! "a multi-binding let names all its inits before binding any of them"
              (chain (A '(let ((u (f 1)) (w (g 2))) u)))
              '('1 (call f t.1) '2 (call g t.3) t.2 t.4))

;; ===========================================================================
;; 3. tail position
;; ===========================================================================

(check-equal! "a call in tail position is a tailcall"
              (A '(f a b))
              '(tailcall f a b))

(check-equal! "a call in operand position is NOT a tailcall"
              (A '(f (g a)))
              '(let ([t.1 (call g a)]) (tailcall f t.1)))

(check! "an operand call never becomes a tailcall"
        (= 0 (count 'tailcall (A '(fx+ (f a) (g b))))))

;; The loop shape. A named let is a letrec of a lambda, and the back edge has to
;; be a tail call or the loop is a stack leak; R5RS's proper tail recursion is
;; the one performance guarantee the standard made that ANSI CL never did.
(check-equal! "a named let's back edge stays a tail call"
              (A '(let loop ((i 0)) (if (fx< i n) (loop (fx+ i 1)) i)))
              '(letrec ([loop%1 (lambda (i%2)
                                  (let ([t.1 (primcall fx< () i%2 n)])
                                    (if t.1
                                        (let ([t.2 '1])
                                          (let ([t.3 (primcall fx+ ((overflow-check checked))
                                                               i%2 t.2)])
                                            (tailcall loop%1 t.3)))
                                        i%2)))])
                 (let ([t.4 '0]) (tailcall loop%1 t.4))))

;; A letrec right-hand side that is a lambda stays a BARE lambda rather than
;; being wrapped in a `let`. (sonic essa) matches on that shape to place a loop
;; header's phi, and a wrapper would silently lose every header.
(check! "a letrec-bound lambda is not wrapped"
        (let ([out (A '(let loop ((i 0)) (loop i)))])
          (eq? 'lambda (car (cadr (car (cadr out)))))))

;; Both arms of a tail `if` are tail positions.
(check-equal! "both arms of a tail if are tail"
              (count 'tailcall (A '(if c (f 1) (g 2))))
              2)

;; ===========================================================================
;; 4. Lanf's `if` takes an atom
;; ===========================================================================

(check-equal! "a compound if test is let-bound"
              (A '(if (fx< i n) a b))
              '(let ([t.1 (primcall fx< () i n)]) (if t.1 a b)))

(check! "an if test is always a symbol"
        (for-all symbol?
                 (operands (A '(if (fx< (fx+ i 1) n) a b)))))

;; A test that is already a variable is left alone; nothing is gained by
;; aliasing it and the sigma in (sonic essa) hangs off the comparison, not off
;; the copy.
(check-equal! "a variable test is not rebound"
              (A '(if c a b))
              '(if c a b))

;; A value-position `if` has nowhere to put its result, because `if` is not a
;; SimpleExpr. The continuation is NAMED rather than duplicated into both arms.
(check-equal! "a value-position if names its continuation instead of copying it"
              (A '(let ((x (if c 1 2))) (fx+ x 1)))
              '(letrec ([join.1 (lambda (x%1)
                                  (let ([t.4 '1])
                                    (let ([t.5 (primcall fx+ ((overflow-check checked))
                                                         x%1 t.4)])
                                      t.5)))])
                 (if c
                     (let ([t.2 '1]) (tailcall join.1 t.2))
                     (let ([t.3 '2]) (tailcall join.1 t.3)))))

;; ===========================================================================
;; 5. the declaration forms survive, with their scopes intact
;; ===========================================================================

(check-equal! "declare-distinct survives normalization"
              (A '(declare-distinct (p v) (flvector-ref p i)))
              '(declare-distinct (p v)
                 (let ([t.1 (primcall flvector-ref
                                      ((type-check checked) (bounds-check checked))
                                      p i)])
                   t.1)))

(check-equal! "policy survives normalization"
              (A '(policy ((bounds-check #f)) (flvector-ref p i)))
              '(policy ((bounds-check #f))
                 (let ([t.1 (primcall flvector-ref
                                      ((type-check checked) (bounds-check checked))
                                      p i)])
                   t.1)))

;; The continuation of a value-position `policy` is bound OUTSIDE the policy,
;; not threaded through its body. Threading it would extend a lexical scope past
;; where the programmer wrote it, and the lexical extent is the whole claim D5
;; makes against Chez's global optimize-level.
(check! "a value-position policy does not swallow its continuation"
        (let ([out (A '(fx+ (policy ((overflow-check #f)) (fx* a b)) c))])
          (and (eq? 'letrec (car out))
               ;; the join lambda is a sibling of the policy, not inside it
               (eq? 'policy (car (caddr out))))))

;; ===========================================================================
;; 6. what it refuses
;; ===========================================================================

(must-fail "(void) in operand position is refused, not spelled '()"
           (lambda () (A '(f (void)))))

(must-fail "set! in operand position is refused; it has no value to name"
           (lambda () (A '(fx+ (set! x 1) 2))))

;; Lanf removed `letrec*` and put nothing back, so the sequential guarantee has
;; no representation. All-lambda groups are the case where the two forms agree.
(let ([lam (parse-expression '(letrec* ((f (lambda (x) x))) (f (quote 1))))]
      [val (parse-expression '(letrec* ((a (quote 1))) a))])
  (check! "letrec* of lambdas maps exactly onto letrec"
          (eq? 'letrec (car (unparse-Lanf (anf lam)))))
  (must-fail "letrec* with a non-lambda right-hand side is refused, not silently reordered"
             (lambda () (anf val))))

;; ===========================================================================
;; 7. the acceptance criterion: bench/nbody/config-sonic.sps
;; ===========================================================================

(define (find-bench-dir)
  (let loop ([cands '("../bench/nbody/" "bench/nbody/" "./bench/nbody/")])
    (cond [(null? cands) #f]
          [(file-exists? (string-append (car cands) "config-sonic.sps")) (car cands)]
          [else (loop (cdr cands))])))

(define bench-dir (find-bench-dir))

(define nbody-externs '(command-line length cadr string->number display newline))

(newline)
(if (not bench-dir)
    (begin (printf "FAIL: cannot find bench/nbody; run this from sonic/\n")
           (set! failures (+ failures 1)))
    (let* ([source (read-all-from-file (string-append bench-dir "config-sonic.sps"))]
           [core (parse-program (expand-program source) nbody-externs)]
           [prog (anf-program (resolve-policy-program core))]
           [out (unparse-Lanf prog)])
      (printf "bench/nbody/config-sonic.sps -> Lanf:\n")

      ;; "Valid Lanf" is not an assertion this file makes: nanopass checks every
      ;; constructed term against the grammar, so a program that BUILDS is well
      ;; formed. What is checked here is that it says what the source said.
      (check-equal! "it is still a `top`" (car out) 'top)
      (check-equal! "with the declared externs" (caddr out) nbody-externs)

      (check-equal! "the three kernels' distinctness premises survive"
                    (count 'declare-distinct out) 3)

      (check! "every operand in the whole program is an atom"
              (for-all symbol? (operands out)))

      (check! "the flonum work is still primcalls"
              (> (count 'primcall out) 100))

      ;; Loops are tail calls in this program and there are no assignments, so a
      ;; missing `tailcall` would mean a loop turned into stack growth.
      (check! "the loops are tail calls" (> (count 'tailcall out) 0))

      ;; Assignment conversion states the ANF invariant as a requirement on its
      ;; input and refuses a non-atomic set! right-hand side, so its accepting
      ;; this program is an independent check of the invariant.
      (check! "assignment conversion accepts the result"
              (guard (e (#t #f)) (begin (assign-convert-program prog) #t)))

      (printf "  ~a primcalls, ~a tailcalls, ~a non-tail calls, ~a lets\n"
              (count 'primcall out) (count 'tailcall out)
              (count 'call out) (count 'let out))))

(newline)
(printf "~a checks, ~a failures\n" checks failures)
(if (> failures 0) (exit 1) (begin (printf "PASS\n") (exit 0)))
