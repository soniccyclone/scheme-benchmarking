#!r6rs
;;; PROBE 1: does the optimiser fold two reads of the same address into one?
;;;
;;; This is the MMIO question. A device register read has a side effect on the
;;; device and must happen exactly as many times as written. If CSE collapses
;;; these two reads, memory-mapped I/O is a wrong-code bug today.
;;;
;;; FALSIFIABLE: if the emitted listing contains TWO loads from the same slot,
;;; the optimiser already leaves them alone and I am wrong.
(define reg (make-vector 4 0))

(define (read-twice)
  (fx+ (vector-ref reg 0) (vector-ref reg 0)))

(display (fx->fl (read-twice)))
(newline)
