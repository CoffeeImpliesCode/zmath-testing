const std = @import("std");
const active_target_mode = @import("active_target_mode");
const corpus = @import("corpus_support");
const campaigns = @import("corpus_campaigns");
const runner = @import("corpus_runner");
const corpus_set = @import("corpus_set");

comptime {
    @setEvalBranchQuota(2_000_000);
}

const max_arguments = corpus.max_argument_count;
const max_results = corpus.max_result_field_count;
const encoded_record_capacity = corpus_set.record_buffer_capacity;
const default_output_root = "test/corpus";

// Byte-exact metadata row schema; the corpus_set loader parses these fields by name.
const metadata_row_format = "signature={d};operation={s};manifest_status={s};oracle={s};" ++
    "evaluator={s};campaign={s};planned_campaign={s};availability={s};" ++
    "coverage={s};evidence_state={s};campaign_seed={x};campaign_tuple_count={d};" ++
    "selection_rule={s};cardinality={d};records={d};claims_exhaustive_full_cartesian={};" ++
    "source_metadata_available={};evidence_available={};source_hash={s};artifact={s};" ++
    "artifact_sha256={s}";

const Digest = corpus_set.Digest;

const GeneratorProfile = corpus_set.Profile;

const FilterOptions = struct {
    operation: ?[]const u8 = null,
    format: ?corpus.Format = null,
};

const ParsedArguments = struct {
    output_root: []const u8,
    filters: FilterOptions,
};

const GenerationScope = enum {
    full,
    filtered,
};

const Selection = struct {
    indices: [campaigns.manifest_campaign_count]usize = undefined,
    count: usize = 0,
    scope: GenerationScope,
};

const GeneratorOptions = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    approved_corpus_pair: bool,
    profile: GeneratorProfile,
    arguments: []const []const u8,
};

const OutputPaths = struct {
    run_root: []u8,
    records_root: []u8,
    metadata_path: []u8,
    incomplete_marker: []u8,
    complete_marker: []u8,

    fn init(allocator: std.mem.Allocator, arguments: ParsedArguments) !OutputPaths {
        const generated_root = try std.fs.path.join(
            allocator,
            &.{ arguments.output_root, "generated" },
        );
        defer allocator.free(generated_root);

        const run_root = if (arguments.filters.operation != null or
            arguments.filters.format != null)
        blk: {
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
            break :blk try std.fs.path.join(
                allocator,
                &.{ generated_root, "probes", probe_name },
            );
        } else try allocator.dupe(u8, generated_root);
        errdefer allocator.free(run_root);

        const records_root = try std.fs.path.join(
            allocator,
            &.{ run_root, "records" },
        );
        errdefer allocator.free(records_root);
        const metadata_path = try std.fs.path.join(
            allocator,
            &.{ run_root, "metadata.txt" },
        );
        errdefer allocator.free(metadata_path);
        const incomplete_marker = try std.fs.path.join(
            allocator,
            &.{ run_root, ".incomplete" },
        );
        errdefer allocator.free(incomplete_marker);
        const complete_marker = try std.fs.path.join(
            allocator,
            &.{ run_root, "COMPLETE" },
        );
        errdefer allocator.free(complete_marker);

        return .{
            .run_root = run_root,
            .records_root = records_root,
            .metadata_path = metadata_path,
            .incomplete_marker = incomplete_marker,
            .complete_marker = complete_marker,
        };
    }

    fn deinit(self: *OutputPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.run_root);
        allocator.free(self.records_root);
        allocator.free(self.metadata_path);
        allocator.free(self.incomplete_marker);
        allocator.free(self.complete_marker);
        self.* = undefined;
    }
};

const RecordContext = struct {
    writer: *std.Io.Writer,
    record_hasher: std.crypto.hash.sha2.Sha256,
    previous_encoded: [encoded_record_capacity]u8 = undefined,
    previous_length: usize = 0,
    record_count: u64 = 0,
};

