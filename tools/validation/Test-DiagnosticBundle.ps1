#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Path)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
try {
    $entries = @{}
    [long]$bytes = 0
    foreach ($entry in $archive.Entries) {
        # .NET Framework CreateFromDirectory can emit Windows separators.
        $name = $entry.FullName.Replace('\','/')
        if ($name.EndsWith('/')) { continue }
        if ($entries.ContainsKey($name)) { throw 'Duplicate ZIP entry.' }
        if ($name -match '(^/|(^|/)\.\.(/|$)|:)') { throw 'Unsafe ZIP entry path.' }
        $bytes += $entry.Length
        if ($bytes -gt 512MB) { throw 'Uncompressed bundle exceeds 512 MiB validation limit.' }
        $entries[$name] = $entry
    }
    if (-not $entries.ContainsKey('SHA256SUMS.txt')) { throw 'Missing SHA256SUMS.txt.' }
    $reader = New-Object IO.StreamReader($entries['SHA256SUMS.txt'].Open())
    try { $manifest=$reader.ReadToEnd() } finally { $reader.Dispose() }
    $seen = @{}
    foreach ($line in ($manifest -split '\r?\n')) {
        if (-not $line.Trim()) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64})  (.+)$') { throw 'Invalid manifest line.' }
        $expected=$Matches[1]
        $name=$Matches[2]
        if ($name -eq 'SHA256SUMS.txt' -or $seen.ContainsKey($name)) { throw 'Duplicate or self-referencing manifest entry.' }
        if (-not $entries.ContainsKey($name)) { throw "Missing packaged file: $name" }
        $stream=$entries[$name].Open()
        $hash=[Security.Cryptography.SHA256]::Create()
        try { $actual=[BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','') }
        finally { $hash.Dispose(); $stream.Dispose() }
        if ($actual -ine $expected) { throw "SHA-256 mismatch: $name" }
        $seen[$name]=$true
    }
    if ($entries.Count -ne $seen.Count+1) { throw 'The ZIP includes files missing from the manifest.' }
    [pscustomobject]@{valid=$true;filesVerified=$seen.Count;uncompressedBytes=$bytes;privacyReviewed=$false}
} finally { $archive.Dispose() }
