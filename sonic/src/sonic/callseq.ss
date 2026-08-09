;;; The call sequence: the calling convention, made into instructions.
;;;
;;; E2. Bead 6gk.19. `callconv.ss` says WHERE a call's arguments and results
;;; live; the two selectors say WHAT instruction moves a value. Until this file
;;; existed nothing joined them, so an Lmach `(call v sc f a b c ...)` reached a
;;; rule that expected one operand and died on the operand count.
;;;
;;; This file is target-parametric in the same sense `select.ss` is: it holds
;;; the convention's shape and none of either ISA. A target supplies four small
;;; emitters -- a register move, a store into the outgoing argument area, a
;;; call and a jump -- and gets the whole sequence back. Both rule tables call
;;; in here rather than each re-deriving which register the fourth double goes
;;; in, because they would eventually disagree and the disagreement would be a
;;; wrong-code bug in exactly one back end.
;;;
;;; ## Three pools, not one list
;;;
;;; The argument registers are per storage class, and the numbering is per class
;;; too: the first tagged argument and the first raw argument both take index 0
;;; and land in different registers. That is `callconv.ss`'s doing and this file
;;; does not second-guess it. In particular `tail-call-plan` is what assigns
;;; registers and stack slots here, for ordinary calls as well as tail calls,
;;; because the assignment is the same question and the only difference is the
;;; transfer at the end.
;;;
;;; The RV64 case that makes the split load-bearing: a raw word may not travel
;;; in a0, even though the host ABI would put it there, because a0 is value
;;; class and the collector scavenges the value class unconditionally. Ask
;;; `callconv.ss`; do not reason it out again here.
;;;
;;; ## The result is not an instruction
;;;
;;; Bead 6cm.10. `(call v sc ...)` leaves its result in the convention's return
;;; register for `sc`, and the way to make `v` BE that register is to constrain
;;; the allocator, not to emit a move. So this file emits nothing for the
;;; result and exports `call-result-pins`, which reads a whole Lmach program and
;;; produces the pins `allocate/precolored` consumes. That is the join the bead
;;; asks for: one function, computed from the program, rather than a side
;;; channel out of selection.
;;;
;;; ## Two hazards this file does not solve, stated rather than hidden
;;;
;;; 1. PARALLEL COPY. The argument moves are emitted in sequence. If the
;;;    allocator happens to place an argument's source in a register a previous
;;;    move already wrote, the second move reads a clobbered value. Breaking
;;;    that cycle needs the allocation result, which selection does not have.
;;;    Stack stores are emitted BEFORE the register moves so that at least no
;;;    argument register write can precede a stack argument's read.
;;;
;;; 2. A TAIL CALL WITH STACK ARGUMENTS. The outgoing area would have to be
;;;    written over the caller's own frame, which is only safe once a frame
;;;    layout pass has said what in that frame is still live. There is no such
;;;    pass, so `tail-call-sequence` refuses rather than emitting a store that
;;;    is right on the days the sources happen to be in registers.

