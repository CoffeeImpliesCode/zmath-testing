//! Leaf slice of the API round: the root generic scalar routes and the
//! `zmath.scalar` and `zmath.ieee` canonical per-format families.
//!
//! Every case here is a direct timed call into one canonical public entry
//! point, plus one dispatch case per root generic entry point. The
//! `Charge` entries name the verbatim public symbol of the accepted binary32
//! kernel, so a root wrapper, an `f16` wrapper and a narrowing kernel that
//! land on the same accepted symbol share one ledger key.
//!
//! No case allocates: every operand comes from a comptime bit table indexed by
//! the runtime index the harness supplies.
//!
//! --- What one `Charge` counts -----------------------------------------
//!
//! A `Charge` count is a per-`invoke` UPPER BOUND on the accepted binary32
//! evaluations that case reaches, taken over every branch the operands can
//! select, so one number covers all three regimes and one root dispatch that
//! evaluates `f16`, `f32` and `f64` in a single `invoke`. Three rules decide
//! what reaches the ledger:
//!
//! 1. A public accepted binary32 kernel reached through another entry point's
//!    body is charged under its own verbatim name, and the caller keeps its own
//!    key too. `cbrth` calls `cbrtf` once on its fallback path and charges
//!    `cbrtf`, because `cbrth` is binary16 and opens no binary32 key of its
//!    own.
//!    An entry point whose body only forwards, with no numerical work of its
//!    own, is the exception: it stays timed as its own public case but its one
//!    numerical evaluation is the terminal accepted kernel, so it opens no key.
//!    `rintf` and `roundevenf` each forward to `nearbyintf`, `powrf` forwards
//!    to `powf`, and `logp1f` forwards to `log1pf`; each charges the terminal
//!    kernel once. Nested genuine numerical work, such as the `fmaf`
//!    evaluations those kernels spend, is still charged on top.
//! 2. `scalar_fma.fma` is the one shared binary32 fused-multiply-add engine
//!    and `zmath.scalar.fmaf` is its public name, so every evaluation of it
//!    keys `fmaf`. `coremath_fma.h` spells the same engine `zmath_fmaf` in C:
//!    `__builtin_fmaf` on a fused target, and the `zmath_core_fmaf_soft` export
//!    of this same module everywhere else. A seam's `zmath_fmaf` is therefore
//!    the same engine and takes the same key. Most binary16 kernels evaluate
//!    their last rounding step in binary32 through that engine, which is why
//!    the half families below carry their own `fmaf` counts. A few binary32
//!    kernels reach it too, once each on one branch: `asinf`, `atanf`, `tanf`,
//!    `tanhf` and `cosf`.
//!    `scalar_fma.fma64` and the C `zmath_fma` are the binary64 engine and are
//!    never a binary32 charge.
//! 3. A C ABI seam that takes and returns a binary16 encoding
//!    (`zmath_core_powh_bits`, `zmath_core_erfch_bits`,
//!    `zmath_core_cospih_bits`, the `asinpi`, `acospi`, `atanpi`, `atan2`,
//!    `lgamma`, `tgamma`, `log2p1` and `log10p1` seams, ...) is the body of
//!    the kernel that calls it once, not a second accepted kernel, so it opens
//!    no entry of its own. Its `zmath_fmaf` evaluations are not free, though:
//!    they are spent inside that kernel and are charged to it under `fmaf`.
//!    `@sqrt`, `@abs`, plain IEEE arithmetic and bit manipulation are not
//!    accepted kernels either.
//!
//! `erfh` is the one binary16 special function that reaches no binary32 kernel
//! at all: `scalar_erfh.zig` widens to binary64 and runs its own degree-eight
//! polynomial over the 56-row table, so the binary16 `erf` case charges
//! nothing and must not be described as a binary32 `erf` evaluation.

const std = @import("std");
const zmath = @import("zmath");
const common = @import("api_round_common.zig");

/// The three input regimes every family is measured under.
///
/// `normal` is an ordinary spread of representable magnitudes, `boundary` is
/// the special-value surface (signed zeros, both infinities, the extreme
/// finite magnitudes, the subnormal extremes, the smallest normal), and
/// `skewed` is the adversarial surface (signaling and payload-carrying NaNs,
/// negative subnormals, one-ulp neighbours of exact values and the rounding
/// tie regions).
const Regime = enum { normal, boundary, skewed };

const slots_per_regime = 8;
const slot_total = slots_per_regime * 3;

const f16_bits = [slot_total]u16{
    // normal
    0x3800, 0x3c00, 0x3e00, 0x4000, 0x4200, 0x3801, 0xbc00, 0xc120,
    // boundary
    0x0000, 0x8000, 0x7c00, 0xfc00, 0x7bff, 0x0001, 0x03ff, 0x0400,
    // skewed
    0x7c01, 0xfe21, 0x8001, 0x3c01, 0xbc01, 0x7bfe, 0x0200, 0x8400,
};

const f32_bits = [slot_total]u32{
    // normal
    0x3f00_0000, 0x3f80_0000, 0x3fc0_0000, 0x4000_0000, 0x4040_0000,
    0x3f80_0001, 0xbf80_0000, 0xc060_0000,
    // boundary
    0x0000_0000, 0x8000_0000,
    0x7f80_0000, 0xff80_0000, 0x7f7f_ffff, 0x0000_0001, 0x007f_ffff,
    0x0080_0000,
    // skewed
    0x7f80_0001, 0xffc0_0001, 0x8000_0001, 0x3f80_0001,
    0xbf80_0001, 0x7f7f_fffe, 0x3380_0000, 0xc000_0000,
};

const f64_bits = [slot_total]u64{
    // normal
    0x3fe0_0000_0000_0000, 0x3ff0_0000_0000_0000, 0x3ff8_0000_0000_0000,
    0x4000_0000_0000_0000, 0x4008_0000_0000_0000, 0x3ff0_0000_0000_0001,
    0xbff0_0000_0000_0000, 0xc060_0000_0000_0000,
    // boundary
    0x0000_0000_0000_0000,
    0x8000_0000_0000_0000, 0x7ff0_0000_0000_0000, 0xfff0_0000_0000_0000,
    0x7fef_ffff_ffff_ffff, 0x0000_0000_0000_0001, 0x000f_ffff_ffff_ffff,
    0x0010_0000_0000_0000,
    // skewed
    0x7ff0_0000_0000_0001, 0xfff8_0000_0000_0001,
    0x8000_0000_0000_0001, 0x3ff0_0000_0000_0001, 0xbff0_0000_0000_0001,
    0x7fef_ffff_ffff_fffe, 0x3ca0_0000_0000_0000, 0xc000_0000_0000_0000,
};

/// The `fromfp` width operands, including the zero width that every family
/// rejects and widths that no binary format can represent.
const fromfp_widths = [_]u32{ 0, 1, 8, 16, 24, 32, 53, 64, 65, 128 };

const fromfp_rounds = [_]zmath.FromFpRound{
    .nearest_even,
    .nearest_from_zero,
    .toward_zero,
    .toward_positive,
    .toward_negative,
};

/// `ldexp` and `scalbn` scale amounts, spanning the exact range, the
/// overflow range and the full-underflow range of every supported format.
const exponents32 = [_]i32{ 0, 1, -1, 15, -15, 23, -23, 52, 127, -127, 1024, -1024, 4000, -4000 };

/// `scalbln` takes the same scale amounts at `i64` width.
const exponents64 = [_]i64{ 0, 1, -1, 15, -15, 23, -23, 52, 127, -127, 1023, -1023, 4096, -4096 };

/// `scaleB` uses the `i32` exponents; the extreme entries drive it into the
/// saturating overflow and the full-underflow return.
const scale_exponents = [_]i32{ 0, 1, -1, 16, -16, 24, -24, 60, -60, 300, -300, 5000, -5000 };

/// Integer degrees for `pown`, `compoundn` and `rootn`, including zero, one,
/// odd and even degrees, and degrees outside the implemented `[-64, 64]`
/// window that report `ok == false`.
const degrees = [_]i64{ 0, 1, 2, 3, -1, -2, -3, 4, 7, 8, 16, 31, 32, 63, 64, 65, -64, -65, 100 };

/// `nan` payload tags: the empty tag, a small accepted payload, the zero
/// payload, the widest accepted binary16 payload, a tag binary16 must reject,
/// the widest accepted binary32 payload, a tag outside the hexadecimal
/// grammar, and a tag wider than the binary64 payload field.
const nan_tags = [_][]const u8{
    "",
    "1",
    "0",
    "1ff",
    "3ff",
    "3fffff",
    "zz",
    "ffffffffffffffffff",
};

const round_modes = [_]zmath.ieee.RoundMode{
    .nearest_even,
    .toward_zero,
    .toward_positive,
    .toward_negative,
};

fn Bits(comptime T: type) type {
    return std.meta.Int(.unsigned, @bitSizeOf(T));
}

/// A deterministic, non-affine spread of the eight slots of one regime.
///
/// The mix keeps consecutive harness indices on different fixtures without
/// leaving the regime, so a kernel never sees the same operand twice in a row
/// and the loop cannot fold into a repeated constant.
fn scramble(index: usize) usize {
    return ((index *% 5) +% (index / 8) +% (index / 64)) & (slots_per_regime - 1);
}

fn fbits(comptime T: type, regime: Regime, index: usize) Bits(T) {
    const offset: usize = @as(usize, @intFromEnum(regime)) * slots_per_regime;
    const slot = offset + scramble(index);
    // Each branch is the only one evaluated for a given `T`, so the table
    // lookup keeps the exact integer width of that format.
    if (T == f16) return f16_bits[slot];
    if (T == f32) return f32_bits[slot];
    return f64_bits[slot];
}

fn fx(comptime T: type, regime: Regime, index: usize) T {
    return @bitCast(fbits(T, regime, index));
}

/// The regime a root dispatch case runs under, cycled by the harness index so
/// one dispatch case covers all three regimes.
fn rootRegime(index: usize) Regime {
    return switch (index % 3) {
        0 => .normal,
        1 => .boundary,
        else => .skewed,
    };
}

fn nanWith(comptime T: type, tag: []const u8) T {
    if (T == f16) return zmath.ieee.nanh(tag);
    if (T == f32) return zmath.ieee.nanf(tag);
    if (T == f64) return zmath.ieee.nand(tag);
    @compileError("api_round_leaf: nanWith supports only f16, f32, and f64");
}

// ---------------------------------------------------------------------------
// Timed callbacks
//
// One callback performs one fixed amount of work: a single canonical
// evaluation, or one evaluation per supported format for a root dispatch
// case. `Case.calls` is the number of times the harness makes that call.
// Every callback is a distinct instantiation, so each one keeps its own
// fixture table read and its own kernel call.
// ---------------------------------------------------------------------------

fn unopCase(comptime T: type, comptime regime: Regime, comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            return common.hash(op(fx(T, regime, index)));
        }
    };
    return Body.run;
}

fn binopCase(comptime T: type, comptime regime: Regime, comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const left = fx(T, regime, index);
            const right = fx(T, regime, index +% 3);
            return common.hash(op(left, right));
        }
    };
    return Body.run;
}

fn trinopCase(comptime T: type, comptime regime: Regime, comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const first = fx(T, regime, index);
            const second = fx(T, regime, index +% 3);
            const third = fx(T, regime, index +% 5);
            return common.hash(op(first, second, third));
        }
    };
    return Body.run;
}

/// `fromBitsh` and any other entry point whose only operand is the encoding.
fn bitsToFloatCase(comptime T: type, comptime regime: Regime, comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            return common.hash(op(fbits(T, regime, index)));
        }
    };
    return Body.run;
}

fn fromfpCase(comptime T: type, comptime regime: Regime, comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const round = fromfp_rounds[index % fromfp_rounds.len];
            const width = fromfp_widths[(index / 5) % fromfp_widths.len];
            return common.hash(op(fx(T, regime, index), round, width));
        }
    };
    return Body.run;
}

fn expo32Case(comptime T: type, comptime regime: Regime, comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            return common.hash(op(fx(T, regime, index), exponents32[index % exponents32.len]));
        }
    };
    return Body.run;
}

fn expo64Case(comptime T: type, comptime regime: Regime, comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            return common.hash(op(fx(T, regime, index), exponents64[index % exponents64.len]));
        }
    };
    return Body.run;
}

fn degreeCase(comptime T: type, comptime regime: Regime, comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            return common.hash(op(fx(T, regime, index), degrees[index % degrees.len]));
        }
    };
    return Body.run;
}

/// `nextToward`: the binary16 and binary32 kernels take a binary64 target,
/// so the second operand is drawn from the binary64 table of the same regime.
fn towardCase(comptime T: type, comptime regime: Regime, comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            return common.hash(op(fx(T, regime, index), fx(f64, regime, index +% 1)));
        }
    };
    return Body.run;
}

fn scaleBCase(comptime T: type, comptime regime: Regime, comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const mode = round_modes[index % round_modes.len];
            return common.hash(op(mode, fx(T, regime, index), scale_exponents[index % scale_exponents.len]));
        }
    };
    return Body.run;
}

fn roundIntegralCase(comptime T: type, comptime regime: Regime, comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const mode = round_modes[index % round_modes.len];
            return common.hash(op(mode, fx(T, regime, index)));
        }
    };
    return Body.run;
}

fn nanCase(comptime T: type, comptime regime: Regime) *const fn (usize) u64 {
    // `nan` takes no float operand, so the regime selects a different band of
    // the tag table instead: each regime still sees accepted and rejected
    // payloads, at different positions in the table.
    const offset: usize = @as(usize, @intFromEnum(regime)) * 3;
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const tag = nan_tags[(offset + index) % nan_tags.len];
            return common.hash(nanWith(T, tag));
        }
    };
    return Body.run;
}

// ---------------------------------------------------------------------------
// Root dispatch callbacks
//
// Each one runs the root generic entry point once per supported format under
// the regime the harness index selects, so one case covers the whole `T ==
// f16` / `f32` / `f64` dispatch of that entry point.
// ---------------------------------------------------------------------------

