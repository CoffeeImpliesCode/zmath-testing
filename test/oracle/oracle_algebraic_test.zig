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
        .{
            .operation_name = "f32fmaf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0x3ff0_0000_1000_0000, 0x3ff0_0000_0000_0000, 0x0000_0000_0000_0001 },
            .arity = 3,
            .expected_bits = 0x3f80_0001,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "f32fmaf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0x3ff0_0000_1000_0000, 0x3ff0_0000_0000_0000, 0x8000_0000_0000_0001 },
            .arity = 3,
            .expected_bits = 0x3f80_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "f32fmaf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0x3690_0000_0000_0000, 0x3ff0_0000_0000_0000, 0x0000_0000_0000_0001 },
            .arity = 3,
            .expected_bits = 0x0000_0001,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL,
        },
        .{
            .operation_name = "f32fmaf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0x3690_0000_0000_0000, 0x3ff0_0000_0000_0000, 0x0000_0000_0000_0000 },
            .arity = 3,
            .expected_bits = 0x0000_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_ZERO,
        },
        .{
            .operation_name = "f32fmaf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0x7fef_ffff_ffff_ffff, 0x0010_0000_0000_0000, 0xc010_0000_0000_0000 },
            .arity = 3,
            .expected_bits = 0xa600_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "f16fmaf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .inputs = .{ 0x3ff0_0200_0000_0000, 0x3ff0_0000_0000_0000, 0x0000_0000_0000_0001 },
            .arity = 3,
            .expected_bits = 0x3c01,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "f16fmaf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .inputs = .{ 0x3ff0_0200_0000_0000, 0x3ff0_0000_0000_0000, 0x8000_0000_0000_0001 },
            .arity = 3,
            .expected_bits = 0x3c00,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "f16fmaf32",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .inputs = .{ 0x3f80_1000, 0x3f80_0000, 0x0000_0001 },
            .arity = 3,
            .expected_bits = 0x3c01,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "f16addf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .inputs = .{ 0x3ff0_0200_0000_0000, 0x0000_0000_0000_0001, 0 },
            .arity = 2,
            .expected_bits = 0x3c01,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "f16subf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .inputs = .{ 0x3ff0_0200_0000_0000, 0x0000_0000_0000_0001, 0 },
            .arity = 2,
            .expected_bits = 0x3c00,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "f32addf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0x3ff0_0000_1000_0000, 0x0000_0000_0000_0001, 0 },
            .arity = 2,
            .expected_bits = 0x3f80_0001,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "f32subf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0x3ff0_0000_1000_0000, 0x0000_0000_0000_0001, 0 },
            .arity = 2,
            .expected_bits = 0x3f80_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
    };
    for (cases) |case| try expectRegression(case);
}

test "algebraic proof accepts ties only for the even destination" {
    const cases = [_]Regression{
        .{
            .operation_name = "f16sqrtf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .inputs = .{ 0x3ff0_0400_4000_0000, 0, 0 },
            .arity = 1,
            .expected_bits = 0x3c00,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "f16sqrtf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .inputs = .{ 0x3ff0_0c02_4000_0000, 0, 0 },
            .arity = 1,
            .expected_bits = 0x3c02,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "f32sqrtf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0x3fd0_0000_2000_0010, 0, 0 },
            .arity = 1,
            .expected_bits = 0x3f00_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "f32sqrtf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0x3fd0_0000_6000_0090, 0, 0 },
            .arity = 1,
            .expected_bits = 0x3f00_0002,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "f16sqrtf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .inputs = .{ 0x3cd0_0000_0000_0000, 0, 0 },
            .arity = 1,
            .expected_bits = 0x0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_ZERO,
        },
        .{
            .operation_name = "f16sqrtf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .inputs = .{ 0x41ef_fc00_2000_0000, 0, 0 },
            .arity = 1,
            .expected_bits = 0x7c00,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY,
        },
        .{
            .operation_name = "f32sqrtf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0x4fef_ffff_e000_0008, 0, 0 },
            .arity = 1,
            .expected_bits = 0x7f80_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY,
        },
    };
    for (cases) |case| try expectRegression(case);
}

test "exact arithmetic rounds finite overflow underflow and cancellation" {
    const cases = [_]Regression{
        .{
            .operation_name = "f32fmaf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0x47ef_ffff_f000_0000, 0x3ff0_0000_0000_0000, 0 },
            .arity = 3,
            .expected_bits = 0x7f80_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY,
        },
        .{
            .operation_name = "f32fmaf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0x47ef_ffff_efff_ffff, 0x3ff0_0000_0000_0000, 0 },
            .arity = 3,
            .expected_bits = 0x7f7f_ffff,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "f32fmaf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0xc7ef_ffff_f000_0000, 0x3ff0_0000_0000_0000, 0 },
            .arity = 3,
            .expected_bits = 0xff80_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY,
        },
        .{
            .operation_name = "f32fmaf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0xb690_0000_0000_0000, 0x3ff0_0000_0000_0000, 0x8000_0000_0000_0001 },
            .arity = 3,
            .expected_bits = 0x8000_0001,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL,
        },
        .{
            .operation_name = "f32fmaf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0x3ff0_0000_0000_0000, 0x3ff0_0000_0000_0000, 0xbff0_0000_0000_0000 },
            .arity = 3,
            .expected_bits = 0x0000_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_ZERO,
        },
        .{
            .operation_name = "ffma",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0x8000_0000_0000_0000, 0x3ff0_0000_0000_0000, 0x8000_0000_0000_0000 },
            .arity = 3,
            .expected_bits = 0x8000_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_ZERO,
        },
    };
    for (cases) |case| try expectRegression(case);
}

test "algebraic roots and hypot prove exact and overflowing results" {
    const cases = [_]Regression{
        .{
            .operation_name = "cbrt",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = .{ 0xc020_0000_0000_0000, 0, 0 },
            .arity = 1,
            .expected_bits = 0xc000_0000_0000_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "rsqrt",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = .{ 0x4010_0000_0000_0000, 0, 0 },
            .arity = 1,
            .expected_bits = 0x3fe0_0000_0000_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "hypot",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = .{ 0x4008_0000_0000_0000, 0x4010_0000_0000_0000, 0 },
            .arity = 2,
            .expected_bits = 0x4014_0000_0000_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "hypot",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = .{ 0x7fef_ffff_ffff_ffff, 0x7fef_ffff_ffff_ffff, 0 },
            .arity = 2,
            .expected_bits = 0x7ff0_0000_0000_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY,
        },
    };
    for (cases) |case| try expectRegression(case);
}

