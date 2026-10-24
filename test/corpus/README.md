# Typed oracle corpus

`manifest.toml` defines schema 5 for the independent zmath oracle harness.
The runtime library does not depend on this directory or the oracle libraries.

## Manifest and numerical scope

The manifest pins CORE-MATH revision
`3bafed75e3c22399531857d63a3fa0e24bfb42fa`, MPFR precision at 512 bits, and
Arb precision at 512 bits. Evaluation fails on uncertainty; precision does not
increase automatically. Fixed 1,024-bit containers hold exact rounding boundaries.

Root keys occur in this order:

```text
schema_version, core_math_repository, core_math_revision,
mpfr_precision_bits, arb_precision_bits, rounding, formats,
reserved_formats, rejected_formats, operation_spelling, columns,
hexadecimal, uncertainty_policy, special_policy
```

Each `[[function]]` row contains, in order:

```text
op, provenance, status, arity, inputs, result, oracle, special_policy, max_ulp
```

Formats `h`, `f`, and `d` mean binary16, binary32, and binary64. Standard C23
operation names are unsuffixed; descriptors select the format. Narrowing names
retain their encoded formats. Unknown tokens and unsupported formats are rejected.

Inputs are `float:<format>`, `integer:<type>`, `tag`, `fromfp_round`, or
`round_mode`. Results are `float:<format>`, `integer:<type>`, `bool`,
`classification`, or `struct:<kind>:<format>`. `fromfp_round` has five modes;
`round_mode` has four and is input-only. `classification` is result-only and
encodes zero, subnormal, normal, infinity, quiet NaN, or signaling NaN.

Provenance is `["zmath"]`, `["core_math"]`, or `["zmath", "core_math"]`.
Rows sort by provenance, case-sensitive operation, then format in H/F/D order.
`operation_spelling` is `c23_hfd_lowercase_v1`.

Statuses are `unsupported`, `correct`, and `bounded`. Unsupported rows require
`oracle = "none"` and `max_ulp = 0`; correct rows require an evaluator and zero
ULP tolerance; bounded rows require an evaluator and a non-negative tolerance.
The authoritative C table assigns each descriptor one evaluator:

- `exact_bits`: direct IEEE bit and integer models.
- `algebraic`: GMP rational arithmetic and certified MPFR/Arb root enclosures.
- `mpfr_arb`: MPFR candidates with Arb proofs.
- `definitional`: IEEE or algebraic convention checks, reported separately from
  independent numerical accuracy.

Manifest acceptance applies to stored tuples. Only `exhaustive_h_unary`
enumerates a complete unary binary16 domain. Integer-domain, special-tuple,
Cartesian, selected F/D, and exact-bit/status campaigns cover their declared
inputs. Non-scalar selected cases do not establish complete-domain accuracy.

## Publication format

Records use length-framed `ZCDR` version 1. Metadata starts with `ZCDM version=1`.
Records carry operation, provenance, typed arguments, result descriptors, typed
result fields, and tolerance. Floating fields preserve bits and IEEE class.

The producer compares runtime results with the selected evaluator before writing.
It publishes `metadata.txt` and `COMPLETE` only after all selected records succeed.
An interrupted publication retains `.incomplete`. The loader requires `COMPLETE`
and checks its metadata SHA-256, descriptor identity, scope, target profile,
record order, counts, and artifact hashes. Generation-time status snapshots may
differ from later manifest acceptance without changing numerical identity.

Keep metadata and `COMPLETE` tracked. Raw records, probes, partial publications,
shards, and measurement logs are ignored. The half-table generator also consumes
pinned metadata and raw `asin`/`tanh` binary16 artifacts.

## Generate and replay

The qualified profile is `x86_64-linux-gnu.2.38`, CPU `haswell`, optimization
`safe`. Stored metadata uses the canonical mode name `ReleaseSafe`.
Use the same profile for every command below:

```sh
zig build oracle-generator corpus-replay bench-scalar bench-vector \
  -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=safe
```

Installed executables are `zmath-testing-corpus-producer`, `zmath-corpus-replay`,
`zmath-scalar-matrix`, and `zmath-vector-matrix` under `zig-out/bin/`.
Each takes an optional first positional corpus root, defaulting to `test/corpus`.

