;;; Programs that are COMPILED, LINKED, LOADED AND RUN, with their answers
;;; checked against Chez running the same source.
;;;
;;; Every other test in this tree inspects an artifact -- an IR, a listing, a
;;; byte string. This one runs the program. The difference is not academic: the
;;; compiler emitted a complete, disassemblable, byte-verified image for a long
;;; time while being unable to execute a nested loop, because a self-tail-call
;;; skipped its epilogue and leaked a frame per iteration. Nothing that reads
;;; the output can see that. Only running it can.
;;;
;;; x86-64 only, because this machine is x86-64. The RISC-V smoke gate covers
;;; the other target as far as "binutils reads it back", which is a weaker claim
;;; and is honestly labelled as one.

(import (chezscheme) (nanopass)
        (sonic lang) (sonic read) (sonic expand) (sonic parse) (sonic policy)
        (sonic anf) (sonic assign) (sonic inline) (sonic essa) (sonic elide)
        (sonic repr) (sonic lower) (sonic select) (sonic regs) (sonic regalloc)
        (sonic finalize) (sonic litpool) (sonic object) (sonic runtime)
        (sonic elfexec) (sonic globals) (sonic target-x86-64))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok
      (begin (display "  ok   ") (display name) (newline))
      (begin (set! failures (+ failures 1))
             (display "  FAIL ") (display name) (newline))))

(define tmp "/tmp/sonic-run-test")

(define (compile-and-run source externs)
  (let ((src (string-append tmp ".sps")) (exe (string-append tmp ".bin")))
    (let ((p (open-file-output-port src (file-options no-fail)
                                    (buffer-mode block) (native-transcoder))))
      (put-string p source) (close-port p))
    (let* ((p0 (inline-program (assign-convert-program
                (anf-program (resolve-policy-program
                 (parse-program (expand-program (read-all-from-file src)) externs)))))))
      (let*-values (((p1 st) (elide-program (essa-program p0)))
                    ((p2 rp) (select-representations-program p1)))
        (let*-values (((prog lst) (lower-toplevel (unparse-Lrepr p2) 'main
                                                  (repr-report-classes rp))))
          (let* ((classes (lowered-classes))
                 (cells (global-cells (unparse-Lrepr p2)))
                 (prog* (globalize prog cells classes))
                 (entry (caddr prog*))
                 (gaddrs (assign-global-cells
                          (map global-cell-name
                               (vector->list (hashtable-keys cells))))))
            (parameterize ((current-litpool (make-pool))
                           (current-vreg-classes classes)
                           (current-globals gaddrs))
              (let* ((selected (select-program x86-64-selector prog*))
                     (fns (finalize-program 'x86-64 arch-x86-64 selected
                                            (cadr prog*) entry classes (lowered-params)))
                     (listing (append (runtime-listing 'x86-64 entry)
                                      (apply append (map finalized-listing fns))))
                     (pool (pool-bytes (current-litpool)))
                     (extra (map (lambda (l) (cons (pool-label (lit-offset l))
                                                   (lit-offset l)))
                                 (pool-entries (current-litpool))))
                     (o (assemble-function 'x86-64 'prog listing
                                           (list (cons 'constants pool)
                                                 (cons 'extra-labels extra))))
                     (start (let loop ((xs listing) (pc 0))
                              (cond ((null? xs) (error 'run "no _start"))
                                    ((eq? (car xs) '_start) pc)
                                    ((symbol? (car xs)) (loop (cdr xs) pc))
                                    (else (loop (cdr xs)
                                                (+ pc (instruction-size 'x86-64 (car xs))))))))
                     (img (build-executable 'x86-64 (function-object-code o) pool
                                            (+ elf-text-vaddr start)
                                            #x600000 runtime-data-size)))
                (write-executable exe img)
                (system (string-append "chmod +x " exe))
                (let ((code (system (string-append exe " > " tmp ".out 2>/dev/null"))))
                  (values code (read-doubles (string-append tmp ".out"))))))))))))

;; `display` writes a double's eight raw bytes -- see runtime.ss on why that is
;; the right thing for an oracle -- so the output is read back as doubles.
(define (read-doubles path)
  (let* ((p (open-file-input-port path))
         (bv (get-bytevector-all p)))
    (close-port p)
    (if (eof-object? bv)
        '()
        (let loop ((i 0) (acc '()))
          (if (>= (+ i 8) (+ (bytevector-length bv) 1))
              (reverse acc)
              (loop (+ i 8)
                    (cons (bytevector-ieee-double-ref bv i (endianness little))
                          acc)))))))

(define (run! name source expected)
  (let-values (((code out) (compile-and-run source '(display newline))))
    (ck! name (and (zero? code) (equal? out expected)))
    (unless (and (zero? code) (equal? out expected))
      (display "       exit=") (display code)
      (display " got=") (write out)
      (display " want=") (write expected) (newline))))

(run! "a literal double survives compilation, linking and execution"
      "(define (main) (display 1.5) (newline))\n(main)\n"
      '(1.5))

(run! "arithmetic on doubles"
      "(define (main) (display (fl* (fl+ 1.5 2.5) 2.0)) (newline))\n(main)\n"
      '(8.0))

(run! "a global holding a double"
      "(define x 3.25)\n(define (main) (display x) (newline))\n(main)\n"
      '(3.25))

(run! "an flvector: allocated by the runtime, indexed by compiled code"
      "(define v (make-flvector 3 2.5))\n(define (main) (display (flvector-ref v 1)) (newline))\n(main)\n"
      '(2.5))

(run! "a store loop over a global vector"
      (string-append
       "(define v (make-flvector 4 0.0))\n"
       "(define (fill! i)\n"
       "  (if (fx= i 4) 0.0 (begin (flvector-set! v i (fx->fl i)) (fill! (fx+ i 1)))))\n"
       "(define (main) (fill! 0) (display (flvector-ref v 3)) (newline))\n(main)\n")
      '(3.0))

;; A tail-recursive accumulator. This is the loop shape the whole benchmark is
;; built from, and it is where proper tail calls stop being a language-lawyer
;; point: without them the frame grows per iteration.
(run! "a tail-recursive accumulator"
      (string-append
       "(define (sum i acc) (if (fx= i 5) acc (sum (fx+ i 1) (fl+ acc 1.5))))\n"
       "(define (main) (display (sum 0 0.0)) (newline))\n(main)\n")
      '(7.5))

;; NESTED loops: an outer loop whose body makes an ordinary call to an inner
;; one. This is what caught the frame leak -- `outer` tail-calls ITSELF, so the
;; jump lands on its own entry label, and treating that as an intra-function
;; edge skipped the epilogue while the prologue kept reserving frames.
(run! "nested loops: a self-tail-call must still release its frame"
      (string-append
       "(define n 3)\n"
       "(define (inner i j acc) (if (fx= j n) acc (inner i (fx+ j 1) (fl+ acc 1.0))))\n"
       "(define (outer i acc) (if (fx= i n) acc (outer (fx+ i 1) (inner i 0 acc))))\n"
       "(define (main) (display (outer 0 0.0)) (newline))\n(main)\n")
      '(9.0))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
