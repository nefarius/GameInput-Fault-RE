# Version inventory and evidence matrix

**File inventory alone does not establish a supported correction.**
Windows 10 22H2 now has contributed inventory, a same-boot service-condition
CPU comparison and a specific-driver VM mechanism/performance PoC described
below. The contributor's game FPS cause and a supported workaround remain
unproven; do not generalize the VM findings to uninspected versions.

## Contributed Windows 10 capture, 2026-10-28

**2026-10-29 binary follow-up:** the operator-provided `xinput files.zip`
contains all three analyzed binaries, each byte-identical to the acquired or
reconstructed copy. This closes the x86 XInput whole-file comparison gap noted
below. See [binary identity evidence](../evidence/static/contributed-binary-identities-20261029.json).

[Offline acquisition](windows10-binary-acquisition.md) now supplies the exact
contributor-hash xinputhid 10.0.19041.5794 and GameInputInbox
0.2309.19041.6456 files, plus x86 XInput 10.0.19041.3636 matching the trace's
version and PE/PDB identities. The contributor's XInput whole-file hash was
unavailable at acquisition; the follow-up above resolves that gap.
[Subsequent static inspection](windows10-queue-identity.md) found a
missing PID initialization in the driver's per-process queue creation path;
the inspected Windows 11 build contains that store. A research VM on
19045.5796 with the exact driver hash and inbox 0.2309.19041.5794 now
[observes the missing initialization live](../evidence/runtime/vm-queue-publication-20261028.json)
and [repeated allocation by the same GameInput worker](../evidence/runtime/vm-queue-repeat-allocation-20261028.json).
The VM inbox differs from the contributor's later revision. A subsequent
[one-entry PID correction](../evidence/runtime/vm-queue-corrected-reuse-20261029.json)
now demonstrates that the same GameInput process selects the corrected node
and reuses its manual WDF queue. Performance effects were not yet measured
at this observation; subsequent comparisons follow below.
A [fresh corrected-device observation](../evidence/runtime/vm-queue-corrected-growth-20261029.json)
retained one queue node after a short run, while the earlier uncorrected fresh
device grew to 332. This is evidence for correction of queue growth in the
specific guest, with approximate timing and incomplete retired-device teardown;
it is not a game-performance or supported-fix result.
A subsequent [100-pair x64 handle-close comparison](../evidence/runtime/vm-handle-close-pair-20261029.json)
measured median 411.45 microseconds uncorrected versus 11.7 corrected, with
matching interface, driver/script hashes and requested limits. Corrected count
remained one after transfer. This supports the local queue-growth/close-cost
mechanism but retains the single-pair, unequal-exposure and teardown limitations;
the contributor's x86 game FPS and controller behavior remain unvalidated.
A [reversed-order check](../evidence/runtime/vm-handle-close-reversed-pair-20261029.json)
reproduced the difference: median 437.8 microseconds in a new uncorrected
lifetime versus 11.15 in the reused corrected lifetime. Device age/exposure and
retired-device state remain incompletely controlled; no compatibility gate changes.
Compatibility gates are unchanged.

The [x86 XInput API pair](../evidence/runtime/vm-xinput-x86-pair-20261029.json)
then completed 400 calls per condition on confirmed guest 19045.5796, with
matching reference driver/DLL/script identities and limits. Disconnected-slot
medians fell from 1834-2747 to 42-125 microseconds and the corrected device
still had one queue node. This is a local API-level PoC with one serial pair,
unequal exposure and incomplete teardown control; per-call stacks, game frame
times and input fidelity remain unvalidated.

The [new updated-collector pair](community-capture-20261028-l4d2-pair.md) shares
a boot, game process UniqueKey/thread, profile and equal four-second windows.
The inbox-running condition restores the reported symptom and XInput/cleanup
dominated hot path while the redist remains running. This supports a local
service-condition association, not a proven driver mechanism, measured FPS
benefit or supported workaround. All 12 shared binary hashes match; the enabled
inbox implementation also matches the earlier enabled inventory. Compatibility
and mitigation gates remain unchanged.

