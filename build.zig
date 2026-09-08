const std = @import("std");
const benchmark_targets = @import("bench/targets.zig");
const benchmark_target_info = @import("bench/target_info.zig");
const ArtifactAcceptance = struct {
    operation: []const u8,
    format: u8,
    required_row_count: usize,
};

const artifact_acceptances = [_]ArtifactAcceptance{
    .{ .operation = "exp", .format = 'h', .required_row_count = 65_536 },
    .{ .operation = "exp", .format = 'f', .required_row_count = 29 },
    .{ .operation = "exp", .format = 'd', .required_row_count = 182 },
    .{ .operation = "log", .format = 'h', .required_row_count = 65_536 },
    .{
        .operation = "log",
        .format = 'f',
        .required_row_count = benchmark_targets.scalar_log_f.input_count,
    },
    .{ .operation = "sin", .format = 'h', .required_row_count = 65_536 },
};

fn artifactAcceptance(operation: []const u8, format: u8) ?ArtifactAcceptance {
    for (artifact_acceptances) |acceptance| {
        if (acceptance.format == format and
            std.mem.eql(u8, acceptance.operation, operation))
        {
            return acceptance;
        }
    }
    return null;
}

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

fn addReferencedCorpusArtifacts(
    b: *std.Build,
    corpus_support_package: anytype,
    target_text: ?[]const u8,
    cpu_text: ?[]const u8,
    mode_text: ?[]const u8,
) []const u8 {
    const manifest = @embedFile("test/corpus/manifest.toml");
    var artifact_entries: std.ArrayList(u8) = .empty;
    var current_operation: ?[]const u8 = null;
    var current_status: ?[]const u8 = null;
    var current_result: ?[]const u8 = null;
    var current_inputs: ?[]const u8 = null;
    var in_function = false;

    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.eql(u8, line, "[[function]]")) {
            if (in_function) {
                addFunctionArtifact(
                    b,
                    corpus_support_package,
                    &artifact_entries,
                    target_text,
                    cpu_text,
                    mode_text,
                    current_operation,
                    current_status,
                    current_result,
                    current_inputs,
                );
            }
            current_operation = null;
            current_status = null;
            current_result = null;
            current_inputs = null;
            in_function = true;
            continue;
        }
        if (!in_function) continue;

        const equal_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equal_index], " \t");
        const value = std.mem.trim(u8, line[equal_index + 1 ..], " \t");
        const text = unquoteBuildValue(value) orelse value;
        if (std.mem.eql(u8, key, "op")) {
            current_operation = text;
        } else if (std.mem.eql(u8, key, "status")) {
            current_status = text;
        } else if (std.mem.eql(u8, key, "result")) {
            current_result = text;
        } else if (std.mem.eql(u8, key, "inputs")) {
            current_inputs = value;
        }
    }

    if (in_function) {
        addFunctionArtifact(
            b,
            corpus_support_package,
            &artifact_entries,
            target_text,
            cpu_text,
            mode_text,
            current_operation,
            current_status,
            current_result,
            current_inputs,
        );
    }
    return artifact_entries.items;
}

fn addFunctionArtifact(
    b: *std.Build,
    corpus_support_package: anytype,
    artifact_entries: *std.ArrayList(u8),
    target_text: ?[]const u8,
    cpu_text: ?[]const u8,
    mode_text: ?[]const u8,
    operation: ?[]const u8,
    status: ?[]const u8,
    result: ?[]const u8,
    inputs: ?[]const u8,
) void {
    const accepted = status orelse return;
    if (!std.mem.eql(u8, accepted, "correct") and
        !std.mem.eql(u8, accepted, "bounded"))
    {
        return;
    }
    const operation_text = operation orelse @panic("accepted manifest row has no operation");
    const format = descriptorFormat(result orelse "", inputs orelse "") orelse
        @panic("accepted manifest row has no floating format");
    const acceptance = artifactAcceptance(operation_text, format) orelse
        @panic("accepted manifest row has no approved artifact evidence");
    const artifact_path = b.fmt(
        "test/corpus/{s}_{c}.tsv",
        .{ operation_text, format },
    );
    std.Io.Dir.cwd().access(b.graph.io, artifact_path, .{}) catch |err| {
        std.debug.panic(
            "manifest references missing corpus artifact {s}: {s}",
            .{ artifact_path, @errorName(err) },
        );
    };
    _ = corpus_support_package.addCopyFile(b.path(artifact_path), artifact_path);

    const artifact_metadata = if (target_text != null and cpu_text != null and mode_text != null) blk: {
        validateMetadataText(target_text.?);
        validateMetadataText(cpu_text.?);
        validateMetadataText(mode_text.?);
        break :blk b.fmt(
            "corpus.ArtifactMetadata{{\n" ++
                "            .artifact_name = \"{s}\",\n" ++
                "            .target_mode = corpus.TargetMode{{ .target = \"{s}\", .cpu = \"{s}\", .mode = \"{s}\" }},\n" ++
                "            .required_row_count = {d},\n" ++
                "        }}",
            .{
                artifact_path,
                target_text.?,
                cpu_text.?,
                mode_text.?,
                acceptance.required_row_count,
            },
        );
    } else "null";
    artifact_entries.appendSlice(
        b.graph.arena,
        b.fmt(
            "    corpus.EmbeddedArtifact{{\n" ++
                "        .source = @embedFile(\"{s}\"),\n" ++
                "        .metadata = {s},\n" ++
                "    }},\n",
            .{ artifact_path, artifact_metadata },
        ),
    ) catch @panic("OOM");
}

