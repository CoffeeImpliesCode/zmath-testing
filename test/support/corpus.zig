const std = @import("std");

pub const manifest_text = @embedFile("corpus/manifest.toml");

pub const max_function_count = 512;
pub const max_argument_count = 8;
pub const max_provenance_count = 4;
pub const max_manifest_list_count = 16;
pub const ValidationError = error{
    ByteOrderMark,
    CarriageReturn,
    MissingFinalNewline,
    MalformedLine,
    UnknownRootKey,
    DuplicateRootKey,
    MissingRootKey,
    UnsortedRootKey,
    InvalidPinnedValue,
    UnknownSection,
    RootKeyAfterFunction,
    UnknownFunctionKey,
    DuplicateFunctionKey,
    UnsortedFunctionKey,
    MissingFunctionKey,
    DuplicateFunctionRow,
    UnsortedFunctionRow,
    MissingFunctionRow,
    FunctionLimit,
    ArgumentLimit,
    UnknownOperation,
    InvalidOperationName,
    ReservedFormat,
    RejectedFormat,
    UnknownFormat,
    UnknownProvenance,
    DuplicateProvenance,
    UnsortedProvenance,
    InvalidArity,
    ArityMismatch,
    MalformedDescriptor,
    UnknownIntegerType,
    UnknownStructKind,
    UnknownResultDescriptor,
    UnknownStatus,
    InvalidStatusMaxUlp,
    StatusOracleMismatch,
    UnknownOracleCapability,
    InvalidSpecialPolicy,
    UnsupportedFunctionStatus,
    InvalidHeader,
    BlankCorpusLine,
    WrongColumnCount,
    InvalidHexWidth,
    InvalidHexDigit,
    UppercaseHexDigit,
    UnknownOutputClass,
    OutputClassMismatch,
    InvalidMaxUlp,
    UnsortedCorpusRow,
    DuplicateCorpusRow,
};

pub const oracle_abi_version: u32 = 2;

pub const OracleStatus = enum(c_uint) {
    ok = 0,
    unsupported = 1,
    @"error" = 2,
    uncertain = 3,
    _,
};

pub const OracleFormat = enum(c_uint) {
    none = 0,
    h = 1,
    f = 2,
    d = 3,
    _,
};

pub const OracleFieldKind = enum(c_uint) {
    float = 1,
    signed_integer = 2,
    unsigned_integer = 3,
    boolean = 4,
    tag = 5,
    rounding = 6,
    _,
};

pub const OracleResultLayout = enum(c_uint) {
    scalar = 1,
    structure = 2,
    _,
};

pub const OracleStructureKind = enum(c_uint) {
    none = 0,
    canonicalize = 1,
    frexp = 2,
    modf = 3,
    remquo = 4,
    lgamma = 5,
    payload = 6,
    atan2 = 7,
    power = 8,
    integer = 9,
    _,
};

pub const OracleClass = enum(c_uint) {
    normal = 0,
    subnormal = 1,
    zero = 2,
    infinity = 3,
    qnan = 4,
    none = 5,
    _,
};

pub const OracleFormatDescriptor = extern struct {
    code: OracleFormat,
    storage_bits: u32,
    exponent_bits: u32,
    fraction_bits: u32,
    reserved: u32,
};

pub const OracleFieldDescriptor = extern struct {
    kind: OracleFieldKind,
    value_bits: u32,
    format: OracleFormatDescriptor,
    reserved: u32,
};

pub const OracleInputField = extern struct {
    descriptor: OracleFieldDescriptor,
    value_bits: u64,
    tag_bytes: [*c]const u8,
    tag_length: u32,
    reserved: u32,
};

pub const OracleResultField = extern struct {
    descriptor: OracleFieldDescriptor,
    value_bits: u64,
    class_code: OracleClass,
    reserved: u32,
};

pub const OracleRequest = extern struct {
    abi_version: u32,
    reserved: u32,
    operation: [*c]const u8,
    operation_length: u32,
    arity: u32,
    input_fields: [*c]const OracleInputField,
    input_field_count: u32,
    result_layout: OracleResultLayout,
    structure_kind: OracleStructureKind,
    result_field_count: u32,
    result_fields: [*c]const OracleFieldDescriptor,
};

pub const OracleResult = extern struct {
    status: OracleStatus,
    reserved: u32,
    field_capacity: u32,
    field_count: u32,
    fields: [*c]OracleResultField,
};

pub extern fn zmath_testing_oracle_v2_mpfr_reference(
    request: *const OracleRequest,
    result: *OracleResult,
) void;

pub extern fn zmath_testing_oracle_v2_arb_prove(
    request: *const OracleRequest,
    candidate: *const OracleResult,
    proof: *OracleResult,
) void;
comptime {
    if (@sizeOf(OracleFormatDescriptor) != 20) @compileError("oracle format ABI drift");
    if (@sizeOf(OracleFieldDescriptor) != 32) @compileError("oracle field ABI drift");
    if (@sizeOf(OracleInputField) != 56) @compileError("oracle input ABI drift");
    if (@sizeOf(OracleResultField) != 48) @compileError("oracle result field ABI drift");
    if (@sizeOf(OracleRequest) != 56) @compileError("oracle request ABI drift");
    if (@sizeOf(OracleResult) != 24) @compileError("oracle result ABI drift");
    if (@offsetOf(OracleInputField, "descriptor") != 0) {
        @compileError("oracle input descriptor order drift");
    }
    if (@offsetOf(OracleInputField, "value_bits") != 32) {
        @compileError("oracle input value order drift");
    }
    if (@offsetOf(OracleInputField, "tag_bytes") != 40) {
        @compileError("oracle input tag pointer order drift");
    }
    if (@offsetOf(OracleInputField, "tag_length") != 48) {
        @compileError("oracle input tag length order drift");
    }
    if (@offsetOf(OracleInputField, "reserved") != 52) {
        @compileError("oracle input reserved order drift");
    }
    if (@offsetOf(OracleResultField, "descriptor") != 0) {
        @compileError("oracle result descriptor order drift");
    }
    if (@offsetOf(OracleResultField, "value_bits") != 32) {
        @compileError("oracle result value order drift");
    }
    if (@offsetOf(OracleResultField, "class_code") != 40) {
        @compileError("oracle result class order drift");
    }
    if (@offsetOf(OracleResultField, "reserved") != 44) {
        @compileError("oracle result reserved order drift");
    }
}

pub const Format = enum(u8) {
    h,
    f,
    d,

    pub fn hexadecimalDigits(format: Format) usize {
        return switch (format) {
            .h => 4,
            .f => 8,
            .d => 16,
        };
    }

    pub fn oracleDescriptor(format: Format) OracleFormatDescriptor {
        return switch (format) {
            .h => .{
                .code = .h,
                .storage_bits = 16,
                .exponent_bits = 5,
                .fraction_bits = 10,
                .reserved = 0,
            },
            .f => .{
                .code = .f,
                .storage_bits = 32,
                .exponent_bits = 8,
                .fraction_bits = 23,
                .reserved = 0,
            },
            .d => .{
                .code = .d,
                .storage_bits = 64,
                .exponent_bits = 11,
                .fraction_bits = 52,
                .reserved = 0,
            },
        };
    }
};

pub const Provenance = enum(u8) {
    c23_7_12,
    c23_ieee,
    annex_f,
    annex_h,
};

pub const IntegerType = enum(u8) {
    i2,
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,

    pub fn oracleValueBits(integer_type: IntegerType) u32 {
        return switch (integer_type) {
            .i2 => 2,
            .i8, .u8 => 8,
            .i16, .u16 => 16,
            .i32, .u32 => 32,
            .i64, .u64 => 64,
        };
    }

    pub fn oracleDescriptor(integer_type: IntegerType) OracleFieldDescriptor {
        const signed = switch (integer_type) {
            .i2, .i8, .i16, .i32, .i64 => true,
            .u8, .u16, .u32, .u64 => false,
        };
        return .{
            .kind = if (signed) .signed_integer else .unsigned_integer,
            .value_bits = integer_type.oracleValueBits(),
            .format = .{
                .code = .none,
                .storage_bits = 0,
                .exponent_bits = 0,
                .fraction_bits = 0,
                .reserved = 0,
            },
            .reserved = 0,
        };
    }
};
pub const OracleEncodingError = error{
    InvalidIntegerWidth,
    IntegerOutOfRange,
    IntegerPayloadOutOfRange,
    InvalidInputValue,
    InvalidResultClass,
    TagLengthOverflow,
};

fn oracleIntegerWidthIsValid(value_bits: u32) bool {
    return value_bits == 2 or value_bits == 8 or value_bits == 16 or
        value_bits == 32 or value_bits == 64;
}

pub fn encodeSignedInteger(value: i64, value_bits: u32) OracleEncodingError!u64 {
    if (!oracleIntegerWidthIsValid(value_bits)) return error.InvalidIntegerWidth;
    if (value_bits == 64) return @bitCast(value);
    const sign_limit = @as(i64, 1) << @intCast(value_bits - 1);
    if (value < -sign_limit or value > sign_limit - 1) {
        return error.IntegerOutOfRange;
    }
    const mask = (@as(u64, 1) << @intCast(value_bits)) - 1;
    return @as(u64, @bitCast(value)) & mask;
}

pub fn decodeSignedInteger(value_bits: u64, width: u32) OracleEncodingError!i64 {
    if (!oracleIntegerWidthIsValid(width)) return error.InvalidIntegerWidth;
    const mask = if (width == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(width)) - 1;
    if ((value_bits & ~mask) != 0) return error.IntegerPayloadOutOfRange;
    if (width == 64) return @bitCast(value_bits);
    const sign_bit = @as(u64, 1) << @intCast(width - 1);
    var extended = value_bits & mask;
    if ((extended & sign_bit) != 0) extended |= ~mask;
    return @bitCast(extended);
}

