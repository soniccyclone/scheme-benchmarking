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
;;; Nothing else is in the frame yet. No callee-saved saves, because the
;;; allocator has not been told which registers a call clobbers; no outgoing
;;; argument area, because nothing here passes arguments on the stack. Both are
;;; refused rather than omitted, so a program that grows one fails loudly
;;; instead of quietly corrupting its own return address.

(library (sonic finalize)
  (export finalize-function finalize-program
          make-frame-layout frame-layout? frame-layout-map frame-layout-count
          frame-layout-bytes frame-slot-offset
          make-spiller spiller? spiller-target
          spiller-x86-64 spiller-rv64 spiller-for
          finalized? finalized-name finalized-listing
          finalized-frame finalized-spills)
  (import (chezscheme)
          (sonic regs)
          (sonic regalloc)
          (sonic callconv)
          (sonic parcopy))

  ;; --- frame layout ---------------------------------------------------------

  (define-record-type (frame-layout make-frame-layout frame-layout?)
    (fields map        ; vreg -> slot index
            count))    ; number of slots

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
    (let ((n (* slot-bytes (frame-layout-count f))))
      (if (zero? (modulo n 16)) n (+ n 8))))

  (define (frame-slot-offset f v)
    (let ((i (hashtable-ref (frame-layout-map f) v #f)))
      (and i (* slot-bytes i))))

  (define (build-frame spills)
    (let ((tbl (make-eq-hashtable)))
      (let loop ((vs spills) (i 0))
        (if (null? vs)
            (make-frame-layout tbl i)
            (if (hashtable-ref tbl (car vs) #f)
                (loop (cdr vs) i)
                (begin (hashtable-set! tbl (car vs) i)
                       (loop (cdr vs) (+ i 1))))))))

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
     '(rax)
     '(xmm15)
     ;; x86-64 reads memory directly, which is the whole reason it gets away
     ;; with four raw registers. A spilled SOURCE does not need a scratch at
     ;; all: `cmp rax, [rsp+16]` is one instruction. Exactly one operand may be
     ;; memory, so this covers the second spilled operand and no more.
     (lambda (off sc) `(mem rsp #f 1 ,off))
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
     '(t0 t1 t2)
     '(ft9 ft10 ft11)
     ;; RV64 is load/store: no arithmetic instruction reads memory, so every
     ;; spilled operand costs a scratch. That is the trade the ISA makes, and it
     ;; is why RV64 reserves two integer scratches where x86-64 reserves one.
     #f
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
                        (if (pair? opt) (car opt) '())))

  (define (finalize-function* target arch name blocks alloc classes own-labels params)
    (let* ((sp (spiller-for target))
           (assign (alloc-result-map alloc))
           (spills (alloc-result-spills alloc))
           (frame (build-frame spills))
           (bytes (frame-layout-bytes frame))
           (spilled? (lambda (v) (and (symbol? v)
                                      (hashtable-ref (frame-layout-map frame) v #f)
                                      #t))))

      (define (class-of v)
        (or (hashtable-ref classes v #f)
            (error 'finalize-function "spilled vreg has no storage class" v)))

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
      (define (mem-eligible i v)
        (let loop ((xs (cdr i)) (k 0) (hit #f))
          (cond ((null? xs) hit)
                ((eq? (car xs) v)
                 (if (or hit (= k 0)) #f (loop (cdr xs) (+ k 1) k)))
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
      (define (do-instr i)
        (let ((vs (distinct (apply append (map spilled-in (cdr i))))))
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
                                            (if (and (eq? v dst-v) (not (reads-dst? i)))
                                                '()
                                                ((spiller-reload sp)
                                                 r (frame-slot-offset frame v) (class-of v)))))
                                        chosen)))
                       (post (apply append
                                    (map (lambda (p)
                                           (let ((v (car p)) (r (cdr p)))
                                             (if (eq? v dst-v)
                                                 ((spiller-store sp)
                                                  (frame-slot-offset frame v) r (class-of v))
                                                 '())))
                                         chosen))))
                  (list pre (cons (car i) ops) post))))))

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
      (define (mov-of i)
        (and (pair? i)
             (memq (car i) '(mov movsd addi fsgnj.d))
             (case (car i)
               ((mov movsd)
                (and (= (length i) 3) (symbol? (cadr i)) (symbol? (caddr i))
                     (reg-class arch (cadr i)) (reg-class arch (caddr i))
                     (cons (cadr i) (caddr i))))
               ;; RV64 spells a register move `addi rd, rs, 0` and a float one
               ;; `fsgnj.d rd, rs, rs`.
               ((addi)
                (and (= (length i) 4) (eqv? (cadddr i) 0)
                     (symbol? (cadr i)) (symbol? (caddr i))
                     (reg-class arch (cadr i)) (reg-class arch (caddr i))
                     (cons (cadr i) (caddr i))))
               ((fsgnj.d)
                (and (= (length i) 4) (eq? (caddr i) (cadddr i))
                     (cons (cadr i) (caddr i))))
               (else #f))))

      ;; Resolve the maximal run of moves ending at each call or tail jump.
      (define (call-or-jump? i)
        (and (pair? i)
             (memq (car i) '(call jmp jal jalr ret))))

      (define (resolve-argument-moves xs)
        (let loop ((xs xs) (run '()) (out '()))
          (cond
           ((null? xs) (append (reverse out) (reverse run)))
           ((mov-of (car xs)) (loop (cdr xs) (cons (car xs) run) out))
           ((call-or-jump? (car xs))
            ;; The run before a transfer is the argument setup.
            (let-values (((resolved st)
                          (resolve-moves-in-block arch (reverse run) mov-of emit-mov)))
              (loop (cdr xs) '() (cons (car xs) (append (reverse resolved) out)))))
           (else
            ;; Anything else ends the run and the run stays as written.
            (loop (cdr xs) '() (cons (car xs) (append run out)))))))

      (define (emit-mov dst src)
        ;; `float-register?`, not membership in the allocatable pool: a cycle is
        ;; broken through the float SCRATCH, which sits outside that pool, and
        ;; asking the pool spells the move `mov xmm15, xmm0`.
        (let ((float? (float-register? arch dst)))
          (if (eq? target 'rv64)
              (if float? `(fsgnj.d ,dst ,src ,src) `(addi ,dst ,src 0))
              (if float? `(movsd ,dst ,src) `(mov ,dst ,src)))))

      (let* ((listing
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
                                                    (if (or ((spiller-returns? sp) ins)
                                                            (and ((spiller-tail-jump? sp) ins)
                                                                 (not (own-label? ins own-labels))))
                                                        ((spiller-epilogue sp) bytes)
                                                        '())
                                                    (list ins)
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
            (listing (resolve-argument-moves listing)))
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
               (arrivals
                (let loop ((ps params) (n (make-eq-hashtable)) (acc '()))
                  (if (null? ps)
                      (reverse acc)
                      (let* ((p (car ps))
                             (c (or (hashtable-ref classes p #f)
                                    (error 'finalize-function
                                           "a parameter with no storage class; nothing says which argument register it arrives in"
                                           name p)))
                             (k (hashtable-ref n c 0)))
                        (hashtable-set! n c (+ k 1))
                        (loop (cdr ps) n
                              (cons (list 'move p c (arg-register cc c k)) acc))))))
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
               (head (append ((spiller-prologue sp) bytes) arrival-instrs)))
          ;; The prologue goes AFTER the function's entry label, not before it.
          ;;
          ;; Before it, the only way to execute it is to fall in from whatever
          ;; precedes the function in the image -- and every call jumps straight
          ;; to the label, skipping it. The frame is then never reserved, so
          ;; every spill slot writes below the stack pointer, over the return
          ;; address the call just pushed.
          (make-finalized name
                          (if (and (pair? listing) (symbol? (car listing)))
                              (cons (car listing) (append head (cdr listing)))
                              (append head listing))
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
                    (alloc (allocate-program arch (cdr fn) classes)))
               (finalize-function target arch (car fn) sel-blocks alloc classes labels
                                  (hashtable-ref params (car fn) '()))))
           (partition-into-functions blocks entry))))
  )
