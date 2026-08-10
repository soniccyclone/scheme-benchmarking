;;; A twenty-line reproduction of the specialize.ss elision collapse.
;;;
;;; specialize.ss is "full unrolling, spelled as specialization" and it is
;;; switched OFF, because enabling it takes fannkuch from 0 surviving bounds
;;; checks to 79 and nbody from 0 to 97. That regression is the only thing
;;; standing between qaq.23 and a measured 8.4% of fannkuch cycles (D43), so
;;; it is worth a fixture rather than a re-derivation each time.
;;;
;;; HOW TO USE IT. Compile with specialize-enabled? off and on and count the
;;; sonic-bounds-error labels:
;;;
;;;   off -> 0 checks, 4 functions
;;;   on  -> 3 checks, 18 functions        one check per copy of shift
;;;
;;; WHAT IT ISOLATES. Change the else branch (vector-set! v r p0) to use a
;;; LITERAL index and the copies come out clean -- 0 checks, still 18
;;; functions. So the loss is specifically an access whose index is a symbolic
;;; variable that is FREE in the copied loop, and it is not about copy count.
;;;
;;; WHAT IT RULES OUT. The interval facts are untouched: r carries exactly
;;; [1,8] with specialization off and on, and the fixpoint drops the same two
;;; names either way. So this is not a lost premise and not the fact-coverage
;;; check firing. specialize.ss own recorded suspect -- that freshen renames a
;;; binder while a declare premise still names the old one -- is separately
;;; refuted: inline.ss freshen maps declare names through the substitution.
;;;
;;; WHERE TO LOOK NEXT. [1,8] against an 8-element vector is NOT provable by
;;; the interval domain, so the baseline must be discharging that access by
;;; another rule -- a dominating check recorded in the environment obligations,
;;; or the ABCD inequality graph. Both are structural, and copying a loop body
;;; into a sibling procedure is exactly what would disturb them. Read
;;; elide-site-why on the PROVED site in the baseline; it names the rule, and
;;; that names what the copies lose.

(define v (make-vector 8 0))
(define (rot r)
  (let ((p0 (vector-ref v 0)))
    (let shift ((i 0))
      (if (fx< i r)
          (begin (vector-set! v i (vector-ref v (fx+ i 1))) (shift (fx+ i 1)))
          (vector-set! v r p0)))))
(define (drive r acc)
  (if (fx< r 8)
      (begin (rot r) (drive (fx+ r 1) (fx+ acc 1)))
      acc))
(display (fx->fl (drive 1 0)))
(newline)