fn oracleUnsignedValueIsValid(value_bits: u64, width: u32) bool {
    if (!oracleIntegerWidthIsValid(width)) return false;
    if (width == 64) return true;
    return (value_bits >> @intCast(width)) == 0;
}

pub fn oracleLiteralInput(
    argument: ArgumentDescriptor,
    value_bits: u64,
) OracleEncodingError!OracleInputField {
    const descriptor = argument.oracleDescriptor();
    switch (argument) {
        .float => |format| {
            const width = format.oracleDescriptor().storage_bits;
            if (width != 64 and (value_bits >> @intCast(width)) != 0) {
                return error.InvalidInputValue;
            }
        },
        .integer => |integer_type| switch (integer_type) {
            .i2, .i8, .i16, .i32, .i64 => {
                _ = try decodeSignedInteger(value_bits, integer_type.oracleValueBits());
            },
            .u8, .u16, .u32, .u64 => {
                if (!oracleUnsignedValueIsValid(value_bits, integer_type.oracleValueBits())) {
                    return error.InvalidInputValue;
                }
            },
        },
        .tag => {
            if (value_bits != 0) return error.InvalidInputValue;
        },
        .fromfp_round => {
            if (value_bits > 4) return error.InvalidInputValue;
        },
    }
    return oracleInputField(descriptor, value_bits);
}

pub fn oracleResultField(
    descriptor: OracleFieldDescriptor,
    value_bits: u64,
    class_code: OracleClass,
) OracleEncodingError!OracleResultField {
    switch (descriptor.kind) {
        .float => {
            if (@intFromEnum(class_code) > @intFromEnum(OracleClass.qnan)) {
                return error.InvalidResultClass;
            }
        },
        .signed_integer, .unsigned_integer, .boolean => {
            if (class_code != .none) return error.InvalidResultClass;
        },
        else => return error.InvalidResultClass,
    }
    return .{
        .descriptor = descriptor,
        .value_bits = value_bits,
        .class_code = class_code,
        .reserved = 0,
    };
}

pub fn oracleInputField(
    descriptor: OracleFieldDescriptor,
    value_bits: u64,
) OracleInputField {
    return .{
        .descriptor = descriptor,
        .value_bits = value_bits,
        .tag_bytes = null,
        .tag_length = 0,
        .reserved = 0,
    };
}

pub fn oracleTagInput(tag_bytes: []const u8) OracleEncodingError!OracleInputField {
    if (tag_bytes.len > std.math.maxInt(u32)) return error.TagLengthOverflow;
    return .{
        .descriptor = .{
            .kind = .tag,
            .value_bits = 0,
            .format = .{
                .code = .none,
                .storage_bits = 0,
                .exponent_bits = 0,
                .fraction_bits = 0,
                .reserved = 0,
            },
            .reserved = 0,
        },
        .value_bits = 0,
        .tag_bytes = if (tag_bytes.len == 0) null else tag_bytes.ptr,
        .tag_length = @intCast(tag_bytes.len),
        .reserved = 0,
    };
}

pub const FromFpRound = enum {
    nearest_even,
    nearest_from_zero,
    toward_zero,
    toward_positive,
    toward_negative,
};

pub const ArgumentDescriptor = union(enum) {
    float: Format,
    integer: IntegerType,
    tag,
    fromfp_round,

    pub fn oracleDescriptor(argument: ArgumentDescriptor) OracleFieldDescriptor {
        return switch (argument) {
            .float => |format| .{
                .kind = .float,
                .value_bits = format.oracleDescriptor().storage_bits,
                .format = format.oracleDescriptor(),
                .reserved = 0,
            },
            .integer => |integer_type| integer_type.oracleDescriptor(),
            .tag => .{
                .kind = .tag,
                .value_bits = 0,
                .format = .{
                    .code = .none,
                    .storage_bits = 0,
                    .exponent_bits = 0,
                    .fraction_bits = 0,
                    .reserved = 0,
                },
                .reserved = 0,
            },
            .fromfp_round => .{
                .kind = .rounding,
                .value_bits = 32,
                .format = .{
                    .code = .none,
                    .storage_bits = 0,
                    .exponent_bits = 0,
                    .fraction_bits = 0,
                    .reserved = 0,
                },
                .reserved = 0,
            },
        };
    }
};

pub const StructKind = enum {
    canonicalize,
    frexp,
    modf,
    remquo,
    lgamma,
    payload,
    atan2,
    power,
    integer,

    pub fn oracleKind(kind: StructKind) OracleStructureKind {
        return switch (kind) {
            .canonicalize => .canonicalize,
            .frexp => .frexp,
            .modf => .modf,
            .remquo => .remquo,
            .lgamma => .lgamma,
            .payload => .payload,
            .atan2 => .atan2,
            .power => .power,
            .integer => .integer,
        };
    }
};

fn oracleBooleanFieldDescriptor() OracleFieldDescriptor {
    return .{
        .kind = .boolean,
        .value_bits = 1,
        .format = .{
            .code = .none,
            .storage_bits = 0,
            .exponent_bits = 0,
            .fraction_bits = 0,
            .reserved = 0,
        },
        .reserved = 0,
    };
}

fn oracleFloatFieldDescriptor(format: Format) OracleFieldDescriptor {
    const descriptor = format.oracleDescriptor();
    return .{
        .kind = .float,
        .value_bits = descriptor.storage_bits,
        .format = descriptor,
        .reserved = 0,
    };
}

pub const StructDescriptor = struct {
    kind: StructKind,
    format: Format,
};

pub const ResultDescriptor = union(enum) {
    float: Format,
    integer: IntegerType,
    boolean,
    structure: StructDescriptor,

    pub fn oracleLayout(result: ResultDescriptor) OracleResultLayout {
        return switch (result) {
            .structure => .structure,
            else => .scalar,
        };
    }

    pub fn oracleStructureKind(result: ResultDescriptor) OracleStructureKind {
        return switch (result) {
            .structure => |structure| structure.kind.oracleKind(),
            else => .none,
        };
    }

    pub fn oracleFieldCount(result: ResultDescriptor) usize {
        return switch (result) {
            .structure => 2,
            else => 1,
        };
    }

    pub fn oracleFieldDescriptor(
        result: ResultDescriptor,
        index: usize,
    ) ?OracleFieldDescriptor {
        return switch (result) {
            .float => |format| if (index == 0) oracleFloatFieldDescriptor(format) else null,
            .integer => |integer_type| if (index == 0) integer_type.oracleDescriptor() else null,
            .boolean => if (index == 0) oracleBooleanFieldDescriptor() else null,
            .structure => |structure| {
                const float_descriptor = oracleFloatFieldDescriptor(structure.format);
                switch (structure.kind) {
                    .canonicalize, .payload, .atan2, .power => {
                        if (index == 0) return float_descriptor;
                        if (index == 1) return oracleBooleanFieldDescriptor();
                    },
                    .frexp, .remquo => {
                        if (index == 0) return float_descriptor;
                        if (index == 1) return IntegerType.i32.oracleDescriptor();
                    },
                    .modf => {
                        if (index == 0 or index == 1) return float_descriptor;
                    },
                    .lgamma => {
                        if (index == 0) return float_descriptor;
                        if (index == 1) return IntegerType.i2.oracleDescriptor();
                    },
                    .integer => {
                        if (index == 0) return IntegerType.i64.oracleDescriptor();
                        if (index == 1) return oracleBooleanFieldDescriptor();
                    },
                }
                return null;
            },
        };
    }
};

pub const Status = enum {
    unsupported,
    correct,
    bounded,
};

pub const OracleCapability = enum {
    none,
    mpfr,
    mpfr_arb,
};

pub fn DescriptorList(comptime T: type, comptime capacity: usize) type {
    return struct {
        values: [capacity]T = undefined,
        count: usize = 0,

        pub const empty: @This() = .{ .values = undefined, .count = 0 };

        pub fn slice(self: *const @This()) []const T {
            return self.values[0..self.count];
        }
    };
}

pub const ProvenanceList = DescriptorList(Provenance, max_provenance_count);
pub const ArgumentList = DescriptorList(ArgumentDescriptor, max_argument_count);

pub const Function = struct {
    op: []const u8,
    provenance: ProvenanceList,
    status: Status,
    arity: u8,
    inputs: ArgumentList,
    result: ResultDescriptor,
    oracle: OracleCapability,
    special_policy: []const u8,
    max_ulp: u64,

    pub fn arguments(self: *const @This()) []const ArgumentDescriptor {
        return self.inputs.slice();
    }
};

pub const Manifest = struct {
    function_values: [max_function_count]Function = undefined,
    function_count: usize = 0,

    pub fn functions(self: *const @This()) FunctionIterator {
        return .{ .manifest = self };
    }
};

pub const FunctionIterator = struct {
    manifest: *const Manifest,
    index: usize = 0,

    pub fn next(self: *@This()) ValidationError!?Function {
        if (self.index == self.manifest.function_count) return null;
        if (self.index > self.manifest.function_count) return error.MissingFunctionRow;
        const function = self.manifest.function_values[self.index];
        self.index += 1;
        return function;
    }
};

// The descriptor corpus is a binary, length-framed format. Its version is
// independent from the manifest version and from the scalar TSV compatibility
// reader below.
pub const descriptor_corpus_codec_version: u8 = 1;
pub const scalar_tsv_compatibility_version: u8 = 2;
pub const descriptor_record_header_length: usize = 26;

