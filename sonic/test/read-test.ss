;;; Tests for the datum reader.
;;;
;;; The acceptance criterion for this bead is not "parses a list": it is that
;;; every datum in bench/nbody round-trips. So the load-bearing half of this
;;; file is the DIFFERENTIAL test against Chez's own `read` over all six Scheme
;;; sources in bench/nbody. Same count, same data, `equal?` element by element.
;;; That is a real oracle rather than a hand-written expectation, and it is the
;;; only way to be sure about 35 flonum constants written as
;;; 4.84143144246472090e+00 whose last bit the whole project depends on.
;;;
;;; The synthetic cases carry the syntax the benchmarks happen not to use
;;; (characters, strings, vectors, dotted pairs, quasiquote), and the negative
;;; cases carry the point that a reader which accepts everything is not a
;;; reader.
;;;
;;; Run: scheme -q --libdirs src:vendor/nanopass --script test/read-test.ss
;;;      (from sonic/)

(import (rnrs base)
        (rnrs lists)
        (rnrs control)
        (rnrs io simple)
        (rnrs exceptions)
        (rnrs files)
        (sonic read))

(define failures 0)
(define checks 0)

(define (check! name ok)
  (set! checks (+ checks 1))
  (unless ok
    (set! failures (+ failures 1))
    (display "FAIL: ") (display name) (newline)))

(define (check-equal! name got want)
  (set! checks (+ checks 1))
  (unless (equal? got want)
    (set! failures (+ failures 1))
    (display "FAIL: ") (display name)
    (display "\n  got:  ") (write got)
    (display "\n  want: ") (write want) (newline)))

;; Reads one datum from a string and compares. `want` is given as a value, so
;; the expectation is written in Chez's reader and checked against ours.
(define (r= name text want)
  (check-equal! name (read-datum-from-string text) want))

;; --- must-fail ------------------------------------------------------------

