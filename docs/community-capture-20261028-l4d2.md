# Left 4 Dead 2 community capture, 2026-10-28

This follow-up provides a concrete runtime lead: a nearly fully occupied game
thread spends about **68% of its retained sampled stacks inside XInputGetState**,
mostly through device enumeration and handle close/cleanup into xinputhid/WDF.
This is expensive work charged to the game process, despite low CPU in the
GameInput service processes. It is not evidence of the proposed unfiltered-state
or rumble-off flood, and the service's causal role still needs a matched comparison.

Reviewed data: [derived summary](../evidence/runtime/community-20261028-8b1526ae-summary.json).
The [earlier Stellar Blade capture](community-capture-20261028.md) is a different
workload and recording, not a service-disabled control for this run.

## Operator report and service identity

The contributor reports Left 4 Dead 2 menu FPS falling from over 900 to below
100, and gameplay from around 600 to below 100 with heavy stuttering, when the
GameInput service is enabled and the controller connected. These are operator
observations, not FPS/frame-time measurements extracted from this package.
The quoted messages do not establish exact scene or symptom timing within the
retained trace. The announced video clip was not supplied with this review.

The separately supplied Services screenshot shows **GameInput Service** with
startup type **Disabled** and no Running status displayed. **GameInput Redist
Service** is Running / Automatic. This identifies the reported workaround as
the inbox `GameInputSvc`, rather than the redist service. The screenshot's timing
relative to capture is unknown. In the package's inventory, **both services
are Running / Auto**; it is not a disabled-service trace or a paired A/B.

The screenshot is preserved privately with SHA-256
`65a6fe94b9ca64d70feb0184dab2e926dea186cd4d0214c647fdc890aab99f08`.
No contributor messages, screenshots or raw diagnostics were uploaded.

## Package and configuration

- ZIP: `GameInput-20261028-192856-8b1526ae.zip`, **10,959,496 bytes**,
  SHA-256 `3580d870776cd1cb94187db92e8047c068bf81e015349782564ce038b2f65968`.
  All **28 manifest entries** verified, with no extra packaged files.
- ETL: **67,108,864 bytes**, SHA-256
  `d0a05680939302844c3a7a0c7a0df32747906eabe04c7be1d8e57055c2610f59`.
- Windows 10 Pro 22H2 **19045.6466**, x64, 16 logical processors.
  CECHZC1U PS3 controller over USB; questionnaire says rumble **No** and
  Left 4 Dead 2 latest version June 30th, 2026. Game build was not authenticated.
- Inbox implementation **0.2309.19041.6456**, host **0.2309.19041.6033**;
  redist **4.0.302.0**, xinputhid **10.0.19041.5794**.
  All 13 collected GameInput/xinputhid binary hashes match the earlier package.
  The inventory paths and hashes are preserved in its linked derived summary.
- Loaded inbox implementation: `gameinputinbox.dll` in PID **11956**;
  system inbox host PID **11188**. System redist PID **5508** lists both
  Program Files and System32 redist DLLs; per-user redist PID **7828** lists
  the System32 DLL. WUDFHost of interest is PID **1388**.
- ETL metadata identifies DsHidMini **3.27.0.2500**. Its hash is unavailable.
  The game uses the x86 `XInput1_4.dll` **10.0.19041.3636**, image size
  `0xd000`, PE timestamp `0x781fbf32`, PDB GUID
  `822D0923E019D817BF1A55A08D50A9A2`, age 1. WDF metadata reports
  **1.31.19041.5794**. Backing-file hashes for these two modules are unavailable.

Raw files and analysis exports stay under ignored
`captures/community/20261028-192856-8b1526ae/`. Original packages are preserved.
No live experiment, service change, injection or throttle was performed.

## Coverage: the old collector was used again

The packaged `Collect-Diagnostics.ps1` and `Collector.Common.ps1` are
byte-identical to those in the first package. They precede the short symptomatic
default, separate phase traces, explicit readiness and corrected markers.
This run again recorded four 15-second phases plus 10-second preparation periods.
Every phase has `OperatorConfirmed=false`; requested phases are not confirmed
physical actions. In particular, the last phase is named rumble despite the
questionnaire saying No.

The trace spans **19:29:03.0874344–19:30:44.3906656 UTC** (101.3032312 seconds).
`xperf` reports zero lost buffers/events, but system memory buffers apparently
wrapped. The first retained CPU sample varies by processor from **65.130557 s**
to **86.784040 s**; reliable context-switch coverage begins at **86.787816 s**.
The last switch is at 100.987652 s. Two generic `GameInput:` markers survive;
the old interpolation defect removed their phase names.

Analysis therefore uses the common **87–100 s** window, corresponding to
**19:30:30.0874344–19:30:43.0874344 UTC**. It falls within the requested final
phase, without certifying vibration or the reported symptom. Earlier phases
cannot supply a valid CPU comparison. Whole-trace CPU percentages would dilute
the retained samples over missing time and are not used.

## CPU and hot path

Sampled CPU estimates over those 13 seconds:

