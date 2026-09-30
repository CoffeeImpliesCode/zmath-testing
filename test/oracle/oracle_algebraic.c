#include "oracle_evaluators.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <gmp.h>
#include <mpfr.h>

#include <flint/arb.h>

#define ZMATH_TESTING_ALGEBRAIC_PRECISION 512
#define ZMATH_TESTING_ALGEBRAIC_BOUNDARY_PRECISION 1024

typedef struct zmath_testing_algebraic_format {
    uint32_t code;
    unsigned width;
    unsigned exponent_bits;
    unsigned fraction_bits;
    unsigned bias;
    uint64_t sign_mask;
    uint64_t exponent_mask;
    uint64_t fraction_mask;
    uint64_t value_mask;
} zmath_testing_algebraic_format;

typedef enum zmath_testing_algebraic_kernel {
    ZMATH_TESTING_ALGEBRAIC_CBRt,
    ZMATH_TESTING_ALGEBRAIC_ADD,
    ZMATH_TESTING_ALGEBRAIC_DIV,
    ZMATH_TESTING_ALGEBRAIC_FMA,
    ZMATH_TESTING_ALGEBRAIC_MUL,
    ZMATH_TESTING_ALGEBRAIC_SQRT,
    ZMATH_TESTING_ALGEBRAIC_SUB,
    ZMATH_TESTING_ALGEBRAIC_HYPOT,
    ZMATH_TESTING_ALGEBRAIC_RSQRT,
    ZMATH_TESTING_ALGEBRAIC_INVALID,
} zmath_testing_algebraic_kernel;

typedef struct zmath_testing_algebraic_value {
    uint64_t bits;
    uint64_t exponent;
    uint64_t fraction;
    int negative;
    int nan;
    int infinity;
    int zero;
} zmath_testing_algebraic_value;

static void zmath_testing_algebraic_initialize_result(
    zmath_testing_oracle_result *result
) {
    if (result != NULL) {
        result->status = ZMATH_TESTING_ORACLE_ERROR;
        result->field_count = 0;
    }
}

static int zmath_testing_algebraic_operation_is(
    const zmath_testing_oracle_operation_signature *signature,
    const char *operation
) {
    const size_t operation_length = strlen(operation);
    return signature != NULL && signature->operation != NULL &&
           signature->operation_length == operation_length &&
           memcmp(signature->operation, operation, operation_length) == 0;
}

static zmath_testing_algebraic_kernel zmath_testing_algebraic_kernel_for(
    const zmath_testing_oracle_operation_signature *signature
) {
    static const struct {
        const char *operation;
        zmath_testing_algebraic_kernel kernel;
    } kernels[] = {
        { "cbrt", ZMATH_TESTING_ALGEBRAIC_CBRt },
        { "fadd", ZMATH_TESTING_ALGEBRAIC_ADD },
        { "f16addf32", ZMATH_TESTING_ALGEBRAIC_ADD },
        { "f16addf64", ZMATH_TESTING_ALGEBRAIC_ADD },
        { "f32addf64", ZMATH_TESTING_ALGEBRAIC_ADD },
        { "fdiv", ZMATH_TESTING_ALGEBRAIC_DIV },
        { "f16divf32", ZMATH_TESTING_ALGEBRAIC_DIV },
        { "f16divf64", ZMATH_TESTING_ALGEBRAIC_DIV },
        { "f32divf64", ZMATH_TESTING_ALGEBRAIC_DIV },
        { "ffma", ZMATH_TESTING_ALGEBRAIC_FMA },
        { "f16fmaf32", ZMATH_TESTING_ALGEBRAIC_FMA },
        { "f16fmaf64", ZMATH_TESTING_ALGEBRAIC_FMA },
        { "f32fmaf64", ZMATH_TESTING_ALGEBRAIC_FMA },
        { "fma", ZMATH_TESTING_ALGEBRAIC_FMA },
        { "fmul", ZMATH_TESTING_ALGEBRAIC_MUL },
        { "f16mulf32", ZMATH_TESTING_ALGEBRAIC_MUL },
        { "f16mulf64", ZMATH_TESTING_ALGEBRAIC_MUL },
        { "f32mulf64", ZMATH_TESTING_ALGEBRAIC_MUL },
        { "fsqrt", ZMATH_TESTING_ALGEBRAIC_SQRT },
        { "f16sqrtf32", ZMATH_TESTING_ALGEBRAIC_SQRT },
        { "f16sqrtf64", ZMATH_TESTING_ALGEBRAIC_SQRT },
        { "f32sqrtf64", ZMATH_TESTING_ALGEBRAIC_SQRT },
        { "fsub", ZMATH_TESTING_ALGEBRAIC_SUB },
        { "f16subf32", ZMATH_TESTING_ALGEBRAIC_SUB },
        { "f16subf64", ZMATH_TESTING_ALGEBRAIC_SUB },
        { "f32subf64", ZMATH_TESTING_ALGEBRAIC_SUB },
        { "hypot", ZMATH_TESTING_ALGEBRAIC_HYPOT },
        { "rsqrt", ZMATH_TESTING_ALGEBRAIC_RSQRT },
        { "sqrt", ZMATH_TESTING_ALGEBRAIC_SQRT },
    };
    size_t index;

    if (signature == NULL) return ZMATH_TESTING_ALGEBRAIC_INVALID;
    for (index = 0; index < sizeof(kernels) / sizeof(kernels[0]); ++index) {
        if (zmath_testing_algebraic_operation_is(
                signature, kernels[index].operation))
        {
            return kernels[index].kernel;
        }
    }
    return ZMATH_TESTING_ALGEBRAIC_INVALID;
}

