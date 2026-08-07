;;; Per-function literal pool.
;;;
;;; E2, bead 6gk.13. Both back ends reported the same wall independently, which
;;; is usually the sign that the gap is in the contract rather than in either
;;; implementation. It is.
;;;
;;; ## What is actually missing
;;;
;;; `Lmach`'s `(const v sc d)` names ONE destination register. For a fixnum on
;;; either target that is enough: the value goes in an integer register by
;;; `movabs` or by `lui`/`addi`, done. For an f64 it is not enough, and the two
;;; targets fail in different ways for the same underlying reason.
;;;
;;;   - RV64 has no instruction that materializes an arbitrary double into an
;;;     FPR from an immediate. The routes are `fmv.d.x fd, rs` and `fcvt.d.l fd,
;;;     rs`, and both READ AN INTEGER REGISTER. `const` gives one destination
;;;     and it is the float one, so there is nowhere to stage the bit pattern.
;;;     That is why both encodings sit in `encode-rv64.ss`, encodable and
;;;     unreachable: no selection rule can produce a use for them.
;;;
;;;   - x86-64 can reach an XMM from an integer register with `movq`, so `const`
;;;     is survivable there, but `flabs` and `flneg` are not. The instructions
;;;     are `andpd`/`xorpd` against a 128-bit mask, and a 128-bit operand has no
;;;     immediate form at all. It MUST come from memory.
;;;
;;; The fix that covers both is the one every serious back end already has: a
;;; block of constant data with a known address, and PC-relative loads into it.
;;; RIP-relative on x86-64, `auipc` plus `fld` on RV64. Then `const` for an f64
;;; is one load and needs no second register, `flabs` is a load-free `andpd`
;;; against a pool slot, and `fcvt.d.l` goes back to meaning what it says
;;; (integer-to-float CONVERSION, for `fx->fl`) instead of being abused as a
;;; materialization path it cannot serve.
;;;
;;; ## Why -0.0 and 0.0 are not the same slot
;;;
;;; They are different bit patterns and the difference is observable.
;;; `bench/nbody/SPEC.md` procedure step 0 records why: `ref.c` writes `-px`,
;;; and `(fl- 0.0 px)` is not the same function. At `px = 0.0` the first gives
;;; `-0.0` and the second gives `0.0`, and the sign survives the division that
;;; follows. `lang.ss` spells that difference as a separate `flneg` primitive
;;; precisely so it cannot be lost, and interning by numeric equality would lose
;;; it again one layer down.
;;;
;;; So the intern key is the IEEE BIT PATTERN, via `numeric.ss`'s `fl-bits`.
;;; That is the only key that is right here, and it comes with two more
;;; properties for free: NaN interns with NaN (it is not `=` to itself), and a
;;; fixnum never collides with a flonum of the same value because the kinds are
;;; part of the key.
;;;
;;; Note what a plain `equal?` table would have done. Chez happens to
;;; distinguish `0.0` from `-0.0` under `eqv?`, so an `equal?` table would pass
;;; this test on this host and fail on a host that reads R6RS's "numerically
;;; equal and both inexact" the other way. Keying on bits does not depend on the
;;; host's opinion.
;;;
;;; ## Alignment is a correctness property, not tidiness
;;;
;;; `andpd xmm, m128` faults unless the memory operand is 16-byte aligned. So
;;; the sign masks want 16 and get it, doubles want 8 and get it, and the pool
;;; as a whole is placed on a 16-byte boundary so that the offsets computed here
;;; survive being added to the function's base address. Padding is emitted as
;;; zero bytes between entries, and there is none at the tail; the layout is
;;; deterministic and the test asserts the exact offsets rather than merely that
;;; they are aligned.
;;;
;;; ## Where the pool goes
;;;
;;; Code, then pool, then metadata. `emit.ss` says the metadata blob is appended
;;; after the code and located by arithmetic on the function header, so
;;; inserting the pool between them is one more term in that arithmetic and
;;; nothing else changes. The pool must not go after the metadata: the metadata
;;; is variable-length LEB128 whose size is not known until every entry is
;;; encoded, and a pool behind it would have an address that moves whenever a
;;; single flag bit changes. It must not go before the code either, because the
;;; function's entry point is its base address and every caller already knows
;;; that. Between is the only place left, and it is also the right one: the pool
;;; is within a small PC-relative displacement of the loads that read it, which
;;; is what makes `auipc` a 20-bit reach rather than a relocation problem.
;;;
;;; ## What this bead does NOT do
;;;
;;; Bead 6gk.13's description carries a second finding: `chk` names a check but
;;; not the EXPECTED TAG, so a type check has no constant to compare against.
;;; That needs an operand added to `Lmach`'s `chk` production in `lang.ss`, and
;;; a frozen inter-stage contract is not something to widen from inside a
;;; back-end support library. The pool is the half that can be built without
;;; touching the contract; `pool-intern-tag!` below is here so that the tag
;;; constant has a home the moment `chk` can name one.

