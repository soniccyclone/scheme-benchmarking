(import (chezscheme) (sonic driver) (sonic finalize) (sonic pipeline))
(define c (compile-sonic "../bench/nbody/config-sonic.sps" nbody-externs))
(for-each (lambda (f)
  (let ((n (length (filter pair? (finalized-listing f)))))
    (when (memq (finalized-name f) '(inner%24.201 outer%22.193 loop%35.293))
      (printf "~22a ~a instrs, ~a spills~n" (finalized-name f) n
              (length (finalized-spills f))))))
  (compiled-functions c))
(printf "total code bytes: ~a~n" (bytevector-length (compiled-code c)))
