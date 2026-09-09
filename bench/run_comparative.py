#!/usr/bin/env python3
"""Run and report the zmath scalar comparison matrix.

The runner uses only Python's standard library. It pins the benchmark process
with taskset, never changes frequency controls, and preserves raw benchmark,
accuracy, metadata, and diagnostic files in one caller-selected directory.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import pathlib
import platform
import shutil
import statistics
import subprocess
import sys
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple


OPERATIONS: Tuple[str, ...] = (
    "exp",
    "log",
    "sin",
    "cos",
    "tan",
    "sqrt",
    "hypot",
    "atan2",
    "pow",
    "acos",
    "acosh",
    "acospi",
    "asin",
    "asinh",
    "asinpi",
    "atan",
    "atan2pi",
    "atanh",
    "atanpi",
    "cbrt",
    "cosh",
    "cospi",
    "erf",
    "erfc",
    "exp10",
    "exp10m1",
    "exp2",
    "exp2m1",
    "expm1",
    "lgamma",
    "log10",
    "log10p1",
    "log1p",
    "log2",
    "log2p1",
    "rsqrt",
    "sinh",
    "sinpi",
    "tanh",
    "tanpi",
    "tgamma",
)
FORMATS: Tuple[str, ...] = ("f32", "f64", "f16")
DISTRIBUTIONS: Tuple[str, ...] = ("normal", "wide", "special")
PROVIDERS: Tuple[str, ...] = ("zmath", "zig", "glibc", "coremath")
REQUIRED_PROVIDERS: Tuple[str, ...] = ("zmath",)
COREMATH_UNSUPPORTED_KEYS: Tuple[Tuple[str, str], ...] = (
    ("sqrt", "f32"),
    ("sqrt", "f64"),
)
GLIBC_UNSUPPORTED_FORMATS: Tuple[str, ...] = ("f16",)
ZIG_F16_OPERATIONS: Tuple[str, ...] = (
    "exp", "log", "sin", "cos", "tan", "sqrt", "hypot",
    "acos", "asin", "atan", "exp2", "log10", "log2",
)
ZIG_F32_F64_OPERATIONS: Tuple[str, ...] = (
    "exp", "log", "sin", "cos", "tan", "sqrt", "hypot", "atan2", "pow",
    "acos", "acosh", "asin", "asinh", "atan", "atanh", "cbrt", "cosh",
    "exp2", "expm1", "lgamma", "log10", "log1p", "log2", "sinh", "tanh",
    "tgamma",
)
COREMATH_REVISION = "3bafed75e3c22399531857d63a3fa0e24bfb42fa"
BATCH_SIZE = 1024
GLIBC_ORIGIN_COUNT = len(OPERATIONS) * (
    len(FORMATS) - len(GLIBC_UNSUPPORTED_FORMATS)
)
COREMATH_ORIGIN_KEYS: Tuple[Tuple[str, str], ...] = tuple(
    (operation, fmt)
    for operation in OPERATIONS
    for fmt in FORMATS
    if (operation, fmt) not in COREMATH_UNSUPPORTED_KEYS
)
COREMATH_ORIGIN_COUNT = len(COREMATH_ORIGIN_KEYS)

Key = Tuple[str, str, str, str]
TupleKey = Tuple[str, str, str]


class RunnerError(RuntimeError):
    """A user-facing run or report error."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run zmath versus Zig, glibc, and independent pinned CORE-MATH."
    )
    parser.add_argument(
        "--binary",
        type=pathlib.Path,
        default=None,
        help="Installed comparison executable (default: zig-out/bin/zmath-compare).",
    )
    build = parser.add_mutually_exclusive_group()
    build.add_argument(
        "--build",
        action="store_true",
        help="Run 'zig build compare' before execution.",
    )
    build.add_argument(
        "--no-build",
        action="store_true",
        help="Never build a missing comparison executable.",
    )
    parser.add_argument(
        "--cpu",
        type=int,
        default=None,
        help="Allowed CPU id for taskset (default: lowest CPU in process affinity).",
    )
    parser.add_argument(
        "--warmup",
        type=float,
        default=0.1,
        help="Google Benchmark warmup duration in seconds (default: 0.1).",
    )
    parser.add_argument(
        "--min_time",
        "--min-time",
        dest="min_time",
        type=float,
        default=0.2,
        help="Minimum Google Benchmark time in seconds (default: 0.2).",
    )
    parser.add_argument(
        "--repetitions",
        type=int,
        default=5,
        help="Google Benchmark repetitions (default: 5).",
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        help="Smoke settings: warmup=0.05, min_time=0.05, repetitions=1.",
    )
    parser.add_argument(
        "--out_dir",
        "--out-dir",
        dest="out_dir",
        type=pathlib.Path,
        default=None,
        help="Caller-selected artifact directory.",
    )
    parser.add_argument(
        "--filter",
        type=str,
        default=None,
        help="Google Benchmark regex filter; coverage is reported explicitly.",
    )
    parser.add_argument(
        "--audit_only",
        "--audit-only",
        dest="audit_only",
        action="store_true",
        help="Run and report the MPFR audit without timing benchmarks.",
    )
    return parser.parse_args()


def repo_root() -> pathlib.Path:
    root = pathlib.Path(__file__).resolve().parent.parent
    if (root / "build.zig").is_file() and (root / "bench").is_dir():
        return root
    return pathlib.Path.cwd().resolve()


def resolve_binary(root: pathlib.Path, requested: Optional[pathlib.Path]) -> pathlib.Path:
    if requested is not None:
        return requested.expanduser().resolve()
    return (root / "zig-out" / "bin" / "zmath-compare").resolve()


def run_capture(command: Sequence[str], cwd: pathlib.Path) -> str:
    try:
        result = subprocess.run(
            list(command), cwd=cwd, capture_output=True, text=True, check=False
        )
    except OSError:
        return "unavailable"
    if result.returncode != 0:
        return f"unavailable (exit {result.returncode})"
    return result.stdout.strip()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def select_cpu(requested: Optional[int]) -> Tuple[int, List[int]]:
    if not hasattr(os, "sched_getaffinity"):
        allowed = [0]
    else:
        allowed = sorted(os.sched_getaffinity(0))
    if not allowed:
        raise RunnerError("process affinity contains no CPUs")
    if requested is not None and requested not in allowed:
        raise RunnerError(
            f"CPU {requested} is not allowed by process affinity {allowed}"
        )
    return (requested if requested is not None else allowed[0]), allowed


