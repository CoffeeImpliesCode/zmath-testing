const std = @import("std");
const corpus = @import("corpus_support");
const campaigns = @import("corpus_campaigns");
const oracle_abi = @import("oracle_abi");

pub const record_buffer_capacity: usize = 8192;
pub const Digest = [32]u8;

pub const Profile = struct {
    target: []const u8,
    cpu: []const u8,
    mode: []const u8,
};

pub const Entry = struct {
    signature_index: usize,
    operation: []const u8,
    artifact: []const u8,
    records: u64,
    digest: Digest,
    evaluator: corpus.Oracle,
};

pub const Set = struct {
    source: []u8,
    entries: [corpus.max_function_count]Entry,
    count: usize,

    pub fn deinit(self: *Set, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        self.* = undefined;
    }
};

const metadata_bytes_max: usize = 1024 * 1024;
const completion_bytes_max: usize = 256;
const source_unavailable_text = "source-metadata-unavailable";
const oracle_signature = oracle_abi.zmath_testing_oracle_operation_signature;

const GenerationScope = enum {
    full,
    filtered,
};

pub const Filters = struct {
    operation: ?[]const u8,
    format: ?corpus.Format,
};

const MetadataRow = struct {
    signature_index: usize,
    operation: []const u8,
    manifest_status: corpus.FunctionStatus,
    oracle: corpus.Oracle,
    evaluator: corpus.Oracle,
    campaign: campaigns.CampaignClass,
    planned_campaign: campaigns.CampaignClass,
    availability: campaigns.Availability,
    coverage: campaigns.CoverageClaim,
    evidence_state: campaigns.EvidenceAvailability,
    campaign_seed: u64,
    campaign_tuple_count: u64,
    selection_rule: []const u8,
    cardinality: u64,
    records: u64,
    claims_exhaustive_full_cartesian: bool,
    source_metadata_available: bool,
    evidence_available: bool,
    source_hash: Digest,
    artifact: []const u8,
    artifact_sha256: Digest,
    source_repository: []const u8,
    source_revision: []const u8,
    source_path: []const u8,
};

comptime {
    if (std.crypto.hash.sha2.Sha256.digest_length != @sizeOf(Digest)) {
        @compileError("SHA-256 digest length drift");
    }
    if (campaigns.manifest_campaign_count != corpus.max_function_count) {
        @compileError("campaign and manifest descriptor counts differ");
    }
}

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    run_root: []const u8,
    manifest: *const corpus.Manifest,
    profile: Profile,
) !Set {
    if (run_root.len == 0) return error.InvalidRunRoot;
    if (profile.target.len == 0) return error.InvalidProfile;
    if (profile.cpu.len == 0) return error.InvalidProfile;
    if (profile.mode.len == 0) return error.InvalidProfile;

    const incomplete_path = try std.fs.path.join(
        allocator,
        &.{ run_root, ".incomplete" },
    );
    defer allocator.free(incomplete_path);
    try rejectIncompletePublication(io, dir, incomplete_path);

    const completion_path = try std.fs.path.join(
        allocator,
        &.{ run_root, "COMPLETE" },
    );
    defer allocator.free(completion_path);
    const completion = dir.readFileAlloc(
        io,
        completion_path,
        allocator,
        .limited(completion_bytes_max),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingCompletion,
        else => return err,
    };
    defer allocator.free(completion);
    const expected_metadata_digest = try parseCompletion(completion);

    const metadata_path = try std.fs.path.join(
        allocator,
        &.{ run_root, "metadata.txt" },
    );
    defer allocator.free(metadata_path);
    const source = dir.readFileAlloc(
        io,
        metadata_path,
        allocator,
        .limited(metadata_bytes_max),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingMetadata,
        else => return err,
    };
    errdefer allocator.free(source);

    var actual_metadata_digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &actual_metadata_digest, .{});
    if (!std.mem.eql(u8, &actual_metadata_digest, &expected_metadata_digest)) {
        return error.MetadataDigestMismatch;
    }

    var set: Set = .{
        .source = source,
        .entries = undefined,
        .count = 0,
    };
    try parseMetadata(&set, run_root, manifest, profile);

    // A concurrent publisher cannot turn a partial replacement into a valid snapshot.
    try rejectIncompletePublication(io, dir, incomplete_path);
    return set;
}

pub fn evaluatorSignature(function: *const corpus.Function) !*const oracle_signature {
    const signature_count: usize =
        @intCast(oracle_abi.zmath_testing_oracle_operation_table_count);
    if (signature_count != corpus.max_function_count) {
        return error.InvalidEvaluatorTable;
    }

    var match: ?*const oracle_signature = null;
    for (0..signature_count) |index| {
        const signature = &oracle_abi.zmath_testing_oracle_operation_table[index];
        if (!signatureMatchesFunction(signature, function)) continue;
        if (match != null) return error.AmbiguousEvaluatorSignature;
        match = signature;
    }
    return match orelse error.MissingEvaluatorSignature;
}

pub fn evaluatorCategory(signature: *const oracle_signature) !corpus.Oracle {
    const category: u32 = @intCast(signature.evaluator_category);
    return switch (category) {
        @as(u32, @intCast(oracle_abi.ZMATH_TESTING_ORACLE_EVALUATOR_EXACT_BITS)) => .exact_bits,
        @as(u32, @intCast(oracle_abi.ZMATH_TESTING_ORACLE_EVALUATOR_MPFR_ARB)) => .mpfr_arb,
        @as(u32, @intCast(oracle_abi.ZMATH_TESTING_ORACLE_EVALUATOR_ALGEBRAIC)) => .algebraic,
        // A definitional row is decided by the IEEE 754 definition rather than
        // by an arbitrary-precision evaluation, and the C side reports it under
        // a category of its own. It must map to its own value here: folding it
        // into exact_bits would let a metadata row claim a numerical
        // verification that never happened, and folding it into .none would
        // make the row unloadable. The category is read from the signature
        // itself, so a row whose C category disagrees with its manifest oracle
        // still fails the evaluator check in validateMetadataRow.
        @as(u32, @intCast(oracle_abi.ZMATH_TESTING_ORACLE_EVALUATOR_DEFINITIONAL)) => .definitional,
        else => error.UnknownEvaluatorCategory,
    };
}

pub fn descriptorEntryHash(
    profile: Profile,
    function: *const corpus.Function,
    signature: *const oracle_signature,
) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(profile.target);
    hasher.update(&[_]u8{0});
    hasher.update(profile.cpu);
    hasher.update(&[_]u8{0});
    hasher.update(profile.mode);
    hasher.update(&[_]u8{0});
    hasher.update(function.op);
    hasher.update(&[_]u8{0});
    for (function.provenance.slice()) |provenance| {
        hasher.update(&[_]u8{@backingInt(provenance)});
    }
    hashU32(&hasher, @intCast(function.arity));
    for (function.arguments()) |argument| {
        const descriptor = argument.oracleDescriptor();
        hasher.update(std.mem.asBytes(&descriptor));
    }
    for (0..function.result.oracleFieldCount()) |index| {
        const descriptor = function.result.oracleFieldDescriptor(index) orelse continue;
        hasher.update(std.mem.asBytes(&descriptor));
    }
    hasher.update(function.special_policy);
    hasher.update(&[_]u8{0});
    hashU64(&hasher, function.max_ulp);

    hasher.update(signatureOperation(signature));
    hashU32(&hasher, @intCast(signature.provenance));
    hashU32(&hasher, @intCast(signature.evaluator_category));
    hashU32(&hasher, @intCast(signature.arity));
    hashU32(&hasher, @intCast(signature.result_layout));
    hashU32(&hasher, @intCast(signature.structure_kind));
    hashU32(&hasher, @intCast(signature.result_field_count));
    for (0..@as(usize, @intCast(signature.arity))) |index| {
        const descriptor = signature.arguments[index];
        hasher.update(std.mem.asBytes(&descriptor));
    }
    for (0..@as(usize, @intCast(signature.result_field_count))) |index| {
        const descriptor = signature.result_fields[index];
        hasher.update(std.mem.asBytes(&descriptor));
    }

    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn parseMetadata(
    set: *Set,
    run_root: []const u8,
    manifest: *const corpus.Manifest,
    profile: Profile,
) !void {
    if (manifest.function_count != corpus.max_function_count) {
        return error.ManifestCountMismatch;
    }
    const source = set.source;
    if (source.len == 0) return error.InvalidMetadata;
    if (source[source.len - 1] != '\n') return error.InvalidMetadata;
    for (source) |byte| {
        if (byte == '\r') return error.InvalidMetadata;
        if (byte == 0) return error.InvalidMetadata;
    }

    var lines = std.mem.splitScalar(u8, source[0 .. source.len - 1], '\n');
    try expectLine(&lines, "ZCDM version=1");
    const descriptor_digest = try parseDigest(
        try takeLineValue(&lines, "manifest_descriptor_sha256"),
    );
    const repository = try takeLineValue(&lines, "core_math_repository");
    const revision = try takeLineValue(&lines, "core_math_revision");
    const profile_target = try takeLineValue(&lines, "profile_target");
    const profile_cpu = try takeLineValue(&lines, "profile_cpu");
    const profile_mode = try takeLineValue(&lines, "profile_mode");
    const scope = try parseEnum(
        GenerationScope,
        try takeLineValue(&lines, "generation_scope"),
    );
    const function_count = try parseCanonicalUnsigned(
        usize,
        10,
        try takeLineValue(&lines, "function_count"),
    );
    const selected_signature_count = try parseCanonicalUnsigned(
        usize,
        10,
        try takeLineValue(&lines, "selected_signature_count"),
    );
    const operation_filter_text = try takeLineValue(&lines, "operation_filter");
    const format_filter_text = try takeLineValue(&lines, "format_filter");
    const codec_version = try parseCanonicalUnsigned(
        u8,
        10,
        try takeLineValue(&lines, "record_codec_version"),
    );
    try expectLine(&lines, "");

    if (!std.mem.eql(u8, repository, campaigns.core_math_repository)) {
        return error.CoreMathIdentityMismatch;
    }
    if (!std.mem.eql(u8, revision, campaigns.core_math_revision)) {
        return error.CoreMathIdentityMismatch;
    }
    if (!std.mem.eql(u8, profile_target, profile.target)) {
        return error.ProfileMismatch;
    }
    if (!std.mem.eql(u8, profile_cpu, profile.cpu)) {
        return error.ProfileMismatch;
    }
    if (!std.mem.eql(u8, profile_mode, profile.mode)) {
        return error.ProfileMismatch;
    }
    if (codec_version != corpus.descriptor_corpus_codec_version) {
        return error.RecordCodecMismatch;
    }

    const filters: Filters = .{
        .operation = if (std.mem.eql(u8, operation_filter_text, "all"))
            null
        else
            operation_filter_text,
        .format = if (std.mem.eql(u8, format_filter_text, "all"))
            null
        else
            std.meta.stringToEnum(corpus.Format, format_filter_text) orelse
                return error.InvalidMetadata,
    };
    const filtered = filters.operation != null or filters.format != null;
    switch (scope) {
        .full => if (filtered) return error.InvalidMetadata,
        .filtered => if (!filtered) return error.InvalidMetadata,
    }

    const expected_count = selectedFunctionCount(manifest, filters);
    if (expected_count == 0) return error.EmptySelection;
    if (function_count != expected_count) return error.IncompleteSelection;
    if (selected_signature_count != expected_count) {
        return error.IncompleteSelection;
    }

    var descriptor_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const expected_source_hash = sourceUnavailableDigest();
    var search_index: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) return error.InvalidMetadata;
        if (set.count == corpus.max_function_count) {
            return error.TooManyMetadataRows;
        }
        const expected_index = nextSelectedFunctionIndex(
            manifest,
            filters,
            search_index,
        ) orelse return error.UnexpectedMetadataRow;
        const row = try parseMetadataRow(line);
        if (row.signature_index != expected_index) {
            return error.UnorderedMetadataRow;
        }

        const function = &manifest.function_values[expected_index];
        if (campaigns.matchingRuleCount(function.*) != 1) {
            return error.InvalidCampaignDefinition;
        }
        const definition = campaigns.classify(function.*);
        const signature = try evaluatorSignature(function);
        const evaluator = try validateMetadataRow(
            row,
            run_root,
            function,
            &definition,
            signature,
            expected_source_hash,
        );

        const entry_digest = descriptorEntryHash(profile, function, signature);
        hashU64(&descriptor_hasher, @intCast(expected_index));
        descriptor_hasher.update(&entry_digest);
        set.entries[set.count] = .{
            .signature_index = expected_index,
            .operation = row.operation,
            .artifact = row.artifact,
            .records = row.records,
            .digest = row.artifact_sha256,
            .evaluator = evaluator,
        };
        set.count += 1;
        search_index = expected_index + 1;
    }

    if (set.count != expected_count) return error.IncompleteSelection;
    if (nextSelectedFunctionIndex(manifest, filters, search_index) != null) {
        return error.IncompleteSelection;
    }

    var actual_descriptor_digest: Digest = undefined;
    descriptor_hasher.final(&actual_descriptor_digest);
    if (!std.mem.eql(u8, &actual_descriptor_digest, &descriptor_digest)) {
        return error.DescriptorDigestMismatch;
    }
}

