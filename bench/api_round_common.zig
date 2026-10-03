//! Shared protocol for the zmath API benchmarking round.
//!
//! Every case slice (`api_round_leaf.zig`, `api_round_lanes.zig`,
//! `api_round_values.zig`, `api_round_aggregates.zig`,
//! `api_round_geometry.zig`, `api_round_algebra.zig`) imports this file
//! relative to the `bench` build root directory and publishes
//! `pub const cases = [_]common.Case{...}`. The round executable
//! (`api_round.zig`) owns the selection, timing and JSONL protocol; nothing
//! in this file measures anything.
//!
//! Two rules make a round comparable:
//!
//! 1. `hash` is a semantic checksum, not a proof. It folds every semantic
//!    field of a result -- float bit patterns, integers, booleans, struct
//!    fields, enum tags, tagged-union payloads, array and vector lanes,
//!    optional presence and error-union discriminants -- and never touches
//!    struct padding, an address, or any other value the language leaves
//!    undefined. Two builds that agree on every hashed field produce the
//!    same `u64`. Two builds that differ in a hashed field almost certainly
//!    produce different ones, but the fold lands in 64 bits, so a collision
//!    is possible and remains a residual risk. Agreement between a baseline
//!    and a candidate across a sampled case set is evidence of semantic
//!    equality over that set; it is not a bitwise whole-domain proof, and it
//!    is not one. The fold is order-sensitive: fields enter in declaration
//!    order and lanes in lane order, so a result that spells the same values
//!    in a different field or lane order is a different checksum.
//! 2. `Charge` is the profiling budget. `operation` is the VERBATIM public
//!    name of one accepted kernel, so the root generic `zmath.exp(f32)`, the
//!    suffixed `zmath.scalar.expf`, and the `@Vector` route all key the same
//!    global ledger entry. `count` is how many times one `invoke` call reaches
//!    that kernel; the caller multiplies by `Case.calls` and by its own
//!    repetition count. Nothing here interprets the name.
//!
//! Every branch that has to destructure a runtime value lives in its own
//! generic helper. Zig analyzes a generic body only at the instantiation that
//! calls it, so `hash` rejects an unsupported shape by compile error at the
//! one call site that uses it, rather than at every call site.

const std = @import("std");

/// One accepted-kernel budget entry for one `invoke` call.
///
/// `operation` is the verbatim public name of the accepted kernel reached,
/// never a module path and never a family name. Plain IEEE arithmetic, bit
/// manipulation and comparison are not accepted kernels and carry no entry.
/// A wrapper that reaches an accepted kernel through its own body is charged
/// the kernel's name, so a binary16 or narrowing wrapper that really does call
/// a binary32 kernel is charged that binary32 kernel.
pub const Charge = struct {
    /// Verbatim public name of the accepted kernel.
    operation: []const u8,
    /// Accepted-kernel evaluations per ONE `invoke` call.
    count: u32,
};

/// One timed entry point.
///
/// `namespace` names the canonical public owner of the entry point under
/// test: `root`, `ieee`, `scalar`, `vector`, `complex`, `quaternion`,
/// `matrix`, `linalg`, `geometry` or `algebra`. It is not the bundle file the
/// case happens to live in, and `zmath.exp(f32)` is a `root` case while
/// `zmath.scalar.expf` is a `scalar` case even though both reach `expf`.
/// `name` is globally unique across all six bundles.
pub const Case = struct {
    /// Globally unique identifier naming bundle, operation, type, shape and
    /// input policy.
    name: []const u8,
    /// Canonical public owner of the entry point under test.
    namespace: []const u8,
    /// `noinline` body that consumes a varying deterministic runtime index and
    /// returns `hash` of every semantic result field.
    invoke: *const fn (usize) u64,
    /// Fixed invocation count per measurement. There is no adaptive warm-up:
    /// the count is part of the protocol, not a tuned loop trip count.
    calls: u32 = 32,
    /// Accepted binary32 kernels reached per `invoke` call. An entry point
    /// that reaches no binary32 kernel leaves this defaulted.
    f32: []const Charge = &.{},
};

/// The canonical public owners a `Case.namespace` may name.
pub const namespaces = [_][]const u8{
    "root",
    "ieee",
    "scalar",
    "vector",
    "complex",
    "quaternion",
    "matrix",
    "linalg",
    "geometry",
    "algebra",
};

pub const hash_seed: u64 = 0xcbf2_9ce4_8422_2325;

