#include <stdint.h>

int32_t add_i32(int32_t a, int32_t b) { return a + b; }
int64_t add_i64(int64_t a, int64_t b) { return a + b; }
double add_f64(double a, double b) { return a + b; }

int32_t sum9(int32_t a, int32_t b, int32_t c, int32_t d, int32_t e,
    int32_t f, int32_t g, int32_t h, int32_t i)
{
    return a + b + c + d + e + f + g + h + i;
}

typedef struct {
    int32_t a;
    int32_t b;
} pair_i32;

pair_i32 add_pair(pair_i32 x, pair_i32 y)
{
    pair_i32 r;
    r.a = x.a + y.a;
    r.b = x.b + y.b;
    return r;
}

typedef struct {
    float a;
    float b;
} pair_f32;

pair_f32 add_hfa(pair_f32 x, pair_f32 y)
{
    pair_f32 r;
    r.a = x.a + y.a;
    r.b = x.b + y.b;
    return r;
}

int32_t load_ptr(const int32_t *p) { return *p; }

typedef struct {
    int64_t a;
    int64_t b;
    int64_t c;
} big24;

int64_t sum_big(big24 s) { return s.a + s.b + s.c; }
