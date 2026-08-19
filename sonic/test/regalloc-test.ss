(import (chezscheme) (sonic regs) (sonic regalloc))

(define (remove-duplicates-eq xs)
  (let loop ([xs xs] [acc '()])
    (cond [(null? xs) (reverse acc)]
          [(memq (car xs) acc) (loop (cdr xs) acc)]
          [else (loop (cdr xs) (cons (car xs) acc))])))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

;; --- the partition tables match the design doc ---------------------------
;;
;; 6/6, not the 8/4 this asserted first. The partition's PURPOSE -- the
;; collector knowing statically which registers hold roots -- is untouched; only
;; where the line falls moved, and it moved because it was measured. nbody has
;; 196 raw-word values against 45 tagged ones and the pools were sized the other
;; way round, so its pairwise loop spilled seven values through a single scratch
;; and spent 85 of 119 instructions moving data.
(ck! "x86-64: 4 value, 8 raw, 14 float (rax, xmm14 and xmm15 reserved as scratch)"
     (and (= (value-count arch-x86-64) 4) (= (raw-count arch-x86-64) 8)
          (= (float-count arch-x86-64) 14)))
;; TWO float scratches on x86-64, because of three-address VEX. A two-address
;; `addsd d, s` has two operands and one can ride in memory, so one scratch
;; covers it; `vaddsd d, a, b` has three, and `a` sits in the VEX prefix's vvvv
;; field, which holds a register number and has no memory form. So d and a can
;; both need a register at once, and with one scratch the pass refused an
;; instruction it had the registers for.
;;
;; Spending the register is cheap HERE and only here: nbody has 179 raw-f64
;; values against 196 raw-word ones, and it was the raw-word pool that spilled.
;; The integer ops are still two-address, so rax stays alone.
(ck! "x86-64 reserves two float scratches and one integer scratch"
     (and (= 2 (length (arch-float-scratch arch-x86-64)))
          (= 1 (length (arch-int-scratch arch-x86-64)))))
;; The scratch registers must not also be allocatable, which is the bug the
;; RV64 agent found and the reason `scratch` is a separate field at all.
(ck! "and neither scratch is in the allocatable float pool"
     (not (exists (lambda (r) (memq r (arch-float arch-x86-64)))
                  (arch-float-scratch arch-x86-64))))
;; THE CALLEE-SAVED REGISTERS ARE NOW SPLIT BETWEEN THE CLASSES, and that is
;; the substance of the 6/6 -> 4/8 retune rather than a side effect of it.
;; System V makes rbx, r12, r13 and r14 callee-saved. All four used to be value
;; class, which meant there was NO callee-saved raw register and a raw word live
;; across a call always spilled -- fannkuch's enumeration driver spilled
;; thirteen values for that reason alone. Two of the four are raw now, so a raw
;; word can survive a call in a register.
;;
;; What must stay true is that each is in EXACTLY ONE pool, and that each class
;; keeps at least one, since a value of either class may be live across a call.
(ck! "the callee-saved registers are split two and two, each in exactly one pool"
     (and (for-all (lambda (r) (memq r (arch-value arch-x86-64))) '(rbx r12))
          (for-all (lambda (r) (memq r (arch-raw arch-x86-64))) '(r13 r14))
          (for-all (lambda (r) (not (and (memq r (arch-value arch-x86-64))
                                         (memq r (arch-raw arch-x86-64)))))
                   '(rbx r12 r13 r14))))
;; Three scratch registers per file on RV64, one per file on x86-64, and the
;; counts are forced by the ISAs rather than chosen. RV64 is load/store, so a
;; spilled operand must be reloaded into a register, and its arithmetic is
;; three-address, so one instruction can have three spilled operands at once.
;; x86-64 is two-address and reads memory directly, so one scratch covers it.
(ck! "rv64: 14 value, 8 raw, 29 float (t0-t2 and ft9-ft11 reserved as scratch)"
     (and (= (value-count arch-rv64) 14) (= (raw-count arch-rv64) 8)
          (= (float-count arch-rv64) 29)))
;; RV64's advantage is now entirely in the VALUE class. It used to have more of
;; both; the x86-64 retune brought the raw pools level at eight, which is worth
;; stating rather than weakening the comparison to `>=` and moving on. a0-a7
;; being value class is what still makes RV64 comfortable -- eight tagged
;; argument registers against two.
(ck! "RV64's remaining advantage is the value class, and the raw pools are level"
     (and (> (value-count arch-rv64) (value-count arch-x86-64))
          (= (raw-count arch-rv64) (raw-count arch-x86-64))))

;; Scratch is NOT allocatable. This is the bug the RV64 agent found: it used t0
;; as an address temporary while t0 sat at the head of the allocatable raw pool,
;; so linear scan would have handed it out and the address computation would
;; have clobbered a live value.
(ck! "scratch registers are outside every allocatable pool"
     (let ([out? (lambda (a)
                   (let ([sc (arch-scratch a)])
                     (not (exists (lambda (r) (or (memq r (arch-value a))
                                                  (memq r (arch-raw a))
                                                  (memq r (arch-float a))))
                                  sc))))])
       (and (out? arch-x86-64) (out? arch-rv64))))
(ck! "a scratch register classifies as scratch, not raw or float"
     (and (eq? (reg-class arch-rv64 't0) 'scratch)
          (eq? (reg-class arch-rv64 'ft11) 'scratch)
          (eq? (reg-class arch-x86-64 'rax) 'scratch)))
(ck! "and no storage class may be assigned to one"
     (and (not (assignment-ok? arch-rv64 'raw-word 't0))
          (not (assignment-ok? arch-rv64 'raw-f64 'ft11))
          (not (assignment-ok? arch-x86-64 'raw-word 'rax))))

;; classes are disjoint: a register in two classes would make the collector's
;; unconditional scavenge of the value class unsound.
(ck! "value, raw and float classes are pairwise disjoint on both targets"
     (let ([dis? (lambda (a)
                   (let ([v (arch-value a)] [r (arch-raw a)] [f (arch-float a)])
                     (and (not (exists (lambda (x) (memq x r)) v))
                          (not (exists (lambda (x) (memq x f)) v))
                          (not (exists (lambda (x) (memq x f)) r)))))])
       (and (dis? arch-x86-64) (dis? arch-rv64))))

;; --- the assertion that makes PC-total roots sound -----------------------
(ck! "a tagged value may go to a value register"
     (assignment-ok? arch-rv64 'tagged 'a0))
(ck! "a tagged value may NOT go to a raw register"
     (not (assignment-ok? arch-rv64 'tagged 't0)))
(ck! "a raw word may NOT go to a value register"
     (not (assignment-ok? arch-rv64 'raw-word 'a0)))
(ck! "a raw f64 goes to a float register, never an integer one"
     (and (assignment-ok? arch-rv64 'raw-f64 'ft0)
          (not (assignment-ok? arch-rv64 'raw-f64 't0))))

;; --- the vector file, which only RV64 has separately ----------------------
;;
;; D169: on x86-64 a packed pair IS a raw-f64 -- one xmm holds a double or two
;; and the width rides on the mnemonic -- so it needs no class of its own. RVV's
;; v registers are a distinct file, and an f register is 64 bits, so a pair put
;; there would be half a value with no diagnostic.
(ck! "rv64 has a vector file and x86-64 does not, which is the asymmetry"
     (and (positive? (vector-count arch-rv64))
          (zero? (vector-count arch-x86-64))))
(ck! "a packed pair goes to a vector register"
     (assignment-ok? arch-rv64 'raw-f64x2 'v1))
(ck! "a packed pair may NOT go to a float register: an f register is 64 bits
       and would hold half of it"
     (not (assignment-ok? arch-rv64 'raw-f64x2 'ft0)))
(ck! "on x86-64 the SAME storage class reaches the float file instead, because
       there an xmm already holds a pair -- so slp.ss can emit one class for
       both targets"
     (and (eq? (packed-class arch-x86-64) 'float)
          (eq? (packed-class arch-rv64) 'vector)
          (assignment-ok? arch-x86-64 'raw-f64x2 'xmm3)))
(ck! "and a scalar double may not go to a vector register either"
     (not (assignment-ok? arch-rv64 'raw-f64 'v1)))
(ck! "v0 is NOT allocatable: RVV names it as the mask in the encoding itself,
       so a value there is destroyed by any masked operation"
     (and (not (memq 'v0 (arch-vector arch-rv64)))
          (not (assignment-ok? arch-rv64 'raw-f64x2 'v0))))
(ck! "a v register reads as physical, so the allocator skips it rather than
       treating the name as a vreg"
     (and (physical? arch-rv64 'v1)
          (eq? (reg-class arch-rv64 'v1) 'vector)))
(let* ([prog '((entry (block ((p2add w raw-f64x2 u v)
                             (p2mul x raw-f64x2 w w)
                             (add n raw-word i i))
                            (ret x))))]
       [cls (make-eq-hashtable)])
  (for-each (lambda (v) (hashtable-set! cls v 'raw-f64x2)) '(u v w x))
  (for-each (lambda (v) (hashtable-set! cls v 'raw-word)) '(i n))
  (let* ([res (allocate-program arch-rv64 prog cls)]
         [m (alloc-result-map res)]
         [vr (lambda (s) (hashtable-ref m s #f))])
    (ck! "a packed vreg is allocated to the vector file, end to end"
         (for-all (lambda (s) (eq? (reg-class arch-rv64 (vr s)) 'vector))
                  '(u v w x)))
    (ck! "and the raw-word vregs beside it still go to raw registers, so the
       new class did not disturb the partition"
         (for-all (lambda (s) (eq? (reg-class arch-rv64 (vr s)) 'raw))
                  '(i n)))
    (ck! "nothing spilled: the vector file is thirty-one deep"
         (null? (alloc-result-spills res)))))

(ck! "the scratch files are named POSITIVELY, so a third file does not fall
       into the integer one -- the spiller takes arch-int-scratch and would
       have reloaded a spilled word into a vector register"
     (and (equal? (arch-int-scratch arch-rv64) '(t0 t1 t2))
          (equal? (arch-float-scratch arch-rv64) '(ft9 ft10 ft11))
          (equal? (arch-vector-scratch arch-rv64) '(v31))))
(ck! "and x86-64's partition is untouched by that change"
     (and (equal? (arch-int-scratch arch-x86-64) '(rax))
          (equal? (arch-float-scratch arch-x86-64) '(xmm14 xmm15))
          (null? (arch-vector-scratch arch-x86-64))))
(ck! "the vector scratch is held OUT of the allocatable pool, the way ft11 is"
     (and (not (memq 'v31 (arch-vector arch-rv64)))
          (eq? (reg-class arch-rv64 'v31) 'scratch)
          (= (vector-count arch-rv64) 30)))
(ck! "a packed pair may not be allocated to the scratch"
     (not (assignment-ok? arch-rv64 'raw-f64x2 'v31)))

(ck! "two storage classes over ONE file share a free list, or the allocator
       hands the same xmm to a scalar and a pair -- the free pool is keyed by
       FILE, not by class"
     (and (eq? (reg-file-for arch-x86-64 'raw-f64) 'float)
          (eq? (reg-file-for arch-x86-64 'raw-f64x2) 'float)
          (eq? (reg-file-for arch-rv64 'raw-f64) 'float)
          (eq? (reg-file-for arch-rv64 'raw-f64x2) 'vector)))

;; The bug this guards is not hypothetical: with a free list per CLASS, an
;; x86-64 program using both classes got two independent lists of the same xmm
;; registers. It surfaced as the RV64/x86-64 bit-identical oracle failing,
;; because the x86-64 side had become wrong (D182).
(let* (;; `w` is packed and live from its definition to the last instruction;
       ;; `s` is a scalar defined and read inside that span. They are live at the
       ;; same time and draw from the same xmm file, which is the pair a free
       ;; list per CLASS gave the same register to.
       [prog '((entry (block ((p2add w raw-f64x2 u v)
                              (mul s raw-f64 a b)
                              (p2splat z raw-f64x2 s)
                              (p2mul x raw-f64x2 w z))
                             (ret x))))]
       [cls (make-eq-hashtable)])
  (for-each (lambda (v) (hashtable-set! cls v 'raw-f64x2)) '(u v w x z))
  (for-each (lambda (v) (hashtable-set! cls v 'raw-f64)) '(a b s))
  (let* ([m (alloc-result-map (allocate-program arch-x86-64 prog cls))]
         [rw (hashtable-ref m 'w #f)] [rs (hashtable-ref m 's #f)])
    (ck! "on x86-64 a scalar and a packed pair that are live at the same time do
       not share a register, though they share the file"
         (and rw rs (not (eq? rw rs))))))

(ck! "the vector file is disjoint from every other pool on rv64"
     (let ([v (arch-vector arch-rv64)])
       (not (exists (lambda (x)
                      (or (memq x (arch-value arch-rv64))
                          (memq x (arch-raw arch-rv64))
                          (memq x (arch-float arch-rv64))))
                    v))))

(set! checks (+ checks 1))
(let ([caught #f])
  (guard (e (#t (set! caught #t))) (check-assignment! arch-rv64 'tagged 't0))
  (if caught
      (display "  ok   a bad assignment RAISES: it is corruption, not slowness\n")
      (begin (set! failures (+ failures 1))
             (display "  FAIL bad assignment accepted\n"))))

;; --- allocation over nbody's inner loop ----------------------------------
;; The real shape: index arithmetic in raw words, the loaded double in a float.
(define instrs
  '((const v-seven raw-word 7)
    (mul   v-off   raw-word v-i v-seven)
    (add   v-idx   raw-word v-off v-k)
    (load  v-val   raw-f64  v-b v-idx)))
(define classes (make-eq-hashtable))
(for-each (lambda (p) (hashtable-set! classes (car p) (cdr p)))
          '((v-seven . raw-word) (v-off . raw-word) (v-idx . raw-word)
            (v-val . raw-f64) (v-i . raw-word) (v-k . raw-word) (v-b . tagged)))

(let* ([r (allocate arch-rv64 instrs classes)]
       [m (alloc-result-map r)])
  (ck! "nbody's inner loop allocates with NO spills on RV64"
       (null? (alloc-result-spills r)))
  (ck! "the loaded double got a float register"
       (memq (hashtable-ref m 'v-val #f) (arch-float arch-rv64)))
  (ck! "the index got a raw register, not a value one"
       (memq (hashtable-ref m 'v-idx #f) (arch-raw arch-rv64)))
  (ck! "the flvector base got a VALUE register: it is a heap pointer"
       (memq (hashtable-ref m 'v-b #f) (arch-value arch-rv64)))
  (ck! "every assignment satisfies the partition"
       (let loop ([ks (vector->list (hashtable-keys m))])
         (cond [(null? ks) #t]
               [(assignment-ok? arch-rv64 (hashtable-ref classes (car ks) #f)
                                (hashtable-ref m (car ks) #f))
                (loop (cdr ks))]
               [else #f]))))

;; --- pressure: raw registers run out before value ones on x86-64 ---------
;; The vregs must be SIMULTANEOUSLY live or one register serves them all. Nine
;; sequential defs with no overlapping uses is not pressure, it is nine reuses
;; of the same register, and an earlier version of this test got that wrong.
(let* ([defs (map (lambda (i)
                    (list 'const (string->symbol (string-append "w" (number->string i)))
                          'raw-word i))
                  (iota 7))]
       [names (map (lambda (i) (string->symbol (string-append "w" (number->string i))))
                   (iota 7))]
       ;; one instruction using all of them at once: now they overlap
       [many (append defs (list (append '(add sink raw-word) names)))]
       [cls (make-eq-hashtable)])
  (hashtable-set! cls 'sink 'raw-word)
  (for-each (lambda (i)
              (hashtable-set! cls (string->symbol (string-append "w" (number->string i)))
                              'raw-word))
            (iota 7))
  ;; EIGHT SIMULTANEOUS RAW VALUES NOW FIT ON BOTH TARGETS -- seven words plus
  ;; the sink -- where x86-64 used to spill them into a six-register pool. The
  ;; program that separated the two targets no longer does, so the boundary is
  ;; tested where it actually is rather than left asserting a difference that
  ;; has gone.
  (let ([r (allocate arch-x86-64 many cls)])
    (ck! "x86-64 does NOT spill 7 raw words plus a sink: 8 fit in 8"
         (null? (alloc-result-spills r))))
  (let ([r (allocate arch-rv64 many cls)])
    (ck! "RV64 does NOT spill the same program: 7 words plus a sink fit in 8"
         (null? (alloc-result-spills r)))))

;; --- a physical name in an operand slot is NOT a vreg ----------------------
;; The two-address fixup puts a scratch register directly into an operand,
;; because the allocator runs over Lmach and never sees selected output, so
;; there is no vreg to request. Without this the allocator would treat it as a
;; virtual register and rename it to an allocatable one -- silently emitting
;; wrong code for exactly the case the fixup exists to handle.
(let* ([instrs '((move xmm15 raw-f64 v-a)
                 (sub  xmm15 raw-f64 xmm15 v-b)
                 (move v-c   raw-f64 xmm15))]
       [cls (make-eq-hashtable)])
  (hashtable-set! cls 'v-a 'raw-f64)
  (hashtable-set! cls 'v-b 'raw-f64)
  (hashtable-set! cls 'v-c 'raw-f64)
  (ck! "a scratch name in an operand slot gets no live interval"
       (not (assq 'xmm15 (live-intervals/arch instrs arch-x86-64))))
  (let* ([r (allocate arch-x86-64 instrs cls)]
         [m (alloc-result-map r)])
    (ck! "and the allocator does not rename it"
         (not (hashtable-ref m 'xmm15 #f)))
    (ck! "while the real vregs are still allocated"
         (and (hashtable-ref m 'v-a #f) (hashtable-ref m 'v-c #f)))))

(ck! "physical? recognises every class, and rejects a vreg"
     (and (physical? arch-x86-64 'rax) (physical? arch-x86-64 'rbx)
          (physical? arch-x86-64 'xmm0) (physical? arch-rv64 't0)
          (not (physical? arch-x86-64 'v-idx))))



;; --- a call's callee is a LABEL, not a vreg -------------------------------
;; physical? skips register names and nothing skipped labels, so a call target
;; got a live interval and was then allocated: the allocator would rewrite a
;; branch target into a register name. That is a wrong-code bug, not a slow one,
;; and the likelier symptom was allocate dying on "vreg has no storage class"
;; and hiding the real defect behind a confusing message.
(let* ([instrs '((const v-a raw-word 1)
                 (call v-r raw-word energy v-a)
                 (move v-o raw-word v-r))]
       [cls (make-eq-hashtable)])
  (for-each (lambda (p) (hashtable-set! cls (car p) (cdr p)))
            '((v-a . raw-word) (v-r . raw-word) (v-o . raw-word)))
  (ck! "the callee label gets no live interval"
       (not (assq 'energy (live-intervals/arch instrs arch-rv64))))
  (let* ([r (allocate arch-rv64 instrs cls)] [m (alloc-result-map r)])
    (ck! "and the allocator does not rewrite it into a register"
         (not (hashtable-ref m 'energy #f)))
    (ck! "while the call's arguments and result still allocate"
         (and (hashtable-ref m 'v-a #f) (hashtable-ref m 'v-r #f)))))

(ck! "jump and branch-if targets are labels too"
     (and (label-operand? '(jump L1) 0)
          (label-operand? '(branch-if v L1 L2) 1)
          (label-operand? '(branch-if v L1 L2) 2)
          ;; but the tested value is NOT a label
          (not (label-operand? '(branch-if v L1 L2) 0))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
