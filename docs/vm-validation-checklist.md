# VM and WinDbg validation

Scope agreed on 2026-10-29: finish useful VM/debugger work without assuming a
game is installed. Use the existing offline Windows 10 19045.5796 guest,
contributor-hash xinputhid 10.0.19041.5794 and x86 XInput DLL, PS3 USB controller
in DsHidMini XInput mode, and the existing snapshot. Physical connection,
input and motor observations belong to the operator. Game frame times are
explicitly outside this phase. Do not claim full input fidelity or a supported
fix from the coarse checks below.

The [research environment and procedure](research-environment.md) records the
VMware Workstation/WinDbg MCP setup, verified tool versions, transfer methods,
operator roles and measurement controls used for this batch.

## Checklist

- [x] Missing PID initialization, repeated allocation and corrected-node reuse.
- [x] Metadata-only close-cost pair and reversed-order check.
- [x] First exact-DLL x86 XInput API pair with slot/return-code groups.
- [x] Separate observation of an absent-slot call reaching driver cleanup and
  the loaded WDF queue traversal, with actual requestor/file/device identity.
- [x] Fresh corrected-first and fresh uncorrected x86 API pair using the same
  runner process, limits, phase exposure and documented queue snapshots.
- [x] Coarse corrected input checks: neutral, held A/B/D-pad, trigger and stick
  positions, then neutral again; retain requested and actually reported actions.
- [x] Operator-triggered low-amplitude vibration start/stop with input queries
  during/after, and physical observation separated from API return status.
- [x] USB disconnect/reconnect behavior, slot statuses, old-device deletion
  state, and loss/reapplication of the lifetime-scoped correction.
- [x] Controlled inbox service stop/start recovery check with original startup
  configuration preserved and original running state restored. Document queue
  retention versus API cost rather than assuming service stop frees queues.
- [x] Review small derived evidence and remove temporary VM shares/runner.

The first x86 pair remains one serial comparison. Earlier reversed ordering
applied to handle closes, not x86 API tests. Fixed slot order, packet activity,
unequal exposure and incompletely observed retired-device state remain possible
confounds. The guest inbox is older than the contributor's 0.2309.19041.6456;
this phase does not silently change the OS, install drivers or reboot.

The [fresh corrected-first idle comparison](../evidence/runtime/vm-xinput-fresh-reversed-pair-20261029.json)
completed 400 calls per condition in the same runner, with matching identities
and limits. Host resume-to-command-file intervals were 241.98 and 242.53 seconds.
The unmodified list contained 48 nodes versus one corrected node, but API costs
were similar: slot medians corrected 18.15/181.8/80.25/54.9 microseconds and
uncorrected 18.5/177/81.25/50.35. This is a negative timing control at a modest
queue population, not a repeat of the high-queue performance effect. No matched
continuous movement was requested; older retained contexts remain a limitation.

The subsequent [30-second moving-stick window](../evidence/runtime/vm-active-input-growth-20261029.json)
recorded 1906 successful reads and 974 distinct left-stick position pairs.
The unmodified process list subsequently contained 3383 entries; absent-slot
medians increased to 773.15/518.95/489.45 microseconds, while slot 0 remained
15.2. The operator's action report was only "yes"; state variation is directly
recorded, but a fuller physical description was not supplied. Snapshots bracket
additional idle time, so their difference is not a precise allocation rate.
No fresh corrected counterpart received this same continuous movement workload.

The [corrected activity checks](../evidence/runtime/vm-input-vibration-20261029.json)
record 1028 successful held-input samples across eight windows. The operator
reported PS3 Cross, Circle, D-pad up, L2, positive left/right stick X, and neutral
at the requested phases; the corresponding XInput states were visible. The
left-stick phase also includes incidental left-trigger values up to 62. Both
motors were requested at 8192 for approximately 0.5 seconds; start/stop returned
success, all 64 during/after input queries succeeded, and the operator answered
yes to the physical start/stop observation. Individual motors, right trigger,
every input transition and physical latency were not separately verified.
The process queue list still contained exactly one entry afterward.

An [uninterrupted repeat](../evidence/runtime/vm-xinput-corrected-post-input-20261029.json)
then completed 400 calls with the expected slot status groups. Absent-slot
medians were 176.25, 56.55 and 46.45 microseconds. This reused corrected lifetime
does not replace the requested fresh reversed-order API comparison.

## Guest runner and temporary transfer

`Start-VMValidation.ps1` runs in x86 PowerShell and loads the exact approved
XInput backing file in its own process. The native script and runner hashes
are pinned at startup; changing source files refuses later cases until a fresh
process starts. The existing v2 ISO and its earlier source remain local for
reproduction; new runner measurements must match the new source hashes within
their own comparisons.

Temporary VMware shares:

- `GameInputTools`: read-only, dedicated host `artifacts/vm-validation-tools/`.
- `GameInputResults`: writable, dedicated host `captures/vm-validation-results/`.

They were added through vmrun and enabled for the current runtime, without
enabling the NIC. The operator launches the runner from the tools share once.
Results are private, including input axes, paths, PIDs and operator text. No
upload is performed. Only reviewed derived summaries belong in Git.

`Save-VMInventory.ps1` runs separately in administrator x64 PowerShell. It only
reads fixed Windows backing files, relevant loaded process modules and controller
driver inventory. Its [reviewed result](../evidence/runtime/vm-component-inventory-20261029.json)
identifies loaded DsHidMini 3.27.0.2500 and inbox GameInput 0.2309.19041.5794.
The WDF 1.31.19041.1 backing file matches the loaded timestamp, image size and
checksum observed during cleanup traversal; its SHA-256 is now recorded.
This is path/backing-file verification, not a full loaded-image memory hash.