```sh
zig-out/bin/zmath-testing-corpus-producer test/corpus
zig-out/bin/zmath-corpus-replay test/corpus
zig-out/bin/zmath-corpus-replay test/corpus --vector
```

`--operation=OP` and `--format=h|f|d` select a probe under
`generated/probes/<op>-<fmt>/`; an omitted filter contributes `all` to the name.
Generate the probe with the same filters before replay or measurement.
The scalar and vector matrices accept `--repetitions=1..100`.
Build wrappers pass `test/corpus`; append filters after `--`.
`replay-vector` already supplies `--vector`, which must not be repeated.

Replay uses stored outputs and current public zmath APIs without invoking a
numerical oracle. Four-lane replay uses registered vector operations where
available and scalar public operations per lane otherwise. The final group
compares only real records. Vector benchmarks measure only registered targets;
other descriptors report `available=false`. Timings grant no numerical acceptance.

For verified-artifact reuse, pass `--reuse-existing=SOURCE/generated` with a fresh
output root. The source must contain metadata, `COMPLETE`, and records. Reuse
validates profile, descriptor identity, paths, ordering, counts, and hashes;
source and destination must have the same full or filtered scope.

## Shards and binary32 ranges

Build one producer binary for all shards and assembly. `--shard=i/n` uses a
zero-based index; `--assemble=n` merges that selection. Do not combine the flags.
The shard count cannot exceed the selected descriptor count.

```sh
zig-out/bin/zmath-testing-corpus-producer "$out" --shard=0/2
zig-out/bin/zmath-testing-corpus-producer "$out" --shard=1/2
zig-out/bin/zmath-testing-corpus-producer "$out" --assemble=2
zig-out/bin/zmath-corpus-replay "$out"
```

Shards live under `shards/<op>-<fmt>/<i>-of-<n>/` and complete with `SHARD`, not
`COMPLETE`. Assembly requires every shard, rejects stale plans and completed
destinations, and copies and hashes all records. Source shards remain intact.
The plan binds profile, filters, descriptors, partition, and shard count.
For byte comparisons across output roots, normalize only the metadata artifact
path field, or run both publications with the same output root.

`--f32-range=LOW:HIGH` explicitly selects a half-open raw binary32 input interval,
with `0 <= LOW < HIGH <= 4294967296`. Eligible descriptors have one `float:f`
input. `--format` still selects the result format. Range shards split the input
interval and use `range-shards/`; results use `ranges/` with `RANGE` or
`RANGE_COMPLETE`, never ordinary `COMPLETE`. Only complete tiling of the full
32-bit interval can establish exhaustive binary32 coverage. Full-domain scans
need substantial storage, including both source shards and copied assembly.

## Fixtures and comparative benchmarks

The six tracked `exp_h`, `exp_f`, `exp_d`, `log_h`, `log_f`, and `sin_h` TSVs
remain regression inputs for integration tests and public-API benchmarks.
The H fixtures enumerate all 65,536 encodings; F/D fixtures cover selected inputs.

The comparative C++ executable uses Google Benchmark and the independent pinned
CORE-MATH DSO. `devenv.nix` supplies its `ZMATH_COMPARE_*` build variables and
`ZMATH_CORE_MATH_SOURCE_DIR`/`ZMATH_GLIBC_SOURCE_DIR` reference paths.

```sh
zig build compare -Dcompare-optimize=safe
python3 bench/run_comparative.py --binary=zig-out/bin/zmath-compare \
  --out_dir=bench/results/comparative-run
```

The output directory must be new. It receives timing, accuracy, source/build
metadata, a report, and process output. `--quick` reduces measurement duration;
`--audit_only` runs numerical audits without timing; `--filter=REGEX` selects
rows. Missing provider symbols remain unsupported, without substituted baselines.
The runner validates provider origins, source revisions, input digests, and
repetition sets before computing paired ratios. It measures scalar throughput,
not SIMD performance or single-call latency. MPFR audit results are selected-case
evidence, not correctly-rounded proofs.
