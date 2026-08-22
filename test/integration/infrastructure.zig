const std = @import("std");
const corpus = @import("corpus_support");

const tsv_header = "op\tformat\tinput_bits\toutput_bits\toutput_class\tmax_ulp\n";

test "portable infrastructure accepts the pinned manifest" {
    try corpus.validateEmbeddedManifest();
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
