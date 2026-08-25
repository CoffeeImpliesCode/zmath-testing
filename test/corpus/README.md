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

Every row currently has:

```text
status = "unsupported"
oracle = "none"
special_policy = "zmath_c23_v1"
max_ulp = 0
```

`unsupported` means that the manifest makes no accuracy or runtime acceptance
claim. It does not state that the corresponding zmath symbol is absent.
Source presence and provenance do not change row status.

## Future corpus artifacts

Schema version 2 ships no corpus artifact for an unsupported row. Add an
artifact only after the row changes to `correct` or `bounded` and reviewers
accept implementation and oracle evidence for that exact operation and format.

A future artifact must be immutable, repository-relative, UTF-8 without a byte
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
