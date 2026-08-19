(import (chezscheme) (sonic regs) (sonic regalloc) (sonic callconv))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))
(define (raises? thunk)
  (let ([caught #f]) (guard (e (#t (set! caught #t))) (thunk)) caught))

(define ccx callconv-x86-64)
(define ccr callconv-rv64)

;; --- arguments come from the right pool, and never from scratch -----------
;; The partition is not advice. A tagged argument in a raw register is a root
;; the collector never finds; an argument in a scratch register is one a
;; selection rule may clobber without telling the allocator.

(define (args-in-pool? cc sc)
  (let* ([a (callconv-arch cc)]
         [pool (case sc
                 [(tagged) (arch-value a)]
                 [(raw-word) (arch-raw a)]
                 [(raw-f64) (arch-float a)])])
    (for-all (lambda (r) (memq r pool)) (arg-registers cc sc))))

(ck! "x86-64: every argument register is in the pool for its storage class"
     (and (args-in-pool? ccx 'tagged)
          (args-in-pool? ccx 'raw-word)
          (args-in-pool? ccx 'raw-f64)))
(ck! "rv64: every argument register is in the pool for its storage class"
     (and (args-in-pool? ccr 'tagged)
          (args-in-pool? ccr 'raw-word)
          (args-in-pool? ccr 'raw-f64)))

(define (no-scratch? cc)
  (let ([s (arch-scratch (callconv-arch cc))])
    (not (exists (lambda (sc) (exists (lambda (r) (memq r s)) (arg-registers cc sc)))
                 '(tagged raw-word raw-f64)))))

(ck! "NO argument register is a scratch register on either target"
     (and (no-scratch? ccx) (no-scratch? ccr)))

(ck! "every argument register satisfies the partition assertion directly"
     (for-all (lambda (cc)
                (for-all (lambda (sc)
                           (for-all (lambda (r) (assignment-ok? (callconv-arch cc) sc r))
                                    (arg-registers cc sc)))
                         '(tagged raw-word raw-f64)))
              (list ccx ccr)))

;; The number that answers "is the partition big enough". x86-64 has SIX value
;; registers and four of them are callee-saved, so two tagged arguments is what
;; is left; the raw class gained r10 and r11 in the rebalance and passes six.
;; RV64 gets eight tagged because a0-a7 are value class by design.
;;
;; Two tagged argument registers is tight, and the honest response to that is
;; not to widen the value class back: nbody has 196 raw-word values against 45
;; tagged ones, so the registers are where the work is. A third tagged argument
;; goes on the stack, which now works in both directions.
(ck! "x86-64 has 2 tagged, 6 raw and 8 float argument registers"
     (and (= 2 (arg-register-count ccx 'tagged))
          (= 6 (arg-register-count ccx 'raw-word))
          (= 8 (arg-register-count ccx 'raw-f64))))
;; The sum is what the partition allows, so this catches a convention that
;; drifted from regs.ss rather than one that merely changed size.
(ck! "and every argument register is drawn from its own class's pool"
     (and (for-all (lambda (r) (memq r (arch-value (callconv-arch ccx))))
                   (arg-registers ccx 'tagged))
          (for-all (lambda (r) (memq r (arch-raw (callconv-arch ccx))))
                   (arg-registers ccx 'raw-word))))
(ck! "rv64 has 8 tagged, 4 raw and 8 float argument registers"
     (and (= 8 (arg-register-count ccr 'tagged))
          ;; Four, not five: t2 joined t0/t1 as a scratch register. RV64's
          ;; three-address arithmetic can put three spilled operands on one
          ;; instruction, and being load/store it cannot leave any of them in
          ;; memory, so it needs three scratches per file where x86-64 needs
          ;; one.
          (= 4 (arg-register-count ccr 'raw-word))
          (= 8 (arg-register-count ccr 'raw-f64))))

(ck! "argument numbering is per class: the first tagged and the first raw
       argument take different registers"
     (and (not (eq? (arg-register ccr 'tagged 0) (arg-register ccr 'raw-word 0)))
          (not (eq? (arg-register ccx 'tagged 0) (arg-register ccx 'raw-word 0)))))
(ck! "running out of argument registers reports #f rather than inventing one"
     (and (not (arg-register ccx 'tagged 4)) (not (arg-register ccr 'tagged 8))))

;; --- caller-saved versus callee-saved -------------------------------------
(ck! "the pools are partitioned: no register is both caller- and callee-saved"
     (for-all (lambda (cc)
                (not (exists (lambda (r) (callee-saved? cc r))
                             (callconv-caller-saved cc))))
              (list ccx ccr)))
(ck! "argument registers are caller-saved on both targets"
     (for-all (lambda (cc)
                (for-all (lambda (sc)
                           (for-all (lambda (r) (caller-saved? cc r))
                                    (arg-registers cc sc)))
                         '(tagged raw-word raw-f64)))
              (list ccx ccr)))
;; The foreign-boundary payoff: our callee-saved set is inside System V's, so a
;; call out to C preserves everything we were keeping there.
(ck! "x86-64 callee-saved is a subset of System V's callee-saved GPRs"
     (for-all (lambda (r) (memq r '(rbx rbp r12 r13 r14 r15)))
              (callconv-callee-saved ccx)))
(ck! "rv64 callee-saved is a subset of lp64d's saved registers"
     (for-all (lambda (r) (memq r '(s0 s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11
                                    fs0 fs1 fs2 fs3 fs4 fs5 fs6 fs7
                                    fs8 fs9 fs10 fs11)))
              (callconv-callee-saved ccr)))
(ck! "scratch registers count as clobbered by a call even though they are in
       no pool"
     (and (clobbered-by-call? ccx 'rax) (clobbered-by-call? ccr 't0)))

;; --- return placement ------------------------------------------------------
(ck! "x86-64 returns integers in rax and doubles in xmm0"
     (and (eq? (return-register ccx 'raw-word) 'rax)
          (eq? (return-register ccx 'raw-f64) 'xmm0)))
(ck! "rv64 returns tagged in a0 and doubles in fa0"
     (and (eq? (return-register ccr 'tagged) 'a0)
          (eq? (return-register ccr 'raw-f64) 'fa0)))
;; The one place we diverge from the host ABI, and it is forced: a0 is VALUE
;; class, so a raw word returned there would be scavenged as a pointer.
(ck! "rv64 does NOT return a raw word in a0: that would be a non-pointer in
       the value class"
     (and (not (eq? (return-register ccr 'raw-word) 'a0))
          (assignment-ok? arch-rv64 'raw-word (return-register ccr 'raw-word))))

;; Multiple values in registers, which is half of bead 6cm.1's acceptance.
(ck! "x86-64 returns three tagged values in rax, rcx, rdx: gcmeta's 2-bit
       scratch-live nesting IS the multiple-value convention"
     (equal? (map pin-reg (precolor-returns ccx '((v1 . tagged) (v2 . tagged) (v3 . tagged))))
             '(rax rcx rdx)))
(ck! "x86-64 refuses a fourth value in a register: the field is two bits"
     (raises? (lambda ()
                (precolor-returns ccx '((v1 . tagged) (v2 . tagged)
                                        (v3 . tagged) (v4 . tagged))))))
(ck! "rv64 returns eight tagged values in a0-a7 with no metadata at all"
     (equal? (map pin-reg (precolor-returns ccr (map (lambda (i) (cons i 'tagged))
                                                     '(a b c d e f g h))))
             '(a0 a1 a2 a3 a4 a5 a6 a7)))
(ck! "mixed-class multiple values draw from different pools simultaneously"
     (equal? (map pin-reg (precolor-returns ccx '((v1 . tagged) (v2 . raw-f64)
                                                  (v3 . raw-f64))))
             '(rax xmm0 xmm1)))

;; --- pin legality ----------------------------------------------------------
(ck! "a tagged pin to a value register is fine"
     (pin-ok? ccr 'tagged 'a3))
(ck! "a raw pin to rax is fine: rax is raw class and allocatable by nobody"
     (pin-ok? ccx 'raw-word 'rax))
(ck! "a tagged pin to rax is fine ONLY because x86-64 declares it scratch-live"
     (and (pin-ok? ccx 'tagged 'rax) (memq 'rax (callconv-scratch-live ccx))))
(ck! "a tagged pin to an undeclared raw register is REFUSED on rv64"
     (and (not (pin-ok? ccr 'tagged 't2))
          (not (pin-ok? ccr 'tagged 't0))))
(ck! "a raw pin into the value class is REFUSED on both targets"
     (and (not (pin-ok? ccr 'raw-word 'a0)) (not (pin-ok? ccx 'raw-word 'r8))))
(ck! "a raw-f64 pin to a raw-class scratch register is REFUSED: wrong class"
     (not (pin-ok? ccr 'raw-f64 't0)))
(ck! "check-pins! RAISES on an illegal pin rather than warning"
     (raises? (lambda () (check-pins! ccr (list (make-pin 'v 't2 'tagged))))))

;; --- precoloring through the allocator -------------------------------------
;; regalloc.ss is untouched. This is the wrapper.

(define instrs
  '((const a tagged 1)
    (const b tagged 2)
    (const c tagged 3)
    (add   r tagged a b)
    (add   s tagged r c)))
(define classes (make-eq-hashtable))
(for-each (lambda (v) (hashtable-set! classes v 'tagged)) '(a b c r s))

(let* ([pins (list (precolor-return ccr 's 'tagged))]
       [res (allocate/precolored ccr instrs classes pins)]
       [m (alloc-result-map res)])
  (ck! "rv64: the precolored return vreg lands EXACTLY on a0"
       (eq? (hashtable-ref m 's #f) 'a0))
  (ck! "and every other vreg still got a register: no spills"
       (null? (alloc-result-spills res)))
  (ck! "no unpinned vreg was handed the pinned register"
       (for-all (lambda (v) (not (eq? (hashtable-ref m v #f) 'a0))) '(a b c r)))
  (ck! "every unpinned assignment is still in the value pool"
       (for-all (lambda (v) (memq (hashtable-ref m v #f) (arch-value arch-rv64)))
                '(a b c r)))
  (ck! "the result carries the ORIGINAL arch, not the narrowed one"
       (eq? (alloc-result-arch res) arch-rv64)))

;; x86-64: the pin goes to rax, which is scratch, so it costs the allocator
;; nothing at all. All eight value registers stay available.
(let* ([pins (list (precolor-return ccx 's 'tagged))]
       [res (allocate/precolored ccx instrs classes pins)]
       [m (alloc-result-map res)])
  (ck! "x86-64: the precolored return vreg lands EXACTLY on rax"
       (eq? (hashtable-ref m 's #f) 'rax))
  (ck! "pinning a scratch register costs the pool nothing"
       (and (null? (alloc-result-spills res))
            (for-all (lambda (v) (memq (hashtable-ref m v #f) (arch-value arch-x86-64)))
                     '(a b c r)))))

;; Two values pinned at once, still leaving room for the rest.
(let* ([pins (precolor-returns ccr '((r . tagged) (s . tagged)))]
       [res (allocate/precolored ccr instrs classes pins)]
       [m (alloc-result-map res)])
  (ck! "two simultaneously-live pins both land where told"
       (and (eq? (hashtable-ref m 'r #f) 'a0)
            (eq? (hashtable-ref m 's #f) 'a1)))
  (ck! "and the unpinned three avoid both pinned registers"
       (for-all (lambda (v) (not (memq (hashtable-ref m v #f) '(a0 a1))))
                '(a b c))))

;; Pinning two overlapping live ranges to ONE register has no answer, so it is
;; refused rather than silently resolved.
(ck! "two overlapping vregs pinned to the same register are REFUSED"
     (raises? (lambda ()
                (allocate/precolored ccr instrs classes
                                     (list (make-pin 'r 'a0 'tagged)
                                           (make-pin 's 'a0 'tagged))))))

;; The pin must actually narrow the pool, or the test above proves nothing.
;; Withhold enough value registers that x86-64 is forced to spill.
(let* ([names (map (lambda (i) (string->symbol (string-append "t" (number->string i))))
                   (iota 8))]
       [defs (map (lambda (v) (list 'const v 'tagged 0)) names)]
       [prog (append defs (list (append '(add sink tagged) names)))]
       [cls (make-eq-hashtable)])
  (for-each (lambda (v) (hashtable-set! cls v 'tagged)) (cons 'sink names))
  (ck! "unpinned, eight simultaneous tagged values plus a sink already spill
       on x86-64: it has 8 value registers"
       (not (null? (alloc-result-spills (allocate arch-x86-64 prog cls)))))
  (ck! "rv64 fits them, and pinning one of the fourteen still fits"
       (and (null? (alloc-result-spills (allocate arch-rv64 prog cls)))
            (null? (alloc-result-spills
                    (allocate/precolored ccr prog cls
                                         (list (make-pin 'sink 'a0 'tagged))))))))

;; --- precoloring over a CFG ------------------------------------------------
;;
;; The single-block entry point is not enough for the case this exists to serve.
;; A loop parameter arrives in an argument register and is written back to that
;; register on the back edge, and both of those are only visible across blocks.
;;
;; What makes the CFG version its own function rather than a call to the other
;; one is the TRANSFER: a block carries `ret` and `branch-if` separately from
;; its instructions, and a pinned vreg read there would put its live range back
;; into the scan that the hiding exists to keep it out of.

(define cfg-prog
  '((entry (block ((const one raw-word 1)
                   (add nxt raw-word i one))
                  (branch-if nxt body done)))
    (body  (block ((add acc raw-word i one))
                  (ret acc)))
    (done  (block () (ret i)))))
(define cfg-cls (make-eq-hashtable))
(for-each (lambda (v) (hashtable-set! cfg-cls v 'raw-word)) '(one nxt i acc))

(let* ([pins (list (make-pin 'i 'rcx 'raw-word))]
       [res (allocate-program/precolored ccx cfg-prog cfg-cls pins)]
       [m (alloc-result-map res)])
  (ck! "x86-64: a vreg pinned across a CFG lands exactly where told"
       (eq? (hashtable-ref m 'i #f) 'rcx))
  (ck! "and no other vreg was handed that register, in any block"
       (for-all (lambda (v) (not (eq? (hashtable-ref m v #f) 'rcx)))
                '(one nxt acc)))
  (ck! "the pinned vreg is live in the TRANSFER of the last block, which the
       scan must count or it would re-place it"
       (null? (alloc-result-spills res)))
  (ck! "the ORIGINAL arch comes back out, not the narrowed one"
       (eq? (alloc-result-arch res) arch-x86-64)))

;; --- a pin lasts a LIVE RANGE, not a whole function ------------------------
;;
;; The fixture above cannot tell the two apart: `i` is read in every block, so
;; its range covers the program and withdrawing rcx for the function and holding
;; it for the range come to the same thing. This one separates them. `i` dies at
;; the first instruction and nothing after it can see the value, so rcx is free
;; for the rest of the program -- and under the implementation this replaced,
;; which removed rcx from every pool up front, it was free for nobody.
;;
;; D165 measured what that cost on a real program: fannkuch's hottest block spent
;; four of nineteen instructions shuffling loop variables out of the registers
;; the parameters held and back again, because the body was not allowed to use
;; them.

(define dies-early
  '((entry (block ((add t raw-word i i))
                  (branch-if t body done)))
    (body  (block ((const a raw-word 1)
                   (add b raw-word a a))
                  (ret b)))
    (done  (block ((const c raw-word 2))
                  (ret c)))))
(define dies-cls (make-eq-hashtable))
(for-each (lambda (v) (hashtable-set! dies-cls v 'raw-word)) '(i t a b c))

(let* ([res (allocate-program/precolored
             ccx dies-early dies-cls (list (make-pin 'i 'rcx 'raw-word)))]
       [m (alloc-result-map res)])
  (ck! "the pin still lands where told"
       (eq? (hashtable-ref m 'i #f) 'rcx))
  (ck! "and rcx goes back in the pool once the pinned value is dead, so a later
       vreg gets it -- the whole point, and false before this change"
       (let loop ([vs '(t a b c)])
         (cond [(null? vs) #f]
               [(eq? (hashtable-ref m (car vs) #f) 'rcx) #t]
               [else (loop (cdr vs))])))
  (ck! "nothing spilled: the register came back rather than being withheld"
       (null? (alloc-result-spills res))))

;; Two pins on one register is a caller bug here rather than a live-range
;; question, because the pins come from a parameter list where distinct
;; parameters take distinct argument registers by construction. Checked
;; directly, and refused.
(ck! "two pins claiming the same register are REFUSED over a CFG too"
     (raises? (lambda ()
                (allocate-program/precolored
                 ccx cfg-prog cfg-cls
                 (list (make-pin 'i 'rcx 'raw-word)
                       (make-pin 'acc 'rcx 'raw-word))))))

;; --- tail calls ------------------------------------------------------------

(define even-frame (make-frame 'even? 4))

(let ([p (tail-call-plan ccr even-frame 'odd? '((tagged . v-n)))])
  (ck! "a tail call TRANSFERS with a jump, never a call: no return address is
       pushed"
       (eq? (tail-plan-transfer p) 'jmp))
  (ck! "a register-only tail call reuses the caller's frame: delta is zero"
       (and (tail-plan-reuses-frame? p) (zero? (tail-plan-frame-delta p))))
  (ck! "the argument goes to the first tagged argument register"
       (equal? (tail-plan-moves p) '((a0 . v-n))))
  (ck! "and nothing goes on the stack" (null? (tail-plan-stack-args p))))

;; Overflow: ten tagged arguments on x86-64, which has TWO tagged registers.
;;
;; Two is the honest consequence of a six-register value class -- see the
;; partition note in regs.ss. The counts are read from the convention rather
;; than written down, so a later rebalance moves this test's arithmetic with it
;; instead of breaking it; what is asserted is that overflow HAPPENS and where
;; it goes, which is the property, not the size of today's pools.
(let* ([n-args 10]
       [regs (arg-register-count ccx 'tagged)]
       [args (map (lambda (i) (cons 'tagged i)) (iota n-args))]
       [tight (tail-call-plan ccx (make-frame 'f 4) 'g args)]
       [roomy (tail-call-plan ccx (make-frame 'f (- n-args regs)) 'g args)])
  (ck! "x86-64 fills its tagged argument registers and spills the rest"
       (and (= regs (length (tail-plan-moves tight)))
            (= (- n-args regs) (length (tail-plan-stack-args tight)))))
  (ck! "a caller frame too small to hold the outgoing area does NOT reuse it"
       (and (not (tail-plan-reuses-frame? tight))
            (= (- n-args regs 4) (tail-plan-frame-delta tight))))
  (ck! "a caller frame big enough does reuse it, so the stack does not grow"
       (tail-plan-reuses-frame? roomy)))
;; RV64's whole advantage: a0-a7 are value class, so eight tagged arguments
;; travel in registers there and overflow on x86-64. The gap is wider now that
;; x86-64 keeps two, and it is the same point.
(ck! "rv64 passes all eight tagged arguments in registers where x86-64 cannot"
     (and (= 8 (length (tail-plan-moves
                        (tail-call-plan ccr (make-frame 'f 0) 'g
                                        (map (lambda (i) (cons 'tagged i)) (iota 8))))))
          (= 0 (stack-words-for-args ccr (map (lambda (i) 'tagged) (iota 8))))
          (> (arg-register-count ccr 'tagged) (arg-register-count ccx 'tagged))))

;; --- constant stack in a mutually recursive fixture ------------------------
;; The acceptance criterion for 6cm.1. even?/odd? calling each other forever.

(define fixture
  (list (make-cproc 'even? 2 '(tagged) 'odd?)
        (make-cproc 'odd?  2 '(tagged) 'even?)))

(let-values ([(final peak) (simulate-calls ccr fixture 'even? 1000000 #t)])
  (ck! "one million mutual TAIL calls use constant stack"
       (and (= final 2) (= peak 2))))
(let-values ([(f10 p10) (simulate-calls ccr fixture 'even? 10 #t)]
             [(f1e6 p1e6) (simulate-calls ccr fixture 'even? 1000000 #t)])
  (ck! "and the depth does not depend on the number of calls at all"
       (and (= f10 f1e6) (= p10 p1e6))))

;; Negative control. Without the frame reuse the same fixture grows without
;; bound, so the assertion above is not vacuous.
(let-values ([(f10 p10) (simulate-calls ccr fixture 'even? 10 #f)]
             [(f100 p100) (simulate-calls ccr fixture 'even? 100 #f)])
  (ck! "the check is not vacuous: as ORDINARY calls the same fixture grows
       linearly"
       (and (> f100 f10) (= f100 (+ f10 (* 90 3))))))

;; Unequal frames: the peak is the largest frame in the cycle, not a sum.
(let ([uneven (list (make-cproc 'a 2 '(tagged) 'b)
                    (make-cproc 'b 9 '(tagged) 'a))])
  (let-values ([(final peak) (simulate-calls ccr uneven 'a 100000 #t)])
    (ck! "with unequal frames the peak is the largest frame in the cycle"
         (= peak 9))))

;; Stack arguments still cost, and a tail call that needs them is still bounded.
;;
;; The DEPTH is derived from the convention rather than written down: a frame of
;; 2 plus whatever the argument list overflows by. What matters is that the
;; depth does not grow with the number of calls, which is the tail-call property
;; -- not the particular number today's register pools produce.
(let* ([wide (list (make-cproc 'a 2 (map (lambda (i) 'tagged) (iota 10)) 'b)
                   (make-cproc 'b 2 (map (lambda (i) 'tagged) (iota 10)) 'a))]
       [expected (+ 2 (stack-words-for-args ccx (map (lambda (i) 'tagged) (iota 10))))])
  (let-values ([(final peak) (simulate-calls ccx wide 'a 100000 #t)]
               [(f10 p10) (simulate-calls ccx wide 'a 10 #t)])
    (ck! "a tail call with stack arguments is still constant-stack on x86-64,
       just deeper"
         (and (= peak expected) (= final expected)))
    (ck! "and a hundred thousand of them are no deeper than ten"
         (and (= final f10) (= peak p10)))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
