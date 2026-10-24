//! API benchmarking slice for `zmath.geometry`.
//!
//! Coverage contract: every declared public callable of `src/geometry.zig` is
//! either timed directly below or classified in the inventory comment at the
//! foot of this file. No runtime source is touched: the fixed 132-limb exact
//! engine, the value layouts, the allocation policy and the operation graphs
//! are exactly as they were.
//!
//! Every `invoke` is `noinline`, consumes the runtime index the runner hands
//! it, and returns the protocol hash of the WHOLE semantic result: error
//! status, `Sign` and `ContainedSide` tags, the intersection union tag, and
//! every component of every payload. The index is mixed in, so a caller can
//! confirm the result really varied with the input.
//!
//! Input construction is driven only by that index, through a splitmix stream
//! and exact power-of-two scaling, so no coordinate is a compile-time literal
//! and nothing folds. The scaling keeps every fixture's exact integer
//! coordinates exact, which is what lets a case name state the intersection
//! tag it provokes. The exceptions are the families that exist to sit on a
//! boundary: the subnormal family, whose whole point is a coordinate that is
//! deliberately not exact and whose spread still comes from the stream, and
//! the format-edge rows, whose operands must stand at `floatMax(T)` for the
//! arithmetic to leave the format at all.
//!
//! f32 charge is declared per invoke call and is an upper bound over EVERY
//! branch the timed body can take, derived from the source rather than
//! measured: the accepted `hypotf` / `sqrtf` / `fminf` / `fmaxf` / `absf`
//! evaluations, the subnormal scaled normalization branch, the
//! collinear-overlap branch, and each refusal route. Plain IEEE arithmetic and
//! the integer-only exact sign machinery charge nothing.
//!
//! The runner times a WHOLE `invoke`, so nothing here pretends the setup is
//! outside the measurement. What the fixture costs is kept as small as the
//! arrangements allow: every receiver that does NOT need a constructor is
//! written as a stored literal, which the module's own contract permits
//! because those fields are public, writable and carry only a finiteness
//! invariant, a nonnegative-radius invariant, or a caller-kept unit
//! invariant that an exact coordinate axis already satisfies. A point, a
//! vector, a bivector, a segment and a ball are all literals for that reason.
//! The rows that still have to call a normalizing constructor — the affine
//! intersections, whose whole subject is an arrangement of directions — are
//! charged for it, and their names end in `.normalized_operands` so a reader
//! knows the number is a pipeline cost and not the method's own latency.
//!
//! The five kernels are read through their transitive closures in
//! `src/scalar*.zig` and none of them reaches another binary32 kernel; the
//! inventory at the foot of this file records that check, kernel by kernel.

const std = @import("std");
const common = @import("api_round_common.zig");
const g = @import("zmath").geometry;

// ---------------------------------------------------------------------------
// Deterministic runtime input state
// ---------------------------------------------------------------------------

/// 2^-53, the step mapping a 53-bit integer into [0, 1).
const unit_scale: f64 = 1.0 / 9007199254740992.0;

/// Exact powers of two, so scaling a fixture leaves every bit of its integer
/// coordinates intact while still being a runtime value.
const scale_powers = [_]f64{ 1.0 / 16.0, 1.0 / 8.0, 1.0 / 4.0, 0.5, 1.0, 2.0, 4.0, 8.0 };

const Source = struct {
    state: u64,

    fn begin(index: usize) Source {
        return .{ .state = @as(u64, @intCast(index)) *% 0x9e3779b97f4a7c15 +% 0x0123456789abcdef };
    }

    fn next(self: *Source) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }

    /// A value in [0, 1) from the runtime stream.
    fn unit(self: *Source) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) * unit_scale;
    }

    /// A signed value in (-spread, spread).
    fn span(self: *Source, spread: f64) f64 {
        return (self.unit() * 2.0 - 1.0) * spread;
    }

    /// A nonzero signed magnitude in (spread / 2, spread], so a fixture built
    /// from it can never be the zero vector.
    fn magnitude(self: *Source, spread: f64) f64 {
        const sample = self.unit();
        const sign: f64 = if (sample < 0.5) -1.0 else 1.0;
        return sign * spread * (0.5 + 0.5 * @abs(sample * 2.0 - 1.0));
    }

    /// An exact power of two from the runtime stream.
    fn scale(self: *Source) f64 {
        return scale_powers[@as(usize, @intCast(self.next() & 7))];
    }
};

/// The three input regimes the module's own contract distinguishes.
const Regime = enum { ordinary, near_degenerate, exponent_extreme };

fn regimeOf(index: usize) Regime {
    return switch (index % 3) {
        0 => .ordinary,
        1 => .near_degenerate,
        else => .exponent_extreme,
    };
}

fn regimeSpread(comptime T: type, regime: Regime) f64 {
    return switch (regime) {
        .ordinary => 4.0,
        // Subnormal-magnitude coordinates: squares and determinants underflow
        // to zero, so a plain evaluation ties where the exact one does not.
        // Eight times `floatMin(T)` still folds to a NORMAL norm, so this
        // regime is about the predicates, not about the scaled normalization;
        // `subnormalSpread` below is the band that enters that branch.
        .near_degenerate => @as(f64, std.math.floatMin(T)) * 8.0,
        // Squares and determinants overflow past the top of the format.
        .exponent_extreme => @as(f64, std.math.floatMax(T)) * 0.125,
    };
}

fn componentCount(comptime X: type) comptime_int {
    return @typeInfo(X).@"struct".field_names.len;
}

fn elementOf(comptime X: type) type {
    return @typeInfo(X).@"struct".field_types[0];
}

fn zeros(comptime n: usize) [n]f64 {
    return @splat(0.0);
}

fn axis(comptime n: usize, which: usize, value: f64) [n]f64 {
    var out: [n]f64 = zeros(n);
    out[which % n] = value;
    return out;
}

/// A unit vector along one coordinate axis.
///
/// It is exact, so a stored operand built from it already satisfies the unit
/// invariant its constructor would otherwise have established. That is what
/// lets the method rows build their receiver as a literal and keep the
/// constructor's normalization out of the timed body.
fn unitAxis(comptime n: usize, which: usize) [n]f64 {
    return axis(n, which, 1.0);
}

/// A row that is zero on every component but `which`, which the caller has
/// already chosen in range. `axis` is the wrapping form of the same thing.
fn oneHot(comptime n: usize, which: usize, value: f64) [n]f64 {
    var out: [n]f64 = zeros(n);
    out[which] = value;
    return out;
}

fn plus(comptime n: usize, a: anytype, b: anytype) [n]f64 {
    var out: [n]f64 = undefined;
    for (a, b, 0..) |left, right, index| out[index] = @as(f64, left) + @as(f64, right);
    return out;
}

fn timesAll(comptime n: usize, a: anytype, factor: anytype) [n]f64 {
    var out: [n]f64 = undefined;
    for (a, 0..) |value, index| out[index] = @as(f64, value) * @as(f64, factor);
    return out;
}

/// A point or vector whose every component is the positive infinity of `T`.
///
/// It is stored field by field rather than built through `build`, because
/// `build` narrows through the type's own constructor and that constructor
/// refuses a non-finite component by design. A fixture whose subject IS a
/// non-finite value has to store one instead of constructing one.
fn poisonedValue(comptime X: type, comptime T: type) X {
    var out = std.mem.zeroes(X);
    inline for (@typeInfo(X).@"struct".field_names) |name| @field(out, name) = std.math.inf(T);
    return out;
}

fn rawCoords(comptime X: type, source: *Source, spread: f64) [componentCount(X)]elementOf(X) {
    var out: [componentCount(X)]elementOf(X) = undefined;
    for (&out) |*slot| slot.* = @floatCast(source.span(spread));
    return out;
}

fn regimeCoords(comptime X: type, source: *Source, regime: Regime) [componentCount(X)]elementOf(X) {
    var out: [componentCount(X)]elementOf(X) = undefined;
    const spread = regimeSpread(elementOf(X), regime);
    for (&out) |*slot| slot.* = @floatCast(source.span(spread));
    return out;
}

/// The band a norm has to land in for the source's subnormal scaled
/// normalization to run: `floatMin(T) / 8` for every component.
///
/// `vectorNormalize` and `arrayNormalizedChecked` take that branch exactly when
/// the folded norm is nonzero and BELOW `floatMin(T)`, so the spread has to
/// clear zero and stay under the smallest normal at the same time. One eighth
/// of `floatMin(T)` does both with room to spare: the largest norm four
/// components can reach is `sqrt(4) * floatMin(T) / 8`, a factor of four under
/// the smallest normal, and each component keeps twenty (binary32) or
/// forty-nine (binary64) bits of subnormal significand, so the fold that
/// decides the branch is a real fold and not a flush to zero.
fn subnormalSpread(comptime T: type) f64 {
    return @as(f64, std.math.floatMin(T)) / 8.0;
}

/// A coordinate list whose norm is nonzero and below `floatMin(T)`, which is
/// the input the subnormal scaled normalization exists for: a plain division
/// by that norm would round the component ratios away, so the source divides
/// through the largest component first and folds the norm of the rescaled
/// vector instead.
fn subnormalCoords(comptime X: type, source: *Source) [componentCount(X)]elementOf(X) {
    var out: [componentCount(X)]elementOf(X) = undefined;
    const spread = subnormalSpread(elementOf(X));
    // `magnitude` never returns zero, so the norm is never zero either and the
    // branch is taken on its norm test rather than on the zero test before it.
    for (&out) |*slot| slot.* = @floatCast(source.magnitude(spread));
    return out;
}

/// Builds a concrete value type from any coordinate list, narrowing each
/// element once. The affine and predicate fixtures supply exact small integers
/// or exact power-of-two multiples of one, so their narrowing never rounds and
/// the tag a case name states is the tag the engine returns; the subnormal
/// fixture deliberately narrows a non-exact product, because that branch is
/// about what the narrowings below `floatMin(T)` leave behind.
///
/// The list is checked against the value type's OWN component count, because
/// the loop below writes one slot per supplied coordinate into an array of
/// `componentCount(X)`: a longer list runs off the end of that array and a
/// shorter one leaves slots undefined. A two- or three-dimensional fixture is
/// exactly as wide as the point type it builds, never four wide because the
/// four-dimensional variant of the same fixture is.
fn build(comptime X: type, coords: anytype) X {
    comptime {
        if (@typeInfo(@TypeOf(coords)) != .array or coords.len != componentCount(X)) @compileError(
            "build narrows exactly componentCount(X) coordinates",
        );
    }
    var out: [componentCount(X)]elementOf(X) = undefined;
    for (coords, 0..) |value, position| out[position] = @floatCast(value);
    return X.fromArray(out) catch unreachable;
}

fn coordsOf(comptime X: type, value: X) [componentCount(X)]elementOf(X) {
    return value.toArray();
}

// ---------------------------------------------------------------------------
// Result digests
// ---------------------------------------------------------------------------

const payload_tag: u64 = 0x51ed270b4f6cdd1d;
const failure_tag: u64 = 0x2545f4914f6cdd1d;

fn foldName(name: []const u8) u64 {
    var accumulator: u64 = 0xcbf29ce484222325;
    for (name) |byte| accumulator = (accumulator ^ byte) *% 0x100000001b3;
    return accumulator;
}

/// A refusal, folded by error name so it never aliases a successful payload.
fn refusal(error_name: []const u8) u64 {
    return common.mix(failure_tag, foldName(error_name));
}

/// A value that cannot fail.
fn digest(index: usize, value: anytype) u64 {
    return common.mix(common.hash(value), @as(u64, @intCast(index)));
}

/// An error union: the payload and the error take different tags.
fn outcome(index: usize, value: anytype) u64 {
    if (value) |held| {
        return common.mix(digest(index, held), payload_tag);
    } else |err| {
        return common.mix(refusal(@errorName(err)), @as(u64, @intCast(index)));
    }
}

/// One value's contribution, whether it held or refused. Every member of every
/// tuple `outcomes` folds is an error union — `Segment.at`, `Aabb.contains`,
/// `Aabb.intersects`, `Aabb.volume` and `Aabb.doubledSurfaceArea` all return
/// one, and a refusal is folded under the failure tag so it can never alias a
/// payload.
fn part(value: anytype) u64 {
    if (value) |held| return common.hash(held) else |err| return refusal(@errorName(err));
}

/// A fixed-size tuple of error unions, each payload and each error folded
/// under its own tag so a refusal never aliases a value.
fn outcomes(index: usize, comptime count: usize, values: anytype) u64 {
    var accumulator: u64 = payload_tag;
    inline for (0..count) |position| {
        accumulator = common.mix(accumulator, part(values[position]));
    }
    return common.mix(accumulator, @as(u64, @intCast(index)));
}

/// Binds comptime arguments to one `invoke` pointer, so a case that differs
/// only in a policy, a regime or a fixture shape needs no hand-written
/// wrapper.
///
/// `entry` names the runner on `Impl` to bind, because one wrapper cannot
/// stand for two differently named runners: the segment builder alone binds
/// `run`, `runRay`, `runLine` and `runSubnormalSpan`, and the ball builder
/// binds `runContains`, `runPair`, `runSubnormalTangency`, `runSegment` and
/// `runRay`.
fn Bound(comptime Impl: type, comptime entry: []const u8, comptime arg: anytype) type {
    const Runner = @field(Impl, entry);
    const Arg = @typeInfo(@TypeOf(Runner)).@"fn".param_types[1].?;
    const bound_arg: Arg = blk: {
        if (@typeInfo(Arg) == .@"struct") {
            var value: Arg = undefined;
            for (@typeInfo(Arg).@"struct".field_names) |name| {
                @field(value, name) = @field(arg, name);
            }
            break :blk value;
        }
        break :blk arg;
    };
    return struct {
        fn run(index: usize) u64 {
            return Runner(index, bound_arg);
        }
    };
}

// ---------------------------------------------------------------------------
// f32 charge tables, one per canonical route
//
// Each is an upper bound over every branch the timed body can take. `charge`
// drops the whole table for an `f64` instantiation, because f64 kernels are
// never charged.
//
// The runner times a WHOLE `invoke`, fixture construction included, because
// that is the only work the case owns. Every operand that does not need a
// constructor is written as a stored literal — the module's fields are public
// and writable, and an exact coordinate axis already satisfies the unit
// invariant a line, ray, plane or hyperplane constructor would establish — so
// only the affine rows still build anything. `affineTable` is the one table
// that takes a `built` count for that reason: how many normalizing
// constructors the case runs before it reaches `affineIntersectDispatch`.
// The other tables describe a route whose operands are all stored literals and
// take no such count.
// ---------------------------------------------------------------------------

const no_charge: []const common.Charge = &.{};

fn charge(comptime T: type, comptime table: anytype) []const common.Charge {
    return if (T == f32) &table else no_charge;
}

/// `vectorLength` / `arrayLength`: one `hypotf` per component. The same fold
/// answers the zero test every normalization opens on, so a refusal taken at
/// `error.Degenerate` has already spent the whole table.
fn lengthOf(comptime T: type, comptime dim: usize) []const common.Charge {
    return charge(T, [_]common.Charge{.{ .operation = "hypotf", .count = @intCast(dim) }});
}

/// `count` copies of `vectorNormalize` / `arrayNormalizedChecked`, which is
/// what `Line.init`, `Ray.init`, `Plane.init`, `Hyperplane.init` and
/// `Vector.normalize` each reach, and what the frame builders reach again on
/// each of their own directions.
///
/// One copy folds the norm once (`dim` `hypotf`) and compares it against
/// `floatMin(T)`. A norm at or above that takes one division per component. A
/// norm BELOW it is the subnormal scaled normalization the source added: the
/// largest component is found with one `absf` and one `fmaxf` per component,
/// every component is divided through it, the norm of the RESCALED vector is
/// folded a second time, and every component is divided through that. The
/// table reserves that whole branch even where the operand is a unit vector
/// that cannot enter it, because the reservation is made before the route runs
/// and is never refunded.
///
/// Its failure routes ride the same bound and add no kernel: `Degenerate` is
/// taken at the zero test just after the first fold, `NonFiniteInput` at the
/// component gate just before it, and `NonFiniteResult` when a fold or a
/// division leaves the format.
fn normalizeTable(comptime dim: usize, comptime count: usize) [3]common.Charge {
    return .{
        .{ .operation = "hypotf", .count = @intCast(2 * dim * count) },
        .{ .operation = "fmaxf", .count = @intCast(dim * count) },
        .{ .operation = "absf", .count = @intCast(dim * count) },
    };
}

/// One normalization: the route itself is a normalizing constructor.
fn normalizeOf(comptime T: type, comptime dim: usize) []const common.Charge {
    return charge(T, normalizeTable(dim, 1));
}

/// The one route every pair of lines, rays and segments takes:
/// `affineIntersectDispatch`, plus `built` normalizing constructors the case
/// performs to get there.
///
/// The closed form is the worst case over three and four dimensions with all
/// three of the route's own normalizations taking the subnormal branch at
/// once, term by term:
///
/// - `u = a_finish - a_start`, normalized: `2 * dim` `hypotf`, `dim` `fmaxf`,
///   `dim` `absf`.
/// - the zero test on the normalized `u`: `dim` `hypotf`.
/// - the zero test on the residual: `dim` `hypotf`.
/// - the second frame direction, either the normalized residual or
///   `anyPerpendicularChecked`: `2 * dim` `hypotf`, `dim` `fmaxf`, and
///   `2 * dim` `absf`, because the perpendicular seed also searches `dim` axes
///   before it normalizes.
/// - `affine2Intersect`'s two zero tests on the projected directions: `4`
///   `hypotf`.
/// - the `.line` payload, whose direction is folded and normalized once more:
///   `3 * dim` `hypotf`, `dim` `fmaxf`, `dim` `absf`.
/// - `collinearOverlap`, reached whenever either supporting line is
///   collinear: `2` `absf`, `3` `fminf`, `3` `fmaxf`.
///
/// Two dimensions skip the frame entirely and reach only the last two steps,
/// so the same closed form covers them.
fn affineTable(comptime dim: usize, comptime built: usize) [4]common.Charge {
    return .{
        .{ .operation = "hypotf", .count = @intCast(9 * dim + 4 + 2 * dim * built) },
        .{ .operation = "fmaxf", .count = @intCast(3 * dim + 3 + dim * built) },
        .{ .operation = "absf", .count = @intCast(4 * dim + 2 + dim * built) },
        .{ .operation = "fminf", .count = 3 },
    };
}

/// The route alone, for a case whose operands reach no accepted kernel.
fn affineOf(comptime T: type, comptime dim: usize) []const common.Charge {
    return charge(T, affineTable(dim, 0));
}

