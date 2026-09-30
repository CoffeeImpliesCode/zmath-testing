const std = @import("std");
const corpus = @import("corpus_support");

const tsv_header = "op\tformat\tinput_bits\toutput_bits\toutput_class\tmax_ulp\n";

const fixture_root =
    "schema_version = 4\n" ++
    "core_math_repository = \"https://gitlab.inria.fr/core-math/core-math.git\"\n" ++
    "core_math_revision = \"3bafed75e3c22399531857d63a3fa0e24bfb42fa\"\n" ++
    "mpfr_precision_bits = 512\n" ++
    "arb_precision_bits = 512\n" ++
    "rounding = \"nearest_even\"\n" ++
    "formats = [\"h\", \"f\", \"d\"]\n" ++
    "reserved_formats = [\"q\"]\n" ++
    "rejected_formats = [\"q\", \"f128\", \"bfloat16\"]\n" ++
    "operation_spelling = \"c23_hfd_lowercase_v1\"\n" ++
    "columns = [\"op\", \"provenance\", \"status\", \"arity\", \"inputs\", " ++
    "\"result\", \"oracle\", \"special_policy\", \"max_ulp\"]\n" ++
    "hexadecimal = \"lowercase_fixed_width\"\n" ++
    "uncertainty_policy = \"fail_closed\"\n" ++
    "special_policy = \"zmath_c23_v1\"\n";

const fixture_row =
    "[[function]]\n" ++
    "op = \"abs\"\n" ++
    "provenance = [\"zmath\"]\n" ++
    "status = \"unsupported\"\n" ++
    "arity = 1\n" ++
    "inputs = [\"float:h\"]\n" ++
    "result = \"float:h\"\n" ++
    "oracle = \"none\"\n" ++
    "special_policy = \"zmath_c23_v1\"\n" ++
    "max_ulp = 0\n";

const fixture_manifest = fixture_root ++ fixture_row;

const abs_h_unsupported =
    "[[function]]\n" ++
    "op = \"abs\"\n" ++
    "provenance = [\"zmath\"]\n" ++
    "status = \"unsupported\"\n" ++
    "arity = 1\n" ++
    "inputs = [\"float:h\"]\n" ++
    "result = \"float:h\"\n" ++
    "oracle = \"none\"\n" ++
    "special_policy = \"zmath_c23_v1\"\n" ++
    "max_ulp = 0\n";
const abs_h_correct =
    "[[function]]\n" ++
    "op = \"abs\"\n" ++
    "provenance = [\"zmath\"]\n" ++
    "status = \"correct\"\n" ++
    "arity = 1\n" ++
    "inputs = [\"float:h\"]\n" ++
    "result = \"float:h\"\n" ++
    "oracle = \"exact_bits\"\n" ++
    "special_policy = \"zmath_c23_v1\"\n" ++
    "max_ulp = 0\n";

fn replaceText(
    input: []const u8,
    needle: []const u8,
    replacement: []const u8,
    output: []u8,
) []const u8 {
    const index = std.mem.indexOf(u8, input, needle) orelse @panic("fixture needle missing");
    const suffix_start = index + needle.len;
    const output_len = index + replacement.len + input.len - suffix_start;
    if (output_len > output.len) @panic("fixture replacement exceeds buffer");
    @memcpy(output[0..index], input[0..index]);
    @memcpy(output[index .. index + replacement.len], replacement);
    @memcpy(output[index + replacement.len .. output_len], input[suffix_start..]);
    return output[0..output_len];
}

test "portable infrastructure accepts the complete typed manifest" {
    const manifest = try corpus.parseEmbeddedManifest();
    try std.testing.expectEqual(@as(usize, 323), manifest.functionCount());
    try corpus.validateEmbeddedManifest();
}

test "portable infrastructure accepts a correct descriptor outside legacy TSV set" {
    var source: [corpus.manifest_text.len + 16]u8 = undefined;
    const accepted_source = if (std.mem.indexOf(
        u8,
        corpus.manifest_text,
        abs_h_correct,
    ) != null)
        corpus.manifest_text
    else
        replaceText(
            corpus.manifest_text,
            abs_h_unsupported,
            abs_h_correct,
            &source,
        );
    const manifest = try corpus.parseManifest(accepted_source);
    const function = manifest.function_values[0];
    try std.testing.expectEqualStrings("abs", function.op);
    try std.testing.expectEqual(corpus.FunctionStatus.correct, function.status);
    try std.testing.expectEqual(corpus.Oracle.exact_bits, function.oracle);
}

test "portable infrastructure rejects a nonempty truncated manifest" {
    try std.testing.expectError(error.MissingFunctionRow, corpus.validateManifest(fixture_manifest));
}

test "portable infrastructure rejects a malformed standard-operation signature" {
    var source: [fixture_manifest.len + 64]u8 = undefined;
    const malformed = replaceText(
        fixture_manifest,
        "inputs = [\"float:h\"]",
        "inputs = [\"tag\"]",
        &source,
    );
    try std.testing.expectError(error.InvalidDescriptor, corpus.validateManifest(malformed));
}

