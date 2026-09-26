;; v128 struct fields and array elements, in every allocation and access
;; form, and across forced collections. Hand-written: every expected lane is
;; spelled out below, derived from the operands in this file, never from a
;; wasmlight tier. Wasm.Wast.Runner.Test runs it in the interpreter, JIT,
;; and AOT tiers.
(module
  ;; The only field.
  (type $only (struct (field (mut v128))))
  ;; First field, then a scalar. Header is 8 bytes, so the v128 aligns to 16.
  (type $first (struct (field (mut v128)) (field (mut i32))))
  ;; Middle field, between two scalars.
  (type $mid (struct (field i64) (field (mut v128)) (field f32)))
  ;; After two packed fields, before a third.
  (type $packed (struct (field i8) (field i16) (field (mut v128))
    (field (mut i8))))
  ;; Two adjacent vectors.
  (type $pair (struct (field v128) (field v128)))
  ;; Ten fields (four v128): past the eight-field batch the interpreter and
  ;; the Arm64 helper use for struct.new.
  (type $big (struct
    (field v128) (field i32) (field v128) (field i64) (field i8)
    (field v128) (field f64) (field i32) (field v128) (field i32)))
  ;; A vector beside a traced reference: a linked list for the GC checks.
  (type $node (struct (field v128) (field (ref null $node))))
  (type $av (array (mut v128)))

  ;; Bytes 0x00 .. 0x2f.
  (data $d "\00\01\02\03\04\05\06\07\08\09\0a\0b\0c\0d\0e\0f"
           "\10\11\12\13\14\15\16\17\18\19\1a\1b\1c\1d\1e\1f"
           "\20\21\22\23\24\25\26\27\28\29\2a\2b\2c\2d\2e\2f")

  ;; --- constant expressions ---------------------------------------------
  (global $gs (ref $first)
    (struct.new $first (v128.const i32x4 101 102 103 104) (i32.const 105)))
  (global $ga (ref $av)
    (array.new $av (v128.const i32x4 201 202 203 204) (i32.const 2)))
  (global $gf (ref $av)
    (array.new_fixed $av 2 (v128.const i32x4 301 302 303 304)
      (v128.const i32x4 401 402 403 404)))

  (global $list (mut (ref null $node)) (ref.null $node))
  (global $keep (mut (ref null $av)) (ref.null $av))
  (global $keepbig (mut (ref null $big)) (ref.null $big))

  ;; --- struct.new / struct.get ------------------------------------------
  (func (export "only") (result v128)
    (struct.get $only 0 (struct.new $only
      (v128.const i32x4 0x11111111 0x22222222 0x33333333 0x44444444))))

  (func (export "only_param") (param v128) (result v128)
    (struct.get $only 0 (struct.new $only (local.get 0))))

  (func (export "first") (result v128 i32) (local $s (ref null $first))
    (local.set $s (struct.new $first (v128.const i32x4 1 2 3 4) (i32.const 5)))
    (struct.get $first 0 (local.get $s))
    (struct.get $first 1 (local.get $s)))

  (func (export "mid") (result i64 v128 f32) (local $s (ref null $mid))
    (local.set $s (struct.new $mid
      (i64.const 0x0102030405060708)
      (v128.const i64x2 -1 0x7fffffffffffffff)
      (f32.const 1.5)))
    (struct.get $mid 0 (local.get $s))
    (struct.get $mid 1 (local.get $s))
    (struct.get $mid 2 (local.get $s)))

  (func (export "packed") (result i32 i32 v128 i32)
    (local $s (ref null $packed))
    (local.set $s (struct.new $packed
      (i32.const 0x1ff)
      (i32.const 0x1fffe)
      (v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)
      (i32.const 0x180)))
    (struct.get_u $packed 0 (local.get $s))
    (struct.get_s $packed 1 (local.get $s))
    (struct.get $packed 2 (local.get $s))
    (struct.get_s $packed 3 (local.get $s)))

  (func (export "pair") (result v128 v128) (local $s (ref null $pair))
    (local.set $s (struct.new $pair
      (v128.const i32x4 10 20 30 40) (v128.const i32x4 50 60 70 80)))
    (struct.get $pair 0 (local.get $s))
    (struct.get $pair 1 (local.get $s)))

  (func $mkbig (result (ref $big))
    (struct.new $big
      (v128.const i32x4 1001 1002 1003 1004)
      (i32.const 11)
      (v128.const i32x4 2001 2002 2003 2004)
      (i64.const 0x1122334455667788)
      (i32.const 0xfe)
      (v128.const i32x4 3001 3002 3003 3004)
      (f64.const -2.25)
      (i32.const 77)
      (v128.const i32x4 4001 4002 4003 4004)
      (i32.const 99)))

  (func (export "big_vecs") (result v128 v128 v128 v128)
    (local $s (ref null $big))
    (local.set $s (call $mkbig))
    (struct.get $big 0 (local.get $s))
    (struct.get $big 2 (local.get $s))
    (struct.get $big 5 (local.get $s))
    (struct.get $big 8 (local.get $s)))

  (func (export "big_scalars") (result i32 i64 i32 f64 i32 i32)
    (local $s (ref null $big))
    (local.set $s (call $mkbig))
    (struct.get $big 1 (local.get $s))
    (struct.get $big 3 (local.get $s))
    (struct.get_s $big 4 (local.get $s))
    (struct.get $big 6 (local.get $s))
    (struct.get $big 7 (local.get $s))
    (struct.get $big 9 (local.get $s)))

  ;; --- struct.set / struct.new_default ----------------------------------
  (func (export "first_set") (result v128 i32) (local $s (ref null $first))
    (local.set $s (struct.new $first (v128.const i32x4 1 2 3 4) (i32.const 5)))
    (struct.set $first 0 (local.get $s) (v128.const i32x4 -1 -2 -3 -4))
    (struct.get $first 0 (local.get $s))
    (struct.get $first 1 (local.get $s)))

  (func (export "packed_set") (result i32 v128 i32)
    (local $s (ref null $packed))
    (local.set $s (struct.new $packed (i32.const 1) (i32.const 2)
      (v128.const i32x4 0 0 0 0) (i32.const 3)))
    (struct.set $packed 2 (local.get $s)
      (v128.const i32x4 0xdeadbeef 0xcafebabe 0x01234567 0x89abcdef))
    (struct.set $packed 3 (local.get $s) (i32.const 0x7f))
    (struct.get_u $packed 1 (local.get $s))
    (struct.get $packed 2 (local.get $s))
    (struct.get_u $packed 3 (local.get $s)))

  (func (export "mid_default") (result i64 v128 f32)
    (local $s (ref null $mid))
    (local.set $s (struct.new_default $mid))
    (struct.get $mid 0 (local.get $s))
    (struct.get $mid 1 (local.get $s))
    (struct.get $mid 2 (local.get $s)))

  ;; --- arrays -----------------------------------------------------------
  (func (export "arr_new") (param $i i32) (result v128 i32)
    (local $a (ref null $av))
    (local.set $a (array.new $av (v128.const i32x4 7 8 9 10) (i32.const 3)))
    (array.get $av (local.get $a) (local.get $i))
    (array.len (local.get $a)))

  (func (export "arr_new_fixed") (param $i i32) (result v128)
    (array.get $av
      (array.new_fixed $av 3
        (v128.const i32x4 1 1 1 1)
        (v128.const i32x4 2 3 4 5)
        (v128.const i32x4 6 7 8 9))
      (local.get $i)))

  (func (export "arr_new_default") (param $i i32) (result v128)
    (array.get $av (array.new_default $av (i32.const 4)) (local.get $i)))

  (func (export "arr_set") (result v128 v128 v128)
    (local $a (ref null $av))
    (local.set $a (array.new_default $av (i32.const 3)))
    (array.set $av (local.get $a) (i32.const 1)
      (v128.const i32x4 0x10 0x20 0x30 0x40))
    (array.get $av (local.get $a) (i32.const 0))
    (array.get $av (local.get $a) (i32.const 1))
    (array.get $av (local.get $a) (i32.const 2)))

  (func (export "arr_fill") (result v128 v128 v128 v128 v128)
    (local $a (ref null $av))
    (local.set $a (array.new $av (v128.const i32x4 1 2 3 4) (i32.const 5)))
    (array.fill $av (local.get $a) (i32.const 1)
      (v128.const i32x4 5 6 7 8) (i32.const 3))
    (array.get $av (local.get $a) (i32.const 0))
    (array.get $av (local.get $a) (i32.const 1))
    (array.get $av (local.get $a) (i32.const 2))
    (array.get $av (local.get $a) (i32.const 3))
    (array.get $av (local.get $a) (i32.const 4)))

  (func $five (result (ref $av))
    (array.new_fixed $av 5
      (v128.const i32x4 100 101 102 103)
      (v128.const i32x4 110 111 112 113)
      (v128.const i32x4 120 121 122 123)
      (v128.const i32x4 130 131 132 133)
      (v128.const i32x4 140 141 142 143)))

  (func $all5 (param $a (ref $av)) (result v128 v128 v128 v128 v128)
    (array.get $av (local.get $a) (i32.const 0))
    (array.get $av (local.get $a) (i32.const 1))
    (array.get $av (local.get $a) (i32.const 2))
    (array.get $av (local.get $a) (i32.const 3))
    (array.get $av (local.get $a) (i32.const 4)))

  (func (export "arr_copy") (result v128 v128 v128 v128 v128)
    (local $d (ref $av))
    (local.set $d (array.new_default $av (i32.const 5)))
    (array.copy $av $av (local.get $d) (i32.const 1)
      (call $five) (i32.const 2) (i32.const 3))
    (call $all5 (local.get $d)))

  ;; Destination above source in one array: memmove must copy backward.
  (func (export "arr_copy_up") (result v128 v128 v128 v128 v128)
    (local $a (ref $av))
    (local.set $a (call $five))
    (array.copy $av $av (local.get $a) (i32.const 1)
      (local.get $a) (i32.const 0) (i32.const 4))
    (call $all5 (local.get $a)))

  ;; Destination below source in one array.
  (func (export "arr_copy_down") (result v128 v128 v128 v128 v128)
    (local $a (ref $av))
    (local.set $a (call $five))
    (array.copy $av $av (local.get $a) (i32.const 0)
      (local.get $a) (i32.const 1) (i32.const 4))
    (call $all5 (local.get $a)))

  (func (export "arr_new_data") (param $i i32) (result v128)
    (array.get $av
      (array.new_data $av $d (i32.const 8) (i32.const 2))
      (local.get $i)))

  (func (export "arr_init_data") (result v128 v128 v128)
    (local $a (ref null $av))
    (local.set $a (array.new $av (v128.const i32x4 -1 -1 -1 -1) (i32.const 3)))
    (array.init_data $av $d (local.get $a) (i32.const 1) (i32.const 0)
      (i32.const 2))
    (array.get $av (local.get $a) (i32.const 0))
    (array.get $av (local.get $a) (i32.const 1))
    (array.get $av (local.get $a) (i32.const 2)))

  ;; --- constant-expression objects ---------------------------------------
  (func (export "g_struct") (result v128 i32)
    (struct.get $first 0 (global.get $gs))
    (struct.get $first 1 (global.get $gs)))

  (func (export "g_arr_new") (param $i i32) (result v128)
    (array.get $av (global.get $ga) (local.get $i)))

  (func (export "g_arr_fixed") (param $i i32) (result v128)
    (array.get $av (global.get $gf) (local.get $i)))

  ;; --- surviving collections --------------------------------------------
  ;; Node i (0..7) holds (i+1) * (1 2 3 4); the head is node 7.
  (func (export "build") (local $i i32)
    (loop $l
      (global.set $list (struct.new $node
        (i32x4.mul
          (i32x4.splat (i32.add (local.get $i) (i32.const 1)))
          (v128.const i32x4 1 2 3 4))
        (global.get $list)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (i32.const 8))))
    (global.set $keep (array.new_fixed $av 3
      (v128.const i32x4 -7 -8 -9 -10)
      (v128.const i64x2 0x0123456789abcdef 0x7edcba9876543210)
      (v128.const i32x4 1 0 -1 0x80000000)))
    (global.set $keepbig (call $mkbig)))

  ;; 60000 rounds of a 48-byte node and a 96-byte array: about 8.6 MB of
  ;; garbage against the 1 MiB default threshold, so several collections.
  (func (export "churn") (param $n i32) (local $i i32)
    (loop $l
      (drop (struct.new $node (i32x4.splat (local.get $i)) (ref.null $node)))
      (drop (array.new $av (i32x4.splat (local.get $i)) (i32.const 4)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n)))))

  (func (export "list_at") (param $depth i32) (result v128)
    (local $n (ref null $node))
    (local.set $n (global.get $list))
    (block $done
      (loop $l
        (br_if $done (i32.eqz (local.get $depth)))
        (local.set $n (struct.get $node 1 (local.get $n)))
        (local.set $depth (i32.sub (local.get $depth) (i32.const 1)))
        (br $l)))
    (struct.get $node 0 (local.get $n)))

  (func (export "keep_at") (param $i i32) (result v128)
    (array.get $av (global.get $keep) (local.get $i)))

  (func (export "keepbig") (result v128 i32 v128 v128)
    (struct.get $big 0 (global.get $keepbig))
    (struct.get $big 9 (global.get $keepbig))
    (struct.get $big 5 (global.get $keepbig))
    (struct.get $big 8 (global.get $keepbig)))
)

