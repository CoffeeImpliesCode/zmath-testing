const std = @import("std");
const c = @import("oracle_abi");

const max_fields: usize = c.ZMATH_TESTING_ORACLE_MAX_FIELDS;

const ExpectedField = struct {
    value_bits: u64,
    class_code: u32,
};

const RequestStorage = struct {
    inputs: [max_fields]c.zmath_testing_oracle_input_field = undefined,
    result_descriptors: [max_fields]c.zmath_testing_oracle_field_descriptor = undefined,
    request: c.zmath_testing_oracle_request = undefined,

    fn init(
        self: *RequestStorage,
        signature: *const c.zmath_testing_oracle_operation_signature,
        values: []const u64,
    ) void {
        std.debug.assert(values.len == signature.arity);
        std.debug.assert(signature.arguments != null);
        std.debug.assert(signature.result_fields != null);
        std.debug.assert(signature.arity <= max_fields);
        std.debug.assert(signature.result_field_count <= max_fields);

        for (values, 0..) |value_bits, index| {
            self.inputs[index] = .{
                .descriptor = signature.arguments[index],
                .value_bits = value_bits,
                .tag_bytes = null,
                .tag_length = 0,
                .reserved = 0,
            };
        }
        for (0..signature.result_field_count) |index| {
            self.result_descriptors[index] = signature.result_fields[index];
        }
        self.request = .{
            .abi_version = c.ZMATH_TESTING_ORACLE_ABI_VERSION,
            .reserved = 0,
            .operation = signature.operation,
            .operation_length = signature.operation_length,
            .arity = signature.arity,
            .input_fields = @ptrCast(&self.inputs),
            .input_field_count = signature.arity,
            .result_layout = signature.result_layout,
            .structure_kind = signature.structure_kind,
            .result_field_count = signature.result_field_count,
            .result_fields = @ptrCast(&self.result_descriptors),
        };
    }
};

const OutputStorage = struct {
    fields: [max_fields]c.zmath_testing_oracle_result_field = undefined,
    result: c.zmath_testing_oracle_result = undefined,

    fn init(self: *OutputStorage, field_capacity: u32) void {
        std.debug.assert(field_capacity <= c.ZMATH_TESTING_ORACLE_MAX_FIELDS);
        for (&self.fields) |*field| {
            field.* = .{
                .descriptor = .{
                    .kind = 0,
                    .value_bits = 0,
                    .format = .{
                        .code = 0,
                        .storage_bits = 0,
                        .exponent_bits = 0,
                        .fraction_bits = 0,
                        .reserved = 0,
                    },
                    .reserved = 0,
                },
                .value_bits = 0xdead_beef_dead_beef,
                .class_code = 0xffff_ffff,
                .reserved = 0,
            };
        }
        self.result = .{
            .status = c.ZMATH_TESTING_ORACLE_UNSUPPORTED,
            .reserved = 0,
            .field_capacity = field_capacity,
            .field_count = 0xffff_ffff,
            .fields = @ptrCast(&self.fields),
        };
    }

    fn setCandidate(
        self: *OutputStorage,
        signature: *const c.zmath_testing_oracle_operation_signature,
        expected: []const ExpectedField,
    ) void {
        std.debug.assert(expected.len == signature.result_field_count);
        std.debug.assert(signature.result_fields != null);

        // The ABI carries the field count in a u32, so the storage capacity
        // comes from a checked conversion, not a narrowed slice length.
        const field_count = std.math.cast(u32, expected.len) orelse
            @panic("expected field count does not fit the oracle ABI");
        self.init(field_count);
        self.result.status = c.ZMATH_TESTING_ORACLE_OK;
        self.result.field_count = field_count;
        for (expected, 0..) |field, index| {
            self.fields[index] = .{
                .descriptor = signature.result_fields[index],
                .value_bits = field.value_bits,
                .class_code = field.class_code,
                .reserved = 0,
            };
        }
    }
};

fn operationSlice(
    signature: *const c.zmath_testing_oracle_operation_signature,
) []const u8 {
    std.debug.assert(signature.operation != null);
    const pointer: [*]const u8 = @ptrCast(signature.operation);
    return pointer[0..@intCast(signature.operation_length)];
}

