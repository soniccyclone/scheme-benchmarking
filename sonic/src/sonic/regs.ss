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
          arch-mask mask-count
          arch-vector vector-count
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
  ;; --- the mask file ---------------------------------------------------------
  ;;
  ;; AVX-512 k0..k7 are a FOURTH register file, and under D21 a fourth file
  ;; needs its own partition answer rather than a place in an existing pool. A
  ;; mask holds one predicate bit per lane. It is never a Scheme value, never a
  ;; pointer, and the collector must never scan it -- so it is disjoint from
  ;; `value`, and folding it into `raw` would be wrong for a different reason:
  ;; no `mov` reaches it, only `kmovw`, so an allocator that handed a raw word a
  ;; k register would emit an instruction that does not exist.
  ;;
  ;; NO STORAGE CLASS MAPS TO IT. `assignment-ok?` answers #f for every Lrepr
  ;; class against a mask register, and that is the whole point: a mask is
  ;; produced and consumed inside one instruction sequence that the vector
  ;; emitter writes, and nothing in Lrepr ever names one. If a mask ever has to
  ;; live across a region the allocator sees, it needs a storage class of its
  ;; own and this comment is where to start.
  ;;
  ;; k0 IS ABSENT FROM THE POOL AND THAT IS AN ENCODING FACT, not a convention.
  ;; The EVEX `aaa` field is three bits and `aaa = 0` MEANS UNMASKED, so there
  ;; is no bit pattern that predicates an instruction on k0. gas rejects `{k0}`.
  ;; An allocator that handed out k0 would silently emit an unmasked
  ;; instruction, which computes every lane including the padding one.
  (define-record-type (arch make-arch* arch?)
    (fields name value raw float structural scratch mask vector))

  ;; Six arguments was the shape before the mask file existed, and the callers
  ;; that use it build a NARROWED arch -- the same partition minus the
  ;; registers some pins claimed (callconv.ss). They narrow the three
  ;; allocatable pools and copy the rest across, and the mask file is not
  ;; something they narrow, so the six-argument form fills it in from the
  ;; target rather than making every site say `(arch-mask a)` and one of them
  ;; forget. A narrowing that DID have to touch masks would use the long form
  ;; and be visible.
  (define make-arch
    (case-lambda
      ((n v r f st sc) (make-arch* n v r f st sc (masks-for n) (vectors-for n)))
      ((n v r f st sc mk) (make-arch* n v r f st sc mk (vectors-for n)))))

  ;; k1..k7. k0 is deliberately absent -- see the note above.
  (define (masks-for target)
    (case target
      ((x86-64) '(k1 k2 k3 k4 k5 k6 k7))
      (else '())))            ; RV64's vector extension masks in v0, not a file

  ;; THE VECTOR FILE, WHICH ONLY RV64 HAS AS A SEPARATE THING.
  ;;
  ;; x86-64 gets an empty list rather than its xmm registers, and that is the
  ;; whole asymmetry D169 is about. There a packed pair IS a `raw-f64` value:
  ;; the same physical register holds one double or two and the width rides on
  ;; the mnemonic, so packed lowering needed no class of its own. RVV's v
  ;; registers are a distinct file that no storage class could previously reach,
  ;; so a packed pair on RV64 has nowhere to live until this exists.
  ;;
  ;; v0 IS ABSENT AND THAT IS NOT AN OFF-BY-ONE. RVV addresses the mask register
  ;; as v0 specifically -- `vop.vv vd, vs2, vs1, v0.t` names it in the encoding
  ;; rather than selecting it -- so any masked operation destroys whatever a
  ;; value allocated there was holding. `masks-for` returns '() for rv64 for the
  ;; same reason: the mask is a fixed register, not a pool to allocate from.
  (define (vectors-for target)
    (case target
      ((rv64) '(v1 v2 v3 v4 v5 v6 v7 v8 v9 v10 v11 v12 v13 v14 v15
                v16 v17 v18 v19 v20 v21 v22 v23 v24 v25 v26 v27 v28 v29 v30 v31))
      (else '())))



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
      ;; THE SPLIT IS TUNED, and it was previously tuned on one benchmark.
      ;;
      ;; Only twelve of the sixteen GPRs are allocatable at all -- rax is the
      ;; scratch, rsp and rbp are structural, r15 holds nil -- so this line
      ;; decides how many registers integer code may use, and 6/6 gave fannkuch
      ;; six. It spilled `j` out of flip-prefix's inner loop, the hottest in the
      ;; benchmark, and reloaded it four times an iteration.
      ;;
      ;; Measured across the whole range, answers bit-exact at every point:
      ;;
      ;;   value/raw   nbody instr/step   fannkuch instructions
      ;;      6/6           714.50              42.157G
      ;;      5/7           718.50              38.115G
      ;;      4/8           715.50              37.705G
      ;;      3/9           715.50              37.580G
      ;;      2/10          787.50              37.284G
      ;;
      ;; nbody is FLAT from 6/6 to 3/9 and falls off a cliff at 2/10, where it
      ;; runs out of tagged registers for its three flvector parameters. So the
      ;; six-register value class was not buying nbody anything; it was costing
      ;; fannkuch ten percent of its instructions for nothing.
      ;;
      ;; 4/8 rather than 3/9, which is fractionally better on fannkuch: rbx and
      ;; r12 are the only value registers System V calls callee-saved once r13
      ;; and r14 leave, and a tagged value live across a call needs one. Two of
      ;; them is a thin margin already and one is not a margin. Both benchmarks
      ;; here are unusually raw-heavy for Scheme, and the split should not be
      ;; fitted so closely to them that ordinary tagged code has nowhere to sit.
      ;;
      ;; WHAT THIS DOES NOT TOUCH. r8 and r9 are the tagged ARGUMENT registers
      ;; and rcx/rdx/rsi/rdi/r10/r11 the raw ones; the convention in callconv.ss
      ;; names those explicitly and none of the four registers moved here
      ;; appears in any convention list. The value class also stays a FIXED
      ;; GLOBAL LIST, which is the property D21 rests on -- the collector
      ;; scavenges it unconditionally and gcmeta.ss carries no register bitmap
      ;; because of it. A per-function partition would buy more and would
      ;; change that contract; see the bead.
      '(rbx r8 r9 r12)                              ; value: 4
      '(rcx rdx rsi rdi r10 r11 r13 r14)            ; raw: 8
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
  (define (mask-count a)  (length (arch-mask a)))
  (define (vector-count a) (length (arch-vector a)))

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
          ((memq r (arch-mask a)) 'mask)
          ((memq r (arch-vector a)) 'vector)
          ((assq r (arch-structural a)) 'structural)
          (else #f)))

  ;; The storage class a virtual carries (from Lrepr) versus the register class
  ;; it is being given. `tagged` may ONLY reach the value class.
  ;;
  ;; raw-word may go to a raw register. raw-f64 may go to a float register.
  ;; Neither may go to a value register: putting a raw word there would make the
  ;; collector scavenge a non-pointer, which is corruption in the other
  ;; direction and just as fatal.
  ;; A mask register is reachable from NO storage class. `reg-class` answers
  ;; `mask` for k1..k7 and every case below then answers #f, which is the
  ;; intended reading rather than an omission: nothing in Lrepr names a lane
  ;; predicate, so an allocator being asked to put a value in one means
  ;; something upstream is confused.
  (define (assignment-ok? a sc r)
    (let ((cls (reg-class a r)))
      (case sc
        ((tagged)   (eq? cls 'value))
        ((raw-word) (eq? cls 'raw))
        ((raw-f64)  (eq? cls 'float))
        ;; A packed pair reaches the vector file and nothing else. Not `float`:
        ;; on RV64 an f register is 64 bits and holds one double, so a pair
        ;; placed there would be half a value with no diagnostic.
        ((raw-f64x2) (eq? cls 'vector))
        (else #f))))

  (define (check-assignment! a sc r)
    (unless (assignment-ok? a sc r)
      (error 'check-assignment!
             (case sc
               ((tagged)
                "a tagged value outside the value class is a root the collector will never find")
               ((raw-f64x2)
                ;; Not a collector question at all, which is why it gets its own
                ;; line rather than the raw message: a packed pair outside the
                ;; vector file is a WIDTH error. An f register is 64 bits, so the
                ;; second lane simply is not there, and the program computes a
                ;; wrong number rather than corrupting anything.
                "a packed pair outside the vector file loses its second lane")
               (else
                "a raw value inside the value class makes the collector scavenge a non-pointer"))
             (arch-name a) sc r (reg-class a r)))
    r)
  )
