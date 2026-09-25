"""Emit x64-writeback.wast beside this script: an adversarial .wast for the
x64 deferred write-back and native return-tail plans. Every expected value
comes from the Python model below, not from any wasmlight tier.

Regenerate with `python3 tests/fixtures/wast/x64-writeback.py`; output is
deterministic, so a clean tree after a run means nothing drifted."""
M32 = (1 << 32) - 1
M64 = (1 << 64) - 1


def w32(x):
    return x & M32


def w64(x):
    return x & M64


def s32(x):
    x &= M32
    return x - (1 << 32) if x >> 31 else x


def rotr32(x, n):
    n &= 31
    return w32((x >> n) | (x << (32 - n)))


def rotr64(x, n):
    n &= 63
    return w64((x >> n) | (x << (64 - n)))


def joins(n):
    i, acc = 0, 11
    while True:
        t3 = w32(acc * 5) ^ w32(i * 7)
        t5 = w32(acc - i) if i & 1 else w32(i << 2)
        acc = w32(t3 + t5)
        i = w32(i + 1)
        if not i < w32(n):
            break
    return acc


def pressure(a, b, c, d):
    acc, i = 1, 0
    while True:
        t5 = w64(w64(acc * a) + w64((b ^ i) - w64(c << (i & 7))))
        t10 = w64(w64(rotr64(d, 3) + (acc >> 1)) - w64(i * b))
        acc = t5 ^ t10
        i += 1
        if not i < 6:
            break
    return acc


def early(n, stop):
    i, acc = 0, 1
    while True:
        acc = w32(w32(acc * 5) + (i ^ 3))
        if i == stop:
            return w32(acc - 1000)
        if i == 9:
            return w32(w32(acc * 3) + i)
        if i == 6 and n % 2 == 0:
            return w32((acc ^ i) + i)
        i = w32(i + 1)
        if not i < w32(n):
            break
    return w32(77 + i)


def trapmid(n, bad):
    i, acc = 0, 5
    while True:
        if (i & 3) == 1 and i == bad:
            return None
        acc = w32(w32(acc * 7) + w32(i + 3))
        i = w32(i + 1)
        if not i < w32(n):
            break
    return acc


def nested(n, m):
    i, s, carried = 0, 0, 17
    while True:
        j = 0
        while True:
            carried = w32(w32(carried * 3) + j)
            s = w32((s ^ j) + i)
            j = w32(j + 1)
            if not j < w32(m):
                break
        i = w32(i + 1)
        if not i < w32(n):
            break
    return w32(carried + s)


def pre(n):
    i, acc = 0, 1
    while True:
        acc = w32(w32(acc * 3) + i)
        i = w32(i + 1)
        if not i < w32(n):
            break
    return w32(w32(n * 13) + acc)


def twoback(n):
    acc, i = 1, 0
    while True:
        acc = w32(w32(acc * 9) + rotr32(i, 1))
        i = w32(i + 1)
        if i < w32(n) and (i & 1) == 0:
            continue
        if i >= w32(n):
            break
        acc = acc ^ w32(i << 3)
    return acc


def divloop(n, z):
    i, acc = 0, 100
    while True:
        d = s32(i - z)
        if d == 0:
            return None
        q = abs(1000) // abs(d)
        if d < 0:
            q = -q
        acc = w32(w32(acc * 3) + q)
        i = w32(i + 1)
        if not i < w32(n):
            break
    return acc


def rec3(n):
    n = w64(n)
    if n < 2:
        return w64(n + 0x300000005)
    if (n & 3) == 2:
        return n ^ 0x200000001
    return w64(rec3(n - 1) - w64(rec3(n - 2) * 3))


def leafsel(a, b):
    return w64(a * 0x100000007) if a < b else w64(b + 0x200000009)


def leafid(a, b):
    return b


def leafconst(a):
    return 0x123456789


def leafeqz(a):
    return 1 if a == 0 else 0


def leafdrive(k):
    acc, i = 0, 0
    while True:
        acc = w64(acc + (leafsel(i, w64(k - i)) ^ leafid(i, w64(i * 3))) +
                  leafconst(i) + leafeqz(i))
        i += 1
        if not i < k:
            break
    return acc


