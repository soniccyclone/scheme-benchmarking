;;; The runtime, as instruction listings.
;;;
;;; D25 says the runtime is Scheme and there is no libc in the running system.
;;; This is the part that cannot be Scheme: the entry point the kernel jumps to,
;;; the syscalls, and the allocator's raw pointer arithmetic. It is small on
;;; purpose -- straight-line code that discovers nothing -- and everything else
;;; that grows later should be written in SonicScheme and compiled.
;;;
;;; It is expressed as instruction listings rather than as a hand-assembled byte
;;; string, so every instruction in it goes through the same encoder as compiled
;;; code and is covered by the same differential test against gas. A runtime
;;; assembled by hand is exactly where a wrong REX prefix would hide.
;;;
;;; ## What nbody actually needs
;;;
;;; Less than it looks. The program reads
;;;
;;;   (let* ((args (command-line))
;;;          (n (if (fx> (length args) 1) (string->number (cadr args)) 1000)))
;;;
;;; so a `command-line` that returns the empty list and a `length` that returns
;;; 1 take the default branch and N is 1000 -- which is the case the oracle in
;;; docs/METHOD.md publishes values for. `cadr` and `string->number` are on the
;;; dead branch. They still need to EXIST, because a label the code references
;;; must resolve, but they trap: a runtime routine that is unreachable and a
;;; runtime routine that silently returns garbage look identical until the day
;;; the branch is taken.
;;;
;;; ## Output is raw IEEE bytes, not decimals
;;;
;;; `display` writes the double's eight bytes to fd 1 and `newline` writes
;;; nothing. This is deliberate and it is STRONGER than printing nine decimals:
;;; the oracle compares the computed value, and eight bytes compare it exactly,
;;; where a decimal conversion inserts our own formatter between the answer and
;;; the check. Correctly-rounded shortest-representation printing is a real
;;; piece of work (Steele & White, then Ryu) and it belongs to whoever needs
;;; human-readable output, not to the oracle.
;;;
;;; ## No collector
;;;
;;; The allocator is a bump pointer and nothing reclaims. nbody allocates three
;;; flvectors at startup and never again, so a collector would never run; adding
;;; one here to look complete would be untested code on the critical path. gc.ss
;;; and alloc.ss own that, and the metadata D21 needs is already emitted.

(library (sonic runtime)
  (export runtime-listing runtime-labels
          heap-base-address heap-size
          runtime-data-size
          heap-pointer-cell out-buffer-cell
          globals-base globals-span assign-global-cells)
  (import (chezscheme)
          (sonic numeric))

  ;; --- the data segment -----------------------------------------------------
  ;;
  ;; Fixed absolute addresses rather than RIP-relative, because these are the
  ;; runtime's own cells and the image is a static executable at a known load
  ;; address. An absolute disp32 is one instruction and needs no relocation.

  (define data-base      #x600000)
  (define heap-pointer-cell data-base)              ; 8 bytes: the bump pointer
  (define out-buffer-cell   (+ data-base 8))        ; 8 bytes: one double
  ;; The top-level bindings' cells sit between the runtime's own words and the
  ;; heap. Reserving a fixed span rather than sizing it to the program keeps the
  ;; heap's base a constant, which the entry code stores without arithmetic.
  (define globals-base      (+ data-base 64))
  (define globals-span      1024)                   ; 128 cells
  (define heap-base-address (+ globals-base globals-span))
  (define heap-size      (* 1 1024 1024))
  (define runtime-data-size (+ 64 globals-span heap-size))

  ;; cell name -> absolute address, in the order the program declares them.
  (define (assign-global-cells names)
    (let ((tbl (make-eq-hashtable)))
      (let loop ((ns names) (at globals-base))
        (cond
         ((null? ns) tbl)
         ((>= (- at globals-base) globals-span)
          (error 'assign-global-cells
                 "more top-level bindings than the reserved span holds"
                 (length names) globals-span))
         (else (hashtable-set! tbl (car ns) at)
               (loop (cdr ns) (+ at 8)))))))

  ;; Linux x86-64 syscall numbers.
  (define sys-write 1)
  (define sys-exit  60)

  ;; Exit codes, one per trap, so a failure names itself in $?.
  (define exit-ok             0)
  (define exit-type-error     101)
  (define exit-bounds-error   102)
  (define exit-overflow-error 103)
  (define exit-unimplemented  104)

  (define (abs-mem addr) `(mem #f #f 1 ,addr))

  ;; --- x86-64 ---------------------------------------------------------------
  ;;
  ;; The calling convention is callconv.ss's, and this file must agree with it:
  ;;   raw-word arguments   rcx rdx rsi rdi
  ;;   tagged arguments     r8 r9 r10 r11
  ;;   raw-f64 arguments    xmm0 ...
  ;;   returns              rax, or xmm0 for a double
  ;;   r15                  nil
  (define (x86-64-listing entry)
    `(;; ---- entry ----
      ;;
      ;; The kernel enters here with argc at [rsp]. Nothing reads it: see the
      ;; header on why `command-line` returns the empty list.
      _start
      (mov r15 (imm ,sonic-null))
      (mov rax (imm ,heap-base-address))
      (mov ,(abs-mem heap-pointer-cell) rax)
      (call (label ,entry))
      (mov rdi (imm ,exit-ok))
      (mov rax (imm ,sys-exit))
      (syscall)

      ;; ---- (make-flvector count fill) ----
      ;; count in rcx (raw-word arg 0), fill in xmm0. Returns a tagged pointer.
      ;;
      ;; Layout is D29's: type word, length, then the elements, with the pointer
      ;; aimed at element zero and carrying the heap tag.
      %make-flvector
      (mov rax ,(abs-mem heap-pointer-cell))     ; rax = raw base
      (mov rdx (imm ,heap-type-flvector))
      (mov (mem rax #f 1 0) rdx)                 ; [raw+0] = type
      (mov (mem rax #f 1 8) rcx)                 ; [raw+8] = length, a raw count
      ;; bump: heap_ptr = raw + 16 + 8*count
      (mov rsi rcx)
      (shl rsi (imm 3))
      (add rsi (imm ,heap-header-bytes))
      (add rsi rax)
      (mov ,(abs-mem heap-pointer-cell) rsi)
      ;; fill the elements
      (lea rdi (mem rax #f 1 ,heap-header-bytes))
      (mov rsi (imm 0))
      %mkfl-loop
      (cmp rsi rcx)
      (jge (label %mkfl-done))
      (movsd (mem rdi rsi 8 0) xmm0)
      (add rsi (imm 1))
      (jmp (label %mkfl-loop))
      %mkfl-done
      (add rax (imm ,(+ heap-header-bytes heap-tag)))
      (ret)

      ;; ---- (display x) ----
      ;; The double arrives in xmm0. Eight raw bytes to fd 1; see the header.
      display
      (movsd ,(abs-mem out-buffer-cell) xmm0)
      (mov rdi (imm 1))
      (mov rsi (imm ,out-buffer-cell))
      (mov rdx (imm 8))
      (mov rax (imm ,sys-write))
      (syscall)
      (mov rax r15)
      (ret)

      ;; A newline would corrupt a stream of raw doubles, so this writes
      ;; nothing. It returns nil, which is what an unspecified result is here.
      newline
      (mov rax r15)
      (ret)

      ;; ---- startup arguments ----
      ;; The empty list and a length of 1 together take nbody's default branch,
      ;; N = 1000, which is the case the oracle publishes values for.
      command-line
      (mov rax r15)
      (ret)

      length
      (mov rax (imm 1))
      (ret)

      ;; On the dead branch. They exist so the label resolves and they trap so
      ;; that taking the branch is loud rather than silently wrong.
      cadr
      string->number
      (mov rdi (imm ,exit-unimplemented))
      (mov rax (imm ,sys-exit))
      (syscall)

      ;; ---- traps ----
      ;; The traps write the value that failed before exiting. A trap that only
      ;; sets an exit code tells you WHICH check fired and nothing about why,
      ;; and "a type check failed somewhere" is not a debuggable statement.
      ;; rax holds the masked tag at the point the check branches here.
      sonic-type-error
      (mov ,(abs-mem out-buffer-cell) rax)
      (mov rdi (imm 2))
      (mov rsi (imm ,out-buffer-cell))
      (mov rdx (imm 8))
      (mov rax (imm ,sys-write))
      (syscall)
      (mov rdi (imm ,exit-type-error))
      (mov rax (imm ,sys-exit))
      (syscall)
      sonic-bounds-error
      (mov rdi (imm ,exit-bounds-error))
      (mov rax (imm ,sys-exit))
      (syscall)
      sonic-overflow-error
      (mov rdi (imm ,exit-overflow-error))
      (mov rax (imm ,sys-exit))
      (syscall)
      sonic-div-error
      (mov rdi (imm ,exit-overflow-error))
      (mov rax (imm ,sys-exit))
      (syscall)))

  ;; --- rv64 -----------------------------------------------------------------
  ;;
  ;; Deliberately absent rather than sketched. The x86-64 runtime above is
  ;; validated by running it; an RV64 one written blind would be validated by
  ;; nothing, and a runtime that assembles is not a runtime that works. The
  ;; RISC-V smoke gate already proves the COMPILER's output is well-formed
  ;; there, which is the claim D22 rests on.
  (define (runtime-listing target entry)
    (case target
      ((x86-64) (x86-64-listing entry))
      ((rv64)
       (error 'runtime-listing
              (string-append
               "no RV64 runtime yet. The x86-64 one is validated by running it "
               "and an RV64 one written blind would be validated by nothing; "
               "the smoke gate proves the compiler's RV64 output is well-formed, "
               "which is a different claim")
              target))
      (else (error 'runtime-listing "unknown target" target))))

  (define (runtime-labels target entry)
    (filter symbol? (runtime-listing target entry)))
  )
