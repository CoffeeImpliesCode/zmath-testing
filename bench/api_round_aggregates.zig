//! Measurement registry for the public aggregate surfaces: `zmath.complex`,
//! `zmath.matrix`, and `zmath.linalg`.
//!
//! Every declared public entry point of those three modules and every concrete
//! type-method family of `Mat`, `LuMat*`, and `CholeskyMat*` appears in
//! `cases`. Each is timed directly; nothing is reached only indirectly, and the
//! compile-only entries are listed with their reason at the bottom of this file.
//!
//! Input regimes. `.normal` is a spread over (-1, +1) built from 24 bits of the
//! runtime index. `.boundary` draws signed zeros, both infinities, quiet and
//! signalling NaNs with payloads, the smallest normals and subnormals, both
//! signs of the maximum, the powers of two bracketing the overflow and
//! underflow windows of both the magnitude reduction and the scaled square-root
//! reduction, the branch-cut angles, and the pole arguments. `.skewed` is the
//! normal spread multiplied by an independent power of two per element spanning
//! 2^-40 to 2^+40, which is what makes contraction cancellation, pivot growth,
//! element-range overflow, and the scaling reductions reachable.
//!
//! Timing boundary. The runner hands an `invoke` nothing but the runtime index,
//! so every fixture below is decoded INSIDE the timed region, and the number a
//! row reports is that decode plus the advertised operation plus
//! `common.hash`. No row in this file is bare kernel latency, and none of them
//! claims to be: the decode is kept cheap enough not to dominate by
//! construction, being integer bit work plus a couple of plain IEEE operations
//! per element, with no loop over an exponent and no accepted kernel call
//! anywhere in fixture construction.
//!
//! Charging. `Case.f32` counts accepted binary32 kernel evaluations reached by
//! ONE `invoke` call, so the runner reserves `count * calls`. Plain IEEE add,
//! subtract, multiply, divide, negate, and compare reach no accepted kernel and
//! are not charged: a real-entry matrix entrywise operation, `mul`, `mulVec`,
//! `determinant`, `inverse`, and every LU operation therefore charge nothing.
//! A complex entry routes through `zmath.complex`'s binary kernels, which are
//! also plain IEEE arithmetic, so a complex-entry matrix operation charges
//! nothing either. A complex transcendental charges every accepted binary32
//! kernel reachable on ANY path of that one call, the scaled paths included, so
//! every count here is an upper bound per call.
//!
//! A row name says where its constructor runs. A `pipeline` row builds its
//! factorization inside the timed region, so it is charged what that
//! constructor reaches on top of the advertised method: `lu` reaches no
//! accepted kernel, so a binary32 pipeline LU row charges nothing, while a
//! binary32 pipeline Cholesky row charges one `sqrtf` per diagonal factor,
//! exactly as a bare `cholesky` row does. A `stored` row hands the method a
//! factorization written field by field from exact dyadic values, so no
//! constructor is inside it at all and those rows charge nothing. binary64
//! kernels are never charged and binary64 cases leave `f32` empty.
const std = @import("std");
const common = @import("api_round_common.zig");
const zmath = @import("zmath");

const matrix = zmath.matrix;
const linalg = zmath.linalg;
const complex = zmath.complex;

const Complexf = complex.Complexf;
const Complexd = complex.Complexd;
const Vec2f = zmath.vector.Vec2f;
const Vec3f = zmath.vector.Vec3f;
const Vec4f = zmath.vector.Vec4f;
const Vec2d = zmath.vector.Vec2d;
const Vec3d = zmath.vector.Vec3d;
const Vec4d = zmath.vector.Vec4d;

// ---------------------------------------------------------------------------
// Charge tables: flat verbatim accepted leaf symbols, per one invoke call.
// ---------------------------------------------------------------------------

const charge_none: []const common.Charge = &.{};

const charge_hypotf: []const common.Charge = &.{
    .{ .operation = "hypotf", .count = 1 },
};
const charge_atan2f: []const common.Charge = &.{
    .{ .operation = "atan2f", .count = 1 },
};
const charge_expf: []const common.Charge = &.{
    .{ .operation = "expf", .count = 1 },
    .{ .operation = "cosf", .count = 1 },
    .{ .operation = "sinf", .count = 1 },
    .{ .operation = "fmaf", .count = 1 },
};
const charge_logf: []const common.Charge = &.{
    .{ .operation = "logf", .count = 1 },
    .{ .operation = "hypotf", .count = 1 },
    .{ .operation = "atan2f", .count = 1 },
};
const charge_log10f: []const common.Charge = &.{
    .{ .operation = "log10f", .count = 1 },
    .{ .operation = "hypotf", .count = 1 },
    .{ .operation = "atan2f", .count = 1 },
};
const charge_sqrtf: []const common.Charge = &.{
    .{ .operation = "sqrtf", .count = 1 },
    .{ .operation = "hypotf", .count = 1 },
    .{ .operation = "frexpf", .count = 1 },
    .{ .operation = "scalbnf", .count = 4 },
};
const charge_powf: []const common.Charge = &.{
    .{ .operation = "powf", .count = 1 },
    .{ .operation = "expf", .count = 1 },
    .{ .operation = "cosf", .count = 1 },
    .{ .operation = "sinf", .count = 1 },
    .{ .operation = "logf", .count = 1 },
    .{ .operation = "hypotf", .count = 1 },
    .{ .operation = "atan2f", .count = 1 },
    .{ .operation = "fmaf", .count = 1 },
};
const charge_sincosf: []const common.Charge = &.{
    .{ .operation = "sinf", .count = 1 },
    .{ .operation = "cosf", .count = 1 },
    .{ .operation = "sinhf", .count = 1 },
    .{ .operation = "coshf", .count = 1 },
    .{ .operation = "fmaf", .count = 1 },
};
const charge_tanf: []const common.Charge = &.{
    .{ .operation = "sinf", .count = 1 },
    .{ .operation = "cosf", .count = 1 },
    .{ .operation = "sinhf", .count = 1 },
    .{ .operation = "coshf", .count = 1 },
    .{ .operation = "tanhf", .count = 1 },
    .{ .operation = "tanf", .count = 1 },
    .{ .operation = "fmaf", .count = 2 },
};
const charge_tanhf: []const common.Charge = &.{
    .{ .operation = "sinf", .count = 1 },
    .{ .operation = "cosf", .count = 1 },
    .{ .operation = "sinhf", .count = 1 },
    .{ .operation = "coshf", .count = 1 },
    .{ .operation = "tanhf", .count = 1 },
    .{ .operation = "fmaf", .count = 1 },
};
const charge_asinf: []const common.Charge = &.{
    .{ .operation = "sqrtf", .count = 2 },
    .{ .operation = "hypotf", .count = 3 },
    .{ .operation = "frexpf", .count = 2 },
    .{ .operation = "scalbnf", .count = 8 },
    .{ .operation = "logf", .count = 1 },
    .{ .operation = "atan2f", .count = 1 },
};
const charge_atanf: []const common.Charge = &.{
    .{ .operation = "logf", .count = 2 },
    .{ .operation = "hypotf", .count = 2 },
    .{ .operation = "atan2f", .count = 2 },
};

const charge_chol2f: []const common.Charge = &.{
    .{ .operation = "sqrtf", .count = 2 },
};
const charge_chol3f: []const common.Charge = &.{
    .{ .operation = "sqrtf", .count = 3 },
};
const charge_chol4f: []const common.Charge = &.{
    .{ .operation = "sqrtf", .count = 4 },
};

// ---------------------------------------------------------------------------
// Deterministic input construction.
//
// All of this runs inside the timed `invoke`, because that is where the index
// arrives; see the timing boundary note above. Nothing here is
// constant-foldable: every value is a function of the runtime index the runner
// varies, so the compiler cannot fold a case away. Nothing here calls an
// accepted kernel either, so a fixture never enters a charge.
// ---------------------------------------------------------------------------

const Regime = enum { normal, boundary, skewed };

fn spread(comptime T: type, raw: u64) T {
    const unit_bits: u32 = @as(u32, @truncate(raw >> 32)) & 0x00ff_ffff;
    const unit: T = @floatFromInt(unit_bits);
    const value = unit * @as(T, 1.0 / 16777216.0) - @as(T, 1.0);
    return if ((raw & 1) == 0) value else -value;
}

/// `2^exponent`, written straight into the biased exponent field of `T`.
///
/// The builders below only ask for `exponent` in `[-40, 40]`, which is inside
/// the normal range of both formats, so `127 + exponent` and `1023 + exponent`
/// are always in range and the result is exact. Encoding the field is a cast
/// and a shift where the loop it replaces was up to `exponent` floating-point
/// operations of pure fixture cost, which for a `.skewed` input exceeded the
/// arithmetic the surrounding case was supposed to measure.
fn powerOfTwoAt(comptime T: type, exponent: i32) T {
    if (T == f32) {
        const biased: u32 = @intCast(127 + exponent);
        return @bitCast(biased << 23);
    }
    const biased: u64 = @intCast(1023 + exponent);
    return @bitCast(biased << 52);
}

fn skew(comptime T: type, raw: u64) T {
    const exponent: i32 = @as(i32, @intCast((raw >> 40) % 81)) - 40;
    return spread(T, raw) * powerOfTwoAt(T, exponent);
}

fn fromBits(comptime T: type, comptime bits_f32: u32, comptime bits_f64: u64) T {
    return if (T == f32)
        @as(T, @bitCast(@as(u32, bits_f32)))
    else
        @as(T, @bitCast(@as(u64, bits_f64)));
}

fn special(comptime T: type, tag: u32) T {
    return switch (tag) {
        0 => @as(T, 0.0),
        1 => -@as(T, 0.0),
        2 => @as(T, 1.0),
        3 => -@as(T, 1.0),
        4 => fromBits(T, 0x7f80_0000, 0x7ff0_0000_0000_0000),
        5 => fromBits(T, 0xff80_0000, 0xfff0_0000_0000_0000),
        6 => fromBits(T, 0x7fc0_0000, 0x7ff8_0000_0000_0000),
        7 => fromBits(T, 0xffc0_0000, 0xfff8_0000_0000_0000),
        8 => fromBits(T, 0x7f80_0001, 0x7ff0_0000_0000_0001),
        9 => fromBits(T, 0xff80_0001, 0xfff0_0000_0000_0001),
        10 => fromBits(T, 0x7f7f_ffff, 0x7fef_ffff_ffff_ffff),
        11 => fromBits(T, 0xff7f_ffff, 0xffef_ffff_ffff_ffff),
        12 => fromBits(T, 0x0080_0000, 0x0010_0000_0000_0000),
        13 => fromBits(T, 0x0000_0001, 0x0000_0000_0000_0001),
        14 => fromBits(T, 0x8000_0001, 0x8000_0000_0000_0001),
        15 => fromBits(T, 0x0d80_0000, 0x0170_0000_0000_0000),
        16 => fromBits(T, 0x7180_0000, 0x7e70_0000_0000_0000),
        17 => fromBits(T, 0x2000_0000, 0x2000_0000_0000_0000),
        18 => fromBits(T, 0x5f00_0000, 0x5ff0_0000_0000_0000),
        19 => @as(T, 0.5),
        20 => -@as(T, 0.5),
        21 => @as(T, 3.141592653589793),
        22 => -@as(T, 3.141592653589793),
        23 => @as(T, 1.5707963267948966),
        24 => @as(T, 1e30),
        25 => -@as(T, 1e-30),
        26 => @as(T, 0.1),
        27 => @as(T, 2.0),
        28 => -@as(T, 2.0),
        29 => @as(T, 1e-45),
        30 => @as(T, 1e38),
        31 => @as(T, 0.7071067811865476),
        else => @as(T, 3.0),
    };
}

fn seed(index: usize, salt: u64) u64 {
    return common.mix(@as(u64, @intCast(index)), salt);
}

fn realAt(comptime T: type, comptime regime: Regime, index: usize, salt: u64) T {
    const raw = common.mix(@as(u64, @intCast(index)), salt);
    return switch (regime) {
        .normal => spread(T, raw),
        .boundary => special(T, @as(u32, @truncate(raw % 32))),
        .skewed => skew(T, raw),
    };
}

fn realOfComplex(comptime C: type) type {
    return if (C == Complexf) f32 else f64;
}

fn complexAt(comptime C: type, comptime regime: Regime, index: usize, salt: u64) C {
    const R = realOfComplex(C);
    return .{
        .re = realAt(R, regime, index, salt),
        .im = realAt(R, regime, index, common.mix(salt, 0x5bd1_e995_1cf1_0d3b)),
    };
}

fn entryAt(comptime S: type, comptime regime: Regime, index: usize, salt: u64) S {
    if (S == f32 or S == f64) return realAt(S, regime, index, salt);
    const R = if (S == Complexf) f32 else f64;
    return .{
        .re = realAt(R, regime, index, salt),
        .im = realAt(R, regime, index, common.mix(salt, 0x1b87_3593_ca3a_d005)),
    };
}

fn matAt(comptime M: type, comptime regime: Regime, index: usize, salt: u64) M {
    var out: M = undefined;
    inline for (0..M.columns) |column| {
        inline for (0..M.rows) |row| {
            out.data[column][row] = entryAt(
                M.Element,
                regime,
                index,
                common.mix(salt, column * 0x9e37_79b9 + row * 0x85eb_ca6b),
            );
        }
    }
    return out;
}

/// The `Mat.mulVec` argument type: the named vector when one matches the column
/// count and the entry type, the plain array otherwise. This mirrors the
/// declared `input_lane` of `zmath.matrix.VecOf`.
fn InputVec(comptime M: type) type {
    const S = M.Element;
    const n = M.columns;
    if (S == f32) {
        return switch (n) {
            2 => Vec2f,
            3 => Vec3f,
            4 => Vec4f,
            else => [n]f32,
        };
    }
    if (S == f64) {
        return switch (n) {
            2 => Vec2d,
            3 => Vec3d,
            4 => Vec4d,
            else => [n]f64,
        };
    }
    return [n]S;
}

fn vectorAt(comptime M: type, comptime regime: Regime, index: usize, salt: u64) InputVec(M) {
    var lanes: [M.columns]M.Element = undefined;
    inline for (0..M.columns) |lane| {
        lanes[lane] = entryAt(M.Element, regime, index, common.mix(salt, lane * 0xc2b2_ae35));
    }
    const V = InputVec(M);
    if (comptime @typeInfo(V) == .array) return lanes;
    return V.fromArray(lanes);
}

fn outVectorAt(comptime M: type, index: usize, salt: u64) M.vector_type {
    var lanes: [M.rows]M.Element = undefined;
    inline for (0..M.rows) |lane| {
        lanes[lane] = entryAt(M.Element, .normal, index, common.mix(salt, lane * 0x27d4_eb2f));
    }
    const V = M.vector_type;
    if (comptime @typeInfo(V) == .array) return lanes;
    return V.fromArray(lanes);
}

/// The right-hand side of the stored-factor overflow rows. `1e30` is an
/// ordinary magnitude of BOTH formats, so every component is inside the range a
/// solve may read and a non-finite answer can only come from the arithmetic
/// rather than from an input that was already out of range.
///
/// What leaves the range is the stored factor these rows pair it with:
/// `overflowFactorOf(T) * 1e30` is `1e68` for binary32 and `1e330` for
/// binary64, an infinity in both.
fn hugeVectorAt(comptime M: type) M.vector_type {
    var lanes: [M.rows]M.Element = undefined;
    inline for (0..M.rows) |lane| lanes[lane] = 1e30;
    const V = M.vector_type;
    if (comptime @typeInfo(V) == .array) return lanes;
    return V.fromArray(lanes);
}

fn hugeMatrixAt(comptime M: type, comptime n_columns: usize) matrix.Mat(M.rows, n_columns, M.Element) {
    var out: matrix.Mat(M.rows, n_columns, M.Element) = undefined;
    inline for (0..n_columns) |column| {
        inline for (0..M.rows) |row| out.data[column][row] = 1e30;
    }
    return out;
}

