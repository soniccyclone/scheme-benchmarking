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
          frame-slot-offset frame-incoming-offset
          make-spiller spiller? spiller-target
          spiller-x86-64 spiller-rv64 spiller-for
          finalized? finalized-name finalized-listing
          finalized-frame finalized-spills)
  (import (chezscheme)
          (sonic regs)
          (sonic regalloc)
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
    (let ((n (* slot-bytes (+ (frame-layout-outgoing f) (frame-layout-count f)))))
      (if (zero? (modulo n 16)) n (+ n 8))))

  ;; Spill slots sit ABOVE the outgoing area, which is why this adds it in.
  ;; Getting the shift wrong is not a fault: it aliases a spilled value onto an
  ;; outgoing argument, so a call silently overwrites a live local.
  (define (frame-slot-offset f v)
    (let ((i (hashtable-ref (frame-layout-map f) v #f)))
      (and i (* slot-bytes (+ (frame-layout-outgoing f) i)))))

  ;; The offset at which the CALLEE finds its i'th incoming stack argument,
  ;; measured from its own stack pointer after the prologue. See the diagram on
  ;; `frame-layout`: past the whole frame, past the return address, then i
  ;; words up.
  (define (frame-incoming-offset f i)
    (+ (frame-layout-bytes f) slot-bytes (* slot-bytes i)))

  ;; Substitute the symbolic `(incoming i)` displacements the tail-call emitters
  ;; leave behind. Selection cannot compute these -- the offset is measured from
  ;; the CALLER'S frame, and the frame is not laid out until here -- so the
  ;; marker travels through selection, allocation and spill rewriting as an
  ;; opaque list and is resolved once, on the finished listing.
  ;;
  ;; Rewritten everywhere rather than at known positions, because the two
  ;; targets put it in different places: x86-64 inside a memory operand,
  ;; RV64 as a bare offset field on the store.
  (define (patch-incoming frame x)
    (cond
     ((and (pair? x) (eq? (car x) 'incoming))
      (frame-incoming-offset frame (cadr x)))
     ((pair? x) (cons (patch-incoming frame (car x))
                      (patch-incoming frame (cdr x))))
     (else x)))

  (define (build-frame spills outgoing)
    (let ((tbl (make-eq-hashtable)))
      (let loop ((vs spills) (i 0))
        (if (null? vs)
            (make-frame-layout tbl i outgoing)
            (if (hashtable-ref tbl (car vs) #f)
                (loop (cdr vs) i)
                (begin (hashtable-set! tbl (car vs) i)
                       (loop (cdr vs) (+ i 1))))))))

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
  (define (own-label? i own-labels)
    (let ((t (let loop ((xs (cdr i)))
               (cond ((null? xs) #f)
                     ((and (pair? (car xs)) (eq? (car (car xs)) 'label)) (cadr (car xs)))
                     ((symbol? (car xs)) (car xs))
                     (else (loop (cdr xs)))))))
      (and t (memq t own-labels) #t)))

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
                            (make-eq-hashtable))))

  (define (finalize-function* target arch name blocks alloc classes own-labels
                              params outgoing tail-outgoing remat)
    (let* ((sp (spiller-for target))
           (assign (alloc-result-map alloc))
           (spills (alloc-result-spills alloc))
           (frame (build-frame spills outgoing))
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
      (define (fold-reload i)
        (and (memq (car i) '(mov movsd))
             (= (length i) 3)
             (spiller-mem-operand sp)
             (let ((dst (cadr i)) (src (caddr i)))
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
                        (list '()
                              (list (car i)
                                    dst-phys
                                    ((spiller-mem-operand sp)
                                     (frame-slot-offset frame src) (class-of src)))
                              '())))))))

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
                     (over-int (max 0 (- (length ints) (length (spiller-int-scratch sp)))))
                     (over-flt (max 0 (- (length flts) (length (spiller-float-scratch sp)))))
                     (need-mem (+ over-int over-flt)))
                (when (> need-mem mem-budget)
                  (error 'finalize-function
                         (string-append
                          "this instruction has more spilled operands than the "
                          "target can serve with its reserved scratch registers "
                          "and its one memory operand, so the reloads would "
                          "clobber each other; the fix is live-range splitting "
                          "in the allocator, not another scratch here")
                         (spiller-target sp) i vs mem-budget))
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
                                     (let ((r (list-ref (spiller-float-scratch sp) nf)))
                                       (set! nf (+ nf 1)) r)
                                     (let ((r (list-ref (spiller-int-scratch sp) ni)))
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
                  (list pre (cons (car i) ops) post))))))))

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
                        (else #f)))))
               ;; RV64 spells a register move `addi rd, rs, 0` and a float one
               ;; `fsgnj.d rd, rs, rs`.
               ((addi)
                (and (= (length i) 4) (eqv? (cadddr i) 0)
                     (symbol? (cadr i)) (symbol? (caddr i))
                     (reg-class arch (cadr i)) (reg-class arch (caddr i))
                     (not (scratchy? (cadr i))) (not (scratchy? (caddr i)))
                     (cons (cadr i) (caddr i))))
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

      ;; A memory source that is NOT a spill slot is a DEFINITION, not a copy.
      ;;
      ;; This distinction is load-bearing and its absence produced a wrong
      ;; answer. A parallel copy permutes values that already exist: every
      ;; source names a location holding a live vreg, and the whole point of
      ;; resolving it is that a source must be read before the register holding
      ;; it is overwritten. A constant-pool load has no such value behind it --
      ;; it MAKES one -- so the moves after it want the register's NEW contents,
      ;; which is the exact opposite of what parallel semantics gives them.
      ;;
      ;; nbody's `offset-momentum!` starts three accumulators at 0.0 and tail
      ;; calls the loop. Once CSE noticed the three constants were one value,
      ;; the entry stub became:
      ;;
      ;;     movsd xmm0, [rip+pool]   ; 0.0 -- a DEFINITION
      ;;     movsd xmm1, xmm0
      ;;     movsd xmm2, xmm0
      ;;
      ;; and reading that as a parallel copy says xmm1 and xmm2 want the OLD
      ;; xmm0, so the resolver dutifully ordered the load LAST. xmm0 is
      ;; undefined at a function entry, so two of the three momentum
      ;; accumulators started at garbage and both energies came out wrong in the
      ;; twelfth digit -- close enough to look like rounding, which is what the
      ;; bit-exact oracle is for.
      ;;
      ;; Spill slots are the case that must stay IN the copy: `mov <argreg>,
      ;; [rsp+N]` reloads a vreg the copy is permuting, and excluding it was the
      ;; bug this function was written to fix. So the line is drawn at the base
      ;; register, which is exactly where the semantic difference lives.
      (define (definition-load? i)
        (and (pair? i)
             (memq (car i) '(mov movsd))
             (= (length i) 3)
             (let ((src (caddr i)))
               (and (pair? src) (eq? (car src) 'mem)
                    (not (memq (cadr src) '(rsp sp)))))))

      (define (resolve-argument-moves xs)
        (let loop ((xs xs) (run '()) (held '()) (defs '()) (out '()))
          (cond
           ((null? xs)
            (append (reverse out) (reverse defs) (reverse held) (reverse run)))
           ;; Hoisted to the FRONT of the run rather than dropped from it.
           ;; Hoisting is always safe: the load reads no register the copy could
           ;; clobber, and if the copy reads its destination, going first is
           ;; precisely what makes the copy see the value being defined.
           ((definition-load? (car xs))
            (loop (cdr xs) run held (cons (car xs) defs) out))
           ((mov-of (car xs))
            ;; A move after the epilogue would read a released frame, so the
            ;; held epilogue stays after the whole run.
            (loop (cdr xs) (cons (car xs) run) held defs out))
           ((frame-adjust? (car xs))
            (loop (cdr xs) run (cons (car xs) held) defs out))
           ((call-or-jump? (car xs))
            ;; The run before a transfer is the argument setup.
            (let-values (((resolved st)
                          (resolve-moves-in-block arch (reverse run) mov-of emit-mov)))
              (loop (cdr xs) '() '() '()
                    (cons (car xs)
                          (append (reverse held) (reverse resolved)
                                  (reverse defs) out)))))
           (else
            (loop (cdr xs) '() '() '()
                  ;; No reversing here, and the asymmetry with the call branch
                  ;; above is correct rather than an oversight.
                  ;;
                  ;; `out` is built so that `(reverse out)` is the final
                  ;; sequence, and `run` and `held` are accumulated by `cons` in
                  ;; that same reversed convention -- so they splice in as-is.
                  ;; The call branch reverses because `resolved` comes back from
                  ;; `resolve-moves-in-block` in FINAL order, which is the other
                  ;; convention.
                  ;; `defs` splices ahead of `run` for the same reason it is
                  ;; hoisted above: it defines values the run may read.
                  (cons (car xs) (append held run defs out)))))))

      ;; `mov r, r` / `movsd r, r` / RV64's `addi r, r, 0` and `fsgnj.d r, r, r`.
      (define (self-move? i)
        (case (car i)
          ((mov movsd) (and (= (length i) 3) (eq? (cadr i) (caddr i))))
          ((addi) (and (= (length i) 4) (eq? (cadr i) (caddr i)) (eqv? (cadddr i) 0)))
          ((fsgnj.d) (and (= (length i) 4) (eq? (cadr i) (caddr i))
                          (eq? (cadr i) (cadddr i))))
          (else #f)))

      (define (emit-mov dst src)
        ;; `float-register?`, not membership in the allocatable pool: a cycle is
        ;; broken through the float SCRATCH, which sits outside that pool, and
        ;; asking the pool spells the move `mov xmm15, xmm0`.
        (let ((float? (float-register? arch dst)))
          (if (eq? target 'rv64)
              (if float? `(fsgnj.d ,dst ,src ,src) `(addi ,dst ,src 0))
              (if float? `(movsd ,dst ,src) `(mov ,dst ,src)))))

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
                                                    (if (and ins
                                                             (or ((spiller-returns? sp) ins)
                                                                 (and ((spiller-tail-jump? sp) ins)
                                                                      (not (own-label? ins own-labels)))))
                                                        ((spiller-epilogue sp) bytes)
                                                        '())
                                                    (if ins (list ins) '())
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
                                     (off (frame-incoming-offset frame (caddr sa)))
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
               (head (append ((spiller-prologue sp) bytes)
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
                           frame
                           (if (and (pair? listing) (symbol? (car listing)))
                               (cons (car listing) (append head (cdr listing)))
                               (append head listing)))
                          frame
                          spills)))))


  ;; The whole program: one finalized listing per function.
  (define (finalize-program target arch selected blocks entry classes . opt)
    (finalize-program* target arch selected blocks entry classes
                       (if (pair? opt) (car opt) (make-eq-hashtable))))

  (define (finalize-program* target arch selected blocks entry classes params)
    (let ((by-label (make-eq-hashtable)))
      (for-each (lambda (b) (hashtable-set! by-label (car b) (cadr b)))
                (cadddr selected))
      (map (lambda (fn)
             (let* ((labels (remq (car fn) (map car (cdr fn))))
                    (sel-blocks (map (lambda (b)
                                       (list (car b) (hashtable-ref by-label (car b) '())))
                                     (cdr fn)))
                    (ps (hashtable-ref params (car fn) '()))
                    (pins (parameter-pins target (cdr fn) ps classes))
                    (alloc (if (null? pins)
                               (allocate-program arch (cdr fn) classes)
                               (allocate-program/precolored
                                (callconv-by-name target) (cdr fn) classes pins))))
               (finalize-function target arch (car fn) sel-blocks alloc classes labels
                                  ps
                                  ;; From the LMACH blocks, `(cdr fn)`, not the
                                  ;; selected ones: Lmach still names a call's
                                  ;; arguments as vregs the class table answers
                                  ;; for, while selection has already turned
                                  ;; them into stores whose count would have to
                                  ;; be recovered by pattern matching.
                                  (outgoing-words-for target (cdr fn) classes)
                                  (tail-outgoing-words-for target (cdr fn) classes)
                                  (remat-table target (cdr fn) classes))))
           (partition-into-functions blocks entry))))
  )
