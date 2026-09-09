#include "oracle_evaluators.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <mpfr.h>

#include <flint/arb.h>
#include <flint/arb_hypgeom.h>
#include <flint/fmpq.h>
#include <flint/fmpz.h>

#define ZMATH_ORACLE_PRECISION 512
#define ZMATH_ORACLE_BOUNDARY_PRECISION 1024

enum zmath_transcendental_kind {
    ZMATH_TR_ACOS, ZMATH_TR_ACOSH, ZMATH_TR_ACOSPI,
    ZMATH_TR_ASIN, ZMATH_TR_ASINH, ZMATH_TR_ASINPI,
    ZMATH_TR_ATAN, ZMATH_TR_ATAN2, ZMATH_TR_ATAN2PI,
    ZMATH_TR_ATANH, ZMATH_TR_ATANPI, ZMATH_TR_COMPOUNDN,
    ZMATH_TR_COS, ZMATH_TR_COSH, ZMATH_TR_COSPI,
    ZMATH_TR_ERF, ZMATH_TR_ERFC, ZMATH_TR_EXP,
    ZMATH_TR_EXP10, ZMATH_TR_EXP10M1, ZMATH_TR_EXP2,
    ZMATH_TR_EXP2M1, ZMATH_TR_EXPM1, ZMATH_TR_LGAMMA,
    ZMATH_TR_LOG, ZMATH_TR_LOG10, ZMATH_TR_LOG10P1,
    ZMATH_TR_LOG1P, ZMATH_TR_LOG2, ZMATH_TR_LOG2P1,
    ZMATH_TR_LOGP1, ZMATH_TR_POW, ZMATH_TR_POWN,
    ZMATH_TR_POWR, ZMATH_TR_ROOTN, ZMATH_TR_SIN,
    ZMATH_TR_SINH, ZMATH_TR_SINPI, ZMATH_TR_TAN,
    ZMATH_TR_TANH, ZMATH_TR_TANPI, ZMATH_TR_TGAMMA,
};

typedef struct zmath_transcendental_route {
    const char *name;
    enum zmath_transcendental_kind kind;
} zmath_transcendental_route;

static const zmath_transcendental_route zmath_transcendental_routes[] = {
    {"acos", ZMATH_TR_ACOS}, {"acosh", ZMATH_TR_ACOSH},
    {"acospi", ZMATH_TR_ACOSPI}, {"asin", ZMATH_TR_ASIN},
    {"asinh", ZMATH_TR_ASINH}, {"asinpi", ZMATH_TR_ASINPI},
    {"atan", ZMATH_TR_ATAN}, {"atan2", ZMATH_TR_ATAN2},
    {"atan2pi", ZMATH_TR_ATAN2PI}, {"atanh", ZMATH_TR_ATANH},
    {"atanpi", ZMATH_TR_ATANPI}, {"compoundn", ZMATH_TR_COMPOUNDN},
    {"cos", ZMATH_TR_COS}, {"cosh", ZMATH_TR_COSH},
    {"cospi", ZMATH_TR_COSPI}, {"erf", ZMATH_TR_ERF},
    {"erfc", ZMATH_TR_ERFC}, {"exp", ZMATH_TR_EXP},
    {"exp10", ZMATH_TR_EXP10}, {"exp10m1", ZMATH_TR_EXP10M1},
    {"exp2", ZMATH_TR_EXP2}, {"exp2m1", ZMATH_TR_EXP2M1},
    {"expm1", ZMATH_TR_EXPM1}, {"lgamma", ZMATH_TR_LGAMMA},
    {"log", ZMATH_TR_LOG}, {"log10", ZMATH_TR_LOG10},
    {"log10p1", ZMATH_TR_LOG10P1}, {"log1p", ZMATH_TR_LOG1P},
    {"log2", ZMATH_TR_LOG2}, {"log2p1", ZMATH_TR_LOG2P1},
    {"logp1", ZMATH_TR_LOGP1}, {"pow", ZMATH_TR_POW},
    {"pown", ZMATH_TR_POWN}, {"powr", ZMATH_TR_POWR},
    {"rootn", ZMATH_TR_ROOTN}, {"sin", ZMATH_TR_SIN},
    {"sinh", ZMATH_TR_SINH}, {"sinpi", ZMATH_TR_SINPI},
    {"tan", ZMATH_TR_TAN}, {"tanh", ZMATH_TR_TANH},
    {"tanpi", ZMATH_TR_TANPI}, {"tgamma", ZMATH_TR_TGAMMA},
};

typedef struct zmath_target_format {
    unsigned width;
    unsigned exponent_bits;
    unsigned fraction_bits;
    unsigned bias;
    uint64_t sign_mask;
    uint64_t exponent_mask;
    uint64_t fraction_mask;
    uint64_t value_mask;
} zmath_target_format;

static int zmath_route_kind(
    const zmath_testing_oracle_operation_signature *signature,
    enum zmath_transcendental_kind *kind_out
) {
    size_t i;
    if (signature == NULL || signature->operation == NULL || kind_out == NULL) return 0;
    for (i = 0; i < sizeof(zmath_transcendental_routes) /
                         sizeof(zmath_transcendental_routes[0]); ++i) {
        const zmath_transcendental_route *route = &zmath_transcendental_routes[i];
        size_t length = strlen(route->name);
        if (signature->operation_length == length &&
            memcmp(signature->operation, route->name, length) == 0) {
            *kind_out = route->kind;
            return 1;
        }
    }
    return 0;
}

static int zmath_format_from_descriptor(
    const zmath_testing_oracle_field_descriptor *descriptor,
    zmath_target_format *format
) {
    if (descriptor == NULL || format == NULL ||
        descriptor->kind != ZMATH_TESTING_ORACLE_FIELD_FLOAT) return 0;
    switch (descriptor->format.code) {
        case ZMATH_TESTING_ORACLE_FORMAT_H:
            if (descriptor->format.storage_bits != 16 || descriptor->format.exponent_bits != 5 ||
                descriptor->format.fraction_bits != 10 || descriptor->value_bits != 16) return 0;
            format->width = 16; format->exponent_bits = 5; format->fraction_bits = 10; format->bias = 15;
            break;
        case ZMATH_TESTING_ORACLE_FORMAT_F:
            if (descriptor->format.storage_bits != 32 || descriptor->format.exponent_bits != 8 ||
                descriptor->format.fraction_bits != 23 || descriptor->value_bits != 32) return 0;
            format->width = 32; format->exponent_bits = 8; format->fraction_bits = 23; format->bias = 127;
            break;
        case ZMATH_TESTING_ORACLE_FORMAT_D:
            if (descriptor->format.storage_bits != 64 || descriptor->format.exponent_bits != 11 ||
                descriptor->format.fraction_bits != 52 || descriptor->value_bits != 64) return 0;
            format->width = 64; format->exponent_bits = 11; format->fraction_bits = 52; format->bias = 1023;
            break;
        default: return 0;
    }
    format->sign_mask = UINT64_C(1) << (format->width - 1);
    format->fraction_mask = (UINT64_C(1) << format->fraction_bits) - 1;
    format->exponent_mask = ((UINT64_C(1) << format->exponent_bits) - 1) << format->fraction_bits;
    format->value_mask = format->sign_mask | format->exponent_mask | format->fraction_mask;
    return 1;
}

static uint64_t zmath_one(const zmath_target_format *format) {
    return (uint64_t)format->bias << format->fraction_bits;
}

static uint64_t zmath_two(const zmath_target_format *format) {
    return (uint64_t)(format->bias + 1) << format->fraction_bits;
}
static uint64_t zmath_half(const zmath_target_format *format) {
    return (uint64_t)(format->bias - 1) << format->fraction_bits;
}

static uint64_t zmath_quarter(const zmath_target_format *format) {
    return (uint64_t)(format->bias - 2) << format->fraction_bits;
}

static uint64_t zmath_canonical_nan(const zmath_target_format *format) {
    return (((UINT64_C(1) << format->exponent_bits) - 1) << format->fraction_bits) |
           (UINT64_C(1) << (format->fraction_bits - 1));
}

static uint64_t zmath_infinity(const zmath_target_format *format, int negative) {
    return (negative ? format->sign_mask : 0) |
           (((UINT64_C(1) << format->exponent_bits) - 1) << format->fraction_bits);
}

static uint64_t zmath_quiet_nan(
    const zmath_target_format *source,
    const zmath_target_format *target,
    uint64_t bits
) {
    uint64_t payload = bits & source->fraction_mask;
    if (target->fraction_bits > source->fraction_bits) payload <<= target->fraction_bits - source->fraction_bits;
    else payload >>= source->fraction_bits - target->fraction_bits;
    payload &= target->fraction_mask;
    payload |= UINT64_C(1) << (target->fraction_bits - 1);
    return (bits & source->sign_mask ? target->sign_mask : 0) |
           (((UINT64_C(1) << target->exponent_bits) - 1) << target->fraction_bits) | payload;
}

