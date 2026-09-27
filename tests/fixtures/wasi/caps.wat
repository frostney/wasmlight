;; A WASI command that reports its capabilities through its exit code:
;; argc + 10 * envc, plus 100 when path_open on fd 3 opens "probe.txt".
(module
  (import "wasi_snapshot_preview1" "args_sizes_get"
    (func $args_sizes_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "environ_sizes_get"
    (func $environ_sizes_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open
      (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (data (i32.const 64) "probe.txt")
  (func (export "_start")
    (local $code i32)
    (drop (call $args_sizes_get (i32.const 0) (i32.const 4)))
    (drop (call $environ_sizes_get (i32.const 8) (i32.const 12)))
    (local.set $code
      (i32.add
        (i32.load (i32.const 0))
        (i32.mul (i32.load (i32.const 8)) (i32.const 10))))
    (if (i32.eqz (call $path_open
          (i32.const 3) (i32.const 0) (i32.const 64) (i32.const 9)
          (i32.const 0) (i64.const 2) (i64.const 0) (i32.const 0)
          (i32.const 16)))
      (then (local.set $code (i32.add (local.get $code) (i32.const 100)))))
    (call $proc_exit (local.get $code))))
