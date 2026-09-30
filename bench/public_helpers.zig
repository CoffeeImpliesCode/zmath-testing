const std = @import("std");
const zmath = @import("zmath");
const target_mode = @import("active_target_mode");

const sample_count = 1024;
const cycles_max: u64 = 1024;
const target_duration_ns: u64 = 5_000_000;
const repetitions_max: u8 = 100;

const Operation = enum {
    classifyh,
    classifyf,
    classifyd,
    ulpDistanceh,
    ulpDistancef,
    ulpDistanced,
    scaleBh,
    roundIntegralh,
};

const Format = enum { h, f, d };
const Row = struct {
    operation: Operation,
    format: Format,
    mode: ?zmath.ieee.RoundMode = null,
};

const rows = [_]Row{
    .{ .operation = .classifyh, .format = .h },
    .{ .operation = .classifyf, .format = .f },
    .{ .operation = .classifyd, .format = .d },
    .{ .operation = .ulpDistanceh, .format = .h },
    .{ .operation = .ulpDistancef, .format = .f },
    .{ .operation = .ulpDistanced, .format = .d },
    .{ .operation = .scaleBh, .format = .h, .mode = .nearest_even },
    .{ .operation = .scaleBh, .format = .h, .mode = .toward_zero },
    .{ .operation = .scaleBh, .format = .h, .mode = .toward_positive },
    .{ .operation = .scaleBh, .format = .h, .mode = .toward_negative },
    .{ .operation = .roundIntegralh, .format = .h, .mode = .nearest_even },
    .{ .operation = .roundIntegralh, .format = .h, .mode = .toward_zero },
    .{ .operation = .roundIntegralh, .format = .h, .mode = .toward_positive },
    .{ .operation = .roundIntegralh, .format = .h, .mode = .toward_negative },
};

// Matching positions exercise signed zeros, subnormals, normal boundaries,
// round-to-integral ties, infinities, and both signs of quiet/signaling NaNs.
const special_h = [_]u16{
    0x0000, 0x8000, 0x0001, 0x8001, 0x03ff, 0x83ff, 0x0400, 0x8400,
    0x3800, 0xb800, 0x3c00, 0xbc00, 0x3e00, 0xbe00, 0x4100, 0xc100,
    0x7bff, 0xfbff, 0x7c00, 0xfc00, 0x7e01, 0xfe01, 0x7d01, 0xfd01,
    0x7fff, 0xffff, 0x37ff, 0xb7ff, 0x3801, 0xb801, 0x3c01, 0xbc01,
    0x3bff, 0xbbff, 0x3a00, 0xba00,
};
const special_f = [_]u32{
    0x0000_0000, 0x8000_0000, 0x0000_0001, 0x8000_0001,
    0x007f_ffff, 0x807f_ffff, 0x0080_0000, 0x8080_0000,
    0x3f00_0000, 0xbf00_0000, 0x3f80_0000, 0xbf80_0000,
    0x3fc0_0000, 0xbfc0_0000, 0x4020_0000, 0xc020_0000,
    0x7f7f_ffff, 0xff7f_ffff, 0x7f80_0000, 0xff80_0000,
    0x7fc0_0001, 0xffc0_0001, 0x7f80_0001, 0xff80_0001,
    0x7fff_ffff, 0xffff_ffff, 0x3eff_ffff, 0xbeff_ffff,
    0x3f00_0001, 0xbf00_0001, 0x3f80_0001, 0xbf80_0001,
    0x3f7f_ffff, 0xbf7f_ffff, 0x3f40_0000, 0xbf40_0000,
};
const special_d = [_]u64{
    0x0000_0000_0000_0000, 0x8000_0000_0000_0000,
    0x0000_0000_0000_0001, 0x8000_0000_0000_0001,
    0x000f_ffff_ffff_ffff, 0x800f_ffff_ffff_ffff,
    0x0010_0000_0000_0000, 0x8010_0000_0000_0000,
    0x3fe0_0000_0000_0000, 0xbfe0_0000_0000_0000,
    0x3ff0_0000_0000_0000, 0xbff0_0000_0000_0000,
    0x3ff8_0000_0000_0000, 0xbff8_0000_0000_0000,
    0x4004_0000_0000_0000, 0xc004_0000_0000_0000,
    0x7fef_ffff_ffff_ffff, 0xffef_ffff_ffff_ffff,
    0x7ff0_0000_0000_0000, 0xfff0_0000_0000_0000,
    0x7ff8_0000_0000_0001, 0xfff8_0000_0000_0001,
    0x7ff0_0000_0000_0001, 0xfff0_0000_0000_0001,
    0x7fff_ffff_ffff_ffff, 0xffff_ffff_ffff_ffff,
    0x3fdf_ffff_ffff_ffff, 0xbfdf_ffff_ffff_ffff,
    0x3fe0_0000_0000_0001, 0xbfe0_0000_0000_0001,
    0x3ff0_0000_0000_0001, 0xbff0_0000_0000_0001,
    0x3fef_ffff_ffff_ffff, 0xbfef_ffff_ffff_ffff,
    0x3fe8_0000_0000_0000, 0xbfe8_0000_0000_0000,
};
const special_exponents = [_]i32{
    0,     0,    -1,  1,   0, 0, -11,           -11,            -24, -24,  -25, -25,
    -25,   -25,  -24, -24, 1, 1, 2_147_483_647, -2_147_483_648, 100, -100, 0,   0,
    -1000, 1000, 0,   0,   0, 0, 2_147_483_647, -2_147_483_648, 0,   0,    -24, -24,
};
const varied_exponents = [_]i32{
    -2_147_483_648, -10_000, -1000, -100, -26, -25, -24,    -15,
    -14,            -11,     -10,   -2,   -1,  0,   1,      2,
    10,             11,      15,    16,   30,  100, 10_000, 2_147_483_647,
};

