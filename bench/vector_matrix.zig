//! Vector corpus-matrix benchmark.
//!
//! This benchmark times `zmath.vector` entry points over the immutable
//! published corpora and, for the same lane groups, an independent
//! `@Vector`-built reference. It mirrors `bench/scalar_matrix.zig`: the same
//! approved-profile guard, the same publication load, the same artifact
//! digest revalidation, the same evenly spaced sample selection, and the same
//! measurement and output style.
//!
//! Accuracy contract: this benchmark reports performance only. It never asserts
//! numerical correctness, it never changes a manifest status, and it grants no
//! manifest acceptance, no oracle evidence, and no whole-domain proof. The
//! reference is measured for speed comparison, not as an acceptance oracle.
//! Every correctness statement remains with the deterministic replay lane.

const std = @import("std");
const target_mode = @import("active_target_mode");
const corpus = @import("corpus_support");
const runner = @import("scalar_runner");
const references = @import("vector_references.zig");
const corpus_set = @import("corpus_set");
const targets = @import("vector_targets.zig");
const zmath = @import("zmath");

const sample_count_max = 64;
const encoded_record_capacity = corpus_set.record_buffer_capacity;
const repetitions_max: u64 = 1024;
const timing_repetitions_max: u8 = 100;
const target_duration_ns: u64 = 5_000_000;
const Inputs = [corpus.max_argument_count]corpus.OracleInputField;
const Digest = corpus_set.Digest;

/// Measured operations. Each names a `zmath.vector` entry point that exists
/// today and a matching independent reference operation.
const Operation = enum {
    exp,
    log,
    sin,
};

const Samples = struct {
    /// Flattened lane storage. Entry `group * lane_width + lane` holds the
    /// corpus inputs for that lane.
    inputs: [sample_count_max]Inputs = undefined,
    tags: [sample_count_max][encoded_record_capacity]u8 = undefined,
    count: usize = 0,
    /// Samples actually packed into lane groups, which is `count` rounded down
    /// to a whole number of groups.
    group_count: usize = 0,
    corpus_count: u64 = 0,
};

const Measurement = struct {
    elapsed_ns: u64,
    calls: u64,
    lanes: u64,
    checksum: u64,
};

const Options = struct {
    root: []const u8 = "test/corpus",
    operation: ?[]const u8 = null,
    format: ?corpus.Format = null,
    repetitions: u8 = 1,

    fn matches(self: Options, function: corpus.Function) bool {
        if (self.operation) |operation| {
            if (!std.mem.eql(u8, function.op, operation)) return false;
        }
        const format = function.result.floatFormat() orelse
            function.arguments()[0].floatFormat() orelse .h;
        return self.format == null or self.format.? == format;
    }
};

/// State handed to a measured loop. The reference provider needs its runtime
/// invoker, which a comptime body function cannot capture.
const MeasureState = struct {
    samples: *const Samples,
    reference: ?*const runner.PreparedRuntime = null,
};

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
            "usage: zmath-vector-matrix [corpus-root] [--operation=<manifest-op>] " ++
                "[--format=h|f|d] [--repetitions=1..{d}] (default 1)\n",
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
        init.io,
        init.gpa,
        std.Io.Dir.cwd(),
        run_root,
        &manifest,
        .{ .target = target_mode.target, .cpu = target_mode.cpu, .mode = target_mode.mode },
    );
    defer published.deinit(init.gpa);
    if (published.count != expected_count) return error.CorpusSelectionMismatch;
    std.debug.print(
        "target={s} cpu={s} optimize={s} selection=evenly_spaced_records samples_max={} " ++
            "repetitions_max={} acceptance=none\n",
        .{ target_mode.target, target_mode.cpu, target_mode.mode, sample_count_max, repetitions_max },
    );
    for (published.entries[0..published.count]) |entry| {
        const function = manifest.function_values[entry.signature_index];
        if (!options.matches(function)) return error.CorpusSelectionMismatch;
        // A vector target is measured only when the registry registers it, so
        // the measured set is exactly the set with a real published corpus.
        const format = targetFormat(function.result.floatFormat() orelse continue);
        const descriptor = targets.lookup(function.op, format) orelse {
            std.debug.print(
                "signature={} operation={s} artifact={s} corpus_records={} lane_width=1 " ++
                    "corpus_sha256=none provider=zmath-vector available=false " ++
                    "reason=no_registered_vector_target\n",
                .{ entry.signature_index, function.op, entry.artifact, entry.records },
            );
            continue;
        };
        const operation = std.meta.stringToEnum(Operation, function.op) orelse {
            std.debug.print(
                "signature={} operation={s} artifact={s} corpus_records={} lane_width={} " ++
                    "corpus_sha256={s} provider=zmath-vector available=false " ++
                    "reason=no_vector_entry_point\n",
                .{
                    entry.signature_index, function.op,
                    entry.artifact,        entry.records,
                    descriptor.lane_width, descriptor.corpus_sha256,
                },
            );
            continue;
        };
        try benchmarkSelected(
            init,
            entry,
            function,
            descriptor,
            operation,
            format,
            options.repetitions,
        );
    }
}

