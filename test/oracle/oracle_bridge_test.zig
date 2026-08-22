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
