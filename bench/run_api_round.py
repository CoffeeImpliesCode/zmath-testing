#!/usr/bin/env python3
"""Run and report one zmath API benchmarking round.

The runner pairs a frozen baseline executable against a candidate executable,
both built from the same harness by `zig build bench-api-round`, optionally
with a consumer manifest bound to the frozen runtime for the baseline.

Four properties are not negotiable, because a round that breaks any of them
reports a number that does not mean what it appears to mean.

**The plan is proved before anything is spent.** Both executables are listed
with `--list`, which performs zero numerical execution, and the two plans must
agree field for field: same protocol version, same harness digest, same case
names in the same order, same per-case call counts, same f32 charge plan. Only
then is the accepted-binary32-kernel budget computed, and only then is anything
measured. `--plan-only` stops there: the two zero-math listings above are how
the plan was proved and are the only processes it starts, so it runs no
measurement, no profiler, and writes no receipt, no result and no ledger row.

**The budget is reserved before launching, and never refunded.** The whole
planned consumption -- every measured case on every pair and on both sides,
plus every declared profiler invocation for the bundles actually profiled --
is appended to one persistent `--ledger` file and fsynced before the first
process starts. The reservation takes an exclusive lock, re-reads the durable
rows under it and checks the whole batch before it appends anything, so two
concurrent rounds cannot both spend the same allowance. A run that then
crashes, a run that produces the wrong rows, and a round that is abandoned
half way have all already been paid for. The cap is per canonical kernel
symbol, `--cap` may only lower the approved ceiling and never raise it, and
exceeding the cap is a hard failure before launch, not a warning afterwards.

**Errors are never silently skipped.** A nonzero exit, a missing row, a
duplicate row, an unexpected row, a malformed or unknown record, a build line
that is not the one that was listed, a summary that does not add up, a changed
call count or a changed checksum fails the round. There is no retry, no
fallback and no "skip the case".

**Both sides run the same work.** Every case is measured on every pair on both
executables, alternating AB then BA so neither side owns the warm state, and
the whole selection runs in one process per side per pair. Nothing here adapts
a loop trip count to a measurement.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
import pathlib
import shutil
import statistics
import subprocess
import sys
from typing import Any, Dict, Iterator, List, Mapping, Optional, Sequence, Tuple


PROTOCOL_VERSION = 1
#: Global ceiling on accepted binary32 kernel evaluations per canonical kernel
#: symbol, counted across every consumer, version, lane, repetition, profiler
#: invocation and failed attempt.
CANONICAL_CAP = 1_048_576
#: The runner pins one Unix host and serialises reservations with an advisory
#: lock, so the ledger is guarded by a sibling lock file it never truncates.
LEDGER_LOCK_SUFFIX = ".lock"
BUNDLES: Tuple[str, ...] = (
    "leaf",
    "lanes",
    "values",
    "aggregates",
    "geometry",
    "algebra",
)
NAMESPACES: Tuple[str, ...] = (
    "root",
    "ieee",
    "scalar",
    "vector",
    "complex",
    "quaternion",
    "matrix",
    "linalg",
    "geometry",
    "algebra",
)
SIDES: Tuple[str, ...] = ("baseline", "candidate")
DEFAULT_PAIRS = 9
DEFAULT_PERF_EVENTS = (
    "cycles,instructions,branches,branch-misses,"
    "cache-references,cache-misses"
)
#: A change smaller than this is inside the noise a shared host produces, so it
#: is not evidence either way.
PRACTICAL_THRESHOLD = 0.02

CaseKey = str


class RunnerError(RuntimeError):
    """A user-facing run or report error."""


# ---------------------------------------------------------------------------
# Ledger
# ---------------------------------------------------------------------------


class Ledger:
    """Append-only record of consumed accepted-binary32-kernel evaluations.

    A reservation is durable before the process it pays for is launched, and
    there is no refund path: `consumed` only ever grows, including across
    separate invocations of this runner. Two processes reserving against one
    file are serialised by an advisory lock on a sibling lock file, and the
    durable rows are re-read under that lock, so a stale in-memory total can
    never authorise a second spend of the same allowance.
    """

    def __init__(self, path: pathlib.Path, cap: int = CANONICAL_CAP) -> None:
        if not isinstance(cap, int) or isinstance(cap, bool) or cap <= 0:
            raise RunnerError(f"canonical cap must be a positive integer, got {cap!r}")
        if cap > CANONICAL_CAP:
            raise RunnerError(
                f"canonical cap {cap} exceeds the approved ceiling {CANONICAL_CAP}"
            )
        self.path = pathlib.Path(path)
        self.lock_path = self.path.with_name(self.path.name + LEDGER_LOCK_SUFFIX)
        self.cap = cap
        self.records = self._load()

    def _load(self) -> List[Dict[str, Any]]:
        if not self.path.exists():
            return []
        records: List[Dict[str, Any]] = []
        for number, line in enumerate(
            self.path.read_text(encoding="utf-8").splitlines(), start=1
        ):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                raise RunnerError(f"ledger line {number} is not JSON: {error}")
            if not isinstance(record, dict):
                raise RunnerError(f"ledger line {number} is not an object")
            operation = record.get("operation")
            count = record.get("count")
            if not isinstance(operation, str) or not operation:
                raise RunnerError(f"ledger line {number} has no operation")
            if not isinstance(count, int) or isinstance(count, bool) or count <= 0:
                raise RunnerError(
                    f"ledger line {number} has a non-positive count for {operation}"
                )
            records.append(record)
        return records

    @contextlib.contextmanager
    def _exclusive(self) -> Iterator[None]:
        """Hold the ledger lock, creating the lock file on first use."""
        self.path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(
            self.lock_path, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o644
        )
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        finally:
            os.close(descriptor)

    @staticmethod
    def _totals(records: Sequence[Mapping[str, Any]]) -> Dict[str, int]:
        totals: Dict[str, int] = {}
        for record in records:
            totals[record["operation"]] = (
                totals.get(record["operation"], 0) + record["count"]
            )
        return totals

    @staticmethod
    def _requested(entries: Mapping[str, int]) -> Dict[str, int]:
        requested: Dict[str, int] = {}
        for operation, count in entries.items():
            if not isinstance(operation, str) or not operation:
                raise RunnerError(f"reservation names an invalid operation: {operation!r}")
            if not isinstance(count, int) or isinstance(count, bool) or count <= 0:
                raise RunnerError(
                    f"reservation for {operation} must be a positive integer, got {count!r}"
                )
            requested[operation] = requested.get(operation, 0) + count
        return requested

    def _refuse(self, requested: Mapping[str, int], consumed: Mapping[str, int]) -> None:
        overspend = {
            operation: consumed.get(operation, 0) + count - self.cap
            for operation, count in sorted(requested.items())
            if consumed.get(operation, 0) + count > self.cap
        }
        if overspend:
            detail = ", ".join(
                f"{operation} needs {count} more with cap {self.cap}"
                for operation, count in overspend.items()
            )
            raise RunnerError(f"canonical f32 budget exceeded: {detail}")

    def consumed(self) -> Dict[str, int]:
        return self._totals(self.records)

    def remaining(self) -> Dict[str, int]:
        return {
            operation: self.cap - total
            for operation, total in self.consumed().items()
            if total < self.cap
        }

    def check(self, entries: Mapping[str, int]) -> None:
        """Fail closed unless the durable ledger can still pay for `entries`.

        Nothing is created and nothing is appended. This is the whole capacity
        proof `--plan-only` makes before it stops.
        """
        requested = self._requested(entries)
        if not requested:
            return
        self._refuse(requested, self._totals(self._load()))

    def _sync_directory(self) -> None:
        """Make the ledger's own directory entry durable, not just its bytes."""
        descriptor = os.open(self.path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def reserve(self, entries: Mapping[str, int], label: str) -> None:
        """Durably record `entries`, or raise without writing anything.

        The whole batch is checked against the durable rows re-read under the
        lock, so neither a stale cache nor a concurrent reservation can let a
        later operation in the same batch overspend.
        """
        requested = self._requested(entries)
        if not requested:
            return

        with self._exclusive():
            durable = self._load()
            self._refuse(requested, self._totals(durable))
            self.path.parent.mkdir(parents=True, exist_ok=True)
            stamp = dt.datetime.now(dt.timezone.utc).isoformat()
            lines = [
                json.dumps(
                    {
                        "sequence": len(durable) + offset,
                        "label": label,
                        "operation": operation,
                        "count": count,
                        "cap": self.cap,
                        "reserved_at": stamp,
                    },
                    sort_keys=True,
                )
                for offset, (operation, count) in enumerate(sorted(requested.items()))
            ]
            with self.path.open("a", encoding="utf-8") as stream:
                for line in lines:
                    stream.write(line + "\n")
                stream.flush()
                os.fsync(stream.fileno())
            self._sync_directory()
        self.records = self._load()


# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------


class CasePlan:
    """One case as `--list` published it, with zero numerical execution."""

    __slots__ = (
        "name",
        "namespace",
        "bundle",
        "calls",
        "f32",
        "input_digest",
        "record",
    )

    def __init__(
        self,
        name: str,
        namespace: str,
        bundle: str,
        calls: int,
        f32: Mapping[str, int],
        input_digest: str,
        record: Optional[Mapping[str, Any]] = None,
    ) -> None:
        self.name = name
        self.namespace = namespace
        self.bundle = bundle
        self.calls = calls
        self.f32 = dict(f32)
        self.input_digest = input_digest
        #: The record this case was parsed from, so a measurement receipt can
        #: be re-read for the fields a listing never carries.
        self.record = record

    def charge(self, operation: str) -> int:
        return self.f32.get(operation, 0)

    def run_cost(self) -> Dict[str, int]:
        """Accepted kernel evaluations for one execution of this case."""
        return {
            operation: count * self.calls
            for operation, count in self.f32.items()
        }

    def identity(self) -> Tuple[Any, ...]:
        return (
            self.name,
            self.namespace,
            self.bundle,
            self.calls,
            tuple(sorted(self.f32.items())),
            self.input_digest,
        )


class Plan:
    """A parsed `--list` document."""

    def __init__(
        self,
        protocol: int,
        target: str,
        cpu: str,
        optimize: str,
        approved_profile: bool,
        harness_digest: str,
        cases: Sequence[CasePlan],
        summary: Mapping[str, Any],
    ) -> None:
        self.protocol = protocol
        self.target = target
        self.cpu = cpu
        self.optimize = optimize
        self.approved_profile = approved_profile
        self.harness_digest = harness_digest
        self.cases = list(cases)
        self.summary = dict(summary)

    def by_name(self) -> Dict[CaseKey, CasePlan]:
        return {case.name: case for case in self.cases}

    def identity(self) -> Tuple[Any, ...]:
        return (self.protocol, self.harness_digest, tuple(c.identity() for c in self.cases))

    def for_bundle(self, bundle: str) -> "Plan":
        """The same pinned plan restricted to one bundle.

        A profiler invocation runs `--slice=<bundle>`, so its receipt carries
        only that bundle's rows. Restricting the case list here keeps every
        pinned build field identical, so the receipt is still proved against
        the plan that was listed rather than against a second, weaker plan.
        """
        return Plan(
            protocol=self.protocol,
            target=self.target,
            cpu=self.cpu,
            optimize=self.optimize,
            approved_profile=self.approved_profile,
            harness_digest=self.harness_digest,
            cases=[case for case in self.cases if case.bundle == bundle],
            summary=self.summary,
        )


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise RunnerError(message)


def _positive_int(value: Any, description: str, line: int) -> int:
    _require(
        isinstance(value, int) and not isinstance(value, bool) and value > 0,
        f"{description} on line {line} must be a positive integer, got {value!r}",
    )
    return int(value)


def parse_plan(text: str, description: str, mode: Optional[str] = None) -> Plan:
    """Parse one `--list` or measurement document into a `Plan`.

    Every field the budget depends on is validated here, so a malformed or
    truncated document fails before a reservation is written. `mode` names the
    document kind the caller insists on: `"list"` for a listing, `"measure"`
    for a measurement receipt, and `None` to accept either.
    """
    if mode is not None and mode not in ("list", "measure"):
        raise RunnerError(f"unknown document mode {mode!r}")
    build: Optional[Dict[str, Any]] = None
    summary: Optional[Dict[str, Any]] = None
    cases: List[CasePlan] = []
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise RunnerError(f"{description} line {number} is not JSON: {error}")
        _require(isinstance(record, dict), f"{description} line {number} is not an object")
        kind = record.get("kind")
        _require(isinstance(kind, str), f"{description} line {number} has no kind")
        if kind == "build":
            _require(build is None, f"{description} repeats its build line")
            build = record
        elif kind == "summary":
            _require(summary is None, f"{description} repeats its summary line")
            summary = record
        elif kind in ("case", "row"):
            if mode is not None:
                expected_kind = "case" if mode == "list" else "row"
                _require(
                    kind == expected_kind,
                    f"{description} line {number} publishes {kind!r}, "
                    f"expected {expected_kind!r} for a {mode} document",
                )
            cases.append(_parse_case(record, description, number))
        else:
            raise RunnerError(f"{description} line {number} has unknown kind {kind!r}")

    _require(build is not None, f"{description} has no build line")
    _require(summary is not None, f"{description} has no summary line")
    assert build is not None and summary is not None

    _require(
        build.get("protocol") == PROTOCOL_VERSION,
        f"{description} speaks protocol {build.get('protocol')!r}, this runner speaks "
        f"{PROTOCOL_VERSION}",
    )
    _require(bool(build.get("approved_profile")), f"{description} was not built in the approved profile")
    harness_digest = build.get("harness_digest")
    _require(
        isinstance(harness_digest, str) and len(harness_digest) == 16,
        f"{description} has no usable harness digest",
    )
    seen: Dict[str, int] = {}
    for case in cases:
        _require(
            case.name not in seen,
            f"{description} publishes case {case.name!r} more than once",
        )
        seen[case.name] = case.calls
    _require(
        summary.get("cases") == len(cases),
        f"{description} summary claims {summary.get('cases')!r} cases but lists {len(cases)}",
    )
    if mode is not None:
        _require(
            summary.get("mode") == mode,
            f"{description} summary claims mode {summary.get('mode')!r}, this "
            f"document must be a {mode} document",
        )

    return Plan(
        protocol=PROTOCOL_VERSION,
        target=str(build.get("target", "unknown")),
        cpu=str(build.get("cpu", "unknown")),
        optimize=str(build.get("optimize", "unknown")),
        approved_profile=bool(build.get("approved_profile")),
        harness_digest=harness_digest,
        cases=cases,
        summary=summary,
    )


def _parse_case(record: Mapping[str, Any], description: str, line: int) -> CasePlan:
    name = record.get("name")
    _require(isinstance(name, str) and name, f"{description} line {line} has no name")
    namespace = record.get("namespace")
    _require(
        isinstance(namespace, str) and namespace in NAMESPACES,
        f"{description} line {line} names namespace {namespace!r}, which is not a "
        "canonical public owner",
    )
    bundle = record.get("bundle")
    _require(
        isinstance(bundle, str) and bundle in BUNDLES,
        f"{description} line {line} names bundle {bundle!r}, which is not a registered bundle",
    )
    calls = _positive_int(record.get("calls"), "calls", line)
    charges = record.get("f32")
    _require(isinstance(charges, list), f"{description} line {line} has no f32 charge list")
    f32: Dict[str, int] = {}
    for charge in charges:
        _require(isinstance(charge, dict), f"{description} line {line} has a malformed charge")
        operation = charge.get("operation")
        _require(
            isinstance(operation, str) and operation,
            f"{description} line {line} has a charge without an operation",
        )
        _require(
            operation not in f32,
            f"{description} line {line} charges {operation} twice, which double spends it",
        )
        f32[operation] = _positive_int(charge.get("count"), "charge count", line)
    total = record.get("f32_total")
    _require(
        total == sum(f32.values()),
        f"{description} line {line} claims f32_total {total!r} but its charges sum to "
        f"{sum(f32.values())}",
    )
    digest = record.get("input_digest")
    _require(
        isinstance(digest, str) and len(digest) == 16,
        f"{description} line {line} has no usable input digest",
    )
    return CasePlan(name, namespace, bundle, calls, f32, digest, record)


def _compare_build(left: Plan, right: Plan, subject: str) -> None:
    """Fail unless two documents came from the same pinned harness build."""
    for field in (
        "harness_digest",
        "target",
        "cpu",
        "optimize",
        "approved_profile",
    ):
        first = getattr(left, field)
        second = getattr(right, field)
        if first != second:
            raise RunnerError(
                f"{subject} disagree on {field}: {first!r} against {second!r}"
            )


def compare_plans(baseline: Plan, candidate: Plan) -> None:
    """Fail unless the two listings describe the same work, field for field."""
    if baseline.identity() != candidate.identity():
        baseline_cases = baseline.by_name()
        candidate_cases = candidate.by_name()
        if list(baseline_cases) != list(candidate_cases):
            only_baseline = [n for n in baseline_cases if n not in candidate_cases]
            only_candidate = [n for n in candidate_cases if n not in baseline_cases]
            raise RunnerError(
                "case lists differ: "
                f"{len(only_baseline)} only in baseline, {len(only_candidate)} only in candidate"
            )

        for name, case in baseline_cases.items():
            other = candidate_cases[name]
            if case.identity() != other.identity():
                raise RunnerError(
                    f"case {name!r} differs between baseline and candidate: "
                    f"baseline {case.identity()!r} against candidate {other.identity()!r}"
                )
        raise RunnerError(
            "plans differ outside their case lists: "
            f"protocol {baseline.protocol}/{candidate.protocol}, "
            f"harness {baseline.harness_digest}/{candidate.harness_digest}"
        )
    _compare_build(baseline, candidate, "the two executable listings")


def compare_document(
    document: Plan, plan: Plan, bundles: Sequence[str], description: str
) -> None:
    """Fail unless a measurement receipt is exactly the round that was listed.

    The receipt is accepted whole or not at all: a missing, duplicated,
    unexpected or altered case, or a summary that does not add up, fails here
    before any of its rows reach a sample list.
    """
    measured = document.by_name()
    listed = plan.by_name()
    missing = sorted(set(listed) - set(measured))
    unexpected = sorted(set(measured) - set(listed))
    if missing or unexpected:
        raise RunnerError(
            f"{description} did not measure the planned selection: "
            f"{len(missing)} missing, {len(unexpected)} unexpected"
        )
    _require(
        list(measured) == list(listed),
        f"{description} measured the planned cases in a different order than the "
        "listing published them",
    )
    for name, case in listed.items():
        if case.identity() != measured[name].identity():
            raise RunnerError(
                f"{description} measured {name!r} differently from the listing: "
                f"planned {case.identity()!r} against measured "
                f"{measured[name].identity()!r}"
            )

    _compare_build(plan, document, f"{description} and the listing")
    summary = document.summary
    _require(
        summary.get("bundles") == list(bundles),
        f"{description} summary names bundles {summary.get('bundles')!r}, this "
        f"round selected {list(bundles)}",
    )
    calls_total = sum(case.calls for case in plan.cases)
    _require(
        summary.get("calls_total") == calls_total,
        f"{description} summary claims {summary.get('calls_total')!r} calls, the "
        f"plan totals {calls_total}",
    )
    charges: Dict[str, int] = {}
    for case in plan.cases:
        for operation, count in case.f32.items():
            charges[operation] = charges.get(operation, 0) + count
    _require(
        summary.get("f32_total") == sum(charges.values()),
        f"{description} summary claims {summary.get('f32_total')!r} f32 charges, "
        f"the plan totals {sum(charges.values())}",
    )
    reported = summary.get("f32")
    _require(
        isinstance(reported, list)
        and all(isinstance(charge, dict) for charge in reported),
        f"{description} summary has no readable f32 charge list",
    )
    _require(
        {charge.get("operation"): charge.get("count") for charge in reported} == charges,
        f"{description} summary aggregates {reported!r}, the plan totals {charges!r}",
    )


def measurement_document(
    text: str,
    description: str,
    plan: Plan,
    bundles: Sequence[str],
) -> List[Tuple[CasePlan, int, str]]:
    """Validate one whole measurement receipt and return its timed rows.

    Nothing here tolerates a partial document: an unknown record kind, a
    non-JSON line, a repeated case, a case the round never planned, a build
    line that is not the one that was listed, or a summary that disagrees with
    its own rows all fail before a single sample is collected.
    """
    document = parse_plan(text, description, "measure")
    compare_document(document, plan, bundles, description)
    timed: List[Tuple[CasePlan, int, str]] = []
    for case in document.cases:
        elapsed, checksum = timed_row(case.record or {}, case, description)
        timed.append((case, elapsed, checksum))
    return timed


# ---------------------------------------------------------------------------
# Budget
# ---------------------------------------------------------------------------


def required_reservations(
    plan: Plan,
    pairs: int,
    profile_invocations: int = 0,
    profile_bundles: Sequence[str] = (),
) -> Dict[str, int]:
    """Kernel evaluations the ledger must have room for before this round runs.

    The measurement loop launches each side once per pair over *every* planned
    case, whether or not its bundle is profiled, and each declared profiler
    invocation launches each side once more over the cases of its own bundle.
    Lane and transitive counts are already multiplied into `CasePlan.f32` by the
    executable, so this arithmetic is the whole budget: narrowing the profiler
    to a subset never narrows what the round measures, and must never narrow
    what the round has paid for.
    """
    _require(pairs > 0, "pair count must be positive")
    _require(profile_invocations >= 0, "profiler invocation count cannot be negative")
    profiled = set(profile_bundles)

    required: Dict[str, int] = {}
    for case in plan.cases:
        runs = 2 * pairs
        if case.bundle in profiled:
            runs += 2 * profile_invocations
        for operation, count in case.run_cost().items():
            required[operation] = required.get(operation, 0) + count * runs
    return required


# ---------------------------------------------------------------------------
# Process execution
# ---------------------------------------------------------------------------


def repo_root() -> pathlib.Path:
    root = pathlib.Path(__file__).resolve().parent.parent
    if (root / "build.zig").is_file() and (root / "bench").is_dir():
        return root
    return pathlib.Path.cwd().resolve()


def run_capture(command: Sequence[str], description: str) -> str:
    try:
        result = subprocess.run(list(command), capture_output=True, text=True, check=False)
    except OSError as error:
        raise RunnerError(f"could not launch {description}: {error}") from error
    if result.returncode != 0:
        raise RunnerError(
            f"{description} failed with exit {result.returncode}: {result.stderr.strip()}"
        )
    return result.stdout


def executable(path: pathlib.Path, description: str) -> pathlib.Path:
    resolved = path.expanduser().resolve()
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise RunnerError(f"{description} is not an executable file: {resolved}")
    return resolved


def select_cpu(requested: int) -> Tuple[int, List[int]]:
    if not hasattr(os, "sched_getaffinity"):
        raise RunnerError("process affinity is not available, so CPU0 cannot be proved")
    allowed = sorted(os.sched_getaffinity(0))
    if not allowed:
        raise RunnerError("process affinity contains no CPUs")
    if requested not in allowed:
        raise RunnerError(f"CPU {requested} is not allowed by process affinity {allowed}")
    return requested, allowed


def selection_arguments(
    bundles: Sequence[str],
    cases: Sequence[str] = (),
    calls: Optional[int] = None,
) -> List[str]:
    """The arguments naming one selection to a round executable.

    One `--case=` per requested name: a cohort is a repeated flag, so a
    selection is exactly the named cases, and no name at all is every case in
    the selected bundles.
    """
    arguments = ["--slice=" + ",".join(bundles)]
    arguments.extend("--case=" + name for name in cases)
    if calls is not None:
        arguments.append(f"--calls={calls}")
    return arguments


def collect_plan(
    exe: pathlib.Path,
    description: str,
    bundles: Sequence[str],
    cases: Sequence[str],
    calls: Optional[int],
) -> Plan:
    """List one executable's selection, with zero numerical execution.

    A name no selected bundle publishes fails here, on the executable's own
    terms, which is before this round reserves anything.
    """
    command = [str(exe), "--list"] + selection_arguments(bundles, cases, calls)
    return parse_plan(run_capture(command, f"{description} listing"), f"{description} listing")


def measure_run(
    exe: pathlib.Path,
    description: str,
    cpu: int,
    bundles: Sequence[str],
    cases: Sequence[str],
    calls: Optional[int],
    raw_dir: pathlib.Path,
    stem: str,
) -> str:
    """One process, one side, one pair. The whole selection or nothing.

    The raw document is returned unparsed: what it claims is judged by
    `measurement_document` against the plan, not by a lenient scan here.
    """
    command = ["taskset", "-c", str(cpu), str(exe)] + selection_arguments(
        bundles, cases, calls
    )
    stdout_path = raw_dir / f"{stem}.jsonl"
    stderr_path = raw_dir / f"{stem}.stderr.txt"
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
    except OSError as error:
        stdout_path.write_text("", encoding="utf-8")
        stderr_path.write_text(str(error), encoding="utf-8")
        raise RunnerError(f"could not launch {description}: {error}") from error
    stdout_path.write_text(result.stdout, encoding="utf-8")
    stderr_path.write_text(result.stderr, encoding="utf-8")
    if result.returncode != 0:
        raise RunnerError(
            f"{description} failed with exit {result.returncode}; the pair is not "
            f"retried and its budget stays spent; see {stderr_path}"
        )
    return result.stdout


def timed_row(
    row: Mapping[str, Any], case: CasePlan, description: str
) -> Tuple[int, str]:
    """Pull `(elapsed_ns, checksum)` out of a measurement row, or fail."""
    _require(row.get("kind") == "row", f"{description} produced a non-row line for {case.name}")
    _require(
        row.get("name") == case.name
        and row.get("namespace") == case.namespace
        and row.get("bundle") == case.bundle,
        f"{description} row does not match the planned case {case.name!r}",
    )
    _require(
        row.get("calls") == case.calls,
        f"{description} ran {case.name!r} with {row.get('calls')!r} calls, the plan says "
        f"{case.calls}",
    )
    _require(
        row.get("input_digest") == case.input_digest,
        f"{description} ran {case.name!r} with a different input digest",
    )
    elapsed = row.get("elapsed_ns")
    _require(
        isinstance(elapsed, int) and not isinstance(elapsed, bool) and elapsed > 0,
        f"{description} reported no elapsed_ns for {case.name!r}",
    )
    checksum = row.get("checksum")
    _require(
        isinstance(checksum, str) and len(checksum) == 16,
        f"{description} reported no checksum for {case.name!r}",
    )
    charges = row.get("f32")
    _require(
        isinstance(charges, list)
        and all(isinstance(charge, dict) for charge in charges)
        and len({charge.get("operation") for charge in charges}) == len(charges),
        f"{description} charged {case.name!r} with a malformed or repeated f32 plan",
    )
    _require(
        {charge.get("operation"): charge.get("count") for charge in charges} == case.f32,
        f"{description} charged a different f32 plan for {case.name!r}",
    )
    _require(
        row.get("f32_total") == sum(case.f32.values()),
        f"{description} claims f32_total {row.get('f32_total')!r} for "
        f"{case.name!r}, its charges sum to {sum(case.f32.values())}",
    )
    return int(elapsed), checksum


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------


def median(values: Sequence[int]) -> float:
    return float(statistics.median(values))


def relative_spread(values: Sequence[int], centre: float) -> float:
    if centre <= 0:
        return float("inf")
    return (max(values) - min(values)) / centre


def verdict(improvement: float, faster_pairs: int, slower_pairs: int, pairs: int) -> str:
    """One word per case. Anything short of the quorum stays undecided.

    Each pair counts in the one direction it went. A candidate that matched
    the baseline exactly is a tie, and a tie is evidence in neither direction,
    so a run cannot buy a quorum with pairs that did not move. The quorum is
    `pairs - 1`: nine pairs need eight of them.
    """
    quorum = max(1, pairs - 1)
    if improvement >= PRACTICAL_THRESHOLD and faster_pairs >= quorum:
        return "faster"
    if improvement <= -PRACTICAL_THRESHOLD and slower_pairs >= quorum:
        return "slower"
    return "undecided"


def summarize(
    plan: Plan,
    samples: Mapping[str, Mapping[str, List[int]]],
    checksums: Mapping[str, Mapping[str, str]],
    pairs: int,
) -> List[Dict[str, Any]]:
    """One record per case. Every case is reported, not only the winners."""
    records: List[Dict[str, Any]] = []
    for case in plan.cases:
        baseline_samples = samples["baseline"].get(case.name, [])
        candidate_samples = samples["candidate"].get(case.name, [])
        _require(
            len(baseline_samples) == pairs and len(candidate_samples) == pairs,
            f"case {case.name!r} has {len(baseline_samples)} baseline and "
            f"{len(candidate_samples)} candidate samples, expected {pairs} of each",
        )
        baseline_median = median(baseline_samples)
        candidate_median = median(candidate_samples)
        improvement = (
            (baseline_median - candidate_median) / baseline_median
            if baseline_median > 0
            else 0.0
        )
        faster_pairs = sum(
            1
            for baseline, candidate in zip(baseline_samples, candidate_samples)
            if candidate < baseline
        )
        slower_pairs = sum(
            1
            for baseline, candidate in zip(baseline_samples, candidate_samples)
            if candidate > baseline
        )
        records.append(
            {
                "name": case.name,
                "namespace": case.namespace,
                "bundle": case.bundle,
                "calls": case.calls,
                "f32": dict(case.f32),
                "baseline_median_ns": baseline_median,
                "candidate_median_ns": candidate_median,
                "baseline_min_ns": min(baseline_samples),
                "baseline_max_ns": max(baseline_samples),
                "candidate_min_ns": min(candidate_samples),
                "candidate_max_ns": max(candidate_samples),
                "baseline_spread": relative_spread(baseline_samples, baseline_median),
                "candidate_spread": relative_spread(candidate_samples, candidate_median),
                "improvement": improvement,
                "faster_pairs": faster_pairs,
                "slower_pairs": slower_pairs,
                "checksum": checksums["baseline"][case.name],
                "verdict": verdict(improvement, faster_pairs, slower_pairs, pairs),
            }
        )
    return records


def cohort_summary(records: Sequence[Mapping[str, Any]], key: str) -> List[Dict[str, Any]]:
    cohorts: Dict[str, Dict[str, int]] = {}
    for record in records:
        bucket = cohorts.setdefault(
            record[key], {"cases": 0, "faster": 0, "slower": 0, "undecided": 0}
        )
        bucket["cases"] += 1
        bucket[record["verdict"]] += 1
    return [{"cohort": name, **counts} for name, counts in sorted(cohorts.items())]


def report_lines(
    records: Sequence[Mapping[str, Any]],
    pairs: int,
    quorum: int,
) -> List[str]:
    lines = [
        "",
        f"cases={len(records)} pairs={pairs} "
        f"practical_threshold={PRACTICAL_THRESHOLD:.0%} direction_quorum={quorum}/{pairs}",
        "",
        f"{'case':<62} {'cohort':<11} {'base ns':>12} {'cand ns':>12} "
        f"{'change':>9} {'fast':>5} verdict",
    ]
    for record in sorted(
        records,
        key=lambda item: (-abs(float(item["improvement"])), item["name"]),
    ):
        lines.append(
            f"{record['name']:<62} {record['bundle']:<11} "
            f"{record['baseline_median_ns']:>12.0f} {record['candidate_median_ns']:>12.0f} "
            f"{record['improvement']:>+8.2%} "
            f"{record['faster_pairs']:>2}/{pairs} {record['verdict']}"
        )
    lines.append("")
    for cohort in cohort_summary(records, "bundle"):
        lines.append(
            f"cohort {cohort['cohort']:<12} cases={cohort['cases']:<5} "
            f"faster={cohort['faster']:<5} slower={cohort['slower']:<5} "
            f"undecided={cohort['undecided']}"
        )
    for cohort in cohort_summary(records, "namespace"):
        lines.append(
            f"module {cohort['cohort']:<12} cases={cohort['cases']:<5} "
            f"faster={cohort['faster']:<5} slower={cohort['slower']:<5} "
            f"undecided={cohort['undecided']}"
        )
    regressions = [record for record in records if record["verdict"] == "slower"]
    lines.append("")
    lines.append(f"regressions meeting the criterion: {len(regressions)}")
    for record in sorted(regressions, key=lambda item: float(item["improvement"])):
        lines.append(
            f"  {record['name']} {record['improvement']:+.2%} "
            f"{record['slower_pairs']}/{pairs} pairs slower"
        )
    return lines


# ---------------------------------------------------------------------------
# Profiler
# ---------------------------------------------------------------------------


def profile_commands(
    perf: str,
    mode: str,
    events: str,
    exe: pathlib.Path,
    side: str,
    bundle: str,
    invocation: int,
    cpu: int,
    cases: Sequence[str],
    calls: Optional[int],
    output_dir: pathlib.Path,
) -> Tuple[List[str], pathlib.Path]:
    common = ["taskset", "-c", str(cpu), str(exe)] + selection_arguments(
        [bundle], cases, calls
    )
    if mode == "stat":
        target = output_dir / f"{side}-{bundle}-run{invocation}.stat.csv"
        command = [perf, "stat", "-x", ",", "-e", events, "-o", str(target), "--"] + common
    else:
        target = output_dir / f"{side}-{bundle}-run{invocation}.perf.data"
        command = [perf, "record", "-o", str(target), "--"] + common
    return command, target


def run_profiles(
    perf: str,
    mode: str,
    events: str,
    executables: Mapping[str, pathlib.Path],
    plan: Plan,
    expected: Mapping[str, Mapping[str, str]],
    bundles: Sequence[str],
    invocations: int,
    cpu: int,
    cases: Sequence[str],
    calls: Optional[int],
    out_dir: pathlib.Path,
) -> List[Dict[str, Any]]:
    """Profile every declared invocation, or fail.

    `--perf-invocations` is what the ledger paid for, so this runs exactly that
    many times per side per bundle, each into its own receipt file. Charging N
    and running one would make the reservation a lie.

    A profiler exit code is not evidence: the workload's stdout is the round's
    own measurement document, so it is saved, then parsed whole against the
    plan restricted to this bundle, and every checksum it reports must equal
    the one this side already measured for that case. A truncated, garbled,
    stale or divergent receipt fails here instead of being published. Nothing
    is retried and nothing is refunded; a failed attempt keeps its raw rows.
    """
    if shutil.which(perf) is None:
        raise RunnerError(f"{perf} is required for profiling but was not found")
    _require(invocations > 0, f"profiler invocation count must be positive, got {invocations}")
    output_dir = out_dir / "perf"
    output_dir.mkdir(parents=True, exist_ok=True)
    runs: List[Dict[str, Any]] = []
    for side in SIDES:
        measured = expected.get(side, {})
        for bundle in bundles:
            bundle_plan = plan.for_bundle(bundle)
            # The invocation runs one bundle's slice, so it is told the part of
            # the cohort that slice publishes: a name belonging to another
            # bundle is not published by this one, and naming it here would
            # fail an invocation it was never meant for. With no cohort this is
            # empty, which is the whole slice.
            published = set(bundle_plan.by_name())
            bundle_cases = list(dict.fromkeys(name for name in cases if name in published))
            for invocation in range(invocations):
                command, target = profile_commands(
                    perf,
                    mode,
                    events,
                    executables[side],
                    side,
                    bundle,
                    invocation,
                    cpu,
                    cases=bundle_cases,
                    calls=calls,
                    output_dir=output_dir,
                )
                stem = f"{side}-{bundle}-run{invocation}"
                stdout_path = output_dir / f"{stem}.jsonl"
                stderr_path = output_dir / f"{stem}.stderr.txt"
                try:
                    result = subprocess.run(
                        command, capture_output=True, text=True, check=False
                    )
                except OSError as error:
                    stdout_path.write_text("", encoding="utf-8")
                    stderr_path.write_text(str(error), encoding="utf-8")
                    raise RunnerError(
                        f"could not launch {perf} for {side}/{bundle} run "
                        f"{invocation}: {error}"
                    )
                # Every receipt lands on disk before anything is judged, so a
                # failed attempt is still evidence of what the paid-for
                # invocation actually produced. perf writes its own counters to
                # `target` itself, and those survive the failure unchanged.
                stdout_path.write_text(result.stdout, encoding="utf-8")
                stderr_path.write_text(result.stderr, encoding="utf-8")
                if result.returncode != 0:
                    raise RunnerError(
                        f"{perf} {mode} for {side}/{bundle} run {invocation} failed "
                        f"with exit {result.returncode}; its budget stays spent; see "
                        f"{stderr_path}"
                    )
                for case, _elapsed, checksum in measurement_document(
                    result.stdout, stem, bundle_plan, [bundle]
                ):
                    recorded = measured.get(case.name)
                    _require(
                        recorded is not None,
                        f"{stem} profiled {case.name!r}, which this round never "
                        f"measured on {side}",
                    )
                    _require(
                        recorded == checksum,
                        f"{stem} returned checksum {checksum} for {case.name!r}, "
                        f"but {side} measured {recorded}; the profile is not of "
                        f"the run it claims to profile",
                    )
                runs.append(
                    {
                        "side": side,
                        "bundle": bundle,
                        "invocation": invocation,
                        "mode": mode,
                        "output": str(target),
                        "stdout": str(stdout_path),
                        "stderr": str(stderr_path),
                        "command": command,
                    }
                )
    return runs


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Pair a frozen zmath API round baseline against a candidate."
    )
    parser.add_argument(
        "--baseline-exe",
        type=pathlib.Path,
        required=True,
        help="Frozen baseline executable. There is no default.",
    )
    parser.add_argument(
        "--candidate-exe",
        type=pathlib.Path,
        required=True,
        help="Candidate executable. There is no default.",
    )
    parser.add_argument(
        "--out-dir",
        type=pathlib.Path,
        required=True,
        help="Fresh scratch directory outside the repository for this round's raw rows, profiler output and report. It must not already exist: a round never overwrites an earlier round's receipts.",
    )
    parser.add_argument(
        "--ledger",
        type=pathlib.Path,
        required=True,
        help="Persistent append-only f32 budget ledger, shared by every round, "
        "version and failed attempt. There is no default and it must live "
        "outside --out-dir, so a new result directory cannot reset the approval.",
    )
    parser.add_argument(
        "--source-dir",
        action="append",
        type=pathlib.Path,
        default=None,
        help="Source tree to fingerprint with SHA256 into the manifest and "
        "results; repeatable. Omit when there is no tree to record.",
    )
    parser.add_argument(
        "--bundle",
        action="append",
        choices=BUNDLES,
        help="Restrict the round to this bundle; repeatable, default all six.",
    )
    parser.add_argument(
        "--case",
        action="append",
        default=None,
        metavar="NAME",
        help="Measure this published case by name; repeatable, so repeating it "
        "measures exactly the named cases. A name no selected bundle publishes "
        "is refused before anything is launched. Omit to measure every case in "
        "the selected bundles.",
    )
    parser.add_argument(
        "--pairs",
        type=int,
        default=DEFAULT_PAIRS,
        help=f"Paired AB/BA rounds (default {DEFAULT_PAIRS}).",
    )
    parser.add_argument(
        "--calls",
        type=int,
        default=None,
        help="Override every case's own call count. Omit to use the plan's per-case count.",
    )
    parser.add_argument(
        "--cpu",
        type=int,
        default=0,
        help="CPU to pin both sides to (default 0).",
    )
    parser.add_argument(
        "--cap",
        type=int,
        default=CANONICAL_CAP,
        help=f"Per-canonical-operation f32 ceiling. It may only lower the approved "
        f"{CANONICAL_CAP}; a larger ceiling is refused.",
    )
    parser.add_argument(
        "--plan-only",
        action="store_true",
        help="Prove the plan and the remaining capacity, then stop. Only the "
        "zero-math --list listings run: no measurement, no profiler, no "
        "receipts, no ledger write. Fails on an exhausted budget.",
    )
    parser.add_argument(
        "--perf-mode",
        choices=("none", "stat", "record"),
        default="none",
        help="Profile the selected cohorts with perf after the measurement pairs.",
    )
    parser.add_argument(
        "--perf-events",
        default=DEFAULT_PERF_EVENTS,
        help=f"perf stat event list (default {DEFAULT_PERF_EVENTS}).",
    )
    parser.add_argument(
        "--perf-bundle",
        action="append",
        choices=BUNDLES,
        help="Bundle to profile; repeatable. Defaults to every selected bundle.",
    )
    parser.add_argument(
        "--perf-invocations",
        type=int,
        default=1,
        help="Profiler invocations per side per bundle; each one is really run "
        "and each is already paid for in the reservation (default 1).",
    )
    parser.add_argument(
        "--perf",
        default="perf",
        help="perf executable to use (default perf).",
    )
    return parser.parse_args(argv)


