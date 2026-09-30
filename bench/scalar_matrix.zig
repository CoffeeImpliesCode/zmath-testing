const std = @import("std");
const target_mode = @import("active_target_mode");
const corpus = @import("corpus_support");
const runner = @import("scalar_runner");
const references = @import("scalar_references.zig");
const corpus_set = @import("corpus_set");

const sample_count_max = 64;
const encoded_record_capacity = corpus_set.record_buffer_capacity;
const repetitions_max: u64 = 1024;
const timing_repetitions_max: u8 = 100;
const target_duration_ns: u64 = 5_000_000;
const Inputs = [corpus.max_argument_count]corpus.OracleInputField;
const Digest = corpus_set.Digest;

const Samples = struct {
    inputs: [sample_count_max]Inputs = undefined,
    tags: [sample_count_max][encoded_record_capacity]u8 = undefined,
    count: usize = 0,
    corpus_count: u64 = 0,
};

const Measurement = struct {
    elapsed_ns: u64,
    calls: u64,
    checksum: u64,
};

const Options = struct {
    root: []const u8 = "test/corpus",
    operation: ?[]const u8 = null,
    format: ?corpus.Format = null,
    repetitions: u8 = 1,
    with_zig: bool = false,

    fn matches(self: Options, function: corpus.Function) bool {
        if (self.operation) |operation| {
            if (!std.mem.eql(u8, function.op, operation)) return false;
        }
        const format = function.result.floatFormat() orelse
            function.arguments()[0].floatFormat() orelse .h;
        return self.format == null or self.format.? == format;
    }
};

fn parseOptions(args: []const []const u8) !Options {
    if (args.len == 0) return error.InvalidArguments;
    var options: Options = .{};
    var repetitions_seen = false;
    var index: usize = 1;
    if (args.len > 1 and !std.mem.startsWith(u8, args[1], "--")) {
        options.root = args[1];
        index = 2;
    }
    if (options.root.len == 0) return error.InvalidArguments;
    for (args[index..]) |argument| {
        if (std.mem.startsWith(u8, argument, "--operation=")) {
            if (options.operation != null) return error.InvalidArguments;
            options.operation = argument["--operation=".len..];
            if (options.operation.?.len == 0) return error.InvalidArguments;
        } else if (std.mem.startsWith(u8, argument, "--format=")) {
            if (options.format != null) return error.InvalidArguments;
            options.format = std.meta.stringToEnum(corpus.Format, argument["--format=".len..]) orelse
                return error.InvalidArguments;
        } else if (std.mem.startsWith(u8, argument, "--repetitions=")) {
            if (repetitions_seen) return error.InvalidRepetitions;
            repetitions_seen = true;
            const text = argument["--repetitions=".len..];
            if (text.len == 0) return error.InvalidRepetitions;
            for (text) |digit| {
                if (digit < '0' or digit > '9') return error.InvalidRepetitions;
            }
            options.repetitions = std.fmt.parseInt(u8, text, 10) catch
                return error.InvalidRepetitions;
            if (options.repetitions == 0 or options.repetitions > timing_repetitions_max) {
                return error.InvalidRepetitions;
            }
        } else if (std.mem.eql(u8, argument, "--with-zig")) {
            if (options.with_zig) return error.InvalidArguments;
            options.with_zig = true;
        } else if (std.mem.startsWith(u8, argument, "--repetitions")) {
            return error.InvalidRepetitions;
        } else return error.InvalidArguments;
    }
    return options;
}

