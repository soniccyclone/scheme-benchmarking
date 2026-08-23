;;; PROBE 6: is CSE involved in folding the double read, or is DCE alone?
;;; Decides whether volatile must be honoured by one pass or two.
;;; Capture the program CSE is handed, run CSE on it, and read the result.
;;; FALSIFIABLE: if the two loads still feed the add through DIFFERENT vregs
;;; after CSE, then CSE is not involved and DCE folds alone.
(import (chezscheme) (sonic driver) (sonic cse))
(define captured #f)
(parameterize ((compile-stage-hook
                (lambda (name p)
                  (when (and (eq? name 'lmach/pre-cse) (not captured))
                    (set! captured p)))))
  (compile-sonic "/work/.necklace/2026-08-19-os-implementation-language/repl/01-mmio-double-read.sps"
                 '(display newline) 'x86-64))
(define (blocks-with-loads p tag)
  (let walk ((x p))
    (when (pair? x)
      (when (eq? (car x) 'block)
        (let ((is (cadr x)))
          (when (>= (length (filter (lambda (i) (and (pair? i) (memq (car i) '(load load-at)))) is)) 2)
            (printf "--- ~a ---\n" tag)
            (for-each (lambda (i) (printf "   ~a\n" i)) is))))
      (for-each walk (cdr x))
      (walk (car x)))))

(let-values (((after st) (cse-program captured)))
  (printf "cse folded=~a invalidations=~a\n"
          (cse-stats-folded st) (cse-stats-invalidations st))
  (blocks-with-loads captured "BEFORE cse")
  (blocks-with-loads after "AFTER cse"))
