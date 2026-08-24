const std = @import("std");
const corpus = @import("corpus.zig");

const manifest_prefix =
    "schema_version = 2\n" ++
    "core_math_repository = \"https://gitlab.inria.fr/core-math/core-math.git\"\n" ++
    "core_math_revision = \"3bafed75e3c22399531857d63a3fa0e24bfb42fa\"\n" ++
    "mpfr_precision_bits = 512\n" ++
    "arb_precision_bits = 512\n" ++
    "rounding = \"nearest_even\"\n" ++
    "formats = [\"h\", \"f\", \"d\"]\n" ++
    "reserved_formats = [\"q\"]\n" ++
    "rejected_formats = [\"q\", \"f128\", \"bfloat16\"]\n" ++
    "operation_spelling = \"case_sensitive_ascii_identifier\"\n" ++
    "columns = [\"op\", \"provenance\", \"status\", \"arity\", \"inputs\", " ++
    "\"result\", \"oracle\", \"special_policy\", \"max_ulp\"]\n" ++
    "hexadecimal = \"lowercase_fixed_width\"\n" ++
    "uncertainty_policy = \"fail_closed\"\n" ++
    "special_policy = \"zmath_c23_v1\"\n\n";

const scalar_row =
    "[[function]]\n" ++
    "op = \"sample\"\n" ++
    "provenance = [\"c23_7_12\"]\n" ++
    "status = \"unsupported\"\n" ++
    "arity = 1\n" ++
    "inputs = [\"float:h\"]\n" ++
    "result = \"float:h\"\n" ++
    "oracle = \"none\"\n" ++
    "special_policy = \"zmath_c23_v1\"\n" ++
    "max_ulp = 0\n";

fn scalarArgument(function: corpus.Function, index: usize) !corpus.Format {
    return switch (function.inputs.slice()[index]) {
        .float => |format| format,
        else => error.UnexpectedArgumentDescriptor,
    };
}

fn structResult(function: corpus.Function) !corpus.StructDescriptor {
    return switch (function.result) {
        .structure => |descriptor| descriptor,
        else => error.UnexpectedResultDescriptor,
    };
}

fn oracleFieldDescriptorsMatch(
    expected: corpus.OracleFieldDescriptor,
    actual: corpus.OracleFieldDescriptor,
) bool {
    return expected.kind == actual.kind and
        expected.value_bits == actual.value_bits and
        expected.format.code == actual.format.code and
        expected.format.storage_bits == actual.format.storage_bits and
        expected.format.exponent_bits == actual.format.exponent_bits and
        expected.format.fraction_bits == actual.format.fraction_bits and
        expected.format.reserved == actual.format.reserved and
        expected.reserved == actual.reserved;
}

const baseline_unary_float_operations = [_][]const u8{
    "abs",
    "ceil",
    "floor",
    "nearbyint",
    "rint",
    "round",
    "roundeven",
    "trunc",
    "exp",
    "exp2",
    "exp10",
    "expm1",
    "exp2m1",
    "exp10m1",
    "log",
    "log2",
    "log10",
    "log1p",
    "logp1",
    "log2p1",
    "log10p1",
    "sin",
    "cos",
    "tan",
    "asin",
    "acos",
    "atan",
    "sinpi",
    "cospi",
    "tanpi",
    "asinpi",
    "acospi",
    "atanpi",
    "sinh",
    "cosh",
    "tanh",
    "asinh",
    "acosh",
    "atanh",
    "sqrt",
    "cbrt",
    "rsqrt",
    "erf",
    "erfc",
    "tgamma",
    "logb",
};

const baseline_unary_i64_operations = [_][]const u8{
    "lrint",
    "llrint",
    "lround",
    "llround",
    "llogb",
};

const baseline_unary_i32_operations = [_][]const u8{"ilogb"};

const baseline_fromfp_operations = [_][]const u8{
    "fromfp",
    "ufromfp",
    "fromfpx",
    "ufromfpx",
};

const baseline_binary_float_operations = [_][]const u8{
    "atan2",
    "atan2pi",
    "pow",
    "powr",
    "hypot",
    "fmod",
    "remainder",
    "fdim",
    "fmax",
    "fmin",
    "fmaximum",
    "fminimum",
    "fmaximum_mag",
    "fminimum_mag",
    "fmaximum_num",
    "fminimum_num",
    "fmaximum_mag_num",
    "fminimum_mag_num",
};

const baseline_binary_i64_operations = [_][]const u8{
    "pown",
    "compoundn",
    "rootn",
    "scalbln",
};

const baseline_binary_i32_operations = [_][]const u8{
    "ldexp",
    "scalbn",
};

const baseline_unary_struct_operations = [_][]const u8{
    "lgamma",
    "frexp",
    "modf",
};

const baseline_binary_struct_operations = [_][]const u8{"remquo"};
const baseline_ternary_float_operations = [_][]const u8{"fma"};

const ieee_operations = [_][]const u8{
    "canonicalize",
    "copySign",
    "nan",
    "nextAfter",
    "nextToward",
    "nextUp",
    "nextDown",
};

const annex_f_operations = [_][]const u8{
    "totalOrder",
    "totalOrderMag",
    "getPayload",
    "setPayload",
    "setPayloadSig",
};

const legacy_narrowing_operations = [_][]const u8{
    "fadd",
    "fsub",
    "fmul",
    "fdiv",
    "ffma",
    "fsqrt",
};

const AnnexHNarrowing = struct {
    operation: []const u8,
    arity: u8,
    source: corpus.Format,
    destination: corpus.Format,
};

const annex_h_narrowing = [_]AnnexHNarrowing{
    .{ .operation = "f16addf32", .arity = 2, .source = .f, .destination = .h },
    .{ .operation = "f16subf32", .arity = 2, .source = .f, .destination = .h },
    .{ .operation = "f16mulf32", .arity = 2, .source = .f, .destination = .h },
    .{ .operation = "f16divf32", .arity = 2, .source = .f, .destination = .h },
    .{ .operation = "f16fmaf32", .arity = 3, .source = .f, .destination = .h },
    .{ .operation = "f16sqrtf32", .arity = 1, .source = .f, .destination = .h },
    .{ .operation = "f16addf64", .arity = 2, .source = .d, .destination = .h },
    .{ .operation = "f16subf64", .arity = 2, .source = .d, .destination = .h },
    .{ .operation = "f16mulf64", .arity = 2, .source = .d, .destination = .h },
    .{ .operation = "f16divf64", .arity = 2, .source = .d, .destination = .h },
    .{ .operation = "f16fmaf64", .arity = 3, .source = .d, .destination = .h },
    .{ .operation = "f16sqrtf64", .arity = 1, .source = .d, .destination = .h },
    .{ .operation = "f32addf64", .arity = 2, .source = .d, .destination = .f },
    .{ .operation = "f32subf64", .arity = 2, .source = .d, .destination = .f },
    .{ .operation = "f32mulf64", .arity = 2, .source = .d, .destination = .f },
    .{ .operation = "f32divf64", .arity = 2, .source = .d, .destination = .f },
    .{ .operation = "f32fmaf64", .arity = 3, .source = .d, .destination = .f },
    .{ .operation = "f32sqrtf64", .arity = 1, .source = .d, .destination = .f },
};
fn annexHIndex(operation: []const u8) ?usize {
    for (annex_h_narrowing, 0..) |expected, index| {
        if (std.mem.eql(u8, expected.operation, operation)) return index;
    }
    return null;
}

