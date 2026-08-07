(import (chezscheme) (sonic regs) (sonic regalloc))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

;; --- the partition tables match the design doc ---------------------------
(ck! "x86-64: 8 value, 4 raw, 15 float (rax and xmm15 reserved as scratch)"
     (and (= (value-count arch-x86-64) 8) (= (raw-count arch-x86-64) 4)
          (= (float-count arch-x86-64) 15)))
(ck! "rv64: 14 value, 9 raw, 31 float (t0, t1, ft11 reserved as scratch)"
     (and (= (value-count arch-rv64) 14) (= (raw-count arch-rv64) 9)
          (= (float-count arch-rv64) 31)))
(ck! "RV64 still has more than twice x86-64's raw registers after reservation"
     (and (> (value-count arch-rv64) (value-count arch-x86-64))
          (> (raw-count arch-rv64) (* 2 (raw-count arch-x86-64)))))

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
                  (iota 8))]
       [names (map (lambda (i) (string->symbol (string-append "w" (number->string i))))
                   (iota 8))]
       ;; one instruction using all nine at once: now they overlap
       [many (append defs (list (append '(add sink raw-word) names)))]
       [cls (make-eq-hashtable)])
  (hashtable-set! cls 'sink 'raw-word)
  (for-each (lambda (i)
              (hashtable-set! cls (string->symbol (string-append "w" (number->string i)))
                              'raw-word))
            (iota 9))
  (let ([r (allocate arch-x86-64 many cls)])
    (ck! "x86-64 spills with 8 simultaneous raw words plus a sink: it has 4"
         (not (null? (alloc-result-spills r)))))
  (let ([r (allocate arch-rv64 many cls)])
    (ck! "RV64 does NOT spill the same program: 8 words plus a sink fit in 9"
         (null? (alloc-result-spills r)))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
