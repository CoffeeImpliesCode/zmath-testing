const std = @import("std");
const corpus = @import("corpus_support");
const campaigns = @import("corpus_campaigns");

fn unaryFunction(
    operation: []const u8,
    format: corpus.Format,
    status: corpus.Status,
) corpus.Function {
    var provenance: corpus.ProvenanceList = .empty;
    provenance.values[0] = .c23_7_12;
    provenance.count = 1;
    var inputs: corpus.ArgumentList = .empty;
    inputs.values[0] = .{ .float = format };
    inputs.count = 1;
    return .{
        .op = operation,
        .provenance = provenance,
        .status = status,
        .arity = 1,
        .inputs = inputs,
        .result = .{ .float = format },
        .oracle = .mpfr_arb,
        .special_policy = "zmath_c23_v1",
        .max_ulp = 0,
    };
}

fn binaryFunction(operation: []const u8) corpus.Function {
    var provenance: corpus.ProvenanceList = .empty;
    provenance.values[0] = .c23_7_12;
    provenance.count = 1;
    var inputs: corpus.ArgumentList = .empty;
    inputs.values[0] = .{ .float = .h };
    inputs.values[1] = .{ .float = .h };
    inputs.count = 2;
    return .{
        .op = operation,
        .provenance = provenance,
        .status = .correct,
        .arity = 2,
        .inputs = inputs,
        .result = .{ .float = .h },
        .oracle = .mpfr_arb,
        .special_policy = "zmath_c23_v1",
        .max_ulp = 0,
    };
}

fn ternaryFunction(operation: []const u8) corpus.Function {
    var provenance: corpus.ProvenanceList = .empty;
    provenance.values[0] = .annex_h;
    provenance.count = 1;
    var inputs: corpus.ArgumentList = .empty;
    inputs.values[0] = .{ .float = .f };
    inputs.values[1] = .{ .float = .f };
    inputs.values[2] = .{ .float = .f };
    inputs.count = 3;
    return .{
        .op = operation,
        .provenance = provenance,
        .status = .correct,
        .arity = 3,
        .inputs = inputs,
        .result = .{ .float = .h },
        .oracle = .mpfr_arb,
        .special_policy = "zmath_c23_v1",
        .max_ulp = 0,
    };
}

fn halfField(bits: u64) corpus.CorpusField {
    return .{ .float = .{ .format = .h, .bits = bits, .class = .none } };
}

fn floatField(format: corpus.Format, bits: u64) corpus.CorpusField {
    return .{ .float = .{ .format = format, .bits = bits, .class = .none } };
}

fn resultHalfField(bits: u64, class: corpus.FieldClass) corpus.CorpusField {
    return .{ .float = .{ .format = .h, .bits = bits, .class = class } };
}

const VisitCounter = struct {
    count: usize = 0,
    first_bits: u64 = 0,
    last_bits: u64 = 0,
    saw_expected: bool = false,
};

fn countVisit(context: *VisitCounter, visit: *const campaigns.RecordVisit) !void {
    const first = visit.arguments.fields[0];
    const bits = switch (first) {
        .float => |value| value.bits,
        else => 0,
    };
    if (context.count == 0) context.first_bits = bits;
    context.last_bits = bits;
    context.saw_expected = context.saw_expected or visit.expected_results.len != 0;
    context.count += 1;
}

