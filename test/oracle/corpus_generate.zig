const std = @import("std");
const corpus = @import("corpus_support");
const campaigns = @import("corpus_campaigns");
const runner = @import("corpus_runner");

comptime {
    @setEvalBranchQuota(2_000_000);
}

const max_arguments = corpus.max_argument_count;
const max_results = 2;
const generated_root = "test/corpus/generated";
const records_root = generated_root ++ "/records";
const metadata_path = generated_root ++ "/metadata.txt";
const incomplete_marker = generated_root ++ "/.incomplete";
const complete_marker = generated_root ++ "/COMPLETE";

const RecordContext = struct {
    allocator: std.mem.Allocator,
    records: *std.ArrayList(u8),
    record_hasher: std.crypto.hash.sha2.Sha256,
    record_count: u64 = 0,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const root = std.Io.Dir.cwd();

    const manifest = try corpus.parseManifest(corpus.manifest_text);
    const matrix = campaigns.classifyManifest(&manifest) catch |err| switch (err) {
        error.ManifestCountMismatch => return error.ManifestCountMismatch,
    };
    if (matrix.count != campaigns.manifest_campaign_count) {
        return error.ManifestCountMismatch;
    }

    try root.createDirPath(io, generated_root);
    try root.createDirPath(io, records_root);
    root.deleteFile(io, complete_marker) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try writeFile(io, incomplete_marker, "oracle-generate started\n");

    var metadata: std.ArrayList(u8) = .empty;
    defer metadata.deinit(allocator);
    try appendFormat(allocator, &metadata, "ZCDM version=1\n", .{});
    try appendHashLine(allocator, &metadata, "manifest_sha256", corpus.manifest_text);
    try appendFormat(allocator, &metadata, "core_math_repository={s}\n", .{campaigns.core_math_repository});
    try appendFormat(allocator, &metadata, "core_math_revision={s}\n", .{campaigns.core_math_revision});
    try appendFormat(allocator, &metadata, "function_count={d}\n", .{matrix.count});
    try appendFormat(allocator, &metadata, "record_codec_version={d}\n\n", .{corpus.descriptor_corpus_codec_version});

    for (0..matrix.count) |index| {
        const definition = matrix.at(index) orelse return error.ManifestCountMismatch;
        try generateDefinition(io, allocator, &metadata, index, definition);
    }

    var metadata_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(metadata.items, &metadata_digest, .{});
    try writeFile(io, metadata_path, metadata.items);

    const metadata_hex = std.fmt.bytesToHex(metadata_digest, .lower);
    root.deleteFile(io, incomplete_marker) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var complete_text: [128]u8 = undefined;
    const complete = try std.fmt.bufPrint(
        &complete_text,
        "oracle-generate complete\nmetadata_sha256={s}\n",
        .{metadata_hex[0..]},
    );
    try writeFile(io, complete_marker, complete);
}

