;;; Shapes: where a vector's LENGTH and a constant's VALUE come from.
;;;
;;; The interval domain could always discharge nbody's inner loop. It had the
;;; arithmetic -- i in [0,4], bi = 3i in [0,12], bi+2 in [2,14] against a length
;;; of 15 -- and none of the premises, so it kept 18 bounds checks in the hot
;;; loop and proved 50 of 227 overall. This pass supplies the two facts it was
;;; missing, and supplies them as FACTS about this program rather than as
;;; assumptions:
;;;
;;;   1. `(define n-bodies 5)` gives n-bodies the interval [5,5]. A top-level
;;;      binding with a literal initializer is a constant; the analysis was
;;;      reading every one of them as unknown, so every loop bound was opaque.
;;;
;;;   2. `(make-flvector 15 0.0)` gives its binding a length of 15. Nothing
;;;      connected a vector to the allocation that produced it, so
;;;      `flvector-length p` was [0, +inf) and no index against it was provable.
;;;
;;; ## Why it has to be interprocedural
;;;
;;; Knowing `pos` is 15 long is not enough. nbody's kernels take the vectors as
;;; PARAMETERS -- `(advance! pos vel mass)` -- so the fact has to cross the call
;;; boundary or it never reaches the loop that needs it. Every procedure here is
;;; top-level or letrec-bound and every call names it directly (closures are a
;;; later bead), so the argument in position i is known at every site and its
;;; shape is the parameter's.
;;;
;;; Where two call sites disagree the parameter has NO fact. That is the only
;;; sound answer: a length that holds on one path is not a length, and a bounds
;;; proof built on "usually 15" is not a proof.
;;;
;;; ## Why a fixpoint
;;;
;;; A loop is a letrec whose tailcall passes its own parameter back to itself,
;;; so the argument in position i IS the parameter in position i. One pass would
;;; ask for a fact still being computed. Facts are only ever added or dropped to
;;; unknown, and there are finitely many, so it settles -- and it is bounded
;;; anyway, because an argument for termination is not a guard.

