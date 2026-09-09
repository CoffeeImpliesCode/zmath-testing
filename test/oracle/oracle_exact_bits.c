#include "oracle_evaluators.h"

#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define Z_EXACT_MAX_FIELDS ZMATH_TESTING_ORACLE_MAX_SIGNATURE_FIELDS
#define Z_EXACT_GUARD_BITS 3u

typedef unsigned __int128 z_exact_u128;

typedef struct z_exact_format {
    unsigned width;
    unsigned exponent_bits;
    unsigned fraction_bits;
    int bias;
    uint64_t sign_mask;
    uint64_t exponent_mask;
    uint64_t fraction_mask;
    uint64_t value_mask;
    uint64_t quiet_nan_bit;
} z_exact_format;

typedef struct z_exact_parts {
    int negative;
    uint64_t significand;
    int exponent;
} z_exact_parts;

typedef struct z_exact_build {
    zmath_testing_oracle_result_field fields[Z_EXACT_MAX_FIELDS];
    uint32_t field_count;
} z_exact_build;

_Static_assert(ZMATH_TESTING_ORACLE_OPERATION_COUNT == 315,
               "oracle operation table count drift");

static int z_exact_is_operation(const zmath_testing_oracle_operation_signature *signature,
                                const char *operation) {
    size_t length = strlen(operation);
    return signature != NULL && signature->operation != NULL &&
           signature->operation_length == (uint32_t)length &&
           memcmp(signature->operation, operation, length) == 0;
}

static int z_exact_descriptor_equal(const zmath_testing_oracle_field_descriptor *left,
                                    const zmath_testing_oracle_field_descriptor *right) {
    return left != NULL && right != NULL && left->kind == right->kind &&
           left->value_bits == right->value_bits &&
           left->format.code == right->format.code &&
           left->format.storage_bits == right->format.storage_bits &&
           left->format.exponent_bits == right->format.exponent_bits &&
           left->format.fraction_bits == right->format.fraction_bits &&
           left->format.reserved == right->format.reserved &&
           left->reserved == right->reserved;
}

static int z_exact_signature_is_table_row(
    const zmath_testing_oracle_operation_signature *signature) {
    uint32_t index;
    if (signature == NULL) return 0;
    for (index = 0; index < zmath_testing_oracle_operation_table_count; ++index) {
        if (signature == &zmath_testing_oracle_operation_table[index]) return 1;
    }
    return 0;
}

static int z_exact_mask(unsigned width, uint64_t *mask_out) {
    if (mask_out == NULL || width == 0 || width > 64) return 0;
    *mask_out = width == 64 ? UINT64_MAX : (UINT64_C(1) << width) - 1;
    return 1;
}

static int z_exact_decode_signed(uint64_t encoded, unsigned width, int64_t *value_out) {
    uint64_t mask;
    uint64_t extended;
    if (value_out == NULL || !z_exact_mask(width, &mask) || (encoded & ~mask) != 0) return 0;
    extended = encoded & mask;
    if ((extended & (UINT64_C(1) << (width - 1))) != 0) extended |= ~mask;
    memcpy(value_out, &extended, sizeof(*value_out));
    return 1;
}

static uint64_t z_exact_encode_signed(int64_t value, unsigned width) {
    uint64_t encoded;
    uint64_t mask;
    memcpy(&encoded, &value, sizeof(encoded));
    if (!z_exact_mask(width, &mask)) return 0;
    return encoded & mask;
}

static int z_exact_get_format(const zmath_testing_oracle_field_descriptor *descriptor,
                              z_exact_format *format_out) {
    z_exact_format format;
    if (descriptor == NULL || format_out == NULL ||
        descriptor->kind != ZMATH_TESTING_ORACLE_FIELD_FLOAT) return 0;
    memset(&format, 0, sizeof(format));
    switch (descriptor->format.code) {
        case ZMATH_TESTING_ORACLE_FORMAT_H:
            format.width = 16; format.exponent_bits = 5; format.fraction_bits = 10; format.bias = 15;
            break;
        case ZMATH_TESTING_ORACLE_FORMAT_F:
            format.width = 32; format.exponent_bits = 8; format.fraction_bits = 23; format.bias = 127;
            break;
        case ZMATH_TESTING_ORACLE_FORMAT_D:
            format.width = 64; format.exponent_bits = 11; format.fraction_bits = 52; format.bias = 1023;
            break;
        default:
            return 0;
    }
    if (descriptor->value_bits != format.width || descriptor->format.storage_bits != format.width ||
        descriptor->format.exponent_bits != format.exponent_bits ||
        descriptor->format.fraction_bits != format.fraction_bits || descriptor->reserved != 0 ||
        descriptor->format.reserved != 0) return 0;
    format.sign_mask = UINT64_C(1) << (format.width - 1);
    format.fraction_mask = (UINT64_C(1) << format.fraction_bits) - 1;
    format.exponent_mask = ((UINT64_C(1) << format.exponent_bits) - 1) << format.fraction_bits;
    format.value_mask = format.width == 64 ? UINT64_MAX : (UINT64_C(1) << format.width) - 1;
    format.quiet_nan_bit = UINT64_C(1) << (format.fraction_bits - 1);
    *format_out = format;
    return 1;
}

static int z_exact_class(const z_exact_format *format, uint64_t bits) {
    uint64_t exponent = bits & format->exponent_mask;
    uint64_t fraction = bits & format->fraction_mask;
    if (exponent == 0) {
        return fraction == 0 ? ZMATH_TESTING_ORACLE_CLASS_ZERO :
                              ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL;
    }
    if (exponent != format->exponent_mask) return ZMATH_TESTING_ORACLE_CLASS_NORMAL;
    if (fraction == 0) return ZMATH_TESTING_ORACLE_CLASS_INFINITY;
    return (fraction & format->quiet_nan_bit) != 0 ?
               ZMATH_TESTING_ORACLE_CLASS_QNAN :
               ZMATH_TESTING_ORACLE_CLASS_SNAN;
}

static int z_exact_nan(const z_exact_format *format, uint64_t bits) {
    return (bits & ~format->sign_mask) > format->exponent_mask;
}

static int z_exact_inf(const z_exact_format *format, uint64_t bits) {
    return (bits & ~format->sign_mask) == format->exponent_mask;
}

static int z_exact_zero(const z_exact_format *format, uint64_t bits) {
    return (bits & ~format->sign_mask) == 0;
}

static uint64_t z_exact_canonical_nan(const z_exact_format *format) {
    return format->exponent_mask | format->quiet_nan_bit;
}

static uint64_t z_exact_quiet(const z_exact_format *format, uint64_t bits) {
    return bits | format->quiet_nan_bit;
}
static uint64_t z_exact_order_key(const z_exact_format *format, uint64_t bits) {
    uint64_t key = bits & format->sign_mask ? ~bits : bits | format->sign_mask;
    return key & format->value_mask;
}


static int z_exact_parts_of(const z_exact_format *format, uint64_t bits, z_exact_parts *parts) {
    uint64_t exponent_field;
    uint64_t significand;
    uint64_t hidden = UINT64_C(1) << format->fraction_bits;
    int exponent;
    if (parts == NULL || z_exact_nan(format, bits) || z_exact_inf(format, bits) || z_exact_zero(format, bits)) return 0;
    exponent_field = (bits & format->exponent_mask) >> format->fraction_bits;
    significand = bits & format->fraction_mask;
    exponent = (int)exponent_field - format->bias - (int)format->fraction_bits;
    if (exponent_field == 0) {
        exponent += 1;
        while (significand < hidden) {
            significand <<= 1;
            --exponent;
        }
    } else {
        significand |= hidden;
    }
    parts->negative = (bits & format->sign_mask) != 0;
    parts->significand = significand;
    parts->exponent = exponent;
    return 1;
}

