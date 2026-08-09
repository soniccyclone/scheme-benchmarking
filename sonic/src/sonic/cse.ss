;;; Common subexpression elimination over Lmach, block-local.
;;;
;;; ## What it is for
;;;
;;; nbody's position update reads and writes three components per body, and
;;; after lowering each component index is computed from scratch:
;;;
;;;     mov rdx, 1 ; mov rdi, rsi ; add rdi, rdx      ; i+1
;;;     mov rdx, 1 ; mov rcx, rsi ; add rcx, rdx      ; i+1, again
;;;     mov rcx, 1 ; mov rdx, rsi ; add rdx, rcx      ; i+1, a third time
;;;
;;; Nine of those in one loop body, computing two distinct values, out of a
;;; body of fifty-three instructions. Nothing upstream is at fault: ANF names
;;; every intermediate separately and lowering translates each name, so the
;;; repetition is an artifact of translating the same source expression three
;;; times rather than of anyone computing something twice.
;;;
;;; ## Rewriting uses, not inserting moves
;;;
;;; The obvious cheap form is to leave the redundant instruction in place as
;;; `(move dst sc prev)`, and let coalescing pick it up. That does not work
;;; here: `prev` is still live -- it has other readers, which is what made it
;;; common in the first place -- so its register is neither free nor dying, the
;;; coalescer correctly declines, and a three-instruction sequence becomes one
;;; instruction rather than none.
;;;
;;; So this rewrites every USE of the redundant destination to name `prev`
;;; instead, program-wide, and lets dce.ss remove the definition that now has
;;; no readers. That is why this pass runs immediately before DCE rather than
;;; after it.
;;;
;;; ## Why rewriting program-wide uses is sound
;;;
;;; Two conditions, both checked.
;;;
;;; First, every vreg involved -- the destination and every operand -- must be
;;; defined exactly ONCE in the whole program. Then a vreg name denotes one
;;; value, and two instructions with equal operand names compute equal results.
;;; Lmach after lowering is single-assignment in practice, but "in practice" is
;;; not a licence, so the def counts are computed and the condition is enforced
;;; per instruction. An op whose operands are multiply-defined is simply left
;;; alone.
;;;
;;; Second, `prev` must dominate every use of `dst`. It does, and the argument
;;; is short: `prev` precedes `dst` in the SAME block, so any point `dst`
;;; dominates is dominated by `prev`. A use of `dst` that `dst` did not
;;; dominate would be a use of an undefined value, which is not a program this
;;; compiler can be handed. Restricting the table to one block is what buys
;;; that argument, and is the reason this is not a global value-numbering pass.
;;;
;;; ## Memory is not pure and the table knows it
;;;
;;; `load`, `vlen` and `gref` read memory, so two identical loads are the same
;;; value only if nothing wrote in between. The loop body above interleaves
;;; loads and stores to the very same vector -- read p[i], write p[i], read
;;; p[i+1] -- so treating a load as unconditionally pure would fold a reload
;;; onto a value the intervening store had already replaced, and nbody's
;;; energies would stop being bit-exact.
;;;
;;; They are therefore kept in a SEPARATE table, discarded whenever a `store`,
;;; `gset` or `call` goes by. Arithmetic and comparison are unaffected by those
;;; -- their operands are single-assignment vregs, not storage -- so the win on
;;; index arithmetic survives an invalidation that happens on nearly every
;;; line.

