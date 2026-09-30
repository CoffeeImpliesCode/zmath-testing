#include "oracle_bridge.h"
#include "oracle_evaluators.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

void zmath_testing_oracle_evaluate_algebraic_reference(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result
);
void zmath_testing_oracle_evaluate_mpfr_reference(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result
);
#define ZMATH_TESTING_ORACLE_OPERATION_MAX 128

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
    const zmath_testing_oracle_format_descriptor *descriptor,
    zmath_testing_target_format *target
) {
    unsigned width;
    unsigned exponent_bits;
    unsigned fraction_bits;
    unsigned bias;

    if (descriptor == NULL || target == NULL || descriptor->reserved != 0) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    memset(target, 0, sizeof(*target));
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
        case ZMATH_TESTING_ORACLE_FORMAT_NONE:
            if (descriptor->storage_bits != 0 ||
                descriptor->exponent_bits != 0 ||
                descriptor->fraction_bits != 0) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            return ZMATH_TESTING_ORACLE_OK;
        default:
            return ZMATH_TESTING_ORACLE_UNSUPPORTED;
    }
    if (descriptor->storage_bits != width ||
        descriptor->exponent_bits != exponent_bits ||
        descriptor->fraction_bits != fraction_bits) {
        return ZMATH_TESTING_ORACLE_ERROR;
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
    return ZMATH_TESTING_ORACLE_OK;
}

static int zmath_testing_integer_width_is_valid(unsigned value_bits) {
    return value_bits == 2 || value_bits == 8 || value_bits == 16 ||
           value_bits == 32 || value_bits == 64;
}

static uint64_t zmath_testing_integer_mask(unsigned value_bits) {
    return value_bits == 64 ? UINT64_MAX :
                              (UINT64_C(1) << value_bits) - UINT64_C(1);
}

static int zmath_testing_decode_signed_integer(
    uint64_t value_bits,
    unsigned width,
    int64_t *value_out
) {
    uint64_t mask;
    uint64_t sign_bit;
    uint64_t extended;

    if (value_out == NULL || !zmath_testing_integer_width_is_valid(width)) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    mask = zmath_testing_integer_mask(width);
    if ((value_bits & ~mask) != 0) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    sign_bit = UINT64_C(1) << (width - 1);
    extended = value_bits & mask;
    if ((extended & sign_bit) != 0) {
        extended |= ~mask;
    }
    memcpy(value_out, &extended, sizeof(*value_out));
    return ZMATH_TESTING_ORACLE_OK;
}