test "algebraic evaluator preserves exact special-value policy" {
    const cases = [_]Regression{
        .{
            .operation_name = "f16addf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .inputs = .{ 0xfff4_0000_0000_0000, 0x7ff8_1234_0000_0000, 0 },
            .arity = 2,
            .expected_bits = 0xff00,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_QNAN,
        },
        .{
            .operation_name = "f32fmaf64",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0xfff4_0000_0000_0000, 0x7ff8_1234_0000_0000, 0x7ff8_5678_0000_0000 },
            .arity = 3,
            .expected_bits = 0xffe0_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_QNAN,
        },
        .{
            .operation_name = "fma",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .inputs = .{ 0x7c00, 0x0000, 0x3c00 },
            .arity = 3,
            .expected_bits = 0x7e00,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_QNAN,
        },
        .{
            .operation_name = "hypot",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = .{ 0x7fc1_2345, 0x7f80_0000, 0 },
            .arity = 2,
            .expected_bits = 0x7f80_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY,
        },
        .{
            .operation_name = "hypot",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .inputs = .{ 0x7c00, 0xfc01, 0 },
            .arity = 2,
            .expected_bits = 0xfe01,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_QNAN,
        },
        .{
            .operation_name = "hypot",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .inputs = .{ 0x7e02, 0xfc01, 0 },
            .arity = 2,
            .expected_bits = 0x7e02,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_QNAN,
        },
        .{
            .operation_name = "sqrt",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = .{ 0xbff0_0000_0000_0000, 0, 0 },
            .arity = 1,
            .expected_bits = 0x7ff8_0000_0000_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_QNAN,
        },
        .{
            .operation_name = "rsqrt",
            .source_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .destination_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = .{ 0x8000_0000_0000_0000, 0, 0 },
            .arity = 1,
            .expected_bits = 0xfff0_0000_0000_0000,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY,
        },
    };
    for (cases) |case| try expectRegression(case);
}

// ---------------------------------------------------------------------------
// Non-scalar numerical coverage
//
// The five operations below are the complex, matrix, linear-algebra, and
// geometry rows of the selected coverage. They are absent from the immutable C
// table today, so every case fails behaviorally instead of by compilation: the
// request is matched against the real table by
// zmath_testing_oracle_find_operation_signature, and a row that is missing or
// declared with another layout fails with error.OperationRowMissing.
//
// Codes 12 and 13 are the raw ABI values of the complex and lu-solve result
// layouts. The header enumerators do not name them yet, and the table match
// refuses any other value, so a later header rename needs no test edit.
// ---------------------------------------------------------------------------

const MaxFields: usize = c.ZMATH_TESTING_ORACLE_MAX_FIELDS;

const layout_complex: u32 = 12;
const layout_lu_solve: u32 = 13;

const float_f = c.zmath_testing_oracle_field_descriptor{
    .kind = c.ZMATH_TESTING_ORACLE_FIELD_FLOAT,
    .value_bits = 32,
    .format = .{
        .code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
        .storage_bits = 32,
        .exponent_bits = 8,
        .fraction_bits = 23,
        .reserved = 0,
    },
    .reserved = 0,
};

const float_d = c.zmath_testing_oracle_field_descriptor{
    .kind = c.ZMATH_TESTING_ORACLE_FIELD_FLOAT,
    .value_bits = 64,
    .format = .{
        .code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
        .storage_bits = 64,
        .exponent_bits = 11,
        .fraction_bits = 52,
        .reserved = 0,
    },
    .reserved = 0,
};

const tag_field = c.zmath_testing_oracle_field_descriptor{
    .kind = c.ZMATH_TESTING_ORACLE_FIELD_TAG,
    .value_bits = 0,
    .format = .{
        .code = c.ZMATH_TESTING_ORACLE_FORMAT_NONE,
        .storage_bits = 0,
        .exponent_bits = 0,
        .fraction_bits = 0,
        .reserved = 0,
    },
    .reserved = 0,
};

const boolean_field = c.zmath_testing_oracle_field_descriptor{
    .kind = c.ZMATH_TESTING_ORACLE_FIELD_BOOLEAN,
    .value_bits = 1,
    .format = .{
        .code = c.ZMATH_TESTING_ORACLE_FORMAT_NONE,
        .storage_bits = 0,
        .exponent_bits = 0,
        .fraction_bits = 0,
        .reserved = 0,
    },
    .reserved = 0,
};

const sign_field = c.zmath_testing_oracle_field_descriptor{
    .kind = c.ZMATH_TESTING_ORACLE_FIELD_SIGNED_INTEGER,
    .value_bits = 32,
    .format = .{
        .code = c.ZMATH_TESTING_ORACLE_FORMAT_NONE,
        .storage_bits = 0,
        .exponent_bits = 0,
        .fraction_bits = 0,
        .reserved = 0,
    },
    .reserved = 0,
};

const complex_f = [_]c.zmath_testing_oracle_field_descriptor{ float_f, float_f };
const complex_d = [_]c.zmath_testing_oracle_field_descriptor{ float_d, float_d };
const lu_solve_f = [_]c.zmath_testing_oracle_field_descriptor{ float_f, float_f, boolean_field };
const lu_solve_d = [_]c.zmath_testing_oracle_field_descriptor{ float_d, float_d, boolean_field };
const scalar_f = [_]c.zmath_testing_oracle_field_descriptor{float_f};
const scalar_d = [_]c.zmath_testing_oracle_field_descriptor{float_d};
const sign_only = [_]c.zmath_testing_oracle_field_descriptor{sign_field};

/// One expected result field.
const NumericField = union(enum) {
    /// The full output bits. The IEEE class is derived from them and checked
    /// separately, so a wrong class cannot hide behind matching bits.
    bits: u64,
    /// Any quiet NaN. The NaN payload is not an arithmetic result, so only the
    /// class is pinned here and the sibling fields carry the exact witness that
    /// the value really is a NaN and not a substituted number.
    quiet_nan,
};

const NumericCase = struct {
    operation_name: []const u8,
    format_code: u32,
    /// Every input is a float of `format_code` except the one at `tag_index`,
    /// which carries `tag_text`.
    inputs: []const u64,
    arity: usize,
    tag_index: ?usize,
    tag_text: []const u8,
    result_layout: u32,
    structure_kind: u32,
    result_fields: []const c.zmath_testing_oracle_field_descriptor,
    expected: []const NumericField,
};