pub fn main(init: std.process.Init) !void {
    if (!target_mode.approved_corpus_pair) return error.UnapprovedCorpusProfile;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseOptions(args) catch |err| {
        if (err == error.InvalidRepetitions) {
            std.debug.print(
                "invalid --repetitions: expected a decimal integer from 1 to {d}\n",
                .{timing_repetitions_max},
            );
        }
        std.debug.print(
            "usage: zmath-scalar-matrix [corpus-root] [--operation=<manifest-op>] " ++
                "[--format=h|f|d] [--repetitions=1..{d}] [--with-zig] (default 1)\n",
            .{timing_repetitions_max},
        );
        return err;
    };
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    var expected_count: usize = 0;
    for (manifest.function_values[0..manifest.function_count]) |function| {
        if (options.matches(function)) expected_count += 1;
    }
    if (expected_count == 0) return error.UnknownOperation;
    var root_buffer: [512]u8 = undefined;
    const run_root = if (options.operation != null or options.format != null)
        try std.fmt.bufPrint(&root_buffer, "{s}/generated/probes/{s}-{s}", .{
            options.root, options.operation orelse "all", if (options.format) |format| @tagName(format) else "all",
        })
    else
        try std.fmt.bufPrint(&root_buffer, "{s}/generated", .{options.root});
    var published = try corpus_set.load(
        init.gpa,
        init.io,
        std.Io.Dir.cwd(),
        run_root,
        &manifest,
        .{ .target = target_mode.target, .cpu = target_mode.cpu, .mode = target_mode.mode },
    );
    defer published.deinit(init.gpa);
    if (published.count != expected_count) return error.CorpusSelectionMismatch;
    std.debug.print(
        "target={s} cpu={s} optimize={s} selection=evenly_spaced_records samples_max={} repetitions_max={}\n",
        .{ target_mode.target, target_mode.cpu, target_mode.mode, sample_count_max, repetitions_max },
    );
    for (published.entries[0..published.count]) |entry| {
        const function = manifest.function_values[entry.signature_index];
        if (!options.matches(function)) return error.CorpusSelectionMismatch;
        try benchmarkFunction(init, entry, function, options.repetitions, options.with_zig);
    }
}

fn benchmarkFunction(
    init: std.process.Init,
    entry: corpus_set.Entry,
    function: corpus.Function,
    timing_repetitions: u8,
    with_zig: bool,
) !void {
    const path = entry.artifact;
    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    const summary = try countRecords(init.io, file);
    if (summary.count != entry.records or !std.mem.eql(u8, &summary.digest, &entry.digest)) {
        return error.CorpusIntegrityMismatch;
    }
    const prepared = try runner.prepareRuntime(function);
    var samples: Samples = .{ .corpus_count = summary.count };
    const sampled_digest = try selectSamples(init.io, file, function, &prepared, &samples);
    if (!std.mem.eql(u8, &summary.digest, &sampled_digest)) return error.CorpusChanged;
    const warmup = measure(init.io, &prepared, &samples, 1);
    const repetitions = std.math.clamp(
        @divFloor(target_duration_ns, @max(warmup.elapsed_ns, 1)),
        1,
        repetitions_max,
    );
    const digest_hex = std.fmt.bytesToHex(summary.digest, .lower);
    for (0..timing_repetitions) |repetition| {
        const result = measure(init.io, &prepared, &samples, repetitions);
        std.debug.print(
            "signature={} operation={s} repetition={} artifact={s} corpus_records={} " ++
                "samples={} calls={} elapsed_ns={} checksum={x:0>16} " ++
                "corpus_sha256={s} provider=zmath\n",
            .{
                entry.signature_index, function.op,   repetition,   path,
                samples.corpus_count,  samples.count, result.calls, result.elapsed_ns,
                result.checksum,       digest_hex,
            },
        );
    }
    if (with_zig) benchmarkZigReference(
        init.io,
        entry,
        function,
        &prepared,
        &samples,
        repetitions,
        timing_repetitions,
        digest_hex[0..],
    );
}

