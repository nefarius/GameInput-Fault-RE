# Workaround status and reproducible validation

**There is no supported one-click workaround.** The signed installer/helper is
[design only](supported-tool-design.md). Collection is available for research;
probe attachment and throttling are experimental and must not be presented as
a proven fix. Neither static loops nor a connected controller establish that
this PC has the reported fault.

The local USB active-input test recorded 2,014 matching calls over 44.75 seconds,
all returning pending, with no immediate unchanged successes to throttle. The
research hook's throttle was therefore not enabled on this hardware. See the
[reviewed USB evidence](../evidence/runtime/active-input-summary.json). Synthetic
tests demonstrate that the throttle reduces a constructed flood; they do not
establish that it fixes the reported service fault.

Build the probe **before** attaching it. A started research DLL is pinned for the
target process lifetime; Disable stops/detaches hooks but does not unload it.
Rebuilding the DLL at that same output path while it is mapped can fail. A
controller refuses to dispatch remote calls into a different loaded build.
Do not replace or forcibly unload a mapped probe to evade that check.

## Start with diagnostics

Use `tools/collector/Collect-Diagnostics.cmd` for the interactive collector.
Read its consent notice before collection. Describe the controller model,
connection, game/version, power configuration, rumble state and exact symptom.
First collect without a workaround. Keep both service states as observed; the
default diagnostic workflow does not stop services or change drivers.

The ZIP can contain system-wide activity, file/user paths and identifying
device-instance information. Review it locally before sharing; no automatic
upload is requested. Keep raw ETL/JSONL locally under ignored `captures/` or
`artifacts/`; commit only reviewed small summaries without serial/instance IDs.
Hashes provide integrity, not anonymization.

For a bounded single symptomatic trace from an administrator x64 PowerShell terminal,
the existing collector supports:

```powershell
./tools/collector/Collect-Diagnostics.ps1 -Consent -Phases symptom -PhaseSeconds 5 -Controller 'Xbox One' -Connection USB -WorkaroundState 'original service settings; no experimental workaround'
```

`-Consent` accepts the script's displayed privacy notice; omit it to use the
interactive consent prompt. Supply the actual controller and connection rather
than copying those labels onto a different test. Check trace/provider failures,
loss counters and symbol coverage. A quiet trace does not rule out an intermittent symptom; check retained timestamp coverage before interpreting it.

The [agent-collected local baseline summary](../evidence/runtime/baseline-summary.json)
records a WPR trace on 2026-10-25 from 13:27:02.3199842 through
13:27:13.9125084 UTC, measured 11.5925242 seconds, with zero lost buffers/events
reported by xperf. The sampled `GameInputSvc` PID 6128 row printed Weight
`2000` (units unverified) and usage `0.00%` (rounded, not zero execution);
redist/WUDFHost/xinputhid had no reported profile rows. No symptomatic
game/frame-time reproduction was requested. Sampling absence does not establish
inactivity or absence of a fault, and this short trace is not a qualifying
30-second A/B window. The first probe startup returned access denied before
creating its handshake mapping and produced no valid IOCTL measurements.
Successful collection does not establish IOCTL or mitigation proof.

The user also observed an Xbox USB base device using `dc1-controller`
10.0.26100.9444 with `xboxgip`, and an XINPUT-compatible HID child using
10.0.26100.9278 with `xinputhid`. This makes the child relevant to investigate;
it does not associate any particular GameInput handle/request with that child.
No serial-bearing instance IDs are retained here.

## Research runtime phases

Use equal measured windows, initially 60 seconds after a 10-second settling
period, and retain a timestamped phase log. Record OS/module/driver hashes,
every eligible PID and creation time, loaded module path, controller/firmware,
connection, active game/test workload, power plan and provider availability.
Keep configuration fixed across each pair. Compare the same implementation
and workload; account for both inbox and redist processes and session respawns.

1. **Disconnected:** no controller; measure background activity and service
   state. This supplies a negative control, not an idle baseline denominator.
2. **Connected idle:** hands off, rumble off. Determine whether the specific
   IOCTL actually shows a pathological unchanged rate. If it queues normally or
   no symptom occurs, report that condition as not reproduced. Do not force a
   90% reduction claim from a zero baseline.
3. **Active input:** use a recorded button/stick/trigger sequence with an
   independent transition/timing reference. Human impressions and a slow poll
   script cannot establish that every transition was delivered.
4. **Rumble:** deliberately request start, amplitude changes and stop, then
   verify output and input together. An accepted API request is not proof a
   motor responded. Log the stimulus and observed response separately.
5. **Observe probe:** repeat the same phases in strict pass-through mode and
   measure its overhead against the no-probe trace. QPC, counters, locks and ETW
   add overhead even though Observe adds no intentional throttle delay.
