const std = @import("std");

pub const manifest_text = @embedFile("corpus/manifest.toml");

pub const canonical_function_count: usize = 315;
pub const function_count_max: usize = canonical_function_count;
pub const max_function_count: usize = function_count_max;
const function_key_count: usize = 9;
const input_count_max: usize = 3;
const manifest_bytes_max: usize = 256 * 1024;
const manifest_line_bytes_max: usize = 512;

pub const max_argument_count: usize = 8;
pub const max_result_field_count: usize = 2;
pub const max_provenance_count: usize = 2;
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
    snan = 6,
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

pub const ValidationError = error{
    ByteOrderMark,
    CarriageReturn,
    MissingFinalNewline,
    ManifestTooLarge,
    MalformedLine,
    UnknownRootKey,
    DuplicateRootKey,
    MissingRootKey,
    InvalidPinnedValue,
    UnknownSection,
    RootKeyAfterFunction,
    UnknownFunctionKey,
    DuplicateFunctionKey,
    UnorderedFunctionKey,
    MissingFunctionKey,
    TooManyFunctionRows,
    DuplicateFunctionRow,
    UnsortedFunctionRow,
    MissingFunctionRow,
    UnknownOperation,
    InvalidProvenance,
    InvalidArity,
    InvalidDescriptor,
    ReservedFormat,
    RejectedFormat,
    UnknownFormat,
    UnsupportedFunctionStatus,
    UnknownOracle,
    InvalidStatusRelation,
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
    InvalidArtifactName,
    MissingArtifactMetadata,
    UnsupportedTargetMode,
    MissingArtifactManifestRow,
    AmbiguousArtifactManifestRow,
    UnsupportedArtifact,
    EmptyArtifact,
    ArtifactOperationMismatch,
    ArtifactFormatMismatch,
    ArtifactMaxUlpMismatch,
    ArtifactRowCountMismatch,
    IncompleteUnaryHDomain,
    InvalidIntegerWidth,
    IntegerOutOfRange,
    IntegerPayloadOutOfRange,
    InvalidInputValue,
    InvalidResultClass,
    TagLengthOverflow,
    InvalidRecordMagic,
    UnknownRecordVersion,
    TruncatedRecord,
    TrailingRecordBytes,
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
    InvalidRecordLength,
};

// The runtime oracle dispatches only these operations. ManifestOperation below
// is the complete schema-v3 operation vocabulary.
pub const Operation = enum(u8) {
    exp,
    log,
    sin,

    fn manifestOperation(operation: Operation) ManifestOperation {
        return switch (operation) {
            .exp => .exp,
            .log => .log,
            .sin => .sin,
        };
    }
};

pub const ManifestOperation = enum(u8) {
    abs,
    acos,
    acosh,
    acospi,
    asin,
    asinh,
    asinpi,
    atan,
    atan2,
    atan2pi,
    atanh,
    atanpi,
    canonicalize,
    cbrt,
    ceil,
    compoundn,
    copySign,
    cos,
    cosh,
    cospi,
    erf,
    erfc,
    exp,
    exp10,
    exp10m1,
    exp2,
    exp2m1,
    expm1,
    f16addf32,
    f16addf64,
    f16divf32,
    f16divf64,
    f16fmaf32,
    f16fmaf64,
    f16mulf32,
    f16mulf64,
    f16sqrtf32,
    f16sqrtf64,
    f16subf32,
    f16subf64,
    f32addf64,
    f32divf64,
    f32fmaf64,
    f32mulf64,
    f32sqrtf64,
    f32subf64,
    fadd,
    fdim,
    fdiv,
    ffma,
    floor,
    fma,
    fmax,
    fmaximum,
    fmaximum_mag,
    fmaximum_mag_num,
    fmaximum_num,
    fmin,
    fminimum,
    fminimum_mag,
    fminimum_mag_num,
    fminimum_num,
    fmod,
    fmul,
    frexp,
    fromfp,
    fromfpx,
    fsqrt,
    fsub,
    getPayload,
    hypot,
    ilogb,
    ldexp,
    lgamma,
    llogb,
    llrint,
    llround,
    log,
    log10,
    log10p1,
    log1p,
    log2,
    log2p1,
    logb,
    logp1,
    lrint,
    lround,
    modf,
    nan,
    nearbyint,
    nextAfter,
    nextDown,
    nextToward,
    nextUp,
    pow,
    pown,
    powr,
    remainder,
    remquo,
    rint,
    rootn,
    round,
    roundeven,
    rsqrt,
    scalbln,
    scalbn,
    setPayload,
    setPayloadSig,
    sin,
    sinh,
    sinpi,
    sqrt,
    tan,
    tanh,
    tanpi,
    tgamma,
    totalOrder,
    totalOrderMag,
    trunc,
    ufromfp,
    ufromfpx,
};

pub const Format = enum(u8) {
    h,
    f,
    d,

    pub fn oracleDescriptor(format: Format) OracleFormatDescriptor {
        return switch (format) {
            .h => .{ .code = .h, .storage_bits = 16, .exponent_bits = 5, .fraction_bits = 10, .reserved = 0 },
            .f => .{ .code = .f, .storage_bits = 32, .exponent_bits = 8, .fraction_bits = 23, .reserved = 0 },
            .d => .{ .code = .d, .storage_bits = 64, .exponent_bits = 11, .fraction_bits = 52, .reserved = 0 },
        };
    }

    pub fn bitWidth(format: Format) usize {
        return switch (format) {
            .h => 16,
            .f => 32,
            .d => 64,
        };
    }

    pub fn hexadecimalDigits(format: Format) usize {
        return switch (format) {
            .h => 4,
            .f => 8,
            .d => 16,
        };
    }
};

pub const FunctionStatus = enum(u8) {
    unsupported,
    correct,
    bounded,
};

pub const Oracle = enum(u8) {
    none,
    exact_bits,
    algebraic,
    mpfr_arb,
};

pub const Provenance = enum(u8) {
    zmath,
    core_math,
    zmath_core_math,
};

pub const OutputClass = enum {
    normal,
    subnormal,
    zero,
    infinity,
    qnan,
    snan,
};

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

    pub fn isSigned(integer_type: IntegerType) bool {
        return switch (integer_type) {
            .i2, .i8, .i16, .i32, .i64 => true,
            .u8, .u16, .u32, .u64 => false,
        };
    }

    pub fn bitWidth(integer_type: IntegerType) u16 {
        return switch (integer_type) {
            .i2 => 2,
            .i8, .u8 => 8,
            .i16, .u16 => 16,
            .i32, .u32 => 32,
            .i64, .u64 => 64,
        };
    }

    pub fn oracleValueBits(integer_type: IntegerType) u32 {
        return integer_type.bitWidth();
    }

    pub fn oracleDescriptor(integer_type: IntegerType) OracleFieldDescriptor {
        return .{
            .kind = if (integer_type.isSigned()) .signed_integer else .unsigned_integer,
            .value_bits = integer_type.bitWidth(),
            .format = .{ .code = .none, .storage_bits = 0, .exponent_bits = 0, .fraction_bits = 0, .reserved = 0 },
            .reserved = 0,
        };
    }
};

pub const StructureKind = enum(u8) {
    atan2,
    canonicalize,
    frexp,
    integer,
    lgamma,
    modf,
    payload,
    power,
    remquo,

    pub fn oracleCode(kind: StructureKind) u8 {
        return switch (kind) {
            .canonicalize => 1,
            .frexp => 2,
            .modf => 3,
            .remquo => 4,
            .lgamma => 5,
            .payload => 6,
            .atan2 => 7,
            .power => 8,
            .integer => 9,
        };
    }
};

