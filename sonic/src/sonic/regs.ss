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
          arch-register-for arch-float-scratch arch-int-scratch float-register?
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
  ;; THE SPLIT IS 6/6, NOT 8/4, AND IT IS MEASURED RATHER THAN ASSUMED.
  ;;
  ;; The partition's PURPOSE is that the collector knows statically which
  ;; registers hold roots, and that is untouched here: the classes are still
  ;; disjoint and still fixed at compile time. Only where the line falls moved,
  ;; and it moved because the old line was wrong for the code this compiler
  ;; actually emits.
  ;;
  ;; nbody has 196 raw-word values against 45 tagged ones, and the pools were
  ;; sized the other way round. The pairwise force loop spilled seven values and
  ;; funnelled them all through the single raw scratch: 85 of its 119
  ;; instructions were data movement against 33 of arithmetic, and most of that
  ;; movement was one index being written to a frame slot and read straight back
  ;; because four registers could not hold the loop's live indices.
  ;;
  ;; r10 and r11 move to the raw pool. Both are caller-saved in System V, so
  ;; neither was carrying a tagged value across a call anyway -- the four value
  ;; registers that survive a call are rbx, r12, r13 and r14, and those stay
  ;; where they are. A raw word live across a call still always spills, because
  ;; System V leaves no callee-saved raw register to keep it in; that is
  ;; unchanged and is why this costs the tagged class nothing it was using.
  (define arch-x86-64
    (make-arch 'x86-64
      '(rbx r8 r9 r12 r13 r14)                      ; value: 6
      '(rcx rdx rsi rdi r10 r11)                    ; raw: 6
      '(xmm0 xmm1 xmm2 xmm3 xmm4 xmm5 xmm6 xmm7
        xmm8 xmm9 xmm10 xmm11 xmm12 xmm13)            ; float: 14, xmm14/15 scratch
      '((rsp . stack) (rbp . frame) (r15 . nil))
      ;; TWO float scratches, not one, and the reason is three-address VEX.
      ;;
      ;; A two-address `addsd d, s` has two operands: if d is spilled it needs a
      ;; scratch, and s can ride in memory, so one scratch covers it. The
      ;; three-address `vaddsd d, a, b` has three, and `a` rides in the VEX
      ;; prefix's vvvv field, which holds a register number and has no memory
      ;; form -- so d and a can both need a register at once.
      ;;
      ;; The alternative was to refuse, which this pass does when it runs out of
      ;; scratches, and refusing is what it did: nbody's `energy` hit
      ;; `(vaddsd t.71 e%57.60 t.70)` with two of the three spilled. Spending a
      ;; second float register is the cheap answer here and only here -- the
      ;; float class has fourteen left and was never the class under pressure.
      ;; That is a measured claim: nbody has 179 raw-f64 values against 196
      ;; raw-word ones, and it was the raw-word pool that was spilling.
      ;;
      ;; rax stays the sole integer scratch: the integer ops are still
      ;; two-address, so nothing there gained an operand.
      '(rax xmm14 xmm15)))

  ;; --- RV64 -----------------------------------------------------------------
  ;; tp already means current-thread in the standard ABI, so using it costs
  ;; nothing in clarity. RISC-V has no segment registers, so nil, current CPU
  ;; and current thread get dedicated registers as arm64 does.
  (define arch-rv64
    (make-arch 'rv64
      '(a0 a1 a2 a3 a4 a5 a6 a7 s2 s3 s4 s5 s6 s7)  ; value: 14
      '(s8 s9 s10 s11 t3 t4 t5 t6)                  ; raw: 8, t2 is scratch
      ;; HAZARD: this is ALLOCATION order, not ABI f-number order. Taking a
      ;; position in this list as a register number puts fs2 at f10, which is
      ;; fa0, and the program still assembles. Encoders must map ABI NAME to
      ;; number, never index into this list.
      '(ft0 ft1 ft2 ft3 ft4 ft5 ft6 ft7
        fs0 fs1 fs2 fs3 fs4 fs5 fs6 fs7
        fa0 fa1 fa2 fa3 fa4 fa5 fa6 fa7
        fs8 fs9 fs10 fs11 ft8)                      ; float: 29, ft9-ft11 scratch
      '((zero . zero) (ra . return-address) (sp . stack) (s0 . frame)
        (gp . nil) (tp . current-thread) (s1 . current-cpu))
      ;; THREE per file, and the count is forced by the ISA rather than chosen.
      ;;
      ;; RV64 is load/store, so a spilled operand cannot ride in memory the way
      ;; it can on x86-64 -- every one of them needs a register to be reloaded
      ;; into. And RV64's arithmetic is THREE-ADDRESS, so a single
      ;; `fadd.d rd, rs1, rs2` can have all three operands spilled at once.
      ;; With two scratches the third reload clobbers the first, silently.
      ;;
      ;; x86-64 needs one per file for the opposite reason on both counts: it
      ;; is two-address, so an instruction mentions at most two distinct
      ;; operands, and it reads memory directly, so a spilled source costs no
      ;; register at all.
      ;;
      ;; The price is three of RISC-V's 32 float registers and one of its
      ;; integer registers -- which it can afford and x86-64 could not, which is
      ;; the same arithmetic PREEMPTION.md ran.
      ;;
      ;; t0, t1 also serve as address temporaries: RV64 has no indexed
      ;; addressing, so (load v raw-f64 base idx) is slli/add/fld and the shift
      ;; needs a home.
      '(t0 t1 t2 ft9 ft10 ft11)))

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

  ;; Which scratch registers belong to which FILE.
  ;;
  ;; `arch-float` is the ALLOCATABLE float pool and the float scratches are
  ;; deliberately outside it, so "is this a float register" cannot be answered
  ;; by membership in that pool. parcopy.ss asked it that way and concluded
  ;; there was no float scratch to break a cycle with -- on a target that
  ;; reserves one for exactly that purpose.
  (define (float-register? a r)
    (and (or (memq r (arch-float a)) (memq r (arch-float-scratch a))) #t))

  (define (arch-float-scratch a)
    (filter (lambda (r) (float-scratch-name? (arch-name a) r)) (arch-scratch a)))

  (define (arch-int-scratch a)
    (filter (lambda (r) (not (float-scratch-name? (arch-name a) r))) (arch-scratch a)))

  ;; Named per target rather than inferred: `xmm15` and `ft11` are float by
  ;; their ABI names, and inferring that from a spelling is the kind of rule
  ;; that breaks the first time a register is renamed.
  (define (float-scratch-name? target r)
    (case target
      ((x86-64) (memq r '(xmm14 xmm15)))
      ((rv64)   (memq r '(ft9 ft10 ft11)))
      (else #f)))

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
