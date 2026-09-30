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
//! ## Binary32 raw-input ranges
//!
//! `--f32-range=LOW:HIGH` declares a half-open interval of raw binary32 bit
//! patterns, `0 <= LOW < HIGH <= 2^32`, and selects the descriptors eligible
//! for it: arity one with one `float:f` input, whatever the result format is.
//! `--shard=<i>/<n>` then splits THAT interval into `n` contiguous pieces and
//! every selected descriptor is generated over each piece, so a range run
//! never needs a descriptor partition and a worker never needs the manifest
//! partition an ordinary shard uses. `--assemble=<n>` proves the pieces tile
//! the interval and writes one range publication.
//!
//! Three things are deliberately different from an ordinary publication.
//!
//! - It lives at `<out>/ranges/<probe>/<low>-<high>` with a `RANGE` receipt,
//!   and an assembled one has `RANGE_COMPLETE`. Neither is `COMPLETE`, and
//!   `load` never reads either, so a partial range can never be mistaken for
//!   the corpus.
//! - Coverage is recomputed by the reader from the declared interval and
//!   whether a tiling was proved. It is `exhaustive_binary32` only for a
//!   proved tiling of `[0, 2^32)`; every other range is `partial`.
//! - Each artifact is proved to hold exactly `[LOW, HIGH)`: record `i` must
//!   carry raw input `LOW + i`, which proves the count, the first input, the
//!   last input, the order, and the absence of a hole, a duplicate, and a
//!   seam in one identity. It is proved for every shard before the
//!   destination is touched, and again by the replay.
//!
//! Without the flag nothing here runs: a range interval is never inferred,
//! and `2^32` is never scanned because no flag asked for it.
//!
//! ## Reusing a published artifact
//!
//! `--reuse-existing=<run root>` publishes into an output root while copying
//! the artifacts of a completed publication the caller names, and generating
//! only the descriptors that publication does not have. It is how a grown
//! manifest keeps its verified artifacts without regenerating the
//! exhaustive campaigns behind them.
//!
//! Nothing is copied until the source is proved, and it is proved in three
//! parts. The publication proves itself: `COMPLETE`, the SHA-256 of its
//! metadata, the core-math repository and revision, the qualified profile, the
//! scope, and the record codec. The rows prove the descriptors: every row is
//! matched to the one current descriptor it may supply, the row count is
//! checked against the header, and the source's own
//! `manifest_descriptor_sha256` is rebuilt from those matched current
//! descriptors, so a changed `max_ulp`, result kind, argument descriptor,
//! policy, or C signature refuses the reuse. The artifacts prove the numbers:
//! every record of every reused artifact is streamed before the destination
//! exists, and its operation, provenance, argument formats, result
//! descriptor, `max_ulp`, canonical order, and count must be the current
//! function's, under the digest its row claims. A changed status, oracle,
//! evaluator, campaign, or source pin refuses the row itself.
//!
//! A ZCDR record carries no signature index, so an unchanged descriptor means
//! the artifact is unchanged byte for byte, and the copy is proved as it is
//! made. Nothing falls back silently: a row the source does not have, a row
//! that no longer matches, or an artifact that does not hold what its row
//! claims is a refusal, not a regeneration. The destination is compared to
//! the source by the identity the filesystem reports, so two spellings of one
//! directory and a symbolic link that points at it are both the destination
//! and are both refused before anything is deleted. The source is never
//! written to.
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
// A range receipt names an interval, a shard index and count, a descriptor and
// a record count, and three digests, so it is a fixed record like the ordinary
// shard marker and no larger.
const range_marker_bytes_max: usize = 2048;
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
    // An explicit half-open interval of raw binary32 bit patterns. Absent
    // means the ordinary publication, and an ordinary publication never
    // infers an interval or scans a domain nobody asked for.
    range: ?corpus_set.RawRange = null,
    // An explicit source publication for artifact reuse, named by its run
    // root. Reuse is opt-in; there is no fallback to it.
    reuse_run_root: ?[]const u8 = null,
};

fn setFilters(filters: FilterOptions) corpus_set.Filters {
    return .{ .operation = filters.operation, .format = filters.format };
}

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

// Domain walkers stream records in canonical order. Bounded named cases may
// arrive in any order, so they are collected from the first record and sorted
// before publication. A later inversion cannot be repaired after an earlier
// prefix has already reached the artifact.
const RecordContext = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    record_hasher: std.crypto.hash.sha2.Sha256,
    // One-record lookahead for ordered walkers. Store encoded bytes because
    // decoded operation and tag fields borrow their frame.
    held_back_encoded: [encoded_record_capacity]u8 = undefined,
    held_back_length: usize = 0,
    // Bounded named cases, collected before any record is published.
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
    try context.writer.writeAll(bytes);
    context.record_hasher.update(bytes);
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

// Sort every bounded case, then prove adjacent records. Duplicates are refused,
// not silently removed.
fn publishHeldRun(context: *RecordContext) !void {
    std.sort.block(
        u32,
        context.held_offsets.items,
        HeldRecordOrder{ .context = context },
        HeldRecordOrder.lessThan,
    );
    var previous: ?corpus.CorpusRecord = null;
    for (context.held_offsets.items) |start| {
        const bytes = heldRecord(context, start);
        const current = try corpus.decodeCorpusRecord(bytes);
        if (previous) |*prior| try corpus.validateCorpusRecordOrder(prior, &current);
        try publishRecord(context, bytes);
        previous = current;
    }
}

// Flush the bounded case set or the ordered walker's last record.
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
    const selection = if (parsed.range != null)
        try selectRangeDefinitions(&matrix, parsed.filters)
    else
        try selectDefinitions(&matrix, parsed.filters);
    if (selection.count == 0) return error.EmptySelection;

    if (parsed.range) |declared| {
        const descriptor_digest = try corpus_set.rangeDescriptorDigest(
            options.profile,
            &manifest,
            setFilters(parsed.filters),
        );
        switch (parsed.mode) {
            .publish => try publishRangePublication(
                options,
                parsed,
                &matrix,
                selection,
                declared,
                descriptor_digest,
            ),
            .shard => |spec| try generateRangeShard(
                options,
                parsed,
                &matrix,
                selection,
                declared,
                descriptor_digest,
                spec,
            ),
            .assemble => |spec| try assembleRangePublication(
                options,
                parsed,
                &matrix,
                selection,
                declared,
                descriptor_digest,
                spec,
            ),
        }
        return;
    }

    switch (parsed.mode) {
        .publish => try publishCorpus(options, parsed, &manifest, &matrix, selection),
        .shard => |spec| try generateShard(options, parsed, &matrix, selection, spec),
        .assemble => |spec| try assemblePublication(options, parsed, &matrix, selection, spec),
    }
}

/// The eligible subset of the filtered selection. The filters keep their
/// ordinary result-format meaning and the eligibility rule is applied after
/// them, so a range run selects fewer descriptors than a publication does and
/// a filter that matches nothing eligible is reported instead of quietly
/// widening the domain.
fn selectRangeDefinitions(
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
        if (!corpus_set.rangeEligible(&definition.function)) continue;
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
        return error.EmptyRangeSelection;
    }
    return selection;
}

fn publishCorpus(
    options: GeneratorOptions,
    parsed: ParsedArguments,
    manifest: *const corpus.Manifest,
    matrix: *const campaigns.CampaignMatrix,
    selection: Selection,
) !void {
    var paths = try OutputPaths.init(options.allocator, parsed);
    defer paths.deinit(options.allocator);
    // The source is proved and read before the destination is created, so a
    // refused reuse has already destroyed nothing.
    var reuse = try openReuseSource(options, parsed, manifest, &paths);
    defer reuse.deinit(options.allocator);
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
            reuseEntry(&reuse, index),
        );
    }

    var metadata_digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(metadata.items, &metadata_digest, .{});
    try publication.finish(metadata.items, metadata_digest);
}

/// The optional reuse set of one publication. Reuse is explicit, so a run
/// without the flag carries none and takes exactly the path it took before.
const ReuseSource = struct {
    set: ?corpus_set.ReuseSet,

    fn deinit(self: *ReuseSource, allocator: std.mem.Allocator) void {
        if (self.set) |*set| set.deinit(allocator);
        self.* = undefined;
    }
};

/// The reusable artifact for one descriptor, if the source publication has
/// one. The set is reached through a pointer so a publication-sized table is
/// never copied once per descriptor.
fn reuseEntry(source: *const ReuseSource, index: usize) ?corpus_set.ReusableEntry {
    if (source.set) |*set| return set.at(index);
    return null;
}

fn openReuseSource(
    options: GeneratorOptions,
    parsed: ParsedArguments,
    manifest: *const corpus.Manifest,
    destination: *const OutputPaths,
) !ReuseSource {
    const source_run_root = parsed.reuse_run_root orelse return .{ .set = null };
    // The publication this run is about to write must not be the publication
    // it copies, and must not live inside it either. The guard runs before the
    // source is read, so a destination that aliases the source is refused
    // before anything can delete its completion marker.
    try rejectUnsafeReuseDestination(
        options.io,
        options.root_dir,
        source_run_root,
        destination.run_root,
    );
    const set = try corpus_set.loadReusable(
        options.allocator,
        options.io,
        options.root_dir,
        source_run_root,
        manifest,
        options.profile,
        setFilters(parsed.filters),
    );
    std.debug.print(
        "reusing {d} verified artifacts from {s}\n",
        .{ set.reusable_count, source_run_root },
    );
    return .{ .set = set };
}

/// The identity of one publication root, as the filesystem reports it and not
/// as the caller spelled it. `resolved` is the real path of the deepest part
/// of the root that exists, with every symbolic link and every `..` resolved
/// by the system; `rest` is the remainder, which does not exist yet and so
/// cannot be a link. A root that does not exist at all is resolved against the
/// working directory, which always exists.
const RootIdentity = struct {
    resolved: [std.Io.Dir.max_path_bytes]u8 = undefined,
    resolved_length: usize = 0,
};

fn resolveRootIdentity(
    io: std.Io,
    root_dir: std.Io.Dir,
    path: []const u8,
    identity: *RootIdentity,
) !void {
    if (path.len == 0 or path.len > identity.resolved.len) return error.InvalidRunRoot;
    var existing_length = path.len;
    while (true) {
        identity.resolved_length = root_dir.realPathFile(
            io,
            path[0..existing_length],
            &identity.resolved,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                const trimmed = std.mem.lastIndexOfScalar(u8, path[0..existing_length], '/') orelse 0;
                if (trimmed == 0) {
                    if (path[0] == '/') {
                        identity.resolved_length = try root_dir.realPathFile(io, "/", &identity.resolved);
                        existing_length = 1;
                    } else {
                        identity.resolved_length = try root_dir.realPathFile(io, ".", &identity.resolved);
                        existing_length = 0;
                    }
                    break;
                }
                existing_length = trimmed;
                continue;
            },
            else => return err,
        };
        break;
    }
    // Resolve the existing prefix through the filesystem, then normalize the
    // missing suffix. Two absent roots under one directory are not aliases.
    var components = std.mem.splitScalar(u8, path[existing_length..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (identity.resolved_length > 1) {
                const parent = std.mem.lastIndexOfScalar(u8, identity.resolved[0..identity.resolved_length], '/') orelse
                    return error.InvalidRunRoot;
                identity.resolved_length = @max(parent, 1);
            }
            continue;
        }
        const separator: usize = if (identity.resolved_length == 1) 0 else 1;
        const available = identity.resolved.len - identity.resolved_length;
        if (separator > available or component.len > available - separator)
            return error.InvalidRunRoot;
        if (separator != 0) {
            identity.resolved[identity.resolved_length] = '/';
            identity.resolved_length += 1;
        }
        @memcpy(identity.resolved[identity.resolved_length..][0..component.len], component);
        identity.resolved_length += component.len;
    }
}

