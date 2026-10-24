const std = @import("std");
const zmath = @import("zmath");
const corpus = @import("corpus_support");

comptime {
    @setEvalBranchQuota(2_000_000);
}

pub const Function = corpus.Function;
const OracleFieldDescriptor = corpus.OracleFieldDescriptor;
const OracleFormatDescriptor = corpus.OracleFormatDescriptor;
const OracleInputField = corpus.OracleInputField;
const OracleRequest = corpus.OracleRequest;
const OracleResult = corpus.OracleResult;
const OracleResultField = corpus.OracleResultField;
const max_oracle_fields: usize = corpus.max_argument_count;

// Four packed lanes times the eight-field result ceiling fill the thirty-two
// slot raw word buffer exactly, so a batch never truncates and never
// overwrites. Only the single-float entries reach this lane; the ceiling is
// what keeps the worst case honest.
pub const vector_lane_count: usize = 4;

comptime {
    if (corpus.max_result_field_count > corpus.max_argument_count) {
        @compileError("result field ceiling exceeds the raw result word buffer");
    }
    if (vector_lane_count * corpus.max_result_field_count > corpus.max_argument_count) {
        @compileError("vector lane count overflows the raw result word buffer");
    }
}

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
    classification_result,
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

    pub fn resultFields(self: *const VerifiedEvidence) []const OracleResultField {
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
    InputTagTooLong,
    InvalidResultClass,
    InvalidResultDescriptor,
    OperationTooLong,
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

    pub fn invoke(
        self: *const PreparedRuntime,
        inputs: *const [corpus.max_argument_count]OracleInputField,
    ) RawRuntimeResult {
        return self.entry.invoke(inputs);
    }

    pub fn resultFieldCount(self: *const PreparedRuntime) usize {
        return self.entry.result_count;
    }

    pub fn resultDescriptors(self: *const PreparedRuntime) []const OracleFieldDescriptor {
        return self.entry.result_descriptors[0..self.entry.result_count];
    }
};

const RequestStorage = struct {
    input_fields: [max_oracle_fields]OracleInputField,
    result_fields: [max_oracle_fields]OracleFieldDescriptor,
    result_field_count: usize,
    request: OracleRequest,

    fn initialize(
        self: *RequestStorage,
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
                // The ABI carries the tag length in a u32. A caller tag wider
                // than that is refused instead of narrowed.
                .tag_length = std.math.cast(u32, tag.len) orelse
                    return error.InputTagTooLong,
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
            // Manifest operation names are short, but the ABI field is a u32,
            // so the encoder states the width instead of narrowing blindly.
            .operation_length = std.math.cast(u32, function.op.len) orelse
                return error.OperationTooLong,
            // `function.arity` is a u8 that the shape guard above forced to
            // equal `arguments.len`, so it already carries the input count.
            .arity = function.arity,
            .input_fields = constPointer(
                OracleInputField,
                self.input_fields[0..arguments.len],
            ),
            .input_field_count = function.arity,
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
    // A definitional row is a first-class oracle category. Its correct answer
    // is fixed by the IEEE 754 encoding rather than decided by an
    // arbitrary-precision evaluation, and the C bridge reports it under its own
    // category. Refusing it here would leave the four bit-level operations
    // permanently unrunnable.
    if (function.oracle != .mpfr_arb and function.oracle != .exact_bits and
        function.oracle != .algebraic and function.oracle != .definitional)
    {
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
        .classification => .{ .unsupported = .classification_result },
    };
}

pub fn runFunction(function: Function, input_bits: []const u64) RunError!RunOutcome {
    const no_tags: []const []const u8 = &.{};
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
    const no_tags: []const []const u8 = &.{};
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
            .classification => |value| {
                // A class carries no float classification code, so requiring
                // .none also rejects a class arriving through a float field.
                if (descriptor.kind != .classification or
                    actual.value_bits != corpusClassificationCode(value) or
                    actual.class_code != .none)
                {
                    return error.RuntimeMismatch;
                }
            },
            .tag, .rounding, .round_mode => return error.InvalidResultDescriptor,
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
            .classification => .{
                .classification = parseClassificationCode(actual.value_bits) orelse
                    return error.RuntimeMismatch,
            },
            // A round mode, a rounding field and a tag are input shapes. None of
            // them is ever a result, so a descriptor claiming one is a shape
            // error rather than a value this code should decode.
            .tag, .rounding, .round_mode => return error.InvalidResultDescriptor,
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
    var reference = try emptyOracleResult(
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

    var candidate = try runtimeOracleResult(&runtime);
    var proof_fields: [max_oracle_fields]OracleResultField = undefined;
    var proof = try emptyOracleResult(proof_fields[0..storage.result_field_count]);
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
    if (@as(usize, function.arity) != function.arguments().len) return null;
    for (runtime_table.entries[0..runtime_table.count]) |*entry| {
        if (!std.mem.eql(u8, function.op, entry.operation)) continue;
        if (entryMatchesFunction(entry.*, function)) return entry;
    }
    return null;
}

// Whether a row's descriptors are the ones an entry declares. The scalar
// lookup, the packed lane lookup and the build-time lane binding all compare
// the same way, so a lane row and the scalar row it serves can never describe
// different records.
fn entryMatchesFunction(entry: RuntimeEntry, function: Function) bool {
    const arguments = function.arguments();
    if (arguments.len != entry.input_count) return false;
    if (function.result.oracleFieldCount() != entry.result_count) return false;
    if (function.result.oracleLayout() != entry.result_layout) return false;
    if (function.result.oracleStructureKind() != entry.structure_kind) return false;
    for (arguments, 0..) |argument, index| {
        if (!fieldDescriptorEqual(
            argument.oracleDescriptor(),
            entry.input_descriptors[index],
        )) {
            return false;
        }
    }
    for (0..entry.result_count) |index| {
        const descriptor = function.result.oracleFieldDescriptor(index) orelse return false;
        if (!fieldDescriptorEqual(descriptor, entry.result_descriptors[index])) return false;
    }
    return true;
}

fn emptyRawRuntimeResult() RawRuntimeResult {
    return .{
        .values = @splat(0),
        .field_count = 0,
    };
}

fn FloatType(comptime format: corpus.Format) type {
    return switch (format) {
        .h => f16,
        .f => f32,
        .d => f64,
    };
}

fn FloatBitsType(comptime format: corpus.Format) type {
    return switch (format) {
        .h => u16,
        .f => u32,
        .d => u64,
    };
}

fn decodeFloat(comptime format: corpus.Format, bits: u64) FloatType(format) {
    const bits_type = FloatBitsType(format);
    return @bitCast(@as(bits_type, @intCast(bits)));
}

fn encodeFloat(comptime format: corpus.Format, value: FloatType(format)) u64 {
    const bits_type = FloatBitsType(format);
    return @intCast(@as(bits_type, @bitCast(value)));
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

fn makeFloatResult(comptime format: corpus.Format, value: FloatType(format)) RawRuntimeResult {
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
            const output: FloatType(output_format) = if (comptime namespace == .root)
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
            const output: FloatType(output_format) = if (comptime namespace == .root)
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
            const output: FloatType(output_format) = if (comptime namespace == .root)
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
            const output: FloatType(output_format) = @call(
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
            const direction: zmath.FromFpRound = @fromBackingInt(@intCast(
                @as(u32, @intCast(inputs[1].value_bits)),
            ));
            const width: u32 = @intCast(inputs[2].value_bits);
            const output: FloatType(format) = @call(
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
            const output: FloatType(format) = @call(
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

// zmath.ieee.Class and corpus.Classification are declared in two different
// modules and nothing in the type system ties their members together. They
// name the same six IEEE 754 classes today, but a positional @intFromEnum
// would keep compiling after either enum was reordered and would then report a
// different class for the same encoding, so every pair is named here. Neither
// switch carries an `else`: a new member on either side is a compile error
// rather than a silently accepted seventh class.
fn corpusClassificationCode(classification: corpus.Classification) u64 {
    return switch (classification) {
        .zero => 0,
        .subnormal => 1,
        .normal => 2,
        .infinity => 3,
        .quiet_nan => 4,
        .signaling_nan => 5,
    };
}

fn parseClassificationCode(bits: u64) ?corpus.Classification {
    return switch (bits) {
        0 => .zero,
        1 => .subnormal,
        2 => .normal,
        3 => .infinity,
        4 => .quiet_nan,
        5 => .signaling_nan,
        else => null,
    };
}

fn classificationCode(class: zmath.ieee.Class) u64 {
    return corpusClassificationCode(switch (class) {
        .zero => .zero,
        .subnormal => .subnormal,
        .normal => .normal,
        .infinity => .infinity,
        .quiet_nan => .quiet_nan,
        .signaling_nan => .signaling_nan,
    });
}

fn makeClassificationInvoker(
    comptime operation: []const u8,
    comptime format: corpus.Format,
) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const input = decodeFloat(format, inputs[0].value_bits);
            const class = @call(.auto, @field(zmath.ieee, operation), .{input});
            var result = emptyRawRuntimeResult();
            result.values[0] = classificationCode(class);
            result.field_count = 1;
            return result;
        }
    };
    return &Adapter.invoke;
}

// The distance is reported in an unsigned integer as wide as the format, so a
// binary16 span of 0..0xffff is never truncated by a narrower result field.
// The width is stated per format rather than derived from the format's bit
// count, so widening one is a deliberate edit and not a silent consequence.
fn ulpDistanceIntegerType(comptime format: corpus.Format) corpus.IntegerType {
    return switch (format) {
        .h => .u16,
        .f => .u32,
        .d => .u64,
    };
}

fn makeUlpDistanceInvoker(
    comptime operation: []const u8,
    comptime format: corpus.Format,
    comptime output_type: corpus.IntegerType,
) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const first = decodeFloat(format, inputs[0].value_bits);
            const second = decodeFloat(format, inputs[1].value_bits);
            const distance = @call(
                .auto,
                @field(zmath.scalar, operation),
                .{ first, second },
            );
            var result = emptyRawRuntimeResult();
            // A NaN operand reports the widest distance the format can name.
            // encodeInteger masks to the result width, so the all-ones answer
            // survives a binary16 result unchanged.
            result.values[0] = encodeInteger(output_type, distance);
            result.field_count = 1;
            return result;
        }
    };
    return &Adapter.invoke;
}

// The four IEEE 754 directions are an input value, not a descriptor, so the
// field kind alone does not prove the payload is one of them: the descriptor
// carries three value bits and codes 4 through 7 name no direction. The
// mapping is spelled out so an unrecognised code is refused here rather than
// handed to @enumFromInt, which is undefined behaviour in a fast build.
fn decodeRoundMode(bits: u64) ?zmath.ieee.RoundMode {
    return switch (bits) {
        0 => .nearest_even,
        1 => .toward_zero,
        2 => .toward_positive,
        3 => .toward_negative,
        else => null,
    };
}

// A refused direction yields a zero-field result. Both callers, dispatchRuntime
// and materializeRawRuntimeFields, reject a field count that disagrees with the
// entry's result count, so the refusal is an error and never a silent pass.
//
// scaleB takes the rounding direction FIRST, where fromfp takes its own
// direction in the middle. Each argument is therefore read from the slot named
// in the body below, and the entry's own input descriptors pin that same
// order, so a value can neither be read from the wrong slot nor reach the
// function through a mismatched descriptor.
fn makeScaleBInvoker(
    comptime operation: []const u8,
    comptime format: corpus.Format,
    comptime exponent_type: corpus.IntegerType,
) RuntimeInvoker {
    const Exponent = switch (exponent_type) {
        .i32 => i32,
        .i64 => i64,
        else => @compileError("scaleB invoker requires an i32 or i64 exponent descriptor"),
    };
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const mode = decodeRoundMode(inputs[0].value_bits) orelse
                return emptyRawRuntimeResult();
            const value = decodeFloat(format, inputs[1].value_bits);
            const exponent: Exponent = @intCast(decodeSignedInteger(
                exponent_type,
                inputs[2].value_bits,
            ));
            const output: FloatType(format) = @call(
                .auto,
                @field(zmath.ieee, operation),
                .{ mode, value, exponent },
            );
            return makeFloatResult(format, output);
        }
    };
    return &Adapter.invoke;
}