;; struct.new, each field position.
(assert_return (invoke "only")
  (v128.const i32x4 0x11111111 0x22222222 0x33333333 0x44444444))
(assert_return (invoke "only_param" (v128.const i32x4 -5 6 -7 8))
  (v128.const i32x4 -5 6 -7 8))
(assert_return (invoke "first") (v128.const i32x4 1 2 3 4) (i32.const 5))
(assert_return (invoke "mid")
  (i64.const 0x0102030405060708)
  (v128.const i64x2 -1 0x7fffffffffffffff)
  (f32.const 1.5))
;; 0x1ff packs to 0xff; 0x1fffe to 0xfffe, sign-extended -2; 0x180 to
;; 0x80, sign-extended -128.
(assert_return (invoke "packed")
  (i32.const 255) (i32.const -2)
  (v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)
  (i32.const -128))
(assert_return (invoke "pair")
  (v128.const i32x4 10 20 30 40) (v128.const i32x4 50 60 70 80))
(assert_return (invoke "big_vecs")
  (v128.const i32x4 1001 1002 1003 1004)
  (v128.const i32x4 2001 2002 2003 2004)
  (v128.const i32x4 3001 3002 3003 3004)
  (v128.const i32x4 4001 4002 4003 4004))
;; 0xfe in an i8 field, sign-extended: -2.
(assert_return (invoke "big_scalars")
  (i32.const 11) (i64.const 0x1122334455667788) (i32.const -2)
  (f64.const -2.25) (i32.const 77) (i32.const 99))