fn operationIndex(operations: []const []const u8, operation: []const u8) ?usize {
    for (operations, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, operation)) return index;
    }
    return null;
}

fn expectArity(function: corpus.Function, arity: u8) !void {
    try std.testing.expectEqual(arity, function.arity);
}

fn expectArgument(
    function: corpus.Function,
    index: usize,
    expected: corpus.ArgumentDescriptor,
) !void {
    if (index >= function.inputs.count) return error.UnexpectedArgumentDescriptor;
    const actual = function.inputs.values[index];
    switch (expected) {
        .float => |format| switch (actual) {
            .float => |actual_format| try std.testing.expectEqual(format, actual_format),
            else => return error.UnexpectedArgumentDescriptor,
        },
        .integer => |integer| switch (actual) {
            .integer => |actual_integer| try std.testing.expectEqual(integer, actual_integer),
            else => return error.UnexpectedArgumentDescriptor,
        },
        .tag => switch (actual) {
            .tag => {},
            else => return error.UnexpectedArgumentDescriptor,
        },
        .fromfp_round => switch (actual) {
            .fromfp_round => {},
            else => return error.UnexpectedArgumentDescriptor,
        },
    }
}

fn expectFloatArguments(function: corpus.Function, arity: u8, format: corpus.Format) !void {
    try expectArity(function, arity);
    for (0..@as(usize, arity)) |index| {
        try expectArgument(function, index, .{ .float = format });
    }
}

fn expectIntegerArgument(
    function: corpus.Function,
    index: usize,
    integer: corpus.IntegerType,
) !void {
    try expectArgument(function, index, .{ .integer = integer });
}

fn expectFloatResult(function: corpus.Function, format: corpus.Format) !void {
    switch (function.result) {
        .float => |actual| try std.testing.expectEqual(format, actual),
        else => return error.UnexpectedResultDescriptor,
    }
}

fn expectIntegerResult(function: corpus.Function, integer: corpus.IntegerType) !void {
    switch (function.result) {
        .integer => |actual| try std.testing.expectEqual(integer, actual),
        else => return error.UnexpectedResultDescriptor,
    }
}

fn expectBooleanResult(function: corpus.Function) !void {
    switch (function.result) {
        .boolean => {},
        else => return error.UnexpectedResultDescriptor,
    }
}

fn expectStructureResult(
    function: corpus.Function,
    kind: corpus.StructKind,
    format: corpus.Format,
) !void {
    const result = try structResult(function);
    try std.testing.expectEqual(kind, result.kind);
    try std.testing.expectEqual(format, result.format);
}

fn firstFloatArgument(function: corpus.Function) !corpus.Format {
    return switch (function.inputs.values[0]) {
        .float => |format| format,
        else => error.UnexpectedArgumentDescriptor,
    };
}

fn expectBaselineDescriptor(function: corpus.Function) !void {
    const format = try firstFloatArgument(function);
    const operation = function.op;
    if (std.mem.eql(u8, operation, "atan2") or
        std.mem.eql(u8, operation, "atan2pi"))
    {
        try expectFloatArguments(function, 2, format);
        return expectStructureResult(function, .atan2, format);
    }
    if (std.mem.eql(u8, operation, "pown") or
        std.mem.eql(u8, operation, "compoundn") or
        std.mem.eql(u8, operation, "rootn"))
    {
        try expectArity(function, 2);
        try expectArgument(function, 0, .{ .float = format });
        try expectIntegerArgument(function, 1, .i64);
        return expectStructureResult(function, .power, format);
    }
    if (std.mem.eql(u8, operation, "lrint") or
        std.mem.eql(u8, operation, "llrint") or
        std.mem.eql(u8, operation, "lround") or
        std.mem.eql(u8, operation, "llround"))
    {
        try expectFloatArguments(function, 1, format);
        return expectStructureResult(function, .integer, format);
    }
    if (operationIndex(&baseline_unary_float_operations, operation) != null) {
        try expectFloatArguments(function, 1, format);
        return expectFloatResult(function, format);
    }
    if (operationIndex(&baseline_unary_i64_operations, operation) != null) {
        try expectFloatArguments(function, 1, format);
        return expectIntegerResult(function, .i64);
    }
    if (operationIndex(&baseline_unary_i32_operations, operation) != null) {
        try expectFloatArguments(function, 1, format);
        return expectIntegerResult(function, .i32);
    }
    if (operationIndex(&baseline_fromfp_operations, operation) != null) {
        try expectArity(function, 3);
        try expectArgument(function, 0, .{ .float = format });
        try expectArgument(function, 1, .fromfp_round);
        try expectIntegerArgument(function, 2, .u32);
        return expectFloatResult(function, format);
    }
    if (operationIndex(&baseline_binary_float_operations, operation) != null) {
        try expectFloatArguments(function, 2, format);
        return expectFloatResult(function, format);
    }
    if (operationIndex(&baseline_binary_i64_operations, operation) != null) {
        try expectArity(function, 2);
        try expectArgument(function, 0, .{ .float = format });
        try expectIntegerArgument(function, 1, .i64);
        return expectFloatResult(function, format);
    }
    if (operationIndex(&baseline_binary_i32_operations, operation) != null) {
        try expectArity(function, 2);
        try expectArgument(function, 0, .{ .float = format });
        try expectIntegerArgument(function, 1, .i32);
        return expectFloatResult(function, format);
    }
    if (std.mem.eql(u8, operation, "lgamma")) {
        try expectFloatArguments(function, 1, format);
        return expectStructureResult(function, .lgamma, format);
    }
    if (std.mem.eql(u8, operation, "frexp")) {
        try expectFloatArguments(function, 1, format);
        return expectStructureResult(function, .frexp, format);
    }
    if (std.mem.eql(u8, operation, "modf")) {
        try expectFloatArguments(function, 1, format);
        return expectStructureResult(function, .modf, format);
    }
    if (std.mem.eql(u8, operation, "remquo")) {
        try expectFloatArguments(function, 2, format);
        return expectStructureResult(function, .remquo, format);
    }
    if (std.mem.eql(u8, operation, "fma")) {
        try expectFloatArguments(function, 3, format);
        return expectFloatResult(function, format);
    }
    return error.UnexpectedOperationDescriptor;
}

