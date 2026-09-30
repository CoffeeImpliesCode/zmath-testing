//! Typed scalar corpus producer.
//!
//! `zmath-testing-corpus-producer <out_root> [--operation=OP] [--format=FMT]`
//! publishes the whole selection into `<out_root>/generated`. With a filter it
//! writes to `<out_root>/generated/probes/<op>-<fmt>` instead, which is a
//! debugging path and never a publication path.
//!
//! A full publication is one process evaluating one descriptor at a time, so
//! it costs one core times the whole corpus. `--shard=<i>/<n>` cuts the SAME
//! selection into `n` descriptor-complete parts that independent workers
//! produce in parallel, and `--assemble=<n>` joins them back into a
//! publication. Nothing else changes: not the record format, not the codec,
//! not a schema form, not what a record is.
//!
//! ## Why a merge can be exact
//!
//! Every published byte is a function of exactly one descriptor:
//!
//! - a record file is written by one descriptor's campaign and validated
//!   record by record inside that descriptor, so a partition boundary cannot
//!   change its bytes, its count, or its order;
//! - a metadata row is a pure function of the manifest entry, the campaign
//!   definition, and the artifact path;
//! - the header, the descriptor digest, and therefore `COMPLETE` are computed
//!   from the WHOLE selection, so the assembler regenerates them from the
//!   manifest instead of copying one worker's claim about them.
//!
//! The only shard-dependent bytes in a row are the `artifact=` field's
//! directory prefix, and the assembler rewrites exactly that prefix against the
//! file name the manifest says the descriptor owns. Rows are then emitted in
//! ascending signature order, which is the order an unmerged run writes them
//! in, so the assembled `metadata.txt` and `COMPLETE` are byte-identical to an
//! unmerged run's. The test "assembled shards reproduce an unmerged publication
//! byte for byte" is that claim, executed.
//!
//! ## Fail-closed rules
//!
//! - A shard writes `SHARD`, never `COMPLETE`, so no shard directory can be
//!   mistaken for a publication.
//! - An assemble refuses unless all `n` shard directories are present, each
//!   carries `SHARD`, carries no `.incomplete`, and records a
//!   `shard_plan_sha256` equal to the plan the assembler recomputes from the
//!   manifest in hand, the profile, the filters, the shard index, and the shard
//!   count. A manifest that grew, a profile that changed, a different filter, a
//!   different shard count, and a different partition each change that digest,
//!   so a stale plan is detected instead of accepted.
//! - Every shard's row digest, row order, artifact path, and artifact file
//!   digest are checked BEFORE the destination is touched, and each record
//!   file is re-hashed while it is copied. A merge that stops halfway leaves
//!   `.incomplete` and no `COMPLETE`.
//! - An assemble never enters a directory that already holds a completed
//!   publication, because a merge starts by deleting `metadata.txt` and
//!   `COMPLETE` and would destroy what it was asked to reproduce.
//!
//! ## Cluster procedure
//!
//! 1. Build the qualified producer once and keep that binary for the whole
//!    campaign. The manifest is compiled into it, so a worker built from a
//!    different manifest is a different producer.
//!
//!    ```text
//!    zig build oracle-generator -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
//!    ```
//!
//! 2. Count the descriptors the selection will contain and choose a shard
//!    count. `N` must not exceed that count, because an empty shard is refused
//!    rather than published as a hole:
//!
//!    ```text
//!    N=$(grep -c '^\[\[function\]\]' test/corpus/manifest.toml)
//!    ```
//!
//! 3. Launch one job per shard, each on its own machine, all writing under the
//!    same output root and with the same filters:
//!
//!    ```text
//!    zmath-testing-corpus-producer "$SCRATCH" --shard="$i/$N"
//!    ```
//!
//!    A shard is restartable: it owns its directory, deletes its own `SHARD`
//!    and row file before writing, and leaves `.incomplete` behind if it dies.
//!    Re-running the same command is always safe. A finished shard is
//!    independently checkable without this tool: it has `SHARD` and no
//!    `.incomplete`.
//!
//! 4. Detect a failed shard: a job is good when its directory holds `SHARD`
//!    and no `.incomplete`. Relaunch a job that exits non-zero or that leaves
//!    `.incomplete`. Never assemble around one.
//!
//! 5. Assemble on one machine that can see every shard directory, into a
//!    destination that holds no publication yet:
//!
//!    ```text
//!    zmath-testing-corpus-producer "$SCRATCH" --assemble="$N"
//!    ```
//!
//! 6. Verify the assembled publication. Run the unmerged reference in the SAME
//!    output root the merge will write into, and copy its metadata and marker
//!    aside first: a publication names its own records directory in every
//!    metadata row, so two different roots produce two different and equally
//!    valid publications, and only a shared root makes the comparison a
//!    literal one.
//!
//!    ```text
//!    zmath-testing-corpus-producer "$SCRATCH"
//!    cp "$SCRATCH/generated/metadata.txt" "$REF/metadata.txt"
//!    cp "$SCRATCH/generated/COMPLETE" "$REF/COMPLETE"
//!    cp -r "$SCRATCH/generated/records" "$REF/records"
//!    rm -rf "$SCRATCH/generated"
//!
//!    for i in $(seq 0 $((N-1))); do
//!        zmath-testing-corpus-producer "$SCRATCH" --shard="$i/$N"
//!    done
//!    zmath-testing-corpus-producer "$SCRATCH" --assemble="$N"
//!
//!    cmp "$REF/metadata.txt" "$SCRATCH/generated/metadata.txt"
//!    cmp "$REF/COMPLETE" "$SCRATCH/generated/COMPLETE"
//!    diff -r "$REF/records" "$SCRATCH/generated/records"
//!    zmath-testing-corpus-replay "$SCRATCH"
//!    ```
//!
//!    The replay is the semantic gate: it re-derives the descriptor digest and
//!    re-checks every row and every record against the manifest. The merge only
//!    proves the bytes were carried intact. Pass the replay the same filter
//!    arguments the producer used when the publication was filtered.

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

// A metadata row is rendered through a 1 KiB `appendFormat` buffer plus its
// source fields, so no row can approach this bound. Scaling the shard row limit
// by the descriptor count beats a magic byte count that is wrong in both
// directions as the manifest grows.
const shard_row_bytes_max: usize = 2048;
const shard_marker_bytes_max: usize = 1024;
const shard_copy_buffer_bytes: usize = 64 * 1024;
const shard_plan_domain = "zmath-corpus-shard-plan";
const shard_plan_version: u64 = 1;
const shard_marker_first_line = "zmath-corpus-shard version=1";
const artifact_field_prefix = ";artifact=";

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

const ShardSpec = struct {
    index: usize = 0,
    count: usize = 1,
};

const Mode = union(enum) {
    publish,
    shard: ShardSpec,
    // Only `count` is meaningful here: an assembly is not a shard of itself.
    assemble: ShardSpec,
};

