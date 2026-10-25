[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$deps = Join-Path $root '.deps'
$version = '1.5.0'
$expected = 'ae8729976ae97cc068813ec67981833f26cf92b5cde0ffe16c01b7b44e346a38'
$uri = 'https://github.com/nefarius/Injector/releases/download/v1.5.0/Injector_x86_amd64_arm64.zip'
New-Item -ItemType Directory -Force -Path $deps | Out-Null
$archive = Join-Path $deps 'Injector-v1.5.0.zip'
if (-not (Test-Path -LiteralPath $archive)) {
    $partial = "$archive.partial"
    try {
        Invoke-WebRequest -Uri $uri -OutFile $partial
        if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $expected) {
            throw 'Injector archive SHA256 mismatch; no extraction performed.'
        }
        Move-Item -LiteralPath $partial -Destination $archive
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $expected) {
    throw 'Cached Injector archive SHA256 mismatch; no extraction performed. Remove the invalid archive and retry.'
}
# Extraction happens only after authenticating the complete archive. Bound entry paths
# before writing, including against malicious rooted/parent-traversal ZIP entries.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$destination = Join-Path $deps "Injector-v$version"
New-Item -ItemType Directory -Force -Path $destination | Out-Null
$prefix = [IO.Path]::GetFullPath($destination) + [IO.Path]::DirectorySeparatorChar
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    foreach ($entry in $zip.Entries) {
        $path = [IO.Path]::GetFullPath((Join-Path $destination $entry.FullName))
        if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe ZIP entry path.' }
        if ([string]::IsNullOrEmpty($entry.Name)) { New-Item -ItemType Directory -Force -Path $path | Out-Null; continue }
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($path)) | Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $true)
    }
} finally { $zip.Dispose() }
[pscustomobject]@{ dependency='Nefarius Injector'; version=$version; archive=$archive; sha256=$expected; extracted=$destination }
