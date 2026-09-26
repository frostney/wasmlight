;; Exception payloads that carry v128 values: throw, throw_ref, every
;; try_table clause kind, nested handlers, throws from callees, and a
;; payload held across forced collections. Hand-written: every expected
;; lane is spelled out below, derived from the operands in this file, never
;; from a wasmlight tier. Wasm.Wast.Runner.Test runs it in the interpreter,
;; JIT, and AOT tiers.
(module
  (type $box (struct (field i32)))
  (type $node (struct (field v128) (field (ref null $node))))

  ;; A v128-only tag.
  (tag $tv (param v128))
  ;; Mixed: a vector between scalars, and a reference after it.
  (tag $tm (param i32 v128 (ref null $box) i64))
  ;; Several vectors, not adjacent to each other everywhere.
  (tag $t3 (param v128 v128 i32 v128))
  ;; A reference between two vectors: its slot moves once vectors take 16
  ;; bytes, and the collector must still trace it.
  (tag $tr (param v128 (ref null $box) v128))
  ;; An unrelated tag for the nested-handler case.
  (tag $other (param i32))

  (global $held (mut exnref) (ref.null exn))

  ;; --- throw -> catch --------------------------------------------------
  (func (export "only") (result v128)
    (block $h (result v128)
      (try_table (catch $tv $h)
        (throw $tv (v128.const i32x4 1 2 3 4)))
      (unreachable)))

  (func (export "only_param") (param v128) (result v128)
    (block $h (result v128)
      (try_table (catch $tv $h)
        (throw $tv (local.get 0)))
      (unreachable)))

  (func (export "mixed") (result i32 v128 i32 i64)
    (local $i i32) (local $v v128) (local $b (ref null $box)) (local $l i64)
    (block $h (result i32 v128 (ref null $box) i64)
      (try_table (catch $tm $h)
        (throw $tm
          (i32.const 7)
          (v128.const i64x2 0x0102030405060708 0x1112131415161718)
          (struct.new $box (i32.const 42))
          (i64.const -9)))
      (unreachable))
    (local.set $l) (local.set $b) (local.set $v) (local.set $i)
    (local.get $i)
    (local.get $v)
    (struct.get $box 0 (local.get $b))
    (local.get $l))

  (func (export "three") (result v128 v128 i32 v128)
    (block $h (result v128 v128 i32 v128)
      (try_table (catch $t3 $h)
        (throw $t3
          (v128.const i32x4 10 11 12 13)
          (v128.const i32x4 20 21 22 23)
          (i32.const -1)
          (v128.const i32x4 30 31 32 33)))
      (unreachable)))

  ;; --- catch_ref + throw_ref, catch_all_ref ------------------------------
  (func (export "rethrow") (result v128 v128 i32 v128)
    (block $outer (result v128 v128 i32 v128)
      (try_table (catch $t3 $outer)
        (block $inner (result v128 v128 i32 v128 exnref)
          (try_table (catch_ref $t3 $inner)
            (throw $t3
              (v128.const i32x4 40 41 42 43)
              (v128.const i32x4 50 51 52 53)
              (i32.const 60)
              (v128.const i32x4 70 71 72 73)))
          (unreachable))
        ;; Drop the delivered payload; rethrow the exnref it came with.
        (throw_ref
          (block $keep (param v128 v128 i32 v128 exnref) (result exnref)
            (br $keep))))
      (unreachable)))

  (func (export "catch_ref_payload") (result v128 i32)
    (local $e exnref)
    (block $h (result v128 exnref)
      (try_table (catch_ref $tv $h)
        (throw $tv (v128.const i32x4 -1 -2 -3 -4)))
      (unreachable))
    (local.set $e)
    (ref.is_null (local.get $e)))

  (func (export "catch_all_ref") (result v128)
    (block $outer (result v128)
      (try_table (catch $tv $outer)
        (throw_ref
          (block $h (result exnref)
            (try_table (catch_all_ref $h)
              (throw $tv (v128.const i32x4 0x7fffffff 0x80000000 0 -1)))
            (unreachable))))
      (unreachable)))

  ;; --- nested handlers -------------------------------------------------
  (func (export "nested") (result i32 v128 i64)
    (local $l i64)
    (block $outer (result i32 v128 (ref null $box) i64)
      (try_table (catch $tm $outer)
        (block $inner (result i32)
          (try_table (catch $other $inner)
            (throw $tm
              (i32.const 1)
              (v128.const i32x4 5 6 7 8)
              (ref.null $box)
              (i64.const 2)))
          (unreachable))
        (drop)
        (unreachable))
      (unreachable))
    (local.set $l)
    (drop)
    (local.get $l))

  ;; --- throw from a callee through direct-call frames ---------------------
  (func $thrower (param v128)
    (throw $tv (local.get 0)))
  (func $middle (param v128) (param i32)
    (call $thrower
      (i32x4.add (local.get 0) (i32x4.splat (local.get 1)))))
  (func (export "through_calls") (result v128)
    (block $h (result v128)
      (try_table (catch $tv $h)
        (call $middle (v128.const i32x4 100 200 300 400) (i32.const 5)))
      (unreachable)))

  ;; --- a payload held across collections --------------------------------
  (func (export "hold")
    (global.set $held
      (block $h (result exnref)
        (try_table (catch_all_ref $h)
          (throw $tr
            (v128.const i64x2 0x0000000000001000 0x0000000000002000)
            (struct.new $box (i32.const 1234))
            (v128.const i32x4 9 8 7 6)))
        (unreachable))))

  (func (export "churn") (param $n i32) (local $i i32)
    (loop $l
      (drop (struct.new $node (i32x4.splat (local.get $i)) (ref.null $node)))
      (drop (struct.new $box (local.get $i)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n)))))

  (func (export "release") (result v128 i32 v128)
    (local $b (ref null $box))
    (local $v v128)
    (block $h (result v128 (ref null $box) v128)
      (try_table (catch $tr $h)
        (throw_ref (global.get $held)))
      (unreachable))
    (local.set $v)
    (local.set $b)
    (struct.get $box 0 (local.get $b))
    (local.get $v))

  ;; --- uncaught --------------------------------------------------------
  (func (export "uncaught")
    (throw $t3
      (v128.const i32x4 1 1 1 1)
      (v128.const i32x4 2 2 2 2)
      (i32.const 3)
      (v128.const i32x4 4 4 4 4)))
)

