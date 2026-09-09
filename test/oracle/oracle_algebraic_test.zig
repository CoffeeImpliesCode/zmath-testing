const std = @import("std");

const c = @import("oracle_abi");

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

const Regression = struct {
    operation_name: []const u8,
    source_code: u32,
    destination_code: u32,
    inputs: [3]u64,
    arity: usize,
    expected_bits: u64,
    expected_class: u32,
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

fn expectRegression(case: Regression) !void {
    const signature = try findSignature(
        case.operation_name,
        case.source_code,
        case.destination_code,
    );
    const evaluation = evaluate(signature, case.inputs[0..case.arity]);
    try std.testing.expectEqual(
        @as(u32, c.ZMATH_TESTING_ORACLE_OK),
        evaluation.status,
    );
    try std.testing.expectEqual(@as(u32, 1), evaluation.field_count);
    try std.testing.expectEqual(case.expected_bits, evaluation.field.value_bits);
    try std.testing.expectEqual(case.expected_class, evaluation.field.class_code);
    try std.testing.expectEqual(@as(u32, 0), evaluation.field.reserved);
}

test "exact narrowing keeps sticky bits across extreme exponent gaps" {
    const cases = [_]Regression{
        .{ .operation_name = "f32fmaf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0x3ff0_0000_1000_0000, 0x3ff0_0000_0000_0000, 0x0000_0000_0000_0001 }, .arity = 3, .expected_bits = 0x3f80_0001, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
        .{ .operation_name = "f32fmaf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0x3ff0_0000_1000_0000, 0x3ff0_0000_0000_0000, 0x8000_0000_0000_0001 }, .arity = 3, .expected_bits = 0x3f80_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
        .{ .operation_name = "f32fmaf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0x3690_0000_0000_0000, 0x3ff0_0000_0000_0000, 0x0000_0000_0000_0001 }, .arity = 3, .expected_bits = 0x0000_0001, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL },
        .{ .operation_name = "f32fmaf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0x3690_0000_0000_0000, 0x3ff0_0000_0000_0000, 0x0000_0000_0000_0000 }, .arity = 3, .expected_bits = 0x0000_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_ZERO },
        .{ .operation_name = "f32fmaf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0x7fef_ffff_ffff_ffff, 0x0010_0000_0000_0000, 0xc010_0000_0000_0000 }, .arity = 3, .expected_bits = 0xa600_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
        .{ .operation_name = "f16fmaf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H, .inputs = .{ 0x3ff0_0200_0000_0000, 0x3ff0_0000_0000_0000, 0x0000_0000_0000_0001 }, .arity = 3, .expected_bits = 0x3c01, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
        .{ .operation_name = "f16fmaf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H, .inputs = .{ 0x3ff0_0200_0000_0000, 0x3ff0_0000_0000_0000, 0x8000_0000_0000_0001 }, .arity = 3, .expected_bits = 0x3c00, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
        .{ .operation_name = "f16fmaf32", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H, .inputs = .{ 0x3f80_1000, 0x3f80_0000, 0x0000_0001 }, .arity = 3, .expected_bits = 0x3c01, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
        .{ .operation_name = "f16addf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H, .inputs = .{ 0x3ff0_0200_0000_0000, 0x0000_0000_0000_0001, 0 }, .arity = 2, .expected_bits = 0x3c01, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
        .{ .operation_name = "f16subf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H, .inputs = .{ 0x3ff0_0200_0000_0000, 0x0000_0000_0000_0001, 0 }, .arity = 2, .expected_bits = 0x3c00, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
        .{ .operation_name = "f32addf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0x3ff0_0000_1000_0000, 0x0000_0000_0000_0001, 0 }, .arity = 2, .expected_bits = 0x3f80_0001, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
        .{ .operation_name = "f32subf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0x3ff0_0000_1000_0000, 0x0000_0000_0000_0001, 0 }, .arity = 2, .expected_bits = 0x3f80_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
    };
    for (cases) |case| try expectRegression(case);
}

test "algebraic proof accepts ties only for the even destination" {
    const cases = [_]Regression{
        .{ .operation_name = "f16sqrtf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H, .inputs = .{ 0x3ff0_0400_4000_0000, 0, 0 }, .arity = 1, .expected_bits = 0x3c00, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
        .{ .operation_name = "f16sqrtf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H, .inputs = .{ 0x3ff0_0c02_4000_0000, 0, 0 }, .arity = 1, .expected_bits = 0x3c02, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
        .{ .operation_name = "f32sqrtf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0x3fd0_0000_2000_0010, 0, 0 }, .arity = 1, .expected_bits = 0x3f00_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
        .{ .operation_name = "f32sqrtf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0x3fd0_0000_6000_0090, 0, 0 }, .arity = 1, .expected_bits = 0x3f00_0002, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
        .{ .operation_name = "f16sqrtf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H, .inputs = .{ 0x3cd0_0000_0000_0000, 0, 0 }, .arity = 1, .expected_bits = 0x0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_ZERO },
        .{ .operation_name = "f16sqrtf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H, .inputs = .{ 0x41ef_fc00_2000_0000, 0, 0 }, .arity = 1, .expected_bits = 0x7c00, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY },
        .{ .operation_name = "f32sqrtf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0x4fef_ffff_e000_0008, 0, 0 }, .arity = 1, .expected_bits = 0x7f80_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY },
    };
    for (cases) |case| try expectRegression(case);
}

test "exact arithmetic rounds finite overflow underflow and cancellation" {
    const cases = [_]Regression{
        .{ .operation_name = "f32fmaf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0x47ef_ffff_f000_0000, 0x3ff0_0000_0000_0000, 0 }, .arity = 3, .expected_bits = 0x7f80_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY },
        .{ .operation_name = "f32fmaf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0x47ef_ffff_efff_ffff, 0x3ff0_0000_0000_0000, 0 }, .arity = 3, .expected_bits = 0x7f7f_ffff, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
        .{ .operation_name = "f32fmaf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0xc7ef_ffff_f000_0000, 0x3ff0_0000_0000_0000, 0 }, .arity = 3, .expected_bits = 0xff80_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY },
        .{ .operation_name = "f32fmaf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0xb690_0000_0000_0000, 0x3ff0_0000_0000_0000, 0x8000_0000_0000_0001 }, .arity = 3, .expected_bits = 0x8000_0001, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL },
        .{ .operation_name = "f32fmaf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0x3ff0_0000_0000_0000, 0x3ff0_0000_0000_0000, 0xbff0_0000_0000_0000 }, .arity = 3, .expected_bits = 0x0000_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_ZERO },
        .{ .operation_name = "ffma", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0x8000_0000_0000_0000, 0x3ff0_0000_0000_0000, 0x8000_0000_0000_0000 }, .arity = 3, .expected_bits = 0x8000_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_ZERO },
    };
    for (cases) |case| try expectRegression(case);
}

test "algebraic roots and hypot prove exact and overflowing results" {
    const cases = [_]Regression{
        .{ .operation_name = "cbrt", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .inputs = .{ 0xc020_0000_0000_0000, 0, 0 }, .arity = 1, .expected_bits = 0xc000_0000_0000_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
        .{ .operation_name = "rsqrt", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .inputs = .{ 0x4010_0000_0000_0000, 0, 0 }, .arity = 1, .expected_bits = 0x3fe0_0000_0000_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
        .{ .operation_name = "hypot", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .inputs = .{ 0x4008_0000_0000_0000, 0x4010_0000_0000_0000, 0 }, .arity = 2, .expected_bits = 0x4014_0000_0000_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL },
        .{ .operation_name = "hypot", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .inputs = .{ 0x7fef_ffff_ffff_ffff, 0x7fef_ffff_ffff_ffff, 0 }, .arity = 2, .expected_bits = 0x7ff0_0000_0000_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY },
    };
    for (cases) |case| try expectRegression(case);
}

test "algebraic evaluator preserves exact special-value policy" {
    const cases = [_]Regression{
        .{ .operation_name = "f16addf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H, .inputs = .{ 0xfff4_0000_0000_0000, 0x7ff8_1234_0000_0000, 0 }, .arity = 2, .expected_bits = 0xff00, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_QNAN },
        .{ .operation_name = "f32fmaf64", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0xfff4_0000_0000_0000, 0x7ff8_1234_0000_0000, 0x7ff8_5678_0000_0000 }, .arity = 3, .expected_bits = 0xffe0_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_QNAN },
        .{ .operation_name = "fma", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_H, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H, .inputs = .{ 0x7c00, 0x0000, 0x3c00 }, .arity = 3, .expected_bits = 0x7e00, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_QNAN },
        .{ .operation_name = "hypot", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F, .inputs = .{ 0x7fc1_2345, 0x7f80_0000, 0 }, .arity = 2, .expected_bits = 0x7f80_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY },
        .{ .operation_name = "hypot", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_H, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H, .inputs = .{ 0x7c00, 0xfc01, 0 }, .arity = 2, .expected_bits = 0xfe01, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_QNAN },
        .{ .operation_name = "hypot", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_H, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H, .inputs = .{ 0x7e02, 0xfc01, 0 }, .arity = 2, .expected_bits = 0x7e02, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_QNAN },
        .{ .operation_name = "sqrt", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .inputs = .{ 0xbff0_0000_0000_0000, 0, 0 }, .arity = 1, .expected_bits = 0x7ff8_0000_0000_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_QNAN },
        .{ .operation_name = "rsqrt", .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_D, .inputs = .{ 0x8000_0000_0000_0000, 0, 0 }, .arity = 1, .expected_bits = 0xfff0_0000_0000_0000, .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY },
    };
    for (cases) |case| try expectRegression(case);
}
