# Scalar oracle corpus

This directory defines the typed scalar oracle contract for `zmath`.
The runtime library does not depend on this directory or on oracle libraries.
The normative contract is in `../../../zmath/spec/core-math-2026-08-22.md`.

## Manifest

`manifest.toml` uses schema version 3.
It pins CORE-MATH revision
`3bafed75e3c22399531857d63a3fa0e24bfb42fa`, MPFR precision at 512 bits, and
Arb precision at 512 bits. Numerical evaluation does not adapt beyond those
precisions. The uncertainty policy is fail closed.

The root keys occur in this order:

```text
schema_version, core_math_repository, core_math_revision,
mpfr_precision_bits, arb_precision_bits, rounding, formats,
reserved_formats, rejected_formats, operation_spelling, columns,
hexadecimal, uncertainty_policy, special_policy
```

Each `[[function]]` row has these keys in this order:

```text
op, provenance, status, arity, inputs, result, oracle, special_policy, max_ulp
```

The format identifiers are `h` for binary16, `f` for binary32, and `d` for
binary64. The manifest rejects `q`, `f128`, `bfloat16`, aliases, and unknown
format identifiers. Standard H/F/D rows use an unsuffixed C23 operation base.
Their typed descriptors select the format. Encoded narrowing names remain exact.

## Ownership and provenance

The manifest has 315 sorted typed rows. Provenance records ownership, not
acceptance. Use only these ordered arrays:

- `["zmath"]` for zmath-owned operations.
- `["core_math"]` for CORE-MATH-owned operations.
- `["zmath", "core_math"]` for operations owned by both projects.

The row order is deterministic. Sort first by the provenance array, then by the
case-sensitive operation spelling, then by the typed format in `h`, `f`, `d`
order. The operation spelling declaration is exactly
`c23_hfd_lowercase_v1`.

The authoritative C operation table maps every manifest operation-format key
exactly once. It assigns 150 descriptors to `exact_bits`, 126 to `mpfr_arb`,
and 39 to `algebraic`.

## Status and evidence

The status values are `unsupported`, `correct`, and `bounded`.
An unsupported row requires `oracle = "none"` and `max_ulp = 0`.
A correct row requires a non-`none` oracle and `max_ulp = 0`.
A bounded row requires a non-`none` oracle and a non-negative `max_ulp`.
The accepted oracle values are `none`, `exact_bits`, `algebraic`, and
`mpfr_arb`.

Implementation, manifest acceptance, corpus evidence, and whole-domain proof
are separate facts. Source exports establish implementation only. A `correct`
or `bounded` row establishes manifest acceptance only. Corpus evidence covers
stored tuples. Whole-domain proof requires exhaustive inputs or a separate
proof for the complete operation-format domain.

The checked-in manifest accepts all 315 descriptors as `correct` with
`max_ulp = 0`. Full publication and replay verified 63,160,084 records.
The benchmark exercised every descriptor.

## Typed publication

New publication records use the length-framed binary `ZCDR` codec version 1.
The metadata file begins with `ZCDM version=1`.
Each record stores the operation, ordered provenance, arity, typed arguments,
result descriptor, typed result fields, and `max_ulp`.
Floating fields store exact format, bits, and IEEE class. Integer, Boolean,
tag, rounding, and status-container fields use explicit typed encodings.

The generator compares the zmath result with the evaluator selected by the
authoritative C table before writing a record. `exact_bits` uses direct IEEE
bit and integer models. `algebraic` uses exact GMP rational arithmetic for
finite dyadic operations and certified 512-bit MPFR/Arb enclosures for
irrational algebraic roots. `mpfr_arb` uses a fixed 512-bit MPFR candidate and a
Arb proof.

Exact dyadic relations are used for target rounding boundaries. Fixed
1,024-bit MPFR boundary containers may hold exact binary boundary values; this
does not change the 512-bit numerical evaluation precision.
The atan2 midpoint correction, log-domain overflow proof, and negative
noninteger lgamma reflection proof are fail-closed evaluator protocols.

Metadata records the manifest descriptor digest, target profile, campaign
class, seed, cardinality, selection rule, record count, source metadata, and
artifact SHA-256. The loader rejects `.incomplete`, requires `COMPLETE`, and
verifies the metadata digest, descriptor digest, scope, profile, record order,
count, and artifact digest. When source metadata is unavailable, use the exact
`source-metadata-unavailable` digest sentinel and `none` source fields.

Campaign classes are explicit:

- `exhaustive_h_unary` enumerates all 65,536 binary16 input bit patterns for
  one unary H operation.