/// Refuses a destination that is the reuse source or that lives inside it.
/// Two spellings of one directory, and a symbolic link that points at it, name
/// the same directory: publishing into either one deletes the source's own
/// `COMPLETE` marker and `metadata.txt` before it copies a single record, and
/// the copy would then read the file it is truncating. A name comparison does
/// not see either case, so the identity does.
fn rejectUnsafeReuseDestination(
    io: std.Io,
    root_dir: std.Io.Dir,
    source_run_root: []const u8,
    destination_run_root: []const u8,
) !void {
    // A missing source has no publication to damage. Let the loader report
    // its missing completion instead of comparing unrelated absent roots.
    root_dir.access(io, source_run_root, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    var source: RootIdentity = .{};
    resolveRootIdentity(io, root_dir, source_run_root, &source) catch |err| switch (err) {
        // A source that is not there is reported by the loader, which knows
        // what a publication is. This guard has nothing to compare it to.
        error.FileNotFound => return,
        else => return err,
    };
    var destination: RootIdentity = .{};
    try resolveRootIdentity(io, root_dir, destination_run_root, &destination);

    const source_resolved = source.resolved[0..source.resolved_length];
    const destination_resolved = destination.resolved[0..destination.resolved_length];
    if (std.mem.eql(u8, source_resolved, destination_resolved)) {
        std.debug.print(
            "--reuse-existing names this run's own destination: {s}\n",
            .{destination_run_root},
        );
        return error.ReuseSourceIsDestination;
    }
    if (destination_resolved.len > source_resolved.len and
        std.mem.startsWith(u8, destination_resolved, source_resolved) and
        (source_resolved.len == 1 or destination_resolved[source_resolved.len] == '/'))
    {
        std.debug.print(
            "--reuse-existing root contains this run's destination: {s}\n",
            .{destination_run_root},
        );
        return error.ReuseDestinationInsideSource;
    }
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
            null,
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
    try requireExactEntries(
        options.allocator,
        options.io,
        options.root_dir,
        .{
            .run_root = paths.run_root,
            .records_root = paths.records_root,
            .metadata_path = paths.metadata_path,
            .incomplete_marker = paths.incomplete_marker,
        },
        selection.count,
    );
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
    try clearAbortedRun(
        allocator,
        io,
        root_dir,
        .{
            .run_root = paths.run_root,
            .records_root = paths.records_root,
            .metadata_path = paths.metadata_path,
            .incomplete_marker = paths.incomplete_marker,
        },
    );
}

const AbortedRunPaths = struct {
    run_root: []const u8,
    records_root: []const u8,
    metadata_path: []const u8,
    incomplete_marker: []const u8,
};

// The sweep an assembling run shares with an ordinary merge, once the
// destination has been proved to hold only this tool's aborted run: the record
// tree and the metadata are removed, and any entry that is not one of the
// three this tool owns is removed too, so the new run cannot inherit a
// leftover artifact no descriptor claims.
fn clearAbortedRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    paths: AbortedRunPaths,
) !void {
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
    paths: AbortedRunPaths,
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

// Joins the pieces of one range artifact, in shard order, into one file and
// returns the digest of the result. The digest is of the bytes that arrived, so
// the row written next to the file carries a fact about that file rather than
// a claim about the pieces it came from.
fn concatVerified(
    io: std.Io,
    root_dir: std.Io.Dir,
    sources: []const []const u8,
    destination_path: []const u8,
) !Digest {
    var atomic = try root_dir.createFileAtomic(io, destination_path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);
    var read_buffer: [shard_copy_buffer_bytes]u8 = undefined;
    var write_buffer: [shard_copy_buffer_bytes]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (sources) |source_path| {
        const source = root_dir.openFile(io, source_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("a range shard record is missing: {s}\n", .{source_path});
                return error.ArtifactMissing;
            },
            else => return err,
        };
        defer source.close(io);
        var reader = source.reader(io, &read_buffer);
        while (true) {
            const read = try reader.interface.readSliceShort(&write_buffer);
            if (read == 0) break;
            hasher.update(write_buffer[0..read]);
            try atomic.file.writeStreamingAll(io, write_buffer[0..read]);
        }
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
        } else if (std.mem.startsWith(u8, argument, "--f32-range=")) {
            if (parsed.range != null) return error.InvalidArguments;
            parsed.range = try corpus_set.parseRawRangeSpec(argument["--f32-range=".len..]);
        } else if (std.mem.startsWith(u8, argument, "--reuse-existing=")) {
            if (parsed.reuse_run_root != null) return error.InvalidArguments;
            const source = argument["--reuse-existing=".len..];
            if (source.len == 0) return error.InvalidArguments;
            parsed.reuse_run_root = source;
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
    // A range run generates the binary32 input domain itself and a reuse run
    // copies another publication's artifacts. Asking for both in one run names
    // two different publications of two different things, so it is refused
    // instead of resolved by a rule nobody would guess.
    if (parsed.range != null and parsed.reuse_run_root != null) return error.InvalidArguments;
    // A reuse is a whole-publication source: a shard owns only part of the
    // selection, so it would copy only part of the source, and an assembling
    // run has no generation step to copy at all.
    if (parsed.reuse_run_root != null and parsed.mode != .publish) {
        return error.InvalidArguments;
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

// ---------------------------------------------------------------------------
// Binary32 raw-input ranges
//
// A range publication is not an ordinary publication. It has its own root, its
// own receipt names, its own rows, and its own loader, and the only marker it
// ever writes that an ordinary reader knows is `.incomplete`, so no range run
// can delete or forge an ordinary `COMPLETE`.
// ---------------------------------------------------------------------------

/// `<out>/ranges/<probe>/<low>-<high>`. The leaf names the interval, so two
/// ranges of the same selection never share a directory and a reader can tell
/// which interval a directory claims from its name alone.
const RangePaths = struct {
    run_root: []u8,
    records_root: []u8,
    metadata_path: []u8,
    incomplete_marker: []u8,
    worker_receipt: []u8,
    complete_receipt: []u8,
    ordinary_complete: []u8,

    fn init(allocator: std.mem.Allocator, arguments: ParsedArguments) !RangePaths {
        const declared = arguments.range orelse return error.InvalidArguments;
        const ranges_root = try std.fs.path.join(
            allocator,
            &.{ arguments.output_root, "ranges" },
        );
        defer allocator.free(ranges_root);
        const probe = try probeName(allocator, arguments.filters);
        defer allocator.free(probe);
        const leaf = try std.fmt.allocPrint(
            allocator,
            "{d}-{d}",
            .{ declared.low, declared.high },
        );
        defer allocator.free(leaf);
        const base = try std.fs.path.join(allocator, &.{ ranges_root, probe });
        defer allocator.free(base);
        const run_root = try std.fs.path.join(allocator, &.{ base, leaf });
        errdefer allocator.free(run_root);
        const records_root = try std.fs.path.join(allocator, &.{ run_root, "records" });
        errdefer allocator.free(records_root);
        const metadata_path = try std.fs.path.join(allocator, &.{ run_root, "metadata.txt" });
        errdefer allocator.free(metadata_path);
        const incomplete_marker = try std.fs.path.join(allocator, &.{ run_root, ".incomplete" });
        errdefer allocator.free(incomplete_marker);
        const worker_receipt = try std.fs.path.join(allocator, &.{ run_root, "RANGE" });
        errdefer allocator.free(worker_receipt);
        const complete_receipt = try std.fs.path.join(
            allocator,
            &.{ run_root, "RANGE_COMPLETE" },
        );
        errdefer allocator.free(complete_receipt);
        const ordinary_complete = try std.fs.path.join(allocator, &.{ run_root, "COMPLETE" });
        errdefer allocator.free(ordinary_complete);
        return .{
            .run_root = run_root,
            .records_root = records_root,
            .metadata_path = metadata_path,
            .incomplete_marker = incomplete_marker,
            .worker_receipt = worker_receipt,
            .complete_receipt = complete_receipt,
            .ordinary_complete = ordinary_complete,
        };
    }

    fn deinit(self: *RangePaths, allocator: std.mem.Allocator) void {
        allocator.free(self.run_root);
        allocator.free(self.records_root);
        allocator.free(self.metadata_path);
        allocator.free(self.incomplete_marker);
        allocator.free(self.worker_receipt);
        allocator.free(self.complete_receipt);
        allocator.free(self.ordinary_complete);
        self.* = undefined;
    }
};

/// `<out>/range-shards/<probe>/<low>-<high>/<i>-of-<n>`. A range shard lives
/// outside the range root for the same reason an ordinary shard does: a merge
/// must never find a shard tree inside the publication it is building, and a
/// finished range publication carries no per-worker tree with it.
const RangeShardPaths = struct {
    run_root: []u8,
    records_root: []u8,
    rows_path: []u8,
    incomplete_marker: []u8,
    shard_receipt: []u8,

    fn init(allocator: std.mem.Allocator, arguments: ParsedArguments) !RangeShardPaths {
        const declared = arguments.range orelse return error.InvalidArguments;
        const spec = switch (arguments.mode) {
            .shard => |shard| shard,
            else => return error.InvalidArguments,
        };
        const shards_root = try std.fs.path.join(
            allocator,
            &.{ arguments.output_root, "range-shards" },
        );
        defer allocator.free(shards_root);
        const probe = try probeName(allocator, arguments.filters);
        defer allocator.free(probe);
        const interval_leaf = try std.fmt.allocPrint(
            allocator,
            "{d}-{d}",
            .{ declared.low, declared.high },
        );
        defer allocator.free(interval_leaf);
        const interval_root = try std.fs.path.join(
            allocator,
            &.{ shards_root, probe, interval_leaf },
        );
        defer allocator.free(interval_root);
        const leaf = try std.fmt.allocPrint(
            allocator,
            "{d}-of-{d}",
            .{ spec.index, spec.count },
        );
        defer allocator.free(leaf);
        const run_root = try std.fs.path.join(allocator, &.{ interval_root, leaf });
        errdefer allocator.free(run_root);
        const records_root = try std.fs.path.join(allocator, &.{ run_root, "records" });
        errdefer allocator.free(records_root);
        const rows_path = try std.fs.path.join(allocator, &.{ run_root, "metadata.rows" });
        errdefer allocator.free(rows_path);
        const incomplete_marker = try std.fs.path.join(allocator, &.{ run_root, ".incomplete" });
        errdefer allocator.free(incomplete_marker);
        const shard_receipt = try std.fs.path.join(allocator, &.{ run_root, "RANGE_SHARD" });
        errdefer allocator.free(shard_receipt);
        return .{
            .run_root = run_root,
            .records_root = records_root,
            .rows_path = rows_path,
            .incomplete_marker = incomplete_marker,
            .shard_receipt = shard_receipt,
        };
    }

    fn deinit(self: *RangeShardPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.run_root);
        allocator.free(self.records_root);
        allocator.free(self.rows_path);
        allocator.free(self.incomplete_marker);
        allocator.free(self.shard_receipt);
        self.* = undefined;
    }
};

const RangeRun = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    paths: *const RangePaths,

    fn begin(self: *const RangeRun) !void {
        // An ordinary `COMPLETE` in a range root is a claim this tool never
        // makes and must never destroy, so its presence stops the run.
        if (try pathExists(self.io, self.root_dir, self.paths.ordinary_complete)) {
            std.debug.print(
                "{s} holds an ordinary publication marker\n",
                .{self.paths.run_root},
            );
            return error.UnexpectedOrdinaryCompletion;
        }
        try self.root_dir.createDirPath(self.io, self.paths.run_root);
        try self.root_dir.createDirPath(self.io, self.paths.records_root);
        try deleteIfPresent(self.io, self.root_dir, self.paths.worker_receipt);
        try deleteIfPresent(self.io, self.root_dir, self.paths.complete_receipt);
        try deleteIfPresent(self.io, self.root_dir, self.paths.metadata_path);
        try writeAtomicSynced(
            self.io,
            self.root_dir,
            self.paths.incomplete_marker,
            "oracle-generate range started\n",
        );
    }

    fn finish(
        self: *const RangeRun,
        metadata: []const u8,
        receipt: corpus_set.RangeReceipt,
    ) !void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.allocator);
        try corpus_set.appendRangeReceipt(self.allocator, &text, receipt);
        try writeAtomicSynced(self.io, self.root_dir, self.paths.metadata_path, metadata);
        try deleteIfPresent(self.io, self.root_dir, self.paths.incomplete_marker);
        const path = switch (receipt.kind) {
            .worker => self.paths.worker_receipt,
            .assembled => self.paths.complete_receipt,
        };
        try writeAtomicSynced(self.io, self.root_dir, path, text.items);
    }
};

