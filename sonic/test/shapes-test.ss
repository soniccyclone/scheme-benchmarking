;;; Tests for shapes.ss -- where a vector's LENGTH and a constant's VALUE come from.
;;;
;;; WHY THIS FILE EXISTS. It did not, and shapes.ss is the pass that supplies
;;; the premises every discharged bounds check rests on. driver.ss calls it
;;; "REQUIRED rather than nice": the interval domain always had the arithmetic
;;; for nbody's inner loop and none of the facts, so it kept 18 checks in the
;;; hot loop until this pass connected a vector to the `make-flvector` that
;;; produced it and read `(define n-bodies 5)` as a constant.
;;;
;;; That makes it dangerous in BOTH directions, which is why the refusals below
;;; matter as much as the derivations. A fact this pass stops deriving turns
;;; into checks nobody notices except as a slow program. A fact it derives
;;; WRONGLY turns into a check removed that was needed -- the unsound-domain
;;; failure D24 says the eleven-way cross-agreement exists to catch, and the
;;; symptom is a value that is only slightly wrong.
;;;
;;; The input is an unparsed Lssa datum, which is what `elide-to-fixpoint`
;;; hands it. `(top ([x e] ...) (extern ...) body)`.

(import (chezscheme) (sonic shapes))

(define checks 0)
(define failures 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok
      (begin (display "  ok   ") (display name) (newline))
      (begin (display "  FAIL ") (display name) (newline)
             (set! failures (+ failures 1)))))

(define (fact-for facts x)
  (let find ((fs facts))
    (cond ((null? fs) #f)
          ((eq? (car (car fs)) x) (car fs))
          (else (find (cdr fs))))))

(display "\n-- constants --\n")

;; `(define n-bodies 5)` must read as the interval [5,5]. Every loop bound in
;; nbody is opaque without this.
(let ((facts (shape-facts '(top ([n-bodies (quote 5)]) (display) n-bodies))))
  (ck! "a top-level literal becomes a point interval"
       (equal? (fact-for facts 'n-bodies) '(n-bodies interval 5 5))))

;; A non-literal initializer is NOT a constant. Reading it as one would invent
;; a premise, which is the direction that deletes a needed check.
(let ((facts (shape-facts '(top ([n (primcall read-argument () x)]) (display) n))))
  (ck! "an initializer that is not a literal yields no interval"
       (not (fact-for facts 'n))))

(display "\n-- vector lengths --\n")

;; ANF names every operand, so a definition's value is a `let` chain ending in
;; the temporary that holds the allocation. The pass has to follow that tail or
;; the fact lands on the temporary and never reaches the call sites.
(define anf-alloc
  '(top ([pos (let ([t.1 (quote 15)])
                (let ([t.2 (primcall make-flvector () t.1 (quote 0.0))])
                  t.2))])
        (display)
        pos))

(let ((facts (shape-facts anf-alloc)))
  (ck! "make-flvector through an ANF let chain gives its binding a length"
       (equal? (fact-for facts 'pos) '(pos flvector 15)))
  ;; THE POINT OF THE TAIL WALK. The fact must reach the DEFINE's name, because
  ;; that is the only name call sites pass. A fact on the temporary alone would
  ;; satisfy "a length was derived" and be useless. (It lands on both, which is
  ;; harmless -- the temporary really is that vector.)
  (ck! "the temporary is shaped too, which is consistent rather than a problem"
       (equal? (fact-for facts 't.2) '(t.2 flvector 15))))

(let ((facts (shape-facts
              '(top ([v (let ([t.1 (quote 4)])
                          (let ([t.2 (primcall make-vector () t.1 (quote 0))])
                            t.2))])
                    (display)
                    v))))
  (ck! "make-vector is distinguished from make-flvector"
       (equal? (fact-for facts 'v) '(v vector 4))))

;; A size that is not a known constant must yield NO length. This is the
;; refusal that keeps the pass sound: a guessed length is a deleted check.
(let ((facts (shape-facts
              '(top ([n (primcall read-argument () x)]
                     [v (let ([t.2 (primcall make-flvector () n (quote 0.0))])
                          t.2)])
                    (display)
                    v))))
  ;; The KIND is still known and still useful -- it discharges type checks --
  ;; but the fact carries no LENGTH, so no index against it can be proved.
  ;; elide.ss's `fact-lengths` guards on `(pair? (cddr f))` for exactly this,
  ;; so a length-less fact is the designed shape rather than a malformed one.
  (ck! "an allocation whose size is unknown yields a KIND but no length"
       (let ((f (fact-for facts 'v)))
         (and f (eq? (cadr f) 'flvector) (null? (cddr f))))))

(display "\n-- copies carry the fact --\n")

(let ((facts (shape-facts
              '(top ([pos (let ([t.1 (quote 15)])
                            (let ([t.2 (primcall make-flvector () t.1 (quote 0.0))])
                              t.2))]
                     [alias pos])
                    (display)
                    alias))))
  (ck! "a binding copied from a shaped one carries the shape"
       (equal? (fact-for facts 'alias) '(alias flvector 15))))

(display "\n-- procedure-params --\n")

;; The interprocedural half. Knowing `pos` is 15 long is not enough: nbody's
;; kernels take the vectors as PARAMETERS, so a fact that stops at the
;; allocation never reaches the loop that needs it.
;; It hands back a HASHTABLE keyed by procedure name, not an alist.
(let ((ps (procedure-params
           '(top ([f (lambda (a b) a)]) (display) (call f (quote 1) (quote 2))))))
  (ck! "procedure-params finds a top-level lambda's parameters"
       (equal? (hashtable-ref ps 'f #f) '(a b)))
  (ck! "and reports nothing for a name that is not a procedure"
       (not (hashtable-ref ps 'nosuch #f))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
