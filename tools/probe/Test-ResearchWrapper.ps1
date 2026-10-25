[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$checks=0
function Assert([bool]$Condition,[string]$Message) {
    if(-not $Condition) { throw $Message }
    $script:checks++
}
foreach($path in @('tools/probe/Invoke-GameInputResearch.ps1','tools/probe/GameInput.Research.psm1','tools/dependencies/Get-ResearchDependencies.ps1','tools/probe/Clear-KnownFailedStart.ps1')) {
    $tokens=$null;$errors=$null
    [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $path),[ref]$tokens,[ref]$errors)|Out-Null
    Assert ($errors.Count -eq 0) "PowerShell parse failure in $path : $errors"
}
$entry=Get-Command (Join-Path $PSScriptRoot 'Invoke-GameInputResearch.ps1')
foreach($forbidden in @('Pid','ProcessId','Dll','DllPath','Export','InjectorPath','ProbePath')) {
    Assert (-not $entry.Parameters.ContainsKey($forbidden)) "Wrapper exposes forbidden argument $forbidden."
}
Import-Module (Join-Path $PSScriptRoot 'GameInput.Research.psm1') -Force
$injector=Get-ResearchInjector
Assert ($injector.EndsWith('.deps\Injector-v1.5.0\x64\Injector.exe',[StringComparison]::OrdinalIgnoreCase)) 'Pinned x64 Injector path mismatch.'
# A corrupt cache is rejected before creating an extraction directory. Work in
# an isolated ignored tree, never mutate the real cache or active binaries.
$fixture=Join-Path $root ('artifacts/wrapper-tests/'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $fixture 'tools/dependencies'),(Join-Path $fixture '.deps') | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'tools/dependencies/Get-ResearchDependencies.ps1') -Destination (Join-Path $fixture 'tools/dependencies/Get-ResearchDependencies.ps1')
[IO.File]::WriteAllText((Join-Path $fixture '.deps/Injector-v1.5.0.zip'),'invalid archive')
$rejected=$false
try { & (Join-Path $fixture 'tools/dependencies/Get-ResearchDependencies.ps1') | Out-Null }
catch { $rejected=$_.Exception.Message -like '*SHA256 mismatch*' }
Assert $rejected 'Corrupt dependency cache was not rejected by hash verification.'
Assert (-not (Test-Path -LiteralPath (Join-Path $fixture '.deps/Injector-v1.5.0'))) 'Corrupt archive reached extraction.'
$controller=Join-Path $root 'tools/build/out/bin/Release/GameInputProbeController.exe'
if(Test-Path -LiteralPath $controller) {
    $result=(& $controller --pid ([string]$PID) --action arbitrary) | ConvertFrom-Json
    Assert ($LASTEXITCODE -ne 0 -and $result.error_code -eq 87) 'Arbitrary native export action accepted.'
    $result=(& $controller --pid ([string]$PID) --action verify) | ConvertFrom-Json
    Assert ($LASTEXITCODE -ne 0 -and $result.error_code -in @(5,1300)) 'Unrelated own-process target was not refused.'
    $result=(& $controller --pid ([string]$PID) --action capture_observe --seconds 301) | ConvertFrom-Json
    Assert ($LASTEXITCODE -ne 0 -and $result.error_code -eq 87) 'Unbounded native capture duration accepted.'
}
$targets=@(Get-ResearchTargets)
$actual=@(Get-Process -Name GameInputSvc,GameInputRedistService -ErrorAction SilentlyContinue)
$observedIds=($targets.pid | Sort-Object) -join ','
$expectedIds=($actual.Id | Sort-Object) -join ','
Assert ($observedIds -eq $expectedIds) 'Inventory failed to enumerate every matching PID.'
[pscustomobject]@{ passed=$checks; failed=0; fixture=$fixture; network_download='Previously tested explicit pinned download + hash verification; cached x64 extraction verified here.' }
