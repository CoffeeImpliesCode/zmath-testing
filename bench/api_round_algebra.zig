//! API benchmarking slice for `zmath.algebra`.
//!
//! Coverage contract: all twelve published concrete types (Cl3f, Cl3d, Cl4f,
//! Cl4d, Pga3f, Pga3d, Pga4f, Pga4d, Cga3f, Cga3d, Cga4f, Cga4d) and every
//! public method and factory each one declares. `src/algebra.zig` is not
//! touched: the coefficient layouts, the comptime product and dual tables, the
//! allocation policy and the operation graphs are exactly as they were.
//!
//! Fixtures come in four shapes, because the module's own contract turns on
//! them:
//!
//! - DENSE: every coefficient a runtime-derived value, so nothing is skipped
//!   by the zero test and the full coefficient-squared product loop runs.
//! - SPARSE: two or three nonzero coefficients at runtime-chosen masks. The
//!   zero-skip branch is the module's stated defence against a NaN, and this
//!   is the shape that exercises it.
//! - MOTOR: the scalar coefficient beside every grade-4 blade. That is the
//!   element `motorPart` extracts, the argument the `unitRotor` and
//!   `unitVersor` rows are stated against ("the caller establishes rotor
//!   membership"), and the source of the single-grade blade `unitFlat` is
//!   stated against. A basis of fewer than four vectors has no grade 4 at
//!   all, so the motor regime exists for ten of the twelve types and is
//!   classified, not skipped, for `Cl3f` and `Cl3d`.
//! - SINGLE-GRADE: one grade and nothing else, at a grade the runtime stream
//!   picks. That is the shape `unitRound` is stated against, and it is the
//!   receiver `unitFlat` sees in its dense row.
//!
//! Every `invoke` is `noinline`, consumes the runtime index, and returns the
//! protocol hash of the WHOLE result: every coefficient in ascending mask
//! order, plus a tag that separates a payload from `null`.
//!
//! A row whose arithmetic cannot depend on the runtime index at all carries a
//! `.folded_constant` suffix in its name: the constant factories `zero`,
//! `one`, `pseudoscalar`, `n_o`, `n_inf` and `origin`, and the static
//! declarations the `staticMetadata` row reads. Their result is a
//! materialization of a compile-time constant, so the only runtime work left
//! is the harness digest of it. Book those rows as harness overhead, not as
//! the numerical latency of the operation they name.
//!
//! Family-gated declarations are classified explicitly rather than invoked
//! blindly. `point` exists only on the projective family; `n_o`, `n_inf`,
//! `origin`, `embed` and `unitRound` exist only on the conformal family.
//! Each is a `@compileError` outside its family, so a generic call would be a
//! build failure rather than a measurement. The comptime gate below emits a
//! case only for the families that declare the entry point, and the inventory
//! at the foot of this file records the gate for the rest.
//!
//! f32 charge: `normalized` and the four unit factories that route through it
//! each reach `scalar.sqrtf` at most once, so each of those rows declares a
//! count of one: the upper bound its route can reach. `unitFlat` returns
//! before the square root when its receiver spans two grades, and `unitRound`
//! returns before it when the drawn grade is not `n - 1`. Every refusal row
//! returns `null` before the square root and charges nothing. Nothing else in
//! this module reaches an accepted f32 kernel, so every other row charges
//! nothing.

const std = @import("std");
const common = @import("api_round_common.zig");
const a = @import("zmath").algebra;

// ---------------------------------------------------------------------------
// Deterministic runtime input state
// ---------------------------------------------------------------------------

const unit_scale: f64 = 1.0 / 9007199254740992.0;

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

    fn unit(self: *Source) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) * unit_scale;
    }

    fn span(self: *Source, spread: f64) f64 {
        return (self.unit() * 2.0 - 1.0) * spread;
    }

    /// An index in `0..limit + 2`, so the out-of-range arms of `blade`,
    /// `grade` and `bladeValue` are reached as well as the in-range ones.
    fn below(self: *Source, limit: usize) usize {
        return @as(usize, @intCast(self.next() % @as(u64, @intCast(limit + 2))));
    }

    /// An index in `0..limit`. `below` deliberately reaches past `limit` so
    /// that the out-of-range arms of the accessors are exercised; a mask that
    /// is written into a coefficient array is not one of them.
    fn within(self: *Source, limit: usize) usize {
        return @as(usize, @intCast(self.next() % @as(u64, @intCast(@max(limit, 1)))));
    }

    /// A nonzero value, so a fixture built from it is never the zero
    /// multivector by accident.
    fn nonzero(self: *Source, spread: f64) f64 {
        const value = self.span(spread);
        return if (value == 0) spread * 0.5 else value;
    }
};

// ---------------------------------------------------------------------------
// Result digests
// ---------------------------------------------------------------------------

const present_tag: u64 = 0x165667b19e3779f9;
const absent_tag: u64 = 0x27d4eb2f165667c5;

fn present(value: anytype) u64 {
    return common.mix(common.hash(value), present_tag);
}

fn absent(index: usize) u64 {
    return common.mix(absent_tag, @as(u64, @intCast(index)));
}

/// A value that cannot fail.
fn digest(index: usize, value: anytype) u64 {
    return common.mix(common.hash(value), @as(u64, @intCast(index)));
}

