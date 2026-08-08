;;; Superword-level parallelism: packing adjacent scalar work into pairs.
;;;
;;; The pass is CORRECT and, on nbody today, INERT. Both halves are asserted,
;;; because a vectorizer that is merely correct is easy and a vectorizer that
;;; merely fires is dangerous.
;;;
;;; What it does not yet do is in `slp-test.ss`'s last section and in the bead
;;; that follows this one: nbody's `dx` is read by `dx*dx`, which feeds a
;;; REDUCTION and cannot pack, and by `dx*mj`, which can. The rule below is all
;;; uses or no pack, so the unpackable use unravels the whole chain. Relaxing
;;; that needs a pack ASSEMBLED from scalars and a cost model to decide when
;;; assembling is worth it.

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

;; --- ALL USES OR NO PACK ----------------------------------------------------
;;
;; `c0` is also read by something that cannot pack. Keeping the pack would need
;; an extract, and an extract costs what the pack saved, so nothing packs.
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

;; --- nbody: correct, and currently inert ------------------------------------
;;
;; Recorded as a measurement rather than left implicit. `dx` is read by `dx*dx`,
;; which feeds the reduction `dx*dx + dy*dy + dz*dz` and cannot pack, and by
;; `dx*mj`, which can. All-uses-or-no-pack means the unpackable use unravels the
;; chain, so nothing survives.
;;
;; The fix is a pack ASSEMBLED from scalars -- the scalar `dx` stays for the
;; square, and one `vunpcklpd` builds the pair for the velocity update -- plus a
;; cost model to decide when assembling pays. Until then this asserts the
;; honest state: bit-exact and unchanged.
(let* ((c (compile-sonic "../bench/nbody/config-sonic.sps" nbody-externs))
       (packed (let count ((xs (compiled-listing c)) (n 0))
                 (cond ((null? xs) n)
                       ((and (pair? (car xs))
                             (memq (car (car xs))
                                   '(vaddpd vsubpd vmulpd vdivpd vmovupd vmovddup)))
                        (count (cdr xs) (+ n 1)))
                       (else (count (cdr xs) n))))))
  (ck! "nbody still compiles, and today packs nothing: every chain has an
       unpackable use"
       (= packed 0)))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
