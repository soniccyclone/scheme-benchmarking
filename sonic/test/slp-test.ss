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

;; --- a chain that does not pay ----------------------------------------------
;;
;; `c0` is read by a horizontal add, so the op pack over it is demoted to an
;; assembled pair. Here that assembly costs more than the one multiply and store
;; it would buy, so nothing is packed at all.
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
  (ck! "a use that cannot pack unravels the chain rather than forcing an extract"
       (not (exists (lambda (i) (memq (car i) '(p2load p2sub p2store))) is))))

;; THE REDUCTION IS THE CASE THAT MATTERS. `(add d c0 c1)` reads both lanes into
;; one scalar, which is a horizontal add -- reassociation, which D24 forbids and
;; which the bit-exact oracle would catch. Asserting it here means the refusal
;; is a property of the pass rather than an accident of the example above.
(ck! "specifically: a horizontal combination of the two lanes is never packed"
     (let-values (((is st) (run escaping (classes-for 'a0 'a1 'b0 'b1 'c0 'c1 'd))))
       (not (exists (lambda (i) (eq? (car i) 'p2add)) is))))

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

;; --- ASSEMBLING a pair from scalars -----------------------------------------
;;
;; `c0` is read by a horizontal add AND stored beside `c1`. The op pack is
;; DEMOTED to a gather rather than dropped: the scalars are still there, so
;; assembling them is available, and the store pack then pays for it.
;; Shaped like nbody's velocity update, because the profitability is the point:
;; ONE assembled pair pays for a load pack, two op packs and a store pack. A
;; shorter chain does NOT pay -- a gather plus a splat costs two and a single
;; multiply plus store saves two -- and the pass correctly declines those.
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
  ;; c0 and c1 keep their scalar subtractions, because the horizontal add still
  ;; reads them -- and one vunpcklpd assembles the pair for the multiply.
  (ck! "a pack whose members have an unpackable use is ASSEMBLED, not abandoned"
       (and (exists (lambda (i) (eq? (car i) 'p2pack)) is)
            (= 2 (length (filter (lambda (i) (eq? (car i) 'sub)) is)))))
  (ck! "the scalar operand shared by both lanes is splatted once"
       (= 1 (length (filter (lambda (i) (eq? (car i) 'p2splat)) is))))
  (ck! "and the reduction that forced the demotion is still scalar"
       (exists (lambda (i) (equal? i '(add d raw-f64 c0 c1))) is)))

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