fn rhsAt(comptime M: type, comptime n_columns: usize, index: usize, salt: u64) matrix.Mat(M.rows, n_columns, M.Element) {
    var out: matrix.Mat(M.rows, n_columns, M.Element) = undefined;
    inline for (0..n_columns) |column| {
        inline for (0..M.rows) |row| {
            out.data[column][row] = entryAt(
                M.Element,
                .normal,
                index,
                common.mix(salt, column * 0x1656_67b1 + row * 0x9e37_79b9),
            );
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Factorization input builders.
// ---------------------------------------------------------------------------

/// The refusals a `lu` or `cholesky` constructor can answer `null` for.
const Refusal = enum {
    singular,
    nonfinite,
    nan_input,
    small_pivot,
    asymmetric,
    not_positive_definite,
};

fn LuTypeFor(comptime M: type) type {
    return switch (M) {
        matrix.Mat2f => linalg.LuMat2f,
        matrix.Mat3f => linalg.LuMat3f,
        matrix.Mat4f => linalg.LuMat4f,
        matrix.Mat2d => linalg.LuMat2d,
        matrix.Mat3d => linalg.LuMat3d,
        matrix.Mat4d => linalg.LuMat4d,
        else => @compileError("api_round_aggregates: no LU factorization type for this matrix"),
    };
}

fn CholTypeFor(comptime M: type) type {
    return switch (M) {
        matrix.Mat2f => linalg.CholeskyMat2f,
        matrix.Mat3f => linalg.CholeskyMat3f,
        matrix.Mat4f => linalg.CholeskyMat4f,
        matrix.Mat2d => linalg.CholeskyMat2d,
        matrix.Mat3d => linalg.CholeskyMat3d,
        matrix.Mat4d => linalg.CholeskyMat4d,
        else => @compileError("api_round_aggregates: no Cholesky factorization type for this matrix"),
    };
}

/// Strictly diagonally dominant, so every pivot clears the threshold, and
/// varied by `index`, so no call can be constant folded. `skewed` puts a
/// different power of two on every diagonal, which is the element-growth
/// stress the threshold exists for.
fn dominantInput(comptime M: type, comptime skewed: bool, index: usize) M {
    const T = M.Element;
    var out: M = undefined;
    inline for (0..M.columns) |column| {
        inline for (0..M.rows) |row| {
            if (row == column) {
                const exponent: i32 = @intCast((seed(index, 0x51ed_270b + column) >> 40) % 21);
                out.data[column][row] =
                    (if (skewed) @as(T, 4.0) * powerOfTwoAt(T, exponent) else @as(T, 4.0)) +
                    @abs(spread(T, seed(index, 0x1111_1111 + row * 7 + column)));
            } else {
                out.data[column][row] = spread(T, seed(index, 0x2222_2222 + column * 11 + row * 13));
            }
        }
    }
    return out;
}

fn symmetricInput(comptime M: type, comptime skewed: bool, index: usize) M {
    const T = M.Element;
    var out: M = undefined;
    inline for (0..M.columns) |column| {
        inline for (0..M.rows) |row| {
            if (row < column) {
                out.data[column][row] = out.data[row][column];
            } else if (row == column) {
                const exponent: i32 = @intCast((seed(index, 0x2545_f491 + row) >> 40) % 21);
                out.data[column][row] =
                    (if (skewed) @as(T, 4.0) * powerOfTwoAt(T, exponent) else @as(T, 4.0)) +
                    @abs(spread(T, seed(index, 0x3333_3333 + row * 5)));
            } else {
                out.data[column][row] = spread(T, seed(index, 0x4444_4444 + column * 17 + row * 3));
            }
        }
    }
    return out;
}

fn luRefusedInput(comptime M: type, comptime refusal: Refusal, index: usize) M {
    const T = M.Element;
    var out = dominantInput(M, false, index);
    switch (refusal) {
        .singular => {
            inline for (0..M.columns) |column| {
                const value = spread(T, seed(index, 0x5555_5555 + column));
                inline for (0..M.rows) |row| out.data[column][row] = value;
            }
        },
        .nonfinite => out.data[0][0] = special(T, 4),
        .nan_input => out.data[0][0] = special(T, 6),
        .small_pivot => {
            inline for (0..M.rows) |row| out.data[0][row] = 1e-30;
        },
        else => {},
    }
    return out;
}

fn cholRefusedInput(comptime M: type, comptime refusal: Refusal, index: usize) M {
    const T = M.Element;
    var out = symmetricInput(M, false, index);
    switch (refusal) {
        .asymmetric => out.data[M.rows - 1][M.rows - 2] = out.data[M.rows - 2][M.rows - 1] + @as(T, 1e-3),
        .not_positive_definite => {
            inline for (0..M.rows) |k| out.data[k][k] = -@as(T, 1);
        },
        .nonfinite => out.data[0][0] = special(T, 4),
        .nan_input => out.data[0][0] = special(T, 6),
        .small_pivot => out.data[0][0] = 1e-30,
        .singular => {},
    }
    return out;
}

/// A pivot above the threshold whose reciprocal overflows the format, so the
/// reduction normalizes the right block past the range and the post-condition
/// finiteness check answers `null` rather than an infinity.
fn tinyPivotOf(comptime T: type) T {
    if (T == f32) return 2e-39;
    return 1e-309;
}

fn tinyScaleOf(comptime T: type) T {
    if (T == f32) return 1e-33;
    return 1e-295;
}

/// A stored factor entry whose product with the right-hand side leaves the
/// format's range: `1e38 * 1e30` is `1e68` for binary32 and `1e300 * 1e30` is
/// `1e330` for binary64. Both are finite in their own format, so the overflow
/// belongs to the substitution and not to a factor that was already invalid.
fn overflowFactorOf(comptime T: type) T {
    if (T == f32) return 1e38;
    return 1e300;
}

/// A stored Cholesky pivot whose quotient by the right-hand side leaves the
/// format's range: `1e30 / 1e-30` is `1e60` for binary32 and `1e30 / 1e-300`
/// is `1e330` for binary64. It is positive, finite and nonzero, so the solve's
/// own pivot test passes and the answer is a value rather than `null`.
fn overflowPivotOf(comptime T: type) T {
    if (T == f32) return 1e-30;
    return 1e-300;
}

fn overflowInverseInput(comptime M: type, index: usize) M {
    const T = M.Element;
    var out: M = undefined;
    inline for (0..M.columns) |column| {
        inline for (0..M.rows) |row| {
            out.data[column][row] = if (column == 0)
                tinyPivotOf(T)
            else
                tinyScaleOf(T) * (1 + @abs(spread(T, seed(index, 0x6a09_e667 + row * 5 + column))));
        }
    }
    return out;
}

/// Every row identical, so the elimination annihilates the whole first column
/// and no pivot remains above the threshold.
fn singularInput(comptime M: type, index: usize) M {
    const T = M.Element;
    var out: M = undefined;
    inline for (0..M.columns) |column| {
        const value = spread(T, seed(index, 0xbb67_ae85 + column));
        inline for (0..M.rows) |row| out.data[column][row] = value;
    }
    return out;
}

fn nonfiniteInverseInput(comptime M: type, comptime tag: u32, index: usize) M {
    var out = dominantInput(M, false, index);
    out.data[0][0] = special(M.Element, tag);
    return out;
}

fn smallPivotInverseInput(comptime M: type, index: usize) M {
    var out = dominantInput(M, false, index);
    inline for (0..M.rows) |row| out.data[0][row] = 1e-30;
    return out;
}

/// The solve policies. `from_factors` is the consumer pipeline: the
/// factorization is produced inside `invoke`, so that row times the
/// constructor AND the advertised solve. The other three build the stored
/// factors field by field instead, so they time the solve alone; one drives the
/// stored pivot to the `null` branch and one makes the substitutions overflow
/// and therefore answers a non-`null` vector whose components overflow.
const SolvePolicy = enum { from_factors, zero_pivot, nonfinite_pivot, overflow };

fn unitLu(comptime M: type) LuTypeFor(M) {
    var out: LuTypeFor(M) = undefined;
    inline for (0..M.columns) |column| {
        inline for (0..M.rows) |row| {
            out.lu.data[column][row] = if (row == column) @as(M.Element, 1) else 0;
        }
    }
    inline for (0..M.rows) |i| out.permutation[i] = @intCast(i);
    out.parity = 0;
    return out;
}

fn handBuiltLu(comptime M: type, comptime policy: SolvePolicy) LuTypeFor(M) {
    const T = M.Element;
    const n = M.rows;
    var out = unitLu(M);
    switch (policy) {
        .from_factors => {},
        .zero_pivot => out.lu.data[n - 1][n - 1] = 0,
        .nonfinite_pivot => out.lu.data[n - 1][n - 1] = special(T, 6),
        .overflow => {
            // A unit lower triangle whose FIRST COLUMN holds
            // `overflowFactorOf(T)`, an upper triangle of ones, the identity
            // permutation, and the parity of a permutation that moved
            // nothing. The stored value is a factorization of a finite matrix
            // and every stored pivot is finite and nonzero, so the only thing
            // that can leave the range is the substitution itself: the first
            // row of the forward substitution multiplies
            // `overflowFactorOf(T)` by a right-hand side entry and that product
            // is an infinity in both formats.
            inline for (0..n) |column| {
                inline for (0..n) |row| {
                    out.lu.data[column][row] = if (row == column)
                        @as(T, 1)
                    else if (column == 0)
                        overflowFactorOf(T)
                    else
                        @as(T, 1);
                }
            }
            inline for (0..n) |i| out.permutation[i] = @intCast(i);
            out.parity = 0;
        },
    }
    return out;
}

fn handBuiltCholesky(comptime M: type, comptime policy: SolvePolicy) CholTypeFor(M) {
    const T = M.Element;
    const n = M.rows;
    var out: CholTypeFor(M) = undefined;
    switch (policy) {
        .from_factors => {
            inline for (0..n) |column| {
                inline for (0..n) |row| {
                    out.lower.data[column][row] = if (row == column) @as(T, 1) else 0;
                }
            }
        },
        .zero_pivot => {
            inline for (0..n) |column| {
                inline for (0..n) |row| {
                    out.lower.data[column][row] = if (row == column) @as(T, 1) else 0;
                }
            }
            out.lower.data[0][0] = 0;
        },
        .nonfinite_pivot => {
            inline for (0..n) |column| {
                inline for (0..n) |row| {
                    out.lower.data[column][row] = if (row == column) @as(T, 1) else 0;
                }
            }
            out.lower.data[0][0] = special(T, 6);
        },
        .overflow => {
            // The STRICT LOWER TRIANGLE, which is the only triangle a
            // `CholeskyMat` stores, with a positive finite pivot and
            // `overflowFactorOf(T)` in the first column. This family overflows
            // on both halves of the solve and in both formats: the first
            // forward step divides by `overflowPivotOf(T)`, and the first
            // column of L multiplies that infinity by a finite entry. The
            // pivots stay finite and nonzero, so the answer is a value.
            inline for (0..n) |column| {
                inline for (0..n) |row| {
                    out.lower.data[column][row] = if (row == column)
                        overflowPivotOf(T)
                    else if (row < column)
                        @as(T, 0)
                    else if (column == 0)
                        overflowFactorOf(T)
                    else
                        @as(T, 1);
                }
            }
        },
    }
    return out;
}

// ---------------------------------------------------------------------------
// Stored factorizations for the isolated method rows.
//
// A `stored` row measures ONE advertised method. The factorization that method
// reads is written here field by field and is never produced by `linalg.lu` or
// `linalg.cholesky`, so no constructor sits inside the timed region and the
// row charges nothing. The fields stay a function of the runtime index, which a
// `comptime` literal would not be: a literal factor would let the whole call
// fold at compile time and the timed `invoke` would collapse into returning
// one already-computed `u64`. Writing the fields from index bits costs one
// multiply and some masks per entry and no floating-point operation at all.
//
// The factors are valid, not arbitrary. `lu` holds a unit lower triangle
// times an upper triangle whose diagonal dominates every row, `permutation` is
// a genuine transposition of `0..n-1`, and `parity` is its sign, so the value
// really is a factorization of the well-conditioned matrix `L * U` and
// `reconstructLu` returns that matrix. `lower` holds a lower triangle with a
// positive dominant diagonal and a zero strict upper triangle, so the value
// really is a factorization of the positive definite `L * transpose(L)` and
// `reconstructCholesky` returns that matrix.

/// One exact dyadic of `T` with magnitude from `2^lo` through `2^(lo+span)`.
///
/// Assembled bit by bit: the format's mantissa bits, then the biased exponent
/// for `lo` plus a `span` offset, then the sign. `positive` drops the sign so a
/// factor diagonal is a diagonal. No arithmetic runs here, so every value is
/// exact and building one costs nothing a measured method can notice.
fn dyadicAt(comptime T: type, comptime lo: i32, comptime span: u32, comptime positive: bool, raw: u64) T {
    if (T == f32) {
        const mantissa: u32 = @truncate(raw & 0x007f_ffff);
        const step: u32 = @mod(@as(u32, @truncate(raw >> 23)), @as(u32, span) + 1);
        const biased: u32 = @intCast(127 + lo + @as(i32, @intCast(step)));
        const sign: u32 = if (positive) 0 else @as(u32, @truncate(raw >> 32)) & 0x8000_0000;
        return @bitCast((biased << 23) | mantissa | sign);
    }
    const mantissa: u64 = raw & 0x000f_ffff_ffff_ffff;
    const step: u64 = @mod(raw >> 52, @as(u64, span) + 1);
    const biased: u64 = @intCast(1023 + lo + @as(i32, @intCast(step)));
    const sign: u64 = if (positive) 0 else raw & 0x8000_0000_0000_0000;
    return @bitCast((biased << 52) | mantissa | sign);
}

/// A per-entry view of the index word: one wrapping multiply by a constant that
/// differs with `position`, which scrambles the whole word, so entries differ
/// in their mantissa, their exponent offset and their sign alike. One multiply
/// against the O(n^3) of the method it feeds.
fn entryWord(raw: u64, comptime position: usize) u64 {
    return raw *% (0x9e37_79b9_7f4a_7c15 +% @as(u64, position));
}

/// A valid stored LU factorization of a well-conditioned matrix. The strictly
/// lower triangle is a set of L multipliers of magnitude below one, the
/// diagonal is positive and dominates its row, and the upper triangle is
/// bounded by half, so `L` is unit lower triangular, `U` is invertible and the
/// product is finite for every size and precision here.
fn storedLu(comptime M: type, index: usize) LuTypeFor(M) {
    const T = M.Element;
    const n = M.rows;
    const raw = seed(index, 0x2545_f491_4f6c_dd1d);
    var out: LuTypeFor(M) = undefined;
    inline for (0..n) |column| {
        inline for (0..n) |row| {
            out.lu.data[column][row] = if (row == column)
                dyadicAt(T, 5, 3, true, entryWord(raw, column * n + row))
            else
                dyadicAt(T, -4, 3, false, entryWord(raw, column * n + row));
        }
    }
    inline for (0..n) |row| out.permutation[row] = @intCast(row);
    if ((raw >> 63) != 0) {
        out.permutation[0] = 1;
        out.permutation[1] = 0;
        out.parity = -1;
    } else {
        out.parity = 0;
    }
    return out;
}

/// A valid stored Cholesky factorization: a lower triangle with a positive
/// dominant diagonal and a strict upper triangle of zero, so the matrix it
/// factorizes is `L * transpose(L)` for a positive definite `L`.
fn storedCholesky(comptime M: type, index: usize) CholTypeFor(M) {
    const T = M.Element;
    const n = M.rows;
    const raw = seed(index, 0x1b87_3593_ca3a_d005);
    var out: CholTypeFor(M) = undefined;
    inline for (0..n) |column| {
        inline for (0..n) |row| {
            out.lower.data[column][row] = if (row == column)
                dyadicAt(T, 5, 3, true, entryWord(raw, column * n + row))
            else if (row > column)
                dyadicAt(T, -4, 3, false, entryWord(raw, column * n + row))
            else
                @as(T, 0);
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Complex invokes. Every semantic field of the result is hashed.
// ---------------------------------------------------------------------------

fn complexUnaryRealInvoke(
    comptime C: type,
    comptime regime: Regime,
    comptime op: anytype,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            return common.hash(op(complexAt(C, regime, index, 0x5bf0_3635_9e37_79b9)));
        }
    };
    return Impl.invoke;
}

fn complexUnaryComplexInvoke(
    comptime C: type,
    comptime regime: Regime,
    comptime op: anytype,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            return common.hash(op(complexAt(C, regime, index, 0x5bf0_3635_9e37_79b9)));
        }
    };
    return Impl.invoke;
}

fn complexBinaryInvoke(
    comptime C: type,
    comptime regime: Regime,
    comptime op: anytype,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            const a = complexAt(C, regime, index, 0x2545_f491_4f6c_dd1d);
            const b = complexAt(C, regime, index, 0x9e37_79b9_7f4a_7c15);
            return common.hash(op(a, b));
        }
    };
    return Impl.invoke;
}

// ---------------------------------------------------------------------------
// Matrix invokes.
// ---------------------------------------------------------------------------

fn matUnaryInvoke(
    comptime M: type,
    comptime regime: Regime,
    comptime op: anytype,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            return common.hash(op(matAt(M, regime, index, 0x68bc_21eb_1f5d_3b1a)));
        }
    };
    return Impl.invoke;
}

fn matBinaryInvoke(
    comptime M: type,
    comptime regime: Regime,
    comptime op: anytype,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            const a = matAt(M, regime, index, 0x68bc_21eb_1f5d_3b1a);
            const Second = @typeInfo(@TypeOf(op)).@"fn".params[1].type.?;
            const b = if (comptime Second == M.Element)
                entryAt(M.Element, regime, index, 0x02e5_be93_c86b_a26b)
            else
                matAt(M, regime, index, 0x02e5_be93_c86b_a26b);
            return common.hash(op(a, b));
        }
    };
    return Impl.invoke;
}

fn matMulVecInvoke(
    comptime M: type,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            const m = matAt(M, regime, index, 0x1b87_3593_ca3a_d005);
            const v = vectorAt(M, regime, index, 0x27d4_eb2f_1656_67b1);
            return common.hash(m.mulVec(v));
        }
    };
    return Impl.invoke;
}

fn matMulInvoke(
    comptime L: type,
    comptime R: type,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            const l = matAt(L, regime, index, 0x2545_f491_4f6c_dd1d);
            const r = matAt(R, regime, index, 0x9e37_79b9_7f4a_7c15);
            return common.hash(matrix.mul(R.columns, l, r));
        }
    };
    return Impl.invoke;
}

fn matDeterminantInvoke(
    comptime M: type,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            return common.hash(matAt(M, regime, index, 0xc2b2_ae35_7d17_c62b).determinant());
        }
    };
    return Impl.invoke;
}

fn singularDeterminantInvoke(
    comptime M: type,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            return common.hash(singularInput(M, index).determinant());
        }
    };
    return Impl.invoke;
}

fn matFreeOpInvoke(
    comptime M: type,
    comptime regime: Regime,
    comptime op: anytype,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            return common.hash(op(matAt(M, regime, index, 0x1656_67b1_9e37_79b9)));
        }
    };
    return Impl.invoke;
}

fn singularInverseInvoke(
    comptime M: type,
    comptime op: anytype,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            return common.hash(op(singularInput(M, index)));
        }
    };
    return Impl.invoke;
}

fn nonfiniteInverseInvoke(
    comptime M: type,
    comptime op: anytype,
    comptime tag: u32,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            return common.hash(op(nonfiniteInverseInput(M, tag, index)));
        }
    };
    return Impl.invoke;
}

