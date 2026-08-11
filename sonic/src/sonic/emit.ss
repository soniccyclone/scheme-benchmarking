;;; Metadata emission threaded through codegen, and the assembled function.
;;;
;;; E2-META. This is the pervasive half of D21 and the reason it could not be
;;; deferred: **every** backend instruction emits or inherits a metadata entry.
;;; Emacs is what deferring costs, 1842 primitives to audit and it never
;;; happened.
;;;
;;; ## The shape
;;;
;;; An emitter accumulates two parallel streams: machine code bytes, and
;;; metadata entries keyed by the byte offset at which each instruction starts.
;;; `emit!` takes both, so there is no way to add an instruction without
;;; stating what the collector should believe at it. That is the point: a
;;; metadata argument that could be omitted would be omitted.
;;;
;;; The encoder in sonic/src/sonic/gcmeta.ss then drops entries identical to
;;; their predecessor, so the emitted stream can be maximally verbose and the
;;; stored table is still a step function over calling-convention transitions.
;;; Emit an entry per instruction; let the encoder decide what is worth keeping.

(library (sonic emit)
  (export make-emitter emitter? emitter-target
          emit! emit-bytes! current-state set-state!
          emitter-code emitter-entries emitter-offset
          emitter-frame-bits emitter-frame-bits-set!
          finish-function
          make-function function? function-name function-code
          function-metadata function-frame-slots)
  (import (chezscheme)
          (sonic gcmeta))

  (define-record-type (emitter mk-emitter emitter?)
    (fields target
            (mutable code)        ; reversed list of bytes
            (mutable offset)
            (mutable entries)     ; reversed list of entry
            (mutable state)       ; current flags alist
            (mutable frame-bits)))

  (define (make-emitter target frame-bits)
    (mk-emitter target '() 0 '() '() frame-bits))

  (define (current-state e) (emitter-state e))

  ;; Change what the collector should believe from here on. The next `emit!`
  ;; picks it up. Used for the transient windows: a multi-load calling sequence
  ;; sets state after each load, so an interrupt between any two of them still
  ;; gets a correct map.
  (define (set-state! e flags) (emitter-state-set! e flags))

  ;; THE entry point. Bytes and metadata together, never separately.
  (define (emit! e bytes . maybe-flags)
    (let ((flags (if (null? maybe-flags) (emitter-state e) (car maybe-flags))))
      (unless (null? maybe-flags) (emitter-state-set! e flags))
      (emitter-entries-set! e
        (cons (make-entry (emitter-offset e) flags (emitter-frame-bits e))
              (emitter-entries e)))
      (emit-bytes! e bytes)))

  ;; Raw bytes with NO new entry: the instruction inherits the state of the one
  ;; before it. For multi-byte encodings of a single logical instruction.
  (define (emit-bytes! e bytes)
    (for-each (lambda (b)
                (unless (and (integer? b) (<= 0 b 255))
                  (error 'emit-bytes! "not a byte" b))
                (emitter-code-set! e (cons b (emitter-code e))))
              bytes)
    (emitter-offset-set! e (+ (emitter-offset e) (length bytes))))

  (define-record-type (function make-function function?)
    (fields name code metadata frame-slots))

  ;; Assemble: bytes to a bytevector, entries through the encoder. The metadata
  ;; blob is appended after the code, and its size is what the decoder uses to
  ;; find it by arithmetic on the function header.
  (define (finish-function e name)
    (let* ((bytes (reverse (emitter-code e)))
           (entries (reverse (emitter-entries e)))
           (blob (encode-metadata (emitter-target e) entries)))
      (make-function name
                     (u8-list->bytevector bytes)
                     blob
                     (length (emitter-frame-bits e)))))
  )
