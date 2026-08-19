;;; Calling convention, and precoloring as the mechanism that implements it.
;;;
;;; E7. Beads 6cm.1 (convention) and 6cm.10 (return placement is a precoloring
;;; constraint).
;;;
;;; Per D8, a C back end forecloses four things: precise GC roots,
;;; calling-convention control, general tail calls, and representation control.
;;; This file is where we take the second and third. The convention is ours. It
;;; is not System V, and it is not System V with Scheme bolted on.
;;;
;;; ## What the register partition decides for us
;;;
;;; sonic/doc/register-partition.md is upstream of every choice here. A tagged
;;; argument may only travel in a value register, a raw word only in a raw
;;; register, a double only in a float register, because D21 has the collector
;;; scavenge the value class unconditionally and consult no metadata. So there
;;; is no single "argument register list". There are three, one per storage
;;; class, and an eight-argument call whose arguments are four tagged and four
;;; raw uses eight registers drawn from two disjoint pools.
;;;
;;; Argument registers are also never drawn from `arch-scratch`. Scratch
;;; registers are the ones a selection rule may clobber WITHOUT telling the
;;; allocator, so a live incoming argument sitting in one would be destroyed by
;;; the first address computation in the callee.
;;;
;;; ## Caller-saved versus callee-saved, and why it tracks the host ABI
;;;
;;; We own the convention, so we could partition saves any way we like. We
;;; deliberately make our callee-saved set a SUBSET of the host ABI's
;;; callee-saved set. The payoff is at the foreign boundary: a call out to C
;;; clobbers exactly the host's caller-saved registers, so anything we were
;;; keeping in one of our callee-saved registers survives a foreign call with no
;;; save sequence at all. The boundary still shuffles arguments explicitly, per
;;; register-partition.md, but it does not have to spill the world.
;;;
;;; The split within each pool is roughly half. A wholly caller-saved file makes
;;; call-dense Scheme spill every long-lived value at every call; a wholly
;;; callee-saved file makes every leaf procedure save registers it never uses.
;;;
;;; ## Return placement
;;;
;;; `(ret v)` carries no storage class. The selector cannot look at it and
;;; choose between rax and xmm0, or between a0 and fa0, so both targets emit a
;;; bare `ret` and the value has to already be in the right physical register
;;; when control reaches it. That is not an instruction to select. It is a
;;; constraint on the allocator: this vreg must land in THAT register. Linear
;;; scan cannot say it, so `allocate/precolored` below says it for us.
;;;
;;; x86-64's tagged return rides rax, rcx, rdx, which are RAW class registers.
;;; That is not an oversight and it is not corruption: sonic/doc/gc-metadata.md
;;; already carries a 2-bit `scratch-live` field whose values are exactly
;;; none / rax / rax+rcx / rax+rcx+rdx, "strictly nesting", because those three
;;; registers transiently hold tagged values during calling-convention
;;; sequences. That nesting IS a multiple-value return: value 1 in rax, value 2
;;; in rcx, value 3 in rdx, with the collector told to scavenge exactly as many
;;; as are live. It also caps x86-64 at three values in registers, because the
;;; field is two bits. RV64 needs none of this: a0-a7 are value class, so a
;;; tagged return there is scavenged unconditionally like anything else, and the
;;; register limit is the pool, not the metadata.
;;;
;;; The inverse does not hold. RV64's RAW return cannot use a0 even though the
;;; host ABI does, because a raw word in a value register makes the collector
;;; scavenge a non-pointer. It uses t2, the head of the caller-saved raw set.
;;;
;;; ## Tail calls
;;;
;;; A general tail call is a jump, never a call, and it reuses the caller's
;;; frame rather than stacking a new one. `tail-call-plan` reports the frame
;;; delta: zero when the callee's outgoing stack-argument area fits in the
;;; caller's frame, which is always true when every argument fits in registers.
;;; That is what makes a mutually recursive fixture run in constant stack, and
;;; it is the property `simulate-calls` measures.