const Publication = struct {
    io: std.Io,
    root_dir: std.Io.Dir,
    paths: *const OutputPaths,

    fn begin(self: *const Publication) !void {
        try self.root_dir.createDirPath(self.io, self.paths.run_root);
        try self.root_dir.createDirPath(self.io, self.paths.records_root);
        try deleteIfPresent(self.io, self.root_dir, self.paths.complete_marker);
        try deleteIfPresent(self.io, self.root_dir, self.paths.metadata_path);
        try writeAtomicSynced(
            self.io,
            self.root_dir,
            self.paths.incomplete_marker,
            "oracle-generate started\n",
        );
    }

    fn finish(self: *const Publication, metadata: []const u8, digest: Digest) !void {
        try writeAtomicSynced(
            self.io,
            self.root_dir,
            self.paths.metadata_path,
            metadata,
        );
        try deleteIfPresent(self.io, self.root_dir, self.paths.incomplete_marker);

        var complete_text: [192]u8 = undefined;
        const digest_hex = std.fmt.bytesToHex(digest, .lower);
        const complete = try std.fmt.bufPrint(
            &complete_text,
            "oracle-generate complete\nmetadata_sha256={s}\n",
            .{digest_hex[0..]},
        );
        try writeAtomicSynced(
            self.io,
            self.root_dir,
            self.paths.complete_marker,
            complete,
        );
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    try generateCorpus(.{
        .io = init.io,
        .allocator = init.gpa,
        .root_dir = std.Io.Dir.cwd(),
        .approved_corpus_pair = active_target_mode.approved_corpus_pair,
        .profile = .{
            .target = active_target_mode.target,
            .cpu = active_target_mode.cpu,
            .mode = active_target_mode.mode,
        },
        .arguments = args,
    });
}

fn generateCorpus(options: GeneratorOptions) !void {
    if (!options.approved_corpus_pair) return error.UnapprovedCorpusProfile;

    const parsed = try parseArguments(options.arguments);
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    const matrix = try campaigns.classifyManifest(&manifest);
    if (matrix.count != campaigns.manifest_campaign_count) {
        return error.ManifestCountMismatch;
    }
    const selection = try selectDefinitions(&matrix, parsed.filters);
    if (selection.count == 0) return error.EmptySelection;

    var paths = try OutputPaths.init(options.allocator, parsed);
    defer paths.deinit(options.allocator);
    const publication: Publication = .{
        .io = options.io,
        .root_dir = options.root_dir,
        .paths = &paths,
    };
    try publication.begin();

    const descriptor_hash = try descriptorProfileHash(
        options.profile,
        &matrix,
        selection,
    );
    var metadata: std.ArrayList(u8) = .empty;
    defer metadata.deinit(options.allocator);
    try appendMetadataHeader(
        options.allocator,
        &metadata,
        options.profile,
        parsed,
        selection,
        descriptor_hash,
    );
    for (selection.indices[0..selection.count]) |index| {
        const definition = matrix.at(index) orelse return error.ManifestCountMismatch;
        try generateDefinition(
            options.allocator,
            options.io,
            options.root_dir,
            &metadata,
            &paths,
            index,
            definition,
        );
    }

    var metadata_digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(metadata.items, &metadata_digest, .{});
    try publication.finish(metadata.items, metadata_digest);
}

fn parseArguments(args: []const []const u8) !ParsedArguments {
    var parsed: ParsedArguments = .{
        .output_root = default_output_root,
        .filters = .{},
    };
    var argument_index: usize = 1;
    if (args.len > 1 and !std.mem.startsWith(u8, args[1], "--")) {
        if (args[1].len == 0) return error.InvalidArguments;
        parsed.output_root = args[1];
        argument_index = 2;
    }

    while (argument_index < args.len) : (argument_index += 1) {
        const argument = args[argument_index];
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

fn selectDefinitions(
    matrix: *const campaigns.CampaignMatrix,
    filters: FilterOptions,
) !Selection {
    var selection: Selection = .{
        .scope = if (filters.operation == null and filters.format == null)
            .full
        else
            .filtered,
    };
    var operation_match_count: usize = 0;
    var format_match_count: usize = 0;
    for (matrix.definitions[0..matrix.count], 0..) |*definition, index| {
        if (filters.operation) |operation| {
            if (!std.mem.eql(u8, definition.function.op, operation)) continue;
            operation_match_count += 1;
        }
        if (filters.format) |format| {
            if (campaignFormat(definition.function) != format) continue;
            format_match_count += 1;
        }
        selection.indices[selection.count] = index;
        selection.count += 1;
    }
    if (selection.count == 0) {
        if (filters.operation != null and operation_match_count == 0) {
            return error.InvalidOperationFilter;
        }
        if (filters.format != null and format_match_count == 0) {
            return error.InvalidFormatFilter;
        }
        return error.EmptySelection;
    }
    return selection;
}

fn appendMetadataHeader(
    allocator: std.mem.Allocator,
    metadata: *std.ArrayList(u8),
    profile: GeneratorProfile,
    arguments: ParsedArguments,
    selection: Selection,
    descriptor_hash: Digest,
) !void {
    try appendFormat("ZCDM version=1\n", allocator, metadata, .{});
    try appendDigestLine(allocator, metadata, "manifest_descriptor_sha256", descriptor_hash);
    try appendFormat(
        "core_math_repository={s}\ncore_math_revision={s}\n",
        allocator,
        metadata,
        .{ campaigns.core_math_repository, campaigns.core_math_revision },
    );
    try appendFormat(
        "profile_target={s}\nprofile_cpu={s}\nprofile_mode={s}\n",
        allocator,
        metadata,
        .{ profile.target, profile.cpu, profile.mode },
    );
    try appendFormat(
        "generation_scope={s}\nfunction_count={d}\nselected_signature_count={d}\n",
        allocator,
        metadata,
        .{ @tagName(selection.scope), selection.count, selection.count },
    );
    try appendFormat(
        "operation_filter={s}\nformat_filter={s}\nrecord_codec_version={d}\n\n",
        allocator,
        metadata,
        .{
            arguments.filters.operation orelse "all",
            if (arguments.filters.format) |format| @tagName(format) else "all",
            corpus.descriptor_corpus_codec_version,
        },
    );
}

fn generateDefinition(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    metadata: *std.ArrayList(u8),
    paths: *const OutputPaths,
    index: usize,
    definition: *const campaigns.CampaignDefinition,
) !void {
    const function = definition.function;
    const source = sourceFor(definition);
    const source_hash = sourceHash(source);
    const planned_class = definition.plannedCampaignClass();
    const campaign_class = definition.campaignClass();
    const coverage = definition.coverageClaim();
    const evidence_state = evidenceState(definition);
    const source_available = definition.sourceMetadataAvailable();
    const campaign_seed = deterministicSeed(definition);
    const campaign_artifact = campaignArtifact(definition);
    const cardinality = definition.cardinality() catch |err| switch (err) {
        error.CampaignUnavailable => 0,
        else => return err,
    };
    const campaign_tuple_count = campaignTupleCount(definition, cardinality);
    const should_generate = campaignEvidenceAvailable(definition);
    const signature = try corpus_set.evaluatorSignature(&function);
    const evaluator_name = @tagName(try corpus_set.evaluatorCategory(signature));
    const artifact_path = try generatedArtifactPath(
        allocator,
        paths.records_root,
        index,
        function.op,
    );
    defer allocator.free(artifact_path);

    var record_count: u64 = 0;
    var artifact_hash: Digest = [_]u8{0} ** std.crypto.hash.sha2.Sha256.digest_length;
    if (should_generate) {
        if (cardinality == 0) return error.RecordCountMismatch;
        var atomic = try root_dir.createFileAtomic(io, artifact_path, .{
            .make_path = true,
            .replace = true,
        });
        defer atomic.deinit(io);
        var write_buffer: [64 * 1024]u8 = undefined;
        var writer = atomic.file.writer(io, &write_buffer);
        var context: RecordContext = .{
            .writer = &writer.interface,
            .record_hasher = std.crypto.hash.sha2.Sha256.init(.{}),
        };
        try campaigns.visitDefinitionRecords(definition, &context, visitRecord);
        if (context.record_count != cardinality) return error.RecordCountMismatch;
        try writer.interface.flush();
        try atomic.file.sync(io);
        context.record_hasher.final(&artifact_hash);
        try atomic.replace(io);
        record_count = context.record_count;
    }

    const source_hash_hex = std.fmt.bytesToHex(source_hash, .lower);
    const artifact_hash_hex = std.fmt.bytesToHex(artifact_hash, .lower);
    const availability: campaigns.Availability = if (should_generate)
        .records_ready
    else
        definition.availability();
    try appendFormat(
        metadata_row_format,
        allocator,
        metadata,
        .{
            index,
            function.op,
            @tagName(function.status),
            @tagName(function.oracle),
            evaluator_name,
            @tagName(campaign_class),
            @tagName(planned_class),
            @tagName(availability),
            @tagName(coverage),
            @tagName(evidence_state),
            campaign_seed,
            campaign_tuple_count,
            campaign_artifact,
            cardinality,
            record_count,
            definition.claimsExhaustiveFullCartesian(),
            source_available,
            should_generate,
            source_hash_hex[0..],
            artifact_path,
            if (should_generate) artifact_hash_hex[0..] else "none",
        },
    );
    try appendSourceFields(allocator, metadata, source);
    try appendFormat("\n", allocator, metadata, .{});
}

fn visitRecord(context: *RecordContext, visit: *const campaigns.RecordVisit) !void {
    var input_bits: [max_arguments]u64 = [_]u64{0} ** max_arguments;
    var input_tags: [max_arguments][]const u8 = [_][]const u8{""} ** max_arguments;
    try encodeInputs(
        visit.function,
        visit.arguments.slice(),
        &input_bits,
        &input_tags,
    );
    errdefer std.debug.print(
        "scalar candidate failed: operation={s} row={} inputs={any}\n",
        .{ visit.function.op, context.record_count, input_bits[0..visit.arguments.count] },
    );

    var result_fields: [max_results]corpus.CorpusField = undefined;
    const outcome = try runner.evaluateFunctionWithTags(
        visit.function,
        input_bits[0..visit.arguments.count],
        input_tags[0..visit.arguments.count],
    );
    var evidence = switch (outcome) {
        .verified => |value| value,
        .unsupported => return error.ExpectedEvidenceUnsupported,
    };
    try runner.verifyExpectedStatus(&evidence, visit.expected_status);
    if (visit.expected_results.len != 0) {
        try runner.verifyExpectedResults(visit.function, &evidence, visit.expected_results);
    }
    const result_count = runner.materializeResultFields(
        visit.function,
        &evidence,
        &result_fields,
    ) catch return error.ResultEncoding;

    const record = try campaigns.buildRecordFromFieldsWithUlp(
        visit.function,
        visit.arguments.slice(),
        result_fields[0..result_count],
        visit.max_ulp,
    );
    const encoded_length = try corpus.corpusRecordEncodedLength(&record);
    var encoded: [encoded_record_capacity]u8 = undefined;
    if (encoded_length > encoded.len) return error.RecordEncoding;
    const bytes = try corpus.encodeCorpusRecord(&record, encoded[0..]);
    if (context.previous_length != 0) {
        const previous = try corpus.decodeCorpusRecord(
            context.previous_encoded[0..context.previous_length],
        );
        const current = try corpus.decodeCorpusRecord(bytes);
        try corpus.validateCorpusRecordOrder(&previous, &current);
    }
    try context.writer.writeAll(bytes);
    context.record_hasher.update(bytes);
    @memcpy(context.previous_encoded[0..bytes.len], bytes);
    context.previous_length = bytes.len;
    context.record_count += 1;
}

fn encodeInputs(
    function: corpus.Function,
    arguments: []const corpus.CorpusField,
    input_bits: *[max_arguments]u64,
    input_tags: *[max_arguments][]const u8,
) !void {
    const descriptors = function.arguments();
    if (arguments.len != descriptors.len) return error.InputEncoding;
    for (arguments, descriptors, 0..) |field, argument, index| {
        const descriptor = argument.oracleDescriptor();
        input_tags[index] = "";
        switch (field) {
            .float => |value| {
                if (descriptor.kind != .float or
                    descriptor.format.code != value.format.oracleDescriptor().code)
                {
                    return error.InputEncoding;
                }
                input_bits[index] = value.bits;
            },
            .signed_integer => |value| {
                if (descriptor.kind != .signed_integer or
                    descriptor.value_bits != value.integer_type.oracleValueBits())
                {
                    return error.InputEncoding;
                }
                input_bits[index] = corpus.encodeSignedInteger(
                    value.value,
                    descriptor.value_bits,
                ) catch return error.InputEncoding;
            },
            .unsigned_integer => |value| {
                if (descriptor.kind != .unsigned_integer or
                    descriptor.value_bits != value.integer_type.oracleValueBits())
                {
                    return error.InputEncoding;
                }
                input_bits[index] = value.value;
            },
            .boolean => |value| {
                if (descriptor.kind != .boolean) return error.InputEncoding;
                input_bits[index] = @intFromBool(value);
            },
            .tag => |value| {
                if (descriptor.kind != .tag) return error.InputEncoding;
                input_bits[index] = 0;
                input_tags[index] = value;
            },
            .rounding => |value| {
                if (descriptor.kind != .rounding) return error.InputEncoding;
                input_bits[index] = @intFromEnum(value);
            },
            // Deliberately a separate arm from `.rounding`, and deliberately
            // keyed on the stored field kind rather than on a numeric range.
            // `FromFpRound` numbers its modes 0-4 and `RoundMode` numbers them
            // 0-3, so accepting either field here would silently reinterpret the
            // value 1: `rounding`'s `nearest_from_zero` would become
            // `round_mode`'s `toward_zero`. Only a `.round_mode` field can
            // satisfy a `.round_mode` descriptor.
            .round_mode => |value| {
                if (descriptor.kind != .round_mode) return error.InputEncoding;
                input_bits[index] = @intFromEnum(value);
            },
            // A classification is a result-only shape. No `InputDescriptor`
            // names it, so a stored classification in an argument position is a
            // corrupt record, not a value this code should encode.
            .classification => return error.InputEncoding,
        }
    }
}

fn campaignFormat(function: corpus.Function) corpus.Format {
    if (function.result.floatFormat()) |format| return format;
    for (function.arguments()) |argument| if (argument.floatFormat()) |format| return format;
    return .h;
}

fn evidenceState(definition: *const campaigns.CampaignDefinition) campaigns.EvidenceAvailability {
    return switch (definition.data) {
        .unavailable => .source_metadata_unavailable,
        .exhaustive_h_unary => |spec| spec.evidence,
        .bounded_h_integer_domain => |spec| spec.evidence,
        .explicit_special_tuple_grid => |spec| spec.evidence,
        .selected_cartesian => |spec| spec.evidence,
        .selected_unary_f => |spec| spec.evidence,
        .selected_unary_d => |spec| spec.evidence,
        .exact_bit_status => |spec| spec.evidence,
    };
}

fn campaignEvidenceAvailable(definition: *const campaigns.CampaignDefinition) bool {
    return definition.campaignClass() != .unavailable;
}

fn deterministicSeed(definition: *const campaigns.CampaignDefinition) u64 {
    return switch (definition.data) {
        .unavailable => |spec| spec.deterministic_seed,
        .exhaustive_h_unary => |spec| spec.deterministic_seed,
        .bounded_h_integer_domain => |spec| spec.deterministic_seed,
        .explicit_special_tuple_grid => |spec| spec.deterministic_seed,
        .selected_cartesian => |spec| spec.deterministic_seed,
        .selected_unary_f => |spec| spec.deterministic_seed,
        .selected_unary_d => |spec| spec.deterministic_seed,
        .exact_bit_status => |spec| spec.deterministic_seed,
    };
}

fn campaignTupleCount(
    definition: *const campaigns.CampaignDefinition,
    cardinality: u64,
) u64 {
    return switch (definition.data) {
        .unavailable => |spec| spec.tuple_count,
        else => cardinality,
    };
}

fn campaignArtifact(definition: *const campaigns.CampaignDefinition) []const u8 {
    return switch (definition.data) {
        .unavailable => |spec| spec.artifact,
        .exhaustive_h_unary => |spec| spec.artifact,
        .bounded_h_integer_domain => |spec| spec.artifact,
        .explicit_special_tuple_grid => |spec| spec.artifact,
        .selected_cartesian => |spec| spec.artifact,
        .selected_unary_f => |spec| spec.artifact,
        .selected_unary_d => |spec| spec.artifact,
        .exact_bit_status => |spec| spec.artifact,
    };
}

fn sourceFor(definition: *const campaigns.CampaignDefinition) ?campaigns.SourcePin {
    return switch (definition.data) {
        .unavailable => |spec| spec.source,
        .exhaustive_h_unary => |spec| spec.source,
        .bounded_h_integer_domain => |spec| spec.source,
        .explicit_special_tuple_grid => |spec| spec.source,
        .selected_cartesian => |spec| spec.source,
        .selected_unary_f => |metadata| metadata.source,
        .selected_unary_d => |metadata| metadata.source,
        .exact_bit_status => |spec| spec.source,
    };
}

fn generatedArtifactPath(
    allocator: std.mem.Allocator,
    records_root: []const u8,
    index: usize,
    operation: []const u8,
) ![]u8 {
    if (operation.len == 0 or operation.len > 128) return error.ArtifactNameInvalid;
    for (operation) |byte| {
        if (!((byte >= 'a' and byte <= 'z') or
            (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or byte == '_'))
        {
            return error.ArtifactNameInvalid;
        }
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}/{d:0>3}_{s}.zcdr",
        .{ records_root, index, operation },
    );
}

fn appendSourceFields(
    allocator: std.mem.Allocator,
    metadata: *std.ArrayList(u8),
    source: ?campaigns.SourcePin,
) !void {
    if (source) |pin| {
        try appendFormat(
            ";source_repository={s};source_revision={s};source_path={s}",
            allocator,
            metadata,
            .{ pin.repository, pin.revision, pin.path },
        );
    } else {
        try appendFormat(
            ";source_repository=none;source_revision=none;source_path=none",
            allocator,
            metadata,
            .{},
        );
    }
}

fn sourceHash(source: ?campaigns.SourcePin) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    if (source) |pin| {
        hasher.update(pin.repository);
        hasher.update("\x00");
        hasher.update(pin.revision);
        hasher.update("\x00");
        hasher.update(pin.path);
    } else {
        hasher.update("source-metadata-unavailable");
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn descriptorProfileHash(
    profile: GeneratorProfile,
    matrix: *const campaigns.CampaignMatrix,
    selection: Selection,
) !Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (selection.indices[0..selection.count]) |index| {
        const function = matrix.definitions[index].function;
        const signature = try corpus_set.evaluatorSignature(&function);
        const digest = corpus_set.descriptorEntryHash(profile, &function, signature);
        hashU64(&hasher, index);
        hasher.update(&digest);
    }
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn hashU64(hasher: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}

fn appendDigestLine(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    name: []const u8,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
) !void {
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    try appendFormat("{s}={s}\n", allocator, output, .{ name, digest_hex[0..] });
}

fn appendFormat(
    comptime format: []const u8,
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    args: anytype,
) !void {
    var buffer: [1024]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, format, args);
    try output.appendSlice(allocator, rendered);
}

fn deleteIfPresent(io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    dir.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn writeAtomicSynced(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    bytes: []const u8,
) !void {
    var atomic = try dir.createFileAtomic(io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

const test_profile: GeneratorProfile = .{
    .target = "x86_64-linux-gnu.2.38",
    .cpu = "haswell",
    .mode = "ReleaseSafe",
};

// This test proves that the qualified-profile check precedes all filesystem work.
test "unapproved profile does not mutate output root" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const arguments = [_][]const u8{ "corpus-generate", "unapproved" };

    try std.testing.expectError(
        error.UnapprovedCorpusProfile,
        generateCorpus(.{
            .io = io,
            .allocator = std.testing.allocator,
            .root_dir = temporary.dir,
            .approved_corpus_pair = false,
            .profile = test_profile,
            .arguments = arguments[0..],
        }),
    );
    try testExpectPathMissing(io, temporary.dir, "unapproved");
}

// This test proves that an unknown operation is rejected before output setup.
test "invalid operation filter does not mutate output root" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const arguments = [_][]const u8{
        "corpus-generate",
        "invalid-filter",
        "--operation=not_a_manifest_operation",
    };

    try std.testing.expectError(
        error.InvalidOperationFilter,
        generateCorpus(.{
            .io = io,
            .allocator = std.testing.allocator,
            .root_dir = temporary.dir,
            .approved_corpus_pair = true,
            .profile = test_profile,
            .arguments = arguments[0..],
        }),
    );
    try testExpectPathMissing(io, temporary.dir, "invalid-filter");
}

// This test checks filtered path ownership and the selected-count metadata.
test "filtered plan owns probe paths and reports selected metadata" {
    const arguments = [_][]const u8{
        "corpus-generate",
        "output",
        "--operation=exp",
        "--format=h",
    };
    const options = try parseArguments(arguments[0..]);
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    const matrix = try campaigns.classifyManifest(&manifest);
    const selection = try selectDefinitions(&matrix, options.filters);
    try std.testing.expectEqual(GenerationScope.filtered, selection.scope);
    try std.testing.expectEqual(@as(usize, 1), selection.count);

    var paths = try OutputPaths.init(std.testing.allocator, options);
    defer paths.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "output/generated/probes/exp-h",
        paths.run_root,
    );
    try std.testing.expectEqualStrings(
        "output/generated/probes/exp-h/records",
        paths.records_root,
    );

    var metadata: std.ArrayList(u8) = .empty;
    defer metadata.deinit(std.testing.allocator);
    const descriptor_hash = [_]u8{0} ** std.crypto.hash.sha2.Sha256.digest_length;
    try appendMetadataHeader(
        std.testing.allocator,
        &metadata,
        test_profile,
        options,
        selection,
        descriptor_hash,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, metadata.items, "generation_scope=filtered\n") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, metadata.items, "function_count=1\n") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, metadata.items, "operation_filter=exp\n") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, metadata.items, "format_filter=h\n") != null,
    );
}