test "manifest rows map to explicit deterministic campaigns or fail closed" {
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    const matrix = try campaigns.classifyManifest(&manifest);
    try std.testing.expectEqual(@as(usize, 315), matrix.count);
    try std.testing.expectEqual(@as(usize, 315), campaigns.manifest_campaign_count);
    try std.testing.expectEqual(@as(usize, 315), campaigns.campaign_table.len);

    var explicit_count: usize = 0;
    var unavailable_count: usize = 0;
    var binary_or_ternary_count: usize = 0;
    var binary_or_ternary_claims: usize = 0;
    var planned_h_count: usize = 0;
    var planned_f_count: usize = 0;
    var planned_d_count: usize = 0;
    var planned_bounded_count: usize = 0;
    var planned_special_count: usize = 0;
    var planned_hard_tuple_count: usize = 0;

    for (manifest.function_values[0..manifest.function_count], 0..) |function, index| {
        const definition = matrix.at(index).?;
        try std.testing.expectEqual(@as(usize, 1), campaigns.matchingRuleCount(function));
        switch (definition.campaignClass()) {
            .unavailable => {
                unavailable_count += 1;
                try std.testing.expect(function.status != .correct);
                try std.testing.expect(!definition.isEvidenceReady());
                try std.testing.expectEqual(campaigns.Availability.unavailable, definition.availability());
                const unavailable = definition.unavailableState().?;
                try std.testing.expect(!unavailable.source_metadata_available);
                try std.testing.expect(unavailable.source != null);
                try std.testing.expect(unavailable.artifact.len != 0);
                try std.testing.expect(unavailable.deterministic_seed != 0);
                try std.testing.expect(unavailable.tuple_count != 0);
                try std.testing.expect(unavailable.planned_class != .unavailable);
                try std.testing.expectEqual(function.status, unavailable.manifest_status);
            },
            .exhaustive_h_unary, .hard_corpus_f, .hard_corpus_d => {
                explicit_count += 1;
                try std.testing.expect(definition.unavailableState() == null);
                try std.testing.expect(!definition.isEvidenceReady());
                try std.testing.expect(definition.sourceMetadataAvailable());
            },
            else => return error.UnexpectedManifestCampaign,
        }
        if (function.arity > 1) {
            binary_or_ternary_count += 1;
            try std.testing.expect(definition.plannedCampaignClass() != .unavailable);
            try std.testing.expect(definition.plannedCampaignClass() != .exhaustive_h_unary);
            if (definition.claimsExhaustiveFullCartesian()) binary_or_ternary_claims += 1;
            try std.testing.expect(!definition.claimsExhaustiveFullCartesian());
        }
        switch (definition.plannedCampaignClass()) {
            .exhaustive_h_unary => planned_h_count += 1,
            .hard_corpus_f => planned_f_count += 1,
            .hard_corpus_d => planned_d_count += 1,
            .bounded_h_integer_domain => planned_bounded_count += 1,
            .explicit_special_tuple_grid => planned_special_count += 1,
            .source_pinned_binary_ternary_hard_tuples => planned_hard_tuple_count += 1,
            .unavailable, .exact_bit_status => return error.UnexpectedPlannedCampaign,
        }
    }

    try std.testing.expectEqual(@as(usize, 5), explicit_count);
    try std.testing.expectEqual(@as(usize, 310), unavailable_count);
    try std.testing.expectEqual(@as(usize, 125), binary_or_ternary_count);
    try std.testing.expectEqual(@as(usize, 0), binary_or_ternary_claims);
    try std.testing.expectEqual(@as(usize, 61), planned_h_count);
    try std.testing.expectEqual(@as(usize, 62), planned_f_count);
    try std.testing.expectEqual(@as(usize, 64), planned_d_count);
    try std.testing.expectEqual(@as(usize, 6), planned_bounded_count);
    try std.testing.expectEqual(@as(usize, 3), planned_special_count);
    try std.testing.expectEqual(@as(usize, 119), planned_hard_tuple_count);
}