WAT = r'''
(module
  (func (export "joins") (param $n i32) (result i32)
    (local $i i32) (local $acc i32)
    (local.set $acc (i32.const 11))
    (loop $l
      (local.set $acc (i32.add
        (i32.xor (i32.mul (local.get $acc) (i32.const 5))
                 (i32.mul (local.get $i) (i32.const 7)))
        (if (result i32) (i32.and (local.get $i) (i32.const 1))
          (then (i32.sub (local.get $acc) (local.get $i)))
          (else (i32.shl (local.get $i) (i32.const 2))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $acc))

  (func (export "pressure") (param $a i64) (param $b i64) (param $c i64)
    (param $d i64) (result i64)
    (local $i i64) (local $acc i64)
    (local.set $acc (i64.const 1))
    (loop $l
      (local.set $acc (i64.xor
        (i64.add (i64.mul (local.get $acc) (local.get $a))
                 (i64.sub (i64.xor (local.get $b) (local.get $i))
                          (i64.shl (local.get $c)
                                   (i64.and (local.get $i) (i64.const 7)))))
        (i64.sub (i64.add (i64.rotr (local.get $d) (i64.const 3))
                          (i64.shr_u (local.get $acc) (i64.const 1)))
                 (i64.mul (local.get $i) (local.get $b)))))
      (local.set $i (i64.add (local.get $i) (i64.const 1)))
      (br_if $l (i64.lt_u (local.get $i) (i64.const 6))))
    (local.get $acc))

  (func (export "early") (param $n i32) (param $stop i32) (result i32)
    (local $i i32) (local $acc i32)
    (local.set $acc (i32.const 1))
    (i32.add
      (block $done (result i32)
        (loop $l
          (local.set $acc (i32.add (i32.mul (local.get $acc) (i32.const 5))
                                   (i32.xor (local.get $i) (i32.const 3))))
          (if (i32.eq (local.get $i) (local.get $stop))
            (then (return (i32.sub (local.get $acc) (i32.const 1000)))))
          (if (i32.eq (local.get $i) (i32.const 9))
            (then (br $done (i32.mul (local.get $acc) (i32.const 3)))))
          (drop (br_if $done (i32.xor (local.get $acc) (local.get $i))
                             (i32.and (i32.eq (local.get $i) (i32.const 6))
                                      (i32.eqz (i32.and (local.get $n)
                                                        (i32.const 1))))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
        (i32.const 77))
      (local.get $i)))

  (func (export "trapmid") (param $n i32) (param $bad i32) (result i32)
    (local $i i32) (local $acc i32)
    (local.set $acc (i32.const 5))
    (loop $l
      (local.set $acc (i32.add (i32.mul (local.get $acc) (i32.const 7))
        (block (result i32)
          (if (i32.eq (i32.and (local.get $i) (i32.const 3)) (i32.const 1))
            (then (if (i32.eq (local.get $i) (local.get $bad))
                    (then unreachable))))
          (i32.add (local.get $i) (i32.const 3)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $acc))

  (func (export "nested") (param $n i32) (param $m i32) (result i32)
    (local $i i32) (local $j i32) (local $s i32)
    i32.const 17
    loop $outer (param i32) (result i32)
      (local.set $j (i32.const 0))
      loop $inner (param i32) (result i32)
        i32.const 3 i32.mul local.get $j i32.add
        local.get $s local.get $j i32.xor local.get $i i32.add local.set $s
        local.get $j i32.const 1 i32.add local.tee $j
        local.get $m i32.lt_u br_if $inner
      end
      local.get $i i32.const 1 i32.add local.tee $i
      local.get $n i32.lt_u br_if $outer
    end
    local.get $s i32.add)

  (func (export "pre") (param $n i32) (result i32)
    (local $i i32) (local $acc i32)
    (local.set $acc (i32.const 1))
    (i32.add (i32.mul (local.get $n) (i32.const 13))
      (block $b (result i32)
        (loop $l
          (local.set $acc (i32.add (i32.mul (local.get $acc) (i32.const 3))
                                   (local.get $i)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
        (local.get $acc))))

  (func (export "twoback") (param $n i32) (result i32)
    (local $i i32) (local $acc i32)
    (local.set $acc (i32.const 1))
    (block $out
      (loop $l
        (local.set $acc (i32.add (i32.mul (local.get $acc) (i32.const 9))
                                 (i32.rotr (local.get $i) (i32.const 1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br_if $l (i32.and (i32.lt_u (local.get $i) (local.get $n))
                           (i32.eqz (i32.and (local.get $i) (i32.const 1)))))
        (br_if $out (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $acc (i32.xor (local.get $acc)
                                 (i32.shl (local.get $i) (i32.const 3))))
        (br $l)))
    (local.get $acc))

  (func (export "divloop") (param $n i32) (param $z i32) (result i32)
    (local $i i32) (local $acc i32)
    (local.set $acc (i32.const 100))
    (loop $l
      (local.set $acc (i32.add (i32.mul (local.get $acc) (i32.const 3))
        (i32.div_s (i32.const 1000) (i32.sub (local.get $i) (local.get $z)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $acc))

  (func $rec3 (export "rec3") (param $n i64) (result i64)
    (block $out (result i64)
      (if (i64.lt_u (local.get $n) (i64.const 2))
        (then (br $out (i64.add (local.get $n) (i64.const 12884901893)))))
      (if (i64.eq (i64.and (local.get $n) (i64.const 3)) (i64.const 2))
        (then (br $out (i64.xor (local.get $n) (i64.const 8589934593)))))
      (i64.sub (call $rec3 (i64.sub (local.get $n) (i64.const 1)))
               (i64.mul (call $rec3 (i64.sub (local.get $n) (i64.const 2)))
                        (i64.const 3)))))

  (func $leafsel (export "leafsel") (param $a i64) (param $b i64) (result i64)
    (select (i64.mul (local.get $a) (i64.const 4294967303))
            (i64.add (local.get $b) (i64.const 8589934601))
            (i64.lt_u (local.get $a) (local.get $b))))
  (func $leafid (export "leafid") (param $a i64) (param $b i64) (result i64)
    (local.get $b))
  (func $leafconst (export "leafconst") (param $a i64) (result i64)
    (i64.const 4886718345))
  (func $leafeqz (export "leafeqz") (param $a i64) (result i32)
    (i64.eqz (local.get $a)))

  (func (export "leafdrive") (param $k i64) (result i64)
    (local $i i64) (local $acc i64)
    (loop $l
      (local.set $acc (i64.add (i64.add (i64.add (local.get $acc)
        (i64.xor (call $leafsel (local.get $i) (i64.sub (local.get $k) (local.get $i)))
                 (call $leafid (local.get $i) (i64.mul (local.get $i) (i64.const 3)))))
        (call $leafconst (local.get $i)))
        (i64.extend_i32_u (call $leafeqz (local.get $i)))))
      (local.set $i (i64.add (local.get $i) (i64.const 1)))
      (br_if $l (i64.lt_u (local.get $i) (local.get $k))))
    (local.get $acc))
)
'''