static int zmath_is_nan(const zmath_target_format *format, uint64_t bits) {
    return (bits & format->exponent_mask) == format->exponent_mask &&
           (bits & format->fraction_mask) != 0;
}

static int zmath_is_inf(const zmath_target_format *format, uint64_t bits) {
    return (bits & format->exponent_mask) == format->exponent_mask &&
           (bits & format->fraction_mask) == 0;
}

static int zmath_is_zero(const zmath_target_format *format, uint64_t bits) {
    return (bits & (format->exponent_mask | format->fraction_mask)) == 0;
}

static int zmath_is_negative(const zmath_target_format *format, uint64_t bits) {
    return (bits & format->sign_mask) != 0;
}
static int zmath_is_signaling_nan(const zmath_target_format *format, uint64_t bits) {
    return zmath_is_nan(format, bits) &&
           (bits & (UINT64_C(1) << (format->fraction_bits - 1))) == 0;
}


static int zmath_decode_bits(mpfr_t value, const zmath_target_format *format, uint64_t bits) {
    uint64_t exponent, fraction, exponent_all;
    mpfr_exp_t exponent_two;
    mpz_t significand;
    if ((bits & ~format->value_mask) != 0) return 0;
    exponent = (bits & format->exponent_mask) >> format->fraction_bits;
    fraction = bits & format->fraction_mask;
    exponent_all = (UINT64_C(1) << format->exponent_bits) - 1;
    if (exponent == exponent_all) {
        if (fraction == 0) mpfr_set_inf(value, zmath_is_negative(format, bits) ? -1 : 1);
        else mpfr_set_nan(value);
        return 1;
    }
    if (exponent == 0 && fraction == 0) {
        mpfr_set_zero(value, zmath_is_negative(format, bits) ? -1 : 1);
        return 1;
    }
    mpz_init_set_ui(significand, fraction);
    if (exponent == 0) exponent_two = 1 - (mpfr_exp_t)format->bias - (mpfr_exp_t)format->fraction_bits;
    else {
        mpz_setbit(significand, format->fraction_bits);
        exponent_two = (mpfr_exp_t)exponent - (mpfr_exp_t)format->bias - (mpfr_exp_t)format->fraction_bits;
    }
    mpfr_set_z_2exp(value, significand, exponent_two, MPFR_RNDN);
    if (zmath_is_negative(format, bits)) mpfr_neg(value, value, MPFR_RNDN);
    mpz_clear(significand);
    return 1;
}
/*
 * Return exact values on the integer and half-integer lattice of pi-scaled
 * operations. The input is represented exactly in `first`, so multiplying it
 * by two and testing integrality does not introduce a reduction error.
 */
static int zmath_special_pi_lattice(
    enum zmath_transcendental_kind kind,
    const zmath_target_format *format,
    mpfr_srcptr first,
    uint64_t *bits_out,
    uint32_t *class_out
) {
    mpfr_t doubled;
    mpz_t lattice;
    unsigned residue;
    int negative;
    int odd_integer;

    if (kind != ZMATH_TR_SINPI && kind != ZMATH_TR_COSPI &&
        kind != ZMATH_TR_TANPI && kind != ZMATH_TR_ASINPI &&
        kind != ZMATH_TR_ACOSPI && kind != ZMATH_TR_ATANPI) {
        return 0;
    }
    if (!mpfr_number_p(first)) return 0;

    mpfr_init2(doubled, ZMATH_ORACLE_PRECISION);
    mpz_init(lattice);
    mpfr_mul_2ui(doubled, first, 1, MPFR_RNDN);
    if (!mpfr_integer_p(doubled)) {
        mpz_clear(lattice);
        mpfr_clear(doubled);
        return 0;
    }
    mpfr_get_z(lattice, doubled, MPFR_RNDZ);
    residue = (unsigned)mpz_fdiv_ui(lattice, 4);
    negative = mpfr_signbit(first) != 0;
    odd_integer = residue == 2;

    switch (kind) {
        case ZMATH_TR_SINPI:
            if ((residue & 1U) == 0) {
                *bits_out = negative ? format->sign_mask : 0;
                *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            } else {
                *bits_out = residue == 1 ? zmath_one(format) :
                                             (zmath_one(format) | format->sign_mask);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
            }
            break;
        case ZMATH_TR_COSPI:
            if ((residue & 1U) != 0) {
                *bits_out = 0;
                *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            } else {
                *bits_out = residue == 0 ? zmath_one(format) :
                                             (zmath_one(format) | format->sign_mask);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
            }
            break;
        case ZMATH_TR_TANPI:
            if ((residue & 1U) != 0) {
                *bits_out = residue == 1 ? zmath_infinity(format, 0) :
                                             zmath_infinity(format, 1);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            } else {
                *bits_out = (negative != odd_integer) ? format->sign_mask : 0;
                *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            }
            break;
        case ZMATH_TR_ASINPI:
            if (mpz_cmp_si(lattice, 0) == 0) {
                *bits_out = negative ? format->sign_mask : 0;
                *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            } else if (mpz_cmp_si(lattice, 2) == 0 ||
                       mpz_cmp_si(lattice, -2) == 0) {
                *bits_out = mpz_sgn(lattice) < 0 ?
                                (zmath_half(format) | format->sign_mask) :
                                zmath_half(format);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
            } else {
                mpz_clear(lattice);
                mpfr_clear(doubled);
                return 0;
            }
            break;
        case ZMATH_TR_ACOSPI:
            if (mpz_cmp_si(lattice, 0) == 0) {
                *bits_out = zmath_half(format);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
            } else if (mpz_cmp_si(lattice, 2) == 0) {
                *bits_out = 0;
                *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            } else if (mpz_cmp_si(lattice, -2) == 0) {
                *bits_out = zmath_one(format);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
            } else {
                mpz_clear(lattice);
                mpfr_clear(doubled);
                return 0;
            }
            break;
        case ZMATH_TR_ATANPI:
            if (mpz_cmp_si(lattice, 0) == 0) {
                *bits_out = negative ? format->sign_mask : 0;
                *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            } else if (mpz_cmp_si(lattice, 2) == 0 ||
                       mpz_cmp_si(lattice, -2) == 0) {
                *bits_out = mpz_sgn(lattice) < 0 ?
                                (zmath_quarter(format) | format->sign_mask) :
                                zmath_quarter(format);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
            } else {
                mpz_clear(lattice);
                mpfr_clear(doubled);
                return 0;
            }
            break;
        default:
            mpz_clear(lattice);
            mpfr_clear(doubled);
            return 0;
    }

    mpz_clear(lattice);
    mpfr_clear(doubled);
    return 1;
}

static int zmath_round_right(mpz_t rounded, const mpz_t value, mpfr_exp_t shift) {
    mpz_t remainder, halfway;
    int comparison;
    if (shift <= 0) {
        mpfr_exp_t left = -shift;
        if (left < 0 || (uintmax_t)left > (uintmax_t)((mp_bitcnt_t)-1)) return 0;
        mpz_mul_2exp(rounded, value, (mp_bitcnt_t)left);
        return 1;
    }
    if ((uintmax_t)shift > (uintmax_t)((mp_bitcnt_t)-1)) return 0;
    mpz_init(remainder); mpz_init(halfway);
    mpz_fdiv_q_2exp(rounded, value, (mp_bitcnt_t)shift);
    mpz_fdiv_r_2exp(remainder, value, (mp_bitcnt_t)shift);
    mpz_set_ui(halfway, 1); mpz_mul_2exp(halfway, halfway, (mp_bitcnt_t)(shift - 1));
    comparison = mpz_cmp(remainder, halfway);
    if (comparison > 0 || (comparison == 0 && mpz_odd_p(rounded))) mpz_add_ui(rounded, rounded, 1);
    mpz_clear(halfway); mpz_clear(remainder);
    return 1;
}