/// The route plus `built` normalizing constructors the case performs itself.
fn affineCaseOf(comptime T: type, comptime dim: usize, comptime built: usize) []const common.Charge {
    return charge(T, affineTable(dim, built));
}

/// `Ball.intersect`: `ballIntersect`. Its operands are two balls, and
/// `ballBuild` only gates and compares, so nothing is added here.
///
/// The coincident test folds the separation once: `dim` `hypotf`. After that
/// exactly one of two branches runs, and the crossing branch is the larger of
/// the two.
///
/// - Tangency: the separation is normalized for the touch point, so `2 * dim`
///   `hypotf`, `dim` `fmaxf` and `dim` `absf` on top of the fold.
/// - Crossing: `ballCrossingPoints` folds the separation again (`dim`
///   `hypotf`), then `anyPerpendicularChecked` searches `dim` axes with `dim`
///   `absf` and normalizes its residual, whose norm may again be subnormal
///   (`2 * dim` `hypotf`, `dim` `fmaxf`, `dim` `absf`), and `chordHeight` ends
///   the route with two `sqrtf` and two `absf`.
fn ballPairOf(comptime T: type, comptime dim: usize) []const common.Charge {
    return charge(T, [_]common.Charge{
        .{ .operation = "hypotf", .count = @intCast(4 * dim) },
        .{ .operation = "fmaxf", .count = @intCast(dim) },
        .{ .operation = "absf", .count = @intCast(2 * dim + 2) },
        .{ .operation = "sqrtf", .count = 2 },
    });
}

/// `Ball.intersectSegment`: `ballIntersectSegment`. The inside test is a
/// predicate and reaches no kernel; the span norm is `dim` `hypotf`; the ray
/// quadratic it then solves takes one `sqrtf` and one `absf` for the root, and
/// the clamped overlap takes one `fmaxf` and one `fminf`. The operands are one
/// ball and one segment, neither of which normalizes.
fn ballSegmentOf(comptime T: type, comptime dim: usize) []const common.Charge {
    return charge(T, [_]common.Charge{
        .{ .operation = "hypotf", .count = @intCast(dim) },
        .{ .operation = "sqrtf", .count = 1 },
        .{ .operation = "absf", .count = 1 },
        .{ .operation = "fmaxf", .count = 1 },
        .{ .operation = "fminf", .count = 1 },
    });
}

/// `Ball.intersectRay`: `ballIntersectRay`. Both operands are stored literals,
/// so nothing is added for building them. No span norm is formed on that
/// route, so what is left of it is the quadratic root: one `sqrtf` and one
/// `absf`.
fn rayBallOf(comptime T: type, comptime dim: usize) []const common.Charge {
    return charge(T, [_]common.Charge{
        .{ .operation = "hypotf", .count = @intCast(2 * dim) },
        .{ .operation = "fmaxf", .count = @intCast(dim) },
        .{ .operation = "absf", .count = @intCast(dim + 1) },
        .{ .operation = "sqrtf", .count = 1 },
    });
}

/// `Sphere.intersectPlane`, `Hypersphere.intersectHyperplane` and
/// `Flat.intersectSphere`: the one `ballIntersectFlat`. Both operands are
/// stored literals, so nothing is added for building them. The section radius
/// is one `sqrtf` and one `absf`; the tangent point and the `.none` answer take
/// neither.
fn ballFlatOf(comptime T: type, comptime dim: usize) []const common.Charge {
    return charge(T, [_]common.Charge{
        .{ .operation = "hypotf", .count = @intCast(2 * dim) },
        .{ .operation = "fmaxf", .count = @intCast(dim) },
        .{ .operation = "absf", .count = @intCast(dim + 1) },
        .{ .operation = "sqrtf", .count = 1 },
    });
}

/// `Plane3.intersect`: `flatPair3`, or `Hyperplane4.intersect`:
/// `flatPair4`. Both operands are stored literals whose normals are exact
/// coordinate axes, so nothing is added for building them.
///
/// In three dimensions the parallel gate and the offset test are predicates
/// and reach no kernel, and the non-parallel branch normalizes the cross
/// product and then the in-plane transversal: two normalizations.
///
/// In four dimensions the in-plane normal is normalized once, then
/// `seedOutsideBasis` is called twice — the second against a three-vector
/// basis — and each call ends in `orthogonalizedChecked`, whose own
/// normalization carries the same subnormal reservation: three
/// normalizations. Two unit normals cannot in fact produce a subnormal
/// in-plane normal, so that part of the reservation is headroom rather than a
/// reachable count; it is reserved all the same, because a reservation is
/// made before the route runs.
fn flatPairOf(comptime T: type, comptime dim: usize) []const common.Charge {
    const inside: usize = if (dim == 3) 2 else 3;
    return charge(T, [_]common.Charge{
        .{ .operation = "hypotf", .count = @intCast(2 * dim * inside) },
        .{ .operation = "fmaxf", .count = @intCast(dim * inside) },
        .{ .operation = "absf", .count = @intCast(dim * inside) },
    });
}

/// `Aabb.expand` and `Aabb.intersect`: one `fminf` and one `fmaxf` per axis,
/// which is the whole of both routes and of the `Aabb.init` fixture they share,
/// because `aabbBuild` only compares. `Aabb.init` itself therefore carries no
/// table.
fn boxSelectOf(comptime T: type, comptime dim: usize) []const common.Charge {
    return charge(T, [_]common.Charge{
        .{ .operation = "fminf", .count = @intCast(dim) },
        .{ .operation = "fmaxf", .count = @intCast(dim) },
    });
}

// ---------------------------------------------------------------------------
// Affine fixture shapes
//
// Every coordinate is a small exact integer scaled by a runtime power of two,
// so the arrangement is exact and the tag the case name states is the tag the
// intersection engine returns.
// ---------------------------------------------------------------------------

const Shape = enum {
    /// One common point, at the shared origin.
    crossing,
    /// One common point, away from both ends.
    crossing_offset,
    /// One common collinear run.
    collinear,
    /// Parallel and distinct: no common point.
    parallel_disjoint,
    /// The two operands are the same set.
    coincident,
    /// One operand lies wholly inside the other.
    contained,
    /// A degenerate segment that is one point, lying on the other operand.
    degenerate_on,
    /// A degenerate segment that is one point, off the other operand.
    degenerate_off,
};

/// The start and finish of one operand of an affine pair.
fn affineFixture(
    comptime dim: usize,
    scale: f64,
    comptime shape: Shape,
    comptime which: usize,
) struct { start: [dim]f64, finish: [dim]f64 } {
    const x = scale;
    switch (shape) {
        .crossing => {
            return if (which == 0)
                .{ .start = zeros(dim), .finish = axis(dim, 0, x) }
            else
                .{ .start = zeros(dim), .finish = axis(dim, 1, x) };
        },
        .crossing_offset => {
            return if (which == 0)
                .{ .start = zeros(dim), .finish = axis(dim, 0, x) }
            else
                .{
                    .start = axis(dim, 0, x / 2),
                    .finish = plus(dim, axis(dim, 0, x / 2), axis(dim, 1, 2.0 * x)),
                };
        },
        .collinear => {
            return if (which == 0)
                .{ .start = zeros(dim), .finish = axis(dim, 0, 2.0 * x) }
            else
                .{ .start = axis(dim, 0, x), .finish = axis(dim, 0, 3.0 * x) };
        },
        .parallel_disjoint => {
            return if (which == 0)
                .{ .start = zeros(dim), .finish = axis(dim, 0, x) }
            else
                .{
                    .start = axis(dim, 1, x),
                    .finish = plus(dim, axis(dim, 1, x), axis(dim, 0, x)),
                };
        },
        .coincident => {
            return .{ .start = zeros(dim), .finish = axis(dim, 0, x) };
        },
        .contained => {
            return if (which == 0)
                .{ .start = axis(dim, 0, x), .finish = axis(dim, 0, 2.0 * x) }
            else
                .{ .start = zeros(dim), .finish = axis(dim, 0, 3.0 * x) };
        },
        .degenerate_on => {
            return if (which == 0)
                .{ .start = axis(dim, 0, x / 2), .finish = axis(dim, 0, x / 2) }
            else
                .{ .start = zeros(dim), .finish = axis(dim, 0, x) };
        },
        .degenerate_off => {
            return if (which == 0)
                .{
                    .start = axis(dim, 1, x / 2),
                    .finish = axis(dim, 1, x / 2),
                }
            else
                .{ .start = zeros(dim), .finish = axis(dim, 0, x) };
        },
    }
}

/// The near-degenerate tie indices.
///
/// `k1` is odd and congruent to 3 modulo 4 and `k2` is congruent to 2 modulo 4,
/// so both `k1 * k2` and `(k1 - 4) * (k2 - 4)` are odd multiples of two.
/// Scaled into a binade whose spacing is two, each product is then an exact
/// halfway case and ties-to-even sends both to the SAME representable number,
/// so the plain evaluation reports `zero` for a determinant whose exact value
/// is `4 * (k1 + k2 - 4)`. The jitter moves in steps that preserve both
/// residues and keep the products inside that binade.
const tie_f32_base_1: f64 = 5003.0;
const tie_f32_base_2: f64 = 6402.0;
const tie_f64_base_1: f64 = 134217823.0;
const tie_f64_base_2: f64 = 134217818.0;

fn tieIndices(comptime T: type, source: *Source) struct { k1: T, k2: T } {
    const base1: f64 = if (T == f32) tie_f32_base_1 else tie_f64_base_1;
    const base2: f64 = if (T == f32) tie_f32_base_2 else tie_f64_base_2;
    const step: f64 = if (T == f32) 4.0 else 8.0;
    return .{
        .k1 = @floatCast(base1 + step * @floor(source.unit() * 4.0)),
        .k2 = @floatCast(base2 + step * @floor(source.unit() * 4.0)),
    };
}

/// The exact sign-predicate fixtures, per dimension. Each returns four points
/// so one set of builders serves both the three- and four-dimensional
/// predicates.
fn signFixture(
    comptime P: type,
    source: *Source,
    regime: Regime,
) struct { a: P, b: P, c: P, d: P } {
    const T = elementOf(P);
    const n = componentCount(P);
    const tie = tieIndices(T, source);
    const k1: f64 = @floatCast(tie.k1);
    const k2: f64 = @floatCast(tie.k2);

    var rows: [4][n]f64 = undefined;
    switch (regime) {
        .ordinary => {
            for (0..4) |row| {
                var coords: [n]f64 = undefined;
                for (0..n) |index| coords[index] = source.span(4.0);
                rows[row] = timesAll(n, coords, source.scale());
            }
        },
        .near_degenerate => {
            // The tie construction. Both plain products are odd multiples of
            // two in a binade whose spacing is two, so each is an exact
            // halfway case and ties-to-even sends both to the same
            // representable number.
            //
            // In two dimensions the determinant IS that pair of products, so
            // the second point carries `(k1, k2 - 4)` and the third carries
            // `(k1 - 4, k2)`: the first product is `k1 * k2` and the second is
            // `(k1 - 4) * (k2 - 4)`, and they differ by `4 * (k1 + k2 - 4)`.
            //
            // In three and four dimensions the determinant is the volume those
            // four points span, so the pair is lifted onto separate axes and
            // the unused axes carry small integers: the second point takes `k1`
            // on axis zero, the third takes `k2` on axis one, and the fourth
            // takes both at half magnitude beside integers, which leaves the
            // cancelling pair of products in the leading minor.
            rows[0] = zeros(n);
            if (n == 2) {
                rows[1] = oneHot(n, 0, k1);
                rows[1][1] = k2 - 4.0;
                rows[2] = oneHot(n, 1, k2);
                rows[2][0] = k1 - 4.0;
                rows[3] = oneHot(n, 0, k1 * 0.5);
                rows[3][1] = k2 * 0.5;
            } else {
                rows[1] = oneHot(n, 0, k1);
                rows[2] = oneHot(n, 1, k2);
                var fourth: [n]f64 = zeros(n);
                fourth[0] = k1 * 0.5;
                fourth[1] = k2 * 0.5;
                fourth[2] = 3.0;
                if (n > 3) fourth[3] = 1.0;
                rows[3] = fourth;
            }
        },
        .exponent_extreme => {
            // Every coordinate at the top of its format with alternating
            // signs, so the plain determinant overflows to signed infinities
            // while the exact determinant is formed from widened integers.
            const high = @as(f64, std.math.floatMax(T)) * 0.5;
            const wobble = 0.25 + 0.5 * source.unit();
            var row: usize = 0;
            while (row < 4) : (row += 1) {
                var coords: [n]f64 = undefined;
                for (0..n) |index| {
                    const sign: f64 = if (((row + index) & 1) == 0) 1.0 else -1.0;
                    coords[index] = sign * high * wobble;
                }
                rows[row] = coords;
            }
        },
    }
    return .{
        .a = build(P, rows[0]),
        .b = build(P, rows[1]),
        .c = build(P, rows[2]),
        .d = build(P, rows[3]),
    };
}

/// The four-dimensional near-dependence: the first row is the componentwise
/// sum of the second and third plus one in the last component, so the exact
/// determinant is a small number in a sum of terms many orders of magnitude
/// larger.
fn dependentFixture(
    comptime P: type,
    source: *Source,
) struct { a: P, b: P, c: P, d: P } {
    const n = componentCount(P);
    const spread: f64 = if (elementOf(P) == f32) 4194304.0 else 16777216.0;
    const scale = source.scale();
    const b = build(P, timesAll(n, rawCoords(P, source, spread), scale));
    const c = build(P, timesAll(n, rawCoords(P, source, spread), scale));
    const d = build(P, timesAll(n, rawCoords(P, source, spread), scale));
    const b_row = coordsOf(P, b);
    const c_row = coordsOf(P, c);
    var a_row: [4]f64 = undefined;
    for (0..3) |index| a_row[index] = b_row[index] + c_row[index];
    a_row[3] = b_row[3] + c_row[3] + 1;
    return .{ .a = build(P, a_row), .b = b, .c = c, .d = d };
}

/// `d` is `b` plus a few units in the last place, so the exact determinant is
/// dominated by cancellation while every plain-evaluation term is not.
fn perturbedFixture(
    comptime P: type,
    source: *Source,
) struct { a: P, b: P, c: P, d: P } {
    const T = elementOf(P);
    const n = componentCount(P);
    const tie = tieIndices(T, source);
    const k1: f64 = @floatCast(tie.k1);
    const k2: f64 = @floatCast(tie.k2);
    const ulp = @as(f64, std.math.floatEps(T)) * 64.0;
    // The row is `n` wide: `build` narrows exactly the extent the point type
    // declares, so a four-wide row would write past the two- and
    // three-dimensional values and leave `d_row[3]` undefined there.
    var d_row: [n]f64 = undefined;
    d_row[0] = k1 + source.span(ulp);
    d_row[1] = source.span(ulp);
    if (n > 2) d_row[2] = 1.0 + source.span(ulp);
    if (n > 3) d_row[3] = source.span(ulp);
    return .{
        .a = build(P, zeros(n)),
        .b = build(P, oneHot(n, 0, k1)),
        .c = build(P, oneHot(n, 1, k2)),
        .d = build(P, d_row),
    };
}

// ---------------------------------------------------------------------------
// Vector2 / Vector3 / Vector4
// ---------------------------------------------------------------------------

