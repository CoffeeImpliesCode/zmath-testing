//! Comparative benchmark bridge: provides C ABI wrappers and getters for zmath
//! and Zig standard library / builtin baseline functions.
//!
//! Zig baseline functions lower to LLVM intrinsics, hardware instructions,
//! or compiler-rt / musl fallback routines depending on target architecture
//! and compiler codegen.
//!
//! Unary operations ignore the second parameter.
//! For zmath atan2 and atan2pi, unresolved results explicitly panic rather
//! than returning a fabricated fallback.

const std = @import("std");
const zmath = @import("zmath");

pub const CompareF32 = ?*const fn (f32, f32) callconv(.c) f32;
pub const CompareF64 = ?*const fn (f64, f64) callconv(.c) f64;
pub const CompareF16 = ?*const fn (f16, f16) callconv(.c) f16;

const Operation = enum(u8) {
    exp = 0,
    log = 1,
    sin = 2,
    cos = 3,
    tan = 4,
    sqrt = 5,
    hypot = 6,
    atan2 = 7,
    pow = 8,
    acos = 9,
    acosh = 10,
    acospi = 11,
    asin = 12,
    asinh = 13,
    asinpi = 14,
    atan = 15,
    atan2pi = 16,
    atanh = 17,
    atanpi = 18,
    cbrt = 19,
    cosh = 20,
    cospi = 21,
    erf = 22,
    erfc = 23,
    exp10 = 24,
    exp10m1 = 25,
    exp2 = 26,
    exp2m1 = 27,
    expm1 = 28,
    lgamma = 29,
    log10 = 30,
    log10p1 = 31,
    log1p = 32,
    log2 = 33,
    log2p1 = 34,
    rsqrt = 35,
    sinh = 36,
    sinpi = 37,
    tanh = 38,
    tanpi = 39,
    tgamma = 40,
};

const operation_count = 41;

fn Compare(comptime T: type) type {
    return ?*const fn (T, T) callconv(.c) T;
}

inline fn callZmath(
    comptime T: type,
    comptime operation: Operation,
    a: T,
    b: T,
) T {
    return switch (operation) {
        .exp => zmath.exp(a),
        .log => zmath.log(a),
        .sin => zmath.sin(a),
        .cos => zmath.cos(a),
        .tan => zmath.tan(a),
        .sqrt => zmath.sqrt(a),
        .hypot => zmath.hypot(a, b),
        .atan2 => result: {
            const value = zmath.atan2(a, b);
            if (!value.resolved) {
                @panic(
                    "zmath.atan2(" ++ @typeName(T) ++ ") returned unresolved result",
                );
            }
            break :result value.value;
        },
        .pow => zmath.pow(a, b),
        .acos => zmath.acos(a),
        .acosh => zmath.acosh(a),
        .acospi => zmath.acospi(a),
        .asin => zmath.asin(a),
        .asinh => zmath.asinh(a),
        .asinpi => zmath.asinpi(a),
        .atan => zmath.atan(a),
        .atan2pi => result: {
            const value = zmath.atan2pi(a, b);
            if (!value.resolved) {
                @panic(
                    "zmath.atan2pi(" ++ @typeName(T) ++ ") returned unresolved result",
                );
            }
            break :result value.value;
        },
        .atanh => zmath.atanh(a),
        .atanpi => zmath.atanpi(a),
        .cbrt => zmath.cbrt(a),
        .cosh => zmath.cosh(a),
        .cospi => zmath.cospi(a),
        .erf => zmath.erf(a),
        .erfc => zmath.erfc(a),
        .exp10 => zmath.exp10(a),
        .exp10m1 => zmath.exp10m1(a),
        .exp2 => zmath.exp2(a),
        .exp2m1 => zmath.exp2m1(a),
        .expm1 => zmath.expm1(a),
        .lgamma => result: {
            // The float-only comparison ABI intentionally excludes sign metadata.
            break :result zmath.lgamma(a).value;
        },
        .log10 => zmath.log10(a),
        .log10p1 => zmath.log10p1(a),
        .log1p => zmath.log1p(a),
        .log2 => zmath.log2(a),
        .log2p1 => zmath.log2p1(a),
        .rsqrt => zmath.rsqrt(a),
        .sinh => zmath.sinh(a),
        .sinpi => zmath.sinpi(a),
        .tanh => zmath.tanh(a),
        .tanpi => zmath.tanpi(a),
        .tgamma => zmath.tgamma(a),
    };
}

fn ZmathWrapper(comptime T: type, comptime operation: Operation) type {
    return struct {
        noinline fn call(a: T, b: T) callconv(.c) T {
            @setFloatMode(.strict);
            return callZmath(T, operation, a, b);
        }
    };
}

fn zigSupports(comptime T: type, comptime operation: Operation) bool {
    return switch (operation) {
        .exp,
        .log,
        .sin,
        .cos,
        .tan,
        .sqrt,
        .hypot,
        .acos,
        .asin,
        .atan,
        .exp2,
        .log10,
        .log2,
        => T == f16 or T == f32 or T == f64,

        .atan2,
        .pow,
        .acosh,
        .asinh,
        .atanh,
        .cbrt,
        .cosh,
        .expm1,
        .lgamma,
        .log1p,
        .sinh,
        .tanh,
        .tgamma,
        => T == f32 or T == f64,

        else => false,
    };
}

