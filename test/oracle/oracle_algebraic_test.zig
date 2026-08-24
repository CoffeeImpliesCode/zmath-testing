const std = @import("std");

const c = @cImport({
    @cInclude("oracle_evaluators.h");
});

extern fn zmath_testing_oracle_evaluate_algebraic(
    signature: *const c.zmath_testing_oracle_operation_signature,
    request: *const c.zmath_testing_oracle_request,
    result: *c.zmath_testing_oracle_result,
) void;
const Evaluation = struct {
    status: u32,
    field_count: u32,
    field: c.zmath_testing_oracle_result_field,
};

fn operation(signature: *const c.zmath_testing_oracle_operation_signature) []const u8 {
    std.debug.assert(signature.operation != null);
    const pointer: [*]const u8 = @ptrCast(signature.operation);
    return pointer[0..@intCast(signature.operation_length)];
}

fn inputPointer(
    fields: []const c.zmath_testing_oracle_input_field,
) [*c]const c.zmath_testing_oracle_input_field {
    if (fields.len == 0) return null;
    return fields.ptr;
}

fn outputPointer(
    fields: []c.zmath_testing_oracle_result_field,
) [*c]c.zmath_testing_oracle_result_field {
    if (fields.len == 0) return null;
    return fields.ptr;
}

fn oneBits(format: c.zmath_testing_oracle_format_descriptor) u64 {
    const exponent_bits: u6 = @intCast(format.exponent_bits);
    const fraction_bits: u6 = @intCast(format.fraction_bits);
    const bias = (@as(u64, 1) << (exponent_bits - 1)) - 1;
    return bias << fraction_bits;
}

fn makeInput(
    descriptor: c.zmath_testing_oracle_field_descriptor,
    value_bits: u64,
) c.zmath_testing_oracle_input_field {
    return .{
        .descriptor = descriptor,
        .value_bits = value_bits,
        .tag_bytes = null,
        .tag_length = 0,
        .reserved = 0,
    };
}

fn findSignature(
    operation_name: []const u8,
    source_code: u32,
    destination_code: u32,
) !*const c.zmath_testing_oracle_operation_signature {
    for (&c.zmath_testing_oracle_operation_table) |*signature| {
        if (signature.evaluator_category != c.ZMATH_TESTING_ORACLE_EVALUATOR_ALGEBRAIC) {
            continue;
        }
        if (!std.mem.eql(u8, operation(signature), operation_name)) continue;
        if (signature.arguments[0].format.code != source_code) continue;
        if (signature.result_fields[0].format.code != destination_code) continue;
        return signature;
    }
    return error.SignatureNotFound;
}

fn evaluate(
    signature: *const c.zmath_testing_oracle_operation_signature,
    value_bits: []const u64,
) Evaluation {
    std.debug.assert(value_bits.len == signature.arity);
    std.debug.assert(value_bits.len <= 3);

    var inputs: [3]c.zmath_testing_oracle_input_field = undefined;
    for (value_bits, 0..) |bits, index| {
        inputs[index] = makeInput(signature.arguments[index], bits);
    }
    const request: c.zmath_testing_oracle_request = .{
        .abi_version = c.ZMATH_TESTING_ORACLE_ABI_VERSION,
        .reserved = 0,
        .operation = signature.operation,
        .operation_length = signature.operation_length,
        .arity = signature.arity,
        .input_fields = inputPointer(inputs[0..value_bits.len]),
        .input_field_count = signature.arity,
        .result_layout = signature.result_layout,
        .structure_kind = signature.structure_kind,
        .result_field_count = signature.result_field_count,
        .result_fields = signature.result_fields,
    };
    var fields = [_]c.zmath_testing_oracle_result_field{.{
        .descriptor = signature.result_fields[0],
        .value_bits = 0xdead_beef_dead_beef,
        .class_code = c.ZMATH_TESTING_ORACLE_CLASS_NONE,
        .reserved = 0,
    }};
    var result: c.zmath_testing_oracle_result = .{
        .status = c.ZMATH_TESTING_ORACLE_ERROR,
        .reserved = 0,
        .field_capacity = 1,
        .field_count = 0,
        .fields = outputPointer(&fields),
    };
    zmath_testing_oracle_evaluate_algebraic(signature, &request, &result);
    return .{
        .status = result.status,
        .field_count = result.field_count,
        .field = fields[0],
    };
}

