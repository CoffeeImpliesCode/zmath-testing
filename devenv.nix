{ pkgs, ... }:

rec {
  packages = with pkgs; [
    gmp
    mpfr
    flint
    pkg-config
    hyperfine
    valgrind
    perf-tools
  ];

  env = {
    C_INCLUDE_PATH = pkgs.lib.makeIncludePath packages;
    LIBRARY_PATH = pkgs.lib.makeLibraryPath packages;
    LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath packages;
  };

  scripts.gate.exec = "zig-gate";
}
