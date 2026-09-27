#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$AppPath = '',
    [string]$ReportPath = ''
)
# Drives the real WinForms analysis page with a read-only analysis of a small fixture.
# It never starts a scan or cleanup, and never recycles anything.
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($AppPath)) { $AppPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'CDriveCleaner.ps1' }
$AppPath = (Resolve-Path -LiteralPath $AppPath).Path
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $PSScriptRoot 'TestResults\analysis-ui.json' }
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ReportPath))
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('CDriveCleanerUi_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'app\node_modules\pkg'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'many'))
$stream = [IO.File]::Create((Join-Path $fixture 'app\node_modules\pkg\big.js'))
try { $buffer = New-Object byte[] (1MB); for ($i = 0; $i -lt 101; $i++) { $stream.Write($buffer, 0, $buffer.Length) } } finally { $stream.Dispose() }
for ($i = 0; $i -lt 5100; $i++) { [IO.File]::WriteAllText((Join-Path $fixture ('many\f{0}.txt' -f $i)), 'x') }

$source = [IO.File]::ReadAllText($AppPath)
$source = $source.Replace('$script:ScriptPath = $MyInvocation.MyCommand.Path', '$script:ScriptPath = $AppPath')
$source = $source.Substring(0, $source.LastIndexOf('if ($UiSmokeTest) {'))
. ([scriptblock]::Create($source))
try {
    $result = Invoke-DiskAnalysis -Root $fixture -PreferMft $false
    Show-AnalysisResult -Result $result
    if ($dirTree.Nodes.Count -ne 1) { throw 'Tree root missing.' }
    $root = $dirTree.Nodes[0]
    if ($root.Nodes.Count -lt 2) { throw 'Root children not loaded.' }
    if ($root.Nodes[0].Text -notlike 'app*') { throw ('Largest folder not first: ' + $root.Nodes[0].Text) }
    Expand-DirectoryTreeNode -TreeNode $root.Nodes[0]
    if ([string]$root.Nodes[0].Nodes[0].Tag -eq 'placeholder') { throw 'Child expansion failed.' }
    $many = @($root.Nodes | Where-Object { $_.Text -like 'many*' })[0]
    Expand-DirectoryTreeNode -TreeNode $many
    if (@($many.Nodes | Where-Object { $_.Text -like '*5,100*' }).Count -ne 1) { throw 'Direct-files leaf missing.' }
    if ($denseList.Items.Count -ne 1 -or $largeFileList.Items.Count -lt 1) { throw 'Lists not filled.' }
    if (@($suggestionList.Items | Where-Object { $_.SubItems[3].Text -like '*node_modules' }).Count -ne 1) { throw 'Suggestion missing from list.' }
    Sort-AnalysisList -List $largeFileList -Column 3
    Sort-AnalysisList -List $largeFileList -Column 3
    if ($largeFileList.Tag.SortColumn -ne 3 -or $largeFileList.Tag.Descending) { throw 'Column sort state wrong.' }
    Sort-AnalysisList -List $largeFileList -Column 0
    $sizes = @($largeFileList.Tag.Data | ForEach-Object { $_.Logical })
    for ($i = 1; $i -lt $sizes.Count; $i++) { if ($sizes[$i - 1] -lt $sizes[$i]) { throw 'Numeric size sort wrong.' } }
    Sort-AnalysisList -List $denseList -Column 0
    [void]$largeFileList.Handle
    $analysisTabs.SelectedIndex = 1
    $largeFileList.Items[0].Selected = $true
    $script:AnalysisFocus = 'List'
    $entry = Get-ActiveAnalysisEntry
    if ($null -eq $entry -or -not (Test-Path -LiteralPath $entry.Path)) { throw 'Selected file entry not resolved.' }
    $dirTree.SelectedNode = $root.Nodes[0]
    $script:AnalysisFocus = 'Tree'
    if ((Get-ActiveAnalysisEntry).Path -ne (Join-Path $fixture 'app')) { throw 'Tree selection path wrong.' }
    $lines = @(Write-AnalysisReport -Result $result)
    if ($lines.Count -lt 10) { throw 'Report too short.' }
    $config = Get-ScheduleConfigFromUi
    if ($scheduleList.Items.Count -lt 10 -or @($config.ItemIds).Count -lt 1 -or $config.Time -notmatch '^\d\d:\d\d$') { throw 'Schedule page state wrong.' }
    if (@($config.ItemIds) -contains 'user-temp-old' -and -not (Test-Path -LiteralPath (Get-ScheduleConfigPath))) { throw 'Temp files preselected without consent.' }
    [pscustomobject]@{ Status = 'PASS'; Files = $result.TotalFiles; Suggestions = $suggestionList.Items.Count } | ConvertTo-Json | Set-Content -LiteralPath $ReportPath -Encoding UTF8
    'Analysis page verification passed'
}
finally {
    $workerTimer.Dispose(); $analysisTimer.Dispose(); $form.Dispose()
    if ((Split-Path $fixture -Leaf) -match '^CDriveCleanerUi_[0-9a-f]{32}$') { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
}
