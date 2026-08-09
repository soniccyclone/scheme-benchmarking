;;; Loop unrolling over Lanf.
;;;
;;; The transformation is one line of intent -- replace the self tail call with a
;;; copy of the body -- so the tests are almost all about the edges: what it
;;; refuses, what it must not capture, and that it stops after one.
;;;
;;; The end-to-end assertions are the ones that would have caught this pass being
;;; INERT, which it was for two separate reasons before either was noticed. A
;;; unit test over a hand-written Expr passes happily while the pass matches
;;; nothing a real program presents (D32), so the acceptance criterion has to be
;;; nbody itself.

(import (chezscheme) (nanopass)
        (sonic lang) (sonic unroll) (sonic inline)
        (sonic read) (sonic expand) (sonic parse) (sonic policy)
        (sonic anf) (sonic assign)
        (sonic driver) (sonic pipeline) (sonic finalize))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

;; A Lanf Program built the way the front end builds one, so the shape under
;; test is the shape the pipeline produces.
(define (front src)
  (assign-convert-program
   (anf-program
    (resolve-policy-program
     (parse-program (expand-program (read-all-from-file/string src)) '())))))

(define (read-all-from-file/string s)
  (let ((p (open-string-input-port s)))
    (let loop ((acc '()))
      (let ((d (read p)))
        (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))

(define (unroll-names src)
  (let-values (((out st) (unroll-program/report (front src))))
    (unroll-stats-names st)))

;; --- what it unrolls --------------------------------------------------------

;; The expander renames a LOCAL binding (`go` becomes `go%N`) and leaves a
;; top-level one alone, so this matches the prefix.
(define (any-named? prefix names)
  (exists (lambda (n)
            (let ((s (symbol->string n)) (p (symbol->string prefix)))
              (and (>= (string-length s) (string-length p))
                   (string=? (substring s 0 (string-length p)) p))))
          names))

(ck! "a self-tail-recursive letrec loop is unrolled"
     (any-named? 'go (unroll-names
                "(define (f n)
                   (letrec ((go (lambda (i acc)
                                  (if (fx< i n) (go (fx+ i 1) (fx+ acc i)) acc))))
                     (go 0 0)))
                 (f 10)")))

;; A top-level procedure that tail-calls itself is a loop in exactly the same
;; sense, and reaching it means walking the Program's BINDINGS rather than only
;; its body. nbody's `subtract-pairs` and `energy-from` are both this shape.
(ck! "a TOP-LEVEL self-tail-recursive procedure is unrolled too"
     (memq 'go (unroll-names
                "(define (go i acc)
                   (if (fx< i 10) (go (fx+ i 1) (fx+ acc i)) acc))
                 (go 0 0)")))

;; --- what it refuses --------------------------------------------------------

(ck! "a procedure that does not call itself is left alone"
     (null? (unroll-names
             "(define (f n) (fx+ n 1))
              (f 3)")))

;; A NON-tail self call is ordinary recursion, not a loop. Copying the body into
;; it would be inlining, which is inline.ss's job and has a different cost model.
(ck! "a non-tail self call is not a back edge and is not unrolled"
     (null? (unroll-names
             "(define (f n)
                (if (fx< n 1) 1 (fx* n (f (fx- n 1)))))
              (f 5)")))

(ck! "the size budget refuses a body larger than it"
     (null? (parameterize ((unroll-size-budget 3))
              (unroll-names
               "(define (go i acc)
                  (if (fx< i 10) (go (fx+ i 1) (fx+ acc i)) acc))
                (go 0 0)"))))

;; --- exactly once -----------------------------------------------------------
;;
;; THE TERMINATION ARGUMENT, asserted rather than trusted. The copy is inserted
;; verbatim and never rescanned, so the copy's own self call survives as the new
;; back edge and is not itself expanded. If it were, this would not terminate at
;; all -- so a passing test here is also the evidence that the pass halts.
(define (count-tailcalls-to f d)
  (let walk ((x d) (n 0))
    (cond ((and (pair? x) (eq? (car x) 'tailcall) (eq? (cadr x) f))
           (+ n 1 (fold-left (lambda (a y) (walk y a)) 0 (cddr x))))
          ((pair? x) (fold-left (lambda (a y) (walk y a)) n x))
          (else n))))

(ck! "unrolling by two leaves exactly two self calls, not three and not a hang"
     (let-values (((out st)
                   (unroll-program/report
                    (front "(define (go i acc)
                              (if (fx< i 10) (go (fx+ i 1) (fx+ acc i)) acc))
                            (go 0 0)"))))
       ;; one back edge in the original tail, one in the copy
       (= 2 (count-tailcalls-to 'go (unparse-Lanf out)))))

;; --- no capture -------------------------------------------------------------
;;
;; The copy's binders must be renamed. Sharing a name with the original gives one
;; variable two definitions, and the failure is silent: the second binding wins
;; and the loop computes with the wrong value.
(ck! "every binder in the copy is renamed"
     (let-values (((out st)
                   (unroll-program/report
                    (front "(define (go i acc)
                              (if (fx< i 10)
                                  (let ((j (fx+ i 1))) (go j (fx+ acc j)))
                                  acc))
                            (go 0 0)"))))
       (let ((names '()))
         (let walk ((x (unparse-Lanf out)))
           (when (pair? x)
             (when (and (eq? (car x) 'let) (pair? (cadr x)) (pair? (car (cadr x))))
               (set! names (cons (car (car (cadr x))) names)))
             (for-each walk x)))
         ;; no let-binder appears twice
         (= (length names) (length (remp (lambda (n) #f)
                                         (let dedup ((ns names) (acc '()))
                                           (cond ((null? ns) acc)
                                                 ((memq (car ns) acc) (dedup (cdr ns) acc))
                                                 (else (dedup (cdr ns) (cons (car ns) acc)))))))))))

;; --- nbody, which is the only test that could have caught the two inertias ---

(define nb "../bench/nbody/config-sonic.sps")

(let-values (((out st) (unroll-program/report
                        (assign-convert-program
                         (anf-program
                          (resolve-policy-program
                           (parse-program
                            (expand-program (read-all-from-file nb))
                            nbody-externs)))))))
  (ck! "nbody's loops are reached at all: the pass is not inert"
       (> (unroll-stats-unrolled st) 0))
  ;; The two that matter. `inner%24` is the pairwise force loop and `outer%22`
  ;; encloses it; a run that unrolls only the energy helpers is the symptom of
  ;; `declare-distinct` going unhandled, which is what made this pass look like
  ;; it worked while doing nothing to the hot path.
  (ck! "specifically, the pairwise force loop and its enclosing loop"
       (and (memq 'inner%24 (unroll-stats-names st))
            (memq 'outer%22 (unroll-stats-names st)))))

;; REGISTER PRESSURE IS THE COST, and it is real rather than theoretical: the
;; doubled body spills one value where the rolled one spilled none. It is
;; asserted so that a later change making it much worse is visible, and because
;; the honest reading of this pass is that it trades pressure for loop control.
(let* ((c (compile-sonic nb nbody-externs))
       (inners (let collect ((fs (compiled-functions c)) (acc '()))
                 (cond ((null? fs) (reverse acc))
                       ((let ((s (symbol->string (finalized-name (car fs)))))
                          (and (>= (string-length s) 6)
                               (string=? (substring s 0 6) "inner%")))
                        (collect (cdr fs) (cons (car fs) acc)))
                       (else (collect (cdr fs) acc))))))
  (ck! "the force loop survives to code generation, once per unrolled caller"
       (= 2 (length inners)))
  (ck! "and the doubled body costs at most one spill"
       (for-all (lambda (f) (<= (length (finalized-spills f)) 1)) inners)))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