fn validateMetadataRow(
    row: MetadataRow,
    run_root: []const u8,
    function: *const corpus.Function,
    definition: *const campaigns.CampaignDefinition,
    signature: *const oracle_signature,
    expected_source_hash: Digest,
) !corpus.Oracle {
    if (!std.mem.eql(u8, row.operation, function.op)) {
        return error.OperationMismatch;
    }
    if (!signatureMatchesFunction(signature, function)) {
        return error.SignatureMismatch;
    }

    const evaluator = try evaluatorCategory(signature);
    if (row.evaluator != evaluator) return error.EvaluatorMismatch;
    try validateStatusSnapshot(row.manifest_status, row.oracle, evaluator);
    try validateStatusSnapshot(function.status, function.oracle, evaluator);

    if (definition.campaignClass() == .unavailable) {
        return error.InvalidCampaignDefinition;
    }
    if (row.campaign != definition.campaignClass()) {
        return error.CampaignMismatch;
    }
    if (row.planned_campaign != definition.plannedCampaignClass()) {
        return error.CampaignMismatch;
    }
    if (row.availability != .records_ready) {
        return error.CampaignAvailabilityMismatch;
    }
    if (row.coverage != definition.coverageClaim()) {
        return error.CampaignCoverageMismatch;
    }
    if (row.evidence_state != campaignEvidenceState(definition)) {
        return error.CampaignEvidenceMismatch;
    }
    if (row.campaign_seed != campaignDeterministicSeed(definition)) {
        return error.CampaignSeedMismatch;
    }
    if (!std.mem.eql(u8, row.selection_rule, campaignSelectionRule(definition))) {
        return error.CampaignSelectionRuleMismatch;
    }

    const cardinality = definition.cardinality() catch {
        return error.InvalidCampaignDefinition;
    };
    if (cardinality == 0) return error.InvalidCampaignDefinition;
    if (row.campaign_tuple_count != cardinality) {
        return error.CampaignCardinalityMismatch;
    }
    if (row.cardinality != cardinality) {
        return error.CampaignCardinalityMismatch;
    }
    if (row.records == 0) return error.CampaignCardinalityMismatch;
    if (row.records != cardinality) return error.CampaignCardinalityMismatch;
    if (row.claims_exhaustive_full_cartesian !=
        definition.claimsExhaustiveFullCartesian())
    {
        return error.CampaignCoverageMismatch;
    }

    if (definition.sourceMetadataAvailable()) {
        return error.SourceMetadataMismatch;
    }
    if (campaignSource(definition) != null) {
        return error.SourceMetadataMismatch;
    }
    if (row.source_metadata_available) return error.SourceMetadataMismatch;
    if (!row.evidence_available) return error.CampaignEvidenceMismatch;
    if (!std.mem.eql(u8, &row.source_hash, &expected_source_hash)) {
        return error.SourceMetadataMismatch;
    }
    if (!std.mem.eql(u8, row.source_repository, "none")) {
        return error.SourceMetadataMismatch;
    }
    if (!std.mem.eql(u8, row.source_revision, "none")) {
        return error.SourceMetadataMismatch;
    }
    if (!std.mem.eql(u8, row.source_path, "none")) {
        return error.SourceMetadataMismatch;
    }
    if (!artifactPathMatches(row.artifact, run_root, row.signature_index, row.operation)) {
        return error.ArtifactPathMismatch;
    }
    return evaluator;
}

fn parseMetadataRow(line: []const u8) !MetadataRow {
    var fields = std.mem.splitScalar(u8, line, ';');
    const row: MetadataRow = .{
        .signature_index = try parseCanonicalUnsigned(
            usize,
            10,
            try takeFieldValue(&fields, "signature"),
        ),
        .operation = try takeFieldValue(&fields, "operation"),
        .manifest_status = try parseEnum(
            corpus.FunctionStatus,
            try takeFieldValue(&fields, "manifest_status"),
        ),
        .oracle = try parseEnum(
            corpus.Oracle,
            try takeFieldValue(&fields, "oracle"),
        ),
        .evaluator = try parseEnum(
            corpus.Oracle,
            try takeFieldValue(&fields, "evaluator"),
        ),
        .campaign = try parseEnum(
            campaigns.CampaignClass,
            try takeFieldValue(&fields, "campaign"),
        ),
        .planned_campaign = try parseEnum(
            campaigns.CampaignClass,
            try takeFieldValue(&fields, "planned_campaign"),
        ),
        .availability = try parseEnum(
            campaigns.Availability,
            try takeFieldValue(&fields, "availability"),
        ),
        .coverage = try parseEnum(
            campaigns.CoverageClaim,
            try takeFieldValue(&fields, "coverage"),
        ),
        .evidence_state = try parseEnum(
            campaigns.EvidenceAvailability,
            try takeFieldValue(&fields, "evidence_state"),
        ),
        .campaign_seed = try parseCanonicalUnsigned(
            u64,
            16,
            try takeFieldValue(&fields, "campaign_seed"),
        ),
        .campaign_tuple_count = try parseCanonicalUnsigned(
            u64,
            10,
            try takeFieldValue(&fields, "campaign_tuple_count"),
        ),
        .selection_rule = try takeFieldValue(&fields, "selection_rule"),
        .cardinality = try parseCanonicalUnsigned(
            u64,
            10,
            try takeFieldValue(&fields, "cardinality"),
        ),
        .records = try parseCanonicalUnsigned(
            u64,
            10,
            try takeFieldValue(&fields, "records"),
        ),
        .claims_exhaustive_full_cartesian = try parseBoolean(
            try takeFieldValue(&fields, "claims_exhaustive_full_cartesian"),
        ),
        .source_metadata_available = try parseBoolean(
            try takeFieldValue(&fields, "source_metadata_available"),
        ),
        .evidence_available = try parseBoolean(
            try takeFieldValue(&fields, "evidence_available"),
        ),
        .source_hash = try parseDigest(
            try takeFieldValue(&fields, "source_hash"),
        ),
        .artifact = try takeFieldValue(&fields, "artifact"),
        .artifact_sha256 = try parseDigest(
            try takeFieldValue(&fields, "artifact_sha256"),
        ),
        .source_repository = try takeFieldValue(&fields, "source_repository"),
        .source_revision = try takeFieldValue(&fields, "source_revision"),
        .source_path = try takeFieldValue(&fields, "source_path"),
    };
    if (fields.next() != null) return error.InvalidMetadata;
    return row;
}

fn rejectIncompletePublication(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) !void {
    dir.access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.IncompletePublication;
}

fn parseCompletion(source: []const u8) !Digest {
    const prefix = "oracle-generate complete\nmetadata_sha256=";
    const digest_offset = prefix.len;
    const newline_offset = digest_offset + @sizeOf(Digest) * 2;
    if (source.len != newline_offset + 1) return error.InvalidCompletion;
    if (!std.mem.startsWith(u8, source, prefix)) return error.InvalidCompletion;
    // Both offsets are compile-time constants, so the trailing newline and the
    // digest hex sit at fixed positions and no length is decremented here.
    if (source[newline_offset] != '\n') return error.InvalidCompletion;
    return parseDigest(source[digest_offset..newline_offset]) catch {
        return error.InvalidCompletion;
    };
}

fn expectLine(lines: anytype, expected: []const u8) !void {
    const line = lines.next() orelse return error.InvalidMetadata;
    if (!std.mem.eql(u8, line, expected)) return error.InvalidMetadata;
}

fn takeLineValue(lines: anytype, name: []const u8) ![]const u8 {
    const line = lines.next() orelse return error.InvalidMetadata;
    return namedValue(line, name);
}

fn takeFieldValue(fields: anytype, name: []const u8) ![]const u8 {
    const field = fields.next() orelse return error.InvalidMetadata;
    return namedValue(field, name);
}

fn namedValue(field: []const u8, name: []const u8) ![]const u8 {
    if (field.len <= name.len + 1) return error.InvalidMetadata;
    if (!std.mem.eql(u8, field[0..name.len], name)) {
        return error.InvalidMetadata;
    }
    if (field[name.len] != '=') return error.InvalidMetadata;
    return field[name.len + 1 ..];
}

fn parseEnum(comptime T: type, text: []const u8) !T {
    return std.meta.stringToEnum(T, text) orelse error.InvalidMetadata;
}

fn parseBoolean(text: []const u8) !bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return error.InvalidMetadata;
}

fn parseCanonicalUnsigned(
    comptime T: type,
    comptime base: u8,
    text: []const u8,
) !T {
    if (text.len == 0) return error.InvalidMetadata;
    if (text.len > 1 and text[0] == '0') return error.InvalidMetadata;
    for (text) |byte| {
        const valid = switch (base) {
            10 => byte >= '0' and byte <= '9',
            16 => (byte >= '0' and byte <= '9') or
                (byte >= 'a' and byte <= 'f'),
            else => @compileError("unsupported integer base"),
        };
        if (!valid) return error.InvalidMetadata;
    }
    return std.fmt.parseInt(T, text, base) catch error.InvalidMetadata;
}

fn parseDigest(text: []const u8) !Digest {
    if (text.len != @sizeOf(Digest) * 2) return error.InvalidMetadata;
    var digest: Digest = undefined;
    for (0..@sizeOf(Digest)) |index| {
        const high = try parseHexNibble(text[index * 2]);
        const low = try parseHexNibble(text[index * 2 + 1]);
        digest[index] = (high << 4) | low;
    }
    return digest;
}

fn parseHexNibble(byte: u8) !u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        else => error.InvalidMetadata,
    };
}

fn selectedFunctionCount(manifest: *const corpus.Manifest, filters: Filters) usize {
    var count: usize = 0;
    for (manifest.function_values[0..manifest.function_count]) |*function| {
        if (functionSelected(function, filters)) count += 1;
    }
    return count;
}