def validate_args(args: argparse.Namespace, root: pathlib.Path) -> pathlib.Path:
    """Resolve and check every option. This writes nothing, ever."""
    if args.pairs <= 0:
        raise RunnerError(f"--pairs must be positive, got {args.pairs}")
    if args.calls is not None and args.calls <= 0:
        raise RunnerError(f"--calls must be positive, got {args.calls}")
    if args.perf_invocations <= 0:
        raise RunnerError(
            f"--perf-invocations must be positive, got {args.perf_invocations}"
        )
    if args.cap <= 0:
        raise RunnerError(f"--cap must be positive, got {args.cap}")
    if args.cap > CANONICAL_CAP:
        raise RunnerError(
            f"--cap {args.cap} exceeds the approved ceiling {CANONICAL_CAP}; the "
            "approval cannot be widened from the command line"
        )
    out_dir = args.out_dir.expanduser().resolve()
    try:
        out_dir.relative_to(root)
    except ValueError:
        pass
    else:
        raise RunnerError(
            f"--out-dir must be caller-supplied scratch outside {root}, got {out_dir}"
        )
    if out_dir.exists() and not out_dir.is_dir():
        raise RunnerError(f"--out-dir exists and is not a directory: {out_dir}")
    return out_dir


def resolve_ledger(args: argparse.Namespace, out_dir: pathlib.Path) -> pathlib.Path:
    """The one persistent ledger this round spends from.

    It is refused inside `--out-dir` precisely because a per-round result
    directory would hand every round a fresh allowance, which is the failure
    this option exists to make impossible.
    """
    ledger = args.ledger.expanduser().resolve()
    if ledger.is_dir():
        raise RunnerError(f"--ledger is a directory, not a ledger file: {ledger}")
    try:
        ledger.relative_to(out_dir)
    except ValueError:
        return ledger
    raise RunnerError(
        f"--ledger must live outside --out-dir {out_dir}, got {ledger}; a ledger "
        "inside the result directory would reset the budget every round"
    )


