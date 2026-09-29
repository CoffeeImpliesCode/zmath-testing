{ pkgs, ... }:

let
  coreMathRevision = "3bafed75e3c22399531857d63a3fa0e24bfb42fa";
  coreMathArchiveUrl = "https://gitlab.inria.fr/api/v4/projects/core-math%2Fcore-math/repository/archive.tar.gz?sha=${coreMathRevision}";
  coreMathArchive = pkgs.fetchzip {
    name = "core-math-${coreMathRevision}";
    url = coreMathArchiveUrl;
    hash = "sha256-6BaQd5HqWk6mHbqciryRYy3kSqS7aJEgGDUy1f3lVaQ=";
  };
  coreMathSource = pkgs.applyPatches {
    name = "core-math-${coreMathRevision}-source";
    src = coreMathArchive;
    postPatch = ''
      cat > .zmath-source-provenance <<'EOF'
      revision=${coreMathRevision}
      archive_url=${coreMathArchiveUrl}
      EOF
    '';
  };

  glibcPatches = pkgs.glibc.patches or [ ];
  glibcPatchNames = map
    (patch: builtins.baseNameOf (toString patch))
    glibcPatches;
  glibcSource = pkgs.applyPatches {
    name = "${pkgs.glibc.name}-source";
    src = pkgs.glibc.src;
    patches = glibcPatches;
    postPatch = (pkgs.glibc.postPatch or "") + ''
      cat > .zmath-source-provenance <<'EOF'
      package=${pkgs.glibc.name}
      package_version=${pkgs.glibc.name}
      upstream_version=${pkgs.glibc.version}
      upstream_source=${pkgs.glibc.src.name}
      nixpkgs_source=${pkgs.path}
      patch_count=${toString (builtins.length glibcPatches)}
      patches:
      ${pkgs.lib.concatMapStringsSep "\n" (name: "  ${name}") glibcPatchNames}
      post_patch=applied
      EOF
    '';
  };

  coreMathOperations = [
    "exp"
    "log"
    "sin"
    "cos"
    "tan"
    "sqrt"
    "hypot"
    "atan2"
    "pow"
    "acos"
    "acosh"
    "acospi"
    "asin"
    "asinh"
    "asinpi"
    "atan"
    "atan2pi"
    "atanh"
    "atanpi"
    "cbrt"
    "cosh"
    "cospi"
    "erf"
    "erfc"
    "exp10"
    "exp10m1"
    "exp2"
    "exp2m1"
    "expm1"
    "lgamma"
    "log10"
    "log10p1"
    "log1p"
    "log2"
    "log2p1"
    "rsqrt"
    "sinh"
    "sinpi"
    "tanh"
    "tanpi"
    "tgamma"
  ];
  coreMathFormats = [
    {
      directory = "binary32";
      suffix = "f";
      hasSqrt = false;
    }
    {
      directory = "binary64";
      suffix = "";
      hasSqrt = false;
    }
    {
      directory = "binary16";
      suffix = "f16";
      hasSqrt = true;
    }
  ];
  coreMathUnitsUnchecked = pkgs.lib.concatMap (
    format:
    map
      (operation: {
        source = "src/${format.directory}/${operation}/${operation}${format.suffix}.c";
        symbol = "cr_${operation}${format.suffix}";
        object = "${format.directory}-${operation}.o";
      })
      (builtins.filter (operation: format.hasSqrt || operation != "sqrt") coreMathOperations)
  ) coreMathFormats;
  coreMathUnits =
    assert builtins.length coreMathUnitsUnchecked == 121;
    coreMathUnitsUnchecked;
  coreMathCompileFlags = [
    "-O3"
    "-g"
    "-std=gnu11"
    "-march=haswell"
    "-mtune=haswell"
    "-mfma"
    "-fPIC"
    "-frounding-math"
    "-ffp-contract=off"
  ];
  coreMathCompileFlagsString = pkgs.lib.concatStringsSep " " coreMathCompileFlags;
  coreMathCompileFlagsShell = pkgs.lib.escapeShellArgs coreMathCompileFlags;
  coreMathObjectsShell = pkgs.lib.escapeShellArgs (map (unit: unit.object) coreMathUnits);
  coreMathReference = pkgs.stdenvNoCC.mkDerivation {
    pname = "zmath-coremath-reference";
    version = coreMathRevision;
    dontUnpack = true;
    strictDeps = true;
    nativeBuildInputs = [
      pkgs.gcc
    ];
    buildInputs = [ pkgs.glibc ];
    dontStrip = true;

    buildPhase = ''
      runHook preBuild

      ${pkgs.lib.concatMapStringsSep "\n" (unit: ''
        test -f "${coreMathSource}/${unit.source}"
        ${pkgs.gcc}/bin/gcc ${coreMathCompileFlagsShell} \
          -c "${coreMathSource}/${unit.source}" \
          -o "${unit.object}"
      '') coreMathUnits}

      cat > zmath_reference_metadata.c <<'EOF'
      const char *zmath_reference_coremath_revision(void) {
        return "${coreMathRevision}";
      }

      const char *zmath_reference_coremath_compiler(void) {
        return __VERSION__;
      }

      const char *zmath_reference_coremath_flags(void) {
        return "${coreMathCompileFlagsString}";
      }

      const char *zmath_reference_coremath_source(void) {
        return "${coreMathSource}";
      }
      EOF
      ${pkgs.gcc}/bin/gcc ${coreMathCompileFlagsShell} \
        -c zmath_reference_metadata.c \
        -o zmath_reference_metadata.o

      cat > exports.map <<'EOF'
      {
        global:
      ${pkgs.lib.concatMapStringsSep "\n" (unit: "    ${unit.symbol};") coreMathUnits}
          zmath_reference_coremath_revision;
          zmath_reference_coremath_compiler;
          zmath_reference_coremath_flags;
          zmath_reference_coremath_source;
        local:
          *;
      };
      EOF

      ${pkgs.gcc}/bin/gcc -shared \
        -Wl,-soname,libzmath-coremath.so \
        -Wl,-Bsymbolic \
        -Wl,-z,defs \
        -Wl,--version-script=exports.map \
        -Wl,--as-needed \
        -o libzmath-coremath.so \
        ${coreMathObjectsShell} \
        zmath_reference_metadata.o \
        -lm

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      install -Dm0555 libzmath-coremath.so "$out/lib/libzmath-coremath.so"
      install -Dm0444 "${coreMathSource}/LICENSE" "$out/share/licenses/core-math/LICENSE"

      runHook postInstall
    '';

    meta = {
      description = "Independent pinned CORE-MATH reference library for zmath benchmarks";
      homepage = "https://core-math.gitlabpages.inria.fr/";
      license = pkgs.lib.licenses.mit;
      platforms = pkgs.lib.platforms.linux;
    };
  };

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
    perf
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
    ZMATH_CORE_MATH_SOURCE_DIR = "${coreMathSource}";
    ZMATH_GLIBC_SOURCE_DIR = "${glibcSource}";
    ZMATH_COMPARE_COREMATH_PATH = "${coreMathReference}/lib/libzmath-coremath.so";
  };

  # zig-gate builds its ziglint file list with `find`, which bypasses ziglint's own
  # .gitignore handling, so generated artifacts would otherwise be linted as if
  # they were source. Exclude the gitignored result directories here.
  scripts.gate.exec = ''
    GATE_EXCLUDE="./bench/results/ ./.devenv/ ./graphify-out/" zig-gate
  '';

  scripts.coverage.exec = ''
    PATH=${coverageZig}:$PATH ~/tools/zcov/zig-out/bin/zig-cov test
  '';
}