fn nextSelectedFunctionIndex(
    manifest: *const corpus.Manifest,
    filters: Filters,
    start: usize,
) ?usize {
    if (start > manifest.function_count) return null;
    for (manifest.function_values[start..manifest.function_count], start..) |
        *function,
        index,
    | {
        if (functionSelected(function, filters)) return index;
    }
    return null;
}

fn functionSelected(function: *const corpus.Function, filters: Filters) bool {
    if (filters.operation) |operation| {
        if (!std.mem.eql(u8, function.op, operation)) return false;
    }
    if (filters.format) |format| {
        if (campaignFormat(function) != format) return false;
    }
    return true;
}

fn campaignFormat(function: *const corpus.Function) corpus.Format {
    if (function.result.floatFormat()) |format| return format;
    for (function.arguments()) |argument| {
        if (argument.floatFormat()) |format| return format;
    }
    return .h;
}

fn validateStatusSnapshot(
    status: corpus.FunctionStatus,
    oracle: corpus.Oracle,
    evaluator: corpus.Oracle,
) !void {
    switch (status) {
        .unsupported => if (oracle != .none) return error.InvalidStatusSnapshot,
        .correct, .bounded => if (oracle != evaluator) {
            return error.InvalidStatusSnapshot;
        },
    }
}

fn campaignEvidenceState(
    definition: *const campaigns.CampaignDefinition,
) campaigns.EvidenceAvailability {
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

fn campaignDeterministicSeed(definition: *const campaigns.CampaignDefinition) u64 {
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

fn campaignSelectionRule(
    definition: *const campaigns.CampaignDefinition,
) []const u8 {
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

fn campaignSource(
    definition: *const campaigns.CampaignDefinition,
) ?campaigns.SourcePin {
    return switch (definition.data) {
        .unavailable => |spec| spec.source,
        .exhaustive_h_unary => |spec| spec.source,
        .bounded_h_integer_domain => |spec| spec.source,
        .explicit_special_tuple_grid => |spec| spec.source,
        .selected_cartesian => |spec| spec.source,
        .selected_unary_f => |spec| spec.source,
        .selected_unary_d => |spec| spec.source,
        .exact_bit_status => |spec| spec.source,
    };
}

fn artifactPathMatches(
    artifact: []const u8,
    run_root: []const u8,
    signature_index: usize,
    operation: []const u8,
) bool {
    var index_buffer: [3]u8 = undefined;
    const index_text = std.fmt.bufPrint(
        &index_buffer,
        "{d:0>3}",
        .{signature_index},
    ) catch return false;

    var remaining = artifact;
    if (!consumePrefix(&remaining, run_root)) return false;
    if (!consumePrefix(&remaining, "/records/")) return false;
    if (!consumePrefix(&remaining, index_text)) return false;
    if (!consumePrefix(&remaining, "_")) return false;
    if (!consumePrefix(&remaining, operation)) return false;
    if (!consumePrefix(&remaining, ".zcdr")) return false;
    return remaining.len == 0;
}

fn consumePrefix(remaining: *[]const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, remaining.*, prefix)) return false;
    remaining.* = remaining.*[prefix.len..];
    return true;
}

fn sourceUnavailableDigest() Digest {
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(source_unavailable_text, &digest, .{});
    return digest;
}

fn signatureMatchesFunction(
    signature: *const oracle_signature,
    function: *const corpus.Function,
) bool {
    if (signature.operation == null) return false;
    if (signature.arguments == null) return false;
    if (signature.result_fields == null) return false;
    if (!signatureProvenanceKnown(signature.provenance)) return false;
    _ = evaluatorCategory(signature) catch return false;

    const operation_length: usize = @intCast(signature.operation_length);
    const arity: usize = @intCast(signature.arity);
    const result_count: usize = @intCast(signature.result_field_count);
    if (operation_length != function.op.len) return false;
    if (arity > corpus.max_argument_count) return false;
    if (result_count > corpus.max_result_field_count) return false;
    if (!std.mem.eql(u8, function.op, signatureOperation(signature))) {
        return false;
    }
    if (arity != function.arguments().len) return false;
    if (result_count != function.result.oracleFieldCount()) return false;
    if (@as(u32, @intCast(signature.result_layout)) !=
        @backingInt(function.result.oracleLayout()))
    {
        return false;
    }
    if (@as(u32, @intCast(signature.structure_kind)) !=
        @backingInt(function.result.oracleStructureKind()))
    {
        return false;
    }
    for (function.arguments(), 0..) |argument, index| {
        if (!cDescriptorMatches(signature.arguments[index], argument.oracleDescriptor())) {
            return false;
        }
    }
    for (0..function.result.oracleFieldCount()) |index| {
        const descriptor = function.result.oracleFieldDescriptor(index) orelse return false;
        if (!cDescriptorMatches(signature.result_fields[index], descriptor)) return false;
    }
    return true;
}

fn signatureProvenanceKnown(provenance_value: anytype) bool {
    const provenance: u32 = @intCast(provenance_value);
    return provenance ==
        @as(u32, @intCast(oracle_abi.ZMATH_TESTING_ORACLE_PROVENANCE_C23_7_12)) or
        provenance ==
            @as(u32, @intCast(oracle_abi.ZMATH_TESTING_ORACLE_PROVENANCE_C23_IEEE)) or
        provenance ==
            @as(u32, @intCast(oracle_abi.ZMATH_TESTING_ORACLE_PROVENANCE_ANNEX_F)) or
        provenance ==
            @as(u32, @intCast(oracle_abi.ZMATH_TESTING_ORACLE_PROVENANCE_ANNEX_H));
}

fn signatureOperation(signature: *const oracle_signature) []const u8 {
    const pointer: [*]const u8 = @ptrCast(signature.operation);
    return pointer[0..@intCast(signature.operation_length)];
}

fn cDescriptorMatches(
    actual: oracle_abi.zmath_testing_oracle_field_descriptor,
    expected: corpus.OracleFieldDescriptor,
) bool {
    return actual.kind == @backingInt(expected.kind) and
        actual.value_bits == expected.value_bits and
        actual.format.code == @backingInt(expected.format.code) and
        actual.format.storage_bits == expected.format.storage_bits and
        actual.format.exponent_bits == expected.format.exponent_bits and
        actual.format.fraction_bits == expected.format.fraction_bits and
        actual.format.reserved == expected.format.reserved and
        actual.reserved == expected.reserved;
}

fn hashU32(hasher: *std.crypto.hash.sha2.Sha256, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hasher.update(&bytes);
}

fn hashU64(hasher: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}

// ---------------------------------------------------------------------------
// Binary32 raw-input range publications
//
// A range publication is a different claim from an ordinary publication, so it
// is a different file set, a different receipt, and a different loader. It
// never writes `COMPLETE`, it never claims ordinary coverage, and it is never
// read by `load`. The one thing it shares with an ordinary publication is the
// record codec, and a record carries no signature index, so a range artifact
// is identified by the metadata row that names it and nothing else.
// ---------------------------------------------------------------------------

/// Every raw binary32 bit pattern, which is the whole domain a range interval
/// is measured against. Bounds are `u64` so a half-open interval can name the
/// exclusive end `2^32` without wrapping.
pub const max_raw_binary32_inputs: u64 = 1 << 32;

pub const range_source_unavailable_text = "zmath-corpus-f32-raw-range";
pub const range_plan_domain = "zmath-corpus-range-plan";
pub const range_plan_version: u64 = 1;
pub const range_metadata_first_line = "ZCRANGE version=1";
pub const range_receipt_first_line = "zmath-corpus-range version=1";
pub const range_shard_receipt_first_line = "zmath-corpus-range-shard version=1";
pub const range_input_width_bits: u64 = 32;
pub const range_row_bytes_max: usize = 2048;
const range_receipt_bytes_max: usize = 2048;
const range_metadata_bytes_max: usize = 1024 * 1024;

/// A half-open interval of raw binary32 bit patterns, `[low, high)`.
pub const RawRange = struct {
    low: u64,
    high: u64,

    pub fn length(self: RawRange) u64 {
        return self.high - self.low;
    }

    pub fn coversFullBinary32(self: RawRange) bool {
        return self.low == 0 and self.high == max_raw_binary32_inputs;
    }

    pub fn eql(left: RawRange, right: RawRange) bool {
        return left.low == right.low and left.high == right.high;
    }
};

pub const RangeCoverage = enum {
    /// The declared interval is proved, and it is not the whole domain.
    partial,
    /// The declared interval is `[0, 2^32)` and every raw input in it is
    /// proved exactly once.
    exhaustive_binary32,
};

pub const RangeCoverageError = error{
    InvalidRawRange,
    RangeShardTooFine,
    RangeShardIndexOutOfRange,
};

/// Coverage is recomputed, never declared. A tiling that is not proved, or an
/// interval that is not the whole domain, is `partial` no matter what the
/// producer believed.
pub fn rangeCoverage(declared: RawRange, complete_tiling: bool) RangeCoverage {
    if (complete_tiling and declared.coversFullBinary32()) return .exhaustive_binary32;
    return .partial;
}

/// Strict `LOW:HIGH`. Both bounds are canonical decimals, `low` is below
/// `high`, and `high` is at most `2^32`. A padded, signed, empty, or oversized
/// bound is a mistake in a launch script and must not become a range.
pub fn parseRawRangeSpec(text: []const u8) !RawRange {
    const separator = std.mem.indexOfScalar(u8, text, ':') orelse
        return error.InvalidRangeSpec;
    if (std.mem.indexOfScalar(u8, text[separator + 1 ..], ':') != null) {
        return error.InvalidRangeSpec;
    }
    const low = parseRawIndexText(text[0..separator]) orelse return error.InvalidRangeSpec;
    const high = parseRawIndexText(text[separator + 1 ..]) orelse return error.InvalidRangeSpec;
    if (low >= high) return error.InvalidRangeSpec;
    if (high > max_raw_binary32_inputs) return error.InvalidRangeSpec;
    return .{ .low = low, .high = high };
}

fn parseRawIndexText(text: []const u8) ?u64 {
    if (text.len == 0 or text.len > 20) return null;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return null;
    }
    if (text.len > 1 and text[0] == '0') return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// Eligibility is one input `float:f` and arity one. The result format is
/// irrelevant: a `float:f` input that rounds to a half or a double is in the
/// range domain, and a `float:f` input behind a tag or an integer is not.
pub fn rangeEligible(function: *const corpus.Function) bool {
    const arguments = function.arguments();
    if (arguments.len != 1) return false;
    return switch (arguments[0]) {
        .float => |format| format == .f,
        else => false,
    };
}

pub const RangeSelection = struct {
    indices: [corpus.max_function_count]usize = undefined,
    count: usize = 0,
};

/// The filters keep their ordinary result-format meaning, and the range
/// eligibility rule is applied after them. A range run therefore selects the
/// eligible subset of the filtered selection, never the whole manifest.
pub fn rangeSelection(manifest: *const corpus.Manifest, filters: Filters) RangeSelection {
    var selection: RangeSelection = .{};
    for (manifest.function_values[0..manifest.function_count], 0..) |*function, index| {
        if (!functionSelected(function, filters)) continue;
        if (!rangeEligible(function)) continue;
        selection.indices[selection.count] = index;
        selection.count += 1;
    }
    return selection;
}

/// The selection digest a range receipt binds. It is the same construction as
/// the ordinary `manifest_descriptor_sha256` restricted to the eligible
/// selection, so a producer and a reader derive the same value from the same
/// manifest, profile, and filters.
pub fn rangeDescriptorDigest(
    profile: Profile,
    manifest: *const corpus.Manifest,
    filters: Filters,
) !Digest {
    const selection = rangeSelection(manifest, filters);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (selection.indices[0..selection.count]) |index| {
        const function = &manifest.function_values[index];
        const signature = try evaluatorSignature(function);
        hashU64(&hasher, @intCast(index));
        hasher.update(&descriptorEntryHash(profile, function, signature));
    }
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

/// A range plan binds the profile, the filters, the selection digest, the
/// declared interval, the shard count and index, and the exact subrange this
/// worker owns. A manifest edit, a profile change, a different filter, a
/// different shard count, a different shard, or a different interval each
/// change it, so a shard produced for another plan cannot be assembled here.
pub const RangePlan = struct {
    profile: Profile,
    filters: Filters,
    descriptor_digest: Digest,
    declared: RawRange,
    shard_count: u64,
    shard_index: u64,
    subrange: RawRange,
};

pub fn rangePlanDigest(plan: RangePlan) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(range_plan_domain);
    hasher.update(&[_]u8{0});
    hashU64(&hasher, range_plan_version);
    hasher.update(plan.profile.target);
    hasher.update(&[_]u8{0});
    hasher.update(plan.profile.cpu);
    hasher.update(&[_]u8{0});
    hasher.update(plan.profile.mode);
    hasher.update(&[_]u8{0});
    hasher.update(plan.filters.operation orelse "all");
    hasher.update(&[_]u8{0});
    hasher.update(if (plan.filters.format) |format| @tagName(format) else "all");
    hasher.update(&[_]u8{0});
    hasher.update(&plan.descriptor_digest);
    hashU64(&hasher, plan.declared.low);
    hashU64(&hasher, plan.declared.high);
    hashU64(&hasher, plan.shard_count);
    hashU64(&hasher, plan.shard_index);
    hashU64(&hasher, plan.subrange.low);
    hashU64(&hasher, plan.subrange.high);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

/// The `i`-th of `n` contiguous pieces of `[declared.low, declared.high)`.
/// The split is a pure function of the interval and the shard count, so a
/// worker and an assembler compute the same piece without exchanging
/// anything, and an assembling run proves the tiling by recomputing it. More
/// shards than raw inputs is refused rather than answered with an empty piece.
pub fn splitRawRange(
    declared: RawRange,
    shard_count: u64,
    shard_index: u64,
) RangeCoverageError!RawRange {
    if (declared.low >= declared.high or declared.high > max_raw_binary32_inputs) {
        return error.InvalidRawRange;
    }
    if (shard_count == 0 or shard_count > declared.length()) return error.RangeShardTooFine;
    if (shard_index >= shard_count) return error.RangeShardIndexOutOfRange;
    const base = declared.length() / shard_count;
    const remainder = declared.length() % shard_count;
    const low = declared.low + shard_index * base + @min(shard_index, remainder);
    const size = base + @intFromBool(shard_index < remainder);
    return .{ .low = low, .high = low + size };
}

pub const RangeShardReceipt = struct {
    declared: RawRange,
    interval: RawRange,
    shard_index: u64,
    shard_count: u64,
    descriptor_count: usize,
    record_count: u64,
    rows_digest: Digest,
    descriptor_digest: Digest,
    plan_digest: Digest,
};

pub const RangeReceiptKind = enum {
    /// One worker produced the whole declared interval.
    worker,
    /// An assembling run proved the shards tile the declared interval.
    assembled,
};

pub const RangeReceipt = struct {
    kind: RangeReceiptKind,
    declared: RawRange,
    coverage: RangeCoverage,
    descriptor_count: usize,
    record_count: u64,
    shard_count: u64,
    descriptor_digest: Digest,
    plan_digest: Digest,
    metadata_digest: Digest,
};

fn appendRangeLine(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    comptime format: []const u8,
    args: anytype,
) !void {
    var buffer: [256]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, format, args);
    try output.appendSlice(allocator, rendered);
}

fn appendRangeDigestLine(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    name: []const u8,
    digest: Digest,
) !void {
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    try appendRangeLine(allocator, output, "{s}={s}\n", .{ name, digest_hex[0..] });
}

pub fn appendRangeShardReceipt(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    receipt: RangeShardReceipt,
) !void {
    try appendRangeLine(allocator, output, "{s}\n", .{range_shard_receipt_first_line});
    try appendRangeLine(
        allocator,
        output,
        "range_low={d}\nrange_high={d}\n",
        .{ receipt.interval.low, receipt.interval.high },
    );
    try appendRangeLine(
        allocator,
        output,
        "range_interval_low={d}\nrange_interval_high={d}\n",
        .{ receipt.declared.low, receipt.declared.high },
    );
    try appendRangeLine(
        allocator,
        output,
        "shard_index={d}\nshard_count={d}\n",
        .{ receipt.shard_index, receipt.shard_count },
    );
    try appendRangeLine(
        allocator,
        output,
        "range_descriptor_count={d}\nrange_record_count={d}\n",
        .{ receipt.descriptor_count, receipt.record_count },
    );
    try appendRangeDigestLine(allocator, output, "range_rows_sha256", receipt.rows_digest);
    try appendRangeDigestLine(
        allocator,
        output,
        "manifest_descriptor_sha256",
        receipt.descriptor_digest,
    );
    try appendRangeDigestLine(allocator, output, "range_plan_sha256", receipt.plan_digest);
}

pub fn parseRangeShardReceipt(source: []const u8) !RangeShardReceipt {
    if (source.len == 0 or source[source.len - 1] != '\n') return error.InvalidRangeReceipt;
    var lines = std.mem.splitScalar(u8, source[0 .. source.len - 1], '\n');
    const first = lines.next() orelse return error.InvalidRangeReceipt;
    if (!std.mem.eql(u8, first, range_shard_receipt_first_line)) {
        return error.InvalidRangeReceipt;
    }
    const receipt: RangeShardReceipt = .{
        .interval = .{
            .low = try takeRangeCount(&lines, "range_low"),
            .high = try takeRangeCount(&lines, "range_high"),
        },
        .declared = .{
            .low = try takeRangeCount(&lines, "range_interval_low"),
            .high = try takeRangeCount(&lines, "range_interval_high"),
        },
        .shard_index = try takeRangeCount(&lines, "shard_index"),
        .shard_count = try takeRangeCount(&lines, "shard_count"),
        .descriptor_count = std.math.cast(usize, try takeRangeCount(
            &lines,
            "range_descriptor_count",
        )) orelse return error.InvalidRangeReceipt,
        .record_count = try takeRangeCount(&lines, "range_record_count"),
        .rows_digest = try takeRangeDigest(&lines, "range_rows_sha256"),
        .descriptor_digest = try takeRangeDigest(&lines, "manifest_descriptor_sha256"),
        .plan_digest = try takeRangeDigest(&lines, "range_plan_sha256"),
    };
    if (lines.next() != null) return error.InvalidRangeReceipt;
    if (receipt.interval.low >= receipt.interval.high) return error.InvalidRangeReceipt;
    if (receipt.interval.high > max_raw_binary32_inputs) return error.InvalidRangeReceipt;
    if (receipt.declared.low >= receipt.declared.high) return error.InvalidRangeReceipt;
    if (receipt.shard_count == 0) return error.InvalidRangeReceipt;
    if (receipt.shard_index >= receipt.shard_count) return error.InvalidRangeReceipt;
    if (receipt.interval.low < receipt.declared.low or
        receipt.interval.high > receipt.declared.high)
    {
        return error.InvalidRangeReceipt;
    }
    return receipt;
}

pub fn appendRangeReceipt(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    receipt: RangeReceipt,
) !void {
    try appendRangeLine(allocator, output, "{s}\n", .{range_receipt_first_line});
    try appendRangeLine(
        allocator,
        output,
        "range_kind={s}\n",
        .{@tagName(receipt.kind)},
    );
    try appendRangeLine(
        allocator,
        output,
        "range_low={d}\nrange_high={d}\n",
        .{ receipt.declared.low, receipt.declared.high },
    );
    try appendRangeLine(
        allocator,
        output,
        "range_coverage={s}\nrange_shard_count={d}\n",
        .{ @tagName(receipt.coverage), receipt.shard_count },
    );
    try appendRangeLine(
        allocator,
        output,
        "range_descriptor_count={d}\nrange_record_count={d}\n",
        .{ receipt.descriptor_count, receipt.record_count },
    );
    try appendRangeDigestLine(
        allocator,
        output,
        "manifest_descriptor_sha256",
        receipt.descriptor_digest,
    );
    try appendRangeDigestLine(allocator, output, "range_plan_sha256", receipt.plan_digest);
    try appendRangeDigestLine(allocator, output, "metadata_sha256", receipt.metadata_digest);
}

pub fn parseRangeReceipt(source: []const u8) !RangeReceipt {
    if (source.len == 0 or source[source.len - 1] != '\n') return error.InvalidRangeReceipt;
    var lines = std.mem.splitScalar(u8, source[0 .. source.len - 1], '\n');
    const first = lines.next() orelse return error.InvalidRangeReceipt;
    if (!std.mem.eql(u8, first, range_receipt_first_line)) return error.InvalidRangeReceipt;
    const receipt: RangeReceipt = .{
        .kind = std.meta.stringToEnum(
            RangeReceiptKind,
            try takeRangeValue(&lines, "range_kind"),
        ) orelse return error.InvalidRangeReceipt,
        .declared = .{
            .low = try takeRangeCount(&lines, "range_low"),
            .high = try takeRangeCount(&lines, "range_high"),
        },
        .coverage = std.meta.stringToEnum(
            RangeCoverage,
            try takeRangeValue(&lines, "range_coverage"),
        ) orelse return error.InvalidRangeReceipt,
        .shard_count = try takeRangeCount(&lines, "range_shard_count"),
        .descriptor_count = std.math.cast(usize, try takeRangeCount(
            &lines,
            "range_descriptor_count",
        )) orelse return error.InvalidRangeReceipt,
        .record_count = try takeRangeCount(&lines, "range_record_count"),
        .descriptor_digest = try takeRangeDigest(&lines, "manifest_descriptor_sha256"),
        .plan_digest = try takeRangeDigest(&lines, "range_plan_sha256"),
        .metadata_digest = try takeRangeDigest(&lines, "metadata_sha256"),
    };
    if (lines.next() != null) return error.InvalidRangeReceipt;
    if (receipt.declared.low >= receipt.declared.high) return error.InvalidRangeReceipt;
    if (receipt.declared.high > max_raw_binary32_inputs) return error.InvalidRangeReceipt;
    if (receipt.shard_count == 0) return error.InvalidRangeReceipt;
    return receipt;
}

fn takeRangeValue(lines: anytype, name: []const u8) ![]const u8 {
    const text = lines.next() orelse return error.InvalidRangeReceipt;
    if (!std.mem.startsWith(u8, text, name)) return error.InvalidRangeReceipt;
    if (text.len <= name.len or text[name.len] != '=') return error.InvalidRangeReceipt;
    return text[name.len + 1 ..];
}

fn takeRangeCount(lines: anytype, name: []const u8) !u64 {
    const text = try takeRangeValue(lines, name);
    if (text.len == 0 or text.len > 20) return error.InvalidRangeReceipt;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidRangeReceipt;
    }
    if (text.len > 1 and text[0] == '0') return error.InvalidRangeReceipt;
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidRangeReceipt;
}

