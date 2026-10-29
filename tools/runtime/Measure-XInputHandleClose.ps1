[CmdletBinding(DefaultParameterSetName='Path')]
param(
    [Parameter(Mandatory=$true, ParameterSetName='List')][switch]$ListDevices,
    [Parameter(Mandatory=$true, ParameterSetName='Compile')][switch]$CompileOnly,
    [Parameter(Mandatory=$true, ParameterSetName='Path')][string]$DevicePath,
    [Parameter(Mandatory=$true, ParameterSetName='Index')][ValidateRange(0,31)][int]$DeviceIndex,
    [Parameter(Mandatory=$true, ParameterSetName='Path')]
    [Parameter(Mandatory=$true, ParameterSetName='Index')][string]$Condition,
    [Parameter(Mandatory=$true, ParameterSetName='Path')]
    [Parameter(Mandatory=$true, ParameterSetName='Index')][string]$OutputPath,
    [Parameter(ParameterSetName='Path')][Parameter(ParameterSetName='Index')][ValidateRange(1,500)][int]$Samples=100,
    [Parameter(ParameterSetName='Path')][Parameter(ParameterSetName='Index')][ValidateRange(1,30)][int]$Seconds=5
)
$ErrorActionPreference='Stop'
if (-not ('GameInputCloseResearch.Benchmark' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
namespace GameInputCloseResearch {
    public sealed class Sample {
        public int Index;
        public long OpenTicks, CloseTicks;
        public bool OpenSucceeded, CloseSucceeded;
        public int OpenError, CloseError;
    }
    public static class Benchmark {
        // Same interface class referenced by the inspected x86 XInput binary.
        static Guid InterfaceClass = new Guid("ec87f1e3-c13b-4100-b5f7-8b84d54260cb");
        [DllImport("cfgmgr32.dll", CharSet=CharSet.Unicode)]
        static extern uint CM_Get_Device_Interface_List_SizeW(out uint length, ref Guid cls, string id, uint flags);
        [DllImport("cfgmgr32.dll", CharSet=CharSet.Unicode)]
        static extern uint CM_Get_Device_Interface_ListW(ref Guid cls, string id, [Out] char[] buffer, uint length, uint flags);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return:MarshalAs(UnmanagedType.Bool)] static extern bool CloseHandle(IntPtr handle);
        public static string[] Interfaces() {
            for (int attempt=0; attempt<3; ++attempt) {
                uint length;
                uint code=CM_Get_Device_Interface_List_SizeW(out length, ref InterfaceClass, null, 0);
                if (code!=0) throw new InvalidOperationException("CM interface size failed: "+code);
                if (length<2) return new string[0];
                if (length>1048576) throw new InvalidOperationException("Unexpected interface list size");
                char[] buffer=new char[length];
                code=CM_Get_Device_Interface_ListW(ref InterfaceClass, null, buffer, length, 0);
                if (code==0) return new string(buffer).Split(new char[]{'\0'}, StringSplitOptions.RemoveEmptyEntries);
                if (code!=0x1a) throw new InvalidOperationException("CM interface list failed: "+code);
            }
            throw new InvalidOperationException("Interface list changed repeatedly; retry after reconnect settles");
        }
        public static Sample[] Measure(string path, int samples, int seconds) {
            if (samples<1 || samples>500 || seconds<1 || seconds>30) throw new ArgumentOutOfRangeException();
            bool present=false;
            foreach(string candidate in Interfaces()) if(String.Equals(candidate,path,StringComparison.OrdinalIgnoreCase)) present=true;
            if(!present) throw new ArgumentException("Path is not a currently present XInput interface");
            List<Sample> result=new List<Sample>(samples);
            Stopwatch budget=Stopwatch.StartNew();
            for(int i=0; i<samples && budget.Elapsed.TotalSeconds<seconds; ++i) {
                Sample row=new Sample(); row.Index=i;
                long before=Stopwatch.GetTimestamp();
                // Metadata-only handle, shared read/write, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL.
                // No ReadFile, WriteFile, DeviceIoControl, or vibration calls.
                IntPtr handle=CreateFileW(path,0,3,IntPtr.Zero,3,0x80,IntPtr.Zero);
                int error=Marshal.GetLastWin32Error();
                row.OpenTicks=Stopwatch.GetTimestamp()-before;
                row.OpenSucceeded=handle!=new IntPtr(-1);
                row.OpenError=row.OpenSucceeded?0:error;
                if(row.OpenSucceeded) {
                    before=Stopwatch.GetTimestamp();
                    row.CloseSucceeded=CloseHandle(handle);
                    error=Marshal.GetLastWin32Error();
                    row.CloseTicks=Stopwatch.GetTimestamp()-before;
                    row.CloseError=row.CloseSucceeded?0:error;
                }
                result.Add(row);
                if(!row.OpenSucceeded || !row.CloseSucceeded) break;
                // Cap offered load; this sleep is outside both timed API intervals.
                Thread.Sleep(10);
            }
            return result.ToArray();
        }
    }
}
'@
}
if ($CompileOnly) { Write-Output 'Compiled; no interfaces enumerated or device handles opened.'; return }
if ($ListDevices) {
    $paths=@([GameInputCloseResearch.Benchmark]::Interfaces())
    for ($i=0; $i -lt $paths.Count; $i++) { Write-Output "[$i] $($paths[$i])" }
    return
}
if ($PSCmdlet.ParameterSetName -eq 'Index') {
    $paths=@([GameInputCloseResearch.Benchmark]::Interfaces())
    if ($DeviceIndex -ge $paths.Count) { throw 'Requested interface index is absent; list devices again.' }
    $DevicePath=$paths[$DeviceIndex]
}