(define (must-fail name text)
  (set! checks (+ checks 1))
  (let ((result
         (guard (e (#t 'raised))
           (let ((d (read-all-from-string text))) (list 'accepted d)))))
    (unless (eq? result 'raised)
      (set! failures (+ failures 1))
      (display "FAIL: ") (display name)
      (display " -- accepted ") (write text)
      (display " as ") (write (cadr result)) (newline))))

;; --- atoms ------------------------------------------------------------------

(r= "symbol" "abc" 'abc)
(r= "symbol with punctuation" "->fx" '->fx)
(r= "symbol +" "+" '+)
(r= "symbol -" "-" '-)
(r= "symbol ..." "..." '...)
(r= "symbol that starts with a digit-ish prefix" "1+" '|1+|)
(r= "bang symbol" "vector-set!" 'vector-set!)
(r= "piped symbol" "|hello world|" (string->symbol "hello world"))

(r= "exact integer" "42" 42)
(r= "negative integer" "-17" -17)
(r= "explicitly positive integer" "+3" 3)
(r= "hex" "#x1f" 31)
(r= "octal" "#o17" 15)
(r= "binary" "#b1011" 11)
(r= "decimal prefix" "#d99" 99)

(r= "flonum" "0.5" 0.5)
(r= "flonum without leading zero" ".5" 0.5)
(r= "flonum trailing dot" "1." 1.0)
(r= "negative flonum" "-0.01" -0.01)
(r= "exponent, lowercase" "1e3" 1e3)
(r= "exponent, explicit plus" "1.0e+3" 1000.0)
(r= "exponent, negative" "1.0e-3" 0.001)

;; The nbody constants, in the exact notation the sources use. Written out
;; longhand rather than generated, because this is the shape the acceptance
;; criterion is about.
(r= "nbody x1"  "4.84143144246472090e+00"  4.84143144246472090e+00)
(r= "nbody y1"  "-1.16032004402742839e+00" -1.16032004402742839e+00)
(r= "nbody vz1" "-6.90460016972063023e-05" -6.90460016972063023e-05)
(r= "nbody m4"  "5.15138902046611451e-05"  5.15138902046611451e-05)
(r= "nbody x4"  "1.53796971148509165e+01"  1.53796971148509165e+01)
(r= "days-per-year" "365.24" 365.24)
(r= "pi" "3.141592653589793" 3.141592653589793)

;; Same values, checked through their decimal image instead of through eqv?.
;; If the reader ever grows its own decimal-to-binary conversion, this is the
;; test that catches it landing one ulp off.
(check-equal! "flonum is bit-exact, via number->string"
              (number->string (read-datum-from-string "4.84143144246472090e+00"))
              (number->string 4.84143144246472090e+00))
(check-equal! "small negative flonum is bit-exact, via number->string"
              (number->string (read-datum-from-string "-9.51592254519715870e-05"))
              (number->string -9.51592254519715870e-05))

(r= "true" "#t" #t)
(r= "false" "#f" #f)
(r= "true long" "#true" #t)
(r= "false long" "#false" #f)

(r= "char" "#\\a" #\a)
(r= "char open paren" "#\\(" #\()
(r= "char semicolon" "#\\;" #\;)
(r= "char space" "#\\space" #\space)
(r= "char newline" "#\\newline" #\newline)
(r= "char tab" "#\\tab" (integer->char 9))
(r= "char delete" "#\\delete" (integer->char 127))
(r= "char hex scalar" "#\\x41" #\A)
(r= "char literal x" "#\\x" #\x)

(r= "string" "\"hello\"" "hello")
(r= "empty string" "\"\"" "")
(r= "string with escapes" "\"a\\nb\\tc\"" (string #\a #\newline #\b (integer->char 9) #\c))
(r= "string with quote and backslash" "\"a\\\"b\\\\c\"" "a\"b\\c")
(r= "string hex escape" "\"\\x41;BC\"" "ABC")
(r= "string line continuation" "\"one\\\n   two\"" "onetwo")
(r= "string keeps a raw newline" "\"a\nb\"" (string #\a #\newline #\b))

;; --- compound data ----------------------------------------------------------

(r= "empty list" "()" '())
(r= "flat list" "(1 2 3)" '(1 2 3))
(r= "nested list" "(a (b (c)) d)" '(a (b (c)) d))
(r= "dotted pair" "(1 . 2)" '(1 . 2))
(r= "improper list" "(1 2 . 3)" '(1 2 . 3))
(r= "list ending in symbol tail" "(a . b)" '(a . b))
(r= "brackets read as parens" "[1 2 3]" '(1 2 3))
(r= "mixed brackets, nested" "(let ([i 0]) i)" '(let ((i 0)) i))
(r= "newlines inside a list" "(1\n 2\n 3)" '(1 2 3))

(r= "vector" "#(1 2 3)" (vector 1 2 3))
(r= "empty vector" "#()" (vector))
(r= "nested vector" "#(1 #(2 3) a)" (vector 1 (vector 2 3) 'a))
(r= "vector of flonums" "#(0.0 1.5)" (vector 0.0 1.5))

(r= "quote" "'a" '(quote a))
(r= "quote of a list" "'(1 2)" '(quote (1 2)))
(r= "quasiquote and unquote" "`(a ,b)" '(quasiquote (a (unquote b))))
(r= "unquote-splicing" "`(a ,@b)" '(quasiquote (a (unquote-splicing b))))
(r= "nested quote" "''a" '(quote (quote a)))

;; --- comments ---------------------------------------------------------------

(r= "line comment before" "; nothing to see\n42" 42)
(r= "line comment inside a list" "(1 ; two\n 3)" '(1 3))
(r= "block comment" "#| skip me |# 42" 42)
(r= "nested block comment" "#| a #| b |# c |# 42" 42)
(r= "block comment inside a list" "(1 #| two |# 3)" '(1 3))
(r= "datum comment" "#;(a b) 42" 42)
(r= "datum comment inside a list" "(1 #;2 3)" '(1 3))
(r= "datum comment on the last element" "(1 2 #;3)" '(1 2))
(r= "datum comment stacking" "#;1 #;2 3" 3)
(r= "r6rs directive is skipped" "#!r6rs (a b)" '(a b))

(check-equal! "read-all over several data"
              (read-all-from-string "1 (2 3) \"four\" #\\5")
              (list 1 '(2 3) "four" #\5))
(check-equal! "read-all on an empty port" (read-all-from-string "") '())
(check-equal! "read-all on whitespace and comments only"
              (read-all-from-string "  ; nope\n #| nor this |#\n") '())
(check! "read-datum at eof returns the eof object"
        (eof-object? (read-datum-from-string "   ")))
(check! "read-datum after the last datum returns eof"
        (let ((p (open-string-input-port "1")))
          (read-datum p)
          (eof-object? (read-datum p))))

;; --- negative cases ---------------------------------------------------------
;; A reader that accepts everything is not a reader.

(must-fail "unterminated string" "\"abc")
(must-fail "unterminated string escape" "\"abc\\")
(must-fail "unterminated hex escape in a string" "\"\\x41")
(must-fail "unterminated block comment" "#| abc")
(must-fail "unterminated nested block comment" "#| a #| b |# c")
(must-fail "stray close paren" ")")
(must-fail "stray close paren after a datum" "42 )")
(must-fail "stray close bracket" "]")
(must-fail "unterminated list" "(1 2")
(must-fail "unterminated vector" "#(1 2")
(must-fail "mismatched brackets, round then square" "(1 2]")
(must-fail "mismatched brackets, square then round" "[1 2)")
(must-fail "bare dot" ".")
(must-fail "dot with nothing before it" "( . 1)")
(must-fail "dot with nothing after it" "(1 . )")
(must-fail "two data after a dot" "(1 . 2 3)")
(must-fail "unterminated piped symbol" "|abc")
(must-fail "unknown character name" "#\\nosuchthing")
(must-fail "eof after a quote" "'")
(must-fail "eof after a hash" "#")
(must-fail "unknown hash syntax" "#z")
(must-fail "unknown directive" "#!nonsense")
(must-fail "fold-case is refused rather than silently ignored" "#!fold-case abc")
(must-fail "datum comment with nothing to comment out" "#;")
(must-fail "datum comment eating the close paren" "(1 #;)")
(must-fail "malformed boolean" "#trueish")

;; --- the acceptance criterion ----------------------------------------------
;; Differential against Chez's own reader, over the real benchmark sources.

(define (find-bench-dir)
  (let loop ((cands '("../bench/nbody/" "bench/nbody/" "./bench/nbody/")))
    (cond ((null? cands) #f)
          ((file-exists? (string-append (car cands) "config1.scm")) (car cands))
          (else (loop (cdr cands))))))

(define bench-dir (find-bench-dir))

;; The oracle: Chez's `read`, over the same file.
(define (chez-read-all path)
  (let ((p (open-input-file path)))
    (let loop ((acc '()))
      (let ((d (read p)))
        (if (eof-object? d)
            (begin (close-input-port p) (reverse acc))
            (loop (cons d acc)))))))

;; Every flonum in a datum tree, in reading order. Compared through
;; number->string so a differing last bit shows up as text, not as a silent #f.
(define (flonums-of d)
  (let walk ((d d) (acc '()))
    (cond ((pair? d) (walk (cdr d) (walk (car d) acc)))
          ((vector? d)
           (let loop ((i 0) (acc acc))
             (if (= i (vector-length d)) acc (loop (+ i 1) (walk (vector-ref d i) acc)))))
          ((and (number? d) (inexact? d)) (cons (number->string d) acc))
          (else acc))))

(define (round-trip-file! name)
  (let* ((path (string-append bench-dir name))
         (mine (read-all-from-file path))
         (theirs (chez-read-all path)))
    (check-equal! (string-append name ": datum count")
                  (length mine) (length theirs))
    (set! checks (+ checks 1))
    (let loop ((a mine) (b theirs) (i 0))
      (cond ((or (null? a) (null? b)) 'done)
            ((equal? (car a) (car b)) (loop (cdr a) (cdr b) (+ i 1)))
            (else
             (set! failures (+ failures 1))
             (display "FAIL: ") (display name)
             (display " datum ") (display i) (display " differs") (newline)
             (display "  ours:  ") (write (car a)) (newline)
             (display "  chez:  ") (write (car b)) (newline))))
    (let ((fm (reverse (flonums-of mine)))
          (ft (reverse (flonums-of theirs))))
      (check-equal! (string-append name ": every flonum is bit-identical to Chez's")
                    fm ft)
      (display "  ") (display name)
      (display ": ") (display (length mine)) (display " data, ")
      (display (length fm)) (display " flonums") (newline))))

(newline)
(if (not bench-dir)
    (begin
      (display "FAIL: cannot find bench/nbody; run this from sonic/") (newline)
      (set! failures (+ failures 1)))
    (begin
      (display "round-trip against Chez's reader, over bench/nbody:") (newline)
      (for-each round-trip-file!
                '("config1.scm"
                  "config2a.sps"
                  "config2b.sps"
                  "config2c-chez.ss"
                  "config4-chez.ss"
                  "config7-stalin.sc"))))

;; Two spot checks with the expectation written out, so a bug that corrupts
;; both readers identically still gets caught.
(when bench-dir
  (let ((d (read-all-from-file (string-append bench-dir "config1.scm"))))
    (check-equal! "config1.scm first datum" (car d) '(define pi 3.141592653589793))
    (check-equal! "config1.scm last datum" (car (reverse d)) '(main))
    (check! "config1.scm carries the nbody x-coordinate of Jupiter"
            (let scan ((x d))
              (cond ((pair? x) (or (scan (car x)) (scan (cdr x))))
                    ((and (number? x) (inexact? x))
                     (string=? (number->string x)
                               (number->string 4.84143144246472090e+00)))
                    (else #f)))))
  ;; config2a.sps opens with #!r6rs, which is a directive and not a datum:
  ;; the first datum must be the import form.
  (let ((d (read-all-from-file (string-append bench-dir "config2a.sps"))))
    (check-equal! "config2a.sps first datum is the import, not the #!r6rs"
                  (car d)
                  '(import (rnrs base)
                           (rnrs arithmetic flonums)
                           (rnrs programs)
                           (rnrs io simple)
                           (rnrs control)))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
