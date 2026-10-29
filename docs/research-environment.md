# Research environment and procedure

This records the tools and workflow used for the October 28-29, 2026
investigation. It describes the completed experiments, rather than a general
installation recipe or a supported workaround. Results and remaining limits
are in the [findings](gameinput-service-fault.md) and
[VM validation checklist](vm-validation-checklist.md).

## Host, guest and tools

Host tool versions were checked from installed file/package metadata on
2026-10-29 after the VM batch. They are distinct from the guest binary identities
recorded in the [component inventory](../evidence/runtime/vm-component-inventory-20261029.json).

- Host: Windows 11 x64, build **26200.9457**.
- VMware Workstation and its `vmrun.exe`: **26.0.1 build 25688693**.
  Workstation hosted the guest, snapshots, USB passthrough and virtual serial
  port. VMware Tools provided the temporary shared-folder transfer path; its
  exact guest version was not recorded.
- Microsoft Store WinDbg: **1.2610.1001.0**, using Microsoft's **built-in MCP
  server** and `DbgX.Mcp.Proxy.exe`. The later live sessions were operated from
  Codex desktop through a custom stdio MCP registration. Earlier debugger
  commands were entered by the operator and shared as output.
- Host orchestration: PowerShell **7.6.5** and Python **3.11.9**. Compatibility
  parsing was also run explicitly under Windows PowerShell **5.1.26100.9444**.
- Guest: Windows 10 22H2 x64, build **19045.5796**, with its NIC disconnected
  and operator-created snapshots. The guest ran its installed Windows files
  after their hashes were matched to the research references.
- Controller: a physical PS3 controller passed through over USB, with
  **DsHidMini 3.27.0.2500** in XInput mode, `mshidumdf` and
  `xinputhid.sys` **10.0.19041.5794**. An earlier Xbox controller exposed a
  different driver path and was replaced for this experiment.
- Guest workloads: Windows PowerShell **5.1**, including its **x86/WOW64**
  executable for x86 XInput tests, and C# helpers compiled locally with
  `Add-Type`. The exact guest PowerShell patch version was not collected.
  Native x64 PowerShell was used for inventory and the service recovery helper.

The guest inbox GameInput implementation was **0.2309.19041.5794**, older than
the contributor's **0.2309.19041.6456**. The driver and x86 XInput backing hashes
match the contributor's supplied files. Those distinctions remain part of the
results; matching one component does not make the whole environment identical.
Exact AI client/model builds were not pinned as experiment identifiers.

## Debugger connection

The guest kernel was debugged through VMware's virtual serial port at
**115200 baud**, backed by the host named pipe `\\.\pipe\GameInputKD`.
This was a live kernel session, not a crash-dump analysis. Microsoft's
[virtual COM debugging documentation](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/attaching-to-a-virtual-machine--kernel-mode-)
describes this transport; the experiment used the existing prepared guest.

