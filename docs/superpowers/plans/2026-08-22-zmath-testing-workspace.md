# zmath-testing Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone Zig 0.16 companion repository with public-API integration tests, MPFR/Arb oracle smoke tests, and benchmark executables for the sibling `../zmath` package.

**Architecture:** `zmath-testing` depends on `../zmath` through a local Zig package dependency. Portable integration tests and benchmarks link only Zig and zmath. Oracle tests compile a small C bridge against MPFR, GMP, and FLINT/Arb supplied by devenv; no oracle types cross into zmath's public API.

**Tech Stack:** Zig 0.16.0, Jujutsu, devenv/Nix, MPFR, GMP, FLINT/Arb, `std.testing`.

## Global Constraints

- Keep the runtime zmath package dependency-free.
- Keep the dependency direction one-way: `zmath-testing -> ../zmath`.
- Keep foundational algebras concrete and named; do not add an arbitrary-signature generic algebra API.
- Keep MPFR, GMP, and FLINT/Arb development-only dependencies.
- Use `zig fmt` before verification and commit only green work with Jujutsu.

---

### Task 1: Configure the devenv oracle toolchain

**Files:**
- Modify: `devenv.nix`
- Modify: `.envrc`

**Interfaces:**
- Produces shell packages `gmp`, `mpfr`, `flint`, `pkg-config`, `hyperfine`, `valgrind`, and `perf-tools`.
- Produces `C_INCLUDE_PATH`, `LIBRARY_PATH`, and `LD_LIBRARY_PATH` values that let Zig's C compiler find headers and libraries.

- [ ] **Step 1: Add Nix packages and standard C search paths**

Use the existing `packages` list and extend its environment:

```nix
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
```

Add FLINT's nested header directory to `C_INCLUDE_PATH` if `#include <arb.h>` is not found through the package root:

```nix
C_INCLUDE_PATH = pkgs.lib.concatStringsSep ":" [
  (pkgs.lib.makeIncludePath packages)
  "${pkgs.flint}/include/flint"
];
```

- [ ] **Step 2: Keep direnv loading the project environment**

`.envrc` must continue to contain the existing `use devenv` directive and no project-specific absolute paths.

- [ ] **Step 3: Enter devenv and inspect package paths**

Run:

```bash
direnv reload
zig version
printf '%s\n' "$C_INCLUDE_PATH"
printf '%s\n' "$LD_LIBRARY_PATH"
```

Expected: Zig reports `0.16.0`; the paths contain MPFR, GMP, and FLINT store paths.

- [ ] **Step 4: Commit the environment change**

```bash
jj commit -m "build: add numerical oracle toolchain"
```

### Task 2: Wire the sibling zmath package and portable test target

**Files:**
- Modify: `build.zig.zon`
- Replace: `build.zig`
- Create: `test/integration/public_api.zig`
- Create: `.gitignore`

**Interfaces:**
- `build.zig.zon` exposes dependency name `zmath` at path `../zmath`.
- `zig build test` runs `test/integration/public_api.zig` with `@import("zmath")` resolved to the sibling package.
- `zig build bench` is reserved for benchmark executables and does not link oracle libraries.

- [ ] **Step 1: Add the local zmath dependency**

In `build.zig.zon`, add:

```zig
.dependencies = .{
    .zmath = .{ .path = "../zmath" },
},
```

Include only build metadata, `test`, `bench`, and the committed specification/plan paths in `.paths`.

- [ ] **Step 2: Write the public-boundary integration test**

Create `test/integration/public_api.zig`:

```zig
const std = @import("std");
const zmath = @import("zmath");

test "imports the public zmath module" {
    try std.testing.expectEqual(@as(i32, 10), zmath.add(3, 7));
}
```

- [ ] **Step 3: Replace the generated sample build graph**

`build.zig` must:

1. create `target` and `optimize` options;
2. load `b.dependency("zmath", .{ .target = target, .optimize = optimize })`;
3. create a test root module from `test/integration/public_api.zig` with an import named `zmath` bound to the dependency module;
4. create a `test` step that runs the test artifact;
5. create a `bench` step without adding oracle libraries;
6. avoid installing or building a sample library/executable.

- [ ] **Step 4: Ignore generated output**

Create `.gitignore`:

