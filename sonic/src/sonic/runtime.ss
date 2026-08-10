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
          heap-pointer-cell out-buffer-cell command-line-cell
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

  (define (x86-64-listing entry)
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
      (mov rax (imm ,three-lane-mask))
      (kmovw k1 rax)
      (mov rax (imm ,heap-base-address))
      (mov ,(abs-mem heap-pointer-cell) rax)
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
      (mov rsi (imm ,heap-type-pair))
      (mov (mem rax #f 1 0) rsi)                 ; [raw+0] = type
      (mov rsi (imm 2))
      (mov (mem rax #f 1 8) rsi)                 ; [raw+8] = field count
      (mov (mem rax #f 1 ,heap-header-bytes) r8)         ; car, first tagged arg
      (mov (mem rax #f 1 ,(+ heap-header-bytes 8)) r9)   ; cdr, second
      (lea rsi (mem rax #f 1 ,(+ heap-header-bytes 16)))
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
      (mov rdi (imm ,heap-type-vector))
      (mov (mem rax #f 1 0) rdi)                 ; [raw+0] = type
      (mov (mem rax #f 1 8) rcx)                 ; [raw+8] = length, a raw count
      (mov rsi rcx)
      (shl rsi (imm 3))
      (add rsi (imm ,heap-header-bytes))
      (add rsi rax)
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
      (mov rdx (imm ,heap-type-flonum))
      (mov (mem rax #f 1 0) rdx)                 ; [raw+0] = type
      (mov rdx (imm 1))
      (mov (mem rax #f 1 8) rdx)                 ; [raw+8] = one field
      (movsd (mem rax #f 1 ,heap-header-bytes) xmm0)
      (mov rsi rax)
      (add rsi (imm ,(+ heap-header-bytes 8)))
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