static uint64_t z_exact_round_integral(const z_exact_format *format, uint64_t bits, int mode) {
    uint64_t magnitude = bits & ~format->sign_mask;
    uint64_t exponent_field = (magnitude & format->exponent_mask) >> format->fraction_bits;
    uint64_t fraction = magnitude & format->fraction_mask;
    int exponent;
    int negative = (bits & format->sign_mask) != 0;
    int increment;
    if (exponent_field == (UINT64_C(1) << format->exponent_bits) - 1) return fraction == 0 ? bits : z_exact_quiet(format, bits);
    if (magnitude == 0) return bits;
    exponent = exponent_field == 0 ? 1 - format->bias : (int)exponent_field - format->bias;
    if (exponent < 0) {
        increment = mode == 0 ? exponent == -1 && fraction != 0 :
                    mode == 1 ? exponent == -1 : mode == 3 ? !negative : mode == 4 ? negative : 0;
        return (bits & format->sign_mask) | (increment ? (uint64_t)format->bias << format->fraction_bits : 0);
    }
    if ((unsigned)exponent >= format->fraction_bits) return bits;
    {
        unsigned shift = format->fraction_bits - (unsigned)exponent;
        uint64_t mask = (UINT64_C(1) << shift) - 1;
        uint64_t discarded = magnitude & mask;
        uint64_t truncated = magnitude & ~mask;
        uint64_t half = UINT64_C(1) << (shift - 1);
        if (discarded == 0) return bits;
        switch (mode) {
            case 0: increment = discarded > half || (discarded == half && ((truncated >> shift) & 1) != 0); break;
            case 1: increment = discarded >= half; break;
            case 2: increment = 0; break;
            case 3: increment = !negative; break;
            case 4: increment = negative; break;
            default: return bits;
        }
        return (bits & format->sign_mask) | truncated + (increment ? UINT64_C(1) << shift : 0);
    }
}

static int z_exact_below_power(const z_exact_format *format, uint64_t bits, int64_t power, int inclusive) {
    uint64_t magnitude = bits & ~format->sign_mask;
    int64_t exponent;
    if (magnitude == 0) return 1;
    exponent = (int64_t)((magnitude & format->exponent_mask) >> format->fraction_bits) - format->bias;
    if (exponent < power) return 1;
    if (exponent > power || !inclusive) return 0;
    return (magnitude & format->fraction_mask) == 0;
}

static int z_exact_within_width(const z_exact_format *format, uint64_t bits, uint32_t width, int is_unsigned) {
    int negative;
    if (width == 0) return 0;
    if ((bits & ~format->sign_mask) == 0) return 1;
    negative = (bits & format->sign_mask) != 0;
    if (is_unsigned) return !negative && z_exact_below_power(format, bits, width, 0);
    return z_exact_below_power(format, bits, (int64_t)width - 1, negative);
}

static int z_exact_pack_integer(const z_exact_format *format, uint64_t magnitude, int negative, uint64_t *bits_out) {
    unsigned top = 0;
    uint64_t probe = magnitude;
    uint64_t significand;
    if (bits_out == NULL) return 0;
    if (magnitude == 0) { *bits_out = negative ? format->sign_mask : 0; return 1; }
    while (probe >>= 1) ++top;
    if (top > format->fraction_bits) return 0;
    significand = magnitude << (format->fraction_bits - top);
    *bits_out = (negative ? format->sign_mask : 0) |
                ((uint64_t)(top + format->bias) << format->fraction_bits) |
                (significand & format->fraction_mask);
    return 1;
}

static z_exact_u128 z_exact_shr_jam(z_exact_u128 value, unsigned shift) {
    if (shift == 0) return value;
    if (shift >= 128) return value == 0 ? 0 : 1;
    return (value >> shift) | ((value & (((z_exact_u128)1 << shift) - 1)) != 0 ? 1 : 0);
}

static int z_exact_pack_exact(const z_exact_format *format, z_exact_u128 magnitude, int exponent,
                              int negative, uint64_t *bits_out) {
    unsigned top = 0;
    z_exact_u128 probe = magnitude;
    int top_exponent;
    int minimum_normal = 1 - format->bias;
    int minimum_subnormal = minimum_normal - (int)format->fraction_bits;
    uint64_t sign = negative ? format->sign_mask : 0;
    if (bits_out == NULL) return 0;
    if (magnitude == 0) { *bits_out = sign; return 1; }
    while (probe >>= 1) ++top;
    top_exponent = exponent + (int)top;
    if (top_exponent < minimum_normal) {
        int shift = minimum_subnormal - exponent;
        z_exact_u128 rounded = shift >= 128 ? 0 :
            shift > 0 ? magnitude >> (unsigned)shift : magnitude << (unsigned)(-shift);
        if (shift > 0 && shift < 128) {
            z_exact_u128 remainder = magnitude & (((z_exact_u128)1 << shift) - 1);
            z_exact_u128 half = (z_exact_u128)1 << (shift - 1);
            if (remainder > half || (remainder == half && (rounded & 1) != 0)) ++rounded;
        }
        if (rounded >= ((z_exact_u128)1 << format->fraction_bits)) *bits_out = sign | (UINT64_C(1) << format->fraction_bits);
        else *bits_out = sign | ((uint64_t)rounded & format->fraction_mask);
        return 1;
    }
    {
        int shift = (int)top - (int)format->fraction_bits;
        z_exact_u128 rounded = shift > 0 ? magnitude >> (unsigned)shift : magnitude << (unsigned)(-shift);
        if (shift > 0 && shift < 128) {
            z_exact_u128 remainder = magnitude & (((z_exact_u128)1 << shift) - 1);
            z_exact_u128 half = (z_exact_u128)1 << (shift - 1);
            if (remainder > half || (remainder == half && (rounded & 1) != 0)) ++rounded;
        }
        if (rounded >= ((z_exact_u128)1 << (format->fraction_bits + 1))) { rounded >>= 1; ++top_exponent; }
        if (top_exponent > format->bias) *bits_out = sign | format->exponent_mask;
        else *bits_out = sign | ((uint64_t)(top_exponent + format->bias) << format->fraction_bits) |
                              ((uint64_t)rounded & format->fraction_mask);
    }
    return 1;
}

