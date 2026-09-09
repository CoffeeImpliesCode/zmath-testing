#include "oracle_evaluators.h"

#include <inttypes.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct zmath_regression_case {
    const char *operation;
    uint32_t format;
    uint64_t input_bits;
    int has_exponent;
    int64_t exponent;
    uint64_t expected_bits;
    uint32_t expected_class;
    uint64_t expected_status;
} zmath_regression_case;

static const zmath_testing_oracle_operation_signature *zmath_find_signature(
    const char *operation,
    uint32_t format
) {
    const size_t operation_length = strlen(operation);
    uint32_t index;

    for (index = 0; index < zmath_testing_oracle_operation_table_count; ++index) {
        const zmath_testing_oracle_operation_signature *signature =
            &zmath_testing_oracle_operation_table[index];
        if (signature->evaluator_category == ZMATH_TESTING_ORACLE_EVALUATOR_MPFR_ARB &&
            signature->arity >= 1 &&
            signature->arguments[0].format.code == format &&
            signature->operation_length == operation_length &&
            memcmp(signature->operation, operation, operation_length) == 0) {
            return signature;
        }
    }
    return NULL;
}

static int zmath_result_matches(
    const zmath_regression_case *test_case,
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_result *result
) {
    /* Binary operations can still have a scalar result. */
    const uint32_t expected_field_count = signature->result_field_count;

    if (result->status != ZMATH_TESTING_ORACLE_OK ||
        result->field_count != expected_field_count ||
        result->fields[0].value_bits != test_case->expected_bits ||
        result->fields[0].class_code != test_case->expected_class ||
        memcmp(
            &result->fields[0].descriptor,
            &signature->result_fields[0],
            sizeof(result->fields[0].descriptor)
        ) != 0) {
        return 0;
    }
    if (signature->result_field_count == 2 &&
        (result->fields[1].value_bits != test_case->expected_status ||
         result->fields[1].class_code != ZMATH_TESTING_ORACLE_CLASS_NONE ||
         memcmp(
             &result->fields[1].descriptor,
             &signature->result_fields[1],
             sizeof(result->fields[1].descriptor)
         ) != 0)) {
        return 0;
    }
    return 1;
}

static int zmath_run_case(const zmath_regression_case *test_case) {
    const zmath_testing_oracle_operation_signature *signature =
        zmath_find_signature(test_case->operation, test_case->format);
    zmath_testing_oracle_input_field inputs[2] = {0};
    zmath_testing_oracle_result_field candidate_fields[2] = {0};
    zmath_testing_oracle_result_field proof_fields[2] = {0};
    zmath_testing_oracle_request request;
    zmath_testing_oracle_result candidate;
    zmath_testing_oracle_result proof;

    if (signature == NULL ||
        signature->arity != (uint32_t)(test_case->has_exponent ? 2 : 1)) {
        fprintf(stderr, "%s/%" PRIu32 ": missing signature\n",
                test_case->operation, test_case->format);
        return 0;
    }

    inputs[0].descriptor = signature->arguments[0];
    inputs[0].value_bits = test_case->input_bits;
    if (test_case->has_exponent) {
        inputs[1].descriptor = signature->arguments[1];
        inputs[1].value_bits = (uint64_t)test_case->exponent;
    }

    request.abi_version = ZMATH_TESTING_ORACLE_ABI_VERSION;
    request.reserved = 0;
    request.operation = (const uint8_t *)signature->operation;
    request.operation_length = signature->operation_length;
    request.arity = signature->arity;
    request.input_fields = inputs;
    request.input_field_count = signature->arity;
    request.result_layout = signature->result_layout;
    request.structure_kind = signature->structure_kind;
    request.result_field_count = signature->result_field_count;
    request.result_fields = signature->result_fields;

    candidate.status = ZMATH_TESTING_ORACLE_ERROR;
    candidate.reserved = 0;
    candidate.field_capacity = 2;
    candidate.field_count = 0;
    candidate.fields = candidate_fields;
    zmath_testing_oracle_v2_mpfr_reference(&request, &candidate);
    if (!zmath_result_matches(test_case, signature, &candidate)) {
        fprintf(
            stderr,
            "%s/%" PRIu32 " input=%016" PRIx64
            ": MPFR status=%" PRIu32 " fields=%" PRIu32
            " bits=%016" PRIx64 " class=%" PRIu32 "\n",
            test_case->operation,
            test_case->format,
            test_case->input_bits,
            candidate.status,
            candidate.field_count,
            candidate.field_count == 0 ? UINT64_C(0) : candidate.fields[0].value_bits,
            candidate.field_count == 0 ? ZMATH_TESTING_ORACLE_CLASS_NONE :
                                         candidate.fields[0].class_code
        );
        return 0;
    }

    proof.status = ZMATH_TESTING_ORACLE_ERROR;
    proof.reserved = 0;
    proof.field_capacity = 2;
    proof.field_count = 0;
    proof.fields = proof_fields;
    zmath_testing_oracle_v2_arb_prove(&request, &candidate, &proof);
    if (!zmath_result_matches(test_case, signature, &proof)) {
        fprintf(
            stderr,
            "%s/%" PRIu32 " input=%016" PRIx64
            ": Arb status=%" PRIu32 " fields=%" PRIu32 "\n",
            test_case->operation,
            test_case->format,
            test_case->input_bits,
            proof.status,
            proof.field_count
        );
        return 0;
    }
    return 1;
}

