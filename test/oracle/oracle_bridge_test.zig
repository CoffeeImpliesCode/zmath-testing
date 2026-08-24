const std = @import("std");
const corpus = @import("corpus_support");

const OracleClass = corpus.OracleClass;
const OracleFieldDescriptor = corpus.OracleFieldDescriptor;
const OracleFormat = corpus.OracleFormat;
const OracleFormatDescriptor = corpus.OracleFormatDescriptor;
const OracleInputField = corpus.OracleInputField;
const OracleRequest = corpus.OracleRequest;
const OracleResult = corpus.OracleResult;
const OracleResultField = corpus.OracleResultField;
const OracleStatus = corpus.OracleStatus;

const format_none: OracleFormatDescriptor = .{
    .code = .none,
    .storage_bits = 0,
    .exponent_bits = 0,
    .fraction_bits = 0,
    .reserved = 0,
};
const format_h: OracleFormatDescriptor = .{
    .code = .h,
    .storage_bits = 16,
    .exponent_bits = 5,
    .fraction_bits = 10,
    .reserved = 0,
};
const format_f: OracleFormatDescriptor = .{
    .code = .f,
    .storage_bits = 32,
    .exponent_bits = 8,
    .fraction_bits = 23,
    .reserved = 0,
};
const format_d: OracleFormatDescriptor = .{
    .code = .d,
    .storage_bits = 64,
    .exponent_bits = 11,
    .fraction_bits = 52,
    .reserved = 0,
};
const format_reserved: OracleFormatDescriptor = .{
    .code = @enumFromInt(4),
    .storage_bits = 128,
    .exponent_bits = 15,
    .fraction_bits = 112,
    .reserved = 0,
};

fn floatDescriptor(format: OracleFormatDescriptor) OracleFieldDescriptor {
    return .{
        .kind = .float,
        .value_bits = format.storage_bits,
        .format = format,
        .reserved = 0,
    };
}

fn signedDescriptor(value_bits: u32) OracleFieldDescriptor {
    return .{
        .kind = .signed_integer,
        .value_bits = value_bits,
        .format = format_none,
        .reserved = 0,
    };
}

fn unsignedDescriptor(value_bits: u32) OracleFieldDescriptor {
    return .{
        .kind = .unsigned_integer,
        .value_bits = value_bits,
        .format = format_none,
        .reserved = 0,
    };
}

fn booleanDescriptor() OracleFieldDescriptor {
    return .{
        .kind = .boolean,
        .value_bits = 1,
        .format = format_none,
        .reserved = 0,
    };
}
fn tagInput(tag_bytes: []const u8) OracleInputField {
    return corpus.oracleTagInput(tag_bytes) catch unreachable;
}

fn roundingInput(value_bits: u64) OracleInputField {
    return .{
        .descriptor = .{
            .kind = .rounding,
            .value_bits = 32,
            .format = format_none,
            .reserved = 0,
        },
        .value_bits = value_bits,
        .tag_bytes = null,
        .tag_length = 0,
        .reserved = 0,
    };
}

fn floatInput(format: OracleFormatDescriptor, value_bits: u64) OracleInputField {
    return corpus.oracleInputField(floatDescriptor(format), value_bits);
}

fn signedInput(value_bits: u32, value: i64) OracleInputField {
    const encoded = corpus.encodeSignedInteger(value, value_bits) catch unreachable;
    return corpus.oracleInputField(signedDescriptor(value_bits), encoded);
}

fn scalarRequest(
    operation: []const u8,
    input_fields: []const OracleInputField,
    result_fields: []const OracleFieldDescriptor,
) OracleRequest {
    return .{
        .abi_version = corpus.oracle_abi_version,
        .reserved = 0,
        .operation = inputPointer(u8, operation),
        .operation_length = @intCast(operation.len),
        .arity = @intCast(input_fields.len),
        .input_fields = inputPointer(OracleInputField, input_fields),
        .input_field_count = @intCast(input_fields.len),
        .result_layout = .scalar,
        .structure_kind = .none,
        .result_field_count = @intCast(result_fields.len),
        .result_fields = inputPointer(OracleFieldDescriptor, result_fields),
    };
}

