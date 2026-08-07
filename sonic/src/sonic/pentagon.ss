;;; SonicScheme: the Pentagon abstract domain.
;;;
;;; Stage 06, level 3 in the Cousot hierarchy. Logozzo and Fahndrich, "Pentagons:
;;; a weakly relational abstract domain for the efficient validation of array
;;; accesses" (SAC 2008, extended in SCP 2010).
;;;
;;; A Pentagon is  x in [a,b]  AND  x < y : intervals, plus a set of STRICT
;;; UPPER BOUNDS per variable. Two halves, and the second is the whole reason
;;; the domain exists.
;;;
;;; WHAT IT BUYS OVER interval.ss, AND IT IS EXACTLY ONE THING.
;;;
;;; interval.ss discharges nbody's `b[i*7 + k]` because both operands have
;;; CONSTANT bounds: i in [0,4] and k in [0,6] give [0,34], and 34 < 35. That is
;;; the whole of nbody and it needs no relational information at all.
;;;
;;; It cannot discharge `b[i]` guarded by `i < n` when n is a parameter. The
;;; index is bounded by a VALUE the analysis does not know, so the interval for
;;; i after widening is [0,+inf) and the interval for n is top, and no amount of
;;; interval arithmetic recovers the relation between them. That access is every
;;; loop over an array whose length arrived from a caller, which is every kernel
;;; that is not a fixed-size fixture. Pentagon represents `i < n` directly, so
;;; the check goes with n still unknown. See pentagon-test.ss, where the fact is
;;; read out of the frozen nbody fixture's own sigma rather than retyped.
;;;
;;; D6 IS RATIFIED AND BINDING: THERE IS NO CLOSURE HERE.
;;;
;;; Logozzo section 8.1 measured closure making Pentagons LESS precise on three
;;; of four .NET assemblies, 82.77% against 83.19% on mscorlib, while tripling
;;; analysis time. Less precise, because a closed sub-map joins worse: closure
;;; manufactures constraints in one branch that the other branch never had, and
;;; the join then drops the originals too.
;;;
;;; The reason is structural and not only cost. Mine's octagons need closure to
;;; make the constraint matrix canonical, and closure over a matrix that grows
;;; during iteration is where the infinite ascending chain in his widening comes
;;; from. Pentagon's Sub has no closure, so that hazard cannot arise: Sub over a
;;; fixed program has a finite variable set, constraints are only ever REMOVED
;;; going up the lattice, and the height is therefore bounded by |V|^2. Adding
;;; closure would reintroduce a hazard this design excludes by construction.
;;;
;;; So: the two halves talk to each other in exactly two places, and neither is
;;; a transitive completion.
;;;
;;;   1. `pt-assume-lt` and `pt-refine` tighten the intervals from the new
;;;      constraint, which is the interval domain's own assume and nothing more.
;;;   2. `pt-join` keeps a constraint held by one side when the OTHER side's
;;;      intervals prove it. This is Logozzo's join and it is what makes the
;;;      domain a reduced product rather than a direct one.
;;;
;;; Nothing iterates. `pt-lt?` does not chase x < y < z to conclude x < z, and
;;; there is a test that pins that refusal, because the day someone adds it as
;;; "an obvious improvement" is the day D6 is silently reversed.
;;;
;;; FIGURE 3 PRINTS AN UNSOUND WIDENING, IN BOTH HALVES.
;;;
;;; The defect is the same in each: the stability test is written one way round
;;; and the value kept is the other one. For intervals, "if lo1 <= lo2 then keep
;;; lo2" returns a bound that does not contain the OLD iterate, so the result is
;;; not an upper bound of its first argument and the fixpoint it converges to is
;;; not a post-fixpoint. For Sub, "if s1(x) subset of s2(x) then keep s2(x)"
;;; returns MORE constraints than the old state had, which is the same failure
;;; spelled over sets.
;;;
;;; Both are invisible while the iterates increase monotonically, which is what
;;; a naive test suite produces: under monotone growth the mis-directed test
;;; simply fails and the result jumps to top, which is sound and looks like a
;;; working widening. The bug only shows on a sequence that narrows or moves
;;; sideways. interval.ss's header says the same thing about iv-widen's argument
;;; order; this file inherits that operator and adds the Sub half, and
;;; pentagon-test.ss reconstructs the defective form and checks that the
;;; soundness harness actually catches it.
;;;
;;; SOUNDNESS DIRECTION. Same as interval.ss. Every operation over-approximates:
;;; the concretization of the result contains the concretization of the inputs,
;;; a state this file cannot represent widens rather than narrows, and `pt-lt?`
;;; and `pt-within?` are the only places a caller gets a positive claim. Those
;;; two are what a check-elision client acts on, so they answer #f unless a
;;; proof is in hand.