fn expectIeeeDescriptor(function: corpus.Function) !void {
    if (std.mem.eql(u8, function.op, "nan")) {
        try expectArity(function, 1);
        try expectArgument(function, 0, .tag);
        const result_format = switch (function.result) {
            .float => |format| format,
            else => return error.UnexpectedResultDescriptor,
        };
        return expectFloatResult(function, result_format);
    }
    const format = try firstFloatArgument(function);
    if (std.mem.eql(u8, function.op, "canonicalize")) {
        try expectFloatArguments(function, 1, format);
        return expectStructureResult(function, .canonicalize, format);
    }
    if (std.mem.eql(u8, function.op, "copySign") or
        std.mem.eql(u8, function.op, "nextAfter"))
    {
        try expectFloatArguments(function, 2, format);
        return expectFloatResult(function, format);
    }
    if (std.mem.eql(u8, function.op, "nextToward")) {
        try expectArity(function, 2);
        try expectArgument(function, 0, .{ .float = format });
        try expectArgument(function, 1, .{ .float = .d });
        return expectFloatResult(function, format);
    }
    if (std.mem.eql(u8, function.op, "nextUp") or
        std.mem.eql(u8, function.op, "nextDown"))
    {
        try expectFloatArguments(function, 1, format);
        return expectFloatResult(function, format);
    }
    return error.UnexpectedOperationDescriptor;
}

fn expectAnnexFDescriptor(function: corpus.Function) !void {
    const format = try firstFloatArgument(function);
    if (std.mem.eql(u8, function.op, "totalOrder") or
        std.mem.eql(u8, function.op, "totalOrderMag"))
    {
        try expectFloatArguments(function, 2, format);
        return expectBooleanResult(function);
    }
    if (std.mem.eql(u8, function.op, "getPayload")) {
        try expectFloatArguments(function, 1, format);
        return expectFloatResult(function, format);
    }
    if (std.mem.eql(u8, function.op, "setPayload") or
        std.mem.eql(u8, function.op, "setPayloadSig"))
    {
        try expectFloatArguments(function, 1, format);
        return expectStructureResult(function, .payload, format);
    }
    return error.UnexpectedOperationDescriptor;
}

fn expectNarrowingDescriptor(
    function: corpus.Function,
    arity: u8,
    source: corpus.Format,
    destination: corpus.Format,
) !void {
    try expectFloatArguments(function, arity, source);
    try expectFloatResult(function, destination);
}

fn expectOperationCount(
    manifest: *const corpus.Manifest,
    provenance: corpus.Provenance,
    operation: []const u8,
    expected: usize,
) !void {
    var count: usize = 0;
    var functions = manifest.functions();
    while (try functions.next()) |function| {
        if (function.provenance.count == 1 and
            function.provenance.values[0] == provenance and
            std.mem.eql(u8, function.op, operation))
        {
            count += 1;
        }
    }
    try std.testing.expectEqual(expected, count);
}

test "v2 embedded registry covers the complete typed API matrix" {
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    try std.testing.expectEqual(@as(usize, 315), manifest.function_count);

    try std.testing.expectEqual(
        @as(usize, 85),
        baseline_unary_float_operations.len +
            baseline_unary_i64_operations.len +
            baseline_unary_i32_operations.len +
            baseline_fromfp_operations.len +
            baseline_binary_float_operations.len +
            baseline_binary_i64_operations.len +
            baseline_binary_i32_operations.len +
            baseline_unary_struct_operations.len +
            baseline_binary_struct_operations.len +
            baseline_ternary_float_operations.len,
    );

    var provenance_counts = [_]usize{ 0, 0, 0, 0 };
    var status_counts = [_]usize{ 0, 0, 0 };
    var functions = manifest.functions();
    while (try functions.next()) |function| {
        try std.testing.expectEqual(@as(usize, 1), function.provenance.count);
        const provenance = function.provenance.values[0];
        provenance_counts[@intFromEnum(provenance)] += 1;
        status_counts[@intFromEnum(function.status)] += 1;

        switch (provenance) {
            .c23_7_12 => {
                if (operationIndex(&legacy_narrowing_operations, function.op)) |index| {
                    const arity: u8 = if (index == 4) 3 else if (index == 5) 1 else 2;
                    try expectNarrowingDescriptor(function, arity, .d, .f);
                } else {
                    try expectBaselineDescriptor(function);
                }
            },
            .c23_ieee => try expectIeeeDescriptor(function),
            .annex_f => try expectAnnexFDescriptor(function),
            .annex_h => {
                const index = annexHIndex(function.op) orelse
                    return error.UnexpectedOperationDescriptor;
                const expected = annex_h_narrowing[index];
                try expectNarrowingDescriptor(
                    function,
                    expected.arity,
                    expected.source,
                    expected.destination,
                );
            },
        }

        switch (function.status) {
            .correct => {
                try std.testing.expectEqual(corpus.OracleCapability.mpfr_arb, function.oracle);
                try std.testing.expectEqual(@as(u64, 0), function.max_ulp);
                const format = try firstFloatArgument(function);
                if (std.mem.eql(u8, function.op, "exp")) {} else if (std.mem.eql(u8, function.op, "log") or
                    std.mem.eql(u8, function.op, "sin"))
                {
                    try std.testing.expectEqual(corpus.Format.h, format);
                } else {
                    return error.UnexpectedAcceptedOperation;
                }
            },
            .unsupported => {
                try std.testing.expectEqual(corpus.OracleCapability.none, function.oracle);
                try std.testing.expectEqual(@as(u64, 0), function.max_ulp);
            },
            .bounded => return error.UnexpectedBoundedRow,
        }
    }

    try std.testing.expectEqual(@as(usize, 261), provenance_counts[0]);
    try std.testing.expectEqual(@as(usize, 21), provenance_counts[1]);
    try std.testing.expectEqual(@as(usize, 15), provenance_counts[2]);
    try std.testing.expectEqual(@as(usize, 18), provenance_counts[3]);
    try std.testing.expectEqual(@as(usize, 310), status_counts[0]);
    try std.testing.expectEqual(@as(usize, 5), status_counts[1]);
    try std.testing.expectEqual(@as(usize, 0), status_counts[2]);

    for (baseline_unary_float_operations) |operation| {
        try expectOperationCount(&manifest, .c23_7_12, operation, 3);
    }
    for (baseline_unary_i64_operations) |operation| {
        try expectOperationCount(&manifest, .c23_7_12, operation, 3);
    }
    for (baseline_unary_i32_operations) |operation| {
        try expectOperationCount(&manifest, .c23_7_12, operation, 3);
    }
    for (baseline_fromfp_operations) |operation| {
        try expectOperationCount(&manifest, .c23_7_12, operation, 3);
    }
    for (baseline_binary_float_operations) |operation| {
        try expectOperationCount(&manifest, .c23_7_12, operation, 3);
    }
    for (baseline_binary_i64_operations) |operation| {
        try expectOperationCount(&manifest, .c23_7_12, operation, 3);
    }
    for (baseline_binary_i32_operations) |operation| {
        try expectOperationCount(&manifest, .c23_7_12, operation, 3);
    }
    for (baseline_unary_struct_operations) |operation| {
        try expectOperationCount(&manifest, .c23_7_12, operation, 3);
    }
    for (baseline_binary_struct_operations) |operation| {
        try expectOperationCount(&manifest, .c23_7_12, operation, 3);
    }
    for (baseline_ternary_float_operations) |operation| {
        try expectOperationCount(&manifest, .c23_7_12, operation, 3);
    }
    for (legacy_narrowing_operations) |operation| {
        try expectOperationCount(&manifest, .c23_7_12, operation, 1);
    }
    for (ieee_operations) |operation| {
        try expectOperationCount(&manifest, .c23_ieee, operation, 3);
    }
    for (annex_f_operations) |operation| {
        try expectOperationCount(&manifest, .annex_f, operation, 3);
    }
    for (annex_h_narrowing) |expected| {
        try expectOperationCount(&manifest, .annex_h, expected.operation, 1);
    }
}