fn findSignature(
    operation_name: []const u8,
    format_code: u32,
) !*const c.zmath_testing_oracle_operation_signature {
    for (&c.zmath_testing_oracle_operation_table) |*signature| {
        if (!std.mem.eql(u8, operation_name, operationSlice(signature))) continue;
        if (signature.arity == 0) continue;
        if (signature.arguments == null) continue;
        if (signature.arguments[0].kind != c.ZMATH_TESTING_ORACLE_FIELD_FLOAT) continue;
        if (signature.arguments[0].format.code != format_code) continue;
        return signature;
    }
    return error.SignatureNotFound;
}

fn expectSuccess(
    output: *const OutputStorage,
    expected: []const ExpectedField,
) !void {
    try std.testing.expectEqual(
        @as(u32, c.ZMATH_TESTING_ORACLE_OK),
        output.result.status,
    );
    // Same u32 ABI width as the candidate storage: compare against a checked
    // conversion so an oversized expectation reports instead of trapping.
    const field_count = std.math.cast(u32, expected.len) orelse
        return error.ExpectedFieldCountOutOfRange;
    try std.testing.expectEqual(field_count, output.result.field_count);
    for (expected, 0..) |field, index| {
        try std.testing.expectEqual(field.value_bits, output.fields[index].value_bits);
        try std.testing.expectEqual(field.class_code, output.fields[index].class_code);
    }
}

fn expectClosed(expected_status: u32, output: *const OutputStorage) !void {
    try std.testing.expectEqual(expected_status, output.result.status);
    try std.testing.expectEqual(@as(u32, 0), output.result.field_count);
}

test "typed bridge rejects unsupported and malformed descriptors" {
    const signature = try findSignature("exp", c.ZMATH_TESTING_ORACLE_FORMAT_H);
    const expected = [_]ExpectedField{.{
        .value_bits = 0x3c00,
        .class_code = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
    }};
    var request: RequestStorage = .{};
    var output: OutputStorage = .{};

    request.init(signature, &.{0x0000});
    request.inputs[0].descriptor.format.code = 4;
    output.init(signature.result_field_count);
    c.zmath_testing_oracle_v2_mpfr_reference(&request.request, &output.result);
    try expectClosed(c.ZMATH_TESTING_ORACLE_UNSUPPORTED, &output);

    request.init(signature, &.{0x0000});
    request.result_descriptors[0].format.code = 5;
    output.init(signature.result_field_count);
    c.zmath_testing_oracle_v2_mpfr_reference(&request.request, &output.result);
    try expectClosed(c.ZMATH_TESTING_ORACLE_UNSUPPORTED, &output);

    var candidate: OutputStorage = .{};
    candidate.setCandidate(signature, &expected);
    request.init(signature, &.{0x0000});
    request.inputs[0].descriptor.format.storage_bits = 15;
    output.init(signature.result_field_count);
    c.zmath_testing_oracle_v2_arb_prove(
        &request.request,
        &candidate.result,
        &output.result,
    );
    try expectClosed(c.ZMATH_TESTING_ORACLE_ERROR, &output);

    request.init(signature, &.{0x0000});
    request.inputs[0].descriptor.kind = 0xffff_ffff;
    output.init(signature.result_field_count);
    c.zmath_testing_oracle_v2_mpfr_reference(&request.request, &output.result);
    try expectClosed(c.ZMATH_TESTING_ORACLE_ERROR, &output);
}

