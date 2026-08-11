;;; Nine tagged values live across allocations, against four value registers.
;;;
;;; A fixture for the GC stack maps. The point is the SPILLS: the value class
;;; is four registers wide (regs.ss), so holding nine live pairs forces some of
;;; them into the frame, and a frame slot holding a pair is a root the collector
;;; must find. Neither benchmark produces one -- fannkuch and nbody spill raw
;;; words and doubles, so every frame bit in them is legitimately clear, and a
;;; test written against either would have passed while the maps were blank.
;;;
;;; Expected: main.entry1 spills 18 slots, 17 of them tagged. Fixnums are tagged
;;; too, which is why it is 17 and not 8.
;;;
;;; The answer is 24: eight pairs, each with car 3.

(define (g a b)
  (let* ((p1 (cons a b)) (p2 (cons a b)) (p3 (cons a b))
         (p4 (cons a b)) (p5 (cons a b)) (p6 (cons a b))
         (p7 (cons a b)) (p8 (cons a b)))
    (fx+ (car p1) (fx+ (car p2) (fx+ (car p3) (fx+ (car p4)
      (fx+ (car p5) (fx+ (car p6) (fx+ (car p7) (car p8))))))))))

(display (fx->fl (g 3 4)))
(newline)
