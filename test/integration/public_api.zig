const std = @import("std");
const zmath = @import("zmath");

test "imports the public zmath module" {
    try std.testing.expectEqual(@as(i32, 10), zmath.add(3, 7));
}

test "exports IEEE primitives from the public module" {
    try std.testing.expectEqual(
        @as(u32, 1),
        @as(u32, @bitCast(zmath.ieee.nextAfterf(0.0, 1.0))),
    );
}
