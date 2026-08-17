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
          heap-pointer-cell out-buffer-cell command-line-cell gcmeta-cell
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
  ;; The argument list, built at _start and handed back by `command-line`. It
  ;; is a Scheme object -- a list of strings -- so it is a GC root the day a
  ;; collector exists, which is why it lives in a named cell rather than being
  ;; rebuilt on each call.
  (define command-line-cell (+ data-base 16))      ; 8 bytes: a tagged list
  ;; WHERE THE GC STACK MAPS ARE. The blob rides in the R+X segment after the
  ;; constant pool (D54), which is an address only the linker knows, so `_start`
  ;; computes it RIP-relatively and leaves it here for the collector to find.
  ;;
  ;; A cell rather than a compile-time constant in the collector's own code
  ;; because the collector will be emitted once, into a listing assembled before
  ;; the pool's size is known -- the same reason the pool's own loads are
  ;; RIP-relative rather than absolute.
  (define gcmeta-cell       (+ data-base 24))      ; 8 bytes: address of the maps
  ;; The top-level bindings' cells sit between the runtime's own words and the
  ;; heap. Reserving a fixed span rather than sizing it to the program keeps the
  ;; heap's base a constant, which the entry code stores without arithmetic.
  (define globals-base      (+ data-base 64))
  (define globals-span      1024)                   ; 128 cells
  (define heap-base-address (+ globals-base globals-span))
  ;; 256 MB, AND IT COSTS NOTHING ON DISK. The heap is its own PT_LOAD with
  ;; filesz 0 and a nonzero memsz -- .bss -- so the kernel zeroes it lazily and
  ;; only the pages a program actually touches become resident. The emitted
  ;; binary is the same size at 256 MB as at 1 MB.
  ;;
  ;; It was 1 MB, which was not a decision so much as a number nobody had
  ;; needed to revisit: with nothing reclaiming, that is about 65,000 pairs,
  ;; and a program consing in a loop hit the end almost immediately. Raising it
  ;; does not fix that -- see D52, the collector is written but not lowered --
  ;; but it moves the wall from "any program that allocates" to "a program that
  ;; allocates more than a real machine would hold", which is a different class
  ;; of complaint.
  ;;
  ;; The guards in the allocator stubs compare against base plus this, and the
  ;; sum has to stay inside a signed 32-bit immediate because those comparisons
  ;; use one. 6.3 MB + 256 MB is comfortably inside it; a gigabyte would not be,
  ;; and would need the encoder to grow a 64-bit compare.
  (define heap-size      (* 256 1024 1024))
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

  ;; Linux RV64 syscall numbers, which are the GENERIC UNISTD set and share no
  ;; values with x86-64's: write is 64 rather than 1, exit is 93 rather than 60.
  ;; Reusing the x86 numbers on RV64 does not fail cleanly -- 60 is `sched_...`
  ;; territory there -- so they are named separately rather than parameterised.
  (define rv64-sys-write 64)
  (define rv64-sys-exit  93)

  ;; RISC-V materialises a 32-bit address as `lui` of the high 20 bits plus
  ;; `addi` of the low 12. The low half is SIGN-EXTENDED by addi, so when it has
  ;; bit 11 set the high half must be incremented to compensate. Every address
  ;; this runtime uses today has a small low half and would work without the
  ;; adjustment, which is exactly why it is done properly here rather than left
  ;; as a latent trap for the first constant that does not.
  (define (lo12 a)
    (let ((l (bitwise-and a #xfff)))
      (if (>= l 2048) (- l 4096) l)))
  (define (hi20 a)
    (bitwise-and (ash (+ a 2048) -12) #xfffff))

  ;; Exit codes, one per trap, so a failure names itself in $?.
  (define exit-ok             0)
  (define exit-type-error     101)
  (define exit-bounds-error   102)
  (define exit-overflow-error 103)
  ;; OUT OF HEAP. Distinct from the other three because it is not the program's
  ;; fault: the program is correct and the runtime cannot serve it. See D52 --
  ;; the collector is written but not lowered, so the heap is a 1 MB bump
  ;; region and nothing reclaims. Before this exit existed, exhausting it wrote
  ;; past the mapping and the process took SIGSEGV, which reads as a compiler
  ;; bug rather than as a limit being reached.
  (define exit-heap-error     104)
  (define exit-unimplemented  104)
  ;; `(error ...)` reached at run time. Distinct from `unimplemented`, which
  ;; means this compiler has not written the routine yet: this one means the
  ;; PROGRAM asked to stop.
  (define exit-user-error     105)

  (define (abs-mem addr) `(mem #f #f 1 ,addr))

  ;; --- x86-64 ---------------------------------------------------------------
  ;;
  ;; The calling convention is callconv.ss's, and this file must agree with it:
  ;;   raw-word arguments   rcx rdx rsi rdi
  ;;   tagged arguments     r8 r9 r10 r11
  ;;   raw-f64 arguments    xmm0 ...
  ;;   returns              rax, or xmm0 for a double
  ;;   r15                  nil
  ;; Lanes 0, 1 and 2 active; lane 3 is the padding a body does not have.
  (define three-lane-mask #b0111)

  ;; `lane-mask?` says whether the image contains any three-lane instruction.
  ;;
  ;; IT IS NOT AN OPTIMIZATION. `kmovw` is AVX-512, so emitting it
  ;; unconditionally made EVERY binary this compiler produces require an
  ;; AVX-512 machine -- including programs with no vector work at all, which is
  ;; most of them. That is the x86 counterpart of exactly what the RISC-V smoke
  ;; gate exists to catch: depending on something the target may not have. It
  ;; also blocked every userspace instrumentation tool, since neither valgrind's
  ;; VEX nor QEMU's TCG decodes AVX-512 -- callgrind reported zero instructions
  ;; and qemu died with SIGILL, both on this one instruction, in the PROLOGUE,
  ;; before a single line of the program ran.
  ;;
  ;; Two instructions are dropped with it: the mask goes through `rax` because
  ;; `kmovw` cannot take an immediate.
  (define (x86-64-listing entry lane-mask?)
    `(;; ---- entry ----
      ;;
      ;; The kernel enters here with argc at [rsp]. Nothing reads it: see the
      ;; header on why `command-line` returns the empty list.
      _start
      (mov r15 (imm ,sonic-null))
      ;; THE LANE MASK, set once for the whole image.
      ;;
      ;; Three-lane work over (x, y, z, pad) predicates every operation on
      ;; k1 = 0b0111. One value, one register, and it is established here rather
      ;; than in each function's prologue because the invariant that makes that
      ;; sound is a property of the whole image: nothing we emit writes a k
      ;; register except this instruction. We produce a static binary and call
      ;; no external code, so no ABI convention can take k1 away from us --
      ;; which is not true of the caller-saved GPRs and is why THIS register
      ;; can be treated as a constant when none of those can.
      ;;
      ;; `kmovw` cannot take an immediate, so the constant goes through a GPR.
      ;; rax is the integer scratch and holds nothing at entry.
      ;;
      ;; Emitted only when the image actually has three-lane work: see the
      ;; header on x86-64-listing. `,@` splices nothing when it does not.
      ,@(if lane-mask?
            `((mov rax (imm ,three-lane-mask))
              (kmovw k1 rax))
            '())
      (mov rax (imm ,heap-base-address))
      (mov ,(abs-mem heap-pointer-cell) rax)
      ;; The maps' address, computed the way every other link-time address in
      ;; this runtime is: RIP-relative against a label the assembler resolves.
      (lea rax (mem rip #f 1 (label %gcmeta)))
      (mov ,(abs-mem gcmeta-cell) rax)
      ;; THE ARGUMENT LIST, built before anything else runs.
      ;;
      ;; The kernel leaves argc at [rsp] and the argv pointers directly after
      ;; it. Nothing has pushed yet -- the entry code above only moves -- so rsp
      ;; still points at argc here, and it is copied to a base register because
      ;; the addressing forms want one.
      ;;
      ;; Walked BACKWARD, from argc-1 down to 0, so that consing produces the
      ;; list in argv order. Element 0 is the program name, as every Scheme's
      ;; `command-line` has it, which is why nbody reads its argument with
      ;; `cadr` rather than `car`.
      (mov rbx rsp)
      (mov r12 (mem rbx #f 1 0))                 ; argc
      (mov r13 r15)                              ; the list, starting empty
      %cl-loop
      (cmp r12 (imm 0))
      (jle (label %cl-done))
      (sub r12 (imm 1))
      (mov rsi (mem rbx r12 8 8))                ; argv[r12]
      (call (label %cstr->string))
      (mov r8 rax)
      (mov r9 r13)
      (call (label %cons))
      (mov r13 rax)
      (jmp (label %cl-loop))
      %cl-done
      (mov ,(abs-mem command-line-cell) r13)
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
      ;; OUT OF HEAP, CHECKED BEFORE THE HEADER IS WRITTEN. The header goes to
      ;; [rax] and [rax+8], so a base within 16 bytes of the limit would fault
      ;; on the write itself and never reach the end check below.
      ;;
      ;; `jg` AND NOT `ja`, which is the unsigned form an address comparison
      ;; would normally want. The encoder has only the signed conditionals, and
      ;; that is sound here rather than a compromise: the heap sits at 6.3 MB
      ;; and ends at 7.3 MB, so every value compared is a small positive number
      ;; and the two orderings agree. A heap placed above 2^63 would need the
      ;; unsigned form and the encoder would have to grow it.
      (cmp rax (imm ,(- (+ heap-base-address heap-size) heap-header-bytes)))
      (jg (label sonic-heap-error))
      (mov rdx (imm ,heap-type-flvector))
      (mov (mem rax #f 1 0) rdx)                 ; [raw+0] = type
      (mov (mem rax #f 1 8) rcx)                 ; [raw+8] = length, a raw count
      ;; bump: heap_ptr = raw + 16 + 8*count
      (mov rsi rcx)
      (shl rsi (imm 3))
      (add rsi (imm ,heap-header-bytes))
      (add rsi rax)
      ;; AND ON THE END, before the payload is written. A single large
      ;; allocation can clear the base check and still run off the end.
      (cmp rsi (imm ,(+ heap-base-address heap-size)))
      (jg (label sonic-heap-error))

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

      ;; ---- (make-vector count fill) ----
      ;; count in rcx and fill in rdx -- raw-word arguments 0 and 1. Returns a
      ;; tagged pointer.
      ;;
      ;; THE FILL'S REGISTER DEPENDS ON ITS CLASS, and that is a real limit
      ;; rather than a convention this routine gets to choose. repr.ss assigns a
      ;; storage class to a primitive's RESULT and says nothing about its
      ;; ARGUMENTS, so the class of the fill is whatever the fill's own value
      ;; has: a fixnum literal is raw-word and arrives in rdx, while a heap
      ;; object would be tagged and arrive in r8. A runtime routine has one
      ;; calling convention and cannot serve both.
      ;;
      ;; So this serves the raw-word case, which is what `(make-vector n 0)`
      ;; is, and a tagged fill would read rdx and store garbage. See the bead:
      ;; the fix is for the compiler to declare argument classes, not for this
      ;; file to guess.
      ;;
      ;; The same shape as `%make-flvector` with two differences, and both are
      ;; the difference between the two storage kinds rather than incidental.
      ;; The type word says `heap-type-vector`, so the collector SCANS these
      ;; elements where it skips an flvector's; and the fill is copied with
      ;; `mov` from a value register, not `movsd` from a float one, because what
      ;; is being stored is a Scheme object and not eight raw bytes.
      ;;
      ;; It did not exist until fannkuch-redux needed it. nbody uses only
      ;; flvectors, so `make-vector` lowered to a call to a label nothing
      ;; defined and the failure surfaced as `resolve-labels: undefined label
      ;; %make-vector` -- loudly, and at link time, which is the right place.
      %make-vector
      (mov rax ,(abs-mem heap-pointer-cell))     ; rax = raw base
      ;; OUT OF HEAP, CHECKED BEFORE THE HEADER IS WRITTEN. The header goes to
      ;; [rax] and [rax+8], so a base within 16 bytes of the limit would fault
      ;; on the write itself and never reach the end check below.
      (cmp rax (imm ,(- (+ heap-base-address heap-size) heap-header-bytes)))
      (jg (label sonic-heap-error))
      ;; THE TYPE GOES THROUGH rdi, NOT rdx. rdx holds the FILL for the whole
      ;; routine, and %make-flvector's shape -- which this one is copied from --
      ;; stages the type word through rdx because its fill is in xmm0 and rdx is
      ;; free. Here it is not. Writing the type to rdx destroys the fill, and it
      ;; reads correctly anyway whenever the fill is 0, because heap-type-vector
      ;; IS 0: a bug that hides on exactly the call every program makes first.
      ;; rdi is free until the `lea` below sets it.
      (mov rdi (imm ,heap-type-vector))
      (mov (mem rax #f 1 0) rdi)                 ; [raw+0] = type
      (mov (mem rax #f 1 8) rcx)                 ; [raw+8] = length, a raw count
      ;; bump: heap_ptr = raw + 16 + 8*count
      (mov rsi rcx)
      (shl rsi (imm 3))
      (add rsi (imm ,heap-header-bytes))
      (add rsi rax)
      ;; AND ON THE END, before the payload is written. A single large
      ;; allocation can clear the base check and still run off the end.
      (cmp rsi (imm ,(+ heap-base-address heap-size)))
      (jg (label sonic-heap-error))

      (mov ,(abs-mem heap-pointer-cell) rsi)
      ;; fill the elements
      (lea rdi (mem rax #f 1 ,heap-header-bytes))
      (mov rsi (imm 0))
      %mkv-loop
      (cmp rsi rcx)
      (jge (label %mkv-done))
      (mov (mem rdi rsi 8 0) rdx)
      (add rsi (imm 1))
      (jmp (label %mkv-loop))
      %mkv-done
      (add rax (imm ,(+ heap-header-bytes heap-tag)))
      (ret)

      ;; ---- (a C string) -> a Scheme string ----
      ;;
      ;; rsi is a NUL-terminated byte pointer; the tagged string comes back in
      ;; rax. Layout is every other heap object's: type, length, payload -- and
      ;; the length is a BYTE COUNT, so the payload is packed bytes rather than
      ;; one character per word. That distinction is why this waited for an
      ;; 8-bit store; see the encoder.
      ;;
      ;; The heap pointer is bumped by the payload ROUNDED UP TO EIGHT, so the
      ;; next object still starts word-aligned. Every other allocator here
      ;; bumps by a multiple of eight for free; this is the first that can ask
      ;; for a fraction of a word.
      %cstr->string
      (mov rcx (imm 0))
      %c2s-len
      (movzx rdx (mem rsi rcx 1 0))
      (cmp rdx (imm 0))
      (je (label %c2s-alloc))
      (add rcx (imm 1))
      (jmp (label %c2s-len))
      %c2s-alloc
      (mov rax ,(abs-mem heap-pointer-cell))
      ;; OUT OF HEAP, CHECKED BEFORE THE HEADER IS WRITTEN. The header goes to
      ;; [rax] and [rax+8], so a base within 16 bytes of the limit would fault
      ;; on the write itself and never reach the end check below.
      (cmp rax (imm ,(- (+ heap-base-address heap-size) heap-header-bytes)))
      (jg (label sonic-heap-error))
      (mov rdi (imm ,heap-type-string))
      (mov (mem rax #f 1 0) rdi)                 ; [raw+0] = type
      (mov (mem rax #f 1 8) rcx)                 ; [raw+8] = byte count
      (mov rdi (imm 0))
      %c2s-copy
      (cmp rdi rcx)
      (jge (label %c2s-bump))
      (movzx rdx (mem rsi rdi 1 0))
      (movb (mem rax rdi 1 ,heap-header-bytes) rdx)
      (add rdi (imm 1))
      (jmp (label %c2s-copy))
      %c2s-bump
      (mov rdi rcx)
      (add rdi (imm 7))
      (shr rdi (imm 3))
      (shl rdi (imm 3))
      (add rdi (imm ,heap-header-bytes))
      (add rdi rax)
      ;; AND ON THE END, before the payload is written. A single large
      ;; allocation can clear the base check and still run off the end.
      (cmp rdi (imm ,(+ heap-base-address heap-size)))
      (jg (label sonic-heap-error))

      (mov ,(abs-mem heap-pointer-cell) rdi)
      (add rax (imm ,(+ heap-header-bytes heap-tag)))
      (ret)

      ;; ---- pairs ----
      ;;
      ;; `(cons 1 2)` used to die in resolve-labels with "undefined label
      ;; %cons". lower.ss has mapped `cons`, `car` and `cdr` onto these names
      ;; for as long as the primitive table has existed; nothing defined them,
      ;; so a Scheme with no pairs failed at LINK rather than at parse, which is
      ;; loud but late.
      ;;
      ;; ARGUMENTS ARRIVE TAGGED, and that is a guarantee rather than a hope:
      ;; repr.ss's `prim-arg-classes` declares `(cons tagged tagged)` and pushes
      ;; the requirement back to whatever produces each field, so convert.ss
      ;; retags a raw word at its definition. Without that declaration this
      ;; routine would be storing whatever representation the program happened
      ;; to have -- which is the hazard `%make-vector`'s fill still carries and
      ;; the reason the declaration had to come first.
      ;;
      ;; Both fields are SCANNED by the collector, so both must be objects. A
      ;; raw machine integer in either one is an address to chase, which is
      ;; D21's failure mode rather than a wrong number.
      ;;
      ;; Layout is every other heap object's: type, length, payload. The length
      ;; is 2 because the collector's scan walks a header and a field count, and
      ;; a pair's two fields are exactly what it must follow.
      %cons
      (mov rax ,(abs-mem heap-pointer-cell))     ; rax = raw base
      ;; OUT OF HEAP, CHECKED BEFORE THE HEADER IS WRITTEN. The header goes to
      ;; [rax] and [rax+8], so a base within 16 bytes of the limit would fault
      ;; on the write itself and never reach the end check below.
      (cmp rax (imm ,(- (+ heap-base-address heap-size) heap-header-bytes)))
      (jg (label sonic-heap-error))
      (mov rsi (imm ,heap-type-pair))
      (mov (mem rax #f 1 0) rsi)                 ; [raw+0] = type
      (mov rsi (imm 2))
      (mov (mem rax #f 1 8) rsi)                 ; [raw+8] = field count
      (mov (mem rax #f 1 ,heap-header-bytes) r8)         ; car, first tagged arg
      (mov (mem rax #f 1 ,(+ heap-header-bytes 8)) r9)   ; cdr, second
      (lea rsi (mem rax #f 1 ,(+ heap-header-bytes 16)))
      ;; AND ON THE END, before the payload is written. A single large
      ;; allocation can clear the base check and still run off the end.
      (cmp rsi (imm ,(+ heap-base-address heap-size)))
      (jg (label sonic-heap-error))

      (mov ,(abs-mem heap-pointer-cell) rsi)
      (add rax (imm ,(+ heap-header-bytes heap-tag)))
      (ret)

      ;; THE TAG COMES OFF IN THE DISPLACEMENT, not in an instruction. A tagged
      ;; pointer is `raw + heap-header-bytes + heap-tag`, so the car sits at
      ;; `-heap-tag` from it and the cdr eight bytes further on -- the same
      ;; trick every vector access here uses, and the reason a load's
      ;; displacement is one constant rather than a subtract and a load.
      ;;
      ;; No type check: lang.ss gives `car` and `cdr` a `type-check` control and
      ;; lower.ss emits it as a `chk` BEFORE the call, so by here the argument
      ;; is known to be a pair. Repeating it would be a second opinion in the
      ;; place least able to report anything useful.
      %car
      (mov rax (mem r8 #f 1 ,(- heap-tag)))
      (ret)

      %cdr
      (mov rax (mem r8 #f 1 ,(- 8 heap-tag)))
      (ret)

      ;; ---- type predicates and eq? ----
      ;;
      ;; The rest of the names lower.ss has always mapped and nothing defined.
      ;; Like %cons, each failed at LINK, so `(pair? x)` was not a slow path or
      ;; a wrong answer -- it was a program that would not build.
      ;;
      ;; THE ARGUMENT IS TAGGED, declared in repr.ss, and that declaration is
      ;; what these depend on. Until the representation was made honest -- see
      ;; the interlock of convert.ss's literals, lower.ss's untag and repr.ss's
      ;; vector-set! rule -- a tagged fixnum was stored unshifted, and
      ;; `%fixnum?` answered FALSE about the number five.
      ;;
      ;; THE RESULT IS A RAW WORD, 0 or 1, and NOT sonic-false/sonic-true.
      ;; repr.ss lists all seven in `boolean-word-prims`, so `branch-if`
      ;; compares against zero. Returning the tagged booleans would make every
      ;; predicate read as true, since 7 and 15 are both non-zero.
      ;;
      ;; numeric.ss's encoding, which these only read:
      ;;   fixnum        low three bits 000
      ;;   heap pointer  low three bits 001, TYPE in the header word
      ;;   immediate     low three bits 111, secondary tag above it
      ;;
      ;; D29 is why the heap cases pay a load: one pointer tag for every heap
      ;; type, so the predicates pay for the distinction and indexing does not.
      %fixnum?
      (mov rax r8)
      (and rax (imm 7))
      (cmp rax (imm 0))
      (je (label %pred-true))
      (jmp (label %pred-false))

      %null?
      (cmp r8 (imm ,sonic-null))
      (je (label %pred-true))
      (jmp (label %pred-false))

      ;; eq? IS IDENTITY ON THE MACHINE WORD, which is right for exactly what
      ;; R6RS lets it be right for: immediates, fixnums and pointers compare as
      ;; themselves. Two distinct boxed flonums holding the same double are not
      ;; `eq?`, which is permitted and is why `fl=` exists.
      %eq?
      (cmp r8 r9)
      (je (label %pred-true))
      (jmp (label %pred-false))

      %pair?
      (mov rax r8)
      (and rax (imm 7))
      (cmp rax (imm ,heap-tag))
      (jne (label %pred-false))
      (mov rax (mem r8 #f 1 ,heap-type-disp))
      (cmp rax (imm ,heap-type-pair))
      (je (label %pred-true))
      (jmp (label %pred-false))

      %vector?
      (mov rax r8)
      (and rax (imm 7))
      (cmp rax (imm ,heap-tag))
      (jne (label %pred-false))
      (mov rax (mem r8 #f 1 ,heap-type-disp))
      (cmp rax (imm ,heap-type-vector))
      (je (label %pred-true))
      (jmp (label %pred-false))

      %flvector?
      (mov rax r8)
      (and rax (imm 7))
      (cmp rax (imm ,heap-tag))
      (jne (label %pred-false))
      (mov rax (mem r8 #f 1 ,heap-type-disp))
      (cmp rax (imm ,heap-type-flvector))
      (je (label %pred-true))
      (jmp (label %pred-false))

      ;; A FLONUM IS THE BOXED ONE. An unboxed double is `raw-f64`, a
      ;; representation this cannot be handed; by the time a value reaches here
      ;; it is tagged, so the only flonum that exists at this point is a box.
      %flonum?
      (mov rax r8)
      (and rax (imm 7))
      (cmp rax (imm ,heap-tag))
      (jne (label %pred-false))
      (mov rax (mem r8 #f 1 ,heap-type-disp))
      (cmp rax (imm ,heap-type-flonum))
      (je (label %pred-true))
      (jmp (label %pred-false))

      %pred-true
      (mov rax (imm 1))
      (ret)
      %pred-false
      (mov rax (imm 0))
      (ret)

      ;; `error` STOPS THE PROGRAM and gets its own exit code, so a failure
      ;; names itself in $? like every other trap here. It does not print its
      ;; arguments: that needs strings, which a real `command-line` and
      ;; `string->number` are also waiting on.
      %error
      (mov rdi (imm ,exit-user-error))
      (mov rax (imm ,sys-exit))
      (syscall)

      ;; ---- (make-vector count fill), TAGGED FILL ----
      ;; count in rcx (raw-word argument 0), fill in r8 (TAGGED argument 0).
      ;;
      ;; A SECOND ROUTINE RATHER THAN A FLAG, because the register the fill
      ;; arrives in is decided by its storage class, and the class is decided
      ;; by the program. `vector-element-class` is program-wide, so exactly one
      ;; of these two is reachable in any given image and lower.ss picks it.
      ;;
      ;; The one above assumes a raw fill and says so, and that was harmless
      ;; while nothing untagged what it read back: a raw 7 went in and a raw 7
      ;; came out. Once reads of a tagged-element vector shift, the same 7 comes
      ;; back as 0 -- which it did, for exactly one commit -- so the fill has to
      ;; be a real object like every other field the collector scans.
      %make-vector-tagged
      (mov rax ,(abs-mem heap-pointer-cell))     ; rax = raw base
      ;; OUT OF HEAP, CHECKED BEFORE THE HEADER IS WRITTEN. The header goes to
      ;; [rax] and [rax+8], so a base within 16 bytes of the limit would fault
      ;; on the write itself and never reach the end check below.
      (cmp rax (imm ,(- (+ heap-base-address heap-size) heap-header-bytes)))
      (jg (label sonic-heap-error))
      (mov rdi (imm ,heap-type-vector))
      (mov (mem rax #f 1 0) rdi)                 ; [raw+0] = type
      (mov (mem rax #f 1 8) rcx)                 ; [raw+8] = length, a raw count
      (mov rsi rcx)
      (shl rsi (imm 3))
      (add rsi (imm ,heap-header-bytes))
      (add rsi rax)
      ;; AND ON THE END, before the payload is written. A single large
      ;; allocation can clear the base check and still run off the end.
      (cmp rsi (imm ,(+ heap-base-address heap-size)))
      (jg (label sonic-heap-error))

      (mov ,(abs-mem heap-pointer-cell) rsi)
      (lea rdi (mem rax #f 1 ,heap-header-bytes))
      (mov rsi (imm 0))
      %mkvt-loop
      (cmp rsi rcx)
      (jge (label %mkvt-done))
      (mov (mem rdi rsi 8 0) r8)
      (add rsi (imm 1))
      (jmp (label %mkvt-loop))
      %mkvt-done
      (add rax (imm ,(+ heap-header-bytes heap-tag)))
      (ret)

      ;; ---- box a flonum ----
      ;;
      ;; The double arrives in xmm0 -- the first raw-f64 argument register --
      ;; and the tagged pointer comes back in rax, which is the convention's
      ;; tagged return register, so this needs no special calling sequence.
      ;;
      ;; Layout is every other heap object's: type word, length word, payload.
      ;; The length is 1 because the collector's scan walks a header and a field
      ;; count; a flonum's one field is raw, which the TYPE says, and that is
      ;; what keeps eight bytes of mantissa from being followed as a pointer.
      ;; ---- integer division ----
      ;;
      ;; A RUNTIME CALL RATHER THAN AN INSTRUCTION, and the reason is the
      ;; register file rather than the encoding. `idiv` reads a 128-bit
      ;; dividend in rdx:rax and writes the quotient to rax and the remainder to
      ;; rdx -- two specific registers, both destroyed. regs.ss allocates from
      ;; disjoint class pools and has no way to say that, which is exactly what
      ;; the selector's refusal said: "integer division needs the rdx:rax pair
      ;; idiv hardwires, which the register partition does not model".
      ;;
      ;; A runtime routine has no allocator to argue with. It costs a call
      ;; around an instruction that is already 20 to 40 cycles, so the overhead
      ;; is in the noise, and it is the difference between compiling integer
      ;; division and refusing it.
      ;;
      ;; Arguments arrive raw, not tagged: repr.ss classifies the fixnum
      ;; primitives raw-word. Dividend in rcx, divisor in rdx (raw-word
      ;; arguments 0 and 1), result in rax.
      ;;
      ;; THE DIVISOR IS MOVED FIRST because `cqo` writes rdx, which is where it
      ;; arrived. Dividing by the sign extension of the dividend is a plausible
      ;; wrong answer rather than a crash.
      %fxquotient
      (mov rax rcx)
      (mov r11 rdx)
      (cqo)
      (idiv r11)
      (ret)

      %fxremainder
      (mov rax rcx)
      (mov r11 rdx)
      (cqo)
      (idiv r11)
      (mov rax rdx)
      (ret)

      ;; `modulo` follows the sign of the DIVISOR where `remainder` follows the
      ;; dividend, so they differ exactly when the two signs disagree and the
      ;; remainder is not zero. Adding the divisor once is the whole correction.
      %fxmodulo
      (mov rax rcx)
      (mov r11 rdx)
      (cqo)
      (idiv r11)
      (mov rax rdx)
      ;; Correct exactly when the remainder is non-zero and its sign disagrees
      ;; with the divisor's. Written as two compares rather than as a sign
      ;; XOR because the encoder has no `xor` for general-purpose registers --
      ;; the only bitwise ops it carries are the packed `xorpd`/`andpd` that
      ;; IEEE negation needs.
      (cmp rax (imm 0))
      (je (label %fxmod-done))
      (jl (label %fxmod-neg))
      ;; remainder > 0: correct only if the divisor is negative
      (cmp r11 (imm 0))
      (jge (label %fxmod-done))
      (add rax r11)
      (jmp (label %fxmod-done))
      %fxmod-neg
      ;; remainder < 0: correct only if the divisor is positive
      (cmp r11 (imm 0))
      (jle (label %fxmod-done))
      (add rax r11)
      %fxmod-done
      (ret)

      %box-flonum
      (mov rax ,(abs-mem heap-pointer-cell))     ; rax = raw base
      ;; OUT OF HEAP, CHECKED BEFORE THE HEADER IS WRITTEN. The header goes to
      ;; [rax] and [rax+8], so a base within 16 bytes of the limit would fault
      ;; on the write itself and never reach the end check below.
      (cmp rax (imm ,(- (+ heap-base-address heap-size) heap-header-bytes)))
      (jg (label sonic-heap-error))
      (mov rdx (imm ,heap-type-flonum))
      (mov (mem rax #f 1 0) rdx)                 ; [raw+0] = type
      (mov rdx (imm 1))
      (mov (mem rax #f 1 8) rdx)                 ; [raw+8] = one field
      (movsd (mem rax #f 1 ,heap-header-bytes) xmm0)
      (mov rsi rax)
      (add rsi (imm ,(+ heap-header-bytes 8)))
      ;; AND ON THE END, before the payload is written. A single large
      ;; allocation can clear the base check and still run off the end.
      (cmp rsi (imm ,(+ heap-base-address heap-size)))
      (jg (label sonic-heap-error))

      (mov ,(abs-mem heap-pointer-cell) rsi)
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
      ;; ---- (command-line) ----
      ;; The list built at _start. It used to return the empty list, which took
      ;; nbody's default branch and was the whole reason N could not be passed.
      command-line
      (mov rax ,(abs-mem command-line-cell))
      (ret)

      ;; ---- (length lst) ----
      ;;
      ;; Walks the cdr chain to `sonic-null`, counting. The count is a RAW
      ;; WORD, which repr.ss declares in `extern-result-classes`: this returns
      ;; an element count and not a Scheme object, and calling it tagged is
      ;; what made nbody's N a tagged fixnum consumed as a machine word.
      ;;
      ;; It used to return the constant 1, which was enough for the one
      ;; expression in the benchmark -- `(fx> (length args) 1)` against an empty
      ;; argument list -- and answered every other question wrongly. The empty
      ;; list now answers 0, and that expression takes the same branch it
      ;; always did.
      length
      (mov rax (imm 0))
      (mov rsi r8)
      %len-loop
      (cmp rsi (imm ,sonic-null))
      (je (label %len-done))
      (add rax (imm 1))
      (mov rsi (mem rsi #f 1 ,(- 8 heap-tag)))   ; rsi = (cdr rsi)
      (jmp (label %len-loop))
      %len-done
      (ret)

      ;; ---- (cadr lst) ----
      ;;
      ;; `(car (cdr lst))`, which is two loads at constant displacements: a
      ;; pair's fields sit at -heap-tag and 8-heap-tag from the tagged pointer,
      ;; the same offsets %car and %cdr use.
      ;;
      ;; NO TYPE CHECK, for the same reason %car has none: `cadr` is reached
      ;; through the extern list rather than through lang.ss's primitive table,
      ;; so no `chk` is emitted before it. A caller handing this a non-pair gets
      ;; a wild load rather than a trap, which is worth saying out loud and is
      ;; the same exposure every extern here carries.
      cadr
      (mov rax (mem r8 #f 1 ,(- 8 heap-tag)))
      (mov rax (mem rax #f 1 ,(- heap-tag)))
      (ret)

      ;; ---- (string->number s) ----
      ;;
      ;; A DECIMAL FIXNUM AND NOTHING ELSE. No sign, no radix, no flonum, no
      ;; validation: every digit is taken as a digit and anything else is
      ;; arithmetic on rubbish. That is the whole of what a benchmark's N needs
      ;; and it is the honest size of this routine -- a real `string->number` is
      ;; a parser and belongs in Scheme, compiled, not here.
      ;;
      ;; The result is a RAW WORD, which repr.ss declares in
      ;; `extern-result-classes`: it is a machine integer, and calling it tagged
      ;; is what made nbody's N a tagged fixnum consumed as one.
      ;;
      ;; Offsets are the string's: the length sits at ptr-9 and the bytes start
      ;; at ptr-1, the same displacements every heap object uses.
      string->number
      (mov rcx (mem r8 #f 1 ,(- -8 heap-tag)))   ; byte count
      (mov rax (imm 0))
      (mov rdi (imm 0))
      %s2n-loop
      (cmp rdi rcx)
      (jge (label %s2n-done))
      (movzx rdx (mem r8 rdi 1 ,(- heap-tag)))
      (sub rdx (imm 48))                         ; '0'
      (imul rax rax (imm 10))
      (add rax rdx)
      (add rdi (imm 1))
      (jmp (label %s2n-loop))
      %s2n-done
      (ret)

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
      (syscall)
      sonic-heap-error
      (mov rdi (imm ,exit-heap-error))
      (mov rax (imm ,sys-exit))
      (syscall)))

  ;; --- rv64 -----------------------------------------------------------------
  ;;
  ;; Deliberately absent rather than sketched. The x86-64 runtime above is
  ;; validated by running it; an RV64 one written blind would be validated by
  ;; nothing, and a runtime that assembles is not a runtime that works. The
  ;; RISC-V smoke gate already proves the COMPILER's output is well-formed
  ;; there, which is the claim D22 rests on.
  ;; `lane-mask?` defaults to #t, which is the pre-D59 behaviour: a caller that
  ;; does not know whether the image vectorizes gets the mask and a binary that
  ;; runs everywhere the old ones did. Only driver.ss, which HAS the finalized
  ;; code and can therefore answer the question, passes #f.
  ;; --- the RV64 entry sequence ----------------------------------------------
  ;;
  ;; MINIMAL, AND ONLY SAFE BECAUSE THE GAPS FAIL LOUDLY. This establishes the
  ;; nil register, the heap pointer and an empty command line, calls the entry
  ;; point, and exits. It does NOT provide the 39 helper routines the x86-64
  ;; listing carries -- no %cons, no %make-flvector, no %box-flonum, no number
  ;; formatting, and it does not populate %gcmeta.
  ;;
  ;; That is not a silent limitation. Compiled code calls those helpers BY
  ;; LABEL, so a program needing one fails at label resolution with the name it
  ;; wanted, rather than running and producing wrong numbers. A partial runtime
  ;; that linked would be the dangerous version of this; one that refuses to
  ;; link is merely incomplete. Allocation is what pulls in %gcmeta, and
  ;; allocation cannot link, so the unpopulated cell is unreachable rather than
  ;; wrong.
  ;;
  ;; gp holds nil here, per regs.ss: RISC-V has no segment registers, so nil
  ;; gets a dedicated register the way it does on arm64. That is the analogue
  ;; of r15 in the x86-64 listing above.
  (define (rv64-listing entry)
    `(_start
      (addi gp zero ,sonic-null)
      ;; heap-pointer-cell <- heap-base-address
      (lui  t0 ,(hi20 heap-base-address))
      (addi t0 t0 ,(lo12 heap-base-address))
      (lui  t2 ,(hi20 heap-pointer-cell))
      (sd   t0 t2 ,(lo12 heap-pointer-cell))
      ;; command-line-cell <- '(), so `command-line` answers rather than faults.
      ;; The x86-64 listing walks argv here; nothing that needs the list can
      ;; link on RV64 yet, so an empty list is the honest placeholder.
      (lui  t2 ,(hi20 command-line-cell))
      (sd   gp t2 ,(lo12 command-line-cell))
      ;; A BARE SYMBOL, not `(label ...)`. The two targets spell a label
      ;; reference differently and object.ss resolves them separately: x86-64
      ;; rewrites `(label L)` to `(rel n)`, while the RV64 arm looks for a
      ;; SYMBOL in the last operand of a branchy instruction. Using the x86
      ;; spelling here got `(label main.entry1)` all the way to the encoder,
      ;; which rejected it as "jal displacement is not an even offset" -- the
      ;; complaint of something handed a list where it wanted a number.
      (jal  ra ,entry)
      (addi a0 zero ,exit-ok)
      (addi a7 zero ,rv64-sys-exit)
      (ecall)

      ;; ---- (make-flvector count fill) ----
      ;;
      ;; count in t3 and fill in fa0 -- raw-word argument 0 and raw-f64
      ;; argument 0 for THIS target. The registers differ from the x86-64 copy
      ;; above (rcx and xmm0) and so does the return: callconv-rv64 returns
      ;; raw-word results in t3, where x86-64 uses rax. Reading the x86 routine
      ;; and substituting register names would have been wrong in both places.
      ;;
      ;; t0, t1 and t2 are the RV64 scratch set (regs.ss), so they are outside
      ;; the allocatable pools and free here.
      ;;
      ;; Layout is D29's, identical across targets: type word, length, then the
      ;; elements, with the returned pointer aimed at element zero and carrying
      ;; the heap tag.
      %make-flvector
      (lui  t0 ,(hi20 heap-pointer-cell))
      (ld   t1 t0 ,(lo12 heap-pointer-cell))     ; t1 = raw base
      ;; OUT OF HEAP, CHECKED BEFORE THE HEADER IS WRITTEN -- the header goes to
      ;; [t1] and [t1+8], so a base within 16 bytes of the limit would fault on
      ;; the write itself. Same ordering as the x86-64 routine, for the same
      ;; reason.
      ;;
      ;; `blt` is the SIGNED compare, matching the x86 side's `jg`. Sound for
      ;; the same reason recorded there: the heap sits well below 2^31, so every
      ;; address compared is a small positive number and the signed and unsigned
      ;; orderings agree.
      (lui  t2 ,(hi20 (- (+ heap-base-address heap-size) heap-header-bytes)))
      (addi t2 t2 ,(lo12 (- (+ heap-base-address heap-size) heap-header-bytes)))
      (blt  t2 t1 sonic-heap-error)
      (addi t0 zero ,heap-type-flvector)
      (sd   t0 t1 0)                             ; [raw+0] = type
      (sd   t3 t1 8)                             ; [raw+8] = length, raw count
      ;; bump: heap_ptr = raw + 16 + 8*count
      (slli t0 t3 3)
      (addi t0 t0 ,heap-header-bytes)
      (add  t0 t0 t1)
      ;; AND ON THE END, before the payload is written: one large allocation can
      ;; clear the base check and still run off the end.
      (lui  t2 ,(hi20 (+ heap-base-address heap-size)))
      (addi t2 t2 ,(lo12 (+ heap-base-address heap-size)))
      (blt  t2 t0 sonic-heap-error)
      (lui  t2 ,(hi20 heap-pointer-cell))
      (sd   t0 t2 ,(lo12 heap-pointer-cell))
      ;; fill the elements: t1 stays the raw base, t0 walks, t2 counts
      (addi t0 t1 ,heap-header-bytes)
      (addi t2 zero 0)
      %mkfl-loop
      (bge  t2 t3 %mkfl-done)
      (fsd  fa0 t0 0)
      (addi t0 t0 8)
      (addi t2 t2 1)
      (jal  zero %mkfl-loop)
      %mkfl-done
      (addi t3 t1 ,(+ heap-header-bytes heap-tag))
      (jalr zero ra 0)

      ;; The trap. Distinct exit code so a failure names itself in $?, the same
      ;; contract the x86-64 traps keep.
      sonic-heap-error
      (addi a0 zero ,exit-heap-error)
      (addi a7 zero ,rv64-sys-exit)
      (ecall)))

  (define (runtime-listing target entry . opt)
    (let ((lane-mask? (if (null? opt) #t (car opt))))
      (case target
        ((x86-64) (x86-64-listing entry lane-mask?))
        ((rv64) (rv64-listing entry))
        (else (error 'runtime-listing "unknown target" target)))))

  ;; The flag is forwarded, not defaulted again: labels are OFFSETS, and a label
  ;; map built against a two-instruction-longer prologue than the code it
  ;; describes is the exact shape of D56 -- every address off by a constant,
  ;; plausible-looking, and wrong.
  (define (runtime-labels target entry . opt)
    (filter symbol? (apply runtime-listing target entry opt)))
  )