fn takeRangeDigest(lines: anytype, name: []const u8) !Digest {
    const text = try takeRangeValue(lines, name);
    if (text.len != @sizeOf(Digest) * 2) return error.InvalidRangeReceipt;
    var digest: Digest = undefined;
    for (0..@sizeOf(Digest)) |index| {
        const high = parseHexNibble(text[index * 2]) catch return error.InvalidRangeReceipt;
        const low = parseHexNibble(text[index * 2 + 1]) catch return error.InvalidRangeReceipt;
        digest[index] = (high << 4) | low;
    }
    return digest;
}

/// A range row states the identity of its descriptor and the exact interval
/// its artifact holds. It deliberately carries no campaign fields: a range
/// artifact is not a campaign enumeration, and a row that named a campaign
/// here would claim a coverage the run did not produce.
pub const RangeRow = struct {
    signature_index: usize,
    operation: []const u8,
    manifest_status: corpus.FunctionStatus,
    oracle: corpus.Oracle,
    evaluator: corpus.Oracle,
    range_low: u64,
    range_high: u64,
    records: u64,
    input_argument: usize,
    source_hash: Digest,
    artifact: []const u8,
    artifact_sha256: Digest,
};

const range_row_format = "signature={d};operation={s};manifest_status={s};oracle={s};" ++
    "evaluator={s};range_low={d};range_high={d};records={d};input_format=f;" ++
    "input_argument={d};source_metadata_available=false;evidence_available=true;" ++
    "source_hash={s};artifact={s};artifact_sha256={s};" ++
    "source_repository=none;source_revision=none;source_path=none";

