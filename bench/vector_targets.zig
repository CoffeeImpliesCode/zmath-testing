//! Self-contained registry of vector benchmark targets.
//!
//! This module mirrors the shape of `bench/targets.zig` but stays independent of
//! it, so the scalar target registry consumed by `build.zig` keeps its exact
//! `Descriptor` shape, `all` array, and comptime guards.
//!
//! Every registered target names an already published corpus fixture under
//! `test/corpus/` and carries the real SHA-256 that the scalar registry records
//! for the same fixture. A target is registered only when both a published
//! corpus and a `zmath.vector` entry point exist for it.
//!
//! `lane_width` is the number of corpus records packed into one `@Vector` lane
//! group. It defaults to 1 so a descriptor can never silently record zero.
//!
//! The registry is descriptive. It records no correctness claim and grants no
//! manifest acceptance.

const std = @import("std");

pub const Operation = enum {
    exp,
    log,
    sin,
};

pub const Format = enum {
    h,
    f,
    d,
};

/// Approved corpus profile. The vector benchmark refuses to measure anything
/// outside this triple, exactly as the scalar benchmark does.
pub const approved_corpus_target = "x86_64-linux-gnu.2.38";
pub const approved_corpus_cpu = "haswell";
pub const approved_corpus_mode = "ReleaseSafe";

/// Lanes packed per `@Vector` for each format. binary16 and binary32 fill a
/// 128-bit group, binary64 fills a 256-bit group.
pub fn laneWidthFor(format: Format) u32 {
    return switch (format) {
        .h, .f => 8,
        .d => 4,
    };
}

pub const VectorDescriptor = struct {
    name: []const u8,
    corpus_id: []const u8,
    corpus_path: []const u8,
    operation: Operation,
    format: Format,
    /// Corpus records packed into one `@Vector` lane group. Defaults to 1 so a
    /// descriptor can never silently record zero lanes.
    lane_width: u32 = 1,
    /// Rows in the historical TSV fixture. This is not the schema-3 publication
    /// record count, which the benchmark revalidates from the artifact digest.
    input_count: usize,
    operation_count: u64,
    corpus_sha256: []const u8,
    corpus_target: []const u8 = approved_corpus_target,
    corpus_cpu: []const u8 = approved_corpus_cpu,
    corpus_mode: []const u8 = approved_corpus_mode,
};

const repetitions: u64 = 16_384;

pub const vector_exp_h: VectorDescriptor = .{
    .name = "vector-exp-h",
    .corpus_id = "exp/h",
    .corpus_path = "test/corpus/exp_h.tsv",
    .operation = .exp,
    .format = .h,
    .lane_width = 8,
    .input_count = 65_536,
    .operation_count = 65_536 * repetitions,
    .corpus_sha256 = "8cdb9a218b9f39d0360979dc4611dd75e76dbd587131df51585fd61f8cb955de",
};

pub const vector_exp_f: VectorDescriptor = .{
    .name = "vector-exp-f",
    .corpus_id = "exp/f",
    .corpus_path = "test/corpus/exp_f.tsv",
    .operation = .exp,
    .format = .f,
    .lane_width = 8,
    .input_count = 29,
    .operation_count = 29 * repetitions,
    .corpus_sha256 = "24e61b7dd6b49fe5b1b18071810f887e2f79d6c1e7b5a3827f36c127278b4b76",
};

pub const vector_exp_d: VectorDescriptor = .{
    .name = "vector-exp-d",
    .corpus_id = "exp/d",
    .corpus_path = "test/corpus/exp_d.tsv",
    .operation = .exp,
    .format = .d,
    .lane_width = 4,
    .input_count = 182,
    .operation_count = 182 * repetitions,
    .corpus_sha256 = "cf2223e488905f0a427ec3bd19c39ab515ebedb74739cfd893adcaf734f744ae",
};

pub const vector_log_h: VectorDescriptor = .{
    .name = "vector-log-h",
    .corpus_id = "log/h",
    .corpus_path = "test/corpus/log_h.tsv",
    .operation = .log,
    .format = .h,
    .lane_width = 8,
    .input_count = 65_536,
    .operation_count = 1_048_576,
    .corpus_sha256 = "55ee40b00ef9ce039e8af197673cec9037e34069d74cbe01815c9a6a52b71e12",
};

pub const vector_log_f: VectorDescriptor = .{
    .name = "vector-log-f",
    .corpus_id = "log/f",
    .corpus_path = "test/corpus/log_f.tsv",
    .operation = .log,
    .format = .f,
    .lane_width = 8,
    .input_count = 64,
    .operation_count = 1_048_576,
    .corpus_sha256 = "7ba725bff8df9b746ebe8f455ebaf018e60d7fbc0d904f20e102b203e63f2315",
};

pub const vector_sin_h: VectorDescriptor = .{
    .name = "vector-sin-h",
    .corpus_id = "sin/h",
    .corpus_path = "test/corpus/sin_h.tsv",
    .operation = .sin,
    .format = .h,
    .lane_width = 8,
    .input_count = 65_536,
    .operation_count = 1_048_576,
    .corpus_sha256 = "36f633026e39df001a4126cf5729050bc868232b99e6d18a1e2b412474447bc8",
};

