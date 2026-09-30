# Scalar oracle corpus

This directory defines the typed scalar oracle contract for `zmath`.
The runtime library does not depend on this directory or on oracle libraries.
The normative contract is in `../../../zmath/spec/core-math-2026-08-22.md`.

## Manifest

`manifest.toml` uses schema version 4.
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

The `inputs` and `result` columns use typed tokens. An `inputs` entry is
`float:h`, `float:f`, `float:d`, `integer:<type>`, `tag`, `fromfp_round`, or
`round_mode`. A `result` entry is `float:<format>`, `integer:<type>`, `bool`,
`classification`, or `struct:<kind>:<format>`. The vocabulary is closed: an
unknown token is rejected rather than ignored. `round_mode` is accepted only
as an input and `classification` only as a result.

## Ownership and provenance

The manifest has 323 sorted typed rows. Provenance records ownership, not
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
39 to `algebraic`, and 8 to `definitional`.

`definitional` is a fourth evaluator category, not a near-miss oracle. It
names the eight descriptors whose correct result is fixed by the IEEE 754
definition rather than computed by MPFR or Arb: `classify` in H, F, and D,
`ulpDistance` in H, F, and D, `scaleB` in H, and `roundIntegral` in H. Their
stored values are compared against the definition, so `definitional` is never
reported as numerical oracle evidence. No descriptor is assigned to two
categories, and the four counts sum to the 323 manifest rows.

## Status and evidence

The status values are `unsupported`, `correct`, and `bounded`.
An unsupported row requires `oracle = "none"` and `max_ulp = 0`.
A correct row requires a non-`none` oracle and `max_ulp = 0`.
A bounded row requires a non-`none` oracle and a non-negative `max_ulp`.
The accepted oracle values are `none`, `exact_bits`, `algebraic`,
`mpfr_arb`, and `definitional`.

Implementation, manifest acceptance, corpus evidence, and whole-domain proof
are separate facts. Source exports establish implementation only. A `correct`
or `bounded` row establishes manifest acceptance only. Corpus evidence covers
stored tuples. Whole-domain proof requires exhaustive inputs or a separate
proof for the complete operation-format domain.

The checked-in manifest accepts all 323 descriptors as `correct` with
`max_ulp = 0`. The checked-in publication is the 2026-09-09 full run: it
covers 315 of those descriptors, and full publication and replay verified
63,160,084 records over them. The benchmark exercised those same 315. The
eight `definitional` descriptors have no published records yet; they need a
regeneration run before any record count, replay total, or benchmark row is
claimed for them. A descriptor without a published record has manifest
acceptance only, never corpus evidence.

## Typed publication

New publication records use the length-framed binary `ZCDR` codec version 1.
The metadata file begins with `ZCDM version=1`.
Each record stores the operation, ordered provenance, arity, typed arguments,
result descriptor, typed result fields, and `max_ulp`.
Floating fields store exact format, bits, and IEEE class. Integer, Boolean,
tag, rounding, and status-container fields use explicit typed encodings.

Two field kinds exist for rounding, and they are not interchangeable.
`rounding` carries `FromFpRound`, whose five modes are coded 0-4. `round_mode`
carries `RoundMode`, whose four modes are coded 0-3. A stored field only
satisfies a descriptor of its own kind, so a `rounding` value can never be
read as a `round_mode` and vice versa. `round_mode` is an input kind only.
`classification` is a result kind only: it carries the six IEEE 754 classes
`zero`, `subnormal`, `normal`, `infinity`, `quiet_nan`, and `signaling_nan`,
in a three-bit payload. It never appears as an argument.

The generator compares the zmath result with the evaluator selected by the
authoritative C table before writing a record. `exact_bits` uses direct IEEE
bit and integer models. `algebraic` uses exact GMP rational arithmetic for
finite dyadic operations and certified 512-bit MPFR/Arb enclosures for
irrational algebraic roots. `mpfr_arb` uses a fixed 512-bit MPFR candidate and a
Arb proof.

`definitional` derives the expected value from the IEEE 754 definition
instead of from a numerical evaluator, and a disagreement there fails the
record the same way an evaluator disagreement does.

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
The campaign table defines 62 exhaustive binary16 unary campaigns.
The remaining campaigns do not prove whole IEEE operation-format domains.

