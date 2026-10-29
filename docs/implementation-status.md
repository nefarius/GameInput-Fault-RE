# Implementation status

The supplied plan is unchanged. The task checklist from the prior editor is not exposed by this client; this file records the same task IDs and their evidence.

- `safe-collector`: completed — contributor instructions, bounded collector, real ETL/ZIP run, zero reported losses and 28 manifest entries verified.
- `ioctl-probe`: completed — pass-through probe, pinned dependencies, secure mapping transfer and restricted persistent research wrapper. Native build/tests and real hook start/stop verified; active-input measurements continue below.
- `live-proof`: observation tooling and local USB/Bluetooth experiments completed; **causal proof remains unvalidated**. Both local measured paths returned pending. A same-boot updated-collector service comparison now links the inbox-running condition to reported symptoms and expensive game-side XInput enumeration/close work. Exact workload control, frame-time measurement and the underlying driver cause remain unvalidated.
- `xinputhid`: completed — matching-PDB Ghidra analysis, dispatch/completion/focus paths and byte-checked excerpts saved in `docs/kernel-xinputhid.md` and `evidence/static/`; poll-to-rumble causation remains unproven.
- `mitigation-prototype`: code and synthetic validation completed; **hardware A/B acceptance blocked on reproduction**. No immediate unchanged-response flood was measured, so enabling a hardware throttle was not justified. Actual Windows scheduling can exceed 8 ms.
- `version-matrix`: completed — local hashes/versions, schema and analysis tools; Windows 10 22H2 has contributed runtime evidence and a byte-checked queue-identity defect now observed live in a research VM, including repeated same-worker allocation. Causal performance impact and correction efficacy remain unvalidated. Evidence tests pass.
- `supported-tool`: completed (design only) — signed helper design and contributor workflow; release remains gated on causal, performance, input/rumble, recovery and signing evidence.

Completion means the specified evidence exists. Hardware tests, external signing, or unobserved Windows builds will not be marked passed based on synthetic tests.

## Verification

- Contributed binary ZIP, 2026-10-29: all three members pass CRC checks and
  exactly match the analyzed GameInputInbox, x86 XInput1_4 and xinputhid files
  by SHA-256 and direct byte comparison. The contributor x86 XInput hash gap
  is closed; earlier capture-time limitations remain historical. See
  [identity evidence](../evidence/static/contributed-binary-identities-20261029.json).

- Live VM publication: a same-thread breakpoint pair identifies requestor PID
  1668 in a child GameInputSvc.exe and observes its new queue node linked with
  PID zero after queue creation. This confirms the missing initialization in
  a real execution. Prior bounded inspection changed from zero list nodes to
  at least seven. A second same-thread allocation now confirms that worker
  allocates another node while its earlier PID-zero node remains linked.
  Exact rate, performance causation and correction efficacy remain unmeasured. See
  [publication evidence](../evidence/runtime/vm-queue-publication-20261028.json).

- VMware stage 1: the operator reports Windows 10 19045.5796 after KB5055612,
  with the exact inspected xinputhid hash and reconstructed x86 XInput hash.
  Inbox is 0.2309.19041.5794, not the contributor's later revision. The displayed
  guest XInput version conflicts with the identical-hash local file's version;
  this remains unresolved. These are installed-file reports, not loaded-module
  or queue-growth observations. See [guest inventory](../evidence/runtime/vm-stage1-20261028.json).

- [Windows 10 queue identity](windows10-queue-identity.md): the contributor-hash
  driver compares per-process queue nodes by PID but omits initialization of that
  PID on allocation. The inspected Windows 11 build contains the store. The
  contributor-hash inbox worker selects the queued request path and waits for
  completion. Nine retained static exports have 1,314 source-byte-verified
  instructions. The later VM observations above establish publication without PID
  initialization and repeated same-worker allocation. FPS causation and a
  corrective hardware PoC remain unvalidated.

- [Windows 10 binary acquisition](windows10-binary-acquisition.md): reconstructed
  xinputhid 10.0.19041.5794 exactly matches the contributor's SHA-256; acquired
  GameInputInbox also matches. Reconstructed x86 XInput 10.0.19041.3636 matches
  trace version and PE/PDB identities; contributor backing-file hash is unknown.
  No acquired code was executed. Subsequent static inspection is recorded above.

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