test "typed bridge rejects malformed request metadata and values" {
    const signature = try findSignature("exp", c.ZMATH_TESTING_ORACLE_FORMAT_H);
    const expected = [_]ExpectedField{.{
        .value_bits = 0x3c00,
        .class_code = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
    }};
    var request: RequestStorage = .{};
    var output: OutputStorage = .{};

    request.init(signature, &.{0x0000});
    request.request.abi_version = c.ZMATH_TESTING_ORACLE_ABI_VERSION + 1;
    output.init(signature.result_field_count);
    c.zmath_testing_oracle_v2_mpfr_reference(&request.request, &output.result);
    try expectClosed(c.ZMATH_TESTING_ORACLE_ERROR, &output);

    var candidate: OutputStorage = .{};
    candidate.setCandidate(signature, &expected);
    request.init(signature, &.{0x0000});
    request.request.arity = 2;
    output.init(signature.result_field_count);
    c.zmath_testing_oracle_v2_arb_prove(
        &request.request,
        &candidate.result,
        &output.result,
    );
    try expectClosed(c.ZMATH_TESTING_ORACLE_ERROR, &output);

    request.init(signature, &.{0x1_0000});
    output.init(signature.result_field_count);
    c.zmath_testing_oracle_v2_mpfr_reference(&request.request, &output.result);
    try expectClosed(c.ZMATH_TESTING_ORACLE_ERROR, &output);

    request.init(signature, &.{0x0000});
    request.request.reserved = 1;
    output.init(signature.result_field_count);
    c.zmath_testing_oracle_v2_arb_prove(
        &request.request,
        &candidate.result,
        &output.result,
    );
    try expectClosed(c.ZMATH_TESTING_ORACLE_ERROR, &output);
}

test "typed bridge fails closed on insufficient result capacity" {
    const signature = try findSignature("exp", c.ZMATH_TESTING_ORACLE_FORMAT_H);
    const expected = [_]ExpectedField{.{
        .value_bits = 0x3c00,
        .class_code = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
    }};
    var request: RequestStorage = .{};
    request.init(signature, &.{0x0000});

    var output: OutputStorage = .{};
    output.init(0);
    c.zmath_testing_oracle_v2_mpfr_reference(&request.request, &output.result);
    try expectClosed(c.ZMATH_TESTING_ORACLE_ERROR, &output);

    var candidate: OutputStorage = .{};
    candidate.setCandidate(signature, &expected);
    output.init(0);
    c.zmath_testing_oracle_v2_arb_prove(
        &request.request,
        &candidate.result,
        &output.result,
    );
    try expectClosed(c.ZMATH_TESTING_ORACLE_ERROR, &output);
}

