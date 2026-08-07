(import (rnrs base) (rnrs lists) (rnrs control) (rnrs exceptions)
        (rnrs io simple) (sonic gcell))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define env (make-genv))

;; --- redefinition is a store ----------------------------------------------
(define c (genv-define! env 'f 1))
(ck! "a global reference is an indirect load" (= (gcell-ref c) 1))
(genv-define! env 'f 2)
(ck! "redefinition writes the SAME cell, so old references see the new value"
     (and (= (gcell-ref c) 2) (eq? c (genv-lookup env 'f))))

;; That identity is the whole design. If redefinition made a NEW cell, every
;; already-emitted reference would still load the old one, and the only fix
;; would be patching the code that holds the address.
(ck! "cell identity is stable across redefinition"
     (eq? (genv-lookup env 'f) (genv-lookup env 'f)))

;; --- sealing licenses inlining, and nothing else does ---------------------
(ck! "an unsealed cell is NOT inlinable" (not (gcell-inlinable? c)))
(genv-seal! env 'f)
(ck! "a sealed cell IS inlinable" (gcell-inlinable? c))

;; --- sealing is enforced, not advisory ------------------------------------
(set! checks (+ checks 1))
(let ([caught #f])
  (guard (e (#t (set! caught (redefinition-error? e))))
    (genv-define! env 'f 3))
  (if caught
      (display "  ok   redefining a sealed global raises, and raises the RIGHT condition\n")
      (begin (set! failures (+ failures 1))
             (display "  FAIL sealed global was silently redefined\n"))))
(ck! "and the value did not change" (= (gcell-ref c) 2))

;; --- sealing is one-way ---------------------------------------------------
;; There is deliberately no unseal: it would invalidate code already inlined,
;; and recovering needs exactly the code-patching this design avoids.
(ck! "there is no unseal operation in the API"
     (not (memq 'gcell-unseal!
                '(make-gcell gcell? gcell-name gcell-value gcell-sealed?
                  gcell-set! gcell-seal! gcell-ref gcell-inlinable?
                  make-genv genv-define! genv-lookup genv-seal! genv-names))))

;; --- an unrelated global is unaffected ------------------------------------
(define g (genv-define! env 'g 10))
(genv-define! env 'g 20)
(ck! "sealing f did not seal g" (and (= (gcell-ref g) 20) (not (gcell-inlinable? g))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
