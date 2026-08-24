const std = @import("std");
const corpus = @import("corpus_support");
const c = @cImport({
    @cInclude("oracle_evaluators.h");
});

const exact_c23_operations = [_][]const u8{
    "abs",
    "ceil",
    "fdim",
    "floor",
    "fmax",
    "fmaximum",
    "fmaximum_mag",
    "fmaximum_mag_num",
    "fmaximum_num",
    "fmin",
    "fminimum",
    "fminimum_mag",
    "fminimum_mag_num",
    "fminimum_num",
    "fmod",
    "frexp",
    "fromfp",
    "fromfpx",
    "ilogb",
    "ldexp",
    "llogb",
    "llrint",
    "llround",
    "logb",
    "lrint",
    "lround",
    "modf",
    "nearbyint",
    "remainder",
    "remquo",
    "rint",
    "round",
    "roundeven",
    "scalbln",
    "scalbn",
    "trunc",
    "ufromfp",
    "ufromfpx",
};

const algebraic_c23_operations = [_][]const u8{
    "cbrt",
    "fadd",
    "fdiv",
    "ffma",
    "fma",
    "fmul",
    "fsqrt",
    "fsub",
    "hypot",
    "rsqrt",
    "sqrt",
};

const legacy_narrowing_operations = [_][]const u8{
    "fadd",
    "fdiv",
    "ffma",
    "fmul",
    "fsqrt",
    "fsub",
};

fn operationIn(operations: []const []const u8, operation: []const u8) bool {
    for (operations) |candidate| {
        if (std.mem.eql(u8, candidate, operation)) return true;
    }
    return false;
}

fn tableOperation(signature: *const c.zmath_testing_oracle_operation_signature) []const u8 {
    std.debug.assert(signature.operation != null);
    const operation_pointer: [*]const u8 = @ptrCast(signature.operation);
    return operation_pointer[0..@intCast(signature.operation_length)];
}

fn expectedProvenance(provenance: corpus.Provenance) u32 {
    return switch (provenance) {
        .c23_7_12 => c.ZMATH_TESTING_ORACLE_PROVENANCE_C23_7_12,
        .c23_ieee => c.ZMATH_TESTING_ORACLE_PROVENANCE_C23_IEEE,
        .annex_f => c.ZMATH_TESTING_ORACLE_PROVENANCE_ANNEX_F,
        .annex_h => c.ZMATH_TESTING_ORACLE_PROVENANCE_ANNEX_H,
    };
}

fn expectedCategory(function: *const corpus.Function) u32 {
    const provenance = function.provenance.values[0];
    return switch (provenance) {
        .c23_ieee, .annex_f => c.ZMATH_TESTING_ORACLE_EVALUATOR_EXACT_BITS,
        .annex_h => c.ZMATH_TESTING_ORACLE_EVALUATOR_ALGEBRAIC,
        .c23_7_12 => if (operationIn(&exact_c23_operations, function.op))
            c.ZMATH_TESTING_ORACLE_EVALUATOR_EXACT_BITS
        else if (operationIn(&algebraic_c23_operations, function.op))
            c.ZMATH_TESTING_ORACLE_EVALUATOR_ALGEBRAIC
        else
            c.ZMATH_TESTING_ORACLE_EVALUATOR_MPFR_ARB,
    };
}

fn expectFieldDescriptor(
    actual: c.zmath_testing_oracle_field_descriptor,
    expected: corpus.OracleFieldDescriptor,
) !void {
    try std.testing.expectEqual(@as(u32, @intFromEnum(expected.kind)), actual.kind);
    try std.testing.expectEqual(expected.value_bits, actual.value_bits);
    try std.testing.expectEqual(@as(u32, @intFromEnum(expected.format.code)), actual.format.code);
    try std.testing.expectEqual(expected.format.storage_bits, actual.format.storage_bits);
    try std.testing.expectEqual(expected.format.exponent_bits, actual.format.exponent_bits);
    try std.testing.expectEqual(expected.format.fraction_bits, actual.format.fraction_bits);
    try std.testing.expectEqual(@as(u32, 0), actual.format.reserved);
    try std.testing.expectEqual(@as(u32, 0), actual.reserved);
}

