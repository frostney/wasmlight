(module
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (func $fib (param $n i32) (result i32)
    (if (result i32)
      (i32.lt_u (local.get $n) (i32.const 2))
      (then (local.get $n))
      (else
        (i32.add
          (call $fib
            (i32.sub (local.get $n) (i32.const 1)))
          (call $fib
            (i32.sub (local.get $n) (i32.const 2)))))))
  (func (export "_start")
    (call $proc_exit
      (i32.ne (call $fib (i32.const 35)) (i32.const 9227465)))))