const RangeShardRun = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    paths: *const RangeShardPaths,

    fn begin(self: *const RangeShardRun) !void {
        try self.root_dir.createDirPath(self.io, self.paths.run_root);
        try self.root_dir.createDirPath(self.io, self.paths.records_root);
        try deleteIfPresent(self.io, self.root_dir, self.paths.shard_receipt);
        try deleteIfPresent(self.io, self.root_dir, self.paths.rows_path);
        try writeAtomicSynced(
            self.io,
            self.root_dir,
            self.paths.incomplete_marker,
            "oracle-generate range shard started\n",
        );
    }

    fn finish(
        self: *const RangeShardRun,
        rows: []const u8,
        receipt: corpus_set.RangeShardReceipt,
    ) !void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.allocator);
        try corpus_set.appendRangeShardReceipt(self.allocator, &text, receipt);
        try writeAtomicSynced(self.io, self.root_dir, self.paths.rows_path, rows);
        try deleteIfPresent(self.io, self.root_dir, self.paths.incomplete_marker);
        try writeAtomicSynced(self.io, self.root_dir, self.paths.shard_receipt, text.items);
    }
};

/// A range metadata header states the interval, the width of the raw domain,
/// the selected descriptor count, the recomputed coverage claim, the shard
/// count the tiling was proved against, and both digests a reader must
/// reproduce. It deliberately carries no campaign claim: a range artifact is
/// not a campaign enumeration.
fn appendRangeMetadataHeader(
    allocator: std.mem.Allocator,
    metadata: *std.ArrayList(u8),
    profile: GeneratorProfile,
    arguments: ParsedArguments,
    selection: Selection,
    declared: corpus_set.RawRange,
    coverage: corpus_set.RangeCoverage,
    shard_count: u64,
    descriptor_digest: Digest,
    plan_digest: Digest,
) !void {
    try appendFormat(
        "{s}\n",
        allocator,
        metadata,
        .{corpus_set.range_metadata_first_line},
    );
    try appendFormat(
        "range_low={d}\nrange_high={d}\nrange_input_width_bits={d}\n",
        allocator,
        metadata,
        .{ declared.low, declared.high, corpus_set.range_input_width_bits },
    );
    try appendFormat(
        "range_descriptor_count={d}\nrange_coverage={s}\nrange_shard_count={d}\n",
        allocator,
        metadata,
        .{ selection.count, @tagName(coverage), shard_count },
    );
    try appendDigestLine(allocator, metadata, "manifest_descriptor_sha256", descriptor_digest);
    try appendDigestLine(allocator, metadata, "range_plan_sha256", plan_digest);
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
        "generation_scope={s}\noperation_filter={s}\nformat_filter={s}\n" ++
            "record_codec_version={d}\n\n",
        allocator,
        metadata,
        .{
            @tagName(selection.scope),
            arguments.filters.operation orelse "all",
            if (arguments.filters.format) |format| @tagName(format) else "all",
            corpus.descriptor_corpus_codec_version,
        },
    );
}

fn publishRangePublication(
    options: GeneratorOptions,
    parsed: ParsedArguments,
    matrix: *const campaigns.CampaignMatrix,
    selection: Selection,
    declared: corpus_set.RawRange,
    descriptor_digest: Digest,
) !void {
    const interval = try corpus_set.splitRawRange(declared, 1, 0);
    const plan_digest = corpus_set.rangePlanDigest(.{
        .profile = options.profile,
        .filters = setFilters(parsed.filters),
        .descriptor_digest = descriptor_digest,
        .declared = declared,
        .shard_count = 1,
        .shard_index = 0,
        .subrange = interval,
    });
    // One worker holds the whole declared interval, so that interval is
    // complete. Whether it is the whole binary32 domain is the reader's
    // question, and it is answered from the interval, never from this line.
    const coverage = corpus_set.rangeCoverage(declared, true);
    var paths = try RangePaths.init(options.allocator, parsed);
    defer paths.deinit(options.allocator);
    const run: RangeRun = .{
        .io = options.io,
        .allocator = options.allocator,
        .root_dir = options.root_dir,
        .paths = &paths,
    };
    try run.begin();

    var metadata: std.ArrayList(u8) = .empty;
    defer metadata.deinit(options.allocator);
    try appendRangeMetadataHeader(
        options.allocator,
        &metadata,
        options.profile,
        parsed,
        selection,
        declared,
        coverage,
        1,
        descriptor_digest,
        plan_digest,
    );
    var record_count: u64 = 0;
    for (selection.indices[0..selection.count]) |index| {
        const definition = matrix.at(index) orelse return error.ManifestCountMismatch;
        record_count += try generateRangeDefinition(
            options.allocator,
            options.io,
            options.root_dir,
            &metadata,
            paths.records_root,
            index,
            definition,
            interval,
        );
    }
    var metadata_digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(metadata.items, &metadata_digest, .{});
    try run.finish(metadata.items, .{
        .kind = .worker,
        .declared = declared,
        .coverage = coverage,
        .descriptor_count = selection.count,
        .record_count = record_count,
        .shard_count = 1,
        .descriptor_digest = descriptor_digest,
        .plan_digest = plan_digest,
        .metadata_digest = metadata_digest,
    });
}

fn generateRangeDefinition(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    metadata: *std.ArrayList(u8),
    records_root: []const u8,
    index: usize,
    definition: *const campaigns.CampaignDefinition,
    interval: corpus_set.RawRange,
) !u64 {
    // A descriptor with no campaign evidence has no proved evaluator to
    // generate from, and it is refused loudly rather than dropped from the
    // selection the receipt and the descriptor digest already name.
    if (!campaignEvidenceAvailable(definition)) return error.RangeDescriptorUnavailable;
    const function = definition.function;
    const signature = try corpus_set.evaluatorSignature(&function);
    const artifact_path = try generatedArtifactPath(
        allocator,
        records_root,
        index,
        function.op,
    );
    defer allocator.free(artifact_path);
    const produced = try writeArtifact(
        allocator,
        io,
        root_dir,
        artifact_path,
        function,
        .{ .raw_range = interval },
    );
    if (produced.record_count != interval.length()) return error.RangeRecordCountMismatch;
    try corpus_set.appendRangeRow(allocator, metadata, .{
        .signature_index = index,
        .operation = function.op,
        .manifest_status = function.status,
        .oracle = function.oracle,
        .evaluator = try corpus_set.evaluatorCategory(signature),
        .range_low = interval.low,
        .range_high = interval.high,
        .records = produced.record_count,
        .input_argument = 0,
        .source_hash = corpus_set.rangeSourceDigest(),
        .artifact = artifact_path,
        .artifact_sha256 = produced.digest,
    });
    return produced.record_count;
}

/// One worker, one piece of the declared interval, every selected descriptor.
/// The plan digest binds the piece, so a shard built for another piece, another
/// shard count, another filter, another profile, or another manifest cannot be
/// assembled into this run's publication.
fn generateRangeShard(
    options: GeneratorOptions,
    parsed: ParsedArguments,
    matrix: *const campaigns.CampaignMatrix,
    selection: Selection,
    declared: corpus_set.RawRange,
    descriptor_digest: Digest,
    spec: ShardSpec,
) !void {
    const interval = try corpus_set.splitRawRange(
        declared,
        @intCast(spec.count),
        @intCast(spec.index),
    );
    const plan_digest = corpus_set.rangePlanDigest(.{
        .profile = options.profile,
        .filters = setFilters(parsed.filters),
        .descriptor_digest = descriptor_digest,
        .declared = declared,
        .shard_count = @intCast(spec.count),
        .shard_index = @intCast(spec.index),
        .subrange = interval,
    });
    var paths = try RangeShardPaths.init(options.allocator, parsed);
    defer paths.deinit(options.allocator);
    const run: RangeShardRun = .{
        .io = options.io,
        .allocator = options.allocator,
        .root_dir = options.root_dir,
        .paths = &paths,
    };
    try run.begin();

    var rows: std.ArrayList(u8) = .empty;
    defer rows.deinit(options.allocator);
    var record_count: u64 = 0;
    for (selection.indices[0..selection.count]) |index| {
        const definition = matrix.at(index) orelse return error.ManifestCountMismatch;
        record_count += try generateRangeDefinition(
            options.allocator,
            options.io,
            options.root_dir,
            &rows,
            paths.records_root,
            index,
            definition,
            interval,
        );
    }
    const expected = std.math.mul(u64, interval.length(), selection.count) catch
        return error.RecordCountOverflow;
    if (record_count != expected) return error.ShardWorkMismatch;
    try run.finish(rows.items, .{
        .declared = declared,
        .interval = interval,
        .shard_index = @intCast(spec.index),
        .shard_count = @intCast(spec.count),
        .descriptor_count = selection.count,
        .record_count = record_count,
        .rows_digest = rowsDigest(rows.items),
        .descriptor_digest = descriptor_digest,
        .plan_digest = plan_digest,
    });
}

/// Reads one range shard, proves it is the shard this manifest, profile,
/// filter, and interval ask for, proves every artifact in it holds exactly its
/// subrange, and returns it. Nothing is written, so a rejection here costs no
/// publication.
const LoadedRangeShard = struct {
    // Optional because a table of them is freed by the caller whether or not
    // every shard in it was loaded: a shard that refused to load owns nothing,
    // and an undefined one would be freed as if it owned something.
    paths: ?RangeShardPaths = null,
    rows: ?[]u8 = null,
    interval: corpus_set.RawRange = .{ .low = 0, .high = 0 },
    record_count: u64 = 0,

    fn deinit(self: *LoadedRangeShard, allocator: std.mem.Allocator) void {
        if (self.paths) |*paths| paths.deinit(allocator);
        if (self.rows) |rows| allocator.free(rows);
        self.* = undefined;
    }
};

fn readRangeShard(
    options: GeneratorOptions,
    parsed: ParsedArguments,
    matrix: *const campaigns.CampaignMatrix,
    selection: Selection,
    declared: corpus_set.RawRange,
    descriptor_digest: Digest,
    spec: ShardSpec,
    interval: corpus_set.RawRange,
) !LoadedRangeShard {
    const allocator = options.allocator;
    var arguments = parsed;
    arguments.mode = .{ .shard = spec };
    var paths = try RangeShardPaths.init(allocator, arguments);
    errdefer paths.deinit(allocator);

    if (try pathExists(options.io, options.root_dir, paths.incomplete_marker)) {
        std.debug.print(
            "range shard {d} of {d} was interrupted and is not a shard: {s}\n",
            .{ spec.index, spec.count, paths.incomplete_marker },
        );
        return error.ShardIncomplete;
    }
    const receipt_source = options.root_dir.readFileAlloc(
        options.io,
        paths.shard_receipt,
        allocator,
        .limited(range_marker_bytes_max),
    ) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print(
                "range shard {d} of {d} is missing: {s}\n",
                .{ spec.index, spec.count, paths.shard_receipt },
            );
            return error.MissingShard;
        },
        else => return err,
    };
    defer allocator.free(receipt_source);
    const receipt = try corpus_set.parseRangeShardReceipt(receipt_source);
    if (receipt.shard_index != @as(u64, @intCast(spec.index))) return error.ShardIndexMismatch;
    if (receipt.shard_count != @as(u64, @intCast(spec.count))) {
        std.debug.print(
            "range shard {d} was produced for {d} shards, not {d}\n",
            .{ spec.index, receipt.shard_count, spec.count },
        );
        return error.ShardCountMismatch;
    }
    if (!corpus_set.RawRange.eql(receipt.declared, declared)) {
        std.debug.print(
            "range shard {d} of {d} was produced for interval {d}:{d}\n",
            .{ spec.index, spec.count, receipt.declared.low, receipt.declared.high },
        );
        return error.RangeIntervalMismatch;
    }
    // The piece is recomputed from the declared interval and the shard count,
    // so a shard that claims another piece, an overlapping piece, or leaves a
    // gap is refused before any of it is trusted.
    if (!corpus_set.RawRange.eql(receipt.interval, interval)) {
        std.debug.print(
            "range shard {d} of {d} covers {d}:{d}, not {d}:{d}\n",
            .{
                spec.index,
                spec.count,
                receipt.interval.low,
                receipt.interval.high,
                interval.low,
                interval.high,
            },
        );
        return error.RangeSubrangeMismatch;
    }
    if (!std.mem.eql(u8, &receipt.descriptor_digest, &descriptor_digest)) {
        std.debug.print(
            "range shard {d} of {d} was produced from a different manifest, profile, or filter\n",
            .{ spec.index, spec.count },
        );
        return error.ShardDescriptorDigestMismatch;
    }
    if (receipt.descriptor_count != selection.count) return error.ShardDescriptorCountMismatch;
    const plan_digest = corpus_set.rangePlanDigest(.{
        .profile = options.profile,
        .filters = setFilters(parsed.filters),
        .descriptor_digest = descriptor_digest,
        .declared = declared,
        .shard_count = @intCast(spec.count),
        .shard_index = @intCast(spec.index),
        .subrange = interval,
    });
    if (!std.mem.eql(u8, &receipt.plan_digest, &plan_digest)) {
        std.debug.print(
            "range shard {d} of {d} does not hold the piece this manifest asks for\n",
            .{ spec.index, spec.count },
        );
        return error.ShardPlanMismatch;
    }

    const rows = options.root_dir.readFileAlloc(
        options.io,
        paths.rows_path,
        allocator,
        .limited(selection.count * corpus_set.range_row_bytes_max),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingShard,
        else => return err,
    };
    errdefer allocator.free(rows);
    if (rows.len == 0 or rows[rows.len - 1] != '\n') return error.ShardRowsMalformed;
    if (!std.mem.eql(u8, &receipt.rows_digest, &rowsDigest(rows))) {
        return error.ShardRowsDigestMismatch;
    }

    var record_count: u64 = 0;
    var lines = std.mem.splitScalar(u8, rows[0 .. rows.len - 1], '\n');
    for (selection.indices[0..selection.count]) |index| {
        const definition = matrix.at(index) orelse return error.ManifestCountMismatch;
        const line = lines.next() orelse return error.ShardRowCountMismatch;
        const row = try corpus_set.parseRangeRow(line);
        if (row.signature_index != index) return error.ShardRowOrderMismatch;
        if (row.range_low != interval.low or row.range_high != interval.high) {
            return error.RangeSubrangeMismatch;
        }
        if (row.records != interval.length()) return error.RangeRecordCountMismatch;
        const expected_artifact = try generatedArtifactPath(
            allocator,
            paths.records_root,
            index,
            definition.function.op,
        );
        defer allocator.free(expected_artifact);
        if (!std.mem.eql(u8, row.artifact, expected_artifact)) {
            return error.ShardRowArtifactMismatch;
        }
        record_count = std.math.add(u64, record_count, row.records) catch
            return error.RecordCountOverflow;
        // The proof that matters: this file holds exactly `[interval.low,
        // interval.high)` and nothing else. It runs before the destination is
        // touched, and the assembled file is proved again at replay.
        _ = try corpus_set.verifyRangeArtifact(
            options.io,
            options.root_dir,
            row.artifact,
            interval,
            definition.function.op,
            row.artifact_sha256,
        );
    }
    if (lines.next() != null) return error.ShardRowCountMismatch;
    if (record_count != receipt.record_count) return error.ShardRecordCountMismatch;
    return .{
        .paths = paths,
        .rows = rows,
        .interval = interval,
        .record_count = record_count,
    };
}