#define Z_PI_CASES(FORMAT, POS_ONE, NEG_ONE, POS_HALF, NEG_HALF, POS_ONE_HALF, \
                   NEG_ONE_HALF, NEG_ZERO, POS_INF, NEG_INF) \
    {"sinpi", FORMAT, POS_ONE, 0, 0, UINT64_C(0), ZMATH_TESTING_ORACLE_CLASS_ZERO, 0}, \
    {"sinpi", FORMAT, NEG_ONE, 0, 0, NEG_ZERO, ZMATH_TESTING_ORACLE_CLASS_ZERO, 0}, \
    {"cospi", FORMAT, POS_HALF, 0, 0, UINT64_C(0), ZMATH_TESTING_ORACLE_CLASS_ZERO, 0}, \
    {"cospi", FORMAT, NEG_HALF, 0, 0, UINT64_C(0), ZMATH_TESTING_ORACLE_CLASS_ZERO, 0}, \
    {"cospi", FORMAT, POS_ONE_HALF, 0, 0, UINT64_C(0), ZMATH_TESTING_ORACLE_CLASS_ZERO, 0}, \
    {"acospi", FORMAT, POS_ONE, 0, 0, UINT64_C(0), ZMATH_TESTING_ORACLE_CLASS_ZERO, 0}, \
    {"tanpi", FORMAT, POS_ONE, 0, 0, NEG_ZERO, ZMATH_TESTING_ORACLE_CLASS_ZERO, 0}, \
    {"tanpi", FORMAT, NEG_ONE, 0, 0, UINT64_C(0), ZMATH_TESTING_ORACLE_CLASS_ZERO, 0}, \
    {"tanpi", FORMAT, POS_HALF, 0, 0, POS_INF, ZMATH_TESTING_ORACLE_CLASS_INFINITY, 0}, \
    {"tanpi", FORMAT, NEG_HALF, 0, 0, NEG_INF, ZMATH_TESTING_ORACLE_CLASS_INFINITY, 0}, \
    {"tanpi", FORMAT, POS_ONE_HALF, 0, 0, NEG_INF, ZMATH_TESTING_ORACLE_CLASS_INFINITY, 0}, \
    {"tanpi", FORMAT, NEG_ONE_HALF, 0, 0, POS_INF, ZMATH_TESTING_ORACLE_CLASS_INFINITY, 0}