test "v2 ModfResult oracle descriptors preserve both float fields" {
    const result = corpus.ResultDescriptor{
        .structure = .{ .kind = .modf, .format = .f },
    };
    const fractional = result.oracleFieldDescriptor(0) orelse
        return error.MissingOracleFieldDescriptor;
    const integral = result.oracleFieldDescriptor(1) orelse
        return error.MissingOracleFieldDescriptor;
    const float_argument = corpus.ArgumentDescriptor{ .float = .f };
    const expected = float_argument.oracleDescriptor();

    try std.testing.expectEqual(corpus.OracleFieldKind.float, fractional.kind);
    try std.testing.expectEqual(corpus.OracleFormat.f, fractional.format.code);
    try std.testing.expect(oracleFieldDescriptorsMatch(expected, fractional));

    try std.testing.expectEqual(corpus.OracleFieldKind.float, integral.kind);
    try std.testing.expectEqual(corpus.OracleFormat.f, integral.format.code);
    try std.testing.expect(oracleFieldDescriptorsMatch(expected, integral));

    const mismatched_integral = corpus.IntegerType.i32.oracleDescriptor();
    try std.testing.expect(!oracleFieldDescriptorsMatch(mismatched_integral, integral));
}

test "v2 LgammaResult oracle descriptors preserve value and sign types" {
    const result = corpus.ResultDescriptor{
        .structure = .{ .kind = .lgamma, .format = .d },
    };
    const value = result.oracleFieldDescriptor(0) orelse
        return error.MissingOracleFieldDescriptor;
    const sign = result.oracleFieldDescriptor(1) orelse
        return error.MissingOracleFieldDescriptor;
    const value_argument = corpus.ArgumentDescriptor{ .float = .d };
    const expected_value = value_argument.oracleDescriptor();
    const expected_sign = corpus.IntegerType.i2.oracleDescriptor();

    try std.testing.expectEqual(corpus.OracleFieldKind.float, value.kind);
    try std.testing.expectEqual(corpus.OracleFormat.d, value.format.code);
    try std.testing.expect(oracleFieldDescriptorsMatch(expected_value, value));

    try std.testing.expectEqual(corpus.OracleFieldKind.signed_integer, sign.kind);
    try std.testing.expectEqual(@as(u32, 2), sign.value_bits);
    try std.testing.expectEqual(corpus.OracleFormat.none, sign.format.code);
    try std.testing.expect(oracleFieldDescriptorsMatch(expected_sign, sign));

    try std.testing.expect(!oracleFieldDescriptorsMatch(expected_value, sign));
}

test "v2 parses mixed arity formats and result descriptors" {
    const source = manifest_prefix ++
        "[[function]]\n" ++
        "op = \"fromFpd\"\n" ++
        "provenance = [\"c23_7_12\"]\n" ++
        "status = \"unsupported\"\n" ++
        "arity = 3\n" ++
        "inputs = [\"float:d\", \"fromfp_round\", \"integer:u32\"]\n" ++
        "result = \"float:d\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n\n" ++
        "[[function]]\n" ++
        "op = \"frexpf\"\n" ++
        "provenance = [\"c23_7_12\", \"annex_f\"]\n" ++
        "status = \"unsupported\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float:f\"]\n" ++
        "result = \"struct:frexp:f\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n\n" ++
        "[[function]]\n" ++
        "op = \"lrintd\"\n" ++
        "provenance = [\"c23_7_12\", \"annex_f\"]\n" ++
        "status = \"unsupported\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float:d\"]\n" ++
        "result = \"integer:i64\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n\n" ++
        "[[function]]\n" ++
        "op = \"remquod\"\n" ++
        "provenance = [\"c23_7_12\", \"annex_f\"]\n" ++
        "status = \"unsupported\"\n" ++
        "arity = 2\n" ++
        "inputs = [\"float:d\", \"float:d\"]\n" ++
        "result = \"struct:remquo:d\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n\n" ++
        "[[function]]\n" ++
        "op = \"canonicalizeh\"\n" ++
        "provenance = [\"c23_ieee\"]\n" ++
        "status = \"unsupported\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float:h\"]\n" ++
        "result = \"struct:canonicalize:h\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n\n" ++
        "[[function]]\n" ++
        "op = \"isCanonicald\"\n" ++
        "provenance = [\"c23_ieee\"]\n" ++
        "status = \"unsupported\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float:d\"]\n" ++
        "result = \"bool\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n\n" ++
        "[[function]]\n" ++
        "op = \"nan\"\n" ++
        "provenance = [\"c23_ieee\"]\n" ++
        "status = \"unsupported\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"tag\"]\n" ++
        "result = \"float:d\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n\n" ++
        "[[function]]\n" ++
        "op = \"nextTowardh\"\n" ++
        "provenance = [\"c23_ieee\"]\n" ++
        "status = \"unsupported\"\n" ++
        "arity = 2\n" ++
        "inputs = [\"float:h\", \"float:d\"]\n" ++
        "result = \"float:h\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n\n" ++
        "[[function]]\n" ++
        "op = \"setPayloadf\"\n" ++
        "provenance = [\"annex_f\"]\n" ++
        "status = \"unsupported\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float:f\"]\n" ++
        "result = \"struct:payload:f\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n";

    const manifest = try corpus.parseManifest(source);
    try std.testing.expectEqual(@as(usize, 9), manifest.function_count);

    var functions = manifest.functions();
    const from_fp = (try functions.next()).?;
    try std.testing.expectEqual(@as(u8, 3), from_fp.arity);
    try std.testing.expectEqual(corpus.Format.d, try scalarArgument(from_fp, 0));
    switch (from_fp.inputs.slice()[1]) {
        .fromfp_round => {},
        else => return error.UnexpectedArgumentDescriptor,
    }
    switch (from_fp.inputs.slice()[2]) {
        .integer => |integer| try std.testing.expectEqual(corpus.IntegerType.u32, integer),
        else => return error.UnexpectedArgumentDescriptor,
    }

    const frexp = (try functions.next()).?;
    const frexp_result = try structResult(frexp);
    try std.testing.expectEqual(corpus.StructKind.frexp, frexp_result.kind);
    try std.testing.expectEqual(corpus.Format.f, frexp_result.format);

    const lrint = (try functions.next()).?;
    switch (lrint.result) {
        .integer => |integer| try std.testing.expectEqual(corpus.IntegerType.i64, integer),
        else => return error.UnexpectedResultDescriptor,
    }

    const remquo = (try functions.next()).?;
    const remquo_result = try structResult(remquo);
    try std.testing.expectEqual(corpus.StructKind.remquo, remquo_result.kind);
    try std.testing.expectEqual(corpus.Format.d, remquo_result.format);

    const canonicalize = (try functions.next()).?;
    const canonicalize_result = try structResult(canonicalize);
    try std.testing.expectEqual(corpus.StructKind.canonicalize, canonicalize_result.kind);
    try std.testing.expectEqual(corpus.Format.h, canonicalize_result.format);

    const is_canonical = (try functions.next()).?;
    switch (is_canonical.result) {
        .boolean => {},
        else => return error.UnexpectedResultDescriptor,
    }

    const nan = (try functions.next()).?;
    switch (nan.inputs.slice()[0]) {
        .tag => {},
        else => return error.UnexpectedArgumentDescriptor,
    }

    const next_toward = (try functions.next()).?;
    try std.testing.expectEqual(corpus.Format.h, try scalarArgument(next_toward, 0));
    try std.testing.expectEqual(corpus.Format.d, try scalarArgument(next_toward, 1));

    const payload = (try functions.next()).?;
    const payload_result = try structResult(payload);
    try std.testing.expectEqual(corpus.StructKind.payload, payload_result.kind);
    try std.testing.expectEqual(corpus.Format.f, payload_result.format);
    try std.testing.expect((try functions.next()) == null);
}

