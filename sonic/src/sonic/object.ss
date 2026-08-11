;;; Object emission: selected instructions to a function image, and to ELF64.
;;;
;;; E2-OBJ. Takes a selected and allocated instruction stream, runs it through
;;; the real encoder for its target, and produces two things from the same
;;; bytes: a self-describing function image, and a relocatable ELF64 object.
;;;
;;; ## The image, and why the metadata size lives in the header
;;;
;;; sonic/src/sonic/emit.ss already assembles code and metadata together; what
;;; it does not say is where the metadata SITS relative to the code once the
;;; function is in memory. D21's collector has a program counter and needs the
;;; entry covering it, so it has to get from a PC to the metadata blob without
;;; consulting a side table, which would be one more thing to keep in step and
;;; one more thing to get wrong under a moving collector.
;;;
;;; So the layout is fixed and the header carries sizes, not pointers:
;;;
;;;     0   magic "SNIC"
;;;     4   u16 format version
;;;     6   u16 target id
;;;     8   u32 code size
;;;     12  u32 constant pool size
;;;     16  u32 metadata size
;;;     20  u32 frame slots
;;;     24  machine code
;;;         constant pool, aligned to 8
;;;         metadata blob
;;;
;;; A PC inside the code gives the image base by subtraction, and everything
;;; else is addition: the pool starts at `align8(24 + code-size)` and the blob
;;; starts at `align8(pool + pool-size)`. Sizes rather than offsets because
;;; offsets can disagree with the thing they point at and sizes cannot.
;;;
;;; The pool is 8-aligned because it holds f64 literals, which is the whole
;;; reason it exists: sonic/src/sonic/target-x86-64.ss refuses an f64 `const`
;;; and an f64 `neg` for want of one, and so does the RV64 selector.
;;;
;;; ## Why also ELF
;;;
;;; Because our own decoder agreeing with our own encoder proves nothing. The
;;; acceptance for this bead is that `objdump -d` and `riscv64-linux-gnu-objdump
;;; -d` read our bytes back as the mnemonics the selector chose, and that `ld`
;;; accepts the object and the linked program runs. Both back ends are already
;;; verified instruction by instruction against binutils
;;; (sonic/test/x86-64-test.ss, sonic/test/rv64-test.ss); this is the same
;;; discipline applied to the container.
;;;
;;; The ELF is deliberately minimal and deliberately NOT clever: no relocations,
;;; no program headers, one global function symbol so the disassembly is
;;; labelled. Relocations arrive with the constant pool's first real user, since
;;; a pooled literal on x86-64 is RIP-relative and on RV64 is an `auipc` pair,
;;; and both need a reloc against `.rodata`.

