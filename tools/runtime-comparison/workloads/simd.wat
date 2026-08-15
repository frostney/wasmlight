(module
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (func $run (result i32)
    (local $i i32)
    (local $value v128)
    (local.set $value (v128.const i32x4 1 2 3 4))
    (loop $loop
      (local.set $value
        (v128.xor
          (i32x4.add
            (local.get $value)
            (v128.const i32x4 1 3 5 7))
          (i32x4.splat (local.get $i))))
      (local.set $i
        (i32.add (local.get $i) (i32.const 1)))
      (br_if $loop
        (i32.lt_u (local.get $i) (i32.const 1000000))))
    (i32.or
      (i32.or
        (i32.ne
          (i32x4.extract_lane 0 (local.get $value))
          (i32.const 1))
        (i32.ne
          (i32x4.extract_lane 1 (local.get $value))
          (i32.const 2262146)))
      (i32.or
        (i32.ne
          (i32x4.extract_lane 2 (local.get $value))
          (i32.const 4000003))
        (i32.ne
          (i32x4.extract_lane 3 (local.get $value))
          (i32.const 22419972)))))
  (func (export "_start")
    (call $proc_exit (call $run))))
