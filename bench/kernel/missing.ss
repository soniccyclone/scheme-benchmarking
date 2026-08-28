;;; What each fixture asks for that the compiler does not have.
;;;
;;; `compile-all.sh` reports one complaint per program, whichever the parser
;;; reaches first, and that is an accident of traversal order rather than a
;;; ranking. This asks the compiler the whole question: take its complaint, feed
;;; the name back as an extern, and ask again, until it stops finding new ones.
;;; The compiler is the oracle for its own surface -- CUJ-08's rule, applied to
;;; the gap instead of the inventory.
(import (chezscheme) (sonic driver) (sonic pipeline))

(define (irritant-of c)
  (and (irritants-condition? c)
       (let ((i (condition-irritants c)))
         (and (pair? i) (car i)))))

(define (message-of c)
  (if (message-condition? c) (condition-message c) "?"))

;; Ask once. Returns 'ok, a symbol (a name it wants declared), or a string (a
;; complaint no extern will fix).
(define (ask path externs out)
  (guard (c (#t (let ((m (message-of c)) (i (irritant-of c)))
                  (if (and (symbol? i)
                           (string=? m "unbound variable; if it is outside this compilation unit, name it in the extern list"))
                      i
                      (string-append m
                                     (if i (string-append " [" (format "~a" i) "]") ""))))))
    (compile-sonic-to-file path externs out)
    'ok))

(define (probe path out)
  (let loop ((externs '(display newline)) (found '()))
    (let ((r (ask path externs out)))
      (cond
       ((eq? r 'ok) (values (reverse found) "COMPILES"))
       ((symbol? r) (loop (cons r externs) (cons r found)))
       (else (values (reverse found) r))))))

(let ((out (string-append (or (getenv "TMPDIR") "/tmp") "/kernel-probe.bin")))
  (for-each
   (lambda (path)
     (let-values (((names stop) (probe path out)))
       (printf "~a\n" path)
       (printf "  wants:  ~a\n" (if (null? names) "(nothing)" names))
       (printf "  stops:  ~a\n\n" stop)))
   (sort string<? (map (lambda (p) (string-append "/work/bench/kernel/" p))
                       (filter (lambda (p) (and (> (string-length p) 4)
                                                (string=? ".sps" (substring p (- (string-length p) 4)
                                                                            (string-length p)))))
                               (directory-list "/work/bench/kernel"))))))
