const std = @import("std");
const c = @cImport({
    @cInclude("oracle_evaluators.h");
});

extern fn zmath_testing_oracle_evaluate_exact_bits(
    signature: *const c.zmath_testing_oracle_operation_signature,
    request: *const c.zmath_testing_oracle_request,
    result: *c.zmath_testing_oracle_result,
) void;

const max_fields: usize = c.ZMATH_TESTING_ORACLE_MAX_FIELDS;

const Evaluation = struct {
    inputs: [max_fields]c.zmath_testing_oracle_input_field = undefined,
    outputs: [max_fields]c.zmath_testing_oracle_result_field = undefined,
    request: c.zmath_testing_oracle_request = undefined,
    result: c.zmath_testing_oracle_result = undefined,

    fn run(
        self: *Evaluation,
        signature: *const c.zmath_testing_oracle_operation_signature,
        values: []const u64,
        tag: []const u8,
    ) void {
        std.debug.assert(values.len == signature.arity);
        std.debug.assert(signature.arity <= max_fields);
        std.debug.assert(signature.result_field_count <= max_fields);
        std.debug.assert(signature.arguments != null);
        std.debug.assert(signature.result_fields != null);

        for (0..signature.arity) |index| {
            const descriptor = signature.arguments[index];
            const is_tag = descriptor.kind == c.ZMATH_TESTING_ORACLE_FIELD_TAG;
            self.inputs[index] = .{
                .descriptor = descriptor,
                .value_bits = values[index],
                .tag_bytes = if (is_tag and tag.len != 0) tag.ptr else null,
                .tag_length = if (is_tag) @intCast(tag.len) else 0,
                .reserved = 0,
            };
        }
        for (0..signature.result_field_count) |index| {
            self.outputs[index] = .{
                .descriptor = signature.result_fields[index],
                .value_bits = 0xdead_beef_dead_beef,
                .class_code = c.ZMATH_TESTING_ORACLE_CLASS_NONE,
                .reserved = 0,
            };
        }

        self.request = .{
            .abi_version = c.ZMATH_TESTING_ORACLE_ABI_VERSION,
            .reserved = 0,
            .operation = @ptrCast(signature.operation),
            .operation_length = signature.operation_length,
            .arity = signature.arity,
            .input_fields = @ptrCast(&self.inputs),
            .input_field_count = signature.arity,
            .result_layout = signature.result_layout,
            .structure_kind = signature.structure_kind,
            .result_field_count = signature.result_field_count,
            .result_fields = signature.result_fields,
        };
        self.result = .{
            .status = c.ZMATH_TESTING_ORACLE_ERROR,
            .reserved = 0,
            .field_capacity = @intCast(max_fields),
            .field_count = 0,
            .fields = @ptrCast(&self.outputs),
        };
        zmath_testing_oracle_evaluate_exact_bits(signature, &self.request, &self.result);
    }
};

fn operationSlice(signature: *const c.zmath_testing_oracle_operation_signature) []const u8 {
    std.debug.assert(signature.operation != null);
    const pointer: [*]const u8 = @ptrCast(signature.operation);
    return pointer[0..@intCast(signature.operation_length)];
}

fn signatureFormat(signature: *const c.zmath_testing_oracle_operation_signature) ?u32 {
    std.debug.assert(signature.arguments != null);
    std.debug.assert(signature.result_fields != null);
    for (0..signature.arity) |index| {
        const descriptor = signature.arguments[index];
        if (descriptor.kind == c.ZMATH_TESTING_ORACLE_FIELD_FLOAT) return descriptor.format.code;
    }
    for (0..signature.result_field_count) |index| {
        const descriptor = signature.result_fields[index];
        if (descriptor.kind == c.ZMATH_TESTING_ORACLE_FIELD_FLOAT) return descriptor.format.code;
    }
    return null;
}

fn findSignature(operation: []const u8, format_code: u32) *const c.zmath_testing_oracle_operation_signature {
    for (&c.zmath_testing_oracle_operation_table) |*signature| {
        if (signature.evaluator_category != c.ZMATH_TESTING_ORACLE_EVALUATOR_EXACT_BITS) continue;
        if (!std.mem.eql(u8, operation, operationSlice(signature))) continue;
        if (signatureFormat(signature)) |code| {
            if (code == format_code) return signature;
        }
    }
    unreachable;
}

