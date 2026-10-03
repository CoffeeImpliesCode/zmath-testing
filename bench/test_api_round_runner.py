"""Tests for the API round runner's budget, plan and mismatch handling.

Every case here is a boundary a consumer of the round's receipts can observe:
what a global f32 ledger allows across separate rounds, what a round refuses to
do, and what a measurement receipt has to contain before the runner believes
it. Nothing reads a source file's text, nothing asserts on a message string,
and nothing re-states a default the module already publishes -- a test that
only echoed the runner back would pass with every one of the defects below
still in place.
"""

import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import run_api_round as runner


BENCH = pathlib.Path(__file__).resolve().parent
RUNNER = str(pathlib.Path(runner.__file__).resolve())
HARNESS = "0123456789abcdef"
TARGET = "x86_64-linux-gnu.2.38"


def build_line(protocol=runner.PROTOCOL_VERSION, harness=HARNESS, approved=True):
    return {
        "kind": "build",
        "protocol": protocol,
        "target": TARGET,
        "cpu": "haswell",
        "optimize": "ReleaseSafe",
        "approved_profile": approved,
        "harness_digest": harness,
    }


def case_line(
    name="leaf.scalar.expf.f32.normal",
    namespace="scalar",
    bundle="leaf",
    calls=32,
    f32=(("expf", 1),),
    digest="1111111111111111",
):
    return {
        "kind": "case",
        "name": name,
        "namespace": namespace,
        "bundle": bundle,
        "calls": calls,
        "f32": [{"operation": operation, "count": count} for operation, count in f32],
        "f32_total": sum(count for _, count in f32),
        "input_digest": digest,
    }


def row_line(**overrides):
    record = dict(case_line())
    record["kind"] = "row"
    record.update(overrides)
    return record


def rows_for(cases, **overrides):
    """The measurement rows a round binary would emit for `cases`."""
    rows = []
    for case in cases:
        row = {key: value for key, value in case.items() if key != "kind"}
        row["kind"] = "row"
        row.update(elapsed_ns=10, checksum="0" * 16)
        row.update(overrides)
        rows.append(row)
    return rows


def summary_line(cases, calls_total=32, f32_total=1, kind="list"):
    return {
        "kind": "summary",
        "mode": kind,
        "cases": cases,
        "calls_total": calls_total,
        "f32_total": f32_total,
        "f32": [],
        "bundles": ["leaf"],
    }


def aggregate_summary(records, mode):
    """The summary line a correct round binary derives from its own records."""
    calls_total = 0
    f32_total = 0
    charges = {}
    bundles = []
    for record in records:
        calls_total += record["calls"]
        f32_total += record["f32_total"]
        for charge in record["f32"]:
            operation = charge["operation"]
            charges[operation] = charges.get(operation, 0) + charge["count"]
        if record["bundle"] not in bundles:
            bundles.append(record["bundle"])
    return {
        "kind": "summary",
        "mode": mode,
        "cases": len(records),
        "calls_total": calls_total,
        "f32_total": f32_total,
        "f32": [
            {"operation": operation, "count": count}
            for operation, count in sorted(charges.items())
        ],
        "bundles": bundles,
    }


def document_text(records, mode, summary=None, build=None):
    lines = [] if build is None else [json.dumps(build)]
    lines.extend(json.dumps(record) for record in records)
    lines.append(json.dumps(aggregate_summary(records, mode) if summary is None else summary))
    return "\n".join(lines) + "\n"


def listing_text(records, summary=None):
    return document_text(records, "list", summary=summary)


def one_case_plan(case=None, summary=None, **overrides):
    record = case if case is not None else case_line(**overrides)
    return runner.parse_plan(document_text([record], "list", summary, build_line()), "listing")


def two_bundle_plan():
    """One profiled case in `leaf` and one unprofiled case in `values`."""
    cases = [
        case_line(name="leaf.scalar.expf.f32.normal", f32=(("expf", 1),)),
        case_line(
            name="values.scalar.fadd.f32.normal",
            bundle="values",
            f32=(("fadd", 1),),
            digest="2222222222222222",
        ),
    ]
    return runner.parse_plan(document_text(cases, "list", build=build_line()), "listing")


class LedgerBudgetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = pathlib.Path(tempfile.mkdtemp(prefix="api-round-ledger-"))
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        self.path = self.directory / "ledger.jsonl"

    def test_a_reservation_is_durable_and_reported_as_consumed(self) -> None:
        ledger = runner.Ledger(self.path, cap=1000)
        ledger.reserve({"expf": 40}, "round")
        self.assertEqual(ledger.consumed(), {"expf": 40})
        self.assertEqual(ledger.remaining(), {"expf": 960})
        self.assertEqual(runner.Ledger(self.path, cap=1000).consumed(), {"expf": 40})
        records = [
            json.loads(line)
            for line in self.path.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual([(record["operation"], record["count"]) for record in records], [("expf", 40)])

    def test_exceeding_the_cap_fails_closed_and_writes_nothing(self) -> None:
        ledger = runner.Ledger(self.path, cap=100)
        ledger.reserve({"expf": 90}, "round")
        with self.assertRaises(runner.RunnerError):
            ledger.reserve({"expf": 11}, "round")
        self.assertEqual(ledger.consumed(), {"expf": 90})
        self.assertEqual(len(self.path.read_text(encoding="utf-8").splitlines()), 1)

    def test_one_overspending_operation_blocks_the_whole_batch(self) -> None:
        ledger = runner.Ledger(self.path, cap=100)
        with self.assertRaises(runner.RunnerError):
            ledger.reserve({"expf": 50, "sinf": 200}, "round")
        self.assertEqual(ledger.consumed(), {})
        self.assertFalse(self.path.exists())

    def test_a_failed_attempt_is_never_refunded(self) -> None:
        runner.Ledger(self.path, cap=100).reserve({"expf": 60}, "round")
        # A round that then dies has no refund path, so the next round sees the
        # whole 60 spent including the attempt that produced nothing.
        reopened = runner.Ledger(self.path, cap=100)
        self.assertEqual(reopened.remaining(), {"expf": 40})
        with self.assertRaises(runner.RunnerError):
            reopened.reserve({"expf": 41}, "round")

    def test_a_non_positive_reservation_is_rejected(self) -> None:
        ledger = runner.Ledger(self.path, cap=100)
        for bad in (0, -1):
            with self.subTest(count=bad):
                with self.assertRaises(runner.RunnerError):
                    ledger.reserve({"expf": bad}, "round")
        self.assertFalse(self.path.exists())

    def test_a_corrupt_ledger_is_rejected_rather_than_reinterpreted(self) -> None:
        self.path.write_text("{not json}\n", encoding="utf-8")
        with self.assertRaises(runner.RunnerError):
            runner.Ledger(self.path, cap=100)

    def test_an_empty_reservation_costs_nothing(self) -> None:
        ledger = runner.Ledger(self.path, cap=100)
        ledger.reserve({}, "round")
        self.assertFalse(self.path.exists())

    def test_a_cap_above_the_approved_ceiling_is_refused(self) -> None:
        with self.assertRaises(runner.RunnerError):
            runner.Ledger(self.path, cap=runner.CANONICAL_CAP + 1)

    def test_a_budget_check_that_would_overspend_spends_nothing(self) -> None:
        ledger = runner.Ledger(self.path, cap=100)
        ledger.reserve({"expf": 90}, "round")
        before = self.path.read_bytes()
        with self.assertRaises(runner.RunnerError):
            ledger.check({"expf": 11})
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(runner.Ledger(self.path, cap=100).consumed(), {"expf": 90})

    def test_a_budget_check_admits_a_batch_that_exactly_fits(self) -> None:
        ledger = runner.Ledger(self.path, cap=100)
        ledger.check({"expf": 100})
        self.assertFalse(self.path.exists())
        ledger.reserve({"expf": 100}, "round")
        with self.assertRaises(runner.RunnerError):
            ledger.check({"expf": 1})


class ReservationArithmeticTests(unittest.TestCase):
    def test_a_case_run_costs_count_times_calls(self) -> None:
        case = one_case_plan(calls=8, f32=(("expf", 3), ("fadd", 5))).cases[0]
        self.assertEqual(case.run_cost(), {"expf": 24, "fadd": 40})

    def test_a_case_costs_count_times_calls_times_both_sides(self) -> None:
        plan = one_case_plan(calls=8, f32=(("expf", 3),))
        self.assertEqual(runner.required_reservations(plan, 9), {"expf": 3 * 8 * 2 * 9})

    def test_lane_and_transitive_counts_are_not_divided_back_out(self) -> None:
        plan = one_case_plan(bundle="lanes", f32=(("expf", 4), ("fadd", 8)))
        self.assertEqual(
            runner.required_reservations(plan, 2),
            {"expf": 4 * 32 * 4, "fadd": 8 * 32 * 4},
        )

    def test_a_selection_that_reaches_no_f32_kernel_needs_no_budget(self) -> None:
        self.assertEqual(runner.required_reservations(one_case_plan(f32=()), 9), {})

    def test_profiled_bundles_add_their_declared_invocations(self) -> None:
        plan = one_case_plan()
        measured = 32 * 2 * 3
        self.assertEqual(runner.required_reservations(plan, 3), {"expf": measured})
        self.assertEqual(
            runner.required_reservations(
                plan, pairs=3, profile_invocations=2, profile_bundles=["leaf"]
            ),
            {"expf": measured + 32 * 2 * 2},
        )

    def test_measured_cases_outside_the_profiled_subset_are_still_charged(self) -> None:
        plan = two_bundle_plan()
        required = runner.required_reservations(
            plan, pairs=1, profile_invocations=2, profile_bundles=["leaf"]
        )
        # `values` is measured on both sides of the only pair and is never
        # profiled, so it owes exactly that; `leaf` owes the pair plus its
        # declared profiler invocations. Narrowing the profiler must never
        # narrow what the round has paid for.
        self.assertEqual(
            required,
            {"expf": 32 * (2 * 1 + 2 * 2), "fadd": 32 * 2 * 1},
        )


class PlanParsingTests(unittest.TestCase):
    def test_a_foreign_protocol_version_is_refused(self) -> None:
        text = json.dumps(build_line(protocol=runner.PROTOCOL_VERSION + 1)) + "\n"
        text += listing_text([case_line()])
        with self.assertRaises(runner.RunnerError):
            runner.parse_plan(text, "listing")

    def test_a_non_approved_profile_is_refused(self) -> None:
        text = json.dumps(build_line(approved=False)) + "\n"
        text += listing_text([case_line()])
        with self.assertRaises(runner.RunnerError):
            runner.parse_plan(text, "listing")

    def test_a_bundle_label_is_not_a_namespace(self) -> None:
        with self.assertRaises(runner.RunnerError):
            one_case_plan(namespace="leaf")

    def test_a_slice_label_is_not_a_bundle(self) -> None:
        with self.assertRaises(runner.RunnerError):
            one_case_plan(bundle="root")

    def test_a_duplicate_case_name_is_refused(self) -> None:
        with self.assertRaises(runner.RunnerError):
            runner.parse_plan(
                document_text(
                    [case_line(), case_line()], "list", build=build_line()
                ),
                "listing",
            )

    def test_a_summary_that_disagrees_with_its_rows_is_refused(self) -> None:
        with self.assertRaises(runner.RunnerError):
            one_case_plan(summary=summary_line(3, 32, 1))

    def test_a_charged_operation_may_not_be_charged_twice(self) -> None:
        with self.assertRaises(runner.RunnerError):
            one_case_plan(f32=(("expf", 1), ("expf", 2)))

    def test_a_charge_total_that_does_not_sum_is_refused(self) -> None:
        case = case_line()
        case["f32_total"] = 9
        with self.assertRaises(runner.RunnerError):
            one_case_plan(case=case)

    def test_a_missing_summary_is_refused(self) -> None:
        text = json.dumps(build_line()) + "\n" + json.dumps(case_line()) + "\n"
        with self.assertRaises(runner.RunnerError):
            runner.parse_plan(text, "listing")

    def test_a_missing_build_line_is_refused(self) -> None:
        with self.assertRaises(runner.RunnerError):
            runner.parse_plan(listing_text([case_line()]), "listing")


class PlanComparisonTests(unittest.TestCase):
    def test_a_different_case_name_is_refused(self) -> None:
        other = one_case_plan(name="leaf.scalar.logf.f32.normal")
        with self.assertRaises(runner.RunnerError):
            runner.compare_plans(one_case_plan(), other)

    def test_a_different_call_count_is_refused(self) -> None:
        with self.assertRaises(runner.RunnerError):
            runner.compare_plans(one_case_plan(), one_case_plan(calls=8))

    def test_a_different_charge_count_is_refused(self) -> None:
        with self.assertRaises(runner.RunnerError):
            runner.compare_plans(one_case_plan(), one_case_plan(f32=(("expf", 4),)))

    def test_a_different_harness_digest_is_refused(self) -> None:
        text = json.dumps(build_line(harness="fedcba9876543210")) + "\n"
        other = runner.parse_plan(text + listing_text([case_line()]), "listing")
        with self.assertRaises(runner.RunnerError):
            runner.compare_plans(one_case_plan(), other)

    def test_a_different_build_target_is_refused(self) -> None:
        text = json.dumps(dict(build_line(), target="aarch64-linux-gnu.2.38")) + "\n"
        other = runner.parse_plan(text + listing_text([case_line()]), "listing")
        with self.assertRaises(runner.RunnerError):
            runner.compare_plans(one_case_plan(), other)


class MeasurementRowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.case = one_case_plan().cases[0]

    def timed(self, row):
        return runner.timed_row(row, self.case, "baseline pair 0")

    def test_a_row_with_a_different_call_count_is_refused(self) -> None:
        with self.assertRaises(runner.RunnerError):
            self.timed(row_line(calls=8, elapsed_ns=1, checksum="0" * 16))

    def test_a_row_with_a_different_charge_plan_is_refused(self) -> None:
        row = row_line(elapsed_ns=1, checksum="0" * 16)
        row["f32"] = [{"operation": "expf", "count": 2}]
        row["f32_total"] = 2
        with self.assertRaises(runner.RunnerError):
            self.timed(row)

    def test_a_row_with_a_different_input_digest_is_refused(self) -> None:
        with self.assertRaises(runner.RunnerError):
            self.timed(
                row_line(elapsed_ns=1, checksum="0" * 16, input_digest="9" * 16)
            )

    def test_a_listing_line_is_not_accepted_as_a_measurement(self) -> None:
        with self.assertRaises(runner.RunnerError):
            self.timed(case_line())

    def test_a_row_without_a_checksum_is_refused(self) -> None:
        row = row_line(elapsed_ns=1)
        with self.assertRaises(runner.RunnerError):
            self.timed(row)

    def test_a_row_without_a_positive_elapsed_time_is_refused(self) -> None:
        with self.assertRaises(runner.RunnerError):
            self.timed(row_line(elapsed_ns=0, checksum="0" * 16))


class DocumentModeTests(unittest.TestCase):
    """A plan and a measurement receipt are different documents, not two labels.

    A mode is spoken twice -- by each record's `kind` and by the summary's own
    `mode` -- and neither may be satisfied by the other. Reading the wrong
    field here is how a listing passes as a receipt, or the reverse.
    """

    def listing(self):
        return document_text([case_line()], "list", build=build_line())

    def receipt(self):
        return document_text(rows_for([case_line()]), "measure", build=build_line())

    def test_a_listing_parses_when_a_listing_is_demanded(self) -> None:
        plan = runner.parse_plan(self.listing(), "listing", "list")
        self.assertEqual(len(plan.cases), 1)
        self.assertEqual(plan.cases[0].name, "leaf.scalar.expf.f32.normal")

    def test_a_receipt_parses_when_a_receipt_is_demanded(self) -> None:
        plan = runner.parse_plan(self.receipt(), "receipt", "measure")
        self.assertEqual(len(plan.cases), 1)

    def test_a_listing_is_refused_where_a_receipt_is_demanded(self) -> None:
        with self.assertRaises(runner.RunnerError):
            runner.parse_plan(self.listing(), "receipt", "measure")

    def test_a_receipt_is_refused_where_a_listing_is_demanded(self) -> None:
        with self.assertRaises(runner.RunnerError):
            runner.parse_plan(self.receipt(), "listing", "list")

    def test_a_summary_that_claims_the_other_mode_is_refused(self) -> None:
        text = document_text(
            [case_line()],
            "list",
            summary_line(1, 32, 1, kind="measure"),
            build_line(),
        )
        with self.assertRaises(runner.RunnerError):
            runner.parse_plan(text, "listing", "list")

    def test_an_unknown_document_mode_is_refused(self) -> None:
        with self.assertRaises(runner.RunnerError):
            runner.parse_plan(self.listing(), "listing", "measure-everything")


class ReceiptDocumentTests(unittest.TestCase):
    """One whole measurement receipt, judged against the listing it claims."""

    def setUp(self) -> None:
        self.plan = one_case_plan()
        self.bundles = ["leaf"]

    def receipt(self, rows=None, summary=None, build=None):
        return document_text(
            rows_for([case_line()]) if rows is None else rows,
            "measure",
            summary,
            build=build_line() if build is None else build,
        )

    def judged(self, text):
        return runner.measurement_document(text, "baseline pair 0", self.plan, self.bundles)

    def refused(self, text) -> None:
        with self.assertRaises(runner.RunnerError):
            self.judged(text)

    def test_a_receipt_that_matches_the_listing_yields_its_timed_rows(self) -> None:
        timed = self.judged(self.receipt())
        self.assertEqual(
            [(case.name, elapsed, checksum) for case, elapsed, checksum in timed],
            [("leaf.scalar.expf.f32.normal", 10, "0" * 16)],
        )

    def test_a_repeated_case_is_refused(self) -> None:
        row = row_line(elapsed_ns=10, checksum="0" * 16)
        self.refused(self.receipt(rows=[row, row]))

    def test_a_case_the_round_never_planned_is_refused(self) -> None:
        stray = row_line(
            name="leaf.scalar.logf.f32.normal", elapsed_ns=10, checksum="0" * 16
        )
        self.refused(self.receipt(rows=rows_for([case_line()]) + [stray]))

    def test_a_receipt_that_omits_a_planned_case_is_refused(self) -> None:
        self.refused(self.receipt(rows=[]))

    def test_a_listing_line_in_a_receipt_is_refused(self) -> None:
        self.refused(self.receipt(rows=[case_line()]))

    def test_a_receipt_from_another_harness_is_refused(self) -> None:
        self.refused(self.receipt(build=dict(build_line(), harness_digest="fedcba9876543210")))

    def test_a_receipt_from_another_optimize_mode_is_refused(self) -> None:
        self.refused(self.receipt(build=dict(build_line(), optimize="Debug")))

    def test_a_summary_that_undercounts_its_charges_is_refused(self) -> None:
        summary = aggregate_summary(rows_for([case_line()]), "measure")
        summary["f32_total"] = 9
        self.refused(self.receipt(summary=summary))

    def test_a_summary_that_names_cohorts_this_round_did_not_select_is_refused(self) -> None:
        summary = aggregate_summary(rows_for([case_line()]), "measure")
        summary["bundles"] = ["leaf", "values"]
        self.refused(self.receipt(summary=summary))


class VerdictTests(unittest.TestCase):
    """The direction a round publishes, read back from real paired samples.

    Every case here hands `summarize` the pairs a round actually measured and
    asserts on the record a consumer of `results.json` gets. That is where the
    direction has to be right: a pair that tied is evidence neither way, and a
    record that counts it as a loss manufactures a regression quorum.
    """

    def record(self, baseline, candidate):
        plan = one_case_plan()
        name = plan.cases[0].name
        records = runner.summarize(
            plan,
            {
                "baseline": {name: list(baseline)},
                "candidate": {name: list(candidate)},
            },
            {"baseline": {name: "0" * 16}, "candidate": {name: "0" * 16}},
            len(baseline),
        )
        self.assertEqual(len(records), 1)
        return records[0]

    def test_a_real_improvement_with_a_quorum_is_faster(self) -> None:
        record = self.record([100] * 9, [95] * 9)
        self.assertEqual((record["faster_pairs"], record["slower_pairs"]), (9, 0))
        self.assertEqual(record["verdict"], "faster")

    def test_a_change_below_the_practical_threshold_is_undecided(self) -> None:
        record = self.record([100] * 9, [99] * 9)
        self.assertEqual(record["faster_pairs"], 9)
        self.assertEqual(record["verdict"], "undecided")

    def test_a_large_change_without_a_quorum_is_undecided(self) -> None:
        record = self.record([100] * 9, [95] * 7 + [105] * 2)
        self.assertEqual((record["faster_pairs"], record["slower_pairs"]), (7, 2))
        self.assertEqual(record["verdict"], "undecided")

    def test_a_regression_is_reported_and_not_swallowed(self) -> None:
        record = self.record([100] * 9, [105] * 9)
        self.assertEqual((record["faster_pairs"], record["slower_pairs"]), (0, 9))
        self.assertEqual(record["verdict"], "slower")

    def test_the_quorum_scales_with_the_pair_count(self) -> None:
        three = self.record([100] * 3, [95] * 2 + [100])
        self.assertEqual(three["verdict"], "faster")
        # Four pairs need three of them, so the same two wins no longer qualify.
        four = self.record([100] * 4, [95] * 2 + [100] * 2)
        self.assertEqual((four["faster_pairs"], four["slower_pairs"]), (2, 0))
        self.assertEqual(four["verdict"], "undecided")

    def test_tied_pairs_cannot_stand_in_for_a_slower_quorum(self) -> None:
        record = self.record([100] * 9, [105] * 5 + [100] * 4)
        # The medians say the candidate got 5% slower, but only five pairs
        # went that way and four tied, so there is no regression to report.
        self.assertLess(record["improvement"], -runner.PRACTICAL_THRESHOLD)
        self.assertEqual((record["faster_pairs"], record["slower_pairs"]), (0, 5))
        self.assertEqual(record["verdict"], "undecided")

    def test_eight_slower_pairs_and_one_tie_meet_the_regression_quorum(self) -> None:
        record = self.record([100] * 9, [105] * 8 + [100])
        self.assertEqual((record["faster_pairs"], record["slower_pairs"]), (0, 8))
        self.assertEqual(record["verdict"], "slower")

    def test_eight_faster_pairs_and_one_tie_meet_the_improvement_quorum(self) -> None:
        record = self.record([100] * 9, [95] * 8 + [100])
        self.assertEqual((record["faster_pairs"], record["slower_pairs"]), (8, 0))
        self.assertEqual(record["verdict"], "faster")

    def test_a_round_in_which_nothing_moved_has_no_direction(self) -> None:
        record = self.record([100] * 9, [100] * 9)
        self.assertEqual((record["faster_pairs"], record["slower_pairs"]), (0, 0))
        self.assertEqual(record["verdict"], "undecided")


class SelectionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = pathlib.Path(tempfile.mkdtemp(prefix="api-round-args-"))
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        self.ledger = self.directory / "ledger.jsonl"

    def namespace(self, *extra):
        return runner.parse_args(
            [
                "--baseline-exe",
                "/bin/true",
                "--candidate-exe",
                "/bin/true",
                "--out-dir",
                str(self.directory / "round"),
                "--ledger",
                str(self.ledger),
                *extra,
            ]
        )

    def test_out_dir_inside_the_repository_is_refused(self) -> None:
        root = runner.repo_root()
        namespace = runner.parse_args(
            [
                "--baseline-exe",
                "/bin/true",
                "--candidate-exe",
                "/bin/true",
                "--out-dir",
                str(root / "bench" / "results"),
                "--ledger",
                str(self.ledger),
            ]
        )
        with self.assertRaises(runner.RunnerError):
            runner.validate_args(namespace, root)

    def test_a_ledger_beside_the_results_it_pays_for_is_refused(self) -> None:
        namespace = runner.parse_args(
            [
                "--baseline-exe",
                "/bin/true",
                "--candidate-exe",
                "/bin/true",
                "--out-dir",
                str(self.directory / "round"),
                "--ledger",
                str(self.directory / "round" / "ledger.jsonl"),
            ]
        )
        out_dir = runner.validate_args(namespace, runner.repo_root())
        with self.assertRaises(runner.RunnerError):
            runner.resolve_ledger(namespace, out_dir)

    def test_a_ledger_outside_the_out_dir_is_the_one_that_gets_spent(self) -> None:
        namespace = self.namespace()
        out_dir = runner.validate_args(namespace, runner.repo_root())
        self.assertEqual(runner.resolve_ledger(namespace, out_dir), self.ledger.resolve())

    def test_every_path_argument_has_to_be_supplied(self) -> None:
        supplied = {
            "--baseline-exe": "/bin/true",
            "--candidate-exe": "/bin/true",
            "--out-dir": str(self.directory / "round"),
            "--ledger": str(self.ledger),
        }
        for missing in supplied:
            with self.subTest(missing=missing):
                argv = []
                for flag, value in supplied.items():
                    if flag != missing:
                        argv.extend([flag, value])
                with self.assertRaises(SystemExit):
                    runner.parse_args(argv)

    def test_nonsensical_counts_are_refused(self) -> None:
        root = runner.repo_root()
        for option in ("--pairs", "--calls", "--cap", "--perf-invocations"):
            with self.subTest(option=option):
                with self.assertRaises(runner.RunnerError):
                    runner.validate_args(self.namespace(option, "0"), root)

    def test_a_cap_above_the_approved_ceiling_is_refused(self) -> None:
        with self.assertRaises(runner.RunnerError):
            runner.validate_args(
                self.namespace("--cap", str(runner.CANONICAL_CAP + 1)),
                runner.repo_root(),
            )

    def test_a_cpu_outside_the_affinity_mask_is_refused(self) -> None:
        allowed = sorted(os.sched_getaffinity(0))
        outside = max(allowed) + 1024
        with self.assertRaises(runner.RunnerError):
            runner.select_cpu(outside)

    def test_bundle_selection_keeps_the_canonical_order(self) -> None:
        namespace = self.namespace("--bundle", "values", "--bundle", "leaf")
        self.assertEqual(runner.selected_bundles(namespace), ["leaf", "values"])

    def test_profiling_a_bundle_outside_the_selection_is_refused(self) -> None:
        namespace = self.namespace(
            "--bundle",
            "leaf",
            "--perf-mode",
            "stat",
            "--perf-bundle",
            "algebra",
        )
        with self.assertRaises(runner.RunnerError):
            runner.profile_bundles(namespace, runner.selected_bundles(namespace))

    def test_profiling_the_whole_selection_is_accepted(self) -> None:
        namespace = self.namespace("--bundle", "leaf", "--perf-mode", "stat")
        self.assertEqual(
            runner.profile_bundles(namespace, runner.selected_bundles(namespace)),
            ["leaf"],
        )


# ---------------------------------------------------------------------------
# Whole-round fixtures
# ---------------------------------------------------------------------------

STUB_SOURCE = """#!{python}
import json
import pathlib
import sys

payload = json.loads(pathlib.Path("{payload}").read_text(encoding="utf-8"))
argv = sys.argv[1:]
listing = bool(argv) and argv[0] == "--list"
slices = ""
names = []
for argument in argv:
    if argument.startswith("--slice="):
        slices = argument.split("=", 1)[1]
    elif argument.startswith("--case="):
        names.append(argument.split("=", 1)[1])
with open(payload["log"], "a", encoding="utf-8") as stream:
    stream.write("--list" if listing else "measure")
    stream.write("\\n")
with open(payload["argv_log"], "a", encoding="utf-8") as stream:
    stream.write(json.dumps(argv))
    stream.write("\\n")


def selected(text, mode):
    # The document a `--case` cohort publishes. A cohort selects exactly the
    # cases it names out of the ones the selected slices publish, a name a
    # selected slice publishes nothing under is refused before a row is
    # printed, and the summary aggregates the rows that survived, because the
    # runner judges a summary against the plan it listed.
    build = []
    records = []
    for line in text.splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        if record.get("kind") == "build":
            build.append(line)
        elif record.get("kind") != "summary":
            records.append(record)
    chosen = [record for record in records
              if record["bundle"] in slices.split(",") and record["name"] in names]
    unpublished = [name for name in names
                   if not any(record["name"] == name for record in chosen)]
    if unpublished:
        sys.stderr.write("no such case: " + ", ".join(unpublished) + "\\n")
        sys.exit(1)
    charges = {{}}
    for record in chosen:
        for charge in record["f32"]:
            charges[charge["operation"]] = charges.get(charge["operation"], 0) + charge["count"]
    summary = {{
        "kind": "summary",
        "mode": mode,
        "cases": len(chosen),
        "calls_total": sum(record["calls"] for record in chosen),
        "f32_total": sum(charge["count"] for record in chosen for charge in record["f32"]),
        "f32": [{{"operation": operation, "count": count}}
                for operation, count in sorted(charges.items())],
        "bundles": slices.split(","),
    }}
    lines = build + [json.dumps(record) for record in chosen] + [json.dumps(summary)]
    return "\\n".join(lines) + "\\n"


if listing:
    sys.stdout.write(selected(payload["list"], "list") if names else payload["list"])
    sys.exit(payload["list_exit"])
# A run over one cohort publishes that cohort's cases and no others, which is
# what makes a profiled invocation differ from a measurement pair.
measured = payload["measure"]
if slices in payload["slice_documents"]:
    measured = payload["slice_documents"][slices]
sys.stdout.write(selected(measured, "measure") if names else measured)
sys.exit(payload["measure_exit"])
"""

RESERVE_SOURCE = """import pathlib
import sys
import time

sys.path.insert(0, {bench!r})
import run_api_round as runner

path = pathlib.Path(sys.argv[1])
gate = pathlib.Path(sys.argv[2])
label = sys.argv[3]
count = int(sys.argv[4])
cap = int(sys.argv[5])

ledger = runner.Ledger(path, cap=cap)
# Rendezvous: both processes have read the ledger before either one appends, so
# a reservation that only checks what it read at construction cannot pass here.
gate.with_name(gate.name + "." + label).write_text("", encoding="utf-8")
deadline = time.monotonic() + 120.0
while len(list(gate.parent.glob(gate.name + ".*"))) < 2 and time.monotonic() < deadline:
    time.sleep(0.002)
try:
    ledger.reserve({{"expf": count}}, label)
except runner.RunnerError:
    sys.exit(3)
sys.exit(0)
"""


def write_executable(directory: pathlib.Path, name: str, body: str) -> pathlib.Path:
    path = directory / name
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


# A profiler is the one part of a round this repository cannot own: it is a
# program on the host that this launch happens under. This fixture is that
# program. It does what a profiler does to the round binary -- it launches it
# as a real child process and keeps what that child reported -- and nothing
# else: no PMU, no `perf`, no zmath kernel, no inspection of the runner's text.
# The only thing a test may change is the receipt the profiler hands back and
# the exit code it returns, so a defect this fixture can expose is a defect in
# what the runner does with a profiler's report, not in what a fake invented.
PERF_SOURCE = '''#!@@PYTHON@@
"""A stand-in for perf, launched the way the runner launches perf."""

import json
import pathlib
import subprocess
import sys


def cohort(command):
    """The selection this invocation was told to profile."""
    for argument in command:
        if argument.startswith("--slice="):
            return argument.split("=", 1)[1]
    return ""


def counters(options):
    """Report back the counters that were asked for, and nothing else."""
    if "-e" not in options:
        return "# no events requested\\n"
    events = options[options.index("-e") + 1]
    return "".join(
        "%d,,%s,1000000,100.00\\n" % (1000 + index, event)
        for index, event in enumerate(name for name in events.split(",") if name)
    )


def damage(text, how):
    """Damage what the child reported, never the work that produced it."""
    lines = text.splitlines(True)
    if how == "truncated":
        # The receipt stops halfway through the document it began.
        return "".join(lines[: max(1, len(lines) // 2)])
    if how == "garbled":
        # The last line is no longer JSON.
        lines[-1] = "?" + lines[-1][1:]
        return "".join(lines)
    if how == "divergent":
        rewritten = []
        for line in lines:
            try:
                record = json.loads(line)
            except ValueError:
                rewritten.append(line)
                continue
            if record.get("kind") == "row":
                record["checksum"] = "".join(
                    "0" if digit == "1" else "1"
                    for digit in record.get("checksum", "")
                )
            rewritten.append(json.dumps(record) + "\\n")
        return "".join(rewritten)
    return text


def main():
    payload = json.loads(pathlib.Path("@@PAYLOAD@@").read_text(encoding="utf-8"))
    argv = sys.argv[1:]
    if "--" not in argv:
        sys.exit(64)
    split = argv.index("--")
    options, command = argv[:split], argv[split + 1:]

    child = subprocess.run(command, capture_output=True, text=True)
    if "-o" in options:
        target = pathlib.Path(options[options.index("-o") + 1])
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(counters(options), encoding="utf-8")

    sys.stdout.write(damage(child.stdout, payload["damage"]))
    sys.stderr.write(payload["stderr"])

    log = pathlib.Path(payload["log"])
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("a", encoding="utf-8") as stream:
        stream.write("%s:%d\\n" % (cohort(command), child.returncode))
    return payload["exit"]


sys.exit(main())
'''


def write_perf(directory: pathlib.Path, name: str, payload) -> pathlib.Path:
    """An isolated profiler whose whole configuration is the file beside it."""
    payload_path = directory / (name + ".perf.json")
    payload_path.write_text(json.dumps(payload), encoding="utf-8")
    source = PERF_SOURCE.replace("@@PYTHON@@", sys.executable).replace(
        "@@PAYLOAD@@", str(payload_path)
    )
    return write_executable(directory, name + ".perf.sh", source)


class RoundCase(unittest.TestCase):
    """Drives the runner as a process against stubbed round binaries.

    The ledger deliberately lives outside every `--out-dir`: a round that keeps
    its own budget beside its own results cannot notice what the last round
    spent.
    """

    def setUp(self) -> None:
        super().setUp()
        self.directory = pathlib.Path(tempfile.mkdtemp(prefix="api-round-round-"))
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        self.env = dict(os.environ, TMPDIR=str(self.directory))
        self.ledger_path = self.directory / "ledger.jsonl"
        self.out_dir = self.directory / "out"
        self.cpu = sorted(os.sched_getaffinity(0))[0]

    def stub(
        self,
        name,
        cases,
        *,
        rows=None,
        summary=None,
        list_build=None,
        measure_build=None,
        list_exit=0,
        measure_exit=0,
        prefix_lines=(),
        slice_documents=None,
    ):
        """A stand-in for the built round binary, plus its launch log.

        It publishes the same cases in both modes and records every invocation
        and the arguments it was given, so a test can prove what was and was
        not launched instead of reading what the runner said about it. It
        selects the way the built executable does: `--case` names a cohort and
        a name the selected slices publish nothing under is refused before a
        row is printed. `slice_documents` gives it the one-slice behaviour a
        profiled invocation needs: run under `--slice=<slice>` it publishes
        that slice's cases instead of the whole selection.
        """
        prefix = "".join(line + "\n" for line in prefix_lines)

        def measure_text(rows_or_cases):
            return prefix + document_text(
                rows_or_cases, "measure", summary, build=measure_build or build_line()
            )

        payload = {
            "list": document_text(cases, "list", build=list_build or build_line()),
            "measure": measure_text(rows_for(cases) if rows is None else rows),
            "slice_documents": {
                label: measure_text(rows_for(selection))
                for label, selection in (slice_documents or {}).items()
            },
            "log": str(self.directory / (name + ".log")),
            "argv_log": str(self.directory / (name + ".argv.log")),
            "list_exit": list_exit,
            "measure_exit": measure_exit,
        }
        payload_path = self.directory / (name + ".json")
        payload_path.write_text(json.dumps(payload), encoding="utf-8")
        return write_executable(
            self.directory,
            name + ".sh",
            STUB_SOURCE.format(python=sys.executable, payload=payload_path),
        )

    def launches(self, name):
        log = self.directory / (name + ".log")
        if not log.exists():
            return []
        return log.read_text(encoding="utf-8").split()

    def launches_argv(self, name):
        """Every launch of this binary, as the runner spelled it."""
        log = self.directory / (name + ".argv.log")
        if not log.exists():
            return []
        return [
            json.loads(line)
            for line in log.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]

    def named(self, name):
        """The `--case` names every launch of this binary was given."""
        return [
            [argument.split("=", 1)[1] for argument in argv
             if argument.startswith("--case=")]
            for argv in self.launches_argv(name)
        ]

    def receipt(self, path):
        return [
            json.loads(line)
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]

    def row_names(self, path):
        return [record["name"] for record in self.receipt(path)
                if record.get("kind") == "row"]

    def published(self):
        """The cases this round published, in the order it listed them."""
        results = json.loads((self.out_dir / "results.json").read_text(encoding="utf-8"))
        return [record["name"] for record in results["cases"]]

    def consumed(self):
        return runner.Ledger(self.ledger_path).consumed()

    def invoke(self, baseline, candidate, *extra, out_dir=None, ledger=None,
               bundles=("leaf",)):
        selection = []
        for bundle in bundles:
            selection.extend(["--bundle", bundle])
        return subprocess.run(
            [
                sys.executable,
                RUNNER,
                "--baseline-exe",
                str(baseline),
                "--candidate-exe",
                str(candidate),
                "--out-dir",
                str(self.out_dir if out_dir is None else out_dir),
                "--ledger",
                str(self.ledger_path if ledger is None else ledger),
                "--cpu",
                str(self.cpu),
                *selection,
                *extra,
            ],
            capture_output=True,
            text=True,
            check=False,
            env=self.env,
            timeout=300,
        )

    def round_budget(self):
        return {"expf": 32 * 2}


@unittest.skipUnless(shutil.which("taskset"), "taskset pins the measurements")
class LedgerScopeTests(RoundCase):
    """The ledger is global to the whole campaign, not to one result directory."""

    def test_a_second_out_dir_cannot_reset_the_shared_ledger(self) -> None:
        cases = [case_line()]
        baseline = self.stub("baseline", cases)
        candidate = self.stub("candidate", cases)

        first = self.invoke(baseline, candidate, "--pairs", "1", "--cap", "64")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(self.consumed(), self.round_budget())

        second_dir = self.directory / "out-second"
        second = self.invoke(
            baseline, candidate, "--pairs", "1", "--cap", "64", out_dir=second_dir
        )
        self.assertNotEqual(second.returncode, 0, second.stdout)
        self.assertEqual(self.consumed(), self.round_budget())
        self.assertFalse(second_dir.exists())
        # Only the zero-math listings happened after the budget ran out.
        self.assertEqual(self.launches("baseline"), ["--list", "measure", "--list"])
        self.assertEqual(self.launches("candidate"), ["--list", "measure", "--list"])

    def test_an_out_dir_that_already_holds_receipts_is_refused(self) -> None:
        cases = [case_line()]
        baseline = self.stub("baseline", cases)
        candidate = self.stub("candidate", cases)

        first = self.invoke(baseline, candidate, "--pairs", "1")
        self.assertEqual(first.returncode, 0, first.stderr)
        results = self.out_dir / "results.json"
        before = results.read_bytes()

        again = self.invoke(baseline, candidate, "--pairs", "1")
        self.assertNotEqual(again.returncode, 0, again.stdout)
        self.assertEqual(results.read_bytes(), before)
        self.assertEqual(self.consumed(), self.round_budget())


@unittest.skipUnless(shutil.which("taskset"), "taskset pins the measurements")
class PlanOnlyTests(RoundCase):
    """`--plan-only` proves the budget. It never pays for it and never runs it."""

    def test_plan_only_creates_nothing_and_launches_no_measurement(self) -> None:
        cases = [case_line()]
        baseline = self.stub("baseline", cases)
        candidate = self.stub("candidate", cases)

        result = self.invoke(baseline, candidate, "--pairs", "3", "--plan-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.out_dir.exists())
        self.assertFalse(self.ledger_path.exists())
        self.assertEqual(self.launches("baseline"), ["--list"])
        self.assertEqual(self.launches("candidate"), ["--list"])

    def test_plan_only_refuses_an_exhausted_budget_without_spending_it(self) -> None:
        runner.Ledger(self.ledger_path, cap=64).reserve(self.round_budget(), "earlier round")
        before = self.ledger_path.read_bytes()

        cases = [case_line()]
        baseline = self.stub("baseline", cases)
        candidate = self.stub("candidate", cases)

        result = self.invoke(baseline, candidate, "--pairs", "1", "--cap", "64", "--plan-only")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.ledger_path.read_bytes(), before)
        self.assertFalse(self.out_dir.exists())
        self.assertEqual(self.launches("baseline"), ["--list"])
        self.assertEqual(self.launches("candidate"), ["--list"])


@unittest.skipUnless(shutil.which("taskset"), "taskset pins the measurements")
class ReceiptTests(RoundCase):
    """A measurement receipt that does not match the plan fails the round closed.

    Every case here still leaves the whole reservation spent: the budget buys
    the attempt, not its result.
    """

    def refused(self, *, baseline_rows=None, candidate_rows=None, baseline_build=None,
                candidate_build=None, prefix_lines=()):
        cases = [case_line()]
        baseline = self.stub(
            "baseline",
            cases,
            rows=baseline_rows,
            measure_build=baseline_build,
            prefix_lines=prefix_lines,
        )
        candidate = self.stub(
            "candidate", cases, rows=candidate_rows, measure_build=candidate_build
        )
        result = self.invoke(baseline, candidate, "--pairs", "1")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.consumed(), self.round_budget())
        self.assertFalse((self.out_dir / "results.json").exists())

    def test_a_duplicate_row_is_refused(self) -> None:
        row = row_line(elapsed_ns=10, checksum="0" * 16)
        self.refused(baseline_rows=[row, row])

    def test_a_row_nobody_planned_is_refused(self) -> None:
        stray = row_line(
            name="leaf.scalar.logf.f32.normal", elapsed_ns=10, checksum="0" * 16
        )
        self.refused(baseline_rows=[row_line(elapsed_ns=10, checksum="0" * 16), stray])

    def test_a_changed_call_count_is_refused(self) -> None:
        self.refused(
            baseline_rows=[
                row_line(calls=8, elapsed_ns=10, checksum="0" * 16),
            ]
        )

    def test_a_receipt_line_that_is_not_json_is_refused(self) -> None:
        self.refused(prefix_lines=("{not json}",))

    def test_a_listing_line_in_a_measurement_receipt_is_refused(self) -> None:
        self.refused(baseline_rows=[case_line()])

    def test_a_receipt_built_from_another_harness_is_refused(self) -> None:
        self.refused(
            candidate_build=dict(build_line(), harness_digest="fedcba9876543210")
        )

    def test_two_builds_that_return_different_results_are_refused(self) -> None:
        self.refused(
            candidate_rows=[row_line(elapsed_ns=10, checksum="1" * 16)],
        )


