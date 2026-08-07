;;; The literal pool.
;;;
;;; The load-bearing case is the one that looks like a rounding error: 0.0 and
;;; -0.0 are two slots. Everything else here is bookkeeping that has to be right
;;; for the two back ends to reach a constant at all.

(import (chezscheme)
        (sonic litpool)
        (sonic emit)
        (sonic gcmeta)
        (sonic numeric))

(define failures 0)
(define checks 0)

(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok
      (printf "  ok   ~a\n" name)
      (begin (set! failures (+ failures 1))
             (printf "  FAIL ~a\n" name))))

(printf "literal pool:\n")

;; --- dedupe ----------------------------------------------------------------

(let ((p (make-pool)))
  (let ((a (pool-intern-f64! p 0.5))
        (b (pool-intern-f64! p 0.5))
        (c (pool-intern-f64! p 0.5)))
    (ck! "the same constant interned three times is ONE slot at ONE offset"
         (and (= a b) (= b c) (= 1 (length (pool-entries p))) (= 8 (pool-size p)))))
  (let ((d (pool-intern-f64! p 0.25)))
    (ck! "a different constant gets a different slot"
         (and (not (= d 0)) (= 2 (length (pool-entries p)))))))

;; --- THE one that matters --------------------------------------------------
;;
;; SPEC.md step 0: ref.c writes -px, and (fl- 0.0 px) is a different function.
;; If the pool folded these two the difference would come back at the last
;; possible moment, as two bytes in an image nobody reads.