;; struct.set and struct.new_default.
(assert_return (invoke "first_set")
  (v128.const i32x4 -1 -2 -3 -4) (i32.const 5))
(assert_return (invoke "packed_set")
  (i32.const 2)
  (v128.const i32x4 0xdeadbeef 0xcafebabe 0x01234567 0x89abcdef)
  (i32.const 127))
(assert_return (invoke "mid_default")
  (i64.const 0) (v128.const i32x4 0 0 0 0) (f32.const 0))

;; Arrays.
(assert_return (invoke "arr_new" (i32.const 0))
  (v128.const i32x4 7 8 9 10) (i32.const 3))
(assert_return (invoke "arr_new" (i32.const 2))
  (v128.const i32x4 7 8 9 10) (i32.const 3))
(assert_return (invoke "arr_new_fixed" (i32.const 0)) (v128.const i32x4 1 1 1 1))
(assert_return (invoke "arr_new_fixed" (i32.const 1)) (v128.const i32x4 2 3 4 5))
(assert_return (invoke "arr_new_fixed" (i32.const 2)) (v128.const i32x4 6 7 8 9))
(assert_trap (invoke "arr_new_fixed" (i32.const 3)) "out of bounds array access")
(assert_return (invoke "arr_new_default" (i32.const 0)) (v128.const i32x4 0 0 0 0))
(assert_return (invoke "arr_new_default" (i32.const 3)) (v128.const i32x4 0 0 0 0))
(assert_return (invoke "arr_set")
  (v128.const i32x4 0 0 0 0)
  (v128.const i32x4 0x10 0x20 0x30 0x40)
  (v128.const i32x4 0 0 0 0))
