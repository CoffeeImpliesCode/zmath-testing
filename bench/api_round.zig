//! The zmath API round executable.
//!
//! It owns bundle registration, selection, the measurement boundary and the
//! JSONL protocol. It owns no case body: the six bundles under `bench/` each
//! publish `pub const cases = [_]common.Case{...}` and are reached only through
//! the `common.Case` contract in `api_round_common.zig`.
//!
//! Two modes share one line schema so a plan and a measurement of the same
//! selection compare field for field.
//!
//! `--list` prints metadata only. It performs ZERO numerical execution: no
//! `invoke` is called, no kernel runs, and the f32 charge plan is read from
//! the case table. That is what lets the caller prove a global profiling
//! budget before spending any of it.
//!
//! `--calls` overrides every selected case's own `Case.calls`. There is no
//! adaptive warm-up anywhere: the invocation count is part of the protocol,
//! and the measurement boundary opens once before the loop and closes once
//! after it, never per call.
//!
//! JSONL, one object per line:
//!
//!   {"kind":"build","protocol":1,"target":..,"cpu":..,"optimize":..,
//!    "approved_profile":..,"harness_digest":".."}
//!   {"kind":"case"|"row","name":..,"namespace":..,"bundle":..,"calls":N,
//!    "f32":[{"operation":..,"count":N}],"f32_total":N,
//!    "input_digest":"..","elapsed_ns":N,"checksum":".."}
//!   {"kind":"summary","mode":..,"cases":N,"calls_total":N,"f32_total":N,
//!    "f32":[{"operation":..,"count":N}],"bundles":[..]}
//!
//! A `case` line carries no timing field; a `row` line carries `elapsed_ns`
//! and `checksum`. Nothing else varies between the two modes.

const std = @import("std");
const common = @import("api_round_common.zig");
const target_mode = @import("active_target_mode");

const leaf = @import("api_round_leaf.zig");
const lanes = @import("api_round_lanes.zig");
const values = @import("api_round_values.zig");
const aggregates = @import("api_round_aggregates.zig");
const geometry = @import("api_round_geometry.zig");
const algebra = @import("api_round_algebra.zig");

/// Bumped whenever a JSONL field changes meaning. The runner refuses a pair
/// of executables that do not agree on it.
pub const protocol_version: u32 = 1;

/// The largest `--calls` any selection may ask for.
pub const calls_cap: u32 = 4096;

/// The most names one `--case` cohort may carry.
///
/// A cohort names a small target set so a round can measure it at a useful
/// call count, so this is a bound and not a budget: the names live in an
/// inline array of slices into the argument vector, which keeps a selection
/// free of dynamic allocation, and a longer request is refused rather than
/// truncated into a cohort nobody asked for. Selecting a bundle whole is what
/// `--slice` is for. Membership and the unpublished-name check are linear scans
/// over the published case table outside every measurement boundary, so this
/// bound costs nothing a measurement can see.
pub const case_names_cap: usize = 64;

const Bundle = struct {
    /// Bundle label, distinct from `Case.namespace`, which names the public
    /// module owner instead.
    label: []const u8,
    cases: []const common.Case,
};

pub const bundles = [_]Bundle{
    .{ .label = "leaf", .cases = &leaf.cases },
    .{ .label = "lanes", .cases = &lanes.cases },
    .{ .label = "values", .cases = &values.cases },
    .{ .label = "aggregates", .cases = &aggregates.cases },
    .{ .label = "geometry", .cases = &geometry.cases },
    .{ .label = "algebra", .cases = &algebra.cases },
};

fn caseCount() usize {
    comptime var total: usize = 0;
    inline for (bundles) |bundle| total += bundle.cases.len;
    return total;
}

const total_cases = caseCount();

const NamedCase = struct { name: []const u8, bundle: []const u8 };

fn namedLessThan(_: void, a: NamedCase, b: NamedCase) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

