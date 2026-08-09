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
;;; ## LANE 0 IS THE SCALAR
;;;
;;; A packed register's low double IS the scalar value, bit for bit, and every
;;; scalar instruction reads exactly that. So a scalar use of a pack's LOW
;;; member costs NOTHING: the use is rewritten to name the pack and gets the
;;; same bits it always did. Only the HIGH member needs an instruction, and only
;;; one however many scalar uses it has.
;;;
;;; That is what lets nbody's dx and dy be loaded and subtracted PACKED while
;;; still being squared scalar into the reduction. The alternative -- all uses
;;; or no pack -- unravelled the chain at the square, and because classify! does
;;; not descend through an assembled pair, the packed loads of p[] beneath it
;;; were never even considered.
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

  ;; SEEDED FROM STORES, GROWN BACKWARD.
  ;;
  ;; Lane order has to be anchored by MEMORY, and this is why. Growing forward
  ;; from loads and pairing any two identical operations lets the pass match
  ;; instructions that have nothing to do with each other -- the "lanes" then
  ;; mean nothing and the stores write the components in the wrong order. Two
  ;; ADJACENT STORES fix which value is lane 0 and which is lane 1, and every
  ;; pack upstream inherits that order from the one below it.
  ;;
  ;; At each pack the members' definitions decide what kind it is:
  ;;
  ;;   adjacent loads          a packed load, and growth stops
  ;;   identical packable ops  a packed op, and growth continues to its operands
  ;;   anything else           a GATHER: the two scalars stay where they are and
  ;;                           one instruction assembles them
  ;;
  ;; A packed op DELETES the scalar form of its members, so it is only legal if
  ;; every use of both is itself packed. When that fails the pack is DEMOTED to
  ;; a gather rather than dropped -- the scalars are still there, so assembling
  ;; them is always available. That demotion is what lets nbody's `dx` be
  ;; squared into a reduction and multiplied beside `dy` at the same time.
  (define (slp-block instrs classes stats guses)
    (let* ((n (length instrs))
           (vec (list->vector instrs))
           (packs '())                     ; ((lo . hi) ...), lane order
           (kind (make-hashtable equal-hash equal?))
           (store-packs '()))

      (define (index-of v)
        (let scan ((k 0))
          (cond ((= k n) #f)
                ((let ((i (vector-ref vec k)))
                   (and (pair? i) (>= (length i) 2) (eq? (cadr i) v)))
                 k)
                (else (scan (+ k 1))))))

      (define (def-of v)
        (let ((k (index-of v))) (and k (vector-ref vec k))))

      (define (f64v? v)
        (and (symbol? v) (eq? (hashtable-ref classes v #f) 'raw-f64)))

      (define (member-of-pack? v)
        (exists (lambda (p) (or (eq? (car p) v) (eq? (cdr p) v))) packs))

      (define (add-pack! lo hi k)
        (and (f64v? lo) (f64v? hi) (not (eq? lo hi))
             (not (member-of-pack? lo)) (not (member-of-pack? hi))
             (index-of lo) (index-of hi)
             (begin (set! packs (cons (cons lo hi) packs))
                    (hashtable-set! kind (cons lo hi) k)
                    #t)))

      (define (adjacent-loads? a b)
        (let ((da (and a (load-form a))) (db (and b (load-form b))))
          (and da db (eq? (car da) (car db)) (eq? (cadr da) (cadr db))
               (= (+ (caddr da) 1) (caddr db)))))

      (define (same-op? a b)
        (and a b (pair? a) (pair? b) (eq? (car a) (car b))
             (assq (car a) pack-op) (= (length a) 5) (= (length b) 5)
             (eq? (caddr a) 'raw-f64) (eq? (caddr b) 'raw-f64)))

      ;; Classify one pack and, when it is an op pack, enqueue its operands.
      (define (classify! p)
        (let* ((lo (car p)) (hi (cdr p))
               (a (def-of lo)) (b (def-of hi)))
          (cond
           ((adjacent-loads? a b) (hashtable-set! kind p 'load))
           ((same-op? a b)
            (hashtable-set! kind p 'op)
            ;; Operand lanes come from THIS pack's order, which came from a
            ;; store. Equal operands are a splat and form no pack.
            (for-each (lambda (x y) (unless (eq? x y) (add-pack! x y 'pending)))
                      (list (cadddr a) (car (cddddr a)))
                      (list (cadddr b) (car (cddddr b)))))
           (else (hashtable-set! kind p 'gather)))))

      ;; Adjacent stores whose values differ: the seed, and the only place lane
      ;; order is decided.
      (define (collect-store-packs!)
        (let outer ((x 0))
          (when (< x n)
            (let ((fa (store-form (vector-ref vec x))))
              (when fa
                (let inner ((y 0))
                  (when (< y n)
                    (let ((fb (store-form (vector-ref vec y))))
                      (when (and fb (not (= x y))
                                 (eq? (car fa) (car fb))
                                 (eq? (cadr fa) (cadr fb))
                                 (= (+ (caddr fa) 1) (caddr fb))
                                 (f64v? (cadddr fa)) (f64v? (cadddr fb)))
                        (when (add-pack! (cadddr fa) (cadddr fb) 'pending)
                          (set! store-packs (cons (cons x y) store-packs)))))
                    (inner (+ y 1))))))
            (outer (+ x 1)))))

      (define (classify-all!)
        (let round ()
          (let ((pending (filter (lambda (p) (eq? 'pending (hashtable-ref kind p #f)))
                                 packs)))
            (unless (null? pending)
              (for-each classify! pending)
              (round)))))

      (define (uses-of v)
        (let count ((k 0) (acc '()))
          (if (= k n)
              (reverse acc)
              (count (+ k 1)
                     (if (and (pair? (vector-ref vec k))
                              (memq v (cddr (vector-ref vec k))))
                         (cons k acc)
                         acc)))))

      ;; OCCURRENCES, not instructions, because `guses` counts occurrences.
      ;;
      ;; `uses-of` returns one entry per INSTRUCTION mentioning v, and the
      ;; global table counts every operand slot. `(mul t dx dx)` is one
      ;; instruction and two occurrences, so the two never agreed for a value
      ;; used twice by one operation -- and nbody squares dx exactly that way.
      ;; Every such value looked like it escaped the block.
      (define (local-occurrences v)
        (let count ((k 0) (acc 0))
          (if (= k n)
              acc
              (count (+ k 1)
                     (+ acc (let ((i (vector-ref vec k)))
                              (if (pair? i)
                                  (length (filter (lambda (x) (eq? x v)) (cddr i)))
                                  0)))))))

      (define (block-local? v)
        (= (local-occurrences v) (hashtable-ref guses v 0)))

      ;; Is instruction k replaced by a pack? Only load and op packs replace
      ;; their members; a gather leaves them.
      (define (consumed? k)
        (let ((i (vector-ref vec k)))
          (or (and (pair? i) (>= (length i) 2) (symbol? (cadr i))
                   (exists (lambda (p)
                             (and (memq (hashtable-ref kind p #f) '(load op))
                                  (or (eq? (car p) (cadr i)) (eq? (cdr p) (cadr i)))))
                           packs))
              (exists (lambda (sp) (or (= k (car sp)) (= k (cdr sp)))) store-packs))))

      ;; A SCALAR USE OF A PACKED VALUE IS NOT ALWAYS AN EXTRACT.
      ;;
      ;; Lane 0 of a packed register IS the scalar, bit for bit -- every scalar
      ;; instruction reads exactly the low double -- so a scalar use of the LOW
      ;; member costs nothing: the use is rewritten to name the pack and reads
      ;; the same bits it always did. Only the HIGH member needs an instruction,
      ;; and only one however many scalar uses it has.
      ;;
      ;; That is what lets nbody's dx and dy be loaded and subtracted PACKED
      ;; while still being squared scalar into the reduction. Before it, the
      ;; square demoted the pair to an assembled one -- and because classify!
      ;; does not descend through a gather, the packed LOADS of p[] beneath it
      ;; were never even considered.
      (define (scalar-uses v) (filter (lambda (k) (not (consumed? k))) (uses-of v)))

      ;; DEMOTE rather than drop. A load or op pack deletes the scalar form of
      ;; its members and rewrites their uses, and this pass rewrites only within
      ;; a block -- so a member read from another block sends the pack back to
      ;; being assembled, where both scalars survive untouched.
      (define (demote!)
        (let round ()
          (let ((changed #f))
            (for-each
             (lambda (p)
               (when (memq (hashtable-ref kind p #f) '(load op))
                 (unless (and (block-local? (car p)) (block-local? (cdr p)))
                   (hashtable-set! kind p 'gather)
                   (set! changed #t))))
             packs)
            (when changed (round)))))

      ;; AN OP PACK WHOSE OPERANDS ARE NOT PAIRED COMPUTES THE WRONG ANSWER.
      ;;
      ;; `plan-pack!` builds an op pack's operands from the LOW member's
      ;; instruction and calls `operand` on each, which yields the pack holding
      ;; that value or, failing that, a SPLAT of it. A splat puts the low
      ;; member's operand in both lanes, which is right only when the high
      ;; member's operand at that position is the same value.
      ;;
      ;; `classify!` enqueues the differing pairs so they become packs, and
      ;; DISCARDS THE RESULT -- `add-pack!` refuses a pair whose members have no
      ;; defining instruction in this block, which is every parameter and every
      ;; value from another block. nbody's `put!` multiplies vx and vy by the
      ;; same `days-per-year`, and vx and vy are parameters: the pair could not
      ;; be packed, nothing noticed, and the emitted code splatted vx into both
      ;; lanes and stored vx*dpy into vel[3i+1] where vy*dpy belonged.
      ;;
      ;; It was reachable only through a CSE fold that made the two reads of
      ;; `days-per-year` one vreg -- which is what put the pack in the
      ;; shared-scalar shape at all -- so it presented as "exempting tagged
      ;; global reads from CSE is unsound" and was recorded that way for a day.
      ;;
      ;; So: an op pack survives only if, at every operand position, the two
      ;; members either name the SAME value or are packed together. Demoted to a
      ;; gather otherwise, which assembles both scalars and reads them
      ;; untouched. A fixpoint, because demoting one pack can unpair another.
      (define (paired? x y)
        (or (eq? x y)
            (exists (lambda (q) (and (eq? (car q) x) (eq? (cdr q) y))) packs)))

      (define (demote-unpaired!)
        (let round ()
          (let ((changed #f))
            (for-each
             (lambda (p)
               (when (eq? 'op (hashtable-ref kind p #f))
                 (let ((a (def-of (car p))) (b (def-of (cdr p))))
                   (when (and a b
                              (not (and (paired? (cadddr a) (cadddr b))
                                        (paired? (car (cddddr a))
                                                 (car (cddddr b))))))
                     (hashtable-set! kind p 'gather)
                     (set! changed #t)))))
             packs)
            (when changed (round)))))

      ;; A pack nothing reads is pure cost. Reachability runs from the stores.
      (define (prune-unreachable!)
        (let round ()
          (let ((changed #f))
            (set! packs
                  (filter
                   (lambda (p)
                     (let ((keep
                            (or (exists (lambda (sp)
                                          (let ((f (store-form (vector-ref vec (car sp)))))
                                            (eq? (cadddr f) (car p))))
                                        store-packs)
                                (exists (lambda (q)
                                          (and (not (eq? q p))
                                               (eq? 'op (hashtable-ref kind q #f))
                                               (let ((a (def-of (car q))))
                                                 (and a (memq (car p) (cdddr a)) #t))))
                                        packs))))
                       (unless keep (set! changed #t))
                       keep))
                   packs))
            (when changed (round)))))

      (define (splat-count)
        (let ((seen (make-eq-hashtable)) (m 0))
          (for-each
           (lambda (p)
             (when (eq? 'op (hashtable-ref kind p #f))
               (let ((a (def-of (car p))) (b (def-of (cdr p))))
                 (when (and a b)
                   (for-each (lambda (x y)
                               (when (and (eq? x y) (not (hashtable-ref seen x #f)))
                                 (hashtable-set! seen x #t)
                                 (set! m (+ m 1))))
                             (list (cadddr a) (car (cddddr a)))
                             (list (cadddr b) (car (cddddr b))))))))
           packs)
          m))

      ;; A load, op or store pack turns two instructions into one. A gather adds
      ;; one, and so does each splat. If the savings do not outnumber the
      ;; assembly, nothing is packed: a block half-packed at a loss is worse
      ;; than a block left alone.
      ;; One extract per pack whose HIGH member is read as a scalar. The low
      ;; member's scalar uses are free.
      (define (extract-count)
        (length (filter (lambda (p)
                          (and (memq (hashtable-ref kind p #f) '(load op))
                               (pair? (scalar-uses (cdr p)))))
                        packs)))

      (define (profitable?)
        (let* ((gathers (length (filter (lambda (p) (eq? 'gather (hashtable-ref kind p #f)))
                                        packs)))
               (savings (+ (- (length packs) gathers) (length store-packs)))
               (costs (+ gathers (splat-count) (extract-count))))
          (> savings costs)))

      (collect-store-packs!)
      (classify-all!)
      (demote!)
      (demote-unpaired!)
      (prune-unreachable!)
      ;; Pruning can remove a pack an op pack was relying on for its operands,
      ;; so the pairing question has to be asked again after it.
      (demote-unpaired!)
      (if (or (null? packs) (not (profitable?)))
          instrs
          (emit vec n packs store-packs kind consumed? classes stats))))

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
  ;; PLACEMENT IS AT THE LATER OF THE TWO, and getting it wrong is a wrong
  ;; answer rather than slow code.
  ;;
  ;; A packed operation replaces two scalar ones that sit at different points in
  ;; the block. Emitting it where the FIRST one was reads the second lane's
  ;; operands before they are computed -- nbody's velocity update stores
  ;; component 0 before component 1 is even loaded. The later position is always
  ;; safe: if pack Q uses pack P then each member of Q is defined after the
  ;; corresponding member of P, so max(Q) > max(P).
  ;; Uses of v among the block's instructions, by index.
  (define (uses-in vec n v)
    (let count ((k 0) (acc '()))
      (if (= k n)
          (reverse acc)
          (count (+ k 1)
                 (if (and (pair? (vector-ref vec k))
                          (memq v (cddr (vector-ref vec k))))
                     (cons k acc)
                     acc)))))

  (define (emit vec n packs store-packs kind consumed? classes stats)
    (let ((name (make-eq-hashtable))
          (splat (make-eq-hashtable))
          (at (make-eqv-hashtable))
          (drop (make-eqv-hashtable))
          (counter 0)
          (out '()))

      (define (index-of v)
        (let scan ((k 0))
          (cond ((= k n) #f)
                ((let ((i (vector-ref vec k)))
                   (and (pair? i) (>= (length i) 2) (eq? (cadr i) v)))
                 k)
                (else (scan (+ k 1))))))

      (define (fresh p)
        (set! counter (+ counter 1))
        (string->symbol
         (string-append "p2." (symbol->string p) "." (number->string counter))))

      (define (pack-of v)
        (let scan ((ps packs))
          (cond ((null? ps) #f) ((eq? (caar ps) v) (car ps)) (else (scan (cdr ps))))))

      (define (pack-name p)
        (or (hashtable-ref name (car p) #f)
            (let ((v (fresh (car p))))
              (hashtable-set! name (car p) v)
              (hashtable-set! classes v 'raw-f64)
              v)))

      (define (emit-at! k is)
        (hashtable-set! at k (append (hashtable-ref at k '()) is)))

      ;; A scalar use of a packed member is REWRITTEN, not extracted, where it
      ;; can be. `subst` maps the member's name to whatever now holds its value:
      ;; the pack itself for lane 0, an extract for lane 1.
      (define subst (make-eq-hashtable))
      (define (rewrite i)
        (if (pair? i)
            (cons (car i)
                  (let walk ((xs (cdr i)) (k 0))
                    (cond
                     ((null? xs) '())
                     ;; slot 0 is the destination on every shape reaching here
                     ((= k 0) (cons (car xs) (walk (cdr xs) 1)))
                     ((and (symbol? (car xs)) (hashtable-ref subst (car xs) #f))
                      => (lambda (r) (cons r (walk (cdr xs) (+ k 1)))))
                     (else (cons (car xs) (walk (cdr xs) (+ k 1)))))))
            i))

      (define pending '())
      (define extracts '())
      (define (operand v)
        (let ((p (pack-of v)))
          (cond
           (p (pack-name p))
           (else
            (or (hashtable-ref splat v #f)
                (let ((s (fresh v)))
                  (hashtable-set! splat v s)
                  (hashtable-set! classes s 'raw-f64)
                  (set! pending (cons (list 'p2splat s 'raw-f64 v) pending))
                  s))))))

      (define (plan-pack! p)
        (let* ((lo (car p)) (hi (cdr p))
               (klo (index-of lo)) (khi (index-of hi))
               (k (max klo khi))
               (i (vector-ref vec klo))
               (o (vector-ref vec khi))
               (kd (hashtable-ref kind p #f)))
          ;; A GATHER assembles a pair from values that stay where they are, so
          ;; neither member is dropped: their scalar forms are still read, which
          ;; is the whole reason the kind exists.
          (unless (eq? kd 'gather)
            (hashtable-set! drop klo #t)
            (hashtable-set! drop khi #t))
          (set! pending '())
          ;; LANE 0 IS FREE: a scalar use of the low member is rewritten to name
          ;; the pack and reads the same bits. The high member costs one extract,
          ;; once, and it must come AFTER the instruction that defines the pack
          ;; -- splats go before their reader, extracts after theirs, and both
          ;; for the same reason.
          (set! extracts '())
          (when (memq kd '(load op))
            (hashtable-set! subst lo (pack-name p))
            (when (pair? (filter (lambda (u) (not (consumed? u))) (uses-in vec n hi)))
              (let ((x (fresh hi)))
                (hashtable-set! classes x 'raw-f64)
                (hashtable-set! subst hi x)
                (set! extracts (list (list 'p2hi x 'raw-f64 (pack-name p)))))))
          (let ((instr
                 (case kd
                   ((gather) (list 'p2pack (pack-name p) 'raw-f64 lo hi))
                   ((load)
                    (let ((f (load-form i)))
                      (list 'p2load (pack-name p) 'raw-f64 (caddr f) (car f) (cadr f))))
                   ((op)
                    (list (cdr (assq (car i) pack-op)) (pack-name p) 'raw-f64
                          (operand (cadddr i)) (operand (car (cddddr i)))))
                   (else #f))))
            (if instr
                (begin
                  (slp-stats-instructions-set!
                   stats (+ 1 (slp-stats-instructions stats)))
                  (emit-at! k (append (reverse pending) (list instr) extracts)))
                (begin (hashtable-delete! drop klo)
                       (hashtable-delete! drop khi))))))

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

      ;; IN POSITION ORDER, so a scalar splatted for one pack is emitted at the
      ;; FIRST pack that asks. Out of order, an earlier pack reads a splat
      ;; defined after it.
      (for-each plan-pack!
                (list-sort (lambda (a b)
                             (< (max (index-of (car a)) (index-of (cdr a)))
                                (max (index-of (car b)) (index-of (cdr b)))))
                           packs))
      (for-each plan-store!
                (list-sort (lambda (a b) (< (max (car a) (cdr a)) (max (car b) (cdr b))))
                           store-packs))

      (let loop ((k 0))
        (when (< k n)
          (unless (hashtable-ref drop k #f)
            (set! out (cons (rewrite (vector-ref vec k)) out)))
          (for-each (lambda (x) (set! out (cons x out))) (hashtable-ref at k '()))
          (loop (+ k 1))))
      (slp-stats-packs-set! stats (+ (length packs) (slp-stats-packs stats)))
      (reverse out)))
  )
