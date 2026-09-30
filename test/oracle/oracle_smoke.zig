const std = @import("std");
const zmath = @import("zmath");

extern fn zmath_testing_mpfr_smoke() c_int;
extern fn zmath_testing_arb_smoke() c_int;

test "zmath public-surface smoke check" {
    // The integer `add` this used to call was zig init template text that zmath
    // no longer exports. Check the same property -- the public surface resolves
    // and computes -- with an exactly representable IEEE operation.
    // The literals are annotated because a bare `2.0` is a comptime_float, and
    // zmath.fma accepts only f16, f32, and f64.
    try std.testing.expectEqual(@as(f64, 10.0), zmath.fma(@as(f64, 2.0), @as(f64, 3.0), @as(f64, 4.0)));
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
