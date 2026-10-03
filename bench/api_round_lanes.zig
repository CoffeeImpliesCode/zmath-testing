//! Lane slice of the API round: the whole portable-vector (`@Vector`) surface.
//!
//! Every case here is a direct timed call into one public `zmath.vector.*`
//! entry point. The mapping from the 417 declared `pub fn` exports of
//! `vector.zig`, `vector_ieee.zig`, `vector_intarg.zig`, `vector_narrow.zig`,
//! `vector_struct.zig` and `vector_core.zig` onto timed cases is
//! source-derived, not sampled: each route table below names the entry points
//! it accounts for, and the comptime checks at the foot of this file fail if
//! that accounting ever stops matching the source.
//!
//! ## How the surface is covered
//!
//! The 417 exports fall into exactly three classes, and `inventory` records
//! which one every export is in, with the reason:
//!
//! - `direct_timed`. The export is the canonical route of at least one lane
//!   type and is timed directly there: every per-format spelling (`abshv`,
//!   `absfv`, `absdv`, ...), every fixed-shape export (the six `vector_narrow`
//!   narrowing routes), every `vector_intarg` per-format spelling, the six
//!   shared `vector_core` helpers, and the six generic dispatch spellings whose
//!   family declares no binary16 spelling. Each is timed at every lane width in
//!   `widths` under every regime in `regimes`, so nine rows per export.
//! - `identical_canonical`. The other 96 generic dispatch spellings (`absv`,
//!   `expm1v`, `fmav`, `pownvLanes`, ...). Their lane-type test is comptime, so
//!   for each lane type they land on the very same mapping helper, the very
//!   same accepted kernel and the very same lane loop as the per-format
//!   spelling they name; there is no runtime dispatch left to measure and
//!   timing them again would measure those routes twice. The per-format rows
//!   are their canonical routes.
//!
//!   The six generic spellings that DO reach a binary16 kernel are `sinv`,
//!   `cosv`, `tanv`, `asinv`, `acosv` and `atanv`. Their binary16 names would
//!   be `sinhv`, `coshv`, `tanhv`, `asinhv`, `acoshv` and `atanhv`, and those
//!   are already the GENERIC entry points of the hyperbolic families, so a
//!   generic dispatch spelling is the only public route to `scalar.sinh`,
//!   `scalar.cosh`, `scalar.tanh`, `scalar.asinh`, `scalar.acosh` and
//!   `scalar.atanh`. Those six are therefore `direct_timed` at the binary16 lane
//!   type only, and their binary32 and binary64 legs are the identical
//!   canonical routes of their per-format siblings.
//! - `compile_only`. The three `vector_intarg` type queries (`widthOf`,
//!   `LaneOf`, `PowerVector`). Each takes a comptime type and returns a
//!   compile-time value or a type, so no runtime evaluation exists to time.
//!   The comptime block below exercises all three and checks their results, and
//!   each consumes no kernel.
//!
//! ## Charging
//!
//! `Charge.operation` is the canonical public name of the accepted kernel the
//! route reaches, so however many spellings reach one kernel it charges one
//! global key, and `Charge.count` is the number of evaluations ONE `invoke`
//! call reaches it. A portable-vector route applies the accepted kernel once
//! per lane, so a case at lane width `w` charges `w` evaluations of a kernel it
//! reaches once per lane, and `w * k` for a kernel it reaches `k` times on the
//! branch an operand can select.
//!
//! The per-lane counts are read off the leaf slice's published charge table,
//! which is the round's coordination table for `zmath.scalar` and `zmath.ieee`.
//! They are transitive and flattened, so:
//!
//! - Most binary16 kernels do no binary32 work and charge nothing: `absh` is a
//!   bit mask, `tanhh`, `lgammah`, `erfh`, `erfch`, `tgammah`, `powh`, `atan2h`,
//!   `atan2pih` and `fmah` reach no binary32 kernel, and `erfh` in particular
//!   widens to binary64. The full list is `zero_charge_kernels`.
//! - The binary16 kernels that DO reach binary32 do so through the one shared
//!   fused-multiply-add engine, so they charge `fmaf`: `sinhh`, `coshh`,
//!   `sinpih`, `cospih` one, `expm1h`, `exp2m1h`, `exp10m1h` two, `log1ph`,
//!   `logp1h`, `log2p1h`, `log10p1h` four, `asinpih` three, `acospih`, `atanpih`
//!   four, `asinhh` six, `acoshh` five, `atanhh` five, the binary16 `acos` and
//!   `atan` kernels four each and the binary16 `tan` kernel two. `expm1h` is
//!   the clearest case: its small path runs two engine evaluations and its
//!   table path one, so `expm1hv` carries `2 * width` and never less.
//! - Seven binary32 kernels run the engine once themselves on top of their own
//!   work: `asinf`, `atanf`, `tanf`, `tanhf`, `cosf`, `cospif` and `lgammaf`,
//!   so their per-lane charge has two entries.
//! - A pure forwarder opens no key of its own; its one numerical evaluation is
//!   the terminal kernel. So `rintf`, `roundevenf` and `logp1f` charge
//!   `nearbyintf`, `nearbyintf` and `log1pf`, and `powrf` charges `powf`.
//!   `cbrth` calls `cbrtf` once on its fallback path and charges it.
//! - The six `vector_narrow` routes (`faddv` ... `fsqrtv`) take `f64` lanes and
//!   produce `f32` lanes, and each charges the one canonical key of the exact
//!   narrowing kernel it runs, once per lane: `faddv` charges `f32addf64`,
//!   `fsubv` `f32subf64`, `fmulv` `f32mulf64`, `fdivv` `f32divf64`, `ffmav`
//!   `f32fmaf64` and `fsqrtv` `f32sqrtf64`. The symbol those routes call is the
//!   short C23 spelling, `fadd` and its five siblings, which is an alias of the
//!   same exact kernel rather than a key of its own, so the root route of the
//!   same kernel and the portable route here reserve one entry between them.
//!   The narrowing `fma` is not one of the six: it keeps its lane type, so it
//!   charges `fmaf` like every other fused-multiply-add route.
//!
//! Every binary64 case and every binary16 case with an empty charge carries no
//! entry at all. `budget` at the foot of this file is the exact per-operation
//! cost of one full pass of this slice.
//!
//! ## The published counts
//!
//! Every number here is derived from the family table at comptime and is
//! asserted in the `comptime` block at the foot of this file, so the prose and
//! the tables cannot drift apart:
//!
//! | What | Count |
//! | --- | --- |
//! | public exports of the six owner modules | 417 |
//! | inventory rows | 420 |
//! | `direct_timed` exports / timed rows / cases | 318 / 321 / 2889 |
//! | `identical_canonical` exports | 96 |
//! | `compile_only` exports | 3 |
//! | accepted binary32 operations budgeted | 98 |
//! | accepted binary32 evaluations per full pass | 170016 |
//! | binding per-operation cost of one pass | `fmaf` at 52080 |
//!
//! The 420 inventory rows cover 417 exports because three helpers of
//! `vector_core` are timed more than once: `mapUnaryR` in the three result
//! element types its `R` parameter exists for (`f32`, `i32`, `i64`) and
//! `mapBinaryR` in the two (`f32` and the `bool` mask). `mapTernaryR`,
//! `mapUnaryExtra`, `mapUnaryExtra2` and `mapIntLanes` have one result shape
//! each and one row apiece.
//!
//! The binding number for the round's per-operation cap is `fmaf` at 52080
//! evaluations per pass, so this slice alone fits 20 passes under the renewed
//! 1048576 cap; the leaf slice spends 9600 of the same key per pass, so a
//! paired baseline/candidate pass of both costs 61680 and fits 17.

const std = @import("std");
const zmath = @import("zmath");
const common = @import("api_round_common.zig");

// ---------------------------------------------------------------------------
// Case bookkeeping
// ---------------------------------------------------------------------------

/// Every case in this slice calls a `zmath.vector` entry point, so the
/// canonical public owner is `vector` for all of them.
const namespace = "vector";

/// The prefix that keeps every case name in this bundle unique across the six
/// bundles of the round.
const bundle = "lanes";

/// Fixed call counts. There is no adaptive warm-up: the count is a property of
/// the case, chosen for the cost of the kernel, never tuned from a run.
const calls_default: u32 = 32;
/// The mid-cost kernels: real expansions, but not the exact-range ones.
const calls_mid: u32 = 16;
/// The exact-range kernels: the power family, `tgamma`, `lgamma`, `erf` and
/// `erfc` run the exact expansions.
const calls_exact: u32 = 8;

/// The lane widths every portable-vector route is measured at.
const widths = [_]usize{ 2, 4, 8 };

/// The three input regimes. They match the leaf bundle's regime names so one
/// word means the same operand class across the round.
const Regime = enum { normal, boundary, skewed };
const regimes = [_]Regime{ .normal, .boundary, .skewed };

/// The input magnitude class a route's lanes are drawn from. The class is part
/// of the case name, because a `log` measured on negative lanes measures the
/// NaN path and nothing else.
const Policy = enum {
    /// An ordinary spread of finite magnitudes either side of one.
    any,
    /// Magnitudes at or below one, the domain of the inverse circular and the
    /// `pi`-scaled functions.
    unit,
    /// Strictly positive, the domain of the logarithm, root and exponential
    /// families.
    positive,
    /// Tiny magnitudes, where `*m1` and `*p1` kernels work.
    small,
    /// Magnitudes from one upward, the domain of the inverse hyperbolic
    /// functions.
    large,
    /// A magnitude chosen to sit on a binary32 rounding tie, for the routes
    /// whose whole point is one correct rounding.
    tie,
};
const policies = [_]Policy{ .any, .unit, .positive, .small, .large, .tie };

/// The lane type a case runs on. The six narrowing routes have fixed `f64`
/// lanes and `f32` results, which is their own lane class.
const Format = enum { h, f, d };

fn laneTypeOf(comptime fmt: Format) type {
    return switch (fmt) {
        .h => f16,
        .f => f32,
        .d => f64,
    };
}

fn formatNameOf(comptime fmt: Format) []const u8 {
    return switch (fmt) {
        .h => "f16",
        .f => "f32",
        .d => "f64",
    };
}

// ---------------------------------------------------------------------------
// Lane input synthesis
//
// Lanes are addressed by index and built from their own encoding, never by
// rounding a wider value, so a binary16 lane is exactly the bit pattern the
// table names and no conversion helper enters the measured region. Every lane
// gets its own deterministic encoding from the harness index, so consecutive
// index values never repeat an operand and no lane pair can be folded into a
// compile-time constant.
// ---------------------------------------------------------------------------

/// The encoding facts of one lane format, so a lane is assembled from the
/// fields of its own format instead of being rounded out of a wider one.
const FloatSpec = struct {
    exponent_bits: u16,
    mantissa_bits: u16,
    bias: u16,
};

/// The encoding facts of the lane type `T`.
///
/// `std.builtin.Type.Float` declares only the total width of a float, so the
/// exponent and mantissa widths are read from `std.math`, which derives both
/// from that width. Every lane type this slice runs is one of `f16`, `f32` and
/// `f64`, and each is a plain IEEE-754 binary format, so those two widths plus
/// the bias are the whole encoding: `std.math.floatExponentMax` is the bias of
/// an IEEE-754 format, 15, 127 and 1023.
fn specOf(comptime T: type) FloatSpec {
    return .{
        .exponent_bits = @intCast(std.math.floatExponentBits(T)),
        .mantissa_bits = @intCast(std.math.floatMantissaBits(T)),
        .bias = @intCast(std.math.floatExponentMax(T)),
    };
}

