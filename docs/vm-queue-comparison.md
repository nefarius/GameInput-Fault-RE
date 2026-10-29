# VM queue growth and handle-close comparison

This follows the [one-node reuse observation](../evidence/runtime/vm-queue-corrected-reuse-20261029.json).
The same GameInput process selected the corrected node and reused its WDF queue.
That establishes a mechanism correction, not a performance result. The current
device lifetime already has **at least 512 nodes**: a direct bounded list walk
on 2026-10-29 visited 512 entries without returning to its head. This is a lower
bound, not a full queue count, growth rate or clean corrected baseline.

The first preparation disconnect did **not** destroy the former device:
[live inspection](../evidence/runtime/vm-disconnect-pending-closes-20261029.json)
found `DeviceNodeDeletePendingCloses`, WDF power stopped and one WDF file object
whose object header reported two handles. That file object was absent from the
inspected GameInput worker's file-handle list; its owner remains unknown. No
handles were forcibly closed. If reconnect creates another device, verify its
separate context and empty initial queue list before calling it a fresh queue
lifetime. Retired-device residency remains a possible performance confound;
this does not establish successful teardown or a leak.

Reconnect subsequently produced a distinct context whose list was empty at the
first GameInput allocation. The uncorrected node was published with stale PID
**0x4c7bc810**, unlike requestor **0x684**. After a short resumed interval, a
bounded walk returned to the head after **332 nodes**, so this is an exact count
at that pause, not a lower bound. The first node remained linked and unchanged.
See [fresh-device growth evidence](../evidence/runtime/vm-queue-uncorrected-growth-20261029.json).
Hands-off input was requested but not independently confirmed. The requested
ten-second sleep and host MCP timing markers do not establish the exact guest
running interval; no allocation rate is claimed. No close-latency benchmark
had run at this observation.

The [uncorrected handle-close baseline](../evidence/runtime/vm-handle-close-uncorrected-20261029.json)
subsequently completed 100 successful pairs in **1.584 seconds**, ending at its
sample cap rather than the five-second time cap. Close latency across all 100
samples was **411.45 microseconds median**, **733.2 microseconds p95** and
**1311.8 microseconds maximum** (p95 uses nearest rank). The backing driver and
script hashes match. A complete earlier pre-benchmark count found **1994 nodes**;
the post-transfer bounded snapshot found **at least 4096**. These are not exact
queue counts during the timed calls, and growth includes guest activity and
operator transfer time. At this stage, no corrected close-time result was available.

A subsequent [fresh corrected lifetime](../evidence/runtime/vm-queue-corrected-growth-20261029.json)
began with an empty list. Its first GameInput entry's PID was initialized from
stale **0x68547844** to **0x684** before publication. A subsequent request from
the same process selected that exact entry for reuse. After another short run
with the same requested ten-second sleep, a complete count still found **one
node**, with the corrected PID and original queue handle intact. In contrast,
the uncorrected short run ended at **332 nodes**. The host timing markers differ
and are not exact guest execution durations; no percentage or per-second rate
is derived. This supports the initialization defect as the cause of excess
queue creation in this configuration. Corrected close timings were collected
next; game impact remains pending.

## Paired handle-close result

The [validated pair](../evidence/runtime/vm-handle-close-pair-20261029.json)
contains 100 successful open/close pairs per condition, with matching interface
path, driver/script hashes, x64 architecture, OS version and requested limits.
Both post-run service inventories show GameInputSvc Running/Manual, PID 5708.
The corrected run took **1.593 seconds** and still had exactly **one queue node**
at its post-transfer snapshot; its PID and queue handle remained unchanged.

Across all samples, median close duration fell from **411.45 to 11.7 microseconds**,
or **35.17 times lower (97.16% reduction)** in this pair. Nearest-rank p95 fell
from **733.2 to 38.3 microseconds**; mean fell from **486.067 to 14.537 microseconds**.
The corrected maximum was 166.8 microseconds versus 1311.8 uncorrected. Open
duration did not show the same improvement: median rose from 23.85 to 26.8
microseconds and p95 from 41.5 to 85.9. This is a specific close-cost result,
not a universal speedup.

