# x86 XInput state-call comparison

The [metadata-only handle-close pairs](vm-queue-comparison.md) measured a
repeatable close-cost difference alongside uncorrected queue growth. They did
not run the game's actual x86 XInput API. This follow-up queries
`XInputGetState` through the exact contributor-hash x86 XInput1_4.dll in a
separate x86 PowerShell process. It does not inject into a game or GameInput.

Use the same offline Windows 10 research VM, PS3 USB controller in DsHidMini
XInput mode and existing service configuration. Keep the controller untouched
for the initial comparison. Record actual activity separately; a request for
hands-off input is not an observed idle guarantee.

## Workload and identities

`tools/runtime/Measure-XInputState.ps1` requires x86 PowerShell on x64 Windows.
It pins the xinputhid backing-file SHA-256 to
`c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f`
and x86 XInput1_4 to
`afcef57f5c6068cedb49ddb370a8d070867fd47fcc8a67fd11694053885dec8d`.
The driver is read through Sysnative to avoid x86 filesystem redirection. The
DLL is loaded by absolute SysWOW64 path with system-directory dependency
search; its reported loaded path must resolve to the same volume/file index
as the expected file in the x86 process's filesystem view, and its backing-file
hash is checked before
binding the exported function from that same local module. This is a normal
test-process DLL load, not a remote operation or modified driver installation.
Backing-file checks do not hash relocated module memory or prove current kernel
device/module identity; retain the independent debugger observations.