const NumericEvaluation = struct {
    status: u32,
    field_count: u32,
    fields: [MaxFields]c.zmath_testing_oracle_result_field,
};

/// The table row that names one case, or null. It only separates a missing
/// operation from a declared-but-different layout; the C lookup below stays the
/// authority for the signature the evaluator receives.
fn tableRow(case: NumericCase) ?*const c.zmath_testing_oracle_operation_signature {
    for (&c.zmath_testing_oracle_operation_table) |*row| {
        if (!std.mem.eql(u8, operation(row), case.operation_name)) continue;
        if (row.arguments[0].format.code != case.format_code) continue;
        return row;
    }
    return null;
}

fn numericInputDescriptor(case: NumericCase, index: usize) c.zmath_testing_oracle_field_descriptor {
    if (case.tag_index != null and case.tag_index.? == index) return tag_field;
    return if (case.format_code == c.ZMATH_TESTING_ORACLE_FORMAT_F) float_f else float_d;
}

/// The IEEE class of `bits` read through `descriptor`, decoded here rather than
/// taken from the C result, so a wrong class_code is caught.
fn numericFloatClass(
    descriptor: c.zmath_testing_oracle_field_descriptor,
    bits: u64,
) u32 {
    if (descriptor.kind != c.ZMATH_TESTING_ORACLE_FIELD_FLOAT) {
        return c.ZMATH_TESTING_ORACLE_CLASS_NONE;
    }
    const fraction_bits: u6 = @intCast(descriptor.format.fraction_bits);
    const exponent_bits: u6 = @intCast(descriptor.format.exponent_bits);
    const fraction_mask = (@as(u64, 1) << fraction_bits) - 1;
    const exponent_mask = ((@as(u64, 1) << exponent_bits) - 1) << fraction_bits;
    const quiet_bit = @as(u64, 1) << (fraction_bits - 1);
    const exponent = bits & exponent_mask;
    const fraction = bits & fraction_mask;
    if (exponent == exponent_mask) {
        if (fraction == 0) return c.ZMATH_TESTING_ORACLE_CLASS_INFINITY;
        return if ((fraction & quiet_bit) != 0)
            c.ZMATH_TESTING_ORACLE_CLASS_QNAN
        else
            c.ZMATH_TESTING_ORACLE_CLASS_SNAN;
    }
    if (exponent == 0) {
        return if (fraction == 0)
            c.ZMATH_TESTING_ORACLE_CLASS_ZERO
        else
            c.ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL;
    }
    return c.ZMATH_TESTING_ORACLE_CLASS_NORMAL;
}

fn evaluateNumeric(case: NumericCase) !NumericEvaluation {
    if (case.arity == 0 or case.arity > MaxFields or case.inputs.len != case.arity or
        case.result_fields.len == 0 or case.result_fields.len > MaxFields or
        case.expected.len != case.result_fields.len)
    {
        return error.MalformedCase;
    }
    var inputs: [MaxFields]c.zmath_testing_oracle_input_field = undefined;
    for (0..case.arity) |index| {
        const tagged = case.tag_index != null and case.tag_index.? == index;
        inputs[index] = .{
            .descriptor = numericInputDescriptor(case, index),
            .value_bits = case.inputs[index],
            .tag_bytes = if (tagged) case.tag_text.ptr else null,
            .tag_length = if (tagged)
                std.math.cast(u32, case.tag_text.len) orelse return error.MalformedCase
            else
                0,
            .reserved = 0,
        };
    }
    const request: c.zmath_testing_oracle_request = .{
        .abi_version = c.ZMATH_TESTING_ORACLE_ABI_VERSION,
        .reserved = 0,
        .operation = case.operation_name.ptr,
        .operation_length = std.math.cast(u32, case.operation_name.len) orelse return error.MalformedCase,
        .arity = @intCast(case.arity),
        .input_fields = inputs[0..case.arity].ptr,
        .input_field_count = @intCast(case.arity),
        .result_layout = case.result_layout,
        .structure_kind = case.structure_kind,
        .result_field_count = std.math.cast(u32, case.result_fields.len) orelse
            return error.MalformedCase,
        .result_fields = case.result_fields.ptr,
    };
    // The immutable table decides whether the row exists and whether it
    // declares the layout this request claims. No hand-built signature can
    // stand in for it, and the evaluator rejects a signature the table does not
    // name for this exact request.
    const signature = c.zmath_testing_oracle_find_operation_signature(&request) orelse {
        if (tableRow(case) != null) return error.OperationLayoutMismatch;
        return error.OperationRowMissing;
    };
    var fields: [MaxFields]c.zmath_testing_oracle_result_field = @splat(.{
        .descriptor = case.result_fields[0],
        .value_bits = 0xdead_beef_dead_beef,
        .class_code = c.ZMATH_TESTING_ORACLE_CLASS_NONE,
        .reserved = 0,
    });
    var result: c.zmath_testing_oracle_result = .{
        .status = c.ZMATH_TESTING_ORACLE_ERROR,
        .reserved = 0,
        .field_capacity = @intCast(MaxFields),
        .field_count = 0,
        .fields = &fields,
    };
    zmath_testing_oracle_evaluate_algebraic(signature, &request, &result);
    return .{
        .status = result.status,
        .field_count = result.field_count,
        .fields = fields,
    };
}

fn expectNumeric(case: NumericCase) !void {
    const evaluation = try evaluateNumeric(case);
    try std.testing.expectEqual(@as(u32, c.ZMATH_TESTING_ORACLE_OK), evaluation.status);
    const expected_field_count = std.math.cast(u32, case.expected.len) orelse
        return error.MalformedCase;
    try std.testing.expectEqual(expected_field_count, evaluation.field_count);
    for (case.expected, 0..) |want, index| {
        const field = evaluation.fields[index];
        try std.testing.expectEqual(@as(u32, 0), field.reserved);
        switch (want) {
            .bits => |value| {
                try std.testing.expectEqual(value, field.value_bits);
                try std.testing.expectEqual(
                    numericFloatClass(case.result_fields[index], field.value_bits),
                    field.class_code,
                );
            },
            .quiet_nan => try std.testing.expectEqual(
                @as(u32, c.ZMATH_TESTING_ORACLE_CLASS_QNAN),
                field.class_code,
            ),
        }
    }
}

