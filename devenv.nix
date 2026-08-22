{ pkgs, ... }:

rec {
  packages = with pkgs; [
    # bash
    # pkg-config

    # performance / profiling tooling (ztex: speed is a top priority)
    hyperfine        # CLI timing of benchmarks
    valgrind         # memory / cachegrind analysis
    perf-tools       # linux perf profiler

  ];

  env = {
    LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath packages}";
    INCLUDE_DIRECTORIES = "${pkgs.lib.makeIncludePath packages}";
  };

  scripts.gate.exec = "zig-gate";
}