const ParsedArguments = struct {
    output_root: []const u8,
    filters: FilterOptions,
    mode: Mode = .publish,
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

// One shard of a selection, as slots into `Selection.indices`. Slots, not
// manifest indices, because a merge has to know which shard owns each position
// of the selection, and `Selection.indices` is ascending.
const ShardPlan = struct {
    spec: ShardSpec,
    slots: [campaigns.manifest_campaign_count]usize = undefined,
    count: usize = 0,
    work: u64 = 0,
};

const ShardMarker = struct {
    index: usize,
    count: usize,
    selection_count: usize,
    descriptor_count: usize,
    record_count: u64,
    rows_digest: Digest,
    publication_digest: Digest,
    plan_digest: Digest,
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
            const probe_name = try probeName(allocator, arguments.filters);
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

// The one name a probe path and a shard path share, so a filter names both
// the same way and an unfiltered run says `all-all` instead of guessing.
fn probeName(allocator: std.mem.Allocator, filters: FilterOptions) ![]u8 {
    if (filters.operation == null and filters.format == null) {
        return allocator.dupe(u8, "all-all");
    }
    const operation_name = filters.operation orelse "all";
    const format_name = if (filters.format) |format| @tagName(format) else "all";
    return std.fmt.allocPrint(
        allocator,
        "{s}-{s}",
        .{ operation_name, format_name },
    );
}

// One descriptor's records reach the artifact in the canonical record order,
// and a campaign is free to visit its tuples in whatever order its own
// reasoning reads best. Two cases, and the second one is rare on purpose.
//
// A campaign that walks a domain already visits its tuples in the canonical
// order. It keeps one record back and publishes it as soon as the pair it
// forms with the record after it is known to be in order, then publishes the
// record it is holding at the end. That is the streaming this path already
// did, in two `encoded_record_capacity` buffers of state where it used one,
// and it writes the same bytes.
//
// The first pair the canonical order refuses means the campaign is visiting
// tuples in an order of its own, which is what a hand-written case list is.
// From that record on, every record is held, the one held back before the
// inversion included, and the held run is sorted before it is published. The
// validator is not relaxed to accept the campaign's order; the campaign is
// brought to the order the validator already enforces.
const RecordContext = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    record_hasher: std.crypto.hash.sha2.Sha256,
    // The record held back, and the last record published. Bytes, not decoded
    // records: a decoded record borrows its operation name from the frame it
    // came from, and each of these frames is overwritten by a later record.
    // A zero length is the empty frame, so no separate flag says "none yet".
    held_back_encoded: [encoded_record_capacity]u8 = undefined,
    held_back_length: usize = 0,
    published_encoded: [encoded_record_capacity]u8 = undefined,
    published_length: usize = 0,
    // The run that arrived out of order, oldest record first. Empty, and so
    // unallocated, until the first inversion.
    held: std.ArrayList(u8) = .empty,
    held_offsets: std.ArrayList(u32) = .empty,
    holding: bool = false,
    record_count: u64 = 0,

    fn deinit(self: *RecordContext) void {
        self.held.deinit(self.allocator);
        self.held_offsets.deinit(self.allocator);
    }
};

// A record frame carries its own length in the same nine leading bytes the
// reader trusts, so a held record is its own extent and no second length array
// is needed to find the next one.
fn heldRecord(context: *const RecordContext, start: u32) []const u8 {
    const bytes = context.held.items[start..];
    const length: usize = std.mem.readInt(u32, bytes[5..9], .little);
    return bytes[0..length];
}

fn hold(context: *RecordContext, bytes: []const u8) !void {
    const offset = std.math.cast(u32, context.held.items.len) orelse
        return error.RecordCountOverflow;
    try context.held_offsets.append(context.allocator, offset);
    try context.held.appendSlice(context.allocator, bytes);
}

fn publishRecord(context: *RecordContext, bytes: []const u8) !void {
    if (bytes.len > context.published_encoded.len) return error.RecordEncoding;
    try context.writer.writeAll(bytes);
    context.record_hasher.update(bytes);
    @memcpy(context.published_encoded[0..bytes.len], bytes);
    context.published_length = bytes.len;
}

const HeldRecordOrder = struct {
    context: *const RecordContext,

    fn lessThan(self: HeldRecordOrder, left: u32, right: u32) bool {
        // Every held slice came out of `encodeCorpusRecord` and was decoded
        // successfully by `appendRecord` on its way in, so a decode failure here
        // would mean the held run itself was corrupted. Reaching it stops the
        // publication instead of guessing an order.
        const left_record = corpus.decodeCorpusRecord(heldRecord(self.context, left)) catch
            return false;
        const right_record = corpus.decodeCorpusRecord(heldRecord(self.context, right)) catch
            return false;
        return corpus.compareCorpusRecords(&left_record, &right_record) == .lt;
    }
};

// The held run is sorted, then walked once. The walk starts from the last
// record already published, because sorting can move the run's smallest record
// in front of it, and it re-checks every adjacent pair, so a duplicate the
// campaign produced is still refused rather than sorted away.
fn publishHeldRun(context: *RecordContext) !void {
    std.sort.block(
        u32,
        context.held_offsets.items,
        HeldRecordOrder{ .context = context },
        HeldRecordOrder.lessThan,
    );
    var previous: ?corpus.CorpusRecord = if (context.published_length == 0)
        null
    else
        try corpus.decodeCorpusRecord(context.published_encoded[0..context.published_length]);
    for (context.held_offsets.items) |start| {
        const bytes = heldRecord(context, start);
        const current = try corpus.decodeCorpusRecord(bytes);
        if (previous) |*prior| try corpus.validateCorpusRecordOrder(prior, &current);
        try publishRecord(context, bytes);
        previous = current;
    }
}

// Close the descriptor. A campaign that ran in the canonical order leaves one
// record held back and nothing held; a campaign that did not leaves the whole
// out-of-order run in `held`.
fn finishRecords(context: *RecordContext) !void {
    if (context.holding) return publishHeldRun(context);
    if (context.held_back_length != 0) {
        try publishRecord(context, context.held_back_encoded[0..context.held_back_length]);
    }
}

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

// A shard lives outside the publication root, under `<out>/shards/`, so a
// merge can never find a shard directory inside the publication it is
// building, and so a finished publication carries no multi-gigabyte shard
// tree with it.
const ShardPaths = struct {
    run_root: []u8,
    records_root: []u8,
    rows_path: []u8,
    incomplete_marker: []u8,
    shard_marker: []u8,

    fn init(allocator: std.mem.Allocator, arguments: ParsedArguments) !ShardPaths {
        const spec = switch (arguments.mode) {
            .shard => |shard| shard,
            else => return error.InvalidArguments,
        };
        const key = try probeName(allocator, arguments.filters);
        defer allocator.free(key);
        const base = try std.fs.path.join(
            allocator,
            &.{ arguments.output_root, "shards", key },
        );
        defer allocator.free(base);
        const leaf = try std.fmt.allocPrint(
            allocator,
            "{d}-of-{d}",
            .{ spec.index, spec.count },
        );
        defer allocator.free(leaf);
        const run_root = try std.fs.path.join(allocator, &.{ base, leaf });
        errdefer allocator.free(run_root);
        const records_root = try std.fs.path.join(allocator, &.{ run_root, "records" });
        errdefer allocator.free(records_root);
        const rows_path = try std.fs.path.join(allocator, &.{ run_root, "metadata.rows" });
        errdefer allocator.free(rows_path);
        const incomplete_marker = try std.fs.path.join(allocator, &.{ run_root, ".incomplete" });
        errdefer allocator.free(incomplete_marker);
        const shard_marker = try std.fs.path.join(allocator, &.{ run_root, "SHARD" });
        errdefer allocator.free(shard_marker);
        return .{
            .run_root = run_root,
            .records_root = records_root,
            .rows_path = rows_path,
            .incomplete_marker = incomplete_marker,
            .shard_marker = shard_marker,
        };
    }

    fn deinit(self: *ShardPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.run_root);
        allocator.free(self.records_root);
        allocator.free(self.rows_path);
        allocator.free(self.incomplete_marker);
        allocator.free(self.shard_marker);
        self.* = undefined;
    }
};

// The same durable-publication order as `Publication`, with one difference a
// merge depends on: a shard completes with `SHARD`, never `COMPLETE`, so no
// reader can mistake a shard directory for a publication and no partial merge
// can be mistaken for one either.
const ShardRun = struct {
    io: std.Io,
    root_dir: std.Io.Dir,
    paths: *const ShardPaths,

    fn begin(self: *const ShardRun) !void {
        try self.root_dir.createDirPath(self.io, self.paths.run_root);
        try self.root_dir.createDirPath(self.io, self.paths.records_root);
        try deleteIfPresent(self.io, self.root_dir, self.paths.shard_marker);
        try deleteIfPresent(self.io, self.root_dir, self.paths.rows_path);
        try writeAtomicSynced(
            self.io,
            self.root_dir,
            self.paths.incomplete_marker,
            "oracle-generate shard started\n",
        );
    }

    fn finish(self: *const ShardRun, rows: []const u8, marker: []const u8) !void {
        try writeAtomicSynced(self.io, self.root_dir, self.paths.rows_path, rows);
        try deleteIfPresent(self.io, self.root_dir, self.paths.incomplete_marker);
        try writeAtomicSynced(self.io, self.root_dir, self.paths.shard_marker, marker);
    }
};

const LoadedShard = struct {
    paths: ShardPaths,
    rows: []u8,
    record_count: u64,
    descriptor_count: usize,

    fn deinit(self: *LoadedShard, allocator: std.mem.Allocator) void {
        self.paths.deinit(allocator);
        allocator.free(self.rows);
        self.* = undefined;
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

    switch (parsed.mode) {
        .publish => try publishCorpus(options, parsed, &matrix, selection),
        .shard => |spec| try generateShard(options, parsed, &matrix, selection, spec),
        .assemble => |spec| try assemblePublication(options, parsed, &matrix, selection, spec),
    }
}

fn publishCorpus(
    options: GeneratorOptions,
    parsed: ParsedArguments,
    matrix: *const campaigns.CampaignMatrix,
    selection: Selection,
) !void {
    var paths = try OutputPaths.init(options.allocator, parsed);
    defer paths.deinit(options.allocator);
    const publication: Publication = .{
        .io = options.io,
        .root_dir = options.root_dir,
        .paths = &paths,
    };
    try publication.begin();

    const descriptor_hash = try descriptorProfileHash(options.profile, matrix, selection);
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
        _ = try generateDefinition(
            options.allocator,
            options.io,
            options.root_dir,
            &metadata,
            paths.records_root,
            index,
            definition,
        );
    }

    var metadata_digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(metadata.items, &metadata_digest, .{});
    try publication.finish(metadata.items, metadata_digest);
}