static int zmath_encode(
    uint64_t *bits_out, uint32_t *class_out,
    const zmath_target_format *format, mpfr_srcptr value
) {
    const uint64_t exponent_all = (UINT64_C(1) << format->exponent_bits) - 1;
    const uint64_t sign = mpfr_signbit(value) ? format->sign_mask : 0;
    const mpfr_exp_t minimum_normal = 1 - (mpfr_exp_t)format->bias;
    const mpfr_exp_t subnormal_unit = minimum_normal - (mpfr_exp_t)format->fraction_bits;
    const unsigned precision = format->fraction_bits + 1;
    mpz_t significand, magnitude, rounded, limit;
    mpfr_exp_t exponent_two, unbiased, shift;
    size_t bit_length;
    uint64_t exponent_field, fraction_field;
    if (mpfr_nan_p(value)) { *bits_out = zmath_canonical_nan(format); *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN; return 1; }
    if (mpfr_inf_p(value)) { *bits_out = sign | (exponent_all << format->fraction_bits); *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY; return 1; }
    if (mpfr_zero_p(value)) { *bits_out = sign; *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO; return 1; }
    mpz_init(significand); mpz_init(magnitude); mpz_init(rounded); mpz_init(limit);
    exponent_two = mpfr_get_z_2exp(significand, value);
    mpz_abs(magnitude, significand); bit_length = mpz_sizeinbase(magnitude, 2);
    unbiased = exponent_two + (mpfr_exp_t)bit_length - 1;
    mpz_set_ui(limit, 1); mpz_mul_2exp(limit, limit, precision);
    if (unbiased >= minimum_normal) {
        shift = (mpfr_exp_t)bit_length - (mpfr_exp_t)precision;
        if (!zmath_round_right(rounded, magnitude, shift)) goto error;
        if (mpz_cmp(rounded, limit) >= 0) { mpz_fdiv_q_2exp(rounded, rounded, 1); ++unbiased; }
        if (unbiased > (mpfr_exp_t)format->bias) {
            *bits_out = sign | (exponent_all << format->fraction_bits);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY; goto success;
        }
        mpz_fdiv_q_2exp(limit, limit, 1); mpz_sub(rounded, rounded, limit);
        exponent_field = (uint64_t)(unbiased + (mpfr_exp_t)format->bias);
        fraction_field = (uint64_t)mpz_get_ui(rounded);
        *bits_out = sign | (exponent_field << format->fraction_bits) | fraction_field;
        *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL; goto success;
    }
    shift = subnormal_unit - exponent_two;
    if (!zmath_round_right(rounded, magnitude, shift)) goto error;
    mpz_set_ui(limit, 1); mpz_mul_2exp(limit, limit, format->fraction_bits);
    if (mpz_cmp(rounded, limit) >= 0) {
        *bits_out = sign | (UINT64_C(1) << format->fraction_bits);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL; goto success;
    }
    fraction_field = (uint64_t)mpz_get_ui(rounded);
    *bits_out = sign | fraction_field;
    *class_out = fraction_field == 0 ? ZMATH_TESTING_ORACLE_CLASS_ZERO : ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL;
success:
    mpz_clear(limit); mpz_clear(rounded); mpz_clear(magnitude); mpz_clear(significand); return 1;
error:
    mpz_clear(limit); mpz_clear(rounded); mpz_clear(magnitude); mpz_clear(significand); return 0;
}

static int zmath_mpfr_eval(
    enum zmath_transcendental_kind kind, mpfr_t output, mpfr_t first, mpfr_t second,
    int64_t exponent, int *lgamma_sign
) {
#define U(fn) return (fn(output, first, MPFR_RNDN), 1)
    switch (kind) {
        case ZMATH_TR_ACOS: U(mpfr_acos); case ZMATH_TR_ACOSH: U(mpfr_acosh); case ZMATH_TR_ACOSPI: U(mpfr_acospi);
        case ZMATH_TR_ASIN: U(mpfr_asin); case ZMATH_TR_ASINH: U(mpfr_asinh); case ZMATH_TR_ASINPI: U(mpfr_asinpi);
        case ZMATH_TR_ATAN: U(mpfr_atan); case ZMATH_TR_ATANH: U(mpfr_atanh); case ZMATH_TR_ATANPI: U(mpfr_atanpi);
        case ZMATH_TR_COS: U(mpfr_cos); case ZMATH_TR_COSH: U(mpfr_cosh); case ZMATH_TR_COSPI: U(mpfr_cospi);
        case ZMATH_TR_ERF: U(mpfr_erf); case ZMATH_TR_ERFC: U(mpfr_erfc); case ZMATH_TR_EXP: U(mpfr_exp);
        case ZMATH_TR_EXP10: U(mpfr_exp10); case ZMATH_TR_EXP10M1: U(mpfr_exp10m1); case ZMATH_TR_EXP2: U(mpfr_exp2);
        case ZMATH_TR_EXP2M1: U(mpfr_exp2m1); case ZMATH_TR_EXPM1: U(mpfr_expm1); case ZMATH_TR_LOG: U(mpfr_log);
        case ZMATH_TR_LOG10: U(mpfr_log10); case ZMATH_TR_LOG10P1: U(mpfr_log10p1); case ZMATH_TR_LOG1P: U(mpfr_log1p);
        case ZMATH_TR_LOG2: U(mpfr_log2); case ZMATH_TR_LOG2P1: U(mpfr_log2p1); case ZMATH_TR_LOGP1: U(mpfr_log1p);
        case ZMATH_TR_SIN: U(mpfr_sin); case ZMATH_TR_SINH: U(mpfr_sinh); case ZMATH_TR_SINPI: U(mpfr_sinpi);
        case ZMATH_TR_TAN: U(mpfr_tan); case ZMATH_TR_TANH: U(mpfr_tanh); case ZMATH_TR_TANPI: U(mpfr_tanpi);
        case ZMATH_TR_TGAMMA: U(mpfr_gamma);
        case ZMATH_TR_ATAN2: return (mpfr_atan2(output, first, second, MPFR_RNDN), 1);
        case ZMATH_TR_ATAN2PI: return (mpfr_atan2pi(output, first, second, MPFR_RNDN), 1);
        case ZMATH_TR_POW: return (mpfr_pow(output, first, second, MPFR_RNDN), 1);
        case ZMATH_TR_POWR: return (mpfr_powr(output, first, second, MPFR_RNDN), 1);
        case ZMATH_TR_COMPOUNDN: return (mpfr_compound_si(output, first, (long)exponent, MPFR_RNDN), 1);
        case ZMATH_TR_POWN: return (mpfr_pow_si(output, first, (long)exponent, MPFR_RNDN), 1);
        case ZMATH_TR_ROOTN: return (mpfr_rootn_si(output, first, (long)exponent, MPFR_RNDN), 1);
        case ZMATH_TR_LGAMMA: return (mpfr_lgamma(output, lgamma_sign, first, MPFR_RNDN), 1);
    }
#undef U
    return 0;
}

