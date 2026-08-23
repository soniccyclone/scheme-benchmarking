;;; PROBE 5: WHICH pass removes the second read?
;;; The volatile control has to be honoured by whichever passes can delete or
;;; move a load. Guessing gives a list; the stage hook gives the answer.
;;; FALSIFIABLE: if two loads survive to the final listing stage, no pass folds.
(import (chezscheme) (sonic driver) (sonic finalize))
(define (count-loads p)
  (let ((n 0))
    (let walk ((x p))
      (cond ((and (pair? x) (memq (car x) '(load load-at))) (set! n (+ n 1))
             (for-each walk (cdr x)))
            ((pair? x) (walk (car x)) (walk (cdr x)))
            (else #f)))
    n))
(parameterize ((compile-stage-hook
                (lambda (name p)
                  (when (memq name '(lssa/pre-elide lmach/pre-cse lmach/addrfold lmach/dce))
                    (printf "~24a loads=~a\n" name (count-loads p))))))
  (compile-sonic "/work/.necklace/2026-08-19-os-implementation-language/repl/01-mmio-double-read.sps"
                 '(display newline) 'x86-64))