test "v2 parses unsupported correct and bounded statuses" {
    const source = manifest_prefix ++
        "[[function]]\n" ++
        "op = \"exampleBounded\"\n" ++
        "provenance = [\"c23_7_12\"]\n" ++
        "status = \"bounded\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float:f\"]\n" ++
        "result = \"float:f\"\n" ++
        "oracle = \"mpfr_arb\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 2\n\n" ++
        "[[function]]\n" ++
        "op = \"exampleCorrect\"\n" ++
        "provenance = [\"c23_7_12\"]\n" ++
        "status = \"correct\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float:f\"]\n" ++
        "result = \"float:f\"\n" ++
        "oracle = \"mpfr_arb\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n\n" ++
        "[[function]]\n" ++
        "op = \"exampleUnsupported\"\n" ++
        "provenance = [\"c23_7_12\"]\n" ++
        "status = \"unsupported\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float:f\"]\n" ++
        "result = \"float:f\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n";

    const manifest = try corpus.parseManifest(source);
    var functions = manifest.functions();
    const bounded = (try functions.next()).?;
    try std.testing.expectEqual(corpus.Status.bounded, bounded.status);
    try std.testing.expectEqual(@as(u64, 2), bounded.max_ulp);
    try std.testing.expectEqual(corpus.Status.correct, (try functions.next()).?.status);
    try std.testing.expectEqual(corpus.Status.unsupported, (try functions.next()).?.status);
}

test "v2 rejects accepted rows without mpfr arb evidence" {
    const correct_without_arb = manifest_prefix ++
        "[[function]]\n" ++
        "op = \"exampleCorrect\"\n" ++
        "provenance = [\"c23_7_12\"]\n" ++
        "status = \"correct\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float:f\"]\n" ++
        "result = \"float:f\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n";
    try std.testing.expectError(
        error.StatusOracleMismatch,
        corpus.parseManifest(correct_without_arb),
    );

    const bounded_without_arb = manifest_prefix ++
        "[[function]]\n" ++
        "op = \"exampleBounded\"\n" ++
        "provenance = [\"c23_7_12\"]\n" ++
        "status = \"bounded\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float:f\"]\n" ++
        "result = \"float:f\"\n" ++
        "oracle = \"mpfr\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 2\n";
    try std.testing.expectError(
        error.StatusOracleMismatch,
        corpus.parseManifest(bounded_without_arb),
    );
}

test "v2 rejects oracle evidence for unsupported rows" {
    const unsupported_with_mpfr_arb = manifest_prefix ++
        "[[function]]\n" ++
        "op = \"exampleUnsupported\"\n" ++
        "provenance = [\"c23_7_12\"]\n" ++
        "status = \"unsupported\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float:f\"]\n" ++
        "result = \"float:f\"\n" ++
        "oracle = \"mpfr_arb\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n";
    try std.testing.expectError(
        error.StatusOracleMismatch,
        corpus.parseManifest(unsupported_with_mpfr_arb),
    );
}

test "v2 rejects unknown function fields" {
    const source = manifest_prefix ++ scalar_row ++ "mystery = \"value\"\n";
    try std.testing.expectError(error.UnknownFunctionKey, corpus.parseManifest(source));
}

test "v2 rejects malformed descriptors" {
    const source = manifest_prefix ++
        "[[function]]\n" ++
        "op = \"sample\"\n" ++
        "provenance = [\"c23_7_12\"]\n" ++
        "status = \"unsupported\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float\"]\n" ++
        "result = \"float:h\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n";
    try std.testing.expectError(error.MalformedDescriptor, corpus.parseManifest(source));
}

test "v2 rejects duplicate fields and signatures" {
    const duplicate_field = manifest_prefix ++
        "[[function]]\n" ++
        "op = \"sample\"\n" ++
        "op = \"sampleAgain\"\n" ++
        "provenance = [\"c23_7_12\"]\n" ++
        "status = \"unsupported\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float:h\"]\n" ++
        "result = \"float:h\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n";
    try std.testing.expectError(
        error.DuplicateFunctionKey,
        corpus.parseManifest(duplicate_field),
    );

    const duplicate_signature = manifest_prefix ++ scalar_row ++ "\n" ++ scalar_row;
    try std.testing.expectError(
        error.DuplicateFunctionRow,
        corpus.parseManifest(duplicate_signature),
    );

    const duplicate_identity = manifest_prefix ++ scalar_row ++ "\n" ++
        "[[function]]\n" ++
        "op = \"sample\"\n" ++
        "provenance = [\"c23_7_12\"]\n" ++
        "status = \"correct\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float:h\"]\n" ++
        "result = \"float:h\"\n" ++
        "oracle = \"mpfr_arb\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n";
    try std.testing.expectError(
        error.DuplicateFunctionRow,
        corpus.parseManifest(duplicate_identity),
    );
}