/// A request the oracle refuses as a whole, with no answer field at all. An
/// unsupported spelling and a non-finite operand both name no reference, so
/// neither may be answered with a value, and a refusal that carries no field
/// must not be answered with a field that only looks empty.
fn expectNumericUnsupported(case: NumericCase) !void {
    const evaluation = try evaluateNumeric(case);
    try std.testing.expectEqual(
        @as(u32, c.ZMATH_TESTING_ORACLE_UNSUPPORTED),
        evaluation.status,
    );
    try std.testing.expectEqual(@as(u32, 0), evaluation.field_count);
}

/// The triangle (0,0), (4,0), (0,3) in binary64, read under `tag_text`. Its
/// exact cross product is 12, so every policy that is honoured answers +1. A
/// case built here can therefore only pass by refusing, which is what makes a
/// policy spelling or a coordinate that names no reference visible instead of
/// silently answered.
fn geometryD(tag_text: []const u8) NumericCase {
    return .{
        .operation_name = "geometryOrient2",
        .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
        .inputs = &.{
            0x0000_0000_0000_0000,
            0x0000_0000_0000_0000,
            0x4010_0000_0000_0000,
            0x0000_0000_0000_0000,
            0x0000_0000_0000_0000,
            0x4008_0000_0000_0000,
            0,
        },
        .arity = 7,
        .tag_index = 6,
        .tag_text = tag_text,
        .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
        .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
        .result_fields = &sign_only,
        .expected = &.{.{ .bits = 1 }},
    };
}

/// The same triangle in binary32, read under `tag_text`.
fn geometryF(tag_text: []const u8) NumericCase {
    return .{
        .operation_name = "geometryOrient2",
        .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
        .inputs = &.{
            0x0000_0000,
            0x0000_0000,
            0x4080_0000,
            0x0000_0000,
            0x0000_0000,
            0x4040_0000,
            0,
        },
        .arity = 7,
        .tag_index = 6,
        .tag_text = tag_text,
        .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
        .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
        .result_fields = &sign_only,
        .expected = &.{.{ .bits = 1 }},
    };
}

/// One NaN in every component of a complex result: the same NaN, not two
/// unrelated ones.
fn expectSharedNaNPair(case: NumericCase) !void {
    try std.testing.expectEqual(@as(usize, 2), case.result_fields.len);
    const evaluation = try evaluateNumeric(case);
    try std.testing.expectEqual(@as(u32, c.ZMATH_TESTING_ORACLE_OK), evaluation.status);
    try std.testing.expectEqual(@as(u32, 2), evaluation.field_count);
    for (evaluation.fields[0..2]) |field| {
        try std.testing.expectEqual(@as(u32, 0), field.reserved);
        try std.testing.expectEqual(
            @as(u32, c.ZMATH_TESTING_ORACLE_CLASS_QNAN),
            field.class_code,
        );
    }
    try std.testing.expectEqual(
        evaluation.fields[0].value_bits,
        evaluation.fields[1].value_bits,
    );
}

test "complex addition keeps each component's own IEEE state" {
    const cases = [_]NumericCase{
        .{
            // +inf + -inf is invalid in the real part alone. The imaginary part
            // is the exact 3 + 4 and must still be 7.
            .operation_name = "complexAdd",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x7ff0_0000_0000_0000,
                0x4008_0000_0000_0000,
                0xfff0_0000_0000_0000,
                0x4010_0000_0000_0000,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_complex,
            .result_fields = &complex_d,
            .expected = &.{ .quiet_nan, .{ .bits = 0x401c_0000_0000_0000 } },
        },
        .{
            .operation_name = "complexAdd",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x7f80_0000,
                0x4040_0000,
                0xff80_0000,
                0x4080_0000,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_complex,
            .result_fields = &complex_f,
            .expected = &.{ .quiet_nan, .{ .bits = 0x40e0_0000 } },
        },
        .{
            // A signaling NaN in the real part is quieted there alone, and the
            // imaginary part still carries the exact 1.5 + 0.25.
            .operation_name = "complexAdd",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x7ff4_0000_0000_0001,
                0x3ff8_0000_0000_0000,
                0x4000_0000_0000_0000,
                0x3fd0_0000_0000_0000,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_complex,
            .result_fields = &complex_d,
            .expected = &.{ .quiet_nan, .{ .bits = 0x3ffc_0000_0000_0000 } },
        },
        .{
            // -0 + +0 is +0 in round to nearest, per component.
            .operation_name = "complexAdd",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x8000_0000_0000_0000,
                0x8000_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x0000_0000_0000_0000,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_complex,
            .result_fields = &complex_d,
            .expected = &.{ .{ .bits = 0x0000_0000_0000_0000 }, .{ .bits = 0x0000_0000_0000_0000 } },
        },
        .{
            // -0 + -0 keeps the negative zero, and 1 + 1 is exact.
            .operation_name = "complexAdd",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x8000_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x8000_0000_0000_0000,
                0x3ff0_0000_0000_0000,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_complex,
            .result_fields = &complex_d,
            .expected = &.{ .{ .bits = 0x8000_0000_0000_0000 }, .{ .bits = 0x4000_0000_0000_0000 } },
        },
        .{
            .operation_name = "complexAdd",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x8000_0000,
                0x8000_0000,
                0x8000_0000,
                0x8000_0000,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_complex,
            .result_fields = &complex_f,
            .expected = &.{ .{ .bits = 0x8000_0000 }, .{ .bits = 0x8000_0000 } },
        },
    };
    for (cases) |case| try expectNumeric(case);
}

test "complex multiplication rounds each product into the target format" {
    const cases = [_]NumericCase{
        .{
            // (0.5 + 1.5i)(3 + (1 + 2^-52)i). Each of the four products is
            // rounded before the sum, so the real part is 1.5 - 1.5000000000000004
            // = -2^-51. The correctly rounded exact real part is -3 * 2^-53,
            // which is a different value; only the target-bit product order
            // gives the bits below.
            .operation_name = "complexMul",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x3fe0_0000_0000_0000,
                0x3ff8_0000_0000_0000,
                0x4008_0000_0000_0000,
                0x3ff0_0000_0000_0001,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_complex,
            .result_fields = &complex_d,
            .expected = &.{
                .{ .bits = 0xbcc0_0000_0000_0000 },
                .{ .bits = 0x4014_0000_0000_0000 },
            },
        },
        .{
            // The same shape in binary32: the exact real part is -3 * 2^-26 and
            // the target-bit product order gives -2^-22 instead.
            .operation_name = "complexMul",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x3f00_0000,
                0x3fc0_0000,
                0x4040_0000,
                0x3f80_0001,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_complex,
            .result_fields = &complex_f,
            .expected = &.{ .{ .bits = 0xb480_0000 }, .{ .bits = 0x40a0_0000 } },
        },
        .{
            // No factor is zero, so both components stay infinite instead of
            // turning into the invalid NaN of an infinite times zero product.
            .operation_name = "complexMul",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x7ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x4000_0000_0000_0000,
                0x4008_0000_0000_0000,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_complex,
            .result_fields = &complex_d,
            .expected = &.{
                .{ .bits = 0x7ff0_0000_0000_0000 },
                .{ .bits = 0x7ff0_0000_0000_0000 },
            },
        },
    };
    for (cases) |case| try expectNumeric(case);
}

