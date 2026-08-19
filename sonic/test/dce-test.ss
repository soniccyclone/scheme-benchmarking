;;; Tests for dce.ss -- dead code elimination over Lmach.
;;;
;;; The pass exists because every stage upstream emits definitions it cannot
;;; tell are dead: `elide` proves a constant and rewrites the USE, leaving the
;;; `gref` that loaded it; `lower` names every intermediate; `essa`'s phi
;;; wrappers copy into names a later fold made unnecessary. Each is locally
;;; correct and locally blind, and the result was two wasted instructions per
;;; pair inside nbody's position-update loop.
;;;
;;; WHAT IT MUST NOT DO IS THE INTERESTING HALF, and it is where the assertions
;;; below concentrate. Deleting a definition something still reads is a
;;; miscompile that no count reveals, so:
;;;
;;;   - liveness is WHOLE-PROGRAM, not "after this point". Lmach is a CFG, and
;;;     "dead after here" is a dataflow question whose wrong answer deletes a
;;;     value a loop back edge reads next iteration. regalloc.ss already carries
;;;     that scar. The crude criterion cannot make the mistake.
;;;   - only `const` and the pure ops define anything removable. A store, gset,
;;;     call or `chk` stays whatever the tables say.
;;;
;;; Input is an Lmach datum: (program ([lbl (block (i ...) transfer)] ...) entry).

(import (chezscheme) (sonic dce) (sonic driver) (sonic pipeline))

(define checks 0)
(define failures 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok
      (begin (display "  ok   ") (display name) (newline))
      (begin (display "  FAIL ") (display name) (newline)
             (set! failures (+ failures 1)))))

(define (run prog)
  (let-values (((out st) (dce-program prog))) (values out st)))

(define (instrs-of out lbl)
  (let find ((bs (cadr out)))
    (cond ((null? bs) #f)
          ((eq? (car (car bs)) lbl) (cadr (cadr (car bs))))
          (else (find (cdr bs))))))

(define (has-op? out lbl op)
  (let ((is (instrs-of out lbl)))
    (and is (exists (lambda (i) (and (pair? i) (eq? (car i) op))) is))))

(define (defines-vreg? out lbl v)
  (let ((is (instrs-of out lbl)))
    (and is (exists (lambda (i) (and (pair? i) (pair? (cdr i)) (eq? (cadr i) v))) is))))

(define (one-block instrs transfer)
  `(program ([entry (block ,instrs ,transfer)]) entry))

(display "\n-- the definitions that should go --\n")

(let-values (((out st) (run (one-block '((const dead raw-word 7)
                                         (const live raw-word 1))
                                       '(ret live)))))
  (ck! "a const nothing reads is removed"
       (not (defines-vreg? out 'entry 'dead)))
  (ck! "and the one the transfer reads is kept"
       (defines-vreg? out 'entry 'live))
  (ck! "the count says one went"
       (= (dce-stats-removed st) 1)))

;; FIXPOINT. `t` is read only by `u`, and `u` is read by nobody. One sweep kills
;; `u`; only a second sees that `t` is now dead too.
(let-values (((out st) (run (one-block '((const t raw-word 2)
                                         (add u raw-word t t)
                                         (const live raw-word 1))
                                       '(ret live)))))
  (ck! "a chain of dead definitions goes entirely, not one layer per run"
       (and (not (defines-vreg? out 'entry 'u))
            (not (defines-vreg? out 'entry 't))))
  (ck! "which took more than one round"
       (> (dce-stats-rounds st) 1)))

(display "\n-- the ones it must never touch --\n")

;; Side effects. None of these define a removable vreg, so they stay however
;; unread their slots look.
(let-values (((out st) (run (one-block '((const v raw-word 3)
                                         (store v raw-word base 0)
                                         (const q raw-word 9)
                                         (gset q raw-word some-cell))
                                       '(jump entry)))))
  (ck! "a store stays"     (has-op? out 'entry 'store))
  (ck! "a gset stays"      (has-op? out 'entry 'gset))
  ;; AND the values they consume stay with them. gset is spelled
  ;; `(gset v sc cell)` where v is the value, not a destination -- reading that
  ;; slot as a definition would leave whatever computed it apparently unread,
  ;; and deleting that silently stores garbage into a global.
  (ck! "the value a store consumes is not collected out from under it"
       (defines-vreg? out 'entry 'v))
  (ck! "nor the value a gset stores, whose slot 1 is a SOURCE"
       (defines-vreg? out 'entry 'q)))

;; A check is not a definition and must survive even though nothing reads it.
;; Deleting one is the single worst thing this pass could do: the count of
;; discharged checks is the number this project exists to produce, and a check
;; removed here would look exactly like one the analysis proved.
(let-values (((out st) (run (one-block '((const i raw-word 0)
                                         (chk bounds-check checked 0 i lim))
                                       '(jump entry)))))
  (ck! "a chk survives, though it defines nothing anyone reads"
       (has-op? out 'entry 'chk))
  (ck! "and the index it tests is kept alive by it"
       (defines-vreg? out 'entry 'i)))

(display "\n-- liveness is whole-program, not straight-line --\n")

;; THE SCAR. `carried` is defined in the entry block and read only in the loop
;; body, which the back edge re-enters. Anything reasoning "nothing after this
;; point in THIS block reads it" deletes a value the next iteration needs.
(let-values (((out st)
              (run '(program ([entry (block ((const carried raw-word 5)
                                             (const zero raw-word 0))
                                            (jump body))]
                              [body  (block ((add sum raw-word carried zero))
                                            (branch-if sum body))])
                             entry))))
  (ck! "a value read only in another block, across a back edge, is kept"
       (defines-vreg? out 'entry 'carried))
  (ck! "and one read only by a branch-if transfer is kept"
       (defines-vreg? out 'body 'sum)))

;; The entry label is preserved: it is where the function starts, not a value.
(let-values (((out st) (run (one-block '((const live raw-word 1)) '(ret live)))))
  (ck! "the program's entry label survives the rewrite"
       (eq? (caddr out) 'entry)))

;; --- THE PASS IS NOT INERT ON A REAL PROGRAM --------------------------------
;;
;; Everything above is a fixture, and a fixture cannot catch inertness: it tests
;; the shape it was written for, which is by construction a shape the pass
;; handles. D132 is the case that motivates this -- `merge-identical-functions`
;; did nothing at all on RV64 for two entries, invisible because every check
;; asked whether the output was CORRECT and none asked whether the pass did
;; ANYTHING.
;;
;; dce cannot be asserted from the emitted code: its removals happen over Lmach
;; and selection, peephole and the allocator then create and remove their own.
;; The tempting property -- "no dead const survives to the listing" -- is FALSE
;; against a working pass, because a `chk` keeps such definitions live at this
;; level and their uses become immediates only later (D110, D136).
;;
;; So it is asserted where it runs, using the driver's stage hook to capture the
;; program dce is handed.
(define captured #f)
(parameterize ((compile-stage-hook
                (lambda (stage prog)
                  (when (eq? stage 'lmach/addrfold) (set! captured prog)))))
  (compile-sonic "../bench/nbody/config-sonic.sps" nbody-externs))

(ck! "the stage hook delivered nbody's Lmach program" (and captured #t))

(let-values (((out st) (dce-program captured)))
  (ck! "dce removes something from nbody: the pass is not inert"
       (> (dce-stats-removed st) 0))
  (unless (> (dce-stats-removed st) 0)
    (display "       removed=") (display (dce-stats-removed st)) (newline)))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
