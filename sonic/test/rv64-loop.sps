#!r6rs
;;; NESTED counted loops, the shape nbody's advance! has: an outer index and an
;;; inner one starting at (fx+ i 1). nbody on RV64 does not terminate; a single
;;; counted loop does. This is the smallest program that has the difference.
(define (nested n)
  (let outer ((i 0) (acc 0))
    (if (fx< i n)
        (outer (fx+ i 1)
               (let inner ((j (fx+ i 1)) (a acc))
                 (if (fx< j n) (inner (fx+ j 1) (fx+ a 1)) a)))
        acc)))
(nested 5)