def resolve_sources(args: argparse.Namespace) -> List[pathlib.Path]:
    """Every `--source-dir`, resolved and proved to be a tree."""
    sources: List[pathlib.Path] = []
    for given in args.source_dir or ():
        root = given.expanduser().resolve()
        if not root.is_dir():
            raise RunnerError(f"--source-dir is not a directory: {root}")
        if root not in sources:
            sources.append(root)
    return sources


def prepare_out_dir(out_dir: pathlib.Path) -> None:
    """Create this round's result directory, refusing to reuse one.

    Raw rows, profiler output and the report are the evidence the round is
    believed on, so an existing directory is a refusal, not a merge target.
    """
    if out_dir.exists():
        raise RunnerError(
            f"--out-dir already exists: {out_dir}; a round must not overwrite an "
            "earlier round's receipts, so it needs a fresh directory"
        )
    try:
        out_dir.mkdir(parents=True, exist_ok=False)
    except FileExistsError as error:
        raise RunnerError(
            f"--out-dir already exists: {out_dir}; a round must not overwrite an "
            "earlier round's receipts, so it needs a fresh directory"
        ) from error


def selected_bundles(args: argparse.Namespace) -> List[str]:
    chosen = set(args.bundle) if args.bundle else set(BUNDLES)
    return [bundle for bundle in BUNDLES if bundle in chosen]