pub const FieldClass = enum(u8) {
    normal = 0,
    subnormal = 1,
    zero = 2,
    infinity = 3,
    qnan = 4,
    none = 5,
};

pub const FloatCorpusField = struct {
    format: Format,
    bits: u64,
    class: FieldClass,
};

pub const SignedIntegerCorpusField = struct {
    integer_type: IntegerType,
    value: i64,
};

pub const UnsignedIntegerCorpusField = struct {
    integer_type: IntegerType,
    value: u64,
};

pub const CorpusField = union(enum) {
    float: FloatCorpusField,
    signed_integer: SignedIntegerCorpusField,
    unsigned_integer: UnsignedIntegerCorpusField,
    boolean: bool,
    tag: []const u8,
    rounding: FromFpRound,
};

pub const CorpusRecord = struct {
    operation: []const u8,
    provenance: ProvenanceList,
    arguments: DescriptorList(CorpusField, max_argument_count),
    result_descriptor: ResultDescriptor,
    results: DescriptorList(CorpusField, 2),
    max_ulp: u64,

    pub const InitOptions = struct {
        operation: []const u8,
        provenance: []const Provenance,
        arguments: []const CorpusField,
        result_descriptor: ResultDescriptor,
        results: []const CorpusField,
        max_ulp: u64,
    };

    pub fn init(options: InitOptions) CorpusRecordError!CorpusRecord {
        try validateOperationName(options.operation);
        if (options.operation.len > @as(usize, std.math.maxInt(u16))) {
            return error.OperationTooLong;
        }
        if (options.provenance.len == 0 or options.provenance.len > max_provenance_count) {
            return error.ProvenanceLimit;
        }
        if (options.arguments.len == 0 or options.arguments.len > max_argument_count) {
            return error.ArgumentLimit;
        }
        if (options.results.len != options.result_descriptor.oracleFieldCount()) {
            return error.ResultFieldMismatch;
        }
        var record: CorpusRecord = .{
            .operation = options.operation,
            .provenance = .empty,
            .arguments = .empty,
            .result_descriptor = options.result_descriptor,
            .results = .empty,
            .max_ulp = options.max_ulp,
        };
        for (options.provenance) |provenance| {
            if (record.provenance.count != 0 and
                @intFromEnum(provenance) <= @intFromEnum(
                    record.provenance.values[record.provenance.count - 1],
                ))
            {
                if (provenance == record.provenance.values[record.provenance.count - 1]) {
                    return error.DuplicateProvenance;
                }
                return error.UnsortedProvenance;
            }
            record.provenance.values[record.provenance.count] = provenance;
            record.provenance.count += 1;
        }
        for (options.arguments) |argument| {
            try validateCorpusField(argument, null);
            record.arguments.values[record.arguments.count] = argument;
            record.arguments.count += 1;
        }
        for (options.results, 0..) |result, index| {
            const descriptor = options.result_descriptor.oracleFieldDescriptor(index) orelse
                return error.ResultFieldMismatch;
            try validateCorpusField(result, descriptor);
            record.results.values[record.results.count] = result;
            record.results.count += 1;
        }
        return record;
    }
};

pub const CorpusRecordError = ValidationError || OracleEncodingError || error{
    InvalidRecordMagic,
    UnknownRecordVersion,
    TruncatedRecord,
    TrailingRecordBytes,
    InvalidRecordLength,
    OutputTooSmall,
    OperationTooLong,
    ProvenanceLimit,
    UnknownFieldKind,
    UnknownFieldClass,
    InvalidFieldClass,
    InvalidBoolean,
    InvalidTagLength,
    UnknownRounding,
    InvalidResultDescriptor,
    ResultFieldMismatch,
    UnknownResultDescriptorKind,
    UnknownStructureKind,
    DuplicateCorpusRecord,
    UnsortedCorpusRecord,
};

const CorpusReader = struct {
    source: []const u8,
    index: usize = 0,

    fn take(self: *@This(), count: usize) CorpusRecordError![]const u8 {
        if (count > self.source.len -| self.index) return error.TruncatedRecord;
        const result = self.source[self.index .. self.index + count];
        self.index += count;
        return result;
    }

    fn readU8(self: *@This()) CorpusRecordError!u8 {
        return (try self.take(1))[0];
    }

    fn readU16(self: *@This()) CorpusRecordError!u16 {
        const bytes = try self.take(2);
        return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
    }

    fn readU32(self: *@This()) CorpusRecordError!u32 {
        const bytes = try self.take(4);
        return @as(u32, bytes[0]) |
            (@as(u32, bytes[1]) << 8) |
            (@as(u32, bytes[2]) << 16) |
            (@as(u32, bytes[3]) << 24);
    }

    fn readU64(self: *@This()) CorpusRecordError!u64 {
        const bytes = try self.take(8);
        var result: u64 = 0;
        for (bytes, 0..) |byte, shift| result |= @as(u64, byte) << @intCast(shift * 8);
        return result;
    }
};

const CorpusWriter = struct {
    target: []u8,
    index: usize = 0,

    fn ensure(self: *@This(), count: usize) CorpusRecordError!void {
        if (count > self.target.len -| self.index) return error.OutputTooSmall;
    }

    fn bytes(self: *@This(), source: []const u8) CorpusRecordError!void {
        try self.ensure(source.len);
        @memcpy(self.target[self.index .. self.index + source.len], source);
        self.index += source.len;
    }

    fn writeU8(self: *@This(), value: u8) CorpusRecordError!void {
        try self.ensure(1);
        self.target[self.index] = value;
        self.index += 1;
    }

    fn writeU16(self: *@This(), value: u16) CorpusRecordError!void {
        try self.ensure(2);
        self.target[self.index] = @intCast(value & 0xff);
        self.target[self.index + 1] = @intCast(value >> 8);
        self.index += 2;
    }

    fn writeU32(self: *@This(), value: u32) CorpusRecordError!void {
        try self.ensure(4);
        for (0..4) |shift| {
            self.target[self.index + shift] = @intCast((value >> @intCast(shift * 8)) & 0xff);
        }
        self.index += 4;
    }

    fn writeU64(self: *@This(), value: u64) CorpusRecordError!void {
        try self.ensure(8);
        for (0..8) |shift| {
            self.target[self.index + shift] = @intCast((value >> @intCast(shift * 8)) & 0xff);
        }
        self.index += 8;
    }
};

fn corpusFormatCode(format: Format) u8 {
    return @intFromEnum(format);
}

fn parseCorpusFormat(code: u8) CorpusRecordError!Format {
    return switch (code) {
        0 => .h,
        1 => .f,
        2 => .d,
        else => error.UnknownFormat,
    };
}

fn parseCorpusProvenance(code: u8) CorpusRecordError!Provenance {
    return switch (code) {
        0 => .c23_7_12,
        1 => .c23_ieee,
        2 => .annex_f,
        3 => .annex_h,
        else => error.UnknownProvenance,
    };
}

fn corpusIntegerTypeCode(integer_type: IntegerType) u8 {
    return @intFromEnum(integer_type) + 1;
}

fn parseCorpusIntegerType(code: u8) CorpusRecordError!IntegerType {
    return switch (code) {
        1 => .i2,
        2 => .i8,
        3 => .i16,
        4 => .i32,
        5 => .i64,
        6 => .u8,
        7 => .u16,
        8 => .u32,
        9 => .u64,
        else => error.UnknownIntegerType,
    };
}

fn corpusFieldClassCode(class: FieldClass) u8 {
    return @intFromEnum(class);
}

fn parseCorpusFieldClass(code: u8) CorpusRecordError!FieldClass {
    return switch (code) {
        0 => .normal,
        1 => .subnormal,
        2 => .zero,
        3 => .infinity,
        4 => .qnan,
        5 => .none,
        else => error.UnknownFieldClass,
    };
}

fn corpusRoundingCode(rounding: FromFpRound) u8 {
    return @intFromEnum(rounding);
}

fn parseCorpusRounding(code: u8) CorpusRecordError!FromFpRound {
    return switch (code) {
        0 => .nearest_even,
        1 => .nearest_from_zero,
        2 => .toward_zero,
        3 => .toward_positive,
        4 => .toward_negative,
        else => error.UnknownRounding,
    };
}

fn corpusStructureCode(kind: StructKind) u8 {
    return @intFromEnum(kind);
}
fn parseCorpusStructure(code: u8) CorpusRecordError!StructKind {
    return switch (code) {
        0 => .canonicalize,
        1 => .frexp,
        2 => .modf,
        3 => .remquo,
        4 => .lgamma,
        5 => .payload,
        6 => .atan2,
        7 => .power,
        8 => .integer,
        else => error.UnknownStructureKind,
    };
}

fn corpusFieldKindCode(field: CorpusField) u8 {
    return switch (field) {
        .float => 0,
        .signed_integer => 1,
        .unsigned_integer => 2,
        .boolean => 3,
        .tag => 4,
        .rounding => 5,
    };
}

fn corpusFieldFormatCode(field: CorpusField) u8 {
    return switch (field) {
        .float => |value| corpusFormatCode(value.format),
        else => 0,
    };
}

fn corpusFieldTypeCode(field: CorpusField) u8 {
    return switch (field) {
        .signed_integer => |value| corpusIntegerTypeCode(value.integer_type),
        .unsigned_integer => |value| corpusIntegerTypeCode(value.integer_type),
        .rounding => |value| corpusRoundingCode(value),
        else => 0,
    };
}