fn makeRoundIntegralInvoker(
    comptime operation: []const u8,
    comptime format: corpus.Format,
) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const mode = decodeRoundMode(inputs[0].value_bits) orelse
                return emptyRawRuntimeResult();
            const value = decodeFloat(format, inputs[1].value_bits);
            const output: FloatType(format) = @call(
                .auto,
                @field(zmath.ieee, operation),
                .{ mode, value },
            );
            return makeFloatResult(format, output);
        }
    };
    return &Adapter.invoke;
}

// The quaternion operand is two four-component factors in one format, the
// first factor then the second, each named w, x, y, z. The manifest row fixes
// that layout, so the invoker reads the slots the row pins rather than
// inferring one, and the result leaves in the same order.
fn makeQuaternionMulInvoker(comptime format: corpus.Format) RuntimeInvoker {
    const Quat = switch (format) {
        .f => zmath.quaternion.Quatf,
        .d => zmath.quaternion.Quatd,
        // A quaternion has no binary16 instantiation; the descriptor builder
        // publishes it at binary32 and binary64 only.
        .h => unreachable,
    };
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const left = Quat.init(
                decodeFloat(format, inputs[1].value_bits),
                decodeFloat(format, inputs[2].value_bits),
                decodeFloat(format, inputs[3].value_bits),
                decodeFloat(format, inputs[0].value_bits),
            );
            const right = Quat.init(
                decodeFloat(format, inputs[5].value_bits),
                decodeFloat(format, inputs[6].value_bits),
                decodeFloat(format, inputs[7].value_bits),
                decodeFloat(format, inputs[4].value_bits),
            );
            const product = left.mul(right);
            var result = emptyRawRuntimeResult();
            result.values[0] = encodeFloat(format, product.w);
            result.values[1] = encodeFloat(format, product.x);
            result.values[2] = encodeFloat(format, product.y);
            result.values[3] = encodeFloat(format, product.z);
            result.field_count = 4;
            return result;
        }
    };
    return &Adapter.invoke;
}

