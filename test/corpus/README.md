# Scalar oracle corpus

This directory defines the pinned scalar oracle contract for `zmath`.
The normative rules are in `../../../zmath/spec/core-math-2026-08-22.md` in the `zmath` repository.
The runtime library does not depend on this directory or on oracle libraries.

## Manifest

`manifest.toml` uses schema version `1`.
It pins CORE-MATH revision `3bafed75e3c22399531857d63a3fa0e24bfb42fa`.
It pins MPFR and Arb at 512-bit precision.
Both oracle paths use round-to-nearest, ties-to-even.
An uncertain result fails closed.
The producer must not refine precision silently or write a best-effort result.

The accepted format identifiers are:

| Identifier | Format | Width | Bit text |
| --- | --- | ---: | ---: |
| `h` | IEEE binary16 | 16 | 4 lowercase hexadecimal digits |
| `f` | IEEE binary32 | 32 | 8 lowercase hexadecimal digits |
| `d` | IEEE binary64 | 64 | 16 lowercase hexadecimal digits |

`q` is reserved for a future binary128 contract and is rejected by schema version 1.
`bfloat16` is rejected.
Aliases, uppercase format identifiers, and unknown formats are rejected.

The manifest has one row for each operation-format pair for `exp`, `log`, and `sin`.
The `exp` rows, `log/h`, and `sin/h` rows have status `correct`; remaining `log`
and `sin` rows are `unsupported`. `correct` requires exact nearest-even results
proved by the oracle bridge. `bounded` would allow only its stated finite ULP limit
in nearest-even mode.
Unsupported rows do not claim an accepted accuracy contract.
Do not add corpus data or change a row to `correct` or `bounded` without the
implementation and oracle evidence required by the specification.

## TSV files

Schema version 1 does not ship a TSV data file. Accepted correctness currently comes
from executable exhaustive or seeded oracle campaigns, not a checked-in vector table.
A future data file must be UTF-8 without a byte-order mark, use LF line endings, and end with one LF.
It must contain this exact header:

```text
op	format	input_bits	output_bits	output_class	max_ulp
```

Every data row has six tab-separated fields:

- `op`: `exp`, `log`, or `sin`.
- `format`: `h`, `f`, or `d`.
- `input_bits`: exact fixed-width lowercase hexadecimal bits without `0x`.
- `output_bits`: exact fixed-width lowercase hexadecimal bits without `0x`.
- `output_class`: `normal`, `subnormal`, `zero`, `infinity`, or `qnan`.
- `max_ulp`: canonical unsigned decimal text. Correctly rounded rows use `0`. Bounded finite rows use the allowed ULP limit.

Rows are unique and sorted by operation, then format, then unsigned input bits.
Consumers reject duplicate or unsorted rows.
Consumers compare special-value bits exactly. For bounded finite normal or subnormal values, they allow at most `max_ulp` ULPs and require the same sign.
They do not replace a bad row with a host-library result or a nearby value.

The specification defines the exact encodings for signed zero, positive one, infinity, and canonical quiet NaN.
For NaN input, the producer preserves the sign and payload and sets the quiet bit.
A signaling NaN output is invalid.
Operation-specific special-value rules are exact and have precedence only after the NaN-input rule.
