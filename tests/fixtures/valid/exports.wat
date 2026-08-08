;; Plain module: type, function, table, memory, global, export sections.
;; Covers the common ascending-id section run with no ordering surprises.
(module
  (type $binop (func (param i32 i32) (result i32)))

  (func $add (type $binop)
    local.get 0
    local.get 1
    i32.add)

  (func $sub (type $binop)
    local.get 0
    local.get 1
    i32.sub)

  (table $tbl 2 funcref)
  (memory $mem 1 2)

  (global $counter (mut i32) (i32.const 0))
  (global $limit i32 (i32.const 100))

  (export "add" (func $add))
  (export "sub" (func $sub))
  (export "counter" (global $counter))
  (export "limit" (global $limit))
  (export "mem" (memory $mem))
  (export "tbl" (table $tbl)))