The first guest attempt stopped before binding/calling XInput because an
earlier path-string guard rejected reported `C:\Windows\System32\XInput1_4.dll`
versus requested `C:\Windows\SysWOW64\XInput1_4.dll`. The operator's x86 diagnostic
found the exact expected SHA-256 through both names. The revised guard compares
volume/file identities through metadata handles and retains the exact hash
checks; it does not simply strip directory names or accept equal basenames.
Regression tests accept the WOW64 alias, reject the native Sysnative DLL and
reject separate files even when their bytes match. See
[failed-attempt evidence](../evidence/runtime/vm-xinput-path-guard-refusal-20261029.json).
Microsoft documents [WOW64 redirection](https://learn.microsoft.com/en-us/windows/win32/winprog64/file-system-redirector)
and [volume/file-index comparison](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfileinformationbyhandle).
The failed attempt yielded no API latency samples; successful guest runs after
the guard repair are recorded below.

One warmup call per slot is retained separately. The timed loop then offers
up to **100 cycles of slots 0, 1, 2 and 3**, at most **400 timed calls**, with
a **five-second loop limit** and **10 ms sleep after each cycle**. Limits are
checked between calls; an individual blocked call has no hard timeout. Warmup
precedes the timed loop. Pacing is part of the benchmark and is not a proposed
driver workaround. The tool requests no vibration and changes no services.

Each sample retains cycle, slot, direct return code and QPC call duration. Only
successful calls retain the packet number; failures retain null. Microsoft
documents [ERROR_DEVICE_NOT_CONNECTED as an expected result for an absent slot](https://learn.microsoft.com/en-us/windows/win32/api/xinput/nf-xinput-xinputgetstate).
It must not be counted as a successful input reading or compared indiscriminately
with connected-slot timings. Unexpected errors stop the workload and preserve
the partial output. Group distributions by slot and return code, retain warmup
separately, and report any slot/status changes across conditions.

The DLL version string is recorded literally: its observed resource-version
discrepancy in the earlier guest inventory must not be silently resolved from
the hash. OS build/revision, architecture, PID, loaded DLL path, backing hashes,
script hash, actual call count/duration and post-run service inventory are saved.
Keep the output under ignored captures; review derived data before publication.

## Operator sequence

1. Mount the prepared XInput benchmark ISO. Preserve the controller connection,
   NIC-disconnected state and existing snapshot. The current device is the
   uncorrected repeat, with 2864 nodes at its last paused snapshot. That is not
   an exact count during later API calls.
2. After the debugger resumes without breakpoints, run this in the guest's
   PowerShell (adjust CD letter if needed):

```powershell
& "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File D:\Measure-XInputState.ps1 -Condition uncorrected -OutputPath C:\GameInputResearch\captures\xinput-x86-uncorrected.json
```

3. Copy the JSON to the host's ignored `captures/vm-queue-comparison/` directory.
   Keep the controller connected. Record post-run queue count and actual loaded
   identities; do not interrupt timed calls with debugger pauses.
4. For the corrected condition, use an operator-assisted fresh reconnect, verify
   an empty queue list, supply the missing PID on the first verified GameInput
   node, and verify publication/reuse. Use the same script, binary hashes,
   controller state, limits and x86 executable. Save under `corrected` to a new
   file; preserve failed and negative runs.
5. Compare state-call timings by slot and return code, queue counts and packet
   changes. If there is a difference, verify its enumeration/cleanup stack in
   a separate observation run before claiming the same bottleneck. Active
   input, vibration/recovery and game frame times remain additional work.

No result from this tool proves input fidelity, physical slot identity, a full
pending-I/O lifetime or a game FPS fix. Do not open supported-fix or release
gates from the microbenchmark alone.

## Uncorrected baseline, 2026-10-29

The [validated baseline](../evidence/runtime/vm-xinput-x86-uncorrected-20261029.json)
completed **400 timed calls in 2.892 seconds**, plus four separate warmup calls.
The guest reports build **19045.5796**. Exact driver, x86 DLL and revised script
hashes match, and the reported System32 module path passes the file-identity
comparison with SysWOW64. GameInputSvc was Running/Manual, PID 5708, in the
post-run inventory.

Slot 0 returned success in all 100 timed calls, with **16.45 microseconds median**
and **197.6 p95**. Slots 1, 2 and 3 returned ERROR_DEVICE_NOT_CONNECTED in all
100 calls each. Their respective medians were **2746.9, 2080.5 and 1834.45
microseconds**, with p95 **4846.3, 4311.1 and 3118.8**. These expected absent-slot
results are not successful readings or unexpected failures. Warmup is excluded
from these statistics and retained separately.

A bounded post-transfer walk found **at least 4096 queue nodes**. That snapshot
does not measure each call's queue population or attribute growth to this API
workload. Slot 0 exposed **51 distinct packet values** despite the hands-off
instruction; movement, device noise and fidelity were not independently
measured. Expensive absent-slot calls fit the inspected enumeration route, but
no corresponding per-call stack was captured. Corrected API timings, stack
verification and game frame-time effects were pending at this observation.

## Corrected comparison, 2026-10-29

The [validated pair](../evidence/runtime/vm-xinput-x86-pair-20261029.json)
matches OS build/revision, x86 architecture, expected/reported loaded DLL paths,
file identity, driver/DLL/script hashes and requested limits. Both runs completed
100 full cycles: 100 successes on slot 0 and 100 expected disconnected returns
on each of slots 1-3. Both post-run service inventories show GameInputSvc
Running/Manual, PID 5708. The corrected timed loop took **1.570 seconds** versus
2.892 uncorrected; warmup is excluded in both.

Disconnected-slot median call duration changed as follows:

- Slot 1: **2746.9 to 125.45 microseconds**, 21.90 times lower.
- Slot 2: **2080.5 to 47.35 microseconds**, 43.94 times lower.
- Slot 3: **1834.45 to 42.25 microseconds**, 43.42 times lower.

Their respective p95 values fell from 4846.3/4311.1/3118.8 to
299.5/140.5/90.3 microseconds. Connected slot 0 median changed from **16.45 to
11.0 microseconds**, p95 197.6 to 27.1. The corrected device still had exactly
**one queue node** after the benchmark and transfer, with its initialized PID
and original WDF queue handle intact. The uncorrected post-transfer snapshot
had at least 4096 nodes.

This extends the missing-PID/reuse/queue-growth/close-cost mechanism PoC to the
contributor-hash x86 XInput binary's actual API. It is one serial API pair,
with unequal device exposure, background activity and retired-device teardown
not fully controlled. The earlier reversed-order tests were handle-close tests,
not repeated x86 API pairs. Per-call enumeration/cleanup stacks and game frame
times still need separate observation. The corrected run's 39 packet values
versus 51 uncorrected occurred over different durations; those counts do not
establish lost input or fidelity. This is a narrow VM data correction, not an
installed or supported fix.
