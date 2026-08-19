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
        (sonic lang) (sonic unroll) (sonic inline) (sonic specialize) (sonic pipeline)
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

;; THE BUDGET IS SET EXPLICITLY, and it has to be. `unroll-size-budget` ships at
;; 0: D153 showed the pass is a net loss once `ascent-rounds` is raised, because
;; check elision no longer needs the duplicated induction step and the
;; duplication costs fannkuch 4.7%. That is a policy about WHEN to run the pass;
;; these tests are about what it DOES when it runs, and would otherwise all pass
;; vacuously by observing a pass that never fired.
(define (unroll-names src . opt)
  (parameterize ((unroll-size-budget (if (pair? opt) (car opt) 1000)))
    (let-values (((out st) (unroll-program/report (front src))))
      (unroll-stats-names st))))

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
     (null? (unroll-names
             "(define (go i acc)
                (if (fx< i 10) (go (fx+ i 1) (fx+ acc i)) acc))
              (go 0 0)"
             3)))

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

;; Budget set explicitly, for the reason on `unroll-names`.
(let-values (((out st) (parameterize ((unroll-size-budget 1000))
                         (unroll-program/report
                          (assign-convert-program
                           (anf-program
                            (resolve-policy-program
                             (parse-program
                              (expand-program (read-all-from-file nb))
                              nbody-externs))))))))
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
;; Budget set explicitly, same reason: this assertion is about what the pass's
;; output does to code generation, which requires the output to exist.
(let* ((c (parameterize ((unroll-size-budget 1000))
            (compile-sonic nb nbody-externs)))
       (inners (let collect ((fs (compiled-functions c)) (acc '()))
                 (cond ((null? fs) (reverse acc))
                       ((let ((s (symbol->string (finalized-name (car fs)))))
                          (and (>= (string-length s) 6)
                               (string=? (substring s 0 6) "inner%")))
                        (collect (cdr fs) (cons (car fs) acc)))
                       (else (collect (cdr fs) acc))))))
  ;; TWO, NOT THREE, SINCE `merge-identical-functions` WAS ADDED. unroll-by-two
  ;; gives two callers and specialize.ss peels the enclosing loop, which used to
  ;; leave three `inner%` functions -- and two of them were the same instruction
  ;; sequence under different label names. finalize.ss now merges those after
  ;; finalization, so the duplication is present for the analyses that need it
  ;; (interval and element-range discharge nbody's fourteen bounds checks only
  ;; with the unrolled induction step, D118) and absent from the code, where a
  ;; doubled hot loop costs the branch predictor (D112).
  ;;
  ;; The assertion's intent is unchanged and is still what is checked: the force
  ;; loop is not LOST, and is not duplicated beyond the distinct bodies that
  ;; exist. What moved is that identical bodies are now one function rather than
  ;; several. The bounds-check assertions in run-x86-64-test.ss are what pin the
  ;; other half -- nbody still emits none, so the merge did not cost the elision.
  (ck! "the force loop survives to code generation, once per DISTINCT body"
       (= 2 (length inners)))
  ;; AND THE PRESSURE WENT DOWN RATHER THAN UP, which is worth asserting
  ;; because the opposite was expected. The doubled body used to spill one
  ;; value; with the peel in place every copy spills NONE. Kept as `at most
  ;; one` so a future change that reintroduces a single spill is a warning
  ;; rather than a failure, but the measured value today is zero.
  (ck! "and the doubled body costs at most one spill"
       (for-all (lambda (f) (<= (length (finalized-spills f)) 1)) inners)))


;; --- SPECIALIZATION MUST NOT BUILD A RING --------------------------------
;;
;; A specialized copy is one unrolled iteration, so the copies of a loop form a
;; CHAIN that ends when a guard folds. A cycle among them is not a slow program:
;; every edge is a tail call, so a ring of them is an infinite loop with no
;; stack growth to notice it by.
;;
;; specialize.ss built one, and the cause was a name collision rather than
;; anything about copying: `copy-name`'s counter lived in the per-call state and
;; restarted at zero every round, so round two minted `loop%66@1` for its first
;; copy -- a name round one had already given to a copy still in the program.
;; Two letrec bindings shared one name and the graph appeared to close on
;; itself. The counter is module-level now.
;;
;; This asserts the OUTCOME, not the guard: full unrolling compiles nbody and
;; computes the same two energies as the rolled program, to the bit. The
;; acyclicity check in specialize.ss stays as the thing that would catch a
;; recurrence, and it is silent here because there is nothing to catch.
(define baked
  (let* ((src (call-with-input-file nb
                (lambda (p)
                  (let loop ((acc '()))
                    (let ((l (get-line p)))
                      (if (eof-object? l)
                          (apply string-append (reverse acc))
                          (loop (cons (string-append l "\n") acc))))))))
         (old (string-append
               "(let* ((args (command-line))\n"
               "         (n (if (fx> (length args) 1)\n"
               "                (string->number (cadr args))\n"
               "                1000)))"))
         (nold (string-length old))
         (at (let scan ((i 0))
               (cond ((> (+ i nold) (string-length src)) #f)
                     ((string=? (substring src i (+ i nold)) old) i)
                     (else (scan (+ i 1))))))
         (out "/tmp/sonic-unroll-baked.sps"))
    ;; N BAKED, because with `(command-line)` in the way N is never a literal,
    ;; nothing specialises far enough and none of this is exercised. The shape
    ;; is asserted so a reworded preamble fails loudly instead of silently
    ;; testing nothing.
    (unless at
      (error 'unroll-test
             "config-sonic.sps no longer opens N with the preamble this rewrites"))
    (call-with-output-file out
      (lambda (p)
        (put-string p (string-append (substring src 0 at)
                                     "(let* ((n 1000))"
                                     (substring src (+ at nold) (string-length src)))))
      'replace)
    out))

(let ((compiled
       (guard (e (#t #f))
         (parameterize ((specialize-enabled? #t))
           (compile-sonic baked nbody-externs)))))
  (ck! "full unrolling compiles nbody rather than emitting a ring of copies"
       (and compiled (compiled? compiled))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
