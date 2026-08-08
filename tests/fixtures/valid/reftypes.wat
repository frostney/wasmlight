;; Reference types: funcref and externref tables, table.get/table.set,
;; ref.null, ref.is_null, ref.func and a declarative element segment.
(module
  (table $funcs 4 funcref)
  (table $exts  2 externref)

  (func $getf (param i32) (result funcref)
    local.get 0
    table.get $funcs)

  (func $sete (param i32 externref)
    local.get 0
    local.get 1
    table.set $exts)

  (func $nullext (result externref)
    ref.null extern)

  (func $isnull (param externref) (result i32)
    local.get 0
    ref.is_null)

  (func $mkref (result funcref)
    ref.func $getf)

  (elem declare func $getf)

  (export "getf" (func $getf))
  (export "sete" (func $sete))
  (export "isnull" (func $isnull))
  (export "mkref" (func $mkref)))
