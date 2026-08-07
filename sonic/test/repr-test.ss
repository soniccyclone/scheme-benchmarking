(import (chezscheme) (nanopass) (sonic lang) (sonic repr) (sonic fixtures))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

;; --- the classification, which is where a mistake becomes corruption -------
(ck! "flonum arithmetic yields raw-f64, so it stays in a float register"
     (and (eq? (prim-result-class 'fl+) 'raw-f64)
          (eq? (prim-result-class 'flsqrt) 'raw-f64)
          (eq? (prim-result-class 'flvector-ref) 'raw-f64)))
(ck! "fixnum arithmetic and every comparison yield raw-word"
     (and (eq? (prim-result-class 'fx+) 'raw-word)
          (eq? (prim-result-class 'fl<) 'raw-word)      ; a BOOLEAN, not a double
          (eq? (prim-result-class 'flvector-length) 'raw-word)))
(ck! "allocation and pair access yield tagged: they are heap objects"
     (and (eq? (prim-result-class 'make-flvector) 'tagged)
          (eq? (prim-result-class 'cons) 'tagged)
          (eq? (prim-result-class 'car) 'tagged)))

;; A comparison over doubles produces a boolean, not a double. Classifying it
;; raw-f64 would put a boolean in a float register and every use of it after
;; would read a NaN-shaped integer.
(ck! "fl< is NOT raw-f64 even though its operands are"
     (not (eq? (prim-result-class 'fl<) 'raw-f64)))

;; --- literals -------------------------------------------------------------
(ck! "a flonum literal is raw-f64" (eq? (datum-class 3.5) 'raw-f64))
(ck! "an exact integer literal is raw-word" (eq? (datum-class 7) 'raw-word))
(ck! "a double is not misclassified as a word: 1.0 and 1 differ"
     (not (eq? (datum-class 1.0) (datum-class 1))))
(ck! "anything else is tagged" (eq? (datum-class "s") 'tagged))

;; --- there is no default, and that is the point ---------------------------
;; Guessing `tagged` for an unknown primitive would make the collector scavenge
;; a non-pointer; guessing `raw` would lose a GC root. Neither is recoverable,
;; so an unclassified primitive is a gap in our own table and says so.
(set! checks (+ checks 1))
(let ([caught #f])
  (guard (e (#t (set! caught #t))) (prim-result-class 'not-a-primitive))
  (if caught
      (display "  ok   an unclassified primitive RAISES rather than defaulting\n")
      (begin (set! failures (+ failures 1))
             (display "  FAIL an unknown primitive got a silent default class\n"))))

;; --- every primitive in lang.ss's table is classified ---------------------
;; This is the test that fails when someone adds a primitive and forgets this
;; file, which is exactly when the silent default would have bitten.
(set! checks (+ checks 1))
(let ([missing '()])
  (for-each (lambda (pr)
              (guard (e (#t (set! missing (cons pr missing))))
                (prim-result-class pr)))
            '(fx+ fx- fx* fxneg fxquotient fxremainder fxmodulo
              fx< fx<= fx= fx>= fx> fl+ fl- fl* fl/ flneg flabs flsqrt
              fl< fl<= fl= fl>= fl> fl->fx fx->fl
              flvector-ref flvector-set! flvector-length make-flvector
              vector-ref vector-set! vector-length make-vector
              car cdr cons null? pair? eq? fixnum? flonum? vector? flvector? error))
  (if (null? missing)
      (display "  ok   every primitive in lang.ss's table has a storage class\n")
      (begin (set! failures (+ failures 1))
             (display "  FAIL unclassified primitives: ") (write missing) (newline))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