// This test proves filtered publication cannot remove the full-corpus marker.
test "filtered publication preserves full completion marker" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const arguments = [_][]const u8{
        "corpus-generate",
        "output",
        "--operation=exp",
        "--format=h",
    };
    const options = try parseArguments(arguments[0..]);
    var paths = try OutputPaths.init(allocator, options);
    defer paths.deinit(allocator);

    const full_marker = try std.fs.path.join(
        allocator,
        &.{ options.output_root, "generated", "COMPLETE" },
    );
    defer allocator.free(full_marker);
    try writeAtomicSynced(io, temporary.dir, full_marker, "full\n");

    const publication: Publication = .{
        .io = io,
        .root_dir = temporary.dir,
        .paths = &paths,
    };
    try publication.begin();
    const metadata = "filtered metadata\n";
    var metadata_digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(metadata, &metadata_digest, .{});
    try publication.finish(metadata, metadata_digest);

    try testExpectPathExists(io, temporary.dir, full_marker);
    try testExpectPathExists(io, temporary.dir, paths.complete_marker);
}

// This test simulates a failure after one durable artifact and before publication.
test "failed artifact write never publishes metadata or completion" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const arguments = [_][]const u8{ "corpus-generate", "partial" };
    const options = try parseArguments(arguments[0..]);
    var paths = try OutputPaths.init(allocator, options);
    defer paths.deinit(allocator);
    const publication: Publication = .{
        .io = io,
        .root_dir = temporary.dir,
        .paths = &paths,
    };

    try temporary.dir.createDirPath(io, paths.run_root);
    try writeAtomicSynced(io, temporary.dir, paths.complete_marker, "stale\n");
    try writeAtomicSynced(io, temporary.dir, paths.metadata_path, "stale metadata\n");
    try publication.begin();

    const first_path = try generatedArtifactPath(
        allocator,
        paths.records_root,
        0,
        "exp",
    );
    defer allocator.free(first_path);
    try writeAtomicSynced(io, temporary.dir, first_path, "first");

    const blocking_path = try std.fs.path.join(
        allocator,
        &.{ paths.records_root, "blocking" },
    );
    defer allocator.free(blocking_path);
    try writeAtomicSynced(io, temporary.dir, blocking_path, "not a directory");
    const failed_path = try std.fs.path.join(
        allocator,
        &.{ blocking_path, "001_log.zcdr" },
    );
    defer allocator.free(failed_path);
    if (writeAtomicSynced(io, temporary.dir, failed_path, "second")) |_| {
        return error.TestExpectedError;
    } else |_| {}

    try testExpectPathExists(io, temporary.dir, first_path);
    try testExpectPathExists(io, temporary.dir, paths.incomplete_marker);
    try testExpectPathMissing(io, temporary.dir, paths.metadata_path);
    try testExpectPathMissing(io, temporary.dir, paths.complete_marker);
}

