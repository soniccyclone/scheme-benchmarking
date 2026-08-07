;;; Does this object outlive the frame that allocated it?
;;;
;;; The REFUSALS are not the load-bearing half here, unlike alias.ss. The safe
;;; answer is `escapes`, and a pass that answered `escapes` to everything would
;;; be sound and useless. So the cases split evenly: the ones that must escape
;;; are correctness, and the ones that must NOT are the entire value of the
;;; pass. Both are asserted, and the reason is asserted with the verdict,
;;; because "escaped" without a route is a report nobody can act on.

(import (chezscheme) (nanopass) (sonic lang) (sonic escape) (sonic alias))

(define failures 0)
(define checks 0)

(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok
      (printf "  ok   ~a\n" name)
      (begin (set! failures (+ failures 1))
             (printf "  FAIL ~a\n" name))))

;; Assert a site's verdict AND its route out, so a site that escapes for the
;; wrong reason fails rather than passing by accident.
(define (expect-escapes name prog binder why)
  (set! checks (+ checks 1))
  (let* ([tbl (escape-analyze prog)]
         [s (escape-site-of tbl binder)])
    (cond
     [(not s)
      (set! failures (+ failures 1))
      (printf "  FAIL ~a  (no allocation site named ~a)\n" name binder)]
     [(and (escape-site-escapes? tbl s) (memq why (escape-site-reasons tbl s)))
      (printf "  ok   ~a  [~a: ~a]\n" name binder (escape-site-reasons tbl s))]
     [else
      (set! failures (+ failures 1))
      (printf "  FAIL ~a  (~a) expected ~a, got ~a\n"
              name binder why (escape-site-reasons tbl s))])))

(define (expect-stays name prog binder)
  (set! checks (+ checks 1))
  (let* ([tbl (escape-analyze prog)]
         [s (escape-site-of tbl binder)])
    (cond
     [(not s)
      (set! failures (+ failures 1))
      (printf "  FAIL ~a  (no allocation site named ~a)\n" name binder)]
     [(escape-site-escapes? tbl s)
      (set! failures (+ failures 1))
      (printf "  FAIL ~a  (~a) escaped via ~a\n" name binder (escape-site-reasons tbl s))]
     [else (printf "  ok   ~a  [~a stack-allocatable]\n" name binder)])))