(library (sonic litpool)
  (export current-litpool pool-label current-globals global-address
          make-pool pool?
          pool-intern! pool-intern-f64! pool-intern-i64!
          pool-intern-sign-mask! pool-intern-tag!
          pool-entries pool-size pool-align pool-bytes
          lit? lit-kind lit-key lit-offset lit-size lit-datum
          pool-entry-at pool-ref-f64 pool-ref-u64

          pool-alignment kind-size kind-align
          abs-mask-bits neg-mask-bits

          layout-function laid-out?
          laid-out-name laid-out-image
          laid-out-code-offset laid-out-code-size
          laid-out-pool-offset laid-out-pool-size
          laid-out-metadata-offset laid-out-metadata-size
          laid-out-frame-slots
          pool-entry-address rip-displacement)
  (import (chezscheme)
          (sonic numeric)
          (sonic emit))

  ;; --- kinds ----------------------------------------------------------------
  ;;
  ;; A kind fixes a width and an alignment. Three of them cover everything the
  ;; two back ends asked for, and the list is deliberately closed: an unknown
  ;; kind is an error rather than a default width, because a wrong width here
  ;; produces a pool that assembles and reads the neighbouring constant.
  ;;
  ;;   f64        one binary64                     8 bytes, align 8
  ;;   i64        one 64-bit integer word          8 bytes, align 8
  ;;   sign-mask  the 128-bit operand of andpd/xorpd, the same 64-bit pattern
  ;;              in both lanes                   16 bytes, align 16
  ;;
  ;; `sign-mask` is x86-64's shape and RV64 has no use for it, since `fsgnjx.d`
  ;; and `fsgnjn.d` do abs and neg in one instruction with no operand. It is
  ;; still a pool entry rather than a target-specific side table because the
  ;; pool is per function and the alignment interacts: a 16-byte entry present
  ;; on one target and absent on the other changes the offsets of everything
  ;; after it, and having one allocator own that arithmetic is the point.

  (define (kind-size k)
    (case k
      ((f64 i64) 8)
      ((sign-mask) 16)
      (else (error 'kind-size "unknown literal kind" k))))

  (define (kind-align k)
    (case k
      ((f64 i64) 8)
      ((sign-mask) 16)
      (else (error 'kind-align "unknown literal kind" k))))

  ;; The pool's own alignment is the widest entry alignment. Placing the pool
  ;; here means an entry's alignment within the pool IS its alignment in the
  ;; image, which is what lets the offsets be computed before the code size is
  ;; known to be a multiple of anything.
  (define pool-alignment 16)

  (define abs-mask-bits #x7fffffffffffffff)   ; andpd: clear the sign bit
  (define neg-mask-bits #x8000000000000000)   ; xorpd: flip the sign bit

  ;; --- entries --------------------------------------------------------------
  ;;
  ;; `key` is what the dedupe compares and `datum` is what the caller handed in.
  ;; They are separate fields on purpose: the key for an f64 is its bit pattern,
  ;; and keeping the original flonum around means a disassembly listing can
  ;; print `-0.0` rather than `9223372036854775808`.

  (define-record-type (lit make-lit lit?)
    (fields kind key offset size datum))

  (define-record-type (pool mk-pool pool?)
    (fields table                    ; key -> entry
            (mutable rev)            ; entries, newest first
            (mutable next)))         ; next free byte offset within the pool

  (define (make-pool) (mk-pool (make-hashtable equal-hash equal?) '() 0))

  (define (pool-entries p) (reverse (pool-rev p)))

  ;; Exactly the bytes used, with no tail padding. The metadata blob follows and
  ;; LEB128 has no alignment requirement, so padding here would buy nothing and
  ;; would make the pool's size depend on what comes after it, which is the one
  ;; property that stops a layout being computable in one pass.
  (define (pool-size p) (pool-next p))
  (define (pool-align p) pool-alignment)

  (define (align-up n a)
    (let ((r (modulo n a)))
      (if (zero? r) n (+ n (- a r)))))

  ;; --- interning ------------------------------------------------------------
  ;;
  ;; Returns a byte offset within the pool. The same constant asked for twice
  ;; returns the same offset and adds no bytes, which is the whole reason this
  ;; is a table rather than an append: a loop body that reads `0.5` in four
  ;; places should cost one slot and four identical PC-relative displacements.

  ;; The pool a selector is currently interning into.
  ;;
  ;; It lives here rather than in either target because BOTH need it and a
  ;; program has exactly one pool: a parameter owned by one back end would
  ;; leave the other silently interning into a different, unemitted pool.
  ;;
  ;; The default is a fresh pool so a unit test can select an instruction
  ;; without standing up an object file, but a real compilation parameterizes
  ;; it -- the pool has to be the same object `object.ss` later asks for the
  ;; bytes of, or the offsets the relocations carry name nothing.
  (define current-litpool (make-parameter (make-pool)))

  ;; The label naming a pool entry's address.
  ;;
  ;; A selector cannot know where the pool lands, so it emits this and the
  ;; assembler computes the displacement -- the same mechanism a branch target
  ;; uses. Emitting the raw OFFSET instead, which is what this used to do, is
  ;; correct only if the pool happens to sit at address zero relative to the
  ;; next instruction, so the program assembled and read the wrong eight bytes.
  (define (pool-label off)
    (string->symbol (string-append "%pool+" (number->string off))))

  ;; Where each top-level binding's cell lives: cell name -> absolute address.
  ;;
  ;; Absolute rather than RIP-relative because the cells are in the WRITABLE
  ;; segment and the code is not, so the two are megabytes apart and the
  ;; displacement would depend on the final layout. The addresses are fixed by
  ;; the driver before selection, which is the same shape as `current-litpool`:
  ;; the selector cannot know a layout it does not own.
  (define current-globals (make-parameter #f))

  (define (global-address name)
    (let ((tbl (current-globals)))
      (unless tbl
        (error 'global-address
               "no global layout is in effect; the driver must parameterize `current-globals` before selection"
               name))
      (or (hashtable-ref tbl name #f)
          (error 'global-address "no cell was reserved for this global" name))))

  (define (pool-intern! p kind key datum)
    (let ((k (cons kind key)))
      (let ((hit (hashtable-ref (pool-table p) k #f)))
        (if hit
            (lit-offset hit)
            (let* ((size (kind-size kind))
                   (off (align-up (pool-next p) (kind-align kind)))
                   (e (make-lit kind key off size datum)))
              (pool-next-set! p (+ off size))
              (pool-rev-set! p (cons e (pool-rev p)))
              (hashtable-set! (pool-table p) k e)
              off)))))

  ;; THE one that matters. `fl-bits` is the key, so 0.0 and -0.0 are two slots
  ;; and NaN is one slot with itself.
  (define (pool-intern-f64! p x)
    (unless (flonum? x) (error 'pool-intern-f64! "not a flonum" x))
    (pool-intern! p 'f64 (fl-bits x) x))

  ;; Integers are keyed on the value, taken modulo 2^64 so that a negative
  ;; fixnum and the unsigned word with the same bits are one slot. They ARE the
  ;; same 8 bytes; keying them apart would emit two.
  (define (pool-intern-i64! p n)
    (unless (and (integer? n) (exact? n)) (error 'pool-intern-i64! "not an exact integer" n))
    (let ((bits (bitwise-and n #xffffffffffffffff)))
      (pool-intern! p 'i64 bits n)))

  ;; `which` is 'abs or 'neg. Two distinct masks, and they never share a slot
  ;; because the keys differ; two `flabs` sites in one function do share one.
  (define (pool-intern-sign-mask! p which)
    (let ((bits (case which
                  ((abs) abs-mask-bits)
                  ((neg) neg-mask-bits)
                  (else (error 'pool-intern-sign-mask! "expected abs or neg" which)))))
      (pool-intern! p 'sign-mask bits which)))

  ;; The tag constant a type check compares against. `numeric.ss` fixes a 3-bit
  ;; primary tag with fixnum = 000; this puts that constant somewhere an
  ;; emitted `chk` could read it once `Lmach` can say which tag it means. See
  ;; the header: widening `chk` is not this bead's to do.
  (define (pool-intern-tag! p tag)
    (unless (and (integer? tag) (exact? tag) (<= 0 tag 7))
      (error 'pool-intern-tag! "a primary tag is three bits" tag))
    (pool-intern-i64! p tag))

  ;; --- the bytes ------------------------------------------------------------
  ;;
  ;; Little-endian on both targets. Padding is zero, which is not merely
  ;; cosmetic: a pool whose padding is uninitialized would make two builds of
  ;; the same function produce different images, and D24's bit-exact
  ;; cross-agreement is not a thing to give up for a few skipped stores.

  (define (pool-bytes p)
    (let ((bv (make-bytevector (pool-size p) 0)))
      (for-each
       (lambda (e)
         (let ((off (lit-offset e)) (bits (lit-key e)))
           (case (lit-kind e)
             ((f64 i64) (u64-set! bv off bits))
             ((sign-mask) (u64-set! bv off bits) (u64-set! bv (+ off 8) bits))
             (else (error 'pool-bytes "unknown literal kind" (lit-kind e))))))
       (pool-entries p))
      bv))

  (define (u64-set! bv off bits)
    (let loop ((i 0))
      (when (< i 8)
        (bytevector-u8-set! bv (+ off i)
                            (bitwise-and (bitwise-arithmetic-shift-right bits (* 8 i)) #xff))
        (loop (+ i 1)))))

  (define (u64-ref bv off)
    (let loop ((i 7) (acc 0))
      (if (< i 0)
          acc
          (loop (- i 1)
                (bitwise-ior (bitwise-arithmetic-shift-left acc 8)
                             (bytevector-u8-ref bv (+ off i)))))))

  (define (pool-entry-at p off)
    (let loop ((es (pool-entries p)))
      (cond ((null? es) #f)
            ((= (lit-offset (car es)) off) (car es))
            (else (loop (cdr es))))))

  ;; Read back what a load at this offset would fetch. The tests resolve
  ;; offsets through these rather than through the entry records, so what is
  ;; asserted is the BYTES the machine would see and not the bookkeeping.
  (define (pool-ref-u64 bv off) (u64-ref bv off))

  (define (pool-ref-f64 bv off)
    (let ((tmp (make-bytevector 8)))
      (let loop ((i 0))
        (when (< i 8)
          (bytevector-u8-set! tmp i (bytevector-u8-ref bv (+ off i)))
          (loop (+ i 1))))
      (bytevector-ieee-double-ref tmp 0 'little)))

  ;; --- layout ---------------------------------------------------------------
  ;;
  ;; code | pad | pool | metadata, in one image, with every offset stated.
  ;;
  ;; This does not modify `emit.ss`. It calls `finish-function` and places the
  ;; three pieces, so an emitter that has no constants produces an image
  ;; identical to today's code-then-metadata layout apart from the alignment
  ;; padding, and an emitter that has constants gets them at a computable
  ;; address without the emitter knowing anything about pools.

  (define-record-type (laid-out make-laid-out laid-out?)
    (fields name image
            code-offset code-size
            pool-offset pool-size
            metadata-offset metadata-size
            frame-slots))

  (define (layout-function e name p)
    (let* ((f (finish-function e name))
           (code (function-code f))
           (meta (function-metadata f))
           (pool (pool-bytes p))
           (csize (bytevector-length code))
           (psize (bytevector-length pool))
           (msize (bytevector-length meta))
           (poff (align-up csize pool-alignment))
           (moff (+ poff psize))
           (total (+ moff msize))
           (img (make-bytevector total 0)))
      (bytevector-copy! code 0 img 0 csize)
      (bytevector-copy! pool 0 img poff psize)
      (bytevector-copy! meta 0 img moff msize)
      (make-laid-out name img 0 csize poff psize moff msize
                     (function-frame-slots f))))

  ;; --- addressing -----------------------------------------------------------

  ;; Absolute address of a pool entry, given where the function was loaded.
  (define (pool-entry-address lo base off)
    (+ base (laid-out-pool-offset lo) off))

  ;; x86-64 RIP-relative displacement. RIP is the address of the NEXT
  ;; instruction, so the displacement is measured from the end of the
  ;; instruction that carries it, not from its start. Getting that backwards is
  ;; the classic way to read the constant before the one you meant.
  (define (rip-displacement lo off next-insn-offset)
    (- (+ (laid-out-pool-offset lo) off) next-insn-offset))
  )