fn provenanceIndex(provenance: u32) ?usize {
    if (provenance == c.ZMATH_TESTING_ORACLE_PROVENANCE_C23_7_12) return 0;
    if (provenance == c.ZMATH_TESTING_ORACLE_PROVENANCE_C23_IEEE) return 1;
    if (provenance == c.ZMATH_TESTING_ORACLE_PROVENANCE_ANNEX_F) return 2;
    if (provenance == c.ZMATH_TESTING_ORACLE_PROVENANCE_ANNEX_H) return 3;
    return null;
}

fn expectedFamilyCount(signature: *const c.zmath_testing_oracle_operation_signature) u32 {
    if (signature.provenance == c.ZMATH_TESTING_ORACLE_PROVENANCE_ANNEX_H) return 1;
    if (signature.provenance == c.ZMATH_TESTING_ORACLE_PROVENANCE_C23_7_12 and
        operationIn(&legacy_narrowing_operations, tableOperation(signature)))
    {
        return 1;
    }
    return 3;
}

fn sameFamily(
    first: *const c.zmath_testing_oracle_operation_signature,
    second: *const c.zmath_testing_oracle_operation_signature,
) bool {
    if (first.provenance != second.provenance) return false;
    return std.mem.eql(u8, tableOperation(first), tableOperation(second));
}

test "operation table matches every manifest signature" {
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    try std.testing.expectEqual(@as(usize, 315), manifest.function_count);
    const operation_count: usize = @intCast(c.ZMATH_TESTING_ORACLE_OPERATION_COUNT);
    try std.testing.expectEqual(@as(usize, 315), operation_count);
    try std.testing.expectEqual(
        operation_count,
        @as(usize, @intCast(c.zmath_testing_oracle_operation_table_count)),
    );

    var category_counts = [_]u32{ 0, 0, 0 };
    for (manifest.function_values[0..manifest.function_count], 0..) |*function, index| {
        const signature = &c.zmath_testing_oracle_operation_table[index];
        try std.testing.expectEqualStrings(function.op, tableOperation(signature));
        try std.testing.expectEqual(@as(usize, 1), function.provenance.count);
        try std.testing.expectEqual(
            expectedProvenance(function.provenance.values[0]),
            signature.provenance,
        );
        try std.testing.expectEqual(expectedCategory(function), signature.evaluator_category);
        try std.testing.expectEqual(@as(u32, function.arity), signature.arity);
        try std.testing.expect(signature.arguments != null);

        for (function.arguments(), 0..) |argument, argument_index| {
            try expectFieldDescriptor(
                signature.arguments[argument_index],
                argument.oracleDescriptor(),
            );
        }

        try std.testing.expectEqual(
            @as(u32, @intFromEnum(function.result.oracleLayout())),
            signature.result_layout,
        );
        try std.testing.expectEqual(
            @as(u32, @intFromEnum(function.result.oracleStructureKind())),
            signature.structure_kind,
        );
        const result_field_count: u32 = @intCast(function.result.oracleFieldCount());
        try std.testing.expectEqual(result_field_count, signature.result_field_count);
        try std.testing.expect(signature.result_fields != null);
        for (0..result_field_count) |result_index| {
            try expectFieldDescriptor(
                signature.result_fields[result_index],
                function.result.oracleFieldDescriptor(result_index).?,
            );
        }

        if (signature.evaluator_category == c.ZMATH_TESTING_ORACLE_EVALUATOR_EXACT_BITS) {
            category_counts[0] += 1;
        } else if (signature.evaluator_category == c.ZMATH_TESTING_ORACLE_EVALUATOR_MPFR_ARB) {
            category_counts[1] += 1;
        } else if (signature.evaluator_category == c.ZMATH_TESTING_ORACLE_EVALUATOR_ALGEBRAIC) {
            category_counts[2] += 1;
        } else {
            return error.UnknownEvaluatorCategory;
        }
    }

    try std.testing.expectEqualSlices(u32, &.{ 150, 126, 39 }, &category_counts);
}

