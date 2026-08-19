;;; Top-level bindings become memory, not registers.
;;;
;;; A top-level binding is STORAGE. It is written once by the program's
;;; initialization and read from any function, and register allocation is per
;;; function -- so a reading function sees a use with no definition, is handed
;;; whatever register its own scan had free, and reads whatever that register
;;; happened to hold.
;;;
;;; This is not a subtle mis-optimization. nbody's `pos`, `vel` and `mass` are
;;; written by the entry code and read inside `main`; what `main` read was zero,
;;; which has tag 000, so the first type check on it trapped. The program built,
;;; linked, loaded and ran, and died on the first thing that looked at a global.
;;;
;;; ## The rewrite
;;;
;;; Every USE of a global becomes a `gref` into a fresh vreg immediately before
;;; the instruction; every DEFINITION becomes a `gset` immediately after. The
;;; global name itself then appears only inside those two ops, and no allocator
;;; ever sees it.
;;;
;;; Reloading at every use rather than once per block is deliberate for now. A
;;; global can be written by a call -- anything might assign one -- so caching it
;;; in a register across a call is only sound with an analysis that says the
;;; callee does not, and that analysis does not exist.
;;;
;;; THE LINE THAT USED TO FOLLOW SAID THE COST LANDS ENTIRELY OUTSIDE NBODY'S
;;; LOOPS, WHICH READ THEIR VECTORS FROM PARAMETERS. That was measured and is
;;; false (D87). The innermost pair loop reloads three globals per iteration --
;;; a vector pointer and two constants -- which is ~150M instructions at N=5e6
;;; against a 2981M total.
;;;
;;; The second cost is larger than the loads. `(define n-bodies 5)` is a global
;;; too, so `(fx< i n-bodies)` emits a register compare rather than `cmp $5`, no
;;; loop trip count is ever a constant, and NOTHING DOWNSTREAM CAN UNROLL. gcc
;;; flattens the same ten-iteration pair loop and we cannot; that is where our
;;; 4.6x branch gap against it comes from.
;;;
;;; The missing analysis is also weaker than this comment assumed. We compile
;;; WHOLE PROGRAMS, so "is this cell ever the target of a gset" is a scan, not an
;;; interprocedural effect analysis. The staged fix, cheapest first: a global
;;; gset exactly once with a LITERAL is a constant and can be propagated to every
;;; use, which alone unblocks unrolling; a global holding a pointer written only
;;; by initialization needs the dominance argument and can wait. See `qaq.17`.
;;;
;;; ## These cells are GC roots
;;;
;;; A global holding a tagged value is a root, and D21's collector scavenges the
;;; value register class unconditionally while knowing nothing about a static
;;; data segment. `global-roots` names the tagged ones so the collector has
;;; something to enumerate; wiring it in is E7's, and until then a collection
;;; that ran would free the vectors out from under the program.

