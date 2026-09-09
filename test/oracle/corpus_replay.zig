const std = @import("std");
const active_target_mode = @import("active_target_mode");
const corpus = @import("corpus_support");
const corpus_set = @import("corpus_set");
const runner = @import("corpus_runner");

const default_output_root = "test/corpus";
const file_reader_capacity: usize = 64 * 1024;
const max_arguments = corpus.max_argument_count;

pub fn main(init: std.process.Init) !void {
    if (!active_target_mode.approved_corpus_pair) return error.UnapprovedCorpusProfile;

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    const parsed = try parseArguments(arguments);
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    const selected_count = try requestedSelectionCount(&manifest, parsed.filters);
    const run_root = try buildRunRoot(init.gpa, parsed);
    defer init.gpa.free(run_root);

    const directory = std.Io.Dir.cwd();
    var published = try corpus_set.load(
        init.io,
        init.gpa,
        directory,
        run_root,
        &manifest,
        .{
            .target = active_target_mode.target,
            .cpu = active_target_mode.cpu,
            .mode = active_target_mode.mode,
        },
    );
    defer published.deinit(init.gpa);
    try validatePublishedSelection(
        &manifest,
        &published,
        parsed.filters,
        selected_count,
    );

    var total_records: u64 = 0;
    for (published.entries[0..published.count]) |*entry| {
        const function = &manifest.function_values[entry.signature_index];
        const record_count = try replayEntry(init.io, directory, entry, function);
        total_records = std.math.add(u64, total_records, record_count) catch
            return error.RecordCountOverflow;
    }
    std.debug.print(
        "corpus replay verified: descriptors={} records={}\n",
        .{ published.count, total_records },
    );
}

const FilterOptions = struct {
    operation: ?[]const u8 = null,
    format: ?corpus.Format = null,
};

const ParsedArguments = struct {
    output_root: []const u8,
    filters: FilterOptions,
};

const EncodedInput = struct {
    word: u64,
    tag: []const u8,
};

fn parseArguments(arguments: []const []const u8) !ParsedArguments {
    var parsed = ParsedArguments{
        .output_root = default_output_root,
        .filters = .{},
    };
    var argument_index: usize = 1;
    if (arguments.len > 1 and !std.mem.startsWith(u8, arguments[1], "--")) {
        if (arguments[1].len == 0) return error.InvalidArguments;
        parsed.output_root = arguments[1];
        argument_index = 2;
    }

    while (argument_index < arguments.len) : (argument_index += 1) {
        const argument = arguments[argument_index];
        if (std.mem.startsWith(u8, argument, "--operation=")) {
            if (parsed.filters.operation != null) return error.InvalidArguments;
            const operation = argument["--operation=".len..];
            if (operation.len == 0) return error.InvalidArguments;
            parsed.filters.operation = operation;
        } else if (std.mem.startsWith(u8, argument, "--format=")) {
            if (parsed.filters.format != null) return error.InvalidArguments;
            const format_name = argument["--format=".len..];
            if (format_name.len == 0) return error.InvalidArguments;
            parsed.filters.format =
                std.meta.stringToEnum(corpus.Format, format_name) orelse
                return error.InvalidFormatFilter;
        } else {
            return error.InvalidArguments;
        }
    }
    return parsed;
}

fn buildRunRoot(
    allocator: std.mem.Allocator,
    arguments: ParsedArguments,
) ![]u8 {
    const generated_root = try std.fs.path.join(
        allocator,
        &.{ arguments.output_root, "generated" },
    );
    errdefer allocator.free(generated_root);
    if (arguments.filters.operation == null and arguments.filters.format == null) {
        return generated_root;
    }

    const operation_name = arguments.filters.operation orelse "all";
    const format_name = if (arguments.filters.format) |format|
        @tagName(format)
    else
        "all";
    const probe_name = try std.fmt.allocPrint(
        allocator,
        "{s}-{s}",
        .{ operation_name, format_name },
    );
    defer allocator.free(probe_name);
    const run_root = try std.fs.path.join(
        allocator,
        &.{ generated_root, "probes", probe_name },
    );
    allocator.free(generated_root);
    return run_root;
}

