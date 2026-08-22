const std = @import("std");

extern fn zmath_testing_mpfr_smoke() c_int;
extern fn zmath_testing_arb_smoke() c_int;

test "MPFR smoke check" {
    try std.testing.expectEqual(@as(c_int, 1), zmath_testing_mpfr_smoke());
}

test "Arb smoke check" {
    try std.testing.expectEqual(@as(c_int, 1), zmath_testing_arb_smoke());
}
