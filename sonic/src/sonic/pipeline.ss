;;; The pipeline, end to end, over a real program.
;;;
;;; Every other test in this tree exercises one pass against hand-written
;;; fixtures, which is what `EXECUTION.md` section 1's whole parallelism
;;; argument depends on. That leaves one thing untested: whether the passes
;;; actually compose on a program nobody wrote a fixture for.
;;;
;;; This is that check. It runs `bench/nbody/config-sonic.sps` through every
;;; stage that exists and reports where it stops, so "how far does the compiler
;;; get" is a number rather than an impression.
;;;
;;; It is deliberately tolerant of missing stages. A pass that does not exist
;;; yet is a STOP with a reason, not a failure, because the pipeline is being
;;; built and a red integration test that stays red teaches nobody anything.
;;; What it must never do is report a stage as passing when it did not run.

(library (sonic pipeline)
  (export run-pipeline pipeline-result? pipeline-result-stages
          pipeline-result-reached pipeline-result-stopped-at
          pipeline-result-note
          nbody-externs)
  (import (chezscheme))

  (define-record-type (pipeline-result make-pipeline-result pipeline-result?)
    (fields stages        ; ((name . ok?) ...) in order
            reached       ; how many stages completed
            stopped-at    ; name of the first stage that did not, or #f
            note))        ; what the last value was, for eyeballing

  ;; What `config-sonic.sps` uses that it does not define. Naming them is the
  ;; point of Lcore's extern list: anything neither defined here nor named here
  ;; is a typo, and `parse-program` says so rather than silently treating it as
  ;; an opaque external reference.
  (define nbody-externs
    '(command-line length cadr string->number display newline))

  ;; Each stage is (name . thunk-of-previous-value). A stage that raises stops
  ;; the run; a stage whose module is absent is reported as unbuilt.
  (define (run-pipeline src stages)
    (let loop ((ss stages) (v src) (done '()) (n 0))
      (if (null? ss)
          (make-pipeline-result (reverse done) n #f v)
          (let* ((name (caar ss))
                 (f (cdar ss))
                 (next (guard (e (#t 'stop)) (f v))))
            (if (eq? next 'stop)
                (make-pipeline-result (reverse (cons (cons name #f) done))
                                      n name v)
                (loop (cdr ss) next (cons (cons name #t) done) (+ n 1)))))))
  )
