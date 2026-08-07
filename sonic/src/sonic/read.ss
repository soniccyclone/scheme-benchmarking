;;; SonicScheme: the datum reader.
;;;
;;; Stage 02. Text in, s-expressions out. R7RS section 7.1.2 datum syntax, with
;;; the R6RS bracket extension, because bench/nbody/config4-chez.ss writes
;;; `(let ([i 0]) ...)` and Chez has always read a bracket as a paren.
;;;
;;; Recursive descent straight over the port. No token stream, no buffering
;;; beyond one character of lookahead: `lookahead-char` plus `get-char` is
;;; exactly the LL(1) window datum syntax needs, and the one place it is not
;;; enough (`#` followed by `|` or `;` or `!` is atmosphere, everything else is
;;; a datum) is handled by consuming the `#` and dispatching, not by pushing a
;;; character back.
;;;
;;; ONE DELEGATION, and it is deliberate. Token classification is ours: this
;;; file decides where an atom ends and whether the result is a number or a
;;; symbol. Converting the digits of a number token to a value is NOT ours; we
;;; hand the token to `string->number`. The benchmark sources carry constants
;;; like 4.84143144246472090e+00 and the whole project rests on bit-exact
;;; agreement across implementations, so the decimal-to-binary conversion has to
;;; be correctly rounded. That is Clinger's algorithm (PLDI 1990), it is a
;;; research problem in its own right, and Chez already ships a correct one.
;;; Writing a second, worse one here would silently move the last bit of every
;;; constant in the benchmark. See read-test.ss, which pins this.
;;;
;;; Run the tests: scheme -q --libdirs src:vendor/nanopass --script test/read-test.ss

