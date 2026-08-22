const std = @import("std");
const corpus = @import("corpus_support");
const zmath = @import("zmath");

const oracle_status_ok: c_int = 0;
const oracle_status_unsupported: c_int = 1;
const oracle_status_error: c_int = 2;
const oracle_status_uncertain: c_int = 3;

const oracle_class_normal: c_uint = 0;
const oracle_class_subnormal: c_uint = 1;
const oracle_class_zero: c_uint = 2;
const oracle_class_infinity: c_uint = 3;
const oracle_class_qnan: c_uint = 4;

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

const DifferentialError = error{
    ManifestUnsupported,
    OracleUnsupported,
    OracleError,
    OracleUncertain,
    RuntimeMismatch,
    ArbProofMismatch,
};

fn bridgeFormat(format: corpus.Format) c_uint {
    return @as(c_uint, @intFromEnum(format)) + 1;
}

fn isFiniteClass(output_class: c_uint) bool {
    return output_class == oracle_class_normal or
        output_class == oracle_class_subnormal or
        output_class == oracle_class_zero;
}

fn runRuntime(
    operation: corpus.Operation,
    format: corpus.Format,
    input_bits: u64,
) DifferentialError!u64 {
    return switch (operation) {
        .exp => switch (format) {
            .h => @as(
                u64,
                @intCast(@as(u16, @bitCast(zmath.scalar.exph(@bitCast(@as(u16, @truncate(input_bits))))))),
            ),
            .f => @as(
                u64,
                @intCast(@as(u32, @bitCast(zmath.scalar.expf(@bitCast(@as(u32, @truncate(input_bits))))))),
            ),
            .d => @bitCast(zmath.scalar.expd(@bitCast(input_bits))),
        },
        // The manifest operation is "sin"; the public zmath symbol is scalar.sinh
        // because the implementation is the CORE-MATH binary16 sine routine.
        .sin => switch (format) {
            .h => @as(
                u64,
                @intCast(@as(u16, @bitCast(zmath.scalar.sinh(@bitCast(@as(u16, @truncate(input_bits))))))),
            ),
            .f, .d => error.ManifestUnsupported,
        },
        .log => switch (format) {
            .h => @as(
                u64,
                @intCast(@as(u16, @bitCast(zmath.scalar.logh(@bitCast(@as(u16, @truncate(input_bits))))))),
            ),
            .f, .d => error.ManifestUnsupported,
        },
    };
}

fn operationName(operation: corpus.Operation) [*:0]const u8 {
    return switch (operation) {
        .exp => "exp",
        .log => "log",
        .sin => "sin",
    };
}

pub fn run(
    operation: corpus.Operation,
    format: corpus.Format,
    input_bits: u64,
) DifferentialError!void {
    const manifest = corpus.parseEmbeddedManifest() catch return error.ManifestUnsupported;
    const status = manifest.functionStatus(operation, format) orelse return error.ManifestUnsupported;
    if (status != .correct) return error.ManifestUnsupported;

    const runtime_bits = try runRuntime(operation, format, input_bits);
    var input_word = input_bits;
    var expected_bits: u64 = 0;
    var expected_class: c_uint = 0;
    const operation_name = operationName(operation);
    const mpfr_status = zmath_testing_mpfr_reference(
        operation_name,
        bridgeFormat(format),
        &input_word,
        1,
        &expected_bits,
        &expected_class,
    );
    if (mpfr_status == oracle_status_unsupported) return error.OracleUnsupported;
    if (mpfr_status == oracle_status_error) return error.OracleError;
    if (mpfr_status == oracle_status_uncertain) return error.OracleUncertain;
    if (mpfr_status != oracle_status_ok) return error.OracleError;
    if (runtime_bits != expected_bits) return error.RuntimeMismatch;

    var proof_class: c_uint = 0;
    const arb_status = zmath_testing_arb_prove_rounding(
        operation_name,
        bridgeFormat(format),
        &input_word,
        1,
        runtime_bits,
        &proof_class,
    );
    if (isFiniteClass(expected_class)) {
        if (arb_status == oracle_status_unsupported) return error.OracleUnsupported;
        if (arb_status == oracle_status_error) return error.OracleError;
        if (arb_status == oracle_status_uncertain) return error.OracleUncertain;
        if (arb_status != oracle_status_ok) return error.OracleError;
        if (proof_class != expected_class) return error.ArbProofMismatch;
    }
}

