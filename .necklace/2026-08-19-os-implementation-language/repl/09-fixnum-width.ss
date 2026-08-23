;;; PROBE 9: what is the fixnum range, and can it hold a 64-bit hardware value?
;;; A page-table entry, a physical address and most device registers are 64 bits.
;;; FALSIFIABLE: if the range covers the full unsigned 64-bit space, fixed-width
;;; integer types are optional and the tower question stands alone.
(import (chezscheme) (sonic numeric))
(define bits fx-value-bits)
(define hi (- (expt 2 (- bits 1)) 1))
(define lo (- (expt 2 (- bits 1))))
(printf "tag bits=~a value bits=~a word bits=~a\n" fx-tag-bits bits fx-word-bits)
(printf "range: ~a .. ~a\n" lo hi)
(printf "PTE 0xFFFFFFFFFFFFF003 fits?        ~a\n" (<= #xFFFFFFFFFFFFF003 hi))
(printf "48-bit phys addr 0xFFFFFFFFF000 fits? ~a\n" (<= #xFFFFFFFFF000 hi))
(printf "32-bit MMIO word 0xFFFFFFFF fits?     ~a\n" (<= #xFFFFFFFF hi))
