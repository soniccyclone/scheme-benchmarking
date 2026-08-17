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
;;; x86-64 only, because the RV64 target has no runtime yet (bead 1mp.6) and so
;;; no compiled PROGRAM to run. The reason used to be "because this machine is
;;; x86-64", which stopped being the binding constraint when the container
;;; gained qemu-riscv64: rv64-test.ss now emits an RV64 image through our own
;;; encoder and ELF writer, and the kernel loads and runs it. That is a real
;;; execution check, on a three-instruction program rather than a compiled one.
;;;
;;; So the ladder for RV64 is: bytes match binutils (rv64-test.ss), objdump
;;; reads our output back (the smoke gate), the kernel runs our image
;;; (rv64-test.ss). What is still missing, and what this file would cover, is a
;;; compiled Scheme program -- which needs the runtime listing.

(import (chezscheme) (nanopass)
        (sonic lang) (sonic read) (sonic expand) (sonic parse) (sonic policy)
        (sonic anf) (sonic assign) (sonic inline) (sonic essa) (sonic elide)
        (sonic repr) (sonic lower) (sonic select) (sonic regs) (sonic regalloc)
        (sonic finalize) (sonic litpool) (sonic object) (sonic runtime)
        (sonic elfexec) (sonic globals) (sonic target-x86-64) (sonic driver) (sonic pipeline)
        (sonic specialize) (sonic gcmeta))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok
      (begin (display "  ok   ") (display name) (newline))
      (begin (set! failures (+ failures 1))
             (display "  FAIL ") (display name) (newline))))

(define tmp "/tmp/sonic-run-test")