fn corpusFieldClass(field: CorpusField) FieldClass {
    return switch (field) {
        .float => |value| value.class,
        else => .none,
    };
}

fn corpusFloatWidth(format: Format) u7 {
    return switch (format) {
        .h => 16,
        .f => 32,
        .d => 64,
    };
}

fn corpusDescriptorFormat(descriptor: OracleFormatDescriptor) CorpusRecordError!Format {
    return switch (descriptor.code) {
        .h => .h,
        .f => .f,
        .d => .d,
        .none => error.UnknownFormat,
        else => error.UnknownFormat,
    };
}

fn corpusFloatBitsAreValid(format: Format, bits: u64) bool {
    const width = corpusFloatWidth(format);
    return width == 64 or (bits >> @intCast(width)) == 0;
}

fn corpusDerivedClass(format: Format, bits: u64) FieldClass {
    const exponent_mask: u64 = switch (format) {
        .h => 0x7c00,
        .f => 0x7f80_0000,
        .d => 0x7ff0_0000_0000_0000,
    };
    const fraction_mask: u64 = switch (format) {
        .h => 0x03ff,
        .f => 0x007f_ffff,
        .d => 0x000f_ffff_ffff_ffff,
    };
    const exponent = bits & exponent_mask;
    const fraction = bits & fraction_mask;
    if (exponent == 0) return if (fraction == 0) .zero else .subnormal;
    if (exponent != exponent_mask) return .normal;
    return if (fraction == 0) .infinity else .qnan;
}

fn corpusFieldMatchesDescriptor(
    field: CorpusField,
    descriptor: OracleFieldDescriptor,
    result_field: bool,
) CorpusRecordError!void {
    switch (descriptor.kind) {
        .float => {
            const value = switch (field) {
                .float => |float| float,
                else => return error.ResultFieldMismatch,
            };
            const format = try corpusDescriptorFormat(descriptor.format);
            if (value.format != format) return error.ResultFieldMismatch;
            if (!corpusFloatBitsAreValid(value.format, value.bits)) return error.InvalidInputValue;
            if (result_field) {
                if (value.class == .none or
                    value.class != corpusDerivedClass(value.format, value.bits))
                {
                    return error.InvalidFieldClass;
                }
            } else if (value.class != .none and
                value.class != corpusDerivedClass(value.format, value.bits))
            {
                return error.InvalidFieldClass;
            }
        },
        .signed_integer => {
            const value = switch (field) {
                .signed_integer => |integer| integer,
                else => return error.ResultFieldMismatch,
            };
            if (value.integer_type.oracleValueBits() != descriptor.value_bits) {
                return error.ResultFieldMismatch;
            }
            _ = try encodeSignedInteger(value.value, descriptor.value_bits);
        },
        .unsigned_integer => {
            const value = switch (field) {
                .unsigned_integer => |integer| integer,
                else => return error.ResultFieldMismatch,
            };
            if (value.integer_type.oracleValueBits() != descriptor.value_bits) {
                return error.ResultFieldMismatch;
            }
            if (!oracleUnsignedValueIsValid(value.value, descriptor.value_bits)) {
                return error.IntegerOutOfRange;
            }
        },
        .boolean => switch (field) {
            .boolean => {},
            else => return error.ResultFieldMismatch,
        },
        else => return error.ResultFieldMismatch,
    }
}

fn validateCorpusField(
    field: CorpusField,
    result_descriptor: ?OracleFieldDescriptor,
) CorpusRecordError!void {
    if (result_descriptor) |descriptor| {
        try corpusFieldMatchesDescriptor(field, descriptor, true);
        return;
    }
    switch (field) {
        .float => |value| {
            if (!corpusFloatBitsAreValid(value.format, value.bits)) return error.InvalidInputValue;
            if (value.class != .none and value.class != corpusDerivedClass(value.format, value.bits)) {
                return error.InvalidFieldClass;
            }
        },
        .signed_integer => |value| {
            _ = try encodeSignedInteger(value.value, value.integer_type.oracleValueBits());
        },
        .unsigned_integer => |value| {
            if (!oracleUnsignedValueIsValid(value.value, value.integer_type.oracleValueBits())) {
                return error.IntegerOutOfRange;
            }
        },
        .boolean, .rounding => {},
        .tag => |value| if (value.len > @as(usize, std.math.maxInt(u32))) return error.InvalidTagLength,
    }
}

fn encodeCorpusResultDescriptor(
    writer: *CorpusWriter,
    descriptor: ResultDescriptor,
) CorpusRecordError!void {
    switch (descriptor) {
        .float => |format| {
            try writer.writeU8(0);
            try writer.writeU8(corpusFormatCode(format));
            try writer.writeU8(0xff);
            try writer.writeU8(0xff);
        },
        .integer => |integer_type| {
            try writer.writeU8(1);
            try writer.writeU8(0xff);
            try writer.writeU8(0xff);
            try writer.writeU8(corpusIntegerTypeCode(integer_type));
        },
        .boolean => {
            try writer.writeU8(2);
            try writer.writeU8(0xff);
            try writer.writeU8(0xff);
            try writer.writeU8(0);
        },
        .structure => |structure| {
            try writer.writeU8(3);
            try writer.writeU8(corpusFormatCode(structure.format));
            try writer.writeU8(corpusStructureCode(structure.kind));
            try writer.writeU8(0);
        },
    }
}

fn decodeCorpusResultDescriptor(reader: *CorpusReader) CorpusRecordError!ResultDescriptor {
    const result_kind = try reader.readU8();
    const format_code = try reader.readU8();
    const structure_code = try reader.readU8();
    const integer_code = try reader.readU8();
    return switch (result_kind) {
        0 => blk: {
            if (structure_code != 0xff or integer_code != 0xff) {
                return error.InvalidResultDescriptor;
            }
            break :blk .{ .float = try parseCorpusFormat(format_code) };
        },
        1 => blk: {
            if (format_code != 0xff or structure_code != 0xff) {
                return error.InvalidResultDescriptor;
            }
            break :blk .{ .integer = try parseCorpusIntegerType(integer_code) };
        },
        2 => if (format_code != 0xff or structure_code != 0xff or integer_code != 0)
            error.InvalidResultDescriptor
        else
            .{ .boolean = {} },
        3 => blk: {
            if (integer_code != 0) return error.InvalidResultDescriptor;
            break :blk .{
                .structure = .{
                    .kind = try parseCorpusStructure(structure_code),
                    .format = try parseCorpusFormat(format_code),
                },
            };
        },
        else => error.UnknownResultDescriptorKind,
    };
}

fn encodeCorpusField(writer: *CorpusWriter, field: CorpusField) CorpusRecordError!void {
    try writer.writeU8(corpusFieldKindCode(field));
    try writer.writeU8(corpusFieldFormatCode(field));
    try writer.writeU8(corpusFieldClassCode(corpusFieldClass(field)));
    try writer.writeU8(corpusFieldTypeCode(field));
    switch (field) {
        .float => |value| try writer.writeU64(value.bits),
        .signed_integer => |value| try writer.writeU64(
            try encodeSignedInteger(value.value, value.integer_type.oracleValueBits()),
        ),
        .unsigned_integer => |value| try writer.writeU64(value.value),
        .boolean => |value| try writer.writeU8(if (value) 1 else 0),
        .tag => |value| {
            try writer.writeU32(@intCast(value.len));
            try writer.bytes(value);
        },
        .rounding => {},
    }
}

fn decodeCorpusField(
    reader: *CorpusReader,
    result_descriptor: ?OracleFieldDescriptor,
) CorpusRecordError!CorpusField {
    const kind = try reader.readU8();
    const format_code = try reader.readU8();
    const class = try parseCorpusFieldClass(try reader.readU8());
    const type_code = try reader.readU8();
    if (kind != 0 and class != .none) return error.InvalidFieldClass;
    if (kind != 0 and format_code != 0) return error.UnknownFormat;
    if (kind == 0 and type_code != 0) return error.InvalidInputValue;
    const field: CorpusField = switch (kind) {
        0 => .{ .float = .{
            .format = try parseCorpusFormat(format_code),
            .bits = try reader.readU64(),
            .class = class,
        } },
        1 => blk: {
            const integer_type = try parseCorpusIntegerType(type_code);
            if (@intFromEnum(integer_type) > @intFromEnum(IntegerType.i64)) {
                return error.ResultFieldMismatch;
            }
            break :blk .{ .signed_integer = .{
                .integer_type = integer_type,
                .value = try decodeSignedInteger(
                    try reader.readU64(),
                    integer_type.oracleValueBits(),
                ),
            } };
        },
        2 => .{ .unsigned_integer = .{
            .integer_type = try parseCorpusIntegerType(type_code),
            .value = try reader.readU64(),
        } },
        3 => blk: {
            const value = try reader.readU8();
            if (value > 1) return error.InvalidBoolean;
            break :blk .{ .boolean = value == 1 };
        },
        4 => blk: {
            const length = try reader.readU32();
            break :blk .{ .tag = try reader.take(length) };
        },
        5 => .{ .rounding = try parseCorpusRounding(type_code) },
        else => return error.UnknownFieldKind,
    };
    try validateCorpusField(field, result_descriptor);
    return field;
}

