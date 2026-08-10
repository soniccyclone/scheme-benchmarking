;;; Dead code elimination over Lmach.
;;;
;;; ## Why there was nothing here, and what that cost
;;;
;;; Every pass upstream of this one produces instructions it does not always
;;; need, and none of them can tell. `elide` proves `n-bodies` is 3 and rewrites
;;; the USE into a constant, leaving the `gref` that loaded it. `lower` emits a
;;; vreg for every intermediate whether or not the value survives. `essa`'s phi
;;; wrappers copy values into names that a later fold made unnecessary. Each of
;;; those is locally correct and locally unable to see that the result is dead,
;;; because the use it would have to inspect is in another pass's output.
;;;
;;; The result was visible in nbody's position-update loop as pairs like:
;;;
;;;     mov rsi, [n-bodies]     ; gref, dead
;;;     mov rsi, 3              ; the constant elision proved
;;;
;;;     mov rcx, [rsp+8]        ; reload, dead
;;;     mov rcx, [rsp+0]
;;;
;;; Two instructions per pair, in a loop body, for nothing. They are not
;;; register-allocation artifacts -- the allocator faithfully materialised a
;;; definition the IR asked for. The IR should not have asked.
;;;
;;; ## The liveness criterion, and why it is the crude one
;;;
;;; A definition is dead here when the vreg it defines appears as an OPERAND
;;; nowhere in the whole function -- not "nowhere after this point". That is
;;; much weaker than real liveness and it is deliberate.
;;;
;;; Lmach is a control-flow graph, so "after this point" is a dataflow question,
;;; and getting it wrong in the direction of "looks dead" deletes a value a loop
;;; back edge reads on the next iteration. The regalloc file already carries the
;;; scar from straight-line liveness being wrong across a back edge. The whole
;;; program criterion cannot make that mistake: if any instruction anywhere
;;; mentions the vreg, the definition stays.
;;;
;;; It is also enough. Every case above is a value with no reader at all, which
;;; is precisely what this catches. Sharpening it to per-point liveness buys
;;; partially-dead definitions, and those want the real dataflow the allocator
;;; already computes -- a separate job, and one worth doing only if measurement
;;; says the remainder is worth it.
;;;
;;; ## The fixpoint
;;;
;;; Removing a dead definition removes its operands' last use, which can make
;;; THEIR definitions dead. `(gref t sc n)` feeding a `(move dead sc t)` needs
;;; two rounds: the move goes first, then the gref. So this iterates.
;;;
;;; ## What is never removed
;;;
;;; An op is removable only if evaluating it has no effect anyone can observe.
;;; `store` and `gset` write memory. `call` runs arbitrary code. `chk` traps,
;;; which is its entire purpose. `div` can raise on x86-64 -- integer division
;;; by zero is #DE, not a value -- and a `chk div-check` guarding it is a
;;; SEPARATE instruction, so deleting a dead `div` would delete a trap the
;;; program is entitled to take. It is also rare enough that keeping it costs
;;; nothing measurable.

