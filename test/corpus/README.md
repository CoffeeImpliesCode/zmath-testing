# Scalar oracle corpus

This directory defines the scalar oracle contract for `zmath`.
The runtime library does not depend on this directory or on oracle libraries.
The normative contract is in `../../../zmath/spec/core-math-2026-08-22.md`.

## Manifest

`manifest.toml` uses schema version 2. It pins CORE-MATH revision
`3bafed75e3c22399531857d63a3fa0e24bfb42fa`, MPFR precision at 512 bits, and
Arb precision at 512 bits. Both oracle paths use round-to-nearest, ties-to-even.
The uncertainty policy is fail closed.

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

The manifest has 315 typed rows. Provenance records ownership, not acceptance.
Use only these ordered arrays:

- `["zmath"]` for zmath-owned operations.
- `["core_math"]` for CORE-MATH-owned operations.
- `["zmath", "core_math"]` for operations owned by both projects.

The row order is deterministic. Sort first by the provenance array, then by the
case-sensitive operation spelling, then by the typed format in `h`, `f`, `d`
order. The operation spelling declaration is exactly
`c23_hfd_lowercase_v1`.

## Current status

Six rows are accepted: `exp/h`, `exp/f`, `exp/d`, `log/h`, `log/f`, and
`sin/h`. Each accepted row has:

```text
status = "correct"
oracle = "mpfr_arb"
special_policy = "zmath_c23_v1"
max_ulp = 0
```

The remaining 309 typed rows have:

```text
status = "unsupported"
oracle = "none"
special_policy = "zmath_c23_v1"
max_ulp = 0
```

`unsupported` means that the manifest makes no accuracy or runtime acceptance
claim. It does not state that the corresponding zmath symbol is absent.
Source presence and provenance do not change row status.

Implementation, manifest acceptance, corpus evidence, and whole-domain proof are
separate facts. Source exports establish implementation only. A `correct` or
`bounded` row establishes manifest acceptance only. Corpus evidence covers the
stored rows. Whole-domain proof requires exhaustive inputs or a separate proof
for the complete operation-format domain.

## Corpus artifacts

Schema version 2 ships no corpus artifact for an unsupported row. The checked-in
`log_f.tsv` artifact covers the accepted `log/f` row. Add an artifact only after
the row changes to `correct` or `bounded` and reviewers accept implementation
and oracle evidence for that exact operation and format.

Each artifact must be immutable, repository-relative, UTF-8 without a byte
order mark, use LF line endings, and end with one LF. Its header must be exactly:

```text
op\tformat\tinput_bits\toutput_bits\toutput_class\tmax_ulp
```

Data rows must be unique and sorted by operation, format, and unsigned input
bits. Bit fields use fixed-width lowercase hexadecimal text without `0x`.
Output classes are `normal`, `subnormal`, `zero`, `infinity`, and `qnan`.
Special values require exact target-format bits. Finite inputs within the
mathematical domain require MPFR at 512 bits and a unique 512-bit Arb proof,
including results that round to target infinity or zero.
`max_ulp` is canonical unsigned decimal text. Correct rows require `0`.
Bounded rows permit any non-negative `max_ulp`, including `0`.
Producers must fail on uncertainty or disagreement and must not use host `libm`,
`fenv`, or `errno` to choose an output.

## Deterministic replay

Acceptance execution reads only immutable embedded TSV rows. It does not call
`std.testing.random_seed`, use a process clock, or sample an input domain. The
producer must generate rows from the pinned MPFR/Arb contract and fail closed
on an oracle disagreement, an uncertain Arb interval, or an unknown special
value. The runner checks the runtime bits, stored bits, MPFR bits, output
classes, and Arb proof before it accepts a row.

Every artifact is bound to exactly one manifest operation-format row. The row
must have status `correct` or `bounded`; an `unsupported` row cannot load an
artifact. The artifact name, operation, format, fixed-width bits, ordering,
uniqueness, output class, and `max_ulp` must agree with the manifest. Missing,
duplicate, or ambiguous manifest bindings are errors.

Target, CPU, and optimize mode are artifact metadata, not TSV columns. Acceptance
requires an explicit `TargetMode` record on each embedded artifact and an active
record from the caller/build. The accepted evidence tuple is immutable:

```text
target = x86_64-linux-gnu.2.38
cpu = haswell
optimize = ReleaseSafe
```

The build records this exact tuple in embedded metadata. The oracle runner
rejects missing metadata and rejects any target, CPU, or optimize-mode mismatch.
No other target profile can replay an accepted artifact.

The exact replay command is:

```text
zig build oracle -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
```

The benchmark commands use the same qualified profile:

```text
zig build bench -Dbench-target=scalar-log-f -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
zig build run-bench -Dbench-target=scalar-log-f -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
```

The same commands accept these six target names:

