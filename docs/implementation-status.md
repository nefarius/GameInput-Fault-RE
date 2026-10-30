# Implementation status

The supplied plan is unchanged. The task checklist from the prior editor is not exposed by this client; this file records the same task IDs and their evidence.

- `safe-collector`: completed — contributor instructions, bounded collector, real ETL/ZIP run, zero reported losses and 28 manifest entries verified.
- `ioctl-probe`: completed — pass-through probe, pinned dependencies, secure mapping transfer and restricted persistent research wrapper. Native build/tests and real hook start/stop verified; active-input measurements continue below.
- `live-proof`: Windows 11 observation tooling and USB/Bluetooth experiments completed; both measured paths returned pending. The Windows 10 VM demonstrates missing PID initialization, repeated queue allocation, restored reuse and lower close/x86 XInput API cost after a one-entry correction. A controlled call now reaches the actual kernel cleanup traversal. A fresh idle pair found no clear API cost difference at a small queue population; active input was followed by thousands of queues and increased cost, which persisted after the producer exited. The same-boot contributor comparison links the inbox-running condition to reported symptoms and expensive enumeration/close work. **Causal proof of the contributor's game FPS loss remains unvalidated**; exact game workload control, frame times and the complete x86 user stack remain outstanding.
- `xinputhid`: completed — matching-PDB Ghidra analysis, dispatch/completion/focus paths and byte-checked excerpts saved in `docs/kernel-xinputhid.md` and `evidence/static/`; poll-to-rumble causation remains unproven.
- `mitigation-prototype`: code and synthetic validation completed; **hardware A/B acceptance blocked on reproduction**. No immediate unchanged-response flood was measured, so enabling a hardware throttle was not justified. Actual Windows scheduling can exceed 8 ms.
- `version-matrix`: completed — local hashes/versions, schema and analysis tools; Windows 10 22H2 has a byte-checked and live-observed queue-identity defect. Fresh-device PID corrections restored reuse and suppressed queue growth. Two serial handle-close comparisons and one x86 XInput API pair measured substantially lower costs. Game FPS benefit, controller fidelity and supported-fix acceptance remain unvalidated. Evidence tests pass.
- `supported-tool`: completed (design only) — signed helper design and contributor workflow; release remains gated on causal, performance, input/rumble, recovery and signing evidence.

Completion means the specified evidence exists. Hardware tests, external signing, or unobserved Windows builds will not be marked passed based on synthetic tests.

## Verification

- Static version follow-up, 2026-10-30: REA/Ghidra 12.1.3 finds the correct PID
  store in xinputhid **10.0.22621.3085**, reconstructed from original Microsoft
  **KB5034204** delta bytes with exact whole-file hash. It maps to **Windows 11
  22H2 / 22621.3085 and 23H2 / 22631.3085**, January 23, 2024. The preceding
  inspected 22621.2506 dispatch lacks the IOCTL; the 26100.1 baseline contains
  the store. Windows 10 19041.3996 already omits it, alongside affected
  19041.5794. No corrected Windows 10 shipping revision or Windows 11
  broken-to-fixed transition established. No new live tests or release gates.
  See [version history and acquisition limits](xinputhid-pid-version-history.md).

- VM-only follow-up, 2026-10-29: a process-scoped absent-slot call reached
  xinputhid cleanup and the actual WDF traversal of the corrected manual queue.
  Loaded WDF backing identity and DsHidMini 3.27.0.2500 are now inventoried.
  Eight held-state windows produced 1028 successful input samples. Vibration
  start/stop and 64 during/after queries succeeded, with operator confirmation
  of physical start/stop; the corrected process queue list remained one.
  WOW64 user unwind failed; every transition, physical latency, game performance,
  and full input fidelity remain outside these results. A fresh corrected-first
  idle pair completed 400 calls per condition: 48 unmodified entries versus one
  corrected entry, but similar API medians. Continuous input then preceded 3383
  entries and 4-10 times higher absent-slot medians in the unmodified lifetime.
  Stopping the service terminated the observed producer processes but retained
  3383 entries and elevated costs; Running/Manual state was restored successfully.
  Both runners stopped cleanly and temporary runtime sharing was disabled. See
  the [VM-only checklist](vm-validation-checklist.md) for evidence and limitations.

