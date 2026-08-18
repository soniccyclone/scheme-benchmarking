#!r6rs
;;; FIVE raw-word arguments, recursively. RV64 passes four in t3-t6, so the
;;; fifth arrives on the stack -- which is the only way to reach
;;; frame-incoming-offset. x86-64 has six raw argument registers and never
;;; spills here, and that asymmetry is exactly why the return-address word in
;;; the frame diagram went unnoticed as an x86-only quantity.
;;;
;;; Recursive rather than straight-line so inline.ss and fold.ss cannot remove
;;; the call: a constant-folded call passes no arguments at all, which is how two
;;; earlier attempts at this test silently exercised nothing.
;;;
;;; NOT IN TAIL POSITION at the top level. A tail call from main.entry1 is
;;; refused, correctly: "a tail call needs more outgoing stack words than this
;;; function received" -- main receives none, and a tail call writes its outgoing
;;; arguments over the caller's own incoming area. Growing the stack for a tail
;;; call needs a frame shuffle this compiler does not have, and says so.
;;;
;;; Wrapping the result in arithmetic makes it an ordinary call, which sizes its
;;; outgoing area in main's own frame.
;;;
;;; Answer: e is returned once a reaches 0, so (five 3 1 2 3 4) = 4, doubled = 8.
(define (five a b c d e)
  (if (fx< a 1) e (five (fx- a 1) b c d e)))
(display (fx->fl (fx* 2 (five 3 1 2 3 4))))
(newline)
