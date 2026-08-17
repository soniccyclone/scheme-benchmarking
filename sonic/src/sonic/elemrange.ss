;;; What a vector's ELEMENTS can hold.
;;;
;;; shapes.ss connects a vector to its allocation and so supplies its LENGTH.
;;; This supplies the other half: a bound on the values stored in it. The
;;; difference matters because an element is frequently used as an index --
;;;
;;;     (let ((k (vector-ref perm 0)))    ; k is what, exactly?
;;;       ... (vector-ref perm k) ...)
;;;
;;; -- and with no fact about perm's contents, `k` is top, so every access
;;; derived from it keeps its check and no loop it bounds has a trip count.
;;; That single unknown is what stopped fannkuch's last four bounds checks, and
;;; it is also the premise a full unroll needs (LEDGER D41).
;;;
;;; ## This file computes the PRECONDITION, not the range
;;;
;;; The range itself cannot be computed here, because the values written are
;;; things like `init`'s induction variable, whose interval comes from the
;;; interval domain -- which runs later and consults these facts. So the range
;;; is computed where that circularity already has an answer: inside elide's
;;; existing fixpoint in driver.ss, which widens and narrows exactly like the
;;; argument intervals do.
;;;
;;; What this file answers is the question that fixpoint cannot: WHICH VECTORS
;;; MAY BE TRACKED AT ALL, and what their elements hold before anyone writes.
;;;
;;; ## Escape, and why it is the whole soundness argument
;;;
;;; The fixpoint learns a vector's element range by joining every `vector-set!`
;;; that names it. That is only a bound on the contents if there is no OTHER
;;; way to write them. A vector passed as an argument is written through a
;;; parameter, under a name this analysis never connects to the global, and the
;;; join then misses that write and claims a range the program violates. It
;;; would be a wrong-answer bug of the worst kind: silent, and only on programs
;;; whose vectors are shared.
;;;
;;; So a vector is TRACKED only if every occurrence of its name in the whole
;;; program is the vector operand of `vector-ref`, `vector-set!` or
;;; `vector-length`. Any other occurrence -- a call argument, a return, being
;;; stored into another vector -- drops it. The rule is deliberately syntactic
;;; and deliberately crude: it is checked by counting occurrences rather than
;;; by reasoning about them, so there is no path where a use is examined and
;;; wrongly judged harmless.
;;;
;;; This is strictly weaker than escape.ss, which answers a different question
;;; (does this allocation outlive its frame). Sharing that machinery would mean
;;; making one analysis serve two definitions of escape, and the definitions do
;;; not agree: a vector stored into a global structure has not escaped for GC
;;; purposes and has certainly escaped for this one.
;;;
;;; ## The sharp edge, measured
;;;
;;; The rule is strict enough that an ordinary Scheme idiom defeats it. Binding
;;; a global to a local for speed --
;;;
;;;     (define (flip-prefix k)
;;;       (let ((p perm))                    ; perm in a VALUE position
;;;         ... (vector-ref p i) ...))
;;;
;;; -- puts `perm` somewhere other than a vector operand, so it stops being
;;; tracked and every bounds check on it returns. Measured on fannkuch at
;;; n=11 while trying to hand-probe loop-invariant code motion: 27.161G
;;; instructions became 35.974G, a third more, and the cycles went with it.
;;; The answer stayed correct; the analysis simply gave up.
;;;
;;; That is the right trade -- the alternative is following the value through
;;; the binding, and then through a parameter, and the soundness argument stops
;;; being a syntactic one anybody can check. But it means a source-level
;;; transformation that renames a tracked vector pays for it, while a pass
;;; working below the name level -- hoisting the global cell's LOAD at Lmach,
;;; after names are gone -- does not. Those two are easy to confuse because
;;; they are described the same way.
;;;
;;; ## The initial contents count
;;;
;;; `(make-vector 7 0)` puts a 0 in every slot before any `vector-set!` runs,
;;; so the fill is part of the join and not a detail. Omitting it would claim
;;; `perm`'s elements are whatever gets stored later, which is false for every
;;; slot the program has not reached yet -- and fannkuch reads `perm[0]` on a
;;; path where `copy-perm` has written it, but nothing in the analysis knows
;;; that. A fill that is not a known constant drops the vector, because "filled
;;; with something" bounds nothing.

