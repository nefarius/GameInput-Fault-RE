# Community capture, 2026-10-28

The package supplies the first contributed Windows 10 inventory and a short
usable CPU window. It does **not** establish the reported high-CPU fault,
state-request completion behavior, or a rumble-off flood. Early CPU evidence
did not survive the bounded memory recording, so this is not a negative
four-phase reproduction.

Reviewed derived data: [capture summary](../evidence/runtime/community-20261028-08710ec5-summary.json).
Raw material and analysis exports remain local under ignored
`captures/community/20261028-030803-08710ec5/`. The original ZIP is preserved.
No diagnostics were uploaded. Paths and device-instance identifiers from the
raw trace are intentionally excluded from this report.

## Provenance and configuration

- Package: `GameInput-20261028-030803-08710ec5.zip`, 12,376,172 bytes;
  SHA-256 `c23319af1787770a8a9fada54678719f4fb02d2ddd43e5e65a561ab94e1f47a9`.
  All 28 manifest entries matched, with no extra packaged files.
- ETL: 69,206,016 bytes; SHA-256
  `f8536e1049d69832ed4bf93d0ef4b1d4d908e5cbc953d4f6ca18aace3079746a`.
- `inventory.json`: Windows 10 Pro 22H2, **19045.6466**, x64.
  Inventory ran 03:08:03.518 through 03:08:07.586 UTC.
- Questionnaire: CECHZC1U PS3 controller over USB, Stellar Blade v1.4.1.0,
  rumble disabled, high CPU while playing. Whether the symptom occurred
  during this trace and its exact onset are unspecified.
- Both `GameInputSvc` and `GameInputRedistService` were Running / Auto.
  The questionnaire says `Disable GameInput Service`; this describes the
  reported workaround, not a measured disabled-service condition or A/B.
- Inbox API and loaded `gameinputinbox.dll`: **0.2309.19041.6456**;
  inbox host: **0.2309.19041.6033**. PID 6188 loaded the inbox implementation;
  the system service host was PID 5264.
- Redist: **4.0.302.0**. PID 12120's module enumeration lists both Program Files
  and System32 copies of `GameInputRedist.dll`; their backing-file hashes match.
  This differs from the locally inspected 3.5.270.0 implementation, whose
  static control flow must not be assumed for this version.
- `xinputhid.sys`: **10.0.19041.5794**, inventory SHA-256
  `c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f`.
  The Windows 10 driver has not been statically inspected.
- ETL `FileVersion` metadata reports `dshidmini.dll` **3.27.0.2500**.
  Its binary hash was not collected. Inventory lists a present PLAYSTATION(R)3
  controller using `mshidumdf` and an XINPUT compatible HID device; this alone
  does not map every traced handle to that controller or certify its mode.

The derived JSON preserves relevant binary paths, versions and hashes.
Authenticode `Valid` values are contributor-side inventory results, not an
independent signature check or an experimental-probe allowlist.

## Retention limits

The ETL header spans **03:08:10.0546505–03:09:51.6889852 UTC**,
101.6343347 seconds. `xperf -a tracestats` reports zero lost buffers/events,
consistent with the collector's status. However:

- The first retained sampled-profile event is at **92.759084 s**; the last
  is at 101.523349 s. The first sample varies by CPU, as late as 96.983865 s.
- `FirstReliableCSwitchEventTimeStamp` is **96.983514 s**; the last retained
  switch is at 101.279396 s. Earlier retained switches start at 92.759053 s
  but do not give complete coverage across all CPUs.
- Only one `GameInput:` phase mark survives, at 101.137488 s; it lacks a
  phase-specific label. JSON phase times remain available independently.

The subsequent collector review found why the label is generic: PowerShell
expands `"GameInput:$phase:start"` to `GameInput:`. The collector now braces
the variable (`"GameInput:${phase}:start"` and the corresponding end marker).
This correction does not restore missing events in the contributed trace.