/// An optional: a payload and a `null` never fold to the same value.
fn optional(index: usize, value: anytype) u64 {
    if (value) |held| return present(held);
    return absent(index);
}

/// Binds a comptime argument to one `invoke` pointer.
fn Bound(comptime Impl: type, comptime arg: anytype) type {
    return struct {
        fn run(index: usize) u64 {
            return Impl.run(index, arg);
        }
        fn runSparse(index: usize) u64 {
            return Impl.runSparse(index, arg);
        }
        fn runMotor(index: usize) u64 {
            return Impl.runMotor(index, arg);
        }
    };
}

// ---------------------------------------------------------------------------
// The public surface, one entry per declared method or factory
// ---------------------------------------------------------------------------

const Op = enum {
    // Construction and access.
    zero,
    one,
    pseudoscalar,
    blade,
    fromCoefficients,
    coefficients,
    setCoefficients,
    bladeValue,
    grade,
    scalarPart,
    isFinite,

    // Linear algebra.
    add,
    sub,
    neg,
    scale,
    evenPart,

    // Products.
    geometricProduct,
    wedge,
    inner,
    meet,
    dot,

    // Involutions.
    reverse,
    conjugate,
    dual,
    dualComplement,

    // Inversion and normalization.
    inverse,
    inverseChecked,
    norm,
    normalized,

    // Named multivector operations.
    unitRotor,
    unitVersor,
    unitFlat,
    motorPart,
    vectorPart,
    euclideanPart,

    /// The compile-time declarations of one concrete type, read once so the
    /// inventory has a positive entry for them. No accepted kernel is reached,
    /// so it charges nothing.
    staticMetadata,

    // Family-gated declarations.
    point,
    n_o,
    n_inf,
    origin,
    embed,
    unitRound,
};

/// True when the family that owns the type declares this entry point at all.
/// The three gates below are the module's own `@compileError`s, read here
/// rather than guessed at.
fn applicable(comptime family: a.Family, comptime op: Op) bool {
    return switch (op) {
        .point => family == .projective,
        .n_o, .n_inf, .origin, .embed, .unitRound => family == .conformal,
        else => true,
    };
}

fn methodName(comptime op: Op) []const u8 {
    return switch (op) {
        .zero => "zero",
        .one => "one",
        .pseudoscalar => "pseudoscalar",
        .blade => "blade",
        .fromCoefficients => "fromCoefficients",
        .coefficients => "coefficients",
        .setCoefficients => "setCoefficients",
        .bladeValue => "bladeValue",
        .grade => "grade",
        .scalarPart => "scalarPart",
        .isFinite => "isFinite",
        .add => "add",
        .sub => "sub",
        .neg => "neg",
        .scale => "scale",
        .evenPart => "evenPart",
        .geometricProduct => "geometricProduct",
        .wedge => "wedge",
        .inner => "inner",
        .meet => "meet",
        .dot => "dot",
        .reverse => "reverse",
        .conjugate => "conjugate",
        .dual => "dual",
        .dualComplement => "dualComplement",
        .inverse => "inverse",
        .inverseChecked => "inverseChecked",
        .norm => "norm",
        .normalized => "normalized",
        .unitRotor => "unitRotor",
        .unitVersor => "unitVersor",
        .unitFlat => "unitFlat",
        .motorPart => "motorPart",
        .vectorPart => "vectorPart",
        .euclideanPart => "euclideanPart",
        .staticMetadata => "staticMetadata",
        .point => "point",
        .n_o => "n_o",
        .n_inf => "n_inf",
        .origin => "origin",
        .embed => "embed",
        .unitRound => "unitRound",
    };
}

/// The operations whose cost turns on the zero-skip branch, and so are
/// measured over the sparse fixture as well as the dense one.
fn isSparseOp(comptime op: Op) bool {
    return switch (op) {
        .grade,
        .evenPart,
        .geometricProduct,
        .wedge,
        .inner,
        .meet,
        .dot,
        .reverse,
        .conjugate,
        .dual,
        .dualComplement,
        .inverse,
        .inverseChecked,
        .norm,
        .normalized,
        .unitRotor,
        .unitVersor,
        .unitFlat,
        .motorPart,
        => true,
        else => false,
    };
}

/// The operations whose answer and cost turn on the grade-4 coefficient being
/// present, so they are measured over the motor fixture as well as the dense
/// and the sparse one. `grade` is deliberately absent: it is indexed by a
/// grade the caller names, not by the shape of the receiver.
fn isMotorOp(comptime op: Op) bool {
    return switch (op) {
        .evenPart,
        .geometricProduct,
        .wedge,
        .inner,
        .meet,
        .dot,
        .reverse,
        .conjugate,
        .dual,
        .dualComplement,
        .inverse,
        .inverseChecked,
        .norm,
        .normalized,
        .unitRotor,
        .unitVersor,
        .unitFlat,
        .motorPart,
        => true,
        else => false,
    };
}

/// True when the basis of `A` has a grade 4 at all. `Cl3f` and `Cl3d` do not,
/// so their `motorPart` is `zero()` by the module's own definition and there
/// is no motor element for them to measure. They are classified rather than
/// silently skipped; see the inventory at the foot of this file.
fn hasMotorGrade(comptime A: type) bool {
    return A.basis_count >= 4;
}

