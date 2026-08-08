;;; MILESTONE 4: packed arithmetic in nbody, verified in disassembly, both targets.
;;;
;;; The chain this exercises did not exist a day ago and every link in it was
;;; broken in a different way:
;;;
;;;   (sonic loops)      returned () for every program ever compiled
;;;   (sonic veclegal)   refused all seven of nbody's loops before reaching an
;;;                      array access
;;;   (sonic vectorize)  did not exist; the two emitters had only hand-written
;;;                      fixtures to consume
;;;
;;; So the assertions here are deliberately end to end: they start from
;;; bench/nbody/config-sonic.sps, run the front half of the real compiler, and
;;; finish at `objdump` reading bytes back. A test that started from a kernel
;;; literal would pass with every one of those links still broken -- which is
;;; exactly the state the fixtures left the project in.
;;;
;;; ## The control
;;;
;;; disasm.ss's header states the rule: "packed arithmetic present" is satisfied
;;; by any predicate that returns #t, so a test asserting it needs a program
;;; that answers the other way. The control here is the SCALAR remainder --
;;; emitted by the same pass, from the same kernel, for the elements a fixed
;;; width cannot cover -- which uses xmm and must NOT count as packed. That is a
;;; stronger control than a separately compiled program, because it rules out
;;; the predicate simply matching anything this compiler emits.

(import (chezscheme) (nanopass)
        (sonic lang) (sonic read) (sonic expand) (sonic parse) (sonic policy)
        (sonic anf) (sonic assign) (sonic inline) (sonic essa)
        (sonic loops) (sonic veclegal) (sonic vectorize)
        (sonic vec-x86-64) (sonic vec-rv64)
        (sonic object) (sonic disasm) (sonic driver) (sonic pipeline))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

;; --- the real compiler, as far as legality ---------------------------------

(define nbody-ssa
  (let* ((p (open-file-input-port "../bench/nbody/config-sonic.sps"))
         (bv (get-bytevector-all p)))
    (close-port p)
    (let ((o (open-file-output-port "/tmp/sonic-vectorize-real.sps"
                                    (file-options no-fail)
                                    (buffer-mode block) (native-transcoder))))
      (put-string o (utf8->string bv)) (close-port o))
    (essa-program
     (inline-program
      (assign-convert-program
       (anf-program
        (resolve-policy-program
         (parse-program (expand-program
                         (read-all-from-file "/tmp/sonic-vectorize-real.sps"))
                        nbody-externs))))))))

;; ELIDED: the IR the back end sees. veclegal on un-elided IR refuses every loop
;; for checks the compiled program does not contain.
(define-values (nbody-elided elide-st) (elide-to-fixpoint nbody-ssa))

(define nbody-loops (analyze-loops nbody-elided))
(define nbody-verdicts (vectorize-legal nbody-elided))

