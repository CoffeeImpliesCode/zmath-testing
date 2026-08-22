const std = @import("std");
const zmath = @import("zmath");

test "exports IEEE H F and D numeric suffixes" {
    const half_value: f16 = -1.5;
    const float_value: f32 = -2.5;
    const double_value: f64 = -3.5;

    try std.testing.expect(zmath.ieee.classifyH(half_value) == .normal);
    try std.testing.expect(zmath.ieee.classifyF(float_value) == .normal);
    try std.testing.expect(zmath.ieee.classifyD(double_value) == .normal);
}

test "exports scalar H F and D numeric suffixes" {
    const half_value: f16 = -1.5;
    const float_value: f32 = -2.5;
    const double_value: f64 = -3.5;

    try std.testing.expectEqual(@as(f16, 1.5), zmath.scalar.absH(half_value));
    try std.testing.expectEqual(@as(f32, 2.5), zmath.scalar.absF(float_value));
    try std.testing.expectEqual(@as(f64, 3.5), zmath.scalar.absD(double_value));
}