Together with missing-initialization, reuse and queue-growth observations, this
supports excess queues as a contributor to handle-close cost on this device.
It is one serial pair with unequal exposure times, background activity and
incomplete retired-device teardown. Queue populations during individual calls
were not measured. It does not establish game FPS benefit, the contributor's
full x86 XInput path, controller fidelity or a supported fix. Next useful work
is repeated/reversed-order pairs with controlled exposure and device lifetime,
then a game or matching x86 enumeration workload with frame-time evidence.

Use the existing offline Windows 10 19045.5796 VM, inspected xinputhid
10.0.19041.5794 and USB PS3/DsHidMini XInput controller. Preserve service and
power configuration. The operator handles USB connection and input. Do not
resume old pointers after reconnect; rediscover the device context each time.

## Measurement workload

`tools/runtime/Measure-XInputHandleClose.ps1` enumerates present interfaces of
class `ec87f1e3-c13b-4100-b5f7-8b84d54260cb`, referenced at RVA 0x146c in the
inspected x86 XInput binary. It opens one explicitly selected interface with
metadata-only access, read/write sharing and OPEN_EXISTING, then closes it.
It sends no input, output, vibration or device-control requests and changes no
services. It verifies the installed driver hash; the debugger must separately
verify the loaded module and actual target device stack.

This isolates one possible cleanup cost. It does not reproduce XInput's
read/write access or its enumeration IOCTL sequence, so a negative result does
not rule out the game's path. The script runs in the architecture of its
PowerShell process; use the same executable and architecture for both runs.
Metadata-only access could also follow a different driver path.

The default offers at most 100 open/close pairs over at most five seconds,
with 10 ms between pairs. Bounds are checked between calls; a blocked kernel
call has no hard timeout. Raw QPC ticks, frequency, errors, actual sample count,
duration, selected path, script/driver hashes and post-run service inventory
are retained. Failed operations stop the run and remain failures, not zero-cost
samples. Keep JSON private: interface paths can identify a device.

In the guest, list interfaces first and select the PS3 XInput interface:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\Measure-XInputHandleClose.ps1 -ListDevices
```

Use the verified index below; `0` is an example, not an assumed match:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\Measure-XInputHandleClose.ps1 -DeviceIndex 0 -Condition uncorrected -OutputPath C:\GameInputResearch\captures\uncorrected-close.json
```

Do not take timed samples while a breakpoint interrupts these operations.
No game FPS, pending-I/O lifetime or input fidelity can be inferred from these
API durations. Capture frame times separately in a later controlled game run.

## Paired run sequence

1. Transfer the script before beginning. Confirm NIC remains disconnected and
   retain the existing snapshot. Keep the controller disconnected from the VM
   while the kernel runs so its former device lifetime can finish teardown.
2. Break the guest, inspect whether the old xinputhid device is absent, set a one-shot
   allocation breakpoint, resume and let the operator reconnect USB. Record
   the new context and requestor. If the old device remains pending deletion,
   retain that result and verify a separate new context and its empty initial
   list; do not silently call the former lifetime destroyed. At the first new queue allocation, record
   the uninitialized PID without correcting it for the uncorrected condition.
3. Remove experiment breakpoints. Run the same bounded input workload in both
   conditions (initial target: ten seconds of operator stick movement). Record
   the actual movement and timing; requested movement is not observed input.
   Count list nodes immediately before and after, bounded with an explicit
   censored/lower-bound result if the list exceeds the scan limit. Debugger
   pauses and setup time are not a measured allocation-rate window.
4. Resume without breakpoints and run the guest microbenchmark. Break afterward
   and count nodes again to check whether the benchmark itself changed the
   queue population. Preserve the JSON and failed runs.
5. Disconnect and complete teardown again. Repeat the same procedure with a
   fresh device context, this time initializing a fresh GameInput node's PID
   before publication, verifying publication and a subsequent reuse. Do not
   patch driver code or delete existing queues. The one-node correction only
   covers the verified requestor; other processes can still allocate nodes.
6. Repeat identical workload, queue counts and benchmark under condition
   `corrected`, saving to a new filename. Compare successful close-time
   distributions and counts, with service/process/device/architecture identities
   and actual durations. Multiple short pairs are preferable before causal
   claims; reconnect/order, input differences and observer overhead can confound
   one pair.

If queue counts cannot be established, device routing differs, calls fail, or
timed calls are interrupted by debugger pauses, report the comparison as
incomplete. Input delivery, vibration, reconnect/recovery and game frame times
remain separate acceptance work. Do not publish this as a supported fix.
