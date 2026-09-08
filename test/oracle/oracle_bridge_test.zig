const std = @import("std");

const format_h: c_uint = 1;
const format_f: c_uint = 2;
const format_d: c_uint = 3;
const format_q: c_uint = 4;
// The ABI does not assign bfloat16 a format code. Five is the first unknown code.
const format_bfloat16: c_uint = 5;

const status_ok: c_int = 0;
const status_unsupported: c_int = 1;
const status_error: c_int = 2;
const status_uncertain: c_int = 3;

const class_normal: c_uint = 0;
const class_subnormal: c_uint = 1;
const class_zero: c_uint = 2;
const class_infinity: c_uint = 3;
const class_qnan: c_uint = 4;

extern fn zmath_testing_mpfr_reference(
    op: [*:0]const u8,
    format: c_uint,
    input_bits: *const u64,
    arity: usize,
    output_bits: *u64,
    output_class: *c_uint,
) c_int;

extern fn zmath_testing_arb_prove_rounding(
    op: [*:0]const u8,
    format: c_uint,
    input_bits: *const u64,
    arity: usize,
    candidate_bits: u64,
    output_class: *c_uint,
) c_int;

test "oracle ABI rejects Q and bfloat16 formats" {
    const input_bits: u64 = 0x0000;
    var output_bits: u64 = 0;
    var output_class: c_uint = 0;

    for ([_]c_uint{ format_q, format_bfloat16 }) |format| {
        try std.testing.expectEqual(
            status_unsupported,
            zmath_testing_mpfr_reference(
                "exp",
                format,
                &input_bits,
                1,
                &output_bits,
                &output_class,
            ),
        );
        try std.testing.expectEqual(
            status_unsupported,
            zmath_testing_arb_prove_rounding(
                "exp",
                format,
                &input_bits,
                1,
                0x3c00,
                &output_class,
            ),
        );
    }
}

test "MPFR exp H positive zero is positive one" {
    const input_bits: u64 = 0x0000;
    var output_bits: u64 = 0;
    var output_class: c_uint = 0;

    try std.testing.expectEqual(
        status_ok,
        zmath_testing_mpfr_reference(
            "exp",
            format_h,
            &input_bits,
            1,
            &output_bits,
            &output_class,
        ),
    );
    try std.testing.expectEqual(@as(u64, 0x3c00), output_bits);
    try std.testing.expectEqual(class_normal, output_class);
}

test "MPFR log H positive zero is negative infinity" {
    const input_bits: u64 = 0x0000;
    var output_bits: u64 = 0;
    var output_class: c_uint = 0;

    try std.testing.expectEqual(
        status_ok,
        zmath_testing_mpfr_reference(
            "log",
            format_h,
            &input_bits,
            1,
            &output_bits,
            &output_class,
        ),
    );
    try std.testing.expectEqual(@as(u64, 0xfc00), output_bits);
    try std.testing.expectEqual(class_infinity, output_class);
}

test "Arb proves exact H exp zero candidate" {
    const input_bits: u64 = 0x0000;
    var output_class: c_uint = 0;
    try std.testing.expectEqual(
        status_ok,
        zmath_testing_arb_prove_rounding(
            "exp",
            format_h,
            &input_bits,
            1,
            0x3c00,
            &output_class,
        ),
    );
    try std.testing.expectEqual(class_normal, output_class);
}

test "Arb applies exact policy to H log domain specials" {
    const cases = [_]struct {
        input_bits: u64,
        candidate_bits: u64,
        output_class: c_uint,
    }{
        .{ .input_bits = 0x0000, .candidate_bits = 0xfc00, .output_class = class_infinity },
        .{ .input_bits = 0x8000, .candidate_bits = 0xfc00, .output_class = class_infinity },
        .{ .input_bits = 0xbc00, .candidate_bits = 0x7e00, .output_class = class_qnan },
        .{ .input_bits = 0x3c00, .candidate_bits = 0x0000, .output_class = class_zero },
    };

    for (cases) |case| {
        var input_bits = case.input_bits;
        var output_class: c_uint = 0;
        try std.testing.expectEqual(
            status_ok,
            zmath_testing_arb_prove_rounding(
                "log",
                format_h,
                &input_bits,
                1,
                case.candidate_bits,
                &output_class,
            ),
        );
        try std.testing.expectEqual(case.output_class, output_class);
    }
}

