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
        (sonic elfexec) (sonic globals) (sonic target-x86-64) (sonic driver) (sonic pipeline))

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
    ;; ONE driver, shared with the build. There used to be a second copy of the
    ;; pipeline here, and it drifted: lambda lifting and the constant pool's
    ;; alignment padding went into the build and not into this file, so the test
    ;; compiled a different program from the one being shipped and reported five
    ;; failures the shipped program did not have.
    (compile-sonic-to-file src externs exe)
    (system (string-append "chmod +x " exe))
    ;; TIMEOUT, because this compiler emits programs that loop forever.
    ;;
    ;; That is not hypothetical: a self-tail-call once skipped its epilogue and
    ;; leaked a frame per iteration, and a lost loop-control value turned an
    ;; ordinary `when` into a spin. A bare `(system exe)` on either of those
    ;; hangs the suite with no output and no clue -- which is what had runs
    ;; being launched on top of each other in the first place.
    ;;
    ;; 20s is far longer than any program here needs; exit 124 says "hung",
    ;; which is a result rather than a silence.
    (let ((code (system (string-append "timeout --signal=KILL 20 "
                                       exe " > " tmp ".out 2>/dev/null"))))
      (values code (read-doubles (string-append tmp ".out"))))))

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

;; THE BENCHMARK ITSELF, as far as it currently gets.
;;
;; nbody's initial energy is the first oracle check in docs/METHOD.md, and it
;; is exact: the compiled program agrees with Chez running the same source to
;; the last bit. That covers init!, offset-momentum! and energy -- allocation,
;; an eight-argument call, nested tail-recursive loops, indexed loads and
;; stores, and IEEE negation through a pooled sign mask.
;;
;; `advance!` is NOT yet correct and is tracked separately, so this asserts the
;; part that is. Asserting less than is true would be as bad as asserting more:
;; the initial energy landing exactly is the strongest single piece of evidence
;; the compiler has, and leaving it unasserted invites a regression nobody sees.
(let-values (((code out)
              (compile-and-run
               (string-append
                (call-with-input-file "../bench/nbody/config-sonic.sps"
                  (lambda (p)
                    (let loop ((acc '()))
                      (let ((l (get-line p)))
                        (if (eof-object? l)
                            (apply string-append (reverse acc))
                            (loop (cons (string-append l "\n") acc)))))))
                "")
               nbody-externs)))
  (ck! "nbody's INITIAL energy is bit-exact against Chez on the same source"
       (and (pair? out) (= (car out) -0.16907516382852447)))
  (unless (and (pair? out) (= (car out) -0.16907516382852447))
    (display "       got=") (write out) (newline)))

;; DETERMINISM. The same source must produce the same bytes.
;;
;; It did not. Three compiles of one program gave three different images,
;; because `hashtable-keys` has no promised order and that order reached the
;; global cell ADDRESSES and the register allocator's tie-breaking. The damage
;; was not just theoretical: D24's oracle is bit-exact cross-agreement, which a
;; nondeterministic compiler cannot have, and debugging was unsound -- a latent
;; bug appeared and vanished between runs, so a passing test proved nothing.
;;
;; Asserted on bytes rather than on behaviour, because behaviour is exactly what
;; hid it: two different images computed the same answer often enough to look
;; fine.
(let* ((src (string-append tmp "-det.sps"))
       (a (string-append tmp "-det-a.bin"))
       (b (string-append tmp "-det-b.bin")))
  (let ((p (open-file-output-port src (file-options no-fail)
                                  (buffer-mode block) (native-transcoder))))
    (put-string p (string-append
                   "(define n 3)\n"
                   "(define V (make-flvector 4 0.0))\n"
                   "(define (go)\n"
                   "  (let outer ((i 0))\n"
                   "    (when (fx< i n)\n"
                   "      (let inner ((j (fx+ i 1)))\n"
                   "        (when (fx< j n)\n"
                   "          (flvector-set! V 0 (fl+ (flvector-ref V 0) 1.0))\n"
                   "          (inner (fx+ j 1))))\n"
                   "      (outer (fx+ i 1)))))\n"
                   "(define (main) (go) (display (flvector-ref V 0)) (newline))\n"
                   "(main)\n"))
    (close-port p))
  (compile-sonic-to-file src '(display newline) a)
  (compile-sonic-to-file src '(display newline) b)
  (ck! "the same source compiles to the same bytes, twice running"
       (let ((x (call-with-port (open-file-input-port a) get-bytevector-all))
             (y (call-with-port (open-file-input-port b) get-bytevector-all)))
         (equal? x y))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
