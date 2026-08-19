;;; PROBE 3: the authoritative primitive surface, asked of the compiler rather
;;; than grepped. Greps disagreed with each other twice and with reality once
;;; (fxquotient compiles but appears in no define-prim).
(import (chezscheme) (sonic prims))
(let ((ns (sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
                (prim-names))))
  (printf "~a primitives:\n" (length ns))
  (for-each (lambda (n) (printf "~a " n)) ns)
  (newline))
