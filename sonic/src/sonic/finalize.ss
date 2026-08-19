;;; From allocated blocks to a flat listing the assembler can take.
;;;
;;; This is the seam between the register allocator and `object.ss`. Selection
;;; produces blocks of TARGET instructions still naming virtual registers;
;;; `assemble-function` wants one flat list where bare symbols are labels and
;;; everything else is an instruction over PHYSICAL registers. Nothing joined
;;; the two, which is why the compiler could report "33 blocks selected, 0
;;; spills" and still not be able to emit a single byte.
;;;
;;; Three jobs, and the order is forced.
;;;
;;; ## 1. Rewrite virtuals to physicals
;;;
;;; Straight substitution from `alloc-result-map`. A name that is ALREADY in a
;;; register class is left alone: selection puts scratch registers directly into
;;; operands, because the two-address fixup runs after allocation and has no
;;; vreg to ask for. Rewriting one would undo the fixup it exists to perform.
;;;
;;; ## 2. Spill code
;;;
;;; A spilled vreg has no register, so every use needs a reload and every
;;; definition needs a store, both through a scratch. This is exactly why the
;;; scratch registers sit outside every allocatable pool (regs.ss): no live
;;; range can be occupying one.
;;;
;;; The constraint that shapes this pass is scratch COUNT. RV64 reserves two
;;; integer scratches (t0, t1) and one float (ft11); x86-64 reserves one of
;;; each (rax, xmm15). An instruction with two spilled sources in the same file
;;; needs two scratches, so on x86-64 it is not expressible, and this pass
;;; refuses rather than emitting code whose second reload clobbers the first.
;;;
;;; That refusal is reachable, not hedging. It is not reached by nbody, whose
;;; worst function spills 4 values at a peak pressure of 8 against 4 registers.
;;; When it is reached the answer is live-range splitting in the ALLOCATOR, not
;;; a second scratch here: a second scratch costs a register on the target that
;;; already has the fewest.
;;;
;;; ## 3. Frame
;;;
;;; The prologue reserves the spill area; the epilogue releases it before every
;;; return AND before every tail call, since a tail call jumps and never comes
;;; back to unwind.
;;;
;;; The frame also carries an OUTGOING ARGUMENT AREA, at the bottom, for calls
;;; whose arguments overflow the register set. See the diagram on
;;; `frame-layout` for the arithmetic that makes both sides of a call agree
;;; without either knowing the other's frame size.
;;;
;;; No callee-saved saves, because the allocator has not been told which
;;; registers a call clobbers. That one is still refused rather than omitted, so
;;; a program that grows one fails loudly instead of quietly corrupting its own
;;; return address.

