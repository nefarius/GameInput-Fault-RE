# xinputhid PID initialization: verified version history

Investigated 2026-10-30, x64 binaries only. This dates the implementation of
the [per-process queue identity field](windows10-queue-identity.md), not a
general GameInput, controller, or game-performance fix.

## Latest Windows 10 package verified

**KB5134125, October 26, 2026** still supplies the affected x64
**xinputhid.sys 10.0.19041.5794**, byte-identical to the contributor file:
SHA-256 `c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f`.
The [Microsoft release page](https://support.microsoft.com/help/5134125)
maps that update to **Windows 10 22H2 / 19045.7811** and **21H2 / 19044.7811**.
The downloaded Catalog entry was the 22H2 x64 package. This is now verified
from its actual forward delta, beyond the earlier third-party index lead.
This package contains no correction to the inspected PID initialization.

The older **KB5031445 / Windows 10 22H2 build 19045.3636**, released
[October 26, 2023](https://support.microsoft.com/help/5031445), reconstructs
driver **10.0.19041.3636**. REA inspected its complete dispatch at
`0x1c0008cec`: the queued `0x8000e388` handler is absent. Together with the
already inspected affected 19041.3996 file, this bounds the introduction between
those revisions. Every intervening package and historical feature enablement
remain unverified.

The [shipping-package manifest](../evidence/static/win10-shipping-driver-20261030.json)
and [older dispatch excerpt](../evidence/static/win10-shipping-driver-20261030-excerpts.txt)
record the identities. The latest 1,055,236,145-byte MSU has SHA-256
`c8c4d65e7ea52afe905a33646de3432beb22d01817452b33d4b43d9a04ac3ca3`;
SHA-1 `938ad1b5ef48df6483c2b7beecd02e62d61e5dc4` matches Microsoft's download
filename. 7-Zip 26.01 extracted the nested CAB wrappers and
`Cab_1_for_KB5134125.cab`. Its
`amd64_dual_xinputhid.inf_31bf3856ad364e35_10.0.19041.5794_none_adb9346e610fdc40/f/xinputhid.sys`
delta has SHA-256
`1da4db0cc5002d92f7172d8234249a61c5b522c417f7ef4af13f7d4dafe44566`.
The CRC32-checked delta applied successfully with `msdelta!ApplyDeltaB`, flags
zero, to the existing ISO baseline 19041.1, producing the exact 61,952-byte
contributor file. No resource restoration was needed for these two Windows 10
package reconstructions.

The original MSU, selected payloads, outputs and logs stay ignored under
`artifacts/acquisition/win10-latest-20261030/`. A workspace disk-full failure
left a partial intermediate CAB; complete extraction on the host's NTFS temp
volume succeeded. The failure was preserved and original captures were not
deleted. No package was installed, no new kernel experiment ran, and equality
with a shipping file does not identify modules loaded on another machine.

The operator's additional idle-breakpoint observation and the corresponding
DsHidMini/xinputhid completion question are tracked
[separately](dshidmini-idle-completions.md).

## Answer

The earliest **verified correct queued implementation** is **xinputhid.sys
10.0.22621.3085**, shipped in **KB5034204 on January 23, 2024**:

- **Windows 11 22H2: OS build 22621.3085.**
- **Windows 11 23H2: OS build 22631.3085**, using the same 22621 driver family.

Microsoft's [KB5034204 release page](https://support.microsoft.com/help/5034204)
confirms the date, two OS builds and public release names. The PID store is
our binary-analysis finding; Microsoft does not identify it in those release
notes. The dispatch case is feature-gated in this revision. We verified the
code when that path is selected, not the feature's historical rollout state.

This is **not a demonstrated Windows 11 broken-to-fixed transition**. The
previous distinct x64 driver revision in the retrieved index,
**10.0.22621.2506**, has no dispatch case for `0x8000e388`; it falls through to
`STATUS_INVALID_DEVICE_REQUEST`. It is classified **handler absent**, not
"PID fault present" or "fixed by rejecting requests". In this verified
transition, the newly present queued path already initializes the PID.
Insider builds, every intermediate package and other architectures were not
exhaustively inspected; "first ever fixed Windows build" would overstate this.

For **Windows 10**, no corrected shipping revision has been established:
**10.0.19041.3996** and the contributor's **10.0.19041.5794** both omit the
initialization. The former maps to **Windows 10 22H2, OS build 19045.3996**,
[KB5034203, January 23, 2024](https://support.microsoft.com/help/5034203).
The latter was observed live on the research VM at **19045.5796**; its file
revision is not itself the OS build. This does not certify every later Windows
10 package as affected or establish when the defect was first introduced.

The correct store also exists in **10.0.26100.1**, the Windows 11 **24H2**
baseline, and in the previously inspected **10.0.26100.9278** file installed
on the **Windows 11 25H2, 26200.9457** research host. Therefore **25H2 is not
the earliest release containing the correct implementation**. Microsoft's
[release information](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information)
maps the 26100 and 26200 OS families to 24H2 and 25H2. A shared driver file
version must not be used to infer the installed public Windows release.

## What REA inspected

REA's Ghidra **12.1.3** provider independently analyzed the files without a
caller-supplied PDB. Names below are semantic labels derived from dispatch
and data flow, not recovered private symbols. Full reviewed assembly is in
[the excerpts](../evidence/static/xinputhid-pid-version-history-excerpts.txt);
[the manifest](../evidence/static/xinputhid-pid-version-history.json) records
hashes, addresses, acquisition and REA Evidence IDs.

- **22621.2506:** dispatch at `0x1c0008200` handles neighboring XInput IOCTLs
  but has no `0x8000e388` case. This is inspection of the full dispatch body,
  not a conclusion from an empty symbol/string search.
- **22621.3085:** dispatch at `0x1c00087dc` gates the IOCTL through
  `0x1c0001fc0`, then calls the handler at `0x1c0007a9c`. The handler obtains
  the requestor PID, compares the DWORD at node offset `0x10`, allocates a
  32-byte node and creates its WDF queue. On success,
  **`44 89 66 10` at `0x1c0007dea` stores R12D to `[RSI+0x10]`**, before list
  publication at `0x1c0007dfe`. A REA read of the handler's byte range matched
  the reconstructed PE. This is the same missing assignment supplied in the
  earlier VM mechanism PoC.
- **19041.3996:** the feature-gated dispatch at `0x1c0009724` reaches handler
  `0x1c0008f98`. It searches PID at `0x1c0009114`, but the full successful
  allocation/queue-creation/publication path has no corresponding PID store.
  R12D is overwritten with a status mask at `0x1c000924a`. This independently
  extends the static affected-version evidence earlier than 19041.5794.
- **26100.1:** handler at `0x1c0007168` performs the same
  **`44 89 66 10` store at `0x1c00074b1`**, before list publication.
- **19041.5794 and 26100.9278:** existing byte-checked static exports and the
  Windows 10 live experiments remain the references in
  [the original investigation](windows10-queue-identity.md).

The correct store prevents this particular uninitialized-PID mismatch. It does
not establish complete queue-lifetime correctness, input fidelity, absence of
other defects, or an FPS benefit on an affected player's machine. No driver
was installed, executed, backported or substituted during this comparison.

## Acquisition and reproducibility

Raw files remain ignored under `artifacts/xinputhid-version-boundary/`.
The [Winbindex index](https://winbindex.m417z.com/?file=xinputhid.sys) was used
for discovery, expected whole-file hashes and component/update associations;
it is a third-party index, not Microsoft's fix announcement. The retrieved
compressed index contains 84 records across architectures. Its hash is retained
in the manifest so the scope is reproducible.

Microsoft symbol-server image URLs use PE timestamp and image size, which do
**not** uniquely identify the whole file. For example, the URL associated
with 22621.3085 returned the same code with version resources saying
22621.1376 and a different whole-file hash. These candidates were retained as
distinct files and were not silently accepted as shipping 22621.3085.

For selected candidates, restoring the file/product version resource values,
their UTF-16 strings and the PE checksum reproduced the indexed shipping
SHA-256 exactly. No code section was changed. The 22621.1 baseline required
reserializing the shorter version strings and their resource-node lengths,
while preserving allocated resource extents. The reconstructed baseline hash
is `36bcb501378824fb58b8a28fe9599bc75072c92c4a3485c92d37b9eb252aec01`.
This is hash-validated artifact reconstruction for analysis, not a driver fix.

For the main 22621.3085 finding we additionally downloaded the original
[Microsoft Update Catalog KB5034204 package](https://www.catalog.update.microsoft.com/Search.aspx?q=KB5034204).
Its SHA-1 matched Microsoft's download filename. 7-Zip **26.01** extracted
the CAB and PSF without installation. The CAB's `express.psf.cix.xml` locates
the 7,868-byte `xinputhid.sys` forward delta at PSF offset **394570622** and
supplies its SHA-256, which matched. The component is
`amd64_dual_xinputhid.inf_31bf3856ad364e35_10.0.22621.3085_none_193ecab02728978d`.

The existing `artifacts/acquisition/updates/apply_delta.py` checked and stripped
the delta's CRC32 prefix, then applied it with Windows `msdelta!ApplyDeltaB`,
flags zero, to the hash-validated 22621.1 baseline. The **90,112-byte** output
hash is **`3753d94637ec3095c1c91a68f637e4c1e7898a069eee0a8828d3936325dae245`**.
It is byte-identical to the independently resource-restored 22621.3085 file
analyzed by REA. The 26100.1 download already matched its indexed hash without
resource restoration.

REA initially refused the workspace volume because its Windows provider
requires NTFS with persistent ACLs. Hash-identical temporary copies on the
host's NTFS volume succeeded; original artifacts stayed in the workspace.
An attempted `rea doctor` invocation could not acquire its uncached npm package
under the network-restricted shell; no REA configuration was changed. The
connected provider itself worked after the target copy. Full REA bundles and
failed acquisition attempts are retained privately. A delta attempt using the
unrestored symbol-server baseline failed with invalid data; the hash-validated
baseline succeeded. Standalone decompression of the compressed component
manifest also failed and was not used as evidence of its contents.

To repeat analysis, verify the manifest's SHA-256 values, open each exact PE
with REA's Ghidra provider, and request assembly/pseudocode for the addresses
above. Export the Evidence bundle before closing each session. Use the matching
preferred image base; RVAs and VAs from another driver revision are not reusable.
The retained public excerpts contain complete selected assembly bodies and
the source PE bytes at each instruction address, not original Microsoft source.
No VM or live debugger was needed for this static comparison.