fn requestedSelectionCount(
    manifest: *const corpus.Manifest,
    filters: FilterOptions,
) !usize {
    var selected_count: usize = 0;
    var operation_match_count: usize = 0;
    var format_match_count: usize = 0;
    for (manifest.function_values[0..manifest.function_count]) |*function| {
        if (filters.operation) |operation| {
            if (!std.mem.eql(u8, function.op, operation)) continue;
            operation_match_count += 1;
        }
        if (filters.format) |format| {
            if (descriptorFormat(function) != format) continue;
            format_match_count += 1;
        }
        selected_count += 1;
    }
    if (selected_count == 0) {
        if (filters.operation != null and operation_match_count == 0) {
            return error.InvalidOperationFilter;
        }
        if (filters.format != null and format_match_count == 0) {
            return error.InvalidFormatFilter;
        }
        return error.EmptySelection;
    }
    return selected_count;
}

fn validatePublishedSelection(
    manifest: *const corpus.Manifest,
    published: *const corpus_set.Set,
    filters: FilterOptions,
    expected_count: usize,
) !void {
    if (published.count != expected_count) return error.PublishedSelectionMismatch;

    var published_index: usize = 0;
    for (manifest.function_values[0..manifest.function_count], 0..) |*function, index| {
        if (!matchesFilters(function, filters)) continue;
        if (published_index >= published.count) return error.PublishedSelectionMismatch;
        const entry = &published.entries[published_index];
        if (entry.signature_index != index) return error.PublishedSelectionMismatch;
        if (!std.mem.eql(u8, entry.operation, function.op)) {
            return error.PublishedSignatureMismatch;
        }
        const signature = try corpus_set.evaluatorSignature(function);
        const evaluator = try corpus_set.evaluatorCategory(signature);
        if (evaluator == .none) return error.UnsupportedEvaluator;
        if (entry.evaluator != evaluator) return error.PublishedEvaluatorMismatch;
        published_index += 1;
    }
    if (published_index != published.count) return error.PublishedSelectionMismatch;
}

fn matchesFilters(function: *const corpus.Function, filters: FilterOptions) bool {
    if (filters.operation) |operation| {
        if (!std.mem.eql(u8, function.op, operation)) return false;
    }
    if (filters.format) |format| {
        if (descriptorFormat(function) != format) return false;
    }
    return true;
}

fn descriptorFormat(function: *const corpus.Function) corpus.Format {
    if (function.result.floatFormat()) |format| return format;
    for (function.arguments()) |argument| {
        if (argument.floatFormat()) |format| return format;
    }
    return .h;
}

fn replayEntry(
    io: std.Io,
    directory: std.Io.Dir,
    entry: *const corpus_set.Entry,
    function: *const corpus.Function,
) !u64 {
    var record_index: u64 = 0;
    errdefer |replay_error| std.debug.print(
        "corpus replay entry failed: signature={} operation={s} artifact={s} " ++
            "record_index={} error={s}\n",
        .{
            entry.signature_index,
            entry.operation,
            entry.artifact,
            record_index,
            @errorName(replay_error),
        },
    );
    if (entry.records == 0) return error.EmptyCorpus;
    const prepared = try runner.prepareRuntime(function.*);

    const file = try directory.openFile(io, entry.artifact, .{});
    defer file.close(io);
    var read_buffer: [file_reader_capacity]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    var frame_buffers: [2][corpus_set.record_buffer_capacity]u8 = undefined;
    var frame_slot: u1 = 0;
    var previous_record: ?corpus.CorpusRecord = null;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    while (try corpus.readEncodedRecord(
        &file_reader.interface,
        frame_buffers[frame_slot][0..],
    )) |encoded| {
        hasher.update(encoded);
        if (record_index >= entry.records) {
            std.debug.print(
                "corpus replay count mismatch: signature={} operation={s} " ++
                    "expected_records={} extra_record_index={}\n",
                .{
                    entry.signature_index,
                    entry.operation,
                    entry.records,
                    record_index,
                },
            );
            return error.RecordCountMismatch;
        }

        const record = try corpus.decodeCorpusRecord(encoded);
        if (previous_record) |*previous| {
            try corpus.validateCorpusRecordOrder(previous, &record);
        }
        try replayRecord(entry, function, &prepared, record_index, &record);
        previous_record = record;
        frame_slot ^= 1;
        record_index = std.math.add(u64, record_index, 1) catch
            return error.RecordCountOverflow;
    }

    if (record_index != entry.records) {
        std.debug.print(
            "corpus replay count mismatch: signature={} operation={s} " ++
                "expected_records={} actual_records={}\n",
            .{ entry.signature_index, entry.operation, entry.records, record_index },
        );
        return error.RecordCountMismatch;
    }
    var digest: corpus_set.Digest = undefined;
    hasher.final(&digest);
    if (!std.mem.eql(u8, &digest, &entry.digest)) {
        const expected_hex = std.fmt.bytesToHex(entry.digest, .lower);
        const actual_hex = std.fmt.bytesToHex(digest, .lower);
        std.debug.print(
            "corpus replay digest mismatch: signature={} operation={s} " ++
                "expected_sha256={s} actual_sha256={s}\n",
            .{
                entry.signature_index,
                entry.operation,
                expected_hex[0..],
                actual_hex[0..],
            },
        );
        return error.CorpusDigestMismatch;
    }

    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    std.debug.print(
        "corpus replay verified: signature={} operation={s} records={} sha256={s}\n",
        .{ entry.signature_index, entry.operation, record_index, digest_hex[0..] },
    );
    return record_index;
}