test "operation table covers every provenance family count" {
    const operation_count: usize = @intCast(c.ZMATH_TESTING_ORACLE_OPERATION_COUNT);
    var provenance_rows = [_]u32{ 0, 0, 0, 0 };
    var provenance_families = [_]u32{ 0, 0, 0, 0 };
    var table_index: usize = 0;

    while (table_index < operation_count) {
        const signature = &c.zmath_testing_oracle_operation_table[table_index];
        const provenance_index = provenanceIndex(signature.provenance) orelse
            return error.UnknownProvenance;
        var family_end = table_index + 1;
        while (family_end < operation_count and
            sameFamily(signature, &c.zmath_testing_oracle_operation_table[family_end]))
        {
            family_end += 1;
        }

        const family_count: u32 = @intCast(family_end - table_index);
        try std.testing.expectEqual(expectedFamilyCount(signature), family_count);
        provenance_rows[provenance_index] += family_count;
        provenance_families[provenance_index] += 1;
        table_index = family_end;
    }

    try std.testing.expectEqualSlices(u32, &.{ 261, 21, 15, 18 }, &provenance_rows);
    try std.testing.expectEqualSlices(u32, &.{ 91, 7, 5, 18 }, &provenance_families);
}

fn expectResultKinds(
    signature: *const c.zmath_testing_oracle_operation_signature,
    first_kind: u32,
    first_bits: u32,
    second_kind: u32,
    second_bits: u32,
) !void {
    try std.testing.expectEqual(@as(u32, 2), signature.result_field_count);
    try std.testing.expectEqual(first_kind, signature.result_fields[0].kind);
    try std.testing.expectEqual(first_bits, signature.result_fields[0].value_bits);
    try std.testing.expectEqual(second_kind, signature.result_fields[1].kind);
    try std.testing.expectEqual(second_bits, signature.result_fields[1].value_bits);
}

test "status-bearing result structures expose value and status fields" {
    var canonicalize_count: u32 = 0;
    var payload_count: u32 = 0;
    var atan2_count: u32 = 0;
    var power_count: u32 = 0;
    var integer_count: u32 = 0;

    for (&c.zmath_testing_oracle_operation_table) |*signature| {
        if (signature.structure_kind == c.ZMATH_TESTING_ORACLE_STRUCTURE_CANONICALIZE) {
            canonicalize_count += 1;
            try expectResultKinds(
                signature,
                c.ZMATH_TESTING_ORACLE_FIELD_FLOAT,
                signature.result_fields[0].format.storage_bits,
                c.ZMATH_TESTING_ORACLE_FIELD_BOOLEAN,
                1,
            );
        } else if (signature.structure_kind == c.ZMATH_TESTING_ORACLE_STRUCTURE_PAYLOAD) {
            payload_count += 1;
            try expectResultKinds(
                signature,
                c.ZMATH_TESTING_ORACLE_FIELD_FLOAT,
                signature.result_fields[0].format.storage_bits,
                c.ZMATH_TESTING_ORACLE_FIELD_BOOLEAN,
                1,
            );
        } else if (signature.structure_kind == c.ZMATH_TESTING_ORACLE_STRUCTURE_ATAN2) {
            atan2_count += 1;
            try expectResultKinds(
                signature,
                c.ZMATH_TESTING_ORACLE_FIELD_FLOAT,
                signature.result_fields[0].format.storage_bits,
                c.ZMATH_TESTING_ORACLE_FIELD_BOOLEAN,
                1,
            );
        } else if (signature.structure_kind == c.ZMATH_TESTING_ORACLE_STRUCTURE_POWER) {
            power_count += 1;
            try expectResultKinds(
                signature,
                c.ZMATH_TESTING_ORACLE_FIELD_FLOAT,
                signature.result_fields[0].format.storage_bits,
                c.ZMATH_TESTING_ORACLE_FIELD_BOOLEAN,
                1,
            );
        } else if (signature.structure_kind == c.ZMATH_TESTING_ORACLE_STRUCTURE_INTEGER) {
            integer_count += 1;
            try expectResultKinds(
                signature,
                c.ZMATH_TESTING_ORACLE_FIELD_SIGNED_INTEGER,
                64,
                c.ZMATH_TESTING_ORACLE_FIELD_BOOLEAN,
                1,
            );
        }
    }

    try std.testing.expectEqual(@as(u32, 3), canonicalize_count);
    try std.testing.expectEqual(@as(u32, 6), payload_count);
    try std.testing.expectEqual(@as(u32, 6), atan2_count);
    try std.testing.expectEqual(@as(u32, 9), power_count);
    try std.testing.expectEqual(@as(u32, 12), integer_count);
}