static int z_exact_compare(const z_exact_format *left_format, uint64_t left_bits,
                           const z_exact_format *right_format, uint64_t right_bits) {
    z_exact_parts left;
    z_exact_parts right;
    int comparison;
    int left_negative = (left_bits & left_format->sign_mask) != 0;
    int right_negative = (right_bits & right_format->sign_mask) != 0;
    int left_zero = z_exact_zero(left_format, left_bits);
    int right_zero = z_exact_zero(right_format, right_bits);
    if (left_zero && right_zero) return 0;
    if (left_zero) return right_negative ? 1 : -1;
    if (right_zero) return left_negative ? -1 : 1;
    if (left_negative != right_negative) return left_negative ? -1 : 1;
    if (z_exact_inf(left_format, left_bits) || z_exact_inf(right_format, right_bits)) {
        if (z_exact_inf(left_format, left_bits) && z_exact_inf(right_format, right_bits)) return 0;
        comparison = z_exact_inf(left_format, left_bits) ? 1 : -1;
        return left_negative ? -comparison : comparison;
    }
    if (!z_exact_parts_of(left_format, left_bits, &left) ||
        !z_exact_parts_of(right_format, right_bits, &right)) return 0;
    comparison = left.exponent + (int)left_format->fraction_bits <
                         right.exponent + (int)right_format->fraction_bits ? -1 :
                 left.exponent + (int)left_format->fraction_bits >
                         right.exponent + (int)right_format->fraction_bits ? 1 : 0;
    if (comparison == 0) {
        unsigned common = left_format->fraction_bits > right_format->fraction_bits ?
                              left_format->fraction_bits : right_format->fraction_bits;
        z_exact_u128 left_significand =
            (z_exact_u128)left.significand << (common - left_format->fraction_bits);
        z_exact_u128 right_significand =
            (z_exact_u128)right.significand << (common - right_format->fraction_bits);
        comparison = left_significand < right_significand ? -1 :
                     left_significand > right_significand ? 1 : 0;
    }
    return left_negative ? -comparison : comparison;
}

static int z_exact_add_sub(const z_exact_format *format, uint64_t left_bits, uint64_t right_bits,
                           int subtract_right, uint64_t *result_bits) {
    z_exact_parts left;
    z_exact_parts right;
    z_exact_parts larger;
    z_exact_parts smaller;
    z_exact_u128 larger_ext;
    z_exact_u128 smaller_ext;
    z_exact_u128 magnitude;
    unsigned difference;
    int negative;
    int left_top;
    int right_top;
    if (!z_exact_parts_of(format, left_bits, &left) || !z_exact_parts_of(format, right_bits, &right)) return 0;
    right.negative ^= subtract_right != 0;
    left_top = left.exponent + (int)format->fraction_bits;
    right_top = right.exponent + (int)format->fraction_bits;
    if (left_top > right_top || (left_top == right_top && left.significand >= right.significand)) {
        larger = left; smaller = right;
    } else { larger = right; smaller = left; }
    difference = (unsigned)((larger.exponent + (int)format->fraction_bits) -
                            (smaller.exponent + (int)format->fraction_bits));
    larger_ext = (z_exact_u128)larger.significand << Z_EXACT_GUARD_BITS;
    smaller_ext = z_exact_shr_jam((z_exact_u128)smaller.significand << Z_EXACT_GUARD_BITS, difference);
    negative = larger.negative;
    if (larger.negative == smaller.negative) magnitude = larger_ext + smaller_ext;
    else if (larger_ext >= smaller_ext) magnitude = larger_ext - smaller_ext;
    else { magnitude = smaller_ext - larger_ext; negative = smaller.negative; }
    return z_exact_pack_exact(format, magnitude, larger.exponent - (int)Z_EXACT_GUARD_BITS, negative, result_bits);
}

static int z_exact_float_input(const zmath_testing_oracle_request *request, unsigned index,
                               z_exact_format *format, uint64_t *bits) {
    if (request == NULL || format == NULL || bits == NULL || request->input_fields == NULL ||
        index >= request->input_field_count || !z_exact_get_format(&request->input_fields[index].descriptor, format)) return 0;
    *bits = request->input_fields[index].value_bits;
    return 1;
}

static int z_exact_result_format(const zmath_testing_oracle_request *request, unsigned index,
                                 z_exact_format *format) {
    if (request == NULL || format == NULL || request->result_fields == NULL || index >= request->result_field_count) return 0;
    return z_exact_get_format(&request->result_fields[index], format);
}

static int z_exact_signed_input(const zmath_testing_oracle_request *request, unsigned index, int64_t *value) {
    const zmath_testing_oracle_input_field *field;
    if (request == NULL || value == NULL || request->input_fields == NULL || index >= request->input_field_count) return 0;
    field = &request->input_fields[index];
    return field->descriptor.kind == ZMATH_TESTING_ORACLE_FIELD_SIGNED_INTEGER &&
           z_exact_decode_signed(field->value_bits, field->descriptor.value_bits, value);
}

static int z_exact_unsigned_input(const zmath_testing_oracle_request *request, unsigned index, uint32_t *value) {
    const zmath_testing_oracle_input_field *field;
    uint64_t mask;
    if (request == NULL || value == NULL || request->input_fields == NULL || index >= request->input_field_count) return 0;
    field = &request->input_fields[index];
    if (field->descriptor.kind != ZMATH_TESTING_ORACLE_FIELD_UNSIGNED_INTEGER || field->descriptor.value_bits > 32 ||
        !z_exact_mask(field->descriptor.value_bits, &mask) || (field->value_bits & ~mask) != 0) return 0;
    *value = (uint32_t)field->value_bits;
    return 1;
}

static int z_exact_rounding_input(const zmath_testing_oracle_request *request, unsigned index, int *mode) {
    const zmath_testing_oracle_input_field *field;
    if (request == NULL || mode == NULL || request->input_fields == NULL || index >= request->input_field_count) return 0;
    field = &request->input_fields[index];
    if (field->descriptor.kind != ZMATH_TESTING_ORACLE_FIELD_ROUNDING || field->value_bits > 4) return 0;
    *mode = (int)field->value_bits;
    return 1;
}


static void z_exact_float_result(zmath_testing_oracle_result_field *field, const z_exact_format *format, uint64_t bits) {
    field->value_bits = bits & format->value_mask;
    field->class_code = (uint32_t)z_exact_class(format, field->value_bits);
    field->reserved = 0;
}

static void z_exact_integer_result(zmath_testing_oracle_result_field *field, int64_t value) {
    field->value_bits = z_exact_encode_signed(value, field->descriptor.value_bits);
    field->class_code = ZMATH_TESTING_ORACLE_CLASS_NONE; field->reserved = 0;
}

static void z_exact_boolean_result(zmath_testing_oracle_result_field *field, int value) {
    field->value_bits = value != 0; field->class_code = ZMATH_TESTING_ORACLE_CLASS_NONE; field->reserved = 0;
}

static void z_exact_fail(zmath_testing_oracle_result *result, uint32_t status) {
    if (result != NULL) { result->status = status; result->field_count = 0; }
}

