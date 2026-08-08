;; SIMD: v128 value type in signatures, v128.const, lane ops and a
;; v128 memory access. Exercises the 0xFD prefixed opcode space and the
;; -5 (0x7B) value type code in the type section.
(module
  (memory 1)

  (func $splat (param i32) (result v128)
    local.get 0
    i32x4.splat)

  (func $add (param v128 v128) (result v128)
    local.get 0
    local.get 1
    i32x4.add)

  (func $konst (result v128)
    v128.const i32x4 1 2 3 4)

  (func $loadstore
    i32.const 0
    i32.const 16
    v128.load
    v128.store)

  (func $extract (param v128) (result i32)
    local.get 0
    i32x4.extract_lane 2)

  (export "splat" (func $splat))
  (export "add" (func $add))
  (export "konst" (func $konst))
  (export "extract" (func $extract)))
