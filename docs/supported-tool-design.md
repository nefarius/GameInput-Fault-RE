# Signed GameInput helper — conditional design only

**Unsupported. No helper or installer is implemented or approved by this
document.** [supported-tool-gates.json](../data/supported-tool-gates.json) has
no enabled compatibility entries and every release gate is unvalidated. Its
[schema](../data/supported-tool-gates.schema.json) deliberately forbids enabling
a supported release. This document is a contingent design for review after
real prototype validation; it does not graduate the research wrapper.

## Prerequisites for design approval and implementation

Reviewers must retain exact target identities, test protocol, raw-evidence
hashes, trace loss/symbol limitations, trial summaries and reviewer/date for
each gate. A claim without its evidence remains unvalidated.

- **Causal reproduction:** show the exact per-process/device request path,
  submitted flag, unchanged-completion behavior, CPU/frame-time correlation,
  controller appearance/disappearance controls and Observe overhead. A normal
  queued Windows 11 path is a negative result. Neither release notes nor a
  resubmission loop proves a fault; an uninspected Windows 10 kernel cannot
  inherit the Windows 11 kernel analysis.
- **A/B performance:** repeated matched trials show at least 90% lower
  pathological unchanged-request rate and corresponding CPU or frame-time
  improvement. Review the absolute baseline and every trial, not just relative
  percentages. Test each GameInput implementation independently and together.
- **Physical correctness:** an independent transition/timing oracle shows no
  missed input and no added latency above the measured, declared cap; verify
  rumble start/change/stop, simultaneous input, multiple handles/controllers,
  reconnect, session/process respawn, crash behavior and shutdown. Initial 8 ms
  pacing is not an 8 ms scheduling guarantee. The reported 17.2735 ms native
  wait check leaves the latency gate failed/pending, not passed. Synthetic
  result/buffer tests cannot substitute for these hardware phases.
- **Trust and target isolation:** security review verifies x64 exact process,
  actual loaded Microsoft-signed modules, hashes/versions, architecture,
  protection, file/path ACLs, race/revalidation behavior and constrained IPC.
  An inventory hash is not a compatibility approval.
- **Release and recovery:** independently review signing, reproducible builds,
  dependency provenance/licenses, security-product false positives, install,
  rollback, uninstall, crash-loop handling and loss of controller/helper.

The analyzer supplies limited numeric research evidence. It never attests to
the remaining gates, signs a manifest, or sets supported eligibility true.
No current Windows 11 configuration, Windows 10 configuration, controller,
signing identity or Defender outcome is approved here.

## Proposed user experience after all gates pass

One UI would expose **Collect diagnostics**, **Enable workaround**, **Disable
workaround**, and status. Collection would remain available on unknown builds.
Enable would be disabled with a clear reason whenever compatibility or any
release gate is missing. Status would distinguish collection, disabled,
validating, enabled for specific verified targets, degraded and recovery needed;
it must never show enabled merely because a service/helper is running.

Enable would present the exact approved target set, measured limits, reversibility
and security-sensitive LocalSystem injection notice. No service/driver disabling
would be required for normal use. Disable would stop new attachment, request
observation/detach for every owned target, report retained modules, and verify
the outcome. Uninstall would disable first and explain any pending process-exit
cleanup; it could not promise immediate unload of a pinned DLL.

No telemetry or diagnostic upload would occur automatically. Local logs would
be bounded and privacy reviewed before export. Restore-point guidance would
describe recovery options without treating a restore point as guaranteed or
required to collect diagnostics.

## Proposed trust boundary

A signed installer would install a signed LocalSystem helper and signed probe
in administrator-writable, ordinary-user-read-only locations. A standard-user UI
would communicate through authenticated, ACL-restricted local IPC exposing only
collect/status/enable/disable with bounded, validated payloads. Administrative
authorization would be required for machine-wide changes. The helper would
accept no arbitrary process, PID, executable path, DLL path, export, remote
address, command string or generic injection operation.

The helper would watch only `GameInputSvc.exe` and `GameInputRedistService.exe`.
For each candidate it would revalidate the held process identity/start time,
canonical executable path, native architecture, protection level, actual loaded
GameInput module paths, expected Microsoft certificate trust and exact versions
and SHA-256 before attachment. Names alone would never authorize injection.
The per-user redist can load `System32\GameInputRedist.dll`; the installed
Program Files DLL is not an adequate proxy. Any ambiguity, inaccessible target,
unknown hash, signature failure or identity change would leave that target
untouched and show why it is unsupported.

A future authenticated compatibility manifest would bind exact OS build+UBR,
architecture, executable and loaded-module identities, driver identity,
approved helper/probe build, tested controller/connection scope, allowed pacing
range, evidence references, gate reviewers and rollback version. It would be
verified before use, protected against unauthorized modification and rollback,
and fail closed if absent, invalid or unknown. No online upload or remote
manifest refresh is required by this design. Binary/file replacement between
checking and using a target must be explicitly reviewed and tested.

The supported x64 implementation could reuse a reviewed, internally restricted
Nefarius Injector implementation pinned to v1.5.0 and Microsoft Detours pinned
to the reviewed build. It must not ship the generic Injector command line as
an end-user API. Research loading of an existing SCM process remains distinct
from Detours import-table injection at suspended process creation. No injection
or hook installation would occur under loader lock.

The probe would call the original IOCTL first and pace only verified repeated
unchanged successful 24-byte results for the exact 4-byte/24-byte tuple and
approved handle/process. Changed results, pending, errors and unexpected calls
would remain pass-through. Return value, output, bytes returned and last error
must be preserved. Bound per-handle state and report drops, remove closed state
where safe, and fail open on internal errors or an expired helper heartbeat.
Any supported pacing range must come from actual timing and hardware tests;
the research interval range is not a validated safety envelope.

## Lifecycle and recovery requirements

Reattachment after service/session respawn would require a fresh exact-identity
check and successful handshake. Rate-limit retries; a proposed conservative
default would disable a target after three failures within ten minutes. This
number is an unvalidated design starting point, to be tested rather than
silently treated as an accepted safety threshold. Never restart a service in a
loop to conceal crashes. Persist a machine-readable recovery reason.

Helper/UI termination, suspend/resume, a stale heartbeat, locked state, disk-full
logging, failed startup, service shutdown and partial uninstall must leave the
OS behavior pass-through. Disable/rollback must be tested even when IPC or a
target is hung. A busy detach would retain the module and report recovery
needed; it would never force `FreeLibrary` or pretend the hook is gone.
The current research DLL is pinned until process exit. A future installer must
report deferred unload/removal honestly and preserve any still-mapped file until
a normal process exit or explicitly arranged restart/reboot permits removal.
Preserve original service configuration and never replace Windows binaries.

Recovery trials would cover stop/disable before and during throttling, reboot,
process/session churn, changed binaries after an OS/redist update, multiple
eligible processes, helper crash, controller reconnect and installer rollback.
Unknown versions after an update would disable enabling until independently
validated. x86 and ARM64 remain unsupported until matching binaries and tests
exist; the generic loader supporting them is insufficient.

## Release evidence required for any supported build

Publish source, reproducible build instructions and environment, pinned source
and release checksums, complete Detours and Injector MIT notices, the actual
code-signing identity and signature verification procedure, compatibility and
hardware validation reports, recovery results, and Defender/security-product
submission outcomes with dates and artifact hashes. False-positive resolution
must be evidenced, not claimed because a local scan was quiet. Retain a known
good signed rollback release and test uninstall. No real signing identity,
submission result, latency bound or release checksum is invented in this design.
