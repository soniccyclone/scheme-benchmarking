;;; Superword-level parallelism: packing adjacent scalar work into pairs.
;;;
;;; ## Why this and not loop vectorization
;;;
;;; nbody's pairwise force loop is 66% of a step and CANNOT be loop-vectorized:
;;; over five bodies it runs 4, 3, 2, 1 and 0 times, so no vector width fits.
;;; veclegal refuses it for `trip-count-too-short` and that refusal is correct.
;;;
;;; But the work inside ONE iteration is three-wide. dx, dy and dz are computed
;;; identically from adjacent elements, squared identically, and each velocity
;;; component is updated identically. That is parallelism within a basic block,
;;; which is a different question from "may this loop be vectorized" and needs a
;;; different analysis.
;;;
;;; gcc reaches the same conclusion from the other side: `-fopt-info-vec` reports
;;; "basic block part vectorized using 16 byte vectors" at exactly the sites
;;; where the components combine, and it emits zero ymm and zero zmm on a machine
;;; that has both -- three components fill two lanes, not four or eight.
;;;
;;; ## Pairs, and why the lane count is not a parameter
;;;
;;; Three components pack as two plus one. A wider vector would have to mask off
;;; a fourth element that may not exist, and masking is an AVX-512 facility this
;;; back end does not otherwise need. Two lanes fit in one 128-bit register,
;;; which is what makes the whole pass cheap: a packed pair is an ordinary
;;; `raw-f64` vreg. The register allocator, the static partition and the
;;; collector need no changes at all, because a pair lives exactly where a
;;; scalar double lives.
;;;
;;; ## ALL USES OR NO PACK
;;;
;;; The condition that makes packing profitable rather than merely possible: a
;;; value may be packed only if EVERY use of it is itself packed. A scalar use
;;; of a packed value needs an extract, and an extract costs what the pack
;;; saved. So packs are built optimistically and then validated, and a chain
;;; that fails validation is discarded whole.
;;;
;;; ## What makes it safe under D24
;;;
;;; `vsubpd` is two independent subtractions, lane by lane. It rounds exactly as
;;; the two scalar subtractions it replaces: no reassociation, no contraction,
;;; no horizontal operation. That is the entire correctness argument, and it is
;;; why the reduction `dx*dx + dy*dy + dz*dz` is NOT packed here -- summing
;;; across lanes is reassociation, which D24 forbids and which the bit-exact
;;; oracle would catch.