static int zmath_arb_eval(
    enum zmath_transcendental_kind kind, arb_t output, arb_t first, arb_t second, int64_t exponent
) {
    arb_t temporary, constant, pi;
    fmpz_t integer;
    fmpq_t rational;
    int ok = 1;
    arb_init(temporary); arb_init(constant); arb_init(pi); fmpz_init(integer); fmpq_init(rational);
    switch (kind) {
        case ZMATH_TR_ACOS: arb_acos(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_ACOSH: arb_acosh(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_ACOSPI: arb_acos(temporary, first, ZMATH_ORACLE_PRECISION); arb_const_pi(pi, ZMATH_ORACLE_PRECISION); arb_div(output, temporary, pi, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_ASIN: arb_asin(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_ASINH: arb_asinh(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_ASINPI: arb_asin(temporary, first, ZMATH_ORACLE_PRECISION); arb_const_pi(pi, ZMATH_ORACLE_PRECISION); arb_div(output, temporary, pi, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_ATAN: arb_atan(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_ATAN2: arb_atan2(output, first, second, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_ATAN2PI: arb_atan2(temporary, first, second, ZMATH_ORACLE_PRECISION); arb_const_pi(pi, ZMATH_ORACLE_PRECISION); arb_div(output, temporary, pi, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_ATANH: arb_atanh(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_ATANPI: arb_atan(temporary, first, ZMATH_ORACLE_PRECISION); arb_const_pi(pi, ZMATH_ORACLE_PRECISION); arb_div(output, temporary, pi, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_COMPOUNDN: arb_add_ui(temporary, first, 1, ZMATH_ORACLE_PRECISION); fmpz_set_si(integer, (slong)exponent); arb_pow_fmpz(output, temporary, integer, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_COS: arb_cos(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_COSH: arb_cosh(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_COSPI: arb_cos_pi(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_ERF: arb_hypgeom_erf(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_ERFC: arb_hypgeom_erfc(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_EXP: arb_exp(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_EXP10: arb_set_ui(constant, 10); arb_pow(output, constant, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_EXP10M1:
        case ZMATH_TR_EXP2M1:
            arb_set_ui(constant, kind == ZMATH_TR_EXP2M1 ? 2 : 10);
            if (arb_is_int(first)) {
                arb_pow(temporary, constant, first, ZMATH_ORACLE_PRECISION);
                arb_sub_ui(output, temporary, 1, ZMATH_ORACLE_PRECISION);
            } else {
                arb_log(constant, constant, ZMATH_ORACLE_PRECISION);
                arb_mul(temporary, first, constant, ZMATH_ORACLE_PRECISION);
                arb_expm1(output, temporary, ZMATH_ORACLE_PRECISION);
            }
            break;
        case ZMATH_TR_EXP2: arb_set_ui(constant, 2); arb_pow(output, constant, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_EXPM1: arb_expm1(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_LGAMMA:
            if (arb_is_negative(first) && !arb_is_int(first)) {
                /*
                 * Reflection is valid away from the poles and keeps the
                 * Arb argument to lgamma positive:
                 * log|Gamma(x)| = log(pi) - log|sin(pi*x)|
                 *                  - log(Gamma(1-x)).
                 */
                arb_neg(constant, first);
                arb_add_ui(constant, constant, 1, ZMATH_ORACLE_PRECISION);
                arb_lgamma(output, constant, ZMATH_ORACLE_PRECISION);
                arb_sin_pi(temporary, first, ZMATH_ORACLE_PRECISION);
                arb_abs(temporary, temporary);
                arb_log(temporary, temporary, ZMATH_ORACLE_PRECISION);
                arb_const_pi(pi, ZMATH_ORACLE_PRECISION);
                arb_log(pi, pi, ZMATH_ORACLE_PRECISION);
                arb_sub(pi, pi, temporary, ZMATH_ORACLE_PRECISION);
                arb_sub(output, pi, output, ZMATH_ORACLE_PRECISION);
            } else {
                arb_lgamma(output, first, ZMATH_ORACLE_PRECISION);
            }
            break;
        case ZMATH_TR_LOG: arb_log(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_LOG10: arb_log_base_ui(output, first, 10, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_LOG10P1: arb_log1p(temporary, first, ZMATH_ORACLE_PRECISION); arb_const_log10(constant, ZMATH_ORACLE_PRECISION); arb_div(output, temporary, constant, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_LOG1P: arb_log1p(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_LOG2: arb_log_base_ui(output, first, 2, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_LOG2P1: arb_log1p(temporary, first, ZMATH_ORACLE_PRECISION); arb_const_log2(constant, ZMATH_ORACLE_PRECISION); arb_div(output, temporary, constant, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_LOGP1: arb_log1p(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_POW: case ZMATH_TR_POWR: arb_pow(output, first, second, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_POWN: fmpz_set_si(integer, (slong)exponent); arb_pow_fmpz(output, first, integer, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_ROOTN:
            if (exponent > 0) {
                fmpq_set_si(rational, 1, (ulong)exponent);
            } else {
                fmpq_set_si(rational, -1, (ulong)(-exponent));
            }
            if (arb_is_negative(first) && exponent % 2 != 0) {
                arb_neg(temporary, first);
                arb_pow_fmpq(
                    output,
                    temporary,
                    rational,
                    ZMATH_ORACLE_PRECISION
                );
                arb_neg(output, output);
            } else {
                arb_pow_fmpq(
                    output,
                    first,
                    rational,
                    ZMATH_ORACLE_PRECISION
                );
            }
            break;
        case ZMATH_TR_SIN: arb_sin(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_SINH: arb_sinh(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_SINPI: arb_sin_pi(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_TAN: arb_tan(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_TANH: arb_tanh(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_TANPI: arb_tan_pi(output, first, ZMATH_ORACLE_PRECISION); break;
        case ZMATH_TR_TGAMMA: arb_gamma(output, first, ZMATH_ORACLE_PRECISION); break;
        default: ok = 0; break;
    }
    fmpq_clear(rational); fmpz_clear(integer); arb_clear(pi); arb_clear(constant); arb_clear(temporary);
    return ok;
}

static uint64_t zmath_next_up(const zmath_target_format *format, uint64_t bits) {
    const uint64_t sign = bits & format->sign_mask;
    const uint64_t magnitude = bits & ~format->sign_mask;

    if (zmath_is_nan(format, bits) ||
        bits == zmath_infinity(format, 0)) return bits;
    if (magnitude == 0) return 1;
    if (sign != 0) return bits - 1;
    return bits + 1;
}

static uint64_t zmath_next_down(const zmath_target_format *format, uint64_t bits) {
    const uint64_t sign = bits & format->sign_mask;
    const uint64_t magnitude = bits & ~format->sign_mask;

    if (zmath_is_nan(format, bits) ||
        bits == zmath_infinity(format, 1)) return bits;
    if (magnitude == 0) return format->sign_mask | 1;
    if (sign != 0) return bits + 1;
    return bits - 1;
}

static int zmath_midpoint(
    mpfr_t midpoint,
    const zmath_target_format *format,
    uint64_t left_bits,
    uint64_t right_bits
) {
    mpfr_t left, right;
    mpfr_init2(left, ZMATH_ORACLE_BOUNDARY_PRECISION);
    mpfr_init2(right, ZMATH_ORACLE_BOUNDARY_PRECISION);
    if (!zmath_decode_bits(left, format, left_bits) ||
        !zmath_decode_bits(right, format, right_bits)) {
        mpfr_clear(right);
        mpfr_clear(left);
        return 0;
    }
    mpfr_add(midpoint, left, right, MPFR_RNDN);
    mpfr_div_2ui(midpoint, midpoint, 1, MPFR_RNDN);
    mpfr_clear(right);
    mpfr_clear(left);
    return 1;
}

static int zmath_is_max_finite(
    const zmath_target_format *format,
    uint64_t bits
) {
    const uint64_t exponent =
        (bits & format->exponent_mask) >> format->fraction_bits;
    const uint64_t maximum_exponent =
        (UINT64_C(1) << format->exponent_bits) - 2;

    return exponent == maximum_exponent &&
           (bits & format->fraction_mask) == format->fraction_mask;
}

static void zmath_overflow_threshold(
    arf_t threshold,
    arf_t negative_threshold,
    const zmath_target_format *format
) {
    arf_t top_power;
    arf_t half_ulp;
    const slong top_exponent = (slong)format->bias + 1;
    const slong half_ulp_exponent =
        (slong)format->bias - (slong)format->fraction_bits - 1;

    arf_init(top_power);
    arf_init(half_ulp);
    arf_set_ui_2exp_si(top_power, 1UL, top_exponent);
    arf_set_ui_2exp_si(half_ulp, 1UL, half_ulp_exponent);
    (void)arf_sub(
        threshold,
        top_power,
        half_ulp,
        ZMATH_ORACLE_PRECISION,
        ARF_RND_NEAR
    );
    arf_neg(negative_threshold, threshold);
    arf_clear(half_ulp);
    arf_clear(top_power);
}

static int zmath_integer_is_odd(mpfr_srcptr value) {
    mpz_t integer;
    int odd;

    if (!mpfr_number_p(value) || !mpfr_integer_p(value)) return 0;
    mpz_init(integer);
    mpfr_get_z(integer, value, MPFR_RNDZ);
    odd = mpz_odd_p(integer) != 0;
    mpz_clear(integer);
    return odd;
}

/*
 * Prove a positive overflow result without constructing the enormous value.
 * For exp_b(x), compare x*log(b) with (bias + 1)*log(2).  That lower
 * bound is above the finite/infinity midpoint.  For exp_b(x)-1, use
 * exp_b(x)-1 > exp_b(x)/2 once x is beyond the deliberately conservative
 * (bias + 2)*log(b) bound.  Pow uses y*log(|x|); negative bases require an
 * even integer exponent because this proof only accepts positive infinity.
 */
static int zmath_prove_log_overflow(
    enum zmath_transcendental_kind kind,
    const zmath_target_format *format,
    mpfr_srcptr first,
    mpfr_srcptr second,
    uint64_t candidate_bits
) {
    arb_t arb_first;
    arb_t arb_second;
    arb_t factor;
    arb_t logarithm;
    arb_t threshold;
    arf_t logarithm_lower;
    arf_t logarithm_upper;
    arf_t threshold_lower;
    arf_t threshold_upper;
    int proof = 0;
    int threshold_multiplier;

    if (!zmath_is_inf(format, candidate_bits) ||
        zmath_is_negative(format, candidate_bits)) return 0;
    if ((kind == ZMATH_TR_EXP || kind == ZMATH_TR_EXP2 ||
         kind == ZMATH_TR_EXP10 || kind == ZMATH_TR_EXP2M1 ||
         kind == ZMATH_TR_EXP10M1) &&
        mpfr_sgn(first) <= 0) return 0;
    if (kind == ZMATH_TR_POW &&
        (mpfr_sgn(first) == 0 ||
         (mpfr_sgn(first) < 0 &&
          (!mpfr_integer_p(second) || zmath_integer_is_odd(second))))) return 0;
    if (kind == ZMATH_TR_POWR && mpfr_sgn(first) <= 0) return 0;
    if (kind != ZMATH_TR_EXP && kind != ZMATH_TR_EXP2 &&
        kind != ZMATH_TR_EXP10 &&
        kind != ZMATH_TR_EXP2M1 && kind != ZMATH_TR_EXP10M1 &&
        kind != ZMATH_TR_POW && kind != ZMATH_TR_POWR) return 0;

    arb_init(arb_first);
    arb_init(arb_second);
    arb_init(factor);
    arb_init(logarithm);
    arb_init(threshold);
    arf_init(logarithm_lower);
    arf_init(logarithm_upper);
    arf_init(threshold_lower);
    arf_init(threshold_upper);
    arb_set_interval_mpfr(
        arb_first,
        first,
        first,
        ZMATH_ORACLE_PRECISION
    );
    if (kind == ZMATH_TR_POW || kind == ZMATH_TR_POWR) {
        arb_set_interval_mpfr(
            arb_second,
            second,
            second,
            ZMATH_ORACLE_PRECISION
        );
        arb_abs(arb_first, arb_first);
        arb_log(factor, arb_first, ZMATH_ORACLE_PRECISION);
        arb_mul(
            logarithm,
            factor,
            arb_second,
            ZMATH_ORACLE_PRECISION
        );
        arb_const_log2(factor, ZMATH_ORACLE_PRECISION);
        threshold_multiplier = (int)format->bias + 1;
        arb_mul_ui(
            threshold,
            factor,
            (ulong)threshold_multiplier,
            ZMATH_ORACLE_PRECISION
        );
    } else if (kind == ZMATH_TR_EXP) {
        arb_set(logarithm, arb_first);
        arb_const_log2(factor, ZMATH_ORACLE_PRECISION);
        threshold_multiplier = (int)format->bias + 1;
        arb_mul_ui(
            threshold,
            factor,
            (ulong)threshold_multiplier,
            ZMATH_ORACLE_PRECISION
        );
    } else {
        const int is_base_ten =
            kind == ZMATH_TR_EXP10 || kind == ZMATH_TR_EXP10M1;
        if (is_base_ten) {
            arb_const_log10(factor, ZMATH_ORACLE_PRECISION);
        } else {
            arb_const_log2(factor, ZMATH_ORACLE_PRECISION);
        }
        arb_mul(
            logarithm,
            arb_first,
            factor,
            ZMATH_ORACLE_PRECISION
        );
        threshold_multiplier = (int)format->bias +
            ((kind == ZMATH_TR_EXP2M1 || kind == ZMATH_TR_EXP10M1) ? 2 : 1);
        arb_mul_ui(
            threshold,
            factor,
            (ulong)threshold_multiplier,
            ZMATH_ORACLE_PRECISION
        );
    }

    arb_get_interval_arf(
        logarithm_lower,
        logarithm_upper,
        logarithm,
        ZMATH_ORACLE_PRECISION
    );
    arb_get_interval_arf(
        threshold_lower,
        threshold_upper,
        threshold,
        ZMATH_ORACLE_PRECISION
    );
    if (arf_is_finite(logarithm_lower) &&
        arf_is_finite(logarithm_upper) &&
        arf_is_finite(threshold_lower) &&
        arf_is_finite(threshold_upper) &&
        arf_cmp(logarithm_lower, threshold_upper) >= 0) {
        proof = 1;
    }
    arf_clear(threshold_upper);
    arf_clear(threshold_lower);
    arf_clear(logarithm_upper);
    arf_clear(logarithm_lower);
    arb_clear(threshold);
    arb_clear(logarithm);
    arb_clear(factor);
    arb_clear(arb_second);
    arb_clear(arb_first);
    return proof;
}

/*
 * For x > 0, atan2(y, x) = atan(y/x), and atan(t) < t for t > 0.
 * Thus |y/x| <= the zero/minsub midpoint proves either signed zero result.
 * Compare the dyadic midpoint after multiplying it by x.  Binary inputs have
 * at most 53-bit significands, so these 1024-bit MPFR products are exact.
 */
static int zmath_prove_atan2_zero(
    enum zmath_transcendental_kind kind,
    const zmath_target_format *format,
    mpfr_srcptr first,
    mpfr_srcptr second,
    uint64_t candidate_bits
) {
    mpfr_t absolute_first;
    mpfr_t boundary;
    mpfr_t scaled_boundary;
    int proof;

    if ((kind != ZMATH_TR_ATAN2 && kind != ZMATH_TR_ATAN2PI) ||
        !zmath_is_zero(format, candidate_bits) ||
        !mpfr_number_p(first) ||
        !mpfr_number_p(second) ||
        mpfr_sgn(first) == 0 ||
        mpfr_sgn(second) <= 0 ||
        zmath_is_negative(format, candidate_bits) != (mpfr_sgn(first) < 0)) {
        return 0;
    }
    mpfr_init2(absolute_first, ZMATH_ORACLE_BOUNDARY_PRECISION);
    mpfr_init2(boundary, ZMATH_ORACLE_BOUNDARY_PRECISION);
    mpfr_init2(scaled_boundary, ZMATH_ORACLE_BOUNDARY_PRECISION);
    mpfr_abs(absolute_first, first, MPFR_RNDN);
    proof = zmath_midpoint(
        boundary,
        format,
        0,
        zmath_next_up(format, 0)
    );
    if (proof) {
        mpfr_mul(
            scaled_boundary,
            boundary,
            second,
            MPFR_RNDN
        );
        proof = mpfr_cmp(absolute_first, scaled_boundary) <= 0;
    }
    mpfr_clear(scaled_boundary);
    mpfr_clear(boundary);
    mpfr_clear(absolute_first);
    return proof;
}

/*
 * When t=|y/x| is exactly a target midpoint, 512-bit atan can round to t.
 * For 0<t<1, t-t^3 < atan(t) < t.  Exact dyadic midpoint equality and an
 * Arb bound t^3 < t-lower_midpoint therefore select the lower magnitude,
 * including odd subnormal results which a second nearest-even round loses.
 */
static int zmath_prove_atan2_midpoint(
    enum zmath_transcendental_kind kind, const zmath_target_format *format,
    mpfr_srcptr first, mpfr_srcptr second, uint64_t candidate_bits
) {
    const uint64_t magnitude = candidate_bits & ~format->sign_mask;
    mpfr_t absolute_first, midpoint, scaled_midpoint, lower_midpoint;
    arb_t upper, gap, cube;
    int proof = 0;
    if (kind != ZMATH_TR_ATAN2 ||
        zmath_is_nan(format, candidate_bits) || zmath_is_inf(format, candidate_bits) ||
        !mpfr_number_p(first) || !mpfr_number_p(second) ||
        mpfr_sgn(first) == 0 || mpfr_sgn(second) <= 0 ||
        zmath_is_negative(format, candidate_bits) != (mpfr_sgn(first) < 0)) return 0;
    mpfr_inits2(ZMATH_ORACLE_BOUNDARY_PRECISION,
                absolute_first, midpoint, scaled_midpoint, lower_midpoint, (mpfr_ptr)0);
    arb_init(upper);
    arb_init(gap);
    arb_init(cube);
    if (!zmath_midpoint(midpoint, format, magnitude, magnitude + 1) ||
        mpfr_cmp_ui(midpoint, 1) >= 0) goto cleanup;
    mpfr_abs(absolute_first, first, MPFR_RNDN);
    mpfr_mul(scaled_midpoint, midpoint, second, MPFR_RNDN);
    if (mpfr_cmp(absolute_first, scaled_midpoint) != 0) goto cleanup;
    if (magnitude == 0) {
        mpfr_set_zero(lower_midpoint, 1);
    } else if (!zmath_midpoint(lower_midpoint, format, magnitude - 1, magnitude)) {
        goto cleanup;
    }
    arb_set_interval_mpfr(upper, midpoint, midpoint, ZMATH_ORACLE_PRECISION);
    arb_set_interval_mpfr(gap, lower_midpoint, lower_midpoint, ZMATH_ORACLE_PRECISION);
    arb_sub(gap, upper, gap, ZMATH_ORACLE_PRECISION);
    arb_pow_ui(cube, upper, 3, ZMATH_ORACLE_PRECISION);
    proof = arb_lt(cube, gap);
cleanup:
    arb_clear(cube);
    arb_clear(gap);
    arb_clear(upper);
    mpfr_clears(absolute_first, midpoint, scaled_midpoint, lower_midpoint, (mpfr_ptr)0);
    return proof;
}

static int zmath_prove(
    enum zmath_transcendental_kind kind,
    const zmath_target_format *format,
    mpfr_t first,
    mpfr_t second,
    int64_t exponent,
    uint64_t candidate_bits
) {
    mpfr_t midpoint;
    arf_t lower;
    arf_t upper;
    arf_t lower_boundary;
    arf_t upper_boundary;
    arf_t overflow_threshold;
    arf_t negative_overflow_threshold;
    arb_t arb_first;
    arb_t arb_second;
    arb_t arb_output;
    uint64_t lower_bits;
    uint64_t upper_bits;
    int candidate_infinity;
    int candidate_max_finite;
    int candidate_negative;
    int has_lower_boundary;
    int has_upper_boundary;
    int candidate_even;
    int proof;
    int atan2_zero_proof;

    candidate_infinity = zmath_is_inf(format, candidate_bits);
    candidate_max_finite = zmath_is_max_finite(format, candidate_bits);
    candidate_negative = zmath_is_negative(format, candidate_bits);
    has_lower_boundary =
        !candidate_infinity &&
        !(candidate_max_finite && candidate_negative);
    has_upper_boundary =
        !candidate_infinity &&
        !(candidate_max_finite && !candidate_negative);
    candidate_even =
        (candidate_bits & format->fraction_mask & UINT64_C(1)) == 0;

    mpfr_init2(midpoint, ZMATH_ORACLE_BOUNDARY_PRECISION);
    arf_init(lower);
    arf_init(upper);
    arf_init(lower_boundary);
    arf_init(upper_boundary);
    arf_init(overflow_threshold);
    arf_init(negative_overflow_threshold);
    arb_init(arb_first);
    arb_init(arb_second);
    arb_init(arb_output);
    proof = 0;
    atan2_zero_proof = 0;

    if (!mpfr_number_p(first) ||
        ((kind == ZMATH_TR_POW || kind == ZMATH_TR_POWR ||
          kind == ZMATH_TR_ATAN2 || kind == ZMATH_TR_ATAN2PI) &&
         !mpfr_number_p(second))) {
        goto cleanup;
    }
    if (zmath_prove_log_overflow(
            kind,
            format,
            first,
            second,
            candidate_bits
        )) {
        proof = 1;
        goto cleanup;
    }
    if (zmath_prove_atan2_midpoint(kind, format, first, second, candidate_bits)) {
        proof = 1;
        goto cleanup;
    }
    atan2_zero_proof = zmath_prove_atan2_zero(
        kind,
        format,
        first,
        second,
        candidate_bits
    );
    arb_set_interval_mpfr(
        arb_first,
        first,
        first,
        ZMATH_ORACLE_PRECISION
    );
    if (kind == ZMATH_TR_POW || kind == ZMATH_TR_POWR ||
        kind == ZMATH_TR_ATAN2 || kind == ZMATH_TR_ATAN2PI) {
        arb_set_interval_mpfr(
            arb_second,
            second,
            second,
            ZMATH_ORACLE_PRECISION
        );
    }
    if (!zmath_arb_eval(
            kind,
            arb_output,
            arb_first,
            arb_second,
            exponent
        ) ||
        !arb_is_finite(arb_output)) {
        goto cleanup;
    }
    arb_get_interval_arf(
        lower,
        upper,
        arb_output,
        ZMATH_ORACLE_PRECISION
    );
    if (!arf_is_finite(lower) || !arf_is_finite(upper)) goto cleanup;
    if (atan2_zero_proof) {
        proof = 1;
        goto cleanup;
    }

    if (candidate_infinity || candidate_max_finite) {
        zmath_overflow_threshold(
            overflow_threshold,
            negative_overflow_threshold,
            format
        );
    }
    if (has_lower_boundary) {
        lower_bits = zmath_next_down(format, candidate_bits);
        if (!zmath_midpoint(
                midpoint,
                format,
                lower_bits,
                candidate_bits
            )) {
            goto cleanup;
        }
        arf_set_mpfr(lower_boundary, midpoint);
    }
    if (has_upper_boundary) {
        upper_bits = zmath_next_up(format, candidate_bits);
        if (!zmath_midpoint(
                midpoint,
                format,
                candidate_bits,
                upper_bits
            )) {
            goto cleanup;
        }
        arf_set_mpfr(upper_boundary, midpoint);
    }

    proof = 1;
    if (candidate_infinity) {
        if (candidate_negative) {
            proof = arf_cmp(upper, negative_overflow_threshold) <= 0;
        } else {
            proof = arf_cmp(lower, overflow_threshold) >= 0;
        }
    } else if (candidate_max_finite) {
        if (candidate_negative) {
            proof = arf_cmp(lower, negative_overflow_threshold) > 0;
        } else {
            proof = arf_cmp(upper, overflow_threshold) < 0;
        }
    }
    if (proof && has_lower_boundary) {
        const int comparison = arf_cmp(lower, lower_boundary);
        if (comparison < 0 || (comparison == 0 && !candidate_even)) {
            proof = 0;
        }
    }
    if (proof && has_upper_boundary) {
        const int comparison = arf_cmp(upper, upper_boundary);
        if (comparison > 0 || (comparison == 0 && !candidate_even)) {
            proof = 0;
        }
    }

cleanup:
    arb_clear(arb_output);
    arb_clear(arb_second);
    arb_clear(arb_first);
    arf_clear(negative_overflow_threshold);
    arf_clear(overflow_threshold);
    arf_clear(upper_boundary);
    arf_clear(lower_boundary);
    arf_clear(upper);
    arf_clear(lower);
    mpfr_clear(midpoint);
    return proof;
}

static int zmath_write_scalar(const zmath_testing_oracle_operation_signature *signature, zmath_testing_oracle_result *result, uint64_t bits, uint32_t class_code) {
    if (signature->result_field_count != 1 || result->field_capacity < 1 || result->fields == NULL) return 0;
    result->fields[0].descriptor = signature->result_fields[0]; result->fields[0].value_bits = bits;
    result->fields[0].class_code = class_code; result->fields[0].reserved = 0; result->field_count = 1; return 1;
}

static int zmath_write_pair(
    const zmath_testing_oracle_operation_signature *signature,
    zmath_testing_oracle_result *result,
    uint64_t bits,
    uint32_t class_code,
    uint64_t status
) {
    if (signature->result_field_count != 2 || result->field_capacity < 2 ||
        result->fields == NULL) return 0;
    result->fields[0].descriptor = signature->result_fields[0];
    result->fields[0].value_bits = bits;
    result->fields[0].class_code = class_code;
    result->fields[0].reserved = 0;
    result->fields[1].descriptor = signature->result_fields[1];
    result->fields[1].value_bits = status;
    result->fields[1].class_code = ZMATH_TESTING_ORACLE_CLASS_NONE;
    result->fields[1].reserved = 0;
    result->field_count = 2;
    return 1;
}
static int zmath_special_unary(
    enum zmath_transcendental_kind kind,
    const zmath_target_format *format,
    uint64_t input_bits,
    uint64_t *bits_out,
    uint32_t *class_out
) {
    int negative = zmath_is_negative(format, input_bits);
    if (zmath_is_nan(format, input_bits)) {
        *bits_out = zmath_quiet_nan(format, format, input_bits);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
        return 1;
    }
    if (zmath_is_zero(format, input_bits)) {
        switch (kind) {
            case ZMATH_TR_EXP:
            case ZMATH_TR_EXP10:
            case ZMATH_TR_EXP2:
            case ZMATH_TR_COS:
            case ZMATH_TR_COSH:
            case ZMATH_TR_COSPI:
            case ZMATH_TR_ERFC:
                *bits_out = zmath_one(format);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
                return 1;
            case ZMATH_TR_LOG:
            case ZMATH_TR_LOG10:
            case ZMATH_TR_LOG2:
                *bits_out = zmath_infinity(format, 1);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
                return 1;
            case ZMATH_TR_ACOSH:
                *bits_out = zmath_canonical_nan(format);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
                return 1;
            case ZMATH_TR_LGAMMA:
            case ZMATH_TR_TGAMMA:
                *bits_out = zmath_infinity(format, kind == ZMATH_TR_TGAMMA && negative);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
                return 1;
            case ZMATH_TR_ACOS:
            case ZMATH_TR_ACOSPI:
                return 0;
            default:
                *bits_out = negative ? format->sign_mask : 0;
                *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
                return 1;
        }
    }
    if (zmath_is_inf(format, input_bits)) {
        switch (kind) {
            case ZMATH_TR_EXP:
            case ZMATH_TR_EXP10:
            case ZMATH_TR_EXP2:
                *bits_out = negative ? 0 : zmath_infinity(format, 0);
                *class_out = negative ? ZMATH_TESTING_ORACLE_CLASS_ZERO :
                                        ZMATH_TESTING_ORACLE_CLASS_INFINITY;
                return 1;
            case ZMATH_TR_EXPM1:
            case ZMATH_TR_EXP2M1:
            case ZMATH_TR_EXP10M1:
                if (negative) {
                    *bits_out = zmath_one(format) | format->sign_mask;
                    *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
                } else {
                    *bits_out = zmath_infinity(format, 0);
                    *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
                }
                return 1;
            case ZMATH_TR_LOG:
            case ZMATH_TR_LOG10:
            case ZMATH_TR_LOG2:
            case ZMATH_TR_LOG1P:
            case ZMATH_TR_LOGP1:
            case ZMATH_TR_LOG2P1:
            case ZMATH_TR_LOG10P1:
            case ZMATH_TR_ACOSH:
                if (negative) {
                    *bits_out = zmath_canonical_nan(format);
                    *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
                } else {
                    *bits_out = zmath_infinity(format, 0);
                    *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
                }
                return 1;
            case ZMATH_TR_ATAN:
            case ZMATH_TR_ACOSPI:
            case ZMATH_TR_ASINPI:
            case ZMATH_TR_ATANPI:
                return 0;
            case ZMATH_TR_SIN:
            case ZMATH_TR_COS:
            case ZMATH_TR_TAN:
            case ZMATH_TR_SINPI:
            case ZMATH_TR_COSPI:
            case ZMATH_TR_TANPI:
            case ZMATH_TR_ASIN:
            case ZMATH_TR_ACOS:
            case ZMATH_TR_ATANH:
                *bits_out = zmath_canonical_nan(format);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
                return 1;
            case ZMATH_TR_SINH:
            case ZMATH_TR_ASINH:
                *bits_out = zmath_infinity(format, negative);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
                return 1;
            case ZMATH_TR_COSH:
            case ZMATH_TR_LGAMMA:
                *bits_out = zmath_infinity(format, 0);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
                return 1;
            case ZMATH_TR_ERFC:
                *bits_out = negative ? zmath_two(format) : 0;
                *class_out = negative ? ZMATH_TESTING_ORACLE_CLASS_NORMAL :
                                        ZMATH_TESTING_ORACLE_CLASS_ZERO;
                return 1;
            case ZMATH_TR_TANH:
            case ZMATH_TR_ERF:
                *bits_out = zmath_one(format) | (negative ? format->sign_mask : 0);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
                return 1;
            case ZMATH_TR_TGAMMA:
                if (negative) {
                    *bits_out = zmath_canonical_nan(format);
                    *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
                } else {
                    *bits_out = zmath_infinity(format, 0);
                    *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
                }
                return 1;
            default:
                return 0;
        }
    }
    if (kind == ZMATH_TR_ATANH &&
        (input_bits == zmath_one(format) ||
         input_bits == (format->sign_mask | zmath_one(format)))) {
        *bits_out = zmath_infinity(
            format,
            input_bits == (format->sign_mask | zmath_one(format))
        );
        *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
        return 1;
    }
    if ((kind == ZMATH_TR_LOG1P || kind == ZMATH_TR_LOGP1 ||
         kind == ZMATH_TR_LOG2P1 || kind == ZMATH_TR_LOG10P1) &&
        input_bits == (format->sign_mask | zmath_one(format))) {
        *bits_out = zmath_infinity(format, 1);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
        return 1;
    }
    return 0;
}

static int zmath_special_power(
    enum zmath_transcendental_kind kind,
    const zmath_target_format *format,
    uint64_t first_bits,
    uint64_t second_bits,
    mpfr_srcptr first,
    mpfr_srcptr second,
    int64_t exponent,
    uint64_t *bits_out,
    uint32_t *class_out
) {
    const int first_nan = zmath_is_nan(format, first_bits);
    const int second_nan = zmath_is_nan(format, second_bits);
    const int first_signaling = zmath_is_signaling_nan(format, first_bits);
    const int second_signaling = zmath_is_signaling_nan(format, second_bits);
    const int first_zero = zmath_is_zero(format, first_bits);
    const int second_zero = zmath_is_zero(format, second_bits);
    const int first_inf = zmath_is_inf(format, first_bits);
    const int second_inf = zmath_is_inf(format, second_bits);
    const int first_negative = zmath_is_negative(format, first_bits);
    int negative_result;
    int result_infinity;
    int comparison;

    if (kind == ZMATH_TR_POWN) {
        if (first_signaling) {
            *bits_out = zmath_quiet_nan(format, format, first_bits);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
        if (exponent == 0) {
            *bits_out = zmath_one(format);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
            return 1;
        }
        if (first_nan) {
            *bits_out = zmath_quiet_nan(format, format, first_bits);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
        if (first_zero || first_inf) {
            negative_result =
                first_negative && (exponent % 2 != 0);
            result_infinity = first_zero ? exponent < 0 : exponent > 0;
            if (result_infinity) {
                *bits_out = zmath_infinity(format, negative_result);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            } else {
                *bits_out = negative_result ? format->sign_mask : 0;
                *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            }
            return 1;
        }
        return 0;
    }

    if (kind == ZMATH_TR_COMPOUNDN) {
        if (first_signaling) {
            *bits_out = zmath_quiet_nan(format, format, first_bits);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
        if (!first_nan && mpfr_cmp_si(first, -1) < 0) {
            *bits_out = zmath_canonical_nan(format);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
        if (exponent == 0) {
            *bits_out = zmath_one(format);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
            return 1;
        }
        if (first_nan) {
            *bits_out = zmath_quiet_nan(format, format, first_bits);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
        if (first_bits == (format->sign_mask | zmath_one(format))) {
            if (exponent > 0) {
                *bits_out = 0;
                *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            } else {
                *bits_out = zmath_infinity(format, 0);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            }
            return 1;
        }
        if (first_bits == zmath_infinity(format, 0)) {
            if (exponent > 0) {
                *bits_out = zmath_infinity(format, 0);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            } else {
                *bits_out = 0;
                *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            }
            return 1;
        }
        return 0;
    }

    if (kind == ZMATH_TR_ROOTN) {
        if (exponent == 0) {
            *bits_out = zmath_canonical_nan(format);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
        if (first_nan) {
            *bits_out = zmath_quiet_nan(format, format, first_bits);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
        if (first_negative && !first_zero && exponent % 2 == 0) {
            *bits_out = zmath_canonical_nan(format);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
        if (first_zero || first_inf) {
            negative_result =
                first_negative && (exponent % 2 != 0);
            result_infinity = first_zero ? exponent < 0 : exponent > 0;
            if (result_infinity) {
                *bits_out = zmath_infinity(format, negative_result);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            } else {
                *bits_out = negative_result ? format->sign_mask : 0;
                *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            }
            return 1;
        }
        return 0;
    }

    if (kind != ZMATH_TR_POW && kind != ZMATH_TR_POWR) return 0;

    if (kind == ZMATH_TR_POW) {
        if (first_signaling || second_signaling) {
            *bits_out = zmath_quiet_nan(format, format, first_nan ? first_bits : second_bits);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
        if (first_bits == zmath_one(format) || second_zero) {
            *bits_out = zmath_one(format);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
            return 1;
        }
        if (first_bits == (format->sign_mask | zmath_one(format)) &&
            second_inf) {
            *bits_out = zmath_one(format);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
            return 1;
        }
    } else {
        if (!first_nan && !first_zero && first_negative) {
            *bits_out = zmath_canonical_nan(format);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
        if ((first_zero && second_zero) ||
            (first_bits == zmath_one(format) && second_inf) ||
            (first_inf && second_zero)) {
            *bits_out = zmath_canonical_nan(format);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
    }

    if ((first_nan || second_nan)) {
        *bits_out = zmath_quiet_nan(
            format,
            format,
            first_nan ? first_bits : second_bits
        );
        *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
        return 1;
    }

    if (kind == ZMATH_TR_POW && second_inf) {
        const int second_negative = mpfr_sgn(second) < 0;
        comparison = mpfr_cmpabs_ui(first, 1);
        if (comparison < 0) {
            result_infinity = second_negative;
        } else if (comparison > 0) {
            result_infinity = !second_negative;
        } else {
            *bits_out = zmath_one(format);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
            return 1;
        }
        if (result_infinity) {
            *bits_out = zmath_infinity(format, 0);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
        } else {
            *bits_out = 0;
            *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
        }
        return 1;
    }

    if (kind == ZMATH_TR_POW &&
        (first_zero || first_inf) &&
        mpfr_number_p(second) &&
        !second_zero) {
        negative_result =
            first_negative && zmath_integer_is_odd(second);
        result_infinity = first_zero ? mpfr_sgn(second) < 0 :
                                      mpfr_sgn(second) > 0;
        if (result_infinity) {
            *bits_out = zmath_infinity(format, negative_result);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
        } else {
            *bits_out = negative_result ? format->sign_mask : 0;
            *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
        }
        return 1;
    }

    if (kind == ZMATH_TR_POW &&
        !first_zero && !first_inf && first_negative &&
        mpfr_number_p(second) && !mpfr_integer_p(second)) {
        *bits_out = zmath_canonical_nan(format);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
        return 1;
    }
    return 0;
}
static int zmath_special_binary(
    enum zmath_transcendental_kind kind,
    const zmath_target_format *format,
    uint64_t first_bits,
    uint64_t second_bits,
    uint64_t *bits_out,
    uint32_t *class_out
) {
    const int first_nan = zmath_is_nan(format, first_bits);
    const int second_nan = zmath_is_nan(format, second_bits);

    if ((kind == ZMATH_TR_ATAN2 || kind == ZMATH_TR_ATAN2PI) &&
        (first_nan || second_nan)) {
        const uint64_t selected = first_nan ? first_bits : second_bits;
        *bits_out = zmath_quiet_nan(format, format, selected);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
        return 1;
    }
    return 0;
}

void zmath_testing_oracle_evaluate_mpfr_reference(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result
);

static void zmath_testing_oracle_evaluate_mpfr_arb_impl(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result,
    int require_proof
) {
    enum zmath_transcendental_kind kind;
    zmath_target_format input_format, output_format;
    mpfr_t first, second, output;
    uint64_t output_bits = 0;
    uint32_t output_class = ZMATH_TESTING_ORACLE_CLASS_NONE;
    int64_t exponent = 0;
    int lgamma_sign = 1;
    int special = 0;
    int nonfinite_special = 0;
    int second_is_float;
    int operation_arity;
    if (result == NULL) return;
    result->status = ZMATH_TESTING_ORACLE_UNSUPPORTED; result->field_count = 0;
    if (signature == NULL || request == NULL || result->fields == NULL ||
        request->input_fields == NULL || request->result_fields == NULL ||
        signature->arguments == NULL || signature->result_fields == NULL ||
        request->input_field_count != signature->arity ||
        request->result_field_count != signature->result_field_count ||
        result->field_capacity < signature->result_field_count ||
        request->result_layout != signature->result_layout ||
        request->structure_kind != signature->structure_kind ||
        !zmath_route_kind(signature, &kind) ||
        !zmath_format_from_descriptor(&signature->arguments[0], &input_format) ||
        !zmath_format_from_descriptor(&signature->result_fields[0], &output_format) ||
        input_format.width != output_format.width) return;
    operation_arity = (kind == ZMATH_TR_ATAN2 || kind == ZMATH_TR_ATAN2PI ||
                       kind == ZMATH_TR_POW || kind == ZMATH_TR_POWR ||
                       kind == ZMATH_TR_POWN || kind == ZMATH_TR_COMPOUNDN ||
                       kind == ZMATH_TR_ROOTN) ? 2 : 1;
    if (signature->arity != (uint32_t)operation_arity) return;
    second_is_float = kind == ZMATH_TR_ATAN2 ||
                      kind == ZMATH_TR_ATAN2PI ||
                      kind == ZMATH_TR_POW ||
                      kind == ZMATH_TR_POWR;
    if (kind == ZMATH_TR_LGAMMA &&
        (signature->structure_kind != ZMATH_TESTING_ORACLE_STRUCTURE_LGAMMA ||
         signature->result_field_count != 2)) return;
    if ((kind == ZMATH_TR_ATAN2 || kind == ZMATH_TR_ATAN2PI) &&
        (signature->structure_kind != ZMATH_TESTING_ORACLE_STRUCTURE_ATAN2 ||
         signature->result_field_count != 2)) return;
    if ((kind == ZMATH_TR_POWN || kind == ZMATH_TR_COMPOUNDN ||
         kind == ZMATH_TR_ROOTN) &&
        (signature->structure_kind != ZMATH_TESTING_ORACLE_STRUCTURE_POWER ||
         signature->result_field_count != 2)) return;
    if (kind == ZMATH_TR_POWN || kind == ZMATH_TR_COMPOUNDN ||
        kind == ZMATH_TR_ROOTN) {
        if (signature->arguments[1].kind !=
                ZMATH_TESTING_ORACLE_FIELD_SIGNED_INTEGER ||
            signature->arguments[1].value_bits != 64) return;
        exponent = (int64_t)request->input_fields[1].value_bits;
        if (exponent < -64 || exponent > 64) {
            output_bits = zmath_canonical_nan(&output_format);
            output_class = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            if (!zmath_write_pair(signature, result, output_bits, output_class, 0)) {
                result->status = ZMATH_TESTING_ORACLE_ERROR;
                return;
            }
            result->status = ZMATH_TESTING_ORACLE_OK;
            return;
        }
        if (kind == ZMATH_TR_ROOTN && exponent == 0) {
            output_bits = zmath_canonical_nan(&output_format);
            output_class = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            if (!zmath_write_pair(signature, result, output_bits, output_class, 1)) {
                result->status = ZMATH_TESTING_ORACLE_ERROR;
                return;
            }
            result->status = ZMATH_TESTING_ORACLE_OK;
            return;
        }
    }
    if (kind == ZMATH_TR_POWN || kind == ZMATH_TR_COMPOUNDN ||
        kind == ZMATH_TR_ROOTN) {
        nonfinite_special =
            zmath_is_zero(&input_format, request->input_fields[0].value_bits) ||
            zmath_is_inf(&input_format, request->input_fields[0].value_bits) ||
            (kind == ZMATH_TR_COMPOUNDN &&
             exponent < 0 &&
             request->input_fields[0].value_bits ==
                 (input_format.sign_mask | zmath_one(&input_format)));
    } else {
        nonfinite_special = operation_arity == 2 ?
            (zmath_is_zero(&input_format, request->input_fields[0].value_bits) ||
             zmath_is_zero(&input_format, request->input_fields[1].value_bits) ||
             zmath_is_inf(&input_format, request->input_fields[0].value_bits) ||
             zmath_is_inf(&input_format, request->input_fields[1].value_bits)) :
            zmath_is_inf(&input_format, request->input_fields[0].value_bits);
    }
    mpfr_init2(first, ZMATH_ORACLE_PRECISION); mpfr_init2(second, ZMATH_ORACLE_PRECISION); mpfr_init2(output, ZMATH_ORACLE_PRECISION);
    if (!zmath_decode_bits(
            first, &input_format, request->input_fields[0].value_bits
        ) ||
        (second_is_float &&
         !zmath_decode_bits(
             second, &input_format, request->input_fields[1].value_bits
         ))) {
        result->status = ZMATH_TESTING_ORACLE_ERROR;
        goto cleanup;
    }
    if (kind == ZMATH_TR_POWN || kind == ZMATH_TR_COMPOUNDN ||
        kind == ZMATH_TR_ROOTN || kind == ZMATH_TR_POW ||
        kind == ZMATH_TR_POWR) {
        special = zmath_special_power(
            kind,
            &input_format,
            request->input_fields[0].value_bits,
            second_is_float ? request->input_fields[1].value_bits : 0,
            first,
            second,
            exponent,
            &output_bits,
            &output_class
        );
    } else if (operation_arity == 2) {
        special = zmath_special_binary(
            kind, &input_format,
            request->input_fields[0].value_bits,
            request->input_fields[1].value_bits,
            &output_bits, &output_class
        );
    } else {
        special = zmath_special_pi_lattice(
            kind,
            &output_format,
            first,
            &output_bits,
            &output_class
        );
        if (!special) {
            special = zmath_special_unary(
                kind,
                &input_format,
                request->input_fields[0].value_bits,
                &output_bits,
                &output_class
            );
        }
    }
    if (!special) {
        if (!zmath_mpfr_eval(kind, output, first, second, exponent, &lgamma_sign)) {
            result->status = ZMATH_TESTING_ORACLE_ERROR;
            goto cleanup;
        }
        if (mpfr_nan_p(output)) {
            output_bits = zmath_canonical_nan(&output_format);
            output_class = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            special = 1;
        } else if (!zmath_encode(
                       &output_bits, &output_class, &output_format, output)) {
            result->status = ZMATH_TESTING_ORACLE_ERROR;
            goto cleanup;
        }
        if (kind == ZMATH_TR_ATAN2 &&
            (output_bits & ~output_format.sign_mask) != 0 &&
            zmath_prove_atan2_midpoint(kind, &output_format, first, second, output_bits - 1)) {
            const uint64_t magnitude = (--output_bits) & ~output_format.sign_mask;
            output_class = magnitude == 0 ? ZMATH_TESTING_ORACLE_CLASS_ZERO :
                magnitude <= output_format.fraction_mask ? ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL :
                ZMATH_TESTING_ORACLE_CLASS_NORMAL;
        }
        if (nonfinite_special) special = 1;
        if (!nonfinite_special && mpfr_inf_p(output) &&
            (kind == ZMATH_TR_LGAMMA || kind == ZMATH_TR_TGAMMA) &&
            mpfr_integer_p(first) && mpfr_sgn(first) < 0) {
            special = 1;
        }
    }
    if (kind == ZMATH_TR_LGAMMA) {
        if (zmath_is_zero(
                &input_format,
                request->input_fields[0].value_bits
            )) {
            lgamma_sign = zmath_is_negative(
                &input_format,
                request->input_fields[0].value_bits
            ) ? -1 : 1;
        } else if (mpfr_number_p(first) &&
                   mpfr_integer_p(first) &&
                   mpfr_sgn(first) < 0) {
            lgamma_sign = -1;
        }
    }
    if (require_proof && !special &&
        !zmath_prove(
            kind, &output_format, first, second, exponent, output_bits)) {
        result->status = ZMATH_TESTING_ORACLE_UNCERTAIN;
        goto cleanup;
    }
    if (kind == ZMATH_TR_LGAMMA) {
        if (!zmath_write_pair(signature, result, output_bits, output_class, lgamma_sign < 0 ? 3 : 1)) { result->status = ZMATH_TESTING_ORACLE_ERROR; goto cleanup; }
    } else if (kind == ZMATH_TR_ATAN2 || kind == ZMATH_TR_ATAN2PI || kind == ZMATH_TR_POWN || kind == ZMATH_TR_COMPOUNDN || kind == ZMATH_TR_ROOTN) {
        if (!zmath_write_pair(signature, result, output_bits, output_class, 1)) { result->status = ZMATH_TESTING_ORACLE_ERROR; goto cleanup; }
    } else if (!zmath_write_scalar(signature, result, output_bits, output_class)) { result->status = ZMATH_TESTING_ORACLE_ERROR; goto cleanup; }
    result->status = ZMATH_TESTING_ORACLE_OK;
cleanup:
    mpfr_clear(output); mpfr_clear(second); mpfr_clear(first);
}

void zmath_testing_oracle_evaluate_mpfr_reference(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result
) {
    zmath_testing_oracle_evaluate_mpfr_arb_impl(
        signature, request, result, 0);
}

void zmath_testing_oracle_evaluate_mpfr_arb(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result
) {
    zmath_testing_oracle_evaluate_mpfr_arb_impl(
        signature, request, result, 1);
}