test "an invalid or NaN operand gives one NaN in both components" {
    const cases = [_]NumericCase{
        .{
            // The real part is the invalid inf * 0 - 1 * 2. The imaginary part
            // is a valid inf * 2 + 1 * 0, and it must not leak through as an
            // infinity beside the invalid component.
            .operation_name = "complexMul",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x7ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x4000_0000_0000_0000,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_complex,
            .result_fields = &complex_d,
            .expected = &.{ .quiet_nan, .quiet_nan },
        },
        .{
            // A signaling NaN operand wins the scan and is quieted in both
            // components, because the product has one result and not two.
            .operation_name = "complexMul",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x7ff4_0000_0000_0001,
                0x3ff0_0000_0000_0000,
                0x4000_0000_0000_0000,
                0x4008_0000_0000_0000,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_complex,
            .result_fields = &complex_d,
            .expected = &.{ .quiet_nan, .quiet_nan },
        },
        .{
            .operation_name = "complexMul",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x7f80_0000,
                0x3f80_0000,
                0x0000_0000,
                0x4000_0000,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_complex,
            .result_fields = &complex_f,
            .expected = &.{ .quiet_nan, .quiet_nan },
        },
    };
    for (cases) |case| try expectSharedNaNPair(case);
}

test "the 2x2 determinant keeps the strict product-then-subtract order" {
    const cases = [_]NumericCase{
        .{
            // (1)(1 + 3e) - (1 + e)(1 + 2e) with e = 2^-52. The exact
            // determinant is -2e^2, but the second product rounds to 1 + 3e
            // first, so the strict order gives the positive zero. Any
            // evaluation that keeps the exact determinant until the end
            // returns a negative subnormal instead.
            .operation_name = "matrixDet2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x3ff0_0000_0000_0000,
                0x3ff0_0000_0000_0001,
                0x3ff0_0000_0000_0002,
                0x3ff0_0000_0000_0003,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &scalar_d,
            .expected = &.{.{ .bits = 0x0000_0000_0000_0000 }},
        },
        .{
            // The same witness in binary32, where the exact determinant is
            // -2e^2 with e = 2^-23.
            .operation_name = "matrixDet2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x3f80_0000,
                0x3f80_0001,
                0x3f80_0002,
                0x3f80_0003,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &scalar_f,
            .expected = &.{.{ .bits = 0x0000_0000 }},
        },
        .{
            // -inf * 1 - +inf * 1 is -inf, not a NaN.
            .operation_name = "matrixDet2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0xfff0_0000_0000_0000,
                0x7ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &scalar_d,
            .expected = &.{.{ .bits = 0xfff0_0000_0000_0000 }},
        },
        .{
            // +inf * 1 - +inf * 1 is the same-sign infinity subtraction and is
            // invalid.
            .operation_name = "matrixDet2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x7ff0_0000_0000_0000,
                0x7ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &scalar_d,
            .expected = &.{.quiet_nan},
        },
        .{
            .operation_name = "matrixDet2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x7f80_0000,
                0x7f80_0000,
                0x3f80_0000,
                0x3f80_0000,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &scalar_f,
            .expected = &.{.quiet_nan},
        },
        .{
            // 2 * 4 - 3 * 1 is the exact 5.
            .operation_name = "matrixDet2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x4000_0000_0000_0000,
                0x4008_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x4010_0000_0000_0000,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &scalar_d,
            .expected = &.{.{ .bits = 0x4014_0000_0000_0000 }},
        },
        .{
            .operation_name = "matrixDet2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x4000_0000,
                0x4040_0000,
                0x3f80_0000,
                0x4080_0000,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &scalar_f,
            .expected = &.{.{ .bits = 0x40a0_0000 }},
        },
        .{
            // (1 + e)(1 + e) - 1 is 2e rounded once, with e = 2^-52.
            .operation_name = "matrixDet2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x3ff0_0000_0000_0001,
                0x3ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x3ff0_0000_0000_0001,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &scalar_d,
            .expected = &.{.{ .bits = 0x3cc0_0000_0000_0000 }},
        },
        .{
            .operation_name = "matrixDet2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x3f80_0001,
                0x3f80_0000,
                0x3f80_0000,
                0x3f80_0001,
            },
            .arity = 4,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &scalar_f,
            .expected = &.{.{ .bits = 0x3480_0000 }},
        },
    };
    for (cases) |case| try expectNumeric(case);
}

test "a pivoted 2x2 solve rounds the exact rational solution" {
    const cases = [_]NumericCase{
        .{
            // (1 2; 2 1) with right side (1, 0). Partial pivoting must swap the
            // rows, and the exact solution is (-1/3, 2/3). Unpivoted elimination
            // in binary64 keeps the pivot row and returns -0.33333333333333326
            // for x0, which is one unit in the last place away from the exact
            // rational answer rounded once.
            .operation_name = "luSolve2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x3ff0_0000_0000_0000,
                0x4000_0000_0000_0000,
                0x4000_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x0000_0000_0000_0000,
            },
            .arity = 6,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_lu_solve,
            .result_fields = &lu_solve_d,
            .expected = &.{
                .{ .bits = 0xbfd5_5555_5555_5555 },
                .{ .bits = 0x3fe5_5555_5555_5555 },
                .{ .bits = 1 },
            },
        },
        .{
            // The same system in binary32, where unpivoted elimination returns
            // -0.3333333730697632 for x0 instead of the rounded -1/3.
            .operation_name = "luSolve2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x3f80_0000,
                0x4000_0000,
                0x4000_0000,
                0x3f80_0000,
                0x3f80_0000,
                0x0000_0000,
            },
            .arity = 6,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_lu_solve,
            .result_fields = &lu_solve_f,
            .expected = &.{
                .{ .bits = 0xbeaa_aaab },
                .{ .bits = 0x3f2a_aaab },
                .{ .bits = 1 },
            },
        },
        .{
            // A system whose exact solution is representable, to keep the
            // accepted path beside the refusal case below.
            .operation_name = "luSolve2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x3ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x4000_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x4008_0000_0000_0000,
            },
            .arity = 6,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_lu_solve,
            .result_fields = &lu_solve_d,
            .expected = &.{
                .{ .bits = 0xbff0_0000_0000_0000 },
                .{ .bits = 0x4000_0000_0000_0000 },
                .{ .bits = 1 },
            },
        },
    };
    for (cases) |case| try expectNumeric(case);
}