// A shard is this selection cut on descriptor boundaries, written into its own
// directory under its own marker. It writes rows without a header, because the
// header, the descriptor digest, and the completion digest are properties of
// the WHOLE selection: the merge recomputes them from the manifest instead of
// trusting one worker's copy of them.
fn generateShard(
    options: GeneratorOptions,
    parsed: ParsedArguments,
    matrix: *const campaigns.CampaignMatrix,
    selection: Selection,
    spec: ShardSpec,
) !void {
    const plan = try planShard(matrix, selection, spec);
    var paths = try ShardPaths.init(options.allocator, parsed);
    defer paths.deinit(options.allocator);
    const run: ShardRun = .{
        .io = options.io,
        .root_dir = options.root_dir,
        .paths = &paths,
    };
    try run.begin();

    const publication_digest = try descriptorProfileHash(options.profile, matrix, selection);
    const plan_digest = try shardPlanDigest(
        options.profile,
        matrix,
        selection,
        plan,
        publication_digest,
        parsed.filters,
    );
    var rows: std.ArrayList(u8) = .empty;
    defer rows.deinit(options.allocator);
    var record_count: u64 = 0;
    for (plan.slots[0..plan.count]) |slot| {
        const index = selection.indices[slot];
        const definition = matrix.at(index) orelse return error.ManifestCountMismatch;
        record_count += try generateDefinition(
            options.allocator,
            options.io,
            options.root_dir,
            &rows,
            paths.records_root,
            index,
            definition,
        );
    }
    // The plan weights each descriptor by the record count it publishes, so a
    // disagreement here is a manifest or campaign-table fault. It must not
    // reach a merge as a plan an assembler would accept.
    if (record_count != plan.work) return error.ShardWorkMismatch;

    var marker: std.ArrayList(u8) = .empty;
    defer marker.deinit(options.allocator);
    try appendShardMarker(
        options.allocator,
        &marker,
        plan,
        selection.count,
        record_count,
        rowsDigest(rows.items),
        publication_digest,
        plan_digest,
    );
    try run.finish(rows.items, marker.items);
}

// The merge is mechanical and it is strict. It reads every shard, proves each
// one against the manifest in hand, copies every record file while re-hashing
// it, and only then writes the publication. A shard boundary cannot change a
// record, a row order, a signature, or a digest, so the result is the same
// bytes an unmerged run would have written; `test "assembled shards reproduce
// an unmerged publication byte for byte"` is that claim in bytes.
fn assemblePublication(
    options: GeneratorOptions,
    parsed: ParsedArguments,
    matrix: *const campaigns.CampaignMatrix,
    selection: Selection,
    spec: ShardSpec,
) !void {
    if (spec.count == 0) return error.InvalidShardCount;
    if (spec.count > selection.count) return error.InvalidShardCount;

    var paths = try OutputPaths.init(options.allocator, parsed);
    defer paths.deinit(options.allocator);
    const publication_digest = try descriptorProfileHash(options.profile, matrix, selection);

    // Nothing is written until every shard is present, complete, and built
    // from this manifest. A merge that discovers a missing shard after it has
    // started copying has already produced the partial publication this
    // publication path exists to prevent.
    var load = try ShardLoad.init(options.allocator, selection.count);
    defer load.deinit();
    for (load.row_of_slot) |*row| row.* = null;
    for (0..spec.count) |shard_index| {
        try load.read(options, parsed, matrix, selection, .{
            .index = shard_index,
            .count = spec.count,
        }, publication_digest);
    }
    for (load.row_of_slot) |row| {
        if (row == null) {
            std.debug.print(
                "the {d} shards do not cover the {d} selected descriptors\n",
                .{ spec.count, selection.count },
            );
            return error.IncompleteShardCoverage;
        }
    }

    try clearAbortedAssemble(options.allocator, options.io, options.root_dir, &paths);
    const publication: Publication = .{
        .io = options.io,
        .root_dir = options.root_dir,
        .paths = &paths,
    };
    try publication.begin();
    var metadata: std.ArrayList(u8) = .empty;
    defer metadata.deinit(options.allocator);
    try appendMetadataHeader(
        options.allocator,
        &metadata,
        options.profile,
        parsed,
        selection,
        publication_digest,
    );
    var rewritten: std.ArrayList(u8) = .empty;
    defer rewritten.deinit(options.allocator);
    for (selection.indices[0..selection.count], 0..) |index, slot| {
        const definition = matrix.at(index) orelse return error.ManifestCountMismatch;
        const shard = load.at(slot);
        const shard_row = load.row_of_slot[slot] orelse return error.IncompleteShardCoverage;
        const name = try artifactFileName(options.allocator, index, definition.function.op);
        defer options.allocator.free(name);
        const shard_field = try artifactField(options.allocator, shard.paths.records_root, name);
        defer options.allocator.free(shard_field);
        const publication_field = try artifactField(options.allocator, paths.records_root, name);
        defer options.allocator.free(publication_field);
        rewritten.clearRetainingCapacity();
        try rewriteRow(
            options.allocator,
            &rewritten,
            shard_row,
            shard_field,
            publication_field,
        );
        try metadata.appendSlice(options.allocator, rewritten.items);
        try metadata.append(options.allocator, '\n');

        const expected = rowArtifactDigest(shard_row) orelse return error.ShardRowMalformed;
        const source = try generatedArtifactPath(
            options.allocator,
            shard.paths.records_root,
            index,
            definition.function.op,
        );
        defer options.allocator.free(source);
        const destination = try generatedArtifactPath(
            options.allocator,
            paths.records_root,
            index,
            definition.function.op,
        );
        defer options.allocator.free(destination);
        const copied = try copyVerified(options.io, options.root_dir, source, destination);
        if (!std.mem.eql(u8, &expected, &copied)) {
            std.debug.print(
                "record {d} does not match the digest in its own metadata row: {s}\n",
                .{ index, source },
            );
            return error.ArtifactDigestMismatch;
        }
    }
    try requireExactEntries(options.allocator, options.io, options.root_dir, &paths, selection.count);
    var metadata_digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(metadata.items, &metadata_digest, .{});
    try publication.finish(metadata.items, metadata_digest);
}

// Longest-processing-time first over published record counts, ties broken by
// ascending selection slot. It is not a load estimate: it is a pure function
// of the manifest, so a worker and an assembler compute the same partition
// without exchanging anything. Equal-count blocks would leave one worker
// holding every expensive descriptor while another holds none.
fn planShard(
    matrix: *const campaigns.CampaignMatrix,
    selection: Selection,
    spec: ShardSpec,
) !ShardPlan {
    if (spec.count == 0) return error.InvalidShardCount;
    if (spec.index >= spec.count) return error.InvalidShardIndex;
    // An empty shard is always a mistake, and allowing one would let a
    // scheduler publish a selection that no shard claimed.
    if (spec.count > selection.count) return error.InvalidShardCount;

    var plan: ShardPlan = .{ .spec = spec };
    var order: [campaigns.manifest_campaign_count]usize = undefined;
    var work: [campaigns.manifest_campaign_count]u64 = undefined;
    var load: [campaigns.manifest_campaign_count]u64 = undefined;
    @memset(load[0..spec.count], 0);
    for (selection.indices[0..selection.count], 0..) |index, slot| {
        order[slot] = slot;
        work[slot] = shardWorkWeight(matrix.at(index) orelse return error.ManifestCountMismatch);
    }
    std.sort.insertion(usize, order[0..selection.count], work[0..selection.count], heavierFirst);
    for (order[0..selection.count]) |slot| {
        var target: usize = 0;
        for (1..spec.count) |candidate| {
            if (load[candidate] < load[target]) target = candidate;
        }
        load[target] += work[slot];
        if (target != spec.index) continue;
        plan.slots[plan.count] = slot;
        plan.count += 1;
        plan.work += work[slot];
    }
    // The partition is a set, and both a worker and the merge read it in
    // selection order, so a shard's own rows stay ascending and reproducible.
    std.sort.insertion(usize, plan.slots[0..plan.count], {}, std.sort.asc(usize));
    return plan;
}