(define licensed
  (let find ((vs nbody-verdicts))
    (cond ((null? vs) #f)
          ((vl-legal? (car vs)) (car vs))
          (else (find (cdr vs))))))

(ck! "some loop in nbody is licensed for vectorization" (and licensed #t))

(define licensed-loop
  (and licensed
       (let find ((ls nbody-loops))
         (cond ((null? ls) #f)
               ((eq? (loop-name (car ls)) (vl-loop licensed)) (car ls))
               (else (find (cdr ls)))))))

;; --- the kernel, built from the IR -----------------------------------------

(define K (and licensed-loop (vectorize-loop nbody-elided licensed-loop licensed)))

(ck! "a kernel is built from it, with no refusal" (and K (not (vk-why K))))

;; LINEARIZATION. The loop steps one body per iteration and touches three
;; elements, so its trip count is 5 and its element count is 15. Unrolling the
;; trip count would write a third of the array and leave the rest.
(ck! "the loop linearizes: 5 iterations of 3 components is 15 elements"
     (and K (= 15 (vk-elements K)) (= 3 (vk-coeff K))))

;; The kernel is `p[k] := p[k] + dt * v[k]`: two loads, a multiply, an add and
;; a store. Asserted by SHAPE rather than by exact register numbers, which are
;; an allocation detail, but the op sequence is the semantics.
(ck! "and it is two loads, a multiply, an add and a store"
     (and K (equal? (map car (vk-kernel K)) '(vload vload vmul vadd vstore))))

;; `dt` is loop invariant, so it needs a lane broadcast before the loop rather
;; than a load per element. Reporting it is what lets a caller do that.
(ck! "dt is reported as the one loop-invariant value needing a lane"
     (and K (= 1 (length (vk-invariants K)))))

(ck! "and the two arrays it addresses are named"
     (and K (= 2 (length (vk-arrays K)))))

;; --- x86-64: emitted, assembled, and read back by objdump ------------------

(define (packed-on-x86)
  (let* ((plan (plan-for-verdict licensed #f))
         (kern (vk-for-x86-64 K
                              (list (cons (car (vk-arrays K)) 'rdi)
                                    (cons (cadr (vk-arrays K)) 'rsi))
                              'rcx)))
    (let-values (((vbody tail full rem) (vec-emit-loop plan kern (vk-elements K))))
      (values
       (disassemble-object
        (assemble-function 'x86-64 'nbody_advance_positions vbody
                           (list (cons 'encoder vec-encode-instr))))
       ;; THE CONTROL: the same kernel, same pass, for the remainder a fixed
       ;; width cannot cover. 15 elements at 4 lanes leaves 3.
       (disassemble-object
        (assemble-function 'x86-64 'nbody_advance_positions_tail tail
                           (list (cons 'encoder vec-encode-instr))))
       full rem))))

(when (and K (objdump-available? 'x86-64))
  (let-values (((vec scal full rem) (packed-on-x86)))
    (ck! "x86-64: 15 elements at 4 lanes is 3 full vector passes and 3 left over"
         (and (= full 3) (= rem 3)))
    (ck! "x86-64: binutils reads packed arithmetic back out of the vector body"
         (has-packed-arithmetic? vec 'nbody_advance_positions))
    ;; The width is asserted separately: "some vector instruction appeared" is
    ;; not the claim, 256-bit packed doubles is.
    (ck! "x86-64: and it is 256-bit, on ymm"
         (has-packed-arithmetic? vec 'nbody_advance_positions 'ymm))
    (ck! "x86-64: the multiply and the add are both packed, not just one"
         (let ((ms (map insn-mnemonic
                        (packed-arithmetic-insns vec 'nbody_advance_positions))))
           (and (member "vmulpd" ms) (member "vaddpd" ms) #t)))
    ;; ANTI-VACUITY. Same compiler, same kernel, same pass -- and it must answer
    ;; the other way, or the predicate is matching anything we emit.
    (ck! "x86-64: the scalar remainder is NOT packed, so the predicate discriminates"
         (not (has-packed-arithmetic? scal 'nbody_advance_positions_tail)))))

(unless (objdump-available? 'x86-64)
  (display "  ..   x86-64 objdump unavailable, so the milestone is unverified\n"))

;; --- RV64: the same kernel, length agnostic --------------------------------
;;
;; RVV does not unroll to a fixed width. `vsetvli` asks the hardware how many
;; elements it will take, the loop bumps each pointer by that many and branches,
;; so the same code runs on any VLEN. That is the whole reason the two targets
;; are separate beads rather than one with a flag.

(define (packed-on-rv64)
  (let* ((plan (rvv-plan-for-verdict licensed #f))
         (kern (vk-for-rv64 K (list (cons (car (vk-arrays K)) 'a0)
                                    (cons (cadr (vk-arrays K)) 'a1))))
         (listing (rvv-emit-loop plan kern '(a0 a1) 'a2 't0 't1 'Lvec)))
    (disassemble-object
     (assemble-function 'rv64 'nbody_advance_positions listing
                        (list (cons 'encoder rvv-encode-instr)
                              ;; Sizing is not encoding: label resolution sizes
                              ;; every instruction before substituting
                              ;; displacements, so an encoder-derived sizer
                              ;; would be handed an unresolved branch. RV64 is
                              ;; fixed width.
                              (cons 'sizer (lambda (i) 4)))))))

(when (and K (objdump-available? 'rv64))
  (let ((d (packed-on-rv64)))
    (ck! "RV64: binutils reads packed arithmetic back out"
         (has-packed-arithmetic? d 'nbody_advance_positions))
    (ck! "RV64: the multiply and the add are both vector-vector float ops"
         (let ((ms (map insn-mnemonic
                        (packed-arithmetic-insns d 'nbody_advance_positions))))
           (and (member "vfmul.vv" ms) (member "vfadd.vv" ms) #t)))
    ;; LENGTH AGNOSTIC, which is the property that distinguishes this from a
    ;; fixed-width unroll: the count comes from `vsetvli` and the loop branches
    ;; back. A straight-line body would pass the packed-arithmetic check and be
    ;; the wrong shape entirely.
    (ck! "RV64: the loop asks the hardware for its vector length"
         (exists (lambda (i) (string=? "vsetvli" (insn-mnemonic i)))
                 (disasm-insns d)))
    (ck! "RV64: and branches back, so it adapts rather than unrolling"
         (exists (lambda (i) (string=? "bne" (insn-mnemonic i)))
                 (disasm-insns d)))))

(unless (objdump-available? 'rv64)
  (display "  ..   riscv64 objdump unavailable, so the milestone is unverified\n"))

;; --- what is still refused, and why ----------------------------------------
;;
;; The pairwise force loop is NOT vectorizable at five bodies: it runs 4, 3, 2,
;; 1 and 0 times and a 512-bit vector holds eight doubles. Asserting the refusal
;; keeps the milestone honest about which loop it covers.
(ck! "the pairwise loop is still refused, for being too short to fill a vector"
     (let find ((vs nbody-verdicts))
       (cond ((null? vs) #f)
             ((eq? (vl-loop (car vs)) 'inner%24.201)
              (vl-refused-for? (car vs) 'trip-count-too-short))
             (else (find (cdr vs))))))

;; A loop that was never licensed must not yield a kernel. The pass is the
;; second half of veclegal's rule, not a second opinion on it.
(ck! "a refused loop yields a refusal rather than a kernel"
     (let find ((vs nbody-verdicts))
       (cond ((null? vs) #f)
             ((not (vl-legal? (car vs)))
              (let* ((nm (vl-loop (car vs)))
                     (l (let f ((ls nbody-loops))
                          (cond ((null? ls) #f)
                                ((eq? (loop-name (car ls)) nm) (car ls))
                                (else (f (cdr ls)))))))
                (and l (vk-why (vectorize-loop nbody-elided l (car vs))) #t)))
             (else (find (cdr vs))))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
