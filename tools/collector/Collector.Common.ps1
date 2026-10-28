# Windows PowerShell 5.1. No shell evaluation, downloaded utilities, or native code.
Set-StrictMode -Version 2.0

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    # CommandLineToArgvW quoting, including quotes and trailing backslashes.
    '"' + ([regex]::Replace(([regex]::Replace($Value, '(\\*)"', '$1$1\"')), '(\\+)$', '$1$1')) + '"'
}

function Get-SystemTool {
    param([string]$Name)
    $directory = Join-Path $env:SystemRoot 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $directory = Join-Path $env:SystemRoot 'Sysnative'
    }
    $path = Join-Path $directory $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Windows tool unavailable: $Name" }
    $path
}

function Invoke-CollectorCommand {
    param([string]$FilePath, [string[]]$Arguments = @(), [int]$TimeoutSeconds = 30,
        [string]$SizeWatchPath = '', [long]$MaxBytes = 536870912)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $sizeExceeded = $false
    $processStarted = $false
    try {
        [void]$process.Start()
        $processStarted = $true
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(200)) {
            if ($SizeWatchPath -and (Get-CollectorBytes $SizeWatchPath) -gt $MaxBytes) { $sizeExceeded = $true }
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds -or $sizeExceeded) {
                $timedOut = -not $sizeExceeded
                $process.Kill()
                [void]$process.WaitForExit(5000)
                break
            }
        }
        $outText = ''
        $errText = ''
        if ($stdout.Wait(5000)) { $outText = $stdout.Result }
        if ($stderr.Wait(5000)) { $errText = $stderr.Result }
        [pscustomobject]@{
            ExitCode = $(if ($timedOut -or $sizeExceeded) { -1 } else { $process.ExitCode })
            TimedOut = $timedOut; SizeExceeded = $sizeExceeded
            # Prevent command transcripts from dominating the bundle.
            Stdout = $outText.Substring(0, [Math]::Min(262144, $outText.Length))
            Stderr = $errText.Substring(0, [Math]::Min(65536, $errText.Length))
        }
    } finally {
        # PowerShell executes finally on Ctrl+C, including while a command is running.
        if ($processStarted -and -not $process.HasExited) { $process.Kill() }
        $process.Dispose()
    }
}

function Get-CollectorBytes {
    param([string]$Path)
    $sum = (Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [long]0 }
    [long]$sum
}

function Write-CollectorJson {
    param([string]$Path, $Value)
    $Value | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Test-CollectorAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-CollectorReadiness {
    # Called before WPR/watchdog startup: waiting for the operator records no trace.
    while ($true) {
        $answer = Read-Host 'Reproduce/prepare the requested state, then Enter = ready; S = skip; Q = cancel'
        switch ($answer.Trim().ToUpperInvariant()) {
            '' { return 'ready' }
            'S' { return 'skipped' }
            'Q' { throw 'Operator cancelled before recording.' }
            default { Write-Host 'Press Enter, S, or Q.' }
        }
    }
}

function Read-CollectorObservations {
    param([switch]$NonInteractive)
    $result = [ordered]@{ RecordedUtc = [DateTime]::UtcNow.ToString('o');
        SymptomObserved = 'unknown'; SymptomTiming = ''; HighCpuProcess = '';
        ActualActions = ''; VibrationObserved = 'unknown'; DisabledServiceWorkaround = '' }
    if ($NonInteractive) { return $result }
    # Ask only after the ETL is saved, so answers cannot displace the symptom.
    do { $answer = (Read-Host 'Was the problem visible during those recorded seconds? Y / N / U (unknown)').Trim().ToUpperInvariant() }
    until ($answer -in @('Y', 'N', 'U', ''))
    $result.SymptomObserved = switch ($answer) { 'Y' { 'yes' } 'N' { 'no' } default { 'unknown' } }
    $result.SymptomTiming = Read-Host 'When did it happen within this recording? (or unknown)'
    $result.HighCpuProcess = Read-Host 'Which process showed high CPU, and roughly how much? (or unknown)'
    $result.ActualActions = Read-Host 'What did you actually do: connected/disconnected, input, vibration?'
    $result.VibrationObserved = Read-Host 'Was vibration actually felt? Yes / no / not requested / unknown'
    $result.DisabledServiceWorkaround = Read-Host 'Which exact service do you normally disable as a workaround? (or none/unknown; do not change it now)'
    $result
}

function Write-CollectorProfile {
    param([string]$Path, [object[]]$Providers = @(), [switch]$WdfKeywords)
    $eventDefinitions = ''
    $eventReferences = ''
    for ($i = 0; $i -lt $Providers.Count; $i++) {
        # Only GUIDs parsed from Windows' provider registry enter XML.
        $guid = ([guid]$Providers[$i].Guid).ToString()
        $eventDefinitions += @"
    <EventProvider Id="E$i" Name="$guid" Level="5" NonPagedMemory="true">
      <Keywords><Keyword Value="0xffffffffffffffff" /></Keywords>
    </EventProvider>
"@
        $eventReferences += "<EventProviderId Value=`"E$i`" />"
    }
    $eventCollector = ''
    $eventBinding = ''
    if ($Providers.Count -gt 0) {
        $eventCollector = '<EventCollector Id="Events" Name="GameInputEvents"><BufferSize Value="256" /><Buffers Value="64" /></EventCollector>'
        $eventBinding = "<EventCollectorId Value=`"Events`"><EventProviders>$eventReferences</EventProviders></EventCollectorId>"
    }
    $wdf = ''
    if ($WdfKeywords) { $wdf = '<Keyword Value="WDFDPC" /><Keyword Value="WDFInterrupt" />' }
    @"
<?xml version="1.0" encoding="utf-8"?>
<WindowsPerformanceRecorder Version="1.0">
  <Profiles>
    <SystemCollector Id="System" Name="GameInputSystem"><BufferSize Value="1024" /><Buffers Value="64" /></SystemCollector>
    $eventCollector
    <SystemProvider Id="CPU">
      <Keywords><Keyword Value="CpuConfig" /><Keyword Value="ProcessThread" /><Keyword Value="Loader" /><Keyword Value="SampledProfile" /><Keyword Value="CSwitch" /><Keyword Value="Power" /><Keyword Value="Timer" />$wdf</Keywords>
      <Stacks><Stack Value="SampledProfile" /></Stacks>
    </SystemProvider>
    $eventDefinitions
    <Profile Id="GameInput.Verbose.Memory" Name="GameInput" Description="Bounded GameInput diagnostics" LoggingMode="Memory" DetailLevel="Verbose">
      <Collectors><SystemCollectorId Value="System"><SystemProviderId Value="CPU" /></SystemCollectorId>$eventBinding</Collectors>
    </Profile>
  </Profiles>
</WindowsPerformanceRecorder>
"@ | Set-Content -LiteralPath $Path -Encoding UTF8
}
