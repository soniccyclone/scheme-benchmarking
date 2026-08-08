;;; Can these two references touch the same storage?
;;;
;;; The REFUSALS are the load-bearing half. An alias analysis that says
;;; `must-not` too often does not lose an optimization, it miscompiles: stage 10
;;; reorders reads against writes on the strength of this answer, and there is
;;; no runtime check downstream to catch it. So most of these cases assert
;;; `may`, and the three that assert `must-not` are the ones carrying a proof.

(import (chezscheme) (nanopass) (sonic lang) (sonic alias)
        (sonic read) (sonic expand) (sonic parse) (sonic policy)
        (sonic anf) (sonic assign) (sonic inline) (sonic pipeline))

(define failures 0)
(define checks 0)

(define (expect name prog x y want)
  (set! checks (+ checks 1))
  (let* ([tbl (alias-analyze prog)]
         [got (alias-query tbl x y)])
    (if (eq? got want)
        (printf "  ok   ~a  (~a ~a) -> ~a\n" name x y got)
        (begin (set! failures (+ failures 1))
               (printf "  FAIL ~a  (~a ~a) expected ~a got ~a\n" name x y want got)
               (printf "        ~a points to ~a, escaped ~a\n"
                       x (alias-points-to tbl x) (alias-escaped? tbl x))
               (printf "        ~a points to ~a, escaped ~a\n"
                       y (alias-points-to tbl y) (alias-escaped? tbl y))))))

(define (expect-true name v)
  (set! checks (+ checks 1))
  (if v
      (printf "  ok   ~a\n" name)
      (begin (set! failures (+ failures 1))
             (printf "  FAIL ~a\n" name))))

;; Every array in these fixtures is allocated the same way, so the only thing
;; that varies between cases is what happens to it afterwards.
(define (one-array inner)
  (with-output-language (Lanf Expr)
    `(let ([a (primcall make-flvector ([type-check checked]) n zero)]) ,inner)))

(define (two-arrays inner)
  (one-array
   (with-output-language (Lanf Expr)
     `(let ([b (primcall make-flvector ([type-check checked]) n zero)]) ,inner))))

;; The helper every fixture ends in: a leaf that mentions both names so neither
;; is dead, without doing anything to them.
(define (mention x y)
  (with-output-language (Lanf Expr) `(seq ,x ,y)))

(printf "alias analysis:\n")

;; 1. THE ONE THAT MATTERS. Two distinct make-flvector calls are two distinct
;;    objects and nothing in between can make them the same one. Without this
;;    the vectorizer never fires on anything.
(expect "two distinct allocation sites"
        (two-arrays (mention 'a 'b))
        'a 'b 'must-not)

;; 2. A reference always may-alias itself. Not a degenerate case: one syntactic
;;    allocation site inside a loop yields a different object per iteration, so
;;    `same site` cannot mean `same object`, and it equally cannot mean
;;    `different object`.
(expect "the same variable aliases itself"
        (one-array (mention 'a 'a))
        'a 'a 'may)

;; 3. Handed to a call we cannot see inside of. The callee may stash it, and we
;;    can no longer enumerate who reads and writes that storage.
(expect "passed to an unknown call"
        (two-arrays (with-output-language (Lanf Expr)
                      `(seq (tailcall opaque a) b)))
        'a 'b 'may)

;; 4. Two names for one array. This is the case an analysis keyed on variable
;;    identity rather than on storage gets wrong.
(expect "two references derived from the same base"
        (one-array (with-output-language (Lanf Expr)
                     `(let ([p a]) (let ([q a]) (seq p q)))))
        'p 'q 'may)

;; 5. The default. Nothing was ever proven about either name.
(expect "two variables the program never binds"
        (mention 'u 'v)
        'u 'v 'may)

;; 6. A reference arriving from an unknown call could be either array we hold.
(expect "a reference returned by an unknown call"
        (one-array (with-output-language (Lanf Expr)
                     `(let ([r (call opaque a)]) (seq a r))))
        'a 'r 'may)

;; 7. Stored into another object. `vector-set!` makes the value reachable by a
;;    path this analysis does not follow, so it escapes with no call in sight.
(expect "stored into a heap object"
        (two-arrays
         (with-output-language (Lanf Expr)
           `(let ([t (primcall vector-set! ([type-check checked] [bounds-check checked]) box i a)])
              (seq b t))))
        'a 'b 'may)

;; 8. Captured by a closure we cannot account for. The lambda is anonymous, so
;;    there is no name to key call sites on and it has to be assumed to leave.
(expect "captured by an escaping closure"
        (two-arrays (with-output-language (Lanf Expr)
                      `(seq b (lambda (u) a))))
        'a 'b 'may)

;; 9. THE INTERPROCEDURAL STEP, and the reason inlining sits upstream of this
;;    stage. `f` is bound once, to a lambda, and used only as a call operator,
;;    so every call site is enumerable and the actuals flow into the formals.
;;    The two parameters then carry disjoint sites.
(expect "parameters of a known procedure keep their sites apart"
        (with-output-language (Lanf Expr)
          `(letrec ([f (lambda (u v)
                         (let ([t (primcall flvector-ref
                                            ([type-check checked] [bounds-check checked])
                                            u i)])
                           t))])
             ,(two-arrays (with-output-language (Lanf Expr) `(tailcall f a b)))))
        'u 'v 'must-not)

