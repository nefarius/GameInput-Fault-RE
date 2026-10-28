# Left 4 Dead 2: updated-collector service comparison

The two new recordings provide **same-boot evidence linking the inbox service
condition to expensive game-side XInput enumeration/handle cleanup**. With inbox
GameInputSvc stopped/disabled, the operator reports no symptom and the cleanup
path is small. With it running, the operator reports the symptom throughout,
the same game thread becomes almost fully occupied, and cleanup dominates its
sampled stacks. The redist stays running throughout.

This is stronger than the earlier cross-boot comparison. It does not identify
the underlying driver defect, measure the reported FPS change, establish the
original unfiltered-state/rumble-off flood, or qualify the experimental throttle.

Sources:

- [Disabled run summary](../evidence/runtime/community-20261028-4dcb7591-summary.json),
  `GameInput-20261028-195831-4dcb7591.zip`.
- [Enabled run summary](../evidence/runtime/community-20261028-3bd8c4d9-summary.json),
  `GameInput-20261028-200724-3bd8c4d9.zip`.
- [New pair comparison](../evidence/runtime/community-20261028-l4d2-updated-collector-comparison.json).
- [Earlier recordings and historical comparison](community-capture-20261028-l4d2.md).

## What matches

Both recordings use Windows 10 Pro 22H2 **19045.6466**, x64, 16 logical CPUs,
booted **2026-10-28 19:54:37.5 UTC**. There is no intervening reboot. The recorded
game PID **12276**, hot-thread TID **11984** and game ETL process UniqueKey all
match, providing stronger identity evidence than a PID alone. Creation UTC was
not independently collected.

All packaged collector sources and the generated WPR profile are byte-identical.
Both runs use the current five-second symptom phase with explicit readiness and
post-save operator reports. Both retain CPU samples across all processors from
the beginning, reliable switches before the chosen window, both corrected phase
markers, and zero reported lost buffers/events. Both are analyzed over **1–5 s**
after their respective ETL starts, giving equal **four-second** windows wholly
within the phase markers. Buffer wrap does not invalidate these selected windows.

The reported controller is CECHZC1U over USB, with no vibration and normal
controller use in both runs. The redist service is **Running / Auto, PID 5280**
in both inventories. The 12 shared GameInput/xinputhid inventory hashes match.
The enabled-only loaded inbox implementation is `gameinputinbox.dll`
**0.2309.19041.6456**, PID **2868**; its hash matches the earlier enabled package.
DsHidMini metadata is **3.27.0.2500**. Public PDB GUIDs/ages for XInput, xinputhid,
WDF and the kernel match across the pair and match the local symbol cache.

Active power scheme **High performance** and the recorded power-settings output
match. Background power-request output differs; the recordings do not establish
that every other environmental variable remained constant.

## What changes

Chronological order is **disabled, then enabled**:

- Disabled: inbox **Stopped / Disabled, PID 0**. Operator reports **no symptom**
  and explicitly says the workaround was applied.
- Enabled: inbox **Running / Auto, PID 8264**. Its per-user implementation is
  loaded in PID **2868**. Operator reports **yes**, the symptom affected **the
  entire recording**, and identifies `left4dead2.exe` as the high-CPU process.

In the four-second analysis windows, hot-thread scheduled residency rises from
**2.587490 s (64.69% of one core)** disabled to **3.996432 s (99.91%)** enabled.
Residency can include interrupt activity; it is not a per-function CPU duration.

The disabled thread has **2,572 available sampled stacks**; enabled has **3,993**:

- `XInputGetState`: **511 / 19.87% disabled**, **3,537 / 88.58% enabled**.
- `EnumerateXInputDevices`: **477 / 18.55% disabled**, **3,532 / 88.45% enabled**.
- `NtClose`: **80 / 3.11% disabled**, **3,462 / 86.70% enabled**.
- `IopCloseFile`: **21 / 0.82% disabled**, **3,460 / 86.65% enabled**.
- `xinputhid!EvtDeviceWdmIrpPreprocess`: **12 / 0.47% disabled**,
  **3,459 / 86.63% enabled**.
- `Wdf01000!FxObject::Release`: **7 / 0.27% disabled**,
  **1,149 / 28.78% enabled**.

