const std = @import("std");

fn enableCoverage(
    enabled: bool,
    runtime_object: ?[]const u8,
    compile: *std.Build.Step.Compile,
) void {
    if (!enabled) return;

    compile.use_llvm = true;
    compile.root_module.fuzz = true;
    compile.root_module.link_libc = true;
    if (runtime_object) |path| {
        compile.root_module.addObjectFile(.{ .cwd_relative = path });
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const coverage = b.option(bool, "coverage", "Enable zig-cov instrumentation") orelse false;
    const coverage_runtime = b.option([]const u8, "coverage-rt", "Path to zig-cov runtime object");
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
    enableCoverage(coverage, coverage_runtime, integration_tests);
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const suffix_module = b.createModule(.{
        .root_source_file = b.path("test/integration/numeric_suffixes.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zmath", .module = zmath_module }},
    });
    const suffix_tests = b.addTest(.{ .root_module = suffix_module });
    enableCoverage(coverage, coverage_runtime, suffix_tests);
    const run_suffix_tests = b.addRunArtifact(suffix_tests);

    const test_step = b.step("test", "Run public zmath integration tests");
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_suffix_tests.step);

    const corpus_support_package = b.addWriteFiles();
    const corpus_support_root = corpus_support_package.addCopyFile(
        b.path("test/support/corpus.zig"),
        "corpus_support.zig",
    );
    _ = corpus_support_package.addCopyFile(
        b.path("test/corpus/manifest.toml"),
        "corpus/manifest.toml",
    );
    const corpus_support_module = b.createModule(.{
        .root_source_file = corpus_support_root,
        .target = target,
        .optimize = optimize,
    });

    const infrastructure_module = b.createModule(.{
        .root_source_file = b.path("test/integration/infrastructure.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "corpus_support",
            .module = corpus_support_module,
        }},
    });
    const infrastructure_tests = b.addTest(.{ .root_module = infrastructure_module });
    enableCoverage(coverage, coverage_runtime, infrastructure_tests);
    const run_infrastructure_tests = b.addRunArtifact(infrastructure_tests);
    test_step.dependOn(&run_infrastructure_tests.step);

    const oracle_module = b.createModule(.{
        .root_source_file = b.path("test/oracle/oracle_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zmath", .module = zmath_module },
            .{ .name = "corpus_support", .module = corpus_support_module },
        },
        .link_libc = true,
    });
    oracle_module.addCSourceFile(.{
        .file = b.path("test/oracle/oracle_smoke.c"),
        .flags = &.{"-std=c11"},
    });
    oracle_module.addCSourceFile(.{
        .file = b.path("test/oracle/oracle_bridge.c"),
        .flags = &.{"-std=c11"},
    });
    oracle_module.addIncludePath(b.path("test/oracle"));
    oracle_module.linkSystemLibrary("mpfr", .{});
    oracle_module.linkSystemLibrary("gmp", .{});
    oracle_module.linkSystemLibrary("flint", .{});
    const oracle_tests = b.addTest(.{ .root_module = oracle_module });
    enableCoverage(coverage, coverage_runtime, oracle_tests);
    const run_oracle_tests = b.addRunArtifact(oracle_tests);
    const oracle_step = b.step("oracle", "Run MPFR and Arb oracle smoke tests");
    oracle_step.dependOn(&run_oracle_tests.step);

    const oracle_fuzz_module = b.createModule(.{
        .root_source_file = b.path("test/oracle/oracle_fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zmath", .module = zmath_module },
            .{ .name = "corpus_support", .module = corpus_support_module },
            .{ .name = "corpus_runner", .module = b.createModule(.{
                .root_source_file = b.path("test/oracle/corpus_runner.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zmath", .module = zmath_module },
                    .{ .name = "corpus_support", .module = corpus_support_module },
                },
                .link_libc = true,
                .fuzz = true,
            }) },
        },
        .link_libc = true,
        .fuzz = true,
    });
    oracle_fuzz_module.addCSourceFile(.{
        .file = b.path("test/oracle/oracle_bridge.c"),
        .flags = &.{"-std=c11"},
    });
    oracle_fuzz_module.addIncludePath(b.path("test/oracle"));
    oracle_fuzz_module.linkSystemLibrary("mpfr", .{});
    oracle_fuzz_module.linkSystemLibrary("gmp", .{});
    oracle_fuzz_module.linkSystemLibrary("flint", .{});
    const oracle_fuzz_tests = b.addTest(.{
        .name = "oracle-fuzz",
        .root_module = oracle_fuzz_module,
    });
    const run_oracle_fuzz = b.addRunArtifact(oracle_fuzz_tests);
    const oracle_fuzz_step = b.step("oracle-fuzz", "Run bounded Exp oracle fuzzing");
    oracle_fuzz_step.dependOn(&run_oracle_fuzz.step);

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
