//! Comparative benchmark bridge: provides C ABI wrappers and getters for zmath
//! and Zig standard library / builtin baseline functions.
//!
//! Zig baseline functions lower to LLVM intrinsics, hardware instructions,
//! or compiler-rt / musl fallback routines depending on target architecture
//! and compiler codegen.
//!
//! Unary operations ignore the second parameter.
//! For zmath atan2, returned Atan2Result(T) is checked; unresolved results
//! explicitly panic rather than returning a fabricated fallback.

const std = @import("std");
const zmath = @import("zmath");

pub const CompareF32 = ?*const fn (f32, f32) callconv(.c) f32;
pub const CompareF64 = ?*const fn (f64, f64) callconv(.c) f64;

// -----------------------------------------------------------------------------
// zmath f32 wrappers
// -----------------------------------------------------------------------------

pub noinline fn compare_zmath_exp_f32(a: f32, b: f32) callconv(.c) f32 {
    @setFloatMode(.strict);
    _ = b;
    return zmath.exp(a);
}

pub noinline fn compare_zmath_log_f32(a: f32, b: f32) callconv(.c) f32 {
    @setFloatMode(.strict);
    _ = b;
    return zmath.log(a);
}

pub noinline fn compare_zmath_sin_f32(a: f32, b: f32) callconv(.c) f32 {
    @setFloatMode(.strict);
    _ = b;
    return zmath.sin(a);
}

pub noinline fn compare_zmath_cos_f32(a: f32, b: f32) callconv(.c) f32 {
    @setFloatMode(.strict);
    _ = b;
    return zmath.cos(a);
}

pub noinline fn compare_zmath_tan_f32(a: f32, b: f32) callconv(.c) f32 {
    @setFloatMode(.strict);
    _ = b;
    return zmath.tan(a);
}

pub noinline fn compare_zmath_sqrt_f32(a: f32, b: f32) callconv(.c) f32 {
    @setFloatMode(.strict);
    _ = b;
    return zmath.sqrt(a);
}

pub noinline fn compare_zmath_hypot_f32(a: f32, b: f32) callconv(.c) f32 {
    @setFloatMode(.strict);
    return zmath.hypot(a, b);
}

pub noinline fn compare_zmath_atan2_f32(a: f32, b: f32) callconv(.c) f32 {
    @setFloatMode(.strict);
    const result = zmath.atan2(a, b);
    if (!result.resolved) {
        @panic("zmath.atan2(f32) returned unresolved result");
    }
    return result.value;
}

pub noinline fn compare_zmath_pow_f32(a: f32, b: f32) callconv(.c) f32 {
    @setFloatMode(.strict);
    return zmath.pow(a, b);
}

// -----------------------------------------------------------------------------
// zmath f64 wrappers
// -----------------------------------------------------------------------------

pub noinline fn compare_zmath_exp_f64(a: f64, b: f64) callconv(.c) f64 {
    @setFloatMode(.strict);
    _ = b;
    return zmath.exp(a);
}

pub noinline fn compare_zmath_log_f64(a: f64, b: f64) callconv(.c) f64 {
    @setFloatMode(.strict);
    _ = b;
    return zmath.log(a);
}

pub noinline fn compare_zmath_sin_f64(a: f64, b: f64) callconv(.c) f64 {
    @setFloatMode(.strict);
    _ = b;
    return zmath.sin(a);
}

pub noinline fn compare_zmath_cos_f64(a: f64, b: f64) callconv(.c) f64 {
    @setFloatMode(.strict);
    _ = b;
    return zmath.cos(a);
}

pub noinline fn compare_zmath_tan_f64(a: f64, b: f64) callconv(.c) f64 {
    @setFloatMode(.strict);
    _ = b;
    return zmath.tan(a);
}

pub noinline fn compare_zmath_sqrt_f64(a: f64, b: f64) callconv(.c) f64 {
    @setFloatMode(.strict);
    _ = b;
    return zmath.sqrt(a);
}

pub noinline fn compare_zmath_hypot_f64(a: f64, b: f64) callconv(.c) f64 {
    @setFloatMode(.strict);
    return zmath.hypot(a, b);
}

pub noinline fn compare_zmath_atan2_f64(a: f64, b: f64) callconv(.c) f64 {
    @setFloatMode(.strict);
    const result = zmath.atan2(a, b);
    if (!result.resolved) {
        @panic("zmath.atan2(f64) returned unresolved result");
    }
    return result.value;
}

pub noinline fn compare_zmath_pow_f64(a: f64, b: f64) callconv(.c) f64 {
    @setFloatMode(.strict);
    return zmath.pow(a, b);
}

