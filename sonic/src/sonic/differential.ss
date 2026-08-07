;;; The differential harness: compile twice, diff, and mean it.
;;;
;;; E6-DIFF (bead qaq.1). This exists BEFORE milestone 1 rather than after it,
;;; because the failure mode it catches is the one this project cannot survive:
;;; an unsound abstract domain does not crash, it deletes a check that was
;;; load-bearing and emits code that is quietly wrong. Every other bug in a
;;; compiler announces itself. This one does not.
;;;
;;; The shape is the oldest trick there is. Build the same program twice, once
;;; with the analysis switched off and every check emitted, once with the
;;; analysis believed and the checks it proved dead removed, then run both and
;;; compare. `proved` is DEFINED in sonic/src/sonic/lang.ss as semantically
;;; identical to `checked`, so the two builds must be indistinguishable from
;;; the outside. Any difference is the analysis lying.
;;;
;;; ## The comparison is bit-exact, and that is a decision, not a default
;;;
;;; The bead was filed saying "any divergence is an unsound analysis", and the
;;; RISC-V smoke gate showed that is false once vectorization lands, because
;;; reassociation legitimately moves the 16th significant digit on nbody. D24
;;; settled it and the settlement is what this file implements:
;;;
;;;   - FP contraction is a NAMED, LEXICALLY SCOPED PERMISSION, default OFF.
;;;   - Reassociation is FORBIDDEN outright.
;;;
;;; Under that policy the two builds must agree in every bit, so `bit-exact` is
;;; the correct comparison and the harness asserts exactly it. What it must not
;;; do is quietly weaken when someone turns contraction on. So the policy is a
;;; value the caller passes, `check-fp-policy!` refuses a bit-exact comparison
;;; once contraction appears in the emitted code, and `make-fp-policy` refuses
;;; to construct a policy permitting reassociation at all. Relaxing the
;;; comparison is possible and has to be written down; drifting into it is not.
;;;
;;; ## Why the analysis is re-driven here instead of called
;;;
;;; sonic/src/sonic/analyze.ss calls `iv-add`, `iv-sub` and `iv-mul` directly
;;; out of (sonic interval). An oracle that cannot be made to fail proves
;;; nothing, so this harness has to be able to run the same program against a
;;; DELIBERATELY BROKEN domain and show it catches the difference. That means
;;; the transfer functions have to be a parameter, and they are: `walk-domain`
;;; below is analyze.ss's walk with the domain lifted out, and
;;; `interval-domain` is the real one. sonic/test/differential-test.ss asserts
;;; that the two agree decision for decision on the default domain, so the copy
;;; cannot drift into a second, kinder analysis that always says yes.
;;;
;;; ## What this harness is, and what it is not
;;;
;;; It is a FALSIFIER. It reports unsoundness it observed on the inputs it was
;;; given; it does not certify soundness, and an elided site the inputs never
;;; drive out of range is a site it says nothing about. So the report carries
;;; `exercised`, and a run that elided nothing or exercised nothing is marked
;;; VACUOUS rather than passing. A green oracle that checked nothing is the
;;; failure this file exists to prevent, and it would be absurd to reproduce it
;;; here.