test "v2 rejects invalid and prohibited formats" {
    const unknown = manifest_prefix ++
        "[[function]]\n" ++
        "op = \"sample\"\n" ++
        "provenance = [\"c23_7_12\"]\n" ++
        "status = \"unsupported\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float:x\"]\n" ++
        "result = \"float:h\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n";
    try std.testing.expectError(error.UnknownFormat, corpus.parseManifest(unknown));

    const reserved = manifest_prefix ++
        "[[function]]\n" ++
        "op = \"sample\"\n" ++
        "provenance = [\"c23_7_12\"]\n" ++
        "status = \"unsupported\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float:q\"]\n" ++
        "result = \"float:h\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n";
    try std.testing.expectError(error.ReservedFormat, corpus.parseManifest(reserved));

    const rejected = manifest_prefix ++
        "[[function]]\n" ++
        "op = \"sample\"\n" ++
        "provenance = [\"c23_7_12\"]\n" ++
        "status = \"unsupported\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float:bfloat16\"]\n" ++
        "result = \"float:h\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n";
    try std.testing.expectError(error.RejectedFormat, corpus.parseManifest(rejected));
}

test "v2 rejects out-of-order fields and rows" {
    const field_order = manifest_prefix ++
        "[[function]]\n" ++
        "op = \"sample\"\n" ++
        "arity = 1\n" ++
        "provenance = [\"c23_7_12\"]\n" ++
        "status = \"unsupported\"\n" ++
        "inputs = [\"float:h\"]\n" ++
        "result = \"float:h\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n";
    try std.testing.expectError(error.UnsortedFunctionKey, corpus.parseManifest(field_order));

    const row_order = manifest_prefix ++
        "[[function]]\n" ++
        "op = \"zeta\"\n" ++
        "provenance = [\"c23_7_12\"]\n" ++
        "status = \"unsupported\"\n" ++
        "arity = 1\n" ++
        "inputs = [\"float:h\"]\n" ++
        "result = \"float:h\"\n" ++
        "oracle = \"none\"\n" ++
        "special_policy = \"zmath_c23_v1\"\n" ++
        "max_ulp = 0\n\n" ++
        scalar_row;
    try std.testing.expectError(error.UnsortedFunctionRow, corpus.parseManifest(row_order));
}

fn expectCorpusFieldEqual(
    expected: corpus.CorpusField,
    actual: corpus.CorpusField,
) !void {
    switch (expected) {
        .float => |expected_float| switch (actual) {
            .float => |actual_float| try std.testing.expectEqualDeep(
                expected_float,
                actual_float,
            ),
            else => return error.UnexpectedCorpusField,
        },
        .signed_integer => |expected_integer| switch (actual) {
            .signed_integer => |actual_integer| try std.testing.expectEqualDeep(
                expected_integer,
                actual_integer,
            ),
            else => return error.UnexpectedCorpusField,
        },
        .unsigned_integer => |expected_integer| switch (actual) {
            .unsigned_integer => |actual_integer| try std.testing.expectEqualDeep(
                expected_integer,
                actual_integer,
            ),
            else => return error.UnexpectedCorpusField,
        },
        .boolean => |expected_boolean| switch (actual) {
            .boolean => |actual_boolean| try std.testing.expectEqual(
                expected_boolean,
                actual_boolean,
            ),
            else => return error.UnexpectedCorpusField,
        },
        .tag => |expected_tag| switch (actual) {
            .tag => |actual_tag| try std.testing.expectEqualSlices(
                u8,
                expected_tag,
                actual_tag,
            ),
            else => return error.UnexpectedCorpusField,
        },
        .rounding => |expected_rounding| switch (actual) {
            .rounding => |actual_rounding| try std.testing.expectEqual(
                expected_rounding,
                actual_rounding,
            ),
            else => return error.UnexpectedCorpusField,
        },
    }
}

fn expectCorpusRecordEqual(
    expected: *const corpus.CorpusRecord,
    actual: *const corpus.CorpusRecord,
) !void {
    try std.testing.expectEqualSlices(u8, expected.operation, actual.operation);
    try std.testing.expectEqualSlices(
        corpus.Provenance,
        expected.provenance.slice(),
        actual.provenance.slice(),
    );
    try std.testing.expectEqualDeep(expected.result_descriptor, actual.result_descriptor);
    try std.testing.expectEqual(expected.max_ulp, actual.max_ulp);
    try std.testing.expectEqual(expected.arguments.count, actual.arguments.count);
    for (expected.arguments.slice(), actual.arguments.slice()) |expected_field, actual_field| {
        try expectCorpusFieldEqual(expected_field, actual_field);
    }
    try std.testing.expectEqual(expected.results.count, actual.results.count);
    for (expected.results.slice(), actual.results.slice()) |expected_field, actual_field| {
        try expectCorpusFieldEqual(expected_field, actual_field);
    }
}

fn expectCorpusRecordRoundTrip(record: *const corpus.CorpusRecord) !void {
    var storage: [2048]u8 = undefined;
    const encoded = try corpus.encodeCorpusRecord(record, &storage);
    try std.testing.expectEqual(
        try corpus.corpusRecordEncodedLength(record),
        encoded.len,
    );
    const decoded = try corpus.decodeCorpusRecord(encoded);
    try expectCorpusRecordEqual(record, &decoded);
}

fn ternaryOrderRecord(
    second_bits: u64,
    third_bits: u64,
    result_bits: u64,
) !corpus.CorpusRecord {
    const provenance = [_]corpus.Provenance{.c23_7_12};
    const arguments = [_]corpus.CorpusField{
        .{ .float = .{ .format = .h, .bits = 0x3c00, .class = .none } },
        .{ .float = .{ .format = .h, .bits = second_bits, .class = .none } },
        .{ .float = .{ .format = .h, .bits = third_bits, .class = .none } },
    };
    const results = [_]corpus.CorpusField{
        .{ .float = .{ .format = .h, .bits = result_bits, .class = .normal } },
    };
    return corpus.CorpusRecord.init(.{
        .operation = "fma",
        .provenance = &provenance,
        .arguments = &arguments,
        .result_descriptor = .{ .float = .h },
        .results = &results,
        .max_ulp = 0,
    });
}

test "descriptor record codec round trips scalar fields and tag spans" {
    const provenance = [_]corpus.Provenance{ .c23_7_12, .c23_ieee };
    const tag = [_]u8{ 'a', 0, 0xff, '9' };
    const arguments = [_]corpus.CorpusField{
        .{ .float = .{
            .format = .d,
            .bits = 0x3ff0_0000_0000_0000,
            .class = .none,
        } },
        .{ .signed_integer = .{ .integer_type = .i2, .value = -1 } },
        .{ .unsigned_integer = .{ .integer_type = .u32, .value = 31 } },
        .{ .tag = &tag },
        .{ .rounding = .toward_negative },
    };
    const results = [_]corpus.CorpusField{.{ .boolean = true }};
    const record = try corpus.CorpusRecord.init(.{
        .operation = "mixed_fields",
        .provenance = &provenance,
        .arguments = &arguments,
        .result_descriptor = .{ .boolean = {} },
        .results = &results,
        .max_ulp = 0,
    });

    try expectCorpusRecordRoundTrip(&record);
}

