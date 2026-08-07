;;; Disassembly assertions: milestones verified in emitted code, by binutils.
;;;
;;; E6-DISASM (bead qaq.2). Milestone 2 says "no bounds-check branch in the
;;; inner loop" and stage 10 says "packed arithmetic is present". Neither is a
;;; timing claim and neither should be checked by one: on a machine with no
;;; `cpufreq` control the wall clock drifts, and D17 already moved the primary
;;; instrument off it. The strongest available evidence is the instruction
;;; stream itself.
;;;
;;; ## Why real binutils and not our own decoder
;;;
;;; sonic/src/sonic/object.ss states the rule for the container and it applies
;;; here with more force: our decoder agreeing with our encoder proves nothing.
;;; A predicate that reads back the same table the selector wrote is a mirror,
;;; and a mirror cannot report a bug that lives in the table. So every predicate
;;; in this file runs `objdump -d` (or `riscv64-linux-gnu-objdump -d -M
;;; no-aliases`) over an emitted object and parses the text, which is an
;;; independent reading by a program nobody here maintains.
;;;
;;; A missing objdump therefore FAILS. `objdump-available?` exists so a caller
;;; can say so loudly; it does not exist so a caller can skip.
;;;
;;; ## Every predicate needs a control, and that is not this file's job
;;;
;;; A test asserting "no bounds check" against a function that never had one
;;; proves nothing, and neither does "packed arithmetic present" against a
;;; function whose whole body is one `vaddpd`. The predicates below are written
;;; so that the same predicate, unchanged, answers the opposite way on a program
;;; that does have the feature. sonic/test/disasm-test.ss pairs each one with
;;; that program and checks it distinguishes them. Two of the anti-vacuity
;;; guards are in the predicates themselves rather than in the test:
;;;
;;;   - `no-bounds-check?` RAISES on a function with no loop at all. "No bounds
;;;     check in the inner loop" is not a true statement about a function with
;;;     no inner loop, it is an ill-formed one, and returning #t for it is the
;;;     exact vacuous pass the bead warns about.
;;;   - `has-packed-arithmetic?` reports WHICH instructions it found, so a test
;;;     can assert the register width as well as the presence.
;;;
;;; ## What a bounds check looks like from the outside
;;;
;;; We must recognize one without being told, because being told is what the
;;; independent reading exists to avoid. Two signals, and the predicate uses the
;;; first because it survives an unlinked object:
;;;
;;;   1. AN EXTRA CONDITIONAL BRANCH. A rotated counted loop has exactly one
;;;      conditional branch, its latch. Any second conditional branch in the
;;;      body is a test the loop did not need to iterate, which for our
;;;      benchmarks is a check. Measured on gcc 15.2 output for both ISAs: the
;;;      checked loop carries `jle`/`bge` beside the latch and the unchecked one
;;;      carries the latch alone.
;;;   2. AN EDGE OUT OF THE BODY. The same branch, identified by its target
;;;      lying outside [head, latch]. Strictly better, and unusable on a
;;;      relocatable object: gcc puts the trap in `.text.unlikely` and leaves the
;;;      displacement zero for the linker, so the printed target falls back
;;;      inside the loop. `loop-exit-branches` is here for linked images.
;;;
;;; ## The poll recognizer is deliberately over-broad
;;;
;;; sonic/src/sonic/preempt.ss says so in as many words: a false positive costs
;;; one look at a disassembly, a false negative means we shipped the design
;;; PREEMPTION.md rejected. Its `poll-free?` takes mnemonics, and no real ISA
;;; spells a poll `poll`, so mnemonics alone can never see one. The wiring is a
;;; SEQUENCE recognizer feeding the same predicate:
;;;
;;;   a scalar integer load from a non-indexed address, followed within
;;;   `poll-window` instructions by a conditional branch.
;;;
;;; That is the shape of every poll in the three runtimes PREEMPTION.md cites: a
;;; global suspend word read and tested. It excludes the loop's own data stream,
;;; which is indexed and lands in the float or vector file, and it excludes a
;;; bounds check, whose compare has no memory operand.

