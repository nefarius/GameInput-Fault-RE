"""Exercise collector orchestration with fake Windows tools; never start tracing."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
POWERSHELL = shutil.which("powershell.exe")

MOCKS = r'''
function Test-CollectorAdministrator { $true }
function Get-SystemTool { param($Name) $Name }
function Invoke-CollectorCommand {
    param($FilePath, $Arguments, $TimeoutSeconds, $SizeWatchPath, $MaxBytes)
    $result = [pscustomobject]@{ ExitCode=0; TimedOut=$false; SizeExceeded=$false; Stdout=''; Stderr='' }
    $row = @{tool=$FilePath; arguments=@($Arguments)} | ConvertTo-Json -Compress
    Add-Content -LiteralPath (Join-Path $env:COLLECTOR_TEST_ROOT 'commands.jsonl') -Value $row
    if ($Arguments -contains 'advanced') { $result.Stdout = 'instancename' }
    if (@($Arguments | Where-Object { $_ -like '*Collect-Inventory.ps1' }).Count) {
        Write-CollectorJson (Join-Path $run 'inventory.json') @{Issues=@()}
    }
    if ($Arguments -contains '-start') {
        if (Test-Path (Join-Path $env:COLLECTOR_TEST_ROOT 'active')) { throw 'Overlapping trace!' }
        Set-Content (Join-Path $env:COLLECTOR_TEST_ROOT 'active') 'active'
    }
    if ($Arguments -contains '-stop') {
        if ($env:COLLECTOR_TEST_SCENARIO -in @('save-failure', 'cleanup-busy')) { $result.ExitCode=1 }
        else {
            Set-Content -LiteralPath $Arguments[1] 'synthetic ETL, not runtime evidence'
            Remove-Item (Join-Path $env:COLLECTOR_TEST_ROOT 'active')
        }
    }
    if ($Arguments -contains '-cancel') {
        if ($env:COLLECTOR_TEST_SCENARIO -eq 'cleanup-busy') { $result.ExitCode=1; return $result }
        Remove-Item (Join-Path $env:COLLECTOR_TEST_ROOT 'active') -ErrorAction SilentlyContinue
    }
    # A nonzero status means the named recording is absent after cancellation.
    if ($Arguments -contains '-status' -and $env:COLLECTOR_TEST_SCENARIO -ne 'cleanup-busy') { $result.ExitCode=1 }
    $result
}
function Start-Process {
    param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru)
    $directory = [regex]::Match($ArgumentList, '"-RunDirectory" "([^"]+)"').Groups[1].Value
    if (-not $directory) { throw 'Missing watchdog directory' }
    if ($WindowStyle -ne 'Hidden') { throw 'Visible watchdog!' }
    Set-Content (Join-Path $directory 'watchdog.ready') 'synthetic ready'
    $mock = [pscustomobject]@{HasExited=$false}
    Add-Member -InputObject $mock -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }
    Add-Member -InputObject $mock -MemberType ScriptMethod -Name Dispose -Value { }
    $mock
}
function Read-Host {
    param($Prompt)
    if (Test-Path (Join-Path $env:COLLECTOR_TEST_ROOT 'active')) { throw 'Prompt during recording!' }
    if ($Prompt -like 'Reproduce/prepare*') {
        if ($env:COLLECTOR_TEST_SCENARIO -eq 'skip') { return 'S' }
        if ($env:COLLECTOR_TEST_SCENARIO -eq 'cancel') { return 'Q' }
        return ''
    }
    if ($Prompt -like 'Was the problem*') { return 'N' }
    return 'unknown'
}
if ($env:COLLECTOR_TEST_SCENARIO -eq 'size-limit') {
    function Get-CollectorBytes {
        param($Path)
        if (@(Get-ChildItem -LiteralPath $Path -Filter *.etl -Recurse -File).Count) { return [long]300MB }
        [long]0
    }
}
'''


@unittest.skipUnless(os.name == "nt" and POWERSHELL, "Windows PowerShell 5.1 required")
class CollectorTests(unittest.TestCase):
    def run_collector(self, scenario="default", phases=None, unattended=False):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        source = ROOT / "tools/collector"
        script = (source / "Collect-Diagnostics.ps1").read_text()
        # Replace only the timed wait with an instantaneous fake. All session,
        # readiness, save, cleanup and packaging control flow runs unchanged.
        start = script.index("function Wait-PhaseInterval {")
        end = script.index("\ntry {", start)
        script = script[:start] + r'''
function Wait-PhaseInterval {
    param([int]$Seconds, [switch]$Preparation)
    Assert-TraceBudget
    if ($Preparation) { return 'timed-preparation-ended' }
    if ($env:COLLECTOR_TEST_SCENARIO -eq 'record-failure') { throw 'Synthetic recording interruption' }
    'completed'
}
''' + script[end:]
        (root / "Collect-Diagnostics.ps1").write_text(script)
        common = (source / "Collector.Common.ps1").read_text()
        (root / "Collector.Common.ps1").write_text(common + MOCKS)
        output = root / "output"
        args = [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                str(root / "Collect-Diagnostics.ps1"), "-Consent", "-OutputDirectory", str(output),
                "-Controller", "test", "-Connection", "test", "-Game", "test", "-Rumble", "test",
                "-Symptom", "test", "-WorkaroundState", "test"]
        if phases:
            # PowerShell -File cannot bind a CLI array as comma-separated text;
            # invoke a generated trusted runner to pass an actual string array.
            runner = root / "runner.ps1"
            phase_literals = ",".join("'" + phase + "'" for phase in phases)
            runner.write_text("& $PSScriptRoot/Collect-Diagnostics.ps1 -Consent "
                              "-Controller test -Connection test -Game test -Rumble test "
                              "-Symptom test -WorkaroundState test -OutputDirectory "
                              "(Join-Path $PSScriptRoot output) -Phases @(" + phase_literals + ")\nexit $LASTEXITCODE\n")
            args = args[:args.index("-File") + 1] + [str(runner)]
        if unattended:
            args.append("-NonInteractive")
        env = dict(os.environ, COLLECTOR_TEST_ROOT=str(root), COLLECTOR_TEST_SCENARIO=scenario)
        # Do not inherit a PowerShell 7-only module search path from the test host.
        env["PSModulePath"] = str(Path(os.environ["SYSTEMROOT"]) / "System32/WindowsPowerShell/v1.0/Modules")
        result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=30)
        runs = list(output.glob("GameInput-*"))
        directory = next(p for p in runs if p.is_dir())
        state = json.loads((directory / "run.json").read_text(encoding="utf-8-sig"))
        self.assertTrue((root / "commands.jsonl").exists(), result.stdout + result.stderr + str(state))
        commands = [json.loads(line) for line in (root / "commands.jsonl").read_text(encoding="utf-8-sig").splitlines()]
        return result, state, commands, directory

    def test_default_short_symptom_capture_and_observations_after_save(self):
        result, state, commands, directory = self.run_collector()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        phases = state["Phases"]
        self.assertEqual(len(phases), 1)
        phase = phases[0]
        self.assertEqual(phase["Name"], "symptom")
        self.assertTrue(phase["OperatorConfirmed"])
        self.assertTrue(phase["TraceSaved"])
        self.assertEqual(phase["TracePath"], "capture.etl")
        self.assertEqual(phase["CoverageStatus"], "not-checked")
        self.assertEqual(phase["Observations"]["SymptomObserved"], "no")
        questionnaire = json.loads((directory / "questionnaire.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(questionnaire["PhaseSeconds"], 5)
        markers = [c["arguments"][1] for c in commands if "-marker" in c["arguments"]]
        self.assertEqual(markers, ["GameInput:symptom:start", "GameInput:symptom:end"])
        self.assertFalse(any("-status" in c["arguments"] for c in commands))
        with zipfile.ZipFile(str(directory) + ".zip") as bundle:
            self.assertIn("capture.etl", bundle.namelist())

    def test_phases_save_separately_with_distinct_instances(self):
        result, state, commands, directory = self.run_collector(phases=["baseline", "rumble"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        actions = [c["arguments"][0] for c in commands if c["arguments"][0] in ("-start", "-stop")]
        self.assertEqual(actions, ["-start", "-stop", "-start", "-stop"])
        self.assertEqual([p["TracePath"] for p in state["Phases"]], ["baseline/capture.etl", "rumble/capture.etl"])
        self.assertEqual(len({p["InstanceName"] for p in state["Phases"]}), 2)
        for phase in state["Phases"]:
            self.assertTrue((directory / phase["TracePath"]).exists())
            self.assertTrue((directory / phase["Name"] / "watchdog.complete").exists())

    def test_unattended_does_not_invent_operator_confirmation(self):
        result, state, _, _ = self.run_collector(unattended=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        phase = state["Phases"][0]
        self.assertFalse(phase["OperatorConfirmed"])
        self.assertEqual(phase["Observations"]["SymptomObserved"], "unknown")

    def test_skip_and_cancel_never_start_tracing(self):
        for scenario in ("skip", "cancel"):
            with self.subTest(scenario=scenario):
                result, state, commands, _ = self.run_collector(scenario)
                self.assertFalse(any("-start" in c["arguments"] for c in commands))
                self.assertFalse(state["Phases"][0]["TraceSaved"])
                self.assertEqual(result.returncode, 0 if scenario == "skip" else 1)

    def test_failed_save_or_interruption_cancels_only_its_named_instance(self):
        for scenario in ("save-failure", "record-failure"):
            with self.subTest(scenario=scenario):
                result, state, commands, _ = self.run_collector(scenario, phases=["baseline", "idle"])
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(state["Status"], "incomplete")
                self.assertEqual(sum("-start" in c["arguments"] for c in commands), 1)
                cancels = [c["arguments"] for c in commands if "-cancel" in c["arguments"]]
                self.assertEqual(cancels, [["-cancel", "-instancename", state["Phases"][0]["InstanceName"]]])
                self.assertFalse(state["Phases"][0]["TraceSaved"])

    def test_shared_size_limit_removes_traces_and_refuses_next_phase(self):
        result, state, commands, directory = self.run_collector("size-limit", phases=["baseline", "idle"])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(sum("-start" in c["arguments"] for c in commands), 1)
        self.assertFalse(list(directory.rglob("*.etl")))
        self.assertFalse(any(p["TraceSaved"] for p in state["Phases"]))

    def test_unverified_cleanup_leaves_watchdog_armed_and_defers_zip(self):
        result, state, _, directory = self.run_collector("cleanup-busy")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue(any("Cleanup could not be verified" in error for error in state["Errors"]))
        self.assertFalse((directory / "watchdog.complete").exists())
        self.assertFalse(Path(str(directory) + ".zip").exists())


if __name__ == "__main__":
    unittest.main()

