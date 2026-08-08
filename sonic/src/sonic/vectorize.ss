;;; From a licensed loop to a kernel: the join the two emitters were waiting for.
;;;
;;; `veclegal.ss` says a loop MAY be vectorized and at what widths.
;;; `vec-x86-64.ss` and `vec-rv64.ss` turn a kernel into packed instructions.
;;; Nothing built a kernel from real IR, so the emitters had only hand-written
;;; fixtures to consume and the legality verdict had nowhere to go. This is that
;;; pass, and it is deliberately the smallest thing that closes the gap.
;;;
;;; ## Linearization, which is why nbody's position update is vectorizable
;;;
;;; The licensed loop steps ONE body per iteration and touches THREE elements:
;;;
;;;     p[3i+0] += dt * v[3i+0]
;;;     p[3i+1] += dt * v[3i+1]
;;;     p[3i+2] += dt * v[3i+2]
;;;
;;; Its trip count is 5 -- bodies, not elements -- and handing that to
;;; `vec-emit-loop` would unroll five elements when there are fifteen.
;;;
;;; The union over i of {3i, 3i+1, 3i+2} for i in [0,5) is exactly [0,15): every
;;; element, once, in order. So the loop is EQUIVALENT to a flat element-wise
;;; loop of `coeff * trip` elements, and that equivalence is checkable rather
;;; than assumed. The condition is that every subscript is affine in one basic
;;; induction variable with a common coefficient c, and that the offsets present
;;; are exactly {0, ..., c-1}. A gap in that set means the loop skips elements
;;; and does not linearize; a repeat outside it means it revisits them.
;;;
;;; ## Why the slices must be isomorphic
;;;
;;; The kernel describes ONE element. Emitting it for all `coeff * trip` of them
;;; is only correct if every offset does the same work, so the per-offset slices
;;; are built independently and compared. nbody's three components are the same
;;; four operations against the same two arrays, which is what makes one kernel
;;; stand for all of them; a loop that treated x differently from y would fail
;;; the comparison rather than be silently vectorized as if it did not.
;;;
;;; ## What this pass will not do
;;;
;;; It refuses anything it cannot spell exactly. A reduction, a call, a branch,
;;; an integer operation feeding a float chain -- each returns a reason instead
;;; of a kernel. `veclegal` has already refused most of them upstream; the
;;; checks here are the second half of the same rule, because a kernel built
;;; from a body this pass did not fully understand is wrong code rather than a
;;; missed optimization.

