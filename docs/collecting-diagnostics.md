# Collecting GameInput diagnostics

Start here if GameInput is associated with high CPU, stutters, or a controller problem. You do not need the experimental probe to collect a useful report.

## Before you start

Keep the original controller, connection, driver, game, and GameInput service settings. First collect **without** an experimental workaround. Note the Windows version, controller model, connection (USB/Bluetooth/receiver), game/version, whether vibration is enabled, the symptom, and how long it takes to appear. Do not change drivers or disable services as part of this baseline.

Close sensitive applications. This collector makes a **system-wide trace**: process/image and file paths, CPU stacks, timing, device identifiers and input-related events can be included. Device IDs can encode a serial number or Bluetooth address; user paths can identify you. Questionnaire answers also become part of the report. The package is not anonymized. No upload happens automatically.

## Collect a report

1. Open `tools/collector` and double-click **Collect-Diagnostics.cmd**. Accept the Windows administrator prompt.
2. Read the displayed privacy notice. Type **COLLECT** to accept collection, or close the window to decline.
3. Answer the short questionnaire. A controller model is enough; do not enter a serial number.
4. Follow the four phase prompts: controller disconnected/baseline, connected and idle, buttons/sticks moving, and vibration requested in your existing game/test app. Press Enter when ready, S to skip an unavailable phase, or Q to cancel. The collector does not generate input or vibration. Describe skipped or unverified actions honestly.
5. Wait for the ZIP path and SHA-256 to appear. The default output is `tools/collector/output`. Saving the trace may take longer than recording it. `collector-status.json` shows the current stage.

The default phase recording is 15 seconds plus 10 seconds of preparation per phase. You can reproduce a delayed fault first, then collect while it is happening. A quiet short capture does not rule out an intermittent fault. If unplugging the controller would disrupt a game or reproduction, skip that phase and explain why.

The collector reads configuration and records tracing. It does not inject a DLL, stop services, install drivers, change power plans, or repair the system. Administrator access allows Windows tracing and access to service/module inventory.

## Review and provide the report

Keep the local staging directory until the report has been checked. Open `summary.txt`, `questionnaire.json`, `inventory.json`, `providers.json`, `phases.json`, and `run.json`. Confirm that the listed controller, actual actions, errors, and service/workaround state are accurate. The ZIP also includes the exact collector scripts/profile used and `consent-privacy.txt`.

ETL is binary and can contain identifying data even if the JSON looks harmless. Ask a maintainer for a private sharing method if you cannot review it or if public disclosure is inappropriate. Do not post a trace containing sensitive activity publicly. Do not delete or edit identifying fields and retain the old checksum manifest: produce a new reviewed package and document what changed.

Attach the reviewed ZIP to the issue when size limits allow, or provide it privately as agreed. Include this information in the issue text:

```text
Windows version/build:
Controller model and firmware if known:
Connection and driver/mode:
Game/test application and version:
Exact symptom and reproduction steps:
Time until the fault starts:
Vibration enabled/requested/observed:
GameInput service/workaround state:
Which phases were actually performed or skipped:
Did the symptom occur during this capture? At what time?
Collector errors or omitted providers:
ZIP SHA-256:
Public or privately shared diagnostics:
```

Never attach Windows binaries, full process memory dumps, or downloaded symbol/build directories by default. Raw diagnostics stay ignored by this repository. Only reviewed small derived summaries belong in git.

## Optional command-line collection

In an administrator PowerShell terminal at the repository root, collect only an idle reproduction:

```powershell
.\tools\collector\Collect-Diagnostics.ps1 -Phases idle -PhaseSeconds 30 -PreparationSeconds 10 -Controller 'your model' -Connection USB
```

To automate an already agreed experiment, `-Consent -NonInteractive` explicitly accepts the exact notice printed by the script. It does **not** confirm that a controller was disconnected or that input/vibration happened. Phase timestamps and operator-confirmation fields must be interpreted accordingly.

For inventory without ETL (usable without administrator access, with access limitations recorded):

```powershell
.\tools\collector\Collect-Diagnostics.ps1 -InventoryOnly
```

The trace duration is bounded by `-MaxTraceSeconds` (maximum 300 seconds); each phase is 3–60 seconds. `-MaxOutputMB` is 128–512 MiB, default 256. Tracing uses bounded memory buffers, not an indefinitely growing file recording. Buffers can wrap: the output limit does not guarantee that every earlier event survives. Inventory and save/packaging have separate bounded waits.

Researchers collecting a trace while the separately authorized probe runs may specify `-IncludeProbeProvider`. That only enables its ETW provider; it does not load or start the probe. See [the research workflow](workaround.md).

Verify a ZIP's manifest without extracting it:

```powershell
.\tools\validation\Test-DiagnosticBundle.ps1 -Path 'path-to-your-report.zip'
```

A passing checksum proves file integrity, not privacy, correct phase execution, successful instrumentation, or a diagnosis.

## Interrupted or incomplete collection

Ctrl+C/Q triggers cleanup. A separate watchdog also monitors the collector owner, time and output size. Cleanup cancels only the collector's randomly named WPR instance. A cancelled or partial run is still useful if it clearly records the errors; do not label it complete.

If `run.json` reports that cleanup could not be verified, its summary gives the exact random `InstanceName`. In an administrator terminal, use the recovery command printed by that run, for example:

```powershell
wpr -cancel -instancename GameInput_REPLACE_WITH_THE_EXACT_RUN_ID
```

Never run an unqualified `wpr -cancel`: another recording may belong to somebody else. Do not disable Defender, anti-cheat, or other protections to collect or attach the research probe. Provide the error and the safe baseline package instead.

## What maintainers need to check

Match OS/build and loaded-module/driver paths, versions, signatures and SHA-256; do not infer them from installed package names. Inspect provider omissions, WPR errors, event loss and CPU stack coverage. A registered/enabled provider does not guarantee that it emitted events. The bounded WDF configuration is documented in the run; it is not a promise of every private driver event.

Establish request rate, completion behavior, byte/packet changes and actual CPU or frame-time impact separately. The inspected Windows 11 `xinputhid` has a queued/change-driven path; the original state-poll-to-rumble hypothesis remains unproven. See [the findings](gameinput-service-fault.md), [kernel analysis](kernel-xinputhid.md) and [version matrix](version-matrix.md).