(library (sonic cse)
  (export cse-program cse-stats cse-stats? cse-stats-folded cse-stats-invalidations)
  (import (chezscheme))

  (define-record-type (cse-stats make-cse-stats cse-stats?)
    (fields (mutable folded) (mutable invalidations)))

  ;; Value-like: the result is a function of the operand vregs alone.
  (define value-ops
    '(add sub mul neg sqrt abs
      cmp-lt cmp-le cmp-eq cmp-ge cmp-gt
      fcmp-lt fcmp-le fcmp-eq fcmp-ge fcmp-gt
      move cvt-f64-from-int cvt-int-from-f64))

  ;; Reads storage, so equal operands mean equal results only between writes.
  ;; Reads the HEAP, so equal operands mean equal results only between writes
  ;; to it. `load-at` belongs here and was missing: it is a load like any other
  ;; and was simply never considered for elimination.
  (define memory-ops '(load load-at vlen))

  ;; Reads a GLOBAL CELL, which is a different storage area entirely.
  ;;
  ;; Keeping these apart is worth real instructions. A global and a heap object
  ;; cannot alias -- globals live in the writable segment at addresses
  ;; globals.ss assigns, heap objects in the heap -- so a `store` into a vector
  ;; says nothing about a global's value. Clearing one table on the other's
  ;; writes had nbody reloading `dt` from its cell three times in the position
  ;; update, once between each pair of vector stores.
  ;;
  ;; It also cost a vector instruction rather than just a load: two loads of the
  ;; same global are two different vregs, so the SLP pass saw two distinct
  ;; scalars and ASSEMBLED them with `vunpcklpd` where one `vmovddup` splat of a
  ;; single value would do.
  (define global-ops '(gref))

  ;; Writes storage, or may. Invalidates the memory table.
  ;; Writes the heap, or may.
  (define clobber-ops '(store store-at call))

  ;; Writes a global, or may. A call may do either, so it appears in both.
  (define global-clobber-ops '(gset call))

  (define (dest-of i)
    (and (pair? i)
         (or (memq (car i) value-ops) (memq (car i) memory-ops)
             (memq (car i) global-ops)
             (eq? (car i) 'const))
         (cadr i)))

  (define (key-of i)
    (cond
     ((eq? (car i) 'const) (list 'const (caddr i) (cadddr i)))
     (else (cons* (car i) (caddr i) (cdddr i)))))

  ;; --- definition counts, over the whole program -----------------------------
  ;;
  ;; Counts DEFINITIONS, and counts them for every instruction shape, not only
  ;; the ones this pass folds. A vreg defined once by an `add` and once by a
  ;; `call` is multiply-defined, and missing the `call` would let the add be
  ;; folded onto a name the call later overwrites.
  (define (def-counts blocks)
    (let ((tbl (make-eq-hashtable)))
      (for-each
       (lambda (lb)
         (for-each
          (lambda (i)
            (when (and (pair? i) (not (eq? (car i) 'chk))
                       ;; (gset v sc cell) puts a SOURCE in slot 1 -- see
                       ;; dce.ss. Counting it as a definition would make the
                       ;; value it stores look multiply-defined, which only
                       ;; suppresses folding, but the count is also read below
                       ;; to decide whether an OPERAND is trustworthy, and there
                       ;; a spurious count is a missed optimisation on every
                       ;; global write. Excluded.
                       (not (eq? (car i) 'gset))
                       (pair? (cdr i)) (symbol? (cadr i)))
              (hashtable-update! tbl (cadr i) (lambda (n) (+ n 1)) 0)))
          (cadr (cadr lb))))
       blocks)
      tbl))

  ;; EXACTLY ONE definition. Relaxing this to "at most one" is tempting -- a
  ;; parameter has none and is still single-valued -- and it produces wrong
  ;; answers, measured: nbody's energies moved to -0.323 and -0.419. A name with
  ;; no definition in Lmach is not reliably a parameter, and this pass has no
  ;; way to tell which kind it is looking at.
  (define (single? counts v)
    (or (not (symbol? v)) (= 1 (hashtable-ref counts v 0))))

  ;; --- the pass --------------------------------------------------------------

  (define (cse-program prog)
    (unless (and (pair? prog) (eq? (car prog) 'program))
      (error 'cse-program "not an Lmach program datum" prog))
    (let* ((blocks (cadr prog))
           (counts (def-counts blocks))
           (stats (make-cse-stats 0 0))
           ;; dst -> the earlier vreg holding the same value. Filled while
           ;; scanning blocks, applied to the whole program afterwards.
           (rename (make-eq-hashtable)))

      ;; Chase, because folding can chain: c := a, then d := a folds to c, and
      ;; a later e := c must land on the same place. Bounded, because a rename
      ;; always points at an EARLIER definition and cannot cycle -- the bound
      ;; is there anyway, on the principle that an argument for termination is
      ;; not a guard.
      (define (resolve v)
        (let loop ((v v) (n 0))
          (let ((r (hashtable-ref rename v #f)))
            (if (and r (< n 1000)) (loop r (+ n 1)) v))))

      (for-each
       (lambda (lb)
         (let ((values-tbl (make-hashtable equal-hash equal?))
               (mem-tbl (make-hashtable equal-hash equal?))
               (glob-tbl (make-hashtable equal-hash equal?)))
           (for-each
            (lambda (i)
              (when (pair? i)
                (cond
                 ((or (memq (car i) clobber-ops) (memq (car i) global-clobber-ops))
                  (cse-stats-invalidations-set!
                   stats (+ 1 (cse-stats-invalidations stats)))
                  (when (memq (car i) clobber-ops) (hashtable-clear! mem-tbl))
                  (when (memq (car i) global-clobber-ops) (hashtable-clear! glob-tbl)))
                 (else
                  (let ((dst (dest-of i)))
                    (when (and dst (single? counts dst)
                               ;; Operands must denote one value each. Resolved
                               ;; first, so an operand this pass already folded
                               ;; is recognised as the same expression.
                               ;;
                               ;; A GLOBAL READ is exempt: its operand is the
                               ;; cell's NAME, a label rather than a value, so
                               ;; it has no definition to count and the check
                               ;; would fail on every one. That exclusion had
                               ;; nbody reloading `dt` three times in one loop
                               ;; body, and cost a vector instruction too --
                               ;; two loads of one global are two vregs, so the
                               ;; SLP pass assembled them with `vunpcklpd`
                               ;; where one `vmovddup` splat would do.
                               ;; A GLOBAL READ is exempt from the operand
                               ;; check. Its operand is the cell's NAME -- a
                               ;; label, not a value -- so it has no definition
                               ;; to count and the check would fail on every
                               ;; one. That exclusion had nbody reloading `dt`
                               ;; three times in one loop body, and cost a
                               ;; vector instruction too: two loads of one
                               ;; global are two vregs, so the SLP pass
                               ;; assembled them with `vunpcklpd` where one
                               ;; `vmovddup` splat of a single value does.
                               ;;
                               ;; TAGGED READS WERE EXCLUDED FOR A DAY, on the
                               ;; measured grounds that including them made
                               ;; nbody answer -0.323 and -0.419 against -0.169
                               ;; and -0.169. The fold was never the problem.
                               ;; Folding two reads of `%g-days-per-year` into
                               ;; one vreg is what puts an SLP op pack into the
                               ;; shared-scalar shape, and slp.ss then splatted
                               ;; an operand the two lanes did NOT share --
                               ;; storing vx*dpy where vy*dpy belonged. Fixed
                               ;; there, in `demote-unpaired!`; this pass was
                               ;; right all along and the restriction is gone.
                               (or (memq (car i) global-ops)
                                   (for-all (lambda (o) (single? counts o))
                                            (cdddr i))))
                      (let* ((tbl (cond ((memq (car i) memory-ops) mem-tbl)
                                        ((memq (car i) global-ops) glob-tbl)
                                        (else values-tbl)))
                             (k (key-of (cons* (car i) (cadr i) (caddr i)
                                               (map resolve (cdddr i)))))
                             (prev (hashtable-ref tbl k #f)))
                        (if prev
                            (begin
                              (cse-stats-folded-set!
                               stats (+ 1 (cse-stats-folded stats)))
                              (hashtable-set! rename dst prev))
                            (hashtable-set! tbl k dst)))))))))
            (cadr (cadr lb)))))
       blocks)

      ;; Apply. Every OPERAND position is rewritten; destinations are left
      ;; alone, so the folded definition survives here with nobody reading it
      ;; and dce.ss is what actually deletes it.
      (values (list 'program (map (lambda (lb) (rewrite-block lb resolve)) blocks)
                    (caddr prog))
              stats)))

  (define (rewrite-block lb resolve)
    (let ((blk (cadr lb)))
      (list (car lb)
            (list 'block
                  (map (lambda (i) (rewrite-instr i resolve)) (cadr blk))
                  (rewrite-transfer (caddr blk) resolve)))))

  (define (rewrite-instr i resolve)
    (cond
     ((not (pair? i)) i)
     ((eq? (car i) 'const) i)
     ((eq? (car i) 'chk)
      (append (list (car i) (cadr i) (caddr i) (cadddr i))
              (map resolve (cddddr i))))
     ;; (gset v sc cell): slot 1 is the value being stored, so it is an operand
     ;; and must be rewritten. Every other shape has a destination there.
     ((eq? (car i) 'gset)
      (list 'gset (resolve (cadr i)) (caddr i) (cadddr i)))
     (else
      (cons* (car i) (cadr i) (caddr i) (map resolve (cdddr i))))))

  (define (rewrite-transfer t resolve)
    (cond
     ((not (pair? t)) t)
     ((eq? (car t) 'branch-if) (list 'branch-if (resolve (cadr t)) (caddr t) (cadddr t)))
     ((eq? (car t) 'ret) (list 'ret (resolve (cadr t))))
     (else t)))
  )