test "every explicit rule carries deterministic source and corpus metadata" {
    for (campaigns.campaign_table) |rule| {
        try std.testing.expect(rule.source.repository.len != 0);
        try std.testing.expect(rule.source.revision.len != 0);
        try std.testing.expect(rule.source.path.len != 0);
        if (rule.enabled) {
            try std.testing.expect(std.mem.startsWith(u8, rule.artifact, "core-math-"));
        } else {
            try std.testing.expect(std.mem.startsWith(u8, rule.artifact, "test/corpus/"));
        }
        switch (rule.campaign_class) {
            .exhaustive_h_unary => try std.testing.expectEqual(
                campaigns.TuplePolicy.exhaustive_raw_bits,
                rule.tuple_policy,
            ),
            .bounded_h_integer_domain => try std.testing.expectEqual(
                campaigns.TuplePolicy.bounded_integer_inclusive,
                rule.tuple_policy,
            ),
            .explicit_special_tuple_grid, .source_pinned_binary_ternary_hard_tuples => {
                try std.testing.expectEqual(
                    campaigns.TuplePolicy.ordered_special_hard,
                    rule.tuple_policy,
                );
            },
            .hard_corpus_f, .hard_corpus_d => try std.testing.expectEqual(
                campaigns.TuplePolicy.deterministic_hard_corpus,
                rule.tuple_policy,
            ),
            .exact_bit_status, .unavailable => return error.UnexpectedRuleClass,
        }
        if (rule.campaign_class == .bounded_h_integer_domain) {
            try std.testing.expectEqual(@as(?u8, 1), rule.integer_index);
            try std.testing.expect(rule.integer_type != null);
            try std.testing.expect(rule.bounds != null);
            try std.testing.expectEqual(@as(u64, 129), rule.tuple_count);
        }
        if (rule.campaign_class == .explicit_special_tuple_grid) {
            try std.testing.expectEqual(@as(u8, 1), rule.special_axis_count);
        }
        if (rule.campaign_class == .source_pinned_binary_ternary_hard_tuples) {
            try std.testing.expect(rule.tuple_count == 32 or rule.tuple_count == 48);
        }
    }
}
test "H unary plans enumerate all encodings and fail closed when unavailable" {
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    var planned_count: usize = 0;
    var exhaustive_count: usize = 0;

    for (manifest.function_values[0..manifest.function_count]) |function| {
        const definition = campaigns.classify(function);
        if (definition.plannedCampaignClass() != .exhaustive_h_unary) continue;
        planned_count += 1;
        if (definition.campaignClass() == .unavailable) {
            try std.testing.expectError(error.CampaignUnavailable, definition.cardinality());
            var unavailable_iterator = definition.iterator();
            try std.testing.expectError(error.CampaignUnavailable, unavailable_iterator.next());
            continue;
        }
        exhaustive_count += 1;
        try std.testing.expectEqual(@as(u64, 65_536), try definition.cardinality());

        var iterator = definition.iterator();
        var expected: u64 = 0;
        while (try iterator.next()) |tuple| {
            try std.testing.expectEqual(@as(u8, 1), tuple.count);
            switch (tuple.fields[0]) {
                .float => |field| {
                    try std.testing.expectEqual(@as(u64, expected), field.bits);
                    try std.testing.expectEqual(corpus.FieldClass.none, field.class);
                },
                else => return error.UnexpectedInputField,
            }
            expected += 1;
        }
        try std.testing.expectEqual(@as(u64, 65_536), expected);
    }

    try std.testing.expectEqual(@as(usize, 61), planned_count);
    try std.testing.expectEqual(@as(usize, 3), exhaustive_count);
}

test "F and D hard campaigns expose metadata but no smoke evidence" {
    const manifest = try corpus.parseManifest(corpus.manifest_text);
    var saw_f = false;
    var saw_d = false;

    for (manifest.function_values[0..manifest.function_count]) |function| {
        const definition = campaigns.classify(function);
        switch (definition.data) {
            .hard_corpus_f => |metadata| {
                saw_f = true;
                try std.testing.expectEqual(corpus.Format.f, metadata.format);
                try std.testing.expect(metadata.source != null);
                try std.testing.expect(metadata.artifact.len != 0);
                try std.testing.expect(std.mem.startsWith(u8, metadata.artifact, "core-math-"));
                try std.testing.expect(metadata.deterministic_seed != 0);
                try std.testing.expectEqual(@as(u64, 0), metadata.record_count);
                try std.testing.expect(!metadata.evidence_available);
                try std.testing.expect(definition.availability() == .metadata_only);
                try std.testing.expect(!definition.isEvidenceReady());
                try std.testing.expectEqual(@as(u64, 0), try definition.cardinality());
                var iterator = definition.iterator();
                try std.testing.expectError(error.MetadataOnly, iterator.next());
            },
            .hard_corpus_d => |metadata| {
                saw_d = true;
                try std.testing.expectEqual(corpus.Format.d, metadata.format);
                try std.testing.expect(metadata.source != null);
                try std.testing.expect(metadata.artifact.len != 0);
                try std.testing.expect(std.mem.startsWith(u8, metadata.artifact, "core-math-"));
                try std.testing.expect(metadata.deterministic_seed != 0);
                try std.testing.expectEqual(@as(u64, 0), metadata.record_count);
                try std.testing.expect(!metadata.evidence_available);
                try std.testing.expect(definition.availability() == .metadata_only);
                try std.testing.expect(!definition.isEvidenceReady());
                try std.testing.expectEqual(@as(u64, 0), try definition.cardinality());
                var iterator = definition.iterator();
                try std.testing.expectError(error.MetadataOnly, iterator.next());
            },
            else => {},
        }
    }

    try std.testing.expect(saw_f);
    try std.testing.expect(saw_d);
}