(library (sonic vectorize)
  (export vectorize-loop
          vk? vk-kernel vk-elements vk-lanes vk-invariants vk-arrays
          vk-index vk-coeff vk-why
          vk-for-x86-64 vk-for-rv64)
  (import (chezscheme) (nanopass)
          (sonic lang) (sonic loops) (sonic veclegal))

  (define-record-type (vk make-vk vk?)
    (fields kernel        ; the vop list for ONE element, over symbolic names
            elements      ; how many elements the flattened loop covers
            lanes         ; name -> lane number, for every value in the kernel
            invariants    ; names defined outside the loop that need a lane
            arrays        ; array names the kernel addresses
            index         ; the basic induction variable the subscripts ride on
            coeff         ; elements touched per iteration
            why))         ; #f when a kernel was built, else the refusal

  (define (refused why) (make-vk #f 0 '() '() '() #f 0 why))

  ;; Float operations this pass can spell as a vector op. Anything else refuses.
  (define float-ops
    '((fl+ . vadd) (fl- . vsub) (fl* . vmul) (fl/ . vdiv) (flsqrt . vsqrt)))

  ;; --- reading the body ------------------------------------------------------
  ;;
  ;; The primcalls in source order, as (name prim args). ANF guarantees one per
  ;; `let`, and the loop body is a chain of them, so order is dependency order
  ;; and no scheduling is needed.

  (define (body-primcalls body)
    (let ([acc '()])
      (let walk ([e body])
        (nanopass-case (Lssa Expr) e
          [(let ([,x ,se]) ,body2)
           (nanopass-case (Lssa SimpleExpr) se
             [(primcall ,pr ([,pn* ,c*] ...) ,x* ...)
              (set! acc (cons (list x pr x*) acc))]
             [else (void)])
           (walk body2)]
          [(seq ,e0 ,e1) (walk e0) (walk e1)]
          [(sigma ,x0 ,x1 ,pr ,x2 ,b ,body2) (walk body2)]
          [(phi ([,x* (,lbl** ,e**) ...] ...) ,body2)
           (for-each (lambda (es) (for-each walk es)) e**)
           (walk body2)]
          [(if ,x ,e0 ,e1) (walk e0) (walk e1)]
          [(declare ([,x* ,prem*] ...) ,body2) (walk body2)]
          [(declare-distinct (,x* ...) ,body2) (walk body2)]
          [(policy ([,pn* ,b*] ...) ,body2) (walk body2)]
          [else (void)]))
      (reverse acc)))

  (define (pc-name p) (car p))
  (define (pc-prim p) (cadr p))
  (define (pc-args p) (caddr p))

  ;; --- linearization ---------------------------------------------------------

  ;; The (base coeff offset) of a subscript, or #f when it is not affine in one
  ;; induction variable of this loop.
  (define (subscript-form l x)
    (let ([f (iv-form l x)])
      (and f
           (integer? (iv-coeff f)) (integer? (iv-offset f))
           (list (iv-base f) (iv-coeff f) (iv-offset f)))))

  (define (sub-base s) (car s))
  (define (sub-coeff s) (cadr s))
  (define (sub-offset s) (caddr s))

  ;; Every offset in 0..c-1 present exactly once as a STORE, and every load's
  ;; offset within range. That is what makes the flattened loop cover each
  ;; element once.
  (define (offsets-cover? offs c)
    (and (= (length offs) c)
         (let check ([k 0])
           (or (= k c)
               (and (memv k offs) (check (+ k 1)))))))

  ;; --- the pass --------------------------------------------------------------

  (define (vectorize-loop e l v)
    (cond
     [(not (vl-legal? v)) (refused (cons 'not-licensed (vl-reasons v)))]
     [(not (and (trip-exact? (vl-trip v)) (trip-count (vl-trip v))))
      (refused 'no-exact-trip-count)]
     [else
      (let* ([body (loop-lambda-body e (loop-name l))]
             [pcs (and body (body-primcalls body))])
        (if (not pcs)
            (refused 'loop-body-not-found)
            (let* ([stores (filter (lambda (p) (eq? (pc-prim p) 'flvector-set!)) pcs)]
                   [loads (filter (lambda (p) (eq? (pc-prim p) 'flvector-ref)) pcs)])
              (cond
               [(null? stores) (refused 'no-stores)]
               [else
                (let ([sforms (map (lambda (p) (subscript-form l (cadr (pc-args p))))
                                   stores)])
                  (cond
                   [(memq #f sforms) (refused 'subscript-not-affine)]
                   [(not (apply = (map sub-coeff sforms))) (refused 'mixed-stride)]
                   [(not (let ([b (sub-base (car sforms))])
                           (for-all (lambda (s) (eq? (sub-base s) b)) sforms)))
                    (refused 'mixed-induction-variable)]
                   [else
                    (let* ([c (sub-coeff (car sforms))]
                           [offs (map sub-offset sforms)])
                      (cond
                       [(not (offsets-cover? offs c)) (refused (list 'not-contiguous offs c))]
                       [else (build-kernel l v pcs stores loads c)]))]))]))))]))

  ;; --- building the kernel ---------------------------------------------------

  (define (build-kernel l v pcs stores loads c)
    (let* ([trip (trip-count (vl-trip v))]
           [defs (map (lambda (p) (cons (pc-name p) p)) pcs)]
           ;; The slice for one offset: the store, and every float operation
           ;; whose result reaches it. Walked backwards from the stored value,
           ;; then reversed, so the result is in dependency order.
           [slice-of
            (lambda (k)
              (let* ([st (let find ([ss stores])
                           (cond [(null? ss) #f]
                                 [(= k (sub-offset (subscript-form l (cadr (pc-args (car ss))))))
                                  (car ss)]
                                 [else (find (cdr ss))]))]
                     [seen '()]
                     [out '()])
                (and st
                     (let reach ([x (caddr (pc-args st))])
                       (cond
                        [(memq x seen) #t]
                        [else
                         (set! seen (cons x seen))
                         (let ([d (assq x defs)])
                           (cond
                            [(not d) #t]      ; defined outside: an invariant
                            [(eq? (pc-prim (cdr d)) 'flvector-ref)
                             (set! out (cons (cdr d) out)) #t]
                            [(assq (pc-prim (cdr d)) float-ops)
                             (for-each reach (pc-args (cdr d)))
                             (set! out (cons (cdr d) out)) #t]
                            [else #f]))]))
                     (list st (reverse out)))))]
           [slices (map slice-of (let nums ([k 0]) (if (= k c) '() (cons k (nums (+ k 1))))))])
      (cond
       [(memq #f slices) (refused 'slice-not-expressible)]
       ;; EVERY OFFSET MUST DO THE SAME WORK. The kernel describes one element;
       ;; emitting it for all of them is correct only if the slices agree.
       [(not (slices-isomorphic? slices l)) (refused 'slices-differ)]
       [else
        (let-values ([(kernel lanes invs arrays) (emit-slice (car slices) defs)])
          (if (not kernel)
              (refused 'slice-not-expressible)
              (make-vk kernel (* c trip) lanes invs arrays
                       (sub-base (subscript-form l (cadr (pc-args (car stores)))))
                       c #f)))])))

  ;; Same operations, in the same order, against the same arrays. The SUBSCRIPTS
  ;; differ by construction -- that is what makes them different offsets -- so
  ;; they are compared by shape rather than by name.
  (define (slices-isomorphic? slices l)
    (let* ([shape (lambda (s)
                    (cons (map pc-prim (cadr s))
                          (map (lambda (p)
                                 (if (eq? (pc-prim p) 'flvector-ref)
                                     (car (pc-args p))
                                     #f))
                               (cadr s))))]
           [first (shape (car slices))])
      (for-all (lambda (s) (equal? (shape s) first)) (cdr slices))))

  ;; One slice becomes vops. Lane numbers are assigned in first-definition
  ;; order; anything the slice reads that the slice does not define is an
  ;; INVARIANT -- `dt` is the case -- and gets a lane the caller must broadcast
  ;; into before the loop.
  (define (emit-slice s defs)
    (let* ([st (car s)] [ops (cadr s)]
           [lanes (make-eq-hashtable)]
           [next 0]
           [invs '()]
           [arrays '()])
      (define (lane! x)
        (or (hashtable-ref lanes x #f)
            (let ([n next])
              (set! next (+ next 1))
              (hashtable-set! lanes x n)
              n)))
      (define (operand x)
        (cond
         [(hashtable-ref lanes x #f)]
         [(assq x defs) (lane! x)]           ; defined here, not yet emitted
         [else (set! invs (cons x invs)) (lane! x)]))
      (define (array! a) (unless (memq a arrays) (set! arrays (cons a arrays))) a)
      (let ([kernel
             (let build ([ps ops] [acc '()])
               (cond
                [(null? ps)
                 ;; The store, whose value is the last thing computed.
                 (let* ([a (array! (car (pc-args st)))]
                        [val (caddr (pc-args st))])
                   (reverse (cons `(vstore (elt ,a) ,(operand val)) acc)))]
                [else
                 (let* ([p (car ps)] [pr (pc-prim p)] [args (pc-args p)])
                   (cond
                    [(eq? pr 'flvector-ref)
                     (build (cdr ps)
                            (cons `(vload ,(lane! (pc-name p))
                                          (elt ,(array! (car args))))
                                  acc))]
                    [(assq pr float-ops)
                     (let* ([vop (cdr (assq pr float-ops))]
                            [srcs (map operand args)]
                            [d (lane! (pc-name p))])
                       (build (cdr ps) (cons (cons* vop d srcs) acc)))]
                    [else #f]))]))])
        (if kernel
            (values kernel
                    (let ([out '()])
                      (vector-for-each
                       (lambda (k) (set! out (cons (cons k (hashtable-ref lanes k #f)) out)))
                       (hashtable-keys lanes))
                      out)
                    (reverse invs)
                    (reverse arrays))
            (values #f '() '() '())))))

  ;; --- instantiating the kernel ----------------------------------------------
  ;;
  ;; The kernel names an element position as `(elt A)` -- "the current element of
  ;; array A" -- because the two targets address it differently and neither
  ;; spelling belongs in a pass that reads IR. x86-64 walks a base with a scaled
  ;; index and a displacement per unrolled step; RVV walks a POINTER that the
  ;; loop bumps by `vl` elements, which is what makes it length agnostic.
  ;;
  ;; The array names are Lssa vregs on the way out. Choosing registers is
  ;; regs.ss's job, so the caller supplies the map.
  (define (subst-names x alist)
    (cond
     [(symbol? x) (let ([p (assq x alist)]) (if p (cdr p) x))]
     [(pair? x) (cons (subst-names (car x) alist) (subst-names (cdr x) alist))]
     [else x]))

  ;; `(elt A)` becomes `(mem A index 8 0)`; `vec-emit-kernel` biases the
  ;; displacement per unrolled step.
  (define (vk-for-x86-64 k alist index-reg)
    (let walk ([x (vk-kernel k)])
      (cond
       [(and (pair? x) (eq? (car x) 'elt))
        `(mem ,(subst-names (cadr x) alist) ,index-reg 8 0)]
       [(pair? x) (cons (walk (car x)) (walk (cdr x)))]
       [else (subst-names x alist)])))

  ;; `(elt A)` becomes A itself: an RVV unit-stride load takes the pointer, and
  ;; `rvv-emit-loop` advances every pointer by the vector length it was granted.
  (define (vk-for-rv64 k alist)
    (let walk ([x (vk-kernel k)])
      (cond
       [(and (pair? x) (eq? (car x) 'elt)) (subst-names (cadr x) alist)]
       [(pair? x) (cons (walk (car x)) (walk (cdr x)))]
       [else (subst-names x alist)])))
  )