@unittest.skipUnless(shutil.which("taskset"), "taskset pins the measurements")
class LaunchFailureTests(RoundCase):
    """A round that dies must fail, and must leave its budget spent."""

    def test_a_nonzero_exit_leaves_the_reservation_spent(self) -> None:
        cases = [case_line()]
        baseline = self.stub("baseline", cases, measure_exit=3)
        candidate = self.stub("candidate", cases, measure_exit=3)

        result = self.invoke(baseline, candidate, "--pairs", "1")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.consumed(), self.round_budget())
        self.assertFalse((self.out_dir / "results.json").exists())

    def test_a_missing_case_is_refused_and_the_budget_stays_spent(self) -> None:
        cases = [case_line()]
        baseline = self.stub("baseline", cases, rows=[])
        candidate = self.stub("candidate", cases, rows=[])

        result = self.invoke(baseline, candidate, "--pairs", "1")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.consumed(), self.round_budget())

    def test_two_executables_that_disagree_are_refused_before_any_launch(self) -> None:
        baseline = self.stub("baseline", [case_line()])
        candidate = self.stub("candidate", [case_line(calls=8)])

        result = self.invoke(baseline, candidate)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.ledger_path.exists())
        self.assertFalse((self.out_dir / "raw").exists())
        self.assertFalse((self.out_dir / "results.json").exists())
        self.assertEqual(self.launches("baseline"), ["--list"])
        self.assertEqual(self.launches("candidate"), ["--list"])


