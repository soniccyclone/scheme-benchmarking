;;; Representation conversions: the pass they had nowhere to live.
;;;
;;; ## The gap
;;;
;;; repr.ss could PROVE that two storage classes must merge and nothing could
;;; emit the instructions to get from one to the other. Its join therefore did
;;; one of two things, and both were wrong in different ways: for a
;;; boolean-valued word it raised, refusing programs that are perfectly
;;; ordinary Scheme; for a fixnum-valued word it answered `tagged` silently,
;;; which is worse. A computed fixnum merged with a tagged value stayed an
;;; untagged machine word sitting in the value class, where D21's collector
;;; scavenges it unconditionally. That is memory corruption, not a wrong
;;; number, and nothing downstream would ever look again to notice.
;;;
;;; ## Why the conversion lands at the DEFINITION, not the edge
;;;
;;; The obvious placement is the edge -- convert at the call site for a
;;; parameter, in the predecessor for a phi -- and that is what the note asking
;;; for this pass proposed. It is not what the pass needs to do, because
;;; repr.ss already pushes requirements BACKWARD along all three edge kinds:
;;; call site to argument, phi to operand, procedure result to tail variable.
;;; By the time the fixpoint settles, a value that must be tagged IS classified
;;; tagged everywhere it is named.
;;;
;;; So a mismatch cannot survive on an edge. It survives in exactly one place:
;;; a `let` whose variable was joined up to `tagged` while its initializer
;;; still produces a raw word. One site, one rule, and no need to know anything
;;; about control flow -- which is a much better pass than the one that was
;;; asked for.
;;;
;;; ## The rewrite
;;;
;;;     (let ([x tagged SE]) body)
;;;   =>
;;;     (let ([x.raw raw-word SE])
;;;       (let ([x tagged (retag KIND x.raw)]) body))
;;;
;;; KIND is `fixnum`, `boolean` or `boxed`, and the distinction is the reason repr.ss
;;; tracks which raw words hold 0/1. A fixnum tags by shifting left 3 (fixnum
;;; tag 000); a boolean tags to sonic-false or sonic-true, 7 and 15. Shifting a
;;; boolean gives the FIXNUMS 0 and 1, which is a wrong answer that looks
;;; plausible.
;;;
;;; ## What is deliberately NOT converted
;;;
;;; A LITERAL. `(quote 5)` classified tagged costs nothing: under numeric.ss a
;;; tagged fixnum's machine word is the value shifted left 3, so the constant
;;; is materialised already shifted and the selectors honour that. Inserting a
;;; retag would emit two instructions to compute a constant.
;;;
;;; A LAMBDA, which is not a value this compiler represents at run time.
;;;
;;; ## The third kind: a double is BOXED
;;;
;;; raw-f64 to tagged has no bit pattern that serves -- a double needs all 64
;;; bits -- so the value goes on the heap and the tagged value is a pointer to
;;; it. That is a runtime facility rather than two arithmetic instructions,
;;; which is why it arrived after the other two: `retag boxed` lowers to a call
;;; to `%box-flonum`, and being a call is what makes the allocation visible to
;;; the GC metadata the call site already emits.

(library (sonic convert)
  (export convert-program convert-report convert-report?
          convert-report-inserted convert-report-sites)
  (import (chezscheme))

  (define-record-type (convert-report make-convert-report convert-report?)
    (fields inserted     ; how many retags went in
            sites))      ; ((x . kind) ...), for the report and the tests

  ;; A retag is owed when the variable's class is `tagged` and its initializer
  ;; naturally produces `raw-word`.
  (define (owes-retag? sc natural)
    (and (eq? sc 'tagged) (memq natural '(raw-word raw-f64))))

  ;; Initializers that reach `tagged` for free, or that are not values at all.
  ;;
  ;; A FLONUM LITERAL IS NOT FREE, and this used to say every literal was. The
  ;; reasoning in the header holds only for a fixnum: its tagged machine word is
  ;; the value shifted left 3, so the constant is materialised already shifted
  ;; and costs nothing. A tagged DOUBLE is a pointer to a heap box and has no
  ;; immediate encoding at all, so leaving it alone hands the selector a tagged
  ;; flonum literal it cannot represent -- "only exact integer and flonum
  ;; literals are selectable", raised on the literal itself.
  ;;
  ;; Nothing reached this before. A flonum literal is only ever REQUIRED tagged
  ;; by something that stores Scheme objects, and until `prim-arg-classes`
  ;; declared `(cons tagged tagged)` there was no such requirement a literal
  ;; could land on: `(cons 1.5 2.5)` is the first program to ask.
  (define (free-form? se)
    (and (pair? se)
         (or (eq? (car se) 'lambda)
             (and (eq? (car se) 'quote)
                  (pair? (cdr se))
                  (not (flonum? (cadr se)))))))

  ;; `form` is an Lrepr `top` datum. `classes` is the vreg -> class table lower.ss
  ;; will read, and it is MUTATED here: the raw temporaries this pass introduces
  ;; are new vregs and lowering needs a class for each of them.
  (define (convert-program form classes naturals booleans)
    (unless (and (pair? form) (eq? (car form) 'top))
      (error 'convert-program "not a top-level program" form))
    (let ((n 0) (sites '()) (counter 0))

      (define (fresh x)
        (set! counter (+ counter 1))
        (string->symbol
         (string-append (symbol->string x) ".raw." (number->string counter))))

      (define (walk e)
        (cond
         ((not (pair? e)) e)
         ((eq? (car e) 'quote) e)
         ((eq? (car e) 'let)
          (let* ((b (car (cadr e)))
                 (x (car b))
                 (sc (cadr b))
                 (se (caddr b))
                 (body (walk (caddr e)))
                 (natural (hashtable-ref naturals x #f)))
            (if (and (owes-retag? sc natural) (not (free-form? se)))
                (let* ((raw (fresh x))
                       (kind (cond
                              ;; A double has no bit pattern that serves, so it
                              ;; is BOXED: the conversion is a heap allocation
                              ;; and a call, not two arithmetic instructions.
                              ((eq? natural 'raw-f64) 'boxed)
                              ((hashtable-ref booleans x #f) 'boolean)
                              (else 'fixnum))))
                  (hashtable-set! classes raw natural)
                  (set! n (+ n 1))
                  (set! sites (cons (cons x kind) sites))
                  ;; The initializer is walked in its ORIGINAL position under
                  ;; the raw name; only the binding is split.
                  ;; The temp's class is the initializer's NATURAL class, not
                  ;; raw-word: a boxed double's temp holds a double, and calling
                  ;; it a word puts it in an integer argument register on the
                  ;; way to the boxing routine.
                  (list 'let (list (list raw natural (walk-se se)))
                        (list 'let (list (list x sc (list 'retag kind raw)))
                              body)))
                (list 'let (list (list x sc (walk-se se))) body))))
         (else (map walk e))))

      ;; A SimpleExpr can contain a lambda, whose body is an Expr.
      (define (walk-se se)
        (if (and (pair? se) (eq? (car se) 'lambda))
            (list 'lambda (cadr se) (walk (caddr se)))
            se))

      ;; SEQUENCED, not `(values (walk form) (make-convert-report n ...))`.
      ;; Argument order is unspecified in Scheme and Chez evaluates right to
      ;; left, so the report was built from `n` and `sites` before `walk` had
      ;; run and every program reported zero conversions -- including the ones
      ;; that had just been rewritten correctly.
      (let ((out (walk form)))
        (values out (make-convert-report n (reverse sites))))))
  )
