[CmdletBinding()]
param(
    [string]$ResultsRoot='\\vmware-host\Shared Folders\GameInputResults',
    [ValidateRange(1,30)][int]$Seconds=30,
    [switch]$CompileOnly
)
$ErrorActionPreference='Stop'
$native=Join-Path $PSScriptRoot 'Measure-XInputState.ps1'
# Allow the reviewed source's LF and CRLF checkout encodings; record actual bytes.
$nativePin=(Get-FileHash -LiteralPath $native).Hash.ToLowerInvariant()
if ($nativePin -notin @('a7dee09f72eddcb6590ec5ddf7a360ecee51687b9eb73669cff100683b6d1083',
    '1cc7a16f6468016d3d03c5614af7c045f27fe1285cabbaa5c7d9c44cc37d098a')) { throw 'Native source differs from this experiment.' }
& $native -CompileOnly
if ($CompileOnly) { Write-Output 'Compiled; no XInput DLL loaded or controller queried.'; return }
if ([IntPtr]::Size -ne 4) { throw 'Use x86 Windows PowerShell in the prepared guest.' }
$driver=Join-Path $env:WINDIR 'Sysnative\drivers\xinputhid.sys'
$dll=Join-Path $env:WINDIR 'SysWOW64\XInput1_4.dll'
$driverHash=(Get-FileHash -LiteralPath $driver).Hash.ToLowerInvariant()
$dllHash=(Get-FileHash -LiteralPath $dll).Hash.ToLowerInvariant()
if ($driverHash -ne 'c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f' -or
    $dllHash -ne 'afcef57f5c6068cedb49ddb370a8d070867fd47fcc8a67fd11694053885dec8d') { throw 'Prepared binary identity mismatch.' }
$loaded=[GameInputStateResearch.Benchmark]::Load($dll)
if (-not [GameInputStateResearch.Benchmark]::SameFile($loaded,$dll) -or
    (Get-FileHash -LiteralPath $loaded).Hash.ToLowerInvariant() -ne $dllHash) { throw 'Loaded XInput identity mismatch.' }
[GameInputStateResearch.Benchmark]::Bind()
Write-Host "Move the LEFT stick continuously in circles for $Seconds seconds after READY, until Done. No vibration is requested."
if ((Read-Host 'Type READY to begin') -ine 'READY') { throw 'Cancelled before input window.' }
$id=[guid]::NewGuid().ToString('N')
$prefix=Join-Path $ResultsRoot ('active-input-'+$id)
function Write-Record([string]$Path,$Value) {
    $temporary=$Path+'.tmp'
    [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
    [IO.File]::Move($temporary,$Path)
}
$version=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$record=[ordered]@{schemaVersion=1; phaseId=$id; startedUtc=[DateTime]::UtcNow.ToString('o'); processId=$PID; architecture='x86'
    build=$version.CurrentBuild; ubr=$version.UBR; requestedSeconds=$Seconds; maximumSamples=3000
    driverSha256=$driverHash; loadedXInputPath=$loaded; loadedXInputBackingSha256=$dllHash; sameFileAsExpected=$true
    nativeScriptSha256=$nativePin; scriptSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant()
    timingEligible=$false; operatorReport=$null; error=$null}
Write-Record ($prefix+'.started.json') $record
$rows=New-Object 'Collections.Generic.List[object]'
$clock=[Diagnostics.Stopwatch]::StartNew()
try {
    while ($clock.Elapsed.TotalSeconds -lt $Seconds -and $rows.Count -lt 3000) {
        $rows.Add([pscustomobject]@{elapsedMilliseconds=$clock.Elapsed.TotalMilliseconds; sample=[GameInputStateResearch.Benchmark]::ReadInput(0)})
        Start-Sleep -Milliseconds 10
    }
    $clock.Stop()
    Write-Host 'Done; release the stick.'
    $record.operatorReport=Read-Host 'What did you physically move during this window?'
} catch { $record.error=$_.Exception.Message }
finally {
    $clock.Stop(); $record.elapsedSeconds=$clock.Elapsed.TotalSeconds; $record.rows=@($rows.ToArray())
    $record.finishedUtc=[DateTime]::UtcNow.ToString('o')
    Write-Record ($prefix+'.result.json') $record
}
if ($null -ne $record.error) { throw $record.error }
Write-Output ('Saved bounded active-input window: '+$prefix+'.result.json')
