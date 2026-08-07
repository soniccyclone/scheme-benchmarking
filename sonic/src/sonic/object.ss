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

  (define (x86-blank i)
    (map (lambda (o) (if (x86-label? o) '(rel 0) o)) i))

  (define (instruction-size target i)
    (case (check-target 'instruction-size target)
      ((x86-64) (length (x86:encode-instr (x86-blank i))))
      ((rv64)   4)))

  (define (encode-instruction target i)
    (case (check-target 'encode-instruction target)
      ((x86-64) (x86:encode-instr i))
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
       (map (lambda (o) (if (x86-label? o) `(rel ,(- (at (cadr o)) (+ pc size))) o)) i))
      ((rv64)
       (if (memq (car i) rv-branchy)
           (let* ((n (length i)) (t (list-ref i (- n 1))))
             (if (symbol? t)
                 (append (list-head i (- n 1)) (list (- (at t) pc)))
                 i))
           i))))

  ;; -> a list of instructions with every label resolved, in listing order.
  (define (resolve-labels target listing)
    (check-target 'resolve-labels target)
    (let ((labels (make-eq-hashtable)))
      (let pass1 ((xs listing) (pc 0))
        (cond ((null? xs) 'done)
              ((symbol? (car xs))
               (when (hashtable-ref labels (car xs) #f)
                 (error 'resolve-labels "label defined twice" (car xs)))
               (hashtable-set! labels (car xs) pc)
               (pass1 (cdr xs) pc))
              (else (pass1 (cdr xs) (+ pc (instruction-size target (car xs)))))))
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
              (state-of (opt 'state-of (lambda (i n) #f)))
              (instrs (resolve-labels target listing))
              (e (make-emitter (gcmeta-target-for target) frame-bits)))
         (let loop ((is instrs) (n 0))
           (unless (null? is)
             (let ((bytes (encode-instruction target (car is)))
                   (flags (state-of (car is) n)))
               (if flags (emit! e bytes flags) (emit! e bytes)))
             (loop (cdr is) (+ n 1))))
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

  (define (build-elf target name code pool meta)
    (let* ((fname (symbol->string name))
           ;; string tables. Offset 0 is the empty name by definition, which is
           ;; what a section or symbol with no name points at.
           (strtab (append '(0) (string->bytes fname) '(0)))
           (sh-names '(".text" ".rodata" ".sonic.meta" ".note.GNU-stack"
                       ".symtab" ".strtab" ".shstrtab"))
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
            (list
             ;; SHT_PROGBITS=1, SHF_ALLOC=2, SHF_EXECINSTR=4
             (section-spec (sh-name-of ".text") 1 6 16 0 0 0 (bytevector->u8-list code))
             (section-spec (sh-name-of ".rodata") 1 2 8 0 0 0 (bytevector->u8-list pool))
             (section-spec (sh-name-of ".sonic.meta") 1 0 1 0 0 0 (bytevector->u8-list meta))
             ;; Zero-size and unexecutable, purely so the linker does not decide
             ;; the program wants an executable stack.
             (section-spec (sh-name-of ".note.GNU-stack") 1 0 1 0 0 0 '())
             ;; SHT_SYMTAB=2. sh_link is the string table's index and sh_info is
             ;; the index of the first non-local symbol, which the linker uses
             ;; to find the local/global boundary. Both are hard errors if wrong
             ;; and silent ones if merely plausible.
             (section-spec (sh-name-of ".symtab") 2 0 8 24 6 1 symtab)
             (section-spec (sh-name-of ".strtab") 3 0 1 0 0 0 strtab)
             (section-spec (sh-name-of ".shstrtab") 3 0 1 0 0 0 shstrtab)))
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
