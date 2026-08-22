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
  ];

  env = {
    C_INCLUDE_PATH = pkgs.lib.makeIncludePath packages;
    LIBRARY_PATH = pkgs.lib.makeLibraryPath packages;
    LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath packages;
  };

  scripts.gate.exec = "zig-gate";

  scripts.coverage.exec = ''
    PATH=${coverageZig}:$PATH ~/tools/zcov/zig-out/bin/zig-cov test
  '';
}
