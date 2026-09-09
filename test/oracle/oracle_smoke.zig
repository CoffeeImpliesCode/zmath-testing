const std = @import("std");
const zmath = @import("zmath");

extern fn zmath_testing_mpfr_smoke() c_int;
extern fn zmath_testing_arb_smoke() c_int;

test "zmath public-surface smoke check" {
    try std.testing.expectEqual(@as(i32, 10), zmath.add(3, 7));
}

test "MPFR environment smoke check" {
    try std.testing.expectEqual(@as(c_int, 1), zmath_testing_mpfr_smoke());
}

test "Arb environment smoke check" {
    try std.testing.expectEqual(@as(c_int, 1), zmath_testing_arb_smoke());
}

test {
    _ = @import("oracle_bridge_test.zig");
    _ = @import("oracle_exact_bits_test.zig");
    _ = @import("oracle_algebraic_test.zig");
    _ = @import("corpus_runner.zig");
}
