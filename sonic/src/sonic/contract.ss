;;; D24 contraction: fusing a multiply-add, where the program permitted it.
;;;
;;; ## What was missing
;;;
;;; `fp-contract` has been a fully-formed permission since D24 -- parsed by
;;; policy.ss, scoped lexically, carried on every flonum primcall, counted in
;;; lower.ss's report, and excluded from veclegal's check vocabulary on purpose.
;;; Nothing ever ACTED on it. A program that granted contraction got exactly the
;;; instructions a program that refused it got, and the only way to find that out
;;; was to read the emitted code.
;;;
;;; That mattered more than a missing optimisation usually does, because it is
;;; the whole of the remaining gap to C. D34's arithmetic: nbody runs 420 FP
;;; operations per step against `gcc -O3 -march=native`'s 297, "and the
;;; difference is almost entirely fused multiply-add: gcc emits `vfmadd` and
;;; `vfnmadd` throughout and each replaces two of ours".
;;;
;;; ## The comparison this makes honest
;;;
;;; gcc contracts BY DEFAULT. `-ffp-contract=fast` is the default at every
;;; optimisation level, so `ref.c` has been fusing all along. Comparing our
;;; twice-rounded arithmetic against its once-rounded arithmetic was never a
;;; comparison of code generation -- it was a comparison of two different
;;; computations, one of which is allowed to use half as many instructions.
;;;
;;; D24 is not weakened by saying so. Contraction stays OFF by default and stays
;;; a named, lexically scoped permission; what changes is that granting it now
;;; does something, so a variant that grants it can be measured against a C
;;; compiler that never asked.
;;;
;;; ## The rewrite
;;;
;;;     (mul-c t sc a b)          (move v sc c)
;;;     (add-c v sc t c)     =>    (fma  v sc a b v)      v = a*b + v
;;;
;;;     (mul-c t sc a b)          (move v sc c)
;;;     (sub-c v sc c t)     =>    (fnma v sc a b v)      v = v - a*b
;;;
;;; The `move` is not an artefact. `vfmadd231sd d, a, b` computes d = a*b + d,
;;; so the destination IS the addend, and the copy that puts it there has to be
;;; visible to the ALLOCATOR -- `move-hints` in regalloc.ss is what turns it
;;; into no instruction at all. Emitting it from the selector instead, after
;;; allocation, was measured: 48 fused multiply-adds, 113 MORE instructions per
;;; step, and 26 cycles worse than not fusing.
;;;
;;; ONE ROUNDING INSTEAD OF TWO, which is the entire semantic difference and the
;;; entire reason this needs permission. The product is not rounded to a double
;;; before the addition, so the result can differ in the last bit from what the
;;; two instructions give -- usually more accurate, never identical, and
;;; `differential.ss` knows to expect a divergence rather than report one.
;;;
;;; ## Three conditions, and why each is necessary
;;;
;;; 1. BOTH INSTRUCTIONS CARRY THE MARK. `mul-c` and `add-c` mean "this stood
;;;    inside a granted scope". A product computed under a permission can be
;;;    read by an addition outside one -- a helper called from two scopes is
;;;    enough -- and fusing there would contract an expression the program did
;;;    not offer.
;;;
;;; 2. THE PRODUCT HAS EXACTLY ONE USE, and it is this addition. If anything
;;;    else reads it, the multiply has to happen anyway and the fusion adds an
;;;    instruction rather than removing one. Counted over the WHOLE PROGRAM, not
;;;    the block: a value read in another block is still read.
;;;
;;; 3. THEY ARE IN THE SAME BLOCK, with nothing between them that writes what
;;;    the fused form reads. A multiply in one block feeding an addition in
;;;    another is a legal contraction and is not worth the liveness analysis to
;;;    find; the shape that matters -- `dx*mag` straight into an accumulator --
;;;    is adjacent by construction, because ANF put it there.
;;;
;;; `sub-c` is directional and the direction is the operand that is the product.
;;; `c - a*b` is `fnma`; `a*b - c` is NOT, because negating the addend is a
;;; different instruction (`vfmsub`), and one is enough to measure with.