Of the eight `definitional` descriptors, exactly one carries an exhaustive
claim. `classify` in binary16 is `exhaustive_h_unary`: the class of a value is
a function of its encoding alone, and the campaign enumerates all 65,536
binary16 encodings, so the claim is exhaustive over its single operand.
`classify` in binary32 and binary64 use the selected edge pools, which already
reach a zero, a subnormal, a normal, an infinity, a quiet NaN, and a signalling
NaN in each format; that is all six classes, but it is a selection, not the
whole format. `ulpDistance` in H, F, and D spans the full Cartesian product of
two selected edge pools and claims `selected_cartesian`; 65,536 squared tuples
is not a campaign anyone runs, so the claim is never exhaustive. `scaleB` in
binary16 is `bounded_h_integer_domain`, because the i32 exponent is the axis
that has to be walked: the campaign spans a declared inclusive integer domain
against an exhaustively enumerated binary16 value, with the round mode held
at its base value. Its claim is bounded, not exhaustive, because the round
mode axis is not covered. `roundIntegral` in binary16 is `selected_cartesian`:
it is neither unary nor integer-parameterised, and the round-mode pool holds
all four directions, so every IEEE 754 rounding direction is exercised against
the selected binary16 edges.

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
and lint outcomes from the 2026-09-09 publication run. Its counters are that
dated snapshot and are NOT current: it records 525 runtime unit tests and a
failing runtime house gate with 1582 ziglint issues, whereas the tree now
passes 596 runtime unit tests and the house gate passes cleanly. Treat the
file as a historical publication record. It has no checked-in producer, so it
is deliberately left byte-identical rather than hand-edited; regenerate it only
with the external publication tool. The harness style lint still reports
diagnostics and is not recorded as passing.

The schema-4 change makes more of it stale, and none of it is repaired by
hand. `accepted_descriptors` still says 315 against a 323-row manifest.
`evaluator_descriptors` has no `definitional` key at all, so the file does not
account for all 323 rows. `exhaustive_binary16_unary_campaigns` and the
`coverage_limit` sentence both name the 315-row campaign count.
`records` and `record_bytes` measure the 315-descriptor publication, which
contains none of the eight `definitional` descriptors. `harness_tests`
predates the schema-4 harness changes and says nothing about them until a
rerun. Only `metadata_sha256` is still correct: the checked-in `metadata.txt`
is byte-identical to the one that run produced, so its digest still matches.
A regenerated file replaces all of it at once.