```text
.zig-cache/
zig-out/
.devenv/
.direnv/
```

- [ ] **Step 5: Run the portable test**

Run:

```bash
zig build test
```

Expected: one integration test passes and the zmath sibling module is resolved through the package dependency.

- [ ] **Step 6: Commit the package/test wiring**

```bash
jj commit -m "test: wire zmath integration workspace"
```

### Task 3: Add isolated MPFR and Arb smoke targets

**Files:**
- Create: `test/oracle/oracle_smoke.zig`
- Create: `test/oracle/oracle_smoke.c`
- Modify: `build.zig`

**Interfaces:**
- C exports `zmath_testing_mpfr_smoke() c_int` and `zmath_testing_arb_smoke() c_int`.
- Zig oracle tests call those functions through `extern` declarations.
- `zig build oracle` is the only target that links `mpfr`, `gmp`, and `flint`.

- [ ] **Step 1: Write the C oracle bridge**

`test/oracle/oracle_smoke.c` must initialize and clear one MPFR value and one Arb value, set each to a known constant, and return nonzero on failure. Use the installed headers:

```c
#include <arb.h>
#include <mpfr.h>

int zmath_testing_mpfr_smoke(void) {
    mpfr_t value;
    mpfr_init2(value, 128);
    mpfr_const_pi(value, MPFR_RNDN);
    int ok = mpfr_cmp_ui(value, 3) > 0;
    mpfr_clear(value);
    return ok;
}

int zmath_testing_arb_smoke(void) {
    arb_t value;
    arb_init(value);
    arb_const_pi(value, 128);
    int ok = !arb_is_zero(value);
    arb_clear(value);
    return ok;
}
```

- [ ] **Step 2: Write the Zig oracle test**

`test/oracle/oracle_smoke.zig` must declare the two C functions and assert that both return `1`.

- [ ] **Step 3: Add the oracle build step**

Create a test root module from `test/oracle/oracle_smoke.zig`; add the C source file; link `mpfr`, `gmp`, and `flint`; run the artifact from an `oracle` step. Keep this artifact out of `test` and `bench`.

- [ ] **Step 4: Run the full oracle test module**

Run:

```bash
zig build oracle
```

Expected: both MPFR and Arb smoke tests pass.

- [ ] **Step 5: Commit the oracle target**

```bash
jj commit -m "test: add MPFR and Arb oracle smoke target"
```

### Task 4: Add a concrete benchmark executable

**Files:**
- Create: `bench/public_api.zig`
- Modify: `build.zig`

**Interfaces:**
- `bench/public_api.zig` is an executable with no MPFR, GMP, or FLINT imports.
- `zig build bench` builds the benchmark artifact.

- [ ] **Step 1: Write the benchmark executable**

Use a fixed loop over `zmath.add`, retain the final accumulator with `std.mem.doNotOptimizeAway`, and print the deterministic operation count. Do not add a generic benchmark framework or a timing API whose contract is not yet needed.

- [ ] **Step 2: Add the benchmark artifact and step**

Build `bench/public_api.zig` with the zmath module import and make `bench` depend on its compile step. Do not link the oracle libraries.

- [ ] **Step 3: Build and run the benchmark**

Run:

```bash
zig build bench
zig build run-bench
```

Expected: the executable builds without oracle libraries and reports the fixed operation count.

- [ ] **Step 4: Commit the benchmark target**

```bash
jj commit -m "bench: add public API benchmark target"
```

### Task 5: Run final gates and inspect the complete workspace

**Files:**
- No source changes expected.

- [ ] **Step 1: Format all Zig sources**

Run:

```bash
zig fmt --check build.zig test bench
```

Expected: no formatting changes are reported.

- [ ] **Step 2: Run every workspace surface**

Run:

```bash
zig build test
zig build oracle
zig build bench
```

Expected: all three commands succeed.

- [ ] **Step 3: Check dependency isolation**

Inspect `build.zig` and confirm only the oracle artifact links MPFR/GMP/FLINT. The integration test and benchmark root modules must import only `zmath` and the Zig standard library.

- [ ] **Step 4: Inspect Jujutsu status**

Run:

```bash
jj st
```

Expected: clean working copy with focused commits and only ignored build/devenv output outside the repository snapshot.