/// The assembling half of a range run. It refuses more shards than raw inputs,
/// proves every shard and every artifact, and only then writes the assembled
/// publication. The result is a `RANGE_COMPLETE` receipt whose tiling covers
/// the declared interval exactly once, which is what makes `exhaustive_binary32`
/// available to a reader and never before the tiling is proved.
fn assembleRangePublication(
    options: GeneratorOptions,
    parsed: ParsedArguments,
    matrix: *const campaigns.CampaignMatrix,
    selection: Selection,
    declared: corpus_set.RawRange,
    descriptor_digest: Digest,
    spec: ShardSpec,
) !void {
    if (spec.count == 0) return error.InvalidShardCount;
    const shard_count: u64 = @intCast(spec.count);
    // More shards than raw inputs would answer a shard with an empty interval,
    // which is a hole in the tiling rather than a partition of it.
    if (shard_count > declared.length()) return error.RangeShardTooFine;

    var paths = try RangePaths.init(options.allocator, parsed);
    defer paths.deinit(options.allocator);
    const shards = try options.allocator.alloc(LoadedRangeShard, spec.count);
    defer {
        for (shards) |*shard| shard.deinit(options.allocator);
        options.allocator.free(shards);
    }
    // `alloc` hands back undefined memory, and a shard that refused to load
    // owns nothing, so every slot starts empty rather than undefined.
    for (shards) |*shard| shard.* = .{};
    for (0..spec.count) |shard_index| {
        const interval = try corpus_set.splitRawRange(
            declared,
            shard_count,
            @intCast(shard_index),
        );
        shards[shard_index] = try readRangeShard(
            options,
            parsed,
            matrix,
            selection,
            declared,
            descriptor_digest,
            .{ .index = shard_index, .count = spec.count },
            interval,
        );
    }

    try clearAbortedRangeAssemble(options.allocator, options.io, options.root_dir, &paths);
    const run: RangeRun = .{
        .io = options.io,
        .allocator = options.allocator,
        .root_dir = options.root_dir,
        .paths = &paths,
    };
    try run.begin();
    const coverage = corpus_set.rangeCoverage(declared, true);
    const plan_digest = corpus_set.rangePlanDigest(.{
        .profile = options.profile,
        .filters = setFilters(parsed.filters),
        .descriptor_digest = descriptor_digest,
        .declared = declared,
        .shard_count = shard_count,
        .shard_index = 0,
        .subrange = declared,
    });
    var metadata: std.ArrayList(u8) = .empty;
    defer metadata.deinit(options.allocator);
    try appendRangeMetadataHeader(
        options.allocator,
        &metadata,
        options.profile,
        parsed,
        selection,
        declared,
        coverage,
        shard_count,
        descriptor_digest,
        plan_digest,
    );
    const sources = try options.allocator.alloc([]const u8, spec.count);
    defer options.allocator.free(sources);
    var record_count: u64 = 0;
    for (selection.indices[0..selection.count]) |index| {
        const definition = matrix.at(index) orelse return error.ManifestCountMismatch;
        const signature = try corpus_set.evaluatorSignature(&definition.function);
        for (sources) |*source| source.* = &.{};
        defer for (sources) |source| {
            if (source.len != 0) options.allocator.free(source);
        };
        for (0..spec.count) |shard_index| {
            sources[shard_index] = try generatedArtifactPath(
                options.allocator,
                shards[shard_index].paths.?.records_root,
                index,
                definition.function.op,
            );
        }
        const destination = try generatedArtifactPath(
            options.allocator,
            paths.records_root,
            index,
            definition.function.op,
        );
        defer options.allocator.free(destination);
        // The pieces are concatenated in shard order. Every piece was proved to
        // hold exactly its own subrange, and the ranges are contiguous,
        // disjoint, and ascending, so the file this produces holds the declared
        // interval in ascending raw order. The concatenation is then streamed
        // once more against that interval, so the receipt describes a file
        // that was checked rather than one that was assumed.
        const digest = try concatVerified(
            options.io,
            options.root_dir,
            sources,
            destination,
        );
        _ = try corpus_set.verifyRangeArtifact(
            options.io,
            options.root_dir,
            destination,
            declared,
            definition.function.op,
            digest,
        );
        // The row is the ordinary range row for the assembled interval, so no
        // count or digest in it is written by hand.
        try corpus_set.appendRangeRow(options.allocator, &metadata, .{
            .signature_index = index,
            .operation = definition.function.op,
            .manifest_status = definition.function.status,
            .oracle = definition.function.oracle,
            .evaluator = try corpus_set.evaluatorCategory(signature),
            .range_low = declared.low,
            .range_high = declared.high,
            .records = declared.length(),
            .input_argument = 0,
            .source_hash = corpus_set.rangeSourceDigest(),
            .artifact = destination,
            .artifact_sha256 = digest,
        });
        record_count = std.math.add(u64, record_count, declared.length()) catch
            return error.RecordCountOverflow;
    }
    try requireExactEntries(
        options.allocator,
        options.io,
        options.root_dir,
        .{
            .run_root = paths.run_root,
            .records_root = paths.records_root,
            .metadata_path = paths.metadata_path,
            .incomplete_marker = paths.incomplete_marker,
        },
        selection.count,
    );
    var metadata_digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(metadata.items, &metadata_digest, .{});
    try run.finish(metadata.items, .{
        .kind = .assembled,
        .declared = declared,
        .coverage = coverage,
        .descriptor_count = selection.count,
        .record_count = record_count,
        .shard_count = shard_count,
        .descriptor_digest = descriptor_digest,
        .plan_digest = plan_digest,
        .metadata_digest = metadata_digest,
    });
}

/// The only destination a range assembly may enter is one its own aborted run
/// left behind. A range root that already holds a `RANGE` or `RANGE_COMPLETE`
/// receipt is a finished range publication and is never a merge target, and an
/// ordinary `COMPLETE` in a range root is refused outright.
fn clearAbortedRangeAssemble(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    paths: *const RangePaths,
) !void {
    if (try pathExists(io, root_dir, paths.worker_receipt) or
        try pathExists(io, root_dir, paths.complete_receipt))
    {
        std.debug.print(
            "{s} already holds a completed range publication\n",
            .{paths.run_root},
        );
        return error.DestinationAlreadyPublished;
    }
    if (try pathExists(io, root_dir, paths.ordinary_complete)) {
        std.debug.print(
            "{s} holds an ordinary publication marker\n",
            .{paths.run_root},
        );
        return error.UnexpectedOrdinaryCompletion;
    }
    if (!try pathExists(io, root_dir, paths.run_root)) return;
    if (!try pathExists(io, root_dir, paths.incomplete_marker)) {
        std.debug.print(
            "{s} is not empty and carries no .incomplete marker\n",
            .{paths.run_root},
        );
        return error.DestinationNotEmpty;
    }
    try clearAbortedRun(allocator, io, root_dir, .{
        .run_root = paths.run_root,
        .records_root = paths.records_root,
        .metadata_path = paths.metadata_path,
        .incomplete_marker = paths.incomplete_marker,
    });
}

/// Where one descriptor's artifact bytes come from. A campaign enumerates the
/// descriptor's own tuples, a raw range enumerates the binary32 input domain,
/// and a reuse copies an artifact a completed publication already proved.
const ArtifactSource = union(enum) {
    campaign: *const campaigns.CampaignDefinition,
    raw_range: corpus_set.RawRange,
    reuse: corpus_set.ReusableEntry,
};

const ProducedArtifact = struct {
    record_count: u64,
    digest: Digest,
};