(assert_return (invoke "arr_fill")
  (v128.const i32x4 1 2 3 4)
  (v128.const i32x4 5 6 7 8)
  (v128.const i32x4 5 6 7 8)
  (v128.const i32x4 5 6 7 8)
  (v128.const i32x4 1 2 3 4))
;; dst[1..3] <- five[2..4].
(assert_return (invoke "arr_copy")
  (v128.const i32x4 0 0 0 0)
  (v128.const i32x4 120 121 122 123)
  (v128.const i32x4 130 131 132 133)
  (v128.const i32x4 140 141 142 143)
  (v128.const i32x4 0 0 0 0))
;; a[1..4] <- a[0..3].
(assert_return (invoke "arr_copy_up")
  (v128.const i32x4 100 101 102 103)
  (v128.const i32x4 100 101 102 103)
  (v128.const i32x4 110 111 112 113)
  (v128.const i32x4 120 121 122 123)
  (v128.const i32x4 130 131 132 133))
;; a[0..3] <- a[1..4].
(assert_return (invoke "arr_copy_down")
  (v128.const i32x4 110 111 112 113)
  (v128.const i32x4 120 121 122 123)
  (v128.const i32x4 130 131 132 133)
  (v128.const i32x4 140 141 142 143)
  (v128.const i32x4 140 141 142 143))