static int z_exact_begin(const zmath_testing_oracle_operation_signature *signature,
                         const zmath_testing_oracle_request *request,
                         zmath_testing_oracle_result *result, z_exact_build *build) {
    uint32_t index;
    if (result == NULL || signature == NULL || request == NULL || build == NULL) return 0;
    result->status = ZMATH_TESTING_ORACLE_ERROR; result->field_count = 0;
    if (result->reserved != 0 || request->reserved != 0 || request->abi_version != ZMATH_TESTING_ORACLE_ABI_VERSION ||
        !z_exact_signature_is_table_row(signature) || signature->evaluator_category != ZMATH_TESTING_ORACLE_EVALUATOR_EXACT_BITS ||
        signature->operation == NULL || request->operation == NULL || request->operation_length != signature->operation_length ||
        memcmp(request->operation, signature->operation, signature->operation_length) != 0 || request->arity != signature->arity ||
        request->input_field_count != signature->arity || request->input_fields == NULL || request->result_layout != signature->result_layout ||
        request->structure_kind != signature->structure_kind || request->result_field_count != signature->result_field_count ||
        request->result_fields == NULL || signature->arguments == NULL || signature->result_fields == NULL ||
        signature->result_field_count > Z_EXACT_MAX_FIELDS || result->field_capacity < signature->result_field_count || result->fields == NULL) return 0;
    for (index = 0; index < signature->arity; ++index) {
        const zmath_testing_oracle_input_field *field = &request->input_fields[index];
        const zmath_testing_oracle_field_descriptor *descriptor = &signature->arguments[index];
        uint64_t mask;
        z_exact_format ignored;
        if (!z_exact_descriptor_equal(descriptor, &field->descriptor) || field->reserved != 0) return 0;
        if (field->descriptor.kind == ZMATH_TESTING_ORACLE_FIELD_FLOAT) {
            if (!z_exact_get_format(descriptor, &ignored) || (field->value_bits & ~ignored.value_mask) != 0) return 0;
        } else if (field->descriptor.kind == ZMATH_TESTING_ORACLE_FIELD_BOOLEAN) {
            if (field->value_bits > 1) return 0;
        } else if (field->descriptor.kind == ZMATH_TESTING_ORACLE_FIELD_SIGNED_INTEGER || field->descriptor.kind == ZMATH_TESTING_ORACLE_FIELD_UNSIGNED_INTEGER) {
            if (!z_exact_mask(field->descriptor.value_bits, &mask) || (field->value_bits & ~mask) != 0) return 0;
        } else if (field->descriptor.kind == ZMATH_TESTING_ORACLE_FIELD_ROUNDING) {
            if (field->value_bits > 4) return 0;
        } else if (field->descriptor.kind == ZMATH_TESTING_ORACLE_FIELD_TAG) {
            if (field->value_bits != 0 ||
                (field->tag_bytes == NULL) != (field->tag_length == 0)) return 0;
        } else return 0;
        if (field->descriptor.kind != ZMATH_TESTING_ORACLE_FIELD_TAG && (field->tag_bytes != NULL || field->tag_length != 0)) return 0;
    }
    build->field_count = signature->result_field_count;
    for (index = 0; index < build->field_count; ++index) {
        if (!z_exact_descriptor_equal(&signature->result_fields[index], &request->result_fields[index])) return 0;
        build->fields[index].descriptor = signature->result_fields[index];
        build->fields[index].value_bits = 0; build->fields[index].class_code = ZMATH_TESTING_ORACLE_CLASS_NONE; build->fields[index].reserved = 0;
    }
    return 1;
}

static void z_exact_finish(zmath_testing_oracle_result *result, const z_exact_build *build) {
    uint32_t index;
    for (index = 0; index < build->field_count; ++index) result->fields[index] = build->fields[index];
    result->field_count = build->field_count; result->status = ZMATH_TESTING_ORACLE_OK;
}

static int z_exact_parse_tag(const uint8_t *bytes, uint32_t length, uint64_t mask, uint64_t *payload) {
    uint64_t value = 0;
    uint32_t index;
    if (bytes == NULL || length == 0 || payload == NULL) return 0;
    for (index = 0; index < length; ++index) {
        uint8_t character = bytes[index];
        uint64_t digit;
        if (character >= '0' && character <= '9') digit = character - '0';
        else if (character >= 'A' && character <= 'F') digit = character - 'A' + 10;
        else if (character >= 'a' && character <= 'f') digit = character - 'a' + 10;
        else return 0;
        if (value > (mask >> 4)) return 0;
        value = (value << 4) | digit;
        if (value > mask) return 0;
    }
    *payload = value; return 1;
}

static int z_exact_payload_integer(const z_exact_format *format, uint64_t bits, uint64_t *payload) {
    uint64_t magnitude = bits & ~format->sign_mask;
    uint64_t exponent_field;
    uint64_t significand;
    unsigned payload_bits = format->fraction_bits - 1;
    unsigned exponent_max = (1u << format->exponent_bits) - 1u;
    unsigned bias = exponent_max >> 1;
    int exponent;
    unsigned shift;
    if (payload == NULL) return 0;
    if (magnitude == 0) { *payload = 0; return 1; }
    if ((bits & format->sign_mask) != 0) return 0;
    exponent_field = (magnitude & format->exponent_mask) >> format->fraction_bits;
    if (exponent_field == 0 || exponent_field == exponent_max || exponent_field < bias) return 0;
    exponent = (int)exponent_field - (int)bias;
    if (exponent >= (int)payload_bits) return 0;
    shift = format->fraction_bits - (unsigned)exponent;
    significand = (UINT64_C(1) << format->fraction_bits) | (bits & format->fraction_mask);
    if ((significand & ((UINT64_C(1) << shift) - 1)) != 0) return 0;
    *payload = significand >> shift;
    return *payload <= format->quiet_nan_bit - 1;
}

static int z_exact_integer_round(const z_exact_format *format, uint64_t bits, int ties_away, int64_t *value) {
    z_exact_parts parts;
    uint64_t integer = 0;
    uint64_t remainder = 0;
    uint64_t half = 0;
    unsigned shift;
    int increment = 0;
    uint64_t limit;
    if (value == NULL) return 0;
    if (z_exact_zero(format, bits)) {
        *value = 0;
        return 1;
    }
    if (!z_exact_parts_of(format, bits, &parts)) return 0;
    if (parts.exponent < 0) {
        shift = (unsigned)(-parts.exponent);
        if (shift >= 64) {
            remainder = parts.significand;
            half = UINT64_MAX;
        } else {
            integer = parts.significand >> shift;
            remainder = parts.significand & ((UINT64_C(1) << shift) - 1);
            half = UINT64_C(1) << (shift - 1);
        }
    } else {
        unsigned left_shift = (unsigned)parts.exponent;
        if (left_shift >= 64 ||
            (left_shift != 0 &&
             parts.significand > (UINT64_MAX >> left_shift)))
        {
            return 0;
        }
        integer = parts.significand << left_shift;
    }
    if (remainder != 0) {
        increment = ties_away ?
                        remainder >= half :
                        remainder > half ||
                            (remainder == half && (integer & 1) != 0);
    }
    if (increment) {
        if (integer == UINT64_MAX) return 0;
        ++integer;
    }
    limit = parts.negative ? (UINT64_C(1) << 63) :
                            ((UINT64_C(1) << 63) - 1);
    if (integer > limit) return 0;
    if (parts.negative) {
        *value = integer == (UINT64_C(1) << 63) ?
                     INT64_MIN :
                     -(int64_t)integer;
    } else {
        *value = (int64_t)integer;
    }
    return 1;
}

static int z_exact_eval_rounding(const zmath_testing_oracle_operation_signature *signature,
                                 const zmath_testing_oracle_request *request, z_exact_build *build) {
    z_exact_format format;
    uint64_t bits;
    int mode;
    if (!z_exact_float_input(request, 0, &format, &bits) || !z_exact_result_format(request, 0, &format)) return 0;
    if (z_exact_is_operation(signature, "ceil")) mode = 3;
    else if (z_exact_is_operation(signature, "floor")) mode = 4;
    else if (z_exact_is_operation(signature, "trunc")) mode = 2;
    else if (z_exact_is_operation(signature, "round")) mode = 1;
    else mode = 0;
    z_exact_float_result(&build->fields[0], &format, z_exact_round_integral(&format, bits, mode));
    return 1;
}

static int z_exact_eval_abs(const zmath_testing_oracle_request *request, z_exact_build *build) {
    z_exact_format format;
    uint64_t bits;
    if (!z_exact_float_input(request, 0, &format, &bits) || !z_exact_result_format(request, 0, &format)) return 0;
    z_exact_float_result(&build->fields[0], &format, bits & ~format.sign_mask); return 1;
}

