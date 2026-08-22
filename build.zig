const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zmath_dependency = b.dependency("zmath", .{
        .target = target,
        .optimize = optimize,
    });
    const zmath_module = zmath_dependency.module("zmath");

    const integration_module = b.createModule(.{
        .root_source_file = b.path("test/integration/public_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zmath", .module = zmath_module }},
    });
    const integration_tests = b.addTest(.{ .root_module = integration_module });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const test_step = b.step("test", "Run public zmath integration tests");
    test_step.dependOn(&run_integration_tests.step);

    const oracle_module = b.createModule(.{
        .root_source_file = b.path("test/oracle/oracle_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oracle_module.addCSourceFile(.{
        .file = b.path("test/oracle/oracle_smoke.c"),
        .flags = &.{"-std=c11"},
    });
    oracle_module.linkSystemLibrary("mpfr", .{});
    oracle_module.linkSystemLibrary("gmp", .{});
    oracle_module.linkSystemLibrary("flint", .{});
    const oracle_tests = b.addTest(.{ .root_module = oracle_module });
    const run_oracle_tests = b.addRunArtifact(oracle_tests);
    const oracle_step = b.step("oracle", "Run MPFR and Arb oracle smoke tests");
    oracle_step.dependOn(&run_oracle_tests.step);

    const benchmark_module = b.createModule(.{
        .root_source_file = b.path("bench/public_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zmath", .module = zmath_module }},
    });
    const benchmark = b.addExecutable(.{
        .name = "zmath-testing-public-api",
        .root_module = benchmark_module,
    });
    const bench_step = b.step("bench", "Build public zmath benchmarks");
    bench_step.dependOn(&benchmark.step);

    const run_benchmark = b.addRunArtifact(benchmark);
    const run_bench_step = b.step("run-bench", "Run public zmath benchmarks");
    run_bench_step.dependOn(&run_benchmark.step);
}
