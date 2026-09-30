#ifndef ZMATH_TESTING_ORACLE_BRIDGE_H
#define ZMATH_TESTING_ORACLE_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
#ifdef __cplusplus
#define ZMATH_TESTING_ORACLE_STATIC_ASSERT static_assert
#else
#define ZMATH_TESTING_ORACLE_STATIC_ASSERT _Static_assert
#endif

#define ZMATH_TESTING_ORACLE_ABI_VERSION UINT32_C(2)
#define ZMATH_TESTING_ORACLE_MAX_FIELDS UINT32_C(8)

enum zmath_testing_oracle_status {
    ZMATH_TESTING_ORACLE_OK = 0,
    ZMATH_TESTING_ORACLE_UNSUPPORTED = 1,
    ZMATH_TESTING_ORACLE_ERROR = 2,
    ZMATH_TESTING_ORACLE_UNCERTAIN = 3,
};

enum zmath_testing_oracle_format_code {
    ZMATH_TESTING_ORACLE_FORMAT_NONE = 0,
    ZMATH_TESTING_ORACLE_FORMAT_H = 1,
    ZMATH_TESTING_ORACLE_FORMAT_F = 2,
    ZMATH_TESTING_ORACLE_FORMAT_D = 3,
};

enum zmath_testing_oracle_field_kind {
    ZMATH_TESTING_ORACLE_FIELD_FLOAT = 1,
    ZMATH_TESTING_ORACLE_FIELD_SIGNED_INTEGER = 2,
    ZMATH_TESTING_ORACLE_FIELD_UNSIGNED_INTEGER = 3,
    ZMATH_TESTING_ORACLE_FIELD_BOOLEAN = 4,
    ZMATH_TESTING_ORACLE_FIELD_TAG = 5,
    ZMATH_TESTING_ORACLE_FIELD_ROUNDING = 6,
    /*
     * ROUND_MODE is deliberately distinct from ROUNDING. ROUNDING carries the
     * five fromfp directions, ROUND_MODE the four IEEE 754 directions, and the
     * two vocabularies number them differently. One field kind must never be
     * reinterpretable as the other.
     */
    ZMATH_TESTING_ORACLE_FIELD_ROUND_MODE = 7,
    /* A six-value class enumeration. It is not an integer result. */
    ZMATH_TESTING_ORACLE_FIELD_CLASSIFICATION = 8,
};

enum zmath_testing_oracle_result_layout {
    ZMATH_TESTING_ORACLE_RESULT_SCALAR = 1,
    ZMATH_TESTING_ORACLE_RESULT_STRUCTURE = 2,
};

enum zmath_testing_oracle_structure_kind {
    ZMATH_TESTING_ORACLE_STRUCTURE_NONE = 0,
    ZMATH_TESTING_ORACLE_STRUCTURE_CANONICALIZE = 1,
    ZMATH_TESTING_ORACLE_STRUCTURE_FREXP = 2,
    ZMATH_TESTING_ORACLE_STRUCTURE_MODF = 3,
    ZMATH_TESTING_ORACLE_STRUCTURE_REMQUO = 4,
    ZMATH_TESTING_ORACLE_STRUCTURE_LGAMMA = 5,
    ZMATH_TESTING_ORACLE_STRUCTURE_PAYLOAD = 6,
    ZMATH_TESTING_ORACLE_STRUCTURE_ATAN2 = 7,
    ZMATH_TESTING_ORACLE_STRUCTURE_POWER = 8,
    ZMATH_TESTING_ORACLE_STRUCTURE_INTEGER = 9,
};

enum zmath_testing_oracle_class {
    ZMATH_TESTING_ORACLE_CLASS_NORMAL = 0,
    ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL = 1,
    ZMATH_TESTING_ORACLE_CLASS_ZERO = 2,
    ZMATH_TESTING_ORACLE_CLASS_INFINITY = 3,
    ZMATH_TESTING_ORACLE_CLASS_QNAN = 4,
    ZMATH_TESTING_ORACLE_CLASS_NONE = 5,
    ZMATH_TESTING_ORACLE_CLASS_SNAN = 6,
};

/*
 * Every descriptor is explicit. The bridge accepts only IEEE binary16,
 * binary32, and binary64 format layouts for successful MPFR/Arb evidence.
 * Any other format code is unsupported and never produces successful evidence.
 */
typedef struct zmath_testing_oracle_format_descriptor {
    uint32_t code;
    uint32_t storage_bits;
    uint32_t exponent_bits;
    uint32_t fraction_bits;
    uint32_t reserved;
} zmath_testing_oracle_format_descriptor;

typedef struct zmath_testing_oracle_field_descriptor {
    uint32_t kind;
    uint32_t value_bits;
    zmath_testing_oracle_format_descriptor format;
    uint32_t reserved;
} zmath_testing_oracle_field_descriptor;

