# Independent validation of the XInput user-mode loops

## Corrections established by this pass

The inbox worker **does wait for I/O completion**. `XusbWatcher::WorkerThread` at `0x180042e98` calls `NtWaitForSingleObject(event, TRUE, NULL)` after each accepted submission, including one that returned `ERROR_IO_PENDING`. Its request helper writes input byte 3 as the inverse of a caller-supplied Boolean. The worker passes **true**, producing **zero**, which selects the queued path in the inspected xinputhid driver. The statement that an unchanged successful transfer has no additional sleep is accurate but incomplete without this completion wait; it is not proof of a tight spin.

The inbox worker compares **19 bytes at output offset 5**, not the packet number. The redist worker separately compares the **32-bit packet word at output offset 0**. Neither comparison demonstrates a request rate or CPU fault.

The redist OS gate and its 1 ms post-success wait are independently confirmed below. The inbox uses fixed mode choices for normal reads and its support probe; it does not use that redist OS gate in these inspected paths.

No live I/O, process injection, driver execution, event signaling, or focus manipulation was performed. This document leaves the main findings document unchanged.

## Image identities and evidence

- Inbox `C:\Windows\System32\GameInput.dll`, version `0.2309.26100.9278`, SHA-256 `f9f5adbde4a2883b9b307bb1848a120094904578d92b21100828bd83f7b77cb6`.
- Inbox PDB GUID `b2f221be-f567-c87a-7830-89f3fe8b3c51`, age 1, independently matched against `symbols/GameInput.pdb`; PDB SHA-256 `1452c6e5285e11874ee68e8bda74674e3cecd0d07862247d4bd183bc56c89651`. Ghidra reports PDB loaded.
- Redist `C:\Windows\System32\GameInputRedist.dll`, version `3.5.270.0`, SHA-256 `6d3650dbeea5f8c639972537dbaed3f2bb465561e63d34fa9661902f24cb9686`. This matches the earlier Program Files image identity; the current process module mapping was not re-measured here. No PDB was applied to redist. Names inferred from embedded source/log strings are distinguished from Ghidra's `FUN_...` labels.
- Ghidra 12.1.3 headless CLI, Temurin 25.0.4.1+1; preferred base `0x180000000` for both DLLs. Addresses here are preferred VAs, not current process addresses.

[Inbox literal pseudocode and 135 verified instructions](../evidence/static/gameinput-inbox-0.2309.26100.9278-excerpts.txt) and [provenance](../evidence/static/gameinput-inbox-0.2309.26100.9278.json) preserve the complete narrow functions and selected source-byte-checked assembly. [Redist excerpts and 134 verified instructions](../evidence/static/gameinput-redist-3.5.270.0-validation-excerpts.txt) and [provenance](../evidence/static/gameinput-redist-3.5.270.0-validation.json) cover its loop, wait/retry wrappers and version check. Full exports/projects remain ignored under `artifacts/`.

The inbox analysis emitted a data-type creation warning at unrelated data address `0x180054630`; the selected functions decompiled successfully. Decompiled stack types and some argument counts remain approximate. Selected instruction bytes are independently checked against the original PE. Import-table API names do not establish actual runtime API-set resolution, loaded implementation or hooking state.

## Inbox request flag and completion wait

`XusbWatcher::RequestUnfilteredState` (`0x1800405e4`) builds this four-byte input:

```c
// Observed positions, not an official SDK declaration.
word0 = 0x0103;
byte2 = (uint8_t)deviceIndex;
byte3 = !callerMode;
```

The assembly tests `R9B` at `0x1800405f4` and uses `SETZ` at `0x180040604` to write byte 3. The worker sets `R9B = 1` at `0x180042f22`; its call at `0x180042f43` therefore sends byte 3 **zero**. There is no OS-version branch between these assignments and submission.

The helper zeroes the output and OVERLAPPED fields, installs the supplied event and resets it at `0x180040634`. At `0x1800406f6` it submits the full constant `0x8000e388`, input length 4, output length 24, and a nonnull OVERLAPPED. It returns true for either synchronous success or false with last error `0x3e5` (`ERROR_IO_PENDING`, checked at `0x180040712`); it does not itself wait for completion.

After a true result, the **worker** supplies `RCX = event`, `DL = 1` (alertable), `R8 = 0` (null timeout pointer), and calls **`NtWaitForSingleObject`** at `0x180042f55`. A null timeout gives an unbounded completion wait, rather than a zero-duration poll. The event may already be signaled after synchronous completion; in that case the same wait may return immediately. There is no alternate branch skipping this wait for synchronous success.

After wait status zero and a clear stop flag, it requires OVERLAPPED `Internal` low status to be zero at `0x180042f75` and `InternalHigh == 0x18` at `0x180042f7f`. On nonzero wait status it calls `CancelIoEx(handle, NULL)` at `0x180042ffc`, tolerates last error `0x490` (`ERROR_NOT_FOUND`), then performs a nonalertable null-timeout wait at `0x18004302c` to synchronize cancellation/completion. Other failure paths can fail fast.

The 100 ms `NtDelayExecution` at `0x180042efd` is selected on device-index lookup failure, helper failure, or unsuccessful/incorrect-length completion. The interval is signed `-1,000,000` in 100 ns units. An ordinary valid unchanged result loops back without this **additional** delay, after the completion wait described above.

