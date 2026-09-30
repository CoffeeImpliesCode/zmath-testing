#ifndef ZMATH_TESTING_ORACLE_EVALUATORS_H
#define ZMATH_TESTING_ORACLE_EVALUATORS_H

#include <stddef.h>
#include <stdint.h>

#include "oracle_bridge.h"

#ifdef __cplusplus
extern "C" {
#endif

#define ZMATH_TESTING_ORACLE_EVALUATOR_ABI_VERSION UINT32_C(1)
#define ZMATH_TESTING_ORACLE_OPERATION_COUNT UINT32_C(323)
#define ZMATH_TESTING_ORACLE_MAX_SIGNATURE_FIELDS \
    ZMATH_TESTING_ORACLE_MAX_FIELDS

enum zmath_testing_oracle_provenance {
    ZMATH_TESTING_ORACLE_PROVENANCE_C23_7_12 = 0,
    ZMATH_TESTING_ORACLE_PROVENANCE_C23_IEEE = 1,
    ZMATH_TESTING_ORACLE_PROVENANCE_ANNEX_F = 2,
    ZMATH_TESTING_ORACLE_PROVENANCE_ANNEX_H = 3,
};

enum zmath_testing_oracle_evaluator_category {
    ZMATH_TESTING_ORACLE_EVALUATOR_EXACT_BITS = 1,
    ZMATH_TESTING_ORACLE_EVALUATOR_MPFR_ARB = 2,
    ZMATH_TESTING_ORACLE_EVALUATOR_ALGEBRAIC = 3,
    /*
     * DEFINITIONAL marks a bit-level operation whose correct result is fixed
     * by the IEEE 754 definition itself. No arbitrary-precision oracle can
     * decide it, so the evaluation is definitional, not numerical. The class
     * exists so a reader can never mistake one of these rows for an
     * oracle-verified row.
     */
    ZMATH_TESTING_ORACLE_EVALUATOR_DEFINITIONAL = 4,
};
/*
 * A category selects an evaluator implementation. It does not grant manifest
 * acceptance, oracle capability, or a numerical error bound.
 */

typedef struct zmath_testing_oracle_operation_signature {
    const char *operation;
    uint32_t operation_length;
    uint32_t provenance;
    uint32_t evaluator_category;
    uint32_t arity;
    const zmath_testing_oracle_field_descriptor *arguments;
    uint32_t result_layout;
    uint32_t structure_kind;
    uint32_t result_field_count;
    const zmath_testing_oracle_field_descriptor *result_fields;
} zmath_testing_oracle_operation_signature;

/*
 * Evaluator implementations receive one validated signature from the table.
 * They must not infer arity, formats, result fields, or provenance from the
 * operation spelling. The existing result status is the only outcome channel;
 * dispatch and bridge integration remain separate concerns.
 */
typedef void (*zmath_testing_oracle_evaluator_fn)(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result
);

typedef struct zmath_testing_oracle_evaluator {
    uint32_t category;
    zmath_testing_oracle_evaluator_fn evaluate;
} zmath_testing_oracle_evaluator;

extern const zmath_testing_oracle_operation_signature
    zmath_testing_oracle_operation_table[ZMATH_TESTING_ORACLE_OPERATION_COUNT];
extern const uint32_t zmath_testing_oracle_operation_table_count;

const zmath_testing_oracle_operation_signature *
zmath_testing_oracle_find_operation_signature(
    const zmath_testing_oracle_request *request
);

#ifdef __cplusplus
}
#endif

#endif
