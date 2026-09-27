#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputDirectory = Join-Path $repoRoot 'dist'
$archivePath = Join-Path $outputDirectory 'CDriveCleaner.zip'
$filenames = @('CDriveCleaner.ps1', '启动C盘清理助手.cmd', 'README.md')
$files = @($filenames | ForEach-Object { Join-Path $repoRoot $_ })
foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing release file: $file" }
}
[void][IO.Directory]::CreateDirectory($outputDirectory)
Compress-Archive -LiteralPath $files -DestinationPath $archivePath -CompressionLevel Optimal -Force

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    if ($archive.Entries.Count -ne $filenames.Count) { throw 'Unexpected release archive entries.' }
    foreach ($filename in $filenames) {
        $entry = $archive.GetEntry($filename)
        if ($null -eq $entry) { throw "Release archive entry missing: $filename" }
        $stream = $entry.Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actualHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
        finally { $stream.Dispose(); $sha.Dispose() }
        $expectedHash = (Get-FileHash -LiteralPath (Join-Path $repoRoot $filename) -Algorithm SHA256).Hash
        if ($actualHash -ne $expectedHash) { throw "Release archive verification failed: $filename" }
    }
}
finally { $archive.Dispose() }
Write-Output $archivePath
