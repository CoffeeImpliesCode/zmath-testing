const std = @import("std");
const zmath = @import("zmath");
const corpus = @import("corpus_support");

comptime {
    @setEvalBranchQuota(2_000_000);
}

const Function = corpus.Function;
const OracleFieldDescriptor = corpus.OracleFieldDescriptor;
const OracleFormatDescriptor = corpus.OracleFormatDescriptor;
const OracleInputField = corpus.OracleInputField;
const OracleRequest = corpus.OracleRequest;
const OracleResult = corpus.OracleResult;
const OracleResultField = corpus.OracleResultField;
const max_oracle_fields: usize = corpus.max_argument_count;

pub const UnsupportedReason = enum {
    manifest_status,
    oracle_capability,
    arity,
    input_shape,
    operation,
    format_conversion,
    binary_float,
    ternary_float,
    integer_result,
    boolean_result,
    structure_result,
};

pub const Support = union(enum) {
    supported: void,
    unsupported: UnsupportedReason,
};

pub const RunOutcome = union(enum) {
    verified: void,
    unsupported: UnsupportedReason,
};

pub const VerifiedEvidence = struct {
    runtime_status: corpus.OracleStatus,
    reference_status: corpus.OracleStatus,
    proof_status: corpus.OracleStatus,
    fields: [max_oracle_fields]OracleResultField,
    field_count: usize,

    pub fn resultFields(self: *const @This()) []const OracleResultField {
        return self.fields[0..self.field_count];
    }
};

pub const EvidenceOutcome = union(enum) {
    verified: VerifiedEvidence,
    unsupported: UnsupportedReason,
};

pub const RunError = error{
    DescriptorCountOverflow,
    DescriptorShapeMismatch,
    EvidenceStatusMismatch,
    InputBitsOutOfRange,
    InputCountMismatch,
    InputTagCountMismatch,
    InvalidResultClass,
    InvalidResultDescriptor,
    ReferenceError,
    ReferenceShapeMismatch,
    ReferenceUncertain,
    ReferenceUnsupported,
    RuntimeMismatch,
    RuntimeShapeMismatch,
    ProofError,
    ProofShapeMismatch,
    ProofUncertain,
    ProofUnsupported,
};

const RuntimeResult = struct {
    fields: [max_oracle_fields]OracleResultField,
    field_count: usize,
};

pub const RawRuntimeResult = struct {
    values: [corpus.max_argument_count]u64,
    field_count: usize,
};

const RuntimeDispatch = union(enum) {
    result: RuntimeResult,
    unsupported: UnsupportedReason,
};

const RuntimeNamespace = enum {
    root,
    scalar,
    ieee,
};

const RuntimeInvoker = *const fn (
    inputs: *const [max_oracle_fields]OracleInputField,
) RawRuntimeResult;

pub const RuntimeEntry = struct {
    operation: []const u8,
    input_descriptors: [max_oracle_fields]OracleFieldDescriptor,
    input_count: usize,
    result_descriptors: [max_oracle_fields]OracleFieldDescriptor,
    result_count: usize,
    result_layout: corpus.OracleResultLayout,
    structure_kind: corpus.OracleStructureKind,
    invoke: RuntimeInvoker,
};

const RuntimeTable = struct {
    entries: [corpus.max_function_count]RuntimeEntry,
    count: usize,
};

pub const PreparedRuntime = struct {
    entry: *const RuntimeEntry,

    pub fn invoke(self: *const @This(), inputs: *const [corpus.max_argument_count]OracleInputField) RawRuntimeResult {
        return self.entry.invoke(inputs);
    }

    pub fn resultFieldCount(self: *const @This()) usize {
        return self.entry.result_count;
    }

    pub fn resultDescriptors(self: *const @This()) []const OracleFieldDescriptor {
        return self.entry.result_descriptors[0..self.entry.result_count];
    }
};

const RequestStorage = struct {
    input_fields: [max_oracle_fields]OracleInputField,
    result_fields: [max_oracle_fields]OracleFieldDescriptor,
    result_field_count: usize,
    request: OracleRequest,

    fn initialize(
        self: *@This(),
        function: Function,
        input_bits: []const u64,
        input_tags: []const []const u8,
    ) RunError!void {
        const arguments = function.arguments();
        if (@as(usize, function.arity) != arguments.len) {
            return error.DescriptorShapeMismatch;
        }
        if (input_bits.len != arguments.len) return error.InputCountMismatch;
        if (input_tags.len != 0 and input_tags.len != arguments.len) {
            return error.InputTagCountMismatch;
        }
        if (arguments.len > self.input_fields.len) return error.DescriptorCountOverflow;

        for (arguments, input_bits, 0..) |argument, bits, index| {
            const descriptor = argument.oracleDescriptor();
            if (!bitsFitDescriptor(descriptor, bits)) return error.InputBitsOutOfRange;
            const tag = switch (argument) {
                .tag => if (input_tags.len == 0) "" else input_tags[index],
                else => "",
            };
            self.input_fields[index] = .{
                .descriptor = descriptor,
                .value_bits = bits,
                .tag_bytes = if (tag.len == 0) null else tag.ptr,
                .tag_length = @intCast(tag.len),
                .reserved = 0,
            };
        }

        self.result_field_count = function.result.oracleFieldCount();
        if (self.result_field_count > self.result_fields.len) {
            return error.DescriptorCountOverflow;
        }
        for (0..self.result_field_count) |index| {
            self.result_fields[index] = function.result.oracleFieldDescriptor(index) orelse
                return error.InvalidResultDescriptor;
        }

        self.request = .{
            .abi_version = corpus.oracle_abi_version,
            .reserved = 0,
            .operation = constPointer(u8, function.op),
            .operation_length = @intCast(function.op.len),
            .arity = @intCast(arguments.len),
            .input_fields = constPointer(
                OracleInputField,
                self.input_fields[0..arguments.len],
            ),
            .input_field_count = @intCast(arguments.len),
            .result_layout = function.result.oracleLayout(),
            .structure_kind = function.result.oracleStructureKind(),
            .result_field_count = @intCast(self.result_field_count),
            .result_fields = constPointer(
                OracleFieldDescriptor,
                self.result_fields[0..self.result_field_count],
            ),
        };
    }
};

pub fn supportFor(function: Function) Support {
    if (function.status != .correct) {
        return .{ .unsupported = .manifest_status };
    }
    if (function.oracle != .mpfr_arb and function.oracle != .exact_bits and function.oracle != .algebraic) {
        return .{ .unsupported = .oracle_capability };
    }
    return shapeSupport(function);
}

fn shapeSupport(function: Function) Support {
    const arguments = function.arguments();
    if (@as(usize, function.arity) != arguments.len) {
        return .{ .unsupported = .arity };
    }
    if (runtimeEntryForFunction(function) != null) {
        return .{ .supported = {} };
    }
    return unsupportedShapeReason(function);
}

fn unsupportedShapeReason(function: Function) Support {
    const arguments = function.arguments();
    return switch (function.result) {
        .float => switch (arguments.len) {
            1 => .{ .unsupported = .input_shape },
            2 => .{ .unsupported = .binary_float },
            3 => .{ .unsupported = .ternary_float },
            else => .{ .unsupported = .arity },
        },
        .integer => .{ .unsupported = .integer_result },
        .boolean => .{ .unsupported = .boolean_result },
        .structure => .{ .unsupported = .structure_result },
    };
}

