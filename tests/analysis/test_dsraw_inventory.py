"""Exercise the read-only IPC reader against a synthetic local mapping."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'tools/runtime/Save-DsHidMiniInputInventory.ps1'
POWERSHELL = shutil.which('powershell.exe')


@unittest.skipUnless(POWERSHELL, 'Windows PowerShell required')
class DsRawInventoryTests(unittest.TestCase):
    def run_ps(self, code):
        return subprocess.run(
            [POWERSHELL, '-NoProfile', '-ExecutionPolicy', 'Bypass',
             '-EncodedCommand', base64.b64encode(code.encode('utf-16le')).decode()],
            env=dict(os.environ, DSRAW_SCRIPT=str(SCRIPT)),
            capture_output=True, text=True, timeout=30)

    def test_compile_only(self):
        result = self.run_ps('& $env:DSRAW_SCRIPT -CompileOnly')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('no mapping opened or configuration read', result.stdout)

    def test_missing_mapping_is_unavailable(self):
        result = self.run_ps('''
. $env:DSRAW_SCRIPT -CompileOnly | Out-Null
[DsRawInventory]::Read('Local\DoesNotExist-'+[guid]::NewGuid()) | ConvertTo-Json -Compress
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(value['Status'], 'open-unavailable')
        self.assertEqual(value['Win32Error'], 2)
        self.assertIsNone(value['Slots'])

    def test_stable_odd_empty_and_mismatched_slots(self):
        result = self.run_ps('''
. $env:DSRAW_SCRIPT -CompileOnly | Out-Null
Add-Type -AssemblyName System.Core
$name='Local\DsRawTest-'+[guid]::NewGuid()
$map=[IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($name,131072)
$view=$map.CreateViewAccessor()
try {
    $offset=65536
    $view.Write($offset,[int]1); $view.Write($offset+4,[int]2)
    $bytes=[byte[]](0..48)
    $view.WriteArray($offset+8,$bytes,0,49)
    $view.Write($offset+60,[int]2); $view.Write($offset+64,[int]3)
    $view.Write($offset+180,[int]99); $view.Write($offset+184,[int]4)
    [DsRawInventory]::Read($name) | ConvertTo-Json -Depth 8 -Compress
} finally { $view.Dispose(); $map.Dispose() }
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(value['Status'], 'mapped-read-only')
        slots = value['Slots']
        self.assertEqual(len(slots), 32)
        self.assertEqual(slots[0]['Status'], 'stable')
        self.assertEqual(slots[0]['ReportHex'], bytes(range(49)).hex())
        self.assertEqual(slots[0]['Sequence'], 2)
        self.assertEqual(slots[1]['Status'], 'unstable')
        self.assertEqual(slots[1]['Attempts'], 8)
        self.assertIsNone(slots[1]['ReportHex'])
        self.assertEqual(slots[2]['Status'], 'empty')
        self.assertIsNone(slots[2]['ReportHex'])
        self.assertEqual(slots[3]['Status'], 'index-mismatch')
        self.assertIsNone(slots[3]['ReportHex'])


if __name__ == '__main__':
    unittest.main()