(library (sonic elemrange)
  (export trackable-vectors)
  (import (chezscheme) (sonic order))

  ;; The three primitives that may name a tracked vector. Position 0 of the
  ;; argument list is the vector; the remaining arguments are ordinary values
  ;; and are walked normally.
  (define vector-ops '(vector-ref vector-set! vector-length))

  ;; -> ((name . fill) ...), sorted, where `fill` is the exact integer every
  ;; slot holds before the program writes one.
  ;;
  ;; `form` is the unparsed Lssa program, the same datum shapes.ss walks.
  (define (trackable-vectors form)
    (unless (and (pair? form) (eq? (car form) 'top))
      (error 'trackable-vectors "not a top-level program" form))

    (let ((consts (make-eq-hashtable))    ; name -> exact integer
          (allocs (make-eq-hashtable))    ; name -> fill integer, or 'unknown
          (escaped (make-eq-hashtable)))  ; name -> #t

      ;; --- the binding that a name's value came from -------------------------
      ;;
      ;; ANF names every operand, so `(define perm (make-vector 7 0))` is a let
      ;; chain ending in the temporary that holds the result. shapes.ss follows
      ;; the same chain for the same reason; the tail forms are kept in step
      ;; with it deliberately, and a form missing from either list costs a fact
      ;; and never a wrong one.
      (define (tail-name e)
        (cond
         ((symbol? e) e)
         ((not (pair? e)) #f)
         (else
          (case (car e)
            ((let seq letrec phi declare declare-distinct policy) (tail-name (caddr e)))
            ((sigma) (tail-name (list-ref e 6)))
            (else #f)))))

      (define (const-of x) (and (symbol? x) (hashtable-ref consts x #f)))

      ;; `(primcall make-vector () size fill)` -- the fill is argument 1.
      ;; make-flvector is NOT here: its elements are flonums, the domain in play
      ;; is the integer interval one, and an flonum range would need its own.
      (define (alloc-fill se)
        (and (pair? se) (eq? (car se) 'primcall) (eq? (cadr se) 'make-vector)
             (let ((args (cdddr se)))
               (if (>= (length args) 2)
                   (or (const-of (cadr args)) 'unknown)
                   'unknown))))

      (define (note-binding! x se)
        (cond
         ((and (pair? se) (eq? (car se) 'quote))
          (let ((d (cadr se)))
            (when (and (integer? d) (exact? d)) (hashtable-set! consts x d))))
         ((alloc-fill se) => (lambda (f) (hashtable-set! allocs x f)))
         (else
          (let ((src (tail-name se)))
            (when (and src (not (eq? src x)))
              (let ((c (hashtable-ref consts src #f))
                    (a (hashtable-ref allocs src #f)))
                (when c (hashtable-set! consts x c))
                (when a (hashtable-set! allocs x a))))))))

      (define (binding-value b)
        ;; Lssa spells a binding (x se); Lrepr adds a class slot.
        (if (= (length b) 3) (caddr b) (cadr b)))

      (define (collect!)
        (let walk ((x form))
          (when (pair? x)
            (case (car x)
              ((let) (let ((b (car (cadr x))))
                       (note-binding! (car b) (binding-value b))))
              ((top letrec)
               (for-each (lambda (b)
                           (let ((v (binding-value b)))
                             (unless (and (pair? v) (eq? (car v) 'lambda))
                               (note-binding! (car b) v))))
                         (cadr x))))
            (for-each walk x))))

      ;; --- escape ------------------------------------------------------------
      ;;
      ;; Every symbol occurrence that is not a binder and not a tracked
      ;; vector's appearance in the vector slot of a vector op is an escape.
      ;; Written as a walk that DECIDES what to skip, so anything unrecognised
      ;; falls through to the escaping case rather than to the safe one.
      (define (escape! x) (when (symbol? x) (hashtable-set! escaped x #t)))

      (define (walk-value x)
        (cond
         ((symbol? x) (escape! x))
         ((not (pair? x)) (void))
         (else
          (case (car x)
            ((quote) (void))
            ((primcall)
             ;; (primcall pr ([pn c] ...) arg ...)
             (let ((pr (cadr x)) (args (cdddr x)))
               (if (and (memq pr vector-ops) (pair? args))
                   ;; argument 0 names the vector and is NOT an escape; the
                   ;; index and the stored value are ordinary uses.
                   (for-each walk-value (cdr args))
                   (for-each walk-value args))))
            ((let)
             (let ((b (car (cadr x))))
               (walk-value (binding-value b))
               (walk-value (caddr x))))
            ((lambda) (walk-value (caddr x)))
            ;; SPLIT, because `top` and `letrec` do not have their body in the
            ;; same place. `(letrec ([x e] ...) body)` keeps it at caddr, but
            ;; `(top ([x e] ...) (extern ...) body)` has the EXTERN LIST there
            ;; and the body at cadddr. Walking them together walked `(display)`
            ;; and never the program, so every escape in the body was invisible
            ;; and the vector was tracked anyway.
            ;;
            ;; That is unsound in the one direction that matters: the fixpoint
            ;; then claims an element range the program can violate, and a check
            ;; that was needed gets discharged. This file's own header calls it
            ;; "a wrong-answer bug of the worst kind: silent, and only on
            ;; programs whose vectors are shared" -- which is what nbody is,
            ;; since its kernels take the vectors as parameters.
            ((letrec)
             (for-each (lambda (b) (walk-value (binding-value b))) (cadr x))
             (walk-value (caddr x)))
            ((top)
             (for-each (lambda (b) (walk-value (binding-value b))) (cadr x))
             (walk-value (cadddr x)))
            (else
             ;; Everything else -- call, tailcall, if, seq, phi, sigma, policy,
             ;; declare -- is walked with every element treated as a value. A
             ;; call's operator is a procedure name and marking it escaped is
             ;; harmless, because a procedure is never a tracked vector.
             (for-each walk-value (cdr x)))))))

      ;; Two sweeps before the escape walk, matching shapes.ss: a size or fill
      ;; may be bound after the allocation that uses it has already been walked
      ;; down another branch.
      (collect!)
      (collect!)
      (walk-value form)

      ;; --- emit --------------------------------------------------------------
      ;;
      ;; Sorted: these become compiler input and the compiler is required to be
      ;; deterministic (order.ss).
      (let loop ((ks (vector->list (sorted-keys allocs))) (out '()))
        (cond
         ((null? ks) (reverse out))
         (else
          (let ((nm (car ks)) (fill (hashtable-ref allocs (car ks) #f)))
            (loop (cdr ks)
                  (if (and (integer? fill) (not (hashtable-ref escaped nm #f)))
                      (cons (cons nm fill) out)
                      out))))))))
  )