pub fn runFunction(function: Function, input_bits: []const u64) RunError!RunOutcome {
    const no_tags = [_][]const u8{};
    return runFunctionInternal(function, input_bits, no_tags[0..], null, .accepted);
}

pub fn runFunctionWithTags(
    function: Function,
    input_bits: []const u64,
    input_tags: []const []const u8,
) RunError!RunOutcome {
    return runFunctionInternal(function, input_bits, input_tags, null, .accepted);
}

pub fn evaluateFunction(
    function: Function,
    input_bits: []const u64,
) RunError!EvidenceOutcome {
    const no_tags = [_][]const u8{};
    return evaluateFunctionWithTags(function, input_bits, no_tags[0..]);
}

// Candidate evaluation produces evidence without changing manifest acceptance.
pub fn evaluateFunctionWithTags(
    function: Function,
    input_bits: []const u64,
    input_tags: []const []const u8,
) RunError!EvidenceOutcome {
    var evidence: VerifiedEvidence = undefined;
    return switch (try runFunctionInternal(
        function,
        input_bits,
        input_tags,
        &evidence,
        .candidate,
    )) {
        .verified => .{ .verified = evidence },
        .unsupported => |reason| .{ .unsupported = reason },
    };
}

pub fn verifyExpectedStatus(
    evidence: *const VerifiedEvidence,
    expected: corpus.OracleStatus,
) RunError!void {
    if (expected != .ok or
        evidence.runtime_status != .ok or
        evidence.reference_status != .ok or
        evidence.proof_status != .ok)
    {
        return error.EvidenceStatusMismatch;
    }
}

pub fn verifyExpectedResults(
    function: Function,
    evidence: *const VerifiedEvidence,
    expected: []const corpus.CorpusField,
) RunError!void {
    if (expected.len != evidence.field_count) return error.ReferenceShapeMismatch;
    for (expected, 0..) |field, index| {
        const descriptor = function.result.oracleFieldDescriptor(index) orelse
            return error.InvalidResultDescriptor;
        const actual = evidence.fields[index];
        if (!fieldDescriptorEqual(descriptor, actual.descriptor) or actual.reserved != 0) {
            return error.ReferenceShapeMismatch;
        }
        switch (field) {
            .float => |value| {
                if (descriptor.kind != .float or
                    descriptor.format.code != value.format.oracleDescriptor().code or
                    actual.value_bits != value.bits or
                    actual.class_code != oracleClass(value.class))
                {
                    return error.RuntimeMismatch;
                }
            },
            .signed_integer => |value| {
                const encoded = corpus.encodeSignedInteger(
                    value.value,
                    descriptor.value_bits,
                ) catch return error.RuntimeMismatch;
                if (descriptor.kind != .signed_integer or
                    descriptor.value_bits != value.integer_type.oracleValueBits() or
                    actual.value_bits != encoded)
                {
                    return error.RuntimeMismatch;
                }
            },
            .unsigned_integer => |value| {
                if (descriptor.kind != .unsigned_integer or
                    descriptor.value_bits != value.integer_type.oracleValueBits() or
                    actual.value_bits != value.value & lowMask(descriptor.value_bits))
                {
                    return error.RuntimeMismatch;
                }
            },
            .boolean => |value| {
                if (descriptor.kind != .boolean or
                    actual.value_bits != @intFromBool(value))
                {
                    return error.RuntimeMismatch;
                }
            },
            .tag, .rounding => return error.InvalidResultDescriptor,
        }
    }
}

fn oracleClass(class: corpus.FieldClass) corpus.OracleClass {
    return switch (class) {
        .normal => .normal,
        .subnormal => .subnormal,
        .zero => .zero,
        .infinity => .infinity,
        .qnan => .qnan,
        .snan => .snan,
        .none => .none,
    };
}

pub fn materializeRawRuntimeFields(
    function: Function,
    prepared: *const PreparedRuntime,
    raw: RawRuntimeResult,
    target: []corpus.CorpusField,
) RunError!usize {
    if (raw.field_count != prepared.resultFieldCount() or raw.field_count > corpus.max_result_field_count) {
        return error.RuntimeShapeMismatch;
    }
    var evidence: VerifiedEvidence = undefined;
    evidence.runtime_status = .ok;
    evidence.reference_status = .unsupported;
    evidence.proof_status = .unsupported;
    evidence.field_count = raw.field_count;
    for (prepared.resultDescriptors(), 0..) |descriptor, index| {
        if (!valueBitsFitDescriptor(descriptor, raw.values[index])) return error.RuntimeShapeMismatch;
        evidence.fields[index] = .{
            .descriptor = descriptor,
            .value_bits = raw.values[index],
            .class_code = if (descriptor.kind == .float) classifyFloatBits(descriptor, raw.values[index]) else .none,
            .reserved = 0,
        };
    }
    return materializeResultFields(function, &evidence, target);
}

pub fn materializeResultFields(
    function: Function,
    evidence: *const VerifiedEvidence,
    target: []corpus.CorpusField,
) RunError!usize {
    if (target.len < evidence.field_count) return error.DescriptorCountOverflow;
    for (0..evidence.field_count) |index| {
        const descriptor = function.result.oracleFieldDescriptor(index) orelse
            return error.InvalidResultDescriptor;
        const actual = evidence.fields[index];
        if (!fieldDescriptorEqual(descriptor, actual.descriptor) or actual.reserved != 0) {
            return error.ReferenceShapeMismatch;
        }
        target[index] = switch (descriptor.kind) {
            .float => .{ .float = .{
                .format = switch (descriptor.format.code) {
                    .h => .h,
                    .f => .f,
                    .d => .d,
                    else => return error.InvalidResultDescriptor,
                },
                .bits = actual.value_bits,
                .class = fieldClass(actual.class_code) orelse
                    return error.InvalidResultClass,
            } },
            .signed_integer => .{ .signed_integer = .{
                .integer_type = signedIntegerType(descriptor.value_bits) orelse
                    return error.InvalidResultDescriptor,
                .value = corpus.decodeSignedInteger(
                    actual.value_bits,
                    descriptor.value_bits,
                ) catch return error.RuntimeMismatch,
            } },
            .unsigned_integer => .{ .unsigned_integer = .{
                .integer_type = unsignedIntegerType(descriptor.value_bits) orelse
                    return error.InvalidResultDescriptor,
                .value = actual.value_bits & lowMask(descriptor.value_bits),
            } },
            .boolean => .{ .boolean = actual.value_bits != 0 },
            .tag, .rounding => return error.InvalidResultDescriptor,
            _ => return error.InvalidResultDescriptor,
        };
    }
    return evidence.field_count;
}

fn fieldClass(class: corpus.OracleClass) ?corpus.FieldClass {
    return switch (class) {
        .normal => .normal,
        .subnormal => .subnormal,
        .zero => .zero,
        .infinity => .infinity,
        .qnan => .qnan,
        .snan => .snan,
        .none => null,
        else => null,
    };
}

