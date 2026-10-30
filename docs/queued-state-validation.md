# Queued-state completion follow-up

Prepared 2026-10-30 after the [raw/public input comparison](dshidmini-idle-completions.md).
That recording explains sampled stick changes consistent with raw variation
surviving the saved dead zone, but does not measure queued completions.

## Current baseline

Host WinDbg MCP inspection reconfirmed the loaded xinputhid image at
`fffff80439160000`, timestamp `8622933a`, image size `0x17000`, checksum `0xf5de`,
and the same xinputhid-over-mshidumdf device stack. No breakpoint rows were
returned. The bounded list walk (cap 4096) reached the list head with **587
entries**, the same count as the earlier post-service walk. These are list
entries, not a count of examined request objects. The cached 18-byte decoded
state was `808080808080808000000000000000000000`. This is a paused snapshot,
not an uninterrupted allocation-rate measurement. The guest was resumed.

The identified guest remains Windows 10 22H2 19045.5796, physical PS3 USB via
DsHidMini 3.27.0.2500 in XInput mode. The last inventory established Stopped/Manual
GameInputSvc. The new script requires that baseline and the driver SHA-256
`c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f`.
It also requires one present research XInput interface and pins its interface
enumeration helper. A backing-file check is distinct from the loaded-image
and device-stack verification above.

## Test client

`tools/runtime/Measure-XInputQueuedState.ps1` is a dedicated native x64 Windows
PowerShell client. It opens the identified interface shared read/write with
overlapped I/O and submits only state IOCTL `0x8000e388`, four input bytes
`03 01 00 00`, and a 24-byte output buffer. The observed layout and zero-byte-3
queued path are supported by the byte-checked Windows 10 handler export in
[queue-identity evidence](windows10-queue-identity.md). It sends no vibration
or configuration commands and changes no service/driver settings.

At most one request is outstanding. The requested phases remain 20 seconds
untouched, 5 seconds moving only the left stick, then 10 seconds untouched.
The operator reports what actually happened. Recording stops at 35 seconds
or 1024 submissions; an early cap means the full phase protocol was not run.
No intentional resubmission sleep is inserted. Event waits are at most 20 ms,
so successful completion timestamps represent observation time rather than
exact kernel completion time. Native dispatch/close calls have no hard timeout.

Each row records request submission and API-return QPC, initial return/error,
observed completion QPC, final success/error, transfer length and all 24 output
bytes **only on successful exact-length completion**. Pending/error/short
responses have no output inspection. Preserve the original packet word and
all payload bytes; compare payload fields explicitly when analyzing repeats.
An initial `ERROR_IO_PENDING` counter is not a completion counter or an I/O
lifetime measurement by itself.

At the deadline the client calls `CancelIoEx` for its own handle/OVERLAPPED,
then allows up to five seconds for observed completion. It does not cancel
other requests. An unconfirmed cancellation or exception while I/O remains
active sets `CleanupPending` and retains the native buffers, event and device
handle until this dedicated process exits. A cancellation request or successful
`CancelIoEx` is not reported as completed cleanup. The normal path reaps the
request before freeing storage and times the device-handle close separately.

The capture is published before the operator report and final service check.
The child process then waits at a prompt so a paused debugger can inspect the
queue population before process exit. Do not close the child until that snapshot
is retained. Metadata records its PID, exact device path, script hashes and
commands/limits; keep these private under ignored captures.

Synthetic tests exercise immediate and pending success, submission failure,
short output, confirmed cancellation, unconfirmed cancellation, failed device
close and an exception
with active I/O. They test no controller or driver. Compilation and synthetic
results do not establish live completion behavior. No hardware run with this
new client was claimed from preparation alone. The actual run follows.

## Uncorrected existing-device recording

