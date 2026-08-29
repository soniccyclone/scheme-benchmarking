;;; Tests for noalloc.ss -- the allocation-free guarantee, checked at compile
;;; time.
;;;
;;; The freestanding RV64 entry (D215) states allocation-free as a precondition
;;; it cannot check: it does not initialise the heap pointer cell, so a program
;;; that allocates bumps from whatever the cell holds. This is what turns that
;;; statement into a refusal.
;;;
;;; The check runs on Lmach, and the reason is soundness rather than
;;; convenience: `%box-flonum` is inserted by convert.ss whenever a double takes
;;; the tagged representation, and `%make-vector-tagged` is chosen from the
;;; fill's class at lowering. Neither is visible in the program's own text, so a
;;; source-level check would hand a kernel author a guarantee that is wrong
;;; exactly where flonums meet generic code.

(import (chezscheme) (sonic driver) (sonic pipeline) (sonic noalloc)
        (sonic runtime))

(define checks 0)
(define failures 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok
      (begin (display "  ok   ") (display name) (newline))
      (begin (display "  FAIL ") (display name) (newline)
             (set! failures (+ failures 1)))))

(define tmp "/tmp/sonic-noalloc")

(define (write-src! src)
  (let ((p (open-file-output-port (string-append tmp ".sps")
                                  (file-options no-fail)
                                  (buffer-mode block) (native-transcoder))))
    (put-string p src) (close-port p)))

;; Returns 'ok, or the refusal message.
(define (try src)
  (write-src! src)
  (guard (e (#t (if (message-condition? e) (condition-message e) "<no message>")))
    (compile-sonic-to-file (string-append tmp ".sps") '(display-word)
                           (string-append tmp ".bin"))
    'ok))

(define (contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) sub) #t)
            (else (loop (+ i 1)))))))

(display "\n-- a procedure that allocates nothing --\n")

(ck! "a marked leaf procedure compiles"
     (eq? 'ok (try (string-append
                    "(declare-no-allocation leaf)\n"
                    "(define (leaf a b) (fx+ a b))\n"
                    "(define (main) (display-word (leaf 1 2)))\n(main)\n"))))

;; THE MARK MUST COST NOTHING WHEN IT IS SATISFIED. A guarantee that changes the
;; code is a guarantee nobody can afford in the hot path an interrupt handler is.
;; Image equality, D182's technique.
(let ((body (string-append
             "(define (leaf a b) (fx+ a b))\n"
             "(define (main) (display-word (leaf 1 2)))\n(main)\n")))
  (define (image-of src)
    (write-src! src)
    (compile-sonic-to-file (string-append tmp ".sps") '(display-word)
                           (string-append tmp ".bin"))
    (let* ((p (open-file-input-port (string-append tmp ".bin")))
           (bv (get-bytevector-all p)))
      (close-port p) bv))
  (ck! "and the mark changes not one byte of the image"
       (equal? (image-of body)
               (image-of (string-append "(declare-no-allocation leaf)\n" body)))))

(display "\n-- a procedure that allocates --\n")

(let ((m (try (string-append
               "(declare-no-allocation bad)\n"
               "(define (bad n) (vector-ref (make-vector n 0) 0))\n"
               "(define (main) (display-word (bad 3)))\n(main)\n"))))
  (ck! "a marked procedure that allocates is REFUSED" (string? m))
  (ck! "and the message names the procedure" (and (string? m) (contains? m "`bad`")))
  ;; NAMING THE ROUTINE is what makes the error actionable: "allocates" sends
  ;; the author reading their own source, and the source of a boxed flonum says
  ;; nothing at all.
  (ck! "and names the allocator it reaches"
       (and (string? m) (contains? m "%make-vector"))))

;; THE CHECK FOLLOWS CALLS. `allocs` has two callers, so inline.ss leaves it
;; alone -- with one caller it would be spliced and the allocation would appear
;; directly in `outer`, which tests nothing about following a call.
(let ((m (try (string-append
               "(declare-no-allocation outer)\n"
               "(define (allocs n) (vector-ref (make-vector n 0) 0))\n"
               "(define (outer n) (fx+ (allocs n) 1))\n"
               "(define (other n) (fx+ (allocs n) 2))\n"
               "(define (main) (display-word (fx+ (outer 3) (other 4))))\n(main)\n"))))
  (ck! "an allocation one call away is still refused" (string? m))
  (ck! "and the message gives the chain that reaches it"
       (and (string? m) (contains? m "outer -> allocs"))))

(display "\n-- a guarantee attached to nothing --\n")

(let ((m (try (string-append
               "(declare-no-allocation nosuch)\n"
               "(define (main) (display-word 1))\n(main)\n"))))
  (ck! "a marked name that names no procedure is REFUSED"
       (and (string? m) (contains? m "names no procedure"))))

(display "\n-- the allocator list against the runtime it describes --\n")

;; THE LIST IS THE WHOLE CORRECTNESS ARGUMENT and a missing entry is a wrong
;; answer, not a missed optimisation. Checking it against the runtime's own
;; labels is what stops it drifting when a seventh allocator is added.
(let ((labels (runtime-labels 'x86-64 'main)))
  (for-each
   (lambda (l)
     (ck! (string-append "the runtime defines " (symbol->string l))
          (and (memq l labels) #t)))
   allocating-labels))

;; And the other direction, which is the one that actually drifts: every runtime
;; label that looks like an allocator must be in the list. `%make-` and `%cons`
;; and `%box-` are the shapes; a new one not matching them would still need a
;; human, and this at least catches the ones that do.
(let ((labels (runtime-labels 'x86-64 'main)))
  (for-each
   (lambda (l)
     (let ((s (symbol->string l)))
       (when (and (> (string-length s) 6)
                  (or (string=? (substring s 0 6) "%make-")
                      (string=? (substring s 0 5) "%box-")))
         (ck! (string-append "the list covers " s)
              (and (memq l allocating-labels) #t)))))
   labels))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
