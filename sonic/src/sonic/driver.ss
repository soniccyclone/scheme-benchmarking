;;; The whole compiler, front to executable, in one place.
;;;
;;; This exists because there were two copies of the pipeline -- one in the
;;; build script and one inside the execution test -- and they drifted. Lambda
;;; lifting and the constant pool's alignment padding were added to one and not
;;; the other, so the test compiled a DIFFERENT program from the one being
;;; shipped and reported five failures that the shipped program did not have.
;;;
;;; A pipeline that is written down twice is a pipeline whose two halves will
;;; disagree, and the half with the tests is the one you will believe.
;;;
;;; Stage order, and why each one sits where it does:
;;;
;;;   read expand parse policy anf assign inline essa elide repr
;;;       -- the front end, unchanged
;;;   LIFT      after repr, because lifting only moves existing names into
;;;             parameter lists and essa has already made them unique, so the
;;;             storage classes computed by repr stay correct with no reruns
;;;   lower     tree to CFG
;;;   GLOBALIZE after lowering, on Lmach, because it needs to see every use as
;;;             an instruction operand rather than as a tree position
;;;   select allocate finalize
;;;   assemble  with the pool placed 16-ALIGNED past the code

(library (sonic driver)
  ;; Named `compile-sonic` rather than `compile-program`: Chez's own
  ;; `(chezscheme)` exports both `compile-program` and `compile-to-file`, and
  ;; shadowing them in a library body is an error rather than a shadow.
  (export compile-sonic compile-sonic-to-file
          ;; Exported so the LEGALITY pass can be run on the same IR the back
          ;; end sees. One `elide-program` call discharges 68 of nbody's 227
          ;; checks; this fixpoint discharges nearly all of them, and a
          ;; vectorizer looking at the un-fixed IR refuses every loop for
          ;; checks the compiled program does not contain.
          elide-to-fixpoint
          compiled? compiled-image compiled-code compiled-pool
          compiled-entry compiled-listing compiled-functions
          compiled-globals compiled-lift-report)
  (import (chezscheme) (nanopass)
          (sonic lang) (sonic read) (sonic expand) (sonic parse) (sonic policy)
          (sonic anf) (sonic assign) (sonic inline) (sonic essa) (sonic elide)
          (sonic repr) (sonic lift) (sonic convert) (sonic lower) (sonic globals)
          (sonic shapes) (sonic interval) (sonic cse) (sonic dce) (sonic addrfold) (sonic slp)
          (sonic select) (sonic regs) (sonic regalloc) (sonic finalize)
          (sonic litpool) (sonic object) (sonic runtime) (sonic elfexec)
          (sonic order)
          (sonic target-x86-64))

  (define-record-type (compiled make-compiled compiled?)
    (fields image code pool entry listing functions globals lift-report))

  (define (compile-sonic path externs)
    (let* ((p0 (inline-program
                (assign-convert-program
                 (anf-program
                  (resolve-policy-program
                   (parse-program (expand-program (read-all-from-file path))
                                  externs)))))))
      ;; SHAPES BEFORE ELISION. The interval domain can discharge nbody's inner
      ;; loop arithmetically and never had the premises: a vector's length was
      ;; never connected to the `make-flvector` that produced it, and a
      ;; top-level `(define n-bodies 5)` read as unknown. shapes.ss derives both
      ;; and propagates them across call sites, which is required rather than
      ;; nice -- the kernels take their vectors as PARAMETERS, so a fact that
      ;; stops at the allocation never reaches the loop that needs it.
      (let*-values (((ssa) (essa-program p0))
                    ((p1 elide-st) (elide-to-fixpoint ssa))
                    ((p2 rp) (select-representations-program p1))
                    ((lifted lrep) (lift-program (unparse-Lrepr p2)))
                    ;; CONVERSIONS AFTER LIFTING. Lifting adds a procedure's
                    ;; free variables as leading parameters, and they keep their
                    ;; own names and classes -- so a retag inserted before it
                    ;; would be inserted again for a name that already agrees.
                    ;; After it, every binding this pass sees is final.
                    ((converted conv-st)
                     (convert-program lifted (repr-report-classes rp)
                                      (repr-report-naturals rp)
                                      (repr-report-booleans rp))))
        (let*-values (((prog0 lower-st) (lower-toplevel converted 'main
                                                        (repr-report-classes rp))))
          (let*-values
              (((classes) (lowered-classes))
               ((cells) (global-cells lifted))
               ;; DCE LAST, after globalisation. The passes above each leave
               ;; definitions nothing reads -- elision rewrites a use into a
               ;; constant and leaves the `gref` that loaded it, lowering names
               ;; every intermediate whether or not it survives -- and none of
               ;; them can see it, because the use they would have to inspect
               ;; belongs to another pass's output. Running here sees all of it
               ;; at once, including the grefs globalisation itself introduces.
               ;; CSE THEN DCE, in that order and not the other. CSE does not
               ;; delete anything: it rewrites the USES of a redundant result
               ;; to name the earlier one, which leaves the redundant
               ;; definition with no readers for DCE to collect.
               ((gprog) (globalize prog0 cells classes))
               ((cprog cse-st) (cse-program gprog))
               ;; ADDRESS FOLDING BEFORE DCE, and before the allocator sees
               ;; anything. The `add` it replaces becomes dead, and DCE is what
               ;; removes it -- which is the whole point: the vreg never reaches
               ;; register allocation, so it never competes for a register and
               ;; never spills.
               ((aprog addr-st) (addrfold-program cprog))
               ;; SLP after DCE, so the packer sees the final instruction set
               ;; and does not pack something about to be deleted. Its packed
               ;; values are ordinary raw-f64 vregs -- a 128-bit pair lives in
               ;; one float register -- so nothing downstream changes.
               ((dprog dce-st) (dce-program aprog))
               ((prog slp-st) (slp-program dprog classes)))
          (let* ((entry (caddr prog))
                 ;; SORTED: this list decides each global's ADDRESS, so an
                 ;; unstable order moved every global between runs.
                 (gnames (map global-cell-name (sorted-key-list cells)))
                 (gaddrs (assign-global-cells gnames)))
            (parameterize ((current-litpool (make-pool))
                           (current-vreg-classes classes)
                           (current-globals gaddrs))
              (let* ((selected (select-program x86-64-selector prog))
                     (fns (finalize-program 'x86-64 arch-x86-64 selected
                                            (cadr prog) entry classes
                                            (lowered-params)))
                     (listing (append (runtime-listing 'x86-64 entry)
                                      (apply append (map finalized-listing fns))))
                     (pool (pool-bytes (current-litpool)))
                     ;; The pool lands 16-ALIGNED past the code, so every pool
                     ;; label carries the padding. A sign mask is a 128-bit SSE
                     ;; operand and `xorpd` FAULTS on an unaligned one, which is
                     ;; how `flneg` alone came to segfault.
                     (code-size (listing-size listing))
                     (pad (- (pool-offset-for code-size) code-size))
                     (extra (map (lambda (l)
                                   (cons (pool-label (lit-offset l))
                                         (+ pad (lit-offset l))))
                                 (pool-entries (current-litpool))))
                     (o (assemble-function 'x86-64 'program listing
                                           (list (cons 'constants pool)
                                                 (cons 'extra-labels extra))))
                     (start (label-offset listing '_start))
                     (img (build-executable 'x86-64 (function-object-code o) pool
                                            (+ elf-text-vaddr start)
                                            #x600000 runtime-data-size)))
                (make-compiled img (function-object-code o) pool
                               (+ elf-text-vaddr start) listing fns
                               gnames lrep)))))))))

  ;; Run the elision analysis until the parameter intervals stop improving.
  ;;
  ;; One pass is not enough and the reason is structural. A loop's variable gets
  ;; its range from the sigma refinement on the loop guard -- and after lambda
  ;; lifting the loop body is a SEPARATE procedure, so that range dies at the
  ;; call boundary and the body sees an unbounded index. nbody's inner loop kept
  ;; 18 bounds checks for exactly this: the length of `p` was known, the range
  ;; of `i` was not, and `p[3i+2]` needs both.
  ;;
  ;; Each round feeds the previous round's call-site argument intervals back as
  ;; premises on the callees' parameters. Facts only ever get added, and each is
  ;; a bounded integer range over a finite lattice, so it settles; the bound is
  ;; there because an argument for termination is not a guard.
  (define (elide-to-fixpoint ssa)
    (let* ((datum (unparse-Lssa ssa))
           (base (shape-facts datum))
           (params (procedure-params datum)))
      ;; WIDENING, without which this does not terminate.
      ;;
      ;; A parameter bounded by its loop guard settles fast -- `i < n-bodies`
      ;; gives [0,5] in three rounds. A parameter whose bound is not a known
      ;; constant ascends forever, one integer per round: [0,7] at round 7,
      ;; [0,41] at round 41. That is the classic infinite ascending chain, and
      ;; Cousot's answer is to widen.
      ;;
      ;; Widening here is to DROP the fact. Dropping is always sound -- it
      ;; claims less -- and for this purpose it is also the right answer: a
      ;; range that is still growing has no bound to state, and the whole point
      ;; of the fact is to bound an index. So after a few rounds of ascent, any
      ;; interval that is still widening is abandoned and the ones that settled
      ;; are kept.
      ;; Cousot's widen-then-narrow, which is the whole reason this terminates.
      ;;
      ;; A loop variable ascends one integer per round -- [0,0], [0,1], [0,2] --
      ;; toward a bound its guard will eventually impose. Waiting it out costs a
      ;; round per iteration of the loop, which for `n = 1000` is hopeless.
      ;; Widening jumps to infinity on whichever side is still growing;
      ;; narrowing then walks the infinite side back in using the guard, and for
      ;; `j < n-bodies` it lands on [0,5] two rounds later.
      ;;
      ;; The first attempt here simply DROPPED any fact that changed, which
      ;; destroyed facts that were ascending correctly and left every loop
      ;; unbounded. Dropping is sound and useless; widening is the operator that
      ;; is both.
      (define ascent-rounds 4)
      (define (combine op prev cand)
        (map (lambda (f)
               (let ((old (assq (car f) prev)))
                 (if (not old)
                     f
                     (let ((iv (op (make-interval (caddr old) (cadddr old))
                                   (make-interval (caddr f) (cadddr f)))))
                       (list (car f) 'interval (interval-lo iv) (interval-hi iv))))))
             cand))
      (let loop ((facts base) (round 0))
        (let-values (((p1 st) (elide-program ssa facts)))
          (let* ((argivs (elide-stats-argivs st))
                 (raw (interval-facts-from argivs params))
                 (prev (filter (lambda (f) (eq? (cadr f) 'interval)) facts))
                 (more (cond ((< round ascent-rounds) raw)
                             ((= round ascent-rounds) (combine iv-widen prev raw))
                             (else (combine iv-narrow prev raw))))
                 (next (append base more)))
            (cond
             ((or (> round 12) (equal? next facts))
              ;; The ascent ignored unbounded sites to get moving, so the result
              ;; is a claim until checked. Anything a caller escapes is dropped
              ;; and the analysis re-run without it.
              (let ((bad (facts-cover? facts argivs params)))
                (if (null? bad)
                    (values p1 st)
                    (let ((kept (filter (lambda (f) (not (memq (car f) bad))) facts)))
                      (elide-program ssa kept)))))
             (else (loop next (+ round 1)))))))))

  (define (listing-size listing)
    (let loop ((xs listing) (pc 0))
      (cond ((null? xs) pc)
            ((symbol? (car xs)) (loop (cdr xs) pc))
            (else (loop (cdr xs) (+ pc (instruction-size 'x86-64 (car xs))))))))

  (define (label-offset listing name)
    (let loop ((xs listing) (pc 0))
      (cond ((null? xs) (error 'label-offset "no such label in the listing" name))
            ((eq? (car xs) name) pc)
            ((symbol? (car xs)) (loop (cdr xs) pc))
            (else (loop (cdr xs) (+ pc (instruction-size 'x86-64 (car xs))))))))

  (define (compile-sonic-to-file path externs out)
    (let ((c (compile-sonic path externs)))
      (write-executable out (compiled-image c))
      c))
  )
