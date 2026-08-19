;;; Tests for merge-identical-functions -- identical code becomes one function.
;;;
;;; WHY THE PASS EXISTS. `unroll-program` duplicates a loop body and `lift.ss`
;;; makes each copy its own function, so a hot loop arrives at code generation as
;;; several functions with the same instructions under different label names.
;;; That duplication is what lets the interval analysis discharge nbody's bounds
;;; checks (D118), and it is what costs fannkuch: 25.2% of its cycles are
;;; front-end stalled on mispredicts (D112) and duplicating a hot loop doubles
;;; its branch targets. Merging after finalization keeps the first and removes
;;; the second.
;;;
;;; WHAT MUST NOT HAPPEN is the first assertion below, and it is not
;;; hypothetical: the original pass canonicalised EVERY label, so a call to `foo`
;;; and a call to `bar` both became "the nth label" and two functions calling
;;; DIFFERENT functions compared as identical. The suite caught it as `label
;;; defined twice`, which is the mild symptom; merging two functions that do
;;; different things is the severe one.

(import (chezscheme) (sonic finalize) (sonic driver) (sonic pipeline))

(define checks 0)
(define failures 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok
      (begin (display "  ok   ") (display name) (newline))
      (begin (display "  FAIL ") (display name) (newline)
             (set! failures (+ failures 1)))))

