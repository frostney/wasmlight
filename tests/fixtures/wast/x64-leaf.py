"""Emit x64-leaf.wast beside this script: an adversarial .wast for the x64
native leaf ABI (up to four i32/i64 parameters in r8, r9, rdi, rdx; leaves
that access the caller instance's memory through a Base in rsi) and the
static-cache call sequences around it. Every expected value comes from the
Python model below, which runs the same commands in order against its own
linear memories, not from any wasmlight tier.

Regenerate with `python3 tests/fixtures/wast/x64-leaf.py`; output is
deterministic, so a clean tree after a run means nothing drifted."""
import os
import struct

M32 = (1 << 32) - 1
M64 = (1 << 64) - 1
PAGE = 65536


def w32(x):
    return x & M32


def w64(x):
    return x & M64


def s32(x):
    x &= M32
    return x - (1 << 32) if x >> 31 else x


def s64(x):
    x &= M64
    return x - (1 << 64) if x >> 63 else x


def sx(x, bits):
    x &= (1 << bits) - 1
    return x - (1 << bits) if x >> (bits - 1) else x


def rotl32(x, n):
    n &= 31
    return w32((x << n) | (x >> (32 - n)))


class Trap(Exception):
    pass


class Exhausted(Exception):
    pass


class Machine:
    """The module's two memories: $m0 (1 page, max 4) and $m1 (1 page)."""

    def __init__(self):
        self.mem = [bytearray(PAGE), bytearray(PAGE)]

    def load(self, m, addr, size, signed=False):
        addr &= M32
        if addr + size > len(self.mem[m]):
            raise Trap('out of bounds memory access')
        v = int.from_bytes(self.mem[m][addr:addr + size], 'little')
        return sx(v, size * 8) if signed else v

    def store(self, m, addr, size, value):
        addr &= M32
        if addr + size > len(self.mem[m]):
            raise Trap('out of bounds memory access')
        self.mem[m][addr:addr + size] = (value & ((1 << (size * 8)) - 1)
                                         ).to_bytes(size, 'little')

    def size(self):
        return len(self.mem[0]) // PAGE

    def grow(self, n):
        old = self.size()
        if old + n > 4:
            return M32
        self.mem[0].extend(bytearray(n * PAGE))
        return old

    # --- leaves -----------------------------------------------------------

    def l3(self, a, b, c):
        return w64(w64(w64(w32(a) * 3) + b) ^ w64(sx(c, 32) << 7))

    def l4(self, a, b, c, d):
        return w32(w32(w64(w64(a - c) * 5)) + (w32(b) ^ rotl32(d, 3)))

    def ord4(self, a, b, c, d):
        return w32(w32(a + w32(b * 10)) + w32(w32(c * 100) + w32(d * 1000)))

    def sel3(self, a, b, c):
        return w32(a + b) if w32(c) != 0 else w32(a - b)

    def sel4(self, a, b, c, d):
        return a if w32(c ^ d) != 0 else b

    def mrw(self, ident, d, p):
        v = w64(self.load(0, p, 8) + w64(d + w32(ident)))
        self.store(0, p, 8, v)
        return w32(self.load(0, p, 8))

    def ldall(self, p):
        s = 0
        for size in (1, 2, 4):
            s += w64(self.load(0, p, size, True))
            s += self.load(0, p, size)
        s += self.load(0, p, 8)
        for size in (1, 2):
            s += w32(self.load(0, p, size, True))
            s += self.load(0, p, size)
        s += self.load(0, p, 4)
        return w64(s)

    def stall(self, p, v):
        self.store(0, p, 8, v)
        self.store(0, w32(p + 8), 1, v)
        self.store(0, w32(p + 10), 2, v)
        self.store(0, w32(p + 12), 4, v)
        self.store(0, w32(p + 16), 1, v)
        self.store(0, w32(p + 18), 2, v)
        self.store(0, w32(p + 20), 4, v)
        return 7

    def two(self, p, q, v):
        self.store(0, p, 4, v)
        self.store(0, q, 4, v)
        return 1

    def off(self, p):
        return self.load(0, w64(w32(p) + 4), 4)

    def m1rd(self, p):
        return self.load(1, p, 4)

    def peek(self, p):
        return self.load(0, p, 8)

    def quad(self, p):
        return w32(w32(self.load(0, p, 4) + self.load(0, w32(p + 4), 4)) +
                   w32(w32(self.load(0, w32(p + 8), 4) ^
                           self.load(0, w32(p + 12), 4)) * 3))

    def quadloop(self, n, p):
        s, i = 0, 0
        while True:
            s = w32(s + self.quad(w32(p + w32(i * 4))))
            i = w32(i + 1)
            if not i < w32(n):
                break
        return s

    def ident(self, a, b, c):
        return c

    # --- callers ----------------------------------------------------------

    def loop3(self, n):
        acc, i = 1, 0
        while True:
            acc = self.l3(i, acc, w32(i ^ 0x5A5))
            acc = w64(acc + self.l3(7, acc, M32 - 2))
            i = w32(i + 1)
            if not i < w32(n):
                break
        return acc

    def loop4(self, n):
        a, b, c, d, i = 3, 0x100000001, 5, 7, 0
        while True:
            b = w64(b + self.l4(b, a, w64(i * 0x10001), d))
            a = self.l4(0x7FFFFFFFFFFF, i, b, a)
            d = w32(d ^ a)
            c = w32(c + d)
            i = w32(i + 1)
            if not i < w32(n):
                break
        return w32(w32(a ^ w32(b)) + w32(c ^ d))

    def loopord(self, n):
        a, b, c, d, i = 1, 2, 3, 4, 0
        while True:
            a2 = self.ord4(d, a, b, c)
            b2 = self.ord4(b, c, d, a2)
            c2 = self.ord4(c, c, c, c)
            d = w32(self.ord4(a2, b2, c2, i) ^ d)
            a, b, c = a2, b2, c2
            i = w32(i + 1)
            if not i < w32(n):
                break
        return w32(w32(a + b) + w32(c + d))

    def teeargs(self, n):
        x, s, i = 3, 0, 0
        while True:
            a0 = x
            x = w32(x + 7)
            s = w32(s + self.ord4(a0, x, x, i))
            i = w32(i + 1)
            if not i < w32(n):
                break
        return w32(s + x)

    def loopsel3(self, n):
        a, b, c, d, i = 5, 6, 7, 8, 0
        while True:
            a = self.sel3(a, w32(b ^ i), w32(i & 1))
            b = w32(b + a)
            c = w32(c ^ w32(b * 5))
            d = w32(d + w32(c ^ i))
            i = w32(i + 1)
            if not i < w32(n):
                break
        return w32(w32(a ^ b) + w32(c ^ d))

    def wide(self, n):
        acc, i = 0, 0
        while True:
            acc = w64(acc + self.l3(i, 0x123456789ABC, M32 - 5))
            i = w32(i + 1)
            if not i < w32(n):
                break
        return acc

    def loopsel(self, n):
        a, b, c, d, e, i = 9, 4, 1, 0, 0, 0
        while True:
            a = self.sel3(a, i, w32(i & 1))
            b = w32(b + self.sel4(a, i, c, d))
            c = self.sel3(c, b, a)
            d = w32(d + w32(a ^ c))
            e = w32(e + self.ident(a, b, c))
            i = w32(i + 1)
            if not i < w32(n):
                break
        return w32(w32(a + b) + w32(w32(c + d) + e))

    def loopmem(self, n, p):
        failed, i = 0, 0
        while True:
            failed = failed | self.mrw(1, w64(i), p)
            i = w32(i + 1)
            if not i < w32(n):
                break
        return w64(self.load(0, p, 8) + w32(failed))

    def loophosts(self, n, p):
        i, a, b, c, d, e = 0, 1, 2, 3, 4, 5
        while True:
            a = w32(a + self.mrw(w32(b ^ i), w64(c), p))
            b = w32(b + w32(a * 3))
            c = w32(c ^ w32(b + d))
            d = w32(d + self.m0get(w32(p + 8)))
            e = w32(e + w32(a ^ d))
            self.store(0, w32(p + 8), 4, w32(e + i))
            i = w32(i + 1)
            if not i < w32(n):
                break
        return w32(w32(a ^ b) + w32(w32(c ^ d) + e))

    def loophosts2(self, n, p):
        i, a, b, c, d, e = 0, 1, 2, 3, 4, 5
        while True:
            a = w32(a + self.mrw(w32(b ^ i), 77, p))
            b = w32(b + w32(a * 3))
            c = w32(c ^ w32(b + d))
            d = w32(d + self.load(0, w32(p + 8), 4))
            e = w32(e + w32(a ^ d))
            self.store(0, w32(p + 8), 4, w32(e + c))
            i = w32(i + 1)
            if not i < w32(n):
                break
        return w32(w32(a ^ b) + w32(w32(c ^ d) + e))

    def twoleaf(self, n, p):
        i, s = 0, 0
        while True:
            s = w32(s + self.m0get(p))
            self.store(0, p, 4, w32(s + i))
            s = self.sel3(s, i, n)
            i = w32(i + 1)
            if not i < w32(n):
                break
        return w32(s + self.load(0, p, 4))

    def m0get(self, p):
        return self.load(0, p, 4)

    def growloop(self, n):
        s, i = 0, 0
        while True:
            top = w32(w32(self.size() * PAGE) - 8)
            s = w32(s + self.mrw(i, 5, top))
            s = w32(s + self.m0get(top))
            self.grow(1)
            i = w32(i + 1)
            if not i < w32(n):
                break
        return w32(s + self.size())

    def trloop(self, n, p, q):
        i = 0
        while True:
            self.two(w32(p + w32(i * 4)), q, w32(i + 100))
            i = w32(i + 1)
            if not i < w32(n):
                break
        return i

    def rec(self, d, depth=0):
        if depth > 5000:
            raise Exhausted()
        if w32(d) == 0:
            return 0
        r = self.rec(w32(d - 1), depth + 1)
        return w32(self.mrw(1, 1, 256) + r)

    def m1call(self, p):
        return w32(self.m1rd(p) + self.load(1, w32(p + 4), 4))

    def mixmem(self, p):
        return w32(self.m1rd(p) + self.m0get(p))

    def offloop(self, n, p):
        s, i = 0, 0
        while True:
            s = w32(s + self.off(w32(p + i)))
            i = w32(i + 1)
            if not i < w32(n):
                break
        return s

    def fill(self, p, n):
        for k in range(n):
            self.store(0, w32(p + k), 1, w32(k * 37 + 0x81))
        return 0

    def fill1(self, p, n):
        for k in range(n):
            self.store(1, w32(p + k), 1, w32(k * 29 + 0x93))
        return 0