test "bridge rejects suffixed unsupported operation names" {
    const input_bits: u64 = 0x3c00;
    var output_bits: u64 = 0;
    var output_class: c_uint = 0;
    const unsupported_operations = [_][*:0]const u8{ "logd", "sinf", "sind" };

    for (unsupported_operations) |operation| {
        try std.testing.expectEqual(
            status_unsupported,
            zmath_testing_mpfr_reference(
                operation,
                format_h,
                &input_bits,
                1,
                &output_bits,
                &output_class,
            ),
        );
        try std.testing.expectEqual(
            status_unsupported,
            zmath_testing_arb_prove_rounding(
                operation,
                format_h,
                &input_bits,
                1,
                0x3c00,
                &output_class,
            ),
        );
    }
}

test "bridge rejects malformed arity and out of range bits" {
    const input_bits: u64 = 0x0000;
    const second_input_bits: u64 = 0x1_0000;
    var output_bits: u64 = 0;
    var output_class: c_uint = 0;
    try std.testing.expectEqual(
        status_error,
        zmath_testing_mpfr_reference(
            "exp",
            format_h,
            &input_bits,
            2,
            &output_bits,
            &output_class,
        ),
    );
    try std.testing.expectEqual(
        status_error,
        zmath_testing_mpfr_reference(
            "exp",
            format_h,
            &second_input_bits,
            1,
            &output_bits,
            &output_class,
        ),
    );
}

test "MPFR unary exp one has exact H F D outputs" {
    const input_bits = [_]u64{
        0x3c00,
        0x3f80_0000,
        0x3ff0_0000_0000_0000,
    };
    const expected_bits = [_]u64{
        0x4170,
        0x402d_f854,
        0x4005_bf0a_8b14_5769,
    };
    const formats = [_]c_uint{ format_h, format_f, format_d };
    var output_bits: u64 = 0;
    var output_class: c_uint = 0;

    for (formats, input_bits, expected_bits) |format, input, expected| {
        try std.testing.expectEqual(
            status_ok,
            zmath_testing_mpfr_reference(
                "exp",
                format,
                &input,
                1,
                &output_bits,
                &output_class,
            ),
        );
        try std.testing.expectEqual(expected, output_bits);
        try std.testing.expectEqual(class_normal, output_class);
    }
}

test "bridge preserves signed zero and quiets NaN payloads" {
    const negative_zero = [_]u64{ 0x8000, 0x8000_0000, 0x8000_0000_0000_0000 };
    const expected_sine_zero = negative_zero;
    const formats = [_]c_uint{ format_h, format_f, format_d };
    var output_bits: u64 = 0;
    var output_class: c_uint = 0;

    for (formats, negative_zero, expected_sine_zero) |format, input, expected| {
        try std.testing.expectEqual(
            status_ok,
            zmath_testing_mpfr_reference(
                "sin",
                format,
                &input,
                1,
                &output_bits,
                &output_class,
            ),
        );
        try std.testing.expectEqual(expected, output_bits);
        try std.testing.expectEqual(class_zero, output_class);
    }

    const nan_inputs = [_]u64{ 0x7d01, 0x7f80_0001, 0x7ff0_0000_0000_0001 };
    const quiet_nan_outputs = [_]u64{ 0x7f01, 0x7fc0_0001, 0x7ff8_0000_0000_0001 };
    for (formats, nan_inputs, quiet_nan_outputs) |format, input, expected| {
        try std.testing.expectEqual(
            status_ok,
            zmath_testing_mpfr_reference(
                "exp",
                format,
                &input,
                1,
                &output_bits,
                &output_class,
            ),
        );
        try std.testing.expectEqual(expected, output_bits);
        try std.testing.expectEqual(class_qnan, output_class);
    }
}

test "Arb rejects candidate disagreement" {
    const input_bits: u64 = 0;
    var output_class: c_uint = 0;
    try std.testing.expectEqual(
        status_uncertain,
        zmath_testing_arb_prove_rounding(
            "exp",
            format_h,
            &input_bits,
            1,
            0x3c01,
            &output_class,
        ),
    );
}