inline fn callZig(
    comptime T: type,
    comptime operation: Operation,
    a: T,
    b: T,
) T {
    return switch (operation) {
        .exp => @exp(a),
        .log => @log(a),
        .sin => @sin(a),
        .cos => @cos(a),
        .tan => @tan(a),
        .sqrt => @sqrt(a),
        .hypot => std.math.hypot(a, b),
        .atan2 => std.math.atan2(a, b),
        .pow => std.math.pow(T, a, b),
        .acos => std.math.acos(a),
        .acosh => std.math.acosh(a),
        .asin => std.math.asin(a),
        .asinh => std.math.asinh(a),
        .atan => std.math.atan(a),
        .atanh => std.math.atanh(a),
        .cbrt => std.math.cbrt(a),
        .cosh => std.math.cosh(a),
        .exp2 => @exp2(a),
        .expm1 => std.math.expm1(a),
        .lgamma => std.math.lgamma(T, a),
        .log10 => @log10(a),
        .log1p => std.math.log1p(a),
        .log2 => @log2(a),
        .sinh => std.math.sinh(a),
        .tanh => std.math.tanh(a),
        .tgamma => std.math.gamma(T, a),
        else => unreachable,
    };
}

fn ZigWrapper(comptime T: type, comptime operation: Operation) type {
    if (!zigSupports(T, operation)) {
        @compileError(
            "Zig baseline does not support " ++
                @tagName(operation) ++
                " for " ++
                @typeName(T),
        );
    }

    return struct {
        noinline fn call(a: T, b: T) callconv(.c) T {
            @setFloatMode(.strict);
            return callZig(T, operation, a, b);
        }
    };
}

fn makeZmathTable(comptime T: type) [operation_count]Compare(T) {
    var table: [operation_count]Compare(T) = undefined;
    inline for (std.enums.values(Operation), 0..) |operation, index| {
        table[index] = &ZmathWrapper(T, operation).call;
    }
    return table;
}

fn makeZigTable(comptime T: type) [operation_count]Compare(T) {
    var table: [operation_count]Compare(T) = undefined;
    inline for (std.enums.values(Operation), 0..) |operation, index| {
        if (zigSupports(T, operation)) {
            table[index] = &ZigWrapper(T, operation).call;
        } else {
            table[index] = null;
        }
    }
    return table;
}

const zmath_f32_functions = makeZmathTable(f32);
const zmath_f64_functions = makeZmathTable(f64);
const zmath_f16_functions = makeZmathTable(f16);
const zig_f32_functions = makeZigTable(f32);
const zig_f64_functions = makeZigTable(f64);
const zig_f16_functions = makeZigTable(f16);

fn exportName(
    comptime T: type,
    comptime provider: []const u8,
    comptime operation: Operation,
) []const u8 {
    return "compare_" ++ provider ++ "_" ++ @tagName(operation) ++ "_" ++ @typeName(T);
}

comptime {
    if (std.enums.values(Operation).len != operation_count) {
        @compileError("comparative operation count does not match the canonical mapping");
    }

    for (std.enums.values(Operation), 0..) |operation, index| {
        if (@intFromEnum(operation) != @as(u8, @intCast(index))) {
            @compileError("comparative operation IDs must remain contiguous and append-only");
        }

        for (.{ f32, f64, f16 }) |T| {
            @export(
                &ZmathWrapper(T, operation).call,
                .{ .name = exportName(T, "zmath", operation) },
            );
            if (zigSupports(T, operation)) {
                @export(
                    &ZigWrapper(T, operation).call,
                    .{ .name = exportName(T, "zig", operation) },
                );
            }
        }
    }
}

fn compareZmathF32(op: u32) callconv(.c) CompareF32 {
    if (op >= operation_count) return null;
    return zmath_f32_functions[@intCast(op)];
}

fn compareZmathF64(op: u32) callconv(.c) CompareF64 {
    if (op >= operation_count) return null;
    return zmath_f64_functions[@intCast(op)];
}

fn compareZmathF16(op: u32) callconv(.c) CompareF16 {
    if (op >= operation_count) return null;
    return zmath_f16_functions[@intCast(op)];
}

fn compareZigF32(op: u32) callconv(.c) CompareF32 {
    if (op >= operation_count) return null;
    return zig_f32_functions[@intCast(op)];
}

fn compareZigF64(op: u32) callconv(.c) CompareF64 {
    if (op >= operation_count) return null;
    return zig_f64_functions[@intCast(op)];
}

fn compareZigF16(op: u32) callconv(.c) CompareF16 {
    if (op >= operation_count) return null;
    return zig_f16_functions[@intCast(op)];
}

// The C ABI spellings are fixed by `bench/comparative.h` and consumed by
// `bench/comparative.cpp`, so the Zig-level names stay camelCase while the
// exported symbols remain the published `compare_*` names.
comptime {
    @export(&compareZmathF32, .{ .name = "compare_zmath_f32" });
    @export(&compareZmathF64, .{ .name = "compare_zmath_f64" });
    @export(&compareZmathF16, .{ .name = "compare_zmath_f16" });
    @export(&compareZigF32, .{ .name = "compare_zig_f32" });
    @export(&compareZigF64, .{ .name = "compare_zig_f64" });
    @export(&compareZigF16, .{ .name = "compare_zig_f16" });
}
