;;; Representation conversions: the pass, and the two failure modes it closes.
;;;
;;; repr.ss could prove two storage classes must merge and nothing could emit
;;; the instructions to get between them. It handled that two ways, and both
;;; were wrong:
;;;
;;;   a BOOLEAN-valued raw word merged with a tagged value RAISED, refusing
;;;   perfectly ordinary Scheme;
;;;
;;;   a FIXNUM-valued raw word merged with a tagged value answered `tagged`
;;;   SILENTLY, leaving an untagged machine word in the value class where D21's
;;;   collector scavenges it unconditionally. That is memory corruption, and
;;;   the silent case is the worse of the two.
;;;
;;; The third case, a double against anything else, still raises: it is a heap
;;; box and needs the allocator, which is a different kind of missing.

(import (chezscheme) (nanopass)
        (sonic lang) (sonic read) (sonic expand) (sonic parse) (sonic policy)
        (sonic anf) (sonic assign) (sonic inline) (sonic essa)
        (sonic repr) (sonic lift) (sonic convert) (sonic numeric) (sonic pipeline))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

;; The front half of the pipeline, down to the converted Lrepr datum. Stops
;; short of lowering on purpose: the programs below use `cons`, which has no
;; runtime entry yet, so anything that assembles them fails for an unrelated
;; reason and would hide what is being tested.
(define (front src . opt)
  (define externs (if (pair? opt) (car opt) '(display newline)))
  (let* ((p (open-file-output-port "/tmp/sonic-convert-test.sps"
                                   (file-options no-fail)
                                   (buffer-mode block) (native-transcoder))))
    (put-string p src) (close-port p))
  (let* ((p0 (inline-program
              (assign-convert-program
               (anf-program
                (resolve-policy-program
                 (parse-program
                  (expand-program
                   (read-all-from-file "/tmp/sonic-convert-test.sps"))
                  externs))))))
         (ssa (essa-program p0)))
    (let*-values (((p2 rp) (select-representations-program ssa))
                  ((lifted lrep) (lift-program (unparse-Lrepr p2)))
                  ((out st) (convert-program lifted
                                             (repr-report-classes rp)
                                             (repr-report-naturals rp)
                                             (repr-report-booleans rp))))
      (values out st))))

;; `pick` is called once with a raw word and once with a tagged object, so its
;; parameter is genuinely polymorphic and the join is forced. This is the
;; program the bead recorded as the reproduction.
(define (polymorphic producer)
  (string-append
   "(define (pick p) p)\n"
   "(define (main) (let ((a (pick " producer ")) (b (pick (cons 1 2)))) a))\n"
   "(main)\n"))

;; --- the boolean case, which used to be refused ---------------------------
(let-values (((form st) (front (polymorphic "(fx< 1 2)"))))
  (ck! "a boolean merged with a tagged value no longer refuses"
       (convert-report? st))
  (ck! "and it inserts exactly one retag, of kind `boolean`"
       (and (= 1 (convert-report-inserted st))
            (eq? 'boolean (cdar (convert-report-sites st))))))

;; --- the fixnum case, which used to be SILENT -----------------------------
;;
;; This is the one that mattered more. Nothing raised, nothing warned, and the
;; program compiled to an untagged word sitting in the value class.
(let-values (((form st) (front (polymorphic "(fx+ 1 2)"))))
  (ck! "a computed fixnum merged with a tagged value inserts a retag"
       (= 1 (convert-report-inserted st)))
  (ck! "and its kind is `fixnum`, not `boolean`"
       (eq? 'fixnum (cdar (convert-report-sites st)))))

;; --- a LITERAL still costs nothing ----------------------------------------
;;
;; Under numeric.ss a tagged fixnum's machine word is the value shifted left 3,
;; so a constant is materialised already shifted. Emitting a retag here would
;; be two instructions to compute a constant.
(let-values (((form st) (front (polymorphic "5"))))
  (ck! "a literal reaching `tagged` needs no conversion"
       (= 0 (convert-report-inserted st))))

;; --- the double case: BOXED, and it used to raise --------------------------
;;
;; A double has no bit pattern that serves -- it needs all 64 bits -- so unlike
;; the fixnum and boolean cases the conversion is not arithmetic. The value goes
;; on the heap and the tagged value is a pointer to it, which is a runtime
;; facility and is why this arrived after the other two.
(let-values (((form st) (front (polymorphic "(fl+ 1.0 2.0)"))))
  (ck! "a double merged with a tagged value no longer refuses"
       (= 1 (convert-report-inserted st)))
  (ck! "and its kind is `boxed`, not an arithmetic retag"
       (eq? 'boxed (cdar (convert-report-sites st)))))

;; --- the arithmetic, which is where a plausible wrong answer lives --------
;;
;; A boolean tags to sonic-false/sonic-true, 7 and 15. Shifting alone gives the
;; FIXNUMS 0 and 1 -- same storage class, same registers, and wrong. Asserted
;; against numeric.ss rather than against the literals so that changing the tag
;; scheme fails here instead of silently disagreeing.
(ck! "shifting a boolean left 3 and adding imm-tag gives sonic-false/sonic-true"
     (and (= sonic-false (+ (* 0 (expt 2 fx-tag-bits)) imm-tag))
          (= sonic-true  (+ (* 1 (expt 2 fx-tag-bits)) imm-tag))))
(ck! "shifting a boolean alone would give the fixnums 0 and 1, which is the bug"
     (and (not (= sonic-false 0)) (not (= sonic-true 8))))

;; --- nbody is untouched ---------------------------------------------------
;;
;; The benchmark mixes no representations, so this pass must be inert on it.
;; A retag appearing here would mean a conversion crept into the hot path.
(let-values (((form st)
              (let* ((p (open-file-input-port "../bench/nbody/config-sonic.sps"))
                     (bv (get-bytevector-all p)))
                (close-port p)
                (front (utf8->string bv) nbody-externs))))
  (ck! "nbody needs no conversions at all"
       (= 0 (convert-report-inserted st))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
