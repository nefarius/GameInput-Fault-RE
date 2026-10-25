"""Synthetic analysis tests: no test in this module proves hardware behavior."""

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "analysis"))
from compare_captures import COUNTERS, CaptureError, compare, read_capture, summarize
from convert_native import CONTEXT_FIELDS, convert


def capture(mitigated=False, calls=None, cpu=None):
    """Deliberately synthetic counts, hashes and context, never matrix evidence."""
    calls = (6000 if mitigated else 60000) if calls is None else calls
    cpu = (0.6 if mitigated else 6) if cpu is None else cpu
    counters = dict.fromkeys(COUNTERS, 0)
    counters.update(calls=calls, sync_success=calls, unchanged=calls)
    if mitigated:
        counters["throttled"] = calls
    return {
        "schema_version": "1.0",
        "metadata": {
            "capture_id": "synthetic-B" if mitigated else "synthetic-A",
            "pair_id": "synthetic-pair", "environment_id": "synthetic-environment",
            "os_build": "26200.9457", "architecture": "x64", "implementation": "redist",
            "process_id": 123, "process_start_id": "synthetic-epoch",
            "image_sha256": "a" * 64, "module_sha256": "b" * 64,
            "driver_sha256": "c" * 64, "probe_sha256": "d" * 64,
            "controller_id": "synthetic-controller", "connection": "synthetic-USB",
            "workload_id": "synthetic-workload", "service_configuration": "both",
            "phase": "idle", "logical_processor_count": 8, "qpc_frequency": 10_000_000,
            "probe_mode": "throttle" if mitigated else "diagnostic",
            "throttle_interval_ms": 8 if mitigated else None,
        },
        "snapshots": [
            {"elapsed_seconds": 0, "cpu_time_seconds": 10, "counters": dict.fromkeys(COUNTERS, 0)},
            {"elapsed_seconds": 60, "cpu_time_seconds": 10 + cpu, "counters": counters},
        ],
    }


def native_records(source):
    meta = source["metadata"]
    records = []
    for sample in source["snapshots"]:
        native = {
            "magic_value": 0x31504947, "abi_version": 1, "struct_bytes": 2296,
            "pid": meta["process_id"], "mode": 1 if meta["probe_mode"] == "throttle" else 0,
            "interval_us": 8000, "status": 1, "qpc_frequency": 10_000_000,
            "start_qpc": 1_000_000, "start_cpu_100ns": 100_000_000,
            "sample_qpc": 1_000_000 + int(sample["elapsed_seconds"] * 10_000_000),
            "process_cpu_100ns": int(sample["cpu_time_seconds"] * 10_000_000),
            "image_path": "C:\\synthetic\\GameInputRedistService.exe",
            "module_path": "C:\\Windows\\System32\\GameInputRedist.dll",
            "image_sha256": meta["image_sha256"], "module_sha256": meta["module_sha256"],
            "controller_heartbeat_qpc": 1_000_000,
            **sample["counters"],
        }
        records.append({"schema_version": 1, "kind": "snapshot", "phase": "idle", "target": {"pid": 123}, "snapshot": native})
    return records


