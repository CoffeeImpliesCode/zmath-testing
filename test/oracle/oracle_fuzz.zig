const std = @import("std");
const runner = @import("corpus_runner");

test "oracle fuzz: typed Exp inputs" {
    try std.testing.fuzz({}, runner.fuzzOne, .{});
}