The runner writes an immutable `session.ready.json` with its nonce, PID,
identities and initial slot observations. Host-authored commands must have the
matching nonce and safe case ID. Supported kinds are only `route`, `benchmark`,
`observe`, `input`, `rumble` and `stop`; arbitrary code/process/service commands
are not supported. Commands and immutable started/result records are published
atomically. There are at most 64 accepted cases and a default 45-minute session
limit (maximum 90). Limits are checked between cases; operator prompts and
individual API calls have no hard timeout. The issued capture runner checked
limits at batch boundaries; the repository runner additionally checks each case
so a prequeued batch cannot exceed 64 accepted commands. Recorded captures used
only fifteen and seven cases; their original source hashes remain in the evidence.

`route` calls one selected slot and is explicitly ineligible for timing claims.
Use process-scoped, bounded breakpoints; preserve IRP major function, requestor,
file/device routing and user/kernel stacks where available. A breakpoint in
inlined WDF code must be checked against its actual loaded instructions.

The [first route observation](../evidence/runtime/vm-xinput-cleanup-route-20261029.json)
now confirms IRP_MJ_CLEANUP from the runner's slot-1 call through NtClose,
xinputhid preprocess and the actual loaded WDF cleanup traversal. The six
WDF queues include the one corrected per-process manual queue; its visit was
observed in the next-queue inline copy. The WOW64 user unwind failed and remains
an explicit limitation; debugger-paused call ticks are not timing samples.

`benchmark` uses the existing bounded state workload (at most 100 cycles and
five seconds, four slots per cycle). Leave no breakpoints interrupting measured
calls. `completed` describes runner procedure completion, not a passed hardware
test; review return codes, counts and identities independently.

Input cases prompt the operator before bounded sample windows and retain their
report afterward. This checks held-state visibility, not every transient or
physical-to-API latency. The vibration case prompts before requesting 8192 on
each motor by default (bounded to 0-16384) for approximately 0.5 seconds, queries input concurrently and
requests zero in `finally`. A failed stop is retained for a bounded cleanup
retry at session end. An accepted stop is not physical proof; record the
operator's observation. Avoid debugger pauses during vibration. Forced process
termination/guest suspension cannot guarantee cleanup or a hard motor timeout.

End with a `stop` case and inspect `session.ended.json`, including failed motor
stop attempts. Then remove only these two named shares and disable their
runtime sharing; preserve all result directories. Do not reset unrelated VM
settings or delete the operator's snapshots.

## Controlled service recovery

Use `Invoke-VMServiceRecovery.ps1` only in the prepared guest, from the separate
administrator x64 window. It refuses a different OS/driver identity or an inbox
service other than Running/Manual. After the operator types READY, it stops only
`GameInputSvc`, records the stopped state and remaining GameInput processes, and
waits for a matching session-specific `resume.request.json`. The default maximum
wait is ten minutes (parameter cap fifteen), then restoration runs automatically.
No startup configuration is changed. Measure only after `stopped.ready.json`
exists, then publish the matching resume request and inspect `ended.json`.
Do not assume stopping the SCM parent terminates the per-user worker or releases
the old queues; inspect those facts independently.

The helper restores Running in `finally`, verifies the original startup type and
records/throws on restoration failure. Keep its window open: forced termination,
native-call blockage or guest suspension cannot guarantee timely restoration.
Synthetic service tests cover successful restoration, failed stop, failed
restoration, rejection of the wrong resume nonce, and refusal before any service
change for a wrong driver identity.

The [service recovery result](../evidence/runtime/vm-service-recovery-20261029.json)
confirms that stopping the inbox service terminated both observed GameInput
processes, but the complete queue count remained 3383. The first original manual
queue still existed with no waiting or driver-owned requests; other queues were
not individually inspected. All 400 API calls completed with expected slot
statuses; absent-slot medians remained 1018.65/546.5/469.85 microseconds.
Restoration succeeded without changing Manual startup. A new parent/worker pair
was observed, queue count was 3384, and API medians remained elevated at
749.25/509/491.65. Stopping production does not remove this observed accumulated
device-lifetime population or recover its earlier low API costs.

Both runner sessions ended on explicit stop commands (fifteen and seven cases),
with no fatal errors or outstanding motor-stop attempts. The guest was left
running with no experiment breakpoints and the service restored to Running/Manual.
The two temporary shares were removed through vmrun, runtime sharing disabled,
and configured share count verified as zero. VMware retained inactive cached
VMX slot records beyond that zero count; no manual live VMX edit was attempted.
All raw results and issued source copies remain private and intact. The issued
active-input helper accepted only the LF source hash; the repository helper also
accepts the equivalent CRLF checkout hash and still records the actual raw hash.

The [first reconnect observation](../evidence/runtime/vm-reconnect-progress-20261029.json)
records all four slots disconnected, followed by slot 0 returning after USB
reconnect. The old device remained DeletePendingCloses with one WDF file object
and two underlying handles; their owner was not found in the three inspected
processes. A fresh context began with an empty process list and a stale PID field.
Repeating the single-entry correction survived publication and restored exact
node reuse. Complete retired-device teardown remains unestablished. The fresh
API comparison and service recovery are separate later observations above;
reconnect success alone does not establish their results.