fn unquoteBuildValue(value: []const u8) ?[]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') {
        return null;
    }
    return value[1 .. value.len - 1];
}

fn descriptorFormat(result: []const u8, inputs: []const u8) ?u8 {
    if (std.mem.startsWith(u8, result, "float:") and result.len == "float:x".len) {
        return result[result.len - 1];
    }
    if (std.mem.startsWith(u8, result, "struct:") and result.len > 0) {
        const format = result[result.len - 1];
        if (format == 'h' or format == 'f' or format == 'd') return format;
    }
    const marker = "float:";
    const marker_index = std.mem.indexOf(u8, inputs, marker) orelse return null;
    const format_index = marker_index + marker.len;
    if (format_index >= inputs.len) return null;
    const format = inputs[format_index];
    if (format == 'h' or format == 'f' or format == 'd') return format;
    return null;
}

fn validateMetadataText(value: []const u8) void {
    if (value.len == 0) @panic("corpus target/CPU/mode metadata must not be empty");
    for (value) |character| {
        const alpha_numeric =
            (character >= 'a' and character <= 'z') or
            (character >= 'A' and character <= 'Z') or
            (character >= '0' and character <= '9');
        if (!alpha_numeric and character != '_' and character != '-' and
            character != '.' and character != '+')
        {
            @panic("corpus target/CPU/mode metadata contains an invalid character");
        }
    }
}