fn VectorOps(comptime V: type, comptime P: type) type {
    return struct {
        const T = elementOf(V);
        const dim = componentCount(V);
        const tag = @typeName(V);

        noinline fn init(index: usize) u64 {
            var source = Source.begin(index);
            const a = rawCoords(V, &source, 4.0);
            const value = if (comptime dim == 2)
                V.init(a[0], a[1])
            else if (comptime dim == 3)
                V.init(a[0], a[1], a[2])
            else
                V.init(a[0], a[1], a[2], a[3]);
            return outcome(index, value);
        }

        noinline fn initPoisoned(index: usize) u64 {
            // The constructor refusal path: a non-finite component.
            const held = poisonedValue(V, T);
            const value = if (comptime dim == 2)
                V.init(held.x, held.y)
            else if (comptime dim == 3)
                V.init(held.x, held.y, held.z)
            else
                V.init(held.x, held.y, held.z, held.w);
            return outcome(index, value);
        }

        noinline fn fromArray(index: usize) u64 {
            var source = Source.begin(index);
            return outcome(index, V.fromArray(rawCoords(V, &source, 4.0)));
        }

        noinline fn toArray(index: usize) u64 {
            var source = Source.begin(index);
            const held = V.fromArray(rawCoords(V, &source, 4.0)) catch unreachable;
            return digest(index, held.toArray());
        }

        noinline fn add(index: usize) u64 {
            var source = Source.begin(index);
            const left = V.fromArray(rawCoords(V, &source, 4.0)) catch unreachable;
            const right = V.fromArray(rawCoords(V, &source, 4.0)) catch unreachable;
            return outcome(index, left.add(right));
        }

        noinline fn sub(index: usize) u64 {
            var source = Source.begin(index);
            const left = V.fromArray(rawCoords(V, &source, 4.0)) catch unreachable;
            const right = V.fromArray(rawCoords(V, &source, 4.0)) catch unreachable;
            return outcome(index, left.sub(right));
        }

        noinline fn neg(index: usize) u64 {
            var source = Source.begin(index);
            const held = V.fromArray(rawCoords(V, &source, 4.0)) catch unreachable;
            return outcome(index, held.neg());
        }

        noinline fn scale(index: usize) u64 {
            var source = Source.begin(index);
            const held = V.fromArray(rawCoords(V, &source, 4.0)) catch unreachable;
            return outcome(index, held.scale(@floatCast(source.magnitude(2.0))));
        }

        noinline fn dot(index: usize) u64 {
            var source = Source.begin(index);
            const left = V.fromArray(rawCoords(V, &source, 4.0)) catch unreachable;
            const right = V.fromArray(rawCoords(V, &source, 4.0)) catch unreachable;
            return outcome(index, left.dot(right));
        }

        noinline fn lengthSquared(index: usize) u64 {
            var source = Source.begin(index);
            const held = V.fromArray(regimeCoords(V, &source, regimeOf(index))) catch unreachable;
            return outcome(index, held.lengthSquared());
        }

        noinline fn length(index: usize) u64 {
            var source = Source.begin(index);
            const held = V.fromArray(regimeCoords(V, &source, regimeOf(index))) catch unreachable;
            return outcome(index, held.length());
        }

        noinline fn normalize(index: usize) u64 {
            var source = Source.begin(index);
            const held = V.fromArray(regimeCoords(V, &source, regimeOf(index))) catch unreachable;
            return outcome(index, held.normalize());
        }

        noinline fn normalizeDegenerate(index: usize) u64 {
            // The refusal paths: a zero direction has no unit form, and a
            // non-finite component is an input failure.
            const held = if (index % 2 == 0)
                build(V, zeros(dim))
            else
                poisonedValue(V, T);
            return outcome(index, held.normalize());
        }

        /// The subnormal scaled normalization: a norm below `floatMin(T)` cannot
        /// be divided through, because that quotient would round the component
        /// ratios away, so the source divides through the largest component and
        /// folds the norm of the rescaled vector instead.
        /// `normalize.degenerate` reaches the zero test and the input gate;
        /// this reaches the branch between them.
        noinline fn normalizeSubnormal(index: usize) u64 {
            var source = Source.begin(index);
            const held = V.fromArray(subnormalCoords(V, &source)) catch unreachable;
            return outcome(index, held.normalize());
        }

        /// The overflow route of the same fold: a norm past the top of the
        /// format is `error.NonFiniteResult`, not the infinity a caller would
        /// then divide by and read as the zero vector.
        noinline fn normalizeOverflow(index: usize) u64 {
            const held = build(V, @as([dim]f64, @splat(@as(f64, std.math.floatMax(T)))));
            return outcome(index, held.normalize());
        }

        noinline fn distanceSquared(index: usize) u64 {
            var source = Source.begin(index);
            const regime = regimeOf(index);
            const left = V.fromArray(regimeCoords(V, &source, regime)) catch unreachable;
            const target = build(P, regimeCoords(P, &source, regime));
            return outcome(index, left.distanceSquared(target));
        }

        noinline fn distance(index: usize) u64 {
            var source = Source.begin(index);
            const regime = regimeOf(index);
            const left = V.fromArray(regimeCoords(V, &source, regime)) catch unreachable;
            const target = build(P, regimeCoords(P, &source, regime));
            return outcome(index, left.distance(target));
        }

        noinline fn isFinite(index: usize) u64 {
            var source = Source.begin(index);
            const held = V.fromArray(rawCoords(V, &source, 4.0)) catch unreachable;
            const poisoned = poisonedValue(V, T);
            return digest(index, .{ held.isFinite(), poisoned.isFinite() });
        }

        noinline fn eq(index: usize) u64 {
            var source = Source.begin(index);
            const left = V.fromArray(rawCoords(V, &source, 4.0)) catch unreachable;
            const right = if (index % 2 == 0)
                left
            else
                V.fromArray(rawCoords(V, &source, 4.0)) catch unreachable;
            const negative_zero = build(V, @as([dim]f64, @splat(-0.0)));
            const positive_zero = build(V, @as([dim]f64, @splat(0.0)));
            return digest(index, .{
                left.eq(right),
                negative_zero.eq(positive_zero),
                negative_zero.eq(negative_zero),
            });
        }

        noinline fn cross(index: usize) u64 {
            if (comptime dim == 3) {
                var source = Source.begin(index);
                const regime = regimeOf(index);
                const left = V.fromArray(regimeCoords(V, &source, regime)) catch unreachable;
                const right = V.fromArray(regimeCoords(V, &source, regime)) catch unreachable;
                return outcome(index, left.cross(right));
            } else {
                return 0;
            }
        }

        noinline fn wedge(index: usize) u64 {
            if (comptime dim == 4) {
                var source = Source.begin(index);
                const regime = regimeOf(index);
                const left = V.fromArray(regimeCoords(V, &source, regime)) catch unreachable;
                const right = V.fromArray(regimeCoords(V, &source, regime)) catch unreachable;
                const value = left.wedge(right) catch |err| return refusal(@errorName(err));
                return digest(index, .{ value.xy, value.xz, value.xw, value.yz, value.yw, value.zw });
            } else {
                return 0;
            }
        }

        fn cases() [count]common.Case {
            var list: [count]common.Case = undefined;
            var at_index: usize = 0;
            const base = [_]common.Case{
                .{ .name = @typeName(V) ++ ".init", .namespace = "geometry", .invoke = init },
                .{ .name = @typeName(V) ++ ".init.poisoned", .namespace = "geometry", .invoke = initPoisoned },
                .{ .name = @typeName(V) ++ ".fromArray", .namespace = "geometry", .invoke = fromArray },
                .{ .name = @typeName(V) ++ ".toArray", .namespace = "geometry", .invoke = toArray },
                .{ .name = @typeName(V) ++ ".add", .namespace = "geometry", .invoke = add },
                .{ .name = @typeName(V) ++ ".sub", .namespace = "geometry", .invoke = sub },
                .{ .name = @typeName(V) ++ ".neg", .namespace = "geometry", .invoke = neg },
                .{ .name = @typeName(V) ++ ".scale", .namespace = "geometry", .invoke = scale },
                .{ .name = @typeName(V) ++ ".dot", .namespace = "geometry", .invoke = dot },
                .{ .name = @typeName(V) ++ ".lengthSquared", .namespace = "geometry", .invoke = lengthSquared },
                .{
                    .name = @typeName(V) ++ ".length",
                    .namespace = "geometry",
                    .invoke = length,
                    .f32 = lengthOf(T, dim),
                },
                .{
                    .name = @typeName(V) ++ ".normalize",
                    .namespace = "geometry",
                    .invoke = normalize,
                    .f32 = normalizeOf(T, dim),
                },
                .{
                    .name = @typeName(V) ++ ".normalize.degenerate",
                    .namespace = "geometry",
                    .invoke = normalizeDegenerate,
                    .f32 = lengthOf(T, dim),
                },
                .{
                    .name = @typeName(V) ++ ".normalize.subnormal_norm",
                    .namespace = "geometry",
                    .invoke = normalizeSubnormal,
                    .f32 = normalizeOf(T, dim),
                },
                .{
                    .name = @typeName(V) ++ ".normalize.overflow",
                    .namespace = "geometry",
                    .invoke = normalizeOverflow,
                    .f32 = lengthOf(T, dim),
                },
                .{ .name = @typeName(V) ++ ".distanceSquared", .namespace = "geometry", .invoke = distanceSquared },
                .{
                    .name = @typeName(V) ++ ".distance",
                    .namespace = "geometry",
                    .invoke = distance,
                    .f32 = lengthOf(T, dim),
                },
                .{ .name = @typeName(V) ++ ".isFinite", .namespace = "geometry", .invoke = isFinite },
                .{ .name = @typeName(V) ++ ".eq", .namespace = "geometry", .invoke = eq },
            };
            for (base) |entry| {
                list[at_index] = entry;
                at_index += 1;
            }
            if (comptime dim == 3) {
                list[at_index] = .{ .name = @typeName(V) ++ ".cross", .namespace = "geometry", .invoke = cross };
                at_index += 1;
            }
            if (comptime dim == 4) {
                list[at_index] = .{ .name = @typeName(V) ++ ".wedge", .namespace = "geometry", .invoke = wedge };
                at_index += 1;
            }
            return list;
        }

        const count = 19 + @as(usize, @intFromBool(dim == 3)) + @as(usize, @intFromBool(dim == 4));
    };
}

// ---------------------------------------------------------------------------
// Bivector4
// ---------------------------------------------------------------------------

fn BivectorOps(comptime B: type) type {
    return struct {
        const T = elementOf(B);
        const tag = @typeName(B);

        noinline fn init(index: usize) u64 {
            var source = Source.begin(index);
            var parts: [6]T = undefined;
            for (&parts) |*slot| slot.* = @floatCast(source.span(4.0));
            return outcome(index, B.init(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]));
        }

        noinline fn initPoisoned(index: usize) u64 {
            return outcome(index, B.init(
                std.math.inf(T),
                @as(T, 1),
                @as(T, 1),
                @as(T, 1),
                @as(T, 1),
                @as(T, 1),
            ));
        }

        noinline fn neg(index: usize) u64 {
            var source = Source.begin(index);
            var parts: [6]T = undefined;
            for (&parts) |*slot| slot.* = @floatCast(source.span(4.0));
            const held = B.init(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]) catch unreachable;
            const flipped = held.neg();
            return digest(index, .{ flipped.xy, flipped.xz, flipped.xw, flipped.yz, flipped.yw, flipped.zw });
        }

        noinline fn isFinite(index: usize) u64 {
            var source = Source.begin(index);
            var parts: [6]T = undefined;
            for (&parts) |*slot| slot.* = @floatCast(source.span(4.0));
            const held = B.init(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]) catch unreachable;
            // Stored, not constructed: `Bivector.init` refuses a non-finite
            // component by design, and this row exists to meet one.
            const poisoned = B{
                .xy = @as(T, 1),
                .xz = @as(T, 1),
                .xw = @as(T, 1),
                .yz = @as(T, 1),
                .yw = @as(T, 1),
                .zw = std.math.inf(T),
            };
            return digest(index, .{ held.isFinite(), poisoned.isFinite() });
        }

        fn cases() [4]common.Case {
            return .{
                .{ .name = tag ++ ".init", .namespace = "geometry", .invoke = init },
                .{ .name = tag ++ ".init.poisoned", .namespace = "geometry", .invoke = initPoisoned },
                .{ .name = tag ++ ".neg", .namespace = "geometry", .invoke = neg },
                .{ .name = tag ++ ".isFinite", .namespace = "geometry", .invoke = isFinite },
            };
        }
    };
}

// ---------------------------------------------------------------------------
// Point2 / Point3 / Point4
// ---------------------------------------------------------------------------

fn PointOps(comptime P: type, comptime V: type) type {
    return struct {
        const T = elementOf(P);
        const dim = componentCount(P);
        const tag = @typeName(P);

        noinline fn init(index: usize) u64 {
            var source = Source.begin(index);
            const a = rawCoords(P, &source, 4.0);
            const value = if (comptime dim == 2)
                P.init(a[0], a[1])
            else if (comptime dim == 3)
                P.init(a[0], a[1], a[2])
            else
                P.init(a[0], a[1], a[2], a[3]);
            return outcome(index, value);
        }

        noinline fn initPoisoned(index: usize) u64 {
            var a: [4]T = undefined;
            a[0] = std.math.inf(T);
            a[1] = -std.math.inf(T);
            a[2] = std.math.nan(T);
            a[3] = std.math.inf(T);
            const value = if (comptime dim == 2)
                P.init(a[0], a[1])
            else if (comptime dim == 3)
                P.init(a[0], a[1], a[2])
            else
                P.init(a[0], a[1], a[2], a[3]);
            return outcome(index, value);
        }

        noinline fn fromArray(index: usize) u64 {
            var source = Source.begin(index);
            return outcome(index, P.fromArray(rawCoords(P, &source, 4.0)));
        }

        noinline fn toArray(index: usize) u64 {
            var source = Source.begin(index);
            const held = P.fromArray(rawCoords(P, &source, 4.0)) catch unreachable;
            return digest(index, held.toArray());
        }

        noinline fn add(index: usize) u64 {
            var source = Source.begin(index);
            const regime = regimeOf(index);
            const held = P.fromArray(regimeCoords(P, &source, regime)) catch unreachable;
            const offset = V.fromArray(regimeCoords(V, &source, regime)) catch unreachable;
            return outcome(index, held.add(offset));
        }

        noinline fn sub(index: usize) u64 {
            var source = Source.begin(index);
            const regime = regimeOf(index);
            const held = P.fromArray(regimeCoords(P, &source, regime)) catch unreachable;
            const offset = V.fromArray(regimeCoords(V, &source, regime)) catch unreachable;
            return outcome(index, held.sub(offset));
        }

        noinline fn toVector(index: usize) u64 {
            var source = Source.begin(index);
            const held = P.fromArray(regimeCoords(P, &source, regimeOf(index))) catch unreachable;
            return digest(index, held.toVector().toArray());
        }

        noinline fn isFinite(index: usize) u64 {
            var source = Source.begin(index);
            const held = P.fromArray(rawCoords(P, &source, 4.0)) catch unreachable;
            const poisoned = poisonedValue(P, T);
            return digest(index, .{ held.isFinite(), poisoned.isFinite() });
        }

        noinline fn eq(index: usize) u64 {
            var source = Source.begin(index);
            const left = P.fromArray(rawCoords(P, &source, 4.0)) catch unreachable;
            const right = if (index % 2 == 0)
                left
            else
                P.fromArray(rawCoords(P, &source, 4.0)) catch unreachable;
            const negative_zero = build(P, @as([dim]f64, @splat(-0.0)));
            const positive_zero = build(P, @as([dim]f64, @splat(0.0)));
            return digest(index, .{
                left.eq(right),
                negative_zero.eq(positive_zero),
                negative_zero.eq(negative_zero),
            });
        }

        /// Both policies over both precisions and all three regimes.
        noinline fn run(index: usize, comptime arg: struct { policy: g.PredicatePolicy, regime: Regime }) u64 {
            var source = Source.begin(index);
            const rows = signFixture(P, &source, arg.regime);
            return if (comptime dim == 2)
                outcome(index, P.orientation(rows.a, rows.b, rows.c, arg.policy))
            else
                outcome(index, P.orientation(rows.a, rows.b, rows.c, rows.d, arg.policy));
        }

        /// The four-dimensional near-dependence, both policies.
        noinline fn runDependent(index: usize, comptime policy: g.PredicatePolicy) u64 {
            var source = Source.begin(index);
            const rows = dependentFixture(P, &source);
            return outcome(index, P.orientation(rows.a, rows.b, rows.c, rows.d, policy));
        }

        /// `d` a few units in the last place away from the exact plane, both
        /// policies.
        noinline fn runPerturbed(index: usize, comptime policy: g.PredicatePolicy) u64 {
            var source = Source.begin(index);
            const rows = perturbedFixture(P, &source);
            return if (comptime dim == 2)
                outcome(index, P.orientation(rows.a, rows.b, rows.c, policy))
            else
                outcome(index, P.orientation(rows.a, rows.b, rows.c, rows.d, policy));
        }

        /// `Point2.side`, the two-dimensional-only entry point.
        noinline fn runSide(index: usize, comptime arg: struct { policy: g.PredicatePolicy, tied: bool }) u64 {
            if (comptime dim == 2) {
                var source = Source.begin(index);
                const rows = signFixture(P, &source, if (arg.tied) .near_degenerate else regimeOf(index));
                return outcome(index, rows.a.side(rows.b, rows.c, arg.policy));
            } else {
                return 0;
            }
        }

        fn cases() [count]common.Case {
            var list: [count]common.Case = undefined;
            var slot: usize = 0;
            const base = [_]common.Case{
                .{ .name = tag ++ ".init", .namespace = "geometry", .invoke = init },
                .{ .name = tag ++ ".init.poisoned", .namespace = "geometry", .invoke = initPoisoned },
                .{ .name = tag ++ ".fromArray", .namespace = "geometry", .invoke = fromArray },
                .{ .name = tag ++ ".toArray", .namespace = "geometry", .invoke = toArray },
                .{ .name = tag ++ ".add", .namespace = "geometry", .invoke = add },
                .{ .name = tag ++ ".sub", .namespace = "geometry", .invoke = sub },
                .{ .name = tag ++ ".toVector", .namespace = "geometry", .invoke = toVector },
                .{ .name = tag ++ ".isFinite", .namespace = "geometry", .invoke = isFinite },
                .{ .name = tag ++ ".eq", .namespace = "geometry", .invoke = eq },
            };
            for (base) |entry| {
                list[slot] = entry;
                slot += 1;
            }
            inline for (.{
                .{ "policy.fast", g.PredicatePolicy.fast, 32 },
                .{ "policy.adaptive_exact", g.PredicatePolicy.adaptive_exact, 8 },
            }) |row| {
                const policy_name = row[0];
                const policy: g.PredicatePolicy = row[1];
                const calls: u32 = row[2];
                inline for (.{
                    .{ "ordinary", Regime.ordinary },
                    .{ "near_degenerate", Regime.near_degenerate },
                    .{ "exponent_extreme", Regime.exponent_extreme },
                }) |regime_row| {
                    const regime: Regime = regime_row[1];
                    list[slot] = .{
                        .name = tag ++ ".orientation." ++ policy_name ++ "." ++ regime_row[0],
                        .namespace = "geometry",
                        .invoke = Bound(@This(), "run", .{ .policy = policy, .regime = regime }).run,
                        .calls = calls,
                    };
                    slot += 1;
                }
            }
            if (comptime dim == 4) {
                list[slot] = .{
                    .name = tag ++ ".orientation.policy.fast.near_dependent",
                    .namespace = "geometry",
                    .invoke = Bound(@This(), "runDependent", g.PredicatePolicy.fast).run,
                    .calls = 8,
                };
                slot += 1;
                list[slot] = .{
                    .name = tag ++ ".orientation.policy.adaptive_exact.near_dependent",
                    .namespace = "geometry",
                    .invoke = Bound(@This(), "runDependent", g.PredicatePolicy.adaptive_exact).run,
                    .calls = 8,
                };
                slot += 1;
                list[slot] = .{
                    .name = tag ++ ".orientation.policy.fast.perturbed_ulp",
                    .namespace = "geometry",
                    .invoke = Bound(@This(), "runPerturbed", g.PredicatePolicy.fast).run,
                    .calls = 8,
                };
                slot += 1;
                list[slot] = .{
                    .name = tag ++ ".orientation.policy.adaptive_exact.perturbed_ulp",
                    .namespace = "geometry",
                    .invoke = Bound(@This(), "runPerturbed", g.PredicatePolicy.adaptive_exact).run,
                    .calls = 8,
                };
                slot += 1;
            }
            if (comptime dim == 3) {
                list[slot] = .{
                    .name = tag ++ ".orientation.policy.fast.perturbed_ulp",
                    .namespace = "geometry",
                    .invoke = Bound(@This(), "runPerturbed", g.PredicatePolicy.fast).run,
                    .calls = 8,
                };
                slot += 1;
                list[slot] = .{
                    .name = tag ++ ".orientation.policy.adaptive_exact.perturbed_ulp",
                    .namespace = "geometry",
                    .invoke = Bound(@This(), "runPerturbed", g.PredicatePolicy.adaptive_exact).run,
                    .calls = 8,
                };
                slot += 1;
            }
            if (comptime dim == 2) {
                list[slot] = .{
                    .name = tag ++ ".side.policy.fast.ordinary",
                    .namespace = "geometry",
                    .invoke = Bound(@This(), "runSide", .{ .policy = .fast, .tied = false }).run,
                    .calls = 32,
                };
                slot += 1;
                list[slot] = .{
                    .name = tag ++ ".side.policy.adaptive_exact.near_degenerate",
                    .namespace = "geometry",
                    .invoke = Bound(@This(), "runSide", .{ .policy = .adaptive_exact, .tied = true }).run,
                    .calls = 8,
                };
                slot += 1;
            }
            return list;
        }

        const count = 9 + 6 +
            @as(usize, @intFromBool(dim == 4)) * 4 +
            @as(usize, @intFromBool(dim == 3)) * 2 +
            @as(usize, @intFromBool(dim == 2)) * 2;
    };
}
// ---------------------------------------------------------------------------
// Line2 / Line3 / Line4
// ---------------------------------------------------------------------------

