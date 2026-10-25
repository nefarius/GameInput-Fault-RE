[CmdletBinding()]
param(
    [ValidateRange(1,60)][int]$Seconds = 5,
    [switch]$Rumble,
    [string]$OutputPath
)
$ErrorActionPreference = 'Stop'
if (-not ('GameInputResearch.XInput' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace GameInputResearch {
    [StructLayout(LayoutKind.Sequential)] public struct Gamepad {
        public ushort Buttons; public byte LeftTrigger, RightTrigger;
        public short LeftX, LeftY, RightX, RightY;
    }
    [StructLayout(LayoutKind.Sequential)] public struct State {
        public uint Packet; public Gamepad Gamepad;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Vibration {
        public ushort LeftMotor, RightMotor;
    }
    public static class XInput {
        [DllImport("xinput1_4.dll")] public static extern uint XInputGetState(uint index, out State state);
        [DllImport("xinput1_4.dll")] public static extern uint XInputSetState(uint index, ref Vibration state);
    }
}
'@
}
$start = [DateTime]::UtcNow
$devices = @()
for ($index=0; $index -lt 4; $index++) {
    $state = New-Object GameInputResearch.State
    $result = [GameInputResearch.XInput]::XInputGetState($index, [ref]$state)
    if ($result -eq 0) { $devices += [pscustomobject]@{ index=$index; packet=$state.Packet } }
}
$samples = @()
$watch = [Diagnostics.Stopwatch]::StartNew()
$activeRumble = @()
try {
    if ($Rumble) {
        foreach ($device in $devices) {
            $v = New-Object GameInputResearch.Vibration
            $v.LeftMotor=8192
            $v.RightMotor=8192
            $activeRumble += $device.index
            $code=[GameInputResearch.XInput]::XInputSetState($device.index,[ref]$v)
            if ($code -ne 0) { Write-Warning "Rumble request for slot $($device.index) failed: $code" }
        }
        Start-Sleep -Milliseconds 500
        foreach ($i in $activeRumble) {
            $v = New-Object GameInputResearch.Vibration
            [void][GameInputResearch.XInput]::XInputSetState($i,[ref]$v)
        }
    }
    while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
        foreach ($device in $devices) {
            $state = New-Object GameInputResearch.State
            $result = [GameInputResearch.XInput]::XInputGetState($device.index,[ref]$state)
            $samples += [pscustomobject]@{ elapsedMs=[math]::Round($watch.Elapsed.TotalMilliseconds,3); index=$device.index; result=$result; packet=$state.Packet }
        }
        Start-Sleep -Milliseconds 16
    }
} finally {
    foreach ($i in $activeRumble) {
        $v = New-Object GameInputResearch.Vibration
        [void][GameInputResearch.XInput]::XInputSetState($i,[ref]$v)
    }
}
$report = [ordered]@{
    schemaVersion=1; startUtc=$start.ToString('o'); durationSeconds=$watch.Elapsed.TotalSeconds
    purpose='XInput discovery / deliberate input and rumble stimulus, not IOCTL proof'
    rumbleRequested=[bool]$Rumble; devices=$devices; samples=$samples
}
$json = $report | ConvertTo-Json -Depth 6
if ($OutputPath) {
    $full=[IO.Path]::GetFullPath($OutputPath)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
    [IO.File]::WriteAllText($full,$json,(New-Object Text.UTF8Encoding($false)))
}
$json
