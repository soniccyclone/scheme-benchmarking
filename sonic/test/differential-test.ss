;;; E6-DIFF (bead qaq.1).
;;;
;;; The acceptance is two sentences and the second one is the hard one:
;;; "harness runs both builds and diffs; DELIBERATELY BREAKING A TRANSFER
;;; FUNCTION IS CAUGHT". An oracle that cannot fail proves nothing, so most of
;;; this file is spent proving that this one can.
;;;
;;; The corruption is not a mock and not a flag. `(sonic differential)` lifts
;;; the interval domain into a record so a caller can replace one transfer
;;; function with a broken one, and the two bugs used below are both real ones:
;;;
;;;   iv-add  computing its upper bound from the SECOND operand's LOWER bound,
;;;           which is the copy-paste every interval implementation makes once;
;;;   iv-mul  taking the al*bl and al*bh corners instead of all four, which is
;;;           the bug sonic/src/sonic/interval.ss names in a comment.
;;;
;;; Both under-approximate. That is what makes them dangerous and what makes
;;; them the right test: an over-approximating bug loses optimizations and an
;;; under-approximating one deletes a check that was load-bearing, and only the
;;; second is a wrong-code bug.
;;;
;;; The program is nbody's access, `b[i*7 + k]`, at two lengths. At 35 the
;;; access is genuinely in range and the real domain proves it. At 30 it is
;;; genuinely out of range, the real domain refuses, and both broken domains
;;; prove it anyway. That second case is the one the harness has to catch.