fn LineOps(comptime L: type, comptime P: type, comptime V: type) type {
    return struct {
        const T = elementOf(P);
        const dim = componentCount(P);
        const tag = @typeName(L);

        noinline fn init(index: usize) u64 {
            var source = Source.begin(index);
            const regime = regimeOf(index);
            const line = L.init(
                build(P, regimeCoords(P, &source, regime)),
                build(V, regimeCoords(V, &source, regime)),
            );
            return outcome(index, line);
        }

        noinline fn initDegenerate(index: usize) u64 {
            // The refusal path: a zero direction has no unit form.
            return outcome(index, L.init(build(P, zeros(dim)), build(V, zeros(dim))));
        }

        /// The subnormal scaled normalization: a direction whose norm is below
        /// `floatMin(T)` cannot be normalized by dividing through that norm,
        /// because the division would round the component ratios away, so the
        /// source divides through the largest component and folds the norm of
        /// the rescaled vector instead. `init` and `init.degenerate` never
        /// enter that branch.
        noinline fn initSubnormal(index: usize) u64 {
            var source = Source.begin(index);
            const origin = build(P, regimeCoords(P, &source, .ordinary));
            const direction = build(V, subnormalCoords(V, &source));
            return outcome(index, L.init(origin, direction));
        }

        /// The receiver the `at`, `closestPointTo` and `isFinite` rows measure,
        /// built as a STORED value rather than through `init`.
        ///
        /// `Line`'s fields are public and writable, and the only invariant
        /// `init` establishes is that the origin is finite and the direction is
        /// unit. A stored line that already satisfies both is exactly what
        /// `init` would have returned, so building it as a literal keeps
        /// `vectorNormalize` out of these rows and leaves them measuring `at`,
        /// `closestPointTo` and `isFinite` and nothing else. Nothing is
        /// narrowed: the regime still reaches the receiver through the origin,
        /// and it reaches the argument through the point and the parameter.
        fn storedLine(index: usize, regime: Regime) L {
            var source = Source.begin(index);
            const which = source.next() & 1;
            return .{
                .origin = build(P, regimeCoords(P, &source, regime)),
                .direction = build(V, unitAxis(dim, which)),
            };
        }

        noinline fn at(index: usize) u64 {
            var source = Source.begin(index);
            const regime = regimeOf(index);
            const line = storedLine(index, regime);
            return outcome(index, line.at(@floatCast(source.span(4.0))));
        }

        noinline fn atNegative(index: usize) u64 {
            // A line is two-sided, so a negative parameter is a point behind
            // the origin and not a failure.
            var source = Source.begin(index);
            const line = storedLine(index, regimeOf(index));
            return outcome(index, line.at(@floatCast(source.span(4.0) - 8.0)));
        }

        noinline fn closestPointTo(index: usize) u64 {
            var source = Source.begin(index);
            const regime = regimeOf(index);
            const line = storedLine(index, regime);
            const target = build(P, regimeCoords(P, &source, regime));
            return outcome(index, line.closestPointTo(target));
        }

        noinline fn isFinite(index: usize) u64 {
            const line = storedLine(index, regimeOf(index));
            const poisoned = L{
                .origin = poisonedValue(P, T),
                .direction = build(V, @as([dim]f64, @splat(1.0))),
            };
            return digest(index, .{ line.isFinite(), poisoned.isFinite() });
        }

        noinline fn run(index: usize, comptime arg: struct { shape: Shape, policy: g.PredicatePolicy }) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const first = affineFixture(dim, scale, arg.shape, 0);
            const second = affineFixture(dim, scale, arg.shape, 1);
            const a = L.init(build(P, first.start), build(V, first.finish)) catch unreachable;
            const b = L.init(build(P, second.start), build(V, second.finish)) catch unreachable;
            return outcome(index, a.intersect(b, arg.policy));
        }

        fn cases() [17]common.Case {
            var list: [17]common.Case = undefined;
            var slot: usize = 0;
            const base = [_]common.Case{
                .{
                    .name = tag ++ ".init",
                    .namespace = "geometry",
                    .invoke = init,
                    .f32 = normalizeOf(T, dim),
                },
                .{
                    .name = tag ++ ".init.degenerate",
                    .namespace = "geometry",
                    .invoke = initDegenerate,
                    .f32 = lengthOf(T, dim),
                },
                .{
                    .name = tag ++ ".init.subnormal_direction",
                    .namespace = "geometry",
                    .invoke = initSubnormal,
                    .f32 = normalizeOf(T, dim),
                },
                // The four rows below build their receiver as a stored
                // literal, so they measure the method alone and carry no
                // charge. `Line.at` and `Line.closestPointTo` are plain
                // arithmetic; `isFinite` is two comparisons.
                .{ .name = tag ++ ".at", .namespace = "geometry", .invoke = at },
                .{ .name = tag ++ ".at.negative_parameter", .namespace = "geometry", .invoke = atNegative },
                .{ .name = tag ++ ".closestPointTo", .namespace = "geometry", .invoke = closestPointTo },
                .{ .name = tag ++ ".isFinite", .namespace = "geometry", .invoke = isFinite },
            };
            for (base) |entry| {
                list[slot] = entry;
                slot += 1;
            }
            inline for (.{
                .{ "policy.fast", g.PredicatePolicy.fast, 16 },
                .{ "policy.adaptive_exact", g.PredicatePolicy.adaptive_exact, 8 },
            }) |policy_row| {
                inline for (.{
                    .{ "crossing", Shape.crossing },
                    .{ "crossing_offset", Shape.crossing_offset },
                    .{ "collinear", Shape.collinear },
                    .{ "parallel_disjoint", Shape.parallel_disjoint },
                    .{ "coincident", Shape.coincident },
                }) |shape_row| {
                    list[slot] = .{
                        // Both lines are built through `init` inside the timed
                        // body, so this row measures two normalizations plus
                        // the intersection, not the intersection alone.
                        .name = tag ++ ".intersect." ++ policy_row[0] ++ "." ++ shape_row[0] ++ ".normalized_operands",
                        .namespace = "geometry",
                        .invoke = Bound(@This(), "run", .{ .shape = shape_row[1], .policy = policy_row[1] }).run,
                        .calls = policy_row[2],
                        .f32 = affineCaseOf(T, dim, 2),
                    };
                    slot += 1;
                }
            }
            return list;
        }
    };
}

// ---------------------------------------------------------------------------
// Ray2 / Ray3 / Ray4
// ---------------------------------------------------------------------------

fn RayOps(
    comptime R: type,
    comptime P: type,
    comptime V: type,
    comptime L: type,
    comptime S: type,
) type {
    return struct {
        const T = elementOf(P);
        const dim = componentCount(P);
        const tag = @typeName(R);

        noinline fn init(index: usize) u64 {
            var source = Source.begin(index);
            const regime = regimeOf(index);
            const ray = R.init(
                build(P, regimeCoords(P, &source, regime)),
                build(V, regimeCoords(V, &source, regime)),
            );
            return outcome(index, ray);
        }

        noinline fn initDegenerate(index: usize) u64 {
            return outcome(index, R.init(build(P, zeros(dim)), build(V, zeros(dim))));
        }

        noinline fn initSubnormal(index: usize) u64 {
            // The subnormal scaled normalization, reached through the ray's
            // own constructor: a direction whose norm is below `floatMin(T)`.
            var source = Source.begin(index);
            const origin = build(P, regimeCoords(P, &source, .ordinary));
            const direction = build(V, subnormalCoords(V, &source));
            return outcome(index, R.init(origin, direction));
        }

        /// The receiver the `at`, `at.clamped` and `isFinite` rows measure,
        /// built as a STORED value rather than through `init`, for the same
        /// reason `LineOps.storedLine` is: a ray's only constructor invariant
        /// is a finite origin and a unit direction, so a literal that already
        /// satisfies both is exactly what `init` would have returned, and
        /// `vectorNormalize` stays out of these rows. The regime still reaches
        /// the receiver through the origin and the argument through the
        /// parameter.
        fn storedRay(index: usize, regime: Regime) R {
            var source = Source.begin(index);
            const which = source.next() & 1;
            return .{
                .origin = build(P, regimeCoords(P, &source, regime)),
                .direction = build(V, unitAxis(dim, which)),
            };
        }

        noinline fn at(index: usize) u64 {
            var source = Source.begin(index);
            const ray = storedRay(index, regimeOf(index));
            return outcome(index, ray.at(@floatCast(source.span(4.0))));
        }

        noinline fn atNegative(index: usize) u64 {
            // A ray clamps at its end, so a nonpositive parameter answers that
            // end rather than a point behind it.
            var source = Source.begin(index);
            const ray = storedRay(index, regimeOf(index));
            return outcome(index, ray.at(@floatCast(source.span(4.0) - 8.0)));
        }

        noinline fn isFinite(index: usize) u64 {
            const ray = storedRay(index, regimeOf(index));
            const poisoned = R{
                .origin = poisonedValue(P, T),
                .direction = build(V, @as([dim]f64, @splat(1.0))),
            };
            return digest(index, .{ ray.isFinite(), poisoned.isFinite() });
        }

        noinline fn runRay(index: usize, comptime arg: struct { shape: Shape, policy: g.PredicatePolicy }) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const first = affineFixture(dim, scale, arg.shape, 0);
            const second = affineFixture(dim, scale, arg.shape, 1);
            const a = R.init(build(P, first.start), build(V, first.finish)) catch unreachable;
            const b = R.init(build(P, second.start), build(V, second.finish)) catch unreachable;
            return outcome(index, a.intersect(b, arg.policy));
        }

        noinline fn runLine(index: usize, comptime arg: struct { shape: Shape, policy: g.PredicatePolicy }) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const first = affineFixture(dim, scale, arg.shape, 0);
            const second = affineFixture(dim, scale, arg.shape, 1);
            const ray = R.init(build(P, first.start), build(V, first.finish)) catch unreachable;
            const line = L.init(build(P, second.start), build(V, second.finish)) catch unreachable;
            return outcome(index, ray.intersectLine(line, arg.policy));
        }

        noinline fn runSegment(index: usize, comptime arg: struct { shape: Shape, policy: g.PredicatePolicy }) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const first = affineFixture(dim, scale, arg.shape, 0);
            const second = affineFixture(dim, scale, arg.shape, 1);
            const ray = R.init(build(P, first.start), build(V, first.finish)) catch unreachable;
            const segment = S.init(build(P, second.start), build(P, second.finish)) catch unreachable;
            return outcome(index, ray.intersectSegment(segment, arg.policy));
        }

        fn cases() [22]common.Case {
            var list: [22]common.Case = undefined;
            var slot: usize = 0;
            const base = [_]common.Case{
                .{
                    .name = tag ++ ".init",
                    .namespace = "geometry",
                    .invoke = init,
                    .f32 = normalizeOf(T, dim),
                },
                .{
                    .name = tag ++ ".init.degenerate",
                    .namespace = "geometry",
                    .invoke = initDegenerate,
                    .f32 = lengthOf(T, dim),
                },
                .{
                    .name = tag ++ ".init.subnormal_direction",
                    .namespace = "geometry",
                    .invoke = initSubnormal,
                    .f32 = normalizeOf(T, dim),
                },
                // The three rows below build their receiver as a stored
                // literal, so they measure the method alone and carry no
                // charge. `Ray.at` is plain arithmetic; `isFinite` is two
                // comparisons.
                .{ .name = tag ++ ".at", .namespace = "geometry", .invoke = at },
                .{ .name = tag ++ ".at.clamped", .namespace = "geometry", .invoke = atNegative },
                .{ .name = tag ++ ".isFinite", .namespace = "geometry", .invoke = isFinite },
            };
            for (base) |entry| {
                list[slot] = entry;
                slot += 1;
            }
            inline for (.{
                .{ "policy.fast", g.PredicatePolicy.fast, 16 },
                .{ "policy.adaptive_exact", g.PredicatePolicy.adaptive_exact, 8 },
            }) |policy_row| {
                inline for (.{
                    .{ "crossing", Shape.crossing },
                    .{ "collinear", Shape.collinear },
                    .{ "parallel_disjoint", Shape.parallel_disjoint },
                    .{ "coincident", Shape.coincident },
                }) |shape_row| {
                    list[slot] = .{
                        // Both operands are built through `init` inside the
                        // timed body, so this row measures two normalizations
                        // plus the intersection, not the intersection alone.
                        .name = tag ++ ".intersect." ++ policy_row[0] ++ "." ++ shape_row[0] ++ ".normalized_operands",
                        .namespace = "geometry",
                        .invoke = Bound(@This(), "runRay", .{ .shape = shape_row[1], .policy = policy_row[1] }).run,
                        .calls = policy_row[2],
                        .f32 = affineCaseOf(T, dim, 2),
                    };
                    slot += 1;
                }
                inline for (.{
                    .{ "contained", Shape.contained },
                    .{ "crossing_offset", Shape.crossing_offset },
                }) |shape_row| {
                    list[slot] = .{
                        // A ray and a line are both built through `init`.
                        .name = tag ++ ".intersectLine." ++ policy_row[0] ++ "." ++ shape_row[0] ++ ".normalized_operands",
                        .namespace = "geometry",
                        .invoke = Bound(@This(), "runLine", .{ .shape = shape_row[1], .policy = policy_row[1] }).run,
                        .calls = policy_row[2],
                        .f32 = affineCaseOf(T, dim, 2),
                    };
                    slot += 1;
                    list[slot] = .{
                        // The ray is built through `init`; the segment is not.
                        .name = tag ++ ".intersectSegment." ++ policy_row[0] ++ "." ++ shape_row[0] ++ ".normalized_operands",
                        .namespace = "geometry",
                        .invoke = Bound(@This(), "runSegment", .{ .shape = shape_row[1], .policy = policy_row[1] }).run,
                        .calls = policy_row[2],
                        .f32 = affineCaseOf(T, dim, 1),
                    };
                    slot += 1;
                }
            }
            return list;
        }
    };
}

// ---------------------------------------------------------------------------
// Segment2 / Segment3 / Segment4
// ---------------------------------------------------------------------------

