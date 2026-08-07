;;; Tests for the syntax-rules expander.
;;;
;;; Two oracles, because shape and meaning fail differently.
;;;
;;; MEANING. Almost everything here is checked by EVALUATING the expander's
;;; output in Chez and comparing the value. That is what makes the hygiene cases
;;; worth anything: `(let ((t 7)) (my-or #f t))` is 7 under a hygienic expander
;;; and #f under a broken one, and no amount of staring at renamed symbols says
;;; that as clearly as the number 7 does. The output is deliberately a subset of
;;; Scheme, so `eval` is available as an oracle for free.
;;;
;;; SHAPE. The acceptance criterion is the benchmark sources, so the second half
;;; runs the expander over bench/nbody and checks two things: that no macro and
;;; no derived form survives in the output, and that the expanded program still
;;; computes the same energy as the original, bit for bit, through Chez's own
;;; expander as the reference.
;;;
;;; The hygiene torture section is the point of the file. Both capture
;;; directions, both classic fixtures (`or` and `swap!`), keywords rebound out
;;; from under a template, literals compared by denotation, and nested ellipsis.
;;;
;;; Run: scheme -q --libdirs src:vendor/nanopass --script test/expand-test.ss
;;;      (from sonic/)

(import (rnrs base)
        (rnrs lists)
        (rnrs control)
        (rnrs io simple)
        (rnrs exceptions)
        (rnrs files)
        (rnrs eval)
        (sonic expand)
        (sonic read))

(define failures 0)
(define checks 0)

(define (check! name ok)
  (set! checks (+ checks 1))
  (unless ok
    (set! failures (+ failures 1))
    (display "FAIL: ") (display name) (newline)))

(define (check-equal! name got want)
  (set! checks (+ checks 1))
  (unless (equal? got want)
    (set! failures (+ failures 1))
    (display "FAIL: ") (display name)
    (display "\n  got:  ") (write got)
    (display "\n  want: ") (write want) (newline)))

;; --- the evaluating oracle --------------------------------------------------