pub fn corpusRecordEncodedLength(record: *const CorpusRecord) CorpusRecordError!usize {
    var length = descriptor_record_header_length + record.operation.len + record.provenance.count;
    for (record.arguments.slice()) |field| {
        length += 4;
        length += switch (field) {
            .float, .signed_integer, .unsigned_integer => 8,
            .boolean => 1,
            .tag => |value| 4 + value.len,
            .rounding => 0,
        };
    }
    for (record.results.slice()) |field| {
        length += 4;
        length += switch (field) {
            .float, .signed_integer, .unsigned_integer => 8,
            .boolean => 1,
            .tag => |value| 4 + value.len,
            .rounding => 0,
        };
    }
    if (length > @as(usize, std.math.maxInt(u32))) return error.InvalidRecordLength;
    return length;
}

pub fn encodeCorpusRecord(
    record: *const CorpusRecord,
    target: []u8,
) CorpusRecordError![]u8 {
    const length = try corpusRecordEncodedLength(record);
    if (target.len < length) return error.OutputTooSmall;
    var writer = CorpusWriter{ .target = target[0..length] };
    try writer.bytes("ZCDR");
    try writer.writeU8(descriptor_corpus_codec_version);
    try writer.writeU32(@intCast(length));
    try writer.writeU16(@intCast(record.operation.len));
    try writer.writeU8(@intCast(record.provenance.count));
    try writer.writeU8(@intCast(record.arguments.count));
    try writer.writeU8(@intCast(record.results.count));
    try writer.writeU64(record.max_ulp);
    try encodeCorpusResultDescriptor(&writer, record.result_descriptor);
    try writer.bytes(record.operation);
    for (record.provenance.slice()) |provenance| try writer.writeU8(@intFromEnum(provenance));
    for (record.arguments.slice()) |field| try encodeCorpusField(&writer, field);
    for (record.results.slice()) |field| try encodeCorpusField(&writer, field);
    if (writer.index != length) return error.InvalidRecordLength;
    return target[0..length];
}

pub fn decodeCorpusRecord(source: []const u8) CorpusRecordError!CorpusRecord {
    if (source.len < descriptor_record_header_length) return error.TruncatedRecord;
    if (!std.mem.eql(u8, source[0..4], "ZCDR")) return error.InvalidRecordMagic;
    if (source[4] != descriptor_corpus_codec_version) return error.UnknownRecordVersion;
    var reader = CorpusReader{ .source = source };
    _ = try reader.take(5);
    const declared_length = try reader.readU32();
    if (@as(usize, declared_length) < descriptor_record_header_length) {
        return error.InvalidRecordLength;
    }
    if (@as(usize, declared_length) > source.len) return error.TruncatedRecord;
    if (@as(usize, declared_length) < source.len) return error.TrailingRecordBytes;
    const operation_length = try reader.readU16();
    const provenance_count = try reader.readU8();
    const argument_count = try reader.readU8();
    const result_count = try reader.readU8();
    const max_ulp = try reader.readU64();
    const result_descriptor = try decodeCorpusResultDescriptor(&reader);
    if (operation_length == 0 or reader.index + operation_length > source.len) {
        return error.InvalidOperationName;
    }
    const operation = try reader.take(operation_length);
    try validateOperationName(operation);
    if (provenance_count == 0 or provenance_count > max_provenance_count) {
        return error.ProvenanceLimit;
    }
    if (argument_count == 0 or argument_count > max_argument_count) {
        return error.ArgumentLimit;
    }
    if (result_count != result_descriptor.oracleFieldCount()) return error.ResultFieldMismatch;
    var provenance: ProvenanceList = .empty;
    for (0..provenance_count) |_| {
        const parsed = try parseCorpusProvenance(try reader.readU8());
        if (provenance.count != 0 and @intFromEnum(parsed) <=
            @intFromEnum(provenance.values[provenance.count - 1]))
        {
            if (parsed == provenance.values[provenance.count - 1]) {
                return error.DuplicateProvenance;
            }
            return error.UnsortedProvenance;
        }
        provenance.values[provenance.count] = parsed;
        provenance.count += 1;
    }
    var record: CorpusRecord = .{
        .operation = operation,
        .provenance = provenance,
        .arguments = .empty,
        .result_descriptor = result_descriptor,
        .results = .empty,
        .max_ulp = max_ulp,
    };
    for (0..argument_count) |_| {
        const field = try decodeCorpusField(&reader, null);
        record.arguments.values[record.arguments.count] = field;
        record.arguments.count += 1;
    }
    for (0..result_count) |index| {
        const descriptor = result_descriptor.oracleFieldDescriptor(index) orelse
            return error.ResultFieldMismatch;
        const field = try decodeCorpusField(&reader, descriptor);
        record.results.values[record.results.count] = field;
        record.results.count += 1;
    }
    if (reader.index != source.len) return error.TrailingRecordBytes;
    return record;
}

fn corpusResultDescriptorKey(descriptor: ResultDescriptor) [4]u8 {
    return switch (descriptor) {
        .float => |format| .{ 0, corpusFormatCode(format), 0xff, 0xff },
        .integer => |integer_type| .{
            1,
            0xff,
            0xff,
            corpusIntegerTypeCode(integer_type),
        },
        .boolean => .{ 2, 0xff, 0xff, 0 },
        .structure => |structure| .{
            3,
            corpusFormatCode(structure.format),
            corpusStructureCode(structure.kind),
            0,
        },
    };
}

fn compareCorpusResultDescriptor(
    previous: ResultDescriptor,
    current: ResultDescriptor,
) std.math.Order {
    const previous_key = corpusResultDescriptorKey(previous);
    const current_key = corpusResultDescriptorKey(current);
    return std.mem.order(u8, previous_key[0..], current_key[0..]);
}

fn compareCorpusField(previous: CorpusField, current: CorpusField) std.math.Order {
    const previous_kind = corpusFieldKindCode(previous);
    const current_kind = corpusFieldKindCode(current);
    if (previous_kind < current_kind) return .lt;
    if (previous_kind > current_kind) return .gt;
    const previous_format = corpusFieldFormatCode(previous);
    const current_format = corpusFieldFormatCode(current);
    if (previous_format < current_format) return .lt;
    if (previous_format > current_format) return .gt;
    const previous_class = corpusFieldClassCode(corpusFieldClass(previous));
    const current_class = corpusFieldClassCode(corpusFieldClass(current));
    if (previous_class < current_class) return .lt;
    if (previous_class > current_class) return .gt;
    const previous_type = corpusFieldTypeCode(previous);
    const current_type = corpusFieldTypeCode(current);
    if (previous_type < current_type) return .lt;
    if (previous_type > current_type) return .gt;
    return switch (previous) {
        .float => |value| switch (current) {
            .float => |current_value| if (value.bits < current_value.bits)
                .lt
            else if (value.bits > current_value.bits)
                .gt
            else
                .eq,
            else => .gt,
        },
        .signed_integer => |value| switch (current) {
            .signed_integer => |current_value| if (value.value < current_value.value)
                .lt
            else if (value.value > current_value.value)
                .gt
            else
                .eq,
            else => .gt,
        },
        .unsigned_integer => |value| switch (current) {
            .unsigned_integer => |current_value| if (value.value < current_value.value)
                .lt
            else if (value.value > current_value.value)
                .gt
            else
                .eq,
            else => .gt,
        },
        .boolean => |value| switch (current) {
            .boolean => |current_value| if (!value and current_value)
                .lt
            else if (value and !current_value)
                .gt
            else
                .eq,
            else => .gt,
        },
        .tag => |value| switch (current) {
            .tag => |current_value| std.mem.order(u8, value, current_value),
            else => .gt,
        },
        .rounding => .eq,
    };
}

pub fn validateCorpusRecordOrder(
    previous: *const CorpusRecord,
    current: *const CorpusRecord,
) CorpusRecordError!void {
    const operation_order = std.mem.order(u8, previous.operation, current.operation);
    if (operation_order == .gt) return error.UnsortedCorpusRecord;
    if (operation_order == .lt) return;
    const provenance_order = compareProvenance(previous.provenance, current.provenance);
    if (provenance_order == .gt) return error.UnsortedCorpusRecord;
    if (provenance_order == .lt) return;
    const descriptor_order = compareCorpusResultDescriptor(
        previous.result_descriptor,
        current.result_descriptor,
    );
    if (descriptor_order == .gt) return error.UnsortedCorpusRecord;
    if (descriptor_order == .lt) return;
    if (previous.arguments.count < current.arguments.count) return;
    if (previous.arguments.count > current.arguments.count) return error.UnsortedCorpusRecord;
    for (previous.arguments.slice(), current.arguments.slice()) |previous_field, current_field| {
        const field_order = compareCorpusField(previous_field, current_field);
        if (field_order == .gt) return error.UnsortedCorpusRecord;
        if (field_order == .lt) return;
    }
    return error.DuplicateCorpusRecord;
}

pub const CorpusRecordIterator = struct {
    source: []const u8,
    offset: usize = 0,
    previous: ?CorpusRecord = null,

    pub fn next(self: *@This()) CorpusRecordError!?CorpusRecord {
        if (self.offset == self.source.len) return null;
        if (self.source.len - self.offset < 9) return error.TruncatedRecord;
        const length = @as(u32, self.source[self.offset + 5]) |
            (@as(u32, self.source[self.offset + 6]) << 8) |
            (@as(u32, self.source[self.offset + 7]) << 16) |
            (@as(u32, self.source[self.offset + 8]) << 24);
        if (length == 0) return error.InvalidRecordLength;
        const length_usize: usize = @intCast(length);
        if (length_usize > self.source.len - self.offset) return error.TruncatedRecord;
        const record = try decodeCorpusRecord(
            self.source[self.offset .. self.offset + length_usize],
        );
        if (self.previous) |previous| {
            try validateCorpusRecordOrder(&previous, &record);
        }
        self.offset += length_usize;
        self.previous = record;
        return record;
    }
};