test "published candidates enforce profile, numerical identity, and integrity" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const arguments = [_][]const u8{
        "corpus-generate", "output", "--operation=abs", "--format=f",
    };
    try generateCorpus(.{
        .io = io,
        .allocator = allocator,
        .root_dir = temporary.dir,
        .approved_corpus_pair = true,
        .profile = test_profile,
        .arguments = &arguments,
    });
    const run_root = "output/generated/probes/abs-f";
    var manifest = try corpus.parseManifest(corpus.manifest_text);
    for (manifest.function_values[0..manifest.function_count]) |*function| {
        function.status = .unsupported;
        function.oracle = .none;
    }
    var published = try corpus_set.load(allocator, io, temporary.dir, run_root, &manifest, test_profile);
    defer published.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), published.count);
    const index = published.entries[0].signature_index;
    manifest.function_values[index].status = .correct;
    manifest.function_values[index].oracle = .exact_bits;
    var accepted = try corpus_set.load(allocator, io, temporary.dir, run_root, &manifest, test_profile);
    defer accepted.deinit(allocator);
    try std.testing.expectEqual(published.entries[0].digest, accepted.entries[0].digest);
    manifest.function_values[index].oracle = .mpfr_arb;
    if (corpus_set.load(allocator, io, temporary.dir, run_root, &manifest, test_profile)) |value| {
        var unexpected = value;
        unexpected.deinit(allocator);
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.InvalidStatusSnapshot, err);
    }
    manifest.function_values[index].oracle = .exact_bits;
    var wrong_profile = test_profile;
    wrong_profile.cpu = "generic";
    try std.testing.expectError(
        error.ProfileMismatch,
        corpus_set.load(allocator, io, temporary.dir, run_root, &manifest, wrong_profile),
    );
    manifest.function_values[index].max_ulp += 1;
    try std.testing.expectError(
        error.DescriptorDigestMismatch,
        corpus_set.load(allocator, io, temporary.dir, run_root, &manifest, test_profile),
    );
    manifest.function_values[index].max_ulp -= 1;
    try writeAtomicSynced(io, temporary.dir, run_root ++ "/metadata.txt", "tampered\n");
    try std.testing.expectError(
        error.MetadataDigestMismatch,
        corpus_set.load(allocator, io, temporary.dir, run_root, &manifest, test_profile),
    );
    try writeAtomicSynced(io, temporary.dir, run_root ++ "/.incomplete", "pending\n");
    try std.testing.expectError(
        error.IncompletePublication,
        corpus_set.load(allocator, io, temporary.dir, run_root, &manifest, test_profile),
    );
}

fn testExpectPathExists(io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    try dir.access(io, path, .{});
}

fn testExpectPathMissing(io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    dir.access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.TestUnexpectedResult;
}