def read_first_line(path: pathlib.Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip().splitlines()[0]
    except (OSError, IndexError):
        return "unknown"


def collect_metadata(
    root: pathlib.Path,
    binary: pathlib.Path,
    selected_cpu: int,
    allowed_cpus: Sequence[int],
    args: argparse.Namespace,
) -> Dict[str, Any]:
    cpu_model = "unknown"
    cpu_mhz = "unknown"
    try:
        blocks: List[Dict[str, str]] = []
        current: Dict[str, str] = {}
        for line in pathlib.Path("/proc/cpuinfo").read_text(encoding="utf-8").splitlines():
            if not line.strip():
                if current:
                    blocks.append(current)
                    current = {}
                continue
            key, separator, value = line.partition(":")
            if not separator:
                continue
            current[key.strip()] = value.strip()
        if current:
            blocks.append(current)
        selected_block = next(
            (block for block in blocks if block.get("processor") == str(selected_cpu)),
            {},
        )
        cpu_model = selected_block.get("model name", "unknown")
        cpu_mhz = selected_block.get("cpu MHz", "unknown")
    except OSError:
        pass

    governor = read_first_line(
        pathlib.Path(f"/sys/devices/system/cpu/cpu{selected_cpu}/cpufreq/scaling_governor")
    )
    no_turbo = read_first_line(pathlib.Path("/sys/devices/system/cpu/intel_pstate/no_turbo"))
    if no_turbo == "0":
        turbo = "enabled"
    elif no_turbo == "1":
        turbo = "disabled"
    elif no_turbo == "unknown":
        turbo = "unknown"
    else:
        turbo = f"state={no_turbo}"

    source_paths = (
        root / "bench" / "comparative.cpp",
        root / "bench" / "comparative.h",
        root / "bench" / "comparative_workloads.hpp",
        root / "bench" / "comparative_workloads.cpp",
        root / "bench" / "comparative_bridge.zig",
        root / "bench" / "comparative_libm.c",
        root / "bench" / "run_comparative.py",
        root / "build.zig",
        root / "build.zig.zon",
        root / "devenv.nix",
        root / "devenv.lock",
    )
    source_hashes: Dict[str, str] = {}
    for path in source_paths:
        if path.is_file():
            source_hashes[str(path.relative_to(root))] = sha256_file(path)

    metadata: Dict[str, Any] = {
        "schema": "zmath-comparative-metadata-v1",
        "timestamp_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "cpu_model": cpu_model,
        "cpu_mhz_at_collection": cpu_mhz,
        "kernel_release": platform.release(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "process_affinity": list(allowed_cpus),
        "selected_cpu": selected_cpu,
        "scaling_governor": governor,
        "turbo": turbo,
        # Build identity is read from the binary's accuracy JSON and Google
        # Benchmark context after execution. Do not infer or substitute it.
        "build": {
            "source": "binary accuracy.json build object and benchmark.json context",
        },
        "binary": {
            "path": str(binary),
            "sha256": sha256_file(binary) if binary.is_file() else "missing",
            "size_bytes": binary.stat().st_size if binary.is_file() else None,
        },
        "source_sha256": source_hashes,
        "jj_commit": run_capture(("jj", "log", "--no-graph", "-r", "@", "-T", "commit_id"), root),
        "jj_status": run_capture(("jj", "status", "--no-pager"), root),
        "runtime_jj_commit": run_capture(
            ("jj", "log", "--no-graph", "-r", "@", "-T", "commit_id"), root.parent / "zmath"
        ),
        "tool_versions": {
            "google_benchmark": run_capture(("pkg-config", "--modversion", "benchmark"), root),
            "mpfr": run_capture(("pkg-config", "--modversion", "mpfr"), root),
            "zig": run_capture(("zig", "version"), root),
        },
        "parameters": {
            "warmup_seconds": args.warmup,
            "min_time_seconds": args.min_time,
            "repetitions": args.repetitions,
            "quick": bool(args.quick),
            "filter": args.filter,
            "audit_only": bool(args.audit_only),
            "random_interleaving_requested": not args.audit_only,
            "timing_basis": "cpu_time_per_iteration_divided_by_1024",
        },
        "isolation_disclaimer": (
            "Shared host; not an isolated real-time machine. taskset pins one allowed CPU, "
            "but background load, frequency changes, turbo, and interrupts remain possible. "
            "This runner does not change governors or turbo controls."
        ),
    }
    return metadata


def write_json(path: pathlib.Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")

def read_json(path: pathlib.Path, description: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise RunnerError(f"cannot read {description} {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise RunnerError(f"{description} is not JSON: {error}") from error

def valid_glibc_origin_path(value: Any) -> bool:
    if not isinstance(value, str) or not value.startswith("/"):
        return False
    if ";" in value or "=" in value or "compiler_rt" in value or "compiler-rt" in value:
        return False
    name = pathlib.Path(value).name
    if name == "libm.so":
        return True
    if not name.startswith("libm.so."):
        return False
    components = name[len("libm.so.") :].split(".")
    return bool(components) and all(component.isdigit() for component in components)


def valid_coremath_origin_path(value: Any) -> bool:
    if not isinstance(value, str) or not value.startswith("/"):
        return False
    if ";" in value or "=" in value:
        return False
    return pathlib.Path(value).name == "libzmath-coremath.so"


def normalize_glibc_provenance(value: Any, description: str) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise RunnerError(f"{description} has no glibc provenance object")
    if set(value) != {"version", "origins"}:
        raise RunnerError(f"{description} glibc provenance fields are invalid")
    version = value.get("version")
    if not isinstance(version, str) or not version.strip():
        raise RunnerError(f"{description} glibc version is missing or empty")
    origins = value.get("origins")
    if not isinstance(origins, list) or len(origins) != GLIBC_ORIGIN_COUNT:
        raise RunnerError(
            f"{description} must contain exactly {GLIBC_ORIGIN_COUNT} glibc origins"
        )

    expected = [
        (operation, fmt)
        for operation in OPERATIONS
        for fmt in FORMATS
        if fmt not in GLIBC_UNSUPPORTED_FORMATS
    ]
    seen: Set[Tuple[str, str]] = set()
    normalized_origins: List[Dict[str, str]] = []
    for origin in origins:
        if not isinstance(origin, dict) or set(origin) != {"operation", "format", "path"}:
            raise RunnerError(f"{description} has a malformed glibc origin")
        operation = origin.get("operation")
        fmt = origin.get("format")
        path = origin.get("path")
        if (
            not isinstance(operation, str)
            or not isinstance(fmt, str)
            or not isinstance(path, str)
            or (operation, fmt) not in expected
        ):
            raise RunnerError(f"{description} has an invalid glibc origin identity")
        if (operation, fmt) in seen:
            raise RunnerError(f"{description} repeats glibc origin {(operation, fmt)}")
        if not valid_glibc_origin_path(path):
            raise RunnerError(f"{description} has an invalid glibc origin path: {path!r}")
        seen.add((operation, fmt))
        normalized_origins.append(
            {"operation": operation, "format": fmt, "path": path}
        )
    if set(seen) != set(expected):
        missing = sorted(set(expected) - seen)
        extra = sorted(set(seen) - set(expected))
        if missing:
            raise RunnerError(f"{description} is missing glibc origin {missing[0]}")
        raise RunnerError(f"{description} has an unexpected glibc origin {extra[0]}")
    normalized_origins.sort(
        key=lambda origin: (OPERATIONS.index(origin["operation"]), FORMATS.index(origin["format"]))
    )
    return {"version": version, "origins": normalized_origins}


def normalize_coremath_provenance(value: Any, description: str) -> Dict[str, Any]:
    required_fields = {"revision", "compiler", "flags", "source_path", "origins"}
    if not isinstance(value, dict):
        raise RunnerError(f"{description} has no CORE-MATH provenance object")
    if set(value) != required_fields:
        raise RunnerError(f"{description} CORE-MATH provenance fields are invalid")
    revision = value.get("revision")
    compiler = value.get("compiler")
    flags = value.get("flags")
    source_path = value.get("source_path")
    for field, field_value in (
        ("revision", revision),
        ("compiler", compiler),
        ("flags", flags),
        ("source_path", source_path),
    ):
        if not isinstance(field_value, str) or not field_value.strip():
            raise RunnerError(f"{description} CORE-MATH {field} is missing or empty")
    if revision != COREMATH_REVISION:
        raise RunnerError(
            f"{description} CORE-MATH revision is not pinned to {COREMATH_REVISION}"
        )
    if not pathlib.PurePosixPath(source_path).is_absolute():
        raise RunnerError(f"{description} CORE-MATH source_path is not absolute")

    origins = value.get("origins")
    if not isinstance(origins, list) or len(origins) != COREMATH_ORIGIN_COUNT:
        raise RunnerError(
            f"{description} must contain exactly {COREMATH_ORIGIN_COUNT} CORE-MATH origins"
        )
    expected = set(COREMATH_ORIGIN_KEYS)
    seen: Set[Tuple[str, str]] = set()
    normalized_origins: List[Dict[str, str]] = []
    for origin in origins:
        if not isinstance(origin, dict) or set(origin) != {"operation", "format", "path"}:
            raise RunnerError(f"{description} has a malformed CORE-MATH origin")
        operation = origin.get("operation")
        fmt = origin.get("format")
        path = origin.get("path")
        if (
            not isinstance(operation, str)
            or not isinstance(fmt, str)
            or not isinstance(path, str)
            or (operation, fmt) not in expected
        ):
            raise RunnerError(f"{description} has an invalid CORE-MATH origin identity")
        if (operation, fmt) in seen:
            raise RunnerError(f"{description} repeats CORE-MATH origin {(operation, fmt)}")
        if not valid_coremath_origin_path(path):
            raise RunnerError(f"{description} has an invalid CORE-MATH origin path: {path!r}")
        seen.add((operation, fmt))
        normalized_origins.append(
            {"operation": operation, "format": fmt, "path": path}
        )
    if seen != expected:
        missing = sorted(expected - seen)
        extra = sorted(seen - expected)
        if missing:
            raise RunnerError(f"{description} is missing CORE-MATH origin {missing[0]}")
        raise RunnerError(f"{description} has an unexpected CORE-MATH origin {extra[0]}")
    normalized_origins.sort(
        key=lambda origin: (OPERATIONS.index(origin["operation"]), FORMATS.index(origin["format"]))
    )
    return {
        "revision": revision,
        "compiler": compiler,
        "flags": flags,
        "source_path": source_path,
        "origins": normalized_origins,
    }


def load_accuracy_provenance(path: pathlib.Path) -> Dict[str, Any]:
    data = read_json(path, "accuracy output")
    value = data.get("glibc_provenance") if isinstance(data, dict) else None
    return normalize_glibc_provenance(value, "accuracy output")


def load_accuracy_coremath_provenance(path: pathlib.Path) -> Dict[str, Any]:
    data = read_json(path, "accuracy output")
    value = data.get("coremath_provenance") if isinstance(data, dict) else None
    return normalize_coremath_provenance(value, "accuracy output")


def decode_context_origins(encoded: Any, description: str) -> List[Dict[str, str]]:
    if not isinstance(encoded, str) or not encoded:
        raise RunnerError(f"{description} has no origins")
    origins: List[Dict[str, str]] = []
    for entry in encoded.split(";"):
        name, separator, path = entry.partition("=")
        parts = name.split("/")
        if not separator or len(parts) != 2 or not path:
            raise RunnerError(f"{description} has a malformed origin: {entry!r}")
        origins.append({"operation": parts[0], "format": parts[1], "path": path})
    return origins


def load_context_glibc_provenance(context: Dict[str, Any]) -> Dict[str, Any]:
    version = context.get("comparison.glibc_version")
    if not isinstance(version, str) or not version.strip():
        raise RunnerError("benchmark context has no GNU libc version")
    origins = decode_context_origins(
        context.get("comparison.glibc_origins"), "benchmark context glibc origins"
    )
    return normalize_glibc_provenance(
        {"version": version, "origins": origins}, "benchmark context"
    )


def load_context_coremath_provenance(context: Dict[str, Any]) -> Dict[str, Any]:
    fields = {
        "revision": context.get("comparison.coremath_revision"),
        "compiler": context.get("comparison.coremath_compiler"),
        "flags": context.get("comparison.coremath_flags"),
        "source_path": context.get("comparison.coremath_source"),
    }
    origins = decode_context_origins(
        context.get("comparison.coremath_origins"),
        "benchmark context CORE-MATH origins",
    )
    fields["origins"] = origins
    return normalize_coremath_provenance(fields, "benchmark context")


def reconcile_glibc_provenance(
    accuracy: Dict[str, Any], context: Dict[str, Any]
) -> None:
    if accuracy != context:
        raise RunnerError(
            "accuracy glibc provenance disagrees with benchmark context"
        )


def reconcile_coremath_provenance(
    accuracy: Dict[str, Any], context: Dict[str, Any]
) -> None:
    if accuracy != context:
        raise RunnerError(
            "accuracy CORE-MATH provenance disagrees with benchmark context"
        )


def _hash_elf_shared_object(
    path: pathlib.Path, binary_path: pathlib.Path, provider: str
) -> str:
    if path == binary_path:
        raise RunnerError(f"{provider} provider is the comparison executable: {path}")
    if not path.is_file():
        raise RunnerError(f"{provider} provider is not a regular file: {path}")
    try:
        with path.open("rb") as stream:
            header = stream.read(18)
    except OSError as error:
        raise RunnerError(f"cannot read {provider} provider {path}: {error}") from error
    if len(header) < 18 or header[:4] != b"\x7fELF" or header[5] not in (1, 2):
        raise RunnerError(f"{provider} provider is not an ELF shared object: {path}")
    byteorder = "little" if header[5] == 1 else "big"
    if int.from_bytes(header[16:18], byteorder=byteorder) != 3:
        raise RunnerError(f"{provider} provider is not an ELF shared object: {path}")
    try:
        return sha256_file(path)
    except OSError as error:
        raise RunnerError(f"cannot hash {provider} provider {path}: {error}") from error


def hash_glibc_provenance(
    provenance: Dict[str, Any], binary: pathlib.Path
) -> Dict[str, Any]:
    try:
        binary_path = binary.resolve(strict=True)
    except OSError as error:
        raise RunnerError(f"cannot resolve comparison binary for provenance: {error}") from error

    hashes: Dict[pathlib.Path, str] = {}
    records: List[Dict[str, str]] = []
    for origin in provenance["origins"]:
        path = pathlib.Path(origin["path"])
        try:
            resolved = path.resolve(strict=True)
        except OSError as error:
            raise RunnerError(
                f"cannot resolve glibc provider {path}: {error}"
            ) from error
        if resolved not in hashes:
            hashes[resolved] = _hash_elf_shared_object(resolved, binary_path, "glibc")
        records.append(
            {
                "operation": origin["operation"],
                "format": origin["format"],
                "path": origin["path"],
                "sha256": hashes[resolved],
            }
        )
    return {"version": provenance["version"], "origins": records}


def _configured_coremath_dso() -> pathlib.Path:
    configured = os.environ.get("ZMATH_COMPARE_COREMATH_PATH")
    if not configured:
        raise RunnerError("ZMATH_COMPARE_COREMATH_PATH is missing")
    path = pathlib.Path(configured).expanduser()
    if not path.is_absolute():
        raise RunnerError("ZMATH_COMPARE_COREMATH_PATH must be absolute")
    if path.name != "libzmath-coremath.so":
        raise RunnerError(
            "ZMATH_COMPARE_COREMATH_PATH must name libzmath-coremath.so"
        )
    try:
        return path.resolve(strict=True)
    except OSError as error:
        raise RunnerError(
            f"cannot resolve ZMATH_COMPARE_COREMATH_PATH {path}: {error}"
        ) from error


def hash_coremath_provenance(
    provenance: Dict[str, Any],
    binary: pathlib.Path,
    dso_path: Optional[pathlib.Path] = None,
) -> Dict[str, Any]:
    try:
        binary_path = binary.resolve(strict=True)
    except OSError as error:
        raise RunnerError(f"cannot resolve comparison binary for provenance: {error}") from error
    if dso_path is not None:
        if not dso_path.is_absolute():
            raise RunnerError("CORE-MATH DSO path must be absolute")
        try:
            expected_dso = dso_path.resolve(strict=True)
        except OSError as error:
            raise RunnerError(
                f"cannot resolve CORE-MATH DSO {dso_path}: {error}"
            ) from error
    else:
        expected_dso = _configured_coremath_dso()
    if expected_dso.name != "libzmath-coremath.so":
        raise RunnerError("CORE-MATH DSO must be libzmath-coremath.so")
    dso_hash = _hash_elf_shared_object(expected_dso, binary_path, "CORE-MATH")
    records: List[Dict[str, str]] = []
    for origin in provenance["origins"]:
        path = pathlib.Path(origin["path"])
        try:
            resolved = path.resolve(strict=True)
        except OSError as error:
            raise RunnerError(
                f"cannot resolve CORE-MATH provider {path}: {error}"
            ) from error
        if resolved != expected_dso:
            raise RunnerError(
                f"CORE-MATH provider does not match configured DSO: {path}"
            )
        records.append(
            {
                "operation": origin["operation"],
                "format": origin["format"],
                "path": origin["path"],
                "sha256": dso_hash,
            }
        )
    return {
        "revision": provenance["revision"],
        "compiler": provenance["compiler"],
        "flags": provenance["flags"],
        "source_path": provenance["source_path"],
        "dso_path": str(expected_dso),
        "dso_sha256": dso_hash,
        "origins": records,
    }


def validate_reference_source_evidence(
    coremath_provenance: Dict[str, Any],
) -> Dict[str, str]:
    core_env = os.environ.get("ZMATH_CORE_MATH_SOURCE_DIR")
    glibc_env = os.environ.get("ZMATH_GLIBC_SOURCE_DIR")
    if not core_env:
        raise RunnerError("ZMATH_CORE_MATH_SOURCE_DIR is missing")
    if not glibc_env:
        raise RunnerError("ZMATH_GLIBC_SOURCE_DIR is missing")
    paths: Dict[str, pathlib.Path] = {}
    for variable, value in (
        ("ZMATH_CORE_MATH_SOURCE_DIR", core_env),
        ("ZMATH_GLIBC_SOURCE_DIR", glibc_env),
    ):
        path = pathlib.Path(value).expanduser()
        if not path.is_absolute():
            raise RunnerError(f"{variable} must be absolute")
        try:
            resolved = path.resolve(strict=True)
        except OSError as error:
            raise RunnerError(f"cannot resolve {variable} {path}: {error}") from error
        if not resolved.is_dir():
            raise RunnerError(f"{variable} is not a source directory: {path}")
        paths[variable] = resolved
    try:
        declared_core = pathlib.Path(coremath_provenance["source_path"]).resolve(strict=True)
    except OSError as error:
        raise RunnerError(
            f"cannot resolve CORE-MATH metadata source path "
            f"{coremath_provenance['source_path']}: {error}"
        ) from error
    if declared_core != paths["ZMATH_CORE_MATH_SOURCE_DIR"]:
        raise RunnerError(
            "CORE-MATH metadata source_path disagrees with "
            "ZMATH_CORE_MATH_SOURCE_DIR"
        )
    return {
        "coremath_source_path": str(declared_core),
        "glibc_source_path": str(paths["ZMATH_GLIBC_SOURCE_DIR"]),
    }


def load_binary_build(path: pathlib.Path) -> Dict[str, str]:
    data = read_json(path, "accuracy output")
    build = data.get("build") if isinstance(data, dict) else None
    if not isinstance(build, dict):
        raise RunnerError("accuracy output has no binary-produced build object")
    required = ("mode", "target", "compiler", "compiler_version", "cxx_flags")
    normalized: Dict[str, str] = {}
    for field in required:
        value = build.get(field)
        if not isinstance(value, str) or not value:
            raise RunnerError(f"binary build field {field!r} is missing or empty")
        normalized[field] = value
    return normalized


def load_benchmark_context(path: pathlib.Path) -> Dict[str, Any]:
    data = read_json(path, "benchmark output")
    context = data.get("context") if isinstance(data, dict) else None
    if not isinstance(context, dict):
        raise RunnerError("benchmark output has no Google Benchmark context")
    return context


def reconcile_build(build: Dict[str, str], context: Dict[str, Any]) -> None:
    context_fields = {
        "mode": "comparison.mode",
        "target": "comparison.target",
        "compiler": "comparison.compiler",
        "compiler_version": "comparison.compiler_version",
        "cxx_flags": "comparison.cxx_flags",
    }
    for field, context_key in context_fields.items():
        value = context.get(context_key)
        if value is None or str(value) != build[field]:
            raise RunnerError(
                f"binary accuracy build field {field!r} disagrees with benchmark context {context_key!r}"
            )


def load_context_input_digests(context: Dict[str, Any]) -> Dict[TupleKey, str]:
    batch_size = context.get("comparison.batch_size")
    if batch_size != str(BATCH_SIZE):
        raise RunnerError(
            f"benchmark context comparison.batch_size must be {BATCH_SIZE}"
        )
    encoded = context.get("comparison.input_digests")
    if not isinstance(encoded, str) or not encoded:
        raise RunnerError("benchmark context has no comparison.input_digests")

    expected_keys = set(matrix_keys())
    digests: Dict[TupleKey, str] = {}
    for entry in encoded.split(";"):
        name, separator, digest = entry.partition("=")
        if not separator or not name or not valid_input_digest(digest):
            raise RunnerError(f"benchmark context has a malformed input digest: {entry!r}")
        parts = name.split("/")
        if len(parts) != 3:
            raise RunnerError(f"benchmark context has an invalid digest key: {name!r}")
        key = (parts[0], parts[1], parts[2])
        if key not in expected_keys:
            raise RunnerError(f"benchmark context has an unknown digest key: {name!r}")
        if key in digests:
            raise RunnerError(f"benchmark context repeats input digest key: {name!r}")
        digests[key] = digest

    missing = sorted(expected_keys - set(digests))
    if missing:
        raise RunnerError(f"benchmark context is missing input digest {missing[0]}")
    extra = sorted(set(digests) - expected_keys)
    if extra:
        raise RunnerError(f"benchmark context has an unexpected input digest {extra[0]}")
    return digests


def validate_benchmark_context(
    accuracy: Dict[Key, Dict[str, Any]], context: Dict[str, Any]
) -> None:
    context_digests = load_context_input_digests(context)
    for operation, fmt, distribution in matrix_keys():
        key = (operation, fmt, distribution)
        accuracy_digests = {
            accuracy[(operation, fmt, distribution, provider)]["input_hash"]
            for provider in PROVIDERS
        }
        if len(accuracy_digests) != 1:
            raise RunnerError(
                f"accuracy input digest differs across providers for {key}"
            )
        expected = next(iter(accuracy_digests))
        if context_digests[key] != expected:
            raise RunnerError(
                f"benchmark input digest disagrees with accuracy records for {key}"
            )


def execute(
    root: pathlib.Path,
    binary: pathlib.Path,
    selected_cpu: int,
    args: argparse.Namespace,
    accuracy_path: pathlib.Path,
    benchmark_path: pathlib.Path,
    stdout_path: pathlib.Path,
    stderr_path: pathlib.Path,
) -> Dict[str, Any]:
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise RunnerError(f"comparison binary is not executable: {binary}")
    if shutil.which("taskset") is None:
        raise RunnerError("taskset is required but was not found")

    command: List[str] = [
        "taskset",
        "-c",
        str(selected_cpu),
        str(binary),
        f"--accuracy_out={accuracy_path}",
    ]
    if args.audit_only:
        command.append("--audit_only")
    else:
        command.extend(
            (
                f"--benchmark_out={benchmark_path}",
                "--benchmark_out_format=json",
                f"--benchmark_min_warmup_time={args.warmup}",
                f"--benchmark_min_time={args.min_time}s",
                f"--benchmark_repetitions={args.repetitions}",
                "--benchmark_report_aggregates_only=false",
                "--benchmark_display_aggregates_only=false",
            )
        )
        if args.filter is not None:
            command.append(f"--benchmark_filter={args.filter}")
        command.append("--benchmark_enable_random_interleaving=true")

    result = subprocess.run(command, cwd=root, capture_output=True, text=True, check=False)
    stdout_path.write_text(result.stdout, encoding="utf-8")
    stderr_path.write_text(result.stderr, encoding="utf-8")
    if result.returncode != 0:
        raise RunnerError(
            "benchmark process failed; random interleaving is required and no fallback is used "
            f"(exit {result.returncode}); see {stderr_path}"
        )
    return {
        "command": command,
        "returncode": result.returncode,
        "random_interleaving": not args.audit_only,
        "timing_basis": "cpu_time_per_iteration_divided_by_1024",
    }


def valid_input_digest(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 16
        and all(character in "0123456789abcdef" for character in value)
    )

def matrix_keys() -> Iterable[TupleKey]:
    for operation in OPERATIONS:
        for fmt in FORMATS:
            for distribution in DISTRIBUTIONS:
                yield operation, fmt, distribution


def full_keys() -> Iterable[Key]:
    for operation, fmt, distribution in matrix_keys():
        for provider in PROVIDERS:
            yield operation, fmt, distribution, provider


def numeric_field(value: Any, name: str, key: Key) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise RunnerError(f"accuracy field {name} is invalid for {key}: {value!r}")
    return value


def load_accuracy(path: pathlib.Path) -> Dict[Key, Dict[str, Any]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise RunnerError(f"cannot read accuracy output {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise RunnerError(f"accuracy output is not JSON: {error}") from error
    if not isinstance(data, dict) or data.get("schema") != "zmath-comparative-accuracy-v1":
        raise RunnerError("accuracy output has an unexpected schema")
    reference = data.get("reference")
    if not isinstance(reference, dict) or reference.get("kind") != "MPFR":
        raise RunnerError("accuracy output does not identify MPFR reference")
    if reference.get("precision_bits") != 512 or reference.get("rounding") != "RNE":
        raise RunnerError("accuracy output must use MPFR-512 round-to-nearest-even")
    if reference.get("formal_correct_rounding_proof") is not False:
        raise RunnerError("accuracy output must state that this is not a formal proof")
    if tuple(data.get("providers", ())) != PROVIDERS:
        raise RunnerError("accuracy output provider list is incomplete or reordered")
    normalize_glibc_provenance(
        data.get("glibc_provenance"), "accuracy output"
    )
    normalize_coremath_provenance(
        data.get("coremath_provenance"), "accuracy output"
    )
    records = data.get("records")
    if not isinstance(records, list):
        raise RunnerError("accuracy output has no records list")

    indexed: Dict[Key, Dict[str, Any]] = {}
    for record in records:
        if not isinstance(record, dict):
            raise RunnerError("accuracy record is not an object")
        key_values = tuple(record.get(name) for name in ("operation", "format", "distribution", "provider"))
        if any(not isinstance(value, str) for value in key_values):
            raise RunnerError(f"accuracy record has malformed identity: {record!r}")
        key = key_values  # type: ignore[assignment]
        if key not in set(full_keys()):
            raise RunnerError(f"accuracy record is outside the comparison matrix: {key}")
        if not valid_input_digest(record.get("input_hash")):
            raise RunnerError(f"accuracy record has an invalid input_hash for {key}")
        if key in indexed:
            raise RunnerError(f"duplicate accuracy record: {key}")
        audit = record.get("audit")
        available = record.get("available")
        if not isinstance(available, bool):
            raise RunnerError(f"accuracy availability is not boolean for {key}")
        expected_status = "audited" if available else "unsupported"
        if record.get("status") != expected_status:
            raise RunnerError(f"accuracy status is invalid for {key}")
        if available:
            if not isinstance(audit, dict):
                raise RunnerError(f"available row has no audit for {key}")
            for field in ("samples", "finite_compared", "max_ulp", "nonfinite_mismatches", "signed_zero_mismatches"):
                numeric_field(audit.get(field), field, key)
            if audit["samples"] != BATCH_SIZE:
                raise RunnerError(f"accuracy sample count is not {BATCH_SIZE} for {key}")
        elif audit is not None:
            raise RunnerError(f"unsupported row has a non-null audit for {key}")
        indexed[key] = record

    missing = sorted(set(full_keys()) - set(indexed))
    if missing:
        raise RunnerError(f"accuracy output is incomplete; missing {missing[0]} and more")
    for operation, fmt, distribution in matrix_keys():
        digest_values = {
            indexed[(operation, fmt, distribution, provider)].get("input_hash")
            for provider in PROVIDERS
        }
        if len(digest_values) != 1 or not next(iter(digest_values), ""):
            raise RunnerError(
                f"input digest differs across providers for {(operation, fmt, distribution)}"
            )
    for provider in REQUIRED_PROVIDERS:
        unavailable = [
            (operation, fmt)
            for operation, fmt, distribution in matrix_keys()
            if not indexed[(operation, fmt, distribution, provider)].get("available")
        ]
        if unavailable:
            raise RunnerError(f"required provider {provider} is unavailable: {unavailable[0]}")
    for operation, fmt, distribution in matrix_keys():
        supported_operations = (
            ZIG_F16_OPERATIONS if fmt == "f16" else ZIG_F32_F64_OPERATIONS
        )
        expected = operation in supported_operations
        if indexed[(operation, fmt, distribution, "zig")]["available"] != expected:
            raise RunnerError(
                f"Zig availability differs from the supported matrix: "
                f"{(operation, fmt, distribution)}"
            )
    glibc_half_available = [
        (operation, fmt, distribution)
        for operation, fmt, distribution in matrix_keys()
        if fmt in GLIBC_UNSUPPORTED_FORMATS
        and indexed[(operation, fmt, distribution, "glibc")].get("available")
    ]
    glibc_missing = [
        (operation, fmt)
        for operation, fmt, distribution in matrix_keys()
        if fmt not in GLIBC_UNSUPPORTED_FORMATS
        and not indexed[(operation, fmt, distribution, "glibc")].get("available")
    ]
    if glibc_missing:
        raise RunnerError(f"required glibc provider is unavailable: {glibc_missing[0]}")
    if glibc_half_available:
        raise RunnerError(
            f"glibc unexpectedly provides binary16 rows: {glibc_half_available[0]}"
        )
    for operation, fmt in COREMATH_ORIGIN_KEYS:
        unavailable = [
            distribution
            for distribution in DISTRIBUTIONS
            if not indexed[(operation, fmt, distribution, "coremath")].get("available")
        ]
        if unavailable:
            raise RunnerError(
                f"required CORE-MATH provider is unavailable: {(operation, fmt)}"
            )
    for operation, fmt in COREMATH_UNSUPPORTED_KEYS:
        available = [
            distribution
            for distribution in DISTRIBUTIONS
            if indexed[(operation, fmt, distribution, "coremath")].get("available")
        ]
        if available:
            raise RunnerError(
                f"CORE-MATH unexpectedly provides an unsupported row: {(operation, fmt)}"
            )
    return indexed


def parse_name(name: str) -> Optional[Key]:
    parts = name.split("/")
    if len(parts) != 4:
        return None
    provider, operation, fmt, distribution = parts
    key = (operation, fmt, distribution, provider)
    return key if key in set(full_keys()) else None


def list_benchmark_names(
    root: pathlib.Path,
    binary: pathlib.Path,
    selected_cpu: int,
    filter_pattern: Optional[str],
) -> Set[str]:
    if shutil.which("taskset") is None:
        raise RunnerError("taskset is required but was not found")
    command: List[str] = [
        "taskset",
        "-c",
        str(selected_cpu),
        str(binary),
        "--benchmark_list_tests=true",
    ]
    if filter_pattern is not None:
        command.append(f"--benchmark_filter={filter_pattern}")
    try:
        result = subprocess.run(
            command, cwd=root, capture_output=True, text=True, check=False
        )
    except OSError as error:
        raise RunnerError(f"benchmark list command failed: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.strip()
        suffix = f": {detail}" if detail else ""
        raise RunnerError(
            f"benchmark list command failed with exit {result.returncode}{suffix}"
        )

    names: Set[str] = set()
    for raw_line in result.stdout.splitlines():
        name = raw_line.strip()
        if not name:
            continue
        if parse_name(name) is None:
            raise RunnerError(f"benchmark list returned an invalid name: {name!r}")
        if name in names:
            raise RunnerError(f"benchmark list returned a duplicate name: {name!r}")
        names.add(name)
    if not names:
        detail = result.stderr.strip()
        suffix = f": {detail}" if detail else ""
        raise RunnerError(f"benchmark list returned no selected benchmarks{suffix}")
    return names


def cpu_time_ns(value: Any, unit: Any) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RunnerError(f"benchmark cpu_time is not numeric: {value!r}")
    if not math.isfinite(float(value)) or float(value) < 0:
        raise RunnerError(f"benchmark cpu_time is invalid: {value!r}")
    factors = {"ns": 1.0, "us": 1_000.0, "ms": 1_000_000.0, "s": 1_000_000_000.0}
    if unit not in factors:
        raise RunnerError(f"unsupported benchmark time unit: {unit!r}")
    return float(value) * factors[unit]


def load_timings(path: pathlib.Path, requested_repetitions: int) -> Dict[Key, List[float]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise RunnerError(f"cannot read benchmark output {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise RunnerError(f"benchmark output is not JSON: {error}") from error
    if not isinstance(data, dict) or not isinstance(data.get("benchmarks"), list):
        raise RunnerError("benchmark output has no benchmarks list")

    timings: Dict[Key, List[float]] = {}
    repetition_indices: Dict[Key, Set[int]] = {}
    for row in data["benchmarks"]:
        if not isinstance(row, dict):
            raise RunnerError("benchmark row is not an object")
        run_type = row.get("run_type")
        if run_type == "aggregate":
            aggregate_error = row.get("error_occurred", False)
            if aggregate_error:
                raise RunnerError(f"benchmark row reported an error: {row.get('name')}")
            continue
        if run_type != "iteration":
            raise RunnerError(f"benchmark row has an invalid run_type: {run_type!r}")
        error_occurred = row.get("error_occurred", False)
        if not isinstance(error_occurred, bool):
            raise RunnerError(f"benchmark row has invalid error_occurred: {row.get('name')!r}")
        if error_occurred:
            raise RunnerError(f"benchmark row reported an error: {row.get('name')}")

        name = row.get("name")
        if not isinstance(name, str):
            raise RunnerError(f"benchmark row has an invalid matrix name: {name!r}")
        key = parse_name(name)
        if key is None:
            raise RunnerError(f"benchmark row has an invalid matrix name: {name!r}")

        iterations = row.get("iterations")
        if isinstance(iterations, bool) or not isinstance(iterations, int) or iterations <= 0:
            raise RunnerError(f"benchmark row has invalid iterations: {name!r}")
        row_repetitions = row.get("repetitions")
        if (
            isinstance(row_repetitions, bool)
            or not isinstance(row_repetitions, int)
            or row_repetitions != requested_repetitions
        ):
            raise RunnerError(
                f"benchmark row repetitions={row_repetitions!r}, "
                f"expected {requested_repetitions}: {name!r}"
            )

        repetition_index = row.get("repetition_index")
        if (
            isinstance(repetition_index, bool)
            or not isinstance(repetition_index, int)
            or repetition_index < 0
            or repetition_index >= requested_repetitions
        ):
            raise RunnerError(f"benchmark row has invalid repetition_index: {name!r}")
        indices = repetition_indices.setdefault(key, set())
        if repetition_index in indices:
            raise RunnerError(f"duplicate repetition_index for {key}: {repetition_index}")
        indices.add(repetition_index)

        # The C++ harness uses default Google Benchmark CPU timing. Keep one
        # basis for every row: cpu_time per iteration divided by 1024 calls.
        ns_per_call = cpu_time_ns(row.get("cpu_time"), row.get("time_unit")) / BATCH_SIZE
        if not math.isfinite(ns_per_call) or ns_per_call < 0:
            raise RunnerError(f"benchmark row has invalid ns/call: {name!r}")
        timings.setdefault(key, []).append(ns_per_call)
    if not timings:
        raise RunnerError("benchmark output contains no iteration rows")

    expected_indices = set(range(requested_repetitions))
    for key, samples in timings.items():
        if len(samples) != requested_repetitions:
            raise RunnerError(
                f"benchmark row {key} has {len(samples)} repetitions, "
                f"expected {requested_repetitions}"
            )
        indices = repetition_indices.get(key)
        if indices != expected_indices:
            raise RunnerError(
                f"benchmark row {key} has repetition indices {sorted(indices or set())}, "
                f"expected {sorted(expected_indices)}"
            )
    return timings


def expected_timing_keys(
    accuracy: Dict[Key, Dict[str, Any]], selected_names: Set[str]
) -> Set[Key]:
    expected: Set[Key] = set()
    for name in selected_names:
        key = parse_name(name)
        if key is None:
            raise RunnerError(f"benchmark selection has an invalid name: {name!r}")
        if not accuracy[key].get("available"):
            raise RunnerError(
                f"benchmark selection includes unavailable provider row: {name!r}"
            )
        expected.add(key)
    return expected


def validate_timing_coverage(
    timings: Dict[Key, List[float]],
    accuracy: Dict[Key, Dict[str, Any]],
    selected_names: Set[str],
) -> Tuple[Set[Key], Set[Key]]:
    expected = expected_timing_keys(accuracy, selected_names)
    observed = set(timings)
    missing = sorted(expected - observed)
    if missing:
        raise RunnerError(f"timing output is incomplete; missing {missing[0]} and more")
    unexpected = sorted(observed - expected)
    if unexpected:
        raise RunnerError(f"timing output contains rows excluded by filter: {unexpected[0]}")
    return expected, observed




def report_lines(
    accuracy: Dict[Key, Dict[str, Any]],
    timings: Optional[Dict[Key, List[float]]],
    filter_pattern: Optional[str],
    audit_only: bool,
    selected_names: Optional[Set[str]] = None,
) -> List[str]:
    lines: List[str] = []
    lines.append("=" * 150)
    lines.append("ZMATH COMPARATIVE REPORT — SCALAR THROUGHPUT AND MPFR ACCURACY AUDIT")
    lines.append("Reference: MPFR 512-bit RNE; numerical audit evidence, not a formal correctly-rounded proof")
    lines.append("Provider calls use one opaque C function pointer and a 1024-call batch for every row")
    lines.append("Timing basis: Google Benchmark CPU time per iteration divided by 1024 calls")
    lines.append("=" * 150)
    if audit_only:
        lines.append("Mode: audit-only (no timing benchmarks registered)")
    elif timings is not None:
        if selected_names is None:
            raise RunnerError("timing report has no framework-selected benchmark names")
        expected, observed = validate_timing_coverage(timings, accuracy, selected_names)
        all_available = sum(1 for key in full_keys() if accuracy[key].get("available"))
        lines.append(
            f"Timing coverage: {len(observed)}/{len(expected)} selected rows; "
            f"{all_available} available rows in audit matrix"
        )
    if filter_pattern:
        lines.append(f"Filter: {filter_pattern!r}; excluded rows are not treated as failures")
    lines.append("")
    if audit_only:
        header = f"{'op':<7} {'fmt':<5} {'dist':<8} {'provider':<10} {'available':<12} {'max_ulp':<9} {'nonfinite':<10} {'signed_zero':<12} {'status':<14}"
    else:
        header = f"{'op':<7} {'fmt':<5} {'dist':<8} {'provider':<10} {'median_ns':<12} {'min..max_ns':<25} {'stdev_ns':<12} {'CV%':<8} {'vs_glibc':<11} {'vs_coremath':<13} {'max_ulp':<8} {'nonfinite':<10} {'signed_zero':<12} {'status':<16}"
    lines.append(header)
    lines.append("-" * len(header))

    for operation, fmt, distribution in matrix_keys():
        glibc_key = (operation, fmt, distribution, "glibc")
        coremath_key = (operation, fmt, distribution, "coremath")
        glibc_median: Optional[float] = None
        coremath_median: Optional[float] = None
        if timings is not None and glibc_key in timings:
            glibc_median = statistics.median(timings[glibc_key])
        if timings is not None and coremath_key in timings:
            coremath_median = statistics.median(timings[coremath_key])
        for provider in PROVIDERS:
            key = (operation, fmt, distribution, provider)
            record = accuracy[key]
            available = bool(record.get("available"))
            audit = record.get("audit") if isinstance(record.get("audit"), dict) else {}
            if not available:
                lines.append(
                    f"{operation:<7} {fmt:<5} {distribution:<8} {provider:<10} "
                    + (
                        f"{'no':<12} {'-':<9} {'-':<10} {'-':<12} {'UNSUPPORTED':<14}"
                        if audit_only
                        else f"{'-':<12} {'-':<25} {'-':<12} {'-':<8} {'-':<11} {'-':<13} {'-':<8} {'-':<10} {'-':<12} {'UNSUPPORTED':<16}"
                    )
                )
                continue

            max_ulp = audit.get("max_ulp", "-")
            nonfinite = audit.get("nonfinite_mismatches", "-")
            signed_zero = audit.get("signed_zero_mismatches", "-")
            if audit_only:
                lines.append(
                    f"{operation:<7} {fmt:<5} {distribution:<8} {provider:<10} "
                    f"{'yes':<12} {str(max_ulp):<9} {str(nonfinite):<10} {str(signed_zero):<12} {'AUDITED':<14}"
                )
                continue

            assert timings is not None
            if key not in timings:
                lines.append(
                    f"{operation:<7} {fmt:<5} {distribution:<8} {provider:<10} "
                    f"{'-':<12} {'-':<25} {'-':<12} {'-':<8} {'-':<11} {'-':<13} "
                    f"{str(max_ulp):<8} {str(nonfinite):<10} {str(signed_zero):<12} {'FILTERED':<16}"
                )
                continue
            samples = timings[key]
            median = statistics.median(samples)
            low, high = min(samples), max(samples)
            stdev = statistics.stdev(samples) if len(samples) > 1 else 0.0
            mean = statistics.fmean(samples)
            cv = 100.0 * stdev / mean if mean > 0 else 0.0
            glibc_ratio = median / glibc_median if glibc_median and glibc_median > 0 else None
            coremath_ratio = median / coremath_median if coremath_median and coremath_median > 0 else None
            glibc_ratio_text = f"{glibc_ratio:.3f}x" if glibc_ratio is not None else "N/A"
            coremath_ratio_text = f"{coremath_ratio:.3f}x" if coremath_ratio is not None else "N/A"
            status = "MISMATCH" if any(
                isinstance(value, int) and value > 0
                for value in (max_ulp, nonfinite, signed_zero)
            ) else "OK"
            lines.append(
                f"{operation:<7} {fmt:<5} {distribution:<8} {provider:<10} "
                f"{median:<12.4f} {low:.4f}..{high:.4f}{'':<8} {stdev:<12.4f} "
                f"{cv:<8.2f} {glibc_ratio_text:<11} {coremath_ratio_text:<13} "
                f"{str(max_ulp):<8} {str(nonfinite):<10} {str(signed_zero):<12} {status:<16}"
            )
    lines.append("=" * 170)
    lines.append("Ratios are provider median ns/call divided by the matching glibc or CORE-MATH median; lower than 1.000x is faster.")
    lines.append("Unsupported reference rows have no timing baseline and are never substituted with another provider.")
    lines.append("Throughput is scalar batch throughput only; it is not a latency or SIMD/vectorization claim.")
    lines.append("Accuracy mismatch counts are visible status data. NaN payload differences are ignored by the audit contract.")
    lines.append("The oracle preserves signaling-NaN precedence and rsqrt zero signs. Reference-provider special-value policies can still differ.")
    lines.append("")
    return lines


def validate_args(args: argparse.Namespace) -> None:
    if (
        not math.isfinite(args.warmup)
        or not math.isfinite(args.min_time)
        or args.warmup < 0
        or args.min_time <= 0
    ):
        raise RunnerError("warmup and min_time must be finite; warmup must be non-negative and min_time positive")
    if args.repetitions <= 0:
        raise RunnerError("repetitions must be positive")
    if args.quick:
        args.warmup = 0.05
        args.min_time = 0.05
        args.repetitions = 1


def main() -> int:
    args = parse_args()
    try:
        validate_args(args)
        root = repo_root()
        binary = resolve_binary(root, args.binary)
        if args.build or (not binary.is_file() and not args.no_build):
            command = ("zig", "build", "compare")
            result = subprocess.run(command, cwd=root, check=False)
            if result.returncode != 0:
                raise RunnerError(f"{' '.join(command)} failed with {result.returncode}")
            binary = resolve_binary(root, args.binary)
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise RunnerError(f"comparison binary is not executable: {binary}")

        selected_cpu, allowed_cpus = select_cpu(args.cpu)
        selected_names = (
            None
            if args.audit_only
            else list_benchmark_names(root, binary, selected_cpu, args.filter)
        )
        if args.out_dir is None:
            timestamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
            out_dir = root / "bench" / "results" / f"run_{timestamp}"
            suffix = 1
            while out_dir.exists():
                out_dir = root / "bench" / "results" / f"run_{timestamp}_{suffix:02d}"
                suffix += 1
        else:
            out_dir = args.out_dir.expanduser().resolve()
            if out_dir.exists():
                raise RunnerError(
                    f"output directory already exists; choose a new directory to preserve evidence: {out_dir}"
                )
        out_dir.mkdir(parents=True)
        accuracy_path = out_dir / "accuracy.json"
        benchmark_path = out_dir / "benchmark.json"
        metadata_path = out_dir / "metadata.json"
        report_path = out_dir / "report.txt"
        stdout_path = out_dir / "process.stdout.txt"
        stderr_path = out_dir / "process.stderr.txt"

        metadata = collect_metadata(root, binary, selected_cpu, allowed_cpus, args)
        metadata["artifacts"] = {
            "accuracy": str(accuracy_path),
            "benchmark": None if args.audit_only else str(benchmark_path),
            "metadata": str(metadata_path),
            "report": str(report_path),
            "stdout": str(stdout_path),
            "stderr": str(stderr_path),
        }
        write_json(metadata_path, metadata)
        execution = execute(
            root,
            binary,
            selected_cpu,
            args,
            accuracy_path,
            benchmark_path,
            stdout_path,
            stderr_path,
        )
        metadata["execution"] = execution
        write_json(metadata_path, metadata)

        accuracy = load_accuracy(accuracy_path)
        accuracy_provenance = load_accuracy_provenance(accuracy_path)
        coremath_provenance = load_accuracy_coremath_provenance(accuracy_path)
        metadata["glibc_provenance"] = hash_glibc_provenance(
            accuracy_provenance, binary
        )
        metadata["coremath_provenance"] = hash_coremath_provenance(
            coremath_provenance, binary
        )
        source_evidence = validate_reference_source_evidence(coremath_provenance)
        metadata["reference_sources"] = source_evidence
        metadata["glibc_source_path"] = source_evidence["glibc_source_path"]
        metadata["coremath_source_path"] = source_evidence["coremath_source_path"]
        binary_build = load_binary_build(accuracy_path)
        metadata["build"] = binary_build
        if args.audit_only:
            metadata["build_source"] = "accuracy.json binary-produced build object"
            timings = None
        else:
            benchmark_context = load_benchmark_context(benchmark_path)
            reconcile_build(binary_build, benchmark_context)
            validate_benchmark_context(accuracy, benchmark_context)
            context_provenance = load_context_glibc_provenance(benchmark_context)
            reconcile_glibc_provenance(accuracy_provenance, context_provenance)
            context_coremath_provenance = load_context_coremath_provenance(
                benchmark_context
            )
            reconcile_coremath_provenance(
                coremath_provenance, context_coremath_provenance
            )
            metadata["benchmark_context"] = benchmark_context
            metadata["build_source"] = "accuracy.json and benchmark.json binary-produced fields"
            timings = load_timings(benchmark_path, args.repetitions)
        write_json(metadata_path, metadata)
        if args.audit_only:
            lines = report_lines(accuracy, None, args.filter, True)
        else:
            assert timings is not None
            assert selected_names is not None
            lines = report_lines(accuracy, timings, args.filter, False, selected_names)
        report = "\n".join(lines) + "\n"
        report_path.write_text(report, encoding="utf-8")
        print(report, end="")
        print(f"Artifacts: {out_dir}")
        return 0
    except RunnerError as error:
        print(f"run_comparative.py: {error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"run_comparative.py: filesystem error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
