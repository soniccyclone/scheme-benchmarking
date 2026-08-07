;;; Tests for the Pentagon domain.
;;;
;;; interval-test.ss says the important half is the SOUNDNESS test rather than
;;; the lattice laws, and that goes double here, because Pentagon has two halves
;;; that can each be individually correct while their interaction is not. So the
;;; harness is Cousot's local consistency condition again, checked by exhaustive
;;; concretization over a small finite grid:
;;;
;;;     for every concrete assignment v in gamma(a) union gamma(b):
;;;         v must be in gamma(a join b), and in gamma(a widen b)
;;;
;;; A Pentagon over two variables concretizes to a set of POINTS rather than to
;;; a set of integers, so gamma is a bitmask over the grid and containment is a
;;; bitwise subset test. That is what makes the full ordered-pair product over
;;; several hundred states affordable, and the product is the point: a widening
;;; bug that only shows on one pair of iterates has to be looked for on every
;;; pair, not on a hand-picked sequence.
;;;
;;; THE FIGURE 3 HAZARD IS TESTED DIRECTLY.
;;;
;;; The paper's Figure 3 prints an unsound widening in both halves. The defect
;;; is the same shape in each: the stability test is written one way round and
;;; the value kept is the other one. It is invisible on a monotone increasing
;;; sequence, which is what a naive test suite produces, because under monotone
;;; growth the mis-directed test simply fails and the result jumps to top.
;;;
;;; So this file reconstructs the defective operator, asserts that the harness
;;; CATCHES it on a non-monotone pair, and asserts that the same harness reports
;;; it clean on a monotone one. A soundness test that cannot catch the known bug
;;; is decoration, and the second assertion is what proves the first is not
;;; passing by accident.
;;;
;;; Run: scheme -q --libdirs src:vendor/nanopass --script test/pentagon-test.ss

(import (chezscheme) (nanopass) (sonic lang) (sonic fixtures)
        (sonic interval) (sonic pentagon))

(define failures 0)
(define checks 0)

(define (check! name got expected)
  (set! checks (+ checks 1))
  (if (equal? got expected)
      (printf "  ok   ~a\n" name)
      (begin (set! failures (+ failures 1))
             (printf "  FAIL ~a\n         expected ~s\n         got      ~s\n"
                     name expected got))))

