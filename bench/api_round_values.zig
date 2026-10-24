//! API round, value-type slice: the six named-component vector types and the
//! four quaternion types.
//!
//! Scope: `zmath.vector.{Vec2f,Vec3f,Vec4f,Vec2d,Vec3d,Vec4d}` and
//! `zmath.quaternion.{Quatf,Quatd,UnitQuatf,UnitQuatd}`, every public method
//! and every public static factory of each, in every input regime the module's
//! own tests give a branch to. Nothing outside those two namespaces is timed
//! here, and nothing in the runtime is edited.
//!
//! Measurement contract:
//!
//! * Every `invoke` is `noinline` and takes a runtime `usize`. Numerical
//!   operands come from tables indexed by that runtime value. Unit values and
//!   conversion fixtures are built at comptime, outside the measured operation.
//!   Zero/one factories have no runtime operand and can fold to constants;
//!   their rows measure callback/checksum overhead, not arithmetic latency.
//! * Every `invoke` returns a checksum over the whole semantic result: all
//!   components by their exact bits, boolean results, the tag and the payload
//!   of every optional, and arrays and `@Vector`s elementwise. `+0` and `-0`,
//!   and a NaN payload, therefore change the checksum.
//! * `f32` charges count accepted canonical kernel calls per one `invoke`.
//!   `f64` kernels are not charged. Plain IEEE arithmetic and bit manipulation
//!   are not kernels and consume no charge, and so do the static factories,
//!   which move bits and call no kernel.
//!
//! Kernel accounting, read off the source of the two modules:
//!
//! * `vector_value.lengthOf` seeds the fold with the first component's own
//!   magnitude, so it calls `hypot` once per component AFTER the first:
//!   1 fold for `Vec2*`, 2 for `Vec3*`, 3 for `Vec4*`. `length`, `distance`
//!   and `normalize` each run exactly one fold. Nothing else in the module
//!   reaches a kernel: `add`, `sub`, `neg`, `scale`, `scaleVec`, `divScalar`,
//!   `dot`, `cross`, `lerp`, `eq` and `isFinite` are hardware arithmetic and
//!   bit rules. `min` calls `fmin` once per component, `max` calls `fmax`
//!   once per component, `clamp` is `max` then `min` so one of each per
//!   component, and `abs` calls `absf` once per component.
//! * `quaternion.lengthOf` folds four components, so 3 calls. `UnitQuat.init`
//!   folds twice, once for the normalization and once for the unit band, so 6.
//!   `UnitQuat.mul`, `UnitQuat.then` and `UnitQuat.lerp` renormalize, so 3
//!   each. `Quat.fromAxisAngle` normalizes the axis through `Vec3.length`, so
//!   2, then adds one `sinf` and one `cosf`; `UnitQuat.fromAxisAngle` routes
//!   through that and then through `init`, so 8 plus the sine and the cosine.
//!   `UnitQuat.slerp` short-circuits `t` at 0 and 1 with no kernel; its
//!   normalized-lerp branch renormalizes, so 3; its spherical branch runs one
//!   `fmin`, one `fmax`, one `acosf`, three `sinf`, and then `init`, so 6 more
//!   `hypot`. `Quat.inverse`, `Quat.conjugate`, `UnitQuat.conjugate`,
//!   `UnitQuat.inverse`, `UnitQuat.rotate`, `dot`, `lengthSquared`,
//!   `normSquared`, `eq` and `isFinite` reach no kernel at all.

const std = @import("std");
const zmath = @import("zmath");
const common = @import("api_round_common.zig");

const Vec2f = zmath.vector.Vec2f;
const Vec3f = zmath.vector.Vec3f;
const Vec4f = zmath.vector.Vec4f;
const Vec2d = zmath.vector.Vec2d;
const Vec3d = zmath.vector.Vec3d;
const Vec4d = zmath.vector.Vec4d;
const Quatf = zmath.quaternion.Quatf;
const Quatd = zmath.quaternion.Quatd;
const UnitQuatf = zmath.quaternion.UnitQuatf;
const UnitQuatd = zmath.quaternion.UnitQuatd;

const Charge = common.Charge;
const Case = common.Case;

/// The number of operands one table holds. A power of two, so turning the
/// runtime index into a table slot costs a mask and nothing else.
const depth = 8;

/// The offset that pairs two table entries. A twin regime pairs an entry with
/// its neighbour, so the two operands differ in exactly one property and in
/// nothing else; every other regime pairs entries three apart, so the operands
/// are unrelated.
fn partnerOffset(comptime regime: anytype) comptime_int {
    return switch (regime) {
        .zero_twin, .nan_twin => 1,
        else => 3,
    };
}

fn charge(comptime operation: []const u8, comptime count: u32) Charge {
    return .{ .operation = operation, .count = count };
}

/// The comptime work one case's own fixture tables may spend. Every operand is
/// an exact bit pattern or an exact comptime expression, and the whole case
/// list is one container-scope array, so the branches one case spends are
/// charged against the next case's budget as well. The default quota is 1000
/// backwards branches and the fourth `vecCase` in the list spends it, so every
/// builder that fills a table states what its own subtree may spend instead.
/// The number is finite and far above what any one case costs.
const fixture_branch_quota: u32 = 10_000_000;

// ---------------------------------------------------------------------------
// Format facts
// ---------------------------------------------------------------------------

/// The component names in declaration order, the same order the types declare.
const component_names = [4][]const u8{ "x", "y", "z", "w" };

/// The component type of a `Vec*` value type.
fn Component(comptime V: type) type {
    return @typeInfo(V).@"struct".field_types[0];
}

/// The declared component count of a `Vec*` value type. The return type is
/// `comptime_int`, not `usize`, so the call is evaluated at compile time at
/// every site rather than once at run time. That is what lets the arity
/// switches below be resolved before the arm that is not taken is ever
/// analyzed: a two-component type has no `w` field to name, and its `init`
/// takes two arguments rather than three. A `usize` result would leave the
/// comparison a run-time branch and every arm would have to be valid.
fn width(comptime V: type) comptime_int {
    return @typeInfo(V).@"struct".field_names.len;
}

/// The component type of a raw quaternion type.
fn Scalar(comptime Q: type) type {
    return @typeInfo(Q).@"struct".field_types[0];
}

/// The validated type that wraps the raw quaternion type `Q`.
fn UnitOf(comptime Q: type) type {
    return switch (Q) {
        Quatf => UnitQuatf,
        Quatd => UnitQuatd,
        else => @compileError("UnitOf is for Quatf and Quatd"),
    };
}

/// The `Vec3*` of the same precision as the raw quaternion type `Q`.
fn Vec3Of(comptime Q: type) type {
    return switch (Q) {
        Quatf => Vec3f,
        Quatd => Vec3d,
        else => @compileError("Vec3Of is for Quatf and Quatd"),
    };
}

/// The float built from the bit pattern `pattern`, truncated to the width of
/// `T`, so a special value is written as the encoding the specification names
/// and not as a decimal literal that might round.
fn fromBits(comptime T: type, comptime pattern: u64) T {
    if (T == f32) return @bitCast(@as(u32, @truncate(pattern)));
    if (T == f64) return @bitCast(pattern);
    @compileError("fromBits is for f32 or f64");
}

fn infinityBits(comptime T: type) u64 {
    if (T == f32) return 0x7f80_0000;
    if (T == f64) return 0x7ff0_0000_0000_0000;
    @compileError("infinityBits is for f32 or f64");
}

fn quietNanBits(comptime T: type) u64 {
    if (T == f32) return 0x7fc0_0000;
    if (T == f64) return 0x7ff8_0000_0000_0000;
    @compileError("quietNanBits is for f32 or f64");
}

fn signalingNanBits(comptime T: type) u64 {
    if (T == f32) return 0x7f80_0001;
    if (T == f64) return 0x7ff0_0000_0000_0001;
    @compileError("signalingNanBits is for f32 or f64");
}

fn signBit(comptime T: type) u64 {
    if (T == f32) return 0x8000_0000;
    if (T == f64) return 0x8000_0000_0000_0000;
    @compileError("signBit is for f32 or f64");
}

fn smallestSubnormal(comptime T: type) T {
    if (T == f32) return @as(f32, 0x1p-149);
    if (T == f64) return @as(f64, 0x1p-1074);
    @compileError("smallestSubnormal is for f32 or f64");
}

fn smallestNormal(comptime T: type) T {
    if (T == f32) return @as(f32, 0x1p-126);
    if (T == f64) return @as(f64, 0x1p-1022);
    @compileError("smallestNormal is for f32 or f64");
}

/// The largest finite value of the format, `floatMax`: `0x7f7f_ffff` in
/// binary32 and `0x7fe_ffff_ffff_ffff` in binary64. These are encodings, not
/// magnitudes, so they go through `fromBits`. Written as a numeric literal
/// instead, binary32 rejects the value outright, because no `f32` holds
/// `2139095039`, and binary64 accepts it and is then silently wrong: the
/// regime that should overflow the fold would not.
fn largestFinite(comptime T: type) T {
    if (T == f32) return fromBits(T, 0x7f7f_ffff);
    if (T == f64) return fromBits(T, 0x7fef_ffff_ffff_ffff);
    @compileError("largestFinite is for f32 or f64");
}

// ---------------------------------------------------------------------------
// Component regimes
//
// A regime is a way of choosing operands, not a way of choosing an operation.
// Two regimes over one operation are two different branches in the module, and
// a regime that a method cannot tell apart from another is not written.
// Every component is an exact bit pattern or an exact comptime expression, so
// no regime depends on how a decimal literal happened to round.
// ---------------------------------------------------------------------------

/// A finite, mixed-sign, quarter-step value in `[-4, 4)`: no zero, no
/// infinity, no NaN. This is the regime every other regime is read against.
fn ordinaryComponent(comptime T: type, comptime seed: usize) T {
    const steps: i32 = @as(i32, @intCast((seed * 7 + 5) % 31)) - 15;
    const value: T = @floatFromInt(steps);
    return value / 4.0;
}

/// A component at the scale where `x * x` overflows the format while `x`
/// itself stays finite. This is the regime that separates the `hypot` fold
/// from a sum of squares.
fn hugeComponent(comptime T: type, comptime seed: usize) T {
    const scale: T = if (T == f32) 1.0e30 else 1.0e200;
    return if (seed % 2 == 0) scale else -scale;
}

/// One of the two magnitudes whose square is underflow, so a sum of squares
/// loses the answer and the fold keeps it.
fn tinyComponent(comptime T: type, comptime seed: usize, comptime slot: usize) T {
    return switch ((seed + slot) % 3) {
        0 => smallestSubnormal(T),
        1 => smallestNormal(T),
        else => smallestSubnormal(T) * 3.0,
    };
}

/// A signed zero, a finite value, or the negation of a finite value. `min`
/// prefers `-0`, `max` prefers `+0`, `neg` and `abs` clear a negative zero, and
/// `eq` separates the two zeros, so one regime reaches all four rules.
fn signedZeroComponent(comptime T: type, comptime seed: usize, comptime slot: usize) T {
    return switch ((seed + slot) % 4) {
        0 => @as(T, 0.0),
        1 => @as(T, -0.0),
        2 => ordinaryComponent(T, seed * 8 + slot),
        else => -ordinaryComponent(T, seed * 8 + slot),
    };
}

/// An infinity, a negative infinity, the positive canonical quiet NaN, a
/// signaling NaN, a quiet NaN with a payload, or a finite value. The finite
/// entry matters: it gives the module's NaN scan an operand that is not a NaN
/// to reject, and it gives `isFinite` and `eq` a lane where the answer differs
/// from the lane beside it.
fn nonfiniteComponent(comptime T: type, comptime seed: usize, comptime slot: usize) T {
    return switch ((seed + slot) % 6) {
        0 => fromBits(T, infinityBits(T)),
        1 => fromBits(T, infinityBits(T) | signBit(T)),
        2 => fromBits(T, quietNanBits(T)),
        3 => fromBits(T, signalingNanBits(T)),
        4 => fromBits(T, quietNanBits(T) | 1),
        else => ordinaryComponent(T, seed * 8 + slot),
    };
}

/// Lane 0 of the twin regimes. `.zero_twin` alternates the sign of a zero in
/// lane 0 and leaves every other lane identical, so a paired comparison is
/// exactly the "the two zeros are not equal" branch. `.nan_twin` gives every
/// lane a quiet NaN with a per-entry payload, so a paired comparison is
/// exactly the "any NaN equals any other NaN" branch and a bit comparison
/// would fail.
fn twinComponent(comptime T: type, comptime regime: anytype, comptime seed: usize, comptime slot: usize) T {
    if (regime == .nan_twin) return fromBits(T, quietNanBits(T) | @as(u64, @intCast(seed % 4 + 1)));
    if (slot != 0) return ordinaryComponent(T, 3);
    return if (seed % 2 == 0) @as(T, 0.0) else @as(T, -0.0);
}

/// The input regimes a vector case can run under.
const VecRegime = enum {
    /// Ordinary finite values.
    ordinary,
    /// One component at the scale where a square overflows.
    huge,
    /// Subnormal and smallest-normal components.
    tiny,
    /// Signed zeros throughout, which is the regime `normalize` returns the
    /// input unchanged from and where a length is a positive zero.
    zero,
    /// Signed zeros among ordinary values.
    signed_zero,
    /// Infinities and NaNs in every lane.
    nonfinite,
    /// Lane 0 is a zero whose sign alternates per entry.
    zero_twin,
    /// Every lane is a quiet NaN with a per-entry payload.
    nan_twin,
    /// The exact-endpoint argument of `lerp`, so the short circuit runs.
    endpoint,
    /// Bounds the wrong way round, so `clamp` returns the upper bound.
    reversed,
};