Together with [the kernel result](kernel-xinputhid.md), these calls describe an intended change-notification loop for the inspected HID path. They establish neither that every device handle reaches that path nor that a pending request always surfaces as `ERROR_IO_PENDING` before a concurrent completion.

## Inbox support probe is a separate mode

`XusbWatcher::IsUnfilteredStateIOCTLSupported` (`0x18003cea4`) calls the same helper with device index 0 and caller mode **false** at `0x18003cef9`. That produces input bytes `03 01 00 01`, selecting cached snapshot mode in the inspected driver. The routine waits nonalertably with relative interval `-10,000,000` (one second) at `0x18003cf15`, and requires status success and length 24. It cancels/synchronizes on unsuccessful wait paths.

Thus a snapshot-mode request can originate from the inbox support probe even though the steady-state worker requests queued mode. Do not label every nonzero-byte request an OS quirk or a sustained poll without its caller/lifecycle context.

## Packet and state offsets

The 24-byte return buffer passed by the inbox worker begins at stack `[RBP+0x27]`. It copies 16 bytes starting at `[RBP+0x2c]`, two bytes at `[RBP+0x3c]`, and one byte at `[RBP+0x3e]` into a 19-byte comparison value: output offsets **5 through 23**. It conditionally clears the last copied byte when watcher field `+0x3c` is nonzero. `memcmp(..., watcher+0x29, 0x13)` is at `0x180042fb7`; equality branches to the next iteration at `0x180042fbe`. It publishes only a changed comparison value, then updates that cache.

The first four output bytes are the packet counter in the kernel's observed layout, and the redist directly compares that word. In redist, the buffer passed at `0x180051b21` begins at `[RBP+0x1f]`; the packet comparison is against that same dword at `0x180051b50`. A diagnostic packet counter should therefore use **offset 0, four bytes**, while an inbox-equivalent state comparison is a different operation starting at offset 5. Both require a successful valid 24-byte completion.

## Redist loop, OS check and retry behavior

The loop at `FUN_1800519ec` embeds the `GameInput::Backend::XInput::Device::ThreadProcSystem` log/source name. It constructs header `0x0103`, device byte 2, and initially zero byte 3. It calls `FUN_1800557a0` at `0x180051a57`; a true result writes byte 3 to **1** at `0x180051ae9`. The log string names the unfiltered-state IOCTL quirk.

`FUN_1800557a0` calls `FUN_180064fa8` and XORs its Boolean result with 1 at `0x1800557a9`. The inner helper passes a structure of size `0x11c` through `FUN_180069e38`, whose embedded import lookup explicitly names `ntdll.dll` / `RtlGetVersion`. After a successful query it returns true when major >10, or major ==10 and build >=**22000**. The assembly compares the build with **`0x55f0` (22000)** at `0x180064ff4`; the decompiler's equivalent `21999 < build` must not be mistaken for a different threshold.

Therefore byte 3 is zero for those newer versions and one for the other version results. Query failure returns false from the inner helper and so **also sets the quirk byte**. Minor version and revision are not used in this test. It is a redist check, not an inbox condition; it also does not establish any Windows 10 driver's implementation.

The caller passes timeout `0xffffffff`, retry count 3 and retry delay 100 ms. `FUN_1800602ac` calls `FUN_180060468`, which resets the completion event and issues overlapped `DeviceIoControl`. On `ERROR_IO_PENDING` it waits either for the completion event or for cancellation plus completion with `WaitForMultipleObjects(2, ..., FALSE, timeout)`. It returns `E_ABORT` when cancellation wins, and checks status and returned size on completion. The wait's configured timeout is **infinite**, so the pending path does not force a 1 ms completion cadence.

On success, the outer retry wrapper returns without the retry delay. On ordinary failure it increments a retry counter and waits/sleeps 100 ms while the counter is <=3: **one initial attempt plus at most three retries**. Cancellation exits separately. The worker compares packet word 0, processes changed packets, and then calls `WaitForSingleObject(stopEvent, 1)` at `0x180051bbe`; it repeats only on `WAIT_TIMEOUT`. That post-success wait is outside the OS-quirk branch.

This confirms a 1 ms requested post-success wait, not a measured 1000 Hz request rate. Pending completion latency, scheduling and timer behavior are additional constraints. The current code does not prove a poll-to-rumble link.

## Runtime handoff and remaining uncertainty

The early inbox claim missed a material wait and conflated repeated submission with repeated immediate completion. The redist OS-flag description is confirmed with the failure fallback added above. Actual request mode/callsite, completion classification and device stack are still required to demonstrate a pathological interval.

The kernel follow-up also found that arbitrary process creation/exit does **not** unconditionally invoke the zero-vibration broadcaster; see [the exact process callback predicates](kernel-xinputhid.md#process-notification-is-not-an-unconditional-rumble-trigger). A persistent native capture reduces process/focus observer effects, but neither process churn nor the state loop is established here as the root cause.

Capture exact input bytes, callsite/lifecycle, valid returned packet/state, pending latency and PID/handle mapping. Correlate those with explicit set-state calls, focus/exit events, lower HID writes and CPU stacks. Distinguish the one-time snapshot support probe from the queued worker and from redist snapshot mode on older version results.