(library (sonic differential)
  (export ;; D24: the comparison policy
          make-fp-policy fp-policy? fp-policy-comparison
          fp-policy-contraction-permitted? fp-policy-reason
          bit-exact-policy check-fp-policy!
          program-grants-contraction?
          bit-identical?

          ;; the abstract domain, as a parameter so it can be broken on purpose
          make-domain domain? domain-name domain-with
          domain-top domain-const domain-range domain-join domain-widen
          domain-leq domain-add domain-sub domain-mul domain-refine
          domain-within?
          interval-domain

          ;; the two builds
          proved-elisions
          compile-core
          make-store store? store-name store-length store-ref store-poison!
          store-fill!

          ;; running them
          run-build
          outcome-ok? outcome-value outcome-trap

          differential-check
          diff-report? diff-report-runs diff-report-elided
          diff-report-exercised diff-report-divergences
          diff-report-sound? diff-report-vacuous? diff-report-summary

          ;; the emitted-code arm
          differential-object object-diff? object-diff-unoptimized
          object-diff-optimized object-diff-removed
          object-diff-only-the-elision?)
  (import (chezscheme)
          (sonic interval)
          (sonic twoaddr)
          (sonic select))

  ;;; =========================================================================
  ;;; 1. Bit-exact comparison, and the D24 guard around it
  ;;; =========================================================================

  ;; Two flonums are the same value only if they are the same 64 bits. `=` is
  ;; not that test: it says 0.0 and -0.0 are equal, and lang.ss records that
  ;; their difference is observable through a subsequent divide and that ref.c
  ;; depends on it. `eqv?` would do for flonums in Chez, but going through the
  ;; bit pattern says what is meant and extends to NaN payloads.
  (define (flonum-bits x)
    (let ((bv (make-bytevector 8 0)))
      (bytevector-ieee-double-set! bv 0 x (endianness little))
      (bytevector-u64-ref bv 0 (endianness little))))

  (define (bit-identical? a b)
    (cond
     ((and (flonum? a) (flonum? b)) (= (flonum-bits a) (flonum-bits b)))
     ((or (flonum? a) (flonum? b)) #f)
     ((and (pair? a) (pair? b))
      (and (bit-identical? (car a) (car b)) (bit-identical? (cdr a) (cdr b))))
     ((and (vector? a) (vector? b))
      (and (= (vector-length a) (vector-length b))
           (let loop ((i 0))
             (or (= i (vector-length a))
                 (and (bit-identical? (vector-ref a i) (vector-ref b i))
                      (loop (+ i 1)))))))
     ((and (number? a) (number? b)) (and (eq? (exact? a) (exact? b)) (= a b)))
     (else (equal? a b))))

  (define-record-type (fp-policy mk-fp-policy fp-policy?)
    (fields comparison contraction-permitted? reason))

  ;; `comparison` is `bit-exact` or `tolerance`. Reassociation is not a field
  ;; because D24 forbids it and a field would be a place to turn it on: it is
  ;; refused here, at construction, so enabling it requires editing the ledger
  ;; and this file together rather than passing an argument.
  (define make-fp-policy
    (case-lambda
      ((comparison contraction-permitted? reason)
       (make-fp-policy comparison contraction-permitted? reason #f))
      ((comparison contraction-permitted? reason reassociation-permitted?)
       (when reassociation-permitted?
         (error 'make-fp-policy
                (string-append
                 "D24 forbids reassociation. It is a global reordering whose result "
                 "depends on the vectorizer, and permitting it here would make the "
                 "eleven-way bit-exact cross-agreement in docs/METHOD.md check 2 "
                 "unavailable, which is the strongest correctness evidence this "
                 "project has")))
       (unless (memq comparison '(bit-exact tolerance))
         (error 'make-fp-policy "unknown comparison mode" comparison))
       (when (and (eq? comparison 'tolerance) (not (string? reason)))
         (error 'make-fp-policy
                "a relaxed comparison must say in writing why it is licensed"
                comparison))
       (mk-fp-policy comparison contraction-permitted? reason))))

  (define bit-exact-policy
    (make-fp-policy 'bit-exact #f
                    "D24: contraction default off, reassociation forbidden, so the two builds must agree in every bit"))

  ;; THE guard the bead asks for. `evidence` is whatever said contraction is
  ;; happening: fused mnemonics found in the emitted code, or a source-level
  ;; grant. A bit-exact comparison in the presence of contraction would report
  ;; a divergence that is not an unsoundness, so we refuse to run rather than
  ;; report a lie, and we refuse loudly enough that turning contraction on
  ;; cannot be done without also deciding what the comparison becomes.
  (define (check-fp-policy! policy evidence who)
    (unless (fp-policy? policy) (error who "not an fp policy" policy))
    (when (and (pair? evidence)
               (not (fp-policy-contraction-permitted? policy)))
      (error who
             (string-append
              "FP contraction is present in this build and the comparison is still "
              "bit-exact. D24 makes contraction a named, lexically scoped permission "
              "that is OFF by default; something turned it on without deciding what "
              "the differential comparison becomes. Either take the contraction back "
              "out, or construct an fp-policy that permits it and states in writing "
              "why the relaxed comparison is licensed")
             evidence))
    (when (and (pair? evidence)
               (eq? (fp-policy-comparison policy) 'bit-exact))
      (error who
             (string-append
              "this policy permits contraction but still compares bit-exactly, which "
              "cannot hold: a fused multiply-add keeps one rounding where the "
              "unfused pair keeps two")
             evidence))
    policy)

  ;; Source-level evidence, over an unparsed Lcore/Lanf/Lrepr datum. Two
  ;; spellings grant the permission: the lexical `(policy ((fp-contract #t)) ...)`
  ;; form, and a per-call control `[fp-contract unchecked]`, which is how the
  ;; check vocabulary spells "the programmer switched this on" for a name that
  ;; is a permission rather than a check.
  (define (program-grants-contraction? datum)
    (let walk ((x datum))
      (cond
       ((not (pair? x)) #f)
       ((and (eq? (car x) 'policy) (pair? (cdr x)) (list? (cadr x))
             (exists (lambda (b) (and (pair? b) (eq? (car b) 'fp-contract) (cadr b)))
                     (cadr x)))
        #t)
       ((and (eq? (car x) 'primcall) (pair? (cddr x)) (list? (caddr x))
             (exists (lambda (b) (and (pair? b) (eq? (car b) 'fp-contract)
                                      (memq (cadr b) '(unchecked proved))))
                     (caddr x)))
        #t)
       (else (or (walk (car x)) (walk (cdr x)))))))

  ;;; =========================================================================
  ;;; 2. The abstract domain, lifted out so it can be broken on purpose
  ;;; =========================================================================

  (define-record-type (domain make-domain domain?)
    (fields name top const range join meet leq widen add sub mul refine within?))

  (define interval-domain
    (make-domain 'interval
                 iv-top iv-const iv-range iv-join iv-meet iv-leq iv-widen
                 iv-add iv-sub iv-mul iv-refine iv-within?))

  ;; Replace one operation and keep the rest. This is the fault-injection point
  ;; and the reason the domain is a record rather than a set of imports.
  (define (domain-with d field proc)
    (define (pick k v) (if (eq? field k) proc v))
    (make-domain (string->symbol (string-append (symbol->string (domain-name d))
                                                "/broken-" (symbol->string field)))
                 (pick 'top (domain-top d))
                 (pick 'const (domain-const d))
                 (pick 'range (domain-range d))
                 (pick 'join (domain-join d))
                 (pick 'meet (domain-meet d))
                 (pick 'leq (domain-leq d))
                 (pick 'widen (domain-widen d))
                 (pick 'add (domain-add d))
                 (pick 'sub (domain-sub d))
                 (pick 'mul (domain-mul d))
                 (pick 'refine (domain-refine d))
                 (pick 'within? (domain-within? d))))

  ;;; =========================================================================
  ;;; 3. The analysis, re-driven over a domain parameter
  ;;; =========================================================================
  ;;
  ;; This is sonic/src/sonic/analyze.ss's `walk` with (sonic interval) lifted
  ;; into an argument and nothing else changed. It is checked against the
  ;; original in the test rather than trusted.
  ;;
  ;; The core language is analyze.ss's:
  ;;   e ::= (const n) | (var x) | (let x e body) | (if (cmp x y) e1 e2)
  ;;       | (prim op x y) | (vref v x) | (loop x lo hi body) | (begin e ...)

  (define (env-ref* d env x)
    (let ((p (assq x env))) (if p (cdr p) (domain-top d))))

  (define (env-set* env x v) (cons (cons x v) env))

  (define (env-vars env) (map car env))

  (define (env-join* d a b)
    (let loop ((xs (append (env-vars a) (env-vars b))) (acc '()))
      (cond ((null? xs) acc)
            ((assq (car xs) acc) (loop (cdr xs) acc))
            (else (loop (cdr xs)
                        (env-set* acc (car xs)
                                  ((domain-join d) (env-ref* d a (car xs))
                                                   (env-ref* d b (car xs)))))))))

  (define (env-widen* d old new)
    (let loop ((xs (append (env-vars old) (env-vars new))) (acc '()))
      (cond ((null? xs) acc)
            ((assq (car xs) acc) (loop (cdr xs) acc))
            (else (loop (cdr xs)
                        (env-set* acc (car xs)
                                  ((domain-widen d) (env-ref* d old (car xs))
                                                    (env-ref* d new (car xs)))))))))

  (define (env-equal?* d a b)
    (let ((xs (append (env-vars a) (env-vars b))))
      (for-all (lambda (x)
                 (let ((u (env-ref* d a x)) (v (env-ref* d b x)))
                   (and ((domain-leq d) u v) ((domain-leq d) v u))))
               xs)))

  (define (refine* d env cmp x y true?)
    (let-values (((vx vy) ((domain-refine d) cmp (not true?)
                           (env-ref* d env x) (env-ref* d env y))))
      (if (eq? x y)
          (env-set* env x ((domain-meet d) vx vy))
          (env-set* (env-set* env x vx) y vy))))

  (define (apply-prim* d op a b)
    (cond ((eq? op '+) ((domain-add d) a b))
          ((eq? op '-) ((domain-sub d) a b))
          ((eq? op '*) ((domain-mul d) a b))
          (else (domain-top d))))

  ;; A decision here carries the SITE and whether the check may go. The site is
  ;; `(vref v x)`, exactly as analyze.ss spells it, so the two can be compared.
  (define-record-type (elision make-elision elision?)
    (fields site eliminable?))

  (define (walk-domain d e env decs lengths)
    (cond
     ((eq? (car e) 'const) (values ((domain-const d) (cadr e)) env decs))
     ((eq? (car e) 'var)   (values (env-ref* d env (cadr e)) env decs))

     ((eq? (car e) 'prim)
      (values (apply-prim* d (cadr e)
                           (env-ref* d env (caddr e))
                           (env-ref* d env (cadddr e)))
              env decs))

     ((eq? (car e) 'let)
      (let-values (((v env1 decs1) (walk-domain d (caddr e) env decs lengths)))
        (walk-domain d (cadddr e) (env-set* env1 (cadr e) v) decs1 lengths)))

     ((eq? (car e) 'begin)
      (let loop ((es (cdr e)) (env env) (decs decs) (last (domain-top d)))
        (if (null? es)
            (values last env decs)
            (let-values (((v env1 decs1) (walk-domain d (car es) env decs lengths)))
              (loop (cdr es) env1 decs1 v)))))

     ((eq? (car e) 'if)
      (let* ((c (cadr e)) (cmp (car c)) (x (cadr c)) (y (caddr c)))
        (let-values (((v1 e1 d1) (walk-domain d (caddr e) (refine* d env cmp x y #t) decs lengths)))
          (let-values (((v2 e2 d2) (walk-domain d (cadddr e) (refine* d env cmp x y #f) d1 lengths)))
            (values ((domain-join d) v1 v2) (env-join* d e1 e2) d2)))))

     ((eq? (car e) 'vref)
      (let* ((v (cadr e)) (x (caddr e))
             (idx (env-ref* d env x))
             (len (let ((p (assq v lengths)))
                    (if p ((domain-const d) (cdr p)) (domain-top d)))))
        (values (domain-top d) env
                (cons (make-elision (list 'vref v x) ((domain-within? d) idx len))
                      decs))))

     ((eq? (car e) 'loop)
      (let* ((x (cadr e)) (lo (caddr e)) (hi (cadddr e)) (body (car (cddddr e)))
             (ivx ((domain-range d) lo (- hi 1))))
        (let fix ((cur (env-set* env x ivx)) (n 0))
          (if (> n 50)
              (error 'walk-domain "fixpoint did not converge")
              (let-values (((v env1 _) (walk-domain d body cur '() lengths)))
                (let ((wid (env-set* (env-widen* d cur (env-join* d cur env1)) x ivx)))
                  (if (env-equal?* d wid cur)
                      (let-values (((v2 env2 decs2) (walk-domain d body cur decs lengths)))
                        (values (domain-top d) env decs2))
                      (fix wid (+ n 1)))))))))

     (else (error 'walk-domain "unknown form" e))))

  ;; -> the sites whose bounds check the domain claims is dead.
  ;;
  ;; A site is `(vref v x)`, so two references to the same vector through the
  ;; same index variable are one site. That is a real constraint on programs
  ;; given to this harness and it is enforced rather than assumed, because
  ;; silently merging two sites would let a sound elision at one of them cover
  ;; an unsound one at the other.
  (define proved-elisions
    (case-lambda
      ((prog lengths) (proved-elisions prog lengths interval-domain))
      ((prog lengths d)
       (check-sites-distinct! prog)
       (let-values (((v env decs) (walk-domain d prog '() '() lengths)))
         (let ((all (reverse decs)))
           (map elision-site (filter elision-eliminable? all)))))))

  (define (all-sites prog)
    (let walk ((e prog) (acc '()))
      (cond
       ((not (pair? e)) acc)
       ((eq? (car e) 'vref) (cons (list 'vref (cadr e) (caddr e)) acc))
       ((eq? (car e) 'let) (walk (caddr e) (walk (cadddr e) acc)))
       ((eq? (car e) 'if) (walk (caddr e) (walk (cadddr e) acc)))
       ((eq? (car e) 'loop) (walk (car (cddddr e)) acc))
       ((eq? (car e) 'begin)
        (let loop ((es (cdr e)) (acc acc))
          (if (null? es) acc (loop (cdr es) (walk (car es) acc)))))
       (else acc))))

  (define (check-sites-distinct! prog)
    (let loop ((ss (all-sites prog)) (seen '()))
      (cond ((null? ss) #t)
            ((member (car ss) seen)
             (error 'differential
                    (string-append
                     "two vref sites in this program share a (vector, index variable) "
                     "pair, so the analysis cannot tell their decisions apart and a "
                     "sound elision at one would cover an unsound one at the other")
                    (car ss)))
            (else (loop (cdr ss) (cons (car ss) seen))))))

  ;;; =========================================================================
  ;;; 4. The store, with a poison zone on both sides
  ;;; =========================================================================
  ;;
  ;; An elided check that should not have been elided has to be OBSERVABLE, and
  ;; a crash is not observable, it is a different kind of failure that hides the
  ;; one we are looking for. So the backing storage extends `guard` elements
  ;; either side of the declared length and those elements hold values that
  ;; cannot occur in range. An unsound elision then reads poison and the trace
  ;; differs, which is exactly the signal a real out-of-bounds read gives in a
  ;; language with no checks: not a fault, a wrong answer.

  (define-record-type (store mk-store store?)
    (fields name length guard data))

  (define (make-store name len guard)
    (mk-store name len guard (make-vector (+ len (* 2 guard)) 0)))

  (define (store-fill! s proc)
    (let loop ((i 0))
      (when (< i (store-length s))
        (vector-set! (store-data s) (+ i (store-guard s)) (proc i))
        (loop (+ i 1)))))

  (define (store-poison! s value)
    (let ((g (store-guard s)) (n (store-length s)))
      (let loop ((i 0))
        (when (< i g)
          (vector-set! (store-data s) i value)
          (vector-set! (store-data s) (+ g n i) value)
          (loop (+ i 1))))))

  (define (store-ref s i)
    (let ((slot (+ i (store-guard s))))
      (if (and (>= slot 0) (< slot (vector-length (store-data s))))
          (vector-ref (store-data s) slot)
          ;; Past the poison zone the harness genuinely cannot model the read,
          ;; and guessing would be inventing a result. Widen the guard instead.
          (error 'store-ref
                 "an unchecked read went past the poison zone; widen the guard so the divergence stays observable rather than becoming a fault"
                 (store-name s) i (store-guard s)))))

  ;;; =========================================================================
  ;;; 5. Compiling the program, twice
  ;;; =========================================================================
  ;;
  ;; A closure compiler, not an interpreter with a flag. The elision set is
  ;; consumed at BUILD time and baked into the residual procedure, so the two
  ;; builds are two different programs in the same sense the two object files
  ;; would be, and nothing at run time can consult the policy and accidentally
  ;; agree.

  (define-record-type (trap make-trap trap?)
    (fields check site index))

  (define (outcome-ok? o) (not (trap? o)))
  (define (outcome-value o) (if (trap? o) #f o))
  (define (outcome-trap o) (and (trap? o) (list (trap-check o) (trap-site o) (trap-index o))))

  (define (compare-op cmp a b)
    (case cmp
      ((< fx< fl<)   (< a b))
      ((<= fx<= fl<=) (<= a b))
      ((> fx> fl>)   (> a b))
      ((>= fx>= fl>=) (>= a b))
      ((= fx= fl=)   (= a b))
      (else (error 'compile-core "unknown comparison" cmp))))

  ;; A compiled expression is `(lambda (env trace-box) -> value)`, where env is
  ;; an alist of concrete values and the box accumulates every value read
  ;; through a vref, in order. A trap escapes through `raise`.
  ;;
  ;; `elided` is the set of sites whose bounds check this build omits.
  (define (compile-core prog lengths elided)
    (define (elided? site) (and (member site elided) #t))
    (define (cv e)
      (cond
       ((eq? (car e) 'const) (let ((n (cadr e))) (lambda (env tr) n)))
       ((eq? (car e) 'var)
        (let ((x (cadr e)))
          (lambda (env tr)
            (let ((p (assq x env)))
              (unless p (error 'compile-core "unbound variable at run time" x))
              (cdr p)))))
       ((eq? (car e) 'prim)
        (let ((op (cadr e)) (x (caddr e)) (y (cadddr e)))
          (lambda (env tr)
            (let ((a (cdr (assq x env))) (b (cdr (assq y env))))
              (case op ((+) (+ a b)) ((-) (- a b)) ((*) (* a b))
                (else (error 'compile-core "unknown primitive" op)))))))
       ((eq? (car e) 'let)
        (let ((x (cadr e)) (ce (cv (caddr e))) (cb (cv (cadddr e))))
          (lambda (env tr) (cb (cons (cons x (ce env tr)) env) tr))))
       ((eq? (car e) 'begin)
        (let ((cs (map cv (cdr e))))
          (lambda (env tr)
            (let loop ((cs cs) (last '()))
              (if (null? cs) last (loop (cdr cs) ((car cs) env tr)))))))
       ((eq? (car e) 'if)
        (let* ((c (cadr e)) (cmp (car c)) (x (cadr c)) (y (caddr c))
               (ct (cv (caddr e))) (cf (cv (cadddr e))))
          (lambda (env tr)
            (if (compare-op cmp (cdr (assq x env)) (cdr (assq y env)))
                (ct env tr) (cf env tr)))))
       ((eq? (car e) 'vref)
        (let* ((v (cadr e)) (x (caddr e))
               (site (list 'vref v x))
               (len (let ((p (assq v lengths)))
                      (unless p (error 'compile-core "vector of unknown length" v))
                      (cdr p)))
               (skip (elided? site)))
          ;; The whole point, and the two branches are chosen HERE, once.
          (if skip
              (lambda (env tr)
                (let* ((i (cdr (assq x env)))
                       (s (cdr (assq v env)))
                       (val (store-ref s i)))
                  (set-box! tr (cons val (unbox tr)))
                  val))
              (lambda (env tr)
                (let ((i (cdr (assq x env))) (s (cdr (assq v env))))
                  (when (or (< i 0) (>= i len))
                    (raise (make-trap 'bounds-check site i)))
                  (let ((val (store-ref s i)))
                    (set-box! tr (cons val (unbox tr)))
                    val))))))
       ((eq? (car e) 'loop)
        (let ((x (cadr e)) (lo (caddr e)) (hi (cadddr e)) (cb (cv (car (cddddr e)))))
          (lambda (env tr)
            (let loop ((i lo) (last '()))
              (if (>= i hi) last (loop (+ i 1) (cb (cons (cons x i) env) tr)))))))
       (else (error 'compile-core "unknown form" e))))
    (cv prog))

  ;; -> (values outcome trace). The trace is in program order.
  (define (run-build compiled env)
    (let ((tr (box '())))
      (let ((o (guard (e ((trap? e) e))
                 (compiled env tr))))
        (values o (reverse (unbox tr))))))

  ;;; =========================================================================
  ;;; 6. The harness
  ;;; =========================================================================

  (define-record-type (diff-report make-diff-report diff-report?)
    (fields runs elided exercised divergences))

  (define (diff-report-sound? r) (null? (diff-report-divergences r)))

  ;; A run that elided nothing compared a build against itself. It is not a
  ;; pass, and saying so is the difference between an oracle and a decoration.
  ;;
  ;; `exercised` is a separate number and deliberately NOT folded in here. A
  ;; sound program legitimately never drives an elided site out of range, so
  ;; zero there is the expected result rather than a defect; it is reported so
  ;; that a run claiming to have validated an elision can say whether the
  ;; missing check would ever have fired.
  (define (diff-report-vacuous? r) (null? (diff-report-elided r)))

  (define (diff-report-summary r)
    (string-append
     (number->string (diff-report-runs r)) " runs, "
     (number->string (length (diff-report-elided r))) " sites elided, "
     (number->string (diff-report-exercised r)) " out-of-range accesses reached an elided site, "
     (number->string (length (diff-report-divergences r))) " divergences"))

  ;; `envs` is a list of initial environments: alists binding the program's free
  ;; variables, with each vector name bound to a `store`.
  ;;
  ;; `exercised` counts the accesses that actually left the declared range at a
  ;; site the optimized build stopped checking. That is the number that says
  ;; whether this run had the power to catch anything, and it is why the report
  ;; carries it rather than only a verdict.
  (define differential-check
    (case-lambda
      ((prog lengths envs) (differential-check prog lengths envs interval-domain bit-exact-policy))
      ((prog lengths envs d) (differential-check prog lengths envs d bit-exact-policy))
      ((prog lengths envs d policy)
       (check-fp-policy! policy '() 'differential-check)
       (let* ((elided (proved-elisions prog lengths d))
              (unopt (compile-core prog lengths '()))
              (opt   (compile-core prog lengths elided))
              ;; The probe is the fully checked build again, used to ask
              ;; whether an elided site actually went out of range on this
              ;; input, without asking the optimized build anything.
              (probe unopt))
         (let loop ((es envs) (n 0) (exercised 0) (divs '()))
           (if (null? es)
               (make-diff-report n elided exercised (reverse divs))
               (let ((env (car es)))
                 (let-values (((o1 t1) (run-build unopt env))
                              ((o2 t2) (run-build opt env)))
                   (let* ((hit (out-of-range-hits probe elided env))
                          (same (and (bit-identical? (outcome-trap o1) (outcome-trap o2))
                                     (bit-identical? (outcome-value o1) (outcome-value o2))
                                     (bit-identical? t1 t2))))
                     (loop (cdr es) (+ n 1) (+ exercised hit)
                           (if same
                               divs
                               (cons (list 'env env
                                           'unoptimized (list (outcome-trap o1) (outcome-value o1) t1)
                                           'optimized   (list (outcome-trap o2) (outcome-value o2) t2))
                                     divs))))))))))))

  ;; How many accesses at an ELIDED site actually left the declared range on
  ;; this input. Run against the fully checked build: it traps at the first one,
  ;; so this is "did the optimized build's missing check matter", answered
  ;; without the optimized build's help.
  (define (out-of-range-hits probe elided env)
    (let-values (((o t) (run-build probe env)))
      (if (and (trap? o) (member (trap-site o) elided)) 1 0)))

  ;;; =========================================================================
  ;;; 7. The emitted-code arm
  ;;; =========================================================================
  ;;
  ;; The interpretive arm above answers "do the two builds compute the same
  ;; thing". This one answers the other half: "do the two builds DIFFER ONLY BY
  ;; THE ELISION". A pass that removes a check and also, say, reorders the
  ;; arithmetic around it would pass the first and fail this.
  ;;
  ;; The comparison is on selected mnemonics rather than bytes, deliberately.
  ;; Removing an instruction shortens live ranges and linear scan may hand out
  ;; different registers as a result, which is legitimate and would make a byte
  ;; comparison fail for a reason that is not a bug. The mnemonic stream is
  ;; allocation-independent and still catches a reordering.

  (define-record-type (object-diff make-object-diff object-diff?)
    (fields unoptimized optimized removed))

  (define (block-instrs prog-datum)
    (cadr (cadr (car (cadr prog-datum)))))

  (define (with-instrs prog-datum instrs)
    (let* ((lb (car (cadr prog-datum)))
           (blk (cadr lb)))
      (list 'program
            (list (list (car lb) (list 'block instrs (caddr blk))))
            (caddr prog-datum))))

  (define (selected-mnemonics selector arch prog-datum)
    (let* ((fixed (twoaddr arch prog-datum))
           (sel (cadr (car (cadddr (select-program selector fixed))))))
      (map car sel)))

  ;; `check-pred` picks the instructions the optimized build removes. Everything
  ;; else about the two programs is identical by construction, which is the
  ;; point: the diff that comes back is attributable.
  (define (differential-object arch selector prog-datum check-pred)
    (let* ((all (block-instrs prog-datum))
           (checks (filter check-pred all))
           (kept (filter (lambda (i) (not (check-pred i))) all))
           (unopt-mn (selected-mnemonics selector arch (with-instrs prog-datum all)))
           (opt-mn (selected-mnemonics selector arch (with-instrs prog-datum kept)))
           ;; What the removed checks select to, on their own, through the same
           ;; rule table. Asking the target rather than assuming keeps this
           ;; honest when a selector changes its check sequence.
           (removed (apply append
                           (map (lambda (i) (map car (select-instr selector i))) checks))))
      (when (null? checks)
        (error 'differential-object
               "no instruction matched the elision predicate, so this comparison would prove nothing"
               (map car all)))
      (make-object-diff unopt-mn opt-mn removed)))

  ;; Deleting the removed check sequences from the unoptimized stream must give
  ;; back the optimized stream exactly. Subsequence deletion rather than a set
  ;; difference, so an instruction that merely happens to share a mnemonic with
  ;; a check is not silently absorbed.
  (define (object-diff-only-the-elision? od)
    (let ((u (object-diff-unoptimized od))
          (o (object-diff-optimized od))
          (r (object-diff-removed od)))
      (and (not (equal? u o))
           (equal? (delete-subsequence u r) o))))

  (define (delete-subsequence xs sub)
    (let loop ((xs xs) (sub sub) (acc '()))
      (cond ((null? sub) (append (reverse acc) xs))
            ((null? xs) (reverse acc))
            ((eq? (car xs) (car sub)) (loop (cdr xs) (cdr sub) acc))
            (else (loop (cdr xs) sub (cons (car xs) acc))))))
  )
