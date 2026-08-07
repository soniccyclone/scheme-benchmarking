;;; Assignment conversion.
;;;
;;; The pass is cheap to write and easy to write BADLY, and the bad version is
;;; not incorrect, it is slow in the one place this project measures. So the
;;; tests are shaped around the cost rather than around the rewrite:
;;;
;;;   1. a variable nobody assigns is byte-for-byte untouched;
;;;   2. an assigned one gets a cell and its `set!` becomes a store;
;;;   3. a mutated FLONUM local gets an `flvector` cell, so the value it holds
;;;      is still a raw f64 and still reaches a float register, and it is
;;;      REPORTED either way so the residual cost is a number and not a rumour;
;;;   4. the output is still A-normal, checked by walking it rather than by
;;;      trusting nanopass, because the grammar cannot say "operands are atoms"
;;;      for the `set!` production it inherited.
;;;
;;; Run: scheme -q --libdirs src:vendor/nanopass --script test/assign-test.ss
;;;      (from sonic/)

(import (chezscheme) (nanopass) (sonic lang) (sonic assign))

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

;; --- walking the output -----------------------------------------------------

(define (occurrences head form)
  (cond [(and (pair? form) (eq? (car form) head))
         (+ 1 (apply + (map (lambda (f) (occurrences head f)) (cdr form))))]
        [(pair? form) (+ (occurrences head (car form)) (occurrences head (cdr form)))]
        [else 0]))