;; `argv` is optional and is appended to the command line, so a test can check
;; that an emitted program READS one. Everything else passes nothing and behaves
;; as it always did.
(define (compile-and-run source externs . argv)
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
    (let ((code (system (string-append "timeout 20 " exe
                                       (if (pair? argv)
                                           (string-append " " (car argv))
                                           "")
                                       " > " tmp ".out 2>/dev/null"))))
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

;; A VIRTUAL MUST NEVER BE SPELLED LIKE A PHYSICAL REGISTER.
;;
;; This program failed to compile at all. `fresh!` in lower.ss names quoted
;; constants `k1`, `k2`, ... and the seventh one came out `k7` -- which is an
;; x86-64 opmask register. From there `mask-reg?` classified the virtual as a
;; mask and the encoder refused `movsd k7, [rip+%pool+8]`: correct, and useless,
;; because the message named neither the virtual nor the pass that made it.
;;
;; It takes seven constants to reach `k7`, which is why the shorter store loop
;; above never tripped it. RV64 was armed the same way and worse -- it has
;; physical `t2`..`t6`, and `t` is the most-used base in lower.ss.
;;
;; IT ALSO ONLY FAILED ON THE FIRST COMPILE IN A PROCESS, because the counter is
;; never reset: a second compile started numbering wherever the first stopped
;; and stepped straight over the collision. So this assertion is only worth
;; anything as long as nothing compiles ahead of it in this file -- which is a
;; property of the file, not of the test, and is why 6gk.25 stays open.
(run! "a virtual is never spelled like a register, however many constants it takes"
      (string-append
       "(define v (make-flvector 4 0.0))\n"
       "(define (fill i n)\n"
       "  (if (fx= i n) 0.0 (begin (flvector-set! v i 1.0) (fill (fx+ i 1) n))))\n"
       "(define (main) (display (fill 0 4)) (newline))\n(main)\n")
      '(0.0))

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

;; A GENERAL VECTOR'S ELEMENT CLASS IS THE VECTOR'S, NOT THE PRIMITIVE'S.
;;
;; `vector-ref` used to be classified `tagged` unconditionally -- the safe
;; reading, and not what the compiler did. Nothing tags what it stores, so
;; `(vector-set! v 0 3)` puts a raw 3 in the slot while `vector-ref` claimed a
;; tagged word came back. The claim is invisible until repr.ss MERGES that
;; value with a raw one: the join answers `tagged`, convert.ss retags the raw
;; side at its definition, and every consumer keeps reading it raw, because
;; there is no untagging direction.
;;
;; Three lines are enough. `j` receives the element on entry and `(fx- j 1)` on
;; the back edge, so it is exactly that merge, and `j` came back shifted left 3.
;; The back edge has to be TAKEN for it to show, so a one-iteration loop passes
;; and this one does not -- which is why fannkuch-redux was right at n=3 and
;; trapped its bounds check at n=4.
(run! "a vector element merged with computed arithmetic is not retagged"
      (string-append
       "(define v (make-vector 8 0))\n"
       "(define (put) (vector-set! v 0 3))\n"
       "(define (go j acc) (if (fx> j 1) (go (fx- j 1) (fx+ acc 1)) acc))\n"
       "(define (main) (begin (put) (display (fx->fl (go (vector-ref v 0) 0)))\n"
       "                      (newline)))\n(main)\n")
      '(2.0))

;; The same value used as an INDEX, which is the other half: a tagged fixnum is
;; the value shifted left 3 and the addressing mode already scales by 8, so a
;; wrongly-tagged index reads eight times too far in.
(run! "a vector element indexes another vector at its own magnitude"
      (string-append
       "(define v (make-vector 4 0))\n(define w (make-vector 4 0))\n"
       "(define (put) (begin (vector-set! v 0 2) (vector-set! w 2 7)))\n"
       "(define (main) (begin (put)\n"
       "  (display (fx->fl (vector-ref w (vector-ref v 0)))) (newline)))\n(main)\n")
      '(7.0))

;; A vector that really does hold a tagged object keeps tagged elements. The
;; classification is computed from what the program STORES, so this is the
;; verification half of the optimistic assumption doing its job -- and it must
;; not be optimised into the raw answer just because the fixnum path wanted it.
(run! "a vector holding another vector still round-trips a fixnum element"
      (string-append
       "(define v (make-vector 4 0))\n"
       "(define (put) (begin (vector-set! v 0 (make-vector 2 0)) (vector-set! v 1 5)))\n"
       "(define (main) (begin (put) (display (fx->fl (vector-ref v 1))) (newline)))\n"
       "(main)\n")
      '(5.0))

;; `vector-length` AND `flvector-length`, which had no machine op.
;;
;; Both lower to `vlen`, and one op serving both is D29 rather than a shortcut:
;; the length word is at the same offset for every heap type, so the selector's
;; rule is a load at a constant displacement that asks nothing about the type
;; word. Neither was wired because nbody carries its own `n` and never asks --
;; `vlen` reached the emitted code only through bounds checks, which the
;; elision pass materialises directly.
(run! "vector-length reads the length of a general vector"
      (string-append
       "(define v (make-vector 4 0))\n"
       "(define (main) (begin (display (fx->fl (vector-length v))) (newline)))\n"
       "(main)\n")
      '(4.0))
(run! "flvector-length reads the length of an flvector"
      (string-append
       "(define v (make-flvector 3 0.0))\n"
       "(define (main) (begin (display (fx->fl (flvector-length v))) (newline)))\n"
       "(main)\n")
      '(3.0))
;; Both kinds in one program, each through a call so the length is a parameter
;; rather than a constant the compiler could have folded. If anything
;; downstream keyed off the flvector type when it saw `vlen`, this is where the
;; two would disagree.
(run! "both lengths in one program, each passed through a call"
      (string-append
       "(define a (make-vector 6 0))\n"
       "(define b (make-flvector 9 0.0))\n"
       "(define (twice n) (fx+ n n))\n"
       "(define (main)\n"
       "  (begin (display (fx->fl (fx+ (twice (vector-length a))\n"
       "                               (twice (flvector-length b)))))\n"
       "         (newline)))\n(main)\n")
      '(30.0))
;; The length as a LOOP BOUND, which is what a program that does not carry its
;; own `n` actually writes.
(run! "a loop bounded by vector-length runs the right number of times"
      (string-append
       "(define v (make-vector 5 0))\n"
       "(define (fill i)\n"
       "  (if (fx< i (vector-length v))\n"
       "      (begin (vector-set! v i (fx* i i)) (fill (fx+ i 1)))\n"
       "      0))\n"
       "(define (sum i acc)\n"
       "  (if (fx< i (vector-length v)) (sum (fx+ i 1) (fx+ acc (vector-ref v i))) acc))\n"
       "(define (main) (begin (fill 0) (display (fx->fl (sum 0 0))) (newline)))\n"
       "(main)\n")
      '(30.0))

;; CONSTANT FOLDING, which this compiler did not have.
;;
;; `(fx* 2 3)` emitted an `imul`, and so did `(let ([i 2]) (fx* i 3))`. Asserted
;; on the emitted code rather than the answer, because the answer was always
;; right -- the instruction was simply there.
(define (emitted src)
  (let* ((f (string-append tmp "-fold.sps"))
         (_ (let ((p (open-file-output-port f (file-options no-fail)
                                            (buffer-mode block) (native-transcoder))))
              (put-string p src) (close-port p)))
         (c (compile-sonic f '(display newline))))
    (filter pair? (apply append (map finalized-listing (compiled-functions c))))))

(let ((n (lambda (src)
           (let* ((f (string-append tmp "-fold.sps"))
                  (_ (let ((p (open-file-output-port
                               f (file-options no-fail)
                               (buffer-mode block) (native-transcoder))))
                       (put-string p src) (close-port p)))
                  (c (compile-sonic f '(display newline)))
                  (l (filter pair? (apply append
                                          (map finalized-listing
                                               (compiled-functions c))))))
             (length (filter (lambda (i) (eq? (car i) 'imul)) l))))))
  (ck! "arithmetic on literals folds, so no multiply is emitted"
       (= 0 (n (string-append
                "(define v (make-vector 8 0))\n"
                "(define (main) (begin (vector-set! v 0 (fx* 2 3))\n"
                "  (display (fx->fl (vector-ref v 0))) (newline)))\n(main)\n"))))
  (ck! "and through a let-bound literal, which is what ANF actually produces"
       (= 0 (n (string-append
                "(define v (make-vector 8 0))\n"
                "(define (main) (let ((i 2)) (begin (vector-set! v 0 (fx* i 3))\n"
                "  (display (fx->fl (vector-ref v 0))) (newline))))\n(main)\n")))))

;; The answers, so folding is checked for being RIGHT and not just for being
;; absent. 2*3+1 = 7, and the let-bound form is the same number by a different
;; route.
(run! "a folded expression computes what it folded to"
      (string-append
       "(define v (make-vector 8 0))\n"
       "(define (main) (let ((i 2))\n"
       "  (begin (vector-set! v 0 (fx+ (fx* i 3) 1))\n"
       "         (display (fx->fl (vector-ref v 0))) (newline))))\n(main)\n")
      '(7.0))
;; A division by a non-zero literal folds like anything else.
(run! "quotient by a non-zero literal folds"
      (string-append
       "(define v (make-vector 8 0))\n"
       "(define (main) (begin (vector-set! v 0 (fxquotient 20 4))\n"
       "  (display (fx->fl (vector-ref v 0))) (newline)))\n(main)\n")
      '(5.0))
;; Division by ZERO is deliberately left alone -- the program may be relying on
;; the trap and a fold would delete it. Not asserted end to end here because
;; `(fxquotient 6 0)` does not reach the trap at all: the selector refuses the
;; div-check shape with "division check expects a divisor". That is a
;; pre-existing gap, unrelated to folding, and it is filed rather than fixed
;; inside this commit.

;; A COMPARISON FOLDS TOO, AND ITS BRANCH GOES WITH IT -- but the truth value
;; is NOT Scheme's. `fx<` produces a raw-word 0/1 (repr.ss), so the fold has to
;; produce one too or it changes the value's storage class; and in that
;; representation 0 is FALSE, where Scheme says every object but `#f` is true.
;; Folding `(if 0 a b)` by Scheme's rule would take the wrong arm, so only a
;; value folded FROM A COMPARISON is allowed to decide a branch.
(ck! "a folded comparison deletes its compare and its branch"
     (let ((l (emitted (string-append
                        "(define v (make-vector 4 0))\n"
                        "(define (main) (begin (vector-set! v 0 (if (fx< 1 2) 7 9))\n"
                        "  (display (fx->fl (vector-ref v 0))) (newline)))\n(main)\n"))))
       (and (= 0 (length (filter (lambda (i) (eq? (car i) 'cmp)) l)))
            (= 0 (length (filter (lambda (i) (memq (car i) '(jl jge))) l))))))
(run! "and it takes the arm the comparison actually selects"
      (string-append
       "(define v (make-vector 4 0))\n"
       "(define (main) (begin (vector-set! v 0 (if (fx< 1 2) 7 9))\n"
       "  (vector-set! v 1 (if (fx> 1 2) 7 9))\n"
       "  (display (fx->fl (fx+ (vector-ref v 0) (vector-ref v 1)))) (newline)))\n(main)\n")
      '(16.0))
;; A FIXNUM THAT HAPPENS TO BE 0 IS NOT A FALSE. R6RS: every object but `#f`
;; is true, so `(if 0 a b)` evaluates `a`.
;;
;; This check used to assert the opposite -- that the branch SURVIVED -- which
;; pinned the behaviour rather than the semantics, and the behaviour was wrong:
;; 0 and the raw-word boolean false share a representation, and `cmp r, 0`
;; could not tell them apart. repr.ss's `booleans` table always knew the
;; difference; it simply did not reach lower.ss.
;;
;; The branch is now GONE, and for the right reason: a raw word that is not a
;; truth value is always true, so there is nothing to test.
(run! "a literal 0 is TRUE, per R6RS" 
      (string-append
       "(define (main) (let ((z 0))\n"
       "  (begin (display (fx->fl (if z 7 9))) (newline))))\n(main)\n")
      '(7.0))
(ck! "and its branch is gone entirely: a non-boolean raw word cannot be false"
     (let ((l (emitted (string-append
                        "(define (main) (let ((z 0))\n"
                        "  (begin (display (fx->fl (if z 7 9))) (newline))))\n"
                        "(main)\n"))))
       (= 0 (length (filter (lambda (i) (eq? (car i) 'cmp)) l)))))
;; A COMPARISON still branches, which is the case that must not be swept up
;; with it. The operand comes from a vector so nothing folds.
(ck! "a real comparison still emits its branch"
     (let ((l (emitted (string-append
                        "(define v (make-vector 4 0))\n"
                        "(define (main) (begin (vector-set! v 0 2)\n"
                        "  (display (fx->fl (if (fx< 1 (vector-ref v 0)) 7 9)))\n"
                        "  (newline)))\n(main)\n"))))
       (> (length (filter (lambda (i) (eq? (car i) 'cmp)) l)) 0)))

;; A BOOLEAN LITERAL IS A SCHEME OBJECT, and the selector used to refuse one:
;; "only exact integer and flonum literals are selectable". `#t` and `#f` are
;; the immediates numeric.ss calls sonic-true and sonic-false -- 15 and 7 --
;; not the fixnums 1 and 0, which repr.ss's header calls a live
;; memory-corruption bug in the other direction. Reachable straight from
;; source, so this was a hole rather than a scope note.
(run! "a boolean literal can be stored and the vector still works"
      (string-append
       "(define v (make-vector 4 0))\n"
       "(define (main) (begin (vector-set! v 0 #f) (vector-set! v 1 7)\n"
       "  (display (fx->fl (vector-ref v 1))) (newline)))\n(main)\n")
      '(7.0))

;; WHICH BOUNDS CHECKS SURVIVE, counted in the emitted code.
;;
;; The elision is what these two benchmarks are in the matrix to exercise, so
;; the count is asserted rather than left to drift. Both numbers moved when the
;; interval domain learned the false edge of an equality test, and a change in
;; either direction is worth failing over: upward means a refinement was lost,
;; downward means one was added and nobody said so.
;;
;; SOUNDNESS IS NOT WHAT THIS CHECKS. differential.ss compiles each program
;; with every check emitted and with the proved ones removed and compares the
;; answers; that is the test that an elision was legal. This one only says how
;; many are left.
(define (surviving-bounds-checks path externs)
  (let ((c (compile-sonic path externs)) (n 0))
    (for-each
     (lambda (f)
       (for-each (lambda (i)
                   (when (and (pair? i) (memq (car i) '(jge jb jae ja))
                              (pair? (cadr i)) (eq? (car (cadr i)) 'label)
                              (eq? (cadr (cadr i)) 'sonic-bounds-error))
                     (set! n (+ n 1))))
                 (finalized-listing f)))
     (compiled-functions c))
    n))

;; nbody's indices are `3i+k` off a vector whose length was proved at its
;; allocation, so every one of them should go -- and now every one does.
(ck! "nbody emits NO bounds check at all"
     (= 0 (surviving-bounds-checks "../bench/nbody/config-sonic.sps" nbody-externs)))

;; fannkuch-redux now emits none either, and the fact that removed the last
;; ones is the one this test used to exist to document.
;;
;; It kept four per copy of `flip-prefix`'s loop -- eight, the loop having been
;; spliced by inline.ss and then duplicated by unroll-program. The loop is
;; `(fx< i j)` with `j` from `(vector-ref perm 0)`, so bounding it needs "every
;; element of perm is below n", which is a statement about the array's CONTENTS
;; and not about any scalar the interval domain tracks. SPEC.md picked this
;; program for exactly that shape.
;;
;; elemrange.ss supplies it. perm's elements join to [0, n-1] because `init`
;; writes an induction variable bounded by the loop guard and every other write
;; stores a value read back out of perm or perm1 -- so the range is closed
;; under the program's own permuting. See LEDGER D42 for why that ascent has to
;; run separately from the interval one.
;;
;; ZERO IS THE CLAIM, not "fewer". A count that merely dropped would leave open
;; which checks went, and the whole point is that the contents fact discharges
;; the entire family: once `k` is bounded, so are `i` and `j`, so are both
;; copies, and nothing in flip-prefix is left to check.
(ck! "fannkuch-redux emits no bounds check either, once perm's contents are bounded"
     (= 0 (surviving-bounds-checks "../bench/fannkuch/config-sonic.sps"
                                   '(display newline))))

;; AN EMPTY INDEX INTERVAL DISCHARGES ITS CHECK, and the fixture is the one
;; that found it.
;;
;; Bottom is not "an index we know nothing about" -- that is top. It is the
;; meet of disjoint constraints, so no value reaches the access and the check
;; can never fire. Every other rule in `bounds-ok?` asks a question about a
;; value that does not exist and gets #f, so before this the site fell through
;; to `kept`.
;;
;; MEASURED WHERE IT MATTERS, which is under specialization -- the pass is off
;; by default, and turning it on used to take fannkuch from 0 surviving checks
;; to 79 and nbody from 0 to 97. The empty-interval rule takes nbody's back to
;; ZERO and fannkuch's to 34, so it removes the whole of one benchmark's
;; regression and over half of the other's. That regression is the only thing
;; between qaq.23 and a measured 8.4% of fannkuch's cycles.
;;
;; The probe is checked at 0 rather than "fewer": it is twenty lines built to
;; isolate exactly this, and a number that merely drops would not say the site
;; went for the right reason.
(ck! "an unreachable access needs no bounds check, even in a specialized copy"
     (= 0 (parameterize ([specialize-enabled? #t])
            (surviving-bounds-checks "../bench/probe-specialize-elision.sps"
                                     '(display newline)))))

;; A TAGGED FALSE IS sonic-false, NOT ZERO.
;;
;; `branch-if` lowers to `cmp r, 0` and a non-zero jump, which is right for a
;; raw-word boolean -- the fixnum comparisons produce 0 or 1 -- and wrong for a
;; tagged one, because Scheme's `#f` is the immediate numeric.ss calls
;; sonic-false, which is 7. Comparing it against 0 made `#f` read as TRUE, so
;; `(if #f 7 9)` evaluated to 7. A wrong answer on ordinary Scheme.
(run! "a literal #f takes the else arm" 
      "(define (main) (begin (display (fx->fl (if #f 7 9))) (newline)))\n(main)\n"
      '(9.0))
;; The same through a vector, so the #f survives to run time rather than being
;; a compile-time shape -- this is the one that exercises the emitted compare.
(run! "and so does a #f that reaches the branch at run time"
      (string-append
       "(define v (make-vector 4 0))\n"
       "(define (main) (begin (vector-set! v 0 #f)\n"
       "  (display (fx->fl (if (vector-ref v 0) 7 9))) (newline)))\n(main)\n")
      '(9.0))
(run! "while a #t takes the then arm, which is not true by accident"
      (string-append
       "(define v (make-vector 4 0))\n"
       "(define (main) (begin (vector-set! v 0 #t)\n"
       "  (display (fx->fl (if (vector-ref v 0) 7 9))) (newline)))\n(main)\n")
      '(7.0))

;; INTEGER DIVISION, which no program could use at all: the selector refused
;; `div` with "integer division needs the rdx:rax pair idiv hardwires, which the
;; register partition does not model".
;;
;; It is a runtime CALL rather than an instruction, and that is the register
;; file's doing rather than the encoder's -- `idiv` reads a 128-bit dividend in
;; rdx:rax and writes both, and regs.ss allocates from disjoint class pools with
;; no way to say so. A runtime routine has no allocator to argue with, and a
;; call around an instruction that is already 20-40 cycles is noise.
;;
;; The divisor is read from a vector so nothing folds it: these must exercise
;; the routine, not fold.ss.
(define (div-prog e)
  (string-append "(define v (make-vector 4 0))\n"
                 "(define (main) (begin (vector-set! v 0 4)\n"
                 "  (display (fx->fl " e ")) (newline)))\n(main)\n"))
(run! "quotient" (div-prog "(fxquotient 20 (vector-ref v 0))") '(5.0))
(run! "quotient truncates toward zero, so a negative dividend gives -5"
      (div-prog "(fxquotient -20 (vector-ref v 0))") '(-5.0))
(run! "remainder follows the DIVIDEND's sign" (div-prog "(fxremainder -23 (vector-ref v 0))")
      '(-3.0))
;; modulo and remainder differ exactly when the signs disagree, which is the
;; only interesting thing about either of them.
(run! "modulo follows the DIVISOR's sign, so the same operands give 1"
      (div-prog "(fxmodulo -23 (vector-ref v 0))") '(1.0))
(run! "and they agree when the signs agree" (div-prog "(fxmodulo 23 (vector-ref v 0))")
      '(3.0))
;; The div-check now reaches an operation that exists, so it can finally trap.
(let-values (((code out)
              (compile-and-run
               (string-append
                "(define v (make-vector 4 0))\n"
                "(define (main) (begin (vector-set! v 0 0)\n"
                "  (display (fx->fl (fxquotient 6 (vector-ref v 0))))))\n(main)\n")
               '(display newline))))
  (ck! "division by zero traps rather than dividing" (not (zero? code))))

;; A PROCEDURE NOTHING CALLS IS NOT COMPILED.
;;
;; `partition-into-functions` gathers blocks no entry reaches under
;; `<unreachable>` and finalize drops that bucket -- but a top-level procedure
;; with no callers is not in it. It is a well-formed function that simply
;; cannot run, and it was being lowered, allocated, finalized and emitted.
;;
;; Reachability is EXACT rather than conservative: every call names its target
;; directly (closures are a later bead), so the call graph is the set of
;; procedures that can run.
(ck! "a procedure nothing calls is dropped, with its inner loop"
     (let* ((f (string-append tmp "-dead.sps"))
            (_ (let ((p (open-file-output-port f (file-options no-fail)
                                               (buffer-mode block)
                                               (native-transcoder))))
                 (put-string p (string-append
                   "(define v (make-vector 4 0))\n"
                   "(define (dead r)\n"
                   "  (let loop ((i 0))\n"
                   "    (if (fx< i r) (begin (vector-set! v i i) (loop (fx+ i 1))) 0)))\n"
                   ;; CALLED TWICE, so rule 2' leaves it alone. A procedure
                   ;; named by one call is spliced whatever its size, and this
                   ;; test is about a procedure named by NONE.
                   "(define (live x) (fx+ x 1))\n"
                   "(define (main) (begin (display (fx->fl (fx+ (live 41) (live 0)))) (newline)))\n"
                   "(main)\n"))
                 (close-port p)))
            (names (map finalized-name
                        (compiled-functions (compile-sonic f '(display newline))))))
       ;; `main` is NOT required to survive: it is named by exactly one call,
       ;; the one the top level makes, so rule 2' splices it into the entry.
       ;; What this test is about is `dead`, which nothing calls at all.
       (and (memq 'live names)
            (not (memq 'dead names))
            ;; the loop inside it goes too, which is the case that would
            ;; survive a check that only looked at top-level names
            (not (exists (lambda (n)
                           (let ((s (symbol->string n)))
                             (and (>= (string-length s) 4)
                                  (string=? (substring s 0 4) "loop"))))
                         names)))))

;; A PROCEDURE NOTHING CALLS MUST NOT REFUSE THE PROGRAM.
;;
;; A parameter's class comes from the call sites (repr.ss), so a procedure with
;; none leaves its parameters unclassified -- and lower.ss then reaches an `if`
;; in its body and cannot say how to copy either arm into the join destination.
;; The compile ABORTS, over code that cannot run.
;;
;; `rotate` here is exactly the shape: a parameter, an inner loop, a join. It
;; is never called. Found while shrinking fannkuch-redux to test `count-flips`
;; on its own, which is when a program acquires dead procedures -- so the case
;; that breaks it is the case you hit while debugging.
(run! "a procedure nothing calls does not refuse the program"
      (string-append
       "(define v (make-vector 4 0))\n"
       "(define (rotate r)\n"
       "  (let ((p0 (vector-ref v 0)))\n"
       "    (let shift ((i 0))\n"
       "      (if (fx< i r)\n"
       "          (begin (vector-set! v i (vector-ref v (fx+ i 1))) (shift (fx+ i 1)))\n"
       "          (vector-set! v r p0)))))\n"
       "(define (live x) (fx+ x 1))\n"
       "(define (main) (begin (display (fx->fl (live 6))) (newline)))\n(main)\n")
      '(7.0))

;; FANNKUCH-REDUX, END TO END, against the oracle in bench/fannkuch/SPEC.md.
;;
;; The second benchmark in the matrix and the first one that is integer work in
;; general vectors: every index here comes from arithmetic on a loop variable or
;; out of another element, which is the case nbody's `3i+k` never exercises.
;; n=7 is the size the variants run; 228 and 16 are `ref.c`'s answers and Chez's.
(let-values (((code out)
              (compile-and-run
               (call-with-input-file "../bench/fannkuch/config-sonic.sps"
                 (lambda (p)
                   (let loop ((acc '()))
                     (let ((l (get-line p)))
                       (if (eof-object? l)
                           (apply string-append (reverse acc))
                           (loop (cons (string-append l "\n") acc)))))))
               '(display newline))))
  (ck! "fannkuch-redux n=7 runs and agrees with the specification's oracle"
       (and (zero? code) (equal? out '(228.0 16.0))))
  (unless (and (zero? code) (equal? out '(228.0 16.0)))
    (display "       exit=") (display code)
    (display " got=") (write out) (newline)))

;; PAIRS, END TO END.
;;
;; `(cons 1 2)` used to fail at LINK -- "undefined label %cons" -- because
;; lower.ss has mapped cons/car/cdr onto runtime entry points for as long as the
;; primitive table has existed and nothing defined them. A Scheme without pairs
;; is a hole worth a test rather than a note.
;;
;; Three cases and each is a different thing being checked: nested pairs walk
;; the cdr chain, a pair holding a VECTOR proves the fields carry real tagged
;; pointers rather than immediates, and the fixnum fields prove repr.ss's
;; `prim-arg-classes` retagged them at their definitions -- without that
;; declaration the runtime would be storing whichever representation the
;; program happened to have, and both fields are SCANNED by the collector.
(let-values (((code out)
              (compile-and-run
               (string-append
                "(define p (cons 1 (cons 2 (cons 3 4))))\n"
                "(define v (make-vector 3 7))\n"
                "(define r (cons v 9))\n"
                "(display (fx->fl (car p))) (newline)\n"
                "(display (fx->fl (car (cdr p)))) (newline)\n"
                "(display (fx->fl (cdr (cdr (cdr p))))) (newline)\n"
                "(display (fx->fl (vector-length (car r)))) (newline)\n"
                "(display (fx->fl (vector-ref (car r) 2))) (newline)\n"
                "(display (fx->fl (cdr r))) (newline)\n")
               '(display newline))))
  (ck! "pairs: cons, car and cdr, nested and holding a vector"
       (and (zero? code) (equal? out '(1.0 2.0 4.0 3.0 7.0 9.0))))
  (unless (and (zero? code) (equal? out '(1.0 2.0 4.0 3.0 7.0 9.0)))
    (display "       exit=") (display code)
    (display " got=") (write out) (newline)))

;; TYPE PREDICATES AND eq?, END TO END.
;;
;; These are what finally read a tag. `%fixnum?` masks the low three bits and
;; compares against 000, so it is the first expression in this compiler's
;; history whose answer depends on a fixnum actually being SHIFTED -- and it
;; answered false about the number five until the representation was made
;; honest. The interlock that fixed it is in convert.ss (literals are retagged),
;; lower.ss (`untag-args` shifts back at the use) and repr.ss (a tagged-element
;; vector requires tagged values); none of the three works without the others.
;;
;; So the last two lines are the ones to watch. `(fx->fl (car p))` reads a
;; fixnum out of a pair, which stores it tagged and hands it to a primitive
;; that needs a machine word: it is the round trip, and it is 1.0 only if both
;; directions are present.
(let-values (((code out)
              (compile-and-run
               (string-append
                "(define p (cons 1 2))\n"
                "(define v (make-vector 2 0))\n"
                "(define f (make-flvector 2 0.0))\n"
                "(display (if (pair? p) 1.0 0.0)) (newline)\n"
                "(display (if (pair? v) 1.0 0.0)) (newline)\n"
                "(display (if (vector? v) 1.0 0.0)) (newline)\n"
                "(display (if (flvector? f) 1.0 0.0)) (newline)\n"
                "(display (if (fixnum? 5) 1.0 0.0)) (newline)\n"
                "(display (if (fixnum? p) 1.0 0.0)) (newline)\n"
                "(display (if (null? p) 1.0 0.0)) (newline)\n"
                "(display (if (eq? p p) 1.0 0.0)) (newline)\n"
                "(display (if (eq? p v) 1.0 0.0)) (newline)\n"
                "(display (fx->fl (car p))) (newline)\n"
                "(display (fx->fl (cdr p))) (newline)\n")
               '(display newline))))
  (ck! "type predicates, eq?, and a fixnum round-tripping through a pair"
       (and (zero? code)
            (equal? out '(1.0 0.0 1.0 1.0 1.0 0.0 0.0 1.0 0.0 1.0 2.0))))
  (unless (and (zero? code)
               (equal? out '(1.0 0.0 1.0 1.0 1.0 0.0 0.0 1.0 0.0 1.0 2.0)))
    (display "       exit=") (display code)
    (display " got=") (write out) (newline)))

;; A GENERAL VECTOR WHOSE ELEMENTS ARE SCHEME OBJECTS.
;;
;; The regression the previous commit shipped, kept as a test. When anything
;; stores an object into a general vector, `vector-element-class` lifts to
;; `tagged` and reads of that vector are untagged -- so the FILL has to be
;; tagged too, or a vector of 7s reads back as 0. It did, for one commit.
;;
;; Both halves are asserted: the fill (elements 1 and 2, never written) and a
;; stored object (element 0, whose `pair?` must still be true after the round
;; trip through the vector).
(let-values (((code out)
              (compile-and-run
               (string-append
                "(define v (make-vector 3 7))\n"
                "(define p (cons 1 2))\n"
                "(vector-set! v 0 p)\n"
                "(display (fx->fl (vector-ref v 1))) (newline)\n"
                "(display (fx->fl (vector-ref v 2))) (newline)\n"
                "(display (if (pair? (vector-ref v 0)) 1.0 0.0)) (newline)\n"
                "(display (fx->fl (car (vector-ref v 0)))) (newline)\n")
               '(display newline))))
  (ck! "a tagged-element vector keeps its fill, and round-trips an object"
       (and (zero? code) (equal? out '(7.0 7.0 1.0 1.0))))
  (unless (and (zero? code) (equal? out '(7.0 7.0 1.0 1.0)))
    (display "       exit=") (display code)
    (display " got=") (write out) (newline)))

;; AN ALLOCATOR COUNT THAT ARRIVES TAGGED.
;;
;; `(make-vector (car p) 5)` traps unless two separate things are right, and
;; each was wrong on its own.
;;
;; The count reaches the allocator as a raw element count, so it has to be
;; untagged at the use like every other raw-word argument. And the `type-check`
;; that guards it has to ask for the FIXNUM tag: `expected-tag` answered
;; `heap-tag` for every type check, which is right for the pair of a `car` and
;; wrong for a count, and no representation of the number three passes it.
;;
;; The last two lines are the ones that keep the checks honest -- a coarse tag
;; test is still a real test, and making a count pass must not make a bad
;; pointer or an out-of-range index pass.
(let-values (((code out)
              (compile-and-run
               (string-append
                "(define p (cons 3 0))\n"
                "(define v (make-vector (car p) 5))\n"
                "(define f (make-flvector (car p) 1.5))\n"
                "(display (fx->fl (vector-length v))) (newline)\n"
                "(display (fx->fl (vector-ref v 1))) (newline)\n"
                "(display (fx->fl (flvector-length f))) (newline)\n"
                "(display (flvector-ref f 1)) (newline)\n")
               '(display newline))))
  (ck! "an allocator count arriving tagged is untagged and type-checked as a fixnum"
       (and (zero? code) (equal? out '(3.0 5.0 3.0 1.5))))
  (unless (and (zero? code) (equal? out '(3.0 5.0 3.0 1.5)))
    (display "       exit=") (display code)
    (display " got=") (write out) (newline)))

;; And the checks still fire. 101 is the type trap, 102 the bounds trap.
(let-values (((code out) (compile-and-run "(display (fx->fl (car 5))) (newline)\n"
                                          '(display newline))))
  (ck! "a type check still traps: (car 5) exits 101" (= 101 code)))
(let-values (((code out)
              (compile-and-run
               (string-append "(define v (make-vector 2 0))\n"
                              "(define p (cons 5 0))\n"
                              "(display (fx->fl (vector-ref v (car p)))) (newline)\n")
               '(display newline))))
  (ck! "a bounds check still traps on a tagged index that is out of range"
       (= 102 code)))

;; THE GC STACK MAPS REACH THE EXECUTABLE.
;;
;; They were computed and thrown away: `assemble-function` hangs the metadata on
;; the function object and driver.ss built the image from
;; `(function-object-code o)` alone. Nothing else was missing for the roots half
;; of D21, which is why this is asserted about the BINARY rather than about
;; object.ss -- the latter was always true and told nobody anything.
;;
;; AND IT CARRIES ROOTS, which is the half that was missing for longer. The
;; blob was three zero bytes on every program -- fannkuch, nbody, a loop that
;; conses, a probe holding nine tagged values live across allocations -- because
;; `assemble-function` accepts a `frame-bits` option that driver.ss never
;; passed. The format, the emitter and the decoder had all been there and
;; carried nothing.
;;
;; The bits are per FUNCTION and the program is assembled as one listing, so
;; they arrive as (instruction-index . bits) and the emitter is re-pointed at
;; each boundary. `finalized-spills` gives the spilled vregs in slot order --
;; the order build-frame numbers them in -- so a slot is tagged exactly when
;; its vreg's class is.
;;
;; A nonzero byte is what distinguishes a map from a placeholder. Asserting only
;; that the blob is present would have passed for the whole time it was blank.
(let* ((c (compile-sonic "../bench/fannkuch/config-sonic.sps" '(display newline)))
       (meta (compiled-metadata c))
       (img (compiled-image c))
       (off (metadata-offset-for (bytevector-length (compiled-code c))
                                 (bytevector-length (compiled-pool c))))
       (back (make-bytevector (bytevector-length meta))))
  (bytevector-copy! img off back 0 (bytevector-length meta))
  (ck! "the GC stack maps are carried into the executable, byte for byte"
       (and (> (bytevector-length meta) 0) (equal? back meta)))
  (ck! "and they carry roots rather than zeros"
       (let loop ((i 0))
         (cond ((= i (bytevector-length meta)) #f)
               ((not (zero? (bytevector-u8-ref meta i))) #t)
               (else (loop (+ i 1))))))
  ;; AND THEY DECODE, WITH THE FRAME DESCRIPTION CHANGING PER FUNCTION. fannkuch
  ;; gives eight entries whose slot counts run 0, 2, 0, 2, 0, 15 -- which is the
  ;; evidence that the bits are re-pointed at each boundary rather than set once
  ;; for the whole listing. Its tagged counts are all ZERO and that is correct:
  ;; it spills raw words and doubles, never a pair.
  (let ((es (decode-metadata target-x86-64 meta)))
    (ck! "the maps decode, and the frame description changes between functions"
         (and (pair? es)
              (let loop ((ns (map (lambda (e) (length (entry-frame-bits e))) es))
                         (seen '()))
                (cond ((null? ns) (> (length seen) 1))
                      ((memv (car ns) seen) (loop (cdr ns) seen))
                      (else (loop (cdr ns) (cons (car ns) seen)))))))
    (ck! "and a lookup by code offset lands at or before it"
         (let ((e (metadata-lookup es 2879)))
           (and e (<= (entry-offset e) 2879))))))

;; EVERY RECORDED OFFSET IS AN INSTRUCTION START, AND THE MAPS COVER FROM ZERO.
;;
;; Two more agreements the collector's walk will rest on, checked against the
;; code layout rather than against the emitter that produced the offsets --
;; asking the emitter would only confirm it agrees with itself.
;;
;; An offset landing mid-instruction would make a lookup by return address
;; describe the wrong frame; a first entry after zero would make a lookup in the
;; runtime stubs fall off the front and find nothing. Both are silent failures
;; and neither is visible in a decoded blob that otherwise looks well formed.
(let* ((c (compile-sonic "../bench/fannkuch/config-sonic.sps" '(display newline)))
       (es (decode-metadata target-x86-64 (compiled-metadata c)))
       ;; instruction starts, walked independently from the listing
       (starts (let loop ((xs (compiled-listing c)) (pc 0) (acc '()))
                 (cond ((null? xs) acc)
                       ((symbol? (car xs)) (loop (cdr xs) pc acc))
                       (else (loop (cdr xs)
                                   (+ pc (instruction-size 'x86-64 (car xs)))
                                   (cons pc acc))))))
       (tbl (make-eqv-hashtable)))
  (for-each (lambda (p) (hashtable-set! tbl p #t)) starts)
  (ck! "every stack-map offset lands on an instruction start"
       (for-all (lambda (e) (hashtable-ref tbl (entry-offset e) #f)) es))
  (ck! "and the maps cover from offset zero, so a lookup never falls off the front"
       (and (pair? es) (= 0 (entry-offset (car es))) (metadata-lookup es 0) #t)))

;; EVERY PROLOGUE SUBTRACTS EXACTLY WHAT THE FRAME LAYOUT SAYS.
;;
;; Pinned before the collector exists rather than after. A stack walk steps from
;; one frame to the next by the size the metadata implies, so if a prologue and
;; its layout ever disagree the walk reads the wrong words for every frame below
;; the offender -- and it would do so silently, exactly like the shared-slot bug
;; two entries up, which also came from two structures that were supposed to
;; agree and did not.
;;
;; Checked across every function of both benchmarks and the tagged fixture: 36
;; functions, no mismatches. Cheap to keep, and it fails loudly the day someone
;; changes how a frame is sized without changing how it is described.
(let* ((progs (list (cons "../bench/fannkuch/config-sonic.sps" '(display newline))
                    (cons "../bench/probe-tagged-spills.sps" '(display newline))))
       (bad
        (fold-left
         (lambda (acc pr)
           (let ((c (compile-sonic (car pr) (cdr pr))))
             (fold-left
              (lambda (acc f)
                (let ((want (frame-layout-bytes (finalized-frame f)))
                      (got (let scan ((is (finalized-listing f)))
                             (cond ((null? is) 0)
                                   ((and (pair? (car is)) (eq? (car (car is)) 'sub)
                                         (eq? (cadr (car is)) 'rsp)
                                         (pair? (caddr (car is)))
                                         (eq? (car (caddr (car is))) 'imm))
                                    (cadr (caddr (car is))))
                                   (else (scan (cdr is)))))))
                  (if (equal? want got) acc (+ acc 1))))
              acc (compiled-functions c))))
         0 progs)))
  (ck! "every prologue subtracts exactly what its frame layout says" (= 0 bad)))

;; AND NO MAP DESCRIBES MORE SLOTS THAN THE FRAME HAS.
;;
;; The bits are per frame SLOT, and `build-frame` shares a slot between a vreg
;; and its coalescing representative -- so the spill list is longer than the
;; frame wherever that happens. fannkuch's `next` is 15 spilled vregs in 14
;; slots and nbody's outer%22 is 4 in 3.
;;
;; A bitmap laid out per vreg is right until the first shared slot and shifted
;; by one after it, which is the worst failure available to a collector: it
;; follows whatever the neighbouring word holds. This caught exactly that -- the
;; maps claimed 15 slots for a 14-slot frame.
(let* ((c (compile-sonic "../bench/fannkuch/config-sonic.sps" '(display newline)))
       (es (decode-metadata target-x86-64 (compiled-metadata c)))
       (widest-map (apply max (map (lambda (e) (length (entry-frame-bits e))) es)))
       (widest-frame (apply max (map (lambda (f) (frame-layout-count (finalized-frame f)))
                                     (compiled-functions c)))))
  (ck! "no stack map describes more slots than its frame has"
       (<= widest-map widest-frame)))

;; AND _start LEAVES THE MAPS' ADDRESS WHERE THE COLLECTOR WILL LOOK.
;;
;; The blob's address is a link-time fact -- it sits after the constant pool,
;; whose size depends on the program -- so the entry code computes it
;; RIP-relatively against a label the assembler resolves, exactly as a pooled
;; constant load does, and stores it in `gcmeta-cell`.
;;
;; Asserted against the LAYOUT rather than against itself: the address the lea
;; computes has to equal elf-text-vaddr plus the offset `metadata-offset-for`
;; gives. Checking only that a lea exists would pass if it pointed anywhere.
(let* ((c (compile-sonic "../bench/probe-tagged-spills.sps" '(display newline)))
       ;; elf-load-base, not elf-text-vaddr: `metadata-offset-for` returns a
       ;; FILE offset and already carries the text segment's own offset, so
       ;; adding the text vaddr would count that page twice.
       (want (+ elf-load-base
                (metadata-offset-for (bytevector-length (compiled-code c))
                                     (bytevector-length (compiled-pool c)))))
       ;; find the lea in the entry code and decode its rip-relative target
       (code (compiled-code c))
       (found
        (let scan ((i 0))
          (cond
           ((>= i (- (bytevector-length code) 7)) #f)
           ;; 48 8d 05 disp32  =  lea rax, [rip+disp]
           ((and (= #x48 (bytevector-u8-ref code i))
                 (= #x8d (bytevector-u8-ref code (+ i 1)))
                 (= #x05 (bytevector-u8-ref code (+ i 2))))
            (let* ((d (bytevector-s32-ref code (+ i 3) 'little))
                   (next (+ elf-text-vaddr i 7)))
              (if (= (+ next d) want) #t (scan (+ i 1)))))
           (else (scan (+ i 1)))))))
  (ck! "_start computes the maps' address and it points at the maps" found))

;; AND A PROGRAM THAT ACTUALLY SPILLS A ROOT SAYS SO.
;;
;; Neither benchmark does -- see above -- so a test written against either would
;; have passed for the whole period the maps were blank. This fixture holds nine
;; tagged values live across allocations against a four-register value class, so
;; some must land in the frame, and a frame slot holding a pair is exactly what
;; the collector will have to find.
(let* ((c (compile-sonic "../bench/probe-tagged-spills.sps" '(display newline)))
       (es (decode-metadata target-x86-64 (compiled-metadata c)))
       (tagged (filter (lambda (e) (exists (lambda (b) b) (entry-frame-bits e))) es)))
  (ck! "a frame slot holding a pair is reported as a root"
       (pair? tagged)))

;; RUNNING OUT OF HEAP IS A DIAGNOSIS, NOT A SEGMENTATION FAULT.
;;
;; The collector is written but not lowered (D52), so the heap is a one-megabyte
;; bump region and nothing reclaims. That is a limitation. What it must not be
;; is a crash: before the guards in runtime.ss, a program allocating past the
;; end wrote into unmapped memory and took SIGSEGV, which reads to anyone
;; running it as a compiler bug rather than as a limit being reached.
;;
;; Measured at the time: 30,000 pairs completed and 60,000 segfaulted, on a
;; heap that was then 1 MB. The heap is 256 MB now -- it is .bss, so the size
;; costs nothing on disk -- which is why this asks for fifty million pairs.
;; Eight hundred megabytes of them against a two hundred and fifty six megabyte
;; heap; the loop trips the guard about a third of the way in.
;;
;; 104 is the heap trap, alongside 101 type, 102 bounds, 103 overflow.
(let-values (((code out)
              (compile-and-run
               (string-append "(define (burn i acc)\n"
                              "  (if (fx< i 50000000)\n"
                              "      (burn (fx+ i 1) (cons i (quote ())))\n"
                              "      acc))\n"
                              "(define r (burn 0 (quote ())))\n"
                              "(display (fx->fl (car r))) (newline)\n")
               '(display newline))))
  (ck! "exhausting the heap exits 104 rather than taking a segmentation fault"
       (= 104 code)))

;; AND THE HEADROOM BELOW IT STILL WORKS, which is the half of this that a
;; guard can easily break: a check placed one object too early would turn every
;; allocating program into a heap error.
(let-values (((code out)
              (compile-and-run
               (string-append "(define (burn i acc)\n"
                              "  (if (fx< i 30000)\n"
                              "      (burn (fx+ i 1) (cons i (quote ())))\n"
                              "      acc))\n"
                              "(define r (burn 0 (quote ())))\n"
                              "(display (fx->fl (car r))) (newline)\n")
               '(display newline))))
  (ck! "and a program that fits in the heap still runs"
       (and (zero? code) (equal? out '(29999.0)))))

;; TWO GROUPS OF ADJACENT STORES IN ONE BLOCK.
;;
;; slp.ss seeds a pack from adjacent stores and used to find its partners by
;; scanning the block from the TOP, returning the first store matching
;; (base, index, offset). That is right while a block holds one such group,
;; which is every program this compiler had seen -- nbody's pair body writes
;; v[bi], v[bi+1], v[bi+2] once.
;;
;; Two groups accumulating into the SAME three elements is what unrolling a
;; pair loop produces, and it is the shape qaq.7.22 needs. The second group's
;; seed reached BACKWARD into the first, packing one value from one
;; computation with two from the other, and the program computed a different
;; number -- NaN, from the full benchmark. The search starts at the seed now.
;;
;; The oracle is Chez on the same source, which is where these two values come
;; from. They are not round numbers and that is the point: a packing bug that
;; mixes lanes produces something plausible, not something obviously broken.
(let-values (((code out)
              (compile-and-run
               (call-with-input-file "../bench/nbody/repro-two-groups.sps"
                 (lambda (p)
                   (let loop ((acc '()))
                     (let ((l (get-line p)))
                       (if (eof-object? l)
                           (apply string-append (reverse acc))
                           (loop (cons (string-append l "\n") acc)))))))
               '(display newline))))
  (ck! "two groups of adjacent stores in one block do not cross-pack"
       (and (zero? code) (equal? out '(0.0027397408607378075 0.0))))
  (unless (and (zero? code) (equal? out '(0.0027397408607378075 0.0)))
    (display "       exit=") (display code)
    (display " got=") (write out) (newline)))

;; LISTS: `length` and `cadr` over real pairs, and the empty list literal.
;;
;; Both were stubs. `length` returned the constant 1, which was enough for the
;; one expression in nbody -- `(fx> (length args) 1)` against an empty argument
;; list -- and wrong for every other question; `cadr` trapped, deliberately,
;; because it sat on a branch nothing took. Pairs exist now, so both can be
;; what they say they are.
;;
;; `(quote ())` is here because it crashed the COMPILER, not the program:
;; fold.ss asked `exact?` before `integer?` and `exact?` raises on a
;; non-number, so any program building a list died with "() is not a number".
;;
;; `length` returns a RAW WORD, which is why the result goes through fx->fl
;; rather than being displayed directly -- see repr.ss's extern-result-classes.
(let-values (((code out)
              (compile-and-run
               (string-append
                "(define l (cons 10 (cons 20 (cons 30 (quote ())))))\n"
                "(display (fx->fl (length l))) (newline)\n"
                "(display (fx->fl (length (quote ())))) (newline)\n"
                "(display (fx->fl (cadr l))) (newline)\n"
                "(display (fx->fl (car l))) (newline)\n")
               '(command-line length cadr string->number display newline))))
  (ck! "length and cadr walk a real list, and the empty list compiles"
       (and (zero? code) (equal? out '(3.0 0.0 20.0 10.0))))
  (unless (and (zero? code) (equal? out '(3.0 0.0 20.0 10.0)))
    (display "       exit=") (display code)
    (display " got=") (write out) (newline)))

;; A COMMAND LINE, END TO END.
;;
;; `command-line` returned the empty list and `length` returned 1, which
;; together took nbody's default branch and were the whole reason N could not
;; be passed. argv is now decoded into real strings at _start -- which needed
;; pairs, an 8-bit store, and a byte-packed string layout -- and
;; `string->number` reads one.
;;
;; Asserted through nbody rather than a toy, because the interesting part is
;; the chain: command-line builds a list of strings, `length` counts it, `cadr`
;; takes the second, `string->number` parses it, and the result drives the loop.
;; A toy would exercise the routines and not the chain.
;;
;; The values are Chez's on the same source at the same N, and the second one
;; MOVES with N -- which is what says the argument was read rather than
;; defaulted.
(let ((nb (call-with-input-file "../bench/nbody/config-sonic.sps"
            (lambda (p)
              (let loop ((acc '()))
                (let ((l (get-line p)))
                  (if (eof-object? l)
                      (apply string-append (reverse acc))
                      (loop (cons (string-append l "\n") acc)))))))))
  (let-values (((code out) (compile-and-run nb nbody-externs "2000")))
    (ck! "an argument on the command line reaches string->number and drives the loop"
         (and (zero? code)
              (equal? out '(-0.16907516382852447 -0.16907160686959147))))
    (unless (and (zero? code)
                 (equal? out '(-0.16907516382852447 -0.16907160686959147)))
      (display "       exit=") (display code)
      (display " got=") (write out) (newline)))
  (let-values (((code out) (compile-and-run nb nbody-externs)))
    (ck! "and with no argument it still takes the default, N=1000"
         (and (zero? code)
              (equal? out '(-0.16907516382852447 -0.16908760523460614))))))

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
     ;; TWO CALLERS EACH, so inline.ss leaves both alone. A procedure named by
     ;; exactly one call is spliced whatever its size (rule 2'), which would
     ;; move the call to `big` out of tail position and leave nothing to refuse.
     (string-append
      "(define (big a b c d e f g)\n"
      "  (fx+ a (fx+ b (fx+ c (fx+ d (fx+ e (fx+ f g)))))))\n"
      "(define (small p q) (big p q 1 2 3 4 5))\n"
      "(define (other u v) (big v u 5 4 3 2 1))\n"
      "(define (main)\n"
      "  (display (fx->fl (fx+ (fx+ (small 9 8) (small 1 2)) (other 3 4))))\n"
      "  (newline))\n"
      "(main)\n")
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
  ;; IDEMPOTENCE IS STRUCTURAL NOW, not luck. lower.ss's name counter used not to
  ;; reset, so a compile's output depended on how many compiles preceded it in
  ;; the process -- and this assertion passed anyway, because THIS program never
  ;; reached the collision that made the difference visible. The one below does:
  ;; it is the seven-constant program from 6gk.26, whose seventh `(fresh! "k")`
  ;; landed on the register name `k7` only when the counter started low.
  (ck! "the same source compiles to the same bytes, twice running"
       (let ((x (call-with-port (open-file-input-port a) get-bytevector-all))
             (y (call-with-port (open-file-input-port b) get-bytevector-all)))
         (equal? x y))))

;; The program that made the non-idempotence visible, asserted directly: three
;; compiles in ONE process, byte for byte. Before the counter reset this crashed
;; on the first and succeeded on the second.
(let ((src (string-append
            "(define v (make-flvector 4 0.0))\n"
            "(define (fill i n)\n"
            "  (if (fx= i n) 0.0 (begin (flvector-set! v i 1.0) (fill (fx+ i 1) n))))\n"
            "(define (main) (display (fill 0 4)) (newline))\n(main)\n"))
      (path (string-append tmp "-idem.sps")))
  (let ((p (open-file-output-port path (file-options no-fail)
                                  (buffer-mode block) (native-transcoder))))
    (put-string p src)
    (close-port p))
  (let ((a (compiled-image (compile-sonic path '(display newline))))
        (b (compiled-image (compile-sonic path '(display newline))))
        (c (compiled-image (compile-sonic path '(display newline)))))
    (ck! "three compiles of one source in one process are byte-identical"
         (and (equal? a b) (equal? b c)))))


;; --- a tail call whose arguments overflow the register set -------------------
;;
;; `tail-call-sequence` used to REFUSE this: the outgoing area has to be written
;; over the caller's own incoming area, and doing that safely needs a frame
;; layout to say what there is still live. There is one now, so it emits.
;;
;; THE ROTATION IS THE TEST, not the arity. Ten arguments passed straight
;; through make every store an identity, which would pass whether or not the
;; ordering is right. Rotating them means every outgoing slot reads a caller
;; slot that some other store overwrites, so an overwrite-before-read shows up
;; as a wrong digit rather than as luck. The digits are place-valued for the
;; same reason: any two arguments landing in the wrong order changes the answer.
(run! "a ten-argument tail call, arguments passed straight through"
      (string-append
       "(define (go a b c d e f g h i j)\n"
       "  (if (fx= a 0)\n"
       "      (fx->fl (fx+ (fx+ (fx+ (fx+ a b) (fx+ c d)) (fx+ (fx+ e f) (fx+ g h))) (fx+ i j)))\n"
       "      (go (fx- a 1) b c d e f g h i j)))\n"
       "(define (main) (display (go 5 1 2 3 4 5 6 7 8 9)) (newline))\n(main)\n")
      '(45.0))

(run! "and the same call ROTATING all ten, so a clobbered slot cannot pass"
      (string-append
       "(define (go n a b c d e f g h i j)\n"
       "  (if (fx= n 0)\n"
       "      (fx->fl (fx+ (fx* a 1000000000) (fx+ (fx* b 100000000)\n"
       "        (fx+ (fx* c 10000000) (fx+ (fx* d 1000000) (fx+ (fx* e 100000)\n"
       "        (fx+ (fx* f 10000) (fx+ (fx* g 1000) (fx+ (fx* h 100)\n"
       "        (fx+ (fx* i 10) j))))))))))\n"
       "      (go (fx- n 1) b c d e f g h i j a)))\n"
       "(define (main) (display (go 1 1 2 3 4 5 6 7 8 9 0)) (newline))\n(main)\n")
      '(2345678901.0))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
