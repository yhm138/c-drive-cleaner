#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$AppPath = '',
    [string]$ReportPath = ''
)
# This test only uses synthetic in-memory rows; it never starts a scan or cleanup.
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($AppPath)) { $AppPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'CDriveCleaner.ps1' }
$AppPath = (Resolve-Path -LiteralPath $AppPath).Path
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $PSScriptRoot 'TestResults\size-sort.json' }
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ReportPath))
$values = @(
    @('gb1', [int64]1GB, 'Paths', '可清理'),
    @('mb900', [int64]900MB, 'Paths', '可清理'),
    @('kb9', [int64]9KB, 'Paths', '可清理'),
    @('gb10', [int64]10GB, 'Paths', '可清理'),
    @('gb2', [int64]2GB, 'Paths', '可清理'),
    @('zero', [int64]0, 'Paths', '无内容'),
    @('rounded2', [int64](1GB + 2), 'Paths', '可清理'),
    @('rounded1', [int64](1GB + 1), 'Paths', '可清理'),
    @('max64', [int64]::MaxValue, 'Paths', '可清理'),
    @('unknown', [int64]0, 'Paths', '扫描失败'),
    @('unscanned', [int64]0, 'Paths', '未扫描'),
    @('rescan', [int64]0, 'Paths', '待重新扫描'),
    @('manual', [int64]0, 'Manage', '手动管理')
)
$fixtureItems = @($values | ForEach-Object {
    [pscustomobject]@{Id=$_[0]; Name=$_[0]; EstimatedBytes=$_[1]; Action=$_[2]; ScanStatus=$_[3]; Risk='低'; DefaultSelected=$false; RequiresAdmin=$false; InUse=$false; IdentityBlocked=$false; Description='Synthetic sorting fixture'; PathSpecs=@(); ProcessNames=@()}
})
$source = [IO.File]::ReadAllText($appPath)
$source = $source.Replace('$script:ScriptPath = $MyInvocation.MyCommand.Path', '$script:ScriptPath = $appPath')
$source = $source.Replace('$script:Items = @(Get-CleanupCatalog)', '$script:Items = @($fixtureItems)')
$source = $source.Substring(0, $source.LastIndexOf('if ($UiSmokeTest) {'))
. ([scriptblock]::Create($source))
try {
    foreach ($row in $grid.Rows) {
        $row.Cells['Estimated'].Value = switch ($row.Tag.Id) {
            unknown {'未知'}
            unscanned {'未扫描'}
            rescan {'待重新扫描'}
            manual {'仅管理'}
            default {Format-ByteSize $row.Tag.EstimatedBytes}
        }
    }
    $script:RowsById['mb900'].Cells['Selected'].Value = $true
    $asc = @('zero','kb9','mb900','gb1','rounded1','rounded2','gb2','gb10','max64')
    $desc = @('max64','gb10','gb2','rounded2','rounded1','gb1','mb900','kb9','zero')
    foreach ($direction in @('Ascending','Descending','Ascending')) {
        $grid.Sort($sizeColumn, [ComponentModel.ListSortDirection]$direction)
        $actual = @($grid.Rows | ForEach-Object {$_.Tag.Id})
        $expected = if ($direction -eq 'Ascending') {$asc} else {$desc}
        if (($actual[0..8] -join ',') -ne ($expected -join ',')) { throw ($direction + ' wrong: ' + ($actual -join ',')) }
        if (@($actual[9..12] | Where-Object {$_ -notin @('unknown','unscanned','rescan','manual')}).Count) { throw 'Unavailable size not at bottom' }
        if (@(Get-SelectedRows).Count -ne 1 -or @(Get-SelectedRows)[0].Tag.Id -ne 'mb900') { throw 'Selection changed identity after sorting' }
        if ($grid.Rows[$script:RowsById['gb1'].Index].Tag.Id -ne 'gb1') { throw 'Row identity map stale' }
    }
    $script:RowsById['kb9'].Tag.EstimatedBytes = [int64]11GB
    $script:RowsById['kb9'].Cells['Estimated'].Value = Format-ByteSize 11GB
    $grid.Sort($sizeColumn, [ComponentModel.ListSortDirection]::Descending)
    if ($grid.Rows[1].Tag.Id -ne 'kb9') { throw 'Updated byte value not used' }
    $grid.Sort($grid.Columns['ItemName'], [ComponentModel.ListSortDirection]::Ascending)
    if ($grid.Rows[0].Tag.Id -ne 'gb1') { throw 'Other column sorting broken' }
    [pscustomobject]@{Status='PASS'; Runtime=$PSVersionTable.PSVersion.ToString(); Cases=@('Ascending/descending/repeated sort','KB/MB/GB numeric order','Equal display text keeps byte precision','Int64 maximum','Unavailable sizes last both directions','Selection and row map preserved','Updated values','Other column sorting')} |
        ConvertTo-Json | Set-Content -LiteralPath $ReportPath -Encoding UTF8
    'Size sorting verification passed'
}
finally { $workerTimer.Dispose(); $form.Dispose() }
