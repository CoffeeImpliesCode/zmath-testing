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

  # This used to fetch a 0.17.0-dev tarball from ziglang.org, which upstream has
  # since removed; the 404 made the whole devshell unbuildable, so nothing in
  # this repository could run. Only scripts.coverage consumes this, and only as a
  # PATH prefix, so resolving it from the locked nixpkgs makes the devshell
  # buildable without touching the main toolchain. The project toolchain stays
  # the 0.16.0 that build.zig.zon asks for as .minimum_zig_version.
  coverageZig = pkgs.zig;
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

  # `zig build` builds the default install target, which is none of the corpus
  # tools, so a green gate did not mean the corpus could be produced: a stale
  # producer binary emitted the old 315-row publication from a new 323-row
  # manifest. `zig build published-tools` compiles every published tool and
  # every tool-owning test step.
  #
  # It runs first, and chained with `&&` rather than on its own line, because
  # it is the cheaper ordering — a broken tool fails in seconds instead of
  # after the whole gate — and because a failing build must not fall through
  # to a gate whose own `zig build` would then pass. The profile is pinned
  # rather than left at the host defaults: every one of those tools guards on
  # the qualified corpus profile and `bench/public_api.zig` will not compile
  # without it. The oracle libraries arrive through LIBRARY_PATH and
  # ZMATH_ORACLE_HOST_PREFIX from .envrc, and the produced binaries carry the
  # RUNPATH for the store-built flint, so this is a link-only build.
  #
  # GATE_EXCLUDE stays as it is: zig-gate builds its ziglint file list with
  # `find`, which bypasses ziglint's own .gitignore handling, so generated
  # artifacts would otherwise be linted as if they were source. Exclude the
  # gitignored result directories here.
  #
  # KEEP IN SYNC WITH THE gate SHIM IN .envrc. On a host with a store this is
  # what runs; on a host without one the shim is what runs, and it used to omit
  # the `zig build published-tools` step, which would have left the blind spot
  # this step closes alive exactly where it was added.
  scripts.gate.exec = ''
    zig build published-tools -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe &&
      GATE_EXCLUDE="./bench/results/ ./.devenv/ ./graphify-out/" zig-gate
  '';


  # `zig-cov` is hardcoded to another machine's home directory and does not
  # exist here, so this script cannot run on this host. It is left as the
  # upstream contract rather than silently repointed.
  scripts.coverage.exec = ''
    PATH=${coverageZig}:$PATH ~/tools/zcov/zig-out/bin/zig-cov test
  '';
}