fn rootUnop(comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const regime = rootRegime(index);
            var acc: u64 = 0;
            acc = common.mix(acc, common.hash(op(fx(f16, regime, index))));
            acc = common.mix(acc, common.hash(op(fx(f32, regime, index))));
            acc = common.mix(acc, common.hash(op(fx(f64, regime, index))));
            return acc;
        }
    };
    return Body.run;
}

fn rootBinop(comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const regime = rootRegime(index);
            var acc: u64 = 0;
            acc = common.mix(acc, common.hash(op(fx(f16, regime, index), fx(f16, regime, index +% 3))));
            acc = common.mix(acc, common.hash(op(fx(f32, regime, index), fx(f32, regime, index +% 3))));
            acc = common.mix(acc, common.hash(op(fx(f64, regime, index), fx(f64, regime, index +% 3))));
            return acc;
        }
    };
    return Body.run;
}

fn rootTrinop(comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const regime = rootRegime(index);
            var acc: u64 = 0;
            acc = common.mix(acc, common.hash(op(
                fx(f16, regime, index),
                fx(f16, regime, index +% 3),
                fx(f16, regime, index +% 5),
            )));
            acc = common.mix(acc, common.hash(op(
                fx(f32, regime, index),
                fx(f32, regime, index +% 3),
                fx(f32, regime, index +% 5),
            )));
            acc = common.mix(acc, common.hash(op(
                fx(f64, regime, index),
                fx(f64, regime, index +% 3),
                fx(f64, regime, index +% 5),
            )));
            return acc;
        }
    };
    return Body.run;
}

fn rootExpo32(comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const regime = rootRegime(index);
            const exponent = exponents32[index % exponents32.len];
            var acc: u64 = 0;
            acc = common.mix(acc, common.hash(op(fx(f16, regime, index), exponent)));
            acc = common.mix(acc, common.hash(op(fx(f32, regime, index), exponent)));
            acc = common.mix(acc, common.hash(op(fx(f64, regime, index), exponent)));
            return acc;
        }
    };
    return Body.run;
}

fn rootExpo64(comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const regime = rootRegime(index);
            const exponent = exponents64[index % exponents64.len];
            var acc: u64 = 0;
            acc = common.mix(acc, common.hash(op(fx(f16, regime, index), exponent)));
            acc = common.mix(acc, common.hash(op(fx(f32, regime, index), exponent)));
            acc = common.mix(acc, common.hash(op(fx(f64, regime, index), exponent)));
            return acc;
        }
    };
    return Body.run;
}

fn rootDegree(comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const regime = rootRegime(index);
            const degree = degrees[index % degrees.len];
            var acc: u64 = 0;
            acc = common.mix(acc, common.hash(op(fx(f16, regime, index), degree)));
            acc = common.mix(acc, common.hash(op(fx(f32, regime, index), degree)));
            acc = common.mix(acc, common.hash(op(fx(f64, regime, index), degree)));
            return acc;
        }
    };
    return Body.run;
}

fn rootFromfp(comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const regime = rootRegime(index);
            const round = fromfp_rounds[index % fromfp_rounds.len];
            const width = fromfp_widths[(index / 5) % fromfp_widths.len];
            var acc: u64 = 0;
            acc = common.mix(acc, common.hash(op(fx(f16, regime, index), round, width)));
            acc = common.mix(acc, common.hash(op(fx(f32, regime, index), round, width)));
            acc = common.mix(acc, common.hash(op(fx(f64, regime, index), round, width)));
            return acc;
        }
    };
    return Body.run;
}

fn rootToward(comptime op: anytype) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const regime = rootRegime(index);
            const toward = fx(f64, regime, index +% 1);
            var acc: u64 = 0;
            acc = common.mix(acc, common.hash(op(fx(f16, regime, index), toward)));
            acc = common.mix(acc, common.hash(op(fx(f32, regime, index), toward)));
            acc = common.mix(acc, common.hash(op(fx(f64, regime, index), toward)));
            return acc;
        }
    };
    return Body.run;
}

// The root `nan` entry point, not the three `zmath.ieee.nan*` spellings: it
// takes the format as a comptime type and dispatches to them itself, so the
// case exercises `zmath.nan` and its typed `f16` / `f32` / `f64` forms.
fn rootNanCase(comptime T: type) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            return common.hash(zmath.nan(T, nan_tags[index % nan_tags.len]));
        }
    };
    return Body.run;
}

// ---------------------------------------------------------------------------
// Case family builders
// ---------------------------------------------------------------------------

fn caseName(
    comptime namespace: []const u8,
    comptime family: []const u8,
    comptime format: []const u8,
    comptime regime: Regime,
) []const u8 {
    return "leaf." ++ namespace ++ "." ++ family ++ "." ++ format ++ "." ++ @tagName(regime);
}

fn famUnary(
    comptime namespace: []const u8,
    comptime family: []const u8,
    comptime format: []const u8,
    comptime T: type,
    comptime op: anytype,
    comptime calls: u32,
    comptime charges: []const common.Charge,
) [3]common.Case {
    return .{
        .{
            .name = caseName(namespace, family, format, .normal),
            .namespace = namespace,
            .invoke = unopCase(T, .normal, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .boundary),
            .namespace = namespace,
            .invoke = unopCase(T, .boundary, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .skewed),
            .namespace = namespace,
            .invoke = unopCase(T, .skewed, op),
            .calls = calls,
            .f32 = charges,
        },
    };
}

fn famBinary(
    comptime namespace: []const u8,
    comptime family: []const u8,
    comptime format: []const u8,
    comptime T: type,
    comptime op: anytype,
    comptime calls: u32,
    comptime charges: []const common.Charge,
) [3]common.Case {
    return .{
        .{
            .name = caseName(namespace, family, format, .normal),
            .namespace = namespace,
            .invoke = binopCase(T, .normal, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .boundary),
            .namespace = namespace,
            .invoke = binopCase(T, .boundary, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .skewed),
            .namespace = namespace,
            .invoke = binopCase(T, .skewed, op),
            .calls = calls,
            .f32 = charges,
        },
    };
}

fn famTernary(
    comptime namespace: []const u8,
    comptime family: []const u8,
    comptime format: []const u8,
    comptime T: type,
    comptime op: anytype,
    comptime calls: u32,
    comptime charges: []const common.Charge,
) [3]common.Case {
    return .{
        .{
            .name = caseName(namespace, family, format, .normal),
            .namespace = namespace,
            .invoke = trinopCase(T, .normal, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .boundary),
            .namespace = namespace,
            .invoke = trinopCase(T, .boundary, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .skewed),
            .namespace = namespace,
            .invoke = trinopCase(T, .skewed, op),
            .calls = calls,
            .f32 = charges,
        },
    };
}

fn famFromfp(
    comptime namespace: []const u8,
    comptime family: []const u8,
    comptime format: []const u8,
    comptime T: type,
    comptime op: anytype,
    comptime calls: u32,
    comptime charges: []const common.Charge,
) [3]common.Case {
    return .{
        .{
            .name = caseName(namespace, family, format, .normal),
            .namespace = namespace,
            .invoke = fromfpCase(T, .normal, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .boundary),
            .namespace = namespace,
            .invoke = fromfpCase(T, .boundary, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .skewed),
            .namespace = namespace,
            .invoke = fromfpCase(T, .skewed, op),
            .calls = calls,
            .f32 = charges,
        },
    };
}

fn famExpo32(
    comptime namespace: []const u8,
    comptime family: []const u8,
    comptime format: []const u8,
    comptime T: type,
    comptime op: anytype,
    comptime calls: u32,
    comptime charges: []const common.Charge,
) [3]common.Case {
    return .{
        .{
            .name = caseName(namespace, family, format, .normal),
            .namespace = namespace,
            .invoke = expo32Case(T, .normal, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .boundary),
            .namespace = namespace,
            .invoke = expo32Case(T, .boundary, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .skewed),
            .namespace = namespace,
            .invoke = expo32Case(T, .skewed, op),
            .calls = calls,
            .f32 = charges,
        },
    };
}

fn famExpo64(
    comptime namespace: []const u8,
    comptime family: []const u8,
    comptime format: []const u8,
    comptime T: type,
    comptime op: anytype,
    comptime calls: u32,
    comptime charges: []const common.Charge,
) [3]common.Case {
    return .{
        .{
            .name = caseName(namespace, family, format, .normal),
            .namespace = namespace,
            .invoke = expo64Case(T, .normal, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .boundary),
            .namespace = namespace,
            .invoke = expo64Case(T, .boundary, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .skewed),
            .namespace = namespace,
            .invoke = expo64Case(T, .skewed, op),
            .calls = calls,
            .f32 = charges,
        },
    };
}

fn famDegree(
    comptime namespace: []const u8,
    comptime family: []const u8,
    comptime format: []const u8,
    comptime T: type,
    comptime op: anytype,
    comptime calls: u32,
    comptime charges: []const common.Charge,
) [3]common.Case {
    return .{
        .{
            .name = caseName(namespace, family, format, .normal),
            .namespace = namespace,
            .invoke = degreeCase(T, .normal, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .boundary),
            .namespace = namespace,
            .invoke = degreeCase(T, .boundary, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .skewed),
            .namespace = namespace,
            .invoke = degreeCase(T, .skewed, op),
            .calls = calls,
            .f32 = charges,
        },
    };
}

fn famToward(
    comptime namespace: []const u8,
    comptime family: []const u8,
    comptime format: []const u8,
    comptime T: type,
    comptime op: anytype,
    comptime calls: u32,
    comptime charges: []const common.Charge,
) [3]common.Case {
    return .{
        .{
            .name = caseName(namespace, family, format, .normal),
            .namespace = namespace,
            .invoke = towardCase(T, .normal, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .boundary),
            .namespace = namespace,
            .invoke = towardCase(T, .boundary, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .skewed),
            .namespace = namespace,
            .invoke = towardCase(T, .skewed, op),
            .calls = calls,
            .f32 = charges,
        },
    };
}

fn famScaleB(
    comptime namespace: []const u8,
    comptime family: []const u8,
    comptime format: []const u8,
    comptime T: type,
    comptime op: anytype,
    comptime calls: u32,
    comptime charges: []const common.Charge,
) [3]common.Case {
    return .{
        .{
            .name = caseName(namespace, family, format, .normal),
            .namespace = namespace,
            .invoke = scaleBCase(T, .normal, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .boundary),
            .namespace = namespace,
            .invoke = scaleBCase(T, .boundary, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .skewed),
            .namespace = namespace,
            .invoke = scaleBCase(T, .skewed, op),
            .calls = calls,
            .f32 = charges,
        },
    };
}

fn famRoundIntegral(
    comptime namespace: []const u8,
    comptime family: []const u8,
    comptime format: []const u8,
    comptime T: type,
    comptime op: anytype,
    comptime calls: u32,
    comptime charges: []const common.Charge,
) [3]common.Case {
    return .{
        .{
            .name = caseName(namespace, family, format, .normal),
            .namespace = namespace,
            .invoke = roundIntegralCase(T, .normal, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .boundary),
            .namespace = namespace,
            .invoke = roundIntegralCase(T, .boundary, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .skewed),
            .namespace = namespace,
            .invoke = roundIntegralCase(T, .skewed, op),
            .calls = calls,
            .f32 = charges,
        },
    };
}

fn famBitsToFloat(
    comptime namespace: []const u8,
    comptime family: []const u8,
    comptime format: []const u8,
    comptime T: type,
    comptime op: anytype,
    comptime calls: u32,
    comptime charges: []const common.Charge,
) [3]common.Case {
    return .{
        .{
            .name = caseName(namespace, family, format, .normal),
            .namespace = namespace,
            .invoke = bitsToFloatCase(T, .normal, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .boundary),
            .namespace = namespace,
            .invoke = bitsToFloatCase(T, .boundary, op),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .skewed),
            .namespace = namespace,
            .invoke = bitsToFloatCase(T, .skewed, op),
            .calls = calls,
            .f32 = charges,
        },
    };
}

fn famNan(
    comptime namespace: []const u8,
    comptime family: []const u8,
    comptime format: []const u8,
    comptime T: type,
    comptime calls: u32,
    comptime charges: []const common.Charge,
) [3]common.Case {
    return .{
        .{
            .name = caseName(namespace, family, format, .normal),
            .namespace = namespace,
            .invoke = nanCase(T, .normal),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .boundary),
            .namespace = namespace,
            .invoke = nanCase(T, .boundary),
            .calls = calls,
            .f32 = charges,
        },
        .{
            .name = caseName(namespace, family, format, .skewed),
            .namespace = namespace,
            .invoke = nanCase(T, .skewed),
            .calls = calls,
            .f32 = charges,
        },
    };
}

// ---------------------------------------------------------------------------
// The measured cases
//
// `calls_default` is the fixed call count for an ordinary kernel and
// `calls_exact` the smaller count reserved for the integer-degree power
// kernels, which run the exact expansion in `scalar_power_exact.zig`.
// There is no adaptive warmup: the count is a property of the case.
// ---------------------------------------------------------------------------

const calls_default: u32 = 32;
const calls_exact: u32 = 8;

// --- zmath.ieee -----------------------------------------------------------
//
// The encoding layer. `toBitsh` and `fromBitsh` exist at binary16 width only,
// so those two families carry a single format. Every other entry point has
// one fixed entry point per format and is timed directly at each.

const ieee_encoding_cases = [_]common.Case{} ++
    famUnary("ieee", "toBits", "h", f16, zmath.ieee.toBitsh, calls_default, &[_]common.Charge{}) ++
    famBitsToFloat("ieee", "fromBits", "h", f16, zmath.ieee.fromBitsh, calls_default, &[_]common.Charge{});

const ieee_classification_cases = [_]common.Case{} ++
    famUnary("ieee", "classify", "h", f16, zmath.ieee.classifyh, calls_default, &[_]common.Charge{}) ++
    famUnary("ieee", "classify", "f", f32, zmath.ieee.classifyf, calls_default, &[_]common.Charge{
        .{ .operation = "classifyf", .count = 1 },
    }) ++
    famUnary("ieee", "classify", "d", f64, zmath.ieee.classifyd, calls_default, &[_]common.Charge{});