test "a singular 2x2 system is refused with inactive components" {
    const cases = [_]NumericCase{
        .{
            // (1 2; 2 4) has the exact determinant zero, so there is no
            // solution to round. The refused result carries the inactive
            // positive zero in both components and ok = false; it must not
            // report an infinity, a NaN, or a solution from a pivot that does
            // not exist.
            .operation_name = "luSolve2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x3ff0_0000_0000_0000,
                0x4000_0000_0000_0000,
                0x4000_0000_0000_0000,
                0x4010_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x0000_0000_0000_0000,
            },
            .arity = 6,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_lu_solve,
            .result_fields = &lu_solve_d,
            .expected = &.{
                .{ .bits = 0x0000_0000_0000_0000 },
                .{ .bits = 0x0000_0000_0000_0000 },
                .{ .bits = 0 },
            },
        },
        .{
            .operation_name = "luSolve2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x3f80_0000,
                0x4000_0000,
                0x4000_0000,
                0x4080_0000,
                0x3f80_0000,
                0x0000_0000,
            },
            .arity = 6,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_lu_solve,
            .result_fields = &lu_solve_f,
            .expected = &.{
                .{ .bits = 0x0000_0000 },
                .{ .bits = 0x0000_0000 },
                .{ .bits = 0 },
            },
        },
    };
    for (cases) |case| try expectNumeric(case);
}

test "the exact orientation keeps the sign that product rounding erases" {
    // Two translated shapes, both with a positive exact cross product that the
    // plain binary64 or binary32 evaluation erases.
    //
    // The first triangle sits at 2^60, where the coordinate spacing is 256 in
    // binary64 and 2^37 in binary32. Its exact cross product is one spacing
    // squared, but the two products round onto the same double or single, so
    // the plain evaluation reports zero.
    //
    // The second triangle is three small integers at 2^53 and above. Its exact
    // cross product is exactly 1, while both x differences are halfway between
    // two binary64 neighbours and round away the odd part.
    //
    // Every coordinate is read from its stored binary64 or binary32 value, not
    // from the small integer its low hex digits suggest. One mantissa unit at
    // the 2^60 exponent is 256, so 0x43b0_0000_0000_0003 stores 2^60 + 768 and
    // not 2^60 + 3. Decoding the stored words and forming the exact
    // determinant gives 2^16 for the first pair and exactly 1 for the second;
    // those are the signs asserted below.
    const cases = [_]NumericCase{
        .{
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            // The seventh slot is the policy tag. It has no float bits to
            // carry, so it is the literal zero; the descriptor and the tag
            // text are what name the policy.
            .inputs = &.{
                0x43b0_0000_0000_0000,
                0x43b0_0000_0000_0000,
                0x43b0_0000_0000_0003,
                0x43c0_0000_0000_0000,
                0x43b0_0000_0000_0002,
                0x43ba_aaaaaaaa_aaab,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "adaptive_exact",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 1 }},
        },
        .{
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x43b0_0000_0000_0000,
                0x43b0_0000_0000_0000,
                0x43b0_0000_0000_0003,
                0x43c0_0000_0000_0000,
                0x43b0_0000_0000_0002,
                0x43ba_aaaaaaaa_aaab,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "fast",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 0 }},
        },
        .{
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x5d80_0000,
                0x5d80_0000,
                0x5d80_0003,
                0x6c00_0000,
                0x5d80_0002,
                0x6baa_aaab,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "adaptive_exact",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 1 }},
        },
        .{
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x5d80_0000,
                0x5d80_0000,
                0x5d80_0003,
                0x6c00_0000,
                0x5d80_0002,
                0x6baa_aaab,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "fast",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 0 }},
        },
        .{
            // (2^53 - 1, 0), (2^54, 1), (3 * 2^53, 2). Every coordinate is a
            // representable binary64 integer, and the exact cross product is
            // exactly 1. The two x differences are 2^53 + 1 and 2^54 + 1,
            // which are halfway between two binary64 neighbours each, so they
            // round down to 2^53 and 2^54 and the plain evaluation reports 0.
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x433f_ffff_ffff_ffff,
                0x0000_0000_0000_0000,
                0x4350_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x4358_0000_0000_0000,
                0x4000_0000_0000_0000,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "adaptive_exact",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 1 }},
        },
        .{
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x433f_ffff_ffff_ffff,
                0x0000_0000_0000_0000,
                0x4350_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x4358_0000_0000_0000,
                0x4000_0000_0000_0000,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "fast",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 0 }},
        },
        .{
            // (-floatMax, 0), (floatMax, 0), (0, 1). The exact cross product
            // is 2 * floatMax, which no binary64 can hold, so only the exact
            // policy can report a sign here. The plain evaluation overflows
            // the difference itself, so this case pins the exact policy alone
            // and says nothing about the fast answer.
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0xffef_ffff_ffff_ffff,
                0x0000_0000_0000_0000,
                0x7fef_ffff_ffff_ffff,
                0x0000_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "adaptive_exact",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 1 }},
        },
    };
    for (cases) |case| try expectNumeric(case);
}

test "both orientation policies report collinear, clockwise, and clean input" {
    const cases = [_]NumericCase{
        .{
            // (0,0), (1,1), (2,2) is collinear: the exact cross product is zero
            // and so is the plain evaluation.
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x0000_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x4000_0000_0000_0000,
                0x4000_0000_0000_0000,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "adaptive_exact",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 0 }},
        },
        .{
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x0000_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x4000_0000_0000_0000,
                0x4000_0000_0000_0000,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "fast",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 0 }},
        },
        .{
            // (0,0), (0,1), (1,0) turns clockwise: the cross product is -1.
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x0000_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x0000_0000_0000_0000,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "adaptive_exact",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 0xffff_ffff }},
        },
        .{
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x0000_0000,
                0x0000_0000,
                0x0000_0000,
                0x3f80_0000,
                0x3f80_0000,
                0x0000_0000,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "fast",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 0xffff_ffff }},
        },
        .{
            // (0,0), (4,0), (0,3) turns counter-clockwise with the exact cross
            // product 12, which both policies must report as positive.
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x0000_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x4010_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x4008_0000_0000_0000,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "adaptive_exact",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 1 }},
        },
        .{
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x0000_0000,
                0x0000_0000,
                0x4080_0000,
                0x0000_0000,
                0x0000_0000,
                0x4040_0000,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "fast",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 1 }},
        },
    };
    for (cases) |case| try expectNumeric(case);
}

