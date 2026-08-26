const std = @import("std");

pub const Info = struct {
    target_triple: []const u8,
    cpu_features: []const u8,
    optimize: []const u8,
};

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