fn signedIntegerType(value_bits: u32) ?corpus.IntegerType {
    return switch (value_bits) {
        2 => .i2,
        8 => .i8,
        16 => .i16,
        32 => .i32,
        64 => .i64,
        else => null,
    };
}

fn unsignedIntegerType(value_bits: u32) ?corpus.IntegerType {
    return switch (value_bits) {
        8 => .u8,
        16 => .u16,
        32 => .u32,
        64 => .u64,
        else => null,
    };
}

fn runFunctionInternal(
    function: Function,
    input_bits: []const u64,
    input_tags: []const []const u8,
    evidence_out: ?*VerifiedEvidence,
    admission: enum { accepted, candidate },
) RunError!RunOutcome {
    const support = if (admission == .accepted) supportFor(function) else shapeSupport(function);
    switch (support) {
        .supported => {},
        .unsupported => |reason| return .{ .unsupported = reason },
    }

    var storage: RequestStorage = undefined;
    try storage.initialize(function, input_bits, input_tags);

    var runtime = switch (try dispatchRuntime(
        function,
        storage.input_fields[0..input_bits.len],
        storage.result_fields[0..storage.result_field_count],
    )) {
        .result => |result| result,
        .unsupported => |reason| return .{ .unsupported = reason },
    };
    if (runtime.field_count != storage.result_field_count) {
        return error.RuntimeShapeMismatch;
    }

    var reference_fields: [max_oracle_fields]OracleResultField = undefined;
    var reference = emptyOracleResult(
        reference_fields[0..storage.result_field_count],
    );
    corpus.zmath_testing_oracle_v2_mpfr_reference(&storage.request, &reference);
    const reference_status = reference.status;
    switch (reference.status) {
        .ok => {},
        .unsupported => return .{ .unsupported = .oracle_capability },
        else => try expectReferenceOk(reference.status),
    }
    try compareEvidence(
        &runtime,
        reference,
        error.ReferenceShapeMismatch,
    );

    var candidate = runtimeOracleResult(&runtime);
    var proof_fields: [max_oracle_fields]OracleResultField = undefined;
    var proof = emptyOracleResult(proof_fields[0..storage.result_field_count]);
    corpus.zmath_testing_oracle_v2_arb_prove(
        &storage.request,
        &candidate,
        &proof,
    );
    const proof_status = proof.status;
    switch (proof.status) {
        .ok => {},
        .unsupported => return .{ .unsupported = .oracle_capability },
        else => try expectProofOk(proof.status),
    }
    try compareEvidence(
        &runtime,
        proof,
        error.ProofShapeMismatch,
    );

    if (evidence_out) |output| {
        output.* = .{
            .runtime_status = .ok,
            .reference_status = reference_status,
            .proof_status = proof_status,
            .fields = runtime.fields,
            .field_count = runtime.field_count,
        };
    }
    return .{ .verified = {} };
}

fn dispatchRuntime(
    function: Function,
    input_fields: []const OracleInputField,
    result_descriptors: []const OracleFieldDescriptor,
) RunError!RuntimeDispatch {
    const entry = findRuntimeEntry(function, input_fields, result_descriptors) orelse {
        const support = unsupportedShapeReason(function);
        return switch (support) {
            .supported => error.RuntimeShapeMismatch,
            .unsupported => |reason| .{ .unsupported = reason },
        };
    };
    if (input_fields.len > max_oracle_fields) return error.RuntimeShapeMismatch;

    var input_storage: [max_oracle_fields]OracleInputField = undefined;
    for (input_fields, 0..) |input, index| input_storage[index] = input;
    const raw = entry.invoke(&input_storage);
    if (raw.field_count != result_descriptors.len) return error.RuntimeShapeMismatch;
    if (raw.field_count > max_oracle_fields) return error.RuntimeShapeMismatch;

    var result: RuntimeResult = .{
        .fields = undefined,
        .field_count = raw.field_count,
    };
    for (result_descriptors, 0..) |descriptor, index| {
        if (!valueBitsFitDescriptor(descriptor, raw.values[index])) {
            return error.RuntimeShapeMismatch;
        }
        result.fields[index] = .{
            .descriptor = descriptor,
            .value_bits = raw.values[index],
            .class_code = if (descriptor.kind == .float)
                classifyFloatBits(descriptor, raw.values[index])
            else
                .none,
            .reserved = 0,
        };
    }
    return .{ .result = result };
}

fn findRuntimeEntry(
    function: Function,
    input_fields: []const OracleInputField,
    result_descriptors: []const OracleFieldDescriptor,
) ?*const RuntimeEntry {
    const entry = runtimeEntryForFunction(function) orelse return null;
    if (input_fields.len != entry.input_count) return null;
    if (result_descriptors.len != entry.result_count) return null;
    for (input_fields, 0..) |input, index| {
        if (!fieldDescriptorEqual(input.descriptor, entry.input_descriptors[index])) return null;
    }
    for (result_descriptors, 0..) |descriptor, index| {
        if (!fieldDescriptorEqual(descriptor, entry.result_descriptors[index])) return null;
    }
    return entry;
}

pub fn prepareRuntime(function: Function) RunError!PreparedRuntime {
    const entry = runtimeEntryForFunction(function) orelse return error.RuntimeShapeMismatch;
    return .{ .entry = entry };
}

fn runtimeEntryForFunction(function: Function) ?*const RuntimeEntry {
    const arguments = function.arguments();
    const result_count = function.result.oracleFieldCount();
    for (runtime_table.entries[0..runtime_table.count]) |*entry| {
        if (!std.mem.eql(u8, function.op, entry.operation)) continue;
        if (arguments.len != entry.input_count) continue;
        if (result_count != entry.result_count) continue;
        if (function.result.oracleLayout() != entry.result_layout) continue;
        if (function.result.oracleStructureKind() != entry.structure_kind) continue;
        var matches = true;
        for (arguments, 0..) |argument, index| {
            if (!fieldDescriptorEqual(
                argument.oracleDescriptor(),
                entry.input_descriptors[index],
            )) {
                matches = false;
                break;
            }
        }
        if (!matches) continue;
        for (0..result_count) |index| {
            const descriptor = function.result.oracleFieldDescriptor(index) orelse {
                matches = false;
                break;
            };
            if (!fieldDescriptorEqual(descriptor, entry.result_descriptors[index])) {
                matches = false;
                break;
            }
        }
        if (matches) return entry;
    }
    return null;
}

fn emptyRawRuntimeResult() RawRuntimeResult {
    return .{
        .values = [_]u64{0} ** max_oracle_fields,
        .field_count = 0,
    };
}

fn floatType(comptime format: corpus.Format) type {
    return switch (format) {
        .h => f16,
        .f => f32,
        .d => f64,
    };
}

fn floatBitsType(comptime format: corpus.Format) type {
    return switch (format) {
        .h => u16,
        .f => u32,
        .d => u64,
    };
}

fn decodeFloat(comptime format: corpus.Format, bits: u64) floatType(format) {
    const Bits = floatBitsType(format);
    return @bitCast(@as(Bits, @intCast(bits)));
}