test "geometry refuses a policy spelling that names no reference" {
    // The policy text says which of the two references answers the request. A
    // spelling that is neither of them, or is one of them with anything left
    // over, names no reference at all. It must be refused, not read as the
    // nearest known name and not read as an absent policy, and a refused
    // request must carry no field at all.
    const cases = [_]NumericCase{
        // A proper prefix of a real name is still not that name.
        geometryD("adaptive"),
        // No spelling at all.
        geometryD(""),
        // A real name with a trailing space, on the short name and the long one.
        geometryD("fast "),
        geometryD("adaptive_exact "),
        // A real name with a trailing NUL, which a terminated read would hide.
        geometryD("fast\x00"),
        // The same letters at another case, which no known name has.
        geometryD("Fast"),
        // The binary32 row refuses on the same grounds as the binary64 one.
        geometryF(""),
        geometryF("adaptive_exact "),
    };
    for (cases) |case| try expectNumericUnsupported(case);
}

test "geometry refuses a non-finite coordinate under both policies" {
    // The finite coordinate domain is the domain of both policies, so one
    // non-finite coordinate names no reference under either one. Every case
    // keeps the other five coordinates finite and keeps one of the two real
    // spellings, so only the coordinate can be the reason for the refusal.
    const cases = [_]NumericCase{
        .{
            // +inf in the first coordinate, exact policy.
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x7ff0_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x4010_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x4008_0000_0000_0000,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "adaptive_exact",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 1 }},
        },
        .{
            // -inf in the last coordinate, fast policy. The sign of an
            // infinity must not be read as an orientation.
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x0000_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x4010_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x0000_0000_0000_0000,
                0xfff0_0000_0000_0000,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "fast",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 1 }},
        },
        .{
            // A quiet NaN in the third coordinate. The exact determinant of a
            // NaN operand is not a number with a sign, so it is not a zero
            // orientation either.
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x0000_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x7ff8_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x4008_0000_0000_0000,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "adaptive_exact",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 1 }},
        },
        .{
            // +inf in the second coordinate in binary32, fast policy.
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x0000_0000,
                0x7f80_0000,
                0x4080_0000,
                0x0000_0000,
                0x0000_0000,
                0x4040_0000,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "fast",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 1 }},
        },
        .{
            // A quiet NaN in the fourth coordinate in binary32, exact policy.
            .operation_name = "geometryOrient2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x0000_0000,
                0x0000_0000,
                0x4080_0000,
                0x7fc0_0000,
                0x0000_0000,
                0x4040_0000,
                0,
            },
            .arity = 7,
            .tag_index = 6,
            .tag_text = "adaptive_exact",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_SCALAR,
            .structure_kind = c.ZMATH_TESTING_ORACLE_STRUCTURE_NONE,
            .result_fields = &sign_only,
            .expected = &.{.{ .bits = 1 }},
        },
    };
    for (cases) |case| try expectNumericUnsupported(case);
}

test "a solve the public growth threshold accepts is answered, not refused" {
    // The documented public threshold is 2^-21 for binary32 and 2^-50 for
    // binary64. Acceptance needs the leading column p = max(|a00|, |a10|)
    // above tau = threshold * max|A|, and |det| above p * tau.
    //
    // In both systems below the exact determinant is
    // 16 * (2^k + 16) - 2^(k+1) * 8 = 256 for k = 23 and k = 52, p is 16,
    // max|A| is 2^24 and 2^53, so tau is 8 and 256 clears 16 * 8 = 128. The
    // exact rational solution is (-2^20, 1) and (-2^49, 1); both components
    // are exact in the target format, so no rounding decides them.
    const cases = [_]NumericCase{
        .{
            .operation_name = "luSolve2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x4180_0000,
                0x4b80_0000,
                0x4100_0000,
                0x4b00_0010,
                0x0000_0000,
                0x4180_0000,
            },
            .arity = 6,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_lu_solve,
            .result_fields = &lu_solve_f,
            .expected = &.{
                .{ .bits = 0xc980_0000 },
                .{ .bits = 0x3f80_0000 },
                .{ .bits = 1 },
            },
        },
        .{
            .operation_name = "luSolve2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x4030_0000_0000_0000,
                0x4340_0000_0000_0000,
                0x4020_0000_0000_0000,
                0x4330_0000_0000_0010,
                0x0000_0000_0000_0000,
                0x4030_0000_0000_0000,
            },
            .arity = 6,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_lu_solve,
            .result_fields = &lu_solve_d,
            .expected = &.{
                .{ .bits = 0xc300_0000_0000_0000 },
                .{ .bits = 0x3ff0_0000_0000_0000 },
                .{ .bits = 1 },
            },
        },
    };
    for (cases) |case| try expectNumeric(case);
}

test "a diagonal system below the public threshold is refused" {
    // The exact solution of each system below is (1, 1), so the refusal is
    // about conditioning and not about a solution that does not exist. The
    // leading column p is 1 and max|A| is 1, so tau is 2^-21 for binary32 and
    // 2^-50 for binary64, and |det| is one halving short of p * tau.
    //
    // A diagonal entry of 2^-23 for binary32 or 2^-52 for binary64 would put
    // |det| exactly at the unit roundoff times the growth bound of a two-by-two
    // reduction, which that criterion already refuses on equality. These
    // entries sit strictly between that bound and the public threshold, so
    // only the public threshold decides them.
    const cases = [_]NumericCase{
        .{
            .operation_name = "luSolve2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x3f80_0000,
                0x0000_0000,
                0x0000_0000,
                0x3480_0000,
                0x3f80_0000,
                0x3480_0000,
            },
            .arity = 6,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_lu_solve,
            .result_fields = &lu_solve_f,
            .expected = &.{
                .{ .bits = 0x0000_0000 },
                .{ .bits = 0x0000_0000 },
                .{ .bits = 0 },
            },
        },
        .{
            .operation_name = "luSolve2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x3ff0_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x3cc0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x3cc0_0000_0000_0000,
            },
            .arity = 6,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_lu_solve,
            .result_fields = &lu_solve_d,
            .expected = &.{
                .{ .bits = 0x0000_0000_0000_0000 },
                .{ .bits = 0x0000_0000_0000_0000 },
                .{ .bits = 0 },
            },
        },
    };
    for (cases) |case| try expectNumeric(case);
}

