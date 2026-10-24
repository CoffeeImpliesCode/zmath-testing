//! `@Vector` reference plug-in for the vector corpus benchmark.
//!
//! This module is the vector counterpart of `bench/scalar_references.zig`. It
//! keeps the validated runtime signature produced by `runner.prepareRuntime`
//! and replaces only the implementation, so the benchmark measures the same
//! descriptors the scalar lane measures.
//!
//! The reference implementation is independent Zig arithmetic on `@Vector`:
//! `@exp`, `@log`, `@sin`, `@abs`, `@ceil`, `@floor`, `@trunc`, `@round`, and a
//! `@mulAdd` fused multiply-add. It never calls `zmath.scalar` and never calls
//! `zmath.vector`, so a timing difference is a difference between two
//! implementations, not a tautology.
//!
//! Lane packing: the returned invoker reads `lane_width` consecutive input
//! fields per argument, so a unary operation of lane width L consumes
//! `inputs[0..L]` and a ternary operation consumes `inputs[0..L]`,
//! `inputs[L..2L]`, and `inputs[2L..3L]`. It writes one result per lane into
//! `values[0..L]`. That field count is wider than the scalar runtime's, so the
//! vector benchmark never routes this invoker through
//! `runner.materializeRawRuntimeFields`.

const std = @import("std");
const corpus = @import("corpus_support");
const runner = @import("scalar_runner");
const targets = @import("vector_targets.zig");

/// Reference operations with an independent `@Vector` implementation.
pub const Operation = enum {
    abs,
    ceil,
    floor,
    trunc,
    round,
    exp,
    log,
    sin,
    fma,
};
const Invoker = *const fn (
    inputs: *const [corpus.max_argument_count]corpus.OracleInputField,
) runner.RawRuntimeResult;

/// Returns a copy of the validated runtime entry whose implementation is
/// independent `@Vector` arithmetic, or null when the function has no vector
/// reference, or when its lane groups do not fit the oracle input array.
pub fn entryFor(function: corpus.Function, runtime: *const runner.RuntimeEntry) ?runner.RuntimeEntry {
    const operation = std.meta.stringToEnum(Operation, function.op) orelse return null;
    const manifest_format = switch (function.result) {
        .float => |value| value,
        else => return null,
    };
    const format = targetFormat(manifest_format);
    const argument_count: usize = if (operation == .fma) 3 else 1;
    if (function.arity != argument_count or function.arguments().len != argument_count) {
        return null;
    }
    for (function.arguments()) |argument| {
        const input_format = argument.floatFormat() orelse return null;
        if (input_format != manifest_format) return null;
    }

    // A ternary operation packs three lane groups, so its lane width is capped
    // by the oracle input array.
    const lane_width = laneWidthFor(format, operation);
    if (lane_width == 0) return null;
    if (argument_count * lane_width > corpus.max_argument_count) return null;

    // Keep the validated runtime signature; replace only its implementation.
    // The lane width and lane type must be comptime known, so the runtime
    // operation is dispatched with an inline prong that fixes both.
    var entry = runtime.*;
    entry.invoke = dispatch(manifest_format, operation);
    return entry;
}

fn dispatch(manifest_format: corpus.Format, operation: Operation) Invoker {
    return switch (manifest_format) {
        inline else => |comptime_format| switch (operation) {
            inline else => |comptime_operation| invokerFor(
                targetFormat(comptime_format),
                comptime_operation,
                laneWidthFor(targetFormat(comptime_format), comptime_operation),
            ),
        },
    };
}

/// Maps a manifest float format onto the vector target registry's format. The
/// manifest enum covers exactly the three published binary formats.
fn targetFormat(format: corpus.Format) targets.Format {
    return switch (format) {
        .h => .h,
        .f => .f,
        .d => .d,
    };
}

/// Lanes packed per invocation for one format and reference operation.
pub fn laneWidthFor(format: targets.Format, operation: Operation) u32 {
    return if (operation == .fma)
        @min(targets.laneWidthFor(format), corpus.max_argument_count / 3)
    else
        targets.laneWidthFor(format);
}

fn FloatType(comptime format: targets.Format) type {
    return switch (format) {
        .h => f16,
        .f => f32,
        .d => f64,
    };
}

