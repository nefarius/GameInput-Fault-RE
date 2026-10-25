#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$ProbeOnly,[switch]$ActiveInput,[ValidateSet('USB','Bluetooth')][string]$Connection='USB')
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$out = Join-Path $root ('artifacts/runtime/validation-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
[void][IO.Directory]::CreateDirectory($out)
$outcome = [ordered]@{ schema_version=1; started_utc=[DateTime]::UtcNow.ToString('o'); status='running'; errors=@(); probe_logs=@(); mitigation='not_requested'; evidence_limitations=@('Input transitions, latency, frame time, reconnect and shutdown require separate validation.') }
$outcome.connection=$Connection
$probe = Join-Path $root 'tools/probe/Invoke-GameInputResearch.ps1'
$transcript = $false
function Invoke-ResearchPhase {
    param([string]$Action,[string]$Phase,[int]$Seconds)
    try { & $probe -Action $Action -Phase $Phase -DurationSeconds $Seconds | Out-Host }
    catch { $outcome.errors += ($Action + ': ' + $_.Exception.Message); Write-Warning $_ }
}
try {
    Start-Transcript -Path (Join-Path $out 'validation.log') -Force | Out-Null
    $transcript = $true
    $collector = Join-Path $root 'tools/collector/Collect-Diagnostics.ps1'
    # Separate process because the collector intentionally returns a process exit code.
    $ps = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    if (-not $ProbeOnly) {
      & $ps -NoProfile -ExecutionPolicy Bypass -File $collector -Consent -NonInteractive `
        -Phases idle -PhaseSeconds 10 -PreparationSeconds 0 -MaxTraceSeconds 30 `
        -Controller 'Xbox One (operator supplied)' -Connection $Connection -WorkaroundState disabled `
        -OutputDirectory (Join-Path $out 'collector') 2>&1 | Out-Host
      $outcome.collector_exit_code = $LASTEXITCODE
    }
    & (Join-Path $PSScriptRoot 'Test-Controller.ps1') -Seconds 2 -OutputPath (Join-Path $out 'controller-idle.json') | Out-Null
    Invoke-ResearchPhase List idle 1
    # Attach is a bounded capture which detaches in its own cleanup. All native
    # samplers stay alive through the phase to avoid per-sample process churn.
    if ($ActiveInput) {
        $monitorArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $PSScriptRoot 'Test-Controller.ps1')+'"'),'-Seconds','60','-OutputPath',('"'+(Join-Path $out 'controller-active.json')+'"'))
        $monitor=Start-Process -FilePath $ps -ArgumentList $monitorArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $out 'controller-monitor.stdout') -RedirectStandardError (Join-Path $out 'controller-monitor.stderr')
        Invoke-ResearchPhase Attach active_input 45
        [void]$monitor.WaitForExit(20000)
    } else { Invoke-ResearchPhase Attach idle 30 }
    # Deliberate, brief rumble stimulus. The helper resets motors in finally.
    & (Join-Path $PSScriptRoot 'Test-Controller.ps1') -Rumble -Seconds 2 -OutputPath (Join-Path $out 'controller-rumble.json') | Out-Null
    Invoke-ResearchPhase Attach post_rumble 10
    # A hardware throttle trial is gated by observed evidence. Do not turn a
    # successful build or the existence of a loop into a positive diagnosis.
    $outcome.mitigation = 'withheld_pending_review_of_observation_and_cpu_trace'
    $outcome.status = if ($outcome.errors.Count) { 'incomplete' } else { 'observation_completed_review_required' }
} catch {
    $outcome.status = 'failed'
    $outcome.errors += $_.Exception.ToString()
} finally {
    Invoke-ResearchPhase Disable cleanup 1
    $outcome.finished_utc = [DateTime]::UtcNow.ToString('o')
    $begin = [DateTime]::Parse($outcome.started_utc).ToUniversalTime()
    $outcome.probe_logs = @(Get-ChildItem (Join-Path $root 'captures') -Recurse -Filter research.jsonl -ErrorAction SilentlyContinue |
        Where-Object {$_.LastWriteTimeUtc -ge $begin} | ForEach-Object {$_.FullName})
    $json = $outcome | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $out 'result.json'),$json,(New-Object Text.UTF8Encoding($false)))
    if ($transcript) { Stop-Transcript | Out-Null }
}
Write-Output $out
if ($outcome.status -eq 'failed') { exit 1 }