# This experiment is pinned to the research driver. Backing-file verification
# does not replace the separate debugger check of loaded module/device identity.
$driver=Join-Path $env:SystemRoot 'System32\drivers\xinputhid.sys'
$expected='c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f'
$driverHash=(Get-FileHash -LiteralPath $driver -Algorithm SHA256).Hash.ToLowerInvariant()
if ($driverHash -ne $expected) { throw 'This benchmark run is restricted to the inspected Windows 10 xinputhid binary.' }
$fullOutput=[IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $fullOutput) { throw 'Output already exists; preserve the previous run and choose another name.' }
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullOutput))
$start=[DateTime]::UtcNow
$watch=[Diagnostics.Stopwatch]::StartNew()
$rows=@([GameInputCloseResearch.Benchmark]::Measure($DevicePath,$Samples,$Seconds))
$watch.Stop()
$report=[ordered]@{
    schemaVersion=1
    purpose='Metadata-only open/close latency microbenchmark; not game FPS or XInput API fidelity'
    condition=$Condition
    startUtc=$start.ToString('o')
    elapsedSeconds=$watch.Elapsed.TotalSeconds
    qpcFrequency=[Diagnostics.Stopwatch]::Frequency
    processArchitecture=if ([IntPtr]::Size -eq 8) {'x64'} else {'x86'}
    osVersion=[Environment]::OSVersion.Version.ToString()
    driverPath=$driver; driverSha256=$driverHash
    scriptSha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    devicePath=$DevicePath
    services=@(Get-CimInstance Win32_Service -Filter "Name LIKE 'GameInput%'" | Select-Object Name,State,StartMode,ProcessId)
    requestedSamples=$Samples; requestedSeconds=$Seconds
    actualSamples=$rows.Count
    samples=$rows
    limitations=@(
        'Time/iteration bounds are checked between calls; an individual blocked kernel call has no hard timeout.',
        'API timing includes user-mode interop and scheduling; CloseHandle ticks include last-error retrieval.',
        'Metadata-only access differs from XInput enumeration and does not issue its inspection IOCTLs.',
        'Path membership does not prove the opened device stack; validate routing independently with the kernel debugger.',
        'Service inventory is after the timed run and does not prove unchanged service state throughout.',
        'Do not run with breakpoints that interrupt these calls; debugger pauses contaminate timings.',
        'Contains a potentially identifying interface path; keep output private under captures or artifacts.'
    )
}
$json=$report | ConvertTo-Json -Depth 7
$stream=[IO.File]::Open($fullOutput,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try {
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($json)
    $stream.Write($bytes,0,$bytes.Length)
} finally { $stream.Dispose() }
Write-Output "Saved $($rows.Count) open/close samples to $fullOutput"
if (@($rows | Where-Object { -not $_.OpenSucceeded -or -not $_.CloseSucceeded }).Count) {
    throw 'A handle operation failed; preserved the partial run. Do not treat it as a successful latency comparison.'
}
