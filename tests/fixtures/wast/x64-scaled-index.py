"""Emit x64-scaled-index.wast beside this script: an adversarial .wast for
the x64 scaled pinned index (an `i32.shl` by 1..3 of a masked address folded
into the access's SIB scale, the shift elided). Every expected value comes
from the Python model below, not from any wasmlight tier.

The net probes the proof boundary: masks m with m * 2^k just below and
exactly at 2^32, masks with the top bit set, shift counts 0..4 and >= 32
(wasm masks them), addresses that must wrap at 2^32 under the i32 shift,
traps at the end of the memory and far past it, store and load widths
1..8, the address local read after the loop, before its redefinition, on
another path, and after the access in the same straight line.

Regenerate with `python3 tests/fixtures/wast/x64-scaled-index.py`; output
is deterministic, so a clean tree after a run means nothing drifted."""
import os

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


class Trap(Exception):
    pass


MEM = bytearray(PAGE)


def check(addr, size):
    if addr + size > PAGE:
        raise Trap()


def store(addr, size, value):
    check(addr, size)
    MEM[addr:addr + size] = (value & ((1 << (8 * size)) - 1)).to_bytes(
        size, 'little')


def load(addr, size, signed=False, bits=32):
    check(addr, size)
    v = int.from_bytes(MEM[addr:addr + size], 'little')
    if signed and v >> (8 * size - 1):
        v -= 1 << (8 * size)
    return v & ((1 << bits) - 1)


def addr(i, x, mask, count):
    return w32(w32(w32(i + x) & mask) << (count & 31))


# --- module text and models ------------------------------------------------

FUNCS = []
SCRIPT = []


def func(text):
    FUNCS.append(text)


def ret(name, args, result):
    """Run `result` (a thunk over the model); record assert_return or
    assert_trap. args are (type, value) pairs."""
    a = ' '.join('(%s.const %d)' % (t, s32(v) if t == 'i32' else s64(v))
                 for t, v in args)
    try:
        r = result()
    except Trap:
        SCRIPT.append('(assert_trap (invoke "%s" %s) '
                      '"out of bounds memory access")' % (name, a))
        return
    if r is None:
        SCRIPT.append('(assert_return (invoke "%s" %s))' % (name, a))
    else:
        t, v = r
        SCRIPT.append('(assert_return (invoke "%s" %s) (%s.const %d))' %
                      (name, a, t, s32(v) if t == 'i32' else s64(v)))


# fill: word j = (j * 0x01000193) xor seed, over the whole page. Unscaled
# shl (no mask), so never fused.
func('''(func (export "fill") (param $seed i32)
    (local $j i32)
    (loop $l
      (i32.store (i32.shl (local.get $j) (i32.const 2))
        (i32.xor (i32.mul (local.get $j) (i32.const 0x01000193))
                 (local.get $seed)))
      (local.set $j (i32.add (local.get $j) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $j) (i32.const 16384)))))''')