def ret(name, args, value, ty='i32'):
    a = ' '.join('(%s.const %d)' % (t, v) for t, v in args)
    return '(assert_return (invoke "%s" %s) (%s.const %d))' % (name, a, ty, value)


def trap(name, args, msg):
    a = ' '.join('(%s.const %d)' % (t, v) for t, v in args)
    return '(assert_trap (invoke "%s" %s) "%s")' % (name, a, msg)


lines = [WAT.strip()]
for n in (0, 1, 2, 3, 7, 16, 33):
    lines.append(ret('joins', [('i32', n)], joins(n)))
for args in ((3, 5, 7, 11), (0x7fffffff, 0xffffffff, 0x100000001, 0xdeadbeefcafebabe),
             (1, 0, 0, 0), (0xffffffffffffffff,) * 4):
    lines.append(ret('pressure', [('i64', v) for v in args], pressure(*args), 'i64'))
for n, stop in ((10, 100), (10, 3), (4, 100), (10, 0), (12, 100), (8, 7), (20, 15),
                (11, 100), (21, 100), (7, 100), (11, 8)):
    lines.append(ret('early', [('i32', n), ('i32', stop)], early(n, stop)))
for n, bad in ((8, 100), (8, 6), (1, 0), (8, 0), (3, 2)):
    lines.append(ret('trapmid', [('i32', n), ('i32', bad)], trapmid(n, bad)))
for n, bad in ((8, 5), (8, 1), (3, 1)):
    assert trapmid(n, bad) is None
    lines.append(trap('trapmid', [('i32', n), ('i32', bad)], 'unreachable'))
for n, m in ((0, 0), (1, 1), (3, 4), (5, 2), (7, 7)):
    lines.append(ret('nested', [('i32', n), ('i32', m)], nested(n, m)))
for n in (0, 1, 5, 19):
    lines.append(ret('pre', [('i32', n)], pre(n)))
for n in (0, 1, 2, 3, 8, 9, 20):
    lines.append(ret('twoback', [('i32', n)], twoback(n)))
for n, z in ((5, 100), (5, -3), (3, 7), (1, 9)):
    lines.append(ret('divloop', [('i32', n), ('i32', z)], divloop(n, z)))
for n, z in ((5, 2), (5, 0), (1, 0)):
    assert divloop(n, z) is None
    lines.append(trap('divloop', [('i32', n), ('i32', z)], 'integer divide by zero'))
for n in (0, 1, 2, 3, 4, 5, 6, 9, 13):
    lines.append(ret('rec3', [('i64', n)], rec3(n), 'i64'))
for a, b in ((1, 2), (5, 3), (0xffffffffffffffff, 0), (7, 7)):
    lines.append(ret('leafsel', [('i64', a), ('i64', b)], leafsel(a, b), 'i64'))
    lines.append(ret('leafid', [('i64', a), ('i64', b)], leafid(a, b), 'i64'))
for a in (0, 1, 0xffffffffffffffff):
    lines.append(ret('leafconst', [('i64', a)], leafconst(a), 'i64'))
    lines.append(ret('leafeqz', [('i64', a)], leafeqz(a)))
for k in (1, 2, 7, 40):
    lines.append(ret('leafdrive', [('i64', k)], leafdrive(k), 'i64'))

import os
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'x64-writeback.wast')
open(OUT, 'w', newline='\n').write('\n'.join(lines) + '\n')
print(len(lines) - 1, 'assertions')