/// The name suffix marking a row whose arithmetic cannot depend on the
/// runtime index at all. See the module header: those rows are harness
/// overhead, not the numerical latency of the operation they name.
fn foldedSuffix(comptime op: Op) []const u8 {
    return switch (op) {
        .zero, .one, .pseudoscalar, .staticMetadata, .n_o, .n_inf, .origin => ".folded_constant",
        else => "",
    };
}

/// The operations that reach `scalar.sqrtf`, at most once each, through
/// `normalized`.
fn isSqrtOp(comptime op: Op) bool {
    return switch (op) {
        .normalized, .unitRotor, .unitVersor, .unitFlat, .unitRound => true,
        else => false,
    };
}

/// One accepted `sqrtf` evaluation per invoke, the upper bound `normalized`
/// reaches and the one each unit factory inherits from it.
const sqrt_charge: []const common.Charge = &[_]common.Charge{.{ .operation = "sqrtf", .count = 1 }};
const no_charge: []const common.Charge = &.{};

// ---------------------------------------------------------------------------
// Coefficient helpers
// ---------------------------------------------------------------------------

/// The coefficient index of the grade-1 blade for Euclidean direction
/// `index`. The projective family leads its basis with the null vector, so
/// its directions start at bit one; the module states this rule and does not
/// publish the mask, so it is read here rather than invented.
fn bladeMask(comptime A: type, comptime index: usize) usize {
    return @as(usize, 1) << (if (A.family == .projective) index + 1 else index);
}

/// Every coefficient a runtime-derived value, in a regime-selected spread.
fn denseCoefficients(comptime A: type, source: *Source) [A.coefficient_count]A.element {
    const spread: f64 = switch (source.next() & 3) {
        0 => 2.0,
        1 => @as(f64, std.math.floatMin(A.element)) * 8.0,
        2 => @as(f64, std.math.floatMax(A.element)) * 0.125,
        else => 0.5,
    };
    var out: [A.coefficient_count]A.element = undefined;
    for (&out) |*slot| slot.* = @floatCast(source.span(spread));
    return out;
}

/// Two or three nonzero coefficients at runtime-chosen masks. Every mask is
/// inside `A.coefficient_count`, because a sparse multivector has no
/// coefficient outside that array and a write past the end would measure
/// whatever the next stack slot holds.
fn sparseCoefficients(comptime A: type, source: *Source) [A.coefficient_count]A.element {
    var out: [A.coefficient_count]A.element = @splat(0);
    const picks = 2 + (source.next() & 1);
    var written: usize = 0;
    while (written < picks) : (written += 1) {
        out[source.within(A.coefficient_count)] = @floatCast(source.nonzero(3.0));
    }
    return out;
}

/// One grade's worth of coefficients and nothing else. `gradeOf` counts the
/// set bits of a mask, which is what the module does.
fn singleGradeCoefficients(comptime A: type, source: *Source) [A.coefficient_count]A.element {
    var out: [A.coefficient_count]A.element = @splat(0);
    const chosen = source.below(A.basis_count + 1);
    for (0..A.coefficient_count) |mask| {
        if (@popCount(mask) == chosen) out[mask] = @floatCast(source.nonzero(2.0));
    }
    return out;
}

/// The scalar coefficient beside every grade-4 blade, which is the motor
/// element: the grade `4` part plus its scalar part, the shape `motorPart`
/// extracts and the `1 + b` rotor form `unitRotor` normalizes. Grade 4 is the
/// set-bit count of the mask, the same rule the module uses. A basis of fewer
/// than four vectors has no such mask, and `hasMotorGrade` keeps this
/// fixture out of that type's table entirely.
fn motorCoefficients(comptime A: type, source: *Source) [A.coefficient_count]A.element {
    var out: [A.coefficient_count]A.element = @splat(0);
    out[A.scalar_mask] = @floatCast(source.nonzero(2.0));
    for (0..A.coefficient_count) |mask| {
        if (@popCount(mask) == 4) out[mask] = @floatCast(source.nonzero(2.0));
    }
    return out;
}

// ---------------------------------------------------------------------------
// The per-type operation table
// ---------------------------------------------------------------------------