/// Maps a manifest float format onto the vector target registry's format. The
/// manifest enum covers exactly the three published binary formats.
fn targetFormat(format: corpus.Format) targets.Format {
    return switch (format) {
        .h => .h,
        .f => .f,
        .d => .d,
    };
}

/// Maps a measured operation onto the reference operation that implements it
/// independently. The enumerations stay separate so the benchmark cannot
/// silently measure an operation the reference does not implement.
fn referenceOperation(operation: Operation) references.Operation {
    return switch (operation) {
        .exp => .exp,
        .log => .log,
        .sin => .sin,
    };
}

/// Selects the comptime specialization for one runtime operation and format, so
/// every measured loop is built from a lane width and a lane type known at
/// compile time.
fn benchmarkSelected(
    init: std.process.Init,
    entry: corpus_set.Entry,
    function: corpus.Function,
    descriptor: *const targets.VectorDescriptor,
    operation: Operation,
    format: targets.Format,
    timing_repetitions: u8,
) !void {
    return switch (operation) {
        inline else => |comptime_operation| switch (format) {
            inline else => |comptime_format| benchmarkFunction(
                init,
                entry,
                function,
                descriptor,
                comptime_operation,
                comptime_format,
                timing_repetitions,
            ),
        },
    };
}


fn benchmarkFunction(
    init: std.process.Init,
    entry: corpus_set.Entry,
    function: corpus.Function,
    descriptor: *const targets.VectorDescriptor,
    comptime operation: Operation,
    comptime format: targets.Format,
    timing_repetitions: u8,
) !void {
    const lane_width = comptime targets.laneWidthFor(format);
    comptime {
        if (lane_width == 0) @compileError("vector lane width must not be zero");
        if (references.laneWidthFor(format, referenceOperation(operation)) != lane_width) {
            @compileError("reference lane width must match the measured lane width");
        }
    }
    if (descriptor.lane_width != lane_width) return error.LaneWidthMismatch;
    // The descriptor records the historical TSV fixture row count, which is
    // not the schema-3 publication record count, so the two are not compared.


    const path = entry.artifact;
    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    const summary = try countRecords(init.io, file);
    if (summary.count != entry.records or !std.mem.eql(u8, &summary.digest, &entry.digest)) {
        return error.CorpusIntegrityMismatch;
    }
    const prepared = try runner.prepareRuntime(function);
    // The reference keeps the validated runtime signature and replaces only the
    // implementation, so both providers are timed on the same descriptor.
    const reference_entry = references.entryFor(function, prepared.entry) orelse {
        std.debug.print(
            "signature={} operation={s} artifact={s} corpus_records={} lane_width={} " ++
                "provider=zig-vector available=false reason=unsupported_vector_signature\n",
            .{ entry.signature_index, function.op, path, summary.count, lane_width },
        );
        return;
    };
    const reference: runner.PreparedRuntime = .{ .entry = &reference_entry };
    var samples: Samples = .{ .corpus_count = summary.count };
    const sampled_digest = try selectSamples(init.io, file, function, lane_width, &samples);
    if (!std.mem.eql(u8, &summary.digest, &sampled_digest)) return error.CorpusChanged;
    const warmup = measureZmath(init.io, operation, format, &samples, 1);
    const repetitions = std.math.clamp(
        @divFloor(target_duration_ns, @max(warmup.elapsed_ns, 1)),
        1,
        repetitions_max,
    );
    const digest_hex = std.fmt.bytesToHex(summary.digest, .lower);
    for (0..timing_repetitions) |repetition| {
        const zmath_result = measureZmath(init.io, operation, format, &samples, repetitions);
        const reference_result = measureReference(init.io, &reference, format, &samples, repetitions);
        std.debug.print(
            "target={s} cpu={s} optimize={s} corpus_id={s} signature={} operation={s} " ++
                "repetition={} artifact={s} corpus_records={} corpus_input_count={} samples={} " ++
                "groups={} lane_width={} calls={} lanes={} elapsed_ns={} checksum={x:0>16} " ++
                "corpus_sha256={s} acceptance=none provider=zmath-vector\n",
            .{
                target_mode.target, target_mode.cpu, target_mode.mode,
                descriptor.corpus_id, entry.signature_index, function.op,
                repetition, path,
                samples.corpus_count, descriptor.input_count,
                samples.count, samples.group_count,
                lane_width, zmath_result.calls,
                zmath_result.lanes, zmath_result.elapsed_ns,
                zmath_result.checksum, digest_hex,
            },
        );
        std.debug.print(
            "target={s} cpu={s} optimize={s} corpus_id={s} signature={} operation={s} " ++
                "repetition={} artifact={s} corpus_records={} corpus_input_count={} samples={} " ++
                "groups={} lane_width={} calls={} lanes={} elapsed_ns={} checksum={x:0>16} " ++
                "corpus_sha256={s} acceptance=none provider=zig-vector\n",
            .{
                target_mode.target, target_mode.cpu, target_mode.mode,
                descriptor.corpus_id, entry.signature_index, function.op,
                repetition, path,
                samples.corpus_count, descriptor.input_count,
                samples.count, samples.group_count,
                lane_width, reference_result.calls,
                reference_result.lanes, reference_result.elapsed_ns,
                reference_result.checksum, digest_hex,
            },
        );
    }
}

