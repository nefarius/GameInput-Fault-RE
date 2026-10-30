# DsHidMini: requests while the controller is untouched

## Observation and question

On 2026-10-30 the operator recalled that, during the earlier VM debugging
session, resuming execution repeatedly hit the breakpoint without deliberate
controller input. This is an operator observation. No uninterrupted submission
rate, paired completion latency or state-byte equality was recorded at those
hits. An untouched controller has not thereby been measured as electrically or
logically unchanged.

The useful question is **which changes cause the queued client request to
complete while the controller is untouched?** Native Xbox XUSB behavior was
not inspected here. Its physical transport, a DsHidMini HID input read and
`xinputhid`'s queued unfiltered-state IOCTL are separate protocol layers.

## What the static evidence says

The [reviewed manifest](../evidence/static/dshidmini-idle-completion-20261030.json)
and [instruction excerpts](../evidence/static/dshidmini-idle-completion-20261030-excerpts.txt)
retain the exact identities and predicates. This follow-up uses REA/Ghidra
12.1.3 on the contributed **xinputhid 10.0.19041.5794**, hash
`c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f`.

**The Windows 10 driver has a decoded-state equality gate.** Its parser at
`0x1c0004698` compares two QWORDs at device offsets `0x90` and `0x98`, plus
a WORD at `0xa0`: **18 bytes in this version**. The compares are at
`0x1c0004dc2`, `0x1c0004dcf` and `0x1c0004dd8`. Equality branches at
`0x1c0004de0` to the unchanged return path.

The read completion routine at `0x1c0005560` calls that parser at
`0x1c0005656`, tests AL at `0x1c000565b`, and branches at `0x1c000565d` to
`0x1c0005cf8` when it reports no change. This skips the packet increment at
`0x1c0005778` and the ordinary per-process queued delivery. The unchanged
path continues lower read scheduling; repeatedly receiving raw HID reports
can therefore coexist with a pending higher-level client request.

**DsHidMini attempts input-report generation without an equality guard at the
XInput call site.** The reviewed source is release tag `setup-v3.27.0`, commit
`3f673849bcbc187a094775536c0583fd687014a2`, matching the installed release
number. Source-to-loaded-binary reproducibility was not independently verified.