fn SegmentOps(
    comptime S: type,
    comptime P: type,
    comptime V: type,
    comptime R: type,
    comptime L: type,
) type {
    return struct {
        const T = elementOf(P);
        const dim = componentCount(P);
        const tag = @typeName(S);

        noinline fn init(index: usize) u64 {
            var source = Source.begin(index);
            const regime = regimeOf(index);
            const segment = S.init(
                build(P, regimeCoords(P, &source, regime)),
                build(P, regimeCoords(P, &source, regime)),
            );
            return outcome(index, segment);
        }

        noinline fn initCoincident(index: usize) u64 {
            // The ends may coincide, which is the legal degenerate segment.
            var source = Source.begin(index);
            const at_point = build(P, regimeCoords(P, &source, regimeOf(index)));
            return outcome(index, S.init(at_point, at_point));
        }

        noinline fn initPoisoned(index: usize) u64 {
            const at_point = poisonedValue(P, T);
            return outcome(index, S.init(at_point, build(P, zeros(dim))));
        }

        noinline fn at(index: usize) u64 {
            var source = Source.begin(index);
            const regime = regimeOf(index);
            const segment = S.init(
                build(P, regimeCoords(P, &source, regime)),
                build(P, regimeCoords(P, &source, regime)),
            ) catch unreachable;
            return outcome(index, segment.at(@floatCast(source.span(4.0))));
        }

        noinline fn atClamped(index: usize) u64 {
            // A segment clamps to [0, 1], so both ends answer that end.
            var source = Source.begin(index);
            const regime = regimeOf(index);
            const segment = S.init(
                build(P, regimeCoords(P, &source, regime)),
                build(P, regimeCoords(P, &source, regime)),
            ) catch unreachable;
            const beyond: T = @floatCast(8.0 + source.unit());
            return outcomes(index, 2, .{ segment.at(-beyond), segment.at(beyond) });
        }

        noinline fn length(index: usize) u64 {
            var source = Source.begin(index);
            const regime = regimeOf(index);
            const segment = S.init(
                build(P, regimeCoords(P, &source, regime)),
                build(P, regimeCoords(P, &source, regime)),
            ) catch unreachable;
            return outcome(index, segment.length());
        }

        noinline fn closestPointTo(index: usize) u64 {
            var source = Source.begin(index);
            const regime = regimeOf(index);
            const segment = S.init(
                build(P, regimeCoords(P, &source, regime)),
                build(P, regimeCoords(P, &source, regime)),
            ) catch unreachable;
            const target = build(P, regimeCoords(P, &source, regime));
            return outcome(index, segment.closestPointTo(target));
        }

        noinline fn closestPointToDegenerate(index: usize) u64 {
            // A degenerate segment answers its own single point.
            var source = Source.begin(index);
            const regime = regimeOf(index);
            const at_point = build(P, regimeCoords(P, &source, regime));
            const segment = S.init(at_point, at_point) catch unreachable;
            const target = build(P, regimeCoords(P, &source, regime));
            return outcome(index, segment.closestPointTo(target));
        }

        noinline fn isFinite(index: usize) u64 {
            var source = Source.begin(index);
            const regime = regimeOf(index);
            const segment = S.init(
                build(P, regimeCoords(P, &source, regime)),
                build(P, regimeCoords(P, &source, regime)),
            ) catch unreachable;
            const poisoned = S{
                .a = poisonedValue(P, T),
                .b = build(P, zeros(dim)),
            };
            return digest(index, .{ segment.isFinite(), poisoned.isFinite() });
        }

        noinline fn runSegment(index: usize, comptime arg: struct { shape: Shape, policy: g.PredicatePolicy }) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const first = affineFixture(dim, scale, arg.shape, 0);
            const second = affineFixture(dim, scale, arg.shape, 1);
            const a = S.init(build(P, first.start), build(P, first.finish)) catch unreachable;
            const b = S.init(build(P, second.start), build(P, second.finish)) catch unreachable;
            return outcome(index, a.intersect(b, arg.policy));
        }

        /// Two collinear segments whose common span is subnormal.
        ///
        /// In three and four dimensions the affine engine normalizes
        /// `a_finish - a_start` before it builds the frame, and that span's
        /// norm is below `floatMin(T)`, so this is the route that reaches the
        /// subnormal branch of `arrayNormalizedChecked` through the affine
        /// engine rather than through a constructor. Two dimensions build no
        /// frame at all, so there the same subnormal span is still the
        /// degenerate-magnitude case, just one the engine answers without
        /// normalizing.
        noinline fn runSubnormalSpan(index: usize, comptime policy: g.PredicatePolicy) u64 {
            var source = Source.begin(index);
            // An exact power-of-two multiple of the subnormal band, capped at
            // one so the span can never climb back above `floatMin(T)`.
            const unit = subnormalSpread(T) * @min(source.scale(), 1.0);
            const a = S.init(build(P, zeros(dim)), build(P, axis(dim, 0, 3.0 * unit))) catch unreachable;
            const b = S.init(build(P, axis(dim, 0, unit)), build(P, axis(dim, 0, 2.0 * unit))) catch unreachable;
            return outcome(index, a.intersect(b, policy));
        }

        noinline fn runRay(index: usize, comptime arg: struct { shape: Shape, policy: g.PredicatePolicy }) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const first = affineFixture(dim, scale, arg.shape, 0);
            const second = affineFixture(dim, scale, arg.shape, 1);
            const segment = S.init(build(P, first.start), build(P, first.finish)) catch unreachable;
            const ray = R.init(build(P, second.start), build(V, second.finish)) catch unreachable;
            return outcome(index, segment.intersectRay(ray, arg.policy));
        }

        noinline fn runLine(index: usize, comptime arg: struct { shape: Shape, policy: g.PredicatePolicy }) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const first = affineFixture(dim, scale, arg.shape, 0);
            const second = affineFixture(dim, scale, arg.shape, 1);
            const segment = S.init(build(P, first.start), build(P, first.finish)) catch unreachable;
            const line = L.init(build(P, second.start), build(V, second.finish)) catch unreachable;
            return outcome(index, segment.intersectLine(line, arg.policy));
        }

        fn cases() [35]common.Case {
            var list: [35]common.Case = undefined;
            var slot: usize = 0;
            const base = [_]common.Case{
                .{ .name = tag ++ ".init", .namespace = "geometry", .invoke = init },
                .{ .name = tag ++ ".init.coincident_ends", .namespace = "geometry", .invoke = initCoincident },
                .{ .name = tag ++ ".init.poisoned", .namespace = "geometry", .invoke = initPoisoned },
                .{ .name = tag ++ ".at", .namespace = "geometry", .invoke = at },
                .{ .name = tag ++ ".at.clamped", .namespace = "geometry", .invoke = atClamped },
                .{
                    .name = tag ++ ".length",
                    .namespace = "geometry",
                    .invoke = length,
                    .f32 = lengthOf(T, dim),
                },
                .{ .name = tag ++ ".closestPointTo", .namespace = "geometry", .invoke = closestPointTo },
                .{
                    .name = tag ++ ".closestPointTo.degenerate",
                    .namespace = "geometry",
                    .invoke = closestPointToDegenerate,
                },
                .{ .name = tag ++ ".isFinite", .namespace = "geometry", .invoke = isFinite },
            };
            for (base) |entry| {
                list[slot] = entry;
                slot += 1;
            }
            inline for (.{
                .{ "policy.fast", g.PredicatePolicy.fast, 16 },
                .{ "policy.adaptive_exact", g.PredicatePolicy.adaptive_exact, 8 },
            }) |policy_row| {
                inline for (.{
                    .{ "crossing", Shape.crossing },
                    .{ "crossing_offset", Shape.crossing_offset },
                    .{ "collinear", Shape.collinear },
                    .{ "parallel_disjoint", Shape.parallel_disjoint },
                    .{ "coincident", Shape.coincident },
                    .{ "contained", Shape.contained },
                    .{ "degenerate_on", Shape.degenerate_on },
                    .{ "degenerate_off", Shape.degenerate_off },
                }) |shape_row| {
                    list[slot] = .{
                        // Two segments reach no accepted kernel to build, so
                        // this row measures `intersect` alone.
                        .name = tag ++ ".intersect." ++ policy_row[0] ++ "." ++ shape_row[0],
                        .namespace = "geometry",
                        .invoke = Bound(@This(), "runSegment", .{ .shape = shape_row[1], .policy = policy_row[1] }).run,
                        .calls = policy_row[2],
                        .f32 = affineOf(T, dim),
                    };
                    slot += 1;
                }
                list[slot] = .{
                    // Two segments again: the subnormal span costs nothing to
                    // build, so this row measures `intersect` alone.
                    .name = tag ++ ".intersect." ++ policy_row[0] ++ ".subnormal_span",
                    .namespace = "geometry",
                    .invoke = Bound(@This(), "runSubnormalSpan", policy_row[1]).run,
                    .calls = policy_row[2],
                    .f32 = affineOf(T, dim),
                };
                slot += 1;
                inline for (.{
                    .{ "contained", Shape.contained },
                    .{ "crossing_offset", Shape.crossing_offset },
                }) |shape_row| {
                    list[slot] = .{
                        // The ray is built through `init` inside the timed body.
                        .name = tag ++ ".intersectRay." ++ policy_row[0] ++ "." ++ shape_row[0] ++ ".normalized_operands",
                        .namespace = "geometry",
                        .invoke = Bound(@This(), "runRay", .{ .shape = shape_row[1], .policy = policy_row[1] }).run,
                        .calls = policy_row[2],
                        .f32 = affineCaseOf(T, dim, 1),
                    };
                    slot += 1;
                    list[slot] = .{
                        // The line is built through `init` inside the timed body.
                        .name = tag ++ ".intersectLine." ++ policy_row[0] ++ "." ++ shape_row[0] ++ ".normalized_operands",
                        .namespace = "geometry",
                        .invoke = Bound(@This(), "runLine", .{ .shape = shape_row[1], .policy = policy_row[1] }).run,
                        .calls = policy_row[2],
                        .f32 = affineCaseOf(T, dim, 1),
                    };
                    slot += 1;
                }
            }
            return list;
        }
    };
}

// ---------------------------------------------------------------------------
// Circle2 / Sphere3 / Hypersphere4
//
// The fixtures use a power-of-two scale and exact multiples of it, so the
// separation between two centres is exact and the tag each case name states
// is the tag the engine returns.
// ---------------------------------------------------------------------------

const BallPair = enum {
    /// Separated by less than the sum and more than the difference.
    crossing,
    /// Separated by exactly the sum: one tangent point.
    tangent,
    /// Separated by less than the difference.
    contained,
    /// Separated by more than the sum.
    disjoint,
    /// Same centre and same radius.
    coincident,
};

const Placement = enum { inside, boundary, outside };

const BallSegmentShape = enum {
    /// Both ends outside, crossing through the ball.
    crossing,
    /// Both ends inside: the segment is the whole common set.
    contained,
    /// Both ends outside, reaching the surface exactly once: a touch.
    tangent,
};

const RayBallShape = enum {
    /// Origin outside, chord entirely ahead of it.
    crossing_outside,
    /// Origin inside: the run from the origin to the exit.
    origin_inside,
    /// Origin outside and tangent: one point.
    tangent,
};

fn BallOps(
    comptime B: type,
    comptime P: type,
    comptime S: type,
    comptime R: type,
) type {
    return struct {
        const T = elementOf(P);
        const dim = componentCount(P);
        const tag = @typeName(B);

        /// A stored ball whose centre is `offset * scale` on the first axis
        /// and whose radius is `radius_factor * scale`.
        ///
        /// The scale is the CALLER'S. Every operand of a named arrangement —
        /// both balls, every probe point, every segment end, every ray origin
        /// — is one exact power-of-two multiple of that one value, so the
        /// separation the engine reads is the separation the case name states.
        /// A helper that drew a scale of its own would place the ball against
        /// a different scale than the probe, and a case named `outside` would
        /// be measuring a point inside.
        ///
        /// `ballBuild` gates the centre and the radius and compares, so a
        /// literal with a finite centre and a nonnegative radius is exactly
        /// what `init` would have returned and costs nothing.
        fn ball(scale: f64, offset: f64, radius_factor: f64) B {
            return .{
                .center = build(P, axis(dim, 0, offset * scale)),
                .radius = @floatCast(radius_factor * scale),
            };
        }

        /// The point a `Placement` names, against a ball centred at the
        /// origin whose radius is ONE `scale`: half that scale inside, the
        /// scale itself on the boundary, twice it outside.
        fn probe(scale: f64, placement: Placement) P {
            const reach: f64 = switch (placement) {
                Placement.inside => 0.5,
                Placement.boundary => 1.0,
                Placement.outside => 2.0,
            };
            return build(P, axis(dim, 0, reach * scale));
        }

        /// The second ball a `BallPair` names, as factors of the SAME scale
        /// the receiver's radius is a factor of. The separation between the
        /// centres is therefore exactly `offset * scale` and the two radii
        /// exactly `radius * scale` against it, so each shape is the one its
        /// name states: crossing and contained need separation strictly inside
        /// the sum, tangent is the sum itself, disjoint is outside it, and
        /// coincident is no separation at all with equal radii.
        fn pairOf(comptime shape: BallPair) struct { offset: f64, radius: f64 } {
            return switch (shape) {
                BallPair.crossing => .{ .offset = 1.5, .radius = 1.0 },
                BallPair.tangent => .{ .offset = 2.0, .radius = 1.0 },
                BallPair.contained => .{ .offset = 0.25, .radius = 0.5 },
                BallPair.disjoint => .{ .offset = 4.0, .radius = 1.0 },
                BallPair.coincident => .{ .offset = 0.0, .radius = 1.0 },
            };
        }

        noinline fn init(index: usize) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const center = build(P, timesAll(dim, regimeCoords(P, &source, regimeOf(index)), scale));
            const radius = source.magnitude(3.0);
            return outcome(index, B.init(center, @floatCast(radius)));
        }

        noinline fn initNegative(index: usize) u64 {
            // The refusal path: a negative radius is decided at construction.
            var source = Source.begin(index);
            return outcome(index, B.init(build(P, zeros(dim)), @floatCast(-source.magnitude(2.0))));
        }

        noinline fn initZero(index: usize) u64 {
            // A zero radius is legal and names the single centre.
            var source = Source.begin(index);
            const center = build(P, regimeCoords(P, &source, regimeOf(index)));
            return outcome(index, B.init(center, @as(T, 0)));
        }

        noinline fn isFinite(index: usize) u64 {
            var source = Source.begin(index);
            const held = ball(source.scale(), 0.0, 1.0);
            const poisoned = B{
                .center = poisonedValue(P, T),
                .radius = @as(T, 1),
            };
            return digest(index, .{ held.isFinite(), poisoned.isFinite() });
        }

        noinline fn runContains(index: usize, comptime arg: struct { placement: Placement, policy: g.PredicatePolicy }) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            return outcome(index, ball(scale, 0.0, 1.0).contains(probe(scale, arg.placement), arg.policy));
        }

        noinline fn runPair(index: usize, comptime arg: struct { shape: BallPair, policy: g.PredicatePolicy }) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const spec = pairOf(arg.shape);
            const first = ball(scale, 0.0, 1.0);
            const second = ball(scale, spec.offset, spec.radius);
            return outcome(index, first.intersect(second, arg.policy));
        }

        /// Two balls whose centres are separated by a subnormal distance that
        /// is exactly the sum of their radii.
        ///
        /// That is the tangency branch, and tangency is the one place
        /// `Ball.intersect` normalizes the separation itself — so this is where
        /// `arrayNormalizedChecked` takes its subnormal branch, with the
        /// separation's own norm below `floatMin(T)`. Every `BallPair` row
        /// above reaches the same branch with a normal separation, or skips it
        /// for the crossing and coincident answers.
        ///
        /// ONE `unit` is both radii and the whole separation, so no operand of
        /// this row can drift onto a second scale.
        fn subnormalPair(unit: T) struct { first: B, second: B } {
            return .{
                .first = .{ .center = build(P, zeros(dim)), .radius = unit },
                .second = .{ .center = build(P, axis(dim, 0, 2.0 * unit)), .radius = unit },
            };
        }

        noinline fn runSubnormalTangency(index: usize, comptime policy: g.PredicatePolicy) u64 {
            var source = Source.begin(index);
            // An exact power-of-two multiple of the subnormal band, capped at
            // one so twice the radius stays a quarter of `floatMin(T)`.
            const pair = subnormalPair(@floatCast(subnormalSpread(T) * @min(source.scale(), 1.0)));
            return outcome(index, pair.first.intersect(pair.second, policy));
        }

        /// The segment a `BallSegmentShape` names, against a ball centred at
        /// the origin whose radius is ONE `scale`. Every end is an exact
        /// multiple of that same scale, so the crossing run really crosses,
        /// the contained run really lies inside, and the touching run really
        /// stands one radius off the centre.
        fn segmentOf(scale: f64, comptime shape: BallSegmentShape) S {
            return switch (shape) {
                // Both ends outside, running straight through the ball.
                BallSegmentShape.crossing => S.init(
                    build(P, axis(dim, 0, -2.0 * scale)),
                    build(P, axis(dim, 0, 2.0 * scale)),
                ) catch unreachable,
                // Both ends inside, so the convex ball holds the whole segment.
                BallSegmentShape.contained => S.init(
                    build(P, axis(dim, 0, 0.25 * scale)),
                    build(P, axis(dim, 0, 0.5 * scale)),
                ) catch unreachable,
                // A run whose closest approach to the centre is exactly the
                // radius, with that closest point inside the run: a double
                // root, which is the module's stated definition of a touch.
                BallSegmentShape.tangent => S.init(
                    build(P, plus(dim, axis(dim, 0, scale), axis(dim, 1, -scale))),
                    build(P, plus(dim, axis(dim, 0, scale), axis(dim, 1, scale))),
                ) catch unreachable,
            };
        }

        noinline fn runSegment(index: usize, comptime arg: struct { shape: BallSegmentShape, policy: g.PredicatePolicy }) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            return outcome(index, ball(scale, 0.0, 1.0).intersectSegment(segmentOf(scale, arg.shape), arg.policy));
        }

        /// The ray a `RayBallShape` names, against a ball centred at the origin
        /// whose radius is ONE `scale`.
        ///
        /// Every shape runs along the first axis, so `init` would normalize
        /// `axis0(scale)` to the unit first axis. Writing that directly makes
        /// the ray a stored literal and keeps `vectorNormalize` out of this
        /// row, while the origin stays an exact multiple of the one scale the
        /// radius is a multiple of.
        fn rayOf(scale: f64, comptime shape: RayBallShape) R {
            const origin = switch (shape) {
                // The chord lies wholly ahead of the origin.
                RayBallShape.crossing_outside => axis(dim, 0, -2.0 * scale),
                // The origin is inside, so the common run starts there.
                RayBallShape.origin_inside => zeros(dim),
                // The supporting line stands one radius off the centre, and
                // the origin is the tangency point itself.
                RayBallShape.tangent => axis(dim, 1, -scale),
            };
            return .{
                .origin = build(P, origin),
                .direction = build(P, unitAxis(dim, 0)).toVector(),
            };
        }

        noinline fn runRay(index: usize, comptime arg: struct { shape: RayBallShape, policy: g.PredicatePolicy }) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            return outcome(index, ball(scale, 0.0, 1.0).intersectRay(rayOf(scale, arg.shape), arg.policy));
        }

        fn cases() [count]common.Case {
            var list: [count]common.Case = undefined;
            var slot: usize = 0;
            const base = [_]common.Case{
                .{ .name = tag ++ ".init", .namespace = "geometry", .invoke = init },
                .{ .name = tag ++ ".init.negative_radius", .namespace = "geometry", .invoke = initNegative },
                .{ .name = tag ++ ".init.zero_radius", .namespace = "geometry", .invoke = initZero },
                .{ .name = tag ++ ".isFinite", .namespace = "geometry", .invoke = isFinite },
            };
            for (base) |entry| {
                list[slot] = entry;
                slot += 1;
            }
            inline for (.{
                .{ "policy.fast", g.PredicatePolicy.fast, 16 },
                .{ "policy.adaptive_exact", g.PredicatePolicy.adaptive_exact, 8 },
            }) |policy_row| {
                inline for (.{
                    .{ "inside", Placement.inside },
                    .{ "boundary", Placement.boundary },
                    .{ "outside", Placement.outside },
                }) |placement_row| {
                    list[slot] = .{
                        .name = tag ++ ".contains." ++ policy_row[0] ++ "." ++ placement_row[0],
                        .namespace = "geometry",
                        .invoke = Bound(@This(), "runContains", .{ .placement = placement_row[1], .policy = policy_row[1] }).run,
                        .calls = policy_row[2],
                    };
                    slot += 1;
                }
                inline for (.{
                    .{ "crossing", BallPair.crossing },
                    .{ "tangent", BallPair.tangent },
                    .{ "contained", BallPair.contained },
                    .{ "disjoint", BallPair.disjoint },
                    .{ "coincident", BallPair.coincident },
                }) |shape_row| {
                    list[slot] = .{
                        .name = tag ++ ".intersect." ++ policy_row[0] ++ "." ++ shape_row[0],
                        .namespace = "geometry",
                        .invoke = Bound(@This(), "runPair", .{ .shape = shape_row[1], .policy = policy_row[1] }).run,
                        .calls = policy_row[2],
                        .f32 = ballPairOf(T, dim),
                    };
                    slot += 1;
                }
                list[slot] = .{
                    .name = tag ++ ".intersect." ++ policy_row[0] ++ ".tangent_subnormal",
                    .namespace = "geometry",
                    .invoke = Bound(@This(), "runSubnormalTangency", policy_row[1]).run,
                    .calls = policy_row[2],
                    .f32 = ballPairOf(T, dim),
                };
                slot += 1;
                inline for (.{
                    .{ "crossing", BallSegmentShape.crossing },
                    .{ "contained", BallSegmentShape.contained },
                    .{ "tangent", BallSegmentShape.tangent },
                }) |shape_row| {
                    list[slot] = .{
                        .name = tag ++ ".intersectSegment." ++ policy_row[0] ++ "." ++ shape_row[0],
                        .namespace = "geometry",
                        .invoke = Bound(@This(), "runSegment", .{ .shape = shape_row[1], .policy = policy_row[1] }).run,
                        .calls = policy_row[2],
                        .f32 = ballSegmentOf(T, dim),
                    };
                    slot += 1;
                }
                inline for (.{
                    .{ "crossing_outside", RayBallShape.crossing_outside },
                    .{ "origin_inside", RayBallShape.origin_inside },
                    .{ "tangent", RayBallShape.tangent },
                }) |shape_row| {
                    list[slot] = .{
                        .name = tag ++ ".intersectRay." ++ policy_row[0] ++ "." ++ shape_row[0],
                        .namespace = "geometry",
                        .invoke = Bound(@This(), "runRay", .{ .shape = shape_row[1], .policy = policy_row[1] }).run,
                        .calls = policy_row[2],
                        // The ray is a stored literal, so this row measures
                        // `intersectRay` alone.
                        .f32 = rayBallOf(T, dim),
                    };
                    slot += 1;
                }
            }
            return list;
        }

        const count = 4 + 2 * (3 + 5 + 1 + 3 + 3);
    };
}

