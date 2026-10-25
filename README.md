# GameInput

Notes on a Windows GameInput service fault: high CPU in `WUDFHost` / `xinputhid.sys`, or frame-time spikes, while an XInput HID controller is connected. The service implementation is closed source. This repo records what the installed binaries actually do, which Windows builds that behavior covers, and what a fix has to change.

The current write-up is [docs/gameinput-service-fault.md](docs/gameinput-service-fault.md). Kernel analysis shows that request flags select **cached immediate state or queued completion**. A user-mode polling loop alone does not prove high CPU, rumble spam, or a Windows 11 regression. The tools here are designed to test that causal chain and collect comparable evidence.

## Use the tools

- **Collect a report:** follow [collecting diagnostics](docs/collecting-diagnostics.md), starting with `tools/collector/Collect-Diagnostics.cmd`. The collector uses Windows tracing and makes a local ZIP for you to review and share manually.
- **Research the exact calls:** follow [the probe and workaround instructions](docs/workaround.md). Build with `tools/build/build.ps1`, fetch the checksum-pinned Injector with `tools/dependencies/Get-ResearchDependencies.ps1`, then use `tools/probe/Invoke-GameInputResearch.ps1`. Observation is the default; throttle mode is an explicit, bounded experiment.
- **Check the evidence:** see [kernel dispatch analysis](docs/kernel-xinputhid.md), [version matrix](docs/version-matrix.md), and [implementation/test status](docs/implementation-status.md).
- **End-user release:** [the supported helper design](docs/supported-tool-design.md) describes the release gates. A signed one-click workaround is gated on real controller validation; this repository is a research prototype.

Traces can reveal device identifiers, user paths, and other applications' activity. Read the collection notice before sharing. Raw captures, symbols, downloaded tools, and local builds are ignored by git. No tool uploads data automatically.

## Credits

Analysis tools:

- [REA](https://github.com/morluto/rea) (`rea-agents` 6.8.0), connected to Cursor as the local MCP server and used to open the binaries, recover strings, and decompile with Ghidra. Install notes: [rea.tools/get-started](https://rea.tools/get-started/).
- [Ghidra](https://ghidra-sre.org/) 12.1.3, the provider REA used for `GameInput.dll` and `GameInputRedist.dll`.
- [Microsoft public symbol server](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/microsoft-public-symbols) and [dbh.exe](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/dbh) from the Windows SDK, used to read the inbox `GameInput.pdb`.
- [Microsoft Detours](https://github.com/microsoft/Detours), pinned to the v4.0.1 commit, for the research API hooks.
- [Nefarius Injector](https://github.com/nefarius/Injector/releases/tag/v1.5.0) v1.5.0, for loading the probe into allowlisted GameInput processes. Its release archive is verified with the published SHA-256 before extraction.
- [Windows Performance Recorder](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/windows-performance-recorder) and [Windows Performance Analyzer](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/windows-performance-analyzer), for CPU stacks and ETW correlation; [DeviceIoControl](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-deviceiocontrol) and [GetOverlappedResult](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-getoverlappedresult), for completion semantics.
- [Visual Studio](https://visualstudio.microsoft.com/), [CMake](https://cmake.org/), [PowerShell](https://github.com/PowerShell/PowerShell), [Python](https://www.python.org/), and [Git](https://git-scm.com/), for building, collection, evidence analysis, and version control.

Third-party license texts and dependency pins are in [third_party/NOTICES.txt](third_party/NOTICES.txt).

Reports and upstream projects:

- [DsHidMini issue 438](https://github.com/nefarius/DsHidMini/issues/438), including the `xinputhid.sys` rumble-off trace. Driver project: [nefarius/DsHidMini](https://github.com/nefarius/DsHidMini). Trace instructions: [Debugging the Drivers](https://docs.nefarius.at/projects/DsHidMini/v3/Debugging-the-drivers/).
- [GameInput issue 34](https://github.com/microsoftconnect/GameInput/issues/34) and the [GameInput releases](https://github.com/microsoftconnect/GameInput/releases), including [v3.3.195.0](https://github.com/microsoftconnect/GameInput/releases/tag/v3.3.195.0). Upstream repo: [microsoftconnect/GameInput](https://github.com/microsoftconnect/GameInput).
- [PCMR report](https://www.reddit.com/r/pcmasterrace/comments/1xee4qw/psa_microsoft_gameinput_service_can_cause_severe/) that the issue 34 reporter cited for a return of the stutter on Windows 11.