fn heavierFirst(work: []u64, lhs: usize, rhs: usize) bool {
    if (work[lhs] != work[rhs]) return work[lhs] > work[rhs];
    return lhs < rhs;
}

// The record count one descriptor will publish. A descriptor whose campaign is
// unavailable emits nothing, and this is a manifest fact in both processes, so
// the partition never depends on a generated artifact.
fn shardWorkWeight(definition: *const campaigns.CampaignDefinition) u64 {
    if (!campaignEvidenceAvailable(definition)) return 0;
    return definition.cardinality() catch 0;
}

// A shard's identity. It covers the profile, the filters, the shard index and
// count, the whole selection's descriptor digest, and the exact descriptors
// this shard claims, so a manifest edit, a profile change, a different filter,
// a different shard count, or a different partition each change it. A worker
// and an assembler that disagree anywhere here cannot merge.
fn shardPlanDigest(
    profile: GeneratorProfile,
    matrix: *const campaigns.CampaignMatrix,
    selection: Selection,
    plan: ShardPlan,
    publication_digest: Digest,
    filters: FilterOptions,
) !Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(shard_plan_domain);
    hasher.update(&[_]u8{0});
    hashU64(&hasher, shard_plan_version);
    hasher.update(profile.target);
    hasher.update(&[_]u8{0});
    hasher.update(profile.cpu);
    hasher.update(&[_]u8{0});
    hasher.update(profile.mode);
    hasher.update(&[_]u8{0});
    hasher.update(filters.operation orelse "all");
    hasher.update(&[_]u8{0});
    hasher.update(if (filters.format) |format| @tagName(format) else "all");
    hasher.update(&[_]u8{0});
    hashU64(&hasher, plan.spec.index);
    hashU64(&hasher, plan.spec.count);
    hashU64(&hasher, selection.count);
    hashU64(&hasher, plan.count);
    hashU64(&hasher, plan.work);
    hasher.update(&publication_digest);
    for (plan.slots[0..plan.count]) |slot| {
        const index = selection.indices[slot];
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

// A shard marker is a fixed, ordered record. It names the shard, the selection
// it was cut from, the rows and record count it wrote, the publication digest
// it was built against, and the plan it computed, so an assembler can reject
// the shard before it trusts a single row.
fn appendShardMarker(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    plan: ShardPlan,
    selection_count: usize,
    record_count: u64,
    rows_digest: Digest,
    publication_digest: Digest,
    plan_digest: Digest,
) !void {
    try appendFormat("{s}\n", allocator, output, .{shard_marker_first_line});
    try appendFormat(
        "shard_index={d}\nshard_count={d}\n",
        allocator,
        output,
        .{ plan.spec.index, plan.spec.count },
    );
    try appendFormat(
        "selection_count={d}\nshard_descriptor_count={d}\nshard_record_count={d}\n",
        allocator,
        output,
        .{ selection_count, plan.count, record_count },
    );
    try appendDigestLine(allocator, output, "shard_rows_sha256", rows_digest);
    try appendDigestLine(allocator, output, "publication_descriptor_sha256", publication_digest);
    try appendDigestLine(allocator, output, "shard_plan_sha256", plan_digest);
}

fn parseShardMarker(source: []const u8) !ShardMarker {
    if (source.len == 0 or source[source.len - 1] != '\n') return error.InvalidShardMarker;
    var lines = std.mem.splitScalar(u8, source[0 .. source.len - 1], '\n');
    const first = lines.next() orelse return error.InvalidShardMarker;
    if (!std.mem.eql(u8, first, shard_marker_first_line)) {
        return error.InvalidShardMarker;
    }
    const marker: ShardMarker = .{
        .index = try markerCount(&lines, "shard_index"),
        .count = try markerCount(&lines, "shard_count"),
        .selection_count = try markerCount(&lines, "selection_count"),
        .descriptor_count = try markerCount(&lines, "shard_descriptor_count"),
        .record_count = @intCast(try markerCount(&lines, "shard_record_count")),
        .rows_digest = try markerDigest(&lines, "shard_rows_sha256"),
        .publication_digest = try markerDigest(&lines, "publication_descriptor_sha256"),
        .plan_digest = try markerDigest(&lines, "shard_plan_sha256"),
    };
    if (lines.next() != null) return error.InvalidShardMarker;
    return marker;
}

fn markerCount(lines: anytype, name: []const u8) !usize {
    return parseCanonicalCount(try takeMarkerValue(lines, name)) orelse
        error.InvalidShardMarker;
}

fn markerDigest(lines: anytype, name: []const u8) !Digest {
    return parseDigestHex(try takeMarkerValue(lines, name)) orelse
        error.InvalidShardMarker;
}

fn takeMarkerValue(lines: anytype, name: []const u8) ![]const u8 {
    const text = lines.next() orelse return error.InvalidShardMarker;
    if (!std.mem.startsWith(u8, text, name)) return error.InvalidShardMarker;
    if (text.len <= name.len or text[name.len] != '=') return error.InvalidShardMarker;
    return text[name.len + 1 ..];
}

fn rowsDigest(rows: []const u8) Digest {
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(rows, &digest, .{});
    return digest;
}

fn parseDigestHex(text: []const u8) ?Digest {
    if (text.len != @sizeOf(Digest) * 2) return null;
    var digest: Digest = undefined;
    _ = std.fmt.hexToBytes(&digest, text) catch return null;
    return digest;
}

fn readShardFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    path: []const u8,
    limit: usize,
    spec: ShardSpec,
) ![]u8 {
    return root_dir.readFileAlloc(io, path, allocator, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print(
                "shard {d} of {d} is missing: {s}\n",
                .{ spec.index, spec.count, path },
            );
            return error.MissingShard;
        },
        else => return err,
    };
}