The `replay-vector` and `run-bench-vector` lanes are additional evidence
recorded by their own build steps, not by that file. They are not counters in
the 2026-09-09 snapshot and change nothing it records.

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
zig build bench-vector -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
```

The resulting executables are:

```text
zig-out/bin/zmath-testing-corpus-producer
zig-out/bin/zmath-corpus-replay
zig-out/bin/zmath-scalar-matrix
zig-out/bin/zmath-vector-matrix
```

Each executable accepts an optional first positional corpus root. The default
root is `test/corpus`. Each accepts `--operation=<manifest-op>` and
`--format=h|f|d`; the filters can be used independently or together. The
vector benchmark also accepts `--repetitions=1..100`; no other executable
does:

```text
zig-out/bin/zmath-testing-corpus-producer test/corpus --operation=atan2 --format=d
zig-out/bin/zmath-corpus-replay test/corpus --operation=atan2 --format=d
zig-out/bin/zmath-scalar-matrix test/corpus --operation=atan2 --format=d
zig-out/bin/zmath-corpus-replay test/corpus --vector --operation=atan2 --format=d
zig-out/bin/zmath-vector-matrix test/corpus --operation=atan2 --format=d --repetitions=3
```

The build wrappers expose these commands:

```text
zig build generate-corpus -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
zig build replay-corpus -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
zig build run-bench-scalar -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
zig build replay-vector -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
zig build run-bench-vector -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
```

Append filters after `--` when using a build wrapper. The wrapper passes
`test/corpus` as its default positional root:

```text
zig build generate-corpus -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe -- --operation=atan2 --format=d
zig build replay-corpus -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe -- --operation=atan2 --format=d
zig build run-bench-scalar -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe -- --operation=atan2 --format=d
zig build replay-vector -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe -- --operation=atan2 --format=d
zig build run-bench-vector -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe -- --operation=exp --format=h --repetitions=3
```

Do not append `--vector` to `replay-vector`. The wrapper already supplies it,
and a repeated `--vector` is rejected.

The generator request and evaluator table use oracle ABI v2.
Each request carries operation bytes, arity, typed input fields, result layout,
structure kind, and typed result fields. The C table has one authoritative
signature and evaluator category for each manifest descriptor.

Replay reads stored typed outputs and compares them with current zmath results.
It does not link or invoke MPFR, Arb, GMP, or FLINT. The scalar benchmark
validates publication metadata and artifact digests before measurement. It
reports measurements only and does not grant manifest acceptance or
whole-domain proof.

The vector lane is a flag on that same executable, so
`zig-out/bin/zmath-corpus-replay test/corpus --vector` and the
`zig build replay-vector` wrapper reach it without a new module, a new root
source file, or a new codec version.

It replays the same stored records through the `zmath.vector` entry points,
packing four records into each `@Vector(4, T)` group, and asserts every
result field of lane `i` against the stored accepted bits of record `i`. That
is corpus-level evidence that the vector surface is bit-identical to the
accepted scalar results over the published tuples. It reuses the existing
`ZCDR` version 1 record format, the existing `corpus_runner` module, and the
published set, so the record codec and the scalar replay path are untouched.
A descriptor with no `zmath.vector` entry point is reported as uncovered, and
the lane fails when no descriptor is covered. The final partial group pads
its unused lanes with the neutral positive zero bit pattern and asserts only
the lanes that exist, so no record is invented for the tail. Its success line
is distinct from the scalar one:
`vector corpus replay verified: descriptors={d} records={d}`.

`run-bench-vector` times that same lane-parallel API over the same published
corpora and validates publication metadata and artifact digests before
measurement, exactly as the scalar benchmark does. `zmath.vector` applies the
identical accepted scalar kernel once per lane, so it is a uniform
lane-parallel API rather than a hand-written SIMD kernel, and the benchmark
measures it exactly as it exists.

## Historical TSV fixtures

Six historical TSV fixtures remain tracked for compatibility and regression
context. They are not the schema-4 typed publication format and do not claim
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
schema-4 full-publication result:

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

## Comparative Google Benchmark matrix

The comparative executable is a separate, test-only C++ program. It does not
change the runtime library. It consumes `bench/comparative.h` and
`bench/comparative_workloads.hpp`; the bridge supplies zmath, Zig, glibc, and
independent pinned CORE-MATH C-ABI function pointers.

The qualified build profile is x86_64 Linux, Haswell, and ReleaseSafe. The
build passes the required `COMPARATIVE_BUILD_MODE`, `COMPARATIVE_TARGET`,
`COMPARATIVE_COMPILER`, and `COMPARATIVE_CXX_FLAGS` macros to C++. The binary
records their values plus the compiler's `__VERSION__`; the runner reads those
binary-produced fields rather than inferring them. The packaged GCC flags are:

```text
-std=c++17 -O3 -march=haswell -ffp-contract=off -fno-builtin -fno-fast-math -fno-lto
```

These flags apply to the wrapper and C++ harness. The independent CORE-MATH
kernels use their own declared flags from DSO provenance. The build does not
add `-fno-builtin` to those upstream kernels.

Build the installed executable with the existing build module:

```text
devenv shell
zig build compare -Dcompare-optimize=ReleaseSafe
```

The runner requires three local reference paths:

```text
ZMATH_CORE_MATH_SOURCE_DIR=/nix/store/<core-math-source>
ZMATH_GLIBC_SOURCE_DIR=/nix/store/<glibc-source>
ZMATH_COMPARE_COREMATH_PATH=/nix/store/<core-math-reference>/lib/libzmath-coremath.so
```

`ZMATH_CORE_MATH_SOURCE_DIR` names the complete CORE-MATH source tree at
revision `3bafed75e3c22399531857d63a3fa0e24bfb42fa`. The CORE-MATH DSO
contains the revision, compiler, declared flags, and source path that the
runner validates. `ZMATH_GLIBC_SOURCE_DIR` names the matching patched glibc
source tree. `ZMATH_COMPARE_COREMATH_PATH` names the independent CORE-MATH
shared object. The runner hashes this DSO and rejects stale, executable, or
non-ELF origin paths before it calculates ratios.

Run the complete matrix. `--out_dir` must name a new directory; this keeps
prior raw evidence immutable:

```text
python3 bench/run_comparative.py \
  --binary=zig-out/bin/zmath-compare \
  --out_dir=bench/results/comparative-YYYYMMDD-HHMMSS