// Every one of these is a compile error rather than a runtime surprise, and
// none of them can be reached from `--list` silently. A benchmark that
// double-charged a kernel would corrupt the global profiling ledger, and a
// duplicated name would make the runner's strict comparison meaningless.
comptime {
    // Thousands of cases times a sort and a per-case charge scan is far past
    // Zig's default 1000 branch evaluation budget, and the budget is what
    // stops an accidental quadratic from hanging the build instead of failing.
    @setEvalBranchQuota(50_000_000);
    var named: [total_cases]NamedCase = undefined;
    var at: usize = 0;
    for (bundles) |bundle| {
        if (bundle.cases.len == 0) {
            @compileError("api_round: bundle " ++ bundle.label ++ " publishes no cases");
        }
        for (bundle.cases) |entry| {
            named[at] = .{ .name = entry.name, .bundle = bundle.label };
            at += 1;
            if (entry.name.len == 0) {
                @compileError("api_round: a case name is empty");
            }
            if (!common.isNamespace(entry.namespace)) {
                @compileError(
                    "api_round: case " ++ entry.name ++
                        " has namespace " ++ entry.namespace ++
                        ", which is not a canonical public owner",
                );
            }
            if (entry.calls == 0 or entry.calls > calls_cap) {
                @compileError("api_round: case " ++ entry.name ++ " has a call count outside 1..calls_cap");
            }
            for (entry.f32, 0..) |charge, charge_index| {
                if (!common.isChargeOperation(charge.operation)) {
                    @compileError(
                        "api_round: case " ++ entry.name ++ " charges malformed operation " ++
                            charge.operation,
                    );
                }
                if (charge.count == 0) {
                    @compileError(
                        "api_round: case " ++ entry.name ++ " charges " ++ charge.operation ++
                            " with a zero count",
                    );
                }
                for (entry.f32[0..charge_index]) |earlier| {
                    if (std.mem.eql(u8, earlier.operation, charge.operation)) {
                        @compileError(
                            "api_round: case " ++ entry.name ++ " charges " ++ charge.operation ++
                                " more than once",
                        );
                    }
                }
            }
        }
    }
    if (at != total_cases) @compileError("api_round: bundle case counts do not add up");
    std.mem.sort(NamedCase, &named, {}, namedLessThan);
    for (named[1..], 1..) |entry, index| {
        if (std.mem.eql(u8, named[index - 1].name, entry.name)) {
            @compileError(
                "api_round: case name " ++ entry.name ++ " is published by both " ++
                    named[index - 1].bundle ++ " and " ++ entry.bundle,
            );
        }
    }
}

const harness_sources = [_][]const u8{
    @embedFile("api_round_common.zig"),
    @embedFile("api_round_leaf.zig"),
    @embedFile("api_round_lanes.zig"),
    @embedFile("api_round_values.zig"),
    @embedFile("api_round_aggregates.zig"),
    @embedFile("api_round_geometry.zig"),
    @embedFile("api_round_algebra.zig"),
    @embedFile("api_round.zig"),
};

/// Identifies the harness that produced a row. Two executables with the same
/// digest were built from the same case sources, so a checksum difference
/// between them is a runtime difference and not an edit.
///
/// The fold runs once per process, outside every measurement boundary. It is
/// deliberately not `comptime`: these sources are large enough that hashing
/// them at compile time buys nothing and spends an evaluation budget the case
/// validation above needs for itself.
fn computeHarnessDigest() u64 {
    var acc = common.hash_seed;
    for (harness_sources) |source| {
        acc = common.mix(acc, @as(u64, source.len));
        for (source) |byte| acc = common.mix(acc, @as(u64, byte));
    }
    return common.mix(acc, protocol_version);
}

