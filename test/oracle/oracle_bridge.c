#include "oracle_bridge.h"

#include <string.h>

#include <mpfr.h>
#include <flint/arb.h>

#define ZMATH_TESTING_ORACLE_PRECISION 512

typedef struct zmath_testing_target_format {
    unsigned width;
    unsigned exponent_bits;
    unsigned fraction_bits;
    unsigned bias;
    uint64_t sign_mask;
    uint64_t exponent_mask;
    uint64_t fraction_mask;
    uint64_t value_mask;
} zmath_testing_target_format;

static int zmath_testing_get_format(
    unsigned format,
    zmath_testing_target_format *target
) {
    unsigned width;
    unsigned exponent_bits;
    unsigned fraction_bits;
    unsigned bias;

    switch (format) {
        case ZMATH_TESTING_ORACLE_FORMAT_H:
            width = 16;
            exponent_bits = 5;
            fraction_bits = 10;
            bias = 15;
            break;
        case ZMATH_TESTING_ORACLE_FORMAT_F:
            width = 32;
            exponent_bits = 8;
            fraction_bits = 23;
            bias = 127;
            break;
        case ZMATH_TESTING_ORACLE_FORMAT_D:
            width = 64;
            exponent_bits = 11;
            fraction_bits = 52;
            bias = 1023;
            break;
        case ZMATH_TESTING_ORACLE_FORMAT_Q:
        default:
            return 0;
    }

    target->width = width;
    target->exponent_bits = exponent_bits;
    target->fraction_bits = fraction_bits;
    target->bias = bias;
    target->sign_mask = UINT64_C(1) << (width - 1);
    target->fraction_mask = (UINT64_C(1) << fraction_bits) - 1;
    target->exponent_mask =
        ((UINT64_C(1) << exponent_bits) - 1) << fraction_bits;
    target->value_mask =
        width == 64 ? UINT64_MAX : (UINT64_C(1) << width) - 1;
    return 1;
}

static int zmath_testing_operation_supported(const char *op) {
    return strcmp(op, "exp") == 0 || strcmp(op, "log") == 0 ||
           strcmp(op, "sin") == 0;
}

static int zmath_testing_validate_request(
    const char *op,
    unsigned format,
    const uint64_t *input_bits,
    size_t arity,
    const uint64_t *output_bits,
    const unsigned *output_class,
    zmath_testing_target_format *target
) {
    if (op == NULL || input_bits == NULL || arity != 1 ||
        output_bits == NULL || output_class == NULL) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    if (!zmath_testing_operation_supported(op) ||
        !zmath_testing_get_format(format, target)) {
        return ZMATH_TESTING_ORACLE_UNSUPPORTED;
    }
    if ((input_bits[0] & ~target->value_mask) != 0) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    return ZMATH_TESTING_ORACLE_OK;
}

static int zmath_testing_decode_bits(
    mpfr_t value,
    const zmath_testing_target_format *target,
    uint64_t bits
) {
    const uint64_t exponent =
        (bits & target->exponent_mask) >> target->fraction_bits;
    const uint64_t fraction = bits & target->fraction_mask;
    const uint64_t exponent_all =
        (UINT64_C(1) << target->exponent_bits) - 1;
    const int negative = (bits & target->sign_mask) != 0;
    mpfr_exp_t exponent_two;
    mpz_t significand;

    if ((bits & ~target->value_mask) != 0) {
        return 0;
    }

    if (exponent == exponent_all) {
        if (fraction == 0) {
            mpfr_set_inf(value, negative ? -1 : 1);
        } else {
            mpfr_set_nan(value);
        }
        return 1;
    }

    if (exponent == 0 && fraction == 0) {
        mpfr_set_zero(value, negative ? -1 : 1);
        return 1;
    }

    mpz_init_set_ui(significand, fraction);
    if (exponent == 0) {
        exponent_two = (mpfr_exp_t)1 - (mpfr_exp_t)target->bias -
                       (mpfr_exp_t)target->fraction_bits;
    } else {
        mpz_setbit(significand, target->fraction_bits);
        exponent_two = (mpfr_exp_t)exponent - (mpfr_exp_t)target->bias -
                       (mpfr_exp_t)target->fraction_bits;
    }

    mpfr_set_z_2exp(value, significand, exponent_two, MPFR_RNDN);
    if (negative) {
        mpfr_neg(value, value, MPFR_RNDN);
    }
    mpz_clear(significand);
    return 1;
}