(let* ((p (make-pool))
       (zero (pool-intern-f64! p 0.0))
       (nzero (pool-intern-f64! p -0.0)))
  (ck! "0.0 and -0.0 are SEPARATE slots: they are different bit patterns and
       bench/nbody/SPEC.md step 0 records why the sign survives"
       (not (= zero nzero)))
  (let ((bv (pool-bytes p)))
    (ck! "and each slot holds its own sign bit, read back from the BYTES"
         (and (= 0 (pool-ref-u64 bv zero))
              (= #x8000000000000000 (pool-ref-u64 bv nzero))
              (not (fl-negative-zero? (pool-ref-f64 bv zero)))
              (fl-negative-zero? (pool-ref-f64 bv nzero)))))
  (ck! "re-interning each of them still hits its own slot and adds nothing"
       (and (= zero (pool-intern-f64! p 0.0))
            (= nzero (pool-intern-f64! p -0.0))
            (= 2 (length (pool-entries p))))))

;; NaN is not `=` to itself, so a key based on numeric equality would emit a
;; fresh slot every time it saw one. Bits make it behave like every other
;; constant.
(let* ((p (make-pool))
       (a (pool-intern-f64! p +nan.0))
       (b (pool-intern-f64! p +nan.0)))
  (ck! "NaN interns with itself, which numeric equality could never do"
       (and (= a b) (= 1 (length (pool-entries p))))))

;; A fixnum and a flonum of the same value are different constants and the kind
;; is part of the key, so they cannot collide.
(let ((p (make-pool)))
  (ck! "1 and 1.0 do not share a slot"
       (not (= (pool-intern-i64! p 1) (pool-intern-f64! p 1.0)))))

(let ((p (make-pool)))
  (ck! "a negative fixnum and the unsigned word with the same bits DO share a
       slot, because they are the same eight bytes"
       (= (pool-intern-i64! p -1) (pool-intern-i64! p #xffffffffffffffff))))

;; --- offsets resolve to the right bytes ------------------------------------

(let* ((p (make-pool))
       (offs (map (lambda (x) (cons x (pool-intern-f64! p x)))
                  '(1.0 2.0 -0.0 0.0 3.5 -1.5)))
       (bv (pool-bytes p)))
  (ck! "every offset resolves to the constant that was interned there"
       (for-all (lambda (pr)
                  (fl-identical? (car pr) (pool-ref-f64 bv (cdr pr))))
                offs))
  (ck! "and no two of them landed on the same offset"
       (let loop ((os (map cdr offs)))
         (cond ((null? os) #t)
               ((memv (car os) (cdr os)) #f)
               (else (loop (cdr os)))))))

;; --- alignment is a correctness property -----------------------------------
;;
;; andpd against a misaligned m128 faults. The offsets are asserted exactly
;; rather than merely tested for divisibility, because "aligned" is satisfied by
;; layouts that waste half the pool.

(let* ((p (make-pool))
       (a (pool-intern-f64! p 1.0))          ; 8 bytes at 0
       (m (pool-intern-sign-mask! p 'abs))   ; needs 16: skips to 16
       (b (pool-intern-f64! p 2.0))          ; 8 bytes at 32
       (n (pool-intern-sign-mask! p 'neg)))  ; needs 16: skips to 48
  (ck! "an f64 takes eight bytes and a sign mask takes sixteen, aligned to
       sixteen, and the pad between them is deterministic"
       (and (= a 0) (= m 16) (= b 32) (= n 48)))
  (ck! "the pool is exactly the bytes it uses, with no tail pad"
       (= 64 (pool-size p)))
  (let ((bv (pool-bytes p)))
    (ck! "the abs mask is the same 64-bit pattern in BOTH lanes: the operand of
       andpd is 128 bits wide"
         (and (= abs-mask-bits (pool-ref-u64 bv m))
              (= abs-mask-bits (pool-ref-u64 bv (+ m 8)))))
    (ck! "and the neg mask is the sign bit alone, in both lanes"
         (and (= neg-mask-bits (pool-ref-u64 bv n))
              (= neg-mask-bits (pool-ref-u64 bv (+ n 8)))))
    (ck! "the padding is zero, not whatever was in the buffer: two builds of
       one function must produce identical images"
         (let loop ((i 8))
           (cond ((= i 16) #t)
                 ((zero? (bytevector-u8-ref bv i)) (loop (+ i 1)))
                 (else #f))))))

(let ((p (make-pool)))
  (pool-intern-sign-mask! p 'abs)
  (pool-intern-sign-mask! p 'abs)
  (ck! "two flabs sites in one function share one mask"
       (= 1 (length (pool-entries p)))))

;; --- the pool sits between code and metadata -------------------------------

(define (emitter-with-code n)
  (let ((e (make-emitter target-x86-64 '(#t #f #t))))
    (let loop ((i 0))
      (when (< i n)
        (emit! e (list (bitwise-and i 255)) `((frame? . 1) (scratch-live . ,(mod i 3))))
        (loop (+ i 1))))
    e))

(let* ((e (emitter-with-code 21))
       (p (make-pool)))
  (pool-intern-f64! p 0.0)
  (pool-intern-f64! p -0.0)
  (pool-intern-sign-mask! p 'neg)
  (let* ((lo (layout-function e 'f p))
         (img (laid-out-image lo)))
    (ck! "code first, at offset zero, because the function's entry point is its
       base address and every caller already knows that"
         (and (= 0 (laid-out-code-offset lo)) (= 21 (laid-out-code-size lo))))
    (ck! "the pool comes AFTER the code and is 16-byte aligned, which is why it
       starts at 32 rather than at 21"
         (and (> (laid-out-pool-offset lo) (laid-out-code-size lo))
              (= 32 (laid-out-pool-offset lo))
              (zero? (mod (laid-out-pool-offset lo) 16))))
    (ck! "and the metadata comes after the POOL, not after the code: the blob is
       variable-length LEB128, so a pool behind it would move whenever one flag
       bit changed"
         (= (laid-out-metadata-offset lo)
            (+ (laid-out-pool-offset lo) (laid-out-pool-size lo))))
    (ck! "the three pieces exactly tile the image with no gap and no overlap"
         (= (bytevector-length img)
            (+ (laid-out-metadata-offset lo) (laid-out-metadata-size lo))))
    (ck! "the code bytes in the image are the bytes the emitter produced"
         (let loop ((i 0))
           (cond ((= i 21) #t)
                 ((= (bytevector-u8-ref img i) (bitwise-and i 255)) (loop (+ i 1)))
                 (else #f))))
    (ck! "a pool offset read out of the ASSEMBLED IMAGE, not out of the pool
       bytevector, still yields the constant"
         (let ((base (laid-out-pool-offset lo)))
           (and (= 0 (pool-ref-u64 img (+ base 0)))
                (= #x8000000000000000 (pool-ref-u64 img (+ base 8)))
                (= neg-mask-bits (pool-ref-u64 img (+ base 16))))))
    (ck! "the metadata in the image decodes to the entries that were emitted"
         (let* ((msize (laid-out-metadata-size lo))
                (blob (make-bytevector msize 0)))
           (bytevector-copy! img (laid-out-metadata-offset lo) blob 0 msize)
           (let ((es (decode-metadata target-x86-64 blob)))
             (and (pair? es)
                  ;; scratch-live cycles 0 1 2, so the encoder's dedupe keeps
                  ;; every entry and the step function has 21 steps.
                  (= 21 (length es))
                  (= 0 (entry-offset (car es)))))))
    (ck! "and the frame slot count survives the layout"
         (= 3 (laid-out-frame-slots lo)))))

;; A function with no constants pays for the alignment pad and nothing else.
(let* ((e (emitter-with-code 16))
       (lo (layout-function e 'g (make-pool))))
  (ck! "an empty pool is zero bytes, so the layout degenerates to today's
       code-then-metadata"
       (and (= 0 (laid-out-pool-size lo))
            (= 16 (laid-out-pool-offset lo))
            (= 16 (laid-out-metadata-offset lo)))))

;; --- addressing ------------------------------------------------------------

(let* ((e (emitter-with-code 21))
       (p (make-pool))
       (off (pool-intern-f64! p 0.5))
       (lo (layout-function e 'h p)))
  (ck! "an entry's absolute address is the load address plus the pool offset
       plus the entry offset"
       (= (pool-entry-address lo #x400000 off)
          (+ #x400000 (laid-out-pool-offset lo) off)))
  ;; A movsd xmm0, [rip+disp32] at offset 4 is 8 bytes long, so RIP is 12.
  (ck! "a RIP-relative displacement is measured from the END of the instruction
       that carries it, not from its start"
       (= (rip-displacement lo off 12)
          (- (+ (laid-out-pool-offset lo) off) 12))))

;; --- the closed kind list --------------------------------------------------

(ck! "an unknown kind is an error, not a default width: a wrong width here
       produces a pool that assembles and reads the neighbouring constant"
     (guard (e (#t #t)) (kind-size 'f32) #f))

(ck! "interning a non-flonum as an f64 is refused"
     (guard (e (#t #t)) (pool-intern-f64! (make-pool) 1) #f))

(ck! "a primary tag is three bits and anything wider is refused"
     (and (guard (e (#t #t)) (pool-intern-tag! (make-pool) 8) #f)
          (integer? (pool-intern-tag! (make-pool) 0))))

(newline)
(printf "~a checks, ~a failures\n" checks failures)
(if (> failures 0) (exit 1) (begin (printf "PASS\n") (exit 0)))
