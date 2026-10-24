const std = @import("std");
const corpus = @import("corpus_support");
const runner = @import("scalar_runner");

const Operation = enum { abs, ceil, floor, trunc, round, fma };
const UnaryOperation = enum { abs, ceil, floor, trunc, round };
const Invoker = *const fn (
    inputs: *const [corpus.max_argument_count]corpus.OracleInputField,
) runner.RawRuntimeResult;

pub fn entryFor(function: corpus.Function, runtime: *const runner.RuntimeEntry) ?runner.RuntimeEntry {
    const operation = std.meta.stringToEnum(Operation, function.op) orelse return null;
    const format = switch (function.result) {
        .float => |value| value,
        else => return null,
    };
    const input_count: usize = if (operation == .fma) 3 else 1;
    if (function.arity != input_count or function.arguments().len != input_count) return null;
    for (function.arguments()) |argument| {
        const input_format = argument.floatFormat() orelse return null;
        if (input_format != format) return null;
    }

    // Keep the validated runtime signature; replace only its implementation.
    var entry = runtime.*;
    entry.invoke = switch (format) {
        .h => invokerFor(.h, operation),
        .f => invokerFor(.f, operation),
        .d => invokerFor(.d, operation),
    };
    return entry;
}

fn invokerFor(comptime format: corpus.Format, operation: Operation) Invoker {
    return switch (operation) {
        .abs => unaryInvoker(format, .abs),
        .ceil => unaryInvoker(format, .ceil),
        .floor => unaryInvoker(format, .floor),
        .trunc => unaryInvoker(format, .trunc),
        .round => unaryInvoker(format, .round),
        .fma => fmaInvoker(format),
    };
}

fn FloatType(comptime format: corpus.Format) type {
    return switch (format) {
        .h => f16,
        .f => f32,
        .d => f64,
    };
}

fn BitsType(comptime format: corpus.Format) type {
    return switch (format) {
        .h => u16,
        .f => u32,
        .d => u64,
    };
}

fn decode(comptime format: corpus.Format, bits: u64) FloatType(format) {
    return @bitCast(@as(BitsType(format), @intCast(bits)));
}

fn singleResult(comptime format: corpus.Format, value: FloatType(format)) runner.RawRuntimeResult {
    var values: [corpus.max_argument_count]u64 = @splat(0);
    values[0] = @intCast(@as(BitsType(format), @bitCast(value)));
    return .{ .values = values, .field_count = 1 };
}

fn unaryInvoker(comptime format: corpus.Format, comptime operation: UnaryOperation) Invoker {
    const Adapter = struct {
        fn invoke(inputs: *const [corpus.max_argument_count]corpus.OracleInputField) runner.RawRuntimeResult {
            const input = decode(format, inputs[0].value_bits);
            const output: FloatType(format) = switch (operation) {
                .abs => @abs(input),
                .ceil => @ceil(input),
                .floor => @floor(input),
                .trunc => @trunc(input),
                .round => @round(input),
            };
            return singleResult(format, output);
        }
    };
    return &Adapter.invoke;
}

fn fmaInvoker(comptime format: corpus.Format) Invoker {
    const Adapter = struct {
        fn invoke(inputs: *const [corpus.max_argument_count]corpus.OracleInputField) runner.RawRuntimeResult {
            const first = decode(format, inputs[0].value_bits);
            const second = decode(format, inputs[1].value_bits);
            const third = decode(format, inputs[2].value_bits);
            const output = @mulAdd(FloatType(format), first, second, third);
            return singleResult(format, output);
        }
    };
    return &Adapter.invoke;
}
