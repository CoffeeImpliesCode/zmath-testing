const std = @import("std");
const Io = std.Io;
const zmath = @import("zmath");

const iterations: u64 = 1_000_000;

fn benchTime(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

pub fn main(init: std.process.Init) !void {
    var accumulator: i32 = 0;
    const start = benchTime(init.io);

    for (0..iterations) |index| {
        accumulator = zmath.add(accumulator, @intCast(index & 7));
    }

    const elapsed = benchTime(init.io) - start;
    std.mem.doNotOptimizeAway(accumulator);
    std.debug.print(
        "operations={} elapsed_ns={} checksum={}\n",
        .{ iterations, elapsed, accumulator },
    );
}