The MCP connection was a separate layer: Codex communicated over stdio with
Microsoft's proxy, which connected to the selected host WinDbg session through
its local MCP pipe. That architecture is described in the
[WinDbg MCP overview](https://learn.microsoft.com/en-us/windows-hardware/drivers/debuggercmds/windbg-mcp-overview).
Codex was a working custom-client configuration, not a claim of official client
support. MCP setup references are in Microsoft's
[setup guide](https://learn.microsoft.com/en-us/windows-hardware/drivers/debuggercmds/set-up-windbg-mcp).

The successful connection used a non-elevated host WinDbg instance. The session
reported partial Secure Mode because a target was already attached. The operator
disabled the output cross-prompt mitigation after an unsupported MCP
`sampling/createMessage` compatibility error. These are historical session
settings, not prerequisites or recommendations for other installations.

Target-state checks, bounded process/thread-scoped breakpoints, register and
memory reads, module inspection, and `!wdfkd` extensions supplied the live
evidence. A guarded, single-entry PID metadata correction was tested before
queue publication, with the original value recorded. It changed neither the
driver file nor its executable instructions and applied to that process/device
lifetime only. The [queue investigation](windows10-queue-identity.md) and linked
runtime records distinguish correction, publication, reuse and timing results.

## Experiment procedure

1. **Establish binary provenance.** Use contributor inventories and files,
   Microsoft symbols, Windows installation media and update packages. Static
   work used REA/Ghidra, matching PDBs and byte checks. Offline reconstruction
   used 7-Zip 26.01 and Windows `msdelta.dll`; details, rejected candidates and
   hashes are in [binary acquisition](windows10-binary-acquisition.md).
2. **Prepare the isolated guest.** Preserve the operator's snapshot and
   disconnected NIC, assign the physical controller to the VM, and verify the
   actual driver stack and loaded modules. Public symbols supplied the
   xinputhid/WDF names and types used in inspection.
3. **Transfer bounded workloads.** Earlier guest tools were delivered on local
   ISOs built with Windows `IMAPI2FS.MsftFileSystemImage` and a C# stream writer.
   Later, `vmrun` enabled two dedicated VMware Tools/HGFS shares: read-only
   `GameInputTools` and writable `GameInputResults`. This transfer did not
   require enabling the guest NIC. Issued ISOs and source copies remain private.
4. **Separate debugger observations from measurements.** Trace the controlled
   cleanup route while stopped, then remove the experiment breakpoints and
   resume for timing runs. Debugger-paused API durations are excluded. The
   WOW64 user-stack unwind failed; the confirmed kernel route is documented
   separately from that unavailable user stack.
5. **Measure the API and queue population.** Use
   [Measure-XInputHandleClose.ps1](../tools/runtime/Measure-XInputHandleClose.ps1),
   [Measure-XInputState.ps1](../tools/runtime/Measure-XInputState.ps1), and the
   [persistent runner](../tools/runtime/Start-VMValidation.ps1). Record bounds,
   slot/return-code groups, raw script hashes and queue snapshots. Verify the
   loaded XInput backing file by identity and hash: WOW64 can report a System32
   path for the verified SysWOW64 file, so path text alone is insufficient.
6. **Collect operator observations.** The operator performed USB reconnects,
   held inputs, stick motion and physical vibration checks. Retain requested
   actions, actual reports and sampled state separately. The
   [active-input helper](../tools/runtime/Measure-VMActiveInput.ps1) recorded the
   30-second moving-stick phase. A successful API return is not proof of every
   physical transition or a measurement of input latency.
7. **Test recovery explicitly.** The
   [service helper](../tools/runtime/Invoke-VMServiceRecovery.ps1) temporarily
   stopped only `GameInputSvc`, recorded producer exit and retained queues, then
   restored Running/Manual state. The
   [inventory helper](../tools/runtime/Save-VMInventory.ps1) collected backing
   hashes, loaded module paths and controller driver metadata.
8. **Validate and clean up.** Python regression tests used synthetic API/service
   backends as well as evidence checks; they are distinct from physical tests.
   Both real runners ended cleanly. Runtime sharing was disabled, configured
   share count returned to zero, and the guest was left running with the service
   restored and no experiment breakpoints. VMware retained inactive cached VMX
   slot records; no manual edit of the running VMX was attempted.

Raw debugger logs, captures, binaries, symbols, ISOs and identifying paths stay
under ignored local directories. Git contains reviewed summaries, hashes,
scripts and tests. AI clients received selected debugger output; excluding files
from Git does not mean that all analysis was processed on-device. A debugger
tool timeout was checked against later output
history/logs before deciding whether its command had completed; a timeout alone
was not treated as proof that nothing ran.

## Other phases and limits

Earlier Windows 11 USB/Bluetooth observation used the separate Detours/Injector
research probe and WPR/WPA/ETW evidence. The Windows 10 VM batch used standalone
XInput workloads and kernel debugging. These tools and phases have different
purposes; neither the probe's existence nor the VM correction validates a
general throttling workaround.

VMware scheduling, USB passthrough, serial-debugger overhead, serial test order,
controller activity and retained old device contexts limit the comparisons.
No game workload was run or required for this batch, and no game frame times were
measured. The [checklist](vm-validation-checklist.md) records negative results,
unmatched workloads and the limits of the coarse input/vibration checks.