test "all algebraic table rows invoke the candidate and proof evaluator" {
    var algebraic_count: u32 = 0;
    for (&c.zmath_testing_oracle_operation_table) |*signature| {
        if (signature.evaluator_category != c.ZMATH_TESTING_ORACLE_EVALUATOR_ALGEBRAIC) {
            continue;
        }
        var values: [3]u64 = undefined;
        for (0..signature.arity) |index| {
            values[index] = oneBits(signature.arguments[index].format);
        }
        const evaluation = evaluate(signature, values[0..signature.arity]);
        try std.testing.expectEqual(
            @as(u32, c.ZMATH_TESTING_ORACLE_OK),
            evaluation.status,
        );
        try std.testing.expectEqual(@as(u32, 1), evaluation.field_count);
        try std.testing.expectEqual(
            @as(u32, c.ZMATH_TESTING_ORACLE_CLASS_NORMAL),
            evaluation.field.class_code,
        );
        try std.testing.expectEqual(@as(u32, 0), evaluation.field.reserved);
        algebraic_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 39), algebraic_count);
}

test "algebraic evaluator preserves exact cross-width specials" {
    const narrow_add = try findSignature(
        "f16addf32",
        c.ZMATH_TESTING_ORACLE_FORMAT_F,
        c.ZMATH_TESTING_ORACLE_FORMAT_H,
    );
    const nan_evaluation = evaluate(narrow_add, &.{ 0xffaa_a000, 0x3f80_0000 });
    try std.testing.expectEqual(
        @as(u32, c.ZMATH_TESTING_ORACLE_OK),
        nan_evaluation.status,
    );
    try std.testing.expectEqual(@as(u64, 0xff55), nan_evaluation.field.value_bits);
    try std.testing.expectEqual(
        @as(u32, c.ZMATH_TESTING_ORACLE_CLASS_QNAN),
        nan_evaluation.field.class_code,
    );

    const zero_evaluation = evaluate(narrow_add, &.{ 0x8000_0000, 0x8000_0000 });
    try std.testing.expectEqual(
        @as(u32, c.ZMATH_TESTING_ORACLE_OK),
        zero_evaluation.status,
    );
    try std.testing.expectEqual(@as(u64, 0x8000), zero_evaluation.field.value_bits);
    try std.testing.expectEqual(
        @as(u32, c.ZMATH_TESTING_ORACLE_CLASS_ZERO),
        zero_evaluation.field.class_code,
    );

    const invalid_fma = try findSignature(
        "fma",
        c.ZMATH_TESTING_ORACLE_FORMAT_H,
        c.ZMATH_TESTING_ORACLE_FORMAT_H,
    );
    const invalid_evaluation = evaluate(invalid_fma, &.{ 0x7c00, 0x0000, 0x3c00 });
    try std.testing.expectEqual(
        @as(u32, c.ZMATH_TESTING_ORACLE_OK),
        invalid_evaluation.status,
    );
    try std.testing.expectEqual(@as(u64, 0x7e00), invalid_evaluation.field.value_bits);
    try std.testing.expectEqual(
        @as(u32, c.ZMATH_TESTING_ORACLE_CLASS_QNAN),
        invalid_evaluation.field.class_code,
    );

    const hypot_f = try findSignature(
        "hypot",
        c.ZMATH_TESTING_ORACLE_FORMAT_F,
        c.ZMATH_TESTING_ORACLE_FORMAT_F,
    );
    const infinity_evaluation = evaluate(hypot_f, &.{ 0x7fc1_2345, 0x7f80_0000 });
    try std.testing.expectEqual(
        @as(u32, c.ZMATH_TESTING_ORACLE_OK),
        infinity_evaluation.status,
    );
    try std.testing.expectEqual(@as(u64, 0x7f80_0000), infinity_evaluation.field.value_bits);
    try std.testing.expectEqual(
        @as(u32, c.ZMATH_TESTING_ORACLE_CLASS_INFINITY),
        infinity_evaluation.field.class_code,
    );

    const sqrt_d = try findSignature(
        "sqrt",
        c.ZMATH_TESTING_ORACLE_FORMAT_D,
        c.ZMATH_TESTING_ORACLE_FORMAT_D,
    );
    const negative_sqrt = evaluate(sqrt_d, &.{0xbff0_0000_0000_0000});
    try std.testing.expectEqual(
        @as(u32, c.ZMATH_TESTING_ORACLE_OK),
        negative_sqrt.status,
    );
    try std.testing.expectEqual(
        @as(u64, 0x7ff8_0000_0000_0000),
        negative_sqrt.field.value_bits,
    );
    try std.testing.expectEqual(
        @as(u32, c.ZMATH_TESTING_ORACLE_CLASS_QNAN),
        negative_sqrt.field.class_code,
    );

    const rsqrt_d = try findSignature(
        "rsqrt",
        c.ZMATH_TESTING_ORACLE_FORMAT_D,
        c.ZMATH_TESTING_ORACLE_FORMAT_D,
    );
    const negative_zero = evaluate(rsqrt_d, &.{0x8000_0000_0000_0000});
    try std.testing.expectEqual(
        @as(u32, c.ZMATH_TESTING_ORACLE_OK),
        negative_zero.status,
    );
    try std.testing.expectEqual(
        @as(u64, 0xfff0_0000_0000_0000),
        negative_zero.field.value_bits,
    );
    try std.testing.expectEqual(
        @as(u32, c.ZMATH_TESTING_ORACLE_CLASS_INFINITY),
        negative_zero.field.class_code,
    );
}

