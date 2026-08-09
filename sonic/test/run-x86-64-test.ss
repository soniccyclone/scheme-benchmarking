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
    ;;
    ;; NO `--signal=KILL`, AND DO NOT ADD IT BACK -- see the note on the
    ;; ENTRYPOINT in the Dockerfile. `timeout` in this image is uutils
    ;; coreutils, whose `--signal=KILL` does not deliver the signal: it waits
    ;; for the child to exit and only then reports 124. Written that way this
    ;; guard did nothing, and a miscompile that looped for ever stalled the
    ;; whole suite with no output rather than failing this one check. The
    ;; default SIGTERM works; an emitted binary installs no handlers and cannot
    ;; decline it.
    (let ((code (system (string-append "timeout 20 "
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
  ;; ANNOUNCED BEFORE IT RUNS, not after it passes. The last line of a stalled
  ;; log used to name the last check that SUCCEEDED, so the one that hung had to
  ;; be inferred from this file -- and a compile that loops has no 20-second
  ;; guard on it at all, since that one bounds only the emitted program.
  ;; `flush-output-port` because a hang is exactly the case where the buffer
  ;; never drains on its own.
  (display "       running: ") (display name) (newline)
  (flush-output-port (current-output-port))
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
;; TWO ORDERING BUGS THAT INTERPROCEDURAL CLOBBER SETS MADE REACHABLE, both of
;; which produced a program that looped for ever rather than one that answered
;; wrongly. Both were latent for the same reason: while every value live across
;; a call was spilled, the values these rules mishandle were in frame slots, and
;; neither rule can go wrong about memory.
;;
;; 1. THE CALL RESULT IS NOT PART OF THE ARGUMENT SETUP. `resolve-argument-moves`
;;    reads the run of moves before a transfer as a PARALLEL copy. Put the
;;    result move in that run and
;;
;;        movsd xmm4, xmm0   ; the call's result
;;        movsd xmm0, xmm4   ; pass it as the next argument
;;
;;    is a swap, which the resolver dutifully emitted through the scratch -- so
;;    the loop carried its previous accumulator round for ever.
(run! "a call's result feeding the next iteration is not a parallel copy"
      (string-append
       "(define n 3)\n"
       "(define (inner i j acc) (if (fx= j n) acc (inner i (fx+ j 1) (fl+ acc 1.0))))\n"
       "(define (outer i acc) (if (fx= i n) acc (outer (fx+ i 1) (inner i 0 acc))))\n"
       "(define (main) (display (outer 0 0.0)) (newline))\n(main)\n")
      '(9.0))

;; 2. A DEFINITION MAY NOT BE HOISTED PAST A MOVE THAT READS IT. A load from an
;;    absolute address is hoisted to the front of the run, because a load makes
;;    a value rather than permuting one. That is right about its SOURCES and
;;    says nothing about its DESTINATION: here the global lands in the very
;;    register the loop counter arrived in, and hoisting it makes the copy read
;;    the global instead of the counter.
(run! "a global read into a parameter's register does not outrun the copy of it"
      (string-append
       "(define lim 4)\n"
       "(define (go i acc)\n"
       "  (if (fx= i lim) acc (go (fx+ i 1) (fl+ acc 2.0))))\n"
       "(define (step p q) (fl+ (go p 0.0) q))\n"
       "(define (main) (display (step 0 1.0)) (newline))\n(main)\n")
      '(9.0))

(run! "nested loops: a self-tail-call must still release its frame"
      (string-append
       "(define n 3)\n"
       "(define (inner i j acc) (if (fx= j n) acc (inner i (fx+ j 1) (fl+ acc 1.0))))\n"
       "(define (outer i acc) (if (fx= i n) acc (outer (fx+ i 1) (inner i 0 acc))))\n"
       "(define (main) (display (outer 0 0.0)) (newline))\n(main)\n")
      '(9.0))

;; STACK ARGUMENTS, which did not work in either direction.
;;
;; x86-64 has four raw-word argument registers, so a sixth fixnum argument has
;; to travel on the stack. Two things were missing and only one was known:
;;
;;   the CALLER had no outgoing argument area, so a store would have landed on
;;   its own spill slots -- and the caller side never fired because
;;
;;   the CALLEE asked the convention for the fifth raw argument register, got
;;   #f, and handed the encoder `mov rcx, #f`. "bad mov operands" is a loud
;;   failure and names nothing that points at a sixth argument.
;;
;; The frame now reserves an outgoing area at the bottom, so a caller writes
;; argument i at [rsp + 8i] and the callee -- one return address and one
;; prologue lower -- reads it at [rsp + bytes + 8 + 8i]. Neither side needs to
;; know the other's frame size.
(run! "a call with more arguments than registers passes them on the stack"
      (string-append
       "(define (six a b c d e f) (fx+ a (fx+ b (fx+ c (fx+ d (fx+ e f))))))\n"
       "(define (main) (display (fx->fl (six 1 2 3 4 5 6))) (newline))\n(main)\n")
      '(21.0))

;; THE SAME THING AS A TAIL CALL, which is the harder half.
;;
;; A tail call jumps without pushing a return address, so the callee reads its
;; stack arguments exactly where the CALLER'S were -- the outgoing area is the
;; caller's own incoming one. Selection cannot compute that address because it
;; depends on the caller's frame size, so the emitters leave `(incoming i)` and
;; finalize substitutes it once the frame is laid out.
;;
;; Ten million iterations rather than three. The interesting failure is not a
;; wrong sum, it is a frame leaked per iteration -- and at three iterations a
;; leak is invisible. At ten million it is eighty megabytes and the program
;; dies, which is the only way this test can tell that the tail call is still
;; a tail call.
(run! "a tail call with a stack argument, ten million times, in constant stack"
      (string-append
       "(define (loop i a b c d e)\n"
       "  (if (fx= i 0) (fx+ a (fx+ b (fx+ c (fx+ d e))))\n"
       "      (loop (fx- i 1) a b c d e)))\n"
       "(define (main) (display (fx->fl (loop 10000000 1 2 3 4 5))) (newline))\n"
       "(main)\n")
      '(15.0))

;; A REPRESENTATION CONVERSION, compiled and run.
;;
;; `pick` is called with a boolean-valued raw word and with a heap object, so
;; its parameter is genuinely polymorphic and repr.ss joins it to `tagged`.
;; That join used to RAISE -- the conversion `(x << 3) | 7` reaching
;; sonic-false/sonic-true had no pass to live in -- so this program was simply
;; rejected. convert.ss now inserts a `retag` and lowering turns it into a
;; multiply by 8 and an add of 7.
;;
;; The observable is the flvector, not the boolean: a tagged boolean has
;; nowhere to be printed yet. What it proves is that the tagged pointer
;; survives the round trip through a parameter that a conversion also flows
;; into, which is the part that would corrupt memory if the classes disagreed.
(run! "a polymorphic parameter forces a representation conversion, and runs"
      (string-append
       "(define (pick p) p)\n"
       "(define (main)\n"
       "  (let ((a (pick (fx< 1 2)))\n"
       "        (b (pick (make-flvector 2 4.5))))\n"
       "    (display (flvector-ref b 1)) (newline)))\n"
       "(main)\n")
      '(4.5))

;; A BOXED DOUBLE, compiled and run.
;;
;; `pick` receives a double from one call site and a heap object from the other,
;; so repr.ss joins its parameter to `tagged` -- and a double has no bit pattern
;; that serves, unlike a fixnum or a boolean. The value goes on the heap through
;; %box-flonum and the tagged value is a pointer to it.
;;
;; This join RAISED until the runtime could box, which is why it was the one
;; case of the three D31 left open.
;;
;; The observable is the flvector, because reading the boxed double back out
;; needs the other direction and there is no unboxing conversion yet. What it
;; proves is that the boxing call happens, the allocation does not disturb the
;; heap pointer for the vector allocated beside it, and the tagged pointer
;; survives the round trip through the polymorphic parameter.
(run! "a double boxed to reach the value class, compiled and run"
      (string-append
       "(define (pick p) p)
"
       "(define (main)
"
       "  (let ((a (pick (fl+ 1.0 2.0)))
"
       "        (b (pick (make-flvector 2 4.5))))
"
       "    (display (flvector-ref b 1)) (newline)))
"
       "(main)
")
      '(4.5))

;; ONE constant passed as SEVERAL arguments of a tail call.
;;
;; This is the shape that broke when CSE started noticing that three separate
;; `0.0` literals were one value. The entry stub became a constant-pool load
;; into a register followed by two copies out of it, and `resolve-argument-moves`
;; treats the run of moves before a transfer as a PARALLEL COPY -- under which
;; the copies want the register's OLD contents, so the load was correctly
;; ordered last and the arguments started at whatever the register happened to
;; hold. At a function entry, that is garbage.
;;
;; nbody caught it only in the twelfth digit, which is exactly the kind of
;; divergence that reads as rounding if the oracle is a tolerance. Asserted
;; here in a form small enough to bisect: three accumulators, one literal.
(run! "one constant passed as several arguments of a tail call"
      (string-append
       "(define (loop i a b c)\n"
       "  (if (fx= i 3) (fl+ a (fl+ b c))\n"
       "      (loop (fx+ i 1) (fl+ a 1.0) (fl+ b 2.0) (fl+ c 3.0))))\n"
       "(define (go) (loop 0 0.0 0.0 0.0))\n"
       "(define (main) (display (go)) (newline))\n(main)\n")
      '(18.0))

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
  ;; BOTH energies, so the whole program is covered: init!, offset-momentum!,
  ;; energy AND advance! over 1000 steps. The second value is the one that
  ;; exercises the pairwise force loop and the position update, and getting it
  ;; bit-exact means every rounding decision matched Chez's for 1000 iterations
  ;; -- which no tolerance-based check would have told us.
  ;;
  ;; -0.169059907 in the Benchmarks Game is for a much larger N; the oracle here
  ;; is cross-agreement with Chez on the same source, per docs/METHOD.md.
  (ck! "nbody is bit-exact against Chez on the same source, both energies"
       (equal? out '(-0.16907516382852447 -0.16908760523460614)))
  (unless (equal? out '(-0.16907516382852447 -0.16908760523460614))
    (display "       got=") (write out) (newline)))

;; THE CASE THAT IS STILL REFUSED, and the refusal is the point.
;;
;; A tail call may overwrite the caller's incoming argument area because the
;; caller is done with it. It may not write PAST that area: those words belong
;; to the caller's caller and are live. So a tail call needing more stack words
;; than the enclosing function received has to grow the stack -- shift the
;; return address up and shuffle the frame -- which this compiler does not do.
;;
;; Asserted because the refusal used to fire on EVERY tail call with a stack
;; argument, which is a much larger set, and a test that only checks the happy
;; path would not notice if it drifted back.
(set! checks (+ checks 1))
(let ((caught #f))
  (guard (e (#t (set! caught #t)))
    (compile-and-run
     (string-append
      "(define (big a b c d e f g)\n"
      "  (fx+ a (fx+ b (fx+ c (fx+ d (fx+ e (fx+ f g)))))))\n"
      "(define (small p q) (big p q 1 2 3 4 5))\n"
      "(define (main) (display (fx->fl (small 9 8))) (newline))\n(main)\n")
     '(display newline)))
  (if caught
      (display "  ok   a tail call that would GROW the stack is refused\n")
      (begin (set! failures (+ failures 1))
             (display "  FAIL a tail call wrote past its incoming argument area\n"))))

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