pub fn corpusRecords(source: []const u8) CorpusRecordIterator {
    return .{ .source = source };
}

pub fn validateDescriptorCorpus(source: []const u8) CorpusRecordError!void {
    var iterator = corpusRecords(source);
    while ((try iterator.next()) != null) {}
}

pub fn validateScalarTsvV2(source: []const u8) ValidationError!void {
    // This is deliberately the legacy scalar-only reader. New campaigns must
    // use validateDescriptorCorpus and must not overload these seven columns.
    return validateTsv(source);
}

const RootKey = enum(u8) {
    schema_version,
    core_math_repository,
    core_math_revision,
    mpfr_precision_bits,
    arb_precision_bits,
    rounding,
    formats,
    reserved_formats,
    rejected_formats,
    operation_spelling,
    columns,
    hexadecimal,
    uncertainty_policy,
    special_policy,
};
const root_key_count = @typeInfo(RootKey).@"enum".fields.len;

const FunctionKey = enum(u8) {
    op,
    provenance,
    status,
    arity,
    inputs,
    result,
    oracle,
    special_policy,
    max_ulp,
};

const FunctionBuilder = struct {
    function: Function,
    seen: [@typeInfo(FunctionKey).@"enum".fields.len]bool = [_]bool{false} **
        @typeInfo(FunctionKey).@"enum".fields.len,
    next_key: usize = 0,
};

const OutputClass = enum {
    normal,
    subnormal,
    zero,
    infinity,
    qnan,
    snan,
};

const SortKey = struct {
    operation: []const u8,
    input_format: Format,
    output_format: Format,
    input_bits: []const u8,
};

pub fn validateEmbeddedManifest() ValidationError!void {
    _ = try parseManifest(manifest_text);
}

pub fn validateManifest(source: []const u8) ValidationError!void {
    _ = try parseManifest(source);
}

pub fn parseManifest(source: []const u8) ValidationError!Manifest {
    try validateTextEnvelope(source, false);

    var manifest: Manifest = .{};
    var root_seen = [_]bool{false} ** @typeInfo(RootKey).@"enum".fields.len;
    var root_next_key: usize = 0;
    var root_complete = false;
    var current: ?FunctionBuilder = null;
    var previous: ?Function = null;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.eql(u8, line, "[[function]]")) {
            if (!root_complete) {
                try requireAllRootKeys(root_seen);
                root_complete = true;
            }
            if (current) |builder| {
                try appendFunction(&manifest, &previous, builder);
            }
            current = newFunctionBuilder();
            continue;
        }
        if (line[0] == '[') return error.UnknownSection;

        const equal_index = std.mem.indexOfScalar(u8, line, '=') orelse
            return error.MalformedLine;
        const key = std.mem.trim(u8, line[0..equal_index], " \t");
        const value = std.mem.trim(u8, line[equal_index + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return error.MalformedLine;

        if (current) |*builder| {
            try parseFunctionField(builder, key, value);
        } else {
            if (root_complete) return error.RootKeyAfterFunction;
            try parseRootField(&root_seen, &root_next_key, key, value);
        }
    }

    if (!root_complete) try requireAllRootKeys(root_seen);
    if (current) |builder| {
        try appendFunction(&manifest, &previous, builder);
    }
    if (manifest.function_count == 0) return error.MissingFunctionRow;
    return manifest;
}

/// Validate only the legacy seven-column unary scalar TSV compatibility format.
/// Descriptor campaigns must use `validateDescriptorCorpus` instead.
pub fn validateTsv(source: []const u8) ValidationError!void {
    try validateTextEnvelope(source, true);

    const body = source[0 .. source.len - 1];
    var lines = std.mem.splitScalar(u8, body, '\n');
    const header = lines.next() orelse return error.InvalidHeader;
    if (!std.mem.eql(
        u8,
        header,
        "op\tinput_format\toutput_format\tinput_bits\toutput_bits\toutput_class\tmax_ulp",
    )) return error.InvalidHeader;

    var previous: ?SortKey = null;
    while (lines.next()) |line| {
        if (line.len == 0) return error.BlankCorpusLine;

        var fields: [7][]const u8 = undefined;
        var field_count: usize = 0;
        var field_iterator = std.mem.splitScalar(u8, line, '\t');
        while (field_iterator.next()) |field| {
            if (field_count == fields.len) return error.WrongColumnCount;
            fields[field_count] = field;
            field_count += 1;
        }
        if (field_count != fields.len) return error.WrongColumnCount;

        try validateOperationName(fields[0]);
        const input_format = try parseFormat(fields[1]);
        const output_format = try parseFormat(fields[2]);
        try validateHexBits(fields[3], input_format);
        try validateHexBits(fields[4], output_format);
        const declared_output_class = try parseOutputClass(fields[5]);
        const derived_output_class = try deriveOutputClass(fields[4], output_format);
        if (declared_output_class != derived_output_class) {
            return error.OutputClassMismatch;
        }
        try validateMaxUlp(fields[6]);
        if (isSpecial(derived_output_class) and !std.mem.eql(u8, fields[6], "0")) {
            return error.InvalidMaxUlp;
        }

        const current = SortKey{
            .operation = fields[0],
            .input_format = input_format,
            .output_format = output_format,
            .input_bits = fields[3],
        };
        if (previous) |prior| try validateSorted(prior, current);
        previous = current;
    }
}

fn newFunctionBuilder() FunctionBuilder {
    return .{
        .function = .{
            .op = "",
            .provenance = .empty,
            .status = .unsupported,
            .arity = 0,
            .inputs = .empty,
            .result = .{ .boolean = {} },
            .oracle = .none,
            .special_policy = "",
            .max_ulp = 0,
        },
    };
}

fn appendFunction(
    manifest: *Manifest,
    previous: *?Function,
    builder: FunctionBuilder,
) ValidationError!void {
    try finishFunction(builder);
    if (manifest.function_count == max_function_count) return error.FunctionLimit;
    if (previous.*) |prior| try validateFunctionOrder(prior, builder.function);
    manifest.function_values[manifest.function_count] = builder.function;
    manifest.function_count += 1;
    previous.* = builder.function;
}

fn finishFunction(builder: FunctionBuilder) ValidationError!void {
    for (builder.seen) |seen| {
        if (!seen) return error.MissingFunctionKey;
    }
    if (builder.function.op.len == 0) return error.InvalidOperationName;
    if (builder.function.arity == 0 or builder.function.arity > max_argument_count) {
        return error.InvalidArity;
    }
    if (builder.function.inputs.count != builder.function.arity) return error.ArityMismatch;
    if (builder.function.provenance.count == 0) return error.MissingFunctionKey;
    if (!std.mem.eql(u8, builder.function.special_policy, "zmath_c23_v1")) {
        return error.InvalidSpecialPolicy;
    }
    switch (builder.function.status) {
        .unsupported => {
            if (builder.function.max_ulp != 0) return error.InvalidStatusMaxUlp;
            if (builder.function.oracle != .none) return error.StatusOracleMismatch;
        },
        .correct => {
            if (builder.function.max_ulp != 0) return error.InvalidStatusMaxUlp;
            if (builder.function.oracle != .mpfr_arb) return error.StatusOracleMismatch;
        },
        .bounded => {
            if (builder.function.oracle != .mpfr_arb) return error.StatusOracleMismatch;
        },
    }
}

fn parseRootField(
    root_seen: *[root_key_count]bool,
    root_next_key: *usize,
    name: []const u8,
    value: []const u8,
) ValidationError!void {
    const key = parseRootKey(name) orelse return error.UnknownRootKey;
    const key_index = @intFromEnum(key);
    if (root_seen[key_index]) return error.DuplicateRootKey;
    if (key_index != root_next_key.*) return error.UnsortedRootKey;
    root_seen[key_index] = true;
    root_next_key.* += 1;

    switch (key) {
        .schema_version => try expectUnsigned(value, 2),
        .core_math_repository => try expectString(
            value,
            "https://gitlab.inria.fr/core-math/core-math.git",
        ),
        .core_math_revision => {
            const revision = try parseString(value);
            if (revision.len != 40) return error.InvalidPinnedValue;
            if (!std.mem.eql(
                u8,
                revision,
                "3bafed75e3c22399531857d63a3fa0e24bfb42fa",
            )) return error.InvalidPinnedValue;
            for (revision) |digit| {
                if (!isLowerHexDigit(digit)) return error.InvalidPinnedValue;
            }
        },
        .mpfr_precision_bits, .arb_precision_bits => try expectUnsigned(value, 512),
        .rounding => try expectString(value, "nearest_even"),
        .formats => try expectFormatArray(value),
        .reserved_formats => try expectStringArray(value, &.{"q"}),
        .rejected_formats => try expectStringArray(value, &.{ "q", "f128", "bfloat16" }),
        .operation_spelling => try expectString(value, "case_sensitive_ascii_identifier"),
        .columns => try expectStringArray(value, &.{
            "op",
            "provenance",
            "status",
            "arity",
            "inputs",
            "result",
            "oracle",
            "special_policy",
            "max_ulp",
        }),
        .hexadecimal => try expectString(value, "lowercase_fixed_width"),
        .uncertainty_policy => try expectString(value, "fail_closed"),
        .special_policy => try expectString(value, "zmath_c23_v1"),
    }
}

