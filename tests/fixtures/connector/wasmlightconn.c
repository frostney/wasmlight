/* Connector fixture library (issue #146): a small C ABI the connector
   suites load application-locally and call through `.wlc` bindings.
   Built by the test suites with the host C compiler; never committed as
   a binary. */
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

int32_t conn_answer(void) { return 42; }

int32_t conn_add(int32_t a, int32_t b) { return a + b; }

int64_t conn_mul64(int64_t a, int64_t b) { return a * b; }

double conn_scale(double x, float f) { return x * (double)f; }

int8_t conn_neg8(int8_t v) { return (int8_t)-v; }

uint16_t conn_join16(uint8_t lo, uint8_t hi)
{
    return (uint16_t)(lo | ((uint16_t)hi << 8));
}

bool conn_is_negative(int16_t v) { return v < 0; }

bool conn_not(bool b) { return !b; }

int32_t conn_sum9(int32_t a, int32_t b, int32_t c, int32_t d, int32_t e,
    int32_t f, int32_t g, int32_t h, int32_t i)
{
    return a + b + c + d + e + f + g + h + i;
}

static int32_t counter;

void conn_bump(int32_t by) { counter += by; }

int32_t conn_counter(void) { return counter; }

/* --- buffers: copy-in, copy-out, inout, and a scoped borrow ------------- */

int32_t conn_sum_bytes(const uint8_t *buf, int32_t n)
{
    int32_t sum = 0;
    for (int32_t i = 0; i < n; i++)
        sum += buf[i];
    return sum;
}

void conn_fill(uint8_t *buf, int32_t n, uint8_t v)
{
    for (int32_t i = 0; i < n; i++)
        buf[i] = (uint8_t)(v + i);
}

void conn_reverse4(int32_t *vals)
{
    int32_t t = vals[0];
    vals[0] = vals[3];
    vals[3] = t;
    t = vals[1];
    vals[1] = vals[2];
    vals[2] = t;
}

int32_t conn_scale_in_place(int16_t *vals, uint32_t n, int16_t k)
{
    int32_t sum = 0;
    for (uint32_t i = 0; i < n; i++) {
        vals[i] = (int16_t)(vals[i] * k);
        sum += vals[i];
    }
    return sum;
}

/* --- opaque handles ----------------------------------------------------- */

typedef struct {
    int32_t value;
} conn_counter_t;

conn_counter_t *conn_counter_new(int32_t start)
{
    static conn_counter_t pool[16];
    static int32_t used;
    if (start < 0 || used >= 16)
        return NULL;
    pool[used].value = start;
    return &pool[used++];
}

int32_t conn_counter_add(conn_counter_t *c, int32_t by)
{
    if (c == NULL)
        return -1;
    c->value += by;
    return c->value;
}

/* --- callbacks ---------------------------------------------------------- */

typedef int32_t (*conn_map_fn)(int32_t);
typedef void (*conn_notify_fn)(int32_t);
typedef void (*conn_void_fn)(void);
typedef int32_t (*conn_get_fn)(void);

int32_t conn_apply(conn_map_fn f, int32_t x) { return f(x) + 1; }

int32_t conn_apply_twice(conn_map_fn f, int32_t x) { return f(f(x)); }

int32_t conn_call_void(conn_void_fn f)
{
    f();
    return 7;
}

int32_t conn_call_get(conn_get_fn f) { return f() * 2; }

static conn_notify_fn saved_notify;

void conn_register(conn_notify_fn f) { saved_notify = f; }

void conn_fire(int32_t v)
{
    if (saved_notify != NULL)
        saved_notify(v);
}

/* A borrow and a callback in one call: the borrow is still live while the
   callback runs. */
int32_t conn_borrow_and_call(uint8_t *buf, int32_t n, conn_map_fn f)
{
    return buf[0] + n + f(1);
}


struct conn_post_args {
    conn_notify_fn f;
    int32_t v;
};

static void *conn_post_worker(void *arg)
{
    struct conn_post_args *a = (struct conn_post_args *)arg;
    a->f(a->v);
    return NULL;
}

/* Notify from a thread this library creates, then join it: a [Queued]
   delegate is the only kind that may be called here. */
void conn_post(conn_notify_fn f, int32_t v)
{
    pthread_t t;
    struct conn_post_args a;
    a.f = f;
    a.v = v;
    if (pthread_create(&t, NULL, conn_post_worker, &a) == 0)
        pthread_join(t, NULL);
}