WAT = r'''
(module
  (memory $m0 1 4)
  (memory $m1 1 1)

  ;; --- leaves (x64 native leaf entry) ---------------------------------
  (func $l3 (export "l3") (param $a i32) (param $b i64) (param $c i32)
    (result i64)
    (i64.xor
      (i64.add (i64.mul (i64.extend_i32_u (local.get $a)) (i64.const 3))
               (local.get $b))
      (i64.shl (i64.extend_i32_s (local.get $c)) (i64.const 7))))
  (func $l4 (export "l4") (param $a i64) (param $b i32) (param $c i64)
    (param $d i32) (result i32)
    (i32.add
      (i32.wrap_i64 (i64.mul (i64.sub (local.get $a) (local.get $c))
                             (i64.const 5)))
      (i32.xor (local.get $b) (i32.rotl (local.get $d) (i32.const 3)))))
  (func $ord4 (export "ord4") (param i32 i32 i32 i32) (result i32)
    (i32.add
      (i32.add (local.get 0) (i32.mul (local.get 1) (i32.const 10)))
      (i32.add (i32.mul (local.get 2) (i32.const 100))
               (i32.mul (local.get 3) (i32.const 1000)))))
  (func $sel3 (export "sel3") (param $a i32) (param $b i32) (param $c i32)
    (result i32)
    (select (i32.add (local.get $a) (local.get $b))
            (i32.sub (local.get $a) (local.get $b))
            (local.get $c)))
  (func $ident (export "ident") (param i32 i32 i32) (result i32)
    (local.get 2))
  (func $mrw (export "mrw") (param $id i32) (param $d i64) (param $p i32)
    (result i32)
    (i64.store (local.get $p)
      (i64.add (i64.load (local.get $p))
               (i64.add (local.get $d) (i64.extend_i32_u (local.get $id)))))
    (i32.wrap_i64 (i64.load (local.get $p))))
  (func $ldall (export "ldall") (param $p i32) (result i64)
    (i64.add
      (i64.add
        (i64.add (i64.add (i64.load8_s (local.get $p))
                          (i64.load8_u (local.get $p)))
                 (i64.add (i64.load16_s (local.get $p))
                          (i64.load16_u (local.get $p))))
        (i64.add (i64.add (i64.load32_s (local.get $p))
                          (i64.load32_u (local.get $p)))
                 (i64.load (local.get $p))))
      (i64.add
        (i64.add
          (i64.add (i64.extend_i32_u (i32.load8_s (local.get $p)))
                   (i64.extend_i32_u (i32.load8_u (local.get $p))))
          (i64.add (i64.extend_i32_u (i32.load16_s (local.get $p)))
                   (i64.extend_i32_u (i32.load16_u (local.get $p)))))
        (i64.extend_i32_u (i32.load (local.get $p))))))
  (func $stall (export "stall") (param $p i32) (param $v i64) (result i32)
    (i64.store (local.get $p) (local.get $v))
    (i32.store8 (i32.add (local.get $p) (i32.const 8))
      (i32.wrap_i64 (local.get $v)))
    (i32.store16 (i32.add (local.get $p) (i32.const 10))
      (i32.wrap_i64 (local.get $v)))
    (i32.store (i32.add (local.get $p) (i32.const 12))
      (i32.wrap_i64 (local.get $v)))
    (i64.store8 (i32.add (local.get $p) (i32.const 16)) (local.get $v))
    (i64.store16 (i32.add (local.get $p) (i32.const 18)) (local.get $v))
    (i64.store32 (i32.add (local.get $p) (i32.const 20)) (local.get $v))
    (i32.const 7))
  (func $two (export "two") (param $p i32) (param $q i32) (param $v i32)
    (result i32)
    (i32.store (local.get $p) (local.get $v))
    (i32.store (local.get $q) (local.get $v))
    (i32.const 1))
  (func $m1rd (export "m1rd") (param $p i32) (result i32)
    (i32.load $m1 (local.get $p)))
  (func $peek (export "peek") (param $p i32) (result i64)
    (i64.load (local.get $p)))
  (func $m0get (export "m0get") (param $p i32) (result i32)
    (i32.load (local.get $p)))
  ;; Enough live values to spill: a leaf with a frame of its own.
  (func $quad (export "quad") (param $p i32) (result i32)
    (i32.add
      (i32.add (i32.load (local.get $p))
               (i32.load (i32.add (local.get $p) (i32.const 4))))
      (i32.mul
        (i32.xor (i32.load (i32.add (local.get $p) (i32.const 8)))
                 (i32.load (i32.add (local.get $p) (i32.const 12))))
        (i32.const 3))))

  ;; --- outside the leaf proof ------------------------------------------
  ;; A fourth parameter lives in rdx, which select needs.
  (func $sel4 (export "sel4") (param i32 i32 i32 i32) (result i32)
    (select (local.get 0) (local.get 1)
            (i32.xor (local.get 2) (local.get 3))))
  ;; A non-zero static offset is not the guard-page leaf form.
  (func $off (export "off") (param $p i32) (result i32)
    (i32.load offset=4 (local.get $p)))

  ;; --- callers ---------------------------------------------------------
  (func (export "loop3") (param $n i32) (result i64)
    (local $i i32) (local $acc i64)
    (local.set $acc (i64.const 1))
    (loop $l
      (local.set $acc (call $l3 (local.get $i) (local.get $acc)
        (i32.xor (local.get $i) (i32.const 0x5a5))))
      (local.set $acc (i64.add (local.get $acc)
        (call $l3 (i32.const 7) (local.get $acc) (i32.const -3))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $acc))

  (func (export "loop4") (param $n i32) (result i32)
    (local $a i32) (local $b i64) (local $c i32) (local $d i32) (local $i i32)
    (local.set $a (i32.const 3)) (local.set $b (i64.const 0x100000001))
    (local.set $c (i32.const 5)) (local.set $d (i32.const 7))
    (loop $l
      (local.set $b (i64.add (local.get $b) (i64.extend_i32_u
        (call $l4 (local.get $b) (local.get $a)
          (i64.mul (i64.extend_i32_u (local.get $i)) (i64.const 0x10001))
          (local.get $d)))))
      (local.set $a (call $l4 (i64.const 0x7fffffffffff) (local.get $i)
        (local.get $b) (local.get $a)))
      (local.set $d (i32.xor (local.get $d) (local.get $a)))
      (local.set $c (i32.add (local.get $c) (local.get $d)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (i32.add (i32.xor (local.get $a) (i32.wrap_i64 (local.get $b)))
             (i32.xor (local.get $c) (local.get $d))))

  (func (export "loopord") (param $n i32) (result i32)
    (local $a i32) (local $b i32) (local $c i32) (local $d i32) (local $i i32)
    (local $a2 i32) (local $b2 i32) (local $c2 i32)
    (local.set $a (i32.const 1)) (local.set $b (i32.const 2))
    (local.set $c (i32.const 3)) (local.set $d (i32.const 4))
    (loop $l
      (local.set $a2 (call $ord4 (local.get $d) (local.get $a) (local.get $b)
        (local.get $c)))
      (local.set $b2 (call $ord4 (local.get $b) (local.get $c) (local.get $d)
        (local.get $a2)))
      (local.set $c2 (call $ord4 (local.get $c) (local.get $c) (local.get $c)
        (local.get $c)))
      (local.set $d (i32.xor (call $ord4 (local.get $a2) (local.get $b2)
        (local.get $c2) (local.get $i)) (local.get $d)))
      (local.set $a (local.get $a2))
      (local.set $b (local.get $b2))
      (local.set $c (local.get $c2))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (i32.add (i32.add (local.get $a) (local.get $b))
             (i32.add (local.get $c) (local.get $d))))

  ;; A forwarded argument copy must not see the local.tee after it.
  (func (export "teeargs") (param $n i32) (result i32)
    (local $x i32) (local $s i32) (local $i i32)
    (local.set $x (i32.const 3))
    (loop $l
      (local.set $s (i32.add (local.get $s)
        (call $ord4 (local.get $x)
          (local.tee $x (i32.add (local.get $x) (i32.const 7)))
          (local.get $x) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (i32.add (local.get $s) (local.get $x)))

  ;; One leaf with select: rdx is its scratch, so a single-target caller
  ;; must not keep a local in rdx across the call.
  (func (export "loopsel3") (param $n i32) (result i32)
    (local $a i32) (local $b i32) (local $c i32) (local $d i32) (local $i i32)
    (local.set $a (i32.const 5)) (local.set $b (i32.const 6))
    (local.set $c (i32.const 7)) (local.set $d (i32.const 8))
    (loop $l
      (local.set $a (call $sel3 (local.get $a)
        (i32.xor (local.get $b) (local.get $i))
        (i32.and (local.get $i) (i32.const 1))))
      (local.set $b (i32.add (local.get $b) (local.get $a)))
      (local.set $c (i32.xor (local.get $c)
        (i32.mul (local.get $b) (i32.const 5))))
      (local.set $d (i32.add (local.get $d)
        (i32.xor (local.get $c) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (i32.add (i32.xor (local.get $a) (local.get $b))
             (i32.xor (local.get $c) (local.get $d))))

  ;; An i64 constant argument whose upper half the leaf reads.
  (func (export "wide") (param $n i32) (result i64)
    (local $acc i64) (local $i i32)
    (loop $l
      (local.set $acc (i64.add (local.get $acc)
        (call $l3 (local.get $i) (i64.const 0x123456789abc) (i32.const -6))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $acc))

  (func (export "loopsel") (param $n i32) (result i32)
    (local $a i32) (local $b i32) (local $c i32) (local $d i32) (local $e i32)
    (local $i i32)
    (local.set $a (i32.const 9)) (local.set $b (i32.const 4))
    (local.set $c (i32.const 1))
    (loop $l
      (local.set $a (call $sel3 (local.get $a) (local.get $i)
        (i32.and (local.get $i) (i32.const 1))))
      (local.set $b (i32.add (local.get $b) (call $sel4 (local.get $a)
        (local.get $i) (local.get $c) (local.get $d))))
      (local.set $c (call $sel3 (local.get $c) (local.get $b) (local.get $a)))
      (local.set $d (i32.add (local.get $d)
        (i32.xor (local.get $a) (local.get $c))))
      (local.set $e (i32.add (local.get $e) (call $ident (local.get $a)
        (local.get $b) (local.get $c))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (i32.add (i32.add (local.get $a) (local.get $b))
             (i32.add (i32.add (local.get $c) (local.get $d)) (local.get $e))))

  ;; The workload shape: a base-pinned static caller of a memory leaf.
  (func (export "loopmem") (param $n i32) (param $p i32) (result i64)
    (local $failed i32) (local $i i32)
    (loop $l
      (local.set $failed (i32.or (local.get $failed)
        (call $mrw (i32.const 1) (i64.extend_i32_u (local.get $i))
          (local.get $p))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (i64.add (i64.load (local.get $p)) (i64.extend_i32_u (local.get $failed))))

  ;; Six hot locals (rdi/rdx hosts) around memory-leaf calls and the
  ;; caller's own pinned accesses.
  (func (export "loophosts") (param $n i32) (param $p i32) (result i32)
    (local $i i32) (local $a i32) (local $b i32) (local $c i32) (local $d i32)
    (local $e i32)
    (local.set $a (i32.const 1)) (local.set $b (i32.const 2))
    (local.set $c (i32.const 3)) (local.set $d (i32.const 4))
    (local.set $e (i32.const 5))
    (loop $l
      (local.set $a (i32.add (local.get $a)
        (call $mrw (i32.xor (local.get $b) (local.get $i))
          (i64.extend_i32_u (local.get $c)) (local.get $p))))
      (local.set $b (i32.add (local.get $b) (i32.mul (local.get $a)
        (i32.const 3))))
      (local.set $c (i32.xor (local.get $c) (i32.add (local.get $b)
        (local.get $d))))
      (local.set $d (i32.add (local.get $d)
        (call $m0get (i32.add (local.get $p) (i32.const 8)))))
      (local.set $e (i32.add (local.get $e) (i32.xor (local.get $a)
        (local.get $d))))
      (i32.store (i32.add (local.get $p) (i32.const 8))
        (i32.add (local.get $e) (local.get $i)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (i32.add (i32.xor (local.get $a) (local.get $b))
             (i32.add (i32.xor (local.get $c) (local.get $d)) (local.get $e))))

  ;; The same with only static-cache ops: a base-pinned loop keeping locals
  ;; in rdi/rdx across a memory leaf that clobbers rdi (its third
  ;; parameter) but not rdx.
  (func (export "loophosts2") (param $n i32) (param $p i32) (result i32)
    (local $i i32) (local $a i32) (local $b i32) (local $c i32) (local $d i32)
    (local $e i32)
    (local.set $a (i32.const 1)) (local.set $b (i32.const 2))
    (local.set $c (i32.const 3)) (local.set $d (i32.const 4))
    (local.set $e (i32.const 5))
    (loop $l
      (local.set $a (i32.add (local.get $a)
        (call $mrw (i32.xor (local.get $b) (local.get $i)) (i64.const 77)
          (local.get $p))))
      (local.set $b (i32.add (local.get $b) (i32.mul (local.get $a)
        (i32.const 3))))
      (local.set $c (i32.xor (local.get $c) (i32.add (local.get $b)
        (local.get $d))))
      (local.set $d (i32.add (local.get $d)
        (i32.load (i32.add (local.get $p) (i32.const 8)))))
      (local.set $e (i32.add (local.get $e) (i32.xor (local.get $a)
        (local.get $d))))
      (i32.store (i32.add (local.get $p) (i32.const 8))
        (i32.add (local.get $e) (local.get $c)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (i32.add (i32.xor (local.get $a) (local.get $b))
             (i32.add (i32.xor (local.get $c) (local.get $d)) (local.get $e))))

  ;; Two different leaves from one base-pinned loop: each call resolves its
  ;; entry inline, which overwrites rsi, so Base must be reloaded for the
  ;; memory leaf and for the caller's own store.
  (func (export "twoleaf") (param $n i32) (param $p i32) (result i32)
    (local $i i32) (local $s i32)
    (loop $l
      (local.set $s (i32.add (local.get $s) (call $m0get (local.get $p))))
      (i32.store (local.get $p) (i32.add (local.get $s) (local.get $i)))
      (local.set $s (call $sel3 (local.get $s) (local.get $i) (local.get $n)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (i32.add (local.get $s) (i32.load (local.get $p))))

  (func (export "quadloop") (param $n i32) (param $p i32) (result i32)
    (local $s i32) (local $i i32)
    (loop $l
      (local.set $s (i32.add (local.get $s) (call $quad (i32.add (local.get $p)
        (i32.mul (local.get $i) (i32.const 4))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $s))

  ;; memory.grow between leaf calls: the leaf must see the new Base/size.
  (func (export "growloop") (param $n i32) (result i32)
    (local $s i32) (local $i i32) (local $top i32)
    (loop $l
      (local.set $top (i32.sub (i32.mul (memory.size) (i32.const 65536))
        (i32.const 8)))
      (local.set $s (i32.add (local.get $s)
        (call $mrw (local.get $i) (i64.const 5) (local.get $top))))
      (local.set $s (i32.add (local.get $s) (call $m0get (local.get $top))))
      (drop (memory.grow (i32.const 1)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (i32.add (local.get $s) (memory.size)))

  ;; A guard-page fault inside a leaf called from a loop.
  (func (export "trloop") (param $n i32) (param $p i32) (param $q i32)
    (result i32)
    (local $i i32)
    (loop $l
      (drop (call $two (i32.add (local.get $p) (i32.mul (local.get $i)
        (i32.const 4))) (local.get $q) (i32.add (local.get $i)
        (i32.const 100))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $i))

  ;; Recursion through a caller of memory leaves (post-order: an
  ;; exhausted descent writes nothing).
  (func $rec (export "rec") (param $d i32) (result i32)
    (local $r i32)
    (if (result i32) (i32.eqz (local.get $d))
      (then (i32.const 0))
      (else
        (local.set $r (call $rec (i32.sub (local.get $d) (i32.const 1))))
        (i32.add (call $mrw (i32.const 1) (i64.const 1) (i32.const 256))
                 (local.get $r)))))

  ;; Memory 1 only: the leaf's memory is the caller's pinned memory 1.
  (func (export "m1call") (param $p i32) (result i32)
    (i32.add (call $m1rd (local.get $p))
             (i32.load $m1 (i32.add (local.get $p) (i32.const 4)))))
  ;; Memory 0 in the caller, memory 1 in the leaf: the generic call.
  (func (export "mixmem") (param $p i32) (result i32)
    (i32.add (call $m1rd (local.get $p)) (i32.load (local.get $p))))
  (func (export "offloop") (param $n i32) (param $p i32) (result i32)
    (local $s i32) (local $i i32)
    (loop $l
      (local.set $s (i32.add (local.get $s)
        (call $off (i32.add (local.get $p) (local.get $i)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $s))

  (func (export "fill") (param $p i32) (param $n i32) (result i32)
    (local $k i32)
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $k) (local.get $n)))
      (i32.store8 (i32.add (local.get $p) (local.get $k))
        (i32.add (i32.mul (local.get $k) (i32.const 37)) (i32.const 0x81)))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $l)))
    (i32.const 0))
  (func (export "fill1") (param $p i32) (param $n i32) (result i32)
    (local $k i32)
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $k) (local.get $n)))
      (i32.store8 $m1 (i32.add (local.get $p) (local.get $k))
        (i32.add (i32.mul (local.get $k) (i32.const 29)) (i32.const 0x93)))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $l)))
    (i32.const 0))
)
'''