test "descriptor record codec round trips binary ternary and narrowing records" {
    const provenance = [_]corpus.Provenance{.annex_h};
    const binary_arguments = [_]corpus.CorpusField{
        .{ .float = .{
            .format = .d,
            .bits = 0x3ff0_0000_0000_0000,
            .class = .none,
        } },
        .{ .float = .{
            .format = .d,
            .bits = 0x4000_0000_0000_0000,
            .class = .none,
        } },
    };
    const binary_results = [_]corpus.CorpusField{
        .{ .float = .{ .format = .f, .bits = 0x4040_0000, .class = .normal } },
    };
    const binary = try corpus.CorpusRecord.init(.{
        .operation = "fadd",
        .provenance = &provenance,
        .arguments = &binary_arguments,
        .result_descriptor = .{ .float = .f },
        .results = &binary_results,
        .max_ulp = 0,
    });
    try expectCorpusRecordRoundTrip(&binary);

    const ternary_arguments = [_]corpus.CorpusField{
        .{ .float = .{ .format = .f, .bits = 0x3f80_0000, .class = .none } },
        .{ .float = .{ .format = .f, .bits = 0x4000_0000, .class = .none } },
        .{ .float = .{ .format = .f, .bits = 0x4040_0000, .class = .none } },
    };
    const ternary_results = [_]corpus.CorpusField{
        .{ .float = .{ .format = .h, .bits = 0x4500, .class = .normal } },
    };
    const ternary = try corpus.CorpusRecord.init(.{
        .operation = "f16fmaf32",
        .provenance = &provenance,
        .arguments = &ternary_arguments,
        .result_descriptor = .{ .float = .h },
        .results = &ternary_results,
        .max_ulp = 0,
    });
    try expectCorpusRecordRoundTrip(&ternary);
}

test "descriptor record codec round trips all nine structures" {
    const cases = [_]struct {
        operation: []const u8,
        kind: corpus.StructKind,
    }{
        .{ .operation = "canonicalize", .kind = .canonicalize },
        .{ .operation = "frexp", .kind = .frexp },
        .{ .operation = "modf", .kind = .modf },
        .{ .operation = "remquo", .kind = .remquo },
        .{ .operation = "lgamma", .kind = .lgamma },
        .{ .operation = "payload", .kind = .payload },
        .{ .operation = "atan2", .kind = .atan2 },
        .{ .operation = "power", .kind = .power },
        .{ .operation = "integer", .kind = .integer },
    };
    const provenance = [_]corpus.Provenance{.c23_7_12};
    const arguments = [_]corpus.CorpusField{
        .{ .float = .{ .format = .f, .bits = 0x3f80_0000, .class = .none } },
    };

    for (cases) |case| {
        var result_fields: [2]corpus.CorpusField = undefined;
        switch (case.kind) {
            .canonicalize, .payload, .atan2, .power => {
                result_fields = .{
                    .{ .float = .{
                        .format = .f,
                        .bits = 0x3f80_0000,
                        .class = .normal,
                    } },
                    .{ .boolean = true },
                };
            },
            .frexp, .remquo => {
                result_fields = .{
                    .{ .float = .{
                        .format = .f,
                        .bits = 0x3f00_0000,
                        .class = .normal,
                    } },
                    .{ .signed_integer = .{ .integer_type = .i32, .value = -2 } },
                };
            },
            .modf => {
                result_fields = .{
                    .{ .float = .{
                        .format = .f,
                        .bits = 0x3f00_0000,
                        .class = .normal,
                    } },
                    .{ .float = .{
                        .format = .f,
                        .bits = 0x3f80_0000,
                        .class = .normal,
                    } },
                };
            },
            .lgamma => {
                result_fields = .{
                    .{ .float = .{
                        .format = .f,
                        .bits = 0x3f80_0000,
                        .class = .normal,
                    } },
                    .{ .signed_integer = .{ .integer_type = .i2, .value = -1 } },
                };
            },
            .integer => {
                result_fields = .{
                    .{ .signed_integer = .{ .integer_type = .i64, .value = -7 } },
                    .{ .boolean = true },
                };
            },
        }
        const record = try corpus.CorpusRecord.init(.{
            .operation = case.operation,
            .provenance = &provenance,
            .arguments = &arguments,
            .result_descriptor = .{
                .structure = .{ .kind = case.kind, .format = .f },
            },
            .results = &result_fields,
            .max_ulp = 0,
        });
        try expectCorpusRecordRoundTrip(&record);
    }
}