fn replayRecord(
    entry: *const corpus_set.Entry,
    function: *const corpus.Function,
    prepared: *const runner.PreparedRuntime,
    record_index: u64,
    record: *const corpus.CorpusRecord,
) !void {
    errdefer |replay_error| logRecordFailure(
        entry,
        record_index,
        record,
        replay_error,
    );
    try validateRecordSignature(function, record);

    var inputs: [max_arguments]corpus.OracleInputField = undefined;
    try encodeInputs(function, record, &inputs);
    const raw = prepared.invoke(&inputs);
    var actual_fields: [corpus.max_result_field_count]corpus.CorpusField = undefined;
    const count = try runner.materializeRawRuntimeFields(function.*, prepared, raw, &actual_fields);
    if (count != record.results.count) return error.RuntimeMismatch;
    for (actual_fields[0..count], record.results.slice()) |actual, expected| {
        if (!std.meta.eql(actual, expected)) return error.RuntimeMismatch;
    }
}

fn validateRecordSignature(
    function: *const corpus.Function,
    record: *const corpus.CorpusRecord,
) !void {
    if (!std.mem.eql(u8, record.operation, function.op)) {
        return error.CorpusSignatureMismatch;
    }
    if (!provenanceEqual(&record.provenance, &function.provenance)) {
        return error.CorpusSignatureMismatch;
    }
    if (@as(usize, function.arity) != function.arguments().len) {
        return error.ManifestSignatureMismatch;
    }
    if (record.arguments.count != function.arguments().len) {
        return error.CorpusSignatureMismatch;
    }
    if (!std.meta.eql(record.result_descriptor, function.result)) {
        return error.CorpusSignatureMismatch;
    }
    if (record.results.count != function.result.oracleFieldCount()) {
        return error.CorpusSignatureMismatch;
    }
    if (record.max_ulp != function.max_ulp) return error.CorpusMaxUlpMismatch;
}

fn provenanceEqual(
    left: *const corpus.ProvenanceList,
    right: *const corpus.ProvenanceList,
) bool {
    if (left.count != right.count) return false;
    return std.mem.eql(corpus.Provenance, left.slice(), right.slice());
}

fn encodeInputs(
    function: *const corpus.Function,
    record: *const corpus.CorpusRecord,
    inputs: *[max_arguments]corpus.OracleInputField,
) !void {
    const descriptors = function.arguments();
    if (record.arguments.count != descriptors.len) return error.CorpusSignatureMismatch;
    for (record.arguments.slice(), descriptors, 0..) |field, descriptor, index| {
        const encoded = try encodeInput(field, descriptor);
        inputs[index] = try switch (descriptor) {
            .tag => corpus.oracleTagInput(encoded.tag),
            else => corpus.oracleLiteralInput(descriptor, encoded.word),
        };
    }
}

