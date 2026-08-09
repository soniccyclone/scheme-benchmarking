;;; Superword-level parallelism: packing adjacent scalar work into pairs.
;;;
;;; Both halves are asserted throughout, because a vectorizer that is merely
;;; correct is easy and one that merely fires is dangerous. Every check that
;;; something PACKS is paired with one that something else does NOT.
;;;
;;; The refusals are the interesting ones. A horizontal combination of two lanes
;;; is reassociation, which D24 forbids; a value read in another block loses its
;;; scalar form if packed; and a chain whose assembly costs more than it saves
;;; is left alone entirely, because a block half-packed at a loss is worse than
;;; a block untouched.

(import (chezscheme) (nanopass)
        (sonic lang) (sonic slp)
        (sonic read) (sonic expand) (sonic parse) (sonic policy)
        (sonic anf) (sonic assign) (sonic inline) (sonic essa)
        (sonic driver) (sonic pipeline))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define (classes-for . vs)
  (let ((h (make-eq-hashtable)))
    (for-each (lambda (v) (hashtable-set! h v 'raw-f64)) vs)
    h))

(define (run prog cls)
  (let-values (((p st) (slp-program prog cls)))
    (values (cadr (cadr (car (cadr p)))) st)))

;; --- the shape that packs ---------------------------------------------------
;;
;; Two adjacent loads, one identical operation on them, one adjacent store pair.
;; Everything is used exactly once and inside the chain, so nothing needs an
;; extract and the whole thing collapses.
(define straight
  '(program ((entry (block ((load    a0 raw-f64 p i)
                            (load-at a1 raw-f64 1 p i)
                            (load    b0 raw-f64 q i)
                            (load-at b1 raw-f64 1 q i)
                            (sub     c0 raw-f64 a0 b0)
                            (sub     c1 raw-f64 a1 b1)
                            (store    z raw-f64 r i c0)
                            (store-at z2 raw-f64 1 r i c1))
                           (ret z))))
     entry))

(let-values (((is st) (run straight (classes-for 'a0 'a1 'b0 'b1 'c0 'c1))))
  (ck! "adjacent loads, one op and adjacent stores collapse to packed form"
       (equal? (map car is) '(p2load p2load p2sub p2store)))
  (ck! "and the pass reports the packs it made"
       (> (slp-stats-packs st) 0)))

;; --- LANE 0 IS THE SCALAR ---------------------------------------------------
;;
;; `c0` is read by a horizontal add, which cannot pack. That does NOT unravel
;; the chain, because lane 0 of a packed register IS the scalar, bit for bit --
;; the add is rewritten to read the pack itself and gets the same bits. Only
;; `c1`, the high lane, costs an instruction, and only one however many scalar
;; uses it has.
(define escaping
  '(program ((entry (block ((load    a0 raw-f64 p i)
                            (load-at a1 raw-f64 1 p i)
                            (load    b0 raw-f64 q i)
                            (load-at b1 raw-f64 1 q i)
                            (sub     c0 raw-f64 a0 b0)
                            (sub     c1 raw-f64 a1 b1)
                            (add     d  raw-f64 c0 c1)
                            (store    z raw-f64 r i c0)
                            (store-at z2 raw-f64 1 r i c1))
                           (ret d))))
     entry))

