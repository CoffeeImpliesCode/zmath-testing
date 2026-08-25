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

test "Arb accepts or cannot prove valid H exp candidate" {
    const input_bits: u64 = 0x0000;
    var output_class: c_uint = 0;
    const status = zmath_testing_arb_prove_rounding(
        "exp",
        format_h,
        &input_bits,
        1,
        0x3c00,
        &output_class,
    );

    try std.testing.expect(status == status_ok or status == status_uncertain);
    if (status == status_ok) {
        try std.testing.expectEqual(class_normal, output_class);
    }
}

test "MPFR unary decoding and target conversion cover H F D" {
    const input_bits: u64 = 0;
    var output_bits: u64 = 0;
    var output_class: c_uint = 0;
    const expected_bits = [_]u64{
        0x3c00,
        0x3f80_0000,
        0x3ff0_0000_0000_0000,
    };
    const formats = [_]c_uint{ format_h, format_f, format_d };

    for (formats, expected_bits) |format, expected| {
        try std.testing.expectEqual(
            status_ok,
            zmath_testing_mpfr_reference(
                "exp",
                format,
                &input_bits,
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

test "Arb rejects an uncertain overflow rounding boundary" {
    const input_bits: u64 = 0x7bff;
    var output_class: c_uint = 0;
    try std.testing.expectEqual(
        status_uncertain,
        zmath_testing_arb_prove_rounding(
            "exp",
            format_h,
            &input_bits,
            1,
            0x7c00,
            &output_class,
        ),
    );
}

test "MPFR decodes finite unary H F D values" {
    const inputs = [_]u64{
        0x3c00,
        0x3f80_0000,
        0x3ff0_0000_0000_0000,
    };
    const formats = [_]c_uint{ format_h, format_f, format_d };
    var output_bits: u64 = 0;
    var output_class: c_uint = 0;
    for (formats, inputs) |format, input| {
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
        try std.testing.expectEqual(class_normal, output_class);
        try std.testing.expect(output_bits != 0);
    }
}
