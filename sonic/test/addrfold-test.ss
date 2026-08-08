;;; Index arithmetic folded into the addressing mode, before allocation.
;;;
;;; The point of doing it HERE rather than in peephole.ss is register pressure,
;;; not instruction count. A derived index is a vreg the allocator must place;
;;; nbody's pairwise loop derives four of them and one spilled, and the seven
;;; instructions that resulted are one addressed load. A peephole cannot repair
;;; that, because by the time it runs the value is in a frame slot.
;;;
;;; So the assertions below are about what reaches the allocator, and the
;;; end-to-end one is about spilling.

(import (chezscheme) (nanopass)
        (sonic lang) (sonic addrfold) (sonic dce)
        (sonic read) (sonic expand) (sonic parse) (sonic policy)
        (sonic anf) (sonic assign) (sonic inline) (sonic essa)
        (sonic driver) (sonic pipeline) (sonic finalize))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define (fold prog) (let-values (((p st) (addrfold-program prog))) p))
(define (instrs p) (cadr (cadr (car (cadr p)))))

;; p[i+1] : an add of an index and a constant, feeding a load.
(define one-load
  '(program ((entry (block ((const k raw-word 1)
                            (add t raw-word i k)
                            (load v raw-f64 p t))
                           (ret v))))
     entry))

(ck! "a load at a constant offset becomes a load-at, and the offset is in ELEMENTS"
     (equal? (list-ref (instrs (fold one-load)) 2)
             '(load-at v raw-f64 1 p i)))

;; Both operand orders, because addition is commutative and lowering does not
;; promise which side the constant lands on.
(ck! "the constant is found on either side of the add"
     (equal? (list-ref
              (instrs (fold '(program ((entry (block ((const k raw-word 2)
                                                     (add t raw-word k i)
                                                     (load v raw-f64 p t))
                                                    (ret v))))
                               entry)))
              2)
             '(load-at v raw-f64 2 p i)))

(ck! "a store folds the same way, keeping the stored value last"
     (equal? (list-ref
              (instrs (fold '(program ((entry (block ((const k raw-word 2)
                                                     (add t raw-word i k)
                                                     (store d raw-f64 p t val))
                                                    (ret d))))
                               entry)))
              2)
             '(store-at d raw-f64 2 p i val)))

;; THE POINT: the add is dead afterwards, so DCE removes it and the vreg never
;; reaches the allocator. Asserted through DCE rather than by inspection,
;; because "the add is dead" is only useful if something actually collects it.
(ck! "the derived index vreg is gone entirely after DCE"
     (let*-values (((p) (fold one-load))
                   ((q st) (dce-program p)))
       (let ((is (cadr (cadr (car (cadr q))))))
         (and (= 1 (length is))
              (equal? (car is) '(load-at v raw-f64 1 p i))))))

;; An index this pass cannot see through is left alone. There is no attempt to
;; chase arithmetic: elide and loops already know more about these expressions,
;; and a second weaker opinion about an index is a second thing to keep sound.
(ck! "an index that is not a constant offset is untouched"
     (equal? (instrs (fold '(program ((entry (block ((add t raw-word i j)
                                                    (load v raw-f64 p t))
                                                   (ret v))))
                              entry)))
             '((add t raw-word i j) (load v raw-f64 p t))))

;; --- end to end, on nbody ---------------------------------------------------
;;
;; The measurement that justifies the pass. Before it, the pairwise force loop
;; spilled five values and its block carried sixteen frame-slot references; the
;; four derived indices were what made it spill.

(let* ((c (compile-sonic "../bench/nbody/config-sonic.sps" nbody-externs))
       (inner (let find ((fs (compiled-functions c)))
                (cond ((null? fs) #f)
                      ((eq? (finalized-name (car fs)) 'inner%24.201) (car fs))
                      (else (find (cdr fs)))))))
  (ck! "nbody's pairwise force loop is found" (and inner #t))
  (ck! "and it spills NOTHING, where it used to spill five"
       (and inner (null? (finalized-spills inner)))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