pub const InputDescriptor = union(enum) {
    float: Format,
    integer: IntegerType,
    tag,
    fromfp_round,

    pub fn floatFormat(descriptor: InputDescriptor) ?Format {
        return switch (descriptor) {
            .float => |format| format,
            .integer, .tag, .fromfp_round => null,
        };
    }

    pub fn oracleDescriptor(descriptor: InputDescriptor) OracleFieldDescriptor {
        return switch (descriptor) {
            .float => |format| .{
                .kind = .float,
                .value_bits = @intCast(format.bitWidth()),
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

pub const InputList = struct {
    descriptors: [input_count_max]InputDescriptor = .{ .tag, .tag, .tag },
    count: u8 = 0,
};

pub const StructureDescriptor = struct {
    kind: StructureKind,
    format: Format,
};

fn oracleBooleanFieldDescriptor() OracleFieldDescriptor {
    return .{
        .kind = .boolean,
        .value_bits = 1,
        .format = .{ .code = .none, .storage_bits = 0, .exponent_bits = 0, .fraction_bits = 0, .reserved = 0 },
        .reserved = 0,
    };
}

fn formatOracleFieldDescriptor(format: Format) OracleFieldDescriptor {
    return .{
        .kind = .float,
        .value_bits = @intCast(format.bitWidth()),
        .format = format.oracleDescriptor(),
        .reserved = 0,
    };
}

pub const ResultDescriptor = union(enum) {
    float: Format,
    integer: IntegerType,
    boolean,
    structure: StructureDescriptor,

    pub fn floatFormat(descriptor: ResultDescriptor) ?Format {
        return switch (descriptor) {
            .float => |format| format,
            .structure => |structure| structure.format,
            .integer, .boolean => null,
        };
    }

    pub fn oracleLayout(descriptor: ResultDescriptor) OracleResultLayout {
        return switch (descriptor) {
            .structure => .structure,
            else => .scalar,
        };
    }

    pub fn oracleStructureKind(descriptor: ResultDescriptor) OracleStructureKind {
        return switch (descriptor) {
            .structure => |structure| @enumFromInt(structure.kind.oracleCode()),
            else => .none,
        };
    }

    pub fn oracleFieldCount(descriptor: ResultDescriptor) usize {
        return switch (descriptor) {
            .float, .integer, .boolean => 1,
            .structure => 2,
        };
    }

    pub fn oracleFieldDescriptor(descriptor: ResultDescriptor, index: usize) ?OracleFieldDescriptor {
        return switch (descriptor) {
            .float => |format| if (index == 0) formatOracleFieldDescriptor(format) else null,
            .integer => |integer_type| if (index == 0) integer_type.oracleDescriptor() else null,
            .boolean => if (index == 0) oracleBooleanFieldDescriptor() else null,
            .structure => |structure| {
                const float_descriptor = formatOracleFieldDescriptor(structure.format);
                switch (structure.kind) {
                    .canonicalize, .payload, .atan2, .power => {
                        if (index == 0) return float_descriptor;
                        if (index == 1) return oracleBooleanFieldDescriptor();
                    },
                    .frexp, .remquo => {
                        if (index == 0) return float_descriptor;
                        if (index == 1) return IntegerType.i32.oracleDescriptor();
                    },
                    .modf => if (index == 0 or index == 1) return float_descriptor,
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

pub const ProvenanceList = struct {
    values: [max_provenance_count]Provenance = @splat(.zmath),
    count: u8 = 0,

    pub const empty: ProvenanceList = .{};

    pub fn slice(list: *const ProvenanceList) []const Provenance {
        return list.values[0..list.count];
    }

    pub fn contains(list: *const ProvenanceList, provenance: Provenance) bool {
        for (list.slice()) |item| if (item == provenance) return true;
        return false;
    }
};

pub const ArgumentList = struct {
    descriptors: [max_argument_count]InputDescriptor = .{
        .tag, .tag, .tag, .tag, .tag, .tag, .tag, .tag,
    },
    count: u8 = 0,

    pub fn slice(list: *const ArgumentList) []const InputDescriptor {
        return list.descriptors[0..list.count];
    }
};

pub const Function = struct {
    op: []const u8,
    provenance: ProvenanceList,
    status: FunctionStatus,
    arity: u8,
    inputs: ArgumentList,
    result: ResultDescriptor,
    oracle: Oracle,
    special_policy: []const u8,
    max_ulp: u64,

    pub fn arguments(function: *const Function) []const InputDescriptor {
        return function.inputs.slice();
    }
};

pub const FunctionIterator = struct {
    manifest: *const Manifest,
    index: usize = 0,

    pub fn next(iterator: *FunctionIterator) ValidationError!?Function {
        if (iterator.index == iterator.manifest.function_count) return null;
        if (iterator.index > iterator.manifest.function_count) return error.MissingFunctionRow;
        const value = iterator.manifest.function_values[iterator.index];
        iterator.index += 1;
        return value;
    }
};

const ManifestBuilder = struct {
    seen: [function_key_count]bool = @splat(false),
    next_key: usize = 0,
    operation: ?ManifestOperation = null,
    provenance: ?Provenance = null,
    provenance_values: ProvenanceList = .empty,
    status: ?FunctionStatus = null,
    arity: ?u8 = null,
    inputs: ?InputList = null,
    result: ?ResultDescriptor = null,
    oracle: ?Oracle = null,
    max_ulp: ?u64 = null,
};

const FunctionDescriptor = struct {
    operation: ManifestOperation,
    provenance: Provenance,
    format: Format,
    arity: u8,
    inputs: InputList,
    result: ResultDescriptor,
};

pub const Manifest = struct {
    function_values: [function_count_max]Function = undefined,
    function_count: usize = 0,

    pub fn functionCount(manifest: *const Manifest) usize {
        return manifest.function_count;
    }

    pub fn functions(manifest: *const Manifest) FunctionIterator {
        return .{ .manifest = manifest };
    }

    pub fn functionStatus(
        manifest: *const Manifest,
        operation: Operation,
        format: Format,
    ) ?FunctionStatus {
        const function = manifest.findFunction(operation, format) orelse return null;
        return function.status;
    }

    fn findFunction(
        manifest: *const Manifest,
        operation: Operation,
        format: Format,
    ) ?*const Function {
        const name = @tagName(operation);
        var match: ?*const Function = null;
        for (manifest.function_values[0..manifest.function_count]) |*function| {
            if (!std.mem.eql(u8, function.op, name)) continue;
            if (functionFormat(function.*) != format) continue;
            if (match != null) return null;
            match = function;
        }
        return match;
    }
};

pub const FromFpRound = enum {
    nearest_even,
    nearest_from_zero,
    toward_zero,
    toward_positive,
    toward_negative,
};

pub fn DescriptorList(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        values: [capacity]T = undefined,
        count: usize = 0,
        pub const empty: Self = .{ .values = undefined, .count = 0 };
        pub fn slice(self: *const Self) []const T {
            return self.values[0..self.count];
        }
    };
}

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
    argument: InputDescriptor,
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
            if (class_code != .normal and class_code != .subnormal and class_code != .zero and
                class_code != .infinity and class_code != .qnan and class_code != .snan)
            {
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
    snan = 6,
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
            if (provenance == .zmath_core_math) return error.InvalidProvenance;
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
    ArgumentLimit,
    DuplicateProvenance,
    UnsortedProvenance,
    UnknownIntegerType,
    UnknownProvenance,
    InvalidOperationName,
};

const CorpusReader = struct {
    source: []const u8,
    index: usize = 0,

    fn take(self: *CorpusReader, count: usize) CorpusRecordError![]const u8 {
        if (count > self.source.len -| self.index) return error.TruncatedRecord;
        const result = self.source[self.index .. self.index + count];
        self.index += count;
        return result;
    }

    fn readU8(self: *CorpusReader) CorpusRecordError!u8 {
        return (try self.take(1))[0];
    }

    fn readU16(self: *CorpusReader) CorpusRecordError!u16 {
        const bytes = try self.take(2);
        return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
    }

    fn readU32(self: *CorpusReader) CorpusRecordError!u32 {
        const bytes = try self.take(4);
        return @as(u32, bytes[0]) |
            (@as(u32, bytes[1]) << 8) |
            (@as(u32, bytes[2]) << 16) |
            (@as(u32, bytes[3]) << 24);
    }

    fn readU64(self: *CorpusReader) CorpusRecordError!u64 {
        const bytes = try self.take(8);
        var result: u64 = 0;
        for (bytes, 0..) |byte, shift| result |= @as(u64, byte) << @intCast(shift * 8);
        return result;
    }
};

const CorpusWriter = struct {
    target: []u8,
    index: usize = 0,

    fn ensure(self: *CorpusWriter, count: usize) CorpusRecordError!void {
        if (count > self.target.len -| self.index) return error.OutputTooSmall;
    }

    fn bytes(self: *CorpusWriter, source: []const u8) CorpusRecordError!void {
        try self.ensure(source.len);
        @memcpy(self.target[self.index .. self.index + source.len], source);
        self.index += source.len;
    }

    fn writeU8(self: *CorpusWriter, value: u8) CorpusRecordError!void {
        try self.ensure(1);
        self.target[self.index] = value;
        self.index += 1;
    }

    fn writeU16(self: *CorpusWriter, value: u16) CorpusRecordError!void {
        try self.ensure(2);
        self.target[self.index] = @intCast(value & 0xff);
        self.target[self.index + 1] = @intCast(value >> 8);
        self.index += 2;
    }

    fn writeU32(self: *CorpusWriter, value: u32) CorpusRecordError!void {
        try self.ensure(4);
        for (0..4) |shift| {
            self.target[self.index + shift] = @intCast((value >> @intCast(shift * 8)) & 0xff);
        }
        self.index += 4;
    }

    fn writeU64(self: *CorpusWriter, value: u64) CorpusRecordError!void {
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
        0 => .zmath,
        1 => .core_math,
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
        6 => .snan,
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

fn corpusStructureCode(kind: StructureKind) u8 {
    return switch (kind) {
        .canonicalize => 0,
        .frexp => 1,
        .modf => 2,
        .remquo => 3,
        .lgamma => 4,
        .payload => 5,
        .atan2 => 6,
        .power => 7,
        .integer => 8,
    };
}
fn parseCorpusStructure(code: u8) CorpusRecordError!StructureKind {
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
    if (fraction == 0) return .infinity;
    const quiet_mask: u64 = switch (format) {
        .h => 0x0200,
        .f => 0x0040_0000,
        .d => 0x0008_0000_0000_0000,
    };
    return if ((fraction & quiet_mask) == 0) .snan else .qnan;
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
    var writer: CorpusWriter = .{ .target = target[0..length] };
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

// Read one frame into caller-owned storage; decode the returned bytes separately.
pub fn readEncodedRecord(
    reader: *std.Io.Reader,
    scratch: []u8,
) (CorpusRecordError || error{ReadFailed})!?[]const u8 {
    if (scratch.len < descriptor_record_header_length) return error.OutputTooSmall;
    if (try reader.readSliceShort(scratch[0..1]) == 0) return null;
    if (try reader.readSliceShort(scratch[1..9]) != 8) return error.TruncatedRecord;
    const length = std.mem.readInt(u32, scratch[5..9], .little);
    if (length < descriptor_record_header_length) return error.InvalidRecordLength;
    if (length > scratch.len) return error.OutputTooSmall;
    if (try reader.readSliceShort(scratch[9..length]) != length - 9) {
        return error.TruncatedRecord;
    }
    return scratch[0..length];
}

pub fn decodeCorpusRecord(source: []const u8) CorpusRecordError!CorpusRecord {
    if (source.len < descriptor_record_header_length) return error.TruncatedRecord;
    if (!std.mem.eql(u8, source[0..4], "ZCDR")) return error.InvalidRecordMagic;
    if (source[4] != descriptor_corpus_codec_version) return error.UnknownRecordVersion;
    var reader: CorpusReader = .{ .source = source };
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

fn compareProvenance(previous: ProvenanceList, current: ProvenanceList) std.math.Order {
    const common = @min(previous.count, current.count);
    for (previous.values[0..common], current.values[0..common]) |left, right| {
        const order = std.math.order(@intFromEnum(left), @intFromEnum(right));
        if (order != .eq) return order;
    }
    return std.math.order(previous.count, current.count);
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

    pub fn next(self: *CorpusRecordIterator) CorpusRecordError!?CorpusRecord {
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

pub const TargetMode = struct {
    target: []const u8,
    cpu: []const u8,
    mode: []const u8,

    pub fn eql(left: TargetMode, right: TargetMode) bool {
        return std.mem.eql(u8, left.target, right.target) and
            std.mem.eql(u8, left.cpu, right.cpu) and
            std.mem.eql(u8, left.mode, right.mode);
    }

    fn valid(target_mode: TargetMode) bool {
        return validMetadataComponent(target_mode.target) and
            validMetadataComponent(target_mode.cpu) and
            validMetadataComponent(target_mode.mode);
    }
};

pub const ArtifactMetadata = struct {
    artifact_name: []const u8,
    target_mode: TargetMode,
    required_row_count: usize,
};

pub const EmbeddedArtifact = struct {
    source: []const u8,
    metadata: ?ArtifactMetadata,
};

pub const CorpusRow = struct {
    operation: Operation,
    format: Format,
    input_bits: u64,
    output_bits: u64,
    output_class: OutputClass,
    max_ulp: u64,
};

pub const Artifact = struct {
    source: []const u8,
    metadata: ArtifactMetadata,
    function: Function,
    operation: Operation,
    format: Format,

    pub fn rows(artifact: Artifact) ValidationError!RowIterator {
        return RowIterator.init(artifact.source);
    }
};

const SortKey = struct {
    operation: Operation,
    format: Format,
    input_bits: u64,
};

pub const RowIterator = struct {
    remaining: []const u8,
    previous: ?SortKey = null,

    fn init(source: []const u8) ValidationError!RowIterator {
        try validateTextEnvelope(source, true);
        const header_end = std.mem.indexOfScalar(u8, source, '\n') orelse
            return error.InvalidHeader;
        if (!std.mem.eql(
            u8,
            source[0..header_end],
            "op\tformat\tinput_bits\toutput_bits\toutput_class\tmax_ulp",
        )) return error.InvalidHeader;

        return .{ .remaining = source[header_end + 1 ..] };
    }

    pub fn next(iterator: *RowIterator) ValidationError!?CorpusRow {
        if (iterator.remaining.len == 0) return null;
        const line_end = std.mem.indexOfScalar(u8, iterator.remaining, '\n') orelse
            return error.MissingFinalNewline;
        const line = iterator.remaining[0..line_end];
        iterator.remaining = iterator.remaining[line_end + 1 ..];
        if (line.len == 0) return error.BlankCorpusLine;

        const row = try parseCorpusRow(line);
        const current: SortKey = .{
            .operation = row.operation,
            .format = row.format,
            .input_bits = row.input_bits,
        };
        if (iterator.previous) |previous| try validateSorted(previous, current);
        iterator.previous = current;
        return row;
    }
};

const NarrowingSignature = struct {
    source: Format,
    destination: Format,
    arity: u8,
};

fn narrowingSignature(operation: ManifestOperation) ?NarrowingSignature {
    return switch (operation) {
        .f16addf32, .f16subf32, .f16mulf32, .f16divf32 => .{ .source = .f, .destination = .h, .arity = 2 },
        .f16fmaf32 => .{ .source = .f, .destination = .h, .arity = 3 },
        .f16sqrtf32 => .{ .source = .f, .destination = .h, .arity = 1 },
        .f16addf64, .f16subf64, .f16mulf64, .f16divf64 => .{ .source = .d, .destination = .h, .arity = 2 },
        .f16fmaf64 => .{ .source = .d, .destination = .h, .arity = 3 },
        .f16sqrtf64 => .{ .source = .d, .destination = .h, .arity = 1 },
        .fadd, .fsub, .fmul, .fdiv, .f32addf64, .f32subf64, .f32mulf64, .f32divf64 => .{
            .source = .d,
            .destination = .f,
            .arity = 2,
        },
        .ffma, .f32fmaf64 => .{ .source = .d, .destination = .f, .arity = 3 },
        .fsqrt, .f32sqrtf64 => .{ .source = .d, .destination = .f, .arity = 1 },
        else => null,
    };
}

const SignatureShape = enum {
    unary_float,
    unary_canonicalize,
    power,
    binary_float,
    ternary_float,
    fromfp,
    unary_frexp,
    unary_integer_i32_result,
    unary_integer_i64_result,
    binary_integer_i32,
    binary_integer_i64,
    unary_integer_result,
    unary_modf,
    unary_payload,
    binary_remquo,
    unary_tag,
    binary_next_toward,
    binary_boolean,
    binary_atan2,
    unary_lgamma,
};

const canonical_function_descriptors: [canonical_function_count]FunctionDescriptor =
    buildCanonicalFunctionDescriptors();

fn buildCanonicalFunctionDescriptors() [canonical_function_count]FunctionDescriptor {
    // Bound: 16 backward branches for each of the 315 canonical rows.
    @setEvalBranchQuota(@intCast(canonical_function_count * 16));
    var descriptors: [canonical_function_count]FunctionDescriptor = undefined;
    var count: usize = 0;
    inline for (.{ Provenance.zmath, Provenance.zmath_core_math }) |provenance| {
        const core_math = provenance == .zmath_core_math;
        inline for (std.meta.tags(ManifestOperation)) |operation| {
            if (isCoreMathOperation(operation) != core_math) continue;
            if (narrowingSignature(operation)) |signature| {
                descriptors[count] = .{
                    .operation = operation,
                    .provenance = provenance,
                    .format = signature.destination,
                    .arity = signature.arity,
                    .inputs = floatInputs(signature.source, signature.arity),
                    .result = .{ .float = signature.destination },
                };
                count += 1;
            } else {
                inline for (.{ Format.h, Format.f, Format.d }) |format| {
                    descriptors[count] = standardDescriptor(operation, provenance, format);
                    count += 1;
                }
            }
        }
    }
    comptime {
        if (count != canonical_function_count) {
            @compileError("canonical descriptor inventory is not 315 rows");
        }
    }
    return descriptors;
}

fn standardDescriptor(
    operation: ManifestOperation,
    provenance: Provenance,
    format: Format,
) FunctionDescriptor {
    const shape = signatureShape(operation) orelse
        @compileError("ordinary operation has no exact signature");
    return switch (shape) {
        .unary_float => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 1,
            .inputs = floatInputs(format, 1),
            .result = .{ .float = format },
        },
        .unary_canonicalize => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 1,
            .inputs = floatInputs(format, 1),
            .result = .{ .structure = .{ .kind = .canonicalize, .format = format } },
        },
        .power => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 2,
            .inputs = .{
                .descriptors = .{ .{ .float = format }, .{ .integer = .i64 }, .tag },
                .count = 2,
            },
            .result = .{ .structure = .{ .kind = .power, .format = format } },
        },
        .binary_float => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 2,
            .inputs = .{
                .descriptors = .{ .{ .float = format }, .{ .float = format }, .tag },
                .count = 2,
            },
            .result = .{ .float = format },
        },
        .ternary_float => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 3,
            .inputs = .{
                .descriptors = .{
                    .{ .float = format },
                    .{ .float = format },
                    .{ .float = format },
                },
                .count = 3,
            },
            .result = .{ .float = format },
        },
        .fromfp => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 3,
            .inputs = .{
                .descriptors = .{
                    .{ .float = format },
                    .fromfp_round,
                    .{ .integer = .u32 },
                },
                .count = 3,
            },
            .result = .{ .float = format },
        },
        .unary_frexp => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 1,
            .inputs = floatInputs(format, 1),
            .result = .{ .structure = .{ .kind = .frexp, .format = format } },
        },
        .unary_integer_i32_result => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 1,
            .inputs = floatInputs(format, 1),
            .result = .{ .integer = .i32 },
        },
        .unary_integer_i64_result => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 1,
            .inputs = floatInputs(format, 1),
            .result = .{ .integer = .i64 },
        },
        .binary_integer_i32 => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 2,
            .inputs = .{
                .descriptors = .{ .{ .float = format }, .{ .integer = .i32 }, .tag },
                .count = 2,
            },
            .result = .{ .float = format },
        },
        .binary_integer_i64 => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 2,
            .inputs = .{
                .descriptors = .{ .{ .float = format }, .{ .integer = .i64 }, .tag },
                .count = 2,
            },
            .result = .{ .float = format },
        },
        .unary_integer_result => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 1,
            .inputs = floatInputs(format, 1),
            .result = .{ .structure = .{ .kind = .integer, .format = format } },
        },
        .unary_modf => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 1,
            .inputs = floatInputs(format, 1),
            .result = .{ .structure = .{ .kind = .modf, .format = format } },
        },
        .unary_payload => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 1,
            .inputs = floatInputs(format, 1),
            .result = .{ .structure = .{ .kind = .payload, .format = format } },
        },
        .binary_remquo => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 2,
            .inputs = .{
                .descriptors = .{ .{ .float = format }, .{ .float = format }, .tag },
                .count = 2,
            },
            .result = .{ .structure = .{ .kind = .remquo, .format = format } },
        },
        .unary_tag => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 1,
            .inputs = .{ .descriptors = .{ .tag, .tag, .tag }, .count = 1 },
            .result = .{ .float = format },
        },
        .binary_next_toward => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 2,
            .inputs = .{
                .descriptors = .{ .{ .float = format }, .{ .float = .d }, .tag },
                .count = 2,
            },
            .result = .{ .float = format },
        },
        .binary_boolean => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 2,
            .inputs = .{
                .descriptors = .{ .{ .float = format }, .{ .float = format }, .tag },
                .count = 2,
            },
            .result = .boolean,
        },
        .binary_atan2 => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 2,
            .inputs = .{
                .descriptors = .{ .{ .float = format }, .{ .float = format }, .tag },
                .count = 2,
            },
            .result = .{ .structure = .{ .kind = .atan2, .format = format } },
        },
        .unary_lgamma => .{
            .operation = operation,
            .provenance = provenance,
            .format = format,
            .arity = 1,
            .inputs = floatInputs(format, 1),
            .result = .{ .structure = .{ .kind = .lgamma, .format = format } },
        },
    };
}