(library (sonic callconv)
  (export make-callconv callconv? callconv-arch callconv-name
          callconv-args callconv-returns
          callconv-caller-saved callconv-callee-saved
          callconv-scratch-live callconv-scratch-classes
          callconv-x86-64 callconv-rv64 callconv-by-name

          arg-registers arg-register arg-register-count
          return-registers return-register return-register-count
          caller-saved? callee-saved? clobbered-by-call?
          stack-words-for-args

          make-frame frame? frame-name frame-words
          make-tail-plan tail-plan? tail-plan-target tail-plan-moves
          tail-plan-stack-args tail-plan-frame-delta tail-plan-transfer
          tail-plan-reuses-frame?
          tail-call-plan
          make-cproc cproc? cproc-name cproc-frame-words cproc-arg-classes
          cproc-next
          simulate-calls

          make-pin pin? pin-vreg pin-reg pin-class
          pin-ok? check-pins! pins-conflict?
          precolor-return precolor-returns
          allocate/precolored allocate-program/precolored)
  (import (chezscheme)
          (sonic regs)
          (sonic regalloc))

  ;; --- the convention record ------------------------------------------------
  ;;
  ;; `args` and `returns` are alists keyed by storage class, because the
  ;; partition makes one flat list impossible. `scratch-live` is the set of
  ;; registers outside the value class that this convention permits to hold a
  ;; tagged value transiently, with the collector told by the gcmeta flag of the
  ;; same name. `scratch-classes` mirrors register-partition.md for the
  ;; registers regs.ss pulls out of every pool, which is the one fact the
  ;; partition tables deliberately no longer carry.
  (define-record-type (callconv make-callconv callconv?)
    (fields arch args returns caller-saved callee-saved
            scratch-live scratch-classes))

  (define (callconv-name cc) (arch-name (callconv-arch cc)))

  ;; --- x86-64 ---------------------------------------------------------------
  ;; value pool: rbx r8 r9 r12                  (4)
  ;; raw pool:   rcx rdx rsi rdi r10 r11 r13 r14 (8, rax is scratch)
  ;; float pool: xmm0-xmm13                     (14, xmm14/15 scratch)
  ;;
  ;; THIS COMMENT HAS BEEN WRONG TWICE, so it is worth saying where the numbers
  ;; come from rather than restating them: regs.ss owns the partition and
  ;; explains the measurement that chose it. Read it there.
  ;;
  ;; System V calls rbx, r12, r13, r14 callee-saved. Two of those are value and
  ;; two are raw, which is the part that changed: there used to be no
  ;; callee-saved RAW register at all, so a raw word live across a call was
  ;; always spilled, and fannkuch's enumeration driver spilled thirteen values
  ;; for that reason. r13 and r14 being raw means a raw word can now survive a
  ;; call in a register.
  ;;
  ;; TWO tagged argument registers, and that is the honest consequence of a
  ;; four-register value class. A call needing a third passes it on the stack,
  ;; which works in both directions -- see the outgoing argument area in
  ;; finalize.ss.
  (define callconv-x86-64
    (make-callconv
     arch-x86-64
     ;; arguments, in order, per class.
     ;;
     ;; THE CONVENTION HAS TO AGREE WITH THE PARTITION, or an argument arrives
     ;; in a register of the wrong class and the collector either scans a
     ;; machine word or misses a root. Every register named here is in the pool
     ;; of its own class in regs.ss, and that is the invariant to preserve when
     ;; either file changes.
     ;;
     ;; It is also why retuning the partition is cheaper than it looks: the four
     ;; registers that moved between the pools -- rbx, r12, r13, r14 -- appear
     ;; in NO list below. Only the pool sizes changed, not where anything is
     ;; passed or returned.
     '((tagged   . (r8 r9))
       (raw-word . (rcx rdx rsi rdi r10 r11))
       (raw-f64  . (xmm0 xmm1 xmm2 xmm3 xmm4 xmm5 xmm6 xmm7)))
     ;; returns, in order: value 1 first. Three is the ceiling for tagged and
     ;; raw-word because gcmeta's scratch-live field is two bits.
     '((tagged   . (rax rcx rdx))
       (raw-word . (rax rcx rdx))
       (raw-f64  . (xmm0 xmm1 xmm2 xmm3)))
     ;; caller-saved
     '(rax rcx rdx rsi rdi r8 r9 r10 r11
       xmm0 xmm1 xmm2 xmm3 xmm4 xmm5 xmm6 xmm7
       xmm8 xmm9 xmm10 xmm11 xmm12 xmm13 xmm14 xmm15)
     ;; callee-saved: a subset of System V's, so a foreign call preserves them
     '(rbx r12 r13 r14)
     ;; may transiently hold a tagged value; gcmeta's 2-bit nesting
     '(rax rcx rdx)
     ;; partition class of the registers regs.ss removed from every pool
     '((rax . raw) (xmm15 . float))))

  ;; --- RV64 -----------------------------------------------------------------
  ;; value pool: a0-a7 s2-s7          (14)
  ;; raw pool:   t2 s8-s11 t3-t6      (9, t0 and t1 are scratch)
  ;; float pool: 31, ft11 is scratch
  ;;
  ;; a0-a7 are value class on purpose (register-partition.md): they carry Scheme
  ;; objects at every call, so making them raw would force a shuffle at each
  ;; boundary. That gives eight tagged argument registers for free and it is why
  ;; this target is comfortable where x86-64 is not.
  (define callconv-rv64
    (make-callconv
     arch-rv64
     '((tagged   . (a0 a1 a2 a3 a4 a5 a6 a7))
       (raw-word . (t3 t4 t5 t6))
       (raw-f64  . (fa0 fa1 fa2 fa3 fa4 fa5 fa6 fa7)))
     ;; The tagged return is a0, as the host ABI has it, and that is sound here
     ;; because a0 is value class. The RAW return is NOT a0: a raw word in a
     ;; value register makes the collector scavenge a non-pointer. t2 instead.
     '((tagged   . (a0 a1 a2 a3 a4 a5 a6 a7))
       (raw-word . (t3 t4 t5 t6))
       (raw-f64  . (fa0 fa1 fa2 fa3 fa4 fa5 fa6 fa7)))
     '(a0 a1 a2 a3 a4 a5 a6 a7 t3 t4 t5 t6
       ft0 ft1 ft2 ft3 ft4 ft5 ft6 ft7 ft8 ft9 ft10
       fa0 fa1 fa2 fa3 fa4 fa5 fa6 fa7)
     '(s2 s3 s4 s5 s6 s7 s8 s9 s10 s11
       fs0 fs1 fs2 fs3 fs4 fs5 fs6 fs7 fs8 fs9 fs10 fs11)
     ;; Nothing. Every register this convention uses for a tagged value is in
     ;; the value class, so there is no transient to declare.
     '()
     '((t0 . raw) (t1 . raw) (ft11 . float))))

  (define (callconv-by-name n)
    (case n
      ((x86-64) callconv-x86-64)
      ((rv64)   callconv-rv64)
      (else (error 'callconv-by-name "unknown target" n))))

  ;; --- queries --------------------------------------------------------------

  (define (assq-list k al)
    (let ((p (assq k al))) (if p (cdr p) '())))

  (define (arg-registers cc sc) (assq-list sc (callconv-args cc)))
  (define (return-registers cc sc) (assq-list sc (callconv-returns cc)))
  (define (arg-register-count cc sc) (length (arg-registers cc sc)))
  (define (return-register-count cc sc) (length (return-registers cc sc)))

  (define (nth-or-false lst i)
    (cond ((null? lst) #f)
          ((zero? i) (car lst))
          (else (nth-or-false (cdr lst) (- i 1)))))

  ;; The i'th argument OF THAT CLASS. Numbering is per class, not global,
  ;; because the pools are disjoint: the first tagged argument and the first raw
  ;; argument both take index 0 and land in different registers.
  (define (arg-register cc sc i) (nth-or-false (arg-registers cc sc) i))
  (define (return-register cc sc)
    (let ((rs (return-registers cc sc)))
      (if (null? rs)
          (error 'return-register "no return register for storage class" sc)
          (car rs))))

  (define (caller-saved? cc r) (and (memq r (callconv-caller-saved cc)) #t))
  (define (callee-saved? cc r) (and (memq r (callconv-callee-saved cc)) #t))
  ;; Scratch registers are clobbered by everything, calls included.
  (define (clobbered-by-call? cc r)
    (or (caller-saved? cc r)
        (and (memq r (arch-scratch (callconv-arch cc))) #t)))

  ;; How many stack words a call needs for arguments that ran out of registers.
  ;; `classes` is the argument list as storage classes, in source order.
  (define (stack-words-for-args cc classes)
    (let ((used (make-eq-hashtable)))
      (fold-left
       (lambda (n sc)
         (let* ((i (hashtable-ref used sc 0)))
           (hashtable-set! used sc (+ i 1))
           (if (arg-register cc sc i) n (+ n 1))))
       0 classes)))

  ;; --- tail calls -----------------------------------------------------------

  (define-record-type (frame make-frame frame?)
    (fields name words))

  (define-record-type (tail-plan make-tail-plan tail-plan?)
    (fields target moves stack-args frame-delta transfer))

  (define (tail-plan-reuses-frame? p) (zero? (tail-plan-frame-delta p)))

  ;; `args` is a list of (storage-class . source), in source order. The result
  ;; says where each argument goes, how much outgoing stack area the call needs,
  ;; whether the caller's frame absorbs it, and that the transfer is a jump.
  ;;
  ;; `transfer` is 'jmp unconditionally. A tail call that emitted 'call would
  ;; push a return address and the whole property disappears; the field exists
  ;; so a test can assert it rather than trust the prose.
  (define (tail-call-plan cc caller-frame target args)
    (let ((used (make-eq-hashtable)))
      (let loop ((as args) (moves '()) (stack '()))
        (if (null? as)
            (let* ((stack-words (length stack))
                   (have (frame-words caller-frame))
                   (delta (if (<= stack-words have) 0 (- stack-words have))))
              (make-tail-plan target (reverse moves) (reverse stack)
                              delta 'jmp))
            (let* ((a (car as))
                   (sc (car a))
                   (src (cdr a))
                   (i (hashtable-ref used sc 0))
                   (r (arg-register cc sc i)))
              (hashtable-set! used sc (+ i 1))
              (if r
                  (loop (cdr as) (cons (cons r src) moves) stack)
                  (loop (cdr as) moves (cons (cons sc src) stack))))))))

  ;; --- the mutually recursive fixture, as a stack simulation ----------------
  ;;
  ;; A procedure: the stack words its own frame needs, the classes of the
  ;; arguments it passes onward, and who it passes them to. Chain them and the
  ;; question "does this run in constant stack" becomes arithmetic.

  (define-record-type (cproc make-cproc cproc?)
    (fields name frame-words arg-classes next))

  ;; Returns (values final-depth peak-depth). With `tail?` true the caller's
  ;; frame is popped before the jump, so depth is a function of the callee
  ;; alone and a cycle of procedures has a bounded peak no matter how many steps
  ;; run. With `tail?` false each call stacks a return address and a frame, so
  ;; depth grows linearly, which is the negative control.
  (define (simulate-calls cc procs start steps tail?)
    (define (lookup name)
      (let loop ((ps procs))
        (cond ((null? ps) (error 'simulate-calls "no such procedure" name))
              ((eq? (cproc-name (car ps)) name) (car ps))
              (else (loop (cdr ps))))))
    (let loop ((n steps)
               (cur (lookup start))
               (depth (cproc-frame-words (lookup start)))
               (peak (cproc-frame-words (lookup start))))
      (if (zero? n)
          (values depth peak)
          (let* ((callee (lookup (cproc-next cur)))
                 (outgoing (stack-words-for-args cc (cproc-arg-classes cur)))
                 (d (if tail?
                        (+ (cproc-frame-words callee) outgoing)
                        (+ depth 1 (cproc-frame-words callee) outgoing))))
            (loop (- n 1) callee d (max peak d))))))

  ;; --- precoloring ----------------------------------------------------------
  ;;
  ;; The mechanism bead 6cm.10 asks for: a way to tell the allocator that a
  ;; particular vreg must land in a particular physical register. regalloc.ss is
  ;; untouched. This is a pre-pass that removes the pinned registers from the
  ;; pools, hides the pinned vregs from the scan, delegates the rest to
  ;; `allocate`, and merges the pins back into the result.
  ;;
  ;; The cost of doing it as a wrapper rather than inside linear scan: a pinned
  ;; register is withheld for the WHOLE block, not just for the pinned vreg's
  ;; live range. For return placement that is nearly free, because the register
  ;; the return pins is either scratch (rax, in no pool to begin with) or one
  ;; register out of a pool, and the pin is at the end of the block anyway.

  (define-record-type (pin make-pin pin?)
    (fields vreg reg class))

  ;; Is this pin sound? Three ways to be legal, in decreasing order of comfort:
  ;;
  ;; 1. The ordinary partition rule: the register is in the pool for that
  ;;    storage class. `assignment-ok?` decides.
  ;; 2. The register is scratch, so it is in no pool, and the partition doc says
  ;;    it belongs to the class being pinned. rax for a raw word is this case,
  ;;    and it is a GOOD case: no live range can ever occupy a non-allocatable
  ;;    register, so a pin to one can never conflict with anything.
  ;; 3. The register is outside the value class but the convention declares it
  ;;    `scratch-live`, meaning the collector is told to scavenge it here. This
  ;;    is the ONLY way a tagged value may be pinned outside the value class,
  ;;    and it exists because x86-64's return convention needs it.
  (define (pin-ok? cc sc r)
    (let* ((a (callconv-arch cc))
           (cls (reg-class a r)))
      (cond
       ((assignment-ok? a sc r) #t)
       ((eq? sc 'tagged) (and (memq r (callconv-scratch-live cc)) #t))
       ((eq? cls 'scratch)
        (let ((declared (assq r (callconv-scratch-classes cc))))
          (and declared
               (case sc
                 ((raw-word) (eq? (cdr declared) 'raw))
                 ((raw-f64)  (eq? (cdr declared) 'float))
                 (else #f)))))
       (else #f))))

  (define (check-pins! cc pins)
    (for-each
     (lambda (p)
       (unless (pin-ok? cc (pin-class p) (pin-reg p))
         (error 'check-pins!
                (if (eq? (pin-class p) 'tagged)
                    "a tagged value pinned outside the value class is a root the collector will never find, and this convention does not declare that register scratch-live"
                    "a raw value pinned into the value class makes the collector scavenge a non-pointer")
                (callconv-name cc) (pin-vreg p) (pin-class p) (pin-reg p))))
     pins))

  ;; Two vregs pinned to the same physical register are fine if their live
  ;; ranges are disjoint, which is the normal case for two returns in one
  ;; procedure. Overlapping is not fine and there is nothing to negotiate.
  (define (pins-conflict? instrs pins)
    (let ((ivals (live-intervals instrs)))
      (define (interval v)
        (let loop ((is ivals))
          (cond ((null? is) #f)
                ((eq? (car (car is)) v) (car is))
                (else (loop (cdr is))))))
      (let outer ((ps pins))
        (cond
         ((null? ps) #f)
         (else
          (let ((a (car ps)))
            (let inner ((qs (cdr ps)))
              (cond
               ((null? qs) (outer (cdr ps)))
               ((and (eq? (pin-reg a) (pin-reg (car qs)))
                     (let ((ia (interval (pin-vreg a)))
                           (ib (interval (pin-vreg (car qs)))))
                       (and ia ib
                            (<= (cadr ia) (caddr ib))
                            (<= (cadr ib) (caddr ia)))))
                (cons (pin-vreg a) (pin-vreg (car qs))))
               (else (inner (cdr qs)))))))))))

  ;; Build the pins that place a procedure's return values. `specs` is a list of
  ;; (vreg . storage-class) in value order. This is the whole of bead 6cm.10 as
  ;; an API: `(ret v)` stays a bare ret and the placement is a constraint.
  ;;
  ;; Written as an explicit loop, not `map`: the per-class counter is state and
  ;; Chez's `map` does not promise to walk the list left to right.
  (define (precolor-returns cc specs)
    (let ((used (make-eq-hashtable)))
      (let loop ((ss specs) (acc '()))
        (if (null? ss)
            (reverse acc)
            (let* ((v (car (car ss))) (sc (cdr (car ss)))
                   (i (hashtable-ref used sc 0))
                   (r (nth-or-false (return-registers cc sc) i)))
              (hashtable-set! used sc (+ i 1))
              (unless r
                (error 'precolor-returns
                       "more values returned in registers than the convention has"
                       (callconv-name cc) sc (+ i 1)))
              (loop (cdr ss) (cons (make-pin v r sc) acc)))))))

  (define (precolor-return cc vreg sc)
    (car (precolor-returns cc (list (cons vreg sc)))))

  (define (without lst regs)
    (filter (lambda (r) (not (memq r regs))) lst))

  ;; Hide a pinned vreg from `live-intervals` by replacing it with a non-symbol.
  ;; live-intervals only records operands satisfying `symbol?`, so a pinned vreg
  ;; rewritten this way never enters the scan and `allocate` never tries to give
  ;; it a register.
  (define (hide instrs pinned)
    (define (sub x)
      (if (and (symbol? x) (memq x pinned)) (list 'pinned x) x))
    (map (lambda (ins)
           (cons (car ins)
                 (cons (sub (cadr ins))
                       (cons (caddr ins) (map sub (cdddr ins))))))
         instrs))

  ;; The entry point. Same shape as `allocate`, plus pins.
  (define (allocate/precolored cc instrs classes pins)
    (check-pins! cc pins)
    (let ((clash (pins-conflict? instrs pins)))
      (when clash
        (error 'allocate/precolored
               "two vregs pinned to the same register with overlapping live ranges"
               (car clash) (cdr clash))))
    (let* ((a (callconv-arch cc))
           (taken (map pin-reg pins))
           (pinned-vregs (map pin-vreg pins))
           ;; The pools minus what the pins claimed. Scratch pins remove
           ;; nothing, because scratch was never in a pool.
           (reduced (make-arch (arch-name a)
                               (without (arch-value a) taken)
                               (without (arch-raw a) taken)
                               (without (arch-float a) taken)
                               (arch-structural a)
                               (arch-scratch a)))
           (result (allocate reduced (hide instrs pinned-vregs) classes))
           (m (alloc-result-map result)))
      (for-each (lambda (p) (hashtable-set! m (pin-vreg p) (pin-reg p))) pins)
      ;; The ORIGINAL arch goes back out. Callers reason about the real
      ;; partition, not the temporarily narrowed one.
      (make-alloc-result a m (alloc-result-spills result))))

  ;; The same, over a CFG rather than one block.
  ;;
  ;; `hide` cannot be reused: a block carries its transfer separately from its
  ;; instructions, and `ret`/`branch-if` read a vreg there. A pinned vreg left
  ;; visible in a transfer would put its live range back into the scan, which
  ;; is the one thing the hiding exists to prevent.
  (define (hide-blocks blocks pinned)
    (define (sub x)
      (if (and (symbol? x) (memq x pinned)) (list 'pinned x) x))
    (define (sub-instr i)
      ;; op, dst, storage class, then operands. The class is not an operand and
      ;; a shorter instruction has no operands to rewrite.
      (if (< (length i) 3)
          (cons (car i) (map sub (cdr i)))
          (cons (car i)
                (cons (sub (cadr i)) (cons (caddr i) (map sub (cdddr i)))))))
    (define (sub-transfer t)
      (case (car t)
        ((branch-if) (cons 'branch-if (cons (sub (cadr t)) (cddr t))))
        ((ret)       (if (pair? (cdr t)) (list 'ret (sub (cadr t))) t))
        (else t)))
    (map (lambda (b)
           (let ((blk (cadr b)))
             (list (car b)
                   (list 'block (map sub-instr (cadr blk))
                         (sub-transfer (caddr blk))))))
         blocks))

  ;; `destroys-of` is optional and is the SAME thing finalize.ss hands the
  ;; unpinned path: a call instruction -> the registers that call can destroy, or
  ;; #f for "assume everything".
  ;;
  ;; It has to be threaded here rather than left out because of which functions
  ;; take this path. A function has pins exactly when it has PARAMETERS, which is
  ;; nearly all of them, so passing them through `allocate-program` -- whose
  ;; `destroys-of` is the constant #f -- meant the clobber analysis applied to
  ;; almost nothing. Measured on fannkuch: `count-flips` spilled its flip counter
  ;; to the stack and incremented it there, `mov %r13,0x8(%rsp)` then `addq
  ;; $0x1,0x8(%rsp)`, across a call to a LEAF that writes neither r13 nor any
  ;; other callee-saved register. The information to keep it in a register was
  ;; computed and then discarded at this boundary.
  (define allocate-program/precolored
    (case-lambda
      [(cc blocks classes pins)
       (allocate-program/precolored cc blocks classes pins (lambda (i) #f))]
      [(cc blocks classes pins destroys-of)
       (allocate-program/precolored* cc blocks classes pins destroys-of)]))

  (define (allocate-program/precolored* cc blocks classes pins destroys-of)
    (check-pins! cc pins)
    ;; No live-range test here, unlike the single-block entry point. Pins over a
    ;; CFG come from the parameter list, where distinct parameters take distinct
    ;; argument registers by construction; two pins on one register would be a
    ;; bug in the caller, so it is checked directly and cheaply.
    (let ((rs (map pin-reg pins)))
      (unless (= (length rs) (length (remove-duplicates rs)))
        (error 'allocate-program/precolored*
               "two pins claim the same register" rs)))
    (let* ((a (callconv-arch cc))
           (taken (map pin-reg pins))
           (pinned-vregs (map pin-vreg pins))
           (reduced (make-arch (arch-name a)
                               (without (arch-value a) taken)
                               (without (arch-raw a) taken)
                               (without (arch-float a) taken)
                               (arch-structural a)
                               (arch-scratch a)))
           (result (allocate-program/clobbers reduced
                                              (hide-blocks blocks pinned-vregs)
                                              classes destroys-of))
           (m (alloc-result-map result)))
      (for-each (lambda (p) (hashtable-set! m (pin-vreg p) (pin-reg p))) pins)
      (make-alloc-result a m (alloc-result-spills result))))

  (define (remove-duplicates xs)
    (let loop ((xs xs) (acc '()))
      (cond ((null? xs) (reverse acc))
            ((memq (car xs) acc) (loop (cdr xs) acc))
            (else (loop (cdr xs) (cons (car xs) acc))))))
  )
