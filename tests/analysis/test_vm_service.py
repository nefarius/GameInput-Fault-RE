"""Service recovery orchestration with fake service operations; no real stop/start."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tools/runtime/Invoke-VMServiceRecovery.ps1'
PS = Path(os.environ.get('WINDIR', 'C:/Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
HARNESS = r'''
$ErrorActionPreference='Stop'
$global:FakeState='Running'
$global:Waits=0
$global:Calls=New-Object 'Collections.Generic.List[string]'
function Get-ItemProperty { [pscustomobject]@{CurrentBuild='19045';UBR=5796} }
function Get-FileHash { [pscustomobject]@{Hash=if($env:SCENARIO -eq 'identity'){ '0'*64 }else{'c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f'}} }
function Get-CimInstance { [pscustomobject]@{Name='GameInputSvc';State=$global:FakeState;StartMode='Manual';ProcessId=42} }
function Get-Process { @() }
function Read-Host { 'READY' }
function Get-Service {
    $s=[pscustomobject]@{Name='GameInputSvc'}
    $s | Add-Member ScriptMethod WaitForStatus { param($state,$timeout) }
    $s
}
function Stop-Service {
    param($Name,$ErrorAction)
    $global:Calls.Add('stop:'+ $Name); $global:FakeState='Stopped'
    if($env:SCENARIO -eq 'stop-error'){throw 'synthetic stop failure'}
    $requestId=if($env:SCENARIO -eq 'wrong-nonce'){'wrong'}else{$id}
    [IO.File]::WriteAllText((Join-Path $folder 'resume.request.json'),(@{sessionId=$requestId}|ConvertTo-Json))
}
function Start-Sleep {
    $global:Waits++
    [IO.File]::WriteAllText((Join-Path $folder 'resume.request.json'),(@{sessionId=$id}|ConvertTo-Json))
}
function Start-Service {
    param($Name,$ErrorAction)
    $global:Calls.Add('start:'+ $Name)
    if($env:SCENARIO -eq 'restore-error'){throw 'synthetic restore failure'}
    $global:FakeState='Running'
}
$failure=$null
try { & $env:SCRIPT -ResultsRoot $env:RESULTS } catch { $failure=$_.Exception.Message }
@{calls=@($global:Calls);state=$global:FakeState;failure=$failure;waits=$global:Waits}|ConvertTo-Json -Compress
'''

@unittest.skipUnless(PS.exists(), 'Windows PowerShell required')
class VMServiceTests(unittest.TestCase):
    def run_case(self, scenario):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            harness = root / 'test.ps1'
            harness.write_text(HARNESS)
            env = dict(os.environ, SCENARIO=scenario, SCRIPT=str(SCRIPT), RESULTS=tmp)
            result = subprocess.run([str(PS), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(harness)],
                                    env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            result_json = json.loads(result.stdout.strip().splitlines()[-1])
            records = [json.loads(p.read_text()) for p in root.glob('service-recovery-*/ended.json')]
            return result_json, records

    def test_matching_request_restores_only_named_service(self):
        result, records = self.run_case('normal')
        self.assertEqual(result['calls'], ['stop:GameInputSvc', 'start:GameInputSvc'])
        self.assertIsNone(result['failure'])
        self.assertEqual(records[0]['reason'], 'matching-resume-request')
        self.assertEqual(records[0]['restored']['StartMode'], 'Manual')

    def test_stop_failure_still_restores_and_is_recorded(self):
        result, records = self.run_case('stop-error')
        self.assertEqual(result['state'], 'Running')
        self.assertIn('synthetic stop failure', records[0]['stopError'])
        self.assertIsNone(records[0]['restoreError'])
        self.assertIsNotNone(result['failure'])

    def test_failed_restoration_is_not_reported_success(self):
        result, records = self.run_case('restore-error')
        self.assertEqual(result['state'], 'Stopped')
        self.assertIn('synthetic restore failure', records[0]['restoreError'])
        self.assertIn('Restoration failed', result['failure'])

    def test_wrong_identity_never_changes_service(self):
        result, records = self.run_case('identity')
        self.assertEqual(result['calls'], [])
        self.assertEqual(records, [])

    def test_wrong_nonce_does_not_end_measurement_window(self):
        result, records = self.run_case('wrong-nonce')
        self.assertEqual(result['waits'], 1)
        self.assertEqual(records[0]['reason'], 'matching-resume-request')

if __name__ == '__main__':
    unittest.main()
