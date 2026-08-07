;;; SonicScheme: escape analysis over Lanf.
;;;
;;; Stage E4, bead cqs.9. Answers one question per allocation: does this object
;;; outlive the frame that allocated it? If not, it can live in that frame and
;;; the heap never hears about it.
;;;
;;; ## Why this is one of the four places we can exceed SBCL
;;;
;;; `docs/phases/07-compiler/PLAN.md` puts stack allocation in the table of
;;; things CL leaves to the programmer: `dynamic-extent` is a DECLARATION, so
;;; SBCL stack-allocates exactly what you remembered to declare, and declaring
;;; it wrongly is undefined behaviour with no diagnostic. An analysis that
;;; derives the same fact is strictly better on both counts, and .NET 9 and 10
;;; have since shipped the same move for the same reason.
;;;
;;; It also buys back what assignment conversion costs. A `set!` on a local is
;;; converted by boxing the variable into a one-slot heap cell, which turns a
;;; mutated flonum accumulator -- the innermost thing in every numeric loop we
;;; care about -- into a heap object read and written on every iteration. That
;;; box is an allocation like any other, and a box that does not escape is a
;;; stack slot, which is a register after `regalloc.ss` gets to it. So the pass
;;; that makes `set!` expressible is paid for by the pass that makes it free.
;;;
;;; ## Size it honestly
;;;
;;; PLAN.md's risk section is explicit and this file should not oversell.
;;; Blanchet measured 25% of 5.25 gigawords stack-allocated on Coq buying 3.0 to
;;; 4.3%; Keep measured 3.6% for the closure half. And the GC argument for it
;;; does NOT apply to us: a precise generational collector never scans the
;;; short-lived data that escape analysis removes, so "less allocation, less GC,
;;; therefore faster" is unsound here. The justification is data locality and
;;; keeping unboxed flonums out of memory, not collector time.
;;;
;;; ## Soundness direction
;;;
;;; The safe answer is ESCAPES. Saying a site escapes when it does not costs a
;;; stack slot. Saying it does not escape when it does puts a live object in a
;;; frame that is about to be popped, and the failure is a dangling pointer that
;;; the collector will happily trace through. So every default here is `escape`,
;;; every unhandled form escapes what it mentions, and a variable we know
;;; nothing about is top.
;;;
;;; ## The four ways out, and the fifth that Scheme adds
;;;
;;; The bead names four: stored into a heap object, passed to an unknown call,
;;; returned, captured by a closure we cannot account for. Scheme adds a fifth
;;; that a CL or Java analysis never has to think about, and it is the one that
;;; decides whether this pass is useful or useless on real Scheme:
;;;
;;; **A tail call destroys the caller's frame.** `(tailcall f v)` pops the frame
;;; before `f` runs, so a `v` stack-allocated in that frame is gone by the time
;;; the callee reads it -- even when `f` is a known procedure whose body we have
;;; walked. SBCL's answer to the same problem is to SUPPRESS the tail-call merge
;;; and keep the object. For a Scheme that is the wrong trade: iteration IS tail
;;; recursion here, and turning a bounded-space loop into a stack leak to save
;;; one heap allocation is a bad exchange at any allocation rate. So a value
;;; passed to a tail call escapes, and the loop stays a loop.
;;;
;;; The same fact has a second consequence that is easy to miss. A tail call
;;; does not only kill its ARGUMENTS; it kills the whole frame. So a free
;;; variable read inside a procedure that is ENTERED BY A TAIL CALL may refer to
;;; storage in a frame that no longer exists. `tail-entered?` below records
;;; which known procedures are reached that way, and a cross-frame reference
;;; from inside one of them escapes. A self tail call does not count: it
;;; replaces the procedure's own frame, which is not the home of anything the
;;; procedure reads from an enclosing scope.
;;;
;;; That pair of rules is what makes the nbody classification come out right.
;;; The position, velocity and mass arrays are allocated in the top-level frame
;;; and read inside a tail-recursive `advance`, so they escape -- correctly,
;;; because the tail call into `advance` destroyed the frame they would have
;;; lived in. A per-step scratch array allocated inside `advance` and not passed
;;; to the recursive call does NOT escape, and that is the one worth having.
;;;
;;; ## Precision ceiling, stated
;;;
;;; A known procedure called with an ordinary (non-tail) `call` keeps its
;;; caller's frame alive underneath it, so passing a stack-allocated object to
;;; one is safe and this pass says so. That is the whole `dynamic-extent` win
;;; and it is the case worth being precise about. Everything else is a `may`:
;;; an unknown callee, a procedure bound more than once, a procedure used as a
;;; value rather than only as an operator. `alias.ss` names the same ceiling and
;;; the same remedy -- run `(sonic inline)` first and the helpers disappear.
;;;
;;; ## Relationship to alias.ss
;;;
;;; Deliberately parallel in structure and deliberately not shared. `alias.ss`
;;; asks whether two references can touch one object; this asks whether one
;;; object outlives one frame. They agree on three of the escape routes and
;;; disagree on the rest: `alias.ss` has no notion of tail position, so it never
;;; sees a return, and it does not track which frame a site is homed in, so it
;;; never sees the tail-call fault line above. The invariant that DOES hold, and
;;; that `escape-test.ss` asserts, is containment: anything `alias-escaped?`
;;; reports escaped is reported escaped here too. This analysis is the stricter
;;; of the two and must stay that way, because its consumer writes to a frame.
;;;
;;; Name uniqueness is assumed, as there: binders are globally unique, which is
;;; what the expander guarantees.