(library (sonic dce)
  (export dce-program dce-stats dce-stats? dce-stats-removed dce-stats-rounds)
  (import (chezscheme))

  (define-record-type (dce-stats make-dce-stats dce-stats?)
    (fields (mutable removed) (mutable rounds)))

  ;; Ops whose only effect is to produce their destination vreg. Anything not
  ;; listed here is kept, so the list being incomplete costs instructions and
  ;; never correctness -- which is the right way round for a table that a new
  ;; mach-op could be added to without anyone thinking about this file.
  ;; `const` BELONGS HERE AND WAS MISSING, and the pass that makes it matter
  ;; runs immediately before this one. addrfold.ss rewrites `add(v, k)` into
  ;; `add-imm`, whose constant rides in the instruction -- which orphans the
  ;; `(const kv raw-word k)` that used to hold it. Every such constant was
  ;; kept. fannkuch's `flip-prefix` showed it as a `mov $0x1,%r11` that no
  ;; instruction reads, once per iteration of the hottest loop in the
  ;; benchmark, next to the `add $0x1` that made it redundant.
  (define pure-ops
    '(const add sub mul neg sqrt abs
      cmp-lt cmp-le cmp-eq cmp-ge cmp-gt
      fcmp-lt fcmp-le fcmp-eq fcmp-ge fcmp-gt
      load load-at move vlen gref add-imm mul-imm
      cvt-f64-from-int cvt-int-from-f64))

  ;; Operand vregs of one instruction. The DESTINATION is not an operand: that
  ;; is the whole point -- a definition whose destination is used nowhere is
  ;; what this pass removes, so counting it here would make every instruction
  ;; keep itself alive.
  (define (operands-of i)
    (cond
     ((not (pair? i)) '())
     ((eq? (car i) 'const) '())               ; (const v sc d)
     ((eq? (car i) 'chk) (cddddr i))          ; (chk pn c d v* ...)
     ((memq (car i) pure-ops) (cdddr i))      ; (op v sc v* ...)
     ;; NOT pure, so this instruction stays either way -- which makes it free
     ;; to be conservative about which of its slots are READS.
     ;;
     ;; `gset` is why that matters. It is spelled (gset v sc cell), and `v` is
     ;; the value being stored, not a destination. Reading slot 1 as a
     ;; destination would leave whatever computed that value with no apparent
     ;; reader, and this pass would delete it -- silently storing garbage into
     ;; a global. Rather than keep a second table of which ops put a source in
     ;; the destination slot, and have it drift the first time an op is added,
     ;; every slot of a surviving instruction counts as a read. The cost is a
     ;; few labels and cell names in the `used` table; they are not vregs, so
     ;; they keep nothing alive.
     (else (cdr i))))

  (define (transfer-uses t)
    (cond
     ((not (pair? t)) '())
     ((eq? (car t) 'jump) '())
     ((eq? (car t) 'branch-if) (list (cadr t)))
     ((eq? (car t) 'ret) (list (cadr t)))
     (else '())))

  ;; The vreg an instruction defines, or #f when it defines nothing.
  (define (defines i)
    (cond
     ((not (pair? i)) #f)
     ((eq? (car i) 'chk) #f)
     ((eq? (car i) 'const) (cadr i))
     ((memq (car i) pure-ops) (cadr i))
     (else #f)))                              ; store, gset, call, ret, ...

  (define (removable? i used)
    (let ((v (defines i)))
      (and v (not (hashtable-ref used v #f)))))

  ;; `prog` is an Lmach `program` datum: (program ([lbl blk] ...) entry),
  ;; each blk being (block (i ...) t).
  (define (dce-program prog)
    (unless (and (pair? prog) (eq? (car prog) 'program))
      (error 'dce-program "not an Lmach program datum" prog))
    (let ([stats (make-dce-stats 0 0)])
      (let loop ([blocks (cadr prog)] [round 0])
        (let ([used (make-eq-hashtable)])
          ;; Mark, over the WHOLE program: every operand of every surviving
          ;; instruction, plus everything the transfers read.
          (for-each
           (lambda (lb)
             (let ([blk (cadr lb)])
               (for-each (lambda (i)
                           (for-each (lambda (v) (hashtable-set! used v #t))
                                     (operands-of i)))
                         (cadr blk))
               (for-each (lambda (v) (hashtable-set! used v #t))
                         (transfer-uses (caddr blk)))))
           blocks)
          ;; Sweep.
          (let* ([dropped 0]
                 [blocks*
                  (map (lambda (lb)
                         (let* ([blk (cadr lb)]
                                [kept (filter (lambda (i)
                                                (if (removable? i used)
                                                    (begin (set! dropped (+ dropped 1)) #f)
                                                    #t))
                                              (cadr blk))])
                           (list (car lb) (list 'block kept (caddr blk)))))
                       blocks)])
            (dce-stats-removed-set! stats (+ (dce-stats-removed stats) dropped))
            (dce-stats-rounds-set! stats (+ round 1))
            ;; A bound as well as a fixpoint. Each round strictly shrinks the
            ;; program, so it terminates on its own; the bound is here because
            ;; an argument for termination is not a guard, and this compiler has
            ;; already had one unbounded loop cons until the OOM killer answered.
            (if (and (> dropped 0) (< round 100))
                (loop blocks* (+ round 1))
                (values (list 'program blocks* (caddr prog)) stats)))))))
  )
