"""Compare cumulative GameInput counters. This never certifies controller safety.

Only Python's standard library is used. See docs/version-matrix.md for the
capture contract and docs/workaround.md for the experiment protocol.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys


COUNTERS = (
    "calls", "sync_success", "pending", "errors", "unobserved", "unchanged",
    "throttled", "delay_qpc", "ioctl_qpc", "state_drops", "closes",
)
MATCH_FIELDS = (
    "pair_id", "environment_id", "os_build", "architecture", "implementation",
    "image_sha256", "module_sha256", "driver_sha256", "probe_sha256", "controller_id",
    "connection", "workload_id", "service_configuration", "phase",
    "logical_processor_count",
)
META_FIELDS = set(MATCH_FIELDS) | {
    "capture_id", "process_id", "process_start_id", "probe_mode", "throttle_interval_ms", "qpc_frequency",
}
PHASES = {"disconnected", "idle", "active_input", "rumble", "reconnect", "shutdown"}


class CaptureError(ValueError):
    """A capture cannot be interpreted without guessing."""


def _object(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise CaptureError(f"duplicate JSON key: {key}")
        obj[key] = value
    return obj


def _constant(value):
    raise CaptureError(f"non-finite JSON number: {value}")


def _loads(text):
    return json.loads(text, object_pairs_hook=_object, parse_constant=_constant)


def _number(value, label, integer=False, positive=False):
    expected = (int,) if integer else (int, float)
    if type(value) not in expected or not math.isfinite(value):
        raise CaptureError(f"{label} must be a finite {'integer' if integer else 'number'}")
    if value < 0 or (positive and value == 0):
        raise CaptureError(f"{label} must be {'positive' if positive else 'nonnegative'}")
    return value


def validate_capture(capture):
    required = {"schema_version", "metadata", "snapshots"}
    if not isinstance(capture, dict) or not required <= set(capture) or set(capture) - required - {"conversion_notes"}:
        raise CaptureError("capture requires schema_version, metadata, snapshots; only conversion_notes is optional")
    if "conversion_notes" in capture and (not isinstance(capture["conversion_notes"], list) or any(not isinstance(note, str) for note in capture["conversion_notes"])):
        raise CaptureError("conversion_notes must be an array of strings")
    if capture["schema_version"] != "1.0":
        raise CaptureError("unsupported schema_version")
    meta = capture["metadata"]
    if not isinstance(meta, dict) or set(meta) != META_FIELDS:
        raise CaptureError("metadata fields must match data/probe-capture.schema.json")
    for name in META_FIELDS - {"process_id", "logical_processor_count", "throttle_interval_ms", "qpc_frequency"}:
        if not isinstance(meta[name], str) or not meta[name].strip():
            raise CaptureError(f"metadata.{name} must be a nonempty string")
    for name in ("image_sha256", "module_sha256", "driver_sha256", "probe_sha256"):
        if re.fullmatch(r"[0-9a-f]{64}", meta[name]) is None:
            raise CaptureError(f"metadata.{name} must be a lowercase SHA-256")
    if re.fullmatch(r"[0-9]+\.[0-9]+", meta["os_build"]) is None:
        raise CaptureError("os_build must include build and revision")
    if meta["architecture"] != "x64" or meta["implementation"] not in {"inbox", "redist"}:
        raise CaptureError("only x64 inbox/redist captures are defined")
    if meta["service_configuration"] not in {"inbox_only", "redist_only", "both"}:
        raise CaptureError("invalid service_configuration")
    if (meta["service_configuration"] == "inbox_only" and meta["implementation"] != "inbox") or (
        meta["service_configuration"] == "redist_only" and meta["implementation"] != "redist"
    ):
        raise CaptureError("implementation contradicts service_configuration")
    if meta["phase"] not in PHASES:
        raise CaptureError("unknown controller phase")
    _number(meta["process_id"], "process_id", integer=True, positive=True)
    _number(meta["logical_processor_count"], "logical_processor_count", integer=True, positive=True)
    _number(meta["qpc_frequency"], "qpc_frequency", integer=True, positive=True)
    if meta["probe_mode"] == "diagnostic":
        if meta["throttle_interval_ms"] is not None:
            raise CaptureError("diagnostic capture cannot have a throttle interval")
    elif meta["probe_mode"] == "throttle":
        _number(meta["throttle_interval_ms"], "throttle_interval_ms", positive=True)
    else:
        raise CaptureError("probe_mode must be diagnostic or throttle")
    snapshots = capture["snapshots"]
    if not isinstance(snapshots, list) or len(snapshots) < 2:
        raise CaptureError("at least two cumulative snapshots are required")
    previous = None
    for index, snapshot in enumerate(snapshots):
        label = f"snapshots[{index}]"
        if not isinstance(snapshot, dict) or set(snapshot) != {"elapsed_seconds", "cpu_time_seconds", "counters"}:
            raise CaptureError(f"{label}: unexpected or missing fields")
        _number(snapshot["elapsed_seconds"], f"{label}.elapsed_seconds")
        _number(snapshot["cpu_time_seconds"], f"{label}.cpu_time_seconds")
        counters = snapshot["counters"]
        if not isinstance(counters, dict) or set(counters) != set(COUNTERS):
            raise CaptureError(f"{label}: all defined cumulative counters are required")
        for name in COUNTERS:
            _number(counters[name], f"{label}.{name}", integer=True)
        if previous is not None:
            if snapshot["elapsed_seconds"] <= previous["elapsed_seconds"]:
                raise CaptureError(f"{label}: time must strictly increase")
            if snapshot["cpu_time_seconds"] < previous["cpu_time_seconds"]:
                raise CaptureError(f"{label}: CPU counter reset")
            delta = {}
            for name in COUNTERS:
                delta[name] = counters[name] - previous["counters"][name]
                if delta[name] < 0:
                    raise CaptureError(f"{label}: {name} counter reset")
        previous = snapshot
    return capture


def read_capture(path):
    """Read one JSON capture or JSONL metadata followed by cumulative snapshots."""
    path = Path(path)
    try:
        content = path.read_text(encoding="utf-8-sig")
        if path.suffix.lower() == ".jsonl":
            records = [_loads(line) for line in content.splitlines() if line.strip()]
            if not records or not isinstance(records[0], dict) or records[0].get("record_type") != "metadata":
                raise CaptureError("JSONL must start with a metadata record")
            header = dict(records[0])
            header.pop("record_type")
            if set(header) != {"schema_version", "metadata"}:
                raise CaptureError("JSONL metadata record has unexpected fields")
            snapshots = []
            for record in records[1:]:
                if not isinstance(record, dict) or record.get("record_type") != "snapshot":
                    raise CaptureError("JSONL requires only snapshot records after metadata")
                snapshot = dict(record)
                snapshot.pop("record_type")
                snapshots.append(snapshot)
            capture = {**header, "snapshots": snapshots}
        else:
            capture = _loads(content)
        return validate_capture(capture)
    except (OSError, UnicodeError, ValueError, OverflowError) as exc:
        raise CaptureError(f"{path}: {exc}") from exc


def summarize(capture):
    validate_capture(capture)
    first, last = capture["snapshots"][0], capture["snapshots"][-1]
    duration = last["elapsed_seconds"] - first["elapsed_seconds"]
    counters = {name: last["counters"][name] - first["counters"][name] for name in COUNTERS}
    cpu = last["cpu_time_seconds"] - first["cpu_time_seconds"]
    return {
        "capture_id": capture["metadata"]["capture_id"],
        "process_id": capture["metadata"]["process_id"],
        "process_start_id": capture["metadata"]["process_start_id"],
        "conversion_notes": capture.get("conversion_notes", []),
        "duration_seconds": duration,
        "counter_deltas": counters,
        "rates_per_second": {name: counters[name] / duration for name in COUNTERS if name not in {"delay_qpc", "ioctl_qpc"}},
        "unchanged_fraction_of_target_calls": counters["unchanged"] / counters["calls"] if counters["calls"] else None,
        "result_counter_balance": counters["calls"] - sum(counters[name] for name in ("sync_success", "pending", "errors", "unobserved")),
        "cpu_time_delta_seconds": cpu,
        "cpu_one_core_percent": 100 * cpu / duration,
        "cpu_machine_percent": 100 * cpu / duration / capture["metadata"]["logical_processor_count"],
        "ioctl_latency_mean_ms": counters["ioctl_qpc"] / capture["metadata"]["qpc_frequency"] * 1000 / counters["calls"] if counters["calls"] else None,
        "throttle_delay_mean_ms": counters["delay_qpc"] / capture["metadata"]["qpc_frequency"] * 1000 / counters["throttled"] if counters["throttled"] else None,
    }


def compare(baseline, mitigated):
    a, b = summarize(baseline), summarize(mitigated)
    am, bm = baseline["metadata"], mitigated["metadata"]
    mismatches = [name for name in MATCH_FIELDS if am[name] != bm[name]]
    if mismatches:
        raise CaptureError("incomparable metadata: " + ", ".join(mismatches))
    if am["capture_id"] == bm["capture_id"]:
        raise CaptureError("baseline and mitigated must have distinct capture IDs")
    if am["probe_mode"] != "diagnostic" or bm["probe_mode"] != "throttle":
        raise CaptureError("baseline must be diagnostic; mitigated must be throttle")
    if a["counter_deltas"]["throttled"]:
        raise CaptureError("diagnostic baseline reports throttled calls")
    issues = []
    if am["phase"] != "idle":
        issues.append("90% pathological-unchanged gate requires an idle pair")
    if bm["throttle_interval_ms"] != 8:
        issues.append("only the initial 8 ms research interval is assessed")
    if abs(a["duration_seconds"] - b["duration_seconds"]) > 0.05 * a["duration_seconds"]:
        issues.append("paired measured durations differ by more than 5%")
    if min(a["duration_seconds"], b["duration_seconds"]) < 30:
        issues.append("each measured idle window must be at least 30 seconds")
    for label, summary in (("baseline", a), ("mitigated", b)):
        counters = summary["counter_deltas"]
        if counters["state_drops"]:
            issues.append(f"{label}: bounded state table/lock drops make unchanged classification incomplete")
        if summary["result_counter_balance"] != 0:
            issues.append(f"{label}: independently sampled counters/in-flight calls do not balance; repeat with stable boundaries")
        if counters["unchanged"] > counters["sync_success"] or counters["throttled"] > counters["unchanged"]:
            issues.append(f"{label}: non-coherent classification counters need review")
    base_rate = a["rates_per_second"]["unchanged"]
    reduction = 1 - b["rates_per_second"]["unchanged"] / base_rate if base_rate else None
    if reduction is None:
        issues.append("baseline unchanged rate is zero; reduction is undefined")
    if a["unchanged_fraction_of_target_calls"] is None or a["unchanged_fraction_of_target_calls"] <= 0.5:
        issues.append("immediate unchanged completions do not dominate baseline target calls")
    cpu_reduction = 1 - b["cpu_one_core_percent"] / a["cpu_one_core_percent"] if a["cpu_one_core_percent"] else None
    rate_gate = None if issues else reduction >= 0.9
    cpu_improved = cpu_reduction > 0 if cpu_reduction is not None else None
    return {
        "schema_version": "1.0",
        "status": "research_analysis_only",
        "matched_context": {key: am[key] for key in MATCH_FIELDS},
        "baseline": a, "mitigated": b,
        "quality_issues": issues,
        "unchanged_rate_reduction_fraction": reduction,
        "cpu_reduction_fraction": cpu_reduction,
        "rate_gate": {"threshold_fraction": 0.9, "passed": rate_gate},
        "cpu_gate": {"criterion": "strictly lower process CPU seconds per measured wall second", "passed": None if issues else cpu_improved},
        "cpu_improvement_observed": cpu_improved,
        "performance_gate": {"passed": None if issues or cpu_improved is None else rate_gate and cpu_improved},
        "controller_validation": {
            name: "not_assessed" for name in (
                "input_transitions", "input_latency", "rumble", "reconnect",
                "service_stability", "shutdown", "frame_time", "wdf_causal_correlation"
            )
        },
        "supported_tool_eligible": False,
        "limitations": [
            "Counter analysis alone does not establish causality or controller correctness.",
            "ABI v1 counters are independent atomic reads; in-flight calls and endpoint skew are reported, not repaired.",
            "Unobserved includes short/unreadable/unvalidated results; pending completion contents and ETW event loss are not measured here.",
            "Unchanged compares all 24 bytes; no changed-packet count is inferred from sync_success minus unchanged.",
            "CPU covers only this GameInput process; WUDFHost/driver/system CPU and frame time need separate traces.",
            "No latency distribution, input transition oracle, rumble, reconnect or shutdown verification is inferred.",
            "Requested 8 ms pacing is not an 8 ms scheduling/input-latency guarantee; mean observed delay cannot establish a maximum.",
            "A single pair is descriptive evidence; repeat paired trials and review external validation gates.",
        ],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("mitigated", type=Path)
    parser.add_argument("--output", type=Path, help="write JSON report here (otherwise stdout)")
    args = parser.parse_args(argv)
    try:
        report = compare(read_capture(args.baseline), read_capture(args.mitigated))
        report["source_files"] = [
            {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            for path in (args.baseline, args.mitigated)
        ]
        rendered = json.dumps(report, indent=2, allow_nan=False) + "\n"
        if args.output:
            if args.output.resolve() in {args.baseline.resolve(), args.mitigated.resolve()}:
                raise CaptureError("output must not overwrite either capture")
            args.output.write_text(rendered, encoding="utf-8")
        else:
            print(rendered, end="")
        return 0 if report["performance_gate"]["passed"] is True else 1
    except (CaptureError, OSError, OverflowError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