(library (sonic escape)
  (export escape-analyze escape-table?
          escape-sites escape-site-of
          site? site-id site-binder site-kind site-home
          escape-site-escapes? escape-site-reasons
          escape-escapes? escape-reasons escape-points-to
          escape-stack-allocatable
          escape-known-procs escape-tail-entered?
          escape-reason-names)
  (import (chezscheme) (nanopass) (sonic lang))

  ;; --- what an escape route is called ---------------------------------------
  ;;
  ;; The reason is not decoration. It is the difference between "inline the
  ;; helper and this becomes stack-allocatable" and "this is genuinely heap
  ;; data", and a report that only says `escaped` cannot tell a user which.
  (define (escape-reason-names)
    '(heap-store      ; stored into a vector, a pair, or a fill
      unknown-call    ; handed to a callee we cannot enumerate
      returned        ; in tail position of its own procedure
      closure         ; the closure itself may outlive its binder
      captured        ; read from inside a closure we cannot account for
      tail-call       ; passed to a tail call, whose frame is already gone
      cross-frame     ; read inside a procedure entered by a tail call
      assigned))      ; target of a set!, before assignment conversion

  ;; --- the table ------------------------------------------------------------
  ;; pt      : symbol -> 'unknown | (site-id ...)
  ;; sites   : site-id -> site
  ;; esc     : site-id -> (reason ...)
  ;; known   : symbol -> (param ...)
  ;; tailent : symbol -> #t

  (define-record-type site
    (fields id binder kind home))

  (define-record-type escape-table
    (fields pt sites esc known tailent))

  (define (pt-ref tbl x)
    (let ([h (escape-table-pt tbl)])
      (if (hashtable-contains? h x) (hashtable-ref h x #f) 'unknown)))

  (define (pts-join a b)
    (cond [(eq? a 'unknown) 'unknown]
          [(eq? b 'unknown) 'unknown]
          [else (let loop ([b b] [acc a])
                  (cond [(null? b) acc]
                        [(memv (car b) acc) (loop (cdr b) acc)]
                        [else (loop (cdr b) (cons (car b) acc))]))]))

  ;; --- which primitives allocate, and which leak ----------------------------
  ;;
  ;; The same three tables `alias.ss` states, for the same reason: the default
  ;; decides between precision and a wrong answer, so it is written down rather
  ;; than left to a fall-through.

  (define (allocator-kind pr)
    (case pr
      [(make-vector) 'vector]
      [(make-flvector) 'flvector]
      [(cons) 'pair]
      [else #f]))

  (define (reference-reader? pr) (memq pr '(car cdr vector-ref)))

  ;; Operand positions whose value is stored into a heap object. The stored
  ;; VALUE escapes; the container does not escape by being written to.
  (define (stores-into-heap pr)
    (case pr
      [(vector-set!) '(2)]
      [(flvector-set!) '(2)]
      [(cons) '(0 1)]
      [(make-vector) '(1)]
      [else '()]))

  ;; --- pre-pass -------------------------------------------------------------
  ;;
  ;; Two syntactic facts, both needed before the escape walk can start.
  ;;
  ;; `known`: bound exactly once, bound to a lambda, and never appearing except
  ;; as the operator of a call. The last condition is what lets us enumerate the
  ;; call sites.
  ;;
  ;; `tailent`: reached by a `tailcall` from somewhere other than itself. See
  ;; the header. This is why the scan has to carry the enclosing procedure name
  ;; rather than just walking the tree.

  (define (scan-procs e)
    (let ([binds (make-eq-hashtable)]
          [lam (make-eq-hashtable)]
          [nonop (make-eq-hashtable)]
          [tailent (make-eq-hashtable)])
      (define (bind! x) (hashtable-update! binds x (lambda (n) (+ n 1)) 0))
      (define (use! x) (hashtable-set! nonop x #t))
      (define (use*! x*) (for-each use! x*))
      (define (tail-enter! f cur)
        ;; A self tail call replaces the procedure's OWN frame. Nothing it reads
        ;; from an enclosing scope lives there, so it is not a cross-frame
        ;; hazard and marking it would cost every loop its analysis.
        (unless (eq? f cur) (hashtable-set! tailent f #t)))
      (define (Expr e cur)
        (nanopass-case (Lanf Expr) e
          [,x (use! x)]
          [(quote ,d) (void)]
          [(if ,x ,e0 ,e1) (use! x) (Expr e0 cur) (Expr e1 cur)]
          [(seq ,e0 ,e1) (Expr e0 cur) (Expr e1 cur)]
          [(let ([,x ,se]) ,body)
           (bind! x)
           (nanopass-case (Lanf SimpleExpr) se
             [(lambda (,x1* ...) ,body1)
              (hashtable-set! lam x x1*) (for-each bind! x1*) (Expr body1 x)]
             [else (SimpleExpr se cur)])
           (Expr body cur)]
          [(tailcall ,x ,x* ...) (tail-enter! x cur) (use*! x*)]
          [(lambda (,x* ...) ,body) (for-each bind! x*) (Expr body cur)]
          [(letrec ([,x* ,e*] ...) ,body)
           (for-each bind! x*)
           (for-each (lambda (nm rhs)
                       (nanopass-case (Lanf Expr) rhs
                         [(lambda (,x1* ...) ,body1)
                          (hashtable-set! lam nm x1*)
                          (for-each bind! x1*) (Expr body1 nm)]
                         [else (Expr rhs cur)]))
                     x* e*)
           (Expr body cur)]
          [(set! ,x ,e) (use! x) (Expr e cur)]
          [(declare ([,x* ,prem*] ...) ,body) (use*! x*) (Expr body cur)]
          [(declare-distinct (,x* ...) ,body) (use*! x*) (Expr body cur)]
          [(policy ([,pn* ,b*] ...) ,body) (Expr body cur)]
          [else (void)]))
      (define (SimpleExpr se cur)
        (nanopass-case (Lanf SimpleExpr) se
          [,x (use! x)]
          [(quote ,d) (void)]
          [(lambda (,x* ...) ,body) (for-each bind! x*) (Expr body cur)]
          [(call ,x ,x* ...) (use*! x*)]
          [(primcall ,pr ([,pn* ,c*] ...) ,x* ...) (use*! x*)]
          [else (void)]))
      (Expr e 'top)
      (let ([known (make-eq-hashtable)])
        (vector-for-each
         (lambda (nm)
           (when (and (= 1 (hashtable-ref binds nm 0))
                      (not (hashtable-ref nonop nm #f)))
             (hashtable-set! known nm (hashtable-ref lam nm '()))))
         (hashtable-keys lam))
        (values known tailent))))

  ;; --- the analysis ---------------------------------------------------------
  ;;
  ;; Flow-insensitive and run to a fixpoint, for the same reasons as `alias.ss`:
  ;; a parameter's points-to set depends on call sites that may be walked after
  ;; the body, and both maps only grow.

  (define fixpoint-cap 40)

  (define (escape-analyze e)
    (let*-values ([(known tailent) (scan-procs e)])
      (let ([pt (make-eq-hashtable)]
            [sites (make-eqv-hashtable)]
            [esc (make-eqv-hashtable)]
            [counter 0]
            [anon 0])

        (define (get x) (if (hashtable-contains? pt x) (hashtable-ref pt x #f) 'unknown))
        (define (get-or-bottom x) (if (hashtable-contains? pt x) (hashtable-ref pt x #f) '()))
        (define (put! x v) (hashtable-set! pt x (pts-join (get-or-bottom x) v)))

        (define (escape-site! s why)
          (let ([rs (hashtable-ref esc s '())])
            (unless (memq why rs) (hashtable-set! esc s (cons why rs)))))

        (define (escape-pts! v why)
          (unless (eq? v 'unknown)
            (for-each (lambda (s) (escape-site! s why)) v)))

        (define (escape-var! x why) (escape-pts! (get x) why))

        (define (tail-entered? f) (and (hashtable-ref tailent f #f) #t))

        ;; EVERY variable occurrence goes through here, and this is where the
        ;; frame reasoning lives. A reference to a site homed in another frame
        ;; is only safe while that frame is still underneath us on the stack.
        ;; It is not, in exactly two situations: we are inside a closure whose
        ;; extent we cannot account for, or we are inside a procedure that was
        ;; entered by a tail call, which popped the frame we would be pointing
        ;; into. A reference to a site homed HERE is always fine.
        (define (ref! x escaping? cur)
          (let ([v (get x)])
            (unless (eq? v 'unknown)
              (for-each
               (lambda (s)
                 (let ([h (hashtable-ref sites s #f)])
                   (unless (and h (eq? (site-home h) cur))
                     (cond [escaping? (escape-site! s 'captured)]
                           [(tail-entered? cur) (escape-site! s 'cross-frame)]
                           [else (void)]))))
               v))))

        (define (fresh-site! binder kind home)
          (set! counter (+ counter 1))
          (hashtable-set! sites counter (make-site counter binder kind home))
          counter)

        (define (fresh-anon!)
          (set! anon (+ anon 1))
          (string->symbol (string-append "anon-lambda." (number->string anon))))

        ;; A call that keeps our frame alive underneath it. Known callee with a
        ;; matching arity: the actuals flow into the formals and nothing
        ;; escapes, which is the dynamic-extent case. Anything else: the
        ;; arguments are now reachable from code we cannot enumerate.
        (define (call! f a* escaping? cur tail?)
          (ref! f escaping? cur)
          (for-each (lambda (a) (ref! a escaping? cur)) a*)
          ;; The frame is gone before the callee runs. Known or not.
          (when tail? (for-each (lambda (a) (escape-var! a 'tail-call)) a*))
          (let ([params (hashtable-ref known f #f)])
            (if (and params (= (length params) (length a*)))
                (for-each (lambda (p a) (put! p (get a))) params a*)
                (for-each (lambda (a) (escape-var! a 'unknown-call)) a*))))

        (define (walk e tail? escaping? cur)
          (nanopass-case (Lanf Expr) e
            [,x (ref! x escaping? cur)
                ;; Tail position of a procedure body IS the return. The value
                ;; outlives the frame by definition.
                (when tail? (escape-var! x 'returned))]
            [(quote ,d) (void)]
            [(if ,x ,e0 ,e1)
             ;; The test is consumed here; only the arms are in tail position.
             (ref! x escaping? cur)
             (walk e0 tail? escaping? cur)
             (walk e1 tail? escaping? cur)]
            [(seq ,e0 ,e1) (walk e0 #f escaping? cur) (walk e1 tail? escaping? cur)]
            [(let ([,x ,se]) ,body)
             (put! x (walk-se se x escaping? cur))
             (walk body tail? escaping? cur)]
            [(tailcall ,x ,x* ...) (call! x x* escaping? cur #t)]
            ;; A lambda in Expr position has no name to key call sites on, so
            ;; its parameters stay top and its body is walked as escaping.
            [(lambda (,x* ...) ,body) (walk body #t #t (fresh-anon!))]
            [(letrec ([,x* ,e*] ...) ,body)
             (for-each (lambda (nm rhs)
                         (nanopass-case (Lanf Expr) rhs
                           [(lambda (,x1* ...) ,body1)
                            ;; Same treatment a `let`-bound lambda gets in
                            ;; walk-se. A letrec-bound procedure is still a
                            ;; closure allocation and still gets a site;
                            ;; giving it one only in the `let` case would make
                            ;; every loop in the language invisible to this
                            ;; pass, since loops are letrec.
                            (let* ([out? (not (hashtable-contains? known nm))]
                                   [s (fresh-site! nm 'closure cur)])
                              (put! nm (list s))
                              (walk body1 #t (or escaping? out?) nm)
                              (when out? (escape-site! s 'closure))
                              (when (tail-entered? nm) (escape-site! s 'tail-call)))]
                           [else (walk rhs #f escaping? cur)]))
                       x* e*)
             (walk body tail? escaping? cur)]
            ;; Mutation, BEFORE assignment conversion. The value flows into a
            ;; variable whose reads we are not tracking flow-sensitively, so it
            ;; escapes. This is not the interesting case and it is not meant to
            ;; be: once assignment conversion has run, the mutation is a
            ;; `vector-set!` into a one-slot box, the box is an ordinary
            ;; allocation site, and its extent is decided by the rules above.
            ;; That is the case the header claims we buy back.
            [(set! ,x ,e)
             (walk e #f escaping? cur)
             (nanopass-case (Lanf Expr) e
               [,x1 (escape-var! x1 'assigned) (put! x (get x1))]
               [else (void)])]
            [(declare ([,x* ,prem*] ...) ,body)
             (for-each (lambda (x) (ref! x escaping? cur)) x*)
             (walk body tail? escaping? cur)]
            [(declare-distinct (,x* ...) ,body)
             (for-each (lambda (x) (ref! x escaping? cur)) x*)
             (walk body tail? escaping? cur)]
            [(policy ([,pn* ,b*] ...) ,body) (walk body tail? escaping? cur)]
            [else (void)]))

        ;; Returns the points-to set of the variable this SimpleExpr binds. A
        ;; SimpleExpr is never in tail position: its value is being named.
        (define (walk-se se binder escaping? cur)
          (nanopass-case (Lanf SimpleExpr) se
            [,x (ref! x escaping? cur) (get x)]
            [(quote ,d) (if (string? d) 'unknown '())]
            [(lambda (,x* ...) ,body)
             (let* ([out? (not (hashtable-contains? known binder))]
                    [s (fresh-site! binder 'closure cur)])
               (walk body #t (or escaping? out?) binder)
               ;; A closure is an allocation. Keep's measurement of the closure
               ;; half is 3.6%, and it is available for exactly the procedures
               ;; we can enumerate the uses of. A procedure entered by a tail
               ;; call is not one of them: the tail call popped the frame its
               ;; closure would have been living in.
               (when out? (escape-site! s 'closure))
               (when (tail-entered? binder) (escape-site! s 'tail-call))
               (list s))]
            [(call ,x ,x* ...) (call! x x* escaping? cur #f) 'unknown]
            [(primcall ,pr ([,pn* ,c*] ...) ,x* ...)
             (for-each (lambda (a) (ref! a escaping? cur)) x*)
             (let ([stored (stores-into-heap pr)])
               (let loop ([i 0] [a* x*])
                 (unless (null? a*)
                   (when (memv i stored) (escape-var! (car a*) 'heap-store))
                   (loop (+ i 1) (cdr a*)))))
             (let ([k (allocator-kind pr)])
               (cond [k (list (fresh-site! binder k cur))]
                     [(reference-reader? pr) 'unknown]
                     [else '()]))]
            [else 'unknown]))

        ;; Monotone: strictly increases until the fixpoint.
        (define (signature)
          (let ([n 0])
            (vector-for-each
             (lambda (x)
               (let ([v (hashtable-ref pt x #f)])
                 (set! n (+ n 1 (if (eq? v 'unknown) 1000000 (length v))))))
             (hashtable-keys pt))
            (vector-for-each
             (lambda (s) (set! n (+ n (* 7 (length (hashtable-ref esc s '()))))))
             (hashtable-keys esc))
            n))

        (let loop ([i 0] [prev -1])
          (cond
           [(> i fixpoint-cap)
            ;; The termination argument says we cannot get here. If we do, it is
            ;; wrong, and the only safe response is a table that escapes
            ;; everything: no site is stack-allocated and no frame is corrupted.
            (let ([all (make-eqv-hashtable)])
              (vector-for-each
               (lambda (s) (hashtable-set! all s '(fixpoint-gave-up)))
               (hashtable-keys sites))
              (make-escape-table (make-eq-hashtable) sites all known tailent))]
           [else
            (set! counter 0)
            (set! anon 0)
            (walk e #t #f 'top)
            (let ([s (signature)])
              (if (= s prev)
                  (make-escape-table pt sites esc known tailent)
                  (loop (+ i 1) s)))])))))

  ;; --- the query ------------------------------------------------------------

  (define (escape-points-to tbl x) (pt-ref tbl x))

  (define (escape-sites tbl)
    (let ([h (escape-table-sites tbl)])
      (map (lambda (k) (hashtable-ref h k #f))
           (sort < (vector->list (hashtable-keys h))))))

  ;; Look a site up by the binder it was allocated into. Every fixture in the
  ;; tests names its allocations, so this is how a test asks about one without
  ;; knowing the numbering.
  (define (escape-site-of tbl binder)
    (let loop ([ss (escape-sites tbl)])
      (cond [(null? ss) #f]
            [(eq? (site-binder (car ss)) binder) (car ss)]
            [else (loop (cdr ss))])))

  (define (escape-site-escapes? tbl s)
    (pair? (hashtable-ref (escape-table-esc tbl) (site-id* s) '())))

  (define (escape-site-reasons tbl s)
    (hashtable-ref (escape-table-esc tbl) (site-id* s) '()))

  ;; Accept a site record or a bare id, so a caller holding either can ask.
  (define (site-id* s) (if (site? s) (site-id s) s))

  ;; A variable escapes when anything it can denote escapes. An unknown
  ;; points-to set is top and therefore escapes: we cannot name what it holds,
  ;; so we cannot promise the frame outlives it.
  (define (escape-escapes? tbl x)
    (let ([v (pt-ref tbl x)])
      (or (eq? v 'unknown)
          (exists (lambda (s) (pair? (hashtable-ref (escape-table-esc tbl) s '()))) v))))

  (define (escape-reasons tbl x)
    (let ([v (pt-ref tbl x)])
      (if (eq? v 'unknown)
          '(unknown)
          (let loop ([v v] [acc '()])
            (if (null? v)
                acc
                (loop (cdr v)
                      (let merge ([rs (hashtable-ref (escape-table-esc tbl) (car v) '())]
                                  [acc acc])
                        (cond [(null? rs) acc]
                              [(memq (car rs) acc) (merge (cdr rs) acc)]
                              [else (merge (cdr rs) (cons (car rs) acc))]))))))))

  ;; THE output. Everything a later pass may put in a frame instead of the heap.
  (define (escape-stack-allocatable tbl)
    (let loop ([ss (escape-sites tbl)] [acc '()])
      (cond [(null? ss) (reverse acc)]
            [(escape-site-escapes? tbl (car ss)) (loop (cdr ss) acc)]
            [else (loop (cdr ss) (cons (car ss) acc))])))

  (define (escape-known-procs tbl)
    (sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
          (vector->list (hashtable-keys (escape-table-known tbl)))))

  (define (escape-tail-entered? tbl f)
    (and (hashtable-ref (escape-table-tailent tbl) f #f) #t))
  )
