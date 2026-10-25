# GameInput

Notes on a Windows GameInput service fault: high CPU in `WUDFHost` / `xinputhid.sys`, or frame-time spikes, while an XInput HID controller is connected. The service implementation is closed source. This repo records what the installed binaries actually do, which Windows builds that behavior covers, and what a fix has to change.

The current write-up is [docs/gameinput-service-fault.md](docs/gameinput-service-fault.md). It is static analysis of the copies on one Windows 11 25H2 machine (inbox GameInput 0.2309.26100.9278 and redistributable 3.5.270.0). A live controller trace is still outstanding.

Both pollers resubmit `IOCTL_XINPUT_GET_UNFILTERED_GAMEPAD_STATE` (`0x8000e388`) for as long as the device is present. The redistributable waits 1 ms between successes. The inbox `XusbWatcher` waits 100 ms only when that read fails. A Windows 10 quirk (builds through 21999) sets a flag on the request and does not slow the loop. Windows 11 leaves the flag clear.

## Credits

Analysis tools:

- [REA](https://github.com/morluto/rea) (`rea-agents` 6.8.0), connected to Cursor as the local MCP server and used to open the binaries, recover strings, and decompile with Ghidra. Install notes: [rea.tools/get-started](https://rea.tools/get-started/).
- [Ghidra](https://ghidra-sre.org/) 12.1.3, the provider REA used for `GameInput.dll` and `GameInputRedist.dll`.
- [Microsoft public symbol server](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/microsoft-public-symbols) and [dbh.exe](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/dbh) from the Windows SDK, used to read the inbox `GameInput.pdb`.

Reports and upstream projects:

- [DsHidMini issue 438](https://github.com/nefarius/DsHidMini/issues/438), including the `xinputhid.sys` rumble-off trace. Driver project: [nefarius/DsHidMini](https://github.com/nefarius/DsHidMini). Trace instructions: [Debugging the Drivers](https://docs.nefarius.at/projects/DsHidMini/v3/Debugging-the-drivers/).
- [GameInput issue 34](https://github.com/microsoftconnect/GameInput/issues/34) and the [GameInput releases](https://github.com/microsoftconnect/GameInput/releases), including [v3.3.195.0](https://github.com/microsoftconnect/GameInput/releases/tag/v3.3.195.0). Upstream repo: [microsoftconnect/GameInput](https://github.com/microsoftconnect/GameInput).
- [PCMR report](https://www.reddit.com/r/pcmasterrace/comments/1xee4qw/psa_microsoft_gameinput_service_can_cause_severe/) that the issue 34 reporter cited for a return of the stutter on Windows 11.