(define (check-true! name v) (check! name (and v #t) #t))

(define (iv-pair a) (list (interval-lo a) (interval-hi a)))

;; --- the concretization harness --------------------------------------------

;; Every point of the grid, as a list of values parallel to `vars`.
(define (grid vars lo hi)
  (if (null? vars)
      '(())
      (let ([rest (grid (cdr vars) lo hi)])
        (let outer ([v lo] [acc '()])
          (if (> v hi)
              (reverse acc)
              (outer (+ v 1)
                     (append (reverse (map (lambda (r) (cons v r)) rest)) acc)))))))

(define (val-of vars point x)
  (let scan ([vs vars] [ps point])
    (cond [(null? vs) #f]
          [(eq? (car vs) x) (car ps)]
          [else (scan (cdr vs) (cdr ps))])))

(define (in-interval? a v)
  (and (not (iv-bot? a))
       (let ([lo (interval-lo a)] [hi (interval-hi a)])
         (and (or (eq? lo 'neginf) (>= v lo))
              (or (eq? hi 'posinf) (<= v hi))))))

;; Does this concrete assignment satisfy every constraint the state records?
;; Both halves, which is the definition of gamma for a Pentagon.
(define (satisfies? s vars point)
  (and (not (pt-bot? s))
       (for-all (lambda (x) (in-interval? (pt-interval s x) (val-of vars point x)))
                vars)
       (for-all (lambda (x)
                  (for-all (lambda (y)
                             (< (val-of vars point x) (val-of vars point y)))
                           (pt-subs s x)))
                vars)))

;; gamma as a bitmask over the grid, so containment is one bitwise operation.
(define (gamma s vars points)
  (let loop ([ps points] [bit 1] [m 0])
    (if (null? ps)
        m
        (loop (cdr ps) (* bit 2)
              (if (satisfies? s vars (car ps)) (+ m bit) m)))))

(define (subset-mask? a b) (zero? (bitwise-and a (bitwise-not b))))

;; --- state generation -------------------------------------------------------

(define (states-over vars ivs sub-configs)
  ;; every combination of one interval per variable, crossed with every
  ;; recorded set of strict upper bounds.
  (let ([iv-combos
         (let build ([vs vars])
           (if (null? vs)
               '(())
               (let ([rest (build (cdr vs))])
                 (apply append
                        (map (lambda (a)
                               (map (lambda (r) (cons (cons (car vs) a) r)) rest))
                             ivs)))))])
    (apply append
           (map (lambda (ic)
                  (map (lambda (sc) (make-pt ic sc)) sub-configs))
                iv-combos))))

;; Run the full ordered-pair product of an operator against its soundness
;; condition. `want` maps the two argument masks to the mask the result must
;; contain.
(define (pair-soundness name op want ss vars points)
  (let* ([n (length ss)]
         [sv (list->vector ss)]
         [gv (list->vector (map (lambda (s) (gamma s vars points)) ss))]
         [bad 0]
         [witness #f])
    (do ([i 0 (+ i 1)]) ((= i n))
      (do ([j 0 (+ j 1)]) ((= j n))
        (let* ([a (vector-ref sv i)] [b (vector-ref sv j)]
               [r (op a b)]
               [need (want (vector-ref gv i) (vector-ref gv j))])
          (unless (subset-mask? need (gamma r vars points))
            (set! bad (+ bad 1))
            (unless witness (set! witness (list (pt->string a) (pt->string b)
                                                (pt->string r))))))))
    (set! checks (+ checks 1))
    (if (zero? bad)
        (printf "  ok   ~a  (~a ordered pairs)\n" name (* n n))
        (begin (set! failures (+ failures 1))
               (printf "  FAIL ~a: ~a of ~a pairs unsound\n         witness ~s\n"
                       name bad (* n n) witness)))
    bad))

;; The same sweep, reporting only whether it found anything. Used to show that
;; the harness catches the Figure 3 defect rather than to assert a property.
(define (pair-unsound-count op want ss vars points)
  (let* ([sv (list->vector ss)]
         [n (vector-length sv)]
         [gv (list->vector (map (lambda (s) (gamma s vars points)) ss))]
         [bad 0])
    (do ([i 0 (+ i 1)]) ((= i n))
      (do ([j 0 (+ j 1)]) ((= j n))
        (let ([r (op (vector-ref sv i) (vector-ref sv j))])
          (unless (subset-mask? (want (vector-ref gv i) (vector-ref gv j))
                                (gamma r vars points))
            (set! bad (+ bad 1))))))
    bad))

(define (union-of a b) (bitwise-ior a b))
(define (intersection-of a b) (bitwise-and a b))

;; --- 1. soundness over two variables ----------------------------------------

(printf "soundness, exhaustive over the [-2,2] x [-2,2] grid:\n")

(define vars2 '(x y))
(define points2 (grid vars2 -2 2))

(define ivs2
  (list iv-top
        (iv-range 0 'posinf)
        (iv-range 'neginf 1)
        (iv-range -2 -1)
        (iv-range 0 0)
        (iv-range 0 1)
        (iv-range -1 2)
        (iv-range 1 2)))

;; Both orders of the pair, and both at once. The last is unsatisfiable and is
;; here on purpose: a state whose concretization is empty must not be reported
;; as containing anything.
(define subs2 '(() ((x y)) ((y x)) ((x y) (y x))))

(define states2 (states-over vars2 ivs2 subs2))

(printf "  ~a states\n" (length states2))

(pair-soundness "join over-approximates both arguments"
                pt-join union-of states2 vars2 points2)
(pair-soundness "meet over-approximates their intersection"
                pt-meet intersection-of states2 vars2 points2)
(pair-soundness "WIDEN over-approximates both arguments"
                pt-widen union-of states2 vars2 points2)

;; The order relation has to agree with the concretization, or the fixpoint loop
;; stops early on a state that does not contain the one before it.
(let ([bad 0])
  (let* ([sv (list->vector states2)]
         [n (vector-length sv)]
         [gv (list->vector (map (lambda (s) (gamma s vars2 points2)) states2))])
    (do ([i 0 (+ i 1)]) ((= i n))
      (do ([j 0 (+ j 1)]) ((= j n))
        (when (pt-leq (vector-ref sv i) (vector-ref sv j))
          (unless (subset-mask? (vector-ref gv i) (vector-ref gv j))
            (set! bad (+ bad 1)))))))
  (check! "a <= b implies gamma(a) is contained in gamma(b)" bad 0))

;; THE QUERIES THE DOMAIN EXISTS FOR. Everything above is machinery; these two
;; are what a check-elision client acts on, and a false positive here deletes a
;; check that was needed.
(let ([bad-lt 0] [bad-in 0])
  (for-each
   (lambda (s)
     (for-each
      (lambda (p)
        (when (satisfies? s vars2 p)
          (let ([vx (val-of vars2 p 'x)] [vy (val-of vars2 p 'y)])
            (when (and (pt-lt? s 'x 'y) (not (< vx vy))) (set! bad-lt (+ bad-lt 1)))
            (when (and (pt-lt? s 'y 'x) (not (< vy vx))) (set! bad-lt (+ bad-lt 1)))
            (when (and (pt-within? s 'x 'y) (not (and (>= vx 0) (< vx vy))))
              (set! bad-in (+ bad-in 1))))))
      points2))
   states2)
  (check! "pt-lt? never claims an ordering a concrete state violates" bad-lt 0)
  (check! "pt-within? never claims an index a concrete state violates" bad-in 0))

;; --- 2. soundness over three variables --------------------------------------
;;
;; Two variables cannot exercise the join's reduction terms against a CHAIN, and
;; a chain is where a domain that quietly closes its constraint map would show
;; up. Smaller grid, because the state space is the cube.

(printf "\nsoundness, exhaustive over the [-1,1]^3 grid:\n")

(define vars3 '(x y z))
(define points3 (grid vars3 -1 1))
(define ivs3 (list iv-top (iv-range 0 'posinf) (iv-range -1 0) (iv-range 1 1)))
(define subs3
  '(()
    ((x y))
    ((y z))
    ((x y) (y z))
    ((x y) (y z) (x z))
    ((x z))))

(define states3 (states-over vars3 ivs3 subs3))
(printf "  ~a states\n" (length states3))

(pair-soundness "join over-approximates both arguments"
                pt-join union-of states3 vars3 points3)
(pair-soundness "WIDEN over-approximates both arguments"
                pt-widen union-of states3 vars3 points3)

;; --- 3. widening, with the direction pinned by hand -------------------------

(printf "\nwidening:\n")

(define (iv-of s x) (iv-pair (pt-interval s x)))

(define stable (make-pt (list (cons 'i (iv-range 0 10))) '((i n))))

(check! "widen: a stable interval bound is kept"
        (iv-of (pt-widen stable stable) 'i) '(0 10))
(check! "widen: an unstable upper bound goes to +inf"
        (iv-of (pt-widen stable (make-pt (list (cons 'i (iv-range 0 11))) '())) 'i)
        '(0 posinf))
(check! "widen: an unstable lower bound goes to -inf"
        (iv-of (pt-widen stable (make-pt (list (cons 'i (iv-range -1 10))) '())) 'i)
        '(neginf 10))

;; The Sub half, and its direction is the second thing Figure 3 gets wrong.
(check! "widen: a constraint both states hold survives"
        (pt-subs (pt-widen stable stable) 'i) '(n))
(check! "widen: a constraint the NEW state lost is dropped"
        (pt-subs (pt-widen stable (make-pt (list (cons 'i (iv-range 0 10))) '())) 'i)
        '())
;; The one an argument-reversed operator gets backwards. A constraint that
;; appears for the first time in the new iterate must NOT survive: the result
;; has to contain the old state too, and the old state never said it.
(check! "widen: a constraint only the NEW state has is REFUSED"
        (pt-subs (pt-widen (make-pt (list (cons 'i (iv-range 0 10))) '()) stable) 'i)
        '())

;; Termination. The whole reason a widening exists: the concrete sequence grows
;; without limit and the abstract one must not.
(let loop ([cur (make-pt (list (cons 'i (iv-const 0))) '())] [k 0])
  (cond
   [(> k 50) (check! "widening terminates" 'diverged 'converged)]
   [else
    (let* ([guarded (pt-refine cur 'fx< #f 'i 'n)]
           [stepped (pt-set-interval guarded 'i
                                     (iv-add (pt-interval guarded 'i) (iv-const 1)))]
           [next (pt-widen cur (pt-join cur stepped))])
      (if (pt-leq next cur)
          (begin
            (check! "widening terminates" 'converged 'converged)
            (check! "and the header's index is [0,+inf)" (iv-of next 'i) '(0 posinf))
            ;; The guard is re-established INSIDE the body by the sigma, not
            ;; carried through the header, because the entry state never had it.
            (check! "the header carries no constraint the entry state lacked"
                    (pt-subs next 'i) '())
            (check-true! "and the body's refined index is still below n"
                         (pt-lt? (pt-refine next 'fx< #f 'i 'n) 'i 'n)))
          (loop next (+ k 1))))]))

;; --- 4. Figure 3, reconstructed and caught ----------------------------------

(printf "\nthe Figure 3 widening:\n")

(define (ble? a b)                      ; bound <=, as interval.ss spells it
  (cond [(eq? a 'neginf) #t]
        [(eq? b 'posinf) #t]
        [(eq? a 'posinf) (eq? b 'posinf)]
        [(eq? b 'neginf) (eq? a 'neginf)]
        [else (<= a b)]))

(define (subset-syms? a b) (for-all (lambda (y) (memq y b)) a))

;; The operator as printed: in each half the stability test is written one way
;; round and the value kept is the other one.
(define (figure3-widen vars)
  (lambda (old new)
    (cond
     [(pt-bot? old) new]
     [(pt-bot? new) old]
     [else
      (make-pt
       (map (lambda (x)
              (let ([a (pt-interval old x)] [b (pt-interval new x)])
                (cons x
                      (make-interval
                       (if (ble? (interval-lo a) (interval-lo b))
                           (interval-lo b) 'neginf)
                       (if (ble? (interval-hi b) (interval-hi a))
                           (interval-hi b) 'posinf)))))
            vars)
       (map (lambda (x)
              (let ([so (pt-subs old x)] [sn (pt-subs new x)])
                (cons x (if (subset-syms? so sn) sn '()))))
            vars))])))

;; Each half on its own, so the report says which one, and so that fixing one
;; and leaving the other cannot pass.
(define (figure3-intervals-only vars)
  (lambda (old new)
    (let ([f ((figure3-widen vars) old new)])
      (if (pt-bot? f) f (make-pt (map (lambda (x) (cons x (pt-interval f x))) vars)
                                 (map (lambda (x) (cons x (pt-subs (pt-widen old new) x)))
                                      vars))))))

(define (figure3-subs-only vars)
  (lambda (old new)
    (let ([f ((figure3-widen vars) old new)]
          [g (pt-widen old new)])
      (if (or (pt-bot? f) (pt-bot? g))
          (pt-widen old new)
          (make-pt (map (lambda (x) (cons x (pt-interval g x))) vars)
                   (map (lambda (x) (cons x (pt-subs f x))) vars))))))

(let ([n-both (pair-unsound-count (figure3-widen vars2) union-of
                                  states2 vars2 points2)]
      [n-iv (pair-unsound-count (figure3-intervals-only vars2) union-of
                                states2 vars2 points2)]
      [n-sub (pair-unsound-count (figure3-subs-only vars2) union-of
                                 states2 vars2 points2)])
  (printf "  it is unsound on ~a pairs (interval half ~a, Sub half ~a)\n"
          n-both n-iv n-sub)
  (check-true! "the harness catches Figure 3's interval half" (> n-iv 0))
  (check-true! "the harness catches Figure 3's Sub half" (> n-sub 0)))

;; AND THE MASKING, which is the reason the sweep above had to be written at
;; all. Restricted to a monotone increasing sequence the defective operator is
;; sound on every pair, so a test suite built from one loop's iterates reports
;; a clean bill of health.
(let* ([mono (filter (lambda (p) (pt-leq (car p) (cdr p)))
                     (apply append
                            (map (lambda (a)
                                   (map (lambda (b) (cons a b)) states2))
                                 states2)))]
       [bad (let count ([ps mono] [n 0])
              (cond [(null? ps) n]
                    [else
                     (let* ([a (car (car ps))] [b (cdr (car ps))]
                            [r ((figure3-widen vars2) a b)])
                       (count (cdr ps)
                              (if (subset-mask? (bitwise-ior (gamma a vars2 points2)
                                                             (gamma b vars2 points2))
                                                (gamma r vars2 points2))
                                  n (+ n 1))))]))])
  (printf "  on the ~a monotone increasing pairs it looks clean\n" (length mono))
  (check! "Figure 3 is invisible on a monotone increasing sequence" bad 0))

;; --- 5. no closure, per D6 --------------------------------------------------

(printf "\nno closure:\n")

(let ([s (pt-assume-lt (pt-assume-lt pt-top 'x 'y) 'y 'z)])
  (check-true! "x < y is recorded" (pt-lt? s 'x 'y))
  (check-true! "y < z is recorded" (pt-lt? s 'y 'z))
  ;; The refusal D6 buys. Closure would conclude it, at three times the analysis
  ;; time and, on three of Logozzo's four assemblies, for less precision overall.
  (check! "x < z is NOT concluded from the chain" (pt-lt? s 'x 'z) #f))

;; What Sub cannot say at all. A non-strict bound has nowhere to go, so the edge
;; refines the intervals and records nothing.
(let ([s (pt-refine pt-top 'fx<= #f 'x 'y)])
  (check! "a non-strict comparison records no constraint" (pt-subs s 'x) '()))

;; x < x is not imprecise, it is unsatisfiable.
(check-true! "assuming x < x is bottom" (pt-bot? (pt-assume-lt pt-top 'x 'x)))

;; --- 6. the join's reduction, which is what closure was NOT needed for -------

(printf "\nthe join:\n")

;; One arm records the constraint and has useless intervals; the other proves it
;; from intervals alone and records nothing. A direct product loses the fact at
;; the merge. Logozzo's join keeps it, and this is the precision that pays for
;; refusing closure.
(let* ([recorded (pt-assume-lt (pt-set-interval pt-top 'i (iv-range 0 'posinf)) 'i 'n)]
       [by-intervals (make-pt (list (cons 'i (iv-range 0 3))
                                    (cons 'n (iv-range 10 20)))
                              '())]
       [j (pt-join recorded by-intervals)])
  (check-true! "the constraint survives a join with an arm that only implies it"
               (pt-lt? j 'i 'n))
  (check! "and the intervals joined as intervals do" (iv-of j 'i) '(0 posinf))
  ;; The other direction of the same rule.
  (check-true! "and it survives with the arms the other way round"
               (pt-lt? (pt-join by-intervals recorded) 'i 'n)))

;; The refusal that proves the rule above is not just keeping everything.
(let* ([recorded (pt-assume-lt (pt-set-interval pt-top 'i (iv-range 0 'posinf)) 'i 'n)]
       [neither (make-pt (list (cons 'i (iv-range 0 'posinf))) '())])
  (check! "a constraint neither implied nor recorded in the other arm is dropped"
          (pt-lt? (pt-join recorded neither) 'i 'n) #f))

;; --- 7. the NaN rule, inherited and not restated ----------------------------

(printf "\nedges and NaN:\n")

(check-true! "the true edge of (fl< a b) records a < b"
             (pt-lt? (pt-refine pt-top 'fl< #f 'a 'b) 'a 'b))
;; (not (fl< a b)) is TRUE when either operand is NaN, where (fl>= a b) is
;; false. interval.ss is the one place that rule lives; this file must not
;; acquire a second copy of it.
(check! "the false edge of (fl< a b) records nothing"
        (let ([s (pt-refine pt-top 'fl< #t 'a 'b)])
          (list (pt-subs s 'a) (pt-subs s 'b)))
        '(() ()))
;; The false edge of (fx< a b) is a >= b, which is NON-STRICT and therefore has
;; nowhere to go in Sub. The false edge of (fx<= a b) is a > b, which is strict
;; and does. That asymmetry is not a special case in this file: iv-edge-cmp
;; hands back the comparison and the strictness follows from it.
(check! "the false edge of (fx< a b) is non-strict and records nothing"
        (let ([s (pt-refine pt-top 'fx< #t 'a 'b)])
          (list (pt-subs s 'a) (pt-subs s 'b)))
        '(() ()))
(check-true! "the false edge of (fx<= a b) records b < a"
             (pt-lt? (pt-refine pt-top 'fx<= #t 'a 'b) 'b 'a))
(check! "an equality records no strict bound in either direction"
        (let ([s (pt-refine pt-top 'fx= #f 'a 'b)])
          (list (pt-subs s 'a) (pt-subs s 'b)))
        '(() ()))

;; --- 8. the real fixture ----------------------------------------------------
;;
;; The claim this domain has to earn: it proves an access interval.ss cannot.
;;
;; The fact is READ OUT of the frozen nbody fixture's own sigma rather than
;; retyped here, so if stage 06's output shape changes this test changes with
;; it. `nbody-facts` in elide-test.ss states `(i interval 0 posinf)` and states
;; NO upper bound, which is the honest description of a loop index whose bound
;; arrived from a caller.

(printf "\nnbody's guard, from the frozen fixture:\n")

(define (nbody-sigma)
  (let find ([e (nbody-inner-ssa)])
    (nanopass-case (Lssa Expr) e
      [(let ([,x ,se]) ,body) (find body)]
      [(if ,x ,e0 ,e1) (find e0)]
      [(sigma ,x0 ,x1 ,pr ,x2 ,b ,body) (list x0 x1 pr x2 b)]
      [else #f])))

(check! "the fixture's guard is (sigma i2 i fx< n #f)"
        (nbody-sigma) '(i2 i fx< n #f))

;; How a client consumes a sigma: refine on the pair the comparison names, then
;; carry what was learned onto the refined name. e-SSA exists so the fact and
;; the name have the same scope, and this is where that pays.
(define (apply-sigma s x0 x1 pr x2 negated?)
  (let* ([s1 (pt-refine s pr negated? x1 x2)]
         [s2 (pt-set-interval s1 x0 (pt-interval s1 x1))])
    (fold-left (lambda (st y) (pt-assume-lt st x0 y)) s2 (pt-subs s1 x1))))

(let* ([g (nbody-sigma)]
       [entry (pt-set-interval pt-top 'i (iv-range 0 'posinf))]
       [s (apply-sigma entry (car g) (cadr g) (caddr g) (cadddr g) (car (cddddr g)))])
  (printf "  ~a\n" (pt->string s))
  ;; What the interval half alone can say, which is nothing: the length is a
  ;; parameter, so its interval is top and the index has no finite upper bound.
  (check! "the index's interval is still unbounded above" (iv-of s 'i2) '(0 posinf))
  ;; All the interval half learned about the length is that it is positive,
  ;; which is the guard's own arithmetic and not a bound on anything.
  (check! "and the length is only known to be above zero" (iv-of s 'n) '(1 posinf))
  (check! "so interval.ss REFUSES the access"
          (iv-within? (pt-interval s 'i2) (pt-interval s 'n)) #f)
  ;; And what Pentagon says, with n still unknown.
  (check-true! "Pentagon DISCHARGES it, from 0 <= i2 and i2 < n"
               (pt-within? s 'i2 'n)))

;; The refusals, so the test above is not proving itself. Drop either half of
;; the pentagon and the access comes back.
(let* ([g (nbody-sigma)]
       [no-lower (apply-sigma pt-top (car g) (cadr g) (caddr g) (cadddr g)
                              (car (cddddr g)))])
  (check! "without 0 <= i the access is refused" (pt-within? no-lower 'i2 'n) #f))

(let ([no-guard (pt-set-interval pt-top 'i2 (iv-range 0 'posinf))])
  (check! "without the guard the access is refused" (pt-within? no-guard 'i2 'n) #f))

(newline)
(printf "~a checks, ~a failures\n" checks failures)
(if (> failures 0) (begin (printf "FAIL\n") (exit 1)) (begin (printf "PASS\n") (exit 0)))