fn smallPivotInverseInvoke(
    comptime M: type,
    comptime op: anytype,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            return common.hash(op(smallPivotInverseInput(M, index)));
        }
    };
    return Impl.invoke;
}

fn overflowInverseInvoke(
    comptime M: type,
    comptime op: anytype,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            return common.hash(op(overflowInverseInput(M, index)));
        }
    };
    return Impl.invoke;
}

fn matInitInvoke(
    comptime M: type,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            var literal: [M.rows][M.columns]M.Element = undefined;
            inline for (0..M.rows) |row| {
                inline for (0..M.columns) |column| {
                    literal[row][column] = entryAt(
                        M.Element,
                        regime,
                        index,
                        common.mix(0x6a09_e667, row * 31 + column * 17),
                    );
                }
            }
            return common.hash(M.init(literal));
        }
    };
    return Impl.invoke;
}

fn matFillInvoke(
    comptime M: type,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            const value = entryAt(M.Element, regime, index, 0xbb67_ae85_84ca_a73b);
            return common.hash(M.fill(value));
        }
    };
    return Impl.invoke;
}

fn matAtInvoke(
    comptime M: type,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            const m = matAt(M, regime, index, 0x3c6e_f372_fe94_f82b);
            return common.hash(m.at(index % M.rows, index % M.columns));
        }
    };
    return Impl.invoke;
}

fn matSetInvoke(
    comptime M: type,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            var m = matAt(M, regime, index, 0xa54f_f53a_5f1d_36f1);
            const value = entryAt(M.Element, regime, index, 0x510e_527f_ade6_82d1);
            m.set(index % M.rows, index % M.columns, value);
            return common.hash(m);
        }
    };
    return Impl.invoke;
}

fn matIsFiniteInvoke(
    comptime M: type,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            return common.hash(matAt(M, regime, index, 0x9b05_688c_2b3e_6c1f).isFinite());
        }
    };
    return Impl.invoke;
}

fn matVecFreeInvoke(
    comptime M: type,
    comptime regime: Regime,
    comptime op: anytype,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            const m = matAt(M, regime, index, 0x1f83_d9ab_fb41_bd6b);
            const v = vectorAt(M, regime, index, 0x5be0_cd19_137e_2179);
            return common.hash(op(m, v));
        }
    };
    return Impl.invoke;
}

// ---------------------------------------------------------------------------
// Linalg invokes.
// ---------------------------------------------------------------------------

fn luFactorInvoke(
    comptime M: type,
    comptime skewed: bool,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            return common.hash(linalg.lu(dominantInput(M, skewed, index)));
        }
    };
    return Impl.invoke;
}

fn luRefusedInvoke(
    comptime M: type,
    comptime refusal: Refusal,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            return common.hash(linalg.lu(luRefusedInput(M, refusal, index)));
        }
    };
    return Impl.invoke;
}

fn luReadbackInvoke(
    comptime M: type,
    comptime readback: anytype,
    comptime skewed: bool,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            const f = linalg.lu(dominantInput(M, skewed, index)) orelse
                return common.hash(@as(?LuTypeFor(M), null));
            return common.hash(readback(f));
        }
    };
    return Impl.invoke;
}

fn solveLuInvoke(
    comptime M: type,
    comptime policy: SolvePolicy,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            const f: LuTypeFor(M) = switch (policy) {
                .from_factors => linalg.lu(dominantInput(M, false, index)) orelse
                    return common.hash(@as(?LuTypeFor(M), null)),
                else => handBuiltLu(M, policy),
            };
            const rhs = switch (policy) {
                .overflow => hugeVectorAt(M),
                else => outVectorAt(M, index, 0x9b05_688c_2b3e_6c1f),
            };
            return common.hash(linalg.solveLu(f, rhs));
        }
    };
    return Impl.invoke;
}

fn solveLuMultipleInvoke(
    comptime M: type,
    comptime n_columns: usize,
    comptime policy: SolvePolicy,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            const f: LuTypeFor(M) = switch (policy) {
                .from_factors => linalg.lu(dominantInput(M, false, index)) orelse
                    return common.hash(@as(?LuTypeFor(M), null)),
                else => handBuiltLu(M, policy),
            };
            const rhs = switch (policy) {
                .overflow => hugeMatrixAt(M, n_columns),
                else => rhsAt(M, n_columns, index, 0x1f83_d9ab_fb41_bd6b),
            };
            return common.hash(linalg.solveLuMultiple(f, rhs));
        }
    };
    return Impl.invoke;
}

fn cholFactorInvoke(
    comptime M: type,
    comptime skewed: bool,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            return common.hash(linalg.cholesky(symmetricInput(M, skewed, index)));
        }
    };
    return Impl.invoke;
}

fn cholRefusedInvoke(
    comptime M: type,
    comptime refusal: Refusal,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            return common.hash(linalg.cholesky(cholRefusedInput(M, refusal, index)));
        }
    };
    return Impl.invoke;
}

fn cholReadbackInvoke(
    comptime M: type,
    comptime readback: anytype,
    comptime skewed: bool,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            const f = linalg.cholesky(symmetricInput(M, skewed, index)) orelse
                return common.hash(@as(?CholTypeFor(M), null));
            return common.hash(readback(f));
        }
    };
    return Impl.invoke;
}

fn solveCholeskyInvoke(
    comptime M: type,
    comptime policy: SolvePolicy,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            const f: CholTypeFor(M) = switch (policy) {
                .from_factors => linalg.cholesky(symmetricInput(M, false, index)) orelse
                    return common.hash(@as(?CholTypeFor(M), null)),
                else => handBuiltCholesky(M, policy),
            };
            const rhs = switch (policy) {
                .overflow => hugeVectorAt(M),
                else => outVectorAt(M, index, 0x9b05_688c_2b3e_6c1f),
            };
            return common.hash(linalg.solveCholesky(f, rhs));
        }
    };
    return Impl.invoke;
}

fn solveCholeskyMultipleInvoke(
    comptime M: type,
    comptime n_columns: usize,
    comptime policy: SolvePolicy,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            const f: CholTypeFor(M) = switch (policy) {
                .from_factors => linalg.cholesky(symmetricInput(M, false, index)) orelse
                    return common.hash(@as(?CholTypeFor(M), null)),
                else => handBuiltCholesky(M, policy),
            };
            const rhs = switch (policy) {
                .overflow => hugeMatrixAt(M, n_columns),
                else => rhsAt(M, n_columns, index, 0x1f83_d9ab_fb41_bd6b),
            };
            return common.hash(linalg.solveCholeskyMultiple(f, rhs));
        }
    };
    return Impl.invoke;
}

// ---------------------------------------------------------------------------
// Stored-factor invokes: one advertised method per timed region, with no
// factorization inside it. The right-hand side is still decoded from the index
// per call, so nothing folds and the solve is real work on varying data.
// ---------------------------------------------------------------------------

fn luStoredReadbackInvoke(
    comptime M: type,
    comptime readback: anytype,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            return common.hash(readback(storedLu(M, index)));
        }
    };
    return Impl.invoke;
}

fn solveLuStoredInvoke(comptime M: type) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            const rhs = outVectorAt(M, index, 0x9b05_688c_2b3e_6c1f);
            return common.hash(linalg.solveLu(storedLu(M, index), rhs));
        }
    };
    return Impl.invoke;
}

fn solveLuMultipleStoredInvoke(comptime M: type, comptime n_columns: usize) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            const rhs = rhsAt(M, n_columns, index, 0x1f83_d9ab_fb41_bd6b);
            return common.hash(linalg.solveLuMultiple(storedLu(M, index), rhs));
        }
    };
    return Impl.invoke;
}

fn cholStoredReadbackInvoke(
    comptime M: type,
    comptime readback: anytype,
) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            return common.hash(readback(storedCholesky(M, index)));
        }
    };
    return Impl.invoke;
}

fn solveCholeskyStoredInvoke(comptime M: type) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            const rhs = outVectorAt(M, index, 0x9b05_688c_2b3e_6c1f);
            return common.hash(linalg.solveCholesky(storedCholesky(M, index), rhs));
        }
    };
    return Impl.invoke;
}

fn solveCholeskyMultipleStoredInvoke(comptime M: type, comptime n_columns: usize) *const fn (usize) u64 {
    const Impl = struct {
        noinline fn invoke(index: usize) u64 {
            const rhs = rhsAt(M, n_columns, index, 0x1f83_d9ab_fb41_bd6b);
            return common.hash(linalg.solveCholeskyMultiple(storedCholesky(M, index), rhs));
        }
    };
    return Impl.invoke;
}