(library (sonic shapes)
  (export shape-facts)
  (import (chezscheme) (sonic order))

  ;; -> a list of facts in `elide-program`'s vocabulary:
  ;;      (x flvector LEN) | (x vector LEN) | (x interval LO HI)
  (define (shape-facts form)
    (unless (and (pair? form) (eq? (car form) 'top))
      (error 'shape-facts "not a top-level program" form))

    (let ((consts (make-eq-hashtable))   ; name -> exact integer
          (shapes (make-eq-hashtable))   ; name -> (kind . len-or-#f)
          (params (make-eq-hashtable))   ; procedure -> (param ...)
          (sites  '()))                  ; (procedure . (arg ...))

      ;; --- collect ---
      (define (note-const! x d)
        (when (and (integer? d) (exact? d)) (hashtable-set! consts x d)))

      ;; The size argument of an allocation, if it is known. Taken from the
      ;; constant table rather than requiring a literal in the call, so a size
      ;; bound through a `let` -- which ANF guarantees, since it names every
      ;; operand -- still counts.
      (define (alloc-shape se)
        (and (pair? se) (eq? (car se) 'primcall)
             (memq (cadr se) '(make-flvector make-vector))
             (let ((args (cdddr se)))
               (and (pair? args)
                    (cons (if (eq? (cadr se) 'make-flvector) 'flvector 'vector)
                          (and (symbol? (car args))
                               (hashtable-ref consts (car args) #f)))))))

      ;; The NAME an expression evaluates to, if it is one.
      ;;
      ;; ANF names every operand, so a top-level binding's value is not the
      ;; allocation itself but a `let` chain ending in the temporary that holds
      ;; it: `(define pos (make-flvector 15 0.0))` becomes
      ;; `(let ([t.408 '15]) (let ([t.409 (primcall make-flvector () t.408 ...)]) t.409))`.
      ;; Without following that tail the facts land on t.409 and never on `pos`,
      ;; so nothing reaches the call sites that pass it.
      (define (tail-name e)
        (cond
         ((symbol? e) e)
         ((not (pair? e)) #f)
         (else
          (case (car e)
            ((let seq letrec phi declare declare-distinct policy) (tail-name (caddr e)))
            ((sigma) (tail-name (list-ref e 6)))
            (else #f)))))

      (define (note-binding! x se)
        (cond
         ((and (pair? se) (eq? (car se) 'quote)) (note-const! x (cadr se)))
         ((alloc-shape se) => (lambda (s) (hashtable-set! shapes x s)))
         ;; A copy carries both -- and so does an expression that merely
         ;; evaluates to one, which is what ANF turns every definition into.
         (else
          (let ((src (tail-name se)))
            (when src
              (let ((c (hashtable-ref consts src #f))
                    (sh (hashtable-ref shapes src #f)))
                (when c (hashtable-set! consts x c))
                (when sh (hashtable-set! shapes x sh))))))))

      (define (note-procs! binds)
        (for-each (lambda (b)
                    (let ((v (cadr b)))
                      (if (and (pair? v) (eq? (car v) 'lambda))
                          (hashtable-set! params (car b) (cadr v))
                          (note-binding! (car b) v))))
                  binds))

      ;; Two sweeps, because a `let` may bind a size AFTER the allocation that
      ;; uses it has already been walked in a different branch. Cheap, and it
      ;; removes an ordering dependency that would otherwise decide whether a
      ;; length is found.
      (define (sweep!)
        (let walk ((x form))
          (when (pair? x)
            (case (car x)
              ((let) (let ((b (car (cadr x))))
                       ;; Lssa: (let ([x se]) body). Lrepr adds a class slot.
                       (note-binding! (car b) (if (= (length b) 3) (caddr b) (cadr b)))))
              ((top letrec) (note-procs! (cadr x)))
              ((call tailcall)
               (set! sites (cons (cons (cadr x) (cddr x)) sites))))
            (for-each walk x))))
      (sweep!)
      (set! sites '())
      (sweep!)

      ;; --- propagate across call sites ---
      ;;
      ;; `#f` in the table means "no fact". Once a parameter disagrees with a
      ;; new argument it is pinned to no-fact, so a later site cannot restore a
      ;; claim an earlier one refuted.
      ;; ONE pinned table PER FACT KIND. Sharing it means a parameter that has
      ;; no constant value -- which every vector parameter is -- gets pinned by
      ;; the constant merge and can then never receive its LENGTH. That is how
      ;; `pos` ended up with a length while `p` inside `advance!` did not, which
      ;; is exactly the fact the inner loop needs.
      (let ((pinned-const (make-eq-hashtable))
            (pinned-shape (make-eq-hashtable)))
        (define (merge! tbl pinned p v)
          (cond
           ((hashtable-ref pinned p #f) #f)
           ((not v) (hashtable-set! pinned p #t)
                    (and (hashtable-ref tbl p #f)
                         (begin (hashtable-delete! tbl p) #t)))
           ((not (hashtable-ref tbl p #f)) (hashtable-set! tbl p v) #t)
           ((equal? (hashtable-ref tbl p #f) v) #f)
           (else (hashtable-set! pinned p #t) (hashtable-delete! tbl p) #t)))

        (let fix ((round 0))
          (when (> round 100)
            (error 'shape-facts "shape propagation did not settle" round))
          (let ((changed #f))
            (for-each
             (lambda (site)
               (let ((ps (hashtable-ref params (car site) #f)))
                 (when (and ps (= (length ps) (length (cdr site))))
                   (for-each
                    (lambda (p a)
                      (let ((c (and (symbol? a) (hashtable-ref consts a #f)))
                            (s (and (symbol? a) (hashtable-ref shapes a #f))))
                        (when (merge! consts pinned-const p c) (set! changed #t))
                        (when (merge! shapes pinned-shape p s) (set! changed #t))))
                    ps (cdr site)))))
             sites)
            (when changed (fix (+ round 1))))))

      ;; --- emit ---
      ;;
      ;; Sorted, because these become part of the compiler's input and the
      ;; compiler is required to be deterministic (see order.ss).
      (append
       (map (lambda (x)
              (let ((s (hashtable-ref shapes x #f)))
                (if (cdr s) (list x (car s) (cdr s)) (list x (car s)))))
            (sorted-key-list shapes))
       (map (lambda (x)
              (let ((n (hashtable-ref consts x #f)))
                (list x 'interval n n)))
            (sorted-key-list consts)))))
  )
