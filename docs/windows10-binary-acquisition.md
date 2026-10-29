# Windows 10 binary acquisition, 2026-10-28

## Contributor files received, 2026-10-29

The operator supplied `xinput files.zip` (239,709 bytes), SHA-256
`e1df942c10fdcbb011a66ea75d978c81be170c57661306ac8acef193f3e778ec`.
All three members pass ZIP CRC checks and match the previously analyzed files
by both SHA-256 and direct byte comparison: GameInputInbox 0.2309.19041.6456,
x86 XInput1_4 10.0.19041.3636 and xinputhid 10.0.19041.5794.
In particular, the contributed x86 XInput DLL matches the reconstructed hash
`afcef57f5c6068cedb49ddb370a8d070867fd47fcc8a67fd11694053885dec8d`.
This resolves the previously unavailable contributor whole-file comparison;
the historical acquisition limitations below describe what was known then.
See [reviewed identity evidence](../evidence/static/contributed-binary-identities-20261029.json).
The ZIP is stored as
`captures/community/20261029-user-binaries/GameInput-Win10-Binaries-20261029-e1df942c.zip`;
the ZIP and extracted raw files remain local and ignored. Only reviewed identity
metadata and documentation are committed. No contributed binary was executed
or installed. The archive's contributor provenance is operator supplied.

## Original acquisition

The [community service comparison](community-capture-20261028-l4d2-pair.md)
identified a game-side XInput enumeration/handle-close path. Offline acquisition
now supplies the Windows 10 binaries needed to inspect it without another
contributor collection. Acquisition alone establishes no fault or mitigation.

## Verified files

- **xinputhid.sys**, x64, **10.0.19041.5794**, 61,952 bytes.
  SHA-256 `c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f`
  exactly matches the contributor's collected inventory. PE timestamp
  `0x8622933a`, image size `0x17000`, checksum `0xf5de`, and
  `XINPUTHID.pdb` GUID `A4F14C10211FF645100498AA4182DC90`, age 1.
- **XInput1_4.dll**, x86/WOW64, **10.0.19041.3636**, 36,864 bytes.
  SHA-256 `afcef57f5c6068cedb49ddb370a8d070867fd47fcc8a67fd11694053885dec8d`.
  Version, architecture, PE timestamp `0x781fbf32`, image size `0xd000`, and
  `XInput1_4.pdb` GUID `822D0923E019D817BF1A55A08D50A9A2`, age 1,
  match the trace metadata. Its PE checksum is `0x16ca6`. The contributor's
  backing-file SHA-256 was not collected, so whole-file equality remains unknown.
- **gameinputinbox.dll**, x64, **0.2309.19041.6456**, 392,536 bytes.
  SHA-256 `b7d2fc1ec42dbd00c3dddb077ab32e7e5f84288b9c7e7dcafed324150b5242f7`
  exactly matches the contributor inventory. Retrieved from Microsoft's symbol
  server using key `D0CB92C864000`. PE timestamp `0xd0cb92c8`, image size
  `0x64000`, `GameInputInbox.pdb` GUID
  `EC4F06E945E009F4F9A91A045A44ADE7`, age 1.

## Reproduction and provenance

The baseline source was `Win10_2004_English_x64.iso`, 5,268,953,088 bytes.
WIM metadata reports Windows 10 Pro at index 6, build 19041.264. A read-only
ISO mount and installed 7-Zip 26.01 extracted only:

- `6\Windows\SysWOW64\XInput1_4.dll`, version 10.0.19041.1,
  SHA-256 `08a832787f00f95ebf771cb83b0723513dc16548fafdeeda15ded52d52c1a480`.
- `6\Windows\System32\drivers\xinputhid.sys`, version 10.0.19041.1,
  SHA-256 `5980bbbd0e7a19302806fa1941a3e178288c42c8c80b8a9ea5970e09005097d6`.

The WIM extraction API first failed with Win32 error 1314 (required privilege
not held). 7-Zip succeeded for both selected files, while reporting a WIM
reference-count warning. No full image was applied, and the ISO was dismounted.

Updates were downloaded from the [Microsoft Update Catalog, KB5031445](https://www.catalog.update.microsoft.com/Search.aspx?q=KB5031445)
and [KB5055612](https://www.catalog.update.microsoft.com/Search.aspx?q=KB5055612).
Their downloaded sizes and SHA-256 values were:

- KB5031445 x64: 810,218,344 bytes,
  `6f6c38c9cb6196481af4c99d1ef59b853bfb00b18e545f2f30f7430a46312981`.
- KB5055612 x64: 746,606,349 bytes,
  `4baca6f59baf31bc2eeab8ab64d7576f574f35f0d0269a96774bb253390aeee1`.

Each download's SHA-1 also matched the digest in its Microsoft download filename.
7-Zip extracted the nested CAB payloads, retaining their component paths:

- KB5031445 `Cab_1_for_KB5031445_PSFX.cab`:
  `wow64_microsoft-windows-directx-xinput1_4_31bf3856ad364e35_10.0.19041.3636_none_c026a486e7191b63\f\xinput1_4.dll`.
  Delta SHA-256 `3034097231532fe0dfc4fd6b5c53c251e1d585e31162ff5c9dcb21875b51febb`.
- KB5055612 `Cab_1_for_KB5055612.cab`:
  `amd64_dual_xinputhid.inf_31bf3856ad364e35_10.0.19041.5794_none_adb9346e610fdc40\f\xinputhid.sys`.
  Delta SHA-256 `798c989d108ae6eb64b6621ec3f13a404ff29cecc325420707ce81ecf53201c5`.

For each delta, the four-byte CRC32 prefix was checked against the remaining
PA30 payload and removed. Windows' installed `msdelta.dll` applied the payload
to the corresponding baseline with `ApplyDeltaB`, flags zero. Both calls
succeeded. Output file hashes, version resources, architecture and CodeView
records were checked; REA independently inventoried the PE resources and hashes.
The DLL/driver files were not executed, installed or loaded as code.

Raw packages, baselines, reconstruction scripts, per-file provenance and REA
records remain ignored under `artifacts/acquisition/`. These are acquisition
artifacts, not dependencies or allowlisted probe targets.

## Rejected candidates and next step

Microsoft's symbol server returned files with matching timestamp/image size
and PDB identity but different version resources: xinputhid 10.0.19041.6456
and x86 XInput 10.0.19041.7722. The driver candidate also failed the known
whole-file hash. They remain preserved separately and are not treated as the
contributor's exact files. PDB identity alone does not prove whole-file identity.

The [subsequent static investigation](windows10-queue-identity.md) inspected the
driver and x86 XInput paths, found a missing PID initialization in the driver's
queued-state handling, and verified inbox reachability. Live queue growth,
repeated rumble-off causation and a safe PoC fix remain unproven. No throttle
experiment, service change or compatibility-gate change follows from acquisition.
