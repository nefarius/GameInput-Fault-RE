# xinputhid kernel investigation

The later [Windows 10 investigation](windows10-queue-identity.md) inspects the
exact contributor-hash 10.0.19041.5794 driver and finds a missing PID store in
per-process queue creation. The Windows 11 handler below contains that store.
This static defect has not yet been tied to measured live queue growth or
validated with a hardware PoC.

## Result and contrary evidence

For **xinputhid.sys 10.0.26100.9278**, `0x8000e388` has two different successful paths. Input byte 3 **nonzero** returns a cached 24-byte state and completes in the handler. Byte 3 **zero** forwards the request to a per-requestor-PID manual WDF queue and returns without completing it. On the inspected HID gamepad path, queued delivery is gated on a change in **decoded state**, not every HID report.

This contradicts an unconditional inference that a Windows 11 caller with the flag clear must spin on immediately completed unchanged state. It also does **not** establish that state polling causes repeated rumble-off writes. The unfiltered-state handler contains no direct vibration call. A distinct focus-change path explicitly requests zero vibration, and a separate set-state IOCTL reaches the vibration helpers.

These are static results for one driver build. No controller IOCTL was issued, no live kernel state or feature configuration was read, and no ETW capture was made in this investigation. The user's Xbox One USB connection does not by itself establish that its active device stack uses this driver or reaches this HID path.

## Identity and evidence

- Original: `C:\Windows\System32\drivers\xinputhid.sys`, 10.0.26100.9278.
- SHA-256: `1e85d1a191f09ed62645658c94f908b733da5a026ed2b6b662635ebbddf84588`.
- Public PDB: `symbols/XINPUTHID.pdb`; SHA-256 `050b38f56fdb1e11b33cbcf4817c3f470fc2402a45401cb7d79e3e5eb8f3d348`.
- PE and PDB independently read GUID `f482d0de-64e0-3d63-a8b2-d58e868db1e5`, age 1, matched. Ghidra reports `PDB Loaded: true`.
- Ghidra 12.1.3 headless CLI, x86 little-endian 64-bit / Windows compiler specification; Temurin 25.0.4.1+1. Static image base `0x140000000`; addresses below are preferred VAs, **not live addresses**. RVA is VA minus image base.
- [Literal pseudocode and instruction excerpts](../evidence/static/xinputhid-10.0.26100.9278-excerpts.txt) preserve function names, incoming references, direct callees, WDF offsets, and 209 instruction byte comparisons against the original PE, with RVA and file offsets.
- [Machine-readable provenance](../evidence/static/xinputhid-10.0.26100.9278.json) records source, PDB, WDF-header, selected raw-export and excerpt hashes.

Full local exports, logs and the reusable Ghidra project are ignored under `artifacts/`. These are ordinary local Ghidra observations, not REA MCP Evidence records. The MCP Java/provider failure was bypassed through the authorized CLI fallback without changing MCP configuration.

## Exact IOCTL and routing

The full constant is **`0x8000e388`**, independently present in comparisons at:

- `EvtIoInCallerContext` (`0x1400087e0`), compare `0x1400089a3`: checks system-management access for this code before ordinary enqueueing. Its direct `DispatchXINPUTIoctl` call also handles other codes; do not assume that call is the route for this code.
- `OnIoDeviceControl` (`0x14001a230`), compare `0x14001a5bc`: accepted XInput/HID branch reaches `DispatchXINPUTIoctl` at `0x14001a6bf`.
- `DispatchXINPUTIoctl` (`0x14000eeec`), compare `0x14000f140`, equal branch `0x14000f146 -> 0x14000f172`, call `0x14000f178 -> DispatchGetUnfilteredGamepadState` (`0x14000d1d8`). This is the definitive code-to-handler mapping.

The code decomposes arithmetically as `CTL_CODE(0x8000, 0x8e2, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)`. This is a decoded numerical definition, not a recovered Microsoft header declaration. `IOCTL_XINPUT_GET_UNFILTERED_GAMEPAD_STATE` is the descriptive name used by the existing GameInput investigation; the public function name confirms the unfiltered-state operation.

