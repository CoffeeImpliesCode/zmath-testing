const std = @import("std");

const oracle_status_ok: c_int = 0;
const oracle_status_unsupported: c_int = 1;
const oracle_status_error: c_int = 2;
const oracle_status_uncertain: c_int = 3;

const oracle_class_normal: c_uint = 0;
const oracle_class_subnormal: c_uint = 1;
const oracle_class_zero: c_uint = 2;
const oracle_class_infinity: c_uint = 3;
const oracle_class_qnan: c_uint = 4;

const header = "op\tformat\tinput_bits\toutput_bits\toutput_class\tmax_ulp\n";

const CFile = opaque {};
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*CFile;
extern "c" fn fwrite(buffer: [*]const u8, size: usize, count: usize, stream: *CFile) usize;
extern "c" fn fclose(stream: *CFile) c_int;
extern "c" fn rename(old_path: [*:0]const u8, new_path: [*:0]const u8) c_int;
extern "c" fn remove(path: [*:0]const u8) c_int;

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

const ProducerError = error{
    InvalidArguments,
    OracleUnsupported,
    OracleError,
    OracleUncertain,
    OracleClassMismatch,
    UnknownOutputClass,
    FileOpenFailed,
    FileWriteFailed,
    FileRenameFailed,
};

const Operation = enum {
    exp,
    log,
    sin,

    fn name(operation: Operation) [*:0]const u8 {
        return switch (operation) {
            .exp => "exp",
            .log => "log",
            .sin => "sin",
        };
    }
};

const Format = enum {
    h,
    f,
    d,

    fn bridgeCode(format: Format) c_uint {
        return switch (format) {
            .h => 1,
            .f => 2,
            .d => 3,
        };
    }

    fn exponentMask(format: Format) u64 {
        return switch (format) {
            .h => 0x7c00,
            .f => 0x7f80_0000,
            .d => 0x7ff0_0000_0000_0000,
        };
    }

    fn signMask(format: Format) u64 {
        return switch (format) {
            .h => 0x8000,
            .f => 0x8000_0000,
            .d => 0x8000_0000_0000_0000,
        };
    }
};

const GeneratedArtifact = struct {
    name: []const u8,
    source: []const u8,
};

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

const f_special_bits = [_]u32{
    0x0000_0000,
    0x8000_0000,
    0x7f80_0000,
    0xff80_0000,
    0x7f80_0001,
    0x7fc0_0000,
    0xff80_0001,
    0xffc0_0000,
};

const d_special_bits = [_]u64{
    0x0000_0000_0000_0000,
    0x8000_0000_0000_0000,
    0x7ff0_0000_0000_0000,
    0xfff0_0000_0000_0000,
    0x7ff0_0000_0000_0001,
    0x7ff8_0000_0000_0000,
    0xfff0_0000_0000_0001,
    0xfff8_0000_0000_0000,
};

// These inputs are the complete F/D set in scalar_exp_test.zig.
const f_regression_bits = [_]u32{
    0x0000_0000,
    0x8000_0000,
    0x7f80_0000,
    0xff80_0000,
    0x7fc1_2345,
    0xff81_2345,
};

const d_regression_bits = [_]u64{
    0x0000_0000_0000_0000,
    0x8000_0000_0000_0000,
    0x7ff0_0000_0000_0000,
    0xfff0_0000_0000_0000,
    0x7ff8_1234_5678_9abc,
    0xfff0_1234_5678_9abc,
};
// These inputs are the exact binary32 sets in scalar_log_test.zig.
const f_log_special_bits = [_]u32{
    0x0000_0000,
    0x8000_0000,
    0x7f80_0000,
    0xff80_0000,
    0x7fc1_2345,
    0x7fa1_2345,
    0xffc1_2345,
    0xffa1_2345,
    0xbf80_0000,
};