test "copied signatures fail closed instead of selecting by spelling" {
    const signature = try findSignature(
        "sqrt",
        c.ZMATH_TESTING_ORACLE_FORMAT_H,
        c.ZMATH_TESTING_ORACLE_FORMAT_H,
    );
    var copied_signature = signature.*;
    var inputs = [_]c.zmath_testing_oracle_input_field{
        makeInput(signature.arguments[0], 0x4000),
    };
    const request: c.zmath_testing_oracle_request = .{
        .abi_version = c.ZMATH_TESTING_ORACLE_ABI_VERSION,
        .reserved = 0,
        .operation = signature.operation,
        .operation_length = signature.operation_length,
        .arity = signature.arity,
        .input_fields = inputPointer(&inputs),
        .input_field_count = signature.arity,
        .result_layout = signature.result_layout,
        .structure_kind = signature.structure_kind,
        .result_field_count = signature.result_field_count,
        .result_fields = signature.result_fields,
    };
    var fields = [_]c.zmath_testing_oracle_result_field{.{
        .descriptor = signature.result_fields[0],
        .value_bits = 0xdead_beef_dead_beef,
        .class_code = c.ZMATH_TESTING_ORACLE_CLASS_NONE,
        .reserved = 0,
    }};
    var result: c.zmath_testing_oracle_result = .{
        .status = c.ZMATH_TESTING_ORACLE_OK,
        .reserved = 0,
        .field_capacity = 1,
        .field_count = 1,
        .fields = outputPointer(&fields),
    };
    zmath_testing_oracle_evaluate_algebraic(&copied_signature, &request, &result);
    try std.testing.expectEqual(@as(u32, c.ZMATH_TESTING_ORACLE_ERROR), result.status);
    try std.testing.expectEqual(@as(u32, 0), result.field_count);
    try std.testing.expectEqual(@as(u64, 0xdead_beef_dead_beef), fields[0].value_bits);
}
