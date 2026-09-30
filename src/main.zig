const std = @import("std");
const Io = std.Io;

const default_corpus_root = "test/corpus";

/// `test/support/corpus.zig` validates the same manifest, but it embeds
/// `corpus/manifest.toml`, a path only the build graph stages, and it declares
/// the C oracle, so this executable cannot import it and scans the canonical
/// rows itself.
const manifest_bytes_max: usize = 256 * 1024;
const schema_version_supported: u32 = 4;
const function_header = "[[function]]";

/// Every `oracle` column value a schema 4 descriptor row may carry.
const Oracle = enum { none, exact_bits, mpfr_arb, algebraic, definitional };

pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    // Report the descriptor census rather than a rounded decimal, because the
    // typed descriptor set this harness publishes and replays is what it sells.
    const corpus_root = if (args.len > 1) args[1] else default_corpus_root;
    try reportCensus(init.io, arena, corpus_root, stdout_writer);

    try stdout_writer.flush(); // Don't forget to flush!
}

/// Counts the manifest's oracle column and fails closed unless the file is the
/// schema 4 corpus this harness publishes, because a missing, foreign, or
/// partial manifest must not print a census that looks published.
fn reportCensus(
    io: std.Io,
    arena: std.mem.Allocator,
    corpus_root: []const u8,
    writer: *Io.Writer,
) !void {
    const manifest_path = try std.fs.path.join(arena, &.{ corpus_root, "manifest.toml" });
    const source = std.Io.Dir.cwd().readFileAlloc(
        io,
        manifest_path,
        arena,
        .limited(manifest_bytes_max),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingManifest,
        else => return err,
    };

    var census = std.EnumArray(Oracle, usize).initFill(0);
    var descriptors: usize = 0;
    var schema_version: ?u32 = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t");
        if (std.mem.eql(u8, line, function_header)) {
            descriptors += 1;
        } else if (valueAfterKey(line, "schema_version = ")) |text| {
            schema_version = std.fmt.parseInt(u32, text, 10) catch
                return error.UnsupportedSchemaVersion;
        } else if (valueAfterKey(line, "oracle = ")) |text| {
            const oracle = std.meta.stringToEnum(Oracle, text) orelse return error.UnknownOracle;
            census.getPtr(oracle).* += 1;
        }
    }

    const version = schema_version orelse return error.MissingSchemaVersion;
    if (version != schema_version_supported) return error.UnsupportedSchemaVersion;

    // Every descriptor row carries exactly one oracle, so the column must
    // account for every row. A shortfall means the scan lost a row.
    var accounted: usize = 0;
    for (std.enums.values(Oracle)) |oracle| {
        accounted += census.get(oracle);
    }
    if (accounted != descriptors) return error.IncompleteOracleColumn;

    try writer.print(
        "typed corpus census: schema_version={} descriptors={}",
        .{ version, descriptors },
    );
    for (std.enums.values(Oracle)) |oracle| {
        try writer.print(" {s}={}", .{ @tagName(oracle), census.get(oracle) });
    }
    try writer.writeByte('\n');
}

/// The value text that follows `key` on one manifest line, with a TOML string's
/// quotes removed. Null when the line carries no such key.
fn valueAfterKey(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    const value = std.mem.trim(u8, line[key.len..], " \t");
    if (value.len < 2 or value[0] != '"') return value;
    if (value[value.len - 1] != '"') return null;
    return value[1 .. value.len - 1];
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            // The guard above is the bound. Narrow once, where it holds, and do
            // the window arithmetic in `u32`: `len` never exceeds `window`, so
            // `window - len` cannot underflow and needs no cast of its own.
            const window: u32 = @intCast(list.items.len);
            const len = smith.valueRangeAtMost(u32, 1, @min(window, 32));
            const off = smith.valueRangeAtMost(u32, 0, window - len);
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