test "typed MPFR reference returns exact transcendental bits" {
    const cases = [_]struct {
        operation_name: []const u8,
        format_code: u32,
        input_bits: u64,
        expected_bits: u64,
        expected_class: u32,
    }{
        .{
            .operation_name = "exp",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .input_bits = 0x0000,
            .expected_bits = 0x3c00,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "log",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .input_bits = 0x0000,
            .expected_bits = 0xfc00,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY,
        },
        .{
            .operation_name = "exp",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .input_bits = 0x3c00,
            .expected_bits = 0x4170,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "exp",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .input_bits = 0x3f80_0000,
            .expected_bits = 0x402d_f854,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "exp",
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .input_bits = 0x3ff0_0000_0000_0000,
            .expected_bits = 0x4005_bf0a_8b14_5769,
            .expected_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
    };

    for (cases) |case| {
        const signature = try findSignature(case.operation_name, case.format_code);
        var request: RequestStorage = .{};
        request.init(signature, &.{case.input_bits});
        var output: OutputStorage = .{};
        output.init(signature.result_field_count);
        c.zmath_testing_oracle_v2_mpfr_reference(&request.request, &output.result);
        const expected = [_]ExpectedField{.{
            .value_bits = case.expected_bits,
            .class_code = case.expected_class,
        }};
        try expectSuccess(&output, &expected);
    }
}

test "typed Arb proof accepts exact transcendental special cases" {
    const cases = [_]struct {
        operation_name: []const u8,
        input_bits: u64,
        candidate_bits: u64,
        candidate_class: u32,
    }{
        .{
            .operation_name = "exp",
            .input_bits = 0x0000,
            .candidate_bits = 0x3c00,
            .candidate_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .operation_name = "log",
            .input_bits = 0x0000,
            .candidate_bits = 0xfc00,
            .candidate_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY,
        },
        .{
            .operation_name = "log",
            .input_bits = 0x8000,
            .candidate_bits = 0xfc00,
            .candidate_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY,
        },
        .{
            .operation_name = "log",
            .input_bits = 0xbc00,
            .candidate_bits = 0x7e00,
            .candidate_class = c.ZMATH_TESTING_ORACLE_CLASS_QNAN,
        },
        .{
            .operation_name = "log",
            .input_bits = 0x3c00,
            .candidate_bits = 0x0000,
            .candidate_class = c.ZMATH_TESTING_ORACLE_CLASS_ZERO,
        },
    };

    for (cases) |case| {
        const signature = try findSignature(
            case.operation_name,
            c.ZMATH_TESTING_ORACLE_FORMAT_H,
        );
        var request: RequestStorage = .{};
        request.init(signature, &.{case.input_bits});
        const expected = [_]ExpectedField{.{
            .value_bits = case.candidate_bits,
            .class_code = case.candidate_class,
        }};
        var candidate: OutputStorage = .{};
        candidate.setCandidate(signature, &expected);
        var proof: OutputStorage = .{};
        proof.init(signature.result_field_count);
        c.zmath_testing_oracle_v2_arb_prove(
            &request.request,
            &candidate.result,
            &proof.result,
        );
        try expectSuccess(&proof, &expected);
    }
}

test "typed reference preserves signed zero and NaN payload behavior" {
    const cases = [_]struct {
        format_code: u32,
        negative_zero: u64,
        signaling_nan: u64,
        quiet_nan: u64,
    }{
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .negative_zero = 0x8000,
            .signaling_nan = 0x7d01,
            .quiet_nan = 0x7f01,
        },
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .negative_zero = 0x8000_0000,
            .signaling_nan = 0x7f80_0001,
            .quiet_nan = 0x7fc0_0001,
        },
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .negative_zero = 0x8000_0000_0000_0000,
            .signaling_nan = 0x7ff0_0000_0000_0001,
            .quiet_nan = 0x7ff8_0000_0000_0001,
        },
    };

    for (cases) |case| {
        const sine_signature = try findSignature("sin", case.format_code);
        var request: RequestStorage = .{};
        request.init(sine_signature, &.{case.negative_zero});
        var output: OutputStorage = .{};
        output.init(sine_signature.result_field_count);
        c.zmath_testing_oracle_v2_mpfr_reference(&request.request, &output.result);
        const expected_zero = [_]ExpectedField{.{
            .value_bits = case.negative_zero,
            .class_code = c.ZMATH_TESTING_ORACLE_CLASS_ZERO,
        }};
        try expectSuccess(&output, &expected_zero);

        const exp_signature = try findSignature("exp", case.format_code);
        request.init(exp_signature, &.{case.signaling_nan});
        output.init(exp_signature.result_field_count);
        c.zmath_testing_oracle_v2_mpfr_reference(&request.request, &output.result);
        const expected_nan = [_]ExpectedField{.{
            .value_bits = case.quiet_nan,
            .class_code = c.ZMATH_TESTING_ORACLE_CLASS_QNAN,
        }};
        try expectSuccess(&output, &expected_nan);
    }
}

test "typed bridge retains signaling NaN result classes" {
    {
        const signature = try findSignature(
            "copySign",
            c.ZMATH_TESTING_ORACLE_FORMAT_H,
        );
        const expected = [_]ExpectedField{.{
            .value_bits = 0xfc01,
            .class_code = c.ZMATH_TESTING_ORACLE_CLASS_SNAN,
        }};
        var request: RequestStorage = .{};
        request.init(signature, &.{ 0x7c01, 0x8000 });
        var reference: OutputStorage = .{};
        reference.init(signature.result_field_count);
        c.zmath_testing_oracle_v2_mpfr_reference(
            &request.request,
            &reference.result,
        );
        try expectSuccess(&reference, &expected);

        var candidate: OutputStorage = .{};
        candidate.setCandidate(signature, &expected);
        var proof: OutputStorage = .{};
        proof.init(signature.result_field_count);
        c.zmath_testing_oracle_v2_arb_prove(
            &request.request,
            &candidate.result,
            &proof.result,
        );
        try expectSuccess(&proof, &expected);
    }

    {
        const signature = try findSignature(
            "setPayloadSig",
            c.ZMATH_TESTING_ORACLE_FORMAT_H,
        );
        const expected = [_]ExpectedField{
            .{
                .value_bits = 0x7c03,
                .class_code = c.ZMATH_TESTING_ORACLE_CLASS_SNAN,
            },
            .{
                .value_bits = 1,
                .class_code = c.ZMATH_TESTING_ORACLE_CLASS_NONE,
            },
        };
        var request: RequestStorage = .{};
        request.init(signature, &.{0x4200});
        var reference: OutputStorage = .{};
        reference.init(signature.result_field_count);
        c.zmath_testing_oracle_v2_mpfr_reference(
            &request.request,
            &reference.result,
        );
        try expectSuccess(&reference, &expected);

        var candidate: OutputStorage = .{};
        candidate.setCandidate(signature, &expected);
        var proof: OutputStorage = .{};
        proof.init(signature.result_field_count);
        c.zmath_testing_oracle_v2_arb_prove(
            &request.request,
            &candidate.result,
            &proof.result,
        );
        try expectSuccess(&proof, &expected);
    }
}