fn BitsType(comptime format: targets.Format) type {
    return switch (format) {
        .h => u16,
        .f => u32,
        .d => u64,
    };
}

fn decodeLane(comptime format: targets.Format, bits: u64) FloatType(format) {
    return @bitCast(@as(BitsType(format), @truncate(bits)));
}

fn encodeLane(comptime format: targets.Format, value: FloatType(format)) u64 {
    return @as(BitsType(format), @bitCast(value));
}

/// Applies the reference operation to one whole lane group. The benchmark times
/// this directly so the measured loop contains only the reference arithmetic.
fn applyVector(
    comptime format: targets.Format,
    comptime operation: Operation,
    comptime lane_width: u32,
    input: @Vector(lane_width, FloatType(format)),
) @Vector(lane_width, FloatType(format)) {
    return switch (operation) {
        .abs => @abs(input),
        .ceil => @ceil(input),
        .floor => @floor(input),
        .trunc => @trunc(input),
        .round => @round(input),
        .exp => @exp(input),
        .log => @log(input),
        .sin => @sin(input),
        .fma => @compileError("applyVector covers the unary reference operations only"),
    };
}

/// Applies the reference operation to three lane groups.
fn applyVectorFma(
    comptime format: targets.Format,
    comptime lane_width: u32,
    first: @Vector(lane_width, FloatType(format)),
    second: @Vector(lane_width, FloatType(format)),
    third: @Vector(lane_width, FloatType(format)),
) @Vector(lane_width, FloatType(format)) {
    return @mulAdd(@Vector(lane_width, FloatType(format)), first, second, third);
}

fn invokerFor(
    comptime format: targets.Format,
    comptime operation: Operation,
    comptime lane_width: u32,
) Invoker {
    return switch (operation) {
        .fma => fmaInvoker(format, lane_width),
        .abs, .ceil, .floor, .trunc, .round, .exp, .log, .sin => unaryInvoker(format, operation, lane_width),
    };
}

fn laneGroup(
    comptime format: targets.Format,
    comptime lane_width: u32,
    inputs: *const [corpus.max_argument_count]corpus.OracleInputField,
    offset: usize,
) @Vector(lane_width, FloatType(format)) {
    std.debug.assert(offset + lane_width <= inputs.len);
    var lanes: @Vector(lane_width, FloatType(format)) = undefined;
    inline for (0..lane_width) |lane| {
        lanes[lane] = decodeLane(format, inputs[offset + lane].value_bits);
    }
    return lanes;
}

fn laneResults(
    comptime format: targets.Format,
    comptime lane_width: u32,
    lanes: @Vector(lane_width, FloatType(format)),
) runner.RawRuntimeResult {
    var values: [corpus.max_argument_count]u64 = @splat(0);
    inline for (0..lane_width) |lane| {
        values[lane] = encodeLane(format, lanes[lane]);
    }
    return .{ .values = values, .field_count = lane_width };
}

fn unaryInvoker(
    comptime format: targets.Format,
    comptime operation: Operation,
    comptime lane_width: u32,
) Invoker {
    const Adapter = struct {
        fn invoke(inputs: *const [corpus.max_argument_count]corpus.OracleInputField) runner.RawRuntimeResult {
            const lanes = laneGroup(format, lane_width, inputs, 0);
            return laneResults(format, lane_width, applyVector(format, operation, lane_width, lanes));
        }
    };
    return &Adapter.invoke;
}

fn fmaInvoker(
    comptime format: targets.Format,
    comptime lane_width: u32,
) Invoker {
    const Adapter = struct {
        fn invoke(inputs: *const [corpus.max_argument_count]corpus.OracleInputField) runner.RawRuntimeResult {
            const first = laneGroup(format, lane_width, inputs, 0);
            const second = laneGroup(format, lane_width, inputs, lane_width);
            const third = laneGroup(format, lane_width, inputs, 2 * lane_width);
            return laneResults(format, lane_width, applyVectorFma(format, lane_width, first, second, third));
        }
    };
    return &Adapter.invoke;
}

comptime {
    // Every reference operation must have an independent `@Vector` path.
    if (laneWidthFor(.d, .fma) == 0 or laneWidthFor(.f, .fma) == 0) {
        @compileError("the ternary reference lane groups must fit the oracle input array");
    }
}