# (export, argument kinds, arguments). Kinds: 'i' = i32, 'I' = i64.
COMMANDS = [
    ('l3', 'iIi', (5, 0x1122334455667788, M32)),
    ('l3', 'iIi', (M32, M64, 0x7FFFFFFF)),
    ('l4', 'IiIi', (0x123456789, 0x80000000, 0x23456789A, 0xDEADBEEF)),
    ('l4', 'IiIi', (M64, 1, 1 << 63, 0x10000000)),
    ('ord4', 'iiii', (1, 2, 3, 4)),
    ('ord4', 'iiii', (4, 3, 2, 1)),
    ('sel3', 'iii', (10, 3, 0)),
    ('sel3', 'iii', (10, 3, 0x80000000)),
    ('sel4', 'iiii', (5, 6, 7, 7)),
    ('ident', 'iii', (1, 2, 3)),
    ('loop3', 'i', (1,)),
    ('loop3', 'i', (2,)),
    ('loop3', 'i', (37,)),
    ('loop4', 'i', (1,)),
    ('loop4', 'i', (3,)),
    ('loop4', 'i', (41,)),
    ('loopord', 'i', (1,)),
    ('loopord', 'i', (2,)),
    ('loopord', 'i', (19,)),
    ('teeargs', 'i', (1,)),
    ('teeargs', 'i', (9,)),
    ('loopsel3', 'i', (1,)),
    ('loopsel3', 'i', (40,)),
    ('wide', 'i', (1,)),
    ('wide', 'i', (5,)),
    ('loopsel', 'i', (1,)),
    ('loopsel', 'i', (2,)),
    ('loopsel', 'i', (33,)),
    ('fill', 'ii', (0, 96)),
    ('quad', 'i', (0,)),
    ('quad', 'i', (17,)),
    ('quadloop', 'ii', (9, 3)),
    ('quad', 'i', (65524,)),
    ('quad', 'i', (65525,)),
    ('ldall', 'i', (0,)),
    ('ldall', 'i', (3,)),
    ('ldall', 'i', (65,)),
    ('stall', 'iI', (128, 0xF1E2D3C4B5A69788)),
    ('peek', 'i', (128,)),
    ('peek', 'i', (136,)),
    ('peek', 'i', (144,)),
    ('ldall', 'i', (136,)),
    ('ldall', 'i', (146,)),
    ('mrw', 'iIi', (1, 0, 512)),
    ('loopmem', 'ii', (1, 520)),
    ('loopmem', 'ii', (1000, 528)),
    ('loopmem', 'ii', (7, 520)),
    ('peek', 'i', (520,)),
    ('loophosts', 'ii', (1, 600)),
    ('loophosts', 'ii', (29, 640)),
    ('peek', 'i', (640,)),
    ('loophosts2', 'ii', (1, 1024)),
    ('loophosts2', 'ii', (37, 1056)),
    ('peek', 'i', (1056,)),
    ('m0get', 'i', (1064,)),
    ('twoleaf', 'ii', (1, 1100)),
    ('twoleaf', 'ii', (23, 1104)),
    ('m0get', 'i', (1104,)),
    ('m0get', 'i', (648,)),
    ('offloop', 'ii', (8, 0)),
    ('offloop', 'ii', (3, 65528)),
    ('fill1', 'ii', (16, 16)),
    ('m1call', 'i', (16,)),
    ('m1call', 'i', (20,)),
    ('mixmem', 'i', (16,)),
    ('m1call', 'i', (65528,)),
    ('m1call', 'i', (65532,)),
    ('mixmem', 'i', (65533,)),
    # Guard-page faults: the first access, the second (the first store
    # stays visible), and mid-loop after earlier iterations' stores.
    ('two', 'iii', (65536, 700, 11)),
    ('m0get', 'i', (700,)),
    ('two', 'iii', (704, 65533, 12)),
    ('m0get', 'i', (704,)),
    ('m0get', 'i', (65532,)),
    ('trloop', 'iii', (4, 720, 740)),
    ('trloop', 'iii', (6, 800, 65534)),
    ('m0get', 'i', (800,)),
    ('m0get', 'i', (804,)),
    ('trloop', 'iii', (6, 65528, 880)),
    ('m0get', 'i', (65528,)),
    ('m0get', 'i', (65532,)),
    ('m0get', 'i', (880,)),
    ('mrw', 'iIi', (1, 1, 65529)),
    ('ldall', 'i', (65535,)),
    ('stall', 'iI', (65520, 0x0102030405060708)),
    ('peek', 'i', (65520,)),
    ('m0get', 'i', (65528,)),
    ('mrw', 'iIi', (1, 1, M32)),
    ('rec', 'i', (1,)),
    ('rec', 'i', (40,)),
    ('peek', 'i', (256,)),
    ('rec', 'i', (1000000,)),
    ('peek', 'i', (256,)),
    ('growloop', 'i', (2,)),
    ('m0get', 'i', (65536 * 3 - 8,)),
    ('growloop', 'i', (3,)),
    ('mrw', 'iIi', (2, 3, 65536 * 4 - 8)),
    ('peek', 'i', (65536 * 4 - 8,)),
    ('mrw', 'iIi', (2, 3, 65536 * 4 - 7)),
]


def const(kind, value):
    if kind == 'i':
        return '(i32.const %d)' % s32(value)
    return '(i64.const %d)' % s64(value)


def main():
    m = Machine()
    lines = [WAT.strip(), '']
    for name, kinds, args in COMMANDS:
        call = '(invoke "%s"%s)' % (name, ''.join(
            ' ' + const(k, a) for k, a in zip(kinds, args)))
        try:
            result = getattr(m, name)(*args)
        except Trap as trap:
            lines.append('(assert_trap %s "%s")' % (call, trap))
            continue
        except (Exhausted, RecursionError):
            lines.append('(assert_exhaustion %s "call stack exhausted")'
                         % call)
            continue
        kind = 'I' if name in ('l3', 'loop3', 'ldall', 'peek', 'loopmem',
                               'wide') \
            else 'i'
        lines.append('(assert_return %s %s)' % (call, const(kind, result)))
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'x64-leaf.wast')
    with open(out, 'w') as f:
        f.write('\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
