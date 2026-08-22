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

## Verification

After implementation:

1. `zig build test` proves the sibling zmath module imports through its public package boundary.
2. `zig build oracle` proves MPFR and Arb/FLINT adapters compile and execute their smoke checks.
3. `zig build bench` builds benchmark executables without linking oracle libraries.
4. The workspace status is clean after the focused Jujutsu commit.
