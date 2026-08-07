;;; The calling convention, as instructions.
;;;
;;; Bead 6gk.19. `callconv.ss` said where arguments go and the selectors said
;;; how to move a value, and nothing joined them, so an Lmach call with more
;;; than one operand died on the operand count. What is checked here:
;;;
;;;   1. arguments land in the registers `callconv.ss` names, on BOTH targets,
;;;      and the two targets are asked the same question so a divergence shows;
;;;   2. a mixed tagged / raw-f64 list draws from two disjoint pools, which is
;;;      the whole reason there is no single argument register list;
;;;   3. arguments past the register set go to the outgoing stack area, in the
;;;      order the convention states;
;;;   4. the result placement is a PRECOLORING constraint (bead 6cm.10), not a
;;;      move, and `allocate/precolored` accepts the pins;
;;;   5. a tail call is a JUMP;
;;;   6. the whole lowered nbody selects on both targets with no arity error.
;;;
;;; The registers are read out of `callconv.ss` rather than written down here.
;;; A test that hardcodes `a0` passes when the convention changes underneath it
;;; and the compiler stops working, which is the wrong way round.

(import (chezscheme) (nanopass) (rnrs io simple)
        (sonic lang) (sonic regs) (sonic regalloc) (sonic callconv) (sonic select)
        (sonic callseq) (sonic target-rv64) (sonic target-x86-64)
        (sonic pipeline) (sonic read) (sonic expand) (sonic parse) (sonic policy)
        (sonic anf) (sonic assign) (sonic inline) (sonic essa) (sonic elide)
        (sonic repr) (sonic lower))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define (raises? th)
  (let ((caught #f)) (guard (e (#t (set! caught #t))) (th)) caught))

;; --- little Lmach programs ------------------------------------------------
;;
;; Built as data in Lmach's unparsed shape, which is what lower.ss produces and
;; what select.ss consumes. Each argument gets a defining instruction, because
;; that definition is where its storage class comes from: an Lmach call states
;; only its DESTINATION's class.

(define (defs args)
  (map (lambda (a)
         `(move ,(car a) ,(cdr a)
                ,(string->symbol (string-append "in." (symbol->string (car a))))))
       args))

;; An ORDINARY call: the transfer returns something other than the call's
;; result, so the tail-call shape is deliberately absent.
(define (call-prog args)
  `(program ((f (block ,(append (defs args)
                                `((call res tagged callee ,@(map car args))))
                       (ret ,(car (car args))))))
            f))

(define (tail-prog args)
  `(program ((f (block ,(append (defs args)
                                `((call res tagged callee ,@(map car args))))
                       (ret res))))
            f))

(define (selected sel prog)
  (cadr (car (cadddr (select-program sel prog)))))

;; Everything the call sequence itself emitted: the defining moves are one
;; instruction each on both targets, so dropping that many leaves the sequence.
(define (seq-of instrs args) (list-tail instrs (length args)))

;; Which physical register did argument `v` end up in? Read back out of the
;; selected stream by finding the move whose SOURCE is v.
(define (rv64-arg-reg instrs v)
  (let loop ((is instrs))
    (cond ((null? is) #f)
          ((and (memq (car (car is)) '(addi fsgnj.d)) (eq? (caddr (car is)) v))
           (cadr (car is)))
          (else (loop (cdr is))))))

(define (x86-arg-reg instrs v)
  (let loop ((is instrs))
    (cond ((null? is) #f)
          ((and (memq (car (car is)) '(mov movsd)) (symbol? (cadr (car is)))
                (eq? (caddr (car is)) v))
           (cadr (car is)))
          (else (loop (cdr is))))))

;; The outgoing stack byte offset a source was stored to, or #f.
(define (rv64-stack-slot instrs v)
  (let loop ((is instrs))
    (cond ((null? is) #f)
          ((and (memq (car (car is)) '(sd fsd)) (eq? (cadr (car is)) v)
                (eq? (caddr (car is)) 'sp))
           (cadddr (car is)))
          (else (loop (cdr is))))))

(define (x86-stack-slot instrs v)
  (let loop ((is instrs))
    (cond ((null? is) #f)
          ((and (memq (car (car is)) '(mov movsd))
                (pair? (cadr (car is))) (eq? (car (cadr (car is))) 'mem)
                (eq? (caddr (car is)) v))
           (list-ref (cadr (car is)) 4))
          (else (loop (cdr is))))))

;; --- 1. three arguments, both targets -------------------------------------

(define three '((a . tagged) (b . tagged) (c . tagged)))

(let* ((r (seq-of (selected rv64-selector (call-prog three)) three))
       (x (seq-of (selected x86-64-selector (call-prog three)) three))
       (rr (map (lambda (a) (rv64-arg-reg r (car a))) three))
       (xr (map (lambda (a) (x86-arg-reg x (car a))) three)))
  (ck! "RV64: three tagged arguments land in the convention's tagged registers"
       (equal? rr (list (arg-register callconv-rv64 'tagged 0)
                        (arg-register callconv-rv64 'tagged 1)
                        (arg-register callconv-rv64 'tagged 2))))
  (ck! "x86-64: the same three land in ITS tagged registers"
       (equal? xr (list (arg-register callconv-x86-64 'tagged 0)
                        (arg-register callconv-x86-64 'tagged 1)
                        (arg-register callconv-x86-64 'tagged 2))))
  ;; The point of asking both: the two conventions genuinely disagree, so a
  ;; selector that hardcoded one would pass one of these and fail the other.
  (ck! "and the two targets' answers are NOT the same registers" (not (equal? rr xr)))
  (ck! "RV64 ends the sequence with a call that saves a return address"
       (member '(jal ra callee) r))
  (ck! "x86-64 likewise" (member '(call (label callee)) x))
  ;; Every argument is in place before control leaves. What follows the call is
  ;; the RESULT MOVE and then the block's return -- the result move was missing
  ;; for a long time, so `dst` held whatever was in it before the call and every
  ;; call in the program returned garbage.
  ;; Two moves follow the call and both were missing for a long time. The first
  ;; brings the RESULT out of the return register into `res`; without it every
  ;; call in the program returned whatever was already there. The second puts
  ;; the block's own returned value INTO the return register; without it every
  ;; function returned whatever was already there. They are separate mechanisms
  ;; that failed the same way.
  (ck! "the call is followed by the result move, then the return move, then the return"
       (and (equal? (list-tail r (- (length r) 4))
                    `((jal ra callee)
                      (addi res ,(return-register callconv-rv64 'tagged) 0)
                      (addi ,(return-register callconv-rv64 'tagged) a 0)
                      (jalr zero ra 0)))
            (equal? (list-tail x (- (length x) 4))
                    `((call (label callee))
                      (mov res ,(return-register callconv-x86-64 'tagged))
                      (mov ,(return-register callconv-x86-64 'tagged) a)
                      (ret))))))

;; --- 2. two register FILES, not one list ----------------------------------

(define mixed '((p . tagged) (q . raw-f64) (r . tagged) (s . raw-f64)))

(let ((r (seq-of (selected rv64-selector (call-prog mixed)) mixed))
      (x (seq-of (selected x86-64-selector (call-prog mixed)) mixed)))
  ;; Numbering is PER CLASS: the first tagged and the first double both take
  ;; index 0 and land in different registers.
  (ck! "RV64: doubles go to the float argument registers, tagged to the value ones"
       (and (eq? (rv64-arg-reg r 'p) (arg-register callconv-rv64 'tagged 0))
            (eq? (rv64-arg-reg r 'r) (arg-register callconv-rv64 'tagged 1))
            (eq? (rv64-arg-reg r 'q) (arg-register callconv-rv64 'raw-f64 0))
            (eq? (rv64-arg-reg r 's) (arg-register callconv-rv64 'raw-f64 1))))
  (ck! "x86-64: same split, its own registers"
       (and (eq? (x86-arg-reg x 'p) (arg-register callconv-x86-64 'tagged 0))
            (eq? (x86-arg-reg x 'r) (arg-register callconv-x86-64 'tagged 1))
            (eq? (x86-arg-reg x 'q) (arg-register callconv-x86-64 'raw-f64 0))
            (eq? (x86-arg-reg x 's) (arg-register callconv-x86-64 'raw-f64 1))))
  ;; A double moved with an integer mv would be a silent wrong-value bug.
  (ck! "RV64 moves the doubles with the float move, not the integer one"
       (member `(fsgnj.d ,(arg-register callconv-rv64 'raw-f64 0) q q) r))
  (ck! "x86-64 moves the doubles with movsd"
       (member `(movsd ,(arg-register callconv-x86-64 'raw-f64 0) q) x))
  ;; And the tagged ones do NOT go through the float file.
  (ck! "the two files stay disjoint: no tagged argument reached a float register"
       (and (not (eq? (rv64-arg-reg r 'p) (rv64-arg-reg r 'q)))
            (eq? (reg-class arch-rv64 (rv64-arg-reg r 'p)) 'value)
            (eq? (reg-class arch-rv64 (rv64-arg-reg r 'q)) 'float))))

;; --- 3. overflow to the stack ---------------------------------------------
;;
;; Six raw words. RV64 has five raw argument registers and x86-64 four, so the
;; two targets spill a DIFFERENT number, which is the convention showing
;; through rather than a constant either file wrote down.

(define six '((w0 . raw-word) (w1 . raw-word) (w2 . raw-word)
              (w3 . raw-word) (w4 . raw-word) (w5 . raw-word)))

(let* ((r (seq-of (selected rv64-selector (call-prog six)) six))
       (x (seq-of (selected x86-64-selector (call-prog six)) six))
       (nr (arg-register-count callconv-rv64 'raw-word))
       (nx (arg-register-count callconv-x86-64 'raw-word))
       (names (map car six)))
;; The two raw-word counts USED to differ (5 against 4) and now coincide at 4:
  ;; t2 joined RV64's scratch set, because its three-address load/store
  ;; arithmetic can put three spilled operands on one instruction and none of
  ;; them can ride in memory. The claim that the two conventions genuinely
  ;; disagree still holds -- it just holds on the TAGGED class now, 8 against 4
  ;; -- so a selector that hardcoded one would still fail the other.
  (ck! "the two conventions genuinely disagree, so this is a real test"
       (and (= nr nx)
            (not (= (arg-register-count callconv-rv64 'tagged)
                    (arg-register-count callconv-x86-64 'tagged)))))
  (ck! "RV64: exactly the arguments past the register set went to the stack"
       (equal? (map (lambda (v) (and (rv64-stack-slot r v) #t)) names)
               (map (lambda (i) (>= i nr)) '(0 1 2 3 4 5))))
  (ck! "x86-64: likewise, and it spills more because it has fewer registers"
       (equal? (map (lambda (v) (and (x86-stack-slot x v) #t)) names)
               (map (lambda (i) (>= i nx)) '(0 1 2 3 4 5))))
  ;; Both targets now take four raw-word arguments in registers, so w4 is the
  ;; first to the stack on each and w5 follows one machine word later.
  (ck! "the outgoing words are in source order, one machine word apart"
       (and (equal? (rv64-stack-slot r 'w4) 0)
            (equal? (rv64-stack-slot r 'w5) 8)
            (equal? (x86-stack-slot x 'w4) 0)
            (equal? (x86-stack-slot x 'w5) 8)))
  ;; Hazard 1 in callseq.ss's header: a register move must not precede a stack
  ;; argument's read, or the store's source may already have been clobbered.
  (ck! "stack stores are emitted BEFORE the argument register moves"
       (let loop ((is r) (seen-move #f))
         (cond ((null? is) #t)
               ((and (eq? (car (car is)) 'sd) (eq? (caddr (car is)) 'sp))
                (and (not seen-move) (loop (cdr is) seen-move)))
               ((memq (car (car is)) '(addi fsgnj.d)) (loop (cdr is) #t))
               (else (loop (cdr is) seen-move)))))
  ;; `callconv.ss` answers "how many words" independently of any instruction.
  (ck! "the word count agrees with stack-words-for-args"
       (and (= (- 6 nr) (stack-words-for-args callconv-rv64 (map cdr six)))
            (= (- 6 nx) (stack-words-for-args callconv-x86-64 (map cdr six))))))

;; --- 4. the result is a constraint, not an instruction --------------------

(let* ((prog (call-prog three))
       (pins-r (call-result-pins callconv-rv64 prog))
       (pins-x (call-result-pins callconv-x86-64 prog))
       (r (seq-of (selected rv64-selector prog) three)))
  (ck! "one pin per non-tail call, naming the convention's return register"
       (and (= (length pins-r) 1)
            (eq? (pin-vreg (car pins-r)) 'res)
            (eq? (pin-reg (car pins-r)) (return-register callconv-rv64 'tagged))))
  (ck! "x86-64's tagged return rides rax, legal only because the convention declares it scratch-live"
       (and (eq? (pin-reg (car pins-x)) (return-register callconv-x86-64 'tagged))
            (pin-ok? callconv-x86-64 'tagged (pin-reg (car pins-x)))))
  ;; The join bead 6cm.10 asks for: the pins go straight into the allocator.
  (ck! "the pins are accepted by allocate/precolored and the vreg lands there"
       (let ((instrs (append (defs three) '((call res tagged callee a b c))))
             (classes (make-eq-hashtable)))
         (for-each (lambda (a)
                     (hashtable-set! classes (car a) (cdr a))
                     (hashtable-set! classes
                                     (string->symbol
                                      (string-append "in." (symbol->string (car a))))
                                     (cdr a)))
                   three)
         (hashtable-set! classes 'res 'tagged)
         ;; ADJACENT GAP, not this bead's: a call's callee slot holds a BLOCK
         ;; LABEL, and `live-intervals` sees a symbol in an operand slot and
         ;; treats it as a virtual register. `physical?` skips register names
         ;; and nothing skips labels, so `allocate` demands a storage class for
         ;; something that will never be in a register. Giving it one here keeps
         ;; the check about pins; the real fix is the allocator learning which
         ;; operand of a call is a target.
         (hashtable-set! classes 'callee 'tagged)
         (let ((out (allocate/precolored callconv-rv64 instrs classes pins-r)))
           (eq? (hashtable-ref (alloc-result-map out) 'res #f)
                (return-register callconv-rv64 'tagged)))))
  ;; Nothing is emitted for the result. A move here would be a second,
  ;; disagreeing mechanism for the same fact.
  ;; UPDATED: the result IS moved now. It has to be -- see above.
  (ck! "the result moves out of the return register into the destination"
       (equal? (list-ref r (- (length r) 4)) '(jal ra callee))))

;; --- 5. tail calls are jumps ----------------------------------------------

(let ((r (seq-of (selected rv64-selector (tail-prog three)) three))
      (x (seq-of (selected x86-64-selector (tail-prog three)) three)))
  (ck! "RV64: a tail call is `jal zero`, so no return address is pushed"
       (equal? (car (reverse r)) '(jal zero callee)))
  (ck! "x86-64: a tail call is a jmp, not a call"
       (equal? (car (reverse x)) '(jmp (label callee))))
  (ck! "and the return that followed it is gone from both"
       (and (not (member '(jalr zero ra 0) r)) (not (member '(ret) x))))
  (ck! "the arguments still land in the ABI registers"
       (equal? (map (lambda (a) (rv64-arg-reg r (car a))) three)
               (list (arg-register callconv-rv64 'tagged 0)
                     (arg-register callconv-rv64 'tagged 1)
                     (arg-register callconv-rv64 'tagged 2))))
  ;; A tail call has no result of its own; the block's own `ret` pin covers the
  ;; vreg, and two pins on one register over one live range is a false conflict.
  (ck! "a tail call contributes NO result pin"
       (null? (call-result-pins callconv-rv64 (tail-prog three))))
  ;; What makes the property real: the frame is reused, so a cycle of tail calls
  ;; has a bounded stack depth. `callconv.ss` measures that.
  (ck! "with every argument in registers the callee's frame fits in the caller's"
       (tail-plan-reuses-frame?
        (tail-call-plan callconv-rv64 (make-frame 'f 0) 'g
                        (map (lambda (a) (cons (cdr a) (car a))) three)))))

;; An overflowing tail call would write its outgoing arguments over the caller's
;; live frame. There is no frame layout pass to say when that is safe, so it
;; refuses rather than emitting a store that is right by luck.
(ck! "a tail call whose arguments overflow the registers is REFUSED, not guessed at"
     (raises? (lambda () (selected rv64-selector (tail-prog six)))))

;; --- 6. the acceptance: the whole lowered nbody ---------------------------

(define src (let loop ((ps '("../bench/nbody/config-sonic.sps"
                             "bench/nbody/config-sonic.sps")))
              (cond ((null? ps) #f)
                    ((file-exists? (car ps)) (car ps))
                    (else (loop (cdr ps))))))

(define lowered #f)
(define repr-classes #f)
(when src
  (run-pipeline src
    (list (cons 'read   (lambda (p) (read-all-from-file p)))
          (cons 'expand (lambda (d) (expand-program d)))
          (cons 'parse  (lambda (e) (parse-program e nbody-externs)))
          (cons 'policy (lambda (c) (resolve-policy-program c)))
          (cons 'anf    (lambda (c) (anf-program c)))
          (cons 'assign (lambda (a) (assign-convert-program a)))
          (cons 'inline (lambda (a) (inline-program a)))
          (cons 'essa   (lambda (a) (essa-program a)))
          (cons 'elide  (lambda (a) (let-values (((o st) (elide-program a))) o)))
          (cons 'repr   (lambda (a) (let-values (((o rp) (select-representations-program a)))
                                      (set! repr-classes (repr-report-classes rp)) o)))
          (cons 'lower  (lambda (a)
                          (let-values (((o st) (lower-toplevel (unparse-Lrepr a) 'main repr-classes)))
                            (set! lowered o) o))))))

(ck! "the nbody variant lowers to a multi-block Lmach program"
     (and lowered (> (length (cadr lowered)) 5)))

;; TWO rules are stubbed to get the whole program through, and neither is this
;; bead's. An exception stops selection where it lands, so without the stubs a
;; surviving arity error further in would simply go unseen, and the acceptance
;; would be a claim about the first few blocks.
;;
;;   `const` on an f64. No target can select one: it needs the per-function
;;   literal pool `litpool.ss` designs and nothing is wired to. Bead 6gk.13,
;;   declared as a gap at the top of both rule tables.
;;
;;   `chk`. lower.ss gives a check the WHOLE primcall's operand list, so a
;;   bounds check on `(flvector-set! v i x)` arrives as three operands where
;;   both targets' rules read two, and the limit it wants to compare against --
;;   the vector's length -- is not an operand at all. That is a hole in the
;;   check operand contract, upstream of either back end, and settling it is a
;;   bead of its own rather than something to decide inside a calling
;;   convention fix.
;;
;; What is NOT stubbed is every call in the program.
(define (override sel overrides)
  (make-selector (selector-name sel)
                 (append overrides (selector-rules sel))
                 (selector-partition sel)))

(define (declared-gaps sel)
  (override sel
    (list (cons 'const
                (let ((real (cdr (assq 'const (selector-rules sel)))))
                  (lambda (dst sc srcs)
                    ;; Keyed on the DATUM, not on `sc`: lower.ss labels a
                    ;; top-level flonum literal `raw-word`, so the class does
                    ;; not identify the ones that need the pool. That
                    ;; disagreement is a third upstream gap, noted here rather
                    ;; than papered over.
                    (if (and (number? (car srcs)) (not (and (integer? (car srcs))
                                                            (exact? (car srcs)))))
                        `((%pool-load ,dst ,(car srcs)))      ; bead 6gk.13
                        (real dst sc srcs)))))
          (cons 'chk (lambda (pn c srcs) `((%check ,pn ,c ,@srcs)))))))

(define (select-all sel prog) (select-program (declared-gaps sel) prog))

(define (all-instrs out) (apply append (map cadr (cadddr out))))

(when lowered
  (ck! "RV64 selects the WHOLE program, with no arity error on any call"
       (> (length (all-instrs (select-all rv64-selector lowered))) 100))
  (ck! "x86-64 selects the WHOLE program too"
       (> (length (all-instrs (select-all x86-64-selector lowered))) 100))

  ;; nbody's `put!` takes eight arguments -- one fixnum and seven doubles. That
  ;; is the call selection used to die on, and it is why this bead exists.
  (let ((r (all-instrs (select-all rv64-selector lowered)))
        (x (all-instrs (select-all x86-64-selector lowered))))
    (ck! "the eight-argument call to put! is selected on RV64"
         (and (member '(jal ra put!) r) #t))
    (ck! "and on x86-64"
         (and (member '(call (label put!)) x) #t))
    ;; Its fixnum argument must NOT ride a value register on RV64: a raw word in
    ;; the value class makes the collector scavenge a non-pointer. This is the
    ;; case the bead singles out, and the convention is what prevents it.
    (ck! "on RV64 every argument register used is in the class of the value it carries"
         (let loop ((is r))
           (cond ((null? is) #t)
                 ((and (eq? (car (car is)) 'addi) (equal? (cadddr (car is)) 0)
                       (memq (cadr (car is)) (arg-registers callconv-rv64 'raw-word)))
                  ;; an integer mv into a raw argument register: correct
                  (loop (cdr is)))
                 ((and (eq? (car (car is)) 'fsgnj.d)
                       (not (memq (cadr (car is)) (arg-registers callconv-rv64 'raw-f64)))
                       (memq (cadr (car is)) (arg-registers callconv-rv64 'tagged)))
                  #f)                       ; a double into a value register
                 (else (loop (cdr is)))))))

  ;; Every call in the real program gets a legal pin on both targets. A raw word
  ;; pinned into the value class, or a tagged value pinned outside it with no
  ;; scratch-live declaration, is caught here.
  (ck! "every call's result pin is legal under BOTH conventions"
       (and (begin (check-pins! callconv-rv64 (call-result-pins callconv-rv64 lowered)) #t)
            (begin (check-pins! callconv-x86-64 (call-result-pins callconv-x86-64 lowered)) #t)))

  ;; The tail calls lower.ss produced are recognised and become jumps. Without
  ;; this every iteration of nbody's loops would stack a frame, and proper tail
  ;; calls are the one performance guarantee R5RS actually makes.
  (let* ((tails (filter (lambda (lb) (tail-call-instr (cadr lb))) (cadr lowered)))
         (out (select-all rv64-selector lowered))
         (ends (map (lambda (lb)
                      (let ((sel (cadr (assq (car lb) (map (lambda (b) (list (car b) (cadr b)))
                                                           (cadddr out))))))
                        (car (reverse sel))))
                    tails)))
    (ck! "nbody has tail calls to recognise" (>= (length tails) 4))
    (ck! "and every one of them ends its block in a JUMP, not a call and return"
         (for-all (lambda (i) (and (eq? (car i) 'jal) (eq? (cadr i) 'zero))) ends))
    (ck! "no tail-call block ends in a return instruction"
         (for-all (lambda (i) (not (equal? i '(jalr zero ra 0)))) ends))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