(library (sonic globals)
  (export globalize global-cells global-roots
          global-cell-name global? )
  (import (chezscheme)
          (sonic lang)
          (sonic order))

  ;; The cell's name. Distinct from the binding's own name so that a `gref`
  ;; naming `%g-pos` can never be confused with a vreg called `pos`, and so a
  ;; disassembly says which is which.
  (define (global-cell-name x)
    (string->symbol (string-append "%g-" (symbol->string x))))

  (define (global? tbl x) (and (symbol? x) (hashtable-ref tbl x #f) #t))

  ;; Which top-level bindings are storage: everything whose value is not a
  ;; procedure. A procedure IS its label, and calling it is a direct branch, so
  ;; putting one in a cell would add an indirection to every call.
  (define (global-cells form)
    (let ((tbl (make-eq-hashtable)))
      (when (and (pair? form) (eq? (car form) 'top))
        (for-each (lambda (b)
                    (let ((v (cadr b)))
                      (unless (and (pair? v) (eq? (car v) 'lambda))
                        (hashtable-set! tbl (car b) #t))))
                  (cadr form)))
      tbl))

  ;; The tagged ones, which the collector has to treat as roots.
  (define (global-roots tbl classes)
    (let ((acc '()))
      (vector-for-each
       (lambda (g)
         (when (eq? (hashtable-ref classes g #f) 'tagged)
           (set! acc (cons g acc))))
       (sorted-keys tbl))
      acc))

  ;; --- the pass -------------------------------------------------------------

  (define (globalize prog tbl classes)
    (let ((counter 0))
      (define (fresh!)
        (set! counter (+ counter 1))
        (string->symbol (string-append "g." (number->string counter))))
      (define (class-of g)
        (or (hashtable-ref classes g #f)
            (error 'globalize
                   "a top-level binding with no storage class; a cell has to know its width and whether the collector scavenges it"
                   g)))

      ;; A `gref` per use, in order, plus the substituted operand list.
      (define (rewrite-uses xs)
        (let loop ((xs xs) (pre '()) (out '()))
          (cond
           ((null? xs) (values (reverse pre) (reverse out)))
           ((global? tbl (car xs))
            (let* ((g (car xs)) (t (fresh!)) (sc (class-of g)))
              (hashtable-set! classes t sc)
              (loop (cdr xs)
                    (cons `(gref ,t ,sc ,(global-cell-name g)) pre)
                    (cons t out))))
           (else (loop (cdr xs) pre (cons (car xs) out))))))

      (define (rewrite-instr i)
        (case (car i)
          ;; (chk pn c tag v* ...): the check name, the control and the tag are
          ;; all fields rather than operands, so the operands start at 4.
          ((chk)
           (let-values (((pre ops) (rewrite-uses (list-tail i 4))))
             (append pre (list (append (list-head i 4) ops)))))
          ;; (const v sc d): the datum is not an operand and the destination is
          ;; the only thing that can be a global.
          ((const)
           (let ((d (cadr i)))
             (if (global? tbl d)
                 (let* ((t (fresh!)) (sc (caddr i)))
                   (hashtable-set! classes t sc)
                   (list (list 'const t sc (cadddr i))
                         `(gset ,t ,sc ,(global-cell-name d))))
                 (list i))))
          (else
           ;; (op v sc v* ...). The call's callee is a label, never a global:
           ;; a procedure is its label, not a cell.
           (let* ((dst (cadr i))
                  (sc (caddr i))
                  (srcs (cdddr i))
                  (skip (if (eq? (car i) 'call) 1 0))
                  (fixed (list-head srcs skip))
                  (rest (list-tail srcs skip)))
             (let-values (((pre ops) (rewrite-uses rest)))
               (if (global? tbl dst)
                   (let* ((t (fresh!)))
                     (hashtable-set! classes t sc)
                     (append pre
                             (list (append (list (car i) t sc) fixed ops)
                                   `(gset ,t ,sc ,(global-cell-name dst)))))
                   (append pre
                           (list (append (list (car i) dst sc) fixed ops)))))))))

      ;; A transfer reads at most one vreg, and it cannot be rewritten in place
      ;; -- the `gref` has to precede it, which means it belongs to the block's
      ;; instruction list rather than to the transfer.
      (define (rewrite-transfer t)
        (case (car t)
          ((branch-if ret)
           (let-values (((pre ops) (rewrite-uses (list (cadr t)))))
             (values pre (cons (car t) (append ops (cddr t))))))
          (else (values '() t))))

      (let ((blocks (cadr prog)) (entry (caddr prog)))
        (list 'program
              (map (lambda (b)
                     (let* ((blk (cadr b))
                            (instrs (apply append (map rewrite-instr (cadr blk)))))
                       (let-values (((pre t) (rewrite-transfer (caddr blk))))
                         (list (car b) (list 'block (append instrs pre) t)))))
                   blocks)
              entry))))
  )
