;;; Full unrolling, spelled as specialization.
;;;
;;; A loop here is a letrec-bound procedure that tail-calls itself, so "fully
;;; unroll it" is not a separate transformation: it is what you get from
;;; substituting the body at a call whose arguments are all literals, and then
;;; letting fold.ss collapse the guard so the next call's argument is a literal
;;; too. Repeat until the guard says stop. The loop is gone because its exit
;;; branch folded, not because anything counted iterations.
;;;
;;; ## Why it is worth the code growth
;;;
;;; nbody's whole remaining gap to `gcc -O3 -march=native` is integer: 370
;;; operations per step against 36. Reading gcc's output says why -- five
;;; separate `vsqrtsd` sites in its `main` -- it fully unrolled the ten-pair
;;; nest, so every index is a constant displacement off one base register. No
;;; counter, no bound, no back edge, and no `imul`, because `bi = i*3` folds
;;; once `i` is a literal.
;;;
;;; ## Why unroll.ss cannot do it
;;;
;;; That pass replaces a self tail call with a copy of the body and consults no
;;; trip count, deliberately: it is correct for a loop that runs zero times, an
;;; odd number of times, or a number nobody can compute. Applying it repeatedly
;;; gives 2^k copies and was MEASURED at 16 -> 28 -> 36 `imul`s -- growing,
;;; because the parameter stays symbolic on every path. Copies of a loop whose
;;; counter is unknown are still a loop.
;;;
;;; The difference here is the ENTRY. Until `(loop 0)` itself is substituted,
;;; the parameter is never a literal and nothing downstream can fold. That is
;;; the one thing this pass adds, and everything else follows from fold.ss.
;;;
;;; ## Termination
;;;
;;; Not by budget, though there is one. Each round substitutes at a call whose
;;; arguments are literals; fold.ss then evaluates the guard and deletes the
;;; branch, so the copy either contains a further self call with a literal
;;; argument or it does not. When the guard goes the other way the exit arm has
;;; no self call left and there is nothing to substitute. A loop whose counter
;;; is not a literal is never touched at all.
;;;
;;; The budget is for the loop that runs a million times, which would otherwise
;;; unroll a million copies before the guard turned. It is a size cap rather
;;; than an iteration count because the thing worth bounding is the program.
;;;
;;; ## WHAT IT CANNOT REACH, WHICH IS THE LOOP THAT MATTERS
;;;
;;; Only `(tailcall f x*)`. A loop entered from a NON-TAIL position is
;;; `(let ([r (call f x*)]) body)`, and substituting there means splicing a
;;; body whose value has to reach `r` -- which inline.ss's `splice` does only
;;; when the body has exactly ONE tail position (its rule 5). A loop body is an
;;; `if` with two arms, so it never does.
;;;
;;; That is not a corner case, it is nbody's pair nest. Measured on the Lanf
;;; this pass is handed, one line per letrec-bound loop and how its name is
;;; used:
;;;
;;;     loop%12   tailcall tailcall
;;;     outer%22  CALL     tailcall
;;;     inner%24  CALL     tailcall
;;;     loop%35   tailcall tailcall
;;;
;;; So this pass unrolls `loop%12` and `loop%35` -- the position updates, where
;;; there is no index arithmetic worth folding -- and cannot touch `outer%22`
;;; or `inner%24`, which is the entire reason full unrolling was worth wanting.
;;; It unrolls precisely the wrong loops.
;;;
;;; Fixing it needs a JOIN: each of the body's tail positions assigns the
;;; result and jumps to a common continuation. The IR already has that shape --
;;; `join.286` in nbody is one -- so it is real work rather than impossible
;;; work, and it belongs to inline.ss's rule 5 rather than here.
;;;
;;; ## What it will not touch
;;;
;;; A procedure that is not self-tail-recursive: that is inlining, inline.ss
;;; owns it, and its rule 4 refuses recursion for a reason this pass has to
;;; work around rather than ignore. A call with any non-literal argument. And a
;;; body over the size budget, checked BEFORE the first substitution rather
;;; than after -- a body that is too big to copy once is too big to copy ten
;;; times, and finding that out on the tenth is how a compiler runs out of
;;; memory.