(library (sonic pentagon)
  (export make-pt pentagon?
          pt-top pt-bot pt-bot? pt-top?
          pt-vars pt-interval pt-subs
          pt-set-interval pt-refine-interval pt-assign pt-forget
          pt-assume-lt pt-refine
          pt-leq pt-join pt-meet pt-widen
          pt-lt? pt-within? pt->string)
  (import (rnrs base)
          (rnrs lists)
          (rnrs control)
          (rnrs records syntactic)
          (rnrs sorting)
          (sonic interval))

  ;; --- representation -------------------------------------------------------
  ;;
  ;;   ivs   ((x . interval) ...)   absent means top
  ;;   subs  ((x . (y ...)) ...)    absent means no strict upper bound is known
  ;;
  ;; Both are kept sorted and free of trivial entries, so two states that say
  ;; the same thing print the same and compare the same. That is not cosmetic:
  ;; a fixpoint loop tests states for equality to decide it has converged, and a
  ;; representation with two spellings of one state never converges.
  ;;
  ;; Bottom is a flag rather than an interval that happens to be empty. An
  ;; unreachable program point is one state, not one per variable, and folding
  ;; it into the map would make `pt-bot?` a scan that a caller could forget.

  (define-record-type (pentagon make-pentagon pentagon?)
    (fields bottom ivs subs))

  (define pt-bot (make-pentagon #t '() '()))
  (define pt-top (make-pentagon #f '() '()))

  (define (pt-bot? s) (pentagon-bottom s))
  (define (pt-top? s)
    (and (not (pentagon-bottom s))
         (null? (pentagon-ivs s))
         (null? (pentagon-subs s))))

  (define (sym<? a b) (string<? (symbol->string a) (symbol->string b)))
  (define (sort-syms l) (list-sort sym<? l))
  (define (sort-alist al) (list-sort (lambda (p q) (sym<? (car p) (car q))) al))

  (define (uniq l)
    (cond ((null? l) '())
          ((memq (car l) (cdr l)) (uniq (cdr l)))
          (else (cons (car l) (uniq (cdr l))))))

  (define (alist-set al k v)
    (cons (cons k v) (remp (lambda (p) (eq? (car p) k)) al)))

  ;; The one constructor. Everything below builds raw pairs and hands them here,
  ;; so the invariants are established in a single place.
  ;;
  ;; `x < x` is not merely imprecise, it is unsatisfiable, so a state carrying it
  ;; is bottom. Detecting it here is what lets `pt-assume-lt` be written without
  ;; a special case and what keeps `pt-meet` from returning a state whose
  ;; concretization is empty while claiming it is not.
  (define (make-pt ivs subs)
    (cond
     ((exists (lambda (p) (iv-bot? (cdr p))) ivs) pt-bot)
     ((exists (lambda (p) (memq (car p) (cdr p))) subs) pt-bot)
     (else
      (make-pentagon
       #f
       (sort-alist (filter (lambda (p) (not (iv-top? (cdr p)))) ivs))
       (sort-alist
        (map (lambda (p) (cons (car p) (sort-syms (uniq (cdr p)))))
             (filter (lambda (p) (not (null? (cdr p)))) subs)))))))

  ;; --- queries on one state -------------------------------------------------

  (define (pt-interval s x)
    (if (pt-bot? s)
        iv-bot
        (let ((p (assq x (pentagon-ivs s)))) (if p (cdr p) iv-top))))

  (define (pt-subs s x)
    (if (pt-bot? s)
        '()
        (let ((p (assq x (pentagon-subs s)))) (if p (cdr p) '()))))

  ;; Every variable the state says anything about, in either half.
  (define (pt-vars s)
    (if (pt-bot? s)
        '()
        (sort-syms
         (uniq (append (map car (pentagon-ivs s))
                       (map car (pentagon-subs s))
                       (apply append (map cdr (pentagon-subs s))))))))

  ;; --- bound comparison -----------------------------------------------------
  ;; interval.ss keeps its bound arithmetic private, and this is the only piece
  ;; of it this file needs: does the interval half alone prove x < y?
  ;;
  ;; Only finite bounds can prove it. hi(x) = +inf proves nothing and lo(y) =
  ;; -inf proves nothing, and answering #f in both cases is the whole rule.
  (define (bound-lt? hx ly)
    (and (integer? hx) (integer? ly) (< hx ly)))

  (define (ivs-prove-lt? s x y)
    (bound-lt? (interval-hi (pt-interval s x)) (interval-lo (pt-interval s y))))

  ;; THE QUERY. Does this state prove x < y?
  ;;
  ;; Two sources, checked and not combined: the constraint is recorded, or the
  ;; intervals settle it outright. There is deliberately NO third case that
  ;; chases y's own upper bounds, because that is closure, and D6 says no. The
  ;; cost of the refusal is a lost proof on a chain; the cost of the closure was
  ;; measured at three times the analysis time for less precision.
  ;;
  ;; Bottom proves everything, which is sound: an unreachable point has no
  ;; concrete states to be wrong about.
  (define (pt-lt? s x y)
    (or (pt-bot? s)
        (and (memq y (pt-subs s x)) #t)
        (ivs-prove-lt? s x y)))

  ;; The query the domain exists for, and the one interval.ss cannot answer when
  ;; the length is symbolic: is every value of `i` a valid index into a vector
  ;; whose length is the value of `n`?
  ;;
  ;; Note what is asked of each half. The lower bound is an interval fact, since
  ;; `0 <= i` is not a relation between two variables. The upper bound is the
  ;; relation, and it needs no integrality argument: an index is in range exactly
  ;; when i < n, not when i <= n - 1.
  (define (pt-within? s i n)
    (or (pt-bot? s)
        (let ((lo (interval-lo (pt-interval s i))))
          (and (integer? lo) (>= lo 0) (pt-lt? s i n)))))

  ;; --- building states ------------------------------------------------------

  ;; Replace what is known about x. For constructing a state, not for refining
  ;; one: an assignment that keeps the old relations is `pt-set-interval`, and it
  ;; is the caller's job to know that x's relations survived.
  (define (pt-set-interval s x a)
    (if (pt-bot? s)
        s
        (make-pt (alist-set (pentagon-ivs s) x a) (pentagon-subs s))))

  ;; Refine: meet the new interval with what is already known.
  (define (pt-refine-interval s x a)
    (if (pt-bot? s)
        s
        (make-pt (alist-set (pentagon-ivs s) x (iv-meet (pt-interval s x) a))
                 (pentagon-subs s))))

  ;; x := something new. Every relation MENTIONING x dies, in both directions,
  ;; and this is the case a map keyed only on the left-hand side gets wrong: the
  ;; state also holds `w < x` for other w, and the new value of x has nothing to
  ;; do with the old one.
  ;;
  ;; SSA makes this rare rather than useless. A pass over Lssa rebinds instead of
  ;; assigning, so the only client is a loop header re-entering with a new value
  ;; for a phi, which is exactly where forgetting is mandatory.
  (define (pt-assign s x a)
    (if (pt-bot? s)
        s
        (make-pt (alist-set (pentagon-ivs s) x a)
                 (map (lambda (p) (cons (car p) (remq x (cdr p))))
                      (remp (lambda (p) (eq? (car p) x)) (pentagon-subs s))))))

  (define (pt-forget s x) (pt-assign s x iv-top))

  (define (add-sub s x y)
    (make-pt (pentagon-ivs s)
             (alist-set (pentagon-subs s) x (cons y (pt-subs s x)))))

  ;; Assume x < y. Both halves move: the constraint is recorded, and the
  ;; intervals are tightened by the interval domain's own refinement, which is
  ;; where `hi(x) <= hi(y) - 1` comes from.
  (define (pt-assume-lt s x y)
    (cond ((pt-bot? s) s)
          ((eq? x y) pt-bot)
          (else
           (let-values (((a b) (iv-refine '< #f (pt-interval s x) (pt-interval s y))))
             (add-sub (make-pt (alist-set (alist-set (pentagon-ivs s) x a) y b)
                               (pentagon-subs s))
                      x y)))))

  ;; The e-SSA edge, with the same signature interval.ss uses: the comparison as
  ;; the program wrote it, plus which edge this is, plus the optional non-NaN
  ;; premise. (sigma x0 x1 pr x2 b body) hands its fields straight in.
  ;;
  ;; WHAT AN EDGE LICENSES IS NOT DECIDED HERE. `iv-edge-cmp` decides it, and it
  ;; is the only place that knows a failed `fl<` licenses NOTHING because NaN
  ;; makes both spellings false. Re-deriving that rule in this file would put the
  ;; NaN case in two places and eventually in disagreement, and the consumer is
  ;; bounds-check elision, so a disagreement is a wrong-code bug.
  ;;
  ;; Only a strict comparison contributes to Sub. `<=` and `=` refine the
  ;; intervals and add no constraint, because Sub holds STRICT upper bounds and
  ;; there is nowhere to put a non-strict one. That is a real limit of the domain
  ;; and not an omission: `x <= y` would need a second map, which is a different
  ;; domain with a different join.
  (define pt-refine
    (case-lambda
      ((s cmp negated? x y) (pt-refine s cmp negated? x y #f))
      ((s cmp negated? x y non-nan?)
       (let ((c (iv-edge-cmp cmp negated? non-nan?)))
         (cond
          ((not c) s)
          ((pt-bot? s) s)
          (else
           (let-values (((a b) (iv-refine cmp negated?
                                          (pt-interval s x) (pt-interval s y)
                                          non-nan?)))
             (let ((s1 (make-pt (alist-set (alist-set (pentagon-ivs s) x a) y b)
                                (pentagon-subs s))))
               (cond ((eq? c '<) (if (eq? x y) pt-bot (add-sub s1 x y)))
                     ((eq? c '>) (if (eq? x y) pt-bot (add-sub s1 y x)))
                     (else s1))))))))))

  ;; --- the lattice ----------------------------------------------------------

  (define (all-vars a b) (uniq (append (pt-vars a) (pt-vars b))))

  ;; a <= b, in the REDUCED order: b's constraint x < y is satisfied by a either
  ;; because a records it or because a's intervals prove it outright. Using the
  ;; componentwise order instead would make `pt-join` fail to be an upper bound
  ;; of its own arguments, since the join's third and fourth terms produce
  ;; exactly the constraints only the intervals justify.
  (define (pt-leq a b)
    (cond
     ((pt-bot? a) #t)
     ((pt-bot? b) #f)
     (else
      (let ((vs (all-vars a b)))
        (and (for-all (lambda (x) (iv-leq (pt-interval a x) (pt-interval b x))) vs)
             (for-all (lambda (x)
                        (for-all (lambda (y) (pt-lt? a x y)) (pt-subs b x)))
                      vs))))))

  ;; LOGOZZO'S JOIN, and the reason Pentagon is not just intervals bolted to a
  ;; constraint map.
  ;;
  ;;   s(x) = (s1(x) inter s2(x))
  ;;          union {y in s1(x) | b2 proves x < y}
  ;;          union {y in s2(x) | b1 proves x < y}
  ;;
  ;; The two asymmetric terms are the whole precision story. `if (i < n) ... else
  ;; ...` where one arm carries the constraint and the other arm's intervals
  ;; happen to settle it keeps the constraint through the merge. Without them,
  ;; every join with a constant-bounded branch throws the relation away and the
  ;; domain degrades to intervals at the first `if`.
  (define (pt-join a b)
    (cond
     ((pt-bot? a) b)
     ((pt-bot? b) a)
     (else
      (let ((vs (all-vars a b)))
        (make-pt
         (map (lambda (x) (cons x (iv-join (pt-interval a x) (pt-interval b x)))) vs)
         (map (lambda (x)
                (let ((sa (pt-subs a x)) (sb (pt-subs b x)))
                  (cons x
                        (append
                         (filter (lambda (y)
                                   (or (memq y sb) (ivs-prove-lt? b x y)))
                                 sa)
                         (filter (lambda (y)
                                   (and (not (memq y sa)) (ivs-prove-lt? a x y)))
                                 sb)))))
              vs))))))

  ;; Meet is the plain conjunction: both halves intersect what they constrain.
  ;;
  ;; It does NOT re-derive intervals from the merged constraints. A state with
  ;; x < y, x in [5,5] and y in [0,0] has an empty concretization and comes back
  ;; as a non-bottom state saying so. That is imprecise and it is sound, since
  ;; the result still contains every concrete state both arguments admitted, and
  ;; closing the gap means iterating the constraints against the intervals, which
  ;; is the closure D6 refused.
  (define (pt-meet a b)
    (cond
     ((pt-bot? a) pt-bot)
     ((pt-bot? b) pt-bot)
     (else
      (let ((vs (all-vars a b)))
        (make-pt
         (map (lambda (x) (cons x (iv-meet (pt-interval a x) (pt-interval b x)))) vs)
         (map (lambda (x) (cons x (append (pt-subs a x) (pt-subs b x)))) vs))))))

  ;; WIDENING. Argument order is (old new) and it is applied as
  ;; `next := old widen (old join f(old))`, exactly as iv-widen is. Reversing it
  ;; is the Figure 3 hazard, and it is masked by any monotone increasing test
  ;; sequence, so pentagon-test.ss pins the direction by hand.
  ;;
  ;; The interval half is interval.ss's operator unchanged, which is where the
  ;; jump to infinity lives.
  ;;
  ;; The Sub half keeps a constraint only if BOTH states hold it. Read that as
  ;; the stability test written the right way round: keep y in s_old(x) when y is
  ;; still in s_new(x). With the direction correct the per-constraint form
  ;; degenerates to intersection, which is why the collapse-to-empty acceleration
  ;; Figure 3 reaches for is not needed at all. It is not needed for termination
  ;; either: Sub over a program's fixed variable set has height at most |V|^2 and
  ;; every step of this operator removes constraints or keeps them, so the chain
  ;; is finite. That finiteness is a consequence of there being no closure, which
  ;; is D6 paying for itself a second time.
  (define (pt-widen old new)
    (cond
     ((pt-bot? old) new)
     ((pt-bot? new) old)
     (else
      (let ((vs (all-vars old new)))
        (make-pt
         (map (lambda (x)
                (cons x (iv-widen (pt-interval old x) (pt-interval new x))))
              vs)
         (map (lambda (x)
                (let ((sn (pt-subs new x)))
                  (cons x (filter (lambda (y) (memq y sn)) (pt-subs old x)))))
              vs))))))

  ;; --- printing -------------------------------------------------------------

  (define (pt->string s)
    (if (pt-bot? s)
        "_|_"
        (let ((parts
               (append
                (map (lambda (p)
                       (string-append (symbol->string (car p))
                                      " in " (iv->string (cdr p))))
                     (pentagon-ivs s))
                (apply append
                       (map (lambda (p)
                              (map (lambda (y)
                                     (string-append (symbol->string (car p))
                                                    " < " (symbol->string y)))
                                   (cdr p)))
                            (pentagon-subs s))))))
          (if (null? parts)
              "T"
              (fold-left (lambda (acc s)
                           (if (string=? acc "") s (string-append acc " ^ " s)))
                         ""
                         parts)))))
  )