(import (chezscheme)
        (sonic interval)
        (sonic analyze)
        (sonic regs)
        (sonic select)
        (sonic target-x86-64)
        (sonic target-rv64)
        (sonic differential)
        (sonic disasm))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define (raises? thunk) (guard (e (#t #t)) (thunk) #f))

(define tmp
  (let ((d (string-append (or (getenv "TMPDIR") "/tmp") "/sonic-differential-test")))
    (system (string-append "mkdir -p " d))
    d))
(define (path . parts) (apply string-append tmp "/" parts))
(define (have? cmd) (zero? (system (string-append cmd " >/dev/null 2>&1"))))
(define (shell cmd) (zero? (system (string-append cmd " > " (path "log") " 2>&1"))))

;;; ==========================================================================
;;; 1. Bit-exact means bit-exact
;;; ==========================================================================
;;
;; D24 keeps contraction off and forbids reassociation, so the two builds must
;; agree in every bit and `=` is not that test. lang.ss records that 0.0 and
;; -0.0 differ observably through a subsequent divide, and ref.c depends on it.

(ck! "0.0 and -0.0 are equal under = and are NOT bit-identical"
     (and (= 0.0 -0.0) (not (bit-identical? 0.0 -0.0))))
(ck! "a flonum and the exact integer with the same value are not identical"
     (not (bit-identical? 1 1.0)))
(ck! "NaN is bit-identical to itself, where = says it is not even equal"
     (and (not (= +nan.0 +nan.0)) (bit-identical? +nan.0 +nan.0)))
(ck! "lists compare elementwise, which is what a trace comparison needs"
     (and (bit-identical? '(1.5 2 (3.0)) '(1.5 2 (3.0)))
          (not (bit-identical? '(1.5 2) '(1.5 2.0)))))

;;; ==========================================================================
;;; 2. D24: the comparison policy cannot drift
;;; ==========================================================================

(ck! "the default policy is bit-exact with contraction off"
     (and (eq? (fp-policy-comparison bit-exact-policy) 'bit-exact)
          (not (fp-policy-contraction-permitted? bit-exact-policy))))

(ck! "a policy permitting REASSOCIATION cannot be constructed at all: D24 forbids it"
     (raises? (lambda () (make-fp-policy 'tolerance #t "because I said so" #t))))

(ck! "a relaxed comparison must state in writing why it is licensed"
     (raises? (lambda () (make-fp-policy 'tolerance #t 'no-reason))))

;; The guard the bead asks for, in both directions.
(ck! "bit-exact plus evidence of contraction FAILS LOUDLY rather than reporting a divergence"
     (raises? (lambda () (check-fp-policy! bit-exact-policy '(vfmadd231pd) 'test))))
(ck! "and so does a policy that permits contraction while still comparing bit-exactly"
     (raises? (lambda ()
                (check-fp-policy! (make-fp-policy 'bit-exact #t "incoherent") '(fmadd.d) 'test))))
(ck! "a deliberately relaxed policy accepts the same evidence"
     (fp-policy? (check-fp-policy!
                  (make-fp-policy 'tolerance #t
                                  "stage 10 measured the contraction delta on nbody; see D24")
                  '(vfmadd231pd) 'test)))
(ck! "and no evidence passes under the default policy, so the guard is not just always-on"
     (fp-policy? (check-fp-policy! bit-exact-policy '() 'test)))

;; Source-level evidence, with its own control: the same program without the
;; permission must come back #f, or the recognizer is a constant.
(ck! "a lexical (policy ((fp-contract #t)) ...) is recognized as granting contraction"
     (program-grants-contraction?
      '(top ((f (lambda (a b) (policy ((fp-contract #t))
                                (primcall fl+ ((fp-contract checked)) a b)))))
            () (quote 0))))
(ck! "a per-call [fp-contract unchecked] is too"
     (program-grants-contraction?
      '(top ((f (lambda (a b) (primcall fl+ ((fp-contract unchecked)) a b)))) () (quote 0))))
(ck! "and the same program with the permission left at its default is not"
     (not (program-grants-contraction?
           '(top ((f (lambda (a b) (policy ((fp-contract #f))
                                     (primcall fl+ ((fp-contract checked)) a b)))))
                 () (quote 0)))))

;;; ==========================================================================
;;; 3. The re-driven analysis is the same analysis
;;; ==========================================================================
;;
;; The domain has to be a parameter so it can be broken on purpose, which means
;; differential.ss carries a second copy of analyze.ss's walk. A second copy is
;; a place for a second, kinder analysis to grow, so it is pinned to the first.

(define (nbody-access ibound kbound)
  `(let seven (const 7)
     (loop i 0 ,ibound
       (loop k 0 ,kbound
         (let off (prim * i seven)
           (let idx (prim + off k)
             (vref b idx)))))))

(define in-range-prog (nbody-access 5 7))       ; max index 4*7+6 = 34
(define out-of-range-prog (nbody-access 5 7))   ; same program, shorter vector

(define len-35 '((b . 35)))
(define len-30 '((b . 30)))

(define (analyze-sites prog lengths)
  (map (lambda (d) (cons (decision-site d) (decision-eliminable? d)))
       (analyze-program prog lengths)))

(ck! "the harness's domain-parametric walk agrees with analyze.ss where the check IS provable"
     (equal? (analyze-sites in-range-prog len-35)
             '(((vref b idx) . #t))))
(ck! "and where it is not"
     (equal? (analyze-sites out-of-range-prog len-30)
             '(((vref b idx) . #f))))
(ck! "proved-elisions on the real domain returns exactly the sites analyze.ss called eliminable"
     (and (equal? (proved-elisions in-range-prog len-35) '((vref b idx)))
          (null? (proved-elisions out-of-range-prog len-30))))

(ck! "two vref sites sharing a (vector, index variable) pair are refused, not merged"
     (raises? (lambda ()
                (proved-elisions '(begin (vref b i) (vref b i)) '((b . 4))))))

;;; ==========================================================================
;;; 4. The two builds, on a program whose elision is real and sound
;;; ==========================================================================

;; A store whose declared length is `len` and whose backing storage runs
;; `guard` elements either side, poisoned. An unsound elision then reads poison
;; and gives a WRONG ANSWER, which is what an unchecked out-of-bounds read
;; actually does; making it fault instead would hide the divergence behind a
;; different kind of failure.
(define (fresh-store len)
  (let ((s (make-store 'b len 8)))
    (store-fill! s (lambda (i) (* 1.5 i)))
    (store-poison! s -999.0)
    s))

(define (env-for len) (list (cons 'b (fresh-store len))))

(define sound-report
  (differential-check in-range-prog len-35 (list (env-for 35))))

(ck! "the sound program elides its bounds check, so the run is not vacuous"
     (and (not (diff-report-vacuous? sound-report))
          (equal? (diff-report-elided sound-report) '((vref b idx)))))
(ck! "and the checked and elided builds agree bit for bit"
     (diff-report-sound? sound-report))
(ck! "with nothing driven out of range, which is what SOUND means here"
     (zero? (diff-report-exercised sound-report)))

;; The same program at a length that makes the access genuinely illegal. The
;; real domain refuses to prove it, so nothing is elided and the two builds are
;; the same build. The harness must report that as vacuous rather than as a
;; pass: it checked nothing.
(define honest-report
  (differential-check out-of-range-prog len-30 (list (env-for 30))))

(ck! "where the real domain cannot prove the check, nothing is elided"
     (null? (diff-report-elided honest-report)))
(ck! "and the harness calls that run VACUOUS rather than green"
     (diff-report-vacuous? honest-report))

;;; ==========================================================================
;;; 5. THE POINT: a deliberately broken transfer function is caught
;;; ==========================================================================
;;
;; Both corruptions fall back to the real function on an infinite bound, so what
;; is being injected is a wrong ANSWER on finite intervals and not a crash.

(define (finite? x) (and (number? x) (exact? x)))

;; The copy-paste: the upper bound built from the second operand's LOWER bound.
;; [0,28] + [0,6] comes back [0,28] instead of [0,34].
(define (broken-add a b)
  (if (and (finite? (interval-lo a)) (finite? (interval-hi a))
           (finite? (interval-lo b)) (finite? (interval-hi b)))
      (make-interval (+ (interval-lo a) (interval-lo b))
                     (+ (interval-hi a) (interval-lo b)))
      (iv-add a b)))

;; The classic interval-multiply bug interval.ss names in a comment: two corners
;; instead of four. [0,4] * [7,7] comes back [0,0] instead of [0,28].
(define (broken-mul a b)
  (if (and (finite? (interval-lo a)) (finite? (interval-hi a))
           (finite? (interval-lo b)) (finite? (interval-hi b)))
      (make-interval (* (interval-lo a) (interval-lo b))
                     (* (interval-lo a) (interval-hi b)))
      (iv-mul a b)))

(define add-broken (domain-with interval-domain 'add broken-add))
(define mul-broken (domain-with interval-domain 'mul broken-mul))

(ck! "the corruption is real: broken iv-add loses the second operand's upper bound"
     (and (equal? (list (interval-lo (iv-add (iv-range 0 28) (iv-range 0 6)))
                        (interval-hi (iv-add (iv-range 0 28) (iv-range 0 6))))
                  '(0 34))
          (equal? (list (interval-lo (broken-add (iv-range 0 28) (iv-range 0 6)))
                        (interval-hi (broken-add (iv-range 0 28) (iv-range 0 6))))
                  '(0 28))))
(ck! "and broken iv-mul takes two corners where four are needed"
     (equal? (list (interval-lo (broken-mul (iv-range 0 4) (iv-const 7)))
                   (interval-hi (broken-mul (iv-range 0 4) (iv-const 7))))
             '(0 0)))

;; Step one of the chain: the wrong transfer function produces a wrong decision.
(ck! "the real domain REFUSES to prove the out-of-range access"
     (null? (proved-elisions out-of-range-prog len-30 interval-domain)))
(ck! "the add-broken domain proves it anyway, which is the wrong-code bug"
     (equal? (proved-elisions out-of-range-prog len-30 add-broken) '((vref b idx))))
(ck! "and so does the mul-broken domain, by a different route"
     (equal? (proved-elisions out-of-range-prog len-30 mul-broken) '((vref b idx))))

;; Step two: the harness observes the difference between the two builds.
(define add-broken-report
  (differential-check out-of-range-prog len-30 (list (env-for 30)) add-broken))
(define mul-broken-report
  (differential-check out-of-range-prog len-30 (list (env-for 30)) mul-broken))

(ck! "the harness CATCHES the add-broken domain"
     (not (diff-report-sound? add-broken-report)))
(ck! "the harness CATCHES the mul-broken domain"
     (not (diff-report-sound? mul-broken-report)))
(ck! "and both runs had the power to catch it: an elided site really went out of range"
     (and (positive? (diff-report-exercised add-broken-report))
          (positive? (diff-report-exercised mul-broken-report))))
(ck! "the divergence is what it should be: the checked build traps where the elided build reads poison"
     (let* ((div (car (diff-report-divergences add-broken-report)))
            (unopt (cadr (memq 'unoptimized div)))
            (opt (cadr (memq 'optimized div))))
       (and (car unopt)                          ; the checked build trapped
            (equal? (car (car unopt)) 'bounds-check)
            (not (car opt))                      ; the elided build ran to the end
            (memv -999.0 (caddr opt)))))         ; and read poison

;; And the same broken domain on the program where the access IS in range
;; diverges nowhere, because the elision it makes there happens to be correct.
;; Without this the previous checks would be consistent with "the harness always
;; says unsound once you hand it a second domain".
(ck! "a broken domain on a program it cannot get wrong reports no divergence"
     (diff-report-sound?
      (differential-check in-range-prog len-35 (list (env-for 35)) add-broken)))

(display "  ---  ") (display (diff-report-summary add-broken-report)) (newline)

;;; ==========================================================================
;;; 6. The emitted-code arm: the two builds differ ONLY by the elision
;;; ==========================================================================
;;
;; The interpretive arm above says the two builds compute the same thing. This
;; says they are the same code apart from the check, which is the property a
;; pass that removes a check AND quietly reorders the arithmetic would break.

;; The check is spelled as Lmach's `chk`, which is the form lower.ss actually
;; produces and the form carrying the control that says WHY the check is there.
;; Its third operand is the expected tag, meaningful only for a type check and
;; passed as 0 by every other one.
(define nbody-checked-mach
  '(program
    ((entry (block ((const v-seven raw-word 7)
                    (mul   v-off   raw-word v-i v-seven)
                    (add   v-idx   raw-word v-off v-k)
                    (chk   bounds-check checked 0 v-idx v-len)
                    (load  v-val   raw-f64  v-b v-idx))
                   (ret v-val))))
    entry))

(define (bounds-check-instr? i)
  (and (eq? (car i) 'chk) (eq? (cadr i) 'bounds-check)))

(define x86-diff
  (differential-object arch-x86-64 x86-64-selector nbody-checked-mach bounds-check-instr?))
(define rv-diff
  (differential-object arch-rv64 rv64-selector nbody-checked-mach bounds-check-instr?))

(ck! "x86-64: the optimized build is the unoptimized one minus exactly the check, and nothing else"
     (object-diff-only-the-elision? x86-diff))
(ck! "RV64: the same"
     (object-diff-only-the-elision? rv-diff))
(ck! "the elision is REAL on both targets: the two streams are not the same stream"
     (and (not (equal? (object-diff-unoptimized x86-diff) (object-diff-optimized x86-diff)))
          (not (equal? (object-diff-unoptimized rv-diff) (object-diff-optimized rv-diff)))))
(ck! "and what was removed is the check sequence each target actually selects"
     (and (equal? (object-diff-removed x86-diff) '(cmp jge))
          (equal? (object-diff-removed rv-diff) '(bgeu))))
(ck! "a predicate matching nothing is refused rather than reported as a clean diff"
     (raises? (lambda ()
                (differential-object arch-x86-64 x86-64-selector nbody-checked-mach
                                     (lambda (i) #f)))))

;;; ==========================================================================
;;; 7. The D24 guard against evidence from code that really was contracted
;;; ==========================================================================
;;
;; Everything in section 2 used a hand-written evidence list, which proves the
;; guard fires but not that it fires on anything real. gcc contracts `d + a*b`
;; into one `vfmadd` under `-ffp-contract=fast` and leaves it as `mulsd`/`addsd`
;; under `off`, so the pair is a control for the evidence gatherer as well.

(define fma-c (path "fma.c"))
(call-with-output-file fma-c
  (lambda (p)
    (display "void fma_loop(double * restrict d, const double * restrict a,\n" p)
    (display "              const double * restrict b, long n) {\n" p)
    (display "  for (long i = 0; i < n; i++) d[i] = d[i] + a[i] * b[i];\n}\n" p))
  'replace)

;; `-mfma` matters: baseline x86-64 has no FMA to contract INTO, which is the
;; asymmetry D24 was found by. RV64 gcc contracts by default because rv64gc has
;; `fmadd.d`; x86-64 needs to be told the target has one before the permission
;; can do anything.
(define (contraction-of label flags)
  (let ((o (path label ".o")))
    (unless (shell (string-append "gcc " flags " -c " fma-c " -o " o))
      (error 'contraction-of "gcc refused the control program" flags))
    (map insn-mnemonic
         (contraction-insns (disassemble-file 'x86-64 o) "fma_loop"))))

(if (and (have? "gcc --version") (objdump-available? 'x86-64))
    (let ((fused (contraction-of "fused" "-O2 -mfma -fno-tree-vectorize -ffp-contract=fast"))
          (unfused (contraction-of "unfused" "-O2 -mfma -fno-tree-vectorize -ffp-contract=off")))
      (ck! "a contracted build really does show a fused multiply-add to objdump"
           (pair? fused))
      (ck! "and the same source with contraction off shows none: the gatherer is not a constant"
           (null? unfused))
      (ck! "the bit-exact policy refuses to compare a build carrying that evidence"
           (raises? (lambda () (check-fp-policy! bit-exact-policy fused 'test))))
      (ck! "and accepts the build that carries none"
           (fp-policy? (check-fp-policy! bit-exact-policy unfused 'test))))
    (begin (set! checks (+ checks 1)) (set! failures (+ failures 1))
           (display "  FAIL gcc or objdump is missing, and the D24 guard would then only\n")
           (display "       ever be tested against evidence this file wrote itself\n")))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