test "a finite solve that leaves the range reports the infinities" {
    // Both stored pivots here are finite and nonzero, so the matrix is solved.
    // The exact determinant is 1/4, and the exact rational solution is
    // (-floatMax / (1/4), (floatMax / 2) / (1/4)), which is
    // (-4 * floatMax, 2 * floatMax). Both components are past the range of the
    // format, so the answer is the pair of IEEE infinities with their own
    // signs and ok stays true: a solution that leaves the range is the
    // arithmetic result, not a refusal, and refusing it would hide the two
    // different signs behind one inactive pair.
    const cases = [_]NumericCase{
        .{
            .operation_name = "luSolve2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x3f00_0000,
                0x3f80_0000,
                0x0000_0000,
                0x3f00_0000,
                0x0000_0000,
                0x7f7f_ffff,
            },
            .arity = 6,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_lu_solve,
            .result_fields = &lu_solve_f,
            .expected = &.{
                .{ .bits = 0xff80_0000 },
                .{ .bits = 0x7f80_0000 },
                .{ .bits = 1 },
            },
        },
        .{
            .operation_name = "luSolve2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x3fe0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x3fe0_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x7fef_ffff_ffff_ffff,
            },
            .arity = 6,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_lu_solve,
            .result_fields = &lu_solve_d,
            .expected = &.{
                .{ .bits = 0xfff0_0000_0000_0000 },
                .{ .bits = 0x7ff0_0000_0000_0000 },
                .{ .bits = 1 },
            },
        },
    };
    for (cases) |case| try expectNumeric(case);
}

test "a factor that overflows the format is refused" {
    // The leading entry is L in all four corners, so the elimination multiplier
    // is exactly 1 and the trailing pivot is a11 - 1 * a01 = -2L. With
    // L = 2^127 in binary32 that is -2^128, and with L = 2^1023 in binary64 it
    // is -2^1024; both are past the largest finite value of their format. The
    // stored pivot is then an infinity, and there is no finite pivot to divide
    // by.
    //
    // The exact rational solution is (1/L, 0), and 2^-127 and 2^-1023 are both
    // representable in their format, so the refusal is about the factor and not
    // about the answer being unrepresentable.
    const cases = [_]NumericCase{
        .{
            .operation_name = "luSolve2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x7f00_0000,
                0x7f00_0000,
                0x7f00_0000,
                0xff00_0000,
                0x3f80_0000,
                0x3f80_0000,
            },
            .arity = 6,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_lu_solve,
            .result_fields = &lu_solve_f,
            .expected = &.{
                .{ .bits = 0x0000_0000 },
                .{ .bits = 0x0000_0000 },
                .{ .bits = 0 },
            },
        },
        .{
            .operation_name = "luSolve2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x7fe0_0000_0000_0000,
                0x7fe0_0000_0000_0000,
                0x7fe0_0000_0000_0000,
                0xffe0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
            },
            .arity = 6,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_lu_solve,
            .result_fields = &lu_solve_d,
            .expected = &.{
                .{ .bits = 0x0000_0000_0000_0000 },
                .{ .bits = 0x0000_0000_0000_0000 },
                .{ .bits = 0 },
            },
        },
    };
    for (cases) |case| try expectNumeric(case);
}

test "a non-finite matrix entry is refused with inactive components" {
    // A matrix entry outside the finite domain has no finite scale to weigh
    // against the public threshold and no finite pivot to factor from, so the
    // solve is refused. That refusal is a result, not a missing reference: it
    // carries the canonical positive zero in both components, which is not a
    // number the arithmetic could have produced, and ok = false.
    const cases = [_]NumericCase{
        .{
            .operation_name = "luSolve2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x7f80_0000,
                0x3f80_0000,
                0x0000_0000,
                0x3f80_0000,
                0x3f80_0000,
                0x3f80_0000,
            },
            .arity = 6,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_lu_solve,
            .result_fields = &lu_solve_f,
            .expected = &.{
                .{ .bits = 0x0000_0000 },
                .{ .bits = 0x0000_0000 },
                .{ .bits = 0 },
            },
        },
        .{
            .operation_name = "luSolve2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x3ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x7ff8_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
            },
            .arity = 6,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_lu_solve,
            .result_fields = &lu_solve_d,
            .expected = &.{
                .{ .bits = 0x0000_0000_0000_0000 },
                .{ .bits = 0x0000_0000_0000_0000 },
                .{ .bits = 0 },
            },
        },
    };
    for (cases) |case| try expectNumeric(case);
}

test "a non-finite right-hand side names no reference at all" {
    // The right-hand side is a different domain from the matrix. It does not
    // decide whether the matrix can be factored, so it cannot be answered with
    // the inactive pair a factor refusal carries: that pair would report a
    // decision about the matrix that the matrix itself never got a chance to
    // make. There is no reference for a non-finite right-hand side, so the
    // request is unsupported and carries no field at all.
    const cases = [_]NumericCase{
        .{
            // +inf in the first right-hand-side component.
            .operation_name = "luSolve2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .inputs = &.{
                0x3f80_0000,
                0x0000_0000,
                0x0000_0000,
                0x3f80_0000,
                0x7f80_0000,
                0x3f80_0000,
            },
            .arity = 6,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_lu_solve,
            .result_fields = &lu_solve_f,
            .expected = &.{ .{ .bits = 0 }, .{ .bits = 0 }, .{ .bits = 0 } },
        },
        .{
            // A quiet NaN in the second right-hand-side component.
            .operation_name = "luSolve2",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .inputs = &.{
                0x3ff0_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x0000_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x3ff0_0000_0000_0000,
                0x7ff8_0000_0000_0000,
            },
            .arity = 6,
            .tag_index = null,
            .tag_text = "",
            .result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE,
            .structure_kind = layout_lu_solve,
            .result_fields = &lu_solve_d,
            .expected = &.{ .{ .bits = 0 }, .{ .bits = 0 }, .{ .bits = 0 } },
        },
    };
    for (cases) |case| try expectNumericUnsupported(case);
}
