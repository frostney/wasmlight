(module
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (func $run (export "run") (param $n i32) (result i32)
    (local $i i32)
    (local $acc i32)
    (local.set $acc (i32.const 123456789))
    (loop $loop
      (local.set $acc
        (i32.add
          (i32.mul
            (i32.xor (local.get $acc) (local.get $i))
            (i32.const 1664525))
          (i32.const 1013904223)))
      (local.set $i
        (i32.add (local.get $i) (i32.const 1)))
      (br_if $loop
        (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $acc))
  (func (export "_start")
    (call $proc_exit
      (i32.ne
        (call $run (i32.const 300000000))
        (i32.const 1124589333)))))