(library (sonic specialize)
  (export specialize-program specialize-program/report specialize-size-budget
          specialize-enabled? specialize-growth-budget
          specialize-stats specialize-stats? specialize-stats-specialized
          specialize-stats-names)
  (import (chezscheme) (nanopass) (sonic lang)
          (only (sonic inline) freshen expr-size))

  (define-record-type (specialize-stats make-specialize-stats specialize-stats?)
    (fields (mutable specialized) (mutable names)))

  ;; OFF, AND THE REASON IS MEASURED. Everything below works and the answers
  ;; stay right -- nbody bit-exact, fannkuch 228/16 -- and it is a net LOSS:
  ;;
  ;;     instructions/step   717.50 -> 778.50
  ;;     cycles/step         189.19 -> 216.31
  ;;
  ;; TWO THINGS GO WRONG, and neither is inherent.
  ;;
  ;; 1. BOUNDS CHECK ELISION COLLAPSES. nbody emits ZERO bounds checks as a
  ;;    loop and 160 when the position loop is unrolled into `advance!`. That
  ;;    is backwards -- a constant index into a vector of known length is the
  ;;    easiest case there is -- so something the copies carry is not what
  ;;    elide.ss needs. The premises attached by `declare` and the length facts
  ;;    shapes.ss propagates across the call are the first suspects, because
  ;;    `freshen` renames binders and a premise naming an old binder is a
  ;;    premise about nothing.
  ;;
  ;; 2. THE PAIR NEST DOES NOT UNROLL, which is the one that matters --
  ;;    `inner%24` survives with its `sqrtsd`. The outer loop's copies each
  ;;    contain a FRESHENED copy of the inner letrec, under a new name, and the
  ;;    copy budget is keyed by name. Every copy therefore gets a fresh budget
  ;;    while the driver's round limit is global, so the rounds are spent on
  ;;    the cheap loop and run out before the expensive one.
  ;;
  ;; So the position loop -- 5 copies, no arithmetic worth folding -- unrolled,
  ;; and the pair nest -- 10 bodies, two `imul`s each, the entire point -- did
  ;; not. Fix (1) before touching (2): the elision regression is most of the
  ;; cost and it would sink the transformation even after (2) worked.
  (define specialize-enabled? (make-parameter #f))

  ;; The most a single loop body may be, in Lanf nodes, before this refuses to
  ;; copy it at all. nbody's pair body is well under; a body larger than this is
  ;; one whose unrolled form nobody wants to read or compile.
  (define specialize-size-budget (make-parameter 400))

  ;; HOW MUCH THE WHOLE PROGRAM MAY GROW, as a multiple of what it started at.
  ;;
  ;; It was a per-name copy count and that bounded NOTHING. `freshen` renames
  ;; the letrec-bound loop in every copy, so each copy is a brand-new name with
  ;; a brand-new budget -- a counter over names minted per copy. The only real
  ;; bound was the driver's round limit, which is why raising that from 24 to
  ;; 400 took nbody from 810 instructions to 27,628.
  ;;
  ;; Program size is the thing actually worth bounding, and unlike a name it
  ;; cannot be reset by renaming.
  (define specialize-growth-budget (make-parameter 4))

  (define (self-tail-recursive? f body)
    (let walk ((e body))
      (nanopass-case (Lanf Expr) e
        [(tailcall ,x ,x* ...) (eq? x f)]
        [(if ,x ,e0 ,e1) (or (walk e0) (walk e1))]
        [(seq ,e0 ,e1) (walk e1)]
        [(let ([,x ,se]) ,body) (walk body)]
        [(letrec ([,x* ,e*] ...) ,body) (walk body)]
        [(declare ([,x* ,prem*] ...) ,body) (walk body)]
        ;; NOT optional -- every kernel taking vectors has its body wrapped in
        ;; one, so omitting it answers #f for exactly the loops worth unrolling.
        ;; unroll.ss records that this cost it a measurement.
        [(declare-distinct (,x* ...) ,body) (walk body)]
        [(policy ([,pn* ,b*] ...) ,body) (walk body)]
        [else #f])))

  (define (specialize-program prog)
    (let-values (((out st) (specialize-program/report prog))) out))

  (define (specialize-program/report prog)
    (let ((stats (make-specialize-stats 0 '()))
          ;; name -> (params . body) for every letrec-bound self-tail-recursive
          ;; lambda. Lanf is alpha-converted, so one table over the whole
          ;; program cannot confuse two bindings of one name.
          (loops (make-eq-hashtable))
          ;; What the program measured before this round, for the growth budget.
          (start-size 0)
          ;; var -> datum, for let-bound literals. Same rule as fold.ss.
          (lits (make-eq-hashtable)))

      (define (literal? x) (and (symbol? x) (hashtable-ref lits x #f) #t))

      ;; --- pass one: what is a loop, and what is a literal -------------------
      (define (scan-expr e)
        (nanopass-case (Lanf Expr) e
          [(let ([,x ,se]) ,body)
           (nanopass-case (Lanf SimpleExpr) se
             [(quote ,d) (hashtable-set! lits x (list d))]
             [(lambda (,x* ...) ,body) (scan-expr body)]
             [else (void)])
           (scan-expr body)]
          [(if ,x ,e0 ,e1) (scan-expr e0) (scan-expr e1)]
          [(seq ,e0 ,e1) (scan-expr e0) (scan-expr e1)]
          [(lambda (,x* ...) ,body) (scan-expr body)]
          [(letrec ([,x* ,e*] ...) ,body)
           (for-each
            (lambda (nm rhs)
              (nanopass-case (Lanf Expr) rhs
                [(lambda (,x* ...) ,body)
                 (when (and (self-tail-recursive? nm body)
                            (<= (expr-size body) (specialize-size-budget)))
                   (hashtable-set! loops nm (cons x* body)))
                 (scan-expr body)]
                [else (scan-expr rhs)]))
            x* e*)
           (scan-expr body)]
          [(declare ([,x* ,prem*] ...) ,body) (scan-expr body)]
          [(declare-distinct (,x* ...) ,body) (scan-expr body)]
          [(policy ([,pn* ,b*] ...) ,body) (scan-expr body)]
          [else (void)]))

      ;; --- pass two: a specialized COPY, not a splice -------------------------
      ;;
      ;; The call is REDIRECTED to a nullary sibling binding whose body is the
      ;; original with the parameters replaced by the literals:
      ;;
      ;;     (letrec ([f (lambda (x) body)])
      ;;       (let ([r (call f zero)]) rest))
      ;;   =>
      ;;     (letrec ([f   (lambda (x) body)]
      ;;              [f@0 (lambda () body[x := zero])])
      ;;       (let ([r (call f@0)]) rest))
      ;;
      ;; SPLICING WOULD NOT WORK AND THAT IS THE POINT. Inlining a body at a
      ;; non-tail call site means its value has to reach `r`, which inline.ss's
      ;; `splice` does only for a body with ONE tail position -- rule 5 -- and a
      ;; loop body is an `if` with two arms. Measured: nbody's pair nest,
      ;; `outer%22` and `inner%24`, is entered by `call` and not by `tailcall`,
      ;; so an earlier version of this pass could not touch it and unrolled the
      ;; position loops instead. Redirecting a call needs no value to travel, so
      ;; a non-tail entry is handled exactly like a tail one.
      ;;
      ;; The recursion then chains rather than nests: inside `f@0` the guard and
      ;; the index arithmetic fold, and the self call `(tailcall f (fx+ 0 1))`
      ;; has a literal argument, so the next round redirects it to `f@1`. The
      ;; loop becomes f@0 -> f@1 -> ... -> exit, joined by TAIL calls, which are
      ;; jumps with no frame.
      ;;
      ;; KEYED BY (name . literals), so two call sites with the same argument
      ;; share one copy and the budget counts copies that exist rather than
      ;; substitutions performed. That is also what makes the count meaningful
      ;; where a per-name budget was not: `freshen` mints a new name per copy,
      ;; and a key made of the ORIGINAL name and the literals does not move.
      (define pending '())        ; (key name args) awaiting a binding
      (define made (make-hashtable equal-hash equal?))   ; key -> new name

      ;; The ORIGINAL name and the literal VALUES, so two call sites with the
      ;; same arguments share a copy -- and so the key does not move when
      ;; `freshen` renames things.
      (define (key-of f x*)
        (cons f (map (lambda (v) (car (hashtable-ref lits v '(#f)))) x*)))

      (define counter 0)
      (define (copy-name f)
        (set! counter (+ counter 1))
        (string->symbol (string-append (symbol->string f) "@"
                                       (number->string counter))))

      (define (eligible? f x*)
        (let ((p (hashtable-ref loops f #f)))
          (and p
               (= (length (car p)) (length x*))
               (specialize-enabled?)
               (for-all literal? x*)
               (or (hashtable-ref made (key-of f x*) #f)
                   (<= (+ (hashtable-size made) 1)
                       (* (specialize-growth-budget) 8))))))

      ;; THE PARAMETERS ARE BOUND INSIDE THE COPY, to the literal VALUES, and
      ;; that is forced by where the copy lives rather than by taste.
      ;;
      ;; A copy is a SIBLING BINDING of the loop it copies, so it is evaluated
      ;; in the letrec's scope -- which does not include anything bound in the
      ;; letrec's BODY. The call site's argument variable is bound there:
      ;;
      ;;     (letrec ([f (lambda (x) body)])
      ;;       (let ([zero (quote 0)]) (call f zero)))
      ;;
      ;; so substituting `zero` for `x` inside a sibling binding references a
      ;; variable that is not in scope. Measured, when I did exactly that:
      ;; "no storage class for this vreg, so an `if` cannot say how to copy it
      ;; into the join destination" -- the class fixpoint had nothing to say
      ;; about a name with no binding anywhere.
      ;;
      ;; Binding the literal inside the copy needs no outer scope at all, and
      ;; fold.ss then propagates it exactly as it would have propagated the
      ;; argument.
      (define (copy-body f args)
        (let* ((p (hashtable-ref loops f #f))
               (params (car p))
               ;; Fresh names for the parameters, because two copies of one loop
               ;; are two bindings and every pass after this assumes names are
               ;; unique program-wide.
               (fresh-ps (map (lambda (q)
                                (set! counter (+ counter 1))
                                (string->symbol
                                 (string-append (symbol->string q) "."
                                                (number->string counter))))
                              params))
               (b (freshen (cdr p) (map cons params fresh-ps)))
               (vals (map (lambda (a) (car (hashtable-ref lits a '(#f)))) args)))
          (with-output-language (Lanf Expr)
            `(lambda ()
               ,(let wrap ((ps fresh-ps) (vs vals))
                  (if (null? ps)
                      b
                      (with-output-language (Lanf Expr)
                        `(let ([,(car ps) (quote ,(car vs))])
                           ,(wrap (cdr ps) (cdr vs))))))))))

      ;; The name to call, making the copy if this is the first request for it.
      (define (copy-for f x*)
        (let ((k (key-of f x*)))
          (or (hashtable-ref made k #f)
              (let ((nm (copy-name f)))
                (hashtable-set! made k nm)
                (set! pending (cons (list nm f x*) pending))
                (specialize-stats-specialized-set!
                 stats (+ 1 (specialize-stats-specialized stats)))
                (unless (memq f (specialize-stats-names stats))
                  (specialize-stats-names-set!
                   stats (cons f (specialize-stats-names stats))))
                nm))))

      (define (Expr e)
        (with-output-language (Lanf Expr)
          (nanopass-case (Lanf Expr) e
            [(tailcall ,x ,x* ...)
             (if (eligible? x x*)
                 `(tailcall ,(copy-for x x*))
                 e)]
            [(if ,x ,e0 ,e1) `(if ,x ,(Expr e0) ,(Expr e1))]
            [(seq ,e0 ,e1) `(seq ,(Expr e0) ,(Expr e1))]
            [(let ([,x ,se]) ,body) `(let ([,x ,(SimpleExpr se)]) ,(Expr body))]
            [(lambda (,x* ...) ,body) `(lambda (,x* ...) ,(Expr body))]
            ;; THE COPIES LAND HERE, in the letrec that binds what they are
            ;; copies of -- which is the only place they are certainly in
            ;; scope, and where a self call inside them still resolves.
            [(letrec ([,x* ,e*] ...) ,body)
             (let* ((before pending)
                    (_ (set! pending '()))
                    (e1* (map Expr e*))
                    (b1 (Expr body))
                    (mine (filter (lambda (r) (memq (cadr r) x*)) pending))
                    (theirs (filter (lambda (r) (not (memq (cadr r) x*))) pending)))
               (set! pending (append theirs before))
               (if (null? mine)
                   `(letrec ([,x* ,e1*] ...) ,b1)
                   (let ((nm* (map car mine))
                         (bd* (map (lambda (r) (copy-body (cadr r) (caddr r))) mine)))
                     `(letrec ([,(append x* nm*) ,(append e1* bd*)] ...) ,b1))))]
            [(declare ([,x* ,prem*] ...) ,body)
             `(declare ([,x* ,prem*] ...) ,(Expr body))]
            [(declare-distinct (,x* ...) ,body)
             `(declare-distinct (,x* ...) ,(Expr body))]
            [(policy ([,pn* ,b*] ...) ,body)
             `(policy ([,pn* ,b*] ...) ,(Expr body))]
            [else e])))

      (define (SimpleExpr se)
        (with-output-language (Lanf SimpleExpr)
          (nanopass-case (Lanf SimpleExpr) se
            [(lambda (,x* ...) ,body) `(lambda (,x* ...) ,(Expr body))]
            ;; A NON-TAIL ENTRY, which is how nbody's pair nest is reached and
            ;; what the splice-based version could not touch at all.
            [(call ,x ,x* ...)
             (if (eligible? x x*) `(call ,(copy-for x x*)) se)]
            [else se])))

      ;; D32: the pipeline hands a Program, and a pass matching only Expr falls
      ;; through its `else` and reports success having done nothing. Six passes
      ;; had that defect; this is not the seventh.
      (nanopass-case (Lanf Program) prog
        [(top ([,x* ,e*] ...) (,x2* ...) ,body)
         (set! start-size
               (fold-left (lambda (a e) (+ a (expr-size e))) (expr-size body) e*))
         (for-each (lambda (x e)
                     (nanopass-case (Lanf Expr) e
                       [(quote ,d) (hashtable-set! lits x (list d))]
                       [else (void)])
                     (scan-expr e))
                   x* e*)
         (scan-expr body)
         (values
          (with-output-language (Lanf Program)
            (let ((e1* (map Expr e*)))
              `(top ([,x* ,e1*] ...) (,x2* ...) ,(Expr body))))
          stats)]
        [else (values prog stats)])))
  )