/// The case names one selection asked for by name.
///
/// An empty selection is every published case in the selected bundles, so a
/// round that names nothing measures its whole selection. A repeated name is
/// harmless: selection asks whether a published case's name equals one of the
/// requested names, so one case is selected once, published once and charged
/// once however often it was named.
const CaseSelection = struct {
    names: [case_names_cap][]const u8 = @splat(""),
    len: usize = 0,

    /// Records one `--case=name`. Past `case_names_cap` names the request is
    /// refused in the same way as any other bad argument.
    fn add(self: *CaseSelection, name: []const u8) error{InvalidArguments}!void {
        if (self.len == case_names_cap) return error.InvalidArguments;
        self.names[self.len] = name;
        self.len += 1;
    }

    /// Whether a published case belongs to this selection.
    fn selects(self: *const CaseSelection, name: []const u8) bool {
        for (self.names[0..self.len]) |wanted| {
            if (std.mem.eql(u8, wanted, name)) return true;
        }
        // No name requested is every case; a name that matched nothing is none.
        return self.len == 0;
    }

    /// The requested names no case in the selected bundles publishes.
    ///
    /// A bundle the round did not select publishes nothing to this selection,
    /// so a name belonging to one is unmatched rather than quietly ignored.
    fn unpublished(self: *const CaseSelection, slices: [bundles.len]bool) Unpublished {
        var missing: Unpublished = .{};
        for (self.names[0..self.len]) |wanted| {
            var found = false;
            for (bundles, 0..) |bundle, index| {
                if (!slices[index]) continue;
                for (bundle.cases) |entry| {
                    if (!std.mem.eql(u8, wanted, entry.name)) continue;
                    found = true;
                    break;
                }
                if (found) break;
            }
            if (!found) missing.add(wanted);
        }
        return missing;
    }
};

/// The requested names that no selected bundle publishes.
///
/// `len` counts distinct names, because a name repeated in the request is one
/// unmatched name, and `listed` is how many of them a diagnostic names before
/// it only counts the rest.
const Unpublished = struct {
    const listed = 8;

    names: [case_names_cap][]const u8 = @splat(""),
    len: usize = 0,

    fn isEmpty(self: *const Unpublished) bool {
        return self.len == 0;
    }

    fn add(self: *Unpublished, name: []const u8) void {
        for (self.names[0..self.len]) |kept| {
            if (std.mem.eql(u8, kept, name)) return;
        }
        // Unreachable while a request carries at most `case_names_cap` names.
        if (self.len == case_names_cap) return;
        self.names[self.len] = name;
        self.len += 1;
    }

    /// The names one diagnostic names, in the order they were requested.
    fn preview(self: *const Unpublished) []const []const u8 {
        return self.names[0..@min(self.len, listed)];
    }
};

const Options = struct {
    list: bool = false,
    calls: ?u32 = null,
    cases: CaseSelection = .{},
    slices: [bundles.len]bool = .{ true, true, true, true, true, true },
};

const usage =
    \\usage: zmath-api-round [--list] [--slice=labels] [--case=name]... [--calls=n]
    \\
    \\  --list            print case metadata and the f32 charge plan only, with
    \\                    zero numerical execution
    \\  --slice=labels    comma-separated subset of leaf,lanes,values,aggregates,geometry,algebra
    \\                    (default: all six)
    \\  --case=name       select exactly this published case; repeatable, so
    \\                    repeating it selects exactly the named cases, at most
    \\                    64 of them. A name no selected bundle publishes is an
    \\                    error. Omit it to select every case in the slices.
    \\  --calls=n         override every selected case's own call count, 1..4096
    \\
    \\Selection and timing output is JSONL on stdout.
    \\
;

fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    var saw_calls = false;
    var saw_slices = false;
    for (args) |argument| {
        if (std.mem.eql(u8, argument, "--list")) {
            if (options.list) return error.InvalidArguments;
            options.list = true;
        } else if (std.mem.startsWith(u8, argument, "--calls=")) {
            if (saw_calls) return error.InvalidArguments;
            saw_calls = true;
            const parsed = std.fmt.parseInt(u32, argument["--calls=".len..], 10) catch
                return error.InvalidArguments;
            if (parsed == 0 or parsed > calls_cap) return error.InvalidArguments;
            options.calls = parsed;
        } else if (std.mem.startsWith(u8, argument, "--case=")) {
            const name = argument["--case=".len..];
            if (name.len == 0) return error.InvalidArguments;
            try options.cases.add(name);
        } else if (std.mem.startsWith(u8, argument, "--slice=")) {
            if (saw_slices) return error.InvalidArguments;
            saw_slices = true;
            const labels = argument["--slice=".len..];
            if (labels.len == 0) return error.InvalidArguments;
            var selected: [bundles.len]bool = @splat(false);
            var parts = std.mem.splitScalar(u8, labels, ',');
            while (parts.next()) |label| {
                var matched = false;
                for (bundles, 0..) |bundle, index| {
                    if (std.mem.eql(u8, bundle.label, label)) {
                        selected[index] = true;
                        matched = true;
                    }
                }
                if (!matched) return error.InvalidArguments;
            }
            options.slices = selected;
        } else {
            return error.InvalidArguments;
        }
    }
    return options;
}