fn floatInputs(format: Format, arity: u8) InputList {
    var inputs: InputList = .{};
    var index: u8 = 0;
    while (index < arity) : (index += 1) {
        inputs.descriptors[index] = .{ .float = format };
    }
    inputs.count = arity;
    return inputs;
}

fn isCoreMathOperation(operation: ManifestOperation) bool {
    return switch (operation) {
        .acospi, .asinpi, .atan2, .atan2pi, .atanpi, .cospi, .erfc, .lgamma, .log10p1, .log2p1, .pow, .tgamma => true,
        else => false,
    };
}

fn signatureShape(operation: ManifestOperation) ?SignatureShape {
    return switch (operation) {
        // ziglint-ignore: Z024
        .abs, .acos, .acosh, .asin, .asinh, .atan, .atanh, .cbrt, .ceil, .cos, .cosh, .erf, .exp, .exp10, .exp10m1, .exp2, .exp2m1, .expm1, .floor, .getPayload, .log, .log10, .log1p, .log2, .logb, .logp1, .nearbyint, .nextDown, .nextUp, .rint, .round, .roundeven, .rsqrt, .sin, .sinh, .sinpi, .sqrt, .tan, .tanh, .tanpi, .trunc, .acospi, .asinpi, .atanpi, .cospi, .erfc, .log10p1, .log2p1, .tgamma => .unary_float,
        .canonicalize => .unary_canonicalize,
        .compoundn, .pown, .rootn => .power,
        // ziglint-ignore: Z024
        .copySign, .fdim, .fmax, .fmaximum, .fmaximum_mag, .fmaximum_mag_num, .fmaximum_num, .fmin, .fminimum, .fminimum_mag, .fminimum_mag_num, .fminimum_num, .fmod, .hypot, .nextAfter, .powr, .remainder, .pow => .binary_float,
        .fma => .ternary_float,
        .frexp => .unary_frexp,
        .fromfp, .fromfpx, .ufromfp, .ufromfpx => .fromfp,
        .ilogb => .unary_integer_i32_result,
        .ldexp, .scalbn => .binary_integer_i32,
        .llogb => .unary_integer_i64_result,
        .llrint, .llround, .lrint, .lround => .unary_integer_result,
        .modf => .unary_modf,
        .nan => .unary_tag,
        .nextToward => .binary_next_toward,
        .remquo => .binary_remquo,
        .scalbln => .binary_integer_i64,
        .setPayload, .setPayloadSig => .unary_payload,
        .totalOrder, .totalOrderMag => .binary_boolean,
        .atan2, .atan2pi => .binary_atan2,
        .lgamma => .unary_lgamma,
        // ziglint-ignore: Z024
        .fadd, .fdiv, .ffma, .fmul, .fsqrt, .fsub, .f16addf32, .f16addf64, .f16divf32, .f16divf64, .f16fmaf32, .f16fmaf64, .f16mulf32, .f16mulf64, .f16sqrtf32, .f16sqrtf64, .f16subf32, .f16subf64, .f32addf64, .f32divf64, .f32fmaf64, .f32mulf64, .f32sqrtf64, .f32subf64 => null,
    };
}

