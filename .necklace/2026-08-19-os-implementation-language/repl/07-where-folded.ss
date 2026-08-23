;;; PROBE 7: at which IR level do the two reads become one value?
;;; Probe 6 showed the add already says (t.5 t.5) before Lmach CSE, so the fold
;;; is upstream. Volatile has to be honoured wherever that is.
;;; FALSIFIABLE: if the earliest stage already shows one value, the fold is in
;;; the front end; if a later one does, it is that pass.
(import (chezscheme) (sonic driver))
(parameterize ((compile-stage-hook
                (lambda (name p)
                  (let ((refs 0) (adds '()))
                    (let walk ((x p))
                      (cond ((and (pair? x) (memq (car x) '(vector-ref primcall)))
                             (set! refs (+ refs 1)) (for-each walk (cdr x)))
                            ((and (pair? x) (eq? (car x) 'add))
                             (set! adds (cons (cddr x) adds)) (for-each walk (cdr x)))
                            ((pair? x) (walk (car x)) (walk (cdr x)))
                            (else #f)))
                    (printf "~22a primcalls=~a adds=~a\n" name refs (reverse adds))))))
  (compile-sonic "/work/.necklace/2026-08-19-os-implementation-language/repl/01-mmio-double-read.sps"
                 '(display newline) 'x86-64))
