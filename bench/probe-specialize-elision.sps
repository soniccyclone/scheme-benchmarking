;;; A twenty-line reproduction of the specialize.ss elision collapse.
;;;
;;; specialize.ss is "full unrolling, spelled as specialization" and it is
;;; switched OFF, because enabling it takes fannkuch from 0 surviving bounds
;;; checks to 79 and nbody from 0 to 97. That regression is the only thing
;;; standing between qaq.23 and a measured 8.4% of fannkuch cycles (D43), so
;;; it is worth a fixture rather than a re-derivation each time.
;;;
;;; HOW TO USE IT. Compile with specialize-enabled? off and on and count the
;;; sonic-bounds-error labels:
;;;
;;;   off -> 0 checks, 4 functions
;;;   on  -> 3 checks, 18 functions        one check per copy of shift
;;;
;;; WHAT IT ISOLATES. Change the else branch (vector-set! v r p0) to use a
;;; LITERAL index and the copies come out clean -- 0 checks, still 18
;;; functions. So the loss is specifically an access whose index is a symbolic
;;; variable that is FREE in the copied loop, and it is not about copy count.
;;;
;;; WHAT IT RULES OUT. The interval facts are untouched: r carries exactly
;;; [1,8] with specialization off and on, and the fixpoint drops the same two
;;; names either way. So this is not a lost premise and not the fact-coverage
;;; check firing. specialize.ss own recorded suspect -- that freshen renames a
;;; binder while a declare premise still names the old one -- is separately
;;; refuted: inline.ss freshen maps declare names through the substitution.
;;;
;;; WHERE TO LOOK NEXT. [1,8] against an 8-element vector is NOT provable by
;;; the interval domain, so the baseline must be discharging that access by
;;; another rule -- a dominating check recorded in the environment obligations,
;;; or the ABCD inequality graph. Both are structural, and copying a loop body
;;; into a sibling procedure is exactly what would disturb them. Read
;;; elide-site-why on the PROVED site in the baseline; it names the rule, and
;;; that names what the copies lose.

;;; --- WHAT THE why FIELD SAYS, AND WHAT IT DOES NOT -----------------------
;;;
;;; Instrumented on the REAL driver path, not a rebuilt front end -- a hand-made
;;; approximation of the pipeline reported six kept checks where the compiler
;;; emits none, so it was measuring its own inaccuracy.
;;;
;;; BASELINE: every bounds check here is proved, why=interval, including the
;;; else branch's write indexed by r. WITH SPECIALIZATION: the same writes come
;;; back as kept, why=#f, one per copy, and their index is a per-copy freshened
;;; name -- r%1.320, r%1.334, r%1.348, one for each.
;;;
;;; TWO HYPOTHESES DIED HERE. Recorded so they are not re-run.
;;;
;;;   1. "The bad copies are the ones past the trip count, indexing out of
;;;      range." No. Change the else branch to a literal index and the copies
;;;      come out clean at the SAME copy count; the in-range copies fail
;;;      identically.
;;;
;;;   2. "The freshened index is not a parameter, so interval-facts-from can
;;;      never derive a fact for it." The kept indices do have neither a fact
;;;      nor parameter status -- and so do SEVENTEEN PROVED sites in the
;;;      baseline. An index normally takes its interval from the dataflow
;;;      through its binding's right-hand side, not from a fact of its own, so
;;;      parameter-ness does not discriminate.
;;;
;;; SO THE OPEN QUESTION IS NARROWER THAN IT LOOKS: for one specific binding --
;;; the copy's r -- the interval that flows through its right-hand side is
;;; present before specialization and absent after. The next step is to print
;;; that binding's right-hand side in both runs and compare. Not to theorise
;;; about which pass is responsible; two theories have already been wrong.