static int zmath_testing_algebraic_format_from_descriptor(
    const zmath_testing_oracle_format_descriptor *descriptor,
    zmath_testing_algebraic_format *format
) {
    unsigned width;
    unsigned exponent_bits;
    unsigned fraction_bits;
    unsigned bias;

    if (descriptor == NULL || format == NULL || descriptor->reserved != 0) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    switch (descriptor->code) {
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
        default:
            return ZMATH_TESTING_ORACLE_UNSUPPORTED;
    }
    if (descriptor->storage_bits != width ||
        descriptor->exponent_bits != exponent_bits ||
        descriptor->fraction_bits != fraction_bits)
    {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    format->code = descriptor->code;
    format->width = width;
    format->exponent_bits = exponent_bits;
    format->fraction_bits = fraction_bits;
    format->bias = bias;
    format->sign_mask = UINT64_C(1) << (width - 1);
    format->fraction_mask = (UINT64_C(1) << fraction_bits) - 1;
    format->exponent_mask =
        ((UINT64_C(1) << exponent_bits) - 1) << fraction_bits;
    format->value_mask = width == 64 ? UINT64_MAX :
        (UINT64_C(1) << width) - 1;
    return ZMATH_TESTING_ORACLE_OK;
}

static int zmath_testing_algebraic_descriptor_equal(
    const zmath_testing_oracle_field_descriptor *left,
    const zmath_testing_oracle_field_descriptor *right
) {
    if (left == NULL || right == NULL) return 0;
    return left->kind == right->kind && left->value_bits == right->value_bits &&
           left->format.code == right->format.code &&
           left->format.storage_bits == right->format.storage_bits &&
           left->format.exponent_bits == right->format.exponent_bits &&
           left->format.fraction_bits == right->format.fraction_bits &&
           left->format.reserved == right->format.reserved &&
           left->reserved == right->reserved;
}

static int zmath_testing_algebraic_request_is_valid(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result,
    zmath_testing_algebraic_format *source,
    zmath_testing_algebraic_format *destination,
    zmath_testing_algebraic_kernel *kernel
) {
    uint32_t index;
    int status;
    zmath_testing_algebraic_format input_format;

    if (signature == NULL || request == NULL || result == NULL ||
        source == NULL || destination == NULL || kernel == NULL)
    {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    if (result->reserved != 0 || request->reserved != 0 ||
        request->abi_version != ZMATH_TESTING_ORACLE_ABI_VERSION)
    {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    if (signature->evaluator_category !=
        ZMATH_TESTING_ORACLE_EVALUATOR_ALGEBRAIC)
    {
        return ZMATH_TESTING_ORACLE_UNSUPPORTED;
    }
    if (signature->provenance != ZMATH_TESTING_ORACLE_PROVENANCE_C23_7_12 &&
        signature->provenance != ZMATH_TESTING_ORACLE_PROVENANCE_ANNEX_H)
    {
        return ZMATH_TESTING_ORACLE_UNSUPPORTED;
    }
    if (zmath_testing_oracle_find_operation_signature(request) != signature) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    if (request->operation == NULL || signature->operation == NULL ||
        request->operation_length != signature->operation_length ||
        request->arity != signature->arity ||
        request->input_field_count != signature->arity ||
        request->input_fields == NULL || request->result_fields == NULL ||
        request->result_layout != ZMATH_TESTING_ORACLE_RESULT_SCALAR ||
        request->structure_kind != ZMATH_TESTING_ORACLE_STRUCTURE_NONE ||
        request->result_field_count != 1 || signature->result_field_count != 1 ||
        signature->arguments == NULL || signature->result_fields == NULL)
    {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    if (memcmp(
            request->operation,
            signature->operation,
            signature->operation_length) != 0)
    {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    if (request->arity == 0 || request->arity > 3) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    status = zmath_testing_algebraic_format_from_descriptor(
        &request->input_fields[0].descriptor.format, source);
    if (status != ZMATH_TESTING_ORACLE_OK) return status;
    for (index = 0; index < request->arity; ++index) {
        if (!zmath_testing_algebraic_descriptor_equal(
                &request->input_fields[index].descriptor,
                &signature->arguments[index]) ||
            request->input_fields[index].reserved != 0 ||
            request->input_fields[index].tag_bytes != NULL ||
            request->input_fields[index].tag_length != 0)
        {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
        if (request->input_fields[index].descriptor.kind !=
            ZMATH_TESTING_ORACLE_FIELD_FLOAT)
        {
            return ZMATH_TESTING_ORACLE_UNSUPPORTED;
        }
        status = zmath_testing_algebraic_format_from_descriptor(
            &request->input_fields[index].descriptor.format, &input_format);
        if (status != ZMATH_TESTING_ORACLE_OK) return status;
        if (index > 0 && input_format.code != source->code) {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
        if ((request->input_fields[index].value_bits & ~source->value_mask) != 0) {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
    }
    if (!zmath_testing_algebraic_descriptor_equal(
            &request->result_fields[0], &signature->result_fields[0]) ||
        request->result_fields[0].kind != ZMATH_TESTING_ORACLE_FIELD_FLOAT)
    {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    status = zmath_testing_algebraic_format_from_descriptor(
        &request->result_fields[0].format, destination);
    if (status != ZMATH_TESTING_ORACLE_OK) return status;
    if (request->result_fields[0].value_bits != destination->width ||
        result->field_capacity < 1 || result->fields == NULL)
    {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    *kernel = zmath_testing_algebraic_kernel_for(signature);
    if (*kernel == ZMATH_TESTING_ALGEBRAIC_INVALID) {
        return ZMATH_TESTING_ORACLE_UNSUPPORTED;
    }
    return ZMATH_TESTING_ORACLE_OK;
}

static void zmath_testing_algebraic_decode_value(
    const zmath_testing_algebraic_format *format,
    uint64_t bits,
    zmath_testing_algebraic_value *value
) {
    const uint64_t exponent =
        (bits & format->exponent_mask) >> format->fraction_bits;
    const uint64_t exponent_all =
        (UINT64_C(1) << format->exponent_bits) - 1;

    value->bits = bits;
    value->exponent = exponent;
    value->fraction = bits & format->fraction_mask;
    value->negative = (bits & format->sign_mask) != 0;
    value->nan = exponent == exponent_all && value->fraction != 0;
    value->infinity = exponent == exponent_all && value->fraction == 0;
    value->zero = exponent == 0 && value->fraction == 0;
}

static uint64_t zmath_testing_algebraic_canonical_nan(
    const zmath_testing_algebraic_format *format
) {
    const uint64_t exponent_all =
        (UINT64_C(1) << format->exponent_bits) - 1;
    return (exponent_all << format->fraction_bits) |
           (UINT64_C(1) << (format->fraction_bits - 1));
}

static uint64_t zmath_testing_algebraic_quiet_nan(
    const zmath_testing_algebraic_format *source,
    const zmath_testing_algebraic_format *destination,
    uint64_t bits
) {
    uint64_t payload = bits & source->fraction_mask;
    const uint64_t exponent_all =
        (UINT64_C(1) << destination->exponent_bits) - 1;

    if (destination->fraction_bits > source->fraction_bits) {
        payload <<= destination->fraction_bits - source->fraction_bits;
    } else {
        payload >>= source->fraction_bits - destination->fraction_bits;
    }
    payload &= destination->fraction_mask;
    payload |= UINT64_C(1) << (destination->fraction_bits - 1);
    return (bits & source->sign_mask ? destination->sign_mask : 0) |
           (exponent_all << destination->fraction_bits) | payload;
}

static uint64_t zmath_testing_algebraic_infinity(
    const zmath_testing_algebraic_format *format,
    int negative
) {
    const uint64_t exponent_all =
        (UINT64_C(1) << format->exponent_bits) - 1;
    return (negative ? format->sign_mask : 0) |
           (exponent_all << format->fraction_bits);
}

static uint64_t zmath_testing_algebraic_zero(
    const zmath_testing_algebraic_format *format,
    int negative
) {
    return negative ? format->sign_mask : 0;
}

static int zmath_testing_algebraic_decode_mpfr(
    mpfr_t value,
    const zmath_testing_algebraic_format *format,
    uint64_t bits
) {
    zmath_testing_algebraic_value decoded;
    mpz_t significand;
    mpfr_exp_t exponent_two;

    zmath_testing_algebraic_decode_value(format, bits, &decoded);
    if (decoded.nan) {
        mpfr_set_nan(value);
        return 1;
    }
    if (decoded.infinity) {
        mpfr_set_inf(value, decoded.negative ? -1 : 1);
        return 1;
    }
    if (decoded.zero) {
        mpfr_set_zero(value, decoded.negative ? -1 : 1);
        return 1;
    }
    mpz_init_set_ui(significand, decoded.fraction);
    if (decoded.exponent == 0) {
        exponent_two = (mpfr_exp_t)1 - (mpfr_exp_t)format->bias -
                       (mpfr_exp_t)format->fraction_bits;
    } else {
        mpz_setbit(significand, format->fraction_bits);
        exponent_two = (mpfr_exp_t)decoded.exponent -
                       (mpfr_exp_t)format->bias -
                       (mpfr_exp_t)format->fraction_bits;
    }
    mpfr_set_z_2exp(value, significand, exponent_two, MPFR_RNDN);
    if (decoded.negative) mpfr_neg(value, value, MPFR_RNDN);
    mpz_clear(significand);
    return 1;
}

static int zmath_testing_algebraic_round_right(
    mpz_t rounded,
    const mpz_t value,
    mpfr_exp_t shift
) {
    mpz_t remainder;
    mpz_t halfway;
    int comparison;

    if (shift <= 0) {
        if (-shift < 0 ||
            (uintmax_t)(-shift) > (uintmax_t)((mp_bitcnt_t)-1))
        {
            return 0;
        }
        mpz_mul_2exp(rounded, value, (mp_bitcnt_t)(-shift));
        return 1;
    }
    if ((uintmax_t)shift > (uintmax_t)((mp_bitcnt_t)-1)) return 0;
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
/*
 * The finite inputs of the dyadic kernels are exact binary rationals.  Keep
 * that fact through the operation and round the resulting GMP rational only
 * once at the destination.  MPFR at the working precision is not sufficient
 * for this path: an exponent gap can move every sticky bit below bit 512.
 */
static int zmath_testing_algebraic_round_ratio(
    mpz_t rounded,
    const mpz_t numerator,
    const mpz_t denominator,
    int64_t shift
) {
    mpz_t scaled_numerator;
    mpz_t scaled_denominator;
    mpz_t remainder;
    mpz_t twice_remainder;

    if (shift >= 0) {
        if ((uintmax_t)shift > (uintmax_t)((mp_bitcnt_t)-1)) return 0;
    } else if ((uintmax_t)(-shift) > (uintmax_t)((mp_bitcnt_t)-1)) {
        return 0;
    }
    mpz_init_set(scaled_numerator, numerator);
    mpz_init_set(scaled_denominator, denominator);
    if (shift >= 0) {
        mpz_mul_2exp(
            scaled_numerator,
            scaled_numerator,
            (mp_bitcnt_t)shift
        );
    } else {
        mpz_mul_2exp(
            scaled_denominator,
            scaled_denominator,
            (mp_bitcnt_t)(-shift)
        );
    }
    mpz_init(remainder);
    mpz_init(twice_remainder);
    mpz_fdiv_qr(rounded, remainder, scaled_numerator, scaled_denominator);
    mpz_mul_2exp(twice_remainder, remainder, 1);
    if (mpz_cmp(twice_remainder, scaled_denominator) > 0 ||
        (mpz_cmp(twice_remainder, scaled_denominator) == 0 &&
         mpz_odd_p(rounded)))
    {
        mpz_add_ui(rounded, rounded, 1);
    }
    mpz_clear(twice_remainder);
    mpz_clear(remainder);
    mpz_clear(scaled_denominator);
    mpz_clear(scaled_numerator);
    return 1;
}

static int zmath_testing_algebraic_ratio_from_bits(
    mpq_t value,
    const zmath_testing_algebraic_format *format,
    uint64_t bits
) {
    zmath_testing_algebraic_value decoded;
    mpz_t significand;
    int64_t exponent_two;

    zmath_testing_algebraic_decode_value(format, bits, &decoded);
    if (decoded.nan || decoded.infinity) return 0;
    mpz_init_set_ui(significand, decoded.fraction);
    if (decoded.exponent == 0) {
        exponent_two = (int64_t)1 - (int64_t)format->bias -
                       (int64_t)format->fraction_bits;
    } else {
        mpz_setbit(significand, format->fraction_bits);
        exponent_two = (int64_t)decoded.exponent -
                       (int64_t)format->bias -
                       (int64_t)format->fraction_bits;
    }
    mpq_set_z(value, significand);
    if (exponent_two >= 0) {
        mpz_mul_2exp(
            mpq_numref(value),
            mpq_numref(value),
            (mp_bitcnt_t)exponent_two
        );
    } else {
        mpz_mul_2exp(
            mpq_denref(value),
            mpq_denref(value),
            (mp_bitcnt_t)(-exponent_two)
        );
    }
    if (decoded.negative) mpq_neg(value, value);
    mpq_canonicalize(value);
    mpz_clear(significand);
    return 1;
}

static int zmath_testing_algebraic_encode_rational(
    uint64_t *bits_out,
    uint32_t *class_out,
    const zmath_testing_algebraic_format *format,
    const mpq_t value,
    int negative_zero
) {
    int64_t minimum_normal;
    int64_t maximum_normal;
    unsigned precision;
    mpz_t numerator;
    mpz_t denominator;
    mpz_t scaled_numerator;
    mpz_t scaled_denominator;
    mpz_t rounded;
    mpz_t limit;
    int64_t unbiased;
    int64_t shift;
    int comparison;
    int negative;
    size_t numerator_bits;
    size_t denominator_bits;
    uint64_t fraction;
    uint64_t exponent_field;
    uint64_t sign;

    if (bits_out == NULL || class_out == NULL || format == NULL) return 0;
    minimum_normal = (int64_t)1 - (int64_t)format->bias;
    maximum_normal = (int64_t)format->bias;
    precision = format->fraction_bits + 1;
    if (mpq_sgn(value) == 0) {
        *bits_out = negative_zero ? format->sign_mask : 0;
        *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
        return 1;
    }
    negative = mpq_sgn(value) < 0;
    sign = negative ? format->sign_mask : 0;
    mpz_init(numerator);
    mpz_init(denominator);
    mpz_init(scaled_numerator);
    mpz_init(scaled_denominator);
    mpz_init(rounded);
    mpz_init(limit);
    mpz_abs(numerator, mpq_numref(value));
    mpz_set(denominator, mpq_denref(value));
    numerator_bits = mpz_sizeinbase(numerator, 2);
    denominator_bits = mpz_sizeinbase(denominator, 2);
    unbiased = (int64_t)numerator_bits - (int64_t)denominator_bits;
    mpz_set(scaled_numerator, numerator);
    mpz_set(scaled_denominator, denominator);
    if (unbiased >= 0) {
        mpz_mul_2exp(
            scaled_denominator,
            scaled_denominator,
            (mp_bitcnt_t)unbiased
        );
        comparison = mpz_cmp(numerator, scaled_denominator);
    } else {
        mpz_mul_2exp(
            scaled_numerator,
            scaled_numerator,
            (mp_bitcnt_t)(-unbiased)
        );
        comparison = mpz_cmp(scaled_numerator, denominator);
    }
    if (comparison < 0) --unbiased;

    if (unbiased >= minimum_normal) {
        shift = (int64_t)format->fraction_bits - unbiased;
        if (!zmath_testing_algebraic_round_ratio(
                rounded, numerator, denominator, shift))
        {
            goto error;
        }
        mpz_set_ui(limit, 1);
        mpz_mul_2exp(limit, limit, precision);
        if (mpz_cmp(rounded, limit) >= 0) {
            mpz_fdiv_q_2exp(rounded, rounded, 1);
            ++unbiased;
        }
        if (unbiased > maximum_normal) {
            *bits_out = sign | zmath_testing_algebraic_infinity(format, 0);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            goto success;
        }
        mpz_fdiv_q_2exp(limit, limit, 1);
        mpz_sub(rounded, rounded, limit);
        exponent_field = (uint64_t)(unbiased + (int64_t)format->bias);
        fraction = (uint64_t)mpz_get_ui(rounded);
        *bits_out = sign | (exponent_field << format->fraction_bits) |
                    fraction;
        *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
        goto success;
    }

    shift = (int64_t)format->fraction_bits - minimum_normal;
    if (!zmath_testing_algebraic_round_ratio(
            rounded, numerator, denominator, shift))
    {
        goto error;
    }
    mpz_set_ui(limit, 1);
    mpz_mul_2exp(limit, limit, format->fraction_bits);
    if (mpz_cmp(rounded, limit) >= 0) {
        *bits_out = sign | (UINT64_C(1) << format->fraction_bits);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
        goto success;
    }
    fraction = (uint64_t)mpz_get_ui(rounded);
    *bits_out = sign | fraction;
    *class_out = fraction == 0 ? ZMATH_TESTING_ORACLE_CLASS_ZERO :
                                 ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL;
success:
    mpz_clear(limit);
    mpz_clear(rounded);
    mpz_clear(scaled_denominator);
    mpz_clear(scaled_numerator);
    mpz_clear(denominator);
    mpz_clear(numerator);
    return 1;
error:
    mpz_clear(limit);
    mpz_clear(rounded);
    mpz_clear(scaled_denominator);
    mpz_clear(scaled_numerator);
    mpz_clear(denominator);
    mpz_clear(numerator);
    return 0;
}

static int zmath_testing_algebraic_exact_kernel(
    zmath_testing_algebraic_kernel kernel
) {
    return kernel == ZMATH_TESTING_ALGEBRAIC_ADD ||
           kernel == ZMATH_TESTING_ALGEBRAIC_SUB ||
           kernel == ZMATH_TESTING_ALGEBRAIC_MUL ||
           kernel == ZMATH_TESTING_ALGEBRAIC_DIV ||
           kernel == ZMATH_TESTING_ALGEBRAIC_FMA;
}

static int zmath_testing_algebraic_exact_result(
    uint64_t *bits_out,
    uint32_t *class_out,
    const zmath_testing_algebraic_format *source,
    const zmath_testing_algebraic_format *destination,
    zmath_testing_algebraic_kernel kernel,
    const zmath_testing_oracle_request *request
) {
    mpq_t inputs[3];
    mpq_t product;
    mpq_t value;
    uint32_t index;
    int negative_zero = 0;
    int first_negative;
    int second_negative;
    int product_negative;
    int success = 0;

    for (index = 0; index < request->arity; ++index) mpq_init(inputs[index]);
    mpq_init(product);
    mpq_init(value);
    for (index = 0; index < request->arity; ++index) {
        if (!zmath_testing_algebraic_ratio_from_bits(
                inputs[index],
                source,
                request->input_fields[index].value_bits))
        {
            goto cleanup;
        }
    }
    switch (kernel) {
        case ZMATH_TESTING_ALGEBRAIC_ADD:
            mpq_add(value, inputs[0], inputs[1]);
            break;
        case ZMATH_TESTING_ALGEBRAIC_SUB:
            mpq_sub(value, inputs[0], inputs[1]);
            break;
        case ZMATH_TESTING_ALGEBRAIC_MUL:
            mpq_mul(value, inputs[0], inputs[1]);
            break;
        case ZMATH_TESTING_ALGEBRAIC_DIV:
            mpq_div(value, inputs[0], inputs[1]);
            break;
        case ZMATH_TESTING_ALGEBRAIC_FMA:
            mpq_mul(product, inputs[0], inputs[1]);
            mpq_add(value, product, inputs[2]);
            break;
        default:
            goto cleanup;
    }
    if (mpq_sgn(value) == 0) {
        first_negative =
            (request->input_fields[0].value_bits & source->sign_mask) != 0;
        second_negative =
            (request->input_fields[1].value_bits & source->sign_mask) != 0;
        if (kernel == ZMATH_TESTING_ALGEBRAIC_SUB) second_negative = !second_negative;
        if (kernel == ZMATH_TESTING_ALGEBRAIC_FMA) {
            product_negative = first_negative != second_negative;
            negative_zero = product_negative &&
                            ((request->input_fields[2].value_bits &
                              source->sign_mask) != 0);
        } else {
            negative_zero = first_negative && second_negative;
        }
    }
    success = zmath_testing_algebraic_encode_rational(
        bits_out,
        class_out,
        destination,
        value,
        negative_zero
    );
cleanup:
    mpq_clear(value);
    mpq_clear(product);
    for (index = 0; index < request->arity; ++index) mpq_clear(inputs[index]);
    return success;
}


static int zmath_testing_algebraic_encode_finite(
    uint64_t *bits_out,
    uint32_t *class_out,
    const zmath_testing_algebraic_format *format,
    mpfr_srcptr value
) {
    const mpfr_exp_t minimum_normal =
        (mpfr_exp_t)1 - (mpfr_exp_t)format->bias;
    const mpfr_exp_t subnormal_unit =
        minimum_normal - (mpfr_exp_t)format->fraction_bits;
    const unsigned precision = format->fraction_bits + 1;
    mpfr_exp_t exponent_two;
    mpfr_exp_t unbiased;
    mpfr_exp_t shift;
    mpz_t significand;
    mpz_t magnitude;
    mpz_t rounded;
    mpz_t limit;
    size_t bit_length;
    uint64_t exponent_field;
    uint64_t fraction_field;
    uint64_t sign;

    if (!mpfr_number_p(value)) return 0;
    sign = mpfr_signbit(value) ? format->sign_mask : 0;
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
        if (!zmath_testing_algebraic_round_right(rounded, magnitude, shift)) {
            goto error;
        }
        if (mpz_cmp(rounded, limit) >= 0) {
            mpz_fdiv_q_2exp(rounded, rounded, 1);
            ++unbiased;
        }
        if (unbiased > (mpfr_exp_t)format->bias) {
            *bits_out = sign | zmath_testing_algebraic_infinity(format, 0);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            goto success;
        }
        mpz_fdiv_q_2exp(limit, limit, 1);
        mpz_sub(rounded, rounded, limit);
        exponent_field = (uint64_t)(unbiased + (mpfr_exp_t)format->bias);
        fraction_field = (uint64_t)mpz_get_ui(rounded);
        *bits_out = sign | (exponent_field << format->fraction_bits) |
                    fraction_field;
        *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
        goto success;
    }
    shift = subnormal_unit - exponent_two;
    if (!zmath_testing_algebraic_round_right(rounded, magnitude, shift)) goto error;
    mpz_set_ui(limit, 1);
    mpz_mul_2exp(limit, limit, format->fraction_bits);
    if (mpz_cmp(rounded, limit) >= 0) {
        *bits_out = sign | (UINT64_C(1) << format->fraction_bits);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_NORMAL;
        goto success;
    }
    fraction_field = (uint64_t)mpz_get_ui(rounded);
    *bits_out = sign | fraction_field;
    *class_out = fraction_field == 0 ? ZMATH_TESTING_ORACLE_CLASS_ZERO :
                                       ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL;
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

static uint64_t zmath_testing_algebraic_next_up(
    const zmath_testing_algebraic_format *format,
    uint64_t bits
) {
    if (bits == zmath_testing_algebraic_infinity(format, 0)) return bits;
    if ((bits & format->sign_mask) != 0) {
        if (bits == format->sign_mask) return 0;
        return bits - 1;
    }
    return bits + 1;
}

static uint64_t zmath_testing_algebraic_next_down(
    const zmath_testing_algebraic_format *format,
    uint64_t bits
) {
    if (bits == zmath_testing_algebraic_infinity(format, 1)) return bits;
    if ((bits & format->sign_mask) != 0) return bits + 1;
    if (bits == 0) return format->sign_mask;
    return bits - 1;
}

static int zmath_testing_algebraic_midpoint(
    mpfr_t midpoint,
    const zmath_testing_algebraic_format *format,
    uint64_t left_bits,
    uint64_t right_bits
) {
    mpfr_t left;
    mpfr_t right;

    mpfr_init2(left, ZMATH_TESTING_ALGEBRAIC_BOUNDARY_PRECISION);
    mpfr_init2(right, ZMATH_TESTING_ALGEBRAIC_BOUNDARY_PRECISION);
    if (!zmath_testing_algebraic_decode_mpfr(left, format, left_bits) ||
        !zmath_testing_algebraic_decode_mpfr(right, format, right_bits))
    {
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

static int zmath_testing_algebraic_overflow_boundary(
    mpfr_t boundary,
    const zmath_testing_algebraic_format *format
) {
    const mpfr_exp_t exponent = (mpfr_exp_t)format->bias + 1;
    const mpfr_exp_t half_ulp_exponent =
        (mpfr_exp_t)format->bias - (mpfr_exp_t)format->fraction_bits - 1;
    mpfr_t power;
    mpfr_t half_ulp;

    mpfr_init2(power, ZMATH_TESTING_ALGEBRAIC_BOUNDARY_PRECISION);
    mpfr_init2(half_ulp, ZMATH_TESTING_ALGEBRAIC_BOUNDARY_PRECISION);
    mpfr_set_ui(power, 1, MPFR_RNDN);
    mpfr_mul_2si(power, power, exponent, MPFR_RNDN);
    mpfr_set_ui(half_ulp, 1, MPFR_RNDN);
    mpfr_mul_2si(half_ulp, half_ulp, half_ulp_exponent, MPFR_RNDN);
    mpfr_sub(boundary, power, half_ulp, MPFR_RNDN);
    mpfr_clear(half_ulp);
    mpfr_clear(power);
    return 1;
}

static void zmath_testing_algebraic_underflow_boundary(
    mpfr_t boundary,
    const zmath_testing_algebraic_format *format
) {
    const mpfr_exp_t exponent =
        (mpfr_exp_t)1 - (mpfr_exp_t)format->bias -
        (mpfr_exp_t)format->fraction_bits - 1;
    mpfr_set_ui(boundary, 1, MPFR_RNDN);
    mpfr_mul_2si(boundary, boundary, exponent, MPFR_RNDN);
}

static int zmath_testing_algebraic_prove_rounding_cell(
    const zmath_testing_algebraic_format *format,
    uint64_t candidate_bits,
    uint32_t candidate_class,
    const arb_t arb_result
) {
    mpfr_t lower;
    mpfr_t upper;
    mpfr_t lower_boundary;
    mpfr_t upper_boundary;
    uint64_t previous_bits;
    uint64_t next_bits;
    int candidate_even;
    int proved = 0;

    if (!arb_is_finite(arb_result)) return 0;
    mpfr_init2(lower, ZMATH_TESTING_ALGEBRAIC_BOUNDARY_PRECISION);
    mpfr_init2(upper, ZMATH_TESTING_ALGEBRAIC_BOUNDARY_PRECISION);
    mpfr_init2(lower_boundary, ZMATH_TESTING_ALGEBRAIC_BOUNDARY_PRECISION);
    mpfr_init2(upper_boundary, ZMATH_TESTING_ALGEBRAIC_BOUNDARY_PRECISION);
    arb_get_interval_mpfr(lower, upper, arb_result);

    if (candidate_class == ZMATH_TESTING_ORACLE_CLASS_ZERO) {
        int upper_comparison;
        int lower_comparison;

        candidate_even =
            (candidate_bits & format->fraction_mask & UINT64_C(1)) == 0;
        zmath_testing_algebraic_underflow_boundary(upper_boundary, format);
        if ((candidate_bits & format->sign_mask) == 0) {
            upper_comparison = mpfr_cmp(upper, upper_boundary);
            proved = mpfr_cmp_si(lower, 0) >= 0 &&
                     (upper_comparison < 0 ||
                      (upper_comparison == 0 && candidate_even));
        } else {
            mpfr_neg(upper_boundary, upper_boundary, MPFR_RNDN);
            lower_comparison = mpfr_cmp(lower, upper_boundary);
            proved = (lower_comparison > 0 ||
                      (lower_comparison == 0 && candidate_even)) &&
                     mpfr_cmp_si(upper, 0) <= 0;
        }
        goto cleanup;
    }
    if (candidate_class == ZMATH_TESTING_ORACLE_CLASS_INFINITY) {
        int comparison;

        zmath_testing_algebraic_overflow_boundary(lower_boundary, format);
        if ((candidate_bits & format->sign_mask) == 0) {
            comparison = mpfr_cmp(lower, lower_boundary);
            proved = comparison > 0 || comparison == 0;
        } else {
            mpfr_neg(lower_boundary, lower_boundary, MPFR_RNDN);
            comparison = mpfr_cmp(upper, lower_boundary);
            proved = comparison < 0 || comparison == 0;
        }
        goto cleanup;
    }
    if (candidate_class != ZMATH_TESTING_ORACLE_CLASS_NORMAL &&
        candidate_class != ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL)
    {
        goto cleanup;
    }
    previous_bits = zmath_testing_algebraic_next_down(format, candidate_bits);
    next_bits = zmath_testing_algebraic_next_up(format, candidate_bits);
    if (previous_bits == zmath_testing_algebraic_infinity(format, 1)) {
        zmath_testing_algebraic_overflow_boundary(lower_boundary, format);
        mpfr_neg(lower_boundary, lower_boundary, MPFR_RNDN);
    } else if (!zmath_testing_algebraic_midpoint(
                   lower_boundary, format, previous_bits, candidate_bits))
    {
        goto cleanup;
    }
    if (next_bits == zmath_testing_algebraic_infinity(format, 0)) {
        zmath_testing_algebraic_overflow_boundary(upper_boundary, format);
    } else if (!zmath_testing_algebraic_midpoint(
                   upper_boundary, format, candidate_bits, next_bits))
    {
        goto cleanup;
    }
    candidate_even =
        (candidate_bits & format->fraction_mask & UINT64_C(1)) == 0;
    {
        const int lower_comparison = mpfr_cmp(lower, lower_boundary);
        const int upper_comparison = mpfr_cmp(upper, upper_boundary);
        proved = (lower_comparison > 0 ||
                  (lower_comparison == 0 && candidate_even)) &&
                 (upper_comparison < 0 ||
                  (upper_comparison == 0 && candidate_even));
    }
cleanup:
    mpfr_clear(upper_boundary);
    mpfr_clear(lower_boundary);
    mpfr_clear(upper);
    mpfr_clear(lower);
    return proved;
}

static int zmath_testing_algebraic_result_field(
    zmath_testing_oracle_result_field *field,
    const zmath_testing_oracle_field_descriptor *descriptor,
    uint64_t bits,
    uint32_t class_code
) {
    if (field == NULL || descriptor == NULL) return 0;
    field->descriptor = *descriptor;
    field->value_bits = bits;
    field->class_code = class_code;
    field->reserved = 0;
    return 1;
}

static int zmath_testing_algebraic_special_unary(
    uint64_t *bits_out,
    uint32_t *class_out,
    zmath_testing_algebraic_kernel kernel,
    const zmath_testing_algebraic_format *source,
    const zmath_testing_algebraic_format *destination,
    const zmath_testing_algebraic_value *input
) {
    if (input->nan) {
        *bits_out = zmath_testing_algebraic_quiet_nan(
            source, destination, input->bits);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
        return 1;
    }
    if (kernel == ZMATH_TESTING_ALGEBRAIC_CBRt) {
        if (input->infinity) {
            *bits_out = zmath_testing_algebraic_infinity(destination,
                                                          input->negative);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            return 1;
        }
        if (input->zero) {
            *bits_out = zmath_testing_algebraic_zero(destination, input->negative);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            return 1;
        }
        return 0;
    }
    if (kernel == ZMATH_TESTING_ALGEBRAIC_SQRT) {
        if (input->zero) {
            *bits_out = zmath_testing_algebraic_zero(destination, input->negative);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            return 1;
        }
        if (input->infinity && !input->negative) {
            *bits_out = zmath_testing_algebraic_infinity(destination, 0);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            return 1;
        }
        if (input->negative) {
            *bits_out = zmath_testing_algebraic_canonical_nan(destination);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
        return 0;
    }
    if (kernel == ZMATH_TESTING_ALGEBRAIC_RSQRT) {
        if (input->zero) {
            *bits_out = zmath_testing_algebraic_infinity(destination,
                                                          input->negative);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            return 1;
        }
        if (input->infinity && !input->negative) {
            *bits_out = zmath_testing_algebraic_zero(destination, 0);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            return 1;
        }
        if (input->negative) {
            *bits_out = zmath_testing_algebraic_canonical_nan(destination);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
        return 0;
    }
    return 0;
}

static int zmath_testing_algebraic_special_binary(
    uint64_t *bits_out,
    uint32_t *class_out,
    zmath_testing_algebraic_kernel kernel,
    const zmath_testing_algebraic_format *source,
    const zmath_testing_algebraic_format *destination,
    const zmath_testing_algebraic_value *first,
    const zmath_testing_algebraic_value *second
) {
    int second_negative;
    int product_negative;

    if (kernel == ZMATH_TESTING_ALGEBRAIC_HYPOT) {
        const uint64_t quiet_bit = UINT64_C(1) << (source->fraction_bits - 1);
        const int first_signaling = first->nan && (first->bits & quiet_bit) == 0;
        const int second_signaling = second->nan && (second->bits & quiet_bit) == 0;
        if ((first->infinity || second->infinity) && !first_signaling && !second_signaling) {
            *bits_out = zmath_testing_algebraic_infinity(destination, 0);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            return 1;
        }
        if (first->nan) {
            *bits_out = zmath_testing_algebraic_quiet_nan(
                source, destination, first->bits);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
        if (second->nan) {
            *bits_out = zmath_testing_algebraic_quiet_nan(
                source, destination, second->bits);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
        return 0;
    }
    if (first->nan) {
        *bits_out = zmath_testing_algebraic_quiet_nan(
            source, destination, first->bits);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
        return 1;
    }
    if (second->nan) {
        *bits_out = zmath_testing_algebraic_quiet_nan(
            source, destination, second->bits);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
        return 1;
    }
    second_negative = second->negative;
    if (kernel == ZMATH_TESTING_ALGEBRAIC_SUB) second_negative = !second_negative;
    if (kernel == ZMATH_TESTING_ALGEBRAIC_ADD ||
        kernel == ZMATH_TESTING_ALGEBRAIC_SUB)
    {
        if (first->infinity && second->infinity &&
            first->negative != second_negative)
        {
            *bits_out = zmath_testing_algebraic_canonical_nan(destination);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
        if (first->infinity) {
            *bits_out = zmath_testing_algebraic_infinity(destination,
                                                          first->negative);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            return 1;
        }
        if (second->infinity) {
            *bits_out = zmath_testing_algebraic_infinity(destination,
                                                          second_negative);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            return 1;
        }
        if (first->zero && second->zero) {
            *bits_out = zmath_testing_algebraic_zero(
                destination, first->negative && second_negative);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            return 1;
        }
        return 0;
    }
    if (kernel == ZMATH_TESTING_ALGEBRAIC_MUL) {
        product_negative = first->negative != second->negative;
        if ((first->infinity && second->zero) ||
            (first->zero && second->infinity))
        {
            *bits_out = zmath_testing_algebraic_canonical_nan(destination);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
        if (first->infinity || second->infinity) {
            *bits_out = zmath_testing_algebraic_infinity(destination,
                                                          product_negative);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            return 1;
        }
        if (first->zero || second->zero) {
            *bits_out = zmath_testing_algebraic_zero(destination,
                                                      product_negative);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            return 1;
        }
        return 0;
    }
    if (kernel == ZMATH_TESTING_ALGEBRAIC_DIV) {
        product_negative = first->negative != second->negative;
        if ((first->zero && second->zero) ||
            (first->infinity && second->infinity))
        {
            *bits_out = zmath_testing_algebraic_canonical_nan(destination);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            return 1;
        }
        if (first->infinity) {
            *bits_out = zmath_testing_algebraic_infinity(destination,
                                                          product_negative);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            return 1;
        }
        if (second->infinity) {
            *bits_out = zmath_testing_algebraic_zero(destination,
                                                      product_negative);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            return 1;
        }
        if (second->zero) {
            *bits_out = zmath_testing_algebraic_infinity(destination,
                                                          product_negative);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
            return 1;
        }
        if (first->zero) {
            *bits_out = zmath_testing_algebraic_zero(destination,
                                                      product_negative);
            *class_out = ZMATH_TESTING_ORACLE_CLASS_ZERO;
            return 1;
        }
        return 0;
    }
    return 0;
}


static int zmath_testing_algebraic_special_ternary(
    uint64_t *bits_out,
    uint32_t *class_out,
    const zmath_testing_algebraic_format *source,
    const zmath_testing_algebraic_format *destination,
    const zmath_testing_algebraic_value *first,
    const zmath_testing_algebraic_value *second,
    const zmath_testing_algebraic_value *third
) {
    int product_negative;
    int product_infinite;

    if (first->nan) {
        *bits_out = zmath_testing_algebraic_quiet_nan(
            source, destination, first->bits);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
        return 1;
    }
    if (second->nan) {
        *bits_out = zmath_testing_algebraic_quiet_nan(
            source, destination, second->bits);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
        return 1;
    }
    if (third->nan) {
        *bits_out = zmath_testing_algebraic_quiet_nan(
            source, destination, third->bits);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
        return 1;
    }
    product_negative = first->negative != second->negative;
    product_infinite = (first->infinity && !second->zero) ||
                       (second->infinity && !first->zero);
    if ((first->infinity && second->zero) ||
        (first->zero && second->infinity))
    {
        *bits_out = zmath_testing_algebraic_canonical_nan(destination);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
        return 1;
    }
    if (product_infinite && third->infinity &&
        product_negative != third->negative)
    {
        *bits_out = zmath_testing_algebraic_canonical_nan(destination);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_QNAN;
        return 1;
    }
    if (product_infinite) {
        *bits_out = zmath_testing_algebraic_infinity(destination,
                                                      product_negative);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
        return 1;
    }
    if (third->infinity) {
        *bits_out = zmath_testing_algebraic_infinity(destination,
                                                      third->negative);
        *class_out = ZMATH_TESTING_ORACLE_CLASS_INFINITY;
        return 1;
    }
    return 0;
}

static int zmath_testing_algebraic_compute_mpfr(
    mpfr_t output,
    zmath_testing_algebraic_kernel kernel,
    mpfr_t *inputs,
    uint32_t arity
) {
    if (inputs == NULL || arity == 0) return 0;
    switch (kernel) {
        case ZMATH_TESTING_ALGEBRAIC_CBRt:
            if (arity != 1) return 0;
            mpfr_cbrt(output, inputs[0], MPFR_RNDN);
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_ADD:
            if (arity != 2) return 0;
            mpfr_add(output, inputs[0], inputs[1], MPFR_RNDN);
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_DIV:
            if (arity != 2) return 0;
            mpfr_div(output, inputs[0], inputs[1], MPFR_RNDN);
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_FMA:
            if (arity != 3) return 0;
            mpfr_fma(output, inputs[0], inputs[1], inputs[2], MPFR_RNDN);
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_MUL:
            if (arity != 2) return 0;
            mpfr_mul(output, inputs[0], inputs[1], MPFR_RNDN);
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_SQRT:
            if (arity != 1) return 0;
            mpfr_sqrt(output, inputs[0], MPFR_RNDN);
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_SUB:
            if (arity != 2) return 0;
            mpfr_sub(output, inputs[0], inputs[1], MPFR_RNDN);
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_HYPOT:
            if (arity != 2) return 0;
            mpfr_hypot(output, inputs[0], inputs[1], MPFR_RNDN);
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_RSQRT:
            if (arity != 1) return 0;
            mpfr_rec_sqrt(output, inputs[0], MPFR_RNDN);
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_INVALID:
            return 0;
    }
    return 0;
}

static int zmath_testing_algebraic_compute_arb(
    arb_t output,
    zmath_testing_algebraic_kernel kernel,
    arb_t *inputs,
    uint32_t arity
) {
    if (inputs == NULL || arity == 0) return 0;
    switch (kernel) {
        case ZMATH_TESTING_ALGEBRAIC_CBRt:
            if (arity != 1) return 0;
            if (arb_is_negative(inputs[0])) {
                arb_neg(output, inputs[0]);
                arb_root_ui(output, output, 3, ZMATH_TESTING_ALGEBRAIC_PRECISION);
                arb_neg(output, output);
            } else {
                arb_root_ui(output, inputs[0], 3, ZMATH_TESTING_ALGEBRAIC_PRECISION);
            }
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_ADD:
            if (arity != 2) return 0;
            arb_add(output, inputs[0], inputs[1], ZMATH_TESTING_ALGEBRAIC_PRECISION);
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_DIV:
            if (arity != 2) return 0;
            arb_div(output, inputs[0], inputs[1], ZMATH_TESTING_ALGEBRAIC_PRECISION);
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_FMA:
            if (arity != 3) return 0;
            arb_set(output, inputs[2]);
            arb_addmul(output, inputs[0], inputs[1], ZMATH_TESTING_ALGEBRAIC_PRECISION);
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_MUL:
            if (arity != 2) return 0;
            arb_mul(output, inputs[0], inputs[1], ZMATH_TESTING_ALGEBRAIC_PRECISION);
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_SQRT:
            if (arity != 1) return 0;
            arb_sqrt(output, inputs[0], ZMATH_TESTING_ALGEBRAIC_PRECISION);
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_SUB:
            if (arity != 2) return 0;
            arb_sub(output, inputs[0], inputs[1], ZMATH_TESTING_ALGEBRAIC_PRECISION);
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_HYPOT:
            if (arity != 2) return 0;
            arb_hypot(output, inputs[0], inputs[1], ZMATH_TESTING_ALGEBRAIC_PRECISION);
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_RSQRT:
            if (arity != 1) return 0;
            arb_rsqrt(output, inputs[0], ZMATH_TESTING_ALGEBRAIC_PRECISION);
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_INVALID:
            return 0;
    }
    return 0;
}

static int zmath_testing_algebraic_finite_result(
    uint64_t *bits_out,
    uint32_t *class_out,
    const zmath_testing_algebraic_format *source,
    const zmath_testing_algebraic_format *destination,
    zmath_testing_algebraic_kernel kernel,
    const zmath_testing_oracle_request *request,
    int require_proof
) {
    mpfr_t mpfr_inputs[3];
    mpfr_t mpfr_output;
    arb_t arb_inputs[3];
    arb_t arb_output;
    uint32_t index;
    uint32_t initialized_mpfr = 0;
    uint32_t initialized_arb = 0;
    int success = 0;

    /*
     * This is exact algebraic evidence, not a 512-bit approximation.  The
     * table remains on the ALGEBRAIC route because the operation still
     * belongs to the algebraic evaluator family.
     */
    if (zmath_testing_algebraic_exact_kernel(kernel)) {
        return zmath_testing_algebraic_exact_result(
            bits_out,
            class_out,
            source,
            destination,
            kernel,
            request
        );
    }

    for (index = 0; index < request->arity; ++index) {
        mpfr_init2(mpfr_inputs[index], ZMATH_TESTING_ALGEBRAIC_PRECISION);
        ++initialized_mpfr;
        arb_init(arb_inputs[index]);
        ++initialized_arb;
        if (!zmath_testing_algebraic_decode_mpfr(
                mpfr_inputs[index],
                source,
                request->input_fields[index].value_bits
            ) ||
            !mpfr_number_p(mpfr_inputs[index]))
        {
            goto cleanup_inputs;
        }
        arb_set_interval_mpfr(
            arb_inputs[index],
            mpfr_inputs[index],
            mpfr_inputs[index],
            ZMATH_TESTING_ALGEBRAIC_PRECISION
        );
    }
    mpfr_init2(mpfr_output, ZMATH_TESTING_ALGEBRAIC_PRECISION);
    arb_init(arb_output);
    if (!zmath_testing_algebraic_compute_mpfr(
            mpfr_output,
            kernel,
            mpfr_inputs,
            request->arity
        ) ||
        !zmath_testing_algebraic_encode_finite(
            bits_out,
            class_out,
            destination,
            mpfr_output
        ))
    {
        arb_clear(arb_output);
        mpfr_clear(mpfr_output);
        goto cleanup_inputs;
    }
    if (!require_proof) {
        success = 1;
        arb_clear(arb_output);
        mpfr_clear(mpfr_output);
        goto cleanup_inputs;
    }
    if (!zmath_testing_algebraic_compute_arb(
            arb_output,
            kernel,
            arb_inputs,
            request->arity
        ) ||
        !zmath_testing_algebraic_prove_rounding_cell(
            destination,
            *bits_out,
            *class_out,
            arb_output
        ))
    {
        arb_clear(arb_output);
        mpfr_clear(mpfr_output);
        goto cleanup_inputs;
    }
    success = 1;
    arb_clear(arb_output);
    mpfr_clear(mpfr_output);
cleanup_inputs:
    while (initialized_arb > 0) {
        --initialized_arb;
        arb_clear(arb_inputs[initialized_arb]);
    }
    while (initialized_mpfr > 0) {
        --initialized_mpfr;
        mpfr_clear(mpfr_inputs[initialized_mpfr]);
    }
    return success;
}
/*
 * ---------------------------------------------------------------------------
 * Compound references for the five non-scalar algebraic rows
 *
 * Every operation below shares one shape: a row of same-format float inputs,
 * an exact GMP rational for each primitive, and a rounding back to the target
 * format at the end of every primitive. Carrying one exact rational through
 * the whole graph would be a different operation, not a more accurate one.
 * A product that rounds before the addition beside it is the arithmetic these
 * rows describe, so zmath_testing_algebraic_graph_step returns target bits and
 * the next primitive decodes those bits again.
 * ---------------------------------------------------------------------------
 */

#define ZMATH_TESTING_ALGEBRAIC_GEOMETRY_COORDINATES 6u
#define ZMATH_TESTING_ALGEBRAIC_GEOMETRY_TAG_INDEX 6u

typedef enum zmath_testing_algebraic_graph {
    ZMATH_TESTING_ALGEBRAIC_GRAPH_NONE = 0,
    ZMATH_TESTING_ALGEBRAIC_GRAPH_COMPLEX_ADD,
    ZMATH_TESTING_ALGEBRAIC_GRAPH_COMPLEX_MUL,
    ZMATH_TESTING_ALGEBRAIC_GRAPH_MATRIX_DET2,
    ZMATH_TESTING_ALGEBRAIC_GRAPH_LU_SOLVE2,
    ZMATH_TESTING_ALGEBRAIC_GRAPH_GEOMETRY_ORIENT2
} zmath_testing_algebraic_graph;

typedef enum zmath_testing_algebraic_policy {
    ZMATH_TESTING_ALGEBRAIC_POLICY_UNKNOWN = 0,
    ZMATH_TESTING_ALGEBRAIC_POLICY_ADAPTIVE_EXACT,
    ZMATH_TESTING_ALGEBRAIC_POLICY_FAST
} zmath_testing_algebraic_policy;

/*
 * The spelling names WHICH operation this is and nothing else. Arity, input
 * kinds, formats, result fields, layout, and provenance all come from the
 * immutable table row that the request is matched against below.
 */
static zmath_testing_algebraic_graph zmath_testing_algebraic_graph_for(
    const zmath_testing_oracle_operation_signature *signature
) {
    static const struct {
        const char *operation;
        zmath_testing_algebraic_graph graph;
    } graphs[] = {
        { "complexAdd", ZMATH_TESTING_ALGEBRAIC_GRAPH_COMPLEX_ADD },
        { "complexMul", ZMATH_TESTING_ALGEBRAIC_GRAPH_COMPLEX_MUL },
        { "geometryOrient2", ZMATH_TESTING_ALGEBRAIC_GRAPH_GEOMETRY_ORIENT2 },
        { "luSolve2", ZMATH_TESTING_ALGEBRAIC_GRAPH_LU_SOLVE2 },
        { "matrixDet2", ZMATH_TESTING_ALGEBRAIC_GRAPH_MATRIX_DET2 }
    };
    size_t index;

    if (signature == NULL) return ZMATH_TESTING_ALGEBRAIC_GRAPH_NONE;
    for (index = 0; index < sizeof(graphs) / sizeof(graphs[0]); ++index) {
        if (zmath_testing_algebraic_operation_is(
                signature, graphs[index].operation))
        {
            return graphs[index].graph;
        }
    }
    return ZMATH_TESTING_ALGEBRAIC_GRAPH_NONE;
}

/*
 * The declared shape of each row. result_floats is the length of the float
 * prefix of the result. A row may carry one trailer field after it, and that
 * field is a boolean for a solve and a signed 32-bit integer for a sign.
 */
static int zmath_testing_algebraic_graph_shape(
    zmath_testing_algebraic_graph graph,
    uint32_t *arity,
    uint32_t *float_inputs,
    uint32_t *result_floats,
    uint32_t *layout,
    uint32_t *structure,
    uint32_t *result_fields
) {
    if (arity == NULL || float_inputs == NULL || result_floats == NULL ||
        layout == NULL || structure == NULL || result_fields == NULL)
    {
        return 0;
    }
    switch (graph) {
        case ZMATH_TESTING_ALGEBRAIC_GRAPH_COMPLEX_ADD:
        case ZMATH_TESTING_ALGEBRAIC_GRAPH_COMPLEX_MUL:
            *arity = 4u;
            *float_inputs = 4u;
            *result_floats = 2u;
            *layout = ZMATH_TESTING_ORACLE_RESULT_STRUCTURE;
            *structure = ZMATH_TESTING_ORACLE_STRUCTURE_COMPLEX;
            *result_fields = 2u;
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_GRAPH_MATRIX_DET2:
            *arity = 4u;
            *float_inputs = 4u;
            *result_floats = 1u;
            *layout = ZMATH_TESTING_ORACLE_RESULT_SCALAR;
            *structure = ZMATH_TESTING_ORACLE_STRUCTURE_NONE;
            *result_fields = 1u;
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_GRAPH_LU_SOLVE2:
            *arity = 6u;
            *float_inputs = 6u;
            *result_floats = 2u;
            *layout = ZMATH_TESTING_ORACLE_RESULT_STRUCTURE;
            *structure = ZMATH_TESTING_ORACLE_STRUCTURE_LU_SOLVE;
            *result_fields = 3u;
            return 1;
        case ZMATH_TESTING_ALGEBRAIC_GRAPH_GEOMETRY_ORIENT2:
            *arity = 7u;
            *float_inputs = ZMATH_TESTING_ALGEBRAIC_GEOMETRY_COORDINATES;
            *result_floats = 0u;
            *layout = ZMATH_TESTING_ORACLE_RESULT_SCALAR;
            *structure = ZMATH_TESTING_ORACLE_STRUCTURE_NONE;
            *result_fields = 1u;
            return 1;
        default:
            return 0;
    }
}

/*
 * The policy text of a geometry request. An unknown spelling names no
 * reference at all, so it is refused instead of being read as one of the two
 * known policies or as an absent policy.
 */
static int zmath_testing_algebraic_policy_from_bytes(
    const uint8_t *bytes,
    uint32_t length,
    zmath_testing_algebraic_policy *policy
) {
    static const uint8_t adaptive_exact[] = "adaptive_exact";
    static const uint8_t fast[] = "fast";

    if (policy == NULL) return ZMATH_TESTING_ORACLE_ERROR;
    *policy = ZMATH_TESTING_ALGEBRAIC_POLICY_UNKNOWN;
    if (bytes == NULL) return ZMATH_TESTING_ORACLE_UNSUPPORTED;
    if (length == sizeof(adaptive_exact) - 1u &&
        memcmp(bytes, adaptive_exact, sizeof(adaptive_exact) - 1u) == 0)
    {
        *policy = ZMATH_TESTING_ALGEBRAIC_POLICY_ADAPTIVE_EXACT;
        return ZMATH_TESTING_ORACLE_OK;
    }
    if (length == sizeof(fast) - 1u &&
        memcmp(bytes, fast, sizeof(fast) - 1u) == 0)
    {
        *policy = ZMATH_TESTING_ALGEBRAIC_POLICY_FAST;
        return ZMATH_TESTING_ORACLE_OK;
    }
    return ZMATH_TESTING_ORACLE_UNSUPPORTED;
}

static int zmath_testing_algebraic_graph_request_is_valid(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result,
    zmath_testing_algebraic_graph graph,
    zmath_testing_algebraic_format *format,
    zmath_testing_algebraic_policy *policy
) {
    uint32_t arity;
    uint32_t float_inputs;
    uint32_t result_floats;
    uint32_t layout;
    uint32_t structure;
    uint32_t result_fields;
    uint32_t source_code = ZMATH_TESTING_ORACLE_FORMAT_NONE;
    uint32_t index;
    zmath_testing_algebraic_format one;
    int status;

    if (signature == NULL || request == NULL || result == NULL ||
        format == NULL || policy == NULL)
    {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    if (!zmath_testing_algebraic_graph_shape(
            graph,
            &arity,
            &float_inputs,
            &result_floats,
            &layout,
            &structure,
            &result_fields))
    {
        return ZMATH_TESTING_ORACLE_UNSUPPORTED;
    }
    if (result->reserved != 0 || request->reserved != 0 ||
        request->abi_version != ZMATH_TESTING_ORACLE_ABI_VERSION)
    {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    if (signature->evaluator_category !=
        ZMATH_TESTING_ORACLE_EVALUATOR_ALGEBRAIC ||
        signature->provenance != ZMATH_TESTING_ORACLE_PROVENANCE_C23_7_12)
    {
        return ZMATH_TESTING_ORACLE_UNSUPPORTED;
    }
    /*
     * The immutable table names the row. No hand-built signature and no
     * request the table does not carry can reach the arithmetic below.
     */
    if (zmath_testing_oracle_find_operation_signature(request) != signature) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    if (request->operation == NULL || signature->operation == NULL ||
        request->operation_length != signature->operation_length ||
        memcmp(
            request->operation,
            signature->operation,
            signature->operation_length) != 0)
    {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    if (request->arity != arity || request->input_field_count != arity ||
        signature->arity != arity || request->input_fields == NULL ||
        signature->arguments == NULL || request->result_fields == NULL ||
        signature->result_fields == NULL ||
        request->result_layout != layout || signature->result_layout != layout ||
        request->structure_kind != structure ||
        signature->structure_kind != structure ||
        request->result_field_count != result_fields ||
        signature->result_field_count != result_fields ||
        result->fields == NULL || result->field_capacity < result_fields)
    {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    *policy = ZMATH_TESTING_ALGEBRAIC_POLICY_UNKNOWN;
    for (index = 0; index < arity; ++index) {
        const zmath_testing_oracle_input_field *field =
            &request->input_fields[index];
        if (!zmath_testing_algebraic_descriptor_equal(
                &field->descriptor,
                &signature->arguments[index]) ||
            field->reserved != 0)
        {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
        if (graph == ZMATH_TESTING_ALGEBRAIC_GRAPH_GEOMETRY_ORIENT2 &&
            index == ZMATH_TESTING_ALGEBRAIC_GEOMETRY_TAG_INDEX)
        {
            if (field->descriptor.kind != ZMATH_TESTING_ORACLE_FIELD_TAG ||
                field->value_bits != 0)
            {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            status = zmath_testing_algebraic_policy_from_bytes(
                field->tag_bytes, field->tag_length, policy);
            if (status != ZMATH_TESTING_ORACLE_OK) return status;
            continue;
        }
        if (index >= float_inputs) return ZMATH_TESTING_ORACLE_ERROR;
        if (field->descriptor.kind != ZMATH_TESTING_ORACLE_FIELD_FLOAT) {
            return ZMATH_TESTING_ORACLE_UNSUPPORTED;
        }
        status = zmath_testing_algebraic_format_from_descriptor(
            &field->descriptor.format, &one);
        if (status != ZMATH_TESTING_ORACLE_OK) return status;
        if (index == 0) {
            /* These five rows are declared for binary32 and binary64 only. */
            if (one.code == ZMATH_TESTING_ORACLE_FORMAT_H) {
                return ZMATH_TESTING_ORACLE_UNSUPPORTED;
            }
            *format = one;
            source_code = one.code;
        } else if (one.code != source_code) {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
        if (field->descriptor.value_bits != format->width ||
            (field->value_bits & ~format->value_mask) != 0 ||
            field->tag_bytes != NULL || field->tag_length != 0)
        {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
    }
    for (index = 0; index < result_fields; ++index) {
        const zmath_testing_oracle_field_descriptor *field =
            &request->result_fields[index];
        if (!zmath_testing_algebraic_descriptor_equal(
                field, &signature->result_fields[index]))
        {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
        if (index < result_floats) {
            if (field->kind != ZMATH_TESTING_ORACLE_FIELD_FLOAT) {
                return ZMATH_TESTING_ORACLE_UNSUPPORTED;
            }
            status = zmath_testing_algebraic_format_from_descriptor(
                &field->format, &one);
            if (status != ZMATH_TESTING_ORACLE_OK) return status;
            if (one.code != source_code || field->value_bits != one.width) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            continue;
        }
        if (result_fields - result_floats != 1u) {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
        if (graph == ZMATH_TESTING_ALGEBRAIC_GRAPH_LU_SOLVE2) {
            if (field->kind != ZMATH_TESTING_ORACLE_FIELD_BOOLEAN ||
                field->value_bits != 1u)
            {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
        } else if (graph == ZMATH_TESTING_ALGEBRAIC_GRAPH_GEOMETRY_ORIENT2) {
            if (field->kind != ZMATH_TESTING_ORACLE_FIELD_SIGNED_INTEGER ||
                field->value_bits != 32u)
            {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
        } else {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
    }
    if (graph == ZMATH_TESTING_ALGEBRAIC_GRAPH_GEOMETRY_ORIENT2 &&
        *policy == ZMATH_TESTING_ALGEBRAIC_POLICY_UNKNOWN)
    {
        return ZMATH_TESTING_ORACLE_UNSUPPORTED;
    }
    return ZMATH_TESTING_ORACLE_OK;
}

/*
 * One binary primitive of a compound graph, rounded to the target format.
 * The exact rational is the evidence for that one rounding. It is not kept
 * past this call, and class_out may be null when the caller reads no class.
 */
static int zmath_testing_algebraic_graph_step(
    uint64_t *bits_out,
    uint32_t *class_out,
    zmath_testing_algebraic_kernel kernel,
    const zmath_testing_algebraic_format *format,
    uint64_t first_bits,
    uint64_t second_bits
) {
    zmath_testing_algebraic_value first;
    zmath_testing_algebraic_value second;
    mpq_t left;
    mpq_t right;
    mpq_t value;
    uint32_t class_code;
    int success = 0;

    if (bits_out == NULL || format == NULL) return 0;
    zmath_testing_algebraic_decode_value(format, first_bits, &first);
    zmath_testing_algebraic_decode_value(format, second_bits, &second);
    /* The first NaN operand wins. Only the same-sign infinity subtraction
     * and the infinite times zero are invalid. */
    if (zmath_testing_algebraic_special_binary(
            bits_out,
            &class_code,
            kernel,
            format,
            format,
            &first,
            &second))
    {
        if (class_out != NULL) *class_out = class_code;
        return 1;
    }
    /*
     * Every NaN, infinity, and zero pair is above. Two finite nonzero
     * operands are left, so the exact result is never zero and the sign of
     * a zero never has to be reconstructed.
     */
    mpq_init(left);
    mpq_init(right);
    mpq_init(value);
    if (zmath_testing_algebraic_ratio_from_bits(left, format, first_bits) &&
        zmath_testing_algebraic_ratio_from_bits(right, format, second_bits))
    {
        switch (kernel) {
            case ZMATH_TESTING_ALGEBRAIC_ADD:
                mpq_add(value, left, right);
                break;
            case ZMATH_TESTING_ALGEBRAIC_SUB:
                mpq_sub(value, left, right);
                break;
            case ZMATH_TESTING_ALGEBRAIC_MUL:
                mpq_mul(value, left, right);
                break;
            default:
                goto cleanup;
        }
        success = zmath_testing_algebraic_encode_rational(
            bits_out, &class_code, format, value, 0);
    }
    if (success && class_out != NULL) *class_out = class_code;
cleanup:
    mpq_clear(value);
    mpq_clear(right);
    mpq_clear(left);
    return success;
}

static int zmath_testing_algebraic_complex_add(
    const zmath_testing_oracle_request *request,
    const zmath_testing_algebraic_format *format,
    zmath_testing_oracle_result *result
) {
    uint64_t bits[2];
    uint32_t class_code[2];
    uint32_t index;

    /* Each component is its own addition and owns its own IEEE state, so an
     * invalid real part leaves the imaginary part exact. */
    if (!zmath_testing_algebraic_graph_step(
            &bits[0],
            &class_code[0],
            ZMATH_TESTING_ALGEBRAIC_ADD,
            format,
            request->input_fields[0].value_bits,
            request->input_fields[2].value_bits) ||
        !zmath_testing_algebraic_graph_step(
            &bits[1],
            &class_code[1],
            ZMATH_TESTING_ALGEBRAIC_ADD,
            format,
            request->input_fields[1].value_bits,
            request->input_fields[3].value_bits))
    {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    for (index = 0; index < 2u; ++index) {
        if (!zmath_testing_algebraic_result_field(
                &result->fields[index],
                &request->result_fields[index],
                bits[index],
                class_code[index]))
        {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
    }
    result->field_count = 2u;
    return ZMATH_TESTING_ORACLE_OK;
}

static int zmath_testing_algebraic_complex_mul(
    const zmath_testing_oracle_request *request,
    const zmath_testing_algebraic_format *format,
    zmath_testing_oracle_result *result
) {
    uint64_t inputs[4];
    uint64_t products[4];
    uint64_t bits[2];
    uint32_t class_code[2];
    zmath_testing_algebraic_value decoded;
    uint64_t shared_nan;
    uint32_t index;
    uint32_t first_nan = 4u;

    for (index = 0; index < 4u; ++index) {
        inputs[index] = request->input_fields[index].value_bits;
    }
    for (index = 0; index < 4u; ++index) {
        zmath_testing_algebraic_decode_value(format, inputs[index], &decoded);
        if (decoded.nan) {
            first_nan = index;
            break;
        }
    }
    if (first_nan < 4u) {
        /*
         * A product has one result and not two, so the first NaN operand is
         * quieted into BOTH components. An infinity beside it must not leak
         * out as a component of the same product.
         */
        shared_nan = zmath_testing_algebraic_quiet_nan(
            format, format, inputs[first_nan]);
        for (index = 0; index < 2u; ++index) {
            bits[index] = shared_nan;
            class_code[index] = ZMATH_TESTING_ORACLE_CLASS_QNAN;
        }
    } else {
        if (!zmath_testing_algebraic_graph_step(
                &products[0], NULL, ZMATH_TESTING_ALGEBRAIC_MUL, format,
                inputs[0], inputs[2]) ||
            !zmath_testing_algebraic_graph_step(
                &products[1], NULL, ZMATH_TESTING_ALGEBRAIC_MUL, format,
                inputs[1], inputs[3]) ||
            !zmath_testing_algebraic_graph_step(
                &products[2], NULL, ZMATH_TESTING_ALGEBRAIC_MUL, format,
                inputs[0], inputs[3]) ||
            !zmath_testing_algebraic_graph_step(
                &products[3], NULL, ZMATH_TESTING_ALGEBRAIC_MUL, format,
                inputs[1], inputs[2]))
        {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
        if (!zmath_testing_algebraic_graph_step(
                &bits[0], &class_code[0], ZMATH_TESTING_ALGEBRAIC_SUB, format,
                products[0], products[1]) ||
            !zmath_testing_algebraic_graph_step(
                &bits[1], &class_code[1], ZMATH_TESTING_ALGEBRAIC_ADD, format,
                products[2], products[3]))
        {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
        if (class_code[0] == ZMATH_TESTING_ORACLE_CLASS_QNAN ||
            class_code[1] == ZMATH_TESTING_ORACLE_CLASS_QNAN)
        {
            /* One invalid component makes the product invalid, so both
             * fields carry the positive canonical NaN. */
            shared_nan = zmath_testing_algebraic_canonical_nan(format);
            for (index = 0; index < 2u; ++index) {
                bits[index] = shared_nan;
                class_code[index] = ZMATH_TESTING_ORACLE_CLASS_QNAN;
            }
        }
    }
    for (index = 0; index < 2u; ++index) {
        if (!zmath_testing_algebraic_result_field(
                &result->fields[index],
                &request->result_fields[index],
                bits[index],
                class_code[index]))
        {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
    }
    result->field_count = 2u;
    return ZMATH_TESTING_ORACLE_OK;
}

static int zmath_testing_algebraic_matrix_det2(
    const zmath_testing_oracle_request *request,
    const zmath_testing_algebraic_format *format,
    zmath_testing_oracle_result *result
) {
    uint64_t left;
    uint64_t right;
    uint64_t bits;
    uint32_t class_code;

    /*
     * fl(fl(a00 * a11) - fl(a01 * a10)), and NOT the single rounded exact
     * determinant. Rounding each product is the whole difference between
     * the two, so each one is rounded on its own and exactly.
     */
    if (!zmath_testing_algebraic_graph_step(
            &left, NULL, ZMATH_TESTING_ALGEBRAIC_MUL, format,
            request->input_fields[0].value_bits,
            request->input_fields[3].value_bits) ||
        !zmath_testing_algebraic_graph_step(
            &right, NULL, ZMATH_TESTING_ALGEBRAIC_MUL, format,
            request->input_fields[1].value_bits,
            request->input_fields[2].value_bits) ||
        !zmath_testing_algebraic_graph_step(
            &bits, &class_code, ZMATH_TESTING_ALGEBRAIC_SUB, format,
            left, right))
    {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    if (!zmath_testing_algebraic_result_field(
            &result->fields[0], &request->result_fields[0], bits, class_code))
    {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    result->field_count = 1u;
    return ZMATH_TESTING_ORACLE_OK;
}

/*
 * A refused solve has no solution to report. The two inactive components
 * carry the canonical positive zero, which is not a number the criterion
 * could have produced, and the flag says the pair is inactive.
 */
static int zmath_testing_algebraic_lu_refused(
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result
) {
    uint32_t index;

    for (index = 0; index < 2u; ++index) {
        if (!zmath_testing_algebraic_result_field(
                &result->fields[index],
                &request->result_fields[index],
                0,
                ZMATH_TESTING_ORACLE_CLASS_ZERO))
        {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
    }
    if (!zmath_testing_algebraic_result_field(
            &result->fields[2],
            &request->result_fields[2],
            0,
            ZMATH_TESTING_ORACLE_CLASS_NONE))
    {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    result->field_count = 3u;
    return ZMATH_TESTING_ORACLE_OK;
}

static int zmath_testing_algebraic_lu_solve2(
    const zmath_testing_oracle_request *request,
    const zmath_testing_algebraic_format *format,
    zmath_testing_oracle_result *result
) {
    mpq_t entries[6];
    mpq_t determinant;
    mpq_t numerator;
    mpq_t solution;
    mpq_t scale;
    mpq_t tau;
    mpq_t leading;
    mpq_t margin;
    mpq_t trailing;
    mpq_t product;
    mpq_t magnitude;
    zmath_testing_algebraic_value decoded;
    uint64_t bits[2];
    uint64_t trailing_bits = 0;
    uint32_t class_code[2];
    uint32_t trailing_class = ZMATH_TESTING_ORACLE_CLASS_NONE;
    uint32_t index;
    int status = ZMATH_TESTING_ORACLE_ERROR;

    for (index = 0; index < 6u; ++index) mpq_init(entries[index]);
    mpq_init(determinant);
    mpq_init(numerator);
    mpq_init(solution);
    mpq_init(scale);
    mpq_init(tau);
    mpq_init(leading);
    mpq_init(margin);
    mpq_init(trailing);
    mpq_init(product);
    mpq_init(magnitude);

    for (index = 0; index < 6u; ++index) {
        zmath_testing_algebraic_decode_value(
            format, request->input_fields[index].value_bits, &decoded);
        if (!decoded.nan && !decoded.infinity) continue;
        /*
         * The matrix and the right-hand side are different domains. A
         * non-finite matrix entry has no finite scale to weigh against the
         * threshold and no finite pivot to factor from, so the solve is
         * refused and reports the inactive pair with ok false. A non-finite
         * right-hand side decides nothing about the matrix, so it names no
         * reference at all and the request carries no field.
         */
        if (index < 4u) {
            status = zmath_testing_algebraic_lu_refused(request, result);
        } else {
            status = ZMATH_TESTING_ORACLE_UNSUPPORTED;
        }
        goto cleanup;
    }
    for (index = 0; index < 6u; ++index) {
        if (!zmath_testing_algebraic_ratio_from_bits(
                entries[index],
                format,
                request->input_fields[index].value_bits))
        {
            goto cleanup;
        }
    }
    /* det = a00 * a11 - a01 * a10, exactly, with no rounding anywhere. */
    mpq_mul(product, entries[0], entries[3]);
    mpq_mul(magnitude, entries[1], entries[2]);
    mpq_sub(determinant, product, magnitude);
    /*
     * scale is the largest entry magnitude of the matrix and tau is the
     * PUBLIC threshold: the unit roundoff of the format, which is
     * 2^-fraction_bits, times the 2^(n-1) element-growth bound of a
     * reduction, which is 2^(fraction_bits - 2) for binary32 and binary64
     * alike and gives 2^-21 and 2^-50. Every term below is an exact
     * rational, so this criterion never reads a rounded product and never
     * copies a Doolittle loop.
     */
    mpq_abs(scale, entries[0]);
    for (index = 1; index < 4u; ++index) {
        mpq_abs(magnitude, entries[index]);
        if (mpq_cmp(magnitude, scale) > 0) mpq_set(scale, magnitude);
    }
    mpz_set_ui(mpq_numref(tau), 1);
    mpz_set_ui(mpq_denref(tau), 1);
    mpz_mul_2exp(
        mpq_denref(tau),
        mpq_denref(tau),
        (mp_bitcnt_t)(format->fraction_bits - 2u));
    mpq_canonicalize(tau);
    mpq_mul(tau, tau, scale);
    /*
     * leading is p, the magnitude of the first pivot a partial-pivoting
     * reduction selects from the leading column, and it has to clear tau.
     */
    mpq_abs(leading, entries[0]);
    mpq_abs(magnitude, entries[2]);
    if (mpq_cmp(magnitude, leading) > 0) mpq_set(leading, magnitude);
    if (mpq_cmp(leading, tau) <= 0) {
        status = zmath_testing_algebraic_lu_refused(request, result);
        goto cleanup;
    }
    /*
     * The trailing pivot of that reduction is det / p in exact arithmetic
     * whichever row the partial pivoting chose, because the two candidate
     * pivots differ only in sign, so it clears the same threshold exactly
     * when |det| clears p * tau.
     */
    mpq_mul(margin, leading, tau);
    mpq_abs(magnitude, determinant);
    if (mpq_cmp(magnitude, margin) <= 0) {
        status = zmath_testing_algebraic_lu_refused(request, result);
        goto cleanup;
    }
    /*
     * A factor that leaves the range of the format has no finite pivot left
     * to divide by. The MAGNITUDE of the trailing pivot is that factor, so
     * encoding it and reading the class decides the overflow without a
     * signed pivot swap to get backwards and without elimination to
     * imitate.
     */
    mpq_div(trailing, magnitude, leading);
    if (!zmath_testing_algebraic_encode_rational(
            &trailing_bits, &trailing_class, format, trailing, 0))
    {
        goto cleanup;
    }
    if (trailing_class == ZMATH_TESTING_ORACLE_CLASS_INFINITY) {
        status = zmath_testing_algebraic_lu_refused(request, result);
        goto cleanup;
    }
    /* x0 = (b0 * a11 - a01 * b1) / det, rounded once to the target format. */
    mpq_mul(product, entries[4], entries[3]);
    mpq_mul(magnitude, entries[1], entries[5]);
    mpq_sub(numerator, product, magnitude);
    mpq_div(solution, numerator, determinant);
    if (!zmath_testing_algebraic_encode_rational(
            &bits[0], &class_code[0], format, solution, 0))
    {
        goto cleanup;
    }
    /* x1 = (a00 * b1 - b0 * a10) / det, rounded once to the target format. */
    mpq_mul(product, entries[0], entries[5]);
    mpq_mul(magnitude, entries[4], entries[2]);
    mpq_sub(numerator, product, magnitude);
    mpq_div(solution, numerator, determinant);
    if (!zmath_testing_algebraic_encode_rational(
            &bits[1], &class_code[1], format, solution, 0))
    {
        goto cleanup;
    }
    /*
     * A finite right-hand side may solve past the range of the format. That
     * is the IEEE infinity with its own sign and ok stays true, because only
     * a pivot or a factor the public factorization refuses makes a solve a
     * refusal, and refusing this would hide two different signs behind one
     * inactive pair.
     */
    for (index = 0; index < 2u; ++index) {
        if (!zmath_testing_algebraic_result_field(
                &result->fields[index],
                &request->result_fields[index],
                bits[index],
                class_code[index]))
        {
            goto cleanup;
        }
    }
    if (!zmath_testing_algebraic_result_field(
            &result->fields[2],
            &request->result_fields[2],
            1,
            ZMATH_TESTING_ORACLE_CLASS_NONE))
    {
        goto cleanup;
    }
    result->field_count = 3u;
    status = ZMATH_TESTING_ORACLE_OK;
cleanup:
    mpq_clear(magnitude);
    mpq_clear(product);
    mpq_clear(trailing);
    mpq_clear(margin);
    mpq_clear(leading);
    mpq_clear(tau);
    mpq_clear(scale);
    mpq_clear(solution);
    mpq_clear(numerator);
    mpq_clear(determinant);
    for (index = 0; index < 6u; ++index) mpq_clear(entries[index]);
    return status;
}

/*
 * The sign of a rounded value, read the way a comparison reads it. A zero
 * is collinear and an unordered comparison is not a sign, so both report no
 * orientation at all.
 */
static int zmath_testing_algebraic_float_sign(
    uint64_t bits,
    uint32_t class_code,
    const zmath_testing_algebraic_format *format,
    int *sign_out
) {
    if (format == NULL || sign_out == NULL) return 0;
    switch (class_code) {
        case ZMATH_TESTING_ORACLE_CLASS_NORMAL:
        case ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL:
        case ZMATH_TESTING_ORACLE_CLASS_INFINITY:
            *sign_out = (bits & format->sign_mask) != 0 ? -1 : 1;
            return 1;
        case ZMATH_TESTING_ORACLE_CLASS_ZERO:
        case ZMATH_TESTING_ORACLE_CLASS_QNAN:
        case ZMATH_TESTING_ORACLE_CLASS_SNAN:
            *sign_out = 0;
            return 1;
        default:
            return 0;
    }
}

static int zmath_testing_algebraic_geometry_orient2(
    const zmath_testing_oracle_request *request,
    const zmath_testing_algebraic_format *format,
    zmath_testing_algebraic_policy policy,
    zmath_testing_oracle_result *result
) {
    /* b - a and c - a, as the input index of each end of each edge. */
    static const uint32_t edge_end[4] = { 2, 3, 4, 5 };
    static const uint32_t edge_origin[4] = { 0, 1, 0, 1 };
    mpq_t stored[ZMATH_TESTING_ALGEBRAIC_GEOMETRY_COORDINATES];
    mpq_t edge[4];
    mpq_t product;
    mpq_t determinant;
    zmath_testing_algebraic_value decoded;
    uint64_t steps[7];
    uint32_t class_code = ZMATH_TESTING_ORACLE_CLASS_NONE;
    uint32_t word;
    uint32_t index;
    int sign = 0;
    int status = ZMATH_TESTING_ORACLE_ERROR;

    for (index = 0; index < ZMATH_TESTING_ALGEBRAIC_GEOMETRY_COORDINATES;
         ++index)
    {
        mpq_init(stored[index]);
    }
    for (index = 0; index < 4u; ++index) mpq_init(edge[index]);
    mpq_init(product);
    mpq_init(determinant);

    for (index = 0; index < ZMATH_TESTING_ALGEBRAIC_GEOMETRY_COORDINATES;
         ++index)
    {
        zmath_testing_algebraic_decode_value(
            format, request->input_fields[index].value_bits, &decoded);
        /* The finite coordinate domain is the domain of both policies, so a
         * non-finite coordinate names no reference under either one. */
        if (decoded.nan || decoded.infinity) {
            status = ZMATH_TESTING_ORACLE_UNSUPPORTED;
            goto cleanup;
        }
        if (!zmath_testing_algebraic_ratio_from_bits(
                stored[index],
                format,
                request->input_fields[index].value_bits))
        {
            goto cleanup;
        }
    }
    if (policy == ZMATH_TESTING_ALGEBRAIC_POLICY_ADAPTIVE_EXACT) {
        /*
         * The exact determinant of the ORIGINAL stored coordinates. A
         * difference rounded into the format first can erase a nonzero cross
         * product, and no later rounding can bring it back.
         */
        mpq_sub(edge[0], stored[edge_end[0]], stored[edge_origin[0]]);
        mpq_sub(edge[1], stored[edge_end[1]], stored[edge_origin[1]]);
        mpq_sub(edge[2], stored[edge_end[2]], stored[edge_origin[2]]);
        mpq_sub(edge[3], stored[edge_end[3]], stored[edge_origin[3]]);
        mpq_mul(product, edge[0], edge[3]);
        mpq_mul(stored[0], edge[1], edge[2]);
        mpq_sub(determinant, product, stored[0]);
        sign = mpq_sgn(determinant);
    } else {
        /* The fast policy: four differences, two products, and the
         * subtraction, each rounded on its own, and only then the sign. */
        for (index = 0; index < 4u; ++index) {
            if (!zmath_testing_algebraic_graph_step(
                    &steps[index],
                    NULL,
                    ZMATH_TESTING_ALGEBRAIC_SUB,
                    format,
                    request->input_fields[edge_end[index]].value_bits,
                    request->input_fields[edge_origin[index]].value_bits))
            {
                goto cleanup;
            }
        }
        if (!zmath_testing_algebraic_graph_step(
                &steps[4], NULL, ZMATH_TESTING_ALGEBRAIC_MUL, format,
                steps[0], steps[3]) ||
            !zmath_testing_algebraic_graph_step(
                &steps[5], NULL, ZMATH_TESTING_ALGEBRAIC_MUL, format,
                steps[1], steps[2]) ||
            !zmath_testing_algebraic_graph_step(
                &steps[6], &class_code, ZMATH_TESTING_ALGEBRAIC_SUB, format,
                steps[4], steps[5]))
        {
            goto cleanup;
        }
        if (!zmath_testing_algebraic_float_sign(
                steps[6], class_code, format, &sign))
        {
            goto cleanup;
        }
    }
    /* The result field is a signed 32-bit integer, so the sign travels as
     * the two's-complement word of its own width: -1 is 0xffffffff, not a
     * 64-bit -1. */
    word = sign < 0 ? UINT32_MAX : (uint32_t)sign;
    if (!zmath_testing_algebraic_result_field(
            &result->fields[0],
            &request->result_fields[0],
            (uint64_t)word,
            ZMATH_TESTING_ORACLE_CLASS_NONE))
    {
        goto cleanup;
    }
    result->field_count = 1u;
    status = ZMATH_TESTING_ORACLE_OK;
cleanup:
    mpq_clear(determinant);
    mpq_clear(product);
    for (index = 0; index < 4u; ++index) mpq_clear(edge[index]);
    for (index = 0; index < ZMATH_TESTING_ALGEBRAIC_GEOMETRY_COORDINATES;
         ++index)
    {
        mpq_clear(stored[index]);
    }
    return status;
}

static int zmath_testing_algebraic_graph_evaluate(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result,
    zmath_testing_algebraic_graph graph
) {
    zmath_testing_algebraic_format format;
    zmath_testing_algebraic_policy policy;
    int status;

    status = zmath_testing_algebraic_graph_request_is_valid(
        signature, request, result, graph, &format, &policy);
    if (status != ZMATH_TESTING_ORACLE_OK) return status;
    switch (graph) {
        case ZMATH_TESTING_ALGEBRAIC_GRAPH_COMPLEX_ADD:
            return zmath_testing_algebraic_complex_add(
                request, &format, result);
        case ZMATH_TESTING_ALGEBRAIC_GRAPH_COMPLEX_MUL:
            return zmath_testing_algebraic_complex_mul(
                request, &format, result);
        case ZMATH_TESTING_ALGEBRAIC_GRAPH_MATRIX_DET2:
            return zmath_testing_algebraic_matrix_det2(
                request, &format, result);
        case ZMATH_TESTING_ALGEBRAIC_GRAPH_LU_SOLVE2:
            return zmath_testing_algebraic_lu_solve2(
                request, &format, result);
        case ZMATH_TESTING_ALGEBRAIC_GRAPH_GEOMETRY_ORIENT2:
            return zmath_testing_algebraic_geometry_orient2(
                request, &format, policy, result);
        default:
            return ZMATH_TESTING_ORACLE_UNSUPPORTED;
    }
}

static void zmath_testing_oracle_evaluate_algebraic_impl(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result,
    int require_proof
) {
    zmath_testing_algebraic_format source;
    zmath_testing_algebraic_format destination;
    zmath_testing_algebraic_kernel kernel;
    zmath_testing_algebraic_graph graph;
    zmath_testing_algebraic_value values[3];
    uint64_t bits;
    uint32_t class_code;
    uint32_t index;
    int special;
    int status;

    zmath_testing_algebraic_initialize_result(result);
    if (result == NULL) return;
    /*
     * The five compound rows are dispatched BEFORE the scalar validation
     * below. That validation owns a three-element argument array, a single
     * float result, and no tag input, so it can neither describe a seven
     * input geometry row nor accept a two component complex result. Reading
     * one there would send seven arguments into a three-slot array.
     */
    graph = zmath_testing_algebraic_graph_for(signature);
    if (graph != ZMATH_TESTING_ALGEBRAIC_GRAPH_NONE) {
        result->status = (uint32_t)zmath_testing_algebraic_graph_evaluate(
            signature, request, result, graph);
        return;
    }
    status = zmath_testing_algebraic_request_is_valid(
        signature, request, result, &source, &destination, &kernel);
    if (status != ZMATH_TESTING_ORACLE_OK) {
        result->status = (uint32_t)status;
        return;
    }
    for (index = 0; index < request->arity; ++index) {
        zmath_testing_algebraic_decode_value(
            &source, request->input_fields[index].value_bits, &values[index]);
    }
    bits = 0;
    class_code = ZMATH_TESTING_ORACLE_CLASS_NONE;
    special = 0;
    if (request->arity == 1) {
        special = zmath_testing_algebraic_special_unary(
            &bits, &class_code, kernel, &source, &destination, &values[0]);
    } else if (request->arity == 2) {
        special = zmath_testing_algebraic_special_binary(
            &bits, &class_code, kernel, &source, &destination,
            &values[0], &values[1]);
    } else if (request->arity == 3) {
        special = zmath_testing_algebraic_special_ternary(
            &bits, &class_code, &source, &destination,
            &values[0], &values[1], &values[2]);
    } else {
        result->status = ZMATH_TESTING_ORACLE_ERROR;
        return;
    }
    if (!special) {
        if (!zmath_testing_algebraic_finite_result(
                &bits, &class_code, &source, &destination, kernel, request,
                require_proof))
        {
            result->status = ZMATH_TESTING_ORACLE_UNCERTAIN;
            return;
        }
    }
    if (!zmath_testing_algebraic_result_field(
            &result->fields[0], &request->result_fields[0], bits, class_code))
    {
        result->status = ZMATH_TESTING_ORACLE_ERROR;
        return;
    }
    result->field_count = 1;
    result->status = ZMATH_TESTING_ORACLE_OK;
}

void zmath_testing_oracle_evaluate_algebraic_reference(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result
) {
    zmath_testing_oracle_evaluate_algebraic_impl(
        signature, request, result, 0);
}

void zmath_testing_oracle_evaluate_algebraic(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result
) {
    zmath_testing_oracle_evaluate_algebraic_impl(
        signature, request, result, 1);
}