comptime {
    if (rows.len != 14) @compileError("expected fourteen public helper timing rows");
    if (@typeInfo(zmath.ieee.RoundMode).@"enum".fields.len != 4) {
        @compileError("public helper benchmark must cover every RoundMode");
    }
    if (special_h.len != special_f.len or special_h.len != special_d.len or
        special_h.len != special_exponents.len)
    {
        @compileError("edge inputs must have matching formats and exponents");
    }
}

const Sample = struct {
    h: f16,
    f: f32,
    d: f64,
    peer_h: f16,
    peer_f: f32,
    peer_d: f64,
    exponent: i32,
};

const Measurement = struct {
    elapsed_ns: u64,
    calls: u64,
    checksum: u64,
};

pub fn main(init: std.process.Init) !void {
    if (!target_mode.approved_corpus_pair) return error.UnapprovedCorpusProfile;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const repetitions = parseRepetitions(args) catch |err| {
        std.debug.print(
            "usage: zmath-public-helpers [--repetitions=1..{d}] (default 5)\n",
            .{repetitions_max},
        );
        return err;
    };

    var samples: [sample_count]Sample = undefined;
    prepareSamples(&samples);
    std.debug.print(
        "target={s} cpu={s} optimize={s} rows_per_repetition={d} samples={d}\n",
        .{ target_mode.target, target_mode.cpu, target_mode.mode, rows.len, sample_count },
    );
    inline for (rows) |row| {
        const input_digest = digestInputs(row, &samples);
        const warmup = measure(row, init.io, &samples, 1);
        const cycles = std.math.clamp(
            @divFloor(target_duration_ns, @max(warmup.elapsed_ns, 1)),
            1,
            cycles_max,
        );
        for (0..repetitions) |repetition| {
            const result = measure(row, init.io, &samples, cycles);
            std.debug.print(
                "operation={s} format={s} mode={s} repetition={d} samples={d} " ++
                    "calls={d} elapsed_ns={d} checksum={x:0>16} input_digest={x:0>16}\n",
                .{
                    @tagName(row.operation),
                    @tagName(row.format),
                    if (row.mode) |mode| @tagName(mode) else "none",
                    repetition,
                    sample_count,
                    result.calls,
                    result.elapsed_ns,
                    result.checksum,
                    input_digest,
                },
            );
        }
    }
}

fn parseRepetitions(args: []const []const u8) !u8 {
    if (args.len == 0) return error.InvalidArguments;
    var repetitions: u8 = 5;
    var seen = false;
    for (args[1..]) |argument| {
        if (!std.mem.startsWith(u8, argument, "--repetitions=")) {
            return error.InvalidArguments;
        }
        if (seen) return error.InvalidRepetitions;
        seen = true;
        const text = argument["--repetitions=".len..];
        if (text.len == 0) return error.InvalidRepetitions;
        for (text) |digit| {
            if (digit < '0' or digit > '9') return error.InvalidRepetitions;
        }
        repetitions = std.fmt.parseInt(u8, text, 10) catch return error.InvalidRepetitions;
        if (repetitions == 0 or repetitions > repetitions_max) {
            return error.InvalidRepetitions;
        }
    }
    return repetitions;
}

