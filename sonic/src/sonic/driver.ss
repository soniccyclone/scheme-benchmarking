;;; The whole compiler, front to executable, in one place.
;;;
;;; This exists because there were two copies of the pipeline -- one in the
;;; build script and one inside the execution test -- and they drifted. Lambda
;;; lifting and the constant pool's alignment padding were added to one and not
;;; the other, so the test compiled a DIFFERENT program from the one being
;;; shipped and reported five failures that the shipped program did not have.
;;;
;;; A pipeline that is written down twice is a pipeline whose two halves will
;;; disagree, and the half with the tests is the one you will believe.
;;;
;;; Stage order, and why each one sits where it does:
;;;
;;;   read expand parse policy anf assign inline essa elide repr
;;;       -- the front end, unchanged
;;;   LIFT      after repr, because lifting only moves existing names into
;;;             parameter lists and essa has already made them unique, so the
;;;             storage classes computed by repr stay correct with no reruns
;;;   lower     tree to CFG
;;;   GLOBALIZE after lowering, on Lmach, because it needs to see every use as
;;;             an instruction operand rather than as a tree position
;;;   select allocate finalize
;;;   assemble  with the pool placed 16-ALIGNED past the code

(library (sonic driver)
  ;; Named `compile-sonic` rather than `compile-program`: Chez's own
  ;; `(chezscheme)` exports both `compile-program` and `compile-to-file`, and
  ;; shadowing them in a library body is an error rather than a shadow.
  (export compile-sonic compile-sonic-to-file
          compiled? compiled-image compiled-code compiled-pool
          compiled-entry compiled-listing compiled-functions
          compiled-globals compiled-lift-report)
  (import (chezscheme) (nanopass)
          (sonic lang) (sonic read) (sonic expand) (sonic parse) (sonic policy)
          (sonic anf) (sonic assign) (sonic inline) (sonic essa) (sonic elide)
          (sonic repr) (sonic lift) (sonic lower) (sonic globals)
          (sonic select) (sonic regs) (sonic regalloc) (sonic finalize)
          (sonic litpool) (sonic object) (sonic runtime) (sonic elfexec)
          (sonic order)
          (sonic target-x86-64))

  (define-record-type (compiled make-compiled compiled?)
    (fields image code pool entry listing functions globals lift-report))

  (define (compile-sonic path externs)
    (let* ((p0 (inline-program
                (assign-convert-program
                 (anf-program
                  (resolve-policy-program
                   (parse-program (expand-program (read-all-from-file path))
                                  externs)))))))
      (let*-values (((p1 elide-st) (elide-program (essa-program p0)))
                    ((p2 rp) (select-representations-program p1))
                    ((lifted lrep) (lift-program (unparse-Lrepr p2))))
        (let*-values (((prog0 lower-st) (lower-toplevel lifted 'main
                                                        (repr-report-classes rp))))
          (let* ((classes (lowered-classes))
                 (cells (global-cells lifted))
                 (prog (globalize prog0 cells classes))
                 (entry (caddr prog))
                 ;; SORTED: this list decides each global's ADDRESS, so an
                 ;; unstable order moved every global between runs.
                 (gnames (map global-cell-name (sorted-key-list cells)))
                 (gaddrs (assign-global-cells gnames)))
            (parameterize ((current-litpool (make-pool))
                           (current-vreg-classes classes)
                           (current-globals gaddrs))
              (let* ((selected (select-program x86-64-selector prog))
                     (fns (finalize-program 'x86-64 arch-x86-64 selected
                                            (cadr prog) entry classes
                                            (lowered-params)))
                     (listing (append (runtime-listing 'x86-64 entry)
                                      (apply append (map finalized-listing fns))))
                     (pool (pool-bytes (current-litpool)))
                     ;; The pool lands 16-ALIGNED past the code, so every pool
                     ;; label carries the padding. A sign mask is a 128-bit SSE
                     ;; operand and `xorpd` FAULTS on an unaligned one, which is
                     ;; how `flneg` alone came to segfault.
                     (code-size (listing-size listing))
                     (pad (- (pool-offset-for code-size) code-size))
                     (extra (map (lambda (l)
                                   (cons (pool-label (lit-offset l))
                                         (+ pad (lit-offset l))))
                                 (pool-entries (current-litpool))))
                     (o (assemble-function 'x86-64 'program listing
                                           (list (cons 'constants pool)
                                                 (cons 'extra-labels extra))))
                     (start (label-offset listing '_start))
                     (img (build-executable 'x86-64 (function-object-code o) pool
                                            (+ elf-text-vaddr start)
                                            #x600000 runtime-data-size)))
                (make-compiled img (function-object-code o) pool
                               (+ elf-text-vaddr start) listing fns
                               gnames lrep))))))))

  (define (listing-size listing)
    (let loop ((xs listing) (pc 0))
      (cond ((null? xs) pc)
            ((symbol? (car xs)) (loop (cdr xs) pc))
            (else (loop (cdr xs) (+ pc (instruction-size 'x86-64 (car xs))))))))

  (define (label-offset listing name)
    (let loop ((xs listing) (pc 0))
      (cond ((null? xs) (error 'label-offset "no such label in the listing" name))
            ((eq? (car xs) name) pc)
            ((symbol? (car xs)) (loop (cdr xs) pc))
            (else (loop (cdr xs) (+ pc (instruction-size 'x86-64 (car xs))))))))

  (define (compile-sonic-to-file path externs out)
    (let ((c (compile-sonic path externs)))
      (write-executable out (compiled-image c))
      c))
  )