pub fn parseEmbeddedManifest() ValidationError!Manifest {
    return parseManifest(manifest_text);
}

pub fn validateEmbeddedManifest() ValidationError!void {
    _ = try parseEmbeddedManifest();
}

pub fn validateManifest(source: []const u8) ValidationError!void {
    _ = try parseManifest(source);
}

pub fn parseManifest(source: []const u8) ValidationError!Manifest {
    if (source.len > manifest_bytes_max) return error.ManifestTooLarge;
    try validateTextEnvelope(source, false);

    var root_seen: [14]bool = @splat(false);
    var function: ?ManifestBuilder = null;
    var function_count: usize = 0;
    var function_values: [function_count_max]Function = undefined;
    var previous_function: ?Function = null;
    var root_complete = false;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        if (raw_line.len > manifest_line_bytes_max) return error.ManifestTooLarge;
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.eql(u8, line, "[[function]]")) {
            if (!root_complete) {
                try requireAllRootKeys(root_seen);
                root_complete = true;
            }
            if (function) |current| {
                try appendFunction(
                    &function_values,
                    &function_count,
                    &previous_function,
                    current,
                );
            }
            function = .{};
            continue;
        }
        if (line[0] == '[') return error.UnknownSection;

        const equal_index = std.mem.indexOfScalar(u8, line, '=') orelse
            return error.MalformedLine;
        const key = std.mem.trim(u8, line[0..equal_index], " \t");
        const value = std.mem.trim(u8, line[equal_index + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return error.MalformedLine;

        if (function) |*current| {
            if (isRootOnlyKey(key)) return error.RootKeyAfterFunction;
            try validateFunctionField(current, key, value);
        } else {
            if (root_complete) return error.RootKeyAfterFunction;
            try validateRootField(&root_seen, key, value);
        }
    }
    if (!root_complete) try requireAllRootKeys(root_seen);
    if (function) |current| {
        try appendFunction(
            &function_values,
            &function_count,
            &previous_function,
            current,
        );
    }
    if (function_count != canonical_function_count) return error.MissingFunctionRow;

    return .{
        .function_values = function_values,
        .function_count = function_count,
    };
}