```

Run the standard-library evidence-loader checks without a C++ build:

```text
python3 -m unittest discover -s bench -p test_comparative_runner.py
```

The default procedure uses 0.1 seconds of warmup, 0.2 seconds minimum time,
five repetitions, one CPU selected from the process affinity mask, and
Google Benchmark random interleaving. The runner passes warmup as decimal
seconds and minimum time with an explicit `s` suffix. `--cpu=N` is allowed
only when `N` is in that mask. The runner invokes
`taskset`, never changes a governor or turbo control, and records CPU, kernel,
affinity, governor, turbo, build-version, source-hash, and binary-hash
metadata. The host is reported as shared and non-isolated; pinning reduces
migration but does not isolate the selected core or its SMT sibling. The
runner does not disable ASLR. Retained framework warnings, ranges, and
coefficients of variation are part of the result, not noise to discard.
Metadata records both Jujutsu revisions, all comparison sources, the local
CORE-MATH and glibc source paths, the Nix toolchain declarations, and Google
Benchmark, MPFR, and Zig versions.

The executable parses Google Benchmark options before it runs workload
self-checks or provider audits. `--help` prints framework usage and exits.
`--benchmark_list_tests=true` lists registered rows without running the MPFR
audit. Unknown framework options fail with exit status 2. A filter that matches
no registered row fails.

The runner asks the same binary for `--benchmark_list_tests=true` with the
requested filter. It uses the returned names as the selected set, so `all`,
negative filters, and framework regular-expression behavior remain unchanged.

One run writes all of these artifacts into the selected directory:

```text
benchmark.json       raw Google Benchmark timing rows
accuracy.json        full MPFR-512 audit and availability matrix
metadata.json        machine, build, command, and hash metadata
report.txt           readable paired comparison report
process.stdout.txt   benchmark process stdout
process.stderr.txt   benchmark process stderr
```

Use `--quick` only for a smoke run (0.05 seconds warmup, 0.05 seconds minimum
time, one repetition). Use `--audit_only` to run and serialize the full
accuracy audit without registering timing benchmarks. `--filter=REGEX` is
forwarded to Google Benchmark; the report gives selected-row coverage and
marks excluded rows as `FILTERED`. A filtered run is not a full matrix result.
Malformed options, missing rows, duplicate or missing repetition indices,
errored rows, invalid timing values, incomplete accuracy records, and
inconsistent input digests fail the runner.

Before it calculates ratios, the runner requires `comparison.batch_size` to
equal `1024`. It also requires every `comparison.input_digests` entry to match
the corresponding digest in `accuracy.json`. Every timing row must report an
integer repetition index, and each provider row must contain exactly the
indexes `0` through `repetitions - 1`.

Before the audit or any timing run, the executable opens the absolute Nix
`libm.so.6` path with `dlopen` and resolves all 82 glibc operation and
format functions once with `dlsym`. The origin C ABI reports the actual
resolved backend for each cached function, not a global lookup. Each wrapper
calls its correctly typed backend pointer. This includes the normal C-library
indirect-call overhead. Resolution, validation, and provenance hashing stay
outside the timed loops.

The comparison bridge retains the full Zig CRT and normal Zig panic behavior.
The Zig label denotes the compiled builtin or `std.math` path, including
compiler-runtime lowering; it does not promise an independent algorithm.
Complete, matching provider provenance is required before ratios are computed.

The benchmark registers
`provider/operation/format/distribution` names for all 41 operations:
`exp`, `log`, `sin`, `cos`, `tan`, `sqrt`, `hypot`, `atan2`, `pow`, `acos`,
`acosh`, `acospi`, `asin`, `asinh`, `asinpi`, `atan`, `atan2pi`, `atanh`,
`atanpi`, `cbrt`, `cosh`, `cospi`, `erf`, `erfc`, `exp10`, `exp10m1`, `exp2`,
`exp2m1`, `expm1`, `lgamma`, `log10`, `log10p1`, `log1p`, `log2`, `log2p1`,
`rsqrt`, `sinh`, `sinpi`, `tanh`, `tanpi`, and `tgamma`. It uses three formats
(`f32`, `f64`, `f16`), all three distributions (`normal`, `wide`, `special`),
and every available provider. It writes 1,476 accuracy records. The matrix has
1,173 available timing rows: 369 zmath, 363 CORE-MATH, 246 glibc, and 195 Zig
rows. Inputs are generated once, converted once, and audited before Google
Benchmark starts.
Every timed row invokes the returned opaque binary function pointer with the
same 1,024-call layout and `DoNotOptimize` policy. No operation switch, input
generation, audit, or serialization occurs in the timed loop. Results use
Google Benchmark CPU time per iteration divided by 1,024 calls. This
comparative matrix still measures scalar throughput only, not single-call
latency or SIMD/vector performance, because every provider row is a scalar
function pointer. The separate `run-bench-vector` lane in this repository is
the only vector measurement, and it is deliberately modest: `zmath.vector`
applies the identical accepted scalar kernel once per lane, so it is a
uniform lane-parallel API and not a hand-written SIMD kernel. The benchmark
times it as it exists. No speedup over the scalar loop is claimed or implied.

CORE-MATH is an independent pinned reference, not vendored or shared zmath
code. The DSO exports 121 cached kernels: all 41 binary16 operations and 40
binary32 and 40 binary64 operations. Binary32 and binary64 `sqrt` have no
CORE-MATH source and produce six unsupported accuracy rows across the three
distributions. The runner rejects missing, extra, duplicate, mismatched,
non-ELF, executable, or stale origin paths before it calculates ratios.
It also checks the revision, compiler, declared flags, full source path, DSO
path, DSO hash, and matching glibc source path. The glibc provider has no
binary16 symbols, so its 123 half-format rows remain unsupported. Zig
availability is explicit: it provides 195 timing rows and 174 unsupported rows.
The executable and runner require the exact Zig support set: 13 operations
for binary16 and 26 each for binary32 and binary64. Missing supported entries
and available unsupported entries both fail validation.
The matrix therefore has 303 explicit unsupported records: 123 glibc, 174 Zig,
and six CORE-MATH rows.
Unsupported rows are omitted from timing registration. They never receive a
fallback or a fabricated baseline. The report includes `vs_glibc` and
`vs_coremath`, each computed from the provider median divided by the matching
reference median for the same operation, format, and distribution. The target
analysis is `zmath/reference <= 1.5` per case against each available reference.
CV is sample standard deviation divided by arithmetic mean.

The accuracy file uses an MPFR 512-bit, round-to-nearest-even numerical
reference. It reports finite ULP distance, non-finite class/sign differences,
and signed-zero differences while ignoring NaN payload differences. This is
audit evidence, not a formal correctly-rounded proof. MPFR input conversion
may quiet signaling NaNs, and special-value policies differ between providers;
therefore non-finite and signed-zero differences are visible status data, not
automatic library bugs or certification failures. Accuracy results remain
side-by-side with speed results and do not filter or reorder timing runs.
`wide` means broad finite exponent stress, not a certified rounding-hard
corpus.

For the framework's standard measurement and command-line behavior, see
[Google Benchmark user guide](https://github.com/google/benchmark/blob/main/docs/user_guide.md).
For affinity, frequency, warmup, and other variance controls, see
[Google Benchmark reducing variance](https://github.com/google/benchmark/blob/main/docs/reducing_variance.md).

The [reference performance analysis](../../docs/reference-performance-analysis.md)
covers all 41 functions, the full timing matrix, focused repeats, source
differences, and portable correctly-rounded optimization candidates. The
[CSV evidence](../../docs/reference-performance-matrix.csv) retains each
provider's timing and numerical audit results.