const ShardLoad = struct {
    allocator: std.mem.Allocator,
    shards: std.ArrayList(LoadedShard),
    owner: []usize,
    row_of_slot: []?[]const u8,

    // Both slot tables are sized by the selection, not by the shard count, so
    // they are large buffers. They are allocated in one scope that owns the
    // window in which they exist: if the second allocation fails, the first is
    // freed by its `errdefer` instead of being orphaned by a struct literal
    // that never completed. On success both are handed to the caller, which is
    // from then on the only owner and frees them through `deinit`.
    fn init(allocator: std.mem.Allocator, count: usize) !ShardLoad {
        const owner = try allocator.alloc(usize, count);
        errdefer allocator.free(owner);
        const row_of_slot = try allocator.alloc(?[]const u8, count);
        errdefer allocator.free(row_of_slot);
        return .{
            .allocator = allocator,
            .shards = .empty,
            .owner = owner,
            .row_of_slot = row_of_slot,
        };
    }

    fn deinit(self: *ShardLoad) void {
        for (self.shards.items) |*shard| shard.deinit(self.allocator);
        self.shards.deinit(self.allocator);
        self.allocator.free(self.owner);
        self.allocator.free(self.row_of_slot);
        self.* = undefined;
    }

    fn at(self: *const ShardLoad, slot: usize) *const LoadedShard {
        return &self.shards.items[self.owner[slot]];
    }

    // Reads one shard, proves it is the shard the manifest in hand asks for,
    // and publishes its rows into `row_of_slot`. It writes nothing, so a
    // rejection here costs no publication.
    fn read(
        self: *ShardLoad,
        options: GeneratorOptions,
        parsed: ParsedArguments,
        matrix: *const campaigns.CampaignMatrix,
        selection: Selection,
        spec: ShardSpec,
        publication_digest: Digest,
    ) !void {
        const allocator = self.allocator;
        var arguments = parsed;
        arguments.mode = .{ .shard = spec };
        const plan = try planShard(matrix, selection, spec);
        var paths = try ShardPaths.init(allocator, arguments);
        errdefer paths.deinit(allocator);

        if (try pathExists(options.io, options.root_dir, paths.incomplete_marker)) {
            std.debug.print(
                "shard {d} of {d} was interrupted and is not a shard: {s}\n",
                .{ spec.index, spec.count, paths.incomplete_marker },
            );
            return error.ShardIncomplete;
        }
        const marker_source = try readShardFile(
            allocator,
            options.io,
            options.root_dir,
            paths.shard_marker,
            shard_marker_bytes_max,
            spec,
        );
        defer allocator.free(marker_source);
        const marker = try parseShardMarker(marker_source);
        if (marker.index != spec.index) return error.ShardIndexMismatch;
        if (marker.count != spec.count) {
            std.debug.print(
                "shard {d} was produced for {d} shards, not {d}\n",
                .{ spec.index, marker.count, spec.count },
            );
            return error.ShardCountMismatch;
        }
        if (marker.selection_count != selection.count) {
            std.debug.print(
                "shard {d} of {d} was cut from {d} selected descriptors, not {d}\n",
                .{ spec.index, spec.count, marker.selection_count, selection.count },
            );
            return error.ShardSelectionMismatch;
        }
        if (!std.mem.eql(u8, &marker.publication_digest, &publication_digest)) {
            std.debug.print(
                "shard {d} of {d} was produced from a different manifest, profile, or filter\n",
                .{ spec.index, spec.count },
            );
            return error.ShardDescriptorDigestMismatch;
        }
        if (marker.descriptor_count != plan.count) return error.ShardDescriptorCountMismatch;
        if (marker.record_count != plan.work) return error.ShardRecordCountMismatch;
        const plan_digest = try shardPlanDigest(
            options.profile,
            matrix,
            selection,
            plan,
            publication_digest,
            parsed.filters,
        );
        if (!std.mem.eql(u8, &marker.plan_digest, &plan_digest)) {
            std.debug.print(
                "shard {d} of {d} does not hold the partition this manifest asks for\n",
                .{ spec.index, spec.count },
            );
            return error.ShardPlanMismatch;
        }

        const rows = try readShardFile(
            allocator,
            options.io,
            options.root_dir,
            paths.rows_path,
            selection.count * shard_row_bytes_max,
            spec,
        );
        errdefer allocator.free(rows);
        if (rows.len == 0 or rows[rows.len - 1] != '\n') return error.ShardRowsMalformed;
        if (!std.mem.eql(u8, &marker.rows_digest, &rowsDigest(rows))) {
            return error.ShardRowsDigestMismatch;
        }

        var record_count: u64 = 0;
        var lines = std.mem.splitScalar(u8, rows[0 .. rows.len - 1], '\n');
        for (plan.slots[0..plan.count]) |slot| {
            const index = selection.indices[slot];
            const definition = matrix.at(index) orelse return error.ManifestCountMismatch;
            const row = lines.next() orelse return error.ShardRowCountMismatch;
            if ((rowSignatureIndex(row) orelse return error.ShardRowMalformed) != index) {
                return error.ShardRowOrderMismatch;
            }
            const name = try artifactFileName(allocator, index, definition.function.op);
            defer allocator.free(name);
            const field = try artifactField(allocator, paths.records_root, name);
            defer allocator.free(field);
            if (std.mem.indexOf(u8, row, field) == null) return error.ShardRowArtifactMismatch;
            record_count += rowRecordCount(row) orelse return error.ShardRowMalformed;
            self.owner[slot] = spec.index;
            self.row_of_slot[slot] = row;
        }
        if (lines.next() != null) return error.ShardRowCountMismatch;
        if (record_count != marker.record_count) return error.ShardRecordCountMismatch;
        try self.shards.append(allocator, .{
            .paths = paths,
            .rows = rows,
            .record_count = record_count,
            .descriptor_count = plan.count,
        });
    }
};

// The only destination a merge may enter is one its own aborted run left
// behind: absent, or carrying this tool's `.incomplete`. A published
// publication is never a merge target, because a merge that starts by deleting
// `metadata.txt` and `COMPLETE` has already destroyed the publication it was
// asked to reproduce.
fn clearAbortedAssemble(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    paths: *const OutputPaths,
) !void {
    if (try pathExists(io, root_dir, paths.complete_marker)) {
        std.debug.print(
            "{s} already holds a completed publication\n",
            .{paths.run_root},
        );
        return error.DestinationAlreadyPublished;
    }
    if (!try pathExists(io, root_dir, paths.run_root)) return;
    if (!try pathExists(io, root_dir, paths.incomplete_marker)) {
        std.debug.print(
            "{s} is not empty and carries no .incomplete marker\n",
            .{paths.run_root},
        );
        return error.DestinationNotEmpty;
    }
    // `deleteTree` treats an absent path as removed, so this clears whatever an
    // aborted merge left behind without caring whether it was there.
    try root_dir.deleteTree(io, paths.records_root);
    try root_dir.deleteTree(io, paths.metadata_path);
    var stray: std.ArrayList([]u8) = .empty;
    defer {
        for (stray.items) |name| allocator.free(name);
        stray.deinit(allocator);
    }
    var handle = try root_dir.openDir(io, paths.run_root, .{ .iterate = true });
    defer handle.close(io);
    var iterator = handle.iterate();
    while (try iterator.next(io)) |entry| {
        const owned = std.mem.eql(u8, entry.name, "records") or
            std.mem.eql(u8, entry.name, "metadata.txt") or
            std.mem.eql(u8, entry.name, ".incomplete");
        if (owned) continue;
        try stray.append(allocator, try allocator.dupe(u8, entry.name));
    }
    for (stray.items) |name| {
        const path = try std.fs.path.join(allocator, &.{ paths.run_root, name });
        defer allocator.free(path);
        try root_dir.deleteTree(io, path);
    }
}

// The publication root holds the publication and nothing else, checked before
// `finish` publishes it. At that moment the merge owns exactly two entries,
// the record tree it filled and the `.incomplete` marker it is running under,
// and `finish` adds `metadata.txt` and `COMPLETE` and touches nothing else. A
// leftover temporary or an unaccounted record file would be an artifact no
// descriptor claims, so it fails the merge instead of shipping.
fn requireExactEntries(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    paths: *const OutputPaths,
    expected_records: usize,
) !void {
    var marker_seen = false;
    var records_seen = false;
    var handle = try root_dir.openDir(io, paths.run_root, .{ .iterate = true });
    defer handle.close(io);
    var iterator = handle.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".incomplete")) {
            marker_seen = true;
        } else if (std.mem.eql(u8, entry.name, "records")) {
            records_seen = true;
        } else {
            std.debug.print(
                "{s} holds an unexpected entry: {s}\n",
                .{ paths.run_root, entry.name },
            );
            return error.DestinationNotEmpty;
        }
    }
    if (!marker_seen or !records_seen) return error.IncompletePublication;

    const records_path = try std.fs.path.join(allocator, &.{ paths.run_root, "records" });
    defer allocator.free(records_path);
    var records = try root_dir.openDir(io, records_path, .{ .iterate = true });
    defer records.close(io);
    var record_iterator = records.iterate();
    var seen: usize = 0;
    while (try record_iterator.next(io)) |_| seen += 1;
    if (seen != expected_records) {
        std.debug.print(
            "the publication holds {d} record files, not {d}\n",
            .{ seen, expected_records },
        );
        return error.IncompletePublication;
    }
}

// Copies a shard's record file into the publication and proves it arrived
// intact. The digest is the metadata row's own claim, so a merge that copied
// the wrong bytes, or a transfer that lost the tail of a file, cannot publish.
fn copyVerified(
    io: std.Io,
    root_dir: std.Io.Dir,
    source_path: []const u8,
    destination_path: []const u8,
) !Digest {
    const source = root_dir.openFile(io, source_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("a shard record is missing: {s}\n", .{source_path});
            return error.ArtifactMissing;
        },
        else => return err,
    };
    defer source.close(io);
    var atomic = try root_dir.createFileAtomic(io, destination_path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);
    var read_buffer: [shard_copy_buffer_bytes]u8 = undefined;
    var write_buffer: [shard_copy_buffer_bytes]u8 = undefined;
    var reader = source.reader(io, &read_buffer);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        // A short read is the end of the file, not an error, and a file with a
        // length of zero is a file with no records in it.
        const read = try reader.interface.readSliceShort(&write_buffer);
        if (read == 0) break;
        hasher.update(write_buffer[0..read]);
        try atomic.file.writeStreamingAll(io, write_buffer[0..read]);
    }
    try atomic.file.sync(io);
    var digest: Digest = undefined;
    hasher.final(&digest);
    try atomic.replace(io);
    return digest;
}

// The one place a merge rewrites a shard's bytes. It replaces the shard's
// record directory prefix with the publication's and nothing else, and it
// refuses unless that prefix occurs exactly once, so no row can carry a second
// artifact path past the check.
fn rewriteRow(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    row: []const u8,
    shard_field: []const u8,
    publication_field: []const u8,
) !void {
    const start = std.mem.indexOf(u8, row, shard_field) orelse {
        std.debug.print("a shard row does not name the shard's own artifact\n", .{});
        return error.ShardRowArtifactMismatch;
    };
    if (std.mem.indexOf(u8, row[start + shard_field.len ..], shard_field) != null) {
        return error.ShardRowArtifactMismatch;
    }
    try output.appendSlice(allocator, row[0..start]);
    try output.appendSlice(allocator, publication_field);
    try output.appendSlice(allocator, row[start + shard_field.len ..]);
}

