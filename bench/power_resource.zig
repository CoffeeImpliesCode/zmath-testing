const std = @import("std");
const builtin = @import("builtin");
const zmath = @import("zmath");

const Io = std.Io;
const repetitions: u32 = 4;

const Family = enum {
    pown,
    compoundn,
    rootn,
};

const Format = enum {
    h,
    f,
    d,
};

const Scenario = struct {
    family: Family,
    format: Format,
    input_bits: u64,
    degree: i64,
};

const Measurement = struct {
    result_bits: u64,
    ok: bool,
};

const scenarios = [_]Scenario{
    .{ .family = .pown, .format = .h, .input_bits = 0x0001, .degree = -64 },
    .{ .family = .pown, .format = .h, .input_bits = 0x0001, .degree = 64 },
    .{ .family = .pown, .format = .h, .input_bits = 0x0002, .degree = -64 },
    .{ .family = .pown, .format = .h, .input_bits = 0x0002, .degree = 64 },
    .{ .family = .pown, .format = .f, .input_bits = 0x0000_0001, .degree = -64 },
    .{ .family = .pown, .format = .f, .input_bits = 0x0000_0001, .degree = 64 },
    .{ .family = .pown, .format = .f, .input_bits = 0x0000_0002, .degree = -64 },
    .{ .family = .pown, .format = .f, .input_bits = 0x0000_0002, .degree = 64 },
    .{ .family = .pown, .format = .d, .input_bits = 0x0000_0000_0000_0001, .degree = -64 },
    .{ .family = .pown, .format = .d, .input_bits = 0x0000_0000_0000_0001, .degree = 64 },
    .{ .family = .pown, .format = .d, .input_bits = 0x0000_0000_0000_0002, .degree = -64 },
    .{ .family = .pown, .format = .d, .input_bits = 0x0000_0000_0000_0002, .degree = 64 },

    .{ .family = .compoundn, .format = .h, .input_bits = 0x0001, .degree = -64 },
    .{ .family = .compoundn, .format = .h, .input_bits = 0x0001, .degree = 64 },
    .{ .family = .compoundn, .format = .h, .input_bits = 0x0002, .degree = -64 },
    .{ .family = .compoundn, .format = .h, .input_bits = 0x0002, .degree = 64 },
    .{ .family = .compoundn, .format = .f, .input_bits = 0x0000_0001, .degree = -64 },
    .{ .family = .compoundn, .format = .f, .input_bits = 0x0000_0001, .degree = 64 },
    .{ .family = .compoundn, .format = .f, .input_bits = 0x0000_0002, .degree = -64 },
    .{ .family = .compoundn, .format = .f, .input_bits = 0x0000_0002, .degree = 64 },
    .{ .family = .compoundn, .format = .d, .input_bits = 0x0000_0000_0000_0001, .degree = -64 },
    .{ .family = .compoundn, .format = .d, .input_bits = 0x0000_0000_0000_0001, .degree = 64 },
    .{ .family = .compoundn, .format = .d, .input_bits = 0x0000_0000_0000_0002, .degree = -64 },
    .{ .family = .compoundn, .format = .d, .input_bits = 0x0000_0000_0000_0002, .degree = 64 },

    .{ .family = .rootn, .format = .h, .input_bits = 0x0001, .degree = -64 },
    .{ .family = .rootn, .format = .h, .input_bits = 0x0001, .degree = 64 },
    .{ .family = .rootn, .format = .h, .input_bits = 0x0002, .degree = -64 },
    .{ .family = .rootn, .format = .h, .input_bits = 0x0002, .degree = 64 },
    .{ .family = .rootn, .format = .f, .input_bits = 0x0000_0001, .degree = -64 },
    .{ .family = .rootn, .format = .f, .input_bits = 0x0000_0001, .degree = 64 },
    .{ .family = .rootn, .format = .f, .input_bits = 0x0000_0002, .degree = -64 },
    .{ .family = .rootn, .format = .f, .input_bits = 0x0000_0002, .degree = 64 },
    .{ .family = .rootn, .format = .d, .input_bits = 0x0000_0000_0000_0001, .degree = -64 },
    .{ .family = .rootn, .format = .d, .input_bits = 0x0000_0000_0000_0001, .degree = 64 },
    .{ .family = .rootn, .format = .d, .input_bits = 0x0000_0000_0000_0002, .degree = -64 },
    .{ .family = .rootn, .format = .d, .input_bits = 0x0000_0000_0000_0002, .degree = 64 },
};

