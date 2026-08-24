const std = @import("std");
const zmath = @import("zmath");
const corpus = @import("corpus_support");

extern fn zmath_testing_mpfr_smoke() c_int;
extern fn zmath_testing_arb_smoke() c_int;

const format_h: corpus.OracleFormatDescriptor = .{
    .code = .h,
    .storage_bits = 16,
    .exponent_bits = 5,
    .fraction_bits = 10,
    .reserved = 0,
};

const float_h: corpus.OracleFieldDescriptor = .{
    .kind = .float,
    .value_bits = 16,
    .format = format_h,
    .reserved = 0,
};

fn constPointer(comptime T: type, values: []const T) [*c]const T {
    if (values.len == 0) return null;
    return values.ptr;
}

fn outputPointer(values: []corpus.OracleResultField) [*c]corpus.OracleResultField {
    if (values.len == 0) return null;
    return values.ptr;
}

test "zmath public-surface smoke check" {
    try std.testing.expectEqual(@as(i32, 10), zmath.add(3, 7));
}

test "MPFR environment smoke check" {
    try std.testing.expectEqual(@as(c_int, 1), zmath_testing_mpfr_smoke());
}

test "Arb environment smoke check" {
    try std.testing.expectEqual(@as(c_int, 1), zmath_testing_arb_smoke());
}

test "v2 scalar oracle smoke check" {
    const input_fields = [_]corpus.OracleInputField{.{
        .descriptor = float_h,
        .bits = 0,
    }};
    const result_descriptors = [_]corpus.OracleFieldDescriptor{float_h};
    const request = corpus.OracleRequest{
        .abi_version = corpus.oracle_abi_version,
        .reserved = 0,
        .operation = constPointer(u8, "exp"),
        .operation_length = 3,
        .arity = 1,
        .input_fields = constPointer(corpus.OracleInputField, &input_fields),
        .input_field_count = 1,
        .result_layout = .scalar,
        .structure_kind = .none,
        .result_field_count = 1,
        .result_fields = constPointer(corpus.OracleFieldDescriptor, &result_descriptors),
    };

    var fields = [_]corpus.OracleResultField{.{
        .descriptor = float_h,
        .bits = 0xdead_beef_dead_beef,
        .class_code = .none,
        .reserved = 0,
    }};
    var result = corpus.OracleResult{
        .status = .@"error",
        .reserved = 0,
        .field_capacity = 1,
        .field_count = 0,
        .fields = outputPointer(&fields),
    };

    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);

    try std.testing.expectEqual(corpus.OracleStatus.ok, result.status);
    try std.testing.expectEqual(@as(u32, 1), result.field_count);
    try std.testing.expectEqual(@as(u64, 0x3c00), fields[0].bits);
    try std.testing.expectEqual(corpus.OracleClass.normal, fields[0].class_code);

    var proof_fields = [_]corpus.OracleResultField{.{
        .descriptor = float_h,
        .bits = 0xdead_beef_dead_beef,
        .class_code = .none,
        .reserved = 0,
    }};
    var proof = corpus.OracleResult{
        .status = .@"error",
        .reserved = 0,
        .field_capacity = 1,
        .field_count = 0,
        .fields = outputPointer(&proof_fields),
    };
    corpus.zmath_testing_oracle_v2_arb_prove(&request, &result, &proof);
    try std.testing.expectEqual(corpus.OracleStatus.ok, proof.status);
    try std.testing.expectEqual(@as(u32, 1), proof.field_count);
    try std.testing.expectEqual(@as(u64, 0x3c00), proof_fields[0].bits);
}

test {
    _ = @import("oracle_bridge_test.zig");
    _ = @import("corpus_runner.zig");
    _ = @import("oracle_fuzz.zig");
}
