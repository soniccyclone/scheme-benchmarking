(import (rnrs base) (rnrs lists) (rnrs control) (rnrs io simple)
        (rnrs bytevectors) (sonic gcmeta))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (unless ok (set! failures (+ failures 1)) (display "  FAIL ") (display name) (newline)))
(define (ok! name) (display "  ok   ") (display name) (newline))

;; --- varints, including the signs that hide bugs --------------------------
(for-each
 (lambda (n)
   (let-values ([(v i) (uleb128-decode (u8-list->bytevector (uleb128-encode n)) 0)])
     (ck! (string-append "uleb " (number->string n)) (= v n))))
 '(0 1 127 128 255 16384 1000000))
(for-each
 (lambda (n)
   (let-values ([(v i) (sleb128-decode (u8-list->bytevector (sleb128-encode n)) 0)])
     (ck! (string-append "sleb " (number->string n)) (= v n))))
 '(0 1 -1 63 -64 64 -65 127 -128 1000 -1000 100000 -100000))
(ok! "varints round-trip, both signs")

;; --- frame bitvectors -----------------------------------------------------
(let* ([bits '(#t #f #f #t #f #t #t #t #f #t)]
       [bv (bits->bytevector bits)])
  (ck! "frame bits round-trip" (equal? (bytevector->bits bv 0 (length bits)) bits)))
(ok! "frame bitvector round-trips at a non-byte-multiple width")

;; --- the step function ----------------------------------------------------
(define (mk off flags bits) (make-entry off flags bits))

(let* ([es (list (mk 0  '((frame? . 1)) '(#t #f))
                 (mk 4  '((frame? . 1)) '(#t #f))     ; identical -> dropped
                 (mk 8  '((frame? . 1) (scratch-live . 1)) '(#t #f))
                 (mk 12 '((frame? . 1) (scratch-live . 1)) '(#t #f))  ; dropped
                 (mk 16 '((frame? . 1)) '(#t #t)))]
       [bv (encode-metadata target-x86-64 es)]
       [back (decode-metadata target-x86-64 bv)])
  (ck! "dedupe drops identical adjacent entries" (= (length back) 3))
  (ck! "surviving offsets are 0, 8, 16"
       (equal? (map entry-offset back) '(0 8 16)))
  (ok! "5 emitted entries encode to 3: it is a step function")

  ;; totality: EVERY offset has an answer, not just the ones with entries
  (ck! "lookup at 0"  (= (entry-offset (metadata-lookup back 0)) 0))
  (ck! "lookup at 7 finds the entry at 0" (= (entry-offset (metadata-lookup back 7)) 0))
  (ck! "lookup at 8"  (= (entry-offset (metadata-lookup back 8)) 8))
  (ck! "lookup at 15 finds the entry at 8" (= (entry-offset (metadata-lookup back 15)) 8))
  (ck! "lookup at 9999 finds the last entry" (= (entry-offset (metadata-lookup back 9999)) 16))
  (ok! "lookup is total over the PC, not just at entry points"))

;; --- per-target vocabularies are NOT interchangeable ----------------------
;; This is the property gc-metadata.md exists to enforce.
(let* ([e (list (mk 0 '((frame? . 1) (ra-live? . 1) (vl-live? . 1) (scratch-live . 5)) '(#t)))]
       [bv (encode-metadata target-rv64 e)]
       [back (decode-metadata target-rv64 bv)]
       [flags (entry-flags (car back))])
  (ck! "rv64 carries ra-live?" (assq 'ra-live? flags))
  (ck! "rv64 carries vl-live? for RVV" (assq 'vl-live? flags))
  (ck! "rv64 scratch-live is a 3-bit bitmap, so 5 survives"
       (= (cdr (assq 'scratch-live flags)) 5))
  (ok! "rv64 vocabulary: ra-live?, vl-live?, 3-bit scratch bitmap"))

(ck! "x86-64 has NO ra-live? field"
     (not (assq 'ra-live? (target-flag-names target-x86-64))))
(ck! "x86-64 has NO vl-live? field"
     (not (assq 'vl-live? (target-flag-names target-x86-64))))
(ok! "x86-64 vocabulary omits what it has no counterpart for")

;; x86-64's scratch-live is 2 bits: a value needing 3 must be REFUSED, not
;; silently truncated. Silent truncation here is a lost GC root.
(set! checks (+ checks 1))
(let ([caught #f])
  (guard (e (#t (set! caught #t)))
    (encode-metadata target-x86-64 (list (mk 0 '((scratch-live . 5)) '(#t)))))
  (if caught
      (ok! "a value too wide for its field is REFUSED, not truncated")
      (begin (set! failures (+ failures 1))
             (display "  FAIL wide value silently truncated\n"))))

;; --- the tight-loop claim, measured ---------------------------------------
;; gc-metadata.md claims a call-free numeric loop stores ~one entry because
;; nothing changes across it. That is a claim about this encoder, so test it.
(let* ([loop-entries (map (lambda (i) (mk (* i 4) '((frame? . 1)) '(#f #f #f)))
                          (iota 200))]
       [bv (encode-metadata target-x86-64 loop-entries)]
       [back (decode-metadata target-x86-64 bv)])
  (ck! "200 emitted entries across a loop body collapse to 1" (= (length back) 1))
  (ck! "and cost under 8 bytes" (< (bytevector-length bv) 8))
  (ok! "call-free loop: 200 entries in, 1 stored, under 8 bytes"))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
