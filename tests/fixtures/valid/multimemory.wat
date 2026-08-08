;; Multi-memory: two memory entries, and a data segment explicitly bound
;; to the second memory (which forces the non-zero memidx data segment
;; encoding, flags = 0x02).
(module
  (memory $a 1)
  (memory $b 1 4)

  (data (memory $b) (i32.const 0) "second memory")

  (func $loada (result i32)
    i32.const 0
    i32.load $a)

  (func $loadb (result i32)
    i32.const 0
    i32.load $b)

  (export "loada" (func $loada))
  (export "loadb" (func $loadb))
  (export "a" (memory $a))
  (export "b" (memory $b)))
