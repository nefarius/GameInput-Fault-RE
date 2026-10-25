#requires -Version 5.1
<#
.SYNOPSIS
Collect bounded GameInput diagnostics with Windows built-in tools, after consent.
.EXAMPLE
.\Collect-Diagnostics.ps1 -InventoryOnly -Consent -NonInteractive
.EXAMPLE
.\Collect-Diagnostics.ps1 -Consent -NonInteractive -Phases idle -PhaseSeconds 15 -Controller 'Xbox One' -Connection USB
#>
[CmdletBinding()]
param(
    [switch]$InventoryOnly,
    [switch]$Consent,
    [switch]$NonInteractive,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'output'),
    [ValidateSet('baseline', 'idle', 'input', 'rumble')][string[]]$Phases = @('baseline', 'idle', 'input', 'rumble'),
    [ValidateRange(3, 60)][int]$PhaseSeconds = 15,
    [ValidateRange(0, 30)][int]$PreparationSeconds = 10,
    [ValidateRange(15, 300)][int]$MaxTraceSeconds = 180,
    [ValidateRange(128, 512)][int]$MaxOutputMB = 256,
    [ValidateRange(15, 180)][int]$InventoryTimeoutSeconds = 120,
    [string]$Controller = '',
    [string]$Connection = '',
    [string]$Game = '',
    [string]$Rumble = '',
    [string]$Symptom = '',
    [string]$WorkaroundState = '',
    [switch]$IncludeProbeProvider,
    # ABI v1, src/probe/protocol.hpp; enables events only, never loads a DLL.
    [guid]$ProbeEtwProviderGuid = 'b91b050b-64b5-4e3b-9a2f-42046d48e9ce'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Collector.Common.ps1')

$notice = @'
GameInput diagnostic collection - consent/privacy notice, version 1

This collector reads system/service/device/driver/module inventory and, unless
InventoryOnly is selected, records system-wide CPU stacks and ETW diagnostics.
ETL may contain other applications' activity, process/image paths, command lines,
file paths, device reports/input-related events, and timing. JSON includes device
instance IDs, hardware IDs, driver/service paths, and module paths. Device IDs
may encode serial numbers or Bluetooth addresses. Paths may reveal your Windows
user name. Questionnaire answers can contain identifying information.

Close sensitive applications before continuing. Do not type passwords or other
sensitive text during a trace. These diagnostics are NOT anonymized. No process
memory dump, hook, injection, driver/service change, or automatic upload is made.
Windows signature verification may use Windows certificate/revocation services.
Rumble is requested manually using your existing game/test app; this collector
does not open a controller or send input/output commands to it.

The local ZIP and staging directory remain on this computer. Review every file
and obtain help reviewing ETL before public sharing. You choose whether to attach
the ZIP to an issue or share privately. Delete the ZIP and staging directory when
no longer needed. A SHA-256 manifest provides integrity, not anonymity or signing.

Type COLLECT to consent, or supply -Consent to explicitly accept this exact notice.
Ctrl+C cancels; Q cancels during timed phases. The collector cancels only its own
randomly named WPR instance. Never use an unqualified wpr -cancel for recovery.
'@
Write-Host $notice
if (-not $Consent) {
    if ($NonInteractive) { throw 'NonInteractive requires explicit -Consent. Nothing has been collected.' }
    if ((Read-Host 'Consent') -cne 'COLLECT') { Write-Host 'Declined. Nothing collected.'; exit 2 }
}
if (-not $InventoryOnly -and -not (Test-CollectorAdministrator)) {
    throw 'Tracing requires Administrator. Double-click Collect-Diagnostics.cmd, or use -InventoryOnly.'
}
if (-not $InventoryOnly -and (($PhaseSeconds + $PreparationSeconds) * $Phases.Count) -gt $MaxTraceSeconds) {
    throw 'Requested phases exceed MaxTraceSeconds. Shorten phases/preparation or raise the limit (maximum 300 seconds).'
}

$questionnaire = [ordered]@{ RecordedUtc = [DateTime]::UtcNow.ToString('o');
    Controller = $Controller; Connection = $Connection; Game = $Game; Rumble = $Rumble;
    Symptom = $Symptom; WorkaroundState = $WorkaroundState;
    RequestedPhases = $Phases; PhaseSeconds = $PhaseSeconds; PreparationSeconds = $PreparationSeconds;
    NonInteractive = [bool]$NonInteractive }