(library (sonic read)
  (export read-datum read-all
          read-datum-from-string read-all-from-string read-all-from-file)
  (import (rnrs base)
          (rnrs lists)
          (rnrs control)
          (rnrs unicode)
          (rnrs io ports)
          (only (rnrs bytevectors) u8-list->bytevector)
          (only (rnrs io simple) open-input-file close-input-port))

  ;; --- errors ---------------------------------------------------------------
  ;; A reader that accepts everything is not a reader. Every malformed input
  ;; below raises rather than returning a plausible-looking datum.

  (define (rd-error msg . irritants)
    (apply error 'read-datum msg irritants))

  ;; --- internal markers -----------------------------------------------------
  ;;
  ;; The recursive descent has to report three things upward that are not data:
  ;; a closing bracket, a dot, and "that was atmosphere, ask again". Fresh pairs
  ;; are used as the sentinels because nothing a user can write is `eq?` to one,
  ;; so no real datum can be mistaken for a marker.

  (define close-round  (list 'close #\)))
  (define close-square (list 'close #\]))
  (define dot-marker   (list 'dot))
  (define atmosphere   (list 'atmosphere))

  (define (close-marker? d) (or (eq? d close-round) (eq? d close-square)))
  (define (closer-char d) (cadr d))
  (define (non-datum? d) (or (close-marker? d) (eq? d dot-marker) (eof-object? d)))

  ;; --- character classes ----------------------------------------------------

  (define (delimiter? c)
    (or (eof-object? c)
        (char-whitespace? c)
        (memv c '(#\( #\) #\[ #\] #\" #\; #\|))))

  (define (intraline-whitespace? c)
    (and (char? c) (or (char=? c #\space) (char=? c (integer->char 9)))))

  ;; --- atmosphere -----------------------------------------------------------

  (define (skip-line p)
    (let loop ()
      (let ((c (get-char p)))
        (cond ((eof-object? c) 'done)
              ((char=? c #\newline) 'done)
              (else (loop))))))

  ;; Nested, per R7RS. Depth counting rather than a regex over "|#", because
  ;; `#| a #| b |# c |#` is one comment and a non-nesting scanner ends it early.
  (define (skip-block-comment p depth)
    (if (= depth 0)
        'done
        (let ((c (get-char p)))
          (cond
            ((eof-object? c) (rd-error "unterminated block comment"))
            ((and (char=? c #\|) (eqv? (lookahead-char p) #\#))
             (get-char p) (skip-block-comment p (- depth 1)))
            ((and (char=? c #\#) (eqv? (lookahead-char p) #\|))
             (get-char p) (skip-block-comment p (+ depth 1)))
            (else (skip-block-comment p depth))))))

  ;; Whitespace and line comments only. The `#`-introduced kinds cannot be
  ;; skipped here without two characters of lookahead, so read-expr handles them.
  (define (skip-blank p)
    (let loop ()
      (let ((c (lookahead-char p)))
        (cond ((eof-object? c) 'done)
              ((char-whitespace? c) (get-char p) (loop))
              ((char=? c #\;) (skip-line p) (loop))
              (else 'done)))))

  ;; --- atoms ----------------------------------------------------------------

  (define (read-atom p)
    (let loop ((acc '()))
      (let ((c (lookahead-char p)))
        (if (delimiter? c)
            (list->string (reverse acc))
            (begin (get-char p) (loop (cons c acc)))))))

  ;; `.` is a token, not a symbol; the list reader is the only context that
  ;; accepts it. Everything else is a number if string->number says so and a
  ;; symbol otherwise, which is precisely R7RS 7.1.1: the symbol production is
  ;; the complement of the number production, not an independent grammar.
  (define (atom->datum s)
    (cond ((string=? s ".") dot-marker)
          ((string->number s))
          (else (string->symbol s))))

  ;; --- characters -----------------------------------------------------------

  (define char-names
    (list (cons "alarm"     (integer->char 7))
          (cons "backspace" (integer->char 8))
          (cons "delete"    (integer->char 127))
          (cons "escape"    (integer->char 27))
          (cons "esc"       (integer->char 27))
          (cons "linefeed"  (integer->char 10))
          (cons "newline"   (integer->char 10))
          (cons "null"      (integer->char 0))
          (cons "nul"       (integer->char 0))
          (cons "page"      (integer->char 12))
          (cons "return"    (integer->char 13))
          (cons "space"     (integer->char 32))
          (cons "tab"       (integer->char 9))))

  (define (read-character p)
    (let ((c (get-char p)))
      (when (eof-object? c) (rd-error "eof in character literal"))
      (let ((rest (read-atom p)))
        (if (string=? rest "")
            c                                   ; #\a, #\(, #\; and friends
            (let* ((name (string-append (string c) rest))
                   (named (assoc name char-names)))
              (cond
                (named (cdr named))
                ((and (char=? c #\x) (string->number rest 16))
                 => (lambda (n)
                      (if (and (exact? n) (integer? n) (>= n 0) (<= n #x10FFFF)
                               (not (and (>= n #xD800) (<= n #xDFFF))))
                          (integer->char n)
                          (rd-error "character scalar value out of range" name))))
                (else (rd-error "unknown character name" name))))))))

  ;; --- strings --------------------------------------------------------------

  (define (read-hex-escape p)
    (let loop ((acc '()))
      (let ((c (get-char p)))
        (cond
          ((eof-object? c) (rd-error "eof in \\x escape"))
          ((char=? c #\;)
           (let ((n (string->number (list->string (reverse acc)) 16)))
             (if (and n (exact? n) (integer? n) (>= n 0) (<= n #x10FFFF))
                 (integer->char n)
                 (rd-error "bad \\x escape"))))
          (else (loop (cons c acc)))))))

  ;; Returns a character, or 'nothing for a line continuation.
  (define (read-escape p)
    (let ((c (get-char p)))
      (cond
        ((eof-object? c) (rd-error "eof in string escape"))
        ((char=? c #\a) (integer->char 7))
        ((char=? c #\b) (integer->char 8))
        ((char=? c #\t) (integer->char 9))
        ((char=? c #\n) (integer->char 10))
        ((char=? c #\v) (integer->char 11))
        ((char=? c #\f) (integer->char 12))
        ((char=? c #\r) (integer->char 13))
        ((char=? c #\") #\")
        ((char=? c #\\) #\\)
        ((char=? c #\|) #\|)
        ((char=? c #\x) (read-hex-escape p))
        ;; \ <intraline ws>* <newline> <intraline ws>*  produces nothing.
        ((or (char=? c #\newline) (intraline-whitespace? c))
         (when (intraline-whitespace? c)
           (let skip ()
             (when (intraline-whitespace? (lookahead-char p)) (get-char p) (skip)))
           (let ((nl (get-char p)))
             (unless (and (char? nl) (char=? nl #\newline))
               (rd-error "expected newline in string line continuation"))))
         (let skip ()
           (when (intraline-whitespace? (lookahead-char p)) (get-char p) (skip)))
         'nothing)
        (else (rd-error "unknown string escape" c)))))

  (define (read-string-literal p)
    (let loop ((acc '()))
      (let ((c (get-char p)))
        (cond
          ((eof-object? c) (rd-error "unterminated string"))
          ((char=? c #\") (list->string (reverse acc)))
          ((char=? c #\\)
           (let ((e (read-escape p)))
             (if (eq? e 'nothing) (loop acc) (loop (cons e acc)))))
          (else (loop (cons c acc)))))))

  (define (read-pipe-symbol p)
    (let loop ((acc '()))
      (let ((c (get-char p)))
        (cond
          ((eof-object? c) (rd-error "unterminated |symbol|"))
          ((char=? c #\|) (string->symbol (list->string (reverse acc))))
          ((char=? c #\\)
           (let ((e (read-escape p)))
             (if (eq? e 'nothing) (loop acc) (loop (cons e acc)))))
          (else (loop (cons c acc)))))))

  ;; --- compound data --------------------------------------------------------

  (define (append-reverse! rev tail)
    (let loop ((r rev) (t tail))
      (if (null? r) t (loop (cdr r) (cons (car r) t)))))

  (define (read-list p closer)
    (let loop ((acc '()))
      (let ((d (read-expr p)))
        (cond
          ((eof-object? d) (rd-error "unterminated list"))
          ((close-marker? d)
           (if (char=? (closer-char d) closer)
               (reverse acc)
               (rd-error "mismatched bracket" (closer-char d) closer)))
          ((eq? d dot-marker)
           (when (null? acc) (rd-error "dot with nothing before it"))
           (let ((tail (read-expr p)))
             (when (non-datum? tail) (rd-error "missing datum after dot"))
             (let ((end (read-expr p)))
               (unless (and (close-marker? end) (char=? (closer-char end) closer))
                 (rd-error "more than one datum after dot"))
               (append-reverse! acc tail))))
          (else (loop (cons d acc)))))))

  (define (read-vector p closer)
    (let ((elems (read-list p closer)))
      (list->vector elems)))

  (define (read-bytevector p closer)
    (let ((elems (read-list p closer)))
      (for-each (lambda (n)
                  (unless (and (integer? n) (exact? n) (>= n 0) (<= n 255))
                    (rd-error "bytevector element out of range" n)))
                elems)
      (u8-list->bytevector elems)))

  (define (wrap sym p)
    (let ((d (read-expr p)))
      (when (non-datum? d) (rd-error "missing datum after quote-like prefix" sym))
      (list sym d)))

  ;; --- the # dispatcher -----------------------------------------------------
  ;; Called with the `#` already consumed. Returns `atmosphere` for the three
  ;; comment/directive forms, and read-expr loops.

  (define (expect-tail p want what)
    (let ((rest (read-atom p)))
      (unless (or (string=? rest "") (string-ci=? rest want))
        (rd-error "malformed literal" what rest))))

  (define directives '("r6rs" "r7rs"))

  (define (read-hash p)
    (let ((c (get-char p)))
      (cond
        ((eof-object? c) (rd-error "eof after #"))
        ((char=? c #\() (read-vector p #\)))
        ((char=? c #\\) (read-character p))
        ((char=? c #\|) (skip-block-comment p 1) atmosphere)
        ((char=? c #\;)
         (let ((d (read-expr p)))
           (when (non-datum? d) (rd-error "missing datum after #;")))
         atmosphere)
        ((char=? c #\!)
         (let ((name (read-atom p)))
           (cond
             ((member name directives) atmosphere)
             ;; Recognized, and refused. Honouring these means folding the case
             ;; of every symbol read from this port afterwards. Accepting the
             ;; directive and not folding would silently read a different
             ;; program than the one on disk, so this fails loudly instead.
             ((or (string=? name "fold-case") (string=? name "no-fold-case"))
              (rd-error "case-folding directives are not supported" name))
             (else (rd-error "unknown #! directive" name)))))
        ((char-ci=? c #\t) (expect-tail p "rue" "#t") #t)
        ((char-ci=? c #\f) (expect-tail p "alse" "#f") #f)
        ((char-ci=? c #\u)
         (let ((eight (get-char p)) (open (get-char p)))
           (unless (and (eqv? eight #\8) (eqv? open #\())
             (rd-error "malformed bytevector prefix"))
           (read-bytevector p #\))))
        ;; Radix and exactness prefixes: the `#` is part of the number token.
        ((memv (char-downcase c) '(#\e #\i #\b #\o #\d #\x))
         (let* ((text (string-append "#" (string c) (read-atom p)))
                (n (string->number text)))
           (or n (rd-error "malformed number literal" text))))
        (else (rd-error "unknown # syntax" c)))))

  ;; --- the core reader ------------------------------------------------------

  (define (read-expr p)
    (let restart ()
      (skip-blank p)
      (let ((c (lookahead-char p)))
        (cond
          ((eof-object? c) c)
          ((char=? c #\() (get-char p) (read-list p #\)))
          ((char=? c #\[) (get-char p) (read-list p #\]))
          ((char=? c #\)) (get-char p) close-round)
          ((char=? c #\]) (get-char p) close-square)
          ((char=? c #\") (get-char p) (read-string-literal p))
          ((char=? c #\|) (get-char p) (read-pipe-symbol p))
          ((char=? c #\') (get-char p) (wrap 'quote p))
          ((char=? c #\`) (get-char p) (wrap 'quasiquote p))
          ((char=? c #\,)
           (get-char p)
           (if (eqv? (lookahead-char p) #\@)
               (begin (get-char p) (wrap 'unquote-splicing p))
               (wrap 'unquote p)))
          ((char=? c #\#)
           (get-char p)
           (let ((d (read-hash p)))
             (if (eq? d atmosphere) (restart) d)))
          (else (atom->datum (read-atom p)))))))

  ;; --- entry points ---------------------------------------------------------

  ;; One datum, or the eof object. A stray `)` or a bare `.` is an error here
  ;; rather than a value, which is the only reason the markers exist.
  (define (read-datum p)
    (let ((d (read-expr p)))
      (cond
        ((close-marker? d) (rd-error "unexpected close bracket" (closer-char d)))
        ((eq? d dot-marker) (rd-error "unexpected . outside a list"))
        (else d))))

  (define (read-all p)
    (let loop ((acc '()))
      (let ((d (read-datum p)))
        (if (eof-object? d) (reverse acc) (loop (cons d acc))))))

  (define (read-datum-from-string s) (read-datum (open-string-input-port s)))
  (define (read-all-from-string s) (read-all (open-string-input-port s)))

  (define (read-all-from-file path)
    (let* ((p (open-input-file path))
           (data (read-all p)))
      (close-input-port p)
      data))
  )