static int z_exact_eval_integer_container(const zmath_testing_oracle_operation_signature *signature,
                                          const zmath_testing_oracle_request *request, z_exact_build *build) {
    z_exact_format format;
    uint64_t bits;
    int64_t value;
    int ties_away = z_exact_is_operation(signature, "lround") || z_exact_is_operation(signature, "llround");
    if (!z_exact_float_input(request, 0, &format, &bits)) return 0;
    if (!z_exact_integer_round(&format, bits, ties_away, &value)) { z_exact_integer_result(&build->fields[0], 0); z_exact_boolean_result(&build->fields[1], 0); }
    else { z_exact_integer_result(&build->fields[0], value); z_exact_boolean_result(&build->fields[1], 1); }
    return 1;
}

static int z_exact_eval_fromfp(const zmath_testing_oracle_operation_signature *signature,
                               const zmath_testing_oracle_request *request, z_exact_build *build) {
    z_exact_format format;
    uint64_t bits;
    uint32_t width;
    int mode;
    int is_unsigned = z_exact_is_operation(signature, "ufromfp") || z_exact_is_operation(signature, "ufromfpx");
    uint64_t result_bits;
    if (!z_exact_float_input(request, 0, &format, &bits) || !z_exact_rounding_input(request, 1, &mode) || !z_exact_unsigned_input(request, 2, &width)) return 0;
    if (width == 0 || z_exact_nan(&format, bits) || z_exact_inf(&format, bits)) result_bits = z_exact_canonical_nan(&format);
    else { result_bits = z_exact_round_integral(&format, bits, mode); if (!z_exact_within_width(&format, result_bits, width, is_unsigned)) result_bits = z_exact_canonical_nan(&format); }
    z_exact_float_result(&build->fields[0], &format, result_bits); return 1;
}

static int z_exact_eval_extrema(const zmath_testing_oracle_operation_signature *signature,
                                const zmath_testing_oracle_request *request, z_exact_build *build) {
    z_exact_format format;
    uint64_t left;
    uint64_t right;
    int left_nan;
    int right_nan;
    int minimum = z_exact_is_operation(signature, "fmin") || z_exact_is_operation(signature, "fminimum") ||
                  z_exact_is_operation(signature, "fminimum_mag") || z_exact_is_operation(signature, "fminimum_num") ||
                  z_exact_is_operation(signature, "fminimum_mag_num");
    int magnitude = z_exact_is_operation(signature, "fmaximum_mag") || z_exact_is_operation(signature, "fminimum_mag") ||
                    z_exact_is_operation(signature, "fmaximum_mag_num") || z_exact_is_operation(signature, "fminimum_mag_num");
    int number = z_exact_is_operation(signature, "fmax") || z_exact_is_operation(signature, "fmin") ||
                 z_exact_is_operation(signature, "fmaximum_num") || z_exact_is_operation(signature, "fminimum_num") ||
                 z_exact_is_operation(signature, "fmaximum_mag_num") || z_exact_is_operation(signature, "fminimum_mag_num");
    int choose_left;
    if (!z_exact_float_input(request, 0, &format, &left) || !z_exact_float_input(request, 1, &format, &right)) return 0;
    left_nan = z_exact_nan(&format, left); right_nan = z_exact_nan(&format, right);
    if (left_nan || right_nan) {
        if (left_nan && right_nan) left = z_exact_quiet(&format, left);
        else if (number) left = left_nan ? right : left;
        else left = left_nan ? z_exact_quiet(&format, left) : z_exact_quiet(&format, right);
        z_exact_float_result(&build->fields[0], &format, left); return 1;
    }
    if (magnitude) {
        uint64_t left_magnitude = left & ~format.sign_mask;
        uint64_t right_magnitude = right & ~format.sign_mask;
        if (left_magnitude != right_magnitude) choose_left = minimum ? left_magnitude < right_magnitude : left_magnitude > right_magnitude;
        else choose_left = minimum ? z_exact_order_key(&format, left) <= z_exact_order_key(&format, right) : z_exact_order_key(&format, left) >= z_exact_order_key(&format, right);
    } else choose_left = minimum ? z_exact_order_key(&format, left) <= z_exact_order_key(&format, right) : z_exact_order_key(&format, left) >= z_exact_order_key(&format, right);
    z_exact_float_result(&build->fields[0], &format, choose_left ? left : right); return 1;
}

static int z_exact_eval_fdim(const zmath_testing_oracle_request *request, z_exact_build *build) {
    z_exact_format format;
    uint64_t left;
    uint64_t right;
    uint64_t result_bits;
    int comparison;
    if (!z_exact_float_input(request, 0, &format, &left) || !z_exact_float_input(request, 1, &format, &right)) return 0;
    if (z_exact_nan(&format, left)) result_bits = z_exact_quiet(&format, left);
    else if (z_exact_nan(&format, right)) result_bits = z_exact_quiet(&format, right);
    else {
        comparison = z_exact_compare(&format, left, &format, right);
        if (comparison <= 0) result_bits = 0;
        else if (z_exact_zero(&format, right)) result_bits = left;
        else if (z_exact_zero(&format, left)) result_bits = right & ~format.sign_mask;
        else if (z_exact_inf(&format, left) || z_exact_inf(&format, right)) result_bits = format.exponent_mask;
        else if (!z_exact_add_sub(&format, left, right, 1, &result_bits)) return 0;
    }
    z_exact_float_result(&build->fields[0], &format, result_bits); return 1;
}