fn benchmarkZigReference(
    io: std.Io,
    entry: corpus_set.Entry,
    function: corpus.Function,
    runtime: *const runner.PreparedRuntime,
    samples: *const Samples,
    repetitions: u64,
    timing_repetitions: u8,
    digest_hex: []const u8,
) void {
    const reference_entry = references.entryFor(function, runtime.entry) orelse {
        std.debug.print(
            "signature={} operation={s} provider=zig available=false " ++
                "reason=unsupported_signature artifact={s} corpus_records={} " ++
                "samples={} corpus_sha256={s}\n",
            .{ entry.signature_index, function.op, entry.artifact, samples.corpus_count, samples.count, digest_hex },
        );
        return;
    };
    const reference: runner.PreparedRuntime = .{ .entry = &reference_entry };
    var mismatches: usize = 0;
    for (samples.inputs[0..samples.count]) |*inputs| {
        const expected = runtime.invoke(inputs);
        const actual = reference.invoke(inputs);
        if (actual.field_count != expected.field_count or
            actual.field_count > actual.values.len or
            expected.field_count > expected.values.len)
        {
            mismatches += 1;
            continue;
        }
        for (actual.values[0..actual.field_count], expected.values[0..expected.field_count]) |a, b| {
            if (a != b) mismatches += 1;
        }
    }
    if (mismatches != 0) {
        std.debug.print(
            "signature={} operation={s} provider=zig available=false " ++
                "reason=sample_result_mismatch mismatches={} artifact={s} " ++
                "corpus_records={} samples={} corpus_sha256={s}\n",
            .{
                entry.signature_index, function.op,   mismatches, entry.artifact,
                samples.corpus_count,  samples.count, digest_hex,
            },
        );
        return;
    }

    for (0..timing_repetitions) |repetition| {
        const result = measure(io, &reference, samples, repetitions);
        std.debug.print(
            "signature={} operation={s} repetition={} artifact={s} corpus_records={} " ++
                "samples={} calls={} elapsed_ns={} checksum={x:0>16} " ++
                "corpus_sha256={s} provider=zig\n",
            .{
                entry.signature_index, function.op,   repetition,   entry.artifact,
                samples.corpus_count,  samples.count, result.calls, result.elapsed_ns,
                result.checksum,       digest_hex,
            },
        );
    }
}

fn countRecords(io: std.Io, file: std.Io.File) !struct { count: u64, digest: Digest } {
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var frames: [2][encoded_record_capacity]u8 = undefined;
    var slot: u1 = 0;
    var previous: ?corpus.CorpusRecord = null;
    var count: u64 = 0;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (try corpus.readEncodedRecord(&reader.interface, &frames[slot])) |bytes| {
        const record = try corpus.decodeCorpusRecord(bytes);
        if (previous) |*prior| try corpus.validateCorpusRecordOrder(prior, &record);
        previous = record;
        slot ^= 1;
        hasher.update(bytes);
        count += 1;
    }
    if (count == 0) return error.EmptyCorpus;
    var digest: Digest = undefined;
    hasher.final(&digest);
    return .{ .count = count, .digest = digest };
}

