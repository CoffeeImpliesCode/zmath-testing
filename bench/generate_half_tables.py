#!/usr/bin/env python3
"""Build the exact binary16 asin/tanh tables from the pinned ZCDR corpus."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path

HARNESS_ROOT = Path(__file__).resolve().parents[1]
CORPUS_ROOT = HARNESS_ROOT / "test/corpus/generated"
METADATA_SHA256 = "f7e624e2be25c43935da9afa179cb20149fce4a0326dbfa310056c5761a017ab"
SOURCES = (
    (
        "asin",
        "009_asin.zcdr",
        "94971c2ce0d1ec87658187a29a6da7c2fb777eebe8c756431bd6970923a654bd",
        9,
        0x29C5,
        0x3C00,
    ),
    (
        "tanh",
        "258_tanh.zcdr",
        "824069309d2e1e2b059dd74a79563becd051531a342141d55e583c1e18c44910",
        258,
        0x2745,
        0x4481,
    ),
)
HEADER_LENGTH = 26
FLOAT_FIELD_LENGTH = 12
DOMAIN_SIZE = 1 << 16


class CorpusError(ValueError):
    """The pinned corpus is missing, corrupt, or not unary binary16."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CorpusError(message)


def half_class(bits: int) -> int:
    magnitude = bits & 0x7FFF
    if magnitude < 0x0400:
        return 2 if magnitude == 0 else 1
    if magnitude < 0x7C00:
        return 0
    if magnitude == 0x7C00:
        return 3
    return 4 if magnitude & 0x0200 else 6


def validate_metadata() -> None:
    verification = json.loads((CORPUS_ROOT / "verification.json").read_text())
    require(
        verification.get("metadata_sha256") == METADATA_SHA256,
        "unexpected metadata SHA-256 pin",
    )
    metadata = (CORPUS_ROOT / "metadata.txt").read_bytes()
    require(
        hashlib.sha256(metadata).hexdigest() == METADATA_SHA256,
        "corpus metadata SHA-256 mismatch",
    )
    rows: dict[int, dict[str, str]] = {}
    wanted = {source[3] for source in SOURCES}
    for line in metadata.decode("ascii").splitlines():
        fields = line.split(";")
        if not fields or not fields[0].startswith("signature="):
            continue
        signature = int(fields[0].split("=", 1)[1])
        if signature not in wanted:
            continue
        require(signature not in rows, f"duplicate metadata signature {signature}")
        row = dict(field.split("=", 1) for field in fields)
        require(len(row) == len(fields), f"duplicate metadata key for {signature}")
        rows[signature] = row
    require(set(rows) == wanted, "missing unary half corpus metadata")
    for operation, filename, digest, signature, _, _ in SOURCES:
        row = rows[signature]
        expected = {
            "signature": str(signature),
            "operation": operation,
            "evaluator": "mpfr_arb",
            "campaign": "exhaustive_h_unary",
            "coverage": "exhaustive_h_unary",
            "campaign_tuple_count": str(DOMAIN_SIZE),
            "selection_rule": "binary16_raw_bits_v1",
            "cardinality": str(DOMAIN_SIZE),
            "records": str(DOMAIN_SIZE),
            "claims_exhaustive_full_cartesian": "true",
            "artifact": f"test/corpus/generated/records/{filename}",
            "artifact_sha256": digest,
        }
        for key, value in expected.items():
            require(
                row.get(key) == value,
                f"{filename}: unexpected metadata {key}={row.get(key)!r}",
            )


def decode_field(frame: memoryview, offset: int, result: bool) -> int:
    require(offset + FLOAT_FIELD_LENGTH <= len(frame), "truncated binary16 field")
    kind, fmt, field_class, type_code = frame[offset : offset + 4]
    require(kind == fmt == type_code == 0, "expected a binary16 float field")
    bits = struct.unpack_from("<Q", frame, offset + 4)[0]
    require(bits <= 0xFFFF, "binary16 field has high bits")
    require(
        field_class == half_class(bits) or (not result and field_class == 5),
        "wrong binary16 field class",
    )
    return bits