fn expectDescriptorEqual(
    expected: c.zmath_testing_oracle_field_descriptor,
    actual: c.zmath_testing_oracle_field_descriptor,
) !void {
    try std.testing.expectEqual(expected.kind, actual.kind);
    try std.testing.expectEqual(expected.value_bits, actual.value_bits);
    try std.testing.expectEqual(expected.format.code, actual.format.code);
    try std.testing.expectEqual(expected.format.storage_bits, actual.format.storage_bits);
    try std.testing.expectEqual(expected.format.exponent_bits, actual.format.exponent_bits);
    try std.testing.expectEqual(expected.format.fraction_bits, actual.format.fraction_bits);
    try std.testing.expectEqual(expected.format.reserved, actual.format.reserved);
    try std.testing.expectEqual(expected.reserved, actual.reserved);
}

fn expectedFloatClass(descriptor: c.zmath_testing_oracle_field_descriptor, bits: u64) u32 {
    const fraction_bits = descriptor.format.fraction_bits;
    const exponent_bits = descriptor.format.exponent_bits;
    const fraction_mask = (@as(u64, 1) << @intCast(fraction_bits)) - 1;
    const exponent_mask = (@as(u64, 1) << @intCast(exponent_bits)) - 1;
    const exponent = (bits >> @intCast(fraction_bits)) & exponent_mask;
    const fraction = bits & fraction_mask;
    if (exponent == 0) {
        return if (fraction == 0) c.ZMATH_TESTING_ORACLE_CLASS_ZERO else c.ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL;
    }
    if (exponent != exponent_mask) return c.ZMATH_TESTING_ORACLE_CLASS_NORMAL;
    return if (fraction == 0) c.ZMATH_TESTING_ORACLE_CLASS_INFINITY else c.ZMATH_TESTING_ORACLE_CLASS_QNAN;
}

fn expectSuccessfulShape(
    signature: *const c.zmath_testing_oracle_operation_signature,
    evaluation: *const Evaluation,
) !void {
    try std.testing.expectEqual(c.ZMATH_TESTING_ORACLE_OK, evaluation.result.status);
    try std.testing.expectEqual(signature.result_field_count, evaluation.result.field_count);
    for (0..signature.result_field_count) |index| {
        const descriptor = signature.result_fields[index];
        const field = evaluation.outputs[index];
        try expectDescriptorEqual(descriptor, field.descriptor);
        try std.testing.expectEqual(@as(u32, 0), field.reserved);
        if (descriptor.kind == c.ZMATH_TESTING_ORACLE_FIELD_FLOAT) {
            try std.testing.expectEqual(expectedFloatClass(descriptor, field.value_bits), field.class_code);
        } else {
            try std.testing.expectEqual(c.ZMATH_TESTING_ORACLE_CLASS_NONE, field.class_code);
        }
    }
}

fn runOperation(
    operation: []const u8,
    format_code: u32,
    values: []const u64,
    tag: []const u8,
    evaluation: *Evaluation,
) *const c.zmath_testing_oracle_operation_signature {
    const signature = findSignature(operation, format_code);
    evaluation.run(signature, values, tag);
    return signature;
}

fn expectScalarBits(
    operation: []const u8,
    format_code: u32,
    values: []const u64,
    tag: []const u8,
    expected_bits: u64,
) !void {
    var evaluation: Evaluation = .{};
    const signature = runOperation(operation, format_code, values, tag, &evaluation);
    try expectSuccessfulShape(signature, &evaluation);
    try std.testing.expectEqual(expected_bits, evaluation.outputs[0].value_bits);
}

test "every exact-bit table row has an evaluator branch" {
    var exact_count: u32 = 0;
    for (&c.zmath_testing_oracle_operation_table) |*signature| {
        if (signature.evaluator_category != c.ZMATH_TESTING_ORACLE_EVALUATOR_EXACT_BITS) continue;
        exact_count += 1;
        var values = [_]u64{0} ** max_fields;
        for (0..signature.arity) |index| {
            const descriptor = signature.arguments[index];
            if (descriptor.kind == c.ZMATH_TESTING_ORACLE_FIELD_UNSIGNED_INTEGER) values[index] = 8;
        }
        var evaluation: Evaluation = .{};
        evaluation.run(signature, values[0..signature.arity], "1");
        try std.testing.expect(evaluation.result.status != c.ZMATH_TESTING_ORACLE_UNSUPPORTED);
        try expectSuccessfulShape(signature, &evaluation);
    }
    try std.testing.expectEqual(@as(u32, 150), exact_count);
}