fn generateDefinition(
    io: std.Io,
    allocator: std.mem.Allocator,
    metadata: *std.ArrayList(u8),
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

    var record_count: u64 = 0;
    var artifact_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = [_]u8{0} **
        std.crypto.hash.sha2.Sha256.digest_length;
    var artifact_path_buffer: [256]u8 = undefined;
    const should_generate = campaignEvidenceAvailable(definition);
    const declared_evidence_available = should_generate;
    if (should_generate) {
        var records: std.ArrayList(u8) = .empty;
        defer records.deinit(allocator);
        var context = RecordContext{
            .allocator = allocator,
            .records = &records,
            .record_hasher = std.crypto.hash.sha2.Sha256.init(.{}),
        };
        campaigns.visitDefinitionRecords(definition, &context, visitRecord) catch |err| return err;
        if (context.record_count != cardinality) return error.RecordCountMismatch;
        context.record_hasher.final(&artifact_hash);
        const artifact_path = materializedArtifactPath(
            definition,
            index,
            function.op,
            &artifact_path_buffer,
        ) catch return error.ArtifactNameInvalid;
        try writeFile(io, artifact_path, records.items);
        record_count = context.record_count;
    }

    const artifact_path = if (should_generate)
        materializedArtifactPath(definition, index, function.op, &artifact_path_buffer) catch
            return error.ArtifactNameInvalid
    else
        campaign_artifact;
    const source_hash_hex = std.fmt.bytesToHex(source_hash, .lower);
    const artifact_hash_hex = std.fmt.bytesToHex(artifact_hash, .lower);
    try appendFormat(
        allocator,
        metadata,
        "signature={d};operation={s};manifest_status={s};oracle={s};campaign={s};planned_campaign={s};availability={s};coverage={s};evidence_state={s};campaign_seed={x};campaign_tuple_count={d};campaign_artifact={s};cardinality={d};records={d};claims_exhaustive_full_cartesian={};source_metadata_available={};evidence_available={};source_hash={s};artifact={s};artifact_sha256={s}",
        .{
            index,
            function.op,
            @tagName(function.status),
            @tagName(function.oracle),
            @tagName(campaign_class),
            @tagName(planned_class),
            @tagName(definition.availability()),
            @tagName(coverage),
            @tagName(evidence_state),
            campaign_seed,
            campaign_tuple_count,
            campaign_artifact,
            cardinality,
            record_count,
            definition.claimsExhaustiveFullCartesian(),
            source_available,
            declared_evidence_available,
            source_hash_hex[0..],
            artifact_path,
            if (should_generate) artifact_hash_hex[0..] else "none",
        },
    );
    try appendSourceFields(allocator, metadata, source);
    try appendFormat(allocator, metadata, "\n", .{});
}

fn visitRecord(context: *RecordContext, visit: *const campaigns.RecordVisit) !void {
    var input_bits: [max_arguments]u64 = [_]u64{0} ** max_arguments;
    var input_tags: [max_arguments][]const u8 = [_][]const u8{""} ** max_arguments;
    encodeInputs(
        visit.function,
        visit.arguments.slice(),
        &input_bits,
        &input_tags,
    ) catch return error.InputEncoding;

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
        try runner.verifyExpectedResults(
            visit.function,
            &evidence,
            visit.expected_results,
        );
    }

    var result_fields: [max_results]corpus.CorpusField = undefined;
    const result_count = runner.materializeResultFields(
        visit.function,
        &evidence,
        &result_fields,
    ) catch return error.ResultEncoding;
    var record = try campaigns.buildRecordFromFieldsWithUlp(
        visit.function,
        visit.arguments.slice(),
        result_fields[0..result_count],
        visit.max_ulp,
    );
    const encoded_length = try corpus.corpusRecordEncodedLength(&record);
    const encoded = try context.allocator.alloc(u8, encoded_length);
    defer context.allocator.free(encoded);
    _ = try corpus.encodeCorpusRecord(&record, encoded);
    try context.records.appendSlice(context.allocator, encoded);
    context.record_hasher.update(encoded);
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
        }
    }
}
fn evidenceState(definition: *const campaigns.CampaignDefinition) campaigns.EvidenceAvailability {
    return switch (definition.data) {
        .unavailable => .source_metadata_unavailable,
        .exhaustive_h_unary => |spec| spec.evidence,
        .bounded_h_integer_domain => |spec| spec.evidence,
        .explicit_special_tuple_grid => |spec| spec.evidence,
        .source_pinned_binary_ternary_hard_tuples => |spec| spec.evidence,
        .hard_corpus_f => |spec| spec.evidence,
        .hard_corpus_d => |spec| spec.evidence,
        .exact_bit_status => |spec| spec.evidence,
    };
}

