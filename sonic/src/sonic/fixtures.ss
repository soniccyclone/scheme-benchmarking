;;; Fixture vocabulary.
;;;
;;; E1-FIX and E2-LIR. This is the module that keeps the DAG wide.
;;;
;;; EXECUTION.md section 1's argument is that freezing the inter-stage IRs turns
;;; a depth-13 chain into a depth-4 DAG, because a pass then depends on the
;;; CONTRACT rather than on its upstream neighbour. That only works if a pass
;;; author can construct valid input for their own stage without importing an
;;; upstream pass. This file is where those inputs live.
;;;
;;; If you are writing a pass and find yourself importing the pass before you in
;;; order to get test input, stop: add a fixture here instead. A bead that
;;; cannot be tested without another incomplete bead is drawn wrong.

(library (sonic fixtures)
  (export store-mach flcmp-mach
          nbody-inner-anf
          nbody-inner-ssa
          nbody-inner-repr
          nbody-inner-mach
          straight-line-anf diamond-anf loop-anf
          show)
  (import (chezscheme) (nanopass) (sonic lang))

  ;; Print any IR value. nanopass does not export the per-language record
  ;; predicates, so this tries each unparser rather than dispatching on type.
  ;; Order matters: the extended languages accept their parent's forms, so the
  ;; most specific unparser has to be tried first or everything prints as Lcore.
  (define (show x)
    (let try ([us (list unparse-Lmach unparse-Lrepr unparse-Lssa
                        unparse-Lanf unparse-Lcore)])
      (if (null? us)
          x
          (guard (e (#t (try (cdr us))))
            ((car us) x)))))

  ;; --- the shapes every analysis pass needs ---------------------------------

  ;; No control flow. A pass that inserts phi or sigma here has a bug.
  (define (straight-line-anf)
    (with-output-language (Lanf Expr)
      `(let ([a (quote 1)])
         (let ([b (quote 2)])
           (let ([c (primcall fx+ ([overflow-check checked]) a b)])
             c)))))

  ;; One join. Exactly one phi belongs at the merge.
  (define (diamond-anf)
    (with-output-language (Lanf Expr)
      `(let ([t (primcall fx< () i n)])
         (if t
             (let ([x (quote 1)]) x)
             (let ([x (quote 2)]) x)))))

  ;; A loop header. phi at the header; the back edge carries the induction step.
  (define (loop-anf)
    (with-output-language (Lanf Expr)
      `(let ([t (primcall fx< () i n)])
         (if t
             (let ([i2 (primcall fx+ ([overflow-check checked]) i one)])
               (tailcall loop i2 n))
             (quote 0)))))

  ;; --- nbody's inner loop, at each stage ------------------------------------
  ;;
  ;; This is the ONE program the whole project is measured on, so it gets a
  ;; fixture at every level. `b[i*7 + k]` against a length-35 flvector, which is
  ;; the exact access `analyze.ss` already proves eliminable and the exact access
  ;; Chez's level-1 lattice cannot.

  (define (nbody-inner-anf)
    (with-output-language (Lanf Expr)
      `(let ([off (primcall fx* ([overflow-check checked]) i seven)])
         (let ([idx (primcall fx+ ([overflow-check checked]) off k)])
           (let ([val (primcall flvector-ref ([type-check checked] [bounds-check checked]) b idx)])
             val)))))

  ;; After e-SSA. The guard has named the fact that makes the check provable.
  (define (nbody-inner-ssa)
    (with-output-language (Lssa Expr)
      `(let ([t (primcall fx< () i n)])
         (if t
             (sigma i2 i fx< n #f
               (let ([off (primcall fx* ([overflow-check checked]) i2 seven)])
                 (let ([idx (primcall fx+ ([overflow-check checked]) off k)])
                   (let ([val (primcall flvector-ref
                                        ([type-check checked] [bounds-check checked])
                                        b idx)])
                     val))))
             (quote 0)))))

  ;; After representation selection. Note `idx` is a raw-word and `val` is a
  ;; raw-f64: neither is tagged, so neither is scavenged, which is what makes
  ;; the inner loop free of GC metadata entirely.
  (define (nbody-inner-repr)
    (with-output-language (Lrepr Expr)
      `(let ([off raw-word (primcall fx* ([overflow-check unchecked]) i seven)])
         (let ([idx raw-word (primcall fx+ ([overflow-check unchecked]) off k)])
           (let ([val raw-f64 (primcall flvector-ref
                                        ([type-check proved] [bounds-check proved])
                                        b idx)])
             val)))))

  ;; PINS the shape of `store`. The x86-64 agent had to guess this and said so:
  ;; `store` has no result, but the Instr production makes the destination slot
  ;; mandatory, and `live-intervals` in regalloc.ss treats that slot as a
  ;; DEFINITION. Putting the stored value there would record a def where there
  ;; is a use and shorten its live range, which is a miscompile. So the slot is
  ;; unused and the value rides in the sources.
  (define (store-mach)
    (with-output-language (Lmach Prog)
      `(program
        ([entry (block ((const v-i raw-word 0)
                        (store v-unused raw-f64 v-b v-i v-val))
                       (ret v-unused))])
        entry)))

  ;; PINS flonum comparison as distinct from integer comparison. Both targets
  ;; need different instructions for it and a single cmp-lt could not say which.
  (define (flcmp-mach)
    (with-output-language (Lmach Prog)
      `(program
        ([entry (block ((fcmp-lt v-t raw-word v-a v-b))
                       (branch-if v-t then else))]
         [then (block () (ret v-a))]
         [else (block () (ret v-b))])
        entry)))

  ;; Lowered. THE fixture both target selectors must consume, per E2-LIR's
  ;; acceptance criterion.
  ;;
  ;; Read what is and is not here. There is no `chk` instruction: the bounds and
  ;; type checks were discharged by the analysis, so nothing survives to
  ;; codegen. The scale on the load is 8 because an f64 is 8 bytes, and that is
  ;; a machine-independent fact both ISAs share. Everything else is a vreg, so
  ;; the allocator is free to place them under the partition.
  (define (nbody-inner-mach)
    (with-output-language (Lmach Prog)
      `(program
        ([entry
          (block ((const v-seven raw-word 7)
                  (mul   v-off   raw-word v-i v-seven)
                  (add   v-idx   raw-word v-off v-k)
                  (load  v-val   raw-f64  v-b v-idx))
                 (ret v-val))])
        entry)))
  )