// The pinned version is 4. This must rewrite it to the immediately previous
// schema, 3, so the test keeps proving that one version step back is refused.
// Rewriting to 2 would also fail, but for the wrong reason: it would stop
// discriminating the immediate boundary.
test "portable infrastructure rejects the previous manifest schema" {
    var source: [fixture_manifest.len + 64]u8 = undefined;
    const malformed = replaceText(
        fixture_manifest,
        "schema_version = 4",
        "schema_version = 3",
        &source,
    );
    try std.testing.expectError(error.InvalidPinnedValue, corpus.validateManifest(malformed));
}

test "portable infrastructure rejects a missing root key" {
    var source: [fixture_manifest.len + 64]u8 = undefined;
    const malformed = replaceText(
        fixture_manifest,
        "operation_spelling = \"c23_hfd_lowercase_v1\"\n",
        "",
        &source,
    );
    try std.testing.expectError(error.MissingRootKey, corpus.validateManifest(malformed));
}

test "portable infrastructure rejects the legacy operation spelling" {
    var source: [fixture_manifest.len + 64]u8 = undefined;
    const malformed = replaceText(
        fixture_manifest,
        "c23_hfd_lowercase_v1",
        "c23_hfd_lowercase_v0",
        &source,
    );
    try std.testing.expectError(error.InvalidPinnedValue, corpus.validateManifest(malformed));
}

test "portable infrastructure rejects unknown provenance" {
    var source: [fixture_manifest.len + 64]u8 = undefined;
    const malformed = replaceText(
        fixture_manifest,
        "provenance = [\"zmath\"]",
        "provenance = [\"vendor\"]",
        &source,
    );
    try std.testing.expectError(error.InvalidProvenance, corpus.validateManifest(malformed));
}

test "portable infrastructure rejects unordered row keys" {
    var source: [fixture_manifest.len + 64]u8 = undefined;
    const malformed = replaceText(
        fixture_manifest,
        "status = \"unsupported\"\narity = 1",
        "arity = 1\nstatus = \"unsupported\"",
        &source,
    );
    try std.testing.expectError(error.UnorderedFunctionKey, corpus.validateManifest(malformed));
}

test "portable infrastructure rejects an unknown typed descriptor" {
    var source: [fixture_manifest.len + 64]u8 = undefined;
    const malformed = replaceText(
        fixture_manifest,
        "inputs = [\"float:h\"]",
        "inputs = [\"float:q\"]",
        &source,
    );
    try std.testing.expectError(error.InvalidDescriptor, corpus.validateManifest(malformed));
}

test "portable infrastructure rejects an invented narrowing operation" {
    var source: [fixture_manifest.len + 64]u8 = undefined;
    const malformed = replaceText(
        fixture_manifest,
        "op = \"abs\"",
        "op = \"f16addf16\"",
        &source,
    );
    try std.testing.expectError(error.UnknownOperation, corpus.validateManifest(malformed));
}

test "portable infrastructure enforces unsupported status relations" {
    var source: [fixture_manifest.len + 64]u8 = undefined;
    const malformed = replaceText(
        fixture_manifest,
        "oracle = \"none\"",
        "oracle = \"mpfr_arb\"",
        &source,
    );
    try std.testing.expectError(error.InvalidStatusRelation, corpus.validateManifest(malformed));
}

test "portable infrastructure enforces correct status relations" {
    var source: [fixture_manifest.len + 64]u8 = undefined;
    const malformed = replaceText(
        fixture_manifest,
        "status = \"unsupported\"",
        "status = \"correct\"",
        &source,
    );
    try std.testing.expectError(error.InvalidStatusRelation, corpus.validateManifest(malformed));
}

test "portable infrastructure rejects non-canonical max ULP" {
    var source: [fixture_manifest.len + 64]u8 = undefined;
    const malformed = replaceText(
        fixture_manifest,
        "max_ulp = 0",
        "max_ulp = 00",
        &source,
    );
    try std.testing.expectError(error.InvalidMaxUlp, corpus.validateManifest(malformed));
}

test "portable infrastructure rejects q rows" {
    try std.testing.expectError(
        error.ReservedFormat,
        corpus.validateTsv(tsv_header ++ "exp\tq\t00000000000000000000000000000000\t" ++
            "00000000000000000000000000000000\tnormal\t0\n"),
    );
}

test "portable infrastructure rejects bfloat16 rows" {
    try std.testing.expectError(
        error.RejectedFormat,
        corpus.validateTsv(tsv_header ++ "exp\tbfloat16\t0000\t0000\tnormal\t0\n"),
    );
}

test "portable infrastructure rejects uppercase hex rows" {
    try std.testing.expectError(
        error.UppercaseHexDigit,
        corpus.validateTsv(tsv_header ++ "exp\th\t000A\t0000\tnormal\t0\n"),
    );
}

test "portable infrastructure rejects declared qNaN class mismatch" {
    try std.testing.expectError(
        error.OutputClassMismatch,
        corpus.validateTsv(tsv_header ++ "exp\th\t0000\t7e00\tnormal\t0\n"),
    );
}

test "portable infrastructure accepts each special output class" {
    try corpus.validateTsv(tsv_header ++ "exp\th\t0000\t0000\tzero\t0\n");
    try corpus.validateTsv(
        tsv_header ++ "exp\tf\t00000000\t7f800000\tinfinity\t0\n",
    );
    try corpus.validateTsv(
        tsv_header ++ "exp\td\t0000000000000000\t7ff8000000000000\tqnan\t0\n",
    );
}