typedef struct zmath_testing_oracle_input_field {
    zmath_testing_oracle_field_descriptor descriptor;
    uint64_t value_bits;
    const uint8_t *tag_bytes;
    uint32_t tag_length;
    uint32_t reserved;
} zmath_testing_oracle_input_field;

typedef struct zmath_testing_oracle_result_field {
    zmath_testing_oracle_field_descriptor descriptor;
    uint64_t value_bits;
    uint32_t class_code;
    uint32_t reserved;
} zmath_testing_oracle_result_field;

typedef struct zmath_testing_oracle_request {
    uint32_t abi_version;
    uint32_t reserved;
    const uint8_t *operation;
    uint32_t operation_length;
    uint32_t arity;
    const zmath_testing_oracle_input_field *input_fields;
    uint32_t input_field_count;
    uint32_t result_layout;
    uint32_t structure_kind;
    uint32_t result_field_count;
    const zmath_testing_oracle_field_descriptor *result_fields;
} zmath_testing_oracle_request;

ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    sizeof(zmath_testing_oracle_format_descriptor) == 20,
    "oracle format descriptor ABI drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_format_descriptor, code) == 0,
    "oracle format descriptor code order drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_format_descriptor, storage_bits) == 4,
    "oracle format descriptor storage order drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_format_descriptor, exponent_bits) == 8,
    "oracle format descriptor exponent order drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_format_descriptor, fraction_bits) == 12,
    "oracle format descriptor fraction order drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_format_descriptor, reserved) == 16,
    "oracle format descriptor reserved order drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_field_descriptor, kind) == 0,
    "oracle field descriptor kind order drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_field_descriptor, value_bits) == 4,
    "oracle field descriptor width order drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_field_descriptor, format) == 8,
    "oracle field descriptor format order drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_field_descriptor, reserved) == 28,
    "oracle field descriptor reserved order drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    sizeof(zmath_testing_oracle_field_descriptor) == 32,
    "oracle field descriptor ABI drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    sizeof(zmath_testing_oracle_input_field) == 56,
    "oracle input field ABI drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    sizeof(zmath_testing_oracle_result_field) == 48,
    "oracle result field ABI drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    sizeof(zmath_testing_oracle_request) == 56,
    "oracle request ABI drift"
);
typedef struct zmath_testing_oracle_result {
    uint32_t status;
    uint32_t reserved;
    uint32_t field_capacity;
    uint32_t field_count;
    zmath_testing_oracle_result_field *fields;
} zmath_testing_oracle_result;
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    sizeof(zmath_testing_oracle_result) == 24,
    "oracle result ABI drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_input_field, descriptor) == 0,
    "oracle input field descriptor order drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_input_field, value_bits) == 32,
    "oracle input field value order drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_input_field, tag_bytes) == 40,
    "oracle input field tag pointer order drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_input_field, tag_length) == 48,
    "oracle input field tag length order drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_input_field, reserved) == 52,
    "oracle input field reserved order drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_result_field, descriptor) == 0,
    "oracle result field descriptor order drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_result_field, value_bits) == 32,
    "oracle result field value order drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_result_field, class_code) == 40,
    "oracle result field class order drift"
);
ZMATH_TESTING_ORACLE_STATIC_ASSERT(
    offsetof(zmath_testing_oracle_result_field, reserved) == 44,
    "oracle result field reserved order drift"
);
#undef ZMATH_TESTING_ORACLE_STATIC_ASSERT

struct zmath_testing_oracle_operation_signature;

void zmath_testing_oracle_evaluate_exact_bits(
    const struct zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result
);

void zmath_testing_oracle_evaluate_algebraic(
    const struct zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result
);

void zmath_testing_oracle_evaluate_mpfr_arb(
    const struct zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result
);

/*
 * The definitional entry point evaluates the IEEE 754 definition directly. It
 * shares the bit-level machinery with the exact-bits evaluator but is a
 * separate entry point, and it accepts only the definitional category, so the
 * two categories can never satisfy each other.
 */
void zmath_testing_oracle_evaluate_definitional(
    const struct zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result
);

/*
 * The v2 MPFR entry point validates the request against the immutable
 * operation table, then dispatches to the evaluator selected by that row.
 * It copies result fields only after the evaluator reports a validated OK
 * result. Unsupported, uncertain, malformed, or mismatched results fail
 * closed with field_count zero.
 */
void zmath_testing_oracle_v2_mpfr_reference(
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result
);

/*
 * The Arb entry point repeats request/table validation, validates the
 * candidate against the immutable result descriptors, and dispatches the
 * same evaluator category route. A disagreement or evaluator uncertainty
 * returns UNCERTAIN; malformed descriptors and unknown categories fail
 * closed with field_count zero.
 */
void zmath_testing_oracle_v2_arb_prove(
    const zmath_testing_oracle_request *request,
    const zmath_testing_oracle_result *candidate,
    zmath_testing_oracle_result *proof
);

#ifdef __cplusplus
}
#endif

#endif
