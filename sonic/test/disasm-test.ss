;;; E6-DISASM (bead qaq.2).
;;;
;;; Milestones are verified in emitted code, not by timing, and the reading has
;;; to be independent: our own decoder agreeing with our own encoder proves
;;; nothing, which is the rule sonic/test/object-test.ss already states for the
;;; container. So every predicate here runs real binutils and parses the text.
;;;
;;; EVERY ASSERTION IS PAIRED WITH A CONTROL. A test asserting "no bounds check"
;;; against a function that never had one proves nothing, so each predicate is
;;; run twice: once on a program that has the feature and once on a program that
;;; does not, and the check is that the SAME predicate answers differently. The
;;; controls come from two places on purpose:
;;;
;;;   gcc and riscv64-linux-gnu-gcc, because they can be told to put the feature
;;;   in or leave it out from one source file, and because a predicate that only
;;;   works on code we wrote is a predicate that has memorised our selector;
;;;
;;;   our own emitted objects, because the predicate has to work on what this
;;;   back end actually produces, which is the code the milestones are about.
;;;
;;; Missing tools FAIL rather than skip. A green run that silently verified
;;; nothing is exactly the vacuous pass this bead exists to prevent.

(import (chezscheme)
        (sonic lang)
        (sonic fixtures)
        (sonic regs)
        (sonic regalloc)
        (sonic twoaddr)
        (sonic select)
        (sonic target-x86-64)
        (sonic target-rv64)
        (sonic object)
        (sonic disasm)
        ;; the real-program milestone 2 arm at the end of this file
        (sonic pipeline) (sonic finalize) (sonic driver)
        (prefix (sonic preempt) preempt:))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))
(define (fail! why)
  (set! checks (+ checks 1)) (set! failures (+ failures 1))
  (display "  FAIL ") (display why) (newline))

