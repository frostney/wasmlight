;; Several custom sections (id 0) at different points in the section
;; sequence, plus a `name` section emitted by the assembler from the
;; symbolic names below (wat2wasm --debug-names).
;;
;; Custom sections may appear anywhere and any number of times, so they
;; must not participate in the section ordering check.
(module
  (@custom "wasmlight.first" (before type) "leading custom payload")
  (@custom "wasmlight.middle" (after memory) "middle custom payload")

  (type $unop (func (param i32) (result i32)))

  (memory $mem 1)

  (func $double (type $unop)
    (local $tmp i32)
    local.get 0
    local.set $tmp
    local.get $tmp
    local.get $tmp
    i32.add)

  (export "double" (func $double))

  (@custom "wasmlight.last" (after code) "trailing custom payload"))