pub const cases = blk: {
    @setEvalBranchQuota(10_000_000);
    break :blk [_]common.Case{
        .{ .name = "complex.real.f.normal", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexf, .normal, complex.realf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.real.f.boundary", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexf, .boundary, complex.realf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.real.d.normal", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexd, .normal, complex.reald), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.real.d.boundary", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexd, .boundary, complex.reald), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.imag.f.normal", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexf, .normal, complex.imagf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.imag.f.boundary", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexf, .boundary, complex.imagf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.imag.d.normal", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexd, .normal, complex.imagd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.imag.d.boundary", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexd, .boundary, complex.imagd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.conj.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.conjf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.conj.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.conjf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.conj.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.conjd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.conj.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.conjd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.proj.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.projf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.proj.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.projf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.proj.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.projd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.proj.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.projd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.abs.f.normal", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexf, .normal, complex.absf), .calls = 32, .f32 = charge_hypotf },
        .{ .name = "complex.abs.f.boundary", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexf, .boundary, complex.absf), .calls = 32, .f32 = charge_hypotf },
        .{ .name = "complex.abs.f.skewed", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexf, .skewed, complex.absf), .calls = 32, .f32 = charge_hypotf },
        .{ .name = "complex.abs.d.normal", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexd, .normal, complex.absd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.abs.d.boundary", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexd, .boundary, complex.absd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.abs.d.skewed", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexd, .skewed, complex.absd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.arg.f.normal", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexf, .normal, complex.argf), .calls = 32, .f32 = charge_atan2f },
        .{ .name = "complex.arg.f.boundary", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexf, .boundary, complex.argf), .calls = 32, .f32 = charge_atan2f },
        .{ .name = "complex.arg.f.skewed", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexf, .skewed, complex.argf), .calls = 32, .f32 = charge_atan2f },
        .{ .name = "complex.arg.d.normal", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexd, .normal, complex.argd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.arg.d.boundary", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexd, .boundary, complex.argd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.arg.d.skewed", .namespace = "complex", .invoke = complexUnaryRealInvoke(Complexd, .skewed, complex.argd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.add.f.normal", .namespace = "complex", .invoke = complexBinaryInvoke(Complexf, .normal, complex.addf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.add.f.boundary", .namespace = "complex", .invoke = complexBinaryInvoke(Complexf, .boundary, complex.addf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.add.f.skewed", .namespace = "complex", .invoke = complexBinaryInvoke(Complexf, .skewed, complex.addf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.add.d.normal", .namespace = "complex", .invoke = complexBinaryInvoke(Complexd, .normal, complex.addd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.add.d.boundary", .namespace = "complex", .invoke = complexBinaryInvoke(Complexd, .boundary, complex.addd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.add.d.skewed", .namespace = "complex", .invoke = complexBinaryInvoke(Complexd, .skewed, complex.addd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.sub.f.normal", .namespace = "complex", .invoke = complexBinaryInvoke(Complexf, .normal, complex.subf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.sub.f.boundary", .namespace = "complex", .invoke = complexBinaryInvoke(Complexf, .boundary, complex.subf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.sub.f.skewed", .namespace = "complex", .invoke = complexBinaryInvoke(Complexf, .skewed, complex.subf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.sub.d.normal", .namespace = "complex", .invoke = complexBinaryInvoke(Complexd, .normal, complex.subd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.sub.d.boundary", .namespace = "complex", .invoke = complexBinaryInvoke(Complexd, .boundary, complex.subd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.sub.d.skewed", .namespace = "complex", .invoke = complexBinaryInvoke(Complexd, .skewed, complex.subd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.mul.f.normal", .namespace = "complex", .invoke = complexBinaryInvoke(Complexf, .normal, complex.mulf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.mul.f.boundary", .namespace = "complex", .invoke = complexBinaryInvoke(Complexf, .boundary, complex.mulf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.mul.f.skewed", .namespace = "complex", .invoke = complexBinaryInvoke(Complexf, .skewed, complex.mulf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.mul.d.normal", .namespace = "complex", .invoke = complexBinaryInvoke(Complexd, .normal, complex.muld), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.mul.d.boundary", .namespace = "complex", .invoke = complexBinaryInvoke(Complexd, .boundary, complex.muld), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.mul.d.skewed", .namespace = "complex", .invoke = complexBinaryInvoke(Complexd, .skewed, complex.muld), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.div.f.normal", .namespace = "complex", .invoke = complexBinaryInvoke(Complexf, .normal, complex.divf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.div.f.boundary", .namespace = "complex", .invoke = complexBinaryInvoke(Complexf, .boundary, complex.divf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.div.f.skewed", .namespace = "complex", .invoke = complexBinaryInvoke(Complexf, .skewed, complex.divf), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.div.d.normal", .namespace = "complex", .invoke = complexBinaryInvoke(Complexd, .normal, complex.divd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.div.d.boundary", .namespace = "complex", .invoke = complexBinaryInvoke(Complexd, .boundary, complex.divd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.div.d.skewed", .namespace = "complex", .invoke = complexBinaryInvoke(Complexd, .skewed, complex.divd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.exp.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.expf), .calls = 32, .f32 = charge_expf },
        .{ .name = "complex.exp.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.expf), .calls = 32, .f32 = charge_expf },
        .{ .name = "complex.exp.f.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .skewed, complex.expf), .calls = 32, .f32 = charge_expf },
        .{ .name = "complex.exp.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.expd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.exp.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.expd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.exp.d.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .skewed, complex.expd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.log.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.logf), .calls = 32, .f32 = charge_logf },
        .{ .name = "complex.log.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.logf), .calls = 32, .f32 = charge_logf },
        .{ .name = "complex.log.f.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .skewed, complex.logf), .calls = 32, .f32 = charge_logf },
        .{ .name = "complex.log.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.logd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.log.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.logd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.log.d.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .skewed, complex.logd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.log10.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.log10f), .calls = 32, .f32 = charge_log10f },
        .{ .name = "complex.log10.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.log10f), .calls = 32, .f32 = charge_log10f },
        .{ .name = "complex.log10.f.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .skewed, complex.log10f), .calls = 32, .f32 = charge_log10f },
        .{ .name = "complex.log10.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.log10d), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.log10.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.log10d), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.log10.d.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .skewed, complex.log10d), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.sqrt.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.sqrtf), .calls = 32, .f32 = charge_sqrtf },
        .{ .name = "complex.sqrt.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.sqrtf), .calls = 32, .f32 = charge_sqrtf },
        .{ .name = "complex.sqrt.f.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .skewed, complex.sqrtf), .calls = 32, .f32 = charge_sqrtf },
        .{ .name = "complex.sqrt.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.sqrtd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.sqrt.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.sqrtd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.sqrt.d.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .skewed, complex.sqrtd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.pow.f.normal", .namespace = "complex", .invoke = complexBinaryInvoke(Complexf, .normal, complex.powf), .calls = 32, .f32 = charge_powf },
        .{ .name = "complex.pow.f.boundary", .namespace = "complex", .invoke = complexBinaryInvoke(Complexf, .boundary, complex.powf), .calls = 32, .f32 = charge_powf },
        .{ .name = "complex.pow.f.skewed", .namespace = "complex", .invoke = complexBinaryInvoke(Complexf, .skewed, complex.powf), .calls = 32, .f32 = charge_powf },
        .{ .name = "complex.pow.d.normal", .namespace = "complex", .invoke = complexBinaryInvoke(Complexd, .normal, complex.powd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.pow.d.boundary", .namespace = "complex", .invoke = complexBinaryInvoke(Complexd, .boundary, complex.powd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.pow.d.skewed", .namespace = "complex", .invoke = complexBinaryInvoke(Complexd, .skewed, complex.powd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.sin.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.sinf), .calls = 32, .f32 = charge_sincosf },
        .{ .name = "complex.sin.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.sinf), .calls = 32, .f32 = charge_sincosf },
        .{ .name = "complex.sin.f.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .skewed, complex.sinf), .calls = 32, .f32 = charge_sincosf },
        .{ .name = "complex.sin.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.sind), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.sin.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.sind), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.sin.d.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .skewed, complex.sind), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.cos.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.cosf), .calls = 32, .f32 = charge_sincosf },
        .{ .name = "complex.cos.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.cosf), .calls = 32, .f32 = charge_sincosf },
        .{ .name = "complex.cos.f.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .skewed, complex.cosf), .calls = 32, .f32 = charge_sincosf },
        .{ .name = "complex.cos.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.cosd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.cos.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.cosd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.cos.d.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .skewed, complex.cosd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.tan.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.tanf), .calls = 32, .f32 = charge_tanf },
        .{ .name = "complex.tan.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.tanf), .calls = 32, .f32 = charge_tanf },
        .{ .name = "complex.tan.f.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .skewed, complex.tanf), .calls = 32, .f32 = charge_tanf },
        .{ .name = "complex.tan.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.tand), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.tan.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.tand), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.tan.d.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .skewed, complex.tand), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.sinh.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.sinhf), .calls = 32, .f32 = charge_sincosf },
        .{ .name = "complex.sinh.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.sinhf), .calls = 32, .f32 = charge_sincosf },
        .{ .name = "complex.sinh.f.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .skewed, complex.sinhf), .calls = 32, .f32 = charge_sincosf },
        .{ .name = "complex.sinh.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.sinhd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.sinh.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.sinhd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.sinh.d.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .skewed, complex.sinhd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.cosh.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.coshf), .calls = 32, .f32 = charge_sincosf },
        .{ .name = "complex.cosh.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.coshf), .calls = 32, .f32 = charge_sincosf },
        .{ .name = "complex.cosh.f.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .skewed, complex.coshf), .calls = 32, .f32 = charge_sincosf },
        .{ .name = "complex.cosh.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.coshd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.cosh.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.coshd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.cosh.d.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .skewed, complex.coshd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.tanh.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.tanhf), .calls = 32, .f32 = charge_tanhf },
        .{ .name = "complex.tanh.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.tanhf), .calls = 32, .f32 = charge_tanhf },
        .{ .name = "complex.tanh.f.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .skewed, complex.tanhf), .calls = 32, .f32 = charge_tanhf },
        .{ .name = "complex.tanh.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.tanhd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.tanh.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.tanhd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.tanh.d.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .skewed, complex.tanhd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.asin.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.asinf), .calls = 32, .f32 = charge_asinf },
        .{ .name = "complex.asin.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.asinf), .calls = 32, .f32 = charge_asinf },
        .{ .name = "complex.asin.f.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .skewed, complex.asinf), .calls = 32, .f32 = charge_asinf },
        .{ .name = "complex.asin.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.asind), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.asin.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.asind), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.asin.d.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .skewed, complex.asind), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.acos.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.acosf), .calls = 32, .f32 = charge_asinf },
        .{ .name = "complex.acos.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.acosf), .calls = 32, .f32 = charge_asinf },
        .{ .name = "complex.acos.f.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .skewed, complex.acosf), .calls = 32, .f32 = charge_asinf },
        .{ .name = "complex.acos.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.acosd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.acos.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.acosd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.acos.d.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .skewed, complex.acosd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.atan.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.atanf), .calls = 32, .f32 = charge_atanf },
        .{ .name = "complex.atan.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.atanf), .calls = 32, .f32 = charge_atanf },
        .{ .name = "complex.atan.f.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .skewed, complex.atanf), .calls = 32, .f32 = charge_atanf },
        .{ .name = "complex.atan.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.atand), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.atan.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.atand), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.atan.d.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .skewed, complex.atand), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.asinh.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.asinhf), .calls = 32, .f32 = charge_asinf },
        .{ .name = "complex.asinh.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.asinhf), .calls = 32, .f32 = charge_asinf },
        .{ .name = "complex.asinh.f.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .skewed, complex.asinhf), .calls = 32, .f32 = charge_asinf },
        .{ .name = "complex.asinh.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.asinhd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.asinh.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.asinhd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.asinh.d.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .skewed, complex.asinhd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.acosh.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.acoshf), .calls = 32, .f32 = charge_asinf },
        .{ .name = "complex.acosh.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.acoshf), .calls = 32, .f32 = charge_asinf },
        .{ .name = "complex.acosh.f.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .skewed, complex.acoshf), .calls = 32, .f32 = charge_asinf },
        .{ .name = "complex.acosh.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.acoshd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.acosh.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.acoshd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.acosh.d.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .skewed, complex.acoshd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.atanh.f.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .normal, complex.atanhf), .calls = 32, .f32 = charge_atanf },
        .{ .name = "complex.atanh.f.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .boundary, complex.atanhf), .calls = 32, .f32 = charge_atanf },
        .{ .name = "complex.atanh.f.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexf, .skewed, complex.atanhf), .calls = 32, .f32 = charge_atanf },
        .{ .name = "complex.atanh.d.normal", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .normal, complex.atanhd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.atanh.d.boundary", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .boundary, complex.atanhd), .calls = 32, .f32 = charge_none },
        .{ .name = "complex.atanh.d.skewed", .namespace = "complex", .invoke = complexUnaryComplexInvoke(Complexd, .skewed, complex.atanhd), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.2x2.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 2, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.2x2.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 2, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.3x3.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 3, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.3x3.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 3, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.4x4.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 4, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.4x4.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 4, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.2x3.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 3, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.2x3.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 3, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.3x2.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 2, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.3x2.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 2, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.2x4.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 4, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.2x4.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 4, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.4x2.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 2, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.4x2.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 2, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.3x4.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 4, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.3x4.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 4, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.4x3.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 3, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.4x3.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 3, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.1x3.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(1, 3, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.1x3.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(1, 3, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.3x1.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 1, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.3x1.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 1, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.1x5.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(1, 5, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.1x5.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(1, 5, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.5x1.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(5, 1, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.5x1.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(5, 1, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.5x4.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(5, 4, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.5x4.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(5, 4, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.4x5.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 5, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f32.4x5.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 5, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.2x2.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 2, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.2x2.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 2, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.3x3.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 3, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.3x3.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 3, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.4x4.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 4, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.4x4.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 4, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.2x3.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 3, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.2x3.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 3, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.3x2.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 2, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.3x2.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 2, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.2x4.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 4, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.2x4.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 4, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.4x2.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 2, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.4x2.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 2, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.3x4.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 4, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.3x4.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 4, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.4x3.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 3, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.4x3.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 3, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.1x3.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(1, 3, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.1x3.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(1, 3, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.3x1.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 1, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.3x1.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 1, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.1x5.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(1, 5, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.1x5.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(1, 5, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.5x1.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(5, 1, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.5x1.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(5, 1, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.5x4.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(5, 4, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.5x4.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(5, 4, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.4x5.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 5, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.f64.4x5.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 5, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexf.2x2.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 2, Complexf), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexf.2x2.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 2, Complexf), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexf.3x3.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 3, Complexf), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexf.3x3.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 3, Complexf), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexf.2x3.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 3, Complexf), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexf.2x3.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 3, Complexf), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexf.3x2.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 2, Complexf), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexf.3x2.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 2, Complexf), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexf.2x4.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 4, Complexf), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexf.2x4.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 4, Complexf), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexf.4x2.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 2, Complexf), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexf.4x2.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 2, Complexf), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexd.2x2.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 2, Complexd), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexd.2x2.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 2, Complexd), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexd.3x3.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 3, Complexd), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexd.3x3.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 3, Complexd), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexd.2x3.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 3, Complexd), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexd.2x3.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 3, Complexd), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexd.3x2.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 2, Complexd), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexd.3x2.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(3, 2, Complexd), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexd.2x4.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 4, Complexd), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexd.2x4.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(2, 4, Complexd), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexd.4x2.normal", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 2, Complexd), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.mulVec.Complexd.4x2.boundary", .namespace = "matrix", .invoke = matMulVecInvoke(matrix.Mat(4, 2, Complexd), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f32.2x2.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 2, f32), .normal, matrix.Mat(2, 2, f32).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f32.2x2.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 2, f32), .boundary, matrix.Mat(2, 2, f32).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f32.2x2.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 2, f32), .normal, matrix.Mat(2, 2, f32).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f32.2x2.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 2, f32), .boundary, matrix.Mat(2, 2, f32).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f32.2x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, f32), .normal, matrix.Mat(2, 2, f32).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f32.2x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, f32), .boundary, matrix.Mat(2, 2, f32).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f32.2x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, f32), .normal, matrix.Mat(2, 2, f32).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f32.2x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, f32), .boundary, matrix.Mat(2, 2, f32).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f32.2x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, f32), .normal, matrix.Mat(2, 2, f32).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f32.2x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, f32), .boundary, matrix.Mat(2, 2, f32).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f32.3x3.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(3, 3, f32), .normal, matrix.Mat(3, 3, f32).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f32.3x3.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(3, 3, f32), .boundary, matrix.Mat(3, 3, f32).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f32.3x3.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(3, 3, f32), .normal, matrix.Mat(3, 3, f32).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f32.3x3.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(3, 3, f32), .boundary, matrix.Mat(3, 3, f32).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f32.3x3.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, f32), .normal, matrix.Mat(3, 3, f32).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f32.3x3.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, f32), .boundary, matrix.Mat(3, 3, f32).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f32.3x3.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, f32), .normal, matrix.Mat(3, 3, f32).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f32.3x3.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, f32), .boundary, matrix.Mat(3, 3, f32).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f32.3x3.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, f32), .normal, matrix.Mat(3, 3, f32).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f32.3x3.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, f32), .boundary, matrix.Mat(3, 3, f32).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f32.4x4.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(4, 4, f32), .normal, matrix.Mat(4, 4, f32).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f32.4x4.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(4, 4, f32), .boundary, matrix.Mat(4, 4, f32).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f32.4x4.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(4, 4, f32), .normal, matrix.Mat(4, 4, f32).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f32.4x4.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(4, 4, f32), .boundary, matrix.Mat(4, 4, f32).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f32.4x4.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 4, f32), .normal, matrix.Mat(4, 4, f32).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f32.4x4.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 4, f32), .boundary, matrix.Mat(4, 4, f32).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f32.4x4.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 4, f32), .normal, matrix.Mat(4, 4, f32).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f32.4x4.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 4, f32), .boundary, matrix.Mat(4, 4, f32).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f32.4x4.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 4, f32), .normal, matrix.Mat(4, 4, f32).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f32.4x4.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 4, f32), .boundary, matrix.Mat(4, 4, f32).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f32.2x4.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 4, f32), .normal, matrix.Mat(2, 4, f32).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f32.2x4.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 4, f32), .boundary, matrix.Mat(2, 4, f32).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f32.2x4.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 4, f32), .normal, matrix.Mat(2, 4, f32).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f32.2x4.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 4, f32), .boundary, matrix.Mat(2, 4, f32).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f32.2x4.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 4, f32), .normal, matrix.Mat(2, 4, f32).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f32.2x4.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 4, f32), .boundary, matrix.Mat(2, 4, f32).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f32.2x4.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 4, f32), .normal, matrix.Mat(2, 4, f32).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f32.2x4.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 4, f32), .boundary, matrix.Mat(2, 4, f32).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f32.2x4.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 4, f32), .normal, matrix.Mat(2, 4, f32).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f32.2x4.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 4, f32), .boundary, matrix.Mat(2, 4, f32).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f32.4x2.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(4, 2, f32), .normal, matrix.Mat(4, 2, f32).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f32.4x2.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(4, 2, f32), .boundary, matrix.Mat(4, 2, f32).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f32.4x2.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(4, 2, f32), .normal, matrix.Mat(4, 2, f32).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f32.4x2.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(4, 2, f32), .boundary, matrix.Mat(4, 2, f32).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f32.4x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 2, f32), .normal, matrix.Mat(4, 2, f32).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f32.4x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 2, f32), .boundary, matrix.Mat(4, 2, f32).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f32.4x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 2, f32), .normal, matrix.Mat(4, 2, f32).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f32.4x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 2, f32), .boundary, matrix.Mat(4, 2, f32).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f32.4x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 2, f32), .normal, matrix.Mat(4, 2, f32).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f32.4x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 2, f32), .boundary, matrix.Mat(4, 2, f32).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f64.2x2.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 2, f64), .normal, matrix.Mat(2, 2, f64).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f64.2x2.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 2, f64), .boundary, matrix.Mat(2, 2, f64).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f64.2x2.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 2, f64), .normal, matrix.Mat(2, 2, f64).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f64.2x2.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 2, f64), .boundary, matrix.Mat(2, 2, f64).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f64.2x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, f64), .normal, matrix.Mat(2, 2, f64).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f64.2x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, f64), .boundary, matrix.Mat(2, 2, f64).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f64.2x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, f64), .normal, matrix.Mat(2, 2, f64).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f64.2x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, f64), .boundary, matrix.Mat(2, 2, f64).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f64.2x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, f64), .normal, matrix.Mat(2, 2, f64).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f64.2x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, f64), .boundary, matrix.Mat(2, 2, f64).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f64.3x3.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(3, 3, f64), .normal, matrix.Mat(3, 3, f64).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f64.3x3.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(3, 3, f64), .boundary, matrix.Mat(3, 3, f64).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f64.3x3.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(3, 3, f64), .normal, matrix.Mat(3, 3, f64).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f64.3x3.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(3, 3, f64), .boundary, matrix.Mat(3, 3, f64).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f64.3x3.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, f64), .normal, matrix.Mat(3, 3, f64).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f64.3x3.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, f64), .boundary, matrix.Mat(3, 3, f64).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f64.3x3.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, f64), .normal, matrix.Mat(3, 3, f64).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f64.3x3.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, f64), .boundary, matrix.Mat(3, 3, f64).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f64.3x3.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, f64), .normal, matrix.Mat(3, 3, f64).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f64.3x3.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, f64), .boundary, matrix.Mat(3, 3, f64).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f64.4x4.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(4, 4, f64), .normal, matrix.Mat(4, 4, f64).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f64.4x4.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(4, 4, f64), .boundary, matrix.Mat(4, 4, f64).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f64.4x4.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(4, 4, f64), .normal, matrix.Mat(4, 4, f64).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f64.4x4.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(4, 4, f64), .boundary, matrix.Mat(4, 4, f64).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f64.4x4.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 4, f64), .normal, matrix.Mat(4, 4, f64).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f64.4x4.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 4, f64), .boundary, matrix.Mat(4, 4, f64).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f64.4x4.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 4, f64), .normal, matrix.Mat(4, 4, f64).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f64.4x4.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 4, f64), .boundary, matrix.Mat(4, 4, f64).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f64.4x4.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 4, f64), .normal, matrix.Mat(4, 4, f64).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f64.4x4.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 4, f64), .boundary, matrix.Mat(4, 4, f64).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f64.2x4.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 4, f64), .normal, matrix.Mat(2, 4, f64).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f64.2x4.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 4, f64), .boundary, matrix.Mat(2, 4, f64).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f64.2x4.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 4, f64), .normal, matrix.Mat(2, 4, f64).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f64.2x4.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 4, f64), .boundary, matrix.Mat(2, 4, f64).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f64.2x4.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 4, f64), .normal, matrix.Mat(2, 4, f64).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f64.2x4.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 4, f64), .boundary, matrix.Mat(2, 4, f64).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f64.2x4.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 4, f64), .normal, matrix.Mat(2, 4, f64).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f64.2x4.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 4, f64), .boundary, matrix.Mat(2, 4, f64).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f64.2x4.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 4, f64), .normal, matrix.Mat(2, 4, f64).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f64.2x4.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 4, f64), .boundary, matrix.Mat(2, 4, f64).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f64.4x2.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(4, 2, f64), .normal, matrix.Mat(4, 2, f64).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.f64.4x2.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(4, 2, f64), .boundary, matrix.Mat(4, 2, f64).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f64.4x2.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(4, 2, f64), .normal, matrix.Mat(4, 2, f64).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.f64.4x2.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(4, 2, f64), .boundary, matrix.Mat(4, 2, f64).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f64.4x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 2, f64), .normal, matrix.Mat(4, 2, f64).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.f64.4x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 2, f64), .boundary, matrix.Mat(4, 2, f64).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f64.4x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 2, f64), .normal, matrix.Mat(4, 2, f64).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.f64.4x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 2, f64), .boundary, matrix.Mat(4, 2, f64).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f64.4x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 2, f64), .normal, matrix.Mat(4, 2, f64).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.f64.4x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(4, 2, f64), .boundary, matrix.Mat(4, 2, f64).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.Complexf.2x2.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 2, Complexf), .normal, matrix.Mat(2, 2, Complexf).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.Complexf.2x2.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 2, Complexf), .boundary, matrix.Mat(2, 2, Complexf).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.Complexf.2x2.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 2, Complexf), .normal, matrix.Mat(2, 2, Complexf).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.Complexf.2x2.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 2, Complexf), .boundary, matrix.Mat(2, 2, Complexf).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.Complexf.2x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, Complexf), .normal, matrix.Mat(2, 2, Complexf).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.Complexf.2x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, Complexf), .boundary, matrix.Mat(2, 2, Complexf).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.Complexf.2x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, Complexf), .normal, matrix.Mat(2, 2, Complexf).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.Complexf.2x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, Complexf), .boundary, matrix.Mat(2, 2, Complexf).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.Complexf.2x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, Complexf), .normal, matrix.Mat(2, 2, Complexf).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.Complexf.2x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, Complexf), .boundary, matrix.Mat(2, 2, Complexf).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.Complexf.3x3.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(3, 3, Complexf), .normal, matrix.Mat(3, 3, Complexf).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.Complexf.3x3.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(3, 3, Complexf), .boundary, matrix.Mat(3, 3, Complexf).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.Complexf.3x3.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(3, 3, Complexf), .normal, matrix.Mat(3, 3, Complexf).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.Complexf.3x3.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(3, 3, Complexf), .boundary, matrix.Mat(3, 3, Complexf).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.Complexf.3x3.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, Complexf), .normal, matrix.Mat(3, 3, Complexf).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.Complexf.3x3.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, Complexf), .boundary, matrix.Mat(3, 3, Complexf).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.Complexf.3x3.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, Complexf), .normal, matrix.Mat(3, 3, Complexf).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.Complexf.3x3.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, Complexf), .boundary, matrix.Mat(3, 3, Complexf).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.Complexf.3x3.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, Complexf), .normal, matrix.Mat(3, 3, Complexf).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.Complexf.3x3.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, Complexf), .boundary, matrix.Mat(3, 3, Complexf).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.Complexd.2x2.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 2, Complexd), .normal, matrix.Mat(2, 2, Complexd).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.Complexd.2x2.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 2, Complexd), .boundary, matrix.Mat(2, 2, Complexd).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.Complexd.2x2.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 2, Complexd), .normal, matrix.Mat(2, 2, Complexd).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.Complexd.2x2.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(2, 2, Complexd), .boundary, matrix.Mat(2, 2, Complexd).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.Complexd.2x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, Complexd), .normal, matrix.Mat(2, 2, Complexd).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.Complexd.2x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, Complexd), .boundary, matrix.Mat(2, 2, Complexd).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.Complexd.2x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, Complexd), .normal, matrix.Mat(2, 2, Complexd).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.Complexd.2x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, Complexd), .boundary, matrix.Mat(2, 2, Complexd).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.Complexd.2x2.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, Complexd), .normal, matrix.Mat(2, 2, Complexd).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.Complexd.2x2.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(2, 2, Complexd), .boundary, matrix.Mat(2, 2, Complexd).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.Complexd.3x3.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(3, 3, Complexd), .normal, matrix.Mat(3, 3, Complexd).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.neg.Complexd.3x3.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(3, 3, Complexd), .boundary, matrix.Mat(3, 3, Complexd).neg), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.Complexd.3x3.normal", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(3, 3, Complexd), .normal, matrix.Mat(3, 3, Complexd).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.transpose.Complexd.3x3.boundary", .namespace = "matrix", .invoke = matUnaryInvoke(matrix.Mat(3, 3, Complexd), .boundary, matrix.Mat(3, 3, Complexd).transpose), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.Complexd.3x3.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, Complexd), .normal, matrix.Mat(3, 3, Complexd).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.add.Complexd.3x3.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, Complexd), .boundary, matrix.Mat(3, 3, Complexd).add), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.Complexd.3x3.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, Complexd), .normal, matrix.Mat(3, 3, Complexd).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.sub.Complexd.3x3.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, Complexd), .boundary, matrix.Mat(3, 3, Complexd).sub), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.Complexd.3x3.normal", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, Complexd), .normal, matrix.Mat(3, 3, Complexd).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.scale.Complexd.3x3.boundary", .namespace = "matrix", .invoke = matBinaryInvoke(matrix.Mat(3, 3, Complexd), .boundary, matrix.Mat(3, 3, Complexd).scale), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.init.f32.2x4.normal", .namespace = "matrix", .invoke = matInitInvoke(matrix.Mat(2, 4, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.init.f32.2x4.boundary", .namespace = "matrix", .invoke = matInitInvoke(matrix.Mat(2, 4, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.fill.f32.2x4.normal", .namespace = "matrix", .invoke = matFillInvoke(matrix.Mat(2, 4, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.fill.f32.2x4.boundary", .namespace = "matrix", .invoke = matFillInvoke(matrix.Mat(2, 4, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.at.f32.2x4.normal", .namespace = "matrix", .invoke = matAtInvoke(matrix.Mat(2, 4, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.at.f32.2x4.boundary", .namespace = "matrix", .invoke = matAtInvoke(matrix.Mat(2, 4, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.set.f32.2x4.normal", .namespace = "matrix", .invoke = matSetInvoke(matrix.Mat(2, 4, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.set.f32.2x4.boundary", .namespace = "matrix", .invoke = matSetInvoke(matrix.Mat(2, 4, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.init.f32.4x2.normal", .namespace = "matrix", .invoke = matInitInvoke(matrix.Mat(4, 2, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.init.f32.4x2.boundary", .namespace = "matrix", .invoke = matInitInvoke(matrix.Mat(4, 2, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.fill.f32.4x2.normal", .namespace = "matrix", .invoke = matFillInvoke(matrix.Mat(4, 2, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.fill.f32.4x2.boundary", .namespace = "matrix", .invoke = matFillInvoke(matrix.Mat(4, 2, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.at.f32.4x2.normal", .namespace = "matrix", .invoke = matAtInvoke(matrix.Mat(4, 2, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.at.f32.4x2.boundary", .namespace = "matrix", .invoke = matAtInvoke(matrix.Mat(4, 2, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.set.f32.4x2.normal", .namespace = "matrix", .invoke = matSetInvoke(matrix.Mat(4, 2, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.set.f32.4x2.boundary", .namespace = "matrix", .invoke = matSetInvoke(matrix.Mat(4, 2, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.init.f64.3x4.normal", .namespace = "matrix", .invoke = matInitInvoke(matrix.Mat(3, 4, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.init.f64.3x4.boundary", .namespace = "matrix", .invoke = matInitInvoke(matrix.Mat(3, 4, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.fill.f64.3x4.normal", .namespace = "matrix", .invoke = matFillInvoke(matrix.Mat(3, 4, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.fill.f64.3x4.boundary", .namespace = "matrix", .invoke = matFillInvoke(matrix.Mat(3, 4, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.at.f64.3x4.normal", .namespace = "matrix", .invoke = matAtInvoke(matrix.Mat(3, 4, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.at.f64.3x4.boundary", .namespace = "matrix", .invoke = matAtInvoke(matrix.Mat(3, 4, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.set.f64.3x4.normal", .namespace = "matrix", .invoke = matSetInvoke(matrix.Mat(3, 4, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.set.f64.3x4.boundary", .namespace = "matrix", .invoke = matSetInvoke(matrix.Mat(3, 4, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.init.f64.4x3.normal", .namespace = "matrix", .invoke = matInitInvoke(matrix.Mat(4, 3, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.init.f64.4x3.boundary", .namespace = "matrix", .invoke = matInitInvoke(matrix.Mat(4, 3, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.fill.f64.4x3.normal", .namespace = "matrix", .invoke = matFillInvoke(matrix.Mat(4, 3, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.fill.f64.4x3.boundary", .namespace = "matrix", .invoke = matFillInvoke(matrix.Mat(4, 3, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.at.f64.4x3.normal", .namespace = "matrix", .invoke = matAtInvoke(matrix.Mat(4, 3, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.at.f64.4x3.boundary", .namespace = "matrix", .invoke = matAtInvoke(matrix.Mat(4, 3, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.set.f64.4x3.normal", .namespace = "matrix", .invoke = matSetInvoke(matrix.Mat(4, 3, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.set.f64.4x3.boundary", .namespace = "matrix", .invoke = matSetInvoke(matrix.Mat(4, 3, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.init.Complexf.2x2.normal", .namespace = "matrix", .invoke = matInitInvoke(matrix.Mat(2, 2, Complexf), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.init.Complexf.2x2.boundary", .namespace = "matrix", .invoke = matInitInvoke(matrix.Mat(2, 2, Complexf), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.fill.Complexf.2x2.normal", .namespace = "matrix", .invoke = matFillInvoke(matrix.Mat(2, 2, Complexf), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.fill.Complexf.2x2.boundary", .namespace = "matrix", .invoke = matFillInvoke(matrix.Mat(2, 2, Complexf), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.at.Complexf.2x2.normal", .namespace = "matrix", .invoke = matAtInvoke(matrix.Mat(2, 2, Complexf), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.at.Complexf.2x2.boundary", .namespace = "matrix", .invoke = matAtInvoke(matrix.Mat(2, 2, Complexf), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.set.Complexf.2x2.normal", .namespace = "matrix", .invoke = matSetInvoke(matrix.Mat(2, 2, Complexf), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.set.Complexf.2x2.boundary", .namespace = "matrix", .invoke = matSetInvoke(matrix.Mat(2, 2, Complexf), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.init.Complexd.2x2.normal", .namespace = "matrix", .invoke = matInitInvoke(matrix.Mat(2, 2, Complexd), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.init.Complexd.2x2.boundary", .namespace = "matrix", .invoke = matInitInvoke(matrix.Mat(2, 2, Complexd), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.fill.Complexd.2x2.normal", .namespace = "matrix", .invoke = matFillInvoke(matrix.Mat(2, 2, Complexd), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.fill.Complexd.2x2.boundary", .namespace = "matrix", .invoke = matFillInvoke(matrix.Mat(2, 2, Complexd), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.at.Complexd.2x2.normal", .namespace = "matrix", .invoke = matAtInvoke(matrix.Mat(2, 2, Complexd), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.at.Complexd.2x2.boundary", .namespace = "matrix", .invoke = matAtInvoke(matrix.Mat(2, 2, Complexd), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.set.Complexd.2x2.normal", .namespace = "matrix", .invoke = matSetInvoke(matrix.Mat(2, 2, Complexd), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.set.Complexd.2x2.boundary", .namespace = "matrix", .invoke = matSetInvoke(matrix.Mat(2, 2, Complexd), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.isFinite.f32.2x3.normal", .namespace = "matrix", .invoke = matIsFiniteInvoke(matrix.Mat(2, 3, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.isFinite.f32.2x3.boundary", .namespace = "matrix", .invoke = matIsFiniteInvoke(matrix.Mat(2, 3, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.isFinite.f64.3x4.normal", .namespace = "matrix", .invoke = matIsFiniteInvoke(matrix.Mat(3, 4, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.isFinite.f64.3x4.boundary", .namespace = "matrix", .invoke = matIsFiniteInvoke(matrix.Mat(3, 4, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.isFinite.Complexf.2x3.normal", .namespace = "matrix", .invoke = matIsFiniteInvoke(matrix.Mat(2, 3, Complexf), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.isFinite.Complexf.2x3.boundary", .namespace = "matrix", .invoke = matIsFiniteInvoke(matrix.Mat(2, 3, Complexf), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.isFinite.Complexd.2x3.normal", .namespace = "matrix", .invoke = matIsFiniteInvoke(matrix.Mat(2, 3, Complexd), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.isFinite.Complexd.2x3.boundary", .namespace = "matrix", .invoke = matIsFiniteInvoke(matrix.Mat(2, 3, Complexd), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.Mat.determinant.Complexf.2x2.normal", .namespace = "matrix", .invoke = matDeterminantInvoke(matrix.Mat(2, 2, Complexf), .normal), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.Mat.determinant.Complexf.2x2.boundary", .namespace = "matrix", .invoke = matDeterminantInvoke(matrix.Mat(2, 2, Complexf), .boundary), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.Mat.determinant.Complexf.3x3.normal", .namespace = "matrix", .invoke = matDeterminantInvoke(matrix.Mat(3, 3, Complexf), .normal), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.Mat.determinant.Complexf.3x3.boundary", .namespace = "matrix", .invoke = matDeterminantInvoke(matrix.Mat(3, 3, Complexf), .boundary), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.Mat.determinant.Complexd.2x2.normal", .namespace = "matrix", .invoke = matDeterminantInvoke(matrix.Mat(2, 2, Complexd), .normal), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.Mat.determinant.Complexd.2x2.boundary", .namespace = "matrix", .invoke = matDeterminantInvoke(matrix.Mat(2, 2, Complexd), .boundary), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.Mat.determinant.Complexd.3x3.normal", .namespace = "matrix", .invoke = matDeterminantInvoke(matrix.Mat(3, 3, Complexd), .normal), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.Mat.determinant.Complexd.3x3.boundary", .namespace = "matrix", .invoke = matDeterminantInvoke(matrix.Mat(3, 3, Complexd), .boundary), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.determinantMat2f.normal", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat2f, .normal, matrix.determinantMat2f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.determinantMat2f.boundary", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat2f, .boundary, matrix.determinantMat2f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.determinantMat2f.skewed", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat2f, .skewed, matrix.determinantMat2f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.determinantMat2f.singular", .namespace = "matrix", .invoke = singularDeterminantInvoke(matrix.Mat2f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.determinantMat3f.normal", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat3f, .normal, matrix.determinantMat3f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.determinantMat3f.boundary", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat3f, .boundary, matrix.determinantMat3f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.determinantMat3f.skewed", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat3f, .skewed, matrix.determinantMat3f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.determinantMat3f.singular", .namespace = "matrix", .invoke = singularDeterminantInvoke(matrix.Mat3f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.determinantMat4f.normal", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat4f, .normal, matrix.determinantMat4f), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.determinantMat4f.boundary", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat4f, .boundary, matrix.determinantMat4f), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.determinantMat4f.skewed", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat4f, .skewed, matrix.determinantMat4f), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.determinantMat4f.singular", .namespace = "matrix", .invoke = singularDeterminantInvoke(matrix.Mat4f), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.determinantMat5f.normal", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat5f, .normal, matrix.determinantMat5f), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.determinantMat5f.boundary", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat5f, .boundary, matrix.determinantMat5f), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.determinantMat5f.skewed", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat5f, .skewed, matrix.determinantMat5f), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.determinantMat5f.singular", .namespace = "matrix", .invoke = singularDeterminantInvoke(matrix.Mat5f), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.determinantMat2d.normal", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat2d, .normal, matrix.determinantMat2d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.determinantMat2d.boundary", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat2d, .boundary, matrix.determinantMat2d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.determinantMat2d.skewed", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat2d, .skewed, matrix.determinantMat2d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.determinantMat2d.singular", .namespace = "matrix", .invoke = singularDeterminantInvoke(matrix.Mat2d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.determinantMat3d.normal", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat3d, .normal, matrix.determinantMat3d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.determinantMat3d.boundary", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat3d, .boundary, matrix.determinantMat3d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.determinantMat3d.skewed", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat3d, .skewed, matrix.determinantMat3d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.determinantMat3d.singular", .namespace = "matrix", .invoke = singularDeterminantInvoke(matrix.Mat3d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.determinantMat4d.normal", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat4d, .normal, matrix.determinantMat4d), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.determinantMat4d.boundary", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat4d, .boundary, matrix.determinantMat4d), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.determinantMat4d.skewed", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat4d, .skewed, matrix.determinantMat4d), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.determinantMat4d.singular", .namespace = "matrix", .invoke = singularDeterminantInvoke(matrix.Mat4d), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.determinantMat5d.normal", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat5d, .normal, matrix.determinantMat5d), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.determinantMat5d.boundary", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat5d, .boundary, matrix.determinantMat5d), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.determinantMat5d.skewed", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat5d, .skewed, matrix.determinantMat5d), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.determinantMat5d.singular", .namespace = "matrix", .invoke = singularDeterminantInvoke(matrix.Mat5d), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.inverseMat2f.normal", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat2f, .normal, matrix.inverseMat2f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat2f.boundary", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat2f, .boundary, matrix.inverseMat2f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat2f.skewed", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat2f, .skewed, matrix.inverseMat2f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat2f.refused_singular", .namespace = "matrix", .invoke = singularInverseInvoke(matrix.Mat2f, matrix.inverseMat2f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat2f.refused_nonfinite", .namespace = "matrix", .invoke = nonfiniteInverseInvoke(matrix.Mat2f, matrix.inverseMat2f, 4), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat2f.refused_nan_input", .namespace = "matrix", .invoke = nonfiniteInverseInvoke(matrix.Mat2f, matrix.inverseMat2f, 6), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat2f.refused_small_pivot", .namespace = "matrix", .invoke = smallPivotInverseInvoke(matrix.Mat2f, matrix.inverseMat2f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat2f.refused_overflow", .namespace = "matrix", .invoke = overflowInverseInvoke(matrix.Mat2f, matrix.inverseMat2f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat3f.normal", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat3f, .normal, matrix.inverseMat3f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat3f.boundary", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat3f, .boundary, matrix.inverseMat3f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat3f.skewed", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat3f, .skewed, matrix.inverseMat3f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat3f.refused_singular", .namespace = "matrix", .invoke = singularInverseInvoke(matrix.Mat3f, matrix.inverseMat3f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat3f.refused_nonfinite", .namespace = "matrix", .invoke = nonfiniteInverseInvoke(matrix.Mat3f, matrix.inverseMat3f, 4), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat3f.refused_nan_input", .namespace = "matrix", .invoke = nonfiniteInverseInvoke(matrix.Mat3f, matrix.inverseMat3f, 6), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat3f.refused_small_pivot", .namespace = "matrix", .invoke = smallPivotInverseInvoke(matrix.Mat3f, matrix.inverseMat3f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat3f.refused_overflow", .namespace = "matrix", .invoke = overflowInverseInvoke(matrix.Mat3f, matrix.inverseMat3f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat4f.normal", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat4f, .normal, matrix.inverseMat4f), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.inverseMat4f.boundary", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat4f, .boundary, matrix.inverseMat4f), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.inverseMat4f.skewed", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat4f, .skewed, matrix.inverseMat4f), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.inverseMat4f.refused_singular", .namespace = "matrix", .invoke = singularInverseInvoke(matrix.Mat4f, matrix.inverseMat4f), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.inverseMat4f.refused_nonfinite", .namespace = "matrix", .invoke = nonfiniteInverseInvoke(matrix.Mat4f, matrix.inverseMat4f, 4), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.inverseMat4f.refused_nan_input", .namespace = "matrix", .invoke = nonfiniteInverseInvoke(matrix.Mat4f, matrix.inverseMat4f, 6), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.inverseMat4f.refused_small_pivot", .namespace = "matrix", .invoke = smallPivotInverseInvoke(matrix.Mat4f, matrix.inverseMat4f), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.inverseMat4f.refused_overflow", .namespace = "matrix", .invoke = overflowInverseInvoke(matrix.Mat4f, matrix.inverseMat4f), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.inverseMat2d.normal", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat2d, .normal, matrix.inverseMat2d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat2d.boundary", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat2d, .boundary, matrix.inverseMat2d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat2d.skewed", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat2d, .skewed, matrix.inverseMat2d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat2d.refused_singular", .namespace = "matrix", .invoke = singularInverseInvoke(matrix.Mat2d, matrix.inverseMat2d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat2d.refused_nonfinite", .namespace = "matrix", .invoke = nonfiniteInverseInvoke(matrix.Mat2d, matrix.inverseMat2d, 4), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat2d.refused_nan_input", .namespace = "matrix", .invoke = nonfiniteInverseInvoke(matrix.Mat2d, matrix.inverseMat2d, 6), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat2d.refused_small_pivot", .namespace = "matrix", .invoke = smallPivotInverseInvoke(matrix.Mat2d, matrix.inverseMat2d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat2d.refused_overflow", .namespace = "matrix", .invoke = overflowInverseInvoke(matrix.Mat2d, matrix.inverseMat2d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat3d.normal", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat3d, .normal, matrix.inverseMat3d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat3d.boundary", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat3d, .boundary, matrix.inverseMat3d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat3d.skewed", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat3d, .skewed, matrix.inverseMat3d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat3d.refused_singular", .namespace = "matrix", .invoke = singularInverseInvoke(matrix.Mat3d, matrix.inverseMat3d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat3d.refused_nonfinite", .namespace = "matrix", .invoke = nonfiniteInverseInvoke(matrix.Mat3d, matrix.inverseMat3d, 4), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat3d.refused_nan_input", .namespace = "matrix", .invoke = nonfiniteInverseInvoke(matrix.Mat3d, matrix.inverseMat3d, 6), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat3d.refused_small_pivot", .namespace = "matrix", .invoke = smallPivotInverseInvoke(matrix.Mat3d, matrix.inverseMat3d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat3d.refused_overflow", .namespace = "matrix", .invoke = overflowInverseInvoke(matrix.Mat3d, matrix.inverseMat3d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.inverseMat4d.normal", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat4d, .normal, matrix.inverseMat4d), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.inverseMat4d.boundary", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat4d, .boundary, matrix.inverseMat4d), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.inverseMat4d.skewed", .namespace = "matrix", .invoke = matFreeOpInvoke(matrix.Mat4d, .skewed, matrix.inverseMat4d), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.inverseMat4d.refused_singular", .namespace = "matrix", .invoke = singularInverseInvoke(matrix.Mat4d, matrix.inverseMat4d), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.inverseMat4d.refused_nonfinite", .namespace = "matrix", .invoke = nonfiniteInverseInvoke(matrix.Mat4d, matrix.inverseMat4d, 4), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.inverseMat4d.refused_nan_input", .namespace = "matrix", .invoke = nonfiniteInverseInvoke(matrix.Mat4d, matrix.inverseMat4d, 6), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.inverseMat4d.refused_small_pivot", .namespace = "matrix", .invoke = smallPivotInverseInvoke(matrix.Mat4d, matrix.inverseMat4d), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.inverseMat4d.refused_overflow", .namespace = "matrix", .invoke = overflowInverseInvoke(matrix.Mat4d, matrix.inverseMat4d), .calls = 16, .f32 = charge_none },
        .{ .name = "matrix.mulMat4fVec4f.normal", .namespace = "matrix", .invoke = matVecFreeInvoke(matrix.Mat4f, .normal, matrix.mulMat4fVec4f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mulMat4fVec4f.boundary", .namespace = "matrix", .invoke = matVecFreeInvoke(matrix.Mat4f, .boundary, matrix.mulMat4fVec4f), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mulMat4dVec4d.normal", .namespace = "matrix", .invoke = matVecFreeInvoke(matrix.Mat4d, .normal, matrix.mulMat4dVec4d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mulMat4dVec4d.boundary", .namespace = "matrix", .invoke = matVecFreeInvoke(matrix.Mat4d, .boundary, matrix.mulMat4dVec4d), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f32.2x2_x_2x2.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 2, f32), matrix.Mat(2, 2, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f32.2x2_x_2x2.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 2, f32), matrix.Mat(2, 2, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f32.3x3_x_3x3.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(3, 3, f32), matrix.Mat(3, 3, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f32.3x3_x_3x3.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(3, 3, f32), matrix.Mat(3, 3, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f32.4x4_x_4x4.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(4, 4, f32), matrix.Mat(4, 4, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f32.4x4_x_4x4.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(4, 4, f32), matrix.Mat(4, 4, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f32.2x3_x_3x2.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 3, f32), matrix.Mat(3, 2, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f32.2x3_x_3x2.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 3, f32), matrix.Mat(3, 2, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f32.3x4_x_4x3.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(3, 4, f32), matrix.Mat(4, 3, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f32.3x4_x_4x3.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(3, 4, f32), matrix.Mat(4, 3, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f32.2x4_x_4x2.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 4, f32), matrix.Mat(4, 2, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f32.2x4_x_4x2.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 4, f32), matrix.Mat(4, 2, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f32.5x4_x_4x3.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(5, 4, f32), matrix.Mat(4, 3, f32), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f32.5x4_x_4x3.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(5, 4, f32), matrix.Mat(4, 3, f32), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f64.2x2_x_2x2.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 2, f64), matrix.Mat(2, 2, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f64.2x2_x_2x2.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 2, f64), matrix.Mat(2, 2, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f64.3x3_x_3x3.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(3, 3, f64), matrix.Mat(3, 3, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f64.3x3_x_3x3.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(3, 3, f64), matrix.Mat(3, 3, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f64.4x4_x_4x4.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(4, 4, f64), matrix.Mat(4, 4, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f64.4x4_x_4x4.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(4, 4, f64), matrix.Mat(4, 4, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f64.2x3_x_3x2.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 3, f64), matrix.Mat(3, 2, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f64.2x3_x_3x2.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 3, f64), matrix.Mat(3, 2, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f64.3x4_x_4x3.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(3, 4, f64), matrix.Mat(4, 3, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f64.3x4_x_4x3.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(3, 4, f64), matrix.Mat(4, 3, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f64.2x4_x_4x2.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 4, f64), matrix.Mat(4, 2, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f64.2x4_x_4x2.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 4, f64), matrix.Mat(4, 2, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f64.5x4_x_4x3.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(5, 4, f64), matrix.Mat(4, 3, f64), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.f64.5x4_x_4x3.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(5, 4, f64), matrix.Mat(4, 3, f64), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.Complexf.2x2_x_2x2.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 2, Complexf), matrix.Mat(2, 2, Complexf), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.Complexf.2x2_x_2x2.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 2, Complexf), matrix.Mat(2, 2, Complexf), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.Complexf.3x3_x_3x3.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(3, 3, Complexf), matrix.Mat(3, 3, Complexf), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.Complexf.3x3_x_3x3.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(3, 3, Complexf), matrix.Mat(3, 3, Complexf), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.Complexf.2x3_x_3x2.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 3, Complexf), matrix.Mat(3, 2, Complexf), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.Complexf.2x3_x_3x2.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 3, Complexf), matrix.Mat(3, 2, Complexf), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.Complexd.2x2_x_2x2.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 2, Complexd), matrix.Mat(2, 2, Complexd), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.Complexd.2x2_x_2x2.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 2, Complexd), matrix.Mat(2, 2, Complexd), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.Complexd.3x3_x_3x3.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(3, 3, Complexd), matrix.Mat(3, 3, Complexd), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.Complexd.3x3_x_3x3.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(3, 3, Complexd), matrix.Mat(3, 3, Complexd), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.Complexd.2x3_x_3x2.normal", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 3, Complexd), matrix.Mat(3, 2, Complexd), .normal), .calls = 32, .f32 = charge_none },
        .{ .name = "matrix.mul.Complexd.2x3_x_3x2.boundary", .namespace = "matrix", .invoke = matMulInvoke(matrix.Mat(2, 3, Complexd), matrix.Mat(3, 2, Complexd), .boundary), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat2f.normal", .namespace = "linalg", .invoke = luFactorInvoke(matrix.Mat2f, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat2f.skewed", .namespace = "linalg", .invoke = luFactorInvoke(matrix.Mat2f, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat2f.refused_singular", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat2f, .singular), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat2f.refused_nonfinite", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat2f, .nonfinite), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat2f.refused_nan_input", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat2f, .nan_input), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat2f.refused_small_pivot", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat2f, .small_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat2f.pipeline_normal", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat2f, linalg.reconstructLu, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat2f.pipeline_skewed", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat2f, linalg.reconstructLu, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat2f.pipeline_normal", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat2f, linalg.determinantLu, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat2f.pipeline_skewed", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat2f, linalg.determinantLu, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat2f.stored", .namespace = "linalg", .invoke = luStoredReadbackInvoke(matrix.Mat2f, linalg.reconstructLu), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat2f.stored", .namespace = "linalg", .invoke = luStoredReadbackInvoke(matrix.Mat2f, linalg.determinantLu), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat2f.pipeline_normal", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat2f, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat2f.stored", .namespace = "linalg", .invoke = solveLuStoredInvoke(matrix.Mat2f), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat2f.refused_zero_pivot", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat2f, .zero_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat2f.refused_nonfinite_pivot", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat2f, .nonfinite_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat2f.nonfinite_result", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat2f, .overflow), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat2f.pipeline_one_column", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat2f, 1, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat2f.pipeline_two_columns", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat2f, 2, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat2f.stored_one_column", .namespace = "linalg", .invoke = solveLuMultipleStoredInvoke(matrix.Mat2f, 1), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat2f.stored_two_columns", .namespace = "linalg", .invoke = solveLuMultipleStoredInvoke(matrix.Mat2f, 2), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat2f.refused_zero_pivot", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat2f, 2, .zero_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat2f.nonfinite_result", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat2f, 2, .overflow), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat2f.normal", .namespace = "linalg", .invoke = cholFactorInvoke(matrix.Mat2f, false), .calls = 32, .f32 = charge_chol2f },
        .{ .name = "linalg.cholesky.Mat2f.skewed", .namespace = "linalg", .invoke = cholFactorInvoke(matrix.Mat2f, true), .calls = 32, .f32 = charge_chol2f },
        .{ .name = "linalg.cholesky.Mat2f.refused_asymmetric", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat2f, .asymmetric), .calls = 32, .f32 = charge_chol2f },
        .{ .name = "linalg.cholesky.Mat2f.refused_not_positive_definite", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat2f, .not_positive_definite), .calls = 32, .f32 = charge_chol2f },
        .{ .name = "linalg.cholesky.Mat2f.refused_nonfinite", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat2f, .nonfinite), .calls = 32, .f32 = charge_chol2f },
        .{ .name = "linalg.cholesky.Mat2f.refused_nan_input", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat2f, .nan_input), .calls = 32, .f32 = charge_chol2f },
        .{ .name = "linalg.cholesky.Mat2f.refused_small_pivot", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat2f, .small_pivot), .calls = 32, .f32 = charge_chol2f },
        .{ .name = "linalg.reconstructCholesky.Mat2f.pipeline_normal", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat2f, linalg.reconstructCholesky, false), .calls = 32, .f32 = charge_chol2f },
        .{ .name = "linalg.reconstructCholesky.Mat2f.pipeline_skewed", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat2f, linalg.reconstructCholesky, true), .calls = 32, .f32 = charge_chol2f },
        .{ .name = "linalg.determinantCholesky.Mat2f.pipeline_normal", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat2f, linalg.determinantCholesky, false), .calls = 32, .f32 = charge_chol2f },
        .{ .name = "linalg.determinantCholesky.Mat2f.pipeline_skewed", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat2f, linalg.determinantCholesky, true), .calls = 32, .f32 = charge_chol2f },
        .{ .name = "linalg.reconstructCholesky.Mat2f.stored", .namespace = "linalg", .invoke = cholStoredReadbackInvoke(matrix.Mat2f, linalg.reconstructCholesky), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantCholesky.Mat2f.stored", .namespace = "linalg", .invoke = cholStoredReadbackInvoke(matrix.Mat2f, linalg.determinantCholesky), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat2f.pipeline_normal", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat2f, .from_factors), .calls = 32, .f32 = charge_chol2f },
        .{ .name = "linalg.solveCholesky.Mat2f.stored", .namespace = "linalg", .invoke = solveCholeskyStoredInvoke(matrix.Mat2f), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat2f.refused_zero_pivot", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat2f, .zero_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat2f.refused_nonfinite_pivot", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat2f, .nonfinite_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat2f.nonfinite_result", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat2f, .overflow), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat2f.pipeline_one_column", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat2f, 1, .from_factors), .calls = 32, .f32 = charge_chol2f },
        .{ .name = "linalg.solveCholeskyMultiple.Mat2f.pipeline_two_columns", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat2f, 2, .from_factors), .calls = 32, .f32 = charge_chol2f },
        .{ .name = "linalg.solveCholeskyMultiple.Mat2f.stored_one_column", .namespace = "linalg", .invoke = solveCholeskyMultipleStoredInvoke(matrix.Mat2f, 1), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat2f.stored_two_columns", .namespace = "linalg", .invoke = solveCholeskyMultipleStoredInvoke(matrix.Mat2f, 2), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat2f.refused_zero_pivot", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat2f, 2, .zero_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat2f.nonfinite_result", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat2f, 2, .overflow), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat3f.normal", .namespace = "linalg", .invoke = luFactorInvoke(matrix.Mat3f, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat3f.skewed", .namespace = "linalg", .invoke = luFactorInvoke(matrix.Mat3f, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat3f.refused_singular", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat3f, .singular), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat3f.refused_nonfinite", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat3f, .nonfinite), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat3f.refused_nan_input", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat3f, .nan_input), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat3f.refused_small_pivot", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat3f, .small_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat3f.pipeline_normal", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat3f, linalg.reconstructLu, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat3f.pipeline_skewed", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat3f, linalg.reconstructLu, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat3f.pipeline_normal", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat3f, linalg.determinantLu, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat3f.pipeline_skewed", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat3f, linalg.determinantLu, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat3f.stored", .namespace = "linalg", .invoke = luStoredReadbackInvoke(matrix.Mat3f, linalg.reconstructLu), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat3f.stored", .namespace = "linalg", .invoke = luStoredReadbackInvoke(matrix.Mat3f, linalg.determinantLu), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat3f.pipeline_normal", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat3f, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat3f.stored", .namespace = "linalg", .invoke = solveLuStoredInvoke(matrix.Mat3f), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat3f.refused_zero_pivot", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat3f, .zero_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat3f.refused_nonfinite_pivot", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat3f, .nonfinite_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat3f.nonfinite_result", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat3f, .overflow), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat3f.pipeline_one_column", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat3f, 1, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat3f.pipeline_two_columns", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat3f, 2, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat3f.stored_one_column", .namespace = "linalg", .invoke = solveLuMultipleStoredInvoke(matrix.Mat3f, 1), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat3f.stored_two_columns", .namespace = "linalg", .invoke = solveLuMultipleStoredInvoke(matrix.Mat3f, 2), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat3f.refused_zero_pivot", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat3f, 2, .zero_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat3f.nonfinite_result", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat3f, 2, .overflow), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat3f.normal", .namespace = "linalg", .invoke = cholFactorInvoke(matrix.Mat3f, false), .calls = 32, .f32 = charge_chol3f },
        .{ .name = "linalg.cholesky.Mat3f.skewed", .namespace = "linalg", .invoke = cholFactorInvoke(matrix.Mat3f, true), .calls = 32, .f32 = charge_chol3f },
        .{ .name = "linalg.cholesky.Mat3f.refused_asymmetric", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat3f, .asymmetric), .calls = 32, .f32 = charge_chol3f },
        .{ .name = "linalg.cholesky.Mat3f.refused_not_positive_definite", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat3f, .not_positive_definite), .calls = 32, .f32 = charge_chol3f },
        .{ .name = "linalg.cholesky.Mat3f.refused_nonfinite", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat3f, .nonfinite), .calls = 32, .f32 = charge_chol3f },
        .{ .name = "linalg.cholesky.Mat3f.refused_nan_input", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat3f, .nan_input), .calls = 32, .f32 = charge_chol3f },
        .{ .name = "linalg.cholesky.Mat3f.refused_small_pivot", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat3f, .small_pivot), .calls = 32, .f32 = charge_chol3f },
        .{ .name = "linalg.reconstructCholesky.Mat3f.pipeline_normal", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat3f, linalg.reconstructCholesky, false), .calls = 32, .f32 = charge_chol3f },
        .{ .name = "linalg.reconstructCholesky.Mat3f.pipeline_skewed", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat3f, linalg.reconstructCholesky, true), .calls = 32, .f32 = charge_chol3f },
        .{ .name = "linalg.determinantCholesky.Mat3f.pipeline_normal", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat3f, linalg.determinantCholesky, false), .calls = 32, .f32 = charge_chol3f },
        .{ .name = "linalg.determinantCholesky.Mat3f.pipeline_skewed", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat3f, linalg.determinantCholesky, true), .calls = 32, .f32 = charge_chol3f },
        .{ .name = "linalg.reconstructCholesky.Mat3f.stored", .namespace = "linalg", .invoke = cholStoredReadbackInvoke(matrix.Mat3f, linalg.reconstructCholesky), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantCholesky.Mat3f.stored", .namespace = "linalg", .invoke = cholStoredReadbackInvoke(matrix.Mat3f, linalg.determinantCholesky), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat3f.pipeline_normal", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat3f, .from_factors), .calls = 32, .f32 = charge_chol3f },
        .{ .name = "linalg.solveCholesky.Mat3f.stored", .namespace = "linalg", .invoke = solveCholeskyStoredInvoke(matrix.Mat3f), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat3f.refused_zero_pivot", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat3f, .zero_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat3f.refused_nonfinite_pivot", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat3f, .nonfinite_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat3f.nonfinite_result", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat3f, .overflow), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat3f.pipeline_one_column", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat3f, 1, .from_factors), .calls = 32, .f32 = charge_chol3f },
        .{ .name = "linalg.solveCholeskyMultiple.Mat3f.pipeline_two_columns", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat3f, 2, .from_factors), .calls = 32, .f32 = charge_chol3f },
        .{ .name = "linalg.solveCholeskyMultiple.Mat3f.stored_one_column", .namespace = "linalg", .invoke = solveCholeskyMultipleStoredInvoke(matrix.Mat3f, 1), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat3f.stored_two_columns", .namespace = "linalg", .invoke = solveCholeskyMultipleStoredInvoke(matrix.Mat3f, 2), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat3f.refused_zero_pivot", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat3f, 2, .zero_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat3f.nonfinite_result", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat3f, 2, .overflow), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat4f.normal", .namespace = "linalg", .invoke = luFactorInvoke(matrix.Mat4f, false), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat4f.skewed", .namespace = "linalg", .invoke = luFactorInvoke(matrix.Mat4f, true), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat4f.refused_singular", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat4f, .singular), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat4f.refused_nonfinite", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat4f, .nonfinite), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat4f.refused_nan_input", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat4f, .nan_input), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat4f.refused_small_pivot", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat4f, .small_pivot), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat4f.pipeline_normal", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat4f, linalg.reconstructLu, false), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat4f.pipeline_skewed", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat4f, linalg.reconstructLu, true), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat4f.pipeline_normal", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat4f, linalg.determinantLu, false), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat4f.pipeline_skewed", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat4f, linalg.determinantLu, true), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat4f.stored", .namespace = "linalg", .invoke = luStoredReadbackInvoke(matrix.Mat4f, linalg.reconstructLu), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat4f.stored", .namespace = "linalg", .invoke = luStoredReadbackInvoke(matrix.Mat4f, linalg.determinantLu), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat4f.pipeline_normal", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat4f, .from_factors), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat4f.stored", .namespace = "linalg", .invoke = solveLuStoredInvoke(matrix.Mat4f), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat4f.refused_zero_pivot", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat4f, .zero_pivot), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat4f.refused_nonfinite_pivot", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat4f, .nonfinite_pivot), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat4f.nonfinite_result", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat4f, .overflow), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat4f.pipeline_one_column", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat4f, 1, .from_factors), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat4f.pipeline_two_columns", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat4f, 2, .from_factors), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat4f.stored_one_column", .namespace = "linalg", .invoke = solveLuMultipleStoredInvoke(matrix.Mat4f, 1), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat4f.stored_two_columns", .namespace = "linalg", .invoke = solveLuMultipleStoredInvoke(matrix.Mat4f, 2), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat4f.refused_zero_pivot", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat4f, 2, .zero_pivot), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat4f.nonfinite_result", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat4f, 2, .overflow), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat4f.normal", .namespace = "linalg", .invoke = cholFactorInvoke(matrix.Mat4f, false), .calls = 16, .f32 = charge_chol4f },
        .{ .name = "linalg.cholesky.Mat4f.skewed", .namespace = "linalg", .invoke = cholFactorInvoke(matrix.Mat4f, true), .calls = 16, .f32 = charge_chol4f },
        .{ .name = "linalg.cholesky.Mat4f.refused_asymmetric", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat4f, .asymmetric), .calls = 16, .f32 = charge_chol4f },
        .{ .name = "linalg.cholesky.Mat4f.refused_not_positive_definite", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat4f, .not_positive_definite), .calls = 16, .f32 = charge_chol4f },
        .{ .name = "linalg.cholesky.Mat4f.refused_nonfinite", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat4f, .nonfinite), .calls = 16, .f32 = charge_chol4f },
        .{ .name = "linalg.cholesky.Mat4f.refused_nan_input", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat4f, .nan_input), .calls = 16, .f32 = charge_chol4f },
        .{ .name = "linalg.cholesky.Mat4f.refused_small_pivot", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat4f, .small_pivot), .calls = 16, .f32 = charge_chol4f },
        .{ .name = "linalg.reconstructCholesky.Mat4f.pipeline_normal", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat4f, linalg.reconstructCholesky, false), .calls = 16, .f32 = charge_chol4f },
        .{ .name = "linalg.reconstructCholesky.Mat4f.pipeline_skewed", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat4f, linalg.reconstructCholesky, true), .calls = 16, .f32 = charge_chol4f },
        .{ .name = "linalg.determinantCholesky.Mat4f.pipeline_normal", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat4f, linalg.determinantCholesky, false), .calls = 16, .f32 = charge_chol4f },
        .{ .name = "linalg.determinantCholesky.Mat4f.pipeline_skewed", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat4f, linalg.determinantCholesky, true), .calls = 16, .f32 = charge_chol4f },
        .{ .name = "linalg.reconstructCholesky.Mat4f.stored", .namespace = "linalg", .invoke = cholStoredReadbackInvoke(matrix.Mat4f, linalg.reconstructCholesky), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.determinantCholesky.Mat4f.stored", .namespace = "linalg", .invoke = cholStoredReadbackInvoke(matrix.Mat4f, linalg.determinantCholesky), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat4f.pipeline_normal", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat4f, .from_factors), .calls = 16, .f32 = charge_chol4f },
        .{ .name = "linalg.solveCholesky.Mat4f.stored", .namespace = "linalg", .invoke = solveCholeskyStoredInvoke(matrix.Mat4f), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat4f.refused_zero_pivot", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat4f, .zero_pivot), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat4f.refused_nonfinite_pivot", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat4f, .nonfinite_pivot), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat4f.nonfinite_result", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat4f, .overflow), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat4f.pipeline_one_column", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat4f, 1, .from_factors), .calls = 16, .f32 = charge_chol4f },
        .{ .name = "linalg.solveCholeskyMultiple.Mat4f.pipeline_two_columns", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat4f, 2, .from_factors), .calls = 16, .f32 = charge_chol4f },
        .{ .name = "linalg.solveCholeskyMultiple.Mat4f.stored_one_column", .namespace = "linalg", .invoke = solveCholeskyMultipleStoredInvoke(matrix.Mat4f, 1), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat4f.stored_two_columns", .namespace = "linalg", .invoke = solveCholeskyMultipleStoredInvoke(matrix.Mat4f, 2), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat4f.refused_zero_pivot", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat4f, 2, .zero_pivot), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat4f.nonfinite_result", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat4f, 2, .overflow), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat2d.normal", .namespace = "linalg", .invoke = luFactorInvoke(matrix.Mat2d, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat2d.skewed", .namespace = "linalg", .invoke = luFactorInvoke(matrix.Mat2d, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat2d.refused_singular", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat2d, .singular), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat2d.refused_nonfinite", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat2d, .nonfinite), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat2d.refused_nan_input", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat2d, .nan_input), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat2d.refused_small_pivot", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat2d, .small_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat2d.pipeline_normal", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat2d, linalg.reconstructLu, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat2d.pipeline_skewed", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat2d, linalg.reconstructLu, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat2d.pipeline_normal", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat2d, linalg.determinantLu, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat2d.pipeline_skewed", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat2d, linalg.determinantLu, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat2d.stored", .namespace = "linalg", .invoke = luStoredReadbackInvoke(matrix.Mat2d, linalg.reconstructLu), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat2d.stored", .namespace = "linalg", .invoke = luStoredReadbackInvoke(matrix.Mat2d, linalg.determinantLu), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat2d.pipeline_normal", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat2d, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat2d.stored", .namespace = "linalg", .invoke = solveLuStoredInvoke(matrix.Mat2d), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat2d.refused_zero_pivot", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat2d, .zero_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat2d.refused_nonfinite_pivot", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat2d, .nonfinite_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat2d.nonfinite_result", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat2d, .overflow), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat2d.pipeline_one_column", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat2d, 1, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat2d.pipeline_two_columns", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat2d, 2, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat2d.stored_one_column", .namespace = "linalg", .invoke = solveLuMultipleStoredInvoke(matrix.Mat2d, 1), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat2d.stored_two_columns", .namespace = "linalg", .invoke = solveLuMultipleStoredInvoke(matrix.Mat2d, 2), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat2d.refused_zero_pivot", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat2d, 2, .zero_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat2d.nonfinite_result", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat2d, 2, .overflow), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat2d.normal", .namespace = "linalg", .invoke = cholFactorInvoke(matrix.Mat2d, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat2d.skewed", .namespace = "linalg", .invoke = cholFactorInvoke(matrix.Mat2d, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat2d.refused_asymmetric", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat2d, .asymmetric), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat2d.refused_not_positive_definite", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat2d, .not_positive_definite), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat2d.refused_nonfinite", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat2d, .nonfinite), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat2d.refused_nan_input", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat2d, .nan_input), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat2d.refused_small_pivot", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat2d, .small_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructCholesky.Mat2d.pipeline_normal", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat2d, linalg.reconstructCholesky, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructCholesky.Mat2d.pipeline_skewed", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat2d, linalg.reconstructCholesky, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantCholesky.Mat2d.pipeline_normal", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat2d, linalg.determinantCholesky, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantCholesky.Mat2d.pipeline_skewed", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat2d, linalg.determinantCholesky, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructCholesky.Mat2d.stored", .namespace = "linalg", .invoke = cholStoredReadbackInvoke(matrix.Mat2d, linalg.reconstructCholesky), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantCholesky.Mat2d.stored", .namespace = "linalg", .invoke = cholStoredReadbackInvoke(matrix.Mat2d, linalg.determinantCholesky), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat2d.pipeline_normal", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat2d, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat2d.stored", .namespace = "linalg", .invoke = solveCholeskyStoredInvoke(matrix.Mat2d), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat2d.refused_zero_pivot", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat2d, .zero_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat2d.refused_nonfinite_pivot", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat2d, .nonfinite_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat2d.nonfinite_result", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat2d, .overflow), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat2d.pipeline_one_column", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat2d, 1, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat2d.pipeline_two_columns", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat2d, 2, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat2d.stored_one_column", .namespace = "linalg", .invoke = solveCholeskyMultipleStoredInvoke(matrix.Mat2d, 1), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat2d.stored_two_columns", .namespace = "linalg", .invoke = solveCholeskyMultipleStoredInvoke(matrix.Mat2d, 2), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat2d.refused_zero_pivot", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat2d, 2, .zero_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat2d.nonfinite_result", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat2d, 2, .overflow), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat3d.normal", .namespace = "linalg", .invoke = luFactorInvoke(matrix.Mat3d, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat3d.skewed", .namespace = "linalg", .invoke = luFactorInvoke(matrix.Mat3d, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat3d.refused_singular", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat3d, .singular), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat3d.refused_nonfinite", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat3d, .nonfinite), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat3d.refused_nan_input", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat3d, .nan_input), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat3d.refused_small_pivot", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat3d, .small_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat3d.pipeline_normal", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat3d, linalg.reconstructLu, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat3d.pipeline_skewed", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat3d, linalg.reconstructLu, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat3d.pipeline_normal", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat3d, linalg.determinantLu, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat3d.pipeline_skewed", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat3d, linalg.determinantLu, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat3d.stored", .namespace = "linalg", .invoke = luStoredReadbackInvoke(matrix.Mat3d, linalg.reconstructLu), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat3d.stored", .namespace = "linalg", .invoke = luStoredReadbackInvoke(matrix.Mat3d, linalg.determinantLu), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat3d.pipeline_normal", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat3d, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat3d.stored", .namespace = "linalg", .invoke = solveLuStoredInvoke(matrix.Mat3d), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat3d.refused_zero_pivot", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat3d, .zero_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat3d.refused_nonfinite_pivot", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat3d, .nonfinite_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat3d.nonfinite_result", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat3d, .overflow), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat3d.pipeline_one_column", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat3d, 1, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat3d.pipeline_two_columns", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat3d, 2, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat3d.stored_one_column", .namespace = "linalg", .invoke = solveLuMultipleStoredInvoke(matrix.Mat3d, 1), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat3d.stored_two_columns", .namespace = "linalg", .invoke = solveLuMultipleStoredInvoke(matrix.Mat3d, 2), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat3d.refused_zero_pivot", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat3d, 2, .zero_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat3d.nonfinite_result", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat3d, 2, .overflow), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat3d.normal", .namespace = "linalg", .invoke = cholFactorInvoke(matrix.Mat3d, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat3d.skewed", .namespace = "linalg", .invoke = cholFactorInvoke(matrix.Mat3d, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat3d.refused_asymmetric", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat3d, .asymmetric), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat3d.refused_not_positive_definite", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat3d, .not_positive_definite), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat3d.refused_nonfinite", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat3d, .nonfinite), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat3d.refused_nan_input", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat3d, .nan_input), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat3d.refused_small_pivot", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat3d, .small_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructCholesky.Mat3d.pipeline_normal", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat3d, linalg.reconstructCholesky, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructCholesky.Mat3d.pipeline_skewed", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat3d, linalg.reconstructCholesky, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantCholesky.Mat3d.pipeline_normal", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat3d, linalg.determinantCholesky, false), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantCholesky.Mat3d.pipeline_skewed", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat3d, linalg.determinantCholesky, true), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.reconstructCholesky.Mat3d.stored", .namespace = "linalg", .invoke = cholStoredReadbackInvoke(matrix.Mat3d, linalg.reconstructCholesky), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.determinantCholesky.Mat3d.stored", .namespace = "linalg", .invoke = cholStoredReadbackInvoke(matrix.Mat3d, linalg.determinantCholesky), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat3d.pipeline_normal", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat3d, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat3d.stored", .namespace = "linalg", .invoke = solveCholeskyStoredInvoke(matrix.Mat3d), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat3d.refused_zero_pivot", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat3d, .zero_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat3d.refused_nonfinite_pivot", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat3d, .nonfinite_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat3d.nonfinite_result", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat3d, .overflow), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat3d.pipeline_one_column", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat3d, 1, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat3d.pipeline_two_columns", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat3d, 2, .from_factors), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat3d.stored_one_column", .namespace = "linalg", .invoke = solveCholeskyMultipleStoredInvoke(matrix.Mat3d, 1), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat3d.stored_two_columns", .namespace = "linalg", .invoke = solveCholeskyMultipleStoredInvoke(matrix.Mat3d, 2), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat3d.refused_zero_pivot", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat3d, 2, .zero_pivot), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat3d.nonfinite_result", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat3d, 2, .overflow), .calls = 32, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat4d.normal", .namespace = "linalg", .invoke = luFactorInvoke(matrix.Mat4d, false), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat4d.skewed", .namespace = "linalg", .invoke = luFactorInvoke(matrix.Mat4d, true), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat4d.refused_singular", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat4d, .singular), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat4d.refused_nonfinite", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat4d, .nonfinite), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat4d.refused_nan_input", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat4d, .nan_input), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.lu.Mat4d.refused_small_pivot", .namespace = "linalg", .invoke = luRefusedInvoke(matrix.Mat4d, .small_pivot), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat4d.pipeline_normal", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat4d, linalg.reconstructLu, false), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat4d.pipeline_skewed", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat4d, linalg.reconstructLu, true), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat4d.pipeline_normal", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat4d, linalg.determinantLu, false), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat4d.pipeline_skewed", .namespace = "linalg", .invoke = luReadbackInvoke(matrix.Mat4d, linalg.determinantLu, true), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.reconstructLu.Mat4d.stored", .namespace = "linalg", .invoke = luStoredReadbackInvoke(matrix.Mat4d, linalg.reconstructLu), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.determinantLu.Mat4d.stored", .namespace = "linalg", .invoke = luStoredReadbackInvoke(matrix.Mat4d, linalg.determinantLu), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat4d.pipeline_normal", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat4d, .from_factors), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat4d.stored", .namespace = "linalg", .invoke = solveLuStoredInvoke(matrix.Mat4d), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat4d.refused_zero_pivot", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat4d, .zero_pivot), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat4d.refused_nonfinite_pivot", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat4d, .nonfinite_pivot), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLu.Mat4d.nonfinite_result", .namespace = "linalg", .invoke = solveLuInvoke(matrix.Mat4d, .overflow), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat4d.pipeline_one_column", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat4d, 1, .from_factors), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat4d.pipeline_two_columns", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat4d, 2, .from_factors), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat4d.stored_one_column", .namespace = "linalg", .invoke = solveLuMultipleStoredInvoke(matrix.Mat4d, 1), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat4d.stored_two_columns", .namespace = "linalg", .invoke = solveLuMultipleStoredInvoke(matrix.Mat4d, 2), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat4d.refused_zero_pivot", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat4d, 2, .zero_pivot), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveLuMultiple.Mat4d.nonfinite_result", .namespace = "linalg", .invoke = solveLuMultipleInvoke(matrix.Mat4d, 2, .overflow), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat4d.normal", .namespace = "linalg", .invoke = cholFactorInvoke(matrix.Mat4d, false), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat4d.skewed", .namespace = "linalg", .invoke = cholFactorInvoke(matrix.Mat4d, true), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat4d.refused_asymmetric", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat4d, .asymmetric), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat4d.refused_not_positive_definite", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat4d, .not_positive_definite), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat4d.refused_nonfinite", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat4d, .nonfinite), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat4d.refused_nan_input", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat4d, .nan_input), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.cholesky.Mat4d.refused_small_pivot", .namespace = "linalg", .invoke = cholRefusedInvoke(matrix.Mat4d, .small_pivot), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.reconstructCholesky.Mat4d.pipeline_normal", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat4d, linalg.reconstructCholesky, false), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.reconstructCholesky.Mat4d.pipeline_skewed", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat4d, linalg.reconstructCholesky, true), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.determinantCholesky.Mat4d.pipeline_normal", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat4d, linalg.determinantCholesky, false), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.determinantCholesky.Mat4d.pipeline_skewed", .namespace = "linalg", .invoke = cholReadbackInvoke(matrix.Mat4d, linalg.determinantCholesky, true), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.reconstructCholesky.Mat4d.stored", .namespace = "linalg", .invoke = cholStoredReadbackInvoke(matrix.Mat4d, linalg.reconstructCholesky), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.determinantCholesky.Mat4d.stored", .namespace = "linalg", .invoke = cholStoredReadbackInvoke(matrix.Mat4d, linalg.determinantCholesky), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat4d.pipeline_normal", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat4d, .from_factors), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat4d.stored", .namespace = "linalg", .invoke = solveCholeskyStoredInvoke(matrix.Mat4d), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat4d.refused_zero_pivot", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat4d, .zero_pivot), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat4d.refused_nonfinite_pivot", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat4d, .nonfinite_pivot), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholesky.Mat4d.nonfinite_result", .namespace = "linalg", .invoke = solveCholeskyInvoke(matrix.Mat4d, .overflow), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat4d.pipeline_one_column", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat4d, 1, .from_factors), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat4d.pipeline_two_columns", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat4d, 2, .from_factors), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat4d.stored_one_column", .namespace = "linalg", .invoke = solveCholeskyMultipleStoredInvoke(matrix.Mat4d, 1), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat4d.stored_two_columns", .namespace = "linalg", .invoke = solveCholeskyMultipleStoredInvoke(matrix.Mat4d, 2), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat4d.refused_zero_pivot", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat4d, 2, .zero_pivot), .calls = 16, .f32 = charge_none },
        .{ .name = "linalg.solveCholeskyMultiple.Mat4d.nonfinite_result", .namespace = "linalg", .invoke = solveCholeskyMultipleInvoke(matrix.Mat4d, 2, .overflow), .calls = 16, .f32 = charge_none },
    };
};