`OnIoDeviceControl` also has a lower-target forwarding branch when the preparsed HID context/usage does not select the inspected gamepad path. Device removal and controller-assist/access gates can reject requests. The result here therefore does not describe every controller stack accepting an identically numbered IOCTL.

## Input byte semantics and immediate completion

`DispatchGetUnfilteredGamepadState` requests a **minimum** 4-byte input at `0x14000d236` and a **minimum** 24-byte output at `0x14000d26e`. The handler checks input word 0 equals `0x0103` at `0x14000d282`; mismatch completes with `0xc000000d`. It does not enforce equality of total input/output lengths to those minima.

Observed input layout, without asserting private structure/field names:

```c
// Observed byte positions; not an SDK structure declaration.
uint16_t word0;       // must be 0x0103 (little-endian bytes 03 01)
uint8_t  byte2;       // not read by this handler
uint8_t  byte3;       // 0: queued mode; ANY nonzero value: cached snapshot mode
```

The instruction at `0x14000d2cb` compares byte `[input+3]` with zero. `0x14000d2dd` jumps to `0x14000d37c` when zero. The nonzero fallthrough acquires the device spin lock, copies 24 bytes from device context offset `0x101` at `0x14000d2f7–0x14000d309`, optionally adjusts a button bit under feature/restriction conditions, releases the lock, and sets transfer information to `0x18` at `0x14000d372`. It then reaches `WdfRequestCompleteWithPriorityBoost(request, STATUS_SUCCESS, 6)` at `0x14000d2aa`.

There is no prior-packet comparison, queue insertion, or wait for change on this snapshot branch. Repeated nonzero-byte submissions can therefore repeatedly return cached unchanged state. This establishes a possibility of rapid resubmission, not its occurrence, rate or CPU cost.

The existing user-mode analysis labels byte 3 as a Windows 10 quirk set on builds below 22000. **For this driver**, setting that byte selects immediate completion; clearing it selects queueing. This investigation does not independently re-establish the callers' OS checks or the actual input bytes submitted at runtime. It also does not establish how any Windows 10 xinputhid build implements the byte. Do not project this Windows 11 driver result onto an uninspected Windows 10 driver.

## Queued completion and unchanged HID reports

On the zero-byte branch, the handler obtains the underlying IRP and requestor PID at `0x14000d386–0x14000d38e`, acquires the device spin lock, and walks the list at device context offset `0x80`. List entries contain the PID at `+0x10` and queue handle at `+0x18`.

For an existing PID, `0x14000d3f8` calls WDF slot `+0x8c8` (`WdfRequestForwardToIoQueue`). For a new PID, the handler allocates a 32-byte list entry and creates a manual queue through slot `+0x4c0` at `0x14000d519`; the queue configuration has dispatch type 3. It links the entry and forwards at `0x14000d5d7`. After successful forwarding, it releases the lock at `0x14000d601` and jumps directly to the return epilogue at `0x14000d606`, bypassing the completion call. Allocation/queue/forward failures take a completion path, generally with `0xc0000120`.

Delivery is in `HIDRequestCompletionRoutine` (`0x140009110`):

1. After successful read/battery processing, it calls `ParseAndLoadInputReportExt` (`0x140004cd0`) at `0x140009235`.
2. The parser builds decoded state and compares two 8-byte fields plus one 4-byte field against cached decoded state at device offsets `0x90`, `0x98`, `0xa0`. Comparisons are at `0x14000553d`, `0x14000554a`, `0x140005553`. Equality jumps at `0x14000555a` to the return path; `BL` began as zero at `0x140004d04`. Changed-state processing writes the cache and selects true before return.
3. The read callback tests `AL` at `0x14000923a`; false jumps at `0x14000923c` to `0x140009a61`, bypassing packet updates and client delivery. Thus an identical **decoded** report does not release these queued state requests on this path. This is not a raw-HID-byte comparison; decoded auxiliary flags and noise can also count as changes.
4. Accepted changes increment the packet word at device offset `0x101` (`0x140009348`) and rebuild the returned state. Depending on controller-assist feature/state, the callback either walks the per-PID queues inline (`0x1400097d5` onward), or calls `DistributeReportDataToUnfilteredClients` (`0x1400021d8`) at `0x140009c3d` when the exclusive-assist PID field at `+0x1ac` is zero. Feature state and access restrictions can suppress delivery; this is not a promise that every change completes every request.
5. Both implementations attempt **one** `WdfIoQueueRetrieveNextRequest` per PID entry, copy the current 24-byte state and complete with information 24. The helper's completion call is `0x1400022d7`, slot `+0x848`. They do not drain an arbitrary number of requests from a PID queue in one pass.