static int z_exact_eval_remainder(const zmath_testing_oracle_operation_signature *signature,
                                  const zmath_testing_oracle_request *request, z_exact_build *build) {
    z_exact_format format;
    uint64_t x_bits;
    uint64_t y_bits;
    z_exact_parts x;
    z_exact_parts y;
    z_exact_u128 numerator;
    z_exact_u128 denominator;
    z_exact_u128 remainder;
    uint8_t quotient_low = 0;
    int exponent_delta;
    int remainder_exponent;
    int negative;
    int quotient_negative;
    uint64_t value_bits;
    int32_t quotient;
    int nearest = z_exact_is_operation(signature, "remainder") || z_exact_is_operation(signature, "remquo");
    if (!z_exact_float_input(request, 0, &format, &x_bits) || !z_exact_float_input(request, 1, &format, &y_bits)) return 0;
    if (z_exact_nan(&format, x_bits) || z_exact_nan(&format, y_bits)) {
        uint64_t selected = z_exact_nan(&format, x_bits) ? x_bits : y_bits;
        z_exact_float_result(&build->fields[0], &format, z_exact_quiet(&format, selected));
        if (build->field_count > 1) z_exact_integer_result(&build->fields[1], 0);
        return 1;
    }
    if (z_exact_inf(&format, x_bits) || z_exact_zero(&format, y_bits)) {
        z_exact_float_result(&build->fields[0], &format, z_exact_canonical_nan(&format));
        if (build->field_count > 1) z_exact_integer_result(&build->fields[1], 0);
        return 1;
    }
    if (z_exact_inf(&format, y_bits) || z_exact_zero(&format, x_bits)) {
        z_exact_float_result(&build->fields[0], &format, x_bits);
        if (build->field_count > 1) z_exact_integer_result(&build->fields[1], 0);
        return 1;
    }
    if (!z_exact_parts_of(&format, x_bits, &x) || !z_exact_parts_of(&format, y_bits, &y)) return 0;
    exponent_delta = x.exponent - y.exponent;
    quotient_negative = x.negative != y.negative;
    negative = x.negative;
    if (exponent_delta < 0 && -exponent_delta > (int)format.fraction_bits + 1) {
        z_exact_float_result(&build->fields[0], &format, x_bits);
        if (build->field_count > 1) z_exact_integer_result(&build->fields[1], 0);
        return 1;
    }
    if (exponent_delta >= 0) {
        unsigned shift = (unsigned)exponent_delta;
        uint64_t numerator_bits = x.significand;
        int bit_count = 0;
        while (numerator_bits != 0) { ++bit_count; numerator_bits >>= 1; }
        int bit_index = bit_count + (int)shift - 1;
        numerator = x.significand;
        denominator = y.significand;
        remainder = 0;
        while (bit_index >= 0) {
            z_exact_u128 bit = bit_index >= (int)shift ? ((z_exact_u128)(numerator >> (unsigned)(bit_index - (int)shift)) & 1) : 0;
            remainder = (remainder << 1) | bit;
            if (remainder >= denominator) { remainder -= denominator; quotient_low = (uint8_t)(((quotient_low << 1) | 1) & 7); }
            else quotient_low = (uint8_t)((quotient_low << 1) & 7);
            --bit_index;
        }
        remainder_exponent = y.exponent;
    } else {
        unsigned shift = (unsigned)(-exponent_delta);
        numerator = x.significand;
        denominator = (z_exact_u128)y.significand << shift;
        remainder = numerator;
        if (remainder >= denominator) { remainder -= denominator; quotient_low = 1; }
        remainder_exponent = x.exponent;
    }
    if (nearest) {
        z_exact_u128 twice = remainder << 1;
        if (twice > denominator || (twice == denominator && (quotient_low & 1) != 0)) { remainder = denominator - remainder; quotient_low = (uint8_t)((quotient_low + 1) & 7); negative = !negative; }
    }
    if (!z_exact_pack_exact(&format, remainder, remainder_exponent, negative, &value_bits)) return 0;
    z_exact_float_result(&build->fields[0], &format, value_bits);
    if (build->field_count > 1) { quotient = (int32_t)quotient_low; if (quotient_negative) quotient = -quotient; z_exact_integer_result(&build->fields[1], quotient); }
    return 1;
}

static int z_exact_eval_decompose(const zmath_testing_oracle_operation_signature *signature,
                                  const zmath_testing_oracle_request *request, z_exact_build *build) {
    z_exact_format format;
    uint64_t bits;
    int class_code;
    if (!z_exact_float_input(request, 0, &format, &bits)) return 0;
    class_code = z_exact_class(&format, bits);
    if (z_exact_is_operation(signature, "frexp")) {
        uint64_t fraction_bits = bits;
        int64_t exponent = 0;
        if (class_code == ZMATH_TESTING_ORACLE_CLASS_NORMAL) {
            int exponent_field = (int)((bits & format.exponent_mask) >> format.fraction_bits);
            fraction_bits = (bits & format.sign_mask) | ((uint64_t)(format.bias - 1) << format.fraction_bits) | (bits & format.fraction_mask);
            exponent = exponent_field - format.bias + 1;
        } else if (class_code == ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL) {
            uint64_t fraction = bits & format.fraction_mask;
            uint64_t hidden = UINT64_C(1) << format.fraction_bits;
            int shift_count = 0;
            while (fraction < hidden) { fraction <<= 1; ++shift_count; }
            fraction_bits = (bits & format.sign_mask) | ((uint64_t)(format.bias - 1) << format.fraction_bits) | (fraction & format.fraction_mask);
            exponent = 1 - format.bias - (int)format.fraction_bits +
                       ((int)format.fraction_bits - shift_count) + 1;
        } else if (z_exact_nan(&format, bits)) {
            fraction_bits = z_exact_quiet(&format, bits);
        }
        z_exact_float_result(&build->fields[0], &format, fraction_bits); z_exact_integer_result(&build->fields[1], exponent); return 1;
    }
    if (z_exact_is_operation(signature, "modf")) {
        uint64_t fractional = bits;
        uint64_t integral = bits;
        if (class_code == ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL) integral = bits & format.sign_mask;
        else if (class_code == ZMATH_TESTING_ORACLE_CLASS_NORMAL) {
            int exponent = (int)((bits & format.exponent_mask) >> format.fraction_bits) - format.bias;
            if (exponent < 0) integral = bits & format.sign_mask;
            else if ((unsigned)exponent < format.fraction_bits) {
                unsigned shift = format.fraction_bits - (unsigned)exponent;
                uint64_t significand = (UINT64_C(1) << format.fraction_bits) | (bits & format.fraction_mask);
                uint64_t remainder = significand & ((UINT64_C(1) << shift) - 1);
                integral = bits & ~((UINT64_C(1) << shift) - 1);
                if (!z_exact_pack_exact(&format, remainder, exponent - (int)format.fraction_bits, (bits & format.sign_mask) != 0, &fractional)) return 0;
            } else fractional = bits & format.sign_mask;
        } else if (class_code == ZMATH_TESTING_ORACLE_CLASS_INFINITY) fractional = bits & format.sign_mask;
        else if (z_exact_nan(&format, bits)) { fractional = z_exact_quiet(&format, bits); integral = fractional; }
        z_exact_float_result(&build->fields[0], &format, fractional); z_exact_float_result(&build->fields[1], &format, integral); return 1;
    }
    return 0;
}

static int z_exact_logb_exponent(const z_exact_format *format, uint64_t bits, int64_t *exponent) {
    int class_code = z_exact_class(format, bits);
    uint64_t fraction;
    unsigned top = 0;
    if (exponent == NULL) return 0;
    if (class_code == ZMATH_TESTING_ORACLE_CLASS_NORMAL) { *exponent = (int64_t)((bits & format->exponent_mask) >> format->fraction_bits) - format->bias; return 1; }
    if (class_code != ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL) return 0;
    fraction = bits & format->fraction_mask; while (fraction >>= 1) ++top;
    *exponent = 1 - format->bias - (int)format->fraction_bits + (int)top; return 1;
}

static int z_exact_eval_logb(const zmath_testing_oracle_request *request, z_exact_build *build) {
    z_exact_format format;
    uint64_t bits;
    int class_code;
    int64_t exponent;
    uint64_t result_bits;
    if (!z_exact_float_input(request, 0, &format, &bits)) return 0;
    class_code = z_exact_class(&format, bits);
    if (class_code == ZMATH_TESTING_ORACLE_CLASS_ZERO) result_bits = format.sign_mask | format.exponent_mask;
    else if (class_code == ZMATH_TESTING_ORACLE_CLASS_INFINITY) result_bits = format.exponent_mask;
    else if (z_exact_nan(&format, bits)) result_bits = z_exact_quiet(&format, bits);
    else { if (!z_exact_logb_exponent(&format, bits, &exponent) || !z_exact_pack_integer(&format, exponent < 0 ? (uint64_t)-exponent : (uint64_t)exponent, exponent < 0, &result_bits)) return 0; }
    z_exact_float_result(&build->fields[0], &format, result_bits); return 1;
}