pub fn runExp(format: corpus.Format, input_bits: u64) DifferentialError!void {
    return run(.exp, format, input_bits);
}

fn nextPrng(state: *u64) u64 {
    var value = state.*;
    value ^= value << 13;
    value ^= value >> 7;
    value ^= value << 17;
    state.* = value;
    return value;
}

const f_boundary_bits = [_]u32{
    0x0000_0000,
    0x0000_0001,
    0x0000_0002,
    0x007f_ffff,
    0x0080_0000,
    0x3f7f_ffff,
    0x3f80_0000,
    0x3f80_0001,
    0x7f7f_ffff,
    0x7f80_0000,
    0x7f80_0001,
    0x7fc0_0000,
    0x8000_0000,
    0x807f_ffff,
    0x8080_0000,
    0xff80_0000,
    0xff80_0001,
    0xffc0_0000,
};

const d_boundary_bits = [_]u64{
    0x0000_0000_0000_0000,
    0x0000_0000_0000_0001,
    0x0000_0000_0000_0002,
    0x000f_ffff_ffff_ffff,
    0x0010_0000_0000_0000,
    0x3fef_ffff_ffff_ffff,
    0x3ff0_0000_0000_0000,
    0x3ff0_0000_0000_0001,
    0x7fef_ffff_ffff_ffff,
    0x7ff0_0000_0000_0000,
    0x7ff0_0000_0000_0001,
    0x7ff8_0000_0000_0000,
    0x8000_0000_0000_0000,
    0x800f_ffff_ffff_ffff,
    0x8010_0000_0000_0000,
    0xfff0_0000_0000_0000,
    0xfff0_0000_0000_0001,
    0xfff8_0000_0000_0000,
};

pub fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    const h_bits = smith.value(u16);
    const f_bits = smith.value(u32);
    const d_bits = smith.value(u64);
    try runExp(.h, h_bits);
    try runExp(.f, f_bits);
    try runExp(.d, d_bits);
}

test "embedded nearest-even exp differential campaign" {
    try corpus.validateEmbeddedManifest();
    var h_bits: u32 = 0;
    while (h_bits < 0x1_0000) : (h_bits += 1) {
        try runExp(.h, h_bits);
    }

    for (f_boundary_bits) |bits| try runExp(.f, bits);
    for (d_boundary_bits) |bits| try runExp(.d, bits);

    var f_state: u64 = 0x9e37_79b9_7f4a_7c15 ^ @as(u64, std.testing.random_seed);
    var f_index: usize = 0;
    while (f_index < 4096) : (f_index += 1) {
        try runExp(.f, @as(u64, @as(u32, @truncate(nextPrng(&f_state)))));
    }

    var d_state: u64 = 0xd1b5_4a32_d192_ed03 ^ @as(u64, std.testing.random_seed);
    var d_index: usize = 0;
    while (d_index < 4096) : (d_index += 1) {
        try runExp(.d, nextPrng(&d_state));
    }
}

test "embedded nearest-even binary16 sin differential campaign" {
    try corpus.validateEmbeddedManifest();
    var input_bits: u32 = 0;
    while (input_bits < 0x1_0000) : (input_bits += 1) {
        try run(.sin, .h, input_bits);
    }
    try std.testing.expectEqual(@as(u32, 0x1_0000), input_bits);
}
test "unsupported sin formats do not dispatch" {
    try std.testing.expectError(error.ManifestUnsupported, run(.sin, .f, 0));
    try std.testing.expectError(error.ManifestUnsupported, run(.sin, .d, 0));
}

test "logh exhaustive oracle campaign checks 65536 inputs" {
    try corpus.validateEmbeddedManifest();
    var input_bits: u32 = 0;
    while (input_bits < 0x1_0000) : (input_bits += 1) {
        try run(.log, .h, input_bits);
    }
    try std.testing.expectEqual(@as(u32, 0x1_0000), input_bits);
}

test "unsupported log formats do not dispatch" {
    try std.testing.expectError(error.ManifestUnsupported, run(.log, .f, 0));
    try std.testing.expectError(error.ManifestUnsupported, run(.log, .d, 0));
}
