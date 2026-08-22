# zmath-testing design

## Purpose

`zmath-testing` is a separate Jujutsu repository for integration tests, independent numerical-oracle tests, and benchmarks of the public `zmath` package. It must not contain library implementation code.

## Repository boundary

- The package depends on sibling path `../zmath`.
- The dependency is one-way: `zmath-testing -> zmath`.
- Test and benchmark code imports only zmath's public package module.
- zmath must not import this repository or its oracle adapters.

## Build surfaces

`build.zig` will expose these top-level steps:

- `test`: portable public-API integration tests. No external oracle library is linked.
- `oracle`: numerical comparisons against MPFR and Arb/FLINT. These adapters are isolated from integration tests and benchmarks.
- `bench`: one executable per public numerical surface. Benchmarks do not link MPFR or Arb.

The workspace uses a devenv environment that provides Zig, GMP, MPFR, and FLINT/Arb. Oracle dependencies are development-only and never become zmath runtime dependencies.

## Test structure

```text
test/
  integration/    public API contracts and regression tests
  oracle/         MPFR and Arb/FLINT FFI adapters and comparison tests
  algebra/        named concrete algebra laws
bench/            isolated benchmark executables
```

The current zmath scaffold exports no numerical functions. Initial oracle adapters therefore need only compile and run a smoke check. Function-level comparisons are added with each exported zmath numerical function.

## Algebra policy

zmath has named, concrete foundational algebras. It does not expose a public arbitrary-signature algebra constructor or generic runtime algebra representation.

Initial planned concrete surfaces:

- `Cl3`: Euclidean 3D Clifford algebra; vectors, bivectors, rotors.
- `Pga3`: projective 3D algebra; points, planes, lines, motors.
- `Cga3`: conformal 3D algebra, added only after the prior two have fixed conventions.

Each surface gets handwritten law tests and an independent benchmark executable. Tests must name the exact scalar type and algebra. They must not generate a broad type/signature matrix.

## Oracle policy

- MPFR is the scalar correctly-rounded oracle.
- Arb/FLINT is the interval and special-function oracle.
- Oracle FFI is restricted to `test/oracle`; public zmath API and benchmark code must not expose MPFR, GMP, FLINT, or Arb types.
- Benchmark output reports time and checked-operation count separately from oracle tests.

## Differential fuzzing policy

The oracle target has two complementary differential-test surfaces:

- `oracle`: a deterministic, seeded campaign. It replays committed regression inputs,
  exhausts every `f16` input when a function is enabled, and samples weighted raw-bit
  `f32` and `f64` inputs. This is the normal CI-quality check.
- `fuzz`: Zig's coverage-guided `std.testing.fuzz` runner. It is an explicit,
  long-running local target, invoked with a fixed `--fuzz` budget and `--seed` for
  reproducibility.

Both surfaces use `std.testing.Smith.value(u16/u32/u64)` and `@bitCast` to generate
IEEE inputs. They call the typed public zmath function, then the MPFR bridge. Output
bits and class must match exactly. For finite output, Arb must certify that the MPFR
rounded result is unique. `ERROR` and `UNCERTAIN` fail the test; only manifest-disabled
functions may return `UNSUPPORTED`, and they must not dispatch to zmath or the bridge.

Zig fuzzer crash files are preserved verbatim because Smith inputs are structured
streams, not raw scalar bit patterns. Committed replay data embeds those files through
`FuzzInputOptions.corpus`. A separate, generated failure sidecar records operation,
format, input bits, runtime bits, MPFR bits, seed, and certification status. It never
modifies the accepted oracle TSV corpus.

The manifest status map is parsed once and drives dispatch. No hard-coded function
status table may duplicate it.

## Verification

After implementation:
1. `zig build test` proves the sibling zmath module imports through its public package boundary.
2. `zig build oracle` proves the deterministic MPFR/Arb differential campaign.
3. `zig build fuzz --fuzz=100K --seed 0x1234` runs a reproducible bounded
   coverage-guided differential campaign on supported hosts.
4. `zig build bench` builds benchmark executables without linking oracle libraries.
5. The workspace status is clean after the focused Jujutsu commit.
