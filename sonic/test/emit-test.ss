(import (chezscheme) (sonic emit) (sonic gcmeta))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

;; --- bytes and metadata cannot be separated -------------------------------
(define e (make-emitter target-rv64 '(#t #f #t)))
(emit! e '(#x13 #x00 #x00 #x00) '((frame? . 1)))
(ck! "emitting advances the offset by the byte count" (= (emitter-offset e) 4))
(ck! "and records exactly one entry" (= (length (emitter-entries e)) 1))

;; inherit: raw bytes add no entry, so a multi-byte encoding of ONE logical
;; instruction does not get spurious metadata
(emit-bytes! e '(#xff #xff))
(ck! "emit-bytes! adds no entry: it is part of the previous instruction"
     (= (length (emitter-entries e)) 1))
(ck! "but does advance the offset" (= (emitter-offset e) 6))

;; --- the transient-window case D21 exists for -----------------------------
;; A multi-load calling sequence changes what the collector should believe
;; between each load. An interrupt landing between any two must get a correct
;; map, which means an entry after each.
(define m (make-emitter target-rv64 '(#f)))
(emit! m '(1) '((scratch-live . 1)))
(emit! m '(2) '((scratch-live . 3)))
(emit! m '(3) '((scratch-live . 7)))
(ck! "each step of a multi-load sequence gets its own entry"
     (= (length (emitter-entries m)) 3))
(let* ([f (finish-function m 'seq)]
       [back (decode-metadata target-rv64 (function-metadata f))])
  (ck! "and all three survive the encoder: the answer changes at each"
       (= (length back) 3))
  (ck! "an interrupt at offset 1 sees scratch-live 3, not 1 or 7"
       (= (cdr (assq 'scratch-live (entry-flags (metadata-lookup back 1)))) 3)))

;; --- a run of identical instructions collapses ----------------------------
;; This is the tight-loop property: emit verbosely, let the encoder decide.
(define l (make-emitter target-rv64 '(#f #f)))
(let loop ([i 0]) (when (< i 100) (emit! l '(0 0 0 0) '((frame? . 1))) (loop (+ i 1))))
(let* ([f (finish-function l 'hot)]
       [back (decode-metadata target-rv64 (function-metadata f))])
  (ck! "100 emitted entries in a call-free run collapse to 1" (= (length back) 1))
  (ck! "the code is still 400 bytes" (= (bytevector-length (function-code f)) 400))
  (ck! "metadata is under 2% of code size"
       (< (bytevector-length (function-metadata f))
          (* 0.02 (bytevector-length (function-code f))))))

;; --- state persists until changed -----------------------------------------
(define s (make-emitter target-rv64 '(#t)))
(set-state! s '((ra-live? . 1)))
(emit! s '(1))
(emit! s '(2))
(ck! "state persists across instructions that do not restate it"
     (let ([es (reverse (emitter-entries s))])
       (equal? (entry-flags (car es)) (entry-flags (cadr es)))))

;; --- a non-byte is refused ------------------------------------------------
(set! checks (+ checks 1))
(let ([caught #f])
  (guard (ex (#t (set! caught #t))) (emit-bytes! (make-emitter target-rv64 '()) '(256)))
  (if caught (display "  ok   a value outside 0-255 is refused, not truncated\n")
             (begin (set! failures (+ failures 1))
                    (display "  FAIL out-of-range byte accepted\n"))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