test "typed Arb proof rejects a forged normal result class" {
    const signature = try findSignature("exp", c.ZMATH_TESTING_ORACLE_FORMAT_H);
    var request: RequestStorage = .{};
    request.init(signature, &.{0x3c00});

    var reference: OutputStorage = .{};
    reference.init(signature.result_field_count);
    c.zmath_testing_oracle_v2_mpfr_reference(&request.request, &reference.result);
    const expected = [_]ExpectedField{.{
        .value_bits = 0x4170,
        .class_code = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
    }};
    try expectSuccess(&reference, &expected);

    reference.fields[0].class_code = c.ZMATH_TESTING_ORACLE_CLASS_ZERO;
    var proof: OutputStorage = .{};
    proof.init(signature.result_field_count);
    c.zmath_testing_oracle_v2_arb_prove(
        &request.request,
        &reference.result,
        &proof.result,
    );
    try expectClosed(c.ZMATH_TESTING_ORACLE_ERROR, &proof);

    var candidate: OutputStorage = .{};
    candidate.setCandidate(signature, &expected);
    candidate.fields[0].descriptor.format.fraction_bits = 9;
    proof.init(signature.result_field_count);
    c.zmath_testing_oracle_v2_arb_prove(
        &request.request,
        &candidate.result,
        &proof.result,
    );
    try expectClosed(c.ZMATH_TESTING_ORACLE_ERROR, &proof);
}

test "typed Arb proof reports valid candidate disagreement as uncertain" {
    const signature = try findSignature("exp", c.ZMATH_TESTING_ORACLE_FORMAT_H);
    var request: RequestStorage = .{};
    request.init(signature, &.{0x0000});
    const incorrect = [_]ExpectedField{.{
        .value_bits = 0x3c01,
        .class_code = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
    }};
    var candidate: OutputStorage = .{};
    candidate.setCandidate(signature, &incorrect);
    var proof: OutputStorage = .{};
    proof.init(signature.result_field_count);
    c.zmath_testing_oracle_v2_arb_prove(
        &request.request,
        &candidate.result,
        &proof.result,
    );
    try expectClosed(c.ZMATH_TESTING_ORACLE_UNCERTAIN, &proof);
}

test "typed Arb proof accepts finite exp overflow candidates" {
    const cases = [_]struct {
        format_code: u32,
        input_bits: u64,
        candidate_bits: u64,
    }{
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .input_bits = 0x498c,
            .candidate_bits = 0x7c00,
        },
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .input_bits = 0x42b1_7218,
            .candidate_bits = 0x7f80_0000,
        },
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .input_bits = 0x4086_2e42_fefa_39f0,
            .candidate_bits = 0x7ff0_0000_0000_0000,
        },
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .input_bits = 0x7bff,
            .candidate_bits = 0x7c00,
        },
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .input_bits = 0x7f7f_ffff,
            .candidate_bits = 0x7f80_0000,
        },
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .input_bits = 0x7fef_ffff_ffff_ffff,
            .candidate_bits = 0x7ff0_0000_0000_0000,
        },
    };

    for (cases) |case| {
        const signature = try findSignature("exp", case.format_code);
        var request: RequestStorage = .{};
        request.init(signature, &.{case.input_bits});
        const expected = [_]ExpectedField{.{
            .value_bits = case.candidate_bits,
            .class_code = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY,
        }};
        var candidate: OutputStorage = .{};
        candidate.setCandidate(signature, &expected);
        var proof: OutputStorage = .{};
        proof.init(signature.result_field_count);
        c.zmath_testing_oracle_v2_arb_prove(
            &request.request,
            &candidate.result,
            &proof.result,
        );
        try expectSuccess(&proof, &expected);
    }
}

