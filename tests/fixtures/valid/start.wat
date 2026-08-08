;; Start section (id 8) plus active data and active element segments, so
;; the section run spans start -> element -> code -> data.
(module
  (memory 1)
  (table 2 funcref)
  (global $g (mut i32) (i32.const 0))

  (func $init
    i32.const 7
    global.set $g)

  (func $noop)

  (start $init)

  (elem (i32.const 0) $init $noop)
  (data (i32.const 0) "hello fixture")

  (export "g" (global $g)))