fn generateDefinition(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    metadata: *std.ArrayList(u8),
    records_root: []const u8,
    index: usize,
    definition: *const campaigns.CampaignDefinition,
    reuse: ?corpus_set.ReusableEntry,
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
        const artifact_source: ArtifactSource = if (reuse) |entry|
            .{ .reuse = entry }
        else
            .{ .campaign = definition };
        const produced = try writeArtifact(
            allocator,
            io,
            root_dir,
            artifact_path,
            function,
            artifact_source,
        );
        // A reused artifact holds the records its proved source row claims, so
        // the count is checked against the CURRENT campaign's cardinality
        // instead of being taken on trust.
        if (produced.record_count != cardinality) return error.RecordCountMismatch;
        artifact_hash = produced.digest;
        record_count = produced.record_count;
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

// The destination of a reused artifact. Each record is written as it is
// proved, so the copy costs one pass over the source and no second one over
// the destination, and the digest the caller gets back is the digest of the
// bytes that went into the file.
const ReuseCopySink = struct {
    writer: *std.Io.Writer,

    fn writeRecord(self: *ReuseCopySink, encoded: []const u8) !void {
        try self.writer.writeAll(encoded);
    }
};

/// Writes one descriptor's artifact and returns what it actually contains. The
/// returned count and digest describe the bytes on disk, never an intention,
/// so a row is always a fact about the file beside it.
fn writeArtifact(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    artifact_path: []const u8,
    function: corpus.Function,
    source: ArtifactSource,
) !ProducedArtifact {
    switch (source) {
        .reuse => |entry| {
            // A ZCDR record carries the operation name, the provenance, the
            // descriptors, the fields, and `max_ulp`. It carries no signature
            // index, so a descriptor the loader proved is a descriptor whose
            // records encode identically: the reuse is a copy and never a
            // re-encoding. The copy is proved as it is made, so the count and
            // the digest the row carries are facts about the bytes that were
            // written rather than about the file that was read, and a
            // destination that appears not to hold them never appears at all:
            // the copy is published atomically or not at all.
            var atomic = try root_dir.createFileAtomic(io, artifact_path, .{
                .make_path = true,
                .replace = true,
            });
            defer atomic.deinit(io);
            var write_buffer: [shard_copy_buffer_bytes]u8 = undefined;
            var writer = atomic.file.writer(io, &write_buffer);
            var sink: ReuseCopySink = .{ .writer = &writer.interface };
            const proof = try corpus_set.streamReusableArtifact(
                io,
                root_dir,
                entry.source_artifact,
                &function,
                entry.records,
                entry.digest,
                &sink,
                ReuseCopySink.writeRecord,
            );
            try writer.interface.flush();
            try atomic.file.sync(io);
            try atomic.replace(io);
            return .{ .record_count = proof.record_count, .digest = proof.digest };
        },
        .raw_range => |interval| {
            const expected = interval.length();
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
            // Raw inputs ascend, which is the canonical record order, so the
            // one-record lookahead in `appendRecord` releases every record as
            // it arrives and this loop holds O(1) records however long the
            // interval is.
            var raw = interval.low;
            while (raw < interval.high) : (raw += 1) {
                const field: corpus.CorpusField = .{ .float = .{
                    .format = .f,
                    .bits = raw,
                    .class = .none,
                } };
                const tuple = try campaigns.InputTuple.init(&.{field});
                const visit: campaigns.RecordVisit = .{
                    .function = function,
                    .arguments = tuple,
                    .expected_results = &.{},
                    .expected_status = .ok,
                    .max_ulp = function.max_ulp,
                };
                try visitRecord(&context, &visit);
            }
            if (context.record_count != expected) return error.RangeRecordCountMismatch;
            try finishRecords(&context);
            try writer.interface.flush();
            try atomic.file.sync(io);
            var digest: Digest = undefined;
            context.record_hasher.final(&digest);
            try atomic.replace(io);
            return .{ .record_count = context.record_count, .digest = digest };
        },
        .campaign => |definition| {
            const cardinality = definition.cardinality() catch |err| switch (err) {
                error.CampaignUnavailable => 0,
                else => return err,
            };
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
                .holding = switch (definition.data) {
                    .selected_cartesian => |spec| spec.tuples.len != 0,
                    .exact_bit_status => true,
                    else => false,
                },
            };
            defer context.deinit();
            try campaigns.visitDefinitionRecords(definition, &context, visitRecord);
            if (context.record_count != cardinality) return error.RecordCountMismatch;
            try finishRecords(&context);
            try writer.interface.flush();
            try atomic.file.sync(io);
            var digest: Digest = undefined;
            context.record_hasher.final(&digest);
            try atomic.replace(io);
            return .{ .record_count = context.record_count, .digest = digest };
        },
    }
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

// Ordered walkers keep one record back until its successor proves the order.
// Bounded named cases keep their complete encoded set for final sorting.
fn appendRecord(context: *RecordContext, bytes: []const u8) !void {
    context.record_count += 1;
    if (context.holding) return hold(context, bytes);
    if (context.held_back_length != 0) {
        const previous = try corpus.decodeCorpusRecord(
            context.held_back_encoded[0..context.held_back_length],
        );
        const current = try corpus.decodeCorpusRecord(bytes);
        try corpus.validateCorpusRecordOrder(&previous, &current);
        try publishRecord(context, context.held_back_encoded[0..context.held_back_length]);
    }
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

// ---------------------------------------------------------------------------
// Range planning, receipts, and reuse
// ---------------------------------------------------------------------------

// The range arguments are total, and every mistake a launch script can make is
// a rejection rather than a different domain.
test "f32 range arguments are parsed fail closed" {
    const whole = try parseArguments(&[_][]const u8{
        "corpus-generate", "out", "--f32-range=0:4294967296",
    });
    try std.testing.expectEqual(
        corpus_set.RawRange{ .low = 0, .high = corpus_set.max_raw_binary32_inputs },
        whole.range orelse return error.TestUnexpectedResult,
    );
    const window = try parseArguments(&[_][]const u8{
        "corpus-generate", "out", "--f32-range=4294967288:4294967296",
    });
    try std.testing.expectEqual(
        corpus_set.RawRange{ .low = 4294967288, .high = 4294967296 },
        window.range orelse return error.TestUnexpectedResult,
    );
    // No flag means no range: an ordinary publication never scans a domain
    // nobody asked for.
    try std.testing.expectEqual(
        @as(?corpus_set.RawRange, null),
        (try parseArguments(&[_][]const u8{ "corpus-generate", "out" })).range,
    );

    // A bound that cannot be read is a malformed interval, whatever produced
    // it.
    const invalid = [_][]const []const u8{
        &.{ "corpus-generate", "out", "--f32-range=0:4294967297" },
        &.{ "corpus-generate", "out", "--f32-range=4:4" },
        &.{ "corpus-generate", "out", "--f32-range=5:4" },
        &.{ "corpus-generate", "out", "--f32-range=-1:4" },
        &.{ "corpus-generate", "out", "--f32-range=01:4" },
        &.{ "corpus-generate", "out", "--f32-range=0:" },
        &.{ "corpus-generate", "out", "--f32-range=:4" },
        &.{ "corpus-generate", "out", "--f32-range=0" },
        &.{ "corpus-generate", "out", "--f32-range=" },
        &.{ "corpus-generate", "out", "--f32-range=0:4:8" },
    };
    for (invalid) |arguments| {
        try std.testing.expectError(error.InvalidRangeSpec, parseArguments(arguments));
    }

    // Conflicting intervals must not silently select either request.
    const contradicting = [_][]const u8{
        "corpus-generate", "out", "--f32-range=0:4", "--f32-range=0:8",
    };
    try std.testing.expectError(error.InvalidArguments, parseArguments(contradicting[0..]));

    // A range run and a reuse run name two different publications of two
    // different things, and a reuse needs the whole publication.
    const both = [_][]const u8{
        "corpus-generate", "out", "--f32-range=0:4", "--reuse-existing=old/generated",
    };
    try std.testing.expectError(error.InvalidArguments, parseArguments(both[0..]));
    const sharded_reuse = [_][]const u8{
        "corpus-generate", "out", "--reuse-existing=old/generated", "--shard=0/2",
    };
    try std.testing.expectError(error.InvalidArguments, parseArguments(sharded_reuse[0..]));
    const assembled_reuse = [_][]const u8{
        "corpus-generate", "out", "--reuse-existing=old/generated", "--assemble=2",
    };
    try std.testing.expectError(error.InvalidArguments, parseArguments(assembled_reuse[0..]));
    const reuse = try parseArguments(&[_][]const u8{
        "corpus-generate", "out", "--reuse-existing=old/generated",
    });
    try std.testing.expectEqualStrings("old/generated", reuse.reuse_run_root.?);
}

// The split is a pure function of the interval and the shard count, so a
// worker and an assembler agree without exchanging anything. It is checked at
// the full domain without enumerating a single raw input.
test "a range shard split tiles the interval it is given" {
    const whole: corpus_set.RawRange = .{
        .low = 0,
        .high = corpus_set.max_raw_binary32_inputs,
    };
    for ([_]u64{ 1, 3, 7, 1024 }) |shard_count| {
        var expected_low: u64 = whole.low;
        for (0..shard_count) |shard_index| {
            const piece = try corpus_set.splitRawRange(
                whole,
                shard_count,
                @intCast(shard_index),
            );
            // Contiguous, disjoint, ascending, and never empty.
            try std.testing.expectEqual(expected_low, piece.low);
            try std.testing.expect(piece.low < piece.high);
            expected_low = piece.high;
        }
        try std.testing.expectEqual(whole.high, expected_low);
    }
    const window: corpus_set.RawRange = .{ .low = 4294967288, .high = 4294967296 };
    try std.testing.expectEqual(
        window,
        try corpus_set.splitRawRange(window, 1, 0),
    );
    const halves = [_]corpus_set.RawRange{
        try corpus_set.splitRawRange(window, 2, 0),
        try corpus_set.splitRawRange(window, 2, 1),
    };
    try std.testing.expectEqual(window.low, halves[0].low);
    try std.testing.expectEqual(halves[0].high, halves[1].low);
    try std.testing.expectEqual(window.high, halves[1].high);

    // More shards than raw inputs would answer a shard with an empty interval,
    // which is a hole rather than a partition.
    try std.testing.expectError(
        error.RangeShardTooFine,
        corpus_set.splitRawRange(.{ .low = 0, .high = 4 }, 5, 0),
    );
    try std.testing.expectError(
        error.RangeShardTooFine,
        corpus_set.splitRawRange(.{ .low = 7, .high = 8 }, 2, 0),
    );
    try std.testing.expectError(
        error.RangeShardIndexOutOfRange,
        corpus_set.splitRawRange(.{ .low = 0, .high = 8 }, 2, 2),
    );
    try std.testing.expectError(
        error.InvalidRawRange,
        corpus_set.splitRawRange(.{ .low = 8, .high = 8 }, 1, 0),
    );
    try std.testing.expectError(
        error.InvalidRawRange,
        corpus_set.splitRawRange(.{ .low = 0, .high = corpus_set.max_raw_binary32_inputs + 1 }, 1, 0),
    );
}

// A stale plan is detected instead of accepted, so every component of the plan
// has to change its digest.
test "a range plan digest binds the profile, selection, interval, and piece" {
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    const declared: corpus_set.RawRange = .{ .low = 0, .high = 8 };
    const baseline_plan: corpus_set.RangePlan = .{
        .profile = test_profile,
        .filters = setFilters(.{ .operation = "abs" }),
        .descriptor_digest = try corpus_set.rangeDescriptorDigest(
            test_profile,
            &manifest,
            setFilters(.{ .operation = "abs" }),
        ),
        .declared = declared,
        .shard_count = 2,
        .shard_index = 0,
        .subrange = try corpus_set.splitRawRange(declared, 2, 0),
    };
    const baseline = corpus_set.rangePlanDigest(baseline_plan);
    // The same plan always digests the same way, in this process and the next.
    try std.testing.expectEqual(baseline, corpus_set.rangePlanDigest(baseline_plan));

    var other = baseline_plan;
    other.filters = setFilters(.{ .operation = "sqrt" });
    try std.testing.expect(!std.mem.eql(u8, &baseline, &corpus_set.rangePlanDigest(other)));

    other = baseline_plan;
    other.profile.cpu = "generic";
    try std.testing.expect(!std.mem.eql(u8, &baseline, &corpus_set.rangePlanDigest(other)));

    other = baseline_plan;
    other.declared = .{ .low = 0, .high = 16 };
    try std.testing.expect(!std.mem.eql(u8, &baseline, &corpus_set.rangePlanDigest(other)));

    other = baseline_plan;
    other.shard_count = 4;
    try std.testing.expect(!std.mem.eql(u8, &baseline, &corpus_set.rangePlanDigest(other)));

    other = baseline_plan;
    other.shard_index = 1;
    try std.testing.expect(!std.mem.eql(u8, &baseline, &corpus_set.rangePlanDigest(other)));

    other = baseline_plan;
    other.subrange = try corpus_set.splitRawRange(declared, 2, 1);
    try std.testing.expect(!std.mem.eql(u8, &baseline, &corpus_set.rangePlanDigest(other)));

    other = baseline_plan;
    other.descriptor_digest = [_]u8{0x5a} ** @sizeOf(corpus_set.Digest);
    try std.testing.expect(!std.mem.eql(u8, &baseline, &corpus_set.rangePlanDigest(other)));
}

// Eligibility is one binary32 input whatever the result format is, and the
// producer's selection and the loader's selection are the same list. A row that
// is eligible is provable from the manifest, so this is a statement about the
// manifest rather than a count.
test "a range selects one binary32 input and ignores the result format" {
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    const matrix = try campaigns.classifyManifest(&manifest);
    const filters = setFilters(.{ .operation = "abs" });
    const selection = try selectRangeDefinitions(&matrix, .{ .operation = "abs" });
    const loader = corpus_set.rangeSelection(&manifest, filters);
    try std.testing.expect(selection.count > 0);
    try std.testing.expectEqual(loader.count, selection.count);
    for (selection.indices[0..selection.count], 0..) |index, position| {
        try std.testing.expectEqual(loader.indices[position], index);
        const function = &matrix.definitions[index].function;
        try std.testing.expect(corpus_set.rangeEligible(function));
    }
    // `abs` has a half, a binary32, and a double row; only the binary32 input
    // row is in the range domain.
    try std.testing.expectEqual(@as(usize, 1), selection.count);

    // A double input is not a binary32 input, whatever it produces.
    try std.testing.expectError(
        error.EmptyRangeSelection,
        selectRangeDefinitions(&matrix, .{ .operation = "f32sqrtf64" }),
    );

    // A tag input is not a float input either.
    try std.testing.expectError(
        error.EmptyRangeSelection,
        selectRangeDefinitions(&matrix, .{ .operation = "nan" }),
    );
}

// The end-to-end claim: two tiny workers over one interval, an assembling run
// that proves the tiling, and a loader that reads the receipt the assembler
// wrote. Eight raw inputs are generated for one selected descriptor here.
test "tiny range workers assemble into a proved range publication" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const manifest = try corpus.parseManifest(corpus.manifest_text);

    try testRangeShard(scratch.dir, io, allocator, "corpus", "abs", 0, 8, 0, 2);
    try testRangeShard(scratch.dir, io, allocator, "corpus", "abs", 0, 8, 1, 2);
    try testRangeRun(scratch.dir, io, allocator, "corpus", "abs", 0, 8, "--assemble=2");

    const run_root = try testRangeRunRoot(allocator, "corpus", 0, 8);
    defer allocator.free(run_root);
    var path_buffer: [512]u8 = undefined;
    try testExpectPathExists(io, scratch.dir, try std.fmt.bufPrint(&path_buffer, "{s}/RANGE_COMPLETE", .{run_root}));
    // An assembled range publication is not an ordinary one: it never carries
    // the ordinary marker, in either spelling.
    try testExpectPathMissing(io, scratch.dir, try std.fmt.bufPrint(&path_buffer, "{s}/RANGE", .{run_root}));
    try testExpectPathMissing(io, scratch.dir, try std.fmt.bufPrint(&path_buffer, "{s}/COMPLETE", .{run_root}));
    try testExpectPathMissing(io, scratch.dir, try std.fmt.bufPrint(&path_buffer, "{s}/.incomplete", .{run_root}));

    var loaded = try corpus_set.loadRange(
        allocator,
        io,
        scratch.dir,
        run_root,
        &manifest,
        test_profile,
        setFilters(.{ .operation = "abs" }),
        .{ .low = 0, .high = 8 },
    );
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(corpus_set.RangeReceiptKind.assembled, loaded.receipt.kind);
    // Eight of the 2^32 raw inputs are proved, so the coverage claim is
    // partial and can never read as an exhaustive sweep.
    try std.testing.expectEqual(corpus_set.RangeCoverage.partial, loaded.receipt.coverage);
    try std.testing.expectEqual(loaded.set.count, loaded.receipt.descriptor_count);
    try std.testing.expectEqual(@as(u64, 8 * @as(u64, @intCast(loaded.set.count))), loaded.receipt.record_count);

    for (loaded.set.entries[0..loaded.set.count]) |*entry| {
        const count = try corpus_set.verifyRangeArtifact(
            io,
            scratch.dir,
            entry.artifact,
            .{ .low = 0, .high = 8 },
            entry.operation,
            entry.digest,
        );
        try std.testing.expectEqual(@as(u64, 8), count);
    }

    // The shards are still there: an assembling run retains its sources.
    try testExpectPathExists(io, scratch.dir, "corpus/range-shards/abs-all/0-8/0-of-2/RANGE_SHARD");
    try testExpectPathExists(io, scratch.dir, "corpus/range-shards/abs-all/0-8/1-of-2/RANGE_SHARD");

    // A finished range publication is never a merge target.
    try std.testing.expectError(
        error.DestinationAlreadyPublished,
        testRangeRun(scratch.dir, io, allocator, "corpus", "abs", 0, 8, "--assemble=2"),
    );
}

// A single worker over the whole interval is a complete range, not an
// exhaustive one, and a receipt that names another tiling or another shard
// count is refused instead of believed.
test "a range receipt is checked against the interval it claims" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    const filters = setFilters(.{ .operation = "abs" });

    try testRangeRun(scratch.dir, io, allocator, "corpus", "abs", 0, 8, "");
    const run_root = try testRangeRunRoot(allocator, "corpus", 0, 8);
    defer allocator.free(run_root);

    var loaded = try corpus_set.loadRange(
        allocator,
        io,
        scratch.dir,
        run_root,
        &manifest,
        test_profile,
        filters,
        .{ .low = 0, .high = 8 },
    );
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(corpus_set.RangeReceiptKind.worker, loaded.receipt.kind);
    try std.testing.expectEqual(corpus_set.RangeCoverage.partial, loaded.receipt.coverage);

    // The interval a reader is asked about is the interval the publication
    // must have produced.
    try std.testing.expectError(
        error.RangeIntervalMismatch,
        corpus_set.loadRange(
            allocator,
            io,
            scratch.dir,
            run_root,
            &manifest,
            test_profile,
            filters,
            .{ .low = 0, .high = 4 },
        ),
    );
    // An ordinary completion marker in a range root is a claim this tool never
    // makes, and it is refused rather than deleted.
    var path_buffer: [512]u8 = undefined;
    try writeAtomicSynced(io, scratch.dir, try std.fmt.bufPrint(&path_buffer, "{s}/COMPLETE", .{run_root}), "not a range\n");
    try std.testing.expectError(
        error.UnexpectedOrdinaryCompletion,
        corpus_set.loadRange(
            allocator,
            io,
            scratch.dir,
            run_root,
            &manifest,
            test_profile,
            filters,
            .{ .low = 0, .high = 8 },
        ),
    );
    try deleteIfPresent(io, scratch.dir, try std.fmt.bufPrint(&path_buffer, "{s}/COMPLETE", .{run_root}));

    // A receipt that claims another tiling is stale, and its plan digest no
    // longer reproduces.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try corpus_set.appendRangeReceipt(allocator, &text, .{
        .kind = .assembled,
        .declared = .{ .low = 0, .high = 8 },
        .coverage = corpus_set.rangeCoverage(.{ .low = 0, .high = 8 }, true),
        .descriptor_count = loaded.receipt.descriptor_count,
        .record_count = loaded.receipt.record_count,
        .shard_count = 3,
        .descriptor_digest = loaded.receipt.descriptor_digest,
        .plan_digest = loaded.receipt.plan_digest,
        .metadata_digest = loaded.receipt.metadata_digest,
    });
    try writeAtomicSynced(io, scratch.dir, try std.fmt.bufPrint(&path_buffer, "{s}/RANGE", .{run_root}), text.items);
    try std.testing.expectError(
        error.RangePlanMismatch,
        corpus_set.loadRange(
            allocator,
            io,
            scratch.dir,
            run_root,
            &manifest,
            test_profile,
            filters,
            .{ .low = 0, .high = 8 },
        ),
    );
}

