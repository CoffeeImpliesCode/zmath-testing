const std = @import("std");
const zmath = @import("zmath");

test "imports the public zmath module" {
    try std.testing.expectEqual(@as(i32, 10), zmath.add(3, 7));
}