/// The ball-against-flat entry point, which exists only where a flat exists:
/// `Sphere3.intersectPlane` in three dimensions and
/// `Hypersphere4.intersectHyperplane` in four. Two dimensions have neither,
/// so `Circle2` declares no such method and this builder is not instantiated
/// for it.
fn BallFlatOps(
    comptime B: type,
    comptime P: type,
    comptime F: type,
) type {
    return struct {
        const T = elementOf(P);
        const dim = componentCount(P);
        const tag = @typeName(B);

        noinline fn run(index: usize, comptime arg: struct { shape: FlatBallShape, policy: g.PredicatePolicy }) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            // Both operands are stored literals: `ballBuild` only gates and
            // compares, and `init` on the flat would normalize `axis0(scale)`
            // to the unit first axis, which is what is written here. So this
            // row measures the cut alone.
            const held = B{ .center = build(P, zeros(dim)), .radius = @floatCast(scale) };
            const flat = F{
                .origin = build(P, axis(dim, 0, FlatBallShapeOffset(arg.shape) * scale)),
                .normal = build(P, unitAxis(dim, 0)).toVector(),
            };
            const cut = switch (dim) {
                3 => held.intersectPlane(flat, arg.policy),
                else => held.intersectHyperplane(flat, arg.policy),
            };
            return outcome(index, cut);
        }

        /// The name of the entry point, which differs by dimension.
        fn methodName() []const u8 {
            return switch (dim) {
                3 => "intersectPlane",
                else => "intersectHyperplane",
            };
        }

        fn cases() [6]common.Case {
            var list: [6]common.Case = undefined;
            var slot: usize = 0;
            inline for (.{
                .{ "policy.fast", g.PredicatePolicy.fast, 16 },
                .{ "policy.adaptive_exact", g.PredicatePolicy.adaptive_exact, 8 },
            }) |policy_row| {
                inline for (.{
                    .{ "cut", FlatBallShape.cut },
                    .{ "tangent", FlatBallShape.tangent },
                    .{ "miss", FlatBallShape.miss },
                }) |shape_row| {
                    list[slot] = .{
                        .name = tag ++ "." ++ methodName() ++ "." ++ policy_row[0] ++ "." ++ shape_row[0],
                        .namespace = "geometry",
                        .invoke = Bound(@This(), "run", .{ .shape = shape_row[1], .policy = policy_row[1] }).run,
                        .calls = policy_row[2],
                        .f32 = ballFlatOf(T, dim),
                    };
                    slot += 1;
                }
            }
            return list;
        }
    };
}

// ---------------------------------------------------------------------------
// Plane3 / Hyperplane4
// ---------------------------------------------------------------------------

const FlatPair = enum {
    /// Normals not parallel: the meeting set is the line they span.
    nonparallel,
    /// The same flat twice.
    coincident,
    /// Parallel normals and a nonzero gap.
    parallel_disjoint,
};

const FlatSegmentShape = enum {
    /// One end strictly either side: the flat cuts the run once.
    crossing,
    /// Both ends on the flat: the run is the whole common set.
    contained,
    /// Both ends strictly on one side.
    disjoint,
};

/// A ball against a flat, named by where the section lands.
const FlatBallShape = enum { cut, tangent, miss };

fn FlatBallShapeOffset(comptime self: FlatBallShape) f64 {
    return switch (self) {
        .cut => 0.0,
        .tangent => 1.0,
        .miss => 2.0,
    };
}

fn FlatOps(
    comptime F: type,
    comptime P: type,
    comptime S: type,
    comptime B: type,
) type {
    return struct {
        const T = elementOf(P);
        const dim = componentCount(P);
        const tag = @typeName(F);

        /// A flat through `(offset * scale)` on the first axis with the first
        /// axis for its normal, built as a STORED value.
        ///
        /// `init` would normalize `axis0(scale)`, whose norm is `scale`, and
        /// return exactly the unit first axis. Writing that value directly
        /// gives the same object with no arithmetic, so the method rows that
        /// need a flat to read or cut pay nothing for having one.
        ///
        /// The scale is the CALLER'S, for the same reason the ball's is: an
        /// operand placed against a second scale is not the arrangement the
        /// case name states. Every caller below passes the ONE scale its
        /// probes and radii are multiples of.
        fn flat(scale: f64, offset: f64) F {
            return .{
                .origin = build(P, axis(dim, 0, offset * scale)),
                .normal = build(P, unitAxis(dim, 0)).toVector(),
            };
        }

        /// The receiver the `signedDistance` and `isFinite` rows measure: a
        /// stored flat with a unit normal, whose origin still follows the
        /// regime.
        fn storedFlat(index: usize, regime: Regime) F {
            var source = Source.begin(index);
            const which = source.next() & 1;
            return .{
                .origin = build(P, regimeCoords(P, &source, regime)),
                .normal = build(P, unitAxis(dim, which)).toVector(),
            };
        }

        noinline fn init(index: usize) u64 {
            var source = Source.begin(index);
            const regime = regimeOf(index);
            const held = F.init(
                build(P, regimeCoords(P, &source, regime)),
                build(P, regimeCoords(P, &source, regime)).toVector(),
            );
            return outcome(index, held);
        }

        noinline fn initDegenerate(index: usize) u64 {
            return outcome(index, F.init(build(P, zeros(dim)), build(P, zeros(dim)).toVector()));
        }

        noinline fn initSubnormal(index: usize) u64 {
            // The subnormal scaled normalization, reached through the flat's
            // own constructor: a normal whose norm is below `floatMin(T)` is
            // normalized by dividing through its largest component.
            var source = Source.begin(index);
            const origin = build(P, regimeCoords(P, &source, .ordinary));
            const normal = build(P, subnormalCoords(P, &source)).toVector();
            return outcome(index, F.init(origin, normal));
        }

        noinline fn signedDistance(index: usize) u64 {
            var source = Source.begin(index);
            const regime = regimeOf(index);
            const held = storedFlat(index, regime);
            const point = build(P, regimeCoords(P, &source, regime));
            return outcome(index, held.signedDistance(point));
        }

        noinline fn signedDistanceOverflow(index: usize) u64 {
            const operands = overflowOperands();
            return outcome(index, operands.held.signedDistance(operands.point));
        }

        /// The operands the overflow row measures: a stored flat through
        /// `-far` on the first axis with that exact axis for its normal, and
        /// a point at `+far` on the same axis.
        ///
        /// Every value is finite and the normal is the unit first axis, so
        /// `requireFiniteField` passes on both operands and the refusal is the
        /// arithmetic's own: `flatDistanceFast` forms `point - origin` on that
        /// axis first, and `2 * far` leaves the format before the sum has
        /// anything to report. An origin at zero could not do that — its
        /// difference is `far`, which is inside the format, so the row would
        /// be measuring a finite distance under a name that promises an
        /// overflow.
        fn overflowOperands() struct { held: F, point: P } {
            const far: f64 = @as(f64, std.math.floatMax(T)) * 0.75;
            return .{
                .held = .{
                    .origin = build(P, axis(dim, 0, -far)),
                    .normal = build(P, unitAxis(dim, 0)).toVector(),
                },
                .point = build(P, axis(dim, 0, far)),
            };
        }

        noinline fn isFinite(index: usize) u64 {
            const held = storedFlat(index, regimeOf(index));
            const poisoned = F{
                .origin = poisonedValue(P, T),
                .normal = build(P, unitAxis(dim, 0)).toVector(),
            };
            return digest(index, .{ held.isFinite(), poisoned.isFinite() });
        }

        noinline fn runPair(index: usize, comptime arg: struct { shape: FlatPair, policy: g.PredicatePolicy }) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            // Both flats carry a unit axis normal, which is what `init` would
            // have produced, so building them costs nothing.
            const first = F{
                .origin = build(P, zeros(dim)),
                .normal = build(P, unitAxis(dim, 0)).toVector(),
            };
            const second = switch (arg.shape) {
                FlatPair.nonparallel => F{
                    .origin = build(P, zeros(dim)),
                    .normal = build(P, unitAxis(dim, 1)).toVector(),
                },
                FlatPair.coincident => F{
                    .origin = build(P, zeros(dim)),
                    .normal = build(P, unitAxis(dim, 0)).toVector(),
                },
                FlatPair.parallel_disjoint => F{
                    .origin = build(P, axis(dim, 1, 2.0 * scale)),
                    .normal = build(P, unitAxis(dim, 0)).toVector(),
                },
            };
            return outcome(index, first.intersect(second, arg.policy));
        }

        noinline fn runSegment(index: usize, comptime arg: struct { shape: FlatSegmentShape, policy: g.PredicatePolicy }) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const held = flat(scale, 0.0);
            const segment = switch (arg.shape) {
                FlatSegmentShape.crossing => S.init(
                    build(P, axis(dim, 1, -scale)),
                    build(P, axis(dim, 1, scale)),
                ) catch unreachable,
                FlatSegmentShape.contained => S.init(
                    build(P, axis(dim, 0, 0.5 * scale)),
                    build(P, axis(dim, 0, 1.5 * scale)),
                ) catch unreachable,
                FlatSegmentShape.disjoint => S.init(
                    build(P, axis(dim, 1, 2.0 * scale)),
                    build(P, axis(dim, 1, 3.0 * scale)),
                ) catch unreachable,
            };
            return outcome(index, held.intersectSegment(segment, arg.policy));
        }

        noinline fn runBall(index: usize, comptime arg: struct { shape: FlatBallShape, policy: g.PredicatePolicy }) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const held = flat(scale, 0.0);
            // Both operands are stored literals, so this row measures
            // `intersectSphere` alone.
            const sphere = B{ .center = build(P, zeros(dim)), .radius = @floatCast(scale) };
            return outcome(index, held.intersectSphere(sphere, arg.policy));
        }

        fn cases() [24]common.Case {
            var list: [24]common.Case = undefined;
            var slot: usize = 0;
            const base = [_]common.Case{
                .{
                    .name = tag ++ ".init",
                    .namespace = "geometry",
                    .invoke = init,
                    .f32 = normalizeOf(T, dim),
                },
                .{
                    .name = tag ++ ".init.degenerate",
                    .namespace = "geometry",
                    .invoke = initDegenerate,
                    .f32 = lengthOf(T, dim),
                },
                .{
                    .name = tag ++ ".init.subnormal_normal",
                    .namespace = "geometry",
                    .invoke = initSubnormal,
                    .f32 = normalizeOf(T, dim),
                },
                // The three rows below build their receiver as a stored
                // literal with a unit normal, so they measure the method alone
                // and carry no charge. `signedDistance` is the plain scalar
                // evaluation the module documents; its overflow row is the
                // same evaluation refused with `error.NonFiniteResult` on
                // finite operands, and `isFinite` is two comparisons.
                .{ .name = tag ++ ".signedDistance", .namespace = "geometry", .invoke = signedDistance },
                .{ .name = tag ++ ".signedDistance.overflow", .namespace = "geometry", .invoke = signedDistanceOverflow },
                .{ .name = tag ++ ".isFinite", .namespace = "geometry", .invoke = isFinite },
            };
            for (base) |entry| {
                list[slot] = entry;
                slot += 1;
            }
            inline for (.{
                .{ "policy.fast", g.PredicatePolicy.fast, 16 },
                .{ "policy.adaptive_exact", g.PredicatePolicy.adaptive_exact, 8 },
            }) |policy_row| {
                inline for (.{
                    .{ "nonparallel", FlatPair.nonparallel },
                    .{ "coincident", FlatPair.coincident },
                    .{ "parallel_disjoint", FlatPair.parallel_disjoint },
                }) |shape_row| {
                    list[slot] = .{
                        .name = tag ++ ".intersect." ++ policy_row[0] ++ "." ++ shape_row[0],
                        .namespace = "geometry",
                        .invoke = Bound(@This(), "runPair", .{ .shape = shape_row[1], .policy = policy_row[1] }).run,
                        .calls = policy_row[2],
                        // Both flats are stored literals, so this row measures
                        // `intersect` alone.
                        .f32 = flatPairOf(T, dim),
                    };
                    slot += 1;
                }
                inline for (.{
                    .{ "crossing", FlatSegmentShape.crossing },
                    .{ "contained", FlatSegmentShape.contained },
                    .{ "disjoint", FlatSegmentShape.disjoint },
                }) |shape_row| {
                    list[slot] = .{
                        .name = tag ++ ".intersectSegment." ++ policy_row[0] ++ "." ++ shape_row[0],
                        .namespace = "geometry",
                        .invoke = Bound(@This(), "runSegment", .{ .shape = shape_row[1], .policy = policy_row[1] }).run,
                        .calls = policy_row[2],
                        // `flatIntersectSegment` is a predicate plus plain
                        // arithmetic, and the flat is a stored literal, so
                        // this row measures `intersectSegment` alone and
                        // declares no charge.
                    };
                    slot += 1;
                }
                inline for (.{
                    .{ "cut", FlatBallShape.cut },
                    .{ "tangent", FlatBallShape.tangent },
                    .{ "miss", FlatBallShape.miss },
                }) |shape_row| {
                    list[slot] = .{
                        .name = tag ++ ".intersectSphere." ++ policy_row[0] ++ "." ++ shape_row[0],
                        .namespace = "geometry",
                        .invoke = Bound(@This(), "runBall", .{ .shape = shape_row[1], .policy = policy_row[1] }).run,
                        .calls = policy_row[2],
                        .f32 = ballFlatOf(T, dim),
                    };
                    slot += 1;
                }
            }
            return list;
        }
    };
}

// ---------------------------------------------------------------------------
// Aabb2 / Aabb3 / Aabb4
// ---------------------------------------------------------------------------

const BoxPair = enum {
    /// Partial overlap: the answer is the box that is neither operand.
    overlap,
    /// One box holds the other whole.
    contained,
    /// The same box twice.
    coincident,
    /// Apart on every axis.
    disjoint,
    /// Sharing one face only, so the answer is a degenerate box.
    touching,
};

fn boxPairCorners(
    comptime dim: usize,
    scale: f64,
    comptime shape: BoxPair,
    comptime which: usize,
) struct { minimum: [dim]f64, maximum: [dim]f64 } {
    return switch (shape) {
        .overlap => if (which == 0)
            .{ .minimum = @as([dim]f64, @splat(-scale)), .maximum = @as([dim]f64, @splat(scale)) }
        else
            .{ .minimum = @as([dim]f64, @splat(0.0)), .maximum = @as([dim]f64, @splat(2.0 * scale)) },
        .contained => if (which == 0)
            .{ .minimum = @as([dim]f64, @splat(-2.0 * scale)), .maximum = @as([dim]f64, @splat(2.0 * scale)) }
        else
            .{ .minimum = @as([dim]f64, @splat(-scale)), .maximum = @as([dim]f64, @splat(scale)) },
        .coincident => .{
            .minimum = @as([dim]f64, @splat(-scale)),
            .maximum = @as([dim]f64, @splat(scale)),
        },
        .disjoint => if (which == 0)
            .{ .minimum = @as([dim]f64, @splat(0.0)), .maximum = @as([dim]f64, @splat(scale)) }
        else
            .{ .minimum = @as([dim]f64, @splat(2.0 * scale)), .maximum = @as([dim]f64, @splat(3.0 * scale)) },
        .touching => if (which == 0)
            .{ .minimum = @as([dim]f64, @splat(0.0)), .maximum = @as([dim]f64, @splat(scale)) }
        else
            .{ .minimum = @as([dim]f64, @splat(scale)), .maximum = @as([dim]f64, @splat(2.0 * scale)) },
    };
}