fn MultivectorOps(comptime A: type) type {
    return struct {
        const Self = @This();
        const T = A.element;
        const tag = @typeName(A);
        const dim = A.dimension;

        fn dense(source: *Source) A {
            return A.fromCoefficients(denseCoefficients(A, source));
        }

        fn sparse(source: *Source) A {
            return A.fromCoefficients(sparseCoefficients(A, source));
        }

        fn singleGrade(source: *Source) A {
            return A.fromCoefficients(singleGradeCoefficients(A, source));
        }

        /// Only reachable for a basis that has a grade 4; see
        /// `hasMotorGrade`.
        fn motor(source: *Source) A {
            return A.fromCoefficients(motorCoefficients(A, source));
        }

        /// The Euclidean component list, from the runtime stream.
        fn spatial(source: *Source) [dim]T {
            var out: [dim]T = undefined;
            for (&out) |*slot| slot.* = @floatCast(source.span(2.0));
            return out;
        }

        // ------------------------------------------------------------------
        // One entry point per declared method, over the dense fixture.
        // ------------------------------------------------------------------

        fn run(index: usize, comptime op: Op) u64 {
            var source = Source.begin(index);
            const left = dense(&source);
            const right = dense(&source);
            return switch (op) {
                .zero => digest(index, A.zero()),
                .one => digest(index, A.one()),
                .pseudoscalar => digest(index, A.pseudoscalar()),
                .blade => digest(index, A.blade(source.below(A.basis_count))),
                .fromCoefficients => digest(index, A.fromCoefficients(denseCoefficients(A, &source))),
                .coefficients => digest(index, left.coefficients()),
                .setCoefficients => digest(index, left.setCoefficients(denseCoefficients(A, &source))),
                .bladeValue => digest(index, left.bladeValue(source.below(A.coefficient_count))),
                .grade => digest(index, left.grade(source.below(A.grade_count))),
                .scalarPart => digest(index, left.scalarPart()),
                .isFinite => digest(index, left.isFinite()),
                .add => digest(index, left.add(right)),
                .sub => digest(index, left.sub(right)),
                .neg => digest(index, left.neg()),
                .scale => digest(index, left.scale(@floatCast(source.nonzero(2.0)))),
                .evenPart => digest(index, left.evenPart()),
                .geometricProduct => digest(index, left.geometricProduct(right)),
                .wedge => digest(index, left.wedge(right)),
                .inner => digest(index, left.inner(right)),
                .meet => digest(index, left.meet(right)),
                .dot => digest(index, left.dot(right)),
                .reverse => digest(index, left.reverse()),
                .conjugate => digest(index, left.conjugate()),
                .dual => digest(index, left.dual()),
                .dualComplement => digest(index, left.dualComplement()),
                .inverse => digest(index, left.inverse()),
                .inverseChecked => optional(index, left.inverseChecked()),
                .norm => digest(index, left.norm()),
                .normalized => optional(index, left.normalized()),
                .unitRotor => optional(index, A.unitRotor(right)),
                .unitVersor => optional(index, left.unitVersor()),
                .unitFlat => optional(index, singleGrade(&source).unitFlat()),
                .motorPart => digest(index, left.motorPart()),
                .vectorPart => digest(index, left.vectorPart()),
                .euclideanPart => digest(index, A.euclideanPart(left)),
                // Every field is coerced to a type `common.hash` covers.
                // `element` is a type and `common.hash` refuses a value it
                // cannot take a semantic address of; `scalar_mask` and
                // `storage_bytes` are `comptime_int` in the module, which its
                // nested-field fold rejects as well. `Sqrt` and `IsFinite`
                // are the module's own `@compileError` on anything but `f32`
                // and `f64`, so the coefficient width identifies the element
                // type exactly.
                .staticMetadata => digest(index, .{
                    @as(usize, @sizeOf(A.element)),
                    A.basis_count,
                    A.coefficient_count,
                    @as(usize, A.scalar_mask),
                    A.pseudoscalar_mask,
                    A.grade_count,
                    A.dimension,
                    A.family,
                    A.metric,
                    A.pseudoscalar_square,
                    A.dual_square,
                    @as(usize, A.storage_bytes),
                }),
                .point => if (comptime A.family == .projective)
                    digest(index, A.point(spatial(&source)))
                else
                    0,
                .n_o => if (comptime A.family == .conformal)
                    digest(index, A.n_o())
                else
                    0,
                .n_inf => if (comptime A.family == .conformal)
                    digest(index, A.n_inf())
                else
                    0,
                .origin => if (comptime A.family == .conformal)
                    digest(index, A.origin())
                else
                    0,
                .embed => if (comptime A.family == .conformal)
                    digest(index, A.embed(spatial(&source)))
                else
                    0,
                .unitRound => if (comptime A.family == .conformal)
                    optional(index, singleGrade(&source).unitRound())
                else
                    0,
            };
        }

        /// The same entry point over the sparse fixture, where the zero-skip
        /// branch is live.
        fn runSparse(index: usize, comptime op: Op) u64 {
            var source = Source.begin(index);
            const left = sparse(&source);
            const right = sparse(&source);
            return switch (op) {
                .grade => digest(index, left.grade(source.below(A.grade_count))),
                .evenPart => digest(index, left.evenPart()),
                .geometricProduct => digest(index, left.geometricProduct(right)),
                .wedge => digest(index, left.wedge(right)),
                .inner => digest(index, left.inner(right)),
                .meet => digest(index, left.meet(right)),
                .dot => digest(index, left.dot(right)),
                .reverse => digest(index, left.reverse()),
                .conjugate => digest(index, left.conjugate()),
                .dual => digest(index, left.dual()),
                .dualComplement => digest(index, left.dualComplement()),
                .inverse => digest(index, left.inverse()),
                .inverseChecked => optional(index, left.inverseChecked()),
                .norm => digest(index, left.norm()),
                .normalized => optional(index, left.normalized()),
                .unitRotor => optional(index, A.unitRotor(right)),
                .unitVersor => optional(index, left.unitVersor()),
                .unitFlat => optional(index, left.unitFlat()),
                .motorPart => digest(index, left.motorPart()),
                else => unreachable,
            };
        }

        /// The same entry point over the motor fixture, where the scalar and
        /// the grade-4 blades are the only nonzero coefficients. Only
        /// reachable for a basis that has a grade 4.
        fn runMotor(index: usize, comptime op: Op) u64 {
            var source = Source.begin(index);
            const left = motor(&source);
            const right = motor(&source);
            return switch (op) {
                .evenPart => digest(index, left.evenPart()),
                .geometricProduct => digest(index, left.geometricProduct(right)),
                .wedge => digest(index, left.wedge(right)),
                .inner => digest(index, left.inner(right)),
                .meet => digest(index, left.meet(right)),
                .dot => digest(index, left.dot(right)),
                .reverse => digest(index, left.reverse()),
                .conjugate => digest(index, left.conjugate()),
                .dual => digest(index, left.dual()),
                .dualComplement => digest(index, left.dualComplement()),
                .inverse => digest(index, left.inverse()),
                .inverseChecked => optional(index, left.inverseChecked()),
                .norm => digest(index, left.norm()),
                .normalized => optional(index, left.normalized()),
                // `1 + motor` is exactly the `1 + b` rotor form the module
                // asks the caller to establish before calling this.
                .unitRotor => optional(index, A.unitRotor(left)),
                // A motor is even, so its even part is the motor itself: this
                // is the versor membership the caller has to establish.
                .unitVersor => optional(index, left.unitVersor()),
                // The motor spans two grades and `unitFlat` refuses that, so
                // the blade it is stated against is the grade-4 half.
                .unitFlat => optional(index, left.motorPart().unitFlat()),
                .motorPart => digest(index, left.motorPart()),
                else => unreachable,
            };
        }

        // ------------------------------------------------------------------
        // Refusal paths and stated preconditions
        // ------------------------------------------------------------------

        /// `normalized` refuses a zero or negative norm.
        noinline fn normalizedZero(index: usize) u64 {
            return optional(index, A.zero().normalized());
        }

        /// A pure pseudoscalar-grade value. Its squared norm is negative
        /// exactly where the metric admits a negative square, which is the
        /// negative-norm refusal; where it is not, the hash records the value
        /// the module actually returns for that member.
        noinline fn normalizedPseudoscalar(index: usize) u64 {
            var value = A.zero();
            value.c[A.pseudoscalar_mask] = @as(T, 1);
            return optional(index, value.normalized());
        }

        /// `normalized` refuses a non-finite coefficient before it looks at
        /// the norm.
        noinline fn normalizedPoisoned(index: usize) u64 {
            var value = A.one();
            value.c[bladeMask(A, 0)] = std.math.inf(T);
            return optional(index, value.normalized());
        }

        /// `inverseChecked` refuses a non-finite coefficient.
        noinline fn inverseCheckedPoisoned(index: usize) u64 {
            var value = A.one();
            value.c[bladeMask(A, 0)] = std.math.nan(T);
            return optional(index, value.inverseChecked());
        }

        /// `inverseChecked` refuses a zero sandwich scalar, which is what an
        /// odd-only blade leaves behind: its even Clifford conjugate is zero.
        noinline fn inverseCheckedOdd(index: usize) u64 {
            var value = A.zero();
            value.c[bladeMask(A, 0)] = @as(T, 2);
            return optional(index, value.inverseChecked());
        }

        /// A grade-2 blade beside a grade-1 blade. The even Clifford
        /// conjugate keeps only the grade-2 part, so the sandwich product is
        /// that blade squared: the scalar `+1` where the blade is spacelike,
        /// and exactly `0` on a projective basis, whose leading vector is
        /// null. `inverseChecked` therefore refuses on the four projective
        /// types and accepts on the other eight; the row records the answer
        /// each type gives rather than the expectation.
        noinline fn inverseCheckedResidue(index: usize) u64 {
            var value = A.zero();
            value.c[@as(usize, 3)] = @as(T, 1);
            value.c[@as(usize, 2)] = @as(T, 1);
            return optional(index, value.inverseChecked());
        }

        /// The unguarded `inverse` on that same odd-only blade. The module
        /// states this is not a general inverse; the hash records what it
        /// actually produces.
        noinline fn inverseOdd(index: usize) u64 {
            var value = A.zero();
            value.c[bladeMask(A, 0)] = @as(T, 2);
            return digest(index, value.inverse());
        }

        /// `unitFlat` refuses a value spanning more than one grade.
        noinline fn unitFlatMixed(index: usize) u64 {
            var value = A.zero();
            value.c[A.scalar_mask] = @as(T, 1);
            value.c[bladeMask(A, 0)] = @as(T, 1);
            return optional(index, value.unitFlat());
        }

        /// `unitFlat` refuses a value with no nonzero coefficient.
        noinline fn unitFlatEmpty(index: usize) u64 {
            return optional(index, A.zero().unitFlat());
        }

        /// `unitRotor` normalizes the even part of `1 + b`. The argument below
        /// is `b = -1 + e` for the first basis blade `e`, so `1 + b` is that
        /// bare grade-1 blade, whose even part is zero and whose normalizer
        /// therefore refuses.
        noinline fn unitRotorEvenPartZero(index: usize) u64 {
            var value = A.zero();
            value.c[A.scalar_mask] = -@as(T, 1);
            value.c[bladeMask(A, 0)] = @as(T, 1);
            return optional(index, A.unitRotor(value));
        }

        /// `unitVersor` normalizes the even part of its receiver, so an odd
        /// receiver is the refusal: the even part is zero.
        noinline fn unitVersorOdd(index: usize) u64 {
            var value = A.zero();
            value.c[bladeMask(A, 0)] = @as(T, 1);
            return optional(index, value.unitVersor());
        }

        /// `unitRound` normalizes the grade `n - 1` part, so a receiver with
        /// none is the refusal. Conformal families only.
        noinline fn unitRoundEmpty(index: usize) u64 {
            return optional(index, A.one().unitRound());
        }

        fn refusal(name: []const u8, entry: *const fn (usize) u64) common.Case {
            return .{ .name = name, .namespace = "algebra", .invoke = entry };
        }

        fn cases() [count]common.Case {
            var list: [count]common.Case = undefined;
            var slot: usize = 0;
            inline for (std.meta.fields(Op)) |field| {
                const op: Op = @enumFromInt(field.value);
                if (comptime applicable(A.family, op)) {
                    list[slot] = .{
                        .name = tag ++ "." ++ methodName(op) ++ foldedSuffix(op),
                        .namespace = "algebra",
                        .invoke = Bound(Self, op).run,
                        .f32 = if (comptime isSqrtOp(op) and T == f32) sqrt_charge else no_charge,
                    };
                    slot += 1;
                    if (comptime isSparseOp(op)) {
                        list[slot] = .{
                            .name = tag ++ "." ++ methodName(op) ++ ".sparse",
                            .namespace = "algebra",
                            .invoke = Bound(Self, op).runSparse,
                            .f32 = if (comptime isSqrtOp(op) and T == f32) sqrt_charge else no_charge,
                        };
                        slot += 1;
                    }
                    if (comptime isMotorOp(op) and hasMotorGrade(A)) {
                        list[slot] = .{
                            .name = tag ++ "." ++ methodName(op) ++ ".motor",
                            .namespace = "algebra",
                            .invoke = Bound(Self, op).runMotor,
                            .f32 = if (comptime isSqrtOp(op) and T == f32) sqrt_charge else no_charge,
                        };
                        slot += 1;
                    }
                }
            }
            list[slot] = refusal(tag ++ ".normalized.zero_norm", &Self.normalizedZero);
            slot += 1;
            list[slot] = refusal(tag ++ ".normalized.pseudoscalar_grade", &Self.normalizedPseudoscalar);
            slot += 1;
            list[slot] = refusal(tag ++ ".normalized.nonfinite_coefficient", &Self.normalizedPoisoned);
            slot += 1;
            list[slot] = refusal(tag ++ ".inverseChecked.nonfinite_coefficient", &Self.inverseCheckedPoisoned);
            slot += 1;
            list[slot] = refusal(tag ++ ".inverseChecked.zero_sandwich", &Self.inverseCheckedOdd);
            slot += 1;
            list[slot] = refusal(tag ++ ".inverseChecked.mixed_grade_sandwich", &Self.inverseCheckedResidue);
            slot += 1;
            list[slot] = refusal(tag ++ ".inverse.odd_only_blade", &Self.inverseOdd);
            slot += 1;
            list[slot] = refusal(tag ++ ".unitFlat.mixed_grades", &Self.unitFlatMixed);
            slot += 1;
            list[slot] = refusal(tag ++ ".unitFlat.no_coefficient", &Self.unitFlatEmpty);
            slot += 1;
            list[slot] = refusal(tag ++ ".unitRotor.zero_even_part", &Self.unitRotorEvenPartZero);
            slot += 1;
            list[slot] = refusal(tag ++ ".unitVersor.odd_receiver", &Self.unitVersorOdd);
            slot += 1;
            if (comptime A.family == .conformal) {
                list[slot] = refusal(tag ++ ".unitRound.no_grade_n_minus_1", &Self.unitRoundEmpty);
                slot += 1;
            }
            return list;
        }

        /// The unconditional entries, plus the sparse doubles, plus the motor
        /// doubles on the types that have a grade 4, plus this family's gated
        /// declarations, plus the refusal paths.
        const count = blk: {
            var total: usize = 0;
            for (std.meta.fields(Op)) |field| {
                const op: Op = @enumFromInt(field.value);
                if (applicable(A.family, op)) {
                    total += 1;
                    if (isSparseOp(op)) total += 1;
                    if (isMotorOp(op) and hasMotorGrade(A)) total += 1;
                }
            }
            total += 11;
            if (A.family == .conformal) total += 1;
            break :blk total;
        };
    };
}

