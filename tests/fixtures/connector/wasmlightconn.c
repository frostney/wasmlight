/* Connector fixture library (issue #146): a small C ABI the connector
   suites load application-locally and call through `.wlc` bindings.
   Built by the test suites with the host C compiler; never committed as
   a binary. */
#include <stdbool.h>
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