fn artifactField(
    allocator: std.mem.Allocator,
    records_root: []const u8,
    name: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}{s}/{s};",
        .{ artifact_field_prefix, records_root, name },
    );
}

fn takeFieldValue(row: []const u8, field: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, row, field) orelse return null;
    const value = row[start + field.len ..];
    const end = std.mem.indexOfScalar(u8, value, ';') orelse return null;
    return value[0..end];
}

fn rowSignatureIndex(row: []const u8) ?usize {
    return parseCanonicalCount(takeFieldValue(row, "signature=") orelse return null);
}

fn rowRecordCount(row: []const u8) ?u64 {
    const value = takeFieldValue(row, ";records=") orelse return null;
    if (value.len == 0 or value.len > 20) return null;
    for (value) |byte| {
        if (byte < '0' or byte > '9') return null;
    }
    return std.fmt.parseInt(u64, value, 10) catch null;
}

fn rowArtifactDigest(row: []const u8) ?Digest {
    return parseDigestHex(takeFieldValue(row, ";artifact_sha256=") orelse return null);
}

fn pathExists(io: std.Io, dir: std.Io.Dir, path: []const u8) !bool {
    dir.access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
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
        } else if (std.mem.startsWith(u8, argument, "--shard=")) {
            try setMode(&parsed, .{ .shard = try parseShardSpec(argument["--shard=".len..]) });
        } else if (std.mem.startsWith(u8, argument, "--assemble=")) {
            const count = parseCanonicalCount(argument["--assemble=".len..]) orelse
                return error.InvalidShardCount;
            if (count == 0) return error.InvalidShardCount;
            try setMode(&parsed, .{ .assemble = .{ .index = 0, .count = count } });
        } else {
            return error.InvalidArguments;
        }
    }
    return parsed;
}

// One mode per run. A second mode is a contradiction, not a refinement: a
// scheduler that means to produce a shard must never silently publish, and a
// scheduler that means to merge must never silently generate.
fn setMode(parsed: *ParsedArguments, mode: Mode) !void {
    switch (parsed.mode) {
        .publish => parsed.mode = mode,
        else => return error.InvalidArguments,
    }
}

// `i/n`, both canonical decimals, with `i` inside the range. A padded, signed,
// or partial value is a mistake in a launch script, and a mistyped shard
// number must not become an empty shard.
fn parseShardSpec(text: []const u8) !ShardSpec {
    const separator = std.mem.indexOfScalar(u8, text, '/') orelse
        return error.InvalidShardSpec;
    if (std.mem.indexOfScalar(u8, text[separator + 1 ..], '/') != null) {
        return error.InvalidShardSpec;
    }
    const index = parseCanonicalCount(text[0..separator]) orelse
        return error.InvalidShardSpec;
    const count = parseCanonicalCount(text[separator + 1 ..]) orelse
        return error.InvalidShardSpec;
    if (count == 0) return error.InvalidShardCount;
    if (index >= count) return error.InvalidShardIndex;
    return .{ .index = index, .count = count };
}

fn parseCanonicalCount(text: []const u8) ?usize {
    if (text.len == 0 or text.len > 20) return null;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return null;
    }
    if (text.len > 1 and text[0] == '0') return null;
    return std.fmt.parseInt(usize, text, 10) catch null;
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
    records_root: []const u8,
    index: usize,
    definition: *const campaigns.CampaignDefinition,
) !u64 {
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
        records_root,
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
            .allocator = allocator,
            .writer = &writer.interface,
            .record_hasher = std.crypto.hash.sha2.Sha256.init(.{}),
        };
        defer context.deinit();
        try campaigns.visitDefinitionRecords(definition, &context, visitRecord);
        if (context.record_count != cardinality) return error.RecordCountMismatch;
        try finishRecords(&context);
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
    return record_count;
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
    try appendRecord(context, bytes);
}

// A campaign visits its tuples in its own order; the artifact stores them in
// the canonical record order. One record is held back, so a pair is decided
// before either of its records is published. A pair the canonical order accepts
// releases the older record. A pair it refuses does not: the run is held from
// the record held back, which is the one the sorted run may have to move
// behind, and `finishRecords` sorts it and re-checks every adjacent pair, so a
// duplicate the campaign produced is still refused rather than sorted away.
//
// Only bytes are kept, never a decoded record: a decoded record borrows its
// operation name from the frame it was decoded from, and both of those frames
// are overwritten by later records.
fn appendRecord(context: *RecordContext, bytes: []const u8) !void {
    context.record_count += 1;
    if (!context.holding and context.held_back_length != 0) {
        const previous = try corpus.decodeCorpusRecord(
            context.held_back_encoded[0..context.held_back_length],
        );
        const current = try corpus.decodeCorpusRecord(bytes);
        if (corpus.compareCorpusRecords(&previous, &current) == .lt) {
            try publishRecord(context, context.held_back_encoded[0..context.held_back_length]);
            try holdBack(context, bytes);
            return;
        }
        context.holding = true;
        try hold(context, context.held_back_encoded[0..context.held_back_length]);
    }
    if (context.holding) try hold(context, bytes);
    try holdBack(context, bytes);
}

fn holdBack(context: *RecordContext, bytes: []const u8) !void {
    if (bytes.len > context.held_back_encoded.len) return error.RecordEncoding;
    @memcpy(context.held_back_encoded[0..bytes.len], bytes);
    context.held_back_length = bytes.len;
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
    const name = try artifactFileName(allocator, index, operation);
    defer allocator.free(name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ records_root, name });
}

// The record file name a descriptor publishes under, in a shard directory and
// in a publication directory alike. A merge matches the name it expects
// against the name a shard claimed instead of trusting either.
fn artifactFileName(
    allocator: std.mem.Allocator,
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
        "{d:0>3}_{s}.zcdr",
        .{ index, operation },
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

// This test proves the shard arguments are total, and that a contradiction
// between them is a rejection rather than a second mode.
test "shard arguments are parsed fail closed" {
    const shard = try parseArguments(&[_][]const u8{ "corpus-generate", "out", "--shard=2/5" });
    try std.testing.expectEqual(Mode{ .shard = .{ .index = 2, .count = 5 } }, shard.mode);
    const assemble = try parseArguments(&[_][]const u8{ "corpus-generate", "out", "--assemble=5" });
    try std.testing.expectEqual(Mode{ .assemble = .{ .index = 0, .count = 5 } }, assemble.mode);
    const publication = try parseArguments(&[_][]const u8{ "corpus-generate", "out" });
    try std.testing.expectEqual(Mode.publish, publication.mode);

    const both = [_][]const u8{ "corpus-generate", "out", "--shard=0/2", "--assemble=2" };
    try std.testing.expectError(error.InvalidArguments, parseArguments(both[0..]));
    const last = [_][]const u8{ "corpus-generate", "out", "--assard=0/2" };
    try std.testing.expectError(error.InvalidArguments, parseArguments(last[0..]));
    const self_contradictory = [_][]const u8{ "corpus-generate", "out", "--shard=2/2" };
    try std.testing.expectError(error.InvalidShardIndex, parseArguments(self_contradictory[0..]));
    const reversed = [_][]const u8{ "corpus-generate", "out", "--shard=3/2" };
    try std.testing.expectError(error.InvalidShardIndex, parseArguments(reversed[0..]));
    const zero = [_][]const u8{ "corpus-generate", "out", "--shard=0/0" };
    try std.testing.expectError(error.InvalidShardCount, parseArguments(zero[0..]));
    const bare = [_][]const u8{ "corpus-generate", "out", "--shard=2" };
    try std.testing.expectError(error.InvalidShardSpec, parseArguments(bare[0..]));
    const negative = [_][]const u8{ "corpus-generate", "out", "--shard=-1/2" };
    try std.testing.expectError(error.InvalidShardSpec, parseArguments(negative[0..]));
    const padded = [_][]const u8{ "corpus-generate", "out", "--shard=01/2" };
    try std.testing.expectError(error.InvalidShardSpec, parseArguments(padded[0..]));
    const empty = [_][]const u8{ "corpus-generate", "out", "--shard=" };
    try std.testing.expectError(error.InvalidShardSpec, parseArguments(empty[0..]));
    const zero_assemble = [_][]const u8{ "corpus-generate", "out", "--assemble=0" };
    try std.testing.expectError(error.InvalidShardCount, parseArguments(zero_assemble[0..]));
    const text_assemble = [_][]const u8{ "corpus-generate", "out", "--assemble=three" };
    try std.testing.expectError(error.InvalidShardCount, parseArguments(text_assemble[0..]));
}

// This test proves a shard owns a directory outside the publication root, and
// that the probe path a filtered publication owns is untouched by it.
test "shard paths do not own the publication root" {
    const shard_arguments = [_][]const u8{ "corpus-generate", "out", "--shard=1/3" };
    const shard = try parseArguments(shard_arguments[0..]);
    var paths = try ShardPaths.init(std.testing.allocator, shard);
    defer paths.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("out/shards/all-all/1-of-3", paths.run_root);
    try std.testing.expectEqualStrings("out/shards/all-all/1-of-3/records", paths.records_root);
    try std.testing.expectEqualStrings("out/shards/all-all/1-of-3/metadata.rows", paths.rows_path);
    try std.testing.expectEqualStrings("out/shards/all-all/1-of-3/SHARD", paths.shard_marker);
    try std.testing.expectEqualStrings("out/shards/all-all/1-of-3/.incomplete", paths.incomplete_marker);

    const probe_arguments = [_][]const u8{
        "corpus-generate", "out", "--operation=exp", "--format=h", "--shard=0/2",
    };
    const probe = try parseArguments(probe_arguments[0..]);
    var probe_paths = try ShardPaths.init(std.testing.allocator, probe);
    defer probe_paths.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("out/shards/exp-h/0-of-2", probe_paths.run_root);
    var publication_paths = try OutputPaths.init(std.testing.allocator, probe);
    defer publication_paths.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "out/generated/probes/exp-h",
        publication_paths.run_root,
    );
}

