;;; E2-2ADDR.
;;;
;;; The pass exists because sonic/src/sonic/target-x86-64.ss refuses one case
;;; loudly: `dst = src2` for a non-commutative op, which needs a scratch
;;; register a selection rule cannot ask for. So the interesting checks here are
;;; not "did the list change shape". They are:
;;;
;;;   the case the selector refuses is the case this pass removes,
;;;   the rewrite computes the same bits, and
;;;   RV64 is left completely alone, because its arithmetic is three-address.
;;;
;;; The equivalence check is not a comparison against a hand-written expected
;;; instruction sequence. It links the emitted object against a C main and runs
;;; it, on BOTH targets, and compares the 64-bit result pattern against C's own
;;; `a - b`. A subtraction rewritten with the operands the wrong way round would
;;; pass any structural check and fail this one at 7.5 - 2.25.
;;;
;;; Needs gcc, riscv64-linux-gnu-gcc, objdump and qemu-riscv64. If they are
;;; missing these checks FAIL rather than skip, for the same reason
;;; sonic/test/rv64-test.ss does: a green run that silently verified nothing is
;;; worse than a red one.

(import (chezscheme) (nanopass) (rnrs io simple)
        (sonic lang) (sonic fixtures) (sonic regs) (sonic regalloc)
        (sonic twoaddr) (sonic select)
        (sonic target-x86-64) (sonic target-rv64)
        (sonic object))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define (raises? thunk) (guard (e (#t #t)) (thunk) #f))

(define (instrs-of prog)
  (cadr (cadr (car (cadr (unparse-Lmach prog))))))

;;; ==========================================================================
;;; 1. The case the selector refuses
;;; ==========================================================================

;; a - b with the destination already holding b. On x86-64 `subsd dst, src`
;; computes dst := dst - src, so this asks for b - a in the register that has to
;; end up holding a - b, and there is nowhere to stand a up.
(define aliased
  '(program ((entry (block ((sub v-x raw-f64 v-a v-x)
                            (move v-r raw-f64 v-x))
                           (ret v-r))))
     entry))

(ck! "the x86-64 selector REFUSES the aliased non-commutative case"
     (raises? (lambda () (select-program x86-64-selector (twoaddr arch-rv64 aliased)))))

(define fixed (twoaddr arch-x86-64 aliased))

(ck! "and after the fixup the same program selects"
     (not (raises? (lambda () (select-program x86-64-selector fixed)))))

(ck! "the fixup routes the left operand through the reserved float scratch"
     (equal? (instrs-of fixed)
             '((move xmm15 raw-f64 v-a)
               (sub xmm15 raw-f64 xmm15 v-x)
               (move v-x raw-f64 xmm15)
               (move v-r raw-f64 v-x))))

;; The middle instruction is now the dst = src1 case, which the rule emits as a
;; bare destructive operate. So the whole fixup costs two moves and no more.
(ck! "selection turns it into movsd/subsd/movsd, with subsd reading v-x"
     (equal? (cadr (car (cadddr (select-program x86-64-selector fixed))))
             '((movsd xmm15 v-a) (subsd xmm15 v-x) (movsd v-x xmm15)
               (movsd v-r v-x) (ret))))

;; The scratch is a physical register, so the output is still valid Lmach and
;; still passes back through the grammar. A datum that merely looks right is not
;; the same as one the language accepts.
(ck! "the pass returns a parsed Lmach program, not a bare list"
     (not (pair? fixed)))

;;; ==========================================================================
;;; 2. What is NOT rewritten
;;; ==========================================================================