pub const all = [_]VectorDescriptor{
    vector_exp_h,
    vector_exp_f,
    vector_exp_d,
    vector_log_h,
    vector_log_f,
    vector_sin_h,
};

pub const ParseError = error{
    UnknownBenchmarkTarget,
    InvalidBenchmarkDescriptor,
};

pub fn validate(descriptor: VectorDescriptor) ParseError!void {
    if (descriptor.name.len == 0 or descriptor.corpus_id.len == 0) {
        return error.InvalidBenchmarkDescriptor;
    }
    if (descriptor.corpus_path.len == 0 or
        !std.mem.startsWith(u8, descriptor.corpus_path, "test/corpus/"))
    {
        return error.InvalidBenchmarkDescriptor;
    }
    if (descriptor.lane_width == 0) return error.InvalidBenchmarkDescriptor;
    if (descriptor.lane_width != laneWidthFor(descriptor.format)) {
        return error.InvalidBenchmarkDescriptor;
    }
    if (descriptor.input_count == 0 or descriptor.operation_count == 0 or
        descriptor.operation_count % descriptor.input_count != 0)
    {
        return error.InvalidBenchmarkDescriptor;
    }
    if (descriptor.corpus_sha256.len != 64) return error.InvalidBenchmarkDescriptor;

    for (descriptor.corpus_sha256) |char| {
        if (!((char >= '0' and char <= '9') or
            (char >= 'a' and char <= 'f')))
        {
            return error.InvalidBenchmarkDescriptor;
        }
    }

    if (!std.mem.eql(u8, descriptor.corpus_target, approved_corpus_target) or
        !std.mem.eql(u8, descriptor.corpus_cpu, approved_corpus_cpu) or
        !std.mem.eql(u8, descriptor.corpus_mode, approved_corpus_mode))
    {
        return error.InvalidBenchmarkDescriptor;
    }

    // The corpus id and the file name must both name the same published
    // fixture, so a descriptor cannot point at one operation and another file.
    var expected_id_buffer: [16]u8 = undefined;
    const expected_id = std.fmt.bufPrint(
        &expected_id_buffer,
        "{s}/{s}",
        .{ @tagName(descriptor.operation), @tagName(descriptor.format) },
    ) catch return error.InvalidBenchmarkDescriptor;
    if (!std.mem.eql(u8, descriptor.corpus_id, expected_id)) {
        return error.InvalidBenchmarkDescriptor;
    }

    var expected_path_buffer: [64]u8 = undefined;
    const expected_path = std.fmt.bufPrint(
        &expected_path_buffer,
        "test/corpus/{s}_{s}.tsv",
        .{ @tagName(descriptor.operation), @tagName(descriptor.format) },
    ) catch return error.InvalidBenchmarkDescriptor;
    if (!std.mem.eql(u8, descriptor.corpus_path, expected_path)) {
        return error.InvalidBenchmarkDescriptor;
    }
}

pub fn parse(name: []const u8) ParseError!*const VectorDescriptor {
    for (&all) |*descriptor| {
        if (!std.mem.eql(u8, name, descriptor.name)) continue;
        try validate(descriptor.*);
        return descriptor;
    }
    return error.UnknownBenchmarkTarget;
}

/// Returns the descriptor registered for one manifest operation and format, or
/// null when the pair has no published corpus behind it.
pub fn lookup(operation: []const u8, format: Format) ?*const VectorDescriptor {
    for (&all) |*descriptor| {
        if (!std.mem.eql(u8, @tagName(descriptor.operation), operation)) continue;
        if (descriptor.format != format) continue;
        validate(descriptor.*) catch continue;
        return descriptor;
    }
    return null;
}

comptime {
    for (all) |descriptor| {
        validate(descriptor) catch @compileError("invalid vector benchmark descriptor");
    }
}

test "vector target parser rejects unknown targets" {
    try std.testing.expectError(error.UnknownBenchmarkTarget, parse("vector-exp-x"));
}

test "vector target parser rejects a zero lane width" {
    var invalid = vector_exp_h;
    invalid.lane_width = 0;
    try std.testing.expectError(error.InvalidBenchmarkDescriptor, validate(invalid));
}

test "vector target parser rejects a lane width that disagrees with the format" {
    var invalid = vector_exp_d;
    invalid.lane_width = 8;
    try std.testing.expectError(error.InvalidBenchmarkDescriptor, validate(invalid));
}

test "vector target parser rejects a non-approved profile" {
    var invalid = vector_log_h;
    invalid.corpus_cpu = "baseline";
    try std.testing.expectError(error.InvalidBenchmarkDescriptor, validate(invalid));
}

test "vector target parser rejects an operation count that is not a repetition" {
    var invalid = vector_log_f;
    invalid.operation_count += 1;
    try std.testing.expectError(error.InvalidBenchmarkDescriptor, validate(invalid));
}