pub fn rangeSourceDigest() Digest {
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(range_source_unavailable_text, &digest, .{});
    return digest;
}

pub fn appendRangeRow(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    row: RangeRow,
) !void {
    const source_hash_hex = std.fmt.bytesToHex(row.source_hash, .lower);
    const artifact_hash_hex = std.fmt.bytesToHex(row.artifact_sha256, .lower);
    // A row carries two digest hex strings and an artifact path, so it is
    // rendered through its own buffer. The receipt writers use the short one
    // because a receipt line is a name and a number.
    var buffer: [1024]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, range_row_format, .{
        row.signature_index,
        row.operation,
        @tagName(row.manifest_status),
        @tagName(row.oracle),
        @tagName(row.evaluator),
        row.range_low,
        row.range_high,
        row.records,
        row.input_argument,
        source_hash_hex[0..],
        row.artifact,
        artifact_hash_hex[0..],
    });
    try output.appendSlice(allocator, rendered);
    try output.append(allocator, '\n');
}

pub fn parseRangeRow(line: []const u8) !RangeRow {
    // Every read below is one field, in the order `range_row_format` writes
    // them, because the format is positional: a reader that took the fields in
    // another order would reject every row a writer produces. A field whose
    // spelling is fixed has exactly one legal value, so it is checked where it
    // is read instead of being stored on a row that could carry another.
    var fields = std.mem.splitScalar(u8, line, ';');
    const signature_index = std.math.cast(usize, try parseRangeUnsigned(
        try takeRangeField(&fields, "signature"),
    )) orelse return error.InvalidRangeRow;
    const operation = try takeRangeField(&fields, "operation");
    const manifest_status = std.meta.stringToEnum(
        corpus.FunctionStatus,
        try takeRangeField(&fields, "manifest_status"),
    ) orelse return error.InvalidRangeRow;
    const oracle = std.meta.stringToEnum(
        corpus.Oracle,
        try takeRangeField(&fields, "oracle"),
    ) orelse return error.InvalidRangeRow;
    const evaluator = std.meta.stringToEnum(
        corpus.Oracle,
        try takeRangeField(&fields, "evaluator"),
    ) orelse return error.InvalidRangeRow;
    const range_low = try parseRangeUnsigned(try takeRangeField(&fields, "range_low"));
    const range_high = try parseRangeUnsigned(try takeRangeField(&fields, "range_high"));
    const records = try parseRangeUnsigned(try takeRangeField(&fields, "records"));
    if (!std.mem.eql(u8, try takeRangeField(&fields, "input_format"), "f")) {
        return error.InvalidRangeRow;
    }
    const input_argument = std.math.cast(usize, try parseRangeUnsigned(
        try takeRangeField(&fields, "input_argument"),
    )) orelse return error.InvalidRangeRow;
    if (!std.mem.eql(u8, try takeRangeField(&fields, "source_metadata_available"), "false")) {
        return error.InvalidRangeRow;
    }
    if (!std.mem.eql(u8, try takeRangeField(&fields, "evidence_available"), "true")) {
        return error.InvalidRangeRow;
    }
    const source_hash = try parseRangeRowDigest(try takeRangeField(&fields, "source_hash"));
    if (!std.mem.eql(u8, &source_hash, &rangeSourceDigest())) return error.InvalidRangeRow;
    const artifact = try takeRangeField(&fields, "artifact");
    const artifact_sha256 = try parseRangeRowDigest(
        try takeRangeField(&fields, "artifact_sha256"),
    );
    if (!std.mem.eql(u8, try takeRangeField(&fields, "source_repository"), "none")) {
        return error.InvalidRangeRow;
    }
    if (!std.mem.eql(u8, try takeRangeField(&fields, "source_revision"), "none")) {
        return error.InvalidRangeRow;
    }
    if (!std.mem.eql(u8, try takeRangeField(&fields, "source_path"), "none")) {
        return error.InvalidRangeRow;
    }
    if (fields.next() != null) return error.InvalidRangeRow;
    return .{
        .signature_index = signature_index,
        .operation = operation,
        .manifest_status = manifest_status,
        .oracle = oracle,
        .evaluator = evaluator,
        .range_low = range_low,
        .range_high = range_high,
        .records = records,
        .input_argument = input_argument,
        .source_hash = source_hash,
        .artifact = artifact,
        .artifact_sha256 = artifact_sha256,
    };
}

fn takeRangeField(fields: anytype, name: []const u8) ![]const u8 {
    const field = fields.next() orelse return error.InvalidRangeRow;
    if (field.len <= name.len + 1) return error.InvalidRangeRow;
    if (!std.mem.eql(u8, field[0..name.len], name)) return error.InvalidRangeRow;
    if (field[name.len] != '=') return error.InvalidRangeRow;
    return field[name.len + 1 ..];
}

fn parseRangeUnsigned(text: []const u8) !u64 {
    if (text.len == 0 or text.len > 20) return error.InvalidRangeRow;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidRangeRow;
    }
    if (text.len > 1 and text[0] == '0') return error.InvalidRangeRow;
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidRangeRow;
}

fn parseRangeRowDigest(text: []const u8) !Digest {
    if (text.len != @sizeOf(Digest) * 2) return error.InvalidRangeRow;
    var digest: Digest = undefined;
    for (0..@sizeOf(Digest)) |index| {
        const high = parseHexNibble(text[index * 2]) catch return error.InvalidRangeRow;
        const low = parseHexNibble(text[index * 2 + 1]) catch return error.InvalidRangeRow;
        digest[index] = (high << 4) | low;
    }
    return digest;
}

fn expectRangeLine(lines: anytype, expected: []const u8) !void {
    const line = lines.next() orelse return error.InvalidRangeMetadata;
    if (!std.mem.eql(u8, line, expected)) return error.InvalidRangeMetadata;
}

/// Streams one range artifact and proves, in one pass and in bounded memory,
/// that it holds exactly the raw inputs `[expected.low, expected.high)` in
/// ascending order for `expected_operation`. Record `i` must carry raw input
/// `expected.low + i`, which proves the count, the first input, the last
/// input, the order, and the absence of a hole, a duplicate, and a seam in one
/// identity, and the digest check then proves the bytes arrived intact.
pub fn streamRangeArtifact(
    io: std.Io,
    dir: std.Io.Dir,
    artifact_path: []const u8,
    expected: RawRange,
    expected_operation: []const u8,
    expected_digest: ?Digest,
    context: anytype,
    callback: anytype,
) !u64 {
    if (expected.low >= expected.high or expected.high > max_raw_binary32_inputs) {
        return error.InvalidRawRange;
    }
    const file = dir.openFile(io, artifact_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("a range artifact is missing: {s}\n", .{artifact_path});
            return error.RangeArtifactMissing;
        },
        else => return err,
    };
    defer file.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    var frames: [2][record_buffer_capacity]u8 = undefined;
    var frame_slot: u1 = 0;
    var previous: ?corpus.CorpusRecord = null;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var record_index: u64 = 0;

    while (try corpus.readEncodedRecord(&file_reader.interface, frames[frame_slot][0..])) |encoded| {
        hasher.update(encoded);
        if (record_index >= expected.length()) {
            std.debug.print(
                "range artifact holds more than its interval: {s}\n",
                .{artifact_path},
            );
            return error.RangeRecordCountMismatch;
        }
        const record = try corpus.decodeCorpusRecord(encoded);
        if (record.operation.len != expected_operation.len or
            !std.mem.eql(u8, record.operation, expected_operation))
        {
            std.debug.print(
                "range artifact {s} record {d} belongs to another operation\n",
                .{ artifact_path, record_index },
            );
            return error.RangeOperationMismatch;
        }
        try validateRangeRawArgument(&record, expected, record_index, artifact_path);
        if (previous) |*prior| try corpus.validateCorpusRecordOrder(prior, &record);
        try callback(context, record_index, &record);
        previous = record;
        frame_slot ^= 1;
        record_index = std.math.add(u64, record_index, 1) catch
            return error.RecordCountOverflow;
    }

    if (record_index != expected.length()) {
        std.debug.print(
            "range artifact {s} holds {d} records, not {d}\n",
            .{ artifact_path, record_index, expected.length() },
        );
        return error.RangeRecordCountMismatch;
    }
    var digest: Digest = undefined;
    hasher.final(&digest);
    if (expected_digest) |claimed| {
        if (!std.mem.eql(u8, &digest, &claimed)) {
            std.debug.print(
                "range artifact digest mismatch: {s}\n",
                .{artifact_path},
            );
            return error.RangeArtifactDigestMismatch;
        }
    }
    return record_index;
}

/// The single per-record identity that carries the whole interval proof: the
/// only argument is a 32-bit float, and its raw bits are the one the interval
/// says record `record_index` must hold.
fn validateRangeRawArgument(
    record: *const corpus.CorpusRecord,
    expected: RawRange,
    record_index: u64,
    artifact_path: []const u8,
) !void {
    const arguments = record.arguments.slice();
    if (arguments.len != 1) {
        std.debug.print(
            "range artifact {s} record {d} does not have one input\n",
            .{ artifact_path, record_index },
        );
        return error.RangeInputDescriptorMismatch;
    }
    const value = switch (arguments[0]) {
        .float => |field| field,
        else => {
            std.debug.print(
                "range artifact {s} record {d} input is not a float\n",
                .{ artifact_path, record_index },
            );
            return error.RangeInputDescriptorMismatch;
        },
    };
    if (value.format != .f) {
        std.debug.print(
            "range artifact {s} record {d} input is not binary32\n",
            .{ artifact_path, record_index },
        );
        return error.RangeInputDescriptorMismatch;
    }
    const wanted = expected.low + record_index;
    if (value.bits != wanted) {
        std.debug.print(
            "range artifact {s} record {d} holds raw input 0x{x}, not 0x{x}\n",
            .{ artifact_path, record_index, value.bits, wanted },
        );
        return error.RangeRawInputMismatch;
    }
}

fn ignoreRangeRecord(context: void, record_index: u64, record: *const corpus.CorpusRecord) !void {
    _ = context;
    _ = record_index;
    _ = record;
}