fn campaignEvidenceAvailable(definition: *const campaigns.CampaignDefinition) bool {
    return switch (definition.data) {
        .unavailable => false,
        .exhaustive_h_unary => |spec| spec.evidence != .source_metadata_unavailable,
        .bounded_h_integer_domain => |spec| spec.evidence != .source_metadata_unavailable,
        .explicit_special_tuple_grid => |spec| spec.evidence != .source_metadata_unavailable,
        .source_pinned_binary_ternary_hard_tuples => |spec| spec.evidence != .source_metadata_unavailable,
        .hard_corpus_f, .hard_corpus_d => false,
        .exact_bit_status => |spec| spec.evidence != .source_metadata_unavailable,
    };
}

fn deterministicSeed(definition: *const campaigns.CampaignDefinition) u64 {
    return switch (definition.data) {
        .unavailable => |spec| spec.deterministic_seed,
        .exhaustive_h_unary => |spec| spec.deterministic_seed,
        .bounded_h_integer_domain => |spec| spec.deterministic_seed,
        .explicit_special_tuple_grid => |spec| spec.deterministic_seed,
        .source_pinned_binary_ternary_hard_tuples => |spec| spec.deterministic_seed,
        .hard_corpus_f => |spec| spec.deterministic_seed,
        .hard_corpus_d => |spec| spec.deterministic_seed,
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
        .source_pinned_binary_ternary_hard_tuples => |spec| spec.artifact,
        .hard_corpus_f => |spec| spec.artifact,
        .hard_corpus_d => |spec| spec.artifact,
        .exact_bit_status => |spec| spec.artifact,
    };
}

fn sourceFor(definition: *const campaigns.CampaignDefinition) ?campaigns.SourcePin {
    return switch (definition.data) {
        .unavailable => |spec| spec.source,
        .exhaustive_h_unary => |spec| spec.source,
        .bounded_h_integer_domain => |spec| spec.source,
        .explicit_special_tuple_grid => |spec| spec.source,
        .source_pinned_binary_ternary_hard_tuples => |spec| spec.source,
        .hard_corpus_f => |metadata| metadata.source,
        .hard_corpus_d => |metadata| metadata.source,
        .exact_bit_status => |spec| spec.source,
    };
}

fn materializedArtifactPath(
    definition: *const campaigns.CampaignDefinition,
    index: usize,
    operation: []const u8,
    buffer: *[256]u8,
) ![]const u8 {
    const configured = campaignArtifact(definition);
    if (std.mem.startsWith(u8, configured, "test/corpus/") and
        std.mem.indexOf(u8, configured, "..") == null)
    {
        return configured;
    }
    return generatedArtifactPath(index, operation, buffer);
}

fn generatedArtifactPath(index: usize, operation: []const u8, buffer: *[256]u8) ![]const u8 {
    if (operation.len == 0 or operation.len > 128) return error.ArtifactNameInvalid;
    for (operation) |byte| {
        if (!((byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or byte == '_'))
        {
            return error.ArtifactNameInvalid;
        }
    }
    return std.fmt.bufPrint(buffer, "{s}/{d}-{s}.zcdr", .{ records_root, index, operation });
}

fn appendSourceFields(
    allocator: std.mem.Allocator,
    metadata: *std.ArrayList(u8),
    source: ?campaigns.SourcePin,
) !void {
    if (source) |pin| {
        try appendFormat(
            allocator,
            metadata,
            ";source_repository={s};source_revision={s};source_path={s}",
            .{ pin.repository, pin.revision, pin.path },
        );
    } else {
        try appendFormat(allocator, metadata, ";source_repository=none;source_revision=none;source_path=none", .{});
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

fn appendHashLine(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    name: []const u8,
    bytes: []const u8,
) !void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    try appendFormat(allocator, output, "{s}={s}\n", .{
        name,
        digest_hex[0..],
    });
}

fn appendFormat(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    comptime format: []const u8,
    args: anytype,
) !void {
    var buffer: [1024]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, format, args);
    try output.appendSlice(allocator, rendered);
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}