pub fn validateTsv(source: []const u8) ValidationError!void {
    try validateTextEnvelope(source, true);

    const body = source[0 .. source.len - 1];
    var lines = std.mem.splitScalar(u8, body, '\n');
    const header = lines.next() orelse return error.InvalidHeader;
    if (!std.mem.eql(
        u8,
        header,
        "op\tformat\tinput_bits\toutput_bits\toutput_class\tmax_ulp",
    )) return error.InvalidHeader;

    var previous: ?SortKey = null;
    while (lines.next()) |line| {
        if (line.len == 0) return error.BlankCorpusLine;
        const row = try parseCorpusRow(line);
        const current: SortKey = .{
            .operation = row.operation,
            .format = row.format,
            .input_bits = row.input_bits,
        };
        if (previous) |prior| try validateSorted(prior, current);
        previous = current;
    }
}

// This loader validates the six historical scalar TSV artifacts only.
// Typed corpus publication and replay cover every descriptor independently.
pub fn loadArtifact(
    manifest: *const Manifest,
    source: []const u8,
    metadata: ?ArtifactMetadata,
    active_target_mode: ?TargetMode,
) ValidationError!Artifact {
    const artifact_metadata = metadata orelse return error.MissingArtifactMetadata;
    const active_mode = active_target_mode orelse return error.MissingArtifactMetadata;
    if (!artifact_metadata.target_mode.valid() or !active_mode.valid()) {
        return error.UnsupportedTargetMode;
    }
    if (!artifact_metadata.target_mode.eql(active_mode)) {
        return error.UnsupportedTargetMode;
    }

    const artifact_identity = parseLegacyArtifactName(artifact_metadata.artifact_name) orelse
        return error.InvalidArtifactName;
    const expected_row_count = expectedLegacyArtifactRowCount(artifact_identity) orelse
        return error.UnsupportedArtifact;
    if (artifact_metadata.required_row_count != expected_row_count) {
        return error.ArtifactRowCountMismatch;
    }
    const function = try findLegacyArtifactFunction(
        manifest,
        artifact_identity.operation,
        artifact_identity.format,
    );
    if (function.status == .unsupported) return error.UnsupportedArtifact;

    var iterator = try RowIterator.init(source);
    var row_count: usize = 0;
    var expected_h_input: u64 = 0;
    while (try iterator.next()) |row| {
        if (row.operation != artifact_identity.operation) {
            return error.ArtifactOperationMismatch;
        }
        if (row.format != artifact_identity.format) {
            return error.ArtifactFormatMismatch;
        }
        if (artifact_identity.format == .h) {
            if (row.input_bits != expected_h_input) {
                return error.IncompleteUnaryHDomain;
            }
            expected_h_input += 1;
        }
        const expected_max_ulp = if (isSpecial(row.output_class))
            0
        else
            function.max_ulp;
        if (row.max_ulp != expected_max_ulp) {
            return error.ArtifactMaxUlpMismatch;
        }
        row_count += 1;
    }
    if (row_count != artifact_metadata.required_row_count or
        row_count != expected_row_count)
    {
        return error.ArtifactRowCountMismatch;
    }
    if (artifact_identity.format == .h and expected_h_input != 1 << 16) {
        return error.IncompleteUnaryHDomain;
    }

    return .{
        .source = source,
        .metadata = artifact_metadata,
        .function = function.*,
        .operation = artifact_identity.operation,
        .format = artifact_identity.format,
    };
}

fn expectedLegacyArtifactRowCount(identity: ArtifactIdentity) ?usize {
    return switch (identity.operation) {
        .exp => switch (identity.format) {
            .h => 65_536,
            .f => 29,
            .d => 182,
        },
        .log => switch (identity.format) {
            .h => 65_536,
            .f => 64,
            .d => null,
        },
        .sin => switch (identity.format) {
            .h => 65_536,
            .f, .d => null,
        },
    };
}

pub fn loadEmbeddedArtifact(
    manifest: *const Manifest,
    embedded: EmbeddedArtifact,
    active_target_mode: ?TargetMode,
) ValidationError!Artifact {
    return loadArtifact(manifest, embedded.source, embedded.metadata, active_target_mode);
}

const ArtifactIdentity = struct {
    operation: Operation,
    format: Format,
};

fn findLegacyArtifactFunction(
    manifest: *const Manifest,
    operation: Operation,
    format: Format,
) ValidationError!*const Function {
    const function = manifest.findFunction(operation, format) orelse
        return error.MissingArtifactManifestRow;
    return function;
}