fn structureRequest(
    operation: []const u8,
    input_fields: []const OracleInputField,
    structure_kind: corpus.OracleStructureKind,
    result_fields: []const OracleFieldDescriptor,
) OracleRequest {
    var request = scalarRequest(operation, input_fields, result_fields);
    request.result_layout = .structure;
    request.structure_kind = structure_kind;
    return request;
}

fn inputPointer(comptime T: type, values: []const T) [*c]const T {
    if (values.len == 0) return null;
    return values.ptr;
}

fn outputPointer(values: []OracleResultField) [*c]OracleResultField {
    if (values.len == 0) return null;
    return values.ptr;
}

fn outputResult(fields: []OracleResultField) OracleResult {
    return .{
        .status = .@"error",
        .reserved = 0,
        .field_capacity = @intCast(fields.len),
        .field_count = 0,
        .fields = outputPointer(fields),
    };
}

fn sentinelField(descriptor: OracleFieldDescriptor) OracleResultField {
    return .{
        .descriptor = descriptor,
        .value_bits = 0xdead_beef_dead_beef,
        .class_code = .none,
        .reserved = 0,
    };
}

fn expectFailureLeavesNoFields(
    expected_status: OracleStatus,
    result: OracleResult,
    field: OracleResultField,
) !void {
    try std.testing.expectEqual(expected_status, result.status);
    try std.testing.expectEqual(@as(u32, 0), result.field_count);
    try std.testing.expectEqual(@as(u64, 0xdead_beef_dead_beef), field.value_bits);
}

fn expectStructureStatus(
    expected_status: OracleStatus,
    operation: []const u8,
    input_fields: []const OracleInputField,
    structure_kind: corpus.OracleStructureKind,
    result_descriptors: *const [2]OracleFieldDescriptor,
) !void {
    const request = structureRequest(
        operation,
        input_fields,
        structure_kind,
        result_descriptors,
    );
    var fields = [_]OracleResultField{
        sentinelField(result_descriptors[0]),
        sentinelField(result_descriptors[1]),
    };
    var result = outputResult(&fields);

    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);

    try expectFailureLeavesNoFields(expected_status, result, fields[0]);
    try std.testing.expectEqual(
        @as(u64, 0xdead_beef_dead_beef),
        fields[1].value_bits,
    );
}

