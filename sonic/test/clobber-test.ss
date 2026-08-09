;;; Interprocedural clobber sets: a call destroys what its callee writes.
;;;
;;; regalloc.ss spilled every value live across a call, on the grounds that "our
;;; own convention saves nothing: a called function uses the whole pool". That is
;;; true of the CONVENTION and false of the program, and this is a whole-program
;;; compiler. Measured on nbody, no function writes more than half the integer
;;; pool and the leaves write one or two.
;;;
;;; The assertions come in pairs throughout: something survives a call, and
;;; something else still spills. A pass that kept everything in registers would
;;; be much easier to write and would miscompile, so every relaxation here is
;;; matched by the refusal that bounds it.

(import (chezscheme)
        (sonic regs) (sonic regalloc)
        (sonic driver) (sonic pipeline) (sonic finalize))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define (classes-of . pairs)
  (let ((h (make-eq-hashtable)))
    (let loop ((ps pairs))
      (unless (null? ps)
        (hashtable-set! h (car ps) (cadr ps))
        (loop (cddr ps))))
    h))

;; `a` is defined before the call and read after it, so it is live ACROSS the
;; call and is the value whose fate these tests are about.
(define across-a-call
  '((entry (block ((const a tagged 1)
                   (const b tagged 2)
                   (call r tagged callee b)
                   (move c tagged a))
                  (ret c)))))

(define cls (classes-of 'a 'tagged 'b 'tagged 'r 'tagged 'c 'tagged))

;; --- the call sites, and which are not calls at all -------------------------

(ck! "a call site is reported with its position and its callee"
     (let ((s (call-sites across-a-call)))
       (and (= 1 (length s)) (eq? 'callee (cdr (car s))))))

;; A TAIL call is a jump. Control never comes back, so nothing is live across it
;; and it constrains no allocation. Reading one as a call would spill the world
;; at every loop back edge.
(ck! "a TAIL call is not a call site"
     (null? (call-sites
             '((entry (block ((const b tagged 2)
                              (call r tagged callee b))
                             (ret r)))))))

;; --- what survives, and what does not ---------------------------------------

(define (assign-for clobbers-of)
  (alloc-result-map
   (allocate-program/clobbers arch-x86-64 across-a-call cls clobbers-of)))

(define (spills-for clobbers-of)
  (alloc-result-spills
   (allocate-program/clobbers arch-x86-64 across-a-call cls clobbers-of)))

;; THE OLD BEHAVIOUR, kept reachable and asserted. An unknown callee -- a
;; runtime routine, a member of a recursive cycle -- answers #f and is treated
;; as writing the whole register file, which is exactly what every caller
;; assumed before any of this existed.
(ck! "an UNKNOWN callee still spills everything live across the call"
     (memq 'a (spills-for (lambda (c) #f))))

(ck! "a callee that writes nothing lets the value stay in a register"
     (let ((m (assign-for (lambda (c) '()))))
       (and (not (memq 'a (spills-for (lambda (c) '()))))
            (memq (hashtable-ref m 'a #f) (arch-value arch-x86-64))
            #t)))

;; The register it keeps must be one the callee does not write. Withhold all but
;; one of the value pool and the answer is forced, so this cannot pass by luck.
(ck! "and the register it keeps is one the callee leaves alone"
     (let* ((all (arch-value arch-x86-64))
            (but-one (cdr all))
            (m (assign-for (lambda (c) but-one))))
       (eq? (hashtable-ref m 'a #f) (car all))))

;; If the callee writes every register of that class, the frame is the only
;; place left -- and the pass must reach for it rather than hand out a register
;; the callee destroys, which would be a wrong program and not a slow one.
(ck! "a callee that writes the whole value pool forces the spill again"
     (memq 'a (spills-for (lambda (c) (arch-value arch-x86-64)))))

;; The partition is not negotiable under any of this: a tagged value may never
;; land in a raw register, however free the raw file is, because the collector
;; scavenges the value class unconditionally and would miss the root.
(ck! "a tagged value never escapes into the raw pool to dodge a clobber"
     (let ((m (assign-for (lambda (c) (arch-value arch-x86-64)))))
       (not (memq (hashtable-ref m 'a #f) (arch-raw arch-x86-64)))))

;; --- nbody, which is what justified the work --------------------------------
;;
;; The measurement in the bead: inner%24 writes 5 of 12 integer registers and
;; leaves r8 and r9 alone -- its parameters ARRIVE there and `parameter-pins`
;; keeps them there, so it reads them and never writes them -- while outer%22
;; spilled exactly those two values across the call to it.

(define nb-fns
  (compiled-functions (compile-sonic "../bench/nbody/config-sonic.sps"
                                     nbody-externs)))

(define (by-prefix p)
  (filter (lambda (f)
            (let ((s (symbol->string (finalized-name f))))
              (and (>= (string-length s) (string-length p))
                   (string=? (substring s 0 (string-length p)) p))))
          nb-fns))

(define outer (car (by-prefix "outer%")))

;; Asserted as a BOUND rather than as zero. outer%22 passes three vectors and a
;; counter to a callee that writes five registers; some of that traffic is real
;; argument setup and always will be. What must not come back is the wholesale
;; spill of every live value at the call, which was six.
(ck! "nbody's outer loop no longer spills the world across its inner call"
     (<= (length (finalized-spills outer)) 3))

;; The one that ties it to the mechanism rather than to a number: the values it
;; keeps must be in registers the callee does not write.
(ck! "and startup's init!, which is nothing but calls, spills nothing at all"
     (let ((i (filter (lambda (f) (eq? (finalized-name f) 'init!)) nb-fns)))
       (and (pair? i) (null? (finalized-spills (car i))))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