/// A deterministic, non-affine spread of the runtime index.
///
/// The mix keeps consecutive harness indices on different fixtures without
/// folding: `index` is a runtime value, so the encoding a lane receives is
/// only known at run time.
fn scramble(index: usize, lane: usize) u64 {
    // The whole mix is defined modulo 2^64, so the sum of two wrapped
    // products is a wrapped sum: a checked `+` overflows for ordinary
    // indices and aborts the process before any case is measured.
    const wide: u64 = @as(u64, index) *% 0x9e37_79b9_7f4a_7c15 +%
        @as(u64, lane) *% 0xc2b2_ae3d_27d4_eb4f;
    var mixed = wide;
    mixed = (mixed ^ (mixed >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    mixed = (mixed ^ (mixed >> 27)) *% 0x94d0_49bb_1331_11eb;
    return mixed ^ (mixed >> 31);
}

fn exponentSpan(comptime spec: FloatSpec) u64 {
    return @as(u64, 1) << @intCast(spec.exponent_bits);
}

fn mantissaMask(comptime spec: FloatSpec) u64 {
    return (@as(u64, 1) << @intCast(spec.mantissa_bits)) - 1;
}

fn signBitOf(comptime spec: FloatSpec) u64 {
    return @as(u64, 1) << (@as(u64, spec.exponent_bits) + @as(u64, spec.mantissa_bits));
}

fn assemble(comptime spec: FloatSpec, sign: u64, exponent: u64, mantissa: u64) u64 {
    return (sign *% signBitOf(spec)) |
        ((exponent & (exponentSpan(spec) - 1)) << @intCast(spec.mantissa_bits)) |
        (mantissa & mantissaMask(spec));
}

/// How many exponents below the bias the `tie` policy's window spans.
///
/// Every tie lane has to stay a normal, finite, nonzero magnitude of its own
/// format, because that is the whole point of the policy: a lane on a
/// rounding tie is what the routes with one correct rounding are measured on.
/// The window reaches that many exponents below the bias, and the only
/// exponents below one are those from one up to the bias, so the window can be
/// no wider than the bias itself. Binary16 has fifteen of them, and a
/// seventeen-wide window there runs off the bottom into exponent zero, which is
/// a zero or a subnormal, and into exponent `-1`, which `assemble` masks to
/// the all-ones exponent and so becomes an infinity or a NaN. Capping the
/// window at the bias leaves binary32 and binary64 at seventeen and bounds
/// binary16 to `bias - 14 .. bias`, every one of them normal.
fn tieWindow(comptime spec: FloatSpec) u64 {
    return @min(@as(u64, 17), @as(u64, spec.bias));
}

/// The `normal` regime: an ordinary spread of finite magnitudes for the
/// route's own domain.
fn normalBits(comptime T: type, comptime policy: Policy, mixed: u64) u64 {
    const spec: FloatSpec = comptime specOf(T);
    const sign = (mixed >> 63) & 1;
    const mantissa = (mixed >> 11) & mantissaMask(spec);
    return switch (policy) {
        .any => assemble(spec, sign, @as(u64, spec.bias) + (mixed % 9) - 4, mantissa),
        .unit => assemble(spec, sign, @as(u64, spec.bias) - 1 - (mixed % 9), mantissa),
        .positive => assemble(spec, 0, @as(u64, spec.bias) + (mixed % 9) - 4, mantissa),
        .small => assemble(spec, sign, mixed % 6, mantissa),
        .large => assemble(spec, sign, @as(u64, spec.bias) + (mixed % 9), mantissa),
        .tie => assemble(spec, sign, @as(u64, spec.bias) - (mixed % tieWindow(spec)), @as(u64, 1) << @intCast(spec.mantissa_bits - 1)),
    };
}

/// The `boundary` regime: the special-value surface, cycled so that one vector
/// holds several different classes of special value at once.
fn boundaryBits(comptime T: type, comptime policy: Policy, mixed: u64, lane: usize) u64 {
    const spec: FloatSpec = comptime specOf(T);
    const sign = (mixed >> 63) & 1;
    const mantissa = mantissaMask(spec);
    const exponent = exponentSpan(spec) - 1;
    // The unit-domain kernels run a shorter cycle, so the extreme finite
    // magnitudes, which no inverse circular or `pi`-scaled kernel accepts
    // anyway, are spent on more of the subnormal and one-ulp-neighbour
    // specials that do sit inside their domain.
    const unit_window: u64 = switch (policy) {
        .unit, .small => 6,
        else => 10,
    };
    return switch ((mixed +% @as(u64, lane)) % unit_window) {
        0 => assemble(spec, 0, 0, 0),
        1 => assemble(spec, 1, 0, 0),
        2 => assemble(spec, 0, exponent, 0),
        3 => assemble(spec, 1, exponent, 0),
        4 => assemble(spec, 0, exponent, @as(u64, 1) << @intCast(spec.mantissa_bits - 1)),
        5 => assemble(spec, 0, 0, 1),
        6 => assemble(spec, 0, 1, @as(u64, spec.bias) - 1),
        7 => assemble(spec, sign, exponent, exponent - 1),
        8 => assemble(spec, sign, @as(u64, spec.bias), 0),
        9 => assemble(spec, sign, @as(u64, spec.bias), mantissa),
        else => assemble(spec, sign, 0, 1),
    };
}

/// The `skewed` regime: the adversarial surface. Buckets spread the lanes of
/// one vector across subnormals, exact powers of two, the huge finite range,
/// infinities and NaNs, with the sign alternating by lane, so the lanes of a
/// single call take different branches inside one unrolled loop.
fn skewedBits(comptime T: type, comptime policy: Policy, mixed: u64, lane: usize) u64 {
    const spec: FloatSpec = comptime specOf(T);
    const sign = ((mixed >> 62) +% @as(u64, lane)) & 1;
    const mantissa = mantissaMask(spec);
    const exponent = exponentSpan(spec) - 1;
    const single = @as(u64, 1) << @intCast(mixed % @as(u64, spec.mantissa_bits));
    const wide: u64 = 2 * @as(u64, spec.bias) - 1;
    return switch ((mixed +% @as(u64, lane)) % 6) {
        0 => assemble(spec, sign, mixed % 4, single),
        1 => assemble(spec, sign, @as(u64, spec.bias) + (mixed % 3) - 1, single),
        2 => assemble(spec, sign, wide - 2 - (mixed % 24), single),
        3 => assemble(spec, sign, exponent, mantissa & (mixed | 1)),
        4 => assemble(spec, sign, 0, 1),
        else => switch (policy) {
            .tie => assemble(spec, sign, @as(u64, spec.bias) - 12 + (mixed % 8), (mixed >> 3) & mantissa),
            else => assemble(spec, sign, @as(u64, spec.bias) - 12 + (mixed % 10), (mixed >> 3) & mantissa),
        },
    };
}

fn laneBitsOf(comptime T: type, comptime policy: Policy, comptime regime: Regime, index: usize, lane: usize) u64 {
    const mixed = scramble(index, lane);
    return switch (regime) {
        .normal => normalBits(T, policy, mixed),
        .boundary => boundaryBits(T, policy, mixed, lane),
        .skewed => skewedBits(T, policy, mixed, lane),
    };
}

fn fromLaneBits(comptime T: type, bits: u64) T {
    return switch (@bitSizeOf(T)) {
        16 => @bitCast(@as(u16, @truncate(bits))),
        32 => @bitCast(@as(u32, @truncate(bits))),
        64 => @bitCast(bits),
        else => @compileError("api_round_lanes: unsupported lane width"),
    };
}

/// One `@Vector(W, T)` whose lane `i` is built from its own encoding.
fn laneVector(comptime T: type, comptime W: usize, comptime policy: Policy, comptime regime: Regime, index: usize) @Vector(W, T) {
    var out: @Vector(W, T) = undefined;
    inline for (0..W) |lane| out[lane] = fromLaneBits(T, laneBitsOf(T, policy, regime, index, lane));
    return out;
}

/// The second operand of a binary route.
///
/// The `boundary` regime relates the second operand to the first rather than
/// drawing it independently, so a single call holds an equal pair, a negated
/// pair, a zero divisor and a NaN operand at the same time: those are the
/// cases `fmod`, `remainder`, `remquo`, `fdim`, `fmax`, `fmin`, `copySign`,
/// `nextAfter`, `totalOrder` and the `fmaximum*` family exist for.
fn secondBitsOf(comptime T: type, comptime policy: Policy, comptime regime: Regime, index: usize, lane: usize) u64 {
    const spec: FloatSpec = comptime specOf(T);
    const first = laneBitsOf(T, policy, regime, index, lane);
    return switch (regime) {
        .normal, .skewed => laneBitsOf(T, policy, regime, index +% 3 +% lane, lane),
        .boundary => switch ((scramble(index, lane) >> 40) % 6) {
            0 => first,
            1 => first ^ signBitOf(spec),
            2 => 0,
            3 => signBitOf(spec),
            4 => assemble(spec, 0, exponentSpan(spec) - 1, 0),
            else => assemble(spec, 0, exponentSpan(spec) - 1, @as(u64, 1) << @intCast(spec.mantissa_bits - 1)),
        },
    };
}

fn secondVector(comptime T: type, comptime W: usize, comptime policy: Policy, comptime regime: Regime, index: usize) @Vector(W, T) {
    var out: @Vector(W, T) = undefined;
    inline for (0..W) |lane| out[lane] = fromLaneBits(T, secondBitsOf(T, policy, regime, index, lane));
    return out;
}

fn thirdVector(comptime T: type, comptime W: usize, comptime policy: Policy, comptime regime: Regime, index: usize) @Vector(W, T) {
    var out: @Vector(W, T) = undefined;
    inline for (0..W) |lane| out[lane] = fromLaneBits(T, secondBitsOf(T, policy, regime, index +% 7, lane));
    return out;
}

// ---------------------------------------------------------------------------
// Non-float arguments
//
// Every one of these is a runtime value derived from the harness index, so a
// kernel that branches on its secondary argument takes a different branch on
// the next call. The tables span the exact range, the overflow range, the
// full-underflow range and the out-of-range degrees that report `ok == false`.
// ---------------------------------------------------------------------------

/// `ldexp` and `scalbn` scale amounts, at `i32` width.
const scale32 = [_]i32{ 0, 1, -1, 15, -15, 23, -23, 52, 127, -127, 1024, -1024, 4000, -4000, std.math.minInt(i32), std.math.maxInt(i32) };

/// `scalbln` takes the same scale amounts at `i64` width.
const scale64 = [_]i64{ 0, 1, -1, 15, -15, 23, -23, 52, 127, -127, 1023, -1023, 4096, -4096, std.math.minInt(i64), std.math.maxInt(i64) };

/// Integer degrees for the power family, including zero, one, odd and even
/// degrees, and degrees outside the implemented `[-64, 64]` window that report
/// `ok == false`.
const degrees = [_]i64{ 0, 1, 2, 3, -1, -2, -3, 4, 7, 8, 16, 31, 32, 63, 64, 65, -64, -65, 100, -100, 4096, -4096 };

/// `fromfp` rounding directions, all five of them.
const fromfp_rounds = [_]zmath.FromFpRound{
    .nearest_even,
    .nearest_from_zero,
    .toward_zero,
    .toward_positive,
    .toward_negative,
};

/// `fromfp` conversion widths, including the zero width every family rejects
/// and widths no binary format can represent.
const fromfp_widths = [_]u32{ 0, 1, 7, 8, 16, 24, 31, 32, 53, 63, 64, 65, 96, 127, 128, 4294967295 };

fn cycleOf(comptime table: anytype, comptime regime: Regime, index: usize, lane: usize) usize {
    const mixed = scramble(index, lane);
    return switch (regime) {
        .normal => @intCast((mixed >> 8) % table.len),
        .boundary => @intCast((mixed >> 8) % (if (table.len > 8) 8 else table.len)),
        .skewed => @intCast((mixed >> 8) % table.len),
    };
}

fn scaleArgOf(comptime I: type, comptime regime: Regime, index: usize) I {
    const table = if (I == i32) scale32 else scale64;
    return @intCast(table[cycleOf(table, regime, index, 0)]);
}

fn degreeArgOf(comptime regime: Regime, index: usize) i64 {
    return degrees[cycleOf(degrees, regime, index, 0)];
}

fn scaleLanes(comptime I: type, comptime W: usize, comptime regime: Regime, index: usize) @Vector(W, I) {
    const table = if (I == i32) scale32 else scale64;
    var out: @Vector(W, I) = undefined;
    inline for (0..W) |lane| out[lane] = @intCast(table[cycleOf(table, regime, index, lane)]);
    return out;
}

fn degreeLanes(comptime W: usize, comptime regime: Regime, index: usize) @Vector(W, i64) {
    var out: @Vector(W, i64) = undefined;
    inline for (0..W) |lane| out[lane] = degrees[cycleOf(degrees, regime, index, lane)];
    return out;
}

fn fromfpRoundOf(index: usize) zmath.FromFpRound {
    return fromfp_rounds[(scramble(index, 0) >> 8) % fromfp_rounds.len];
}

fn fromfpWidthOf(index: usize) u32 {
    return fromfp_widths[(scramble(index, 1) >> 8) % fromfp_widths.len];
}

/// `nextToward` targets: both zeros, both infinities, the extreme finite
/// magnitudes of binary16 and binary32, and an ordinary spread either side of
/// one, so one call's successor search sees the whole tolerance surface of
/// every format instead of one direction.
const toward_table = [_]f64{
    0.0,            -0.0,
    1.0,            -1.0,
    65504.0,        -65504.0,
    0x1.fffffep127, -0x1.fffffep127,
    3.5,            -3.5,
    1.0e300,        -1.0e300,
};

fn towardOf(comptime regime: Regime, index: usize) f64 {
    return toward_table[cycleOf(toward_table, regime, index, 0)];
}

// ---------------------------------------------------------------------------
// The binary32 charge table
//
// `Case.f32` is a slice, so every charge needs static storage. The pool below
// is one top-level constant with one slot per (charge pattern, lane count)
// pair, and each case points a slice at its own slot. A pattern is the set of
// accepted binary32 kernels one lane of a route reaches, with the number of
// evaluations per lane; the verbatim public name of each kernel is the ledger
// key, so the same kernel reached here at width eight and from `zmath.scalar`
// in the leaf slice share one global cap entry.
// ---------------------------------------------------------------------------

/// One accepted binary32 kernel and the number of evaluations ONE lane of a
/// route reaches.
const ChargeRow = struct {
    operation: []const u8,
    per_lane: u32,
};

const Charge = enum {
    /// The route reaches no accepted binary32 kernel.
    none,
    /// One tag per distinct per-lane charge this bundle can charge. The
    /// pattern a tag names is `charge_patterns[@intFromEnum(tag)]`, so the two
    /// tables cannot drift apart.
    absf,
    acosf,
    acoshf,
    acospif,
    asinhf,
    asinpif,
    atan2f,
    atan2pif,
    atanhf,
    atanpif,
    canonicalizef,
    cbrtf,
    ceilf,
    compoundnf,
    copySignf,
    coshf,
    erfcf,
    erff,
    exp10f,
    exp10m1f,
    exp2f,
    exp2m1f,
    expf,
    expm1f,
    /// The six exact binary64-to-binary32 narrowing keys. Each has two public
    /// spellings that run the one accepted exact narrowing kernel, so the root
    /// route and the portable `faddv`-style route charge one key between them
    /// and never two. The key is the `f32xxf64` spelling, the one the root
    /// surface of `zmath` exports for the same kernel; the short C23 spelling
    /// (`fadd`, the symbol `faddv` itself calls) is the alias, not a second
    /// key. These six keep the slot of the short spelling they replace, so
    /// `charge_patterns` stays in the order of this enum.
    f32addf64,
    fdimf,
    f32divf64,
    f32fmaf64,
    floorf,
    fmaf,
    fmaf_2,
    fmaf_3,
    fmaf_4,
    fmaf_5,
    fmaf_6,
    fmaxf,
    fmaximum_mag_numf,
    fmaximum_magf,
    fmaximum_numf,
    fmaximumf,
    fminf,
    fminimum_mag_numf,
    fminimum_magf,
    fminimum_numf,
    fminimumf,
    fmodf,
    f32mulf64,
    frexpf,
    fromfpf,
    fromfpxf,
    f32sqrtf64,
    f32subf64,
    getPayloadf,
    hypotf,
    ilogbf,
    ldexpf,
    llogbf,
    llrintf,
    llroundf,
    log10f,
    log10p1f,
    log1pf,
    log2f,
    log2p1f,
    logbf,
    logf,
    lrintf,
    lroundf,
    modff,
    nearbyintf,
    nextAfterf,
    nextDownf,
    nextTowardf,
    nextUpf,
    powf,
    pownf,
    remainderf,
    remquof,
    rootnf,
    roundf,
    rsqrtf,
    scalblnf,
    scalbnf,
    setPayloadSigf,
    setPayloadf,
    sinf,
    sinhf,
    sinpif,
    sqrtf,
    tanpif,
    tgammaf,
    totalOrderMagf,
    totalOrderf,
    truncf,
    ufromfpf,
    ufromfpxf,
    asinf_fmaf,
    atanf_fmaf,
    cosf_fmaf,
    cospif_fmaf,
    lgammaf_fmaf,
    tanf_fmaf,
    tanhf_fmaf,
};

/// The accepted binary32 kernels and how many evaluations ONE lane reaches, in
/// the order of `Charge`.
const charge_patterns = [_][]const ChargeRow{
    &.{},
    &.{
        .{ .operation = "absf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "acosf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "acoshf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "acospif", .per_lane = 1 },
    },
    &.{
        .{ .operation = "asinhf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "asinpif", .per_lane = 1 },
    },
    &.{
        .{ .operation = "atan2f", .per_lane = 1 },
    },
    &.{
        .{ .operation = "atan2pif", .per_lane = 1 },
    },
    &.{
        .{ .operation = "atanhf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "atanpif", .per_lane = 1 },
    },
    &.{
        .{ .operation = "canonicalizef", .per_lane = 1 },
    },
    &.{
        .{ .operation = "cbrtf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "ceilf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "compoundnf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "copySignf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "coshf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "erfcf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "erff", .per_lane = 1 },
    },
    &.{
        .{ .operation = "exp10f", .per_lane = 1 },
    },
    &.{
        .{ .operation = "exp10m1f", .per_lane = 1 },
    },
    &.{
        .{ .operation = "exp2f", .per_lane = 1 },
    },
    &.{
        .{ .operation = "exp2m1f", .per_lane = 1 },
    },
    &.{
        .{ .operation = "expf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "expm1f", .per_lane = 1 },
    },
    &.{
        .{ .operation = "f32addf64", .per_lane = 1 },
    },
    &.{
        .{ .operation = "fdimf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "f32divf64", .per_lane = 1 },
    },
    &.{
        .{ .operation = "f32fmaf64", .per_lane = 1 },
    },
    &.{
        .{ .operation = "floorf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "fmaf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "fmaf", .per_lane = 2 },
    },
    &.{
        .{ .operation = "fmaf", .per_lane = 3 },
    },
    &.{
        .{ .operation = "fmaf", .per_lane = 4 },
    },
    &.{
        .{ .operation = "fmaf", .per_lane = 5 },
    },
    &.{
        .{ .operation = "fmaf", .per_lane = 6 },
    },
    &.{
        .{ .operation = "fmaxf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "fmaximum_mag_numf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "fmaximum_magf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "fmaximum_numf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "fmaximumf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "fminf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "fminimum_mag_numf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "fminimum_magf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "fminimum_numf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "fminimumf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "fmodf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "f32mulf64", .per_lane = 1 },
    },
    &.{
        .{ .operation = "frexpf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "fromfpf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "fromfpxf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "f32sqrtf64", .per_lane = 1 },
    },
    &.{
        .{ .operation = "f32subf64", .per_lane = 1 },
    },
    &.{
        .{ .operation = "getPayloadf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "hypotf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "ilogbf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "ldexpf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "llogbf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "llrintf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "llroundf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "log10f", .per_lane = 1 },
    },
    &.{
        .{ .operation = "log10p1f", .per_lane = 1 },
    },
    &.{
        .{ .operation = "log1pf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "log2f", .per_lane = 1 },
    },
    &.{
        .{ .operation = "log2p1f", .per_lane = 1 },
    },
    &.{
        .{ .operation = "logbf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "logf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "lrintf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "lroundf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "modff", .per_lane = 1 },
    },
    &.{
        .{ .operation = "nearbyintf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "nextAfterf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "nextDownf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "nextTowardf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "nextUpf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "powf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "pownf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "remainderf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "remquof", .per_lane = 1 },
    },
    &.{
        .{ .operation = "rootnf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "roundf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "rsqrtf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "scalblnf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "scalbnf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "setPayloadSigf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "setPayloadf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "sinf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "sinhf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "sinpif", .per_lane = 1 },
    },
    &.{
        .{ .operation = "sqrtf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "tanpif", .per_lane = 1 },
    },
    &.{
        .{ .operation = "tgammaf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "totalOrderMagf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "totalOrderf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "truncf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "ufromfpf", .per_lane = 1 },
    },
    &.{
        .{ .operation = "ufromfpxf", .per_lane = 1 },
    },
    &.{ .{ .operation = "asinf", .per_lane = 1 }, .{ .operation = "fmaf", .per_lane = 1 } },
    &.{ .{ .operation = "atanf", .per_lane = 1 }, .{ .operation = "fmaf", .per_lane = 1 } },
    &.{ .{ .operation = "cosf", .per_lane = 1 }, .{ .operation = "fmaf", .per_lane = 1 } },
    &.{ .{ .operation = "cospif", .per_lane = 1 }, .{ .operation = "fmaf", .per_lane = 1 } },
    &.{ .{ .operation = "lgammaf", .per_lane = 1 }, .{ .operation = "fmaf", .per_lane = 1 } },
    &.{ .{ .operation = "tanf", .per_lane = 1 }, .{ .operation = "fmaf", .per_lane = 1 } },
    &.{ .{ .operation = "tanhf", .per_lane = 1 }, .{ .operation = "fmaf", .per_lane = 1 } },
};

/// The widest pattern in `charge_patterns`, so one fixed slot per
/// (pattern, lane count) pair holds every entry of every pattern.
const max_charge_rows = blk: {
    var widest: usize = 0;
    for (charge_patterns) |rows| {
        if (rows.len > widest) widest = rows.len;
    }
    break :blk widest;
};

const ChargeSlot = struct {
    rows: [max_charge_rows]common.Charge,
};

const charge_pool: [charge_patterns.len * widths.len]ChargeSlot = buildChargePool();

fn buildChargePool() [charge_patterns.len * widths.len]ChargeSlot {
    var pool: [charge_patterns.len * widths.len]ChargeSlot = undefined;
    inline for (charge_patterns, 0..) |rows, key| {
        inline for (widths, 0..) |width, slot| {
            const index = key * widths.len + slot;
            inline for (rows, 0..) |row, at| {
                pool[index].rows[at] = .{
                    .operation = row.operation,
                    .count = @intCast(row.per_lane * width),
                };
            }
        }
    }
    return pool;
}

fn widthSlot(comptime width: usize) usize {
    inline for (widths, 0..) |candidate, slot| {
        if (candidate == width) return slot;
    }
    @compileError("api_round_lanes: a portable-vector case uses an unmeasured lane width");
}

/// The charge for one `invoke` call at `width`: every accepted binary32 kernel
/// of the pattern, once per lane.
fn chargeFor(comptime key: Charge, comptime width: usize) []const common.Charge {
    const rows = switch (key) {
        inline else => |tag| charge_patterns[@intFromEnum(tag)],
    };
    if (rows.len == 0) return chargeNone();
    const slot: *const ChargeSlot = &charge_pool[@intFromEnum(key) * widths.len + widthSlot(width)];
    return slot.rows[0..rows.len];
}

/// The charge for a case that reaches no binary32 kernel.
fn chargeNone() []const common.Charge {
    return &[_]common.Charge{};
}

/// The accepted binary32 kernels whose evaluation charges something, with the
/// per-lane pattern of the route that reaches them. Every name is the verbatim
/// public symbol the leaf slice charges under, so one kernel opens one global
/// ledger entry no matter which slice or route reached it.
///
/// Six rows name a public symbol that is an ALIAS rather than the ledger key
/// itself: `fadd`, `fsub`, `fmul`, `fdiv`, `ffma` and `fsqrt` are the short
/// C23 spellings `faddv` and its siblings call, and each runs the identical
/// exact narrowing kernel as the `f32xxf64` spelling the root surface exports.
/// They charge that one kernel under its `f32xxf64` key, so this bundle's
/// portable route and the leaf bundle's root route reserve one entry between
/// them instead of two.
///
/// A kernel absent from this table reaches no accepted binary32 kernel, so its
/// route charges nothing. Every kernel a family names is either listed here or
/// listed in `zero_charge_kernels`, and the comptime check at the foot of this
/// file fails if a family names a kernel in neither table.
const kernel_charges = [_]struct { kernel: []const u8, charge: Charge }{
    .{ .kernel = "absf", .charge = .absf },
    .{ .kernel = "acosf", .charge = .acosf },
    .{ .kernel = "acosh", .charge = .fmaf_4 },
    .{ .kernel = "acoshf", .charge = .acoshf },
    .{ .kernel = "acoshh", .charge = .fmaf_5 },
    .{ .kernel = "acospif", .charge = .acospif },
    .{ .kernel = "acospih", .charge = .fmaf_4 },
    .{ .kernel = "asinf", .charge = .asinf_fmaf },
    .{ .kernel = "asinhf", .charge = .asinhf },
    .{ .kernel = "asinhh", .charge = .fmaf_6 },
    .{ .kernel = "asinpif", .charge = .asinpif },
    .{ .kernel = "asinpih", .charge = .fmaf_3 },
    .{ .kernel = "atan2f", .charge = .atan2f },
    .{ .kernel = "atan2pif", .charge = .atan2pif },
    .{ .kernel = "atanf", .charge = .atanf_fmaf },
    .{ .kernel = "atanh", .charge = .fmaf_4 },
    .{ .kernel = "atanhf", .charge = .atanhf },
    .{ .kernel = "atanhh", .charge = .fmaf_5 },
    .{ .kernel = "atanpif", .charge = .atanpif },
    .{ .kernel = "atanpih", .charge = .fmaf_4 },
    .{ .kernel = "canonicalizef", .charge = .canonicalizef },
    .{ .kernel = "cbrtf", .charge = .cbrtf },
    .{ .kernel = "cbrth", .charge = .cbrtf },
    .{ .kernel = "ceilf", .charge = .ceilf },
    .{ .kernel = "compoundnf", .charge = .compoundnf },
    .{ .kernel = "copySignf", .charge = .copySignf },
    .{ .kernel = "cosf", .charge = .cosf_fmaf },
    .{ .kernel = "cosh", .charge = .fmaf },
    .{ .kernel = "coshf", .charge = .coshf },
    .{ .kernel = "coshh", .charge = .fmaf },
    .{ .kernel = "cospif", .charge = .cospif_fmaf },
    .{ .kernel = "cospih", .charge = .fmaf },
    .{ .kernel = "erfcf", .charge = .erfcf },
    .{ .kernel = "erff", .charge = .erff },
    .{ .kernel = "exp10f", .charge = .exp10f },
    .{ .kernel = "exp10m1f", .charge = .exp10m1f },
    .{ .kernel = "exp10m1h", .charge = .fmaf_2 },
    .{ .kernel = "exp2f", .charge = .exp2f },
    .{ .kernel = "exp2m1f", .charge = .exp2m1f },
    .{ .kernel = "exp2m1h", .charge = .fmaf_2 },
    .{ .kernel = "expf", .charge = .expf },
    .{ .kernel = "expm1f", .charge = .expm1f },
    .{ .kernel = "expm1h", .charge = .fmaf_2 },
    .{ .kernel = "fadd", .charge = .f32addf64 },
    .{ .kernel = "fdimf", .charge = .fdimf },
    .{ .kernel = "fdiv", .charge = .f32divf64 },
    .{ .kernel = "ffma", .charge = .f32fmaf64 },
    .{ .kernel = "floorf", .charge = .floorf },
    .{ .kernel = "fmaf", .charge = .fmaf },
    .{ .kernel = "fmaxf", .charge = .fmaxf },
    .{ .kernel = "fmaximum_mag_numf", .charge = .fmaximum_mag_numf },
    .{ .kernel = "fmaximum_magf", .charge = .fmaximum_magf },
    .{ .kernel = "fmaximum_numf", .charge = .fmaximum_numf },
    .{ .kernel = "fmaximumf", .charge = .fmaximumf },
    .{ .kernel = "fminf", .charge = .fminf },
    .{ .kernel = "fminimum_mag_numf", .charge = .fminimum_mag_numf },
    .{ .kernel = "fminimum_magf", .charge = .fminimum_magf },
    .{ .kernel = "fminimum_numf", .charge = .fminimum_numf },
    .{ .kernel = "fminimumf", .charge = .fminimumf },
    .{ .kernel = "fmodf", .charge = .fmodf },
    .{ .kernel = "fmul", .charge = .f32mulf64 },
    .{ .kernel = "frexpf", .charge = .frexpf },
    .{ .kernel = "fromfpf", .charge = .fromfpf },
    .{ .kernel = "fromfpxf", .charge = .fromfpxf },
    .{ .kernel = "fsqrt", .charge = .f32sqrtf64 },
    .{ .kernel = "fsub", .charge = .f32subf64 },
    .{ .kernel = "getPayloadf", .charge = .getPayloadf },
    .{ .kernel = "hypotf", .charge = .hypotf },
    .{ .kernel = "ilogbf", .charge = .ilogbf },
    .{ .kernel = "ldexpf", .charge = .ldexpf },
    .{ .kernel = "lgammaf", .charge = .lgammaf_fmaf },
    .{ .kernel = "llogbf", .charge = .llogbf },
    .{ .kernel = "llrintf", .charge = .llrintf },
    .{ .kernel = "llroundf", .charge = .llroundf },
    .{ .kernel = "log10f", .charge = .log10f },
    .{ .kernel = "log10p1f", .charge = .log10p1f },
    .{ .kernel = "log10p1h", .charge = .fmaf_4 },
    .{ .kernel = "log1pf", .charge = .log1pf },
    .{ .kernel = "log1ph", .charge = .fmaf_4 },
    .{ .kernel = "log2f", .charge = .log2f },
    .{ .kernel = "log2p1f", .charge = .log2p1f },
    .{ .kernel = "log2p1h", .charge = .fmaf_4 },
    .{ .kernel = "logbf", .charge = .logbf },
    .{ .kernel = "logf", .charge = .logf },
    .{ .kernel = "logp1f", .charge = .log1pf },
    .{ .kernel = "logp1h", .charge = .fmaf_4 },
    .{ .kernel = "lrintf", .charge = .lrintf },
    .{ .kernel = "lroundf", .charge = .lroundf },
    .{ .kernel = "modff", .charge = .modff },
    .{ .kernel = "nearbyintf", .charge = .nearbyintf },
    .{ .kernel = "nextAfterf", .charge = .nextAfterf },
    .{ .kernel = "nextDownf", .charge = .nextDownf },
    .{ .kernel = "nextTowardf", .charge = .nextTowardf },
    .{ .kernel = "nextUpf", .charge = .nextUpf },
    .{ .kernel = "powf", .charge = .powf },
    .{ .kernel = "pownf", .charge = .pownf },
    .{ .kernel = "powrf", .charge = .powf },
    .{ .kernel = "remainderf", .charge = .remainderf },
    .{ .kernel = "remquof", .charge = .remquof },
    .{ .kernel = "rintf", .charge = .nearbyintf },
    .{ .kernel = "rootnf", .charge = .rootnf },
    .{ .kernel = "roundevenf", .charge = .nearbyintf },
    .{ .kernel = "roundf", .charge = .roundf },
    .{ .kernel = "rsqrtf", .charge = .rsqrtf },
    .{ .kernel = "scalblnf", .charge = .scalblnf },
    .{ .kernel = "scalbnf", .charge = .scalbnf },
    .{ .kernel = "setPayloadSigf", .charge = .setPayloadSigf },
    .{ .kernel = "setPayloadf", .charge = .setPayloadf },
    .{ .kernel = "sinf", .charge = .sinf },
    .{ .kernel = "sinh", .charge = .fmaf },
    .{ .kernel = "sinhf", .charge = .sinhf },
    .{ .kernel = "sinhh", .charge = .fmaf },
    .{ .kernel = "sinpif", .charge = .sinpif },
    .{ .kernel = "sinpih", .charge = .fmaf },
    .{ .kernel = "sqrtf", .charge = .sqrtf },
    .{ .kernel = "tanf", .charge = .tanf_fmaf },
    .{ .kernel = "tanh", .charge = .fmaf_2 },
    .{ .kernel = "tanhf", .charge = .tanhf_fmaf },
    .{ .kernel = "tanpif", .charge = .tanpif },
    .{ .kernel = "tanpih", .charge = .fmaf_2 },
    .{ .kernel = "tgammaf", .charge = .tgammaf },
    .{ .kernel = "totalOrderMagf", .charge = .totalOrderMagf },
    .{ .kernel = "totalOrderf", .charge = .totalOrderf },
    .{ .kernel = "truncf", .charge = .truncf },
    .{ .kernel = "ufromfpf", .charge = .ufromfpf },
    .{ .kernel = "ufromfpxf", .charge = .ufromfpxf },
};

/// The kernels this bundle reaches that provably charge no accepted binary32
/// kernel, listed so an empty charge is a recorded decision and not a gap.
/// Three groups:
///
/// - The binary64 spellings. They run the binary64 engine or no engine at all,
///   so they never charge by construction.
/// - The binary16 and binary32 spellings that are pure bit rules, table
///   lookups or their own arithmetic, even though a sibling of the same family
///   does charge. `absh` is `bits & magnitude_mask`; `tanhh`, `lgammah`,
///   `erfh`, `erfch`, `tgammah`, `powh`, `atan2h`, `atan2pih` and `fmah` reach
///   no binary32 kernel. `erfh` widens to binary64 and runs its own degree-eight
///   polynomial, and `fmah` reaches the fused-multiply-add engine only through
///   its own body arithmetic.
/// - The `ilogb`, `llogb` and `logb` binary16 spellings, which decompose the
///   encoding without a binary32 evaluation.
const zero_charge_kernels = [_][]const u8{
    "absh",              "asinh",             "atan2h",        "atan2pih",       "canonicalizeh", "ceilh",             "compoundnh",        "copySignh",
    "erfch",             "erfh",              "exp10h",        "exp2h",          "exph",          "fdimh",             "floorh",            "fmah",
    "fmaxh",             "fmaximum_mag_numh", "fmaximum_magh", "fmaximum_numh",  "fmaximumh",     "fminh",             "fminimum_mag_numh", "fminimum_magh",
    "fminimum_numh",     "fminimumh",         "fmodh",         "frexph",         "fromfph",       "fromfpxh",          "getPayloadh",       "hypoth",
    "ilogbh",            "ldexph",            "lgammah",       "llogbh",         "llrinth",       "llroundh",          "log10h",            "log2h",
    "logbh",             "logh",              "lrinth",        "lroundh",        "modfh",         "nearbyinth",        "nextAfterh",        "nextDownh",
    "nextTowardh",       "nextUph",           "powh",          "pownh",          "powrh",         "remainderh",        "remquoh",           "rinth",
    "rootnh",            "roundevenh",        "roundh",        "rsqrth",         "scalblnh",      "scalbnh",           "setPayloadSigh",    "setPayloadh",
    "sqrth",             "tanhh",             "tgammah",       "totalOrderMagh", "totalOrderh",   "trunch",            "ufromfph",          "ufromfpxh",
    "absd",              "acosd",             "acoshd",        "acospid",        "asind",         "asinhd",            "asinpid",           "atan2d",
    "atan2pid",          "atand",             "atanhd",        "atanpid",        "canonicalized", "cbrtd",             "ceild",             "compoundnd",
    "copySignd",         "cosd",              "coshd",         "cospid",         "erfcd",         "erfd",              "exp10d",            "exp10m1d",
    "exp2d",             "exp2m1d",           "expd",          "expm1d",         "fdimd",         "floord",            "fmad",              "fmaxd",
    "fmaximum_mag_numd", "fmaximum_magd",     "fmaximum_numd", "fmaximumd",      "fmind",         "fminimum_mag_numd", "fminimum_magd",     "fminimum_numd",
    "fminimumd",         "fmodd",             "frexpd",        "fromfpd",        "fromfpxd",      "getPayloadd",       "hypotd",            "ilogbd",
    "ldexpd",            "lgammad",           "llogbd",        "llrintd",        "llroundd",      "log10d",            "log10p1d",          "log1pd",
    "log2d",             "log2p1d",           "logbd",         "logd",           "logp1d",        "lrintd",            "lroundd",           "modfd",
    "nearbyintd",        "nextAfterd",        "nextDownd",     "nextTowardd",    "nextUpd",       "powd",              "pownd",             "powrd",
    "remainderd",        "remquod",           "rintd",         "rootnd",         "roundd",        "roundevend",        "rsqrtd",            "scalblnd",
    "scalbnd",           "setPayloadSigd",    "setPayloadd",   "sind",           "sinhd",         "sinpid",            "sqrtd",             "tand",
    "tanhd",             "tanpid",            "tgammad",       "totalOrderMagd", "totalOrderd",   "truncd",            "ufromfpd",          "ufromfpxd",
};

/// The per-lane charge of evaluating one accepted binary32 kernel.
fn chargeOfKernel(comptime kernel: []const u8) Charge {
    if (kernel.len == 0) return .none;
    inline for (kernel_charges) |row| {
        if (std.mem.eql(u8, row.kernel, kernel)) return row.charge;
    }
    return .none;
}

/// True when `kernel` is named by one of the two charge tables, so an entry
/// point can never reach a kernel whose binary32 charge was left unstated.
fn declaresKernel(comptime kernel: []const u8) bool {
    if (kernel.len == 0) return true;
    for (kernel_charges) |row| {
        if (std.mem.eql(u8, row.kernel, kernel)) return true;
    }
    for (zero_charge_kernels) |name| {
        if (std.mem.eql(u8, name, kernel)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// The owner modules and the family table
//
// One `Family` row names an operation family, the four public entry points that
// family declares and the canonical kernel each spelling reaches. Everything
// below is derived from those rows, so the inventory and the case rows cannot
// disagree: there is one list of export names, and the cases, the
// classifications, the reasons and the budget all read it.
// ---------------------------------------------------------------------------

/// The six modules that own the portable-vector entry points.
const Owner = enum {
    vector,
    ieee_family,
    intarg,
    narrow,
    struct_family,
    core,

    /// The Zig module itself, so a row can reach a declaration by name.
    fn container(owner: Owner) type {
        return switch (owner) {
            .vector => zmath.vector,
            .ieee_family => zmath.vector.ieee_family,
            .intarg => zmath.vector.intarg,
            .narrow => zmath.vector.narrow,
            .struct_family => zmath.vector.struct_family,
            .core => zmath.vector.core,
        };
    }

    /// The source file that declares the entry points.
    fn file(owner: Owner) []const u8 {
        return switch (owner) {
            .vector => "vector.zig",
            .ieee_family => "vector_ieee.zig",
            .intarg => "vector_intarg.zig",
            .narrow => "vector_narrow.zig",
            .struct_family => "vector_struct.zig",
            .core => "vector_core.zig",
        };
    }

    /// The public declaration itself, so the timed call is the real entry point
    /// and not a second spelling of it.
    fn decl(comptime owner: Owner, comptime name: []const u8) @TypeOf(@field(container(owner), name)) {
        return @field(container(owner), name);
    }
};

/// How one entry point consumes its lanes.
const Shape = enum {
    /// One lane vector in, and either a lane vector or a lane-ordered result
    /// array out. The float-to-float, integer-returning, boolean-returning,
    /// result-struct and narrowing unary routes all land here.
    unary,
    /// Two lane vectors in.
    binary,
    /// Three lane vectors in.
    ternary,
    /// One lane vector in and one broadcast runtime scalar.
    extra,
    /// One lane vector in and two broadcast runtime scalars.
    extra2,
    /// One lane vector in and a per-lane integer vector.
    lanes,
    /// A comptime type query: there is no runtime evaluation to time.
    type_query,
    /// The six shared `vector_core` helpers, one shape each.
    core_unary,
    core_binary,
    core_ternary,
    core_extra,
    core_extra2,
    core_lanes,
};

/// The non-lane argument a `vector_intarg` entry point takes.
const Extra = enum {
    none,
    /// The broadcast `i32` exponent of `ldexp` and `scalbn`, and the `@Vector`
    /// of `i32` exponents of their `Lanes` forms.
    scale32,
    /// The broadcast `i64` exponent of `scalbln`, and the `@Vector` of `i64`
    /// exponents of its `Lanes` form.
    scale64,
    /// The broadcast `i64` degree of the power family, and the `@Vector` of
    /// `i64` degrees of their `Lanes` forms.
    degree,
    /// The broadcast `f64` target of `nextToward`.
    toward,
    /// The broadcast `FromFpRound` direction and `u32` width of the `fromfp`
    /// family.
    fromfp,
};

/// How one export is accounted for.
const Class = enum {
    /// The canonical route. Its cases call the export itself.
    direct_timed,
    /// Not timed separately: the comptime lane-type dispatch lands on the
    /// identical canonical route a per-format spelling reaches, so timing it
    /// again would measure that route twice.
    identical_canonical,
    /// No runtime evaluation exists to time.
    compile_only,
};

const Family = struct {
    owner: Owner,
    /// The operation name the entry points are built from: `absv`, `abshv`,
    /// `absfv` and `absdv` are all `abs` plus a spelling suffix.
    base: []const u8,
    shape: Shape,
    /// The magnitude class the `normal` regime draws from. The `boundary` and
    /// `skewed` regimes carry the special-value surface whatever the policy is.
    policy: Policy,
    /// The fixed invocation count, chosen from the cost of the kernel and
    /// never tuned from a run.
    calls: u32,
    /// The accepted binary32 kernel this family reaches, which is the whole
    /// charge of the binary32 lane format. Empty for a comptime type query.
    kernel: []const u8,
    extra: Extra = .none,
    /// The family declares a per-lane integer vector form under a `Lanes`
    /// suffix as well as the broadcast form.
    lanes_form: bool = false,
    /// The family declares no binary16 spelling, because `BASEhv` already names
    /// the generic entry point of another family. This is true of `sin`, `cos`,
    /// `tan`, `asin`, `acos` and `atan`, whose `hv` names are the generics of
    /// `sinh`, `cosh`, `tanh`, `asinh`, `acosh` and `atanh`.
    no_h: bool = false,
    /// The row is one fixed-shape entry point with no generic spelling and no
    /// per-format forms.
    fixed: bool = false,
    /// The lane format a fixed row runs on.
    format: Format = .f,
    /// The result element type a `vector_core` row is instantiated with.
    result: []const u8 = "",
};

fn lanesTail(comptime family: Family) []const u8 {
    return if (family.lanes_form) "Lanes" else "";
}

/// The kernel-name stem of a family: the accepted binary32 kernel it reaches,
/// without its trailing `f`. That is the family base for every route whose
/// entry points and kernels share one spelling. The six `vector_ieee`
/// `fmaximum*`/`fminimum*` aliases are the exception: their entry points are
/// camelCase and their kernels are the snake_case symbols they alias, so the
/// stem is the kernel spelling, never the entry-point spelling.
fn kernelStem(comptime family: Family) []const u8 {
    return family.kernel[0 .. family.kernel.len - 1];
}

fn formatIndex(comptime fmt: Format) usize {
    return switch (fmt) {
        .h => 0,
        .f => 1,
        .d => 2,
    };
}

fn widthTag(comptime width: usize) []const u8 {
    return switch (width) {
        2 => "w2",
        4 => "w4",
        8 => "w8",
        else => @compileError("api_round_lanes: a portable-vector case uses an unmeasured lane width"),
    };
}

// ---------------------------------------------------------------------------
// The family table
//
// 55 families in `vector.zig`, 16 in `vector_ieee.zig`, 13 in
// `vector_struct.zig`, 17 broadcast and per-lane families plus three comptime
// type queries in `vector_intarg.zig`, the `fma` family and six fixed-shape
// narrowing routes in `vector_narrow.zig`, and nine instantiations of the six
// `vector_core` helpers. Expanding them names 417 distinct exports and no
// others; `comptime` below checks that against the source.
// ---------------------------------------------------------------------------

const families = [_]Family{
    // zmath.vector: the float-to-float surface, `@Vector(N, T)` to `@Vector(N, T)`.
    .{ .owner = .vector, .base = "abs", .shape = .unary, .policy = .any, .calls = calls_default, .kernel = "absf" },
    .{ .owner = .vector, .base = "exp", .shape = .unary, .policy = .positive, .calls = calls_mid, .kernel = "expf" },
    .{ .owner = .vector, .base = "exp10", .shape = .unary, .policy = .positive, .calls = calls_mid, .kernel = "exp10f" },
    .{ .owner = .vector, .base = "exp2m1", .shape = .unary, .policy = .positive, .calls = calls_mid, .kernel = "exp2m1f" },
    .{ .owner = .vector, .base = "exp10m1", .shape = .unary, .policy = .positive, .calls = calls_mid, .kernel = "exp10m1f" },
    .{ .owner = .vector, .base = "erfc", .shape = .unary, .policy = .any, .calls = calls_exact, .kernel = "erfcf" },
    .{ .owner = .vector, .base = "tgamma", .shape = .unary, .policy = .any, .calls = calls_exact, .kernel = "tgammaf" },
    .{ .owner = .vector, .base = "log", .shape = .unary, .policy = .positive, .calls = calls_mid, .kernel = "logf" },
    .{ .owner = .vector, .base = "log2", .shape = .unary, .policy = .positive, .calls = calls_mid, .kernel = "log2f" },
    .{ .owner = .vector, .base = "log2p1", .shape = .unary, .policy = .positive, .calls = calls_mid, .kernel = "log2p1f" },
    .{ .owner = .vector, .base = "log10", .shape = .unary, .policy = .positive, .calls = calls_mid, .kernel = "log10f" },
    .{ .owner = .vector, .base = "log10p1", .shape = .unary, .policy = .positive, .calls = calls_mid, .kernel = "log10p1f" },
    .{ .owner = .vector, .base = "erf", .shape = .unary, .policy = .any, .calls = calls_exact, .kernel = "erff" },
    .{ .owner = .vector, .base = "sin", .shape = .unary, .policy = .any, .calls = calls_mid, .kernel = "sinf", .no_h = true },
    .{ .owner = .vector, .base = "sinh", .shape = .unary, .policy = .any, .calls = calls_mid, .kernel = "sinhf" },
    .{ .owner = .vector, .base = "sinpi", .shape = .unary, .policy = .unit, .calls = calls_mid, .kernel = "sinpif" },
    .{ .owner = .vector, .base = "cos", .shape = .unary, .policy = .any, .calls = calls_mid, .kernel = "cosf", .no_h = true },
    .{ .owner = .vector, .base = "cosh", .shape = .unary, .policy = .any, .calls = calls_mid, .kernel = "coshf" },
    .{ .owner = .vector, .base = "cospi", .shape = .unary, .policy = .unit, .calls = calls_mid, .kernel = "cospif" },
    .{ .owner = .vector, .base = "acosh", .shape = .unary, .policy = .small, .calls = calls_mid, .kernel = "acoshf" },
    .{ .owner = .vector, .base = "tan", .shape = .unary, .policy = .any, .calls = calls_mid, .kernel = "tanf", .no_h = true },
    .{ .owner = .vector, .base = "tanpi", .shape = .unary, .policy = .unit, .calls = calls_mid, .kernel = "tanpif" },
    .{ .owner = .vector, .base = "tanh", .shape = .unary, .policy = .any, .calls = calls_mid, .kernel = "tanhf" },
    .{ .owner = .vector, .base = "rsqrt", .shape = .unary, .policy = .positive, .calls = calls_default, .kernel = "rsqrtf" },
    .{ .owner = .vector, .base = "sqrt", .shape = .unary, .policy = .positive, .calls = calls_default, .kernel = "sqrtf" },
    .{ .owner = .vector, .base = "acos", .shape = .unary, .policy = .unit, .calls = calls_mid, .kernel = "acosf", .no_h = true },
    .{ .owner = .vector, .base = "asin", .shape = .unary, .policy = .unit, .calls = calls_mid, .kernel = "asinf", .no_h = true },
    .{ .owner = .vector, .base = "asinh", .shape = .unary, .policy = .small, .calls = calls_mid, .kernel = "asinhf" },
    .{ .owner = .vector, .base = "atanh", .shape = .unary, .policy = .large, .calls = calls_mid, .kernel = "atanhf" },
    .{ .owner = .vector, .base = "atan", .shape = .unary, .policy = .unit, .calls = calls_mid, .kernel = "atanf", .no_h = true },
    .{ .owner = .vector, .base = "cbrt", .shape = .unary, .policy = .any, .calls = calls_mid, .kernel = "cbrtf" },
    .{ .owner = .vector, .base = "exp2", .shape = .unary, .policy = .positive, .calls = calls_mid, .kernel = "exp2f" },
    .{ .owner = .vector, .base = "expm1", .shape = .unary, .policy = .positive, .calls = calls_mid, .kernel = "expm1f" },
    .{ .owner = .vector, .base = "log1p", .shape = .unary, .policy = .positive, .calls = calls_mid, .kernel = "log1pf" },
    .{ .owner = .vector, .base = "logp1", .shape = .unary, .policy = .positive, .calls = calls_mid, .kernel = "logp1f" },
    .{ .owner = .vector, .base = "ceil", .shape = .unary, .policy = .tie, .calls = calls_default, .kernel = "ceilf" },
    .{ .owner = .vector, .base = "floor", .shape = .unary, .policy = .tie, .calls = calls_default, .kernel = "floorf" },
    .{ .owner = .vector, .base = "nearbyint", .shape = .unary, .policy = .tie, .calls = calls_default, .kernel = "nearbyintf" },
    .{ .owner = .vector, .base = "rint", .shape = .unary, .policy = .tie, .calls = calls_default, .kernel = "rintf" },
    .{ .owner = .vector, .base = "roundeven", .shape = .unary, .policy = .tie, .calls = calls_default, .kernel = "roundevenf" },
    .{ .owner = .vector, .base = "trunc", .shape = .unary, .policy = .tie, .calls = calls_default, .kernel = "truncf" },
    .{ .owner = .vector, .base = "asinpi", .shape = .unary, .policy = .unit, .calls = calls_mid, .kernel = "asinpif" },
    .{ .owner = .vector, .base = "acospi", .shape = .unary, .policy = .unit, .calls = calls_mid, .kernel = "acospif" },
    .{ .owner = .vector, .base = "atanpi", .shape = .unary, .policy = .unit, .calls = calls_mid, .kernel = "atanpif" },
    .{ .owner = .vector, .base = "logb", .shape = .unary, .policy = .any, .calls = calls_default, .kernel = "logbf" },
    .{ .owner = .vector, .base = "pow", .shape = .binary, .policy = .any, .calls = calls_exact, .kernel = "powf" },
    .{ .owner = .vector, .base = "powr", .shape = .binary, .policy = .any, .calls = calls_exact, .kernel = "powrf" },
    .{ .owner = .vector, .base = "hypot", .shape = .binary, .policy = .any, .calls = calls_mid, .kernel = "hypotf" },
    .{ .owner = .vector, .base = "fmod", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "fmodf" },
    .{ .owner = .vector, .base = "remainder", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "remainderf" },
    .{ .owner = .vector, .base = "fdim", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "fdimf" },
    .{ .owner = .vector, .base = "fmax", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "fmaxf" },
    .{ .owner = .vector, .base = "fmin", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "fminf" },
    .{ .owner = .vector, .base = "fmaximum", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "fmaximumf" },
    .{ .owner = .vector, .base = "fminimum", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "fminimumf" },
    // zmath.vector.ieee_family: the remaining IEEE and miscellaneous float-to-float
    // routes, plus the integer-returning and boolean-returning ones.
    .{ .owner = .ieee_family, .base = "round", .shape = .unary, .policy = .any, .calls = calls_default, .kernel = "roundf" },
    .{ .owner = .ieee_family, .base = "nextUp", .shape = .unary, .policy = .any, .calls = calls_default, .kernel = "nextUpf" },
    .{ .owner = .ieee_family, .base = "nextDown", .shape = .unary, .policy = .any, .calls = calls_default, .kernel = "nextDownf" },
    .{ .owner = .ieee_family, .base = "getPayload", .shape = .unary, .policy = .any, .calls = calls_default, .kernel = "getPayloadf" },
    .{ .owner = .ieee_family, .base = "copySign", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "copySignf" },
    .{ .owner = .ieee_family, .base = "nextAfter", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "nextAfterf" },
    // These six are the camelCase aliases of the snake_case `fmaximum*` and
    // `fminimum*` kernels: `vector_ieee` forwards each lane to the canonical
    // symbol it aliases, so that symbol is the accepted kernel this row
    // reaches and the one its binary32 leg charges.
    .{ .owner = .ieee_family, .base = "fmaximumMag", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "fmaximum_magf" },
    .{ .owner = .ieee_family, .base = "fminimumMag", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "fminimum_magf" },
    .{ .owner = .ieee_family, .base = "fmaximumNum", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "fmaximum_numf" },
    .{ .owner = .ieee_family, .base = "fminimumNum", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "fminimum_numf" },
    .{ .owner = .ieee_family, .base = "fmaximumMagNum", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "fmaximum_mag_numf" },
    .{ .owner = .ieee_family, .base = "fminimumMagNum", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "fminimum_mag_numf" },
    .{ .owner = .ieee_family, .base = "ilogb", .shape = .unary, .policy = .any, .calls = calls_default, .kernel = "ilogbf" },
    .{ .owner = .ieee_family, .base = "llogb", .shape = .unary, .policy = .any, .calls = calls_default, .kernel = "llogbf" },
    .{ .owner = .ieee_family, .base = "totalOrder", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "totalOrderf" },
    .{ .owner = .ieee_family, .base = "totalOrderMag", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "totalOrderMagf" },
    // zmath.vector.struct_family: the thirteen routes whose kernel returns a
    // result struct, so the result is a lane-ordered array rather than a vector.
    .{ .owner = .struct_family, .base = "lrint", .shape = .unary, .policy = .tie, .calls = calls_default, .kernel = "lrintf" },
    .{ .owner = .struct_family, .base = "llrint", .shape = .unary, .policy = .tie, .calls = calls_default, .kernel = "llrintf" },
    .{ .owner = .struct_family, .base = "lround", .shape = .unary, .policy = .tie, .calls = calls_default, .kernel = "lroundf" },
    .{ .owner = .struct_family, .base = "llround", .shape = .unary, .policy = .tie, .calls = calls_default, .kernel = "llroundf" },
    .{ .owner = .struct_family, .base = "lgamma", .shape = .unary, .policy = .any, .calls = calls_exact, .kernel = "lgammaf" },
    .{ .owner = .struct_family, .base = "frexp", .shape = .unary, .policy = .tie, .calls = calls_default, .kernel = "frexpf" },
    .{ .owner = .struct_family, .base = "modf", .shape = .unary, .policy = .tie, .calls = calls_default, .kernel = "modff" },
    .{ .owner = .struct_family, .base = "canonicalize", .shape = .unary, .policy = .any, .calls = calls_default, .kernel = "canonicalizef" },
    .{ .owner = .struct_family, .base = "setPayload", .shape = .unary, .policy = .any, .calls = calls_default, .kernel = "setPayloadf" },
    .{ .owner = .struct_family, .base = "setPayloadSig", .shape = .unary, .policy = .any, .calls = calls_default, .kernel = "setPayloadSigf" },
    .{ .owner = .struct_family, .base = "atan2", .shape = .binary, .policy = .unit, .calls = calls_mid, .kernel = "atan2f" },
    .{ .owner = .struct_family, .base = "atan2pi", .shape = .binary, .policy = .unit, .calls = calls_mid, .kernel = "atan2pif" },
    .{ .owner = .struct_family, .base = "remquo", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "remquof" },
    // zmath.vector.intarg: the eleven operations that take a non-float argument,
    // each in a broadcast form and, for the six exponent operations, a per-lane
    // form, plus the three comptime type queries.
    .{ .owner = .intarg, .base = "ldexp", .shape = .extra, .policy = .any, .calls = calls_default, .kernel = "ldexpf", .extra = .scale32 },
    .{ .owner = .intarg, .base = "ldexp", .shape = .lanes, .policy = .any, .calls = calls_default, .kernel = "ldexpf", .extra = .scale32, .lanes_form = true },
    .{ .owner = .intarg, .base = "scalbn", .shape = .extra, .policy = .any, .calls = calls_default, .kernel = "scalbnf", .extra = .scale32 },
    .{ .owner = .intarg, .base = "scalbn", .shape = .lanes, .policy = .any, .calls = calls_default, .kernel = "scalbnf", .extra = .scale32, .lanes_form = true },
    .{ .owner = .intarg, .base = "scalbln", .shape = .extra, .policy = .any, .calls = calls_default, .kernel = "scalblnf", .extra = .scale64 },
    .{ .owner = .intarg, .base = "scalbln", .shape = .lanes, .policy = .any, .calls = calls_default, .kernel = "scalblnf", .extra = .scale64, .lanes_form = true },
    .{ .owner = .intarg, .base = "pown", .shape = .extra, .policy = .any, .calls = calls_exact, .kernel = "pownf", .extra = .degree },
    .{ .owner = .intarg, .base = "pown", .shape = .lanes, .policy = .any, .calls = calls_exact, .kernel = "pownf", .extra = .degree, .lanes_form = true },
    .{ .owner = .intarg, .base = "compoundn", .shape = .extra, .policy = .any, .calls = calls_exact, .kernel = "compoundnf", .extra = .degree },
    .{ .owner = .intarg, .base = "compoundn", .shape = .lanes, .policy = .any, .calls = calls_exact, .kernel = "compoundnf", .extra = .degree, .lanes_form = true },
    .{ .owner = .intarg, .base = "rootn", .shape = .extra, .policy = .any, .calls = calls_exact, .kernel = "rootnf", .extra = .degree },
    .{ .owner = .intarg, .base = "rootn", .shape = .lanes, .policy = .any, .calls = calls_exact, .kernel = "rootnf", .extra = .degree, .lanes_form = true },
    .{ .owner = .intarg, .base = "nextToward", .shape = .extra, .policy = .any, .calls = calls_default, .kernel = "nextTowardf", .extra = .toward },
    .{ .owner = .intarg, .base = "fromfp", .shape = .extra2, .policy = .tie, .calls = calls_default, .kernel = "fromfpf", .extra = .fromfp },
    .{ .owner = .intarg, .base = "ufromfp", .shape = .extra2, .policy = .tie, .calls = calls_default, .kernel = "ufromfpf", .extra = .fromfp },
    .{ .owner = .intarg, .base = "fromfpx", .shape = .extra2, .policy = .tie, .calls = calls_default, .kernel = "fromfpxf", .extra = .fromfp },
    .{ .owner = .intarg, .base = "ufromfpx", .shape = .extra2, .policy = .tie, .calls = calls_default, .kernel = "ufromfpxf", .extra = .fromfp },
    .{ .owner = .intarg, .base = "widthOf", .shape = .type_query, .policy = .any, .calls = calls_default, .kernel = "", .fixed = true },
    .{ .owner = .intarg, .base = "LaneOf", .shape = .type_query, .policy = .any, .calls = calls_default, .kernel = "", .fixed = true },
    .{ .owner = .intarg, .base = "PowerVector", .shape = .type_query, .policy = .any, .calls = calls_default, .kernel = "", .fixed = true },
    // zmath.vector.narrow: the six fixed-shape C23 narrowing routes and the
    // ternary float-to-float `fma` family.
    .{ .owner = .narrow, .base = "faddv", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "fadd", .fixed = true, .format = .d },
    .{ .owner = .narrow, .base = "fsubv", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "fsub", .fixed = true, .format = .d },
    .{ .owner = .narrow, .base = "fmulv", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "fmul", .fixed = true, .format = .d },
    .{ .owner = .narrow, .base = "fdivv", .shape = .binary, .policy = .any, .calls = calls_default, .kernel = "fdiv", .fixed = true, .format = .d },
    .{ .owner = .narrow, .base = "ffmav", .shape = .ternary, .policy = .any, .calls = calls_default, .kernel = "ffma", .fixed = true, .format = .d },
    .{ .owner = .narrow, .base = "fsqrtv", .shape = .unary, .policy = .any, .calls = calls_default, .kernel = "fsqrt", .fixed = true, .format = .d },
    .{ .owner = .narrow, .base = "fma", .shape = .ternary, .policy = .any, .calls = calls_default, .kernel = "fmaf" },
    // zmath.vector.core: the six shared per-lane helpers, each timed in the one
    // instantiation that shows the capability it exists for.
    .{ .owner = .core, .base = "mapUnaryR", .shape = .core_unary, .policy = .positive, .calls = calls_mid, .kernel = "expf", .fixed = true, .result = "f32" },
    .{ .owner = .core, .base = "mapUnaryR", .shape = .core_unary, .policy = .any, .calls = calls_default, .kernel = "ilogbf", .fixed = true, .result = "i32" },
    .{ .owner = .core, .base = "mapUnaryR", .shape = .core_unary, .policy = .any, .calls = calls_default, .kernel = "llogbf", .fixed = true, .result = "i64" },
    .{ .owner = .core, .base = "mapBinaryR", .shape = .core_binary, .policy = .any, .calls = calls_exact, .kernel = "powf", .fixed = true, .result = "f32" },
    .{ .owner = .core, .base = "mapBinaryR", .shape = .core_binary, .policy = .any, .calls = calls_default, .kernel = "totalOrderf", .fixed = true, .result = "bool" },
    .{ .owner = .core, .base = "mapTernaryR", .shape = .core_ternary, .policy = .any, .calls = calls_default, .kernel = "fmaf", .fixed = true, .result = "f32" },
    .{ .owner = .core, .base = "mapUnaryExtra", .shape = .core_extra, .policy = .any, .calls = calls_default, .kernel = "ldexpf", .fixed = true, .result = "i32" },
    .{ .owner = .core, .base = "mapUnaryExtra2", .shape = .core_extra2, .policy = .tie, .calls = calls_default, .kernel = "fromfpf", .fixed = true, .result = "FromFpRound,u32" },
    .{ .owner = .core, .base = "mapIntLanes", .shape = .core_lanes, .policy = .any, .calls = calls_default, .kernel = "ldexpf", .fixed = true, .result = "i32" },
};

// ---------------------------------------------------------------------------
// Expanding a family into its exports
// ---------------------------------------------------------------------------

/// One public export, named exactly as its owner module declares it.
const Entry = struct {
    owner: Owner,
    name: []const u8,
    /// The family base the export name is built from.
    base: []const u8,
    /// The result element type a `vector_core` row instantiates its helper
    /// with, and "" for every other export.
    variant: []const u8,
    shape: Shape,
    extra: Extra,
    /// True when the export has no generic spelling and no per-format forms.
    fixed: bool,
    class: Class,
    policy: Policy,
    calls: u32,
    /// The accepted kernel reached at each lane format, and "" where the export
    /// declares no such spelling.
    kernels: [3][]const u8,
    /// The family base of a generic dispatch spelling, and "" otherwise.
    canonical: []const u8,
    /// The lane format this export is timed at.
    format: Format,
};

fn entryCount(comptime family: Family) usize {
    if (family.fixed) return 1;
    return if (family.no_h) 3 else 4;
}

/// The generic dispatch spelling. Its kernel table is the family's own three
/// kernels: the binary16 lane type of `sinv` is `scalar.sinh`, the binary16 SINE
/// kernel, not the binary16 HYPERBOLIC SINE, exactly as `vector.zig` binds it.
fn genericEntry(comptime family: Family) Entry {
    return .{
        .owner = family.owner,
        .name = family.base ++ "v" ++ lanesTail(family),
        .base = family.base,
        .variant = "",
        .shape = family.shape,
        .extra = family.extra,
        .fixed = false,
        // A family with no binary16 spelling reaches the binary16 kernel only
        // through this generic entry point, so this row is that route's
        // canonical one and is timed at the binary16 lane format. Its binary32
        // and binary64 legs stay the identical canonical routes of the
        // per-format spellings and open no rows of their own.
        .class = if (family.no_h) .direct_timed else .identical_canonical,
        .policy = family.policy,
        .calls = family.calls,
        .kernels = .{
            kernelStem(family) ++ "h",
            kernelStem(family) ++ "f",
            kernelStem(family) ++ "d",
        },
        .canonical = family.base,
        .format = if (family.no_h) .h else .f,
    };
}

/// One per-format spelling, `BASE` + `h`/`f`/`d` + `v` + the `Lanes` suffix.
fn spelledEntry(comptime family: Family, comptime letter: []const u8, comptime fmt: Format) Entry {
    const at = formatIndex(fmt);
    return .{
        .owner = family.owner,
        .name = family.base ++ letter ++ "v" ++ lanesTail(family),
        .base = family.base,
        .variant = "",
        .shape = family.shape,
        .extra = family.extra,
        .fixed = false,
        .class = .direct_timed,
        .policy = family.policy,
        .calls = family.calls,
        .kernels = .{
            if (at == 0) kernelStem(family) ++ "h" else "",
            if (at == 1) kernelStem(family) ++ "f" else "",
            if (at == 2) kernelStem(family) ++ "d" else "",
        },
        .canonical = "",
        .format = fmt,
    };
}

/// One fixed-shape export: a narrowing route, a `vector_core` helper or a
/// comptime type query.
fn fixedEntry(comptime family: Family) Entry {
    const at = formatIndex(family.format);
    return .{
        .owner = family.owner,
        .name = family.base,
        .base = family.base,
        .variant = if (family.result.len == 0) "" else "R=" ++ family.result,
        .shape = family.shape,
        .extra = family.extra,
        .fixed = true,
        .class = if (family.shape == .type_query) .compile_only else .direct_timed,
        .policy = family.policy,
        .calls = family.calls,
        .kernels = .{
            if (at == 0) family.kernel else "",
            if (at == 1) family.kernel else "",
            if (at == 2) family.kernel else "",
        },
        .canonical = "",
        .format = family.format,
    };
}

fn entriesFor(comptime family: Family) [entryCount(family)]Entry {
    var out: [entryCount(family)]Entry = undefined;
    if (family.fixed) {
        out[0] = fixedEntry(family);
        return out;
    }
    out[0] = genericEntry(family);
    if (family.no_h) {
        out[1] = spelledEntry(family, "f", .f);
        out[2] = spelledEntry(family, "d", .d);
    } else {
        out[1] = spelledEntry(family, "h", .h);
        out[2] = spelledEntry(family, "f", .f);
        out[3] = spelledEntry(family, "d", .d);
    }
    return out;
}

const entry_total = blk: {
    var n: usize = 0;
    for (families) |family| n += entryCount(family);
    break :blk n;
};

const entries: [entry_total]Entry = blk: {
    @setEvalBranchQuota(10_000_000);
    var out: [entry_total]Entry = undefined;
    var at: usize = 0;
    for (families) |family| {
        const produced = entriesFor(family);
        for (0..produced.len) |i| {
            out[at + i] = produced[i];
        }
        at += produced.len;
    }
    break :blk out;
};

// ---------------------------------------------------------------------------
// Non-lane operands
// ---------------------------------------------------------------------------

/// The type of a broadcast non-lane argument.
fn ExtraType(comptime extra: Extra) type {
    return switch (extra) {
        .scale32 => i32,
        .scale64, .degree => i64,
        .toward => f64,
        .none, .fromfp => @compileError("api_round_lanes: this extra argument needs its own two-scalar form"),
    };
}

fn extraValue(comptime extra: Extra, comptime regime: Regime, index: usize) ExtraType(extra) {
    return switch (extra) {
        .scale32 => @as(i32, scaleArgOf(i32, regime, index)),
        .scale64 => @as(i64, scaleArgOf(i64, regime, index)),
        .degree => @as(i64, degreeArgOf(regime, index)),
        .toward => @as(f64, towardOf(regime, index)),
        .none, .fromfp => @compileError("api_round_lanes: this extra argument needs its own two-scalar form"),
    };
}

/// The element type of a per-lane integer vector.
fn LanesType(comptime extra: Extra) type {
    return switch (extra) {
        .scale32 => i32,
        .scale64, .degree => i64,
        .none, .toward, .fromfp => @compileError("api_round_lanes: a per-lane form needs an integer exponent vector"),
    };
}

/// The per-lane integer exponents one `Lanes` route is driven with.
///
/// Each per-lane form draws from the table its own broadcast sibling draws
/// from, because the two forms are the same kernel with the same argument
/// domain: `scalbln` takes an `i64` exponent, so its `Lanes` form is driven
/// with the `i64` scale amounts, the exact, overflow and full-underflow ranges
/// and both `i64` limits included. The bounded degree table belongs to the
/// power family alone, which reports `ok == false` outside `[-64, 64]`, and
/// feeding it to `scalbln` would measure a narrower domain than the broadcast
/// form measures.
fn intLanesOf(
    comptime I: type,
    comptime width: usize,
    comptime extra: Extra,
    comptime regime: Regime,
    index: usize,
) @Vector(width, I) {
    return switch (extra) {
        .scale32 => scaleLanes(i32, width, regime, index),
        .scale64 => scaleLanes(i64, width, regime, index),
        .degree => degreeLanes(width, regime, index),
        .none, .toward, .fromfp => @compileError("api_round_lanes: a per-lane form needs an integer exponent vector"),
    };
}

/// The result element type a `vector_core` row instantiates its helper with.
fn coreResult(comptime entry: Entry) type {
    const variant = entry.variant;
    if (std.mem.eql(u8, variant, "R=f32")) return f32;
    if (std.mem.eql(u8, variant, "R=i32")) return i32;
    if (std.mem.eql(u8, variant, "R=i64")) return i64;
    if (std.mem.eql(u8, variant, "R=bool")) return bool;
    @compileError("api_round_lanes: a vector_core row needs a result element type");
}

/// The accepted kernel a `vector_core` row maps, named by the same verbatim
/// symbol the charge table uses.
fn kernelNameOf(comptime entry: Entry) []const u8 {
    return entry.kernels[formatIndex(entry.format)];
}

/// True when the accepted kernel of a `vector_core` row is the one of the six
/// that lives in `zmath.ieee` rather than `zmath.scalar`, which is
/// `totalOrderf` alone. It is binary and returns a verdict, where every other
/// kernel the six shared helpers map is a `zmath.scalar` export of another
/// arity or another result type, so the two spellings share no signature and
/// no single return type can name both of them.
///
/// That is why no helper hands the kernel back as a value: a helper declares
/// one return type, and the two spellings have none in common. Each timed
/// callback binds the kernel itself, in the `comptime` block that fills the
/// `anytype` parameter of the shared helper it maps, so the condition is
/// comptime-known and only the taken branch is analyzed.
fn ieeeKernelOf(comptime entry: Entry) bool {
    return std.mem.eql(u8, kernelNameOf(entry), "totalOrderf");
}

// ---------------------------------------------------------------------------
// The timed callbacks
//
// Each one is `noinline`, takes the runtime index the harness supplies, builds
// its operands from that index, calls the public entry point directly and
// returns the checksum of the whole semantic result: every lane in lane order,
// every field of every result struct including `ok`, `resolved`, `sign` and
// `quotient`, every integer and every mask bit, with no padding and no address.
// ---------------------------------------------------------------------------

fn unaryInvoke(
    comptime T: type,
    comptime width: usize,
    comptime op: anytype,
    comptime policy: Policy,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const lanes: @Vector(width, T) = laneVector(T, width, policy, regime, index);
            return common.hash(op(lanes));
        }
    };
    return Body.run;
}

fn binaryInvoke(
    comptime T: type,
    comptime width: usize,
    comptime op: anytype,
    comptime policy: Policy,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const left: @Vector(width, T) = laneVector(T, width, policy, regime, index);
            const right: @Vector(width, T) = secondVector(T, width, policy, regime, index);
            return common.hash(op(left, right));
        }
    };
    return Body.run;
}

fn ternaryInvoke(
    comptime T: type,
    comptime width: usize,
    comptime op: anytype,
    comptime policy: Policy,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const a: @Vector(width, T) = laneVector(T, width, policy, regime, index);
            const b: @Vector(width, T) = secondVector(T, width, policy, regime, index);
            const c: @Vector(width, T) = thirdVector(T, width, policy, regime, index);
            return common.hash(op(a, b, c));
        }
    };
    return Body.run;
}

fn extraInvoke(
    comptime T: type,
    comptime width: usize,
    comptime extra: Extra,
    comptime op: anytype,
    comptime policy: Policy,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const lanes: @Vector(width, T) = laneVector(T, width, policy, regime, index);
            return common.hash(op(lanes, extraValue(extra, regime, index)));
        }
    };
    return Body.run;
}

fn extra2Invoke(
    comptime T: type,
    comptime width: usize,
    comptime op: anytype,
    comptime policy: Policy,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const lanes: @Vector(width, T) = laneVector(T, width, policy, regime, index);
            return common.hash(op(lanes, fromfpRoundOf(index), fromfpWidthOf(index)));
        }
    };
    return Body.run;
}

fn intLanesInvoke(
    comptime T: type,
    comptime width: usize,
    comptime extra: Extra,
    comptime op: anytype,
    comptime policy: Policy,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const I = LanesType(extra);
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const lanes: @Vector(width, T) = laneVector(T, width, policy, regime, index);
            const exponents: @Vector(width, I) = intLanesOf(I, width, extra, regime, index);
            return common.hash(op(lanes, exponents));
        }
    };
    return Body.run;
}

fn coreUnaryRInvoke(
    comptime T: type,
    comptime width: usize,
    comptime R: type,
    comptime entry: Entry,
    comptime policy: Policy,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const f = comptime if (ieeeKernelOf(entry)) zmath.ieee.totalOrderf else @field(zmath.scalar, kernelNameOf(entry));
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const lanes: @Vector(width, T) = laneVector(T, width, policy, regime, index);
            return common.hash(zmath.vector.core.mapUnaryR(T, R, f, lanes));
        }
    };
    return Body.run;
}

fn coreBinaryRInvoke(
    comptime T: type,
    comptime width: usize,
    comptime R: type,
    comptime entry: Entry,
    comptime policy: Policy,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const f = comptime if (ieeeKernelOf(entry)) zmath.ieee.totalOrderf else @field(zmath.scalar, kernelNameOf(entry));
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const a: @Vector(width, T) = laneVector(T, width, policy, regime, index);
            const b: @Vector(width, T) = secondVector(T, width, policy, regime, index);
            return common.hash(zmath.vector.core.mapBinaryR(T, R, f, a, b));
        }
    };
    return Body.run;
}