This is consistent with the documented 64 MiB system memory buffer wrapping.
Zero loss counters do not establish retention of earlier events. Whole-trace
CPU percentages dilute the surviving samples over missing time and must not
be used to claim low CPU throughout the recording. Baseline, idle and input
CPU comparisons are unavailable. The usable tail falls within the requested
rumble phase, but every phase has `OperatorConfirmed=false`, and the
questionnaire says vibration was disabled. Actual vibration is unknown.

## CPU evidence in the retained tail

Using **97–101 s** after ETL start (03:09:47.0546505–03:09:51.0546505 UTC),
`xperf -a profile -detail -range 97000000 101000000` gives:

- WUDFHost PID 1372: 216,000 microseconds sampled weight, approximately
  **5.4% of one core / 0.3375% of the 16-logical-processor machine**.
- Inbox GameInput PID 6188: 10,000 microseconds, approximately
  **0.25% of one core / 0.015625% of the machine**.
- Redist PID 12120: 5,000 microseconds, approximately
  **0.125% of one core / 0.0078125% of the machine**.
- The game accounts for about **22.71% of machine capacity** in this window.
  This does not establish whether its workload or frame pacing is abnormal.

These are sampled estimates with a four-second denominator, not lifetime
process CPU counters or per-request latency. Sum unrounded weights before
calculating percentages; individual printed module percentages round heavily.
WUDFHost stack samples include DsHidMini, UMDF/WDF, HIDCLASS and xinputhid.
Function symbols were unresolved, so module participation cannot identify
the operation, payload, caller responsible for output, or a defective loop.
The brief window does not demonstrate a sustained high-resource condition.

## Provider and causal limits

The decoded event stream contains two DsHidMini events, 16 HIDCLASS events
(mostly initial rundown), and 87,179 Kernel-IoTrace events. No named WDF
performance events were decoded; 84,200 `UnknownEvent/Classic` rows remain
unclassified. Enabled providers and undecoded events do not establish complete
driver coverage. The two DsHidMini events do not form an output-command stream.

The probe provider was omitted and there are no native probe snapshots.
No defensible count of `0x8000e388`, immediate/pending completions, unchanged
states, or rumble-off packets was derived. No input fidelity, frame-time,
service A/B, throttle, or recovery experiment was performed. The existing
causal and mitigation gates remain unvalidated.

## Reproduce the review

Use the trusted repository validator against the ZIP; never run the contributed
collector scripts as part of analysis. In this review Windows PowerShell 5.1
blocked script execution under its execution policy. An independent Python
ZIP/manifest check verified every SHA-256, rejected unsafe/duplicate paths,
checked the 512 MiB uncompressed bound, and extracted the files locally.
No execution-policy setting was changed.

Analysis used installed `xperf.exe` **10.0.28000.2270**:

```powershell
$trace = 'captures/community/20261028-030803-08710ec5/capture.etl'
xperf -i $trace -a tracestats
xperf -i $trace -a marks
xperf -i $trace -a profile -detail -range 97000000 101000000
xperf -i $trace -a stack -butterfly 2 -pid 1372 6188 12120
xperf -i $trace -o captures/community/20261028-030803-08710ec5/events.csv -a dumper
```

The CSV is private raw-derived material. Inspect `SampledProfile` time ranges
per CPU and `FirstReliableCSwitchEventTimeStamp`, rather than inferring
coverage from the trace header. For each process sum profile `Weight` in
microseconds; one-core percent is `100 * weight / 4000000`, and machine
percent divides that result by 16. This does not count IOCTLs.

## Next useful evidence

Ask the contributor whether the symptom was visible during recording, when
it occurred, which process was high, what physical phase actions occurred,
and whether vibration was actually requested or observed. Confirm exactly
which service their workaround disables. A follow-up should preserve service
and driver settings and record one short symptomatic interval ending
immediately in trace saving, then verify retained coverage. Do not request
an experimental throttle from this package: the matching pathological
completion behavior has not been measured, and these builds are uninspected.
