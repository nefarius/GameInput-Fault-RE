# Implementation status

The supplied plan is unchanged. The task checklist from the prior editor is not exposed by this client; this file records the same task IDs and their evidence.

- `safe-collector`: completed — contributor instructions, bounded collector, real ETL/ZIP run, zero reported losses and 28 manifest entries verified.
- `ioctl-probe`: completed — pass-through probe, pinned dependencies, secure mapping transfer and restricted persistent research wrapper. Native build/tests and real hook start/stop verified; active-input measurements continue below.
- `live-proof`: observation tooling and local USB/Bluetooth experiments completed; **causal proof remains unvalidated**. Both local measured paths returned pending. A same-boot updated-collector service comparison now links the inbox-running condition to reported symptoms and expensive game-side XInput enumeration/close work. Exact workload control, frame-time measurement and the underlying driver cause remain unvalidated.
- `xinputhid`: completed — matching-PDB Ghidra analysis, dispatch/completion/focus paths and byte-checked excerpts saved in `docs/kernel-xinputhid.md` and `evidence/static/`; poll-to-rumble causation remains unproven.
- `mitigation-prototype`: code and synthetic validation completed; **hardware A/B acceptance blocked on reproduction**. No immediate unchanged-response flood was measured, so enabling a hardware throttle was not justified. Actual Windows scheduling can exceed 8 ms.
- `version-matrix`: completed — local hashes/versions, schema and analysis tools; Windows 10 22H2 has contributed runtime evidence; its driver semantics remain statically uninspected. Evidence tests pass.
- `supported-tool`: completed (design only) — signed helper design and contributor workflow; release remains gated on causal, performance, input/rumble, recovery and signing evidence.

Completion means the specified evidence exists. Hardware tests, external signing, or unobserved Windows builds will not be marked passed based on synthetic tests.

## Verification

- Updated-collector service pair: both 27-entry manifests verify, with matching
  four-second retained windows, boot, game process UniqueKey/thread, collector
  sources and profile. Redist stays running. Inbox enabled restores the reported
  symptom and cleanup-heavy hot path: XInputGetState occupies 88.58% of sampled
  thread stacks enabled versus 19.87% disabled. Scene/focus/FPS and driver cause
  remain unverified; no throttle or compatibility gate changes. See [pair review](community-capture-20261028-l4d2-pair.md).

- Updated-collector disabled-service follow-up: 27 manifest entries verified;
  five-second ETL retains both corrected markers and a usable four-second
  CPU/stack interval. Inbox is Stopped/Disabled, redist Running/Auto; operator
  reports no symptom. The older cleanup-heavy game path is greatly diminished,
  but a reboot and unconfirmed workload matching prevent a controlled A/B.
  The updated enabled counterpart is now reviewed separately; see [follow-up](community-capture-20261028-l4d2.md#disabled-service-follow-up-195831-4dcb7591).

- Left 4 Dead 2 community follow-up: 28 manifest entries verified; all 13
  GameInput/xinputhid inventory hashes match the first package. A retained
  13-second window and trace-matched public symbols locate game-thread CPU
  work in XInput enumeration and handle cleanup, not a measured unfiltered-state
  or rumble-off flood. See [review](community-capture-20261028-l4d2.md).

- Collector follow-up: five-second symptomatic default, explicit interactive
  readiness before tracing, separate ETLs/watchdogs for comparison phases,
  corrected phase markers and post-save operator reports. Windows PowerShell
  5.1 parser and mocked orchestration checks cover these changes. The two new
  contributed short traces retain usable windows, including the reported
  symptomatic enabled run; this does not guarantee retention under every load.

- Community review, 2026-10-28: 28 bundle manifest entries verified; Windows
  10 inventory and a four-second retained CPU window reviewed. Earlier CPU
  phases did not survive memory-buffer retention. No causal proof or hardware
  mitigation acceptance resulted; see [review](community-capture-20261028.md).

- Native MSVC x64 build succeeded; 4/4 native tests passed, including real Detours/trampoline calls, pending/error/guard-page preservation, result buffers, handle reuse, concurrency, mapping security, loaded-image export/build validation, and a suspended process-heap owner.
- 29/29 Python evidence-analysis tests passed. Runtime/schema/diagnostic checks are recorded in the findings and derived summaries.
- Real collector validation: ETL and ZIP created; xperf reported no lost buffers/events; all 28 packaged file hashes verified.
- Both successful controller runs completed without wrapper errors and ended with stopped/detached probe status. Pinned modules and bounded setup resources remain until normal target-process exit; no GameInput service was stopped or disabled.
- Four release-critical review findings were addressed: process-heap allocation during suspension, remote export address/build mismatch, executable pin consistency, and pre-call guarded-input reads.

The supplied plan remains unchanged. The remaining causal/performance/input/rumble/recovery/signing gates stay explicitly unvalidated. The repository does not contain a signed helper or installer and does not claim a permanent fix.