;; Element 0 is data bytes 8..23, element 1 bytes 24..39.
(assert_return (invoke "arr_new_data" (i32.const 0))
  (v128.const i8x16 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23))
(assert_return (invoke "arr_new_data" (i32.const 1))
  (v128.const i8x16 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39))
(assert_return (invoke "arr_init_data")
  (v128.const i32x4 -1 -1 -1 -1)
  (v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)
  (v128.const i8x16 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31))

;; Objects built by constant expressions.
(assert_return (invoke "g_struct")
  (v128.const i32x4 101 102 103 104) (i32.const 105))
(assert_return (invoke "g_arr_new" (i32.const 0))
  (v128.const i32x4 201 202 203 204))
(assert_return (invoke "g_arr_new" (i32.const 1))
  (v128.const i32x4 201 202 203 204))
(assert_return (invoke "g_arr_fixed" (i32.const 0))
  (v128.const i32x4 301 302 303 304))
(assert_return (invoke "g_arr_fixed" (i32.const 1))
  (v128.const i32x4 401 402 403 404))

;; Values survive forced collections.
(invoke "build")
(invoke "churn" (i32.const 60000))
(assert_return (invoke "list_at" (i32.const 0)) (v128.const i32x4 8 16 24 32))
(assert_return (invoke "list_at" (i32.const 3)) (v128.const i32x4 5 10 15 20))
(assert_return (invoke "list_at" (i32.const 7)) (v128.const i32x4 1 2 3 4))
(assert_return (invoke "keep_at" (i32.const 0)) (v128.const i32x4 -7 -8 -9 -10))
(assert_return (invoke "keep_at" (i32.const 1))
  (v128.const i64x2 0x0123456789abcdef 0x7edcba9876543210))
(assert_return (invoke "keep_at" (i32.const 2))
  (v128.const i32x4 1 0 -1 0x80000000))
(assert_return (invoke "keepbig")
  (v128.const i32x4 1001 1002 1003 1004)
  (i32.const 99)
  (v128.const i32x4 3001 3002 3003 3004)
  (v128.const i32x4 4001 4002 4003 4004))
(invoke "churn" (i32.const 60000))
(assert_return (invoke "list_at" (i32.const 1)) (v128.const i32x4 7 14 21 28))
(assert_return (invoke "keep_at" (i32.const 2))
  (v128.const i32x4 1 0 -1 0x80000000))