// Every way a range input can be wrong is refused by the reader, and each one
// is a different answer rather than a generic failure. Four raw inputs are
// generated for one selected descriptor here.
test "a range reader refuses a missing, corrupt, or holed artifact" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    const filters = setFilters(.{ .operation = "abs" });

    try testRangeRun(scratch.dir, io, allocator, "corpus", "abs", 0, 4, "");
    const half_root = try testRangeRunRoot(allocator, "corpus", 0, 4);
    defer allocator.free(half_root);
    try testRangeRun(scratch.dir, io, allocator, "corpus", "abs", 0, 2, "");
    const quarter_root = try testRangeRunRoot(allocator, "corpus", 0, 2);
    defer allocator.free(quarter_root);

    var loaded = try corpus_set.loadRange(
        allocator,
        io,
        scratch.dir,
        half_root,
        &manifest,
        test_profile,
        filters,
        .{ .low = 0, .high = 4 },
    );
    defer loaded.deinit(allocator);
    const entry = &loaded.set.entries[0];
    const artifact = try allocator.dupe(u8, entry.artifact);
    defer allocator.free(artifact);
    const intact = try scratch.dir.readFileAlloc(io, artifact, allocator, .limited(1 << 20));
    defer allocator.free(intact);
    const quarter_entry = try testFirstArtifactPath(
        allocator,
        quarter_root,
        &manifest,
        filters,
    );
    defer allocator.free(quarter_entry);
    const quarter = try scratch.dir.readFileAlloc(io, quarter_entry, allocator, .limited(1 << 20));
    defer allocator.free(quarter);

    // A file that is not there is named, not silently short.
    try scratch.dir.deleteFile(io, artifact);
    try std.testing.expectError(
        error.RangeArtifactMissing,
        corpus_set.verifyRangeArtifact(
            io,
            scratch.dir,
            artifact,
            .{ .low = 0, .high = 4 },
            entry.operation,
            null,
        ),
    );

    // The lower half twice is a hole and an overlap at once, and it is the
    // only damage the reader cannot see in the record count: the file holds
    // exactly four records of `abs`, and the third is the raw input 0 where
    // the interval says 2. A file that merely held the wrong number of
    // records is answered further down.
    try testWriteConcat(io, scratch.dir, artifact, &.{ quarter_entry, quarter_entry });
    try std.testing.expectError(
        error.RangeRawInputMismatch,
        corpus_set.verifyRangeArtifact(
            io,
            scratch.dir,
            artifact,
            .{ .low = 0, .high = 4 },
            entry.operation,
            null,
        ),
    );

    // Change one result while retaining a valid frame and the raw input.
    // Structural proof must pass before the row's digest detects the change.
    var damaged = try allocator.dupe(u8, intact);
    defer allocator.free(damaged);
    const frame_length = std.mem.readInt(u32, damaged[5..9], .little);
    var record = try corpus.decodeCorpusRecord(damaged[0..frame_length]);
    record.results.values[0] = .{ .float = .{ .format = .f, .bits = 1, .class = .subnormal } };
    var frame_buffer: [corpus_set.record_buffer_capacity]u8 = undefined;
    const changed = try corpus.encodeCorpusRecord(&record, &frame_buffer);
    if (changed.len != frame_length) return error.TestUnexpectedResult;
    @memcpy(damaged[0..frame_length], changed);
    try writeAtomicSynced(io, scratch.dir, artifact, damaged);
    try std.testing.expectError(
        error.RangeArtifactDigestMismatch,
        corpus_set.verifyRangeArtifact(
            io,
            scratch.dir,
            artifact,
            .{ .low = 0, .high = 4 },
            entry.operation,
            entry.digest,
        ),
    );

    // A short file is a short interval, not a shorter claim.
    try writeAtomicSynced(io, scratch.dir, artifact, quarter);
    try std.testing.expectError(
        error.RangeRecordCountMismatch,
        corpus_set.verifyRangeArtifact(
            io,
            scratch.dir,
            artifact,
            .{ .low = 0, .high = 4 },
            entry.operation,
            null,
        ),
    );
}

// A shard that is interrupted, absent, or holding another piece of the interval
// is refused, and nothing is written while it is.
test "a range assembly refuses an interrupted, missing, or stale shard" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    const publication = "refused/ranges/abs-all/0-8";

    try testRangeShard(scratch.dir, io, allocator, "refused", "abs", 0, 8, 0, 2);
    try testRangeShard(scratch.dir, io, allocator, "refused", "abs", 0, 8, 1, 2);

    // An interrupted shard is not a shard, even when its records are present.
    try writeAtomicSynced(
        io,
        scratch.dir,
        "refused/range-shards/abs-all/0-8/0-of-2/.incomplete",
        "pending\n",
    );
    try std.testing.expectError(
        error.ShardIncomplete,
        testRangeRun(scratch.dir, io, allocator, "refused", "abs", 0, 8, "--assemble=2"),
    );
    try testExpectPathMissing(io, scratch.dir, publication ++ "/RANGE_COMPLETE");
    try deleteIfPresent(io, scratch.dir, "refused/range-shards/abs-all/0-8/0-of-2/.incomplete");

    // A missing shard stops the assembly before any write.
    try scratch.dir.deleteTree(io, "refused/range-shards/abs-all/0-8/1-of-2");
    try std.testing.expectError(
        error.MissingShard,
        testRangeRun(scratch.dir, io, allocator, "refused", "abs", 0, 8, "--assemble=2"),
    );
    try testExpectPathMissing(io, scratch.dir, publication ++ "/RANGE_COMPLETE");
    try testExpectPathMissing(io, scratch.dir, publication ++ "/metadata.txt");

    // More shards than raw inputs is a hole in the tiling, not a partition.
    try testRangeShard(scratch.dir, io, allocator, "refused", "abs", 0, 8, 1, 2);
    try std.testing.expectError(
        error.RangeShardTooFine,
        testRangeRun(scratch.dir, io, allocator, "refused", "abs", 0, 4, "--assemble=5"),
    );

    // A shard whose artifact holds the wrong piece of the interval is a seam,
    // and it is refused on the records rather than on the receipt. Each shard
    // directory holds its own records, so the two paths differ by the shard leaf
    // as well as by the piece their content claims.
    const filters = setFilters(.{ .operation = "abs" });
    const first = try testShardArtifactPath(
        allocator,
        "refused/range-shards/abs-all/0-8/0-of-2",
        &manifest,
        filters,
    );
    defer allocator.free(first);
    const second = try testShardArtifactPath(
        allocator,
        "refused/range-shards/abs-all/0-8/1-of-2",
        &manifest,
        filters,
    );
    defer allocator.free(second);
    const zero_bytes = try scratch.dir.readFileAlloc(io, first, allocator, .limited(1 << 20));
    defer allocator.free(zero_bytes);
    try writeAtomicSynced(io, scratch.dir, second, zero_bytes);
    try std.testing.expectError(
        error.RangeRawInputMismatch,
        testRangeRun(scratch.dir, io, allocator, "refused", "abs", 0, 8, "--assemble=2"),
    );
    try testExpectPathMissing(io, scratch.dir, publication ++ "/RANGE_COMPLETE");
}

