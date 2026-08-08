;; Exception handling: a tag section (id 13), which the binary grammar
;; places between the memory section (id 5) and the global section (id 6)
;; -- the second place where section id order != section encoding order.
(module
  (tag $oops (param i32))

  (memory 1)
  (global $g (mut i32) (i32.const 0))

  (func $thrower
    i32.const 5
    throw $oops)

  (func $catcher (result i32)
    (block $handler (result i32)
      (try_table (result i32) (catch $oops $handler)
        call $thrower
        i32.const 0)))

  (export "catcher" (func $catcher))
  (export "oops" (tag $oops)))