test "signature lookup accepts every row and rejects shape drift" {
    for (&c.zmath_testing_oracle_operation_table) |*signature| {
        var input_fields: [c.ZMATH_TESTING_ORACLE_MAX_FIELDS]c.zmath_testing_oracle_input_field = undefined;
        for (0..signature.arity) |argument_index| {
            input_fields[argument_index] = .{
                .descriptor = signature.arguments[argument_index],
                .value_bits = 0,
                .tag_bytes = null,
                .tag_length = 0,
                .reserved = 0,
            };
        }
        const request = c.zmath_testing_oracle_request{
            .abi_version = c.ZMATH_TESTING_ORACLE_ABI_VERSION,
            .reserved = 0,
            .operation = @ptrCast(signature.operation),
            .operation_length = signature.operation_length,
            .arity = signature.arity,
            .input_fields = &input_fields[0],
            .input_field_count = signature.arity,
            .result_layout = signature.result_layout,
            .structure_kind = signature.structure_kind,
            .result_field_count = signature.result_field_count,
            .result_fields = signature.result_fields,
        };
        const found = c.zmath_testing_oracle_find_operation_signature(&request);
        try std.testing.expect(found != null);
        try std.testing.expectEqual(@intFromPtr(signature), @intFromPtr(found));
    }

    const signature = &c.zmath_testing_oracle_operation_table[0];
    var input_field = c.zmath_testing_oracle_input_field{
        .descriptor = signature.arguments[0],
        .value_bits = 0,
        .tag_bytes = null,
        .tag_length = 0,
        .reserved = 0,
    };
    var request = c.zmath_testing_oracle_request{
        .abi_version = c.ZMATH_TESTING_ORACLE_ABI_VERSION,
        .reserved = 0,
        .operation = @ptrCast(signature.operation),
        .operation_length = signature.operation_length,
        .arity = signature.arity,
        .input_fields = &input_field,
        .input_field_count = signature.arity,
        .result_layout = signature.result_layout,
        .structure_kind = signature.structure_kind,
        .result_field_count = signature.result_field_count,
        .result_fields = signature.result_fields,
    };

    input_field.descriptor.value_bits += 1;
    try std.testing.expect(c.zmath_testing_oracle_find_operation_signature(&request) == null);
    input_field.descriptor = signature.arguments[0];

    const unknown_operation = "unknownOperation";
    request.operation = unknown_operation.ptr;
    request.operation_length = unknown_operation.len;
    try std.testing.expect(c.zmath_testing_oracle_find_operation_signature(&request) == null);

    request.operation = @ptrCast(signature.operation);
    request.operation_length = signature.operation_length;
    request.result_layout = c.ZMATH_TESTING_ORACLE_RESULT_STRUCTURE;
    try std.testing.expect(c.zmath_testing_oracle_find_operation_signature(&request) == null);
}