fn encodeFloat(comptime format: corpus.Format, value: floatType(format)) u64 {
    const Bits = floatBitsType(format);
    return @intCast(@as(Bits, @bitCast(value)));
}

fn integerWidth(comptime integer_type: corpus.IntegerType) u32 {
    return integer_type.oracleValueBits();
}

fn decodeSignedInteger(comptime integer_type: corpus.IntegerType, bits: u64) i64 {
    const width = integerWidth(integer_type);
    const mask = lowMask(width);
    var value = bits & mask;
    const sign_bit = @as(u64, 1) << @as(u6, @intCast(width - 1));
    if (value & sign_bit != 0) value |= ~mask;
    return @bitCast(value);
}

fn encodeInteger(comptime integer_type: corpus.IntegerType, value: anytype) u64 {
    const width = integerWidth(integer_type);
    return switch (integer_type) {
        .i2, .i8, .i16, .i32, .i64 => @as(u64, @bitCast(@as(i64, @intCast(value)))) & lowMask(width),
        .u8, .u16, .u32, .u64 => @as(u64, @intCast(value)) & lowMask(width),
    };
}

fn makeFloatResult(comptime format: corpus.Format, value: floatType(format)) RawRuntimeResult {
    var result = emptyRawRuntimeResult();
    result.values[0] = encodeFloat(format, value);
    result.field_count = 1;
    return result;
}

fn makeUnaryFloatInvoker(
    comptime namespace: RuntimeNamespace,
    comptime operation: []const u8,
    comptime input_format: corpus.Format,
    comptime output_format: corpus.Format,
) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const input = decodeFloat(input_format, inputs[0].value_bits);
            const output: floatType(output_format) = if (comptime namespace == .root)
                @call(.auto, @field(zmath, operation), .{input})
            else if (comptime namespace == .scalar)
                @call(.auto, @field(zmath.scalar, operation), .{input})
            else
                @call(.auto, @field(zmath.ieee, operation), .{input});
            return makeFloatResult(output_format, output);
        }
    };
    return &Adapter.invoke;
}

fn makeBinaryFloatInvoker(
    comptime namespace: RuntimeNamespace,
    comptime operation: []const u8,
    comptime first_format: corpus.Format,
    comptime second_format: corpus.Format,
    comptime output_format: corpus.Format,
) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const first = decodeFloat(first_format, inputs[0].value_bits);
            const second = decodeFloat(second_format, inputs[1].value_bits);
            const output: floatType(output_format) = if (comptime namespace == .root)
                @call(.auto, @field(zmath, operation), .{ first, second })
            else if (comptime namespace == .scalar)
                @call(.auto, @field(zmath.scalar, operation), .{ first, second })
            else
                @call(.auto, @field(zmath.ieee, operation), .{ first, second });
            return makeFloatResult(output_format, output);
        }
    };
    return &Adapter.invoke;
}

fn makeTernaryFloatInvoker(
    comptime namespace: RuntimeNamespace,
    comptime operation: []const u8,
    comptime input_format: corpus.Format,
    comptime output_format: corpus.Format,
) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const first = decodeFloat(input_format, inputs[0].value_bits);
            const second = decodeFloat(input_format, inputs[1].value_bits);
            const third = decodeFloat(input_format, inputs[2].value_bits);
            const output: floatType(output_format) = if (comptime namespace == .root)
                @call(.auto, @field(zmath, operation), .{ first, second, third })
            else if (comptime namespace == .scalar)
                @call(.auto, @field(zmath.scalar, operation), .{ first, second, third })
            else
                @call(.auto, @field(zmath.ieee, operation), .{ first, second, third });
            return makeFloatResult(output_format, output);
        }
    };
    return &Adapter.invoke;
}

fn makeBinaryIntegerInvoker(
    comptime operation: []const u8,
    comptime input_format: corpus.Format,
    comptime integer_type: corpus.IntegerType,
    comptime output_format: corpus.Format,
) RuntimeInvoker {
    const Integer = switch (integer_type) {
        .i32 => i32,
        .i64 => i64,
        else => @compileError("binary integer invoker requires an i32 or i64 descriptor"),
    };
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const input = decodeFloat(input_format, inputs[0].value_bits);
            const integer_value: Integer = @intCast(decodeSignedInteger(
                integer_type,
                inputs[1].value_bits,
            ));
            const output: floatType(output_format) = @call(
                .auto,
                @field(zmath, operation),
                .{ input, integer_value },
            );
            return makeFloatResult(output_format, output);
        }
    };
    return &Adapter.invoke;
}

fn makeUnaryIntegerInvoker(
    comptime operation: []const u8,
    comptime input_format: corpus.Format,
    comptime output_type: corpus.IntegerType,
) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const input = decodeFloat(input_format, inputs[0].value_bits);
            const output = @call(.auto, @field(zmath, operation), .{input});
            var result = emptyRawRuntimeResult();
            result.values[0] = encodeInteger(output_type, output);
            result.field_count = 1;
            return result;
        }
    };
    return &Adapter.invoke;
}

fn makeFromFpInvoker(
    comptime operation: []const u8,
    comptime format: corpus.Format,
) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const input = decodeFloat(format, inputs[0].value_bits);
            const direction: zmath.FromFpRound = @enumFromInt(
                @as(u32, @intCast(inputs[1].value_bits)),
            );
            const width: u32 = @intCast(inputs[2].value_bits);
            const output: floatType(format) = @call(
                .auto,
                @field(zmath, operation),
                .{ input, direction, width },
            );
            return makeFloatResult(format, output);
        }
    };
    return &Adapter.invoke;
}

fn makeTagInvoker(
    comptime operation: []const u8,
    comptime format: corpus.Format,
) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const tag: []const u8 = if (inputs[0].tag_bytes == null)
                ""
            else
                inputs[0].tag_bytes[0..@intCast(inputs[0].tag_length)];
            const output: floatType(format) = @call(
                .auto,
                @field(zmath.ieee, operation),
                .{tag},
            );
            return makeFloatResult(format, output);
        }
    };
    return &Adapter.invoke;
}

fn makeOkStructureInvoker(
    comptime namespace: RuntimeNamespace,
    comptime operation: []const u8,
    comptime format: corpus.Format,
) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const input = decodeFloat(format, inputs[0].value_bits);
            const output = if (comptime namespace == .root)
                @call(.auto, @field(zmath, operation), .{input})
            else if (comptime namespace == .scalar)
                @call(.auto, @field(zmath.scalar, operation), .{input})
            else
                @call(.auto, @field(zmath.ieee, operation), .{input});
            var result = emptyRawRuntimeResult();
            result.values[0] = encodeFloat(format, output.value);
            result.values[1] = @intFromBool(output.ok);
            result.field_count = 2;
            return result;
        }
    };
    return &Adapter.invoke;
}

fn makeResolvedStructureInvoker(
    comptime operation: []const u8,
    comptime format: corpus.Format,
) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const first = decodeFloat(format, inputs[0].value_bits);
            const second = decodeFloat(format, inputs[1].value_bits);
            const output = @call(.auto, @field(zmath, operation), .{ first, second });
            var result = emptyRawRuntimeResult();
            result.values[0] = encodeFloat(format, output.value);
            result.values[1] = @intFromBool(output.resolved);
            result.field_count = 2;
            return result;
        }
    };
    return &Adapter.invoke;
}