class RateTests(unittest.TestCase):
    def test_exact_90_percent_and_cpu_are_numeric_only(self):
        report = compare(capture(), capture(True))
        self.assertAlmostEqual(report["unchanged_rate_reduction_fraction"], 0.9)
        self.assertTrue(report["rate_gate"]["passed"])
        self.assertTrue(report["cpu_gate"]["passed"])
        self.assertAlmostEqual(report["baseline"]["cpu_one_core_percent"], 10)
        self.assertAlmostEqual(report["baseline"]["cpu_machine_percent"], 1.25)
        self.assertFalse(report["supported_tool_eligible"])
        self.assertEqual(set(report["controller_validation"].values()), {"not_assessed"})

    def test_rate_just_below_threshold_fails(self):
        report = compare(capture(), capture(True, calls=6001))
        self.assertFalse(report["rate_gate"]["passed"])
        self.assertTrue(report["cpu_gate"]["passed"])
        self.assertFalse(report["performance_gate"]["passed"])

    def test_cpu_regression_is_separate(self):
        report = compare(capture(), capture(True, cpu=7))
        self.assertTrue(report["rate_gate"]["passed"])
        self.assertFalse(report["cpu_gate"]["passed"])
        self.assertFalse(report["performance_gate"]["passed"])

    def test_cpu_no_change_is_not_improvement(self):
        self.assertFalse(compare(capture(), capture(True, cpu=6))["cpu_gate"]["passed"])

    def test_zero_baseline_is_unknown_not_a_fix(self):
        report = compare(capture(calls=0, cpu=0), capture(True, calls=0, cpu=0))
        self.assertIsNone(report["unchanged_rate_reduction_fraction"])
        self.assertIsNone(report["rate_gate"]["passed"])
        self.assertIsNone(report["cpu_gate"]["passed"])

    def test_lifetime_offsets_do_not_change_rates(self):
        data = capture()
        for sample in data["snapshots"]:
            sample["elapsed_seconds"] += 500
            sample["cpu_time_seconds"] += 200
            for name in ("calls", "sync_success", "unchanged"):
                sample["counters"][name] += 999_999
        self.assertEqual(summarize(data)["rates_per_second"]["calls"], 1000)
        self.assertEqual(summarize(data)["cpu_one_core_percent"], 10)

    def test_historical_throttle_is_allowed_in_later_observe_window(self):
        baseline = capture()
        for sample in baseline["snapshots"]:
            sample["counters"]["throttled"] += 100
            sample["counters"]["unchanged"] += 100
            sample["counters"]["sync_success"] += 100
            sample["counters"]["calls"] += 100
        self.assertTrue(compare(baseline, capture(True))["rate_gate"]["passed"])

    def test_actual_delay_mean_has_no_latency_certification(self):
        mitigated = capture(True)
        mitigated["snapshots"][-1]["counters"]["delay_qpc"] = 1_036_410_000
        report = compare(capture(), mitigated)
        self.assertAlmostEqual(report["mitigated"]["throttle_delay_mean_ms"], 17.2735)
        self.assertEqual(report["controller_validation"]["input_latency"], "not_assessed")

    def test_normal_pending_baseline_is_not_pathological(self):
        baseline = capture()
        baseline["snapshots"][-1]["counters"].update(sync_success=0, unchanged=0, pending=60000)
        self.assertIsNone(compare(baseline, capture(True))["rate_gate"]["passed"])

    def test_atomic_skew_and_state_drops_are_not_repaired(self):
        for name in ("calls", "state_drops"):
            with self.subTest(name=name):
                baseline = capture()
                baseline["snapshots"][-1]["counters"][name] += 1
                report = compare(baseline, capture(True))
                self.assertIsNone(report["rate_gate"]["passed"])
                self.assertTrue(report["quality_issues"])

    def test_short_different_duration_phase_and_interval_leave_gate_unknown(self):
        for field, value in (("phase", "rumble"), ("throttle_interval_ms", 4)):
            with self.subTest(field=field):
                a, b = capture(), capture(True)
                b["metadata"][field] = value
                if field == "phase":
                    a["metadata"][field] = value
                self.assertIsNone(compare(a, b)["rate_gate"]["passed"])
        for duration in (10, 70):
            b = capture(True)
            b["snapshots"][-1]["elapsed_seconds"] = duration
            self.assertIsNone(compare(capture(), b)["rate_gate"]["passed"])

    def test_hash_workload_and_os_mismatches_are_rejected(self):
        for field in ("module_sha256", "driver_sha256", "probe_sha256", "os_build", "controller_id", "workload_id", "environment_id"):
            with self.subTest(field=field):
                b = capture(True)
                b["metadata"][field] = "e" * 64 if field.endswith("sha256") else ("19045.1" if field == "os_build" else "different")
                with self.assertRaises(CaptureError):
                    compare(capture(), b)

    def test_new_pid_between_captures_is_allowed(self):
        b = capture(True)
        b["metadata"].update(process_id=456, process_start_id="new-synthetic-epoch")
        self.assertTrue(compare(capture(), b)["rate_gate"]["passed"])

    def test_intermediate_counter_reset_and_bad_times_are_rejected(self):
        bad = capture()
        intermediate = copy.deepcopy(bad["snapshots"][-1])
        intermediate["elapsed_seconds"] = 30
        intermediate["counters"]["calls"] += 10
        bad["snapshots"].insert(1, intermediate)
        with self.assertRaisesRegex(CaptureError, "counter reset"):
            summarize(bad)
        for time in (0, -1, float("nan"), float("inf")):
            bad = capture()
            bad["snapshots"][-1]["elapsed_seconds"] = time
            with self.assertRaises(CaptureError):
                summarize(bad)

    def test_boolean_missing_and_negative_counters_rejected(self):
        for value in (True, -1, 0.5):
            bad = capture()
            bad["snapshots"][-1]["counters"]["calls"] = value
            with self.assertRaises(CaptureError):
                summarize(bad)
        bad = capture()
        del bad["snapshots"][-1]["counters"]["pending"]
        with self.assertRaises(CaptureError):
            summarize(bad)


