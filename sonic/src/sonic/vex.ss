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
  (define (evex-bytes r r2 x b w vvvv v2 ll pp mp)
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
          (bitwise-ior (bitwise-arithmetic-shift-left ll 5)
                       (bitwise-arithmetic-shift-left (- 1 v2) 3))))
  )
