;;; Deterministic iteration over hash tables.
;;;
;;; `hashtable-keys` returns a vector in an order Chez does not promise and
;;; which is not stable across runs. Every place that order reaches something
;;; order-sensitive is a source of nondeterminism, and this compiler had
;;; several: three compiles of one source produced three different images.
;;;
;;;     6fc6be65368f667f / 41a2c66cb84a172c / 9124963c74aa506a
;;;
;;; That is not a cosmetic problem. It invalidates the oracle -- D24 rests on
;;; bit-exact cross-agreement, and "bit-exact" is not a property a
;;; nondeterministic compiler can have. Worse, it makes debugging unsound: a
;;; latent bug appears and disappears between runs as the allocation shifts, so
;;; a test that passes proves nothing and a repro that stops reproducing looks
;;; fixed. Hours went into chasing wrong answers that moved.
;;;
;;; The two places it did the most damage:
;;;
;;;   driver.ss   the list of global cell names decides each global's ADDRESS,
;;;               so every global moved between runs
;;;   regalloc.ss live intervals are built from a table and then sorted by start
;;;               point; ties are broken by the incoming order, so two values
;;;               with the same start swapped places and got different registers
;;;
;;; Sorting by NAME rather than by hash: names are what a disassembly shows, so
;;; a deterministic order is also a readable one, and a diff between two builds
;;; stays meaningful.

(library (sonic order)
  (export sorted-keys sorted-key-list key<?)
  (import (chezscheme))

  ;; A total order over the key types this compiler puts in hash tables:
  ;; symbols (vregs, labels, procedure names) and exact integers (offsets,
  ;; block indices). Mixed tables sort integers before symbols, which is
  ;; arbitrary but stable -- and stable is the whole point.
  (define (key<? a b)
    (cond
     ((and (symbol? a) (symbol? b))
      (string<? (symbol->string a) (symbol->string b)))
     ((and (number? a) (number? b)) (< a b))
     ((number? a) #t)
     ((number? b) #f)
     (else (string<? (format "~a" a) (format "~a" b)))))

  ;; The keys of `h`, as a list, in a deterministic order.
  (define (sorted-key-list h)
    (sort key<? (vector->list (hashtable-keys h))))

  ;; The same, as a vector, for callers using `vector-for-each`.
  (define (sorted-keys h)
    (list->vector (sorted-key-list h)))
  )
