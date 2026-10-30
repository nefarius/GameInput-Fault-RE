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

## Next bounded measurement

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

No new live capture, service change, filtering change, driver installation,
throttle experiment or memory correction was performed for this review.