static int z_exact_eval_integer_logb(const zmath_testing_oracle_request *request, z_exact_build *build, int width) {
    z_exact_format format;
    uint64_t bits;
    int64_t exponent;
    int class_code;
    if (!z_exact_float_input(request, 0, &format, &bits)) return 0;
    class_code = z_exact_class(&format, bits);
    if (class_code == ZMATH_TESTING_ORACLE_CLASS_ZERO) exponent = width == 32 ? INT32_MIN : INT64_MIN;
    else if (class_code == ZMATH_TESTING_ORACLE_CLASS_INFINITY || z_exact_nan(&format, bits)) exponent = width == 32 ? INT32_MAX : INT64_MAX;
    else if (!z_exact_logb_exponent(&format, bits, &exponent)) return 0;
    z_exact_integer_result(&build->fields[0], exponent); return 1;
}

static int64_t z_exact_sat_add(int64_t left, int64_t right) {
    if (right > 0 && left > INT64_MAX - right) return INT64_MAX;
    if (right < 0 && left < INT64_MIN - right) return INT64_MIN;
    return left + right;
}

static int z_exact_eval_scale(const zmath_testing_oracle_request *request, z_exact_build *build) {
    z_exact_format format;
    uint64_t bits;
    int64_t exponent;
    uint64_t magnitude;
    uint64_t significand;
    uint64_t hidden;
    int64_t scale;
    int64_t result_scale;
    int64_t minimum_normal;
    int64_t minimum_subnormal;
    int64_t minimum_normal_scale;
    int64_t maximum_normal_scale;
    int64_t shift;
    uint64_t rounded;
    int class_code;
    if (!z_exact_float_input(request, 0, &format, &bits) || !z_exact_signed_input(request, 1, &exponent)) return 0;
    class_code = z_exact_class(&format, bits);
    if (class_code == ZMATH_TESTING_ORACLE_CLASS_ZERO || class_code == ZMATH_TESTING_ORACLE_CLASS_INFINITY) { z_exact_float_result(&build->fields[0], &format, bits); return 1; }
    if (z_exact_nan(&format, bits)) { z_exact_float_result(&build->fields[0], &format, z_exact_quiet(&format, bits)); return 1; }
    magnitude = bits & ~format.sign_mask; hidden = UINT64_C(1) << format.fraction_bits; significand = magnitude & format.fraction_mask;
    minimum_normal = 1 - format.bias; minimum_subnormal = minimum_normal - format.fraction_bits; minimum_normal_scale = minimum_subnormal; maximum_normal_scale = format.bias - format.fraction_bits;
    scale = minimum_subnormal;
    if ((magnitude & format.exponent_mask) != 0) { significand |= hidden; scale = (int64_t)((magnitude & format.exponent_mask) >> format.fraction_bits) - format.bias - format.fraction_bits; }
    else while (significand < hidden) { significand <<= 1; --scale; }
    result_scale = z_exact_sat_add(scale, exponent);
    if (result_scale > maximum_normal_scale) { z_exact_float_result(&build->fields[0], &format, (bits & format.sign_mask) | format.exponent_mask); return 1; }
    if (result_scale >= minimum_normal_scale) { uint64_t exponent_field = (uint64_t)(result_scale + format.fraction_bits + format.bias); z_exact_float_result(&build->fields[0], &format, (bits & format.sign_mask) | (exponent_field << format.fraction_bits) | (significand & format.fraction_mask)); return 1; }
    shift = minimum_subnormal - result_scale; rounded = 0;
    if (shift < (int64_t)format.fraction_bits + 1) {
        rounded = shift > 0 ? significand >> (unsigned)shift : significand << (unsigned)(-shift);
        if (shift > 0) { uint64_t rem = significand & ((UINT64_C(1) << (unsigned)shift) - 1); uint64_t half = UINT64_C(1) << ((unsigned)shift - 1); if (rem > half || (rem == half && (rounded & 1) != 0)) ++rounded; }
    } else if (shift == (int64_t)format.fraction_bits + 1 && significand > hidden) rounded = 1;
    z_exact_float_result(&build->fields[0], &format, (bits & format.sign_mask) | (rounded >= hidden ? hidden : rounded)); return 1;
}

static int z_exact_parse_and_payload(const zmath_testing_oracle_request *request, const z_exact_format *format, uint64_t *payload) {
    const zmath_testing_oracle_input_field *field;
    if (request == NULL || format == NULL || payload == NULL || request->input_fields == NULL || request->input_field_count == 0) return 0;
    field = &request->input_fields[0];
    return z_exact_parse_tag(field->tag_bytes, field->tag_length, format->quiet_nan_bit - 1, payload);
}

static int z_exact_eval_ieee(const zmath_testing_oracle_operation_signature *signature,
                             const zmath_testing_oracle_request *request, z_exact_build *build) {
    z_exact_format format;
    z_exact_format toward_format;
    uint64_t first;
    uint64_t second;
    uint64_t payload;
    int comparison;
    if (z_exact_is_operation(signature, "canonicalize")) {
        if (!z_exact_float_input(request, 0, &format, &first)) return 0;
        if (z_exact_nan(&format, first)) first = z_exact_quiet(&format, first);
        z_exact_float_result(&build->fields[0], &format, first); z_exact_boolean_result(&build->fields[1], 1); return 1;
    }
    if (z_exact_is_operation(signature, "copySign")) {
        if (!z_exact_float_input(request, 0, &format, &first) || !z_exact_float_input(request, 1, &format, &second)) return 0;
        z_exact_float_result(&build->fields[0], &format, (first & ~format.sign_mask) | (second & format.sign_mask)); return 1;
    }
    if (z_exact_is_operation(signature, "nan")) {
        if (!z_exact_result_format(request, 0, &format)) return 0;
        if (!z_exact_parse_and_payload(request, &format, &payload)) payload = 0;
        z_exact_float_result(&build->fields[0], &format, format.exponent_mask | format.quiet_nan_bit | payload); return 1;
    }
    if (z_exact_is_operation(signature, "nextToward")) {
        if (!z_exact_float_input(request, 0, &format, &first) || !z_exact_float_input(request, 1, &toward_format, &second)) return 0;
        if (z_exact_nan(&format, first)) { z_exact_float_result(&build->fields[0], &format, z_exact_quiet(&format, first)); return 1; }
        if (z_exact_nan(&toward_format, second)) {
            unsigned shift = toward_format.fraction_bits > format.fraction_bits ? toward_format.fraction_bits - format.fraction_bits : 0;
            payload = (second & (toward_format.quiet_nan_bit - 1)) >> shift;
            if (payload > format.quiet_nan_bit - 1) payload = format.quiet_nan_bit - 1;
            z_exact_float_result(&build->fields[0], &format, (second & toward_format.sign_mask ? format.sign_mask : 0) | format.exponent_mask | format.quiet_nan_bit | payload); return 1;
        }
        comparison = z_exact_compare(&format, first, &toward_format, second);
        if (comparison == 0) { if (z_exact_zero(&format, first) && z_exact_zero(&toward_format, second)) first = second & toward_format.sign_mask ? format.sign_mask : 0; }
        else if (comparison < 0) { if (z_exact_zero(&format, first)) first = (second & toward_format.sign_mask ? format.sign_mask : 0) | 1; else first = (first & format.sign_mask) ? first - 1 : first + 1; }
        else { if (z_exact_zero(&format, first)) first = (second & toward_format.sign_mask ? format.sign_mask : 0) | 1; else first = (first & format.sign_mask) ? first + 1 : first - 1; }
        z_exact_float_result(&build->fields[0], &format, first); return 1;
    }
    if (!z_exact_float_input(request, 0, &format, &first)) return 0;
    if (z_exact_is_operation(signature, "nextUp")) { if (z_exact_nan(&format, first)) first = z_exact_quiet(&format, first); else if (z_exact_zero(&format, first)) first = 1; else if (!((first & ~format.sign_mask) == format.exponent_mask && (first & format.sign_mask) == 0)) first = (first & format.sign_mask) ? first - 1 : first + 1; z_exact_float_result(&build->fields[0], &format, first); return 1; }
    if (z_exact_is_operation(signature, "nextDown")) { if (z_exact_nan(&format, first)) first = z_exact_quiet(&format, first); else if (z_exact_zero(&format, first)) first = format.sign_mask | 1; else if ((first & ~format.sign_mask) != format.exponent_mask || (first & format.sign_mask) == 0) first = (first & format.sign_mask) ? first + 1 : first - 1; z_exact_float_result(&build->fields[0], &format, first); return 1; }
    if (!z_exact_float_input(request, 1, &format, &second)) return 0;
    if (z_exact_nan(&format, first)) first = z_exact_quiet(&format, first);
    else if (z_exact_nan(&format, second)) first = z_exact_quiet(&format, second);
    else if (first == second || (z_exact_zero(&format, first) && z_exact_zero(&format, second))) first = second;
    else if (z_exact_zero(&format, first)) first = (second & format.sign_mask) | 1;
    else { int greater = z_exact_order_key(&format, first) < z_exact_order_key(&format, second); int negative = (first & format.sign_mask) != 0; first = greater == negative ? first - 1 : first + 1; }
    z_exact_float_result(&build->fields[0], &format, first); return 1;
}