pub fn verifyRangeArtifact(
    io: std.Io,
    dir: std.Io.Dir,
    artifact_path: []const u8,
    expected: RawRange,
    expected_operation: []const u8,
    expected_digest: ?Digest,
) !u64 {
    return streamRangeArtifact(
        io,
        dir,
        artifact_path,
        expected,
        expected_operation,
        expected_digest,
        {},
        ignoreRangeRecord,
    );
}

pub const LoadedRange = struct {
    set: Set,
    receipt: RangeReceipt,

    pub fn deinit(self: *LoadedRange, allocator: std.mem.Allocator) void {
        self.set.deinit(allocator);
        self.* = undefined;
    }
};

/// Loads a range publication: the receipt, the metadata it names, and every
/// descriptor row the current manifest, profile, and filters ask for. The
/// interval, the descriptor digest, the plan digest, the shard count, and the
/// coverage claim are all recomputed here, so a stale, partial, or
/// mis-declared range publication is refused before a caller reads a record.
pub fn loadRange(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    run_root: []const u8,
    manifest: *const corpus.Manifest,
    profile: Profile,
    filters: Filters,
    declared: RawRange,
) !LoadedRange {
    if (run_root.len == 0) return error.InvalidRunRoot;
    if (declared.low >= declared.high or declared.high > max_raw_binary32_inputs) {
        return error.InvalidRawRange;
    }

    const incomplete_path = try std.fs.path.join(allocator, &.{ run_root, ".incomplete" });
    defer allocator.free(incomplete_path);
    try rejectIncompletePublication(io, dir, incomplete_path);

    // An ordinary completion marker in a range root would be a claim the run
    // never made, and a range run must never be able to remove one.
    const ordinary_marker = try std.fs.path.join(allocator, &.{ run_root, "COMPLETE" });
    defer allocator.free(ordinary_marker);
    if (try pathPresent(io, dir, ordinary_marker)) return error.UnexpectedOrdinaryCompletion;

    const complete_path = try std.fs.path.join(allocator, &.{ run_root, "RANGE_COMPLETE" });
    defer allocator.free(complete_path);
    const worker_path = try std.fs.path.join(allocator, &.{ run_root, "RANGE" });
    defer allocator.free(worker_path);
    const assembled = try pathPresent(io, dir, complete_path);
    const receipt_path = if (assembled) complete_path else worker_path;
    const receipt_source = dir.readFileAlloc(
        io,
        receipt_path,
        allocator,
        .limited(range_receipt_bytes_max),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingRangeReceipt,
        else => return err,
    };
    defer allocator.free(receipt_source);
    const receipt = try parseRangeReceipt(receipt_source);
    if (!RawRange.eql(receipt.declared, declared)) return error.RangeIntervalMismatch;

    const selection = rangeSelection(manifest, filters);
    if (selection.count == 0) return error.EmptySelection;
    if (receipt.descriptor_count != selection.count) return error.IncompleteSelection;
    const expected_digest = try rangeDescriptorDigest(profile, manifest, filters);
    if (!std.mem.eql(u8, &receipt.descriptor_digest, &expected_digest)) {
        return error.RangeDescriptorDigestMismatch;
    }
    const plan = RangePlan{
        .profile = profile,
        .filters = filters,
        .descriptor_digest = expected_digest,
        .declared = declared,
        .shard_count = receipt.shard_count,
        .shard_index = 0,
        .subrange = declared,
    };
    if (!std.mem.eql(u8, &receipt.plan_digest, &rangePlanDigest(plan))) {
        return error.RangePlanMismatch;
    }
    const complete_tiling = switch (receipt.kind) {
        .worker => receipt.shard_count == 1,
        .assembled => true,
    };
    if (assembled != (receipt.kind == .assembled)) return error.InvalidRangeReceipt;
    const expected_coverage = rangeCoverage(declared, complete_tiling);
    if (receipt.coverage != expected_coverage) return error.RangeCoverageMismatch;

    const metadata_path = try std.fs.path.join(allocator, &.{ run_root, "metadata.txt" });
    defer allocator.free(metadata_path);
    const source = dir.readFileAlloc(
        io,
        metadata_path,
        allocator,
        .limited(range_metadata_bytes_max),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingMetadata,
        else => return err,
    };
    errdefer allocator.free(source);
    var actual_metadata_digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &actual_metadata_digest, .{});
    if (!std.mem.eql(u8, &actual_metadata_digest, &receipt.metadata_digest)) {
        return error.MetadataDigestMismatch;
    }

    var set: Set = .{
        .source = source,
        .entries = undefined,
        .count = 0,
    };
    try parseRangeMetadata(&set, run_root, manifest, profile, filters, declared, receipt);

    // A concurrent publisher cannot turn a partial replacement into a valid
    // snapshot.
    try rejectIncompletePublication(io, dir, incomplete_path);
    return .{ .set = set, .receipt = receipt };
}

fn parseRangeMetadata(
    set: *Set,
    run_root: []const u8,
    manifest: *const corpus.Manifest,
    profile: Profile,
    filters: Filters,
    declared: RawRange,
    receipt: RangeReceipt,
) !void {
    if (manifest.function_count != corpus.max_function_count) {
        return error.ManifestCountMismatch;
    }
    const source = set.source;
    if (source.len == 0) return error.InvalidRangeMetadata;
    if (source[source.len - 1] != '\n') return error.InvalidRangeMetadata;
    for (source) |byte| {
        if (byte == '\r' or byte == 0) return error.InvalidRangeMetadata;
    }

    var lines = std.mem.splitScalar(u8, source[0 .. source.len - 1], '\n');
    try expectRangeLine(&lines, range_metadata_first_line);
    const header_interval = RawRange{
        .low = try takeRangeCount(&lines, "range_low"),
        .high = try takeRangeCount(&lines, "range_high"),
    };
    if (!RawRange.eql(header_interval, declared)) return error.RangeIntervalMismatch;
    if (try takeRangeCount(&lines, "range_input_width_bits") != range_input_width_bits) {
        return error.RangeInputWidthMismatch;
    }
    const header_descriptor_count = std.math.cast(usize, try takeRangeCount(
        &lines,
        "range_descriptor_count",
    )) orelse return error.InvalidRangeMetadata;
    if (header_descriptor_count != receipt.descriptor_count) {
        return error.IncompleteSelection;
    }
    const header_coverage = std.meta.stringToEnum(
        RangeCoverage,
        try takeRangeValue(&lines, "range_coverage"),
    ) orelse return error.InvalidRangeMetadata;
    if (header_coverage != receipt.coverage) return error.RangeCoverageMismatch;
    if (try takeRangeCount(&lines, "range_shard_count") != receipt.shard_count) {
        return error.RangePlanMismatch;
    }
    const header_digest = try takeRangeDigest(&lines, "manifest_descriptor_sha256");
    if (!std.mem.eql(u8, &header_digest, &receipt.descriptor_digest)) {
        return error.RangeDescriptorDigestMismatch;
    }
    // The metadata digest is deliberately NOT repeated in the header: it is the
    // digest of these bytes, so it belongs to the receipt beside the header,
    // which is what `loadRange` compared the file against.
    const header_plan_digest = try takeRangeDigest(&lines, "range_plan_sha256");
    if (!std.mem.eql(u8, &header_plan_digest, &receipt.plan_digest)) {
        return error.RangePlanMismatch;
    }
    if (!std.mem.eql(u8, try takeRangeValue(&lines, "core_math_repository"), campaigns.core_math_repository)) {
        return error.CoreMathIdentityMismatch;
    }
    if (!std.mem.eql(u8, try takeRangeValue(&lines, "core_math_revision"), campaigns.core_math_revision)) {
        return error.CoreMathIdentityMismatch;
    }
    if (!std.mem.eql(u8, try takeRangeValue(&lines, "profile_target"), profile.target)) {
        return error.ProfileMismatch;
    }
    if (!std.mem.eql(u8, try takeRangeValue(&lines, "profile_cpu"), profile.cpu)) {
        return error.ProfileMismatch;
    }
    if (!std.mem.eql(u8, try takeRangeValue(&lines, "profile_mode"), profile.mode)) {
        return error.ProfileMismatch;
    }
    const scope = std.meta.stringToEnum(
        GenerationScope,
        try takeRangeValue(&lines, "generation_scope"),
    ) orelse return error.InvalidRangeMetadata;
    const filtered = filters.operation != null or filters.format != null;
    switch (scope) {
        .full => if (filtered) return error.InvalidRangeMetadata,
        .filtered => if (!filtered) return error.InvalidRangeMetadata,
    }
    const operation_filter = try takeRangeValue(&lines, "operation_filter");
    if (filters.operation) |operation| {
        if (!std.mem.eql(u8, operation_filter, operation)) return error.InvalidRangeMetadata;
    } else if (!std.mem.eql(u8, operation_filter, "all")) {
        return error.InvalidRangeMetadata;
    }
    const format_filter = try takeRangeValue(&lines, "format_filter");
    if (filters.format) |format| {
        if (!std.mem.eql(u8, format_filter, @tagName(format))) return error.InvalidRangeMetadata;
    } else if (!std.mem.eql(u8, format_filter, "all")) {
        return error.InvalidRangeMetadata;
    }
    if (try takeRangeCount(&lines, "record_codec_version") !=
        corpus.descriptor_corpus_codec_version)
    {
        return error.RecordCodecMismatch;
    }
    try expectRangeLine(&lines, "");

    const selection = rangeSelection(manifest, filters);
    for (selection.indices[0..selection.count], 0..) |expected_index, entry_index| {
        const line = lines.next() orelse return error.IncompleteSelection;
        if (line.len == 0) return error.InvalidRangeMetadata;
        if (set.count == corpus.max_function_count) return error.TooManyMetadataRows;
        const row = try parseRangeRow(line);
        if (row.signature_index != expected_index) return error.UnorderedMetadataRow;
        const function = &manifest.function_values[expected_index];
        try validateRangeRow(row, run_root, function, declared);
        set.entries[entry_index] = .{
            .signature_index = expected_index,
            .operation = row.operation,
            .artifact = row.artifact,
            .records = row.records,
            .digest = row.artifact_sha256,
            .evaluator = row.evaluator,
        };
        set.count += 1;
    }
    if (set.count != selection.count) return error.IncompleteSelection;
    if (lines.next() != null) return error.UnexpectedMetadataRow;
}

fn validateRangeRow(
    row: RangeRow,
    run_root: []const u8,
    function: *const corpus.Function,
    declared: RawRange,
) !void {
    if (!rangeEligible(function)) return error.RangeSelectionMismatch;
    if (!std.mem.eql(u8, row.operation, function.op)) return error.OperationMismatch;
    const signature = try evaluatorSignature(function);
    if (!signatureMatchesFunction(signature, function)) return error.SignatureMismatch;
    const evaluator = try evaluatorCategory(signature);
    if (row.evaluator != evaluator) return error.EvaluatorMismatch;
    try validateStatusSnapshot(row.manifest_status, row.oracle, evaluator);
    try validateStatusSnapshot(function.status, function.oracle, evaluator);
    if (row.range_low != declared.low or row.range_high != declared.high) {
        return error.RangeIntervalMismatch;
    }
    if (row.range_low >= row.range_high) return error.InvalidRangeRow;
    if (row.range_high > max_raw_binary32_inputs) return error.InvalidRangeRow;
    if (row.records != row.range_high - row.range_low) return error.RangeRecordCountMismatch;
    if (row.input_argument != 0) return error.RangeInputDescriptorMismatch;
    if (std.mem.eql(u8, &row.artifact_sha256, &@as(Digest, @splat(0)))) {
        return error.InvalidRangeRow;
    }
    if (!artifactPathMatches(row.artifact, run_root, row.signature_index, row.operation)) {
        return error.ArtifactPathMismatch;
    }
}