;;; --- THE PROOF CHAIN, READ OUT OF THE Lssa ITSELF ------------------------
;;;
;;; Dumping the datum and reading it beats guessing at binder shapes, which is
;;; how the two dead hypotheses above were produced.
;;;
;;; The else branch's write is guarded by two nested e-SSA sigmas:
;;;
;;;   (sigma i.N i.M fx< r.K #f            ; the false edge of (fx< i r)
;;;     (sigma r.J r.K fx> i.N #f          ; so r <= i
;;;       ... (vector-set! v r.J p0) ...))
;;;
;;; SO r's UPPER BOUND NEVER COMES FROM r. `rot` is `(lambda (r.K) ...)`, a
;;; perfectly ordinary letrec-bound procedure, and r.K carries NO interval fact
;;; in EITHER run -- checked, the only r-named fact in the program is a
;;; different variable entirely. The bound arrives through the second sigma:
;;; r <= i, so whatever upper bound `i` has becomes r's.
;;;
;;; THAT is what the copies lose. Not a fact, not a premise, not parameter
;;; status -- the refinement chain that carries `i`'s bound across to `r`.
;;;
;;; NEXT: check `i`'s interval at that sigma in both runs. In the copies `i` is
;;; let-bound to a literal, which ought to make the bound BETTER, so if it is
;;; absent there the reason is structural -- the phi/entry wrapper around the
;;; copy's parameter is the first thing to look at, since the original reads
;;; `(phi ((i.M (entry i.L))) ...)` and a copy binding a literal may not
;;; produce the same shape.
;;;
;;; Three hypotheses have now died on this issue. Read the IR before forming a
;;; fourth.

;;; --- A RETRACTION: THE POLARITY CLAIM WAS WRONG -------------------------
;;;
;;; A previous revision of this header announced the cause: that the baseline
;;; put the else-branch write under the guard's FALSE edge, giving `r <= i` and
;;; an upper bound, while the copies put it under the TRUE edge, giving `r > i`
;;; and only a lower bound.
;;;
;;; IT IS NOT TRUE. Checked properly, by matching the p0 write itself in both
;;; dumps rather than matching the first sigma chain in the file:
;;;
;;;     baseline      6 p0-writes, EVERY ONE under a #t sigma, all PROVED
;;;     specialized  20 p0-writes, EVERY ONE under a #t sigma, many KEPT
;;;
;;; Same polarity on both sides. It explains nothing.
;;;
;;; HOW THE MISTAKE HAPPENED, because it is the reusable part. I searched each
;;; dump for the first `(sigma ... fx< ... #f (sigma ... fx> ... #f` and
;;; compared what I found. In the baseline that pattern matched a DIFFERENT
;;; access than the one under investigation. Two different sites, read as one
;;; site changing. The fix is to match the site by its own operands -- here the
;;; `p0` argument, which is unique to the write in question -- and only then
;;; look up what guards it.
;;;
;;; ALSO CHECKED AND EQUAL: the Lanf before essa runs. The copy's `if` has the
;;; same arm order as the original's, differing only in that the loop bound is
;;; renamed from r%5 to the inlined argument t.18. So essa is not being handed
;;; a swapped conditional either.
;;;
;;; WHAT REMAINS TRUE. Baseline proves every one of these writes; with
;;; specialization on, one per copy survives. The structure around them --
;;; sigma chain, edge polarity, arm order -- is the same in both. So the
;;; difference is in what the interval domain can DERIVE along that chain, not
;;; in the chain's shape. The next thing to print is the interval elide
;;; actually computes for each operand of the surviving check, at the check,
;;; in both runs. Nothing short of that has settled anything on this issue.
;;;
;;; SCOREBOARD, kept deliberately: five hypotheses have now died here --
;;; out-of-range copies, lost declare premises, missing parameter status, a
;;; broken refinement chain, and edge polarity. The two that survived longest
;;; were the ones I did not check against the specific site.

(define v (make-vector 8 0))
(define (rot r)
  (let ((p0 (vector-ref v 0)))
    (let shift ((i 0))
      (if (fx< i r)
          (begin (vector-set! v i (vector-ref v (fx+ i 1))) (shift (fx+ i 1)))
          (vector-set! v r p0)))))
(define (drive r acc)
  (if (fx< r 8)
      (begin (rot r) (drive (fx+ r 1) (fx+ acc 1)))
      acc))
(display (fx->fl (drive 1 0)))
(newline)