// This test proves the partition covers the selection exactly once, is stable
// across runs, and refuses a shard count larger than the selection.
test "shard partition covers the selection exactly once" {
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    const matrix = try campaigns.classifyManifest(&manifest);
    const selection = try selectDefinitions(&matrix, .{});
    const shard_count = 5;
    try std.testing.expect(selection.count >= shard_count);

    var seen: [campaigns.manifest_campaign_count]u8 = undefined;
    @memset(seen[0..selection.count], 0);
    for (0..shard_count) |shard_index| {
        const spec: ShardSpec = .{ .index = shard_index, .count = shard_count };
        const plan = try planShard(&matrix, selection, spec);
        const repeat = try planShard(&matrix, selection, spec);
        try std.testing.expectEqual(plan.count, repeat.count);
        try std.testing.expect(plan.count > 0);
        for (plan.slots[0..plan.count], 0..) |slot, position| {
            if (position != 0) {
                try std.testing.expect(slot > plan.slots[position - 1]);
            }
            try std.testing.expectEqual(slot, repeat.slots[position]);
            try std.testing.expectEqual(@as(u8, 0), seen[slot]);
            seen[slot] = 1;
        }
    }
    for (seen[0..selection.count]) |owner| try std.testing.expectEqual(@as(u8, 1), owner);

    try std.testing.expectError(
        error.InvalidShardCount,
        planShard(&matrix, selection, .{ .index = 0, .count = selection.count + 1 }),
    );
    try std.testing.expectError(
        error.InvalidShardIndex,
        planShard(&matrix, selection, .{ .index = shard_count, .count = shard_count }),
    );
}

// This test proves the staleness guard. A shard identifies itself with a digest
// of the plan, so an edit to any descriptor, to the profile, to the filter, or
// to the shard count changes the digest and a shard built before the edit can
// no longer be assembled into a publication built after it.
test "a changed manifest or shard count invalidates the shard plan digest" {
    var manifest = try corpus.parseManifest(corpus.manifest_text);
    var matrix = try campaigns.classifyManifest(&manifest);
    var selection = try selectDefinitions(&matrix, .{});
    const baseline = try testShardPlanDigest(&matrix, selection, .{ .index = 1, .count = 4 });

    // One descriptor's own bytes changed, exactly as a manifest edit does.
    manifest.function_values[0].max_ulp += 1;
    matrix = try campaigns.classifyManifest(&manifest);
    selection = try selectDefinitions(&matrix, .{});
    const after_edit = try testShardPlanDigest(&matrix, selection, .{ .index = 1, .count = 4 });
    try std.testing.expect(!std.mem.eql(u8, &baseline, &after_edit));

    // The same manifest under a different shard count is a different plan.
    const after_count = try testShardPlanDigest(&matrix, selection, .{ .index = 1, .count = 5 });
    try std.testing.expect(!std.mem.eql(u8, &after_edit, &after_count));

    // The same manifest and shard count under a different profile is a
    // different plan too: record bytes are only comparable within a profile.
    var wrong_profile = test_profile;
    wrong_profile.cpu = "generic";
    const wrong_plan = try planShard(&matrix, selection, .{ .index = 1, .count = 4 });
    const publication_digest = try descriptorProfileHash(wrong_profile, &matrix, selection);
    const after_profile = try shardPlanDigest(
        wrong_profile,
        &matrix,
        selection,
        wrong_plan,
        publication_digest,
        .{},
    );
    try std.testing.expect(!std.mem.eql(u8, &after_edit, &after_profile));
}

// This test proves the shard marker is a fixed, self-describing record whose
// plan digest survives a round trip and whose damage is visible.
test "shard marker round trip rejects damage" {
    const plan: ShardPlan = .{ .spec = .{ .index = 1, .count = 4 }, .count = 6 };
    const rows_digest: Digest = @splat(0x11);
    const publication_digest: Digest = @splat(0x22);
    const plan_digest: Digest = @splat(0x33);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try appendShardMarker(
        std.testing.allocator,
        &text,
        plan,
        17,
        @as(u64, 1234),
        rows_digest,
        publication_digest,
        plan_digest,
    );
    const marker = try parseShardMarker(text.items);
    try std.testing.expectEqual(@as(usize, 1), marker.index);
    try std.testing.expectEqual(@as(usize, 4), marker.count);
    try std.testing.expectEqual(@as(usize, 17), marker.selection_count);
    try std.testing.expectEqual(@as(usize, 6), marker.descriptor_count);
    try std.testing.expectEqual(@as(u64, 1234), marker.record_count);
    try std.testing.expectEqualStrings(&rows_digest, &marker.rows_digest);
    try std.testing.expectEqualStrings(&publication_digest, &marker.publication_digest);
    try std.testing.expectEqualStrings(&plan_digest, &marker.plan_digest);

    var damaged = try std.testing.allocator.dupe(u8, text.items);
    defer std.testing.allocator.free(damaged);
    const plan_offset = std.mem.indexOf(u8, damaged, "shard_plan_sha256=33").?;
    damaged[plan_offset + "shard_plan_sha256=".len] = '9';
    const changed = try parseShardMarker(damaged);
    try std.testing.expect(!std.mem.eql(u8, &plan_digest, &changed.plan_digest));

    try std.testing.expectError(error.InvalidShardMarker, parseShardMarker(""));
    try std.testing.expectError(
        error.InvalidShardMarker,
        parseShardMarker(damaged[0 .. damaged.len - 1]),
    );
    try std.testing.expectError(
        error.InvalidShardMarker,
        parseShardMarker("zmath-corpus-shard version=1\nshard_index=1\n"),
    );
    try std.testing.expectError(
        error.InvalidShardMarker,
        parseShardMarker("zmath-corpus-shard version=1\nshard_index=01\nshard_count=4\n"),
    );
}

// This test proves the merge invariant on a real generation: the assembled
// publication is byte-identical to the publication the same root produced in one
// run. Both sides MUST share an output root, because a publication names its own
// records directory in every metadata row, so two different roots produce two
// different and equally valid publications. The test therefore generates
// unmerged, captures it, deletes it, and merges the same root again.
test "assembled shards reproduce an unmerged publication byte for byte" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const shard_count = 3;
    try testExpectSelectionAtLeast("nan", shard_count);
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const publication = "corpus/generated/probes/nan-all";

    try testGenerate(scratch.dir, io, allocator, &.{
        "corpus-generate", "corpus", "--operation=nan",
    });
    var captured = try testCapturePublication(io, scratch.dir, allocator, publication);
    defer testFreeCaptured(allocator, &captured);
    try scratch.dir.deleteTree(io, "corpus/generated");

    for (0..shard_count) |shard_index| {
        try testGenerateNanShard(scratch.dir, io, allocator, "corpus", shard_index, shard_count);
    }
    try testGenerate(scratch.dir, io, allocator, &.{
        "corpus-generate", "corpus", "--operation=nan", "--assemble=3",
    });

    try testExpectCapturedEqual(io, scratch.dir, allocator, publication, captured);
    try testExpectPathExists(io, scratch.dir, "corpus/shards/nan-all/0-of-3/SHARD");
}

