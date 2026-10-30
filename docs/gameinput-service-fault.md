# GameInput service fault

Static findings from installed binaries, matched to public reports. **The original user-mode analysis identified a hypothesis, not a proven cause or a confirmed Windows 11 regression.** The kernel follow-up below changes an important assumption: with the request flag clear, `xinputhid` queues the unfiltered-state request instead of always returning cached state immediately. Runtime measurements and controller safety tests determine whether a mitigation applies.

See [kernel analysis](kernel-xinputhid.md), [diagnostic collection](collecting-diagnostics.md), [version evidence](version-matrix.md), [research workaround](workaround.md), and [implementation status](implementation-status.md).

**2026-10-30 version follow-up:** the [PID initialization history](xinputhid-pid-version-history.md)
now verifies the correct queued implementation in xinputhid **10.0.22621.3085**,
shipped with **Windows 11 22H2 / 22621.3085 and 23H2 / 22631.3085** in
**KB5034204, January 23, 2024**. It predates 24H2/25H2. The preceding inspected
Windows 11 revision lacks this handler, so this does not establish a Windows 11
broken-to-fixed transition. No corrected Windows 10 shipping driver or general
game-performance fix has been established. This driver finding must not be
equated with Microsoft's separately reported newer-GameInput compatibility fix.

