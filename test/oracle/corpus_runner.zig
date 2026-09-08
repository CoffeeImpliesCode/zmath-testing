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

fn runAcceptedArtifacts(
    active_target_mode: ?corpus.TargetMode,
    embedded_target_mode: ?corpus.TargetMode,
    artifacts: []const corpus.EmbeddedArtifact,
) DifferentialError!void {
    if (artifacts.len == 0) return;

    const active_mode = active_target_mode orelse return error.TargetModeMissing;
    const manifest = corpus.parseEmbeddedManifest() catch return error.ManifestUnsupported;
    const embedded_mode = embedded_target_mode orelse return error.TargetModeMissing;
    if (!embedded_mode.eql(active_mode)) return error.TargetModeMismatch;
    for (artifacts) |embedded_artifact| {
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

pub fn runAccepted(active_target_mode: ?corpus.TargetMode) DifferentialError!void {
    if (embedded.artifacts.len == 0) return;
    comptime {
        if (embedded.artifacts.len != 0 and !active_build.approved_corpus_pair) {
            @compileError(
                "accepted corpus requires target x86_64-linux-gnu.2.38, CPU haswell, mode ReleaseSafe",
            );
        }
    }
    return runAcceptedArtifacts(
        active_target_mode,
        embedded.target_mode,
        embedded.artifacts[0..],
    );
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
// This helper is an exploratory Exp campaign only; it never loads accepted rows.
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

fn activeTargetModeForTest() corpus.TargetMode {
    return .{
        .target = active_build.target,
        .cpu = active_build.cpu,
        .mode = active_build.mode,
    };
}

fn embeddedArtifactForTest(name: []const u8) ?corpus.EmbeddedArtifact {
    for (embedded.artifacts) |artifact| {
        const metadata = artifact.metadata orelse continue;
        if (std.mem.eql(u8, metadata.artifact_name, name)) return artifact;
    }
    return null;
}

test "stored rows reject wrong finite and special bits and classes" {
    try std.testing.expectError(error.RuntimeMismatch, runStoredRow(.{
        .operation = .exp,
        .format = .h,
        .input_bits = 0x0000,
        .output_bits = 0x3c01,
        .output_class = .normal,
        .max_ulp = 0,
    }));
    try std.testing.expectError(error.RuntimeClassMismatch, runStoredRow(.{
        .operation = .exp,
        .format = .h,
        .input_bits = 0x0000,
        .output_bits = 0x3c00,
        .output_class = .zero,
        .max_ulp = 0,
    }));
    try std.testing.expectError(error.RuntimeMismatch, runStoredRow(.{
        .operation = .exp,
        .format = .h,
        .input_bits = 0x7c01,
        .output_bits = 0x7e02,
        .output_class = .qnan,
        .max_ulp = 0,
    }));
    try std.testing.expectError(error.StoredClassMismatch, runStoredRow(.{
        .operation = .exp,
        .format = .h,
        .input_bits = 0x7c01,
        .output_bits = 0x7e01,
        .output_class = .snan,
        .max_ulp = 0,
    }));
}

test "accepted replay rejects missing and wrong target metadata" {
    const artifact = embeddedArtifactForTest("test/corpus/exp_f.tsv") orelse
        return error.SkipZigTest;
    const active_mode = activeTargetModeForTest();
    const one_artifact = [_]corpus.EmbeddedArtifact{artifact};
    try std.testing.expectError(
        error.TargetModeMissing,
        runAcceptedArtifacts(active_mode, null, one_artifact[0..]),
    );
    try std.testing.expectError(
        error.TargetModeMissing,
        runAcceptedArtifacts(null, embedded.target_mode, one_artifact[0..]),
    );

    const missing_metadata = [_]corpus.EmbeddedArtifact{.{
        .source = artifact.source,
        .metadata = null,
    }};
    try std.testing.expectError(
        error.TargetModeMissing,
        runAcceptedArtifacts(
            active_mode,
            embedded.target_mode,
            missing_metadata[0..],
        ),
    );

    var wrong_metadata = artifact.metadata.?;
    wrong_metadata.target_mode.cpu = "baseline";
    const wrong_target = [_]corpus.EmbeddedArtifact{.{
        .source = artifact.source,
        .metadata = wrong_metadata,
    }};
    try std.testing.expectError(
        error.TargetModeMismatch,
        runAcceptedArtifacts(
            active_mode,
            embedded.target_mode,
            wrong_target[0..],
        ),
    );
}

test "accepted replay rejects a wrong artifact ULP" {
    const artifact = embeddedArtifactForTest("test/corpus/exp_f.tsv") orelse
        return error.SkipZigTest;
    const source = try std.testing.allocator.dupe(u8, artifact.source);
    defer std.testing.allocator.free(source);
    const max_ulp_marker = std.mem.indexOf(u8, source, "\t0\n") orelse
        @panic("exp/f fixture has no zero-ULP row");
    source[max_ulp_marker + 1] = '1';
    const wrong_ulp = [_]corpus.EmbeddedArtifact{.{
        .source = source,
        .metadata = artifact.metadata,
    }};
    try std.testing.expectError(
        error.ArtifactRejected,
        runAcceptedArtifacts(
            activeTargetModeForTest(),
            embedded.target_mode,
            wrong_ulp[0..],
        ),
    );
}

test "differential execution fails closed on oracle errors" {
    try std.testing.expectError(error.OracleError, run(.exp, .h, 0x1_0000));
}

test "differential execution proves finite overflow results" {
    try run(.exp, .h, 0x7bff);
}

test "unsupported sin formats do not dispatch" {
    try std.testing.expectError(error.ManifestUnsupported, run(.sin, .f, 0));
    try std.testing.expectError(error.ManifestUnsupported, run(.sin, .d, 0));
}

test "unsupported log d format does not dispatch" {
    try std.testing.expectError(error.ManifestUnsupported, run(.log, .d, 0));
}