(library (sonic object)
  (export assemble-function
          function-object? function-object-name function-object-target
          function-object-code function-object-constants
          function-object-metadata function-object-entries
          function-object-frame-slots
          function-object-image function-object-elf
          image-header-size image-target image-code image-constants
          image-metadata image-metadata-entries image-frame-slots
          resolve-labels encode-instruction instruction-size
          gcmeta-target-for constants->bytevector
          write-bytevector-to-file)
  (import (chezscheme)
          (sonic emit)
          (sonic gcmeta)
          (prefix (sonic encode-x86-64) x86:)
          (prefix (sonic vec-x86-64) vx:)
          (prefix (sonic encode-rv64) rv:))

  ;; --- targets --------------------------------------------------------------

  (define (check-target who t)
    (case t
      ((x86-64 rv64) t)
      (else (error who "unknown target" t))))

  (define (gcmeta-target-for t)
    (case (check-target 'gcmeta-target-for t)
      ((x86-64) target-x86-64)
      ((rv64)   target-rv64)))

  (define (target-id t)
    (case (check-target 'target-id t) ((x86-64) 1) ((rv64) 2)))

  (define (target-of-id n)
    (case n ((1) 'x86-64) ((2) 'rv64)
      (else (error 'image-target "unknown target id in a function image" n))))

  ;; EM_X86_64 and EM_RISCV. The RISC-V value is 243, not 62 plus something
  ;; memorable; getting it wrong makes `ld` say "incompatible" and say nothing
  ;; about which side is wrong.
  (define (elf-machine t)
    (case (check-target 'elf-machine t) ((x86-64) 62) ((rv64) 243)))

  ;; EF_RISCV_FLOAT_ABI_DOUBLE. This must match the ABI of the objects we link
  ;; against, and lp64d is what riscv64-linux-gnu-gcc uses here. The RVC bit is
  ;; deliberately clear: we emit no compressed instructions, and it is not an
  ;; ABI bit, so a linker sees no conflict with a toolchain object that sets it.
  (define (elf-flags t)
    (case (check-target 'elf-flags t) ((x86-64) 0) ((rv64) #x4)))

  ;; --- little-endian scalars ------------------------------------------------
  ;; Both targets are little-endian, and RISC-V defines little-endian
  ;; instruction fetch regardless of the data endianness, so there is one
  ;; spelling here rather than a parameter nobody would ever set.

  (define (le n width)
    (let loop ((i 0) (acc '()))
      (if (= i width)
          (reverse acc)
          (loop (+ i 1) (cons (bitwise-and (ash n (* -8 i)) #xff) acc)))))

  (define (u16 n) (le n 2))
  (define (u32 n) (le n 4))
  (define (u64 n) (le n 8))

  (define (align-to n a) (* a (div (+ n (- a 1)) a)))

  (define (zeros n) (make-list n 0))

  (define (pad-to bytes n) (append bytes (zeros (- n (length bytes)))))

  ;; --- the constant pool ----------------------------------------------------
  ;;
  ;; Every entry is 8 bytes because every storage class this compiler has is 8
  ;; bytes: a double, a machine word and a tagged value all are. A flonum goes
  ;; in as its IEEE754 bit pattern and an exact integer as a two's complement
  ;; word, which is the same distinction Lmach's storage classes already draw.

  ;; A bytevector passes through untouched.
  ;;
  ;; litpool.ss owns the pool's byte layout -- entry sizes, alignment, and the
  ;; padding, which it zeroes deliberately so two builds of the same program
  ;; produce the same bytes. A 16-byte sign mask is not eight bytes and its
  ;; datum is the SYMBOL `neg` rather than a number, so re-deriving the layout
  ;; from a list of values here cannot work and should not be attempted. Callers
  ;; with a real pool pass `pool-bytes`; the list form remains for fixtures.
  (define (constants->bytevector consts)
    (if (bytevector? consts)
        consts
        (constants-list->bytevector consts)))

  (define (constants-list->bytevector consts)
    (let* ((n (length consts))
           (bv (make-bytevector (* 8 n) 0)))
      (let loop ((cs consts) (i 0))
        (cond
         ((null? cs) bv)
         (else
          (let ((c (car cs)))
            (cond
             ((flonum? c) (bytevector-ieee-double-set! bv i c (endianness little)))
             ((and (integer? c) (exact? c))
              (bytevector-u64-set! bv i (bitwise-and c #xffffffffffffffff)
                                   (endianness little)))
             (else (error 'constants->bytevector
                          "a constant pool entry must be a flonum or an exact integer"
                          c)))
            (loop (cdr cs) (+ i 8))))))))

  ;; --- encoding, with labels ------------------------------------------------
  ;;
  ;; A listing is a list whose elements are either a bare symbol (a label
  ;; definition) or a target instruction. Selection produces `(label L)`
  ;; operands on x86-64 and bare symbol operands on RV64, and neither encoder
  ;; will touch one: both say, correctly, that resolving them is the caller's
  ;; job. This is the caller.
  ;;
  ;; Two passes and no relaxation fixpoint. RV64 is fixed-width. On x86-64 this
  ;; encoder spells every branch and call with a 32-bit displacement, so a
  ;; label's value cannot change an instruction's length either. Adding a short
  ;; form later turns this into a fixpoint, which is the reason to note now that
  ;; it is not one.

  (define (x86-label? o) (and (pair? o) (eq? (car o) 'label)))

  ;; Sizing pass: every label becomes a placeholder of the SAME encoded width
  ;; it will have once resolved. A RIP displacement is always disp32, so 0 is
  ;; the right stand-in; a branch is always rel32 for the same reason.
  (define (x86-blank i)
    (map (lambda (o)
           (cond
            ((x86-label? o) '(rel 0))
            ((and (pair? o) (eq? (car o) 'mem) (eq? (cadr o) 'rip)
                  (pair? (list-ref o 4)) (eq? (car (list-ref o 4)) 'label))
             (list 'mem 'rip #f (cadddr o) 0))
            (else o)))
         i))

  (define (object-instruction-size target i) (instruction-size target i))

  ;; ONE ENCODER PER MNEMONIC, and the vector one wins where both have it.
  ;;
  ;; x86-64 has two encoders and they overlap. encode-x86-64.ss grew the packed
  ;; forms when slp.ss needed them and is 128-bit only -- its own comment says
  ;; "a 256-bit form would be a different mnemonic and a different lane count,
  ;; which is why the width is not a parameter here". vec-x86-64.ss was written
  ;; for the loop vectorizer and dispatches width across xmm/ymm/zmm, selects
  ;; EVEX, and now carries masking.
  ;;
  ;; Two implementations of one instruction is the hazard vex.ss's header names
  ;; about the prefix BYTES, one level up: they must agree to the bit, and the
  ;; differential test against gas is only meaningful if there is one thing
  ;; under test. Measured before switching -- every packed instruction in a full
  ;; nbody compile, 155 of them, encoded identically under both -- so this
  ;; changes no byte in the image today. What it changes is that the emitted
  ;; path can now reach a width and a mask, which is what (x,y,z,pad) needs.
  ;;
  ;; The scalar encoder keeps everything the vector one does not claim,
  ;; including `vmovddup` and the legacy SSE `xorpd`/`andpd` that carry no VEX
  ;; prefix at all.
  (define (x86-encode i)
    (if (and (pair? i) (symbol? (car i)) (vx:vec-supports? (car i)))
        (vx:vec-encode-instr i)
        (x86:encode-instr i)))

  (define (instruction-size target i)
    (case (check-target 'instruction-size target)
      ((x86-64) (length (x86-encode (x86-blank i))))
      ((rv64)   4)))

  (define (encode-instruction target i)
    (case (check-target 'encode-instruction target)
      ((x86-64) (x86-encode i))
      ((rv64)   (rv:encode-instr i))))

  ;; RV64 branch and jump targets are the last operand and are relative to the
  ;; instruction itself; x86-64 displacements are relative to the END of the
  ;; instruction. Getting that difference backwards is a wrong-target branch
  ;; that assembles cleanly, so the two cases are written out rather than
  ;; unified behind a sign.
  (define rv-branchy '(beq bne blt bge bltu bgeu jal))

  (define (substitute target i pc size labels)
    (define (at name)
      (or (hashtable-ref labels name #f)
          (error 'resolve-labels "undefined label" name i)))
    (case target
      ((x86-64)
       (map (lambda (o)
              (cond
               ((x86-label? o) `(rel ,(- (at (cadr o)) (+ pc size))))
               ;; A RIP-relative memory operand whose displacement is a LABEL
               ;; rather than a number. This is how a pooled constant reaches
               ;; its data: the selector cannot know the address, so it emits
               ;; the pool entry's label and the displacement is computed here,
               ;; from the END of the instruction, which is what RIP holds.
               ;;
               ;; Without this the displacement stayed at the pool OFFSET --
               ;; correct only if the pool happened to sit at address zero
               ;; relative to the next instruction, which it never does. The
               ;; program assembled and read the wrong eight bytes.
               ((and (pair? o) (eq? (car o) 'mem) (eq? (cadr o) 'rip)
                     (pair? (list-ref o 4)) (eq? (car (list-ref o 4)) 'label))
                (list 'mem 'rip #f (cadddr o)
                      (- (at (cadr (list-ref o 4))) (+ pc size))))
               (else o)))
            i))
      ((rv64)
       (if (memq (car i) rv-branchy)
           (let* ((n (length i)) (t (list-ref i (- n 1))))
             (if (symbol? t)
                 (append (list-head i (- n 1)) (list (- (at t) pc)))
                 i))
           i))))

  ;; -> a list of instructions with every label resolved, in listing order.
  (define resolve-labels
    (case-lambda
      ((target listing) (resolve-labels target listing '() #f))
      ((target listing extra) (resolve-labels* target listing extra #f))
      ;; `size` lets the VECTOR path in: label resolution derives an address
      ;; from the sizes of the instructions before it, and sizing goes through
      ;; the scalar encoder, which refuses VEX by name. See the `encoder` option
      ;; on `assemble-function` for why that refusal stays the default.
      ((target listing extra size) (resolve-labels* target listing extra size))))

  ;; `extra` is ((name . offset-past-the-code) ...): labels for data that is
  ;; emitted AFTER the instructions and therefore has no position in the
  ;; listing. The constant pool is the case -- a pooled double is referenced
  ;; RIP-relative from inside the code and lives immediately past it -- and it
  ;; cannot be spelled as a listing entry, because the resolver derives a
  ;; label's address from the sizes of the instructions before it and a
  ;; constant is not an instruction.
  ;; --- RV64 branch relaxation ----------------------------------------------
  ;;
  ;; A B-type conditional branch reaches +/-4KiB. `jal` reaches +/-1MiB. nbody
  ;; is 6KB of code, so a branch across the middle of it does not fit, and the
  ;; encoder correctly refuses rather than truncating the displacement.
  ;;
  ;; The fix is the standard one: invert the condition and branch over an
  ;; unconditional jump.
  ;;
  ;;     blt a, b, far        becomes    bge a, b, .skip
  ;;                                     jal zero, far
  ;;                                     .skip:
  ;;
  ;; It has to ITERATE. Expanding one branch moves everything after it, which
  ;; can push a second branch out of range, and expanding that moves things
  ;; again. Displacements only grow, so it settles -- but assuming one pass is
  ;; how a relaxer emits an out-of-range branch on the second-largest function
  ;; in a program.
  (define rv-invert
    '((beq . bne) (bne . beq) (blt . bge) (bge . blt)
      (bltu . bgeu) (bgeu . bltu)))

  (define (rv-branch-range? d) (and (<= -4096 d 4094) (even? d)))

  (define (relax-rv64 listing)
    (define (label-positions xs)
      (let ((h (make-eq-hashtable)))
        (let loop ((xs xs) (pc 0))
          (cond ((null? xs) h)
                ((symbol? (car xs)) (hashtable-set! h (car xs) pc) (loop (cdr xs) pc))
                (else (loop (cdr xs) (+ pc 4)))))))
    (let pass ((xs listing) (n 0))
      (when (> n 20)
        (error 'relax-rv64 "branch relaxation did not settle" n))
      (let* ((pos (label-positions xs))
             (changed #f)
             (out
              (let loop ((ys xs) (pc 0) (acc '()))
                (cond
                 ((null? ys) (reverse acc))
                 ((symbol? (car ys)) (loop (cdr ys) pc (cons (car ys) acc)))
                 (else
                  (let* ((i (car ys))
                         (t (and (memq (car i) rv-branchy)
                                 (let ((x (list-ref i (- (length i) 1))))
                                   (and (symbol? x) x))))
                         (target (and t (hashtable-ref pos t #f))))
                    (if (and target (assq (car i) rv-invert)
                             (not (rv-branch-range? (- target pc))))
                        (let ((skip (string->symbol
                                     (string-append "%relax" (number->string pc)))))
                          (set! changed #t)
                          (loop (cdr ys) (+ pc 8)
                                (cons skip
                                      (cons `(jal zero ,t)
                                            (cons (append
                                                   (list (cdr (assq (car i) rv-invert)))
                                                   (list-head (cdr i) (- (length i) 2))
                                                   (list skip))
                                                  acc)))))
                        (loop (cdr ys) (+ pc 4) (cons i acc)))))))))
        (if changed (pass out (+ n 1)) out))))

  (define (resolve-labels* target listing extra size-of)
    ;; Shadows the module-level sizer so the vector path can supply its own.
    ;; Defined before any expression, because internal definitions must come
    ;; first and `check-target` is an expression.
    (define (instruction-size target i)
      (if size-of (size-of i) (object-instruction-size target i)))
    (check-target 'resolve-labels target)
    (let ((labels (make-eq-hashtable))
          (listing (if (eq? target 'rv64) (relax-rv64 listing) listing)))
      (let pass1 ((xs listing) (pc 0))
        (cond ((null? xs) 'done)
              ((symbol? (car xs))
               (when (hashtable-ref labels (car xs) #f)
                 (error 'resolve-labels "label defined twice" (car xs)))
               (hashtable-set! labels (car xs) pc)
               (pass1 (cdr xs) pc))
              (else (pass1 (cdr xs) (+ pc (instruction-size target (car xs)))))))
      ;; The code's total size is where the trailing data begins.
      (let ((code-size
             (let count ((xs listing) (pc 0))
               (cond ((null? xs) pc)
                     ((symbol? (car xs)) (count (cdr xs) pc))
                     (else (count (cdr xs) (+ pc (instruction-size target (car xs)))))))))
        (for-each (lambda (p)
                    (when (hashtable-ref labels (car p) #f)
                      (error 'resolve-labels "label defined twice" (car p)))
                    (hashtable-set! labels (car p) (+ code-size (cdr p))))
                  extra))
      (let pass2 ((xs listing) (pc 0) (acc '()))
        (cond ((null? xs) (reverse acc))
              ((symbol? (car xs)) (pass2 (cdr xs) pc acc))
              (else
               (let ((size (instruction-size target (car xs))))
                 (pass2 (cdr xs) (+ pc size)
                        (cons (substitute target (car xs) pc size labels) acc))))))))

  ;; --- the function object --------------------------------------------------

  (define-record-type (function-object make-function-object function-object?)
    (fields name target code constants metadata entries frame-slots image elf))

  ;; `opts` is an alist so this does not grow a seventh positional argument
  ;; every time codegen learns something new:
  ;;
  ;;   (constants . (<flonum or exact integer> ...))
  ;;   (frame-bits . (<boolean> ...))   one per stack slot, set if it is tagged
  ;;   (state-of . (lambda (instr index) -> flags alist or #f))
  ;;
  ;; `state-of` returning #f means "inherit", which is what a step function
  ;; wants for the overwhelming majority of instructions. Returning an alist
  ;; changes what the collector should believe from that instruction on, and
  ;; sonic/src/sonic/gcmeta.ss drops the entry again if it says the same thing
  ;; as its predecessor. Emit verbosely, let the encoder decide.
  (define assemble-function
    (case-lambda
      ((target name listing) (assemble-function target name listing '()))
      ((target name listing opts)
       (check-target 'assemble-function target)
       (let* ((opt (lambda (k d) (let ((p (assq k opts))) (if p (cdr p) d))))
              (consts (opt 'constants '()))
              (frame-bits (opt 'frame-bits '()))
              ;; PER-FUNCTION FRAME BITS, as (instruction-index . bits) in
              ;; order. `frame-bits` alone describes ONE frame, and driver.ss
              ;; assembles the whole program as a single listing, so every
              ;; procedure in it has a different frame and a different spill
              ;; set. The emitter's field is mutable precisely so it can be
              ;; re-pointed as emission crosses from one function into the
              ;; next; this option says where those crossings are.
              ;;
              ;; Indices rather than labels because `resolve-labels` hands back
              ;; instructions with the labels already consumed, and the caller
              ;; knows the boundaries anyway -- it built the listing by
              ;; appending one function's listing to the next.
              (frame-bits-at (opt 'frame-bits-at '()))
              (state-of (opt 'state-of (lambda (i n) #f)))
              ;; The ENCODER, supplied by the caller for the vector path.
              ;;
              ;; encode-x86-64.ss refuses every VEX-shaped mnemonic by name, and
              ;; that refusal is a correctness property rather than a scope
              ;; note: the scalar back end is the side of the differential
              ;; oracle that has to round exactly like baseline, so a packed
              ;; instruction reaching it is a bug. vec-x86-64.ss and vec-rv64.ss
              ;; therefore carry their own encoders.
              ;;
              ;; Passing one in here keeps that split intact -- the default is
              ;; still the refusing encoder, and only a caller holding a vector
              ;; plan can ask for the other one -- while letting a vector
              ;; listing become a real object that binutils can read back. That
              ;; readback is the whole of the milestone's evidence.
              (encode (opt 'encoder (lambda (i) (encode-instruction target i))))
              ;; SIZING IS NOT ENCODING, and on a target with labels the two
              ;; cannot be the same function. Label resolution sizes every
              ;; instruction to find each label's address, and it does that
              ;; BEFORE substituting displacements -- so a sizer that encodes
              ;; would be handed `(bne a2 zero Lvec)` with the label still a
              ;; symbol, and the encoder is right to refuse that. RV64 is fixed
              ;; width so its sizer is a constant; x86-64's vector encoder can
              ;; measure an instruction whose operands are all resolved, which
              ;; on that target they are, because its only label operands are
              ;; branches this path does not emit.
              (size (opt 'sizer #f))
              (instrs (resolve-labels target listing (opt 'extra-labels '())
                                      (or size
                                          (and (assq 'encoder opts)
                                               (lambda (i) (length (encode i)))))))
              (e (make-emitter (gcmeta-target-for target) frame-bits)))
         (let loop ((is instrs) (n 0) (fb frame-bits-at))
           (unless (null? is)
             (let ((fb (if (and (pair? fb) (= n (car (car fb))))
                           (begin (emitter-frame-bits-set! e (cdr (car fb)))
                                  (cdr fb))
                           fb)))
               (let ((bytes (encode (car is)))
                     (flags (state-of (car is) n)))
                 (if flags (emit! e bytes flags) (emit! e bytes)))
               (loop (cdr is) (+ n 1) fb))))
         (let* ((f (finish-function e name))
                (code (function-code f))
                (meta (function-metadata f))
                (pool (constants->bytevector consts))
                (img (build-image target code pool meta (function-frame-slots f))))
           (make-function-object
            name target code pool meta
            (decode-metadata (gcmeta-target-for target) meta)
            (function-frame-slots f)
            img
            (build-elf target name code pool meta)))))))

  ;; --- the image ------------------------------------------------------------

  (define image-header-size 24)
  (define image-magic '(#x53 #x4e #x49 #x43))   ; "SNIC"
  (define image-version 1)

  (define (build-image target code pool meta frame-slots)
    (let* ((cs (bytevector-length code))
           (ps (bytevector-length pool))
           (ms (bytevector-length meta))
           (pool-at (align-to (+ image-header-size cs) 8))
           (meta-at (align-to (+ pool-at ps) 8))
           (total (+ meta-at ms))
           (header (append image-magic
                           (u16 image-version)
                           (u16 (target-id target))
                           (u32 cs) (u32 ps) (u32 ms) (u32 frame-slots)))
           (bv (make-bytevector total 0)))
      (let blit ((bs header) (i 0))
        (unless (null? bs)
          (bytevector-u8-set! bv i (car bs))
          (blit (cdr bs) (+ i 1))))
      (bytevector-copy! code 0 bv image-header-size cs)
      (bytevector-copy! pool 0 bv pool-at ps)
      (bytevector-copy! meta 0 bv meta-at ms)
      bv))

  ;; The decoder half. Deliberately reconstructs the offsets by the same
  ;; arithmetic the collector would rather than reading them from anywhere, so
  ;; that a layout change breaks these and not just the collector.

  (define (image-check! bv)
    (when (< (bytevector-length bv) image-header-size)
      (error 'image "too short to be a function image" (bytevector-length bv)))
    (let loop ((ms image-magic) (i 0))
      (unless (null? ms)
        (unless (= (bytevector-u8-ref bv i) (car ms))
          (error 'image "bad magic: this is not a function image" i))
        (loop (cdr ms) (+ i 1))))
    (let ((v (bytevector-u16-ref bv 4 (endianness little))))
      (unless (= v image-version)
        (error 'image "unknown function image version" v)))
    bv)

  (define (image-field bv off) (bytevector-u32-ref bv off (endianness little)))

  (define (image-target bv)
    (image-check! bv)
    (target-of-id (bytevector-u16-ref bv 6 (endianness little))))

  (define (image-frame-slots bv) (image-check! bv) (image-field bv 20))

  (define (image-code bv)
    (image-check! bv)
    (let ((cs (image-field bv 8)))
      (bytevector-copy-part bv image-header-size cs)))

  (define (image-constants bv)
    (image-check! bv)
    (let* ((cs (image-field bv 8)) (ps (image-field bv 12))
           (at (align-to (+ image-header-size cs) 8)))
      (bytevector-copy-part bv at ps)))

  (define (image-metadata bv)
    (image-check! bv)
    (let* ((cs (image-field bv 8)) (ps (image-field bv 12)) (ms (image-field bv 16))
           (pool-at (align-to (+ image-header-size cs) 8))
           (meta-at (align-to (+ pool-at ps) 8)))
      (bytevector-copy-part bv meta-at ms)))

  (define (image-metadata-entries bv)
    (decode-metadata (gcmeta-target-for (image-target bv)) (image-metadata bv)))

  (define (bytevector-copy-part bv start n)
    (let ((out (make-bytevector n 0)))
      (bytevector-copy! bv start out 0 n)
      out))

  ;; --- ELF64 ----------------------------------------------------------------
  ;;
  ;; One relocatable object. Section header table only; no program headers,
  ;; because ET_REL is not loadable and inventing segments for it would be
  ;; decoration. `.sonic.meta` is unallocated: it is for objdump and for us, not
  ;; for the runtime, which reads the image instead.

  (define (string->bytes s) (map char->integer (string->list s)))

  ;; name type flags addralign entsize link info, plus the data.
  (define (section-spec name type flags align entsize link info data)
    (list name type flags align entsize link info data))

  (define (write-bytevector-to-file bv path)
    (when (file-exists? path) (delete-file path))
    (let ((p (open-file-output-port path)))
      (put-bytevector p bv)
      (close-port p))
    path)

  ;; --- .riscv.attributes -----------------------------------------------------
  ;;
  ;; WITHOUT THIS, binutils will not decode our vector instructions. objdump
  ;; reads `Tag_RISCV_arch` to decide which extensions exist, and an object that
  ;; does not say `v1p0` gets every RVV instruction printed as `.insn 4, 0x...`
  ;; -- a raw word, not a mnemonic.
  ;;
  ;; That is not cosmetic. disasm.ss's whole premise is that the milestone is
  ;; checked by an independent reading, and a predicate looking for packed
  ;; arithmetic in a stream of `.insn` finds none. The scalar RV64 output never
  ;; needed the section because base instructions decode without it, which is
  ;; why this was missing until the first vector object was built.
  ;;
  ;; Layout, from the RISC-V ELF psABI:
  ;;
  ;;   'A'                      format version
  ;;   u32                      length of this subsection, counting itself
  ;;   "riscv\0"                vendor
  ;;   1                        Tag_File
  ;;   u32                      length of this sub-subsection, counting itself
  ;;   5                        Tag_RISCV_arch (uleb128; 5 is one byte)
  ;;   "<arch>\0"               the extension string
  ;;
  ;; The arch string is the one gas itself emits for `-march=rv64gcv`. Writing a
  ;; shorter hand-rolled one risks binutils' parser rejecting a version it does
  ;; not recognise, and a rejected attributes section decodes as `.insn` again --
  ;; the same failure, with a more confusing cause.
  (define riscv-arch-string
    "rv64i2p0_m2p0_a2p0_f2p0_d2p0_c2p0_v1p0_zmmul1p0_zaamo1p0_zalrsc1p0_zca1p0_zcd1p0_zve32f1p0_zve32x1p0_zve64d1p0_zve64f1p0_zve64x1p0_zvl128b1p0_zvl32b1p0_zvl64b1p0")

  (define (riscv-attributes)
    (let* ((arch (append (string->bytes riscv-arch-string) '(0)))
           (subsub (append '(1) (u32 (+ 1 4 1 (length arch))) '(5) arch))
           (vendor (append (string->bytes "riscv") '(0)))
           (sub (append (u32 (+ 4 (length vendor) (length subsub))) vendor subsub)))
      (append '(#x41) sub)))

  (define (build-elf target name code pool meta)
    (let* ((fname (symbol->string name))
           ;; string tables. Offset 0 is the empty name by definition, which is
           ;; what a section or symbol with no name points at.
           (strtab (append '(0) (string->bytes fname) '(0)))
           (rv64? (eq? target 'rv64))
           ;; Section indices are 1-based past the null section 0, in the order
           ;; `sh-names` lists them.
           (strtab-index (if rv64? 7 6))
           (sh-names (append '(".text" ".rodata" ".sonic.meta" ".note.GNU-stack")
                             (if rv64? '(".riscv.attributes") '())
                             '(".symtab" ".strtab" ".shstrtab")))
           (shstrtab-pairs
            (let loop ((ns sh-names) (at 1) (acc '()))
              (if (null? ns)
                  (reverse acc)
                  (loop (cdr ns) (+ at (string-length (car ns)) 1)
                        (cons (cons (car ns) at) acc)))))
           (shstrtab
            (append '(0)
                    (apply append
                           (map (lambda (n) (append (string->bytes n) '(0))) sh-names))))
           (sh-name-of (lambda (n) (cdr (assoc n shstrtab-pairs))))
           (code-size (bytevector-length code))
           ;; symbol 0 is the reserved null entry; symbol 1 is the function,
           ;; GLOBAL (bind 1) and FUNC (type 2), which is what puts a label on
           ;; objdump's disassembly.
           (symtab (append (zeros 24)
                           (u32 1) (list #x12) (list 0) (u16 1)
                           (u64 0) (u64 code-size)))
           (sections
            (append
             (list
              ;; SHT_PROGBITS=1, SHF_ALLOC=2, SHF_EXECINSTR=4
              (section-spec (sh-name-of ".text") 1 6 16 0 0 0 (bytevector->u8-list code))
              (section-spec (sh-name-of ".rodata") 1 2 8 0 0 0 (bytevector->u8-list pool))
              (section-spec (sh-name-of ".sonic.meta") 1 0 1 0 0 0 (bytevector->u8-list meta))
              ;; Zero-size and unexecutable, purely so the linker does not decide
              ;; the program wants an executable stack.
              (section-spec (sh-name-of ".note.GNU-stack") 1 0 1 0 0 0 '()))
             ;; SHT_RISCV_ATTRIBUTES = 0x70000003, processor-specific by
             ;; definition, so it is emitted only on the target that has one.
             (if rv64?
                 (list (section-spec (sh-name-of ".riscv.attributes")
                                     #x70000003 0 1 0 0 0 (riscv-attributes)))
                 '())
             (list
              ;; SHT_SYMTAB=2. sh_link is the string table's index and sh_info
              ;; is the index of the first non-local symbol, which the linker
              ;; uses to find the local/global boundary. Both are hard errors if
              ;; wrong and silent ones if merely plausible.
              ;; sh_link DERIVED, not written down. It was the literal 6, which
              ;; is `.strtab`'s index -- correct until `.riscv.attributes` was
              ;; inserted ahead of it and moved every later section up one. The
              ;; comment above calls a wrong sh_link a hard error that looks
              ;; plausible; leaving a literal here would have made it one.
              (section-spec (sh-name-of ".symtab") 2 0 8 24 strtab-index 1 symtab)
              (section-spec (sh-name-of ".strtab") 3 0 1 0 0 0 strtab)
              (section-spec (sh-name-of ".shstrtab") 3 0 1 0 0 0 shstrtab))))
           (shnum (+ 1 (length sections)))
           (shstrndx (- shnum 1)))
      ;; Place each section's data after the ELF header, honouring its
      ;; alignment, then the section header table 8-aligned after all of them.
      (let place ((ss sections) (at 64) (placed '()))
        (if (null? ss)
            (let* ((shoff (align-to at 8))
                   (pre-sht-pad (- shoff at))
                   (ehdr (append '(#x7f #x45 #x4c #x46 2 1 1 0) (zeros 8)
                                 (u16 1)                      ; ET_REL
                                 (u16 (elf-machine target))
                                 (u32 1)                      ; EV_CURRENT
                                 (u64 0) (u64 0) (u64 shoff)
                                 (u32 (elf-flags target))
                                 (u16 64) (u16 0) (u16 0)
                                 (u16 64) (u16 shnum) (u16 shstrndx)))
                   (body
                    (apply append
                           (map (lambda (p) (append (zeros (car p)) (cadr p)))
                                (reverse placed))))
                   (null-shdr (zeros 64))
                   (shdrs
                    (apply append
                           (map (lambda (s p)
                                  (append (u32 (list-ref s 0))    ; sh_name
                                          (u32 (list-ref s 1))    ; sh_type
                                          (u64 (list-ref s 2))    ; sh_flags
                                          (u64 0)                 ; sh_addr
                                          (u64 (caddr p))         ; sh_offset
                                          (u64 (length (list-ref s 7)))
                                          (u32 (list-ref s 5))    ; sh_link
                                          (u32 (list-ref s 6))    ; sh_info
                                          (u64 (list-ref s 3))    ; sh_addralign
                                          (u64 (list-ref s 4))))  ; sh_entsize
                                sections (reverse placed)))))
              (u8-list->bytevector
               (append ehdr body (zeros pre-sht-pad) null-shdr shdrs)))
            (let* ((s (car ss))
                   (align (max 1 (list-ref s 3)))
                   (start (align-to at align))
                   (pad (- start at))
                   (data (list-ref s 7)))
              (place (cdr ss) (+ start (length data))
                     (cons (list pad data start) placed)))))))
  )