fn parseLegacyArtifactName(name: []const u8) ?ArtifactIdentity {
    const basename = if (std.mem.startsWith(u8, name, "test/corpus/"))
        name["test/corpus/".len..]
    else
        name;
    const operation_names = .{ "exp", "log", "sin" };
    const operations = .{ Operation.exp, Operation.log, Operation.sin };
    const format_names = .{ "_h.tsv", "_f.tsv", "_d.tsv" };
    const formats = .{ Format.h, Format.f, Format.d };
    inline for (operation_names, operations) |operation_name, operation| {
        inline for (format_names, formats) |format_name, format| {
            var expected: [16]u8 = undefined;
            const expected_name = std.fmt.bufPrint(&expected, "{s}{s}", .{
                operation_name,
                format_name,
            }) catch unreachable;
            if (std.mem.eql(u8, basename, expected_name)) {
                return .{ .operation = operation, .format = format };
            }
        }
    }
    return null;
}

fn validMetadataComponent(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |character| {
        const alpha_numeric =
            (character >= 'a' and character <= 'z') or
            (character >= 'A' and character <= 'Z') or
            (character >= '0' and character <= '9');
        if (!alpha_numeric and character != '_' and character != '-' and
            character != '.' and character != '+')
        {
            return false;
        }
    }
    return true;
}

fn parseCorpusRow(line: []const u8) ValidationError!CorpusRow {
    var fields: [6][]const u8 = undefined;
    var field_count: usize = 0;
    var field_iterator = std.mem.splitScalar(u8, line, '\t');
    while (field_iterator.next()) |field| {
        if (field_count == fields.len) return error.WrongColumnCount;
        fields[field_count] = field;
        field_count += 1;
    }
    if (field_count != fields.len) return error.WrongColumnCount;

    const operation = try parseCorpusOperation(fields[0]);
    const format = try parseFormat(fields[1]);
    try validateHexBits(fields[2], format);
    try validateHexBits(fields[3], format);
    const declared_output_class = try parseOutputClass(fields[4]);
    const derived_output_class = try deriveOutputClass(fields[3], format);
    if (declared_output_class != derived_output_class) return error.OutputClassMismatch;
    try validateMaxUlp(fields[5]);
    if (isSpecial(derived_output_class) and !std.mem.eql(u8, fields[5], "0")) {
        return error.InvalidMaxUlp;
    }

    const input_bits = std.fmt.parseUnsigned(u64, fields[2], 16) catch
        return error.InvalidHexDigit;
    const output_bits = std.fmt.parseUnsigned(u64, fields[3], 16) catch
        return error.InvalidHexDigit;
    const max_ulp = parseCanonicalUnsigned(fields[5]) orelse return error.InvalidMaxUlp;
    return .{
        .operation = operation,
        .format = format,
        .input_bits = input_bits,
        .output_bits = output_bits,
        .output_class = declared_output_class,
        .max_ulp = max_ulp,
    };
}

fn validateTextEnvelope(source: []const u8, require_final_newline: bool) ValidationError!void {
    if (std.mem.startsWith(u8, source, "\xef\xbb\xbf")) return error.ByteOrderMark;
    if (std.mem.indexOfScalar(u8, source, '\r') != null) return error.CarriageReturn;
    if (require_final_newline) {
        if (source.len == 0) return error.MissingFinalNewline;
        if (source[source.len - 1] != '\n') return error.MissingFinalNewline;
    }
}