test "rounding, conversion, scaling, remainder, and decomposition" {
    try expectScalarBits("roundeven", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{0x4100}, "", 0x4000);
    try expectScalarBits("round", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{0x4100}, "", 0x4200);
    try expectScalarBits("ceil", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{0xb400}, "", 0x8000);
    try expectScalarBits("floor", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{0x3400}, "", 0x0000);
    try expectScalarBits("fromfp", c.ZMATH_TESTING_ORACLE_FORMAT_F, &.{ 0x3fc0_0000, 0, 8 }, "", 0x4000_0000);
    try expectScalarBits("fromfp", c.ZMATH_TESTING_ORACLE_FORMAT_F, &.{ 0x3fc0_0000, 2, 8 }, "", 0x3f80_0000);
    try expectScalarBits("scalbn", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{ 0x0400, 0xffff_ffff }, "", 0x0200);
    try expectScalarBits("fmod", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{ 0x4580, 0x4000 }, "", 0x3e00);
    try expectScalarBits("remainder", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{ 0x4580, 0x4000 }, "", 0xb800);
    try expectScalarBits("remainder", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{ 0xfc00, 0x4000 }, "", 0x7e00);

    var evaluation: Evaluation = .{};
    var signature = runOperation("frexp", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{0x0001}, "", &evaluation);
    try expectSuccessfulShape(signature, &evaluation);
    try std.testing.expectEqual(@as(u64, 0x3800), evaluation.outputs[0].value_bits);
    try std.testing.expectEqual(@as(u64, 0xffff_ffe9), evaluation.outputs[1].value_bits);

    signature = runOperation("modf", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{0x3e00}, "", &evaluation);
    try expectSuccessfulShape(signature, &evaluation);
    try std.testing.expectEqual(@as(u64, 0x3800), evaluation.outputs[0].value_bits);
    try std.testing.expectEqual(@as(u64, 0x3c00), evaluation.outputs[1].value_bits);
    try expectScalarBits("ilogb", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{0x0000}, "", 0x8000_0000);
    try expectScalarBits("llogb", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{0x7c00}, "", 0x7fff_ffff_ffff_ffff);
}

test "extrema use deterministic NaN and signed-zero policy" {
    try expectScalarBits("fmax", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{ 0x7c01, 0x3c00 }, "", 0x3c00);
    try expectScalarBits("fmaximum", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{ 0x7c01, 0x3c00 }, "", 0x7e01);
    try expectScalarBits("fminimum", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{ 0x0000, 0x8000 }, "", 0x8000);
    try expectScalarBits("fmaximum_mag", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{ 0xc000, 0x4000 }, "", 0x4000);
    try expectScalarBits("fminimum_mag", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{ 0xc000, 0x4000 }, "", 0xc000);
    try expectScalarBits("fmaximum_mag_num", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{ 0x7e44, 0x4000 }, "", 0x4000);
}

test "C23 IEEE and Annex-F operations fill all fields and classes" {
    var evaluation: Evaluation = .{};
    var signature = runOperation("canonicalize", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{0xfc01}, "", &evaluation);
    try expectSuccessfulShape(signature, &evaluation);
    try std.testing.expectEqual(@as(u64, 0xfe01), evaluation.outputs[0].value_bits);
    try std.testing.expectEqual(@as(u64, 1), evaluation.outputs[1].value_bits);
    try expectScalarBits("copySign", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{ 0x7c01, 0x8000 }, "", 0xfc01);
    try expectScalarBits("nan", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{0}, "1ff", 0x7fff);
    try expectScalarBits("nan", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{0}, "0x1", 0x7e00);
    try expectScalarBits("nextAfter", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{ 0x8000, 0x3c00 }, "", 0x0001);
    try expectScalarBits("nextUp", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{0x8000}, "", 0x0001);
    try expectScalarBits("nextDown", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{0x0000}, "", 0x8001);
    try expectScalarBits("nextToward", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{ 0x0000, 0x8000_0000_0000_0000 }, "", 0x8000);

    signature = runOperation("getPayload", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{0x7e03}, "", &evaluation);
    try expectSuccessfulShape(signature, &evaluation);
    try std.testing.expectEqual(@as(u64, 0x4200), evaluation.outputs[0].value_bits);
    signature = runOperation("setPayload", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{0x4200}, "", &evaluation);
    try expectSuccessfulShape(signature, &evaluation);
    try std.testing.expectEqual(@as(u64, 0x7e03), evaluation.outputs[0].value_bits);
    try std.testing.expectEqual(@as(u64, 1), evaluation.outputs[1].value_bits);
    signature = runOperation("setPayloadSig", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{0x8000}, "", &evaluation);
    try expectSuccessfulShape(signature, &evaluation);
    try std.testing.expectEqual(@as(u64, 0), evaluation.outputs[0].value_bits);
    try std.testing.expectEqual(@as(u64, 0), evaluation.outputs[1].value_bits);
    try expectScalarBits("totalOrder", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{ 0x8000, 0x0000 }, "", 1);
    try expectScalarBits("totalOrder", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{ 0x0000, 0x8000 }, "", 0);
    try expectScalarBits("totalOrderMag", c.ZMATH_TESTING_ORACLE_FORMAT_H, &.{ 0xc000, 0x4000 }, "", 1);
}
