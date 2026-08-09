;;; Procedure inlining, Lanf -> Lanf.
;;;
;;; Three of these cases assert that something did NOT happen, and those are the
;;; ones with teeth. An inliner that fires on everything duplicates effects,
;;; unrolls loops it was not asked to unroll, and grows code without bound; the
;;; grammar catches none of that, so it has to be tested.
;;;
;;; NOTE ON WHAT SUCCESS MEANS. nbody is the one benchmark where Chez's cp0
;;; inliner does not help, 0.92 to 1.05 on the R4400 per Waddell and Dybvig. A
;;; measured wall-clock effect of nothing on nbody is the expected result for
;;; this pass. What these tests check is that the TRANSFORMATION is correct and
;;; bounded, which is a separate question from whether it pays, and the only one
;;; a unit test can answer.

(import (chezscheme) (nanopass) (sonic lang) (sonic inline))

;; THE BUDGET IS SET HERE, because this file tests the MECHANISM and the shipped
;; default is a policy. That default is now 0 -- the pass is disabled by
;; measurement on nbody, where it changes no code and costs the interval analysis
;; eighteen discharged facts -- and every fixture below was written against 12,
;; which is the number to re-enable it at. See the note on `inline-size-budget`.
(inline-size-budget 12)

(define failures 0)
(define checks 0)

(define (ok! name v)
  (set! checks (+ checks 1))
  (if v
      (printf "  ok   ~a\n" name)
      (begin (set! failures (+ failures 1))
             (printf "  FAIL ~a\n" name))))

(define (ok/show name v out)
  (set! checks (+ checks 1))
  (if v
      (printf "  ok   ~a\n" name)
      (begin (set! failures (+ failures 1))
             (printf "  FAIL ~a\n" name)
             (pretty-print (unparse-Lanf out)))))

;; --- structural queries over an Lanf term ---------------------------------
;; Written here rather than in the pass, because a checker that shares code with
;; the thing it checks is not a check.

