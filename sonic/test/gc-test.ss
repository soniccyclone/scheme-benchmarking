;;; The precise generational copying collector.
;;;
;;; The tests that matter here are the ones a CONSERVATIVE collector would also
;;; pass. "Reachable objects survive" is true of Boehm too, and RESEARCH.md
;;; section 3 is where Boehm costs Stalin 5x to 16x, so a suite that only checks
;;; survival proves nothing about the decision D21 records.
;;;
;;; So every precision case in this file is stated as a CONTRAST. The test
;;; builds a machine state, computes the root set a conservative scan would
;;; produce from the same bytes, shows it is strictly larger, and then shows
;;; this collector's answer differs in exactly the way precision requires. Three
;;; separate consequences are checked, because they fail differently:
;;;
;;;   LEAK        a dead object whose bit pattern survives in a raw register is
;;;               reclaimed anyway.
;;;   RELOCATION  one bit pattern in two slots, one tagged and one raw, comes
;;;               out of a collection as two DIFFERENT words. No conservative
;;;               collector can do this; it is the reason it cannot move
;;;               objects, and moving objects is the reason we get to bump
;;;               allocate.
;;;   CRASH       a raw word that decodes to an address with no header is never
;;;               dereferenced. The collector's own copy routine, applied to
;;;               that word by hand, raises -- so the test shows the trap is
;;;               real and that precision is what keeps us out of it.

(import (chezscheme)
        (sonic gc)
        (sonic alloc)
        (sonic gcmeta)
        (sonic preempt))

(define failures 0)
(define checks 0)

(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok
      (printf "  ok   ~a\n" name)
      (begin (set! failures (+ failures 1))
             (printf "  FAIL ~a\n" name))))

;; --- fixture scaffolding ---------------------------------------------------

;; 96 words of nursery, 8 held back for the collector, and 256 words of old
;; space so the worst-case reserve check passes by a wide margin.
(define (fresh-heap) (make-gc-heap 96 8 256))