test "Zig v2 field layout matches the C ABI" {
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(OracleInputField));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(OracleResultField));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(OracleInputField, "descriptor"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(OracleInputField, "value_bits"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(OracleInputField, "tag_bytes"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(OracleInputField, "tag_length"));
    try std.testing.expectEqual(@as(usize, 52), @offsetOf(OracleInputField, "reserved"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(OracleResultField, "descriptor"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(OracleResultField, "value_bits"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(OracleResultField, "class_code"));
    try std.testing.expectEqual(@as(usize, 44), @offsetOf(OracleResultField, "reserved"));
    try std.testing.expect(@hasField(OracleInputField, "tag_bytes"));
    try std.testing.expect(@hasField(OracleInputField, "tag_length"));
    try std.testing.expect(!@hasField(OracleResultField, "tag_bytes"));
    try std.testing.expect(!@hasField(OracleResultField, "tag_length"));
}

test "Zig v2 input fields preserve byte spans and scalar storage" {
    const literal = [_]u8{ 'n', 0, 0xff, 'x' };
    const tag = try corpus.oracleTagInput(literal[0..]);
    try std.testing.expectEqual(corpus.OracleFieldKind.tag, tag.descriptor.kind);
    try std.testing.expectEqual(@as(u32, 0), tag.descriptor.value_bits);
    try std.testing.expectEqual(@as(u64, 0), tag.value_bits);
    try std.testing.expect(tag.tag_bytes != null);
    try std.testing.expectEqual(@as(u32, literal.len), tag.tag_length);
    try std.testing.expectEqualSlices(
        u8,
        literal[0..],
        tag.tag_bytes[0..@as(usize, @intCast(tag.tag_length))],
    );

    const empty_tag = try corpus.oracleTagInput("");
    try std.testing.expect(empty_tag.tag_bytes == null);
    try std.testing.expectEqual(@as(u32, 0), empty_tag.tag_length);

    const scalar = floatInput(format_h, 0x3c00);
    try std.testing.expect(scalar.tag_bytes == null);
    try std.testing.expectEqual(@as(u32, 0), scalar.tag_length);
    try std.testing.expectError(
        error.InvalidInputValue,
        corpus.oracleLiteralInput(.tag, 1),
    );
}

test "Zig v2 signed integer codec uses zero-extended low-width bits" {
    const cases = [_]struct {
        value: i64,
        width: u32,
        encoded: u64,
    }{
        .{ .value = -2, .width = 2, .encoded = 0x2 },
        .{ .value = -1, .width = 2, .encoded = 0x3 },
        .{ .value = -128, .width = 8, .encoded = 0x80 },
        .{ .value = -1, .width = 8, .encoded = 0xff },
        .{ .value = -32_768, .width = 16, .encoded = 0x8000 },
        .{ .value = -1, .width = 16, .encoded = 0xffff },
        .{ .value = std.math.minInt(i32), .width = 32, .encoded = 0x8000_0000 },
        .{ .value = -1, .width = 32, .encoded = 0xffff_ffff },
        .{
            .value = std.math.minInt(i64),
            .width = 64,
            .encoded = 0x8000_0000_0000_0000,
        },
        .{ .value = -1, .width = 64, .encoded = std.math.maxInt(u64) },
    };
    for (cases) |case| {
        const encoded = try corpus.encodeSignedInteger(case.value, case.width);
        try std.testing.expectEqual(case.encoded, encoded);
        try std.testing.expectEqual(
            case.value,
            try corpus.decodeSignedInteger(encoded, case.width),
        );
    }

    try std.testing.expectError(
        error.InvalidIntegerWidth,
        corpus.encodeSignedInteger(0, 1),
    );
    try std.testing.expectError(error.IntegerOutOfRange, corpus.encodeSignedInteger(2, 2));
    try std.testing.expectError(error.IntegerOutOfRange, corpus.encodeSignedInteger(-3, 2));
    try std.testing.expectError(
        error.IntegerPayloadOutOfRange,
        corpus.decodeSignedInteger(0x100, 8),
    );
}

test "Zig v2 result fields enforce class-none non-float semantics" {
    const float_classes = [_]OracleClass{
        .normal,
        .subnormal,
        .zero,
        .infinity,
        .qnan,
    };
    for (float_classes) |class_code| {
        const field = try corpus.oracleResultField(
            floatDescriptor(format_h),
            0,
            class_code,
        );
        try std.testing.expectEqual(class_code, field.class_code);
    }

    const signed = try corpus.oracleResultField(
        signedDescriptor(64),
        try corpus.encodeSignedInteger(-1, 64),
        .none,
    );
    try std.testing.expectEqual(std.math.maxInt(u64), signed.value_bits);
    try std.testing.expectEqual(OracleClass.none, signed.class_code);
    const unsigned = try corpus.oracleResultField(unsignedDescriptor(8), 0xff, .none);
    try std.testing.expectEqual(OracleClass.none, unsigned.class_code);
    const boolean = try corpus.oracleResultField(booleanDescriptor(), 1, .none);
    try std.testing.expectEqual(OracleClass.none, boolean.class_code);

    try std.testing.expectError(
        error.InvalidResultClass,
        corpus.oracleResultField(floatDescriptor(format_h), 0, .none),
    );
    try std.testing.expectError(
        error.InvalidResultClass,
        corpus.oracleResultField(signedDescriptor(64), std.math.maxInt(u64), .normal),
    );
    try std.testing.expectError(
        error.InvalidResultClass,
        corpus.oracleResultField(booleanDescriptor(), 1, .zero),
    );

    const tag_descriptor = (try corpus.oracleTagInput("result")).descriptor;
    try std.testing.expectError(
        error.InvalidResultClass,
        corpus.oracleResultField(tag_descriptor, 0, .none),
    );
}
test "corpus struct descriptors preserve typed result fields" {
    const frexp = corpus.ResultDescriptor{
        .structure = .{ .kind = .frexp, .format = .h },
    };
    const frexp_exponent = frexp.oracleFieldDescriptor(1) orelse unreachable;
    try std.testing.expectEqual(corpus.OracleFieldKind.signed_integer, frexp_exponent.kind);
    try std.testing.expectEqual(@as(u32, 32), frexp_exponent.value_bits);

    const modf = corpus.ResultDescriptor{
        .structure = .{ .kind = .modf, .format = .h },
    };
    const modf_integral = modf.oracleFieldDescriptor(1) orelse unreachable;
    try std.testing.expectEqual(corpus.OracleFieldKind.float, modf_integral.kind);
    try std.testing.expectEqual(corpus.OracleFormat.h, modf_integral.format.code);

    const remquo = corpus.ResultDescriptor{
        .structure = .{ .kind = .remquo, .format = .f },
    };
    const remquo_quotient = remquo.oracleFieldDescriptor(1) orelse unreachable;
    try std.testing.expectEqual(corpus.OracleFieldKind.signed_integer, remquo_quotient.kind);
    try std.testing.expectEqual(@as(u32, 32), remquo_quotient.value_bits);

    const lgamma = corpus.ResultDescriptor{
        .structure = .{ .kind = .lgamma, .format = .d },
    };
    const lgamma_sign = lgamma.oracleFieldDescriptor(1) orelse unreachable;
    try std.testing.expectEqual(corpus.OracleFieldKind.signed_integer, lgamma_sign.kind);
    try std.testing.expectEqual(@as(u32, 2), lgamma_sign.value_bits);
}

test "v2 MPFR retains exp log and sin scalar results" {
    const cases = [_]struct {
        operation: []const u8,
        input_bits: u64,
        expected_bits: u64,
        expected_class: OracleClass,
    }{
        .{
            .operation = "exp",
            .input_bits = 0x0000,
            .expected_bits = 0x3c00,
            .expected_class = .normal,
        },
        .{
            .operation = "log",
            .input_bits = 0x0000,
            .expected_bits = 0xfc00,
            .expected_class = .infinity,
        },
        .{
            .operation = "sin",
            .input_bits = 0x8000,
            .expected_bits = 0x8000,
            .expected_class = .zero,
        },
    };

    for (cases) |case| {
        const input_fields = [_]OracleInputField{floatInput(format_h, case.input_bits)};
        const result_descriptors = [_]OracleFieldDescriptor{floatDescriptor(format_h)};
        const request = scalarRequest(case.operation, &input_fields, &result_descriptors);
        var fields = [_]OracleResultField{sentinelField(result_descriptors[0])};
        var result = outputResult(&fields);

        corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);

        try std.testing.expectEqual(OracleStatus.ok, result.status);
        try std.testing.expectEqual(case.expected_bits, fields[0].value_bits);
        try std.testing.expectEqual(result_descriptors[0], fields[0].descriptor);
        try std.testing.expectEqual(case.expected_class, fields[0].class_code);
        try std.testing.expectEqual(@as(u32, 0), fields[0].reserved);
    }
}

test "v2 MPFR keeps source and destination formats independent" {
    const input_fields = [_]OracleInputField{floatInput(format_h, 0x0000)};
    const result_descriptors = [_]OracleFieldDescriptor{floatDescriptor(format_f)};
    const request = scalarRequest("exp", &input_fields, &result_descriptors);
    var fields = [_]OracleResultField{sentinelField(result_descriptors[0])};
    var result = outputResult(&fields);

    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);

    try std.testing.expectEqual(OracleStatus.ok, result.status);
    try std.testing.expectEqual(@as(u64, 0x3f80_0000), fields[0].value_bits);
    try std.testing.expectEqual(OracleFormat.f, fields[0].descriptor.format.code);
    try std.testing.expectEqual(OracleClass.normal, fields[0].class_code);
}

test "v2 rejects malformed request and format descriptors" {
    var input_fields = [_]OracleInputField{floatInput(format_h, 0x0000)};
    const result_descriptors = [_]OracleFieldDescriptor{floatDescriptor(format_h)};
    var request = scalarRequest("exp", &input_fields, &result_descriptors);
    var fields = [_]OracleResultField{sentinelField(result_descriptors[0])};
    var result = outputResult(&fields);

    request.abi_version = 1;
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.@"error", result, fields[0]);

    request.abi_version = corpus.oracle_abi_version;
    input_fields[0].descriptor.format.fraction_bits = 9;
    result = outputResult(&fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.@"error", result, fields[0]);

    input_fields[0] = floatInput(format_h, 0x0000);
    request.input_field_count = 0;
    result = outputResult(&fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.@"error", result, fields[0]);
}

test "v2 accepts well-formed tag inputs as opaque values" {
    var tag_inputs = [_]OracleInputField{tagInput("round")};
    const result_descriptors = [_]OracleFieldDescriptor{floatDescriptor(format_h)};
    var fields = [_]OracleResultField{sentinelField(result_descriptors[0])};
    const request = scalarRequest("exp", &tag_inputs, &result_descriptors);
    var result = outputResult(&fields);

    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);

    try expectFailureLeavesNoFields(.unsupported, result, fields[0]);

    tag_inputs[0] = tagInput("");
    result = outputResult(&fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.unsupported, result, fields[0]);
}