fn encodeInput(
    field: corpus.CorpusField,
    expected: corpus.InputDescriptor,
) !EncodedInput {
    switch (expected) {
        .float => |format| {
            const value = switch (field) {
                .float => |float_value| float_value,
                else => return error.CorpusSignatureMismatch,
            };
            if (value.format != format) return error.CorpusSignatureMismatch;
            return .{ .word = try checkedFloatWord(value.bits, format), .tag = "" };
        },
        .integer => |integer_type| {
            if (integer_type.isSigned()) {
                const value = switch (field) {
                    .signed_integer => |integer| integer,
                    else => return error.CorpusSignatureMismatch,
                };
                if (value.integer_type != integer_type) {
                    return error.CorpusSignatureMismatch;
                }
                return .{
                    .word = try corpus.encodeSignedInteger(
                        value.value,
                        integer_type.oracleValueBits(),
                    ),
                    .tag = "",
                };
            }
            const value = switch (field) {
                .unsigned_integer => |integer| integer,
                else => return error.CorpusSignatureMismatch,
            };
            if (value.integer_type != integer_type) {
                return error.CorpusSignatureMismatch;
            }
            return .{
                .word = try checkedUnsignedWord(value.value, integer_type),
                .tag = "",
            };
        },
        .tag => {
            const value = switch (field) {
                .tag => |tag| tag,
                else => return error.CorpusSignatureMismatch,
            };
            if (std.math.cast(u32, value.len) == null) return error.InputTagTooLong;
            return .{ .word = 0, .tag = value };
        },
        .fromfp_round => {
            const value = switch (field) {
                .rounding => |rounding| rounding,
                else => return error.CorpusSignatureMismatch,
            };
            const word = std.math.cast(u32, @intFromEnum(value)) orelse
                return error.InputBitsOutOfRange;
            return .{ .word = word, .tag = "" };
        },
    }
}

fn checkedFloatWord(bits: u64, format: corpus.Format) !u64 {
    return switch (format) {
        .h => @as(
            u64,
            std.math.cast(u16, bits) orelse return error.InputBitsOutOfRange,
        ),
        .f => @as(
            u64,
            std.math.cast(u32, bits) orelse return error.InputBitsOutOfRange,
        ),
        .d => bits,
    };
}

fn checkedUnsignedWord(value: u64, integer_type: corpus.IntegerType) !u64 {
    return switch (integer_type) {
        .u8 => @as(
            u64,
            std.math.cast(u8, value) orelse return error.InputBitsOutOfRange,
        ),
        .u16 => @as(
            u64,
            std.math.cast(u16, value) orelse return error.InputBitsOutOfRange,
        ),
        .u32 => @as(
            u64,
            std.math.cast(u32, value) orelse return error.InputBitsOutOfRange,
        ),
        .u64 => value,
        .i2, .i8, .i16, .i32, .i64 => error.ManifestSignatureMismatch,
    };
}

fn logRecordFailure(
    entry: *const corpus_set.Entry,
    record_index: u64,
    record: *const corpus.CorpusRecord,
    replay_error: anyerror,
) void {
    std.debug.print(
        "corpus replay record failed: signature={} operation={s} " ++
            "record_index={} error={s} inputs=[",
        .{
            entry.signature_index,
            record.operation,
            record_index,
            @errorName(replay_error),
        },
    );
    for (record.arguments.slice(), 0..) |field, index| {
        if (index != 0) std.debug.print(", ", .{});
        logInputField(field);
    }
    std.debug.print("]\n", .{});
}

fn logInputField(field: corpus.CorpusField) void {
    switch (field) {
        .float => |value| std.debug.print(
            "float:{s}:0x{x}:{s}",
            .{ @tagName(value.format), value.bits, @tagName(value.class) },
        ),
        .signed_integer => |value| std.debug.print(
            "signed:{s}:{}",
            .{ @tagName(value.integer_type), value.value },
        ),
        .unsigned_integer => |value| std.debug.print(
            "unsigned:{s}:{}",
            .{ @tagName(value.integer_type), value.value },
        ),
        .boolean => |value| std.debug.print("boolean:{}", .{value}),
        .tag => |value| {
            const preview = value[0..@min(value.len, 32)];
            std.debug.print("tag:len={}:preview={any}", .{ value.len, preview });
        },
        .rounding => |value| std.debug.print("rounding:{s}", .{@tagName(value)}),
    }
}
