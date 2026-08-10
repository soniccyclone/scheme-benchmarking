;;; REPRODUCTION for qaq.22: two 3-element store groups in one block.
;;;
;;; One loop whose body contains TWO pair computations, each writing three
;;; adjacent flvector elements. SonicScheme computes different numbers from
;;; Chez; tools/diff-run.sh on this file says DIFFER.
;;;
;;; Shrunk from bench/nbody/config-sonic-two.sps by removing, one at a time,
;;; everything that turned out not to matter: the outer loop, declare-distinct,
;;; and the j-side stores. Reducing each pair body to ONE store makes it pass,
;;; which is what points at slp.ss -- three adjacent stores is its seed, and
;;; two such groups in one block is a shape nothing generated before.
;;;
(define n 5)
(define p (make-flvector 15 0.0))
(define v (make-flvector 15 0.0))
(define m (make-flvector 5 1.0))
(define (setup i)
  (if (fx< i n)
      (begin (flvector-set! p (fx* i 3) (fx->fl (fx+ i 1)))
             (flvector-set! p (fx+ (fx* i 3) 1) (fx->fl (fx+ i 3)))
             (flvector-set! p (fx+ (fx* i 3) 2) (fx->fl (fx+ i 7)))
             (setup (fx+ i 1)))
      0))
(define (adv p v m)
  (begin
    (let outer ((i 0))
      (when (fx< i 1)
        (let inner ((j (fx+ i 1)))
          (if (fx< (fx+ j 1) n)
              (begin
          (let* ((bia (fx* i 3)) (bja (fx* j 3))
                 (dxa (fl- (flvector-ref p bia) (flvector-ref p bja)))
                 (dya (fl- (flvector-ref p (fx+ bia 1)) (flvector-ref p (fx+ bja 1))))
                 (dza (fl- (flvector-ref p (fx+ bia 2)) (flvector-ref p (fx+ bja 2))))
                 (d2a (fl+ (fl+ (fl* dxa dxa) (fl* dya dya)) (fl* dza dza)))
                 (mga (fl/ 0.01 (fl* d2a (flsqrt d2a))))
                 (mja (fl* (flvector-ref m j) mga))
                 (mia (fl* (flvector-ref m i) mga)))
            (flvector-set! v bia (fl- (flvector-ref v bia) (fl* dxa mja)))
            (flvector-set! v (fx+ bia 1) (fl- (flvector-ref v (fx+ bia 1)) (fl* dya mja)))
            (flvector-set! v (fx+ bia 2) (fl- (flvector-ref v (fx+ bia 2)) (fl* dza mja))))
          (let* ((bib (fx* i 3)) (bjb (fx* (fx+ j 1) 3))
                 (dxb (fl- (flvector-ref p bib) (flvector-ref p bjb)))
                 (dyb (fl- (flvector-ref p (fx+ bib 1)) (flvector-ref p (fx+ bjb 1))))
                 (dzb (fl- (flvector-ref p (fx+ bib 2)) (flvector-ref p (fx+ bjb 2))))
                 (d2b (fl+ (fl+ (fl* dxb dxb) (fl* dyb dyb)) (fl* dzb dzb)))
                 (mgb (fl/ 0.01 (fl* d2b (flsqrt d2b))))
                 (mjb (fl* (flvector-ref m (fx+ j 1)) mgb))
                 (mib (fl* (flvector-ref m i) mgb)))
            (flvector-set! v bib (fl- (flvector-ref v bib) (fl* dxb mjb)))
            (flvector-set! v (fx+ bib 1) (fl- (flvector-ref v (fx+ bib 1)) (fl* dyb mjb)))
            (flvector-set! v (fx+ bib 2) (fl- (flvector-ref v (fx+ bib 2)) (fl* dzb mjb))))
                (inner (fx+ j 2)))
              (when (fx< j n)
          (let* ((bic (fx* i 3)) (bjc (fx* j 3))
                 (dxc (fl- (flvector-ref p bic) (flvector-ref p bjc)))
                 (dyc (fl- (flvector-ref p (fx+ bic 1)) (flvector-ref p (fx+ bjc 1))))
                 (dzc (fl- (flvector-ref p (fx+ bic 2)) (flvector-ref p (fx+ bjc 2))))
                 (d2c (fl+ (fl+ (fl* dxc dxc) (fl* dyc dyc)) (fl* dzc dzc)))
                 (mgc (fl/ 0.01 (fl* d2c (flsqrt d2c))))
                 (mjc (fl* (flvector-ref m j) mgc))
                 (mic (fl* (flvector-ref m i) mgc)))
            (flvector-set! v bic (fl- (flvector-ref v bic) (fl* dxc mjc)))
            (flvector-set! v (fx+ bic 1) (fl- (flvector-ref v (fx+ bic 1)) (fl* dyc mjc)))
            (flvector-set! v (fx+ bic 2) (fl- (flvector-ref v (fx+ bic 2)) (fl* dzc mjc))))
                0)))
        (outer (fx+ i 1))))))
(setup 0)
(adv p v m)
(display (flvector-ref v 0))
(newline)
(display (flvector-ref v 7))
(newline)