fn floatType(comptime format: targets.Format) type {
    return switch (format) {
        .h => f16,
        .f => f32,
        .d => f64,
    };
}

fn bitsType(comptime format: targets.Format) type {
    return switch (format) {
        .h => u16,
        .f => u32,
        .d => u64,
    };
}

fn decodeLane(comptime format: targets.Format, bits: u64) floatType(format) {
    return @bitCast(@as(bitsType(format), @truncate(bits)));
}

fn encodeLane(comptime format: targets.Format, value: floatType(format)) u64 {
    return @as(bitsType(format), @bitCast(value));
}

/// Applies the measured `zmath.vector` entry point to one lane group.
fn zmathVector(
    comptime operation: Operation,
    comptime format: targets.Format,
    comptime lane_width: u32,
    lanes: @Vector(lane_width, floatType(format)),
) @Vector(lane_width, floatType(format)) {
    return switch (operation) {
        .exp => switch (format) {
            .h => zmath.vector.exphv(lanes),
            .f => zmath.vector.expfv(lanes),
            .d => zmath.vector.expdv(lanes),
        },
        .log => switch (format) {
            .h => zmath.vector.loghv(lanes),
            .f => zmath.vector.logfv(lanes),
            .d => zmath.vector.logdv(lanes),
        },
        .sin => switch (format) {
            // `sin` has no `sinhv` entry point, because `sinhv` is the sinh
            // generic. The generic `sinv` selects the binary16 kernel instead.
            .h => zmath.vector.sinv(lanes),
            .f => zmath.vector.sinfv(lanes),
            .d => zmath.vector.sindv(lanes),
        },
    };
}

fn mixChecksum(checksum: u64, bits: u64) u64 {
    return (checksum ^ bits) *% 0x100_0000_01b3;
}

fn loadGroup(
    comptime format: targets.Format,
    comptime lane_width: u32,
    samples: *const Samples,
    group: usize,
) @Vector(lane_width, floatType(format)) {
    var lanes: @Vector(lane_width, floatType(format)) = undefined;
    inline for (0..lane_width) |lane| {
        lanes[lane] = decodeLane(format, samples.inputs[group * lane_width + lane][0].value_bits);
    }
    return lanes;
}

fn foldLanes(
    comptime format: targets.Format,
    comptime lane_width: u32,
    lanes: @Vector(lane_width, floatType(format)),
    checksum: u64,
) u64 {
    var folded = checksum;
    inline for (0..lane_width) |lane| {
        folded = mixChecksum(folded, encodeLane(format, lanes[lane]));
    }
    return folded;
}

fn measureZmath(
    io: std.Io,
    comptime operation: Operation,
    comptime format: targets.Format,
    samples: *const Samples,
    repetitions: u64,
) Measurement {
    const lane_width = comptime targets.laneWidthFor(format);
    return measure(io, lane_width, repetitions, struct {
        fn run(state: MeasureState) u64 {
            const batch = state.samples;
            var checksum: u64 = 0;
            for (0..batch.group_count) |group| {
                const lanes = loadGroup(format, lane_width, batch, group);
                checksum = foldLanes(
                    format,
                    lane_width,
                    zmathVector(operation, format, lane_width, lanes),
                    checksum,
                );
            }
            return checksum;
        }
    }.run, .{ .samples = samples });
}