fn pathPresent(io: std.Io, dir: std.Io.Dir, path: []const u8) !bool {
    dir.access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

// ---------------------------------------------------------------------------
// Producer reuse
//
// A grown manifest must not leave the old verified artifacts behind, and it
// must not regenerate them either: the exhaustive campaigns behind the old
// rows are not reproducible on demand. Reuse is therefore an explicit opt-in
// that copies an artifact only after the source publication has been proved,
// and rebuilds every other part of the publication through the normal
// producer.
//
// The proof has three parts, and each one answers a question the others
// cannot. The header proves the identity of the publication: its `COMPLETE`
// marker, the SHA-256 of its metadata, the core-math repository and revision,
// the qualified profile, the scope, and the record codec. The rows prove the
// identity of every descriptor: each row is matched to the one current
// descriptor it may supply, and the source's own `manifest_descriptor_sha256`
// is reconstructed from those matched current descriptors, hashed under the
// source's own indices in the source's own order, so a changed `max_ulp`, a
// changed result kind, a changed argument descriptor, a changed policy, or a
// changed C signature changes the digest and refuses the reuse. The artifacts
// prove the identity of the numbers: every record of every reused artifact is
// streamed, and its operation, provenance, argument formats, result
// descriptor, and `max_ulp` must be the current function's, its records must
// be in the canonical order, and the file must hold exactly the count its row
// claims under the digest its row claims. A digest alone is not that proof, so
// none of the three is skipped because another one passed.
//
// One operation name is published once per format, and the campaign identity a
// row carries is the same for all of them, so a row on its own cannot say which
// of them it holds. The first record of the row's artifact can: its argument
// fields are the descriptor's own formats. That record only CHOOSES
// the candidate. Every later record is then proved against the chosen
// descriptor, and the source descriptor digest is rebuilt from the choice, so a
// candidate the first record admits and no second record answers is still
// refused, and a candidate no record answers is never chosen.
//
// A ZCDR record carries no signature index, so an unchanged descriptor means
// the artifact bytes are unchanged and a reuse is a byte-identical copy. The
// identity that DOES move is the artifact file name and the metadata row, and
// both are rebuilt from the current manifest rather than rewritten from the
// old ones.
// ---------------------------------------------------------------------------

pub const ReusableEntry = struct {
    /// The current manifest index this artifact supplies.
    signature_index: usize,
    /// The path the source publication named, relative to the same root.
    source_artifact: []const u8,
    records: u64,
    digest: Digest,
};

pub const ReuseSet = struct {
    source: []u8,
    entries: [corpus.max_function_count]ReusableEntry,
    available: [corpus.max_function_count]bool,
    source_descriptor_count: usize,
    reusable_count: usize,

    pub fn deinit(self: *ReuseSet, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        self.* = undefined;
    }

    pub fn at(self: *const ReuseSet, signature_index: usize) ?ReusableEntry {
        if (signature_index >= self.entries.len) return null;
        if (!self.available[signature_index]) return null;
        return self.entries[signature_index];
    }
};

pub fn loadReusable(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    source_run_root: []const u8,
    manifest: *const corpus.Manifest,
    profile: Profile,
    filters: Filters,
) !ReuseSet {
    if (source_run_root.len == 0) return error.InvalidRunRoot;
    const incomplete_path = try std.fs.path.join(
        allocator,
        &.{ source_run_root, ".incomplete" },
    );
    defer allocator.free(incomplete_path);
    try rejectIncompletePublication(io, dir, incomplete_path);

    const completion_path = try std.fs.path.join(
        allocator,
        &.{ source_run_root, "COMPLETE" },
    );
    defer allocator.free(completion_path);
    const completion = dir.readFileAlloc(
        io,
        completion_path,
        allocator,
        .limited(completion_bytes_max),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingCompletion,
        else => return err,
    };
    defer allocator.free(completion);
    const expected_metadata_digest = try parseCompletion(completion);

    const metadata_path = try std.fs.path.join(
        allocator,
        &.{ source_run_root, "metadata.txt" },
    );
    defer allocator.free(metadata_path);
    const source = dir.readFileAlloc(
        io,
        metadata_path,
        allocator,
        .limited(metadata_bytes_max),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingMetadata,
        else => return err,
    };
    errdefer allocator.free(source);
    var actual_metadata_digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &actual_metadata_digest, .{});
    if (!std.mem.eql(u8, &actual_metadata_digest, &expected_metadata_digest)) {
        return error.MetadataDigestMismatch;
    }
    if (source.len == 0 or source[source.len - 1] != '\n') return error.InvalidMetadata;

    // `set.source` and `source` are the same allocation and the `errdefer`
    // above is its only owner until this returns it, so no second errdefer is
    // registered here.
    var set: ReuseSet = .{
        .source = source,
        .entries = undefined,
        .available = @splat(false),
        .source_descriptor_count = 0,
        .reusable_count = 0,
    };
    var lines = std.mem.splitScalar(u8, source[0 .. source.len - 1], '\n');
    try expectLine(&lines, "ZCDM version=1");
    // The source's own descriptor digest covers the selection it was published
    // for, which the current manifest no longer reproduces once rows are
    // added. It is not discarded: it is reconstructed below from the CURRENT
    // descriptors the source rows were matched to, under the source's own
    // indices, so a manifest that only grew still reproduces it exactly and a
    // descriptor that moved does not.
    const source_descriptor_digest = try parseDigest(
        try takeLineValue(&lines, "manifest_descriptor_sha256"),
    );
    if (!std.mem.eql(u8, try takeLineValue(&lines, "core_math_repository"), campaigns.core_math_repository)) {
        return error.CoreMathIdentityMismatch;
    }
    if (!std.mem.eql(u8, try takeLineValue(&lines, "core_math_revision"), campaigns.core_math_revision)) {
        return error.CoreMathIdentityMismatch;
    }
    if (!std.mem.eql(u8, try takeLineValue(&lines, "profile_target"), profile.target)) {
        return error.ProfileMismatch;
    }
    if (!std.mem.eql(u8, try takeLineValue(&lines, "profile_cpu"), profile.cpu)) {
        return error.ProfileMismatch;
    }
    if (!std.mem.eql(u8, try takeLineValue(&lines, "profile_mode"), profile.mode)) {
        return error.ProfileMismatch;
    }
    const source_scope = try parseEnum(GenerationScope, try takeLineValue(&lines, "generation_scope"));
    const source_descriptor_count = try parseCanonicalUnsigned(
        usize,
        10,
        try takeLineValue(&lines, "function_count"),
    );
    if (try parseCanonicalUnsigned(
        usize,
        10,
        try takeLineValue(&lines, "selected_signature_count"),
    ) != source_descriptor_count) {
        return error.IncompleteSelection;
    }
    const source_operation = try takeLineValue(&lines, "operation_filter");
    const source_format = try takeLineValue(&lines, "format_filter");
    const source_filters: Filters = .{
        .operation = if (std.mem.eql(u8, source_operation, "all"))
            null
        else
            source_operation,
        .format = if (std.mem.eql(u8, source_format, "all"))
            null
        else
            std.meta.stringToEnum(corpus.Format, source_format) orelse
                return error.InvalidMetadata,
    };
    // Reuse across a different scope would silently move a filtered
    // publication's rows into an unfiltered one, or the reverse, so the scope
    // must be the same one the caller asked to publish.
    if (sourceFiltersDiffer(source_filters, filters)) return error.ReuseScopeMismatch;
    switch (source_scope) {
        .full => if (filters.operation != null or filters.format != null) {
            return error.ReuseScopeMismatch;
        },
        .filtered => if (filters.operation == null and filters.format == null) {
            return error.ReuseScopeMismatch;
        },
    }
    if (try parseCanonicalUnsigned(
        u8,
        10,
        try takeLineValue(&lines, "record_codec_version"),
    ) != corpus.descriptor_corpus_codec_version) {
        return error.RecordCodecMismatch;
    }
    try expectLine(&lines, "");

    const selection = selectedFunctionIndices(manifest, filters);
    var descriptor_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var previous_index: ?usize = null;
    var first_record: FirstSourceRecord = undefined;
    while (lines.next()) |line| {
        if (line.len == 0) return error.InvalidMetadata;
        if (set.source_descriptor_count == corpus.max_function_count) {
            return error.TooManyMetadataRows;
        }
        const row = try parseMetadataRow(line);
        if (previous_index) |prior| {
            if (row.signature_index <= prior) return error.UnorderedMetadataRow;
        }
        previous_index = row.signature_index;
        set.source_descriptor_count += 1;

        const current = findReusableIndex(
            manifest,
            &selection,
            source_run_root,
            row,
            io,
            dir,
            &first_record,
        ) catch |err| switch (err) {
            error.NoReusableDescriptor => {
                std.debug.print(
                    "source row signature={d} operation={s} no longer matches any current descriptor\n",
                    .{ row.signature_index, row.operation },
                );
                return err;
            },
            else => return err,
        };
        if (set.available[current.index]) return error.ReuseAmbiguousDescriptor;
        set.available[current.index] = true;
        set.entries[current.index] = .{
            .signature_index = current.index,
            .source_artifact = row.artifact,
            .records = row.records,
            .digest = row.artifact_sha256,
        };
        set.reusable_count += 1;

        // The row was published under the source's own index, so the digest is
        // rebuilt with that index and not with the current one. A manifest that
        // only grew reproduces the source digest exactly; a manifest that
        // reordered or edited a descriptor does not, and a source whose header
        // count no longer matches its rows is refused before the digest is
        // even consulted.
        hashU64(&descriptor_hasher, @intCast(row.signature_index));
        descriptor_hasher.update(&descriptorEntryHash(
            profile,
            &manifest.function_values[current.index],
            current.signature,
        ));
    }
    if (set.source_descriptor_count != source_descriptor_count) {
        return error.IncompleteSelection;
    }
    if (set.reusable_count == 0) return error.EmptySelection;
    var actual_descriptor_digest: Digest = undefined;
    descriptor_hasher.final(&actual_descriptor_digest);
    if (!std.mem.eql(u8, &actual_descriptor_digest, &source_descriptor_digest)) {
        return error.DescriptorDigestMismatch;
    }

    // The numbers are proved before this returns, so a caller that copies an
    // artifact copies only a file already shown to hold the current function's
    // own records, in the canonical order, at the count and digest its row
    // claims. Each artifact is streamed once, in a fixed amount of memory.
    for (set.entries[0..corpus.max_function_count], 0..) |*entry, index| {
        if (!set.available[index]) continue;
        _ = try verifyReusableArtifact(
            io,
            dir,
            entry.source_artifact,
            &manifest.function_values[index],
            entry.records,
            entry.digest,
        );
    }
    try rejectIncompletePublication(io, dir, incomplete_path);
    return set;
}

fn sourceFiltersDiffer(left: Filters, right: Filters) bool {
    if ((left.operation == null) != (right.operation == null)) return true;
    if (left.operation) |operation| {
        if (!std.mem.eql(u8, operation, right.operation orelse return true)) return true;
    }
    if ((left.format == null) != (right.format == null)) return true;
    if (left.format) |format| {
        if (format != (right.format orelse return true)) return true;
    }
    return false;
}