class NativeTests(unittest.TestCase):
    def test_actual_wrapper_shape_and_cpu_units(self):
        source = capture()
        normalized = convert(native_records(source), {k: source["metadata"][k] for k in CONTEXT_FIELDS}, 123)
        self.assertEqual(normalized["metadata"]["implementation"], "redist")
        self.assertEqual(normalized["metadata"]["module_sha256"], "b" * 64)
        self.assertIn("probe-start-qpc", normalized["metadata"]["process_start_id"])
        self.assertEqual(summarize(normalized)["duration_seconds"], 60)
        self.assertEqual(summarize(normalized)["cpu_one_core_percent"], 10)

    def test_controls_other_pids_and_terminal_sample(self):
        source = capture()
        records = native_records(source)
        other = copy.deepcopy(records[0])
        other["target"]["pid"] = 789
        stop = copy.deepcopy(records[-1])
        stop["snapshot"]["status"] = 2
        records = [{"schema_version": 1, "kind": "inventory"}, other, *records, stop]
        result = convert(records, {k: source["metadata"][k] for k in CONTEXT_FIELDS}, 123)
        self.assertEqual(len(result["snapshots"]), 2)
        self.assertIn("excluded 1", result["conversion_notes"][0])

    def test_mitigate_log_observe_start_handshake_is_not_a_measured_mode_change(self):
        source = capture(True)
        records = native_records(source)
        handshake = copy.deepcopy(records[0])
        handshake["snapshot"]["mode"] = 0
        handshake["details"] = "Start handshake verified."
        result = convert([handshake, *records], {k: source["metadata"][k] for k in CONTEXT_FIELDS}, 123)
        self.assertEqual(result["metadata"]["probe_mode"], "throttle")
        self.assertIn("Excluded 1", result["conversion_notes"][1])

    def test_persistent_capture_uses_only_measurement_stage_and_allows_extra_fields(self):
        source = capture()
        records = native_records(source)
        for record in records:
            record["snapshot"]["capture_stage"] = "measurement"
            record["snapshot"]["future_optional_field"] = "ignored"
        before, after = copy.deepcopy(records[0]), copy.deepcopy(records[-1])
        before["snapshot"]["capture_stage"] = "stabilization"
        after["snapshot"]["capture_stage"] = "drain"
        result = convert([before, *records, after], {k: source["metadata"][k] for k in CONTEXT_FIELDS}, 123)
        self.assertEqual(len(result["snapshots"]), 2)
        self.assertIn("Excluded 2", result["conversion_notes"][2])

    def test_missing_context_or_pid_cannot_be_inferred(self):
        source = capture()
        with self.assertRaises(CaptureError):
            convert(native_records(source), {}, 123)
        with self.assertRaises(CaptureError):
            convert(native_records(source), {k: source["metadata"][k] for k in CONTEXT_FIELDS}, 999)

    def test_abi_identity_mode_phase_and_counter_errors(self):
        for field, value in (("struct_bytes", 2288), ("abi_version", 2), ("pid", 999), ("mode", 1), ("module_sha256", "e" * 64), ("qpc_frequency", 0), ("start_qpc", 2_000_000)):
            with self.subTest(field=field):
                source = capture()
                records = native_records(source)
                records[-1]["snapshot"][field] = value
                with self.assertRaises(CaptureError):
                    convert(records, {k: source["metadata"][k] for k in CONTEXT_FIELDS}, 123)
        source = capture()
        records = native_records(source)
        records[-1]["phase"] = "rumble"
        with self.assertRaises(CaptureError):
            convert(records, {k: source["metadata"][k] for k in CONTEXT_FIELDS}, 123)

    def test_blocked_target_cannot_become_zero_rate(self):
        source = capture()
        records = native_records(source)
        records.append({"schema_version": 1, "kind": "blocked", "target": {"pid": 123}})
        with self.assertRaises(CaptureError):
            convert(records, {k: source["metadata"][k] for k in CONTEXT_FIELDS}, 123)


