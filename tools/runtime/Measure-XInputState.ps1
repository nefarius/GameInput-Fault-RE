[CmdletBinding(DefaultParameterSetName='Measure')]
param(
    [Parameter(Mandatory=$true,ParameterSetName='Compile')][switch]$CompileOnly,
    [Parameter(Mandatory=$true,ParameterSetName='Measure')][string]$Condition,
    [Parameter(Mandatory=$true,ParameterSetName='Measure')][string]$OutputPath,
    [Parameter(ParameterSetName='Measure')][ValidateRange(1,500)][int]$Cycles=100,
    [Parameter(ParameterSetName='Measure')][ValidateRange(1,30)][int]$Seconds=5
)
$ErrorActionPreference='Stop'
if (-not ('GameInputStateResearch.Benchmark' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;
namespace GameInputStateResearch {
    [StructLayout(LayoutKind.Sequential)] public struct Gamepad {
        public ushort Buttons; public byte LeftTrigger,RightTrigger;
        public short LeftX,LeftY,RightX,RightY;
    }
    [StructLayout(LayoutKind.Sequential)] public struct State { public uint Packet; public Gamepad Pad; }
    [StructLayout(LayoutKind.Sequential)] public struct Vibration { public ushort Left,Right; }
    public sealed class InputSample {
        public uint Slot,Result; public long Ticks;
        public uint? Packet; public ushort? Buttons; public byte? LeftTrigger,RightTrigger;
        public short? LeftX,LeftY,RightX,RightY;
    }
    public sealed class Sample {
        public int Cycle; public uint Slot,Result; public long Ticks; public uint? Packet;
    }
    public sealed class Measurement {
        public Sample[] Warmup,Samples; public double ElapsedSeconds;
    }
    public static class Benchmark {
        [StructLayout(LayoutKind.Sequential)] struct FileInformation {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation,Access,Write;
            public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
        }
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
        static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
        [DllImport("kernel32.dll",SetLastError=true)]
        [return:MarshalAs(UnmanagedType.Bool)]
        static extern bool GetFileInformationByHandle(SafeFileHandle file,out FileInformation information);
        // Compare the targets seen by this process, including WOW64 redirection
        // and hard links, rather than treating path spelling as file identity.
        public static bool SameFile(string left,string right) {
            using(SafeFileHandle a=CreateFileW(left,0,7,IntPtr.Zero,3,0x80,IntPtr.Zero)) {
                if(a.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                using(SafeFileHandle b=CreateFileW(right,0,7,IntPtr.Zero,3,0x80,IntPtr.Zero)) {
                    if(b.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                    FileInformation x,y;
                    if(!GetFileInformationByHandle(a,out x)) throw new Win32Exception(Marshal.GetLastWin32Error());
                    if(!GetFileInformationByHandle(b,out y)) throw new Win32Exception(Marshal.GetLastWin32Error());
                    if((x.IndexHigh==0 && x.IndexLow==0) || (y.IndexHigh==0 && y.IndexLow==0))
                        throw new InvalidOperationException("File identity unavailable");
                    return x.Volume==y.Volume && x.IndexHigh==y.IndexHigh && x.IndexLow==y.IndexLow;
                }
            }
        }
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
        static extern IntPtr LoadLibraryExW(string path,IntPtr file,uint flags);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
        static extern uint GetModuleFileNameW(IntPtr module,StringBuilder path,int size);
        [DllImport("kernel32.dll",CharSet=CharSet.Ansi,ExactSpelling=true,SetLastError=true)]
        static extern IntPtr GetProcAddress(IntPtr module,string name);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        delegate uint GetState(uint slot,out State state);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        delegate uint SetState(uint slot,ref Vibration vibration);
        static IntPtr module;
        static GetState getState;
        static SetState setState;
        // The retained module reference belongs only to this benchmark process.
        public static string Load(string fullPath) {
            if(module!=IntPtr.Zero) throw new InvalidOperationException("Use a fresh benchmark process");
            if(Marshal.SizeOf(typeof(State))!=16) throw new InvalidOperationException("Wrong XINPUT_STATE layout");
            module=LoadLibraryExW(fullPath,IntPtr.Zero,0x800);
            if(module==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            StringBuilder path=new StringBuilder(32768);
            uint size=GetModuleFileNameW(module,path,path.Capacity);
            if(size==0 || size>=path.Capacity) throw new InvalidOperationException("Cannot identify loaded XInput module");
            return path.ToString();
        }
        public static void Bind() {
            if(module==IntPtr.Zero) throw new InvalidOperationException("Load the verified module first");
            IntPtr address=GetProcAddress(module,"XInputGetState");
            if(address==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            getState=(GetState)Marshal.GetDelegateForFunctionPointer(address,typeof(GetState));
        }
        static Sample Read(int cycle,uint slot) {
            State state;
            long start=Stopwatch.GetTimestamp();
            uint result=getState(slot,out state);
            long elapsed=Stopwatch.GetTimestamp()-start;
            // XInput returns its error code directly; no GetLastError or error-buffer read.
            Sample row=new Sample {Cycle=cycle,Slot=slot,Result=result,Ticks=elapsed};
            if(result==0) row.Packet=state.Packet;
            return row;
        }
        static bool Expected(Sample sample) { return sample.Result==0 || sample.Result==1167; }
        public static Sample ReadSingle(uint slot) {
            if(slot>3) throw new ArgumentOutOfRangeException("slot");
            if(getState==null) throw new InvalidOperationException("Bind the verified module first");
            return Read(-1,slot);
        }
        public static InputSample ReadInput(uint slot) {
            if(slot>3) throw new ArgumentOutOfRangeException("slot");
            if(getState==null) throw new InvalidOperationException("Bind the verified module first");
            State state; long start=Stopwatch.GetTimestamp();
            uint result=getState(slot,out state);
            InputSample row=new InputSample {Slot=slot,Result=result,Ticks=Stopwatch.GetTimestamp()-start};
            if(result==0) {
                row.Packet=state.Packet; row.Buttons=state.Pad.Buttons;
                row.LeftTrigger=state.Pad.LeftTrigger; row.RightTrigger=state.Pad.RightTrigger;
                row.LeftX=state.Pad.LeftX; row.LeftY=state.Pad.LeftY;
                row.RightX=state.Pad.RightX; row.RightY=state.Pad.RightY;
            }
            return row;
        }
        public static uint SetVibration(uint slot,ushort left,ushort right) {
            if(slot>3 || left>16384 || right>16384) throw new ArgumentOutOfRangeException();
            if(module==IntPtr.Zero) throw new InvalidOperationException("Load the verified module first");
            if(setState==null) {
                IntPtr address=GetProcAddress(module,"XInputSetState");
                if(address==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                setState=(SetState)Marshal.GetDelegateForFunctionPointer(address,typeof(SetState));
            }
            Vibration value=new Vibration {Left=left,Right=right};
            return setState(slot,ref value);
        }
        public static Measurement Run(int cycles,int seconds) {
            if(cycles<1 || cycles>500 || seconds<1 || seconds>30) throw new ArgumentOutOfRangeException();
            if(getState==null) throw new InvalidOperationException("Bind the verified module first");
            List<Sample> warmup=new List<Sample>(4),rows=new List<Sample>(cycles*4);
            bool valid=true;
            for(uint slot=0;slot<4 && valid;++slot) {
                Sample row=Read(-1,slot); warmup.Add(row); valid=Expected(row);
            }
            Stopwatch budget=Stopwatch.StartNew();
            for(int cycle=0;cycle<cycles && valid && budget.Elapsed.TotalSeconds<seconds;++cycle) {
                for(uint slot=0;slot<4 && valid && budget.Elapsed.TotalSeconds<seconds;++slot) {
                    Sample row=Read(cycle,slot); rows.Add(row); valid=Expected(row);
                }
                if(valid) Thread.Sleep(10);
            }
            budget.Stop();
            return new Measurement {Warmup=warmup.ToArray(),Samples=rows.ToArray(),ElapsedSeconds=budget.Elapsed.TotalSeconds};
        }
    }
}
'@
}
if ($CompileOnly) { Write-Output 'Compiled; no DLL loaded and no controller state queried.'; return }
if ([IntPtr]::Size -ne 4 -or -not [Environment]::Is64BitOperatingSystem) {
    throw 'Run this experiment in x86 Windows PowerShell on the prepared x64 Windows 10 guest.'
}
$fullOutput=[IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $fullOutput) { throw 'Output already exists; preserve the previous run and choose another name.' }
$driver=Join-Path $env:SystemRoot 'Sysnative\drivers\xinputhid.sys'
$dll=Join-Path $env:SystemRoot 'SysWOW64\XInput1_4.dll'
$driverHash=(Get-FileHash -LiteralPath $driver -Algorithm SHA256).Hash.ToLowerInvariant()
$dllHash=(Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash.ToLowerInvariant()
if ($driverHash -ne 'c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f' -or
    $dllHash -ne 'afcef57f5c6068cedb49ddb370a8d070867fd47fcc8a67fd11694053885dec8d') {
    throw 'This experiment requires the exact research xinputhid and x86 XInput binaries.'
}
$loadedPath=[GameInputStateResearch.Benchmark]::Load($dll)
if (-not [GameInputStateResearch.Benchmark]::SameFile($loadedPath,$dll)) {
    throw 'Loaded XInput module does not resolve to the verified file in this process filesystem view.'
}
$loadedHash=(Get-FileHash -LiteralPath $loadedPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($loadedHash -ne $dllHash) { throw 'Loaded XInput backing-file hash differs from the verified file.' }
[GameInputStateResearch.Benchmark]::Bind()
$start=[DateTime]::UtcNow
$measurement=[GameInputStateResearch.Benchmark]::Run($Cycles,$Seconds)
$version=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$report=[ordered]@{
    schemaVersion=1; purpose='x86 XInputGetState call latency by slot and return code; not game FPS or complete input fidelity'
    condition=$Condition; startUtc=$start.ToString('o'); elapsedSeconds=$measurement.ElapsedSeconds
    qpcFrequency=[Diagnostics.Stopwatch]::Frequency; processArchitecture='x86'; processId=$PID
    osBuild=$version.CurrentBuild; osUBR=$version.UBR
    driverPath=$driver; driverSha256=$driverHash
    expectedXInputPath=$dll; loadedXInputPath=$loadedPath
    loadedXInputSameFileAsExpected=$true; loadedXInputBackingFileSha256=$loadedHash
    loadedXInputFileVersion=(Get-Item -LiteralPath $loadedPath).VersionInfo.FileVersion
    scriptSha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    services=@(Get-CimInstance Win32_Service -Filter "Name LIKE 'GameInput%'" | Select-Object Name,State,StartMode,ProcessId)
    requestedCycles=$Cycles; requestedSeconds=$Seconds; actualCalls=$measurement.Samples.Count
    warmup=@($measurement.Warmup); samples=@($measurement.Samples)
    limitations=@(
        'One warmup call per slot is retained separately from timed samples.',
        'startUtc precedes warmup; elapsedSeconds describes the timed loop only.',
        'Result 1167 is an expected disconnected slot, not a successful reading; packet is null on any error.',
        'Each cycle queries slots 0 through 3 then sleeps 10 ms outside timed calls; this is benchmark pacing, not a driver mitigation.',
        'Bounds apply between API calls; a blocked call has no hard timeout.',
        'DLL backing-file identity is verified after loading; relocated module memory is not hashed.',
        'Call duration includes interop and scheduling, not a measured kernel pending-I/O lifetime.',
        'Service inventory is post-run. Slot-to-physical-controller mapping and per-call device routing need independent evidence.',
        'Successful state queries and packet changes do not establish complete input delivery, vibration, or game frame times.',
        'Do not interrupt timed calls with debugger breakpoints; retain failed and partial runs.'
    )
}
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullOutput))
$json=$report | ConvertTo-Json -Depth 8
$stream=[IO.File]::Open($fullOutput,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try { $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($json); $stream.Write($bytes,0,$bytes.Length) }
finally { $stream.Dispose() }
Write-Output "Saved $($measurement.Samples.Count) timed XInput calls to $fullOutput"
$unexpected=@(@($measurement.Warmup)+@($measurement.Samples) | Where-Object { $_.Result -ne 0 -and $_.Result -ne 1167 })
if ($unexpected.Count -or $measurement.Samples.Count -eq 0) { throw 'Incomplete run or unexpected XInput error; partial evidence preserved.' }