// -----------------------------------------------------------------------------
// Zig standard library / builtin f32 wrappers
// -----------------------------------------------------------------------------

pub noinline fn compare_zig_exp_f32(a: f32, b: f32) callconv(.c) f32 {
    _ = b;
    return @exp(a);
}

pub noinline fn compare_zig_log_f32(a: f32, b: f32) callconv(.c) f32 {
    _ = b;
    return @log(a);
}

pub noinline fn compare_zig_sin_f32(a: f32, b: f32) callconv(.c) f32 {
    _ = b;
    return @sin(a);
}

pub noinline fn compare_zig_cos_f32(a: f32, b: f32) callconv(.c) f32 {
    _ = b;
    return @cos(a);
}

pub noinline fn compare_zig_tan_f32(a: f32, b: f32) callconv(.c) f32 {
    _ = b;
    return @tan(a);
}

pub noinline fn compare_zig_sqrt_f32(a: f32, b: f32) callconv(.c) f32 {
    _ = b;
    return @sqrt(a);
}

pub noinline fn compare_zig_hypot_f32(a: f32, b: f32) callconv(.c) f32 {
    return std.math.hypot(a, b);
}

pub noinline fn compare_zig_atan2_f32(a: f32, b: f32) callconv(.c) f32 {
    return std.math.atan2(a, b);
}

pub noinline fn compare_zig_pow_f32(a: f32, b: f32) callconv(.c) f32 {
    return std.math.pow(f32, a, b);
}

// -----------------------------------------------------------------------------
// Zig standard library / builtin f64 wrappers
// -----------------------------------------------------------------------------

pub noinline fn compare_zig_exp_f64(a: f64, b: f64) callconv(.c) f64 {
    _ = b;
    return @exp(a);
}

pub noinline fn compare_zig_log_f64(a: f64, b: f64) callconv(.c) f64 {
    _ = b;
    return @log(a);
}

pub noinline fn compare_zig_sin_f64(a: f64, b: f64) callconv(.c) f64 {
    _ = b;
    return @sin(a);
}

pub noinline fn compare_zig_cos_f64(a: f64, b: f64) callconv(.c) f64 {
    _ = b;
    return @cos(a);
}

pub noinline fn compare_zig_tan_f64(a: f64, b: f64) callconv(.c) f64 {
    _ = b;
    return @tan(a);
}

pub noinline fn compare_zig_sqrt_f64(a: f64, b: f64) callconv(.c) f64 {
    _ = b;
    return @sqrt(a);
}

pub noinline fn compare_zig_hypot_f64(a: f64, b: f64) callconv(.c) f64 {
    return std.math.hypot(a, b);
}

pub noinline fn compare_zig_atan2_f64(a: f64, b: f64) callconv(.c) f64 {
    return std.math.atan2(a, b);
}

pub noinline fn compare_zig_pow_f64(a: f64, b: f64) callconv(.c) f64 {
    return std.math.pow(f64, a, b);
}