- `left4dead2.exe` PID **12076**: **160.14% of one core / 10.009% machine CPU**.
- WUDFHost PID **1388**: **2.585% of one core / 0.162% machine CPU**.
- Inbox worker PID **11956**: **0.339% of one core / 0.0212% machine CPU**.
- System redist PID **5508**: **0.100% of one core / 0.00625% machine CPU**.

Game thread **11880** has 12,983 sampled-profile events. Summing its retained
context-switch intervals gives **12.987294 seconds scheduled out of 13 seconds**,
about **99.90% of one logical processor**. Scheduled residency can include
interrupt work; it is not identical to a per-function CPU measurement.

Of **12,970 available sampled stacks** for that thread in the window:

- **8,811 (67.93%)** include `XInput1_4!XInputGetState`.
- **8,750 (67.46%)** include `EnumerateXInputDevices`.
- **8,291 (63.92%)** include `NtClose`; **8,228 (63.44%)** include `IopCloseFile`.
- **8,221 (63.38%)** include `xinputhid!EvtDeviceWdmIrpPreprocess`.
- Exclusive sampled leaves include `KeAcquireSpinLockRaiseToDpc` **3,165
  (24.40%)**, `Wdf01000!FxObject::Release` **2,938 (22.65%)**, and
  `KeReleaseSpinLock` **1,774 (13.68%)**.

Inclusive counts overlap and must not be added. These are samples of where
execution occurred, not counts of calls, IOCTLs, closes or lock contention.
Lock-function samples alone do not establish a lock owner or prove spinning.

A representative stack at **90.000157 s**, caller toward sampled leaf with
intermediate WOW64/WDF frames omitted, is:

```text
inputsystem.dll+0x6275
  GameOverlayRenderer.dll+0xba4b2
  XInput1_4!XInputGetState
  XInput1_4!XInputCore::ProcessAPIRequest
  XInput1_4!DeviceEnum::GetDeviceOnPort
  XInput1_4!EnumerateXInputDevices
  nt!NtClose -> nt!IopCloseFile
  xinputhid!EvtDeviceWdmIrpPreprocess+0x211 (RVA 0x3451)
  Wdf01000!FxPkgGeneral::Dispatch+0x2f9 (RVA 0x7029)
  nt!KeAcquireSpinLockRaiseToDpc+0x59 (RVA 0x2d8a39)
```

Steam overlay frames participate in the chain; this alone does not implicate
the overlay. Public Microsoft symbols matched the ETL's recorded PDB GUIDs and
ages. Their identities and hashes are recorded in the derived summary; game
and some Windows frames remain unresolved. Symbolization is runtime evidence,
not a static analysis of the Windows 10 driver.

## What this changes and what it does not

The useful lead is now **game-side XInput enumeration/handle-close cost**, rather
than only looking for high CPU inside GameInputSvc or WUDFHost. An expensive
input path on an almost fully occupied game thread is consistent with the
reported performance problem. It does not establish the FPS impact, service
dependency, device-handle association, or which component is defective.

The provider stream contains two named DsHidMini events and 248,365 unclassified
classic events; no named HIDCLASS or WDF performance rows were decoded.
Kernel-IoTrace decoded rows carry activity identifiers without IOCTL codes,
completion state or output bytes. There are no probe snapshots. State-request
rates, immediate/pending behavior and rumble-off rates remain unknown.
Nothing here qualifies the experimental throttle or enables a compatibility gate.

## Reproduce and continue

Analysis used `xperf.exe` **10.0.28000.2270**. Verify the ZIP manifest first,
then inspect retention and use the selected interval:

```powershell
$trace = 'captures/community/20261028-192856-8b1526ae/capture.etl'
xperf -i $trace -a tracestats
xperf -i $trace -a marks
xperf -i $trace -a profile -detail -range 87000000 100000000
# With trace-matched public symbols already downloaded locally:
$env:_NT_SYMBOL_PATH = 'srv*D:\RE\GameInput\symbols\community-win10'
$env:_NT_SYMCACHE_PATH = 'D:\RE\GameInput\captures\community\20261028-192856-8b1526ae\symcache'
xperf -i $trace -symbols -a stack -butterfly 2 -pid 12076 -tid 11880 -range 87000000 100000000
xperf -i $trace -symbols -a dumper -range 90000000 90010000 -stacktimeshifting
```

For CPU, sum unrounded profile Weight in microseconds by process, divide by
13,000,000 and multiply by 100 for one-core percent; divide again by 16 for
machine percent. Stack percentages use the 12,970 sampled-stack denominator.
Keep large exports private.

The next useful operator experiment, if they agree, is a matched pair using
the **updated collector**: the same fixed menu scene, controller connection and
vibration settings, first with the inbox service enabled and symptom visible,
then with the operator's inbox-service workaround applied. Leave the redist
service unchanged, record actual FPS and service states for each run, and save
each short capture separately. Verify retention before comparing the hot thread
and XInput enumeration/close stacks. A video can corroborate the visible FPS
change; it cannot replace the trace comparison or prove a driver mechanism.