The handler is void and transfers ownership to WDF; it does not literally return `STATUS_PENDING`. A request queued here may be completed by a concurrent state change before `DeviceIoControl` returns. Conversely errors can complete immediately. A synchronous/pending counter alone must be interpreted alongside success, exact input byte, request timing, device path and packet contents.

## Rumble: actual paths and limits

`DispatchXINPUTIoctl` routes **`0x8000a010`** to `DispatchSetGamepadState` (`0x14000e354`) or `DispatchSetGamepadStateEx` (`0x14000e630`) according to the XInputExplorer feature. The legacy handler checks bit `0x02` of its **own** input byte 4 before the vibration branch. This set-state flag is distinct from unfiltered-read byte 3. Calls into vibration helpers occur at `0x14000e57e`/`0x14000e5ed` and `0x14000e95a`/`0x14000e961`.

`BroadcastDevicesFocusChanged` (`0x14000fcb0`) provides a concrete **zero-vibration** source. Instructions `0x1400100c2–0x1400100cf` clear the amplitude arguments; depending on device byte `+0x178`, it calls `SendVibrationMessageThrottled` (`0x140006010`) at `0x1400100db` or `_SendVibrationMessage` (`0x140006ac4`) at `0x1400100e2`. The broadcaster is called by process-notification and focus/exclusive-focus callbacks, not directly by the unfiltered-read handler. Its per-device processed marker also matters when interpreting its internal restart of device enumeration.

`_SendVibrationMessage` builds a HID output report and calls `HID_PerformOp(context, 0, outputMemory)` at `0x140006e53`. In `HID_PerformOp` (`0x140003504`), operation zero selects WDF slot `+0x5c8` (format write), whereas nonzero operations select `+0x5d8` (format IOCTL). Both then send the request. This distinguishes a lower HID write from the read IOCTL itself.

The throttled helper replaces a pending output-memory slot at device `+0x180`. `XihOutputThrottleIssueAndReschedule` (`0x140006740`) takes and clears that slot, writes only when it has a buffer, and reschedules only when a newly pending buffer remains; it contains a 10 ms interval calculation. That code does not prove actual timer resolution, sustained write rate, or a self-generating rumble-off loop. The async-set-state low-memory feature changes buffer reuse, including all-zero reports; its live state was not measured.

No direct vibration-helper call appears in `DispatchGetUnfilteredGamepadState`, `ParseAndLoadInputReportExt`, or `HIDRequestCompletionRoutine`. The latter can resubmit HID reads through `CheckInputState`; that alone does not turn them into vibration writes. The inspected static paths do not establish that `0x8000e388` generates a rumble-off write per request. Repeated focus notifications, explicit set-state callers, a different driver version/path, or other runtime mechanisms remain possible explanations requiring evidence.

## Process notification is not an unconditional rumble trigger

A further narrow export of `_CreateProcessNotifyRoutine` (`0x1400104c0`) resolves the process-churn hypothesis for this build. `DriverEntry` registers this address with `PsSetCreateProcessNotifyRoutine(callback, FALSE)` at `0x14001c501`. The callback's second argument is the process PID; its third Boolean selects creation versus exit. Parent PID is not used for the focus decision.

Creation can emit a trace message, but the test at `0x14001052a` / branch `0x14001052c` skips the focus/cleanup body when `Create != 0`. The focus-broadcast path is **exit-only** and additionally requires a valid driver context and nonzero exiting PID.

