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
  ;; PACKING PRESERVES THE CONTRACTION MARK. The `-c` spellings are the same
  ;; operations standing inside a granted `fp-contract` scope (see lang.ss), and
  ;; packing a pair of them has to produce a marked PAIR -- otherwise contract.ss
  ;; cannot fuse what this pass just packed, and the program gets one
  ;; optimisation or the other rather than both.
  ;;
  ;; That is not hypothetical. This pass ran AFTER contraction at first, so it
  ;; saw `fma` where it wanted `mul`, packed nothing, and nbody's velocity
  ;; updates went from `vsubpd`/`vmulpd` back to six scalar load/fma/store
  ;; sequences. Contraction bought 4.5 cycles instead of the 15 it should have.
  (define pack-op '((add . p2add) (sub . p2sub) (mul . p2mul) (div . p2div)
                    (add-c . p2add-c) (sub-c . p2sub-c) (mul-c . p2mul-c)))

  ;; The same, as name STEMS, so the arity is a prefix rather than a second
  ;; table that could disagree with the first.
  (define pack-op-stem '((add . "add") (sub . "sub") (mul . "mul") (div . "div")
                         (add-c . "add-c") (sub-c . "sub-c") (mul-c . "mul-c")))

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

      ;; A PACK IS A LIST OF MEMBERS IN LANE ORDER, not a cons of two.
      ;;
      ;; It was `(lo . hi)`, which put the lane count in the representation:
      ;; every `(cdr p)` in this file meant "the high member" rather than "the
      ;; remaining lanes". Three components pack as two plus one today, and the
      ;; encoder can now emit a masked 256-bit form that takes all three. This
      ;; commit changes the SHAPE only -- two members in, two members out, and
      ;; the emitted image is byte-identical.
      ;;
      ;; `(car p)` still means lane 0 everywhere, which is why most of the file
      ;; is untouched. Lane 0 is load-bearing in its own right: a packed
      ;; register's low double IS the scalar, so a scalar use of it is free.
      (define (pack-lo p) (car p))
      (define (pack-hi p) (cadr p))       ; the last lane, while packs are pairs

      (define (member-of-pack? v)
        (exists (lambda (p) (and (memq v p) #t)) packs))

      (define (no-dups? ms)
        (or (null? ms) (and (not (memq (car ms) (cdr ms))) (no-dups? (cdr ms)))))

      ;; Variadic, with the kind last, so a triple is `(add-pack! x y z 'pending)`
      ;; and the arity is not a thing to change again.
      (define (add-pack! . args)
        (let* ((r (reverse args)) (k (car r)) (ms (reverse (cdr r))))
          (and (>= (length ms) 2)
               (for-all f64v? ms)
               (no-dups? ms)
               (not (exists member-of-pack? ms))
               (for-all (lambda (m) (and (index-of m) #t)) ms)
               (begin (set! packs (cons ms packs))
                      (hashtable-set! kind ms k)
                      #t))))

      ;; N-ARY, over the pack's definitions in lane order. Two members today,
      ;; three when the seed finds a third adjacent store; the predicates say
      ;; "consecutive" and "all the same operation" rather than counting.
      (define (adjacent-loads? ds)
        (let ((fs (map (lambda (d) (and d (load-form d))) ds)))
          (and (for-all values fs)
               (let ((f0 (car fs)))
                 (let walk ((xs (cdr fs)) (off (caddr f0)))
                   (or (null? xs)
                       (and (eq? (car (car xs)) (car f0))
                            (eq? (cadr (car xs)) (cadr f0))
                            (= (caddr (car xs)) (+ off 1))
                            (walk (cdr xs) (+ off 1)))))))))

      (define (packable-op? d)
        (and d (pair? d) (assq (car d) pack-op) (= (length d) 5)
             (eq? (caddr d) 'raw-f64)))

      (define (same-op? ds)
        (and (for-all packable-op? ds)
             (for-all (lambda (d) (eq? (car d) (car (car ds)))) (cdr ds))))

      ;; The operands of a packable op, in order.
      (define (op-operands d) (list (cadddr d) (car (cddddr d))))

      ;; Classify one pack and, when it is an op pack, enqueue its operands.
      (define (classify! p)
        (let ((ds (map def-of p)))
          (cond
           ((adjacent-loads? ds) (hashtable-set! kind p 'load))
           ((same-op? ds)
            (hashtable-set! kind p 'op)
            ;; Operand lanes come from THIS pack's order, which came from a
            ;; store. At each operand position the members either all name the
            ;; same value -- a splat, which forms no pack -- or they become a
            ;; pack of their own with the same arity as this one.
            (for-each
             (lambda (pos)
               (let ((xs (map (lambda (d) (list-ref (op-operands d) pos)) ds)))
                 (unless (for-all (lambda (x) (eq? x (car xs))) (cdr xs))
                   (apply add-pack! (append xs '(pending))))))
             '(0 1)))
           (else (hashtable-set! kind p 'gather)))))

      ;; Adjacent stores whose values differ: the seed, and the only place lane
      ;; order is decided.
      ;;
      ;; THREE FIRST, THEN TWO. A body is three consecutive doubles, so the
      ;; shape worth finding is three adjacent stores; two is what is left when
      ;; the third is not there. Trying the pair first and widening later would
      ;; mean unpicking a pack that is already registered and already the
      ;; operand of others, which is the kind of state this pass has no way to
      ;; back out of.
      ;;
      ;; The index at offset d is found by scanning for a store whose offset is
      ;; d+1 and then d+2 from the SAME base and index. Nothing here proves the
      ;; three are distinct elements of one object -- adjacency of the
      ;; SUBSCRIPTS is the whole claim, and it is the claim the load and store
      ;; forms are normalised to make checkable.
      (define (store-at base idx off)
        (let scan ((k 0))
          (cond ((= k n) #f)
                ((let ((f (store-form (vector-ref vec k))))
                   (and f (eq? (car f) base) (eq? (cadr f) idx)
                        (= (caddr f) off) (f64v? (cadddr f))
                        (cons k f)))
                 => values)
                (else (scan (+ k 1))))))

      ;; THREE LANES ARE OFF, AND THE REASON IS MEASURED RATHER THAN STRUCTURAL.
      ;;
      ;; Everything below works. Turning this on packs nbody's force loop into
      ;; masked 256-bit operations, keeps both energies BIT-EXACT, and takes
      ;; instructions per step from 717.50 to 625.50 -- the 92 the bead
      ;; predicted. It also takes cycles per step from 189 to 864.
      ;;
      ;; A MASKED STORE CANNOT FORWARD TO A LATER LOAD. Measured on this Zen 5
      ;; part, a store/load round trip through the same address:
      ;;
      ;;     unmasked 256 store -> 256 load        5.65 cyc
      ;;     128-bit pair + scalar, the old shape  5.65 cyc
      ;;     masked store -> unmasked load         9.45 cyc
      ;;     masked store -> masked load          10.70 cyc
      ;;
      ;; and `ls_bad_status2.stli_other` counts 59 forwarding failures PER STEP
      ;; in the packed build, which at the ~12 cycles above is the whole
      ;; regression. IPC falls from 3.8 to 0.72. nbody's `advance` reads v[3i],
      ;; writes v[3i] and reads it again on the next pair, so it does exactly
      ;; the round trip the mask breaks, once per body per pair.
      ;;
      ;; Masked LOADS are separately 4x slower than unmasked ones (1.25 against
      ;; 0.31 cyc/iter), and mixing legacy SSE with 256-bit state costs 14% --
      ;; real, and both an order of magnitude too small to matter here.
      ;;
      ;; WHAT WOULD ACTUALLY WORK is the layout, not the mask: pad a body to
      ;; FOUR doubles and every load and store is unmasked, forwards normally,
      ;; and the index arithmetic becomes a shift instead of a multiply by
      ;; three. That is a change to how the benchmark stores its data, so it is
      ;; a question about what the matrix is comparing rather than one this
      ;; pass can answer -- `ref.c` uses three-wide arrays. Filed.
      ;;
      ;; The switch stays because that layout change is what flips it back, and
      ;; because a measurement nobody can repeat is worth nothing.
      (define three-lane-packs? #f)

      (define (collect-store-packs!)
        (let outer ((x 0))
          (when (< x n)
            (let ((fa (store-form (vector-ref vec x))))
              (when (and fa (f64v? (cadddr fa)))
                (let* ((base (car fa)) (idx (cadr fa)) (off (caddr fa))
                       (b (store-at base idx (+ off 1)))
                       (c (and b (store-at base idx (+ off 2)))))
                  (cond
                   ;; three lanes
                   ((and three-lane-packs? b c
                         (add-pack! (cadddr fa) (cadddr (cdr b)) (cadddr (cdr c))
                                    'pending))
                    (set! store-packs (cons (list x (car b) (car c)) store-packs)))
                   ;; two, which is what a body's third component being absent
                   ;; or unpackable leaves
                   ((and b (add-pack! (cadddr fa) (cadddr (cdr b)) 'pending))
                    (set! store-packs (cons (list x (car b)) store-packs)))
                   (else (values))))))
            (outer (+ x 1)))))

      ;; A TRIPLE THAT CANNOT STAND BECOMES A PAIR, not a gather.
      ;;
      ;; A gather assembles the members from values that stay where they are,
      ;; and assembling three scalars into a 256-bit register takes two
      ;; instructions -- `vunpcklpd` then `vinsertf128` -- to save the two a
      ;; triple saves. It breaks even at best, and the encoder does not have
      ;; `vinsertf128` because of that. So a triple whose members are not three
      ;; adjacent loads or three identical ops drops its last lane and is
      ;; classified again as a pair, which is exactly what this pass did before
      ;; triples existed.
      ;;
      ;; The matching store pack narrows with it. WITHOUT THAT the third store
      ;; is dropped by `plan-store!` while the value pack only ever wrote two
      ;; lanes, and the third element of every body is stored from whatever was
      ;; in the register's high half. nbody's `put!` is where it showed:
      ;;
      ;;     vmulsd    xmm8, xmm3, xmm7      vx * days-per-year
      ;;     vmulsd    xmm9, xmm4, xmm7      vy * days-per-year
      ;;     vmulsd    xmm10, xmm5, xmm7     vz * days-per-year
      ;;     vunpcklpd xmm7, xmm8, xmm9      a TWO-lane gather
      ;;     vmovupd   [rbx+rdx*8-1]{k1}, ymm7    storing THREE lanes from it
      ;;
      ;; and vz went in as whatever the 128-bit `vunpcklpd` left up there,
      ;; which is zero. The initial energy came out wrong in the fifth digit.
      ;;
      ;; RETURNS WHETHER IT NARROWED ANYTHING, because it cannot run once. The
      ;; kind it keys off is not settled after `classify-all!`: `demote!` and
      ;; `demote-unpaired!` both turn a load or op pack into a gather, and they
      ;; run later. So this is part of the fixpoint below rather than a step
      ;; before it, and it terminates because every narrowing strictly reduces
      ;; the total arity of `packs`.
      (define (narrow!)
        (let round ((ever #f))
          (let ((changed #f))
            (for-each
             (lambda (p)
               (when (and (> (length p) 2)
                          (not (memq (hashtable-ref kind p #f) '(load op))))
                 (let ((short (list (car p) (cadr p))))
                   (set! packs (cons short (remq p packs)))
                   (hashtable-set! kind short 'pending)
                   (hashtable-delete! kind p)
                   (set! store-packs
                         (map (lambda (sp)
                                (if (and (> (length sp) 2)
                                         (eq? (cadddr (store-form
                                                       (vector-ref vec (car sp))))
                                              (car p)))
                                    (list (car sp) (cadr sp))
                                    sp))
                              store-packs))
                   (set! changed #t))))
             packs)
            (cond (changed (classify-all!) (round #t))
                  (else ever)))))

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
                                  (and (memq (cadr i) p) #t)))
                           packs))
              (exists (lambda (sp) (and (memv k sp) #t)) store-packs))))

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
                 (unless (for-all block-local? p)
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
      ;; The lanes of one operand position either are all the same value -- a
      ;; splat -- or are exactly the members of some pack, in order.
      (define (lanes-together? xs)
        (or (for-all (lambda (x) (eq? x (car xs))) (cdr xs))
            (exists (lambda (q) (equal? q xs)) packs)))

      (define (demote-unpaired!)
        (let round ()
          (let ((changed #f))
            (for-each
             (lambda (p)
               (when (eq? 'op (hashtable-ref kind p #f))
                 (let ((ds (map def-of p)))
                   (when (and (for-all values ds) (for-all packable-op? ds)
                              (not (for-all
                                    (lambda (pos)
                                      (lanes-together?
                                       (map (lambda (d) (list-ref (op-operands d) pos))
                                            ds)))
                                    '(0 1))))
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
                                            (eq? (cadddr f) (pack-lo p))))
                                        store-packs)
                                (exists (lambda (q)
                                          (and (not (eq? q p))
                                               (eq? 'op (hashtable-ref kind q #f))
                                               (let ((a (def-of (pack-lo q))))
                                                 (and a (memq (pack-lo p) (cdddr a)) #t))))
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
               (let ((ds (map def-of p)))
                 (when (and (for-all values ds) (for-all packable-op? ds))
                   (for-each
                    (lambda (pos)
                      (let ((xs (map (lambda (d) (list-ref (op-operands d) pos)) ds)))
                        (when (and (for-all (lambda (x) (eq? x (car xs))) (cdr xs))
                                   (not (hashtable-ref seen (car xs) #f)))
                          (hashtable-set! seen (car xs) #t)
                          (set! m (+ m 1)))))
                    '(0 1))))))
           packs)
          m))

      ;; A load, op or store pack turns two instructions into one. A gather adds
      ;; one, and so does each splat. If the savings do not outnumber the
      ;; assembly, nothing is packed: a block half-packed at a loss is worse
      ;; than a block left alone.
      ;; One extract per pack whose HIGH member is read as a scalar. The low
      ;; member's scalar uses are free.
      ;; LANE 0 IS FREE, every other lane may cost one. A packed register's low
      ;; double IS the scalar, so a scalar use of lane 0 is a rewrite; lanes 1
      ;; and 2 each need an instruction, once, however many scalar uses they
      ;; have.
      (define (extract-count)
        (fold-left
         (lambda (acc p)
           (if (memq (hashtable-ref kind p #f) '(load op))
               (+ acc (length (filter (lambda (m) (pair? (scalar-uses m))) (cdr p))))
               acc))
         0 packs))

      ;; A PACK OF k SAVES k-1, not one. k scalar instructions become one, so a
      ;; triple is worth twice what a pair is -- which is the whole reason for
      ;; the third lane and has to be in the arithmetic, not just the comment.
      ;; A gather adds one, and so does each splat and each extract.
      (define (profitable?)
        (let* ((gathers (filter (lambda (p) (eq? 'gather (hashtable-ref kind p #f)))
                                packs))
               (real (filter (lambda (p)
                               (memq (hashtable-ref kind p #f) '(load op)))
                             packs))
               (savings (+ (fold-left (lambda (a p) (+ a (- (length p) 1))) 0 real)
                           (fold-left (lambda (a sp) (+ a (- (length sp) 1))) 0
                                      store-packs)))
               (costs (+ (length gathers) (splat-count) (extract-count))))
          (> savings costs)))

      (collect-store-packs!)
      (classify-all!)
      ;; ONE FIXPOINT, and the order inside it is not free. Each of these can
      ;; undo the premise of the others: demoting a pack to a gather can leave a
      ;; triple that must narrow, narrowing re-classifies and can unpair an op
      ;; pack above it, and pruning can remove a pack an op pack was relying on
      ;; for its operands. Running them once in sequence leaves whichever
      ;; happens to be last holding a stale answer -- which is exactly how a
      ;; three-lane store came to be fed by a two-lane gather.
      (let settle ()
        (demote!)
        (demote-unpaired!)
        (prune-unreachable!)
        (demote-unpaired!)
        (when (narrow!) (settle)))
      (if (or (null? packs) (not (profitable?)))
          instrs
          (emit vec n packs store-packs kind consumed? classes stats))))

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
          (splat (make-hashtable equal-hash equal?))
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
         (string-append "p." (symbol->string p) "." (number->string counter))))

      ;; A pack is a LIST of members in lane order; `(car p)` is lane 0.
      (define (pack-lo p) (car p))
      (define (pack-hi p) (cadr p))       ; the last lane, while packs are pairs

      (define (pack-of v)
        (let scan ((ps packs))
          (cond ((null? ps) #f)
                ((eq? (pack-lo (car ps)) v) (car ps))
                (else (scan (cdr ps))))))

      (define (pack-name p)
        (or (hashtable-ref name (pack-lo p) #f)
            (let ((v (fresh (pack-lo p))))
              (hashtable-set! name (pack-lo p) v)
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

      ;; The op name for an arity. Two lanes and three lanes are DIFFERENT
      ;; INSTRUCTIONS rather than one with a parameter -- see lang.ss -- and the
      ;; splat is not even the same operation: `vmovddup` duplicates within each
      ;; 128-bit half, which is (a,a,c,c) on a triple.
      (define (arith-name lanes mach-op)
        (string->symbol
         (string-append "p" (number->string lanes)
                        (cdr (assq mach-op pack-op-stem)))))

      (define pending '())
      (define extracts '())
      ;; A SPLAT'S WIDTH IS ITS READER'S. The same scalar feeding a pair and a
      ;; triple needs two different instructions, so the table is keyed by both.
      (define (operand v lanes)
        (let ((p (pack-of v)))
          (cond
           (p (pack-name p))
           (else
            (let ((key (cons v lanes)))
              (or (hashtable-ref splat key #f)
                  (let ((s (fresh v)))
                    (hashtable-set! splat key s)
                    (hashtable-set! classes s 'raw-f64)
                    (set! pending
                          (cons (list (if (= lanes 2) 'p2splat 'p3splat) s 'raw-f64 v)
                                pending))
                    s)))))))

      ;; The instruction that reads lane `j` of a pack as a scalar. Lane 0 never
      ;; reaches here -- it is free. Lane 1 is `p2hi` WHATEVER THE ARITY: a
      ;; ymm's low 128 bits are the xmm of the same number, so the pair's
      ;; extract reads a triple's lane 1 without knowing it is one. Only lane 2
      ;; has an instruction of its own.
      (define (lane-extract j)
        (case j ((1) 'p2hi) ((2) 'p3lane2)
          (else (error 'slp "no extract for this lane" j))))

      (define (plan-pack! p)
        (let* ((ks (map index-of p))
               (k (apply max ks))
               (lanes (length p))
               (i (vector-ref vec (car ks)))
               (kd (hashtable-ref kind p #f)))
          ;; A GATHER assembles a pack from values that stay where they are, so
          ;; no member is dropped: their scalar forms are still read, which is
          ;; the whole reason the kind exists.
          (unless (eq? kd 'gather)
            (for-each (lambda (kk) (hashtable-set! drop kk #t)) ks))
          (set! pending '())
          ;; LANE 0 IS FREE: a scalar use of the low member is rewritten to name
          ;; the pack and reads the same bits. Every other lane costs one
          ;; extract, once, and it must come AFTER the instruction that defines
          ;; the pack -- splats go before their reader, extracts after theirs,
          ;; and both for the same reason.
          (set! extracts '())
          (when (memq kd '(load op))
            (hashtable-set! subst (car p) (pack-name p))
            (let walk ((ms (cdr p)) (j 1))
              (unless (null? ms)
                (when (pair? (filter (lambda (u) (not (consumed? u)))
                                     (uses-in vec n (car ms))))
                  (let ((x (fresh (car ms))))
                    (hashtable-set! classes x 'raw-f64)
                    (hashtable-set! subst (car ms) x)
                    (set! extracts
                          (append extracts
                                  (list (list (lane-extract j) x 'raw-f64
                                              (pack-name p)))))))
                (walk (cdr ms) (+ j 1)))))
          (let ((instr
                 (case kd
                   ;; A gather is only ever a pair: assembling three scalars
                   ;; into a 256-bit register costs two instructions to save
                   ;; two, so `narrow!` sends a triple back to a pair before it
                   ;; can get here.
                   ((gather) (list 'p2pack (pack-name p) 'raw-f64 (car p) (cadr p)))
                   ((load)
                    (let ((f (load-form i)))
                      (list (if (= lanes 2) 'p2load 'p3load)
                            (pack-name p) 'raw-f64 (caddr f) (car f) (cadr f))))
                   ((op)
                    (list (arith-name lanes (car i)) (pack-name p) 'raw-f64
                          (operand (cadddr i) lanes)
                          (operand (car (cddddr i)) lanes)))
                   (else #f))))
            (if instr
                (begin
                  (slp-stats-instructions-set!
                   stats (+ 1 (slp-stats-instructions stats)))
                  (emit-at! k (append (reverse pending) (list instr) extracts)))
                (for-each (lambda (kk) (hashtable-delete! drop kk)) ks)))))

      (define (plan-store! sp)
        (let* ((k (apply max sp))
               (lanes (length sp))
               (i (vector-ref vec (car sp)))
               (f (store-form i)))
          (for-each (lambda (kk) (hashtable-set! drop kk #t)) sp)
          (set! pending '())
          (let ((instr (list (if (= lanes 2) 'p2store 'p3store) (cadr i) 'raw-f64
                             (caddr f) (car f) (cadr f)
                             (operand (cadddr f) lanes))))
            (slp-stats-instructions-set!
             stats (+ 1 (slp-stats-instructions stats)))
            (emit-at! k (append (reverse pending) (list instr))))))

      ;; IN POSITION ORDER, so a scalar splatted for one pack is emitted at the
      ;; FIRST pack that asks. Out of order, an earlier pack reads a splat
      ;; defined after it.
      (for-each plan-pack!
                (list-sort (lambda (a b)
                             (< (apply max (map index-of a))
                                (apply max (map index-of b))))
                           packs))
      (for-each plan-store!
                (list-sort (lambda (a b) (< (apply max a) (apply max b)))
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
