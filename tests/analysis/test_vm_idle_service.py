"""Exercise only synthetic service/process backends for the running condition."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tools/runtime/Invoke-VMIdleRunningCondition.ps1'
PS = shutil.which('powershell.exe')
BACKEND = r'''
$global:state='Stopped'; $global:starts=0; $global:stops=0; $global:launches=0
if ($env:TEST_MODE -eq 'baseline') { $global:state='Running' }
function Get-ItemProperty { [pscustomobject]@{CurrentBuild='19045';UBR=5796} }
function Get-FileHash {
 param($LiteralPath)
 $h='c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f'
 if ($LiteralPath -like '*Measure-VMIdleInput.ps1') {$h='40d40823aa58312f7aed456885f3e52749ff4b074146598d53322c823bc77bab'}
 if ($LiteralPath -like '*Save-VMInventory.ps1') {$h='59235f028a941a50e4550957c78caeb7614f137ed50e71863b2e8bcbdf8c562c'}
 [pscustomobject]@{Hash=$h}
}
function Get-Service { param($Name) if($Name -ne 'GameInputSvc'){throw 'Unexpected service'}; [pscustomobject]@{Status=$global:state;StartType='Manual'} }
function Start-Service { param($Name) if($Name -ne 'GameInputSvc'){throw 'Unexpected service'}; $global:starts++;$global:state='Running';if($env:TEST_MODE -eq 'partial'){throw 'Synthetic partial start'} }
function Stop-Service { param($Name) if($Name -ne 'GameInputSvc'){throw 'Unexpected service'}; $global:stops++;if($env:TEST_MODE -eq 'stop_failure'){throw 'Synthetic stop failure'};$global:state='Stopped' }
function Get-CimInstance { [pscustomobject]@{Name='GameInputSvc';State=$global:state;StartMode='Manual';ProcessId=123} }
function Start-Sleep { param($Seconds,$Milliseconds) }
function Start-Process {
 param($FilePath,$ArgumentList,[switch]$NoNewWindow,[switch]$PassThru)
 $global:launches++
 if($env:TEST_MODE -ne 'child_failure') {
  $folder=Join-Path ($ArgumentList[-1].Trim('"')) 'idle-input-synthetic'
  [void][IO.Directory]::CreateDirectory($folder)
  [IO.File]::WriteAllText((Join-Path $folder 'capture.json'),'{}')
 }
 [pscustomobject]@{HasExited=$true;ExitCode=0}
}
try { & $env:TEST_SCRIPT -ResultsRoot $env:TEST_RESULTS -ValidateOnly:($env:TEST_MODE -eq 'validate') }
finally {
 $calls=@{state=$global:state;starts=$global:starts;stops=$global:stops;launches=$global:launches}
 [IO.File]::WriteAllText($env:TEST_CALLS,($calls | ConvertTo-Json))
}
'''


@unittest.skipUnless(PS, 'Windows PowerShell required')
class IdleServiceTests(unittest.TestCase):
    def exercise(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / SCRIPT.name
            shutil.copyfile(SCRIPT, script)
            (root / 'Save-VMInventory.ps1').write_text('param($ResultsRoot)\n')
            env = dict(os.environ, TEST_MODE=mode, TEST_SCRIPT=str(script),
                       TEST_RESULTS=str(root / 'results'), TEST_CALLS=str(root / 'calls.json'))
            result = subprocess.run([PS, '-NoProfile', '-ExecutionPolicy', 'Bypass',
                                     '-EncodedCommand', base64.b64encode(BACKEND.encode('utf-16le')).decode()],
                                    env=env, capture_output=True, text=True, timeout=30)
            calls = json.loads((root / 'calls.json').read_text())
            records = [json.loads(p.read_text()) for p in root.glob('results/*/restored.json')]
            return result, calls, records

    def test_validate_only_never_changes_or_launches(self):
        result, calls, records = self.exercise('validate')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((calls['starts'], calls['stops'], calls['launches']), (0, 0, 0))
        self.assertFalse(records)

    def test_wrong_baseline_refused(self):
        result, calls, records = self.exercise('baseline')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls['starts'], 0)
        self.assertFalse(records)

    def test_capture_publication_restores_baseline(self):
        result, calls, records = self.exercise('success')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((calls['starts'], calls['stops'], calls['launches']), (1, 1, 1))
        self.assertEqual(calls['state'], 'Stopped')
        self.assertTrue(records[0]['captureFound'])
        self.assertTrue(records[0]['stoppedVerified'])

    def test_partial_start_failure_still_restores(self):
        result, calls, records = self.exercise('partial')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((calls['stops'], calls['launches']), (1, 0))
        self.assertTrue(records[0]['stoppedVerified'])

    def test_child_failure_still_restores(self):
        result, calls, records = self.exercise('child_failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls['state'], 'Stopped')
        self.assertFalse(records[0]['captureFound'])

    def test_restoration_failure_is_not_reported_success(self):
        result, calls, records = self.exercise('stop_failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(records[0]['stoppedVerified'])
        self.assertIn('Synthetic stop failure', records[0]['restorationError'])


if __name__ == '__main__':
    unittest.main()
