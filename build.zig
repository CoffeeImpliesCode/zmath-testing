const std = @import("std");

fn addOracleEvaluatorSupport(b: *std.Build, module: *std.Build.Module) void {
    const evaluator_sources = [_][]const u8{
        "test/oracle/oracle_operation_table.c",
        "test/oracle/oracle_exact_bits.c",
        "test/oracle/oracle_algebraic.c",
        "test/oracle/oracle_transcendental.c",
    };
    for (evaluator_sources) |source| {
        module.addCSourceFile(.{
            .file = b.path(source),
            .flags = &.{"-std=c11"},
        });
    }
    module.addIncludePath(b.path("test/oracle"));
    module.linkSystemLibrary("mpfr", .{});
    module.linkSystemLibrary("gmp", .{});
    module.linkSystemLibrary("flint", .{});
}

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

    const suffix_module = b.createModule(.{
        .root_source_file = b.path("test/integration/numeric_suffixes.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zmath", .module = zmath_module }},
    });
    const suffix_tests = b.addTest(.{ .root_module = suffix_module });
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
    _ = corpus_support_package.addCopyFile(
        b.path("test/support/corpus.zig"),
        "corpus.zig",
    );
    const corpus_v2_test_root = corpus_support_package.addCopyFile(
        b.path("test/support/corpus_v2_test.zig"),
        "corpus_v2_test.zig",
    );
    const corpus_v2_test_module = b.createModule(.{
        .root_source_file = corpus_v2_test_root,
        .target = target,
        .optimize = optimize,
    });
    const corpus_v2_tests = b.addTest(.{ .root_module = corpus_v2_test_module });
    const run_corpus_v2_tests = b.addRunArtifact(corpus_v2_tests);
    test_step.dependOn(&run_corpus_v2_tests.step);

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
    addOracleEvaluatorSupport(b, oracle_module);
    const oracle_tests = b.addTest(.{ .root_module = oracle_module });
    const run_oracle_tests = b.addRunArtifact(oracle_tests);
    const oracle_step = b.step("oracle", "Run MPFR and Arb oracle smoke tests");
    oracle_step.dependOn(&run_oracle_tests.step);

    const oracle_evaluator_test_sources = [_][]const u8{
        "test/oracle/oracle_operation_table_test.zig",
        "test/oracle/oracle_exact_bits_test.zig",
        "test/oracle/oracle_algebraic_test.zig",
        "test/oracle/oracle_transcendental_test.zig",
    };
    for (oracle_evaluator_test_sources) |test_source| {
        const evaluator_test_module = b.createModule(.{
            .root_source_file = b.path(test_source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "corpus_support",
                .module = corpus_support_module,
            }},
            .link_libc = true,
        });
        addOracleEvaluatorSupport(b, evaluator_test_module);
        const evaluator_tests = b.addTest(.{ .root_module = evaluator_test_module });
        const run_evaluator_tests = b.addRunArtifact(evaluator_tests);
        oracle_step.dependOn(&run_evaluator_tests.step);
    }

    const corpus_campaigns_module = b.createModule(.{
        .root_source_file = b.path("test/oracle/corpus_campaigns.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "corpus_support",
            .module = corpus_support_module,
        }},
    });
    const corpus_campaigns_test_module = b.createModule(.{
        .root_source_file = b.path("test/oracle/corpus_campaigns_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "corpus_support", .module = corpus_support_module },
            .{ .name = "corpus_campaigns", .module = corpus_campaigns_module },
        },
    });
    const corpus_campaigns_tests = b.addTest(.{
        .root_module = corpus_campaigns_test_module,
    });
    const run_corpus_campaigns_tests = b.addRunArtifact(corpus_campaigns_tests);
    oracle_step.dependOn(&run_corpus_campaigns_tests.step);

    const corpus_runner_module = b.createModule(.{
        .root_source_file = b.path("test/oracle/corpus_runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zmath", .module = zmath_module },
            .{ .name = "corpus_support", .module = corpus_support_module },
        },
    });
    const corpus_generator_module = b.createModule(.{
        .root_source_file = b.path("test/oracle/corpus_generate.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "corpus_support", .module = corpus_support_module },
            .{ .name = "corpus_campaigns", .module = corpus_campaigns_module },
            .{ .name = "corpus_runner", .module = corpus_runner_module },
        },
        .link_libc = true,
    });
    corpus_generator_module.addCSourceFile(.{
        .file = b.path("test/oracle/oracle_bridge.c"),
        .flags = &.{"-std=c11"},
    });
    addOracleEvaluatorSupport(b, corpus_generator_module);
    const corpus_generator = b.addExecutable(.{
        .name = "zmath-testing-oracle-generate",
        .root_module = corpus_generator_module,
    });
    const run_corpus_generator = b.addRunArtifact(corpus_generator);
    run_corpus_generator.setCwd(b.path("."));
    const oracle_generate_step = b.step(
        "oracle-generate",
        "Materialize deterministic MPFR+Arb ZCDR evidence under test/corpus/generated; manifest statuses are unchanged",
    );
    oracle_generate_step.dependOn(&run_corpus_generator.step);

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