const ieee_sign_cases = [_]common.Case{} ++
    famBinary("ieee", "copySign", "h", f16, zmath.ieee.copySignh, calls_default, &[_]common.Charge{}) ++
    famBinary("ieee", "copySign", "f", f32, zmath.ieee.copySignf, calls_default, &[_]common.Charge{
        .{ .operation = "copySignf", .count = 1 },
    }) ++
    famBinary("ieee", "copySign", "d", f64, zmath.ieee.copySignd, calls_default, &[_]common.Charge{});

const ieee_successor_cases = [_]common.Case{} ++
    famBinary("ieee", "nextAfter", "h", f16, zmath.ieee.nextAfterh, calls_default, &[_]common.Charge{}) ++
    famBinary("ieee", "nextAfter", "f", f32, zmath.ieee.nextAfterf, calls_default, &[_]common.Charge{
        .{ .operation = "nextAfterf", .count = 1 },
    }) ++
    famBinary("ieee", "nextAfter", "d", f64, zmath.ieee.nextAfterd, calls_default, &[_]common.Charge{}) ++
    famUnary("ieee", "nextUp", "h", f16, zmath.ieee.nextUph, calls_default, &[_]common.Charge{}) ++
    famUnary("ieee", "nextUp", "f", f32, zmath.ieee.nextUpf, calls_default, &[_]common.Charge{
        .{ .operation = "nextUpf", .count = 1 },
    }) ++
    famUnary("ieee", "nextUp", "d", f64, zmath.ieee.nextUpd, calls_default, &[_]common.Charge{}) ++
    famUnary("ieee", "nextDown", "h", f16, zmath.ieee.nextDownh, calls_default, &[_]common.Charge{}) ++
    famUnary("ieee", "nextDown", "f", f32, zmath.ieee.nextDownf, calls_default, &[_]common.Charge{
        .{ .operation = "nextDownf", .count = 1 },
    }) ++
    famUnary("ieee", "nextDown", "d", f64, zmath.ieee.nextDownd, calls_default, &[_]common.Charge{}) ++
    famToward("ieee", "nextToward", "h", f16, zmath.ieee.nextTowardh, calls_default, &[_]common.Charge{}) ++
    famToward("ieee", "nextToward", "f", f32, zmath.ieee.nextTowardf, calls_default, &[_]common.Charge{
        .{ .operation = "nextTowardf", .count = 1 },
    }) ++
    famToward("ieee", "nextToward", "d", f64, zmath.ieee.nextTowardd, calls_default, &[_]common.Charge{});

const ieee_order_cases = [_]common.Case{} ++
    famBinary("ieee", "totalOrder", "h", f16, zmath.ieee.totalOrderh, calls_default, &[_]common.Charge{}) ++
    famBinary("ieee", "totalOrder", "f", f32, zmath.ieee.totalOrderf, calls_default, &[_]common.Charge{
        .{ .operation = "totalOrderf", .count = 1 },
    }) ++
    famBinary("ieee", "totalOrder", "d", f64, zmath.ieee.totalOrderd, calls_default, &[_]common.Charge{}) ++
    famBinary("ieee", "totalOrderMag", "h", f16, zmath.ieee.totalOrderMagh, calls_default, &[_]common.Charge{}) ++
    famBinary("ieee", "totalOrderMag", "f", f32, zmath.ieee.totalOrderMagf, calls_default, &[_]common.Charge{
        .{ .operation = "totalOrderMagf", .count = 1 },
    }) ++
    famBinary("ieee", "totalOrderMag", "d", f64, zmath.ieee.totalOrderMagd, calls_default, &[_]common.Charge{});

const ieee_nan_cases = [_]common.Case{} ++
    famNan("ieee", "nan", "h", f16, calls_default, &[_]common.Charge{}) ++
    famNan("ieee", "nan", "f", f32, calls_default, &[_]common.Charge{
        .{ .operation = "nanf", .count = 1 },
    }) ++
    famNan("ieee", "nan", "d", f64, calls_default, &[_]common.Charge{}) ++
    famUnary("ieee", "canonicalize", "h", f16, zmath.ieee.canonicalizeh, calls_default, &[_]common.Charge{}) ++
    famUnary("ieee", "canonicalize", "f", f32, zmath.ieee.canonicalizef, calls_default, &[_]common.Charge{
        .{ .operation = "canonicalizef", .count = 1 },
    }) ++
    famUnary("ieee", "canonicalize", "d", f64, zmath.ieee.canonicalized, calls_default, &[_]common.Charge{}) ++
    famUnary("ieee", "getPayload", "h", f16, zmath.ieee.getPayloadh, calls_default, &[_]common.Charge{}) ++
    famUnary("ieee", "getPayload", "f", f32, zmath.ieee.getPayloadf, calls_default, &[_]common.Charge{
        .{ .operation = "getPayloadf", .count = 1 },
    }) ++
    famUnary("ieee", "getPayload", "d", f64, zmath.ieee.getPayloadd, calls_default, &[_]common.Charge{}) ++
    famUnary("ieee", "setPayload", "h", f16, zmath.ieee.setPayloadh, calls_default, &[_]common.Charge{}) ++
    famUnary("ieee", "setPayload", "f", f32, zmath.ieee.setPayloadf, calls_default, &[_]common.Charge{
        .{ .operation = "setPayloadf", .count = 1 },
    }) ++
    famUnary("ieee", "setPayload", "d", f64, zmath.ieee.setPayloadd, calls_default, &[_]common.Charge{}) ++
    famUnary("ieee", "setPayloadSig", "h", f16, zmath.ieee.setPayloadSigh, calls_default, &[_]common.Charge{}) ++
    famUnary("ieee", "setPayloadSig", "f", f32, zmath.ieee.setPayloadSigf, calls_default, &[_]common.Charge{
        .{ .operation = "setPayloadSigf", .count = 1 },
    }) ++
    famUnary("ieee", "setPayloadSig", "d", f64, zmath.ieee.setPayloadSigd, calls_default, &[_]common.Charge{});

const ieee_rounding_cases = [_]common.Case{} ++
    famScaleB("ieee", "scaleB", "h", f16, zmath.ieee.scaleBh, calls_default, &[_]common.Charge{}) ++
    famScaleB("ieee", "scaleB", "f", f32, zmath.ieee.scaleBf, calls_default, &[_]common.Charge{
        .{ .operation = "scaleBf", .count = 1 },
    }) ++
    famScaleB("ieee", "scaleB", "d", f64, zmath.ieee.scaleBd, calls_default, &[_]common.Charge{}) ++
    famRoundIntegral("ieee", "roundIntegral", "h", f16, zmath.ieee.roundIntegralh, calls_default, &[_]common.Charge{}) ++
    famRoundIntegral("ieee", "roundIntegral", "f", f32, zmath.ieee.roundIntegralf, calls_default, &[_]common.Charge{
        .{ .operation = "roundIntegralf", .count = 1 },
    }) ++
    famRoundIntegral("ieee", "roundIntegral", "d", f64, zmath.ieee.roundIntegrald, calls_default, &[_]common.Charge{});

const ieee_cases = ieee_encoding_cases ++
    ieee_classification_cases ++
    ieee_sign_cases ++
    ieee_successor_cases ++
    ieee_order_cases ++
    ieee_nan_cases ++
    ieee_rounding_cases;

// --- zmath.scalar: integral rounding, conversion, remainder, decomposition --

// The `round_modes` table above is handed only to `scaleB` and
// `roundIntegral`, the two entry points that take a mode argument. `ceil`,
// `floor`, `trunc`, `nearbyint`, `rint`, `round` and `roundeven` take no
// mode: `scalar_rounding.zig` fixes each direction in code, never reads the
// ambient floating-point rounding mode, and resolves a tie to even for
// `nearbyint`, `rint` and `roundeven`. This round therefore measures their
// nearest-even kernels; it is not a mode-sensitive route.
const scalar_rounding_cases = [_]common.Case{} ++
    famUnary("scalar", "ceil", "h", f16, zmath.scalar.ceilh, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "ceil", "f", f32, zmath.scalar.ceilf, calls_default, &[_]common.Charge{
        .{ .operation = "ceilf", .count = 1 },
    }) ++
    famUnary("scalar", "ceil", "d", f64, zmath.scalar.ceild, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "floor", "h", f16, zmath.scalar.floorh, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "floor", "f", f32, zmath.scalar.floorf, calls_default, &[_]common.Charge{
        .{ .operation = "floorf", .count = 1 },
    }) ++
    famUnary("scalar", "floor", "d", f64, zmath.scalar.floord, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "trunc", "h", f16, zmath.scalar.trunch, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "trunc", "f", f32, zmath.scalar.truncf, calls_default, &[_]common.Charge{
        .{ .operation = "truncf", .count = 1 },
    }) ++
    famUnary("scalar", "trunc", "d", f64, zmath.scalar.truncd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "nearbyint", "h", f16, zmath.scalar.nearbyinth, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "nearbyint", "f", f32, zmath.scalar.nearbyintf, calls_default, &[_]common.Charge{
        .{ .operation = "nearbyintf", .count = 1 },
    }) ++
    famUnary("scalar", "nearbyint", "d", f64, zmath.scalar.nearbyintd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "rint", "h", f16, zmath.scalar.rinth, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "rint", "f", f32, zmath.scalar.rintf, calls_default, &[_]common.Charge{
        // `rintf` forwards to `nearbyintf`, which is the only accepted binary32
        // kernel it runs, so the alias charges `nearbyintf` once and opens no
        // key of its own.
        .{ .operation = "nearbyintf", .count = 1 },
    }) ++
    famUnary("scalar", "rint", "d", f64, zmath.scalar.rintd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "round", "h", f16, zmath.scalar.roundh, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "round", "f", f32, zmath.scalar.roundf, calls_default, &[_]common.Charge{
        .{ .operation = "roundf", .count = 1 },
    }) ++
    famUnary("scalar", "round", "d", f64, zmath.scalar.roundd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "roundeven", "h", f16, zmath.scalar.roundevenh, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "roundeven", "f", f32, zmath.scalar.roundevenf, calls_default, &[_]common.Charge{
        .{ .operation = "nearbyintf", .count = 1 },
    }) ++
    famUnary("scalar", "roundeven", "d", f64, zmath.scalar.roundevend, calls_default, &[_]common.Charge{});

const scalar_integer_rounding_cases = [_]common.Case{} ++
    famUnary("scalar", "lrint", "h", f16, zmath.scalar.lrinth, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "lrint", "f", f32, zmath.scalar.lrintf, calls_default, &[_]common.Charge{
        .{ .operation = "lrintf", .count = 1 },
    }) ++
    famUnary("scalar", "lrint", "d", f64, zmath.scalar.lrintd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "llrint", "h", f16, zmath.scalar.llrinth, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "llrint", "f", f32, zmath.scalar.llrintf, calls_default, &[_]common.Charge{
        .{ .operation = "llrintf", .count = 1 },
    }) ++
    famUnary("scalar", "llrint", "d", f64, zmath.scalar.llrintd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "lround", "h", f16, zmath.scalar.lroundh, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "lround", "f", f32, zmath.scalar.lroundf, calls_default, &[_]common.Charge{
        .{ .operation = "lroundf", .count = 1 },
    }) ++
    famUnary("scalar", "lround", "d", f64, zmath.scalar.lroundd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "llround", "h", f16, zmath.scalar.llroundh, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "llround", "f", f32, zmath.scalar.llroundf, calls_default, &[_]common.Charge{
        .{ .operation = "llroundf", .count = 1 },
    }) ++
    famUnary("scalar", "llround", "d", f64, zmath.scalar.llroundd, calls_default, &[_]common.Charge{});

const scalar_fromfp_cases = [_]common.Case{} ++
    famFromfp("scalar", "fromfp", "h", f16, zmath.scalar.fromfph, calls_default, &[_]common.Charge{}) ++
    famFromfp("scalar", "fromfp", "f", f32, zmath.scalar.fromfpf, calls_default, &[_]common.Charge{
        .{ .operation = "fromfpf", .count = 1 },
    }) ++
    famFromfp("scalar", "fromfp", "d", f64, zmath.scalar.fromfpd, calls_default, &[_]common.Charge{}) ++
    famFromfp("scalar", "ufromfp", "h", f16, zmath.scalar.ufromfph, calls_default, &[_]common.Charge{}) ++
    famFromfp("scalar", "ufromfp", "f", f32, zmath.scalar.ufromfpf, calls_default, &[_]common.Charge{
        .{ .operation = "ufromfpf", .count = 1 },
    }) ++
    famFromfp("scalar", "ufromfp", "d", f64, zmath.scalar.ufromfpd, calls_default, &[_]common.Charge{}) ++
    famFromfp("scalar", "fromfpx", "h", f16, zmath.scalar.fromfpxh, calls_default, &[_]common.Charge{}) ++
    famFromfp("scalar", "fromfpx", "f", f32, zmath.scalar.fromfpxf, calls_default, &[_]common.Charge{
        .{ .operation = "fromfpxf", .count = 1 },
    }) ++
    famFromfp("scalar", "fromfpx", "d", f64, zmath.scalar.fromfpxd, calls_default, &[_]common.Charge{}) ++
    famFromfp("scalar", "ufromfpx", "h", f16, zmath.scalar.ufromfpxh, calls_default, &[_]common.Charge{}) ++
    famFromfp("scalar", "ufromfpx", "f", f32, zmath.scalar.ufromfpxf, calls_default, &[_]common.Charge{
        .{ .operation = "ufromfpxf", .count = 1 },
    }) ++
    famFromfp("scalar", "ufromfpx", "d", f64, zmath.scalar.ufromfpxd, calls_default, &[_]common.Charge{});

