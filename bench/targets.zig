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

pub const Descriptor = struct {
    name: []const u8,
    corpus_id: []const u8,
    corpus_path: []const u8,
    operation: Operation,
    format: Format,
    input_count: usize,
    operation_count: u64,
    corpus_sha256: []const u8,
};

const repetitions: u64 = 16_384;

pub const scalar_exp_h: Descriptor = .{
    .name = "scalar-exp-h",
    .corpus_id = "exp/h",
    .corpus_path = "test/corpus/exp_h.tsv",
    .operation = .exp,
    .format = .h,
    .input_count = 65_536,
    .operation_count = 1_048_576,
    .corpus_sha256 = "8cdb9a218b9f39d0360979dc4611dd75e76dbd587131df51585fd61f8cb955de",
};

pub const scalar_exp_f: Descriptor = .{
    .name = "scalar-exp-f",
    .corpus_id = "exp/f",
    .corpus_path = "test/corpus/exp_f.tsv",
    .operation = .exp,
    .format = .f,
    .input_count = 29,
    .operation_count = 29 * repetitions,
    .corpus_sha256 = "24e61b7dd6b49fe5b1b18071810f887e2f79d6c1e7b5a3827f36c127278b4b76",
};

pub const scalar_exp_d: Descriptor = .{
    .name = "scalar-exp-d",
    .corpus_id = "exp/d",
    .corpus_path = "test/corpus/exp_d.tsv",
    .operation = .exp,
    .format = .d,
    .input_count = 182,
    .operation_count = 182 * repetitions,
    .corpus_sha256 = "cf2223e488905f0a427ec3bd19c39ab515ebedb74739cfd893adcaf734f744ae",
};

pub const scalar_log_h: Descriptor = .{
    .name = "scalar-log-h",
    .corpus_id = "log/h",
    .corpus_path = "test/corpus/log_h.tsv",
    .operation = .log,
    .format = .h,
    .input_count = 65_536,
    .operation_count = 1_048_576,
    .corpus_sha256 = "55ee40b00ef9ce039e8af197673cec9037e34069d74cbe01815c9a6a52b71e12",
};

pub const scalar_log_f: Descriptor = .{
    .name = "scalar-log-f",
    .corpus_id = "log/f",
    .corpus_path = "test/corpus/log_f.tsv",
    .operation = .log,
    .format = .f,
    .input_count = 64,
    .operation_count = 1_048_576,
    .corpus_sha256 = "7ba725bff8df9b746ebe8f455ebaf018e60d7fbc0d904f20e102b203e63f2315",
};

pub const scalar_sin_h: Descriptor = .{
    .name = "scalar-sin-h",
    .corpus_id = "sin/h",
    .corpus_path = "test/corpus/sin_h.tsv",
    .operation = .sin,
    .format = .h,
    .input_count = 65_536,
    .operation_count = 1_048_576,
    .corpus_sha256 = "36f633026e39df001a4126cf5729050bc868232b99e6d18a1e2b412474447bc8",
};

pub const all = [_]Descriptor{
    scalar_exp_h,
    scalar_exp_f,
    scalar_exp_d,
    scalar_log_h,
    scalar_log_f,
    scalar_sin_h,
};

pub const ParseError = error{
    UnknownBenchmarkTarget,
    InvalidBenchmarkDescriptor,
};

pub fn validate(descriptor: Descriptor) ParseError!void {
    if (descriptor.name.len == 0 or descriptor.corpus_id.len == 0) {
        return error.InvalidBenchmarkDescriptor;
    }
    if (descriptor.corpus_path.len == 0 or
        !std.mem.startsWith(u8, descriptor.corpus_path, "test/corpus/"))
    {
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
}

pub fn parse(name: []const u8) ParseError!*const Descriptor {
    for (&all) |*descriptor| {
        if (!std.mem.eql(u8, name, descriptor.name)) continue;
        try validate(descriptor.*);
        return descriptor;
    }
    return error.UnknownBenchmarkTarget;
}

comptime {
    for (all) |descriptor| {
        validate(descriptor) catch @compileError("invalid benchmark descriptor");
    }
}

test "benchmark target parser rejects unknown targets" {
    try std.testing.expectError(error.UnknownBenchmarkTarget, parse("scalar-exp-x"));
}

test "benchmark target parser rejects incomplete descriptors" {
    try std.testing.expectError(
        error.InvalidBenchmarkDescriptor,
        validate(.{
            .name = "scalar-exp-h",
            .corpus_id = "",
            .corpus_path = "",
            .operation = .exp,
            .format = .h,
            .input_count = 0,
            .operation_count = 0,
            .corpus_sha256 = "",
        }),
    );
}

test "benchmark target parser rejects invalid descriptors" {
    var invalid = scalar_exp_f;
    invalid.operation_count += 1;
    try std.testing.expectError(error.InvalidBenchmarkDescriptor, validate(invalid));
}