test "descriptor record codec rejects malformed records and field values" {
    const provenance = [_]corpus.Provenance{.c23_7_12};
    const arguments = [_]corpus.CorpusField{
        .{ .float = .{ .format = .h, .bits = 0x3c00, .class = .none } },
    };
    const results = [_]corpus.CorpusField{
        .{ .float = .{ .format = .h, .bits = 0x3c00, .class = .normal } },
    };
    const record = try corpus.CorpusRecord.init(.{
        .operation = "malformed",
        .provenance = &provenance,
        .arguments = &arguments,
        .result_descriptor = .{ .float = .h },
        .results = &results,
        .max_ulp = 0,
    });

    var storage: [512]u8 = undefined;
    const encoded = try corpus.encodeCorpusRecord(&record, &storage);

    var unknown_version: [512]u8 = undefined;
    @memcpy(unknown_version[0..encoded.len], encoded);
    unknown_version[4] = corpus.descriptor_corpus_codec_version + 1;
    try std.testing.expectError(
        error.UnknownRecordVersion,
        corpus.decodeCorpusRecord(unknown_version[0..encoded.len]),
    );
    try std.testing.expectError(
        error.TruncatedRecord,
        corpus.decodeCorpusRecord(encoded[0 .. encoded.len - 1]),
    );

    var trailing: [513]u8 = undefined;
    @memcpy(trailing[0..encoded.len], encoded);
    trailing[encoded.len] = 0;
    try std.testing.expectError(
        error.TrailingRecordBytes,
        corpus.decodeCorpusRecord(trailing[0 .. encoded.len + 1]),
    );

    const provenance_offset = corpus.descriptor_record_header_length + record.operation.len;
    var unknown_provenance: [512]u8 = undefined;
    @memcpy(unknown_provenance[0..encoded.len], encoded);
    unknown_provenance[provenance_offset] = 0xff;
    try std.testing.expectError(
        error.UnknownProvenance,
        corpus.decodeCorpusRecord(unknown_provenance[0..encoded.len]),
    );

    const first_field_offset = corpus.descriptor_record_header_length +
        record.operation.len + record.provenance.count;
    var unknown_kind: [512]u8 = undefined;
    @memcpy(unknown_kind[0..encoded.len], encoded);
    unknown_kind[first_field_offset] = 0xff;
    try std.testing.expectError(
        error.UnknownFieldKind,
        corpus.decodeCorpusRecord(unknown_kind[0..encoded.len]),
    );

    var unknown_integer: [512]u8 = undefined;
    @memcpy(unknown_integer[0..encoded.len], encoded);
    unknown_integer[first_field_offset] = 1;
    unknown_integer[first_field_offset + 3] = 0xff;
    try std.testing.expectError(
        error.UnknownIntegerType,
        corpus.decodeCorpusRecord(unknown_integer[0..encoded.len]),
    );

    var unknown_structure: [512]u8 = undefined;
    @memcpy(unknown_structure[0..encoded.len], encoded);
    unknown_structure[corpus.descriptor_record_header_length - 4] = 3;
    unknown_structure[corpus.descriptor_record_header_length - 2] = 0xff;
    unknown_structure[corpus.descriptor_record_header_length - 1] = 0;
    try std.testing.expectError(
        error.UnknownStructureKind,
        corpus.decodeCorpusRecord(unknown_structure[0..encoded.len]),
    );

    var unknown_format: [512]u8 = undefined;
    @memcpy(unknown_format[0..encoded.len], encoded);
    unknown_format[first_field_offset + 1] = 0xff;
    try std.testing.expectError(
        error.UnknownFormat,
        corpus.decodeCorpusRecord(unknown_format[0..encoded.len]),
    );

    var unknown_class: [512]u8 = undefined;
    @memcpy(unknown_class[0..encoded.len], encoded);
    unknown_class[first_field_offset + 2] = 0xff;
    try std.testing.expectError(
        error.UnknownFieldClass,
        corpus.decodeCorpusRecord(unknown_class[0..encoded.len]),
    );

    const bad_class_results = [_]corpus.CorpusField{
        .{ .float = .{ .format = .h, .bits = 0x3c00, .class = .zero } },
    };
    try std.testing.expectError(
        error.InvalidFieldClass,
        corpus.CorpusRecord.init(.{
            .operation = "bad_class",
            .provenance = &provenance,
            .arguments = &arguments,
            .result_descriptor = .{ .float = .h },
            .results = &bad_class_results,
            .max_ulp = 0,
        }),
    );

    const bad_integer_arguments = [_]corpus.CorpusField{
        .{ .signed_integer = .{ .integer_type = .i2, .value = 2 } },
    };
    try std.testing.expectError(
        error.IntegerOutOfRange,
        corpus.CorpusRecord.init(.{
            .operation = "bad_integer",
            .provenance = &provenance,
            .arguments = &bad_integer_arguments,
            .result_descriptor = .{ .boolean = {} },
            .results = &[_]corpus.CorpusField{.{ .boolean = false }},
            .max_ulp = 0,
        }),
    );

    const bad_structure_results = [_]corpus.CorpusField{
        .{ .float = .{ .format = .h, .bits = 0x3c00, .class = .normal } },
        .{ .boolean = true },
    };
    try std.testing.expectError(
        error.ResultFieldMismatch,
        corpus.CorpusRecord.init(.{
            .operation = "bad_structure",
            .provenance = &provenance,
            .arguments = &arguments,
            .result_descriptor = .{
                .structure = .{ .kind = .lgamma, .format = .h },
            },
            .results = &bad_structure_results,
            .max_ulp = 0,
        }),
    );
}

test "descriptor record ordering includes every input and rejects duplicate keys" {
    const first = try ternaryOrderRecord(0x3c00, 0x3c00, 0x4200);
    const second = try ternaryOrderRecord(0x3c01, 0x3c00, 0x4201);
    const third = try ternaryOrderRecord(0x3c01, 0x3c01, 0x4202);
    const duplicate = try ternaryOrderRecord(0x3c01, 0x3c01, 0x7bff);

    try corpus.validateCorpusRecordOrder(&first, &second);
    try corpus.validateCorpusRecordOrder(&second, &third);
    try std.testing.expectError(
        error.UnsortedCorpusRecord,
        corpus.validateCorpusRecordOrder(&third, &second),
    );
    try std.testing.expectError(
        error.DuplicateCorpusRecord,
        corpus.validateCorpusRecordOrder(&third, &duplicate),
    );

    var sorted_storage: [4096]u8 = undefined;
    var sorted_length: usize = 0;
    for ([_]corpus.CorpusRecord{ first, second, third }) |record| {
        const encoded = try corpus.encodeCorpusRecord(
            &record,
            sorted_storage[sorted_length..],
        );
        sorted_length += encoded.len;
    }
    var records = corpus.corpusRecords(sorted_storage[0..sorted_length]);
    try std.testing.expect((try records.next()) != null);
    try std.testing.expect((try records.next()) != null);
    try std.testing.expect((try records.next()) != null);
    try std.testing.expect((try records.next()) == null);

    var unsorted_storage: [2048]u8 = undefined;
    const encoded_third = try corpus.encodeCorpusRecord(&third, &unsorted_storage);
    const encoded_second = try corpus.encodeCorpusRecord(
        &second,
        unsorted_storage[encoded_third.len..],
    );
    var unsorted = corpus.corpusRecords(
        unsorted_storage[0 .. encoded_third.len + encoded_second.len],
    );
    try std.testing.expect((try unsorted.next()) != null);
    try std.testing.expectError(error.UnsortedCorpusRecord, unsorted.next());

    var duplicate_storage: [2048]u8 = undefined;
    const encoded_third_duplicate = try corpus.encodeCorpusRecord(
        &third,
        &duplicate_storage,
    );
    const encoded_duplicate = try corpus.encodeCorpusRecord(
        &duplicate,
        duplicate_storage[encoded_third_duplicate.len..],
    );
    var duplicates = corpus.corpusRecords(
        duplicate_storage[0 .. encoded_third_duplicate.len + encoded_duplicate.len],
    );
    try std.testing.expect((try duplicates.next()) != null);
    try std.testing.expectError(error.DuplicateCorpusRecord, duplicates.next());
}

test "scalar TSV version two remains compatibility-only" {
    try std.testing.expectEqual(
        @as(u8, 2),
        corpus.scalar_tsv_compatibility_version,
    );
    try corpus.validateScalarTsvV2(
        "op\tinput_format\toutput_format\tinput_bits\toutput_bits\toutput_class\tmax_ulp\n" ++
            "exp\th\th\t0000\t3c00\tnormal\t0\n",
    );
    try std.testing.expectError(
        error.InvalidHeader,
        corpus.validateScalarTsvV2(
            "op\targuments\tresults\n" ++
                "fma\t[3c00,3c00,3c00]\t[4200]\n",
        ),
    );
}
