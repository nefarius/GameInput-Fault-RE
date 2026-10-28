# Implementation status

The supplied plan is unchanged. The task checklist from the prior editor is not exposed by this client; this file records the same task IDs and their evidence.

- `safe-collector`: completed — contributor instructions, bounded collector, real ETL/ZIP run, zero reported losses and 28 manifest entries verified.
- `ioctl-probe`: completed — pass-through probe, pinned dependencies, secure mapping transfer and restricted persistent research wrapper. Native build/tests and real hook start/stop verified; active-input measurements continue below.
- `live-proof`: observation tooling and local USB/Bluetooth experiments completed; **causal proof remains unvalidated**. Both local measured paths returned pending. A contributed Left 4 Dead 2 trace now identifies expensive game-side XInput enumeration/close work; a matched service comparison and frame-time evidence are still missing.
- `xinputhid`: completed — matching-PDB Ghidra analysis, dispatch/completion/focus paths and byte-checked excerpts saved in `docs/kernel-xinputhid.md` and `evidence/static/`; poll-to-rumble causation remains unproven.
- `mitigation-prototype`: code and synthetic validation completed; **hardware A/B acceptance blocked on reproduction**. No immediate unchanged-response flood was measured, so enabling a hardware throttle was not justified. Actual Windows scheduling can exceed 8 ms.
- `version-matrix`: completed — local hashes/versions, schema and analysis tools; Windows 10 22H2 is explicitly untested. Evidence tests pass.
- `supported-tool`: completed (design only) — signed helper design and contributor workflow; release remains gated on causal, performance, input/rumble, recovery and signing evidence.

Completion means the specified evidence exists. Hardware tests, external signing, or unobserved Windows builds will not be marked passed based on synthetic tests.

## Verification

- Left 4 Dead 2 community follow-up: 28 manifest entries verified; all 13
  GameInput/xinputhid inventory hashes match the first package. A retained
  13-second window and trace-matched public symbols locate game-thread CPU
  work in XInput enumeration and handle cleanup, not a measured unfiltered-state
  or rumble-off flood. See [review](community-capture-20261028-l4d2.md).

- Collector follow-up: five-second symptomatic default, explicit interactive
  readiness before tracing, separate ETLs/watchdogs for comparison phases,
  corrected phase markers and post-save operator reports. Windows PowerShell
  5.1 parser and mocked orchestration checks cover these changes; live WPR
  retention on a symptomatic machine remains unvalidated.

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