The subsequent [disabled-service run](community-capture-20261028-l4d2.md#disabled-service-follow-up-195831-4dcb7591)
uses the updated collector, retains a usable four-second CPU window and confirms
inbox Stopped/Disabled with redist Running/Auto. Its 12 available GameInput/
xinputhid hashes match prior inventory; the inbox implementation was not
inventoried this time. The operator reports no symptom, with greatly diminished
game-side cleanup stacks. A reboot occurred since the old enabled run, and scene
equivalence is unknown for that older comparison. Its updated-collector enabled
counterpart has now arrived; see the new comparison below.

A [second package from Left 4 Dead 2](community-capture-20261028-l4d2.md)
matches all 13 collected GameInput/xinputhid hashes in the first package.
Its [derived summary](../evidence/runtime/community-20261028-8b1526ae-summary.json)
records an expensive game-thread XInputGetState/device-enumeration/close path
with trace-matched Microsoft symbols. Both services were running in inventory;
the separately supplied screenshot identifies the reported workaround as
disabling inbox GameInput Service while leaving the redist running. A matched
service A/B, frame-time impact, state-request semantics and workaround safety
remain unvalidated. The old collector was used again, so only a retained tail
supports CPU analysis. This observation does not change compatibility gates.

The [community review](community-capture-20261028.md) and
[derived summary](../evidence/runtime/community-20261028-08710ec5-summary.json)
record Windows 10 22H2 **19045.6466**, inbox implementation
**0.2309.19041.6456**, redist **4.0.302.0**, xinputhid **10.0.19041.5794**
and DsHidMini trace metadata **3.27.0.2500**. Both services were running.
The reported workload is a USB PS3 controller in Stellar Blade, with rumble
disabled. The symptom's occurrence during recording is unspecified.

The system memory buffer apparently wrapped: reliable CPU/switch coverage
survives only near the end, preventing the requested four-phase comparison.
The reviewed four-second tail shows approximately 0.3375% machine CPU for
WUDFHost, 0.015625% for the inbox worker and 0.0078125% for the redist.
No state-request/completion or rumble-off rates were established.

This contributed observation is kept separately from the schema-constrained
local/probe matrix below, which requires fields this collector did not record
(including binary sizes and process creation times). Its generic untested
Windows 10 target row remains a plan for mechanism testing, not an assertion
that no Windows 10 inventory has been received. No affected/fixed/supported
status or probe compatibility gate changes.

The authoritative small machine record is [version-matrix.json](../data/version-matrix.json),
constrained by [version-matrix.schema.json](../data/version-matrix.schema.json)
(JSON Schema draft 2020-12). Missing observations are `null`, empty arrays, or
`not_tested`; zero is reserved for an actual measured zero. The schema admits
the reviewed negative USB observation below, but cannot mark a configuration
affected, fixed, or supported without a further reviewed evidence revision.

## USB runtime result, 2026-10-25

The reviewed [active-input summary](../evidence/runtime/active-input-summary.json)
records 44.75 measured seconds with both services running. In the system redist
process, all 2,014 matching requests returned `ERROR_IO_PENDING`; immediate
successful/unchanged/error counts were zero. Its measured process CPU was
0.279% of one core, including probe overhead. The inbox and per-user redist
processes made no matching requests in that window; this says nothing about
their other work. An independent 60-second XInput monitor observed 1,246 distinct
packet values, confirming controller activity without certifying input fidelity.

The earlier 11.59-second no-probe WPR baseline reported zero lost events/buffers.
It was not simultaneous with this probe run. No symptomatic game was running,
and no high-resource condition or polling-to-rumble causality was demonstrated.
No hardware throttle trial was justified by this result. The initial mapping
failure and the subsequent wrapper exit-code reporting failure remain in local
raw logs; neither is silently treated as a successful capture.

The same controller was then paired over **Bluetooth LE**, with USB disconnected
and operation confirmed by the operator. In a second 44.75-second measurement,
the inbox process issued **1,439** matching requests and the system redist
**1,391**; every request returned pending. Their CPU use was about **0.175%** and
**0.105% of one core**, respectively, including probe overhead. There were no
immediate successes, unchanged responses, errors, or throttles. The independent
monitor observed **1,279** distinct packet values. See [Bluetooth evidence](../evidence/runtime/bluetooth-active-input-summary.json).

The Bluetooth child was `Bluetooth LE XINPUT compatible input device`, using
`mshidumdf` and the `xinputhid` upper filter, driver 10.0.26100.9278. Its parent
used `BthLEEnum`. The USB base had used `dc1-controller` 10.0.26100.9444 with
`xboxgip`. These inventories establish different device paths but not a definitive
association of each captured handle to a child device.

The operator has not knowingly observed the reported fault on this machine.
Treat these as comparison runs on a system without a confirmed symptom, not as
negative results from a previously established affected configuration.

## Local Windows 11 observation

Read on 2026-10-25, with binary inventory at 13:15 UTC and the PID/module check
at 13:20 UTC:

- Windows 11 25H2, **26200.9457**, x64. CIM caption is `Microsoft Windows 11
  Business`; registry `ProductName` says `Windows 10 Pro`. The record preserves
  that stale branding instead of treating it as a Windows 10 installation.
- Inbox `GameInput.dll` and `GameInputSvc.exe`: **0.2309.26100.9278**.
- Redist `GameInputRedist.dll` and `GameInputRedistService.exe`: **3.5.270.0**.
  The uninstall registry entry also reports Microsoft GameInput 3.5.270.0;
  this is installed package metadata, not an authenticated downloaded package.
- `xinputhid.sys`: product version **10.0.26100.9278**. The raw file-version
  string includes `(WinBuild.160101.0800)` and is preserved in JSON.
- `GameInputSvc` was Running / Manual; `GameInputRedistService` was Running /
  Auto. These historical states are not assertions about a later run.
- **PID 7188 actually loaded `C:\Windows\System32\GameInputRedist.dll`.**
  The process image was the Program Files redist service host. Both the loaded
  System32 DLL path and the separately inventoried Program Files DLL are
  recorded. Their backing files had equal hashes at this observation time;
  future copies must be checked independently. A backing-file hash is not a
  hash of relocated process memory. Rediscover PID/start time before each run.

Key SHA-256 values (all six file records, including host executables, are in JSON):

- Inbox DLL: `f9f5adbde4a2883b9b307bb1848a120094904578d92b21100828bd83f7b77cb6`.
- System32 and Program Files redist DLLs, each independently read:
  `6d3650dbeea5f8c639972537dbaed3f2bb465561e63d34fa9661902f24cb9686`.
- Driver: `1e85d1a191f09ed62645658c94f908b733da5a026ed2b6b662635ebbddf84588`.

Signature validation was not part of this inventory. These hashes must never
be promoted directly into a supported compatibility allowlist.

## Interpretation and Windows 10 coverage

The prior [user-mode findings](gameinput-service-fault.md) describe resubmission
loops. The [kernel investigation](kernel-xinputhid.md) shows that this exact
Windows 11 driver returns cached state when input byte 3 is nonzero and queues
the zero-byte path until decoded state changes, subject to the documented
routing/feature conditions. A blocking synchronous call can also wait before
returning TRUE: a successful API return alone does not prove immediate kernel
completion. A loop in user-mode code is therefore insufficient to label this
Windows 11 installation or its controller affected.

The redist's static OS gate predicts a clear flag on build 26200 and a set flag
on build 19045. Actual submitted bytes, request/device routing and completion
timing need runtime evidence. The initial investigation covered Windows 11
only; subsequent Windows 10 inspection and VM observations above cover the
specific 10.0.19041.5794 driver. Neither build's semantics should be projected
onto other uninspected drivers. The schema's generic planned Windows 10 row
does not encode or replace those separately retained contributed/VM results,
and no supported target is enabled. A release note is not binary/runtime proof.

## Reproduce the inventory

Run these read-only checks from x64 PowerShell; access-denied results must be
recorded rather than replaced with guessed values. CIM or protected-process
inspection may require an administrator terminal.

```powershell
$version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$version | Select-Object ProductName,DisplayVersion,CurrentBuild,UBR,BuildLabEx
Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,OSArchitecture
Get-CimInstance Win32_Service | Where-Object Name -like '*GameInput*' |
    Select-Object Name,PathName,State,StartMode
$paths = @(
    'C:\Windows\System32\GameInput.dll',
    'C:\Windows\System32\GameInputRedist.dll',
    'C:\Windows\System32\GameInputSvc.exe',
    'C:\Program Files\Microsoft GameInput\x64\GameInputRedist.dll',
    'C:\Program Files\Microsoft GameInput\x64\GameInputRedistService.exe',
    'C:\Windows\System32\drivers\xinputhid.sys'
)
foreach ($filePath in $paths) {
    $file = Get-Item -LiteralPath $filePath
    [pscustomobject]@{
        path=$file.FullName; file_version=$file.VersionInfo.FileVersion
        product_version=$file.VersionInfo.ProductVersion; size_bytes=$file.Length
        sha256=(Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
Get-Process GameInputSvc,GameInputRedistService -ErrorAction SilentlyContinue |
    ForEach-Object {
        $_ | Select-Object Id,StartTime,Path
        $_.Modules | Where-Object ModuleName -like '*GameInput*' |
            Select-Object ModuleName,FileName
    }
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' |
    Get-ItemProperty | Where-Object DisplayName -like '*GameInput*' |
    Select-Object PSPath,DisplayName,DisplayVersion,Publisher
```

Record collection UTC time and hash each newly discovered loaded-module path,
even if it differs from the six expected paths. Store no device serial or
instance IDs in tracked data. Accept future version rows only from local or
contributed diagnostics with provenance, or authenticated Microsoft packages;
package-only evidence must remain separate from installed/runtime observations.

## Native captures and analysis contract

[convert_native.py](../tools/analysis/convert_native.py) consumes the actual
`tools/probe/Invoke-GameInputResearch.ps1` JSONL envelope:
`schema_version: 1`, `kind: "snapshot"`, `phase`, `target.pid`, and `snapshot`
containing native fields from [protocol.hpp](../src/probe/protocol.hpp).
Current ABI v1 is **2296 bytes**, including the controller heartbeat.
The converter verifies magic, version, size, selected/native PID, stable probe
epoch, image/module identity, mode and QPC origin. Unknown ABI layouts fail.

The required context file follows [experiment-context.schema.json](../data/experiment-context.schema.json).
Supply a distinct `capture_id`, paired experiment `pair_id`, `environment_id`
identifying the saved power/driver/game/ETW configuration, actual OS build+UBR,
actual driver and probe SHA-256, a private controller pseudonym, connection,
workload identity, actual service configuration, phase and logical CPU count.
Do not fill unknown values with placeholders or infer identity from a PID alone.
`service_configuration` describes the observed poller configuration; default
collection does not stop services to create an isolated configuration.

The converter derives the PID, implementation, image/module hashes, mode,
interval, QPC frequency, cumulative CPU and counters from the native records.
`process_start_id` is explicitly a PID/probe-start-QPC epoch token, not a claimed
process creation timestamp. It filters other PIDs, ignores inventory/action
records, notes excluded explicit Start handshakes and terminal Stopped/Busy samples, and rejects failures for
the selected PID. Preserve the raw file; normalized conversion notes record its
SHA-256 and the context SHA-256.

For persistent captures, optional native `capture_stage` (or envelope
`captureStage`) selects **measurement** records only; stabilization, drain and
teardown are explicitly counted as exclusions. Additional native fields are
accepted without changing the meanings of required ABI fields.

```powershell
python tools/analysis/convert_native.py captures/observe/research.jsonl --pid $ObservedPid --context captures/observe-context.json --output captures/observe.json
python tools/analysis/convert_native.py captures/throttle/research.jsonl --pid $ObservedPid --context captures/throttle-context.json --output captures/throttle.json
python tools/analysis/compare_captures.py captures/observe.json captures/throttle.json --output captures/comparison.json
```

Paths above are user-selected capture locations, not supplied evidence files.
Use the directories printed by each wrapper invocation. Select an actually
enumerated PID for each capture; respawned processes may have different PIDs.

[probe-capture.schema.json](../data/probe-capture.schema.json) defines normalized
JSON: metadata and at least two cumulative snapshots. Normalized JSONL is also
accepted by the comparator: first record `record_type: "metadata"` with
`schema_version` and `metadata`; later records `record_type: "snapshot"` with
`elapsed_seconds`, `cpu_time_seconds`, and `counters`. Native wrapper JSONL goes
through the converter first. Neither format is an individual-IOCTL event stream.

Native counters retain their names: `calls`, `sync_success`, `pending`, `errors`,
`unobserved`, `unchanged`, `throttled`, `delay_qpc`, `ioctl_qpc`, `state_drops`,
`closes`. `unchanged` compares all 24 bytes. `sync_success - unchanged` is **not**
a proven changed-packet count. Pending output/completion contents are unobserved.
Current TRUE overlapped returns are validated by the probe without waiting;
short/unreadable/unvalidated results remain separate. The first four output
bytes are not assumed to be a decoded packet number.

Rates use endpoint **counter differences / measured elapsed seconds**, never a
lifetime total divided by a requested duration. CPU is the difference in process
kernel+user CPU seconds: one-core percent is `100 * CPU / elapsed`; machine
percent additionally divides by logical CPU count. QPC-derived mean IOCTL time
and mean actual throttle delay are descriptive aggregates, not latency bounds.
The converter requires at least two valid samples; second-scale cadence is
sufficient for these rates but cannot validate input transitions or latency.

Every intermediate sample is checked for resets, time regression, mode/identity
changes and non-finite values. Independently atomic ABI counters are not a
coherent transaction: completion-category imbalance is reported and leaves the
gate unknown; the analyzer never silently repairs categories. State-table drops
also leave it unknown. Phase/context/hash mismatches reject the comparison.

The 90% gate applies only to a matched idle pair with at least 30 measured
seconds each, durations within 5%, requested 8 ms research pacing, a positive
baseline unchanged rate, and unchanged completions comprising more than half
of baseline calls. These minimum window/quality rules are analysis policy,
not a demonstrated device safety envelope. Reduction is
`1 - mitigated_rate / baseline_rate`; a zero denominator is unknown, not a pass.
The separate CPU gate requires strictly lower CPU seconds per wall second.
Frame-time evidence requires external traces and is never inferred here.

Exit codes: `0` means the limited numeric rate+CPU gates passed; `1` means failed
or insufficient evidence; `2` means invalid/unreadable/incomparable input.
JSON booleans are tri-state (`true`, `false`, `null` for unknown). Reports always
set `supported_tool_eligible: false`; input, latency, rumble, reconnect,
shutdown and causal validation remain `not_assessed`.

## Tests

```powershell
python -m unittest discover -s tests/analysis -v
```

These tests use synthetic counters in temporary files and do not establish
hardware correctness. JSON Schema validation is an additional check when the
`jsonschema` package is available; neither analysis CLI requires that package.
