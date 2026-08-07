;;; Linear-scan register allocation, enforcing the partition.
;;;
;;; E2-RA. Poletto and Sarkar's linear scan, with one addition that is the whole
;;; reason this bead is P0: **every assignment is checked against the register
;;; partition** (sonic/src/sonic/regs.ss).
;;;
;;; A tagged value reaching a raw register is a root the collector will never
;;; find, because under D21 the collector scavenges the value class
;;; unconditionally and consults no metadata. That is silent memory corruption,
;;; not a slow program, so the allocator raises rather than warning.
;;;
;;; Linear scan rather than graph colouring on purpose. Chaitin-style colouring
;;; buys maybe a few percent on straight-line numeric code and costs a
;;; build-coalesce-spill loop whose spill heuristic Chaitin's own prose and SETL
;;; appendix disagree about. The partition already fragments the register file,
;;; which is the thing colouring is best at exploiting, so the return is smaller
;;; here than usual.

(library (sonic regalloc)
  (export allocate live-intervals live-intervals/arch physical?
          make-alloc-result alloc-result? alloc-result-map
          alloc-result-spills alloc-result-arch)
  (import (chezscheme)
          (sonic regs))

  (define-record-type (alloc-result make-alloc-result alloc-result?)
    (fields arch map spills))

  ;; --- live intervals -------------------------------------------------------
  ;; A linear pass over a flat instruction list. Each vreg gets [first-def,
  ;; last-use]. Straight-line only, which is what a basic block is; extending to
  ;; a whole CFG is a later bead and needs the loop structure from E4-LOOP so a
  ;; vreg live across a back edge stays live to the end of the loop.

  (define (live-intervals instrs) (live-intervals/arch instrs #f))

  (define (live-intervals/arch instrs arch)
    ;; instrs: list of (op dst sc src ...) with dst possibly #f
    (let ([tbl (make-eq-hashtable)])
      (let loop ([is instrs] [i 0])
        (unless (null? is)
          (let* ([ins (car is)]
                 [dst (cadr ins)]
                 [srcs (cdddr ins)])
            (when (and (symbol? dst) (not (and arch (physical? arch dst))))
              (let ([e (hashtable-ref tbl dst #f)])
                (if e
                    (set-cdr! e (max (cdr e) i))
                    (hashtable-set! tbl dst (cons i i)))))
            (for-each
             (lambda (s)
               (when (and (symbol? s) (not (and arch (physical? arch s))))
                 (let ([e (hashtable-ref tbl s #f)])
                   (if e
                       (set-cdr! e (max (cdr e) i))
                       ;; A use with no prior def: live in from before this
                       ;; block. Start it at -1 so it sorts first and is never
                       ;; mistaken for a local temporary.
                       (hashtable-set! tbl s (cons -1 i))))))
             srcs))
          (loop (cdr is) (+ i 1))))
      ;; -> ((vreg start . end) ...) sorted by start
      (sort (lambda (a b) (< (cadr a) (cadr b)))
            (map (lambda (k)
                   (let ([e (hashtable-ref tbl k #f)])
                     (list k (car e) (cdr e))))
                 (vector->list (hashtable-keys tbl))))))

  ;; --- the scan -------------------------------------------------------------

  (define (pool-for arch sc)
    (case sc
      ((tagged)   (arch-value arch))
      ((raw-word) (arch-raw arch))
      ((raw-f64)  (arch-float arch))
      (else (error 'pool-for "unknown storage class" sc))))

  ;; A PHYSICAL register name in an operand slot is not a vreg, and the
  ;; allocator has to know the difference.
  ;;
  ;; The two-address fixup puts a scratch register (xmm15, t0) directly into an
  ;; operand, because the allocator runs over Lmach and never sees selected
  ;; output, so there is no vreg to request. Without this check `live-intervals`
  ;; treats that symbol as a virtual register and `allocate` either dies on
  ;; "vreg has no storage class" or -- far worse -- renames the scratch to an
  ;; allocatable register and silently emits wrong code for exactly the case the
  ;; fixup exists to handle.
  ;;
  ;; So: a name in ANY register class is skipped, not allocated. That subsumes
  ;; the adapter twoaddr.ss had to carry.
  (define (physical? arch r)
    (and (symbol? r) (reg-class arch r) #t))

  ;; `classes` maps vreg -> storage class, which is what Lrepr carries.
  (define (allocate arch instrs classes)
    (let* ([ivals (live-intervals/arch instrs arch)]
           [assign (make-eq-hashtable)]
           [spills '()]
           ;; free pools, one per storage class, kept disjoint by construction
           [free (make-eq-hashtable)])
      (for-each (lambda (sc) (hashtable-set! free sc (pool-for arch sc)))
                '(tagged raw-word raw-f64))
      (let scan ([is ivals] [active '()])
        (if (null? is)
            (make-alloc-result arch assign (reverse spills))
            (let* ([iv (car is)]
                   [v (car iv)] [start (cadr iv)]
                   [sc (let ([p (hashtable-ref classes v #f)])
                         (or p (error 'allocate "vreg has no storage class" v)))])
              ;; expire intervals that ended before this one starts
              (let ([still-active
                     (let expire ([as active] [keep '()])
                       (cond
                        [(null? as) (reverse keep)]
                        [(< (caddr (car as)) start)
                         (let* ([done (car as)]
                                [dv (car done)]
                                [dsc (hashtable-ref classes dv #f)]
                                [dr (hashtable-ref assign dv #f)])
                           (when dr
                             (hashtable-set! free dsc (cons dr (hashtable-ref free dsc '()))))
                           (expire (cdr as) keep))]
                        [else (expire (cdr as) (cons (car as) keep))]))])
                (let ([pool (hashtable-ref free sc '())])
                  (if (null? pool)
                      (begin
                        (set! spills (cons v spills))
                        (scan (cdr is) still-active))
                      (let ([r (car pool)])
                        ;; THE assertion. Not a warning.
                        (check-assignment! arch sc r)
                        (hashtable-set! assign v r)
                        (hashtable-set! free sc (cdr pool))
                        (scan (cdr is) (cons iv still-active)))))))))))
  )