/// Folds the running state `a` and the next folded value `b` into one `u64`.
///
/// State and payload have different roles. The asymmetric hash-combine step
/// treats their order as significant, unlike a plain sum.
/// SplitMix64 then distributes the output bits. All arithmetic wraps and
/// requires no allocation. For fixed state, distinct payloads give distinct
/// checksums. Other combinations can still collide.
pub fn mix(a: u64, b: u64) u64 {
    var mixed = a ^ (b +% 0x9e37_79b9_7f4a_7c15 +% (a << 6) +% (a >> 2));
    mixed = (mixed ^ (mixed >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    mixed = (mixed ^ (mixed >> 27)) *% 0x94d0_49bb_1331_11eb;
    return mixed ^ (mixed >> 31);
}

/// True when `value` is one of the canonical public owners.
pub fn isNamespace(value: []const u8) bool {
    for (namespaces) |candidate| {
        if (std.mem.eql(u8, candidate, value)) return true;
    }
    return false;
}

/// True when `value` is a usable `Charge.operation`: non-empty and free of the
/// characters that would make two distinct kernels share one ledger key or
/// break the JSONL protocol.
pub fn isChargeOperation(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        const plain = (byte >= 'A' and byte <= 'Z') or
            (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9');
        if (!plain and byte != '_') return false;
    }
    return true;
}

/// Hashes `value` over its semantic content only.
///
/// Two values that agree on every hashed field hash identically. Two that
/// differ in a hashed field differ with overwhelming probability, not with
/// certainty: the result is 64 bits wide, so a collision remains possible and
/// is a residual risk of this design rather than a property it guarantees.
/// Callers therefore read a matching checksum across a sampled case set as
/// evidence of semantic equality over that set, never as a bitwise
/// whole-domain proof.
///
/// Unsupported types are a compile error, never a silent zero: a benchmark
/// whose checksum quietly ignored a field would compare equal across a
/// behaviour change.
pub fn hash(value: anytype) u64 {
    const raw = @TypeOf(value);
    // `comptime_int` and `comptime_float` have no addressable runtime type, so
    // they widen to one first. A slice owner that passes a bare literal still
    // gets a real hash instead of a compile error.
    if (@typeInfo(raw) == .comptime_int) {
        const typed: u64 = value;
        return hashValue(u64, &typed, hash_seed);
    }
    if (@typeInfo(raw) == .comptime_float) {
        const typed: f64 = value;
        return hashValue(f64, &typed, hash_seed);
    }
    return hashValue(raw, &value, hash_seed);
}

fn hashValue(comptime T: type, ptr: *const T, seed: u64) u64 {
    const info = @typeInfo(T);
    return switch (info) {
        .void => mix(seed, 0x9e37_79b9_7f4a_7c15),
        .bool => mix(seed, @intFromBool(ptr.*)),
        .int => hashInt(T, ptr.*, seed),
        .float => hashFloat(T, ptr.*, seed),
        .@"enum" => hashEnum(T, ptr, seed),
        .@"struct" => hashStruct(T, ptr, seed),
        .@"union" => hashUnion(T, ptr, seed),
        .array => hashArray(T, ptr, seed),
        .vector => hashVector(T, ptr, seed),
        .optional => hashOptional(T, ptr, seed),
        .error_union => hashErrorUnion(T, ptr, seed),
        .error_set => hashText(seed, @errorName(ptr.*)),
        .pointer => hashSlice(T, ptr, seed),
        else => @compileError(
            "api_round_common.hash does not cover this type: " ++ @typeName(T),
        ),
    };
}

fn hashStruct(comptime T: type, ptr: *const T, seed: u64) u64 {
    var acc = seed;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        acc = if (comptime field.is_comptime)
            // A `comptime` field has no runtime address to take.
            hashByValue(field.type, @field(ptr.*, field.name), acc)
        else
            hashValue(field.type, &@field(ptr.*, field.name), acc);
    }
    return acc;
}

fn hashArray(comptime T: type, ptr: *const T, seed: u64) u64 {
    var acc = mix(seed, @as(u64, @typeInfo(T).array.len));
    inline for (0..@typeInfo(T).array.len) |index| {
        const element: @typeInfo(T).array.child = ptr.*[index];
        acc = hashValue(@typeInfo(T).array.child, &element, acc);
    }
    return acc;
}

fn hashVector(comptime T: type, ptr: *const T, seed: u64) u64 {
    var acc = mix(seed, @typeInfo(T).vector.len);
    inline for (0..@typeInfo(T).vector.len) |index| {
        const lane: @typeInfo(T).vector.child = ptr.*[index];
        acc = hashValue(@typeInfo(T).vector.child, &lane, acc);
    }
    return acc;
}

fn hashOptional(comptime T: type, ptr: *const T, seed: u64) u64 {
    if (ptr.*) |payload| {
        return hashValue(@typeInfo(T).optional.child, &payload, mix(seed, 1));
    }
    return mix(seed, 0);
}

fn hashErrorUnion(comptime T: type, ptr: *const T, seed: u64) u64 {
    const value = ptr.*;
    if (value) |payload| {
        return hashValue(@typeInfo(T).error_union.payload, &payload, mix(seed, 1));
    } else |failure| {
        return hashText(mix(seed, 0), @errorName(failure));
    }
}

/// A slice is hashed by length and then by element. A single pointer carries
/// an address, which is not a semantic value, so it is a compile error rather
/// than a checksum that changes on every run.
fn hashSlice(comptime T: type, ptr: *const T, seed: u64) u64 {
    if (@typeInfo(T).pointer.size != .slice) {
        @compileError(
            "api_round_common.hash refuses a pointer: a hashed value must not contain an address",
        );
    }
    var acc = mix(seed, @as(u64, ptr.*.len));
    for (ptr.*) |*element| acc = hashValue(@typeInfo(T).pointer.child, element, acc);
    return acc;
}

fn hashUnion(comptime T: type, ptr: *const T, seed: u64) u64 {
    if (@typeInfo(T).@"union".tag_type == null) {
        @compileError(
            "api_round_common.hash refuses an untagged union: it has no semantic value",
        );
    }
    return hashTagged(T, ptr, mix(seed, hashText(seed, @tagName(ptr.*))));
}

/// Enums hash their integer tag. Tagged unions use the separate payload path.
fn hashEnum(comptime T: type, ptr: *const T, seed: u64) u64 {
    return hashInt(@typeInfo(T).@"enum".tag_type, @intFromEnum(ptr.*), seed);
}

/// Hashes the active payload of a tagged union. The tag name
/// is already folded into `seed`, so two fields that share a payload type
/// still hash apart.
fn hashTagged(comptime T: type, ptr: *const T, seed: u64) u64 {
    return switch (ptr.*) {
        inline else => |payload| hash: {
            const Payload = @TypeOf(payload);
            if (comptime Payload == void) break :hash seed;
            break :hash hashValue(Payload, &payload, seed);
        },
    };
}

/// Converts comptime-only fields before taking a runtime address.
fn hashByValue(comptime T: type, value: T, seed: u64) u64 {
    if (@typeInfo(T) == .comptime_int) return hashInt(u64, value, seed);
    if (@typeInfo(T) == .comptime_float) return hashFloat(f64, value, seed);
    return hashValue(T, &value, seed);
}

fn hashInt(comptime T: type, value: T, seed: u64) u64 {
    if (@bitSizeOf(T) <= 64) {
        const wide: u64 = if (@typeInfo(T).int.signedness == .signed)
            @bitCast(@as(i64, value))
        else
            @as(u64, value);
        return mix(seed, wide);
    }
    if (@bitSizeOf(T) <= 128) {
        const wide: u128 = if (@typeInfo(T).int.signedness == .signed)
            @bitCast(@as(i128, value))
        else
            @as(u128, value);
        return mix(
            mix(seed, @as(u64, @truncate(wide))),
            @as(u64, @truncate(wide >> 64)),
        );
    }
    @compileError("api_round_common.hash does not cover integers wider than 128 bits");
}

/// Hashes the encoding of a float, never its numeric value, so `-0.0`, the two
/// NaN families and every subnormal stay distinguishable.
fn hashFloat(comptime T: type, value: T, seed: u64) u64 {
    return switch (@as(u16, @bitSizeOf(T))) {
        16 => mix(seed, @as(u16, @bitCast(value))),
        32 => mix(seed, @as(u32, @bitCast(value))),
        64 => mix(seed, @as(u64, @bitCast(value))),
        128 => mix(
            mix(seed, @as(u64, @truncate(@as(u128, @bitCast(value))))),
            @as(u64, @truncate(@as(u128, @bitCast(value)) >> 64)),
        ),
        else => @compileError("api_round_common.hash does not cover this float width"),
    };
}

/// Folds `text` into `seed`. Case names, namespaces, bundle labels, error
/// names and enum tags all reach the checksum through here.
pub fn hashText(seed: u64, text: []const u8) u64 {
    var acc = mix(seed, @as(u64, text.len));
    for (text) |byte| acc = mix(acc, @as(u64, byte));
    return acc;
}

const Testing = struct {
    const A = struct { x: f32, y: u32 };
    const B = struct { y: u32, x: f32 };

    /// Two variants over one payload type, so only the tag separates them.
    const Tagged = union(enum) {
        absolute: u32,
        negated: u32,
    };
};

test "hash separates encodings that share a numeric value" {
    try std.testing.expect(hash(@as(f32, 0.0)) != hash(@as(f32, -0.0)));
    try std.testing.expect(hash(std.math.nan(f32)) != hash(@as(f32, 0.0)));
    try std.testing.expect(hash(@as(f16, 1.0)) != hash(@as(f32, 1.0)));
    try std.testing.expect(hash(true) != hash(false));
}

test "hash covers optional presence and error-union discriminants" {
    const present: ?u32 = 5;
    const absent: ?u32 = null;
    try std.testing.expect(hash(present) != hash(absent));
    try std.testing.expect(hash(present) != hash(@as(?u32, 6)));

    const ok: anyerror!u32 = 5;
    const bad: anyerror!u32 = error.Bad;
    try std.testing.expect(hash(ok) != hash(bad));
    try std.testing.expect(hash(ok) != hash(@as(anyerror!u32, 6)));
}

test "hash folds a slice by contents and never by address" {
    const first = [_]u8{ 'a', 'b', 'c' };
    var second = [_]u8{ 'a', 'b', 'c' };
    const first_slice: []const u8 = &first;
    const second_slice: []const u8 = &second;
    try std.testing.expectEqual(hash(first_slice), hash(second_slice));
    second[2] = 'd';
    try std.testing.expect(hash(first_slice) != hash(second_slice));
}

test "reordering a field or a lane moves the checksum a consumer reads" {
    // Two spellings of one result, same numbers, opposite field order. A
    // commutative fold would call these equal and a case that reordered its
    // own result fields would compare clean across the round.
    const forward = Testing.A{ .x = 1.5, .y = 7 };
    const backward = Testing.B{ .y = 7, .x = 1.5 };
    try std.testing.expect(hash(forward) != hash(backward));
    try std.testing.expect(hash(forward) != hash(Testing.A{ .x = 1.5, .y = 8 }));

    // Lanes fold in lane order for an array result and for a vector result,
    // so swapping two lanes is a difference and not a permutation of one.
    const array = [_]u32{ 1, 2 };
    try std.testing.expect(hash(array) != hash(@as([2]u32, .{ 2, 1 })));
    try std.testing.expect(hash(array) != hash(@as([2]u32, .{ 1, 3 })));

    const lanes: @Vector(2, f32) = .{ 1.0, 2.0 };
    try std.testing.expect(hash(lanes) != hash(@as(@Vector(2, f32), .{ 2.0, 1.0 })));
    try std.testing.expect(hash(lanes) != hash(@as(@Vector(2, f32), .{ 1.0, 3.0 })));

    // A tag is a semantic field: two variants sharing one payload type stay
    // apart, and moving the payload under an unchanged tag moves it too.
    try std.testing.expect(
        hash(Testing.Tagged{ .absolute = 7 }) != hash(Testing.Tagged{ .negated = 7 }),
    );
    try std.testing.expect(
        hash(Testing.Tagged{ .absolute = 7 }) != hash(Testing.Tagged{ .absolute = 8 }),
    );
}

test "namespace and charge operation guards accept only declared shapes" {
    try std.testing.expect(isNamespace("scalar"));
    try std.testing.expect(!isNamespace("leaf"));
    try std.testing.expect(isChargeOperation("expf"));
    try std.testing.expect(isChargeOperation("sinpih"));
    try std.testing.expect(isChargeOperation("fadd"));
    try std.testing.expect(!isChargeOperation(""));
    try std.testing.expect(!isChargeOperation("scalar.expf"));
    try std.testing.expect(!isChargeOperation("exp f"));
}

test "hash distinguishes enum tags and comptime metadata fields" {
    const Kind = enum { alpha, beta };
    try std.testing.expect(hash(Kind.alpha) != hash(Kind.beta));
    const original = .{ @as(u32, 7), 3, 0.5, Kind.alpha };
    try std.testing.expect(hash(original) != hash(.{ @as(u32, 7), 4, 0.5, Kind.alpha }));
    try std.testing.expect(hash(original) != hash(.{ @as(u32, 7), 3, 0.75, Kind.alpha }));
    try std.testing.expect(hash(original) != hash(.{ @as(u32, 7), 3, 0.5, Kind.beta }));
}
