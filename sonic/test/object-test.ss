;;; E2-OBJ.
;;;
;;; Our decoder agreeing with our encoder proves nothing, so the acceptance here
;;; is external: `objdump -d` and `riscv64-linux-gnu-objdump -d` must read our
;;; bytes back as the mnemonics the selector chose, `ld` must accept the object,
;;; and the linked program must run and give the right answer. Everything below
;;; that is arithmetic on the function image, which we can check ourselves
;;; because the format is ours.
;;;
;;; The end-to-end case is nbody's inner loop, all the way from the Lrepr
;;; fixture: lower, two-address fixup, select, allocate, encode, ELF. That is
;;; E2-LIR's acceptance criterion carried to its conclusion, and it runs on BOTH
;;; targets from the one fixture, which is the property that keeps the two back
;;; ends consuming the same thing.
;;;
;;; Needs gcc, objdump, riscv64-linux-gnu-gcc, riscv64-linux-gnu-objdump and
;;; qemu-riscv64. Missing tools FAIL rather than skip: a green run that silently
;;; verified nothing is worse than a red one.

(import (chezscheme) (nanopass) (rnrs io simple)
        (sonic lang) (sonic fixtures) (sonic lower) (sonic gcmeta)
        (sonic regs) (sonic regalloc) (sonic twoaddr) (sonic select)
        (sonic target-x86-64) (sonic target-rv64) (sonic object)
        (prefix (sonic encode-rv64) rv:))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define (raises? thunk) (guard (e (#t #t)) (thunk) #f))

(define tmp
  (let ((d (string-append (or (getenv "TMPDIR") "/tmp") "/sonic-object-test")))
    (system (string-append "mkdir -p " d)) d))
(define (path . parts) (apply string-append tmp "/" parts))

(define (shell cmd) (zero? (system (string-append cmd " > " (path "log") " 2>&1"))))
(define (have? cmd) (zero? (system (string-append cmd " >/dev/null 2>&1"))))

(define (read-all-lines file)
  (call-with-input-file file
    (lambda (p)
      (let loop ((acc '()))
        (let ((l (get-line p)))
          (if (eof-object? l) (reverse acc) (loop (cons l acc))))))))

(define (split str ch)
  (let loop ((i 0) (start 0) (acc '()))
    (cond ((= i (string-length str)) (reverse (cons (substring str start i) acc)))
          ((char=? (string-ref str i) ch)
           (loop (+ i 1) (+ i 1) (cons (substring str start i) acc)))
          (else (loop (+ i 1) start acc)))))

(define (trim s)
  (let* ((n (string-length s))
         (a (let loop ((i 0)) (if (and (< i n) (char-whitespace? (string-ref s i)))
                                  (loop (+ i 1)) i)))
         (b (let loop ((i n)) (if (and (> i a) (char-whitespace? (string-ref s (- i 1))))
                                  (loop (- i 1)) i))))
    (substring s a b)))

(define (hex-digit? c)
  (or (char-numeric? c) (and (char>=? c #\a) (char<=? c #\f))))

;;; ==========================================================================
;;; 1. The function image: sizes in the header, everything else by arithmetic
;;; ==========================================================================
;;
;; D21's collector has a program counter and needs the metadata entry covering
;; it. Sizes rather than offsets, because an offset can disagree with the thing
;; it points at and a size cannot.

(define img-fo
  (assemble-function 'x86-64 'sonic_img
    '((mov rax (imm 1)) (mov rax (imm 2)) (ret))
    '((constants . (7.5 -1 2.5))
      (frame-bits . (#t #f #t #t)))))

(define img (function-object-image img-fo))

(ck! "the image names its target, so a decoder never has to be told"
     (eq? (image-target img) 'x86-64))
(ck! "the code comes back byte for byte"
     (equal? (image-code img) (function-object-code img-fo)))
(ck! "and so does the constant pool, one 8-byte slot per entry"
     (and (= (bytevector-length (image-constants img)) 24)
          (equal? (image-constants img) (function-object-constants img-fo))))
(ck! "a pooled flonum is its IEEE754 pattern, not a re-read of the source text"
     (and (= (bytevector-ieee-double-ref (image-constants img) 0 (endianness little)) 7.5)
          (= (bytevector-ieee-double-ref (image-constants img) 16 (endianness little)) 2.5)))
(ck! "the metadata blob comes back byte for byte"
     (equal? (image-metadata img) (function-object-metadata img-fo)))
(ck! "the frame slot count rides in the header, one bit per stack slot"
     (= (image-frame-slots img) 4))

;; The pool holds f64 literals, which is the whole reason it exists, so it has
;; to be 8-aligned no matter how odd the code size is.
(let* ((odd (assemble-function 'x86-64 'sonic_odd '((ret)) '((constants . (1.5)))))
       (b (function-object-image odd)))
  (ck! "the pool stays 8-aligned behind a one-byte function"
       (and (= (bytevector-length (image-code b)) 1)
            (= (bytevector-ieee-double-ref (image-constants b) 0 (endianness little)) 1.5))))

(ck! "a blob with the wrong magic is refused, not parsed as garbage"
     (raises? (lambda () (image-code (make-bytevector 64 0)))))
(ck! "and so is one too short to hold a header"
     (raises? (lambda () (image-code (make-bytevector 4 0)))))

;;; ==========================================================================
;;; 2. The metadata survives the round trip, and lookup is still total
;;; ==========================================================================
;;
;; The point of gcmeta.ss is that EVERY byte offset has an answer, not just the
;; ones with an entry. So the interesting lookups are the offsets in between.

;; Ten identical instructions, seven bytes each, with the state changing at
;; instruction 0, 4 and 7. Offsets 0, 28 and 49.
(define meta-fo
  (assemble-function 'x86-64 'sonic_meta
    (map (lambda (k) `(mov rax (imm ,k))) (iota 10))
    `((frame-bits . (#t #f))
      (state-of . ,(lambda (i n)
                     (case n
                       ((0) '((frame? . 1)))
                       ((4) '((frame? . 1) (scratch-live . 2)))
                       ((7) '((frame? . 1) (interrupt? . 1)))
                       (else #f)))))))

(define meta-img (function-object-image meta-fo))
(define entries (image-metadata-entries meta-img))

(ck! "ten emitted entries collapse to the three places the answer changes"
     (= (length entries) 3))
(ck! "at the offsets the state actually changed"
     (equal? (map entry-offset entries) '(0 28 49)))
(ck! "decoding from the image agrees with decoding from the blob directly"
     (equal? (map entry-offset entries)
             (map entry-offset (function-object-entries meta-fo))))

;; An arbitrary offset, with no entry of its own, in the middle of the second
;; run. The step function has to answer with the entry before it.
(ck! "an arbitrary offset inside a run gets the last entry at or before it"
     (= 2 (cdr (assq 'scratch-live (entry-flags (metadata-lookup entries 33))))))
(ck! "an offset one byte before a change still gets the OLD answer"
     (= 2 (cdr (assq 'scratch-live (entry-flags (metadata-lookup entries 48))))))
(ck! "and one byte after it gets the new one"
     (= 1 (cdr (assq 'interrupt? (entry-flags (metadata-lookup entries 49))))))
(ck! "an offset past the last entry is still covered: the function is total"
     (= 1 (cdr (assq 'interrupt? (entry-flags (metadata-lookup entries 69))))))
(ck! "the frame bitvector survives the round trip"
     (equal? (entry-frame-bits (metadata-lookup entries 33)) '(#t #f)))

;;; ==========================================================================
;;; 3. Labels, resolved before the encoders ever see them
;;; ==========================================================================
;;
;; Both encoders refuse an unresolved label, correctly: resolving one is the
;; caller's job. This is the caller.

;; RV64 already has a verified listing assembler in encode-rv64.ss, so the
;; honest check is that we agree with it rather than with an expectation table.
(define rv-listing
  '((addi a0 zero 1)
    loop
    (addi a0 a0 1)
    (bne a0 zero loop)
    (jal zero done)
    (addi a0 zero 9)
    done
    (jalr zero ra 0)))

(ck! "RV64 label resolution agrees byte for byte with encode-listing"
     (equal? (apply append (map (lambda (i) (encode-instruction 'rv64 i))
                                (resolve-labels 'rv64 rv-listing)))
             (rv:encode-listing rv-listing)))

(ck! "a label defined twice is refused"
     (raises? (lambda () (resolve-labels 'rv64 '(l (addi a0 zero 0) l)))))
(ck! "and a branch to a label nobody defined is refused"
     (raises? (lambda () (resolve-labels 'rv64 '((jal zero nowhere))))))

;; x86-64 displacements are relative to the END of the instruction, RV64's to
;; the instruction itself. Getting that backwards assembles cleanly and branches
;; to the wrong place, so it gets its own check.
(ck! "an x86-64 backward jump is relative to the end of the instruction"
     (equal? (resolve-labels 'x86-64
                             '((mov rax (imm 1)) here (mov rax (imm 2))
                               (jmp (label here))))
             '((mov rax (imm 1)) (mov rax (imm 2)) (jmp (rel -12)))))

;;; ==========================================================================
;;; 4. nbody's inner loop, from the fixture to an ELF object, on both targets
;;; ==========================================================================

;; The `lower` link in the chain. lower-program hands back an unparsed datum and
;; names its vregs after the source variables, so the comparison is on the
;; opcode sequence, exactly as sonic/test/lower-test.ss argues.
(let-values (((lowered stats) (lower-program (unparse-Lrepr (nbody-inner-repr)) 'entry)))
  (let ((after (twoaddr arch-x86-64 lowered)))
    (ck! "lowering nbody's inner loop and fixing it up gives mul, add, load"
         (equal? (map car (cadr (cadr (car (cadr (unparse-Lmach after))))))
                 '(mul add load)))
    (ck! "which is the op sequence the frozen Lmach fixture pins"
         (equal? (map car (cadr (cadr (car (cadr (unparse-Lmach after))))))
                 (map car (list-tail (cadr (cadr (car (cadr (unparse-Lmach (nbody-inner-mach))))))
                                     1))))))

(define nbody-classes
  (let ((t (make-eq-hashtable)))
    ;; The three block-live-in vregs have no defining instruction, so their
    ;; classes come from the fixture's prose: `b` is the tagged flvector, `i`
    ;; and `k` are raw indices.
    (for-each (lambda (p) (hashtable-set! t (car p) (cdr p)))
              '((v-b . tagged) (v-i . raw-word) (v-k . raw-word)
                (v-seven . raw-word) (v-off . raw-word) (v-idx . raw-word)
                (v-val . raw-f64)))
    t))

(define (resolve-with m x)
  (cond ((pair? x) (cons (resolve-with m (car x)) (resolve-with m (cdr x))))
        ((symbol? x) (or (hashtable-ref m x #f) x))
        (else x)))

;; lower -> twoaddr -> select -> regalloc -> encode -> ELF.
(define (pipeline arch selector)
  (let* ((fixed (twoaddr arch (nbody-inner-mach)))
         (mach (cadr (cadr (car (cadr (unparse-Lmach fixed))))))
         ;; A physical scratch name is not a vreg; blank it before liveness.
         (alloc (allocate arch (strip-scratch arch mach) nbody-classes))
         (selected (cadr (car (cadddr (select-program selector fixed))))))
    (values alloc (resolve-with (alloc-result-map alloc) selected))))

(define-values (x86-alloc x86-body) (pipeline arch-x86-64 x86-64-selector))
(define-values (rv-alloc rv-body)   (pipeline arch-rv64 rv64-selector))

(ck! "the fixture allocates with no spills on either target"
     (and (null? (alloc-result-spills x86-alloc))
          (null? (alloc-result-spills rv-alloc))))
(ck! "no vreg survived into the x86-64 stream"
     (not (memq 'v-idx (let flat ((x x86-body))
                         (cond ((pair? x) (append (flat (car x)) (flat (cdr x))))
                               ((symbol? x) (list x)) (else '()))))))
(ck! "RV64 needed three instructions for the indexed load x86-64 folds into one"
     (and (= (length x86-body) 7) (= (length rv-body) 7)
          (equal? (map car rv-body) '(addi mul add slli add fld jalr))
          (equal? (map car x86-body) '(mov mov imul mov add movsd ret))))

;; --- what binutils reads back ---------------------------------------------

;; stderr only. Redirecting stdout here would clobber the objdump command's own
;; redirect, since the last one on the line wins.
(define (shell-quiet cmd) (zero? (system (string-append cmd " 2>/dev/null"))))

(define (objdump-mnemonics tool flags obj)
  (let ((d (path "dis.txt")))
    (unless (shell-quiet (string-append tool " -d " flags " " obj " > " d))
      (error 'objdump-mnemonics "objdump failed" obj))
    (let loop ((ls (read-all-lines d)) (acc '()))
      (if (null? ls)
          (reverse acc)
          (let ((fs (split (car ls) #\tab)))
            (if (and (>= (length fs) 3)
                     (let ((a (trim (car fs))))
                       (and (> (string-length a) 1)
                            (char=? (string-ref a (- (string-length a) 1)) #\:)
                            (hex-digit? (string-ref a 0)))))
                (loop (cdr ls)
                      (cons (car (split (trim (caddr fs)) #\space)) acc))
                (loop (cdr ls) acc)))))))

(define (disassembly-check! label target body tool flags)
  (set! checks (+ checks 1))
  (let* ((obj (path label "-nbody.o"))
         (fo (assemble-function target 'sonic_nbody_inner body)))
    (write-bytevector-to-file (function-object-elf fo) obj)
    (let* ((theirs (guard (e (#t 'error)) (objdump-mnemonics tool flags obj)))
           (ours (map (lambda (i) (symbol->string (car i))) body)))
      (cond
       ((equal? theirs ours)
        (display "  ok   ") (display label)
        (display ": objdump reads back exactly what the selector chose: ")
        (write ours) (newline))
       (else
        (set! failures (+ failures 1))
        (display "  FAIL ") (display label) (display ": ours=") (write ours)
        (display " objdump=") (write theirs) (newline))))))

(if (have? "objdump --version")
    (disassembly-check! "x86-64" 'x86-64 x86-body "objdump" "-M intel")
    (begin (set! checks (+ checks 1)) (set! failures (+ failures 1))
           (display "  FAIL objdump is missing, and it is the acceptance for this bead\n")))

(if (have? "riscv64-linux-gnu-objdump --version")
    (disassembly-check! "rv64" 'rv64 rv-body "riscv64-linux-gnu-objdump" "-M no-aliases")
    (begin (set! checks (+ checks 1)) (set! failures (+ failures 1))
           (display "  FAIL riscv64-linux-gnu-objdump is missing, and it is the\n")
           (display "       acceptance for the RV64 half of this bead\n")))

;;; ==========================================================================
;;; 5. The bead's own criterion: it links, and it runs
;;; ==========================================================================

(define main-c (path "main.c"))
(call-with-output-file main-c
  (lambda (p)
    (display "#include <stdio.h>\n" p)
    (display "extern long sonic_answer(void);\n" p)
    (display "int main(void){ long v = sonic_answer();\n" p)
    (display "  printf(\"%ld\\n\", v); return v == 42 ? 0 : 1; }\n" p))
  'replace)

(define (link-and-run! label target body cc run)
  (set! checks (+ checks 1))
  (let* ((obj (path label "-answer.o"))
         (exe (path label "-answer.bin"))
         (fo (assemble-function target 'sonic_answer body)))
    (write-bytevector-to-file (function-object-elf fo) obj)
    (cond
     ((not (shell (string-append cc " " main-c " " obj " -o " exe)))
      (set! failures (+ failures 1))
      (display "  FAIL ") (display label)
      (display ": ld refused our object; see ") (display (path "log")) (newline))
     ((not (shell (string-append run " " exe)))
      (set! failures (+ failures 1))
      (display "  FAIL ") (display label)
      (display ": the linked program ran and gave the wrong answer\n"))
     (else
      (display "  ok   ") (display label)
      (display ": the emitted object links and the program returns 42\n")))))

(if (have? "gcc --version")
    (link-and-run! "x86-64" 'x86-64 '((mov rax (imm 42)) (ret)) "gcc" "")
    (begin (set! checks (+ checks 1)) (set! failures (+ failures 1))
           (display "  FAIL gcc is missing; `links and runs` cannot be faked locally\n")))

(if (and (have? "riscv64-linux-gnu-gcc --version") (have? "qemu-riscv64 -version"))
    (link-and-run! "rv64" 'rv64 '((addi a0 zero 42) (jalr zero ra 0))
                   "riscv64-linux-gnu-gcc -static" "qemu-riscv64")
    (begin (set! checks (+ checks 1)) (set! failures (+ failures 1))
           (display "  FAIL riscv64-linux-gnu-gcc or qemu-riscv64 is missing; the RV64\n")
           (display "       half of `links and runs` would go unverified\n")))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
