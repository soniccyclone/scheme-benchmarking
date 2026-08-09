;;; How far does a real program get? Reported as a number, not an impression.
(import (chezscheme) (nanopass) (sonic lang) (sonic pipeline)
        (sonic read) (sonic expand) (sonic parse) (sonic policy)
        (sonic anf) (sonic assign) (sonic inline) (sonic essa) (sonic elide) (sonic repr) (sonic lower) (sonic regalloc) (sonic regs) (sonic select))

;; MATCHED BY PREFIX. The `%NN` comes from the expander and is stable with the
;; source; the trailing `.NNN` is a global gensym counter that every pass
;; upstream shifts -- unrolling and inlining have each moved it. A test pinning
;; the counter fails whenever an unrelated pass allocates a name, and reports it
;; as a missing loop rather than as what it is.
(define (name-prefix? prefix nm)
  (let ((s (symbol->string nm)) (p (symbol->string prefix)))
    (and (>= (string-length s) (string-length p))
         (string=? (substring s 0 (string-length p)) p))))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define src (let loop ([ps '("../bench/nbody/config-sonic.sps"
                             "bench/nbody/config-sonic.sps")])
              (cond [(null? ps) #f]
                    [(file-exists? (car ps)) (car ps)]
                    [else (loop (cdr ps))])))

