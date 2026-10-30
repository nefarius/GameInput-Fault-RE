"""Synthetic bracket classification and compile/refusal checks, without hardware."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'tools/runtime/Measure-DsHidMiniInputPair.ps1'
PS64 = shutil.which('powershell.exe')
PS32 = Path(os.environ.get('WINDIR', 'C:/Windows')) / 'SysWOW64/WindowsPowerShell/v1.0/powershell.exe'


@unittest.skipUnless(PS64, 'Windows PowerShell required')
class DsRawPairTests(unittest.TestCase):
    def run_ps(self, code, executable=PS64):
        return subprocess.run(
            [str(executable), '-NoProfile', '-ExecutionPolicy', 'Bypass',
             '-EncodedCommand', base64.b64encode(code.encode('utf-16le')).decode()],
            env=dict(os.environ, DSRAW_PAIR=str(SCRIPT)),
            capture_output=True, text=True, timeout=30)

    def test_compile_x64(self):
        result = self.run_ps('& $env:DSRAW_PAIR -CompileOnly')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('no mapping opened, DLL loaded or controller queried', result.stdout)

    @unittest.skipUnless(PS32.exists(), 'x86 Windows PowerShell required')
    def test_compile_x86(self):
        result = self.run_ps('& $env:DSRAW_PAIR -CompileOnly', PS32)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_changed_missing_unstable_and_other_slot_are_not_stable_brackets(self):
        result = self.run_ps('''
. $env:DSRAW_PAIR -CompileOnly | Out-Null
$a=[pscustomobject]@{Status='stable'; Index=1; Sequence=2; ReportHex='01'}
$b=[pscustomobject]@{Status='stable'; Index=1; Sequence=2; ReportHex='01'}
$results=@(Test-StableIpcBracket $a $b)
$b.Sequence=4; $results+=Test-StableIpcBracket $a $b
$b.Sequence=2; $b.ReportHex='02'; $results+=Test-StableIpcBracket $a $b
$b.ReportHex='01'; $b.Status='unstable'; $results+=Test-StableIpcBracket $a $b
$b.Status='stable'; $b.Index=2; $results+=Test-StableIpcBracket $a $b
$results+=Test-StableIpcBracket $null $a
$results | ConvertTo-Json -Compress
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [True, False, False, False, False, False])

    def test_native_x64_recording_is_refused(self):
        result = self.run_ps('& $env:DSRAW_PAIR')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Use x86 Windows PowerShell', result.stderr)

    def test_single_service_result_and_invalid_baselines_in_windows_powershell(self):
        result = self.run_ps('''
. $env:DSRAW_PAIR -CompileOnly | Out-Null
# Mock only the read-only CIM boundary, preserving actual selection/unrolling.
function Get-CimInstance { [pscustomobject]@{Name='GameInputSvc';State='Stopped';StartMode='Manual';ProcessId=0} }
$services=@(Get-PairService)
Assert-PairServiceBaseline $services
$accepted=@()
$cases=@(
    @{rows=@()},
    @{rows=@([pscustomobject]@{State='Running';StartMode='Manual'})},
    @{rows=@([pscustomobject]@{State='Stopped';StartMode='Auto'})},
    @{rows=@($services[0],$services[0])}
)
foreach ($case in $cases) {
    try { Assert-PairServiceBaseline $case.rows; $accepted+=$true }
    catch {
        if ($_.Exception.Message -notlike '*Observed:*') { throw }
        $accepted+=$false
    }
}
[pscustomobject]@{count=$services.Count; acceptedInvalid=$accepted} | ConvertTo-Json -Compress
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            'count': 1, 'acceptedInvalid': [False, False, False, False]})


if __name__ == '__main__':
    unittest.main()