// One Cl(3) multivector is eight coefficients in one format, in ascending
// basis-blade mask order, which is the order the runtime stores them in and
// the order the manifest lists them.
//
// The manifest spells each involution with an `algebra` prefix that the zmath
// method does not carry, so there is one maker per involution and each names
// its own method in its own body. A method that stops existing is then a
// compile error at the line that calls it, rather than a lookup of a manifest
// name against a member that never existed.
fn algebraType(comptime format: corpus.Format) type {
    return switch (format) {
        .f => zmath.algebra.Cl3f,
        .d => zmath.algebra.Cl3d,
        // Cl3f and Cl3d are the two published Cl(3) instantiations, so the
        // descriptor builder publishes a row at binary32 and binary64 only.
        .h => unreachable,
    };
}

fn decodeAlgebra(
    comptime format: corpus.Format,
    comptime Algebra: type,
    inputs: *const [max_oracle_fields]OracleInputField,
) Algebra {
    var coefficients: [Algebra.coefficient_count]FloatType(format) = undefined;
    for (&coefficients, 0..) |*coefficient, index| {
        coefficient.* = decodeFloat(format, inputs[index].value_bits);
    }
    return Algebra.fromCoefficients(coefficients);
}

fn encodeAlgebra(
    comptime format: corpus.Format,
    comptime Algebra: type,
    image: Algebra,
) RawRuntimeResult {
    var result = emptyRawRuntimeResult();
    for (image.coefficients(), 0..) |coefficient, index| {
        result.values[index] = encodeFloat(format, coefficient);
    }
    result.field_count = Algebra.coefficient_count;
    return result;
}

/// The Clifford conjugate, the grade sign `(-1)^(k * (k + 1) / 2)`.
fn makeAlgebraConjugateInvoker(comptime format: corpus.Format) RuntimeInvoker {
    const Algebra = algebraType(format);
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            return encodeAlgebra(
                format,
                Algebra,
                decodeAlgebra(format, Algebra, inputs).conjugate(),
            );
        }
    };
    return &Adapter.invoke;
}

/// The right dual `A * inverse(I)`: the complement blade carrying the sign the
/// product table gives for that blade times `I`, divided by `I * I`. The sign
/// therefore depends on the blade and not only on its grade.
fn makeAlgebraDualInvoker(comptime format: corpus.Format) RuntimeInvoker {
    const Algebra = algebraType(format);
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            return encodeAlgebra(
                format,
                Algebra,
                decodeAlgebra(format, Algebra, inputs).dual(),
            );
        }
    };
    return &Adapter.invoke;
}

/// The complementary dual, which drops the dual sign and keeps the complement.
fn makeAlgebraDualComplementInvoker(comptime format: corpus.Format) RuntimeInvoker {
    const Algebra = algebraType(format);
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            return encodeAlgebra(
                format,
                Algebra,
                decodeAlgebra(format, Algebra, inputs).dualComplement(),
            );
        }
    };
    return &Adapter.invoke;
}

/// The grade reversal, the grade sign `(-1)^(k * (k - 1) / 2)`.
fn makeAlgebraReverseInvoker(comptime format: corpus.Format) RuntimeInvoker {
    const Algebra = algebraType(format);
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            return encodeAlgebra(
                format,
                Algebra,
                decodeAlgebra(format, Algebra, inputs).reverse(),
            );
        }
    };
    return &Adapter.invoke;
}

// The eight coefficients are the same list for every involution, so it is
// written once here and each row in the runtime table names the operation and
// the maker that calls the zmath method for it.
fn appendAlgebraEntry(
    table: *RuntimeTable,
    comptime operation: []const u8,
    comptime format: corpus.Format,
    comptime invoker: RuntimeInvoker,
) void {
    append(table, makeEntry(
        operation,
        .{
            floatArgument(format),
            floatArgument(format),
            floatArgument(format),
            floatArgument(format),
            floatArgument(format),
            floatArgument(format),
            floatArgument(format),
            floatArgument(format),
        },
        structureResult(.algebra, format),
        invoker,
    ));
}

// ---------------------------------------------------------------------------
// Non-elementwise descriptor forms
//
// A row below carries a struct, a matrix, or a policy tag rather than a list of
// same-format floats. Each invoker names the public type it builds and the slot
// every component is read from, so a manifest edit that moved a component is a
// visible mismatch in the entry's own descriptors rather than a silently
// transposed result.
// ---------------------------------------------------------------------------

// A complex factor is a real and an imaginary part in one format. The manifest
// lists the first factor's re then im, then the second factor's re then im, and
// the result leaves in the same order.
fn complexType(comptime format: corpus.Format) type {
    return switch (format) {
        .f => zmath.complex.Complexf,
        .d => zmath.complex.Complexd,
        // A complex number has no binary16 instantiation, so the descriptor
        // builder publishes the row at binary32 and binary64 only.
        .h => unreachable,
    };
}

fn makeComplexBinaryInvoker(
    comptime operation: []const u8,
    comptime format: corpus.Format,
) RuntimeInvoker {
    const Complex = complexType(format);
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const left = Complex{
                .re = decodeFloat(format, inputs[0].value_bits),
                .im = decodeFloat(format, inputs[1].value_bits),
            };
            const right = Complex{
                .re = decodeFloat(format, inputs[2].value_bits),
                .im = decodeFloat(format, inputs[3].value_bits),
            };
            const computed: Complex = @call(
                .auto,
                @field(zmath.complex, operation),
                .{ left, right },
            );
            var result = emptyRawRuntimeResult();
            result.values[0] = encodeFloat(format, computed.re);
            result.values[1] = encodeFloat(format, computed.im);
            result.field_count = 2;
            return result;
        }
    };
    return &Adapter.invoke;
}

fn mat2Type(comptime format: corpus.Format) type {
    return switch (format) {
        .f => zmath.matrix.Mat2f,
        .d => zmath.matrix.Mat2d,
        .h => unreachable,
    };
}

// A 2 by 2 matrix is a ROW-MAJOR literal: the first argument row is
// `a00, a01` and the second is `a10, a11`, which is both the order the
// manifest lists and the order the public constructor reads.
fn decodeMat2(
    comptime format: corpus.Format,
    inputs: *const [max_oracle_fields]OracleInputField,
) mat2Type(format) {
    const Mat2 = mat2Type(format);
    return Mat2.init(.{
        .{
            decodeFloat(format, inputs[0].value_bits),
            decodeFloat(format, inputs[1].value_bits),
        },
        .{
            decodeFloat(format, inputs[2].value_bits),
            decodeFloat(format, inputs[3].value_bits),
        },
    });
}

// The size-paired siblings are named per format rather than assembled from a
// suffix, so a rename of one of them is a compile error at the call below and
// not a lookup of an assembled name that never existed.
fn determinantMat2Name(comptime format: corpus.Format) []const u8 {
    return switch (format) {
        .f => "determinantMat2f",
        .d => "determinantMat2d",
        .h => unreachable,
    };
}

fn makeMat2DeterminantInvoker(comptime format: corpus.Format) RuntimeInvoker {
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const determinant: FloatType(format) = @call(
                .auto,
                @field(zmath.matrix, determinantMat2Name(format)),
                .{decodeMat2(format, inputs)},
            );
            return makeFloatResult(format, determinant);
        }
    };
    return &Adapter.invoke;
}

// A refused solve carries the canonical positive zero in both solution fields
// and false in the flag. The two fields are INACTIVE rather than approximate:
// a factorization that refused, or a stored pivot that was zero or not finite,
// has no solution to report, and a number written there would be one the
// runtime never derived.
fn refusedLuSolve(comptime format: corpus.Format) RawRuntimeResult {
    var result = emptyRawRuntimeResult();
    result.values[0] = encodeFloat(format, 0.0);
    result.values[1] = encodeFloat(format, 0.0);
    result.values[2] = 0;
    result.field_count = 3;
    return result;
}