fn coreTernaryRInvoke(
    comptime T: type,
    comptime width: usize,
    comptime R: type,
    comptime entry: Entry,
    comptime policy: Policy,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const f = comptime if (ieeeKernelOf(entry)) zmath.ieee.totalOrderf else @field(zmath.scalar, kernelNameOf(entry));
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const a: @Vector(width, T) = laneVector(T, width, policy, regime, index);
            const b: @Vector(width, T) = secondVector(T, width, policy, regime, index);
            const c: @Vector(width, T) = thirdVector(T, width, policy, regime, index);
            return common.hash(zmath.vector.core.mapTernaryR(T, R, f, a, b, c));
        }
    };
    return Body.run;
}

fn coreUnaryExtraInvoke(
    comptime T: type,
    comptime width: usize,
    comptime entry: Entry,
    comptime policy: Policy,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const f = comptime if (ieeeKernelOf(entry)) zmath.ieee.totalOrderf else @field(zmath.scalar, kernelNameOf(entry));
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const lanes: @Vector(width, T) = laneVector(T, width, policy, regime, index);
            const exponent = scaleArgOf(i32, regime, index);
            return common.hash(zmath.vector.core.mapUnaryExtra(T, T, i32, f, exponent, lanes));
        }
    };
    return Body.run;
}