static int z_exact_eval_annex_f(const zmath_testing_oracle_operation_signature *signature,
                                const zmath_testing_oracle_request *request, z_exact_build *build) {
    z_exact_format format;
    uint64_t bits;
    uint64_t payload;
    if (z_exact_is_operation(signature, "getPayload")) {
        if (!z_exact_float_input(request, 0, &format, &bits)) return 0;
        if (!z_exact_nan(&format, bits)) { if (!z_exact_pack_integer(&format, 1, 1, &bits)) return 0; }
        else if (!z_exact_pack_integer(&format, bits & (format.quiet_nan_bit - 1), 0, &bits)) return 0;
        z_exact_float_result(&build->fields[0], &format, bits); return 1;
    }
    if (z_exact_is_operation(signature, "setPayload") || z_exact_is_operation(signature, "setPayloadSig")) {
        int signaling = z_exact_is_operation(signature, "setPayloadSig");
        if (!z_exact_float_input(request, 0, &format, &bits)) return 0;
        if (!z_exact_payload_integer(&format, bits, &payload) || (signaling && payload == 0)) { z_exact_float_result(&build->fields[0], &format, 0); z_exact_boolean_result(&build->fields[1], 0); }
        else { z_exact_float_result(&build->fields[0], &format, format.exponent_mask | (signaling ? 0 : format.quiet_nan_bit) | payload); z_exact_boolean_result(&build->fields[1], 1); }
        return 1;
    }
    if (!z_exact_float_input(request, 0, &format, &bits) || !z_exact_float_input(request, 1, &format, &payload)) return 0;
    if (z_exact_is_operation(signature, "totalOrderMag")) z_exact_boolean_result(&build->fields[0], (bits & ~format.sign_mask) <= (payload & ~format.sign_mask));
    else z_exact_boolean_result(&build->fields[0], z_exact_order_key(&format, bits) <= z_exact_order_key(&format, payload));
    return 1;
}

void zmath_testing_oracle_evaluate_exact_bits(
    const zmath_testing_oracle_operation_signature *signature,
    const zmath_testing_oracle_request *request,
    zmath_testing_oracle_result *result) {
    z_exact_build build;
    int ok = 0;
    if (!z_exact_begin(signature, request, result, &build)) { z_exact_fail(result, ZMATH_TESTING_ORACLE_ERROR); return; }
    if (z_exact_is_operation(signature, "abs")) ok = z_exact_eval_abs(request, &build);
    else if (z_exact_is_operation(signature, "ceil") || z_exact_is_operation(signature, "floor") || z_exact_is_operation(signature, "nearbyint") || z_exact_is_operation(signature, "rint") || z_exact_is_operation(signature, "round") || z_exact_is_operation(signature, "roundeven") || z_exact_is_operation(signature, "trunc")) ok = z_exact_eval_rounding(signature, request, &build);
    else if (z_exact_is_operation(signature, "fromfp") || z_exact_is_operation(signature, "fromfpx") || z_exact_is_operation(signature, "ufromfp") || z_exact_is_operation(signature, "ufromfpx")) ok = z_exact_eval_fromfp(signature, request, &build);
    else if (z_exact_is_operation(signature, "lrint") || z_exact_is_operation(signature, "llrint") || z_exact_is_operation(signature, "lround") || z_exact_is_operation(signature, "llround")) ok = z_exact_eval_integer_container(signature, request, &build);
    else if (z_exact_is_operation(signature, "fdim")) ok = z_exact_eval_fdim(request, &build);
    else if (z_exact_is_operation(signature, "fmax") || z_exact_is_operation(signature, "fmin") || z_exact_is_operation(signature, "fmaximum") || z_exact_is_operation(signature, "fminimum") || z_exact_is_operation(signature, "fmaximum_mag") || z_exact_is_operation(signature, "fminimum_mag") || z_exact_is_operation(signature, "fmaximum_mag_num") || z_exact_is_operation(signature, "fminimum_mag_num") || z_exact_is_operation(signature, "fmaximum_num") || z_exact_is_operation(signature, "fminimum_num")) ok = z_exact_eval_extrema(signature, request, &build);
    else if (z_exact_is_operation(signature, "fmod") || z_exact_is_operation(signature, "remainder") || z_exact_is_operation(signature, "remquo")) ok = z_exact_eval_remainder(signature, request, &build);
    else if (z_exact_is_operation(signature, "frexp") || z_exact_is_operation(signature, "modf")) ok = z_exact_eval_decompose(signature, request, &build);
    else if (z_exact_is_operation(signature, "ilogb")) ok = z_exact_eval_integer_logb(request, &build, 32);
    else if (z_exact_is_operation(signature, "llogb")) ok = z_exact_eval_integer_logb(request, &build, 64);
    else if (z_exact_is_operation(signature, "logb")) ok = z_exact_eval_logb(request, &build);
    else if (z_exact_is_operation(signature, "ldexp") || z_exact_is_operation(signature, "scalbn") || z_exact_is_operation(signature, "scalbln")) ok = z_exact_eval_scale(request, &build);
    else if (z_exact_is_operation(signature, "canonicalize") || z_exact_is_operation(signature, "copySign") || z_exact_is_operation(signature, "nan") || z_exact_is_operation(signature, "nextAfter") || z_exact_is_operation(signature, "nextDown") || z_exact_is_operation(signature, "nextToward") || z_exact_is_operation(signature, "nextUp")) ok = z_exact_eval_ieee(signature, request, &build);
    else if (z_exact_is_operation(signature, "getPayload") || z_exact_is_operation(signature, "setPayload") || z_exact_is_operation(signature, "setPayloadSig") || z_exact_is_operation(signature, "totalOrder") || z_exact_is_operation(signature, "totalOrderMag")) ok = z_exact_eval_annex_f(signature, request, &build);
    else ok = 0;
    if (!ok) z_exact_fail(result, ZMATH_TESTING_ORACLE_ERROR); else z_exact_finish(result, &build);
}