;; LAMBDA BODIES ARE SKIPPED, deliberately. The pass leaves the now-dead
;; `(let ([f (lambda ...)]) ...)` binding in place, because deleting it is dead
;; code elimination and that is a different pass. So a count over the whole term
;; would report the definition's copy of the work alongside every inlined copy,
;; and the interesting number is the one in the code that still runs.
(define (fold-live e leaf)
  (let loop ([e e] [acc '()])
    (define (se se acc)
      (nanopass-case (Lanf SimpleExpr) se
        [(lambda (,x* ...) ,body) acc]
        [else (cons (leaf 'se se) acc)]))
    (let ([acc (cons (leaf 'e e) acc)])
      (nanopass-case (Lanf Expr) e
        [(if ,x ,e0 ,e1) (loop e1 (loop e0 acc))]
        [(seq ,e0 ,e1) (loop e1 (loop e0 acc))]
        [(let ([,x ,se0]) ,body) (loop body (se se0 acc))]
        [(lambda (,x* ...) ,body) acc]
        [(letrec ([,x* ,e*] ...) ,body) (loop body acc)]
        [(declare ([,x* ,prem*] ...) ,body) (loop body acc)]
        [(policy ([,pn* ,b*] ...) ,body) (loop body acc)]
        [else acc]))))

(define (count-nodes e pred)
  (length (filter values (fold-live e pred))))

;; How many primcalls of a given primitive survive in live code.
(define (count-primcall e want)
  (count-nodes e
    (lambda (kind n)
      (and (eq? kind 'se)
           (nanopass-case (Lanf SimpleExpr) n
             [(primcall ,pr ([,pn* ,c*] ...) ,x* ...) (eq? pr want)]
             [else #f])))))

;; How many `call`/`tailcall` sites name a given operator.
(define (count-calls e want)
  (+ (count-nodes e
       (lambda (kind n)
         (and (eq? kind 'se)
              (nanopass-case (Lanf SimpleExpr) n
                [(call ,x ,x* ...) (eq? x want)]
                [else #f]))))
     (count-nodes e
       (lambda (kind n)
         (and (eq? kind 'e)
              (nanopass-case (Lanf Expr) n
                [(tailcall ,x ,x* ...) (eq? x want)]
                [else #f]))))))

;; Every binder in the term, with duplicates kept.
(define (binders e)
  (let loop ([e e] [acc '()])
    (define (se se acc)
      (nanopass-case (Lanf SimpleExpr) se
        [(lambda (,x* ...) ,body) (loop body (append x* acc))]
        [else acc]))
    (nanopass-case (Lanf Expr) e
      [(if ,x ,e0 ,e1) (loop e1 (loop e0 acc))]
      [(seq ,e0 ,e1) (loop e1 (loop e0 acc))]
      [(let ([,x ,se0]) ,body) (loop body (se se0 (cons x acc)))]
      [(lambda (,x* ...) ,body) (loop body (append x* acc))]
      [(letrec ([,x* ,e*] ...) ,body)
       (loop body (fold-left (lambda (a r) (loop r a)) (append x* acc) e*))]
      [(declare ([,x* ,prem*] ...) ,body) (loop body acc)]
      [(policy ([,pn* ,b*] ...) ,body) (loop body acc)]
      [else acc])))

(define (no-duplicates? l)
  (let loop ([l l])
    (cond [(null? l) #t]
          [(memq (car l) (cdr l)) #f]
          [else (loop (cdr l))])))

;; Free variables, as a set. The scope test: inlining must not introduce a
;; reference to anything the original program did not already have free.
(define (free-vars e)
  (define (rm x* s) (filter (lambda (v) (not (memq v x*))) s))
  (define (u a b) (fold-left (lambda (s v) (if (memq v s) s (cons v s))) a b))
  (let fv ([e e])
    (define (fv-se se)
      (nanopass-case (Lanf SimpleExpr) se
        [,x (list x)]
        [(quote ,d) '()]
        [(lambda (,x* ...) ,body) (rm x* (fv body))]
        [(call ,x ,x* ...) (u (list x) x*)]
        [(primcall ,pr ([,pn* ,c*] ...) ,x* ...) (u '() x*)]
        [else '()]))
    (nanopass-case (Lanf Expr) e
      [,x (list x)]
      [(quote ,d) '()]
      [(if ,x ,e0 ,e1) (u (u (list x) (fv e0)) (fv e1))]
      [(seq ,e0 ,e1) (u (fv e0) (fv e1))]
      [(let ([,x ,se]) ,body) (u (fv-se se) (rm (list x) (fv body)))]
      [(tailcall ,x ,x* ...) (u (list x) x*)]
      [(lambda (,x* ...) ,body) (rm x* (fv body))]
      [(letrec ([,x* ,e*] ...) ,body)
       (rm x* (fold-left (lambda (s r) (u s (fv r))) (fv body) e*))]
      [(declare ([,x* ,prem*] ...) ,body) (u x* (fv body))]
      [(policy ([,pn* ,b*] ...) ,body) (fv body)]
      [else '()])))

(define (subset? a b) (for-all (lambda (v) (memq v b)) a))

(printf "procedure inlining:\n")

;; --- 1. a leaf call is inlined ------------------------------------------
;; `scale` is bound once, to a lambda, and only ever called. Its body is four
;; nodes, well under the budget. The call site is non-tail and the body has one
;; tail position, so rule 5 is satisfied too.

(define leaf-prog
  (with-output-language (Lanf Expr)
    `(let ([scale (lambda (u v)
                    (let ([w (primcall fl* ([fp-contract unchecked]) u v)]) w))])
       (let ([r (call scale a b)])
         r))))

(define leaf-out (inline-program leaf-prog))

(ok/show "a leaf call is inlined"
         (= 0 (count-calls leaf-out 'scale))
         leaf-out)

(ok/show "the inlined body's work is still there exactly once"
         (= 1 (count-primcall leaf-out 'fl*))
         leaf-out)

(ok/show "the report names what was inlined"
         (let-values ([(out rep) (inline-program/report leaf-prog)])
           (equal? rep '(scale)))
         leaf-out)

;; --- 2. the ANF invariant survives ---------------------------------------
;; Grammar-level ANF is enforced by nanopass at expansion time, so what is left
;; to check is the part it cannot see: the inlined result is still NAMED at the
;; binding the call's result was named at, no binder is duplicated, and no free
;; variable appeared out of nowhere.

(ok/show "every intermediate stays named: r is still bound"
         (memq 'r (binders leaf-out))
         leaf-out)

(ok/show "binders in the output are unique"
         (no-duplicates? (binders leaf-out))
         leaf-out)

(ok/show "no free variable is introduced"
         (subset? (free-vars leaf-out) (free-vars leaf-prog))
         leaf-out)

;; The same three properties on a term where the inlined copy nests inside
;; another copy, which is where a renamer that forgets to freshen would collide.
(define twice-prog
  (with-output-language (Lanf Expr)
    `(let ([sq (lambda (u)
                 (let ([w (primcall fl* ([fp-contract unchecked]) u u)]) w))])
       (let ([p (call sq a)])
         (let ([q (call sq b)])
           (let ([s (primcall fl+ ([fp-contract unchecked]) p q)])
             s))))))

(define twice-out (inline-program twice-prog))

(ok/show "two copies of one body do not collide"
         (and (no-duplicates? (binders twice-out))
              (= 0 (count-calls twice-out 'sq))
              (= 2 (count-primcall twice-out 'fl*))
              (subset? (free-vars twice-out) (free-vars twice-prog)))
         twice-out)

;; --- 3. a recursive call terminates --------------------------------------
;; The pass must return, and it must leave the recursion alone. Rule 4 refuses
;; a procedure that can reach itself; rule 3 would bound it anyway.

(define rec-prog
  (with-output-language (Lanf Expr)
    `(letrec ([loop (lambda (i acc)
                      (let ([t (primcall fx< () i n)])
                        (if t
                            (let ([i1 (primcall fx+ ([overflow-check checked]) i one)])
                              (tailcall loop i1 acc))
                            acc)))])
       (tailcall loop zero start))))

(define rec-out (inline-program rec-prog))

(ok/show "a recursive call terminates and is left alone"
         (= 1 (count-calls rec-out 'loop))
         rec-out)

(ok/show "the recursive program is otherwise unchanged"
         (equal? (unparse-Lanf rec-out) (unparse-Lanf rec-prog))
         rec-out)

;; Mutual recursion, which a self-edge check alone would miss.
(define mutual-prog
  (with-output-language (Lanf Expr)
    `(letrec ([even (lambda (i) (tailcall odd i))]
              [odd (lambda (i) (tailcall even i))])
       (tailcall even n))))

(define mutual-out (inline-program mutual-prog))

(ok/show "mutual recursion terminates and is left alone"
         (equal? (unparse-Lanf mutual-out) (unparse-Lanf mutual-prog))
         mutual-out)

;; --- 4. a call with an effectful argument is not duplicated --------------
;; `use2` names its parameter twice. A beta-substituting inliner that copied the
;; ARGUMENT EXPRESSION rather than the argument variable would evaluate the
;; flvector-set! twice and write the array twice. Lanf hands us the atom, and
;; the pass must not undo that.

(define effect-prog
  (with-output-language (Lanf Expr)
    `(let ([use2 (lambda (u)
                   (let ([w (primcall fl+ ([fp-contract unchecked]) u u)]) w))])
       (let ([t (primcall flvector-set! ([type-check checked] [bounds-check checked]) v i x)])
         (let ([r (call use2 t)])
           r)))))

(define effect-out (inline-program effect-prog))

(ok/show "an effectful argument is evaluated exactly once"
         (= 1 (count-primcall effect-out 'flvector-set!))
         effect-out)

(ok/show "and the inline still happened"
         (= 0 (count-calls effect-out 'use2))
         effect-out)

;; --- 5. the budgets are real --------------------------------------------

(define big-prog
  (with-output-language (Lanf Expr)
    `(let ([big (lambda (u v)
                  (let ([a1 (primcall fl* ([fp-contract unchecked]) u v)])
                    (let ([a2 (primcall fl+ ([fp-contract unchecked]) a1 u)])
                      (let ([a3 (primcall fl- ([fp-contract unchecked]) a2 v)])
                        (let ([a4 (primcall fl* ([fp-contract unchecked]) a3 a3)])
                          (let ([a5 (primcall fl/ () a4 a1)])
                            a5))))))])
       (let ([r (call big a b)])
         r))))

(ok/show "a procedure over the size budget is refused"
         (= 1 (count-calls (inline-program big-prog) 'big))
         (inline-program big-prog))

(ok! "and the same procedure goes in when the budget is raised"
     (parameterize ([inline-size-budget 100])
       (= 0 (count-calls (inline-program big-prog) 'big))))

;; --- 6. refusals that keep the pass honest -------------------------------

;; A name that is not only called cannot be assumed to denote its lambda.
(define escaping-prog
  (with-output-language (Lanf Expr)
    `(let ([f (lambda (u) u)])
       (let ([t (call register f)])
         (let ([r (call f a)])
           (seq t r))))))

(ok/show "a procedure whose name escapes is not inlined"
         (= 1 (count-calls (inline-program escaping-prog) 'f))
         (inline-program escaping-prog))

;; Rule 5. Two tail positions means `k` would have to be copied into both.
(define branchy-prog
  (with-output-language (Lanf Expr)
    `(let ([pick (lambda (u v) (if u v u))])
       (let ([r (call pick a b)])
         r))))

(ok/show "a non-tail call to a two-tailed body is refused"
         (= 1 (count-calls (inline-program branchy-prog) 'pick))
         (inline-program branchy-prog))

;; ...but in tail position there is no continuation to copy, so the same
;; procedure goes straight in.
(define branchy-tail-prog
  (with-output-language (Lanf Expr)
    `(let ([pick (lambda (u v) (if u v u))])
       (tailcall pick a b))))

(ok/show "the same body inlines fine at a tail call"
         (= 0 (count-calls (inline-program branchy-tail-prog) 'pick))
         (inline-program branchy-tail-prog))

;; Arity has to match, or the call is not the call we think it is.
(define arity-prog
  (with-output-language (Lanf Expr)
    `(let ([f (lambda (u v) u)])
       (let ([r (call f a)])
         r))))

(ok/show "an arity mismatch is refused"
         (= 1 (count-calls (inline-program arity-prog) 'f))
         (inline-program arity-prog))

;; --- 7. nesting, and the depth budget ------------------------------------

;; Binders are distinct across the two procedures. That is not test hygiene, it
;; is the precondition the pass documents: names are globally unique, which is
;; what makes it safe to leave the callee's FREE variables alone when splicing a
;; copy into a deeper scope.
(define nested-prog
  (with-output-language (Lanf Expr)
    `(let ([inner (lambda (ui)
                    (let ([wi (primcall fl* ([fp-contract unchecked]) ui ui)]) wi))])
       (let ([outer (lambda (uo)
                      (let ([wo (call inner uo)]) wo))])
         (let ([r (call outer a)])
           r)))))

(define nested-out (inline-program nested-prog))

(ok/show "inlining nests, within the depth budget"
         (and (= 0 (count-calls nested-out 'outer))
              (= 0 (count-calls nested-out 'inner))
              (= 1 (count-primcall nested-out 'fl*))
              (no-duplicates? (binders nested-out))
              (subset? (free-vars nested-out) (free-vars nested-prog)))
         nested-out)

(ok! "depth 1 stops after the outer call"
     (parameterize ([inline-depth-budget 1])
       (let ([out (inline-program nested-prog)])
         (and (= 0 (count-calls out 'outer))
              (= 1 (count-calls out 'inner))))))

;; --- 8. a call that survives inlining becomes a non-tail call ------------
;; The callee's `tailcall` is in the caller's non-tail position now, so it has
;; to be rewritten as a `call` with its result named. Getting this wrong is a
;; silent stack-discipline bug, not a grammar error.

(define tailconv-prog
  (with-output-language (Lanf Expr)
    `(let ([thunk (lambda (u) (tailcall opaque u))])
       (let ([r (call thunk a)])
         r))))

(define tailconv-out (inline-program tailconv-prog))

(ok/show "an inlined tail call becomes a named non-tail call"
         (and (= 0 (count-calls tailconv-out 'thunk))
              (= 1 (count-nodes tailconv-out
                     (lambda (kind n)
                       (and (eq? kind 'se)
                            (nanopass-case (Lanf SimpleExpr) n
                              [(call ,x ,x* ...) (eq? x 'opaque)]
                              [else #f])))))
              (= 0 (count-nodes tailconv-out
                     (lambda (kind n)
                       (and (eq? kind 'e)
                            (nanopass-case (Lanf Expr) n
                              [(tailcall ,x ,x* ...) (eq? x 'opaque)]
                              [else #f]))))))
         tailconv-out)

(printf "\n~a checks, ~a failures\n" checks failures)
(if (> failures 0) (exit 1) (begin (printf "PASS\n") (exit 0)))