(library (sonic callseq)
  (export make-call-emitter call-emitter?
          call-emitter-name call-emitter-move call-emitter-store-arg
          call-emitter-call call-emitter-jump call-emitter-store-incoming-arg

          call-arg-classes call-plan reg-storage-class
          call-sequence tail-call-sequence
          call-result-pins)
  (import (chezscheme)
          (nanopass)
          (sonic lang)
          (sonic regs)
          (sonic callconv)
          (sonic select))

  ;; The four things a target has to say. Each returns a LIST of instructions,
  ;; so a target that needs two for a move is not forced to lie.
  ;;
  ;;   move       (lambda (sc reg src) ...)   reg := src, honouring the class
  ;;   store-arg  (lambda (sc slot src) ...)  outgoing stack word `slot` := src
  ;;   call       (lambda (callee) ...)       transfer, return address saved
  ;;   jump       (lambda (callee) ...)       transfer, no return address
  (define-record-type (call-emitter make-call-emitter call-emitter?)
    (fields name move store-arg call jump
            ;; A TAIL call's outgoing area is not below the caller's stack
            ;; pointer, it is the caller's own INCOMING argument area -- the
            ;; jump pushes no return address, so the callee reads its stack
            ;; arguments exactly where the caller's were. The offset therefore
            ;; depends on the caller's frame size, which selection does not
            ;; know, so this emits the symbolic displacement `(incoming i)` and
            ;; finalize.ss substitutes the number once the frame is laid out.
            store-incoming-arg))

  ;; The storage class an argument register implies. The register's partition
  ;; class IS the storage class -- that is what the partition means -- so this
  ;; is a spelling change and not a second table that could drift.
  (define (reg-storage-class cc r)
    (case (reg-class (callconv-arch cc) r)
      ((value) 'tagged)
      ((raw)   'raw-word)
      ((float) 'raw-f64)
      (else (error 'callseq
                   "the convention names an argument register that is in no allocatable class"
                   (callconv-name cc) r))))

  ;; The class of each argument, from the program-wide map `select.ss` builds.
  (define (call-arg-classes args) (map vreg-class args))

  ;; Register and stack assignment, both kinds of call. `frame-words` is the
  ;; caller's frame, which only the tail-call case reads.
  (define (call-plan cc callee args frame-words)
    (tail-call-plan cc (make-frame 'caller frame-words) callee
                    (map cons (call-arg-classes args) args)))

  ;; Stack stores first, then register moves: see hazard 1 in the header.
  ;;
  ;; `store` picks which of the two outgoing areas this call writes: the one at
  ;; the bottom of our own frame for an ordinary call, or the caller's incoming
  ;; area for a tail call.
  ;;
  ;; THE REGISTER MOVES ARE BRACKETED, and that bracket is the whole interface
  ;; to hazard 1. `parcopy.ss` cannot run until allocation has happened, and by
  ;; then the moves are indistinguishable from any other run of moves in the
  ;; instruction stream -- so finalize.ss used to recover them by pattern, as
  ;; "the maximal run of moves before a transfer".
  ;;
  ;; That pattern is not sound and could not be made sound. A move that COMPUTES
  ;; a value the copy then reads has to happen first; read as simultaneous it
  ;; becomes a swap. A genuine permutation has exactly the same shape, so no
  ;; predicate over the finished listing separates them -- three were tried, and
  ;; each made one program right and a different one wrong: nbody's
  ;; `subtract-pairs` looped forever, then fannkuch's `count-flips` passed a
  ;; register that was never written, then fannkuch's `step` dropped the
  ;; assignment of `maxflips` because the run held two writes to one register
  ;; and the resolver kept the last.
  ;;
  ;; This is the only place that knows, so this is the place that says. What is
  ;; between the markers is a parallel copy because it was BUILT as one, and
  ;; nothing downstream has to guess.
  (define (plan-instrs cc em plan store)
    (append
     (let loop ((ss (tail-plan-stack-args plan)) (slot 0) (out '()))
       (if (null? ss)
           (apply append (reverse out))
           (loop (cdr ss) (+ slot 1)
                 (cons (store (car (car ss)) slot (cdr (car ss)))
                       out))))
     (let ((moves (apply append
                         (map (lambda (m)
                                ((call-emitter-move em) (reg-storage-class cc (car m))
                                                        (car m) (cdr m)))
                              (tail-plan-moves plan)))))
       (if (null? moves)
           '()
           ;; Operandless, so every walk between here and finalize.ss ignores
           ;; them: the spiller asks `(cdr i)` for vregs and gets none, the
           ;; clobber scan asks for a destination and gets none.
           (append '((%argcopy)) moves '((%argcopy-end)))))))

  (define (split-callee who srcs)
    (when (null? srcs)
      (error who "a call needs a callee" srcs))
    (values (car srcs) (cdr srcs)))

  ;; `(call dst sc f a b c ...)`.
  ;;
  ;; The result move used to be omitted here, on the reasoning that placement
  ;; belongs to the allocator as a precoloring constraint rather than to an
  ;; instruction. `call-result-pins` expresses that constraint and nothing ever
  ;; consumed it, so `dst` was left holding whatever was in it before the call.
  ;;
  ;; That is not a missing optimisation. Every call in the program returned
  ;; garbage: nbody's `(fx> (length args) 1)` compared an uninitialised register
  ;; against 1, took the wrong branch, and reached a runtime routine that only
  ;; exists on the dead branch.
  ;;
  ;; A move is the right mechanism anyway. Precoloring would pin `dst` to the
  ;; return register for its whole live range, which is a caller-saved register
  ;; on both targets, so anything living past the next call would have to move
  ;; out regardless.
  (define (call-sequence cc em dst sc srcs)
    (let-values (((callee args) (split-callee 'call-sequence srcs)))
      (append (plan-instrs cc em (call-plan cc callee args 0)
                           (lambda (sc slot src)
                             ((call-emitter-store-arg em) sc slot src)))
              ((call-emitter-call em) callee)
              (if (and dst sc)
                  ((call-emitter-move em) sc dst (return-register cc sc))
                  '()))))

  ;; A tail call is a JUMP. Not a call followed by a return: that pushes a
  ;; return address, and proper tail calls are the one performance guarantee
  ;; R5RS makes, so a sequence that stacks a frame per iteration is not an
  ;; optimisation we skipped, it is the language broken.
  ;; A tail call's stack arguments go into the CALLER'S OWN incoming area, and
  ;; the check that this is safe is not here.
  ;;
  ;; It cannot be. The condition is that the callee needs no more stack words
  ;; than the caller received, and selection does not know the enclosing
  ;; function's signature -- `call-plan` is even called with a frame of zero
  ;; words, so the frame delta computed here would say "grows" for every tail
  ;; call with any stack argument at all. finalize.ss knows both numbers, and
  ;; that is where the refusal now lives.
  ;;
  ;; This used to refuse outright, on the grounds that there was no frame
  ;; layout pass to say where the area could go. There is one now: the layout
  ;; is fixed (see finalize.ss) and the address is expressible, symbolically,
  ;; as `(incoming i)`.
  (define (tail-call-sequence cc em dst sc srcs)
    (let-values (((callee args) (split-callee 'tail-call-sequence srcs)))
      (let ((plan (call-plan cc callee args 0)))
        (append (plan-instrs cc em plan
                             (lambda (sc slot src)
                               ((call-emitter-store-incoming-arg em) sc slot src)))
                ((call-emitter-jump em) callee)))))

  ;; --- the result, as a constraint on the allocator -------------------------

  (define (as-datum prog) (if (pair? prog) prog (unparse-Lmach prog)))

  ;; Every non-tail call in the program, as a pin: this vreg must land in the
  ;; return register for its class. Feed the result to `allocate/precolored`.
  ;;
  ;; Tail calls are skipped deliberately. A tail call has no result of its own
  ;; -- the value returns to OUR caller -- so its destination vreg is the one
  ;; the block's `(ret v)` already pins, and emitting both would look to
  ;; `pins-conflict?` like one vreg pinned twice to the same register.
  (define (call-result-pins cc prog)
    (let loop ((lbs (cadr (as-datum prog))) (acc '()))
      (if (null? lbs)
          (reverse acc)
          (let* ((blk (cadr (car lbs)))
                 (tc (tail-call-instr blk)))
            (loop (cdr lbs)
                  (fold-left
                   (lambda (out i)
                     (if (and (eq? (car i) 'call) (symbol? (cadr i)) (not (eq? i tc)))
                         (cons (make-pin (cadr i) (return-register cc (caddr i)) (caddr i))
                               out)
                         out))
                   acc (cadr blk)))))))
  )
