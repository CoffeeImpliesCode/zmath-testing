const std = @import("std");
const corpus = @import("corpus_support");

const manifest_status_unsupported: c_int = 1;

extern fn zmath_testing_mpfr_reference(
    op: [*:0]const u8,
    format: c_uint,
    input_bits: *const u64,
    arity: usize,
    output_bits: *u64,
    output_class: *c_uint,
) c_int;

extern fn zmath_testing_arb_prove_rounding(
    op: [*:0]const u8,
    format: c_uint,
    input_bits: *const u64,
    arity: usize,
    candidate_bits: u64,
    output_class: *c_uint,
) c_int;

const Format = enum(c_uint) {
    h = 1,
    f = 2,
    d = 3,
};

const ManifestStatus = enum {
    unsupported,
};

const Row = struct {
    op: [:0]const u8,
    format: Format,
    status: ManifestStatus,
};

const unsupported_rows = [_]Row{
    .{ .op = "exp", .format = .h, .status = .unsupported },
    .{ .op = "exp", .format = .f, .status = .unsupported },
    .{ .op = "exp", .format = .d, .status = .unsupported },
    .{ .op = "log", .format = .h, .status = .unsupported },
    .{ .op = "log", .format = .f, .status = .unsupported },
    .{ .op = "log", .format = .d, .status = .unsupported },
    .{ .op = "sin", .format = .h, .status = .unsupported },
    .{ .op = "sin", .format = .f, .status = .unsupported },
    .{ .op = "sin", .format = .d, .status = .unsupported },
};

const DispatchProbe = struct {
    runtime_calls: usize = 0,
    bridge_calls: usize = 0,

    fn runtime(context: *anyopaque, _: Row) void {
        const probe: *DispatchProbe = @ptrCast(@alignCast(context));
        probe.runtime_calls += 1;
    }

    fn bridge(context: *anyopaque, _: Row) void {
        const probe: *DispatchProbe = @ptrCast(@alignCast(context));
        probe.bridge_calls += 1;
    }
};

const Dispatch = struct {
    context: *anyopaque,
    runtime: *const fn (context: *anyopaque, row: Row) void,
    bridge: *const fn (context: *anyopaque, row: Row) void,
};

fn runManifestRow(row: Row, dispatch: Dispatch) c_int {
    switch (row.status) {
        .unsupported => {
            _ = dispatch;
            return manifest_status_unsupported;
        },
    }
}

comptime {
    _ = &zmath_testing_mpfr_reference;
    _ = &zmath_testing_arb_prove_rounding;
}

test "embedded unsupported transcendental rows do not dispatch" {
    try corpus.validateEmbeddedManifest();

    var probe = DispatchProbe{};
    const dispatch = Dispatch{
        .context = &probe,
        .runtime = DispatchProbe.runtime,
        .bridge = DispatchProbe.bridge,
    };

    for (unsupported_rows) |row| {
        try std.testing.expectEqual(manifest_status_unsupported, runManifestRow(row, dispatch));
    }

    try std.testing.expectEqual(@as(usize, 0), probe.runtime_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.bridge_calls);
}
