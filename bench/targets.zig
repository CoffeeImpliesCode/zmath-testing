const std = @import("std");

pub const Descriptor = struct {
    name: []const u8,
    corpus_id: []const u8,
    corpus_path: []const u8,
    input_count: usize,
    operation_count: u64,
    corpus_sha256: []const u8,
    corpus_sha256_bytes: [32]u8,
};

pub const scalar_log_f = Descriptor{
    .name = "scalar-log-f",
    .corpus_id = "log/f",
    .corpus_path = "test/corpus/log_f.tsv",
    .input_count = 64,
    .operation_count = 1_048_576,
    .corpus_sha256 = "7ba725bff8df9b746ebe8f455ebaf018e60d7fbc0d904f20e102b203e63f2315",
    .corpus_sha256_bytes = .{
        0x7b, 0xa7, 0x25, 0xbf, 0xf8, 0xdf, 0x9b, 0x74,
        0x6e, 0xbe, 0x8f, 0x45, 0x5e, 0xba, 0xf0, 0x18,
        0xe6, 0x0d, 0x7f, 0xbc, 0x0d, 0x90, 0x4f, 0x20,
        0xe1, 0x02, 0xb2, 0x03, 0xe6, 0x3f, 0x23, 0x15,
    },
};

pub const ParseError = error{UnknownBenchmarkTarget};

pub fn parse(name: []const u8) ParseError!*const Descriptor {
    if (std.mem.eql(u8, name, scalar_log_f.name)) return &scalar_log_f;
    return error.UnknownBenchmarkTarget;
}

comptime {
    if (scalar_log_f.input_count == 0) @compileError("benchmark corpus must not be empty");
    if (scalar_log_f.operation_count == 0 or
        scalar_log_f.operation_count % scalar_log_f.input_count != 0)
    {
        @compileError("benchmark operation count must be a non-zero corpus multiple");
    }
    if (scalar_log_f.corpus_sha256.len != 64) {
        @compileError("benchmark corpus SHA-256 must contain 64 hexadecimal digits");
    }
}