fn coreUnaryExtra2Invoke(
    comptime T: type,
    comptime width: usize,
    comptime entry: Entry,
    comptime policy: Policy,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const f = comptime if (ieeeKernelOf(entry)) zmath.ieee.totalOrderf else @field(zmath.scalar, kernelNameOf(entry));
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const lanes: @Vector(width, T) = laneVector(T, width, policy, regime, index);
            return common.hash(zmath.vector.core.mapUnaryExtra2(
                T,
                T,
                zmath.FromFpRound,
                u32,
                f,
                fromfpRoundOf(index),
                fromfpWidthOf(index),
                lanes,
            ));
        }
    };
    return Body.run;
}

fn coreIntLanesInvoke(
    comptime T: type,
    comptime width: usize,
    comptime entry: Entry,
    comptime policy: Policy,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const f = comptime if (ieeeKernelOf(entry)) zmath.ieee.totalOrderf else @field(zmath.scalar, kernelNameOf(entry));
    const Body = struct {
        noinline fn run(index: usize) u64 {
            const lanes: @Vector(width, T) = laneVector(T, width, policy, regime, index);
            const exponents: @Vector(width, i32) = scaleLanes(i32, width, regime, index);
            return common.hash(zmath.vector.core.mapIntLanes(T, T, i32, f, lanes, exponents));
        }
    };
    return Body.run;
}

