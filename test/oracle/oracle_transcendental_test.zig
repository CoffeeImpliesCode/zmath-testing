const std = @import("std");
const c = @cImport({
    @cInclude("oracle_evaluators.h");
});

extern fn zmath_testing_oracle_evaluate_mpfr_arb(
    signature: *const c.zmath_testing_oracle_operation_signature,
    request: *const c.zmath_testing_oracle_request,
    result: *c.zmath_testing_oracle_result,
) callconv(.c) void;

fn operation(signature: *const c.zmath_testing_oracle_operation_signature) []const u8 {
    const bytes: [*]const u8 = @ptrCast(signature.operation);
    return bytes[0..@intCast(signature.operation_length)];
}

fn inputPointer(values: []const c.zmath_testing_oracle_input_field) [*c]const c.zmath_testing_oracle_input_field {
    return if (values.len == 0) null else values.ptr;
}

fn resultPointer(values: []c.zmath_testing_oracle_result_field) [*c]c.zmath_testing_oracle_result_field {
    return if (values.len == 0) null else values.ptr;
}

fn inputField(descriptor: c.zmath_testing_oracle_field_descriptor, bits: u64) c.zmath_testing_oracle_input_field {
    return .{
        .descriptor = descriptor,
        .value_bits = bits,
        .tag_bytes = null,
        .tag_length = 0,
        .reserved = 0,
    };
}

fn encodedSigned(value: i64, width: u32) u64 {
    if (width == 64) return @bitCast(value);
    const mask = (@as(u64, 1) << @intCast(width)) - 1;
    return @as(u64, @bitCast(value)) & mask;
}

fn floatBits(format_code: u32, h: u16, f: u32, d: u64) u64 {
    if (format_code == c.ZMATH_TESTING_ORACLE_FORMAT_H) return h;
    if (format_code == c.ZMATH_TESTING_ORACLE_FORMAT_F) return f;
    std.debug.assert(format_code == c.ZMATH_TESTING_ORACLE_FORMAT_D);
    return d;
}

fn quarterBits(format_code: u32) u64 {
    return floatBits(format_code, 0x3400, 0x3e80_0000, 0x3fd0_0000_0000_0000);
}

fn halfBits(format_code: u32) u64 {
    return floatBits(format_code, 0x3800, 0x3f00_0000, 0x3fe0_0000_0000_0000);
}

fn threeQuarterBits(format_code: u32) u64 {
    return floatBits(format_code, 0x3a00, 0x3f40_0000, 0x3fe8_0000_0000_0000);
}

fn oneAndHalfBits(format_code: u32) u64 {
    return floatBits(format_code, 0x3e00, 0x3fc0_0000, 0x3ff8_0000_0000_0000);
}

fn twoBits(format_code: u32) u64 {
    return floatBits(format_code, 0x4000, 0x4000_0000, 0x4000_0000_0000_0000);
}

fn twoAndHalfBits(format_code: u32) u64 {
    return floatBits(format_code, 0x4100, 0x4020_0000, 0x4004_0000_0000_0000);
}

fn eightBits(format_code: u32) u64 {
    return floatBits(format_code, 0x4800, 0x4100_0000, 0x4020_0000_0000_0000);
}

fn canonicalNaNBits(format_code: u32) u64 {
    return floatBits(format_code, 0x7e00, 0x7fc0_0000, 0x7ff8_0000_0000_0000);
}

fn buildInputs(
    signature: *const c.zmath_testing_oracle_operation_signature,
    fields: *[2]c.zmath_testing_oracle_input_field,
) []const c.zmath_testing_oracle_input_field {
    const op = operation(signature);
    const format_code = signature.arguments[0].format.code;
    var first = quarterBits(format_code);
    var second: u64 = 0;

    if (std.mem.eql(u8, op, "acosh") or std.mem.eql(u8, op, "log") or
        std.mem.eql(u8, op, "log2") or std.mem.eql(u8, op, "log10"))
    {
        first = twoBits(format_code);
    } else if (std.mem.eql(u8, op, "lgamma") or std.mem.eql(u8, op, "tgamma")) {
        first = twoAndHalfBits(format_code);
    } else if (std.mem.eql(u8, op, "atan2") or std.mem.eql(u8, op, "atan2pi")) {
        first = halfBits(format_code);
        second = threeQuarterBits(format_code);
    } else if (std.mem.eql(u8, op, "pow") or std.mem.eql(u8, op, "powr")) {
        first = oneAndHalfBits(format_code);
        second = halfBits(format_code);
    } else if (std.mem.eql(u8, op, "pown")) {
        first = oneAndHalfBits(format_code);
        second = encodedSigned(3, 64);
    } else if (std.mem.eql(u8, op, "compoundn")) {
        first = halfBits(format_code);
        second = encodedSigned(3, 64);
    } else if (std.mem.eql(u8, op, "rootn")) {
        first = eightBits(format_code);
        second = encodedSigned(3, 64);
    }

    fields[0] = inputField(signature.arguments[0], first);
    if (signature.arity == 1) return fields[0..1];
    fields[1] = inputField(signature.arguments[1], second);
    return fields[0..2];
}