- [InputReport.c, lines 541-568](https://github.com/nefarius/DsHidMini/blob/3f673849bcbc187a094775536c0583fd687014a2/driver/InputReport.c#L541)
  maps the DS3 report and calls `DMF_VirtualHidMini_InputReportGenerate`.
  There is no local equality check before that call. A generation attempt,
  its returned status and an actual lower HID read completion remain distinct.
- [DsHid.c, lines 900-1013](https://github.com/nefarius/DsHidMini/blob/3f673849bcbc187a094775536c0583fd687014a2/driver/DsHid.c#L900)
  maps transformed sticks, L2/R2 pressure, buttons, hat, PS and battery.
  This mapper contains no motion-field mapping or explicit per-report packet
  counter increment. Its stick transformation uses the configured dead zones.
  Each resulting 8-bit stick count is multiplied by 257, and each trigger
  pressure count by 4. Small changes that survive transformation therefore
  change the mapped report even when the operator perceives the pad as idle.
  This is a property of the source mapping, not a measurement of this pad.
- [The XInput HID descriptor](https://github.com/nefarius/DsHidMini/blob/3f673849bcbc187a094775536c0583fd687014a2/driver/HID/05_XIH_Col1_XInputHID.h)
  describes those axes/buttons and battery. A changing DS3 raw motion field
  cannot simply be assumed to change the decoded XInput comparison state.

Consequently, the breakpoint behavior is compatible with small stick or
trigger changes surviving mapping, buffered activity around debugger pauses,
or other request/completion paths. Those are hypotheses to discriminate.
This does not establish an unchanged-success flood or a DsHidMini defect.
The [missing PID initialization](windows10-queue-identity.md) can amplify
legitimate decoded changes by creating additional queues; it does not require
the completed states to be identical.

## Runtime follow-up and measurement plan

### First paired parser observation, 2026-10-30

The fresh guest's loaded driver PE timestamp/checksum/image size matched the
inspected Windows 10 file. Its per-process list was empty and WDF listed five
base queues. A [one-report paired observation](../evidence/runtime/vm-idle-parser-pair-20261030.json)
then stopped before parsing, at the equality comparison and at the parser return
in the same callback/thread. The 18-byte lower HID report was neutral; all 18
decoded comparison bytes matched the cache, and the parser returned **AL=0**.
The cached client packet was **3 before and after**. All one-shot breakpoints
were consumed and the guest resumed; no PID correction or service change ran.

This observes the unchanged predicate on actual input. No per-process queued
clients were present, so it does not measure a pending client's lifetime or
observe its completion. Breakpoint pauses exclude normal-rate/latency claims.
Fresh backing-file and service inventory was a separate step; the screening
inventory below subsequently confirmed the guest/build and backing hashes.
The actual device dead-zone/axis configuration remains uncollected.

### Stopped-service screening result

The [first uninterrupted screening pass](../evidence/runtime/vm-idle-xinput-stopped-20261030.json)
confirmed guest **19045.5796**, the exact driver/DLL backing hashes and
`GameInputSvc` **Stopped/Manual** in the before/after inventories. All **2227**
queries succeeded in **35.0019 seconds**, with no recorder error. The operator
reported "did exactly as instructed"; phase labels remain requested actions,
not independently measured physical start/release times.

- **First 20-second idle window:** 1272 identical public gamepad snapshots;
  packet number stayed **3**. Both sticks remained at X=128, Y=-129, with
  buttons and triggers zero. The small center offsets are actual returned
  values, not evidence of movement by themselves.
- **Five-second left-stick window:** 318 successful samples, 238 distinct
  observed public gamepad states. The right stick, buttons and triggers stayed
  unchanged. Packet values ranged from 3 to 403.
- **Ten-second requested idle-after window:** 637 samples, 28 distinct public
  states, packet values 403 through 503. Large left-stick excursions continue
  briefly after the phase cue; the cue does not prove the precise release time.

An exploratory, post hoc **26-to-35-second** subwindow excludes that first
requested idle-after second. Its 573 samples contain only two left-stick
pairs: **(128, -129)** in 548 samples and **(385, -900)** in 25. Thus small
left-stick variation is present late in this reported idle interval, while
the initial idle interval was stable. This is a candidate source of legitimate
decoded changes after use. It does not identify the electrical/firmware cause,
prove all intermediate changes were delivered, or measure queued completions.
Sampling was about 64 Hz with roughly 10 ms requested sleeps, so packet jumps
cannot be equated to the number of visible state transitions.

The stopped condition does not exercise the inbox worker. The operator
approved a temporary Running/Manual repeat with automatic restoration to the
Stopped/Manual baseline. `Invoke-VMIdleRunningCondition.ps1` pins this issued
recorder, verifies the original state, inventories loaded modules outside the
timed window, launches the interactive child and stops the service after
capture publication. Failure/timeout also reaches restoration; failed
restoration is recorded as a failure. Its 180-second polling deadline is not
a hard timeout for blocked native/service calls or forced parent termination.
Compare its service-lifetime QPC bounds with the capture's query QPC bounds
before accepting a running-condition result.

### Running-service screening result

The [running-condition evidence](../evidence/runtime/vm-idle-xinput-running-20261030.json)
contains **2213 successful queries in 35.0025 seconds**, with no recorder error.
The operator reported "did as instructed". The recorder/native-helper/driver/
XInput hashes match the stopped run. The running inventory observed the inbox
worker loading **GameInputInbox 0.2309.19041.5794** and WUDFHost loading
**DsHidMini 3.27.0.2500**, SHA-256
`84c22c152fccc8d0e17595e0f3a1125312b2c4d1a45cd814c74b635a505e077a`.

All query QPC values lie after the wrapper's verified Running/Manual state and
before its stop request; the last query ended **0.4054 seconds** before that
request. Restoration verified **Stopped/Manual**, with no restoration error.
These lifecycle bounds are not a continuous service-event trace.

- **Idle-before:** 1265 samples, including 1249 left-stick pairs at
  **(128, -129)** and 16 at **(385, -900)**; packet values 4615 through 4667.
- **Left-stick:** 318 samples and 160 distinct observed public gamepad states.
- **Idle-after:** 630 samples and 29 distinct public states, including brief
  large excursions around the requested phase transition. In the exploratory
  26-to-35-second subwindow, 566 samples contain **(128, -129)** 499 times,
  **(128, -900)** 66 times and **(385, -900)** once.

Buttons, triggers and the right stick stayed unchanged throughout. This is a
single serial pair with unequal device/controller exposure: the first stopped
idle preceded deliberate stick movement, while the later running idle followed
earlier movement and intervening time. **The pair does not establish that
starting the service causes the stick variation.** Small variation appears
after use in both conditions. Packet differences do not count queued client
completions or allocations.

### Matched idle change and retained queues

After the service had been restored to Stopped/Manual, a bounded list walk
found **587 per-process entries**, versus the earlier empty list at the same
observed device-context address. The 4096-entry cap was not reached. This
population spans service startup, recording, restoration and intervening
exposure; it is not a 35-second allocation rate. Individual WDF queues and
their waiting requests were not all inspected. The 120-second MCP client
timeout did not mean the walk stopped: later debugger history confirmed its
completion and count. No duplicate walk or UI interrupt was needed.

A [one-report changed-state observation](../evidence/runtime/vm-idle-changed-report-20261030.json)
then stopped only on the parser's changed branch at **RVA 0x4de6**. The
operator confirmed that the controller stayed completely untouched after the
recording. In the same callback/thread:

1. The old decoded left-Y word at device offset **0x92** was **0x8080**.
   The new word was **0x8383**; the other decoded comparison bytes matched.
2. The device's WDF input-memory handle resolved to an **18-byte mapped HID
   report** containing that same **0x8383** left-Y word.
3. At parser return **RVA 0x565b**, **AL=1** and the decoded cache contained
   the new value.
4. At callback finish **RVA 0x5cfc**, the cached client packet had advanced
   **6601 → 6602**, and its left-Y value changed **-129 → -900**.

Together with the earlier equal-report **AL=0** observation, this demonstrates
both sides of this driver's decoded-state gate on actual reports. **This
particular idle hit represents a changed mapped left-Y value**, with operator
confirmation of no physical interaction. It does not identify every historical
breakpoint hit or prove a DsHidMini defect. These are DsHidMini's mapped HID
bytes, not the physical DS3 wire report or ADC readings. No GameInput client
completion was matched during this post-restoration callback inspection.

The next useful diagnostic is to retain the actual device configuration and
compare the physical DS3 report with the mapped report. That can distinguish
source input variation from transformation/configuration behavior. The missing
PID assignment remains a separate verified driver defect; normal state changes
can feed its excess-queue creation.

All one-shot breakpoints were consumed and the guest resumed. Both temporary
VMware shares were removed, runtime sharing disabled and configured share count
returned to zero. Original captures and scripts remain private and intact.

### Uninterrupted public-state screening

`tools/runtime/Measure-VMIdleInput.ps1` adds a standalone screening pass: 20
seconds untouched, 5 seconds moving only the left stick, then 10 seconds
untouched. It reuses the hash-verified native helper and exact x86 XInput
backing-file identity, refuses another OS/driver/DLL, and saves bounded samples
before requesting the operator's actual-action report. It preserves services
and controller settings. Its nominal 10 ms sleep is observer pacing, not a
guaranteed sample frequency or mitigation.

This pass records public XInput slot 0 snapshots only. It cannot establish
raw HID equality, PS/battery behavior or queued IOCTL completion timing. Those
boundaries still require the matched observations below. No uninterrupted
capture result is claimed merely because the recorder is prepared.

Use the existing identified guest/controller stack and agree on a short idle
and deliberate-input run before recording. Keep the baseline configuration,
service state, report behavior and dead-zone settings unchanged. The operator
handles the physical input. Retain the actual left/right dead-zone enable and
polar values plus axis-flip settings; installed defaults do not establish the
active device configuration. Record at three boundaries:

1. **DsHidMini output:** mapped HID bytes, delivery status and timestamps;
   compare fields and count identical reports. Raw DS3 values are useful for
   identifying noise that survives the mapper.
2. **xinputhid parser:** old/new values of the exact 18 compared bytes and
   the parser's changed result. Record which bytes differ, rather than infer
   this from a public XInput state snapshot.
3. **Queued client IOCTL:** actual byte-3 flag, PID/device, submission and
   completion times, status, successful transfer size, packet number and all
   24 returned bytes. Read output only after successful completion.

Use bounded counters/buffers over an uninterrupted measurement interval.
Repeated interactive breakpoint pauses are unsuitable for establishing the
normal timing or rate. Separate lower HID-read counts from successful queued
IOCTL completions and preserve errors/pending cases as such.

If the decoded state varies, locate the changing field and its mapping first.
If successful queued completions repeat with equal decoded state, trace which
completion path bypasses the ordinary equality gate. Then assess whether a
targeted DsHidMini correction is warranted. Suppressing duplicate HID reports
alone might reduce parsing work, but the inspected xinputhid path already
suppresses queued delivery for identical decoded state. Any filtering change
must preserve small intentional input, triggers, PS, battery and reconnect
behavior, and would not repair the missing PID assignment.

The original static review performed no live capture or target changes. The
subsequent observations and service repeat are dated above. Only the explicitly
approved temporary service start/stop was applied; no controller filtering,
driver installation, throttle or PID correction was used.