- `bounded_h_integer_domain` covers a declared integer parameter domain.
- `explicit_special_tuple_grid` covers declared special-value tuples.
- `selected_cartesian` covers a declared selected Cartesian product.
- `selected_unary_f` and `selected_unary_d` cover declared selected F and D
  inputs.
- `exact_bit_status` covers exact-bit and status-return cases.

Only `exhaustive_h_unary` claims exhaustive coverage of its one-argument
binary16 domain. Every other campaign claims only its declared tuples.
The publication includes 61 exhaustive binary16 unary campaigns.
The remaining campaigns do not prove whole IEEE operation-format domains.

Generated raw records are multi-gigabyte artifacts.
Keep `generated/records/` and `generated/probes/` local and ignored.
Also ignore incomplete-publication markers and temporary files.
Commit publication metadata, `COMPLETE`, `replay.txt`, and `benchmark.txt`.
Regenerate raw records with `generate-corpus` in a new checkout.

The metadata SHA-256 is
`f7e624e2be25c43935da9afa179cb20149fce4a0326dbfa310056c5761a017ab`.
Its status-oracle snapshots record the candidate state before acceptance.
Status promotion does not change numerical descriptor identity or record hashes.
The loader checks both historical snapshots and the current manifest.

`generated/verification.json` records test, formatting, replay, benchmark,
and lint outcomes. Numerical verification passed. The runtime house gate and
harness style lint still report diagnostics; they are not recorded as passing.

## Deterministic replay and benchmark

The qualified profile is:

```text
target = x86_64-linux-gnu.2.38
cpu = haswell
optimize = ReleaseSafe
```

Build the typed tools with:

```text
zig build oracle-generator -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
zig build corpus-replay -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
zig build bench-scalar -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
```

The resulting executables are:

```text
zig-out/bin/zmath-testing-corpus-producer
zig-out/bin/zmath-corpus-replay
zig-out/bin/zmath-scalar-matrix
```

Each executable accepts an optional first positional corpus root. The default
root is `test/corpus`. Each accepts `--operation=<manifest-op>` and
`--format=h|f|d`; the filters can be used independently or together:

```text
zig-out/bin/zmath-testing-corpus-producer test/corpus --operation=atan2 --format=d
zig-out/bin/zmath-corpus-replay test/corpus --operation=atan2 --format=d
zig-out/bin/zmath-scalar-matrix test/corpus --operation=atan2 --format=d
```

The build wrappers expose these commands:

```text
zig build generate-corpus -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
zig build replay-corpus -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
zig build run-bench-scalar -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
```

Append filters after `--` when using a build wrapper. The wrapper passes
`test/corpus` as its default positional root:

```text
zig build generate-corpus -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe -- --operation=atan2 --format=d
zig build replay-corpus -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe -- --operation=atan2 --format=d
zig build run-bench-scalar -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe -- --operation=atan2 --format=d
```

The generator request and evaluator table use oracle ABI v2.
Each request carries operation bytes, arity, typed input fields, result layout,
structure kind, and typed result fields. The C table has one authoritative
signature and evaluator category for each manifest descriptor.

Replay reads stored typed outputs and compares them with current zmath results.
It does not link or invoke MPFR, Arb, GMP, or FLINT. The scalar benchmark
validates publication metadata and artifact digests before measurement. It
reports measurements only and does not grant manifest acceptance or
whole-domain proof.

## Historical TSV fixtures

Six historical TSV fixtures remain tracked for compatibility and regression
context. They are not the schema-3 typed publication format and do not claim
full coverage:

- `exp_h.tsv`: 65,536 data rows covering every unsigned binary16 encoding in
  numeric order.
- `exp_f.tsv`: 29 data rows.
- `exp_d.tsv`: 182 data rows.
- `log_h.tsv`: 65,536 data rows covering every unsigned binary16 encoding in
  numeric order.
- `log_f.tsv`: 64 data rows from the exact binary32 vectors in
  `scalar_log_test.zig`: special values, subnormal/normal boundaries,
  adjacent-to-one values, and nine CORE-MATH fallback/low-correction vectors
  with each vector's immediate predecessor and successor. Inputs are sorted
  and deduplicated.
- `sin_h.tsv`: 65,536 data rows covering every unsigned binary16 encoding in
  numeric order.

The H fixtures are exhaustive over their unary binary16 domains. The F and D
fixtures are deterministic selected-case corpora and provide evidence only for
stored inputs. Their historical text header is:

```text
op	format	input_bits	output_bits	output_class	max_ulp
```

