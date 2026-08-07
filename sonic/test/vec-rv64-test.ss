;;; E5-RVV. Length-agnostic vector emission, and the three things that makes
;;; different from AVX-512.
;;;
;;;   1. NO WIDTH. The loop asks the hardware how many elements it will take and
;;;      adapts, so the same bytes run on a 128-bit part and a 1024-bit one.
;;;      This file proves that by RUNNING the loop under QEMU at four different
;;;      VLEN settings and requiring bit-identical output.
;;;   2. NO TAIL. sonic/test/vec-x86-64-test.ss has a whole section for the 3 of
;;;      nbody's 7 iterations a fixed 4-lane vector leaves over. There is no
;;;      counterpart here; the last pass simply runs short.
;;;   3. `vl-live?`. `vsetvl` establishes machine state that is neither a
;;;      register the collector scavenges nor memory it can read, and resuming
;;;      without it computes a WRONG ANSWER rather than crashing.
;;;
;;; The encodings are checked byte-for-byte against riscv64-linux-gnu-gcc, not
;;; against a table written here. RVV's operand order is irregular -- `vfadd.vv
;;; vd, vs2, vs1` and `vfmacc.vv vd, vs1, vs2` disagree about which field the
;;; second operand lands in -- and a hand-written expectation reproduces a
;;; misreading as faithfully as it reproduces the manual.
;;;
;;; Run: scheme -q --libdirs src:vendor/nanopass --script test/vec-rv64-test.ss

(import (chezscheme) (nanopass) (rnrs io simple)
        (sonic lang) (sonic fixtures) (sonic elide) (sonic alias)
        (sonic loops) (sonic veclegal) (sonic differential)
        (sonic gcmeta) (sonic preempt)
        (only (sonic encode-rv64) above-baseline-extension)
        (sonic vec-rv64))

(define failures 0) (define checks 0)

(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define (check! name got expected)
  (set! checks (+ checks 1))
  (if (equal? got expected)
      (printf "  ok   ~a\n" name)
      (begin (set! failures (+ failures 1))
             (printf "  FAIL ~a\n         expected ~s\n         got      ~s\n"
                     name expected got))))

(define (raises? thunk) (guard (e (#t #t)) (thunk) #f))

(define (raises-naming? thunk needle)
  (guard (e (#t (let ((s (call-with-string-output-port
                          (lambda (p) (if (condition? e) (display-condition e p)
                                          (write e p))))))
                  (let loop ((i 0))
                    (cond ((> (+ i (string-length needle)) (string-length s)) #f)
                          ((string=? (substring s i (+ i (string-length needle))) needle) #t)
                          (else (loop (+ i 1))))))))
    (thunk) #f))

;;; ==========================================================================
;;; 1. The fixture, and the verdict
;;; ==========================================================================

(define (elided e facts)
  (let-values ([(out st) (elide e facts)]) out))

(define nbody-facts
  '((b flvector 35) (i interval 0 posinf) (n interval 5 5)
    (k interval 0 6) (seven interval 7 7)))

(define (access-chain)
  (let find ([e (elided (nbody-inner-ssa) nbody-facts)])
    (nanopass-case (Lssa Expr) e
      [(let ([,x ,se]) ,body) (find body)]
      [(if ,x ,e0 ,e1) (find e0)]
      [(sigma ,x0 ,x1 ,pr ,x2 ,b ,body) body]
      [else e])))

(define (nbody-loops)
  (with-output-language (Lssa Expr)
    `(let ([zero (quote 0)])
       (let ([five (quote 5)])
         (let ([seven (quote 7)])
           (let ([one (quote 1)])
             (letrec ([bodies
                       (lambda (i.p n.p)
                         (phi ([i (entry i.p)] [n (entry n.p)])
                           (let ([c1 (primcall fx< () i n)])
                             (if c1
                                 (sigma i2 i fx< n #f
                                   (letrec
                                     ([pairs
                                       (lambda (j.p q.p)
                                         (phi ([j (entry j.p)] [q (entry q.p)])
                                           (let ([c3 (primcall fx< () j q)])
                                             (if c3
                                                 (sigma j.g j fx< q #f
                                                   (let ([j2 (primcall
                                                               fx+ ([overflow-check checked])
                                                               j.g one)])
                                                     (tailcall pairs j2 q)))
                                                 (quote 0)))))]
                                      [fields
                                       (lambda (k.p m.p)
                                         (phi ([k (entry k.p)] [m (entry m.p)])
                                           (let ([c2 (primcall fx< () k m)])
                                             (if c2
                                                 (sigma k.g k fx< m #f
                                                   (seq ,(access-chain)
                                                        (let ([k2 (primcall
                                                                    fx+ ([overflow-check checked])
                                                                    k.g one)])
                                                          (tailcall fields k2 m))))
                                                 (quote 0)))))])
                                     (let ([j0 (primcall fx+ ([overflow-check checked])
                                                         i2 one)])
                                       (let ([r1 (call pairs j0 n)])
                                         (let ([r2 (call fields zero seven)])
                                           (let ([i.n (primcall fx+ ([overflow-check checked])
                                                                i2 one)])
                                             (tailcall bodies i.n n)))))))
                                 (quote 0)))))])
               (tailcall bodies zero five))))))))

