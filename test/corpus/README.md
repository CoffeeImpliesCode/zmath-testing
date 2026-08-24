# Scalar and descriptor-driven oracle corpus

This directory defines the pinned scalar oracle contract for `zmath`.
The normative rules are in `../../../zmath/spec/core-math-2026-08-22.md`.
The runtime library does not depend on this directory or on oracle libraries.

## Manifest schema

`manifest.toml` uses schema version `2`.
The parser accepts operation names as case-sensitive ASCII identifiers.
It does not use an operation allowlist.

The manifest pins CORE-MATH revision `3bafed75e3c22399531857d63a3fa0e24bfb42fa`.
It pins MPFR and Arb at exactly 512-bit precision.
The required rounding mode is `nearest_even`.
The caller owns the floating-point environment.
The parser does not inspect or change that environment.

The accepted format identifiers are:

| Identifier | Format | Width | Bit text |
| --- | --- | ---: | --- |
| `h` | IEEE binary16 | 16 | 4 lowercase hexadecimal digits |
| `f` | IEEE binary32 | 32 | 8 lowercase hexadecimal digits |
| `d` | IEEE binary64 | 64 | 16 lowercase hexadecimal digits |

`q`, `f128`, and `bfloat16` are rejected.
Aliases, uppercase format identifiers, and unknown formats are rejected.

The root `columns` value fixes the function row order:

```text
op, provenance, status, arity, inputs, result, oracle, special_policy, max_ulp
```

Every function row must contain these keys once and in this order.
Unknown keys, duplicate keys, and out-of-order keys fail closed.
The root keys also occur once and in their declared order.

## Function rows

`op` is an arbitrary case-sensitive ASCII operation spelling.
It can include letters, digits, and underscores after the first character.

`provenance` is a non-empty ordered array of distinct values.
The allowed values are `c23_7_12`, `c23_ieee`, `annex_f`, and `annex_h`.
The array order is the declaration order above.

`arity` is a positive argument count.
`inputs` is a typed descriptor array with exactly `arity` entries.
The supported argument descriptors are:

| Descriptor | Meaning |
| --- | --- |
| `float:h`, `float:f`, `float:d` | A binary16, binary32, or binary64 value |
| `integer:i64`, `integer:u32` | A fixed-width integer value |
| `tag` | A string tag, such as the `nan` family tag |
| `fromfp_round` | A `FromFpRound` direction |

The parser also accepts the other fixed-width signed and unsigned integer names used by
C result descriptors. It rejects unknown integer names.

The result descriptor is one of:

```text
float:h       float:f       float:d
integer:i64   integer:u32
bool
struct:canonicalize:h   struct:canonicalize:f   struct:canonicalize:d
struct:frexp:h          struct:frexp:f          struct:frexp:d
struct:modf:h           struct:modf:f           struct:modf:d
struct:remquo:h         struct:remquo:f         struct:remquo:d
struct:lgamma:h         struct:lgamma:f         struct:lgamma:d
struct:payload:h        struct:payload:f        struct:payload:d
```

The struct descriptors map to explicit Zig value results.
`FrexpResult(T)` has `fraction` and `exponent` fields.
`ModfResult(T)` has `fractional` and `integral` fields.
`RemquoResult(T)` has `value` and `quotient` fields.
`LgammaResult(T)` has `value` and `sign` fields.
`CanonicalizeResult(T)` and `PayloadResult(T)` have `value` and `ok` fields.
C-style integer conversion results use `i64`.

Input and output formats are independent.
For example, a narrowing row can use `inputs = ["float:d", "float:d"]` and
`result = "float:f"`.
The parser does not collapse those formats into one operation format.

`status` is one of `unsupported`, `correct`, or `bounded`.
`max_ulp` is canonical unsigned decimal text.
`unsupported` rows and `correct` rows require `max_ulp = 0`.
`bounded` rows require a declared non-negative `max_ulp` value.
Unsupported rows make no runtime or oracle acceptance claim.
A correct row requires exact nearest-even evidence.
A bounded row permits only its declared finite-result ULP limit.

`oracle` declares the available capability.
The allowed values are `none`, `mpfr`, and `mpfr_arb`.
Every unsupported row requires `none`.
Every `correct` or `bounded` row requires `mpfr_arb`.
The parser records this declaration and does not infer a capability from status.

`special_policy` is required on every row and must be `zmath_c23_v1`.
This policy makes NaN and special-value behavior explicit.
The producer writes exact target-format bit patterns.
It does not ask a host library to choose special-value bits.

For a NaN input, preserve the sign and payload and set the target quiet bit.
A quiet NaN remains unchanged.
A signaling NaN becomes a quiet NaN.
An invalid non-NaN input returns the positive canonical quiet NaN.
An operation-specific rule takes precedence over the general rule.

The legacy `fmax` and `fmin` policy is local to zmath.
It is not a portable C guarantee.
One NaN selects the numeric operand.
Two NaNs return the positive canonical quiet NaN.
An opposite signed-zero tie returns `+0` for `fmax` and `-0` for `fmin`.

## Target registry

The manifest contains 315 rows.
It covers each target operation and typed descriptor in the C23 API.

| Provenance | Rows | Coverage |
| --- | ---: | --- |
| `c23_7_12` | 261 | 85 baseline families in H, F, and D, plus six legacy narrowing operations |
| `c23_ieee` | 21 | Seven IEEE-owned families in H, F, and D |
| `annex_f` | 15 | Five optional Annex F families in H, F, and D |
| `annex_h` | 18 | Six Annex H operations for each supported narrowing format pair |