The latest inspected Windows 10 package, **KB5134125 / October 26, 2026**,
still reconstructs the exact affected driver bytes. An older 19041.3636
driver lacks the queued handler, narrowing the inspected introduction window.
See [shipping-package verification](xinputhid-pid-version-history.md#latest-windows-10-package-verified).
The operator's untouched-controller breakpoint observation is now tracked in
[the DsHidMini idle-completion review](dshidmini-idle-completions.md), with
static equality gates distinguished from unmeasured runtime completion rates.
The follow-up now observes an equal report returning AL=0 and a matched,
operator-confirmed untouched-controller left-Y change returning AL=1 and
advancing its packet. The stopped/running public-state recordings both show
small variation after controller use. They do not establish service causation
of that variation or an unchanged-success flood; physical DS3 wire input and
actual dead-zone configuration remain uncollected.

## Reports

- [nefarius/DsHidMini#438](https://github.com/nefarius/DsHidMini/issues/438), closed as an external component. Windows 10 22H2. After a controller is connected in XInput HID mode, `WUDFHost.exe` and `xinputhid.sys` climb in CPU and games stutter. SXS mode does not. Unplug or killing `WUDFHost` clears it until the device returns. Repeated rumble-off traffic was an assumption based on one ETL supplied in that issue, not an observed packet sequence or established cause. The operator clarified this on 2026-10-28; the earlier wording that Nefarius had traced those packets was incorrect.
- [microsoftconnect/GameInput#34](https://github.com/microsoftconnect/GameInput/issues/34). Disabling GameInput Service stops FPS drops reported in games such as Gears Reloaded, Marathon (2026), and Battlefield 6. On 2026-07-23 Microsoft said this was a compatibility issue with older Windows 10, fixed in newer GameInput, and named neither the fault, the Windows builds, nor the package versions. On 2026-10-25 the reporter pointed at a new Windows 11 report and said the stutter is likely back.
- The PCMR thread cited there could not be fetched (Reddit challenge page).

Public release notes never name this bug. Closest lines:

- v2.2: rumble became unresponsive on some devices under load.
- v3.0: performance regression for Xbox One controllers on Windows 10.
- v3.3.195.0 (2026-04-24): "stability and performance" only.

## This machine

Windows 11 25H2, build 26200.9457 (`Win32_OperatingSystem` caption: Microsoft Windows 11 Business). Both services were running.

| Component | Path | Version | Dated |
| --- | --- | --- | --- |
| GameInput Service (`GameInputSvc`) | `C:\Windows\System32\GameInputSvc.exe` | 0.2309.26100.9278 | 2026-09-09 |
| Inbox API / service logic | `C:\Windows\System32\GameInput.dll` | 0.2309.26100.9278 | 2026-09-09 |
| GameInput Redist Service | `C:\Program Files\Microsoft GameInput\x64\GameInputRedistService.exe` | 3.5.270.0 | 2026-08-31 |
| Redistributable logic | `C:\Program Files\Microsoft GameInput\x64\GameInputRedist.dll` | 3.5.270.0 | 2026-08-31 |
| `xinputhid.sys` | `C:\Windows\System32\drivers\xinputhid.sys` | 10.0.26100.9278 | same stamp as inbox GameInput |

`GameInputSvc.exe` is a small host. It references both `GameInput.dll` and `GameInputRedist.dll`, plus `RedistDir`, `CopyFileW`, `VerifyVersionInfoW`, and the string `GameInputService watchdog runaway`. The redistributable is newer than the last public GitHub release (v3.3.195.0) and its PDB is not on the public symbol server. Inbox `GameInput.pdb` (`B2F221BEF567C87A783089F3FE8B3C51`, age 1) loaded and supplied private names.

SHA-256:

- `GameInput.dll`: `f9f5adbde4a2883b9b307bb1848a120094904578d92b21100828bd83f7b77cb6`
- `GameInputRedist.dll`: `6d3650dbeea5f8c639972537dbaed3f2bb465561e63d34fa9661902f24cb9686`

## User-mode mechanism under investigation

The identified loops submit `IOCTL 0x8000e388` (`IOCTL_XINPUT_GET_UNFILTERED_GAMEPAD_STATE`, 0x18-byte state). A loop that waits on a pending request is different from a loop receiving repeated immediate completions. The mode difference in the DsHidMini reports identifies a useful comparison, but neither repeated rumble-off traffic nor a causal link from this state IOCTL was established by the issue's ETL.

### Redistributable, version 3.5.270.0

`GameInput::Backend::XInput::Device::ThreadProcSystem` in `BeXInputDevice.cpp` (`FUN_1800519ec`):

1. Submit `IOCTL 0x8000e388`.
2. If the packet number changed, publish the reading.
3. `WaitForSingleObject` for 1 ms.
4. Repeat until the stop event is signaled (`E_ABORT` / `0x80004004` ends the thread).

`GameInput::Common` `Driver.cpp` (`FUN_180060468`) waits until the IOCTL completes. `ERROR_IO_PENDING` waits on the overlapped event. The caller's wait timeout word is `0xFFFFFFFF` (infinite). A 100 ms sleep is used only between failed attempts, and only up to 3 retries (`local_4c = 3`, `local_48 = 100`). A successful immediate completion never takes that delay, so a driver that returns the current state instead of pending until a change is polled at about 1000 requests per second.

`FUN_1800557a0` / `FUN_180064fa8` is the version gate. `RtlGetVersion` with `dwOSVersionInfoSize = 0x11C`. The inner check returns true when `dwMajorVersion > 10`, or `dwMajorVersion == 10` and `dwBuildNumber > 21999`. The quirk helper returns the inverse. The IOCTL flag byte is therefore set, and the log line `Quirking for IOCTL_XINPUT_GET_UNFILTERED_GAMEPAD_STATE` is emitted, on Windows 10 (builds through 21999, including 22H2). Windows 11 (build 22000 and later) leaves the flag clear. The 1 ms loop is not inside that check.

### Inbox `GameInput.dll` 0.2309.26100.9278

`XusbWatcher::WorkerThread` (`FUN_180042e98`) submits the same unfiltered-state request, **then waits on the completion event with `NtWaitForSingleObject` and a null timeout**. The earlier analysis omitted this material wait. The worker sets request byte 3 to zero, selecting the queued/change-driven path in the inspected driver. A separate support probe sets it to one. The 100 ms failure backoff is an additional delay; its absence after a valid completion does not imply a busy spin. See [independently validated user-mode control flow](user-mode-validation.md) for exact call sites and byte-checked evidence.

The inbox compares output bytes 5–23, while the redist compares the packet counter at output offset zero. The probe compares all 24 bytes. These are different comparisons and must not be conflated in runtime analysis.

`HidForceFeedbackScheduler::WorkerThread` (`FUN_180022678`) calls `timeBeginPeriod(1)` around scheduled sampling. The wait timeout is the time until the next sample divided by 1000. A sample that is already due becomes a 0 ms wait. A generation change calls `HidForceFeedbackDriver::Reset` (`FUN_18001a570`). These are candidate profiling sites, not demonstrated defects: a due sample can be normal scheduling, and calling `timeBeginPeriod` alone does not prove CPU or frame-time harm.

`GipQuiesceWatcher` (`FUN_18001a21c`, called from `WaitForQuiesce` at `FUN_180022438`): IOCTL `0x40001dc0`. `ERROR_IO_PENDING` (`0x3E5`) is the expected arm. A synchronous success logs `GIP quiesce notification completed immediately, retrying` and retries with no sleep, at most 50 times, then returns `0x8000FFFF`. That is a burst, not the sustained poll.

`FeedbackManagerState.cpp` (`FUN_180014ed8`) logs `Legacy GIP equation manager IS allowed` or `NOT allowed` from a device id/firmware table (`DAT_180054bd8`) and a flag at object offset `0xAB`. That gate is per device, not per OS build.

## Kernel follow-up

Ghidra with the matching public PDB identifies `DispatchGetUnfilteredGamepadState` at `0x14000d1d8`. It validates input size 4, output size 24, and the input header `0x0103`. Input byte 3 selects behavior: nonzero copies cached state and completes, while zero uses a per-requestor-process queue. See [the detailed analysis](kernel-xinputhid.md) for completion paths, feature gates, hashes, and the evidence needed to connect this to output/rumble traffic.

The redist's Win10 quirk sets this byte; Windows 11 clears it. Consequently, the existence of the redist's 1 ms loop does **not** establish a 1000 Hz successful poll on Windows 11. Completion behavior must be measured. This also does not establish which version Microsoft fixed.

The running per-user redistributable was observed loading `C:\Windows\System32\GameInputRedist.dll`; its SHA-256 matches the `Program Files` DLL above. Future diagnostics must record loaded module paths rather than assume the installation path.

## Bluetooth comparison

On the same machine/controller over Bluetooth LE, 44.75 measured seconds produced 1,439 target requests in the inbox process and 1,391 in the system redist, all pending. CPU was approximately 0.175% and 0.105% of one core, including probe overhead. The independent monitor recorded 1,279 packet values. There were no immediate successes or throttled calls. [Bluetooth summary](../evidence/runtime/bluetooth-active-input-summary.json).

The operator has not knowingly observed the original symptom on this machine. Neither connection is a confirmed affected reproduction. These comparison results cannot identify Microsoft's historical fix, establish the cause of the reports, or qualify the proposed throttle for release.

## What is still open

The [Left 4 Dead 2 follow-up](community-capture-20261028-l4d2.md) adds a
different runtime lead on Windows 10: in a retained 13-second interval, a
nearly fully occupied game thread has XInputGetState on 67.93% of sampled
stacks, mostly through device enumeration and handle cleanup into xinputhid/WDF.
CPU in the GameInput service processes and WUDFHost is low in that window.
The contributor identifies the disabled-service workaround as inbox
`GameInputSvc`, with the redist still running, but no matched disabled-service
trace or frame-time series was available for that initial review. A later
[updated-collector disabled run](community-capture-20261028-l4d2.md#disabled-service-follow-up-195831-4dcb7591)
records the inbox stopped/disabled, redist running and no operator-observed
symptom. The cleanup-dominated game-thread path is greatly diminished, but the
machine rebooted and workload equivalence to the old enabled capture is unknown.
The corresponding [updated-collector enabled run](community-capture-20261028-l4d2-pair.md)
has now arrived: same boot, game process UniqueKey, thread and four-second
window duration as the new disabled run. Inbox running correlates with the
reported symptom throughout and XInputGetState on **88.58%** of hot-thread
stacks, versus **19.87%** disabled. The cleanup path similarly returns, while
the redist remains running. This supports a service-condition association; exact
scene/focus, numeric FPS and the underlying driver cause remain unverified.
This does not establish the original
unfiltered-state/rumble-off flood or justify throttling it.

The [2026-10-28 community package](community-capture-20261028.md) adds Windows
10 22H2 inventory and a partial CPU trace with a USB PS3 controller. Its
memory buffers apparently wrapped, leaving only a short usable CPU tail;
the reported symptom's occurrence during that capture is unspecified.
It establishes neither immediate state completions nor rumble-off flooding.
Redist 4.0.302.0 remains statically uninspected. The exact Windows 10 driver
was subsequently acquired and inspected; see the fix direction below.

The corrected probe then completed a USB active-input run: 44.75 measured seconds, **2,014 target requests in the system redist process, all returning `ERROR_IO_PENDING`**, zero immediate successful/unchanged responses and zero throttled calls. The process used about 0.279% of one core, including instrumentation overhead. The other two instrumented GameInput processes made no matching requests in that interval. XInput independently recorded 1,246 distinct packet values. See [the reviewed runtime summary](../evidence/runtime/active-input-summary.json). This is a negative reproduction of the proposed busy-poll mechanism, not proof of a fix or proof that all Windows 11 configurations are unaffected.

The first local collector validation produced an 11.59-second idle ETL with zero lost events/buffers according to `xperf`, and its ZIP passed all 28 manifest checks. The sampled GameInput row printed 0.00% (rounded). This window did not demonstrate the reported fault. The initial probe attach failed before its shared mapping existed; no request rate can be inferred from that attempt. See [derived baseline evidence](../evidence/runtime/baseline-summary.json). Later measurements must be recorded separately rather than rewriting this attempt as successful.

- No live trace yet of `IOCTL 0x8000e388` rate, pending-IRP count, or `xinputhid` completing immediately versus waiting for a packet change.
- Repeated rumble-off traffic was an assumption, not a measured flood. Its existence would first need to be demonstrated before testing any correlation with state requests and driver output events. Reading state and writing vibration use different kernel dispatch paths.
- Which of the two services a given report disabled is not always stated. "GameInput Service" is the inbox display name. The redist service is a second poller and was running here too.
- The inspected redist's Windows 10 quirk selects cached immediate state; the inspected Windows 10 inbox worker instead selects queued state. Their actual request rates and resource impact require separate runtime measurement.

## Fix direction

The [exact Windows 10 driver follow-up](windows10-queue-identity.md) now
identifies a concrete missing PID initialization in the queued unfiltered-state
path. The contributor-hash inbox worker selects that path. Repeated creation
of queues instead of reuse can add handle-close cost in the research VM:
uncorrected fresh-device queues accumulated, while initializing one GameInput
entry's PID restored reuse and retained one node. In a
[single paired metadata-only benchmark](vm-queue-comparison.md#paired-handle-close-result),
median close duration fell from 411.45 to 11.7 microseconds across 100 successful
pairs per condition. Unequal exposure and incomplete retired-device teardown
limit that comparison; the game's x86 path, frame times and controller fidelity
remain unvalidated. This is a focused mechanism/performance PoC in one guest,
not proof of the contributor's FPS cause or a supported fix.
A [reversed-order check](../evidence/runtime/vm-handle-close-reversed-pair-20261029.json)
also found much higher close cost uncorrected (437.8 versus 11.15 microseconds
median). It reused the corrected lifetime, so this is not four independent
fresh-device replications. The [next prepared workload](vm-xinput-state-comparison.md)
measures the exact x86 XInput API rather than metadata-only handle operations.
That [x86 comparison](vm-xinput-state-comparison.md#corrected-comparison-2026-10-29)
has now completed: disconnected-slot medians fell from 1.83-2.75 ms to
42-125 microseconds, with 100 calls per slot/condition, matching binaries and
the corrected queue list still at one. This is direct API-level PoC evidence
for the local mechanism, retaining single-pair/exposure/teardown limits.
A [process-scoped cleanup observation](../evidence/runtime/vm-xinput-cleanup-route-20261029.json)
now follows the controlled absent-slot call through NtClose, xinputhid cleanup
and the actual loaded WDF queue traversal, including the corrected manual queue.
The x86 user stack could not be unwound, so user-mode enumeration frames are not
claimed. Debugger-paused calls are excluded from latency measurements.
[Coarse input and vibration checks](../evidence/runtime/vm-input-vibration-20261029.json)
also succeeded in this corrected guest lifetime: 1028 held-input samples, API
success for vibration start/stop and the operator's physical confirmation. This
does not establish every transition, physical input latency or game frame times.
The [fresh corrected-first idle comparison](../evidence/runtime/vm-xinput-fresh-reversed-pair-20261029.json)
is a useful negative control: with approximately four minutes untouched per
condition, the unmodified device had 48 entries versus one corrected entry,
but API medians were similar. A later
[30-second moving-stick phase](../evidence/runtime/vm-active-input-growth-20261029.json)
was followed by 3383 entries and absent-slot medians of 489-773 microseconds,
roughly 4-10 times the preceding unmodified idle result. This is an
activity-associated accumulation/cost observation, not an unchanged-state flood
or a precisely measured allocation rate. Its continuous movement workload has
no fresh corrected counterpart.

The [service stop/start check](../evidence/runtime/vm-service-recovery-20261029.json)
then terminated the observed producer processes but retained 3383 entries and
elevated API costs. Restoring Running/Manual service state produced new service
processes and 3384 entries, with similar elevated costs. In this guest, stopping
the producer after accumulation does not clear the accumulated device lifetime.
See the [completed VM batch checklist](vm-validation-checklist.md) for provenance,
coarse input/reconnect results and limitations. Game frame times remain untested.
The inspected Windows 11 driver includes the missing store. This gives a focused
correction to test separately from the earlier throttling hypothesis; it does not
enable any compatibility or mitigation gate.

Stopping a service removes its GameInput work, but that observation alone does not identify which operation caused a symptom. The inspected inbox worker waits for completion and has not been shown spinning. Games that require GameInput can lose the API when its services are disabled.

If an immediate unchanged-completion flood is demonstrated, the experimental hook can delay only that exact successful result while preserving buffers and errors. Its initial interval is 8 ms. This can add input latency or miss brief transitions between polls and therefore requires input/rumble/reconnect tests. Blindly applying the 100 ms failure backoff to successful reads is not a validated fix.

Pending requests, errors, unrelated IOCTLs, and unsupported builds remain pass-through. Scheduler and quiesce changes need independent runtime evidence before being recommended upstream. A local A/B improvement would validate a workaround for that configuration; it would not prove every GameInput lag report has the same cause.
