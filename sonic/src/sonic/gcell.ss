;;; Global cells: redefinition and sealing.
;;;
;;; E1-REDEF. The model of what a global reference compiles to, and the one
;;; place where a RISC-V hardware fact reaches up and changes language
;;; semantics.
;;;
;;; ## Why redefinition is a pointer store and never a patched branch
;;;
;;; The obvious fast implementation of `(define (f x) ...)` followed by a call
;;; to `f` is to emit a direct call and patch the branch target when `f` is
;;; redefined. That is what several systems do on x86-64 and it is unsound on
;;; RISC-V:
;;;
;;;   - `FENCE.I` is OPTIONAL (extension Zifencei) and, where present, is
;;;     LOCAL-HART ONLY.
;;;   - So making a modified instruction visible to another hart needs a data
;;;     fence plus an IPI to every remote hart, coordinated.
;;;
;;; A data store needs none of that: the coherence protocol already handles it.
;;; Mezzano's own arm64 port declines patching for the same reason, with both
;;; activation functions literal no-ops, and its x86-64 patching path carries
;;; three FIXMEs for locking, fences and cross-CPU.
;;;
;;; So: a global reference is an indirect load from a cell, and redefinition is
;;; a single store into that cell. One instruction, no fences, no IPI, correct
;;; on every hart.
;;;
;;; ## Why the seal bit lives in the same cell
;;;
;;; Indirection costs a load on every call, and the way to get it back is
;;; inlining. But inlining through a global reference is only sound if the
;;; global cannot be redefined afterwards — otherwise the inlined body is a
;;; stale copy and the redefinition silently does nothing at that site.
;;;
;;; SEALED means exactly "this binding will not be redefined, so the compiler
;;; may inline through it." Putting the bit in the cell rather than in a side
;;; table means the check is on the datum the compiler already has in hand.
;;;
;;; Sealing is one-way. Unsealing would invalidate code already inlined, and
;;; recovering from that needs the code-patching machinery this design exists to
;;; avoid.

(library (sonic gcell)
  (export make-gcell gcell? gcell-name gcell-value gcell-sealed?
          gcell-set! gcell-seal! gcell-ref
          gcell-inlinable?
          make-genv genv-define! genv-lookup genv-seal! genv-names
          &redefinition-of-sealed make-redefinition-error redefinition-error?)
  (import (rnrs base)
          (rnrs lists)
          (rnrs control)
          (rnrs records syntactic)
          (rnrs conditions)
          (rnrs exceptions)
          (rnrs hashtables))

  (define-condition-type &redefinition-of-sealed &error
    make-redefinition-error redefinition-error?
    (cell redefinition-error-cell))

  ;; A cell is mutable state, deliberately: it IS the thing the store writes to.
  ;; `value` and `sealed?` are the two fields the emitted code cares about, and
  ;; a real backend lays them out adjacently so the seal test is a load at a
  ;; constant offset from the pointer it already has.
  (define-record-type (gcell mk-gcell gcell?)
    (fields name (mutable value) (mutable sealed?)))

  (define (make-gcell name value) (mk-gcell name value #f))

  ;; The emitted form of a global reference: one indirect load. Named as an
  ;; operation rather than left as field access so the lowering has something
  ;; to match on.
  (define (gcell-ref c) (gcell-value c))

  ;; The emitted form of a redefinition: one store. No fence, no IPI.
  (define (gcell-set! c v)
    (when (gcell-sealed? c)
      (raise (make-redefinition-error c)))
    (gcell-value-set! c v))

  ;; One-way. See the header for why there is no unseal.
  (define (gcell-seal! c) (gcell-sealed?-set! c #t))

  ;; The question the inliner asks. It is deliberately the ONLY thing that
  ;; licenses inlining through a global: an unsealed cell may change under a
  ;; site that has already been specialised to its current value.
  (define (gcell-inlinable? c) (gcell-sealed? c))

  ;; --- global environment ---------------------------------------------------

  (define (make-genv) (make-eq-hashtable))

  (define (genv-define! env name value)
    (let ((existing (hashtable-ref env name #f)))
      (if existing
          (begin (gcell-set! existing value) existing)   ; raises if sealed
          (let ((c (make-gcell name value)))
            (hashtable-set! env name c)
            c))))

  (define (genv-lookup env name) (hashtable-ref env name #f))

  (define (genv-seal! env name)
    (let ((c (hashtable-ref env name #f)))
      (if c (begin (gcell-seal! c) c) (error 'genv-seal! "no such global" name))))

  (define (genv-names env)
    (vector->list (hashtable-keys env)))
  )