fn vecComponent(
    comptime T: type,
    comptime regime: VecRegime,
    comptime seed: usize,
    comptime slot: usize,
) T {
    return switch (regime) {
        .ordinary, .endpoint, .reversed => ordinaryComponent(T, seed * 8 + slot),
        .huge => if (slot == 0) hugeComponent(T, seed) else ordinaryComponent(T, seed * 8 + slot),
        .tiny => tinyComponent(T, seed, slot),
        .zero => if (seed % 2 == 0) @as(T, 0.0) else @as(T, -0.0),
        .signed_zero => signedZeroComponent(T, seed, slot),
        .nonfinite => nonfiniteComponent(T, seed, slot),
        .zero_twin, .nan_twin => twinComponent(T, regime, seed, slot),
    };
}

/// A `V` whose every lane comes from `regime`.
fn regimeVec(comptime V: type, comptime regime: VecRegime, comptime seed: usize) V {
    const lanes: usize = width(V);
    var out: V = undefined;
    inline for (0..lanes) |slot| {
        @field(out, component_names[slot]) = vecComponent(Component(V), regime, seed, slot);
    }
    return out;
}

fn regimeVecs(comptime V: type, comptime regime: VecRegime) [depth]V {
    var out: [depth]V = undefined;
    for (0..depth) |index| out[index] = regimeVec(V, regime, index);
    return out;
}

/// The scalar argument of the regime: the factor of a `scale`, the divisor of a
/// `divScalar`, the `t` of a `lerp`. `.endpoint` alternates the two exact
/// endpoints, which is the branch `lerp` short-circuits on.
fn regimeScalar(comptime T: type, comptime regime: VecRegime, comptime index: usize) T {
    return switch (regime) {
        .endpoint => @as(T, if (index % 2 == 0) 0.0 else 1.0),
        .zero => @as(T, if (index % 2 == 0) -0.0 else 0.0),
        else => ordinaryComponent(T, index * 3 + 1),
    };
}

fn regimeScalars(comptime T: type, comptime regime: VecRegime) [depth]T {
    var out: [depth]T = undefined;
    for (0..depth) |index| out[index] = regimeScalar(T, regime, index);
    return out;
}

/// The arrays a `fromArray` reads, and the `@Vector`s a `fromVector` reads.
/// Both are built at comptime so the timed region holds the bridge alone.
fn arraysOf(comptime V: type, comptime vectors: anytype) [depth][width(V)]Component(V) {
    var out: [depth][width(V)]Component(V) = undefined;
    for (0..depth) |index| out[index] = vectors[index].toArray();
    return out;
}

fn lanesOf(comptime V: type, comptime vectors: anytype) [depth]@Vector(width(V), Component(V)) {
    var out: [depth]@Vector(width(V), Component(V)) = undefined;
    for (0..depth) |index| out[index] = vectors[index].toVector();
    return out;
}

/// `V.init` called with the components of `value`. The arity is fixed at
/// comptime, so this is the named-component constructor and not the array
/// bridge. `width` returns `comptime_int`, so the switch value is known here
/// and only the prong the width selects is analyzed: a two-component type
/// never names a `z` or a `w`, and a three-component type never names a `w`,
/// so no other arity has to compile.
fn initOf(comptime V: type, value: V) V {
    return switch (width(V)) {
        2 => V.init(value.x, value.y),
        3 => V.init(value.x, value.y, value.z),
        4 => V.init(value.x, value.y, value.z, value.w),
        else => @compileError("a Vec* value type has 2, 3, or 4 components"),
    };
}

/// `cross` exists only on the three-component types, so it gets its own
/// factory instead of an arm of the shared one.
fn CrossInvoke(comptime V: type, comptime regime: VecRegime) type {
    const vectors = regimeVecs(V, regime);
    return struct {
        const Self = @This();
        noinline fn invoke(index: usize) u64 {
            const left = vectors[index % depth];
            const right = vectors[(index + partnerOffset(regime)) % depth];
            return common.hash(left.cross(right));
        }
    };
}

/// The public method families of a `Vec*` value type. `cross` is absent
/// because only the three-component types have it; see `CrossInvoke`.
const VecOp = enum {
    // Construction and the bridges out.
    init,
    zero,
    one,
    from_array,
    to_array,
    to_vector,
    from_vector,
    // Componentwise arithmetic.
    add,
    sub,
    neg,
    scale,
    scale_vec,
    div_scalar,
    dot,
    // Magnitudes.
    length_squared,
    length,
    distance_squared,
    distance,
    normalize,
    // Interpolation.
    lerp,
    // Selection.
    min,
    max,
    clamp,
    abs,
    // Predicates.
    is_finite,
    eq,
};

/// The timed body of one vector case. `op` is fixed at comptime, so the
/// switch over it is a single arm and nothing below is a runtime branch.
fn VecInvoke(comptime V: type, comptime op: VecOp, comptime regime: VecRegime) type {
    const vectors = regimeVecs(V, regime);
    const arrays = arraysOf(V, vectors);
    const lanes = lanesOf(V, vectors);
    const scalars = regimeScalars(Component(V), regime);
    return struct {
        /// The first operand.
        fn first(index: usize) V {
            return vectors[index % depth];
        }

        /// The second operand, from the slot the regime pairs with the first.
        fn second(index: usize) V {
            return vectors[(index + partnerOffset(regime)) % depth];
        }

        /// The scalar argument of `scale`, `divScalar` and `lerp`.
        fn scalar(index: usize) Component(V) {
            return scalars[index % depth];
        }

        /// The second bound of `clamp`.
        fn bound(index: usize) V {
            return vectors[(index + 5) % depth];
        }

        /// `clamp` with the bounds in the order the regime asks for.
        fn clamped(index: usize) V {
            return if (regime == .reversed)
                first(index).clamp(second(index), bound(index))
            else
                first(index).clamp(bound(index), second(index));
        }

        noinline fn invoke(index: usize) u64 {
            // `op` is fixed at comptime, so this switch is one arm and the
            // operands an arm does not read are never loaded at all.
            return switch (op) {
                .init => common.hash(initOf(V, first(index))),
                .zero => common.hash(V.zero()),
                .one => common.hash(V.one()),
                .from_array => common.hash(V.fromArray(arrays[index % depth])),
                .to_array => common.hash(first(index).toArray()),
                .to_vector => common.hash(first(index).toVector()),
                .from_vector => common.hash(V.fromVector(lanes[index % depth])),
                .add => common.hash(first(index).add(second(index))),
                .sub => common.hash(first(index).sub(second(index))),
                .neg => common.hash(first(index).neg()),
                .scale => common.hash(first(index).scale(scalar(index))),
                .scale_vec => common.hash(first(index).scaleVec(second(index))),
                .div_scalar => common.hash(first(index).divScalar(scalar(index))),
                .dot => common.hash(first(index).dot(second(index))),
                .length_squared => common.hash(first(index).lengthSquared()),
                .length => common.hash(first(index).length()),
                .distance_squared => common.hash(first(index).distanceSquared(second(index))),
                .distance => common.hash(first(index).distance(second(index))),
                .normalize => common.hash(first(index).normalize()),
                .lerp => common.hash(first(index).lerp(second(index), scalar(index))),
                .min => common.hash(first(index).min(second(index))),
                .max => common.hash(first(index).max(second(index))),
                .clamp => common.hash(clamped(index)),
                .abs => common.hash(first(index).abs()),
                .is_finite => common.hash(first(index).isFinite()),
                .eq => common.hash(first(index).eq(second(index))),
            };
        }
    };
}

/// One vector case. `namespace` is the module that owns the entry point,
/// which for every `Vec*` is `zmath.vector`.
fn vecCase(
    comptime V: type,
    comptime op: VecOp,
    comptime regime: VecRegime,
    comptime name: []const u8,
    comptime calls: u32,
    comptime f32_charges: []const Charge,
) Case {
    @setEvalBranchQuota(fixture_branch_quota);
    return .{
        .name = name,
        .namespace = "vector",
        .invoke = VecInvoke(V, op, regime).invoke,
        .calls = calls,
        .f32 = f32_charges,
    };
}

/// One `cross` case. Only the three-component types reach it.
fn crossCase(
    comptime V: type,
    comptime regime: VecRegime,
    comptime name: []const u8,
    comptime f32_charges: []const Charge,
) Case {
    @setEvalBranchQuota(fixture_branch_quota);
    return .{
        .name = name,
        .namespace = "vector",
        .invoke = CrossInvoke(V, regime).invoke,
        .calls = 32,
        .f32 = f32_charges,
    };
}

/// The `hypot` fold of one length, which seeds with the first component's own
/// magnitude and so calls the kernel once per component after the first.
/// A binary64 type folds through `hypotd` instead, which is not a binary32
/// kernel, so `Vec2d`, `Vec3d` and `Vec4d` charge `no_f32` here.
fn foldCharge(comptime V: type) []const Charge {
    return &.{charge("hypotf", @as(u32, @intCast(width(V) - 1)))};
}

/// One accepted selection kernel per component, for `min`, `max` and `abs`.
/// A binary64 type reaches `fmind`, `fmaxd` and `absd` instead, which are not
/// binary32 kernels, so those cases charge `no_f32`.
fn perComponentCharge(comptime operation: []const u8, comptime V: type) []const Charge {
    return &.{charge(operation, @as(u32, @intCast(width(V))))};
}

/// `clamp` is `max` then `min`, so one call of each per component.
fn clampCharges(comptime V: type) []const Charge {
    return &.{
        charge("fmaxf", @as(u32, @intCast(width(V)))),
        charge("fminf", @as(u32, @intCast(width(V)))),
    };
}

/// No case in this slice calls an f32 kernel.
const no_f32: []const Charge = &.{};

// ---------------------------------------------------------------------------
// Quaternion regimes
// ---------------------------------------------------------------------------

/// The input regimes a quaternion case can run under. The raw regimes feed
/// the algebra, the `unit_` regimes feed the validated type, and the last
/// five are the four reasons `fromAxisAngle` reports `null` plus the ordinary
/// pair that does not.
const QuatRegime = enum {
    /// Ordinary finite components, not unit.
    ordinary,
    /// Every component at the scale where the length fold itself overflows the
    /// format, which is the case the validated constructor rejects.
    huge,
    /// Every component large enough that a sum of squares overflows while the
    /// `hypot` fold does not. This is the regime the fold exists for, and the
    /// validated constructor normalizes such a value rather than rejecting it.
    large,
    /// Every component subnormal. The fold cannot scale a subnormal, so
    /// normalization lands four ones whose length is not one, and the unit
    /// band rejects the value.
    tiny,
    /// Signed zeros throughout, which is the quaternion with no inverse.
    zero,
    /// Signed zeros among ordinary values.
    signed_zero,
    /// Infinities and NaNs in every lane.
    nonfinite,
    /// Lane 0 is a zero whose sign alternates per entry.
    zero_twin,
    /// Every lane is a quiet NaN with a per-entry payload.
    nan_twin,
    /// An arbitrary pair of validated rotations.
    unit,
    /// A validated pair whose dot product is above the near-parallel
    /// threshold, so `slerp` takes its normalized-lerp branch.
    unit_near,
    /// A validated pair whose dot product is at or below the threshold, so
    /// `slerp` takes the spherical branch.
    unit_arc,
    /// A validated pair whose dot product is negative, so `slerp` negates the
    /// second endpoint before it chooses a branch.
    unit_far,
    /// The exact-endpoint argument of `lerp` and `slerp`.
    endpoint,
    /// A non-finite `t`, which `slerp` reports and `lerp` propagates.
    t_nonfinite,
    /// A zero axis, which has no direction.
    axis_zero,
    /// A non-finite axis, which has no finite length.
    axis_nonfinite,
    /// A finite axis whose length fold overflowed the format.
    axis_overflow,
    /// A non-finite angle, which has no half to take a sine of.
    angle_nonfinite,
};

fn quatComponent(
    comptime T: type,
    comptime regime: QuatRegime,
    comptime seed: usize,
    comptime slot: usize,
) T {
    return switch (regime) {
        .huge => largestFinite(T),
        .large => hugeComponent(T, seed),
        .tiny => if (seed % 2 == 0) smallestSubnormal(T) else -smallestSubnormal(T),
        .zero => if (seed % 2 == 0) @as(T, 0.0) else @as(T, -0.0),
        .signed_zero => signedZeroComponent(T, seed, slot),
        .nonfinite => nonfiniteComponent(T, seed, slot),
        .zero_twin, .nan_twin => twinComponent(T, regime, seed, slot),
        // The validated regimes never read a raw component: their operands
        // come from the unit tables below.
        else => ordinaryComponent(T, seed * 4 + slot),
    };
}

fn rawQuat(comptime Q: type, comptime regime: QuatRegime, comptime seed: usize) Q {
    var out: Q = undefined;
    inline for (0..4) |slot| {
        @field(out, component_names[slot]) = quatComponent(Scalar(Q), regime, seed, slot);
    }
    return out;
}

fn rawQuats(comptime Q: type, comptime regime: QuatRegime) [depth]Q {
    var out: [depth]Q = undefined;
    for (0..depth) |index| out[index] = rawQuat(Q, regime, index);
    return out;
}

fn rawArrays(comptime Q: type, comptime quats: anytype) [depth][4]Scalar(Q) {
    var out: [depth][4]Scalar(Q) = undefined;
    for (0..depth) |index| out[index] = quats[index].toArray();
    return out;
}

// ---------------------------------------------------------------------------
// Validated rotations

// The unit operands are stored at comptime, because constructing a rotation is
// not the operation any of the cases below measures. They are built from four
// components that are already unit, and never through `init`, because `init`
// normalizes and measures through the `hypot` kernel: calling it here would
// run accepted math at comptime, and calling it inside a timed body would run
// it again on every one of the calls a row counts. What stands in for the
// constructor is the band check below, which reaches no kernel at all.
// ---------------------------------------------------------------------------

