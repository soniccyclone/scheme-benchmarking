#!r6rs
;;; An Sv39 page-table walk, and the construction of a leaf PTE.
;;;
;;; Sv39: a 39-bit virtual address in three 9-bit levels over a 12-bit page
;;; offset. A PTE is 64 bits: PPN in [53:10], the RSW in [9:8], and the flag
;;; bits D A G U X W R V in [7:0]. RISC-V has no NX bit -- executability is the
;;; X flag -- but x86-64's PTE puts NX at bit 63, and probe 9 measured that a
;;; 61-bit fixnum cannot hold it. Both are written here for that reason.

(define page-shift 12)
(define ptes-per-table 512)
(define pte-v #x01)
(define pte-r #x02)
(define pte-w #x04)
(define pte-x #x08)
;; x86-64. Bit 63. This constant is the whole argument for u64.
(define pte-nx #x8000000000000000)

;; Extract the 9-bit index for one level of the walk.
(define (vpn va level)
  (u64and (u64shr va (fx+ page-shift (fx* 9 level))) 511))

;; A PTE's physical page number lives in [53:10]; shifting it back up by 12
;; gives the physical address of the next table.
(define (pte->pa pte)
  (u64shl (u64shr pte 10) page-shift))

(define (pte-valid? pte) (u64and pte pte-v))

;; A leaf PTE is a leaf when any of R, W or X is set; otherwise it is a pointer
;; to the next level. That distinction is the walk's whole termination argument.
(define (pte-leaf? pte)
  (u64and pte (u64ior pte-r (u64ior pte-w pte-x))))

(define (make-pte pa flags)
  (u64ior (u64shl (u64shr pa page-shift) 10) flags))

;; Walk three levels, reading each table out of physical memory. Returns the
;; leaf PTE, or 0 if the walk hits an invalid entry.
(define (walk root va level)
  (let ((pte (mmio-u64-ref (u64+ root (u64shl (vpn va level) 3)))))
    (if (u64= (pte-valid? pte) 0)
        0
        (if (u64= (pte-leaf? pte) 0)
            (if (fx= level 0)
                0
                (walk (pte->pa pte) va (fx- level 1)))
            pte))))

(define (translate root va)
  (let ((pte (walk root va 2)))
    (if (u64= pte 0)
        0
        (u64ior (pte->pa pte) (u64and va #xFFF)))))

(define (main)
  ;; A writable, non-executable identity mapping of physical page 0x80000.
  (let ((pte (make-pte #x80000000 (u64ior pte-v (u64ior pte-r (u64ior pte-w pte-nx))))))
    (display-word (translate #x80001000 #x40000000))))

(main)
