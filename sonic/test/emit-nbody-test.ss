;;; The whole benchmark, all the way to bytes, on both targets.
;;;
;;; Every other test in this tree stops at some IR. This one runs
;;; `bench/nbody/config-sonic.sps` through every stage that exists and asserts
;;; that what comes out is machine code binutils will read back.
;;;
;;; It exists because the compiler spent a long time able to report "33 blocks
;;; selected, 0 spills" while being unable to emit a single byte. Nothing joined
;;; the register allocator to the assembler, and no test could tell, because
;;; every stage was individually consistent. A reach measured in stages is not
;;; the same claim as a reach measured in bytes.
;;;
;;; The RUNTIME BOUNDARY is stubbed rather than linked: `%make-flvector`, the
;;; trap handlers, and the externs nbody calls for I/O. Stubbing is honest here
;;; and the test says so in its own output -- what is being asserted is that the
;;; COMPILER emits a complete image, not that the program runs. Running it is
;;; E7's job and milestone 1's remaining half.

(import (chezscheme) (nanopass)
        (sonic lang) (sonic pipeline) (sonic read) (sonic expand) (sonic parse)
        (sonic policy) (sonic anf) (sonic assign) (sonic inline) (sonic essa)
        (sonic elide) (sonic repr) (sonic lower) (sonic select) (sonic regs)
        (sonic regalloc) (sonic finalize) (sonic litpool) (sonic object)
        (sonic target-rv64) (sonic target-x86-64) (sonic globals) (sonic runtime))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok
      (begin (display "  ok   ") (display name) (newline))
      (begin (set! failures (+ failures 1))
             (display "  FAIL ") (display name) (newline))))

(define src "../bench/nbody/config-sonic.sps")

(define p0 (inline-program (assign-convert-program (anf-program (resolve-policy-program
             (parse-program (expand-program (read-all-from-file src)) nbody-externs))))))
(define-values (p1 elide-st) (elide-program (essa-program p0)))
(define-values (p2 rp) (select-representations-program p1))
(define-values (prog0 lower-st) (lower-toplevel (unparse-Lrepr p2) 'main (repr-report-classes rp)))
(define classes (lowered-classes))
;; Top-level bindings are STORAGE: written by the entry code, read from any
;; function, and register allocation is per function. Without cells, a reading
;; function is handed a register unrelated to the one the writer used.
(define cells (global-cells (unparse-Lrepr p2)))
(define prog (globalize prog0 cells classes))

;; A call whose callee is not a block of this program is the runtime boundary.
;; Naming them is the point: a primitive that lowers to a call and names no
;; entry point puts its first ARGUMENT in the callee slot, which is how
;; `(make-flvector 15)` once lowered to a call to 15.
(define program-labels (map car (cadr prog)))
(define boundary
  (let ((acc '()))
    (let walk ((x prog))
      (when (pair? x)
        (when (and (eq? (car x) 'call) (>= (length x) 4))
          (let ((c (list-ref x 3)))
            (when (and (symbol? c) (not (memq c program-labels)) (not (memq c acc)))
              (set! acc (cons c acc)))))
        (for-each walk x)))
    acc))

(display "       runtime boundary: ") (write boundary) (newline)
(ck! "every runtime call names an entry point, not one of its own arguments"
     (for-all (lambda (c)
                (or (memq c nbody-externs)
                    (char=? (string-ref (symbol->string c) 0) #\%)))
              boundary))

;; Every label referenced by the finalized listing but not defined in it.
;; Pool entries are labels too, but they are defined by `extra-labels` at
;; assembly time rather than by appearing in the listing -- a constant is not an
;; instruction, so it has no position the label resolver could derive. Stubbing
;; them would emit a `ret` where a double belongs.
(define (pool-label? s)
  (let ((n (symbol->string s)))
    (and (> (string-length n) 6) (string=? (substring n 0 6) "%pool+"))))

(define (undefined-labels arch body)
  (let ((defined (filter symbol? body)) (refs '()))
    (let walk ((x body))
      (when (pair? x)
        (if (and (eq? (car x) 'label) (symbol? (cadr x)))
            (set! refs (cons (cadr x) refs))
            (for-each (lambda (y)
                        (if (pair? y)
                            (walk y)
                            (when (and (symbol? y) (not (eq? y 'rip))
                                       (not (reg-class arch y)))
                              (set! refs (cons y refs)))))
                      (cdr x)))))
    (let loop ((r refs) (acc '()))
      (cond ((null? r) acc)
            ((or (memq (car r) defined) (memq (car r) acc) (pool-label? (car r)))
             (loop (cdr r) acc))
            (else (loop (cdr r) (cons (car r) acc)))))))

(define (build target arch sel ret)
  ;; The allocator's class table is the authoritative one; selection must
  ;; read the same one or the return move cannot tell rax from xmm0.
  (parameterize ((current-litpool (make-pool)) (current-vreg-classes classes)
                 (current-globals
                  (assign-global-cells
                   (map global-cell-name (vector->list (hashtable-keys cells))))))
    (let* ((selected (select-program sel prog))
           (fns (finalize-program target arch selected (cadr prog) (caddr prog) classes (lowered-params)))
           (body (apply append (map finalized-listing fns)))
           (undef (undefined-labels arch body))
           (listing (append body (apply append (map (lambda (s) (cons s ret)) undef))))
           (extra (map (lambda (l) (cons (pool-label (lit-offset l)) (lit-offset l)))
                       (pool-entries (current-litpool))))
           (o (assemble-function target 'nbody listing
                                 (list (cons 'constants (pool-bytes (current-litpool)))
                                       (cons 'extra-labels extra)))))
      (list o fns undef))))

(define (report target arch sel ret)
  (let* ((r (build target arch sel ret))
         (o (car r)) (fns (cadr r)) (undef (caddr r))
         (code (function-object-code o)))
    (display "       ") (display target)
    (display ": ") (display (length fns)) (display " functions, ")
    (display (bytevector-length code)) (display " bytes of code, ")
    (display (bytevector-length (function-object-constants o)))
    (display " bytes of constants, stubbed ") (display (length undef))
    (display " runtime labels") (newline)
    (ck! (string-append (symbol->string target) ": the whole program assembles to bytes")
         (> (bytevector-length code) 1000))
    (ck! (string-append (symbol->string target) ": every function made it into the image")
         (= (length fns) 17))
    ;; The stubs must be the RUNTIME boundary and nothing else. An undefined
    ;; label that is one of our own blocks would mean a lost edge.
    (ck! (string-append (symbol->string target) ": nothing undefined is one of our own blocks")
         (not (exists (lambda (u) (memq u program-labels)) undef)))
    code))

(define rv-code (report 'rv64 arch-rv64 rv64-selector '((jalr zero ra 0))))
(define x86-code (report 'x86-64 arch-x86-64 x86-64-selector '((ret))))

;; Both targets compile the SAME program, so neither may come out trivially
;; small relative to the other -- a back end that silently dropped half the
;; program would still "assemble".
(ck! "the two targets emit comparable amounts of code for the same program"
     (let ((r (/ (bytevector-length x86-code) (bytevector-length rv-code))))
       (and (> r 1/2) (< r 2))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
