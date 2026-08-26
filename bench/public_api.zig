const std = @import("std");
const Io = std.Io;
const zmath = @import("zmath");
const targets = @import("targets.zig");
const build_target = @import("benchmark_target");

const log_f_corpus = @embedFile("log_f.tsv");
const Corpus = [build_target.input_count]u32;
const corpus_inputs: Corpus = parseCorpus();

fn parseCorpus() Corpus {
    // The 64-row, six-field TSV parser exceeds 10,000 backward branches.
    // A local 100,000-branch quota provides headroom without affecting other comptime work.
    @setEvalBranchQuota(100_000);
    var inputs: Corpus = undefined;
    var row_count: usize = 0;
    var lines = std.mem.splitScalar(u8, log_f_corpus, '\n');

    const header = lines.next() orelse @compileError("log_f corpus is missing its header");
    if (!std.mem.eql(u8, header, "op\tformat\tinput_bits\toutput_bits\toutput_class\tmax_ulp")) {
        @compileError("log_f corpus header does not match the accepted schema");
    }

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (row_count >= inputs.len) @compileError("log_f corpus has too many data rows");

        var fields = std.mem.splitScalar(u8, line, '\t');
        const operation = fields.next() orelse @compileError("log_f corpus row is missing op");
        const format = fields.next() orelse @compileError("log_f corpus row is missing format");
        const input_bits_text = fields.next() orelse
            @compileError("log_f corpus row is missing input_bits");
        const output_bits_text = fields.next() orelse
            @compileError("log_f corpus row is missing output_bits");
        const output_class = fields.next() orelse
            @compileError("log_f corpus row is missing output_class");
        const max_ulp = fields.next() orelse @compileError("log_f corpus row is missing max_ulp");

        if (!std.mem.eql(u8, operation, "log")) @compileError("log_f corpus has a non-log row");
        if (!std.mem.eql(u8, format, "f")) @compileError("log_f corpus has a non-f row");
        if (input_bits_text.len != 8 or output_bits_text.len != 8) {
            @compileError("log_f corpus bit fields must be eight hexadecimal digits");
        }
        if (output_class.len == 0) @compileError("log_f corpus output class must not be empty");
        if (!std.mem.eql(u8, max_ulp, "0")) @compileError("log_f corpus max_ulp must be zero");
        if (fields.next() != null) @compileError("log_f corpus row has extra fields");

        inputs[row_count] = std.fmt.parseInt(u32, input_bits_text, 16) catch
            @compileError("log_f corpus input_bits is not hexadecimal");
        _ = std.fmt.parseInt(u32, output_bits_text, 16) catch
            @compileError("log_f corpus output_bits is not hexadecimal");
        row_count += 1;
    }

    if (row_count != build_target.input_count) {
        @compileError("log_f corpus row count does not match the target descriptor");
    }
    return inputs;
}

fn verifyCorpusChecksum() void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(log_f_corpus, &digest, .{});
    if (!std.mem.eql(u8, digest[0..], targets.scalar_log_f.corpus_sha256_bytes[0..])) {
        @panic("log_f corpus checksum does not match its immutable descriptor");
    }
}

fn benchTime(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn runScalarLogF() u64 {
    const repetitions = build_target.operation_count / @as(u64, build_target.input_count);
    var result_checksum: u64 = 0;
    var repetition: u64 = 0;
    while (repetition < repetitions) : (repetition += 1) {
        for (corpus_inputs) |input_bits| {
            const input: f32 = @bitCast(input_bits);
            const output: f32 = zmath.log(input);
            const output_bits: u32 = @bitCast(output);
            result_checksum +%= output_bits;
        }
    }
    return result_checksum;
}

pub fn main(init: std.process.Init) !void {
    verifyCorpusChecksum();
    const start = benchTime(init.io);
    const result_checksum = runScalarLogF();
    const elapsed = benchTime(init.io) - start;
    std.mem.doNotOptimizeAway(result_checksum);

    std.debug.print(
        "target={s} corpus_id={s} corpus_count={} operations={} checksum={s} " ++
            "target_triple={s} cpu_features={s} optimize={s}\n",
        .{
            build_target.name,
            build_target.corpus_id,
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