fn BoxOps(comptime A: type, comptime P: type) type {
    return struct {
        const T = elementOf(P);
        const dim = componentCount(P);
        const tag = @typeName(A);

        fn boxFrom(minimum: [dim]f64, maximum: [dim]f64) A {
            return A.init(build(P, minimum), build(P, maximum)) catch unreachable;
        }

        noinline fn init(index: usize) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            var spread = rawCoords(P, &source, 2.0);
            for (&spread) |*component| component.* = @abs(component.*);
            return outcome(index, A.init(
                build(P, timesAll(dim, spread, -scale)),
                build(P, timesAll(dim, spread, scale)),
            ));
        }

        noinline fn initDegenerate(index: usize) u64 {
            // A box whose corners coincide is legal and names one point.
            var source = Source.begin(index);
            const corner = timesAll(dim, rawCoords(P, &source, 2.0), source.scale());
            return outcome(index, A.init(build(P, corner), build(P, corner)));
        }

        noinline fn initInverted(index: usize) u64 {
            // The refusal path: a minimum above the matching maximum.
            var source = Source.begin(index);
            const scale = source.scale();
            return outcome(index, A.init(
                build(P, @as([dim]f64, @splat(scale))),
                build(P, @as([dim]f64, @splat(-scale))),
            ));
        }

        noinline fn initPoisoned(index: usize) u64 {
            return outcome(index, A.init(
                poisonedValue(P, T),
                build(P, @as([dim]f64, @splat(1.0))),
            ));
        }

        noinline fn contains(index: usize) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const held = boxFrom(@as([dim]f64, @splat(-scale)), @as([dim]f64, @splat(scale)));
            const inside = build(P, @as([dim]f64, @splat(0.5 * scale)));
            const on_face = build(P, @as([dim]f64, @splat(scale)));
            const outside = build(P, @as([dim]f64, @splat(2.0 * scale)));
            return outcomes(index, 3, .{
                held.contains(inside),
                held.contains(on_face),
                held.contains(outside),
            });
        }

        noinline fn expand(index: usize) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const held = boxFrom(@as([dim]f64, @splat(-scale)), @as([dim]f64, @splat(scale)));
            const outside = build(P, @as([dim]f64, @splat(3.0 * scale)));
            const grown = held.expand(outside) catch |err| return refusal(@errorName(err));
            return digest(index, .{ grown.minimum.toArray(), grown.maximum.toArray() });
        }

        noinline fn expandInside(index: usize) u64 {
            // A point already inside leaves both corners exactly as they were.
            var source = Source.begin(index);
            const scale = source.scale();
            const held = boxFrom(@as([dim]f64, @splat(-scale)), @as([dim]f64, @splat(scale)));
            const inside = build(P, @as([dim]f64, @splat(0.25 * scale)));
            const grown = held.expand(inside) catch |err| return refusal(@errorName(err));
            return digest(index, .{ grown.minimum.toArray(), grown.maximum.toArray() });
        }

        noinline fn intersects(index: usize) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const first = boxFrom(@as([dim]f64, @splat(-scale)), @as([dim]f64, @splat(scale)));
            const overlapping = boxFrom(@as([dim]f64, @splat(0.0)), @as([dim]f64, @splat(2.0 * scale)));
            const apart = boxFrom(@as([dim]f64, @splat(2.0 * scale)), @as([dim]f64, @splat(3.0 * scale)));
            const touching = boxFrom(@as([dim]f64, @splat(scale)), @as([dim]f64, @splat(2.0 * scale)));
            return outcomes(index, 3, .{
                first.intersects(overlapping),
                first.intersects(apart),
                first.intersects(touching),
            });
        }

        noinline fn center(index: usize) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const held = boxFrom(@as([dim]f64, @splat(-scale)), @as([dim]f64, @splat(scale)));
            return outcome(index, held.center());
        }

        noinline fn centerOverflow(index: usize) u64 {
            // A box spanning the whole range overflows the sum the centre forms
            // before the halving.
            const huge = @as(f64, std.math.floatMax(T)) * 0.75;
            return outcome(index, boxFrom(
                @as([dim]f64, @splat(-huge)),
                @as([dim]f64, @splat(huge)),
            ).center());
        }

        noinline fn extent(index: usize) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const held = boxFrom(@as([dim]f64, @splat(-scale)), @as([dim]f64, @splat(3.0 * scale)));
            return outcome(index, held.extent());
        }

        /// The receiver every measure row measures: a stored box spanning
        /// `3 * scale` on every axis, so the measure is a genuine finite
        /// value rather than a zero side. `aabbBuild` only compares, so the
        /// box is a literal and each row below times its own method alone.
        fn measureBox(scale: f64) A {
            return boxFrom(@as([dim]f64, @splat(-scale)), @as([dim]f64, @splat(2.0 * scale)));
        }

        noinline fn measureArea(index: usize) u64 {
            var source = Source.begin(index);
            return outcome(index, measureBox(source.scale()).area());
        }

        noinline fn measureVolume(index: usize) u64 {
            var source = Source.begin(index);
            return outcome(index, measureBox(source.scale()).volume());
        }

        noinline fn measureDoubledSurfaceArea(index: usize) u64 {
            var source = Source.begin(index);
            return outcome(index, measureBox(source.scale()).doubledSurfaceArea());
        }

        noinline fn measureHyperVolume(index: usize) u64 {
            var source = Source.begin(index);
            return outcome(index, measureBox(source.scale()).hyperVolume());
        }

        /// The measures this dimension declares, one row each and one timed
        /// call each. Three dimensions declare two of them, `volume` and
        /// `doubledSurfaceArea`, and those are separate public callables over
        /// separate routes — `aabbMeasureOf` against `aabbMeasuresOf` — so
        /// each is its own row and no case name stands for both.
        fn measureCases() []const common.Case {
            return switch (dim) {
                2 => &.{
                    .{ .name = tag ++ ".area", .namespace = "geometry", .invoke = measureArea },
                },
                3 => &.{
                    .{ .name = tag ++ ".volume", .namespace = "geometry", .invoke = measureVolume },
                    .{ .name = tag ++ ".doubledSurfaceArea", .namespace = "geometry", .invoke = measureDoubledSurfaceArea },
                },
                else => &.{
                    .{ .name = tag ++ ".hyperVolume", .namespace = "geometry", .invoke = measureHyperVolume },
                },
            };
        }

        noinline fn isFinite(index: usize) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const held = boxFrom(@as([dim]f64, @splat(-scale)), @as([dim]f64, @splat(scale)));
            const poisoned = A{
                .minimum = poisonedValue(P, T),
                .maximum = build(P, @as([dim]f64, @splat(1.0))),
            };
            return digest(index, .{ held.isFinite(), poisoned.isFinite() });
        }

        noinline fn runPair(index: usize, comptime shape: BoxPair) u64 {
            var source = Source.begin(index);
            const scale = source.scale();
            const first = boxPairCorners(dim, scale, shape, 0);
            const second = boxPairCorners(dim, scale, shape, 1);
            return outcome(index, boxFrom(first.minimum, first.maximum).intersect(boxFrom(second.minimum, second.maximum)));
        }

        fn cases() [count]common.Case {
            var list: [count]common.Case = undefined;
            var slot: usize = 0;
            const base = [_]common.Case{
                .{ .name = tag ++ ".init", .namespace = "geometry", .invoke = init },
                .{ .name = tag ++ ".init.degenerate", .namespace = "geometry", .invoke = initDegenerate },
                .{ .name = tag ++ ".init.inverted", .namespace = "geometry", .invoke = initInverted },
                .{ .name = tag ++ ".init.poisoned", .namespace = "geometry", .invoke = initPoisoned },
                .{ .name = tag ++ ".contains", .namespace = "geometry", .invoke = contains },
                .{
                    .name = tag ++ ".expand",
                    .namespace = "geometry",
                    .invoke = expand,
                    .f32 = boxSelectOf(T, dim),
                },
                .{
                    .name = tag ++ ".expand.inside",
                    .namespace = "geometry",
                    .invoke = expandInside,
                    .f32 = boxSelectOf(T, dim),
                },
                .{ .name = tag ++ ".intersects", .namespace = "geometry", .invoke = intersects },
                .{ .name = tag ++ ".center", .namespace = "geometry", .invoke = center },
                .{ .name = tag ++ ".center.overflow", .namespace = "geometry", .invoke = centerOverflow },
                .{ .name = tag ++ ".extent", .namespace = "geometry", .invoke = extent },
                .{ .name = tag ++ ".isFinite", .namespace = "geometry", .invoke = isFinite },
            };
            for (base) |entry| {
                list[slot] = entry;
                slot += 1;
            }
            for (measureCases()) |row| {
                list[slot] = row;
                slot += 1;
            }
            inline for (.{
                .{ "overlap", BoxPair.overlap },
                .{ "contained", BoxPair.contained },
                .{ "coincident", BoxPair.coincident },
                .{ "disjoint", BoxPair.disjoint },
                .{ "touching", BoxPair.touching },
            }) |shape_row| {
                list[slot] = .{
                    .name = tag ++ ".intersect." ++ shape_row[0],
                    .namespace = "geometry",
                    .invoke = Bound(@This(), "runPair", shape_row[1]).run,
                    .f32 = boxSelectOf(T, dim),
                };
                slot += 1;
            }
            return list;
        }

        /// Twelve constructor and predicate rows, the measure rows this
        /// dimension declares, and the five pair arrangements.
        const count = 12 + measureCases().len + 5;
    };
}

// ---------------------------------------------------------------------------
// The exported case list
// ---------------------------------------------------------------------------

pub const cases = blk: {
    @setEvalBranchQuota(10_000_000);
    break :blk [_]common.Case{} ++
        // Vectors: two, three, and four components in both precisions. `cross`
        // is three-dimensional only and `wedge` is four-dimensional only; every
        // other vector method exists in all six concrete types.
        VectorOps(g.Vector2f, g.Point2f).cases() ++
        VectorOps(g.Vector2d, g.Point2d).cases() ++
        VectorOps(g.Vector3f, g.Point3f).cases() ++
        VectorOps(g.Vector3d, g.Point3d).cases() ++
        VectorOps(g.Vector4f, g.Point4f).cases() ++
        VectorOps(g.Vector4d, g.Point4d).cases() ++

        // Bivector4: four dimensions only, by the contract.
        BivectorOps(g.Bivector4f).cases() ++
        BivectorOps(g.Bivector4d).cases() ++

        // Points: `side` is two-dimensional only; `orientation` has a
        // two-argument form in two dimensions and a four-argument form in three
        // and four.
        PointOps(g.Point2f, g.Vector2f).cases() ++
        PointOps(g.Point2d, g.Vector2d).cases() ++
        PointOps(g.Point3f, g.Vector3f).cases() ++
        PointOps(g.Point3d, g.Vector3d).cases() ++
        PointOps(g.Point4f, g.Vector4f).cases() ++
        PointOps(g.Point4d, g.Vector4d).cases() ++

        // Lines, rays, and segments in all three dimensions and both
        // precisions. Every pair of them reduces to the same affine engine, so
        // each public entry point is timed through its own receiver and its own
        // route into it.
        LineOps(g.Line2f, g.Point2f, g.Vector2f).cases() ++
        LineOps(g.Line2d, g.Point2d, g.Vector2d).cases() ++
        LineOps(g.Line3f, g.Point3f, g.Vector3f).cases() ++
        LineOps(g.Line3d, g.Point3d, g.Vector3d).cases() ++
        LineOps(g.Line4f, g.Point4f, g.Vector4f).cases() ++
        LineOps(g.Line4d, g.Point4d, g.Vector4d).cases() ++
        RayOps(g.Ray2f, g.Point2f, g.Vector2f, g.Line2f, g.Segment2f).cases() ++
        RayOps(g.Ray2d, g.Point2d, g.Vector2d, g.Line2d, g.Segment2d).cases() ++
        RayOps(g.Ray3f, g.Point3f, g.Vector3f, g.Line3f, g.Segment3f).cases() ++
        RayOps(g.Ray3d, g.Point3d, g.Vector3d, g.Line3d, g.Segment3d).cases() ++
        RayOps(g.Ray4f, g.Point4f, g.Vector4f, g.Line4f, g.Segment4f).cases() ++
        RayOps(g.Ray4d, g.Point4d, g.Vector4d, g.Line4d, g.Segment4d).cases() ++
        SegmentOps(g.Segment2f, g.Point2f, g.Vector2f, g.Ray2f, g.Line2f).cases() ++
        SegmentOps(g.Segment2d, g.Point2d, g.Vector2d, g.Ray2d, g.Line2d).cases() ++
        SegmentOps(g.Segment3f, g.Point3f, g.Vector3f, g.Ray3f, g.Line3f).cases() ++
        SegmentOps(g.Segment3d, g.Point3d, g.Vector3d, g.Ray3d, g.Line3d).cases() ++
        SegmentOps(g.Segment4f, g.Point4f, g.Vector4f, g.Ray4f, g.Line4f).cases() ++
        SegmentOps(g.Segment4d, g.Point4d, g.Vector4d, g.Ray4d, g.Line4d).cases() ++

        // Closed solid balls: circle in two, sphere in three, hypersphere in
        // four. The flat-cut entry point exists only where a flat exists: it is
        // `intersectPlane` in three dimensions and `intersectHyperplane` in
        // four, and two dimensions declare neither.
        BallOps(g.Circle2f, g.Point2f, g.Segment2f, g.Ray2f).cases() ++
        BallOps(g.Circle2d, g.Point2d, g.Segment2d, g.Ray2d).cases() ++
        BallOps(g.Sphere3f, g.Point3f, g.Segment3f, g.Ray3f).cases() ++
        BallFlatOps(g.Sphere3f, g.Point3f, g.Plane3f).cases() ++
        BallOps(g.Sphere3d, g.Point3d, g.Segment3d, g.Ray3d).cases() ++
        BallFlatOps(g.Sphere3d, g.Point3d, g.Plane3d).cases() ++
        BallOps(g.Hypersphere4f, g.Point4f, g.Segment4f, g.Ray4f).cases() ++
        BallFlatOps(g.Hypersphere4f, g.Point4f, g.Hyperplane4f).cases() ++
        BallOps(g.Hypersphere4d, g.Point4d, g.Segment4d, g.Ray4d).cases() ++
        BallFlatOps(g.Hypersphere4d, g.Point4d, g.Hyperplane4d).cases() ++

        // Flats: a plane exists in three dimensions and a hyperplane in four.
        FlatOps(g.Plane3f, g.Point3f, g.Segment3f, g.Sphere3f).cases() ++
        FlatOps(g.Plane3d, g.Point3d, g.Segment3d, g.Sphere3d).cases() ++
        FlatOps(g.Hyperplane4f, g.Point4f, g.Segment4f, g.Hypersphere4f).cases() ++
        FlatOps(g.Hyperplane4d, g.Point4d, g.Segment4d, g.Hypersphere4d).cases() ++

        // Axis-aligned boxes in all three dimensions and both precisions.
        // Every measure the dimension declares is its own row and its own
        // timed call: `area` in two dimensions, `volume` AND
        // `doubledSurfaceArea` in three, `hyperVolume` in four.
        BoxOps(g.Aabb2f, g.Point2f).cases() ++
        BoxOps(g.Aabb2d, g.Point2d).cases() ++
        BoxOps(g.Aabb3f, g.Point3f).cases() ++
        BoxOps(g.Aabb3d, g.Point3d).cases() ++
        BoxOps(g.Aabb4f, g.Point4f).cases() ++
        BoxOps(g.Aabb4d, g.Point4d).cases()

    // `Intersection2/3/4`, `Flat2f/Flat2d`, `PredicatePolicy`, `Sign` and
    // `ContainedSide` are consumed through the cases above and declared
    // here so the list is complete against the module surface.
    ;
};