fn validateRootField(
    root_seen: *[14]bool,
    name: []const u8,
    value: []const u8,
) ValidationError!void {
    const key = parseRootKey(name) orelse return error.UnknownRootKey;
    const key_index: usize = @intFromEnum(key);
    if (root_seen[key_index]) return error.DuplicateRootKey;
    root_seen[key_index] = true;

    switch (key) {
        .schema_version => try expectUnsigned(value, 3),
        .core_math_repository => try expectString(
            value,
            "https://gitlab.inria.fr/core-math/core-math.git",
        ),
        .core_math_revision => {
            const revision = try parseString(value);
            if (!std.mem.eql(
                u8,
                revision,
                "3bafed75e3c22399531857d63a3fa0e24bfb42fa",
            )) return error.InvalidPinnedValue;
            if (revision.len != 40) return error.InvalidPinnedValue;
            for (revision) |digit| {
                if (!isLowerHexDigit(digit)) return error.InvalidPinnedValue;
            }
        },
        .mpfr_precision_bits, .arb_precision_bits => try expectUnsigned(value, 512),
        .rounding => try expectString(value, "nearest_even"),
        .formats => try expectStringArray(value, &.{ "h", "f", "d" }),
        .reserved_formats => try expectStringArray(value, &.{"q"}),
        .rejected_formats => try expectStringArray(value, &.{ "q", "f128", "bfloat16" }),
        .operation_spelling => try expectString(value, "c23_hfd_lowercase_v1"),
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

fn validateFunctionField(
    function: *ManifestBuilder,
    name: []const u8,
    value: []const u8,
) ValidationError!void {
    const key = std.meta.stringToEnum(FunctionKey, name) orelse
        return error.UnknownFunctionKey;
    const key_index: usize = @intFromEnum(key);
    if (function.seen[key_index]) return error.DuplicateFunctionKey;
    if (key_index != function.next_key) return error.UnorderedFunctionKey;
    function.seen[key_index] = true;
    function.next_key += 1;

    switch (key) {
        .op => function.operation = try parseManifestOperation(try parseString(value)),
        .provenance => {
            const parsed = try parseProvenanceInfo(value);
            function.provenance = parsed.legacy;
            function.provenance_values = parsed.values;
        },
        .status => function.status = try parseFunctionStatus(try parseString(value)),
        .arity => {
            const arity = parseCanonicalUnsigned(value) orelse return error.InvalidArity;
            if (arity == 0 or arity > input_count_max) return error.InvalidArity;
            function.arity = @intCast(arity);
        },
        .inputs => function.inputs = try parseInputList(value),
        .result => function.result = try parseResultDescriptor(try parseString(value)),
        .oracle => function.oracle = try parseOracle(try parseString(value)),
        .special_policy => try expectString(value, "zmath_c23_v1"),
        .max_ulp => {
            function.max_ulp = parseCanonicalUnsigned(value) orelse
                return error.InvalidMaxUlp;
        },
    }
}

fn appendFunction(
    function_values: *[function_count_max]Function,
    function_count: *usize,
    previous_function: *?Function,
    function: ManifestBuilder,
) ValidationError!void {
    if (function_count.* == function_count_max) return error.TooManyFunctionRows;
    const value = try finishFunction(function);
    if (previous_function.*) |previous| {
        const order = compareFunctions(previous, value);
        if (order > 0) return error.UnsortedFunctionRow;
        if (order == 0) return error.DuplicateFunctionRow;
    }
    try validateCanonicalDescriptor(value, canonical_function_descriptors[function_count.*]);
    function_values[function_count.*] = value;
    function_count.* += 1;
    previous_function.* = value;
}

fn finishFunction(builder: ManifestBuilder) ValidationError!Function {
    if (builder.next_key != function_key_count) return error.MissingFunctionKey;
    const operation = builder.operation orelse return error.MissingFunctionKey;
    const provenance = builder.provenance orelse return error.MissingFunctionKey;
    const status = builder.status orelse return error.MissingFunctionKey;
    const arity = builder.arity orelse return error.MissingFunctionKey;
    const inputs = builder.inputs orelse return error.MissingFunctionKey;
    const result = builder.result orelse return error.MissingFunctionKey;
    const oracle = builder.oracle orelse return error.MissingFunctionKey;
    const max_ulp = builder.max_ulp orelse return error.MissingFunctionKey;
    if (inputs.count != arity) return error.InvalidArity;
    try validateStatusRelation(status, oracle, max_ulp);

    var arguments: ArgumentList = .{};
    arguments.count = inputs.count;
    for (inputs.descriptors[0..inputs.count], 0..) |descriptor, index| {
        arguments.descriptors[index] = descriptor;
    }
    const value: Function = .{
        .op = @tagName(operation),
        .provenance = builder.provenance_values,
        .status = status,
        .arity = arity,
        .inputs = arguments,
        .result = result,
        .oracle = oracle,
        .special_policy = "zmath_c23_v1",
        .max_ulp = max_ulp,
    };
    _ = provenance;
    return value;
}

fn functionFormat(function: Function) ?Format {
    if (function.result.floatFormat()) |format| return format;
    for (function.arguments()) |argument| if (argument.floatFormat()) |format| return format;
    return null;
}

fn validateCanonicalDescriptor(function: Function, expected: FunctionDescriptor) ValidationError!void {
    if (!std.mem.eql(u8, function.op, @tagName(expected.operation))) return error.InvalidDescriptor;
    if (expected.provenance == .zmath and
        (function.provenance.count != 1 or function.provenance.values[0] != .zmath)) return error.InvalidProvenance;
    if (expected.provenance == .zmath_core_math and
        (function.provenance.count != 2 or
            function.provenance.values[0] != .zmath or
            function.provenance.values[1] != .core_math)) return error.InvalidProvenance;
    if (functionFormat(function) != expected.format or function.arity != expected.arity) return error.InvalidDescriptor;
    if (function.arguments().len != expected.inputs.count) return error.InvalidDescriptor;
    for (function.arguments(), expected.inputs.descriptors[0..expected.inputs.count]) |actual, wanted| {
        if (!std.meta.eql(actual, wanted)) return error.InvalidDescriptor;
    }
    if (!std.meta.eql(function.result, expected.result)) return error.InvalidDescriptor;
}

fn compareFunctions(previous: Function, current: Function) i8 {
    const previous_provenance: u1 = @intFromBool(previous.provenance.count == 2);
    const current_provenance: u1 = @intFromBool(current.provenance.count == 2);
    if (previous_provenance < current_provenance) return -1;
    if (previous_provenance > current_provenance) return 1;
    const operation_order = std.mem.order(u8, previous.op, current.op);
    if (operation_order == .lt) return -1;
    if (operation_order == .gt) return 1;
    const previous_format = @intFromEnum(functionFormat(previous) orelse .h);
    const current_format = @intFromEnum(functionFormat(current) orelse .h);
    if (previous_format < current_format) return -1;
    if (previous_format > current_format) return 1;
    return 0;
}

fn requireAllRootKeys(seen: [14]bool) ValidationError!void {
    for (seen) |present| {
        if (!present) return error.MissingRootKey;
    }
}

fn validateOperationName(name: []const u8) ValidationError!void {
    if (std.meta.stringToEnum(ManifestOperation, name) == null) return error.UnknownOperation;
}

fn parseRootKey(name: []const u8) ?RootKey {
    return std.meta.stringToEnum(RootKey, name);
}

fn isRootOnlyKey(name: []const u8) bool {
    const key = parseRootKey(name) orelse return false;
    return key != .special_policy;
}

fn parseManifestOperation(text: []const u8) ValidationError!ManifestOperation {
    return std.meta.stringToEnum(ManifestOperation, text) orelse error.UnknownOperation;
}

fn parseCorpusOperation(text: []const u8) ValidationError!Operation {
    if (std.mem.eql(u8, text, "exp")) return .exp;
    if (std.mem.eql(u8, text, "log")) return .log;
    if (std.mem.eql(u8, text, "sin")) return .sin;
    return error.UnknownOperation;
}

fn parseFormat(text: []const u8) ValidationError!Format {
    if (std.mem.eql(u8, text, "h")) return .h;
    if (std.mem.eql(u8, text, "f")) return .f;
    if (std.mem.eql(u8, text, "d")) return .d;
    if (std.mem.eql(u8, text, "q")) return error.ReservedFormat;
    if (std.mem.eql(u8, text, "f128")) return error.RejectedFormat;
    if (std.mem.eql(u8, text, "bfloat16")) return error.RejectedFormat;
    return error.UnknownFormat;
}

fn parseFunctionStatus(text: []const u8) ValidationError!FunctionStatus {
    return std.meta.stringToEnum(FunctionStatus, text) orelse
        error.UnsupportedFunctionStatus;
}

fn validateStatusRelation(
    status: FunctionStatus,
    oracle: Oracle,
    max_ulp: u64,
) ValidationError!void {
    switch (status) {
        .unsupported => {
            if (oracle != .none or max_ulp != 0) return error.InvalidStatusRelation;
        },
        .correct => {
            if (oracle == .none or max_ulp != 0) return error.InvalidStatusRelation;
        },
        .bounded => {
            if (oracle == .none) return error.InvalidStatusRelation;
        },
    }
}

fn parseOracle(text: []const u8) ValidationError!Oracle {
    return std.meta.stringToEnum(Oracle, text) orelse error.UnknownOracle;
}

const ParsedProvenance = struct {
    legacy: Provenance,
    values: ProvenanceList,
};

fn parseProvenanceInfo(value: []const u8) ValidationError!ParsedProvenance {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') {
        return error.InvalidProvenance;
    }
    const elements = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    if (elements.len == 0) return error.InvalidProvenance;

    var items: [max_provenance_count][]const u8 = undefined;
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, elements, ',');
    while (iterator.next()) |element| {
        if (count == items.len) return error.InvalidProvenance;
        items[count] = parseString(std.mem.trim(u8, element, " \t")) catch
            return error.InvalidProvenance;
        count += 1;
    }
    if (count == 0) return error.InvalidProvenance;

    var values: ProvenanceList = .empty;
    var previous: ?Provenance = null;
    for (items[0..count]) |item| {
        const parsed: Provenance = if (std.mem.eql(u8, item, "zmath"))
            .zmath
        else if (std.mem.eql(u8, item, "core_math"))
            .core_math
        else
            return error.InvalidProvenance;
        if (previous) |prior| {
            if (@intFromEnum(parsed) <= @intFromEnum(prior)) return error.InvalidProvenance;
        }
        values.values[values.count] = parsed;
        values.count += 1;
        previous = parsed;
    }
    const legacy: Provenance = if (values.count == 1 and values.values[0] == .zmath)
        .zmath
    else if (values.count == 2 and values.values[0] == .zmath and values.values[1] == .core_math)
        .zmath_core_math
    else
        return error.InvalidProvenance;
    return .{ .legacy = legacy, .values = values };
}

fn parseProvenance(value: []const u8) ValidationError!Provenance {
    return (try parseProvenanceInfo(value)).legacy;
}

fn parseInputList(value: []const u8) ValidationError!InputList {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') {
        return error.InvalidDescriptor;
    }
    const elements = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    if (elements.len == 0) return .{};

    var inputs: InputList = .{};
    var iterator = std.mem.splitScalar(u8, elements, ',');
    while (iterator.next()) |element| {
        if (inputs.count == input_count_max) return error.InvalidArity;
        const text = parseString(std.mem.trim(u8, element, " \t")) catch
            return error.InvalidDescriptor;
        inputs.descriptors[inputs.count] = try parseInputDescriptor(text);
        inputs.count += 1;
    }
    return inputs;
}

fn parseInputDescriptor(text: []const u8) ValidationError!InputDescriptor {
    if (std.mem.eql(u8, text, "tag")) return .tag;
    if (std.mem.eql(u8, text, "fromfp_round")) return .fromfp_round;
    if (std.mem.startsWith(u8, text, "float:")) {
        const format = parseDescriptorFormat(text["float:".len..]) orelse
            return error.InvalidDescriptor;
        return .{ .float = format };
    }
    if (std.mem.startsWith(u8, text, "integer:")) {
        const integer_type = std.meta.stringToEnum(
            IntegerType,
            text["integer:".len..],
        ) orelse return error.InvalidDescriptor;
        return .{ .integer = integer_type };
    }
    return error.InvalidDescriptor;
}

fn parseResultDescriptor(text: []const u8) ValidationError!ResultDescriptor {
    if (std.mem.eql(u8, text, "bool")) {
        return .boolean;
    }
    if (std.mem.startsWith(u8, text, "float:")) {
        const format = parseDescriptorFormat(text["float:".len..]) orelse
            return error.InvalidDescriptor;
        return .{ .float = format };
    }
    if (std.mem.startsWith(u8, text, "integer:")) {
        const integer_type = std.meta.stringToEnum(
            IntegerType,
            text["integer:".len..],
        ) orelse return error.InvalidDescriptor;
        return .{ .integer = integer_type };
    }
    if (std.mem.startsWith(u8, text, "struct:")) {
        var parts = std.mem.splitScalar(u8, text, ':');
        if (!std.mem.eql(u8, parts.next() orelse "", "struct")) {
            return error.InvalidDescriptor;
        }
        const kind = parts.next() orelse return error.InvalidDescriptor;
        const format_text = parts.next() orelse return error.InvalidDescriptor;
        if (parts.next() != null) return error.InvalidDescriptor;
        const structure_kind = std.meta.stringToEnum(StructureKind, kind) orelse
            return error.InvalidDescriptor;
        const format = parseDescriptorFormat(format_text) orelse
            return error.InvalidDescriptor;
        return .{ .structure = .{ .kind = structure_kind, .format = format } };
    }
    return error.InvalidDescriptor;
}

