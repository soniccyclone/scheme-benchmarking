#!r6rs
;;; The smallest program that exercises the RV64 entry sequence end to end.
;;;
;;; It allocates nothing, prints nothing, and calls no runtime helper, so it
;;; needs only _start, the call and the exit -- which is precisely what the
;;; minimal RV64 runtime provides. Anything more (a flvector, `display`) would
;;; reference a helper label that does not exist yet and would fail to link,
;;; which is the boundary rv64-test.ss asserts alongside this.
(define (add-them a b) (fx+ a b))
(add-them 20 22)
