[CmdletBinding()]
param(
    [ValidateSet('List','Attach','Snapshot','Observe','Mitigate','Disable','Eject')][string]$Action = 'List',
    [ValidateSet('Observe','Mitigate')][string]$Mode = 'Observe',
    [ValidateRange(1,300)][int]$DurationSeconds = 10,
    [ValidateLength(1,128)][string]$Phase = 'research'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Action -eq 'Mitigate') { $Mode = 'Mitigate' }
if (-not [Environment]::Is64BitProcess -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) { throw 'This prototype requires x64 Windows and x64 PowerShell.' }
Import-Module (Join-Path $PSScriptRoot 'GameInput.Research.psm1') -Force
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$logDir = Join-Path $root ('captures/probe-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$log = Join-Path $logDir 'research.jsonl'
function Write-ResearchRecord {
    param([string]$Kind,$Target,$Snapshot,$Details)
    [ordered]@{ schema_version=1; timestamp_utc=[DateTime]::UtcNow.ToString('o'); kind=$Kind; action=$Action; mode=$Mode; phase=$Phase; target=$Target; snapshot=$Snapshot; details=$Details } |
        ConvertTo-Json -Depth 16 -Compress | Add-Content -LiteralPath $log -Encoding utf8
}
Write-Host "Local inventory/snapshot log: $log"
if ($Action -eq 'Eject') {
    Write-ResearchRecord blocked $null $null 'Probe ABI pins module until process exit; eject refused. Disable detaches hooks and retains module.'
    throw 'Eject refused: use Disable; the pinned module remains until process exit.'
}
if ($Action -ne 'List' -and -not (Test-ResearchAdministrator)) {
    Write-ResearchRecord blocked $null $null 'Administrator rights required for attach/control. List supports partial nonadministrator inventory.'
    throw 'Run PowerShell as administrator for attach/control. List supports partial inventory without elevation.'
}
if ($Action -ne 'List') {
    try { Enable-ResearchDebugPrivilege; Write-ResearchRecord action $null $null 'SeDebugPrivilege enabled for exact-target inventory and control.' }
    catch { Write-ResearchRecord blocked $null $null $_.Exception.Message; throw }
}
$targets = @(Get-ResearchTargets)
foreach ($target in $targets) { Write-ResearchRecord inventory $target $null $null }
if ($Action -eq 'List') { $targets; return }
if ($targets.Count -eq 0) { throw 'No exact GameInput process families are running.' }
$failed = [Collections.Generic.List[string]]::new()
$ready = [Collections.Generic.List[object]]::new()
$workers = [Collections.Generic.List[object]]::new()
$capture = $Action -in @('Attach','Mitigate')
$controller = Join-Path $root 'tools/build/out/bin/Release/GameInputProbeController.exe'
foreach ($target in $targets) {
    try {
        if ($target.inactive_host) { Write-ResearchRecord action $target $null 'Inactive GameInput host has no core module; skipped.'; continue }
        if (-not $target.eligible) { throw ($target.blocked_reasons -join '; ') }
        if ($capture) {
            $injector = Get-ResearchInjector
            $probe = Join-Path $root 'tools/build/out/bin/Release/GameInputProbe.dll'
            if (-not (Test-Path -LiteralPath $probe)) { throw 'Fixed x64 Release probe DLL is missing. Build it first.' }
            $preflight = Invoke-ResearchController $target.pid verify
            $fresh = Get-Process -Id $target.pid -ErrorAction Stop
            if ($fresh.StartTime.ToUniversalTime().ToString('o') -ne $target.start_time_utc) { throw 'Process identity changed before injection.' }
            Write-ResearchRecord action $target $null @{ preflight=$preflight; probe_sha256=(Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash.ToLowerInvariant(); loader_pid_race='Separate Injector PID interface cannot eliminate exit/recycle race; post-load handshake required.' }
            if (-not $preflight.probe_loaded) {
                $output = & $injector --process-id ([string]$target.pid) --inject $probe 2>&1
                $exit = $LASTEXITCODE
                Write-ResearchRecord action $target $null @{ injector_exit_code=$exit; injector_output=($output -join [Environment]::NewLine) }
                if ($exit -ne 0) { throw "Injector failed with exit $exit; inspect local log." }
            }
            $ready.Add($target)
        } else {
            $verb = @{ Snapshot='snapshot'; Observe='observe'; Disable='stop' }[$Action]
            Write-ResearchRecord snapshot $target (Invoke-ResearchController $target.pid $verb) $null
        }
    } catch {
        $message = "PID $($target.pid): $($_.Exception.Message)"
        $failed.Add($message); Write-ResearchRecord blocked $target $null $message; Write-Warning $message
    }
}
if ($capture) {
    if ($ready.Count -eq 0) {
        Write-ResearchRecord blocked $null $null 'No eligible GameInput core process could be prepared; no measurements were made.'
        throw 'No eligible GameInput core process could be prepared. Inspect inventory and blocked reasons.'
    }
    try {
        # All loaders/preflights finish before workers launch. One persistent
        # process per target reads shared counters; no per-sample processes or
        # target threads. Native capture excludes 2 s warmup and 2 s drain.
        $verb = if ($Action -eq 'Mitigate' -or $Mode -eq 'Mitigate') { 'capture_mitigate' } else { 'capture_observe' }
        foreach ($target in $ready) {
            $stdout = Join-Path $logDir ("pid-$($target.pid).native.jsonl")
            $stderr = Join-Path $logDir ("pid-$($target.pid).stderr.txt")
            $process = Start-Process -FilePath $controller -ArgumentList @('--pid',[string]$target.pid,'--action',$verb,'--seconds',[string]$DurationSeconds) -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            # Retain the native process handle before a short-lived child exits.
            # Windows PowerShell otherwise sometimes exposes a null ExitCode.
            $null = $process.Handle
            $workers.Add([pscustomobject]@{ target=$target; process=$process; stdout=$stdout; stderr=$stderr })
        }
        $deadline = [DateTime]::UtcNow.AddSeconds($DurationSeconds+45)
        while (@($workers | Where-Object { -not $_.process.HasExited }).Count -gt 0) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Capture workers exceeded bounded session deadline; requesting graceful stop.' }
            Start-Sleep -Milliseconds 250
        }
    } finally {
        foreach ($worker in $workers) {
            if (-not $worker.process.HasExited) {
                try {
                    $cancel = [Threading.EventWaitHandle]::OpenExisting("Global\GameInputProbeCaptureStop-v1-$($worker.target.pid)")
                    try { $cancel.Set() | Out-Null } finally { $cancel.Dispose() }
                } catch { Write-ResearchRecord blocked $worker.target $null ('Could not signal native cleanup: '+$_.Exception.Message) }
                if (-not $worker.process.WaitForExit(15000)) {
                    Write-ResearchRecord blocked $worker.target $null 'Worker did not stop; no forced unload. Probe heartbeat expires to observation.'
                    try { Write-ResearchRecord action $worker.target (Invoke-ResearchController $worker.target.pid stop) 'Fallback fixed stop after worker timeout.' }
                    catch { Write-ResearchRecord blocked $worker.target $null $_.Exception.Message }
                    $failed.Add("PID $($worker.target.pid): worker cleanup timeout.")
                }
            }
            if ($worker.process.HasExited) { $worker.process.WaitForExit() }
            if (Test-Path -LiteralPath $worker.stdout) {
                foreach ($line in [IO.File]::ReadLines($worker.stdout)) {
                    try {
                        $sample = $line | ConvertFrom-Json
                        if ($null -ne $sample.PSObject.Properties['error_code']) { throw "Native controller error $($sample.error_code): $($sample.error)" }
                        $stage = if ($null -ne $sample.PSObject.Properties['capture_stage']) { $sample.capture_stage } else { 'unknown' }
                        $kind = if ($stage -eq 'measurement') { 'snapshot' } else { 'capture_lifecycle' }
                        Write-ResearchRecord $kind $worker.target $sample @{ capture_stage=$stage; sample_timestamp_source='Native sample_qpc; timestamp_utc is merge time.'; observer_effect='Persistent workers; initial/final process lifecycle excluded by 2s stabilization/drain. Correlate ETW before causal claims.' }
                    } catch { $failed.Add("PID $($worker.target.pid): $($_.Exception.Message)"); Write-ResearchRecord blocked $worker.target $null $_.Exception.Message }
                }
            }
            if ($worker.process.HasExited -and ($null -eq $worker.process.ExitCode -or $worker.process.ExitCode -ne 0)) {
                $failed.Add("PID $($worker.target.pid): capture worker exited $($worker.process.ExitCode).")
                Write-ResearchRecord blocked $worker.target $null @{ worker_exit=$worker.process.ExitCode; stderr=(Get-Content -LiteralPath $worker.stderr -Raw -ErrorAction SilentlyContinue) }
            }
        }
    }
}
if ($failed.Count -gt 0) { throw ('One or more targets were blocked or failed: '+($failed -join ' | ')) }