test "bounded H integer-domain campaign is inclusive and deterministic" {
    var function = binaryFunction("ldexp");
    function.inputs.values[1] = .{ .integer = .i8 };
    function.result = .{ .float = .h };
    const base_fields = [_]corpus.CorpusField{
        halfField(0x3c00),
        .{ .signed_integer = .{ .integer_type = .i8, .value = 0 } },
    };
    const base = try campaigns.InputTuple.init(&base_fields);
    const definition = try campaigns.makeBoundedHIntegerDomain(
        function,
        1,
        .{ .signed = .{ .lower = -2, .upper = 2 } },
        base,
    );

    try std.testing.expectEqual(campaigns.CampaignClass.bounded_h_integer_domain, definition.campaignClass());
    try std.testing.expectEqual(@as(u64, 5), try definition.cardinality());
    var iterator = definition.iterator();
    var expected: i8 = -2;
    while (try iterator.next()) |tuple| {
        switch (tuple.fields[1]) {
            .signed_integer => |field| try std.testing.expectEqual(expected, field.value),
            else => return error.UnexpectedIntegerField,
        }
        expected += 1;
    }
    try std.testing.expectEqual(@as(i8, 3), expected);
}

test "special binary tuple grid is lexicographic and not exhaustive Cartesian" {
    const function = binaryFunction("special_binary");
    const first_axis = [_]corpus.CorpusField{ halfField(0x0000), halfField(0x3c00) };
    const second_axis = [_]corpus.CorpusField{ halfField(0x8000), halfField(0x3c00) };
    const axes = [_]campaigns.TupleAxis{
        .{ .values = first_axis[0..] },
        .{ .values = second_axis[0..] },
    };
    const definition = try campaigns.makeSpecialTupleGrid(function, axes[0..]);

    try std.testing.expectEqual(@as(u64, 4), try definition.cardinality());
    try std.testing.expect(!definition.claimsExhaustiveFullCartesian());
    var iterator = definition.iterator();
    const expected = [_][2]u64{
        .{ 0x0000, 0x8000 },
        .{ 0x0000, 0x3c00 },
        .{ 0x3c00, 0x8000 },
        .{ 0x3c00, 0x3c00 },
    };
    for (expected) |pair| {
        const tuple = (try iterator.next()).?;
        try std.testing.expectEqual(pair[0], tuple.fields[0].float.bits);
        try std.testing.expectEqual(pair[1], tuple.fields[1].float.bits);
    }
    try std.testing.expect((try iterator.next()) == null);
}

