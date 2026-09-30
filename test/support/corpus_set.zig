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

const Filters = struct {
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
        hasher.update(&[_]u8{@intFromEnum(provenance)});
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
        @intFromEnum(function.result.oracleLayout()))
    {
        return false;
    }
    if (@as(u32, @intCast(signature.structure_kind)) !=
        @intFromEnum(function.result.oracleStructureKind()))
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
    return actual.kind == @intFromEnum(expected.kind) and
        actual.value_bits == expected.value_bits and
        actual.format.code == @intFromEnum(expected.format.code) and
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