fn evaluate(
    signature: *const c.zmath_testing_oracle_operation_signature,
    inputs: []const c.zmath_testing_oracle_input_field,
    fields: []c.zmath_testing_oracle_result_field,
) c.zmath_testing_oracle_result {
    const request: c.zmath_testing_oracle_request = .{
        .abi_version = c.ZMATH_TESTING_ORACLE_ABI_VERSION,
        .reserved = 0,
        .operation = @ptrCast(signature.operation),
        .operation_length = signature.operation_length,
        .arity = signature.arity,
        .input_fields = inputPointer(inputs),
        .input_field_count = @intCast(inputs.len),
        .result_layout = signature.result_layout,
        .structure_kind = signature.structure_kind,
        .result_field_count = signature.result_field_count,
        .result_fields = signature.result_fields,
    };
    var result: c.zmath_testing_oracle_result = .{
        .status = c.ZMATH_TESTING_ORACLE_ERROR,
        .reserved = 0,
        .field_capacity = @intCast(fields.len),
        .field_count = 0,
        .fields = resultPointer(fields),
    };
    zmath_testing_oracle_evaluate_mpfr_arb(signature, &request, &result);
    return result;
}

fn expectDescriptors(
    signature: *const c.zmath_testing_oracle_operation_signature,
    fields: []const c.zmath_testing_oracle_result_field,
) !void {
    for (fields, 0..) |field, index| {
        try std.testing.expectEqualDeep(signature.result_fields[index], field.descriptor);
        try std.testing.expectEqual(@as(u32, 0), field.reserved);
        if (field.descriptor.kind == c.ZMATH_TESTING_ORACLE_FIELD_FLOAT) {
            try std.testing.expect(field.class_code != c.ZMATH_TESTING_ORACLE_CLASS_NONE);
        } else {
            try std.testing.expectEqual(c.ZMATH_TESTING_ORACLE_CLASS_NONE, field.class_code);
        }
    }
}

test "all 126 MPFR Arb signatures have a direct route" {
    var row_count: u32 = 0;
    for (&c.zmath_testing_oracle_operation_table) |*signature| {
        if (signature.evaluator_category != c.ZMATH_TESTING_ORACLE_EVALUATOR_MPFR_ARB) continue;
        row_count += 1;

        var input_storage: [2]c.zmath_testing_oracle_input_field = undefined;
        const inputs = buildInputs(signature, &input_storage);
        var fields: [2]c.zmath_testing_oracle_result_field = undefined;
        const field_count: usize = @intCast(signature.result_field_count);
        const result = evaluate(signature, inputs, fields[0..field_count]);

        try std.testing.expect(
            result.status == c.ZMATH_TESTING_ORACLE_OK or
                result.status == c.ZMATH_TESTING_ORACLE_UNCERTAIN,
        );
        if (result.status == c.ZMATH_TESTING_ORACLE_UNCERTAIN) {
            try std.testing.expectEqual(@as(u32, 0), result.field_count);
            continue;
        }
        try std.testing.expectEqual(signature.result_field_count, result.field_count);
        try expectDescriptors(signature, fields[0..field_count]);
        if (signature.structure_kind == c.ZMATH_TESTING_ORACLE_STRUCTURE_ATAN2 or
            signature.structure_kind == c.ZMATH_TESTING_ORACLE_STRUCTURE_POWER)
        {
            try std.testing.expectEqual(@as(u64, 1), fields[1].value_bits);
        }
        if (signature.structure_kind == c.ZMATH_TESTING_ORACLE_STRUCTURE_LGAMMA) {
            try std.testing.expectEqual(@as(u64, 1), fields[1].value_bits);
        }
    }
    try std.testing.expectEqual(@as(u32, 126), row_count);
}

test "bounded power status is exact before numerical evaluation" {
    for (&c.zmath_testing_oracle_operation_table) |*signature| {
        const op = operation(signature);
        if (signature.evaluator_category != c.ZMATH_TESTING_ORACLE_EVALUATOR_MPFR_ARB or
            !(std.mem.eql(u8, op, "pown") or std.mem.eql(u8, op, "compoundn") or
                std.mem.eql(u8, op, "rootn")))
        {
            continue;
        }

        const format_code = signature.arguments[0].format.code;
        const inputs = [_]c.zmath_testing_oracle_input_field{
            inputField(signature.arguments[0], canonicalNaNBits(format_code)),
            inputField(signature.arguments[1], encodedSigned(65, 64)),
        };
        var fields: [2]c.zmath_testing_oracle_result_field = undefined;
        const result = evaluate(signature, &inputs, &fields);

        try std.testing.expectEqual(c.ZMATH_TESTING_ORACLE_OK, result.status);
        try std.testing.expectEqual(@as(u32, 2), result.field_count);
        try std.testing.expectEqual(canonicalNaNBits(format_code), fields[0].value_bits);
        try std.testing.expectEqual(c.ZMATH_TESTING_ORACLE_CLASS_QNAN, fields[0].class_code);
        try std.testing.expectEqual(@as(u64, 0), fields[1].value_bits);
    }
}

test "lgamma signed-zero pole policy is exact" {
    for (&c.zmath_testing_oracle_operation_table) |*signature| {
        if (!std.mem.eql(u8, operation(signature), "lgamma")) continue;
        const format_code = signature.arguments[0].format.code;
        const negative_zero = floatBits(
            format_code,
            0x8000,
            0x8000_0000,
            0x8000_0000_0000_0000,
        );
        const positive_infinity = floatBits(
            format_code,
            0x7c00,
            0x7f80_0000,
            0x7ff0_0000_0000_0000,
        );
        const inputs = [_]c.zmath_testing_oracle_input_field{
            inputField(signature.arguments[0], negative_zero),
        };
        var fields: [2]c.zmath_testing_oracle_result_field = undefined;
        const result = evaluate(signature, &inputs, &fields);

        try std.testing.expectEqual(c.ZMATH_TESTING_ORACLE_OK, result.status);
        try std.testing.expectEqual(positive_infinity, fields[0].value_bits);
        try std.testing.expectEqual(c.ZMATH_TESTING_ORACLE_CLASS_INFINITY, fields[0].class_code);
        try std.testing.expectEqual(@as(u64, 3), fields[1].value_bits);
    }
}
