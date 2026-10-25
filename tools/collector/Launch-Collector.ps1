#requires -Version 5.1
[CmdletBinding()]
param([switch]$Elevated)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Collector.Common.ps1')
if (-not $Elevated) {
    try {
        $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File ' +
            (ConvertTo-NativeArgument $PSCommandPath) + ' -Elevated'
        # Only a fixed adjacent script is elevated; paths are quoted as data.
        $child = Start-Process -FilePath (Get-SystemTool 'WindowsPowerShell\v1.0\powershell.exe') `
            -ArgumentList $arguments -Verb RunAs -PassThru -Wait
        exit $child.ExitCode
    } catch { Write-Host "Collector did not start: $($_.Exception.Message)"; exit 1 }
}
$code = 1
try {
    & (Join-Path $PSScriptRoot 'Collect-Diagnostics.ps1')
    $code = $LASTEXITCODE
} catch { Write-Host $_ -ForegroundColor Red }
finally { [void](Read-Host 'Press Enter to close this window') }
exit $code