static int zmath_testing_evaluate(
    mpfr_t result,
    const char *op,
    mpfr_srcptr input
) {
    if (strcmp(op, "exp") == 0) {
        mpfr_exp(result, input, MPFR_RNDN);
        return 1;
    }
    if (strcmp(op, "log") == 0) {
        mpfr_log(result, input, MPFR_RNDN);
        return 1;
    }
    if (strcmp(op, "sin") == 0) {
        mpfr_sin(result, input, MPFR_RNDN);
        return 1;
    }
    return 0;
}

static int zmath_testing_shift_is_usable(mpfr_exp_t shift) {
    return shift >= 0 &&
           (uintmax_t)shift <= (uintmax_t)((mp_bitcnt_t)-1);
}

/* Round a non-negative integer divided by 2^shift to nearest, ties to even. */
static int zmath_testing_round_right(
    mpz_t rounded,
    const mpz_t value,
    mpfr_exp_t shift
) {
    mpz_t remainder;
    mpz_t halfway;
    int comparison;

    if (shift <= 0) {
        mpfr_exp_t left = -(shift + 1) + 1;
        if (left < 0 || (uintmax_t)left > (uintmax_t)((mp_bitcnt_t)-1)) {
            return 0;
        }
        mpz_mul_2exp(rounded, value, (mp_bitcnt_t)left);
        return 1;
    }
    if (!zmath_testing_shift_is_usable(shift)) {
        return 0;
    }

    mpz_init(remainder);
    mpz_init(halfway);
    mpz_fdiv_q_2exp(rounded, value, (mp_bitcnt_t)shift);
    mpz_fdiv_r_2exp(remainder, value, (mp_bitcnt_t)shift);
    mpz_set_ui(halfway, 1);
    mpz_mul_2exp(halfway, halfway, (mp_bitcnt_t)(shift - 1));
    comparison = mpz_cmp(remainder, halfway);
    if (comparison > 0 || (comparison == 0 && mpz_odd_p(rounded))) {
        mpz_add_ui(rounded, rounded, 1);
    }
    mpz_clear(halfway);
    mpz_clear(remainder);
    return 1;
}

static uint64_t zmath_testing_nan_bits(
    const zmath_testing_target_format *target
) {
    return ((UINT64_C(1) << target->exponent_bits) - 1)
               << target->fraction_bits |
           (UINT64_C(1) << (target->fraction_bits - 1));
}
static uint64_t zmath_testing_quiet_nan_bits(
    const zmath_testing_target_format *target,
    uint64_t input_bits
) {
    return input_bits |
           (UINT64_C(1) << (target->fraction_bits - 1));
}

static uint64_t zmath_testing_one_bits(
    const zmath_testing_target_format *target
) {
    return (uint64_t)target->bias << target->fraction_bits;
}

static uint64_t zmath_testing_infinity_bits(
    const zmath_testing_target_format *target,
    int negative
) {
    const uint64_t exponent_all =
        (UINT64_C(1) << target->exponent_bits) - 1;
    return (negative ? target->sign_mask : 0) |
           (exponent_all << target->fraction_bits);
}