/// The structural fingerprint of one case: which bundle published it, what it
/// is called, which public owner it exercises, how many calls a run makes and
/// which accepted kernels that run reaches. Inputs are constructed inside the
/// case body from the runtime index, so the values themselves are pinned by the
/// checksum rather than here.
fn inputDigest(bundle_label: []const u8, entry: common.Case, calls: u32) u64 {
    var acc = common.mix(common.hash_seed, @as(u64, calls));
    acc = common.hashText(acc, bundle_label);
    acc = common.hashText(acc, entry.name);
    acc = common.hashText(acc, entry.namespace);
    for (entry.f32) |charge| {
        acc = common.mix(acc, @as(u64, charge.count));
    }
    return common.mix(acc, common.hashText(common.hash_seed, "zmath-api-round-input"));
}

fn chargeTotal(entry: common.Case) u64 {
    var total: u64 = 0;
    for (entry.f32) |charge| total += charge.count;
    return total;
}

fn writeJsonString(out: *std.Io.Writer, value: []const u8) !void {
    try out.writeAll("\"");
    for (value) |byte| {
        switch (byte) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            else => {
                if (byte < 0x20) {
                    try out.print("\\u{x:0>4}", .{byte});
                } else {
                    try out.writeByte(byte);
                }
            },
        }
    }
    try out.writeAll("\"");
}

fn writeCharges(out: *std.Io.Writer, entry: common.Case) !void {
    try out.writeAll("[");
    for (entry.f32, 0..) |charge, index| {
        if (index != 0) try out.writeAll(",");
        try out.writeAll("{\"operation\":");
        try writeJsonString(out, charge.operation);
        try out.print(",\"count\":{d}}}", .{charge.count});
    }
    try out.writeAll("]");
}

/// Writes `value` as sixteen lowercase hex digits. The width is fixed so a
/// consumer can parse the field without reading the summary first.
fn writeDigest(out: *std.Io.Writer, value: u64) !void {
    const alphabet = "0123456789abcdef";
    var text: [16]u8 = undefined;
    var remaining = value;
    var index: usize = alphabet.len;
    while (index > 0) {
        index -= 1;
        text[index] = alphabet[@intCast(remaining & 0x0f)];
        remaining >>= 4;
    }
    try writeJsonString(out, &text);
}

/// One measurement boundary. The clock is read once before the loop and once
/// after it. Every `invoke` result is passed through `doNotOptimizeAway` and
/// folded into the checksum inside the timed region, so the compiler cannot
/// drop a call and the checksum cannot be computed outside the measurement.
fn measure(io: std.Io, entry: common.Case, calls: u32) struct { elapsed_ns: u64, checksum: u64 } {
    const total: usize = @intCast(calls);
    var checksum: u64 = 0;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..total) |index| {
        const value = entry.invoke(index);
        std.mem.doNotOptimizeAway(&value);
        checksum = common.mix(checksum, value);
    }
    const elapsed = std.Io.Clock.awake.now(io).nanoseconds - start;
    std.mem.doNotOptimizeAway(&checksum);
    return .{ .elapsed_ns = @intCast(elapsed), .checksum = checksum };
}

const OperationTotal = struct { operation: []const u8, count: u64 };