(define (verdict-for e tbl name)
  (let scan ([vs (vectorize-legal e tbl)])
    (cond [(null? vs) #f]
          [(eq? (vl-loop (car vs)) name) (car vs)]
          [else (scan (cdr vs))])))

(define fields-verdict (verdict-for (nbody-loops) #f 'fields))
(define pairs-verdict (verdict-for (nbody-loops) #f 'pairs))

(display "\n-- what veclegal says --\n")
(vl-report fields-verdict)

(ck! "nbody's fields loop is vectorizable" (vl-legal? fields-verdict))
(check! "and its element is an unboxed double" (vl-elt-class fields-verdict) 'raw-f64)

(define plan (rvv-plan-for-verdict fields-verdict #f))
(define plan/fma (rvv-plan-for-verdict fields-verdict #t))

(check! "SEW is 64, fixed by the element class and not by a register name"
        (rvv-plan-sew plan) 64)
(check! "and the vtype is the length-agnostic one" (rvv-plan-vtype plan)
        '(e64 m1 ta ma))
(ck! "a refused loop cannot be planned here either"
     (raises? (lambda () (rvv-plan-for-verdict pairs-verdict #f))))
(ck! "and the refusal says length agnosticism does not make it legal"
     (raises-naming? (lambda () (rvv-plan-for-verdict pairs-verdict #f))
                     "length agnosticism"))

;;; ==========================================================================
;;; 2. The loop, and what it does NOT contain
;;; ==========================================================================
;;
;; `f[k] += v[k] * dt` over the 7 doubles per body, with dt splatted from an
;; FPR. The splat is inside the loop because vl changes on every pass and a
;; splat writes exactly vl elements.

(define (kernel-for fptr vptr)
  (cons `(vsplat 2 fa0) (nbody-fields-kernel fptr vptr 2)))

(define kernel (kernel-for 'a0 'a1))

(define listing (rvv-emit-loop plan kernel '(a0 a1) 'a2 't0 't1 'sonic_vec_loop))
(define listing/fma
  (rvv-emit-loop plan/fma kernel '(a0 a1) 'a2 't0 't1 'sonic_vec_loop))

(display "\n-- the length-agnostic loop, contraction OFF --\n")
(for-each (lambda (i) (display "   ") (write i) (newline)) listing)
(display "-- and contraction ON, by permission --\n")
(for-each (lambda (i) (display "   ") (write i) (newline)) listing/fma)

(define (instrs-of l) (filter pair? l))
(define (mnemonics l) (map car (instrs-of l)))

(check! "the whole loop, unfused" (instrs-of listing)
        '((vsetvli t0 a2 (e64 m1 ta ma))
          (vfmv.v.f v2 fa0)
          (vle64.v v0 a0)
          (vle64.v v1 a1)
          (vfmul.vv v31 v1 v2)
          (vfadd.vv v0 v0 v31)
          (vse64.v v0 a0)
          (slli t1 t0 3)
          (add a0 a0 t1)
          (add a1 a1 t1)
          (sub a2 a2 t0)
          (bne a2 zero sonic_vec_loop)))

(ck! "the vector length is READ at run time, not chosen at compile time"
     (memq 'vsetvli (mnemonics listing)))
(ck! "it is packed f64 arithmetic" (memq 'vfmul.vv (mnemonics listing)))
(ck! "the loop closes on itself, so a short last pass needs no separate code"
     (let ((last (car (reverse (instrs-of listing)))))
       (and (eq? (car last) 'bne)
            (eq? (list-ref last 3) 'sonic_vec_loop))))
(ck! "and there is NO tail: nothing in the listing is a scalar float op"
     (not (exists (lambda (m) (memq m '(fld fsd fmul.d fadd.d fmadd.d)))
                  (mnemonics listing))))

;; The layout obligation the restart decision rests on.
(let* ((is (instrs-of listing))
       (store-at (let loop ((xs is) (i 0))
                   (cond ((null? xs) #f)
                         ((eq? (caar xs) 'vse64.v) i)
                         (else (loop (cdr xs) (+ i 1))))))
       (bump-at (let loop ((xs is) (i 0))
                  (cond ((null? xs) #f)
                        ((eq? (caar xs) 'slli) i)
                        (else (loop (cdr xs) (+ i 1)))))))
  (ck! "every pointer bump comes AFTER the store, which is what makes a rewind idempotent"
       (and store-at bump-at (< store-at bump-at))))

;;; ==========================================================================
;;; 3. D24 again: contraction is a permission on this target too
;;; ==========================================================================

(check! "WITHOUT the permission, no fused mnemonic"
        (rvv-contraction-evidence listing) '())
(check! "and the multiply and the add keep their two roundings"
        (filter (lambda (m) (memq m '(vfmul.vv vfadd.vv))) (mnemonics listing))
        '(vfmul.vv vfadd.vv))
(check! "WITH it, exactly one vfmacc.vv"
        (rvv-contraction-evidence listing/fma) '(vfmacc.vv))
(ck! "check-fp-policy! accepts the unfused loop under the bit-exact policy"
     (fp-policy? (check-fp-policy! bit-exact-policy
                                  (rvv-contraction-evidence listing)
                                  'vec-rv64-test)))
(ck! "and REFUSES the fused one, naming D24"
     (raises-naming? (lambda () (check-fp-policy! bit-exact-policy
                                                  (rvv-contraction-evidence listing/fma)
                                                  'vec-rv64-test))
                     "D24"))

;;; ==========================================================================
;;; 4. vl-live?, and the decision the bead owed
;;; ==========================================================================
;;
;; sonic/doc/gc-metadata.md left it open whether restart regions extend to a
;; vsetvl-established context. They do, and the reason is the layout checked
;; above: the region ends at the last vector instruction, so a rewind re-runs
;; the vsetvli and then the same loads and the same store from pointers nothing
;; has advanced yet.

(define frame-bits '(#f #f))

(define-values (entries region) (rvv-loop-metadata listing frame-bits))

(display "\n-- the metadata a vector loop contributes --\n")
(for-each (lambda (e)
            (printf "   at ~a: ~s\n" (entry-offset e) (entry-flags e)))
          entries)
(printf "   restart region ~a [~a, ~a)\n"
        (region-name region) (region-start region) (region-end region))

(check! "two entries, because the answer changes exactly twice" (length entries) 2)
(ck! "vl comes live at the vsetvli"
     (and (= (entry-offset (car entries)) 0)
          (= (cdr (assq 'vl-live? (entry-flags (car entries)))) 1)))
(ck! "and dies after the last vector instruction"
     (= (cdr (assq 'vl-live? (entry-flags (cadr entries)))) 0))
(check! "the live span is the vsetvli plus the six vector instructions"
        (entry-offset (cadr entries)) (* 4 7))
(ck! "the restart region is that same span, and no wider"
     (and (= (region-start region) 0)
          (= (region-end region) (entry-offset (cadr entries)))))
(ck! "so the pointer bumps and the back branch are OUTSIDE it"
     (< (region-end region) (* 4 (length (instrs-of listing)))))
(ck! "a PC inside the region rewinds to the vsetvli, which re-establishes vl"
     (= (rewind-pc (region-table-add! (make-region-table) region) 16) 0))
(ck! "and a PC past it is left exactly where it was"
     (= (rewind-pc (region-table-add! (make-region-table) region) 40) 40))

;; The field is a real wire-format field, not a comment. Round-trip it.
(let* ((bv (encode-metadata target-rv64 entries))
       (back (decode-metadata target-rv64 bv)))
  (ck! "vl-live? survives the RV64 metadata encoding"
       (and (= (length back) 2)
            (= (cdr (assq 'vl-live? (entry-flags (car back)))) 1)
            (= (cdr (assq 'vl-live? (entry-flags (cadr back)))) 0)))
  (ck! "and x86-64's vocabulary still has no such field, per gc-metadata.md"
       (not (assq 'vl-live? (target-flag-names target-x86-64)))))

;;; ==========================================================================
;;; 5. The rv64gc scalar fallback
;;; ==========================================================================
;;
;; harness/smoke-riscv.sh runs PROFILE=legacy against rv64gc, which has no V.
;; The same kernel, scalar, and nothing in it above the floor.

(define scalar-kernel-listing (rv64gc-emit-loop plan (nbody-fields-kernel 'a0 'a1 2)))
(define scalar-kernel/fma (rv64gc-emit-loop plan/fma (nbody-fields-kernel 'a0 'a1 2)))

;; The runnable form. The vector loop has to re-splat dt on every pass because
;; vl changes; the scalar one does it once, in a prologue, and that asymmetry is
;; a real consequence of the vector length being a run-time value.
(define scalar-run-listing (cons '(fsgnj.d ft2 fa0 fa0) scalar-kernel-listing))

(display "\n-- the rv64gc fallback, first two of seven iterations --\n")
(for-each (lambda (i) (display "   ") (write i) (newline))
          (list-head scalar-kernel-listing 7))

(check! "seven iterations, five instructions each, unfused"
        (length scalar-kernel-listing) (* 7 5))
(check! "the first iteration" (list-head scalar-kernel-listing 5)
        '((fld ft0 a0 0) (fld ft1 a1 0)
          (fmul.d ft11 ft1 ft2) (fadd.d ft0 ft0 ft11) (fsd ft0 a0 0)))
(check! "and the second walks on by one double"
        (list-head (list-tail scalar-kernel-listing 5) 2)
        '((fld ft0 a0 8) (fld ft1 a1 8)))
(ck! "NOTHING in the fallback is above the rv64gc floor"
     (not (exists (lambda (i) (above-baseline-extension (car i)))
                  scalar-kernel-listing)))
(ck! "and nothing in it is a vector instruction"
     (not (exists (lambda (i) (rvv-vector-instr? (car i))) scalar-kernel-listing)))
(check! "with the permission the fallback fuses too, to fmadd.d"
        (rvv-contraction-evidence scalar-kernel/fma)
        (map (lambda (x) 'fmadd.d) (iota 7)))

;; The base encoder must still refuse the vector path, with the extension named.
(ck! "the base rv64gc encoder refuses vfsub.vv and names V, not `no such instruction`"
     (and (eq? (above-baseline-extension 'vfsub.vv) 'V)
          (eq? (above-baseline-extension 'vfmv.v.f) 'V)
          (eq? (above-baseline-extension 'vmv.v.v) 'V)))

;;; ==========================================================================
;;; 6. THE differential check, against binutils
;;; ==========================================================================

(define tmp
  (let ((d (string-append (or (getenv "TMPDIR") "/tmp") "/sonic-vec-rv64-test")))
    (system (string-append "mkdir -p " d)) d))

(define (path . parts) (apply string-append tmp "/" parts))

(define (read-all-lines file)
  (call-with-input-file file
    (lambda (p)
      (let loop ((acc '()))
        (let ((l (get-line p)))
          (if (eof-object? l) (reverse acc) (loop (cons l acc))))))))

(define (split str ch)
  (let loop ((i 0) (start 0) (acc '()))
    (cond ((= i (string-length str)) (reverse (cons (substring str start i) acc)))
          ((char=? (string-ref str i) ch)
           (loop (+ i 1) (+ i 1) (cons (substring str start i) acc)))
          (else (loop (+ i 1) start acc)))))

(define (trim s)
  (let* ((n (string-length s))
         (a (let loop ((i 0)) (if (and (< i n) (char-whitespace? (string-ref s i)))
                                  (loop (+ i 1)) i)))
         (b (let loop ((i n)) (if (and (> i a) (char-whitespace? (string-ref s (- i 1))))
                                  (loop (- i 1)) i))))
    (substring s a b)))

;; --- the assembly printer -------------------------------------------------
;; Operand order is the assembler's, which is what the encoder's table also
;; uses, so this printer is total over the table by construction rather than by
;; someone remembering to extend it.

(define offset-form '(ld lw fld sd sw fsd jalr))
(define paren-form '(vle64.v vse64.v))
(define vtype-form '(vsetvli vsetivli))

(define (op->string x) (if (symbol? x) (symbol->string x) (number->string x)))

(define (commas xs)
  (cond ((null? xs) "")
        ((null? (cdr xs)) (car xs))
        (else (string-append (car xs) "," (commas (cdr xs))))))

(define (instr->asm i)
  (let ((mn (car i)) (o (cdr i)))
    (string-append
     (symbol->string mn) "\t"
     (cond
      ((memq mn paren-form)
       (string-append (op->string (car o)) ",(" (op->string (cadr o)) ")"))
      ((memq mn vtype-form)
       (commas (list (op->string (car o)) (op->string (cadr o))
                     (commas (map op->string (caddr o))))))
      ((memq mn offset-form)
       (string-append (op->string (car o)) ","
                      (op->string (caddr o)) "(" (op->string (cadr o)) ")"))
      (else (commas (map op->string o)))))))

;; Every mnemonic the vector encoder knows appears here. Immediates and
;; registers are chosen to exercise both ends of the fields, and both operand
;; conventions -- vv and vv-macc -- are present with DISTINCT registers so a
;; swapped vs1/vs2 cannot pass.
(define coverage-listing
  '((vsetvli t0 a2 (e64 m1 ta ma))
    (vsetvli t0 zero (e64 m1 ta ma))
    (vsetvli a5 a4 (e32 m2 tu mu))
    (vsetvli s2 s3 (e64 m8 ta mu))
    (vsetivli t1 4 (e64 m1 ta ma))
    (vsetivli a0 31 (e8 mf2 tu ma))
    (vsetvl t0 a2 a3)
    (vle64.v v0 a0)
    (vle64.v v31 t6)
    (vse64.v v1 a1)
    (vse64.v v30 s11)
    (vfadd.vv v3 v1 v2)
    (vfsub.vv v13 v11 v12)
    (vfmul.vv v23 v21 v22)
    (vfdiv.vv v31 v29 v30)
    (vadd.vv v3 v1 v2)
    (vfmacc.vv v0 v1 v2)
    (vfmacc.vv v20 v21 v22)
    (vfsqrt.v v4 v5)
    (vfsqrt.v v28 v29)
    (vfmv.v.f v2 fa0)
    (vfmv.v.f v17 ft11)
    (vmv.v.v v6 v7)
    (fmadd.d fa0 fa1 fa2 fa3)
    (fmadd.d ft0 fs11 ft11 fs2)
    ;; the scalar bookkeeping the loop is made of, which the vector encoder
    ;; passes through to sonic/src/sonic/encode-rv64.ss rather than duplicating
    (slli t1 t0 3)
    (add a0 a0 t1)
    (sub a2 a2 t0)
    (fld ft0 a0 0)
    (fsd ft0 a0 48)
    (fmul.d ft11 ft1 ft2)
    (fadd.d ft0 ft0 ft11)
    (jalr zero ra 0)))

(ck! "the differential listing covers EVERY mnemonic the vector encoder knows"
     (let ((covered (map car coverage-listing)))
       (for-all (lambda (mn) (memq mn covered)) (rvv-mnemonics))))

(define asm-available?
  (zero? (system "riscv64-linux-gnu-gcc --version >/dev/null 2>&1")))

(unless asm-available?
  (display "  FAIL riscv64-linux-gnu-gcc is not installed, and this encoder's\n")
  (display "       correctness is DEFINED as agreement with it.\n")
  (set! failures (+ failures 1))
  (set! checks (+ checks 1)))

(define (hex-digit? c)
  (or (char-numeric? c) (and (char>=? c #\a) (char<=? c #\f))))

(define (downcase s) (list->string (map char-downcase (string->list s))))

(define (assemble-listing tag march listing)
  (let ((s (path tag ".s")) (o (path tag ".o")) (d (path tag ".dis")))
    (when (file-exists? s) (delete-file s))
    (call-with-output-file s
      (lambda (p)
        (display ".option norvc\n.text\n.globl sonic_cover\nsonic_cover:\n" p)
        (for-each (lambda (x)
                    (if (symbol? x)
                        (begin (display (symbol->string x) p) (display ":\n" p))
                        (begin (display "\t" p) (display (instr->asm x) p)
                               (newline p))))
                  listing)))
    (unless (zero? (system (string-append
                            "riscv64-linux-gnu-gcc -march=" march " -mabi=lp64d -c "
                            s " -o " o " 2>" (path tag ".err"))))
      (error 'assemble-listing "the real assembler rejected our listing; see"
             (path tag ".err")))
    (unless (zero? (system (string-append
                            "riscv64-linux-gnu-objdump -d -M no-aliases " o
                            " > " d " 2>/dev/null")))
      (error 'assemble-listing "objdump failed" d))
    (let loop ((ls (read-all-lines d)) (acc '()))
      (if (null? ls)
          (reverse acc)
          (let ((fs (split (car ls) #\tab)))
            (if (and (>= (length fs) 3)
                     (let ((a (trim (car fs))))
                       (and (> (string-length a) 1)
                            (char=? (string-ref a (- (string-length a) 1)) #\:)
                            (hex-digit? (string-ref a 0)))))
                (loop (cdr ls) (cons (list (trim (car fs)) (trim (cadr fs))
                                           (trim (caddr fs)))
                                     acc))
                (loop (cdr ls) acc)))))))

(define (hex-of-word w)
  (let ((s (downcase (number->string w 16))))
    (string-append (make-string (- 8 (string-length s)) #\0) s)))

(define verified 0)

(define (differential! tag march listing)
  (let* ((ref (assemble-listing tag march listing))
         (ours (rvv-encode-listing listing))
         (is (filter pair? listing)))
    (ck! (string-append tag ": binutils produced one word per instruction")
         (= (length ref) (length is)))
    (let loop ((rs ref) (i 0) (bad '()))
      (if (null? rs)
          (begin
            (ck! (string-append tag ": all " (number->string (length ref))
                                " instructions encode BYTE-IDENTICALLY to binutils")
                 (null? bad))
            (set! verified (+ verified (- (length ref) (length bad))))
            (unless (null? bad)
              (for-each (lambda (b) (display "         ") (write b) (newline))
                        (reverse bad))))
          (let* ((theirs (cadr (car rs)))
                 (mine (hex-of-word
                        (let ((bs (list-tail ours (* 4 i))))
                          (+ (car bs) (* 256 (cadr bs))
                             (* 65536 (caddr bs)) (* 16777216 (cadddr bs)))))))
            (loop (cdr rs) (+ i 1)
                  (if (string=? theirs mine)
                      bad
                      (cons (list (list-ref is i) 'binutils theirs 'ours mine) bad))))))
    ;; And the round trip: objdump must read back the mnemonic we asked for.
    (let loop ((rs ref) (xs is) (bad '()))
      (if (null? rs)
          (begin
            (ck! (string-append tag ": and every one disassembles back to the mnemonic we emitted")
                 (null? bad))
            (unless (null? bad)
              (for-each (lambda (b) (display "         ") (write b) (newline))
                        (reverse bad))))
          (loop (cdr rs) (cdr xs)
                (if (string=? (caddr (car rs)) (symbol->string (caar xs)))
                    bad
                    (cons (list (car xs) '-> (caddr (car rs))) bad)))))))

(when asm-available?
  (display "\n-- differential against binutils --\n")
  (differential! "cover" "rv64gcv" coverage-listing)
  (differential! "loop" "rv64gcv" listing)
  (differential! "loopfma" "rv64gcv" listing/fma)
  ;; The fallback assembles under the LEGACY floor, which is the whole point of
  ;; having one. `vsetvli` does not exist there.
  (differential! "fallback" "rv64gc" scalar-run-listing)
  (ck! "the vector loop is REFUSED by the rv64gc assembler, so the floor is real"
       (not (zero? (system
                    (string-append
                     "riscv64-linux-gnu-gcc -march=rv64gc -mabi=lp64d -c "
                     (path "loop.s") " -o " (path "floor.o") " 2>/dev/null"))))))

;;; ==========================================================================
;;; 7. Running it: a vector length the loop did not know at compile time
;;; ==========================================================================
;;
;; The bead's acceptance criterion. The SAME assembled function, run under QEMU
;; at VLEN 128, 256, 512 and 1024, must produce bit-identical results and must
;; agree with the scalar reference. That is what "length agnostic" means, and it
;; is not something a disassembly can show.

;; qemu comes from PATH. It used to default to ~/.local/bin/qemu-riscv64 --
;; a wrapper around a package unpacked by hand, from before there was a
;; container to install things in properly. Inside the container that path does
;; not exist, so the whole length-agnostic section silently reported itself
;; missing.
(define qemu (or (getenv "QEMU_RISCV") "qemu-riscv64"))

;; Probed by RUNNING it rather than by `file-exists?`, since a name on PATH has
;; no path to test.
(define qemu-available?
  (zero? (system (string-append qemu " -version >/dev/null 2>&1"))))

(define (write-function! file march name listing)
  (call-with-output-file file
    (lambda (p)
      (display ".option norvc\n.text\n.globl " p) (display name p) (newline p)
      (display name p) (display ":\n" p)
      (for-each (lambda (x)
                  (if (symbol? x)
                      (begin (display (symbol->string x) p) (display ":\n" p))
                      (begin (display "\t" p) (display (instr->asm x) p) (newline p))))
                listing)
      (display "\tjalr\tzero,ra,0\n" p))
    'replace))

;; void step(double *f, double *v, double dt, long n)  ->  a0 a1 fa0 a2
(define driver-c
  (string-append
   "#include <stdio.h>\n#include <string.h>\n"
   "void step(double*, double*, double, long);\n"
   "int main(void){\n"
   "  double f[7], v[7], r[7];\n"
   "  for (int i=0;i<7;i++){ f[i]=i*1.5+0.3; v[i]=i*0.25+1.0; r[i]=f[i]+v[i]*0.125; }\n"
   "  step(f, v, 0.125, 7);\n"
   "  for (int i=0;i<7;i++) printf(\"%.17g \", f[i]);\n"
   "  printf(\"%s\\n\", memcmp(f,r,sizeof f)==0 ? \"MATCH\" : \"DIFFER\");\n"
   "  return 0;\n}\n"))

(define (capture cmd)
  (let ((out (path "run.out")))
    (system (string-append cmd " > " out " 2>/dev/null"))
    (let ((ls (read-all-lines out)))
      (if (null? ls) "" (trim (car ls))))))

(when (and asm-available? qemu-available?)
  (display "\n-- running the emitted loop under QEMU --\n")
  (call-with-output-file (path "driver.c") (lambda (p) (display driver-c p)) 'replace)
  ;; The loop as emitted, plus a return. The bytes were already proved identical
  ;; to what binutils makes of this same listing, so assembling the text here is
  ;; running OUR encoding.
  (write-function! (path "step.s") "rv64gcv" "step" listing)
  (write-function! (path "stepgc.s") "rv64gc" "step" scalar-run-listing)
  (let ((build
         (lambda (asm march exe)
           (zero? (system (string-append
                           "riscv64-linux-gnu-gcc -march=" march " -mabi=lp64d -O2 "
                           "-ffp-contract=off -static -o " (path exe) " "
                           (path "driver.c") " " (path asm) " 2>/dev/null"))))))
    (ck! "the vector function links into a real RISC-V executable"
         (build "step.s" "rv64gcv" "vrun"))
    (ck! "and so does the rv64gc fallback, under the legacy floor"
         (build "stepgc.s" "rv64gc" "grun")))
  (let ((results
         (map (lambda (vlen)
                (cons vlen
                      (capture (string-append qemu " -cpu max,vlen=" (number->string vlen)
                                              " " (path "vrun")))))
              '(128 256 512 1024))))
    (for-each (lambda (r) (printf "   vlen=~a  ~a\n" (car r) (cdr r))) results)
    (ck! "the vector loop computes the RIGHT answer at every vector length"
         (for-all (lambda (r)
                    (and (> (string-length (cdr r)) 5)
                         (let ((s (cdr r)))
                           (string=? (substring s (- (string-length s) 5)
                                                (string-length s))
                                     "MATCH"))))
                  results))
    (ck! "and the SAME BYTES give bit-identical results across all four lengths"
         (let ((first (cdar results)))
           (for-all (lambda (r) (string=? (cdr r) first)) results)))
    (let ((g (capture (string-append qemu " " (path "grun")))))
      (printf "   rv64gc  ~a\n" g)
      (ck! "the rv64gc scalar fallback agrees with the vector path, bit for bit"
           (string=? g (cdar results))))))

(unless (and asm-available? qemu-available?)
  (display "  FAIL the RISC-V toolchain or qemu-riscv64 is missing, and the\n")
  (display "       length-agnostic claim is DEFINED by running at several VLEN.\n")
  (set! failures (+ failures 1))
  (set! checks (+ checks 1)))

;;; ==========================================================================
;;; 8. Refusals
;;; ==========================================================================

(ck! "a bad vtype is refused rather than packed as zero"
     (raises? (lambda () (vtype-bits '(e128 m1 ta ma)))))
(ck! "and so is a vtype of the wrong shape"
     (raises? (lambda () (vtype-bits '(e64 m1 ta)))))
(check! "the e64/m1/ta/ma vtype is 0xd8, which is what binutils encodes"
        (vtype-bits '(e64 m1 ta ma)) #xd8)
(ck! "a GPR where a vector register belongs is refused"
     (raises? (lambda () (rvv-encode-word '(vfadd.vv a0 v1 v2)))))
(ck! "a vsetivli count above 31 does not fit the field and says so"
     (raises-naming? (lambda () (rvv-encode-word '(vsetivli t0 32 (e64 m1 ta ma))))
                     "5-bit"))
(ck! "an undefined label in a listing is refused"
     (raises-naming? (lambda () (rvv-encode-listing '((bne a0 zero nowhere))))
                     "undefined"))
(ck! "the vl register cannot double as a data pointer"
     (raises? (lambda () (rvv-emit-loop plan kernel '(a0 t0) 'a2 't0 't1 'l))))
(ck! "the unfused lowering refuses to clobber the scratch lane"
     (raises-naming? (lambda () (rvv-emit-kernel plan '((vmuladd 31 1 2))))
                     "scratch"))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures, ")
(display verified) (display " instructions verified byte-for-byte against binutils")
(newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