(library (sonic contract)
  (export contract-program contract-stats contract-stats? contract-stats-fused)
  (import (chezscheme) (sonic order))

  (define-record-type (contract-stats make-contract-stats contract-stats?)
    (fields (mutable fused)))

  (define (instr? i) (and (pair? i) (symbol? (car i))))

  ;; Every vreg an instruction READS. The destination is slot 1 on every shape
  ;; that reaches here except a store, whose first slot is the value -- and a
  ;; store of a product is a use, which is what this has to count.
  (define (uses i)
    (cond
     ((not (instr? i)) '())
     ((memq (car i) '(store store-at gset p2store p3store)) (filter symbol? (cdr i)))
     (else (filter symbol? (cdddr i)))))

  ;; Uses of each vreg across the WHOLE program, transfers included. A
  ;; block-local count says a value nothing here reads is dead, and a value read
  ;; from another block is exactly the case that makes fusing wrong.
  (define (use-counts prog)
    (let ((t (make-eq-hashtable)))
      (define (bump! v) (when (symbol? v) (hashtable-update! t v (lambda (k) (+ k 1)) 0)))
      (for-each
       (lambda (lb)
         (let ((blk (cadr lb)))
           (for-each (lambda (i) (for-each bump! (uses i))) (cadr blk))
           (let ((tr (caddr blk)))
             (when (and (pair? tr) (memq (car tr) '(branch-if ret))) (bump! (cadr tr))))))
       (cadr prog))
      t))

  ;; --- one table, two widths --------------------------------------------------
  ;;
  ;; A pair fuses exactly as a scalar does: `vfmadd231pd` is two independent
  ;; fused multiply-adds, lane by lane, each rounding once where the two packed
  ;; instructions it replaces round twice. Same permission, same argument, so
  ;; the same rewrite -- and writing it twice is how the two would drift.
  ;;
  ;; Each row is (marked-mul marked-add marked-sub fma fnma fma132 fnma132).
  (define fuse-table
    '((mul-c   add-c   sub-c   fma   fnma   fma132   fnma132)
      (p2mul-c p2add-c p2sub-c p2fma p2fnma p2fma132 p2fnma132)))

  (define (row-for-mul op) (assq op fuse-table))
  (define (row-of i) (and (instr? i) (row-for-mul (car i))))
  (define (row-add r) (cadr r))
  (define (row-sub r) (caddr r))
  (define (row-fma r) (cadddr r))
  (define (row-fnma r) (list-ref r 4))
  (define (row-fma132 r) (list-ref r 5))
  (define (row-fnma132 r) (list-ref r 6))

  ;; The unmarked spelling, for a marked op that did not fuse. Nothing
  ;; downstream should have to know the mark existed.
  (define unmark-table
    '((mul-c . mul) (add-c . add) (sub-c . sub)
      (p2mul-c . p2mul) (p2add-c . p2add) (p2sub-c . p2sub)))

  (define (unmark-instr i)
    (let ((m (and (instr? i) (assq (car i) unmark-table))))
      (if m (cons (cdr m) (cdr i)) i)))

  (define (f64? i) (and (instr? i) (>= (length i) 3) (eq? (caddr i) 'raw-f64)))

  ;; A marked multiply of either width -> (row t a b), or #f.
  (define (product i)
    (let ((r (row-of i)))
      (and r (= (length i) 5) (f64? i)
           (list r (cadr i) (cadddr i) (car (cddddr i))))))

  (define (fuse-block instrs counts stats)
    (let loop ((xs instrs) (out '()))
      (cond
       ((null? xs) (reverse out))
       ((null? (cdr xs)) (loop '() (cons (unmark-instr (car xs)) out)))
       (else
        (let ((p (product (car xs))) (nxt (cadr xs)))
          (cond
           ((and p
                 (eqv? 1 (hashtable-ref counts (cadr p) 0))
                 (instr? nxt) (f64? nxt) (= (length nxt) 5)
                 ;; the SAME WIDTH: a packed product does not fuse into a scalar
                 ;; sum, and the row is what says which is which.
                 (memq (car nxt) (list (row-add (car p)) (row-sub (car p))))
                 ;; the addend is whichever operand is not the product
                 (let* ((r (car p)) (t (cadr p))
                        (x (cadddr nxt)) (y (car (cddddr nxt))))
                   (cond
                    ;; a*b + c, either operand order: addition commutes and the
                    ;; fused form computes the same sum.
                    ((eq? (car nxt) (row-add r))
                     (cond ((eq? x t) (list (row-fma r) y))
                           ((eq? y t) (list (row-fma r) x))
                           (else #f)))
                    ;; c - a*b ONLY. `a*b - c` negates the addend instead of the
                    ;; product and is a different instruction.
                    (else (and (eq? y t) (list (row-fnma r) x))))))
            => (lambda (kind0)
                 (contract-stats-fused-set! stats (+ 1 (contract-stats-fused stats)))
                 ;; THE ADDEND HAS TO REACH THE DESTINATION, and the copy is
                 ;; emitted HERE rather than in the selector because only here
                 ;; can the allocator see it. `vfmadd231sd d, a, b` computes
                 ;; d = a*b + d, so the destination IS the addend; a rule that
                 ;; emitted the copy itself would emit it after allocation,
                 ;; where nothing can coalesce it, and it measured exactly that
                 ;; way -- 48 fused multiply-adds and 113 more instructions per
                 ;; step, for 26 cycles WORSE than not fusing at all.
                 ;;
                 ;; As an Lmach `move` it is what `move-hints` in regalloc.ss
                 ;; consumes: the allocator tries to give the addend and the
                 ;; destination one register, and when it succeeds finalize
                 ;; deletes the self-move. When it fails the move is real and
                 ;; the code is still right.
                 ;; WHICH OPERAND GOES IN THE DESTINATION is a coalescing
                 ;; question, not an arithmetic one -- every ordering computes
                 ;; the same number. `231` puts the ADDEND there, and for the
                 ;; shape that matters that is the worst possible choice: the
                 ;; addend is a loop-carried accumulator, live across the back
                 ;; edge, so its interval never ends at the copy and
                 ;; `move-hints` cannot take its register. Measured: 48 fusions
                 ;; and 65 surviving moves, for a net of ONE instruction saved.
                 ;;
                 ;; A FACTOR usually dies at the multiply -- `dx` in `dx*mag`
                 ;; is read once -- and a value that dies at the copy is
                 ;; exactly what coalescing needs. So when a factor has a single
                 ;; use, it goes in the destination and the ordering becomes
                 ;; `132`; otherwise fall back to `231` and the addend.
                 (let* ((r (car p)) (v (cadr nxt))
                        (kind (car kind0)) (addend (cadr kind0))
                        (a (caddr p)) (b (cadddr p))
                        (fma? (eq? kind (row-fma r)))
                        (once? (lambda (x) (eqv? 1 (hashtable-ref counts x 0))))
                        (plan (cond ((once? a) (list 'f132 a b))
                                    ((once? b) (list 'f132 b a))
                                    (else (list 'f231 addend #f)))))
                   (loop (cddr xs)
                         (cons (if (eq? (car plan) 'f132)
                                   ;; v holds a factor: v = v * other + addend
                                   (list (if fma? (row-fma132 r) (row-fnma132 r))
                                         v 'raw-f64 (caddr plan) addend)
                                   ;; v holds the addend: v = a*b + v
                                   (list kind v 'raw-f64 a b v))
                               (cons (list 'move v 'raw-f64 (cadr plan)) out))))))
           (else (loop (cdr xs) (cons (unmark-instr (car xs)) out)))))))))

  (define (contract-program prog)
    (unless (and (pair? prog) (eq? (car prog) 'program))
      (error 'contract-program "not an Lmach program datum" prog))
    (let ((stats (make-contract-stats 0))
          (counts (use-counts prog)))
      (values
       (list 'program
             (map (lambda (lb)
                    (let ((blk (cadr lb)))
                      (list (car lb)
                            (list 'block (fuse-block (cadr blk) counts stats)
                                  (caddr blk)))))
                  (cadr prog))
             (caddr prog))
       stats)))
  )