(define (mentions? sym form)
  (cond [(eq? sym form) #t]
        [(pair? form) (or (mentions? sym (car form)) (mentions? sym (cdr form)))]
        [else #f]))

;; THE ANF INVARIANT, spelled out. nanopass enforces most of it at compile time
;; -- `(primcall pr (...) x* ...)` will not hold an expression -- but it cannot
;; enforce that a `set!`'s right-hand side is an atom, because `set!` came in
;; from Lcore where operands are arbitrary. So this walks the unparsed output
;; and states the whole invariant in one place.
(define (anf-violations form)
  (let walk ([f form] [bad '()])
    (cond
     [(symbol? f) bad]
     [(not (pair? f)) bad]
     [else
      (case (car f)
        [(quote) bad]
        [(if) (let ([bad (if (symbol? (cadr f)) bad (cons f bad))])
                (walk (cadddr f) (walk (caddr f) bad)))]
        [(seq) (walk (caddr f) (walk (cadr f) bad))]
        [(let) (let ([bs (cadr f)])
                 (if (= 1 (length bs))
                     (walk (caddr f) (walk (cadr (car bs)) bad))
                     (cons f bad)))]
        [(letrec) (fold-left (lambda (b b1) (walk (cadr b1) b))
                             (walk (caddr f) bad) (cadr f))]
        [(lambda) (walk (caddr f) bad)]
        [(call tailcall) (if (for-all symbol? (cdr f)) bad (cons f bad))]
        [(primcall) (if (for-all symbol? (cdddr f)) bad (cons f bad))]
        [(void) bad]
        ;; A `set!` in the OUTPUT of this pass is either a store to a global or
        ;; a bug; either way its right-hand side must already be an atom.
        [(set!) (if (or (symbol? (caddr f))
                        (and (pair? (caddr f)) (eq? 'quote (car (caddr f)))))
                    bad
                    (cons f bad))]
        [(declare declare-distinct policy) (walk (caddr f) bad)]
        [else bad])])))

(define (convert e) (assign-convert e))
(define (convert/report e)
  (let-values ([(out r) (assign-convert/report e)]) (cons out r)))

(printf "assignment conversion:\n")

;; ===========================================================================
;; 1. a variable nobody assigns is not touched
;; ===========================================================================

(define untouched
  (with-output-language (Lanf Expr)
    `(let ([a (quote 1)])
       (let ([b (quote 2)])
         (let ([c (primcall fx+ ([overflow-check checked]) a b)])
           c)))))

(check-equal! "a non-assigned variable is left exactly as it was"
              (unparse-Lanf (convert untouched))
              (unparse-Lanf untouched))

(let ([r (cdr (convert/report untouched))])
  (check-equal! "nothing is boxed when nothing is assigned"
                (assign-report-boxed r) '())
  (check-equal! "and nothing is stored" (assign-report-stores r) 0))

;; A mutated NEIGHBOUR must not drag an innocent binding into a cell. This is
;; the precision claim the whole design rests on, so it is tested directly.
(define one-of-two
  (with-output-language (Lanf Expr)
    `(let ([keep (quote 1)])
       (let ([mut (quote 2)])
         (seq (set! mut keep) keep)))))

(let* ([p (convert/report one-of-two)]
       [out (unparse-Lanf (car p))]
       [r (cdr p)])
  (check-equal! "only the assigned variable is boxed"
                (map car (assign-report-boxed r)) '(mut))
  (check! "the unassigned neighbour is still read directly"
          (mentions? 'keep out))
  (check-equal! "and it got no cell of its own"
                (occurrences 'make-vector out) 1))

;; ===========================================================================
;; 2. an assigned variable is boxed, and its set! becomes a store
;; ===========================================================================

(define mutated-fixnum
  (with-output-language (Lanf Expr)
    `(let ([n (quote 0)])
       (let ([one (quote 1)])
         (let ([n1 (primcall fx+ ([overflow-check checked]) n one)])
           (seq (set! n n1) n))))))

(let* ([p (convert/report mutated-fixnum)]
       [out (unparse-Lanf (car p))]
       [r (cdr p)])
  (check-equal! "the assigned variable is boxed"
                (map car (assign-report-boxed r)) '(n))
  (check-equal! "a cell is allocated for it"
                (occurrences 'make-vector out) 1)
  (check-equal! "the set! became a store"
                (occurrences 'vector-set! out) 1)
  (check-equal! "and no set! survives"
                (occurrences 'set! out) 0)
  (check-equal! "the store was counted" (assign-report-stores r) 1)
  (check! "every read of it is now a load"
          (>= (occurrences 'vector-ref out) 2)))

;; ===========================================================================
;; 3. THE COST. A mutated flonum local, reported, and in an flvector cell.
;; ===========================================================================
;;
;; The accumulator shape: `acc` starts at a flonum literal and every value
;; assigned to it comes from a flonum primitive. That is provable without any
;; type inference, and it is the difference between a raw f64 in a float
;; register and a tagged pointer in a value register.

(define mutated-flonum
  (with-output-language (Lanf Expr)
    `(let ([acc (quote 0.0)])
       (let ([acc1 (primcall fl+ ([fp-contract checked]) acc acc)])
         (seq (set! acc acc1) acc)))))

(let* ([p (convert/report mutated-flonum)]
       [out (unparse-Lanf (car p))]
       [r (cdr p)])
  (check-equal! "a mutated flonum local is REPORTED, so the cost is visible"
                (assign-report-flonum-boxed r) '(acc))
  (check-equal! "and it is the only kind of cost here"
                (assign-report-tagged-boxed r) '())
  (check-equal! "its cell is an flvector, so the value stays a raw f64"
                (occurrences 'make-flvector out) 1)
  (check-equal! "reads are flvector-ref, which yields raw-f64 and reaches a float register"
                (> (occurrences 'flvector-ref out) 0) #t)
  (check-equal! "writes are flvector-set!"
                (occurrences 'flvector-set! out) 1)
  (check-equal! "no general vector is allocated for it"
                (occurrences 'make-vector out) 0))

;; The fallback, and it must be conservative: if anything assigned to the
;; variable is not provably a flonum, an `flvector` cell would be a type error
;; waiting to happen, so it gets a general cell and pays the tagged price.
(define mutated-mixed
  (with-output-language (Lanf Expr)
    `(let ([acc (quote 0.0)])
       (let ([n (quote 1)])
         (seq (set! acc n) acc)))))

(let* ([p (convert/report mutated-mixed)]
       [out (unparse-Lanf (car p))]
       [r (cdr p)])
  (check-equal! "a variable that is not provably flonum falls back to a general cell"
                (assign-report-tagged-boxed r) '(acc))
  (check-equal! "no flvector cell is created on a guess"
                (occurrences 'make-flvector out) 0))

;; A parameter's value comes from callers, so nothing about it is provable here
;; and it cannot get an flvector cell. Escape analysis (cqs.9) is what changes
;; this, by removing the cell entirely rather than by re-typing it.
(define mutated-parameter
  (with-output-language (Lanf Expr)
    `(lambda (x)
       (let ([one (quote 1)])
         (seq (set! x one) x)))))

(let* ([p (convert/report mutated-parameter)]
       [out (unparse-Lanf (car p))]
       [r (cdr p)])
  (check-equal! "an assigned parameter is boxed at entry"
                (map car (assign-report-boxed r)) '(x))
  (check-equal! "and gets a general cell, because a caller's value is opaque"
                (assign-report-tagged-boxed r) '(x))
  (check-equal! "the cell is filled from the parameter itself"
                (occurrences 'make-vector out) 1))

;; ===========================================================================
;; 4. the ANF invariant survives
;; ===========================================================================

(for-each
 (lambda (named)
   (let* ([name (car named)]
          [out (unparse-Lanf (convert (cdr named)))]
          [bad (anf-violations out)])
     (check-equal! (string-append "ANF invariant survives: " name) bad '())))
 (list (cons "untouched" untouched)
       (cons "one of two" one-of-two)
       (cons "mutated fixnum" mutated-fixnum)
       (cons "mutated flonum" mutated-flonum)
       (cons "mutated parameter" mutated-parameter)))

;; The cell reads sit in their own bindings, which is the only way an operand
;; position can hold one. Counting them is how we know the conversion did not
;; quietly put a primcall where a variable belongs.
(let ([out (unparse-Lanf (convert mutated-flonum))])
  (check! "each cell read is bound by its own let"
          (>= (occurrences 'let out) 4)))

;; ===========================================================================
;; 5. what the pass refuses
;; ===========================================================================

;; The right-hand side of a set! has to be an atom already. There is no way to
;; name an arbitrary Expr's result in ANF, so this is a refusal rather than a
;; workaround.
(must-fail "a non-atomic set! right-hand side is refused"
           (lambda ()
             (convert (with-output-language (Lanf Expr)
                        `(let ([x (quote 0)])
                           (set! x (seq (quote 1) (quote 2))))))))

;; A premise names a VARIABLE. After boxing, that name is the cell rather than
;; the array the programmer was talking about, so rewriting it would turn a
;; true premise into a false one -- and `declare-distinct` is the one path in
;; the alias analysis that can miscompile.
(must-fail "declare-distinct over an assigned variable is refused"
           (lambda ()
             (convert (with-output-language (Lanf Expr)
                        `(lambda (p v)
                           (declare-distinct (p v)
                             (let ([z (quote 0)])
                               (seq (set! p z) v))))))))

;; ===========================================================================
;; 6. an internal define that is later assigned
;; ===========================================================================
;;
;; The expander turns internal definitions into `letrec`, so this is what
;; `(define n 0) (set! n 1)` inside a body actually looks like by the time it
;; gets here. The cell has to exist BEFORE the right-hand sides run, because a
;; recursive reference reads it, so the binding leaves the letrec entirely.

(define internal-define
  (with-output-language (Lanf Expr)
    `(letrec ([n (quote 0)])
       (let ([one (quote 1)])
         (seq (set! n one) n)))))

(let* ([p (convert/report internal-define)]
       [out (unparse-Lanf (car p))]
       [r (cdr p)])
  (check-equal! "an assigned letrec binding is boxed"
                (map car (assign-report-boxed r)) '(n))
  (check-equal! "and the letrec no longer binds it"
                (occurrences 'letrec out) 0)
  (check-equal! "its initial value is stored into the cell"
                (occurrences 'vector-set! out) 2)
  (check-equal! "ANF invariant survives: internal define"
                (anf-violations out) '()))

;; ===========================================================================
;; 7. globals are not locals
;; ===========================================================================
;;
;; A top-level binding is already a mutable location: `(sonic gcell)` makes a
;; global reference an indirect load and redefinition a store. Boxing one would
;; put a cell inside a cell.

(define prog
  (with-output-language (Lanf Program)
    `(top ([g (quote 0)]) (ext) (set! g g))))

(let-values ([(out r) (assign-convert-program/report prog)])
  (check-equal! "a top-level name is not boxed"
                (assign-report-boxed r) '())
  (check-equal! "and its set! is left for (sonic gcell)"
                (occurrences 'set! (unparse-Lanf out)) 1))

;; A local inside a top-level definition is still a local.
(define prog-local
  (with-output-language (Lanf Program)
    `(top ([f (lambda (a)
                (let ([n (quote 0)])
                  (seq (set! n a) n)))])
          ()
          (void))))

(let-values ([(out r) (assign-convert-program/report prog-local)])
  (check-equal! "a local inside a top-level definition is boxed"
                (map car (assign-report-boxed r)) '(n)))

;; --- assigned-variables ----------------------------------------------------

(check-equal! "assigned-variables names exactly the mutated ones"
              (list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
                         (assigned-variables one-of-two))
              '(mut))

(newline)
(printf "~a checks, ~a failures\n" checks failures)
(if (> failures 0) (exit 1) (begin (printf "PASS\n") (exit 0)))