/// The timed callback for one export row.
fn invokeFor(
    comptime entry: Entry,
    comptime route: anytype,
    comptime T: type,
    comptime width: usize,
    comptime regime: Regime,
) *const fn (usize) u64 {
    const policy = entry.policy;
    return switch (entry.shape) {
        .unary => unaryInvoke(T, width, route, policy, regime),
        .binary => binaryInvoke(T, width, route, policy, regime),
        .ternary => ternaryInvoke(T, width, route, policy, regime),
        .extra => extraInvoke(T, width, entry.extra, route, policy, regime),
        .extra2 => extra2Invoke(T, width, route, policy, regime),
        .lanes => intLanesInvoke(T, width, entry.extra, route, policy, regime),
        .core_unary => coreUnaryRInvoke(T, width, coreResult(entry), entry, policy, regime),
        .core_binary => coreBinaryRInvoke(T, width, coreResult(entry), entry, policy, regime),
        .core_ternary => coreTernaryRInvoke(T, width, coreResult(entry), entry, policy, regime),
        .core_extra => coreUnaryExtraInvoke(T, width, entry, policy, regime),
        .core_extra2 => coreUnaryExtra2Invoke(T, width, entry, policy, regime),
        .core_lanes => coreIntLanesInvoke(T, width, entry, policy, regime),
        .type_query => @compileError("api_round_lanes: a comptime type query has no runtime case"),
    };
}