const f_log_reduction_bits = [_]u32{
    0x0000_0001,
    0x0000_0002,
    0x0000_0003,
    0x007f_ffff,
    0x0080_0000,
    0x0100_0000,
    0x3a80_0000,
    0x3dcc_cccd,
    0x3eaa_aaab,
    0x3f00_0000,
    0x3f35_04f3,
    0x3f7f_ffff,
    0x3f80_0000,
    0x3f80_0001,
    0x3f80_0002,
    0x3f80_0100,
    0x3f90_0000,
    0x3fb5_04f3,
    0x3fc0_0000,
    0x3fe0_0000,
    0x3fff_fffe,
    0x3fff_ffff,
    0x4000_0000,
    0x4000_0001,
    0x4040_0000,
    0x4120_0000,
    0x42c8_0000,
    0x7f7f_ffff,
};

const f_log_fallback_bits = [_]u32{
    0x3f80_2000,
    0x1f11_6ab8,
    0x3c41_3d3a,
    0x4117_8feb,
    0x4c5d_65a5,
    0x4d60_4ebe,
    0x65d8_90d3,
    0x66a8_c860,
    0x6f31_a8ec,
};

// Pinned CORE-MATH binary64 Exp fallback database inputs from scalar.zig.
const d_hard_cases = [_]f64{
    0x1.fffffffffffffp-53,
    0x1.ba07d73250de7p-14,
    0x1.6a4d1af9cc989p-8,
    0x1.5a75293a5dcdap-6,
    0x1.42ea46949b3c7p-5,
    0x1.7c8bb0cf5d16p-5,
    0x1.0948d39a41695p-3,
    0x1.a065fefae814fp-3,
    0x1.f6e4c3ced7c72p-3,
    0x1.1a0408712e00ap-2,
    0x1.bcab27d05abdep-2,
    0x1.005ae04256babp-1,
    0x1.273c188aa7b14p+2,
    0x1.83d4bcdebb3f4p+2,
    0x1.08f51434652c3p+4,
    0x1.1d5c2daebe367p+4,
    0x1.c44ce0d716a1ap+4,
    0x1.e07e71bfcf06fp+5,
    0x1.f7216c4b435c9p+5,
    0x1.54cd1fea7663ap+7,
    0x1.d6479eba7c971p+8,
    -0x1.664716b68a409p-14,
    -0x1.a2fefefd580dfp-13,
    -0x1.ce3f638d0c742p-12,
    -0x1.ceff32831e2c2p-12,
    -0x1.33accae78b371p-11,
    -0x1.d792b60084f92p-11,
    -0x1.7fb235d76cce7p-8,
    -0x1.1ff9b8e8b38bep-7,
    -0x1.54511e930898cp-7,
    -0x1.5c5ed0ec83666p-6,
    -0x1.8c56ff5326197p-6,
    -0x1.a4187f2ca71f9p-6,
    -0x1.a8f783d749a8fp-4,
    -0x1.bd44fdaed819fp-4,
    -0x1.daf693d64fadap-4,
    -0x1.290ea09e36479p-3,
    -0x1.8aeb636f3ce35p-3,
    -0x1.d3f3799439415p-3,
    -0x1.ea16274b0109bp-3,
    -0x1.22e24fa3d5cf9p-1,
    -0x1.85068c07fbbf6p-1,
    -0x1.bdc7955d1482cp-1,
    -0x1.2a9cad9998262p+0,
    -0x1.cc37ef7de7501p+0,
    -0x1.02393d5976769p+1,
    -0x1.65061daf79a78p+1,
    -0x1.e8bdbfcd9144ep+3,
    -0x1.8f80e06f3a04cp+4,
    -0x1.59f038076039cp+6,
    -0x1.981587ad4542fp+7,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.InvalidArguments;

    const f_inputs = try selectedFInputs(allocator);
    const d_inputs = try selectedDInputs(allocator);
    const f_log_inputs = try selectedLogFInputs(allocator);
    const artifacts = [_]GeneratedArtifact{
        .{ .name = "exp_h.tsv", .source = try generateExhaustiveH(allocator, .exp) },
        .{ .name = "exp_f.tsv", .source = try generateSelected(allocator, .exp, .f, f_inputs) },
        .{ .name = "exp_d.tsv", .source = try generateSelected(allocator, .exp, .d, d_inputs) },
        .{ .name = "log_h.tsv", .source = try generateExhaustiveH(allocator, .log) },
        .{ .name = "log_f.tsv", .source = try generateSelected(allocator, .log, .f, f_log_inputs) },
        .{ .name = "sin_h.tsv", .source = try generateExhaustiveH(allocator, .sin) },
    };
    try replaceArtifacts(allocator, args[1], &artifacts);
}