The Annex H rows cover these format pairs:

| Source | Destination |
| --- | --- |
| `f32` | `f16` |
| `f64` | `f16` |
| `f64` | `f32` |

Each pair has add, subtract, multiply, divide, fused multiply-add, and square root rows.
The six legacy narrowing rows use `f64` inputs and an `f32` result.
Legacy and Annex H names remain distinct when their descriptors are equal.

The registry preserves only five evidence-backed correct rows.
These rows are `exp` in H, F, and D, `log` in H, and `sin` in H.
Each correct row declares `mpfr_arb` and `max_ulp = 0`.

The other 310 rows have status `unsupported`.
Each unsupported row declares `oracle = "none"` and `max_ulp = 0`.
The registry has no bounded row.
Registry coverage does not grant implementation or manifest acceptance.
Do not change status without the implementation and oracle evidence required by the specification.

Rows are unique and sorted by provenance, operation spelling, typed input descriptors,
and typed result descriptor.
Consumers reject duplicate or unsorted rows.

## TSV data

A future data file must be UTF-8 without a byte-order mark, use LF line endings, and end
with one LF.
It must contain this exact header:

```text
op\tinput_format\toutput_format\tinput_bits\toutput_bits\toutput_class\tmax_ulp
```

Every data row has seven tab-separated fields:

- `op`: the exact operation spelling from the manifest.
- `input_format`: `h`, `f`, or `d` for the input bits.
- `output_format`: `h`, `f`, or `d` for the output bits.
- `input_bits`: fixed-width lowercase hexadecimal bits without `0x`.
- `output_bits`: fixed-width lowercase hexadecimal bits without `0x`.
- `output_class`: `normal`, `subnormal`, `zero`, `infinity`, or `qnan`.
- `max_ulp`: canonical unsigned decimal text.

Input and output widths are checked independently.
Rows are sorted by operation, input format, output format, and input bits.
The tuple `(op, input_format, output_format, input_bits)` must be unique.

Special-value rows always use `max_ulp = 0` and require an exact bit match.
Finite bounded rows require the same sign and a ULP distance no greater than `max_ulp`.
A consumer must reject a bad row.
It must not skip the row, use a host result, or substitute a nearby value.

## Descriptor corpus codec

New campaigns use the versioned descriptor codec, not the scalar TSV reader.
The current descriptor codec version is `1`. Each record is a length-framed
little-endian byte sequence:

```text
magic[4] = "ZCDR"
version[1]
record_length[4]
operation_length[2]
provenance_count[1]
argument_count[1]
result_count[1]
max_ulp[8]
result_descriptor[4]
operation[operation_length]
provenance[provenance_count]
arguments[argument_count]
results[result_count]
```

The length includes the complete record. A corpus file is a concatenation of
records. Consumers reject an unknown version, a short record, trailing bytes,
bad lengths, unknown discriminants, and bytes after the declared result array.

Every field has a four-byte descriptor header followed by its payload:

```text
kind[1] format[1] class[1] type_or_rounding[1] payload[...]
```

Field kinds are `float`, `signed_integer`, `unsigned_integer`, `boolean`,
`tag`, and `rounding`. Float formats are independent per field (`h`, `f`, or
`d`). Float payloads are raw unsigned target-format bits. A result float must
declare the derived class (`normal`, `subnormal`, `zero`, `infinity`, or
`qnan`); input floats may use class `none`. Integer payloads use fixed-width
two's-complement low bits for signed values and unsigned low bits for
unsigned values. Supported signed widths include `i2`, `i8`, `i16`, `i32`,
and `i64`; out-of-range values are rejected. Boolean payloads are exactly
`0` or `1`. Tags carry a `u32` byte length followed by the exact bytes, so
embedded NUL and non-text tag bytes are preserved. Rounding fields carry one
of the five `FromFpRound` codes.

The four result-descriptor bytes are `(layout, format, structure, type)`.
`layout = 0` is a scalar float and uses `format`; `layout = 1` is a scalar
integer and uses `type`; `layout = 2` is bool; `layout = 3` is a structure
and uses `format` plus `structure`. Unused bytes are `0xff` where applicable.

The result descriptor identifies a scalar float, scalar integer, scalar bool,
or one of these nine ordered two-field structures:

```text
canonicalize  frexp  modf  remquo  lgamma
payload       atan2  power integer
```

The structure field order is normative. `canonicalize`, `payload`, `atan2`,
and `power` are `(float, bool)`; `frexp` and `remquo` are `(float, i32)`;
`modf` is `(float, float)`; `lgamma` is `(float, i2)`; and `integer` is
`(i64, bool)`. A record may therefore represent binary, ternary, status, and
narrowing operations without overloading scalar columns. For example:

```text
fma: [float:h, float:h, float:h] -> float:h
f16addf64: [float:d, float:d] -> float:h
```

Records sort by operation spelling, provenance sequence, and then every
argument field in declaration order. Field ordering compares kind, format,
integer/rounding code, and raw value bytes. Equal complete input keys are
duplicates even when their result bytes differ. Consumers reject both an
unsorted key and a duplicate key.

The seven-column TSV format above is retained only as compatibility version
`2` for legacy unary scalar rows. It has one input, one output, one output
class, and one input-based sort key. It is not evidence for binary, ternary,
multi-result, status, tag, integer, boolean, mixed-format, or narrowing
records. Future campaign readers must call the descriptor codec.