const scalar_remainder_cases = [_]common.Case{} ++
    famBinary("scalar", "fmod", "h", f16, zmath.scalar.fmodh, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fmod", "f", f32, zmath.scalar.fmodf, calls_default, &[_]common.Charge{
        .{ .operation = "fmodf", .count = 1 },
    }) ++
    famBinary("scalar", "fmod", "d", f64, zmath.scalar.fmodd, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "remainder", "h", f16, zmath.scalar.remainderh, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "remainder", "f", f32, zmath.scalar.remainderf, calls_default, &[_]common.Charge{
        .{ .operation = "remainderf", .count = 1 },
    }) ++
    famBinary("scalar", "remainder", "d", f64, zmath.scalar.remainderd, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "remquo", "h", f16, zmath.scalar.remquoh, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "remquo", "f", f32, zmath.scalar.remquof, calls_default, &[_]common.Charge{
        .{ .operation = "remquof", .count = 1 },
    }) ++
    famBinary("scalar", "remquo", "d", f64, zmath.scalar.remquod, calls_default, &[_]common.Charge{});

const scalar_decompose_cases = [_]common.Case{} ++
    famUnary("scalar", "frexp", "h", f16, zmath.scalar.frexph, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "frexp", "f", f32, zmath.scalar.frexpf, calls_default, &[_]common.Charge{
        .{ .operation = "frexpf", .count = 1 },
    }) ++
    famUnary("scalar", "frexp", "d", f64, zmath.scalar.frexpd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "modf", "h", f16, zmath.scalar.modfh, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "modf", "f", f32, zmath.scalar.modff, calls_default, &[_]common.Charge{
        .{ .operation = "modff", .count = 1 },
    }) ++
    famUnary("scalar", "modf", "d", f64, zmath.scalar.modfd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "ilogb", "h", f16, zmath.scalar.ilogbh, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "ilogb", "f", f32, zmath.scalar.ilogbf, calls_default, &[_]common.Charge{
        .{ .operation = "ilogbf", .count = 1 },
    }) ++
    famUnary("scalar", "ilogb", "d", f64, zmath.scalar.ilogbd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "llogb", "h", f16, zmath.scalar.llogbh, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "llogb", "f", f32, zmath.scalar.llogbf, calls_default, &[_]common.Charge{
        .{ .operation = "llogbf", .count = 1 },
    }) ++
    famUnary("scalar", "llogb", "d", f64, zmath.scalar.llogbd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "logb", "h", f16, zmath.scalar.logbh, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "logb", "f", f32, zmath.scalar.logbf, calls_default, &[_]common.Charge{
        .{ .operation = "logbf", .count = 1 },
    }) ++
    famUnary("scalar", "logb", "d", f64, zmath.scalar.logbd, calls_default, &[_]common.Charge{});

const scalar_scaling_cases = [_]common.Case{} ++
    famExpo32("scalar", "ldexp", "h", f16, zmath.scalar.ldexph, calls_default, &[_]common.Charge{}) ++
    famExpo32("scalar", "ldexp", "f", f32, zmath.scalar.ldexpf, calls_default, &[_]common.Charge{
        .{ .operation = "ldexpf", .count = 1 },
    }) ++
    famExpo32("scalar", "ldexp", "d", f64, zmath.scalar.ldexpd, calls_default, &[_]common.Charge{}) ++
    famExpo32("scalar", "scalbn", "h", f16, zmath.scalar.scalbnh, calls_default, &[_]common.Charge{}) ++
    famExpo32("scalar", "scalbn", "f", f32, zmath.scalar.scalbnf, calls_default, &[_]common.Charge{
        .{ .operation = "scalbnf", .count = 1 },
    }) ++
    famExpo32("scalar", "scalbn", "d", f64, zmath.scalar.scalbnd, calls_default, &[_]common.Charge{}) ++
    famExpo64("scalar", "scalbln", "h", f16, zmath.scalar.scalblnh, calls_default, &[_]common.Charge{}) ++
    famExpo64("scalar", "scalbln", "f", f32, zmath.scalar.scalblnf, calls_default, &[_]common.Charge{
        .{ .operation = "scalblnf", .count = 1 },
    }) ++
    famExpo64("scalar", "scalbln", "d", f64, zmath.scalar.scalblnd, calls_default, &[_]common.Charge{});

// --- zmath.scalar: extrema, gamma, angular, integer-degree powers ----------

// The eleven extrema rules are separate kernels with separate internal
// helpers, so each is timed directly even where two rules agree on all three
// supported formats.
const scalar_extrema_cases = [_]common.Case{} ++
    famBinary("scalar", "fdim", "h", f16, zmath.scalar.fdimh, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fdim", "f", f32, zmath.scalar.fdimf, calls_default, &[_]common.Charge{
        .{ .operation = "fdimf", .count = 1 },
    }) ++
    famBinary("scalar", "fdim", "d", f64, zmath.scalar.fdimd, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fmax", "h", f16, zmath.scalar.fmaxh, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fmax", "f", f32, zmath.scalar.fmaxf, calls_default, &[_]common.Charge{
        .{ .operation = "fmaxf", .count = 1 },
    }) ++
    famBinary("scalar", "fmax", "d", f64, zmath.scalar.fmaxd, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fmin", "h", f16, zmath.scalar.fminh, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fmin", "f", f32, zmath.scalar.fminf, calls_default, &[_]common.Charge{
        .{ .operation = "fminf", .count = 1 },
    }) ++
    famBinary("scalar", "fmin", "d", f64, zmath.scalar.fmind, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fmaximum", "h", f16, zmath.scalar.fmaximumh, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fmaximum", "f", f32, zmath.scalar.fmaximumf, calls_default, &[_]common.Charge{
        .{ .operation = "fmaximumf", .count = 1 },
    }) ++
    famBinary("scalar", "fmaximum", "d", f64, zmath.scalar.fmaximumd, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fminimum", "h", f16, zmath.scalar.fminimumh, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fminimum", "f", f32, zmath.scalar.fminimumf, calls_default, &[_]common.Charge{
        .{ .operation = "fminimumf", .count = 1 },
    }) ++
    famBinary("scalar", "fminimum", "d", f64, zmath.scalar.fminimumd, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fmaximum_mag", "h", f16, zmath.scalar.fmaximum_magh, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fmaximum_mag", "f", f32, zmath.scalar.fmaximum_magf, calls_default, &[_]common.Charge{
        .{ .operation = "fmaximum_magf", .count = 1 },
    }) ++
    famBinary("scalar", "fmaximum_mag", "d", f64, zmath.scalar.fmaximum_magd, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fminimum_mag", "h", f16, zmath.scalar.fminimum_magh, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fminimum_mag", "f", f32, zmath.scalar.fminimum_magf, calls_default, &[_]common.Charge{
        .{ .operation = "fminimum_magf", .count = 1 },
    }) ++
    famBinary("scalar", "fminimum_mag", "d", f64, zmath.scalar.fminimum_magd, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fmaximum_num", "h", f16, zmath.scalar.fmaximum_numh, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fmaximum_num", "f", f32, zmath.scalar.fmaximum_numf, calls_default, &[_]common.Charge{
        .{ .operation = "fmaximum_numf", .count = 1 },
    }) ++
    famBinary("scalar", "fmaximum_num", "d", f64, zmath.scalar.fmaximum_numd, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fminimum_num", "h", f16, zmath.scalar.fminimum_numh, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fminimum_num", "f", f32, zmath.scalar.fminimum_numf, calls_default, &[_]common.Charge{
        .{ .operation = "fminimum_numf", .count = 1 },
    }) ++
    famBinary("scalar", "fminimum_num", "d", f64, zmath.scalar.fminimum_numd, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fmaximum_mag_num", "h", f16, zmath.scalar.fmaximum_mag_numh, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fmaximum_mag_num", "f", f32, zmath.scalar.fmaximum_mag_numf, calls_default, &[_]common.Charge{
        .{ .operation = "fmaximum_mag_numf", .count = 1 },
    }) ++
    famBinary("scalar", "fmaximum_mag_num", "d", f64, zmath.scalar.fmaximum_mag_numd, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fminimum_mag_num", "h", f16, zmath.scalar.fminimum_mag_numh, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "fminimum_mag_num", "f", f32, zmath.scalar.fminimum_mag_numf, calls_default, &[_]common.Charge{
        .{ .operation = "fminimum_mag_numf", .count = 1 },
    }) ++
    famBinary("scalar", "fminimum_mag_num", "d", f64, zmath.scalar.fminimum_mag_numd, calls_default, &[_]common.Charge{});

const scalar_angular_cases = [_]common.Case{} ++
    famUnary("scalar", "lgamma", "h", f16, zmath.scalar.lgammah, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "lgamma", "f", f32, zmath.scalar.lgammaf, calls_default, &[_]common.Charge{
        .{ .operation = "lgammaf", .count = 1 },
        // `lgammaf` is the body of the `zmath_core_lgammaf` seam, whose
        // overflow branch spends one `zmath_fmaf` (coremath_lgammaf.c 171).
        .{ .operation = "fmaf", .count = 1 },
    }) ++
    famUnary("scalar", "lgamma", "d", f64, zmath.scalar.lgammad, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "atan2", "h", f16, zmath.scalar.atan2h, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "atan2", "f", f32, zmath.scalar.atan2f, calls_default, &[_]common.Charge{
        .{ .operation = "atan2f", .count = 1 },
    }) ++
    famBinary("scalar", "atan2", "d", f64, zmath.scalar.atan2d, calls_default, &[_]common.Charge{}) ++
    // `asinpih` calls the `zmath_core_asinpih_bits` seam, where each of the two
    // polynomial branches spends three `zmath_fmaf` evaluations
    // (coremath_pi_inverseh.c 110-112, 119-121).
    famUnary("scalar", "asinpi", "h", f16, zmath.scalar.asinpih, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 3 },
    }) ++
    famUnary("scalar", "asinpi", "f", f32, zmath.scalar.asinpif, calls_default, &[_]common.Charge{
        .{ .operation = "asinpif", .count = 1 },
    }) ++
    famUnary("scalar", "asinpi", "d", f64, zmath.scalar.asinpid, calls_default, &[_]common.Charge{}) ++
    // `acospih` calls the `zmath_core_acospih_bits` seam, where each of the
    // three polynomial branches spends four `zmath_fmaf` evaluations
    // (coremath_pi_inverseh.c 224-227, 233-236, 244-247).
    famUnary("scalar", "acospi", "h", f16, zmath.scalar.acospih, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 4 },
    }) ++
    famUnary("scalar", "acospi", "f", f32, zmath.scalar.acospif, calls_default, &[_]common.Charge{
        .{ .operation = "acospif", .count = 1 },
    }) ++
    famUnary("scalar", "acospi", "d", f64, zmath.scalar.acospid, calls_default, &[_]common.Charge{}) ++
    // `atanpih` calls the `zmath_core_atanpih_bits` seam, whose widest branch
    // spends four `zmath_fmaf` evaluations (coremath_pi_inverseh.c 395-398).
    famUnary("scalar", "atanpi", "h", f16, zmath.scalar.atanpih, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 4 },
    }) ++
    famUnary("scalar", "atanpi", "f", f32, zmath.scalar.atanpif, calls_default, &[_]common.Charge{
        .{ .operation = "atanpif", .count = 1 },
    }) ++
    famUnary("scalar", "atanpi", "d", f64, zmath.scalar.atanpid, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "atan2pi", "h", f16, zmath.scalar.atan2pih, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "atan2pi", "f", f32, zmath.scalar.atan2pif, calls_default, &[_]common.Charge{
        .{ .operation = "atan2pif", .count = 1 },
    }) ++
    famBinary("scalar", "atan2pi", "d", f64, zmath.scalar.atan2pid, calls_default, &[_]common.Charge{});

const scalar_power_cases = [_]common.Case{} ++
    famBinary("scalar", "powr", "h", f16, zmath.scalar.powrh, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "powr", "f", f32, zmath.scalar.powrf, calls_default, &[_]common.Charge{
        // `powrf` computes `exp(y * log(x))` through `directPow`, which is the
        // public binary32 `powf`, and that is the only accepted kernel it runs,
        // so the alias charges `powf` once and opens no key of its own. The
        // binary16 `powrh` takes the same route to `powh` and stays unchanged.
        .{ .operation = "powf", .count = 1 },
    }) ++
    famBinary("scalar", "powr", "d", f64, zmath.scalar.powrd, calls_default, &[_]common.Charge{}) ++
    famDegree("scalar", "pown", "h", f16, zmath.scalar.pownh, calls_exact, &[_]common.Charge{}) ++
    famDegree("scalar", "pown", "f", f32, zmath.scalar.pownf, calls_exact, &[_]common.Charge{
        .{ .operation = "pownf", .count = 1 },
    }) ++
    famDegree("scalar", "pown", "d", f64, zmath.scalar.pownd, calls_exact, &[_]common.Charge{}) ++
    famDegree("scalar", "compoundn", "h", f16, zmath.scalar.compoundnh, calls_exact, &[_]common.Charge{}) ++
    famDegree("scalar", "compoundn", "f", f32, zmath.scalar.compoundnf, calls_exact, &[_]common.Charge{
        .{ .operation = "compoundnf", .count = 1 },
    }) ++
    famDegree("scalar", "compoundn", "d", f64, zmath.scalar.compoundnd, calls_exact, &[_]common.Charge{}) ++
    famDegree("scalar", "rootn", "h", f16, zmath.scalar.rootnh, calls_exact, &[_]common.Charge{}) ++
    famDegree("scalar", "rootn", "f", f32, zmath.scalar.rootnf, calls_exact, &[_]common.Charge{
        .{ .operation = "rootnf", .count = 1 },
    }) ++
    famDegree("scalar", "rootn", "d", f64, zmath.scalar.rootnd, calls_exact, &[_]common.Charge{});

// --- zmath.scalar: exponentials, logarithms, absolute value ----------------

