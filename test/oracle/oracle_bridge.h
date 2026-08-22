#ifndef ZMATH_TESTING_ORACLE_BRIDGE_H
#define ZMATH_TESTING_ORACLE_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Stable ABI values. Q is reserved and every bridge entry point rejects it. */
enum zmath_testing_oracle_format {
    ZMATH_TESTING_ORACLE_FORMAT_H = 1,
    ZMATH_TESTING_ORACLE_FORMAT_F = 2,
    ZMATH_TESTING_ORACLE_FORMAT_D = 3,
    ZMATH_TESTING_ORACLE_FORMAT_Q = 4,
};

enum zmath_testing_oracle_status {
    ZMATH_TESTING_ORACLE_OK = 0,
    ZMATH_TESTING_ORACLE_UNSUPPORTED = 1,
    ZMATH_TESTING_ORACLE_ERROR = 2,
    ZMATH_TESTING_ORACLE_UNCERTAIN = 3,
};

enum zmath_testing_oracle_class {
    ZMATH_TESTING_ORACLE_CLASS_NORMAL = 0,
    ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL = 1,
    ZMATH_TESTING_ORACLE_CLASS_ZERO = 2,
    ZMATH_TESTING_ORACLE_CLASS_INFINITY = 3,
    ZMATH_TESTING_ORACLE_CLASS_QNAN = 4,
};

/*
 * Oracle-only MPFR reference ABI.
 *
 * op is a NUL-terminated operation name. This bridge supports the unary names
 * "exp", "log", and "sin". arity must be one. Rounding is fixed to
 * round-to-nearest, ties-to-even, at the manifest-pinned 512-bit MPFR
 * precision. There is deliberately no ambient or caller-selected rounding
 * mode.
 *
 * Each input_bits element is an exact IEEE 754 interchange bit pattern stored
 * in the low bits of uint64_t: binary16 for H (format 1), binary32 for F
 * (format 2), or binary64 for D (format 3). Unused high bits for H and F must
 * be zero. The bridge decodes sign, exponent, and significand fields directly;
 * it never converts through a host float or double. Q (format 4) is reserved
 * and rejected. Every other format, including bfloat16, is unsupported.
 * The quiet masks are H=0x0200, F=0x00400000, and
 * D=0x0008000000000000. Exact special cases are exp(+-0)=+1,
 * exp(+inf)=+inf, exp(-inf)=+0; log(+-0)=-inf, log(+1)=+0,
 * log(+inf)=+inf, and log(negative non-NaN)=+qNaN; sin(+0)=+0,
 * sin(-0)=-0, and sin(+-inf)=+qNaN. These rules precede MPFR evaluation.
 * On OK, output_bits contains the exact target-format bit pattern in the same
 * low-bit layout and output_class is NORMAL, SUBNORMAL, ZERO, INFINITY, or
 * QNAN. Normal values, subnormals, infinities, and signed zeros use their
 * exact IEEE fields. A NaN input is returned before MPFR evaluation: preserve
 * its sign and payload, and set the target quiet bit. Invalid non-NaN inputs
 * return the positive canonical quiet encodings 0x7e00, 0x7fc00000, and
 * 0x7ff8000000000000 for H, F, and D. The bridge writes neither output on
 * UNSUPPORTED, ERROR, or UNCERTAIN.
 */
int zmath_testing_mpfr_reference(
    const char *op,
    unsigned format,
    const uint64_t *input_bits,
    size_t arity,
    uint64_t *output_bits,
    unsigned *output_class
);

/*
 * Oracle-only Arb rounding-proof ABI.
 *
 * Inputs and candidate_bits use the exact H/F/D layouts specified above.
 * The operation set, arity, fixed nearest-even rounding, reserved Q behavior,
 * and unsupported bfloat16 behavior are identical to the MPFR entry point.
 * Arb evaluates at the manifest-pinned 512-bit precision.
 *
 * OK means the complete Arb enclosure lies in one target-format rounding cell
 * and that cell's exact bit pattern equals candidate_bits. Checking that the
 * enclosure merely contains a point is not proof. A non-finite enclosure, an
 * enclosure that touches or crosses a rounding boundary, or disagreement with
 * candidate_bits returns UNCERTAIN. The bridge never guesses and writes
 * output_class only on OK. Malformed arguments return ERROR; unsupported
 * operation or format codes return UNSUPPORTED.
 */
int zmath_testing_arb_prove_rounding(
    const char *op,
    unsigned format,
    const uint64_t *input_bits,
    size_t arity,
    uint64_t candidate_bits,
    unsigned *output_class
);

#ifdef __cplusplus
}
#endif

#endif