// ---------------------------------------------------------------------------
// Inventory: every declared public callable of `src/geometry.zig`
//
// 1110 cases in total, all in the `geometry` namespace, because every entry
// point below is reached through `zmath.geometry`. Every name names the PUBLIC
// ENTRY POINT under test; a name that also ends in `.normalized_operands` is
// the one case where the timed body additionally runs a normalizing
// constructor to build an operand, and the section "WHAT THE TIMED BODY
// CONTAINS" below says exactly which rows those are and what they cost.
//
// TIMED DIRECTLY
//
// - `Vector2f/2d/3f/3d/4f/4d`: `init`, `init.poisoned` (the refusal arm),
//   `fromArray`, `toArray`, `add`, `sub`, `neg`, `scale`, `dot`,
//   `lengthSquared`, `length`, `normalize`, `normalize.degenerate`,
//   `normalize.subnormal_norm`, `normalize.overflow`, `distanceSquared`,
//   `distance`, `isFinite`, `eq`. Plus `cross` on the three three-dimensional
//   types and `wedge` on the two four-dimensional types.
// - `Bivector4f/4d`: `init`, `init.poisoned`, `neg`, `isFinite`.
// - `Point2f/2d/3f/3d/4f/4d`: `init`, `init.poisoned`, `fromArray`, `toArray`,
//   `add`, `sub`, `toVector`, `isFinite`, `eq`; `orientation` under both
//   policies in the ordinary, near-degenerate and exponent-extreme regimes,
//   with the four-dimensional near-dependence and the perturbed-ulp rows added
//   where they apply; `side` under both policies on the two-dimensional types.
// - `Line2f/2d/3f/3d/4f/4d`: `init`, `init.degenerate`,
//   `init.subnormal_direction`, `at`, `at.negative_parameter`,
//   `closestPointTo`, `isFinite`; `intersect` under both policies over the
//   crossing, offset-crossing, collinear, parallel-disjoint and coincident
//   arrangements.
// - `Ray2f/2d/3f/3d/4f/4d`: `init`, `init.degenerate`,
//   `init.subnormal_direction`, `at`, `at.clamped`, `isFinite`; `intersect`,
//   `intersectLine` and `intersectSegment` under both policies over the
//   arrangements each accepts.
// - `Segment2f/2d/3f/3d/4f/4d`: `init`, `init.coincident_ends`,
//   `init.poisoned`, `at`, `at.clamped`, `length`, `closestPointTo`,
//   `closestPointTo.degenerate`, `isFinite`; `intersect` under both policies
//   over all eight arrangements plus the subnormal span, `intersectRay` and
//   `intersectLine` under both policies, both degenerate-segment arms included.
// - `Circle2f/2d`, `Sphere3f/3d`, `Hypersphere4f/4d`: `init`,
//   `init.negative_radius`, `init.zero_radius`, `isFinite`; `contains` under
//   both policies at the inside, boundary and outside placements;
//   `intersect` under both policies over crossing, tangent, contained,
//   disjoint and coincident, plus a subnormal tangency; `intersectSegment`
//   over crossing, contained and tangent; `intersectRay` over outside-crossing,
//   origin-inside and tangent.
// - `Plane3f/3d`, `Hyperplane4f/4d`: `init`, `init.degenerate`,
//   `init.subnormal_normal`, `signedDistance`, `signedDistance.overflow`,
//   `isFinite`; `intersect` under both policies over non-parallel, coincident
//   and parallel-disjoint; `intersectSegment` over crossing, contained and
//   disjoint; `intersectSphere` over cut, tangent and miss.
// - `Aabb2f/2d/3f/3d/4f/4d`: `init`, `init.degenerate`, `init.inverted`,
//   `init.poisoned`, `contains`, `expand`, `expand.inside`, `intersects`,
//   `center`, `center.overflow`, `extent`, `isFinite`; the measure methods the
//   dimension declares, each its own row; `intersect` over overlap, contained,
//   coincident, disjoint and touching.
//
// THE SUBNORMAL SCALED NORMALIZATION
//
// `vectorNormalize` and `arrayNormalizedChecked` both compare the folded norm
// against `floatMin(T)`. Below it they do not divide through that norm, which
// would round the component ratios away; they divide through the largest
// component, fold the norm of the RESCALED vector, and divide through that.
// The branch is reached by four case families, one per public route into it:
//
// - `*.init.subnormal_direction` on `Line2/3/4f/d` and `Ray2/3/4f/d`, and
//   `*.init.subnormal_normal` on `Plane3f/3d` and `Hyperplane4f/4d`, which all
//   reach `vectorNormalize` through `lineBuild`.
// - `Vector*.normalize.subnormal_norm`, which reaches it directly.
// - `Segment*.intersect.policy.*.subnormal_span`, which reaches
//   `arrayNormalizedChecked` through the affine engine's frame.
// - `*.intersect.policy.*.tangent_subnormal` on the balls, which reaches it
//   through `ballIntersect`'s touch point.
//
// Two more normalizations sit on routes a public entry point cannot reach with
// a subnormal operand, and are reserved rather than timed:
//
// - The `.line` payload of `affineToIntersection` normalizes `a_direction`,
//   which is the unit direction `Line.init` or `Ray.init` already normalized.
// - `flatPair3`'s cross product and `flatPair4`'s in-plane normal are built
//   from two unit normals, whose separation no representable pair drops below
//   `floatMin(T)` on. Both tables still carry the branch, because a
//   reservation is made before the route runs and is never refunded.
//
// CONSUMED THROUGH THE CASES ABOVE, NOT SEPARATELY DECLARED
//
// - `Intersection2f/2d/3f/3d/4f/4d` and `Flat2f/2d` are result types. They
//   carry no declaration of their own: they are produced by the intersect
//   cases above and are hashed in full, tag and every payload component, so a
//   case that returns `.circle` records the centre and radius of the section
//   and a case that returns `.plane` records the two-flat's origin and both
//   directions. No static inventory entry can add anything.
// - `PredicatePolicy`, `Sign` and `ContainedSide` are the policy and tag
//   arguments and results of the cases above. `Sign` and `ContainedSide` are
//   hashed as enum values by every orientation, predicate and intersection
//   case, so both tags are covered.
// - `PredicatePolicy.fast` and `PredicatePolicy.adaptive_exact` are both
//   exercised by name on every polynomial predicate in the module: the five
//   `Point` orientation forms, `Point2.side`, every affine intersection,
//   `Ball.contains`, ball-pair, ball-segment, ball-ray and ball-flat
//   classification, `Flat.intersect`, `Flat.intersectSegment` and
//   `Flat.intersectSphere`.
//
// FAMILY-INAPPLICABLE, CLASSIFIED AND NOT CALLED
//
// - `Vector3.cross` does not exist in two or four dimensions: the orthogonal
//   complement of the plane two vectors span is a plane, not a line, and the
//   module documents this omission. It is timed on `Vector3f` and `Vector3d`
//   only.
// - `Vector4.cross` does not exist at all, for the same reason. `Vector4.wedge`
//   is the product four dimensions actually has and is timed on `Vector4f` and
//   `Vector4d`.
// - `Point2.side` exists in two dimensions only; a line in three or four
//   dimensions has no two sides. It is timed on `Point2f` and `Point2d`.
// - `Ray.closestPointTo` does not exist: the contract names `at` for a ray and
//   `closestPointTo` for a segment, and the module keeps that asymmetry.
// - `Segment`, `Line`, `Ray`, `Plane` and `Hyperplane` are typed by dimension,
//   so `Circle2f` has no flat-cut entry point and `Sphere3f` has no
//   hyperplane cut. `Circle2` is therefore built without the ball-flat
//   builder, and the two higher-dimensional families each name the entry point
//   their dimension declares.
// - `Aabb` declares the measures its dimension names and no other: `area` in
//   two dimensions, `volume` and `doubledSurfaceArea` in three, `hyperVolume`
//   in four. They are separate public callables over separate routes, so each
//   is timed on its own and each case name states the one it measured.
// - `Hypersphere4.intersectHyperplane` and `Sphere3.intersectPlane` are the
//   same canonical route (`ballIntersectFlat`) reached through the name each
//   dimension gives it, so each is timed through its own public entry point
//   rather than being merged.
//
// CANONICAL ROUTES, for reading the charge tables
//
// - Every pair of lines, rays and segments reduces to
//   `affineIntersectDispatch`: the coplanarity gate in three and four
//   dimensions, the two-dimensional classification directly in two, and one
//   payload construction. `affineTable` is that route's bound, and
//   `affineCaseOf` adds the normalizations the case spends getting there.
// - `Segment.length` and `Vector.distance` both reach `vectorDistance`, which
//   is `vectorLength` over the difference; `lengthOf` covers them together.
// - `Line.init`, `Ray.init`, `Plane.init`, `Hyperplane.init` and
//   `Vector.normalize` all reach `vectorNormalize`; `normalizeOf` covers them
//   together, subnormal branch included. `affineCaseOf` is the only other
//   table that adds a copy of it, because only the affine rows still build an
//   operand through a constructor.
// - `Ball.intersect` reaches `ballIntersect`, whose crossing branch needs a
//   perpendicular seed and `chordHeight` and whose tangency branch normalizes
//   the separation; `ballPairOf` is the larger of the two.
// - `Ball.intersectSegment` and `Ball.intersectRay` share the ray quadratic
//   but not the span norm, so they carry separate tables.
// - `Aabb.expand` and `Aabb.intersect` are the only two routes that select a
//   corner with `fminf`/`fmaxf`. `Aabb.init` only compares, and carries no
//   table.
//
// TRANSITIVE CLOSURE OF THE FIVE KERNELS THIS BUNDLE REACHES
//
// A charge has to name every binary32 kernel a route reaches, not only the
// one it calls directly. Read from `src/scalar*.zig`:
//
// - `hypotf` (`scalar_hypot.zig`) calls `hypotSpecialF` and `hypotfRefine`.
//   `hypotSpecialF` is pure bit manipulation. `hypotfRefine` calls
//   `fma_impl.fma64`, which is a BINARY64 kernel and is never part of a
//   binary32 budget. So `hypotf` reaches no other binary32 kernel.
// - `sqrtf` (`scalar_sqrt.zig`) is `@sqrt` plus a bit-level special-case
//   ladder. No binary32 kernel call.
// - `fminf` and `fmaxf` (`scalar_extrema.zig`) reach `minimumLegacy` and
//   `maximumLegacy`, which are NaN tests and comparisons over the bit
//   patterns. No binary32 kernel call.
// - `absf` (`scalar.zig`) is one mask. No binary32 kernel call.
//
// So unlike the transcendental leaves, none of the five kernels this bundle
// reaches has a nested binary32 closure, and no `fmaf` line is owed here.
//
// WHAT THE TIMED BODY CONTAINS
//
// The runner times a whole `invoke`, so every row here includes whatever its
// own body does before it reaches the entry point under test. No row claims
// otherwise. The two groups below are separated so that a reader knows which
// number is a method's own latency and which is a pipeline cost.
//
// ISOLATED — the row's body is the named entry point and its own arguments.
//
// - Every `Vector`, `Point`, `Bivector4` and `Aabb` row. Their fixtures reach
//   no accepted kernel, so `fromArray`/`init`/`contains`/`intersects`/`expand`
//   in the body costs nothing the row has to declare beyond its own route.
// - Every `Segment` row: `Segment.init` only gates its two ends, so
//   `at`, `at.clamped`, `closestPointTo`, `closestPointTo.degenerate`,
//   `isFinite`, `intersect` and `intersect.policy.*.subnormal_span` are all
//   measured on their own. `length` is the exception inside this group, and it
//   declares `hypotf` for the fold it performs.
// - Every `Circle`/`Sphere`/`Hypersphere` row. `ballBuild` only gates the
//   centre and compares the radius, so the ball operand is a stored literal
//   and `contains`, `intersect`, `intersectSegment`, `intersectRay`,
//   `intersectPlane` and `intersectHyperplane` are measured on their own.
// - `Line.at`, `Line.at.negative_parameter`, `Line.closestPointTo` and
//   `Line.isFinite`; `Ray.at`, `Ray.at.clamped` and `Ray.isFinite`;
//   `Plane3`/`Hyperplane4.signedDistance`, `.signedDistance.overflow` and
//   `.isFinite`; `Flat.intersectSegment`; `Flat.intersectSphere`.
//   All of these build their receiver as a stored literal with a unit
//   coordinate-axis normal, which is exactly what `init` would have returned,
//   so `vectorNormalize` stays out of the measurement.
//
// PIPELINE — the row's name ends in `.normalized_operands`, and its body also
// runs one or two normalizing constructors to get there.
//
// - `Line.intersect`, `Ray.intersect`, `Ray.intersectLine`: two constructors.
// - `Ray.intersectSegment`, `Segment.intersectRay`, `Segment.intersectLine`:
//   one constructor, the segment being free.
//
// Those are the only rows whose subject is an arrangement of DIRECTIONS, so
// the constructor is not incidental there: the arrangement is the thing under
// test, and an operand with a non-unit direction is not the operand the method
// documents. `Flat.intersect` and the ball-flat cut rows used to be in this
// group as well; their normals are exact coordinate axes, so they moved back
// to the isolated group.
//
// CASES AND BUDGET, BY NAMESPACE
//
// `charged` counts the cases that declare a binary32 reservation. It is not
// simply half of each family: the binary64 instantiation of an entry point
// reaches no binary32 kernel at all, but the binary32 instantiation of
// `Point`, `Bivector4` and the vector-only methods reaches none either.
// `evaluations` is the declared binary32 count for ONE repetition of the whole
// family, that is the sum over its charged cases of the table times
// `Case.calls`. The pipeline rows above are included, and they are why the
// affine tables take a `built` count instead of hiding the constructor.
//
// | namespace | family                | cases | charged | evaluations |
// | --------- | --------------------- | ----: | ------: | ----------: |
// | geometry  | Vector2/3/4           |   118 |      18 |       3,456 |
// | geometry  | Point2/3/4            |   106 |       0 |           0 |
// | geometry  | Bivector4             |     8 |       0 |           0 |
// | geometry  | Line2/3/4             |   102 |      39 |      32,832 |
// | geometry  | Ray2/3/4              |   132 |      57 |      49,248 |
// | geometry  | Segment2/3/4          |   210 |      81 |      59,904 |
// | geometry  | Circle2/Sphere3/Hypersphere4 | 204 |   72 |      15,336 |
// | geometry  | Sphere/Hypersphere flat cut | 24 |   12 |       2,304 |
// | geometry  | Plane3/Hyperplane4    |    96 |      30 |       9,504 |
// | geometry  | Aabb2/3/4             |   110 |      21 |       4,032 |
// | geometry  | TOTAL                 | 1,110 |     330 |     176,616 |
//
// Broken out by kernel, the same 176,616 is:
//
// | kernel  | evaluations |
// | ------- | ----------: |
// | hypotf  |      88,456 |
// | absf    |      41,560 |
// | fmaxf   |      37,168 |
// | fminf   |       7,848 |
// | sqrtf   |       1,584 |
//
// 330 charged cases at `calls` of 8, 16 or 32 mean one full repetition of this
// bundle costs 176,616 of the global 1,048,576 binary32 budget, or about 16.8
// per cent.

// ---------------------------------------------------------------------------
// Boundary regressions
//
// Each test reads the operands a NAMED row builds, through the same helper
// that row builds them with, and asserts the classification the module's own
// documentation gives that arrangement. None of them reads a case name, a
// case count or a charge table: they fail when a named row stops reaching the
// branch its name states, which is a failure two builds agree on and a
// checksum comparison cannot see.
// ---------------------------------------------------------------------------

test "every named ball relation reaches the classification its name states" {
    inline for (.{
        .{ g.Circle2f, g.Point2f, g.Segment2f, g.Ray2f },
        .{ g.Circle2d, g.Point2d, g.Segment2d, g.Ray2d },
        .{ g.Sphere3f, g.Point3f, g.Segment3f, g.Ray3f },
        .{ g.Sphere3d, g.Point3d, g.Segment3d, g.Ray3d },
        .{ g.Hypersphere4f, g.Point4f, g.Segment4f, g.Ray4f },
        .{ g.Hypersphere4d, g.Point4d, g.Segment4d, g.Ray4d },
    }) |family| {
        const Ops = BallOps(family[0], family[1], family[2], family[3]);
        const T = elementOf(family[1]);
        inline for (.{ g.PredicatePolicy.fast, g.PredicatePolicy.adaptive_exact }) |policy| {
            // Every scale the stream can draw, so no arrangement is only ever
            // checked at one magnitude.
            for (0..scale_powers.len) |power| {
                const scale = scale_powers[power];
                const held = Ops.ball(scale, 0.0, 1.0);

                // `contains`: the boundary belongs to the closed ball, so
                // `inside` and `boundary` hold and `outside` does not. This is
                // the assertion a second scale on the probe would break.
                try std.testing.expect(try held.contains(Ops.probe(scale, .inside), policy));
                try std.testing.expect(try held.contains(Ops.probe(scale, .boundary), policy));
                try std.testing.expect(!try held.contains(Ops.probe(scale, .outside), policy));

                const crossing = Ops.pairOf(.crossing);
                const crossed = held.intersect(Ops.ball(scale, crossing.offset, crossing.radius), policy) catch unreachable;
                try std.testing.expect(std.meta.activeTag(crossed) == .two_points);

                const tangent = Ops.pairOf(.tangent);
                const touched = held.intersect(Ops.ball(scale, tangent.offset, tangent.radius), policy) catch unreachable;
                try std.testing.expect(std.meta.activeTag(touched) == .point);

                const inner = Ops.pairOf(.contained);
                const swallowed = held.intersect(Ops.ball(scale, inner.offset, inner.radius), policy) catch unreachable;
                try std.testing.expect(std.meta.activeTag(swallowed) == .contained);
                try std.testing.expect(swallowed.contained == .second);

                const apart = Ops.pairOf(.disjoint);
                const separate = held.intersect(Ops.ball(scale, apart.offset, apart.radius), policy) catch unreachable;
                try std.testing.expect(std.meta.activeTag(separate) == .none);

                const same = Ops.pairOf(.coincident);
                const identical = held.intersect(Ops.ball(scale, same.offset, same.radius), policy) catch unreachable;
                try std.testing.expect(std.meta.activeTag(identical) == .coincident);

                // The subnormal tangency: one unit is both radii and the whole
                // separation, and the answer is the single touch point the
                // normalized separation builds.
                const sub_pair = Ops.subnormalPair(@floatCast(subnormalSpread(T)));
                const grazed = sub_pair.first.intersect(sub_pair.second, policy) catch unreachable;
                try std.testing.expect(std.meta.activeTag(grazed) == .point);

                // Segments: a run through the ball is a proper sub-segment, a
                // run wholly inside is the segment itself, and a run standing
                // one radius off the centre touches at its closest point.
                const through = held.intersectSegment(Ops.segmentOf(scale, .crossing), policy) catch unreachable;
                try std.testing.expect(std.meta.activeTag(through) == .segment);
                const within = held.intersectSegment(Ops.segmentOf(scale, .contained), policy) catch unreachable;
                try std.testing.expect(std.meta.activeTag(within) == .contained);
                try std.testing.expect(within.contained == .second);
                const brushing = held.intersectSegment(Ops.segmentOf(scale, .tangent), policy) catch unreachable;
                try std.testing.expect(std.meta.activeTag(brushing) == .point);

                // Rays: a chord ahead of the origin and a run from an origin
                // inside the ball are both segments, and a ray whose origin IS
                // the touch point answers with that point.
                const ahead = held.intersectRay(Ops.rayOf(scale, .crossing_outside), policy) catch unreachable;
                try std.testing.expect(std.meta.activeTag(ahead) == .segment);
                const started_inside = held.intersectRay(Ops.rayOf(scale, .origin_inside), policy) catch unreachable;
                try std.testing.expect(std.meta.activeTag(started_inside) == .segment);
                const on_the_surface = held.intersectRay(Ops.rayOf(scale, .tangent), policy) catch unreachable;
                try std.testing.expect(std.meta.activeTag(on_the_surface) == .point);
            }
        }
    }
}

test "the signed-distance overflow row is the module's own NonFiniteResult on finite operands" {
    inline for (.{
        .{ g.Plane3f, g.Point3f, g.Segment3f, g.Sphere3f },
        .{ g.Plane3d, g.Point3d, g.Segment3d, g.Sphere3d },
        .{ g.Hyperplane4f, g.Point4f, g.Segment4f, g.Hypersphere4f },
        .{ g.Hyperplane4d, g.Point4d, g.Segment4d, g.Hypersphere4d },
    }) |family| {
        const Flat = family[0];
        const P = family[1];
        const dim = componentCount(P);
        const Ops = FlatOps(Flat, P, family[2], family[3]);
        const operands = Ops.overflowOperands();
        // The refusal has to be the arithmetic's and not a poisoned input:
        // both operands are finite and the normal is an exact unit axis.
        try std.testing.expect(operands.held.isFinite());
        try std.testing.expect(operands.point.isFinite());
        try std.testing.expectError(error.NonFiniteResult, operands.held.signedDistance(operands.point));

        // The control: the same point against a flat through the origin is
        // inside the format, so the refusal above is the subtraction's and not
        // a property of either operand.
        const at_origin = Flat{
            .origin = build(P, zeros(dim)),
            .normal = build(P, unitAxis(dim, 0)).toVector(),
        };
        const measured = at_origin.signedDistance(operands.point) catch unreachable;
        try std.testing.expect(std.math.isFinite(measured));
    }
}

test "the perturbed-ulp fixture fills exactly the extent each point declares" {
    inline for (.{
        g.Point2f, g.Point2d, g.Point3f, g.Point3d, g.Point4f, g.Point4d,
    }) |P| {
        for (0..8) |index| {
            var source = Source.begin(index);
            const rows = perturbedFixture(P, &source);
            // `build` narrows exactly `componentCount(P)` coordinates, so a
            // row wider than the point type would write past it and a narrower
            // one would leave its tail undefined. Both defects read here as a
            // point that is not wholly finite.
            for ([_]P{ rows.a, rows.b, rows.c, rows.d }) |held| {
                try std.testing.expect(held.isFinite());
            }
            // The row that consumes this fixture has to DECIDE rather than
            // refuse: `catch unreachable` is the whole assertion, because a
            // `NonFiniteResult` here would be a refused measurement.
            inline for (.{ g.PredicatePolicy.fast, g.PredicatePolicy.adaptive_exact }) |policy| {
                if (comptime componentCount(P) == 2) {
                    _ = P.orientation(rows.a, rows.b, rows.c, policy) catch unreachable;
                } else {
                    _ = P.orientation(rows.a, rows.b, rows.c, rows.d, policy) catch unreachable;
                }
            }
        }
    }
}

test "every box measure returns its own value for one box, in its own dimension" {
    inline for (.{
        .{ g.Aabb2f, g.Point2f },
        .{ g.Aabb2d, g.Point2d },
        .{ g.Aabb3f, g.Point3f },
        .{ g.Aabb3d, g.Point3d },
        .{ g.Aabb4f, g.Point4f },
        .{ g.Aabb4d, g.Point4d },
    }) |family| {
        const Ops = BoxOps(family[0], family[1]);
        for (0..scale_powers.len) |power| {
            const scale = scale_powers[power];
            // `measureBox` spans `3 * scale` on every axis, so each measure is
            // `(3 * scale)` to its own dimension's power, and the doubled
            // surface area is twice the sum of the three side products.
            const held = Ops.measureBox(scale);
            switch (comptime componentCount(family[1])) {
                2 => {
                    const area = @as(f64, held.area() catch unreachable);
                    try std.testing.expect(area == 9.0 * scale * scale);
                },
                3 => {
                    const volume = @as(f64, held.volume() catch unreachable);
                    try std.testing.expect(volume == 27.0 * scale * scale * scale);
                    const doubled = @as(f64, held.doubledSurfaceArea() catch unreachable);
                    try std.testing.expect(doubled == 54.0 * scale * scale);
                },
                else => {
                    const hyper = @as(f64, held.hyperVolume() catch unreachable);
                    try std.testing.expect(hyper == 81.0 * scale * scale * scale * scale);
                },
            }
        }
    }
}