;; A FUNCTION'S LISTING DEFINES A LABEL OF ITS OWN NAME, and the fixtures below
;; do too, because the pass depends on it: that is how a call naming the function
;; gets redirected when the function is dropped. `finalize-function` emits it --
;; a disassembly shows `=== loop%2.372 ===` and `=== loop%2.372.loop ===` as two
;; blocks -- and a fixture without it exercises a shape the compiler never
;; produces.
(define (fn name listing) (make-finalized name (cons name listing) #f '()))
(define (names fs) (map finalized-name fs))
(define (listing-of fs n)
  (let loop ((fs fs))
    (cond ((null? fs) #f)
          ((eq? (finalized-name (car fs)) n) (finalized-listing (car fs)))
          (else (loop (cdr fs))))))

;; --- the basic case ---------------------------------------------------------

(define a-body '(a.loop (mov rax rcx) (add rax (imm 1)) (jmp (label a.loop))))
(define b-body '(b.loop (mov rax rcx) (add rax (imm 1)) (jmp (label b.loop))))

(ck! "two functions identical under label renaming become one"
     (equal? (names (merge-identical-functions (list (fn 'a a-body) (fn 'b b-body))))
             '(a)))

(ck! "and the one that survives is the FIRST, not whichever hashes first"
     (equal? (names (merge-identical-functions (list (fn 'b b-body) (fn 'a a-body))))
             '(b)))

(ck! "a function with different instructions is untouched"
     (equal? (names (merge-identical-functions
                     (list (fn 'a a-body)
                           (fn 'c '(c.loop (mov rax rcx) (sub rax (imm 1))
                                           (jmp (label c.loop)))))))
             '(a c)))

;; --- THE SOUNDNESS PROPERTY -------------------------------------------------
;;
;; Same instructions, different callee. Merging these would redirect a call.

(ck! "two functions differing ONLY in whom they call are NOT merged"
     (equal? (names (merge-identical-functions
                     (list (fn 'p '(p.loop (mov rax rcx) (call (label foo))))
                           (fn 'q '(q.loop (mov rax rcx) (call (label bar)))))))
             '(p q)))

(ck! "and differing only in a jump target outside themselves are not merged"
     (equal? (names (merge-identical-functions
                     (list (fn 'p '(p.loop (mov rax rcx) (jmp (label foo))))
                           (fn 'q '(q.loop (mov rax rcx) (jmp (label bar)))))))
             '(p q)))

;; --- references to a dropped function's INTERNAL labels ----------------------
;;
;; D97's frame reuse retargets a tail call to `<name>.loop`, so a dropped
;; function's internal labels are named from outside it.

(ck! "a reference to the dropped function's own label is redirected"
     (let* ((out (merge-identical-functions
                  (list (fn 'a a-body)
                        (fn 'b b-body)
                        (fn 'z '(z.loop (jmp (label b.loop)))))))
            (zl (listing-of out 'z)))
       (and (equal? (names out) '(a z))
            (equal? zl '(z z.loop (jmp (label a.loop)))))))

(ck! "and a call naming the dropped FUNCTION is redirected too"
     (let* ((out (merge-identical-functions
                  (list (fn 'a a-body)
                        (fn 'b b-body)
                        (fn 'z '(z.loop (call (label b)))))))
            (zl (listing-of out 'z)))
       (and (equal? (names out) '(a z))
            (equal? zl '(z z.loop (call (label a)))))))

;; --- the fixpoint -----------------------------------------------------------
;;
;; p and q differ only in calling foo versus bar. Once foo and bar merge, p and
;; q become identical -- which one round cannot see.

(ck! "merging is iterated: callers become identical once their callees merge"
     (equal? (names (merge-identical-functions
                     (list (fn 'foo '(foo.loop (mov rax (imm 7))))
                           (fn 'bar '(bar.loop (mov rax (imm 7))))
                           (fn 'p '(p.loop (mov rcx rdx) (call (label foo))))
                           (fn 'q '(q.loop (mov rcx rdx) (call (label bar)))))))
             '(foo p)))

(ck! "nothing to merge leaves the list alone"
     (equal? (names (merge-identical-functions
                     (list (fn 'a a-body)
                           (fn 'c '(c.loop (sub rax rcx))))))
             '(a c)))

;; --- THE PASS IS NOT INERT, ON EITHER TARGET -------------------------------
;;
;; D132: the pass shipped in the driver rather than behind a target case and did
;; nothing at all on RV64 for two entries' worth of work, because x86-64 names a
;; branch target `(label X)` and RV64 names it as a bare symbol. Nothing failed
;; and no measurement looked wrong -- every check this project runs asks whether
;; the OUTPUT is correct and none asked whether the pass did anything.
;;
;; The assertion below is on the output and needs no instrumentation: after the
;; pass, no two emitted functions may be identical under label renaming. An
;; inert pass leaves duplicates and fails it.
;;
;; The canonical form here is written out INDEPENDENTLY rather than imported,
;; deliberately. Sharing `canonical-listing` would share its bugs -- and the bug
;; it had was precisely a shape it did not canonicalise, which a shared
;; implementation would agree with and this one does not.

(define (canon listing)
  (let ((own (let ((t (make-eq-hashtable)))
               (for-each (lambda (i) (when (symbol? i) (hashtable-set! t i #t))) listing)
               t))
        (m (make-eq-hashtable)) (n 0))
    (define (lab x)
      (if (hashtable-ref own x #f)
          (or (hashtable-ref m x #f)
              (begin (set! n (+ n 1)) (hashtable-set! m x n) n))
          x))
    (let walk ((x listing))
      (cond ((and (symbol? x) (hashtable-ref own x #f)) (lab x))
            ((pair? x) (cons (walk (car x)) (walk (cdr x))))
            (else x)))))

(define (duplicate-pairs fs)
  (let loop ((fs fs) (acc '()))
    (if (null? fs)
        (reverse acc)
        (let ((a (car fs)))
          (loop (cdr fs)
                (fold-left (lambda (acc b)
                             (if (equal? (canon (finalized-listing a))
                                         (canon (finalized-listing b)))
                                 (cons (list (finalized-name a) (finalized-name b)) acc)
                                 acc))
                           acc (cdr fs)))))))

(define nb "../bench/nbody/config-sonic.sps")

(for-each
 (lambda (target)
   (let* ((c (compile-sonic nb nbody-externs target))
          (dups (duplicate-pairs (compiled-functions c))))
     (ck! (string-append "no two emitted functions are identical under renaming ("
                         (symbol->string target) ")")
          (null? dups))
     (unless (null? dups)
       (display "       duplicates: ") (write dups) (newline))))
 '(x86-64 rv64))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