;; One frame, one entry at offset 0, whatever frame bits are asked for.
(define (one-frame bits . maybe-flags)
  (let ((flags (if (null? maybe-flags) '((frame? . 1)) (car maybe-flags))))
    (make-frame (list (make-entry 0 flags bits)) 0 (length bits) 0)))

(define (state-with stack-words frame regs)
  (make-thread-state target-x86-64 (list->vector stack-words) regs
                     (list frame) alloc-region-table))

(define (regs-with value-words)
  (let ((rf (fresh-regfile 8 4 15 1)))
    (let loop ((i 0) (ws value-words))
      (unless (null? ws)
        (vector-set! (regfile-value rf) i (car ws))
        (loop (+ i 1) (cdr ws))))
    rf))

;; THE COMPARISON. Everything a conservative collector would have to treat as a
;; root: every machine word in the thread, from every register file and every
;; stack slot, with no metadata consulted -- because a conservative collector
;; has none to consult. It cannot tell which of these are pointers, so it must
;; assume all of them are.
(define (conservative-roots st)
  (let ((rf (thread-state-regs st)))
    (filter pointer-word?
            (append (vector->list (thread-state-stack st))
                    (vector->list (regfile-value rf))
                    (vector->list (regfile-raw rf))
                    (vector->list (regfile-float rf))
                    (vector->list (regfile-scratch rf))))))

(define (precise-root-words st)
  (map slot-ref (precise-roots st)))

;; The value class is scanned unconditionally and is always in the root set, so
;; a test about the STACK map has to look at the stack roots specifically.
(define (stack-roots st)
  (filter (lambda (s) (eq? 'stack (car (slot-name s)))) (precise-roots st)))

(define (forwarded? h w) (forward? (gc-header h w)))

(printf "precise generational copying collector:\n")

;; ===========================================================================
;; 1. It collects.
;; ===========================================================================

(let* ((h (fresh-heap))
       (live (gc-alloc! h (tagged-hdr 'pair 2) (list (word-fixnum 1) (word-fixnum 2))))
       (dead (gc-alloc! h (tagged-hdr 'pair 2) (list (word-fixnum 3) (word-fixnum 4))))
       (rf (regs-with (list live)))
       (st (state-with (list (word-fixnum 0)) (one-frame '(#f)) rf))
       (used-before (gc-nursery-used h))
       (stats (gc-collect! h st))
       (live2 (vector-ref (regfile-value rf) 0)))
  (ck! "a reachable object survives, with its fields intact"
       (and (= 2 (hdr-fields (gc-header h live2)))
            (= (word-fixnum 1) (gc-field-ref h live2 0))
            (= (word-fixnum 2) (gc-field-ref h live2 1))))
  (ck! "it MOVED: the root now names a to-space address, and the from-space
       header has been replaced by a forwarding record"
       (and (not (= live live2))
            (gc-old-addr? h (word->addr live2))
            (forwarded? h live)))
  (ck! "the unreachable object was NOT copied: its header is still a header,
       never a forwarding record"
       (and (hdr? (gc-header h dead)) (not (forwarded? h dead))))
  (ck! "exactly one object was copied and to-space grew by exactly its size"
       (and (= 1 (gc-stats-copied stats)) (= 3 (gc-stats-words stats))))
  (ck! "the nursery is empty afterwards: the cost of a copying collection is
       proportional to what SURVIVED, not to what died"
       (and (= 6 used-before) (= 0 (gc-nursery-used h)))))

;; Shared structure stays shared, and a cycle terminates. Both are the
;; forwarding record doing its job.
(let* ((h (fresh-heap))
       (shared (gc-alloc! h (tagged-hdr 'box 1) (list (word-fixnum 7))))
       (a (gc-alloc! h (tagged-hdr 'pair 2) (list shared shared)))
       (b (gc-alloc! h (tagged-hdr 'pair 2) (list shared (word-fixnum 0))))
       (rf (regs-with (list a b)))
       (st (state-with (list (word-fixnum 0)) (one-frame '(#f)) rf))
       (stats (gc-collect! h st))
       (a2 (vector-ref (regfile-value rf) 0))
       (b2 (vector-ref (regfile-value rf) 1)))
  (ck! "a diamond is not duplicated: three objects in, three objects out, and
       all three references to the shared one are the same word"
       (and (= 3 (gc-stats-copied stats))
            (= (gc-field-ref h a2 0) (gc-field-ref h a2 1))
            (= (gc-field-ref h a2 0) (gc-field-ref h b2 0)))))

(let* ((h (fresh-heap))
       (x (gc-alloc! h (tagged-hdr 'node 1) (list (word-fixnum 0))))
       (y (gc-alloc! h (tagged-hdr 'node 1) (list x))))
  (gc-field-set! h x 0 y)                        ; close the cycle
  (let* ((rf (regs-with (list x)))
         (st (state-with (list (word-fixnum 0)) (one-frame '(#f)) rf))
         (stats (gc-collect! h st))
         (x2 (vector-ref (regfile-value rf) 0)))
    (ck! "a cycle terminates and comes out a cycle: Cheney's queue is the
       to-space itself, so there is no recursion to overflow"
         (and (= 2 (gc-stats-copied stats))
              (= x2 (gc-field-ref h (gc-field-ref h x2 0) 0))))))

;; An flvector's payload is raw f64 bits. Tracing it would scavenge doubles as
;; pointers, which is the corruption regs.ss refuses in the register file.
(let* ((h (fresh-heap))
       ;; These bit patterns are, as integers, valid tagged pointers into the
       ;; nursery. A collector that traced this object would follow them.
       (fv (gc-alloc! h (raw-hdr 'flvector 2) (list (word-pointer 0) (word-pointer 3))))
       (rf (regs-with (list fv)))
       (st (state-with (list (word-fixnum 0)) (one-frame '(#f)) rf))
       (stats (gc-collect! h st))
       (fv2 (vector-ref (regfile-value rf) 0)))
  (ck! "an flvector's payload is not traced, even when the bits look exactly
       like pointers: the header says which fields are tagged and none are"
       (and (= 1 (gc-stats-copied stats))
            (= (word-pointer 0) (gc-field-ref h fv2 0))
            (= (word-pointer 3) (gc-field-ref h fv2 1)))))

;; ===========================================================================
;; 2. PRECISION. The whole reason for D21.
;; ===========================================================================

;; --- LEAK -------------------------------------------------------------------
;;
;; A dead object whose exact tagged word is still sitting in a raw register and
;; in an unmarked stack slot. Conservative scanning finds it in both places.

(let* ((h (fresh-heap))
       (live (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 1))))
       (dead (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 2))))
       (rf (regs-with (list live))))
  ;; The bit pattern of the dead object, left in places the collector must not
  ;; believe: a raw register, a float register, and a stack slot whose frame bit
  ;; is clear.
  (vector-set! (regfile-raw rf) 0 dead)
  (vector-set! (regfile-float rf) 0 dead)
  (let* ((st (state-with (list live dead) (one-frame '(#t #f)) rf))
         (cons-roots (conservative-roots st))
         (prec-roots (precise-root-words st)))
    (ck! "a conservative scan of this exact state finds the dead object THREE
       times: raw register, float register, unmarked stack slot"
         (= 3 (length (filter (lambda (w) (= w dead)) cons-roots))))
    (ck! "the precise root set does not contain it at all, and holds strictly
       fewer pointer-shaped words than the conservative one"
         (and (not (memv dead prec-roots))
              (< (length (filter pointer-word? prec-roots))
                 (length cons-roots))))
    (let ((stats (gc-collect! h st)))
      (ck! "so the collection reclaims it: ONE object copied, not two. This is
       the case where a conservative collector leaks and we do not"
           (= 1 (gc-stats-copied stats)))
      (ck! "and the dead object was never even looked at: its header is intact
       rather than forwarded"
           (and (hdr? (gc-header h dead)) (not (forwarded? h dead)))))))

;; --- RELOCATION -------------------------------------------------------------
;;
;; The same bit pattern in two stack slots. One is marked tagged, one is not.
;; After a collection they must be DIFFERENT words: the tagged one updated to
;; to-space, the raw one byte-for-byte unchanged. A conservative collector has
;; exactly two options and both are wrong here -- pin the object and update
;; neither, or update both and corrupt an integer.

(let* ((h (fresh-heap))
       (obj (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 9))))
       (rf (regs-with '()))
       (st (state-with (list obj obj) (one-frame '(#t #f)) rf)))
  (gc-collect! h st)
  (let ((tagged-slot (vector-ref (thread-state-stack st) 0))
        (raw-slot (vector-ref (thread-state-stack st) 1)))
    (ck! "one bit pattern, two slots, two DIFFERENT answers after collection:
       the tagged slot was relocated and the raw slot was left alone"
         (and (not (= tagged-slot raw-slot))
              (= raw-slot obj)
              (gc-old-addr? h (word->addr tagged-slot))))
    (ck! "and the relocated slot names the real object, with its field intact"
         (= (word-fixnum 9) (gc-field-ref h tagged-slot 0)))))

;; --- CRASH ------------------------------------------------------------------
;;
;; A raw word decoding to an address in the middle of an object, where there is
;; no header. This is what a conservative scan hits whenever an interior pointer
;; or a plausible integer shows up.

(let* ((h (fresh-heap))
       (obj (gc-alloc! h (tagged-hdr 'pair 2) (list (word-fixnum 1) (word-fixnum 2))))
       ;; One word past the header: a field, not an object.
       (interior (word-pointer (+ (word->addr obj) 1)))
       (rf (regs-with (list obj))))
  (vector-set! (regfile-raw rf) 0 interior)
  (let ((st (state-with (list interior) (one-frame '(#f)) rf)))
    (ck! "a conservative scan would treat the interior word as a root"
         (memv interior (conservative-roots st)))
    (ck! "and following it raises: there is no header there, and the collector
       refuses to invent a size rather than copying garbage"
         (guard (e (#t #t)) (gc-forward! h interior) #f))
    ;; Now the same word, left where it is, with a precise collection over it.
    (let ((stats (gc-collect! h st)))
      (ck! "but the collection completes, because the precise root set never
       contained it: precision is what keeps us out of that trap"
           (= 1 (gc-stats-copied stats)))
      (ck! "and the raw word is unchanged, as an integer must be"
           (and (= interior (vector-ref (regfile-raw (thread-state-regs st)) 0))
                (= interior (vector-ref (thread-state-stack st) 0)))))))

;; --- the metadata is consulted, and it is a step function -------------------

(let* ((h (fresh-heap))
       (a (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 1))))
       (b (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 2))))
       (rf (regs-with '()))
       ;; Two entries. Slot 0 is tagged from offset 0; slot 1 only becomes
       ;; tagged at offset 10.
       (f (make-frame (list (make-entry 0 '((frame? . 1)) '(#t #f))
                            (make-entry 10 '((frame? . 1)) '(#t #t)))
                      0 2 7))
       (st (make-thread-state target-x86-64 (vector a b) rf (list f) alloc-region-table)))
  (ck! "a PC with no entry of its own takes the last entry at or before it:
       gcmeta.ss's step function, consulted for real"
       (= 1 (length (stack-roots st))))
  (let ((stats (gc-collect! h st)))
    (ck! "so at PC 7 only slot 0 is a root and the other object dies"
         (= 1 (gc-stats-copied stats)))))

(let* ((h (fresh-heap))
       (a (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 1))))
       (b (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 2))))
       (rf (regs-with '()))
       (f (make-frame (list (make-entry 0 '((frame? . 1)) '(#t #f))
                            (make-entry 10 '((frame? . 1)) '(#t #t)))
                      0 2 12))
       (st (make-thread-state target-x86-64 (vector a b) rf (list f) alloc-region-table)))
  (ck! "and four instructions later, at PC 12, the SAME frame has two roots and
       both objects live. Same stack, same bytes, different answer"
       (= 2 (gc-stats-copied (gc-collect! h st)))))

;; A PC the metadata does not cover is a compiler bug. Fail loudly rather than
;; falling back to scanning the frame conservatively.
(let* ((h (fresh-heap))
       (rf (regs-with '()))
       (f (make-frame (list (make-entry 8 '((frame? . 1)) '(#t))) 0 1 2))
       (st (make-thread-state target-x86-64 (vector (word-fixnum 0)) rf (list f)
                              (make-region-table))))
  (ck! "a PC before the first metadata entry raises: the metadata is supposed
       to be TOTAL, so a gap is a bug and not a licence to guess"
       (guard (e (#t #t)) (precise-roots st) #f)))

;; --- scratch-live, which is the one place a RAW register IS a root ----------

(let* ((h (fresh-heap))
       (obj (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 5))))
       (rf (regs-with '())))
  (vector-set! (regfile-scratch rf) 0 obj)
  ;; scratch-live = 1: on x86-64 that is a strict nesting COUNT, so the low one
  ;; scratch register is transiently holding a tagged value.
  (let* ((f (one-frame '(#f) '((frame? . 1) (scratch-live . 1))))
         (st (state-with (list (word-fixnum 0)) f rf)))
    (ck! "a scratch register named by scratch-live IS scanned: the flag exists
       precisely because a raw register can transiently hold a tagged value"
         (= 1 (gc-stats-copied (gc-collect! h st))))
    (ck! "and the scratch register was UPDATED to the new address, which is the
       half a read-only root scan would get wrong"
         (let ((w (vector-ref (regfile-scratch rf) 0)))
           (and (not (= w obj))
                (gc-old-addr? h (word->addr w))
                (= (word-fixnum 5) (gc-field-ref h w 0)))))))

(let* ((h (fresh-heap))
       (obj (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 5))))
       (rf (regs-with '())))
  (vector-set! (regfile-scratch rf) 0 obj)
  (let* ((f (one-frame '(#f) '((frame? . 1) (scratch-live . 0))))
         (st (state-with (list (word-fixnum 0)) f rf)))
    (ck! "with scratch-live clear the SAME register holding the SAME word is
       not a root, and the object dies"
         (= 0 (gc-stats-copied (gc-collect! h st))))))

(ck! "x86-64 reads scratch-live as a strict nesting count and RV64 as a bitmap,
       and they are decoded separately because they mean different things"
     (and (equal? '(0 1) (scratch-live-indices target-x86-64 2))
          (equal? '(0 2) (scratch-live-indices target-rv64 5))))

;; ===========================================================================
;; 3. The write barrier.
;; ===========================================================================

(ck! "the barrier is ten instructions"
     (= 10 (length (barrier-path))))

(ck! "and its last six ARE alloc.ss's remembered-set push, spliced rather than
       restated, so the aliased comparison cannot drift"
     (equal? (rs-push-path) (list-tail (barrier-path) 4)))

(ck! "the store comes FIRST: the push can overflow, the overflow drives a
       collection, and the collector must see the new value in the slot"
     (equal? '(store (mem obj off) val) (car (barrier-path))))

(ck! "there is NO generation check: every load in the barrier reads the thread
       block, and nothing reads a segment table or the object's generation"
     (barrier-generation-check-free? (barrier-path)))

(ck! "and the one test it does perform is on the stored VALUE, never on the
       object being stored into"
     (barrier-tests-only-the-value? (barrier-path)))

(ck! "the barrier contains no poll, yield or safepoint either: D21 holds here
       as much as it does in alloc.ss"
     (poll-free? (barrier-mnemonics)))

;; Both of those predicates are worthless if nothing can fail them, and a
;; predicate over the shape of emitted code is exactly the kind that quietly
;; becomes a tautology. Hand each one the design it exists to refuse.
(ck! "and both predicates have teeth: a path that reads a segment table is
       rejected by the first, and a path that tests the OBJECT's tag instead of
       the stored value's -- a generation check wearing a tag test's clothes --
       is rejected by the second"
     (and (barrier-generation-check-free? '((load t (thread rs-ptr))))
          (not (barrier-generation-check-free?
                '((load g (segment obj)) (and t g gen-mask))))
          (barrier-tests-only-the-value? '((and t val tag-mask)))
          (not (barrier-tests-only-the-value? '((and t obj tag-mask))))))

;; --- it catches a cross-generation store ------------------------------------
;;
;; The sharpest form of this test is the control. The same program, with the
;; barrier and without it, and the difference is whether a live object survives.

(define (cross-generation-store use-barrier?)
  (let* ((h (fresh-heap))
         (parent (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 0))))
         (rf (regs-with (list parent)))
         (st (state-with (list (word-fixnum 0)) (one-frame '(#f)) rf)))
    ;; First collection promotes the parent into old space.
    (gc-collect! h st)
    (let ((promoted (vector-ref (regfile-value rf) 0)))
      ;; A fresh nursery object, stored into the promoted parent and then
      ;; dropped from every register. Nothing but the parent's field refers to
      ;; it, and the parent is in a generation this collection does not scan.
      (let ((child (gc-alloc! h (tagged-hdr 'box 1) (list (word-fixnum 42)))))
        (if use-barrier?
            (gc-store! h promoted 0 child)
            (gc-field-set! h promoted 0 child)))
      (let ((stats (gc-collect! h st)))
        (list h (vector-ref (regfile-value rf) 0) stats)))))

(let* ((with (cross-generation-store #t))
       (h (car with)) (p (cadr with)) (stats (caddr with)))
  (ck! "WITH the barrier, the old-to-new store is remembered and the child
       survives a collection that scans no old-space object"
       (and (= 1 (gc-stats-copied stats))
            (= 1 (gc-stats-honoured stats))
            (pointer-word? (gc-field-ref h p 0))
            (= (word-fixnum 42) (gc-field-ref h (gc-field-ref h p 0) 0))))
  (ck! "and the parent's field was UPDATED to the child's new address, not left
       pointing into the nursery"
       (gc-old-addr? h (word->addr (gc-field-ref h p 0)))))

(let* ((without (cross-generation-store #f))
       (h (car without)) (p (cadr without)) (stats (caddr without)))
  (ck! "WITHOUT it, nothing is remembered, nothing is copied, and the parent is
       left holding a dangling from-space pointer. That is the bug the barrier
       exists to prevent, and it is the price of choosing generations"
       (and (= 0 (gc-stats-copied stats))
            (= 0 (gc-stats-remembered stats))
            (gc-nursery-addr? h (word->addr (gc-field-ref h p 0))))))

;; --- the mutator pushes everything; the COLLECTOR sorts it ------------------

(let* ((h (fresh-heap))
       (a (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 0))))
       (b (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 0))))
       (rf (regs-with (list a b)))
       (st (state-with (list (word-fixnum 0)) (one-frame '(#f)) rf)))
  ;; Every one of these is a store the barrier records, and every one of them
  ;; is junk to the collector: nursery-to-nursery, and duplicated.
  (gc-store! h a 0 b)
  (gc-store! h a 0 b)
  (gc-store! h b 0 a)
  (ck! "the barrier pushed every non-fixnum store it saw, including duplicates
       and nursery-to-nursery ones: it has no way to tell and does not try"
       (= 3 (length (remembered-entries h))))
  (let ((stats (gc-collect! h st)))
    (ck! "and the collector dropped all three, once, over a batch. That deferral
       is what keeps the barrier at ten instructions"
         (and (= 3 (gc-stats-remembered stats))
              (= 0 (gc-stats-honoured stats))
              (= 3 (gc-stats-dropped stats)))))
  (ck! "the store buffer is empty again afterwards"
       (= 0 (length (remembered-entries h)))))

;; A fixnum store records nothing at all: the one tag test is the whole filter
;; the mutator performs.
(let* ((h (fresh-heap))
       (a (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 0)))))
  (gc-store! h a 0 (word-fixnum 123))
  (ck! "a fixnum store pushes nothing: that is the ONE test the mutator makes"
       (= 0 (length (remembered-entries h)))))

;; ===========================================================================
;; 4. Restart regions: the collector is what rewinds.
;; ===========================================================================

(let* ((h (fresh-heap))
       (rf (regs-with '()))
       (f (make-frame (list (make-entry 0 '((frame? . 1) (restart? . 1)) '(#f))) 0 1 3))
       (st (make-thread-state target-x86-64 (vector (word-fixnum 0)) rf
                              (list f) alloc-region-table)))
  (ck! "a thread stopped inside the claim-then-fill window has its PC rewound
       to the region START by the COLLECTOR: the mutator never polls,
       cooperates, or knows it happened"
       (begin (gc-collect! h st)
              (= (region-start alloc-region) (frame-pc f)))))

(let* ((h (fresh-heap))
       (rf (regs-with '()))
       (f (make-frame (list (make-entry 0 '((frame? . 1)) '(#f))) 0 1 9))
       (st (make-thread-state target-x86-64 (vector (word-fixnum 0)) rf
                              (list f) alloc-region-table)))
  (ck! "a PC outside every region is left exactly where it was, which is the
       common case and stays free"
       (begin (gc-collect! h st) (= 9 (frame-pc f)))))

;; ===========================================================================
;; 5. The reserve, and heap exhaustion as a condition.
;; ===========================================================================

(let ((h (fresh-heap)))
  (ck! "the worst case reserved is the whole mutator-usable nursery: in the
       limit every object survives a minor collection"
       (and (= 88 (gc-worst-case h)) (gc-reserve-ok? h))))

;; A to-space too small for the worst case. Note the nursery here holds almost
;; nothing, so a collection would in fact succeed -- and it still refuses,
;; because reserving after the fact is what produces the half-collected heap
;; nobody recovers from.
(let* ((h (make-gc-heap 96 8 16))
       (obj (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 1))))
       (rf (regs-with (list obj)))
       (st (state-with (list (word-fixnum 0)) (one-frame '(#f)) rf))
       (caught #f))
  (ck! "to-space smaller than the worst case fails the check up front"
       (not (gc-reserve-ok? h)))
  (guard (e (#t (set! caught e))) (gc-collect! h st))
  (ck! "and heap exhaustion RAISES A SCHEME CONDITION a program can catch,
       rather than aborting. The bundle's finding is that this is what
       separates the systems that survive it from Linux, Chez and Mirage"
       (and (heap-exhausted? caught) (= 88 (heap-exhausted-request caught))))
  (ck! "the collection did not start: nothing was copied and old space is
       untouched, so there is no half-collected heap to recover from"
       (= 0 (gc-old-used h))))

(let* ((h (make-gc-heap 96 8 16))
       (obj (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 1))))
       (rf (regs-with (list obj)))
       (st (state-with (list (word-fixnum 0)) (one-frame '(#f)) rf))
       (n (gc-heap-nursery h)))
  (ck! "the condition object was built out of alloc.ss's RESERVE, which the
       mutator's comparison can never reach. Allocating it from the space we
       just failed to find is the circularity that turns a recoverable error
       into an abort"
       (and (reserve-intact? n)
            (begin (guard (e (#t #t)) (gc-collect! h st))
                   (and (not (reserve-intact? n))
                        (= gc-condition-words
                           (- (reserve-ptr n) (reserve-base n))))))))

;; The reserve pointer moving proves a claim was made, not that anything was
;; built. A reserve charged for a condition it never wrote is the same failure
;; with a passing test in front of it, so read the words back.
(let* ((h (make-gc-heap 96 8 16))
       (obj (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 1))))
       (rf (regs-with (list obj)))
       (st (state-with (list (word-fixnum 0)) (one-frame '(#f)) rf))
       (n (gc-heap-nursery h))
       (p (reserve-base n)))
  (guard (e (#t #t)) (gc-collect! h st))
  (let ((head (heap-ref n p)))
    (ck! "and the object is really THERE: a parseable header and the two fields
       the condition carries, at an address above both mutator pointers"
         (and (hdr? head)
              (eq? 'heap-exhausted (hdr-kind head))
              (= 2 (hdr-fields head))
              (= (word-fixnum 88) (heap-ref n (+ p 1)))
              (>= p (nursery-rs-ptr n))
              (> p (nursery-alloc-ptr n))))))

;; The reserve holds two condition objects and no more. Spend it, and the third
;; exhaustion has nowhere to build one.
(let* ((h (make-gc-heap 96 8 16))
       (obj (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 1))))
       (rf (regs-with (list obj)))
       (st (state-with (list (word-fixnum 0)) (one-frame '(#f)) rf)))
  (guard (e (#t #t)) (gc-collect! h st))
  (guard (e (#t #t)) (gc-collect! h st))
  (let ((third (guard (e (#t e)) (gc-collect! h st) #f)))
    (ck! "with the reserve spent, exhaustion says the RESERVE was sized wrong
       rather than handing back an &heap-exhausted whose object was never
       built. Skipping the write silently would report success for the one
       guarantee the reserve exists to make"
         (and third (not (heap-exhausted? third))))))

;; ===========================================================================
;; 6. Wired to alloc.ss, not duplicating it.
;; ===========================================================================

(let* ((h (fresh-heap))
       (rf (regs-with '()))
       (st (state-with (list (word-fixnum 0)) (one-frame '(#f)) rf))
       (n (gc-heap-nursery h)))
  (gc-install! h (lambda () st))
  ;; Fill the nursery to the last word with garbage nothing refers to.
  ;; Twenty-two four-word objects is exactly the 88 words the mutator can see.
  (let loop ((i 0))
    (when (< i 22)
      (gc-alloc! h (tagged-hdr 'pair 3) (list (word-fixnum i)))
      (loop (+ i 1))))
  (ck! "the nursery is full to the last word with unreachable objects"
       (= 88 (gc-nursery-used h)))
  (let ((w (gc-alloc! h (tagged-hdr 'pair 3) (list (word-fixnum 99)))))
    (ck! "the next allocation overflows, alloc.ss's slow path calls THIS
       collector, and the allocation then succeeds from a fresh nursery"
         (and (pointer-word? w)
              (= (nursery-base n) (word->addr w))
              (= (word-fixnum 99) (gc-field-ref h w 0))))
    (ck! "and nothing survived, because nothing was rooted"
         (= 0 (gc-old-used h)))))

;; The remembered-set push runs off the SAME comparison, so overflowing the
;; store buffer drives a collection too. One budget, not two.
(let* ((h (fresh-heap))
       (a (gc-alloc! h (tagged-hdr 'pair 1) (list (word-fixnum 0))))
       (rf (regs-with (list a)))
       (st (state-with (list (word-fixnum 0)) (one-frame '(#f)) rf))
       (n (gc-heap-nursery h)))
  (gc-install! h (lambda () st))
  (let loop ((i 0))
    (when (< i 200)
      (gc-store! h (vector-ref (regfile-value rf) 0) 0 (vector-ref (regfile-value rf) 0))
      (loop (+ i 1))))
  (ck! "200 barrier pushes into an 88-word region drive collections through the
       SAME comparison the allocator uses, and the program keeps running"
       (and (> (nursery-rs-ptr n) (nursery-alloc-ptr n))
            (pointer-word? (vector-ref (regfile-value rf) 0)))))

;; ===========================================================================
;; 7. The allocation assist, and the control loop that is not in it.
;; ===========================================================================
;;
;; "Some assist happened" is not the property. Go has an assist too, and Go's is
;; the design Biscuit deleted. What separates them is that Go's coefficient is
;; republished by a controller and this one is a literal, so every check below
;; is about the RATE holding still rather than about a charge being made.

;; --- the charge, as a function --------------------------------------------

(ck! "a zero-word allocation is charged zero: no fixed term is hiding in the
       rate"
     (= 0 (assist-charge 0)))

(ck! "the charge is the size times the rate at every size, with no rounding,
       no floor and no ceiling"
     (let loop ((s 0))
       (cond ((> s 512) #t)
             ((= (assist-charge s) (* s assist-work-per-word)) (loop (+ s 1)))
             (else #f))))

(ck! "additive over every pair up to 64: charge(a+b) = charge(a) + charge(b).
       A pacer fails this, because by the time it charges for b the rate it
       charged a at has moved"
     (let outer ((a 0))
       (cond ((> a 64) #t)
             (else (let inner ((b 0))
                     (cond ((> b 64) (outer (+ a 1)))
                           ((= (assist-charge (+ a b))
                               (+ (assist-charge a) (assist-charge b)))
                            (inner (+ b 1)))
                           (else #f)))))))

(ck! "and homogeneous, so the charge for an allocation of at most k words is at
       most k times the rate -- a bound computable without running anything.
       An unbounded charge is the one that cannot be paid inside a lock or an
       interrupt handler, which is Biscuit's reason for deleting Go's"
     (let loop ((s 0) (worst 0))
       (if (> s 256)
           (= worst (* 256 assist-work-per-word))
           (loop (+ s 1) (max worst (assist-charge s))))))

(ck! "the charge admits exactly one argument, the size. There is no parameter
       through which a phase, a deadline or a residual could arrive"
     (= (assist-charge-arity) (procedure-arity-mask (lambda (size) size))))

;; --- the emitted shape ----------------------------------------------------

(ck! "the emitted assist is five instructions and carries the rate as an
       IMMEDIATE. In Go that operand is a load of the controller's published
       assistWorkPerByte; immediate versus load is the whole of this bead"
     (and (= 5 (length (assist-path)))
          (assist-constant-rate? (assist-path))))

(ck! "no load on the path reaches anything but the thread block, and there is
       no division -- dividing outstanding scan work by remaining heap distance
       is exactly how a controller computes a rate"
     (assist-feedback-free? (assist-path)))

(ck! "the predicates have teeth: a path that loads a published rate is
       rejected, a path that divides to compute one is rejected even though all
       its loads are thread-local, and a multiply against a REGISTER rate is
       not a constant rate"
     (and (not (assist-feedback-free?
                '((load r (controller assist-work-per-byte))
                  (mul  w size r))))
          (not (assist-feedback-free?
                '((load s (thread scan-work))
                  (load d (thread heap-distance))
                  (div  r s d)
                  (mul  w size r))))
          (not (assist-constant-rate? '((mul w size rate))))))

(ck! "and the assist contains no poll, yield or safepoint: D21 holds here too"
     (poll-free? (assist-mnemonics)))

;; --- the ledger, wired to allocation --------------------------------------

(ck! "a fresh heap starts at the grant, and each allocation debits its own word
       count times the rate -- header included, because the header is a word
       the collector will copy"
     (let ((h (fresh-heap)))
       (and (= assist-grant (gc-assist-credit h))
            (begin (gc-alloc! h (tagged-hdr 'pair 3) '())
                   (= (- assist-grant (assist-charge 4)) (gc-assist-credit h)))
            (begin (gc-alloc! h (tagged-hdr 'box 1) '())
                   (= (- assist-grant (assist-charge 4) (assist-charge 2))
                      (gc-assist-credit h))))))

(ck! "the debt is REPORTED, not acted on. Our collector stops the world, so
       there is no concurrent marking a mutator in debt could go and do; what
       is fixed now is the accounting an incremental collector will consume"
     (let ((h (fresh-heap)))
       (and (not (gc-assist-due? h))
            (begin (gc-assist-debit! h (+ 1 (div assist-grant assist-work-per-word)))
                   (gc-assist-due? h)))))

;; --- the discriminating test: two histories, one rate ----------------------
;;
;; Run the same allocation sequence twice, once dropping everything and once
;; keeping a live set in the value registers so every collection promotes. The
;; two runs differ in collection count and in how much old space they fill,
;; which is precisely the input a pacer feeds back on. Sample the marginal
;; charge for a fixed size all the way through both.

(define (assist-run live? iters)
  (let* ((h (make-gc-heap 96 8 2048))
         (rf (regs-with '()))
         (st (state-with (list (word-fixnum 0)) (one-frame '(#f)) rf))
         (ncoll 0) (rates '()) (grants '()))
    ;; The state thunk is called once per collection, so it doubles as the
    ;; collection counter without the collector knowing it is being watched.
    (gc-install! h (lambda () (set! ncoll (+ ncoll 1)) st))
    (let loop ((i 0))
      (when (< i iters)
        (let* ((c0 ncoll)
               (before (gc-assist-credit h))
               (w (gc-alloc! h (tagged-hdr 'pair 3) (list (word-fixnum i))))
               (after (gc-assist-credit h)))
          (when live? (vector-set! (regfile-value rf) (mod i 8) w))
          (if (= c0 ncoll)
              ;; No collection intervened: the difference IS the marginal
              ;; charge for a four-word object.
              (set! rates (cons (- before after) rates))
              ;; A collection intervened, so the credit was reset and then
              ;; debited. Undo the debit and what is left is the grant.
              (set! grants (cons (+ after (assist-charge 4)) grants)))
          (loop (+ i 1)))))
    (list (reverse rates) (reverse grants) ncoll (gc-old-used h))))

(define dead (assist-run #f 100))
(define live (assist-run #t 100))

(define (all-equal? xs v) (for-all (lambda (x) (= x v)) xs))

(ck! "the two runs really did have different histories: both collected several
       times and one filled old space while the other left it empty. Without
       this the rest of this section proves nothing"
     (and (> (caddr dead) 1) (> (caddr live) 1)
          (= 0 (cadddr dead)) (> (cadddr live) 0)))

(ck! "and across both, EVERY marginal charge for a four-word object is the same
       number. Not a mean, not a tolerance: every sample, in a run that copied
       nothing and a run that promoted at every collection"
     (and (> (length (car dead)) 20)
          (> (length (car live)) 20)
          (all-equal? (car dead) (assist-charge 4))
          (all-equal? (car live) (assist-charge 4))))

(ck! "the credit handed back at each collection is the same literal every time
       too. copied, honoured and dropped are all in scope at the line that
       resets it, and none of them reaches the number"
     (and (pair? (cadr dead)) (pair? (cadr live))
          (all-equal? (cadr dead) assist-grant)
          (all-equal? (cadr live) assist-grant)))

;; The control. Without it "all the samples are equal" is a sentence about a
;; multiplication, not about a design.
(define (pacer-rates)
  ;; Go's shape: outstanding scan work over remaining heap distance, revised as
  ;; the interval runs, times the size. Same size every step.
  (let loop ((i 0) (scan 400) (dist 88) (acc '()))
    (if (>= i 20)
        (reverse acc)
        (loop (+ i 1) (- scan 4) (- dist 4)
              (cons (* 4 (div scan (max dist 1))) acc)))))

(ck! "the control: a pacer charged for the SAME size at every step returns a
       different number as it runs, so the equality assertions above are
       assertions rather than restatements of arithmetic"
     (not (all-equal? (pacer-rates) (car (pacer-rates)))))

(newline)
(printf "~a checks, ~a failures\n" checks failures)
(if (> failures 0) (exit 1) (begin (printf "PASS\n") (exit 0)))