// ---------------------------------------------------------------------------
// The case rows
// ---------------------------------------------------------------------------

fn caseCount(comptime entry: Entry) usize {
    return switch (entry.class) {
        // Only a `direct_timed` row is timed. A `compile_only` export has no
        // runtime evaluation and an `identical_canonical` one is already timed
        // through the per-format spelling it duplicates.
        .compile_only, .identical_canonical => 0,
        .direct_timed => widths.len * regimes.len,
    };
}

fn caseName(comptime entry: Entry, comptime width: usize, comptime regime: Regime) []const u8 {
    const variant = if (entry.variant.len == 0) "" else "." ++ entry.variant;
    return "lanes." ++ entry.name ++ variant ++ "." ++ formatNameOf(entry.format) ++
        "." ++ widthTag(width) ++ "." ++ @tagName(regime);
}

fn casesFor(comptime entry: Entry) [caseCount(entry)]common.Case {
    var out: [caseCount(entry)]common.Case = undefined;
    if (entry.class != .direct_timed) return out;
    const route = Owner.decl(entry.owner, entry.name);
    const T = laneTypeOf(entry.format);
    const key = chargeOfKernel(entry.kernels[formatIndex(entry.format)]);
    inline for (widths, 0..) |width, wi| {
        inline for (regimes, 0..) |regime, ri| {
            out[wi * regimes.len + ri] = .{
                .name = caseName(entry, width, regime),
                .namespace = namespace,
                .invoke = invokeFor(entry, route, T, width, regime),
                .calls = entry.calls,
                .f32 = chargeFor(key, width),
            };
        }
    }
    return out;
}

