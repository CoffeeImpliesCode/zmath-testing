const std = @import("std");
const zmath = @import("zmath");

test "imports the public zmath module" {
    // The integer `add` this used to call was zig init template text, not a
    // mathematical operation, and zmath no longer exports it. Prove the same
    // thing -- the module imports and a public entry point computes -- with an
    // exactly representable IEEE operation instead. 2*3 + 4 is 10 with no
    // rounding, so the expected value needs no tolerance.
    // The literals are annotated because a bare `2.0` is a comptime_float, and
    // zmath.fma accepts only f16, f32, and f64.
    try std.testing.expectEqual(@as(f64, 10.0), zmath.fma(@as(f64, 2.0), @as(f64, 3.0), @as(f64, 4.0)));
}

test "exports IEEE primitives from the public module" {
    try std.testing.expectEqual(
        @as(u32, 1),
        @as(u32, @bitCast(zmath.ieee.nextAfterf(0.0, 1.0))),
    );
}