test "v2 rejects malformed tag and rounding input values" {
    const result_descriptors = [_]OracleFieldDescriptor{floatDescriptor(format_h)};
    var fields = [_]OracleResultField{sentinelField(result_descriptors[0])};

    var tag_inputs = [_]OracleInputField{tagInput("round")};
    tag_inputs[0].value_bits = 1;
    var request = scalarRequest("exp", &tag_inputs, &result_descriptors);
    var result = outputResult(&fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.@"error", result, fields[0]);

    tag_inputs[0] = tagInput("round");
    tag_inputs[0].tag_bytes = null;
    result = outputResult(&fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.@"error", result, fields[0]);

    tag_inputs[0] = tagInput("round");
    tag_inputs[0].tag_length = 0;
    result = outputResult(&fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.@"error", result, fields[0]);

    const rounding_inputs = [_]OracleInputField{roundingInput(@as(u64, 1) << 40)};
    request = scalarRequest("exp", &rounding_inputs, &result_descriptors);
    result = outputResult(&fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.@"error", result, fields[0]);
}

test "v2 rejects result count type and capacity errors" {
    const input_fields = [_]OracleInputField{floatInput(format_h, 0x0000)};
    var result_descriptors = [_]OracleFieldDescriptor{
        floatDescriptor(format_h),
        floatDescriptor(format_h),
    };
    var request = scalarRequest("exp", &input_fields, &result_descriptors);
    var fields = [_]OracleResultField{
        sentinelField(result_descriptors[0]),
        sentinelField(result_descriptors[1]),
    };
    var result = outputResult(&fields);

    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.@"error", result, fields[0]);

    request.result_field_count = 1;
    result_descriptors[0].kind = @enumFromInt(99);
    result = outputResult(&fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.@"error", result, fields[0]);
    result_descriptors[0] = signedDescriptor(32);
    result_descriptors[0].format = format_h;
    result = outputResult(&fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.@"error", result, fields[0]);

    result_descriptors[0] = floatDescriptor(format_h);
    result_descriptors[1] = booleanDescriptor();
    request.result_layout = .structure;
    request.structure_kind = .frexp;
    request.result_field_count = 2;
    result = outputResult(&fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.@"error", result, fields[0]);

    request.result_layout = .scalar;
    request.structure_kind = .none;
    request.result_field_count = 1;

    result_descriptors[0] = floatDescriptor(format_h);
    result = outputResult(fields[0..0]);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try std.testing.expectEqual(OracleStatus.@"error", result.status);
    try std.testing.expectEqual(@as(u32, 0), result.field_count);
}

