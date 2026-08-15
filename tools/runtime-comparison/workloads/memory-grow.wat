(module
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  (memory (export "memory") 1 4097)
  (func $run (result i32)
    (local $i i32)
    (local $old-pages i32)
    (local $checksum i32)
    (loop $grow
      (local.set $old-pages (memory.grow (i32.const 1)))
      (if (i32.eq (local.get $old-pages) (i32.const -1))
        (then (return (i32.const 1))))
      (if
        (i32.ne
          (local.get $old-pages)
          (i32.add (local.get $i) (i32.const 1)))
        (then (return (i32.const 1))))
      (i32.store8
        (i32.shl (local.get $old-pages) (i32.const 16))
        (local.get $i))
      (local.set $i
        (i32.add (local.get $i) (i32.const 1)))
      (br_if $grow
        (i32.lt_u (local.get $i) (i32.const 4096))))
    (local.set $i (i32.const 0))
    (loop $verify
      (local.set $checksum
        (i32.add
          (local.get $checksum)
          (i32.load8_u
            (i32.shl
              (i32.add (local.get $i) (i32.const 1))
              (i32.const 16)))))
      (local.set $i
        (i32.add (local.get $i) (i32.const 1)))
      (br_if $verify
        (i32.lt_u (local.get $i) (i32.const 4096))))
    (i32.or
      (i32.ne (memory.size) (i32.const 4097))
      (i32.ne (local.get $checksum) (i32.const 522240))))
  (func (export "_start")
    (call $proc_exit (call $run))))