fn makePowerStructureInvoker(
    comptime operation: []const u8,
    comptime format: corpus.Format,
) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const input = decodeFloat(format, inputs[0].value_bits);
            const exponent = decodeSignedInteger(.i64, inputs[1].value_bits);
            const output = @call(.auto, @field(zmath, operation), .{ input, exponent });
            var result = emptyRawRuntimeResult();
            result.values[0] = encodeFloat(format, output.value);
            result.values[1] = @intFromBool(output.ok);
            result.field_count = 2;
            return result;
        }
    };
    return &Adapter.invoke;
}

fn makeIntegerResultInvoker(
    comptime operation: []const u8,
    comptime format: corpus.Format,
) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const input = decodeFloat(format, inputs[0].value_bits);
            const output = @call(.auto, @field(zmath, operation), .{input});
            var result = emptyRawRuntimeResult();
            result.values[0] = encodeInteger(.i64, output.value);
            result.values[1] = @intFromBool(output.ok);
            result.field_count = 2;
            return result;
        }
    };
    return &Adapter.invoke;
}

fn makeFrexpInvoker(comptime format: corpus.Format) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const input = decodeFloat(format, inputs[0].value_bits);
            const output = @call(.auto, zmath.frexp, .{input});
            var result = emptyRawRuntimeResult();
            result.values[0] = encodeFloat(format, output.fraction);
            result.values[1] = encodeInteger(.i32, output.exponent);
            result.field_count = 2;
            return result;
        }
    };
    return &Adapter.invoke;
}

fn makeModfInvoker(comptime format: corpus.Format) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const input = decodeFloat(format, inputs[0].value_bits);
            const output = @call(.auto, zmath.modf, .{input});
            var result = emptyRawRuntimeResult();
            result.values[0] = encodeFloat(format, output.fractional);
            result.values[1] = encodeFloat(format, output.integral);
            result.field_count = 2;
            return result;
        }
    };
    return &Adapter.invoke;
}

fn makeRemquoInvoker(comptime format: corpus.Format) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const first = decodeFloat(format, inputs[0].value_bits);
            const second = decodeFloat(format, inputs[1].value_bits);
            const output = @call(.auto, zmath.remquo, .{ first, second });
            var result = emptyRawRuntimeResult();
            result.values[0] = encodeFloat(format, output.value);
            result.values[1] = encodeInteger(.i32, output.quotient);
            result.field_count = 2;
            return result;
        }
    };
    return &Adapter.invoke;
}

fn makeLgammaInvoker(comptime format: corpus.Format) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const input = decodeFloat(format, inputs[0].value_bits);
            const output = @call(.auto, zmath.lgamma, .{input});
            var result = emptyRawRuntimeResult();
            result.values[0] = encodeFloat(format, output.value);
            result.values[1] = encodeInteger(.i2, output.sign);
            result.field_count = 2;
            return result;
        }
    };
    return &Adapter.invoke;
}

fn makeBooleanInvoker(
    comptime operation: []const u8,
    comptime format: corpus.Format,
) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const first = decodeFloat(format, inputs[0].value_bits);
            const second = decodeFloat(format, inputs[1].value_bits);
            const output: bool = @call(
                .auto,
                @field(zmath.ieee, operation),
                .{ first, second },
            );
            var result = emptyRawRuntimeResult();
            result.values[0] = @intFromBool(output);
            result.field_count = 1;
            return result;
        }
    };
    return &Adapter.invoke;
}

const NarrowSpec = struct {
    operation: []const u8,
    input_format: corpus.Format,
    output_format: corpus.Format,
    namespace: RuntimeNamespace,
};

const root_unary_operations = [_][]const u8{
    "abs",    "acos",    "acosh",     "acospi", "asin",  "asinh",
    "asinpi", "atan",    "atanh",     "atanpi", "cbrt",  "ceil",
    "cos",    "cosh",    "cospi",     "erf",    "erfc",  "exp",
    "exp10",  "exp10m1", "exp2",      "exp2m1", "expm1", "floor",
    "log",    "log10",   "log10p1",   "log1p",  "log2",  "log2p1",
    "logb",   "logp1",   "nearbyint", "rint",   "round", "roundeven",
    "rsqrt",  "sin",     "sinh",      "sinpi",  "sqrt",  "tan",
    "tanh",   "tanpi",   "tgamma",    "trunc",
};

const root_binary_operations = [_][]const u8{
    "fdim",             "fmax",             "fmaximum",     "fmaximum_mag",
    "fmaximum_mag_num", "fmaximum_num",     "fmin",         "fminimum",
    "fminimum_mag",     "fminimum_mag_num", "fminimum_num", "fmod",
    "hypot",            "pow",              "powr",         "remainder",
};

const narrow_unary_operations = [_]NarrowSpec{
    .{ .operation = "f16sqrtf32", .input_format = .f, .output_format = .h, .namespace = .scalar },
    .{ .operation = "f16sqrtf64", .input_format = .d, .output_format = .h, .namespace = .scalar },
    .{ .operation = "f32sqrtf64", .input_format = .d, .output_format = .f, .namespace = .scalar },
};

const narrow_binary_operations = [_]NarrowSpec{
    .{ .operation = "fadd", .input_format = .d, .output_format = .f, .namespace = .root },
    .{ .operation = "fsub", .input_format = .d, .output_format = .f, .namespace = .root },
    .{ .operation = "fmul", .input_format = .d, .output_format = .f, .namespace = .root },
    .{ .operation = "fdiv", .input_format = .d, .output_format = .f, .namespace = .root },
    .{ .operation = "f16addf32", .input_format = .f, .output_format = .h, .namespace = .scalar },
    .{ .operation = "f16subf32", .input_format = .f, .output_format = .h, .namespace = .scalar },
    .{ .operation = "f16mulf32", .input_format = .f, .output_format = .h, .namespace = .scalar },
    .{ .operation = "f16divf32", .input_format = .f, .output_format = .h, .namespace = .scalar },
    .{ .operation = "f16addf64", .input_format = .d, .output_format = .h, .namespace = .scalar },
    .{ .operation = "f16subf64", .input_format = .d, .output_format = .h, .namespace = .scalar },
    .{ .operation = "f16mulf64", .input_format = .d, .output_format = .h, .namespace = .scalar },
    .{ .operation = "f16divf64", .input_format = .d, .output_format = .h, .namespace = .scalar },
    .{ .operation = "f32addf64", .input_format = .d, .output_format = .f, .namespace = .scalar },
    .{ .operation = "f32subf64", .input_format = .d, .output_format = .f, .namespace = .scalar },
    .{ .operation = "f32mulf64", .input_format = .d, .output_format = .f, .namespace = .scalar },
    .{ .operation = "f32divf64", .input_format = .d, .output_format = .f, .namespace = .scalar },
};

const narrow_ternary_operations = [_]NarrowSpec{
    .{ .operation = "ffma", .input_format = .d, .output_format = .f, .namespace = .root },
    .{ .operation = "f16fmaf32", .input_format = .f, .output_format = .h, .namespace = .scalar },
    .{ .operation = "f16fmaf64", .input_format = .d, .output_format = .h, .namespace = .scalar },
    .{ .operation = "f32fmaf64", .input_format = .d, .output_format = .f, .namespace = .scalar },
};