6. **Reconnect and shutdown:** repeat disconnect/reconnect, session/process
   respawn and graceful shutdown with capture markers; record failures and
   recovery before any release gate is considered complete.

Correlate request PID/module, handle and actual device stack, input byte 3,
result/transfer size, unchanged bytes and call latency with WPR CPU stacks and
WDF request start/completion. Preserve ETW provider configuration and lost-event
statistics. A synchronous TRUE return can follow a blocking wait; use call
timing rather than equating TRUE with immediate kernel completion.

The probe never reads caller input before the original API or on a pending/error
return. Its `input_flag3` field, when valid, is a **post-success snapshot** of
readable input; it cannot prove the originally submitted byte if another thread
changes that memory. Pending requests have no captured flag or output contents.
Their measured latency is API-return latency, not full pending-I/O lifetime.
Use additional kernel/completion evidence where those distinctions matter.

On the inspected Windows 11 driver, flag-clear state requests can queue until
decoded state changes. The later [Windows 10 investigation](windows10-queue-identity.md)
found a missing PID initialization in queue creation, with live consequences
still unvalidated. Repeated rumble-off traffic was an assumption from one GitHub
issue ETL, not an observed packet sequence. Establish whether such traffic occurs
before testing a causal link to state requests; correlate lower output writes,
set-state IOCTLs, focus changes and force-feedback/timer activity separately.
CPU, frame time, input and rumble are distinct observations.

## Controlled A/B experiments

Only attempt mitigation after Observe evidence establishes a pathological
unchanged-success interval for the exact target. The research wrapper discovers
and validates every eligible GameInput PID; it takes no arbitrary process/DLL
argument. Dependencies/builds and administrator access must be ready first.
An attach/preflight/handshake failure blocks the experiment and must be retained
as a failed run, not analyzed as a zero-rate improvement.

For a validated research session, the wrapper exposes the following bounded
sequence; each command prints its own `research.jsonl` directory:

```powershell
./tools/probe/Invoke-GameInputResearch.ps1 -Action List
./tools/probe/Invoke-GameInputResearch.ps1 -Action Attach -DurationSeconds 60 -Phase idle
./tools/probe/Invoke-GameInputResearch.ps1 -Action Mitigate -DurationSeconds 60 -Phase idle
./tools/probe/Invoke-GameInputResearch.ps1 -Action Attach -DurationSeconds 60 -Phase idle
```

Attach selects Observe. Each bounded Attach/Mitigate session ends with a stop
attempt; a later session must successfully restart/revalidate before collecting.
The wrapper can reuse the pinned module rather than loading another copy.
Do not remove the DLL from a live process. `Disable` detaches where safe and
retains the module until process exit; `Eject` is refused. If cleanup reports
busy/failure, inspect status and follow the research recovery instructions;
do not treat a timeout or a killed wrapper as proof of successful detach.

Record no-probe, Observe A, throttle B, and Observe A-again windows. Repeat at
least three pairs and alternate order to expose drift/overhead; summarize every
trial rather than selecting the best. Collect simultaneous WPR evidence and
use [native conversion and comparison](version-matrix.md#native-captures-and-analysis-contract)
separately for each implementation/PID and each pair. A process restart splits
a capture; both-side binary/context identity must still match.

The numeric rate criterion is **at least 90%** reduction in pathological
unchanged requests, with corresponding CPU or externally demonstrated frame-time
improvement. The Python report implements the CPU option only. Baseline zero,
unbalanced counters, state-table drops, mismatched context or too-short windows
cannot pass. Sampling once per second is adequate for counter rates; it does
not establish individual input timings. Test inbox and redist independently
in explicitly documented controlled configurations and together. Default
collection does not disable services to manufacture isolation.

Initial research pacing requests 8 ms (nominal 125 Hz for unchanged results);
**8 ms is not a maximum actual delay or input-latency guarantee**. A native
development check reported an 8 ms Sleep request taking **17.2735 ms**; timing
improvements were still being developed. This is not a controller latency
measurement or a passed safety gate. Measure actual delay distributions,
scheduling overshoot and end-to-end transition latency under load, power changes
and reconnect. Any added latency exceeding the declared acceptance cap fails
that gate; an unknown maximum leaves it pending. Changed packets, pending calls
and errors must preserve their original results and buffers, but synthetic
pass-through tests alone cannot verify physical input or rumble.

A numerical report always leaves input transitions, latency, rumble, reconnect,
crashes, shutdown and causal correlation unassessed. These need separately
reviewed evidence. No experimental success here enables a supported installer.
Stopping GameInput services is not the validation mechanism: games may depend
on those services. A permanent correction belongs in the upstream caller/driver
behavior demonstrated by the evidence.
