(module
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (type $box (struct (field i32)))
  (type $roots (array (mut (ref null $box))))
  (func $run (result i32)
    (local $i i32)
    (local $acc i32)
    (local $roots (ref $roots))
    (local $box (ref $box))
    (local.set $roots
      (array.new_default $roots (i32.const 1024)))
    (loop $loop
      (local.set $box
        (struct.new $box (local.get $i)))
      (array.set $roots
        (local.get $roots)
        (i32.and (local.get $i) (i32.const 1023))
        (local.get $box))
      (local.set $acc
        (i32.add
          (local.get $acc)
          (struct.get $box 0 (local.get $box))))
      (local.set $i
        (i32.add (local.get $i) (i32.const 1)))
      (br_if $loop
        (i32.lt_u (local.get $i) (i32.const 2000000))))
    (local.get $acc))
  (func (export "_start")
    (call $proc_exit
      (i32.ne (call $run) (i32.const -1455759936)))))