test "v2 rejects tag result descriptors" {
    const input_fields = [_]OracleInputField{floatInput(format_h, 0x0000)};
    const tag_descriptor = (try corpus.oracleTagInput("result")).descriptor;
    const result_descriptors = [_]OracleFieldDescriptor{tag_descriptor};
    const request = scalarRequest("exp", &input_fields, &result_descriptors);
    var fields = [_]OracleResultField{sentinelField(result_descriptors[0])};
    var result = outputResult(&fields);

    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);

    try expectFailureLeavesNoFields(.@"error", result, fields[0]);
}

test "v2 returns unsupported for reserved formats and valid capability hooks" {
    var output_descriptors = [_]OracleFieldDescriptor{floatDescriptor(format_h)};
    var fields = [_]OracleResultField{sentinelField(output_descriptors[0])};

    const reserved_inputs = [_]OracleInputField{floatInput(format_reserved, 0)};
    var request = scalarRequest("exp", &reserved_inputs, &output_descriptors);
    var result = outputResult(&fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.unsupported, result, fields[0]);
    const digit_inputs = [_]OracleInputField{floatInput(format_h, 0)};
    request = scalarRequest("exp2", &digit_inputs, &output_descriptors);
    result = outputResult(&fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.unsupported, result, fields[0]);

    const binary_inputs = [_]OracleInputField{
        floatInput(format_h, 0x3c00),
        floatInput(format_f, 0x3f80_0000),
    };
    request = scalarRequest("atan2", &binary_inputs, &output_descriptors);
    result = outputResult(&fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.unsupported, result, fields[0]);

    const ternary_inputs = [_]OracleInputField{
        floatInput(format_h, 0x3c00),
        floatInput(format_f, 0x3f80_0000),
        floatInput(format_h, 0x4000),
    };
    request = scalarRequest("fma", &ternary_inputs, &output_descriptors);
    result = outputResult(&fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.unsupported, result, fields[0]);

    output_descriptors[0] = signedDescriptor(32);
    request = scalarRequest("ilogb", reserved_inputs[0..1], &output_descriptors);
    request.input_fields = inputPointer(OracleInputField, ternary_inputs[0..1]);
    result = outputResult(&fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.unsupported, result, fields[0]);

    output_descriptors[0] = booleanDescriptor();
    request = scalarRequest("iscanonical", ternary_inputs[0..1], &output_descriptors);
    result = outputResult(&fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);
    try expectFailureLeavesNoFields(.unsupported, result, fields[0]);
}