if (-not $NonInteractive) {
    foreach ($question in @(
        @('Controller', 'Controller model (no serial number needed)'),
        @('Connection', 'Connection: USB / Bluetooth / receiver'),
        @('Game', 'Game/test application and version'),
        @('Rumble', 'Rumble enabled? How will it be requested?'),
        @('Symptom', 'Symptom and how to reproduce it'),
        @('WorkaroundState', 'Workaround state (collect once without it first)'))) {
        if (-not $questionnaire[$question[0]]) { $questionnaire[$question[0]] = Read-Host $question[1] }
    }
}
$runId = [guid]::NewGuid().ToString('N')
$instance = 'GameInput_' + $runId
[void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory))
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$run = Join-Path $outputRoot ('GameInput-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + $runId.Substring(0, 8))
[void][IO.Directory]::CreateDirectory($run)
$maxBytes = [long]$MaxOutputMB * 1MB
$zip = $run + '.zip'
$statusPath = Join-Path $outputRoot 'collector-status.json'
$state = [ordered]@{ SchemaVersion = 1; RunId = $runId; StartedUtc = [DateTime]::UtcNow.ToString('o');
    Mode = $(if ($InventoryOnly) { 'inventory-only' } else { 'trace' }); Status = 'in-progress';
    InstanceName = $instance; MaxTraceSeconds = $MaxTraceSeconds; MaxOutputMB = $MaxOutputMB;
    TraceMemoryMB = 80; Providers = @(); WdfProfile = $null; Phases = @(); Commands = @();
    InventoryIssueCount = 0; Errors = @(); Cleanup = @(); FinishedUtc = $null }
$commandRecords = [Collections.Generic.List[object]]::new()
$errors = [Collections.Generic.List[string]]::new()
$cleanup = [Collections.Generic.List[object]]::new()
$providerRecords = [Collections.Generic.List[object]]::new()
$phaseRecords = [Collections.Generic.List[object]]::new()
$watchdog = $null
$wpr = $null
$traceAttempted = $false
$traceStopped = $false
$cleanupSucceeded = $true
$traceClock = $null
$exitCode = 0

function Write-CollectionStatus {
    param([string]$Stage, [string]$Outcome = 'running')
    # Stable location for unattended callers. Atomic replacement avoids partial JSON.
    $temporaryStatus = $statusPath + '.' + $runId + '.tmp'
    Write-CollectorJson $temporaryStatus ([ordered]@{ SchemaVersion = 1; Stage = $Stage; Status = $Outcome;
        UpdatedUtc = [DateTime]::UtcNow.ToString('o'); RunDirectory = $run; RunJson = (Join-Path $run 'run.json');
        ZipPath = $(if (Test-Path -LiteralPath $zip) { $zip } else { $null }); InstanceName = $instance;
        ExitCode = $(if ($Outcome -eq 'running') { $null } else { $exitCode }) })
    Move-Item -LiteralPath $temporaryStatus -Destination $statusPath -Force
}

function Invoke-RunCommand {
    param([string]$File, [string[]]$Arguments, [int]$Timeout = 30)
    $result = Invoke-CollectorCommand $File $Arguments $Timeout $run $maxBytes
    $commandRecords.Add([pscustomobject]@{ Utc = [DateTime]::UtcNow.ToString('o');
        Tool = [IO.Path]::GetFileName($File); Arguments = $Arguments; Result = $result })
    $result
}

function Assert-TraceBudget {
    if ($traceClock -and $traceClock.Elapsed.TotalSeconds -ge $MaxTraceSeconds) { throw 'Trace duration limit reached.' }
    if ((Get-CollectorBytes $run) -gt $maxBytes) { throw 'Output size limit reached.' }
    if (Test-Path -LiteralPath (Join-Path $run 'watchdog-result.json')) { throw 'Watchdog stopped this recording; see watchdog-result.json.' }
}

function Wait-PhaseInterval {
    param([int]$Seconds, [switch]$Preparation)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $Seconds) {
        Assert-TraceBudget
        if (-not $NonInteractive -and -not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Q) { throw 'Operator cancelled using Q.' }
            if ($Preparation -and $key.Key -eq [ConsoleKey]::S) { return 'skipped' }
            if ($Preparation -and $key.Key -eq [ConsoleKey]::Enter) { return 'ready' }
        }
        Start-Sleep -Milliseconds 100
    }
    if ($Preparation) { return 'timed-preparation-ended' }
    'completed'
}

