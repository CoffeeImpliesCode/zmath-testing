const std = @import("std");
const benchmark_targets = @import("bench/targets.zig");
const benchmark_target_info = @import("bench/target_info.zig");
const LegacyArtifactAcceptance = struct {
    operation: []const u8,
    format: u8,
    required_row_count: usize,
};

const legacy_artifact_acceptances = [_]LegacyArtifactAcceptance{
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

fn legacyArtifactAcceptance(operation: []const u8, format: u8) ?LegacyArtifactAcceptance {
    for (legacy_artifact_acceptances) |acceptance| {
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
    // Legacy TSVs are optional regression fixtures. Typed corpus publication
    // and replay remain authoritative for every accepted descriptor.
    const acceptance = legacyArtifactAcceptance(operation_text, format) orelse return;
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

fn addOracleSources(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFiles(.{
        .files = &.{
            "test/oracle/oracle_bridge.c",
            "test/oracle/oracle_operation_table.c",
            "test/oracle/oracle_exact_bits.c",
            "test/oracle/oracle_algebraic.c",
            "test/oracle/oracle_transcendental.c",
        },
        .flags = &.{"-std=c11"},
    });
    module.addIncludePath(b.path("test/oracle"));
}

fn requiredBuildEnv(b: *std.Build, name: []const u8) []const u8 {
    return b.graph.environ_map.get(name) orelse
        @panic(b.fmt(
            "comparative build requires {s}; enter the declared devenv shell",
            .{name},
        ));
}

fn addComparativeObject(
    b: *std.Build,
    compiler: []const u8,
    source_path: []const u8,
    output_name: []const u8,
    flags: []const []const u8,
    include_dirs: []const []const u8,
    definitions: []const []const u8,
    input_paths: []const []const u8,
) std.Build.LazyPath {
    const compile = b.addSystemCommand(&.{compiler});
    compile.addArgs(flags);
    for (include_dirs) |include_dir| {
        compile.addArg(b.fmt("-I{s}", .{include_dir}));
    }
    compile.addArgs(definitions);
    for (input_paths) |input_path| {
        compile.addFileInput(b.path(input_path));
    }
    compile.addArg("-c");
    compile.addArg("-o");
    const object = compile.addOutputFileArg(output_name);
    compile.addFileArg(b.path(source_path));
    return object;
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
    benchmark_options.addOption([]const u8, "corpus_target", corpus_target);
    benchmark_options.addOption([]const u8, "corpus_cpu", corpus_cpu);
    benchmark_options.addOption([]const u8, "corpus_mode", corpus_mode);
    benchmark_options.addOption(
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

    const benchmark_target_module = b.createModule(.{
        .root_source_file = b.path("bench/targets.zig"),
        .target = target,
        .optimize = optimize,
    });
    const benchmark_target_tests = b.addTest(.{ .root_module = benchmark_target_module });
    enableCoverage(coverage, coverage_runtime, benchmark_target_tests);
    const run_benchmark_target_tests = b.addRunArtifact(benchmark_target_tests);

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
    test_step.dependOn(&run_benchmark_target_tests.step);
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
    const corpus_support_tests = b.addTest(.{ .root_module = corpus_support_module });
    enableCoverage(coverage, coverage_runtime, corpus_support_tests);
    const run_corpus_support_tests = b.addRunArtifact(corpus_support_tests);
    test_step.dependOn(&run_corpus_support_tests.step);

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

    const oracle_abi = b.addTranslateC(.{
        .root_source_file = b.path("test/oracle/oracle_evaluators.h"),
        .target = target,
        .optimize = optimize,
    });
    oracle_abi.addIncludePath(b.path("test/oracle"));
    const oracle_abi_module = oracle_abi.createModule();

    const oracle_module = b.createModule(.{
        .root_source_file = b.path("test/oracle/oracle_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zmath", .module = zmath_module },
            .{ .name = "corpus_support", .module = corpus_support_module },
            .{ .name = "corpus_artifacts", .module = corpus_artifacts_module },
            .{ .name = "oracle_abi", .module = oracle_abi_module },
        },
        .link_libc = true,
    });
    oracle_module.addOptions("active_target_mode", active_options);

    oracle_module.addCSourceFile(.{
        .file = b.path("test/oracle/oracle_smoke.c"),
        .flags = &.{"-std=c11"},
    });
    addOracleSources(b, oracle_module);
    oracle_module.linkSystemLibrary("mpfr", .{});
    oracle_module.linkSystemLibrary("gmp", .{});
    oracle_module.linkSystemLibrary("flint", .{});
    const oracle_tests = b.addTest(.{ .root_module = oracle_module });
    enableCoverage(coverage, coverage_runtime, oracle_tests);
    const run_oracle_tests = b.addRunArtifact(oracle_tests);
    const oracle_step = b.step("oracle", "Run typed scalar reference and proof checks");
    oracle_step.dependOn(&run_oracle_tests.step);
    const transcendental_regression_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addOracleSources(b, transcendental_regression_module);
    transcendental_regression_module.addCSourceFile(.{
        .file = b.path("test/oracle/oracle_transcendental_regression.c"),
        .flags = &.{"-std=c11"},
    });
    transcendental_regression_module.linkSystemLibrary("mpfr", .{});
    transcendental_regression_module.linkSystemLibrary("gmp", .{});
    transcendental_regression_module.linkSystemLibrary("flint", .{});
    const transcendental_regression = b.addExecutable(.{
        .name = "oracle-transcendental-regression",
        .root_module = transcendental_regression_module,
    });
    const run_transcendental_regression = b.addRunArtifact(transcendental_regression);
    oracle_step.dependOn(&run_transcendental_regression.step);

    const corpus_campaigns_module = b.createModule(.{
        .root_source_file = b.path("test/oracle/corpus_campaigns.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "corpus_support",
            .module = corpus_support_module,
        }},
    });
    const campaign_tests = b.addTest(.{ .root_module = corpus_campaigns_module });
    const run_campaign_tests = b.addRunArtifact(campaign_tests);
    test_step.dependOn(&run_campaign_tests.step);
    const campaign_test_step = b.step("test-campaigns", "Check deterministic scalar campaign ordering");
    campaign_test_step.dependOn(&run_campaign_tests.step);

    const corpus_set_module = b.createModule(.{
        .root_source_file = b.path("test/support/corpus_set.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "corpus_support", .module = corpus_support_module },
            .{ .name = "corpus_campaigns", .module = corpus_campaigns_module },
            .{ .name = "oracle_abi", .module = oracle_abi_module },
        },
    });

    const scalar_runner_module = b.createModule(.{
        .root_source_file = b.path("test/oracle/corpus_runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zmath", .module = zmath_module },
            .{ .name = "corpus_support", .module = corpus_support_module },
            .{ .name = "corpus_artifacts", .module = corpus_artifacts_module },
        },
    });
    scalar_runner_module.addOptions("active_target_mode", active_options);
    const corpus_producer_module = b.createModule(.{
        .root_source_file = b.path("test/oracle/corpus_generate.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "corpus_support", .module = corpus_support_module },
            .{ .name = "corpus_campaigns", .module = corpus_campaigns_module },
            .{ .name = "corpus_runner", .module = scalar_runner_module },
            .{ .name = "oracle_abi", .module = oracle_abi_module },
            .{ .name = "corpus_set", .module = corpus_set_module },
        },
        .link_libc = true,
    });
    corpus_producer_module.addOptions("active_target_mode", active_options);

    addOracleSources(b, corpus_producer_module);
    corpus_producer_module.linkSystemLibrary("mpfr", .{});
    corpus_producer_module.linkSystemLibrary("gmp", .{});
    corpus_producer_module.linkSystemLibrary("flint", .{});
    const generator_tests = b.addTest(.{ .root_module = corpus_producer_module });
    const run_generator_tests = b.addRunArtifact(generator_tests);
    oracle_step.dependOn(&run_generator_tests.step);
    const generator_test_step = b.step("test-generator", "Check scalar corpus publication and profile guards");
    generator_test_step.dependOn(&run_generator_tests.step);
    const corpus_producer = b.addExecutable(.{
        .name = "zmath-testing-corpus-producer",
        .root_module = corpus_producer_module,
    });
    const install_corpus_producer = b.addInstallArtifact(corpus_producer, .{});
    const generator_step = b.step("oracle-generator", "Build the typed scalar corpus generator");
    generator_step.dependOn(&install_corpus_producer.step);
    const run_corpus_producer = b.addRunArtifact(corpus_producer);
    run_corpus_producer.addArg("test/corpus");
    if (b.args) |args| run_corpus_producer.addArgs(args);
    const corpus_producer_step = b.step(
        "generate-corpus",
        "Generate verified typed scalar corpus artifacts",
    );
    corpus_producer_step.dependOn(&run_corpus_producer.step);

    const corpus_replay_module = b.createModule(.{
        .root_source_file = b.path("test/oracle/corpus_replay.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "corpus_support", .module = corpus_support_module },
            .{ .name = "corpus_set", .module = corpus_set_module },
            .{ .name = "corpus_runner", .module = scalar_runner_module },
        },
        .link_libc = true,
    });
    corpus_replay_module.addOptions("active_target_mode", active_options);
    corpus_replay_module.addIncludePath(b.path("test/oracle"));
    corpus_replay_module.addCSourceFile(.{
        .file = b.path("test/oracle/oracle_operation_table.c"),
        .flags = &.{"-std=c11"},
    });
    const corpus_replay = b.addExecutable(.{
        .name = "zmath-corpus-replay",
        .root_module = corpus_replay_module,
    });
    const install_corpus_replay = b.addInstallArtifact(corpus_replay, .{});
    const replay_build_step = b.step("corpus-replay", "Build the typed scalar corpus replay");
    replay_build_step.dependOn(&install_corpus_replay.step);
    const run_corpus_replay = b.addRunArtifact(corpus_replay);
    run_corpus_replay.addArg("test/corpus");
    if (b.args) |args| run_corpus_replay.addArgs(args);
    const replay_step = b.step("replay-corpus", "Verify every published scalar corpus record");
    replay_step.dependOn(&run_corpus_replay.step);

    // Zig 0.16's built-in fuzzer expects every __sancov_cntrs byte to have
    // one entry in Zig's __sancov_pcs1. Clang writes two-word C records to
    // __sancov_pcs while sharing __sancov_cntrs, so mixed Zig/C fuzz-mode
    // compilation violates that invariant. This campaign is intentionally
    // Exp-only: use the same dependency source without zmath's C kernel
    // link objects, and compile only the MPFR/Arb oracle bridge separately.
    // A future C-backed campaign must use a supported C coverage layout; this
    // module deliberately omits those kernels so an accidental C-backed call
    // fails at link time instead of silently losing kernel coverage.
    const zmath_exp_fuzz_module = b.createModule(.{
        .root_source_file = zmath_dependency.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const oracle_fuzz_bridge_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .fuzz = false,
        .link_libc = true,
    });
    addOracleSources(b, oracle_fuzz_bridge_module);
    const oracle_fuzz_bridge = b.addLibrary(.{
        .name = "oracle-fuzz-bridge",
        .root_module = oracle_fuzz_bridge_module,
    });

    const corpus_runner_module = b.createModule(.{
        .root_source_file = b.path("test/oracle/corpus_runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zmath", .module = zmath_exp_fuzz_module },
            .{ .name = "corpus_support", .module = corpus_support_module },
            .{ .name = "corpus_artifacts", .module = corpus_artifacts_module },
        },
        .link_libc = true,
    });
    corpus_runner_module.addOptions("active_target_mode", active_options);

    const oracle_fuzz_module = b.createModule(.{
        .root_source_file = b.path("test/oracle/oracle_fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zmath", .module = zmath_exp_fuzz_module },
            .{ .name = "corpus_support", .module = corpus_support_module },
            .{ .name = "corpus_runner", .module = corpus_runner_module },
        },
        .link_libc = true,
    });
    oracle_fuzz_module.linkLibrary(oracle_fuzz_bridge);
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
        b.path("test/corpus/exp_h.tsv"),
        "exp_h.tsv",
    );
    _ = benchmark_package.addCopyFile(
        b.path("test/corpus/exp_f.tsv"),
        "exp_f.tsv",
    );
    _ = benchmark_package.addCopyFile(
        b.path("test/corpus/exp_d.tsv"),
        "exp_d.tsv",
    );
    _ = benchmark_package.addCopyFile(
        b.path("test/corpus/log_h.tsv"),
        "log_h.tsv",
    );
    _ = benchmark_package.addCopyFile(
        b.path("test/corpus/log_f.tsv"),
        "log_f.tsv",
    );
    _ = benchmark_package.addCopyFile(
        b.path("test/corpus/sin_h.tsv"),
        "sin_h.tsv",
    );

    const benchmark_module = b.createModule(.{
        .root_source_file = benchmark_root,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zmath", .module = zmath_module },
            .{ .name = "corpus_support", .module = corpus_support_module },
        },
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

    const scalar_benchmark_module = b.createModule(.{
        .root_source_file = b.path("bench/scalar_matrix.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "scalar_runner", .module = scalar_runner_module },
            .{ .name = "corpus_support", .module = corpus_support_module },
            .{ .name = "corpus_set", .module = corpus_set_module },
        },
    });
    scalar_benchmark_module.addOptions("active_target_mode", active_options);
    scalar_benchmark_module.addIncludePath(b.path("test/oracle"));
    scalar_benchmark_module.addCSourceFile(.{
        .file = b.path("test/oracle/oracle_operation_table.c"),
        .flags = &.{"-std=c11"},
    });
    const scalar_benchmark = b.addExecutable(.{
        .name = "zmath-scalar-matrix",
        .root_module = scalar_benchmark_module,
    });
    const install_scalar_benchmark = b.addInstallArtifact(scalar_benchmark, .{});
    const scalar_bench_step = b.step("bench-scalar", "Build typed scalar corpus benchmarks");
    scalar_bench_step.dependOn(&install_scalar_benchmark.step);
    const run_scalar_benchmark = b.addRunArtifact(scalar_benchmark);
    run_scalar_benchmark.addArg("test/corpus");
    if (b.args) |args| run_scalar_benchmark.addArgs(args);
    const run_scalar_bench_step = b.step("run-bench-scalar", "Benchmark typed scalar corpora");
    run_scalar_bench_step.dependOn(&run_scalar_benchmark.step);

    const power_module = b.createModule(.{
        .root_source_file = b.path("bench/power_resource.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zmath", .module = zmath_module }},
    });
    const power_executable = b.addExecutable(.{
        .name = "zmath-power-resource",
        .root_module = power_module,
    });
    const install_power = b.addInstallArtifact(power_executable, .{});
    const bench_power_step = b.step(
        "bench-power",
        "Build and install the power resource benchmark",
    );
    bench_power_step.dependOn(&install_power.step);

    const run_power = b.addRunArtifact(power_executable);
    run_power.step.dependOn(&install_power.step);
    if (b.args) |args| run_power.addArgs(args);
    const run_power_step = b.step("run-power", "Run the power resource benchmark");
    run_power_step.dependOn(&run_power.step);
    // The comparative lane uses an explicit GNU toolchain so its C++ ABI is
    // identical to the packaged Google Benchmark library.
    const compare_target_query = std.Target.Query.parse(.{
        .arch_os_abi = "x86_64-linux-gnu.2.38",
        .cpu_features = "haswell",
    }) catch @panic("invalid comparative benchmark target");
    const compare_target = b.resolveTargetQuery(compare_target_query);
    const compare_optimize =
        b.option(std.builtin.OptimizeMode, "compare-optimize", "Optimization mode for the comparative benchmark") orelse
        .ReleaseSafe;
    const compare_zmath_dependency = b.dependency("zmath", .{
        .target = compare_target,
        .optimize = compare_optimize,
    });
    const compare_zmath_module = compare_zmath_dependency.module("zmath");
    const comparative_bridge_module = b.createModule(.{
        .root_source_file = b.path("bench/comparative_bridge.zig"),
        .target = compare_target,
        .optimize = compare_optimize,
        .imports = &.{.{ .name = "zmath", .module = compare_zmath_module }},
        .link_libc = true,
    });
    const comparative_bridge = b.addLibrary(.{
        .name = "comparative_bridge",
        .linkage = .static,
        .root_module = comparative_bridge_module,
    });
    comparative_bridge.bundle_compiler_rt = true;

    const compare_cc = requiredBuildEnv(b, "ZMATH_COMPARE_CC");
    const compare_cxx = requiredBuildEnv(b, "ZMATH_COMPARE_CXX");
    const compare_compiler = requiredBuildEnv(b, "ZMATH_COMPARE_COMPILER");
    const gbenchmark_include_dir = requiredBuildEnv(b, "ZMATH_COMPARE_GBENCHMARK_INCLUDE_DIR");
    const gbenchmark_library_dir = requiredBuildEnv(b, "ZMATH_COMPARE_GBENCHMARK_LIBRARY_DIR");
    const mpfr_include_dir = requiredBuildEnv(b, "ZMATH_COMPARE_MPFR_INCLUDE_DIR");
    const mpfr_library_dir = requiredBuildEnv(b, "ZMATH_COMPARE_MPFR_LIBRARY_DIR");
    const gmp_include_dir = requiredBuildEnv(b, "ZMATH_COMPARE_GMP_INCLUDE_DIR");
    const gmp_library_dir = requiredBuildEnv(b, "ZMATH_COMPARE_GMP_LIBRARY_DIR");
    const compare_libm_path = requiredBuildEnv(b, "ZMATH_COMPARE_LIBM_PATH");
    if (compare_libm_path.len == 0 or compare_libm_path[0] != '/') {
        @panic("ZMATH_COMPARE_LIBM_PATH must be absolute");
    }
    const compare_target_name = "x86_64-linux-haswell";
    const compare_build_mode = @tagName(compare_optimize);
    const compare_cxx_flags_text =
        "-std=c++17 -O3 -march=haswell -ffp-contract=off -fno-builtin -fno-fast-math -fno-lto";
    const compare_c_flags = [_][]const u8{
        "-std=c11",
        "-O3",
        "-march=haswell",
        "-ffp-contract=off",
        "-fno-builtin",
        "-fno-fast-math",
        "-fno-lto",
    };
    const compare_c_definitions = [_][]const u8{
        b.fmt("-DCOMPARATIVE_LIBM_PATH=\"{s}\"", .{compare_libm_path}),
    };
    const compare_cxx_flags = [_][]const u8{
        "-std=c++17",
        "-O3",
        "-march=haswell",
        "-ffp-contract=off",
        "-fno-builtin",
        "-fno-fast-math",
        "-fno-lto",
    };
    const compare_cxx_definitions = [_][]const u8{
        b.fmt("-DCOMPARATIVE_BUILD_MODE=\"{s}\"", .{compare_build_mode}),
        b.fmt("-DCOMPARATIVE_TARGET=\"{s}\"", .{compare_target_name}),
        b.fmt("-DCOMPARATIVE_COMPILER=\"{s}\"", .{compare_compiler}),
        b.fmt("-DCOMPARATIVE_CXX_FLAGS=\"{s}\"", .{compare_cxx_flags_text}),
    };
    const compare_include_dirs = [_][]const u8{
        "bench",
        gbenchmark_include_dir,
        mpfr_include_dir,
        gmp_include_dir,
    };
    const comparative_libm_object = addComparativeObject(
        b,
        compare_cc,
        "bench/comparative_libm.c",
        "comparative_libm.o",
        &compare_c_flags,
        &compare_include_dirs,
        &compare_c_definitions,
        &.{"bench/comparative.h"},
    );
    const comparative_object = addComparativeObject(
        b,
        compare_cxx,
        "bench/comparative.cpp",
        "comparative.o",
        &compare_cxx_flags,
        &compare_include_dirs,
        &compare_cxx_definitions,
        &.{
            "bench/comparative.h",
            "bench/comparative_workloads.hpp",
        },
    );
    const comparative_workloads_object = addComparativeObject(
        b,
        compare_cxx,
        "bench/comparative_workloads.cpp",
        "comparative_workloads.o",
        &compare_cxx_flags,
        &compare_include_dirs,
        &compare_cxx_definitions,
        &.{
            "bench/comparative.h",
            "bench/comparative_workloads.hpp",
        },
    );

    const compare_link_flags = [_][]const u8{
        "-O3",
        "-march=haswell",
        "-ffp-contract=off",
        "-fno-builtin",
        "-fno-fast-math",
        "-fno-lto",
        "-pthread",
    };
    const compare_link = b.addSystemCommand(&.{compare_cxx});
    compare_link.addArgs(&compare_link_flags);
    compare_link.addArg("-o");
    const compare_binary = compare_link.addOutputFileArg("zmath-compare");
    compare_link.addFileArg(comparative_libm_object);
    compare_link.addFileArg(comparative_object);
    compare_link.addFileArg(comparative_workloads_object);
    compare_link.addFileArg(comparative_bridge.getEmittedBin());
    compare_link.addArg(b.fmt("-L{s}", .{gbenchmark_library_dir}));
    compare_link.addArg("-lbenchmark");
    compare_link.addArg(b.fmt("-L{s}", .{mpfr_library_dir}));
    compare_link.addArg("-lmpfr");
    compare_link.addArg(b.fmt("-L{s}", .{gmp_library_dir}));
    compare_link.addArg("-lgmp");
    compare_link.addArg("-lm");
    compare_link.addArg("-ldl");

    const install_comparative = b.addInstallBinFile(compare_binary, "zmath-compare");
    const compare_step = b.step("compare", "Build and install zmath-compare");
    compare_step.dependOn(&install_comparative.step);

    const run_comparative = std.Build.Step.Run.create(b, "run zmath-compare");
    run_comparative.addFileArg(compare_binary);
    run_comparative.step.dependOn(&install_comparative.step);
    if (b.args) |args| run_comparative.addArgs(args);
    const run_compare_step = b.step("run-compare", "Run the comparative benchmark");
    run_compare_step.dependOn(&run_comparative.step);
}