// ---------------------------------------------------------------------------
// Stored-factor regressions.
//
// A `nonfinite_result` row is the one place a fixture mistake survives the
// checksum: a right-hand side or a stored factor small enough to stay in range
// answers an ordinary finite vector, and the row hashes it like any other
// answer. The tests below pin what the row names promise, per type and per
// entry point: finite stored factors and a finite right-hand side, an answer
// rather than a refusal, and the class of every component of that answer.
// ---------------------------------------------------------------------------

/// What one component of a solved column is. "Not finite" is too coarse for
/// these rows: the infinity the substitutions divided out and the NaN an
/// infinity made by meeting another one are different arithmetic, and a row
/// that stops producing one of them has changed the path it measures without
/// changing its name.
const SolvedClass = enum { finite, positive_infinity, negative_infinity, nan };

fn classifySolved(value: anytype) SolvedClass {
    const T = @TypeOf(value);
    if (std.math.isNan(value)) return .nan;
    if (value == std.math.inf(T)) return .positive_infinity;
    if (value == -std.math.inf(T)) return .negative_infinity;
    return .finite;
}

/// Which family reads which triangle, which is the only reason the two
/// families disagree on their first component.
const StoredSolver = enum { lu, cholesky };

/// The six factorizations `linalg` publishes, in the order the `cases` list
/// walks them.
const factorMatrixTypes = [_]type{
    matrix.Mat2f,
    matrix.Mat3f,
    matrix.Mat4f,
    matrix.Mat2d,
    matrix.Mat3d,
    matrix.Mat4d,
};