def selected_cases(args: argparse.Namespace) -> List[str]:
    """The cases this round asked for by name, in request order.

    No name at all is every case in the selected bundles. A name no published
    case carries is refused by the executable that lists the plan, which is
    before this round creates or reserves anything. An empty name can select
    nothing at all, so it is refused here rather than by a process launched to
    reject it. A name repeated in the request is left alone: the executable
    selects that case once.
    """
    names = list(args.case or ())
    for name in names:
        if not name:
            raise RunnerError(f"--case needs a published case name, got {name!r}")
    return names


def profile_bundles(args: argparse.Namespace, selected: Sequence[str]) -> List[str]:
    if args.perf_mode == "none":
        return []
    if args.perf_bundle:
        chosen = list(dict.fromkeys(args.perf_bundle))
    else:
        chosen = list(selected)
    outside = [bundle for bundle in chosen if bundle not in selected]
    if outside:
        raise RunnerError(
            f"profiled bundles {outside} are not part of this round's selection {list(selected)}"
        )
    return chosen


# ---------------------------------------------------------------------------
# Provenance
# ---------------------------------------------------------------------------


def file_digest(path: pathlib.Path) -> str:
    """SHA256 of one file, read in blocks so a large binary is not slurped."""
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_digest(root: pathlib.Path) -> Tuple[str, int]:
    """SHA256 over a whole source tree, and how many files went into it.

    Relative paths are folded in beside the contents, so a renamed file with
    identical bytes is a different tree.
    """
    digest = hashlib.sha256()
    files = sorted(path for path in root.rglob("*") if path.is_file())
    for path in files:
        digest.update(path.relative_to(root).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(file_digest(path).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest(), len(files)


def provenance(
    executables: Mapping[str, pathlib.Path],
    sources: Sequence[pathlib.Path],
    runner_path: pathlib.Path,
) -> Dict[str, Any]:
    """What produced these numbers: both binaries, this runner, the trees."""
    trees: List[Dict[str, Any]] = []
    for root in sources:
        digest, files = tree_digest(root)
        trees.append({"path": str(root), "sha256": digest, "files": files})
    return {
        "runner": {"path": str(runner_path), "sha256": file_digest(runner_path)},
        "executables": {
            side: {
                "path": str(path),
                "sha256": file_digest(path),
                "size": path.stat().st_size,
            }
            for side, path in sorted(executables.items())
        },
        "sources": trees,
    }


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    root = repo_root()
    out_dir = validate_args(args, root)
    ledger_path = resolve_ledger(args, out_dir)
    sources = resolve_sources(args)
    bundles = selected_bundles(args)
    cases = selected_cases(args)
    profiled = profile_bundles(args, bundles)
    cpu, allowed = select_cpu(args.cpu)
    if shutil.which("taskset") is None:
        raise RunnerError("taskset is required to pin measurements but was not found")

    executables = {
        "baseline": executable(args.baseline_exe, "baseline executable"),
        "candidate": executable(args.candidate_exe, "candidate executable"),
    }
    plans = {
        side: collect_plan(
            executables[side], f"{side} executable", bundles, cases, args.calls
        )
        for side in SIDES
    }
    compare_plans(plans["baseline"], plans["candidate"])
    plan = plans["candidate"]
    if not plan.cases:
        raise RunnerError(f"the selection {bundles} contains no cases")

    required = required_reservations(
        plan,
        args.pairs,
        args.perf_invocations if profiled else 0,
        profiled,
    )
    ledger = Ledger(ledger_path, args.cap)
    consumed_before = ledger.consumed()

    print(f"cases={len(plan.cases)} bundles={','.join(bundles)} pairs={args.pairs}")
    print(
        f"target={plan.target} cpu={plan.cpu} optimize={plan.optimize} "
        f"allowed_cpus={allowed} pinned_cpu={cpu}"
    )
    print(f"harness_digest={plan.harness_digest} protocol={plan.protocol}")
    print(f"canonical f32 cap={args.cap} per operation")
    print(f"ledger={ledger_path}")
    if required:
        print("required before launch:")
        for operation, count in sorted(required.items()):
            left = args.cap - consumed_before.get(operation, 0)
            print(f"  {operation}: {count} required, {left} left, {left - count} left after")
    else:
        print("required before launch: nothing, the selection reaches no accepted f32 kernel")

    # Fail closed on an exhausted allowance before anything is created, and
    # without touching the ledger. `reserve` re-proves it under its own lock.
    ledger.check(required)

    if args.plan_only:
        print(
            "plan-only: the ledger can pay for this round; the two --list "
            "listings above were its only launches. Nothing was measured, "
            "nothing was written"
        )
        return 0

    # Fresh receipts only, and durable before the first process. Failed
    # attempts stay paid for.
    prepare_out_dir(out_dir)
    ledger.reserve(required, "round")
    print(f"reserved {sum(required.values())} kernel evaluations in {ledger.path}")

    raw_dir = out_dir / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    samples: Dict[str, Dict[str, List[int]]] = {side: {} for side in SIDES}
    checksums: Dict[str, Dict[str, str]] = {side: {} for side in SIDES}
    commands: List[Dict[str, Any]] = []

    for pair in range(args.pairs):
        # AB on even pairs, BA on odd ones, so neither side always runs first.
        order = SIDES if pair % 2 == 0 else tuple(reversed(SIDES))
        for side in order:
            stem = f"{side}-pair{pair:02d}"
            command = ["taskset", "-c", str(cpu), str(executables[side])] + selection_arguments(
                bundles, cases, args.calls
            )
            commands.append({"label": stem, "command": command})
            receipt = measure_run(
                executables[side],
                f"{side} pair {pair}",
                cpu,
                bundles,
                cases,
                args.calls,
                raw_dir,
                stem,
            )
            # One whole document or nothing: a missing, duplicated,
            # unexpected, malformed or unknown record fails here, before any
            # sample from this pair reaches the report.
            for case, elapsed, checksum in measurement_document(
                receipt, stem, plan, bundles
            ):
                samples[side].setdefault(case.name, []).append(elapsed)
                previous = checksums[side].get(case.name)
                if previous is None:
                    checksums[side][case.name] = checksum
                elif previous != checksum:
                    raise RunnerError(
                        f"{side} produced two different checksums for {case.name!r}: "
                        f"{previous} and {checksum}; the input is not deterministic"
                    )
            print(f"  {stem}: {len(plan.cases)} cases")

    divergent = [
        name
        for name in checksums["baseline"]
        if checksums["baseline"][name] != checksums["candidate"][name]
    ]
    if divergent:
        preview = ", ".join(divergent[:8])
        raise RunnerError(
            f"{len(divergent)} case(s) returned different results on the two builds: {preview}"
        )

    records = summarize(plan, samples, checksums, args.pairs)
    profiles: List[Dict[str, Any]] = []
    if profiled:
        profiles = run_profiles(
            args.perf,
            args.perf_mode,
            args.perf_events,
            executables,
            plan,
            checksums,
            profiled,
            args.perf_invocations,
            cpu,
            cases,
            args.calls,
            out_dir,
        )

    try:
        stamps = provenance(executables, sources, pathlib.Path(__file__).resolve())
    except OSError as error:
        raise RunnerError(f"could not fingerprint the round's provenance: {error}") from error
    quorum = max(1, args.pairs - 1)
    lines = report_lines(records, args.pairs, quorum)
    report = "\n".join(lines)
    (out_dir / "report.txt").write_text(report + "\n", encoding="utf-8")

    document = {
        "protocol": PROTOCOL_VERSION,
        "pairs": args.pairs,
        "bundles": bundles,
        "profiled_bundles": profiled,
        "perf_invocations": args.perf_invocations if profiled else 0,
        "target": plan.target,
        "cpu": plan.cpu,
        "optimize": plan.optimize,
        "approved_profile": plan.approved_profile,
        "pinned_cpu": cpu,
        "allowed_cpus": allowed,
        "harness_digest": plan.harness_digest,
        "canonical_cap": args.cap,
        "ledger": str(ledger.path),
        "provenance": stamps,
        "reserved": required,
        "consumed_before_run": consumed_before,
        "consumed_total": ledger.consumed(),
        "cases": records,
        "profiles": profiles,
        "raw_rows": "raw/",
        "report": str(out_dir / "report.txt"),
    }
    (out_dir / "results.json").write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (out_dir / "manifest.json").write_text(
        json.dumps(
            {
                "commands": commands + [dict(profile, label=f"perf-{profile['side']}-{profile['bundle']}-run{profile['invocation']}") for profile in profiles],
                "out_dir": str(out_dir),
                "python": sys.version.split()[0],
                "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                "ledger": str(ledger.path),
                "provenance": stamps,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    print(report)
    print(f"raw rows and report are under {out_dir}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RunnerError as error:
        print(f"run_api_round: {error}", file=sys.stderr)
        sys.exit(2)