/// The unit band `UnitQuat.init` enforces, restated on the squared length. The
/// constructor normalizes and then rejects a length further than
/// `8 * floatEps(T)` from one. Here `|l * l - 1| = |l - 1| * (l + 1)`, and a
/// length inside that band sits a few ulps from one, so `16 * floatEps(T)` is
/// the same band one square out.
fn unitBandSquared(comptime T: type) T {
    return 16 * std.math.floatEps(T);
}

/// A stored rotation from four components that are unit themselves. The check
/// is the constructor's own band restated on the squared length, and
/// `lengthSquared` is four products and three additions, so confirming the
/// invariant reaches no kernel here or in any timed body.
fn storedUnit(
    comptime Q: type,
    comptime x: f64,
    comptime y: f64,
    comptime z: f64,
    comptime w: f64,
) UnitOf(Q) {
    const T = Scalar(Q);
    const value = UnitOf(Q){ .raw = Q.init(
        @as(T, @floatCast(x)),
        @as(T, @floatCast(y)),
        @as(T, @floatCast(z)),
        @as(T, @floatCast(w)),
    ) };
    if (@abs(value.raw.lengthSquared() - 1.0) > unitBandSquared(T)) {
        @compileError("a stored validated rotation is not unit");
    }
    return value;
}

/// The scalar component that completes a half-angle sine to a unit pair. This
/// is the only rounding between the literal and the stored value, and it is
/// comptime arithmetic on a literal rather than a call to a kernel.
fn unitCosine(comptime s: f64) f64 {
    return @sqrt(1.0 - s * s);
}

/// The rotation about `+z` whose half-angle sine is `s`.
fn zTurn(comptime Q: type, comptime s: f64) UnitOf(Q) {
    return storedUnit(Q, 0, 0, s, unitCosine(s));
}

/// The same rotation named by its negation. `q` and `-q` are one rotation with
/// two names, which is the whole reason `slerp` may negate an endpoint.
fn zTurnNegated(comptime Q: type, comptime s: f64) UnitOf(Q) {
    return storedUnit(Q, 0, 0, s, -unitCosine(s));
}

/// An arbitrary rotation whose vector part is given and whose scalar part
/// completes it to unit length. Three free components and one square root keep
/// the eight entries unrelated to one another and every one of them a rotation.
fn unitTurnOf(comptime Q: type, comptime x: f64, comptime y: f64, comptime z: f64) UnitOf(Q) {
    return storedUnit(Q, x, y, z, @sqrt(1.0 - (x * x + y * y + z * z)));
}

/// Eight arbitrary rotations about no common axis, for the cases where the
/// relationship between the two operands is not what the case measures.
fn unitTable(comptime Q: type) [depth]UnitOf(Q) {
    return .{
        unitTurnOf(Q, 0, 0, 0),
        unitTurnOf(Q, 0.2, 0.4, 0.89),
        unitTurnOf(Q, -0.5, 0.25, 0.7),
        unitTurnOf(Q, 1, 0, 0),
        unitTurnOf(Q, 0.577, 0.577, 0.577),
        unitTurnOf(Q, 0.3, 0.5, 0.81),
        unitTurnOf(Q, -0.25, 0.5, 0.75),
        unitTurnOf(Q, 0.11, -0.22, 0.33),
    };
}

/// Half-angle sines that keep a pair above the near-parallel threshold. That
/// threshold is four square roots of the epsilon below one, so it is 0.9986
/// in binary32 and one minus 6e-8 in binary64: a sine that clears it in one
/// format falls below it in the other, and the two precisions need their own
/// table or one of them silently measures the other branch.
fn nearSines(comptime T: type) [depth]f64 {
    if (T == f32) return .{ 0.003, 0.006, 0.009, 0.012, 0.015, 0.018, 0.021, 0.024 };
    if (T == f64) return .{ 1.5e-5, 3.0e-5, 4.5e-5, 6.0e-5, 7.5e-5, 9.0e-5, 1.05e-4, 1.2e-4 };
    @compileError("nearSines is for f32 or f64");
}

/// The second operand of a near-parallel pair: a much smaller turn about the
/// same axis, so the dot product of the pair stays above the threshold with
/// room for the few ulps `init` rounds away.
fn nearPartners(comptime T: type) [depth]f64 {
    if (T == f32) return .{ 0.001, 0.002, 0.003, 0.004, 0.005, 0.006, 0.007, 0.008 };
    if (T == f64) return .{ 5.0e-6, 1.0e-5, 1.5e-5, 2.0e-5, 2.5e-5, 3.0e-5, 3.5e-5, 4.0e-5 };
    @compileError("nearPartners is for f32 or f64");
}

/// Wide half-angle sines and their partners. Every product of the two
/// cosines is far below the near-parallel threshold in both formats, so the
/// pair always takes the spherical branch.
const arc_sines: [depth]f64 = .{ 0.9, 0.8, 0.7, 0.6, 0.5, 0.85, 0.75, 0.65 };
const arc_partners: [depth]f64 = .{ 0.1, 0.2, 0.3, 0.4, 0.05, 0.15, 0.25, 0.35 };

fn unitLefts(comptime Q: type, comptime regime: QuatRegime) [depth]UnitOf(Q) {
    return switch (regime) {
        .unit_near => blk: {
            var out: [depth]UnitOf(Q) = undefined;
            const sines = nearSines(Scalar(Q));
            for (0..depth) |index| out[index] = zTurn(Q, sines[index]);
            break :blk out;
        },
        .unit_arc, .unit_far => blk: {
            var out: [depth]UnitOf(Q) = undefined;
            for (0..depth) |index| out[index] = zTurn(Q, arc_sines[index]);
            break :blk out;
        },
        else => unitTable(Q),
    };
}

fn unitRights(comptime Q: type, comptime regime: QuatRegime) [depth]UnitOf(Q) {
    return switch (regime) {
        .unit_near => blk: {
            var out: [depth]UnitOf(Q) = undefined;
            const partners = nearPartners(Scalar(Q));
            for (0..depth) |index| out[index] = zTurn(Q, partners[index]);
            break :blk out;
        },
        .unit_arc => blk: {
            var out: [depth]UnitOf(Q) = undefined;
            for (0..depth) |index| out[index] = zTurn(Q, arc_partners[index]);
            break :blk out;
        },
        .unit_far => blk: {
            var out: [depth]UnitOf(Q) = undefined;
            for (0..depth) |index| out[index] = zTurnNegated(Q, arc_partners[index]);
            break :blk out;
        },
        else => unitTable(Q),
    };
}

// ---------------------------------------------------------------------------
// The axis and the angle of the axis-angle constructor
// ---------------------------------------------------------------------------

fn axisComponent(comptime T: type, comptime regime: QuatRegime, comptime seed: usize, comptime slot: usize) T {
    return switch (regime) {
        .axis_zero => if (seed % 2 == 0) @as(T, 0.0) else @as(T, -0.0),
        // Every lane is non-finite, so the axis is rejected by `isFinite`
        // before the length is ever measured. The regime is the rejection, not
        // a mixture in which some entries happen to succeed.
        .axis_nonfinite => switch ((seed + slot) % 3) {
            0 => fromBits(T, infinityBits(T)),
            1 => fromBits(T, infinityBits(T) | signBit(T)),
            else => fromBits(T, quietNanBits(T)),
        },
        // A finite axis whose true norm is past the top of the format, so the
        // fold overflows and there is no representable direction left.
        .axis_overflow => largestFinite(T),
        else => ordinaryComponent(T, seed * 4 + slot),
    };
}

fn axisOf(comptime Q: type, comptime regime: QuatRegime, comptime seed: usize) Vec3Of(Q) {
    const V = Vec3Of(Q);
    const lanes: usize = width(V);
    var out: V = undefined;
    inline for (0..lanes) |slot| {
        @field(out, component_names[slot]) = axisComponent(Scalar(Q), regime, seed, slot);
    }
    return out;
}

fn axesOf(comptime Q: type, comptime regime: QuatRegime) [depth]Vec3Of(Q) {
    var out: [depth]Vec3Of(Q) = undefined;
    for (0..depth) |index| out[index] = axisOf(Q, regime, index);
    return out;
}

fn radiansOf(comptime T: type, comptime regime: QuatRegime, comptime index: usize) T {
    return switch (regime) {
        // Every angle is non-finite, so the rejection is the regime rather
        // than one of the outcomes inside it.
        .angle_nonfinite => switch (index % 3) {
            0 => fromBits(T, infinityBits(T)),
            1 => fromBits(T, infinityBits(T) | signBit(T)),
            else => fromBits(T, signalingNanBits(T)),
        },
        else => radiansStep(T, index),
    };
}

/// Ordinary angles a quarter of a radian apart, over more than a half turn, so
/// the constructed quaternion is neither the identity nor a small rotation.
fn radiansStep(comptime T: type, comptime index: usize) T {
    const base: T = 0.3;
    const step: T = 0.9;
    return base + @as(T, @floatFromInt(index)) * step;
}

/// The `t` of `lerp` and `slerp`. The ordinary value is strictly inside the
/// interval, so it never lands on either short circuit.
fn tOf(comptime T: type, comptime regime: QuatRegime, comptime index: usize) T {
    return switch (regime) {
        .endpoint => @as(T, if (index % 2 == 0) 0.0 else 1.0),
        // Every `t` is non-finite, so `slerp` rejects all of them before it
        // reaches a kernel and `lerp` propagates all of them as a NaN.
        .t_nonfinite => switch (index % 3) {
            0 => fromBits(T, infinityBits(T)),
            1 => fromBits(T, infinityBits(T) | signBit(T)),
            else => fromBits(T, signalingNanBits(T)),
        },
        else => tStep(T, index),
    };
}

fn tStep(comptime T: type, comptime index: usize) T {
    const base: T = 0.125;
    const step: T = 0.125;
    return base + @as(T, @floatFromInt(index % 7)) * step;
}

/// The scalar argument of the raw algebra: the factor of a `scale`.
fn rawScalarOf(comptime T: type, comptime regime: QuatRegime, comptime index: usize) T {
    return switch (regime) {
        .zero => @as(T, if (index % 2 == 0) -0.0 else 0.0),
        else => ordinaryComponent(T, index * 3 + 1),
    };
}

/// The scalar arguments of a case, built at comptime so a timed body reads one
/// table slot instead of recomputing the value from the runtime index. Every
/// argument the factories need is one of these three tables.
fn rawScalars(comptime T: type, comptime regime: QuatRegime) [depth]T {
    var out: [depth]T = undefined;
    for (0..depth) |index| out[index] = rawScalarOf(T, regime, index);
    return out;
}

fn radiansTable(comptime T: type, comptime regime: QuatRegime) [depth]T {
    var out: [depth]T = undefined;
    for (0..depth) |index| out[index] = radiansOf(T, regime, index);
    return out;
}

fn tTable(comptime T: type, comptime regime: QuatRegime) [depth]T {
    var out: [depth]T = undefined;
    for (0..depth) |index| out[index] = tOf(T, regime, index);
    return out;
}

// ---------------------------------------------------------------------------
// The raw algebra
// ---------------------------------------------------------------------------

/// The public method families of `Quatf` and `Quatd`. `normSquared` is
/// absent because it is a one-line delegation to `lengthSquared`, so its
/// timed route is that method's route bit for bit.
const RawOp = enum {
    // Construction and the array bridge.
    init,
    identity,
    zero,
    from_array,
    to_array,
    // Componentwise arithmetic.
    add,
    sub,
    neg,
    scale,
    scale_quat,
    dot,
    // Magnitudes.
    length_squared,
    length,
    // The algebra proper.
    conjugate,
    inverse,
    mul,
    from_axis_angle,
    // Predicates.
    is_finite,
    eq,
};

fn RawQuatInvoke(comptime Q: type, comptime op: RawOp, comptime regime: QuatRegime) type {
    const T = Scalar(Q);
    const quats = rawQuats(Q, regime);
    const arrays = rawArrays(Q, quats);
    const axes = axesOf(Q, regime);
    const factors = rawScalars(T, regime);
    const angles = radiansTable(T, regime);
    return struct {
        /// The first operand.
        fn first(index: usize) Q {
            return quats[index % depth];
        }

        /// The second operand, from the slot the regime pairs with the first.
        fn second(index: usize) Q {
            return quats[(index + partnerOffset(regime)) % depth];
        }

        /// The factor of a `scale`.
        fn factor(index: usize) T {
            return factors[index % depth];
        }

        /// The angle of `fromAxisAngle`.
        fn angle(index: usize) T {
            return angles[index % depth];
        }

        noinline fn invoke(index: usize) u64 {
            return switch (op) {
                .init => common.hash(Q.init(
                    first(index).x,
                    first(index).y,
                    first(index).z,
                    first(index).w,
                )),
                .identity => common.hash(Q.identity()),
                .zero => common.hash(Q.zero()),
                .from_array => common.hash(Q.fromArray(arrays[index % depth])),
                .to_array => common.hash(first(index).toArray()),
                .add => common.hash(first(index).add(second(index))),
                .sub => common.hash(first(index).sub(second(index))),
                .neg => common.hash(first(index).neg()),
                .scale => common.hash(first(index).scale(factor(index))),
                .scale_quat => common.hash(first(index).scaleQuat(second(index))),
                .dot => common.hash(first(index).dot(second(index))),
                .length_squared => common.hash(first(index).lengthSquared()),
                .length => common.hash(first(index).length()),
                .conjugate => common.hash(first(index).conjugate()),
                .inverse => common.hash(first(index).inverse()),
                .mul => common.hash(first(index).mul(second(index))),
                .from_axis_angle => common.hash(Q.fromAxisAngle(axes[index % depth], angle(index))),
                .is_finite => common.hash(first(index).isFinite()),
                .eq => common.hash(first(index).eq(second(index))),
            };
        }
    };
}

