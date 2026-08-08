;;; Index arithmetic into the addressing mode, over Lmach.
;;;
;;; A vector indexed at a constant offset from a loop counter -- `p[3i+1]` --
;;; lowers to an `add` producing a fresh vreg and a `load` using it. The add is
;;; unnecessary: every addressing mode this compiler targets carries a
;;; displacement, and the tag adjustment is already riding in it.
;;;
;;; ## Why this is not the peephole that already exists
;;;
;;; peephole.ss folds the same arithmetic, and it must stay: it catches cases
;;; this pass cannot see, and it is where the scale-distributes-over-the-constant
;;; reasoning is tested. But it runs AFTER register allocation, and by then the
;;; damage is done.
;;;
;;; nbody's pairwise force loop derives four indices -- 3i+1, 3i+2, 3j+1, 3j+2 --
;;; and each is a vreg the allocator must place. One of them spilled, and the
;;; seven instructions that resulted
;;;
;;;     mov  rax, r11 ; mov [rsp+40], rax ; mov rax, [rsp+40] ; add rax, 2
;;;     mov  [rsp+40], rax ; mov rax, [rsp+40] ; movsd xmm1, [r8+rax*8-1]
;;;
;;; are one addressed load. A peephole cannot repair that, because the value it
;;; would fold is in a frame slot rather than a register. The saving is not the
;;; seven instructions either -- it is the four vregs that never compete for a
;;; register in the first place.
;;;
;;; ## The offset is in ELEMENTS
;;;
;;; `(load-at v sc d base idx)` addresses element `idx + d`, not byte `idx + d`.
;;; The scale is the target's business: x86-64 folds it into a SIB scale and
;;; RV64 shifts, and a byte count here would bake one target's element size into
;;; the machine-independent IR.
;;;
;;; ## What it refuses
;;;
;;; The offset must be a constant this pass can SEE -- an `add` of an index and
;;; a `const`-defined vreg. An index built any other way is left alone. There is
;;; no attempt to chase arithmetic: `elide` and `loops` already know far more
;;; about these expressions, and a second, weaker opinion about an index is a
;;; second thing to keep sound.

(library (sonic addrfold)
  (export addrfold-program
          addrfold-stats addrfold-stats? addrfold-stats-folded)
  (import (chezscheme))

  (define-record-type (addrfold-stats make-addrfold-stats addrfold-stats?)
    (fields (mutable folded)))

  ;; vreg -> the exact integer it is bound to, for `(const v sc d)`.
  (define (const-table blocks)
    (let ((tbl (make-eq-hashtable)))
      (for-each
       (lambda (lb)
         (for-each
          (lambda (i)
            (when (and (pair? i) (eq? (car i) 'const) (= (length i) 4)
                       (integer? (cadddr i)) (exact? (cadddr i)))
              (hashtable-set! tbl (cadr i) (cadddr i))))
          (cadr (cadr lb))))
       blocks)
      tbl))

  ;; vreg -> (index . offset), for an `add` of an index and a constant. Both
  ;; operand orders, because addition is commutative and lowering does not
  ;; promise which side the constant lands on.
  (define (offset-table blocks consts)
    (let ((tbl (make-eq-hashtable)))
      (for-each
       (lambda (lb)
         (for-each
          (lambda (i)
            (when (and (pair? i) (eq? (car i) 'add) (= (length i) 5))
              (let* ((dst (cadr i)) (a (cadddr i)) (b (car (cddddr i)))
                     (ka (and (symbol? a) (hashtable-ref consts a #f)))
                     (kb (and (symbol? b) (hashtable-ref consts b #f))))
                (cond
                 ;; A constant on BOTH sides is a constant, not an index. Left
                 ;; alone: folding it would produce a load whose index is a
                 ;; literal, which is a different and rarer shape.
                 ((and ka kb) (void))
                 (kb (hashtable-set! tbl dst (cons a kb)))
                 (ka (hashtable-set! tbl dst (cons b ka)))
                 (else (void))))))
          (cadr (cadr lb))))
       blocks)
      tbl))

  (define (addrfold-program prog)
    (unless (and (pair? prog) (eq? (car prog) 'program))
      (error 'addrfold-program "not an Lmach program datum" prog))
    (let* ((blocks (cadr prog))
           (consts (const-table blocks))
           (offs (offset-table blocks consts))
           (stats (make-addrfold-stats 0)))

      (define (folded-index x)
        (and (symbol? x) (hashtable-ref offs x #f)))

      (define (rewrite i)
        (cond
         ;; (load dst sc base idx)
         ((and (pair? i) (eq? (car i) 'load) (= (length i) 5))
          (let ((f (folded-index (car (cddddr i)))))
            (if f
                (begin
                  (addrfold-stats-folded-set! stats (+ 1 (addrfold-stats-folded stats)))
                  (list 'load-at (cadr i) (caddr i) (cdr f) (cadddr i) (car f)))
                i)))
         ;; (store dst sc base idx val)
         ((and (pair? i) (eq? (car i) 'store) (= (length i) 6))
          (let ((f (folded-index (car (cddddr i)))))
            (if f
                (begin
                  (addrfold-stats-folded-set! stats (+ 1 (addrfold-stats-folded stats)))
                  (list 'store-at (cadr i) (caddr i) (cdr f) (cadddr i) (car f)
                        (cadr (cddddr i))))
                i)))
         (else i)))

      (let ((out
             (map (lambda (lb)
                    (let ((blk (cadr lb)))
                      (list (car lb)
                            (list 'block (map rewrite (cadr blk)) (caddr blk)))))
                  blocks)))
        (values (list 'program out (caddr prog)) stats))))
  )