// This test proves a merge fails closed on an interrupted, missing, or
// miscounted shard, that it writes nothing when it does, and that it refuses to
// overwrite a publication that already exists.
test "assembly refuses an interrupted, missing, or miscounted shard" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const shard_count = 3;
    try testExpectSelectionAtLeast("nan", shard_count);
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const publication = "refused/generated/probes/nan-all";
    const shard_root = "refused/shards/nan-all/1-of-3";
    const assemble = [_][]const u8{
        "corpus-generate", "refused", "--operation=nan", "--assemble=3",
    };
    const assemble_two = [_][]const u8{
        "corpus-generate", "refused", "--operation=nan", "--assemble=2",
    };
    for (0..shard_count) |shard_index| {
        try testGenerateNanShard(scratch.dir, io, allocator, "refused", shard_index, shard_count);
    }

    // An interrupted shard is not a shard, even when its records are present.
    try writeAtomicSynced(io, scratch.dir, shard_root ++ "/.incomplete", "pending\n");
    try std.testing.expectError(
        error.ShardIncomplete,
        testGenerate(scratch.dir, io, allocator, assemble[0..]),
    );
    try testExpectPathMissing(io, scratch.dir, publication ++ "/COMPLETE");
    try testExpectPathMissing(io, scratch.dir, publication ++ "/metadata.txt");
    try deleteIfPresent(io, scratch.dir, shard_root ++ "/.incomplete");

    // A shard count nobody produced names a shard directory that does not
    // exist, so the merge stops at the missing shard and before any write.
    try std.testing.expectError(
        error.MissingShard,
        testGenerate(scratch.dir, io, allocator, assemble_two[0..]),
    );
    try testExpectPathMissing(io, scratch.dir, publication ++ "/COMPLETE");

    // A shard directory that claims another count is refused on the count the
    // marker records, not on the directory name, so a copied or renamed shard
    // cannot pass itself off as part of a different campaign.
    try scratch.dir.rename(
        "refused/shards/nan-all/0-of-3",
        scratch.dir,
        "refused/shards/nan-all/0-of-2",
        io,
    );
    try std.testing.expectError(
        error.ShardCountMismatch,
        testGenerate(scratch.dir, io, allocator, assemble_two[0..]),
    );
    try testExpectPathMissing(io, scratch.dir, publication ++ "/COMPLETE");
    try scratch.dir.rename(
        "refused/shards/nan-all/0-of-2",
        scratch.dir,
        "refused/shards/nan-all/0-of-3",
        io,
    );

    // A missing shard directory is refused, and named.
    try scratch.dir.deleteTree(io, shard_root);
    try std.testing.expectError(
        error.MissingShard,
        testGenerate(scratch.dir, io, allocator, assemble[0..]),
    );
    try testExpectPathMissing(io, scratch.dir, publication ++ "/COMPLETE");
    try testExpectPathMissing(io, scratch.dir, publication ++ "/metadata.txt");

    // Recreating the shard lets the merge finish, and the merge refuses to
    // overwrite the publication it just wrote.
    try testGenerateNanShard(scratch.dir, io, allocator, "refused", 1, shard_count);
    try testGenerate(scratch.dir, io, allocator, assemble[0..]);
    try testExpectPathExists(io, scratch.dir, publication ++ "/COMPLETE");
    try std.testing.expectError(
        error.DestinationAlreadyPublished,
        testGenerate(scratch.dir, io, allocator, assemble[0..]),
    );
}

fn testGenerate(
    root_dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
) !void {
    try generateCorpus(.{
        .io = io,
        .allocator = allocator,
        .root_dir = root_dir,
        .approved_corpus_pair = true,
        .profile = test_profile,
        .arguments = arguments,
    });
}

// A shard count is only legal when the selection can fill it. The tests that
// generate a real publication through a filter state that premise first, so a
// manifest that shrinks below it reports itself instead of surfacing as a
// shard-count rejection from deep inside a merge.
fn testExpectSelectionAtLeast(operation: []const u8, count: usize) !void {
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    const matrix = try campaigns.classifyManifest(&manifest);
    const selection = try selectDefinitions(&matrix, .{ .operation = operation });
    try std.testing.expect(selection.count >= count);
}

fn testShardPlanDigest(
    matrix: *const campaigns.CampaignMatrix,
    selection: Selection,
    spec: ShardSpec,
) !Digest {
    const plan = try planShard(matrix, selection, spec);
    const publication_digest = try descriptorProfileHash(test_profile, matrix, selection);
    return shardPlanDigest(test_profile, matrix, selection, plan, publication_digest, .{});
}

const CapturedRecord = struct {
    name: []u8,
    bytes: []u8,
};

const CapturedPublication = struct {
    metadata: []u8,
    complete: []u8,
    records: []CapturedRecord,
};

fn testGenerateNanShard(
    root_dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    output_root: []const u8,
    index: usize,
    count: usize,
) !void {
    var flag_buffer: [32]u8 = undefined;
    const flag = try std.fmt.bufPrint(
        &flag_buffer,
        "--shard={d}/{d}",
        .{ index, count },
    );
    try testGenerate(root_dir, io, allocator, &.{
        "corpus-generate", output_root, "--operation=nan", flag,
    });
}

// A publication is its metadata, its completion marker, and every record file
// it names. Capturing all three is what lets the merge invariant be stated in
// bytes instead of in words.
fn testCapturePublication(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    publication: []const u8,
) !CapturedPublication {
    var captured: CapturedPublication = .{
        .metadata = try testReadFile(allocator, io, dir, publication, "metadata.txt"),
        .complete = try testReadFile(allocator, io, dir, publication, "COMPLETE"),
        .records = try allocator.alloc(CapturedRecord, 0),
    };
    errdefer testFreeCaptured(allocator, &captured);
    var count: usize = 0;
    const records_root = try std.fmt.allocPrint(allocator, "{s}/records", .{publication});
    defer allocator.free(records_root);
    var records = try dir.openDir(io, records_root, .{ .iterate = true });
    defer records.close(io);
    var iterator = records.iterate();
    while (try iterator.next(io)) |entry| {
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/records/{s}",
            .{ publication, entry.name },
        );
        defer allocator.free(path);
        const bytes = try dir.readFileAlloc(io, path, allocator, .limited(1 << 24));
        captured.records = try allocator.realloc(captured.records, count + 1);
        captured.records[count] = .{ .name = try allocator.dupe(u8, entry.name), .bytes = bytes };
        count += 1;
    }
    try std.testing.expect(count > 0);
    return captured;
}

fn testExpectCapturedEqual(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    publication: []const u8,
    captured: CapturedPublication,
) !void {
    const metadata = try testReadFile(allocator, io, dir, publication, "metadata.txt");
    defer allocator.free(metadata);
    const complete = try testReadFile(allocator, io, dir, publication, "COMPLETE");
    defer allocator.free(complete);
    try std.testing.expectEqualStrings(captured.metadata, metadata);
    try std.testing.expectEqualStrings(captured.complete, complete);

    const records_root = try std.fmt.allocPrint(allocator, "{s}/records", .{publication});
    defer allocator.free(records_root);
    var records = try dir.openDir(io, records_root, .{ .iterate = true });
    defer records.close(io);
    var iterator = records.iterate();
    var compared: usize = 0;
    while (try iterator.next(io)) |entry| {
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/records/{s}",
            .{ publication, entry.name },
        );
        defer allocator.free(path);
        const bytes = try dir.readFileAlloc(io, path, allocator, .limited(1 << 24));
        defer allocator.free(bytes);
        for (captured.records) |record| {
            if (!std.mem.eql(u8, record.name, entry.name)) continue;
            try std.testing.expectEqualStrings(record.bytes, bytes);
            compared += 1;
            break;
        } else return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(captured.records.len, compared);
}

fn testReadFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    publication: []const u8,
    name: []const u8,
) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ publication, name });
    defer allocator.free(path);
    return dir.readFileAlloc(io, path, allocator, .limited(1 << 24));
}

fn testFreeCaptured(allocator: std.mem.Allocator, captured: *CapturedPublication) void {
    for (captured.records) |record| {
        allocator.free(record.name);
        allocator.free(record.bytes);
    }
    allocator.free(captured.records);
    allocator.free(captured.complete);
    allocator.free(captured.metadata);
    captured.* = undefined;
}
