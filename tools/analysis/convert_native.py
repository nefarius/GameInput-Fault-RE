"""Convert tools/probe wrapper JSONL to the analysis snapshot contract.

Usage: python tools/analysis/convert_native.py capture.jsonl --pid 7188
       --context local-context.json --output normalized.json
Context contains only externally observed experiment metadata. Native process
identity, module hashes, clocks, modes and counters are never filled with defaults.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys

from compare_captures import COUNTERS, CaptureError, _loads, _number, validate_capture


CONTEXT_FIELDS = {
    "capture_id", "pair_id", "environment_id", "os_build", "driver_sha256",
    "probe_sha256", "controller_id", "connection", "workload_id", "service_configuration",
    "phase", "logical_processor_count",
}
IDENTITY_FIELDS = (
    "pid", "qpc_frequency", "start_qpc", "start_cpu_100ns", "image_path", "module_path",
    "image_sha256", "module_sha256", "mode", "interval_us",
)


def convert(records, context, process_id):
    if not isinstance(context, dict) or set(context) != CONTEXT_FIELDS:
        raise CaptureError("context must contain exactly: " + ", ".join(sorted(CONTEXT_FIELDS)))
    _number(process_id, "selected PID", integer=True, positive=True)
    samples = []
    identity = None
    skipped_terminal = 0
    skipped_start = 0
    skipped_stage = 0
    for index, record in enumerate(records):
        if not isinstance(record, dict) or type(record.get("schema_version")) is not int or record["schema_version"] != 1:
            raise CaptureError(f"wrapper record {index}: unsupported schema_version")
        if record.get("kind") == "blocked" and isinstance(record.get("target"), dict) and record["target"].get("pid") == process_id:
            raise CaptureError("selected PID has a blocked/failed wrapper action; review raw evidence")
        if record.get("kind") != "snapshot":
            continue
        native = record.get("snapshot")
        target = record.get("target")
        if not isinstance(native, dict) or not isinstance(target, dict):
            raise CaptureError(f"wrapper record {index}: snapshot and target must be objects")
        if type(target.get("pid")) is not int:
            raise CaptureError(f"wrapper record {index}: target PID missing")
        if target["pid"] != process_id:
            continue
        if record.get("details") == "Start handshake verified.":
            # Attach logs Observe before the requested mode is selected. It is
            # a control handshake, not the beginning of a Mitigate time window.
            skipped_start += 1
            continue
        required = set(IDENTITY_FIELDS) | set(COUNTERS) | {
            "magic_value", "abi_version", "struct_bytes", "status", "sample_qpc", "process_cpu_100ns", "controller_heartbeat_qpc",
        }
        if not required <= set(native):
            raise CaptureError("native ABI fields missing: " + ", ".join(sorted(required - set(native))))
        for name in set(COUNTERS) | {"pid", "qpc_frequency", "start_qpc", "start_cpu_100ns", "sample_qpc", "process_cpu_100ns", "magic_value", "abi_version", "struct_bytes", "status", "mode", "interval_us"}:
            _number(native[name], f"native.{name}", integer=True)
        if (native["magic_value"], native["abi_version"], native["struct_bytes"]) != (0x31504947, 1, 2296):
            raise CaptureError("native ABI handshake mismatch")
        if native["pid"] != process_id:
            raise CaptureError("wrapper and native PID mismatch")
        stage = native.get("capture_stage", record.get("captureStage"))
        if stage is not None:
            if stage not in {"stabilization", "measurement", "drain", "teardown"}:
                raise CaptureError("unknown native capture stage")
            if stage != "measurement":
                skipped_stage += 1
                continue
        if native["status"] in (2, 3):
            skipped_terminal += 1
            continue
        if native["status"] != 1:
            raise CaptureError("only Running probe samples may define a measured window")
        if record.get("phase") != context["phase"]:
            raise CaptureError("wrapper phase differs from context; export one phase per file")
        if native["qpc_frequency"] <= 0 or native["sample_qpc"] < native["start_qpc"]:
            raise CaptureError("native QPC frequency/origin invalid")
        if native["process_cpu_100ns"] < native["start_cpu_100ns"]:
            raise CaptureError("native CPU counter predates origin")
        current = {name: native[name] for name in IDENTITY_FIELDS}
        if identity is None:
            identity = current
        elif identity != current:
            raise CaptureError("PID/start, frequency, image/module, or mode changed within capture; split the capture")
        samples.append({
            "elapsed_seconds": (native["sample_qpc"] - native["start_qpc"]) / native["qpc_frequency"],
            "cpu_time_seconds": (native["process_cpu_100ns"] - native["start_cpu_100ns"]) / 10_000_000,
            "counters": {name: native[name] for name in COUNTERS},
        })
    if identity is None:
        raise CaptureError("no snapshots for selected PID; no identity or counters can be inferred")
    if not isinstance(identity["module_path"], str) or not isinstance(identity["image_path"], str):
        raise CaptureError("native image/module paths must be strings")
    module_name = identity["module_path"].replace("\\", "/").rsplit("/", 1)[-1].lower()
    implementation = {"gameinput.dll": "inbox", "gameinputredist.dll": "redist"}.get(module_name)
    if implementation is None:
        raise CaptureError("native module is not a known GameInput module")
    image_name = identity["image_path"].replace("\\", "/").rsplit("/", 1)[-1].lower()
    if image_name not in {"gameinputsvc.exe", "gameinputredistservice.exe"}:
        raise CaptureError("native image is not a known GameInput host")
    if identity["mode"] not in (0, 1):
        raise CaptureError("native mode is neither Observe nor Mitigate")
    metadata = {
        **context,
        "process_id": process_id,
        # A probe epoch token, not a fabricated process creation timestamp.
        "process_start_id": f"pid:{process_id}/probe-start-qpc:{identity['start_qpc']}",
        "architecture": "x64",  # fixed by validated ABI v1 size/layout
        "qpc_frequency": identity["qpc_frequency"],
        "implementation": implementation,
        "image_sha256": identity["image_sha256"],
        "module_sha256": identity["module_sha256"],
        "probe_mode": "diagnostic" if identity["mode"] == 0 else "throttle",
        "throttle_interval_ms": None if identity["mode"] == 0 else identity["interval_us"] / 1000,
    }
    return validate_capture({
        "schema_version": "1.0", "metadata": metadata, "snapshots": samples,
        "conversion_notes": [
            f"Selected PID {process_id}; excluded {skipped_terminal} Stopped/Busy control snapshots from measured windows.",
            f"Excluded {skipped_start} explicit Start handshake records before mode selection.",
            f"Excluded {skipped_stage} explicitly staged stabilization/drain/teardown records; retained measurement records only when stages are present.",
            "Inventory/action records are not samples. Preserve raw JSONL; no ETW loss information is inferred.",
        ],
    })


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("raw", type=Path)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--context", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.output.resolve() in {args.raw.resolve(), args.context.resolve()}:
            raise CaptureError("output must not overwrite raw evidence or context")
        raw_bytes, context_bytes = args.raw.read_bytes(), args.context.read_bytes()
        records = [_loads(line) for line in raw_bytes.decode("utf-8-sig").splitlines() if line.strip()]
        context = _loads(context_bytes.decode("utf-8-sig"))
        result = convert(records, context, args.pid)
        result["conversion_notes"].extend([
            f"Raw JSONL SHA256: {hashlib.sha256(raw_bytes).hexdigest()}",
            f"Context JSON SHA256: {hashlib.sha256(context_bytes).hexdigest()}",
        ])
        args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n", encoding="utf-8")
        return 0
    except (CaptureError, OSError, UnicodeError, ValueError, OverflowError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
