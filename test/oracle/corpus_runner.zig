const std = @import("std");
const corpus = @import("corpus_support");
const embedded = @import("corpus_artifacts");
const active_build = @import("active_target_mode");
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
    ArtifactRejected,
    TargetModeMissing,
    TargetModeMismatch,
    OracleUnsupported,
    OracleError,
    OracleUncertain,
    RuntimeMismatch,
    RuntimeClassMismatch,
    StoredMismatch,
    StoredClassMismatch,
    ArbProofMismatch,
};

fn bridgeFormat(format: corpus.Format) c_uint {
    return @as(c_uint, @intFromEnum(format)) + 1;
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
            .f => @as(
                u64,
                @intCast(@as(u32, @bitCast(zmath.scalar.logf(@bitCast(@as(u32, @truncate(input_bits))))))),
            ),
            .d => error.ManifestUnsupported,
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

fn classFromBits(format: corpus.Format, bits: u64) c_uint {
    const exponent_mask: u64 = switch (format) {
        .h => 0x7c00,
        .f => 0x7f80_0000,
        .d => 0x7ff0_0000_0000_0000,
    };
    const fraction_mask: u64 = switch (format) {
        .h => 0x03ff,
        .f => 0x007f_ffff,
        .d => 0x000f_ffff_ffff_ffff,
    };
    const exponent = (bits & exponent_mask) >> switch (format) {
        .h => 10,
        .f => 23,
        .d => 52,
    };
    const exponent_all: u64 = switch (format) {
        .h => 0x1f,
        .f => 0xff,
        .d => 0x7ff,
    };
    const fraction = bits & fraction_mask;
    if (exponent == 0) {
        return if (fraction == 0) oracle_class_zero else oracle_class_subnormal;
    }
    if (exponent == exponent_all) {
        return if (fraction == 0) oracle_class_infinity else oracle_class_qnan;
    }
    return oracle_class_normal;
}

fn bridgeClass(output_class: corpus.OutputClass) DifferentialError!c_uint {
    return switch (output_class) {
        .normal => oracle_class_normal,
        .subnormal => oracle_class_subnormal,
        .zero => oracle_class_zero,
        .infinity => oracle_class_infinity,
        .qnan => oracle_class_qnan,
        .snan => error.StoredClassMismatch,
    };
}

fn isFiniteOutputClass(output_class: c_uint) bool {
    return output_class == oracle_class_normal or
        output_class == oracle_class_subnormal or
        output_class == oracle_class_zero;
}

fn checkOracleStatus(status: c_int) DifferentialError!void {
    if (status == oracle_status_unsupported) return error.OracleUnsupported;
    if (status == oracle_status_error) return error.OracleError;
    if (status == oracle_status_uncertain) return error.OracleUncertain;
    if (status != oracle_status_ok) return error.OracleError;
}

fn runStoredRow(row: corpus.CorpusRow) DifferentialError!void {
    const runtime_bits = try runRuntime(row.operation, row.format, row.input_bits);
    const stored_class = try bridgeClass(row.output_class);
    const runtime_class = classFromBits(row.format, runtime_bits);
    if (runtime_class != stored_class) return error.RuntimeClassMismatch;
    if (runtime_bits != row.output_bits) return error.RuntimeMismatch;

    var input_word = row.input_bits;
    var mpfr_bits: u64 = 0;
    var mpfr_class: c_uint = 0;
    try checkOracleStatus(zmath_testing_mpfr_reference(
        operationName(row.operation),
        bridgeFormat(row.format),
        &input_word,
        1,
        &mpfr_bits,
        &mpfr_class,
    ));
    if (mpfr_bits != row.output_bits) return error.StoredMismatch;
    if (mpfr_class != stored_class) return error.StoredClassMismatch;
    if (isFiniteOutputClass(stored_class)) {
        var proof_class: c_uint = 0;
        try checkOracleStatus(zmath_testing_arb_prove_rounding(
            operationName(row.operation),
            bridgeFormat(row.format),
            &input_word,
            1,
            row.output_bits,
            &proof_class,
        ));
        if (proof_class != stored_class) return error.ArbProofMismatch;
    }
}

pub fn runAccepted(active_target_mode: ?corpus.TargetMode) DifferentialError!void {
    if (embedded.artifacts.len == 0) return;
    comptime {
        if (embedded.artifacts.len != 0 and !active_build.approved_corpus_pair) {
            @compileError(
                "accepted corpus requires target x86_64-linux-gnu.2.38, CPU haswell, mode ReleaseSafe",
            );
        }
    }

    const active_mode = active_target_mode orelse return error.TargetModeMissing;
    const manifest = corpus.parseEmbeddedManifest() catch return error.ManifestUnsupported;
    if (embedded.target_mode) |embedded_mode| {
        if (!embedded_mode.eql(active_mode)) return error.TargetModeMismatch;
    }
    for (embedded.artifacts) |embedded_artifact| {
        const artifact = corpus.loadEmbeddedArtifact(
            &manifest,
            embedded_artifact,
            active_mode,
        ) catch |err| switch (err) {
            error.MissingArtifactMetadata => return error.TargetModeMissing,
            error.UnsupportedTargetMode => return error.TargetModeMismatch,
            else => return error.ArtifactRejected,
        };
        var rows = artifact.rows() catch return error.ArtifactRejected;
        while (rows.next() catch return error.ArtifactRejected) |row| {
            try runStoredRow(row);
        }
    }
}

pub fn run(
    operation: corpus.Operation,
    format: corpus.Format,
    input_bits: u64,
) DifferentialError!void {
    const manifest = corpus.parseEmbeddedManifest() catch return error.ManifestUnsupported;
    const status = manifest.functionStatus(operation, format) orelse return error.ManifestUnsupported;
    if (status == .unsupported) return error.ManifestUnsupported;

    const runtime_bits = try runRuntime(operation, format, input_bits);
    var input_word = input_bits;
    var expected_bits: u64 = 0;
    var expected_class: c_uint = 0;
    try checkOracleStatus(zmath_testing_mpfr_reference(
        operationName(operation),
        bridgeFormat(format),
        &input_word,
        1,
        &expected_bits,
        &expected_class,
    ));
    if (runtime_bits != expected_bits) return error.RuntimeMismatch;

    var proof_class: c_uint = 0;
    try checkOracleStatus(zmath_testing_arb_prove_rounding(
        operationName(operation),
        bridgeFormat(format),
        &input_word,
        1,
        runtime_bits,
        &proof_class,
    ));
    if (proof_class != expected_class) return error.ArbProofMismatch;
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
pub fn fuzzSeeded(seed: u64, sample_count: usize) DifferentialError!void {
    var state = seed;
    var index: usize = 0;
    while (index < sample_count) : (index += 1) {
        try runExp(.h, nextPrng(&state) & 0xffff);
        try runExp(.f, @as(u64, @as(u32, @truncate(nextPrng(&state)))));
        try runExp(.d, nextPrng(&state));
    }
}
pub fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    const h_bits = smith.value(u16);
    const f_bits = smith.value(u32);
    const d_bits = smith.value(u64);
    try runExp(.h, h_bits);
    try runExp(.f, f_bits);
    try runExp(.d, d_bits);
}

test "embedded acceptance replay is deterministic and artifact-driven" {
    try corpus.validateEmbeddedManifest();
    const active_mode: ?corpus.TargetMode = if (embedded.artifacts.len == 0)
        null
    else
        .{
            .target = active_build.target,
            .cpu = active_build.cpu,
            .mode = active_build.mode,
        };
    try runAccepted(active_mode);
}

test "unsupported sin formats do not dispatch" {
    try std.testing.expectError(error.ManifestUnsupported, run(.sin, .f, 0));
    try std.testing.expectError(error.ManifestUnsupported, run(.sin, .d, 0));
}

test "unsupported log d format does not dispatch" {
    try std.testing.expectError(error.ManifestUnsupported, run(.log, .d, 0));
}