(define commutative
  '(program ((entry (block ((add v-x raw-f64 v-a v-x)) (ret v-x)))) entry))

(ck! "a commutative op is left alone: the rule swaps the operands instead"
     (equal? (instrs-of (twoaddr arch-x86-64 commutative))
             '((add v-x raw-f64 v-a v-x))))

(define unaliased
  '(program ((entry (block ((sub v-x raw-f64 v-a v-b)) (ret v-x)))) entry))

(ck! "a non-commutative op whose destination aliases NOTHING is left alone"
     (equal? (instrs-of (twoaddr arch-x86-64 unaliased))
             '((sub v-x raw-f64 v-a v-b))))

(define dst-is-src1
  '(program ((entry (block ((sub v-x raw-f64 v-x v-b)) (ret v-x)))) entry))

(ck! "and so is dst = src1, which is the case the copy is dead in"
     (equal? (instrs-of (twoaddr arch-x86-64 dst-is-src1))
             '((sub v-x raw-f64 v-x v-b))))

(ck! "nbody's inner loop has no aliased op, so the pass is a no-op over it"
     (equal? (instrs-of (twoaddr arch-x86-64 (nbody-inner-mach)))
             (instrs-of (nbody-inner-mach))))

;;; ==========================================================================
;;; 3. RV64 does not need this pass
;;; ==========================================================================
;;
;; `fsub.d rd, rs1, rs2` writes a destination unrelated to either source, so
;; `dst = src2` is not a special case and there is nothing to fix. The pass says
;; so per TARGET, not per instruction.

(ck! "x86-64 is a two-address target and RV64 is not"
     (and (two-address-target? arch-x86-64)
          (not (two-address-target? arch-rv64))))

(ck! "RV64 gets the aliased program back with the same instruction list"
     (equal? (instrs-of (twoaddr arch-rv64 aliased))
             (cadr (cadr (car (cadr aliased))))))
(ck! "which is still the three-address form, scratch registers untouched"
     (equal? (instrs-of (twoaddr arch-rv64 aliased))
             '((sub v-x raw-f64 v-a v-x) (move v-r raw-f64 v-x))))

(ck! "and the RV64 selector consumes the aliased form directly"
     (equal? (cadr (car (cadddr (select-program rv64-selector
                                               (twoaddr arch-rv64 aliased)))))
             '((fsub.d v-x v-a v-x) (fsgnj.d v-r v-x v-x) (jalr zero ra 0))))

;; A back end nobody has written yet must not get a quiet #f here. Guessing
;; "three-address" for an unknown target emits wrong code for exactly the case
;; this file exists to catch.
(ck! "an unknown target RAISES rather than defaulting to `no fixup needed`"
     (raises? (lambda () (two-address-target? (make-arch 'vax '() '() '() '() '())))))

;;; ==========================================================================
;;; 4. The scratch registers come from regs.ss, not from here
;;; ==========================================================================

(ck! "the float scratch is xmm15 on x86-64 and ft11 on RV64"
     (and (eq? (scratch-for arch-x86-64 'raw-f64) 'xmm15)
          (eq? (scratch-for arch-rv64 'raw-f64) 'ft11)))
(ck! "the integer scratch is rax on x86-64 and t0 on RV64"
     (and (eq? (scratch-for arch-x86-64 'raw-word) 'rax)
          (eq? (scratch-for arch-rv64 'raw-word) 't0)))
(ck! "every scratch this pass names is one regs.ss actually reserves"
     (and (memq (scratch-for arch-x86-64 'raw-f64) (arch-scratch arch-x86-64))
          (memq (scratch-for arch-x86-64 'raw-word) (arch-scratch arch-x86-64))
          (memq (scratch-for arch-rv64 'raw-f64) (arch-scratch arch-rv64))
          (memq (scratch-for arch-rv64 'raw-word) (arch-scratch arch-rv64))))

;; A tagged value parked in a scratch register is a root the collector will
;; never find: it scavenges the value class unconditionally and the scratch
;; registers are outside every class. Covering that window is what the
;; `scratch-live` flag is for, and this pass has no channel to set it.
(ck! "routing a TAGGED value through a scratch register is refused, not done"
     (raises? (lambda () (scratch-for arch-x86-64 'tagged))))

;;; ==========================================================================
;;; 5. The allocator adapter
;;; ==========================================================================
;;
;; `live-intervals` reads every symbol in an operand slot as a vreg, so a
;; physical scratch name reaching `allocate` is a crash at best and a renamed
;; scratch at worst. Blanking them keeps the real vregs' live ranges exact.

(define fixed-instrs (instrs-of fixed))

(ck! "the raw fixup stream still carries physical scratch names"
     (and (memq 'xmm15 (map cadr fixed-instrs)) #t))

(ck! "strip-scratch blanks them and leaves every vreg alone"
     (equal? (strip-scratch arch-x86-64 fixed-instrs)
             '((move #f raw-f64 v-a)
               (sub #f raw-f64 #f v-x)
               (move v-x raw-f64 #f)
               (move v-r raw-f64 v-x))))

(let ((classes (make-eq-hashtable)))
  (for-each (lambda (p) (hashtable-set! classes (car p) (cdr p)))
            '((v-a . raw-f64) (v-x . raw-f64) (v-r . raw-f64)))
  ;; UPDATED: the allocator now recognises physical names itself (regalloc.ss's
  ;; `physical?`), so a raw scratch operand is SKIPPED rather than crashing or,
  ;; worse, being renamed to an allocatable register. strip-scratch is therefore
  ;; no longer load-bearing, and this asserts the property directly instead of
  ;; asserting that the unadapted call blows up.
  (set! checks (+ checks 1))
  (let* ((r (allocate arch-x86-64 fixed-instrs classes))
         (m (alloc-result-map r)))
    (if (not (hashtable-ref m 'xmm15 #f))
        (display "  ok   the allocator skips a physical scratch name rather than renaming it\n")
        (begin (set! failures (+ failures 1))
               (display "  FAIL a physical scratch name was allocated as a vreg\n"))))
  (let ((r (allocate arch-x86-64 (strip-scratch arch-x86-64 fixed-instrs) classes)))
    (ck! "and accepts the blanked stream with no spills"
         (null? (alloc-result-spills r)))
    (ck! "assigning float registers to the three real vregs and nothing else"
         (= 3 (vector-length (hashtable-keys (alloc-result-map r)))))))

;;; ==========================================================================
;;; 6. Equivalence, by running it
;;; ==========================================================================
;;
;; Standing in for a calling-convention pass with a fixed register map, exactly
;; as sonic/test/rv64-test.ss does: `(ret v)` carries no storage class, so no
;; rule can move the result into the ABI return register, and precolouring is
;; E3's bead. System V puts the first two doubles in xmm0/xmm1 and lp64d puts
;; them in fa0/fa1, and returns in the first of each.

(define tmp
  (let ((d (string-append (or (getenv "TMPDIR") "/tmp") "/sonic-twoaddr-test")))
    (system (string-append "mkdir -p " d)) d))
(define (path . parts) (apply string-append tmp "/" parts))

(define (resolve map- x)
  (cond ((pair? x) (cons (resolve map- (car x)) (resolve map- (cdr x))))
        ((symbol? x) (let ((p (assq x map-))) (if p (cdr p) x)))
        (else x)))

(define (selected-instrs sel prog)
  (cadr (car (cadddr (select-program sel prog)))))

(define x86-body
  (resolve '((v-a . xmm0) (v-x . xmm1) (v-r . xmm0))
           (selected-instrs x86-64-selector (twoaddr arch-x86-64 aliased))))

(define rv-body
  (resolve '((v-a . fa0) (v-x . fa1) (v-r . fa0))
           (selected-instrs rv64-selector (twoaddr arch-rv64 aliased))))

(define main-c (path "main.c"))
(call-with-output-file main-c
  (lambda (p)
    (display "#include <stdio.h>\n#include <string.h>\n" p)
    (display "extern double sonic_sub(double, double);\n" p)
    (display "static const double xs[][2] = {\n" p)
    (display "  {7.5, 2.25}, {0.0, 0.0}, {-0.0, 0.0}, {2.25, 7.5},\n" p)
    (display "  {0.1, 0.2}, {1e308, -1e308}, {-3.5, -3.5}\n};\n" p)
    (display "int main(void){\n  int bad = 0;\n" p)
    (display "  for (unsigned i = 0; i < sizeof xs / sizeof xs[0]; i++) {\n" p)
    (display "    double got = sonic_sub(xs[i][0], xs[i][1]);\n" p)
    (display "    double ref = xs[i][0] - xs[i][1];\n" p)
    (display "    unsigned long long g, r;\n" p)
    (display "    memcpy(&g, &got, 8); memcpy(&r, &ref, 8);\n" p)
    (display "    printf(\"%016llx %016llx\\n\", g, r);\n" p)
    (display "    if (g != r) bad = 1;\n  }\n  return bad;\n}\n" p))
  'replace)

(define (shell cmd) (zero? (system (string-append cmd " > " (path "log") " 2>&1"))))

(define (have? cmd) (zero? (system (string-append cmd " >/dev/null 2>&1"))))

(define (run-target! label instrs cc-cmd run-cmd)
  (set! checks (+ checks 1))
  (let* ((obj (path label ".o"))
         (exe (path label ".bin"))
         (fo (assemble-function (if (string=? label "x86-64") 'x86-64 'rv64)
                                'sonic_sub instrs)))
    (write-bytevector-to-file (function-object-elf fo) obj)
    (cond
     ((not (shell (string-append cc-cmd " " main-c " " obj " -o " exe)))
      (set! failures (+ failures 1))
      (display "  FAIL ") (display label)
      (display ": the linker refused our object; see ") (display (path "log"))
      (newline))
     ((not (shell (string-append run-cmd " " exe)))
      (set! failures (+ failures 1))
      (display "  FAIL ") (display label)
      (display ": the rewritten subtraction did not match C's a - b bit for bit\n")
      (system (string-append "cat " (path "log"))))
     (else
      (display "  ok   ") (display label)
      (display ": links, runs, and every result matches C's a - b bit for bit\n")))))

(cond
 ((not (have? "gcc --version"))
  (set! checks (+ checks 1)) (set! failures (+ failures 1))
  (display "  FAIL gcc is missing and the equivalence of the rewrite is DEFINED\n")
  (display "       as agreement with C's own subtraction. There is no local\n")
  (display "       expectation table to fall back to, on purpose.\n"))
 (else (run-target! "x86-64" x86-body "gcc" "")))

(cond
 ((not (and (have? "riscv64-linux-gnu-gcc --version") (have? "qemu-riscv64 -version")))
  (set! checks (+ checks 1)) (set! failures (+ failures 1))
  (display "  FAIL riscv64-linux-gnu-gcc or qemu-riscv64 is missing. The RV64\n")
  (display "       arm is what shows the untouched three-address form computes\n")
  (display "       the same bits as the rewritten one, so skipping it would\n")
  (display "       leave the pass half checked.\n"))
 (else (run-target! "rv64" rv-body "riscv64-linux-gnu-gcc -static" "qemu-riscv64")))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
