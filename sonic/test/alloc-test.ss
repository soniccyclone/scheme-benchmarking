(import (rnrs base) (rnrs lists) (rnrs control) (rnrs exceptions)
        (rnrs io simple) (sonic alloc) (sonic preempt))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define HDR 'header)

;; 64 words of nursery with 16 held back for the collector, so the mutator sees
;; 48 and the collector's worst case is provisioned before anyone needs it.
(define (fresh) (make-nursery 64 16))

;; --- the fast path is a pointer bump --------------------------------------

(let ((n (fresh)))
  ;; let*, not let: these are three allocations in a definite order and Chez
  ;; does not promise to evaluate let bindings left to right.
  (let* ((a (nursery-alloc! n 4 HDR))
         (b (nursery-alloc! n 4 HDR))
         (c (nursery-alloc! n 8 HDR)))
    (ck! "the first object starts at the nursery base"
         (= a (nursery-base n)))
    (ck! "each allocation moves the pointer by EXACTLY the size requested:
       there is no header search, no free list, no rounding"
         (and (= b (+ a 4)) (= c (+ b 4))))
    (ck! "the allocation pointer ends where the last object ends"
         (= (nursery-alloc-ptr n) (+ c 8)))
    (ck! "the header is written at the object's own address"
         (and (eq? (heap-ref n a) HDR) (eq? (heap-ref n c) HDR)))))