fn parseFunctionField(
    builder: *FunctionBuilder,
    name: []const u8,
    value: []const u8,
) ValidationError!void {
    const key = parseFunctionKey(name) orelse return error.UnknownFunctionKey;
    const key_index = @intFromEnum(key);
    if (builder.seen[key_index]) return error.DuplicateFunctionKey;
    if (key_index != builder.next_key) return error.UnsortedFunctionKey;
    builder.seen[key_index] = true;
    builder.next_key += 1;

    switch (key) {
        .op => {
            const operation = try parseString(value);
            try validateOperationName(operation);
            builder.function.op = operation;
        },
        .provenance => try parseProvenance(value, &builder.function.provenance),
        .status => builder.function.status = try parseStatus(value),
        .arity => {
            const arity = std.fmt.parseUnsigned(u8, value, 10) catch return error.InvalidArity;
            if (arity == 0 or arity > max_argument_count) return error.InvalidArity;
            builder.function.arity = arity;
        },
        .inputs => try parseInputs(value, &builder.function.inputs),
        .result => builder.function.result = try parseResult(value),
        .oracle => builder.function.oracle = try parseOracle(value),
        .special_policy => {
            const policy = try parseString(value);
            if (!std.mem.eql(u8, policy, "zmath_c23_v1")) return error.InvalidSpecialPolicy;
            builder.function.special_policy = policy;
        },
        .max_ulp => builder.function.max_ulp = try parseMaxUlp(value),
    }
}

fn parseProvenance(value: []const u8, result: *ProvenanceList) ValidationError!void {
    var values: [max_provenance_count][]const u8 = undefined;
    const count = try parseStringArray(max_provenance_count, value, &values);
    if (count == 0 or count > max_provenance_count) return error.UnknownProvenance;
    result.* = .empty;
    var previous: ?Provenance = null;
    for (values[0..count]) |text| {
        const provenance = parseProvenanceName(text) orelse return error.UnknownProvenance;
        if (previous) |prior| {
            if (@intFromEnum(provenance) == @intFromEnum(prior)) return error.DuplicateProvenance;
            if (@intFromEnum(provenance) < @intFromEnum(prior)) return error.UnsortedProvenance;
        }
        result.values[result.count] = provenance;
        result.count += 1;
        previous = provenance;
    }
}

fn parseInputs(value: []const u8, result: *ArgumentList) ValidationError!void {
    var values: [max_argument_count][]const u8 = undefined;
    const count = try parseStringArray(max_argument_count, value, &values);
    if (count == 0 or count > max_argument_count) return error.ArgumentLimit;
    result.* = .empty;
    for (values[0..count]) |text| {
        result.values[result.count] = try parseArgument(text);
        result.count += 1;
    }
}

fn parseArgument(text: []const u8) ValidationError!ArgumentDescriptor {
    if (std.mem.eql(u8, text, "tag")) return .tag;
    if (std.mem.eql(u8, text, "fromfp_round")) return .fromfp_round;
    if (std.mem.startsWith(u8, text, "float:")) {
        return .{ .float = try parseFormat(text[6..]) };
    }
    if (std.mem.startsWith(u8, text, "integer:")) {
        const integer_name = text[8..];
        return .{ .integer = parseIntegerType(integer_name) orelse return error.UnknownIntegerType };
    }
    return error.MalformedDescriptor;
}

fn parseResult(value: []const u8) ValidationError!ResultDescriptor {
    const text = try parseString(value);
    if (std.mem.eql(u8, text, "bool")) return .boolean;
    if (std.mem.startsWith(u8, text, "float:")) {
        return .{ .float = try parseFormat(text[6..]) };
    }
    if (std.mem.startsWith(u8, text, "integer:")) {
        const integer_name = text[8..];
        return .{ .integer = parseIntegerType(integer_name) orelse return error.UnknownIntegerType };
    }
    if (std.mem.startsWith(u8, text, "struct:")) return .{ .structure = try parseStruct(text[7..]) };
    return error.UnknownResultDescriptor;
}

fn parseStruct(text: []const u8) ValidationError!StructDescriptor {
    var pieces = std.mem.splitScalar(u8, text, ':');
    const kind_name = pieces.next() orelse return error.MalformedDescriptor;
    const format_name = pieces.next() orelse return error.MalformedDescriptor;
    if (pieces.next() != null) return error.MalformedDescriptor;
    const kind = parseStructKind(kind_name) orelse return error.UnknownStructKind;
    return .{ .kind = kind, .format = try parseFormat(format_name) };
}

fn parseStatus(value: []const u8) ValidationError!Status {
    const text = try parseString(value);
    if (std.mem.eql(u8, text, "unsupported")) return .unsupported;
    if (std.mem.eql(u8, text, "correct")) return .correct;
    if (std.mem.eql(u8, text, "bounded")) return .bounded;
    return error.UnknownStatus;
}

fn parseOracle(value: []const u8) ValidationError!OracleCapability {
    const text = try parseString(value);
    if (std.mem.eql(u8, text, "none")) return .none;
    if (std.mem.eql(u8, text, "mpfr")) return .mpfr;
    if (std.mem.eql(u8, text, "mpfr_arb")) return .mpfr_arb;
    return error.UnknownOracleCapability;
}

fn parseMaxUlp(value: []const u8) ValidationError!u64 {
    try validateMaxUlp(value);
    return std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidMaxUlp;
}