fn parseDescriptorFormat(text: []const u8) ?Format {
    if (std.mem.eql(u8, text, "h")) return .h;
    if (std.mem.eql(u8, text, "f")) return .f;
    if (std.mem.eql(u8, text, "d")) return .d;
    return null;
}

fn parseOutputClass(text: []const u8) ValidationError!OutputClass {
    if (std.mem.eql(u8, text, "normal")) return .normal;
    if (std.mem.eql(u8, text, "subnormal")) return .subnormal;
    if (std.mem.eql(u8, text, "zero")) return .zero;
    if (std.mem.eql(u8, text, "infinity")) return .infinity;
    if (std.mem.eql(u8, text, "qnan")) return .qnan;
    return error.UnknownOutputClass;
}

fn parseString(value: []const u8) ValidationError![]const u8 {
    if (value.len < 2) return error.InvalidPinnedValue;
    if (value[0] != '"' or value[value.len - 1] != '"') {
        return error.InvalidPinnedValue;
    }
    const text = value[1 .. value.len - 1];
    if (std.mem.indexOfAny(u8, text, "\\\"") != null) return error.InvalidPinnedValue;
    return text;
}

fn expectString(value: []const u8, expected: []const u8) ValidationError!void {
    const actual = try parseString(value);
    if (!std.mem.eql(u8, actual, expected)) return error.InvalidPinnedValue;
}

fn expectUnsigned(value: []const u8, expected: u64) ValidationError!void {
    const actual = parseCanonicalUnsigned(value) orelse return error.InvalidPinnedValue;
    if (actual != expected) return error.InvalidPinnedValue;
}

fn parseCanonicalUnsigned(value: []const u8) ?u64 {
    if (value.len == 0) return null;
    if (value.len > 1 and value[0] == '0') return null;
    for (value) |digit| {
        if (digit < '0' or digit > '9') return null;
    }
    return std.fmt.parseUnsigned(u64, value, 10) catch null;
}

fn expectStringArray(
    value: []const u8,
    expected: []const []const u8,
) ValidationError!void {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') {
        return error.InvalidPinnedValue;
    }
    const elements = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    if (expected.len == 0) {
        if (elements.len != 0) return error.InvalidPinnedValue;
        return;
    }

    var iterator = std.mem.splitScalar(u8, elements, ',');
    var index: usize = 0;
    while (iterator.next()) |element| {
        if (index == expected.len) return error.InvalidPinnedValue;
        const actual = try parseString(std.mem.trim(u8, element, " \t"));
        if (!std.mem.eql(u8, actual, expected[index])) return error.InvalidPinnedValue;
        index += 1;
    }
    if (index != expected.len) return error.InvalidPinnedValue;
}

fn validateHexBits(text: []const u8, format: Format) ValidationError!void {
    if (text.len != format.hexadecimalDigits()) return error.InvalidHexWidth;
    for (text) |digit| {
        if (digit >= 'A' and digit <= 'F') return error.UppercaseHexDigit;
        if (!isLowerHexDigit(digit)) return error.InvalidHexDigit;
    }
}

fn isLowerHexDigit(digit: u8) bool {
    return (digit >= '0' and digit <= '9') or (digit >= 'a' and digit <= 'f');
}

fn validateMaxUlp(text: []const u8) ValidationError!void {
    if (parseCanonicalUnsigned(text) == null) return error.InvalidMaxUlp;
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

fn validateSorted(previous: SortKey, current: SortKey) ValidationError!void {
    const previous_operation = @intFromEnum(previous.operation);
    const current_operation = @intFromEnum(current.operation);
    if (current_operation < previous_operation) return error.UnsortedCorpusRow;
    if (current_operation > previous_operation) return;

    const previous_format = @intFromEnum(previous.format);
    const current_format = @intFromEnum(current.format);
    if (current_format < previous_format) return error.UnsortedCorpusRow;
    if (current_format > previous_format) return;

    if (current.input_bits < previous.input_bits) return error.UnsortedCorpusRow;
    if (current.input_bits == previous.input_bits) return error.DuplicateCorpusRow;
}

test "typed descriptor records round trip signaling NaN" {
    const argument = corpusFieldForTest(.f, 0x7f800001, .snan);
    const record = try CorpusRecord.init(.{
        .operation = "copySign",
        .provenance = &.{.zmath},
        .arguments = &.{ argument, corpusFieldForTest(.f, 0x80000000, .zero) },
        .result_descriptor = .{ .float = .f },
        .results = &.{corpusFieldForTest(.f, 0xff800001, .snan)},
        .max_ulp = 0,
    });
    var encoded: [512]u8 = undefined;
    const encoded_record = try encodeCorpusRecord(&record, &encoded);
    const decoded = try decodeCorpusRecord(encoded_record);
    try std.testing.expectEqual(@as(u64, 0x7f800001), decoded.arguments.values[0].float.bits);
    try std.testing.expectEqual(FieldClass.snan, decoded.arguments.values[0].float.class);
    try std.testing.expectEqual(@as(u64, 0xff800001), decoded.results.values[0].float.bits);
    try std.testing.expectEqual(FieldClass.snan, decoded.results.values[0].float.class);
}

fn corpusFieldForTest(format: Format, bits: u64, class: FieldClass) CorpusField {
    return .{ .float = .{ .format = format, .bits = bits, .class = class } };
}

test "typed descriptor records reject corrupt length and class" {
    const record = try CorpusRecord.init(.{
        .operation = "exp",
        .provenance = &.{.zmath},
        .arguments = &.{corpusFieldForTest(.f, 0, .none)},
        .result_descriptor = .{ .float = .f },
        .results = &.{corpusFieldForTest(.f, 0, .zero)},
        .max_ulp = 0,
    });
    var encoded: [512]u8 = undefined;
    const encoded_record = try encodeCorpusRecord(&record, &encoded);
    encoded[5] = 0;
    encoded[6] = 0;
    encoded[7] = 0;
    encoded[8] = 0;
    try std.testing.expectError(error.InvalidRecordLength, decodeCorpusRecord(encoded_record));
    try std.testing.expectError(
        error.InvalidResultClass,
        oracleResultField(formatOracleFieldDescriptor(.f), 0, .none),
    );
}

test "streaming records distinguish clean EOF from truncated frames" {
    const record = try CorpusRecord.init(.{
        .operation = "abs",
        .provenance = &.{.zmath},
        .arguments = &.{corpusFieldForTest(.f, 0, .none)},
        .result_descriptor = .{ .float = .f },
        .results = &.{corpusFieldForTest(.f, 0, .zero)},
        .max_ulp = 0,
    });
    var encoded: [512]u8 = undefined;
    const bytes = try encodeCorpusRecord(&record, &encoded);
    var scratch: [512]u8 = undefined;
    var empty = std.Io.Reader.fixed("");
    try std.testing.expect((try readEncodedRecord(&empty, &scratch)) == null);
    var input = std.Io.Reader.fixed(bytes);
    const actual = (try readEncodedRecord(&input, &scratch)) orelse return error.MissingRecord;
    try std.testing.expectEqualSlices(u8, bytes, actual);
    try std.testing.expect((try readEncodedRecord(&input, &scratch)) == null);
    for ([_]usize{ 1, bytes.len - 1 }) |length| {
        var truncated = std.Io.Reader.fixed(bytes[0..length]);
        try std.testing.expectError(error.TruncatedRecord, readEncodedRecord(&truncated, &scratch));
    }
}