(ck! "the emitted fast path is seven instructions with ONE comparison"
     (and (= 7 (length (alloc-fast-path)))
          (= 1 (length (filter (lambda (m) (eq? m 'bgt))
                               (alloc-fast-path-mnemonics))))))
(ck! "and it contains no poll, yield or safepoint: D21 holds here too"
     (and (poll-free? (alloc-fast-path-mnemonics))
          (poll-free? (rs-push-path-mnemonics))))

;; --- the restart region ----------------------------------------------------

(ck! "the claim-then-fill window is a registered restart region"
     (and (region? alloc-region)
          (eq? (region-table-find alloc-region-table (region-start alloc-region))
               alloc-region)))
(ck! "rewind-pc returns the region's start from anywhere INSIDE it"
     (let loop ((pc (region-start alloc-region)))
       (cond ((= pc (region-end alloc-region)) #t)
             ((= (rewind-pc alloc-region-table pc) (region-start alloc-region))
              (loop (+ pc 1)))
             (else #f))))
(ck! "the region is half-open: the PC one past the fill is left alone, because
       the object is already valid there"
     (= (rewind-pc alloc-region-table (region-end alloc-region))
        (region-end alloc-region)))
(ck! "the region starts at the LOAD of the allocation pointer, not at the bump:
       a redo has to re-read a pointer that may have moved"
     (eq? (car (list-ref (alloc-fast-path) 0)) 'load))
(ck! "the remembered-set push has its own region and preempt.ss accepted both,
       which is the proof they do not overlap"
     (and (region? rs-region)
          (not (regions-overlap? alloc-region rs-region))
          (eq? (region-table-find alloc-region-table (region-start rs-region))
               rs-region)))

;; --- an interrupt anywhere in the window is restarted correctly -----------
;; The thread does not poll, cooperate, or know it happened. Stop it at every
;; PC in the region, rewind, and check the object that comes out is valid.

(let loop ((pc (region-start alloc-region)) (ok #t) (waste '()))
  (if (= pc (region-end alloc-region))
      (begin
        (ck! "an interrupt at EVERY PC in the claim-then-fill window yields a
       valid object with a consistent allocation pointer" ok)
        ;; Interrupts before the commit cost nothing. The one after the commit
        ;; abandons the claimed block, which a tracing collector never looks at.
        (ck! "only the PC between the commit and the header abandons a block,
       and it abandons exactly one"
             (equal? (reverse waste) '(0 0 0 0 0 4))))
      (let* ((n (fresh))
             (start (nursery-alloc-ptr n))
             (a (run-alloc n 4 HDR pc)))
        (loop (+ pc 1)
              (and ok
                   a
                   (eq? (heap-ref n a) HDR)              ; the object is valid
                   (= (nursery-alloc-ptr n) (+ a 4)))    ; the pointer agrees
              (cons (- a start) waste)))))

(let ((n (fresh)))
  (run-alloc n 4 HDR 5)
  (ck! "the abandoned block is headerless, which is exactly why the collector
       must be tracing rather than heap-parsing"
       (equal? (heap-ref n (nursery-base n)) 0)))

;; --- one comparison, two consumers ----------------------------------------
;; The allocation pointer grows up, the remembered-set pointer grows down, and
;; the single comparison between them is the whole bound check for both.

(ck! "the two pointers start at opposite ends of the same free region"
     (let ((n (fresh)))
       (and (= (nursery-alloc-ptr n) (nursery-base n))
            (= (nursery-rs-ptr n) (- (nursery-top n) (nursery-reserve n)))
            (= (nursery-free n) 48))))

(let ((n (fresh)))
  (nursery-alloc! n 20 HDR)
  (let ((before (nursery-free n)))
    (nursery-rs-push! n 'slot)
    (ck! "a remembered-set push consumes the SAME free words an allocation
       would have"
         (= (nursery-free n) (- before 1)))))

;; Fill from the allocation side; the store buffer runs out at that instant.
(let ((n (fresh)))
  (nursery-alloc! n 48 HDR)
  (ck! "with the nursery full from below, a remembered-set push fails: it is
       the same event on the same comparison"
       (and (= 0 (nursery-free n))
            (not (run-rs-push n 'slot #f)))))

;; Fill from the remembered-set side; allocation runs out at that instant.
(let ((n (fresh)))
  (let push ((i 0)) (when (< i 48) (nursery-rs-push! n 'slot) (push (+ i 1))))
  (ck! "with the same region full from above, allocation fails at the same
       point, and it is the same comparison that says so"
       (and (= 0 (nursery-free n))
            (not (run-alloc n 1 HDR #f))
            (nursery-would-overflow? n 1))))

;; Interleaved, to show there is one budget and not two.
(let ((n (fresh)))
  (nursery-alloc! n 24 HDR)
  (let push ((i 0)) (when (< i 24) (nursery-rs-push! n 'slot) (push (+ i 1))))
  (ck! "24 words allocated plus 24 words of store buffer exhausts a 48-word
       region: one budget, not two"
       (and (= 0 (nursery-free n))
            (not (run-alloc n 1 HDR #f))
            (not (run-rs-push n 'slot #f)))))

(ck! "the boundary is exact: the last word fits and the next does not"
     (let ((n (fresh)))
       (nursery-alloc! n 47 HDR)
       (and (run-alloc n 1 HDR #f)
            (not (run-alloc n 1 HDR #f))
            (not (run-rs-push n 'slot #f)))))

;; --- the collection worst case is reserved up front -----------------------

(ck! "the reserve is carved out before the mutator ever runs, and the mutator's
       comparison cannot see it"
     (let ((n (fresh)))
       (and (= 16 (nursery-reserve n))
            (reserve-intact? n)
            (= (reserve-base n) (nursery-rs-ptr n))
            (< (nursery-free n) (- (nursery-top n) (nursery-base n))))))

(set! checks (+ checks 1))
(let ((n (fresh)) (caught #f) (cond-obj #f))
  (guard (e (#t (set! caught #t) (set! cond-obj e)))
    (nursery-alloc! n 100 HDR))
  (if (and caught (heap-exhausted? cond-obj) (= 100 (heap-exhausted-request cond-obj)))
      (display "  ok   heap exhaustion RAISES A SCHEME CONDITION rather than aborting\n")
      (begin (set! failures (+ failures 1))
             (display "  FAIL heap exhaustion did not surface as a condition\n"))))

(ck! "and the reserve is still intact when it does, so the collector could
       have run"
     (let ((n (fresh)))
       (guard (e (#t #t)) (nursery-alloc! n 100 HDR))
       (and (reserve-intact? n)
            (= 16 (- (nursery-top n) (reserve-ptr n))))))

(ck! "the collector allocates out of the reserve, which the mutator's pointers
       never reach"
     (let ((n (fresh)))
       (nursery-alloc! n 48 HDR)
       (let ((p (reserve-claim! n 16)))
         (and p (= p (reserve-base n)) (not (reserve-intact? n))
              (not (reserve-claim! n 1))))))

;; A collector that actually frees turns the same exhaustion into a retry.
(ck! "with a collector installed, the slow path collects and the allocation
       succeeds"
     (let ((n (fresh)) (ran 0))
       (nursery-collector-set! n (lambda (nn) (nursery-alloc-ptr-set! nn 0)))
       (nursery-alloc! n 40 HDR)
       (let ((a (nursery-alloc! n 40 HDR)))
         (and a (= a 0) (eq? (heap-ref n a) HDR)))))

(ck! "a collector that frees nothing still surfaces a condition, not an abort"
     (let ((n (fresh)))
       (nursery-collector-set! n (lambda (nn) #f))
       (guard (e (#t (heap-exhausted? e))) (nursery-alloc! n 100 HDR) #f)))

(newline)
;; --- the aliasing, asserted on the INSTRUCTIONS ---------------------------
;; The behavioural tests above show the two exhaust together. This shows WHY:
;; both paths end in the same comparison against the same limit. The allocation
;; pointer grows up and the remembered-set pointer grows down, so `add` and
;; `sub` are the only difference, and the store buffer's dedicated limit
;; register and its bound check are both free because there is only one.
(let* ([a (alloc-fast-path-mnemonics)]
       [r (rs-push-path-mnemonics)]
       [shared (filter (lambda (x) (memq x r)) a)])
  (ck! "both paths end in the same comparison"
          (and (memq 'bgt a) (memq 'bgt r) #t))
  (ck! "allocation grows UP and the remembered set grows DOWN"
          (and (memq 'add a) (memq 'sub r)
               (not (memq 'sub a)) (not (memq 'add r))))
  ;; If someone gives the store buffer its own limit register, this breaks:
  ;; the paths stop sharing and the second bound check reappears.
  (ck! "neither path carries a second limit load the other lacks"
          (= (length (filter (lambda (x) (eq? x 'load)) a))
             (length (filter (lambda (x) (eq? x 'load)) r)))))

(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") 


(newline) (exit 0)))