fn parseRootKey(name: []const u8) ?RootKey {
    inline for (@typeInfo(RootKey).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn parseFunctionKey(name: []const u8) ?FunctionKey {
    inline for (@typeInfo(FunctionKey).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn parseFormat(text: []const u8) ValidationError!Format {
    if (std.mem.eql(u8, text, "h")) return .h;
    if (std.mem.eql(u8, text, "f")) return .f;
    if (std.mem.eql(u8, text, "d")) return .d;
    if (std.mem.eql(u8, text, "q")) return error.ReservedFormat;
    if (std.mem.eql(u8, text, "f128") or std.mem.eql(u8, text, "bfloat16")) {
        return error.RejectedFormat;
    }
    return error.UnknownFormat;
}

fn parseIntegerType(text: []const u8) ?IntegerType {
    inline for (@typeInfo(IntegerType).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn parseProvenanceName(text: []const u8) ?Provenance {
    inline for (@typeInfo(Provenance).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn parseStructKind(text: []const u8) ?StructKind {
    inline for (@typeInfo(StructKind).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn parseString(value: []const u8) ValidationError![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') {
        return error.InvalidPinnedValue;
    }
    const text = value[1 .. value.len - 1];
    if (std.mem.indexOfAny(u8, text, "\\\"") != null) return error.InvalidPinnedValue;
    return text;
}

fn parseStringArray(
    comptime capacity: usize,
    value: []const u8,
    result: *[capacity][]const u8,
) ValidationError!usize {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') {
        return error.InvalidPinnedValue;
    }
    const elements = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    if (elements.len == 0) return 0;
    var iterator = std.mem.splitScalar(u8, elements, ',');
    var count: usize = 0;
    while (iterator.next()) |element| {
        if (count == result.*.len) return error.ArgumentLimit;
        const item = std.mem.trim(u8, element, " \t");
        if (item.len == 0) return error.InvalidPinnedValue;
        result[count] = try parseString(item);
        count += 1;
    }
    return count;
}

fn expectString(value: []const u8, expected: []const u8) ValidationError!void {
    const actual = try parseString(value);
    if (!std.mem.eql(u8, actual, expected)) return error.InvalidPinnedValue;
}

fn expectUnsigned(value: []const u8, expected: u16) ValidationError!void {
    const actual = std.fmt.parseUnsigned(u16, value, 10) catch return error.InvalidPinnedValue;
    if (actual != expected) return error.InvalidPinnedValue;
}
fn expectStringArray(value: []const u8, expected: []const []const u8) ValidationError!void {
    var actual: [max_manifest_list_count][]const u8 = undefined;
    const count = try parseStringArray(max_manifest_list_count, value, &actual);
    if (count != expected.len) return error.InvalidPinnedValue;
    for (expected, 0..) |item, index| {
        if (!std.mem.eql(u8, actual[index], item)) return error.InvalidPinnedValue;
    }
}
fn expectFormatArray(value: []const u8) ValidationError!void {
    var actual: [max_manifest_list_count][]const u8 = undefined;
    const count = try parseStringArray(max_manifest_list_count, value, &actual);
    if (count != 3) return error.InvalidPinnedValue;
    const expected = [_]Format{ .h, .f, .d };
    for (expected, 0..) |item, index| {
        if ((try parseFormat(actual[index])) != item) return error.InvalidPinnedValue;
    }
}

fn requireAllRootKeys(root_seen: [root_key_count]bool) ValidationError!void {
    for (root_seen) |seen| {
        if (!seen) return error.MissingRootKey;
    }
}

fn validateTextEnvelope(source: []const u8, require_final_newline: bool) ValidationError!void {
    if (std.mem.startsWith(u8, source, "\xef\xbb\xbf")) return error.ByteOrderMark;
    if (std.mem.indexOfScalar(u8, source, '\r') != null) return error.CarriageReturn;
    if (require_final_newline) {
        if (source.len == 0 or source[source.len - 1] != '\n') return error.MissingFinalNewline;
    }
}

fn validateOperationName(operation: []const u8) ValidationError!void {
    if (operation.len == 0) return error.InvalidOperationName;
    if (!isAsciiLetter(operation[0]) and operation[0] != '_') return error.InvalidOperationName;
    for (operation[1..]) |character| {
        if (!isAsciiLetter(character) and !isAsciiDigit(character) and character != '_') {
            return error.InvalidOperationName;
        }
    }
}

fn isAsciiLetter(character: u8) bool {
    return (character >= 'a' and character <= 'z') or (character >= 'A' and character <= 'Z');
}

fn isAsciiDigit(character: u8) bool {
    return character >= '0' and character <= '9';
}

fn isLowerHexDigit(digit: u8) bool {
    return (digit >= '0' and digit <= '9') or (digit >= 'a' and digit <= 'f');
}

fn validateHexBits(text: []const u8, format: Format) ValidationError!void {
    if (text.len != format.hexadecimalDigits()) return error.InvalidHexWidth;
    for (text) |digit| {
        if (digit >= 'A' and digit <= 'F') return error.UppercaseHexDigit;
        if (!isLowerHexDigit(digit)) return error.InvalidHexDigit;
    }
}

fn validateMaxUlp(text: []const u8) ValidationError!void {
    if (text.len == 0) return error.InvalidMaxUlp;
    if (text.len > 1 and text[0] == '0') return error.InvalidMaxUlp;
    for (text) |digit| {
        if (!isAsciiDigit(digit)) return error.InvalidMaxUlp;
    }
}

fn parseOutputClass(text: []const u8) ValidationError!OutputClass {
    if (std.mem.eql(u8, text, "normal")) return .normal;
    if (std.mem.eql(u8, text, "subnormal")) return .subnormal;
    if (std.mem.eql(u8, text, "zero")) return .zero;
    if (std.mem.eql(u8, text, "infinity")) return .infinity;
    if (std.mem.eql(u8, text, "qnan")) return .qnan;
    return error.UnknownOutputClass;
}

fn deriveOutputClass(text: []const u8, format: Format) ValidationError!OutputClass {
    const bits = std.fmt.parseUnsigned(u64, text, 16) catch return error.InvalidHexDigit;
    const exponent_mask: u64 = switch (format) {
        .h => 0x7c00,
        .f => 0x7f80_0000,
        .d => 0x7ff0_0000_0000_0000,
    };
    const fraction_mask: u64 = switch (format) {
        .h => 0x03ff,
        .f => 0x007f_ffff,
        .d => 0x000f_ffff_ffff_ffff,
    };
    const quiet_nan_mask: u64 = switch (format) {
        .h => 0x0200,
        .f => 0x0040_0000,
        .d => 0x0008_0000_0000_0000,
    };
    const exponent = bits & exponent_mask;
    const fraction = bits & fraction_mask;
    if (exponent == 0) {
        if (fraction == 0) return .zero;
        return .subnormal;
    }
    if (exponent != exponent_mask) return .normal;
    if (fraction == 0) return .infinity;
    if ((fraction & quiet_nan_mask) != 0) return .qnan;
    return .snan;
}

fn isSpecial(output_class: OutputClass) bool {
    return switch (output_class) {
        .normal, .subnormal => false,
        .zero, .infinity, .qnan, .snan => true,
    };
}

fn validateFunctionOrder(previous: Function, current: Function) ValidationError!void {
    switch (compareFunction(previous, current)) {
        .lt => {},
        .eq => return error.DuplicateFunctionRow,
        .gt => return error.UnsortedFunctionRow,
    }
}

fn compareFunction(previous: Function, current: Function) std.math.Order {
    const provenance_order = compareProvenance(previous.provenance, current.provenance);
    if (provenance_order != .eq) return provenance_order;
    const operation_order = std.mem.order(u8, previous.op, current.op);
    if (operation_order != .eq) return operation_order;
    const input_order = compareInputs(previous.inputs, current.inputs);
    if (input_order != .eq) return input_order;
    return compareResults(previous.result, current.result);
}

fn compareProvenance(previous: ProvenanceList, current: ProvenanceList) std.math.Order {
    const common = @min(previous.count, current.count);
    for (0..common) |index| {
        const prior = @intFromEnum(previous.values[index]);
        const next = @intFromEnum(current.values[index]);
        if (prior < next) return .lt;
        if (prior > next) return .gt;
    }
    if (previous.count < current.count) return .lt;
    if (previous.count > current.count) return .gt;
    return .eq;
}

fn compareInputs(previous: ArgumentList, current: ArgumentList) std.math.Order {
    const common = @min(previous.count, current.count);
    for (0..common) |index| {
        const order = compareArguments(previous.values[index], current.values[index]);
        if (order != .eq) return order;
    }
    if (previous.count < current.count) return .lt;
    if (previous.count > current.count) return .gt;
    return .eq;
}

fn compareArguments(previous: ArgumentDescriptor, current: ArgumentDescriptor) std.math.Order {
    const previous_rank = argumentRank(previous);
    const current_rank = argumentRank(current);
    if (previous_rank < current_rank) return .lt;
    if (previous_rank > current_rank) return .gt;
    return .eq;
}

fn argumentRank(argument: ArgumentDescriptor) u8 {
    return switch (argument) {
        .float => |format| 10 + @as(u8, @intFromEnum(format)),
        .integer => |integer| 20 + @as(u8, @intFromEnum(integer)),
        .fromfp_round => 40,
        .tag => 50,
    };
}

fn compareResults(previous: ResultDescriptor, current: ResultDescriptor) std.math.Order {
    const previous_rank = resultRank(previous);
    const current_rank = resultRank(current);
    if (previous_rank < current_rank) return .lt;
    if (previous_rank > current_rank) return .gt;
    return .eq;
}

fn resultRank(result: ResultDescriptor) u16 {
    return switch (result) {
        .float => |format| 10 + @as(u16, @intFromEnum(format)),
        .integer => |integer| 20 + @as(u16, @intFromEnum(integer)),
        .boolean => 40,
        .structure => |descriptor| 50 +
            @as(u16, @intFromEnum(descriptor.kind)) * 3 +
            @as(u16, @intFromEnum(descriptor.format)),
    };
}

fn validateSorted(previous: SortKey, current: SortKey) ValidationError!void {
    const operation_order = std.mem.order(u8, previous.operation, current.operation);
    if (operation_order == .gt) return error.UnsortedCorpusRow;
    if (operation_order == .lt) return;
    if (@intFromEnum(current.input_format) < @intFromEnum(previous.input_format)) {
        return error.UnsortedCorpusRow;
    }
    if (@intFromEnum(current.input_format) > @intFromEnum(previous.input_format)) return;
    if (@intFromEnum(current.output_format) < @intFromEnum(previous.output_format)) {
        return error.UnsortedCorpusRow;
    }
    if (@intFromEnum(current.output_format) > @intFromEnum(previous.output_format)) return;
    switch (std.mem.order(u8, previous.input_bits, current.input_bits)) {
        .lt => {},
        .eq => return error.DuplicateCorpusRow,
        .gt => return error.UnsortedCorpusRow,
    }
}

test "status-container result descriptors parse exact kinds and formats" {
    const cases = [_]struct {
        source: []const u8,
        kind: StructKind,
        format: Format,
    }{
        .{ .source = "\"struct:atan2:h\"", .kind = .atan2, .format = .h },
        .{ .source = "\"struct:atan2:f\"", .kind = .atan2, .format = .f },
        .{ .source = "\"struct:atan2:d\"", .kind = .atan2, .format = .d },
        .{ .source = "\"struct:power:h\"", .kind = .power, .format = .h },
        .{ .source = "\"struct:power:f\"", .kind = .power, .format = .f },
        .{ .source = "\"struct:power:d\"", .kind = .power, .format = .d },
        .{ .source = "\"struct:integer:h\"", .kind = .integer, .format = .h },
        .{ .source = "\"struct:integer:f\"", .kind = .integer, .format = .f },
        .{ .source = "\"struct:integer:d\"", .kind = .integer, .format = .d },
    };

    for (cases) |case| {
        const result = try parseResult(case.source);
        const structure = switch (result) {
            .structure => |structure| structure,
            else => return error.UnexpectedResultDescriptor,
        };
        try std.testing.expectEqual(case.kind, structure.kind);
        try std.testing.expectEqual(case.format, structure.format);
        try std.testing.expectEqual(case.kind.oracleKind(), result.oracleStructureKind());
    }
}

test "status-container result descriptors expose exact fields" {
    const formats = [_]Format{ .h, .f, .d };
    const float_boolean_kinds = [_]StructKind{ .atan2, .power };

    for (formats) |format| {
        for (float_boolean_kinds) |kind| {
            const result = ResultDescriptor{
                .structure = .{ .kind = kind, .format = format },
            };
            const float_field = result.oracleFieldDescriptor(0) orelse
                return error.MissingOracleFieldDescriptor;
            const status_field = result.oracleFieldDescriptor(1) orelse
                return error.MissingOracleFieldDescriptor;

            try std.testing.expectEqual(@as(usize, 2), result.oracleFieldCount());
            try std.testing.expectEqualDeep(
                oracleFloatFieldDescriptor(format),
                float_field,
            );
            try std.testing.expectEqualDeep(
                oracleBooleanFieldDescriptor(),
                status_field,
            );
            try std.testing.expect(result.oracleFieldDescriptor(2) == null);
        }

        const integer_result = ResultDescriptor{
            .structure = .{ .kind = .integer, .format = format },
        };
        const integer_field = integer_result.oracleFieldDescriptor(0) orelse
            return error.MissingOracleFieldDescriptor;
        const ok_field = integer_result.oracleFieldDescriptor(1) orelse
            return error.MissingOracleFieldDescriptor;

        try std.testing.expectEqual(@as(usize, 2), integer_result.oracleFieldCount());
        try std.testing.expectEqualDeep(
            IntegerType.i64.oracleDescriptor(),
            integer_field,
        );
        try std.testing.expectEqualDeep(
            oracleBooleanFieldDescriptor(),
            ok_field,
        );
        try std.testing.expect(integer_result.oracleFieldDescriptor(2) == null);
    }
}
