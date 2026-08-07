;;; SonicScheme: extended SSA construction. Lanf -> Lssa.
;;;
;;; Stage 06. This is the pass ABCD (Bodik, Gupta and Sarkar, PLDI 2000) runs
;;; on, and the reason it needs its own IR rather than plain SSA is one line of
;;; that paper: a difference-constraint system is only equivalent to the
;;; flow-sensitive one if every variable's live range is contained in the scope
;;; of every constraint mentioning it. Standard SSA splits live ranges at
;;; assignments. Conditionals need the extra split, and that split is SIGMA.
;;;
;;; On the true edge of (fx< i n) the analysis must be able to say "this i is
;;; the one that is less than n". If both edges keep the name `i`, an interval
;;; domain cannot tell which side of the test it is on and no bounds check is
;;; ever discharged. sonic/src/sonic/analyze.ss already does exactly this
;;; refinement in its `refine` procedure, but only over a toy tree walk that
;;; hard-codes `if` as the only control construct; sigma is what makes the same
;;; refinement expressible as a property of the IR.
;;;
;;; THREE THINGS THIS PASS DOES.
;;;
;;;   1. Unique names per definition. Lanf has no `set!`, so every binder is
;;;      already a single definition and SSA construction here is alpha
;;;      renaming: `i` becomes `i.7`. The base name is preserved so fixtures
;;;      and disassembly stay readable, and the counter is reset per pass
;;;      invocation so the output is deterministic and testable.
;;;
;;;   2. Phi at joins. See the note on phi placement below: in Lanf there are
;;;      exactly two of them, and one is a lambda's parameter list.
;;;
;;;   3. Sigma on both edges of a conditional whose test is a comparison, for
;;;      the variables that comparison actually constrains and no others.
;;;      Sigma-ing every live variable is correct and would triple the size of
;;;      every downstream fixture for nothing.
;;;
;;; WHERE PHI CAN GO IN Lanf, WHICH IS NOT WHERE A CFG WOULD PUT IT.
;;;
;;; Lanf's `if` takes an atom and two Exprs, and `if` is NOT a SimpleExpr, so
;;; it cannot appear on the right of a `let`. A diamond therefore never has a
;;; syntactic point where the two arms' values meet and flow onward: the value
;;; of an `if` is either discarded (statement position, the first arm of `seq`)
;;; or returned. This is Appel's "SSA is functional programming" holding in the
;;; other direction, and it means:
;;;
;;;   - A LOOP HEADER is a letrec-bound lambda, and its phis are its
;;;     PARAMETERS, each a merge of the entry value and the back-edge values.
;;;     We name that merge explicitly: (lambda (i.1) (phi ([i.2 i.1]) body)).
;;;     This is the phi that matters, because it is the one ABCD's inequality
;;;     graph needs a vertex for.
;;;
;;;   - A DIAMOND's join is the enclosing function's return. We name the merged
;;;     value where it is produced: (phi ([join.4 (if ...)]) join.4), emitted
;;;     only when the `if` is in value position. In statement position the
;;;     merge is dead and no phi is emitted.
;;;
;;; WHAT SIGMA EXPRESSES, AND WHAT IT DOES NOT DECIDE.
;;;
;;; A sigma is a syntactic report: this edge is the one where (p a b) held, or
;;; the one where it failed. It does not say what follows from that. The false
;;; edge of (fl< a b) is emitted as an fl< sigma with negated? set, NOT as an
;;; fl>= sigma, because NaN makes the negation true where fl>= is false. Turning
;;; the report into an interval is (sonic interval)'s iv-refine, and that is the
;;; only place the NaN rule appears.