test "typed Arb proof accepts exp underflow boundary candidates" {
    const cases = [_]struct {
        format_code: u32,
        input_bits: u64,
        candidate_bits: u64,
        candidate_class: u32,
    }{
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .input_bits = 0xcc55,
            .candidate_bits = 0x0001,
            .candidate_class = c.ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL,
        },
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .input_bits = 0xcc56,
            .candidate_bits = 0x0000,
            .candidate_class = c.ZMATH_TESTING_ORACLE_CLASS_ZERO,
        },
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .input_bits = 0xc2cf_f1b4,
            .candidate_bits = 0x0000_0001,
            .candidate_class = c.ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL,
        },
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .input_bits = 0xc2cf_f1b5,
            .candidate_bits = 0x0000_0000,
            .candidate_class = c.ZMATH_TESTING_ORACLE_CLASS_ZERO,
        },
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .input_bits = 0xc087_4910_d52d_3051,
            .candidate_bits = 0x0000_0000_0000_0001,
            .candidate_class = c.ZMATH_TESTING_ORACLE_CLASS_SUBNORMAL,
        },
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .input_bits = 0xc087_4910_d52d_3052,
            .candidate_bits = 0x0000_0000_0000_0000,
            .candidate_class = c.ZMATH_TESTING_ORACLE_CLASS_ZERO,
        },
    };

    for (cases) |case| {
        const signature = try findSignature("exp", case.format_code);
        var request: RequestStorage = .{};
        request.init(signature, &.{case.input_bits});
        const expected = [_]ExpectedField{.{
            .value_bits = case.candidate_bits,
            .class_code = case.candidate_class,
        }};
        var candidate: OutputStorage = .{};
        candidate.setCandidate(signature, &expected);
        var proof: OutputStorage = .{};
        proof.init(signature.result_field_count);
        c.zmath_testing_oracle_v2_arb_prove(
            &request.request,
            &candidate.result,
            &proof.result,
        );
        try expectSuccess(&proof, &expected);
    }
}

test "typed Arb proof rejects incorrect exp overflow edge candidates" {
    const cases = [_]struct {
        format_code: u32,
        input_bits: u64,
        candidate_bits: u64,
        candidate_class: u32,
    }{
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .input_bits = 0x498b,
            .candidate_bits = 0x7c00,
            .candidate_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY,
        },
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_H,
            .input_bits = 0x498c,
            .candidate_bits = 0x7bff,
            .candidate_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .input_bits = 0x42b1_7217,
            .candidate_bits = 0x7f80_0000,
            .candidate_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY,
        },
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_F,
            .input_bits = 0x42b1_7218,
            .candidate_bits = 0x7f7f_ffff,
            .candidate_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .input_bits = 0x4086_2e42_fefa_39ef,
            .candidate_bits = 0x7ff0_0000_0000_0000,
            .candidate_class = c.ZMATH_TESTING_ORACLE_CLASS_INFINITY,
        },
        .{
            .format_code = c.ZMATH_TESTING_ORACLE_FORMAT_D,
            .input_bits = 0x4086_2e42_fefa_39f0,
            .candidate_bits = 0x7fef_ffff_ffff_ffff,
            .candidate_class = c.ZMATH_TESTING_ORACLE_CLASS_NORMAL,
        },
    };

    for (cases) |case| {
        const signature = try findSignature("exp", case.format_code);
        var request: RequestStorage = .{};
        request.init(signature, &.{case.input_bits});
        const incorrect = [_]ExpectedField{.{
            .value_bits = case.candidate_bits,
            .class_code = case.candidate_class,
        }};
        var candidate: OutputStorage = .{};
        candidate.setCandidate(signature, &incorrect);
        var proof: OutputStorage = .{};
        proof.init(signature.result_field_count);
        c.zmath_testing_oracle_v2_arb_prove(
            &request.request,
            &candidate.result,
            &proof.result,
        );
        try expectClosed(c.ZMATH_TESTING_ORACLE_UNCERTAIN, &proof);
    }
}
