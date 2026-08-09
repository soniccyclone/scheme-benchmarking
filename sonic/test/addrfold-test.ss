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
        (sonic driver) (sonic pipeline) (sonic finalize) (sonic unroll))

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

;; --- the constant out of the register, where the result is a VALUE ----------
;;
;; The rules above delete the add entirely, because its result was only ever an
;; address. A loop counter is not an address: the add has to survive. What does
;; NOT have to survive is the register holding the 1, and that register is the
;; whole point -- in nbody's force loop it and the stride constant were the two
;; values that pushed the block over its register budget and made it spill.

(ck! "an add of a constant whose result is a value keeps the add and drops the register"
     (let*-values (((p) (fold '(program ((entry (block ((const k raw-word 1)
                                                       (add t raw-word i k))
                                                      (ret t))))
                                entry)))
                   ((q st) (dce-program p)))
       (equal? (instrs q) '((add-imm t raw-word 1 i)))))

(ck! "and the same for a multiply, whose constant is the element stride"
     (let*-values (((p) (fold '(program ((entry (block ((const k raw-word 3)
                                                       (mul t raw-word i k))
                                                      (ret t))))
                                entry)))
                   ((q st) (dce-program p)))
       (equal? (instrs q) '((mul-imm t raw-word 3 i)))))

(ck! "either operand order, for both"
     (and (equal? (instrs (fold '(program ((entry (block ((const k raw-word 5)
                                                         (add t raw-word k i))
                                                        (ret t))))
                                  entry)))
                  '((const k raw-word 5) (add-imm t raw-word 5 i)))
          (equal? (instrs (fold '(program ((entry (block ((const k raw-word 7)
                                                         (mul t raw-word k i))
                                                        (ret t))))
                                  entry)))
                  '((const k raw-word 7) (mul-imm t raw-word 7 i)))))

;; RESTRICTED TO raw-word, and the restriction is the interesting half. A tagged
;; add carries a tagged datum, whose bit pattern is not the integer written in
;; the source; folding one would put the wrong number in the instruction. A
;; float add is not this instruction at all.
(ck! "a tagged add is left alone, because its constant is not the integer it reads as"
     (equal? (instrs (fold '(program ((entry (block ((const k tagged 1)
                                                    (add t tagged i k))
                                                   (ret t))))
                             entry)))
             '((const k tagged 1) (add t tagged i k))))

(ck! "a float add is left alone"
     (equal? (instrs (fold '(program ((entry (block ((const k raw-f64 1)
                                                    (add t raw-f64 i k))
                                                   (ret t))))
                             entry)))
             '((const k raw-f64 1) (add t raw-f64 i k))))

;; A constant on BOTH sides is a constant, not an operation, and belongs to
;; whatever folds constants -- not here, where rewriting it would leave an
;; instruction whose one operand is also a literal.
(ck! "constants on both sides are left for the constant folder"
     (equal? (instrs (fold '(program ((entry (block ((const a raw-word 2)
                                                    (const b raw-word 3)
                                                    (add t raw-word a b))
                                                   (ret t))))
                             entry)))
             '((const a raw-word 2) (const b raw-word 3) (add t raw-word a b))))

;; --- end to end, on nbody ---------------------------------------------------
;;
;; The measurement that justifies the pass. Before it, the pairwise force loop
;; spilled five values and its block carried sixteen frame-slot references; the
;; four derived indices were what made it spill.


;; FOUND BY PREFIX, not by full name. The `%24` comes from the expander and is
;; stable with the source; the `.NNN` suffix is a global gensym counter that
;; every pass upstream shifts -- unrolling moved it from .201 to .271. A test
;; that pins the counter fails whenever an unrelated pass allocates a name, and
;; reports it as a missing loop.
(define (force-loop c)
  (let find ((fs (compiled-functions c)))
    (cond ((null? fs) #f)
          ((let ((s (symbol->string (finalized-name (car fs)))))
             (and (>= (string-length s) 6) (string=? (substring s 0 6) "inner%")))
           (car fs))
          (else (find (cdr fs))))))

;; UNROLLING OFF for this one, so the measurement is about THIS pass. With it on
;; the force loop is twice the size and spills one value -- which is a fact about
;; register pressure under unrolling, asserted in unroll-test.ss, and says
;; nothing either way about whether folding an index into the addressing mode
;; removed the four derived vregs it exists to remove.
(let* ((c (parameterize ((unroll-size-budget 0))
            (compile-sonic "../bench/nbody/config-sonic.sps" nbody-externs)))
       (inner (force-loop c)))
  (ck! "nbody's pairwise force loop is found" (and inner #t))
  (ck! "and it spills NOTHING, where it used to spill five"
       (and inner (null? (finalized-spills inner)))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
