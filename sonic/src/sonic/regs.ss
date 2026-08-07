;;; Register partition tables.
;;;
;;; The executable form of sonic/doc/register-partition.md. Read that document
;;; for the reasoning; this file is the data plus the predicate the allocator
;;; asserts against.
;;;
;;; The invariant, per D21: the collector scavenges the VALUE class
;;; unconditionally, consulting no metadata. A tagged value that lands in a raw
;;; register is therefore a root the collector will never find. That is silent
;;; memory corruption, not a slow program, which is why `check-assignment!`
;;; raises rather than warns.

(library (sonic regs)
  (export make-arch arch? arch-name arch-value arch-raw arch-float arch-structural
          arch-register-for
          arch-scratch
          arch-x86-64 arch-rv64 arch-by-name
          reg-class check-assignment! assignment-ok?
          value-count raw-count float-count)
  (import (chezscheme))

  ;; `scratch` is NOT part of the allocatable pools. It is the set of registers
  ;; a selection rule may use for address temporaries and two-address fixups
  ;; WITHOUT telling the allocator, because the allocator runs over Lmach and
  ;; never sees selected output.
  ;;
  ;; This exists because the RV64 selector needed one and took t0, which was
  ;; simultaneously at the head of the allocatable raw pool. Linear scan would
  ;; have handed t0 out and the address computation would have clobbered a live
  ;; value. Both statements cannot hold, so the scratch registers come out of
  ;; the pool.
  ;;
  ;; Do NOT confuse this with `scratch-live` in gc-metadata.md. That bit means a
  ;; RAW register is transiently holding a TAGGED value during a calling
  ;; sequence and must be scavenged. This is about a register being unavailable
  ;; to the allocator. Two different concepts that both wanted the word.
  (define-record-type (arch make-arch arch?)
    (fields name value raw float structural scratch))

  ;; --- x86-64 (System V) ----------------------------------------------------
  ;; Current CPU and current thread live behind the GS base rather than burning
  ;; two GPRs, which is why we get 8 value registers where Mezzano gets 7.
  (define arch-x86-64
    (make-arch 'x86-64
      '(rbx r8 r9 r10 r11 r12 r13 r14)              ; value: 8
      '(rcx rdx rsi rdi)                            ; raw: 4
      '(xmm0 xmm1 xmm2 xmm3 xmm4 xmm5 xmm6 xmm7
        xmm8 xmm9 xmm10 xmm11 xmm12 xmm13 xmm14)      ; float: 15, xmm15 is scratch
      '((rsp . stack) (rbp . frame) (r15 . nil))
      ;; rax: the two-address fixup for subsd/divsd needs somewhere to put the
      ;; left operand when dst aliases src2, and xmm15 is the float equivalent.
      '(rax xmm15)))

  ;; --- RV64 -----------------------------------------------------------------
  ;; tp already means current-thread in the standard ABI, so using it costs
  ;; nothing in clarity. RISC-V has no segment registers, so nil, current CPU
  ;; and current thread get dedicated registers as arm64 does.
  (define arch-rv64
    (make-arch 'rv64
      '(a0 a1 a2 a3 a4 a5 a6 a7 s2 s3 s4 s5 s6 s7)  ; value: 14
      '(t2 s8 s9 s10 s11 t3 t4 t5 t6)               ; raw: 9
      ;; HAZARD: this is ALLOCATION order, not ABI f-number order. Taking a
      ;; position in this list as a register number puts fs2 at f10, which is
      ;; fa0, and the program still assembles. Encoders must map ABI NAME to
      ;; number, never index into this list.
      '(ft0 ft1 ft2 ft3 ft4 ft5 ft6 ft7
        fs0 fs1 fs2 fs3 fs4 fs5 fs6 fs7
        fa0 fa1 fa2 fa3 fa4 fa5 fa6 fa7
        fs8 fs9 fs10 fs11 ft8 ft9 ft10)             ; float: 31, ft11 is scratch
      '((zero . zero) (ra . return-address) (sp . stack) (s0 . frame)
        (gp . nil) (tp . current-thread) (s1 . current-cpu))
      ;; t0, t1: address temporaries. RV64 has no indexed addressing, so
      ;; (load v raw-f64 base idx) is slli/add/fld and the shift needs a home.
      ;; ft11: the float equivalent.
      '(t0 t1 ft11)))

  (define (arch-by-name n)
    (case n
      ((x86-64) arch-x86-64)
      ((rv64)   arch-rv64)
      (else (error 'arch-by-name "unknown target" n))))

  (define (value-count a) (length (arch-value a)))
  (define (raw-count a)   (length (arch-raw a)))
  (define (float-count a) (length (arch-float a)))

  ;; The register holding a structural role: `nil`, `current-thread`,
  ;; `current-cpu`, `frame`, `stack`. Selection needs `nil` by name -- the empty
  ;; list is a real Scheme object with no immediate encoding, and both
  ;; partitions already dedicate a register to it rather than paying for a tag.
  (define (arch-register-for a role)
    (let loop ((rs (arch-structural a)))
      (cond ((null? rs)
             (error 'arch-register-for "no register holds this role" (arch-name a) role))
            ((eq? (cdar rs) role) (caar rs))
            (else (loop (cdr rs))))))

  ;; Which class does this physical register belong to?
  (define (reg-class a r)
    (cond ((memq r (arch-scratch a)) 'scratch)
          ((memq r (arch-value a)) 'value)
          ((memq r (arch-raw a)) 'raw)
          ((memq r (arch-float a)) 'float)
          ((assq r (arch-structural a)) 'structural)
          (else #f)))

  ;; The storage class a virtual carries (from Lrepr) versus the register class
  ;; it is being given. `tagged` may ONLY reach the value class.
  ;;
  ;; raw-word may go to a raw register. raw-f64 may go to a float register.
  ;; Neither may go to a value register: putting a raw word there would make the
  ;; collector scavenge a non-pointer, which is corruption in the other
  ;; direction and just as fatal.
  (define (assignment-ok? a sc r)
    (let ((cls (reg-class a r)))
      (case sc
        ((tagged)   (eq? cls 'value))
        ((raw-word) (eq? cls 'raw))
        ((raw-f64)  (eq? cls 'float))
        (else #f))))

  (define (check-assignment! a sc r)
    (unless (assignment-ok? a sc r)
      (error 'check-assignment!
             (case sc
               ((tagged)
                "a tagged value outside the value class is a root the collector will never find")
               (else
                "a raw value inside the value class makes the collector scavenge a non-pointer"))
             (arch-name a) sc r (reg-class a r)))
    r)
  )
