;;; Preemption model: no polls, restart regions.
;;;
;;; E1-PREEMPT, implementing D21. The full costing is in
;;; docs/phases/07-compiler/PREEMPTION.md.
;;;
;;; ## The invariant
;;;
;;; SonicScheme emits NO poll instruction, NO suspend flag the mutator reads,
;;; and NO list of allowed stopping points. A thread is stopped by an interrupt
;;; wherever it happens to be, and the collector reads its registers and stack
;;; directly using the PC-total metadata in sonic/src/sonic/gcmeta.ss.
;;;
;;; ## Why this and not safepoint polls
;;;
;;; The forcing fact, from compare-operating-systems bundle/axes/scheduling.md:
;;; the loop that makes a Scheme match C is a tight numeric loop with no
;;; procedure calls, no allocation, and unboxed values in registers, which is BY
;;; CONSTRUCTION a loop with no safepoint. That is exactly the code this project
;;; exists to emit, so a poll-based design puts its worst case precisely where
;;; our hot path is.
;;;
;;; Three code generators over thirty years converged on the function prologue,
;;; sound only because Erlang and Scheme have no loop construct and iteration is
;;; tail recursion. Lanf has a `tailcall` production for that reason, but it
;;; ALSO has ordinary loops that lower to jumps, and the moment one of those
;;; exists the prologue guarantee dies silently. Inferno is the worked example
;;; of that failure; Biscuit is the one where the machine is finished while the
;;; thread table round-robins a dead system at 1000Hz.
;;;
;;; Under this model none of that applies, because there is nothing to place.
;;;
;;; ## Restart regions
;;;
;;; One place the invariant genuinely cannot hold: the allocator's claim-then-
;;; fill window. The fast path bumps the pointer, then writes the object header
;;; several instructions later, and in between the memory is not a valid object.
;;;
;;; The answer is NOT a poll. The region is marked restartable and the collector
;;; REWINDS the saved program counter to the region's start, so the allocation
;;; is simply redone. It costs nothing on the fast path and nothing in the
;;; common case where no collection happens, and the thread never polls,
;;; cooperates, or knows it happened.
;;;
;;; Restart regions must be idempotent-on-rewind: everything a region does
;;; before its commit point must be safe to do twice. `region-safe?` is the
;;; check, and it is the obligation a region author has to discharge.

(library (sonic preempt)
  (export make-region region? region-start region-end region-name
          regions-overlap? region-contains?
          make-region-table region-table-add! region-table-find
          rewind-pc
          poll-free? emitted-poll-mnemonics)
  (import (rnrs base)
          (rnrs lists)
          (rnrs control)
          (rnrs records syntactic)
          (rnrs io simple))

  ;; A restart region is a half-open PC range [start, end) within one function.
  (define-record-type (region make-region region?)
    (fields name start end))

  (define (region-contains? r pc)
    (and (>= pc (region-start r)) (< pc (region-end r))))

  ;; Overlapping restart regions are a bug, not a configuration. If two regions
  ;; overlap, a PC inside both has two different rewind targets and the
  ;; collector has no principled way to choose. The table refuses them.
  (define (regions-overlap? a b)
    (and (< (region-start a) (region-end b))
         (< (region-start b) (region-end a))))

  (define (make-region-table) (list))

  (define (region-table-add! tbl r)
    (for-each
     (lambda (existing)
       (when (regions-overlap? existing r)
         (error 'region-table-add!
                "overlapping restart regions have no principled rewind target"
                (region-name existing) (region-name r))))
     tbl)
    (cons r tbl))

  (define (region-table-find tbl pc)
    (let loop ((rs tbl))
      (cond ((null? rs) #f)
            ((region-contains? (car rs) pc) (car rs))
            (else (loop (cdr rs))))))

  ;; What the collector does to a thread stopped inside a restart region: move
  ;; the saved PC back to the region start so the sequence is redone from the
  ;; top. A PC outside every region is left exactly where it was, which is the
  ;; common case and must stay free.
  (define (rewind-pc tbl pc)
    (let ((r (region-table-find tbl pc)))
      (if r (region-start r) pc)))

  ;; --- the invariant, as an assertion over emitted code ---------------------
  ;;
  ;; E1-PREEMPT's acceptance criterion is that a grep over emitted code for a
  ;; poll or yield check returns nothing. This is that grep, as a predicate the
  ;; back-end tests can call once there is emitted code to check.
  ;;
  ;; The list is deliberately over-broad. A false positive costs one look at a
  ;; disassembly; a false negative means we shipped the design we spent
  ;; PREEMPTION.md rejecting.
  (define (emitted-poll-mnemonics)
    '(poll yield safepoint gc-check stack-check
      check-interrupt test-interrupt poll-interrupt
      %poll %yield %safepoint))

  (define (poll-free? mnemonics)
    (not (exists (lambda (m) (memq m (emitted-poll-mnemonics))) mnemonics)))
  )
