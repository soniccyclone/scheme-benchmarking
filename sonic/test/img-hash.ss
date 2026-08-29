;;; Image equality, D182's technique: a refactor that must not change the
;;; emitted code is checked by hashing what it emits, not by reading it.
(import (chezscheme) (sonic driver) (sonic pipeline))
(compile-sonic-to-file "../bench/nbody/config-sonic.sps" nbody-externs "/tmp/nb.bin")
(compile-sonic-to-file "../bench/fannkuch/config-sonic.sps" '(display newline) "/tmp/fk.bin")