(library (sonic finalize)
  (export finalize-function finalize-program
          make-frame-layout frame-layout? frame-layout-map frame-layout-count
          frame-layout-bytes frame-layout-outgoing
          frame-slot-offset frame-incoming-offset frame-borrow-offset
          make-spiller spiller? spiller-target
          spiller-x86-64 spiller-rv64 spiller-for
          finalized? finalized-name finalized-listing
          merge-identical-functions
          finalized-frame finalized-spills)
  (import (chezscheme)
          (sonic regs)
          (sonic regalloc) (sonic runtime)
          (sonic callconv)
          (sonic parcopy)
          (sonic peephole))

  ;; --- frame layout ---------------------------------------------------------

  ;; THE FRAME, bottom to top, as this compiler lays it out:
  ;;
  ;;     [rsp + bytes + 8 + 8i]   incoming stack argument i
  ;;     [rsp + bytes]            return address
  ;;     ---------------------    the prologue's `sub rsp, bytes`
  ;;     [rsp + 8*(out + i)]      spill slot i
  ;;     [rsp + 8i]               OUTGOING stack argument i
  ;;     rsp
  ;;
  ;; The outgoing area is at the BOTTOM, and that placement is what makes the
  ;; arithmetic close. A caller writes outgoing argument i at [rsp + 8i]; the
  ;; `call` pushes a return address, so the callee's rsp is 8 lower, and after
  ;; its own prologue the callee finds that word at [rsp + bytes + 8 + 8i].
  ;; Both sides compute the same address without either knowing the other's
  ;; frame size.
  ;;
  ;; Spill slots used to start at [rsp+0] and there was no outgoing area at
  ;; all, so a call with more arguments than registers stored them straight
  ;; over the caller's own spilled values. That never fired only because the
  ;; CALLEE side could not read a stack argument either -- it asked the
  ;; convention for the fifth raw argument register, got #f, and handed the
  ;; encoder a move from nothing.
  (define-record-type (frame-layout make-frame-layout frame-layout?)
    (fields map         ; vreg -> slot index
            count       ; number of spill slots
            outgoing))  ; words reserved for outgoing stack arguments

  ;; --- functions that are the same function ----------------------------------
  ;;
  ;; `unroll-program` duplicates a loop body and `lift.ss` turns each copy into
  ;; its own function, so the two halves of fannkuch's reversal arrive here as
  ;; FOUR functions that are pairwise identical -- same instructions, same
  ;; operands, different label names. nbody's `inner%24` arrives twice the same
  ;; way. Measured: 123 instructions of fannkuch and 103 of nbody are exact
  ;; copies (D121).
  ;;
  ;; WHY MERGING THEM IS THE POINT, and not merely tidy. D116 measured that
  ;; disabling unrolling makes fannkuch 5.6% faster, because 25.2% of its cycles
  ;; are front-end stalled on branch mispredicts (D112) and duplicating a hot
  ;; loop doubles its branch targets. But unrolling is what lets the interval
  ;; analysis discharge nbody's fourteen bounds checks (D118), so it cannot
  ;; simply be turned off.
  ;;
  ;; Merging here gets both: the duplication is present for the ANALYSIS, which
  ;; runs long before this, and absent from the CODE. That is D116's "unroll for
  ;; the analysis, re-roll before code generation" in the one form that does not
  ;; need loop structure recovered -- two finalized listings either are the same
  ;; sequence or they are not.
  ;;
  ;; SOUNDNESS. Two functions with identical instruction sequences compute the
  ;; same thing, so redirecting calls is safe by construction. The care is in
  ;; INTERNAL labels: D97's frame reuse retargets a tail call to `<name>.loop`,
  ;; so a dropped function's internal labels are referenced from outside it. The
  ;; correspondence is positional -- the listings are identical modulo naming --
  ;; so the nth label of the dropped function maps to the nth of the kept one.
  ;; The labels a listing DEFINES -- the bare symbols in it. Everything else it
  ;; names is somebody else's.
  (define (defined-labels listing)
    (let ((t (make-eq-hashtable)))
      (for-each (lambda (i) (when (symbol? i) (hashtable-set! t i #t))) listing)
      t))

  ;; ONLY INTERNAL LABELS ARE RENUMBERED. Canonicalising every label was
  ;; unsound: a call to `foo` and a call to `bar` both became "the nth label",
  ;; so two functions calling DIFFERENT functions compared as identical. The
  ;; suite caught it as `label defined twice`, which is the mild symptom; the
  ;; severe one is merging two functions that do different things.
  (define (canonical-listing listing)
    (let ((own (defined-labels listing)) (m (make-eq-hashtable)) (n 0))
      (define (lab x)
        (if (hashtable-ref own x #f)
            (or (hashtable-ref m x #f)
                (begin (set! n (+ n 1)) (hashtable-set! m x n) n))
            x))                                  ; external: compare by NAME
      (map (lambda (i)
             (if (symbol? i)
                 (list 'L (lab i))
                 (let walk ((x i))
                   (cond ((and (pair? x) (eq? (car x) 'label) (symbol? (cadr x)))
                          (list 'label (lab (cadr x))))
                         ((pair? x) (cons (walk (car x)) (walk (cdr x))))
                         (else x)))))
           listing)))

  ;; Every label a listing defines or names, in order of first appearance --
  ;; the same order `canonical-listing` numbers them in.
  ;; Restricted to the labels the listing DEFINES, for the same reason: the
  ;; positional correspondence is only meaningful for those, and mapping an
  ;; external call target positionally would redirect a call.
  (define (listing-labels listing)
    (let ((own (defined-labels listing)) (seen (make-eq-hashtable)) (acc '()))
      (define (note x)
        (when (and (hashtable-ref own x #f) (not (hashtable-ref seen x #f)))
          (hashtable-set! seen x #t)
          (set! acc (cons x acc))))
      (for-each (lambda (i)
                  (if (symbol? i)
                      (note i)
                      (let walk ((x i))
                        (cond ((and (pair? x) (eq? (car x) 'label) (symbol? (cadr x)))
                               (note (cadr x)))
                              ((pair? x) (walk (car x)) (walk (cdr x)))
                              (else #f)))))
                listing)
      (reverse acc)))

  (define (rename-labels listing m)
    (map (lambda (i)
           (if (symbol? i)
               (or (hashtable-ref m i #f) i)
               (let walk ((x i))
                 (cond ((and (pair? x) (eq? (car x) 'label) (symbol? (cadr x)))
                        (list 'label (or (hashtable-ref m (cadr x) #f) (cadr x))))
                       ((pair? x) (cons (walk (car x)) (walk (cdr x))))
                       (else x)))))
         listing))

  (define (merge-identical-functions fns)
    (let ((by-shape (make-hashtable equal-hash equal?))
          (rename (make-eq-hashtable)))
      ;; FIRST WINS, in the order finalize produced them, so the choice does not
      ;; depend on hashing.
      (for-each
       (lambda (f)
         (let* ((k (canonical-listing (finalized-listing f)))
                (keep (hashtable-ref by-shape k #f)))
           (if keep
               ;; Positional correspondence, as argued above.
               (for-each (lambda (from to) (hashtable-set! rename from to))
                         (listing-labels (finalized-listing f))
                         (listing-labels (finalized-listing keep)))
               (hashtable-set! by-shape k f))))
       fns)
      (if (zero? (hashtable-size rename))
          fns
          (let ((kept (filter (lambda (f)
                                (not (hashtable-ref rename (finalized-name f) #f)))
                              fns)))
            (map (lambda (f)
                   (make-finalized (finalized-name f)
                                   (rename-labels (finalized-listing f) rename)
                                   (finalized-frame f)
                                   (finalized-spills f)))
                 kept)))))

  (define-record-type (finalized make-finalized finalized?)
    (fields name listing frame spills))

  ;; Every storage class this compiler has is 8 bytes wide -- a double, a
  ;; machine word and a tagged value all are -- so a slot is one word.
  (define slot-bytes 8)

  (define (frame-layout-bytes f)
    ;; Both ABIs want the stack pointer 16-byte aligned at a call boundary, so
    ;; the reservation is rounded up rather than left at 8*n. Getting this wrong
    ;; does not fault on either target; it misaligns every SSE spill on x86-64,
    ;; where a 16-byte load from an unaligned address DOES fault, and that fault
    ;; would point at the load rather than at the prologue that caused it.
    (let ((n (* slot-bytes (+ (frame-layout-outgoing f) (frame-layout-count f)
                              borrow-words))))
      (if (zero? (modulo n 16)) n (+ n 8))))

  ;; TWO RESERVED WORDS AT THE TOP OF EVERY FRAME.
  ;;
  ;; An instruction can need more registers than the target reserves as
  ;; scratch. `(vector-set! v i x)` with both the index and the value spilled is
  ;; the case that forced this: the destination is the memory operand, so the
  ;; one x86-64 allows is spent, and the target reserves a single integer
  ;; scratch, so the second reload has nowhere to go. It used to raise.
  ;;
  ;; So an allocatable register is BORROWED for the length of that one
  ;; instruction -- saved here, used as a second scratch, restored after. That
  ;; is a live-range split of the narrowest possible kind, which is what the old
  ;; refusal said the real fix was.
  ;;
  ;; Reserved unconditionally rather than on demand, because the frame is laid
  ;; out before the instruction that needs it is rewritten. Sixteen bytes of
  ;; stack and no instructions when nothing borrows.
  (define borrow-words 2)

  (define (frame-borrow-offset f k)
    (* slot-bytes (+ (frame-layout-outgoing f) (frame-layout-count f) k)))

  ;; Spill slots sit ABOVE the outgoing area, which is why this adds it in.
  ;; Getting the shift wrong is not a fault: it aliases a spilled value onto an
  ;; outgoing argument, so a call silently overwrites a live local.
  (define (frame-slot-offset f v)
    (let ((i (hashtable-ref (frame-layout-map f) v #f)))
      (and i (* slot-bytes (+ (frame-layout-outgoing f) i)))))

  ;; The offset at which the CALLEE finds its i'th incoming stack argument,
  ;; measured from its own stack pointer after the prologue. See the diagram on
  ;; `frame-layout`: past the whole frame, past the return address if there is
  ;; one, then i words up.
  ;;
  ;; THE RETURN-ADDRESS WORD IS x86-64 ONLY, and this used to add it
  ;; unconditionally. `call` PUSHES the return address, so an x86-64 callee's
  ;; rsp is 8 lower than the caller's outgoing area and the word must be
  ;; stepped over. RV64's `jal` writes the return address into `ra`, a
  ;; REGISTER: nothing is pushed, the callee's sp is exactly the caller's, and
  ;; stepping over a word that is not there reads 8 bytes too high.
  ;;
  ;; Measured before the fix, in a nested counted loop: a return sequence did
  ;; `ld t0,8(sp)` where the value sat at [sp+0], loaded a stack address
  ;; instead of its accumulator, and returned it. The garbage became the outer
  ;; loop's bound, so `j < n` compared against a pointer and the program never
  ;; terminated. The cause was three frames away from the symptom.
  (define (frame-incoming-offset target f i . opt)
    (+ (frame-layout-bytes f)
       (if (eq? target 'rv64) 0 slot-bytes)
       ;; The ra area, when the function saves ra: it sits between this frame
       ;; and the caller's outgoing area, so a callee reading its own incoming
       ;; arguments must step over it.
       (if (pair? opt) (car opt) 0)
       (* slot-bytes i)))

  ;; Substitute the symbolic `(incoming i)` displacements the tail-call emitters
  ;; leave behind. Selection cannot compute these -- the offset is measured from
  ;; the CALLER'S frame, and the frame is not laid out until here -- so the
  ;; marker travels through selection, allocation and spill rewriting as an
  ;; opaque list and is resolved once, on the finished listing.
  ;;
  ;; Rewritten everywhere rather than at known positions, because the two
  ;; targets put it in different places: x86-64 inside a memory operand,
  ;; RV64 as a bare offset field on the store.
  (define (patch-incoming target frame x)
    (cond
     ((and (pair? x) (eq? (car x) 'incoming))
      (frame-incoming-offset target frame (cadr x)))
     ((pair? x) (cons (patch-incoming target frame (car x))
                      (patch-incoming target frame (cdr x))))
     (else x)))

  ;; TWO SPILLED VREGS CONNECTED BY A MOVE SHARE A SLOT.
  ;;
  ;; A `(move a b)` whose two ends both spilled becomes a reload into the scratch
  ;; and a store back out -- two instructions to copy a value from one frame slot
  ;; to another. Given the same slot it is a copy from a place to itself, and
  ;; `do-instr` emits nothing at all.
  ;;
  ;; SOUND BECAUSE LMACH IS SINGLE-ASSIGNMENT, and that is the whole argument.
  ;; `a` is defined by this move and nowhere else, `b` by its own definition and
  ;; nowhere else, and the move makes them equal -- so one slot holds one value
  ;; for the life of both. Nothing here has to reason about liveness or overlap.
  ;;
  ;; ONLY AN LMACH `move`. The trap is that a two-address fixup looks the same in
  ;; the emitted listing: `(add-imm d 1 src)` becomes `mov d, src` then
  ;; `add d, 1`, and reading THAT as a copy would coalesce d with src and then
  ;; increment src in place. qaq.7.7 fell into exactly that reading. The alias
  ;; map is built from Lmach, before any of those exist.
  (define (move-aliases blocks spilled?)
    (let ((find (make-eq-hashtable)))
      (define (root x)
        (let ((p (hashtable-ref find x #f)))
          (if p (let ((r (root p))) (hashtable-set! find x r) r) x)))
      (for-each
       (lambda (lb)
         (for-each
          (lambda (i)
            (when (and (pair? i) (eq? (car i) 'move) (= (length i) 4)
                       (symbol? (cadr i)) (symbol? (cadddr i))
                       (spilled? (cadr i)) (spilled? (cadddr i)))
              (let ((ra (root (cadr i))) (rb (root (cadddr i))))
                (unless (eq? ra rb) (hashtable-set! find ra rb)))))
          (cadr (cadr lb))))
       blocks)
      root))

  (define (build-frame spills outgoing . opt)
    (let ((tbl (make-eq-hashtable))
          ;; vreg -> the representative whose slot it shares, or itself
          (rep (if (pair? opt) (car opt) (lambda (v) v))))
      (let loop ((vs spills) (i 0))
        (if (null? vs)
            (make-frame-layout tbl i outgoing)
            (let* ((v (car vs)) (r (rep v)))
              (cond
               ((hashtable-ref tbl v #f) (loop (cdr vs) i))
               ;; the representative already has a slot: share it
               ((hashtable-ref tbl r #f)
                => (lambda (k) (hashtable-set! tbl v k) (loop (cdr vs) i)))
               (else (hashtable-set! tbl v i)
                     (unless (eq? r v) (hashtable-set! tbl r i))
                     (loop (cdr vs) (+ i 1)))))))))

  ;; How many words of outgoing argument area this function needs: the most any
  ;; one of its calls overflows by. Read off the Lmach blocks rather than the
  ;; selected stream, because Lmach still names the arguments as vregs and the
  ;; class table answers for each of them; by the time selection has run, the
  ;; stores exist and the count would have to be recovered from them.
  ;;
  ;; A tail call is also spelled `call` in Lmach -- the language has no tailcall
  ;; production, select.ss recognises the SHAPE -- so this counts both, which is
  ;; what we want: a tail call's outgoing area is the caller's incoming one, and
  ;; sizing for the larger of the two costs at most a few words.
  ;; How many of this function's own parameters arrive on the stack. The same
  ;; per-class walk the arrival code does, and the number a tail call out of
  ;; here is allowed to overwrite.
  (define (incoming-stack-words target params classes)
    (let ((cc (callconv-by-name target)) (n (make-eq-hashtable)))
      (fold-left
       (lambda (acc p)
         (let* ((c (or (hashtable-ref classes p #f) 'raw-word))
                (k (hashtable-ref n c 0)))
           (hashtable-set! n c (+ k 1))
           (if (arg-register cc c k) acc (+ acc 1))))
       0 params)))

  ;; The stack words needed by the TAIL calls specifically. Lmach has no
  ;; tailcall production -- select.ss recognises the shape, a call that is the
  ;; block's last instruction whose result the transfer returns -- so the same
  ;; shape test is applied here.
  (define (tail-outgoing-words-for target blocks classes)
    (let ((cc (callconv-by-name target)))
      (fold-left
       (lambda (most b)
         (let* ((blk (cadr b))
                (is (cadr blk))
                (t (caddr blk))
                (last (and (pair? is) (car (reverse is)))))
           (if (and last (pair? last) (eq? (car last) 'call)
                    (pair? t) (eq? (car t) 'ret) (eq? (cadr t) (cadr last)))
               (max most
                    (stack-words-for-args
                     cc (map (lambda (a)
                               (or (and (symbol? a) (hashtable-ref classes a #f))
                                   'raw-word))
                             (cddddr last))))
               most)))
       0 blocks)))

  ;; --- parameters pinned to the registers they arrive in ---------------------
  ;;
  ;; A parameter arrives in `arg-register(class, k)`. The allocator knows
  ;; nothing about that and puts it wherever its scan had room, so the arrival
  ;; is a real move -- and a self tail call has to put the value BACK into the
  ;; argument register before jumping. nbody's inner loop paid both ends:
  ;;
  ;;     inner%24:  mov rbx, r9      mov rax, rcx     ; four moves rotating
  ;;                mov rcx, rdx     mov rdx, rsi     ; parameters into place
  ;;                mov rsi, rax     mov r9, [rsp+24]
  ;;                ...
  ;;                mov [rsp+24], r9  mov rdx, rcx    ; and four rotating them
  ;;                mov rcx, rsi      mov r9, rbx     ; back out
  ;;                mov rsi, r11      jmp inner%24
  ;;
  ;; Eleven instructions of pure shuffling per iteration, none of which computes
  ;; anything. It is a ROTATION, not a spill: every parameter is in some other
  ;; parameter's argument register. Pinning each to its own makes the arrival
  ;; `mov r, r`, which the peephole deletes, and makes a loop-carried parameter
  ;; that does not change an identity move on the back edge as well.
  ;;
  ;; ONLY WHERE EVERY CALL IS A TAIL CALL. Argument registers are caller-saved,
  ;; so a parameter live across an ordinary call is destroyed by it -- and the
  ;; allocator would have spilled it, which is exactly the decision a pin
  ;; overrides. A tail call is a jump: nothing is live after it, so there is
  ;; nothing to destroy.
  (define (every-call-is-tail? blocks)
    (for-all
     (lambda (b)
       (let* ((blk (cadr b)) (is (cadr blk)) (t (caddr blk)))
         (let loop ((is is))
           (cond
            ((null? is) #t)
            ((not (eq? (car (car is)) 'call)) (loop (cdr is)))
            ;; A tail call is the last instruction of a block whose transfer
            ;; returns precisely its result.
            (else (and (null? (cdr is))
                       (pair? t) (eq? (car t) 'ret)
                       (pair? (cdr t)) (eq? (cadr t) (cadr (car is)))))))))
     blocks))

  ;; The counter walk here must agree instruction-for-instruction with the one
  ;; that builds the arrivals in `finalize-function`, because the whole point is
  ;; that the pin names the register the arrival would have moved out of.
  (define (parameter-pins target blocks params classes)
    (if (or (null? params) (not (every-call-is-tail? blocks)))
        '()
        (let ((cc (callconv-by-name target)))
          (let loop ((ps params) (n (make-eq-hashtable)) (acc '()))
            (if (null? ps)
                (reverse acc)
                (let* ((p (car ps))
                       (c (hashtable-ref classes p #f))
                       (k (and c (hashtable-ref n c 0)))
                       (r (and c (arg-register cc c k))))
                  (when c (hashtable-set! n c (+ k 1)))
                  (loop (cdr ps) n
                        ;; No register means this parameter overflowed onto the
                        ;; stack; there is nothing to pin it to.
                        (if (and r (pin-ok? cc c r))
                            (cons (make-pin p r c) acc)
                            acc))))))))

  ;; Which spilled vregs can be REBUILT rather than reloaded.
  ;;
  ;; A vreg whose Lmach definition is `(const v sc d)` need not occupy a frame
  ;; slot at all: recreating it is one instruction, and a store plus one reload
  ;; is already two. nbody's pairwise force loop stored the constant 1 and read
  ;; it back twice.
  ;;
  ;; Read off Lmach rather than the selected stream, because Lmach still says
  ;; `const` -- by selection time it is a `mov` with an immediate and looks like
  ;; any other move.
  (define (remat-table target blocks classes)
    (let ((sp (spiller-for target))
          (tbl (make-eq-hashtable)))
      (for-each
       (lambda (lb)
         (for-each
          (lambda (i)
            (when (and (pair? i) (eq? (car i) 'const) (= (length i) 4)
                       ((spiller-remat sp) 'r (cadddr i) (caddr i)))
              (hashtable-set! tbl (cadr i) (cadddr i))))
          (cadr (cadr lb))))
       blocks)
      tbl))

  (define (outgoing-words-for target blocks classes)
    (let ((cc (callconv-by-name target)))
      (let loop ((bs blocks) (most 0))
        (if (null? bs)
            most
            (loop (cdr bs)
                  (let inner ((is (cadr (cadr (car bs)))) (m most))
                    (cond
                     ((null? is) m)
                     ((and (pair? (car is)) (eq? (car (car is)) 'call))
                      ;; (call dst sc callee arg ...) -- the callee is a label.
                      (let* ((args (cddddr (car is)))
                             (cs (map (lambda (a)
                                        (or (and (symbol? a)
                                                 (hashtable-ref classes a #f))
                                            'raw-word))
                                      args)))
                        (inner (cdr is) (max m (stack-words-for-args cc cs)))))
                     (else (inner (cdr is) m)))))))))

  ;; --- per-target spellings -------------------------------------------------
  ;;
  ;; Everything target-specific this pass needs, in one record, so the pass
  ;; itself has no `case` on the target name.

  (define-record-type (spiller make-spiller spiller?)
    (fields target
            reload        ; (reg offset class) -> instrs
            store         ; (offset reg class) -> instrs
            prologue      ; (bytes) -> instrs
            epilogue      ; (bytes) -> instrs
            int-scratch   ; list, in the order this pass may take them
            float-scratch
            mem-operand   ; (offset class) -> an operand, or #f if the ISA has none
            ;; instr -> the ONE operand position that may be memory, or #f for
            ;; "any but the destination". Three-address VEX needs this: its
            ;; first source rides in a prefix field that holds a register
            ;; number and cannot name memory.
            mem-position
            ;; (reg datum class) -> instructions that recreate the value, or #f
            ;; when this target cannot do it in ONE instruction. A constant that
            ;; takes two to rebuild is not cheaper than a reload, and the whole
            ;; argument for rematerialising is that it is.
            remat
            returns?      ; instr -> #t if control leaves here
            tail-jump?))  ; instr -> #t if it is a jump out of the function

  (define spiller-x86-64
    (make-spiller
     'x86-64
     (lambda (reg off sc)
       (if (eq? sc 'raw-f64)
           `((movsd ,reg (mem rsp #f 1 ,off)))
           `((mov ,reg (mem rsp #f 1 ,off)))))
     (lambda (off reg sc)
       (if (eq? sc 'raw-f64)
           `((movsd (mem rsp #f 1 ,off) ,reg))
           `((mov (mem rsp #f 1 ,off) ,reg))))
     (lambda (bytes) (if (zero? bytes) '() `((sub rsp (imm ,bytes)))))
     (lambda (bytes) (if (zero? bytes) '() `((add rsp (imm ,bytes)))))
     ;; DERIVED from regs.ss, not restated. These lists were literals, and when
     ;; a second float scratch was added for the three-address VEX forms the
     ;; partition grew one and this did not, so the pass kept refusing an
     ;; instruction it now had the registers for. regs.ss is the source of truth
     ;; for which registers are reserved; asking it is the only way the two
     ;; cannot drift.
     (arch-int-scratch arch-x86-64)
     (arch-float-scratch arch-x86-64)
     ;; x86-64 reads memory directly, which is the whole reason it gets away
     ;; with four raw registers. A spilled SOURCE does not need a scratch at
     ;; all: `cmp rax, [rsp+16]` is one instruction. Exactly one operand may be
     ;; memory, so this covers the second spilled operand and no more.
     (lambda (off sc) `(mem rsp #f 1 ,off))
     ;; The three-address float forms take memory only in their last operand.
     (lambda (i)
       (and (pair? i)
            (memq (car i) '(vaddsd vsubsd vmulsd vdivsd))
            2))
     ;; `mov r64, imm32` is one instruction. A double would be a pool load,
     ;; which costs exactly what the reload it replaces costs, so it is not
     ;; rematerialised.
     (lambda (r d sc)
       (and (not (eq? sc 'raw-f64))
            (integer? d) (exact? d)
            (<= (- (expt 2 31)) d (- (expt 2 31) 1))
            `((mov ,r (imm ,d)))))
     (lambda (i) (eq? (car i) 'ret))
     (lambda (i) (and (eq? (car i) 'jmp)
                      (pair? (cdr i))
                      (pair? (cadr i))
                      (eq? (car (cadr i)) 'label)))))

  (define spiller-rv64
    (make-spiller
     'rv64
     (lambda (reg off sc)
       (if (eq? sc 'raw-f64) `((fld ,reg sp ,off)) `((ld ,reg sp ,off))))
     (lambda (off reg sc)
       (if (eq? sc 'raw-f64) `((fsd ,reg sp ,off)) `((sd ,reg sp ,off))))
     (lambda (bytes) (if (zero? bytes) '() `((addi sp sp ,(- bytes)))))
     (lambda (bytes) (if (zero? bytes) '() `((addi sp sp ,bytes))))
     (arch-int-scratch arch-rv64)
     (arch-float-scratch arch-rv64)
     ;; RV64 is load/store: no arithmetic instruction reads memory, so every
     ;; spilled operand costs a scratch. That is the trade the ISA makes, and it
     ;; is why RV64 reserves two integer scratches where x86-64 reserves one.
     #f
     ;; RV64 is load/store: `mem-operand` is already #f, so no operand of any
     ;; instruction may be memory and this is never consulted.
     (lambda (i) #f)
     ;; `addi rd, zero, imm` covers 12 bits signed in one instruction. Anything
     ;; wider is lui/addi, which is two, and two is not cheaper than a reload.
     (lambda (r d sc)
       (and (not (eq? sc 'raw-f64))
            (integer? d) (exact? d)
            (<= -2048 d 2047)
            `((addi ,r zero ,d))))
     (lambda (i) (and (eq? (car i) 'jalr) (equal? (cdr i) '(zero ra 0))))
     ;; `jal zero <label>` is an unconditional jump. Within a function that is a
     ;; block edge, not an exit, so the caller tells us which labels are ours.
     (lambda (i) (and (eq? (car i) 'jal) (eq? (cadr i) 'zero)))))

  (define (spiller-for target)
    (case target
      ((x86-64) spiller-x86-64)
      ((rv64) spiller-rv64)
      (else (error 'spiller-for "unknown target" target))))

  ;; --- operand rewriting ----------------------------------------------------
  ;;
  ;; An operand is a register name, an (imm n), a (mem base index scale disp), a
  ;; (label x), or a bare integer. Only register NAMES are rewritten, and only
  ;; those that are not already physical.

  (define (rewrite-operand arch assign x)
    (cond
     ((symbol? x)
      (if (reg-class arch x)
          x                                  ; already physical: leave it alone
          (or (hashtable-ref assign x #f) x)))
     ((and (pair? x) (eq? (car x) 'mem))
      (list 'mem
            (rewrite-operand arch assign (cadr x))
            (and (caddr x) (rewrite-operand arch assign (caddr x)))
            (cadddr x)
            (list-ref x 4)))
     (else x)))

  ;; A jump whose destination is a block of this function is an ordinary edge
  ;; and needs no epilogue. A jump to a function ENTRY is a tail call and does.
  ;;
  ;; The function's OWN entry is a tail-call target, not an ordinary edge, and
  ;; conflating the two is a stack leak that looks like nothing else. A loop is
  ;; a procedure that tail-calls itself, so the jump lands on its own entry
  ;; label; treating that as an intra-function edge skips the epilogue, and the
  ;; prologue at the entry then reserves ANOTHER frame. The stack grows by the
  ;; frame size every iteration until it runs out -- which for a loop with no
  ;; spills at all is zero bytes and no symptom, and for one with spills is a
  ;; segfault whose backtrace points at whatever was executing when the guard
  ;; page was hit.
  ;;
  ;; So `own-labels` excludes the entry.
  ;; ANY OPERAND THAT NAMES AN OWN LABEL, not the first symbol found.
  ;;
  ;; This used to stop at the first symbol-shaped operand, which is the target
  ;; on x86-64 -- `(jmp (label L))` has exactly one -- and is the DESTINATION
  ;; REGISTER on RV64: `(jal zero L)` writes the return address to `zero` and
  ;; jumps to L. So every RV64 branch reported its target as `zero`, which is in
  ;; no function's label list, so every intra-function edge was classified as a
  ;; TAIL CALL and got an epilogue.
  ;;
  ;; The exit blocks emit their own epilogue, so the frame was released twice on
  ;; the way out:
  ;;
  ;;     (addi sp sp 16)        <- spurious, from the misclassified edge
  ;;     (jal zero L.else6)
  ;;     L.else6: ... (addi sp sp 16) (jalr zero ra 0)
  ;;
  ;; leaving sp a frame too high. A later return then read its spilled result
  ;; from `[sp+8]`, got a stack address, and handed it back as the value -- which
  ;; became a loop bound three frames away, so a nested loop compared its index
  ;; against a pointer and never terminated. See bead 1mp.10.
  ;;
  ;; Scanning every operand is correct for both targets and needs no target
  ;; argument: a register name is never an own label, and object.ss's `rv-branchy`
  ;; handling already assumes the RV64 target is simply the operand that is a
  ;; label.
  (define (own-label? i own-labels)
    (let loop ((xs (cdr i)))
      (cond ((null? xs) #f)
            ((and (pair? (car xs)) (eq? (car (car xs)) 'label)
                  (memq (cadr (car xs)) own-labels))
             #t)
            ((and (symbol? (car xs)) (memq (car xs) own-labels)) #t)
            (else (loop (cdr xs))))))

  ;; --- the pass -------------------------------------------------------------

  ;; blocks     : ((lbl (instr ...)) ...) as select-program produces, in layout
  ;;              order, entry first
  ;; alloc      : the alloc-result for this function
  ;; classes    : vreg -> storage class
  ;; own-labels : the labels belonging to this function, so an intra-function
  ;;              jump is not mistaken for a tail call
  ;; `params` is this function's parameter list, in order, or '().
  (define (finalize-function target arch name blocks alloc classes own-labels . opt)
    (finalize-function* target arch name blocks alloc classes own-labels
                        (if (pair? opt) (car opt) '())
                        (if (and (pair? opt) (pair? (cdr opt))) (cadr opt) 0)
                        (if (and (pair? opt) (pair? (cddr opt))) (caddr opt) 0)
                        (if (and (pair? opt) (pair? (cdddr opt)))
                            (cadddr opt)
                            (make-eq-hashtable))
                        (if (and (pair? opt) (pair? (cdddr opt))
                                 (pair? (cddddr opt)))
                            (car (cddddr opt))
                            (lambda (v) v))
                        (if (and (pair? opt) (pair? (cdddr opt))
                                 (pair? (cddddr opt))
                                 (pair? (cdr (cddddr opt))))
                            (cadr (cddddr opt))
                            (make-eq-hashtable))))

  ;; `frames` maps a function name to `(frame-bytes . ra-bytes)`. It is both
  ;; written (this function records its own) and read (a tail call asks about its
  ;; target). Callee-first finalization is what makes the read meaningful, the
  ;; same property that lets `clobbers` work without a fixpoint.
  (define (finalize-function* target arch name blocks alloc classes own-labels
                              params outgoing tail-outgoing remat slot-rep
                              frames)
    (let* ((sp (spiller-for target))
           (assign (alloc-result-map alloc))
           (spills (alloc-result-spills alloc))
           (frame (build-frame spills outgoing slot-rep))
           (bytes (frame-layout-bytes frame))
           (spilled? (lambda (v) (and (symbol? v)
                                      (hashtable-ref (frame-layout-map frame) v #f)
                                      #t)))
           ;; REMATERIALISABLE: spilled, and cheaper to rebuild than to reload.
           ;; Every path that would otherwise touch this vreg's frame slot has
           ;; to agree, because nothing ever WRITES that slot -- see the four
           ;; uses below. The slot is still reserved; leaving it allocated costs
           ;; eight bytes of frame and keeps `spilled?` meaning one thing.
           (remat? (lambda (v) (and (symbol? v)
                                    (hashtable-ref (frame-layout-map frame) v #f)
                                    (hashtable-contains? remat v))))
           ;; THE TAIL-CALL CONDITION, checked where both numbers exist.
           ;;
           ;; A tail call's stack arguments are written over the caller's own
           ;; incoming argument area, because the jump pushes no return address and
           ;; the callee reads its stack arguments exactly where the caller's were.
           ;; That is sound as long as the callee needs no MORE words than the caller
           ;; received. Needing more means writing past the incoming area into the
           ;; caller's caller's frame, which is live.
           ;;
           ;; Growing the stack instead -- shifting the return address up and moving
           ;; the whole frame -- is what a compiler with a real shuffle does, and it
           ;; is a different piece of work. Refusing here is honest and, unlike the
           ;; refusal this replaces, it fires only on the case that is actually
           ;; unsound rather than on every tail call with a stack argument.
           (checked
            (let ((have (incoming-stack-words target params classes)))
              (when (> tail-outgoing have)
                (error 'finalize-function
                       (string-append
                        "a tail call needs more outgoing stack words than this "
                        "function received, so its outgoing area would be "
                        "written past the incoming one into a live frame; "
                        "growing the stack for a tail call needs a frame "
                        "shuffle this compiler does not have")
                       name tail-outgoing have)))))


      (define (class-of v)
        (or (hashtable-ref classes v #f)
            (error 'finalize-function "spilled vreg has no storage class" v)))

      ;; REMATERIALISING IS NOT FREE AT EVERY USE, and this is the pre-pass that
      ;; notices.
      ;;
      ;; A rematerialisable vreg has no valid frame slot, so it can never be the
      ;; operand that rides in memory: it must take a scratch. On x86-64 there
      ;; is one integer scratch and one memory operand per instruction, so
      ;; `(cmp t.7 t.8)` with both operands spilled needs exactly one of them in
      ;; memory -- and if both are rematerialisable, there is no candidate and
      ;; the pass refuses an instruction it used to handle.
      ;;
      ;; So rematerialising is decided per VREG, not per use: any vreg that some
      ;; instruction needs in memory is dropped from the table and goes back to
      ;; being stored and reloaded. Dropping is monotone -- it only ever adds
      ;; candidates -- so one pass settles it.
      ;;
      ;; The gain was always per-vreg anyway. Rebuilding costs the same as a
      ;; reload; what remat saves is the DEFINITION and the STORE, once.
      (define (un-remat-what-must-ride-in-memory!)
        (for-each
         (lambda (b)
           (for-each
            (lambda (i)
              (let* ((vs (distinct (apply append (map spilled-in (cdr i)))))
                     (float? (lambda (v) (eq? (class-of v) 'raw-f64)))
                     (ints (filter (lambda (v) (not (float? v))) vs))
                     (flts (filter float? vs))
                     (over (+ (max 0 (- (length ints) (length (spiller-int-scratch sp))))
                              (max 0 (- (length flts) (length (spiller-float-scratch sp)))))))
                (when (> over 0)
                  (let ((free (filter (lambda (v)
                                        (and (not (remat? v)) (mem-eligible* i v)))
                                      vs)))
                    ;; Not enough non-rematerialisable candidates: give the
                    ;; instruction back the ones it needs, cheapest first in
                    ;; source order since any of them will do.
                    (let give ((need (- over (length free)))
                               (cs (filter (lambda (v)
                                             (and (remat? v) (mem-eligible* i v)))
                                           vs)))
                      (when (and (> need 0) (pair? cs))
                        (hashtable-delete! remat (car cs))
                        (give (- need 1) (cdr cs))))))))
            (cadr b)))
         blocks))

      ;; The instructions that rebuild a rematerialisable vreg into `r`.
      (define (remat-into r v)
        (or ((spiller-remat sp) r (hashtable-ref remat v #f) (class-of v))
            (error 'finalize-function
                   "a vreg was marked rematerialisable and then could not be rebuilt"
                   v)))

      (define (scratches-for sc)
        (if (eq? sc 'raw-f64) (spiller-float-scratch sp) (spiller-int-scratch sp)))

      ;; Every spilled vreg this instruction mentions, ANYWHERE -- including
      ;; inside a (mem base index scale disp), which is where they hid: a
      ;; positional scan of the top-level operands missed a spilled index, so it
      ;; was never reloaded and the encoder saw a virtual register name in a
      ;; memory operand.
      (define (spilled-in x)
        (cond ((and (symbol? x) (spilled? x)) (list x))
              ((and (pair? x) (eq? (car x) 'mem))
               (append (spilled-in (cadr x)) (spilled-in (caddr x))))
              (else '())))

      (define (distinct xs)
        (let loop ((xs xs) (acc '()))
          (cond ((null? xs) (reverse acc))
                ((memq (car xs) acc) (loop (cdr xs) acc))
                (else (loop (cdr xs) (cons (car xs) acc))))))

      ;; A vreg is eligible to ride in memory only if it appears exactly once,
      ;; at TOP LEVEL, and is not the destination. Inside a memory operand it
      ;; cannot -- an address computation needs the value in a register -- and
      ;; twice it cannot, because one instruction may hold only one memory
      ;; operand.
      ;; WHICH operand position may be memory is per instruction, not just
      ;; "anything but the destination".
      ;;
      ;; A three-address VEX form carries its first source in the prefix's vvvv
      ;; field, which encodes a REGISTER NUMBER and has no memory form. Only the
      ;; r/m operand -- the last one -- can be a memory reference. Letting a
      ;; spilled value ride in position 1 produced `vaddsd xmm15, [rsp+8], xmm0`,
      ;; which the encoder refused; had it not, there is no way to encode it and
      ;; the refusal is the only correct answer.
      (define (mem-position-ok? i k)
        (let ((p ((spiller-mem-position sp) i)))
          (if p (= k p) (> k 0))))

      ;; A rematerialisable vreg may never be the operand that rides in memory:
      ;; its slot is never written, so the read would be garbage. It always
      ;; takes a scratch and is rebuilt into it.
      (define (mem-eligible i v)
        (if (remat? v)
            #f
            (mem-eligible* i v)))

      (define (mem-eligible* i v)
        (let loop ((xs (cdr i)) (k 0) (hit #f))
          (cond ((null? xs) hit)
                ((eq? (car xs) v)
                 (if (or hit (not (mem-position-ok? i k)))
                     #f
                     (loop (cdr xs) (+ k 1) k)))
                ((memq v (spilled-in (car xs))) #f)   ; nested: needs a register
                (else (loop (cdr xs) (+ k 1) hit)))))

      (define (has-mem? i)
        (let loop ((xs (cdr i)))
          (cond ((null? xs) #f)
                ((and (pair? (car xs)) (eq? (car (car xs)) 'mem)) #t)
                (else (loop (cdr xs))))))

      ;; Rewrite one instruction, producing (pre instr post).
      ;;
      ;; Each spilled vreg is either given a SCRATCH -- reloaded before, stored
      ;; after if it is the destination -- or, where the ISA has memory operands
      ;; and none is spent yet, left as a memory operand and costing nothing.
      ;; x86-64 reads memory directly, which is the whole reason it gets away
      ;; with four raw registers; RV64 is load/store and every spilled operand
      ;; costs a scratch, which is why it reserves two.
      ;; A plain MOVE whose source is spilled folds the reload into itself:
      ;; `mov dst, [rsp+N]` rather than `mov rax, [rsp+N]` then `mov dst, rax`.
      ;;
      ;; This is not just one instruction saved. Going through the scratch is
      ;; what broke nbody's inner loop. Argument setup for a tail call emits a
      ;; run of moves that must be resolved as a PARALLEL copy, and routing a
      ;; spilled source through the scratch turns `mov rcx, <spilled>` into a
      ;; pair whose second half reads the scratch -- which `mov-of` correctly
      ;; refuses to treat as part of a parallel copy, since the scratch has to
      ;; stay free to break cycles. So those moves were never resolved, and
      ;; they clobbered each other:
      ;;
      ;;     mov rcx, [rsp+24] ; add rcx, 1   -> rcx = j+1
      ;;     mov rax, [rsp+0]  ; mov rcx, rax -> rcx overwritten, j+1 gone
      ;;
      ;; The loop then passed a stale index and ran exactly one iteration,
      ;; whatever its bound: nbody visited pair (0,1) and (1,2) but never (0,2).
      ;;
      ;; A memory source cannot be clobbered by a register write, so folding it
      ;; in makes the move safe to reorder and keeps the scratch free.
      ;; BOTH SPELLINGS OF A REGISTER MOVE. x86-64 writes `(mov d s)`; RV64 is
      ;; load/store and has no move instruction, so it spells one `(addi d s 0)`
      ;; and a float one `(fsgnj.d d s s)`. Returns (dst . src), or #f.
      (define (move-pair i)
        (and (pair? i)
             (case (car i)
               ((mov movsd) (and (= (length i) 3) (cons (cadr i) (caddr i))))
               ((addi) (and (= (length i) 4) (eqv? (cadddr i) 0)
                            (cons (cadr i) (caddr i))))
               ((fsgnj.d) (and (= (length i) 4) (eq? (caddr i) (cadddr i))
                               (cons (cadr i) (caddr i))))
               (else #f))))

      ;; THE MEMORY FOLD NEEDS A MEMORY OPERAND; REBUILDING A CONSTANT DOES NOT,
      ;; and conflating the two made this whole procedure x86-only. It required
      ;; `(memq (car i) '(mov movsd))` -- not RV64's move spelling -- AND
      ;; `spiller-mem-operand`, which is #f on RV64 because no instruction there
      ;; reads memory. So on RV64 it never fired, and every rematerialisable
      ;; argument went through the generic path instead: rebuilt into a SCRATCH
      ;; and then moved out of it.
      ;;
      ;; That move is spill code by resolve-argcopy's definition -- `mov-of`
      ;; refuses a move whose source is a scratch, precisely so reloads can be
      ;; lifted over a copy -- so argument setup ended up with spill code on the
      ;; copy's own registers. Before the scratch sets were separated it was
      ;; worse than an error: the staged value was simply clobbered, and a
      ;; nested loop on RV64 read a corrupted bound and never terminated.
      ;;
      ;; See beads 1mp.9 and 1mp.10.
      (define (fold-reload i)
        (and (move-pair i)
             (let ((dst (car (move-pair i))) (src (cdr (move-pair i))))
               ;; The destination may ALREADY be physical -- argument setup
               ;; moves into a convention register, and those are exactly the
               ;; ones that were clobbering each other, so missing this case
               ;; missed the bug entirely.
               (let ((dst-phys (if (reg-class arch dst)
                                   dst
                                   (hashtable-ref assign dst #f))))
               (and (symbol? src) (spilled? src)
                    (symbol? dst) (not (spilled? dst))
                    dst-phys
                    (if (remat? src)
                        ;; Rebuild straight into the destination. Better than
                        ;; the fold it replaces -- no memory reference at all --
                        ;; and REQUIRED, because src's slot is never written.
                        (list '() (car (remat-into dst-phys src)) '())
                        (and
                         ;; ONLY the memory fold needs an operand form.
                         (spiller-mem-operand sp)
                         (list '()
                              (list (car i)
                                    dst-phys
                                    ((spiller-mem-operand sp)
                                     (frame-slot-offset frame src) (class-of src)))
                              '()))))))))

      (define (do-instr i)
        (let ((vs (distinct (apply append (map spilled-in (cdr i))))))
          (cond
           ;; THE DEFINITION OF A REMATERIALISABLE VREG EMITS NOTHING. Its whole
           ;; job was to fill a frame slot, and nothing reads that slot any
           ;; more: every use rebuilds the value instead. Without this the
           ;; materialisation survives with its store deleted, which is a dead
           ;; instruction writing a scratch register.
           ;;
           ;; Safe only because the vreg has exactly one definition -- Lmach is
           ;; single-assignment -- so there is no other instruction whose
           ;; destination this could be.
           ;; A COPY FROM A SLOT TO ITSELF IS NOT A COPY. Two spilled vregs
           ;; joined by an Lmach `move` were given one slot (see `move-aliases`),
           ;; so the reload-and-store this would otherwise emit moves a value
           ;; from a place to the same place.
           ((and (memq (car i) '(mov movsd)) (= (length i) 3)
                 (symbol? (cadr i)) (symbol? (caddr i))
                 (spilled? (cadr i)) (spilled? (caddr i))
                 (eqv? (frame-slot-offset frame (cadr i))
                       (frame-slot-offset frame (caddr i))))
            (list '() #f '()))
           ((and (pair? (cdr i)) (symbol? (cadr i)) (remat? (cadr i))
                 (not (reads-dst? i)))
            ;; #f, not '(), as the "no instruction" marker: the caller asks the
            ;; spiller whether this instruction returns or tail-jumps, and both
            ;; predicates take its car.
            (list '() #f '()))
           ((fold-reload i))
           (else
          (if (null? vs)
              (list '() (cons (car i) (map (lambda (x) (rewrite-operand arch assign x))
                                           (cdr i)))
                    '())
              (let* ((memop (spiller-mem-operand sp))
                     (mem-budget (if (and memop (not (has-mem? i))) 1 0))
                     (float? (lambda (v) (eq? (class-of v) 'raw-f64)))
                     (ints (filter (lambda (v) (not (float? v))) vs))
                     (flts (filter float? vs))
                     (over-int0 (max 0 (- (length ints) (length (spiller-int-scratch sp)))))
                     (over-flt0 (max 0 (- (length flts) (length (spiller-float-scratch sp)))))
                     ;; BORROW WHAT THE SCRATCHES CANNOT COVER.
                     ;;
                     ;; The one memory operand absorbs one over-budget operand;
                     ;; anything past that needs a register the target does not
                     ;; reserve, so one is taken from the allocatable pool for
                     ;; the length of this instruction and given back after.
                     ;; Every register live in this instruction is excluded, and
                     ;; the borrowed one is saved to a reserved frame slot, so
                     ;; whatever value it held is untouched.
                     (borrow-n (max 0 (- (+ over-int0 over-flt0) mem-budget)))
                     (live-here
                      (let ((acc '()))
                        (let walk ((x (cdr i)))
                          (cond ((symbol? x)
                                 (let ((r (if (reg-class arch x)
                                              x
                                              (hashtable-ref assign x #f))))
                                   (when r (set! acc (cons r acc)))))
                                ((pair? x) (walk (car x)) (walk (cdr x)))
                                (else (void))))
                        acc))
                     (borrow-class (if (> over-int0 0) 'raw-word 'raw-f64))
                     (borrowed
                      (let loop ((rs (if (eq? borrow-class 'raw-f64)
                                         (arch-float arch)
                                         (arch-raw arch)))
                                 (n borrow-n) (acc '()))
                        (cond ((or (zero? n) (null? rs)) (reverse acc))
                              ((memq (car rs) live-here) (loop (cdr rs) n acc))
                              (else (loop (cdr rs) (- n 1) (cons (car rs) acc))))))
                     (_ (when (< (length borrowed) borrow-n)
                          (error 'finalize-function
                                 (string-append
                                  "this instruction needs more registers than the "
                                  "scratches, the one memory operand and the whole "
                                  "allocatable pool can supply between them")
                                 (spiller-target sp) i vs)))
                     (int-scr (append (spiller-int-scratch sp)
                                      (if (eq? borrow-class 'raw-word) borrowed '())))
                     (flt-scr (append (spiller-float-scratch sp)
                                      (if (eq? borrow-class 'raw-f64) borrowed '())))
                     (over-int (max 0 (- (length ints) (length int-scr))))
                     (over-flt (max 0 (- (length flts) (length flt-scr))))
                     (need-mem (+ over-int over-flt)))
                (let* ((cands (filter (lambda (v)
                                        (and (mem-eligible i v)
                                             (if (> over-flt 0) (float? v) (not (float? v)))))
                                      vs))
                       (mem-v (and (> need-mem 0)
                                   (if (pair? cands)
                                       (car cands)
                                       (error 'finalize-function
                                              (string-append
                                               "the spilled operand over budget cannot ride in "
                                               "memory: it is either the destination or an "
                                               "address component, both of which need a register")
                                              (spiller-target sp) i vs))))
                       (scratched (filter (lambda (v) (not (eq? v mem-v))) vs))
                       (pick (let ((ni 0) (nf 0))
                               (lambda (v)
                                 (if (float? v)
                                     (let ((r (list-ref flt-scr nf)))
                                       (set! nf (+ nf 1)) r)
                                     (let ((r (list-ref int-scr ni)))
                                       (set! ni (+ ni 1)) r)))))
                       (chosen (map (lambda (v) (cons v (pick v))) scratched))
                       (sub (lambda (x)
                              (cond ((and (symbol? x) (assq x chosen)) (cdr (assq x chosen)))
                                    ((and (symbol? x) (eq? x mem-v))
                                     (memop (frame-slot-offset frame x) (class-of x)))
                                    (else (rewrite-operand arch assign x)))))
                       (ops (map (lambda (x)
                                   (if (and (pair? x) (eq? (car x) 'mem))
                                       (list 'mem (sub (cadr x))
                                             (and (caddr x) (sub (caddr x)))
                                             (cadddr x) (list-ref x 4))
                                       (sub x)))
                                 (cdr i)))
                       (dst-v (let ((d (car (cdr i)))) (and (symbol? d) d)))
                       (pre (apply append
                                   (map (lambda (p)
                                          (let ((v (car p)) (r (cdr p)))
                                            (cond
                                             ((and (eq? v dst-v) (not (reads-dst? i))) '())
                                             ((remat? v) (remat-into r v))
                                             (else
                                              ((spiller-reload sp)
                                               r (frame-slot-offset frame v)
                                               (class-of v))))))
                                        chosen)))
                       (post (apply append
                                    (map (lambda (p)
                                           (let ((v (car p)) (r (cdr p)))
                                             (if (and (eq? v dst-v) (not (remat? v)))
                                                 ((spiller-store sp)
                                                  (frame-slot-offset frame v) r (class-of v))
                                                 '())))
                                         chosen))))
                  ;; The borrow brackets everything: saved before the reloads
                  ;; that may use it, restored after the stores that may.
                  (let ((save (apply append
                                     (map (lambda (r k)
                                            ((spiller-store sp)
                                             (frame-borrow-offset frame k) r
                                             borrow-class))
                                          borrowed
                                          (let n ((k 0) (rs borrowed))
                                            (if (null? rs) '()
                                                (cons k (n (+ k 1) (cdr rs)))))))) 
                        (restore (apply append
                                        (map (lambda (r k)
                                               ((spiller-reload sp)
                                                r (frame-borrow-offset frame k)
                                                borrow-class))
                                             borrowed
                                             (let n ((k 0) (rs borrowed))
                                               (if (null? rs) '()
                                                   (cons k (n (+ k 1) (cdr rs)))))))))
                    (list (append save pre) (cons (car i) ops)
                          (append post restore))))))))))

      ;; The two-address forms read their destination. Anything that only writes
      ;; it must NOT be reloaded first: the reload would be dead, and worse, it
      ;; would make a dead value look live to anything reading this listing.
      (define write-only-mnemonics
        '(mov movsd lea movzx cvtsi2sd sqrtsd
          ld fld li lui auipc addi
          fcvt.d.l fcvt.l.d fsqrt.d fmv.d))
      (define (reads-dst? i) (not (memq (car i) write-only-mnemonics)))

      ;; A run of register-to-register moves is a PARALLEL copy: every source
      ;; reads the state before the run, not part-way through it. Emitted in
      ;; sequence, a later move can read a register an earlier one overwrote.
      ;;
      ;; This is what argument setup is. `put!` takes seven doubles, so the
      ;; caller emits seven moves into xmm0..xmm6 -- and if the value for xmm6
      ;; is sitting in xmm2, the move into xmm2 has already destroyed it. The
      ;; symptom is one wrong argument and a plausible answer: nbody's `mass`
      ;; came out zero while `pos` and `vel` were exact.
      ;;
      ;; parcopy.ss has resolved this correctly since it was written; nothing
      ;; called it. It runs here, after allocation, because that is the first
      ;; point at which the physical registers are known -- which is precisely
      ;; the reason callseq.ss could not do it.
      ;; A move touching a SCRATCH register is not part of a parallel copy, and
      ;; feeding one in is what took the VM down.
      ;;
      ;; The scratch is what breaks a cycle, so it has to be free. A move whose
      ;; destination is the scratch makes the cycle-breaker rewrite that move
      ;; into `(scratch . scratch)` -- a self-move it then spins on forever,
      ;; consing. And such moves are common right here: the two-address fixup
      ;; routes a left operand through xmm15, and if that sequence happens to
      ;; sit just before a call it lands in this run.
      ;;
      ;; They are also not parallel in the first place. The fixup's moves are
      ;; SEQUENTIAL by construction -- the whole point is `mov tmp, a` then
      ;; operate on tmp -- so reordering them is wrong even when it terminates.
      (define (scratchy? r) (eq? (reg-class arch r) 'scratch))

      (define (mov-of i)
        (and (pair? i)
             (memq (car i) '(mov movsd addi fsgnj.d))
             (case (car i)
               ((mov movsd)
                (and (= (length i) 3) (symbol? (cadr i))
                     (reg-class arch (cadr i)) (not (scratchy? (cadr i)))
                     ;; The SOURCE may be a memory operand, and admitting those
                     ;; is what fixes argument setup.
                     ;;
                     ;; A spilled argument folds to `mov <argreg>, [rsp+N]`, and
                     ;; rejecting it broke the run -- so a live value sitting in
                     ;; a register that is ALSO a convention argument register
                     ;; got overwritten before the move that read it. rcx held
                     ;; j+1 and is raw-word argument 0, so the loop passed a
                     ;; stale index and ran exactly one iteration.
                     ;;
                     ;; A memory source has no register to be clobbered, so it
                     ;; never participates in a cycle; it only has to be ordered
                     ;; after anything that reads its destination, which is
                     ;; exactly what the ready rule already enforces.
                     (let ((src (caddr i)))
                       (cond
                        ((and (symbol? src) (reg-class arch src) (not (scratchy? src)))
                         (cons (cadr i) src))
                        ((and (pair? src) (eq? (car src) 'mem)) (cons (cadr i) src))
                        ;; An IMMEDIATE source writes a copy destination and
                        ;; reads no register: a copy operation with no source.
                        ;; See emit-mov.
                        ((and (pair? src) (eq? (car src) 'imm))
                         (cons (cadr i) (list 'as-written i)))
                        (else #f)))))
               ;; RV64 spells a register move `addi rd, rs, 0` and a float one
               ;; `fsgnj.d rd, rs, rs`.
               ((addi)
                (and (= (length i) 4)
                     (symbol? (cadr i)) (reg-class arch (cadr i))
                     (not (scratchy? (cadr i)))
                     (if (eqv? (cadddr i) 0)
                         (and (symbol? (caddr i)) (reg-class arch (caddr i))
                              (not (scratchy? (caddr i)))
                              (cons (cadr i) (caddr i)))
                         ;; `addi rd, zero, imm` is RV64's spelling of the
                         ;; sourceless copy operation -- it has no
                         ;; move-immediate, so this is where x86-64 writes
                         ;; `(mov rd (imm n))`. See emit-mov.
                         (and (eq? (caddr i) 'zero)
                              (cons (cadr i) (list 'as-written i))))))
               ((fsgnj.d)
                (and (= (length i) 4) (eq? (caddr i) (cadddr i))
                     (symbol? (cadr i)) (symbol? (caddr i))
                     (reg-class arch (cadr i)) (reg-class arch (caddr i))
                     (not (scratchy? (cadr i))) (not (scratchy? (caddr i)))
                     (cons (cadr i) (caddr i))))
               (else #f))))

      ;; Peephole each straight-line RUN, never across a label.
      ;;
      ;; A label is a branch target, so anything arriving there did not execute
      ;; the compare above it -- fusing a compare with a branch across one would
      ;; hand the branch flags that some paths never set. Splitting at labels is
      ;; the scope, not a convenience.
      (define (peephole-runs target xs)
        (let loop ((xs xs) (run '()) (out '()))
          (define (flush)
            (if (null? run)
                out
                (let-values (((done st) (peephole target (reverse run))))
                  (append (reverse done) out))))
          (cond
           ((null? xs) (reverse (flush)))
           ((symbol? (car xs)) (loop (cdr xs) '() (cons (car xs) (flush))))
           (else (loop (cdr xs) (cons (car xs) run) out)))))

      ;; Resolve the maximal run of moves ending at each call or tail jump.
      (define (call-or-jump? i)
        (and (pair? i)
             (memq (car i) '(call jmp jal jalr ret))))

      ;; The EPILOGUE sits between the argument moves and the jump on any
      ;; function that has a frame, and it must not break the run.
      ;;
      ;; This is not a detail. Treating it as an ordinary instruction meant the
      ;; argument setup of every function with a spill slot was left
      ;; unresolved -- which is every interesting function, since a function
      ;; with no frame is one with nothing live across a call. The functions
      ;; that appeared to work were the ones with no frame.
      (define (frame-adjust? i)
        (and (pair? i)
             (or (and (memq (car i) '(add sub)) (eq? (cadr i) 'rsp))
                 (and (eq? (car i) 'addi) (eq? (cadr i) 'sp)))))

      ;; --- the argument setup, as callseq.ss marked it -----------------------
      ;;
      ;; `plan-instrs` brackets the register moves of a call or a tail call with
      ;; `(%argcopy)` / `(%argcopy-end)`. Everything between them is one parallel
      ;; copy because it was built as one; nothing here has to work out which
      ;; moves those were.
      ;;
      ;; THAT USED TO BE A GUESS, and it is worth saying why no better guess
      ;; exists. The rule was "the maximal run of moves before a transfer", and a
      ;; move that COMPUTES a value the copy reads has to run first while a move
      ;; that PERMUTES one must not -- and in a finished listing those are the
      ;; same two instructions. Three predicates were tried against the whole
      ;; suite. Each fixed one program and broke another: ordering by "is this
      ;; destination read later" made fannkuch right and nbody non-terminating,
      ;; and the reverse test made nbody right while fannkuch's `step` silently
      ;; dropped `maxflips`, because the run then held two writes to one register
      ;; and the resolver keeps the last. The information is upstream. Ask for it
      ;; there.
      ;;
      ;; Markers are dropped here, before the peephole, so nothing downstream --
      ;; and no encoder -- ever sees one.
      (define (argcopy-begin? i) (and (pair? i) (eq? (car i) '%argcopy)))
      (define (argcopy-end? i) (and (pair? i) (eq? (car i) '%argcopy-end)))

      ;; The registers a copy reads and the registers it writes.
      (define (copy-reads ms)
        (filter symbol? (map (lambda (i) (cdr (mov-of i))) ms)))
      (define (copy-writes ms)
        (map (lambda (i) (car (mov-of i))) ms))

      ;; Every register an instruction names. Coarse on purpose: this only
      ;; decides whether spill code may be lifted over the copy, and treating a
      ;; read as a write costs an ordering, not a wrong answer.
      (define (regs-of i)
        (let walk ((x (cdr i)) (acc '()))
          (cond ((null? x) acc)
                ((symbol? (car x))
                 (walk (cdr x) (if (reg-class arch (car x)) (cons (car x) acc) acc)))
                ((pair? (car x)) (walk (cdr x) (walk (cdr (car x)) acc)))
                (else (walk (cdr x) acc)))))

      ;; One bracketed region. The moves are the copy; anything else in here is
      ;; spill code `do-instr` inserted for one of them, which computes a value
      ;; the copy reads and therefore goes first. It may only be lifted over the
      ;; copy if it does not touch the copy's registers -- true for a reload,
      ;; which reads a frame slot and writes a scratch, and the scratch classes
      ;; are outside every pool `mov-of` admits.
      (define (resolve-argcopy region)
        (let* ((moves (filter mov-of region))
               (others (filter (lambda (i) (not (mov-of i))) region))
               (touched (append (copy-reads moves) (copy-writes moves)))
               (tangled (filter (lambda (i)
                                  (exists (lambda (r) (memq r touched)) (regs-of i)))
                                others)))
          ;; Loudly, rather than falling back to program order: program order is
          ;; the bug, and a fallback would restore it on exactly the day some
          ;; future spiller starts routing an argument through a pool register.
          (unless (null? tangled)
            (error 'finalize-function
                   "argument setup has spill code on the copy's own registers"
                   name (car tangled)))
          (let-values (((resolved st)
                        (resolve-moves-in-block arch moves mov-of emit-mov)))
            (append others resolved))))

      (define (resolve-argument-moves xs)
        (let loop ((xs xs) (out '()))
          (cond
           ((null? xs) (reverse out))
           ((argcopy-begin? (car xs))
            (let region ((ys (cdr xs)) (acc '()))
              (cond
               ((null? ys)
                (error 'finalize-function "unterminated argument copy" name))
               ((argcopy-end? (car ys))
                (loop (cdr ys)
                      (append (reverse (resolve-argcopy (reverse acc))) out)))
               (else (region (cdr ys) (cons (car ys) acc))))))
           ((argcopy-end? (car xs))
            (error 'finalize-function "argument copy ends without starting" name))
           (else (loop (cdr xs) (cons (car xs) out))))))

      ;; `mov r, r` / `movsd r, r` / RV64's `addi r, r, 0` and `fsgnj.d r, r, r`.
      (define (self-move? i)
        (case (car i)
          ((mov movsd) (and (= (length i) 3) (eq? (cadr i) (caddr i))))
          ((addi) (and (= (length i) 4) (eq? (cadr i) (caddr i)) (eqv? (cadddr i) 0)))
          ((fsgnj.d) (and (= (length i) 4) (eq? (cadr i) (caddr i))
                          (eq? (cadr i) (cadddr i))))
          (else #f)))

      (define (emit-mov dst src)
        ;; A COPY OPERATION WITH NO SOURCE is carried as-written and emitted
        ;; verbatim. `resolve-parallel-copy` reorders (dst . src) pairs and
        ;; `emit-mov` rebuilds each one, which cannot reconstruct an instruction
        ;; that reads no register -- there is nothing to rebuild it FROM. So the
        ;; instruction rides in the source slot instead.
        ;;
        ;; Sound for the reordering too: the payload is a pair and every
        ;; destination is a symbol, so it never matches one and can never be
        ;; part of a cycle. That is exactly right -- an operation that reads
        ;; nothing has no incoming edge, and only needs to be ordered after
        ;; anything that READS its destination, which the ready rule enforces
        ;; from the destination alone.
        (if (and (pair? src) (eq? (car src) 'as-written))
            (cadr src)
        ;; `float-register?`, not membership in the allocatable pool: a cycle is
        ;; broken through the float SCRATCH, which sits outside that pool, and
        ;; asking the pool spells the move `mov xmm15, xmm0`.
        (let ((float? (float-register? arch dst)))
          (if (eq? target 'rv64)
              (if float? `(fsgnj.d ,dst ,src ,src) `(addi ,dst ,src 0))
              (if float? `(movsd ,dst ,src) `(mov ,dst ,src))))))

      ;; --- a self tail call jumps PAST the prologue ---------------------------
      ;;
      ;; A loop is a procedure that tail-calls itself, so its back edge is a jump
      ;; to its own entry label -- where the prologue lives. The epilogue before
      ;; the jump released the frame and the prologue at the entry reserved it
      ;; again, every iteration, for a frame whose size cannot have changed:
      ;;
      ;;     inner%24.201:  sub rsp, 16      <- every iteration
      ;;                    ...
      ;;                    add rsp, 16      <- every iteration
      ;;                    jmp inner%24.201
      ;;
      ;; So the back edge targets a label placed AFTER the prologue and the
      ;; epilogue is not emitted for it. Both cancel and both disappear.
      ;;
      ;; THE LABEL GOES BEFORE THE ARRIVAL MOVES, not after them, and that is the
      ;; whole subtlety. An arrival copies a parameter out of the argument
      ;; register it came in, and a self tail call has just written the next
      ;; iteration's values into those registers -- so the arrivals must run
      ;; again. Only the frame adjustment is redundant. Placing the label after
      ;; them would leave every parameter holding its first-iteration value,
      ;; which is a loop that runs once with the right answer and then forever
      ;; with the wrong one.
      ;;
      ;; Offsets stay correct because rsp simply never moves. A self tail call
      ;; writes the callee's incoming argument area, which for a self call is our
      ;; own, at [rsp + bytes + 8 + 8i]; the reader at the top uses the same
      ;; expression. Both were already computed against a lowered rsp, since the
      ;; write happened before the epilogue.
      (define loop-label
        (string->symbol (string-append (symbol->string name) ".loop")))

      ;; --- RV64 must SAVE `ra` in a non-leaf function ------------------------
      ;;
      ;; x86-64's `call` PUSHES the return address, so a callee cannot destroy
      ;; its caller's. RV64's `jal ra` writes it to a REGISTER, so any function
      ;; that itself calls something overwrites its own return address -- and
      ;; then `jalr zero ra 0` returns into its own body just past the call.
      ;;
      ;; Measured before this: outer%2.2 ran its prologue ONCE and its epilogue
      ;; TWICE, climbing a frame per pass, until [sp+0] no longer named the slot
      ;; holding the loop bound. A nested loop never terminated. See 1mp.10.
      ;;
      ;; Only a NON-LEAF pays. A leaf keeps ra untouched, and spending two
      ;; instructions and a word on every leaf would be a real cost on a target
      ;; whose whole calling convention is register-based.
      (define non-leaf?
        (and (eq? target 'rv64)
             (let scan ((bs blocks))
               (cond ((null? bs) #f)
                     ((let inner ((is (cadr (car bs))))
                        (cond ((null? is) #f)
                              ((and (pair? (car is)) (eq? (car (car is)) 'jal)
                                    (pair? (cdr (car is))) (eq? (cadr (car is)) 'ra))
                               #t)
                              (else (inner (cdr is)))))
                      #t)
                     (else (scan (cdr bs)))))))

      ;; SIXTEEN, not eight, so the stack stays 16-byte aligned at a call
      ;; boundary -- the same reason frame-layout-bytes rounds up.
      (define ra-bytes (if non-leaf? 16 0))

      ;; Bound rather than written as a bare expression: this sits among
      ;; internal definitions, which must all precede any expression in a body.
      (define recorded-frame
        (hashtable-set! frames name (cons bytes ra-bytes)))

      ;; A TAIL CALL INTO AN IDENTICAL FRAME KEEPS IT.
      ;;
      ;; `loop%2.14@8.373` ended every iteration with `add $0x10,%rsp` and jumped
      ;; to `loop%2.372`, whose first instruction is `sub $0x10,%rsp` -- two
      ;; halves of one loop, each rebuilding what the other just tore down, in
      ;; blocks that are 18.5% of fannkuch's profile (D96). `tail-call-plan`
      ;; already reported a zero frame delta; nothing consulted it.
      ;;
      ;; Both `ra-bytes` must be zero. On rv64 a non-leaf saves `ra` OUTSIDE the
      ;; spill frame, and a tail call has to restore it before jumping or the
      ;; callee returns to the wrong place -- so a saved `ra` is exactly the case
      ;; where the epilogue is load-bearing. On x86-64 `non-leaf?` is always #f.
      ;;
      ;; Overlaying the callee's spill slots on ours is sound only because we are
      ;; LEAVING: nothing of ours is read after the jump.
      ;; EQUAL FRAMES ARE NOT THE REAL PRECONDITION. `add F_caller` followed by
      ;; the callee's `sub F_callee` is just `rsp += F_caller - F_callee`, so any
      ;; pair collapses to ONE instruction and an equal pair to none. Returns
      ;; `(body-label . delta)`, delta being what rsp must move by.
      ;;
      ;; `tail-outgoing` must be zero. A tail call that passes arguments on the
      ;; stack writes them into this frame at offsets the callee reads back from
      ;; ITS rsp; moving rsp between the write and the read shifts every one of
      ;; them. With equal frames rsp does not move and the question does not
      ;; arise, which is why the first version needed no such guard.
      (define (reuse-frame-target i)
        (and (zero? ra-bytes)
             (let ((tgt (jump-target i)))
               (and (symbol? tgt)
                    (let ((f (hashtable-ref frames tgt #f)))
                      (and f (zero? (cdr f))
                           (or (= (car f) bytes) (zero? tail-outgoing))
                           (cons (string->symbol
                                  (string-append (symbol->string tgt) ".loop"))
                                 (- bytes (car f)))))))))

      ;; Rewrite the jump to land past the callee's prologue.
      (define (retarget-to body i)
        (let ((tgt (jump-target i)))
          (cons (car i)
                (map (lambda (x)
                       (cond ((and (pair? x) (eq? (car x) 'label) (eq? (cadr x) tgt))
                              (list 'label body))
                             ((eq? x tgt) body)
                             (else x)))
                     (cdr i)))))

      ;; Wrapped OUTSIDE the spill frame, so every existing sp displacement into
      ;; that frame is unchanged. Only what a CALLEE sees above it moves, which
      ;; is why incoming-offset adds ra-bytes too.
      (define (ra-save)
        (if non-leaf? `((addi sp sp -16) (sd ra sp 8)) '()))
      (define (ra-restore)
        (if non-leaf? `((ld ra sp 8) (addi sp sp 16)) '()))

      ;; THE TARGET IS A LABEL, NOT THE FIRST SYMBOL OPERAND. Same defect as
      ;; own-label? had: on x86-64 `(jmp (label L))` has one operand and the
      ;; first symbol IS the target, but RV64 spells a jump `(jal zero L)` and
      ;; the first symbol is the DESTINATION REGISTER. So this returned `zero`
      ;; for every RV64 jump, self-jump? was never true, and the
      ;; past-the-prologue rewrite below never fired on that target -- every
      ;; loop iteration released and re-reserved a frame whose size cannot
      ;; change.
      ;;
      ;; A register is never a label, so preferring a name that IS one is
      ;; correct for both spellings.
      (define (jump-target i)
        (let loop ((xs (cdr i)) (fallback #f))
          (cond ((null? xs) fallback)
                ((and (pair? (car xs)) (eq? (car (car xs)) 'label)) (cadr (car xs)))
                ((and (symbol? (car xs)) (not (reg-class arch (car xs)))) (car xs))
                (else (loop (cdr xs) fallback)))))

      (define (self-jump? i)
        (and ((spiller-tail-jump? sp) i) (eq? (jump-target i) name)))

      (define (retarget i)
        (cons (car i)
              (map (lambda (x)
                     (cond ((and (pair? x) (eq? (car x) 'label) (eq? (cadr x) name))
                            (list 'label loop-label))
                           ((eq? x name) loop-label)
                           (else x)))
                   (cdr i))))

      (let* (;; Before any rewriting: decide which rematerialisable vregs have
             ;; to go back to a frame slot because some instruction needs them
             ;; in memory. Must run before `do-instr` sees anything, since
             ;; `remat?` reads the table this prunes.
             (pruned (un-remat-what-must-ride-in-memory!))
             (listing
             (apply append
                    (map (lambda (b)
                           (let ((lbl (car b)) (instrs (cadr b)))
                             (cons lbl
                                   (apply append
                                          (map (lambda (i)
                                                 (let* ((parts (do-instr i))
                                                        (pre (car parts))
                                                        (ins (cadr parts))
                                                        (post (caddr parts)))
                                                   ;; The epilogue goes before
                                                   ;; the instruction that leaves,
                                                   ;; not after it.
                                                   (append
                                                    pre
                                                    (let ((reuse
                                                           (and ins
                                                                ((spiller-tail-jump? sp) ins)
                                                                (not (own-label? ins own-labels))
                                                                (not (self-jump? ins))
                                                                (reuse-frame-target ins))))
                                                      (append
                                                       (if (and reuse
                                                                (not (zero? (cdr reuse))))
                                                           (if (positive? (cdr reuse))
                                                               ((spiller-epilogue sp) (cdr reuse))
                                                               ((spiller-prologue sp) (- (cdr reuse))))
                                                           '())
                                                       (if (and ins
                                                                (not reuse)
                                                                (or ((spiller-returns? sp) ins)
                                                                    (and ((spiller-tail-jump? sp) ins)
                                                                         (not (own-label? ins own-labels))
                                                                         ;; the back edge keeps the frame
                                                                         (not (self-jump? ins)))))
                                                           (append
                                                            ((spiller-epilogue sp) bytes)
                                                            (ra-restore))
                                                           '())
                                                       (if ins
                                                           (list (cond (reuse (retarget-to (car reuse) ins))
                                                                       ((self-jump? ins) (retarget ins))
                                                                       (else ins)))
                                                           '())))
                                                    post)))
                                               instrs)))))
                         blocks)))
            ;; ONLY the argument setup, not every run of moves.
            ;;
            ;; Applying parallel-copy resolution to every maximal run of moves
            ;; is WRONG, because a run of moves in ordinary code can be
            ;; sequential: `mov a, b` then `mov c, a` means c gets the NEW a.
            ;; Read as a parallel copy it gets the old one. Argument setup is
            ;; parallel; a phi copy chain is not necessarily.
            ;;
            ;; The run immediately preceding a call or a tail jump is argument
            ;; setup by construction -- callseq.ss emits the moves and then the
            ;; transfer, with nothing between -- so that is the run resolved.
            (listing (resolve-argument-moves listing))
            ;; PEEPHOLE. It has existed since the back end was written and
            ;; nothing ever called it, so every `setcc`/`movzx`/`cmp $0`/`jne`
            ;; sequence the selector emits for a branch survived into the final
            ;; image -- four instructions where the flags from the compare were
            ;; already sitting there.
            ;;
            ;; It runs HERE, after allocation and after the parallel copy,
            ;; because fusing a compare with its branch is only valid once
            ;; nothing can be inserted between them, and the spill code inserted
            ;; above is exactly the thing that could.
            (listing (peephole-runs target listing))
            ;; Delete moves that coalescing made redundant.
            ;;
            ;; The allocator now gives a move's destination its source's
            ;; register where it can, which turns the move into `mov r, r`.
            ;; Deleting those is the whole point -- a self-move is the shape a
            ;; coalesced copy leaves behind, and leaving it in means the
            ;; coalescing bought nothing.
            (listing (filter (lambda (i)
                               (not (and (pair? i)
                                         (memq (car i) '(mov movsd addi fsgnj.d))
                                         (self-move? i))))
                             listing)))
        ;; ARGUMENT ARRIVAL.
        ;;
        ;; The convention puts argument k of class c in a fixed register, and
        ;; the allocator put the parameter wherever its own scan had room. The
        ;; two are not the same register, and nothing bridged them: a function
        ;; read its first argument from whatever the allocator picked, while the
        ;; caller had written the convention's. `outer` read `i` from rdx while
        ;; its caller wrote rcx, so the loop compared an unrelated register
        ;; against its bound and fell straight out.
        ;;
        ;; This is the same gap the RETURN move had, at the other end of the
        ;; call, and it failed the same way: silently, with a plausible value.
        ;;
        ;; The moves go after the prologue, so a spilled parameter's store lands
        ;; in a frame that exists.
        ;;
        ;; Before it, the only way to execute it is to fall in from whatever
        ;; precedes the function in the image -- and every call jumps straight
        ;; to the label, skipping it. The frame is then never reserved, so every
        ;; spill slot writes below the stack pointer, over the return address
        ;; the call just pushed. That is a segfault at best.
        (let* ((cc (callconv-by-name target))
               ;; Register arrivals and STACK arrivals, split.
               ;;
               ;; `arg-register` answers #f once a class runs out, and that #f
               ;; used to go straight into a move: `mov rcx, #f` reached the
               ;; encoder, which reported "bad mov operands" and named nothing
               ;; that would tell you a sixth raw argument was the cause. A
               ;; parameter past the registers arrives in the caller's outgoing
               ;; area, and its slot index is its position among the OVERFLOWING
               ;; arguments in source order -- the same walk `tail-call-plan`
               ;; does on the caller's side, which is why the two agree.
               (split
                (let loop ((ps params) (n (make-eq-hashtable)) (slot 0)
                           (regs '()) (stack '()))
                  (if (null? ps)
                      (cons (reverse regs) (reverse stack))
                      (let* ((p (car ps))
                             (c (or (hashtable-ref classes p #f)
                                    (error 'finalize-function
                                           "a parameter with no storage class; nothing says which argument register it arrives in"
                                           name p)))
                             (k (hashtable-ref n c 0))
                             (r (arg-register cc c k)))
                        (hashtable-set! n c (+ k 1))
                        (if r
                            (loop (cdr ps) n slot
                                  (cons (list 'move p c r) regs) stack)
                            (loop (cdr ps) n (+ slot 1)
                                  regs (cons (list p c slot) stack)))))))
               (arrivals (car split))
               ;; STACK ARRIVALS GO LAST, after the register parallel copy.
               ;;
               ;; They cannot go first. A stack arrival writes the parameter's
               ;; ALLOCATED register, and the allocator draws from the same
               ;; pools the convention passes arguments in -- so writing one
               ;; early can destroy an argument register a register arrival has
               ;; not read yet. After the copy, every argument register has been
               ;; consumed and each stack arrival writes a destination no other
               ;; arrival touches, since distinct live parameters get distinct
               ;; registers.
               ;;
               ;; Emitted through the SPILLER rather than as an Lmach move,
               ;; because RV64's move is `addi rd, rs, 0` and has no memory
               ;; form. The spiller already spells a load from the stack on both
               ;; targets; this is the same load at a different offset.
               (stack-arrivals
                (apply append
                       (map (lambda (sa)
                              (let* ((p (car sa)) (c (cadr sa))
                                     (off (frame-incoming-offset target frame (caddr sa)))
                                     (r (hashtable-ref assign p #f)))
                                (cond
                                 (r ((spiller-reload sp) r off c))
                                 ((spilled? p)
                                  ;; Memory to memory, so it goes through a
                                  ;; scratch -- the one place an arrival needs
                                  ;; one, and it is free here because no live
                                  ;; range can occupy a scratch.
                                  (let ((t (car (scratches-for c))))
                                    (append ((spiller-reload sp) t off c)
                                            ((spiller-store sp)
                                             (frame-slot-offset frame p) t c))))
                                 ;; A parameter the function never reads.
                                 (else '()))))
                            (cdr split))))
               ;; Each arrival is an Lmach `move`, so it goes through the same
               ;; selection and the same spill machinery as any other.
               ;; A parameter the allocator never placed is one this function
               ;; never READS -- it has no live interval, so the scan never saw
               ;; it. Its arrival move is dead, and emitting it would put a
               ;; virtual register name in front of the encoder. Dropped rather
               ;; than raised: an unused parameter is ordinary.
               (live-arrivals
                (filter (lambda (m)
                          (let ((p (cadr m)))
                            (or (hashtable-ref assign p #f) (spilled? p))))
                        arrivals))
               ;; THE ARRIVALS ARE A PARALLEL COPY, and this is where the last
               ;; wrong answer came from.
               ;;
               ;; Every one of them reads an ARGUMENT register, and the
               ;; allocator may well have placed some parameter IN an argument
               ;; register -- they are drawn from the same pools. So a move that
               ;; writes xmm6 can destroy the value a later move was going to
               ;; read from xmm6. `put!` took seven doubles and its eighth
               ;; parameter came out holding the second one's value: the caller
               ;; was exactly right and the callee shredded its own arguments.
               ;;
               ;; Spilled parameters are stored FIRST, straight from the
               ;; argument register, while every argument register is still
               ;; pristine. The rest is a parallel copy between physical
               ;; registers, which parcopy.ss resolves.
               (arrival-stores
                (apply append
                       (map (lambda (m)
                              (let ((p (cadr m)) (c (caddr m)) (r (cadddr m)))
                                (if (spilled? p)
                                    ((spiller-store sp) (frame-slot-offset frame p) r c)
                                    '())))
                            live-arrivals)))
               (arrival-pairs
                (let loop ((ms live-arrivals) (acc '()))
                  (cond ((null? ms) (reverse acc))
                        ((spilled? (cadr (car ms))) (loop (cdr ms) acc))
                        (else
                         (loop (cdr ms)
                               (cons (cons (hashtable-ref assign (cadr (car ms)) #f)
                                           (cadddr (car ms)))
                                     acc))))))
               (arrival-instrs
                (append arrival-stores
                        (let-values (((out st) (resolve-moves-in-block
                                                arch
                                                (map (lambda (pr)
                                                       (emit-mov (car pr) (cdr pr)))
                                                     arrival-pairs)
                                                mov-of emit-mov)))
                          out)))
               (head (append (ra-save)
                             ((spiller-prologue sp) bytes)
                             (list loop-label)
                             arrival-instrs stack-arrivals)))
          ;; The prologue goes AFTER the function's entry label, not before it.
          ;;
          ;; Before it, the only way to execute it is to fall in from whatever
          ;; precedes the function in the image -- and every call jumps straight
          ;; to the label, skipping it. The frame is then never reserved, so
          ;; every spill slot writes below the stack pointer, over the return
          ;; address the call just pushed.
          (make-finalized name
                          (patch-incoming
                           target frame
                           (if (and (pair? listing) (symbol? (car listing)))
                               (cons (car listing) (append head (cdr listing)))
                               (append head listing)))
                          frame
                          spills)))))


  ;; The whole program: one finalized listing per function.
  (define (finalize-program target arch selected blocks entry classes . opt)
    (finalize-program* target arch selected blocks entry classes
                       (if (pair? opt) (car opt) (make-eq-hashtable))))

  ;; --- what a function writes, and the order that lets us know -------------
  ;;
  ;; Every physical register a finished listing writes: the destination slot of
  ;; anything that is not a store or a compare or a branch. Read off the LISTING
  ;; rather than the allocator's assignment, because that is the only place all
  ;; of it appears -- the allocation, the spill scratches, the argument setup a
  ;; caller performs, and the return move.
  (define (listing-writes arch xs)
    (let ((acc '()))
      (for-each
       (lambda (i)
         (when (and (pair? i) (pair? (cdr i)) (symbol? (cadr i))
                    (reg-class arch (cadr i))
                    (not (memq (car i) '(cmp jmp ret call syscall push
                                         jl jle je jne jge jg jb jbe ja jae))))
           (unless (memq (cadr i) acc) (set! acc (cons (cadr i) acc)))))
       (filter pair? xs))
      acc))

  ;; --- a procedure nothing calls is not compiled -----------------------------
  ;;
  ;; `partition-into-functions` already gathers blocks no entry reaches under
  ;; `<unreachable>`, and finalize already drops that bucket -- but a top-level
  ;; procedure with no callers is not in it. It is a perfectly well-formed
  ;; function that simply cannot run, and it was being lowered, allocated,
  ;; finalized and emitted.
  ;;
  ;; It costs more than bytes. repr.ss has to classify such a procedure's
  ;; parameters, and it cannot: a parameter's class comes from its call sites,
  ;; so a procedure with none leaves them unknown and lower.ss then refuses the
  ;; whole program over code that cannot execute. That was a real bug, and the
  ;; fix there -- call the parameters `raw-word` because an unconstrained choice
  ;; is free -- is a workaround for compiling something nobody should compile.
  ;;
  ;; REACHABILITY IS EXACT HERE, not conservative. Every call in this compiler
  ;; names its target directly -- closures are a later bead -- so `callees-of`
  ;; over the call graph IS the set of procedures that can run, and a name it
  ;; does not reach cannot be entered by any means. The runtime's own routines
  ;; are not in this list at all: they live in `runtime-listing`, and the entry
  ;; reaches them through it.
  (define (reachable-functions fns entry)
    (let ((by-name (make-eq-hashtable)) (seen (make-eq-hashtable)))
      (for-each (lambda (fn) (hashtable-set! by-name (car fn) fn)) fns)
      (let walk ((work (list entry)))
        (unless (null? work)
          (let ((nm (car work)))
            (cond
             ((hashtable-ref seen nm #f) (walk (cdr work)))
             (else
              (hashtable-set! seen nm #t)
              (let ((fn (hashtable-ref by-name nm #f)))
                (walk (append (if fn (callees-of (cdr fn)) '()) (cdr work)))))))))
      ;; IN THE ORIGINAL ORDER. The image's layout is not the call graph's
      ;; business, and reordering it would move every function in the object
      ;; file for a reason that has nothing to do with them.
      (filter (lambda (fn) (hashtable-ref seen (car fn) #f)) fns)))

  ;; The functions this one CALLS, tail calls included. A tail call transfers
  ;; control, so from a caller's point of view calling f runs whatever f jumps
  ;; to, and its writes are f's writes.
  (define (callees-of blocks)
    (let ((acc '()))
      (for-each
       (lambda (b)
         (for-each (lambda (i)
                     (when (and (pair? i) (eq? (car i) 'call) (>= (length i) 4)
                                (symbol? (cadddr i))
                                (not (memq (cadddr i) acc)))
                       (set! acc (cons (cadddr i) acc))))
                   (cadr (cadr b))))
       blocks)
      acc))

  ;; Callees before callers, so a caller is allocated knowing what its callees
  ;; write. Anything left when no candidate has all its callees resolved is in a
  ;; CYCLE, and every member of it is emitted with no clobber information --
  ;; which is exactly the assumption this compiler made everywhere until now, so
  ;; a cycle costs nothing that was not already being lost.
  ;;
  ;; Self recursion is not a cycle here: a loop's back edge is a TAIL call, which
  ;; selection turns into a jump, and a function is never its own blocker.
  (define (callee-first fns)
    (let* ((names (map car fns))
           (calls (map (lambda (fn)
                         (cons (car fn)
                               (filter (lambda (c) (and (memq c names)
                                                        (not (eq? c (car fn)))))
                                       (callees-of (cdr fn)))))
                       fns)))
      (let loop ((left fns) (done '()) (out '()))
        (if (null? left)
            (reverse out)
            (let ((ready (filter (lambda (fn)
                                   (for-all (lambda (c) (memq c done))
                                            (cdr (assq (car fn) calls))))
                                 left)))
              (if (null? ready)
                  ;; a cycle: emit the rest in the order given, unresolved
                  (append (reverse out) left)
                  (loop (filter (lambda (fn) (not (memq fn ready))) left)
                        (append (map car ready) done)
                        (append (reverse ready) out))))))))

  (define (finalize-program* target arch selected blocks entry classes params)
    (let ((by-label (make-eq-hashtable))
          ;; function name -> the registers calling it can destroy. Absent means
          ;; "not known", which every caller treats as "everything".
          (clobbers (make-eq-hashtable))
          ;; function name -> (frame-bytes . ra-bytes), for D96's tail-call
          ;; frame reuse. Same callee-first argument as `clobbers`.
          (frames (make-eq-hashtable)))
      ;; THE RUNTIME GOES IN THE TABLE FIRST. A caller finding no entry assumes
      ;; the whole register file is gone, and the runtime is hand-written so
      ;; nothing ever put it there; every one of fannkuch's 21 spills traced to
      ;; exactly this (D103).
      ;;
      ;; `lane-mask?` is #t rather than the value the driver computes from this
      ;; very code. It only controls whether the prologue emits its AVX-512 k1
      ;; setup, which writes a mask register and no GP register, so #t is the
      ;; SUPERSET and over-approximating is the safe direction.
      ;;
      ;; A label whose walk refuses returns #f and is not entered, leaving that
      ;; routine exactly as conservative as before.
      (let ((rl (runtime-listing target entry #t)))
        (for-each (lambda (x)
                    (when (symbol? x)
                      (let ((c (runtime-clobbers rl x)))
                        (when c (hashtable-set! clobbers x c)))))
                  rl))
      (for-each (lambda (b) (hashtable-set! by-label (car b) (cadr b)))
                (cadddr selected))
      (let* (;; NOT THE ORPHAN BUCKET. `partition-into-functions` gathers blocks
             ;; that no entry reaches under `<unreachable>` so nothing is
             ;; silently dropped, which is the right thing for it to do and the
             ;; wrong thing to compile: a block no entry reaches cannot execute.
             ;;
             ;; Compiling it is not merely wasted bytes. The bucket is not a
             ;; procedure -- it has no parameter list, so it is treated as
             ;; receiving zero incoming stack words, and a tail call inside it
             ;; that needs one looks like a tail call that would grow the stack.
             ;; That refusal is correct for a real function and meaningless here,
             ;; and it aborts the compile over code that never runs.
             ;;
             ;; It became reachable when inline.ss started working: inlining a
             ;; procedure at its every call site leaves the original with no
             ;; callers, which is exactly what this bucket collects.
             (fns (reachable-functions
                   (filter (lambda (fn) (not (eq? (car fn) '<unreachable>)))
                           (partition-into-functions blocks entry))
                   entry))
             (out (make-eq-hashtable)))

        (define (finalize-one fn)
          (let* ((labels (remq (car fn) (map car (cdr fn))))
                 (sel-blocks (map (lambda (b)
                                    (list (car b)
                                          (hashtable-ref by-label (car b) '())))
                                  (cdr fn)))
                 (ps (hashtable-ref params (car fn) '()))
                 (pins (parameter-pins target (cdr fn) ps classes))
                 ;; WHAT A CALL DESTROYS, both halves.
                 ;;
                 ;; The callee's own writes, which `clobbers` records, AND the
                 ;; ARGUMENT REGISTERS this call site fills, which are nobody's
                 ;; writes but the caller's own. Missing the second half is not a
                 ;; missed optimisation: it hands a value a register that the
                 ;; argument setup a few instructions later overwrites. It did
                 ;; not matter while every live value spilled at every call --
                 ;; nothing was in a register to lose -- and it matters the
                 ;; moment one is allowed to stay.
                 ;;
                 ;; The return registers go in for the same reason: the call
                 ;; sequence moves its result out of one, and on x86-64 the
                 ;; float return register xmm0 IS allocatable.
                 (clobbers-of
                  (lambda (i)
                    (let* ((cc (callconv-by-name target))
                           (callee (and (pair? i) (>= (length i) 4)
                                        (symbol? (cadddr i)) (cadddr i)))
                           (c (and callee (hashtable-ref clobbers callee #f))))
                      (and c
                           (append
                            c
                            ;; the argument registers this site fills
                            (let loop ((as (cddddr i))
                                       (n (make-eq-hashtable)) (acc '()))
                              (if (null? as)
                                  acc
                                  (let* ((cl (or (and (symbol? (car as))
                                                      (hashtable-ref classes
                                                                     (car as) #f))
                                                 'raw-word))
                                         (k (hashtable-ref n cl 0))
                                         (r (arg-register cc cl k)))
                                    (hashtable-set! n cl (+ k 1))
                                    (loop (cdr as) n (if r (cons r acc) acc)))))
                            (apply append
                                   (map (lambda (cl) (return-registers cc cl))
                                        '(tagged raw-word raw-f64))))))))
                 (alloc (if (null? pins)
                            (allocate-program/clobbers arch (cdr fn) classes
                                                       clobbers-of)
                            ;; clobbers-of goes to BOTH paths. A function has
                            ;; pins exactly when it has parameters, so omitting
                            ;; it here applied the analysis to almost nothing.
                            (allocate-program/precolored
                             (callconv-by-name target) (cdr fn) classes pins
                             clobbers-of)))
                 (done
                  (finalize-function
                   target arch (car fn) sel-blocks alloc classes labels ps
                   ;; From the LMACH blocks, `(cdr fn)`, not the selected ones:
                   ;; Lmach still names a call's arguments as vregs the class
                   ;; table answers for, while selection has already turned them
                   ;; into stores whose count would have to be recovered by
                   ;; pattern matching.
                   (outgoing-words-for target (cdr fn) classes)
                   (tail-outgoing-words-for target (cdr fn) classes)
                   (remat-table target (cdr fn) classes)
                   ;; Spilled vregs joined by an Lmach `move` share a slot, so
                   ;; the copy between them costs nothing. Computed here because
                   ;; it needs BOTH the Lmach form -- a two-address fixup in the
                   ;; selected stream looks identical and must not be read as a
                   ;; copy -- and the spill set, which allocation has just
                   ;; produced.
                   (let ((sp (alloc-result-spills alloc)))
                     (move-aliases (cdr fn) (lambda (v) (memq v sp))))
                   ;; SHARED across every function in the program, and that is
                   ;; the whole point: a caller asks it about a callee that was
                   ;; finalized earlier, which callee-first ordering guarantees.
                   frames)))
            ;; What this one writes, for whoever calls it. Its own callees are
            ;; already recorded -- that is what `callee-first` buys -- so the
            ;; union closes over the call graph without a separate fixpoint.
            (hashtable-set!
             clobbers (car fn)
             (let loop ((cs (callees-of (cdr fn)))
                        (acc (listing-writes arch (finalized-listing done))))
               (cond
                ((null? cs) acc)
                ((eq? (car cs) (car fn)) (loop (cdr cs) acc))
                (else
                 (let ((c (hashtable-ref clobbers (car cs) #f)))
                   (if c
                       (loop (cdr cs)
                             (append (filter (lambda (r) (not (memq r acc))) c)
                                     acc))
                       ;; a callee we know nothing about taints this one too
                       (loop '() (append (arch-value arch) (arch-raw arch)
                                         (arch-float arch)))))))))
            done))

        ;; FINALIZED CALLEE-FIRST, RETURNED IN IMAGE ORDER. A caller can only be
        ;; allocated against real clobber sets once its callees are emitted, so
        ;; the walk order is the call graph's. The image's layout is not the call
        ;; graph's business, and reordering it would move every function in the
        ;; object file for a reason that has nothing to do with them.
        (for-each (lambda (fn) (hashtable-set! out (car fn) (finalize-one fn)))
                  (callee-first fns))
        (map (lambda (fn) (hashtable-ref out (car fn) #f)) fns))))
  )