/// One raw-quaternion case.
fn rawCase(
    comptime Q: type,
    comptime op: RawOp,
    comptime regime: QuatRegime,
    comptime name: []const u8,
    comptime calls: u32,
    comptime f32_charges: []const Charge,
) Case {
    @setEvalBranchQuota(fixture_branch_quota);
    return .{
        .name = name,
        .namespace = "quaternion",
        .invoke = RawQuatInvoke(Q, op, regime).invoke,
        .calls = calls,
        .f32 = f32_charges,
    };
}

// ---------------------------------------------------------------------------
// The validated rotation
// ---------------------------------------------------------------------------

/// The public method families of `UnitQuatf` and `UnitQuatd`. `inverse` is
/// absent because it is a one-line delegation to `conjugate`, so its timed
/// route is that method's route bit for bit.
const UnitOp = enum {
    init,
    dot,
    eq,
    conjugate,
    mul,
    then,
    rotate,
    from_axis_angle,
    slerp,
    lerp,
};

fn UnitQuatInvoke(comptime Q: type, comptime op: UnitOp, comptime regime: QuatRegime) type {
    const T = Scalar(Q);
    const V = Vec3Of(Q);
    const quats = rawQuats(Q, regime);
    const vectors = regimeVecs(V, .ordinary);
    const lefts = unitLefts(Q, regime);
    const rights = unitRights(Q, regime);
    const axes = axesOf(Q, regime);
    const angles = radiansTable(T, regime);
    const interpolants = tTable(T, regime);
    return struct {
        /// The raw value `init` validates.
        fn raw(index: usize) Q {
            return quats[index % depth];
        }

        /// The first operand.
        fn first(index: usize) UnitOf(Q) {
            return lefts[index % depth];
        }

        /// The second operand.
        fn second(index: usize) UnitOf(Q) {
            return rights[(index + partnerOffset(regime)) % depth];
        }

        /// The vector `rotate` moves.
        fn vector(index: usize) V {
            return vectors[index % depth];
        }

        /// The `t` of `lerp` and `slerp`.
        fn t(index: usize) T {
            return interpolants[index % depth];
        }

        /// The axis of `fromAxisAngle`.
        fn axis(index: usize) V {
            return axes[index % depth];
        }

        /// The angle of `fromAxisAngle`.
        fn angle(index: usize) T {
            return angles[index % depth];
        }

        noinline fn invoke(index: usize) u64 {
            return switch (op) {
                .init => common.hash(UnitOf(Q).init(raw(index))),
                .dot => common.hash(first(index).dot(second(index))),
                .eq => common.hash(first(index).eq(second(index))),
                .conjugate => common.hash(first(index).conjugate()),
                .mul => common.hash(first(index).mul(second(index))),
                .then => common.hash(first(index).then(second(index))),
                .rotate => common.hash(first(index).rotate(vector(index))),
                .from_axis_angle => common.hash(
                    UnitOf(Q).fromAxisAngle(axis(index), angle(index)),
                ),
                .slerp => common.hash(first(index).slerp(second(index), t(index))),
                .lerp => common.hash(first(index).lerp(second(index), t(index))),
            };
        }
    };
}

/// One validated-rotation case.
fn unitCase(
    comptime Q: type,
    comptime op: UnitOp,
    comptime regime: QuatRegime,
    comptime name: []const u8,
    comptime calls: u32,
    comptime f32_charges: []const Charge,
) Case {
    @setEvalBranchQuota(fixture_branch_quota);
    return .{
        .name = name,
        .namespace = "quaternion",
        .invoke = UnitQuatInvoke(Q, op, regime).invoke,
        .calls = calls,
        .f32 = f32_charges,
    };
}

// ---------------------------------------------------------------------------
// Quaternion charges
// ---------------------------------------------------------------------------

/// Four components fold in three calls.
const quat_fold: []const Charge = &.{charge("hypotf", 3)};

/// The validated constructor folds twice: once to normalize and once for the
/// unit band, so six calls where one length costs three.
const unit_init_charge: []const Charge = &.{charge("hypotf", 6)};

/// The raw axis-angle constructor normalizes its axis through `Vec3.length`,
/// which folds a three-component vector in two calls, and then takes one sine
/// and one cosine of the half angle.
const raw_axis_angle: []const Charge = &.{
    charge("hypotf", 2),
    charge("sinf", 1),
    charge("cosf", 1),
    charge("fmaf", 1),
};

/// The validated one routes the raw answer through `init`, so it is the raw
/// constructor's charge plus the constructor's own fold.
const unit_axis_angle: []const Charge = &.{
    charge("hypotf", 8),
    charge("sinf", 1),
    charge("cosf", 1),
    charge("fmaf", 1),
};

/// The spherical branch of `slerp`: the dot is clamped with one `fmin` and one
/// `fmax`, the angle costs one `acosf`, the two coefficients and the sine of
/// the angle cost three `sinf`, and the mixed value goes back through `init`.
const slerp_spherical: []const Charge = &.{
    charge("fminf", 1),
    charge("fmaxf", 1),
    charge("acosf", 1),
    charge("sinf", 3),
    charge("hypotf", 6),
};

/// A `t` that is not finite, or an endpoint, leaves `slerp` before it reaches
/// any kernel.
const slerp_unreachable: []const Charge = &.{};

/// The default call count of this slice.
const calls_default: u32 = 32;

/// The call count for the paths that carry a sine, a cosine or an arc length.
/// They are exact, accepted kernels and the point of the round is their cost,
/// not the count of them.
const calls_exact: u32 = 8;

/// The axis of `fromAxisAngle` alone: a three-component length folds in two.
const axis_fold: []const Charge = &.{charge("hypotf", 2)};

// ---------------------------------------------------------------------------
// The case list
//
// One entry per public method or static factory per type, plus one entry per
// input regime that the module's own tests give a distinct branch. Every name
// is unique across the whole round and names the operation, the type, and the
// regime. The two delegations that share a route bit for bit
// (`Quat.normSquared` and `UnitQuat.inverse`) are covered by the method they
// delegate to rather than timed twice.
// ---------------------------------------------------------------------------