static int zmath_testing_validate_input_field(
    const zmath_testing_oracle_input_field *field
) {
    if (field == NULL || field->reserved != 0) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    if (field->descriptor.kind == ZMATH_TESTING_ORACLE_FIELD_TAG) {
        if (field->descriptor.value_bits != 0 ||
            (field->tag_bytes == NULL) != (field->tag_length == 0)) {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
        return ZMATH_TESTING_ORACLE_OK;
    }
    if (field->tag_bytes != NULL || field->tag_length != 0) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    return ZMATH_TESTING_ORACLE_OK;
}


static int zmath_testing_validate_field_descriptor(
    const zmath_testing_oracle_field_descriptor *descriptor,
    zmath_testing_target_format *target
) {
    int status;

    if (descriptor == NULL || descriptor->reserved != 0) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    switch (descriptor->kind) {
        case ZMATH_TESTING_ORACLE_FIELD_FLOAT:
            if (descriptor->format.code == ZMATH_TESTING_ORACLE_FORMAT_NONE) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            status = zmath_testing_get_format(&descriptor->format, target);
            if (status != ZMATH_TESTING_ORACLE_OK) {
                return status;
            }
            if (descriptor->value_bits != target->width) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            return ZMATH_TESTING_ORACLE_OK;
        case ZMATH_TESTING_ORACLE_FIELD_SIGNED_INTEGER:
        case ZMATH_TESTING_ORACLE_FIELD_UNSIGNED_INTEGER:
            if (descriptor->format.code != ZMATH_TESTING_ORACLE_FORMAT_NONE) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            status = zmath_testing_get_format(&descriptor->format, target);
            if (status != ZMATH_TESTING_ORACLE_OK) {
                return status;
            }
            return zmath_testing_integer_width_is_valid(descriptor->value_bits) ?
                       ZMATH_TESTING_ORACLE_OK : ZMATH_TESTING_ORACLE_ERROR;
        case ZMATH_TESTING_ORACLE_FIELD_BOOLEAN:
            if (descriptor->format.code != ZMATH_TESTING_ORACLE_FORMAT_NONE) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            status = zmath_testing_get_format(&descriptor->format, target);
            if (status != ZMATH_TESTING_ORACLE_OK) {
                return status;
            }
            return descriptor->value_bits == 1 ?
                       ZMATH_TESTING_ORACLE_OK : ZMATH_TESTING_ORACLE_ERROR;
        case ZMATH_TESTING_ORACLE_FIELD_TAG:
            if (descriptor->format.code != ZMATH_TESTING_ORACLE_FORMAT_NONE) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            status = zmath_testing_get_format(&descriptor->format, target);
            if (status != ZMATH_TESTING_ORACLE_OK) {
                return status;
            }
            return descriptor->value_bits == 0 ?
                       ZMATH_TESTING_ORACLE_OK : ZMATH_TESTING_ORACLE_ERROR;
        case ZMATH_TESTING_ORACLE_FIELD_ROUNDING:
            if (descriptor->format.code != ZMATH_TESTING_ORACLE_FORMAT_NONE) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            status = zmath_testing_get_format(&descriptor->format, target);
            if (status != ZMATH_TESTING_ORACLE_OK) {
                return status;
            }
            return descriptor->value_bits == 32 ?
                       ZMATH_TESTING_ORACLE_OK : ZMATH_TESTING_ORACLE_ERROR;
        case ZMATH_TESTING_ORACLE_FIELD_ROUND_MODE:
            if (descriptor->format.code != ZMATH_TESTING_ORACLE_FORMAT_NONE) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            status = zmath_testing_get_format(&descriptor->format, target);
            if (status != ZMATH_TESTING_ORACLE_OK) {
                return status;
            }
            return descriptor->value_bits == 32 ?
                       ZMATH_TESTING_ORACLE_OK : ZMATH_TESTING_ORACLE_ERROR;
        case ZMATH_TESTING_ORACLE_FIELD_CLASSIFICATION:
            if (descriptor->format.code != ZMATH_TESTING_ORACLE_FORMAT_NONE) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            status = zmath_testing_get_format(&descriptor->format, target);
            if (status != ZMATH_TESTING_ORACLE_OK) {
                return status;
            }
            /* Six classes need three bits; a wider claim is a descriptor bug. */
            return descriptor->value_bits == 3 ?
                       ZMATH_TESTING_ORACLE_OK : ZMATH_TESTING_ORACLE_ERROR;
        default:
            return ZMATH_TESTING_ORACLE_ERROR;
    }
}
static int zmath_testing_value_bits_valid(
    const zmath_testing_oracle_field_descriptor *descriptor,
    const zmath_testing_target_format *target,
    uint64_t bits
) {
    if (descriptor->kind == ZMATH_TESTING_ORACLE_FIELD_FLOAT) {
        return (bits & ~target->value_mask) == 0;
    }
    if (descriptor->kind == ZMATH_TESTING_ORACLE_FIELD_BOOLEAN) {
        return bits <= 1;
    }
    if (descriptor->kind == ZMATH_TESTING_ORACLE_FIELD_SIGNED_INTEGER) {
        int64_t signed_value;
        return zmath_testing_decode_signed_integer(
                   bits, descriptor->value_bits, &signed_value) ==
               ZMATH_TESTING_ORACLE_OK;
    }
    if (descriptor->kind == ZMATH_TESTING_ORACLE_FIELD_UNSIGNED_INTEGER) {
        if (descriptor->value_bits == 64) {
            return 1;
        }
        return (bits >> descriptor->value_bits) == 0;
    }
    if (descriptor->kind == ZMATH_TESTING_ORACLE_FIELD_TAG) {
        return bits == 0;
    }
    if (descriptor->kind == ZMATH_TESTING_ORACLE_FIELD_ROUNDING) {
        return (bits >> 32) == 0;
    }
    if (descriptor->kind == ZMATH_TESTING_ORACLE_FIELD_ROUND_MODE) {
        return bits <= 3;
    }
    if (descriptor->kind == ZMATH_TESTING_ORACLE_FIELD_CLASSIFICATION) {
        return bits <= 5;
    }
    return 1;
}

static unsigned zmath_testing_structure_field_count(unsigned structure_kind) {
    switch (structure_kind) {
        case ZMATH_TESTING_ORACLE_STRUCTURE_CANONICALIZE:
        case ZMATH_TESTING_ORACLE_STRUCTURE_FREXP:
        case ZMATH_TESTING_ORACLE_STRUCTURE_MODF:
        case ZMATH_TESTING_ORACLE_STRUCTURE_REMQUO:
        case ZMATH_TESTING_ORACLE_STRUCTURE_LGAMMA:
        case ZMATH_TESTING_ORACLE_STRUCTURE_PAYLOAD:
        case ZMATH_TESTING_ORACLE_STRUCTURE_ATAN2:
        case ZMATH_TESTING_ORACLE_STRUCTURE_POWER:
        case ZMATH_TESTING_ORACLE_STRUCTURE_INTEGER:
            return 2;
        /* Four components: the Hamilton product's w, x, y, z. */
        case ZMATH_TESTING_ORACLE_STRUCTURE_QUATERNION:
            return 4;
        /* Eight coefficients: one per basis blade of Cl(3), in mask order. */
        case ZMATH_TESTING_ORACLE_STRUCTURE_ALGEBRA:
            return 8;
        /* Two components: the complex result's real and imaginary parts. */
        case ZMATH_TESTING_ORACLE_STRUCTURE_COMPLEX:
            return 2;
        /* Three channels: x0, x1, and the acceptance flag. */
        case ZMATH_TESTING_ORACLE_STRUCTURE_LU_SOLVE:
            return 3;
        default:
            return 0;
    }
}

static int zmath_testing_validate_structure_fields(
    const zmath_testing_oracle_request *request
) {
    const zmath_testing_oracle_field_descriptor *first =
        &request->result_fields[0];
    const zmath_testing_oracle_field_descriptor *second =
        &request->result_fields[1];
    zmath_testing_target_format ignored;
    int status;

    /*
     * A quaternion and a multivector are N components of ONE format, so the
     * second field is a float like the first and the count is fixed by the
     * kind rather than by the first two fields alone. The check runs over the
     * whole declared width and only for the two kinds that name it; anything
     * else still reaches the switch below, whose default arm refuses.
     */
    if (request->structure_kind == ZMATH_TESTING_ORACLE_STRUCTURE_QUATERNION ||
        request->structure_kind == ZMATH_TESTING_ORACLE_STRUCTURE_ALGEBRA) {
        const uint32_t field_count =
            request->structure_kind == ZMATH_TESTING_ORACLE_STRUCTURE_QUATERNION
                ? 4u
                : 8u;
        uint32_t index;

        if (request->result_field_count != field_count ||
            first->kind != ZMATH_TESTING_ORACLE_FIELD_FLOAT) {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
        status = zmath_testing_validate_field_descriptor(first, &ignored);
        if (status != ZMATH_TESTING_ORACLE_OK) {
            return status;
        }
        for (index = 1; index < field_count; ++index) {
            const zmath_testing_oracle_field_descriptor *field =
                &request->result_fields[index];
            if (field->kind != ZMATH_TESTING_ORACLE_FIELD_FLOAT ||
                field->value_bits != first->value_bits ||
                field->format.code != first->format.code ||
                field->format.storage_bits != first->format.storage_bits ||
                field->format.exponent_bits != first->format.exponent_bits ||
                field->format.fraction_bits != first->format.fraction_bits ||
                field->format.reserved != first->format.reserved) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            status = zmath_testing_validate_field_descriptor(field, &ignored);
            if (status != ZMATH_TESTING_ORACLE_OK) {
                return status;
            }
        }
        return ZMATH_TESTING_ORACLE_OK;
    }
    if (request->structure_kind == ZMATH_TESTING_ORACLE_STRUCTURE_INTEGER) {
        if (first->kind != ZMATH_TESTING_ORACLE_FIELD_SIGNED_INTEGER ||
            first->value_bits != 64) {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
    } else if (first->kind != ZMATH_TESTING_ORACLE_FIELD_FLOAT) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    status = zmath_testing_validate_field_descriptor(first, &ignored);
    if (status != ZMATH_TESTING_ORACLE_OK) {
        return status;
    }
    switch (request->structure_kind) {
        case ZMATH_TESTING_ORACLE_STRUCTURE_CANONICALIZE:
        case ZMATH_TESTING_ORACLE_STRUCTURE_PAYLOAD:
        case ZMATH_TESTING_ORACLE_STRUCTURE_ATAN2:
        case ZMATH_TESTING_ORACLE_STRUCTURE_POWER:
        case ZMATH_TESTING_ORACLE_STRUCTURE_INTEGER:
            if (second->kind != ZMATH_TESTING_ORACLE_FIELD_BOOLEAN) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            break;
        case ZMATH_TESTING_ORACLE_STRUCTURE_FREXP:
        case ZMATH_TESTING_ORACLE_STRUCTURE_REMQUO:
            if (second->kind != ZMATH_TESTING_ORACLE_FIELD_SIGNED_INTEGER ||
                second->value_bits != 32) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            break;
        /*
         * COMPLEX is MODF's shape: a second float of the first field's format.
         * LU_SOLVE adds a trailing boolean, so its second field repeats the
         * same check and the third is left to the arm below.
         */
        case ZMATH_TESTING_ORACLE_STRUCTURE_COMPLEX:
        case ZMATH_TESTING_ORACLE_STRUCTURE_LU_SOLVE:
        case ZMATH_TESTING_ORACLE_STRUCTURE_MODF:
            if (second->kind != ZMATH_TESTING_ORACLE_FIELD_FLOAT ||
                second->value_bits != first->value_bits ||
                second->format.code != first->format.code ||
                second->format.storage_bits != first->format.storage_bits ||
                second->format.exponent_bits != first->format.exponent_bits ||
                second->format.fraction_bits != first->format.fraction_bits ||
                second->format.reserved != first->format.reserved) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            break;
        case ZMATH_TESTING_ORACLE_STRUCTURE_LGAMMA:
            if (second->kind != ZMATH_TESTING_ORACLE_FIELD_SIGNED_INTEGER ||
                second->value_bits != 2) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            break;
        default:
            return ZMATH_TESTING_ORACLE_ERROR;
    }
    status = zmath_testing_validate_field_descriptor(second, &ignored);
    if (status != ZMATH_TESTING_ORACLE_OK ||
        request->structure_kind != ZMATH_TESTING_ORACLE_STRUCTURE_LU_SOLVE) {
        return status;
    }
    /*
     * LU_SOLVE is the only three-field structure, and its caller has already
     * fixed the width at three, so the flag is in range here.
     */
    if (request->result_fields[2].kind != ZMATH_TESTING_ORACLE_FIELD_BOOLEAN) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    return zmath_testing_validate_field_descriptor(
        &request->result_fields[2], &ignored);
}

static int zmath_testing_operation_name_is_valid(
    const zmath_testing_oracle_request *request
) {
    uint32_t index;

    if (request->operation == NULL || request->operation_length == 0 ||
        request->operation_length > ZMATH_TESTING_ORACLE_OPERATION_MAX) {
        return 0;
    }
    for (index = 0; index < request->operation_length; ++index) {
        const uint8_t character = request->operation[index];
        const int first = index == 0;
        const int alpha = (character >= 'a' && character <= 'z') ||
                          (character >= 'A' && character <= 'Z');
        const int digit = character >= '0' && character <= '9';
        if (first) {
            if (!alpha && character != '_') {
                return 0;
            }
        } else if (!alpha && !digit && character != '_') {
            return 0;
        }
    }
    return 1;
}

static int zmath_testing_validate_request(
    const zmath_testing_oracle_request *request
) {
    zmath_testing_target_format ignored;
    int status;
    int input_unsupported = 0;
    int result_unsupported = 0;
    uint32_t index;
    unsigned expected_fields;

    if (request == NULL) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    if (request->abi_version != ZMATH_TESTING_ORACLE_ABI_VERSION ||
        request->reserved != 0 || !zmath_testing_operation_name_is_valid(request)) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    if (request->arity == 0 || request->arity > ZMATH_TESTING_ORACLE_MAX_FIELDS ||
        request->input_field_count != request->arity ||
        request->input_fields == NULL) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    for (index = 0; index < request->input_field_count; ++index) {
        status = zmath_testing_validate_input_field(
            &request->input_fields[index]);
        if (status != ZMATH_TESTING_ORACLE_OK) {
            return status;
        }
        status = zmath_testing_validate_field_descriptor(
            &request->input_fields[index].descriptor, &ignored);
        if (status == ZMATH_TESTING_ORACLE_ERROR) {
            return status;
        }
        if (status == ZMATH_TESTING_ORACLE_UNSUPPORTED) {
            input_unsupported = 1;
        }
        if (status == ZMATH_TESTING_ORACLE_OK &&
            !zmath_testing_value_bits_valid(
                &request->input_fields[index].descriptor,
                &ignored,
                request->input_fields[index].value_bits)) {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
    }

    if (request->result_field_count == 0 ||
        request->result_field_count > ZMATH_TESTING_ORACLE_MAX_FIELDS ||
        request->result_fields == NULL) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    switch (request->result_layout) {
        case ZMATH_TESTING_ORACLE_RESULT_SCALAR:
            if (request->structure_kind != ZMATH_TESTING_ORACLE_STRUCTURE_NONE ||
                request->result_field_count != 1) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            break;
        case ZMATH_TESTING_ORACLE_RESULT_STRUCTURE:
            expected_fields = zmath_testing_structure_field_count(
                request->structure_kind);
            if (expected_fields == 0 ||
                request->result_field_count != expected_fields) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
            status = zmath_testing_validate_structure_fields(request);
            if (status == ZMATH_TESTING_ORACLE_ERROR) {
                return status;
            }
            if (status == ZMATH_TESTING_ORACLE_UNSUPPORTED) {
                result_unsupported = 1;
            }
            break;
        default:
            return ZMATH_TESTING_ORACLE_ERROR;
    }
    for (index = 0; index < request->result_field_count; ++index) {
        if (request->result_fields[index].kind ==
            ZMATH_TESTING_ORACLE_FIELD_TAG) {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
        status = zmath_testing_validate_field_descriptor(
            &request->result_fields[index], &ignored);
        if (status == ZMATH_TESTING_ORACLE_ERROR) {
            return status;
        }
        if (status == ZMATH_TESTING_ORACLE_UNSUPPORTED) {
            result_unsupported = 1;
        }
    }
    if (input_unsupported || result_unsupported) {
        return ZMATH_TESTING_ORACLE_UNSUPPORTED;
    }
    return ZMATH_TESTING_ORACLE_OK;
}

static int zmath_testing_validate_result_storage(
    const zmath_testing_oracle_result *result,
    uint32_t field_count
) {
    if (result == NULL || result->reserved != 0 ||
        result->field_capacity < field_count ||
        (field_count != 0 && result->fields == NULL)) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    return ZMATH_TESTING_ORACLE_OK;
}

static void zmath_testing_initialize_result(zmath_testing_oracle_result *result) {
    if (result != NULL) {
        result->status = ZMATH_TESTING_ORACLE_ERROR;
        result->field_count = 0;
    }
}












static int zmath_testing_descriptor_equal(
    const zmath_testing_oracle_field_descriptor *left,
    const zmath_testing_oracle_field_descriptor *right
) {
    if (left == NULL || right == NULL) {
        return 0;
    }
    return left->kind == right->kind && left->value_bits == right->value_bits &&
           left->format.code == right->format.code &&
           left->format.storage_bits == right->format.storage_bits &&
           left->format.exponent_bits == right->format.exponent_bits &&
           left->format.fraction_bits == right->format.fraction_bits &&
           left->format.reserved == right->format.reserved &&
           left->reserved == right->reserved;
}

static int zmath_testing_signature_matches_request(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request
) {
    uint32_t index;

    if (signature == NULL || request == NULL ||
        signature->operation == NULL || request->operation == NULL ||
        signature->arguments == NULL || signature->result_fields == NULL ||
        request->input_fields == NULL || request->result_fields == NULL ||
        signature->arity == 0 ||
        signature->arity > ZMATH_TESTING_ORACLE_MAX_FIELDS ||
        signature->result_field_count == 0 ||
        signature->result_field_count > ZMATH_TESTING_ORACLE_MAX_FIELDS ||
        signature->operation_length != request->operation_length ||
        memcmp(
            signature->operation,
            request->operation,
            signature->operation_length
        ) != 0 ||
        signature->arity != request->arity ||
        signature->arity != request->input_field_count ||
        signature->result_layout != request->result_layout ||
        signature->structure_kind != request->structure_kind ||
        signature->result_field_count != request->result_field_count) {
        return 0;
    }
    for (index = 0; index < signature->arity; ++index) {
        if (!zmath_testing_descriptor_equal(
                &signature->arguments[index],
                &request->input_fields[index].descriptor)) {
            return 0;
        }
    }
    for (index = 0; index < signature->result_field_count; ++index) {
        if (!zmath_testing_descriptor_equal(
                &signature->result_fields[index],
                &request->result_fields[index])) {
            return 0;
        }
    }
    return 1;
}

static int zmath_testing_validate_and_lookup(
    const zmath_testing_oracle_request *request,
    const zmath_testing_oracle_operation_signature **signature_out
) {
    const zmath_testing_oracle_operation_signature *signature;
    int status;

    if (signature_out == NULL) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    *signature_out = NULL;
    status = zmath_testing_validate_request(request);
    if (status != ZMATH_TESTING_ORACLE_OK) {
        return status;
    }
    signature = zmath_testing_oracle_find_operation_signature(request);
    if (!zmath_testing_signature_matches_request(signature, request) ||
        signature->result_field_count > ZMATH_TESTING_ORACLE_MAX_FIELDS) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    *signature_out = signature;
    return ZMATH_TESTING_ORACLE_OK;
}

static void zmath_testing_initialize_dispatch_result(
    zmath_testing_oracle_result *result,
    zmath_testing_oracle_result_field *fields
) {
    memset(fields, 0, sizeof(*fields) * ZMATH_TESTING_ORACLE_MAX_FIELDS);
    result->status = ZMATH_TESTING_ORACLE_ERROR;
    result->reserved = 0;
    result->field_capacity = ZMATH_TESTING_ORACLE_MAX_FIELDS;
    result->field_count = 0;
    result->fields = fields;
}

static void zmath_testing_dispatch_evaluator(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result,
    int require_proof
) {
    if (signature == NULL || request == NULL || result == NULL) {
        if (result != NULL) {
            result->status = ZMATH_TESTING_ORACLE_ERROR;
            result->field_count = 0;
        }
        return;
    }
    switch (signature->evaluator_category) {
        case ZMATH_TESTING_ORACLE_EVALUATOR_EXACT_BITS:
            zmath_testing_oracle_evaluate_exact_bits(signature, request, result);
            return;
        case ZMATH_TESTING_ORACLE_EVALUATOR_ALGEBRAIC:
            if (require_proof) {
                zmath_testing_oracle_evaluate_algebraic(
                    signature, request, result);
            } else {
                zmath_testing_oracle_evaluate_algebraic_reference(
                    signature, request, result);
            }
            return;
        case ZMATH_TESTING_ORACLE_EVALUATOR_MPFR_ARB:
            if (require_proof) {
                zmath_testing_oracle_evaluate_mpfr_arb(
                    signature, request, result);
            } else {
                zmath_testing_oracle_evaluate_mpfr_reference(
                    signature, request, result);
            }
            return;
        case ZMATH_TESTING_ORACLE_EVALUATOR_DEFINITIONAL:
            /*
             * A definitional row is decided by the IEEE 754 definition, not by
             * a numerical oracle. Both entries return the single bit-level
             * answer the definition fixes, so there is no interval to certify
             * and therefore no separate proof route.
             */
            zmath_testing_oracle_evaluate_definitional(signature, request, result);
            return;
        default:
            result->status = ZMATH_TESTING_ORACLE_ERROR;
            result->field_count = 0;
            return;
    }
}

static int zmath_testing_evaluator_status(
    const zmath_testing_oracle_result *result
) {
    if (result == NULL) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    switch (result->status) {
        case ZMATH_TESTING_ORACLE_OK:
        case ZMATH_TESTING_ORACLE_UNSUPPORTED:
        case ZMATH_TESTING_ORACLE_ERROR:
        case ZMATH_TESTING_ORACLE_UNCERTAIN:
            return (int)result->status;
        default:
            return ZMATH_TESTING_ORACLE_ERROR;
    }
}

static uint32_t zmath_testing_float_class(
    const zmath_testing_target_format *target,
    uint64_t bits
) {
    const uint64_t exponent = bits & target->exponent_mask;
    const uint64_t fraction = bits & target->fraction_mask;

    if (exponent == target->exponent_mask) {
        if (fraction == 0) return ZMATH_TESTING_ORACLE_CLASS_INFINITY;
        return (fraction & (UINT64_C(1) << (target->fraction_bits - 1))) != 0 ?
            ZMATH_TESTING_ORACLE_CLASS_QNAN : ZMATH_TESTING_ORACLE_CLASS_SNAN;
    }
    if (exponent == 0) {
        return fraction == 0 ?
            ZMATH_TESTING_ORACLE_CLASS_ZERO : ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL;
    }
    return ZMATH_TESTING_ORACLE_CLASS_NORMAL;
}

static int zmath_testing_validate_evaluator_result(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_result *result
) {
    uint32_t index;
    int status;

    if (signature == NULL || result == NULL ||
        result->reserved != 0 ||
        result->status != ZMATH_TESTING_ORACLE_OK ||
        result->field_count != signature->result_field_count ||
        result->fields == NULL ||
        result->field_capacity < signature->result_field_count ||
        signature->result_fields == NULL) {
        return ZMATH_TESTING_ORACLE_ERROR;
    }
    for (index = 0; index < signature->result_field_count; ++index) {
        zmath_testing_target_format target;
        const zmath_testing_oracle_result_field *field =
            &result->fields[index];

        if (field->reserved != 0 ||
            !zmath_testing_descriptor_equal(
                &field->descriptor,
                &signature->result_fields[index])) {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
        status = zmath_testing_validate_field_descriptor(
            &field->descriptor,
            &target
        );
        if (status != ZMATH_TESTING_ORACLE_OK) {
            return status == ZMATH_TESTING_ORACLE_UNSUPPORTED ?
                       status : ZMATH_TESTING_ORACLE_ERROR;
        }
        if (!zmath_testing_value_bits_valid(
                &field->descriptor,
                &target,
                field->value_bits)) {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
        if (field->descriptor.kind == ZMATH_TESTING_ORACLE_FIELD_FLOAT) {
            if (field->class_code !=
                zmath_testing_float_class(&target, field->value_bits)) {
                return ZMATH_TESTING_ORACLE_ERROR;
            }
        } else if (field->class_code != ZMATH_TESTING_ORACLE_CLASS_NONE) {
            return ZMATH_TESTING_ORACLE_ERROR;
        }
    }
    return ZMATH_TESTING_ORACLE_OK;
}

static int zmath_testing_validate_candidate(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_result *candidate
) {
    return zmath_testing_validate_evaluator_result(signature, candidate);
}

static int zmath_testing_result_fields_equal(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_result *left,
    const zmath_testing_oracle_result *right
) {
    uint32_t index;

    if (signature == NULL || left == NULL || right == NULL) {
        return 0;
    }
    for (index = 0; index < signature->result_field_count; ++index) {
        if (left->fields[index].value_bits != right->fields[index].value_bits ||
            left->fields[index].class_code != right->fields[index].class_code ||
            left->fields[index].reserved != right->fields[index].reserved) {
            return 0;
        }
    }
    return 1;
}

void zmath_testing_oracle_v2_mpfr_reference(
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result
) {
    const zmath_testing_oracle_operation_signature *signature;
    zmath_testing_oracle_result evaluated;
    zmath_testing_oracle_result_field fields[ZMATH_TESTING_ORACLE_MAX_FIELDS];
    int status;

    zmath_testing_initialize_result(result);
    if (result == NULL) {
        return;
    }
    status = zmath_testing_validate_and_lookup(request, &signature);
    if (status != ZMATH_TESTING_ORACLE_OK) {
        result->status = (uint32_t)status;
        return;
    }
    status = zmath_testing_validate_result_storage(
        result,
        signature->result_field_count
    );
    if (status != ZMATH_TESTING_ORACLE_OK) {
        result->status = (uint32_t)status;
        return;
    }
    zmath_testing_initialize_dispatch_result(&evaluated, fields);
    zmath_testing_dispatch_evaluator(signature, request, &evaluated, 0);
    status = zmath_testing_evaluator_status(&evaluated);
    if (status != ZMATH_TESTING_ORACLE_OK) {
        result->status = (uint32_t)status;
        return;
    }
    status = zmath_testing_validate_evaluator_result(signature, &evaluated);
    if (status != ZMATH_TESTING_ORACLE_OK) {
        result->status = (uint32_t)status;
        return;
    }
    memcpy(
        result->fields,
        evaluated.fields,
        sizeof(result->fields[0]) * signature->result_field_count
    );
    result->field_count = signature->result_field_count;
    result->status = ZMATH_TESTING_ORACLE_OK;
}

void zmath_testing_oracle_v2_arb_prove(
    const zmath_testing_oracle_request *request,
    const zmath_testing_oracle_result *candidate,
    zmath_testing_oracle_result *proof
) {
    const zmath_testing_oracle_operation_signature *signature;
    zmath_testing_oracle_result evaluated;
    zmath_testing_oracle_result_field fields[ZMATH_TESTING_ORACLE_MAX_FIELDS];
    int status;

    zmath_testing_initialize_result(proof);
    if (proof == NULL) {
        return;
    }
    status = zmath_testing_validate_and_lookup(request, &signature);
    if (status != ZMATH_TESTING_ORACLE_OK) {
        proof->status = (uint32_t)status;
        return;
    }
    status = zmath_testing_validate_candidate(signature, candidate);
    if (status != ZMATH_TESTING_ORACLE_OK) {
        proof->status = (uint32_t)status;
        return;
    }
    status = zmath_testing_validate_result_storage(
        proof,
        signature->result_field_count
    );
    if (status != ZMATH_TESTING_ORACLE_OK) {
        proof->status = (uint32_t)status;
        return;
    }
    zmath_testing_initialize_dispatch_result(&evaluated, fields);
    zmath_testing_dispatch_evaluator(signature, request, &evaluated, 1);
    status = zmath_testing_evaluator_status(&evaluated);
    if (status != ZMATH_TESTING_ORACLE_OK) {
        proof->status = (uint32_t)status;
        return;
    }
    status = zmath_testing_validate_evaluator_result(signature, &evaluated);
    if (status != ZMATH_TESTING_ORACLE_OK) {
        proof->status = (uint32_t)status;
        return;
    }
    if (!zmath_testing_result_fields_equal(signature, candidate, &evaluated)) {
        proof->status = ZMATH_TESTING_ORACLE_UNCERTAIN;
        return;
    }
    memcpy(
        proof->fields,
        evaluated.fields,
        sizeof(proof->fields[0]) * signature->result_field_count
    );
    proof->field_count = signature->result_field_count;
    proof->status = ZMATH_TESTING_ORACLE_OK;
}