const scalar_exponential_cases = [_]common.Case{} ++
    famUnary("scalar", "abs", "h", f16, zmath.scalar.absh, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "abs", "f", f32, zmath.scalar.absf, calls_default, &[_]common.Charge{
        .{ .operation = "absf", .count = 1 },
    }) ++
    famUnary("scalar", "abs", "d", f64, zmath.scalar.absd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "exp", "h", f16, zmath.scalar.exph, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "exp", "f", f32, zmath.scalar.expf, calls_default, &[_]common.Charge{
        .{ .operation = "expf", .count = 1 },
    }) ++
    famUnary("scalar", "exp", "d", f64, zmath.scalar.expd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "exp2", "h", f16, zmath.scalar.exp2h, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "exp2", "f", f32, zmath.scalar.exp2f, calls_default, &[_]common.Charge{
        .{ .operation = "exp2f", .count = 1 },
    }) ++
    famUnary("scalar", "exp2", "d", f64, zmath.scalar.exp2d, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "exp10", "h", f16, zmath.scalar.exp10h, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "exp10", "f", f32, zmath.scalar.exp10f, calls_default, &[_]common.Charge{
        .{ .operation = "exp10f", .count = 1 },
    }) ++
    famUnary("scalar", "exp10", "d", f64, zmath.scalar.exp10d, calls_default, &[_]common.Charge{}) ++
    // `expm1h` rounds in binary32 through `fma_impl.fma`: the small-argument
    // branch spends two evaluations, one for the coefficient and one for the
    // final correction, and the table branch spends one. Two is the per-invoke
    // upper bound. `expm1f` itself calls no binary32 fused multiply-add, so
    // the binary32 `expm1` case is unchanged.
    famUnary("scalar", "expm1", "h", f16, zmath.scalar.expm1h, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 2 },
    }) ++
    famUnary("scalar", "expm1", "f", f32, zmath.scalar.expm1f, calls_default, &[_]common.Charge{
        .{ .operation = "expm1f", .count = 1 },
    }) ++
    famUnary("scalar", "expm1", "d", f64, zmath.scalar.expm1d, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "exp2m1", "h", f16, zmath.scalar.exp2m1h, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 2 },
    }) ++
    famUnary("scalar", "exp2m1", "f", f32, zmath.scalar.exp2m1f, calls_default, &[_]common.Charge{
        .{ .operation = "exp2m1f", .count = 1 },
    }) ++
    famUnary("scalar", "exp2m1", "d", f64, zmath.scalar.exp2m1d, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "exp10m1", "h", f16, zmath.scalar.exp10m1h, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 2 },
    }) ++
    famUnary("scalar", "exp10m1", "f", f32, zmath.scalar.exp10m1f, calls_default, &[_]common.Charge{
        .{ .operation = "exp10m1f", .count = 1 },
    }) ++
    famUnary("scalar", "exp10m1", "d", f64, zmath.scalar.exp10m1d, calls_default, &[_]common.Charge{});

const scalar_logarithm_cases = [_]common.Case{} ++
    famUnary("scalar", "log", "h", f16, zmath.scalar.logh, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "log", "f", f32, zmath.scalar.logf, calls_default, &[_]common.Charge{
        .{ .operation = "logf", .count = 1 },
    }) ++
    famUnary("scalar", "log", "d", f64, zmath.scalar.logd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "log2", "h", f16, zmath.scalar.log2h, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "log2", "f", f32, zmath.scalar.log2f, calls_default, &[_]common.Charge{
        .{ .operation = "log2f", .count = 1 },
    }) ++
    famUnary("scalar", "log2", "d", f64, zmath.scalar.log2d, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "log10", "h", f16, zmath.scalar.log10h, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "log10", "f", f32, zmath.scalar.log10f, calls_default, &[_]common.Charge{
        .{ .operation = "log10f", .count = 1 },
    }) ++
    famUnary("scalar", "log10", "d", f64, zmath.scalar.log10d, calls_default, &[_]common.Charge{}) ++
    // `logp1h/f/d` forward to the `log1p` kernels unchanged, so the accepted
    // binary32 leaf of a `logp1f` call is `log1pf`. The alias shares that one
    // ledger key with the `log1p` case instead of opening a second one.
    //
    // `log1ph` evaluates its whole small-argument polynomial in binary32
    // through `log1phSmall`, which is three `fma_impl.fma` evaluations, and
    // its table path adds one reduction `fma` before that polynomial: four is
    // the per-invoke upper bound. `log1pf` widens to binary64 and reaches no
    // binary32 fused multiply-add.
    famUnary("scalar", "log1p", "h", f16, zmath.scalar.log1ph, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 4 },
    }) ++
    famUnary("scalar", "log1p", "f", f32, zmath.scalar.log1pf, calls_default, &[_]common.Charge{
        .{ .operation = "log1pf", .count = 1 },
    }) ++
    famUnary("scalar", "log1p", "d", f64, zmath.scalar.log1pd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "logp1", "h", f16, zmath.scalar.logp1h, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 4 },
    }) ++
    famUnary("scalar", "logp1", "f", f32, zmath.scalar.logp1f, calls_default, &[_]common.Charge{
        .{ .operation = "log1pf", .count = 1 },
    }) ++
    famUnary("scalar", "logp1", "d", f64, zmath.scalar.logp1d, calls_default, &[_]common.Charge{}) ++
    // `log2p1h` calls the `zmath_core_log2p1h_bits` seam, whose body spends one
    // reduction `zmath_fmaf` (coremath_log2p1h.c 233) plus the three in
    // `log2p1_small` (166-168).
    famUnary("scalar", "log2p1", "h", f16, zmath.scalar.log2p1h, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 4 },
    }) ++
    famUnary("scalar", "log2p1", "f", f32, zmath.scalar.log2p1f, calls_default, &[_]common.Charge{
        .{ .operation = "log2p1f", .count = 1 },
    }) ++
    famUnary("scalar", "log2p1", "d", f64, zmath.scalar.log2p1d, calls_default, &[_]common.Charge{}) ++
    // `log10p1h` calls the `zmath_core_log10p1h_bits` seam, whose body spends
    // one reduction `zmath_fmaf` (coremath_log10p1h.c 229) plus the three in
    // `log10p1_small` (165-167).
    famUnary("scalar", "log10p1", "h", f16, zmath.scalar.log10p1h, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 4 },
    }) ++
    famUnary("scalar", "log10p1", "f", f32, zmath.scalar.log10p1f, calls_default, &[_]common.Charge{
        .{ .operation = "log10p1f", .count = 1 },
    }) ++
    famUnary("scalar", "log10p1", "d", f64, zmath.scalar.log10p1d, calls_default, &[_]common.Charge{});

// --- zmath.scalar: trigonometry and its hyperbolic and pi-scaled relatives -
//
// The binary16 trigonometric entries are `scalar.sinh`, `scalar.cosh` and
// `scalar.tanh`; the binary16 hyperbolic entries are `scalar.sinhh`,
// `scalar.coshh` and `scalar.tanhh`. The names differ only in the doubled
// trailing letter, so each family names the symbol it calls.
//
// The binary16 sine and cosine kernels each finish their table evaluation
// with one binary32 `fma_impl.fma` evaluation, and the binary16 tangent
// spends two, one for the sine numerator and one for the cosine denominator.
// `scalar.tanhh` is a pure table lookup and reaches no binary32 kernel.
// On the binary32 side `asinf`, `atanf`, `tanf`, `tanhf` and `cosf` each
// reach the same engine once, on a single branch.
// The `cospi` pair reaches the same engine from inside its C seam rather than
// from Zig; the charges on the two `cospi` cases below carry the counts.

const scalar_trigonometric_cases = [_]common.Case{} ++
    famUnary("scalar", "sin", "h", f16, zmath.scalar.sinh, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 1 },
    }) ++
    famUnary("scalar", "sin", "f", f32, zmath.scalar.sinf, calls_default, &[_]common.Charge{
        .{ .operation = "sinf", .count = 1 },
    }) ++
    famUnary("scalar", "sin", "d", f64, zmath.scalar.sind, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "cos", "h", f16, zmath.scalar.cosh, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 1 },
    }) ++
    famUnary("scalar", "cos", "f", f32, zmath.scalar.cosf, calls_default, &[_]common.Charge{
        .{ .operation = "cosf", .count = 1 },
        .{ .operation = "fmaf", .count = 1 },
    }) ++
    famUnary("scalar", "cos", "d", f64, zmath.scalar.cosd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "tan", "h", f16, zmath.scalar.tanh, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 2 },
    }) ++
    famUnary("scalar", "tan", "f", f32, zmath.scalar.tanf, calls_default, &[_]common.Charge{
        .{ .operation = "tanf", .count = 1 },
        .{ .operation = "fmaf", .count = 1 },
    }) ++
    famUnary("scalar", "tan", "d", f64, zmath.scalar.tand, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "sinpi", "h", f16, zmath.scalar.sinpih, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 1 },
    }) ++
    famUnary("scalar", "sinpi", "f", f32, zmath.scalar.sinpif, calls_default, &[_]common.Charge{
        .{ .operation = "sinpif", .count = 1 },
    }) ++
    famUnary("scalar", "sinpi", "d", f64, zmath.scalar.sinpid, calls_default, &[_]common.Charge{}) ++
    // `cospih` hands its encoding to the `zmath_core_cospih_bits` seam, which
    // spends one `zmath_fmaf` on its saturation branch (coremath_cospih.c
    // 1777) and one on its table branch (1783); `cr_cospif` spends one the
    // same way (coremath_cospif.c 85, 87). Both key `fmaf`.
    famUnary("scalar", "cospi", "h", f16, zmath.scalar.cospih, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 1 },
    }) ++
    famUnary("scalar", "cospi", "f", f32, zmath.scalar.cospif, calls_default, &[_]common.Charge{
        .{ .operation = "cospif", .count = 1 },
        .{ .operation = "fmaf", .count = 1 },
    }) ++
    famUnary("scalar", "cospi", "d", f64, zmath.scalar.cospid, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "tanpi", "h", f16, zmath.scalar.tanpih, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 2 },
    }) ++
    famUnary("scalar", "tanpi", "f", f32, zmath.scalar.tanpif, calls_default, &[_]common.Charge{
        .{ .operation = "tanpif", .count = 1 },
    }) ++
    famUnary("scalar", "tanpi", "d", f64, zmath.scalar.tanpid, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "sinh", "h", f16, zmath.scalar.sinhh, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 1 },
    }) ++
    famUnary("scalar", "sinh", "f", f32, zmath.scalar.sinhf, calls_default, &[_]common.Charge{
        .{ .operation = "sinhf", .count = 1 },
    }) ++
    famUnary("scalar", "sinh", "d", f64, zmath.scalar.sinhd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "cosh", "h", f16, zmath.scalar.coshh, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 1 },
    }) ++
    famUnary("scalar", "cosh", "f", f32, zmath.scalar.coshf, calls_default, &[_]common.Charge{
        .{ .operation = "coshf", .count = 1 },
    }) ++
    famUnary("scalar", "cosh", "d", f64, zmath.scalar.coshd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "tanh", "h", f16, zmath.scalar.tanhh, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "tanh", "f", f32, zmath.scalar.tanhf, calls_default, &[_]common.Charge{
        .{ .operation = "tanhf", .count = 1 },
        .{ .operation = "fmaf", .count = 1 },
    }) ++
    famUnary("scalar", "tanh", "d", f64, zmath.scalar.tanhd, calls_default, &[_]common.Charge{});

const scalar_inverse_cases = [_]common.Case{} ++
    famUnary("scalar", "asin", "h", f16, zmath.scalar.asinh, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "asin", "f", f32, zmath.scalar.asinf, calls_default, &[_]common.Charge{
        .{ .operation = "asinf", .count = 1 },
        .{ .operation = "fmaf", .count = 1 },
    }) ++
    famUnary("scalar", "asin", "d", f64, zmath.scalar.asind, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "acos", "h", f16, zmath.scalar.acosh, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 4 },
    }) ++
    famUnary("scalar", "acos", "f", f32, zmath.scalar.acosf, calls_default, &[_]common.Charge{
        .{ .operation = "acosf", .count = 1 },
    }) ++
    famUnary("scalar", "acos", "d", f64, zmath.scalar.acosd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "atan", "h", f16, zmath.scalar.atanh, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 4 },
    }) ++
    famUnary("scalar", "atan", "f", f32, zmath.scalar.atanf, calls_default, &[_]common.Charge{
        .{ .operation = "atanf", .count = 1 },
        .{ .operation = "fmaf", .count = 1 },
    }) ++
    famUnary("scalar", "atan", "d", f64, zmath.scalar.atand, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "asinh", "h", f16, zmath.scalar.asinhh, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 6 },
    }) ++
    famUnary("scalar", "asinh", "f", f32, zmath.scalar.asinhf, calls_default, &[_]common.Charge{
        .{ .operation = "asinhf", .count = 1 },
    }) ++
    famUnary("scalar", "asinh", "d", f64, zmath.scalar.asinhd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "acosh", "h", f16, zmath.scalar.acoshh, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 5 },
    }) ++
    famUnary("scalar", "acosh", "f", f32, zmath.scalar.acoshf, calls_default, &[_]common.Charge{
        .{ .operation = "acoshf", .count = 1 },
    }) ++
    famUnary("scalar", "acosh", "d", f64, zmath.scalar.acoshd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "atanh", "h", f16, zmath.scalar.atanhh, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 5 },
    }) ++
    famUnary("scalar", "atanh", "f", f32, zmath.scalar.atanhf, calls_default, &[_]common.Charge{
        .{ .operation = "atanhf", .count = 1 },
    }) ++
    famUnary("scalar", "atanh", "d", f64, zmath.scalar.atanhd, calls_default, &[_]common.Charge{});

// --- zmath.scalar: special functions, roots, powers, fused multiply-add ---

