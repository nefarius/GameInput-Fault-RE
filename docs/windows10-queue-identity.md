# Windows 10 per-process queue identity defect

The [2026-10-29 contributor binary package](windows10-binary-acquisition.md#contributor-files-received-2026-10-29)
is byte-identical to all three Windows 10 analysis copies, including x86 XInput.
This resolves the earlier whole-file identity gap; capture-time caveats below
record what was available during the original investigation.

The exact contributor-hash **xinputhid.sys 10.0.19041.5794** contains a concrete
initialization defect: its queued unfiltered-state handler searches a list by
requestor PID, but does not initialize that field when adding a new queue entry.
The inspected **10.0.26100.9278** Windows 11 handler does initialize it.

A [2026-10-30 REA version comparison](xinputhid-pid-version-history.md) dates
the earliest verified correct queued implementation to **10.0.22621.3085**,
**KB5034204 / Windows 11 22H2 build 22621.3085 and 23H2 build 22631.3085**,
January 23, 2024. The preceding inspected 22621.2506 driver lacks that IOCTL
handler; this is not a verified Windows 11 broken-to-fixed transition. The
Windows 10 19041.3996 implementation already omits the store, and no corrected
Windows 10 shipping revision has been established.

The defect has also been observed at live queue publication in the research VM:
a `GameInputSvc.exe` child requestor PID **1668 (0x684)** reaches the handler,
which creates a WDF queue and links its node while leaving the PID field **zero**.
See [allocation observation](../evidence/runtime/vm-queue-allocation-20261028.json)
and [publication observation](../evidence/runtime/vm-queue-publication-20261028.json).
The VM inbox is 0.2309.19041.5794, unlike the contributor's later inbox revision.

A [second allocation breakpoint](../evidence/runtime/vm-queue-repeat-allocation-20261028.json)
then observed the same worker and device allocating a different node while its
first node remained linked with PID zero and an unchanged queue handle. This
demonstrates failure to reuse that worker's earlier node. The second observation
stops before its new queue is created. A later
[one-node corrective experiment](../evidence/runtime/vm-queue-corrected-publication-20261029.json)
initialized that fresh node's PID to 0x684 and observed it survive queue creation
and list publication. Sleep and controller reconnection interrupted the session
before any queue-reuse result was supplied. The correction's effect on reuse and
performance remained unmeasured at that interruption; old pointers must not be
reused after reconnection.

After rediscovering the reconnected device, a
[direct MCP experiment](../evidence/runtime/vm-queue-corrected-reuse-20261029.json)
initialized another fresh node's PID from stale pool data **0x00650067** to
**0x684** before publication. A subsequent request from the same GameInput
process selected that exact node at driver RVA **0x91ea**, then loaded its
existing WDF queue handle at **0x91ee**. WDF resolved the handle as a manual
queue. This demonstrates queue reuse after the missing PID initialization is
supplied. It is a one-entry mechanism PoC, not a measured performance fix:
existing excess queues remain, and growth rate, cleanup cost, FPS and input
behavior have not been compared. The VM was left paused with the correction
still present and no remaining experiment breakpoints.

This is a statically identified and live-observed defect with a plausible connection to the contributed
[cleanup-heavy service comparison](community-capture-20261028-l4d2-pair.md).
The contributor's live queue count and allocation history were not captured;
the defect is **not yet a demonstrated cause of their FPS loss or a supported
fix**. A later [fresh-device comparison](vm-queue-comparison.md#paired-handle-close-result)
now supplies a limited mechanism/performance PoC: corrected queue count stayed
at one, while the uncorrected device accumulated thousands, and median
metadata-only handle-close time fell from **411.45 to 11.7 microseconds** across
100 successful pairs per condition. The single serial pair has unequal exposure
and incomplete retired-device teardown. A
[reversed-order check](../evidence/runtime/vm-handle-close-reversed-pair-20261029.json)
reproduced the difference (437.8 versus 11.15 microseconds median), while reusing
the corrected lifetime. Game FPS and controller fidelity remain untested.
The older rumble-off idea was an assumption based on one ETL from
the GitHub issue, not an observed packet sequence; this finding does not
establish such traffic either.

The [actual x86 XInput API comparison](vm-xinput-state-comparison.md#corrected-comparison-2026-10-29)
now also shows lower call cost with the correction: disconnected-slot medians
fell from **1834-2747 to 42-125 microseconds** (21.90-43.94 times lower), with
100 calls per slot/condition and matching reference binaries and limits.
The corrected device retained one node after all 400 calls and transfer.
This strengthens the local mechanism/performance PoC, while retaining serial
pair/exposure limitations and the need for per-call stack and game-frame proof.

## Evidence and identities

**2026-10-30 direct queued-client follow-up:** a single-outstanding-request
client using input `03 01 00 00` records 355 initially pending submissions,
354 successful 24-byte replies and one confirmed deadline cancellation. None
of the 353 adjacent successful payload pairs repeats after excluding the packet
word; only left-stick bytes change besides that packet. Complete bounded list
walks grow from 587 entries to 942 and still find 942 after process exit; no
stored PID matches the still-live test PID at the intermediate snapshot. The
aggregate increase matches all 355 submissions but is not a per-allocation
trace. This supports the queue-identity mechanism without an unchanged-success
flood or a game-performance claim. See
[completion and retention evidence](queued-state-validation.md). A fresh
uncorrected/corrected comparison remains outstanding for this client.

[Acquisition provenance](windows10-binary-acquisition.md) records the Windows 10
files. The [literal excerpts](../evidence/static/windows10-queue-identity-excerpts.txt)
and [manifest](../evidence/static/windows10-queue-identity.json) retain nine
function exports. All **1,314 exported instructions** were checked against their
pinned source PE bytes. Matching public PDB GUID/age pairs were verified before
headless Ghidra 12.1.3 analysis. Pseudocode types and indirect-call signatures
remain decompiler interpretations.

REA independently recovered the Windows 10 handler without the companion PDB:
Evidence `ev_b14f7ba0ac792b5a68e125de6acae32f25f677a188ac7f3a8ae8810821ffa544`
reports the same missing store. The complete REA bundle and snapshots remain
private under the local analysis-copy directory; headless exports remain in
ignored `artifacts/`. No target code was executed or installed.

## The missing field initialization

Windows 10 `DispatchGetUnfilteredGamepadState` is at **0x1c0009068**, SHA-256
`c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f`.
Its complete function export contains 216 byte-verified instructions.

With request byte 3 nonzero it returns the cached 24-byte state. With that byte
zero, it obtains the IRP requestor PID, holds the device's wait lock, and searches
the list rooted at device-context offset **0x80**. Each 32-byte node contains
list links at offsets **0x00/0x08**, the compared PID at **0x10**, and a WDF queue
handle at **0x18**.

- **0x1c00091a5–0x1c00091bf:** obtain the requestor PID and preserve it in R12D.
- **0x1c00091e4:** `CMP dword ptr [R8+0x10], R12D` tests the existing node's PID.
- **0x1c000926d–0x1c000929b:** allocate 32 bytes with
  `ExAllocatePoolWithTag(0x200, 0x20, 0x50484958)`, preserving the result in RSI.
- **0x1c00092f5–0x1c0009314:** supply `node+0x18` as the queue-handle output
  to the WDF queue-creation call.
- **0x1c000931a:** overwrite R12D with `0xc0000000` for status classification.
- **0x1c000938d–0x1c00093aa:** publish the node's list links, with **no store
  of the requestor PID to node+0x10**. The allocated node is not zeroed either.

This absence holds across the entire successful allocation/creation/publication
path, not just a short excerpt. WDF's output pointer is to the queue-handle field,
not to the PID field. The installed KMDF 1.15 `wdffuncenum.h` maps the table
base **0x1c000e240** plus slot **152** to `WdfIoQueueCreate` at **0x1c000e700**,
and slot **281** to `WdfRequestForwardToIoQueue` at **0x1c000eb08**. Slots 313/314
map the acquire/release calls at **0x1c000ec20/0x1c000ec28**.

Microsoft documents that [ExAllocatePoolWithTag returns uninitialized memory](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-exallocatepoolwithtag).
[WdfIoQueueCreate's output](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdfio/nf-wdfio-wdfioqueuecreate)
is a queue handle. Neither call establishes the missing PID.

The consequence is conditional on the stale pool contents: if no node's
uninitialized field happens to equal the current PID, the next queued request
creates another node and queue instead of reusing the prior queue. Exact queue
growth rate, accidental PID matches and allocation failures are runtime unknowns.
Do not assume the field is always zero or that every request must allocate.

For comparison, Windows 11 **10.0.26100.9278**, SHA-256
`1e85d1a191f09ed62645658c94f908b733da5a026ed2b6b662635ebbddf84588`,
performs **`44896610 MOV dword ptr [RSI+0x10],R12D` at 0x14000d59a** after
successful queue creation and before publishing the node. Its entire 239-instruction
handler was also source-byte checked. This comparison identifies a semantic
correction; it does not date the change or establish which other builds contain it.
The later [version-history investigation](xinputhid-pid-version-history.md)
extends that original two-file comparison with additional exact identities.

## Inbox reachability and game-side amplification

The contributor-hash inbox **0.2309.19041.6456** supplies a static route to the
affected branch. `XusbWatcher::WorkerThread` at **0x18003b758** passes true to
`RequestUnfilteredState` at **0x18003b524**. The helper XORs that Boolean with one
at **0x18003b549** and stores it as input byte 3 at **0x18003b554**, making the
worker's request flag **zero**. It submits **0x8000e388** with a four-byte input
and 24-byte output. The worker then calls `NtWaitForSingleObject` with a null
timeout. It reissues after completion; this is not evidence of an unconditional
busy loop. Actual use of this specific worker/device path during the trace still
requires observation.

The reconstructed x86 XInput **10.0.19041.3636** matches the game's trace version
and PE/PDB identities, with contributor whole-file hash unavailable.
`DeviceEnum::GetDeviceOnPort` at **0x10004efc** may call enumeration when the
requested port has no cached entry and enumeration is allowed. The local retry
counter is bounded; repeated game API calls can still repeat enumeration for an
absent port. The requested port numbers and API-call rate were not measured.

`EnumerateXInputDevices` at **0x10004e01** opens an interface, inspects it, then
calls **CloseHandle at 0x10004eca**. This accounts for the observed game-side
enumeration-to-cleanup route without requiring game-side unfiltered-state calls.
The exact device path opened by each game call is not available in these traces.

The enabled trace contains **3,459/3,993 samples (86.63%)** with
`EvtDeviceWdmIrpPreprocess`, all continuing into
`imp_WdfDeviceWdmDispatchPreprocessedIrp`; none are exclusive to the preprocess
callback. Its relevant measured child is `FxPkgGeneral::Dispatch`, including
spin-lock operations, `FxObject::Release` and `FxIoQueue::DispatchEvents`.
Thus the driver's feature-gated system-button cancellation list scan is not
established as the measured bottleneck.

Microsoft's [published WDF cleanup code](https://github.com/microsoft/Windows-Driver-Frameworks/blob/main/src/framework/shared/irphandlers/general/fxpkggeneral.cpp)
calls [FlushAllQueuesByFileObject](https://github.com/microsoft/Windows-Driver-Frameworks/blob/main/src/framework/shared/irphandlers/io/fxpkgio.cpp),
which iterates the device's queues, flushes matching requests, releases references
and advances under locks. This gives a plausible amplification mechanism for
excess queue objects, consistent with the measured stack shape. The published
source is contextual evidence, **not a verified source revision of the loaded
1.31.19041.5794 framework binary**.

## Lifetime and falsifiable next experiment

The inspected `_CreateProcessNotifyRoutine` at **0x1c000a190** updates focus
bookkeeping; it does not remove the per-process queue nodes. The inspected
`EvtDeviceReleaseHardware` at **0x1c0006dc0** has a feature-gated traversal that
deletes their WDF queue objects and frees nodes with tag **0x50484958** (bytes
`X I H P`, commonly displayed as `XIHP`). This does not prove that stopping the
service removes accumulated queues. Recovery timing is a separate test.

Before a hardware PoC, agree on a disposable Windows 10 VM or test machine,
the exact driver build, controller/connection, workload, recording duration and
collection scope. A useful bounded experiment would:

1. Start from a documented fresh device lifetime and record baseline device
   queue count, `XIHP` allocations, handle-close latency and frame times.
2. Observe queued unfiltered-state submissions, their actual originating
   process/device, completions, and queue creation/reuse while input changes.
3. Verify whether multiple nodes accumulate for the same requestor while their
   PID fields fail to identify it. Measure cleanup cost against queue count.
4. Compare a narrowly corrected test implementation that initializes the PID
   before list insertion. Check queue reuse, close latency, frame times, input
   delivery, vibration, reconnect and recovery separately.

The conceptual correction is `newEntry->ProcessId = requestorPid` before
publication. It is not an installable patch. A safe hardware demonstration needs
a separately agreed test environment and a build-specific correction strategy;
the current user-mode probe does not patch this kernel field. A throttle could
hide allocation growth while leaving the defect intact, so it is not justified
as a proven fix by this finding.

There is also a falsification check: if close latency falls immediately when the
service stops while excess device queues remain unchanged, queue accumulation
alone does not explain that recovery. Preserve that result and investigate the
remaining interaction rather than forcing it into this hypothesis.

## Reproduce the retained static evidence

Use the installed-tool setup and explicit matching-PDB importer in
`tools/ghidra/README.md`. The ignored projects are `CommunityWin10Driver`,
`CommunityWin10Xinput` and `CommunityWin10Inbox`; the Windows 11 comparison uses
the earlier `XinputKernel` exports. Select these preferred VAs with the existing
`ExportXinputEvidence.java <output-directory> exact <addresses...>` command:

- Driver: `1c0009068 1c0003240 1c000a190 1c0006dc0`, output
  `artifacts/win10-driver-analysis`.
- Inbox: `18003b524 18003b758`, output `artifacts/win10-inbox-analysis`.
- x86 XInput: `10004e01 10004efc`, output `artifacts/win10-xinput-analysis`.
- Windows 11 driver: `14000d1d8`, existing output `artifacts/xinputhid-analysis`.

Then run `python tools/ghidra/SaveWindows10QueueEvidence.py`. The retention
script refuses unexpected binary hashes, incomplete decompilation, missing
instructions and source-byte mismatches. Original full logs and failed attempts
remain ignored. An attempted WDF reconstruction from the ISO's serviced baseline
failed with invalid delta data; the symbol-server alternative has resource version
1.31.19041.7714 and is not certified as the contributor's exact framework binary.