const case_total = blk: {
    var n: usize = 0;
    for (entries) |entry| n += caseCount(entry);
    break :blk n;
};

/// Every timed case of this slice: one row per export, lane width and regime.
pub const cases: [case_total]common.Case = blk: {
    @setEvalBranchQuota(10_000_000);
    var out: [case_total]common.Case = undefined;
    var at: usize = 0;
    for (0..entries.len) |i| {
        const produced = casesFor(entries[i]);
        for (0..produced.len) |k| {
            out[at + k] = produced[k];
        }
        at += produced.len;
    }
    break :blk out;
};

// ---------------------------------------------------------------------------
// The complete inventory
// ---------------------------------------------------------------------------

/// What one export produces, which is what the checksum has to cover.
fn resultNote(comptime entry: Entry) []const u8 {
    if (entry.owner == .core)
        return "a `@Vector(N, " ++ entry.variant[2..] ++ ")` out of the shared helper";
    if (entry.owner == .struct_family)
        return "a lane-ordered `[N]Result` array, because Zig forbids a struct as a `@Vector` element type, with every field of every lane and the lane order itself in the checksum";
    if (entry.owner == .narrow and entry.fixed)
        return "a `@Vector(N, f32)` out of binary64 lanes, because a narrowing route fixes both the lane type and the result element type";
    if (std.mem.eql(u8, entry.base, "ilogb"))
        return "an `@Vector(N, i32)` binary exponent, one integer per lane";
    if (std.mem.eql(u8, entry.base, "llogb"))
        return "an `@Vector(N, i64)` binary exponent, one integer per lane";
    if (std.mem.eql(u8, entry.base, "totalOrder") or std.mem.eql(u8, entry.base, "totalOrderMag"))
        return "an `@Vector(N, bool)` mask, one bit per lane";
    if (entry.owner == .intarg and entry.extra == .degree)
        return "a lane-ordered `[N]PowerResult` array, so the value and its `ok` status are both in the checksum";
    if (entry.extra == .scale32 or entry.extra == .scale64 or entry.extra == .toward or entry.extra == .fromfp)
        return "a `@Vector(N, T)` of the same lane type";
    return "a `@Vector(N, T)` of the same lane type";
}

/// The argument list one export takes, which is what the callback varies.
fn operandNote(comptime entry: Entry) []const u8 {
    return switch (entry.shape) {
        .unary => "one lane vector",
        .binary => "two lane vectors whose second operand is related to the first in the boundary regime",
        .ternary => "three lane vectors",
        .extra => switch (entry.extra) {
            .scale32 => "one lane vector and a broadcast `i32` exponent drawn from the exact, overflow and full-underflow ranges",
            .scale64 => "one lane vector and a broadcast `i64` exponent",
            .degree => "one lane vector and a broadcast `i64` degree spanning the implemented `[-64, 64]` window and the out-of-range degrees that report `ok == false`",
            .toward => "one lane vector and a broadcast `f64` target covering both zeros, both infinities and the extreme finite magnitudes",
            else => "one lane vector and a broadcast scalar",
        },
        .extra2 => "one lane vector and two broadcast scalars, the `FromFpRound` direction and the `u32` conversion width, covering every direction and the widths every family rejects",
        .lanes => "one lane vector and a per-lane integer vector of exponents, so one call drives several branches of the kernel at once",
        .core_unary => "one lane vector, mapped by the shared unary helper",
        .core_binary => "two lane vectors, mapped by the shared binary helper",
        .core_ternary => "three lane vectors, mapped by the shared ternary helper",
        .core_extra => "one lane vector and a broadcast `i32` exponent, mapped by the shared one-extra helper",
        .core_extra2 => "one lane vector and two broadcast scalars, mapped by the shared two-extra helper",
        .core_lanes => "one lane vector and a per-lane `i32` vector, mapped by the shared per-lane helper",
        .type_query => "a comptime type",
    };
}

/// Why an export is in the class it is in. The class name is the first word, so
/// a reader can grep the inventory for any one classification.
fn reasonFor(comptime entry: Entry) []const u8 {
    return switch (entry.class) {
        .compile_only => "COMPILE-ONLY: a comptime type query. It takes a type and returns a compile-time value or a type, so there is no runtime evaluation to time, it reaches no accepted kernel and it opens no case. It exists so a caller writing its own lane-parallel entry point can name the lane count, the lane type and the lane-ordered power result type.",
        .identical_canonical => "IDENTICAL-CANONICAL: the generic dispatch spelling of the " ++ entry.canonical ++ " family. Its lane-type test is comptime, so for each lane type it reaches the identical canonical route, the identical accepted kernel and the identical lane loop as the per-format spelling of that family, and timing it again would measure that route twice. The per-format rows are its canonical route, so it opens no case of its own.",
        .direct_timed => if (entry.canonical.len != 0)
            "TIMED DIRECTLY at the binary16 lane type only: " ++ entry.name ++ " is the ONLY public route to the binary16 " ++ entry.canonical ++ " kernel, because the name its binary16 spelling would take, " ++ entry.canonical ++ "hv, is already the generic entry point of another family. Its binary32 and binary64 legs are the identical canonical routes of " ++ entry.canonical ++ "fv and " ++ entry.canonical ++ "dv and open no rows of their own. It takes " ++ operandNote(entry) ++ " and produces " ++ resultNote(entry) ++ "."
        else
            "TIMED DIRECTLY: the canonical route of " ++ entry.name ++ ", taking " ++ operandNote(entry) ++ " and producing " ++ resultNote(entry) ++ ". Its cases call the export itself and charge the canonical binary32 kernel once per lane.",
    };
}

/// One row per public export of the six owner modules, with its class and the
/// reason for that class.
pub const InventoryEntry = struct {
    /// The owner module, which is the canonical public namespace owner.
    owner: Owner,
    /// The source file the export is declared in.
    file: []const u8,
    /// The public export name, exactly as the module declares it.
    name: []const u8,
    /// The result element type a `vector_core` row is instantiated with, and
    /// "" for every other export.
    variant: []const u8,
    class: Class,
    shape: Shape,
    /// The accepted kernel reached at each lane format, "" where the export
    /// declares no such spelling.
    kernels: [3][]const u8,
    /// The canonical route a generic dispatch spelling duplicates.
    canonical: []const u8,
    policy: Policy,
    calls: u32,
    reason: []const u8,
};

pub const inventory = blk: {
    @setEvalBranchQuota(10_000_000);
    var out: [entries.len]InventoryEntry = undefined;
    for (0..entries.len) |i| {
        const entry = entries[i];
        out[i] = .{
            .owner = entry.owner,
            .file = Owner.file(entry.owner),
            .name = entry.name,
            .variant = entry.variant,
            .class = entry.class,
            .shape = entry.shape,
            .kernels = entry.kernels,
            .canonical = entry.canonical,
            .policy = entry.policy,
            .calls = entry.calls,
            .reason = reasonFor(entry),
        };
    }
    break :blk out;
};

/// The number of public `fn` exports each owner module declares, read off the
/// six sources. The accounting check below fails if the family table stops
/// naming exactly these.
const owner_export_counts = [_]struct { owner: Owner, exports: usize }{
    .{ .owner = .vector, .exports = 214 },
    .{ .owner = .ieee_family, .exports = 64 },
    .{ .owner = .intarg, .exports = 71 },
    .{ .owner = .narrow, .exports = 10 },
    .{ .owner = .struct_family, .exports = 52 },
    .{ .owner = .core, .exports = 6 },
};

const OwnerAccounting = struct {
    owner: Owner,
    file: []const u8,
    exports: usize,
    direct_timed: usize,
    identical_canonical: usize,
    compile_only: usize,
};

pub const owner_accounting: [owner_export_counts.len]OwnerAccounting = blk: {
    @setEvalBranchQuota(10_000_000);
    var out: [owner_export_counts.len]OwnerAccounting = undefined;
    for (owner_export_counts, 0..) |declared, at| {
        var names: [declared.exports][]const u8 = undefined;
        var used: usize = 0;
        var direct: usize = 0;
        var identical: usize = 0;
        var compiled: usize = 0;
        for (entries) |entry| {
            if (entry.owner != declared.owner) continue;
            var seen = false;
            for (names[0..used]) |name| {
                if (std.mem.eql(u8, name, entry.name)) seen = true;
            }
            if (seen) continue;
            names[used] = entry.name;
            used += 1;
            switch (entry.class) {
                .direct_timed => direct += 1,
                .identical_canonical => identical += 1,
                .compile_only => compiled += 1,
            }
        }
        out[at] = .{
            .owner = declared.owner,
            .file = Owner.file(declared.owner),
            .exports = used,
            .direct_timed = direct,
            .identical_canonical = identical,
            .compile_only = compiled,
        };
    }
    break :blk out;
};

/// The whole portable-vector surface this slice accounts for.
pub const export_count = blk: {
    var n: usize = 0;
    for (owner_accounting) |row| n += row.exports;
    break :blk n;
};

pub const direct_timed_exports = blk: {
    var n: usize = 0;
    for (owner_accounting) |row| n += row.direct_timed;
    break :blk n;
};

pub const identical_canonical_exports = blk: {
    var n: usize = 0;
    for (owner_accounting) |row| n += row.identical_canonical;
    break :blk n;
};

pub const compile_only_exports = blk: {
    var n: usize = 0;
    for (owner_accounting) |row| n += row.compile_only;
    break :blk n;
};

/// The number of timed rows in `inventory`. It exceeds `direct_timed_exports`
/// by three: `mapUnaryR` is timed in three result element types and
/// `mapBinaryR` in two, because the result shape is the point of them.
pub const direct_timed_rows = blk: {
    var n: usize = 0;
    for (entries) |entry| {
        if (entry.class == .direct_timed) n += 1;
    }
    break :blk n;
};