- Corrected x86 XInput comparison, 2026-10-29: all 400 calls per condition
  completed with identical slot status groups and matching OS/binary/script
  identities and limits. Disconnected-slot medians fell from 1834-2747 to
  42-125 microseconds (21.90-43.94 times lower), and corrected queue count
  remained one. One serial API pair; exposure, teardown, stack verification,
  game frame times and input fidelity remain limited or unvalidated. See
  [API pair evidence](../evidence/runtime/vm-xinput-x86-pair-20261029.json).

- x86 XInput baseline, 2026-10-29: revised WOW64 identity guard passed; exact
  driver/DLL/script hashes verified. All 400 timed calls completed: 100 successes
  on slot 0 (median 16.45 microseconds), and 100 expected disconnected returns
  on each of slots 1-3 (medians 2746.9, 2080.5, 1834.45 microseconds). Snapshot
  after transfer found at least 4096 queues. Corrected API comparison and
  per-call enumeration/cleanup stacks remain pending. See
  [baseline evidence](../evidence/runtime/vm-xinput-x86-uncorrected-20261029.json).

- Reversed-order handle-close check, 2026-10-29: corrected repeat median 11.15
  microseconds, then fresh uncorrected repeat 437.8 (39.26 times higher).
  All 100 pairs in each succeeded with identities and limits matching the first
  pair. Corrected count stayed one; uncorrected grew from the pre-snapshot 556
  to post-transfer 2864. The repeat reuses the first corrected lifetime; age,
  exposure and retired-device state remain confounds. See
  [reversed pair](../evidence/runtime/vm-handle-close-reversed-pair-20261029.json).

- Paired handle-close result, 2026-10-29: 100 successful pairs per condition
  with matching interface, driver/script hashes, architecture and limits.
  Corrected post-transfer list still had one node. Median close duration fell
  from 411.45 to 11.7 microseconds (35.17 times lower); p95 from 733.2 to 38.3.
  This supports the queue-accumulation/close-cost mechanism in the guest.
  Single serial pair, unequal exposure and incomplete retired-device teardown
  limit causality; game FPS and controller fidelity remain untested. See
  [pair evidence](../evidence/runtime/vm-handle-close-pair-20261029.json).

- Fresh corrected VM lifetime, 2026-10-29: initialized the first GameInput
  entry's missing PID before publication and observed reuse by the same
  process. After the short resumed observation, its complete list still had
  one node versus 332 in the earlier uncorrected short run. This supports the
  missing initialization as the cause of excess queue creation in this guest;
  exact running intervals and other activity were not fully matched. Corrected
  handle-close timings and game performance remain pending. See
  [corrected growth evidence](../evidence/runtime/vm-queue-corrected-growth-20261029.json).

- Fresh uncorrected VM lifetime, 2026-10-29: a distinct context began with an
  empty list, published a stale-PID node and later contained 332 nodes. An x64
  metadata-only open/close benchmark completed 100 successful pairs; median
  close time was 411.45 microseconds, p95 733.2 microseconds. Earlier pre-run
  count was 1994; post-transfer count was at least 4096, with exact population
  during timed calls unknown. Corrected comparison remains pending. See
  [comparison workflow and baseline](vm-queue-comparison.md).

- Direct MCP correction/reuse, 2026-10-29: after rediscovering the device
  following reconnect, a guarded four-byte write initialized a fresh node's PID
  to 0x684. It survived publication; a subsequent request by the same GameInput
  process selected that exact node and loaded its existing manual WDF queue.
  This proves reuse for the observed request, not a performance fix. Existing
  excess queues remain; growth rate, cleanup cost, FPS and input behavior are
  unmeasured. VM left paused, corrected field retained, no breakpoints remaining.
  See [reuse evidence](../evidence/runtime/vm-queue-corrected-reuse-20261029.json).

- One-node correction in the VM: the operator initialized a fresh node's PID
  to its captured requestor PID 0x684 and observed that value survive WDF queue
  creation and list publication. Sleep and controller reconnection interrupted
  the follow-up before a reuse result was supplied. Old device/queue pointers
  must be discarded and the new lifetime rediscovered. This is not proof of
  queue reuse or a performance fix. See
  [corrected publication evidence](../evidence/runtime/vm-queue-corrected-publication-20261029.json).

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
  Exact rate, performance causation and correction efficacy were unmeasured
  at this observation; subsequent correction/API comparisons are recorded above. See
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
  initialization and repeated same-worker allocation, followed by a limited
  VM queue-growth/close-cost/x86 API PoC. Game FPS causation, fidelity and
  a supported hardware fix remain unvalidated.

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
