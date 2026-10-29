"""Exercise runner dispatch and motor-stop cleanup with a synthetic API backend."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
RUNNER=ROOT/"tools/runtime/Start-VMValidation.ps1"
PS32=Path(os.environ.get("WINDIR","C:/Windows"))/"SysWOW64/WindowsPowerShell/v1.0/powershell.exe"

BACKEND=r'''
using System;
using System.Collections.Generic;
namespace GameInputStateResearch {
    public sealed class Row { public uint Slot,Result; public uint? Packet; public ushort? Buttons; }
    public sealed class Measurement { public Row[] Samples,Warmup; public double ElapsedSeconds; }
    public static class Benchmark {
        public static List<string> Log=new List<string>();
        public static bool Motor,FailDuring,FailStopOnce;
        public static string Load(string path) { return path; }
        public static bool SameFile(string a,string b) { return true; }
        public static void Bind() {}
        public static Row ReadSingle(uint slot) {
            Log.Add("single:"+slot);
            return new Row {Slot=slot,Result=slot==0?0u:1167u,Packet=slot==0?(uint?)1:null};
        }
        public static Row ReadInput(uint slot) {
            Log.Add("input:"+slot);
            if(Motor && FailDuring) throw new Exception("synthetic capture failure");
            return new Row {Slot=slot,Result=0,Packet=1,Buttons=0x1000};
        }
        public static uint SetVibration(uint slot,ushort left,ushort right) {
            Log.Add("vibration:"+slot+":"+left+":"+right);
            if(left==0 && right==0 && FailStopOnce) { FailStopOnce=false; return 5; }
            Motor=left!=0 || right!=0; return 0;
        }
        public static Measurement Run(int cycles,int seconds) {
            Log.Add("benchmark:"+cycles+":"+seconds);
            return new Measurement {Samples=new Row[0],Warmup=new Row[0],ElapsedSeconds=0};
        }
    }
}
'''

HARNESS=r'''
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:VM_TEST_BACKEND)))
[GameInputStateResearch.Benchmark]::FailDuring=($env:VM_TEST_SCENARIO -like 'rumble-*')
[GameInputStateResearch.Benchmark]::FailStopOnce=($env:VM_TEST_SCENARIO -eq 'rumble-stop-retry')
function Get-FileHash {
    param($LiteralPath)
    $hash='0'*64
    if ($LiteralPath -like '*xinputhid.sys') { $hash='c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f' }
    if ($LiteralPath -like '*XInput1_4.dll') { $hash='afcef57f5c6068cedb49ddb370a8d070867fd47fcc8a67fd11694053885dec8d' }
    [pscustomobject]@{Hash=$hash}
}
function Get-CimInstance { [pscustomobject]@{Name='GameInputSvc';State='Running';StartMode='Manual';ProcessId=42} }
function Read-Host { param($Prompt) if($Prompt -like 'Did vibration*') {'yes'} elseif($Prompt -like 'What did*') {'synthetic held A'} else {'READY'} }
$global:VMTestSeeded=$false
function Get-ChildItem {
    param($LiteralPath,$Filter,[switch]$File)
    if (-not $global:VMTestSeeded) {
        $global:VMTestSeeded=$true
        $ready=Get-Content (Join-Path $LiteralPath 'session.ready.json') -Raw | ConvertFrom-Json
        $commands=@()
        if ($env:VM_TEST_SCENARIO -eq 'command-limit') {
            foreach($number in 0..69) {
                $commands+=@{id=('route-'+$number);kind='route';slot=1;sessionId=$ready.sessionId}
            }
        } elseif ($env:VM_TEST_SCENARIO -like 'rumble-*') {
            $commands+=@{id='rumble';kind='rumble';slot=0;sessionId=$ready.sessionId}
        } else {
            $commands+=@{id='foreign';kind='route';slot=1;sessionId='wrong-session'}
            $commands+=@{id='unknown';kind='execute';sessionId=$ready.sessionId}
            $commands+=@{id='route';kind='route';slot=1;sessionId=$ready.sessionId}
            $commands+=@{id='benchmark';kind='benchmark';cycles=1;seconds=1;sessionId=$ready.sessionId}
            $commands+=@{id='input';kind='input';phase='hold-a';milliseconds=100;sessionId=$ready.sessionId}
            $commands+=@{id='observe';kind='observe';sessionId=$ready.sessionId}
            $commands+=@{id='bad-range';kind='benchmark';cycles=101;sessionId=$ready.sessionId}
        }
        $commands+=@{id='stop';kind='stop';sessionId=$ready.sessionId}
        $index=0
        foreach($command in $commands) {
            $path=Join-Path $LiteralPath ('{0:d2}.command.json' -f $index)
            [IO.File]::WriteAllText($path,($command | ConvertTo-Json)); $index++
        }
    }
    Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $LiteralPath -Filter $Filter -File
}
& $env:VM_TEST_RUNNER -ResultsRoot $env:VM_TEST_ROOT -SessionMinutes 1
[IO.File]::WriteAllText((Join-Path $env:VM_TEST_ROOT 'api-log.json'),([GameInputStateResearch.Benchmark]::Log | ConvertTo-Json))
'''


@unittest.skipUnless(PS32.is_file(),"x86 Windows PowerShell required")
class VMRunnerTests(unittest.TestCase):
    def run_scenario(self,scenario):
        with tempfile.TemporaryDirectory() as directory:
            env=dict(os.environ,VM_TEST_RUNNER=str(RUNNER),VM_TEST_ROOT=directory,
                     VM_TEST_SCENARIO=scenario,VM_TEST_BACKEND=base64.b64encode(BACKEND.encode()).decode())
            encoded=base64.b64encode(HARNESS.encode('utf-16le')).decode()
            result=subprocess.run([str(PS32),'-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',encoded],
                                  env=env,capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stderr)
            root=Path(directory)
            session=next(p for p in root.iterdir() if p.is_dir())
            records={p.name:json.loads(p.read_text(encoding='utf-8-sig')) for p in session.glob('*.result.json')}
            ended=json.loads((session/'session.ended.json').read_text(encoding='utf-8-sig'))
            log=json.loads((root/'api-log.json').read_text())
            return records,ended,log

    def test_closed_dispatch_range_limits_and_observation_do_not_vibrate(self):
        records,ended,log=self.run_scenario('observation')
        self.assertNotIn('foreign.result.json',records)
        self.assertNotIn('unknown.result.json',records)
        self.assertEqual(records['route.result.json']['data']['sample']['Slot'],1)
        self.assertFalse(records['route.result.json']['timingEligible'])
        self.assertTrue(records['benchmark.result.json']['timingEligible'])
        self.assertEqual(records['input.result.json']['status'],'completed')
        self.assertEqual(records['input.result.json']['data']['operatorReport'],'synthetic held A')
        self.assertEqual(records['bad-range.result.json']['status'],'failed')
        self.assertEqual(log.count('benchmark:1:1'),1)
        self.assertFalse(any(x.startswith('vibration:') for x in log))
        self.assertEqual(ended['reason'],'host_requested_stop')
        self.assertEqual(ended['motorStopAttempts'],[])

    def test_rumble_stop_survives_capture_failure_and_partial_result_is_saved(self):
        records,ended,log=self.run_scenario('rumble-failure')
        failed=records['rumble.result.json']
        self.assertEqual(failed['status'],'failed')
        self.assertIn('synthetic capture failure',failed['error'])
        self.assertEqual(failed['data']['startResult'],0)
        self.assertTrue(failed['data']['stopAttempted'])
        self.assertEqual(failed['data']['stopResult'],0)
        self.assertEqual([x for x in log if x.startswith('vibration:')],
                         ['vibration:0:8192:8192','vibration:0:0:0'])
        self.assertEqual(ended['motorStopAttempts'],[])

    def test_failed_stop_is_retained_and_retried_during_session_cleanup(self):
        records,ended,log=self.run_scenario('rumble-stop-retry')
        self.assertEqual(records['rumble.result.json']['status'],'failed')
        self.assertEqual(records['rumble.result.json']['data']['stopResult'],5)
        self.assertEqual([x for x in log if x.startswith('vibration:')],
                         ['vibration:0:8192:8192','vibration:0:0:0','vibration:0:0:0'])
        self.assertEqual(ended['motorStopAttempts'],[{'slot':0,'stopResult':0}])

    def test_prequeued_batch_cannot_exceed_command_limit(self):
        records,ended,log=self.run_scenario('command-limit')
        self.assertEqual(len(records),64)
        self.assertEqual(ended['completedOrFailedCommands'],64)
        self.assertEqual(ended['reason'],'command_limit')
        self.assertEqual(log.count('single:1'),65)  # One initial slot read, 64 cases.