fn benchTime(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn pack(result: anytype) Measurement {
    const value = result.value;
    const T = @TypeOf(value);
    if (T == f16) {
        const result_bits: u16 = @bitCast(value);
        return .{ .result_bits = result_bits, .ok = result.ok };
    }
    if (T == f32) {
        const result_bits: u32 = @bitCast(value);
        return .{ .result_bits = result_bits, .ok = result.ok };
    }
    if (T == f64) {
        const result_bits: u64 = @bitCast(value);
        return .{ .result_bits = result_bits, .ok = result.ok };
    }
    @compileError("power resource benchmark supports only f16, f32, and f64");
}

fn measureH(scenario: Scenario) Measurement {
    var input_bits: u16 = @intCast(scenario.input_bits);
    var degree = scenario.degree;
    std.mem.doNotOptimizeAway(&input_bits);
    std.mem.doNotOptimizeAway(&degree);
    const input: f16 = @bitCast(input_bits);
    return switch (scenario.family) {
        .pown => pack(zmath.pown(input, degree)),
        .compoundn => pack(zmath.compoundn(input, degree)),
        .rootn => pack(zmath.rootn(input, degree)),
    };
}

fn measureF(scenario: Scenario) Measurement {
    var input_bits: u32 = @intCast(scenario.input_bits);
    var degree = scenario.degree;
    std.mem.doNotOptimizeAway(&input_bits);
    std.mem.doNotOptimizeAway(&degree);
    const input: f32 = @bitCast(input_bits);
    return switch (scenario.family) {
        .pown => pack(zmath.pown(input, degree)),
        .compoundn => pack(zmath.compoundn(input, degree)),
        .rootn => pack(zmath.rootn(input, degree)),
    };
}

fn measureD(scenario: Scenario) Measurement {
    var input_bits: u64 = scenario.input_bits;
    var degree = scenario.degree;
    std.mem.doNotOptimizeAway(&input_bits);
    std.mem.doNotOptimizeAway(&degree);
    const input: f64 = @bitCast(input_bits);
    return switch (scenario.family) {
        .pown => pack(zmath.pown(input, degree)),
        .compoundn => pack(zmath.compoundn(input, degree)),
        .rootn => pack(zmath.rootn(input, degree)),
    };
}

fn measure(scenario: Scenario) Measurement {
    return switch (scenario.format) {
        .h => measureH(scenario),
        .f => measureF(scenario),
        .d => measureD(scenario),
    };
}

pub fn main(init: std.process.Init) !void {
    var checksum: u64 = 0;
    std.debug.print(
        "target_arch={s} target_os={s} target_abi={s} cpu={s} optimize={s} " ++
            "scenarios={} repetitions={}\n",
        .{
            @tagName(builtin.target.cpu.arch),
            @tagName(builtin.target.os.tag),
            @tagName(builtin.target.abi),
            builtin.target.cpu.model.name,
            @tagName(builtin.mode),
            scenarios.len,
            repetitions,
        },
    );

    for (scenarios, 0..) |scenario, index| {
        const start = benchTime(init.io);
        var last: Measurement = .{ .result_bits = 0, .ok = false };
        var repetition: u32 = 0;
        while (repetition < repetitions) : (repetition += 1) {
            last = measure(scenario);
            checksum +%= last.result_bits;
            checksum +%= @as(u64, @intCast(index));
            checksum +%= if (last.ok) 1 else 0;
        }
        const elapsed = benchTime(init.io) - start;
        std.mem.doNotOptimizeAway(&last);
        std.mem.doNotOptimizeAway(&checksum);
        std.debug.print(
            "scenario={} family={s} format={s} degree={} input_bits=0x{x} " ++
                "elapsed_ns={} calls={} result_bits=0x{x} status={s} checksum=0x{x}\n",
            .{
                index,
                @tagName(scenario.family),
                @tagName(scenario.format),
                scenario.degree,
                scenario.input_bits,
                elapsed,
                repetitions,
                last.result_bits,
                if (last.ok) "ok" else "invalid",
                checksum,
            },
        );
    }
}
