(module
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (func $run (result i32)
    (local $i i32)
    (local $acc i32)
    (loop $loop
      (local.set $acc
        (i32.add (local.get $acc) (local.get $i)))
      (local.set $i
        (i32.add (local.get $i) (i32.const 1)))
      (br_if $loop
        (i32.lt_u (local.get $i) (i32.const 2000))))
    (local.get $acc))
  (func (export "_start")
    (call $proc_exit
      (i32.ne (call $run) (i32.const 1999000)))))