static int zmath_testing_special_result(
    uint64_t *bits_out,
    unsigned *class_out,
    const zmath_testing_target_format *target,
    const char *op,
    uint64_t input_bits
) {
    const uint64_t exponent =
        (input_bits & target->exponent_mask) >> target->fraction_bits;
    const uint64_t fraction = input_bits & target->fraction_mask;
    const uint64_t exponent_all =
        (UINT64_C(1) << target->exponent_bits) - 1;
    const uint64_t one_bits = zmath_testing_one_bits(target);
    const int negative = (input_bits & target->sign_mask) != 0;

    if (exponent == exponent_all && fraction != 0) {
        *bits_out = zmath_testing_quiet_nan_bits(target, input_bits);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
        return 1;
    }

    if (strcmp(op, "exp") == 0) {
        if (exponent == 0 && fraction == 0) {
            *bits_out = one_bits;
            *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
            return 1;
        }
        if (exponent == exponent_all) {
            if (negative) {
                *bits_out = 0;
                *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            } else {
                *bits_out = zmath_testing_infinity_bits(target, 0);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            }
            return 1;
        }
    }

    if (strcmp(op, "log") == 0) {
        if (exponent == 0 && fraction == 0) {
            *bits_out = zmath_testing_infinity_bits(target, 1);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            return 1;
        }
        if (input_bits == one_bits) {
            *bits_out = 0;
            *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            return 1;
        }
        if (exponent == exponent_all) {
            if (negative) {
                *bits_out = zmath_testing_nan_bits(target);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            } else {
                *bits_out = zmath_testing_infinity_bits(target, 0);
                *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            }
            return 1;
        }
        if (negative) {
            *bits_out = zmath_testing_nan_bits(target);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
    }

    if (strcmp(op, "sin") == 0) {
        if (exponent == 0 && fraction == 0) {
            *bits_out = input_bits;
            *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            return 1;
        }
        if (exponent == exponent_all) {
            *bits_out = zmath_testing_nan_bits(target);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
    }

    return 0;
}

static int zmath_testing_encode_result(
    uint64_t *bits_out,
    unsigned *class_out,
    const zmath_testing_target_format *target,
    mpfr_srcptr value
) {
    const uint64_t exponent_all =
        (UINT64_C(1) << target->exponent_bits) - 1;
    const uint64_t sign = mpfr_signbit(value) ? target->sign_mask : 0;
    const mpfr_exp_t minimum_normal =
        (mpfr_exp_t)1 - (mpfr_exp_t)target->bias;
    const mpfr_exp_t subnormal_unit =
        minimum_normal - (mpfr_exp_t)target->fraction_bits;
    const unsigned precision = target->fraction_bits + 1;
    mpz_t significand;
    mpz_t magnitude;
    mpz_t rounded;
    mpz_t limit;
    mpfr_exp_t exponent_two;
    mpfr_exp_t unbiased;
    mpfr_exp_t shift;
    size_t bit_length;
    uint64_t exponent_field;
    uint64_t fraction_field;

    if (mpfr_nan_p(value)) {
        *bits_out = zmath_testing_nan_bits(target);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
        return 1;
    }
    if (mpfr_inf_p(value)) {
        *bits_out = sign | (exponent_all << target->fraction_bits);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
        return 1;
    }
    if (mpfr_zero_p(value)) {
        *bits_out = sign;
        *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
        return 1;
    }

    mpz_init(significand);
    mpz_init(magnitude);
    mpz_init(rounded);
    mpz_init(limit);
    exponent_two = mpfr_get_z_2exp(significand, value);
    mpz_abs(magnitude, significand);
    bit_length = mpz_sizeinbase(magnitude, 2);
    unbiased = exponent_two + (mpfr_exp_t)bit_length - 1;
    mpz_set_ui(limit, 1);
    mpz_mul_2exp(limit, limit, precision);

    if (unbiased >= minimum_normal) {
        shift = (mpfr_exp_t)bit_length - (mpfr_exp_t)precision;
        if (!zmath_testing_round_right(rounded, magnitude, shift)) {
            goto error;
        }
        if (mpz_cmp(rounded, limit) >= 0) {
            mpz_fdiv_q_2exp(rounded, rounded, 1);
            ++unbiased;
        }
        if (unbiased > (mpfr_exp_t)target->bias) {
            *bits_out = sign | (exponent_all << target->fraction_bits);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            goto success;
        }

        mpz_fdiv_q_2exp(limit, limit, 1);
        mpz_sub(rounded, rounded, limit);
        exponent_field = (uint64_t)(unbiased + (mpfr_exp_t)target->bias);
        fraction_field = (uint64_t)mpz_get_ui(rounded);
        *bits_out = sign | (exponent_field << target->fraction_bits) |
                    fraction_field;
        *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
        goto success;
    }

    shift = subnormal_unit - exponent_two;
    if (!zmath_testing_round_right(rounded, magnitude, shift)) {
        goto error;
    }
    mpz_set_ui(limit, 1);
    mpz_mul_2exp(limit, limit, target->fraction_bits);
    if (mpz_cmp(rounded, limit) >= 0) {
        *bits_out = sign | (UINT64_C(1) << target->fraction_bits);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
        goto success;
    }
    fraction_field = (uint64_t)mpz_get_ui(rounded);
    *bits_out = sign | fraction_field;
    *class_out = fraction_field == 0 ? ZMATH_TESTING_ORACLE_CLASS_ZERO
                                     : ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL;

success:
    mpz_clear(limit);
    mpz_clear(rounded);
    mpz_clear(magnitude);
    mpz_clear(significand);
    return 1;

error:
    mpz_clear(limit);
    mpz_clear(rounded);
    mpz_clear(magnitude);
    mpz_clear(significand);
    return 0;
}

int zmath_testing_mpfr_reference(
    const char *op,
    unsigned format,
    const uint64_t *input_bits,
    size_t arity,
    uint64_t *output_bits,
    unsigned *output_class
) {
    zmath_testing_target_format target;
    mpfr_t input;
    mpfr_t result;
    int status;

    status = zmath_testing_validate_request(
        op, format, input_bits, arity, output_bits, output_class, &target);
    if (status != ZMATH_TESTING_ORACLE_OK) {
        return status;
    }
    if (zmath_testing_special_result(
            output_bits, output_class, &target, op, input_bits[0])) {
        return ZMATH_TESTING_ORACLE_OK;
    }

    mpfr_init2(input, ZMATH_TESTING_ORACLE_PRECISION);
    mpfr_init2(result, ZMATH_TESTING_ORACLE_PRECISION);
    if (!zmath_testing_decode_bits(input, &target, input_bits[0]) ||
        !zmath_testing_evaluate(result, op, input) ||
        !zmath_testing_encode_result(output_bits, output_class, &target, result)) {
        mpfr_clear(result);
        mpfr_clear(input);
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    mpfr_clear(result);
    mpfr_clear(input);
    return ZMATH_TESTING_ORACLE_OK;
}

static uint64_t zmath_testing_next_up(
    const zmath_testing_target_format *target,
    uint64_t bits
) {
    const uint64_t sign = bits & target->sign_mask;
    const uint64_t magnitude = bits & ~target->sign_mask;

    if (magnitude == 0) {
        return 1;
    }
    if (sign != 0) {
        return bits - 1;
    }
    return bits + 1;
}

static uint64_t zmath_testing_next_down(
    const zmath_testing_target_format *target,
    uint64_t bits
) {
    const uint64_t sign = bits & target->sign_mask;
    const uint64_t magnitude = bits & ~target->sign_mask;

    if (magnitude == 0) {
        return target->sign_mask | 1;
    }
    if (sign != 0) {
        return bits + 1;
    }
    return bits - 1;
}

static int zmath_testing_midpoint(
    mpfr_t midpoint,
    const zmath_testing_target_format *target,
    uint64_t left_bits,
    uint64_t right_bits
) {
    mpfr_t left;
    mpfr_t right;

    mpfr_init2(left, 1024);
    mpfr_init2(right, 1024);
    if (!zmath_testing_decode_bits(left, target, left_bits) ||
        !zmath_testing_decode_bits(right, target, right_bits)) {
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

int zmath_testing_arb_prove_rounding(
    const char *op,
    unsigned format,
    const uint64_t *input_bits,
    size_t arity,
    uint64_t candidate_bits,
    unsigned *output_class
) {
    zmath_testing_target_format target;
    mpfr_t input;
    mpfr_t lower;
    mpfr_t upper;
    mpfr_t lower_boundary;
    mpfr_t upper_boundary;
    arb_t arb_input;
    arb_t arb_result;
    uint64_t expected_bits;
    unsigned expected_class;
    uint64_t lower_bits;
    uint64_t upper_bits;
    uint64_t exponent;
    uint64_t exponent_all;
    int status;
    int proof;

    status = zmath_testing_validate_request(
        op, format, input_bits, arity, &candidate_bits, output_class, &target);
    if (status != ZMATH_TESTING_ORACLE_OK) {
        return status;
    }
    if ((candidate_bits & ~target.value_mask) != 0) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }

    status = zmath_testing_mpfr_reference(
        op, format, input_bits, arity, &expected_bits, &expected_class);
    if (status != ZMATH_TESTING_ORACLE_OK || expected_bits != candidate_bits) {
        return ZMATH_TESTING_ORACLE_UNCERTAIN;
    }

    exponent_all = (UINT64_C(1) << target.exponent_bits) - 1;
    exponent = (candidate_bits & target.exponent_mask) >> target.fraction_bits;
    if (exponent == exponent_all ||
        (exponent == exponent_all - 1 &&
         (candidate_bits & target.fraction_mask) == target.fraction_mask)) {
        /*
         * Arb intervals do not carry a proof for NaN, infinity, or the
         * finite-to-infinity overflow boundary.
         */
        return ZMATH_TESTING_ORACLE_UNCERTAIN;
    }
    mpfr_init2(input, ZMATH_TESTING_ORACLE_PRECISION);
    mpfr_init2(lower, ZMATH_TESTING_ORACLE_PRECISION);
    mpfr_init2(upper, ZMATH_TESTING_ORACLE_PRECISION);
    mpfr_init2(lower_boundary, 1024);
    mpfr_init2(upper_boundary, 1024);
    arb_init(arb_input);
    arb_init(arb_result);

    if (!zmath_testing_decode_bits(input, &target, input_bits[0]) ||
        !mpfr_number_p(input)) {
        proof = 0;
        goto cleanup;
    }

    arb_set_interval_mpfr(arb_input, input, input, ZMATH_TESTING_ORACLE_PRECISION);
    if (strcmp(op, "exp") == 0) {
        arb_exp(arb_result, arb_input, ZMATH_TESTING_ORACLE_PRECISION);
    } else if (strcmp(op, "log") == 0) {
        arb_log(arb_result, arb_input, ZMATH_TESTING_ORACLE_PRECISION);
    } else if (strcmp(op, "sin") == 0) {
        arb_sin(arb_result, arb_input, ZMATH_TESTING_ORACLE_PRECISION);
    } else {
        proof = 0;
        goto cleanup;
    }
    if (!arb_is_finite(arb_result)) {
        proof = 0;
        goto cleanup;
    }
    arb_get_interval_mpfr(lower, upper, arb_result);

    lower_bits = zmath_testing_next_down(&target, candidate_bits);
    upper_bits = zmath_testing_next_up(&target, candidate_bits);
    if (!zmath_testing_midpoint(
            lower_boundary, &target, lower_bits, candidate_bits) ||
        !zmath_testing_midpoint(
            upper_boundary, &target, candidate_bits, upper_bits)) {
        proof = 0;
        goto cleanup;
    }
    proof = mpfr_cmp(lower, lower_boundary) > 0 &&
            mpfr_cmp(upper, upper_boundary) < 0;
cleanup:
    arb_clear(arb_result);
    arb_clear(arb_input);
    mpfr_clear(upper_boundary);
    mpfr_clear(lower_boundary);
    mpfr_clear(upper);
    mpfr_clear(lower);
    mpfr_clear(input);
    if (!proof) {
        return ZMATH_TESTING_ORACLE_UNCERTAIN;
    }
    *output_class = expected_class;
    return ZMATH_TESTING_ORACLE_OK;
}
