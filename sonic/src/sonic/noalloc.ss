;;; SonicScheme: the allocation-free guarantee, checked at compile time.
;;;
;;; CUJ-05. A kernel author writing an interrupt handler or an early-boot path
;;; needs to know a procedure cannot allocate, and needs to know it at compile
;;; time rather than at 3am on real hardware. The freestanding RV64 entry
;;; already STATES that precondition (D215) and cannot check it; this is what
;;; turns the statement into a refusal.
;;;
;;; ## Why it runs on Lmach and not on the source
;;;
;;; Two of the ways a program allocates are invisible in its own text.
;;;
;;; `%box-flonum` is inserted by convert.ss, long after parsing, whenever a
;;; double has to take the `tagged` representation -- a polymorphic parameter
;;; that also receives a heap object forces the join (D31). No amount of reading
;;; the source shows it, and a check that missed it would hand a kernel author a
;;; guarantee that is wrong exactly where flonums meet generic code.
;;;
;;; `%make-vector-tagged` is chosen from the FILL'S CLASS at lowering, so even
;;; the primitive's name in the source does not say which routine runs.
;;;
;;; On Lmach both are ordinary `call` instructions to named labels, and so is
;;; every other allocation. The check becomes "does any reachable block call one
;;; of these six labels", which is a graph walk with no analysis in it at all.
;;;
;;; ## Why it runs BEFORE cse and dce
;;;
;;; Because it must not depend on them. DCE would remove an allocation whose
;;; result is unused, which would make the guarantee depend on whether the
;;; program happened to use the object -- and a later change to DCE would then
;;; silently widen what this promises. Checking the unoptimised graph makes the
;;; answer a property of the program.
;;;
;;; ## What it does not cover, stated rather than discovered
;;;
;;; The stack. A deeply recursive allocation-free procedure still grows the
;;; frame, and on a kernel stack that is just as fatal. Bounding stack depth is
;;; a different analysis and this one does not pretend to it.

(library (sonic noalloc)
  (export check-no-allocation allocating-labels no-allocation-names)
  (import (chezscheme))

  ;; EVERY ROUTINE THAT BUMPS THE HEAP POINTER, and the list is the whole
  ;; correctness argument. runtime.ss is the source of truth: these are exactly
  ;; the labels whose bodies read and write `heap-pointer-cell`.
  ;;
  ;; A missing entry is a WRONG ANSWER rather than a missed optimisation --
  ;; unlike dce.ss's `pure-ops`, where an absent name costs instructions and
  ;; never correctness. That asymmetry is why this list is checked against the
  ;; runtime in noalloc-test.ss rather than trusted.
  (define allocating-labels
    '(%make-vector %make-vector-tagged %make-flvector %make-bytevector
      %cons %box-flonum))

  ;; The procedures the program declared allocation-free, by source name.
  (define no-allocation-names (make-parameter '()))

  (define (block-label b) (car b))
  (define (block-instrs b) (cadr (cadr b)))
  (define (block-transfer b) (caddr (cadr b)))

  ;; Every label an instruction or transfer could hand control to. Deliberately
  ;; over-broad: any symbol operand that names a block is followed. Following
  ;; something that is not a call costs a walk; missing a call that is one would
  ;; let an allocation hide one level down.
  (define (targets-of x labels)
    (let loop ((x x) (acc '()))
      (cond
       ((and (symbol? x) (memq x labels)) (cons x acc))
       ((pair? x) (loop (car x) (loop (cdr x) acc)))
       (else acc))))

  ;; Which allocator a single instruction calls, or #f.
  (define (allocator-called i)
    (and (pair? i)
         (eq? (car i) 'call)
         (let scan ((x (cdr i)))
           (cond ((null? x) #f)
                 ((memq (car x) allocating-labels) (car x))
                 (else (scan (cdr x)))))))

  ;; Walk from `start`, reporting the first allocation reached and the chain of
  ;; block names that leads to it. Depth-first, with a visited set, so a
  ;; recursive procedure terminates.
  (define (find-allocation blocks start)
    (let ((labels (map block-label blocks))
          (seen (make-eq-hashtable)))
      (let walk ((lbl start) (path '()))
        (cond
         ((hashtable-ref seen lbl #f) #f)
         (else
          (hashtable-set! seen lbl #t)
          (let ((b (assq lbl blocks)))
            (and b
                 (let ((here (let scan ((is (block-instrs b)))
                               (cond ((null? is) #f)
                                     ((allocator-called (car is))
                                      => (lambda (r) r))
                                     (else (scan (cdr is)))))))
                   (if here
                       (cons here (reverse (cons lbl path)))
                       (let next ((ts (targets-of (list (block-instrs b)
                                                        (block-transfer b))
                                                  labels)))
                         (cond ((null? ts) #f)
                               ((walk (car ts) (cons lbl path)) => values)
                               (else (next (cdr ts))))))))))))))

  ;; A marked name that names no block is a typo, and saying so is the whole
  ;; value of the declaration: a guarantee attached to nothing looks exactly
  ;; like a guarantee that holds.
  (define (check-no-allocation prog names)
    (let ((blocks (cadr prog)))
      (for-each
       (lambda (name)
         (unless (assq name blocks)
           (error 'no-allocation
                  (string-append
                   "`" (symbol->string name) "` is declared allocation-free and "
                   "names no procedure in this program; a guarantee attached to "
                   "nothing is indistinguishable from one that holds")
                  name))
         (let ((found (find-allocation blocks name)))
           (when found
             (error 'no-allocation
                    (string-append
                     "`" (symbol->string name) "` is declared allocation-free and "
                     "allocates: it reaches `" (symbol->string (car found))
                     "` through " (fmt-path (cdr found)))
                    name (car found) (cdr found)))))
       names)
      prog))

  (define (fmt-path path)
    (let loop ((p path) (acc ""))
      (cond ((null? p) acc)
            ((null? (cdr p)) (string-append acc (symbol->string (car p))))
            (else (loop (cdr p)
                        (string-append acc (symbol->string (car p)) " -> "))))))
  )
