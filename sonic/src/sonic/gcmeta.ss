;;; PC-total GC metadata: encoder, decoder, lookup.
;;;
;;; E1-GCENC. Implements the format specified in sonic/doc/gc-metadata.md, per
;;; decision D21.
;;;
;;; The one idea worth holding on to: this is a STEP FUNCTION, not a table of
;;; safepoints. Every byte offset in every function has a defined answer to
;;; "which stack slots hold tagged values here", obtained by taking the last
;;; entry at or before that offset. The compiler emits an entry before every
;;; backend instruction and the encoder DROPS any entry identical to its
;;; predecessor, so what is stored has an entry only where the answer changes.
;;;
;;; That is why the space cost is O(calling-convention transitions) rather than
;;; O(instructions), which is the same order as a conventional safepoint table
;;; even though this is total over the PC. And it is why a tight numeric loop
;;; with no calls stores approximately one entry: nothing changes across it.
;;;
;;; There is no register bitmap anywhere in here. The register partition
;;; (sonic/doc/register-partition.md) makes the value class a fixed list the
;;; collector scavenges unconditionally, which is the other half of why this is
;;; affordable.

(library (sonic gcmeta)
  (export make-entry entry? entry-offset entry-flags entry-frame-bits
          make-target target? target-name target-flag-names
          target-x86-64 target-rv64
          encode-metadata decode-metadata metadata-lookup
          uleb128-encode uleb128-decode sleb128-encode sleb128-decode
          bits->bytevector bytevector->bits)
  (import (rnrs base)
          (rnrs lists)
          (rnrs control)
          (rnrs arithmetic bitwise)
          (rnrs bytevectors)
          (rnrs records syntactic)
          (rnrs io simple))

  ;; --- varints --------------------------------------------------------------
  ;; LEB128. Unsigned for offsets and lengths, signed for pushed-values counts,
  ;; which can go negative when the convention pops below the frame.

  (define (uleb128-encode n)
    (let loop ((n n) (acc '()))
      (let ((b (bitwise-and n #x7f)) (rest (bitwise-arithmetic-shift-right n 7)))
        (if (zero? rest)
            (reverse (cons b acc))
            (loop rest (cons (bitwise-ior b #x80) acc))))))

  (define (uleb128-decode bv i)
    (let loop ((i i) (shift 0) (acc 0))
      (let ((b (bytevector-u8-ref bv i)))
        (let ((acc (bitwise-ior acc (bitwise-arithmetic-shift-left (bitwise-and b #x7f) shift))))
          (if (zero? (bitwise-and b #x80))
              (values acc (+ i 1))
              (loop (+ i 1) (+ shift 7) acc))))))

  (define (sleb128-encode n)
    (let loop ((n n) (acc '()))
      (let ((b (bitwise-and n #x7f))
            (rest (bitwise-arithmetic-shift-right n 7)))
        (if (or (and (zero? rest) (zero? (bitwise-and b #x40)))
                (and (= rest -1) (not (zero? (bitwise-and b #x40)))))
            (reverse (cons b acc))
            (loop rest (cons (bitwise-ior b #x80) acc))))))

  (define (sleb128-decode bv i)
    (let loop ((i i) (shift 0) (acc 0))
      (let ((b (bytevector-u8-ref bv i)))
        (let ((acc (bitwise-ior acc (bitwise-arithmetic-shift-left (bitwise-and b #x7f) shift)))
              (shift (+ shift 7)))
          (if (zero? (bitwise-and b #x80))
              (values (if (and (< shift 64) (not (zero? (bitwise-and b #x40))))
                          (bitwise-ior acc (bitwise-arithmetic-shift-left -1 shift))
                          acc)
                      (+ i 1))
              (loop (+ i 1) shift acc))))))

  ;; --- frame bitvectors -----------------------------------------------------
  ;; One bit per stack slot, set if the slot holds a tagged value. Represented
  ;; as a list of booleans in the API and packed LSB-first on the wire.

  (define (bits->bytevector bits)
    (let* ((n (length bits))
           (nbytes (div (+ n 7) 8))
           (bv (make-bytevector nbytes 0)))
      (let loop ((bs bits) (i 0))
        (if (null? bs)
            bv
            (begin
              (when (car bs)
                (let ((byte (div i 8)) (bit (mod i 8)))
                  (bytevector-u8-set! bv byte
                    (bitwise-ior (bytevector-u8-ref bv byte)
                                 (bitwise-arithmetic-shift-left 1 bit)))))
              (loop (cdr bs) (+ i 1)))))))

  (define (bytevector->bits bv start n)
    (let loop ((i 0) (acc '()))
      (if (= i n)
          (reverse acc)
          (let ((byte (bytevector-u8-ref bv (+ start (div i 8))))
                (bit (mod i 8)))
            (loop (+ i 1)
                  (cons (not (zero? (bitwise-and byte (bitwise-arithmetic-shift-left 1 bit))))
                        acc))))))

  ;; --- targets --------------------------------------------------------------
  ;; The flag NAMES differ per target and that is the whole point of
  ;; gc-metadata.md. There is no shared enum: `scratch-live` is a 2-bit strict
  ;; nesting on x86-64 and a 3-bit bitmap on RV64, and RV64 carries `ra-live?`
  ;; and `vl-live?` which x86-64 has no counterpart for.
  ;;
  ;; A target is a name plus an ordered list of (flag-name . width-in-bits).
  ;; Encoding packs them LSB-first in that order.

  (define-record-type (target make-target target?)
    (fields name flag-names))

  (define target-x86-64
    (make-target 'x86-64
      '((frame? . 1) (interrupt? . 1) (restart? . 1) (scratch-live . 2))))

  (define target-rv64
    (make-target 'rv64
      '((frame? . 1) (interrupt? . 1) (restart? . 1)
        (ra-live? . 1) (vl-live? . 1) (scratch-live . 3))))

  (define (target-flag-width t)
    (fold-left + 0 (map cdr (target-flag-names t))))

  (define (pack-flags t alist)
    (let loop ((fs (target-flag-names t)) (shift 0) (acc 0))
      (if (null? fs)
          acc
          (let* ((name (caar fs)) (w (cdar fs))
                 (p (assq name alist))
                 (v (if p (cdr p) 0))
                 (v (if (eq? v #t) 1 (if (eq? v #f) 0 v))))
            (when (>= v (expt 2 w))
              (error 'pack-flags "value too wide for field" name v w))
            (loop (cdr fs) (+ shift w)
                  (bitwise-ior acc (bitwise-arithmetic-shift-left v shift)))))))

  (define (unpack-flags t packed)
    (let loop ((fs (target-flag-names t)) (shift 0) (acc '()))
      (if (null? fs)
          (reverse acc)
          (let* ((name (caar fs)) (w (cdar fs))
                 (v (bitwise-and (bitwise-arithmetic-shift-right packed shift)
                                 (- (expt 2 w) 1))))
            (loop (cdr fs) (+ shift w) (cons (cons name v) acc))))))

  ;; --- entries --------------------------------------------------------------

  (define-record-type (entry make-entry entry?)
    (fields offset flags frame-bits))

  (define (entry-same? a b)
    ;; Offsets deliberately excluded: two entries at different PCs with the same
    ;; content ARE the same answer, and dropping the second is the dedupe that
    ;; makes this a step function.
    (and (equal? (entry-flags a) (entry-flags b))
         (equal? (entry-frame-bits a) (entry-frame-bits b))))

  ;; --- encode / decode ------------------------------------------------------

  (define (encode-metadata t entries)
    ;; entries must be sorted by offset. Adjacent duplicates are dropped.
    (let* ((deduped
            (let loop ((es entries) (prev #f) (acc '()))
              (cond ((null? es) (reverse acc))
                    ((and prev (entry-same? (car es) prev)) (loop (cdr es) prev acc))
                    (else (loop (cdr es) (car es) (cons (car es) acc))))))
           (bytes '()))
      (let loop ((es deduped) (prev-off 0) (out '()))
        (if (null? es)
            (u8-list->bytevector (reverse out))
            (let* ((e (car es))
                   (delta (- (entry-offset e) prev-off))
                   (bits (entry-frame-bits e))
                   (nbits (length bits))
                   (packed (bits->bytevector bits))
                   (chunk (append (uleb128-encode delta)
                                  (uleb128-encode (pack-flags t (entry-flags e)))
                                  (uleb128-encode nbits)
                                  (bytevector->u8-list packed))))
              (loop (cdr es) (entry-offset e) (append (reverse chunk) out)))))))

  (define (decode-metadata t bv)
    (let loop ((i 0) (off 0) (acc '()))
      (if (>= i (bytevector-length bv))
          (reverse acc)
          (let*-values (((delta i) (uleb128-decode bv i))
                        ((packed i) (uleb128-decode bv i))
                        ((nbits i) (uleb128-decode bv i)))
            (let* ((nbytes (div (+ nbits 7) 8))
                   (bits (bytevector->bits bv i nbits))
                   (off (+ off delta)))
              (loop (+ i nbytes) off
                    (cons (make-entry off (unpack-flags t packed) bits) acc)))))))

  ;; THE query that makes the metadata total: any offset, not just the ones
  ;; with entries. Returns the last entry at or before `off`, or #f if the
  ;; offset precedes the first entry.
  (define (metadata-lookup entries off)
    (let loop ((es entries) (best #f))
      (cond ((null? es) best)
            ((> (entry-offset (car es)) off) best)
            (else (loop (cdr es) (car es))))))
  )