;; 10. Same shape, but the procedure name is also handed to somebody else, so we
;;     can no longer claim to know every caller. The formals go back to `may`.
(expect "a procedure whose name escapes loses its parameter facts"
        (with-output-language (Lanf Expr)
          `(letrec ([f (lambda (u v)
                         (let ([t (primcall flvector-ref
                                            ([type-check checked] [bounds-check checked])
                                            u i)])
                           t))])
             ,(two-arrays (with-output-language (Lanf Expr)
                            `(seq (tailcall register f) (tailcall f a b))))))
        'u 'v 'may)

;; 11. A flonum is not storage. This is what lets a query between a loaded
;;     element and the array it came from answer `must-not` rather than wasting
;;     the caller's time.
(expect "a flonum result holds no reference"
        (one-array
         (with-output-language (Lanf Expr)
           `(let ([s (primcall flvector-ref ([type-check checked] [bounds-check checked]) a i)])
              (seq a s))))
        'a 's 'must-not)

;; --- declare-distinct, the premise ----------------------------------------
;;
;; nbody's real entry point: the kernel receives its flvectors as PARAMETERS.
;; The make-flvector happened in a caller this compiler may not have, so
;; allocation-site reasoning has nothing to work with and every case below
;; except the declared one must answer `may`.

;; 12. The baseline. Without a premise, two parameters are two unknowns.
(expect "two kernel parameters, no premise"
        (with-output-language (Lanf Expr)
          `(lambda (a b) ,(mention 'a 'b)))
        'a 'b 'may)

;; 13. THE ONE THIS EXISTS FOR. The same kernel, with the programmer asserting
;;     what the compiler cannot see. This is the difference between vectorizing
;;     nbody and not.
(expect "two kernel parameters under declare-distinct"
        (with-output-language (Lanf Expr)
          `(lambda (a b) (declare-distinct (a b) ,(mention 'a 'b))))
        'a 'b 'must-not)

;; 14. A name is not distinct from itself, however the group is written. The
;;     premise is already violated at that point; answering `must-not` would
;;     turn the programmer's mistake into a silently miscompiled loop.
(expect "a name is never distinct from itself"
        (with-output-language (Lanf Expr)
          `(lambda (a b) (declare-distinct (a b) ,(mention 'a 'a))))
        'a 'a 'may)

;; 15. The premise covers the group it names and nothing else.
(expect "a third array is not covered by someone else's premise"
        (with-output-language (Lanf Expr)
          `(lambda (a b c) (declare-distinct (a b) ,(mention 'a 'c))))
        'a 'c 'may)

;; 16. Three names in one group are pairwise distinct, which is what `restrict`
;;     on three pointers means and what a three-array kernel needs.
(expect "a group of three is pairwise distinct"
        (with-output-language (Lanf Expr)
          `(lambda (a b c) (declare-distinct (a b c) ,(mention 'b 'c))))
        'b 'c 'must-not)

;; 17. The premise wins over escape, and that is deliberate rather than an
;;     oversight: a parameter is escaped by construction here, so an escape test
;;     ahead of the premise would make declare-distinct unreachable. Like C99's
;;     restrict, the assertion covers access and not merely identity. See the
;;     undefined-behaviour note in alias.ss.
(expect "the premise outranks escape, which is what makes it usable"
        (with-output-language (Lanf Expr)
          `(lambda (a b)
             (declare-distinct (a b) (seq (tailcall opaque a) b))))
        'a 'b 'must-not)

;; 18. The body under declare-distinct is still ANALYSED. Before the form was
;;     handled it fell to the walk's `else` and the whole subtree went unread,
;;     so allocations inside it were invisible: sound, and blind.
(expect "allocations inside the body are still seen"
        (with-output-language (Lanf Expr)
          `(declare-distinct (p q) ,(two-arrays (mention 'a 'b))))
        'a 'b 'must-not)

(expect-true "the premise is separately reportable"
             (let ([tbl (alias-analyze
                         (with-output-language (Lanf Expr)
                           `(lambda (a b) (declare-distinct (a b) ,(mention 'a 'b)))))])
               (and (alias-declared-distinct? tbl 'a 'b)
                    (alias-declared-distinct? tbl 'b 'a)
                    (not (alias-declared-distinct? tbl 'a 'a)))))

;; --- the direction of the default -----------------------------------------
;; If a form is added to Lanf and this file is not taught about it, the walk
;; falls through and the answer stays `may`. Assert the fall-through lands on
;; top rather than on an empty points-to set, because the two are one character
;; apart in the source and opposite in consequence.

(expect-true "an unbound variable is top, not bottom"
             (eq? 'unknown
                  (alias-points-to
                   (alias-analyze (with-output-language (Lanf Expr) `(quote 0)))
                   'never-mentioned)))

(expect-true "escape is separately reportable"
             (let ([tbl (alias-analyze
                         (one-array (with-output-language (Lanf Expr)
                                      `(tailcall opaque a))))])
               (alias-escaped? tbl 'a)))

(expect-true "must-not-alias? and may-alias? agree with alias-query"
             (let ([tbl (alias-analyze (two-arrays (mention 'a 'b)))])
               (and (must-not-alias? tbl 'a 'b)
                    (not (may-alias? tbl 'a 'b))
                    (may-alias? tbl 'a 'a))))


;; --- the precondition, now enforced ---------------------------------------
;; Flow insensitivity is sound only while a name denotes one object for its
;; whole lifetime. Lanf inherited set! from Lcore, so that is no longer free: a
;; mutated variable can point at different objects at different program points,
;; which is exactly what a flow-insensitive analysis cannot see. Returning
;; must-not for two names that alias at run time is a miscompile nothing
;; downstream could detect, so we refuse instead.
(set! checks (+ checks 1))
(let ([caught #f])
  (guard (e (#t (set! caught #t)))
    (alias-analyze '(let ([a (primcall make-flvector ([type-check checked]) n z)])
                      (set! a b))))
  (if caught
      (printf "  ok   a program still containing set! is REFUSED\n")
      (begin (set! failures (+ failures 1))
             (printf "  FAIL analysed an unconverted program; flow insensitivity is unsound there\n"))))


;; --- a REAL program, which every fixture above is not -----------------------
;;
;; This file's walks are `nanopass-case` over Lanf EXPR, and the pipeline hands
;; an Lanf PROGRAM. Handing it one raised "unrecognized language record",
;; which is the better of the two possible failures but still means this
;; analysis had never once run on a program the compiler produces.
;;
;; No fixture could catch it. Every one above is a hand-built Expr, and the bug
;; is about the shape the front end produces -- which a fixture, by
;; construction, is not. So this compiles source and checks a number that is
;; knowable independently: nbody allocates exactly three vectors.

(printf "\nreal programs, not fixtures:\n")

(define real-anf
  (let* ((p (open-file-input-port "../bench/nbody/config-sonic.sps"))
         (bv (get-bytevector-all p)))
    (close-port p)
    (let ((o (open-file-output-port "/tmp/sonic-alias-real.sps" (file-options no-fail)
                                    (buffer-mode block) (native-transcoder))))
      (put-string o (utf8->string bv)) (close-port o))
    (inline-program
     (assign-convert-program
      (anf-program
       (resolve-policy-program
        (parse-program (expand-program (read-all-from-file "/tmp/sonic-alias-real.sps"))
                       nbody-externs)))))))

(let ((tbl (alias-analyze real-anf)))
  (expect-true "nbody's three make-flvector calls are three allocation sites"
               (= 3 (length (alias-sites tbl)))))

(printf "\n~a cases, ~a failures\n" checks failures)
(if (> failures 0) (exit 1) (begin (printf "PASS\n") (exit 0)))