(assert_return (invoke "only") (v128.const i32x4 1 2 3 4))
(assert_return (invoke "only_param" (v128.const i32x4 -5 6 -7 8))
  (v128.const i32x4 -5 6 -7 8))
(assert_return (invoke "mixed")
  (i32.const 7)
  (v128.const i64x2 0x0102030405060708 0x1112131415161718)
  (i32.const 42)
  (i64.const -9))
(assert_return (invoke "three")
  (v128.const i32x4 10 11 12 13)
  (v128.const i32x4 20 21 22 23)
  (i32.const -1)
  (v128.const i32x4 30 31 32 33))
(assert_return (invoke "rethrow")
  (v128.const i32x4 40 41 42 43)
  (v128.const i32x4 50 51 52 53)
  (i32.const 60)
  (v128.const i32x4 70 71 72 73))
(assert_return (invoke "catch_ref_payload")
  (v128.const i32x4 -1 -2 -3 -4) (i32.const 0))
(assert_return (invoke "catch_all_ref")
  (v128.const i32x4 0x7fffffff 0x80000000 0 -1))
(assert_return (invoke "nested")
  (i32.const 1) (v128.const i32x4 5 6 7 8) (i64.const 2))
;; 100 200 300 400 + splat 5.
(assert_return (invoke "through_calls") (v128.const i32x4 105 205 305 405))
(invoke "hold")
(invoke "churn" (i32.const 60000))
(assert_return (invoke "release")
  (v128.const i64x2 0x0000000000001000 0x0000000000002000)
  (i32.const 1234)
  (v128.const i32x4 9 8 7 6))
(assert_exception (invoke "uncaught"))