/// The component classes the stored-factor overflow rows are built to produce.
///
/// The second forward row is where both families leave the format: it
/// subtracts a stored overflow factor times the first right-hand side entry
/// from a finite right-hand side entry, and finite minus infinity is
/// `-infinity`. From the third row on the forward sum is an infinity plus that
/// `-infinity`, which is the invalid NaN, so every component from the third on
/// answers NaN and the back substitution hands that NaN to every row above it.
///
/// At size two there is no third row, and the one finite forward row left is
/// the first component, so the answer is `+infinity` in the first component and
/// `-infinity` in the last: the back substitution subtracts the `-infinity` of
/// the last row from a finite first row. Both families answer the same pair,
/// because the entry the Cholesky substitution multiplies by stays finite even
/// where the stored factor does not.
fn expectedOverflowClasses(comptime n: usize) [n]SolvedClass {
    var out = [_]SolvedClass{.nan} ** n;
    if (n == 2) {
        out[0] = .positive_infinity;
        out[1] = .negative_infinity;
    }
    return out;
}

/// The stored LU factors an overflow row hands a solve: every entry finite,
/// the identity permutation, and the parity of a permutation that moved
/// nothing. A stored pivot that is zero or not finite is the one thing that
/// makes this solve answer `null`, and no entry here is, so the answer below
/// is a value.
fn expectFiniteLuFactors(comptime M: type, factor: LuTypeFor(M)) !void {
    inline for (0..M.rows) |column| {
        inline for (0..M.rows) |row| {
            try std.testing.expect(std.math.isFinite(factor.lu.data[column][row]));
        }
    }
    inline for (0..M.rows) |row| {
        try std.testing.expectEqual(@as(usize, row), @as(usize, factor.permutation[row]));
    }
    try std.testing.expectEqual(@as(i1, 0), factor.parity);
}

