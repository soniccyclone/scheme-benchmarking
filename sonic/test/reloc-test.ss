(import (chezscheme) (sonic reloc))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

;; --- x86-64: one relocation, and the addend is not the pool offset --------
(let ([rs (pool-load-relocs 'x86-64 100 3 64)])
  (ck! "x86-64 pooled load needs exactly ONE relocation" (= (length rs) 1))
  (let ([r (car rs)])
    (ck! "it is R_X86_64_PC32" (= (reloc-type-code (reloc-type r)) 2))
    (ck! "patching the disp32, which is 4 bytes into the instruction"
         (= (reloc-offset r) 104))
    ;; The -4 is the whole subtlety. x86-64 measures PC-relative displacement
    ;; from the END of the instruction, not from the displacement field, so an
    ;; addend equal to the pool offset resolves 4 bytes past the constant.
    (ck! "and the addend carries the -4 for end-of-instruction relative"
         (= (reloc-addend r) 60))))

;; --- RV64: two relocations, and the second names an instruction ----------
(let ([rs (pool-load-relocs 'rv64 200 3 64)])
  (ck! "RV64 pooled load needs TWO relocations: it has no PC-relative load"
       (= (length rs) 2))
  (let ([hi (car rs)] [lo (cadr rs)])
    (ck! "the first is PCREL_HI20 on the auipc"
         (and (= (reloc-type-code (reloc-type hi)) 23) (= (reloc-offset hi) 200)))
    (ck! "the second is PCREL_LO12_I on the load, 4 bytes later"
         (and (= (reloc-type-code (reloc-type lo)) 24) (= (reloc-offset lo) 204)))
    ;; THE detail a naive port gets wrong: the LO12 relocation does not name the
    ;; symbol, it names the LABEL of its paired HI20, because the linker has to
    ;; recover which high part this low part belongs to.
    (ck! "the LO12 names the HI20's LABEL, not the symbol"
         (and (= (reloc-symbol lo) 200) (not (= (reloc-symbol lo) 3))))
    (ck! "and the HI20 does name the symbol" (= (reloc-symbol hi) 3))
    (ck! "the pool offset rides on the HI20's addend" (= (reloc-addend hi) 64))))

;; --- encoding ------------------------------------------------------------
(let* ([rs (pool-load-relocs 'x86-64 0 1 8)]
       [bv (relocs->bytevector rs)])
  (ck! "an Elf64_Rela entry is 24 bytes" (= (bytevector-length bv) 24))
  (ck! "little-endian offset in the first 8 bytes"
       (= (bytevector-u8-ref bv 0) 4))
  ;; info = (sym << 32) | type, so the type is the low byte
  (ck! "type is the low byte of info" (= (bytevector-u8-ref bv 8) 2))
  (ck! "symbol index sits in the high half of info"
       (= (bytevector-u8-ref bv 12) 1)))

(let ([bv (relocs->bytevector (pool-load-relocs 'rv64 0 1 8))])
  (ck! "two RV64 relocations encode to 48 bytes" (= (bytevector-length bv) 48)))

;; --- an unknown target raises rather than emitting nothing ---------------
(set! checks (+ checks 1))
(let ([caught #f])
  (guard (e (#t (set! caught #t))) (pool-load-relocs 'arm64 0 1 0))
  (if caught (display "  ok   an unknown target RAISES, rather than emitting no relocation\n")
             (begin (set! failures (+ failures 1))
                    (display "  FAIL unknown target silently produced no relocation\n"))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