fn makeLuSolveInvoker(comptime format: corpus.Format) RuntimeInvoker {
    const Mat2 = mat2Type(format);
    // The right-hand side is the vector type the matrix itself names, so the
    // public solve accepts it and the caller never restates the pairing the
    // compile-time check inside the solve enforces.
    const Vector2 = Mat2.vector_type;
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const factorization = zmath.linalg.lu(decodeMat2(format, inputs)) orelse
                return refusedLuSolve(format);
            const right_hand_side = Vector2.init(
                decodeFloat(format, inputs[4].value_bits),
                decodeFloat(format, inputs[5].value_bits),
            );
            const solution = zmath.linalg.solveLu(factorization, right_hand_side) orelse
                return refusedLuSolve(format);
            var result = emptyRawRuntimeResult();
            result.values[0] = encodeFloat(format, solution.x);
            result.values[1] = encodeFloat(format, solution.y);
            result.values[2] = 1;
            result.field_count = 3;
            return result;
        }
    };
    return &Adapter.invoke;
}

fn point2Type(comptime format: corpus.Format) type {
    return switch (format) {
        .f => zmath.geometry.Point2f,
        .d => zmath.geometry.Point2d,
        .h => unreachable,
    };
}

// The two policy names are the whole accepted tag vocabulary. The tag is an
// input value rather than a descriptor, so the descriptor proves nothing about
// the payload and an unrecognised name is refused here instead of being handed
// to @enumFromInt, which is undefined behaviour in a fast build.
fn decodeOrientationPolicy(
    tag_bytes: ?[*c]const u8,
    tag_length: u32,
) ?zmath.geometry.PredicatePolicy {
    const bytes = tag_bytes orelse return null;
    if (bytes == null) return null;
    const tag: []const u8 = bytes[0..@intCast(tag_length)];
    if (std.mem.eql(u8, tag, "adaptive_exact")) return .adaptive_exact;
    if (std.mem.eql(u8, tag, "fast")) return .fast;
    return null;
}

// zmath.geometry.Sign and the signed i32 result field are declared in two
// different modules and nothing in the type system ties their members together.
// A positional @intFromEnum would keep compiling after either enum was
// reordered and would then report a different sign for the same orientation,
// so every pair is named here. Neither switch carries an `else`: a new member
// on either side is a compile error rather than a silently accepted sign.
fn orientationSignValue(sign: zmath.geometry.Sign) i32 {
    return switch (sign) {
        .negative => -1,
        .zero => 0,
        .positive => 1,
    };
}