(define-syntax anf
  (syntax-rules ()
    [(_ e) (with-output-language (Lanf Expr) `e)]))

(define TC '([type-check checked]))
(define TB '([type-check checked] [bounds-check checked]))

(printf "escape analysis:\n")

;; --- 1. a non-escaping allocation ------------------------------------------
;;
;; Allocated, read, discarded. The value that leaves is a flonum, so nothing
;; carries a reference out of the frame.

(define non-escaping
  (anf (let ([v (primcall make-flvector ([type-check checked]) n zero)])
         (let ([r (primcall flvector-ref ([type-check checked] [bounds-check checked]) v i)])
           r))))

(expect-stays "an allocation whose only use is a local read stays in the frame"
              non-escaping 'v)

(let ([tbl (escape-analyze non-escaping)])
  (ck! "and it shows up in the stack-allocatable set, which is this pass's
       actual output"
       (equal? '(v) (map site-binder (escape-stack-allocatable tbl))))
  (ck! "the site knows what it is and which frame it is homed in"
       (let ([s (escape-site-of tbl 'v)])
         (and (eq? 'flvector (site-kind s)) (eq? 'top (site-home s)))))
  (ck! "and the variable query agrees with the site query"
       (not (escape-escapes? tbl 'v))))

;; --- 2. stored into a heap object ------------------------------------------
;;
;; The stored VALUE escapes; the container does not escape by being written to.
;; Both halves are asserted, because getting the second one wrong is how an
;; analysis quietly stops proving anything.

(define stored-into-heap
  (anf (let ([outer (primcall make-vector ([type-check checked]) n zero)])
         (let ([v (primcall make-vector ([type-check checked]) n zero)])
           (let ([u (primcall vector-set! ([type-check checked] [bounds-check checked]) outer i v)])
             (quote 0))))))

(expect-escapes "an allocation stored into a heap object escapes"
                stored-into-heap 'v 'heap-store)
(expect-stays "and the CONTAINER does not escape by being written to"
              stored-into-heap 'outer)

(expect-escapes "cons stores both of its operands"
                (anf (let ([v (primcall make-vector ([type-check checked]) n zero)])
                       (let ([p (primcall cons () v v)])
                         (quote 0))))
                'v 'heap-store)

(expect-escapes "so does the fill of a make-vector"
                (anf (let ([v (primcall make-vector ([type-check checked]) n zero)])
                       (let ([w (primcall make-vector ([type-check checked]) n v)])
                         (quote 0))))
                'v 'heap-store)

;; --- 3. passed to an unknown call ------------------------------------------

(expect-escapes "an allocation passed to a callee we cannot enumerate escapes"
                (anf (let ([v (primcall make-flvector ([type-check checked]) n zero)])
                       (let ([r (call f v)])
                         (quote 0))))
                'v 'unknown-call)

;; --- 4. returned -----------------------------------------------------------

(expect-escapes "an allocation in tail position is returned, which outlives the
       frame by definition"
                (anf (let ([v (primcall make-flvector ([type-check checked]) n zero)])
                       v))
                'v 'returned)

(expect-stays "but the SAME allocation is fine when the tail value is a flonum
       read out of it rather than the object itself"
              non-escaping 'v)

;; The test of an `if` is consumed where it stands; only the arms are tail.
(expect-escapes "returned from one arm of a branch is still returned"
                (anf (let ([v (primcall make-flvector ([type-check checked]) n zero)])
                       (let ([t (primcall fx< () i n)])
                         (if t v (quote 0)))))
                'v 'returned)

;; --- 5. the Scheme-specific route: a tail call pops the frame ---------------
;;
;; This is the rule a CL or Java escape analysis never needs and the one that
;; decides whether this pass is right on real Scheme. Note the callee here is
;; KNOWN and its body does nothing with the argument at all. It still escapes,
;; because by the time the body runs the frame holding the object is gone.

(define known-tailcall
  (anf (let ([g (lambda (p) (quote 0))])
         (let ([v (primcall make-flvector ([type-check checked]) n zero)])
           (tailcall g v)))))

(expect-escapes "passed to a tail call, the object escapes even though the
       callee is KNOWN: the frame is popped before the callee runs"
                known-tailcall 'v 'tail-call)

(let ([tbl (escape-analyze known-tailcall)])
  (ck! "and it escapes via the tail call SPECIFICALLY, not by being treated as
       an unknown callee: the analysis knows exactly where g is"
       (and (memq 'g (escape-known-procs tbl))
            (not (memq 'unknown-call
                       (escape-site-reasons tbl (escape-site-of tbl 'v)))))))

;; --- 6. and the same fact reaches free variables ---------------------------
;;
;; The tail call does not only kill its arguments, it kills the frame. A free
;; variable read inside a tail-entered procedure points into storage that is
;; already gone.

(define cross-frame
  (anf (let ([xs (primcall make-flvector ([type-check checked]) n zero)])
         (letrec ([go (lambda (k)
                        (let ([r (primcall flvector-ref ([type-check checked] [bounds-check checked]) xs k)])
                          r))])
           (tailcall go zero)))))

(expect-escapes "a free variable read inside a procedure ENTERED BY A TAIL CALL
       escapes, because the frame it lived in was popped to get there"
                cross-frame 'xs 'cross-frame)

;; The contrast that makes the rule worth having rather than blunt: the same
;; procedure, entered by an ordinary call, keeps the caller's frame underneath
;; it. This is the whole dynamic-extent win.
(define known-call
  (anf (let ([xs (primcall make-flvector ([type-check checked]) n zero)])
         (let ([go (lambda (k)
                     (let ([r (primcall flvector-ref ([type-check checked] [bounds-check checked]) xs k)])
                       r))])
           (let ([out (call go zero)])
             (quote 0))))))

(expect-stays "entered by an ORDINARY call, the same free read is safe: the
       caller's frame is still underneath the callee"
              known-call 'xs)

(expect-stays "and an argument passed to a known non-tail callee stays in the
       caller's frame, which is what CL spells dynamic-extent by hand"
              (anf (let ([h (lambda (p)
                              (let ([r (primcall flvector-ref ([type-check checked] [bounds-check checked]) p i)])
                                r))])
                     (let ([v (primcall make-flvector ([type-check checked]) n zero)])
                       (let ([r (call h v)])
                         (quote 0)))))
              'v)

;; A self tail call replaces the procedure's OWN frame. If it counted, every
;; loop in the language would poison its own free variables and the pass would
;; report nothing on any real program.
(let ([tbl (escape-analyze
            (anf (let ([xs (primcall make-flvector ([type-check checked]) n zero)])
                   (letrec ([go (lambda (k)
                                  (let ([t (primcall fx< () k n)])
                                    (if t
                                        (let ([k2 (primcall fx+ ([overflow-check checked]) k one)])
                                          (tailcall go k2))
                                        (quote 0))))])
                     (let ([out (call go zero)])
                       (quote 0))))))])
  (ck! "a SELF tail call does not mark a procedure tail-entered: it replaces
       its own frame, not the one its free variables live in"
       (not (escape-tail-entered? tbl 'go)))
  (ck! "so a loop written as self tail recursion does not poison the arrays it
       was called with"
       (not (escape-escapes? tbl 'xs))))

;; --- 7. closures are allocations too ---------------------------------------

(let ([tbl (escape-analyze known-call)])
  (ck! "a known procedure's closure is an allocation site and it is
       stack-allocatable: Keep measured the closure half at 3.6%"
       (let ([s (escape-site-of tbl 'go)])
         (and s (eq? 'closure (site-kind s)) (not (escape-site-escapes? tbl s))))))

(let ([tbl (escape-analyze cross-frame)])
  (ck! "but a tail-entered procedure's closure escapes, because the tail call
       popped the frame the closure itself was sitting in"
       (let ([s (escape-site-of tbl 'go)])
         (and s (memq 'tail-call (escape-site-reasons tbl s))))))

(expect-escapes "a procedure used as a VALUE rather than only as an operator is
       not known, and its closure escapes"
                (anf (let ([k (lambda (p) (quote 0))])
                       (let ([r (call apply1 k)])
                         (quote 0))))
                'k 'closure)

;; --- 8. what assignment conversion costs, bought back ----------------------
;;
;; This is the shape assignment conversion emits for a mutated flonum local: a
;; one-slot cell, read and written on every iteration. It is an ordinary
;; allocation site, so the ordinary rules apply, and a box that does not escape
;; is a frame slot, which regalloc.ss then turns into a register.

(expect-stays "a one-slot box for a mutated local does not escape, so the
       mutated flonum never needs to be in the heap at all"
             (anf (let ([bx (primcall make-vector ([type-check checked]) one zero)])
                    (let ([cur (primcall vector-ref ([type-check checked] [bounds-check checked]) bx zero)])
                      (let ([nxt (primcall fl+ ([fp-contract checked]) cur step)])
                        (let ([u (primcall vector-set! ([type-check checked] [bounds-check checked]) bx zero nxt)])
                          (let ([out (primcall flvector-ref ([type-check checked] [bounds-check checked]) acc zero)])
                            out))))))
             'bx)

;; And the box loses it the moment it is handed out, which is the case where
;; the mutable variable genuinely is shared.
(expect-escapes "a box captured by a closure we cannot account for is a real
       heap box and the analysis says so"
                (anf (let ([bx (primcall make-vector ([type-check checked]) one zero)])
                       (let ([k (lambda (u)
                                  (let ([r (primcall vector-ref ([type-check checked] [bounds-check checked]) bx zero)])
                                    r))])
                         (let ([r (call apply1 k)])
                           (quote 0)))))
                'bx 'captured)

;; --- 9. nbody ---------------------------------------------------------------
;;
;; The shape the benchmark actually has: three long-lived arrays allocated in
;; the top-level frame, and a tail-recursive `advance` that reads them and
;; keeps a per-step scratch array of its own.
;;
;; The right answer is NOT "all three arrays are stack-allocatable". The tail
;; call into `advance` pops the frame they would live in, so they are heap data
;; and calling them anything else would be a dangling pointer. What IS
;; recovered is the per-step scratch, which is homed inside `advance` and never
;; leaves it. That is the honest size of this pass on this benchmark, and
;; PLAN.md already said so: 3 to 4%, not transformative.

(define nbody
  (anf (let ([xs (primcall make-flvector ([type-check checked]) n zero)])
         (let ([vs (primcall make-flvector ([type-check checked]) n zero)])
           (let ([ms (primcall make-flvector ([type-check checked]) n zero)])
             (letrec ([advance
                       (lambda (k)
                         (let ([scratch (primcall make-flvector ([type-check checked]) three zero)])
                           (let ([px (primcall flvector-ref ([type-check checked] [bounds-check checked]) xs k)])
                             (let ([pv (primcall flvector-ref ([type-check checked] [bounds-check checked]) vs k)])
                               (let ([pm (primcall flvector-ref ([type-check checked] [bounds-check checked]) ms k)])
                                 (let ([d (primcall fl* ([fp-contract checked]) pv pm)])
                                   (let ([u (primcall flvector-set! ([type-check checked] [bounds-check checked]) scratch zero d)])
                                     (let ([t (primcall fx< () k n)])
                                       (if t
                                           (let ([k2 (primcall fx+ ([overflow-check checked]) k one)])
                                             (tailcall advance k2))
                                           (quote 0))))))))))])
               (tailcall advance zero)))))))

(expect-escapes "nbody's position array escapes: the tail call into advance
       popped the frame it was allocated in" nbody 'xs 'cross-frame)
(expect-escapes "so does the velocity array" nbody 'vs 'cross-frame)
(expect-escapes "so does the mass array" nbody 'ms 'cross-frame)
(expect-stays "and the per-step scratch does NOT: it is homed inside advance,
       read there, and never passed to the recursive call" nbody 'scratch)

(let ([tbl (escape-analyze nbody)])
  (ck! "advance is a known procedure and it is tail-entered, which is the fact
       the three verdicts above turn on"
       (and (memq 'advance (escape-known-procs tbl))
            (escape-tail-entered? tbl 'advance)))
  (ck! "the stack-allocatable set on nbody is exactly the scratch array"
       (equal? '(scratch) (map site-binder (escape-stack-allocatable tbl)))))

;; --- 10. containment against alias.ss --------------------------------------
;;
;; The two analyses share three escape routes and disagree on the rest. What
;; must hold is one direction: this pass is the stricter of the two, because
;; its consumer writes to a frame. If alias.ss ever reports an escape that this
;; pass does not, one of them is wrong and it is probably this one.

(define (contains? prog vars)
  (let ([a (alias-analyze prog)] [e (escape-analyze prog)])
    (for-all (lambda (v) (or (not (alias-escaped? a v)) (escape-escapes? e v))) vars)))

(ck! "everything alias.ss calls escaped is escaped here too, on every fixture
       in this file"
     (and (contains? non-escaping '(v r))
          (contains? stored-into-heap '(outer v))
          (contains? known-tailcall '(v))
          (contains? cross-frame '(xs))
          (contains? known-call '(xs out))
          (contains? nbody '(xs vs ms scratch))))

;; The one place containment does NOT hold, and it is a deliberate choice in
;; alias.ss rather than a disagreement about escape. alias.ss gives every
;; closure the points-to set `unknown`, on the stated grounds that it never
;; needs to prove two closures distinct and top keeps its default at `may`. Top
;; reads as escaped through `alias-escaped?`, so a procedure name is escaped
;; there and stack-allocatable here. Excluding procedure names from the check
;; above rather than weakening it is the honest way to record that.
(ck! "procedure names are the stated exception: alias.ss makes every closure
       top on purpose, so its escape answer for one carries no information"
     (let ([a (alias-analyze known-call)] [e (escape-analyze known-call)])
       (and (eq? 'unknown (alias-points-to a 'go))
            (alias-escaped? a 'go)
            (not (escape-escapes? e 'go)))))

;; The divergence, named. alias.ss has no notion of a frame, so it sees nothing
;; wrong with nbody's arrays; that is correct for ITS question and wrong for
;; this one, which is why the two are separate passes rather than one.
(ck! "and the containment is strict on nbody: alias.ss does not consider the
       arrays escaped, because a frame is not a thing it models"
     (let ([a (alias-analyze nbody)] [e (escape-analyze nbody)])
       (and (not (alias-escaped? a 'xs)) (escape-escapes? e 'xs))))

;; --- 11. defaults ----------------------------------------------------------

(ck! "a variable we know nothing about is top, and top escapes: we cannot
       promise a frame outlives what we cannot name"
     (escape-escapes? (escape-analyze non-escaping) 'nowhere))

(ck! "a value read back out of a heap object is top, so it escapes"
     (escape-escapes?
      (escape-analyze (anf (let ([p (primcall car ([type-check checked]) q)]) p)))
      'p))

(newline)
(printf "~a checks, ~a failures\n" checks failures)
(if (> failures 0) (exit 1) (begin (printf "PASS\n") (exit 0)))
