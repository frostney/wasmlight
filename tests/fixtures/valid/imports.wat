;; Import section carrying all four import kinds (func, table, memory,
;; global), so the import section body is non-trivial and the function
;; index space starts above zero.
(module
  (import "env" "log"  (func $log (param i32)))
  (import "env" "tbl"  (table 1 funcref))
  (import "env" "mem"  (memory 1))
  (import "env" "base" (global $base i32))

  (func $use (result i32)
    i32.const 42
    call $log
    global.get $base)

  (export "use" (func $use)))