test "v2 accepts struct result descriptors without claiming support" {
    const input_fields = [_]OracleInputField{floatInput(format_h, 0x3c00)};
    const output_descriptors = [_]OracleFieldDescriptor{
        floatDescriptor(format_h),
        signedDescriptor(32),
    };
    var request = scalarRequest("frexp", &input_fields, &output_descriptors);
    request.result_layout = .structure;
    request.structure_kind = .frexp;
    var fields = [_]OracleResultField{
        sentinelField(output_descriptors[0]),
        sentinelField(output_descriptors[1]),
    };
    var result = outputResult(&fields);

    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);

    try expectFailureLeavesNoFields(.unsupported, result, fields[0]);
}

test "v2 accepts exact atan2 power and integer two-field shapes" {
    const binary_inputs = [_]OracleInputField{
        floatInput(format_h, 0x3c00),
        floatInput(format_h, 0x4000),
    };
    const power_inputs = [_]OracleInputField{
        floatInput(format_h, 0x3c00),
        signedInput(64, 2),
    };
    const integer_inputs = [_]OracleInputField{floatInput(format_h, 0x3c00)};
    const float_boolean = [_]OracleFieldDescriptor{
        floatDescriptor(format_h),
        booleanDescriptor(),
    };
    const integer_boolean = [_]OracleFieldDescriptor{
        signedDescriptor(64),
        booleanDescriptor(),
    };
    try std.testing.expectEqual(
        @as(c_uint, 7),
        @intFromEnum(corpus.OracleStructureKind.atan2),
    );
    try std.testing.expectEqual(
        @as(c_uint, 8),
        @intFromEnum(corpus.OracleStructureKind.power),
    );
    try std.testing.expectEqual(
        @as(c_uint, 9),
        @intFromEnum(corpus.OracleStructureKind.integer),
    );

    try expectStructureStatus(
        .unsupported,
        "atan2",
        &binary_inputs,
        .atan2,
        &float_boolean,
    );
    try expectStructureStatus(
        .unsupported,
        "compoundn",
        &power_inputs,
        .power,
        &float_boolean,
    );
    try expectStructureStatus(
        .unsupported,
        "llrint",
        &integer_inputs,
        .integer,
        &integer_boolean,
    );
}