pub const cases = [_]Case{
    // -----------------------------------------------------------------------
    // Vec2f: two components, so one `hypot` in the fold
    // -----------------------------------------------------------------------
    vecCase(Vec2f, .init, .ordinary, "values/Vec2f.init/ordinary", calls_default, no_f32),
    vecCase(Vec2f, .init, .nonfinite, "values/Vec2f.init/nonfinite-payloads", calls_default, no_f32),
    vecCase(Vec2f, .zero, .ordinary, "values/Vec2f.zero/constant-factory", calls_default, no_f32),
    vecCase(Vec2f, .one, .ordinary, "values/Vec2f.one/constant-factory", calls_default, no_f32),
    vecCase(Vec2f, .from_array, .ordinary, "values/Vec2f.fromArray/ordinary", calls_default, no_f32),
    vecCase(Vec2f, .to_array, .ordinary, "values/Vec2f.toArray/ordinary", calls_default, no_f32),
    vecCase(Vec2f, .to_vector, .ordinary, "values/Vec2f.toVector/ordinary", calls_default, no_f32),
    vecCase(Vec2f, .from_vector, .ordinary, "values/Vec2f.fromVector/ordinary", calls_default, no_f32),
    vecCase(Vec2f, .add, .ordinary, "values/Vec2f.add/ordinary", calls_default, no_f32),
    vecCase(Vec2f, .add, .nonfinite, "values/Vec2f.add/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec2f, .sub, .ordinary, "values/Vec2f.sub/ordinary", calls_default, no_f32),
    vecCase(Vec2f, .sub, .nonfinite, "values/Vec2f.sub/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec2f, .neg, .ordinary, "values/Vec2f.neg/ordinary", calls_default, no_f32),
    vecCase(Vec2f, .neg, .signed_zero, "values/Vec2f.neg/signed-zero", calls_default, no_f32),
    vecCase(Vec2f, .scale, .ordinary, "values/Vec2f.scale/ordinary", calls_default, no_f32),
    vecCase(Vec2f, .scale, .nonfinite, "values/Vec2f.scale/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec2f, .scale_vec, .ordinary, "values/Vec2f.scaleVec/ordinary", calls_default, no_f32),
    vecCase(Vec2f, .scale_vec, .nonfinite, "values/Vec2f.scaleVec/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec2f, .div_scalar, .ordinary, "values/Vec2f.divScalar/ordinary", calls_default, no_f32),
    vecCase(Vec2f, .div_scalar, .nonfinite, "values/Vec2f.divScalar/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec2f, .dot, .ordinary, "values/Vec2f.dot/ordinary", calls_default, no_f32),
    vecCase(Vec2f, .dot, .huge, "values/Vec2f.dot/huge-cancellation-order", calls_default, no_f32),
    vecCase(Vec2f, .dot, .nonfinite, "values/Vec2f.dot/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec2f, .length_squared, .ordinary, "values/Vec2f.lengthSquared/ordinary", calls_default, no_f32),
    vecCase(Vec2f, .length_squared, .huge, "values/Vec2f.lengthSquared/huge-overflow", calls_default, no_f32),
    vecCase(Vec2f, .length, .ordinary, "values/Vec2f.length/ordinary", calls_default, foldCharge(Vec2f)),
    vecCase(Vec2f, .length, .huge, "values/Vec2f.length/huge-no-overflow", calls_default, foldCharge(Vec2f)),
    vecCase(Vec2f, .length, .tiny, "values/Vec2f.length/tiny-no-underflow", calls_default, foldCharge(Vec2f)),
    vecCase(Vec2f, .length, .nonfinite, "values/Vec2f.length/nonfinite-kernel-precedence", calls_default, foldCharge(Vec2f)),
    vecCase(Vec2f, .length, .zero, "values/Vec2f.length/signed-zero-positive-result", calls_default, foldCharge(Vec2f)),
    vecCase(Vec2f, .distance_squared, .ordinary, "values/Vec2f.distanceSquared/ordinary", calls_default, no_f32),
    vecCase(Vec2f, .distance_squared, .huge, "values/Vec2f.distanceSquared/huge", calls_default, no_f32),
    vecCase(Vec2f, .distance, .ordinary, "values/Vec2f.distance/ordinary", calls_default, foldCharge(Vec2f)),
    vecCase(Vec2f, .distance, .huge, "values/Vec2f.distance/huge", calls_default, foldCharge(Vec2f)),
    vecCase(Vec2f, .distance, .nonfinite, "values/Vec2f.distance/nonfinite-quieted-difference", calls_default, foldCharge(Vec2f)),
    vecCase(Vec2f, .normalize, .ordinary, "values/Vec2f.normalize/ordinary", calls_default, foldCharge(Vec2f)),
    vecCase(Vec2f, .normalize, .huge, "values/Vec2f.normalize/huge-no-overflow", calls_default, foldCharge(Vec2f)),
    vecCase(Vec2f, .normalize, .tiny, "values/Vec2f.normalize/tiny-subnormal-norm", calls_default, foldCharge(Vec2f)),
    vecCase(Vec2f, .normalize, .zero, "values/Vec2f.normalize/zero-returns-input", calls_default, foldCharge(Vec2f)),
    vecCase(Vec2f, .normalize, .nonfinite, "values/Vec2f.normalize/nonfinite-canonical-NaN", calls_default, foldCharge(Vec2f)),
    vecCase(Vec2f, .lerp, .ordinary, "values/Vec2f.lerp/interior-t", calls_default, no_f32),
    vecCase(Vec2f, .lerp, .endpoint, "values/Vec2f.lerp/endpoint-short-circuit", calls_default, no_f32),
    vecCase(Vec2f, .min, .ordinary, "values/Vec2f.min/ordinary", calls_default, perComponentCharge("fminf", Vec2f)),
    vecCase(Vec2f, .min, .signed_zero, "values/Vec2f.min/signed-zero-preference", calls_default, perComponentCharge("fminf", Vec2f)),
    vecCase(Vec2f, .min, .nonfinite, "values/Vec2f.min/nonfinite-nan-loses", calls_default, perComponentCharge("fminf", Vec2f)),
    vecCase(Vec2f, .max, .ordinary, "values/Vec2f.max/ordinary", calls_default, perComponentCharge("fmaxf", Vec2f)),
    vecCase(Vec2f, .max, .signed_zero, "values/Vec2f.max/signed-zero-preference", calls_default, perComponentCharge("fmaxf", Vec2f)),
    vecCase(Vec2f, .max, .nonfinite, "values/Vec2f.max/nonfinite-nan-loses", calls_default, perComponentCharge("fmaxf", Vec2f)),
    vecCase(Vec2f, .clamp, .ordinary, "values/Vec2f.clamp/ordinary", calls_default, clampCharges(Vec2f)),
    vecCase(Vec2f, .clamp, .reversed, "values/Vec2f.clamp/reversed-bounds", calls_default, clampCharges(Vec2f)),
    vecCase(Vec2f, .clamp, .signed_zero, "values/Vec2f.clamp/signed-zero-bound", calls_default, clampCharges(Vec2f)),
    vecCase(Vec2f, .clamp, .nonfinite, "values/Vec2f.clamp/nonfinite-bounds-decide", calls_default, clampCharges(Vec2f)),
    vecCase(Vec2f, .abs, .ordinary, "values/Vec2f.abs/ordinary", calls_default, perComponentCharge("absf", Vec2f)),
    vecCase(Vec2f, .abs, .signed_zero, "values/Vec2f.abs/signed-zero-cleared", calls_default, perComponentCharge("absf", Vec2f)),
    vecCase(Vec2f, .is_finite, .ordinary, "values/Vec2f.isFinite/ordinary", calls_default, no_f32),
    vecCase(Vec2f, .is_finite, .nonfinite, "values/Vec2f.isFinite/nonfinite", calls_default, no_f32),
    vecCase(Vec2f, .eq, .ordinary, "values/Vec2f.eq/ordinary", calls_default, no_f32),
    vecCase(Vec2f, .eq, .zero_twin, "values/Vec2f.eq/signed-zero-not-equal", calls_default, no_f32),
    vecCase(Vec2f, .eq, .nan_twin, "values/Vec2f.eq/nan-equals-nan-any-payload", calls_default, no_f32),

    // -----------------------------------------------------------------------
    // Vec3f: three components, two `hypot` in the fold, plus `cross`
    // -----------------------------------------------------------------------
    vecCase(Vec3f, .init, .ordinary, "values/Vec3f.init/ordinary", calls_default, no_f32),
    vecCase(Vec3f, .init, .nonfinite, "values/Vec3f.init/nonfinite-payloads", calls_default, no_f32),
    vecCase(Vec3f, .zero, .ordinary, "values/Vec3f.zero/constant-factory", calls_default, no_f32),
    vecCase(Vec3f, .one, .ordinary, "values/Vec3f.one/constant-factory", calls_default, no_f32),
    vecCase(Vec3f, .from_array, .ordinary, "values/Vec3f.fromArray/ordinary", calls_default, no_f32),
    vecCase(Vec3f, .to_array, .ordinary, "values/Vec3f.toArray/ordinary", calls_default, no_f32),
    vecCase(Vec3f, .to_vector, .ordinary, "values/Vec3f.toVector/ordinary", calls_default, no_f32),
    vecCase(Vec3f, .from_vector, .ordinary, "values/Vec3f.fromVector/ordinary", calls_default, no_f32),
    vecCase(Vec3f, .add, .ordinary, "values/Vec3f.add/ordinary", calls_default, no_f32),
    vecCase(Vec3f, .add, .nonfinite, "values/Vec3f.add/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec3f, .sub, .ordinary, "values/Vec3f.sub/ordinary", calls_default, no_f32),
    vecCase(Vec3f, .sub, .nonfinite, "values/Vec3f.sub/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec3f, .neg, .ordinary, "values/Vec3f.neg/ordinary", calls_default, no_f32),
    vecCase(Vec3f, .neg, .signed_zero, "values/Vec3f.neg/signed-zero", calls_default, no_f32),
    vecCase(Vec3f, .scale, .ordinary, "values/Vec3f.scale/ordinary", calls_default, no_f32),
    vecCase(Vec3f, .scale, .nonfinite, "values/Vec3f.scale/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec3f, .scale_vec, .ordinary, "values/Vec3f.scaleVec/ordinary", calls_default, no_f32),
    vecCase(Vec3f, .scale_vec, .nonfinite, "values/Vec3f.scaleVec/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec3f, .div_scalar, .ordinary, "values/Vec3f.divScalar/ordinary", calls_default, no_f32),
    vecCase(Vec3f, .div_scalar, .nonfinite, "values/Vec3f.divScalar/nonfinite-canonical-substitution", calls_default, no_f32),
    crossCase(Vec3f, .ordinary, "values/Vec3f.cross/ordinary", no_f32),
    crossCase(Vec3f, .nonfinite, "values/Vec3f.cross/nonfinite-per-component-rule", no_f32),
    vecCase(Vec3f, .dot, .ordinary, "values/Vec3f.dot/ordinary", calls_default, no_f32),
    vecCase(Vec3f, .dot, .huge, "values/Vec3f.dot/huge-cancellation-order", calls_default, no_f32),
    vecCase(Vec3f, .dot, .nonfinite, "values/Vec3f.dot/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec3f, .length_squared, .ordinary, "values/Vec3f.lengthSquared/ordinary", calls_default, no_f32),
    vecCase(Vec3f, .length_squared, .huge, "values/Vec3f.lengthSquared/huge-overflow", calls_default, no_f32),
    vecCase(Vec3f, .length, .ordinary, "values/Vec3f.length/ordinary", calls_default, foldCharge(Vec3f)),
    vecCase(Vec3f, .length, .huge, "values/Vec3f.length/huge-no-overflow", calls_default, foldCharge(Vec3f)),
    vecCase(Vec3f, .length, .tiny, "values/Vec3f.length/tiny-no-underflow", calls_default, foldCharge(Vec3f)),
    vecCase(Vec3f, .length, .nonfinite, "values/Vec3f.length/nonfinite-kernel-precedence", calls_default, foldCharge(Vec3f)),
    vecCase(Vec3f, .length, .zero, "values/Vec3f.length/signed-zero-positive-result", calls_default, foldCharge(Vec3f)),
    vecCase(Vec3f, .distance_squared, .ordinary, "values/Vec3f.distanceSquared/ordinary", calls_default, no_f32),
    vecCase(Vec3f, .distance_squared, .huge, "values/Vec3f.distanceSquared/huge", calls_default, no_f32),
    vecCase(Vec3f, .distance, .ordinary, "values/Vec3f.distance/ordinary", calls_default, foldCharge(Vec3f)),
    vecCase(Vec3f, .distance, .huge, "values/Vec3f.distance/huge", calls_default, foldCharge(Vec3f)),
    vecCase(Vec3f, .distance, .nonfinite, "values/Vec3f.distance/nonfinite-quieted-difference", calls_default, foldCharge(Vec3f)),
    vecCase(Vec3f, .normalize, .ordinary, "values/Vec3f.normalize/ordinary", calls_default, foldCharge(Vec3f)),
    vecCase(Vec3f, .normalize, .huge, "values/Vec3f.normalize/huge-no-overflow", calls_default, foldCharge(Vec3f)),
    vecCase(Vec3f, .normalize, .tiny, "values/Vec3f.normalize/tiny-subnormal-norm", calls_default, foldCharge(Vec3f)),
    vecCase(Vec3f, .normalize, .zero, "values/Vec3f.normalize/zero-returns-input", calls_default, foldCharge(Vec3f)),
    vecCase(Vec3f, .normalize, .nonfinite, "values/Vec3f.normalize/nonfinite-canonical-NaN", calls_default, foldCharge(Vec3f)),
    vecCase(Vec3f, .lerp, .ordinary, "values/Vec3f.lerp/interior-t", calls_default, no_f32),
    vecCase(Vec3f, .lerp, .endpoint, "values/Vec3f.lerp/endpoint-short-circuit", calls_default, no_f32),
    vecCase(Vec3f, .min, .ordinary, "values/Vec3f.min/ordinary", calls_default, perComponentCharge("fminf", Vec3f)),
    vecCase(Vec3f, .min, .signed_zero, "values/Vec3f.min/signed-zero-preference", calls_default, perComponentCharge("fminf", Vec3f)),
    vecCase(Vec3f, .min, .nonfinite, "values/Vec3f.min/nonfinite-nan-loses", calls_default, perComponentCharge("fminf", Vec3f)),
    vecCase(Vec3f, .max, .ordinary, "values/Vec3f.max/ordinary", calls_default, perComponentCharge("fmaxf", Vec3f)),
    vecCase(Vec3f, .max, .signed_zero, "values/Vec3f.max/signed-zero-preference", calls_default, perComponentCharge("fmaxf", Vec3f)),
    vecCase(Vec3f, .max, .nonfinite, "values/Vec3f.max/nonfinite-nan-loses", calls_default, perComponentCharge("fmaxf", Vec3f)),
    vecCase(Vec3f, .clamp, .ordinary, "values/Vec3f.clamp/ordinary", calls_default, clampCharges(Vec3f)),
    vecCase(Vec3f, .clamp, .reversed, "values/Vec3f.clamp/reversed-bounds", calls_default, clampCharges(Vec3f)),
    vecCase(Vec3f, .clamp, .signed_zero, "values/Vec3f.clamp/signed-zero-bound", calls_default, clampCharges(Vec3f)),
    vecCase(Vec3f, .clamp, .nonfinite, "values/Vec3f.clamp/nonfinite-bounds-decide", calls_default, clampCharges(Vec3f)),
    vecCase(Vec3f, .abs, .ordinary, "values/Vec3f.abs/ordinary", calls_default, perComponentCharge("absf", Vec3f)),
    vecCase(Vec3f, .abs, .signed_zero, "values/Vec3f.abs/signed-zero-cleared", calls_default, perComponentCharge("absf", Vec3f)),
    vecCase(Vec3f, .is_finite, .ordinary, "values/Vec3f.isFinite/ordinary", calls_default, no_f32),
    vecCase(Vec3f, .is_finite, .nonfinite, "values/Vec3f.isFinite/nonfinite", calls_default, no_f32),
    vecCase(Vec3f, .eq, .ordinary, "values/Vec3f.eq/ordinary", calls_default, no_f32),
    vecCase(Vec3f, .eq, .zero_twin, "values/Vec3f.eq/signed-zero-not-equal", calls_default, no_f32),
    vecCase(Vec3f, .eq, .nan_twin, "values/Vec3f.eq/nan-equals-nan-any-payload", calls_default, no_f32),

    // -----------------------------------------------------------------------
    // Vec4f: four components, three `hypot` in the fold
    // -----------------------------------------------------------------------
    vecCase(Vec4f, .init, .ordinary, "values/Vec4f.init/ordinary", calls_default, no_f32),
    vecCase(Vec4f, .init, .nonfinite, "values/Vec4f.init/nonfinite-payloads", calls_default, no_f32),
    vecCase(Vec4f, .zero, .ordinary, "values/Vec4f.zero/constant-factory", calls_default, no_f32),
    vecCase(Vec4f, .one, .ordinary, "values/Vec4f.one/constant-factory", calls_default, no_f32),
    vecCase(Vec4f, .from_array, .ordinary, "values/Vec4f.fromArray/ordinary", calls_default, no_f32),
    vecCase(Vec4f, .to_array, .ordinary, "values/Vec4f.toArray/ordinary", calls_default, no_f32),
    vecCase(Vec4f, .to_vector, .ordinary, "values/Vec4f.toVector/ordinary", calls_default, no_f32),
    vecCase(Vec4f, .from_vector, .ordinary, "values/Vec4f.fromVector/ordinary", calls_default, no_f32),
    vecCase(Vec4f, .add, .ordinary, "values/Vec4f.add/ordinary", calls_default, no_f32),
    vecCase(Vec4f, .add, .nonfinite, "values/Vec4f.add/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec4f, .sub, .ordinary, "values/Vec4f.sub/ordinary", calls_default, no_f32),
    vecCase(Vec4f, .sub, .nonfinite, "values/Vec4f.sub/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec4f, .neg, .ordinary, "values/Vec4f.neg/ordinary", calls_default, no_f32),
    vecCase(Vec4f, .neg, .signed_zero, "values/Vec4f.neg/signed-zero", calls_default, no_f32),
    vecCase(Vec4f, .scale, .ordinary, "values/Vec4f.scale/ordinary", calls_default, no_f32),
    vecCase(Vec4f, .scale, .nonfinite, "values/Vec4f.scale/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec4f, .scale_vec, .ordinary, "values/Vec4f.scaleVec/ordinary", calls_default, no_f32),
    vecCase(Vec4f, .scale_vec, .nonfinite, "values/Vec4f.scaleVec/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec4f, .div_scalar, .ordinary, "values/Vec4f.divScalar/ordinary", calls_default, no_f32),
    vecCase(Vec4f, .div_scalar, .nonfinite, "values/Vec4f.divScalar/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec4f, .dot, .ordinary, "values/Vec4f.dot/ordinary", calls_default, no_f32),
    vecCase(Vec4f, .dot, .huge, "values/Vec4f.dot/huge-cancellation-order", calls_default, no_f32),
    vecCase(Vec4f, .dot, .nonfinite, "values/Vec4f.dot/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec4f, .length_squared, .ordinary, "values/Vec4f.lengthSquared/ordinary", calls_default, no_f32),
    vecCase(Vec4f, .length_squared, .huge, "values/Vec4f.lengthSquared/huge-overflow", calls_default, no_f32),
    vecCase(Vec4f, .length, .ordinary, "values/Vec4f.length/ordinary", calls_default, foldCharge(Vec4f)),
    vecCase(Vec4f, .length, .huge, "values/Vec4f.length/huge-no-overflow", calls_default, foldCharge(Vec4f)),
    vecCase(Vec4f, .length, .tiny, "values/Vec4f.length/tiny-no-underflow", calls_default, foldCharge(Vec4f)),
    vecCase(Vec4f, .length, .nonfinite, "values/Vec4f.length/nonfinite-kernel-precedence", calls_default, foldCharge(Vec4f)),
    vecCase(Vec4f, .length, .zero, "values/Vec4f.length/signed-zero-positive-result", calls_default, foldCharge(Vec4f)),
    vecCase(Vec4f, .distance_squared, .ordinary, "values/Vec4f.distanceSquared/ordinary", calls_default, no_f32),
    vecCase(Vec4f, .distance_squared, .huge, "values/Vec4f.distanceSquared/huge", calls_default, no_f32),
    vecCase(Vec4f, .distance, .ordinary, "values/Vec4f.distance/ordinary", calls_default, foldCharge(Vec4f)),
    vecCase(Vec4f, .distance, .huge, "values/Vec4f.distance/huge", calls_default, foldCharge(Vec4f)),
    vecCase(Vec4f, .distance, .nonfinite, "values/Vec4f.distance/nonfinite-quieted-difference", calls_default, foldCharge(Vec4f)),
    vecCase(Vec4f, .normalize, .ordinary, "values/Vec4f.normalize/ordinary", calls_default, foldCharge(Vec4f)),
    vecCase(Vec4f, .normalize, .huge, "values/Vec4f.normalize/huge-no-overflow", calls_default, foldCharge(Vec4f)),
    vecCase(Vec4f, .normalize, .tiny, "values/Vec4f.normalize/tiny-subnormal-norm", calls_default, foldCharge(Vec4f)),
    vecCase(Vec4f, .normalize, .zero, "values/Vec4f.normalize/zero-returns-input", calls_default, foldCharge(Vec4f)),
    vecCase(Vec4f, .normalize, .nonfinite, "values/Vec4f.normalize/nonfinite-canonical-NaN", calls_default, foldCharge(Vec4f)),
    vecCase(Vec4f, .lerp, .ordinary, "values/Vec4f.lerp/interior-t", calls_default, no_f32),
    vecCase(Vec4f, .lerp, .endpoint, "values/Vec4f.lerp/endpoint-short-circuit", calls_default, no_f32),
    vecCase(Vec4f, .min, .ordinary, "values/Vec4f.min/ordinary", calls_default, perComponentCharge("fminf", Vec4f)),
    vecCase(Vec4f, .min, .signed_zero, "values/Vec4f.min/signed-zero-preference", calls_default, perComponentCharge("fminf", Vec4f)),
    vecCase(Vec4f, .min, .nonfinite, "values/Vec4f.min/nonfinite-nan-loses", calls_default, perComponentCharge("fminf", Vec4f)),
    vecCase(Vec4f, .max, .ordinary, "values/Vec4f.max/ordinary", calls_default, perComponentCharge("fmaxf", Vec4f)),
    vecCase(Vec4f, .max, .signed_zero, "values/Vec4f.max/signed-zero-preference", calls_default, perComponentCharge("fmaxf", Vec4f)),
    vecCase(Vec4f, .max, .nonfinite, "values/Vec4f.max/nonfinite-nan-loses", calls_default, perComponentCharge("fmaxf", Vec4f)),
    vecCase(Vec4f, .clamp, .ordinary, "values/Vec4f.clamp/ordinary", calls_default, clampCharges(Vec4f)),
    vecCase(Vec4f, .clamp, .reversed, "values/Vec4f.clamp/reversed-bounds", calls_default, clampCharges(Vec4f)),
    vecCase(Vec4f, .clamp, .signed_zero, "values/Vec4f.clamp/signed-zero-bound", calls_default, clampCharges(Vec4f)),
    vecCase(Vec4f, .clamp, .nonfinite, "values/Vec4f.clamp/nonfinite-bounds-decide", calls_default, clampCharges(Vec4f)),
    vecCase(Vec4f, .abs, .ordinary, "values/Vec4f.abs/ordinary", calls_default, perComponentCharge("absf", Vec4f)),
    vecCase(Vec4f, .abs, .signed_zero, "values/Vec4f.abs/signed-zero-cleared", calls_default, perComponentCharge("absf", Vec4f)),
    vecCase(Vec4f, .is_finite, .ordinary, "values/Vec4f.isFinite/ordinary", calls_default, no_f32),
    vecCase(Vec4f, .is_finite, .nonfinite, "values/Vec4f.isFinite/nonfinite", calls_default, no_f32),
    vecCase(Vec4f, .eq, .ordinary, "values/Vec4f.eq/ordinary", calls_default, no_f32),
    vecCase(Vec4f, .eq, .zero_twin, "values/Vec4f.eq/signed-zero-not-equal", calls_default, no_f32),
    vecCase(Vec4f, .eq, .nan_twin, "values/Vec4f.eq/nan-equals-nan-any-payload", calls_default, no_f32),

    // -----------------------------------------------------------------------
    // Vec2d: the binary64 twin of Vec2f
    // -----------------------------------------------------------------------
    vecCase(Vec2d, .init, .ordinary, "values/Vec2d.init/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .init, .nonfinite, "values/Vec2d.init/nonfinite-payloads", calls_default, no_f32),
    vecCase(Vec2d, .zero, .ordinary, "values/Vec2d.zero/constant-factory", calls_default, no_f32),
    vecCase(Vec2d, .one, .ordinary, "values/Vec2d.one/constant-factory", calls_default, no_f32),
    vecCase(Vec2d, .from_array, .ordinary, "values/Vec2d.fromArray/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .to_array, .ordinary, "values/Vec2d.toArray/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .to_vector, .ordinary, "values/Vec2d.toVector/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .from_vector, .ordinary, "values/Vec2d.fromVector/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .add, .ordinary, "values/Vec2d.add/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .add, .nonfinite, "values/Vec2d.add/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec2d, .sub, .ordinary, "values/Vec2d.sub/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .sub, .nonfinite, "values/Vec2d.sub/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec2d, .neg, .ordinary, "values/Vec2d.neg/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .neg, .signed_zero, "values/Vec2d.neg/signed-zero", calls_default, no_f32),
    vecCase(Vec2d, .scale, .ordinary, "values/Vec2d.scale/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .scale, .nonfinite, "values/Vec2d.scale/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec2d, .scale_vec, .ordinary, "values/Vec2d.scaleVec/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .scale_vec, .nonfinite, "values/Vec2d.scaleVec/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec2d, .div_scalar, .ordinary, "values/Vec2d.divScalar/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .div_scalar, .nonfinite, "values/Vec2d.divScalar/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec2d, .dot, .ordinary, "values/Vec2d.dot/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .dot, .huge, "values/Vec2d.dot/huge-cancellation-order", calls_default, no_f32),
    vecCase(Vec2d, .dot, .nonfinite, "values/Vec2d.dot/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec2d, .length_squared, .ordinary, "values/Vec2d.lengthSquared/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .length_squared, .huge, "values/Vec2d.lengthSquared/huge-overflow", calls_default, no_f32),
    vecCase(Vec2d, .length, .ordinary, "values/Vec2d.length/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .length, .huge, "values/Vec2d.length/huge-no-overflow", calls_default, no_f32),
    vecCase(Vec2d, .length, .tiny, "values/Vec2d.length/tiny-no-underflow", calls_default, no_f32),
    vecCase(Vec2d, .length, .nonfinite, "values/Vec2d.length/nonfinite-kernel-precedence", calls_default, no_f32),
    vecCase(Vec2d, .length, .zero, "values/Vec2d.length/signed-zero-positive-result", calls_default, no_f32),
    vecCase(Vec2d, .distance_squared, .ordinary, "values/Vec2d.distanceSquared/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .distance_squared, .huge, "values/Vec2d.distanceSquared/huge", calls_default, no_f32),
    vecCase(Vec2d, .distance, .ordinary, "values/Vec2d.distance/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .distance, .huge, "values/Vec2d.distance/huge", calls_default, no_f32),
    vecCase(Vec2d, .distance, .nonfinite, "values/Vec2d.distance/nonfinite-quieted-difference", calls_default, no_f32),
    vecCase(Vec2d, .normalize, .ordinary, "values/Vec2d.normalize/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .normalize, .huge, "values/Vec2d.normalize/huge-no-overflow", calls_default, no_f32),
    vecCase(Vec2d, .normalize, .tiny, "values/Vec2d.normalize/tiny-subnormal-norm", calls_default, no_f32),
    vecCase(Vec2d, .normalize, .zero, "values/Vec2d.normalize/zero-returns-input", calls_default, no_f32),
    vecCase(Vec2d, .normalize, .nonfinite, "values/Vec2d.normalize/nonfinite-canonical-NaN", calls_default, no_f32),
    vecCase(Vec2d, .lerp, .ordinary, "values/Vec2d.lerp/interior-t", calls_default, no_f32),
    vecCase(Vec2d, .lerp, .endpoint, "values/Vec2d.lerp/endpoint-short-circuit", calls_default, no_f32),
    vecCase(Vec2d, .min, .ordinary, "values/Vec2d.min/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .min, .signed_zero, "values/Vec2d.min/signed-zero-preference", calls_default, no_f32),
    vecCase(Vec2d, .min, .nonfinite, "values/Vec2d.min/nonfinite-nan-loses", calls_default, no_f32),
    vecCase(Vec2d, .max, .ordinary, "values/Vec2d.max/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .max, .signed_zero, "values/Vec2d.max/signed-zero-preference", calls_default, no_f32),
    vecCase(Vec2d, .max, .nonfinite, "values/Vec2d.max/nonfinite-nan-loses", calls_default, no_f32),
    vecCase(Vec2d, .clamp, .ordinary, "values/Vec2d.clamp/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .clamp, .reversed, "values/Vec2d.clamp/reversed-bounds", calls_default, no_f32),
    vecCase(Vec2d, .clamp, .signed_zero, "values/Vec2d.clamp/signed-zero-bound", calls_default, no_f32),
    vecCase(Vec2d, .clamp, .nonfinite, "values/Vec2d.clamp/nonfinite-bounds-decide", calls_default, no_f32),
    vecCase(Vec2d, .abs, .ordinary, "values/Vec2d.abs/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .abs, .signed_zero, "values/Vec2d.abs/signed-zero-cleared", calls_default, no_f32),
    vecCase(Vec2d, .is_finite, .ordinary, "values/Vec2d.isFinite/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .is_finite, .nonfinite, "values/Vec2d.isFinite/nonfinite", calls_default, no_f32),
    vecCase(Vec2d, .eq, .ordinary, "values/Vec2d.eq/ordinary", calls_default, no_f32),
    vecCase(Vec2d, .eq, .zero_twin, "values/Vec2d.eq/signed-zero-not-equal", calls_default, no_f32),
    vecCase(Vec2d, .eq, .nan_twin, "values/Vec2d.eq/nan-equals-nan-any-payload", calls_default, no_f32),

    // -----------------------------------------------------------------------
    // Vec3d: three components in binary64, plus `cross`
    // -----------------------------------------------------------------------
    vecCase(Vec3d, .init, .ordinary, "values/Vec3d.init/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .init, .nonfinite, "values/Vec3d.init/nonfinite-payloads", calls_default, no_f32),
    vecCase(Vec3d, .zero, .ordinary, "values/Vec3d.zero/constant-factory", calls_default, no_f32),
    vecCase(Vec3d, .one, .ordinary, "values/Vec3d.one/constant-factory", calls_default, no_f32),
    vecCase(Vec3d, .from_array, .ordinary, "values/Vec3d.fromArray/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .to_array, .ordinary, "values/Vec3d.toArray/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .to_vector, .ordinary, "values/Vec3d.toVector/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .from_vector, .ordinary, "values/Vec3d.fromVector/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .add, .ordinary, "values/Vec3d.add/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .add, .nonfinite, "values/Vec3d.add/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec3d, .sub, .ordinary, "values/Vec3d.sub/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .sub, .nonfinite, "values/Vec3d.sub/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec3d, .neg, .ordinary, "values/Vec3d.neg/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .neg, .signed_zero, "values/Vec3d.neg/signed-zero", calls_default, no_f32),
    vecCase(Vec3d, .scale, .ordinary, "values/Vec3d.scale/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .scale, .nonfinite, "values/Vec3d.scale/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec3d, .scale_vec, .ordinary, "values/Vec3d.scaleVec/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .scale_vec, .nonfinite, "values/Vec3d.scaleVec/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec3d, .div_scalar, .ordinary, "values/Vec3d.divScalar/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .div_scalar, .nonfinite, "values/Vec3d.divScalar/nonfinite-canonical-substitution", calls_default, no_f32),
    crossCase(Vec3d, .ordinary, "values/Vec3d.cross/ordinary", no_f32),
    crossCase(Vec3d, .nonfinite, "values/Vec3d.cross/nonfinite-per-component-rule", no_f32),
    vecCase(Vec3d, .dot, .ordinary, "values/Vec3d.dot/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .dot, .huge, "values/Vec3d.dot/huge-cancellation-order", calls_default, no_f32),
    vecCase(Vec3d, .dot, .nonfinite, "values/Vec3d.dot/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec3d, .length_squared, .ordinary, "values/Vec3d.lengthSquared/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .length_squared, .huge, "values/Vec3d.lengthSquared/huge-overflow", calls_default, no_f32),
    vecCase(Vec3d, .length, .ordinary, "values/Vec3d.length/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .length, .huge, "values/Vec3d.length/huge-no-overflow", calls_default, no_f32),
    vecCase(Vec3d, .length, .tiny, "values/Vec3d.length/tiny-no-underflow", calls_default, no_f32),
    vecCase(Vec3d, .length, .nonfinite, "values/Vec3d.length/nonfinite-kernel-precedence", calls_default, no_f32),
    vecCase(Vec3d, .length, .zero, "values/Vec3d.length/signed-zero-positive-result", calls_default, no_f32),
    vecCase(Vec3d, .distance_squared, .ordinary, "values/Vec3d.distanceSquared/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .distance_squared, .huge, "values/Vec3d.distanceSquared/huge", calls_default, no_f32),
    vecCase(Vec3d, .distance, .ordinary, "values/Vec3d.distance/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .distance, .huge, "values/Vec3d.distance/huge", calls_default, no_f32),
    vecCase(Vec3d, .distance, .nonfinite, "values/Vec3d.distance/nonfinite-quieted-difference", calls_default, no_f32),
    vecCase(Vec3d, .normalize, .ordinary, "values/Vec3d.normalize/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .normalize, .huge, "values/Vec3d.normalize/huge-no-overflow", calls_default, no_f32),
    vecCase(Vec3d, .normalize, .tiny, "values/Vec3d.normalize/tiny-subnormal-norm", calls_default, no_f32),
    vecCase(Vec3d, .normalize, .zero, "values/Vec3d.normalize/zero-returns-input", calls_default, no_f32),
    vecCase(Vec3d, .normalize, .nonfinite, "values/Vec3d.normalize/nonfinite-canonical-NaN", calls_default, no_f32),
    vecCase(Vec3d, .lerp, .ordinary, "values/Vec3d.lerp/interior-t", calls_default, no_f32),
    vecCase(Vec3d, .lerp, .endpoint, "values/Vec3d.lerp/endpoint-short-circuit", calls_default, no_f32),
    vecCase(Vec3d, .min, .ordinary, "values/Vec3d.min/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .min, .signed_zero, "values/Vec3d.min/signed-zero-preference", calls_default, no_f32),
    vecCase(Vec3d, .min, .nonfinite, "values/Vec3d.min/nonfinite-nan-loses", calls_default, no_f32),
    vecCase(Vec3d, .max, .ordinary, "values/Vec3d.max/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .max, .signed_zero, "values/Vec3d.max/signed-zero-preference", calls_default, no_f32),
    vecCase(Vec3d, .max, .nonfinite, "values/Vec3d.max/nonfinite-nan-loses", calls_default, no_f32),
    vecCase(Vec3d, .clamp, .ordinary, "values/Vec3d.clamp/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .clamp, .reversed, "values/Vec3d.clamp/reversed-bounds", calls_default, no_f32),
    vecCase(Vec3d, .clamp, .signed_zero, "values/Vec3d.clamp/signed-zero-bound", calls_default, no_f32),
    vecCase(Vec3d, .clamp, .nonfinite, "values/Vec3d.clamp/nonfinite-bounds-decide", calls_default, no_f32),
    vecCase(Vec3d, .abs, .ordinary, "values/Vec3d.abs/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .abs, .signed_zero, "values/Vec3d.abs/signed-zero-cleared", calls_default, no_f32),
    vecCase(Vec3d, .is_finite, .ordinary, "values/Vec3d.isFinite/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .is_finite, .nonfinite, "values/Vec3d.isFinite/nonfinite", calls_default, no_f32),
    vecCase(Vec3d, .eq, .ordinary, "values/Vec3d.eq/ordinary", calls_default, no_f32),
    vecCase(Vec3d, .eq, .zero_twin, "values/Vec3d.eq/signed-zero-not-equal", calls_default, no_f32),
    vecCase(Vec3d, .eq, .nan_twin, "values/Vec3d.eq/nan-equals-nan-any-payload", calls_default, no_f32),

    // -----------------------------------------------------------------------
    // Vec4d: four components in binary64
    // -----------------------------------------------------------------------
    vecCase(Vec4d, .init, .ordinary, "values/Vec4d.init/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .init, .nonfinite, "values/Vec4d.init/nonfinite-payloads", calls_default, no_f32),
    vecCase(Vec4d, .zero, .ordinary, "values/Vec4d.zero/constant-factory", calls_default, no_f32),
    vecCase(Vec4d, .one, .ordinary, "values/Vec4d.one/constant-factory", calls_default, no_f32),
    vecCase(Vec4d, .from_array, .ordinary, "values/Vec4d.fromArray/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .to_array, .ordinary, "values/Vec4d.toArray/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .to_vector, .ordinary, "values/Vec4d.toVector/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .from_vector, .ordinary, "values/Vec4d.fromVector/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .add, .ordinary, "values/Vec4d.add/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .add, .nonfinite, "values/Vec4d.add/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec4d, .sub, .ordinary, "values/Vec4d.sub/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .sub, .nonfinite, "values/Vec4d.sub/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec4d, .neg, .ordinary, "values/Vec4d.neg/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .neg, .signed_zero, "values/Vec4d.neg/signed-zero", calls_default, no_f32),
    vecCase(Vec4d, .scale, .ordinary, "values/Vec4d.scale/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .scale, .nonfinite, "values/Vec4d.scale/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec4d, .scale_vec, .ordinary, "values/Vec4d.scaleVec/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .scale_vec, .nonfinite, "values/Vec4d.scaleVec/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec4d, .div_scalar, .ordinary, "values/Vec4d.divScalar/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .div_scalar, .nonfinite, "values/Vec4d.divScalar/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec4d, .dot, .ordinary, "values/Vec4d.dot/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .dot, .huge, "values/Vec4d.dot/huge-cancellation-order", calls_default, no_f32),
    vecCase(Vec4d, .dot, .nonfinite, "values/Vec4d.dot/nonfinite-canonical-substitution", calls_default, no_f32),
    vecCase(Vec4d, .length_squared, .ordinary, "values/Vec4d.lengthSquared/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .length_squared, .huge, "values/Vec4d.lengthSquared/huge-overflow", calls_default, no_f32),
    vecCase(Vec4d, .length, .ordinary, "values/Vec4d.length/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .length, .huge, "values/Vec4d.length/huge-no-overflow", calls_default, no_f32),
    vecCase(Vec4d, .length, .tiny, "values/Vec4d.length/tiny-no-underflow", calls_default, no_f32),
    vecCase(Vec4d, .length, .nonfinite, "values/Vec4d.length/nonfinite-kernel-precedence", calls_default, no_f32),
    vecCase(Vec4d, .length, .zero, "values/Vec4d.length/signed-zero-positive-result", calls_default, no_f32),
    vecCase(Vec4d, .distance_squared, .ordinary, "values/Vec4d.distanceSquared/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .distance_squared, .huge, "values/Vec4d.distanceSquared/huge", calls_default, no_f32),
    vecCase(Vec4d, .distance, .ordinary, "values/Vec4d.distance/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .distance, .huge, "values/Vec4d.distance/huge", calls_default, no_f32),
    vecCase(Vec4d, .distance, .nonfinite, "values/Vec4d.distance/nonfinite-quieted-difference", calls_default, no_f32),
    vecCase(Vec4d, .normalize, .ordinary, "values/Vec4d.normalize/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .normalize, .huge, "values/Vec4d.normalize/huge-no-overflow", calls_default, no_f32),
    vecCase(Vec4d, .normalize, .tiny, "values/Vec4d.normalize/tiny-subnormal-norm", calls_default, no_f32),
    vecCase(Vec4d, .normalize, .zero, "values/Vec4d.normalize/zero-returns-input", calls_default, no_f32),
    vecCase(Vec4d, .normalize, .nonfinite, "values/Vec4d.normalize/nonfinite-canonical-NaN", calls_default, no_f32),
    vecCase(Vec4d, .lerp, .ordinary, "values/Vec4d.lerp/interior-t", calls_default, no_f32),
    vecCase(Vec4d, .lerp, .endpoint, "values/Vec4d.lerp/endpoint-short-circuit", calls_default, no_f32),
    vecCase(Vec4d, .min, .ordinary, "values/Vec4d.min/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .min, .signed_zero, "values/Vec4d.min/signed-zero-preference", calls_default, no_f32),
    vecCase(Vec4d, .min, .nonfinite, "values/Vec4d.min/nonfinite-nan-loses", calls_default, no_f32),
    vecCase(Vec4d, .max, .ordinary, "values/Vec4d.max/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .max, .signed_zero, "values/Vec4d.max/signed-zero-preference", calls_default, no_f32),
    vecCase(Vec4d, .max, .nonfinite, "values/Vec4d.max/nonfinite-nan-loses", calls_default, no_f32),
    vecCase(Vec4d, .clamp, .ordinary, "values/Vec4d.clamp/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .clamp, .reversed, "values/Vec4d.clamp/reversed-bounds", calls_default, no_f32),
    vecCase(Vec4d, .clamp, .signed_zero, "values/Vec4d.clamp/signed-zero-bound", calls_default, no_f32),
    vecCase(Vec4d, .clamp, .nonfinite, "values/Vec4d.clamp/nonfinite-bounds-decide", calls_default, no_f32),
    vecCase(Vec4d, .abs, .ordinary, "values/Vec4d.abs/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .abs, .signed_zero, "values/Vec4d.abs/signed-zero-cleared", calls_default, no_f32),
    vecCase(Vec4d, .is_finite, .ordinary, "values/Vec4d.isFinite/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .is_finite, .nonfinite, "values/Vec4d.isFinite/nonfinite", calls_default, no_f32),
    vecCase(Vec4d, .eq, .ordinary, "values/Vec4d.eq/ordinary", calls_default, no_f32),
    vecCase(Vec4d, .eq, .zero_twin, "values/Vec4d.eq/signed-zero-not-equal", calls_default, no_f32),
    vecCase(Vec4d, .eq, .nan_twin, "values/Vec4d.eq/nan-equals-nan-any-payload", calls_default, no_f32),

    // -----------------------------------------------------------------------
    // Quatf: the raw f32 algebra
    // -----------------------------------------------------------------------
    rawCase(Quatf, .init, .ordinary, "values/Quatf.init/ordinary", calls_default, no_f32),
    rawCase(Quatf, .init, .nonfinite, "values/Quatf.init/nonfinite-payloads", calls_default, no_f32),
    rawCase(Quatf, .identity, .ordinary, "values/Quatf.identity/constant-factory", calls_default, no_f32),
    rawCase(Quatf, .zero, .ordinary, "values/Quatf.zero/constant-factory", calls_default, no_f32),
    rawCase(Quatf, .from_array, .ordinary, "values/Quatf.fromArray/ordinary", calls_default, no_f32),
    rawCase(Quatf, .to_array, .ordinary, "values/Quatf.toArray/ordinary", calls_default, no_f32),
    rawCase(Quatf, .add, .ordinary, "values/Quatf.add/ordinary", calls_default, no_f32),
    rawCase(Quatf, .add, .nonfinite, "values/Quatf.add/nonfinite-canonical-substitution", calls_default, no_f32),
    rawCase(Quatf, .sub, .ordinary, "values/Quatf.sub/ordinary", calls_default, no_f32),
    rawCase(Quatf, .sub, .nonfinite, "values/Quatf.sub/nonfinite-canonical-substitution", calls_default, no_f32),
    rawCase(Quatf, .neg, .ordinary, "values/Quatf.neg/ordinary", calls_default, no_f32),
    rawCase(Quatf, .neg, .signed_zero, "values/Quatf.neg/signed-zero", calls_default, no_f32),
    rawCase(Quatf, .scale, .ordinary, "values/Quatf.scale/ordinary", calls_default, no_f32),
    rawCase(Quatf, .scale, .nonfinite, "values/Quatf.scale/nonfinite-payload-survives", calls_default, no_f32),
    rawCase(Quatf, .scale_quat, .ordinary, "values/Quatf.scaleQuat/ordinary", calls_default, no_f32),
    rawCase(Quatf, .scale_quat, .nonfinite, "values/Quatf.scaleQuat/nonfinite-canonical-substitution", calls_default, no_f32),
    rawCase(Quatf, .dot, .ordinary, "values/Quatf.dot/ordinary", calls_default, no_f32),
    rawCase(Quatf, .dot, .nonfinite, "values/Quatf.dot/nonfinite-canonical-substitution", calls_default, no_f32),
    rawCase(Quatf, .length_squared, .ordinary, "values/Quatf.lengthSquared/ordinary", calls_default, no_f32),
    rawCase(Quatf, .length_squared, .huge, "values/Quatf.lengthSquared/huge-overflow", calls_default, no_f32),
    rawCase(Quatf, .length_squared, .large, "values/Quatf.lengthSquared/large-overflow", calls_default, no_f32),
    rawCase(Quatf, .length, .ordinary, "values/Quatf.length/ordinary", calls_default, quat_fold),
    rawCase(Quatf, .length, .huge, "values/Quatf.length/huge-fold-overflows", calls_default, quat_fold),
    rawCase(Quatf, .length, .large, "values/Quatf.length/large-fold-keeps-finite", calls_default, quat_fold),
    rawCase(Quatf, .length, .tiny, "values/Quatf.length/tiny-no-underflow", calls_default, quat_fold),
    rawCase(Quatf, .length, .nonfinite, "values/Quatf.length/nonfinite-kernel-precedence", calls_default, quat_fold),
    rawCase(Quatf, .conjugate, .ordinary, "values/Quatf.conjugate/ordinary", calls_default, no_f32),
    rawCase(Quatf, .conjugate, .nonfinite, "values/Quatf.conjugate/nonfinite-sign-and-payload", calls_default, no_f32),
    rawCase(Quatf, .inverse, .ordinary, "values/Quatf.inverse/ordinary", calls_default, no_f32),
    rawCase(Quatf, .inverse, .zero, "values/Quatf.inverse/zero-norm-null", calls_default, no_f32),
    rawCase(Quatf, .inverse, .nonfinite, "values/Quatf.inverse/nonfinite-norm-null", calls_default, no_f32),
    rawCase(Quatf, .inverse, .huge, "values/Quatf.inverse/huge-norm-overflow-null", calls_default, no_f32),
    rawCase(Quatf, .mul, .ordinary, "values/Quatf.mul/ordinary", calls_default, no_f32),
    rawCase(Quatf, .mul, .nonfinite, "values/Quatf.mul/nonfinite-cross-component-payload", calls_default, no_f32),
    rawCase(Quatf, .from_axis_angle, .ordinary, "values/Quatf.fromAxisAngle/ordinary-axis", calls_exact, raw_axis_angle),
    rawCase(Quatf, .from_axis_angle, .axis_zero, "values/Quatf.fromAxisAngle/zero-axis-null", calls_exact, axis_fold),
    rawCase(Quatf, .from_axis_angle, .axis_nonfinite, "values/Quatf.fromAxisAngle/nonfinite-axis-null", calls_exact, no_f32),
    rawCase(Quatf, .from_axis_angle, .axis_overflow, "values/Quatf.fromAxisAngle/overflow-axis-null", calls_exact, axis_fold),
    rawCase(Quatf, .from_axis_angle, .angle_nonfinite, "values/Quatf.fromAxisAngle/nonfinite-angle-null", calls_exact, no_f32),
    rawCase(Quatf, .is_finite, .ordinary, "values/Quatf.isFinite/ordinary", calls_default, no_f32),
    rawCase(Quatf, .is_finite, .nonfinite, "values/Quatf.isFinite/nonfinite", calls_default, no_f32),
    rawCase(Quatf, .eq, .ordinary, "values/Quatf.eq/ordinary", calls_default, no_f32),
    rawCase(Quatf, .eq, .zero_twin, "values/Quatf.eq/signed-zero-not-equal", calls_default, no_f32),
    rawCase(Quatf, .eq, .nan_twin, "values/Quatf.eq/nan-equals-nan-any-payload", calls_default, no_f32),

    // -----------------------------------------------------------------------
    // Quatd: the raw f64 algebra
    // -----------------------------------------------------------------------
    rawCase(Quatd, .init, .ordinary, "values/Quatd.init/ordinary", calls_default, no_f32),
    rawCase(Quatd, .init, .nonfinite, "values/Quatd.init/nonfinite-payloads", calls_default, no_f32),
    rawCase(Quatd, .identity, .ordinary, "values/Quatd.identity/constant-factory", calls_default, no_f32),
    rawCase(Quatd, .zero, .ordinary, "values/Quatd.zero/constant-factory", calls_default, no_f32),
    rawCase(Quatd, .from_array, .ordinary, "values/Quatd.fromArray/ordinary", calls_default, no_f32),
    rawCase(Quatd, .to_array, .ordinary, "values/Quatd.toArray/ordinary", calls_default, no_f32),
    rawCase(Quatd, .add, .ordinary, "values/Quatd.add/ordinary", calls_default, no_f32),
    rawCase(Quatd, .add, .nonfinite, "values/Quatd.add/nonfinite-canonical-substitution", calls_default, no_f32),
    rawCase(Quatd, .sub, .ordinary, "values/Quatd.sub/ordinary", calls_default, no_f32),
    rawCase(Quatd, .sub, .nonfinite, "values/Quatd.sub/nonfinite-canonical-substitution", calls_default, no_f32),
    rawCase(Quatd, .neg, .ordinary, "values/Quatd.neg/ordinary", calls_default, no_f32),
    rawCase(Quatd, .neg, .signed_zero, "values/Quatd.neg/signed-zero", calls_default, no_f32),
    rawCase(Quatd, .scale, .ordinary, "values/Quatd.scale/ordinary", calls_default, no_f32),
    rawCase(Quatd, .scale, .nonfinite, "values/Quatd.scale/nonfinite-payload-survives", calls_default, no_f32),
    rawCase(Quatd, .scale_quat, .ordinary, "values/Quatd.scaleQuat/ordinary", calls_default, no_f32),
    rawCase(Quatd, .scale_quat, .nonfinite, "values/Quatd.scaleQuat/nonfinite-canonical-substitution", calls_default, no_f32),
    rawCase(Quatd, .dot, .ordinary, "values/Quatd.dot/ordinary", calls_default, no_f32),
    rawCase(Quatd, .dot, .nonfinite, "values/Quatd.dot/nonfinite-canonical-substitution", calls_default, no_f32),
    rawCase(Quatd, .length_squared, .ordinary, "values/Quatd.lengthSquared/ordinary", calls_default, no_f32),
    rawCase(Quatd, .length_squared, .huge, "values/Quatd.lengthSquared/huge-overflow", calls_default, no_f32),
    rawCase(Quatd, .length, .ordinary, "values/Quatd.length/ordinary", calls_default, no_f32),
    rawCase(Quatd, .length, .huge, "values/Quatd.length/huge-fold-overflows", calls_default, no_f32),
    rawCase(Quatd, .length, .large, "values/Quatd.length/large-fold-keeps-finite", calls_default, no_f32),
    rawCase(Quatd, .length, .tiny, "values/Quatd.length/tiny-no-underflow", calls_default, no_f32),
    rawCase(Quatd, .length, .nonfinite, "values/Quatd.length/nonfinite-kernel-precedence", calls_default, no_f32),
    rawCase(Quatd, .conjugate, .ordinary, "values/Quatd.conjugate/ordinary", calls_default, no_f32),
    rawCase(Quatd, .conjugate, .nonfinite, "values/Quatd.conjugate/nonfinite-sign-and-payload", calls_default, no_f32),
    rawCase(Quatd, .inverse, .ordinary, "values/Quatd.inverse/ordinary", calls_default, no_f32),
    rawCase(Quatd, .inverse, .zero, "values/Quatd.inverse/zero-norm-null", calls_default, no_f32),
    rawCase(Quatd, .inverse, .nonfinite, "values/Quatd.inverse/nonfinite-norm-null", calls_default, no_f32),
    rawCase(Quatd, .inverse, .huge, "values/Quatd.inverse/huge-norm-overflow-null", calls_default, no_f32),
    rawCase(Quatd, .mul, .ordinary, "values/Quatd.mul/ordinary", calls_default, no_f32),
    rawCase(Quatd, .mul, .nonfinite, "values/Quatd.mul/nonfinite-cross-component-payload", calls_default, no_f32),
    rawCase(Quatd, .from_axis_angle, .ordinary, "values/Quatd.fromAxisAngle/ordinary-axis", calls_exact, no_f32),
    rawCase(Quatd, .from_axis_angle, .axis_zero, "values/Quatd.fromAxisAngle/zero-axis-null", calls_exact, no_f32),
    rawCase(Quatd, .from_axis_angle, .axis_nonfinite, "values/Quatd.fromAxisAngle/nonfinite-axis-null", calls_exact, no_f32),
    rawCase(Quatd, .from_axis_angle, .axis_overflow, "values/Quatd.fromAxisAngle/overflow-axis-null", calls_exact, no_f32),
    rawCase(Quatd, .from_axis_angle, .angle_nonfinite, "values/Quatd.fromAxisAngle/nonfinite-angle-null", calls_exact, no_f32),
    rawCase(Quatd, .is_finite, .ordinary, "values/Quatd.isFinite/ordinary", calls_default, no_f32),
    rawCase(Quatd, .is_finite, .nonfinite, "values/Quatd.isFinite/nonfinite", calls_default, no_f32),
    rawCase(Quatd, .eq, .ordinary, "values/Quatd.eq/ordinary", calls_default, no_f32),
    rawCase(Quatd, .eq, .zero_twin, "values/Quatd.eq/signed-zero-not-equal", calls_default, no_f32),
    rawCase(Quatd, .eq, .nan_twin, "values/Quatd.eq/nan-equals-nan-any-payload", calls_default, no_f32),

    // -----------------------------------------------------------------------
    // UnitQuatf: the validated f32 rotation
    // -----------------------------------------------------------------------
    unitCase(Quatf, .init, .ordinary, "values/UnitQuatf.init/non-unit-normalized", calls_default, unit_init_charge),
    unitCase(Quatf, .init, .huge, "values/UnitQuatf.init/huge-length-overflow-null", calls_default, quat_fold),
    unitCase(Quatf, .init, .large, "values/UnitQuatf.init/large-finite-normalized", calls_default, unit_init_charge),
    unitCase(Quatf, .init, .zero, "values/UnitQuatf.init/zero-null", calls_default, quat_fold),
    unitCase(Quatf, .init, .tiny, "values/UnitQuatf.init/subnormal-band-null", calls_default, unit_init_charge),
    unitCase(Quatf, .init, .nonfinite, "values/UnitQuatf.init/nonfinite-null", calls_default, no_f32),
    unitCase(Quatf, .dot, .unit, "values/UnitQuatf.dot/unit-pair", calls_default, no_f32),
    unitCase(Quatf, .eq, .unit, "values/UnitQuatf.eq/unit-pair", calls_default, no_f32),
    unitCase(Quatf, .conjugate, .unit, "values/UnitQuatf.conjugate/unit-pair", calls_default, no_f32),
    unitCase(Quatf, .mul, .unit, "values/UnitQuatf.mul/unit-pair-renormalized", calls_default, quat_fold),
    unitCase(Quatf, .then, .unit, "values/UnitQuatf.then/unit-pair-reversed", calls_default, quat_fold),
    unitCase(Quatf, .rotate, .unit, "values/UnitQuatf.rotate/unit-pair-two-hamilton-products", calls_default, no_f32),
    unitCase(Quatf, .from_axis_angle, .ordinary, "values/UnitQuatf.fromAxisAngle/ordinary-axis", calls_exact, unit_axis_angle),
    unitCase(Quatf, .from_axis_angle, .axis_zero, "values/UnitQuatf.fromAxisAngle/zero-axis-null", calls_exact, axis_fold),
    unitCase(Quatf, .from_axis_angle, .axis_nonfinite, "values/UnitQuatf.fromAxisAngle/nonfinite-axis-null", calls_exact, no_f32),
    unitCase(Quatf, .from_axis_angle, .axis_overflow, "values/UnitQuatf.fromAxisAngle/overflow-axis-null", calls_exact, axis_fold),
    unitCase(Quatf, .from_axis_angle, .angle_nonfinite, "values/UnitQuatf.fromAxisAngle/nonfinite-angle-null", calls_exact, no_f32),
    unitCase(Quatf, .slerp, .endpoint, "values/UnitQuatf.slerp/endpoint-short-circuit", calls_exact, slerp_unreachable),
    unitCase(Quatf, .slerp, .unit_near, "values/UnitQuatf.slerp/near-parallel-normalized-lerp", calls_exact, quat_fold),
    unitCase(Quatf, .slerp, .unit_arc, "values/UnitQuatf.slerp/spherical-arc", calls_exact, slerp_spherical),
    unitCase(Quatf, .slerp, .unit_far, "values/UnitQuatf.slerp/negative-dot-sign-flip", calls_exact, slerp_spherical),
    unitCase(Quatf, .slerp, .t_nonfinite, "values/UnitQuatf.slerp/nonfinite-t-null", calls_exact, slerp_unreachable),
    unitCase(Quatf, .lerp, .unit, "values/UnitQuatf.lerp/interior-t-renormalized", calls_default, quat_fold),
    unitCase(Quatf, .lerp, .endpoint, "values/UnitQuatf.lerp/endpoint-short-circuit", calls_default, quat_fold),
    unitCase(Quatf, .lerp, .t_nonfinite, "values/UnitQuatf.lerp/nonfinite-t-propagates", calls_default, quat_fold),

    // -----------------------------------------------------------------------
    // UnitQuatd: the validated f64 rotation
    // -----------------------------------------------------------------------
    unitCase(Quatd, .init, .ordinary, "values/UnitQuatd.init/non-unit-normalized", calls_default, no_f32),
    unitCase(Quatd, .init, .huge, "values/UnitQuatd.init/huge-length-overflow-null", calls_default, no_f32),
    unitCase(Quatd, .init, .large, "values/UnitQuatd.init/large-finite-normalized", calls_default, no_f32),
    unitCase(Quatd, .init, .zero, "values/UnitQuatd.init/zero-null", calls_default, no_f32),
    unitCase(Quatd, .init, .tiny, "values/UnitQuatd.init/subnormal-band-null", calls_default, no_f32),
    unitCase(Quatd, .init, .nonfinite, "values/UnitQuatd.init/nonfinite-null", calls_default, no_f32),
    unitCase(Quatd, .dot, .unit, "values/UnitQuatd.dot/unit-pair", calls_default, no_f32),
    unitCase(Quatd, .eq, .unit, "values/UnitQuatd.eq/unit-pair", calls_default, no_f32),
    unitCase(Quatd, .conjugate, .unit, "values/UnitQuatd.conjugate/unit-pair", calls_default, no_f32),
    unitCase(Quatd, .mul, .unit, "values/UnitQuatd.mul/unit-pair-renormalized", calls_default, no_f32),
    unitCase(Quatd, .then, .unit, "values/UnitQuatd.then/unit-pair-reversed", calls_default, no_f32),
    unitCase(Quatd, .rotate, .unit, "values/UnitQuatd.rotate/unit-pair-two-hamilton-products", calls_default, no_f32),
    unitCase(Quatd, .from_axis_angle, .ordinary, "values/UnitQuatd.fromAxisAngle/ordinary-axis", calls_exact, no_f32),
    unitCase(Quatd, .from_axis_angle, .axis_zero, "values/UnitQuatd.fromAxisAngle/zero-axis-null", calls_exact, no_f32),
    unitCase(Quatd, .from_axis_angle, .axis_nonfinite, "values/UnitQuatd.fromAxisAngle/nonfinite-axis-null", calls_exact, no_f32),
    unitCase(Quatd, .from_axis_angle, .axis_overflow, "values/UnitQuatd.fromAxisAngle/overflow-axis-null", calls_exact, no_f32),
    unitCase(Quatd, .from_axis_angle, .angle_nonfinite, "values/UnitQuatd.fromAxisAngle/nonfinite-angle-null", calls_exact, no_f32),
    unitCase(Quatd, .slerp, .endpoint, "values/UnitQuatd.slerp/endpoint-short-circuit", calls_exact, slerp_unreachable),
    unitCase(Quatd, .slerp, .unit_near, "values/UnitQuatd.slerp/near-parallel-normalized-lerp", calls_exact, no_f32),
    unitCase(Quatd, .slerp, .unit_arc, "values/UnitQuatd.slerp/spherical-arc", calls_exact, no_f32),
    unitCase(Quatd, .slerp, .unit_far, "values/UnitQuatd.slerp/negative-dot-sign-flip", calls_exact, no_f32),
    unitCase(Quatd, .slerp, .t_nonfinite, "values/UnitQuatd.slerp/nonfinite-t-null", calls_exact, slerp_unreachable),
    unitCase(Quatd, .lerp, .unit, "values/UnitQuatd.lerp/interior-t-renormalized", calls_default, no_f32),
    unitCase(Quatd, .lerp, .endpoint, "values/UnitQuatd.lerp/endpoint-short-circuit", calls_default, no_f32),
    unitCase(Quatd, .lerp, .t_nonfinite, "values/UnitQuatd.lerp/nonfinite-t-propagates", calls_default, no_f32),
};