/// The stored Cholesky factors an overflow row hands a solve: the strict lower
/// triangle that is the only triangle a `CholeskyMat` stores, and a positive
/// finite pivot in every row, so nothing in the stored value can fail the
/// solve's own pivot test.
fn expectStrictLowerCholeskyFactors(comptime M: type, factor: CholTypeFor(M)) !void {
    inline for (0..M.rows) |column| {
        inline for (0..M.rows) |row| {
            const entry = factor.lower.data[column][row];
            if (row < column) {
                try std.testing.expectEqual(@as(M.Element, 0), entry);
            } else {
                try std.testing.expect(std.math.isFinite(entry));
            }
        }
    }
    inline for (0..M.rows) |row| {
        const pivot = factor.lower.data[row][row];
        try std.testing.expect(std.math.isFinite(pivot));
        try std.testing.expect(pivot > 0);
    }
}

fn expectSolvedComponents(
    comptime n: usize,
    comptime expected: [n]SolvedClass,
    components: anytype,
) !void {
    for (components, 0..) |value, component| {
        try std.testing.expectEqual(expected[component], classifySolved(value));
    }
}

/// Both entry points of one family against one matrix type: the vector solve
/// and the two-column solve, off the same stored factors and the same finite
/// right-hand sides the `nonfinite_result` rows time.
fn expectStoredOverflowSolve(comptime M: type, comptime solver: StoredSolver) !void {
    const expected = comptime expectedOverflowClasses(M.rows);

    const vector = hugeVectorAt(M);
    const columns = hugeMatrixAt(M, 2);
    for (vector.toArray()) |value| try std.testing.expect(std.math.isFinite(value));
    inline for (0..2) |column| {
        inline for (0..M.rows) |row| {
            try std.testing.expect(std.math.isFinite(columns.data[column][row]));
        }
    }
    switch (solver) {
        .lu => {
            const factor = handBuiltLu(M, .overflow);
            try expectFiniteLuFactors(M, factor);
            const solved = linalg.solveLu(factor, vector) orelse return error.RefusedSolve;
            try expectSolvedComponents(M.rows, expected, solved.toArray());
            const many = linalg.solveLuMultiple(factor, columns) orelse
                return error.RefusedSolve;
            inline for (0..2) |column| {
                try expectSolvedComponents(M.rows, expected, many.data[column][0..M.rows]);
            }
        },
        .cholesky => {
            const factor = handBuiltCholesky(M, .overflow);
            try expectStrictLowerCholeskyFactors(M, factor);
            const solved = linalg.solveCholesky(factor, vector) orelse return error.RefusedSolve;
            try expectSolvedComponents(M.rows, expected, solved.toArray());
            const many = linalg.solveCholeskyMultiple(factor, columns) orelse
                return error.RefusedSolve;
            inline for (0..2) |column| {
                try expectSolvedComponents(M.rows, expected, many.data[column][0..M.rows]);
            }
        },
    }
}