const ieee_unary_operations = [_][]const u8{ "getPayload", "nextUp", "nextDown" };
const ieee_binary_operations = [_][]const u8{ "copySign", "nextAfter" };
const ieee_boolean_operations = [_][]const u8{ "totalOrder", "totalOrderMag" };
const power_operations = [_][]const u8{ "pown", "compoundn", "rootn" };
const integer_result_operations = [_][]const u8{ "lrint", "llrint", "lround", "llround" };
const fromfp_operations = [_][]const u8{ "fromfp", "ufromfp", "fromfpx", "ufromfpx" };
const scale_i32_operations = [_][]const u8{ "ldexp", "scalbn" };

const formats = [_]corpus.Format{ .h, .f, .d };

fn formatSuffix(comptime format: corpus.Format) []const u8 {
    return switch (format) {
        .h => "h",
        .f => "f",
        .d => "d",
    };
}

fn suffixedOperation(comptime operation: []const u8, comptime format: corpus.Format) []const u8 {
    return std.fmt.comptimePrint("{s}{s}", .{ operation, formatSuffix(format) });
}

fn floatArgument(comptime format: corpus.Format) corpus.InputDescriptor {
    return .{ .float = format };
}

fn integerArgument(comptime integer_type: corpus.IntegerType) corpus.InputDescriptor {
    return .{ .integer = integer_type };
}

fn makeEntry(
    comptime operation: []const u8,
    comptime arguments: anytype,
    comptime result: corpus.ResultDescriptor,
    comptime invoke: RuntimeInvoker,
) RuntimeEntry {
    var input_descriptors: [max_oracle_fields]OracleFieldDescriptor = undefined;
    inline for (arguments, 0..) |argument, index| {
        input_descriptors[index] = argument.oracleDescriptor();
    }
    var result_descriptors: [max_oracle_fields]OracleFieldDescriptor = undefined;
    inline for (0..result.oracleFieldCount()) |index| {
        result_descriptors[index] = result.oracleFieldDescriptor(index).?;
    }
    return .{
        .operation = operation,
        .input_descriptors = input_descriptors,
        .input_count = @typeInfo(@TypeOf(arguments)).@"struct".fields.len,
        .result_descriptors = result_descriptors,
        .result_count = result.oracleFieldCount(),
        .result_layout = result.oracleLayout(),
        .structure_kind = result.oracleStructureKind(),
        .invoke = invoke,
    };
}

fn structureResult(
    comptime kind: corpus.StructureKind,
    comptime format: corpus.Format,
) corpus.ResultDescriptor {
    return .{ .structure = .{ .kind = kind, .format = format } };
}

fn append(table: *RuntimeTable, entry: RuntimeEntry) void {
    if (table.count == table.entries.len) @compileError("runtime table is full");
    table.entries[table.count] = entry;
    table.count += 1;
}

fn buildRuntimeTable() RuntimeTable {
    @setEvalBranchQuota(2_000_000);

    var table: RuntimeTable = .{ .entries = undefined, .count = 0 };

    inline for (root_unary_operations) |operation| {
        inline for (formats) |format| {
            append(&table, makeEntry(
                operation,
                .{floatArgument(format)},
                .{ .float = format },
                makeUnaryFloatInvoker(.root, operation, format, format),
            ));
        }
    }
    inline for (root_binary_operations) |operation| {
        inline for (formats) |format| {
            append(&table, makeEntry(
                operation,
                .{ floatArgument(format), floatArgument(format) },
                .{ .float = format },
                makeBinaryFloatInvoker(.root, operation, format, format, format),
            ));
        }
    }
    inline for (formats) |format| {
        append(&table, makeEntry(
            "fma",
            .{ floatArgument(format), floatArgument(format), floatArgument(format) },
            .{ .float = format },
            makeTernaryFloatInvoker(.root, "fma", format, format),
        ));
        append(&table, makeEntry(
            "frexp",
            .{floatArgument(format)},
            structureResult(.frexp, format),
            makeFrexpInvoker(format),
        ));
        append(&table, makeEntry(
            "modf",
            .{floatArgument(format)},
            structureResult(.modf, format),
            makeModfInvoker(format),
        ));
        append(&table, makeEntry(
            "lgamma",
            .{floatArgument(format)},
            structureResult(.lgamma, format),
            makeLgammaInvoker(format),
        ));
        inline for (integer_result_operations) |operation| {
            append(&table, makeEntry(
                operation,
                .{floatArgument(format)},
                structureResult(.integer, format),
                makeIntegerResultInvoker(operation, format),
            ));
        }
        append(&table, makeEntry(
            "ilogb",
            .{floatArgument(format)},
            .{ .integer = .i32 },
            makeUnaryIntegerInvoker("ilogb", format, .i32),
        ));
        append(&table, makeEntry(
            "llogb",
            .{floatArgument(format)},
            .{ .integer = .i64 },
            makeUnaryIntegerInvoker("llogb", format, .i64),
        ));
        inline for (fromfp_operations) |operation| {
            append(&table, makeEntry(
                operation,
                .{
                    floatArgument(format),
                    @as(corpus.InputDescriptor, .fromfp_round),
                    integerArgument(.u32),
                },
                .{ .float = format },
                makeFromFpInvoker(operation, format),
            ));
        }
        inline for (scale_i32_operations) |operation| {
            append(&table, makeEntry(
                operation,
                .{ floatArgument(format), integerArgument(.i32) },
                .{ .float = format },
                makeBinaryIntegerInvoker(operation, format, .i32, format),
            ));
        }
        append(&table, makeEntry(
            "scalbln",
            .{ floatArgument(format), integerArgument(.i64) },
            .{ .float = format },
            makeBinaryIntegerInvoker("scalbln", format, .i64, format),
        ));
        inline for (power_operations) |operation| {
            append(&table, makeEntry(
                operation,
                .{ floatArgument(format), integerArgument(.i64) },
                structureResult(.power, format),
                makePowerStructureInvoker(operation, format),
            ));
        }
        inline for (.{ "atan2", "atan2pi" }) |operation| {
            append(&table, makeEntry(
                operation,
                .{ floatArgument(format), floatArgument(format) },
                structureResult(.atan2, format),
                makeResolvedStructureInvoker(operation, format),
            ));
        }
        append(&table, makeEntry(
            "remquo",
            .{ floatArgument(format), floatArgument(format) },
            structureResult(.remquo, format),
            makeRemquoInvoker(format),
        ));
        inline for (ieee_unary_operations) |operation| {
            append(&table, makeEntry(
                operation,
                .{floatArgument(format)},
                .{ .float = format },
                makeUnaryFloatInvoker(
                    .ieee,
                    suffixedOperation(operation, format),
                    format,
                    format,
                ),
            ));
        }
        inline for (ieee_binary_operations) |operation| {
            append(&table, makeEntry(
                operation,
                .{ floatArgument(format), floatArgument(format) },
                .{ .float = format },
                makeBinaryFloatInvoker(
                    .ieee,
                    suffixedOperation(operation, format),
                    format,
                    format,
                    format,
                ),
            ));
        }
        inline for (ieee_boolean_operations) |operation| {
            append(&table, makeEntry(
                operation,
                .{ floatArgument(format), floatArgument(format) },
                .{ .boolean = {} },
                makeBooleanInvoker(suffixedOperation(operation, format), format),
            ));
        }
        append(&table, makeEntry(
            "nextToward",
            .{ floatArgument(format), floatArgument(.d) },
            .{ .float = format },
            makeBinaryFloatInvoker(
                .ieee,
                suffixedOperation("nextToward", format),
                format,
                .d,
                format,
            ),
        ));
        append(&table, makeEntry(
            "canonicalize",
            .{floatArgument(format)},
            structureResult(.canonicalize, format),
            makeOkStructureInvoker(.ieee, suffixedOperation("canonicalize", format), format),
        ));
        append(&table, makeEntry(
            "setPayload",
            .{floatArgument(format)},
            structureResult(.payload, format),
            makeOkStructureInvoker(.ieee, suffixedOperation("setPayload", format), format),
        ));
        append(&table, makeEntry(
            "setPayloadSig",
            .{floatArgument(format)},
            structureResult(.payload, format),
            makeOkStructureInvoker(.ieee, suffixedOperation("setPayloadSig", format), format),
        ));
        append(&table, makeEntry(
            "nan",
            .{@as(corpus.InputDescriptor, .tag)},
            .{ .float = format },
            makeTagInvoker(suffixedOperation("nan", format), format),
        ));
    }

    inline for (narrow_unary_operations) |spec| {
        append(&table, makeEntry(
            spec.operation,
            .{floatArgument(spec.input_format)},
            .{ .float = spec.output_format },
            makeUnaryFloatInvoker(
                spec.namespace,
                spec.operation,
                spec.input_format,
                spec.output_format,
            ),
        ));
    }
    append(&table, makeEntry(
        "fsqrt",
        .{floatArgument(.d)},
        .{ .float = .f },
        makeUnaryFloatInvoker(.root, "fsqrt", .d, .f),
    ));
    inline for (narrow_binary_operations) |spec| {
        append(&table, makeEntry(
            spec.operation,
            .{ floatArgument(spec.input_format), floatArgument(spec.input_format) },
            .{ .float = spec.output_format },
            makeBinaryFloatInvoker(
                spec.namespace,
                spec.operation,
                spec.input_format,
                spec.input_format,
                spec.output_format,
            ),
        ));
    }
    inline for (narrow_ternary_operations) |spec| {
        append(&table, makeEntry(
            spec.operation,
            .{
                floatArgument(spec.input_format),
                floatArgument(spec.input_format),
                floatArgument(spec.input_format),
            },
            .{ .float = spec.output_format },
            makeTernaryFloatInvoker(
                spec.namespace,
                spec.operation,
                spec.input_format,
                spec.output_format,
            ),
        ));
    }
    if (table.count != 315) @compileError("runtime table does not cover the descriptor corpus");
    return table;
}

