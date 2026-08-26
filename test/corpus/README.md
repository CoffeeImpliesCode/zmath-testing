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
Special values require exact target-format bits. Finite candidates require
MPFR at 512 bits and an Arb interval that rounds uniquely to the same bits.
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
duplicate, or ambiguous manifest bindings are errors. No artifact is checked
in while all rows remain `unsupported`.

Target and mode are artifact metadata, not TSV columns. Acceptance requires an
explicit `TargetMode` record on each embedded artifact and an active
target/mode record from the caller/build. Missing or mismatched records fail
closed. The build uses `-Dcorpus-target` and `-Dcorpus-mode` when supplied and
otherwise records the active target and Zig mode. The accepted `log/f` artifact
therefore carries the exact target triple and Zig mode supplied by the
caller/build.

Exploratory fuzzing is a separate surface. A caller must provide a fixed seed
to the seeded fuzz helper, and a fuzz campaign must preserve its seed,
compiler, source, budget, and callback request order. Fuzz inputs never become
accepted TSV rows automatically.

## Corpus producer

The test-only producer runs with `zig build generate-corpus`. It links the
existing MPFR and Arb bridge. It writes temporary files and renames them only
after all six artifacts pass the oracle checks.

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

The F and D boundary sets each contain the 18 inputs from the deterministic
Task 3 campaign. The producer adds exact special values, every F and D input
from `scalar_exp_test.zig`, and the 51 pinned CORE-MATH binary64 Exp database
inputs from `scalar.zig`. It adds the immediate predecessor and successor of
each selected finite input, then sorts and removes duplicates.

For each row, the producer gets the output bits and class from MPFR at 512
bits with round-to-nearest, ties-to-even. It then requires a matching unique
512-bit Arb rounding proof for finite output classes. Any oracle error,
disagreement, or uncertainty stops the producer before it changes an
artifact.