fn selectSamples(
    io: std.Io,
    file: std.Io.File,
    function: corpus.Function,
    prepared: *const runner.PreparedRuntime,
    samples: *Samples,
) !Digest {
    samples.count = @intCast(@min(sample_count_max, samples.corpus_count));
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var frame: [encoded_record_capacity]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var record_index: u64 = 0;
    var sample_index: usize = 0;
    while (try corpus.readEncodedRecord(&reader.interface, &frame)) |bytes| : (record_index += 1) {
        if (sample_index == samples.count) return error.RecordCountMismatch;
        hasher.update(bytes);
        const selected_index = if (samples.count == 1) 0 else @divFloor(
            @as(u64, sample_index) * (samples.corpus_count - 1),
            samples.count - 1,
        );
        if (record_index != selected_index) continue;
        const record = try corpus.decodeCorpusRecord(bytes);
        try storeSample(function, prepared, samples, sample_index, &record);
        sample_index += 1;
    }
    if (sample_index != samples.count or record_index != samples.corpus_count) return error.IncompleteSample;
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn storeSample(
    function: corpus.Function,
    prepared: *const runner.PreparedRuntime,
    samples: *Samples,
    sample_index: usize,
    record: *const corpus.CorpusRecord,
) !void {
    if (!std.mem.eql(u8, record.operation, function.op) or
        !std.meta.eql(record.result_descriptor, function.result) or
        record.arguments.count != function.arity)
    {
        return error.CorpusSignatureMismatch;
    }
    const inputs = &samples.inputs[sample_index];
    var tag_offset: usize = 0;
    for (record.arguments.slice(), function.arguments(), 0..) |field, descriptor, index| {
        inputs[index] = try decodeInput(field, descriptor, samples.tags[sample_index][tag_offset..]);
        tag_offset += switch (field) {
            .tag => |tag| tag.len,
            else => 0,
        };
    }
    const raw = prepared.invoke(inputs);
    var actual_fields: [2]corpus.CorpusField = undefined;
    const count = try runner.materializeRawRuntimeFields(function, prepared, raw, &actual_fields);
    if (count != record.results.count) return error.RuntimeMismatch;
    for (actual_fields[0..count], record.results.slice()) |actual, expected| {
        if (!std.meta.eql(actual, expected)) return error.RuntimeMismatch;
    }
}

fn decodeInput(field: corpus.CorpusField, expected: corpus.InputDescriptor, tag_buffer: []u8) !corpus.OracleInputField {
    const descriptor: corpus.InputDescriptor = switch (field) {
        .float => |value| .{ .float = value.format },
        .signed_integer => |value| .{ .integer = value.integer_type },
        .unsigned_integer => |value| .{ .integer = value.integer_type },
        .tag => .tag,
        .rounding => .fromfp_round,
        // `round_mode` is not `rounding`. `FromFpRound` codes its five modes
        // 0-4 and `RoundMode` codes four 0-3, so a single shared arm would
        // accept a `rounding` field as a `round_mode` and reinterpret its
        // numeric value. The stored field kind must match the descriptor kind.
        .round_mode => .round_mode,
        .boolean => return error.InvalidInputDescriptor,
        // `classification` is a result-only shape. No `InputDescriptor` can
        // name it, so an argument that carries one is a corrupt record.
        .classification => return error.InvalidInputDescriptor,
    };
    if (!std.meta.eql(descriptor, expected)) return error.CorpusSignatureMismatch;
    const bits: u64 = switch (field) {
        .float => |value| value.bits,
        .signed_integer => |value| try corpus.encodeSignedInteger(
            value.value,
            value.integer_type.oracleValueBits(),
        ),
        .unsigned_integer => |value| value.value,
        .rounding => |value| @intFromEnum(value),
        .round_mode => |value| @intFromEnum(value),
        .tag => |value| {
            if (value.len > tag_buffer.len) return error.TagTooLong;
            @memcpy(tag_buffer[0..value.len], value);
            return corpus.oracleTagInput(tag_buffer[0..value.len]);
        },
        .boolean => return error.InvalidInputDescriptor,
        .classification => return error.InvalidInputDescriptor,
    };
    return corpus.oracleLiteralInput(descriptor, bits);
}

fn measure(
    io: std.Io,
    prepared: *const runner.PreparedRuntime,
    samples: *const Samples,
    repetitions: u64,
) Measurement {
    std.debug.assert(samples.count > 0);
    std.debug.assert(samples.count <= sample_count_max);
    std.debug.assert(repetitions > 0);
    std.debug.assert(repetitions <= repetitions_max);
    var checksum: u64 = 0;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..repetitions) |_| {
        for (samples.inputs[0..samples.count]) |*inputs| {
            std.mem.doNotOptimizeAway(inputs);
            const result = prepared.invoke(inputs);
            std.debug.assert(result.field_count <= 2);
            for (result.values[0..result.field_count]) |bits| {
                checksum = (checksum ^ bits) *% 0x100_0000_01b3;
            }
        }
    }
    std.mem.doNotOptimizeAway(&checksum);
    const elapsed = std.Io.Clock.awake.now(io).nanoseconds - start;
    std.debug.assert(elapsed >= 0);
    return .{
        .elapsed_ns = @intCast(elapsed),
        .calls = repetitions * samples.count,
        .checksum = checksum,
    };
}
