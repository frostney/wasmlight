(module
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  (import "wasi_snapshot_preview1" "clock_time_get"
    (func $clock_time_get (param i32 i64 i32) (result i32)))
  (memory (export "memory") 1)
  (func $run (result i32)
    (local $i i32)
    (local $failed i32)
    (local $previous i64)
    (local $current i64)
    (loop $loop
      (local.set $failed
        (i32.or
          (local.get $failed)
          (call $clock_time_get
            (i32.const 1)
            (i64.const 0)
            (i32.const 0))))
      (local.set $current (i64.load (i32.const 0)))
      (local.set $failed
        (i32.or
          (local.get $failed)
          (i64.lt_u (local.get $current) (local.get $previous))))
      (local.set $previous (local.get $current))
      (local.set $i
        (i32.add (local.get $i) (i32.const 1)))
      (br_if $loop
        (i32.lt_u (local.get $i) (i32.const 1000000))))
    (local.get $failed))
  (func (export "_start")
    (call $proc_exit (call $run))))