fn addEmbeddedArtifactModule(
    b: *std.Build,
    package: anytype,
    target_text: ?[]const u8,
    cpu_text: ?[]const u8,
    mode_text: ?[]const u8,
    artifact_entries: []const u8,
) std.Build.LazyPath {
    const metadata = if (target_text != null and cpu_text != null and mode_text != null) blk: {
        validateMetadataText(target_text.?);
        validateMetadataText(cpu_text.?);
        validateMetadataText(mode_text.?);
        break :blk b.fmt(
            "pub const target_mode: ?corpus.TargetMode = corpus.TargetMode{{ .target = \"{s}\", .cpu = \"{s}\", .mode = \"{s}\" }};\n",
            .{ target_text.?, cpu_text.?, mode_text.? },
        );
    } else "pub const target_mode: ?corpus.TargetMode = null;\n";
    const artifacts = if (artifact_entries.len == 0)
        "pub const artifacts = [_]corpus.EmbeddedArtifact{};\n"
    else
        b.fmt(
            "pub const artifacts = [_]corpus.EmbeddedArtifact{{\n{s}}};\n",
            .{artifact_entries},
        );
    return package.add(
        "corpus_artifacts.zig",
        b.fmt(
            "const corpus = @import(\"corpus_support\");\n{s}{s}",
            .{ metadata, artifacts },
        ),
    );
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bench_target_name = b.option(
        []const u8,
        "bench-target",
        "Select the public benchmark target",
    ) orelse benchmark_targets.scalar_log_f.name;
    const bench_target = benchmark_targets.parse(bench_target_name) catch
        @panic("unknown benchmark target");
    const bench_info = benchmark_target_info.resolve(b, target, optimize);
    const benchmark_options = b.addOptions();
    benchmark_options.addOption([]const u8, "name", bench_target.name);
    benchmark_options.addOption([]const u8, "corpus_id", bench_target.corpus_id);
    benchmark_options.addOption(usize, "input_count", bench_target.input_count);
    benchmark_options.addOption(u64, "operation_count", bench_target.operation_count);
    benchmark_options.addOption([]const u8, "corpus_sha256", bench_target.corpus_sha256);
    benchmark_options.addOption([]const u8, "target_triple", bench_info.target_triple);
    benchmark_options.addOption([]const u8, "cpu_features", bench_info.cpu_features);
    benchmark_options.addOption([]const u8, "optimize", bench_info.optimize);
    const coverage = b.option(bool, "coverage", "Enable zig-cov instrumentation") orelse false;
    const coverage_runtime = b.option([]const u8, "coverage-rt", "Path to zig-cov runtime object");
    const active_target = bench_info.target_triple;
    const active_cpu = target.result.cpu.model.name;
    const active_mode = @tagName(optimize);
    const corpus_target = active_target;
    const corpus_cpu = active_cpu;
    const corpus_mode = active_mode;
    const active_options = b.addOptions();
    active_options.addOption(
        []const u8,
        "target",
        active_target,
    );
    active_options.addOption([]const u8, "cpu", active_cpu);
    active_options.addOption([]const u8, "mode", active_mode);
    active_options.addOption(
        bool,
        "approved_corpus_pair",
        benchmark_target_info.isApprovedCorpusTarget(target.result) and
            benchmark_target_info.isApprovedCorpusCpu(target.result) and
            benchmark_target_info.isApprovedCorpusMode(optimize),
    );

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

    const target_policy_module = b.createModule(.{
        .root_source_file = b.path("bench/target_info.zig"),
        .target = target,
        .optimize = optimize,
    });
    const target_policy_tests = b.addTest(.{ .root_module = target_policy_module });
    enableCoverage(coverage, coverage_runtime, target_policy_tests);
    const run_target_policy_tests = b.addRunArtifact(target_policy_tests);

    const test_step = b.step("test", "Run public zmath integration tests");
    test_step.dependOn(&run_target_policy_tests.step);

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
    const artifact_entries = addReferencedCorpusArtifacts(
        b,
        corpus_support_package,
        corpus_target,
        corpus_cpu,
        corpus_mode,
    );
    const corpus_artifacts_root = addEmbeddedArtifactModule(
        b,
        corpus_support_package,
        corpus_target,
        corpus_cpu,
        corpus_mode,
        artifact_entries,
    );
    const corpus_support_module = b.createModule(.{
        .root_source_file = corpus_support_root,
        .target = target,
        .optimize = optimize,
    });
    const corpus_artifacts_module = b.createModule(.{
        .root_source_file = corpus_artifacts_root,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "corpus_support",
            .module = corpus_support_module,
        }},
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
            .{ .name = "corpus_artifacts", .module = corpus_artifacts_module },
        },
        .link_libc = true,
    });
    oracle_module.addOptions("active_target_mode", active_options);

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
    const corpus_producer_module = b.createModule(.{
        .root_source_file = b.path("test/oracle/corpus_producer.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    corpus_producer_module.addCSourceFile(.{
        .file = b.path("test/oracle/oracle_bridge.c"),
        .flags = &.{"-std=c11"},
    });
    corpus_producer_module.addIncludePath(b.path("test/oracle"));
    corpus_producer_module.linkSystemLibrary("mpfr", .{});
    corpus_producer_module.linkSystemLibrary("gmp", .{});
    corpus_producer_module.linkSystemLibrary("flint", .{});
    const corpus_producer = b.addExecutable(.{
        .name = "zmath-testing-corpus-producer",
        .root_module = corpus_producer_module,
    });
    const run_corpus_producer = b.addRunArtifact(corpus_producer);
    run_corpus_producer.addArg(b.pathFromRoot("test/corpus"));
    const corpus_producer_step = b.step(
        "generate-corpus",
        "Generate immutable MPFR and Arb corpus artifacts",
    );
    corpus_producer_step.dependOn(&run_corpus_producer.step);

    const corpus_runner_module = b.createModule(.{
        .root_source_file = b.path("test/oracle/corpus_runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zmath", .module = zmath_module },
            .{ .name = "corpus_support", .module = corpus_support_module },
            .{ .name = "corpus_artifacts", .module = corpus_artifacts_module },
        },
        .link_libc = true,
        .fuzz = true,
    });
    corpus_runner_module.addOptions("active_target_mode", active_options);

    const oracle_fuzz_module = b.createModule(.{
        .root_source_file = b.path("test/oracle/oracle_fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zmath", .module = zmath_module },
            .{ .name = "corpus_support", .module = corpus_support_module },
            .{ .name = "corpus_runner", .module = corpus_runner_module },
        },
        .link_libc = true,
        .fuzz = true,
    });
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

    const benchmark_package = b.addWriteFiles();
    const benchmark_root = benchmark_package.addCopyFile(
        b.path("bench/public_api.zig"),
        "public_api.zig",
    );
    _ = benchmark_package.addCopyFile(
        b.path("bench/targets.zig"),
        "targets.zig",
    );
    _ = benchmark_package.addCopyFile(
        b.path("test/corpus/log_f.tsv"),
        "log_f.tsv",
    );

    const benchmark_module = b.createModule(.{
        .root_source_file = benchmark_root,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zmath", .module = zmath_module }},
    });
    benchmark_module.addOptions("benchmark_target", benchmark_options);
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