(library (sonic disasm)
  (export objdump-for objdump-flags objdump-available?
          disassemble-file disassemble-elf disassemble-object

          insn? insn-address insn-mnemonic insn-operands insn-function
          insn-bytes insn-text
          disasm? disasm-target disasm-insns disasm-function-names
          function-insns function-mnemonics

          conditional-branch? unconditional-branch? branch-target
          memory-read? scalar-integer-load?

          loop? loop-head loop-latch loop-insns
          inner-loop function-loops

          no-bounds-check? bounds-check-branches loop-exit-branches
          has-packed-arithmetic? packed-arithmetic-insns
          poll-free? poll-sequences poll-window
          contraction-insns)
  (import (chezscheme)
          (prefix (sonic preempt) preempt:)
          (sonic object))

  ;; --- running the tool -----------------------------------------------------

  (define (objdump-for target)
    (case target
      ((x86-64) "objdump")
      ((rv64)   "riscv64-linux-gnu-objdump")
      (else (error 'objdump-for "no disassembler known for this target" target))))

  ;; `-M no-aliases` on RISC-V because an alias hides the instruction that was
  ;; actually encoded: `mv` is `addi rd, rs, 0` and `ret` is `jalr zero, ra, 0`,
  ;; and a predicate that greps for branches must see `bge`, not `bgez`.
  (define (objdump-flags target)
    (case target
      ((x86-64) "-d")
      ((rv64)   "-d -M no-aliases")
      (else (error 'objdump-flags "no disassembler flags for this target" target))))

  (define (objdump-available? target)
    (zero? (system (string-append (objdump-for target)
                                  " --version >/dev/null 2>&1"))))

  (define scratch-dir
    (let ((d #f))
      (lambda ()
        (unless d
          (set! d (string-append (or (getenv "TMPDIR") "/tmp") "/sonic-disasm"))
          (system (string-append "mkdir -p " d " >/dev/null 2>&1")))
        d)))

  (define counter 0)
  (define (scratch-path suffix)
    (set! counter (+ counter 1))
    (string-append (scratch-dir) "/d" (number->string counter) suffix))

  ;; --- text helpers ---------------------------------------------------------

  (define (trim s)
    (let* ((n (string-length s))
           (a (let loop ((i 0))
                (if (and (< i n) (char-whitespace? (string-ref s i))) (loop (+ i 1)) i)))
           (b (let loop ((i n))
                (if (and (> i a) (char-whitespace? (string-ref s (- i 1)))) (loop (- i 1)) i))))
      (substring s a b)))

  (define (split-char str ch)
    (let loop ((i 0) (start 0) (acc '()))
      (cond ((= i (string-length str)) (reverse (cons (substring str start i) acc)))
            ((char=? (string-ref str i) ch)
             (loop (+ i 1) (+ i 1) (cons (substring str start i) acc)))
            (else (loop (+ i 1) start acc)))))

  (define (whitespace-split str)
    (let loop ((i 0) (start #f) (acc '()))
      (cond ((= i (string-length str))
             (reverse (if start (cons (substring str start i) acc) acc)))
            ((char-whitespace? (string-ref str i))
             (loop (+ i 1) #f (if start (cons (substring str start i) acc) acc)))
            (else (loop (+ i 1) (or start i) acc)))))

  ;; Comma splitting that does not cut inside a memory operand: `(%rdi,%rax,8)`
  ;; is ONE operand and naive splitting turns it into three.
  (define (split-operands str)
    (let loop ((i 0) (depth 0) (start 0) (acc '()))
      (cond ((= i (string-length str))
             (reverse (cons (trim (substring str start i)) acc)))
            ((char=? (string-ref str i) #\() (loop (+ i 1) (+ depth 1) start acc))
            ((char=? (string-ref str i) #\)) (loop (+ i 1) (- depth 1) start acc))
            ((and (char=? (string-ref str i) #\,) (zero? depth))
             (loop (+ i 1) depth (+ i 1) (cons (trim (substring str start i)) acc)))
            (else (loop (+ i 1) depth start acc)))))

  (define (join-with-space parts)
    (let loop ((ps parts) (acc ""))
      (if (null? ps)
          acc
          (loop (cdr ps) (if (string=? acc "")
                             (car ps)
                             (string-append acc " " (car ps)))))))

  (define (substring? needle hay)
    (let ((n (string-length needle)) (h (string-length hay)))
      (let loop ((i 0))
        (cond ((> (+ i n) h) #f)
              ((string=? needle (substring hay i (+ i n))) #t)
              (else (loop (+ i 1)))))))

  (define (prefix? p s)
    (and (>= (string-length s) (string-length p))
         (string=? p (substring s 0 (string-length p)))))

  (define (suffix? p s)
    (and (>= (string-length s) (string-length p))
         (string=? p (substring s (- (string-length s) (string-length p))
                                (string-length s)))))

  (define (hex->integer s)
    (and (> (string-length s) 0)
         (let ((v (string->number s 16)))
           (and (integer? v) v))))

  (define (read-lines path)
    (call-with-input-file path
      (lambda (p)
        (let loop ((acc '()))
          (let ((l (get-line p)))
            (if (eof-object? l) (reverse acc) (loop (cons l acc))))))))

  ;; --- the model ------------------------------------------------------------

  (define-record-type (insn make-insn insn?)
    (fields address mnemonic operands function bytes text))

  (define-record-type (disasm make-disasm disasm?)
    (fields target insns))

  (define (disasm-function-names d)
    (let loop ((is (disasm-insns d)) (acc '()))
      (cond ((null? is) (reverse acc))
            ((member (insn-function (car is)) acc) (loop (cdr is) acc))
            (else (loop (cdr is) (cons (insn-function (car is)) acc))))))

  (define (function-insns d name)
    (let ((n (if (symbol? name) (symbol->string name) name)))
      (let ((r (filter (lambda (i) (string=? (insn-function i) n)) (disasm-insns d))))
        (when (null? r)
          (error 'function-insns
                 "the disassembly contains no such function; an assertion about a function that is not there is vacuous"
                 n (disasm-function-names d)))
        r)))

  (define (function-mnemonics d name)
    (map (lambda (i) (string->symbol (insn-mnemonic i))) (function-insns d name)))

  ;; --- parsing objdump ------------------------------------------------------
  ;;
  ;; A header line is `0000000000000000 <name>:`. A RISC-V object carries local
  ;; labels (`<.L4>`) in its symbol table and objdump prints a header for each,
  ;; which would split one function into five. A name beginning with `.` is
  ;; treated as a continuation of the function it sits inside, which is what it
  ;; is. Anything else starts a new function, including gcc's `<f.cold>` split,
  ;; which is genuinely a different piece of code.

  (define (header-name line)
    (let ((fs (whitespace-split line)))
      (and (= (length fs) 2)
           (hex->integer (car fs))
           (let ((s (cadr fs)))
             (and (> (string-length s) 3)
                  (char=? (string-ref s 0) #\<)
                  (suffix? ">:" s)
                  (substring s 1 (- (string-length s) 2)))))))

  ;; An instruction line is tab-separated: `   20:\t48 39 c2\tcmp    %rax,%rdx`.
  ;; A raw-bytes continuation line has only two fields and no text, and dropping
  ;; it is correct: the instruction it belongs to was already recorded.
  (define (parse-lines target lines)
    (let loop ((ls lines) (fn "") (acc '()))
      (cond
       ((null? ls) (make-disasm target (reverse acc)))
       (else
        (let* ((line (car ls))
               (h (header-name line)))
          (cond
           (h (loop (cdr ls) (if (prefix? "." h) fn h) acc))
           (else
            (let ((fs (split-char line #\tab)))
              (if (< (length fs) 3)
                  (loop (cdr ls) fn acc)
                  (let* ((a (trim (car fs)))
                         (addr (and (suffix? ":" a)
                                    (hex->integer (substring a 0 (- (string-length a) 1))))))
                    (if (not addr)
                        (loop (cdr ls) fn acc)
                        ;; Field 3 onward is the instruction. x86-64 objdump
                        ;; separates the mnemonic from its operands with spaces
                        ;; and RISC-V objdump with another tab, so the tail is
                        ;; rejoined rather than assumed to be one field.
                        (let* ((text (trim (join-with-space (cddr fs))))
                               ;; objdump appends `# 35 <f+0x35>` comments on
                               ;; PC-relative operands; keep them out of the
                               ;; operand text so operand splitting is clean.
                               (text (let ((p (split-char text #\#)))
                                       (trim (car p))))
                               (toks (whitespace-split text))
                               (mn (if (null? toks) "" (car toks)))
                               (ops (if (null? toks)
                                        ""
                                        (trim (substring text (string-length mn)
                                                         (string-length text))))))
                          (loop (cdr ls) fn
                                (cons (make-insn addr mn ops fn (trim (cadr fs)) text)
                                      acc))))))))))))))

  (define (disassemble-file target path)
    (unless (objdump-available? target)
      (error 'disassemble-file
             "objdump for this target is missing, and an independent reading of the emitted code is the whole acceptance for this bead"
             target (objdump-for target)))
    (let ((out (scratch-path ".dis")))
      (unless (zero? (system (string-append (objdump-for target) " "
                                            (objdump-flags target) " " path
                                            " > " out " 2>/dev/null")))
        (error 'disassemble-file "objdump refused the object" path))
      (parse-lines target (read-lines out))))

  (define (disassemble-elf target bv)
    (let ((p (scratch-path ".o")))
      (write-bytevector-to-file bv p)
      (disassemble-file target p)))

  (define (disassemble-object fo)
    (disassemble-elf (function-object-target fo) (function-object-elf fo)))

  ;; --- branches -------------------------------------------------------------

  (define x86-uncond '("jmp" "jmpq" "jmpl"))

  (define (conditional-branch? d i)
    (let ((m (insn-mnemonic i)))
      (case (disasm-target d)
        ;; Every x86-64 conditional branch is `j<cc>`; `jmp` is the only `j`
        ;; that is not one, and `loop*` is the historical exception.
        ((x86-64) (or (and (> (string-length m) 1)
                           (char=? (string-ref m 0) #\j)
                           (not (member m x86-uncond)))
                      (prefix? "loop" m)))
        ;; Every RV64 branch mnemonic begins with `b`, compressed or not, and
        ;; nothing else in the base ISA does.
        ((rv64) (or (prefix? "b" m) (prefix? "c.b" m)))
        (else #f))))

  (define (unconditional-branch? d i)
    (let ((m (insn-mnemonic i)))
      (case (disasm-target d)
        ((x86-64) (and (member m x86-uncond) #t))
        ((rv64) (and (member m '("jal" "jalr" "c.j" "c.jr" "c.jalr" "c.jal")) #t))
        (else #f))))

  ;; The target address, as objdump resolved it. x86-64 prints it as the sole
  ;; operand; RV64 prints it last after the compared registers. Taking the last
  ;; operand and reading its leading token as hex covers both, and returns #f
  ;; for a register-indirect branch, which has no static target.
  (define (branch-target i)
    (let ((ops (split-operands (insn-operands i))))
      (and (pair? ops)
           (let ((toks (whitespace-split (car (reverse ops)))))
             (and (pair? toks) (hex->integer (car toks)))))))

  ;; --- loops ----------------------------------------------------------------

  (define-record-type (loop make-loop loop?)
    (fields head latch insns))

  ;; A backward conditional branch is a loop latch and its target is the head.
  ;; That is the whole loop finder, and it is enough: it recognizes the rotated
  ;; counted loop every optimizing compiler emits, which is the shape milestone
  ;; 2 is about. It does not recognize an irreducible loop, and it should not
  ;; pretend to.
  (define (function-loops d name)
    (let* ((is (function-insns d name))
           (lo (insn-address (car is)))
           (hi (insn-address (car (reverse is)))))
      (let loop ((xs is) (acc '()))
        (cond
         ((null? xs) (reverse acc))
         (else
          (let* ((i (car xs)) (t (branch-target i)))
            (if (and (conditional-branch? d i) t
                     (<= t (insn-address i)) (>= t lo) (<= t hi))
                (loop (cdr xs)
                      (cons (make-loop t (insn-address i)
                                       (filter (lambda (j)
                                                 (and (>= (insn-address j) t)
                                                      (<= (insn-address j) (insn-address i))))
                                               is))
                            acc))
                (loop (cdr xs) acc))))))))

  ;; The innermost loop is the one whose head is latest: a nested loop's inner
  ;; header always follows its outer one. Ties go to the shortest body, which is
  ;; the same rule stated from the other end.
  (define (inner-loop d name)
    (let ((ls (function-loops d name)))
      (when (null? ls)
        (error 'inner-loop
               "this function has no loop, so every statement about its inner loop is vacuous"
               name))
      (let pick ((xs (cdr ls)) (best (car ls)))
        (cond ((null? xs) best)
              ((or (> (loop-head (car xs)) (loop-head best))
                   (and (= (loop-head (car xs)) (loop-head best))
                        (< (loop-latch (car xs)) (loop-latch best))))
               (pick (cdr xs) (car xs)))
              (else (pick (cdr xs) best))))))

  ;; --- milestone 2: no bounds-check branch in the inner loop ----------------

  ;; Every conditional branch in the body except the latch itself. In a rotated
  ;; counted loop there are none, and each one that is there is a test the
  ;; iteration did not require.
  (define (bounds-check-branches d name)
    (let ((l (inner-loop d name)))
      (filter (lambda (i)
                (and (conditional-branch? d i)
                     (not (= (insn-address i) (loop-latch l)))))
              (loop-insns l))))

  ;; The stronger reading, for a LINKED image where displacements are real: a
  ;; branch whose target leaves the body. On a relocatable object gcc leaves the
  ;; displacement to the trap section at zero, so this under-reports and
  ;; `bounds-check-branches` is the one to assert on.
  (define (loop-exit-branches d name)
    (let ((l (inner-loop d name)))
      (filter (lambda (i)
                (and (conditional-branch? d i)
                     (not (= (insn-address i) (loop-latch l)))
                     (let ((t (branch-target i)))
                       (or (not t) (< t (loop-head l)) (> t (loop-latch l))))))
              (loop-insns l))))

  (define (no-bounds-check? d name) (null? (bounds-check-branches d name)))

  ;; --- stage 10: packed arithmetic ------------------------------------------

  ;; x86-64: an SSE/AVX arithmetic stem with a packed-double or packed-single
  ;; suffix. The 132/213/231 in `vfmadd231pd` selects which operand is the
  ;; addend and is not a semantic difference, so the whole family counts; gcc
  ;; 15.2 picks 132 for `d[i] + a[i]*b[i]` where the bead's prose names 231.
  (define x86-packed-stems
    '("add" "sub" "mul" "div" "sqrt" "max" "min" "hadd" "hsub" "rcp" "rsqrt"
      "fmadd132" "fmadd213" "fmadd231" "fnmadd132" "fnmadd213" "fnmadd231"
      "fmsub132" "fmsub213" "fmsub231" "fnmsub132" "fnmsub213" "fnmsub231"
      "fmaddsub132" "fmaddsub213" "fmaddsub231"
      "fmsubadd132" "fmsubadd213" "fmsubadd231"))

  ;; RVV: an arithmetic stem with a vector-vector, vector-scalar, vector-float
  ;; or vector-reduction suffix. `vsetvli` and `vle64.v` are vector but not
  ;; arithmetic, and counting them would let a program that merely LOADS
  ;; vectors claim it vectorized.
  (define rv-packed-stems
    '("vadd" "vsub" "vmul" "vdiv" "vmacc" "vmadd" "vnmsac"
      "vfadd" "vfsub" "vfmul" "vfdiv" "vfsqrt" "vfmacc" "vfmadd" "vfnmacc"
      "vfnmsac" "vfmsac" "vfmsub" "vfnmadd" "vfnmsub" "vfmin" "vfmax"
      "vfredusum" "vfredosum" "vredsum"))

  (define rv-packed-suffixes '(".vv" ".vx" ".vf" ".vs" ".vi" ".v"))

  (define (x86-packed? m)
    (let* ((body (if (prefix? "v" m) (substring m 1 (string-length m)) m)))
      (and (or (suffix? "pd" body) (suffix? "ps" body))
           (let ((stem (substring body 0 (- (string-length body) 2))))
             (and (member stem x86-packed-stems) #t)))))

  (define (rv-packed? m)
    (let loop ((ss rv-packed-suffixes))
      (cond ((null? ss) #f)
            ((and (suffix? (car ss) m)
                  (member (substring m 0 (- (string-length m) (string-length (car ss))))
                          rv-packed-stems))
             #t)
            (else (loop (cdr ss))))))

  (define (vector-register-width i)
    (let ((ops (insn-operands i)))
      (cond ((substring? "%zmm" ops) 'zmm)
            ((substring? "%ymm" ops) 'ymm)
            ((substring? "%xmm" ops) 'xmm)
            (else 'v))))

  ;; -> the packed arithmetic instructions in the named function. `width` is
  ;; `any`, or one of zmm/ymm/xmm for x86-64, and filters on the register file
  ;; the instruction names, so a test can assert AVX-512 rather than merely SIMD.
  (define packed-arithmetic-insns
    (case-lambda
      ((d name) (packed-arithmetic-insns d name 'any))
      ((d name width)
       (filter (lambda (i)
                 (and (case (disasm-target d)
                        ((x86-64) (x86-packed? (insn-mnemonic i)))
                        ((rv64)   (rv-packed? (insn-mnemonic i)))
                        (else #f))
                      (or (eq? width 'any)
                          (eq? width (vector-register-width i)))))
               (function-insns d name)))))

  (define has-packed-arithmetic?
    (case-lambda
      ((d name) (pair? (packed-arithmetic-insns d name)))
      ((d name width) (pair? (packed-arithmetic-insns d name width)))))

  ;; --- D21: poll-free, wired to a real reading ------------------------------

  ;; How far a conditional branch may sit from the load whose value it tests.
  ;; gcc 15.2 puts `test` between them on x86-64 and nothing between them on
  ;; RV64, so two would do; three is the over-broad margin preempt.ss asks for.
  (define poll-window (make-parameter 3))

  (define x86-non-memory '("lea" "nop" "nopw" "nopl" "endbr64" "push" "pop"
                           "call" "ret" "leave"))

  (define (x86-float-or-vector? i)
    (let ((m (insn-mnemonic i)) (ops (insn-operands i)))
      (or (substring? "%xmm" ops) (substring? "%ymm" ops) (substring? "%zmm" ops)
          (substring? "%st" ops)
          (suffix? "sd" m) (suffix? "ss" m) (suffix? "pd" m) (suffix? "ps" m))))

  ;; A memory operand in AT&T syntax is a parenthesised base, optionally with a
  ;; scaled index: `(%rip)`, `0x8(%rsp)`, `(%rdi,%rax,8)`. A comma inside the
  ;; parentheses means an index register, which means the address moves with the
  ;; loop, which means it is the data stream and not a suspend word.
  (define (x86-nonindexed-memory-source? i)
    (let ((ops (split-operands (insn-operands i))))
      (and (pair? ops)
           (let ((src (car ops)))
             (and (substring? "(" src)
                  (not (substring? "," src)))))))

  (define rv-integer-loads
    '("lb" "lh" "lw" "ld" "lbu" "lhu" "lwu"
      "c.lw" "c.ld" "c.lwsp" "c.ldsp"))

  (define (scalar-integer-load? d i)
    (case (disasm-target d)
      ((x86-64) (and (not (member (insn-mnemonic i) x86-non-memory))
                     (not (x86-float-or-vector? i))
                     (x86-nonindexed-memory-source? i)))
      ((rv64) (and (member (insn-mnemonic i) rv-integer-loads) #t))
      (else #f)))

  (define (memory-read? d i)
    (case (disasm-target d)
      ((x86-64) (and (not (member (insn-mnemonic i) x86-non-memory))
                     (substring? "(" (insn-operands i))))
      ((rv64) (or (member (insn-mnemonic i) rv-integer-loads)
                  (member (insn-mnemonic i) '("flw" "fld" "c.flw" "c.fld"
                                              "c.flwsp" "c.fldsp"))))
      (else #f)))

  ;; -> the (load . branch) pairs that look like a suspend-flag poll.
  (define (poll-sequences d name)
    (let* ((is (function-insns d name))
           (v (list->vector is))
           (n (vector-length v)))
      (let loop ((i 0) (acc '()))
        (cond
         ((= i n) (reverse acc))
         ((scalar-integer-load? d (vector-ref v i))
          (let scan ((j (+ i 1)))
            (cond
             ((or (= j n) (> (- j i) (poll-window))) (loop (+ i 1) acc))
             ((conditional-branch? d (vector-ref v j))
              (loop (+ i 1) (cons (cons (vector-ref v i) (vector-ref v j)) acc)))
             (else (scan (+ j 1))))))
         (else (loop (+ i 1) acc))))))

  ;; preempt.ss's own predicate over the mnemonics binutils actually printed,
  ;; AND the sequence recognizer, because no real ISA spells a poll `poll` and
  ;; the mnemonic half can therefore only ever catch our own pseudo-ops.
  (define (poll-free? d name)
    (and (preempt:poll-free? (function-mnemonics d name))
         (null? (poll-sequences d name))))

  ;; --- D24: evidence of FP contraction in emitted code ----------------------
  ;;
  ;; Not a milestone predicate. It is what sonic/src/sonic/differential.ss reads
  ;; to decide whether a bit-exact comparison is still the right one, because
  ;; the moment a fused multiply-add appears the two builds are permitted to
  ;; disagree in the low bits and a bit-exact diff would report an unsoundness
  ;; that is not there.

  (define (x86-fused? m)
    (let ((b (if (prefix? "v" m) (substring m 1 (string-length m)) m)))
      (or (prefix? "fmadd" b) (prefix? "fnmadd" b)
          (prefix? "fmsub" b) (prefix? "fnmsub" b)
          (prefix? "fmaddsub" b) (prefix? "fmsubadd" b))))

  (define (rv-fused? m)
    (or (member m '("fmadd.d" "fmsub.d" "fnmadd.d" "fnmsub.d"
                    "fmadd.s" "fmsub.s" "fnmadd.s" "fnmsub.s"))
        (prefix? "vfmacc" m) (prefix? "vfmadd" m)
        (prefix? "vfnmacc" m) (prefix? "vfnmsac" m)
        (prefix? "vfmsac" m) (prefix? "vfmsub" m)
        (prefix? "vfnmadd" m) (prefix? "vfnmsub" m)))

  (define (contraction-insns d name)
    (filter (lambda (i)
              (case (disasm-target d)
                ((x86-64) (x86-fused? (insn-mnemonic i)))
                ((rv64)   (rv-fused? (insn-mnemonic i)))
                (else #f)))
            (function-insns d name)))
  )