pub fn main(init: std.process.Init) !void {
    if (!target_mode.approved_corpus_pair) return error.UnapprovedCorpusProfile;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseOptions(args[1..]) catch {
        std.debug.print("{s}", .{usage});
        return error.InvalidArguments;
    };

    // The selection is proved before anything is written. A round that quietly
    // measured less than it was asked to measure would publish a receipt that
    // does not describe itself, so a name no selected bundle publishes is an
    // error here rather than a shorter document later.
    const missing = options.cases.unpublished(options.slices);
    if (!missing.isEmpty()) {
        const plural: []const u8 = if (missing.len == 1) "" else "s";
        const verb: []const u8 = if (missing.len == 1) "is" else "are";
        std.debug.print(
            "no such case: {d} requested case name{s} {s} not published by any selected bundle: ",
            .{ missing.len, plural, verb },
        );
        const shown = missing.preview();
        for (shown, 0..) |name, index| {
            if (index != 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{name});
        }
        if (shown.len < missing.len) {
            std.debug.print(", and {d} more", .{missing.len - shown.len});
        }
        std.debug.print("\n", .{});
        return error.UnknownCase;
    }

    var out_buffer: [1 << 16]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    const harness_digest = computeHarnessDigest();
    try out.writeAll("{\"kind\":\"build\",\"protocol\":");
    try out.print("{d},\"target\":", .{protocol_version});
    try writeJsonString(out, target_mode.target);
    try out.writeAll(",\"cpu\":");
    try writeJsonString(out, target_mode.cpu);
    try out.writeAll(",\"optimize\":");
    try writeJsonString(out, target_mode.mode);
    try out.print(",\"approved_profile\":{s},\"harness_digest\":", .{
        if (target_mode.approved_corpus_pair) "true" else "false",
    });
    try writeDigest(out, harness_digest);
    try out.writeAll("}\n");

    const allocator = init.arena.allocator();
    var totals: std.ArrayList(OperationTotal) = .empty;
    var emitted: usize = 0;
    var calls_total: u64 = 0;
    var charge_total: u64 = 0;

    for (bundles, 0..) |bundle, bundle_index| {
        if (!options.slices[bundle_index]) continue;
        for (bundle.cases) |entry| {
            if (!options.cases.selects(entry.name)) continue;
            const calls = options.calls orelse entry.calls;
            const kind: []const u8 = if (options.list)
                "{\"kind\":\"case\",\"name\":"
            else
                "{\"kind\":\"row\",\"name\":";
            try out.writeAll(kind);
            try writeJsonString(out, entry.name);
            try out.writeAll(",\"namespace\":");
            try writeJsonString(out, entry.namespace);
            try out.writeAll(",\"bundle\":");
            try writeJsonString(out, bundle.label);
            try out.print(",\"calls\":{d},\"f32\":", .{calls});
            try writeCharges(out, entry);
            try out.print(",\"f32_total\":{d},\"input_digest\":", .{chargeTotal(entry)});
            try writeDigest(out, inputDigest(bundle.label, entry, calls));

            if (!options.list) {
                const measurement = measure(init.io, entry, calls);
                try out.print(",\"elapsed_ns\":{d},\"checksum\":", .{measurement.elapsed_ns});
                try writeDigest(out, measurement.checksum);
            }
            try out.writeAll("}\n");

            for (entry.f32) |charge| {
                var merged = false;
                for (totals.items) |*total| {
                    if (!std.mem.eql(u8, total.operation, charge.operation)) continue;
                    total.count += charge.count;
                    merged = true;
                    break;
                }
                if (!merged) {
                    try totals.append(allocator, .{
                        .operation = charge.operation,
                        .count = charge.count,
                    });
                }
            }
            emitted += 1;
            calls_total += calls;
            charge_total += chargeTotal(entry);
        }
    }

    const mode: []const u8 = if (options.list) "list" else "measure";
    try out.writeAll("{\"kind\":\"summary\",\"mode\":");
    try writeJsonString(out, mode);
    try out.print(",\"cases\":{d},\"calls_total\":{d},\"f32_total\":{d},\"f32\":[", .{
        emitted,
        calls_total,
        charge_total,
    });
    for (totals.items, 0..) |total, index| {
        if (index != 0) try out.writeAll(",");
        try out.writeAll("{\"operation\":");
        try writeJsonString(out, total.operation);
        try out.print(",\"count\":{d}}}", .{total.count});
    }
    try out.writeAll("],\"bundles\":[");
    var first = true;
    for (bundles, 0..) |bundle, bundle_index| {
        if (!options.slices[bundle_index]) continue;
        if (!first) try out.writeAll(",");
        first = false;
        try writeJsonString(out, bundle.label);
    }
    try out.writeAll("]}\n");
}
