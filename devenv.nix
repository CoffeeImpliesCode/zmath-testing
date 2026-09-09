{ pkgs, ... }:

let
  coverageZig = pkgs.stdenvNoCC.mkDerivation {
    pname = "zig-coverage";
    version = "0.17.0-dev.1824+7988f7952";
    src = pkgs.fetchurl {
      url = "https://ziglang.org/builds/zig-x86_64-linux-0.17.0-dev.1824+7988f7952.tar.xz";
      hash = "sha256-ssIo3qIezE0LVveGhbfylv0JXla2MN7DlgpHbAUStjE=";
    };
    dontUnpack = true;
    installPhase = ''
      mkdir -p "$out"
      tar -xJf "$src" --strip-components=1 -C "$out"
    '';
  };
in
rec {
  packages = with pkgs; [
    gmp
    mpfr
    flint
    pkg-config
    hyperfine
    valgrind
    perf-tools
    gbenchmark
    clang-tools
    gcc
    python3
    util-linux
  ];

  env = {
    C_INCLUDE_PATH = pkgs.lib.makeIncludePath packages;
    CPLUS_INCLUDE_PATH = pkgs.lib.makeIncludePath packages;
    LIBRARY_PATH = pkgs.lib.makeLibraryPath packages;
    LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath packages;
    ZMATH_COMPARE_CC = "${pkgs.gcc}/bin/gcc";
    ZMATH_COMPARE_CXX = "${pkgs.gcc}/bin/g++";
    ZMATH_COMPARE_COMPILER = "GNU g++ ${pkgs.gcc.version} (Nixpkgs)";
    ZMATH_COMPARE_LIBM_PATH = "${pkgs.lib.getLib pkgs.glibc}/lib/libm.so.6";
    ZMATH_COMPARE_GBENCHMARK_INCLUDE_DIR = "${pkgs.lib.getDev pkgs.gbenchmark}/include";
    ZMATH_COMPARE_GBENCHMARK_LIBRARY_DIR = "${pkgs.lib.getLib pkgs.gbenchmark}/lib";
    ZMATH_COMPARE_MPFR_INCLUDE_DIR = "${pkgs.lib.getDev pkgs.mpfr}/include";
    ZMATH_COMPARE_MPFR_LIBRARY_DIR = "${pkgs.lib.getLib pkgs.mpfr}/lib";
    ZMATH_COMPARE_GMP_INCLUDE_DIR = "${pkgs.lib.getDev pkgs.gmp}/include";
    ZMATH_COMPARE_GMP_LIBRARY_DIR = "${pkgs.lib.getLib pkgs.gmp}/lib";
  };

  scripts.gate.exec = "zig-gate";

  scripts.coverage.exec = ''
    PATH=${coverageZig}:$PATH ~/tools/zcov/zig-out/bin/zig-cov test
  '';
}
