# zmath-testing design

## Purpose

`zmath-testing` is a separate Jujutsu repository for integration tests, independent numerical-oracle tests, and benchmarks of the public `zmath` package. It must not contain library implementation code.

## Repository boundary

- The package depends on sibling path `../zmath`.
- The dependency is one-way: `zmath-testing -> zmath`.
- Test and benchmark code imports only zmath's public package module.
- zmath must not import this repository or its oracle adapters.

## Build surfaces

`build.zig` exposes these top-level steps:

- `test`: portable public-API integration tests. No external oracle library is linked.
- `oracle`: deterministic replay and numerical comparison against MPFR and Arb/FLINT. These adapters are isolated from integration tests and benchmarks.
- `oracle-fuzz`: explicitly seeded exploratory differential fuzzing. It does not change manifest status or accepted TSV rows.
- `bench`: one executable per public numerical surface. Benchmarks do not link MPFR or Arb.
- `generate-corpus`: test-only production of immutable MPFR/Arb-checked TSV artifacts.

The workspace uses a devenv environment that provides Zig, GMP, MPFR, and FLINT/Arb.
Oracle dependencies are development-only and never become zmath runtime dependencies.

The accepted scalar profile is exactly target `x86_64-linux-gnu.2.38`, CPU
`haswell`, and optimize mode `ReleaseSafe`.
Acceptance producer, replay, and benchmark commands must name this profile:

```text
zig build generate-corpus -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
zig build oracle -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
zig build bench -Dbench-target=scalar-log-f -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
zig build run-bench -Dbench-target=scalar-log-f -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
```

The benchmark commands measure performance only. They do not change manifest
acceptance or provide numerical proof.

## Current scalar contract

The schema-v2 manifest has 315 sorted typed rows.
Exactly six pairs are accepted: `exp/h`, `exp/f`, `exp/d`, `log/h`, `log/f`,
and `sin/h`.
The remaining 309 rows are `unsupported`.

Schema version 2 keeps `max_ulp` as a non-negative unsigned value.
Correct rows require `max_ulp = 0`.
Bounded rows permit any non-negative value, including zero.
This integration does not change the schema version.

Implementation, manifest acceptance, corpus evidence, and whole-domain proof
are separate facts.
An exported zmath symbol proves implementation only.
A `correct` or `bounded` manifest row proves acceptance only.
An immutable corpus proves its stored inputs only.
Whole-domain proof requires exhaustive inputs or a separate proof for the full
operation-format domain.

The H artifacts enumerate all binary16 inputs for their unary operations.
The F and D artifacts are deterministic selected-case corpora. They do not
prove whole-domain correctness for binary32 or binary64.

## Test structure

```text
test/
  integration/    public API contracts and regression tests
  oracle/         MPFR and Arb/FLINT FFI adapters and comparison tests
  algebra/        named concrete algebra laws
bench/            isolated benchmark executables
```

Test and benchmark code imports only zmath's public package module.
The current scalar acceptance lane uses the six accepted manifest pairs.
Future pairs remain `unsupported` until implementation, corpus evidence, and a
manifest update satisfy the schema-v2 contract.

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

The oracle and fuzz surfaces have different roles:

- `oracle` deterministically replays immutable TSV rows for the six accepted pairs. It exhausts all `65,536` binary16 inputs for each accepted H row and replays selected F and D rows. F and D rows are samples of their domains, not whole-domain proof.
- `oracle-fuzz` is an explicitly seeded exploratory differential campaign. It may sample weighted raw-bit `f32` and `f64` inputs, but it never changes manifest status or accepted TSV rows.

The oracle replay decodes fixed-width inputs and calls the typed public zmath
function. It compares runtime bits, stored bits, MPFR bits, output classes, and
the Arb unique-rounding proof. `ERROR` and `UNCERTAIN` fail the replay.
Unsupported functions do not dispatch to zmath or the bridge.

The fuzz surface uses `std.testing.Smith.value(u16/u32/u64)` and `@bitCast` to
generate IEEE inputs. Reproducibility requires the same source, compiler, fuzz
budget, seed, and callback request order.

Zig fuzzer crash files are preserved verbatim because Smith inputs are
structured streams, not raw scalar bit patterns. Committed replay data embeds
those files through `FuzzInputOptions.corpus`. Each fixture is valid only while
its callback's request order and types remain unchanged. A separate generated
failure sidecar records operation, format, input bits, runtime bits, MPFR bits,
seed, and certification status. It never modifies the accepted oracle TSV corpus.

The manifest status map is parsed once and drives dispatch. No hard-coded
function status table may duplicate it.


## Integration dispositions

The broad C23 campaign and evaluator branch remains preserved at the
`preserve-c23-campaigns` bookmark.
Only strict manifest and schema rejection regressions move into this acceptance
lane.
Descriptor runtime and broad campaign files remain outside that migration.

The obsolete approximate `atan2` split and its invalid audit constants are
superseded by the canonical `Atan2Result(T)` wrappers, direct CORE-MATH kernels,
and migrated regression cases.
The current `lgamma` contract returns `+infinity` at zero and finite negative
integer poles. It returns sign `-1` at those poles and keeps the pure-value
contract without `errno` or hidden sign state.

## Verification

After implementation:

1. `zig build test` proves the sibling zmath module imports through its public package boundary.
2. `zig build oracle -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe` replays the accepted MPFR/Arb corpus.
3. `zig build oracle-fuzz --fuzz=100K --seed 0x1234 -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe` runs a reproducible exploratory campaign.
4. `devenv shell -- coverage` runs `zig-cov` under the pinned 0.17-dev coverage toolchain. Delivery builds and normal oracle tests remain pinned to Zig 0.16.0.
5. `zig build bench -Dbench-target=scalar-log-f -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe` builds the scalar benchmark without oracle libraries.
6. `zig build run-bench -Dbench-target=scalar-log-f -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe` runs the scalar benchmark.
7. The workspace status is clean after the focused Jujutsu commit.