class FileAndCliTests(unittest.TestCase):
    def test_jsonl_bom_and_duplicate_nonfinite_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.jsonl"
            data = capture()
            records = [{"record_type": "metadata", "schema_version": "1.0", "metadata": data["metadata"]}]
            records.extend({"record_type": "snapshot", **s} for s in data["snapshots"])
            path.write_text("\n".join(json.dumps(r) for r in records), encoding="utf-8-sig")
            self.assertEqual(summarize(read_capture(path))["duration_seconds"], 60)
            path = path.with_suffix(".json")
            for content in ('{"schema_version":"1.0","schema_version":"1.0"}', '{"value":NaN}', '[]', '{'):
                path.write_text(content, encoding="utf-8")
                with self.assertRaises(CaptureError):
                    read_capture(path)

    def test_native_to_comparison_cli_and_evidence_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            normalized = []
            for suffix, source in (("a", capture()), ("b", capture(True))):
                raw, context, output = [directory / (suffix + extension) for extension in (".jsonl", "-context.json", ".json")]
                raw.write_text("\n".join(json.dumps(r) for r in native_records(source)), encoding="utf-8")
                context.write_text(json.dumps({k: source["metadata"][k] for k in CONTEXT_FIELDS}), encoding="utf-8")
                result = subprocess.run([sys.executable, str(ROOT / "tools/analysis/convert_native.py"), str(raw), "--pid", "123", "--context", str(context), "--output", str(output)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                normalized.append(output)
            script = str(ROOT / "tools/analysis/compare_captures.py")
            result = subprocess.run([sys.executable, script, *map(str, normalized)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report["source_files"][0]["sha256"], hashlib.sha256(normalized[0].read_bytes()).hexdigest())
            self.assertFalse(report["supported_tool_eligible"])
            result = subprocess.run([sys.executable, script, *map(str, normalized), "--output", str(normalized[0])], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("overwrite", result.stderr)

    def test_gate_failure_cli_exit_one(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ("a.json", "b.json")]
            for path, data in zip(paths, (capture(), capture(True, cpu=7))):
                path.write_text(json.dumps(data), encoding="utf-8")
            result = subprocess.run([sys.executable, str(ROOT / "tools/analysis/compare_captures.py"), *map(str, paths)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stderr)


class InventoryTests(unittest.TestCase):
    def test_inventory_and_negative_capture_do_not_certify_a_fix(self):
        data = json.loads((ROOT / "data/version-matrix.json").read_text())
        self.assertEqual(len(data["rows"]), 2)
        for row in data["rows"]:
            self.assertEqual(row["supported_tool_status"], "unsupported")
            self.assertEqual(row["affected_status"], "not_established")
            if row["runtime"]["status"] == "observed_no_pathological_poll":
                self.assertEqual(row["runtime"]["measured_unchanged_rate_hz"],0)
                self.assertTrue(row["runtime"]["evidence_files"])
                for path in row["runtime"]["evidence_files"]:
                    evidence=json.loads((ROOT/path).read_text())
                    self.assertFalse(evidence["causal_fault_proven"])
                    self.assertFalse(evidence["mitigation_validated"])
            else:
                self.assertEqual(row["runtime"]["status"], "not_tested")
                self.assertIsNone(row["runtime"]["measured_unchanged_rate_hz"])
                self.assertEqual(row["runtime"]["evidence_files"], [])
        win10 = data["rows"][1]
        self.assertEqual(win10["os"]["build_number"], 19045)
        self.assertIsNone(win10["os"]["update_build_revision"])
        self.assertEqual(win10["binaries"], [])

    def test_system32_loaded_identity_and_complete_hashes(self):
        row = json.loads((ROOT / "data/version-matrix.json").read_text())["rows"][0]
        binaries = {b["id"]: b for b in row["binaries"]}
        self.assertEqual(len(binaries), 6)
        for binary in binaries.values():
            self.assertRegex(binary["sha256"], r"^[0-9a-f]{64}$")
        observation = row["process_observations"][0]
        self.assertEqual(observation["loaded_module_binary_id"], "redist_system32_dll")
        self.assertIn("System32", binaries[observation["loaded_module_binary_id"]]["path"])
        self.assertEqual(binaries["redist_system32_dll"]["sha256"], binaries["redist_programfiles_dll"]["sha256"])

    def test_supported_design_has_no_enabled_targets(self):
        gates = json.loads((ROOT / "data/supported-tool-gates.json").read_text())
        self.assertFalse(gates["supported"])
        self.assertEqual(gates["enabled_compatibility_entries"], [])
        self.assertEqual(len({gate["id"] for gate in gates["gates"]}), 10)
        self.assertTrue(all(gate["status"] == "not_validated" and not gate["evidence"] for gate in gates["gates"]))

    def test_schema_fields_and_native_size_contract_have_not_drifted(self):
        schema = json.loads((ROOT / "data/probe-capture.schema.json").read_text())
        self.assertEqual(set(schema["$defs"]["snapshot"]["properties"]["counters"]["required"]), set(COUNTERS))
        protocol = (ROOT / "src/probe/protocol.hpp").read_text()
        self.assertIn("sizeof(Shared) == 2296", protocol)


if __name__ == "__main__":
    unittest.main()