fn selectedFInputs(allocator: std.mem.Allocator) ![]const u64 {
    var inputs: std.ArrayList(u64) = .empty;
    for (f_boundary_bits) |bits| try inputs.append(allocator, bits);
    for (f_special_bits) |bits| try inputs.append(allocator, bits);
    for (f_regression_bits) |bits| try inputs.append(allocator, bits);
    try addAdjacentFiniteInputs(allocator, &inputs, .f);
    sortUnique(&inputs);
    return inputs.items;
}
fn selectedLogFInputs(allocator: std.mem.Allocator) ![]const u64 {
    var inputs: std.ArrayList(u64) = .empty;
    for (f_log_special_bits) |bits| try inputs.append(allocator, bits);
    for (f_log_reduction_bits) |bits| try inputs.append(allocator, bits);
    for (f_log_fallback_bits) |bits| {
        try inputs.append(allocator, bits);
        try inputs.append(allocator, nextDown(.f, bits));
        try inputs.append(allocator, nextUp(.f, bits));
    }
    sortUnique(&inputs);
    return inputs.items;
}

fn selectedDInputs(allocator: std.mem.Allocator) ![]const u64 {
    var inputs: std.ArrayList(u64) = .empty;
    for (d_boundary_bits) |bits| try inputs.append(allocator, bits);
    for (d_special_bits) |bits| try inputs.append(allocator, bits);
    for (d_regression_bits) |bits| try inputs.append(allocator, bits);
    for (d_hard_cases) |value| {
        const bits: u64 = @bitCast(value);
        try inputs.append(allocator, bits);
    }
    try addAdjacentFiniteInputs(allocator, &inputs, .d);
    sortUnique(&inputs);
    return inputs.items;
}

fn addAdjacentFiniteInputs(
    allocator: std.mem.Allocator,
    inputs: *std.ArrayList(u64),
    format: Format,
) !void {
    sortUnique(inputs);
    const selected = try allocator.dupe(u64, inputs.items);
    for (selected) |bits| {
        if (!isFiniteInput(format, bits)) continue;
        try inputs.append(allocator, nextDown(format, bits));
        try inputs.append(allocator, nextUp(format, bits));
    }
}

fn sortUnique(inputs: *std.ArrayList(u64)) void {
    std.sort.pdq(u64, inputs.items, {}, std.sort.asc(u64));
    if (inputs.items.len < 2) return;

    var write_index: usize = 1;
    for (inputs.items[1..]) |bits| {
        if (bits == inputs.items[write_index - 1]) continue;
        inputs.items[write_index] = bits;
        write_index += 1;
    }
    inputs.items = inputs.items[0..write_index];
}

fn isFiniteInput(format: Format, bits: u64) bool {
    const exponent_mask = format.exponentMask();
    return (bits & exponent_mask) != exponent_mask;
}

fn nextDown(format: Format, bits: u64) u64 {
    const sign_mask = format.signMask();
    const magnitude = bits & ~sign_mask;
    if (magnitude == 0) return sign_mask | 1;
    return if ((bits & sign_mask) != 0) bits + 1 else bits - 1;
}

fn nextUp(format: Format, bits: u64) u64 {
    const sign_mask = format.signMask();
    const magnitude = bits & ~sign_mask;
    if (magnitude == 0) return 1;
    return if ((bits & sign_mask) != 0) bits - 1 else bits + 1;
}

fn generateExhaustiveH(allocator: std.mem.Allocator, operation: Operation) ![]const u8 {
    var source: std.ArrayList(u8) = .empty;
    try source.ensureTotalCapacity(allocator, 2 * 1024 * 1024);
    try source.appendSlice(allocator, header);

    var bits: u32 = 0;
    while (bits < 0x1_0000) : (bits += 1) {
        try appendRow(allocator, &source, operation, .h, bits);
    }
    return source.items;
}

