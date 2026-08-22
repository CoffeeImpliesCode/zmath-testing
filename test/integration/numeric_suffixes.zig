const std = @import("std");
const zmath = @import("zmath");

test "exports IEEE h f and d numeric suffixes" {
    const half_value: f16 = -1.5;
    const float_value: f32 = -2.5;
    const double_value: f64 = -3.5;

    try std.testing.expect(zmath.ieee.classifyh(half_value) == .normal);
    try std.testing.expect(zmath.ieee.classifyf(float_value) == .normal);
    try std.testing.expect(zmath.ieee.classifyd(double_value) == .normal);
}

test "exports scalar h f and d numeric suffixes" {
    const half_value: f16 = -1.5;
    const float_value: f32 = -2.5;
    const double_value: f64 = -3.5;

    try std.testing.expectEqual(@as(f16, 1.5), zmath.scalar.absh(half_value));
    try std.testing.expectEqual(@as(f32, 2.5), zmath.scalar.absf(float_value));
    try std.testing.expectEqual(@as(f64, 3.5), zmath.scalar.absd(double_value));
}