#define Z_POWER_CASES(FORMAT, SNAN_ONE, QNAN_ONE) \
    {"pown", FORMAT, SNAN_ONE, 1, 0, QNAN_ONE, ZMATH_TESTING_ORACLE_CLASS_QNAN, 1}, \
    {"compoundn", FORMAT, SNAN_ONE, 1, 0, QNAN_ONE, ZMATH_TESTING_ORACLE_CLASS_QNAN, 1}

static const zmath_regression_case zmath_regression_cases[] = {
    {"pow", ZMATH_TESTING_ORACLE_FORMAT_D, UINT64_C(0x8000000000000001), 1,
     -INT64_C(4503599627370497), UINT64_C(0x7ff0000000000000),
     ZMATH_TESTING_ORACLE_CLASS_INFINITY, 0},
    {"atan2", ZMATH_TESTING_ORACLE_FORMAT_D, UINT64_C(0x000fffffffffffff), 1,
     UINT64_C(0x4000000000000000), UINT64_C(0x0007ffffffffffff),
     ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL, 1},
    {"atan2", ZMATH_TESTING_ORACLE_FORMAT_D, UINT64_C(5), 1,
     UINT64_C(0x4000000000000000), UINT64_C(2),
     ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL, 1},
    {"atan2", ZMATH_TESTING_ORACLE_FORMAT_D, UINT64_C(0x8000000000000003), 1,
     UINT64_C(0x4000000000000000), UINT64_C(0x8000000000000001),
     ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL, 1},
    {"pow", ZMATH_TESTING_ORACLE_FORMAT_H, UINT64_C(0x7e00), 1,
     UINT64_C(0x7c01), UINT64_C(0x7e00),
     ZMATH_TESTING_ORACLE_CLASS_QNAN, 0},
    {"powr", ZMATH_TESTING_ORACLE_FORMAT_D, UINT64_C(0x3ff0000000000001), 1,
     UINT64_C(0x7fefffffffffffff), UINT64_C(0x7ff0000000000000),
     ZMATH_TESTING_ORACLE_CLASS_INFINITY, 0},
    {"exp", ZMATH_TESTING_ORACLE_FORMAT_F, UINT64_C(0x7f7ffffe), 0, 0,
     UINT64_C(0x7f800000), ZMATH_TESTING_ORACLE_CLASS_INFINITY, 0},
    {"exp2m1", ZMATH_TESTING_ORACLE_FORMAT_D, UINT64_C(1), 0, 0,
     UINT64_C(1), ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL, 0},
    {"exp10m1", ZMATH_TESTING_ORACLE_FORMAT_D, UINT64_C(1), 0, 0,
     UINT64_C(2), ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL, 0},
    {"atan2", ZMATH_TESTING_ORACLE_FORMAT_D, UINT64_C(0x0000000000000001), 1,
     UINT64_C(0x4000000000000000), UINT64_C(0x0000000000000000),
     ZMATH_TESTING_ORACLE_CLASS_ZERO, 1},
    {"exp2", ZMATH_TESTING_ORACLE_FORMAT_D, UINT64_C(0x5fdfffffffffffff), 0, 0,
     UINT64_C(0x7ff0000000000000), ZMATH_TESTING_ORACLE_CLASS_INFINITY, 0},
    {"exp10", ZMATH_TESTING_ORACLE_FORMAT_D, UINT64_C(0x5fdfffffffffffff), 0, 0,
     UINT64_C(0x7ff0000000000000), ZMATH_TESTING_ORACLE_CLASS_INFINITY, 0},
    {"exp2m1", ZMATH_TESTING_ORACLE_FORMAT_D, UINT64_C(0x5fdfffffffffffff), 0, 0,
     UINT64_C(0x7ff0000000000000), ZMATH_TESTING_ORACLE_CLASS_INFINITY, 0},
    {"exp10m1", ZMATH_TESTING_ORACLE_FORMAT_D, UINT64_C(0x5fdfffffffffffff), 0, 0,
     UINT64_C(0x7ff0000000000000), ZMATH_TESTING_ORACLE_CLASS_INFINITY, 0},
    {"powr", ZMATH_TESTING_ORACLE_FORMAT_D, UINT64_C(0x0000000000000001), 1,
     -INT64_C(4503599627370497), UINT64_C(0x7ff0000000000000),
     ZMATH_TESTING_ORACLE_CLASS_INFINITY, 0},
    {"lgamma", ZMATH_TESTING_ORACLE_FORMAT_H, UINT64_C(0x8001), 0, 0,
     UINT64_C(0x4c29), ZMATH_TESTING_ORACLE_CLASS_NORMAL, 3},
    {"pow", ZMATH_TESTING_ORACLE_FORMAT_H, UINT64_C(0x0000), 1,
     UINT64_C(0xfc00), UINT64_C(0x7c00),
     ZMATH_TESTING_ORACLE_CLASS_INFINITY, 0},
    {"exp2m1", ZMATH_TESTING_ORACLE_FORMAT_H, UINT64_C(0x4a00), 0, 0,
     UINT64_C(0x6c00), ZMATH_TESTING_ORACLE_CLASS_NORMAL, 0},
    {"exp2m1", ZMATH_TESTING_ORACLE_FORMAT_H, UINT64_C(0xca00), 0, 0,
     UINT64_C(0xbc00), ZMATH_TESTING_ORACLE_CLASS_NORMAL, 0},
    Z_PI_CASES(
        ZMATH_TESTING_ORACLE_FORMAT_H,
        UINT64_C(0x3c00), UINT64_C(0xbc00),
        UINT64_C(0x3800), UINT64_C(0xb800),
        UINT64_C(0x3e00), UINT64_C(0xbe00),
        UINT64_C(0x8000), UINT64_C(0x7c00), UINT64_C(0xfc00)
    ),
    Z_PI_CASES(
        ZMATH_TESTING_ORACLE_FORMAT_F,
        UINT64_C(0x3f800000), UINT64_C(0xbf800000),
        UINT64_C(0x3f000000), UINT64_C(0xbf000000),
        UINT64_C(0x3fc00000), UINT64_C(0xbfc00000),
        UINT64_C(0x80000000), UINT64_C(0x7f800000), UINT64_C(0xff800000)
    ),
    Z_PI_CASES(
        ZMATH_TESTING_ORACLE_FORMAT_D,
        UINT64_C(0x3ff0000000000000), UINT64_C(0xbff0000000000000),
        UINT64_C(0x3fe0000000000000), UINT64_C(0xbfe0000000000000),
        UINT64_C(0x3ff8000000000000), UINT64_C(0xbff8000000000000),
        UINT64_C(0x8000000000000000), UINT64_C(0x7ff0000000000000),
        UINT64_C(0xfff0000000000000)
    ),
    Z_POWER_CASES(
        ZMATH_TESTING_ORACLE_FORMAT_H,
        UINT64_C(0x7c01), UINT64_C(0x7e01)
    ),
    Z_POWER_CASES(
        ZMATH_TESTING_ORACLE_FORMAT_F,
        UINT64_C(0x7f800001), UINT64_C(0x7fc00001)
    ),
    Z_POWER_CASES(
        ZMATH_TESTING_ORACLE_FORMAT_D,
        UINT64_C(0x7ff0000000000001), UINT64_C(0x7ff8000000000001)
    ),
    {"pown", ZMATH_TESTING_ORACLE_FORMAT_H, UINT64_C(0x7d55), 1, 0,
     UINT64_C(0x7f55), ZMATH_TESTING_ORACLE_CLASS_QNAN, 1},
    {"compoundn", ZMATH_TESTING_ORACLE_FORMAT_H, UINT64_C(0x7d55), 1, 0,
     UINT64_C(0x7f55), ZMATH_TESTING_ORACLE_CLASS_QNAN, 1},
};

int main(void) {
    size_t index;

    for (index = 0;
         index < sizeof(zmath_regression_cases) / sizeof(zmath_regression_cases[0]);
         ++index) {
        if (!zmath_run_case(&zmath_regression_cases[index])) return 1;
    }
    return 0;
}