// ---------------------------------------------------------------------------
// The exported case list
// ---------------------------------------------------------------------------

pub const cases = blk: {
    @setEvalBranchQuota(10_000_000);
    break :blk [_]common.Case{} ++
        // The Euclidean Clifford algebras: no family-gated declaration. `Cl3f` and
        // `Cl3d` additionally have a basis of three vectors, so there is no grade
        // 4 and no motor regime for them.
        MultivectorOps(a.Cl3f).cases() ++
        MultivectorOps(a.Cl3d).cases() ++
        MultivectorOps(a.Cl4f).cases() ++
        MultivectorOps(a.Cl4d).cases() ++

        // The projective algebras, which additionally declare `point`.
        MultivectorOps(a.Pga3f).cases() ++
        MultivectorOps(a.Pga3d).cases() ++
        MultivectorOps(a.Pga4f).cases() ++
        MultivectorOps(a.Pga4d).cases() ++

        // The conformal algebras, which additionally declare `n_o`, `n_inf`,
        // `origin`, `embed` and `unitRound`.
        MultivectorOps(a.Cga3f).cases() ++
        MultivectorOps(a.Cga3d).cases() ++
        MultivectorOps(a.Cga4f).cases() ++
        MultivectorOps(a.Cga4d).cases();
};

// ---------------------------------------------------------------------------
// Inventory: every declared public callable of `src/algebra.zig`
//
// 1000 cases in total. Per concrete type: 66 for `Cl3f` and `Cl3d`, 84 for
// `Cl4f` and `Cl4d`, 85 for each of the four projective types, and 90 for each
// of the four conformal types. `Cl3f` and `Cl3d` carry 18 fewer than `Cl4f`
// and `Cl4d` because a basis of three vectors has no grade 4, so there is no
// motor element and no motor regime for them.
//
// TIMED DIRECTLY, on all twelve concrete types
//
// Construction and access: `zero`, `one`, `pseudoscalar`, `blade` (with the
// index drawn from a range that reaches the out-of-range arm),
// `fromCoefficients`, `coefficients`, `setCoefficients`, `bladeValue`, `grade`
// (same, with the out-of-range arm), `scalarPart`, `isFinite`.
//
// Linear algebra: `add`, `sub`, `neg`, `scale`, `evenPart`.
//
// Products: `geometricProduct`, `wedge`, `inner`, `meet`, `dot`.
//
// Involutions: `reverse`, `conjugate`, `dual`, `dualComplement`.
//
// Inversion and normalization: `inverse`, `inverseChecked`, `norm`,
// `normalized`.
//
// Named multivector operations: `unitRotor`, `unitVersor`, `unitFlat`,
// `motorPart`, `vectorPart`, `euclideanPart`.
//
// REGIMES
//
// - DENSE, one row per applicable entry point on every type. Every
//   coefficient is a runtime-derived value, so no row is skipped by the zero
//   test and the full coefficient-squared product loop runs.
// - SPARSE, a second row for the nineteen operations whose cost turns on the
//   zero-skip branch: `grade`, `evenPart`, `geometricProduct`, `wedge`,
//   `inner`, `meet`, `dot`, `reverse`, `conjugate`, `dual`, `dualComplement`,
//   `inverse`, `inverseChecked`, `norm`, `normalized`, `unitRotor`,
//   `unitVersor`, `unitFlat`, `motorPart`. Two or three coefficients are
//   nonzero, at masks the runtime stream picks. That is the shape the
//   module's skip exists for, and it is the shape that proves the skip.
// - MOTOR, a third row for the eighteen of those nineteen whose answer and
//   cost turn on the grade-4 coefficient, on the ten types that have one. The
//   fixture is the scalar beside every grade-4 blade: the element
//   `motorPart` extracts, the `1 + b` rotor form `unitRotor` normalizes, the
//   even element `unitVersor` normalizes, and the source of the single-grade
//   blade `unitFlat` is stated against. `grade` is not in this set: it is
//   indexed by a grade the caller names, not by the shape of the receiver.
// - SINGLE-GRADE, used inside the dense rows rather than as a regime of its
//   own, because only two entry points take it: `unitFlat` and `unitRound`.
//   The grade is drawn from the runtime stream over a range that reaches the
//   grade-above-`n` arm, which is the all-zero receiver.
//
// MOTOR REGIME, CLASSIFIED WHERE IT DOES NOT EXIST
//
// `Cl3f` and `Cl3d` are the two types with no grade 4. The module defines
// `motorPart` as the grade-4 part and states that it is `zero()` for a basis
// that has no grade 4, so on those two types there is no motor element to
// normalize, to invert, or to extract, and the eighteen motor rows are not
// instantiated for them. That is a property of the basis, not an omission:
// `motorPart` itself is still timed on all twelve types, over the dense and
// the sparse fixture, where it answers `zero()`.
//
// REFUSAL PATHS AND STATED PRECONDITIONS, on all twelve concrete types
//
// - `normalized` with a zero norm, with a pure pseudoscalar-grade value (whose
//   squared norm is negative exactly where the metric admits a negative
//   square, and zero where the pseudoscalar is null), and with a non-finite
//   coefficient.
// - `inverseChecked` with a non-finite coefficient, with an odd-only blade
//   (zero sandwich scalar), and with a grade-2 blade beside a grade-1 blade.
//   That last receiver squares its own even Clifford conjugate to `+1` on a
//   spacelike basis and to exactly `0` on a projective basis, so the row
//   refuses on the four projective types and accepts on the other eight. It
//   records the answer each type gives, not the expectation.
// - `inverse` with that same odd-only blade: the module states this is not a
//   general multivector inverse, and the case hashes what it actually
//   produces, which is a non-finite answer on every type.
// - `unitFlat` with a value spanning two grades, and with no nonzero
//   coefficient.
// - `unitRotor` with an argument whose even part cancels to zero.
// - `unitVersor` with an odd receiver, whose even part is zero.
// - `unitRound` with a receiver carrying no grade `n - 1` blade, on the four
//   conformal types.
//
// The module reports every failure as `null` and never as an error union, so
// the "error state" each of these rows carries is optional presence, and the
// digest folds both the presence tag and the whole payload.
//
// FAMILY-GATED DECLARATIONS, CLASSIFIED AND NOT CALLED BLINDLY
//
// - `point` is declared only by the projective family; on a Clifford or
//   conformal type it is a `@compileError`. It is timed on `Pga3f`, `Pga3d`,
//   `Pga4f` and `Pga4d`, and it is not instantiated for the other eight.
// - `n_o`, `n_inf`, `origin` and `embed` are declared only by the conformal
//   family, for the same reason. They are timed on `Cga3f`, `Cga3d`, `Cga4f`
//   and `Cga4d` only. `origin` is `n_o`, and `embed` is the embedding of a
//   Euclidean vector, so all three are exercised with the runtime coordinates
//   they take.
// - `unitRound` is declared only by the conformal family, for the same reason.
//
// The gate is the module's own `@compileError`, read into `applicable` rather
// than guessed at, and a prong whose family gate is closed is never analyzed:
// the entry point is not called, so a build failure is never mistaken for a
// measurement.
//
// STATIC DECLARATIONS
//
// `element`, `basis_count`, `coefficient_count`, `scalar_mask`,
// `pseudoscalar_mask`, `grade_count`, `dimension`, `family`, `metric`,
// `pseudoscalar_square`, `dual_square` and `storage_bytes` are compile-time
// declarations of each concrete type. Each type's `staticMetadata` case reads
// all twelve once, so the inventory has a positive entry for them. Reaching
// them calls no kernel, so they charge nothing, exactly as the protocol
// requires of a static inventory. `element` is a type rather than a value,
// and `common.hash` refuses a value it cannot take a semantic address of, so
// the row records the width of the coefficient instead; `Sqrt` and `IsFinite`
// are the module's own `@compileError` on anything but `f32` and `f64`, so
// that width identifies the element type exactly.
//
// MODULE-LEVEL EXPORTS
//
// - `Family`, the three-valued enum `clifford`, `projective`, `conformal`,
//   gates every row above and is hashed as a tag by `staticMetadata`.
// - The twelve published types, `Cl3f`, `Cl3d`, `Cl4f`, `Cl4d`, `Pga3f`,
//   `Pga3d`, `Pga4f`, `Pga4d`, `Cga3f`, `Cga3d`, `Cga4f` and `Cga4d`, are the
//   twelve types this file builds its tables from. Each is a distinct
//   instantiation of the module's private `Multivector`, so each publishes
//   the surface inventoried above with its own coefficient count, metric and
//   comptime tables.
// - The public field `c`, the coefficient array indexed by ascending blade
//   mask, is storage rather than an entry point: no row calls it. It is read
//   directly only to build the refusal fixtures above, and `coefficients` and
//   `setCoefficients` are the two published accessors that do the same work
//   through the interface.
//
// SHARED DECLARATIONS, NOT SEPARATE ENTRY POINTS
//
// - `euclideanPart` is `pub const euclideanPart = vectorPart`: one map under
//   two names. Both names are timed, each through the name it is published
//   under.
// - `unitRotor` and `unitVersor` are each one call to `normalized` on an
//   even part. They are timed directly, and their refusal paths are timed
//   directly too, so nothing rests on the shared route alone.
//
// FOLDED CONSTANT ROWS: HARNESS OVERHEAD, NOT NUMERICAL LATENCY
//
// Sixty rows carry a `.folded_constant` suffix in their name: `zero`, `one`,
// `pseudoscalar` and `staticMetadata` on all twelve types (48), plus `n_o`,
// `n_inf` and `origin` on the four conformal types (12). Their arithmetic
// cannot depend on the runtime index, so the result is a materialization of
// a compile-time constant and the only runtime work left is the harness
// digest of it -- for the widest type, a fold over a 64-coefficient array
// that measures the checksum and not the algebra. Book those rows as
// overhead. They are kept in the table rather than dropped, because they are
// declared public entry points and the inventory owes them a positive entry;
// the suffix is what tells the reader not to read a latency into them.
//
// CHARGE
//
// `normalized` reaches `scalar.sqrtf` at most once, and `unitRotor`,
// `unitVersor`, `unitFlat` and `unitRound` each inherit that single
// evaluation. Those five entries are the only ones that reach an accepted f32
// kernel, at a count of one per invoke, which is the upper bound the route
// can reach rather than a claim that every invoke takes it: `unitFlat`
// returns before the square root when its receiver spans two grades, and
// `unitRound` returns before it when the drawn grade is not `n - 1`. Every
// refusal row returns `null` before the square root, so it charges nothing.
// Every other operation in this module is plain IEEE arithmetic or an integer
// fold over the comptime tables, and charges nothing. The `f64` reciprocal
// goes through `scalar_div.div64`, which is not an accepted kernel, so it is
// never charged either.