fn generateSelected(
    allocator: std.mem.Allocator,
    operation: Operation,
    format: Format,
    inputs: []const u64,
) ![]const u8 {
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(allocator, header);
    for (inputs) |bits| try appendRow(allocator, &source, operation, format, bits);
    return source.items;
}

fn appendRow(
    allocator: std.mem.Allocator,
    source: *std.ArrayList(u8),
    operation: Operation,
    format: Format,
    input_bits: u64,
) !void {
    var input_word = input_bits;
    var output_bits: u64 = 0;
    var output_class: c_uint = 0;
    try requireOracleOk(zmath_testing_mpfr_reference(
        operation.name(),
        format.bridgeCode(),
        &input_word,
        1,
        &output_bits,
        &output_class,
    ));

    if (isFiniteOutputClass(output_class)) {
        var proof_class: c_uint = 0;
        try requireOracleOk(zmath_testing_arb_prove_rounding(
            operation.name(),
            format.bridgeCode(),
            &input_word,
            1,
            output_bits,
            &proof_class,
        ));
        if (proof_class != output_class) return error.OracleClassMismatch;
    }

    const class_name = try outputClassName(output_class);
    switch (format) {
        .h => try source.print(
            allocator,
            "{s}\th\t{x:0>4}\t{x:0>4}\t{s}\t0\n",
            .{ operation.name(), input_bits, output_bits, class_name },
        ),
        .f => try source.print(
            allocator,
            "{s}\tf\t{x:0>8}\t{x:0>8}\t{s}\t0\n",
            .{ operation.name(), input_bits, output_bits, class_name },
        ),
        .d => try source.print(
            allocator,
            "{s}\td\t{x:0>16}\t{x:0>16}\t{s}\t0\n",
            .{ operation.name(), input_bits, output_bits, class_name },
        ),
    }
}

fn requireOracleOk(status: c_int) ProducerError!void {
    return switch (status) {
        oracle_status_ok => {},
        oracle_status_unsupported => error.OracleUnsupported,
        oracle_status_error => error.OracleError,
        oracle_status_uncertain => error.OracleUncertain,
        else => error.OracleError,
    };
}

fn isFiniteOutputClass(output_class: c_uint) bool {
    return output_class == oracle_class_normal or
        output_class == oracle_class_subnormal or
        output_class == oracle_class_zero;
}

fn outputClassName(output_class: c_uint) ProducerError![]const u8 {
    return switch (output_class) {
        oracle_class_normal => "normal",
        oracle_class_subnormal => "subnormal",
        oracle_class_zero => "zero",
        oracle_class_infinity => "infinity",
        oracle_class_qnan => "qnan",
        else => error.UnknownOutputClass,
    };
}

fn replaceArtifacts(
    allocator: std.mem.Allocator,
    output_directory: []const u8,
    artifacts: []const GeneratedArtifact,
) !void {
    var final_paths: [6][:0]u8 = undefined;
    var temporary_paths: [6][:0]u8 = undefined;
    for (artifacts, 0..) |artifact, index| {
        const final_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
            output_directory,
            artifact.name,
        });
        final_paths[index] = try allocator.dupeZ(u8, final_path);
        const temporary_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{final_path});
        temporary_paths[index] = try allocator.dupeZ(u8, temporary_path);
    }
    defer {
        for (temporary_paths) |path| _ = remove(path.ptr);
    }

    for (artifacts, temporary_paths) |artifact, path| {
        _ = remove(path.ptr);
        try writeFile(path, artifact.source);
    }
    for (temporary_paths, final_paths) |temporary_path, final_path| {
        if (rename(temporary_path.ptr, final_path.ptr) != 0) return error.FileRenameFailed;
    }
}

fn writeFile(path: [:0]const u8, source: []const u8) ProducerError!void {
    const stream = fopen(path.ptr, "wb") orelse return error.FileOpenFailed;
    var closed = false;
    defer {
        if (!closed) _ = fclose(stream);
    }

    if (fwrite(source.ptr, 1, source.len, stream) != source.len) {
        return error.FileWriteFailed;
    }
    if (fclose(stream) != 0) return error.FileWriteFailed;
    closed = true;
}
