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

;; The whole INSTRUCTION, not just the callee's name. A call destroys two
;; different things and only one is the callee's doing: the callee writes what
;; its body writes, and the CALL SITE writes the argument registers, which are
;; decided by this instruction's operands. Naming only the callee loses the
;; second half.
(ck! "a call site is reported with its position and its whole instruction"
     (let ((s (call-sites across-a-call)))
       (and (= 1 (length s))
            (eq? 'call (car (cdr (car s))))
            (eq? 'callee (cadddr (cdr (car s)))))))

;; A TAIL call is a jump. Control never comes back, so nothing is live across it
;; and it constrains no allocation. Reading one as a call would spill the world
;; at every loop back edge.
(ck! "a TAIL call is not a call site"
     (null? (call-sites
             '((entry (block ((const b tagged 2)
                              (call r tagged callee b))
                             (ret r)))))))

;; --- what survives, and what does not ---------------------------------------

;; `destroys-of` takes the call INSTRUCTION and answers with everything that
;; call leaves destroyed, or #f for "assume everything".
(define (assign-for destroys-of)
  (alloc-result-map
   (allocate-program/clobbers arch-x86-64 across-a-call cls destroys-of)))

(define (spills-for destroys-of)
  (alloc-result-spills
   (allocate-program/clobbers arch-x86-64 across-a-call cls destroys-of)))

;; THE OLD BEHAVIOUR, kept reachable and asserted. An unknown callee -- a
;; runtime routine, a member of a recursive cycle -- answers #f and is treated
;; as writing the whole register file, which is exactly what every caller
;; assumed before any of this existed.
(ck! "an UNKNOWN callee still spills everything live across the call"
     (memq 'a (spills-for (lambda (i) #f))))

(ck! "a callee that writes nothing lets the value stay in a register"
     (let ((m (assign-for (lambda (i) '()))))
       (and (not (memq 'a (spills-for (lambda (i) '()))))
            (memq (hashtable-ref m 'a #f) (arch-value arch-x86-64))
            #t)))

;; The register it keeps must be one the callee does not write. Withhold all but
;; one of the value pool and the answer is forced, so this cannot pass by luck.
(ck! "and the register it keeps is one the callee leaves alone"
     (let* ((all (arch-value arch-x86-64))
            (but-one (cdr all))
            (m (assign-for (lambda (i) but-one))))
       (eq? (hashtable-ref m 'a #f) (car all))))

;; If the callee writes every register of that class, the frame is the only
;; place left -- and the pass must reach for it rather than hand out a register
;; the callee destroys, which would be a wrong program and not a slow one.
(ck! "a callee that writes the whole value pool forces the spill again"
     (memq 'a (spills-for (lambda (i) (arch-value arch-x86-64)))))

;; The partition is not negotiable under any of this: a tagged value may never
;; land in a raw register, however free the raw file is, because the collector
;; scavenges the value class unconditionally and would miss the root.
(ck! "a tagged value never escapes into the raw pool to dodge a clobber"
     (let ((m (assign-for (lambda (i) (arch-value arch-x86-64)))))
       (not (memq (hashtable-ref m 'a #f) (arch-raw arch-x86-64)))))

;; --- nbody, which is what justified the work --------------------------------
;;
;; The measurement in the bead: no function in nbody writes more than half the
;; integer pool and the leaves write one or two, against an allocator that
;; assumed a call destroyed all twelve.
;;
;; Asserted as spill counts, in BOUNDS with the before-figure named, because the
;; exact number moves whenever anything upstream changes and the claim is about
;; the order of magnitude rather than the digit.

(define nb-fns
  (compiled-functions (compile-sonic "../bench/nbody/config-sonic.sps"
                                     nbody-externs)))

(define (spills-of name)
  (let find ((fs nb-fns))
    (cond ((null? fs) #f)
          ((eq? (finalized-name (car fs)) name)
           (length (finalized-spills (car fs))))
          (else (find (cdr fs))))))

(define total-spills
  (fold-left (lambda (n f) (+ n (length (finalized-spills f)))) 0 nb-fns))

;; 82 before, 52 after. The whole program, so a regression anywhere shows here
;; even if the function that caused it is not named below.
(ck! "nbody spills far less across the program: 82 before, well under 60 now"
     (< total-spills 60))

;; init! WAS the sharpest case here -- nothing but calls, 27 spills for a
;; function doing almost no arithmetic -- and it is no longer a function. It is
;; named by exactly one call, the one `main` makes, so inline.ss splices it
;; (rule 2') and there is nothing left to look up.
;;
;; The property it demonstrated is not lost: it is the program-wide total
;; above, which counts wherever that code ended up. Asserting it on a name that
;; no longer exists would have been a test that passes because `spills-of`
;; returns #f, which is worse than not asserting it.
(ck! "the spliced startup code does not reintroduce spills program-wide"
     (< total-spills 60))

;; And a loop whose body contains a call, which is the shape the whole thing was
;; built for: 8 before.
(ck! "subtract-pairs, a loop with a call in its body, drops from 8 to under 5"
     (and (spills-of 'subtract-pairs) (< (spills-of 'subtract-pairs) 5)))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
