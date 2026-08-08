;; THE ORDERING FIXTURE.
;;
;; A passive data segment plus memory.init/data.drop forces the data count
;; section (id 12) to be emitted, and the binary grammar places it BEFORE
;; the code section (id 10). A decoder that enforces "section ids must
;; strictly increase" rejects this valid module.
(module
  (memory 1)

  (data $passive "passive payload")
  (data $active (i32.const 0) "active payload")

  (func $load
    i32.const 0     ;; destination in memory
    i32.const 0     ;; offset into the passive segment
    i32.const 15    ;; length
    memory.init $passive
    data.drop $passive)

  (func $fill
    i32.const 32    ;; destination
    i32.const 0     ;; byte value
    i32.const 16    ;; length
    memory.fill)

  (export "load" (func $load))
  (export "fill" (func $fill)))