// `erfh` is NOT a thin binary32 `erf`. `scalar_erfh.zig` widens its argument
// to binary32 only to read the encoding, then evaluates the whole error
// function in binary64: a degree-eight polynomial over a 56-row coefficient
// table, with a separate small-argument polynomial below 7/16. Its two
// bit helpers `myCopysignf` and `myCopysign` are private to that file, not
// accepted kernels, and it never calls `erff`. So the binary16 `erf` case
// reaches no binary32 kernel and charges nothing. `erfch` is the opposite
// shape: it hands its binary16 encoding straight to the `zmath_core_erfch_bits`
// seam, which is its own body.
const scalar_special_cases = [_]common.Case{} ++
    famUnary("scalar", "erf", "h", f16, zmath.scalar.erfh, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "erf", "f", f32, zmath.scalar.erff, calls_default, &[_]common.Charge{
        .{ .operation = "erff", .count = 1 },
    }) ++
    famUnary("scalar", "erf", "d", f64, zmath.scalar.erfd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "erfc", "h", f16, zmath.scalar.erfch, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "erfc", "f", f32, zmath.scalar.erfcf, calls_default, &[_]common.Charge{
        .{ .operation = "erfcf", .count = 1 },
    }) ++
    famUnary("scalar", "erfc", "d", f64, zmath.scalar.erfcd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "tgamma", "h", f16, zmath.scalar.tgammah, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "tgamma", "f", f32, zmath.scalar.tgammaf, calls_default, &[_]common.Charge{
        .{ .operation = "tgammaf", .count = 1 },
    }) ++
    famUnary("scalar", "tgamma", "d", f64, zmath.scalar.tgammad, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "sqrt", "h", f16, zmath.scalar.sqrth, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "sqrt", "f", f32, zmath.scalar.sqrtf, calls_default, &[_]common.Charge{
        .{ .operation = "sqrtf", .count = 1 },
    }) ++
    famUnary("scalar", "sqrt", "d", f64, zmath.scalar.sqrtd, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "rsqrt", "h", f16, zmath.scalar.rsqrth, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "rsqrt", "f", f32, zmath.scalar.rsqrtf, calls_default, &[_]common.Charge{
        .{ .operation = "rsqrtf", .count = 1 },
    }) ++
    famUnary("scalar", "rsqrt", "d", f64, zmath.scalar.rsqrtd, calls_default, &[_]common.Charge{}) ++
    // `cbrth` resolves its exact cases from the table and calls the public
    // binary32 `cbrtf` exactly once for every remaining finite input, so one
    // binary16 `cbrt` evaluation accepts one `cbrtf` call. `cbrtf` itself
    // widens to binary64 and reaches no further accepted binary32 kernel.
    famUnary("scalar", "cbrt", "h", f16, zmath.scalar.cbrth, calls_default, &[_]common.Charge{
        .{ .operation = "cbrtf", .count = 1 },
    }) ++
    famUnary("scalar", "cbrt", "f", f32, zmath.scalar.cbrtf, calls_default, &[_]common.Charge{
        .{ .operation = "cbrtf", .count = 1 },
    }) ++
    famUnary("scalar", "cbrt", "d", f64, zmath.scalar.cbrtd, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "pow", "h", f16, zmath.scalar.powh, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "pow", "f", f32, zmath.scalar.powf, calls_default, &[_]common.Charge{
        .{ .operation = "powf", .count = 1 },
    }) ++
    famBinary("scalar", "pow", "d", f64, zmath.scalar.powd, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "hypot", "h", f16, zmath.scalar.hypoth, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "hypot", "f", f32, zmath.scalar.hypotf, calls_default, &[_]common.Charge{
        .{ .operation = "hypotf", .count = 1 },
    }) ++
    famBinary("scalar", "hypot", "d", f64, zmath.scalar.hypotd, calls_default, &[_]common.Charge{}) ++
    famTernary("scalar", "fma", "h", f16, zmath.scalar.fmah, calls_default, &[_]common.Charge{}) ++
    famTernary("scalar", "fma", "f", f32, zmath.scalar.fmaf, calls_default, &[_]common.Charge{
        .{ .operation = "fmaf", .count = 1 },
    }) ++
    famTernary("scalar", "fma", "d", f64, zmath.scalar.fmad, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "ulpDistance", "h", f16, zmath.scalar.ulpDistanceh, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "ulpDistance", "f", f32, zmath.scalar.ulpDistancef, calls_default, &[_]common.Charge{
        .{ .operation = "ulpDistancef", .count = 1 },
    }) ++
    famBinary("scalar", "ulpDistance", "d", f64, zmath.scalar.ulpDistanced, calls_default, &[_]common.Charge{});

// --- zmath.scalar: narrowing operations ------------------------------------
//
// Each kernel forms the exact source-format result and rounds once to the
// destination format, so a binary16 result from a binary32 or binary64 source
// is a distinct accepted kernel and not a widening call plus a conversion.
// A `f16*` result with a binary32 source, and every `f32*` result from a
// binary64 source, carries a binary32 charge; the binary64-source
// `f16*` kernels do no binary32 work and charge nothing.

const scalar_narrow_cases = [_]common.Case{} ++
    famBinary("scalar", "f16addf32", "f32_to_f16", f32, zmath.scalar.f16addf32, calls_default, &[_]common.Charge{
        .{ .operation = "f16addf32", .count = 1 },
    }) ++
    famBinary("scalar", "f16subf32", "f32_to_f16", f32, zmath.scalar.f16subf32, calls_default, &[_]common.Charge{
        .{ .operation = "f16subf32", .count = 1 },
    }) ++
    famBinary("scalar", "f16mulf32", "f32_to_f16", f32, zmath.scalar.f16mulf32, calls_default, &[_]common.Charge{
        .{ .operation = "f16mulf32", .count = 1 },
    }) ++
    famBinary("scalar", "f16divf32", "f32_to_f16", f32, zmath.scalar.f16divf32, calls_default, &[_]common.Charge{
        .{ .operation = "f16divf32", .count = 1 },
    }) ++
    famTernary("scalar", "f16fmaf32", "f32_to_f16", f32, zmath.scalar.f16fmaf32, calls_default, &[_]common.Charge{
        .{ .operation = "f16fmaf32", .count = 1 },
    }) ++
    famUnary("scalar", "f16sqrtf32", "f32_to_f16", f32, zmath.scalar.f16sqrtf32, calls_default, &[_]common.Charge{
        .{ .operation = "f16sqrtf32", .count = 1 },
    }) ++
    famBinary("scalar", "f16addf64", "f64_to_f16", f64, zmath.scalar.f16addf64, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "f16subf64", "f64_to_f16", f64, zmath.scalar.f16subf64, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "f16mulf64", "f64_to_f16", f64, zmath.scalar.f16mulf64, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "f16divf64", "f64_to_f16", f64, zmath.scalar.f16divf64, calls_default, &[_]common.Charge{}) ++
    famTernary("scalar", "f16fmaf64", "f64_to_f16", f64, zmath.scalar.f16fmaf64, calls_default, &[_]common.Charge{}) ++
    famUnary("scalar", "f16sqrtf64", "f64_to_f16", f64, zmath.scalar.f16sqrtf64, calls_default, &[_]common.Charge{}) ++
    famBinary("scalar", "f32addf64", "f64_to_f32", f64, zmath.scalar.f32addf64, calls_default, &[_]common.Charge{
        .{ .operation = "f32addf64", .count = 1 },
    }) ++
    famBinary("scalar", "f32subf64", "f64_to_f32", f64, zmath.scalar.f32subf64, calls_default, &[_]common.Charge{
        .{ .operation = "f32subf64", .count = 1 },
    }) ++
    famBinary("scalar", "f32mulf64", "f64_to_f32", f64, zmath.scalar.f32mulf64, calls_default, &[_]common.Charge{
        .{ .operation = "f32mulf64", .count = 1 },
    }) ++
    famBinary("scalar", "f32divf64", "f64_to_f32", f64, zmath.scalar.f32divf64, calls_default, &[_]common.Charge{
        .{ .operation = "f32divf64", .count = 1 },
    }) ++
    famTernary("scalar", "f32fmaf64", "f64_to_f32", f64, zmath.scalar.f32fmaf64, calls_default, &[_]common.Charge{
        .{ .operation = "f32fmaf64", .count = 1 },
    }) ++
    famUnary("scalar", "f32sqrtf64", "f64_to_f32", f64, zmath.scalar.f32sqrtf64, calls_default, &[_]common.Charge{
        .{ .operation = "f32sqrtf64", .count = 1 },
    });

const scalar_cases = scalar_rounding_cases ++
    scalar_integer_rounding_cases ++
    scalar_fromfp_cases ++
    scalar_remainder_cases ++
    scalar_decompose_cases ++
    scalar_scaling_cases ++
    scalar_extrema_cases ++
    scalar_angular_cases ++
    scalar_power_cases ++
    scalar_exponential_cases ++
    scalar_logarithm_cases ++
    scalar_trigonometric_cases ++
    scalar_inverse_cases ++
    scalar_special_cases ++
    scalar_narrow_cases;

// ---------------------------------------------------------------------------
// Root generic dispatch
//
// Each wrapper below is the one root entry point it names. The root module
// resolves the format at compile time from the argument type and calls the
// matching canonical `zmath.scalar` or `zmath.ieee` entry point, so a
// dispatch case exercises the root route for all three formats and charges
// exactly the binary32 leaf that route accepts.
// ---------------------------------------------------------------------------

/// The lane float type of a root argument, matching the result types the root
/// module publishes for both scalar and `@Vector` arguments.
fn FloatLane(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .vector => |vector| vector.child,
        else => T,
    };
}

fn r_abs(value: anytype) @TypeOf(value) {
    return zmath.abs(value);
}

fn r_exp(value: anytype) @TypeOf(value) {
    return zmath.exp(value);
}

fn r_pow(base: anytype, exponent: anytype) @TypeOf(base) {
    return zmath.pow(base, exponent);
}

fn r_exp10(value: anytype) @TypeOf(value) {
    return zmath.exp10(value);
}

fn r_exp2m1(value: anytype) @TypeOf(value) {
    return zmath.exp2m1(value);
}

fn r_exp10m1(value: anytype) @TypeOf(value) {
    return zmath.exp10m1(value);
}

fn r_fma(first: anytype, second: anytype, third: anytype) @TypeOf(first) {
    return zmath.fma(first, second, third);
}

fn r_erfc(value: anytype) @TypeOf(value) {
    return zmath.erfc(value);
}

fn r_tgamma(value: anytype) @TypeOf(value) {
    return zmath.tgamma(value);
}

fn r_log(value: anytype) @TypeOf(value) {
    return zmath.log(value);
}

fn r_log2(value: anytype) @TypeOf(value) {
    return zmath.log2(value);
}

fn r_log2p1(value: anytype) @TypeOf(value) {
    return zmath.log2p1(value);
}

fn r_log10(value: anytype) @TypeOf(value) {
    return zmath.log10(value);
}

fn r_log10p1(value: anytype) @TypeOf(value) {
    return zmath.log10p1(value);
}

fn r_erf(value: anytype) @TypeOf(value) {
    return zmath.erf(value);
}

fn r_sinh(value: anytype) @TypeOf(value) {
    return zmath.sinh(value);
}

fn r_sin(value: anytype) @TypeOf(value) {
    return zmath.sin(value);
}

fn r_sinpi(value: anytype) @TypeOf(value) {
    return zmath.sinpi(value);
}

fn r_cos(value: anytype) @TypeOf(value) {
    return zmath.cos(value);
}

fn r_cospi(value: anytype) @TypeOf(value) {
    return zmath.cospi(value);
}

fn r_cosh(value: anytype) @TypeOf(value) {
    return zmath.cosh(value);
}

fn r_acosh(value: anytype) @TypeOf(value) {
    return zmath.acosh(value);
}

fn r_tan(value: anytype) @TypeOf(value) {
    return zmath.tan(value);
}

fn r_tanpi(value: anytype) @TypeOf(value) {
    return zmath.tanpi(value);
}

fn r_tanh(value: anytype) @TypeOf(value) {
    return zmath.tanh(value);
}

fn r_rsqrt(value: anytype) @TypeOf(value) {
    return zmath.rsqrt(value);
}

fn r_sqrt(value: anytype) @TypeOf(value) {
    return zmath.sqrt(value);
}

fn r_hypot(left: anytype, right: anytype) @TypeOf(left) {
    return zmath.hypot(left, right);
}

fn r_acos(value: anytype) @TypeOf(value) {
    return zmath.acos(value);
}

fn r_asin(value: anytype) @TypeOf(value) {
    return zmath.asin(value);
}

fn r_asinh(value: anytype) @TypeOf(value) {
    return zmath.asinh(value);
}

fn r_atanh(value: anytype) @TypeOf(value) {
    return zmath.atanh(value);
}

fn r_atan(value: anytype) @TypeOf(value) {
    return zmath.atan(value);
}

fn r_cbrt(value: anytype) @TypeOf(value) {
    return zmath.cbrt(value);
}

fn r_exp2(value: anytype) @TypeOf(value) {
    return zmath.exp2(value);
}

fn r_expm1(value: anytype) @TypeOf(value) {
    return zmath.expm1(value);
}

fn r_log1p(value: anytype) @TypeOf(value) {
    return zmath.log1p(value);
}

fn r_logp1(value: anytype) @TypeOf(value) {
    return zmath.logp1(value);
}

fn r_ceil(value: anytype) @TypeOf(value) {
    return zmath.ceil(value);
}

fn r_floor(value: anytype) @TypeOf(value) {
    return zmath.floor(value);
}

fn r_nearbyint(value: anytype) @TypeOf(value) {
    return zmath.nearbyint(value);
}

fn r_rint(value: anytype) @TypeOf(value) {
    return zmath.rint(value);
}

fn r_round(value: anytype) @TypeOf(value) {
    return zmath.round(value);
}

fn r_roundeven(value: anytype) @TypeOf(value) {
    return zmath.roundeven(value);
}

fn r_trunc(value: anytype) @TypeOf(value) {
    return zmath.trunc(value);
}

fn r_lrint(value: anytype) zmath.IntegerResult {
    return zmath.lrint(value);
}

fn r_llrint(value: anytype) zmath.IntegerResult {
    return zmath.llrint(value);
}

