const std = @import("std");

pub const Info = struct {
    target_triple: []const u8,
    cpu_features: []const u8,
    optimize: []const u8,
};

pub const approved_corpus_target = "x86_64-linux-gnu.2.38";
pub const approved_corpus_cpu = "haswell";
pub const approved_corpus_mode = "ReleaseSafe";
const approved_corpus_glibc = std.SemanticVersion{
    .major = 2,
    .minor = 38,
    .patch = 0,
};

pub fn isApprovedCorpusTarget(target: std.Target) bool {
    if (target.cpu.arch != .x86_64) return false;
    if (target.os.tag != .linux) return false;
    if (target.abi != .gnu) return false;
    const glibc = target.os.versionRange().gnuLibCVersion() orelse return false;
    return glibc.order(approved_corpus_glibc) == .eq;
}

pub fn isApprovedCorpusCpu(target: std.Target) bool {
    const canonical_cpu = std.Target.x86.cpu.haswell.toCpu(.x86_64);
    if (!std.mem.eql(u8, target.cpu.model.name, approved_corpus_cpu)) return false;
    return target.cpu.features.eql(canonical_cpu.features);
}

pub fn isApprovedCorpusMode(optimize: std.builtin.OptimizeMode) bool {
    return std.mem.eql(u8, @tagName(optimize), approved_corpus_mode);
}

pub fn resolve(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Info {
    const target_triple = target.result.zigTriple(b.allocator) catch @panic("OOM");
    var cpu_features: std.ArrayList(u8) = .empty;

    for (target.result.cpu.arch.allFeaturesList()) |feature| {
        if (!target.result.cpu.features.isEnabled(feature.index)) continue;

        if (cpu_features.items.len != 0) {
            cpu_features.append(b.allocator, ',') catch @panic("OOM");
        }
        cpu_features.appendSlice(b.allocator, feature.name) catch @panic("OOM");
    }

    return .{
        .target_triple = target_triple,
        .cpu_features = cpu_features.items,
        .optimize = @tagName(optimize),
    };
}

test "corpus target qualification accepts exact glibc and CPU identity" {
    const query = try std.Target.Query.parse(.{
        .arch_os_abi = approved_corpus_target,
        .cpu_features = approved_corpus_cpu,
    });
    const target = try std.zig.system.resolveTargetQuery(std.testing.io, query);

    try std.testing.expect(isApprovedCorpusTarget(target));
    try std.testing.expect(isApprovedCorpusCpu(target));
    try std.testing.expect(isApprovedCorpusMode(.ReleaseSafe));
}

test "corpus target qualification rejects an added haswell feature" {
    const query = try std.Target.Query.parse(.{
        .arch_os_abi = approved_corpus_target,
        .cpu_features = approved_corpus_cpu ++ "+avx512f",
    });
    const target = try std.zig.system.resolveTargetQuery(std.testing.io, query);

    try std.testing.expect(std.mem.eql(u8, target.cpu.model.name, approved_corpus_cpu));
    try std.testing.expect(!isApprovedCorpusCpu(target));
}

test "corpus target qualification rejects a removed haswell feature" {
    const query = try std.Target.Query.parse(.{
        .arch_os_abi = approved_corpus_target,
        .cpu_features = approved_corpus_cpu ++ "-avx2",
    });
    const target = try std.zig.system.resolveTargetQuery(std.testing.io, query);

    try std.testing.expect(std.mem.eql(u8, target.cpu.model.name, approved_corpus_cpu));
    try std.testing.expect(!isApprovedCorpusCpu(target));
}

test "corpus target qualification rejects a different glibc version" {
    const query = try std.Target.Query.parse(.{
        .arch_os_abi = "x86_64-linux-gnu.2.31",
        .cpu_features = approved_corpus_cpu,
    });
    const target = try std.zig.system.resolveTargetQuery(std.testing.io, query);

    try std.testing.expect(!isApprovedCorpusTarget(target));
}

test "corpus target qualification rejects a non-approved CPU" {
    const query = try std.Target.Query.parse(.{
        .arch_os_abi = approved_corpus_target,
        .cpu_features = "baseline",
    });
    const target = try std.zig.system.resolveTargetQuery(std.testing.io, query);

    try std.testing.expect(!isApprovedCorpusCpu(target));
}

test "corpus target qualification rejects a non-approved optimize mode" {
    try std.testing.expect(!isApprovedCorpusMode(.ReleaseFast));
}