def decode_source(operation: str, filename: str, digest: str) -> list[int]:
    data = (CORPUS_ROOT / "records" / filename).read_bytes()
    require(
        hashlib.sha256(data).hexdigest() == digest,
        f"{filename}: artifact SHA-256 mismatch",
    )
    name = operation.encode("ascii")
    expected_length = HEADER_LENGTH + len(name) + 1 + 2 * FLOAT_FIELD_LENGTH
    outputs = [-1] * DOMAIN_SIZE
    offset = 0
    records = 0
    view = memoryview(data)
    while offset < len(data):
        require(offset + HEADER_LENGTH <= len(data), f"{filename}: truncated header")
        require(
            view[offset : offset + 4] == b"ZCDR" and data[offset + 4] == 1,
            f"{filename}: unsupported ZCDR codec",
        )
        length, operation_length = struct.unpack_from("<IH", data, offset + 5)
        require(
            length == expected_length and offset + length <= len(data),
            f"{filename}: invalid unary half frame length",
        )
        frame = view[offset : offset + length]
        require(
            operation_length == len(name)
            and tuple(frame[11:14]) == (1, 1, 1)
            and struct.unpack_from("<Q", frame, 14)[0] == 0
            and bytes(frame[22:26]) == b"\x00\x00\xff\xff",
            f"{filename}: invalid unary half descriptor",
        )
        require(
            frame[26 : 26 + len(name)] == name and frame[26 + len(name)] == 0,
            f"{filename}: wrong operation or provenance",
        )
        field_offset = HEADER_LENGTH + len(name) + 1
        input_bits = decode_field(frame, field_offset, False)
        result_bits = decode_field(frame, field_offset + FLOAT_FIELD_LENGTH, True)
        require(outputs[input_bits] < 0, f"{filename}: repeated input {input_bits:04x}")
        outputs[input_bits] = result_bits
        records += 1
        offset += length
    require(
        records == DOMAIN_SIZE and all(bits >= 0 for bits in outputs),
        f"{filename}: not all 65536 raw binary16 inputs are present",
    )
    return outputs


def exact_table(operation: str, outputs: list[int], start: int, end: int) -> list[int]:
    table: list[int] = []
    for magnitude in range(0x8000):
        positive = outputs[magnitude]
        negative = outputs[magnitude | 0x8000]
        if magnitude > 0x7C00:
            require(
                positive == (magnitude | 0x0200) and negative == (magnitude | 0x8200),
                f"{operation}: NaN sign or payload changed at {magnitude:04x}",
            )
        elif operation == "asin" and magnitude > end:
            require(
                positive == negative == 0x7E00,
                f"asin: wrong domain result at {magnitude:04x}",
            )
        elif operation == "tanh" and magnitude > end:
            require(
                positive == 0x3C00 and negative == 0xBC00,
                f"tanh: wrong saturated result at {magnitude:04x}",
            )
        elif magnitude < start:
            require(
                positive == magnitude and negative == (magnitude | 0x8000),
                f"{operation}: wrong identity result at {magnitude:04x}",
            )
        else:
            bound = 0x3E48 if operation == "asin" else 0x3BFF
            require(
                0 < positive <= bound and negative == (positive | 0x8000),
                f"{operation}: wrong range or odd symmetry at {magnitude:04x}",
            )
            if operation == "asin":
                require(
                    positive >= magnitude,
                    f"asin: result below input at {magnitude:04x}",
                )
            else:
                require(
                    positive <= magnitude,
                    f"tanh: result above input at {magnitude:04x}",
                )
            table.append(positive)
    require(len(table) == end - start + 1, f"{operation}: invalid table span")
    return table


def generate() -> bytes:
    validate_metadata()
    text = [
        "// Generated by zmath-testing/bench/generate_half_tables.py from pinned ZCDR v1 corpora.\n",
        "// Each entry is the exact positive binary16 result at the input magnitude index.\n",
    ]
    for operation, filename, digest, _, start, end in SOURCES:
        outputs = decode_source(operation, filename, digest)
        table = exact_table(operation, outputs, start, end)
        text.extend(
            (
                f"// {operation}: test/corpus/generated/records/{filename}\n",
                f"// SHA-256: {digest}\n",
                f"// Input magnitudes: 0x{start:04x}..0x{end:04x}.\n",
                f"pub const {operation}_bits = [_]u16{{\n",
            )
        )
        for index in range(0, len(table), 10):
            text.append(
                "    "
                + " ".join(f"0x{bits:04x}," for bits in table[index : index + 10])
                + "\n"
            )
        text.append("};\n\n")
    return ("".join(text).rstrip("\n") + "\n").encode("ascii")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--runtime-output",
        required=True,
        type=Path,
        help="Explicit path to zmath/src/scalar_half_tables.zig",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Fail if the existing runtime table differs; do not write",
    )
    args = parser.parse_args()
    require(
        args.runtime_output.name == "scalar_half_tables.zig",
        "runtime output must be scalar_half_tables.zig",
    )
    generated = generate()
    if args.check:
        require(
            args.runtime_output.read_bytes() == generated,
            "runtime half tables differ from the exhaustive corpus",
        )
    else:
        args.runtime_output.write_bytes(generated)


if __name__ == "__main__":
    main()