/// Eight raw inputs for one selected descriptor: two pieces of four.
fn testRangeShard(
    root_dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    output_root: []const u8,
    operation: []const u8,
    low: u64,
    high: u64,
    index: usize,
    count: usize,
) !void {
    var operation_buffer: [64]u8 = undefined;
    const operation_flag = try std.fmt.bufPrint(
        &operation_buffer,
        "--operation={s}",
        .{operation},
    );
    var range_buffer: [64]u8 = undefined;
    const range_flag = try std.fmt.bufPrint(
        &range_buffer,
        "--f32-range={d}:{d}",
        .{ low, high },
    );
    var shard_buffer: [32]u8 = undefined;
    const shard_flag = try std.fmt.bufPrint(
        &shard_buffer,
        "--shard={d}/{d}",
        .{ index, count },
    );
    try testGenerate(root_dir, io, allocator, &.{
        "corpus-generate",
        output_root,
        operation_flag,
        range_flag,
        shard_flag,
    });
}

/// One whole-interval range run, or an assembling one when `mode_flag` names
/// an assembly.
fn testRangeRun(
    root_dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    output_root: []const u8,
    operation: []const u8,
    low: u64,
    high: u64,
    mode_flag: []const u8,
) !void {
    var operation_buffer: [64]u8 = undefined;
    const operation_flag = try std.fmt.bufPrint(
        &operation_buffer,
        "--operation={s}",
        .{operation},
    );
    var range_buffer: [64]u8 = undefined;
    const range_flag = try std.fmt.bufPrint(
        &range_buffer,
        "--f32-range={d}:{d}",
        .{ low, high },
    );
    if (mode_flag.len == 0) {
        try testGenerate(root_dir, io, allocator, &.{
            "corpus-generate",
            output_root,
            operation_flag,
            range_flag,
        });
        return;
    }
    try testGenerate(root_dir, io, allocator, &.{
        "corpus-generate",
        output_root,
        operation_flag,
        range_flag,
        mode_flag,
    });
}

fn testRangeRunRoot(
    allocator: std.mem.Allocator,
    output_root: []const u8,
    low: u64,
    high: u64,
) ![]u8 {
    const ranges_root = try std.fs.path.join(allocator, &.{ output_root, "ranges" });
    defer allocator.free(ranges_root);
    const leaf = try std.fmt.allocPrint(allocator, "{d}-{d}", .{ low, high });
    defer allocator.free(leaf);
    return std.fs.path.join(allocator, &.{ ranges_root, "abs-all", leaf });
}

/// The artifact of the first selected descriptor inside one range shard
/// directory. The descriptor index is derived from the manifest and the
/// filters, because the file name carries the index and a test that guessed
/// it would be testing a path that does not exist.
fn testShardArtifactPath(
    allocator: std.mem.Allocator,
    shard_root: []const u8,
    manifest: *const corpus.Manifest,
    filters: corpus_set.Filters,
) ![]u8 {
    const selection = corpus_set.rangeSelection(manifest, filters);
    if (selection.count == 0) return error.TestUnexpectedResult;
    const index = selection.indices[0];
    const name = try artifactFileName(
        allocator,
        index,
        manifest.function_values[index].op,
    );
    defer allocator.free(name);
    return std.fmt.allocPrint(allocator, "{s}/records/{s}", .{ shard_root, name });
}

fn testFirstArtifactPath(
    allocator: std.mem.Allocator,
    run_root: []const u8,
    manifest: *const corpus.Manifest,
    filters: corpus_set.Filters,
) ![]u8 {
    const selection = corpus_set.rangeSelection(manifest, filters);
    if (selection.count == 0) return error.TestUnexpectedResult;
    const index = selection.indices[0];
    const records_root = try std.fmt.allocPrint(allocator, "{s}/records", .{run_root});
    defer allocator.free(records_root);
    const name = try artifactFileName(
        allocator,
        index,
        manifest.function_values[index].op,
    );
    defer allocator.free(name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ records_root, name });
}

// Joins files into one, reading every part before the destination is written
// so a part may also BE the destination.
fn testWriteConcat(
    io: std.Io,
    dir: std.Io.Dir,
    destination: []const u8,
    parts: []const []const u8,
) !void {
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(std.testing.allocator);
    for (parts) |part| {
        const bytes = try dir.readFileAlloc(
            io,
            part,
            std.testing.allocator,
            .limited(1 << 20),
        );
        defer std.testing.allocator.free(bytes);
        try combined.appendSlice(std.testing.allocator, bytes);
    }
    try writeAtomicSynced(io, dir, destination, combined.items);
}

// Reuse copies what a completed publication already proved and rebuilds
// everything else through the normal producer. Both formats share the same
// metadata campaign, so only their numerical records can distinguish them.
test "a reused publication rebuilds its rows and keeps its source" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    const source_root = "corpus/generated/probes/algebraConjugate-all";
    const target_root = "reused/generated/probes/algebraConjugate-all";

    try testGenerate(scratch.dir, io, allocator, &.{
        "corpus-generate", "corpus", "--operation=algebraConjugate",
    });
    var source = try corpus_set.load(allocator, io, scratch.dir, source_root, &manifest, test_profile);
    defer source.deinit(allocator);
    const source_artifact = try allocator.dupe(u8, source.entries[0].artifact);
    defer allocator.free(source_artifact);
    const source_bytes = try scratch.dir.readFileAlloc(
        io,
        source_artifact,
        allocator,
        .limited(1 << 20),
    );
    defer allocator.free(source_bytes);

    var flag_buffer: [128]u8 = undefined;
    const reuse_flag = try testReuseFlag(&flag_buffer, source_root);
    try testGenerate(scratch.dir, io, allocator, &.{
        "corpus-generate",
        "reused",
        "--operation=algebraConjugate",
        reuse_flag,
    });
    // A republished artifact must survive a fresh reader's full record and
    // digest proof, not only its metadata header. This catches buffered bytes
    // that never reached the atomic file before replacement.
    var target = try corpus_set.loadReusable(allocator, io, scratch.dir, target_root, &manifest, test_profile, .{
        .operation = "algebraConjugate",
        .format = null,
    });
    defer target.deinit(allocator);
    for (source.entries[0..source.count]) |entry| {
        const proved = target.entries[entry.signature_index];
        try std.testing.expectEqual(entry.records, proved.records);
        try std.testing.expectEqualSlices(u8, &entry.digest, &proved.digest);
    }

    // The source is never written to: it still carries its own completion
    // marker and its own records, byte for byte.
    try testExpectPathExists(io, scratch.dir, source_root ++ "/COMPLETE");
    const kept = try scratch.dir.readFileAlloc(
        io,
        source_artifact,
        allocator,
        .limited(1 << 20),
    );
    defer allocator.free(kept);
    try std.testing.expectEqualStrings(source_bytes, kept);

    // Reuse is explicit and its source is never the destination.
    try std.testing.expectError(
        error.ReuseSourceIsDestination,
        testGenerate(scratch.dir, io, allocator, &.{
            "corpus-generate",
            "corpus",
            "--operation=algebraConjugate",
            "--reuse-existing=" ++ source_root,
        }),
    );

    // A source that is not a completed publication is not a source.
    var absent_buffer: [128]u8 = undefined;
    const absent_flag = try testReuseFlag(&absent_buffer, "absent/generated");
    try std.testing.expectError(
        error.MissingCompletion,
        testGenerate(scratch.dir, io, allocator, &.{
            "corpus-generate",
            "again",
            "--operation=algebraConjugate",
            absent_flag,
        }),
    );
    try testExpectPathMissing(io, scratch.dir, "again/generated");
}

test "a late cancellation tuple precedes an already ascending case prefix" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    const root = "corpus/generated/probes/complexAdd-f";
    try testGenerate(scratch.dir, io, allocator, &.{
        "corpus-generate", "corpus", "--operation=complexAdd", "--format=f",
    });
    // A fresh consumer proves all framing, descriptors, counts, ordering and
    // digests. The all-zero tuple comes after two ascending cases in the
    // campaign but must be the first tuple in the published artifact.
    var proved = try corpus_set.loadReusable(allocator, io, scratch.dir, root, &manifest, test_profile, .{
        .operation = "complexAdd",
        .format = .f,
    });
    defer proved.deinit(allocator);
    var publication = try corpus_set.load(allocator, io, scratch.dir, root, &manifest, test_profile);
    defer publication.deinit(allocator);
    const bytes = try scratch.dir.readFileAlloc(io, publication.entries[0].artifact, allocator, .limited(1 << 20));
    defer allocator.free(bytes);
    const length = std.mem.readInt(u32, bytes[5..9], .little);
    const first = try corpus.decodeCorpusRecord(bytes[0..length]);
    for (first.arguments.slice()) |field| try std.testing.expectEqual(@as(u64, 0), field.float.bits);
    try std.testing.expectEqual(@as(usize, 2), first.results.slice().len);
    for (first.results.slice()) |field| try std.testing.expectEqual(@as(u64, 0), field.float.bits);
}

fn testReuseFlag(buffer: []u8, source_run_root: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "--reuse-existing={s}", .{source_run_root});
}