(define (raises? thunk) (guard (e (#t #t)) (thunk) #f))

(define tmp
  (let ((d (string-append (or (getenv "TMPDIR") "/tmp") "/sonic-disasm-test")))
    (system (string-append "mkdir -p " d))
    d))
(define (path . parts) (apply string-append tmp "/" parts))
(define (have? cmd) (zero? (system (string-append cmd " >/dev/null 2>&1"))))
(define (shell cmd) (zero? (system (string-append cmd " > " (path "log") " 2>&1"))))

(define (write-c name text)
  (let ((p (path name)))
    (call-with-output-file p (lambda (o) (display text o)) 'replace)
    p))

;; -> a disassembly of `src` compiled with `flags`, or a hard error.
(define (compiled cc target label src flags)
  (let ((o (path label ".o")))
    (unless (shell (string-append cc " " flags " -c " src " -o " o))
      (error 'compiled "the control program did not compile; see the log"
             label flags (path "log")))
    (disassemble-file target o)))

;;; ==========================================================================
;;; 0. The tools, and the refusal to proceed without them
;;; ==========================================================================

(define have-x86 (and (have? "gcc --version") (objdump-available? 'x86-64)))
(define have-rv (and (have? "riscv64-linux-gnu-gcc --version")
                     (objdump-available? 'rv64)))

(unless have-x86
  (fail! "gcc or objdump is missing, and an independent reading of x86-64 code is the acceptance for this bead"))
(unless have-rv
  (fail! "riscv64-linux-gnu-gcc or riscv64-linux-gnu-objdump is missing; the RV64 half would go unverified"))

;;; ==========================================================================
;;; 1. Reading our own emitted objects back
;;; ==========================================================================
;;
;; Before any predicate means anything, the parser has to agree with the
;; selector about what was emitted. This is object-test.ss's discipline applied
;; to the thing that will carry the milestone assertions.

(define nbody-classes
  (let ((t (make-eq-hashtable)))
    (for-each (lambda (p) (hashtable-set! t (car p) (cdr p)))
              '((v-b . tagged) (v-i . raw-word) (v-k . raw-word)
                (v-seven . raw-word) (v-off . raw-word) (v-idx . raw-word)
                (v-val . raw-f64)))
    t))

(define (resolve-with m x)
  (cond ((pair? x) (cons (resolve-with m (car x)) (resolve-with m (cdr x))))
        ((symbol? x) (or (hashtable-ref m x #f) x))
        (else x)))

;; The real pipeline, exactly as object-test.ss runs it: the frozen Lrepr
;; fixture through lowering, the two-address fixup, selection and allocation.
;; Asserting poll-freedom over a hand-written listing would assert it about a
;; listing; this asserts it about the code the back end emits for nbody.
(define (nbody-body arch selector)
  (let* ((fixed (twoaddr arch (nbody-inner-mach)))
         (mach (cadr (cadr (car (cadr (unparse-Lmach fixed))))))
         (alloc (allocate arch (strip-scratch arch mach) nbody-classes))
         (selected (cadr (car (cadddr (select-program selector fixed))))))
    (resolve-with (alloc-result-map alloc) selected)))

(define (emit! target name listing)
  (disassemble-object (assemble-function target name listing)))

(when have-x86
  (let* ((body (nbody-body arch-x86-64 x86-64-selector))
         (d (emit! 'x86-64 'sonic_nbody_inner body)))
    (ck! "x86-64: objdump reads our nbody inner loop back as the mnemonics the selector chose"
         (equal? (map symbol->string (function-mnemonics d "sonic_nbody_inner"))
                 (map (lambda (i) (symbol->string (car i))) body)))
    (ck! "the disassembly knows which function each instruction belongs to"
         (equal? (disasm-function-names d) '("sonic_nbody_inner")))
    ;; D21's invariant, over a real reading rather than over our own table.
    (ck! "x86-64: the emitted nbody inner loop is poll-free"
         (poll-free? d "sonic_nbody_inner"))
    ;; The anti-vacuity guard built into the predicate itself. This function is
    ;; straight-line, so "no bounds check in its inner loop" is not a true
    ;; statement about it, it is an ill-formed one.
    (ck! "asking about the inner loop of a function that has no loop RAISES rather than passing"
         (raises? (lambda () (no-bounds-check? d "sonic_nbody_inner"))))
    (ck! "and asking about a function that is not in the disassembly at all RAISES too"
         (raises? (lambda () (function-insns d "sonic_no_such_thing"))))))

(when have-rv
  (let* ((body (nbody-body arch-rv64 rv64-selector))
         (d (emit! 'rv64 'sonic_nbody_inner body)))
    (ck! "RV64: objdump reads our nbody inner loop back as the mnemonics the selector chose"
         (equal? (map symbol->string (function-mnemonics d "sonic_nbody_inner"))
                 (map (lambda (i) (symbol->string (car i))) body)))
    (ck! "RV64: the emitted nbody inner loop is poll-free"
         (poll-free? d "sonic_nbody_inner"))))

;;; ==========================================================================
;;; 2. Milestone 2: no bounds-check branch in the inner loop
;;; ==========================================================================
;;
;; A rotated counted loop has exactly one conditional branch, its latch. The
;; check shows up as a second one. Both halves of the control are the same C
;; source compiled the same way, differing only by an explicit index test.

(define bc-src
  (write-c "bc.c"
    (string-append
     "double sum_checked(const double *a, long n, long len) {\n"
     "  double s = 0.0;\n"
     "  for (long i = 0; i < n; i++) {\n"
     "    if (i >= len) __builtin_trap();\n"
     "    s += a[i];\n  }\n  return s;\n}\n"
     "double sum_unchecked(const double *a, long n) {\n"
     "  double s = 0.0;\n"
     "  for (long i = 0; i < n; i++) s += a[i];\n  return s;\n}\n")))

(define bc-flags "-O2 -fno-tree-vectorize")

(when have-x86
  (let ((d (compiled "gcc" 'x86-64 "bc-x86" bc-src bc-flags)))
    (ck! "x86-64 control: the UNCHECKED loop has no bounds-check branch"
         (no-bounds-check? d "sum_unchecked"))
    (ck! "x86-64 control: the CHECKED loop does, so the predicate distinguishes them"
         (not (no-bounds-check? d "sum_checked")))
    ;; The point is that the predicate NAMES what it found rather than only
    ;; answering yes -- not that gcc picks one particular branch. Pinning the
    ;; mnemonic pinned gcc's instruction selection, which moved between versions
    ;; and turned a toolchain difference into what looked like a compiler bug.
    (ck! "and it names the branches it found rather than only saying no"
         (let ((bs (bounds-check-branches d "sum_checked")))
           (and (pair? bs)
                (for-all (lambda (i) (conditional-branch? d i)) bs))))
    (ck! "the loop finder found a real loop in both, with the latch branching backwards"
         (and (< (loop-head (inner-loop d "sum_checked"))
                 (loop-latch (inner-loop d "sum_checked")))
              (< (loop-head (inner-loop d "sum_unchecked"))
                 (loop-latch (inner-loop d "sum_unchecked")))))))

(when have-rv
  (let ((d (compiled "riscv64-linux-gnu-gcc" 'rv64 "bc-rv" bc-src bc-flags)))
    (ck! "RV64 control: the UNCHECKED loop has no bounds-check branch"
         (no-bounds-check? d "sum_unchecked"))
    (ck! "RV64 control: the CHECKED loop does"
         (not (no-bounds-check? d "sum_checked")))
    (ck! "and on RV64 it names them too"
         (let ((bs (bounds-check-branches d "sum_checked")))
           (and (pair? bs)
                (for-all (lambda (i) (conditional-branch? d i)) bs))))
    ;; RISC-V objdump prints a header for every local label in the symbol table,
    ;; which would otherwise split one function into five and hide the loop.
    (ck! "a local .L label is read as part of the function it sits inside, not as a new one"
         (>= (length (function-insns d "sum_checked")) 8))))

;;; ==========================================================================
;;; 3. The same predicate, on code THIS back end emitted
;;; ==========================================================================
;;
;; gcc's output proves the predicate reads machine code. It does not prove the
;; predicate reads OUR machine code, and the milestone is about ours.

(define x86-loop-checked
  '((mov rax (imm 0))
    top
    (cmp rax rdx)
    (jge (label trap))
    (add rax rcx)
    (cmp rax rsi)
    (jl (label top))
    trap
    (ret)))

(define x86-loop-plain
  '((mov rax (imm 0))
    top
    (add rax rcx)
    (cmp rax rsi)
    (jl (label top))
    (ret)))

;; --- the shape THIS compiler emits ------------------------------------------
;;
;; Everything above is gcc's rotated counted loop, where the latch IS the test.
;; A SonicScheme loop is a procedure that tail-calls itself: the exit test is a
;; conditional branch FORWARD to the join, and the back edge is a plain `jmp`
;; backward. The loop finder recognized only the first spelling, so `inner-loop`
;; raised "this function has no loop" for all seventeen of nbody's compiled
;; functions and milestone 2 could not be stated about our own output at all.
(define x86-selfcall-loop
  '((mov rax (imm 0))
    top
    (add rax rcx)
    (cmp rax rsi)
    (jge (label done))
    (jmp (label top))
    done
    (ret)))

;; The same, with a check branching to a trap ahead of the loop's own exit.
(define x86-selfcall-checked
  '((mov rax (imm 0))
    top
    (cmp rax rdx)
    (jge (label trap))
    (add rax rcx)
    (cmp rax rsi)
    (jge (label done))
    (jmp (label top))
    trap
    (ret)
    done
    (ret)))

(when have-x86
  (let ((d (emit! 'x86-64 'sonic_selfcall x86-selfcall-loop)))
    (ck! "a self-tail-call loop is found at all, unconditional back edge and all"
         (loop? (inner-loop d "sonic_selfcall")))
    (ck! "and the latch it found is the unconditional jmp, not the exit test"
         (let ((l (inner-loop d "sonic_selfcall")))
           (and (not (conditional-branch? d (loop-latch-insn d l)))
                (string=? (insn-mnemonic (loop-latch-insn d l)) "jmp")))))

  ;; THE REFUSAL, and it matters more than the finding. With an unconditional
  ;; latch the loop's own exit test is an ordinary conditional branch sitting in
  ;; the body, so "every conditional branch but the latch" would report it as a
  ;; bounds check -- a check that is not there, in a loop that is clean. The
  ;; predicate refuses instead of answering, because an assertion that says what
  ;; we want to hear is worth less than no assertion.
  (ck! "bounds-check-branches REFUSES on that shape rather than miscounting"
       (raises? (lambda () (bounds-check-branches
                            (emit! 'x86-64 'sonic_selfcall x86-selfcall-loop)
                            "sonic_selfcall"))))

  ;; Identified by DESTINATION instead: a check is a branch to the trap, which
  ;; is what target-x86-64.ss emits (`(jge (label sonic-bounds-error))`).
  ;; The trap's address, computed from the listing the way
  ;; harness/disasm-sonic.sh computes its label map: sum instruction-size up to
  ;; the label. `label-offset` in driver.ss does the same thing and is private.
  (let* ((d (emit! 'x86-64 'sonic_sc_chk x86-selfcall-checked))
         (trap (let walk ((xs x86-selfcall-checked) (pc 0))
                 (cond ((null? xs) (error 'trap-label "no trap label" xs))
                       ((symbol? (car xs))
                        (if (eq? (car xs) 'trap) pc (walk (cdr xs) pc)))
                       (else (walk (cdr xs)
                                   (+ pc (instruction-size 'x86-64 (car xs)))))))))
    (ck! "check-branches-to finds the check by where it branches"
         (equal? (map insn-mnemonic (check-branches-to d "sonic_sc_chk" (list trap)))
                 '("jge")))
    (ck! "and does NOT count the loop's own exit test, which the old reading would"
         (= 1 (length (check-branches-to d "sonic_sc_chk" (list trap))))))

  (let* ((d (emit! 'x86-64 'sonic_selfcall x86-selfcall-loop))
         (trap 999999))
    (ck! "a clean self-tail-call loop has no branch to any trap"
         (no-check-branch-to? d "sonic_selfcall" (list trap)))))

(define rv-loop-checked
  '((addi a0 zero 0)
    top
    (bgeu a0 a2 trap)
    (addi a0 a0 1)
    (blt a0 a1 top)
    trap
    (jalr zero ra 0)))

(define rv-loop-plain
  '((addi a0 zero 0)
    top
    (addi a0 a0 1)
    (blt a0 a1 top)
    (jalr zero ra 0)))

(when have-x86
  (ck! "x86-64, our own emission: the loop WITHOUT a check reads back clean"
       (no-bounds-check? (emit! 'x86-64 'sonic_plain x86-loop-plain) "sonic_plain"))
  (ck! "x86-64, our own emission: the loop WITH one does not"
       (not (no-bounds-check? (emit! 'x86-64 'sonic_checked x86-loop-checked)
                              "sonic_checked")))
  (ck! "and in the linked-image reading, that branch is the one leaving the loop body"
       (equal? (map insn-mnemonic
                    (loop-exit-branches (emit! 'x86-64 'sonic_checked x86-loop-checked)
                                        "sonic_checked"))
               '("jge"))))

(when have-rv
  (ck! "RV64, our own emission: the loop WITHOUT a check reads back clean"
       (no-bounds-check? (emit! 'rv64 'sonic_plain rv-loop-plain) "sonic_plain"))
  (ck! "RV64, our own emission: the loop WITH one does not"
       (not (no-bounds-check? (emit! 'rv64 'sonic_checked rv-loop-checked) "sonic_checked")))
  (ck! "and the branch found is the bgeu the RV64 selector emits for a bounds check"
       (equal? (map insn-mnemonic
                    (bounds-check-branches (emit! 'rv64 'sonic_checked rv-loop-checked)
                                           "sonic_checked"))
               '("bgeu"))))

;;; ==========================================================================
;;; 4. Stage 10: packed arithmetic is present
;;; ==========================================================================
;;
;; The control is the same loop compiled two ways. Without it, "packed
;; arithmetic present" is satisfied by any predicate that returns #t.

(define vec-src
  (write-c "vec.c"
    (string-append
     "void fma_loop(double * restrict d, const double * restrict a,\n"
     "              const double * restrict b, long n) {\n"
     "  for (long i = 0; i < n; i++) d[i] = d[i] + a[i] * b[i];\n}\n")))

(when have-x86
  (let ((packed (compiled "gcc" 'x86-64 "vec-x86-packed" vec-src
                          "-O3 -march=x86-64-v4 -ffp-contract=fast"))
        (scalar (compiled "gcc" 'x86-64 "vec-x86-scalar" vec-src
                          "-O2 -fno-tree-vectorize -ffp-contract=off")))
    (ck! "x86-64: the vectorized build has packed arithmetic"
         (has-packed-arithmetic? packed "fma_loop"))
    (ck! "x86-64: the scalar build does not, so the predicate is not a constant"
         (not (has-packed-arithmetic? scalar "fma_loop")))
    ;; The bead names AVX-512 specifically, so the width is asserted separately
    ;; rather than being taken on trust from "some vector instruction appeared".
    (ck! "and it is AVX-512: a packed FMA on zmm, which is what stage 10 is for"
         (and (has-packed-arithmetic? packed "fma_loop" 'zmm)
              (exists (lambda (i)
                        (let ((m (insn-mnemonic i)))
                          (and (>= (string-length m) 6)
                               (string=? "vfmadd" (substring m 0 6)))))
                      (packed-arithmetic-insns packed "fma_loop" 'zmm))))
    ;; A vector LOAD is not vectorized arithmetic. Counting it would let a
    ;; program that only moves vectors around claim the milestone.
    (ck! "the scalar build's own movsd and mulsd are not mistaken for packed work"
         (null? (packed-arithmetic-insns scalar "fma_loop")))))

(when have-rv
  (let ((packed (compiled "riscv64-linux-gnu-gcc" 'rv64 "vec-rv-packed" vec-src
                          "-O3 -march=rv64gcv -ffp-contract=fast"))
        (scalar (compiled "riscv64-linux-gnu-gcc" 'rv64 "vec-rv-scalar" vec-src
                          "-O2 -fno-tree-vectorize -ffp-contract=off")))
    (ck! "RV64: the RVV build has packed arithmetic"
         (has-packed-arithmetic? packed "fma_loop"))
    (ck! "RV64: the scalar build does not"
         (not (has-packed-arithmetic? scalar "fma_loop")))
    (ck! "and what was found is an RVV arithmetic op, not vsetvli or a vector load"
         (exists (lambda (i)
                   (let ((m (insn-mnemonic i)))
                     (and (>= (string-length m) 2) (string=? "vf" (substring m 0 2)))))
                 (packed-arithmetic-insns packed "fma_loop")))))

;;; ==========================================================================
;;; 5. D21: poll-free, wired through preempt.ss to a real reading
;;; ==========================================================================
;;
;; preempt.ss's `poll-free?` takes mnemonics and no real ISA spells a poll
;; `poll`, so the mnemonic half can only ever catch our own pseudo-ops. The
;; sequence recognizer is the half that can see a real one, and this is its
;; control: the same loop with and without a suspend-flag test.

(define poll-src
  (write-c "poll.c"
    (string-append
     "extern volatile int sonic_suspend;\n"
     "void sonic_handle(void);\n"
     "double loop_with_poll(const double *a, long n) {\n"
     "  double s = 0.0;\n"
     "  for (long i = 0; i < n; i++) { if (sonic_suspend) sonic_handle(); s += a[i]; }\n"
     "  return s;\n}\n"
     "double loop_no_poll(const double *a, long n) {\n"
     "  double s = 0.0;\n"
     "  for (long i = 0; i < n; i++) s += a[i];\n  return s;\n}\n")))

(ck! "preempt.ss's own predicate still answers over a mnemonic list, unchanged"
     (and (preempt:poll-free? '(mov add cmp jl ret))
          (not (preempt:poll-free? '(mov safepoint ret)))))

(when have-x86
  (let ((d (compiled "gcc" 'x86-64 "poll-x86" poll-src "-O2 -fno-tree-vectorize")))
    (ck! "x86-64 control: the loop WITH a suspend-flag poll is not poll-free"
         (not (poll-free? d "loop_with_poll")))
    (ck! "x86-64 control: the identical loop without one is, so the recognizer distinguishes them"
         (poll-free? d "loop_no_poll"))
    (ck! "and the sequence it matched is a load and the branch that tests it"
         (let ((ps (poll-sequences d "loop_with_poll")))
           (and (pair? ps)
                (scalar-integer-load? d (car (car ps)))
                (conditional-branch? d (cdr (car ps))))))))

(when have-rv
  (let ((d (compiled "riscv64-linux-gnu-gcc" 'rv64 "poll-rv" poll-src
                     "-O2 -fno-tree-vectorize")))
    (ck! "RV64 control: the loop WITH a poll is not poll-free"
         (not (poll-free? d "loop_with_poll")))
    (ck! "RV64 control: the loop without one is"
         (poll-free? d "loop_no_poll"))))


;;; ==========================================================================
;;; Milestone 2, on a REAL compiled inner loop rather than a fixture
;;; ==========================================================================
;;
;; Everything above proves the PREDICATES work, on hand-written listings and on
;; gcc's output. This compiles two programs through the whole driver and asks
;; the question milestone 2 actually asks.
;;
;; ORDER IS DELIBERATE: nbody first. Compilation is not idempotent within a
;; process (6gk.25 -- the name counter in lower.ss is never reset), so the first
;; compile is the only one running from a clean state. nbody is the arm whose
;; answer must be ZERO, and a contaminated compile reporting zero would be a
;; FALSE PASS on the milestone. The control is second, where contamination could
;; only turn its non-zero answer into a failure -- loud, not silent. When
;; 6gk.25 is fixed this ordering stops mattering and the comment can go.
;;
;; A CHECK IS FOUND BY WHERE IT BRANCHES. `resolve-labels` places an
;; `extra-labels` entry at (+ code-size offset), so the trap's address is
;; computable rather than guessable -- which it had to be, because guessing it
;; produced a confident zero for a control that has two.

(define (extern-label-addrs target ls)
  (let ((defined (filter symbol? ls)) (refs '()))
    (let walk ((xs ls))
      (unless (null? xs)
        (let mem ((y (car xs)))
          (cond ((and (pair? y) (eq? (car y) 'label) (pair? (cdr y)))
                 (unless (memq (cadr y) refs) (set! refs (cons (cadr y) refs))))
                ((pair? y) (mem (car y)) (mem (cdr y)))
                (else 'no)))
        (walk (cdr xs))))
    (let loop ((rs refs) (n 4096) (acc '()))
      (cond ((null? rs) acc)
            ((memq (car rs) defined) (loop (cdr rs) n acc))
            (else (loop (cdr rs) (+ n 64) (cons (cons (car rs) n) acc)))))))

(define (code-size-of target ls)
  (let cnt ((xs ls) (pc 0))
    (cond ((null? xs) pc)
          ((symbol? (car xs)) (cnt (cdr xs) pc))
          (else (cnt (cdr xs) (+ pc (instruction-size target (car xs))))))))

;; Returns (values disasm name trap-address) for the first function matching p.
(define (compiled-loop-of path externs p)
  (let* ((c (compile-sonic path externs))
         (f (let find ((fs (compiled-functions c)))
              (cond ((null? fs) (error 'compiled-loop-of "no such function" path))
                    ((p (symbol->string (finalized-name (car fs)))) (car fs))
                    (else (find (cdr fs)))))))
    (let* ((nm (finalized-name f)) (ls (finalized-listing f))
           (extra (extern-label-addrs 'x86-64 ls))
           (cs (code-size-of 'x86-64 ls))
           (trap (cond ((assq 'sonic-bounds-error extra)
                        => (lambda (e) (+ cs (cdr e))))
                       (else -1))))
      (values (disassemble-object
               (assemble-function 'x86-64 nm ls (list (cons 'extra-labels extra))))
              (symbol->string nm) trap))))

(when have-x86
  ;; nbody FIRST -- see the note above.
  (let-values (((d nm trap)
                (compiled-loop-of "../bench/nbody/config-sonic.sps" nbody-externs
                                  (lambda (s) (and (>= (string-length s) 6)
                                                   (string=? (substring s 0 6) "inner%"))))))
    (ck! "MILESTONE 2: nbody's inner loop is found in the emitted code"
         (loop? (inner-loop d nm)))
    (ck! "MILESTONE 2: and it contains no branch to the bounds-error trap"
         (no-check-branch-to? d nm (list trap)))
    ;; Non-vacuity from the other side: the trap is not merely unreachable, it
    ;; is not named anywhere in the function.
    (ck! "and the trap is not referenced by that function at all"
         (= trap -1)))

  ;; --- Milestone 4, same reading, on the same compiled program -------------
  ;;
  ;; vectorize-test.ss already asserts packed arithmetic on both targets, but it
  ;; does so on the VECTORIZER'S KERNEL -- emitted from a verdict, assembled, and
  ;; read back. That is the right test for the pass and the only one available
  ;; for RV64, which has no runtime to build a whole program with. This is the
  ;; other half: the arithmetic is still packed in the binary the driver
  ;; actually produces, after every pass downstream of the vectorizer has had a
  ;; turn at it.
  (let-values (((d nm trap)
                (compiled-loop-of "../bench/nbody/config-sonic.sps" nbody-externs
                                  (lambda (s) (and (>= (string-length s) 6)
                                                   (string=? (substring s 0 6) "inner%"))))))
    (ck! "MILESTONE 4: the compiled nbody inner loop really does carry packed arithmetic"
         (has-packed-arithmetic? d (string->symbol nm)))
    ;; 128-BIT, AND THAT IS THE MILESTONE'S PROBLEM RATHER THAN THIS TEST'S.
    ;;
    ;; vectorize-test.ss asserts 256-bit `ymm` and passes -- on the VECTORIZER'S
    ;; KERNEL. The compiled binary is 128-bit `xmm` throughout, because
    ;; `vectorize.ss` IS NOT IMPORTED BY driver.ss: nothing in the pipeline
    ;; calls it. Every packed instruction that reaches a real program comes from
    ;; slp.ss, which packs PAIRS -- its own header says "three components fill
    ;; two lanes, not four or eight" and "two lanes fit in one 128-bit
    ;; register".
    ;;
    ;; So this asserts what is true and names what is not, rather than asserting
    ;; the width we want and failing. Milestone 4 is NOT met by this: its
    ;; assertion passes on a kernel that never ships. See 1mp.
    (ck! "and it is 128-bit xmm -- the pairs slp.ss packs, NOT vectorize.ss's 256-bit"
         (and (has-packed-arithmetic? d (string->symbol nm) 'xmm)
              (not (has-packed-arithmetic? d (string->symbol nm) 'ymm))))
    (ck! "MILESTONE 4: the subtract, multiply and add are all packed"
         (let ((ms (map insn-mnemonic
                        (packed-arithmetic-insns d (string->symbol nm)))))
           (and (member "vsubpd" ms) (member "vmulpd" ms) (member "vaddpd" ms) #t))))

  ;; ANTI-VACUITY for the above: a scalar function from the SAME compiled
  ;; program must answer the other way, or the predicate is matching anything
  ;; this compiler emits.
  (let-values (((d nm trap)
                (compiled-loop-of "../bench/nbody/config-sonic.sps" nbody-externs
                                  (lambda (s) (string=? s "subtract-pairs")))))
    (ck! "and a scalar function in that same binary is NOT packed"
         (not (has-packed-arithmetic? d (string->symbol nm)))))

  ;; THE CONTROL. Same predicate, same pipeline, a bound the analysis cannot
  ;; prove -- so the check survives and must be found. Without this the
  ;; assertion above is satisfied by any program that fails to emit a check for
  ;; any reason, including a broken elision pass.
  (let ((ctl "/tmp/sonic-m2-control.sps"))
    (with-output-to-file ctl
      (lambda ()
        (display "(define v (make-flvector 4 0.0))\n")
        (display "(define (fill i n)\n")
        (display "  (if (fx= i n) 0.0 (begin (flvector-set! v i 1.0) (fill (fx+ i 1) n))))\n")
        (display "(define (main) (display (fill 0 (string->number (cadr (command-line))))) (newline))\n")
        (display "(main)\n"))
      'replace)
    (let-values (((d nm trap)
                  (compiled-loop-of ctl '(command-line length cadr string->number
                                          display newline)
                                    (lambda (s) (string=? s "fill")))))
      (ck! "CONTROL: a bound the analysis cannot prove keeps its check"
           (> trap -1))
      (ck! "CONTROL: and the same predicate finds it inside the inner loop"
           (pair? (check-branches-to d nm (list trap))))
      (ck! "CONTROL: every one it found is a conditional branch to the trap"
           (for-all (lambda (i)
                      (and (conditional-branch? d i)
                           (equal? (branch-target i) trap)))
                    (check-branches-to d nm (list trap)))))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