// Keep the wrapper symbols available for C inspection as well as through the
// getters. The getter path is what the benchmark uses for every timed call.
comptime {
    @export(&compare_zmath_exp_f32, .{ .name = "compare_zmath_exp_f32" });
    @export(&compare_zmath_log_f32, .{ .name = "compare_zmath_log_f32" });
    @export(&compare_zmath_sin_f32, .{ .name = "compare_zmath_sin_f32" });
    @export(&compare_zmath_cos_f32, .{ .name = "compare_zmath_cos_f32" });
    @export(&compare_zmath_tan_f32, .{ .name = "compare_zmath_tan_f32" });
    @export(&compare_zmath_sqrt_f32, .{ .name = "compare_zmath_sqrt_f32" });
    @export(&compare_zmath_hypot_f32, .{ .name = "compare_zmath_hypot_f32" });
    @export(&compare_zmath_atan2_f32, .{ .name = "compare_zmath_atan2_f32" });
    @export(&compare_zmath_pow_f32, .{ .name = "compare_zmath_pow_f32" });
    @export(&compare_zmath_exp_f64, .{ .name = "compare_zmath_exp_f64" });
    @export(&compare_zmath_log_f64, .{ .name = "compare_zmath_log_f64" });
    @export(&compare_zmath_sin_f64, .{ .name = "compare_zmath_sin_f64" });
    @export(&compare_zmath_cos_f64, .{ .name = "compare_zmath_cos_f64" });
    @export(&compare_zmath_tan_f64, .{ .name = "compare_zmath_tan_f64" });
    @export(&compare_zmath_sqrt_f64, .{ .name = "compare_zmath_sqrt_f64" });
    @export(&compare_zmath_hypot_f64, .{ .name = "compare_zmath_hypot_f64" });
    @export(&compare_zmath_atan2_f64, .{ .name = "compare_zmath_atan2_f64" });
    @export(&compare_zmath_pow_f64, .{ .name = "compare_zmath_pow_f64" });
    @export(&compare_zig_exp_f32, .{ .name = "compare_zig_exp_f32" });
    @export(&compare_zig_log_f32, .{ .name = "compare_zig_log_f32" });
    @export(&compare_zig_sin_f32, .{ .name = "compare_zig_sin_f32" });
    @export(&compare_zig_cos_f32, .{ .name = "compare_zig_cos_f32" });
    @export(&compare_zig_tan_f32, .{ .name = "compare_zig_tan_f32" });
    @export(&compare_zig_sqrt_f32, .{ .name = "compare_zig_sqrt_f32" });
    @export(&compare_zig_hypot_f32, .{ .name = "compare_zig_hypot_f32" });
    @export(&compare_zig_atan2_f32, .{ .name = "compare_zig_atan2_f32" });
    @export(&compare_zig_pow_f32, .{ .name = "compare_zig_pow_f32" });
    @export(&compare_zig_exp_f64, .{ .name = "compare_zig_exp_f64" });
    @export(&compare_zig_log_f64, .{ .name = "compare_zig_log_f64" });
    @export(&compare_zig_sin_f64, .{ .name = "compare_zig_sin_f64" });
    @export(&compare_zig_cos_f64, .{ .name = "compare_zig_cos_f64" });
    @export(&compare_zig_tan_f64, .{ .name = "compare_zig_tan_f64" });
    @export(&compare_zig_sqrt_f64, .{ .name = "compare_zig_sqrt_f64" });
    @export(&compare_zig_hypot_f64, .{ .name = "compare_zig_hypot_f64" });
    @export(&compare_zig_atan2_f64, .{ .name = "compare_zig_atan2_f64" });
    @export(&compare_zig_pow_f64, .{ .name = "compare_zig_pow_f64" });
}

// -----------------------------------------------------------------------------
// Getters for zmath and Zig providers
// -----------------------------------------------------------------------------

export fn compare_zmath_f32(op: u32) callconv(.c) CompareF32 {
    return switch (op) {
        0 => &compare_zmath_exp_f32,
        1 => &compare_zmath_log_f32,
        2 => &compare_zmath_sin_f32,
        3 => &compare_zmath_cos_f32,
        4 => &compare_zmath_tan_f32,
        5 => &compare_zmath_sqrt_f32,
        6 => &compare_zmath_hypot_f32,
        7 => &compare_zmath_atan2_f32,
        8 => &compare_zmath_pow_f32,
        else => null,
    };
}

export fn compare_zmath_f64(op: u32) callconv(.c) CompareF64 {
    return switch (op) {
        0 => &compare_zmath_exp_f64,
        1 => &compare_zmath_log_f64,
        2 => &compare_zmath_sin_f64,
        3 => &compare_zmath_cos_f64,
        4 => &compare_zmath_tan_f64,
        5 => &compare_zmath_sqrt_f64,
        6 => &compare_zmath_hypot_f64,
        7 => &compare_zmath_atan2_f64,
        8 => &compare_zmath_pow_f64,
        else => null,
    };
}

export fn compare_zig_f32(op: u32) callconv(.c) CompareF32 {
    return switch (op) {
        0 => &compare_zig_exp_f32,
        1 => &compare_zig_log_f32,
        2 => &compare_zig_sin_f32,
        3 => &compare_zig_cos_f32,
        4 => &compare_zig_tan_f32,
        5 => &compare_zig_sqrt_f32,
        6 => &compare_zig_hypot_f32,
        7 => &compare_zig_atan2_f32,
        8 => &compare_zig_pow_f32,
        else => null,
    };
}

export fn compare_zig_f64(op: u32) callconv(.c) CompareF64 {
    return switch (op) {
        0 => &compare_zig_exp_f64,
        1 => &compare_zig_log_f64,
        2 => &compare_zig_sin_f64,
        3 => &compare_zig_cos_f64,
        4 => &compare_zig_tan_f64,
        5 => &compare_zig_sqrt_f64,
        6 => &compare_zig_hypot_f64,
        7 => &compare_zig_atan2_f64,
        8 => &compare_zig_pow_f64,
        else => null,
    };
}