// The seventh argument is the policy tag, and the result is the signed sign
// rather than the enum, so the two conventions meet exactly here.
//
// An unknown policy and a non-finite coordinate both yield a zero-field result.
// Both callers, dispatchRuntime and materializeRawRuntimeFields, reject a field
// count that disagrees with the entry's own result count, so the refusal is an
// error that fails closed rather than a sign the runtime never computed.
fn makeOrientationInvoker(comptime format: corpus.Format) RuntimeInvoker {
    const Point = point2Type(format);
    const Adapter = struct {
        fn invoke(inputs: *const [max_oracle_fields]OracleInputField) RawRuntimeResult {
            const policy = decodeOrientationPolicy(
                inputs[6].tag_bytes,
                inputs[6].tag_length,
            ) orelse return emptyRawRuntimeResult();
            const first = Point.init(
                decodeFloat(format, inputs[0].value_bits),
                decodeFloat(format, inputs[1].value_bits),
            ) catch return emptyRawRuntimeResult();
            const second = Point.init(
                decodeFloat(format, inputs[2].value_bits),
                decodeFloat(format, inputs[3].value_bits),
            ) catch return emptyRawRuntimeResult();
            const third = Point.init(
                decodeFloat(format, inputs[4].value_bits),
                decodeFloat(format, inputs[5].value_bits),
            ) catch return emptyRawRuntimeResult();
            const sign = Point.orientation(first, second, third, policy) catch
                return emptyRawRuntimeResult();
            var result = emptyRawRuntimeResult();
            result.values[0] = encodeInteger(.i32, orientationSignValue(sign));
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
    // The arguments tuple is deliberately placed before the result and invoker
    // parameters. It is a comptime `anytype`, which the linter ranks as "other",
    // so this order is flagged; but it is load-bearing across every call site
    // below, and reordering it buys no correctness or clarity. Suppressed here
    // rather than risk a fourth signature churn on the dispatch table.
    // ziglint-ignore: Z023
    comptime arguments: anytype,
    // ziglint-ignore: Z023
    comptime result: corpus.ResultDescriptor,
    // ziglint-ignore: Z023
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
        .input_count = @typeInfo(@TypeOf(arguments)).@"struct".field_names.len,
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
        // classify is a total function of one operand, so its binary16 campaign
        // is genuinely exhaustive over all 65536 encodings. Its result is the
        // six-value class enumeration, not a float.
        append(&table, makeEntry(
            "classify",
            .{floatArgument(format)},
            .classification,
            makeClassificationInvoker(suffixedOperation("classify", format), format),
        ));
        // Two operands, so no campaign here may claim the full Cartesian
        // product. Both arguments are encodings of the one format the result
        // width is chosen for, which the entry's descriptors pin.
        append(&table, makeEntry(
            "ulpDistance",
            .{ floatArgument(format), floatArgument(format) },
            .{ .integer = ulpDistanceIntegerType(format) },
            makeUlpDistanceInvoker(
                suffixedOperation("ulpDistance", format),
                format,
                ulpDistanceIntegerType(format),
            ),
        ));
    }
    // zmath.ieee exposes scaleB and roundIntegral for binary16 only, so there is
    // one row each and no format loop. The rounding direction is an input
    // value rather than a descriptor, which is why the arity is three and two
    // and why the manifest key (provenance, op, format) still yields one row.
    append(&table, makeEntry(
        "scaleB",
        .{
            @as(corpus.InputDescriptor, .round_mode),
            floatArgument(.h),
            integerArgument(.i32),
        },
        .{ .float = .h },
        makeScaleBInvoker("scaleBh", .h, .i32),
    ));
    append(&table, makeEntry(
        "roundIntegral",
        .{ @as(corpus.InputDescriptor, .round_mode), floatArgument(.h) },
        .{ .float = .h },
        makeRoundIntegralInvoker("roundIntegralh", .h),
    ));
    // The format-suffixed forms of scaleB and roundIntegral follow the same
    // shape as their binary16 siblings and reach the other three rounding
    // directions through the same round_mode field, so one row each is the
    // whole inventory rather than a format loop.
    append(&table, makeEntry(
        "scaleBf",
        .{
            @as(corpus.InputDescriptor, .round_mode),
            floatArgument(.f),
            integerArgument(.i32),
        },
        .{ .float = .f },
        makeScaleBInvoker("scaleBf", .f, .i32),
    ));
    append(&table, makeEntry(
        "scaleBd",
        .{
            @as(corpus.InputDescriptor, .round_mode),
            floatArgument(.d),
            integerArgument(.i32),
        },
        .{ .float = .d },
        makeScaleBInvoker("scaleBd", .d, .i32),
    ));
    append(&table, makeEntry(
        "roundIntegralf",
        .{ @as(corpus.InputDescriptor, .round_mode), floatArgument(.f) },
        .{ .float = .f },
        makeRoundIntegralInvoker("roundIntegralf", .f),
    ));
    append(&table, makeEntry(
        "roundIntegrald",
        .{ @as(corpus.InputDescriptor, .round_mode), floatArgument(.d) },
        .{ .float = .d },
        makeRoundIntegralInvoker("roundIntegrald", .d),
    ));

    // Two four-component factors and four components back. The eight
    // arguments are the first factor then the second, each w, x, y, z.
    inline for ([_]corpus.Format{ .f, .d }) |format| {
        append(&table, makeEntry(
            "quaternionMul",
            .{
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
            },
            structureResult(.quaternion, format),
            makeQuaternionMulInvoker(format),
        ));
    }

    // One Cl(3) multivector in, the same eight coefficients out. The manifest
    // operation and the zmath method it calls are written against each other
    // here, one row each, so the pairing is read off the table rather than
    // inferred from a name.
    inline for ([_]corpus.Format{ .f, .d }) |format| {
        appendAlgebraEntry(
            &table,
            "algebraConjugate",
            format,
            makeAlgebraConjugateInvoker(format),
        );
        appendAlgebraEntry(
            &table,
            "algebraDual",
            format,
            makeAlgebraDualInvoker(format),
        );
        appendAlgebraEntry(
            &table,
            "algebraDualComplement",
            format,
            makeAlgebraDualComplementInvoker(format),
        );
        appendAlgebraEntry(
            &table,
            "algebraReverse",
            format,
            makeAlgebraReverseInvoker(format),
        );
    }

    // Two complex factors, a 2 by 2 matrix, a matrix with a right-hand side,
    // and three points under a policy tag. Each is published at binary32 and
    // binary64 only, so the loop names those two formats rather than walking
    // the three-format list: an absent instantiation is a missing row, not a
    // format the row exists in.
    inline for ([_]corpus.Format{ .f, .d }) |format| {
        append(&table, makeEntry(
            "complexAdd",
            .{
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
            },
            structureResult(.complex, format),
            makeComplexBinaryInvoker(suffixedOperation("add", format), format),
        ));
        append(&table, makeEntry(
            "complexMul",
            .{
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
            },
            structureResult(.complex, format),
            makeComplexBinaryInvoker(suffixedOperation("mul", format), format),
        ));
        append(&table, makeEntry(
            "matrixDet2",
            .{
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
            },
            .{ .float = format },
            makeMat2DeterminantInvoker(format),
        ));
        append(&table, makeEntry(
            "luSolve2",
            .{
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
            },
            structureResult(.luSolve, format),
            makeLuSolveInvoker(format),
        ));
        // The policy tag is the last argument, after the six coordinates, and
        // the result is a signed i32 rather than an enum ordinal.
        append(&table, makeEntry(
            "geometryOrient2",
            .{
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
                floatArgument(format),
                @as(corpus.InputDescriptor, .tag),
            },
            .{ .integer = .i32 },
            makeOrientationInvoker(format),
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
    validateRuntimeTable(&table);
    return table;
}

// The runtime table is the runtime's own view of the descriptor corpus, so the
// build checks the shape of every row it emits. A pinned row count would only
// move the failure from this file to the next manifest edit.
//
//  - Every entry names an operation the manifest can express, so no entry
//    exists for a shape no row reaches.
//  - Every argument is a shape a stored record can hold. A classification is a
//    result-only field, so an entry naming one as an operand is a shape nothing
//    can ever call.
//  - Every entry stays inside the ABI ceilings, so a row can never ask the
//    oracle bridge for more fields than the result buffer holds.
fn validateRuntimeTable(table: *const RuntimeTable) void {
    for (table.entries[0..table.count]) |*entry| {
        comptime {
            if (std.meta.stringToEnum(corpus.ManifestOperation, entry.operation) == null) {
                @compileError("runtime table names an operation the manifest vocabulary does not declare");
            }
            if (entry.input_count == 0 or entry.input_count > corpus.max_argument_count) {
                @compileError("runtime table entry has an argument count outside the ABI ceiling");
            }
            if (entry.result_count == 0 or entry.result_count > corpus.max_result_field_count) {
                @compileError("runtime table entry has a result field count outside the ABI ceiling");
            }
            for (entry.input_descriptors[0..entry.input_count]) |descriptor| {
                if (!bitsFitDescriptor(descriptor, 0)) {
                    @compileError("runtime table entry names an argument no stored record can hold");
                }
            }
        }
    }
}

const runtime_table = buildRuntimeTable();

// ---------------------------------------------------------------------------
// Vector replay lane
// ---------------------------------------------------------------------------

/// Fail-closed errors for a packed vector batch. `VectorLaneBufferOverflow` is
/// distinct from the shape errors so a batch needing more result words than the
/// eight-slot buffer holds is rejected instead of truncated.
/// `VectorLaneRefused` is the lane-level refusal: the invoker behind a lane
/// declined that record, and a declined record has no stored answer for the
/// replay to agree with, so the batch fails rather than publishing a value the
/// runtime never derived.
pub const VectorBatchError = error{
    VectorLaneCountOutOfRange,
    VectorResultFieldCountOverflow,
    VectorLaneBufferOverflow,
    VectorLaneRefused,
};

/// One packed lane: the input field slots of a single record, in manifest
/// argument order.
pub const VectorLaneGroup = [max_oracle_fields]OracleInputField;

/// Applies one lane kernel to four packed lanes. `groups` holds one lane per
/// slot, and `out` receives the result words packed lane major: lane `i` owns
/// `out[i * field_count ..][0..field_count]`.
pub const VectorRuntimeInvoker = *const fn (
    groups: *const [vector_lane_count]VectorLaneGroup,
    out: *[corpus.max_argument_count]u64,
) VectorBatchError!void;

/// One packed lane row. `scalar` is the runtime row the lane serves, and every
/// descriptor is read from it rather than copied: a lane and its scalar row
/// describe one manifest row, and there is one description of a record here.
/// `vector_operation` names the `zmath.vector` entry point when the lane is a
/// real vector kernel, and is null when the lane is scalar-backed: the group is
/// replayed by the accepted scalar invoker once per lane, which is a
/// correctness lane and never a throughput claim.
pub const VectorRuntimeEntry = struct {
    scalar: *const RuntimeEntry,
    vector_operation: ?[]const u8,
    invoke: VectorRuntimeInvoker,
};

const VectorRuntimeTable = struct {
    entries: [corpus.max_function_count]VectorRuntimeEntry,
    count: usize,
};

pub const PreparedVectorRuntime = struct {
    entry: *const VectorRuntimeEntry,
};

/// A packed batch of consecutive corpus records. `lane_count` is below
/// `vector_lane_count` only for the final partial group. The invoker computes
/// every lane, so the unused lanes must carry a defined input, never an
/// undefined one.
pub const VectorBatch = struct {
    groups: [vector_lane_count]VectorLaneGroup,
    lane_count: usize,
    values: [corpus.max_argument_count]u64,
};

// The vector entry point of a root scalar operation, or null when `zmath.vector`
// does not vectorize it. The name is the operation plus the `v` suffix that
// every generic vector entry point carries.
fn vectorEntryName(comptime operation: []const u8) ?[]const u8 {
    const name = operation ++ "v";
    return if (comptime @hasDecl(zmath.vector, name)) name else null;
}

// One packed call of the real `zmath.vector` kernel. The published corpus
// stores the scalar result of every record, and a lane kernel is only in this
// table because it reproduces that result lane for lane.
fn makeVectorUnaryInvoker(
    comptime vector_operation: []const u8,
    comptime format: corpus.Format,
) VectorRuntimeInvoker {
    const lane_float = FloatType(format);
    const Lanes = @Vector(vector_lane_count, lane_float);
    const Adapter = struct {
        fn invoke(
            groups: *const [vector_lane_count]VectorLaneGroup,
            out: *[corpus.max_argument_count]u64,
        ) VectorBatchError!void {
            var lanes: Lanes = undefined;
            inline for (0..vector_lane_count) |lane| {
                lanes[lane] = decodeFloat(format, groups[lane][0].value_bits);
            }
            const result: Lanes = @call(
                .auto,
                @field(zmath.vector, vector_operation),
                .{lanes},
            );
            // The entry has exactly one result field, so the packed word index
            // of a lane is the lane index.
            inline for (0..vector_lane_count) |lane| {
                out[lane] = encodeFloat(format, result[lane]);
            }
        }
    };
    return &Adapter.invoke;
}

fn makeVectorBinaryInvoker(
    comptime vector_operation: []const u8,
    comptime format: corpus.Format,
) VectorRuntimeInvoker {
    const lane_float = FloatType(format);
    const Lanes = @Vector(vector_lane_count, lane_float);
    const Adapter = struct {
        fn invoke(
            groups: *const [vector_lane_count]VectorLaneGroup,
            out: *[corpus.max_argument_count]u64,
        ) VectorBatchError!void {
            var first: Lanes = undefined;
            var second: Lanes = undefined;
            inline for (0..vector_lane_count) |lane| {
                first[lane] = decodeFloat(format, groups[lane][0].value_bits);
                second[lane] = decodeFloat(format, groups[lane][1].value_bits);
            }
            const result: Lanes = @call(
                .auto,
                @field(zmath.vector, vector_operation),
                .{ first, second },
            );
            inline for (0..vector_lane_count) |lane| {
                out[lane] = encodeFloat(format, result[lane]);
            }
        }
    };
    return &Adapter.invoke;
}

// A lane row names the scalar row it serves, and the arguments it declares here
// are what that row is looked up by. Declaring them in the same comptime
// `anytype` tuple the scalar builder takes is what makes the two descriptions
// of a row impossible to write differently.
fn makeVectorEntry(
    comptime operation: []const u8,
    comptime arguments: anytype,
    comptime result: corpus.ResultDescriptor,
    comptime vector_operation: ?[]const u8,
    comptime invoke: VectorRuntimeInvoker,
) VectorRuntimeEntry {
    const field_count = result.oracleFieldCount();
    comptime {
        if (field_count == 0 or field_count > corpus.max_result_field_count) {
            @compileError("a packed lane carries between one and the result field ceiling");
        }
        // Four packed lanes of the widest result must still fit the raw word
        // buffer, or a batch would overwrite a neighbouring lane.
        if (field_count * vector_lane_count > corpus.max_argument_count) {
            @compileError("packed lane results overflow the raw result word buffer");
        }
    }
    return .{
        .scalar = scalarEntryFor(operation, arguments, result),
        .vector_operation = vector_operation,
        .invoke = invoke,
    };
}

// The scalar row that serves the named arguments and result, found by the same
// descriptor comparison the runtime lookup performs. A lane that names a row the
// scalar table does not serve is a build error, not a lane that measures
// nothing.
fn scalarEntryFor(
    comptime operation: []const u8,
    comptime arguments: anytype,
    comptime result: corpus.ResultDescriptor,
) *const RuntimeEntry {
    const row = laneFunction(operation, arguments, result);
    for (runtime_table.entries[0..runtime_table.count]) |*entry| {
        if (!std.mem.eql(u8, entry.operation, operation)) continue;
        if (entryMatchesFunction(entry.*, row)) return entry;
    }
    // Reached only when the lane names a row the scalar table does not serve,
    // which at comptime is the compile error the comment above describes.
    unreachable;
}

// The row a lane declares. Only the fields a descriptor comparison reads carry
// meaning, so the provenance, status and oracle a manifest row also carries are
// left at their neutral values here rather than restated.
fn laneFunction(
    comptime operation: []const u8,
    comptime arguments: anytype,
    comptime result: corpus.ResultDescriptor,
) Function {
    var inputs: corpus.ArgumentList = .{};
    inputs.count = @typeInfo(@TypeOf(arguments)).@"struct".field_names.len;
    inline for (arguments, 0..) |argument, index| {
        inputs.descriptors[index] = argument;
    }
    return .{
        .op = operation,
        .provenance = .empty,
        .status = .correct,
        .arity = inputs.count,
        .inputs = inputs,
        .result = result,
        .oracle = .none,
        .special_policy = "",
        .max_ulp = 0,
    };
}

// A scalar-backed lane group: lane `i` is one call of the accepted scalar
// invoker with that lane's own record, so the packed word lane `i` owns is
// bit-for-bit the stored scalar result for record `i`.
//
// This lane is a REPLAY path, not a vector kernel. It exists so a descriptor
// with no `zmath.vector` entry point is still covered by the packed replay, and
// it makes no throughput claim: a caller that wants SIMD timing measures the
// registered `zmath.vector` targets instead.
fn makeScalarBackedVectorInvoker(
    comptime scalar: RuntimeInvoker,
    comptime field_count: usize,
) VectorRuntimeInvoker {
    const Adapter = struct {
        fn invoke(
            groups: *const [vector_lane_count]VectorLaneGroup,
            out: *[corpus.max_argument_count]u64,
        ) VectorBatchError!void {
            inline for (0..vector_lane_count) |lane| {
                const raw = scalar(&groups[lane]);
                // A scalar invoker refuses a record by returning fewer fields
                // than its entry declares, so the width is also the refusal
                // check: a lane that answered a different shape has no stored
                // answer to agree with.
                if (raw.field_count != field_count) return error.VectorLaneRefused;
                @memcpy(
                    out[lane * field_count ..][0..field_count],
                    raw.values[0..field_count],
                );
            }
        }
    };
    return &Adapter.invoke;
}

// The lane row for a scalar row with no vector kernel. It carries the scalar
// row itself, so the lane and the scalar row cannot describe different records.
fn makeScalarBackedVectorEntry(entry: *const RuntimeEntry) VectorRuntimeEntry {
    return .{
        .scalar = entry,
        .vector_operation = null,
        .invoke = makeScalarBackedVectorInvoker(entry.invoke, entry.result_count),
    };
}

fn appendVector(table: *VectorRuntimeTable, entry: VectorRuntimeEntry) void {
    if (table.count == table.entries.len) @compileError("vector runtime table is full");
    table.entries[table.count] = entry;
    table.count += 1;
}

// True when `zmath.vector` publishes a real kernel for the elementwise
// operation named. The decision comes from the same declaration lookup the
// kernel loop uses, so a kernel that appears or disappears moves this answer
// with it, and no row is ever left without a packed lane.
//
// Every other descriptor the scalar table serves is scalar-backed, so the
// packed lane covers the whole corpus by construction: a new row reaches it the
// moment it has a scalar invoker, and the two tables cannot drift apart.
fn hasVectorKernel(operation: []const u8) bool {
    inline for (root_unary_operations) |candidate| {
        if (std.mem.eql(u8, candidate, operation)) {
            return comptime vectorEntryName(candidate) != null;
        }
    }
    inline for (root_binary_operations) |candidate| {
        if (std.mem.eql(u8, candidate, operation)) {
            return comptime vectorEntryName(candidate) != null;
        }
    }
    return false;
}

fn buildVectorRuntimeTable() VectorRuntimeTable {
    @setEvalBranchQuota(2_000_000);

    var table: VectorRuntimeTable = .{ .entries = undefined, .count = 0 };

    inline for (root_unary_operations) |operation| {
        const vector_operation = comptime vectorEntryName(operation) orelse continue;
        inline for (formats) |format| {
            appendVector(&table, makeVectorEntry(
                operation,
                .{floatArgument(format)},
                .{ .float = format },
                vector_operation,
                makeVectorUnaryInvoker(vector_operation, format),
            ));
        }
    }
    inline for (root_binary_operations) |operation| {
        const vector_operation = comptime vectorEntryName(operation) orelse continue;
        inline for (formats) |format| {
            appendVector(&table, makeVectorEntry(
                operation,
                .{ floatArgument(format), floatArgument(format) },
                .{ .float = format },
                vector_operation,
                makeVectorBinaryInvoker(vector_operation, format),
            ));
        }
    }
    // Everything the scalar table serves beyond those kernels: the structured
    // results, the integer results, the tag-carrying rows, and every binary16
    // and narrowing shape `zmath.vector` does not publish a kernel for.
    inline for (runtime_table.entries[0..runtime_table.count]) |*entry| {
        if (hasVectorKernel(entry.operation)) continue;
        appendVector(&table, makeScalarBackedVectorEntry(entry));
    }
    // The count is the scalar table's, read rather than pinned: a pinned number
    // would only have to be moved again, while this fails the build the moment
    // a row reaches the scalar replay and misses the packed one.
    comptime {
        if (table.count != runtime_table.count) {
            @compileError("vector runtime table does not cover the scalar descriptor corpus");
        }
    }
    return table;
}

const vector_runtime_table = buildVectorRuntimeTable();

// A lane row is found the way a scalar row is: by comparing the descriptors
// the manifest publishes against the ones the row declares. The scalar lookup
// already accepts an integer or a tag argument, and a structure result, so
// reusing that rule here is what lets one packed lane serve every corpus row
// rather than only the elementwise float ones.
pub fn runtimeVectorEntryForFunction(function: Function) ?*const VectorRuntimeEntry {
    if (@as(usize, function.arity) != function.arguments().len) return null;
    for (vector_runtime_table.entries[0..vector_runtime_table.count]) |*entry| {
        if (!std.mem.eql(u8, function.op, entry.scalar.operation)) continue;
        if (entryMatchesFunction(entry.scalar.*, function)) return entry;
    }
    return null;
}

pub fn prepareVectorRuntime(function: Function) ?PreparedVectorRuntime {
    const entry = runtimeVectorEntryForFunction(function) orelse return null;
    return .{ .entry = entry };
}

pub fn invokeVectorBatch(
    prepared: *const PreparedVectorRuntime,
    batch: *VectorBatch,
) VectorBatchError!void {
    const field_count = prepared.entry.scalar.result_count;
    if (batch.lane_count == 0 or batch.lane_count > vector_lane_count) {
        return error.VectorLaneCountOutOfRange;
    }
    if (field_count == 0 or field_count > corpus.max_result_field_count) {
        return error.VectorResultFieldCountOverflow;
    }
    if (field_count * vector_lane_count > batch.values.len) {
        return error.VectorLaneBufferOverflow;
    }
    @memset(batch.values[0 .. field_count * vector_lane_count], 0);
    // The zero fill above is a defined starting point for the lanes an invoker
    // leaves untouched, not a value: a lane that refuses fails the batch rather
    // than reporting the zero back as if the runtime had produced it.
    try prepared.entry.invoke(&batch.groups, &batch.values);
}

pub fn materializeRawVectorRuntimeFields(
    function: Function,
    prepared: *const PreparedVectorRuntime,
    batch: *const VectorBatch,
    target: *[vector_lane_count][corpus.max_result_field_count]corpus.CorpusField,
) RunError!usize {
    if (batch.lane_count == 0 or batch.lane_count > vector_lane_count) {
        return error.RuntimeShapeMismatch;
    }
    const field_count = prepared.entry.scalar.result_count;
    if (field_count == 0 or field_count > corpus.max_result_field_count) {
        return error.RuntimeShapeMismatch;
    }
    var evidence: VerifiedEvidence = undefined;
    evidence.runtime_status = .ok;
    evidence.reference_status = .unsupported;
    evidence.proof_status = .unsupported;
    evidence.field_count = field_count;
    for (0..batch.lane_count) |lane| {
        for (0..field_count) |field| {
            const descriptor = prepared.entry.scalar.result_descriptors[field];
            const value_bits = batch.values[lane * field_count + field];
            if (!valueBitsFitDescriptor(descriptor, value_bits)) {
                return error.RuntimeShapeMismatch;
            }
            evidence.fields[field] = .{
                .descriptor = descriptor,
                .value_bits = value_bits,
                .class_code = if (descriptor.kind == .float)
                    classifyFloatBits(descriptor, value_bits)
                else
                    .none,
                .reserved = 0,
            };
        }
        if (try materializeResultFields(function, &evidence, target[lane][0..]) != field_count) {
            return error.RuntimeShapeMismatch;
        }
    }
    return batch.lane_count;
}

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
        // round_mode is a different field kind from rounding on purpose: it
        // numbers four directions, not five, and the descriptor reserves three
        // value bits for them.
        .round_mode => return bits <= 3,
        // A class is a result, never an operand, so a descriptor that claims
        // one on the input side is refused. The named prong is required: a `_`
        // prong only covers the values the enum leaves undeclared.
        .classification => return false,
        _ => return false,
    }
}

fn valueBitsFitDescriptor(descriptor: OracleFieldDescriptor, bits: u64) bool {
    return switch (descriptor.kind) {
        .float => bits <= lowMask(descriptor.value_bits),
        .signed_integer, .unsigned_integer => bits <= lowMask(descriptor.value_bits),
        .classification => bits <= lowMask(descriptor.value_bits),
        .boolean => bits <= 1,
        else => false,
    };
}
fn emptyOracleResult(fields: []OracleResultField) RunError!OracleResult {
    // The result capacity is a u32 ABI field, so a wider storage buffer is a
    // shape error rather than a truncated cast.
    const field_capacity = std.math.cast(u32, fields.len) orelse
        return error.DescriptorCountOverflow;
    return .{
        .status = .@"error",
        .reserved = 0,
        .field_capacity = field_capacity,
        .field_count = 0,
        .fields = outputPointer(fields),
    };
}

fn runtimeOracleResult(runtime: *RuntimeResult) RunError!OracleResult {
    const fields = runtime.fields[0..runtime.field_count];
    const field_capacity = std.math.cast(u32, fields.len) orelse
        return error.DescriptorCountOverflow;
    return .{
        .status = .ok,
        .reserved = 0,
        .field_capacity = field_capacity,
        .field_count = field_capacity,
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

const no_inputs: []const u64 = &.{};

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
    var request: OracleRequest = .{
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
    var reference: OracleResult = .{
        .status = .@"error",
        .reserved = 0,
        .field_capacity = 1,
        .field_count = 0,
        .fields = &reference_fields,
    };
    corpus.zmath_testing_oracle_v2_mpfr_reference(&request, &reference);
    try oracleStatusOk(reference.status);
    const candidate_bits = expRuntimeBits(format, input_bits);
    const candidate_class = classifyFloatBits(result_descriptor, candidate_bits);
    if (reference.field_count != 1 or reference.fields[0].value_bits != candidate_bits or
        reference.fields[0].class_code != candidate_class)
    {
        return error.RuntimeMismatch;
    }
    var candidate_fields = [_]OracleResultField{.{
        .descriptor = result_descriptor,
        .value_bits = candidate_bits,
        .class_code = candidate_class,
        .reserved = 0,
    }};
    var candidate: OracleResult = .{
        .status = .ok,
        .reserved = 0,
        .field_capacity = 1,
        .field_count = 1,
        .fields = &candidate_fields,
    };
    var proof_fields = [_]OracleResultField{undefined};
    var proof: OracleResult = .{
        .status = .@"error",
        .reserved = 0,
        .field_capacity = 1,
        .field_count = 0,
        .fields = &proof_fields,
    };
    corpus.zmath_testing_oracle_v2_arb_prove(&request, &candidate, &proof);
    try oracleStatusOk(proof.status);
    if (proof.field_count != 1 or proof.fields[0].class_code != candidate_class) return error.ProofShapeMismatch;
}

// This path is intentionally Exp-only. It avoids the full dispatch table.
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
        try runExp(.f, @as(u32, @truncate(nextPrng(&state))));
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

// The manifest row for an operation at one format. The format is read from the
// first argument rather than from the result, so a row whose result carries no
// float format is found by the same rule as one that does.
fn manifestRowFor(operation: []const u8, format: corpus.Format) !Function {
    const manifest = try corpus.parseEmbeddedManifest();
    var functions = manifest.functions();
    while (try functions.next()) |function| {
        if (!std.mem.eql(u8, function.op, operation)) continue;
        const row_format = function.arguments()[0].floatFormat() orelse continue;
        if (row_format != format) continue;
        return function;
    }
    return error.MissingFunctionRow;
}

// One record's input fields. A tag field points into this value, so a caller
// holds it alive for the whole invocation instead of letting the bytes outlive
// the call. The payload is the text a tag-carrying row names; a row that carries
// no tag passes null and leaves the field unset.
const RuntimeRecord = struct {
    fields: [corpus.max_argument_count]corpus.OracleInputField = undefined,
    payload: [32]u8 = undefined,

    fn encode(
        record: *@This(),
        format: corpus.Format,
        values: []const u64,
        tag: ?[]const u8,
    ) corpus.OracleEncodingError!void {
        const descriptor: corpus.InputDescriptor = .{ .float = format };
        for (values, 0..) |bits, index| {
            record.fields[index] = try corpus.oracleLiteralInput(descriptor, bits);
        }
        const payload = tag orelse return;
        @memcpy(record.payload[0..payload.len], payload);
        record.fields[values.len] = try corpus.oracleTagInput(record.payload[0..payload.len]);
    }
};

// An orientation sign is defined only on a finite coordinate domain under a
// policy the runtime names. Outside that the invoker must decline the record
// rather than answer, because the consumer sees nothing but the fields: a
// fabricated sign would sit in the stored corpus looking exactly like a
// computed one. The decline carries no field at all, so both callers reject it
// on the count and the replay raises RuntimeShapeMismatch.
test "an unnamed geometry policy declines the record instead of answering" {
    const function = try manifestRowFor("geometryOrient2", .d);
    const prepared = try prepareRuntime(function);
    const finite = [_]u64{ 1, 0, 1, 2, 0, 1 };
    var actual: [corpus.max_result_field_count]corpus.CorpusField = undefined;
    for ([_][]const u8{ "", " ", "exact", "adaptive", "Fast", "adaptive_exact " }) |policy| {
        var record: RuntimeRecord = .{};
        try record.encode(.d, &finite, policy);
        const raw = prepared.invoke(&record.fields);
        try std.testing.expectEqual(@as(usize, 0), raw.field_count);
        try std.testing.expectError(
            error.RuntimeShapeMismatch,
            materializeRawRuntimeFields(function, &prepared, raw, &actual),
        );
    }
}

// The other half of the domain: a coordinate the public point constructor
// refuses is not a coordinate the predicate may classify, under either policy.
test "a non-finite geometry coordinate declines the record instead of answering" {
    const function = try manifestRowFor("geometryOrient2", .f);
    const prepared = try prepareRuntime(function);
    var actual: [corpus.max_result_field_count]corpus.CorpusField = undefined;
    const not_finite = [_]u64{
        0x7fc0_0000, // quiet NaN
        0x7f80_0000, // positive infinity
        0xff80_0000, // negative infinity
        0x7f80_0001, // signalling NaN
    };
    for ([_][]const u8{ "adaptive_exact", "fast" }) |policy| {
        for (not_finite) |bits| {
            for (0..6) |slot| {
                var coordinates = [_]u64{ 1, 0, 1, 2, 0, 1 };
                coordinates[slot] = bits;
                var record: RuntimeRecord = .{};
                try record.encode(.f, &coordinates, policy);
                const raw = prepared.invoke(&record.fields);
                try std.testing.expectEqual(@as(usize, 0), raw.field_count);
                try std.testing.expectError(
                    error.RuntimeShapeMismatch,
                    materializeRawRuntimeFields(function, &prepared, raw, &actual),
                );
            }
        }
    }
}

// A refused solve is a different contract from a declined orientation: the
// refusal IS a published answer. The two solution fields carry the canonical
// positive zero rather than a number the factorization never produced, and the
// flag is false, so a replay comparing decoded fields sees the refusal on every
// refused record and nothing else.
test "a refused solve publishes canonical zero solutions and a false flag" {
    const function = try manifestRowFor("luSolve2", .d);
    const prepared = try prepareRuntime(function);
    // The four matrix entries are zero, so the largest entry magnitude is zero
    // and no pivot clears the threshold times it: the factorization refuses
    // before a solution exists. The right-hand side is 1 and 2, so the refusal
    // is the matrix and not a later solve step.
    const coordinates = [_]u64{
        0,
        0,
        0,
        0,
        0x3ff0_0000_0000_0000,
        0x4000_0000_0000_0000,
    };
    var record: RuntimeRecord = .{};
    try record.encode(.d, &coordinates, null);
    const raw = prepared.invoke(&record.fields);
    var actual: [corpus.max_result_field_count]corpus.CorpusField = undefined;
    const count = try materializeRawRuntimeFields(function, &prepared, raw, &actual);
    try std.testing.expectEqual(@as(usize, 3), count);
    const canonical_zero = corpus.CorpusField{ .float = .{
        .format = .d,
        .bits = 0,
        .class = .zero,
    } };
    try std.testing.expectEqual(canonical_zero, actual[0]);
    try std.testing.expectEqual(canonical_zero, actual[1]);
    try std.testing.expectEqual(corpus.CorpusField{ .boolean = false }, actual[2]);
}
