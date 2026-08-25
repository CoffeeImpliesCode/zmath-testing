const std = @import("std");

pub const manifest_text = @embedFile("corpus/manifest.toml");

pub const canonical_function_count: usize = 315;
pub const function_count_max: usize = canonical_function_count;
const function_key_count: usize = 9;
const input_count_max: usize = 3;
const manifest_bytes_max: usize = 256 * 1024;
const manifest_line_bytes_max: usize = 512;

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
};

// The runtime oracle dispatches only these operations. ManifestOperation below
// is the complete schema-v2 operation vocabulary.
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

    fn hexadecimalDigits(format: Format) usize {
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
    mpfr_arb,
};

pub const Provenance = enum(u8) {
    zmath,
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
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
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
};

pub const InputDescriptor = union(enum) {
    float: Format,
    integer: IntegerType,
    tag,
    fromfp_round,

    fn floatFormat(descriptor: InputDescriptor) ?Format {
        return switch (descriptor) {
            .float => |format| format,
            .integer, .tag, .fromfp_round => null,
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

pub const ResultDescriptor = union(enum) {
    float: Format,
    integer: IntegerType,
    boolean,
    structure: StructureDescriptor,

    fn floatFormat(descriptor: ResultDescriptor) ?Format {
        return switch (descriptor) {
            .float => |format| format,
            .structure => |structure| structure.format,
            .integer, .boolean => null,
        };
    }
};

const Function = struct {
    seen: [function_key_count]bool = @splat(false),
    next_key: usize = 0,
    operation: ?ManifestOperation = null,
    provenance: ?Provenance = null,
    status: ?FunctionStatus = null,
    arity: ?u8 = null,
    inputs: ?InputList = null,
    result: ?ResultDescriptor = null,
    oracle: ?Oracle = null,
    max_ulp: ?u64 = null,
};

pub const FunctionDescriptor = struct {
    operation: ManifestOperation,
    provenance: Provenance,
    format: Format,
    arity: u8,
    inputs: InputList,
    result: ResultDescriptor,
};

pub const FunctionRow = struct {
    operation: ManifestOperation,
    provenance: Provenance,
    format: Format,
    arity: u8,
    inputs: InputList,
    result: ResultDescriptor,
    status: FunctionStatus,
    oracle: Oracle,
    max_ulp: u64,
};

pub const Manifest = struct {
    functions: [function_count_max]FunctionRow,
    function_count: u16,

    pub fn functionRows(manifest: *const Manifest) []const FunctionRow {
        const count: usize = manifest.function_count;
        return manifest.functions[0..count];
    }

    pub fn functionCount(manifest: *const Manifest) usize {
        return manifest.function_count;
    }

    pub fn functionStatus(
        manifest: *const Manifest,
        operation: Operation,
        format: Format,
    ) ?FunctionStatus {
        const row = manifest.functionRow(operation, format) orelse return null;
        return row.status;
    }

    pub fn functionRow(
        manifest: *const Manifest,
        operation: Operation,
        format: Format,
    ) ?*const FunctionRow {
        const manifest_operation = operation.manifestOperation();
        var match: ?*const FunctionRow = null;
        for (manifest.functionRows()) |*function| {
            if (function.operation != manifest_operation or function.format != format) continue;
            if (match != null) return null;
            match = function;
        }
        return match;
    }
};

pub const TargetMode = struct {
    target: []const u8,
    mode: []const u8,

    pub fn eql(left: TargetMode, right: TargetMode) bool {
        return std.mem.eql(u8, left.target, right.target) and
            std.mem.eql(u8, left.mode, right.mode);
    }

    fn valid(target_mode: TargetMode) bool {
        return validMetadataComponent(target_mode.target) and
            validMetadataComponent(target_mode.mode);
    }
};

pub const ArtifactMetadata = struct {
    artifact_name: []const u8,
    target_mode: TargetMode,
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
    function: FunctionRow,
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
        const current = SortKey{
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

pub const canonical_function_descriptors: [canonical_function_count]FunctionDescriptor =
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
        .abs, .acos, .acosh, .asin, .asinh, .atan, .atanh, .cbrt, .ceil, .cos, .cosh, .erf, .exp, .exp10, .exp10m1, .exp2, .exp2m1, .expm1, .floor, .getPayload, .log, .log10, .log1p, .log2, .logb, .logp1, .nearbyint, .nextDown, .nextUp, .rint, .round, .roundeven, .rsqrt, .sin, .sinh, .sinpi, .sqrt, .tan, .tanh, .tanpi, .trunc, .acospi, .asinpi, .atanpi, .cospi, .erfc, .log10p1, .log2p1, .tgamma => .unary_float,
        .canonicalize => .unary_canonicalize,
        .compoundn, .pown, .rootn => .power,
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
    var function: ?Function = null;
    var function_count: usize = 0;
    var function_rows: [function_count_max]FunctionRow = undefined;
    var previous_function: ?FunctionRow = null;
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
                    &function_rows,
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
            &function_rows,
            &function_count,
            &previous_function,
            current,
        );
    }
    if (function_count != canonical_function_count) return error.MissingFunctionRow;

    return .{
        .functions = function_rows,
        .function_count = @intCast(function_count),
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
        const current = SortKey{
            .operation = row.operation,
            .format = row.format,
            .input_bits = row.input_bits,
        };
        if (previous) |prior| try validateSorted(prior, current);
        previous = current;
    }
}
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

    const artifact_identity = parseArtifactName(artifact_metadata.artifact_name) orelse
        return error.InvalidArtifactName;
    const function = try findArtifactFunction(
        manifest,
        artifact_identity.operation,
        artifact_identity.format,
    );
    if (function.status == .unsupported) return error.UnsupportedArtifact;

    var iterator = try RowIterator.init(source);
    var row_count: usize = 0;
    while (try iterator.next()) |row| {
        if (row.operation != artifact_identity.operation) {
            return error.ArtifactOperationMismatch;
        }
        if (row.format != artifact_identity.format) {
            return error.ArtifactFormatMismatch;
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
    if (row_count == 0) return error.EmptyArtifact;

    return .{
        .source = source,
        .metadata = artifact_metadata,
        .function = function.*,
        .operation = artifact_identity.operation,
        .format = artifact_identity.format,
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

fn findArtifactFunction(
    manifest: *const Manifest,
    operation: Operation,
    format: Format,
) ValidationError!*const FunctionRow {
    const manifest_operation = operation.manifestOperation();
    var match: ?*const FunctionRow = null;
    for (manifest.functionRows()) |*function| {
        if (function.operation != manifest_operation or function.format != format) continue;
        if (match != null) return error.AmbiguousArtifactManifestRow;
        match = function;
    }
    return match orelse error.MissingArtifactManifestRow;
}

fn parseArtifactName(name: []const u8) ?ArtifactIdentity {
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
        .schema_version => try expectUnsigned(value, 2),
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
    function: *Function,
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
        .provenance => function.provenance = try parseProvenance(value),
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
    function_rows: *[function_count_max]FunctionRow,
    function_count: *usize,
    previous_function: *?FunctionRow,
    function: Function,
) ValidationError!void {
    if (function_count.* == function_count_max) return error.TooManyFunctionRows;
    const row = try finishFunction(function);
    if (previous_function.*) |previous| {
        const order = compareFunctionRows(previous, row);
        if (order > 0) return error.UnsortedFunctionRow;
        if (order == 0) return error.DuplicateFunctionRow;
    }
    try validateCanonicalDescriptor(row, canonical_function_descriptors[function_count.*]);
    function_rows[function_count.*] = row;
    function_count.* += 1;
    previous_function.* = row;
}

fn finishFunction(function: Function) ValidationError!FunctionRow {
    if (function.next_key != function_key_count) return error.MissingFunctionKey;

    const operation = function.operation orelse return error.MissingFunctionKey;
    const provenance = function.provenance orelse return error.MissingFunctionKey;
    const status = function.status orelse return error.MissingFunctionKey;
    const arity = function.arity orelse return error.MissingFunctionKey;
    const inputs = function.inputs orelse return error.MissingFunctionKey;
    const result = function.result orelse return error.MissingFunctionKey;
    const oracle = function.oracle orelse return error.MissingFunctionKey;
    const max_ulp = function.max_ulp orelse return error.MissingFunctionKey;

    if (inputs.count != arity) return error.InvalidArity;
    const format = try deriveFunctionFormat(inputs, result);
    try validateStatusRelation(status, oracle, max_ulp);

    return .{
        .operation = operation,
        .provenance = provenance,
        .format = format,
        .arity = arity,
        .inputs = inputs,
        .result = result,
        .status = status,
        .oracle = oracle,
        .max_ulp = max_ulp,
    };
}

fn deriveFunctionFormat(inputs: InputList, result: ResultDescriptor) ValidationError!Format {
    if (result.floatFormat()) |format| return format;
    for (inputs.descriptors[0..inputs.count]) |descriptor| {
        if (descriptor.floatFormat()) |format| return format;
    }
    return error.InvalidDescriptor;
}
fn validateCanonicalDescriptor(
    row: FunctionRow,
    expected: FunctionDescriptor,
) ValidationError!void {
    if (row.operation != expected.operation) return error.InvalidDescriptor;
    if (row.provenance != expected.provenance) return error.InvalidProvenance;
    if (row.format != expected.format) return error.InvalidDescriptor;
    if (row.arity != expected.arity) return error.InvalidArity;
    if (!std.meta.eql(row.inputs, expected.inputs)) return error.InvalidDescriptor;
    if (!std.meta.eql(row.result, expected.result)) return error.InvalidDescriptor;
}

fn narrowingSignature(operation: ManifestOperation) ?NarrowingSignature {
    return switch (operation) {
        .fadd, .fdiv, .fmul, .fsub => .{ .source = .d, .destination = .f, .arity = 2 },
        .ffma => .{ .source = .d, .destination = .f, .arity = 3 },
        .fsqrt => .{ .source = .d, .destination = .f, .arity = 1 },
        .f16addf32, .f16divf32, .f16mulf32, .f16subf32 => .{
            .source = .f,
            .destination = .h,
            .arity = 2,
        },
        .f16fmaf32 => .{ .source = .f, .destination = .h, .arity = 3 },
        .f16sqrtf32 => .{ .source = .f, .destination = .h, .arity = 1 },
        .f16addf64, .f16divf64, .f16mulf64, .f16subf64 => .{
            .source = .d,
            .destination = .h,
            .arity = 2,
        },
        .f16fmaf64 => .{ .source = .d, .destination = .h, .arity = 3 },
        .f16sqrtf64 => .{ .source = .d, .destination = .h, .arity = 1 },
        .f32addf64, .f32divf64, .f32mulf64, .f32subf64 => .{
            .source = .d,
            .destination = .f,
            .arity = 2,
        },
        .f32fmaf64 => .{ .source = .d, .destination = .f, .arity = 3 },
        .f32sqrtf64 => .{ .source = .d, .destination = .f, .arity = 1 },
        else => null,
    };
}

fn validateStatusRelation(
    status: FunctionStatus,
    oracle: Oracle,
    max_ulp: u64,
) ValidationError!void {
    switch (status) {
        .unsupported => {
            if (oracle != .none) return error.InvalidStatusRelation;
            if (max_ulp != 0) return error.InvalidStatusRelation;
        },
        .correct => {
            if (oracle != .mpfr_arb) return error.InvalidStatusRelation;
            if (max_ulp != 0) return error.InvalidStatusRelation;
        },
        .bounded => {
            if (oracle != .mpfr_arb) return error.InvalidStatusRelation;
        },
    }
}

fn compareFunctionRows(previous: FunctionRow, current: FunctionRow) i8 {
    const previous_provenance = @intFromEnum(previous.provenance);
    const current_provenance = @intFromEnum(current.provenance);
    if (previous_provenance < current_provenance) return -1;
    if (previous_provenance > current_provenance) return 1;

    const previous_operation = @intFromEnum(previous.operation);
    const current_operation = @intFromEnum(current.operation);
    if (previous_operation < current_operation) return -1;
    if (previous_operation > current_operation) return 1;

    const previous_format = @intFromEnum(previous.format);
    const current_format = @intFromEnum(current.format);
    if (previous_format < current_format) return -1;
    if (previous_format > current_format) return 1;
    return 0;
}

fn requireAllRootKeys(root_seen: [14]bool) ValidationError!void {
    for (root_seen) |seen| {
        if (!seen) return error.MissingRootKey;
    }
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

fn parseOracle(text: []const u8) ValidationError!Oracle {
    return std.meta.stringToEnum(Oracle, text) orelse error.UnknownOracle;
}

fn parseProvenance(value: []const u8) ValidationError!Provenance {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') {
        return error.InvalidProvenance;
    }
    const elements = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    if (elements.len == 0) return error.InvalidProvenance;

    var items: [2][]const u8 = undefined;
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, elements, ',');
    while (iterator.next()) |element| {
        if (count == items.len) return error.InvalidProvenance;
        items[count] = parseString(std.mem.trim(u8, element, " \t")) catch
            return error.InvalidProvenance;
        count += 1;
    }

    if (count == 1 and std.mem.eql(u8, items[0], "zmath")) return .zmath;
    if (count == 2 and
        std.mem.eql(u8, items[0], "zmath") and
        std.mem.eql(u8, items[1], "core_math"))
    {
        return .zmath_core_math;
    }
    return error.InvalidProvenance;
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

test "embedded manifest contains all schema-v2 rows" {
    const manifest = try parseEmbeddedManifest();
    try std.testing.expectEqual(@as(usize, 315), manifest.functionCount());
}

test "manifest rejects unknown function status" {
    var source: [manifest_text.len]u8 = undefined;
    @memcpy(&source, manifest_text);
    const status_index = std.mem.indexOf(u8, &source, "unsupported") orelse unreachable;
    source[status_index] = 'x';
    try std.testing.expectError(error.UnsupportedFunctionStatus, validateManifest(&source));
}

test "TSV rejects unknown operations and output classes" {
    try std.testing.expectError(
        error.UnknownOperation,
        validateTsv(
            "op\tformat\tinput_bits\toutput_bits\toutput_class\tmax_ulp\n" ++
                "cos\th\t0000\t0000\tzero\t0\n",
        ),
    );
    try std.testing.expectError(
        error.UnknownOutputClass,
        validateTsv(
            "op\tformat\tinput_bits\toutput_bits\toutput_class\tmax_ulp\n" ++
                "exp\th\t0000\t0000\tsnan\t0\n",
        ),
    );
}

test "artifact loading requires explicit target and mode metadata" {
    const manifest = try parseEmbeddedManifest();
    const source =
        "op\tformat\tinput_bits\toutput_bits\toutput_class\tmax_ulp\n" ++
        "exp\th\t0000\t3c00\tnormal\t0\n";
    const target_mode = TargetMode{
        .target = "x86_64-linux-gnu",
        .mode = "Debug",
    };
    try std.testing.expectError(
        error.MissingArtifactMetadata,
        loadArtifact(&manifest, source, null, target_mode),
    );
    try std.testing.expectError(
        error.MissingArtifactMetadata,
        loadArtifact(
            &manifest,
            source,
            .{
                .artifact_name = "test/corpus/exp_h.tsv",
                .target_mode = target_mode,
            },
            null,
        ),
    );
}

test "artifact loading rejects unsupported manifest rows" {
    const manifest = try parseEmbeddedManifest();
    const target_mode = TargetMode{
        .target = "x86_64-linux-gnu",
        .mode = "Debug",
    };
    const source =
        "op\tformat\tinput_bits\toutput_bits\toutput_class\tmax_ulp\n" ++
        "exp\th\t0000\t3c00\tnormal\t0\n";
    try std.testing.expectError(
        error.UnsupportedArtifact,
        loadArtifact(
            &manifest,
            source,
            .{
                .artifact_name = "test/corpus/exp_h.tsv",
                .target_mode = target_mode,
            },
            target_mode,
        ),
    );
}