try {
    Write-CollectionStatus 'inventory'
    $notice | Set-Content -LiteralPath (Join-Path $run 'consent-privacy.txt') -Encoding UTF8
    Write-CollectorJson (Join-Path $run 'consent.json') ([ordered]@{ Accepted = $true;
        AcceptedUtc = [DateTime]::UtcNow.ToString('o'); Method = $(if ($Consent) { 'explicit -Consent switch' } else { 'typed COLLECT' });
        NoticeSHA256 = (Get-FileHash -LiteralPath (Join-Path $run 'consent-privacy.txt') -Algorithm SHA256).Hash })
    Write-CollectorJson (Join-Path $run 'questionnaire.json') $questionnaire
    Write-CollectorJson (Join-Path $run 'run.json') $state
    # Copy only collector sources: no binaries, environment dumps, or repo contents.
    $sourceDirectory = Join-Path $run 'collector-source'
    [void][IO.Directory]::CreateDirectory($sourceDirectory)
    foreach ($source in Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Extension -in @('.ps1', '.cmd') }) {
        Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $sourceDirectory $source.Name)
    }
    Write-Host "Collecting inventory (up to $InventoryTimeoutSeconds seconds). Output: $run"
    $powershell = Get-SystemTool 'WindowsPowerShell\v1.0\powershell.exe'
    $inventoryResult = Invoke-RunCommand $powershell @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $PSScriptRoot 'Collect-Inventory.ps1'), '-RunDirectory', $run) $InventoryTimeoutSeconds
    if ($inventoryResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $run 'inventory.json'))) {
        $errors.Add('Inventory worker failed or timed out; see command transcript. Missing fields are not evidence of absence.')
        if (-not (Test-Path -LiteralPath (Join-Path $run 'inventory.json'))) {
            Write-CollectorJson (Join-Path $run 'inventory.json') @{ SchemaVersion = 1; Incomplete = $true; WorkerResult = $inventoryResult }
        }
    }
    $inventorySnapshot = Get-Content -LiteralPath (Join-Path $run 'inventory.json') -Raw | ConvertFrom-Json
    if ($inventorySnapshot.PSObject.Properties['Issues']) { $state.InventoryIssueCount = @($inventorySnapshot.Issues).Count }

    if (-not $InventoryOnly) {
        $wpr = Get-SystemTool 'wpr.exe'
        $advanced = Invoke-RunCommand $wpr @('-help', 'advanced')
        if ($advanced.Stdout -notmatch '(?i)instancename') { throw 'This WPR does not advertise named-instance support; tracing refused.' }
        $providerQuery = Invoke-RunCommand (Get-SystemTool 'logman.exe') @('query', 'providers')
        $providerQuery.Stdout | Set-Content -LiteralPath (Join-Path $run 'registered-providers.txt') -Encoding UTF8
        $available = @{}
        if ($providerQuery.ExitCode -eq 0) {
            foreach ($line in ($providerQuery.Stdout -split '\r?\n')) {
                if ($line -match '^\s*(.*?)\s+(\{[0-9a-fA-F-]{36}\})\s*$') {
                    $available[$Matches[1].Trim()] = $Matches[2]
                }
            }
        } else { $errors.Add('Provider enumeration failed; optional providers will be recorded as unavailable.') }
        $wanted = @('WdfTraceLoggingProvider', 'Microsoft-Windows-DriverFrameworks-UserMode-Performance',
            'Microsoft-Windows-DriverFrameworks-KernelMode-Performance', 'Microsoft-Windows-Input-HIDCLASS',
            'Microsoft-Windows-Kernel-IO', 'Microsoft-Windows-Kernel-IoTrace', 'Microsoft-Windows-Kernel-Power')
        $wanted += @($available.Keys | Where-Object { $_ -match '(?i)dshidmini' })
        if (-not @($available.Keys | Where-Object { $_ -match '(?i)dshidmini' }).Count) {
            $providerRecords.Add([pscustomobject]@{ Name = 'DsHidMini'; Guid = $null; Status = 'omitted';
                Reason = 'No registered DsHidMini provider. No driver/debug setting was installed or changed.' })
        }
        $selected = [Collections.Generic.List[object]]::new()
        foreach ($name in $wanted) {
            $record = [pscustomobject]@{ Name = $name; Guid = $null; Status = 'omitted'; Reason = 'Not registered or provider enumeration unavailable.' }
            if ($available.ContainsKey($name)) {
                $record.Guid = $available[$name]; $record.Status = 'selected'; $record.Reason = 'Registered provider; all keywords, level 5.'
                $selected.Add($record)
            }
            $providerRecords.Add($record)
        }
        # WdfTraceLoggingProvider is commonly a WPR PROFILE, not an ETW provider.
        # Do not blindly enable its built-in file-mode profile (unbounded and huge).
        $profiles = Invoke-RunCommand $wpr @('-profiles')
        $hasWdfProfile = $profiles.Stdout -match '(?m)^\s*WdfTraceLoggingProvider\s'
        $state.WdfProfile = [ordered]@{ Available = $hasWdfProfile;
            Handling = 'Bounded equivalent: WDFDPC/WDFInterrupt + registered WDF performance providers, with CPU/process/loader. Built-in WDF file-mode profile is not started.' }
        if ($hasWdfProfile) {
            $wdfRecord = $providerRecords | Where-Object Name -eq 'WdfTraceLoggingProvider' | Select-Object -First 1
            if ($wdfRecord.Status -eq 'omitted') {
                $wdfRecord.Status = 'bounded-equivalent'
                $wdfRecord.Reason = $state.WdfProfile.Handling
            }
        }
        $probeGuid = $ProbeEtwProviderGuid.ToString()
        $probeRegistered = @($available.Keys | Where-Object { $available[$_].Trim('{}') -ieq $probeGuid })
        $probe = [pscustomobject]@{ Name = 'GameInputProbe'; Guid = $probeGuid; Status = 'omitted';
            Reason = 'Protocol ABI v1 provider not registered. Use -IncludeProbeProvider to arm before a separate probe attaches.' }
        if ($IncludeProbeProvider -or $probeRegistered.Count -gt 0) {
            $probe.Status = 'selected'; $probe.Reason = 'Protocol ABI v1 GUID; event capture only. No probe is loaded or attached by this collector.'
            $selected.Add($probe)
        }
        $providerRecords.Add($probe)
        Write-CollectorJson (Join-Path $run 'providers.json') $providerRecords.ToArray()
        $profilePath = Join-Path $run 'capture.wprp'
        Write-CollectorProfile $profilePath $selected.ToArray() -WdfKeywords:$hasWdfProfile
        $validation = Invoke-RunCommand $wpr @('-profiles', $profilePath)
        if ($validation.ExitCode -ne 0) { throw 'Generated WPR profile failed validation; see command transcript.' }

        # Start watchdog BEFORE WPR; it can clean up even a partially failed start.
        $owner = Get-Process -Id $PID
        $watchArguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            (Join-Path $PSScriptRoot 'Trace-Watchdog.ps1'), '-InstanceName', $instance,
            '-OwnerProcessId', "$PID", '-OwnerStartTicks', "$($owner.StartTime.ToUniversalTime().Ticks)",
            '-RunDirectory', $run, '-DeadlineSeconds', "$($MaxTraceSeconds + 120)", '-MaxOutputMB', "$MaxOutputMB")
        $watchdog = Start-Process -FilePath $powershell -ArgumentList (($watchArguments | ForEach-Object {
            ConvertTo-NativeArgument $_ }) -join ' ') -WindowStyle Hidden -PassThru
        $readyClock = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath (Join-Path $run 'watchdog.ready'))) {
            if ($watchdog.HasExited -or $readyClock.Elapsed.TotalSeconds -gt 10) { throw 'Cleanup watchdog did not become ready; WPR was not started.' }
            Start-Sleep -Milliseconds 100
        }
        $traceAttempted = $true
        Write-CollectionStatus 'trace-start'
        $started = Invoke-RunCommand $wpr @('-start', ($profilePath + '!GameInput'), '-instancename', $instance) 30
        if ($started.ExitCode -ne 0) { throw 'WPR start failed. Only this random instance will be cancelled; existing recordings are left alone.' }
        foreach ($record in $selected) { $record.Status = 'enabled'; $record.Reason += ' WPR start succeeded; event production is not guaranteed.' }
        $traceClock = [Diagnostics.Stopwatch]::StartNew()
        foreach ($phase in $Phases) {
            Write-CollectionStatus ('phase-' + $phase)
            $instruction = switch ($phase) {
                'baseline' { 'Disconnect the controller if safe; leave the test app in its baseline state.' }
                'idle' { 'Connect the controller; keep hands off buttons/sticks; stop rumble in your app.' }
                'input' { 'Move sticks and press buttons in your existing game/test app; keep rumble off.' }
                'rumble' { 'Request rumble in your existing game/test app; note if unsupported. No rumble is sent by this script.' }
            }
            $record = [ordered]@{ Name = $phase; Instruction = $instruction; PromptUtc = [DateTime]::UtcNow.ToString('o');
                Preparation = $null; StartUtc = $null; EndUtc = $null; StartQpc = $null; EndQpc = $null;
                QpcFrequency = [Diagnostics.Stopwatch]::Frequency; Result = 'not-started';
                OperatorConfirmed = $false; StartMarker = $null; EndMarker = $null }
            $phaseRecords.Add($record)
            Write-Host "`nPHASE: $phase ($PhaseSeconds seconds). $instruction" -ForegroundColor Cyan
            Write-Host "Preparation: $PreparationSeconds seconds. Enter = ready; S = skip; Q = cancel."
            $preparation = Wait-PhaseInterval $PreparationSeconds -Preparation
            $record.Preparation = $preparation
            if ($preparation -eq 'skipped') { $record.Result = 'skipped'; continue }
            $record.OperatorConfirmed = ($preparation -eq 'ready')
            $record.StartUtc = [DateTime]::UtcNow.ToString('o')
            $record.StartQpc = [Diagnostics.Stopwatch]::GetTimestamp()
            $record.StartMarker = Invoke-RunCommand $wpr @('-marker', "GameInput:$phase:start", '-instancename', $instance) 5
            $record.Result = 'recording'
            Write-Host "Recording $phase now..."
            try { $record.Result = Wait-PhaseInterval $PhaseSeconds }
            finally {
                $record.EndUtc = [DateTime]::UtcNow.ToString('o'); $record.EndQpc = [Diagnostics.Stopwatch]::GetTimestamp()
                if ($record.Result -eq 'recording') { $record.Result = 'interrupted' }
                $record.EndMarker = Invoke-RunCommand $wpr @('-marker', "GameInput:$phase:end", '-instancename', $instance) 5
                Write-CollectorJson (Join-Path $run 'phases.json') $phaseRecords.ToArray()
            }
        }
        $status = Invoke-RunCommand $wpr @('-status', 'collectors', '-details', '-instancename', $instance) 10
        $status.Stdout | Set-Content -LiteralPath (Join-Path $run 'trace-status.txt') -Encoding UTF8
        Write-Host 'Saving this collector trace (up to 90 seconds)...'
        Write-CollectionStatus 'trace-save'
        $stopped = Invoke-RunCommand $wpr @('-stop', (Join-Path $run 'capture.etl'), '-skipPdbGen', '-instancename', $instance) 90
        if ($stopped.ExitCode -ne 0) { throw 'WPR save failed or exceeded its time/size budget; cleanup will cancel this instance.' }
        $traceStopped = $true
    }
    $state.Status = 'complete'
    if ($state.InventoryIssueCount -gt 0) { $state.Status = 'complete-with-omissions' }
} catch {
    $exitCode = 1
    $errors.Add($_.Exception.Message)
    $state.Status = 'incomplete'
    Write-Host "Collection incomplete: $($_.Exception.Message)" -ForegroundColor Yellow
} finally {
    # This path runs on success, ordinary failure, and PowerShell Ctrl+C.
    if ($traceAttempted -and -not $traceStopped) {
        try {
            $cancel = Invoke-CollectorCommand $wpr @('-cancel', '-instancename', $instance) 30
            $cleanup.Add($cancel)
            # A nonzero cancellation can mean start never succeeded; verify absence.
            $verify = Invoke-CollectorCommand $wpr @('-status', '-instancename', $instance) 10
            $cleanup.Add($verify)
            if ($cancel.ExitCode -ne 0 -and $verify.ExitCode -eq 0) { $cleanupSucceeded = $false }
        } catch { $cleanupSucceeded = $false; $errors.Add("Cleanup: $($_.Exception.Message)") }
    }
    if ($cleanupSucceeded) {
        'complete' | Set-Content -LiteralPath (Join-Path $run 'watchdog.complete') -Encoding ASCII
        if ($watchdog) { [void]$watchdog.WaitForExit(3000); $watchdog.Dispose() }
    } else {
        $errors.Add("Cleanup could not be verified. Watchdog remains armed. Recovery: wpr -cancel -instancename $instance")
    }
    # Enforce the artifact cap even if WPR merge metadata expanded beyond buffers.
    $etl = Join-Path $run 'capture.etl'
    if ((Get-CollectorBytes $run) -gt $maxBytes -and (Test-Path -LiteralPath $etl)) {
        Remove-Item -LiteralPath $etl -Force
        $errors.Add('ETL removed because total staging output exceeded MaxOutputMB. No trace is included.')
    }
    if ($errors.Count -gt 0) { $state.Status = 'incomplete'; $exitCode = 1 }
    $state.Providers = @($providerRecords.ToArray()); $state.Phases = @($phaseRecords.ToArray())
    $state.Commands = @($commandRecords.ToArray()); $state.Errors = @($errors.ToArray()); $state.Cleanup = @($cleanup.ToArray())
    $state.FinishedUtc = [DateTime]::UtcNow.ToString('o')
    Write-CollectorJson (Join-Path $run 'run.json') $state
    Write-CollectorJson (Join-Path $run 'phases.json') $phaseRecords.ToArray()
    Write-CollectorJson (Join-Path $run 'providers.json') $providerRecords.ToArray()
    $summary = @"
GameInput diagnostics - $($state.Status)
UTC: $($state.StartedUtc) to $($state.FinishedUtc)
Mode: $($state.Mode)
WPR instance: $instance
Controller: $($questionnaire.Controller)
Connection: $($questionnaire.Connection)
Game/test app: $($questionnaire.Game)
Rumble: $($questionnaire.Rumble)
Workaround state: $($questionnaire.WorkaroundState)
Symptom: $($questionnaire.Symptom)
Trace present: $(Test-Path -LiteralPath $etl)
Phases: $(($phaseRecords | ForEach-Object { $_.Name + '=' + $_.Result }) -join ', ')
Omissions: $(($providerRecords | Where-Object Status -eq 'omitted' | ForEach-Object Name) -join ', ')
Errors: $($errors -join ' | ')
Inventory issues: $($state.InventoryIssueCount) (see inventory.json)

Read consent-privacy.txt before sharing. Inventory and ETL are not anonymized.
Inventory is a snapshot; inaccessible modules, absent providers, and event loss
must not be interpreted as proof of absence. Timer snapshot may be unavailable.
Fixed 64 MiB system + 16 MiB event buffers can wrap; early phases may be lost.
Inspect trace-status.txt / WPA for loss, stacks, and actual event coverage.
Phase timestamps describe requested actions; timed preparation does not confirm
the controller state or that input/rumble occurred. InventoryOnly has no ETL.
No automatic upload. SHA256SUMS.txt covers all packaged files except itself.
"@
    $summary | Set-Content -LiteralPath (Join-Path $run 'summary.txt') -Encoding UTF8
    try {
        Write-CollectionStatus 'packaging'
        if (-not $cleanupSucceeded) { throw 'Watchdog remains armed; ZIP deferred until trace cleanup can be verified.' }
        if ((Get-CollectorBytes $run) -gt $maxBytes) { throw 'Metadata exceeds the output cap; ZIP not created.' }
        $manifest = @(Get-ChildItem -LiteralPath $run -File -Recurse | Sort-Object FullName | ForEach-Object {
            (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' +
                $_.FullName.Substring($run.Length + 1).Replace('\', '/')
        })
        $manifest | Set-Content -LiteralPath (Join-Path $run 'SHA256SUMS.txt') -Encoding UTF8
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($run, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
        if ((Get-Item -LiteralPath $zip).Length -gt $maxBytes) {
            Remove-Item -LiteralPath $zip -Force
            throw 'ZIP exceeded MaxOutputMB and was removed; staging files remain for review.'
        }
        Write-Host "`nReview before manual sharing: $zip" -ForegroundColor Green
        Write-Host ('ZIP SHA-256: ' + (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash)
    } catch { $exitCode = 1; $state.Status = 'incomplete'; Write-Host "Packaging failed: $($_.Exception.Message). Staging: $run" -ForegroundColor Yellow }
    Write-CollectionStatus 'finished' $state.Status
}
exit $exitCode