The operator ran the prepared client and reported **"all as instructed"**.
The [completion summary](../evidence/runtime/vm-queued-state-completions-20261030.json)
retains the run identities and hashes of the original private capture, ready,
operator and after records. GameInputSvc was Stopped/Manual at both endpoint
checks. No PID correction, service change, vibration or controller configuration
change was performed. This recorder did not rehash the controller configuration,
and endpoint checks are not continuous service monitoring.
The [exact issued client source](../evidence/runtime/issued/Measure-XInputQueuedState-20261030.ps1)
is retained byte-for-byte (SHA-256
`9e9d32a4164f970ef63addd14053a863b291e4cf628f72873305397d1caf8a3f`)
for both uncorrected recordings. The current tool additionally supports the
separately gated priming candidate; its source hash differs.

Over **35.0105232 seconds**, it submitted **355** requests. Every initial API
return was `ERROR_IO_PENDING`. It subsequently observed **354 successful
24-byte completions**, with no output-access-contract violation, and reaped
the last request as `ERROR_OPERATION_ABORTED` after its deadline cancellation.
The device handle closed successfully in **0.4928 ms**. Request/storage cleanup
was confirmed; no cleanup remained pending. These are real completion results,
not counts inferred from the initial return value.

Across the **353 adjacent successful pairs**, no complete reply repeated and
no reply payload repeated after excluding the packet word. The packet word
advanced by one each time, from 17487 to 17840. Apart from packet bytes 0/1,
only output bytes **10–13** changed, corresponding to the left-stick fields
observed in the earlier state analysis. Full 24-byte replies remain private.
Comparisons do not establish input fidelity or independently decode every
private field.

By observed completion time in nominal windows, 10 successes fell in 0–20 s,
344 in 20–25 s, and none in 25–35 s. Phase cues occurred at approximately
0.0004, 20.0259 and 25.0098 s; these requested windows are not instrumented
physical-action timestamps. The final request began at 24.4205441 s and
remained outstanding until observed cancellation about **10.5899724 s** later.
This client did not reproduce an immediate unchanged-response flood. Its wait
granularity, missed intermediate states and observer work preclude treating
completion-observation intervals as exact hardware timing or the service's rate.

The [bounded population snapshots](../evidence/runtime/vm-queued-state-queue-population-20261030.json)
found **587 entries before and 942 after**, an aggregate increase of **355**
matching the 355 submissions, including the cancelled request. The post-capture
walk reached the head below its 4096 cap, while the test process was still
present. None of the 942 stored PID fields matched the test PID. After the
operator exited that child normally, a further complete walk still found
**942**, and the child was absent from the PowerShell process listing. The
guest was resumed after each paused inspection.

This supports repeated node creation and retention on the affected queued
path even though observed successful payloads changed. It does not provide a
per-request allocation trace, inspect every associated WDF queue or establish
that no unrelated activity occurred between snapshots. The exact aggregate
match is consistent with the missing-PID mechanism rather than proof that every
node was directly traced to its allocating call.

Reproduce the completion summary with
`tools/analysis/summarize_queued_state.py <private-capture.json> <new-summary.json>`.
The analyzer separates submission and observed-completion windows, cancellation,
failed/short replies, packet wrap and payload equality. Regression tests include
cross-phase requests and refuse to count error output as successful data.
The raw debugger transcripts and all capture files remain ignored/private.

## Interpretation and next comparison

### Fresh uncorrected control

After an operator disconnect, `xinputhid.sys` was absent from the refreshed
module list. Reconnect produced a new driver base and device context with a
self-linked list head and **zero entries**. The same issued reader (SHA-256
`9e9d32a4164f970ef63addd14053a863b291e4cf628f72873305397d1caf8a3f`)
then recorded **483 submissions and 483 successful 24-byte completions** over
**35.004256 s**. All initial returns were pending. No cancellation was needed:
the final request completed at the end of the budget. Cleanup and handle close
were successful, with no remaining pending cleanup. The operator reported
**"as instructed"**, and service endpoint checks remained Stopped/Manual.
See the [fresh completion summary](../evidence/runtime/vm-queued-state-fresh-uncorrected-20261030.json).