The legacy TSV reader remains for these compatibility fixtures only.
The typed producer and replay validate campaign scope, typed records, and the
manifest status/evaluator relation.

## Historical benchmark fixture

The following table records the old six-target native runs. It is historical
benchmark evidence for the TSV fixtures, not a performance bound or a
schema-3 full-publication result:

| Target | Corpus rows | Timed operations | Observed elapsed ns | Result checksum |
| --- | ---: | ---: | ---: | ---: |
| `scalar-exp-h` | 65,536 | 1,048,576 | 14,974,205 | 17,401,774,768 |
| `scalar-exp-f` | 29 | 475,136 | 6,522,980 | 753,964,464,013,312 |
| `scalar-exp-d` | 182 | 2,981,888 | 114,997,455 | 15,514,520,106,984,325,120 |
| `scalar-log-h` | 65,536 | 1,048,576 | 9,811,652 | 34,843,479,648 |
| `scalar-log-f` | 64 | 1,048,576 | 28,824,041 | 2,036,652,067,569,664 |
| `scalar-sin-h` | 65,536 | 1,048,576 | 9,792,795 | 29,520,195,616 |

These are single native runs on a shared host, not performance bounds.
The typed scalar benchmark validates its selected publication metadata and
SHA-256 before the timed loop.

## Corpus producer and fail-closed behavior

The test-only producer runs on the host.
Build options record the requested target, CPU features, and mode.
The producer rejects unapproved profiles before it reads arguments or changes files.
Host execution does not qualify an additional runtime profile.

The producer writes temporary record files.
It publishes metadata and `COMPLETE` only after all selected records pass evaluator checks.
A failed run can leave partial records with an `.incomplete` marker.
Evaluator disagreement, an ambiguous enclosure, or an unresolved midpoint correction prevents completion.
Unknown special-value policies, descriptor mismatches, and missing source sentinels also prevent completion.
The producer does not increase precision silently or emit a best-effort record.

Replay rejects metadata, profile, descriptor, scope, record-order, count, or
artifact-digest mismatches. It does not skip a bad row, substitute a host
result, invoke an external oracle, or accept a nearby value.

## Exploratory fuzzing

Exploratory fuzzing is a separate surface. A caller must provide a fixed seed
to the seeded fuzz helper, and a fuzz campaign must preserve its seed,
compiler, source, budget, and callback request order. Fuzz inputs never become
accepted typed records automatically.

The Exp-only Smith campaign uses Zig 0.16.0:

```text
zig build oracle-fuzz --fuzz=100 --seed 0x7a6d6174 -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
```

It instruments the same Zig Exp source used by the library. The oracle C
bridge is linked separately without coverage instrumentation. Zig 0.16's
built-in fuzzer cannot combine its PC-table layout with Clang's C layout.
This target therefore omits C kernel link objects. A future C-backed campaign
needs compatible coverage support; it must not silently claim C coverage.

## Exact-power resource measurements

Power-family resource measurements do not establish numerical acceptance or a
whole-domain stack or latency bound.

```text
zig build run-power -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
zig build run-power -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseFast
```

`bench-power` installs `zig-out/bin/zmath-power-resource` without running it.
The program covers 36 scenarios: `pown`, `compoundn`, and `rootn`; H/F/D;
input encodings `1` and `2`; degree `-64` and `64`. Each scenario runs four
calls with input barriers. Both modes returned identical bits, `ok` status,
and final checksum `0xfd70910108ab9694`.

Observed native four-call batch ranges, in milliseconds:

| Family | ReleaseSafe | ReleaseFast |
| --- | ---: | ---: |
| `pown` | 0.583–8.065 | 0.559–5.087 |
| `compoundn` | 105.547–14,678.156 | 92.780–3,232.987 |
| `rootn` | 6.056–82.031 | 4.903–25.075 |

Batch times include dispatch and checksum overhead. The host was shared and
the runs were not isolated. These samples do not establish a speedup ratio
between modes. Minimum-subnormal `compoundn` is expensive.

Valgrind 3.27.1 Massif, with `--stacks=yes --time-unit=B`, observed
whole-program peak stack sizes of 362,832 bytes in ReleaseSafe and 362,976
bytes in ReleaseFast. It reported zero heap bytes in both runs. These peaks
cover only the 36 scenarios and include measurement-program stack use.
Do not use instrumented elapsed times as native latency measurements.

`readelf -d` found no dynamic section in all six historical scalar benchmark
binaries or either power measurement binary. `nm -u` listed only `_DYNAMIC`;
none referenced MPFR, GMP, FLINT, Arb, or libc math symbols.
