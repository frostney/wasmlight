"""Emit x64-v128-cache.wast beside this script: an adversarial .wast for the
x64 xmm cache that keeps v128 values in registers inside static-cache loops
(fixed v128 locals, hoisted loop-invariant v128.const hosts, and dynamic
xmm temporaries under deferred write-back). Every expected value comes from
the lane model below, not from any wasmlight tier.

Regenerate with `python3 tests/fixtures/wast/x64-v128-cache.py`; output is
deterministic, so a clean tree after a run means nothing drifted."""
import os

M128 = (1 << 128) - 1


def lanes(v, bits):
    m = (1 << bits) - 1
    return [(v >> (bits * k)) & m for k in range(128 // bits)]


def pack(ls, bits):
    m = (1 << bits) - 1
    v = 0
    for k, x in enumerate(ls):
        v |= (x & m) << (bits * k)
    return v


def i32x4(*ls):
    return pack(ls, 32)


def lanewise(bits, f):
    def op(a, b):
        return pack([f(x, y) for x, y in zip(lanes(a, bits), lanes(b, bits))],
                    bits)
    return op


add8, add16, add32, add64 = (lanewise(b, lambda x, y: x + y)
                             for b in (8, 16, 32, 64))
sub8, sub16, sub32, sub64 = (lanewise(b, lambda x, y: x - y)
                             for b in (8, 16, 32, 64))


def splat(x, bits):
    return pack([x] * (128 // bits), bits)


def vnot(a):
    return ~a & M128


def andnot(a, b):
    return a & ~b & M128


def extract_s(v, bits, lane):
    x = lanes(v, bits)[lane]
    return x - (1 << bits) if x >> (bits - 1) else x


def extract_u(v, bits, lane):
    return lanes(v, bits)[lane]


def w32(x):
    return x & 0xFFFFFFFF


def w64(x):
    return x & 0xFFFFFFFFFFFFFFFF


def joins(n):
    i, acc = 0, i32x4(1, 2, 3, 4)
    while True:
        t = acc ^ splat(i, 32)
        if i & 1:
            u = sub32(acc, i32x4(7, 70, 700, 7000))
        else:
            u = add8(acc, splat(i, 8))
        acc = add32(t, u)
        i = w32(i + 1)
        if not i < w32(n):
            return acc


def carried(n):
    i, v = 0, i32x4(5, 6, 7, 8)
    while True:
        v = add32(v, i32x4(3, 1, 4, 1)) ^ splat(i, 32)
        i = w32(i + 1)
        if not i < w32(n):
            return v


def trapmid(n, bad):
    i, acc = 0, i32x4(9, 8, 7, 6)
    while True:
        t = add32(acc, splat(w32(i * 3), 32))
        if i == w32(bad):
            return None
        u = acc | i32x4(1, 0, 1, 0)
        acc = sub32(t, u)
        i = w32(i + 1)
        if not i < w32(n):
            return acc


def pressure(n):
    i = 0
    a, b, c, d = (i32x4(1, 2, 3, 4), i32x4(0x10, 0x20, 0x30, 0x40),
                  i32x4(0xF0F0F0F0, 0x0F0F0F0F, 0xFF00FF00, 0x00FF00FF),
                  i32x4(0x1234, 0x5678, 0x9ABC, 0xDEF0))
    e, f, g, h = (i32x4(0xFFFFFFFF, 1, 0x80000000, 0x7FFFFFFF),
                  i32x4(0xDEADBEEF, 0xCAFEBABE, 0x01234567, 0x89ABCDEF),
                  i32x4(0x55555555, 0xAAAAAAAA, 0x33333333, 0xCCCCCCCC),
                  i32x4(0xFFFF0000, 0x0000FFFF, 0xFF0000FF, 0x00FFFF00))
    while True:
        inner = add32(a, splat(i, 32))
        inner = h & inner
        inner = sub8(g, inner)
        inner = f ^ inner
        inner = add64(e, inner)
        inner = sub16(d, inner)
        inner = andnot(c, inner)
        a = sub32(b, inner)
        h = h | a
        g = sub64(g, h)
        b = add16(b, g)
        c = c ^ add32(d, splat(i, 32))
        d = andnot(e, sub8(d, f))
        e = vnot(e) ^ a
        f = add8(f, add16(g, c))
        i = w32(i + 1)
        if not i < w32(n):
            return a ^ b ^ c ^ d ^ e ^ f ^ g ^ h


def consts(n):
    i = j = 0
    x = 0
    while True:
        x = add32(x, i32x4(1, 2, 3, 4))
        x = x ^ (M128 if i & 1 else i32x4(0x10, 0x20, 0x30, 0x40))
        i = w32(i + 1)
        if not i < w32(n):
            break
    while True:
        x = sub32(x, i32x4(1, 2, 3, 4))
        x = add16(x, 0)
        j = w32(j + 1)
        if not j < w32(n):
            return x


MANY = [i32x4(k * 0x01010101, k + 1, 0x80000000 | k, 0xFFFFFFFF - k)
        for k in range(1, 11)]


def manyconsts(n):
    i, acc, alt = 0, i32x4(1, 1, 1, 1), 0
    while True:
        t = acc
        for k, c in enumerate(MANY):
            t = add32(t, c) if k % 2 == 0 else t ^ c
        acc = sub32(t, alt)
        alt = add64(alt, MANY[i & 7])
        i = w32(i + 1)
        if not i < w32(n):
            return acc ^ alt


MIX0 = pack([0, 1, 2, 3, 0x7F, 0x80, 0xFE, 0xFF,
             8, 9, 0xAA, 0x55, 12, 13, 0x81, 0xF0], 8)


def mix(n):
    i, v, s, t = 0, MIX0, 0, 0
    while True:
        v = add8(v, splat(w32(i + 0x7D), 8))
        s = w32(s + w32(extract_s(v, 8, 15) ^ extract_u(v, 8, 3)))
        s = w32(s - w32(extract_s(v, 16, 7) ^ extract_u(v, 16, 0)))
        v = sub16(v, splat(s, 16))
        v = add64(v, splat(t, 64))
        t = w64(t + extract_u(v, 64, 1))
        t = t ^ extract_u(v, 64, 0)
        s = w32(s + extract_u(v, 32, 2))
        v = vnot(v)
        v = (v & splat(s, 32)) | splat(i, 32)
        i = w32(i + 1)
        if not i < w32(n):
            return t ^ extract_u(splat(s, 32), 64, 0)


def vk(a, b, n):
    i = 0
    while True:
        a = add32(a, b)
        b = b ^ splat(i, 32)
        i = w32(i + 1)
        if not i < w32(n):
            return sub64(a, b)


def vkcaller(n):
    k, acc = 0, i32x4(1, 1, 1, 1)
    while True:
        acc = vk(acc, i32x4(2, 3, 5, 7), k)
        k = w32(k + 1)
        if not k < w32(n):
            return acc


def early(n, stop):
    i, acc = 0, i32x4(3, 5, 7, 11)
    while True:
        acc = add32(add32(acc, acc), splat(i, 32))
        if i == w32(stop):
            return acc ^ i32x4(0xFFFFFFFF, 0, 0xFFFFFFFF, 0)
        if i == 6:
            out = sub8(acc, splat(i, 8))
            break
        i = w32(i + 1)
        if not i < w32(n):
            out = i32x4(100, 200, 300, 400)
            break
    return add32(out, splat(i, 32))


def nested(n, m):
    i = 0
    acc = 0
    while True:
        row = splat(i, 32)
        j = 0
        while True:
            row = add32(row, i32x4(1, 2, 3, 4))
            j = w32(j + 1)
            if not j < w32(m):
                break
        acc = add16(acc, row) ^ splat(j, 32)
        i = w32(i + 1)
        if not i < w32(n):
            return acc


def replace(n):
    i, v = 0, 0
    while True:
        v = add32(v, i32x4(1, 1, 1, 1))
        ls = lanes(v, 32)
        ls[1] = i
        v = pack(ls, 32)
        i = w32(i + 1)
        if not i < w32(n):
            return v


def aliased(n):
    i, s, v, w = 0, 0, i32x4(1, 2, 3, 4), i32x4(9, 8, 7, 6)
    while True:
        d = sub32(v, i32x4(5, 6, 7, 8))
        sp = splat(s, 32)
        s = i
        v = d ^ sp
        w = add32(v, w)
        v = add64(w, v)
        i = w32(i + 1)
        if not i < w32(n):
            return v ^ w


def many_consts_wat():
    lines = []
    expr = '(local.get $acc)'
    for k, c in enumerate(MANY):
        op = 'i32x4.add' if k % 2 == 0 else 'v128.xor'
        expr = '(%s %s (v128.const i32x4 %s))' % (
            op, expr, ' '.join(str(x) for x in lanes(c, 32)))
    lines.append('      (local.set $t %s)' % expr)
    return '\n'.join(lines)


def alt_consts():
    # alt += MANY[i & 7], spelled as an eight-arm if-chain of i64x2.add over
    # constants selected by the masked counter: more in-loop constants than
    # fixed hosts, each the only writer of its temporary.
    out = []
    for k, c in enumerate(MANY[:8]):
        out.append('        (if (i32.eq (local.get $r) (i32.const %d))\n'
                   '          (then (local.set $alt (i64x2.add (local.get $alt)'
                   ' (v128.const i32x4 %s)))))'
                   % (k, ' '.join(str(x) for x in lanes(c, 32))))
    return '\n'.join(out)


WAT = r'''
(module
  (func (export "joins") (param $n i32) (result v128)
    (local $i i32) (local $acc v128)
    (local.set $acc (v128.const i32x4 1 2 3 4))
    (loop $l
      (local.set $acc
        (i32x4.add
          (v128.xor (local.get $acc) (i32x4.splat (local.get $i)))
          (if (result v128) (i32.and (local.get $i) (i32.const 1))
            (then (i32x4.sub (local.get $acc)
                             (v128.const i32x4 7 70 700 7000)))
            (else (i8x16.add (local.get $acc)
                             (i8x16.splat (local.get $i)))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $acc))

  (func (export "carried") (param $n i32) (result v128)
    (local $i i32)
    v128.const i32x4 5 6 7 8
    loop $l (param v128) (result v128)
      v128.const i32x4 3 1 4 1
      i32x4.add
      local.get $i
      i32x4.splat
      v128.xor
      local.get $i
      i32.const 1
      i32.add
      local.tee $i
      local.get $n
      i32.lt_u
      br_if $l
    end)

  (func (export "trapmid") (param $n i32) (param $bad i32) (result v128)
    (local $i i32) (local $acc v128)
    (local.set $acc (v128.const i32x4 9 8 7 6))
    (loop $l
      (local.set $acc
        (i32x4.sub
          (i32x4.add (local.get $acc)
                     (i32x4.splat (i32.mul (local.get $i) (i32.const 3))))
          (block (result v128)
            (if (i32.eq (local.get $i) (local.get $bad)) (then unreachable))
            (v128.or (local.get $acc) (v128.const i32x4 1 0 1 0)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $acc))

  (func (export "pressure") (param $n i32) (result v128)
    (local $i i32)
    (local $a v128) (local $b v128) (local $c v128) (local $d v128)
    (local $e v128) (local $f v128) (local $g v128) (local $h v128)
    (local.set $a (v128.const i32x4 1 2 3 4))
    (local.set $b (v128.const i32x4 0x10 0x20 0x30 0x40))
    (local.set $c (v128.const i32x4 0xF0F0F0F0 0x0F0F0F0F 0xFF00FF00 0x00FF00FF))
    (local.set $d (v128.const i32x4 0x1234 0x5678 0x9ABC 0xDEF0))
    (local.set $e (v128.const i32x4 0xFFFFFFFF 1 0x80000000 0x7FFFFFFF))
    (local.set $f (v128.const i32x4 0xDEADBEEF 0xCAFEBABE 0x01234567 0x89ABCDEF))
    (local.set $g (v128.const i32x4 0x55555555 0xAAAAAAAA 0x33333333 0xCCCCCCCC))
    (local.set $h (v128.const i32x4 0xFFFF0000 0x0000FFFF 0xFF0000FF 0x00FFFF00))
    (loop $l
      (local.set $a
        (i32x4.sub (local.get $b)
          (v128.andnot (local.get $c)
            (i16x8.sub (local.get $d)
              (i64x2.add (local.get $e)
                (v128.xor (local.get $f)
                  (i8x16.sub (local.get $g)
                    (v128.and (local.get $h)
                      (i32x4.add (local.get $a)
                                 (i32x4.splat (local.get $i)))))))))))
      (local.set $h (v128.or (local.get $h) (local.get $a)))
      (local.set $g (i64x2.sub (local.get $g) (local.get $h)))
      (local.set $b (i16x8.add (local.get $b) (local.get $g)))
      (local.set $c (v128.xor (local.get $c)
                              (i32x4.add (local.get $d)
                                         (i32x4.splat (local.get $i)))))
      (local.set $d (v128.andnot (local.get $e)
                                 (i8x16.sub (local.get $d) (local.get $f))))
      (local.set $e (v128.xor (v128.not (local.get $e)) (local.get $a)))
      (local.set $f (i8x16.add (local.get $f)
                               (i16x8.add (local.get $g) (local.get $c))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (v128.xor (local.get $a)
      (v128.xor (local.get $b)
        (v128.xor (local.get $c)
          (v128.xor (local.get $d)
            (v128.xor (local.get $e)
              (v128.xor (local.get $f)
                (v128.xor (local.get $g) (local.get $h)))))))))

  (func (export "consts") (param $n i32) (result v128)
    (local $i i32) (local $j i32) (local $x v128)
    (local.set $x (v128.const i64x2 0 0))
    (loop $a
      (local.set $x (i32x4.add (local.get $x) (v128.const i32x4 1 2 3 4)))
      (local.set $x
        (v128.xor (local.get $x)
          (if (result v128) (i32.and (local.get $i) (i32.const 1))
            (then (v128.const i32x4 -1 -1 -1 -1))
            (else (v128.const i32x4 0x10 0x20 0x30 0x40)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $a (i32.lt_u (local.get $i) (local.get $n))))
    (loop $b
      (local.set $x (i32x4.sub (local.get $x) (v128.const i32x4 1 2 3 4)))
      (local.set $x (i16x8.add (local.get $x) (v128.const i64x2 0 0)))
      (local.set $j (i32.add (local.get $j) (i32.const 1)))
      (br_if $b (i32.lt_u (local.get $j) (local.get $n))))
    (local.get $x))

  (func (export "manyconsts") (param $n i32) (result v128)
    (local $i i32) (local $r i32) (local $acc v128) (local $alt v128)
    (local $t v128)
    (local.set $acc (v128.const i32x4 1 1 1 1))
    (loop $l
@MANY@
      (local.set $acc (i32x4.sub (local.get $t) (local.get $alt)))
      (local.set $r (i32.and (local.get $i) (i32.const 7)))
@ALT@
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (v128.xor (local.get $acc) (local.get $alt)))

  (func (export "manyconsts_norem") (param $n i32) (result v128)
    (local $i i32) (local $acc v128) (local $t v128)
    (local.set $acc (v128.const i32x4 1 1 1 1))
    (loop $l
@MANY@
      (local.set $acc (local.get $t))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $acc))

  (func (export "mix") (param $n i32) (result i64)
    (local $i i32) (local $s i32) (local $t i64) (local $v v128)
    (local.set $v (v128.const i8x16 0 1 2 3 0x7F 0x80 0xFE 0xFF
                                    8 9 0xAA 0x55 12 13 0x81 0xF0))
    (loop $l
      (local.set $v (i8x16.add (local.get $v)
                               (i8x16.splat (i32.add (local.get $i)
                                                     (i32.const 0x7D)))))
      (local.set $s (i32.add (local.get $s)
        (i32.xor (i8x16.extract_lane_s 15 (local.get $v))
                 (i8x16.extract_lane_u 3 (local.get $v)))))
      (local.set $s (i32.sub (local.get $s)
        (i32.xor (i16x8.extract_lane_s 7 (local.get $v))
                 (i16x8.extract_lane_u 0 (local.get $v)))))
      (local.set $v (i16x8.sub (local.get $v) (i16x8.splat (local.get $s))))
      (local.set $v (i64x2.add (local.get $v) (i64x2.splat (local.get $t))))
      (local.set $t (i64.add (local.get $t)
                             (i64x2.extract_lane 1 (local.get $v))))
      (local.set $t (i64.xor (local.get $t)
                             (i64x2.extract_lane 0 (local.get $v))))
      (local.set $s (i32.add (local.get $s)
                             (i32x4.extract_lane 2 (local.get $v))))
      (local.set $v (v128.not (local.get $v)))
      (local.set $v (v128.or (v128.and (local.get $v)
                                       (i32x4.splat (local.get $s)))
                             (i32x4.splat (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (i64.xor (local.get $t)
             (i64x2.extract_lane 0 (i32x4.splat (local.get $s)))))

  (func $vk (export "vk") (param $a v128) (param $b v128) (param $n i32)
    (result v128)
    (local $i i32)
    (loop $l
      (local.set $a (i32x4.add (local.get $a) (local.get $b)))
      (local.set $b (v128.xor (local.get $b) (i32x4.splat (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (i64x2.sub (local.get $a) (local.get $b)))

  (func (export "vkcaller") (param $n i32) (result v128)
    (local $k i32) (local $acc v128)
    (local.set $acc (v128.const i32x4 1 1 1 1))
    (loop $l
      (local.set $acc (call $vk (local.get $acc)
                                (v128.const i32x4 2 3 5 7) (local.get $k)))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $k) (local.get $n))))
    (local.get $acc))

  (func (export "early") (param $n i32) (param $stop i32) (result v128)
    (local $i i32) (local $acc v128)
    (local.set $acc (v128.const i32x4 3 5 7 11))
    (i32x4.add
      (block $done (result v128)
        (loop $l
          (local.set $acc (i32x4.add (i32x4.add (local.get $acc)
                                                (local.get $acc))
                                     (i32x4.splat (local.get $i))))
          (if (i32.eq (local.get $i) (local.get $stop))
            (then (return (v128.xor (local.get $acc)
                                    (v128.const i32x4 -1 0 -1 0)))))
          (drop (br_if $done (i8x16.sub (local.get $acc)
                                        (i8x16.splat (local.get $i)))
                             (i32.eq (local.get $i) (i32.const 6))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
        (v128.const i32x4 100 200 300 400))
      (i32x4.splat (local.get $i))))

  (func (export "nested") (param $n i32) (param $m i32) (result v128)
    (local $i i32) (local $j i32) (local $acc v128) (local $row v128)
    (loop $outer
      (local.set $row (i32x4.splat (local.get $i)))
      (local.set $j (i32.const 0))
      (loop $inner
        (local.set $row (i32x4.add (local.get $row)
                                   (v128.const i32x4 1 2 3 4)))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br_if $inner (i32.lt_u (local.get $j) (local.get $m))))
      (local.set $acc (v128.xor (i16x8.add (local.get $acc) (local.get $row))
                                (i32x4.splat (local.get $j))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $outer (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $acc))

  (func (export "replace") (param $n i32) (result v128)
    (local $i i32) (local $v v128)
    (loop $l
      (local.set $v (i32x4.replace_lane 1
                      (i32x4.add (local.get $v) (v128.const i32x4 1 1 1 1))
                      (local.get $i)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $v))
  (func (export "aliased") (param $n i32) (result v128)
    (local $i i32) (local $s i32) (local $v v128) (local $w v128)
    (local.set $v (v128.const i32x4 1 2 3 4))
    (local.set $w (v128.const i32x4 9 8 7 6))
    (loop $l
      local.get $v
      (local.set $v (v128.const i32x4 5 6 7 8))
      local.get $v
      i32x4.sub
      local.get $s
      (local.set $s (local.get $i))
      i32x4.splat
      v128.xor
      local.set $v
      (local.set $v (i64x2.add (local.tee $w (i32x4.add (local.get $v)
                                                         (local.get $w)))
                               (local.get $v)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (v128.xor (local.get $v) (local.get $w)))
)
'''


def many_norem(n):
    i, acc = 0, i32x4(1, 1, 1, 1)
    while True:
        t = acc
        for k, c in enumerate(MANY):
            t = add32(t, c) if k % 2 == 0 else t ^ c
        acc = t
        i = w32(i + 1)
        if not i < w32(n):
            return acc


def v128(v):
    return '(v128.const i32x4 %s)' % ' '.join(str(x) for x in lanes(v, 32))


def arg(a):
    return v128(a) if isinstance(a, tuple) else '(i32.const %d)' % a


def ret(name, args, value, ty='v128'):
    a = ' '.join(v128(x[1]) if isinstance(x, tuple) else '(i32.const %d)' % x
                 for x in args)
    if ty == 'v128':
        want = v128(value)
    else:
        want = '(%s.const %d)' % (ty, value)
    return '(assert_return (invoke "%s" %s) %s)' % (name, a, want)


def trap(name, args, msg):
    a = ' '.join('(i32.const %d)' % x for x in args)
    return '(assert_trap (invoke "%s" %s) "%s")' % (name, a, msg)


wat = WAT.strip().replace('@MANY@', many_consts_wat()).replace(
    '@ALT@', alt_consts())
lines = [wat]
for n in (0, 1, 2, 3, 7, 33):
    lines.append(ret('joins', [n], joins(n)))
for n in (0, 1, 2, 9, 40):
    lines.append(ret('carried', [n], carried(n)))
for n, bad in ((8, 100), (1, 5), (3, 7)):
    lines.append(ret('trapmid', [n, bad], trapmid(n, bad)))
for n, bad in ((8, 5), (8, 0), (1, 0), (3, 2)):
    assert trapmid(n, bad) is None
    lines.append(trap('trapmid', [n, bad], 'unreachable'))
for n in (0, 1, 2, 5, 17):
    lines.append(ret('pressure', [n], pressure(n)))
for n in (0, 1, 2, 6):
    lines.append(ret('consts', [n], consts(n)))
for n in (0, 1, 3, 12, 25):
    lines.append(ret('manyconsts', [n], manyconsts(n)))
for n in (1, 4):
    lines.append(ret('manyconsts_norem', [n], many_norem(n)))
for n in (0, 1, 2, 9, 31):
    lines.append(ret('mix', [n], mix(n), 'i64'))
for a, b, n in ((i32x4(1, 2, 3, 4), i32x4(5, 6, 7, 8), 0),
                (i32x4(0xFFFFFFFF, 0, 0x80000000, 7), i32x4(1, 1, 1, 1), 5),
                (i32x4(9, 9, 9, 9), i32x4(0xDEADBEEF, 3, 0, 0x7FFFFFFF), 13)):
    lines.append(ret('vk', [('v', a), ('v', b), n], vk(a, b, n)))
for n in (1, 4, 6):
    lines.append(ret('vkcaller', [n], vkcaller(n)))
for n, stop in ((10, 100), (10, 3), (4, 100), (10, 0), (12, 100), (5, 6)):
    lines.append(ret('early', [n, stop], early(n, stop)))
for n, m in ((0, 0), (1, 1), (3, 4), (5, 2)):
    lines.append(ret('nested', [n, m], nested(n, m)))
for n in (1, 5):
    lines.append(ret('replace', [n], replace(n)))
for n in (1, 2, 7):
    lines.append(ret('aliased', [n], aliased(n)))

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   'x64-v128-cache.wast')
open(OUT, 'w', newline='\n').write('\n'.join(lines) + '\n')
print(len(lines) - 1, 'assertions')