fn measureReference(
    io: std.Io,
    reference: *const runner.PreparedRuntime,
    comptime format: targets.Format,
    samples: *const Samples,
    repetitions: u64,
) Measurement {
    const lane_width = comptime targets.laneWidthFor(format);
    return measure(io, lane_width, repetitions, struct {
        fn run(state: MeasureState) u64 {
            const batch = state.samples;
            const provider = state.reference.?;
            var checksum: u64 = 0;
            var lanes: Inputs = undefined;
            for (0..batch.group_count) |group| {
                inline for (0..lane_width) |lane| {
                    lanes[lane] = batch.inputs[group * lane_width + lane][0];
                }
                const raw = provider.invoke(&lanes);
                if (raw.field_count < lane_width) return 0;
                inline for (0..lane_width) |lane| {
                    checksum = mixChecksum(checksum, raw.values[lane]);
                }
            }
            return checksum;
        }
    }.run, .{ .samples = samples, .reference = reference });
}

fn measure(
    io: std.Io,
    comptime lane_width: u32,
    repetitions: u64,
    comptime body: *const fn (state: MeasureState) u64,
    state: MeasureState,
) Measurement {
    comptime std.debug.assert(lane_width > 0);
    const samples = state.samples;
    std.debug.assert(samples.group_count > 0);
    std.debug.assert(repetitions > 0);
    std.debug.assert(repetitions <= repetitions_max);
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    var checksum: u64 = 0;
    for (0..repetitions) |_| {
        checksum = body(state);
    }
    std.mem.doNotOptimizeAway(&checksum);
    const elapsed = std.Io.Clock.awake.now(io).nanoseconds - start;
    std.debug.assert(elapsed >= 0);
    return .{
        .elapsed_ns = @intCast(elapsed),
        .calls = repetitions * samples.group_count,
        .lanes = repetitions * @as(u64, @intCast(samples.group_count * lane_width)),
        .checksum = checksum,
    };
}


fn parseOptions(args: []const []const u8) !Options {
    if (args.len == 0) return error.InvalidArguments;
    var options = Options{};
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
        } else if (std.mem.startsWith(u8, argument, "--repetitions")) {
            return error.InvalidRepetitions;
        } else return error.InvalidArguments;
    }
    return options;
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
    comptime lane_width: u32,
    samples: *Samples,
) !Digest {
    samples.count = @intCast(@min(sample_count_max, samples.corpus_count));
    samples.group_count = samples.count / lane_width;
    if (samples.group_count == 0) return error.InsufficientSamples;
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var frame: [encoded_record_capacity]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var record_index: u64 = 0;
    var sample_index: usize = 0;
    while (try corpus.readEncodedRecord(&reader.interface, &frame)) |bytes| : (record_index += 1) {
        if (sample_index == samples.count) return error.RecordCountMismatch;
        hasher.update(bytes);
        const selected_index = if (samples.count == 1) 0 else @divFloor(@as(u64, sample_index) * (samples.corpus_count - 1), samples.count - 1);
        if (record_index != selected_index) continue;
        const record = try corpus.decodeCorpusRecord(bytes);
        try storeSample(function, samples, sample_index, &record);
        sample_index += 1;
    }
    if (sample_index != samples.count or record_index != samples.corpus_count) {
        return error.IncompleteSample;
    }
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn storeSample(
    function: corpus.Function,
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
}

/// The record argument descriptors must match the manifest function. The stored
/// result values are never compared: this benchmark reports performance only
/// and grants no acceptance.
fn decodeInput(
    field: corpus.CorpusField,
    expected: corpus.InputDescriptor,
    tag_buffer: []u8,
) !corpus.OracleInputField {
    const descriptor: corpus.InputDescriptor = switch (field) {
        .float => |value| .{ .float = value.format },
        .signed_integer => |value| .{ .integer = value.integer_type },
        .unsigned_integer => |value| .{ .integer = value.integer_type },
        .tag => .tag,
        .rounding => .fromfp_round,
        .boolean => return error.InvalidInputDescriptor,
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
        .tag => |value| {
            if (value.len > tag_buffer.len) return error.TagTooLong;
            @memcpy(tag_buffer[0..value.len], value);
            return corpus.oracleTagInput(tag_buffer[0..value.len]);
        },
        .boolean => return error.InvalidInputDescriptor,
    };
    return corpus.oracleLiteralInput(descriptor, bits);
}