(define host (environment '(chezscheme)))

;; Expand a whole program and run it as one body. The expander's output is a
;; subset of Scheme, so this needs no interpreter of our own.
(define (run-program forms)
  (eval (cons 'let (cons '() (expand-program forms))) host))

(define (run-expression form)
  (eval (expand-expression form) host))

;; `name` is checked by value, which is the only thing hygiene is visible in.
(define (v= name forms want)
  (check-equal! name (run-program forms) want))

(define (e= name form want)
  (check-equal! name (run-expression form) want))

;; --- must-fail --------------------------------------------------------------

(define (must-fail name forms)
  (set! checks (+ checks 1))
  (let ((result (guard (e (#t 'raised))
                  (list 'accepted (expand-program forms)))))
    (unless (eq? result 'raised)
      (set! failures (+ failures 1))
      (display "FAIL: ") (display name)
      (display " -- accepted, expanded to ") (write (cadr result)) (newline))))

;; ===========================================================================
;; 1. derived forms
;; ===========================================================================

(e= "quote" '(quote (a b)) '(a b))
(e= "self-evaluating number" '42 42)
(e= "self-evaluating string" '"hi" "hi")
(e= "two-armed if" '(if #t 1 2) 1)
(e= "one-armed if, taken" '(if #t 1) 1)
(e= "lambda and application" '((lambda (x y) (+ x y)) 1 2) 3)

(e= "let" '(let ((x 1) (y 2)) (+ x y)) 3)
(e= "let does not see its own bindings"
    '(let ((x 1)) (let ((x 2) (y x)) (list x y)))
    '(2 1))
(e= "let*" '(let* ((x 1) (y (+ x 1))) (list x y)) '(1 2))
(e= "letrec" '(letrec ((even2? (lambda (n) (if (= n 0) #t (odd2? (- n 1)))))
                       (odd2? (lambda (n) (if (= n 0) #f (even2? (- n 1))))))
                (even2? 10))
    #t)
(e= "named let" '(let loop ((i 0) (acc '())) (if (= i 3) acc (loop (+ i 1) (cons i acc))))
    '(2 1 0))
(e= "named let inits are evaluated outside the loop's own scope"
    '(let ((i 5)) (let loop ((i i)) i))
    5)
(e= "the loop name does not leak past the named let"
    '(let ((f 'outer)) (let f ((i 0)) i) f)
    'outer)

(e= "begin" '(begin 1 2 3) 3)
(e= "when, taken" '(when #t 1 2) 2)
(e= "unless, not taken" '(unless #t 1 2) '())
(e= "unless, taken" '(unless #f 1 2) 2)

(e= "and, empty" '(and) #t)
(e= "and, all true" '(and 1 2 3) 3)
(e= "and, short circuit" '(and 1 #f (car '())) #f)
(e= "or, empty" '(or) #f)
(e= "or, first true" '(or 7 (car '())) 7)
(e= "or, falls through" '(or #f #f 9) 9)

;; --- and/or in TEST position -----------------------------------------------
;;
;; The meaning tests above pin `and` and `or` in VALUE position, where the
;; result is the operand's own value and a temporary is the right lowering.
;; In TEST position only truth matters, and there the lowering has to be nested
;; `if`s, because the analysis five stages downstream reads the test.
;;
;; Lanf's `if` takes a single atom. A test that is anything but a comparison
;; becomes a let-bound boolean, and (sonic essa) attaches a sigma only where the
;; tested variable came from a comparison primcall. Lower `(and A B)` as
;; `(if A B #f)` inside a test and there is nothing for a fact to attach to: the
;; branch gets no sigma, and the interval domain is blind at every bounds-
;; guarded loop -- config-2c's shape, and every guard in the benchmark set.
;;
;; So these check the SHAPE, not the value. A value oracle cannot see the
;; difference; the analysis can see nothing else.

;; Every `if` test in a tree, in document order.
(define (if-tests d)
  (reverse
   (let walk ((d d) (acc '()))
     (if (not (pair? d))
         acc
         (let ((acc (if (and (eq? (car d) 'if) (= (length d) 4))
                        (cons (cadr d) acc)
                        acc)))
           (if (and (pair? d) (eq? (car d) 'quote))
               acc
               (let loop ((l d) (acc acc))
                 (if (pair? l) (loop (cdr l) (walk (car l) acc)) acc))))))))

;; What e-SSA can hang a fact on: an application of a comparison primitive to
;; atoms. Anything else -- an `if`, a `let`, a bare boolean variable -- is a
;; test the analysis cannot read.
(define (readable-test? t)
  (and (pair? t)
       (memq (car t) '(fx< fx<= fx= fx>= fx> fl< fl<= fl= fl>= fl>))
       (for-all (lambda (a) (or (symbol? a)
                                (and (pair? a) (eq? (car a) 'quote))))
                (cdr t))
       #t))

(check! "a conjunctive test becomes nested ifs, each reading a comparison"
        (let ((tests (if-tests (expand-expression
                                '(if (and (fx<= 0 i) (fx< i n)) (f i) 0)))))
          (and (= (length tests) 2) (for-all readable-test? tests))))

(check! "a disjunctive test becomes nested ifs too"
        (let ((tests (if-tests (expand-expression
                                '(if (or (fx< i 0) (fx>= i n)) 0 (f i))))))
          (and (= (length tests) 2) (for-all readable-test? tests))))

(check! "three conjuncts give three readable tests"
        (let ((tests (if-tests (expand-expression
                                '(if (and (fx<= 0 i) (fx< i n) (fx< j n)) (f i) 0)))))
          (and (= (length tests) 3) (for-all readable-test? tests))))

;; THE CASE THE BEAD IS ABOUT. A guarded loop, written the way the benchmark
;; sources write one. Every conditional in the output must read a comparison
;; directly, and the loop body must sit INSIDE both guards, because that nesting
;; is what makes the two facts compose into [0,n).
(define guarded-loop
  (expand-expression
   '(let loop ((i 0))
      (if (and (fx<= 0 i) (fx< i n))
          (begin (g (flvector-ref a i)) (loop (fx+ i 1)))
          '()))))

(check! "guarded loop: every test is a comparison the analysis can read"
        (let ((tests (if-tests guarded-loop)))
          (and (= (length tests) 2) (for-all readable-test? tests))))

(check! "guarded loop: no test is itself a conditional"
        (for-all (lambda (t) (not (and (pair? t) (memq (car t) '(if let)))))
                 (if-tests guarded-loop)))

(check! "guarded loop: the body is nested inside BOTH guards, not behind a call"
        (let find ((d guarded-loop) (depth 0))
          (cond ((not (pair? d)) #f)
                ((eq? (car d) 'quote) #f)
                ((and (eq? (car d) 'flvector-ref) (= depth 2)) #t)
                ((and (eq? (car d) 'if) (= (length d) 4))
                 (or (find (caddr d) (+ depth 1)) (find (cadddr d) depth)))
                (else (exists (lambda (s) (find s depth)) d)))))

;; The duplicated arm is named once rather than copied, so a nested test cannot
;; multiply code size. The arm reached exactly once is never named: putting the
;; loop body behind a call would take it out of the scope of the refinements.
(check-equal! "a non-trivial duplicated arm is bound once and called"
              (let ((out (expand-expression
                          '(if (and (fx<= 0 i) (fx< i n) (fx< j n)) (f i) (h j)))))
                (list (car out) (length (cadr out))))
              '(let 1))

;; Value position is untouched: `and` still yields its last operand's value and
;; `or` still yields the first true one, which the meaning tests above cover.
;; This pins that the two positions really are lowered differently.
(check! "in value position `and` is NOT distributed into ifs"
        (let ((out (expand-expression '(let ((c (and (fx< i n) (fx< j n)))) c))))
          (equal? (if-tests out) '((fx< i n)))))

(e= "cond, first clause" '(cond (#t 1) (else 2)) 1)
(e= "cond, else" '(cond (#f 1) (else 2 3)) 3)
(e= "cond, no clause matches" '(cond (#f 1)) '())
(e= "cond, test-only clause yields the test"
    '(cond (#f 1) (42) (else 'no)) 42)
(e= "cond, => receives the test value"
    '(cond ((assv 2 '((1 a) (2 b))) => cadr) (else 'no)) 'b)
(e= "cond, => is not evaluated when the test fails"
    '(cond (#f => (car '())) (else 'fine)) 'fine)

(e= "internal defines become letrec"
    '(let ()
       (define (even2? n) (if (= n 0) #t (odd2? (- n 1))))
       (define (odd2? n) (if (= n 0) #f (even2? (- n 1))))
       (even2? 8))
    #t)
(e= "internal define after a begin splice"
    '(let () (begin (define a 1) (define b 2)) (+ a b)) 3)
(e= "set!" '(let ((x 1)) (set! x 2) x) 2)

(v= "top-level define, procedure shorthand"
    '((define (f x) (* x 2)) (f 21)) 42)
(v= "top-level define is recursive"
    '((define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 5)) 120)
(v= "top-level define, forward reference"
    '((define (a) (b)) (define (b) 'ok) (a)) 'ok)
(v= "top-level begin splices"
    '((begin (define x 1) (define y 2)) (+ x y)) 3)

;; The shapes stage 03 has to see, checked structurally rather than by value.
(check-equal! "one-armed if gets an explicit else arm"
              (expand-expression '(if a b))
              '(if a b (quote ())))
(check-equal! "let* nests"
              (expand-expression '(let* ((a 1) (b 2)) b))
              '(let ((a%1 (quote 1))) (let ((b%2 (quote 2))) b%2)))
(check-equal! "named let becomes letrec of a lambda"
              (expand-expression '(let go ((i 0)) i))
              '(letrec ((go%1 (lambda (i%2) i%2))) (go%1 (quote 0))))
(check-equal! "literals are quoted, so Lcore never sees a bare datum"
              (expand-expression '(f 1 "s" #\c #t))
              '(f (quote 1) (quote "s") (quote #\c) (quote #t)))
(check-equal! "declare survives, with its variable renamed and its check name bare"
              (expand-expression '(lambda (v) (declare ((v fixnum?)) v)))
              '(lambda (v%1) (declare ((v%1 fixnum?)) v%1)))
(check-equal! "policy survives"
              (expand-expression '(policy ((bounds-check #f)) 1))
              '(policy ((bounds-check #f)) (quote 1)))

;; ===========================================================================
;; 2. syntax-rules: matching
;; ===========================================================================

(v= "a macro with no arguments"
    '((define-syntax zero (syntax-rules () ((_) 0))) (zero)) 0)
(v= "pattern variables"
    '((define-syntax swap-args (syntax-rules () ((_ a b) (list b a))))
      (swap-args 1 2))
    '(2 1))
(v= "several clauses, first match wins"
    '((define-syntax arity
        (syntax-rules ()
          ((_) 'none)
          ((_ a) 'one)
          ((_ a b) 'two)))
      (list (arity) (arity 1) (arity 1 2)))
    '(none one two))
(v= "underscore matches and binds nothing"
    '((define-syntax second (syntax-rules () ((_ _ b) b))) (second 1 2)) 2)
(v= "a constant in a pattern must match itself"
    '((define-syntax pick
        (syntax-rules ()
          ((_ 0 x y) x)
          ((_ 1 x y) y)))
      (list (pick 0 'a 'b) (pick 1 'a 'b)))
    '(a b))
(v= "improper pattern binds the tail"
    '((define-syntax tailed (syntax-rules () ((_ a . rest) (list 'a 'rest))))
      (tailed 1 2 3))
    '(1 (2 3)))
(v= "nested pattern structure"
    '((define-syntax deep (syntax-rules () ((_ (a (b c))) (list a b c))))
      (deep (1 (2 3))))
    '(1 2 3))
(v= "vector pattern and vector template"
    '((define-syntax vpair (syntax-rules () ((_ #(a b)) (vector b a))))
      (vpair #(1 2)))
    (vector 2 1))

(v= "ellipsis"
    '((define-syntax lst (syntax-rules () ((_ x ...) (list x ...))))
      (lst 1 2 3))
    '(1 2 3))
(v= "ellipsis matching nothing"
    '((define-syntax lst (syntax-rules () ((_ x ...) (list x ...)))) (lst))
    '())
(v= "ellipsis followed by a fixed tail"
    '((define-syntax butlast (syntax-rules () ((_ x ... y) (list 'front (list x ...) 'last y))))
      (butlast 1 2 3))
    '(front (1 2) last 3))
(v= "ellipsis over structured subpatterns"
    '((define-syntax pairs (syntax-rules () ((_ (a b) ...) (list (list 'a 'b) ...))))
      (pairs (1 2) (3 4)))
    '((1 2) (3 4)))
(v= "nested ellipsis, depth two"
    '((define-syntax nest (syntax-rules () ((_ (x y ...) ...) (list (list 'x 'y ...) ...))))
      (nest (a 1 2) (b 3) (c)))
    '((a 1 2) (b 3) (c)))
(v= "nested ellipsis with an outer-depth variable replicated inward"
    '((define-syntax tag (syntax-rules () ((_ (t x ...) ...) (list (list 't x) ... ...))))
      (tag (a 1 2) (b 3)))
    '((a 1) (a 2) (b 3)))
(v= "two ellipses flatten one level"
    '((define-syntax flat (syntax-rules () ((_ (x ...) ...) (list x ... ...))))
      (flat (1 2) (3) (4 5 6)))
    '(1 2 3 4 5 6))

(v= "literals match by denotation"
    '((define-syntax lit
        (syntax-rules (foo)
          ((_ foo) 'matched-literal)
          ((_ x) 'matched-variable)))
      (list (lit foo) (lit bar)))
    '(matched-literal matched-variable))
(v= "a bound identifier no longer matches the same-named literal"
    '((define-syntax lit
        (syntax-rules (foo)
          ((_ foo) 'matched-literal)
          ((_ x) 'matched-variable)))
      (let ((foo 1)) (lit foo)))
    'matched-variable)

(v= "custom ellipsis identifier"
    '((define-syntax ce (syntax-rules ::: () ((_ x :::) (list x :::))))
      (ce 1 2 3))
    '(1 2 3))
(v= "(... ...) escapes an ellipsis, so a macro can write a macro"
    '((define-syntax define-lister
        (syntax-rules ()
          ((_ name)
           (define-syntax name
             (syntax-rules () ((_ x (... ...)) (list x (... ...))))))))
      (define-lister my-list)
      (my-list 1 2 3))
    '(1 2 3))

(v= "a macro may expand into a definition"
    '((define-syntax def-two
        (syntax-rules ()
          ((_ a b) (begin (define a 1) (define b 2)))))
      (def-two p q)
      (+ p q))
    3)
(v= "a macro may expand into a definition inside a body"
    '((define-syntax def-one (syntax-rules () ((_ a v) (define a v))))
      (define (f) (def-one z 9) z)
      (f))
    9)
(v= "recursive macro"
    '((define-syntax my-and
        (syntax-rules ()
          ((_) #t)
          ((_ e) e)
          ((_ e1 e2 ...) (if e1 (my-and e2 ...) #f))))
      (list (my-and) (my-and 1 2 3) (my-and 1 #f 3)))
    (list #t 3 #f))

(v= "let-syntax scopes a keyword"
    '((let-syntax ((twice (syntax-rules () ((_ e) (+ e e))))) (twice 21)))
    42)
(v= "letrec-syntax lets a transformer see itself"
    '((letrec-syntax ((count (syntax-rules ()
                               ((_) 0)
                               ((_ x y ...) (+ 1 (count y ...))))))
        (count a b c)))
    3)

;; ===========================================================================
;; 3. HYGIENE TORTURE
;; ===========================================================================
;; Two directions, and they fail for different reasons, so they are tested
;; separately. A macro-introduced binding must not capture a user variable; a
;; user binding must not capture a macro-introduced reference.

;; --- direction one: the template's binder must not capture the user's ------

;; The `or` case. `t` is introduced by the template and passed in by the user.
;; A capturing expander returns #f here; a hygienic one returns 7.
(v= "TORTURE: (or a b) does not capture the user's t"
    '((define-syntax my-or
        (syntax-rules ()
          ((_) #f)
          ((_ e) e)
          ((_ e1 e2 ...) (let ((t e1)) (if t t (my-or e2 ...))))))
      (let ((t 7)) (my-or #f t)))
    7)

(v= "TORTURE: the same capture through two levels of recursive expansion"
    '((define-syntax my-or
        (syntax-rules ()
          ((_) #f)
          ((_ e) e)
          ((_ e1 e2 ...) (let ((t e1)) (if t t (my-or e2 ...))))))
      (let ((t 7)) (my-or #f #f t)))
    7)

;; The `swap!` case, which is the assignment version of the same bug: a
;; capturing expander swaps the temporary with itself and returns (1 2).
(v= "TORTURE: swap! does not capture the user's tmp"
    '((define-syntax swap!
        (syntax-rules ()
          ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp)))))
      (let ((tmp 1) (other 2))
        (swap! tmp other)
        (list tmp other)))
    '(2 1))

(v= "TORTURE: swap! with the user's variable named tmp on the other side"
    '((define-syntax swap!
        (syntax-rules ()
          ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp)))))
      (let ((other 1) (tmp 2))
        (swap! other tmp)
        (list other tmp)))
    '(2 1))

(v= "TORTURE: a macro-introduced lambda parameter does not capture"
    '((define-syntax apply-to-1
        (syntax-rules () ((_ e) ((lambda (x) e) 1))))
      (let ((x 99)) (apply-to-1 x)))
    99)

(v= "TORTURE: two firings of one macro introduce two distinct bindings"
    '((define-syntax bind-t (syntax-rules () ((_ v e) (let ((t v)) e))))
      (bind-t 1 (bind-t 2 'inner)))
    'inner)

;; --- direction two: the user's binder must not capture the template's ------

(v= "TORTURE: a template's free reference is not captured by a user binding"
    '((define-syntax wrap (syntax-rules () ((_ e) (list e))))
      (let ((list (lambda (a) 'hijacked))) (wrap 1)))
    '(1))

(v= "TORTURE: a template's keyword survives the user rebinding it"
    '((define-syntax pick (syntax-rules () ((_ c a b) (if c a b))))
      (let ((if (lambda (a b c) 'hijacked))) (pick #t 'yes 'no)))
    'yes)

(v= "TORTURE: a template's `let` survives the user rebinding let"
    '((define-syntax bind (syntax-rules () ((_ v e) (let ((q v)) (+ q e)))))
      (let ((let 5)) (bind 1 2)))
    3)

(v= "TORTURE: a macro sees the binding in force where it was DEFINED"
    '((define base 'outer)
      (define-syntax get-base (syntax-rules () ((_) base)))
      (let ((base 'inner)) (get-base)))
    'outer)

(v= "TORTURE: a macro used inside a body that redefines its free name"
    '((define (helper x) (* x 10))
      (define-syntax use-helper (syntax-rules () ((_ e) (helper e))))
      (let ((helper (lambda (x) 'wrong))) (use-helper 4)))
    40)

;; --- hygiene under ellipsis -------------------------------------------------

(v= "TORTURE: nested ellipsis with an introduced binder at each level"
    '((define-syntax my-let*
        (syntax-rules ()
          ((_ () body) body)
          ((_ ((n v) rest ...) body) (let ((n v)) (my-let* (rest ...) body)))))
      (let ((n 100))
        (my-let* ((a 1) (b 2)) (list a b n))))
    '(1 2 100))

(v= "TORTURE: an ellipsis template that binds all its inputs at once"
    '((define-syntax my-let
        (syntax-rules ()
          ((_ ((n v) ...) body ...) ((lambda (n ...) body ...) v ...))))
      (let ((x 5))
        (my-let ((x 1) (y x)) (list x y))))
    '(1 5))

(v= "TORTURE: nested ellipsis, macro-introduced temporaries do not collide"
    '((define-syntax sums
        (syntax-rules ()
          ((_ (x y ...) ...) (list (let ((acc x)) (+ acc y ...)) ...))))
      (let ((acc 1000))
        (list acc (sums (1 2 3) (10 20)))))
    '(1000 (6 30)))

;; --- quoting ----------------------------------------------------------------
;; A renamed identifier must never escape into a quoted datum.

(v= "a quoted template symbol comes out unrenamed"
    '((define-syntax q (syntax-rules () ((_) 'hello))) (q))
    'hello)
(v= "a quoted template list comes out unrenamed"
    '((define-syntax q (syntax-rules () ((_) '(a (b c))))) (q))
    '(a (b c)))
(v= "a quoted pattern variable comes out unrenamed"
    '((define-syntax q (syntax-rules () ((_ x) '(tag x)))) (let ((y 1)) (q y)))
    '(tag y))

(check! "no expander-generated name survives inside a quote"
        (let ((out (expand-program
                    '((define-syntax q (syntax-rules () ((_) '(a b c))))
                      (let ((a 1)) (q))))))
          (let scan ((d out))
            (cond ((and (pair? d) (eq? (car d) 'quote))
                   (let inner ((q (cadr d)))
                     (cond ((symbol? q) (memq q '(a b c)))
                           ((pair? q) (and (inner (car q)) (inner (cdr q))))
                           (else #t))))
                  ((pair? d) (and (scan (car d)) (scan (cdr d))))
                  (else #t)))))

;; ===========================================================================
;; 4. negative cases
;; ===========================================================================
;; An expander that accepts everything is not an expander.

;; ellipsis depth, caught at define-syntax time rather than at the first use
(must-fail "pattern variable bound under an ellipsis, used without one"
           '((define-syntax bad (syntax-rules () ((_ x ...) (list x))))))
(must-fail "depth two in the pattern, depth one in the template"
           '((define-syntax bad (syntax-rules () ((_ (x ...) ...) (list x ...))))))
(must-fail "ellipsis template with no pattern variable to iterate over"
           '((define-syntax bad (syntax-rules () ((_ x) (list y ...))))))
(must-fail "unbound pattern variable driving an ellipsis, nested"
           '((define-syntax bad (syntax-rules () ((_ x ...) (list (list y ...) ...))))))
(must-fail "pattern variable repeated in one pattern"
           '((define-syntax bad (syntax-rules () ((_ x x) x)))))

;; ellipsis length, which is only knowable at the use
(must-fail "ellipsis length mismatch between two pattern variables"
           '((define-syntax zip
               (syntax-rules () ((_ (a ...) (b ...)) (list (list a b) ...))))
             (zip (1 2 3) (4 5))))

(must-fail "no clause matches the use"
           '((define-syntax two (syntax-rules () ((_ a b) (list a b))))
             (two 1)))
(must-fail "a syntax-rules clause needs a template"
           '((define-syntax bad (syntax-rules () ((_ a))))))
(must-fail "a syntax-rules pattern must be a list"
           '((define-syntax bad (syntax-rules () (x 1)))))
(must-fail "only syntax-rules transformers are supported"
           '((define-syntax bad (lambda (x) x))))
(must-fail "a macro name is not a variable"
           '((define-syntax m (syntax-rules () ((_) 1))) m))

;; the Lcore shape rules
(must-fail "lambda with a rest parameter"
           '((lambda (a . rest) a)))
(must-fail "lambda with a symbol formal"
           '((lambda args args)))
(must-fail "duplicate lambda parameter"
           '((lambda (x x) x)))
(must-fail "duplicate let binding is a duplicate parameter after renaming"
           '((let ((x 1)) (lambda (y y) y))))

;; malformed core forms
(must-fail "if with one argument" '((if 1)))
(must-fail "if with four arguments" '((if 1 2 3 4)))
(must-fail "quote with two arguments" '((quote a b)))
(must-fail "set! on a keyword" '((set! if 1)))
(must-fail "set! on a non-identifier" '((set! (f x) 1)))
(must-fail "let with a non-identifier binding" '((let ((1 2)) 3)))
(must-fail "let with a malformed binding" '((let ((x)) x)))
(must-fail "body with definitions but no expression" '((let () (define x 1))))
(must-fail "empty application" '((f ())))
(must-fail "improper application" '((f 1 . 2)))
(must-fail "else is not the last cond clause" '((cond (else 1) (#t 2))))
(must-fail "definition in an expression position" '((if #t (define x 1) 2)))
(must-fail "syntax-rules outside a transformer" '((syntax-rules () ((_) 1))))
(must-fail "declare with a malformed premise" '((lambda (v) (declare ((v)) v))))
(must-fail "policy with a non-boolean setting" '((policy ((bounds-check maybe)) 1)))

;; ===========================================================================
;; 5. the acceptance criterion: bench/nbody
;; ===========================================================================

(define (find-bench-dir)
  (let loop ((cands '("../bench/nbody/" "bench/nbody/" "./bench/nbody/")))
    (cond ((null? cands) #f)
          ((file-exists? (string-append (car cands) "config1.scm")) (car cands))
          (else (loop (cdr cands))))))

(define bench-dir (find-bench-dir))

;; Nothing derived may survive. `quote` hides its contents from this scan,
;; since a quoted datum may legitimately spell any of these.
(define banned
  '(define-syntax syntax-rules let-syntax letrec-syntax
    let* when unless cond else => and or letrec*))

(define (survivors form)
  (let scan ((d form) (acc '()))
    (cond ((and (pair? d) (eq? (car d) 'quote)) acc)
          ((pair? d) (scan (cdr d) (scan (car d) acc)))
          ((and (symbol? d) (memq d banned) (not (memq d acc))) (cons d acc))
          (else acc))))

;; A named let survives as a letrec of a lambda, so the giveaway is a `let`
;; whose second element is a symbol rather than a binding list.
(define (named-lets form)
  (let scan ((d form) (n 0))
    (cond ((and (pair? d) (eq? (car d) 'quote)) n)
          ((and (pair? d) (eq? (car d) 'let) (pair? (cdr d)) (symbol? (cadr d)))
           (+ n 1))
          ((pair? d) (scan (cdr d) (scan (car d) n)))
          (else n))))

;; Keep the definitions, drop the `import` header and the driver at the bottom.
;; The driver is `(main)` in three of these files and a bare `let*` that runs a
;; thousand steps and prints in the other two; either way it is everything after
;; the last definition. What is left is a library of procedures the probe below
;; can call.
;;
;; The original goes through Chez's expander and ours goes through this file's,
;; so agreement on the energy is a differential test of the whole expander
;; against a production one over 160 lines of real program.
(define (definition? f)
  (and (pair? f) (memq (car f) '(define define-syntax))))

;; Trailing run only: `(define-slot bx bx! 0)` sits in the middle of two of
;; these files and is a macro use rather than a definition, so anything that
;; scans forward and stops at the first non-definition loses half the program.
(define (body-of forms)
  (let loop ((fs (reverse (filter (lambda (f)
                                    (not (and (pair? f) (eq? (car f) 'import))))
                                  forms))))
    (cond ((null? fs) '())
          ((definition? (car fs)) (reverse fs))
          (else (loop (cdr fs))))))

(define probe '((init!) (offset-momentum!) (advance!) (advance!) (advance!) (energy)))

(define (energy-of forms)
  (eval (cons 'let (cons '() (append forms probe))) host))

(define (check-source! name)
  (let* ((path (string-append bench-dir name))
         (source (read-all-from-file path))
         (body (body-of source))
         (expanded (expand-program body)))
    (check-equal! (string-append name ": no derived form survives")
                  (survivors expanded) '())
    (check-equal! (string-append name ": no named let survives")
                  (named-lets expanded) 0)
    (check-equal! (string-append name ": energy after three steps matches Chez's own expander")
                  (number->string (energy-of expanded))
                  (number->string (energy-of body)))
    (display "  ") (display name)
    (display ": ") (display (length expanded)) (display " top-level forms, energy ")
    (display (energy-of expanded)) (newline)))

(newline)
(if (not bench-dir)
    (begin
      (display "FAIL: cannot find bench/nbody; run this from sonic/") (newline)
      (set! failures (+ failures 1)))
    (begin
      (display "expanding bench/nbody, differential against Chez's expander:") (newline)
      (for-each check-source!
                '("config1.scm"
                  "config2a.sps"
                  "config2b.sps"
                  "config2c-chez.ss"
                  "config4-chez.ss"))
      ;; Stalin's dialect will not run under Chez, so this one is shape only.
      (let ((expanded (expand-program
                       (read-all-from-file (string-append bench-dir "config7-stalin.sc")))))
        (check-equal! "config7-stalin.sc: no derived form survives"
                      (survivors expanded) '())
        (check-equal! "config7-stalin.sc: no named let survives"
                      (named-lets expanded) 0))))

;; Spot check with the expectation written out: config2a's `define-slot` is the
;; one real macro in the benchmark set, and it has to produce two definitions
;; per use, with the pattern variables landing in the global namespace unrenamed
;; because that is where the rest of the program looks for them.
(when bench-dir
  (let* ((source (read-all-from-file (string-append bench-dir "config2a.sps")))
         (expanded (expand-program (body-of source)))
         (names (map cadr (filter (lambda (f) (and (pair? f) (eq? (car f) 'define)))
                                  expanded))))
    (check! "config2a: define-slot's accessor names reach the top level unrenamed"
            (for-all (lambda (n) (memq n names))
                     '(bx bx! by by! bz bz! bvx bvx! bvy bvy! bvz bvz!)))
    (check-equal! "config2a: the first slot accessor has the expected shape"
                  (let ((d (assq 'bx (map cdr (filter (lambda (f)
                                                        (and (pair? f) (eq? (car f) 'define)))
                                                      expanded)))))
                    (list (car (cadr d)) (length (cadr (cadr d)))))
                  '(lambda 1))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