| Target | Corpus rows | Timed operations | Observed elapsed ns | Result checksum |
| --- | ---: | ---: | ---: | ---: |
| `scalar-exp-h` | 65,536 | 1,048,576 | 14,974,205 | 17,401,774,768 |
| `scalar-exp-f` | 29 | 475,136 | 6,522,980 | 753,964,464,013,312 |
| `scalar-exp-d` | 182 | 2,981,888 | 114,997,455 | 15,514,520,106,984,325,120 |
| `scalar-log-h` | 65,536 | 1,048,576 | 9,811,652 | 34,843,479,648 |
| `scalar-log-f` | 64 | 1,048,576 | 28,824,041 | 2,036,652,067,569,664 |
| `scalar-sin-h` | 65,536 | 1,048,576 | 9,792,795 | 29,520,195,616 |

These are single native runs on a shared host, not performance bounds.
Each target validates its corpus and SHA-256 before the timed loop.
Per-call input barriers prevent constant folding and loop hoisting.
The output includes the resolved target triple, sorted CPU features, mode,
corpus path, row count, operation count, SHA-256, elapsed time, and checksum.
The exact populated Haswell feature set is required; adding or removing a
feature rejects the accepted profile.

Exploratory fuzzing is a separate surface. A caller must provide a fixed seed
to the seeded fuzz helper, and a fuzz campaign must preserve its seed,
compiler, source, budget, and callback request order. Fuzz inputs never become
accepted TSV rows automatically.

The Exp-only Smith campaign uses Zig 0.16.0:

```text
zig build oracle-fuzz --fuzz=100 --seed 0x7a6d6174 -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
```

It instruments the same Zig Exp source used by the library. The oracle C
bridge is linked separately without coverage instrumentation. Zig 0.16's
built-in fuzzer cannot combine its PC-table layout with Clang's C layout.
This target therefore omits C kernel link objects. A future C-backed campaign
needs compatible coverage support; it must not silently claim C coverage.

## Corpus producer

The test-only producer runs on the host. At compile time, it checks that
the requested corpus profile is exactly the qualified target, CPU features,
and mode. Host execution does not qualify an additional runtime profile.

```text
zig build generate-corpus -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe
```

It links the existing MPFR and Arb bridge. It writes temporary files and renames
them only after all six accepted artifacts pass the oracle checks.

The producer writes these immutable artifacts:

- `exp_h.tsv`: 65,536 data rows. It covers every unsigned binary16
  encoding in numeric order.
- `exp_f.tsv`: 29 data rows.
- `exp_d.tsv`: 182 data rows.
- `log_h.tsv`: 65,536 data rows. It covers every unsigned binary16
  encoding in numeric order.
- `log_f.tsv`: 64 data rows. Its provenance is the exact binary32 vectors in
  `scalar_log_test.zig`: special values, subnormal/normal boundaries,
  adjacent-to-one values, and nine CORE-MATH fallback/low-correction vectors
  with each vector's immediate predecessor and successor. Inputs are sorted
  and deduplicated.

- `sin_h.tsv`: 65,536 data rows. It covers every unsigned binary16
  encoding in numeric order.
The H artifacts are exhaustive over their unary binary16 domains.
The F and D artifacts are deterministic selected-case corpora. They provide
evidence for stored inputs only and do not prove their whole domains.

The F and D boundary sets each contain the 18 inputs from the deterministic
Task 3 campaign. The producer adds exact special values, every F and D input
from `scalar_exp_test.zig`, and the 51 pinned CORE-MATH binary64 Exp database
inputs from `scalar.zig`. It adds the immediate predecessor and successor of
each selected finite input, then sorts and removes duplicates.

For each row, the producer gets the output bits and class from MPFR at 512
bits with round-to-nearest, ties-to-even. It calls the Arb bridge for every
row. The bridge requires a unique 512-bit enclosure proof for finite
mathematical results, including target-format overflow, and applies exact
nonfinite-input and domain-special rules. Any oracle error, disagreement,
or uncertainty stops generation before artifact replacement.

## Exact-power resource measurements

Power families remain `unsupported`. Resource measurements do not establish
numerical acceptance or a full-domain stack or latency bound.

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
the runs were not isolated. In particular, these samples do not establish
a speedup ratio between modes. Minimum-subnormal `compoundn` is expensive.

Valgrind 3.27.1 Massif, with `--stacks=yes --time-unit=B`, observed whole-program
peak stack sizes of 362,832 bytes in ReleaseSafe and 362,976 bytes in
ReleaseFast. It reported zero heap bytes in both runs. These peaks cover
only the 36 scenarios and include measurement-program stack use.
Do not use instrumented elapsed times as native latency measurements.

`readelf -d` found no dynamic section in all six scalar benchmark binaries
or either power measurement binary. `nm -u` listed only `_DYNAMIC`;
none referenced MPFR, GMP, FLINT, Arb, or libc math symbols.