(ck! "the SonicScheme nbody variant exists" (and src #t))

(define elide-stats #f)
(define repr-counts #f)
(define repr-classes #f)
(define lower-stats #f)
(define lowered #f)

(define r
  (run-pipeline src
    (list (cons 'read   (lambda (p) (read-all-from-file p)))
          (cons 'expand (lambda (d) (expand-program d)))
          (cons 'parse  (lambda (e) (parse-program e nbody-externs)))
          (cons 'policy (lambda (c) (resolve-policy-program c)))
          (cons 'anf    (lambda (c) (anf-program c)))
          (cons 'assign (lambda (a) (assign-convert-program a)))
          (cons 'inline (lambda (a) (inline-program a)))
          (cons 'essa   (lambda (a) (essa-program a)))
          (cons 'elide  (lambda (a)
                          (let-values ([(o st) (elide-program a)])
                            (set! elide-stats st) o)))
          (cons 'repr   (lambda (a)
                          (let-values ([(o rp) (select-representations-program a)])
                            (set! repr-counts (repr-report-counts rp))
                            (set! repr-classes (repr-report-classes rp))
                            o)))
          (cons 'lower  (lambda (a)
                          (let-values ([(o st) (lower-toplevel (unparse-Lrepr a) 'main repr-classes)])
                            (set! lower-stats st) (set! lowered o) o))))))

(for-each (lambda (p)
            (display "       ") (display (if (cdr p) "ok  " "STOP"))
            (display "  ") (display (car p)) (newline))
          (pipeline-result-stages r))

(ck! "all eleven stages compose on the real program"
     (= (pipeline-result-reached r) 11))
(ck! "and nothing stopped" (not (pipeline-result-stopped-at r)))

;; What parse actually produced. These numbers are the shape of the program and
;; a change in them is a change in the front end worth noticing.
(when (= (pipeline-result-reached r) 11)
  ;; The first end-to-end measurement of SonicScheme on a real program. These
  ;; are the numbers the whole project exists to produce, and a change in them
  ;; is a change in what the analysis can prove.
  (display "       proved=") (display (elide-proved elide-stats))
  (display " kept=") (display (elide-kept elide-stats))
  (display " policy-suppressed=") (display (elide-unchecked elide-stats)) (newline)
  (ck! "the analysis discharges a substantial number of checks"
       (>= (elide-proved elide-stats) 40))
  ;; Nothing was suppressed by policy, so every discharge above is a PROOF.
  ;; lower.ss counts the two apart precisely so this claim can be made.
  (ck! "and NONE of them were suppressed by policy: all are proofs"
       (= (elide-unchecked elide-stats) 0))
  ;; A pass that proved everything would be unsound, not brilliant.
  (ck! "it does not claim to prove everything"
       (> (elide-kept elide-stats) 0))

  ;; Representation is where the unboxing shows up. A binding in raw-f64 lives
  ;; in a float register, is never scavenged and needs no GC metadata, which is
  ;; what lets nbody's inner loop carry none at all.
  (display "       repr ") (write repr-counts) (newline)
  (let ([g (lambda (c) (cdr (assq c repr-counts)))])
    (ck! "most bindings are UNBOXED, not tagged"
         (> (+ (g 'raw-f64) (g 'raw-word)) (* 8 (g 'tagged))))
    (ck! "and doubles dominate, which is what nbody is"
         (> (g 'raw-f64) (g 'raw-word))))

  ;; Lowering is where the tree becomes a CFG. The block count is the shape of
  ;; the program's control flow and a change in it is worth noticing.
  (display "       blocks=") (display (length (cadr lowered)))
  (display " lower-proved=") (display (lower-stats-proved lower-stats))
  (display " lower-emitted=") (display (lower-stats-emitted lower-stats)) (newline)
  (ck! "the program lowers to a multi-block CFG, not one straight line"
       (> (length (cadr lowered)) 5))
  ;; EVERY BLOCK MUST BE REACHABLE.
  ;;
  ;; The lowered CFG was disconnected for a long time and nothing noticed. An
  ;; `if` emitted its three blocks correctly, but the code AFTER the join went
  ;; on accumulating into a list the caller emitted under its own label, with
  ;; no edge from the join to it. The program still selected, still allocated,
  ;; and still reported plausible counts -- 287 of nbody's 551 virtual
  ;; registers simply lived in blocks nothing could branch to.
  ;;
  ;; A block count alone cannot catch that, because the blocks all exist. Only
  ;; reachability can, so it is asserted as a number.
  (let* ([fns (partition-into-functions (cadr lowered) (caddr lowered))]
         [orphans (assq '<unreachable> fns)])
    (display "       functions=") (display (length fns)) (newline)
    ;; REFINED, because the bucket now has two meanings and only one is a bug.
    ;;
    ;; Since inline.ss started working, inlining a procedure at its every call
    ;; site leaves the original binding with no callers -- so a whole DEAD
    ;; PROCEDURE lands here, legitimately. The disconnected CFG this test was
    ;; written for is a different shape: an intra-function block, one of the
    ;; `L.` labels an `if` or a join emits, that the function it belongs to
    ;; cannot branch to.
    ;;
    ;; So the invariant is stated on the labels. A whole unreachable procedure
    ;; is dead code and finalize declines to emit it; an unreachable `L.` block
    ;; means a function's own control flow lost an edge, which is the failure
    ;; that hid 287 of nbody's 551 virtual registers.
    (ck! "no INTRA-FUNCTION block is unreachable: the CFG is not disconnected"
         (or (not orphans)
             (for-all (lambda (b)
                        (let ((n (symbol->string (car b))))
                          (not (and (>= (string-length n) 2)
                                    (string=? (substring n 0 2) "L.")))))
                      (cdr orphans))))
    (when orphans
      (display "       unreachable (dead procedures): ")
      (write (map car (cdr orphans))) (newline))
    (ck! "and the program is many functions, not one"
         (> (length fns) 5)))

  ;; INSTRUCTION ORDER WITHIN A BLOCK.
  ;;
  ;; `emit-block!` takes its instructions reversed, and two callers handed it
  ;; an ordered list -- so those blocks came out backwards, with every use
  ;; before its def. That is invisible to a block count and to a label check,
  ;; and it made every vreg look live from position 0, so the allocator spilled
  ;; half the inner loop. Asserted directly: within a block, a vreg's
  ;; definition precedes its uses.
  (let ([bad '()])
    (for-each
     (lambda (b)
       (let ([instrs (cadr (cadr b))])
         (let loop ([is instrs] [defined '()])
           (unless (null? is)
             (let* ([i (car is)]
                    [later (map instr-def (cdr is))])
               (for-each (lambda (u)
                           ;; Used here, defined LATER in the same block.
                           (when (and (not (memq u defined)) (memq u later))
                             (set! bad (cons (list (car b) (car i) u) bad))))
                         (instr-uses i))
               (loop (cdr is)
                     (let ([d (instr-def i)])
                       (if d (cons d defined) defined))))))))
     (cadr lowered))
    (ck! "within a block, no vreg is used before the instruction that defines it"
         (null? bad)))

  ;; TAIL CALLS.
  ;;
  ;; This is the guarantee R5RS made that ANSI CL never did, and it is why this
  ;; compiler can express a loop as a procedure at all. It was silently absent:
  ;; essa.ss wraps an `if` in value position in a phi, so a loop's recursive
  ;; call came out as the call, then the phi's copy, then a jump to the join --
  ;; and `tail-call-instr` recognises a call that is the block's LAST
  ;; instruction and whose result the block's `ret` returns. The copy and the
  ;; jump destroyed both halves of that, so every iteration of every loop in
  ;; nbody pushed a frame.
  ;;
  ;; Lowering now tracks tail position, and in tail position an `if` needs
  ;; neither the copies nor a join: each arm ends in its own `ret`.
  (let ([tails (filter (lambda (b) (tail-call-instr (cadr b))) (cadr lowered))])
    (display "       tail calls=") (display (length tails)) (newline)
    (ck! "the loops' recursive calls are recognised as TAIL calls"
         (> (length tails) 10))
    ;; Named individually, because "some tail calls exist" would still pass
    ;; with every loop back edge stacking a frame.
    (let ([callees (map (lambda (b) (cadddr (tail-call-instr (cadr b)))) tails)])
      (ck! "every loop in nbody tail-calls itself"
           (for-all (lambda (pre)
                      (exists (lambda (c) (name-prefix? pre c)) callees))
                    '(loop%12 loop%35 inner%24 outer%22)))))

  ;; REGISTER PRESSURE, PER TARGET.
  ;;
  ;; The same program, the same allocator, two register partitions:
  ;;
  ;;   RV64     14 value / 9 raw / 31 float
  ;;   x86-64    8 value / 4 raw / 15 float
  ;;
  ;; Most of what is spilled on BOTH targets is spilled for the same reason and
  ;; it is not pressure: our own convention saves nothing across a call, so a
  ;; value live across one cannot stay in a register at all. That is why the
  ;; two counts are close. The partition difference shows up in the residual --
  ;; the values spilled for want of a register rather than for want of a
  ;; callee-saved set -- and x86-64's is the larger.
  ;;
  ;; What this assertion is really guarding is the LIVENESS pass. The CFG-wide
  ;; dataflow replaced a straight-line one that made every vreg look live from
  ;; position 0; under it these counts were several times higher. A regression
  ;; there shows up here first and loudly.
  (let* ([classes (lowered-classes)]
         [fns (lambda (arch)
                (allocate-functions arch (cadr lowered) (caddr lowered) classes))]
         [spills (lambda (arch)
                   (apply + (map (lambda (f) (length (alloc-result-spills (cdr f))))
                                 (fns arch))))]
         [rv (spills arch-rv64)]
         [x86 (spills arch-x86-64)])
    (display "       spills rv64=") (display rv)
    (display " x86-64=") (display x86) (newline)
    (ck! "spilling stays bounded -- a liveness regression multiplies this"
         (and (< rv 120) (< x86 140)))
    (ck! "x86-64 spills more than RV64, because eight value registers is not fourteen"
         (> x86 rv)))

  ;; Every block label must be unique: two blocks with one label make the
  ;; program ambiguous in a way selection cannot detect, since it walks both
  ;; and the second silently wins.
  (ck! "every block label is unique"
       (let loop ([ls (map car (cadr lowered))] [seen '()])
         (cond [(null? ls) #t]
               [(memq (car ls) seen) #f]
               [else (loop (cdr ls) (cons (car ls) seen))]))))

(when #f
  (let* ([u (unparse-Lcore (pipeline-result-note r))]
         [count (lambda (sym) (let f ([x u]) (cond [(pair? x) (+ (f (car x)) (f (cdr x)))]
                                                   [(eq? x sym) 1] [else 0])))])
    (display "       primcall=") (display (count 'primcall))
    (display " set!=") (display (count 'set!))
    (display " declare-distinct=") (display (count 'declare-distinct))
    (display " lambda=") (display (count 'lambda)) (newline)
    (ck! "the program reaches Lcore with primcalls, not surface forms"
         (> (count 'primcall) 100))
    ;; The number LEDGER.md records: nbody boxes nothing, because idiomatic
    ;; Scheme carries loop state in tail-call parameters and updates arrays
    ;; through flvector-set!, which is a store rather than an assignment.
    (ck! "ZERO set! forms, so assignment conversion boxes nothing"
         (= (count 'set!) 0))
    ;; The premise that makes the arrays provably distinct. Without it
    ;; alias-query answers `may` for a kernel that receives its arrays as
    ;; parameters, which is what a real entry point looks like.
    (ck! "declare-distinct survives to Lcore" (>= (count 'declare-distinct) 1))))

;; An UNDECLARED external must be refused, not silently treated as opaque.
;; This is the extern list earning its place: without it a typo reads as a
;; deliberate reference to something outside the compilation unit.
(set! checks (+ checks 1))
(let ([caught #f])
  (guard (e (#t (set! caught #t)))
    (parse-program (expand-program (read-all-from-file src)) '()))
  (if caught
      (display "  ok   parsing with an EMPTY extern list is refused: the names are unbound\n")
      (begin (set! failures (+ failures 1))
             (display "  FAIL an unbound name was silently accepted as external\n"))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