/// A valid stored factorization against a normal right-hand side answers a
/// vector of ordinary finite components, which is what tells the overflow
/// rows apart from the stored rows they sit beside.
fn expectStoredFiniteSolve(comptime M: type) !void {
    for (0..8) |index| {
        const rhs = outVectorAt(M, index, 0x9b05_688c_2b3e_6c1f);
        const columns = rhsAt(M, 2, index, 0x1f83_d9ab_fb41_bd6b);
        const lu_factor = storedLu(M, index);
        const chol_factor = storedCholesky(M, index);
        const lu_answer = linalg.solveLu(lu_factor, rhs) orelse return error.RefusedSolve;
        const chol_answer = linalg.solveCholesky(chol_factor, rhs) orelse
            return error.RefusedSolve;
        for (lu_answer.toArray(), chol_answer.toArray()) |value, solved| {
            try std.testing.expect(std.math.isFinite(value));
            try std.testing.expect(std.math.isFinite(solved));
        }
        const lu_columns = linalg.solveLuMultiple(lu_factor, columns) orelse
            return error.RefusedSolve;
        const chol_columns = linalg.solveCholeskyMultiple(chol_factor, columns) orelse
            return error.RefusedSolve;
        inline for (0..2) |column| {
            for (lu_columns.data[column], chol_columns.data[column]) |value, solved| {
                try std.testing.expect(std.math.isFinite(value));
                try std.testing.expect(std.math.isFinite(solved));
            }
        }
    }
}

test "the stored LU overflow rows answer a non-null vector of non-finite components" {
    inline for (factorMatrixTypes) |M| try expectStoredOverflowSolve(M, .lu);
}

test "the stored Cholesky overflow rows answer a non-null vector of non-finite components" {
    inline for (factorMatrixTypes) |M| try expectStoredOverflowSolve(M, .cholesky);
}

test "a stored pivot of zero or not finite refuses, where an overflow is answered" {
    // The contract separates the two ways these solves answer `null`: a stored
    // pivot that is zero or not finite refuses, while an arithmetic overflow
    // leaves the optional alone. The overflow rows are only a distinct
    // measurement from the refusal rows while that difference is real.
    inline for (factorMatrixTypes) |M| {
        const vector = hugeVectorAt(M);
        const columns = hugeMatrixAt(M, 2);
        inline for ([_]SolvePolicy{ .zero_pivot, .nonfinite_pivot }) |policy| {
            const lu_factor = handBuiltLu(M, policy);
            const chol_factor = handBuiltCholesky(M, policy);
            try std.testing.expect(linalg.solveLu(lu_factor, vector) == null);
            try std.testing.expect(linalg.solveCholesky(chol_factor, vector) == null);
            try std.testing.expect(linalg.solveLuMultiple(lu_factor, columns) == null);
            try std.testing.expect(linalg.solveCholeskyMultiple(chol_factor, columns) == null);
        }
    }
}

test "a valid stored factorization answers finite components at every size and precision" {
    inline for (factorMatrixTypes) |M| try expectStoredFiniteSolve(M);
}

// ---------------------------------------------------------------------------
// Complete callable inventory for the three modules this file covers.
//
// TIMED DIRECTLY, every declared entry point:
//
// zmath.complex, 54 functions in 27 families, each in both precisions and
// under three input regimes:
//   realf reald imagf imagd conjf conjd projf projd
//   absf absd argf argd
//   addf addd subf subd mulf muld divf divd
//   expf expd logf logd log10f log10d sqrtf sqrtd powf powd
//   sinf sind cosf cosd tanf tand
//   sinhf sinhd coshf coshd tanhf tanhd
//   asinf asind acosf acosd atanf atand
//   asinhf asinhd acoshf acoshd atanhf atanhd
//   Complexf Complexd are plain data and declare no function.
//
// zmath.matrix, the factory, every decl and every method of every
// instantiation:
//   Mat(rows, columns, Scalar)      COMPILE-ONLY: it declares a type, not a
//                                   callable, and its guard is comptime.
//   Element element_component rows columns vector_type
//                                   COMPILE-ONLY: type and integer decls.
//   init fill at set                timed for f32, f64, Complexf and Complexd
//                                   at wide and tall shapes, normal and
//                                   boundary; `init` exercises the row-major
//                                   literal to column-major transposition.
//   identity                        COMPILE-ONLY: it takes no argument and
//                                   returns a published constant, so there is
//                                   no runtime input to vary and nothing left
//                                   to time.
//   add sub neg scale transpose     timed for f32, f64, Complexf and Complexd
//                                   at square (2x2, 3x3, 4x4), wide (2x4) and
//                                   tall (4x2) shapes, normal and boundary.
//   mulVec                          timed for f32 and f64 at 15 shapes and for
//                                   Complexf and Complexd at 6 shapes, so both
//                                   declared column routes are covered: a named
//                                   Vec2f/Vec3f/Vec4f/Vec2d/Vec3d/Vec4d column
//                                   with a named row-sized result, a named
//                                   column with a plain array result (1x3,
//                                   1x5, 5x1, 5x4), a plain array column with a
//                                   named result (3x1, 4x5), and a plain array
//                                   column with a plain array result (1x5).
//   isFinite                        timed for all four entry types, normal and
//                                   boundary.
//   determinant                     timed for all four entry types; the
//                                   Complexf and Complexd cases at 2x2 and 3x3
//                                   are the only route to a complex determinant.
//                                   COMPILE-ONLY for a non-square
//                                   instantiation: it is a @compileError
//                                   naming the shape.
//   Mat2f Mat3f Mat4f Mat5f Mat2d Mat3d Mat4d Mat5d
//                                   COMPILE-ONLY: type aliases.
//   mul(output_columns, left, right)
//                                   timed for f32 and f64 at square 2x2, 3x3
//                                   and 4x4, wide-by-tall 2x3 times 3x2 and
//                                   3x4 times 4x3 and 2x4 times 4x2, a
//                                   tall-by-wide 4x2 times 2x4, and the
//                                   five-row 5x4 times 4x3 contraction that
//                                   exceeds every named size; and for Complexf
//                                   and Complexd at 2x2, 3x3 and 2x3 times 3x2.
//   determinantMat2f determinantMat2d determinantMat3f determinantMat3d
//   determinantMat4f determinantMat4d determinantMat5f determinantMat5d
//                                   timed for every size and precision under
//                                   normal, boundary, skewed and singular
//                                   inputs, so both the closed forms at size
//                                   two and three and the cofactor recursion at
//                                   size four and five are covered.
//   inverseMat2f inverseMat2d inverseMat3f inverseMat3d inverseMat4f
//   inverseMat4d                    timed for every size and precision under
//                                   normal, boundary and skewed inputs and
//                                   under all four null reasons: an eliminated
//                                   column with no pivot, a non-finite entry in
//                                   the pre-scan, a NaN entry in the pre-scan,
//                                   a pivot at or below the threshold, and a
//                                   reduction that normalizes the right block
//                                   past the format range.
//   mulMat4fVec4f mulMat4dVec4d     timed, normal and boundary.
//   inverse_pivot_threshold_f inverse_pivot_threshold_d
//                                   COMPILE-ONLY: published constants with no
//                                   call to time.
//
// zmath.linalg:
//   LuMat2f LuMat3f LuMat4f LuMat2d LuMat3d LuMat4d
//   CholeskyMat2f CholeskyMat3f CholeskyMat4f
//   CholeskyMat2d CholeskyMat3d CholeskyMat4d
//                                   COMPILE-ONLY: plain data structs declaring
//                                   no method; their fields are read through
//                                   the timed operations below.
//   lu(value)                       timed for all six types: normal, skewed,
//                                   and the four refusals (a matrix whose
//                                   elimination annihilates the column, a
//                                   non-finite entry, a NaN entry, and a pivot
//                                   at or below the threshold).
//   reconstructLu(f)                timed for all six types twice over: a
//                                   `pipeline` pair that runs `lu` inside the
//                                   timed region under normal and skewed
//                                   inputs, and a `stored` pair that hands the
//                                   readback a valid factorization written
//                                   field by field, so the method alone is
//                                   what the row measures.
//   determinantLu(f)                timed for all six types, same two cohorts.
//   solveLu(f, rhs)                 timed for all six types across five
//                                   transitions: that same pipeline, a
//                                   `stored` solve against the same valid
//                                   hand-written factorization, a hand-built
//                                   factorization with a zero stored pivot,
//                                   one with a NaN stored pivot, and one
//                                   whose forward and back substitutions
//                                   overflow, and the contract answers that with a
//                                   non-null vector rather than with `null`.
//   solveLuMultiple(f, rhs)         timed for all six types with a one-column
//                                   and a two-column right-hand side under the
//                                   pipeline, the stored factor and both
//                                   refusals, so both factor regimes are
//                                   covered at both widths.
//   cholesky(value)                 timed for all six types: normal, skewed,
//                                   and the five refusals (asymmetric by one
//                                   ulp, not positive definite, non-finite,
//                                   NaN, and a pivot at or below the
//                                   threshold).
//   reconstructCholesky(f)          timed for all six types, the same
//                                   `pipeline` and `stored` cohorts as
//                                   reconstructLu.
//   determinantCholesky(f)          timed for all six types, the same two
//                                   cohorts.
//   solveCholesky(f, rhs)           timed for all six types across the same
//                                   five transitions as solveLu.
//   solveCholeskyMultiple(f, rhs)   timed for all six types with one and two
//                                   columns, across the same five transitions.
//   A binary32 `pipeline` Cholesky row is charged one `sqrtf` per diagonal
//   factor, because that constructor is inside its timed region; a binary64
//   `pipeline` row and every `stored` row charge nothing.
//
// REACHED ONLY THROUGH A TIMED PUBLIC ENTRY POINT, never timed on its own:
//   zmath.complex private kernels ComplexOf positiveInfinity canonicalNaN
//     halfPiOf lnTenOf sqrtTwoOf sqrtMinNormalOf magnitudeLimitOf Format
//     isNaN isInfinity quieted firstNaN2 firstNaN4 withSign product divide
//     projValue magnitude absValue argValue addTerm subTerm plus minus mulValue
//     zeroQuotient divValue toBaseTen polarSpecial logValue log10Value
//     sqrtScaled sqrtValue powValue sinValue cosValue tanValue sinhValue
//     coshValue tanhValue rejectInfinity asinValue acosValue atanValue
//     asinhValue acoshValue atanhValue. Each is private, so it has no public
//     spelling of its own; every one of them is on the path of at least one
//     case above.
//   zmath.matrix private helpers Component RealOf zeroOf oneOf Bits
//     canonicalNaN quietNaN binaryResult unaryResult entryAdd entrySub
//     entryMul entryNeg isFiniteEntry lane_names VecOf laneType laneAt
//     laneSet hasDecl isMat Product entryAt minorOf det2 det3 cofactorDet
//     pivotThresholdOf gaussJordan. Each is private and reached only through a
//     timed public method or free helper.
//   zmath.linalg private helpers finiteScaleOf allFinite pivotThresholdOf
//     sqrtOf n_of LuOf CholeskyOf MatrixOf RightHandSidesOf luFactor
//     unitLowerOf upperOf luSolveColumn choleskyFactor choleskySolveColumn.
//     Each is private and reached only through a timed public function.
//
// The API declares no dynamic matrix, expression template, or tensor type, so
// the inventory above is complete.
// ---------------------------------------------------------------------------
