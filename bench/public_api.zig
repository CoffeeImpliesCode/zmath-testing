const std = @import("std");
const Io = std.Io;
const zmath = @import("zmath");
const corpus_support = @import("corpus_support");
const targets = @import("targets.zig");
const build_target = @import("benchmark_target");

const descriptor = targets.parse(build_target.name) catch
    @compileError("benchmark options name an unknown target");

comptime {
    if (!build_target.approved_corpus_pair) {
        @compileError(
            "benchmarks require target x86_64-linux-gnu.2.38, CPU haswell, mode ReleaseSafe",
        );
    }
    if (build_target.input_count != descriptor.input_count or
        build_target.operation_count != descriptor.operation_count or
        !std.mem.eql(u8, build_target.corpus_sha256, descriptor.corpus_sha256))
    {
        @compileError("benchmark options do not match their immutable descriptor");
    }
}

const exp_h_corpus = @embedFile("exp_h.tsv");
const exp_f_corpus = @embedFile("exp_f.tsv");
const exp_d_corpus = @embedFile("exp_d.tsv");
const log_h_corpus = @embedFile("log_h.tsv");
const log_f_corpus = @embedFile("log_f.tsv");
const sin_h_corpus = @embedFile("sin_h.tsv");

fn corpusSource() []const u8 {
    return switch (descriptor.operation) {
        .exp => switch (descriptor.format) {
            .h => exp_h_corpus,
            .f => exp_f_corpus,
            .d => exp_d_corpus,
        },
        .log => switch (descriptor.format) {
            .h => log_h_corpus,
            .f => log_f_corpus,
            .d => @panic("no accepted scalar-log-d benchmark descriptor"),
        },
        .sin => switch (descriptor.format) {
            .h => sin_h_corpus,
            .f, .d => @panic("no accepted scalar-sin benchmark descriptor"),
        },
    };
}

fn activeTargetMode() corpus_support.TargetMode {
    return .{
        .target = build_target.corpus_target,
        .cpu = build_target.corpus_cpu,
        .mode = build_target.optimize,
    };
}

fn verifyCorpusChecksum(source: []const u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &digest_hex, descriptor.corpus_sha256)) {
        @panic("benchmark corpus checksum does not match its immutable descriptor");
    }
}

fn parseCorpus() [build_target.input_count]u64 {
    const source = corpusSource();
    const mode = activeTargetMode();
    const manifest = corpus_support.parseEmbeddedManifest() catch
        @panic("benchmark manifest is invalid");
    const artifact = corpus_support.loadArtifact(
        &manifest,
        source,
        .{
            .artifact_name = descriptor.corpus_path,
            .target_mode = mode,
            .required_row_count = descriptor.input_count,
        },
        mode,
    ) catch @panic("benchmark corpus does not satisfy its immutable descriptor");

    var inputs: [build_target.input_count]u64 = undefined;
    var iterator = artifact.rows() catch @panic("benchmark corpus rows are invalid");
    var input_index: usize = 0;
    while (tryNext(&iterator)) |row| {
        if (input_index >= inputs.len) @panic("benchmark corpus has too many rows");
        inputs[input_index] = row.input_bits;
        input_index += 1;
    }
    if (input_index != inputs.len) @panic("benchmark corpus has too few rows");
    return inputs;
}

fn tryNext(iterator: *corpus_support.RowIterator) ?corpus_support.CorpusRow {
    return iterator.next() catch @panic("benchmark corpus row parsing failed");
}

fn benchTime(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn inputValue(comptime T: type, input_bits: u64) T {
    if (T == f16) {
        var bits: u16 = @intCast(input_bits);
        std.mem.doNotOptimizeAway(&bits);
        return @bitCast(bits);
    }
    if (T == f32) {
        var bits: u32 = @intCast(input_bits);
        std.mem.doNotOptimizeAway(&bits);
        return @bitCast(bits);
    }
    if (T == f64) {
        var bits: u64 = input_bits;
        std.mem.doNotOptimizeAway(&bits);
        return @bitCast(bits);
    }
    @compileError("benchmark inputs support only f16, f32, and f64");
}

fn outputBits(comptime T: type, output: T) u64 {
    if (T == f16) return @as(u64, @as(u16, @bitCast(output)));
    if (T == f32) return @as(u64, @as(u32, @bitCast(output)));
    if (T == f64) return @bitCast(output);
    @compileError("benchmark outputs support only f16, f32, and f64");
}

fn apply(comptime T: type, operation: targets.Operation, input: T) T {
    return switch (operation) {
        .exp => zmath.exp(input),
        .log => zmath.log(input),
        .sin => zmath.sin(input),
    };
}

fn run(comptime T: type, inputs: []const u64) u64 {
    const repetitions = build_target.operation_count / @as(u64, build_target.input_count);
    var result_checksum: u64 = 0;
    var repetition: u64 = 0;
    while (repetition < repetitions) : (repetition += 1) {
        for (inputs) |input_bits| {
            const input = inputValue(T, input_bits);
            const output = apply(T, descriptor.operation, input);
            result_checksum +%= outputBits(T, output);
        }
    }
    return result_checksum;
}

pub fn main(init: std.process.Init) !void {
    const source = corpusSource();
    verifyCorpusChecksum(source);
    var inputs = parseCorpus();

    const start = benchTime(init.io);
    const result_checksum = switch (descriptor.format) {
        .h => run(f16, &inputs),
        .f => run(f32, &inputs),
        .d => run(f64, &inputs),
    };
    const elapsed = benchTime(init.io) - start;
    std.mem.doNotOptimizeAway(&result_checksum);

    std.debug.print(
        "target={s} corpus_id={s} corpus_path={s} corpus_count={} operations={} " ++
            "corpus_sha256={s} target_triple={s} cpu_features={s} optimize={s}\n",
        .{
            build_target.name,
            build_target.corpus_id,
            descriptor.corpus_path,
            build_target.input_count,
            build_target.operation_count,
            build_target.corpus_sha256,
            build_target.target_triple,
            build_target.cpu_features,
            build_target.optimize,
        },
    );
    std.debug.print("elapsed_ns={} result_checksum={}\n", .{ elapsed, result_checksum });
}
