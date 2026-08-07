#!r6rs
;;; SonicScheme forms, as no-ops for a host Scheme.
;;;
;;; `config-sonic.sps` is written in SonicScheme's surface syntax, which is a
;;; subset of R7RS plus four declaration forms that no other Scheme has. Those
;;; four are PREMISES and PERMISSIONS: they tell a compiler what it may assume
;;; or may do, and they never change what a program computes. So a host that
;;; does not know them can discard them and still get the right answer, which is
;;; what this library is for, and it is what makes the same file both a
;;; SonicScheme benchmark and a Chez program whose energy can be checked against
;;; `SPEC.md`.
;;;
;;; That property is worth stating plainly, because it is the whole reason these
;;; are declarations rather than operators: DROPPING THEM IS ALWAYS SOUND. A
;;; compiler that ignores `declare-distinct` loses a vectorization; a compiler
;;; that ignores `policy` emits a check it was allowed to skip. Neither computes
;;; a different number. The reverse is not true, which is why `(sonic alias)`
;;; calls violating `declare-distinct` undefined behaviour.
;;;
;;; The three procedures are here for a duller reason: SonicScheme's primitive
;;; table names them and Chez does not have them.

(library (sonic-compat)
  (export declare-distinct declare policy flneg fxneg fx->fl fl->fx)
  (import (chezscheme))

  ;; (declare-distinct (a b ...) body ...) -- C99's `restrict`, as a premise.
  (define-syntax declare-distinct
    (syntax-rules ()
      ((_ (v ...) b1 b2 ...) (let () b1 b2 ...))))

  ;; (declare ((x premise) ...) body ...) -- facts about a variable.
  (define-syntax declare
    (syntax-rules ()
      ((_ ((x p) ...) b1 b2 ...) (let () b1 b2 ...))))

  ;; (policy ((check on?) ...) body ...) -- lexical check policy, D5.
  (define-syntax policy
    (syntax-rules ()
      ((_ ((c on) ...) b1 b2 ...) (let () b1 b2 ...))))

  ;; IEEE negation, not subtraction from zero. SPEC.md item 0: the two disagree
  ;; at 0.0, where subtraction gives 0.0 and negation gives -0.0, and the sign
  ;; survives the divide that follows. Chez's unary `fl-` is the real thing.
  (define (flneg x) (fl- x))
  (define (fxneg x) (fx- x))

  (define (fx->fl x) (fixnum->flonum x))
  (define (fl->fx x) (exact (flround x)))
  )