None of the 482 adjacent successful payloads repeats after excluding the
packet word. Besides packet bytes and left-stick bytes 10–13, byte 8 changed
twice (`0 -> 0x16 -> 0`, observed around 23.974/23.984 s). Its decoded meaning
and physical cause are not established here; the operator report does not
prove the absence of all other physical input. By nominal observed-completion
windows, 0 successes fell in 0–20 s, 360 in 20–25 s and 123 in 25–35 s.
The phase labels remain requested actions, not direct physical measurement.

A complete post-recording list walk found **483 entries**, with no stored PID
matching the still-present test child. This reproduces aggregate one-entry-per-
submission growth from zero, rather than relying on the older 587-entry starting
population. It remains an aggregate comparison, not a per-allocation trace or
an enumeration of each WDF queue. See [fresh population evidence](../evidence/runtime/vm-queued-state-fresh-population-20261030.json).
After that snapshot the operator exited the child and unplugged the controller.
No exit-only population snapshot was taken for this fresh control; the earlier
existing-device run supplies the separate process-exit retention observation.

### Corrected-condition preparation

`-PreparePidComparison` adds a separate ARM gate and a maximum-one-request
priming operation before the normal READY gate. It saves `priming.json` and
refuses to start measurement if priming did not finish/reap/close cleanly. The
priming budget is nominally 0.5 s, with the same five-second cancellation reap
bound; debugger pauses make priming timing unsuitable for comparison. No
measurement cues are emitted during priming. A synthetic regression test
checks that it submits at most one request and leaves measurement cues empty.

The script does not apply a correction. The separately guarded debugger step
will verify the fresh driver/device and owned requestor, then initialize only
that allocated node's missing PID DWORD before publication, as in the earlier
mechanism PoC. Save original/new values and verify one linked node with the
test PID after priming. Keep the same process alive for the subsequent 35-second
measurement so its requests can find that queue. The reader rechecks the
Stopped/Manual service baseline immediately before the timed operation. Its
metadata labels this a comparison candidate requiring external verification,
not proof that a correction occurred. No corrected-condition result is claimed
from preparing the script or priming gate.

Retain the before/after bounded list counts, successful completion count and
full returned bytes. Separate observed repeats, cancelled/failed requests,
early termination and pending cleanup. This test adds consumer activity and can
create additional per-process queues on the affected driver; it does not measure
the service's natural request rate or demonstrate game FPS benefit.

First establish that byte-3-zero requests actually wait/complete on this device
and identify any equal-state successful responses. Then compare queue growth
with the request population. A later PID-corrected comparison requires a fresh,
identified device lifetime and a separate guarded correction step; it has not
been applied for this baseline. Preserve the controller configuration and account
for source-state variation, differing exposure and accidental PID matches.

## End-of-day handoff, 2026-10-30

The operator stopped work after reconnecting for corrected-condition preparation.
The driver module inventory was refreshed, but that new device's context and
initial population were **not yet verified**. No priming client was launched,
no correction was applied, and no corrected measurement was recorded in this
follow-up. The prior fresh-control addresses belong to the removed device and
must be reacquired before further inspection or any guarded correction.

The VM was resumed. Both temporary queued-tool/result shares were removed,
runtime sharing disabled, and configured share count verified at zero. The
original captures, primed candidate, failed-run record and debugger transcripts
remain intact under ignored local folders. The reviewed issued client source
is also retained publicly as literal evidence above.

To resume: confirm the guest/controller/service baseline, reacquire the loaded
driver/device identity and empty initial list, restore narrowly scoped temporary
transfers, then launch the primed candidate and stop at ARM. Verify the owned
process and build-specific allocation location before the one-node PID step.
Save the original/new DWORD, reap priming and verify the linked queue identity
before the separately gated timed run. The candidate is not a supported fix.