test "Arb proves finite H F D exp overflow candidates" {
    const cases = [_]struct {
        format: c_uint,
        input_bits: u64,
        candidate_bits: u64,
        output_class: c_uint,
    }{
        .{
            .format = format_h,
            .input_bits = 0x498c,
            .candidate_bits = 0x7c00,
            .output_class = class_infinity,
        },
        .{
            .format = format_f,
            .input_bits = 0x42b1_7218,
            .candidate_bits = 0x7f80_0000,
            .output_class = class_infinity,
        },
        .{
            .format = format_d,
            .input_bits = 0x4086_2e42_fefa_39f0,
            .candidate_bits = 0x7ff0_0000_0000_0000,
            .output_class = class_infinity,
        },
        .{
            .format = format_h,
            .input_bits = 0x7bff,
            .candidate_bits = 0x7c00,
            .output_class = class_infinity,
        },
        .{
            .format = format_f,
            .input_bits = 0x7f7f_ffff,
            .candidate_bits = 0x7f80_0000,
            .output_class = class_infinity,
        },
        .{
            .format = format_d,
            .input_bits = 0x7fef_ffff_ffff_ffff,
            .candidate_bits = 0x7ff0_0000_0000_0000,
            .output_class = class_infinity,
        },
    };

    for (cases) |case| {
        var input_bits = case.input_bits;
        var output_class: c_uint = 0;
        try std.testing.expectEqual(
            status_ok,
            zmath_testing_arb_prove_rounding(
                "exp",
                case.format,
                &input_bits,
                1,
                case.candidate_bits,
                &output_class,
            ),
        );
        try std.testing.expectEqual(case.output_class, output_class);
    }
}

test "Arb proves exp results on both sides of the underflow zero tie" {
    const cases = [_]struct {
        format: c_uint,
        input_bits: u64,
        candidate_bits: u64,
        output_class: c_uint,
    }{
        .{ .format = format_h, .input_bits = 0xcc55, .candidate_bits = 0x0001, .output_class = class_subnormal },
        .{ .format = format_h, .input_bits = 0xcc56, .candidate_bits = 0x0000, .output_class = class_zero },
        .{ .format = format_f, .input_bits = 0xc2cf_f1b4, .candidate_bits = 0x0000_0001, .output_class = class_subnormal },
        .{ .format = format_f, .input_bits = 0xc2cf_f1b5, .candidate_bits = 0x0000_0000, .output_class = class_zero },
        .{
            .format = format_d,
            .input_bits = 0xc087_4910_d52d_3051,
            .candidate_bits = 0x0000_0000_0000_0001,
            .output_class = class_subnormal,
        },
        .{
            .format = format_d,
            .input_bits = 0xc087_4910_d52d_3052,
            .candidate_bits = 0x0000_0000_0000_0000,
            .output_class = class_zero,
        },
    };

    for (cases) |case| {
        var input_bits = case.input_bits;
        var output_class: c_uint = 0;
        try std.testing.expectEqual(
            status_ok,
            zmath_testing_arb_prove_rounding(
                "exp",
                case.format,
                &input_bits,
                1,
                case.candidate_bits,
                &output_class,
            ),
        );
        try std.testing.expectEqual(case.output_class, output_class);
    }
}

test "Arb keeps incorrect exp overflow-edge candidates uncertain" {
    const cases = [_]struct {
        format: c_uint,
        input_bits: u64,
        candidate_bits: u64,
    }{
        .{ .format = format_h, .input_bits = 0x498b, .candidate_bits = 0x7c00 },
        .{ .format = format_h, .input_bits = 0x498c, .candidate_bits = 0x7bff },
        .{ .format = format_f, .input_bits = 0x42b1_7217, .candidate_bits = 0x7f80_0000 },
        .{ .format = format_f, .input_bits = 0x42b1_7218, .candidate_bits = 0x7f7f_ffff },
        .{
            .format = format_d,
            .input_bits = 0x4086_2e42_fefa_39ef,
            .candidate_bits = 0x7ff0_0000_0000_0000,
        },
        .{
            .format = format_d,
            .input_bits = 0x4086_2e42_fefa_39f0,
            .candidate_bits = 0x7fef_ffff_ffff_ffff,
        },
    };

    for (cases) |case| {
        var input_bits = case.input_bits;
        var output_class: c_uint = class_qnan;
        try std.testing.expectEqual(
            status_uncertain,
            zmath_testing_arb_prove_rounding(
                "exp",
                case.format,
                &input_bits,
                1,
                case.candidate_bits,
                &output_class,
            ),
        );
        try std.testing.expectEqual(class_qnan, output_class);
    }
}