// One publication and every way a reuse source can be wrong. Eighteen named
// tuples for one descriptor are generated here and then only damaged: a row
// that is gone, a descriptor that moved, records that carry another
// descriptor, records out of the canonical order, a count the row does not
// claim, a tail one record short, a file that is not there, and a
// destination that is the source under another name. Every damage is written
// back with a metadata row and a completion marker that agree with it, so what
// each case measures is the structural proof and not a stale digest.
test "a reuse source is refused unless its rows and records still match" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    const source_root = "corpus/generated/probes/algebraConjugate-f";
    const filters = setFilters(.{ .operation = "algebraConjugate", .format = .f });

    try testGenerate(scratch.dir, io, allocator, &.{
        "corpus-generate", "corpus", "--operation=algebraConjugate", "--format=f",
    });
    const fixture = try testReuseFixture(allocator, io, scratch.dir, source_root);
    defer fixture.deinit(allocator);

    // A descriptor that moved. The row and the records still agree with each
    // other, and the manifest no longer agrees with either, so the source
    // digest cannot be rebuilt out of the current descriptors.
    {
        var moved = try corpus.parseManifest(corpus.manifest_text);
        moved.function_values[fixture.signature_index].max_ulp = 1;
        try std.testing.expectError(
            error.DescriptorDigestMismatch,
            corpus_set.loadReusable(
                allocator,
                io,
                scratch.dir,
                source_root,
                &moved,
                test_profile,
                filters,
            ),
        );
    }

    // A row that is gone, under a header that still counts it. The count the
    // header claims and the rows the source holds are two facts, and a source
    // that does not agree with itself is not a source.
    {
        const damaged = try allocator.dupe(u8, fixture.metadata);
        defer allocator.free(damaged);
        const header_end =
            (std.mem.indexOf(u8, damaged, "\n\n") orelse return error.TestUnexpectedResult) + 2;
        try writeAtomicSynced(io, scratch.dir, fixture.artifact, fixture.records);
        try testSealReuseSource(
            io,
            scratch.dir,
            allocator,
            source_root,
            damaged[0..header_end],
        );
        try std.testing.expectError(
            error.IncompleteSelection,
            corpus_set.loadReusable(
                allocator,
                io,
                scratch.dir,
                source_root,
                &manifest,
                test_profile,
                filters,
            ),
        );
    }
    try testRestoreReuseSource(io, scratch.dir, allocator, source_root, &fixture);

    // A record that carries a tolerance the manifest does not claim, under a
    // digest the row agrees with. Every record decodes, the count is the one
    // the row claims, and the order is the canonical one; only the numbers
    // inside the records are another descriptor's.
    {
        const damaged = try testReuseRecords(allocator, fixture.records, .changed_descriptor);
        defer allocator.free(damaged);
        try testWriteReuseSource(
            io,
            scratch.dir,
            allocator,
            source_root,
            fixture.metadata,
            fixture.artifact,
            damaged,
        );
        try std.testing.expectError(
            error.ReuseRecordDescriptorMismatch,
            corpus_set.loadReusable(
                allocator,
                io,
                scratch.dir,
                source_root,
                &manifest,
                test_profile,
                filters,
            ),
        );
    }
    try testRestoreReuseSource(io, scratch.dir, allocator, source_root, &fixture);

    // The last two records the other way round. Every record is the current
    // descriptor's and the count is right, so only the order is left to catch
    // it.
    {
        const damaged = try testReuseRecords(allocator, fixture.records, .swapped);
        defer allocator.free(damaged);
        try testWriteReuseSource(
            io,
            scratch.dir,
            allocator,
            source_root,
            fixture.metadata,
            fixture.artifact,
            damaged,
        );
        try std.testing.expectError(
            error.UnsortedCorpusRecord,
            corpus_set.loadReusable(
                allocator,
                io,
                scratch.dir,
                source_root,
                &manifest,
                test_profile,
                filters,
            ),
        );
    }
    try testRestoreReuseSource(io, scratch.dir, allocator, source_root, &fixture);

    // Remove one complete record. Descriptors, framing and order still pass,
    // but the artifact no longer holds the record count its row claims.
    {
        const damaged = try testReuseRecords(allocator, fixture.records, .missing_record);
        defer allocator.free(damaged);
        try testWriteReuseSource(
            io,
            scratch.dir,
            allocator,
            source_root,
            fixture.metadata,
            fixture.artifact,
            damaged,
        );
        try std.testing.expectError(
            error.ReuseRecordCountMismatch,
            corpus_set.loadReusable(
                allocator,
                io,
                scratch.dir,
                source_root,
                &manifest,
                test_profile,
                filters,
            ),
        );
    }
    try testRestoreReuseSource(io, scratch.dir, allocator, source_root, &fixture);

    // A tail one byte short of the record it starts. Every record before it
    // decodes, the count the row claims is the count the file holds, and the
    // row is told the truth about the bytes, so only the length the last
    // frame declares is left to catch it.
    {
        const damaged = try testReuseRecords(allocator, fixture.records, .truncated_tail);
        defer allocator.free(damaged);
        try testWriteReuseSource(
            io,
            scratch.dir,
            allocator,
            source_root,
            fixture.metadata,
            fixture.artifact,
            damaged,
        );
        try std.testing.expectError(
            error.TruncatedRecord,
            corpus_set.loadReusable(
                allocator,
                io,
                scratch.dir,
                source_root,
                &manifest,
                test_profile,
                filters,
            ),
        );
    }
    try testRestoreReuseSource(io, scratch.dir, allocator, source_root, &fixture);

    // A file that is not there is named, not believed.
    try scratch.dir.deleteFile(io, fixture.artifact);
    try std.testing.expectError(
        error.ReuseArtifactMissing,
        corpus_set.loadReusable(
            allocator,
            io,
            scratch.dir,
            source_root,
            &manifest,
            test_profile,
            filters,
        ),
    );
    try testRestoreReuseSource(io, scratch.dir, allocator, source_root, &fixture);

    // A destination that is the source under another name. The link target
    // spells the same directory with a `..` in it and a `.` beside it, which
    // is what a name comparison cannot see and an identity can. The refusal
    // comes before the destination is created, so the source still holds its
    // completion marker, its metadata, and its records afterwards.
    try scratch.dir.createDirPath(io, "alias/generated/probes");
    try scratch.dir.symLink(
        io,
        "../../../corpus/generated/probes/./algebraConjugate-f",
        "alias/generated/probes/algebraConjugate-f",
        .{ .is_directory = true },
    );
    var flag_buffer: [128]u8 = undefined;
    const reuse_flag = try testReuseFlag(&flag_buffer, source_root);
    try std.testing.expectError(
        error.ReuseSourceIsDestination,
        testGenerate(scratch.dir, io, allocator, &.{
            "corpus-generate",
            "alias",
            "--operation=algebraConjugate",
            "--format=f",
            reuse_flag,
        }),
    );
    try testExpectReuseSourceIntact(allocator, io, scratch.dir, source_root, fixture);

    // A destination inside the source, under a name of its own, is the same
    // fault and is refused the same way: nothing is written under the source.
    try std.testing.expectError(
        error.ReuseDestinationInsideSource,
        testGenerate(scratch.dir, io, allocator, &.{
            "corpus-generate",
            source_root,
            "--operation=algebraConjugate",
            "--format=f",
            reuse_flag,
        }),
    );
    try testExpectPathMissing(io, scratch.dir, source_root ++ "/generated");
    try testExpectReuseSourceIntact(allocator, io, scratch.dir, source_root, fixture);
}

// The four things a damage can be to an artifact. Each one is applied to whole
// record frames, so the reader never sees a hole in the middle of a record.
const ReuseDamage = enum {
    /// The first record re-encoded with a tolerance the manifest does not
    /// claim. The other records, and the order, are untouched.
    changed_descriptor,
    /// The last two records exchanged. Every record is still the current
    /// descriptor's and the count is still the row's.
    swapped,
    /// The last complete record removed, without corrupting framing or order.
    missing_record,
    /// The last record one byte short of the length its own header declares.
    truncated_tail,
};

const ReuseFixture = struct {
    artifact: []u8,
    metadata: []u8,
    records: []u8,
    signature_index: usize,

    fn deinit(self: ReuseFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.artifact);
        allocator.free(self.metadata);
        allocator.free(self.records);
    }
};

fn testReuseFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    run_root: []const u8,
) !ReuseFixture {
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    var set = try corpus_set.load(allocator, io, dir, run_root, &manifest, test_profile);
    defer set.deinit(allocator);
    const artifact = try allocator.dupe(u8, set.entries[0].artifact);
    errdefer allocator.free(artifact);
    const metadata = try testReadFile(allocator, io, dir, run_root, "metadata.txt");
    errdefer allocator.free(metadata);
    const records = try dir.readFileAlloc(
        io,
        set.entries[0].artifact,
        allocator,
        .limited(1 << 20),
    );
    return .{
        .artifact = artifact,
        .metadata = metadata,
        .records = records,
        .signature_index = set.entries[0].signature_index,
    };
}

// A source that is internally consistent: the records the reader will find,
// the row told the truth about them, and the completion marker told the truth
// about the row. Without the last two, a damage would be refused by a digest
// the reader checks first, which is not the proof under test.
fn testWriteReuseSource(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    run_root: []const u8,
    metadata: []const u8,
    artifact: []const u8,
    records: []const u8,
) !void {
    try writeAtomicSynced(io, dir, artifact, records);

    const row = try allocator.dupe(u8, metadata);
    defer allocator.free(row);
    var artifact_digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(records, &artifact_digest, .{});
    const digest_hex = std.fmt.bytesToHex(artifact_digest, .lower);
    const field = "artifact_sha256=";
    const start = std.mem.indexOf(u8, row, field) orelse return error.TestUnexpectedResult;
    const digest_start = start + field.len;
    if (row.len - digest_start < digest_hex.len) return error.TestUnexpectedResult;
    @memcpy(row[digest_start..][0..digest_hex.len], digest_hex[0..]);
    try testSealReuseSource(io, dir, allocator, run_root, row);
}

// The completion marker is the SHA-256 of the metadata beside it, so metadata
// written by hand is signed by hand. A case that changes the metadata without
// touching the rows still needs this, or it would be refused by the marker
// rather than by the thing under test.
fn testSealReuseSource(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    run_root: []const u8,
    metadata: []const u8,
) !void {
    const metadata_path = try std.fmt.allocPrint(allocator, "{s}/metadata.txt", .{run_root});
    defer allocator.free(metadata_path);
    try writeAtomicSynced(io, dir, metadata_path, metadata);

    var metadata_digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(metadata, &metadata_digest, .{});
    const metadata_hex = std.fmt.bytesToHex(metadata_digest, .lower);
    var text: [192]u8 = undefined;
    const complete = try std.fmt.bufPrint(
        &text,
        "oracle-generate complete\nmetadata_sha256={s}\n",
        .{metadata_hex[0..]},
    );
    const complete_path = try std.fmt.allocPrint(allocator, "{s}/COMPLETE", .{run_root});
    defer allocator.free(complete_path);
    try writeAtomicSynced(io, dir, complete_path, complete);
}

// Puts the source back the way the producer left it, so one damage is measured
// against the real thing and not against another damage.
fn testRestoreReuseSource(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    run_root: []const u8,
    fixture: *const ReuseFixture,
) !void {
    try testWriteReuseSource(
        io,
        dir,
        allocator,
        run_root,
        fixture.metadata,
        fixture.artifact,
        fixture.records,
    );
}

fn testExpectReuseSourceIntact(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    run_root: []const u8,
    fixture: ReuseFixture,
) !void {
    var path_buffer: [512]u8 = undefined;
    try testExpectPathExists(io, dir, try std.fmt.bufPrint(&path_buffer, "{s}/COMPLETE", .{run_root}));
    const metadata = try testReadFile(allocator, io, dir, run_root, "metadata.txt");
    defer allocator.free(metadata);
    try std.testing.expectEqualStrings(fixture.metadata, metadata);
    const records = try dir.readFileAlloc(io, fixture.artifact, allocator, .limited(1 << 20));
    defer allocator.free(records);
    try std.testing.expectEqualStrings(fixture.records, records);
}

fn testReuseRecords(
    allocator: std.mem.Allocator,
    records: []const u8,
    damage: ReuseDamage,
) ![]u8 {
    var frames: std.ArrayList([]const u8) = .empty;
    defer frames.deinit(allocator);
    // A frame carries its own length, so the records are cut out of the file
    // by what they declare and no damage lands inside one.
    var offset: usize = 0;
    while (offset < records.len) {
        if (records.len - offset < 9) return error.TestUnexpectedResult;
        const length = std.mem.readInt(u32, records[offset + 5 ..][0..4], .little);
        if (length < 9 or length > records.len - offset) return error.TestUnexpectedResult;
        try frames.append(allocator, records[offset..][0..length]);
        offset += length;
    }
    if (frames.items.len < 2) return error.TestUnexpectedResult;

    var damaged: std.ArrayList(u8) = .empty;
    errdefer damaged.deinit(allocator);
    switch (damage) {
        .changed_descriptor => {
            var frame_buffer: [corpus_set.record_buffer_capacity]u8 = undefined;
            for (frames.items, 0..) |frame, index| {
                if (index != 0) {
                    try damaged.appendSlice(allocator, frame);
                    continue;
                }
                var record = try corpus.decodeCorpusRecord(frame);
                record.max_ulp += 1;
                try damaged.appendSlice(
                    allocator,
                    try corpus.encodeCorpusRecord(&record, &frame_buffer),
                );
            }
        },
        .swapped => {
            for (frames.items[0 .. frames.items.len - 2]) |frame| {
                try damaged.appendSlice(allocator, frame);
            }
            try damaged.appendSlice(allocator, frames.getLast());
            try damaged.appendSlice(allocator, frames.items[frames.items.len - 2]);
        },
        .missing_record => {
            for (frames.items[0 .. frames.items.len - 1]) |frame| {
                try damaged.appendSlice(allocator, frame);
            }
        },
        .truncated_tail => {
            for (frames.items[0 .. frames.items.len - 1]) |frame| {
                try damaged.appendSlice(allocator, frame);
            }
            const last = frames.getLast();
            try damaged.appendSlice(allocator, last[0 .. last.len - 1]);
        },
    }
    return damaged.toOwnedSlice(allocator);
}
