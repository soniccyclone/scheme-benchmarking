#!r6rs
;;; u64 at the bit a fixnum cannot reach, run on both targets and compared.
;;;
;;; Probe 9 measured the ceiling: 3 tag bits leave 61 value bits, so bit 63 --
;;; x86-64's NX bit in a page-table entry -- does not fit a fixnum at all. Every
;;; value below is at or past that boundary.
;;;
;;; DOUBLED RATHER THAN WRITTEN AS A LITERAL, and that is not stylistic: a
;;; constant above 32 bits is refused by both targets today (RV64 says so by
;;; name, x86-64 through `imm32-bytes`), so a literal 2^63 would test the
;;; refusal instead of the arithmetic. It is also stronger this way -- a folded
;;; literal would exercise no instruction at all.

(define (dbl n x) (if (fx= n 0) x (dbl (fx- n 1) (u64+ x x))))

(define (main)
  (begin
    ;; 2^63. One bit above what a fixnum can hold, and the reason this type
    ;; exists.
    (display-word (dbl 63 1))
    ;; The flag bits a real PTE carries alongside it.
    (display-word (u64ior (dbl 63 1) 3))
    ;; Disjoint masks, so the answer is 0 whichever way the bits are counted.
    (display-word (u64and (dbl 63 1) (dbl 62 1)))
    ;; WRAPAROUND, which is the difference from fx+: this overflows a 64-bit
    ;; word and must produce 0 rather than trapping. `fx+` carries
    ;; `overflow-check` and would refuse; `u64+` carries nothing and wraps,
    ;; which is what an address computation wants.
    (display-word (u64+ (dbl 63 1) (dbl 63 1)))
    ;; xor of a value with itself, at the top bit.
    (display-word (u64xor (dbl 63 1) (dbl 63 1)))
    ;; Multiplication reaching the same place from below.
    (display-word (u64* (dbl 62 1) 2))))

(main)