const runtime_table = buildRuntimeTable();

fn classifyFloatBits(descriptor: OracleFieldDescriptor, bits: u64) corpus.OracleClass {
    const format = descriptor.format;
    const fraction_mask = lowMask(format.fraction_bits);
    const exponent_mask = lowMask(format.exponent_bits) <<
        @as(u6, @intCast(format.fraction_bits));
    const fraction = bits & fraction_mask;
    const exponent = bits & exponent_mask;

    if (exponent == 0) return if (fraction == 0) .zero else .subnormal;
    if (exponent == exponent_mask) {
        if (fraction == 0) return .infinity;
        const quiet_mask = switch (format.code) {
            .h => @as(u64, 0x0200),
            .f => @as(u64, 0x0040_0000),
            .d => @as(u64, 0x0008_0000_0000_0000),
            else => 0,
        };
        return if ((fraction & quiet_mask) == 0) .snan else .qnan;
    }
    return .normal;
}

fn lowMask(bit_count: u32) u64 {
    if (bit_count == 0) return 0;
    if (bit_count >= 64) return std.math.maxInt(u64);
    return (@as(u64, 1) << @as(u6, @intCast(bit_count))) - 1;
}

fn bitsFitDescriptor(descriptor: OracleFieldDescriptor, bits: u64) bool {
    switch (descriptor.kind) {
        .float => {
            if (descriptor.value_bits == 0 or descriptor.value_bits > 64) return false;
            return bits <= lowMask(descriptor.value_bits);
        },
        .signed_integer, .unsigned_integer => {
            if (descriptor.value_bits == 0 or descriptor.value_bits > 64) return false;
            return bits <= lowMask(descriptor.value_bits);
        },
        .boolean => return bits <= 1,
        .tag => return bits == 0,
        .rounding => return bits <= 4,
        _ => return false,
    }
}

fn valueBitsFitDescriptor(descriptor: OracleFieldDescriptor, bits: u64) bool {
    return switch (descriptor.kind) {
        .float => bits <= lowMask(descriptor.value_bits),
        .signed_integer, .unsigned_integer => bits <= lowMask(descriptor.value_bits),
        .boolean => bits <= 1,
        else => false,
    };
}
fn emptyOracleResult(fields: []OracleResultField) OracleResult {
    return .{
        .status = .@"error",
        .reserved = 0,
        .field_capacity = @intCast(fields.len),
        .field_count = 0,
        .fields = outputPointer(fields),
    };
}

fn runtimeOracleResult(runtime: *RuntimeResult) OracleResult {
    const fields = runtime.fields[0..runtime.field_count];
    return .{
        .status = .ok,
        .reserved = 0,
        .field_capacity = @intCast(fields.len),
        .field_count = @intCast(fields.len),
        .fields = outputPointer(fields),
    };
}

fn expectReferenceOk(status: corpus.OracleStatus) RunError!void {
    switch (status) {
        .ok => {},
        .unsupported => return error.ReferenceUnsupported,
        .@"error" => return error.ReferenceError,
        .uncertain => return error.ReferenceUncertain,
        else => return error.ReferenceError,
    }
}

fn expectProofOk(status: corpus.OracleStatus) RunError!void {
    switch (status) {
        .ok => {},
        .unsupported => return error.ProofUnsupported,
        .@"error" => return error.ProofError,
        .uncertain => return error.ProofUncertain,
        else => return error.ProofError,
    }
}

fn compareEvidence(
    runtime: *const RuntimeResult,
    evidence: OracleResult,
    shape_error: RunError,
) RunError!void {
    if (evidence.reserved != 0 or
        evidence.field_count != @as(u32, @intCast(runtime.field_count)) or
        evidence.field_capacity < evidence.field_count or
        evidence.fields == null)
    {
        return shape_error;
    }

    for (runtime.fields[0..runtime.field_count], 0..) |runtime_field, index| {
        const evidence_field = evidence.fields[index];
        if (!fieldDescriptorEqual(runtime_field.descriptor, evidence_field.descriptor) or
            evidence_field.reserved != 0)
        {
            return shape_error;
        }
        if (runtime_field.value_bits != evidence_field.value_bits or
            runtime_field.class_code != evidence_field.class_code)
        {
            return error.RuntimeMismatch;
        }
    }
}

