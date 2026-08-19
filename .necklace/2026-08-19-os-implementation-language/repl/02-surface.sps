#!r6rs
;;; PROBE 2 (corrected): is integer division reachable from source?
;;;
;;; The first version passed literals -- (fxquotient 7 2) -- and "compiled",
;;; which proved nothing: constant folding removes the call before selection
;;; ever sees it. A probe that cannot fail proves nothing (necklace-spec).
;;;
;;; This version takes its operands from a vector the folder cannot see through.
;;; FALSIFIABLE: if this compiles and emits a division, fxquotient is reachable.
(define v (make-vector 4 7))

(define (f) (fxquotient (vector-ref v 0) (vector-ref v 1)))

(display (fx->fl (f)))
(newline)
