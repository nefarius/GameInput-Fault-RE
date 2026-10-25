#requires -Version 5.1
# Independent of the console: cancel only this collector's random WPR instance
# if its owner exits (including console close), hangs, or exceeds the deadline.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^GameInput_[0-9a-f]{32}$')][string]$InstanceName,
    [Parameter(Mandatory)][int]$OwnerProcessId,
    [Parameter(Mandatory)][long]$OwnerStartTicks,
    [Parameter(Mandatory)][string]$RunDirectory,
    [ValidateRange(30, 900)][int]$DeadlineSeconds = 480,
    [ValidateRange(128, 512)][int]$MaxOutputMB = 256
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Collector.Common.ps1')
$clock = [Diagnostics.Stopwatch]::StartNew()
$reason = 'deadline'
try {
    'ready' | Set-Content -LiteralPath (Join-Path $RunDirectory 'watchdog.ready') -Encoding ASCII
    while ($clock.Elapsed.TotalSeconds -lt $DeadlineSeconds) {
        if (Test-Path -LiteralPath (Join-Path $RunDirectory 'watchdog.complete')) { return }
        try {
            $owner = Get-Process -Id $OwnerProcessId -ErrorAction Stop
            if ($owner.StartTime.ToUniversalTime().Ticks -ne $OwnerStartTicks) { $reason = 'owner-replaced'; break }
        } catch { $reason = 'owner-exited'; break }
        if ((Get-CollectorBytes $RunDirectory) -gt ($MaxOutputMB * 1MB)) { $reason = 'size-limit'; break }
        Start-Sleep -Milliseconds 500
    }
    $result = Invoke-CollectorCommand (Get-SystemTool 'wpr.exe') @('-cancel', '-instancename', $InstanceName) 30
    Write-CollectorJson (Join-Path $RunDirectory 'watchdog-result.json') ([ordered]@{
        Utc = [DateTime]::UtcNow.ToString('o'); Reason = $reason; Cancel = $result
    })
} catch {
    $_.ToString() | Set-Content -LiteralPath (Join-Path $RunDirectory 'watchdog-error.txt') -Encoding UTF8
}