(let-values (((is st) (run escaping (classes-for 'a0 'a1 'b0 'b1 'c0 'c1 'd))))
  (ck! "a scalar use of the LOW lane costs nothing: the chain still packs"
       (equal? (map car is) '(p2load p2load p2sub p2hi add p2store)))
  ;; Nine instructions become six, and the one added is the extract.
  (ck! "exactly one extract, for the high lane only"
       (= 1 (length (filter (lambda (i) (eq? (car i) 'p2hi)) is)))))

;; THE REDUCTION IS THE CASE THAT MATTERS. `(add d c0 c1)` reads both lanes into
;; one scalar, which is a horizontal add -- reassociation, which D24 forbids and
;; which the bit-exact oracle would catch. Asserting it here means the refusal
;; is a property of the pass rather than an accident of the example above.
(ck! "specifically: a horizontal combination of the two lanes is never packed"
     (let-values (((is st) (run escaping (classes-for 'a0 'a1 'b0 'b1 'c0 'c1 'd))))
       (not (exists (lambda (i) (eq? (car i) 'p2add)) is))))

;; And it reads the PACK for lane 0 and the EXTRACT for lane 1, rather than two
;; scalars that no longer exist.
(ck! "the reduction reads the pack's low lane directly and the extract for the high"
     (let-values (((is st) (run escaping (classes-for 'a0 'a1 'b0 'b1 'c0 'c1 'd))))
       (let ((a (car (filter (lambda (i) (eq? (car i) 'add)) is)))
             (pk (cadr (car (filter (lambda (i) (eq? (car i) 'p2sub)) is))))
             (hi (cadr (car (filter (lambda (i) (eq? (car i) 'p2hi)) is)))))
         (equal? (cdddr a) (list pk hi)))))

;; --- a value live out of the block ------------------------------------------
;;
;; Block-local use counts are not enough: a value packed here still has its
;; scalar form read elsewhere, and packing deletes that form. The count is
;; taken over the whole program for exactly this reason.
(define escapes-block
  '(program ((entry (block ((load    a0 raw-f64 p i)
                            (load-at a1 raw-f64 1 p i)
                            (load    b0 raw-f64 q i)
                            (load-at b1 raw-f64 1 q i)
                            (sub     c0 raw-f64 a0 b0)
                            (sub     c1 raw-f64 a1 b1)
                            (store    z raw-f64 r i c0)
                            (store-at z2 raw-f64 1 r i c1))
                           (jump other)))
              (other (block ((move w raw-f64 c0)) (ret w))))
     entry))

(let-values (((p st) (slp-program escapes-block
                                  (classes-for 'a0 'a1 'b0 'b1 'c0 'c1 'w))))
  (ck! "a value read in ANOTHER block is not packed"
       (not (exists (lambda (i) (eq? (car i) 'p2sub))
                    (cadr (cadr (car (cadr p))))))))

;; --- nbody's velocity update, end to end ------------------------------------
;;
;; `c0` is read by a horizontal add AND flows into a store pack, which is the
;; shape that used to force an assembled pair. With lane 0 free the whole chain
;; packs: two packed loads, a packed subtract, ONE extract for the high lane,
;; one splat for the shared scalar, then packed multiply, load, subtract and
;; store. Fifteen instructions become ten.
(define demotes
  '(program ((entry (block ((load    a0 raw-f64 p i)
                            (load-at a1 raw-f64 1 p i)
                            (load    b0 raw-f64 q i)
                            (load-at b1 raw-f64 1 q i)
                            (sub     c0 raw-f64 a0 b0)
                            (sub     c1 raw-f64 a1 b1)
                            (mul     e0 raw-f64 c0 m)
                            (mul     e1 raw-f64 c1 m)
                            (load    f0 raw-f64 v i)
                            (load-at f1 raw-f64 1 v i)
                            (sub     g0 raw-f64 f0 e0)
                            (sub     g1 raw-f64 f1 e1)
                            (store    z raw-f64 v i g0)
                            (store-at z2 raw-f64 1 v i g1)
                            (add      d raw-f64 c0 c1))
                           (ret d))))
     entry))

(let-values (((is st) (run demotes (classes-for 'a0 'a1 'b0 'b1 'c0 'c1
                                                'e0 'e1 'f0 'f1 'g0 'g1 'm 'd))))
  (ck! "the whole chain packs, and nothing has to be assembled"
       (and (equal? (map car is)
                    '(p2load p2load p2sub p2hi p2splat p2mul p2load p2sub p2store add))
            (not (exists (lambda (i) (eq? (car i) 'p2pack)) is))))
  (ck! "the scalar operand shared by both lanes is splatted once"
       (= 1 (length (filter (lambda (i) (eq? (car i) 'p2splat)) is))))
  ;; The reduction survives as a SCALAR add -- packing it would be a horizontal
  ;; combination, which is reassociation -- reading the pack's low lane and the
  ;; one extract.
  (ck! "and the reduction is still scalar, over the pack and its extract"
       (let ((a (car (filter (lambda (i) (eq? (car i) 'add)) is))))
         (and (= 5 (length a)) (eq? (car a) 'add)))))

;; --- an op pack whose operands cannot be paired ------------------------------
;;
;; `plan-pack!` builds an op pack's operands from the LOW member's instruction
;; and splats any that are not themselves in a pack. A splat puts one value in
;; both lanes, which is right ONLY when the high member names the same value
;; there.
;;
;; `classify!` enqueues the differing pairs so they become packs and discards
;; the result -- and `add-pack!` refuses a pair whose members have no defining
;; instruction in this block, which is every parameter. Here `vx` and `vy` are
;; parameters multiplied by a shared `m`: the pair cannot be packed, and before
;; `demote-unpaired!` nothing noticed, so vx was splatted into both lanes and
;; vx*m was stored where vy*m belonged.
;;
;; This is nbody's `put!` exactly, and it presented for a day as "exempting
;; tagged global reads from CSE is unsound" -- because folding two reads of one
;; global into a single vreg is what puts the pack into this shape at all.
(define unpairable
  '(program ((entry (block ((mul e0 raw-f64 vx m)
                            (mul e1 raw-f64 vy m)
                            (store    z raw-f64 r i e0)
                            (store-at z2 raw-f64 1 r i e1))
                           (ret z))))
     entry))

(let-values (((is st) (run unpairable (classes-for 'e0 'e1 'vx 'vy 'm))))
  (ck! "an op pack whose operands cannot be paired is NOT emitted as a pack"
       (not (exists (lambda (i) (eq? (car i) 'p2mul)) is)))
  ;; The scalar multiplies must survive intact, each reading its own operand.
  (ck! "both multiplies survive, and each keeps its own first operand"
       (let ((ms (filter (lambda (i) (eq? (car i) 'mul)) is)))
         (and (= 2 (length ms))
              (eq? 'vx (cadddr (car ms)))
              (eq? 'vy (cadddr (cadr ms))))))
  ;; The failure this guards is silent: with the splat in place the program is
  ;; shorter and wrong, so a count alone would have called it an improvement.
  (ck! "and nothing is splatted, which is what put the wrong value in lane 1"
       (not (exists (lambda (i) (eq? (car i) 'p2splat)) is))))

;; --- nbody ------------------------------------------------------------------
;;
;; The measurement that justifies the pass. `dx` is read by `dx*dx`, which feeds
;; the reduction and cannot pack, and by `dx*mj`, which can. Assembling the pair
;; costs one instruction and buys the two velocity updates, which are three
;; identical load/mul/sub/store sequences twice over.
(let* ((c (compile-sonic "../bench/nbody/config-sonic.sps" nbody-externs))
       (packed (let count ((xs (compiled-listing c)) (n 0))
                 (cond ((null? xs) n)
                       ((and (pair? (car xs))
                             (memq (car (car xs))
                                   '(vaddpd vsubpd vmulpd vdivpd vunpcklpd
                                     vmovupd vmovddup)))
                        (count (cdr xs) (+ n 1)))
                       (else (count (cdr xs) n))))))
  (ck! "nbody's pairwise force loop emits packed arithmetic" (> packed 0)))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