fn r_lround(value: anytype) zmath.IntegerResult {
    return zmath.lround(value);
}

fn r_llround(value: anytype) zmath.IntegerResult {
    return zmath.llround(value);
}

fn r_fromfp(value: anytype, direction: zmath.FromFpRound, width: u32) @TypeOf(value) {
    return zmath.fromfp(value, direction, width);
}

fn r_ufromfp(value: anytype, direction: zmath.FromFpRound, width: u32) @TypeOf(value) {
    return zmath.ufromfp(value, direction, width);
}

fn r_fromfpx(value: anytype, direction: zmath.FromFpRound, width: u32) @TypeOf(value) {
    return zmath.fromfpx(value, direction, width);
}

fn r_ufromfpx(value: anytype, direction: zmath.FromFpRound, width: u32) @TypeOf(value) {
    return zmath.ufromfpx(value, direction, width);
}

fn r_atan2(y: anytype, x: anytype) zmath.Atan2Result(FloatLane(@TypeOf(y))) {
    return zmath.atan2(y, x);
}

fn r_asinpi(value: anytype) @TypeOf(value) {
    return zmath.asinpi(value);
}

fn r_acospi(value: anytype) @TypeOf(value) {
    return zmath.acospi(value);
}

fn r_atanpi(value: anytype) @TypeOf(value) {
    return zmath.atanpi(value);
}

fn r_atan2pi(y: anytype, x: anytype) zmath.Atan2Result(FloatLane(@TypeOf(y))) {
    return zmath.atan2pi(y, x);
}

fn r_pown(value: anytype, exponent: i64) zmath.PowerResult(FloatLane(@TypeOf(value))) {
    return zmath.pown(value, exponent);
}

fn r_powr(base: anytype, exponent: anytype) @TypeOf(base) {
    return zmath.powr(base, exponent);
}

fn r_compoundn(value: anytype, exponent: i64) zmath.PowerResult(FloatLane(@TypeOf(value))) {
    return zmath.compoundn(value, exponent);
}

fn r_rootn(value: anytype, degree: i64) zmath.PowerResult(FloatLane(@TypeOf(value))) {
    return zmath.rootn(value, degree);
}

fn r_lgamma(value: anytype) zmath.LgammaResult(FloatLane(@TypeOf(value))) {
    return zmath.lgamma(value);
}

fn r_fmod(left: anytype, right: anytype) @TypeOf(left) {
    return zmath.fmod(left, right);
}

fn r_remainder(left: anytype, right: anytype) @TypeOf(left) {
    return zmath.remainder(left, right);
}

fn r_remquo(left: anytype, right: anytype) zmath.RemquoResult(FloatLane(@TypeOf(left))) {
    return zmath.remquo(left, right);
}

fn r_frexp(value: anytype) zmath.FrexpResult(FloatLane(@TypeOf(value))) {
    return zmath.frexp(value);
}

fn r_modf(value: anytype) zmath.ModfResult(FloatLane(@TypeOf(value))) {
    return zmath.modf(value);
}

fn r_ilogb(value: anytype) i32 {
    return zmath.ilogb(value);
}

fn r_llogb(value: anytype) i64 {
    return zmath.llogb(value);
}

fn r_logb(value: anytype) @TypeOf(value) {
    return zmath.logb(value);
}

fn r_ldexp(value: anytype, exponent: i32) @TypeOf(value) {
    return zmath.ldexp(value, exponent);
}

fn r_scalbn(value: anytype, exponent: i32) @TypeOf(value) {
    return zmath.scalbn(value, exponent);
}

fn r_scalbln(value: anytype, exponent: i64) @TypeOf(value) {
    return zmath.scalbln(value, exponent);
}

fn r_fdim(left: anytype, right: anytype) @TypeOf(left) {
    return zmath.fdim(left, right);
}

fn r_fmax(left: anytype, right: anytype) @TypeOf(left) {
    return zmath.fmax(left, right);
}

fn r_fmin(left: anytype, right: anytype) @TypeOf(left) {
    return zmath.fmin(left, right);
}

fn r_fmaximum(left: anytype, right: anytype) @TypeOf(left) {
    return zmath.fmaximum(left, right);
}

fn r_fminimum(left: anytype, right: anytype) @TypeOf(left) {
    return zmath.fminimum(left, right);
}

fn r_fmaximum_mag(left: anytype, right: anytype) @TypeOf(left) {
    return zmath.fmaximum_mag(left, right);
}

fn r_fminimum_mag(left: anytype, right: anytype) @TypeOf(left) {
    return zmath.fminimum_mag(left, right);
}

fn r_fmaximum_num(left: anytype, right: anytype) @TypeOf(left) {
    return zmath.fmaximum_num(left, right);
}

fn r_fminimum_num(left: anytype, right: anytype) @TypeOf(left) {
    return zmath.fminimum_num(left, right);
}

fn r_fmaximum_mag_num(left: anytype, right: anytype) @TypeOf(left) {
    return zmath.fmaximum_mag_num(left, right);
}

fn r_fminimum_mag_num(left: anytype, right: anytype) @TypeOf(left) {
    return zmath.fminimum_mag_num(left, right);
}

fn r_canonicalize(value: anytype) zmath.CanonicalizeResult(FloatLane(@TypeOf(value))) {
    return zmath.canonicalize(value);
}

fn r_copySign(value: anytype, sign: anytype) @TypeOf(value) {
    return zmath.copySign(value, sign);
}

fn r_nextAfter(from: anytype, to: anytype) @TypeOf(from) {
    return zmath.nextAfter(from, to);
}

fn r_nextToward(value: anytype, toward: f64) @TypeOf(value) {
    return zmath.nextToward(value, toward);
}

fn r_nextUp(value: anytype) @TypeOf(value) {
    return zmath.nextUp(value);
}

fn r_nextDown(value: anytype) @TypeOf(value) {
    return zmath.nextDown(value);
}

fn r_totalOrder(left: anytype, right: anytype) bool {
    return zmath.totalOrder(left, right);
}

fn r_totalOrderMag(left: anytype, right: anytype) bool {
    return zmath.totalOrderMag(left, right);
}

fn r_getPayload(value: anytype) @TypeOf(value) {
    return zmath.getPayload(value);
}

fn r_setPayload(value: anytype) zmath.PayloadResult(FloatLane(@TypeOf(value))) {
    return zmath.setPayload(value);
}

fn r_setPayloadSig(value: anytype) zmath.PayloadResult(FloatLane(@TypeOf(value))) {
    return zmath.setPayloadSig(value);
}

fn rootEntry(
    comptime family: []const u8,
    comptime invoke: *const fn (usize) u64,
    comptime calls: u32,
    comptime charges: []const common.Charge,
) common.Case {
    return .{
        .name = "leaf.root." ++ family ++ ".dispatch",
        .namespace = "root",
        .invoke = invoke,
        .calls = calls,
        .f32 = charges,
    };
}

fn rootNanEntry(comptime T: type, comptime charges: []const common.Charge) common.Case {
    return .{
        .name = "leaf.root.nan." ++ @typeName(T),
        .namespace = "root",
        .invoke = rootNanCase(T),
        .calls = calls_default,
        .f32 = charges,
    };
}

// The six root narrowing entry points keep a fixed binary64 source and a
// binary32 result, so they are timed per regime like any other binary32
// kernel rather than through the three-format dispatch above.
//
// Each root spelling runs the kernel that `zmath.scalar.f32addf64` and its
// five siblings run: one `scalar_narrow` `addBits`, `multiplyBits`,
// `divideBits`, `fmaBits` or `sqrtBits` call with a binary64 source and a
// binary32 destination, over the same operands, with one rounding at the end.
// The six cases therefore charge those six canonical keys and open no key of
// their own, the alias rule `rintf` follows onto `nearbyintf` above.
const root_narrow_cases = [_]common.Case{} ++
    famBinary("root", "fadd", "f64_to_f32", f64, zmath.fadd, calls_default, &[_]common.Charge{
        .{ .operation = "f32addf64", .count = 1 },
    }) ++
    famBinary("root", "fsub", "f64_to_f32", f64, zmath.fsub, calls_default, &[_]common.Charge{
        .{ .operation = "f32subf64", .count = 1 },
    }) ++
    famBinary("root", "fmul", "f64_to_f32", f64, zmath.fmul, calls_default, &[_]common.Charge{
        .{ .operation = "f32mulf64", .count = 1 },
    }) ++
    famBinary("root", "fdiv", "f64_to_f32", f64, zmath.fdiv, calls_default, &[_]common.Charge{
        .{ .operation = "f32divf64", .count = 1 },
    }) ++
    famTernary("root", "ffma", "f64_to_f32", f64, zmath.ffma, calls_default, &[_]common.Charge{
        .{ .operation = "f32fmaf64", .count = 1 },
    }) ++
    famUnary("root", "fsqrt", "f64_to_f32", f64, zmath.fsqrt, calls_default, &[_]common.Charge{
        .{ .operation = "f32sqrtf64", .count = 1 },
    });

