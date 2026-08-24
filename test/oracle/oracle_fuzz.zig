const std = @import("std");
const corpus = @import("corpus_support");
const campaigns = @import("corpus_campaigns.zig");
const runner = @import("corpus_runner.zig");

const Function = corpus.Function;
const max_function_count = corpus.max_function_count;
const max_argument_count = corpus.max_argument_count;
const max_tag_bytes: usize = 32;

pub const FuzzSelection = struct {
    function: Function,
    campaign: campaigns.CampaignClass,
};

pub const FuzzDecision = union(enum) {
    supported: FuzzSelection,
    unsupported: runner.UnsupportedReason,
};

pub const FuzzError = error{
    NoSupportedRows,
    UnsupportedShape,
    InputShapeMismatch,
    AcceptedRowUnsupported,
};

pub fn selectFuzzFunction(
    manifest: *const corpus.Manifest,
    smith: *std.testing.Smith,
) !FuzzDecision {
    var supported: [max_function_count]FuzzSelection = undefined;
    var supported_count: usize = 0;
    var functions = manifest.functions();
    while (try functions.next()) |function| {
        switch (runner.supportFor(function)) {
            .supported => {
                if (supported_count == supported.len) return error.NoSupportedRows;
                supported[supported_count] = .{
                    .function = function,
                    .campaign = campaigns.campaignClass(function),
                };
                supported_count += 1;
            },
            .unsupported => {},
        }
    }
    if (supported_count == 0) return error.NoSupportedRows;
    const index = @as(usize, smith.value(u16)) % supported_count;
    return .{ .supported = supported[index] };
}

fn lowMask(bit_count: u32) u64 {
    if (bit_count == 0) return 0;
    if (bit_count >= 64) return std.math.maxInt(u64);
    return (@as(u64, 1) << @as(u6, @intCast(bit_count))) - 1;
}

fn fuzzFloatBits(format: corpus.Format, smith: *std.testing.Smith) u64 {
    return switch (format) {
        .h => @as(u64, smith.value(u16)),
        .f => @as(u64, smith.value(u32)),
        .d => smith.value(u64),
    };
}

fn fuzzFieldBits(
    descriptor: corpus.OracleFieldDescriptor,
    campaign: campaigns.CampaignClass,
    smith: *std.testing.Smith,
) u64 {
    return switch (descriptor.kind) {
        .float => fuzzFloatBits(descriptor.format.code, smith),
        .signed_integer, .unsigned_integer => blk: {
            const raw = smith.value(u64);
            if (campaign == .bounded_h_integer_domain) {
                const bounded = raw % 33;
                break :blk bounded & lowMask(descriptor.value_bits);
            }
            break :blk raw & lowMask(descriptor.value_bits);
        },
        .boolean => @as(u64, smith.value(u8) & 1),
        .tag, .rounding => @as(u64, smith.value(u8)) %
            (if (descriptor.kind == .rounding) 5 else 1),
    };
}

fn fuzzSupportedRow(selection: FuzzSelection, smith: *std.testing.Smith) !void {
    const function = selection.function;
    const arguments = function.arguments();
    if (arguments.len == 0 or arguments.len > max_argument_count) {
        return error.InputShapeMismatch;
    }

    var input_bits: [max_argument_count]u64 = undefined;
    var input_tags: [max_argument_count][]const u8 = undefined;
    var tag_storage: [max_argument_count][max_tag_bytes]u8 = undefined;
    for (arguments, 0..) |argument, index| {
        const descriptor = argument.oracleDescriptor();
        input_bits[index] = fuzzFieldBits(descriptor, selection.campaign, smith);
        input_tags[index] = "";
        switch (argument) {
            .tag => {
                const tag_length = @as(usize, smith.value(u8)) % (max_tag_bytes + 1);
                for (0..tag_length) |tag_index| {
                    tag_storage[index][tag_index] = smith.value(u8);
                }
                input_tags[index] = tag_storage[index][0..tag_length];
            },
            else => {},
        }
    }

    const outcome = runner.runFunctionWithTags(
        function,
        input_bits[0..arguments.len],
        input_tags[0..arguments.len],
    ) catch |err| switch (err) {
        error.ReferenceUnsupported,
        error.ProofUnsupported,
        => return error.AcceptedRowUnsupported,
        else => return err,
    };
    switch (outcome) {
        .verified => {},
        .unsupported => return error.AcceptedRowUnsupported,
    }
}

pub fn fuzzRow(function: Function, smith: *std.testing.Smith) !void {
    switch (runner.supportFor(function)) {
        .supported => try fuzzSupportedRow(.{
            .function = function,
            .campaign = campaigns.campaignClass(function),
        }, smith),
        .unsupported => return error.UnsupportedShape,
    }
}

fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    const decision = try selectFuzzFunction(&manifest, smith);
    switch (decision) {
        .supported => |selection| try fuzzSupportedRow(selection, smith),
        .unsupported => return error.UnsupportedShape,
    }
}

test "v2 fuzz selects descriptor-supported campaigns" {
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    var functions = manifest.functions();
    var supported_count: usize = 0;
    var unsupported_count: usize = 0;
    while (try functions.next()) |function| {
        switch (runner.supportFor(function)) {
            .supported => {
                supported_count += 1;
                const campaign = campaigns.classify(function);
                try std.testing.expect(campaign.campaignClass() != .unavailable);
            },
            .unsupported => unsupported_count += 1,
        }
    }
    try std.testing.expectEqual(@as(usize, 5), supported_count);
    try std.testing.expectEqual(@as(usize, 310), unsupported_count);
}

test "v2 fuzz target uses the descriptor campaign callback" {
    try std.testing.fuzz({}, fuzzOne, .{});
}