/// The number of timed cases in this slice: one per timed row, lane width and
/// regime.
pub const case_count = cases.len;

// ---------------------------------------------------------------------------
// The exact per-operation budget
//
// `Charge.count` is per `invoke` call, so one full pass of a case costs
// `calls * count` evaluations of each kernel it charges. This table is that
// product summed over every case of the slice, which is what the ledger must
// reserve before a single process is launched.
// ---------------------------------------------------------------------------

const BudgetRow = struct {
    /// The verbatim public name of the accepted binary32 kernel.
    operation: []const u8,
    /// How many cases of this slice charge the kernel.
    cases: usize,
    /// Accepted binary32 evaluations one full pass of the slice costs.
    evaluations: u64,
};

/// Every operation name any case of this slice can charge.
const budget_operations = [_][]const u8{
    "absf",          "acosf",         "acoshf",         "acospif",        "asinf",             "asinhf",        "asinpif",       "atan2f",     "atan2pif",
    "atanf",         "atanhf",        "atanpif",        "canonicalizef",  "cbrtf",             "ceilf",         "compoundnf",    "copySignf",  "cosf",
    "coshf",         "cospif",        "erfcf",          "erff",           "exp10f",            "exp10m1f",      "exp2f",         "exp2m1f",    "expf",
    "expm1f",        "f32addf64",     "fdimf",          "f32divf64",      "f32fmaf64",         "floorf",        "fmaf",          "fmaxf",      "fmaximum_mag_numf",
    "fmaximum_magf", "fmaximum_numf", "fmaximumf",      "fminf",          "fminimum_mag_numf", "fminimum_magf", "fminimum_numf", "fminimumf",  "fmodf",
    "f32mulf64",     "frexpf",        "fromfpf",        "fromfpxf",       "f32sqrtf64",        "f32subf64",     "getPayloadf",   "hypotf",     "ilogbf",
    "ldexpf",        "lgammaf",       "llogbf",         "llrintf",        "llroundf",          "log10f",        "log10p1f",      "log1pf",     "log2f",
    "log2p1f",       "logbf",         "logf",           "lrintf",         "lroundf",           "modff",         "nearbyintf",    "nextAfterf", "nextDownf",
    "nextTowardf",   "nextUpf",       "powf",           "pownf",          "remainderf",        "remquof",       "rootnf",        "roundf",     "rsqrtf",
    "scalblnf",      "scalbnf",       "setPayloadSigf", "setPayloadf",    "sinf",              "sinhf",         "sinpif",        "sqrtf",      "tanf",
    "tanhf",         "tanpif",        "tgammaf",        "totalOrderMagf", "totalOrderf",       "truncf",        "ufromfpf",      "ufromfpxf",
};

pub const budget: [budget_operations.len]BudgetRow = blk: {
    @setEvalBranchQuota(10_000_000);
    var out: [budget_operations.len]BudgetRow = undefined;
    for (budget_operations, 0..) |operation, at| {
        var hit: usize = 0;
        var evaluations: u64 = 0;
        for (cases) |case| {
            for (case.f32) |charge| {
                if (std.mem.eql(u8, charge.operation, operation)) {
                    hit += 1;
                    evaluations += @as(u64, case.calls) * charge.count;
                }
            }
        }
        out[at] = .{ .operation = operation, .cases = hit, .evaluations = evaluations };
    }
    break :blk out;
};

/// The largest per-operation cost of one full pass of this slice, which is the
/// binding number when the round reserves against the per-operation cap.
pub const budget_peak = blk: {
    var peak: u64 = 0;
    for (budget) |row| {
        if (row.evaluations > peak) peak = row.evaluations;
    }
    break :blk peak;
};

/// The name of that operation, so a reader does not have to find it.
pub const budget_peak_operation = blk: {
    var name: []const u8 = "";
    for (budget) |row| {
        if (row.evaluations == budget_peak) {
            name = row.operation;
        }
    }
    break :blk name;
};

/// Accepted binary32 evaluations one full pass of the slice costs in total,
/// across every kernel.
pub const budget_total = blk: {
    var n: u64 = 0;
    for (budget) |row| n += row.evaluations;
    break :blk n;
};

// ---------------------------------------------------------------------------
// Accounting checks
//
// These fail the build, not a test, so a case, a classification and a charge
// can never drift away from the surface they claim to cover.
// ---------------------------------------------------------------------------

comptime {
    @setEvalBranchQuota(10_000_000);
    // The published counts. Every number in the `## The published counts`
    // section of this file's header is checked here, so the prose and the
    // derived tables cannot drift apart.
    if (export_count != 417) {
        @compileError("api_round_lanes: the portable-vector surface is 417 public exports");
    }
    if (direct_timed_exports != 318) {
        @compileError("api_round_lanes: 318 exports are timed directly");
    }
    if (identical_canonical_exports != 96) {
        @compileError("api_round_lanes: 96 exports are the identical canonical route of a timed spelling");
    }
    if (compile_only_exports != 3) {
        @compileError("api_round_lanes: exactly three exports are compile-only");
    }
    if (direct_timed_rows != 321) {
        @compileError("api_round_lanes: 321 timed rows, because the core helpers carry extra instantiations");
    }
    if (case_count != 2889) {
        @compileError("api_round_lanes: 2889 timed cases");
    }
    if (budget_operations.len != 98) {
        @compileError("api_round_lanes: 98 accepted binary32 operations are budgeted");
    }
    if (budget_total != 170_016) {
        @compileError("api_round_lanes: one full pass costs 170016 accepted binary32 evaluations");
    }
    if (budget_peak != 52_080 or !std.mem.eql(u8, budget_peak_operation, "fmaf")) {
        @compileError("api_round_lanes: fmaf is the binding per-operation cost of one full pass");
    }

    // Every export name is a real public declaration of its owner module.
    for (entries) |entry| {
        if (!@hasDecl(Owner.container(entry.owner), entry.name)) {
            @compileError("api_round_lanes: an inventory entry names no public entry point: " ++ entry.name);
        }
    }

    // Every kernel a family reaches is named by one of the two charge tables,
    // so no route can carry an unstated binary32 charge.
    for (families) |family| {
        if (!declaresKernel(family.kernel)) {
            @compileError("api_round_lanes: a family reaches an undeclared kernel: " ++ family.kernel);
        }
        if (!family.fixed) {
            // The stem is the kernel spelling, which is the entry-point base
            // for every route but the camelCase aliases' snake_case kernels.
            if (!declaresKernel(kernelStem(family) ++ "h")) {
                @compileError("api_round_lanes: a family reaches an undeclared kernel: " ++ kernelStem(family) ++ "h");
            }
            if (!declaresKernel(kernelStem(family) ++ "f")) {
                @compileError("api_round_lanes: a family reaches an undeclared kernel: " ++ kernelStem(family) ++ "f");
            }
            if (!declaresKernel(kernelStem(family) ++ "d")) {
                @compileError("api_round_lanes: a family reaches an undeclared kernel: " ++ kernelStem(family) ++ "d");
            }
        }
    }

    // Every charge tag is a charge some family actually reaches, so no pattern
    // is dead metadata.
    var used = [_]bool{false} ** @typeInfo(Charge).@"enum".fields.len;
    for (families) |family| {
        if (family.fixed) {
            used[@intFromEnum(chargeOfKernel(family.kernel))] = true;
        } else {
            used[@intFromEnum(chargeOfKernel(kernelStem(family) ++ "h"))] = true;
            used[@intFromEnum(chargeOfKernel(kernelStem(family) ++ "f"))] = true;
            used[@intFromEnum(chargeOfKernel(kernelStem(family) ++ "d"))] = true;
        }
    }
    for (used, 0..) |was, at| {
        if (!was) {
            const key: Charge = @enumFromInt(at);
            @compileError("api_round_lanes: a charge tag no family reaches: " ++ @tagName(key));
        }
    }

    // The three comptime type queries are exercised on a real instantiation, so
    // they are not dead declarations and their results are checked rather than
    // discarded, and they are the only compile-only exports.
    const query_width = zmath.vector.intarg.widthOf(@Vector(8, f32));
    const query_lane = zmath.vector.intarg.LaneOf(@Vector(8, f32));
    const query_power = zmath.vector.intarg.PowerVector(f32, @Vector(8, f32));
    if (query_width != 8) {
        @compileError("api_round_lanes: widthOf must return the lane count");
    }
    if (query_lane != f32) {
        @compileError("api_round_lanes: LaneOf must return the lane type");
    }
    if (@typeInfo(query_power).array.len != 8) {
        @compileError("api_round_lanes: PowerVector must return one row per lane");
    }

    // The classifications partition the whole portable-vector surface.
    if (direct_timed_exports + identical_canonical_exports + compile_only_exports != export_count) {
        @compileError("api_round_lanes: the classifications do not partition the surface");
    }

    // Every timed row produces exactly one case per lane width and regime.
    if (case_count != direct_timed_rows * widths.len * regimes.len) {
        @compileError("api_round_lanes: the case count is not the timed rows times widths times regimes");
    }

    // A case name is built from the export name and the lane format alone, and
    // `owner_accounting` already proved that the distinct names of each owner
    // are exactly the exports that owner declares. This adds the cross-owner
    // half: no name may be declared by two owner modules at once.
    for (inventory) |entry| {
        for (inventory) |other| {
            if (other.owner != entry.owner and std.mem.eql(u8, other.name, entry.name)) {
                @compileError("api_round_lanes: two owner modules declare one name: " ++ entry.name);
            }
        }
    }

    // Every case names a canonical namespace and charges only accepted kernels.
    for (cases) |case| {
        if (!common.isNamespace(case.namespace)) {
            @compileError("api_round_lanes: a case names a namespace outside the canonical owners");
        }
        for (case.f32) |charge| {
            if (!common.isChargeOperation(charge.operation)) {
                @compileError("api_round_lanes: a charge names no accepted kernel: " ++ charge.operation);
            }
        }
    }

    // The budget table covers every operation the charge patterns can name.
    for (charge_patterns) |rows| {
        for (rows) |row| {
            var declared = false;
            for (budget_operations) |operation| {
                if (std.mem.eql(u8, operation, row.operation)) declared = true;
            }
            if (!declared) {
                @compileError("api_round_lanes: an accepted kernel is missing from the budget table: " ++ row.operation);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Lane encoding regressions
//
// The accounting above reads names, counts and checksums, so it cannot see
// what a fixture actually encodes: a `normal` lane that leaves the magnitude
// class its policy claims still hashes, and is only caught when a kernel
// built for a normal operand traps on it. These tests read the encoding
// itself, so a fixture that reaches outside its format fails here, next to
// the generator, instead of inside a timed case.
// ---------------------------------------------------------------------------

/// The exponent field of one assembled lane, read off that lane's own
/// encoding rather than off a rounded value.
fn exponentOf(comptime T: type, bits: u64) u64 {
    const spec: FloatSpec = comptime specOf(T);
    return (bits >> @intCast(spec.mantissa_bits)) & (exponentSpan(spec) - 1);
}

/// The largest exponent field a normal finite magnitude of `T` can carry: the
/// all-ones field is the infinities and the NaNs, so the top normal magnitude
/// sits one field below it.
fn maxNormalExponent(comptime T: type) u64 {
    return exponentSpan(comptime specOf(T)) - 2;
}

test "the tie window of every format stays inside the normal range" {
    // At f16 bias 15, a 17-wide window emits exponent zero and underflows at
    // mixed == 16. Check both ends and the modulus boundaries.
    const mixed_values = [_]u64{ 0, 1, 13, 14, 15, 16, 17, 30, 31, 32, 33, 46, 47, 48, 0xffff, 0x1_0000, 0x1234_5678_9abc_def0 };
    for (mixed_values) |mixed| {
        const exponent = exponentOf(f16, normalBits(f16, .tie, mixed));
        try std.testing.expect(exponent >= 1);
        try std.testing.expect(exponent <= maxNormalExponent(f16));
        const value = fromLaneBits(f16, normalBits(f16, .tie, mixed));
        try std.testing.expect(std.math.isFinite(value));
        try std.testing.expect(value != 0);
    }
    // binary32 and binary64 keep the whole seventeen-wide window, so the cap
    // is a property of binary16's bias and not of the fixture.
    for (mixed_values) |mixed| {
        try std.testing.expect(exponentOf(f32, normalBits(f32, .tie, mixed)) >= 1);
        try std.testing.expect(exponentOf(f32, normalBits(f32, .tie, mixed)) <= maxNormalExponent(f32));
        try std.testing.expect(exponentOf(f64, normalBits(f64, .tie, mixed)) >= 1);
        try std.testing.expect(exponentOf(f64, normalBits(f64, .tie, mixed)) <= maxNormalExponent(f64));
    }
}

test "every normal-regime lane is finite, and normal outside the small policy" {
    inline for (.{ f16, f32, f64 }) |T| {
        inline for (policies) |policy| {
            for (0..128) |index| {
                for (0..widths[widths.len - 1]) |lane| {
                    const bits = laneBitsOf(T, policy, .normal, index, lane);
                    const value = fromLaneBits(T, bits);
                    try std.testing.expect(std.math.isFinite(value));
                    // `small` is the one policy whose class IS the tiny
                    // magnitudes, so exponent zero, a zero or a subnormal, is
                    // the surface it draws on purpose. Every other policy is an
                    // ordinary spread of normal magnitudes, and a lane outside
                    // that range measures a path the regime does not name.
                    if (policy == .small) continue;
                    const exponent = exponentOf(T, bits);
                    try std.testing.expect(exponent >= 1);
                    try std.testing.expect(exponent <= maxNormalExponent(T));
                }
            }
        }
    }
}

test "the per-lane scalbln exponents span the i64 scale table, not the bounded degrees" {
    // The per-lane form and the broadcast form are one kernel with one
    // argument domain, so the per-lane form has to reach the same exponents:
    // both `i64` limits included. Those two limits are the field the degree
    // table never holds, so they are what tells the two tables apart.
    inline for ([_]Regime{ .normal, .skewed }) |regime| {
        var saw_min_limit = false;
        var saw_max_limit = false;
        var saw_long_range = false;
        for (0..4096) |index| {
            const lanes = intLanesOf(i64, 4, .scale64, regime, index);
            inline for (0..4) |lane| {
                const value = lanes[lane];
                if (value == std.math.minInt(i64)) saw_min_limit = true;
                if (value == std.math.maxInt(i64)) saw_max_limit = true;
                if (value == 1023 or value == -1023) saw_long_range = true;
            }
        }
        try std.testing.expect(saw_min_limit);
        try std.testing.expect(saw_max_limit);
        try std.testing.expect(saw_long_range);
    }
}