// One dispatch case per root generic entry point. Every entry point in the
// root module that takes an `f16`, `f32` or `f64` argument appears here
// exactly once. One `invoke` evaluates all three formats, so a charge list is
// the union of the three routes: the binary32 leaf named once, everything the
// binary16 route reaches transitively, and anything that binary32 leaf itself
// reaches. `cbrt` is the one entry whose binary16 route calls the same public
// binary32 kernel the binary32 route names, so `cbrtf` is charged twice.
const root_dispatch_cases = [_]common.Case{
    rootEntry("abs", rootUnop(r_abs), calls_default, &[_]common.Charge{.{ .operation = "absf", .count = 1 }}),
    rootEntry("exp", rootUnop(r_exp), calls_default, &[_]common.Charge{.{ .operation = "expf", .count = 1 }}),
    rootEntry("pow", rootBinop(r_pow), calls_default, &[_]common.Charge{.{ .operation = "powf", .count = 1 }}),
    rootEntry("exp10", rootUnop(r_exp10), calls_default, &[_]common.Charge{.{ .operation = "exp10f", .count = 1 }}),
    rootEntry("exp2m1", rootUnop(r_exp2m1), calls_default, &[_]common.Charge{
        .{ .operation = "exp2m1f", .count = 1 },
        .{ .operation = "fmaf", .count = 2 },
    }),
    rootEntry("exp10m1", rootUnop(r_exp10m1), calls_default, &[_]common.Charge{
        .{ .operation = "exp10m1f", .count = 1 },
        .{ .operation = "fmaf", .count = 2 },
    }),
    rootEntry("fma", rootTrinop(r_fma), calls_default, &[_]common.Charge{.{ .operation = "fmaf", .count = 1 }}),
    rootEntry("erfc", rootUnop(r_erfc), calls_default, &[_]common.Charge{.{ .operation = "erfcf", .count = 1 }}),
    rootEntry("tgamma", rootUnop(r_tgamma), calls_default, &[_]common.Charge{.{ .operation = "tgammaf", .count = 1 }}),
    rootEntry("log", rootUnop(r_log), calls_default, &[_]common.Charge{.{ .operation = "logf", .count = 1 }}),
    rootEntry("log2", rootUnop(r_log2), calls_default, &[_]common.Charge{.{ .operation = "log2f", .count = 1 }}),
    rootEntry("log2p1", rootUnop(r_log2p1), calls_default, &[_]common.Charge{
        .{ .operation = "log2p1f", .count = 1 },
        // The binary16 route spends the four `zmath_fmaf` evaluations of the
        // `zmath_core_log2p1h_bits` seam; `log2p1f` reaches none.
        .{ .operation = "fmaf", .count = 4 },
    }),
    rootEntry("log10", rootUnop(r_log10), calls_default, &[_]common.Charge{.{ .operation = "log10f", .count = 1 }}),
    rootEntry("log10p1", rootUnop(r_log10p1), calls_default, &[_]common.Charge{
        .{ .operation = "log10p1f", .count = 1 },
        // The binary16 route spends the four `zmath_fmaf` evaluations of the
        // `zmath_core_log10p1h_bits` seam; `log10p1f` reaches none.
        .{ .operation = "fmaf", .count = 4 },
    }),
    rootEntry("erf", rootUnop(r_erf), calls_default, &[_]common.Charge{.{ .operation = "erff", .count = 1 }}),
    rootEntry("sinh", rootUnop(r_sinh), calls_default, &[_]common.Charge{
        .{ .operation = "sinhf", .count = 1 },
        .{ .operation = "fmaf", .count = 1 },
    }),
    rootEntry("sin", rootUnop(r_sin), calls_default, &[_]common.Charge{
        .{ .operation = "sinf", .count = 1 },
        .{ .operation = "fmaf", .count = 1 },
    }),
    rootEntry("sinpi", rootUnop(r_sinpi), calls_default, &[_]common.Charge{
        .{ .operation = "sinpif", .count = 1 },
        .{ .operation = "fmaf", .count = 1 },
    }),
    rootEntry("cos", rootUnop(r_cos), calls_default, &[_]common.Charge{
        .{ .operation = "cosf", .count = 1 },
        // One evaluation from the binary16 `cosh` kernel and one from the
        // binary32 `cosf` leaf itself.
        .{ .operation = "fmaf", .count = 2 },
    }),
    rootEntry("cospi", rootUnop(r_cospi), calls_default, &[_]common.Charge{
        .{ .operation = "cospif", .count = 1 },
        // One evaluation from the binary16 `cospih` seam and one from the
        // binary32 `cospif` seam; both spend their fused multiply-add in C.
        .{ .operation = "fmaf", .count = 2 },
    }),
    rootEntry("cosh", rootUnop(r_cosh), calls_default, &[_]common.Charge{
        .{ .operation = "coshf", .count = 1 },
        .{ .operation = "fmaf", .count = 1 },
    }),
    rootEntry("acosh", rootUnop(r_acosh), calls_default, &[_]common.Charge{
        .{ .operation = "acoshf", .count = 1 },
        .{ .operation = "fmaf", .count = 5 },
    }),
    rootEntry("tan", rootUnop(r_tan), calls_default, &[_]common.Charge{
        .{ .operation = "tanf", .count = 1 },
        .{ .operation = "fmaf", .count = 3 },
    }),
    rootEntry("tanpi", rootUnop(r_tanpi), calls_default, &[_]common.Charge{
        .{ .operation = "tanpif", .count = 1 },
        .{ .operation = "fmaf", .count = 2 },
    }),
    rootEntry("tanh", rootUnop(r_tanh), calls_default, &[_]common.Charge{
        .{ .operation = "tanhf", .count = 1 },
        // `tanhh` is a pure table lookup; this evaluation is the binary32
        // `tanhf` leaf's own.
        .{ .operation = "fmaf", .count = 1 },
    }),
    rootEntry("rsqrt", rootUnop(r_rsqrt), calls_default, &[_]common.Charge{.{ .operation = "rsqrtf", .count = 1 }}),
    rootEntry("sqrt", rootUnop(r_sqrt), calls_default, &[_]common.Charge{.{ .operation = "sqrtf", .count = 1 }}),
    rootEntry("hypot", rootBinop(r_hypot), calls_default, &[_]common.Charge{.{ .operation = "hypotf", .count = 1 }}),
    rootEntry("acos", rootUnop(r_acos), calls_default, &[_]common.Charge{
        .{ .operation = "acosf", .count = 1 },
        .{ .operation = "fmaf", .count = 4 },
    }),
    rootEntry("asin", rootUnop(r_asin), calls_default, &[_]common.Charge{
        .{ .operation = "asinf", .count = 1 },
        .{ .operation = "fmaf", .count = 1 },
    }),
    rootEntry("asinh", rootUnop(r_asinh), calls_default, &[_]common.Charge{
        .{ .operation = "asinhf", .count = 1 },
        .{ .operation = "fmaf", .count = 6 },
    }),
    rootEntry("atanh", rootUnop(r_atanh), calls_default, &[_]common.Charge{
        .{ .operation = "atanhf", .count = 1 },
        .{ .operation = "fmaf", .count = 5 },
    }),
    rootEntry("atan", rootUnop(r_atan), calls_default, &[_]common.Charge{
        .{ .operation = "atanf", .count = 1 },
        .{ .operation = "fmaf", .count = 5 },
    }),
    rootEntry("cbrt", rootUnop(r_cbrt), calls_default, &[_]common.Charge{
        .{ .operation = "cbrtf", .count = 2 },
    }),
    rootEntry("exp2", rootUnop(r_exp2), calls_default, &[_]common.Charge{.{ .operation = "exp2f", .count = 1 }}),
    rootEntry("expm1", rootUnop(r_expm1), calls_default, &[_]common.Charge{
        .{ .operation = "expm1f", .count = 1 },
        // The binary16 `expm1h` route spends two binary32 fused multiply-adds
        // on its small-argument branch, one on its table branch.
        .{ .operation = "fmaf", .count = 2 },
    }),
    rootEntry("log1p", rootUnop(r_log1p), calls_default, &[_]common.Charge{
        .{ .operation = "log1pf", .count = 1 },
        .{ .operation = "fmaf", .count = 4 },
    }),
    rootEntry("logp1", rootUnop(r_logp1), calls_default, &[_]common.Charge{
        .{ .operation = "log1pf", .count = 1 },
        // `logp1h` forwards to `log1ph`, so the binary16 route spends the same
        // four binary32 fused multiply-adds as `log1p`.
        .{ .operation = "fmaf", .count = 4 },
    }),
    rootEntry("ceil", rootUnop(r_ceil), calls_default, &[_]common.Charge{.{ .operation = "ceilf", .count = 1 }}),
    rootEntry("floor", rootUnop(r_floor), calls_default, &[_]common.Charge{.{ .operation = "floorf", .count = 1 }}),
    rootEntry("nearbyint", rootUnop(r_nearbyint), calls_default, &[_]common.Charge{.{ .operation = "nearbyintf", .count = 1 }}),
    rootEntry("rint", rootUnop(r_rint), calls_default, &[_]common.Charge{
        .{ .operation = "nearbyintf", .count = 1 },
    }),
    rootEntry("round", rootUnop(r_round), calls_default, &[_]common.Charge{.{ .operation = "roundf", .count = 1 }}),
    rootEntry("roundeven", rootUnop(r_roundeven), calls_default, &[_]common.Charge{
        .{ .operation = "nearbyintf", .count = 1 },
    }),
    rootEntry("trunc", rootUnop(r_trunc), calls_default, &[_]common.Charge{.{ .operation = "truncf", .count = 1 }}),
    rootEntry("lrint", rootUnop(r_lrint), calls_default, &[_]common.Charge{.{ .operation = "lrintf", .count = 1 }}),
    rootEntry("llrint", rootUnop(r_llrint), calls_default, &[_]common.Charge{.{ .operation = "llrintf", .count = 1 }}),
    rootEntry("lround", rootUnop(r_lround), calls_default, &[_]common.Charge{.{ .operation = "lroundf", .count = 1 }}),
    rootEntry("llround", rootUnop(r_llround), calls_default, &[_]common.Charge{.{ .operation = "llroundf", .count = 1 }}),
    rootEntry("fromfp", rootFromfp(r_fromfp), calls_default, &[_]common.Charge{.{ .operation = "fromfpf", .count = 1 }}),
    rootEntry("ufromfp", rootFromfp(r_ufromfp), calls_default, &[_]common.Charge{.{ .operation = "ufromfpf", .count = 1 }}),
    rootEntry("fromfpx", rootFromfp(r_fromfpx), calls_default, &[_]common.Charge{.{ .operation = "fromfpxf", .count = 1 }}),
    rootEntry("ufromfpx", rootFromfp(r_ufromfpx), calls_default, &[_]common.Charge{.{ .operation = "ufromfpxf", .count = 1 }}),
    rootEntry("atan2", rootBinop(r_atan2), calls_default, &[_]common.Charge{.{ .operation = "atan2f", .count = 1 }}),
    rootEntry("asinpi", rootUnop(r_asinpi), calls_default, &[_]common.Charge{
        .{ .operation = "asinpif", .count = 1 },
        // The binary16 route spends the three `zmath_fmaf` evaluations of the
        // `zmath_core_asinpih_bits` seam; `asinpif` reaches none.
        .{ .operation = "fmaf", .count = 3 },
    }),
    rootEntry("acospi", rootUnop(r_acospi), calls_default, &[_]common.Charge{
        .{ .operation = "acospif", .count = 1 },
        // The binary16 route spends the four `zmath_fmaf` evaluations of the
        // `zmath_core_acospih_bits` seam; `acospif` reaches none.
        .{ .operation = "fmaf", .count = 4 },
    }),
    rootEntry("atanpi", rootUnop(r_atanpi), calls_default, &[_]common.Charge{
        .{ .operation = "atanpif", .count = 1 },
        // The binary16 route spends the four `zmath_fmaf` evaluations of the
        // `zmath_core_atanpih_bits` seam; `atanpif` reaches none.
        .{ .operation = "fmaf", .count = 4 },
    }),
    rootEntry("atan2pi", rootBinop(r_atan2pi), calls_default, &[_]common.Charge{.{ .operation = "atan2pif", .count = 1 }}),
    rootEntry("pown", rootDegree(r_pown), calls_exact, &[_]common.Charge{.{ .operation = "pownf", .count = 1 }}),
    rootEntry("powr", rootBinop(r_powr), calls_default, &[_]common.Charge{
        .{ .operation = "powf", .count = 1 },
    }),
    rootEntry("compoundn", rootDegree(r_compoundn), calls_exact, &[_]common.Charge{.{ .operation = "compoundnf", .count = 1 }}),
    rootEntry("rootn", rootDegree(r_rootn), calls_exact, &[_]common.Charge{.{ .operation = "rootnf", .count = 1 }}),
    rootEntry("lgamma", rootUnop(r_lgamma), calls_default, &[_]common.Charge{
        .{ .operation = "lgammaf", .count = 1 },
        // `lgammah` reaches a seam with no binary32 fused multiply-add, so
        // this one evaluation is the binary32 `zmath_core_lgammaf` seam's own.
        .{ .operation = "fmaf", .count = 1 },
    }),
    rootEntry("fmod", rootBinop(r_fmod), calls_default, &[_]common.Charge{.{ .operation = "fmodf", .count = 1 }}),
    rootEntry("remainder", rootBinop(r_remainder), calls_default, &[_]common.Charge{.{ .operation = "remainderf", .count = 1 }}),
    rootEntry("remquo", rootBinop(r_remquo), calls_default, &[_]common.Charge{.{ .operation = "remquof", .count = 1 }}),
    rootEntry("frexp", rootUnop(r_frexp), calls_default, &[_]common.Charge{.{ .operation = "frexpf", .count = 1 }}),
    rootEntry("modf", rootUnop(r_modf), calls_default, &[_]common.Charge{.{ .operation = "modff", .count = 1 }}),
    rootEntry("ilogb", rootUnop(r_ilogb), calls_default, &[_]common.Charge{.{ .operation = "ilogbf", .count = 1 }}),
    rootEntry("llogb", rootUnop(r_llogb), calls_default, &[_]common.Charge{.{ .operation = "llogbf", .count = 1 }}),
    rootEntry("logb", rootUnop(r_logb), calls_default, &[_]common.Charge{.{ .operation = "logbf", .count = 1 }}),
    rootEntry("ldexp", rootExpo32(r_ldexp), calls_default, &[_]common.Charge{.{ .operation = "ldexpf", .count = 1 }}),
    rootEntry("scalbn", rootExpo32(r_scalbn), calls_default, &[_]common.Charge{.{ .operation = "scalbnf", .count = 1 }}),
    rootEntry("scalbln", rootExpo64(r_scalbln), calls_default, &[_]common.Charge{.{ .operation = "scalblnf", .count = 1 }}),
    rootEntry("fdim", rootBinop(r_fdim), calls_default, &[_]common.Charge{.{ .operation = "fdimf", .count = 1 }}),
    rootEntry("fmax", rootBinop(r_fmax), calls_default, &[_]common.Charge{.{ .operation = "fmaxf", .count = 1 }}),
    rootEntry("fmin", rootBinop(r_fmin), calls_default, &[_]common.Charge{.{ .operation = "fminf", .count = 1 }}),
    rootEntry("fmaximum", rootBinop(r_fmaximum), calls_default, &[_]common.Charge{.{ .operation = "fmaximumf", .count = 1 }}),
    rootEntry("fminimum", rootBinop(r_fminimum), calls_default, &[_]common.Charge{.{ .operation = "fminimumf", .count = 1 }}),
    rootEntry("fmaximum_mag", rootBinop(r_fmaximum_mag), calls_default, &[_]common.Charge{.{ .operation = "fmaximum_magf", .count = 1 }}),
    rootEntry("fminimum_mag", rootBinop(r_fminimum_mag), calls_default, &[_]common.Charge{.{ .operation = "fminimum_magf", .count = 1 }}),
    rootEntry("fmaximum_num", rootBinop(r_fmaximum_num), calls_default, &[_]common.Charge{.{ .operation = "fmaximum_numf", .count = 1 }}),
    rootEntry("fminimum_num", rootBinop(r_fminimum_num), calls_default, &[_]common.Charge{.{ .operation = "fminimum_numf", .count = 1 }}),
    rootEntry("fmaximum_mag_num", rootBinop(r_fmaximum_mag_num), calls_default, &[_]common.Charge{.{ .operation = "fmaximum_mag_numf", .count = 1 }}),
    rootEntry("fminimum_mag_num", rootBinop(r_fminimum_mag_num), calls_default, &[_]common.Charge{.{ .operation = "fminimum_mag_numf", .count = 1 }}),
    rootEntry("canonicalize", rootUnop(r_canonicalize), calls_default, &[_]common.Charge{.{ .operation = "canonicalizef", .count = 1 }}),
    rootEntry("copySign", rootBinop(r_copySign), calls_default, &[_]common.Charge{.{ .operation = "copySignf", .count = 1 }}),
    rootEntry("nextAfter", rootBinop(r_nextAfter), calls_default, &[_]common.Charge{.{ .operation = "nextAfterf", .count = 1 }}),
    rootEntry("nextToward", rootToward(r_nextToward), calls_default, &[_]common.Charge{.{ .operation = "nextTowardf", .count = 1 }}),
    rootEntry("nextUp", rootUnop(r_nextUp), calls_default, &[_]common.Charge{.{ .operation = "nextUpf", .count = 1 }}),
    rootEntry("nextDown", rootUnop(r_nextDown), calls_default, &[_]common.Charge{.{ .operation = "nextDownf", .count = 1 }}),
    rootEntry("totalOrder", rootBinop(r_totalOrder), calls_default, &[_]common.Charge{.{ .operation = "totalOrderf", .count = 1 }}),
    rootEntry("totalOrderMag", rootBinop(r_totalOrderMag), calls_default, &[_]common.Charge{.{ .operation = "totalOrderMagf", .count = 1 }}),
    rootEntry("getPayload", rootUnop(r_getPayload), calls_default, &[_]common.Charge{.{ .operation = "getPayloadf", .count = 1 }}),
    rootEntry("setPayload", rootUnop(r_setPayload), calls_default, &[_]common.Charge{.{ .operation = "setPayloadf", .count = 1 }}),
    rootEntry("setPayloadSig", rootUnop(r_setPayloadSig), calls_default, &[_]common.Charge{.{ .operation = "setPayloadSigf", .count = 1 }}),
    rootNanEntry(f16, &[_]common.Charge{}),
    rootNanEntry(f32, &[_]common.Charge{.{ .operation = "nanf", .count = 1 }}),
    rootNanEntry(f64, &[_]common.Charge{}),
};

const root_cases = root_dispatch_cases ++ root_narrow_cases;

/// Every case in this slice, in module order: the encoding layer, then the
/// canonical per-format scalar families, then the root dispatch routes.
pub const cases = ieee_cases ++ scalar_cases ++ root_cases;
