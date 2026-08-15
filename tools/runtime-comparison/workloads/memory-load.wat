(module
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (func $run (result i32)
    (local $i i32)
    (local $acc i32)
    (local $address i32)
    (loop $initialize
      (local.set $address
        (i32.shl (local.get $i) (i32.const 2)))
      (i32.store
        (local.get $address)
        (i32.xor
          (i32.mul (local.get $i) (i32.const 17))
          (i32.const -1640531527)))
      (local.set $i
        (i32.add (local.get $i) (i32.const 1)))
      (br_if $initialize
        (i32.lt_u (local.get $i) (i32.const 16384))))
    (local.set $i (i32.const 0))
    (loop $load
      (local.set $address
        (i32.shl
          (i32.and (local.get $i) (i32.const 16383))
          (i32.const 2)))
      (local.set $acc
        (i32.add
          (local.get $acc)
          (i32.load (local.get $address))))
      (local.set $i
        (i32.add (local.get $i) (i32.const 1)))
      (br_if $load
        (i32.lt_u (local.get $i) (i32.const 100000000))))
    (local.get $acc))
  (func (export "_start")
    (call $proc_exit
      (i32.ne (call $run) (i32.const 1408972672)))))