These are inclusive sampled-stack counts. Their categories overlap; do not add
them or interpret them as calls, closes, IOCTLs, lock contention events or latency.
The comparison JSON also expresses counts per elapsed second to account for
sample-denominator differences, explicitly retaining the sampled-stack units.

Enabled exclusive leaves are dominated by `KeAcquireSpinLockRaiseToDpc`
**1,267 stacks (31.73%)**, `FxObject::Release` **1,149 (28.78%)**, and
`KeReleaseSpinLock` **871 (21.81%)**. These symbols locate CPU work but do not
identify lock ownership or independently establish spinning.

The path matches the older enabled trace: XInputGetState, device enumeration,
NtClose/IopCloseFile, xinputhid IRP preprocessing and WDF dispatch/cleanup.
That recurrence adds consistency across enabled recordings; the old trace is
not substituted for either member of the new pair.

## CPU and interpretation

Enabled sampled machine CPU is approximately **7.551% for the game**, **0.547%
for WUDFHost**, **0.0594% for the inbox worker**, and **0.0219% for system redist**.
Disabled game CPU was approximately **10.946%**, even though its hottest thread
was less occupied. Total game CPU therefore does not measure symptom severity
or prove an FPS improvement: thread distribution and workload differ. The
important observation is the return of concentrated input/cleanup work on the
same hot game thread alongside the reported symptom.

The service-condition association is now supported by equal-duration,
same-collector, same-boot observations. Full experimental control is not
established: exact scene, window focus, FPS, game settings and physical action
equivalence were not independently captured. Both descriptions say normal use,
but that does not certify identical input or workload. There is one new recording
per condition, in a single order; background activity also differs.

The data supports prioritizing the Windows 10 xinputhid close/cleanup interaction
and XInput enumeration behavior. It does not tell us why enabling inbox GameInput
changes this cost. There are no IOCTL payload/completion measurements, command
counts, or input-fidelity/latency tests. The suspected state-request-to-rumble
mechanism and the proposed throttle remain unvalidated. No supported-tool gate
or binary allowlist is enabled by this review.

## Enabled package provenance and reproduction

The new enabled ZIP is **3,219,415 bytes**, SHA-256
`632d84645360e164151ada5013ddcfd9d8c43952a1edb3a7a47422d6ac9eaf91`.
All **27 manifest entries** verify, with no extra packaged files. Its ETL is
**26,214,400 bytes**, SHA-256
`c667417290a780eec813ecc22d0f79a991c295d562e4380f24bdf08d9d59703b`.
The ETL spans **20:07:44.4971312–20:07:49.9039053 UTC**, **5.4067741 s**.
Its markers occur at **0.055500 s** and **5.148571 s**. All CPUs have samples by
**0.001044 s**; reliable switches start at **0.015031 s** and continue past 5 s.

Original ZIPs and extracted raw data remain private under ignored `captures/`;
the new extraction is `captures/community/20261028-200724-3bd8c4d9/`.
No live experiment, injection, service change or upload was performed by the
analyst. The operator performed the service-condition runs.

Use installed `xperf.exe` **10.0.28000.2270** and trace-matched public symbols:

```powershell
$trace = 'captures/community/20261028-200724-3bd8c4d9/capture.etl'
xperf -i $trace -a tracestats
xperf -i $trace -a marks
xperf -i $trace -a profile -detail -range 1000000 5000000
$env:_NT_SYMBOL_PATH = 'srv*D:\RE\GameInput\symbols\community-win10'
$env:_NT_SYMCACHE_PATH = 'D:\RE\GameInput\captures\community\20261028-200724-3bd8c4d9\symcache'
xperf -i $trace -symbols -a stack -butterfly 1 -pid 12276 -tid 11984 -range 1000000 5000000
```

Repeat with the disabled ETL and its private symbol-cache location for the
other side. CPU weights are microseconds: one-core percent is
`100 * weight / 4000000`, machine percent divides by 16. Residency sums switch
intervals per CPU, clipped to the same window. Inspect raw timestamps and process
identity rather than using collector wall time or lifetime CPU counters.

The next research step is to inspect the exact Windows 10 driver close path and
its interaction with inbox-held device handles, using properly sourced matching
binaries. This is a hypothesis to investigate, not a conclusion about handle
ownership. Additional hardware experiments should follow an agreed scope and
measure frame time/input behavior independently; this pair does not justify
starting a throttle experiment.