The focus section is entered only when the exiting PID matches driver field `+0x24` or `+0x18` (`0x14001057c`, `0x140010581`). Matching only `+0x24` clears that tracked field but does not set the Boolean that controls broadcast. If PID matches `+0x18`, the code clears that field, optionally clears policy bit `0x02` under `XInputHidExclusiveProcTermFix`, and checks whether the former `+0x18` PID also equals current focus field `+0x20` at `0x1400105f6`. Only then does it call `SwitchFocusProcess(saved/restoration PID at +0x1c)` at `0x1400105fe`.

`SwitchFocusProcess` returns false if the requested PID equals the current focus PID; otherwise it changes focus subject to its policy checks. The caller tests its returned Boolean at `0x140010624`; false skips the call. **Only true reaches `BroadcastDevicesFocusChanged` at `0x140010629`**, which can send zero vibration using the previously documented `0x1400100db` / `0x1400100e2` sites. Offsets are observed; the role of `+0x18` as the exclusive-focus PID is supported by the feature/function context, not recovered structure field names.

There is separate feature-gated exit cleanup in `RemoveProcessQuirks` (`0x140005c28`). It removes PID-specific records and can invoke an indirect controller-assist callback at device `+0x1d8` when the exiting PID matches that device's assist PID at `+0x1ac`. The indirect callback's lower behavior is not established here. This additional callback is also PID-gated; it does not establish a zero-vibration write on every arbitrary process exit.

Thus spawning a diagnostic helper every 250 ms is **not sufficient by itself** to trigger this callback's focus-zero path. A helper acquiring a relevant tracked/exclusive/focus role, separate WNF focus notifications, or another runtime mechanism would need independent evidence. Persistent native capture is a useful way to reduce observer effects, but this static finding establishes neither a rumble flood nor process churn as its cause. The original rumble-off idea was an assumption from one issue ETL, not observed traffic.

[Literal process-callback evidence](../evidence/static/xinputhid-10.0.26100.9278-process-notify-excerpts.txt) and [provenance](../evidence/static/xinputhid-10.0.26100.9278-process-notify.json) retain the predicates, registration, focus update and zero-vibration call sites, with 95 additional source-byte-verified instructions. The earlier 209-instruction evidence bundle remains unchanged.

## Type and WDF uncertainty

The PDB supplies function names but does not recover useful layouts for `_DEVICE_CONTEXT`/`_DRIVER_CONTEXT`. Ghidra prints these as byte-addressed opaque types and produces some incomplete or misleading indirect-call prototypes. In particular it invents an uncertain sixth argument for `_SendVibrationMessage`; the four amplitude arguments are supported by assembly, but the printed sixth argument is not used as semantic evidence.

WDF functions remain indirect through `WdfFunctions_01015` at `0x1400174b8`. Names here are mapped by **offset / 8** against the installed KMDF **1.15** `wdffuncenum.h`, whose hash is retained in provenance. Relevant mappings: `+0x868` input buffer, `+0x870` output buffer, `+0x898` set information, `+0x840` complete with priority boost, `+0x848` complete with information, `+0x8c8` forward to queue, `+0x4f0` retrieve next queued request, `+0x9e0/+0x9e8` acquire/release spin lock. These names are external header interpretation, not symbols resolved on those indirect calls by Ghidra. Assembly and slot offsets are retained so that interpretation is reviewable.

## Proven versus unresolved

**Proven statically in this exact image:** full dispatch constant and handler; minimum buffer sizes and version word; nonzero byte 3 cached completion; zero byte 3 per-PID queueing; decoded-state equality suppresses ordinary queued delivery; one request retrieved per PID per accepted change; explicit zero-vibration focus path; separate vibration-producing set-state path.

**Unresolved:** actual per-process request bytes/rates and synchronous versus pending distribution; which stack the attached Xbox One USB device uses; live feature states; Windows 10 driver behavior; whether inbox/redist pollers hit a pathological path on this machine; runtime origin and cadence of rumble-off writes; CPU/stutter causation and mitigation effectiveness.

The runtime handoff should retain the exact read input bytes (especially byte 3), IOCTL, successful transfer length, PID/handle/device stack and immediate/pending classification. Correlate these with lower output writes, set-state requests, focus events, packet changes and CPU stacks during idle/input/rumble phases. Neither an immediate-completion possibility nor a separate static rumble-off path closes that causal gap.