test "v2 rejects malformed atan2 power and integer shapes" {
    const binary_inputs = [_]OracleInputField{
        floatInput(format_h, 0x3c00),
        floatInput(format_h, 0x4000),
    };
    const power_inputs = [_]OracleInputField{
        floatInput(format_h, 0x3c00),
        signedInput(64, 2),
    };
    const integer_inputs = [_]OracleInputField{floatInput(format_h, 0x3c00)};
    const malformed_atan2 = [_]OracleFieldDescriptor{
        floatDescriptor(format_h),
        signedDescriptor(32),
    };
    const malformed_power = [_]OracleFieldDescriptor{
        floatDescriptor(format_h),
        signedDescriptor(64),
    };
    const malformed_integer = [_]OracleFieldDescriptor{
        signedDescriptor(32),
        booleanDescriptor(),
    };

    try expectStructureStatus(
        .@"error",
        "atan2",
        &binary_inputs,
        .atan2,
        &malformed_atan2,
    );
    try expectStructureStatus(
        .@"error",
        "compoundn",
        &power_inputs,
        .power,
        &malformed_power,
    );
    try expectStructureStatus(
        .@"error",
        "llrint",
        &integer_inputs,
        .integer,
        &malformed_integer,
    );
    const unknown_kind_request = structureRequest(
        "atan2",
        &binary_inputs,
        @enumFromInt(10),
        &malformed_atan2,
    );
    var unknown_kind_fields = [_]OracleResultField{
        sentinelField(malformed_atan2[0]),
        sentinelField(malformed_atan2[1]),
    };
    var unknown_kind_result = outputResult(&unknown_kind_fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(
        &unknown_kind_request,
        &unknown_kind_result,
    );
    try expectFailureLeavesNoFields(
        .@"error",
        unknown_kind_result,
        unknown_kind_fields[0],
    );

    const exact_atan2 = [_]OracleFieldDescriptor{
        floatDescriptor(format_h),
        booleanDescriptor(),
    };
    var request = structureRequest(
        "atan2",
        &binary_inputs,
        .atan2,
        &exact_atan2,
    );
    request.result_field_count = 1;
    var fields = [_]OracleResultField{
        sentinelField(exact_atan2[0]),
        sentinelField(exact_atan2[1]),
    };
    var result = outputResult(&fields);

    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &result);

    try expectFailureLeavesNoFields(.@"error", result, fields[0]);
    try std.testing.expectEqual(
        @as(u64, 0xdead_beef_dead_beef),
        fields[1].value_bits,
    );
}

test "v2 Arb proves typed candidate and fails closed on disagreement" {
    const input_fields = [_]OracleInputField{floatInput(format_h, 0x0000)};
    const result_descriptors = [_]OracleFieldDescriptor{floatDescriptor(format_h)};
    const request = scalarRequest("exp", &input_fields, &result_descriptors);
    var candidate_fields = [_]OracleResultField{sentinelField(result_descriptors[0])};
    var candidate = outputResult(&candidate_fields);
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &candidate);
    try std.testing.expectEqual(OracleStatus.ok, candidate.status);

    var proof_fields = [_]OracleResultField{sentinelField(result_descriptors[0])};
    var proof = outputResult(&proof_fields);
    corpus.zmath_testing_oracle_v2_arb_prove(&request, &candidate, &proof);
    try std.testing.expectEqual(@as(u64, 0x3c00), proof_fields[0].value_bits);
    try std.testing.expectEqual(@as(u32, 1), proof.field_count);

    candidate_fields[0].class_code = .none;
    proof_fields[0] = sentinelField(result_descriptors[0]);
    proof = outputResult(&proof_fields);
    corpus.zmath_testing_oracle_v2_arb_prove(&request, &candidate, &proof);
    try expectFailureLeavesNoFields(.@"error", proof, proof_fields[0]);
    candidate_fields[0].class_code = .normal;

    candidate_fields[0].value_bits = 0x3c01;

    proof_fields[0] = sentinelField(result_descriptors[0]);
    proof = outputResult(&proof_fields);
    corpus.zmath_testing_oracle_v2_arb_prove(&request, &candidate, &proof);
    try expectFailureLeavesNoFields(.uncertain, proof, proof_fields[0]);

    candidate.field_count = 0;
    proof = outputResult(&proof_fields);
    corpus.zmath_testing_oracle_v2_arb_prove(&request, &candidate, &proof);
    try std.testing.expectEqual(OracleStatus.@"error", proof.status);
    try std.testing.expectEqual(@as(u32, 0), proof.field_count);
}