(library (sonic essa)
  (export essa comparison-prim? cmp-swap)
  (import (chezscheme) (nanopass) (sonic lang))

  ;; --- the comparison algebra -----------------------------------------------
  ;; Each row: the primitive and its SWAP ((p a b) iff (swap(p) b a)).
  ;;
  ;; SWAP IS ALL THIS PASS KNOWS, AND THAT IS DELIBERATE. There is no negation
  ;; column, because negating a comparison is a claim about the numbers and this
  ;; pass only reports syntax. NaN makes every comparison false, so
  ;; (not (fl<= a b)) is TRUE for a NaN operand while (fl> a b) is false, and a
  ;; pass that rewrote the false edge of (fl< a b) into an fl>= sigma would
  ;; assert an ordering in exactly the case where neither ordering holds. There
  ;; is no fx<> either, so the false edge of an equality had nowhere to go at
  ;; all.
  ;;
  ;; Both problems are the same problem, and the fix is the same: the false edge
  ;; carries the comparison AS WRITTEN with sigma's negated? flag set, and
  ;; (sonic interval) decides what follows from it -- an ordering for fixnums,
  ;; nothing for flonums, nothing for a disequality. See iv-refine.
  ;;
  ;; Swapping needs no such care and holds on both edges: (p a b) and
  ;; (swap(p) b a) are the same test, so they are true together and false
  ;; together, NaN included.
  (define cmp-table
    ;;  prim   swap
    '((fx<     fx>)
      (fx<=    fx>=)
      (fx=     fx=)
      (fx>=    fx<=)
      (fx>     fx<)
      (fl<     fl>)
      (fl<=    fl>=)
      (fl=     fl=)
      (fl>=    fl<=)
      (fl>     fl<)))

  (define (comparison-prim? pr) (and (assq pr cmp-table) #t))
  (define (cmp-swap pr) (cadr (assq pr cmp-table)))

  ;; --- fresh names ----------------------------------------------------------
  ;; Readable rather than gensym'd: `i.7` beats `g$1234`, fixtures are written
  ;; and read by hand here, and the counter reset at pass entry keeps the
  ;; output reproducible so a test can assert on it.

  (define name-counter 0)
  (define (reset-names!) (set! name-counter 0))

  ;; Strip a trailing ".ddd" so re-running the pass does not grow names without
  ;; bound. `i` -> `i`, `i.7` -> `i`, `x1` -> `x1` (no dot, so not ours).
  (define (base-of x)
    (let* ([s (symbol->string x)] [n (string-length s)])
      (let loop ([i (- n 1)])
        (cond [(< i 0) s]
              [(= i (- n 1)) (if (char-numeric? (string-ref s i)) (loop (- i 1)) s)]
              [(char-numeric? (string-ref s i)) (loop (- i 1))]
              [(char=? (string-ref s i) #\.) (substring s 0 i)]
              [else s]))))

  (define (fresh-name x)
    (set! name-counter (+ name-counter 1))
    (string->symbol
      (string-append (base-of x) "." (number->string name-counter))))

  ;; --- environments ---------------------------------------------------------
  ;; env : source name -> current SSA name. An alist, newest first, so
  ;; shadowing is just a longer list. A name with no entry is free (a top-level
  ;; or runtime binding) and maps to itself.
  ;;
  ;; facts : SSA name of a boolean -> (prim (a-src . a-ssa) (b-src . b-ssa)).
  ;; Recorded when a comparison primcall is let-bound, consumed when the `if`
  ;; that tests it is reached. Both the source and SSA names are kept because
  ;; the source name can be REBOUND between the two points:
  ;;
  ;;   (let ([c (fx< i n)]) (let ([i (quote 5)]) (if c ...)))
  ;;
  ;; Here the fact is about the old i, and refining the new one would be
  ;; unsound. Comparing the recorded SSA name against what the source name maps
  ;; to now detects that in one eq? and we drop the sigma for that operand.

  ;; LEFT-TO-RIGHT map, for effectful functions.
  ;;
  ;; Chez does not promise an application order for `map`, and every
  ;; `(map/lr fresh-name x*)` below mutates a counter. Under a different order the
  ;; same input compiles to differently-named IR: still correct, but not
  ;; reproducible, and essa-test.ss asserts specific names like i.2 and n.3, so
  ;; it would be flaky rather than wrong. Deterministic output also matters for
  ;; the differential harness, which diffs two builds of the same program.
  (define (map/lr f xs)
    (let loop ([xs xs] [acc '()])
      (if (null? xs)
          (reverse acc)
          (let ([v (f (car xs))])          ; forced before the recursive call
            (loop (cdr xs) (cons v acc))))))

  (define (env-lookup env x)
    (let ([p (assq x env)]) (if p (cdr p) x)))

  (define (fact-ref facts x)
    (let ([p (assq x facts)]) (and p (cdr p))))

  ;; Conservative occurrence test over the unparsed term: does this letrec
  ;; binding refer to itself or to a sibling, making the group a loop? A false
  ;; positive (a shadowing inner binder of the same name) costs one redundant
  ;; header phi, which is safe; a false negative would lose the loop, which is
  ;; not, so the test is deliberately the over-approximating direction.
  (define (occurs? x s)
    (cond [(pair? s) (or (occurs? x (car s)) (occurs? x (cdr s)))]
          [else (eq? x s)]))

  (define (occurs-in-any? x forms)
    (let loop ([fs forms])
      (cond [(null? fs) #f]
            [(occurs? x (unparse-Lanf (car fs))) #t]
            [else (loop (cdr fs))])))

  ;; --- the pass -------------------------------------------------------------

  (define-pass essa : Lanf (e) -> Lssa ()
    (definitions

      ;; Build the sigma nodes for ONE edge of a conditional.
      ;;
      ;; Returns the environment the branch body must be converted under, and a
      ;; wrapper that puts the sigmas around that converted body. It has to be
      ;; in that order: the refined names have to exist before the body can
      ;; reference them.
      ;;
      ;; For a test (p a b) taken on this edge, ABCD wants BOTH operands split,
      ;; because the true edge of a<b tells you as much about b as about a. So:
      ;;
      ;;   (sigma a2 a  p        b  neg  (sigma b2 b  swap(p)  a2  neg  body))
      ;;
      ;; a2's other operand is the unrefined b (b2 is not in scope yet); b2's
      ;; is the already-refined a2, which is what the paper does and is strictly
      ;; more precise.
      ;;
      ;; `neg` is #f on the true edge and #t on the false one, and the SAME
      ;; comparison is emitted on both. Swapping distributes over negation --
      ;; (p a b) and (swap(p) b a) are one test, so they fail together -- so the
      ;; second sigma of a false edge is (swap(p), negated), not swap of some
      ;; negated primitive that may not exist.
      (define (edge-sigmas env f true?)
        (define (nowrap) (values env (lambda (body) body)))
        (if (not f)
            (nowrap)
            (let* ([p (car f)]
                   [asrc (car (cadr f))] [assa (cdr (cadr f))]
                   [bsrc (car (caddr f))] [bssa (cdr (caddr f))]
                   [neg (not true?)]
                   [a-ok (eq? (env-lookup env asrc) assa)]
                   ;; (fx< i i) constrains one variable, not two.
                   [b-ok (and (eq? (env-lookup env bsrc) bssa)
                              (not (eq? assa bssa)))]
                   [q (cmp-swap p)])
              (if (and (not a-ok) (not b-ok))
                  (nowrap)
                  (let* ([a^ (and a-ok (fresh-name asrc))]
                         [b^ (and b-ok (fresh-name bsrc))]
                         [env1 (if a-ok (cons (cons asrc a^) env) env)]
                         [env2 (if b-ok (cons (cons bsrc b^) env1) env1)]
                         [aother (if a-ok a^ assa)])
                    (values
                      env2
                      (lambda (body)
                        (with-output-language (Lssa Expr)
                          (let ([inner (if b-ok
                                           `(sigma ,b^ ,bssa ,q ,aother ,neg ,body)
                                           body)])
                            (if a-ok
                                `(sigma ,a^ ,assa ,p ,bssa ,neg ,inner)
                                inner))))))))))

      ;; Does this let-bound simple expression establish a comparison fact?
      ;; Operands in Lanf are atoms by construction, so both are variables and
      ;; there is nothing to normalize.
      (define (simple-fact se env)
        (nanopass-case (Lanf SimpleExpr) se
          [(primcall ,pr ([,pn* ,c*] ...) ,x* ...)
           (and (comparison-prim? pr)
                (= (length x*) 2)
                (list pr
                      (cons (car x*) (env-lookup env (car x*)))
                      (cons (cadr x*) (env-lookup env (cadr x*)))))]
          [else #f])))

    ;; val? says whether this expression's value is consumed. It decides
    ;; whether a diamond's merge gets a name; nothing else depends on it.
    (Expr : Expr (e env facts val?) -> Expr ()
      [,x `,(env-lookup env x)]

      [(quote ,d) `(quote ,d)]

      [(if ,x ,e0 ,e1)
       (let*-values ([(x^) (env-lookup env x)]
                     [(f) (fact-ref facts x^)]
                     [(env-t wrap-t) (edge-sigmas env f #t)]
                     [(env-f wrap-f) (edge-sigmas env f #f)])
         (let ([node `(if ,x^
                          ,(wrap-t (Expr e0 env-t facts val?))
                          ,(wrap-f (Expr e1 env-f facts val?)))])
           (if val?
               ;; A value-position diamond. Both arms merge here, and phi now
               ;; names WHICH arm each incoming value came from, so a consumer
               ;; can tell an induction variable stepped inside a conditional
               ;; from one stepped unconditionally. Before this the whole node
               ;; was one opaque operand and such a loop was unanalysable.
               ;; A value-position diamond, and the ONE case per-predecessor
               ;; operands do not fix.
               ;;
               ;; Lanf's `if` is not a SimpleExpr, so there is no syntactic
               ;; point where the two arms' values are named and flow onward.
               ;; The arms are whole expressions, so labelling them would mean
               ;; either duplicating the `if` into both operands (which doubles
               ;; the code and breaks unique naming outright -- tried, it does)
               ;; or introducing a join continuation, which is a different
               ;; lowering and a separate bead.
               ;;
               ;; So this carries ONE operand on a `join` edge. The consequence
               ;; stands as loops.ss reported it: an induction variable stepped
               ;; inside a conditional has an opaque back-edge operand and comes
               ;; back `unknown`. Counted loops, which is what stage 10 needs,
               ;; are unaffected because their phis are HEADER phis and those
               ;; now carry real per-predecessor operands.
               (let* ([j (fresh-name 'join)]
                      [lbls (list 'join)]
                      [vals (list node)])
                 `(phi ([,j (,lbls ,vals) ...]) ,j))
               node)))]

      [(let ([,x ,se]) ,body)
       (let* ([se^ (SimpleExpr se env facts)]
              [f (simple-fact se env)]
              [x^ (fresh-name x)]
              [env1 (cons (cons x x^) env)]
              [facts1 (if f (cons (cons x^ f) facts) facts)])
         `(let ([,x^ ,se^]) ,(Expr body env1 facts1 val?)))]

      ;; The loop case. Binders first so the RHSs see each other, then each
      ;; lambda in the group gets a header phi if the group is recursive.
      [(letrec ([,x* ,e*] ...) ,body)
       (let* ([x^* (map/lr fresh-name x*)]
              [env1 (append (map cons x* x^*) env)]
              [rhs*
               (map (lambda (xs rhs)
                      (let ([header? (occurs-in-any? xs e*)])
                        (nanopass-case (Lanf Expr) rhs
                          [(lambda (,x** ...) ,body2)
                           (let* ([p* (map/lr fresh-name x**)]
                                  [env2 (append (map cons x** p*) env1)])
                             (if header?
                                 (let* ([h* (map/lr fresh-name x**)]
                                        [env3 (append (map cons x** h*) env2)]
                                        [in* (map (lambda (p)
                                                    (with-output-language (Lssa Expr) `,p))
                                                  p*)]
                                        ;; One operand per binding, on the
                                        ;; `entry` edge. The back edge's
                                        ;; operands live on the tailcall and are
                                        ;; recovered positionally by loops.ss.
                                        [lbl** (map (lambda (_) '(entry)) p*)]
                                        [in**  (map list in*)])
                                   ;; The header phi. `entry` is the incoming
                                   ;; edge; the back edge's operands live on the
                                   ;; tailcall and are still recovered by
                                   ;; position, which is what loops.ss does.
                                   `(lambda (,p* ...)
                                      (phi ([,h* (,lbl** ,in**) ...] ...)
                                        ,(Expr body2 env3 facts #t))))
                                 `(lambda (,p* ...) ,(Expr body2 env2 facts #t))))]
                          [else (Expr rhs env1 facts #t)])))
                    x* e*)])
         `(letrec ([,x^* ,rhs*] ...) ,(Expr body env1 facts val?)))]

      [(lambda (,x* ...) ,body)
       (let* ([p* (map/lr fresh-name x*)]
              [env1 (append (map cons x* p*) env)])
         `(lambda (,p* ...) ,(Expr body env1 facts #t)))]

      ;; declare's variables are REFERENCES, not binders: the form states a
      ;; premise about a variable already in scope.
      [(declare ([,x* ,prem*] ...) ,body)
       (let ([x^* (map (lambda (x) (env-lookup env x)) x*)])
         `(declare ([,x^* ,prem*] ...) ,(Expr body env facts val?)))]

      [(policy ([,pn* ,b*] ...) ,body)
       `(policy ([,pn* ,b*] ...) ,(Expr body env facts val?))]

      ;; tailcall and set! MUST have explicit clauses. Nanopass generates a
      ;; fallthrough that copies operands verbatim, with no env-lookup, so
      ;; without these a back edge emits `(tailcall loop i2 n)` while the
      ;; binders are `loop.1`, `i2.11`, `n.5` — every operand names a variable
      ;; that does not exist. Silent, and it breaks every loop consumer
      ;; downstream, since a back edge is exactly where the loop analysis reads
      ;; its induction step.
      ;;
      ;; The generated clause is the dangerous kind of default: it typechecks,
      ;; it round-trips, and it is wrong.
      [(tailcall ,x ,x* ...)
       `(tailcall ,(env-lookup env x)
                  ,(map (lambda (a) (env-lookup env a)) x*) ...)]

      ;; set!'s TARGET is a reference to a binder already in scope, not a new
      ;; one, so it renames like any other use. The value is an ordinary
      ;; expression.
      [(set! ,x ,e)
       `(set! ,(env-lookup env x) ,(Expr e env facts #t))]

      ;; declare-distinct's variables are references, same as declare's.
      [(declare-distinct (,x* ...) ,body)
       `(declare-distinct (,(map (lambda (x) (env-lookup env x)) x*) ...)
                          ,(Expr body env facts val?))]

      ;; First arm is statement position: its value, and so any merge in it,
      ;; is dead.
      [(seq ,e0 ,e1)
       `(seq ,(Expr e0 env facts #f) ,(Expr e1 env facts val?))])

    (SimpleExpr : SimpleExpr (se env facts) -> SimpleExpr ()
      [,x `,(env-lookup env x)]

      [(quote ,d) `(quote ,d)]

      [(lambda (,x* ...) ,body)
       (let* ([p* (map/lr fresh-name x*)]
              [env1 (append (map cons x* p*) env)])
         `(lambda (,p* ...) ,(Expr body env1 facts #t)))]

      [(call ,x ,x* ...)
       `(call ,(env-lookup env x) ,(map (lambda (a) (env-lookup env a)) x*) ...)]

      [(primcall ,pr ([,pn* ,c*] ...) ,x* ...)
       `(primcall ,pr ([,pn* ,c*] ...)
                  ,(map (lambda (a) (env-lookup env a)) x*) ...)])

    (begin (reset-names!) (Expr e '() '() #t)))
  )