fn fieldDescriptorEqual(a: OracleFieldDescriptor, b: OracleFieldDescriptor) bool {
    return a.kind == b.kind and
        a.value_bits == b.value_bits and
        formatDescriptorEqual(a.format, b.format) and
        a.reserved == b.reserved;
}

fn formatDescriptorEqual(a: OracleFormatDescriptor, b: OracleFormatDescriptor) bool {
    return a.code == b.code and
        a.storage_bits == b.storage_bits and
        a.exponent_bits == b.exponent_bits and
        a.fraction_bits == b.fraction_bits and
        a.reserved == b.reserved;
}

fn constPointer(comptime T: type, values: []const T) [*c]const T {
    if (values.len == 0) return null;
    return values.ptr;
}

fn outputPointer(values: []OracleResultField) [*c]OracleResultField {
    if (values.len == 0) return null;
    return values.ptr;
}

const unary_h_campaign_inputs = [_]u64{
    0x0000,
    0x8000,
    0x0001,
    0x03ff,
    0x3c00,
    0x4000,
    0x3800,
};
const unary_f_campaign_inputs = [_]u64{
    0x0000_0000,
    0x8000_0000,
    0x0000_0001,
    0x007f_ffff,
    0x3f80_0000,
    0x4000_0000,
    0x3f00_0000,
};
const unary_d_campaign_inputs = [_]u64{
    0x0000_0000_0000_0000,
    0x8000_0000_0000_0000,
    0x0000_0000_0000_0001,
    0x000f_ffff_ffff_ffff,
    0x3ff0_0000_0000_0000,
    0x4000_0000_0000_0000,
    0x3fe0_0000_0000_0000,
};

pub fn campaignInputs(function: Function) ?[]const u64 {
    const arguments = function.arguments();
    if (arguments.len != 1) return null;
    return switch (arguments[0]) {
        .float => |format| switch (format) {
            .h => unary_h_campaign_inputs[0..],
            .f => unary_f_campaign_inputs[0..],
            .d => unary_d_campaign_inputs[0..],
        },
        else => null,
    };
}

const no_inputs = [_]u64{};

fn expRuntimeBits(format: corpus.Format, input_bits: u64) u64 {
    return switch (format) {
        .h => @as(u64, @intCast(@as(u16, @bitCast(zmath.scalar.exph(@bitCast(@as(u16, @truncate(input_bits)))))))),
        .f => @as(u64, @intCast(@as(u32, @bitCast(zmath.scalar.expf(@bitCast(@as(u32, @truncate(input_bits)))))))),
        .d => @bitCast(zmath.scalar.expd(@bitCast(input_bits))),
    };
}

fn oracleStatusOk(status: corpus.OracleStatus) RunError!void {
    return switch (status) {
        .ok => {},
        .unsupported => error.ReferenceUnsupported,
        .uncertain => error.ReferenceUncertain,
        .@"error" => error.ReferenceError,
        _ => error.ReferenceError,
    };
}

fn runExpDirect(format: corpus.Format, input_bits: u64) RunError!void {
    const input_descriptor = (corpus.InputDescriptor{ .float = format }).oracleDescriptor();
    const result_descriptor = (corpus.ResultDescriptor{ .float = format }).oracleFieldDescriptor(0) orelse
        return error.InvalidResultDescriptor;
    var inputs = [_]OracleInputField{corpus.oracleInputField(input_descriptor, input_bits)};
    var result_descriptors = [_]OracleFieldDescriptor{result_descriptor};
    var request = OracleRequest{
        .abi_version = corpus.oracle_abi_version,
        .reserved = 0,
        .operation = "exp",
        .operation_length = 3,
        .arity = 1,
        .input_fields = &inputs,
        .input_field_count = 1,
        .result_layout = .scalar,
        .structure_kind = .none,
        .result_field_count = 1,
        .result_fields = &result_descriptors,
    };
    var reference_fields = [_]OracleResultField{undefined};
    var reference = OracleResult{ .status = .@"error", .reserved = 0, .field_capacity = 1, .field_count = 0, .fields = &reference_fields };
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &reference);
    try oracleStatusOk(reference.status);
    const candidate_bits = expRuntimeBits(format, input_bits);
    const candidate_class = classifyFloatBits(result_descriptor, candidate_bits);
    if (reference.field_count != 1 or reference.fields[0].value_bits != candidate_bits or
        reference.fields[0].class_code != candidate_class)
    {
        return error.RuntimeMismatch;
    }
    var candidate_fields = [_]OracleResultField{.{ .descriptor = result_descriptor, .value_bits = candidate_bits, .class_code = candidate_class, .reserved = 0 }};
    var candidate = OracleResult{ .status = .ok, .reserved = 0, .field_capacity = 1, .field_count = 1, .fields = &candidate_fields };
    var proof_fields = [_]OracleResultField{undefined};
    var proof = OracleResult{ .status = .@"error", .reserved = 0, .field_capacity = 1, .field_count = 0, .fields = &proof_fields };
    corpus.zmath_testing_oracle_v2_arb_prove(&request, &candidate, &proof);
    try oracleStatusOk(proof.status);
    if (proof.field_count != 1 or proof.fields[0].class_code != candidate_class) return error.ProofShapeMismatch;
}

// This path is intentionally Exp-only. It avoids the full 315-entry dispatch table.
pub fn runExp(format: corpus.Format, input_bits: u64) RunError!void {
    return runExpDirect(format, input_bits);
}

fn nextPrng(state: *u64) u64 {
    var value = state.*;
    value ^= value << 13;
    value ^= value >> 7;
    value ^= value << 17;
    state.* = value;
    return value;
}

pub fn fuzzSeeded(seed: u64, sample_count: usize) RunError!void {
    var state = seed;
    var index: usize = 0;
    while (index < sample_count) : (index += 1) {
        try runExp(.h, nextPrng(&state) & 0xffff);
        try runExp(.f, @as(u64, @as(u32, @truncate(nextPrng(&state)))));
        try runExp(.d, nextPrng(&state));
    }
}

pub fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    try runExp(.h, smith.value(u16));
    try runExp(.f, smith.value(u32));
    try runExp(.d, smith.value(u64));
}

test "candidate evidence does not grant accepted execution" {
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    var candidate = found: {
        var functions = manifest.functions();
        while (try functions.next()) |function| {
            if (std.mem.eql(u8, function.op, "acos") and
                function.result.floatFormat() == .h) break :found function;
        }
        return error.MissingFunction;
    };
    candidate.status = .unsupported;
    candidate.oracle = .none;
    const evidence = switch (try evaluateFunction(candidate, &.{0})) {
        .verified => |value| value,
        .unsupported => return error.MissingCandidateEvidence,
    };
    try std.testing.expectEqual(@as(u64, 0x3e48), evidence.fields[0].value_bits);
    const reason = switch (try runFunction(candidate, &.{0})) {
        .unsupported => |value| value,
        .verified => return error.UnacceptedExecution,
    };
    try std.testing.expectEqual(UnsupportedReason.manifest_status, reason);
}