fn mix64(value: u64) u64 {
    var mixed = value;
    mixed = (mixed ^ (mixed >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    mixed = (mixed ^ (mixed >> 27)) *% 0x94d0_49bb_1331_11eb;
    return mixed ^ (mixed >> 31);
}

fn peerBits(comptime T: type, bits: T, noise: T, index: usize) T {
    return switch (index % 8) {
        0 => bits,
        1 => bits +% 1,
        2 => bits -% 1,
        3 => bits ^ (@as(T, 1) << (@bitSizeOf(T) - 1)),
        4 => bits +% 37,
        5 => bits -% 512,
        6 => noise,
        7 => bits +% noise,
        else => unreachable,
    };
}

fn prepareSamples(samples: *[sample_count]Sample) void {
    var state: u64 = 0x1397_a340_8927_c6d1;
    for (samples, 0..) |*sample, index| {
        state +%= 0x9e37_79b9_7f4a_7c15;
        const random_h = mix64(state);
        const random_f = mix64(random_h);
        const random_d = mix64(random_f);
        const random_peer = mix64(random_d);
        const bits_h: u16 = if (index < special_h.len)
            special_h[index]
        else
            @truncate(random_h);
        const bits_f: u32 = if (index < special_f.len)
            special_f[index]
        else
            @truncate(random_f);
        const bits_d: u64 = if (index < special_d.len)
            special_d[index]
        else
            random_d;
        const peer_h: u16 = if (index < special_h.len)
            special_h[(index * 7 + 3) % special_h.len]
        else
            peerBits(u16, bits_h, @truncate(random_peer), index);
        const peer_f: u32 = if (index < special_f.len)
            special_f[(index * 7 + 3) % special_f.len]
        else
            peerBits(u32, bits_f, @truncate(random_peer), index);
        const peer_d: u64 = if (index < special_d.len)
            special_d[(index * 7 + 3) % special_d.len]
        else
            peerBits(u64, bits_d, random_peer, index);
        sample.* = .{
            .h = @bitCast(bits_h),
            .f = @bitCast(bits_f),
            .d = @bitCast(bits_d),
            .peer_h = @bitCast(peer_h),
            .peer_f = @bitCast(peer_f),
            .peer_d = @bitCast(peer_d),
            .exponent = if (index < special_exponents.len)
                special_exponents[index]
            else
                varied_exponents[index % varied_exponents.len],
        };
    }
}

fn mix(digest: u64, value: u64) u64 {
    return (digest ^ value) *% 0x100_0000_01b3;
}

fn digestInputs(comptime row: Row, samples: *const [sample_count]Sample) u64 {
    var digest: u64 = 0xcbf2_9ce4_8422_2325;
    if (row.mode) |mode| digest = mix(digest, @intFromEnum(mode));
    for (samples) |sample| {
        digest = mix(digest, switch (row.operation) {
            .classifyh, .ulpDistanceh, .scaleBh, .roundIntegralh => @as(u16, @bitCast(sample.h)),
            .classifyf, .ulpDistancef => @as(u32, @bitCast(sample.f)),
            .classifyd, .ulpDistanced => @as(u64, @bitCast(sample.d)),
        });
        switch (row.operation) {
            .ulpDistanceh => digest = mix(digest, @as(u16, @bitCast(sample.peer_h))),
            .ulpDistancef => digest = mix(digest, @as(u32, @bitCast(sample.peer_f))),
            .ulpDistanced => digest = mix(digest, @as(u64, @bitCast(sample.peer_d))),
            .scaleBh => digest = mix(digest, @as(u32, @bitCast(sample.exponent))),
            else => {},
        }
    }
    return digest;
}

fn evaluate(comptime row: Row, sample: *const Sample) u64 {
    return switch (row.operation) {
        .classifyh => @intFromEnum(zmath.ieee.classifyh(sample.h)),
        .classifyf => @intFromEnum(zmath.ieee.classifyf(sample.f)),
        .classifyd => @intFromEnum(zmath.ieee.classifyd(sample.d)),
        .ulpDistanceh => zmath.scalar.ulpDistanceh(sample.h, sample.peer_h),
        .ulpDistancef => zmath.scalar.ulpDistancef(sample.f, sample.peer_f),
        .ulpDistanced => zmath.scalar.ulpDistanced(sample.d, sample.peer_d),
        .scaleBh => @as(u16, @bitCast(zmath.ieee.scaleBh(row.mode.?, sample.h, sample.exponent))),
        .roundIntegralh => @as(u16, @bitCast(zmath.ieee.roundIntegralh(row.mode.?, sample.h))),
    };
}

fn measure(
    comptime row: Row,
    io: std.Io,
    samples: *const [sample_count]Sample,
    cycles: u64,
) Measurement {
    std.debug.assert(cycles > 0);
    std.debug.assert(cycles <= cycles_max);
    var checksum: u64 = 0;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..cycles) |_| {
        for (samples) |*sample| {
            std.mem.doNotOptimizeAway(sample);
            checksum = mix(checksum, evaluate(row, sample));
        }
    }
    std.mem.doNotOptimizeAway(&checksum);
    const elapsed = std.Io.Clock.awake.now(io).nanoseconds - start;
    std.debug.assert(elapsed >= 0);
    return .{
        .elapsed_ns = @intCast(elapsed),
        .calls = cycles * sample_count,
        .checksum = checksum,
    };
}
