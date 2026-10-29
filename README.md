# GameInput Fault Investigation

Getting sudden stutters, FPS drops, or unusually high CPU usage while using a controller on Windows? We're investigating reports that Microsoft's GameInput services may be involved. Our goal is to understand what goes wrong and find a reliable fix that keeps your controller working.

**Need help? Come talk to us on Discord: [discord.nefarius.at](https://discord.nefarius.at/).** You don't need to be a developer. We can help you work out which details to share and how to collect a useful report.

## Think you're affected? Start here

1. **Tell us what happens.** Join [our Discord](https://discord.nefarius.at/) or [open an issue](https://github.com/nefarius/GameInput-Fault-RE/issues/new/choose) and describe your controller, how it connects, which games are affected, and when the problem starts. It's fine if you're unsure whether GameInput is the cause.
2. **Collect a report while the problem is happening.** Follow the [step-by-step diagnostic guide](docs/collecting-diagnostics.md). The collector uses tools included in Windows; no programming or developer tools are needed.
3. **Review before sharing.** The collector creates a ZIP on your PC. Ask us on Discord if you need help reviewing it or arranging private sharing. Nothing is uploaded automatically.

To get the collector, choose **Code → Download ZIP** on this GitHub page and extract the downloaded ZIP. Inside the extracted folder, open `tools/collector` and double-click **Collect-Diagnostics.cmd**. The default is one five-second recording: reproduce the problem, press Enter when ready, then describe what happened during those seconds. The [guide](docs/collecting-diagnostics.md) explains the administrator prompt, privacy notice, and recording steps. Longer recordings can overwrite earlier data in the fixed memory buffers.

Reports can contain device identifiers, your Windows user name in file paths, and information about other running applications. Read the privacy notice before collecting or sharing anything. Keep your original settings for the first report so we can investigate the behavior you're actually seeing.

## Already have findings to share?

**Issues and pull requests are welcome!** If you've already collected diagnostics, tested a reproduction, investigated with AI agents, or found something we missed, [open an issue](https://github.com/nefarius/GameInput-Fault-RE/issues/new/choose) to share your findings or [submit a pull request](https://github.com/nefarius/GameInput-Fault-RE/compare) with code, documentation, or evidence improvements. You don't need to join Discord first.

AI-assisted contributions are welcome too. Include what you tested, the relevant Windows/controller/driver versions, and the evidence behind your conclusions. Clearly distinguish measured results from hypotheses or AI-generated suggestions so others can check and build on your work. Review diagnostics for private information before posting them publicly.

## Is there a fix yet?

**There is no verified general fix or supported one-click workaround yet.** We have identified a specific Windows 10 driver defect and demonstrated a limited correction in a research VM.

In the tested Windows 10 setup, `xinputhid.sys` can create new queues instead of reusing an existing queue for the same process. Correcting a missing process ID in one fresh entry restored reuse and reduced handle-close and XInput API costs in earlier comparisons. Coarse input and vibration checks also succeeded. This debugger-only correction is tied to one process and device lifetime; it is not a downloadable fix.

The latest tests add two important limits: an idle comparison with few queues showed no clear API cost difference, while controller activity was followed by thousands of queues and higher costs. Stopping GameInput Service afterward left the accumulated queues and elevated costs in place. See the [VM results and limitations](docs/vm-validation-checklist.md).

**A game FPS benefit, full controller compatibility, and applicability to other Windows versions remain unproven.** The VM uses a PS3 controller through DsHidMini in XInput mode and the contributor-matching Windows 10 driver, with an older inbox GameInput revision than the contributor's.

Our comparison tests with an Xbox controller over USB and Bluetooth did not reproduce the suspected busy polling. That doesn't rule out problems with other controllers, drivers, Windows versions, or games. Reports from people who can reproduce the issue are especially useful.

For current progress, see the [findings](docs/gameinput-service-fault.md), [Windows and GameInput version inventory](docs/version-matrix.md), and [test status](docs/implementation-status.md).

<details>
<summary>Technical information for developers and researchers</summary>

Continuing the investigation with a coding agent? Start with [AGENTS.md](AGENTS.md) for the evidence standards, collection workflow, prototype boundaries, and validation commands.

The [research environment and procedure](docs/research-environment.md) records the VMware Workstation guest, WinDbg/MCP connection, tool versions, operator steps, workload transfer, measurement controls and cleanup used for the VM experiments.

The [research probe and workaround instructions](docs/workaround.md) cover the experimental Detours probe. Build with `tools/build/build.ps1`, fetch the checksum-pinned Injector with `tools/dependencies/Get-ResearchDependencies.ps1`, then use `tools/probe/Invoke-GameInputResearch.ps1`. Observation is the default; throttle mode is an explicit, bounded experiment.

The [kernel analysis](docs/kernel-xinputhid.md) and [user-mode validation](docs/user-mode-validation.md) explain the inspected request paths. Their completion waits matter: finding a polling loop alone does not prove excessive CPU use or a link to repeated vibration commands.

The [Windows 10 queue-identity investigation](docs/windows10-queue-identity.md) covers the missing initialization in `xinputhid.sys` 10.0.19041.5794. Live debugger observations now confirm repeated allocation, corrected-node reuse, and an XInput call reaching the loaded WDF cleanup traversal. This queue-accumulation mechanism does not establish the immediate unchanged-response flood required to justify the separate throttling prototype.

The [proposed supported helper](docs/supported-tool-design.md) remains a design, subject to validation and release requirements. Raw captures, symbols, downloaded tools, and local builds are excluded from git.

</details>

## Credits

Analysis tools:

- [REA](https://github.com/morluto/rea) (`rea-agents` 6.8.0), connected to Cursor as the local MCP server and used to open the binaries, recover strings, and decompile with Ghidra. Install notes: [rea.tools/get-started](https://rea.tools/get-started/).
- [Ghidra](https://ghidra-sre.org/) 12.1.3, the provider REA used for `GameInput.dll` and `GameInputRedist.dll`.
- [Microsoft public symbol server](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/microsoft-public-symbols) and [dbh.exe](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/dbh) from the Windows SDK, used to read the inbox `GameInput.pdb`.
- [WinDbg and its built-in MCP server](https://learn.microsoft.com/en-us/windows-hardware/drivers/debuggercmds/windbg-mcp-overview) 1.2610.1001.0, connected through Microsoft's `DbgX.Mcp.Proxy.exe`, for live kernel queue, cleanup-path, and recovery observations.
- [VMware Workstation](https://www.vmware.com/products/desktop-hypervisor/workstation-and-fusion) 26.0.1 build 25688693, for the Windows 10 VM, snapshots, USB controller passthrough and virtual serial debugging. `vmrun` and VMware Tools supplied the temporary guest-tool/result transfers.
- Cursor and Codex desktop, for AI-assisted analysis, scripting and debugger orchestration. Findings were checked against binary and runtime evidence; the [procedure](docs/research-environment.md) records the roles and limitations.
- [Microsoft Detours](https://github.com/microsoft/Detours), pinned to the v4.0.1 commit, for the research API hooks.
- [Nefarius Injector](https://github.com/nefarius/Injector/releases/tag/v1.5.0) v1.5.0, for loading the probe into allowlisted GameInput processes. Its release archive is verified with the published SHA-256 before extraction.
- [Windows Performance Recorder](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/windows-performance-recorder) and [Windows Performance Analyzer](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/windows-performance-analyzer), for CPU stacks and ETW correlation; [DeviceIoControl](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-deviceiocontrol) and [GetOverlappedResult](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-getoverlappedresult), for completion semantics.
- [Visual Studio](https://visualstudio.microsoft.com/), [CMake](https://cmake.org/), [PowerShell](https://github.com/PowerShell/PowerShell), [Python](https://www.python.org/), and [Git](https://git-scm.com/), for building, collection, evidence analysis, and version control.
- 7-Zip 26.01 and Windows `msdelta.dll`, for offline reference-file extraction/reconstruction; Windows IMAPI2FS, for preparing guest-tool ISOs. See [binary provenance](docs/windows10-binary-acquisition.md) and the [environment record](docs/research-environment.md).

Third-party license texts and dependency pins are in [third_party/NOTICES.txt](third_party/NOTICES.txt).

Reports and upstream projects:

- [DsHidMini issue 438](https://github.com/nefarius/DsHidMini/issues/438), for controller-mode/CPU reports and contributed diagnostics. Repeated rumble-off traffic was an assumption, not an established observation from its ETL. Driver project: [nefarius/DsHidMini](https://github.com/nefarius/DsHidMini). Trace instructions: [Debugging the Drivers](https://docs.nefarius.at/projects/DsHidMini/v3/Debugging-the-drivers/).
- [GameInput issue 34](https://github.com/microsoftconnect/GameInput/issues/34) and the [GameInput releases](https://github.com/microsoftconnect/GameInput/releases), including [v3.3.195.0](https://github.com/microsoftconnect/GameInput/releases/tag/v3.3.195.0). Upstream repo: [microsoftconnect/GameInput](https://github.com/microsoftconnect/GameInput).
- [PCMR report](https://www.reddit.com/r/pcmasterrace/comments/1xee4qw/psa_microsoft_gameinput_service_can_cause_severe/) that the issue 34 reporter cited for a return of the stutter on Windows 11.