(library (sonic slp)
  (export slp-program slp-stats slp-stats? slp-stats-packs slp-stats-instructions)
  (import (chezscheme) (sonic order))

  (define-record-type (slp-stats make-slp-stats slp-stats?)
    (fields (mutable packs) (mutable instructions)))

  ;; Packable arithmetic. `div` is here and `sqrt` is not: sqrt is unary and the
  ;; shape below is binary, and a one-operand pack saves one instruction where
  ;; the plumbing costs more than that.
  (define pack-op '((add . p2add) (sub . p2sub) (mul . p2mul) (div . p2div)))

  ;; --- reading a block --------------------------------------------------------

  ;; A load, normalised: (base idx offset), or #f.
  (define (load-form i)
    (cond
     ((and (pair? i) (eq? (car i) 'load) (= (length i) 5))
      (list (cadddr i) (car (cddddr i)) 0))
     ((and (pair? i) (eq? (car i) 'load-at) (= (length i) 6))
      (list (car (cddddr i)) (cadr (cddddr i)) (cadddr i)))
     (else #f)))

  ;; A store, normalised: (base idx offset value), or #f.
  (define (store-form i)
    (cond
     ((and (pair? i) (eq? (car i) 'store) (= (length i) 6))
      (list (cadddr i) (car (cddddr i)) 0 (cadr (cddddr i))))
     ((and (pair? i) (eq? (car i) 'store-at) (= (length i) 7))
      (list (car (cddddr i)) (cadr (cddddr i)) (cadddr i) (caddr (cddddr i))))
     (else #f)))

  (define (f64? i classes)
    (and (pair? i) (>= (length i) 3) (eq? (caddr i) 'raw-f64)))

  ;; --- the pass ---------------------------------------------------------------

  ;; How many times each vreg is used as an operand ANYWHERE in the program,
  ;; including in transfers.
  ;;
  ;; A block-local count is not enough and the difference is a wrong answer: a
  ;; value packed here still has its scalar form read in another block, and
  ;; packing deletes that form. Nothing in one block can see that, which is why
  ;; this is computed over the whole program and handed down.
  (define (global-uses prog)
    (let ((tbl (make-eq-hashtable)))
      (define (bump! v)
        (when (symbol? v) (hashtable-update! tbl v (lambda (k) (+ k 1)) 0)))
      (for-each
       (lambda (lb)
         (let ((blk (cadr lb)))
           (for-each (lambda (i) (when (pair? i) (for-each bump! (cddr i))))
                     (cadr blk))
           (let ((t (caddr blk)))
             (when (and (pair? t) (memq (car t) '(branch-if ret))) (bump! (cadr t))))))
       (cadr prog))
      tbl))

  (define (slp-program prog classes)
    (unless (and (pair? prog) (eq? (car prog) 'program))
      (error 'slp-program "not an Lmach program datum" prog))
    (let ((stats (make-slp-stats 0 0))
          (guses (global-uses prog)))
      (values
       (list 'program
             (map (lambda (lb)
                    (let ((blk (cadr lb)))
                      (list (car lb)
                            (list 'block (slp-block (cadr blk) classes stats guses)
                                  (caddr blk)))))
                  (cadr prog))
             (caddr prog))
       stats)))

  (define (slp-block instrs classes stats guses)
    (let* ((n (length instrs))
           (vec (list->vector instrs))
           (packed (make-eq-hashtable))     ; lo -> hi
           (packs '())                      ; ((lo . hi) ...), lane order
           (store-packs '()))               ; ((lo-index . hi-index) ...)

      (define (pack! lo hi)
        (if (hashtable-contains? packed lo)
            #f
            (begin (hashtable-set! packed lo hi)
                   (set! packs (cons (cons lo hi) packs))
                   #t)))

      (define (paired? a b) (eq? (hashtable-ref packed a #f) b))

      ;; Two loads from adjacent elements are two halves of one 128-bit read.
      ;; Adjacency is the precondition the packed load needs and the only thing
      ;; that cannot be recovered later, which is why seeding starts here.
      (define (collect-seeds!)
        (let outer ((a 0))
          (when (< a n)
            (let ((fa (load-form (vector-ref vec a))))
              (when (and fa (f64? (vector-ref vec a) classes))
                (let inner ((b 0))
                  (when (< b n)
                    (let ((fb (load-form (vector-ref vec b))))
                      (when (and fb (not (= a b))
                                 (eq? (car fa) (car fb))
                                 (eq? (cadr fa) (cadr fb))
                                 (= (+ (caddr fa) 1) (caddr fb)))
                        (pack! (cadr (vector-ref vec a)) (cadr (vector-ref vec b)))))
                    (inner (+ b 1))))))
            (outer (+ a 1)))))

      ;; A pack of values feeds a pack of identical operations when the operands
      ;; line up lane for lane: both from one pack, or both the SAME scalar,
      ;; which becomes a splat.
      (define (grow!)
        (let round ()
          (let ((again #f))
            (let loop ((k 0))
              (when (< k n)
                (let ((i (vector-ref vec k)))
                  (when (and (pair? i) (assq (car i) pack-op) (= (length i) 5)
                             (eq? (caddr i) 'raw-f64)
                             (not (hashtable-contains? packed (cadr i))))
                    (let inner ((j 0))
                      (when (< j n)
                        (let ((o (vector-ref vec j)))
                          (when (and (not (= j k)) (pair? o) (eq? (car o) (car i))
                                     (= (length o) 5) (eq? (caddr o) 'raw-f64)
                                     (lane-ok? (cadddr i) (cadddr o) paired?)
                                     (lane-ok? (car (cddddr i)) (car (cddddr o)) paired?))
                            (when (pack! (cadr i) (cadr o)) (set! again #t))))
                        (inner (+ j 1))))))
                (loop (+ k 1))))
            (when again (round)))))

      (define (collect-store-packs!)
        (let outer ((a 0))
          (when (< a n)
            (let ((fa (store-form (vector-ref vec a))))
              (when (and fa (f64? (vector-ref vec a) classes))
                (let inner ((b 0))
                  (when (< b n)
                    (let ((fb (store-form (vector-ref vec b))))
                      (when (and fb (not (= a b))
                                 (eq? (car fa) (car fb))
                                 (eq? (cadr fa) (cadr fb))
                                 (= (+ (caddr fa) 1) (caddr fb))
                                 (paired? (cadddr fa) (cadddr fb)))
                        (set! store-packs (cons (cons a b) store-packs))))
                    (inner (+ b 1))))))
            (outer (+ a 1)))))

      (define (uses-of v)
        (let count ((k 0) (acc '()))
          (if (= k n)
              (reverse acc)
              (count (+ k 1)
                     (if (and (pair? (vector-ref vec k))
                              (memq v (cddr (vector-ref vec k))))
                         (cons k acc)
                         acc)))))

      (define (hi? v)
        (let scan ((ps packs))
          (cond ((null? ps) #f) ((eq? (cdar ps) v) #t) (else (scan (cdr ps))))))

      ;; Used here as many times as it is used anywhere: nothing outside this
      ;; block reads it, so replacing its scalar form loses nothing.
      (define (block-local? v)
        (= (length (uses-of v)) (hashtable-ref guses v 0)))

      (define (packed-instruction? k)
        (let ((i (vector-ref vec k)))
          (or (and (pair? i) (>= (length i) 2) (symbol? (cadr i))
                   (or (hashtable-contains? packed (cadr i)) (hi? (cadr i))))
              (let scan ((sp store-packs))
                (cond ((null? sp) #f)
                      ((or (= k (caar sp)) (= k (cdar sp))) #t)
                      (else (scan (cdr sp))))))))

      ;; An arithmetic pack is only still valid if its OPERAND lanes still line
      ;; up. Growth pairs operands against the packs that existed then; pruning
      ;; can remove one of those, and a pack left referring to it is silently
      ;; wrong rather than merely unprofitable.
      ;;
      ;; This is the bug that produced a wrong second energy: the squares
      ;; `dx*dx` and `dy*dy` feed a REDUCTION, so their pack was correctly
      ;; pruned, which removed the (dx,dy) pack -- and the pack for `dx*mj`
      ;; beside `dy*mj` was left behind. At emission `dx` no longer looked
      ;; packed, so it took the scalar path and was SPLATTED into both lanes.
      ;; The code was well formed and computed dx twice.
      (define (operands-still-paired? p)
        (let ((k (let scan ((k 0))
                   (cond ((= k n) #f)
                         ((let ((i (vector-ref vec k)))
                            (and (pair? i) (>= (length i) 2) (eq? (cadr i) (car p))))
                          k)
                         (else (scan (+ k 1)))))))
          (or (not k)
              (let ((i (vector-ref vec k)))
                (or (load-form i)          ; a load pack has no operand lanes
                    (not (assq (car i) pack-op))
                    (let ((j (let scan ((j 0))
                               (cond ((= j n) #f)
                                     ((let ((o (vector-ref vec j)))
                                        (and (pair? o) (>= (length o) 2)
                                             (eq? (cadr o) (cdr p))))
                                      j)
                                     (else (scan (+ j 1)))))))
                      (and j
                           (let ((o (vector-ref vec j)))
                             (and (lane-ok? (cadddr i) (cadddr o) paired?)
                                  (lane-ok? (car (cddddr i)) (car (cddddr o))
                                            paired?))))))))))

      ;; ALL USES OR NO PACK. A packed value read by anything not itself packed
      ;; would need an extract, and an extract costs what the pack saved. So
      ;; packs are built optimistically and then validated, and a chain that
      ;; fails is discarded whole. Dropping one pack can invalidate another --
      ;; both by leaving a use unpacked and by breaking an operand pairing -- so
      ;; this runs to a fixpoint.
      (define (prune!)
        (let round ()
          (let ((dropped #f))
            (set! packs
                  (filter (lambda (p)
                            (let ((ok (and (block-local? (car p)) (block-local? (cdr p))
                                           (operands-still-paired? p)
                                           (for-all packed-instruction? (uses-of (car p)))
                                           (for-all packed-instruction? (uses-of (cdr p))))))
                              (unless ok
                                (set! dropped #t)
                                (hashtable-delete! packed (car p)))
                              ok))
                          packs))
            (set! store-packs
                  (filter (lambda (sp)
                            (paired? (cadddr (store-form (vector-ref vec (car sp))))
                                     (cadddr (store-form (vector-ref vec (cdr sp))))))
                          store-packs))
            (when dropped (round)))))

      (collect-seeds!)
      (grow!)
      (collect-store-packs!)
      (prune!)
      (if (null? packs)
          instrs
          (emit vec n packs store-packs packed classes stats))))

  ;; Operands line up when both sides come from one pack, or both are the same
  ;; scalar -- which becomes a splat, once, feeding every pack that shares it.
  (define (lane-ok? a b paired?)
    (or (paired? a b) (eq? a b)))

  ;; --- emission ---------------------------------------------------------------

  ;; PLACEMENT IS AT THE LATER OF THE TWO, and getting it wrong is a wrong
  ;; answer rather than slow code.
  ;;
  ;; A packed operation replaces two scalar ones that sit at different points in
  ;; the block. Emitting it where the FIRST one was reads the second lane's
  ;; operands before they are computed -- nbody's velocity update stores
  ;; component 0 before component 1 is even loaded, so the packed store referred
  ;; to a value that did not exist yet and the second energy came out 4.19
  ;; instead of -0.169.
  ;;
  ;; The later position is always safe, and the argument is short: if pack Q
  ;; uses pack P then each of Q's members is defined after the corresponding
  ;; member of P, so max(Q) > max(P). Dependencies are preserved by placing
  ;; every pack at its own maximum.
  (define (emit vec n packs store-packs packed classes stats)
    (let ((name (make-eq-hashtable))     ; lo -> the packed vreg
          (splat (make-eq-hashtable))    ; scalar -> its splatted vreg
          (at (make-eqv-hashtable))      ; position -> packed instrs to emit there
          (drop (make-eqv-hashtable))
          (counter 0)
          (out '()))

      (define (fresh p)
        (set! counter (+ counter 1))
        (string->symbol
         (string-append "p2." (symbol->string p) "." (number->string counter))))

      (define (pack-name lo)
        (or (hashtable-ref name lo #f)
            (let ((v (fresh lo)))
              (hashtable-set! name lo v)
              (hashtable-set! classes v 'raw-f64)
              v)))

      (define (lo? v) (hashtable-contains? packed v))

      (define (index-of v)
        (let scan ((k 0))
          (cond ((= k n) #f)
                ((let ((i (vector-ref vec k)))
                   (and (pair? i) (>= (length i) 2) (eq? (cadr i) v)))
                 k)
                (else (scan (+ k 1))))))

      (define (emit-at! k instrs)
        (hashtable-set! at k (append (hashtable-ref at k '()) instrs)))

      ;; A scalar wanted in both lanes is splatted once, and the splat has to
      ;; land before the first pack that reads it.
      (define pending '())
      (define (operand v)
        (cond
         ((lo? v) (pack-name v))
         (else
          (or (hashtable-ref splat v #f)
              (let ((s (fresh v)))
                (hashtable-set! splat v s)
                (hashtable-set! classes s 'raw-f64)
                (set! pending (cons (list 'p2splat s 'raw-f64 v) pending))
                s)))))

      (define (plan-pack! p)
        (let* ((lo (car p)) (hi (cdr p))
               (klo (index-of lo)) (khi (index-of hi)))
          (when (and klo khi)
            (let* ((k (max klo khi))
                   (i (vector-ref vec klo))
                   (f (load-form i)))
              (hashtable-set! drop klo #t)
              (hashtable-set! drop khi #t)
              (set! pending '())
              (let ((packed-instr
                     (cond
                      (f (list 'p2load (pack-name lo) 'raw-f64
                               (caddr f) (car f) (cadr f)))
                      ((assq (car i) pack-op)
                       (list (cdr (assq (car i) pack-op)) (pack-name lo) 'raw-f64
                             (operand (cadddr i)) (operand (car (cddddr i)))))
                      (else #f))))
                (if packed-instr
                    (begin
                      (slp-stats-instructions-set!
                       stats (+ 1 (slp-stats-instructions stats)))
                      (emit-at! k (append (reverse pending) (list packed-instr))))
                    ;; Not a shape this pass emits: put the originals back.
                    (begin (hashtable-delete! drop klo)
                           (hashtable-delete! drop khi))))))))

      (define (plan-store! sp)
        (let* ((klo (car sp)) (khi (cdr sp))
               (k (max klo khi))
               (i (vector-ref vec klo))
               (f (store-form i)))
          (hashtable-set! drop klo #t)
          (hashtable-set! drop khi #t)
          (set! pending '())
          (let ((instr (list 'p2store (cadr i) 'raw-f64
                             (caddr f) (car f) (cadr f) (operand (cadddr f)))))
            (slp-stats-instructions-set!
             stats (+ 1 (slp-stats-instructions stats)))
            (emit-at! k (append (reverse pending) (list instr))))))

      ;; IN POSITION ORDER. A scalar splatted for one pack is reused by every
      ;; later pack that shares it, so the splat must be emitted at the FIRST
      ;; pack that asks -- which is only the earliest one if they are planned in
      ;; order. Out of order, a pack earlier in the block reads a splat defined
      ;; after it.
      (for-each plan-pack!
                (list-sort (lambda (a b)
                             (< (max (or (index-of (car a)) 0) (or (index-of (cdr a)) 0))
                                (max (or (index-of (car b)) 0) (or (index-of (cdr b)) 0))))
                           packs))
      (for-each plan-store!
                (list-sort (lambda (a b) (< (max (car a) (cdr a)) (max (car b) (cdr b))))
                           store-packs))

      (let loop ((k 0))
        (when (< k n)
          (unless (hashtable-ref drop k #f)
            (set! out (cons (vector-ref vec k) out)))
          (for-each (lambda (x) (set! out (cons x out)))
                    (hashtable-ref at k '()))
          (loop (+ k 1))))
      (slp-stats-packs-set! stats (+ (length packs) (slp-stats-packs stats)))
      (reverse out)))
  )
