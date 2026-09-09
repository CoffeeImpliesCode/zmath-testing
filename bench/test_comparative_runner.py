import json
import pathlib
import tempfile
import unittest
from typing import Any, Dict, Iterable, List, Mapping, Tuple

import run_comparative as runner

DatasetKey = Tuple[str, str, str]

def build_identity() -> Dict[str, str]:
    return {
        "mode": "ReleaseSafe",
        "target": "x86_64-linux-gnu.2.38",
        "compiler": "gcc",
        "compiler_version": "fixture-version",
        "cxx_flags": "fixture-flags",
    }


def dataset_digests() -> Dict[DatasetKey, str]:
    return {
        key: f"{index:016x}"
        for index, key in enumerate(runner.matrix_keys())
    }

def glibc_origins() -> List[Dict[str, str]]:
    path = "/fixture/libm.so.6"
    return [
        {"operation": operation, "format": fmt, "path": path}
        for operation in runner.OPERATIONS
        for fmt in runner.FORMATS
    ]

def provenance_document(origins: List[Dict[str, str]]) -> Dict[str, Any]:
    return {"glibc_provenance": {"version": "fixture-glibc-version", "origins": origins}}

def encode_digests(digests: Mapping[DatasetKey, str]) -> str:
    return ";".join(
        f"{operation}/{fmt}/{distribution}={digest}"
        for (operation, fmt, distribution), digest in digests.items()
    )


def encode_origins(origins: Iterable[Mapping[str, str]]) -> str:
    return ";".join(
        f"{origin['operation']}/{origin['format']}={origin['path']}"
        for origin in origins
    )

def benchmark_context(digests: Mapping[DatasetKey, str]) -> Dict[str, str]:
    build = build_identity()
    return {
        "comparison.mode": build["mode"],
        "comparison.target": build["target"],
        "comparison.compiler": build["compiler"],
        "comparison.compiler_version": build["compiler_version"],
        "comparison.cxx_flags": build["cxx_flags"],
        "comparison.batch_size": str(runner.BATCH_SIZE),
        "comparison.input_digests": encode_digests(digests),
        "comparison.glibc_version": "fixture-glibc-version",
        "comparison.glibc_origins": encode_origins(glibc_origins()),
    }


def accuracy_document(digests: Mapping[DatasetKey, str]) -> Dict[str, Any]:
    records = []
    for operation, fmt, distribution in runner.matrix_keys():
        for provider in runner.PROVIDERS:
            records.append(
                {
                    "operation": operation,
                    "format": fmt,
                    "distribution": distribution,
                    "provider": provider,
                    "input_hash": digests[(operation, fmt, distribution)],
                    "available": True,
                    "status": "audited",
                    "audit": {
                        "samples": runner.BATCH_SIZE,
                        "finite_compared": 0,
                        "max_ulp": 0,
                        "nonfinite_mismatches": 0,
                        "signed_zero_mismatches": 0,
                    },
                }
            )
    return {
        "schema": "zmath-comparative-accuracy-v1",
        "reference": {
            "kind": "MPFR",
            "precision_bits": 512,
            "rounding": "RNE",
            "formal_correct_rounding_proof": False,
        },
        "sample_count": runner.BATCH_SIZE,
        "providers": list(runner.PROVIDERS),
        "build": build_identity(),
        "glibc_provenance": {
            "version": "fixture-glibc-version",
            "origins": glibc_origins(),
        },
        "records": records,
    }


def timing_document(repetitions: int, indices: Iterable[Any]) -> Dict[str, Any]:
    # Zero is a schema sentinel. These tests do not report it as a measurement.
    return {
        "benchmarks": [
            {
                "name": "zmath/exp/f64/normal",
                "run_type": "iteration",
                "error_occurred": False,
                "iterations": 1,
                "repetitions": repetitions,
                "repetition_index": index,
                "cpu_time": 0,
                "time_unit": "ns",
            }
            for index in indices
        ]
    }


class ComparativeEvidenceLoaderTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = pathlib.Path(temporary.name)
        self.fixture_number = 0

    def write_fixture(self, value: Any) -> pathlib.Path:
        self.fixture_number += 1
        path = self.directory / f"fixture-{self.fixture_number}.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def load_context(self, context: Dict[str, str]) -> Dict[str, Any]:
        path = self.write_fixture({"context": context})
        return runner.load_benchmark_context(path)

    def test_one_and_five_repetition_evidence_is_accepted(self) -> None:
        key = ("exp", "f64", "normal", "zmath")
        for repetitions in (1, 5):
            with self.subTest(repetitions=repetitions):
                path = self.write_fixture(
                    timing_document(repetitions, range(repetitions))
                )
                timings = runner.load_timings(path, repetitions)
                self.assertEqual(set(timings), {key})
                self.assertEqual(len(timings[key]), repetitions)

    def test_missing_repetition_index_field_is_rejected(self) -> None:
        document = timing_document(1, [0])
        del document["benchmarks"][0]["repetition_index"]
        with self.assertRaises(runner.RunnerError):
            runner.load_timings(self.write_fixture(document), 1)

    def test_missing_repetition_index_in_sequence_is_rejected(self) -> None:
        document = timing_document(5, [0, 1, 2, 4])
        with self.assertRaises(runner.RunnerError):
            runner.load_timings(self.write_fixture(document), 5)

    def test_duplicate_repetition_index_is_rejected(self) -> None:
        document = timing_document(2, [0, 0])
        with self.assertRaises(runner.RunnerError):
            runner.load_timings(self.write_fixture(document), 2)

    def test_shifted_repetition_indices_are_rejected(self) -> None:
        document = timing_document(5, [1, 2, 3, 4, 5])
        with self.assertRaises(runner.RunnerError):
            runner.load_timings(self.write_fixture(document), 5)

    def test_noninteger_repetition_index_is_rejected(self) -> None:
        document = timing_document(1, ["0"])
        with self.assertRaises(runner.RunnerError):
            runner.load_timings(self.write_fixture(document), 1)

    def test_incorrect_requested_repetition_count_is_rejected(self) -> None:
        document = timing_document(1, [0])
        with self.assertRaises(runner.RunnerError):
            runner.load_timings(self.write_fixture(document), 5)

    def test_wrong_batch_size_is_rejected(self) -> None:
        context = benchmark_context(dataset_digests())
        context["comparison.batch_size"] = "512"
        with self.assertRaises(runner.RunnerError):
            runner.load_context_input_digests(self.load_context(context))

    def test_mismatched_dataset_digest_is_rejected(self) -> None:
        context_digests = dataset_digests()
        accuracy_digests = dict(context_digests)
        accuracy_digests[next(iter(accuracy_digests))] = "ffffffffffffffff"
        accuracy = runner.load_accuracy(
            self.write_fixture(accuracy_document(accuracy_digests))
        )
        context = self.load_context(benchmark_context(context_digests))
        with self.assertRaises(runner.RunnerError):
            runner.validate_benchmark_context(accuracy, context)

    def test_missing_dataset_digest_is_rejected(self) -> None:
        context = benchmark_context(dataset_digests())
        entries = context["comparison.input_digests"].split(";")
        context["comparison.input_digests"] = ";".join(entries[:-1])
        with self.assertRaises(runner.RunnerError):
            runner.load_context_input_digests(self.load_context(context))

    def test_extra_dataset_digest_is_rejected(self) -> None:
        context = benchmark_context(dataset_digests())
        context["comparison.input_digests"] += ";extra/f64/normal=aaaaaaaaaaaaaaaa"
        with self.assertRaises(runner.RunnerError):
            runner.load_context_input_digests(self.load_context(context))

    def test_inconsistent_build_identity_is_rejected(self) -> None:
        accuracy_path = self.write_fixture({"build": build_identity()})
        context = benchmark_context(dataset_digests())
        context["comparison.target"] = "different-target"
        with self.assertRaises(runner.RunnerError):
            runner.reconcile_build(
                runner.load_binary_build(accuracy_path), self.load_context(context)
            )

    def test_inconsistent_provenance_identity_is_rejected(self) -> None:
        accuracy_path = self.write_fixture(provenance_document(glibc_origins()))
        context = benchmark_context(dataset_digests())
        context["comparison.glibc_version"] = "different-glibc-version"
        with self.assertRaises(runner.RunnerError):
            runner.reconcile_glibc_provenance(
                runner.load_accuracy_provenance(accuracy_path),
                runner.load_context_glibc_provenance(self.load_context(context)),
            )

    def test_missing_origin_row_is_rejected(self) -> None:
        document = provenance_document(glibc_origins()[:-1])
        with self.assertRaises(runner.RunnerError):
            runner.load_accuracy_provenance(self.write_fixture(document))

    def test_duplicate_origin_row_is_rejected(self) -> None:
        origins = glibc_origins()
        origins[-1] = origins[0]
        context = benchmark_context(dataset_digests())
        context["comparison.glibc_origins"] = encode_origins(origins)
        with self.assertRaises(runner.RunnerError):
            runner.load_context_glibc_provenance(self.load_context(context))

    def test_coefficient_of_variation_uses_mean_not_median(self) -> None:
        accuracy = runner.load_accuracy(
            self.write_fixture(accuracy_document(dataset_digests()))
        )
        for samples, expected_cv in (([1, 1, 1, 1, 6], 111.80),
                                     ([0, 0, 0, 0, 5], 223.61)):
            with self.subTest(samples=samples):
                lines = runner.report_lines(
                    accuracy, {("exp", "f64", "normal", "zmath"): samples},
                    "zmath/exp/f64/normal", False, {"zmath/exp/f64/normal"},
                )
                row = next(line.split() for line in lines
                           if line.split()[:4] == ["exp", "f64", "normal", "zmath"])
                self.assertAlmostEqual(float(row[7]), expected_cv, places=2)

if __name__ == "__main__":
    unittest.main()