fn selectedFunctionIndices(manifest: *const corpus.Manifest, filters: Filters) RangeSelection {
    var selection: RangeSelection = .{};
    for (manifest.function_values[0..manifest.function_count], 0..) |*function, index| {
        if (!functionSelected(function, filters)) continue;
        selection.indices[selection.count] = index;
        selection.count += 1;
    }
    return selection;
}

/// The one current descriptor a source row may supply, and the C evaluator
/// signature that descriptor is published under. The row is proved against
/// that descriptor through the ordinary row validation, which covers the
/// operation, the status, the oracle, the evaluator, the campaign identity,
/// the source pin, the artifact count, and the artifact path. The row does NOT
/// name the format, because a row never does: one operation name is published
/// once per format under one campaign identity, so the format is decided by
/// the artifact's own first record. The numerical identity of the descriptor
/// is carried by the digest `loadReusable` reconstructs, and the identity of
/// the records is carried by the artifact stream, so no single field is the
/// whole proof.
const ReusableMatch = struct {
    index: usize,
    signature: *const oracle_signature,
};

/// One source artifact's first record, held together with the frame that owns
/// its bytes. A decoded record borrows the frame it was decoded from, so the
/// record and its frame may not be separated; one frame of fixed storage serves
/// every row of the source, and the next row overwrites it.
const FirstSourceRecord = struct {
    frame: [record_buffer_capacity]u8 = undefined,
    record: corpus.CorpusRecord = undefined,

    /// Reads and decodes the first record of one artifact, in the fixed amount
    /// of memory a whole artifact would not fit in. A file that holds no record
    /// at all is refused here rather than further down, where a count of zero
    /// has no proof left to give.
    fn read(self: *FirstSourceRecord, io: std.Io, dir: std.Io.Dir, artifact_path: []const u8) !void {
        const file = dir.openFile(io, artifact_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("a reusable artifact is missing: {s}\n", .{artifact_path});
                return error.ReuseArtifactMissing;
            },
            else => return err,
        };
        defer file.close(io);
        var read_buffer: [64 * 1024]u8 = undefined;
        var file_reader = file.reader(io, &read_buffer);
        const encoded = (try corpus.readEncodedRecord(
            &file_reader.interface,
            self.frame[0..],
        )) orelse {
            std.debug.print("reusable artifact {s} holds no records\n", .{artifact_path});
            return error.ReuseArtifactEmpty;
        };
        self.record = try corpus.decodeCorpusRecord(encoded);
    }
};

fn findReusableIndex(
    manifest: *const corpus.Manifest,
    selection: *const RangeSelection,
    source_run_root: []const u8,
    row: MetadataRow,
    io: std.Io,
    dir: std.Io.Dir,
    first_record: *FirstSourceRecord,
) !ReusableMatch {
    const expected_source_hash = sourceUnavailableDigest();
    var found: ?ReusableMatch = null;
    var record_read = false;
    for (selection.indices[0..selection.count]) |index| {
        const function = &manifest.function_values[index];
        if (!std.mem.eql(u8, row.operation, function.op)) continue;
        if (campaigns.matchingRuleCount(function.*) != 1) continue;
        const definition = campaigns.classify(function.*);
        const signature = evaluatorSignature(function) catch continue;
        if (definition.campaignClass() == .unavailable) continue;
        _ = validateMetadataRow(
            row,
            source_run_root,
            function,
            &definition,
            signature,
            expected_source_hash,
        ) catch continue;
        // Most rows have one metadata candidate and need no extra artifact
        // read. If a second candidate shares the row, the first record resolves
        // its numerical descriptor. Full-artifact proof still follows below.
        // Row validation has already confined this path to the source root.
        if (!record_read) {
            if (found) |prior| {
                try first_record.read(io, dir, row.artifact);
                record_read = true;
                const prior_function = &manifest.function_values[prior.index];
                if (recordMatchesFunction(prior_function, &first_record.record) != .agrees) {
                    found = null;
                }
            }
        }
        if (record_read and recordMatchesFunction(function, &first_record.record) != .agrees) continue;
        // One source row for two current descriptors would let a run guess which
        // of two identical descriptors the artifact belongs to. It is refused
        // instead, because guessing is how a publication ends up with the wrong
        // evidence under the right name.
        if (found != null) return error.ReuseAmbiguousDescriptor;
        found = .{ .index = index, .signature = signature };
    }
    return found orelse error.NoReusableDescriptor;
}

/// One proved reusable artifact: the records it actually holds, and the digest
/// of the bytes it actually held.
pub const ReusableArtifactProof = struct {
    record_count: u64,
    digest: Digest,
};

/// Streams one reusable artifact and proves, in one pass and in a fixed amount
/// of memory, that it belongs to the CURRENT function. Every record must
/// carry that function's operation, provenance, argument descriptors, result
/// descriptor, and `max_ulp`; the records must be in the canonical record
/// order; and the file must hold exactly `expected_records` of them. The
/// digest is of the bytes that arrived, so a file that decodes cleanly but
/// answers a different descriptor is still refused, and a row cannot buy a
/// pass by naming the digest of the file it ships.
///
/// Each encoded record is handed to `sink` in the same pass, so a caller that
/// copies the artifact proves the bytes it writes and writes them once. A
/// caller that only checks writes to a sink that discards.
pub fn streamReusableArtifact(
    io: std.Io,
    dir: std.Io.Dir,
    artifact_path: []const u8,
    function: *const corpus.Function,
    expected_records: u64,
    expected_digest: ?Digest,
    context: anytype,
    sink: anytype,
) !ReusableArtifactProof {
    if (expected_records == 0) return error.ReuseRecordCountMismatch;
    const file = dir.openFile(io, artifact_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("a reusable artifact is missing: {s}\n", .{artifact_path});
            return error.ReuseArtifactMissing;
        },
        else => return err,
    };
    defer file.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    // Two frames, because the slot advances at the BOTTOM of the loop: record
    // k-1 borrows frame (k-1) mod 2 while record k borrows frame k mod 2, so
    // the order check never reads the frame this iteration just filled. The
    // frame holding `previous` is refilled one iteration later, after
    // `previous` has already moved on.
    var frames: [2][record_buffer_capacity]u8 = undefined;
    var frame_slot: u1 = 0;
    var previous: ?corpus.CorpusRecord = null;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var record_index: u64 = 0;

    while (try corpus.readEncodedRecord(
        &file_reader.interface,
        frames[frame_slot][0..],
    )) |encoded| {
        hasher.update(encoded);
        if (record_index >= expected_records) {
            std.debug.print(
                "reusable artifact {s} holds more records than its row claims\n",
                .{artifact_path},
            );
            return error.ReuseRecordCountMismatch;
        }
        const record = try corpus.decodeCorpusRecord(encoded);
        try proveReusableRecord(function, &record, artifact_path, record_index);
        if (previous) |*prior| try corpus.validateCorpusRecordOrder(prior, &record);
        try sink(context, encoded);
        previous = record;
        frame_slot ^= 1;
        record_index = std.math.add(u64, record_index, 1) catch
            return error.RecordCountOverflow;
    }

    if (record_index != expected_records) {
        std.debug.print(
            "reusable artifact {s} holds {d} records, not {d}\n",
            .{ artifact_path, record_index, expected_records },
        );
        return error.ReuseRecordCountMismatch;
    }
    var digest: Digest = undefined;
    hasher.final(&digest);
    if (expected_digest) |claimed| {
        if (!std.mem.eql(u8, &digest, &claimed)) {
            std.debug.print("reusable artifact digest mismatch: {s}\n", .{artifact_path});
            return error.ReuseArtifactDigestMismatch;
        }
    }
    return .{ .record_count = record_index, .digest = digest };
}

fn discardReusableRecord(context: void, encoded: []const u8) !void {
    _ = context;
    _ = encoded;
}

/// Proves one reusable artifact and copies none of it.
pub fn verifyReusableArtifact(
    io: std.Io,
    dir: std.Io.Dir,
    artifact_path: []const u8,
    function: *const corpus.Function,
    expected_records: u64,
    expected_digest: ?Digest,
) !u64 {
    const proof = try streamReusableArtifact(
        io,
        dir,
        artifact_path,
        function,
        expected_records,
        expected_digest,
        {},
        discardReusableRecord,
    );
    return proof.record_count;
}

/// How one record answers one descriptor. A record that answers a different
/// descriptor and a record that answers it with the wrong argument formats are
/// different faults, and the stream proof names them apart.
const RecordMatch = enum {
    agrees,
    descriptor_mismatch,
    argument_mismatch,
};

/// One record against one function, as the predicate both callers share. A
/// ZCDR record carries the operation name, the provenance, the argument fields
/// with their own descriptors, the result descriptor, the result fields, and
/// `max_ulp`, so a changed tolerance, a changed result kind, or a widened input
/// format is visible in the record bytes and not only in the row that names
/// them. The argument formats are what separate the current descriptors that
/// share one operation name.
fn recordMatchesFunction(
    function: *const corpus.Function,
    record: *const corpus.CorpusRecord,
) RecordMatch {
    const descriptors = function.arguments();
    if (!std.mem.eql(u8, record.operation, function.op) or
        !provenanceListEqual(&record.provenance, &function.provenance) or
        !std.meta.eql(record.result_descriptor, function.result) or
        record.max_ulp != function.max_ulp or
        @as(usize, function.arity) != descriptors.len or
        record.arguments.count != descriptors.len or
        record.results.count != function.result.oracleFieldCount())
    {
        return .descriptor_mismatch;
    }
    for (record.arguments.slice(), descriptors) |field, descriptor| {
        if (!corpusFieldMatchesInput(field, descriptor)) return .argument_mismatch;
    }
    return .agrees;
}

/// One record against the CURRENT function, for the artifact stream that proves
/// every record instead of the first one.
fn proveReusableRecord(
    function: *const corpus.Function,
    record: *const corpus.CorpusRecord,
    artifact_path: []const u8,
    record_index: u64,
) !void {
    switch (recordMatchesFunction(function, record)) {
        .agrees => {},
        .descriptor_mismatch => {
            std.debug.print(
                "reusable artifact {s} record {d} does not match the current descriptor\n",
                .{ artifact_path, record_index },
            );
            return error.ReuseRecordDescriptorMismatch;
        },
        .argument_mismatch => {
            std.debug.print(
                "reusable artifact {s} record {d} input does not match the current descriptor\n",
                .{ artifact_path, record_index },
            );
            return error.ReuseRecordDescriptorMismatch;
        },
    }
}

/// One record field against one input descriptor. The decoder proves a float
/// field's width and class against the field itself, so the descriptor is
/// what binds a field to a position: a binary16 input is not answered by a
/// binary32 field, and a signed integer input is not answered by an unsigned
/// one.
fn corpusFieldMatchesInput(
    field: corpus.CorpusField,
    descriptor: corpus.InputDescriptor,
) bool {
    return switch (descriptor) {
        .float => |format| switch (field) {
            .float => |value| value.format == format,
            else => false,
        },
        .integer => |integer_type| switch (field) {
            .signed_integer => |value| value.integer_type == integer_type,
            .unsigned_integer => |value| value.integer_type == integer_type,
            else => false,
        },
        .tag => switch (field) {
            .tag => true,
            else => false,
        },
        .fromfp_round => switch (field) {
            .rounding => true,
            else => false,
        },
        .round_mode => switch (field) {
            .round_mode => true,
            else => false,
        },
    };
}

fn provenanceListEqual(
    left: *const corpus.ProvenanceList,
    right: *const corpus.ProvenanceList,
) bool {
    if (left.count != right.count) return false;
    return std.mem.eql(corpus.Provenance, left.slice(), right.slice());
}