test "source-pinned binary and ternary hooks are immutable finite tuples" {
    const binary = binaryFunction("hard_binary");
    const binary_one_fields = [_]corpus.CorpusField{ halfField(0x3c00), halfField(0x4000) };
    const binary_two_fields = [_]corpus.CorpusField{ halfField(0x0000), halfField(0x3c00) };
    const binary_one = try campaigns.InputTuple.init(&binary_one_fields);
    const binary_two = try campaigns.InputTuple.init(&binary_two_fields);
    const hard_binary = [_]campaigns.HardTuple{
        .{ .arguments = binary_one },
        .{ .arguments = binary_two },
    };
    const source = campaigns.SourcePin{
        .repository = campaigns.core_math_repository,
        .revision = campaigns.core_math_revision,
        .path = "src/binary16/hard_binary.c",
    };
    const binary_definition = try campaigns.makeSourcePinnedHardTuples(
        binary,
        source,
        hard_binary[0..],
    );
    try std.testing.expectEqual(@as(u64, 2), try binary_definition.cardinality());
    try std.testing.expect(!binary_definition.claimsExhaustiveFullCartesian());

    const ternary = ternaryFunction("hard_ternary");
    const ternary_fields = [_]corpus.CorpusField{
        floatField(.f, 0x3f80_0000),
        floatField(.f, 0x4000_0000),
        floatField(.f, 0x4040_0000),
    };
    const ternary_tuple = try campaigns.InputTuple.init(&ternary_fields);
    const hard_ternary = [_]campaigns.HardTuple{.{ .arguments = ternary_tuple }};
    const ternary_definition = try campaigns.makeSourcePinnedHardTuples(
        ternary,
        source,
        hard_ternary[0..],
    );
    try std.testing.expectEqual(@as(u64, 1), try ternary_definition.cardinality());
    try std.testing.expect(!ternary_definition.claimsExhaustiveFullCartesian());
}

test "exact bit and status campaign emits complete ZCDR record" {
    const function = unaryFunction("nextUp", .h, .correct);
    const arguments = try campaigns.InputTuple.init(&.{halfField(0x8000)});
    const results = [_]corpus.CorpusField{resultHalfField(0x0000, .zero)};
    const cases = [_]campaigns.ExactCase{.{
        .arguments = arguments,
        .results = results[0..],
        .expected_status = .ok,
        .max_ulp = 0,
    }};
    const definition = try campaigns.makeExactBitStatus(function, cases[0..]);

    try std.testing.expectEqual(campaigns.CampaignClass.exact_bit_status, definition.campaignClass());
    try std.testing.expectEqual(@as(u64, 1), try definition.cardinality());
    const expected = try campaigns.exactRecord(&definition, 0);
    try std.testing.expectEqual(corpus.OracleStatus.ok, expected.expected_status);
    try std.testing.expectEqual(@as(usize, 1), expected.record.arguments.count);
    try std.testing.expectEqual(@as(usize, 1), expected.record.results.count);
    try std.testing.expectEqual(@as(u64, 0x0000), expected.record.results.values[0].float.bits);
    try std.testing.expectEqual(corpus.FieldClass.zero, expected.record.results.values[0].float.class);

    var storage: [512]u8 = undefined;
    const encoded = try campaigns.encodeExactRecord(&definition, 0, storage[0..]);
    const decoded = try corpus.decodeCorpusRecord(encoded);
    try std.testing.expectEqualStrings("nextUp", decoded.operation);
    try std.testing.expectEqual(@as(u64, 0x8000), decoded.arguments.values[0].float.bits);
    try std.testing.expectEqual(@as(u64, 0x0000), decoded.results.values[0].float.bits);
    try std.testing.expectEqual(corpus.FieldClass.zero, decoded.results.values[0].float.class);
}

test "definition visitor carries hard expected fields without allocation" {
    const function = binaryFunction("hard_binary");
    const arguments = [_]corpus.CorpusField{ halfField(0x3c00), halfField(0x4000) };
    const tuple = try campaigns.InputTuple.init(&arguments);
    const results = [_]corpus.CorpusField{resultHalfField(0x4200, .normal)};
    const hard = [_]campaigns.HardTuple{.{
        .arguments = tuple,
        .expected_results = results[0..],
        .expected_status = .ok,
    }};
    const source = campaigns.SourcePin{
        .repository = campaigns.core_math_repository,
        .revision = campaigns.core_math_revision,
        .path = "src/binary16/hard_binary.c",
    };
    const definition = try campaigns.makeSourcePinnedHardTuples(function, source, hard[0..]);
    var counter = VisitCounter{};
    try campaigns.visitDefinitionRecords(&definition, &counter, countVisit);
    try std.testing.expectEqual(@as(usize, 1), counter.count);
    try std.testing.expectEqual(@as(u64, 0x3c00), counter.first_bits);
    try std.testing.expect(counter.saw_expected);
}
