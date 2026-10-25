# GameInput service fault

Static findings from the installed binaries on this machine, matched to public reports. No live controller reproduction was done in this pass.

## Reports

- [nefarius/DsHidMini#438](https://github.com/nefarius/DsHidMini/issues/438), closed as an external component. Windows 10 22H2. After a controller is connected in XInput HID mode, `WUDFHost.exe` and `xinputhid.sys` climb in CPU and games stutter. SXS mode does not. Unplug or killing `WUDFHost` clears it until the device returns. Nefarius traced repeated rumble-off packets from `xinputhid.sys` into DsHidMini, which completes them immediately and so does not throttle the caller.
- [microsoftconnect/GameInput#34](https://github.com/microsoftconnect/GameInput/issues/34). Disabling GameInput Service stops FPS drops reported in games such as Gears Reloaded, Marathon (2026), and Battlefield 6. On 2026-07-23 Microsoft said this was a compatibility issue with older Windows 10, fixed in newer GameInput, and named neither the fault, the Windows builds, nor the package versions. On 2026-10-25 the reporter pointed at a new Windows 11 report and said the stutter is likely back.
- The PCMR thread cited there could not be fetched (Reddit challenge page).

Public release notes never name this bug. Closest lines:

- v2.2: rumble became unresponsive on some devices under load.
- v3.0: performance regression for Xbox One controllers on Windows 10.
- v3.3.195.0 (2026-04-24): "stability and performance" only.

## This machine

Windows 11 25H2, build 26200.9457 (`Win32_OperatingSystem` caption: Microsoft Windows 11 Business). Both services were running.

| Component | Path | Version | Dated |
| --- | --- | --- | --- |
| GameInput Service (`GameInputSvc`) | `C:\Windows\System32\GameInputSvc.exe` | 0.2309.26100.9278 | 2026-09-09 |
| Inbox API / service logic | `C:\Windows\System32\GameInput.dll` | 0.2309.26100.9278 | 2026-09-09 |
| GameInput Redist Service | `C:\Program Files\Microsoft GameInput\x64\GameInputRedistService.exe` | 3.5.270.0 | 2026-08-31 |
| Redistributable logic | `C:\Program Files\Microsoft GameInput\x64\GameInputRedist.dll` | 3.5.270.0 | 2026-08-31 |
| `xinputhid.sys` | `C:\Windows\System32\drivers\xinputhid.sys` | 10.0.26100.9278 | same stamp as inbox GameInput |

`GameInputSvc.exe` is a small host. It references both `GameInput.dll` and `GameInputRedist.dll`, plus `RedistDir`, `CopyFileW`, `VerifyVersionInfoW`, and the string `GameInputService watchdog runaway`. The redistributable is newer than the last public GitHub release (v3.3.195.0) and its PDB is not on the public symbol server. Inbox `GameInput.pdb` (`B2F221BEF567C87A783089F3FE8B3C51`, age 1) loaded and supplied private names.

SHA-256:

- `GameInput.dll`: `f9f5adbde4a2883b9b307bb1848a120094904578d92b21100828bd83f7b77cb6`
- `GameInputRedist.dll`: `6d3650dbeea5f8c639972537dbaed3f2bb465561e63d34fa9661902f24cb9686`

## Mechanism

While an XInput HID controller is connected, GameInput repeatedly submits `IOCTL 0x8000e388` (`IOCTL_XINPUT_GET_UNFILTERED_GAMEPAD_STATE`, 0x18-byte state) into `xinputhid.sys`. That driver is the XInput filter on HID, which is why DsHidMini XInput mode is affected and SXS mode is not.

### Redistributable, version 3.5.270.0

`GameInput::Backend::XInput::Device::ThreadProcSystem` in `BeXInputDevice.cpp` (`FUN_1800519ec`):

1. Submit `IOCTL 0x8000e388`.
2. If the packet number changed, publish the reading.
3. `WaitForSingleObject` for 1 ms.
4. Repeat until the stop event is signaled (`E_ABORT` / `0x80004004` ends the thread).

`GameInput::Common` `Driver.cpp` (`FUN_180060468`) waits until the IOCTL completes. `ERROR_IO_PENDING` waits on the overlapped event. The caller's wait timeout word is `0xFFFFFFFF` (infinite). A 100 ms sleep is used only between failed attempts, and only up to 3 retries (`local_4c = 3`, `local_48 = 100`). A successful immediate completion never takes that delay, so a driver that returns the current state instead of pending until a change is polled at about 1000 requests per second.

`FUN_1800557a0` / `FUN_180064fa8` is the version gate. `RtlGetVersion` with `dwOSVersionInfoSize = 0x11C`. The inner check returns true when `dwMajorVersion > 10`, or `dwMajorVersion == 10` and `dwBuildNumber > 21999`. The quirk helper returns the inverse. The IOCTL flag byte is therefore set, and the log line `Quirking for IOCTL_XINPUT_GET_UNFILTERED_GAMEPAD_STATE` is emitted, on Windows 10 (builds through 21999, including 22H2). Windows 11 (build 22000 and later) leaves the flag clear. The 1 ms loop is not inside that check.

### Inbox `GameInput.dll` 0.2309.26100.9278

`XusbWatcher::WorkerThread` (`FUN_180042e98`) polls the same unfiltered state. The 100 ms relative delay (`NtDelayExecution`, interval `0xFFFFFFFFFFF0BDC0` = 100 ms in 100 ns units) runs only when the device index cannot be resolved or the completed transfer is not 0x18 bytes. An unchanged successful 0x18-byte state is followed by another request with no delay. If the driver completes immediately, this is a tight spin rather than a 1 ms poll.

`HidForceFeedbackScheduler::WorkerThread` (`FUN_180022678`) calls `timeBeginPeriod(1)` around each scheduled sample. The wait timeout is the time until the next sample divided by 1000. A sample that is already due becomes a 0 ms wait, and the thread loops. A generation change calls `HidForceFeedbackDriver::Reset` (`FUN_18001a570`). This is a separate stutter path: a process-wide 1 ms timer plus repeated HID force-feedback resets.

`GipQuiesceWatcher` (`FUN_18001a21c`, called from `WaitForQuiesce` at `FUN_180022438`): IOCTL `0x40001dc0`. `ERROR_IO_PENDING` (`0x3E5`) is the expected arm. A synchronous success logs `GIP quiesce notification completed immediately, retrying` and retries with no sleep, at most 50 times, then returns `0x8000FFFF`. That is a burst, not the sustained poll.

`FeedbackManagerState.cpp` (`FUN_180014ed8`) logs `Legacy GIP equation manager IS allowed` or `NOT allowed` from a device id/firmware table (`DAT_180054bd8`) and a flag at object offset `0xAB`. That gate is per device, not per OS build.

## What is still open

- No live trace yet of `IOCTL 0x8000e388` rate, pending-IRP count, or `xinputhid` completing immediately versus waiting for a packet change.
- `xinputhid.sys` was not decompiled. Nefarius's rumble-off reading is his ETW observation of the upper driver; this pass shows the GameInput poll that feeds that driver. Strings in `xinputhid.sys` include `exclusive focus` and `focus change` only.
- Which of the two services a given report disabled is not always stated. "GameInput Service" is the inbox display name. The redist service is a second poller and was running here too.
- The Win10 quirk flag's effect inside `xinputhid` is not known. It does not slow the user-mode loop, and it is off on Windows 11.

## Fix direction

Stopping GameInput Service removes the inbox `XusbWatcher` spin. Stopping GameInput Redist Service removes `ThreadProcSystem`. Games that require GameInput, Minecraft among those reported, then lose the API.

The code change is to not resubmit `IOCTL 0x8000e388` when it completes with the same packet. Wait for a state change, or use the 100 ms backoff the failure path already has. `XusbWatcher::WorkerThread` needs that on the unchanged-state path. `ThreadProcSystem` needs more than 1 ms when the driver completes immediately. The Windows 10 quirk byte does not cover Windows 11.

`HidForceFeedbackScheduler` should not call `timeBeginPeriod(1)` for a sample that is already due. `GipQuiesceWatcher` should back off when `0x40001dc0` completes synchronously.