def fill(seed):
    for j in range(PAGE // 4):
        store(j * 4, 4, w32(j * 0x01000193) ^ seed)


# hash: FNV-style over cnt words from byte address p (p steps by 4).
func('''(func (export "hash") (param $p i32) (param $cnt i32) (result i32)
    (local $acc i32)
    (local.set $acc (i32.const 0x811c9dc5))
    (loop $l
      (local.set $acc (i32.mul (i32.xor (local.get $acc)
        (i32.load (local.get $p))) (i32.const 0x01000193)))
      (local.set $p (i32.add (local.get $p) (i32.const 4)))
      (local.set $cnt (i32.sub (local.get $cnt) (i32.const 1)))
      (br_if $l (local.get $cnt)))
    (local.get $acc))''')


def hash_(p, cnt):
    acc = 0x811c9dc5
    while True:
        acc = w32((acc ^ load(p, 4)) * 0x01000193)
        p = w32(p + 4)
        cnt = w32(cnt - 1)
        if cnt == 0:
            break
    return ('i32', acc)


STORES = {
    'i32.store8': 1, 'i32.store16': 2, 'i32.store': 4, 'i64.store': 8,
}
LOADS = {
    'i32.load8_s': (1, True, 32), 'i32.load8_u': (1, False, 32),
    'i32.load16_s': (2, True, 32), 'i32.load16_u': (2, False, 32),
    'i32.load': (4, False, 32), 'i64.load': (8, False, 64),
}


def store_func(name, op, mask, count):
    """do { a = ((i + x) & mask) << count; op [a] <- v; v += step } while
    ++i < n. $a is dead after the access."""
    wide = op.startswith('i64')
    t = 'i64' if wide else 'i32'
    step = '0x9E3779B97F4A7C15' if wide else '0x9E3779B1'
    func('''(func (export "%s") (param $n i32) (param $x i32)
    (local $i i32) (local $a i32) (local $v %s)
    (local.set $v (%s.const 0x12345))
    (loop $l
      (local.set $a (i32.shl
        (i32.and (i32.add (local.get $i) (local.get $x)) (i32.const %d))
        (i32.const %d)))
      (%s (local.get $a) (local.get $v))
      (local.set $v (%s.add (local.get $v) (%s.const %s)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n)))))''' % (
        name, t, t, s32(mask), count, op, t, t, step))
    size = STORES[op]
    stepv = 0x9E3779B97F4A7C15 if wide else 0x9E3779B1

    def model(n, x):
        def run():
            i, v = 0, 0x12345
            while True:
                store(addr(i, x, mask, count), size, v)
                v = w64(v + stepv) if wide else w32(v + stepv)
                i = w32(i + 1)
                if not i < n:
                    break
            return None
        return run
    return model


def load_func(name, op, mask, count):
    """acc += op [((i + x) & mask) << count] for i < n; $a dead after."""
    size, signed, bits = LOADS[op]
    wide = bits == 64
    t = 'i64' if wide else 'i32'
    func('''(func (export "%s") (param $n i32) (param $x i32) (result %s)
    (local $i i32) (local $a i32) (local $acc %s)
    (loop $l
      (local.set $a (i32.shl
        (i32.and (i32.add (local.get $i) (local.get $x)) (i32.const %d))
        (i32.const %d)))
      (local.set $acc (%s.add (local.get $acc) (%s (local.get $a))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $acc))''' % (name, t, t, s32(mask), count, t, op))

    def model(n, x):
        def run():
            i, acc = 0, 0
            while True:
                v = load(addr(i, x, mask, count), size, signed, bits)
                acc = w64(acc + v) if wide else w32(acc + v)
                i = w32(i + 1)
                if not i < n:
                    break
            return (t, acc)
        return run
    return model


def call(name, model, n, x):
    ret(name, [('i32', n), ('i32', x)], model(n, x))


def h(p, cnt):
    ret('hash', [('i32', p), ('i32', cnt)], lambda: hash_(p, cnt))


def f(seed):
    ret('fill', [('i32', seed)], lambda: fill(seed))


# --- scaled stores at and across the mask boundary --------------------------
# Fused: m * 2^k < 2^32 (m = 2^(32-k) - 1 and small masks). Not fused:
# m * 2^k >= 2^32 (m = 2^(32-k) exactly, all-ones, top-bit masks), where the
# i32 shift must wrap.
f(0x5a5a5a5a)
st = {}
for name, op, mask, count in [
        ('st1_7fffffff', 'i32.store16', 0x7fffffff, 1),
        ('st1_80000000', 'i32.store16', 0x80000000, 1),
        ('st1_ffffffff', 'i32.store16', 0xffffffff, 1),
        ('st1_80000fff', 'i32.store16', 0x80000fff, 1),
        ('st2_3fffffff', 'i32.store', 0x3fffffff, 2),
        ('st2_40000000', 'i32.store', 0x40000000, 2),
        ('st2_40000fff', 'i32.store', 0x40000fff, 2),
        ('st2_3fff', 'i32.store', 0x3fff, 2),
        ('st3_1fffffff', 'i64.store', 0x1fffffff, 3),
        ('st3_20000000', 'i64.store', 0x20000000, 3),
        ('st3_1fff', 'i64.store', 0x1fff, 3),
        ('st2_b_3fff', 'i32.store8', 0x3fff, 2),
        ('st3_w_1fff', 'i32.store', 0x1fff, 3),
        ('st1_b_7fff', 'i32.store8', 0x7fff, 1)]:
    st[name] = store_func(name, op, mask, count)

# In range.
call('st2_3fffffff', st['st2_3fffffff'], 40, 0x3ff0)
h(0xffc0, 16)
call('st2_3fff', st['st2_3fff'], 100, 0x3fd0)
h(0xff40, 48)
h(0, 20)
call('st1_7fffffff', st['st1_7fffffff'], 30, 0x7ff0)
h(0xffe0, 8)
call('st3_1fffffff', st['st3_1fffffff'], 12, 0x1ffa)
h(0xffd0, 12)
call('st3_1fff', st['st3_1fff'], 20, 0x1ff8)
h(0xffc0, 16)
h(0, 24)
call('st2_b_3fff', st['st2_b_3fff'], 64, 0x3fe0)
h(0xff80, 32)
call('st3_w_1fff', st['st3_w_1fff'], 16, 0x1ff4)
h(0xffa0, 24)
call('st1_b_7fff', st['st1_b_7fff'], 50, 0x7fe8)
h(0xffd0, 12)
h(0, 8)
# Fused masks with a huge masked index: far past the memory, inside the
# reservation; the trap is the interpreter's.
call('st2_3fffffff', st['st2_3fffffff'], 4, 0x3ffffff0)
call('st1_7fffffff', st['st1_7fffffff'], 3, 0x7ffffff0)
call('st3_1fffffff', st['st3_1fffffff'], 2, 0x1ffffff0)
call('st2_3fffffff', st['st2_3fffffff'], 3, 0x00010000)
h(0, 16)
# Not fused: the shifted index wraps at 2^32 to a low, valid address.
call('st2_40000000', st['st2_40000000'], 8, 0x40000000)
h(0, 4)
call('st2_40000fff', st['st2_40000fff'], 20, 0x40000ff0)
h(0x3fc0, 16)
h(0, 8)
call('st1_80000000', st['st1_80000000'], 5, 0x80000000)
h(0, 2)
call('st1_ffffffff', st['st1_ffffffff'], 12, 0x80000002)
h(0, 8)
call('st1_80000fff', st['st1_80000fff'], 9, 0x80000ff8)
h(0x1fe0, 16)
h(0, 4)
call('st3_20000000', st['st3_20000000'], 3, 0x20000000)
h(0, 2)
# Traps at the end of the memory: the first out-of-range iteration traps
# and every earlier store stays.
call('st2_3fff', st['st2_3fff'], 40, 0x3ff8)
h(0xffe0, 8)
h(0, 8)
call('st3_1fff', st['st3_1fff'], 10, 0x1ffc)
h(0xffe0, 8)
call('st1_7fffffff', st['st1_7fffffff'], 10, 0x7ffc)
h(0xfff0, 4)
call('st2_b_3fff', st['st2_b_3fff'], 10, 0x3ffc)
h(0xfff0, 4)

# --- scaled loads -----------------------------------------------------------
f(0x13579bdf)
ld = {}
for name, op, mask, count in [
        ('ld2_3fff', 'i32.load', 0x3fff, 2),
        ('ld2_3fffffff', 'i32.load', 0x3fffffff, 2),
        ('ld2_40000000', 'i32.load', 0x40000000, 2),
        ('ld1_s16_7fff', 'i32.load16_s', 0x7fff, 1),
        ('ld1_u16_7fffffff', 'i32.load16_u', 0x7fffffff, 1),
        ('ld1_u16_ffffffff', 'i32.load16_u', 0xffffffff, 1),
        ('ld2_s8_3fff', 'i32.load8_s', 0x3fff, 2),
        ('ld3_u8_1fff', 'i32.load8_u', 0x1fff, 3),
        ('ld3_64_1fff', 'i64.load', 0x1fff, 3),
        ('ld3_64_1fffffff', 'i64.load', 0x1fffffff, 3),
        ('ld3_64_20000001', 'i64.load', 0x20000001, 3)]:
    ld[name] = load_func(name, op, mask, count)

call('ld2_3fff', ld['ld2_3fff'], 1000, 7)
call('ld2_3fff', ld['ld2_3fff'], 40000, 0x3000)
call('ld2_3fffffff', ld['ld2_3fffffff'], 300, 0x3f00)
call('ld2_3fffffff', ld['ld2_3fffffff'], 300, 0x3ff00)
call('ld2_3fffffff', ld['ld2_3fffffff'], 2, 0x3fffffff)
call('ld2_40000000', ld['ld2_40000000'], 50, 0x40000000)
call('ld1_s16_7fff', ld['ld1_s16_7fff'], 70000, 0x1234)
call('ld1_u16_7fffffff', ld['ld1_u16_7fffffff'], 500, 0x7f00)
call('ld1_u16_7fffffff', ld['ld1_u16_7fffffff'], 500, 0x7ff00)
call('ld1_u16_ffffffff', ld['ld1_u16_ffffffff'], 20, 0x7ffffff8)
call('ld1_u16_ffffffff', ld['ld1_u16_ffffffff'], 20, 0x80000000)
call('ld2_s8_3fff', ld['ld2_s8_3fff'], 20000, 3)
call('ld3_u8_1fff', ld['ld3_u8_1fff'], 9000, 0x1f00)
call('ld3_64_1fff', ld['ld3_64_1fff'], 9000, 0x100)
call('ld3_64_1fffffff', ld['ld3_64_1fffffff'], 100, 0x1fc0)
call('ld3_64_1fffffff', ld['ld3_64_1fffffff'], 100, 0x1ff0)
call('ld3_64_20000001', ld['ld3_64_20000001'], 40, 0x20000000)
call('ld3_64_20000001', ld['ld3_64_20000001'], 40, 0x3fffffe0)

# --- shift counts: 0 and 4 never fuse; >= 32 is masked to 1..3 --------------
f(0x2468ace0)
sc = {}
for count in (0, 1, 3, 4, 32, 33, 34, 35, 36, 66, 99):
    name = 'ldc%d' % count
    sc[count] = load_func(name, 'i32.load8_u', 0xfff, count)
    call(name, sc[count], 5000, 11)
sc2 = store_func('stc34', 'i32.store', 0x3fff, 34)
call('stc34', sc2, 20, 0x3ff0)
h(0xffc0, 16)
sc3 = store_func('stc36', 'i32.store', 0x3fff, 36)
call('stc36', sc3, 5000, 0)

# --- the address local stays observable -------------------------------------
f(0x0badf00d)

# $a is read after the loop: never fused, and the result is the last address.
func('''(func (export "after") (param $n i32) (result i32)
    (local $i i32) (local $a i32)
    (loop $l
      (local.set $a (i32.shl (i32.and (local.get $i) (i32.const 0x3fff))
                             (i32.const 2)))
      (i32.store (local.get $a) (local.get $i))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (i32.add (local.get $a) (i32.load (local.get $a))))''')


def after(n):
    def run():
        i = 0
        while True:
            a = addr(i, 0, 0x3fff, 2)
            store(a, 4, i)
            i = w32(i + 1)
            if not i < n:
                break
        return ('i32', w32(a + load(a, 4)))
    return run


ret('after', [('i32', 37)], after(37))
ret('after', [('i32', 16390)], after(16390))

# $a is read at the top of the next iteration, before its redefinition
# (loop-carried), and on only one arm of an if.
func('''(func (export "carried") (param $n i32) (result i32)
    (local $i i32) (local $a i32) (local $acc i32)
    (local.set $a (i32.const 1000))
    (loop $l
      (if (i32.and (local.get $i) (i32.const 1))
        (then (local.set $acc (i32.add (local.get $acc) (local.get $a)))))
      (local.set $a (i32.shl (i32.and (local.get $i) (i32.const 0x3fff))
                             (i32.const 2)))
      (i32.store (local.get $a) (i32.xor (local.get $i) (local.get $acc)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $acc))''')


def carried(n):
    def run():
        i, a, acc = 0, 1000, 0
        while True:
            if i & 1:
                acc = w32(acc + a)
            a = addr(i, 0, 0x3fff, 2)
            store(a, 4, i ^ acc)
            i = w32(i + 1)
            if not i < n:
                break
        return ('i32', acc)
    return run


ret('carried', [('i32', 1)], carried(1))
ret('carried', [('i32', 999)], carried(999))
h(0, 64)

# $a is read after the access in the same straight line, and again on one
# arm of an if after the access.
func('''(func (export "sameline") (param $n i32) (result i32)
    (local $i i32) (local $a i32) (local $acc i32)
    (loop $l
      (local.set $a (i32.shl (i32.and (local.get $i) (i32.const 0x1fff))
                             (i32.const 3)))
      (i32.store (local.get $a) (local.get $acc))
      (local.set $acc (i32.add (local.get $acc) (local.get $a)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $acc))''')


def sameline(n):
    def run():
        i, acc = 0, 0
        while True:
            a = addr(i, 0, 0x1fff, 3)
            store(a, 4, acc)
            acc = w32(acc + a)
            i = w32(i + 1)
            if not i < n:
                break
        return ('i32', acc)
    return run


ret('sameline', [('i32', 3000)], sameline(3000))
h(0, 32)

func('''(func (export "onearm") (param $n i32) (result i32)
    (local $i i32) (local $a i32) (local $acc i32)
    (loop $l
      (local.set $a (i32.shl (i32.and (local.get $i) (i32.const 0x7fff))
                             (i32.const 1)))
      (i32.store16 (local.get $a) (local.get $i))
      (if (i32.eqz (i32.and (local.get $i) (i32.const 3)))
        (then (local.set $acc (i32.xor (local.get $acc) (local.get $a))))
        (else (local.set $acc (i32.add (local.get $acc) (i32.const 1)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $acc))''')


def onearm(n):
    def run():
        i, acc = 0, 0
        while True:
            a = addr(i, 0, 0x7fff, 1)
            store(a, 2, i)
            if (i & 3) == 0:
                acc ^= a
            else:
                acc = w32(acc + 1)
            i = w32(i + 1)
            if not i < n:
                break
        return ('i32', acc)
    return run


ret('onearm', [('i32', 5000)], onearm(5000))
h(0, 32)

# $a is redefined before every later read: the fused access may leave it
# unwritten. The post-loop read sees the constant.
func('''(func (export "redef") (param $n i32) (result i32)
    (local $i i32) (local $a i32)
    (loop $l
      (local.set $a (i32.shl (i32.and (local.get $i) (i32.const 0x3fff))
                             (i32.const 2)))
      (i32.store (local.get $a) (local.get $i))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.set $a (i32.const 12))
    (i32.add (local.get $a) (i32.load (local.get $a))))''')


def redef(n):
    def run():
        i = 0
        while True:
            store(addr(i, 0, 0x3fff, 2), 4, i)
            i = w32(i + 1)
            if not i < n:
                break
        return ('i32', w32(12 + load(12, 4)))
    return run


ret('redef', [('i32', 2)], redef(2))
ret('redef', [('i32', 16389)], redef(16389))

# One address local, two accesses (store, then a narrower load that is not
# forwarded): the second read keeps $a live past the first access.
func('''(func (export "twice") (param $n i32) (result i32)
    (local $i i32) (local $a i32) (local $acc i32)
    (loop $l
      (local.set $a (i32.shl (i32.and (local.get $i) (i32.const 0x3fff))
                             (i32.const 2)))
      (i32.store (local.get $a) (i32.mul (local.get $i) (i32.const 0x01010101)))
      (local.set $acc (i32.add (local.get $acc)
        (i32.load8_u (local.get $a))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $acc))''')


def twice(n):
    def run():
        i, acc = 0, 0
        while True:
            a = addr(i, 0, 0x3fff, 2)
            store(a, 4, w32(i * 0x01010101))
            acc = w32(acc + load(a, 1))
            i = w32(i + 1)
            if not i < n:
                break
        return ('i32', acc)
    return run


ret('twice', [('i32', 20000)], twice(20000))

# The benchmark memory shape: store then the forwarded load of the same
# address.
func('''(func (export "fwd") (param $n i32) (result i32)
    (local $i i32) (local $acc i32) (local $address i32)
    (loop $l
      (local.set $address (i32.shl (i32.and (local.get $i) (i32.const 16383))
                                   (i32.const 2)))
      (i32.store (local.get $address) (local.get $i))
      (local.set $acc (i32.add (local.get $acc)
        (i32.load (local.get $address))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $acc))''')


def fwd(n):
    def run():
        i, acc = 0, 0
        while True:
            a = addr(i, 0, 16383, 2)
            store(a, 4, i)
            acc = w32(acc + load(a, 4))
            i = w32(i + 1)
            if not i < n:
                break
        return ('i32', acc)
    return run


ret('fwd', [('i32', 70000)], fwd(70000))
h(0, 64)

# The stored value is the address itself: the value read keeps it live.
func('''(func (export "selfval") (param $n i32) (result i32)
    (local $i i32) (local $a i32)
    (loop $l
      (local.set $a (i32.shl (i32.and (local.get $i) (i32.const 0x3fff))
                             (i32.const 2)))
      (i32.store (local.get $a) (local.get $a))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (i32.const 0))''')


def selfval(n):
    def run():
        i = 0
        while True:
            a = addr(i, 0, 0x3fff, 2)
            store(a, 4, a)
            i = w32(i + 1)
            if not i < n:
                break
        return ('i32', 0)
    return run


ret('selfval', [('i32', 100)], selfval(100))
h(0, 100)

# The masked operand is itself the stored value, and a masked byte loaded
# from memory is the index of another access.
func('''(func (export "chain") (param $n i32) (result i32)
    (local $i i32) (local $m i32) (local $acc i32)
    (loop $l
      (local.set $m (i32.and (i32.load8_s (local.get $i)) (i32.const 0xff)))
      (i32.store (i32.shl (local.get $m) (i32.const 2)) (local.get $m))
      (local.set $acc (i32.add (local.get $acc) (i32.load
        (i32.shl (i32.and (i32.add (local.get $i) (local.get $acc))
                          (i32.const 0x3fff)) (i32.const 2)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (local.get $acc))''')


def chain(n):
    def run():
        i, acc = 0, 0
        while True:
            m = load(i, 1, True) & 0xff
            store(w32(m << 2), 4, m)
            acc = w32(acc + load(addr(i, acc, 0x3fff, 2), 4))
            i = w32(i + 1)
            if not i < n:
                break
        return ('i32', acc)
    return run


ret('chain', [('i32', 3000)], chain(3000))
h(0, 256)

# The stored value is computed between the shift and the store, with
# enough temporaries to evict the masked index from its host. `between`
# reads its address local twice; `between1` has no local.
func('''(func (export "between") (param $n i32) (param $x i32) (result i32)
    (local $i i32) (local $a i32)
    (loop $l
      (local.set $a (i32.shl (i32.and (i32.add (local.get $i) (local.get $x))
                                      (i32.const 0x1fff)) (i32.const 3)))
      (i64.store (local.get $a)
        (i64.add (i64.mul (i64.xor (i64.const 0x1234567890)
                                   (i64.const 0x55))
                          (i64.const 0x45))
                 (i64.const 7)))
      (i32.store (local.get $a)
        (i32.add (i32.mul (i32.xor (local.get $i) (local.get $x))
                          (i32.const 0x45))
                 (i32.mul (i32.add (local.get $i) (i32.const 7))
                          (i32.sub (local.get $x) (local.get $i)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (i32.const 1))''')


def between(n, x):
    def run():
        i = 0
        while True:
            a = addr(i, x, 0x1fff, 3)
            store(a, 8, w64((0x1234567890 ^ 0x55) * 0x45 + 7))
            store(a, 4, w32(w32((i ^ x) * 0x45) +
                            w32(w32(i + 7) * w32(x - i))))
            i = w32(i + 1)
            if not i < n:
                break
        return ('i32', 1)
    return run


func('''(func (export "between1") (param $n i32) (param $x i32) (result i32)
    (local $i i32)
    (loop $l
      (i32.store (i32.shl (i32.and (i32.add (local.get $i) (local.get $x))
                                   (i32.const 0x3fff)) (i32.const 2))
        (i32.add (i32.mul (i32.xor (local.get $i) (local.get $x))
                          (i32.const 0x45))
                 (i32.mul (i32.add (local.get $i) (i32.const 7))
                          (i32.sub (local.get $x) (local.get $i)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))
    (i32.const 1))''')


def between1(n, x):
    def run():
        i = 0
        while True:
            a = addr(i, x, 0x3fff, 2)
            store(a, 4, w32(w32((i ^ x) * 0x45) +
                            w32(w32(i + 7) * w32(x - i))))
            i = w32(i + 1)
            if not i < n:
                break
        return ('i32', 1)
    return run


ret('between', [('i32', 3000), ('i32', 5)], between(3000, 5))
h(0, 256)
h(0xff00, 64)
ret('between', [('i32', 20), ('i32', 0x1ff0)], between(20, 0x1ff0))
h(0xff80, 32)
ret('between1', [('i32', 20000), ('i32', 9)], between1(20000, 9))
h(0, 256)
h(0xfe00, 128)
ret('between1', [('i32', 20), ('i32', 0x3ff8)], between1(20, 0x3ff8))
h(0xffe0, 8)

# A constant address operand, not a mask: the i32 shift wraps
# (0x40000001 << 2 = 4).
func('''(func (export "wrapconst") (result i32)
    (i32.store (i32.shl (i32.const 0x40000001) (i32.const 2))
               (i32.const 0x11223344))
    (i32.load (i32.const 4)))''')
ret('wrapconst', [], lambda: (store(4, 4, 0x11223344), ('i32', load(4, 4)))[1])

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   'x64-scaled-index.wast')
with open(OUT, 'w') as fh:
    fh.write(';; Generated by x64-scaled-index.py; do not edit.\n')
    fh.write('(module\n  (memory 1)\n')
    for text in FUNCS:
        fh.write('  ' + text + '\n\n')
    fh.write(')\n\n')
    for line in SCRIPT:
        fh.write(line + '\n')
print('%d functions, %d assertions' % (len(FUNCS), len(SCRIPT)))