@unittest.skipUnless(shutil.which("taskset"), "taskset pins the measurements")
class CohortSelectionTests(RoundCase):
    """A round may name a cohort of cases instead of measuring whole bundles.

    A global per-kernel cap makes a whole-surface round unaffordable at any
    useful call count, so a round that needs a few cases at high counts names
    them. The stub executable selects the way the built one does, so what
    follows is decided by what a child process published and by what the
    ledger was asked for: a cohort is exactly the cases it names, a name the
    selection does not publish is refused before anything is measured, and a
    case named twice is still one row and one charge.
    """

    EXPF = "leaf.scalar.expf.f32.normal"
    LOGF = "leaf.scalar.logf.f32.normal"
    FADD = "values.scalar.fadd.f32.normal"

    #: Declared profiler invocations per side for the profiled cohort.
    INVOCATIONS = 2

    def published_cases(self):
        return [
            case_line(name=self.EXPF, f32=(("expf", 1),)),
            case_line(name=self.LOGF, f32=(("logf", 1),), digest="2222222222222222"),
            case_line(
                name=self.FADD,
                bundle="values",
                f32=(("fadd", 1),),
                digest="3333333333333333",
            ),
        ]

    def both(self, cases):
        return self.stub("baseline", cases), self.stub("candidate", cases)

    def test_an_unknown_cohort_name_is_refused_before_anything_is_spent(self) -> None:
        baseline, candidate = self.both(self.published_cases())

        result = self.invoke(
            baseline, candidate, "--pairs", "1", "--case", "leaf.scalar.nosuch.f32.normal"
        )

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.ledger_path.exists())
        self.assertFalse(self.out_dir.exists())
        # The plan is proved from the baseline listing first, and that
        # listing is where the refusal happens, so the candidate is never
        # launched at all: no measurement, nothing measured, nothing charged.
        self.assertEqual(self.launches("baseline"), ["--list"])
        self.assertEqual(self.launches("candidate"), [])

    def test_a_cohort_naming_an_unselected_bundle_is_refused(self) -> None:
        # This case is published by the fixture, but not by this selection.
        baseline, candidate = self.both(self.published_cases())

        result = self.invoke(baseline, candidate, "--pairs", "1", "--case", self.FADD)

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.ledger_path.exists())
        self.assertFalse(self.out_dir.exists())
        self.assertEqual(self.launches("baseline"), ["--list"])
        self.assertEqual(self.launches("candidate"), [])

    def test_a_cohort_publishes_and_charges_exactly_its_cases(self) -> None:
        baseline, candidate = self.both(self.published_cases())
        cohort = [self.EXPF, self.FADD]

        result = self.invoke(
            baseline,
            candidate,
            "--pairs",
            "1",
            "--case",
            cohort[0],
            "--case",
            cohort[1],
            bundles=("leaf", "values"),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        # The listing published these two cases, in this order, and nothing else.
        self.assertEqual(self.published(), cohort)
        self.assertEqual(
            self.row_names(self.out_dir / "raw" / "baseline-pair00.jsonl"), cohort
        )
        # One `--case` per name reached both the listing and the measurement.
        for side in ("baseline", "candidate"):
            self.assertEqual(self.named(side), [cohort, cohort])
        # One pair on both sides charged each named case once, and left the case
        # the cohort did not name unpaid.
        self.assertEqual(self.consumed(), {"expf": 32 * 2, "fadd": 32 * 2})

    def test_repeating_one_name_selects_one_case(self) -> None:
        baseline, candidate = self.both(self.published_cases())

        result = self.invoke(
            baseline,
            candidate,
            "--pairs",
            "1",
            "--case",
            self.EXPF,
            "--case",
            self.EXPF,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.published(), [self.EXPF])
        self.assertEqual(
            self.row_names(self.out_dir / "raw" / "baseline-pair00.jsonl"), [self.EXPF]
        )
        # The name reached every launch twice and still published one case and
        # one charge.
        self.assertEqual(self.named("baseline"), [[self.EXPF, self.EXPF]] * 2)
        self.assertEqual(self.consumed(), {"expf": 32 * 2})

    def test_a_profiled_cohort_receipts_and_charges_each_case_once(self) -> None:
        baseline, candidate = self.both(self.published_cases())
        cohort = [self.EXPF, self.LOGF]
        ledger = self.directory / "cohort-ledger.jsonl"
        perf = write_perf(
            self.directory,
            "cohort-perf",
            {
                "damage": "none",
                "exit": 0,
                "stderr": "",
                "log": str(self.directory / "cohort-perf.log"),
            },
        )

        result = self.invoke(
            baseline,
            candidate,
            "--pairs",
            "1",
            "--perf",
            str(perf),
            "--perf-mode",
            "stat",
            "--perf-bundle",
            "leaf",
            "--perf-invocations",
            str(self.INVOCATIONS),
            "--case",
            cohort[0],
            "--case",
            cohort[1],
            bundles=("leaf", "values"),
            ledger=ledger,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.published(), cohort)
        # The listing, the pair and every declared profile invocation carried
        # the cohort, on both sides.
        expected = [cohort] * (2 + self.INVOCATIONS)
        for side in ("baseline", "candidate"):
            self.assertEqual(self.named(side), expected)
        # Each named case is charged once per side for the pair and once per
        # side for every declared profile invocation.
        charged = 32 * 2 * (1 + self.INVOCATIONS)
        self.assertEqual(
            runner.Ledger(ledger).consumed(), {"expf": charged, "logf": charged}
        )
        # No profiled receipt carries a named case twice, which is what a cohort
        # and a bundle slice naming the same case would produce.
        receipts = sorted((self.out_dir / "perf").glob("*.jsonl"))
        self.assertEqual(len(receipts), 2 * self.INVOCATIONS)
        for receipt in receipts:
            self.assertEqual(self.row_names(receipt), cohort)


@unittest.skipUnless(shutil.which("taskset"), "taskset pins the measurements")
class ProfileReceiptTests(RoundCase):
    """A profiler's own numbers are a receipt, and they are paid for.

    `run_profiles` launches the round binary under the profiler, so every
    declared invocation reports measurements of its own, and the reservation
    has already paid for all of them before the first one starts. A profiler
    that exits zero while its receipt is partial, malformed or disagrees with
    the measurements has still run the work: the round may not publish a
    success it cannot read, and it may not hand back what the budget bought.

    The fixture profiler really launches the round binary, so everything below
    is decided by what a child process printed, not by what the runner claimed.
    """

    #: Declared invocations per side per profiled bundle, and the number the
    #: ledger was asked for.
    INVOCATIONS = 2

    def profile_cases(self):
        """Two fixed bundles; only `leaf` is ever profiled."""
        return [
            case_line(name="leaf.scalar.expf.f32.normal", f32=(("expf", 1),)),
            case_line(
                name="leaf.scalar.logf.f32.normal",
                f32=(("logf", 1),),
                digest="3333333333333333",
            ),
            case_line(
                name="values.scalar.fadd.f32.normal",
                bundle="values",
                f32=(("fadd", 1),),
                digest="2222222222222222",
            ),
        ]

    def profiled_document(self):
        """The receipt a `--slice=leaf` run of the fixture binary publishes."""
        leaf = [case for case in self.profile_cases() if case["bundle"] == "leaf"]
        return document_text(rows_for(leaf), "measure", build=build_line())

    def charges(self):
        """This fixture's own arithmetic: 32 calls of one charge per case, one
        pair on both sides, and `INVOCATIONS` profiles of `leaf` on both sides.
        Every measured case is charged whatever the profiler was asked to
        cover, and only the profiled cohort is charged for the profiles."""
        measured = 32 * 2
        profiled = measured + 32 * 2 * self.INVOCATIONS
        return {"expf": profiled, "logf": profiled, "fadd": measured}

    def fixture_round(self, label, *, damage="none", exit_code=0, stderr=""):
        """One round whose only profiler is the fixture beside it."""
        cases = self.profile_cases()
        leaf = [case for case in cases if case["bundle"] == "leaf"]
        baseline = self.stub("baseline", cases, slice_documents={"leaf": leaf})
        candidate = self.stub("candidate", cases, slice_documents={"leaf": leaf})
        perf = write_perf(
            self.directory,
            label + "-perf",
            {
                "damage": damage,
                "exit": exit_code,
                "stderr": stderr,
                "log": str(self.directory / (label + "-perf.log")),
            },
        )
        out_dir = self.directory / ("out-" + label)
        ledger = self.directory / ("ledger-" + label + ".jsonl")
        result = self.invoke(
            baseline,
            candidate,
            "--pairs",
            "1",
            "--perf",
            str(perf),
            "--perf-mode",
            "stat",
            "--perf-bundle",
            "leaf",
            "--perf-invocations",
            str(self.INVOCATIONS),
            out_dir=out_dir,
            ledger=ledger,
            bundles=("leaf", "values"),
        )
        return result, out_dir, ledger

    def spent(self, ledger):
        return runner.Ledger(ledger).consumed()

    def kept(self, out_dir, text):
        """Every file the round left behind that still holds `text`."""
        if not out_dir.is_dir():
            return []
        return [
            path
            for path in sorted(out_dir.rglob("*"))
            if path.is_file()
            and text in path.read_text(encoding="utf-8", errors="replace")
        ]

    def measured_checksums(self, out_dir):
        """The checksums the round's own measurement pairs agreed on."""
        found = {}
        for path in sorted((out_dir / "raw").glob("*.jsonl")):
            for line in path.read_text(encoding="utf-8").splitlines():
                if not line.strip():
                    continue
                record = json.loads(line)
                if record.get("kind") == "row":
                    found[record["name"]] = record["checksum"]
        return found

    def test_a_valid_profile_publishes_its_raw_receipt_and_the_measured_checksums(
        self,
    ) -> None:
        result, out_dir, ledger = self.fixture_round("valid")

        self.assertEqual(result.returncode, 0, result.stderr)
        results = json.loads((out_dir / "results.json").read_text(encoding="utf-8"))
        self.assertEqual(results["profiled_bundles"], ["leaf"])
        self.assertEqual(len(results["profiles"]), 2 * self.INVOCATIONS)
        for profile in results["profiles"]:
            self.assertTrue(pathlib.Path(profile["output"]).is_file(), profile)
            self.assertTrue(pathlib.Path(profile["stderr"]).is_file(), profile)

        # Every declared invocation really launched the binary, on both sides.
        self.assertEqual(
            self.launches("valid-perf"), ["leaf:0"] * (2 * self.INVOCATIONS)
        )
        pair_and_profiles = ["--list", "measure"] + ["measure"] * self.INVOCATIONS
        self.assertEqual(self.launches("baseline"), pair_and_profiles)
        self.assertEqual(self.launches("candidate"), pair_and_profiles)

        # Both bundles were measured on the single pair, so both were charged;
        # only the profiled cohort was charged again for its invocations.
        self.assertEqual(self.spent(ledger), self.charges())

        # The profiler's receipt is kept whole, and it carries the checksums
        # the round measured, so a consumer can re-read what was validated.
        receipt = self.profiled_document()
        kept = self.kept(out_dir, receipt)
        self.assertTrue(kept, "the round kept no copy of the profiler's receipt")
        rows = {}
        for line in kept[0].read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get("kind") == "row":
                rows[record["name"]] = record["checksum"]
        leaf = {
            name: checksum
            for name, checksum in self.measured_checksums(out_dir).items()
            if name.startswith("leaf.")
        }
        self.assertEqual(len(leaf), 2)
        self.assertEqual(rows, leaf)

    def test_a_profiler_that_exits_zero_with_an_unusable_receipt_fails_the_round(
        self,
    ) -> None:
        for damage in ("truncated", "garbled"):
            with self.subTest(damage=damage):
                result, out_dir, ledger = self.fixture_round(damage, damage=damage)

                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse((out_dir / "results.json").exists())
                # Stop at the invalid receipt without retrying or refunding.
                self.assertEqual(
                    self.launches(damage + "-perf"),
                    ["leaf:0"],
                )
                self.assertEqual(self.spent(ledger), self.charges())

    def test_a_profile_whose_checksum_disagrees_with_the_measurement_fails_the_round(
        self,
    ) -> None:
        result, out_dir, ledger = self.fixture_round(
            "divergent", damage="divergent"
        )

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((out_dir / "results.json").exists())
        self.assertEqual(self.spent(ledger), self.charges())

        # Only the profile's copy of the receipt was altered: the round's own
        # measurement pairs still agree with each other, and they are what the
        # profile was caught disagreeing with.
        measured = self.measured_checksums(out_dir)
        self.assertEqual(len(measured), 3)
        self.assertEqual(set(measured.values()), {"0" * 16})

    def test_a_profiler_that_fails_keeps_its_output_and_its_whole_charge(self) -> None:
        note = "fixture perf: no permission to open the event\n"
        result, out_dir, ledger = self.fixture_round(
            "failed", exit_code=9, stderr=note
        )

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((out_dir / "results.json").exists())
        self.assertEqual(self.spent(ledger), self.charges())

        # It launched once, the child answered, and the profiler died with the
        # receipt in hand. Both sides of what it printed are kept.
        self.assertEqual(self.launches("failed-perf"), ["leaf:0"])
        self.assertEqual(
            self.launches("baseline"), ["--list", "measure", "measure"]
        )
        self.assertTrue(
            self.kept(out_dir, self.profiled_document()),
            "the round kept no copy of the failed profiler's stdout",
        )
        self.assertTrue(
            self.kept(out_dir, note),
            "the round kept no copy of the failed profiler's stderr",
        )


class ConcurrentReservationTests(unittest.TestCase):
    """Two processes may not both decide the same budget is still available."""

    def test_two_processes_reserving_at_once_cannot_overspend(self) -> None:
        directory = pathlib.Path(tempfile.mkdtemp(prefix="api-round-concurrent-"))
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        path = directory / "ledger.jsonl"
        source = directory / "reserve.py"
        source.write_text(
            RESERVE_SOURCE.format(bench=str(BENCH)), encoding="utf-8"
        )

        processes = [
            subprocess.Popen(
                [
                    sys.executable,
                    str(source),
                    str(path),
                    str(directory / "gate"),
                    f"child{index}",
                    "60",
                    "100",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=dict(os.environ, TMPDIR=str(directory)),
            )
            for index in range(2)
        ]
        codes = []
        for process in processes:
            _, stderr = process.communicate(timeout=300)
            codes.append(process.returncode)
            if process.returncode not in (0, 3):
                self.fail(f"reservation process exited {process.returncode}: {stderr}")

        self.assertEqual(sorted(codes), [0, 3])
        consumed = runner.Ledger(path, cap=100).consumed()
        self.assertEqual(consumed, {"expf": 60})
        self.assertLessEqual(sum(consumed.values()), 100)


if __name__ == "__main__":
    unittest.main()