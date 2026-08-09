;;; The VEX and EVEX prefix bytes, in one place.
;;;
;;; Two files need these and they must agree to the bit. `vec-x86-64.ss` emits
;;; packed arithmetic; `encode-x86-64.ss` emits the THREE-ADDRESS SCALAR forms,
;;; which are the same instructions the SSE back end already has, encoded so
;;; that the destination need not alias a source.
;;;
;;; Keeping one copy is not tidiness. These bytes store five register-extension
;;; bits INVERTED, and a second implementation that inverted four of them would
;;; assemble cleanly and address the wrong registers. The differential test
;;; compares our bytes against gas's, and it is only meaningful if there is one
;;; thing under test.
;;;
;;; ## Why the scalar back end may emit VEX at all
;;;
;;; encode-x86-64.ss refuses VEX-shaped mnemonics, and that refusal is a
;;; correctness property rather than a scope note: D24 makes FP contraction a
;;; named permission that is off by default, and a fused multiply-add rounds
;;; differently from the reference C, which breaks the bit-exact oracle.
;;;
;;; The refusal is aimed at FUSION, and `vmulsd` is not fusion. It computes
;;; exactly what `movsd` + `mulsd` computes, to the bit, in one instruction
;;; instead of two -- the only difference is that VEX has a second source
;;; operand field, so the destination does not have to be one of the inputs.
;;; `vfmadd*` and `vfmsub*` stay refused, by name, because those are the ones
;;; that change the arithmetic.

(library (sonic vex)
  (export vex-bytes evex-bytes vex-pp vex-map)
  (import (chezscheme))

  ;; The legacy prefix, folded into the VEX byte: 1 = 66, 2 = F3, 3 = F2.
  (define (vex-pp p)
    (case p ((none) 0) ((#x66) 1) ((#xF3) 2) ((#xF2) 3)
      (else (error 'vex-pp "not a foldable legacy prefix" p))))

  ;; The opcode map: 1 = 0F, 2 = 0F 38, 3 = 0F 3A.
  (define (vex-map m)
    (case m ((#x0F) 1) ((#x0F38) 2) ((#x0F3A) 3)
      (else (error 'vex-map "not an opcode map" m))))

  ;; 2-byte VEX when nothing needs the third byte: no high rm register, no high
  ;; index, W = 0 and the 0F map. That is exactly gas's rule, and matching it is
  ;; what makes a byte comparison against gas meaningful rather than a
  ;; comparison of two arbitrary legal encodings.
  (define (vex-bytes r x b w vvvv l pp mp)
    (if (and (zero? x) (zero? b) (zero? w) (= mp 1))
        (list #xC5
              (bitwise-ior (bitwise-arithmetic-shift-left (- 1 r) 7)
                           (bitwise-arithmetic-shift-left
                            (bitwise-and (bitwise-not vvvv) #xf) 3)
                           (bitwise-arithmetic-shift-left l 2)
                           pp))
        (list #xC4
              (bitwise-ior (bitwise-arithmetic-shift-left (- 1 r) 7)
                           (bitwise-arithmetic-shift-left (- 1 x) 6)
                           (bitwise-arithmetic-shift-left (- 1 b) 5)
                           mp)
              (bitwise-ior (bitwise-arithmetic-shift-left w 7)
                           (bitwise-arithmetic-shift-left
                            (bitwise-and (bitwise-not vvvv) #xf) 3)
                           (bitwise-arithmetic-shift-left l 2)
                           pp))))

  ;; EVEX. Four bytes, and five of the register-extension bits in them are
  ;; stored INVERTED, which is the single most common way to get this wrong.
  ;;
  ;; The fourth byte is the one that carries masking:
  ;;
  ;;     bit 7    z     zeroing, rather than merging, the masked-off lanes
  ;;     6..5     L'L   vector length
  ;;     bit 4    b     broadcast / rounding control -- not used here
  ;;     bit 3    V'    the fifth vvvv bit, INVERTED like the others
  ;;     2..0     aaa   which of k1..k7 predicates this instruction
  ;;
  ;; `aaa` = 0 means k0, and k0 IS THE UNMASKED ENCODING rather than a register
  ;; that happens to read all ones. There is no way to write "predicate this on
  ;; k0"; the assembler rejects `{k0}` on a masked form for that reason, and it
  ;; is why a mask allocator may not hand out k0. regs.ss keeps it out of the
  ;; pool and says so there.
  ;;
  ;; The four-argument call is the unmasked one and stays exactly as it was:
  ;; every existing caller means aaa = 0, z = 0, and spelling that out at each
  ;; site would be noise that hides the sites that do mask.
  (define evex-bytes
    (case-lambda
      ((r r2 x b w vvvv v2 ll pp mp)
       (evex-bytes r r2 x b w vvvv v2 ll pp mp 0 0))
      ((r r2 x b w vvvv v2 ll pp mp aaa z)
       (unless (and (exact? aaa) (<= 0 aaa 7))
         (error 'evex-bytes "the mask selector is three bits" aaa))
       (unless (memv z '(0 1))
         (error 'evex-bytes "the zeroing bit is one bit" z))
       (when (and (= z 1) (= aaa 0))
         ;; Zeroing with no mask register zeroes every lane, which is a
         ;; constant, and no assembler will write it -- `{z}` without `{k}` is
         ;; a syntax error. Emitting it would produce bytes gas cannot read
         ;; back, so the differential test could never cover them.
         (error 'evex-bytes "zeroing needs a mask register; {z} without {k} is not an encoding" z))
       (list #x62
             (bitwise-ior (bitwise-arithmetic-shift-left (- 1 r) 7)
                          (bitwise-arithmetic-shift-left (- 1 x) 6)
                          (bitwise-arithmetic-shift-left (- 1 b) 5)
                          (bitwise-arithmetic-shift-left (- 1 r2) 4)
                          mp)
             (bitwise-ior (bitwise-arithmetic-shift-left w 7)
                          (bitwise-arithmetic-shift-left
                           (bitwise-and (bitwise-not vvvv) #xf) 3)
                          #b100
                          pp)
             (bitwise-ior (bitwise-arithmetic-shift-left z 7)
                          (bitwise-arithmetic-shift-left ll 5)
                          (bitwise-arithmetic-shift-left (- 1 v2) 3)
                          aaa)))))
  )
