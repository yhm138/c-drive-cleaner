#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$AppPath = '',
    [switch]$SkipWorker,
    [string]$ReportPath = ''
)

# This harness loads functions without launching the normal app. Catalog inspection is read-only.
# Every clean request has Action='Paths' and targets this invocation's own fixtures.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($AppPath)) { $AppPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'CDriveCleaner.ps1' }
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $PSScriptRoot 'TestResults\cleanup.json' }
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ReportPath))
$script:RegressionResults = New-Object 'System.Collections.Generic.List[object]'
$script:FixtureJunctions = New-Object 'System.Collections.Generic.List[string]'
$script:LiveWorkers = New-Object 'System.Collections.Generic.List[object]'
# The app deliberately supports C: only. Keep test fixtures on C: even when
# the repository is cloned to another drive. Never use the whole TEMP as a target.
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
if ([IO.Path]::GetPathRoot($tempRoot) -ne 'C:\' -or $tempRoot -eq 'C:') {
    throw 'These tests require the current user TEMP directory to be on C:. No fixtures were created.'
}
$workRoot = [IO.Path]::GetFullPath((Join-Path $tempRoot 'CDriveCleanerTests')).TrimEnd('\')
# Refuse redirected/reparse-point ancestors before creating or deleting fixtures.
$ancestor = $workRoot
while (-not [string]::IsNullOrWhiteSpace($ancestor)) {
    if ([IO.Directory]::Exists($ancestor) -and
        (([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw ('Fixture ancestor is a reparse point; test refused: ' + $ancestor)
    }
    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}
[void][IO.Directory]::CreateDirectory($workRoot)
$fixtureRoot = Join-Path $workRoot ('CDriveCleanerExtended_' + [guid]::NewGuid().ToString('N'))
if (-not $fixtureRoot.StartsWith($workRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
    ([IO.Path]::GetPathRoot($fixtureRoot) -ne 'C:\') -or
    ((Split-Path $fixtureRoot -Leaf) -notmatch '^CDriveCleanerExtended_[0-9a-f]{32}$')) {
    throw 'Fixture directory containment check failed.'
}
[void][IO.Directory]::CreateDirectory($fixtureRoot)

function Assert-Regression {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-RegressionCase {
    param([string]$Name, [scriptblock]$Body)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $detail = @(& $Body)
        $watch.Stop()
        $skipped = ($detail.Count -gt 0) -and ([string]$detail[0] -like 'SKIP:*')
        [void]$script:RegressionResults.Add([pscustomobject]@{
            Name = $Name; Passed = $true; Skipped = $skipped; Milliseconds = $watch.ElapsedMilliseconds; Detail = ($detail -join '; ')
        })
        $label = if ($skipped) { 'SKIP' } else { 'PASS' }
        Write-Host ('{0}  {1} ({2} ms) {3}' -f $label, $Name, $watch.ElapsedMilliseconds, ($detail -join '; '))
    }
    catch {
        $watch.Stop()
        [void]$script:RegressionResults.Add([pscustomobject]@{
            Name = $Name; Passed = $false; Skipped = $false; Milliseconds = $watch.ElapsedMilliseconds; Detail = $_.Exception.Message
        })
        Write-Host ('FAIL  {0}: {1}' -f $Name, $_.Exception.Message)
    }
}

function New-FixtureDirectory {
    param([string]$RelativePath)
    $candidate = [IO.Path]::GetFullPath((Join-Path $fixtureRoot $RelativePath))
    Assert-Regression ($candidate.StartsWith($fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase)) 'Fixture escaped its root.'
    [void][IO.Directory]::CreateDirectory($candidate)
    return $candidate
}

function New-SyntheticItem {
    param([string]$Id, [string]$Target, [string]$AllowedRoot)
    Assert-Regression ($Target.StartsWith($fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase)) 'Worker target escaped fixture.'
    Assert-Regression ($AllowedRoot.StartsWith($fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase)) 'Worker allowed root escaped fixture.'
    return [pscustomobject]@{
        Id = $Id; Name = $Id; Risk = '低'; DefaultSelected = $false; RequiresAdmin = $false
        Action = 'Paths'; PathSpecs = @([pscustomobject]@{Path = $Target; AllowedRoot = $AllowedRoot})
        ProcessNames = @(); Description = 'Synthetic regression fixture only'; EstimatedBytes = [int64]0
        ScanStatus = '未扫描'; InUse = $false; IdentityBlocked = $false
        MinAgeDays = 0; UseLogRetention = $false; FilePatterns = @('*'); SetupGuard = $false; ManageUri = ''
    }
}

function Start-FixtureWorker {
    param([string]$Mode, [object[]]$Items, [bool]$StopAtGoal = $false, [int64]$GoalBytes = [int64]::MaxValue, [int]$LogKeepDays = 7)
    foreach ($testItem in $Items) {
        Assert-Regression ($testItem.Action -eq 'Paths') 'Harness permits only Paths actions.'
        foreach ($spec in $testItem.PathSpecs) {
            Assert-Regression ([IO.Path]::GetFullPath($spec.Path).StartsWith($fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase)) 'Worker clean path escaped fixture.'
        }
    }
    $request = @{Mode = $Mode; ItemsXml = [Management.Automation.PSSerializer]::Serialize(@($Items), 10); GoalBytes = $GoalBytes; StopAtGoal = $StopAtGoal; LogKeepDays = $LogKeepDays}
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $worker = New-CleanupWorker -Request $request
    $watch.Stop()
    $worker | Add-Member -MemberType NoteProperty -Name RegressionStartMilliseconds -Value $watch.ElapsedMilliseconds
    [void]$script:LiveWorkers.Add($worker)
    return $worker
}

function Complete-FixtureWorker {
    param($Worker, [int]$TimeoutSeconds = 30, [switch]$AllowFailure)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $ticks = 0
    while (-not $Worker.Handle.IsCompleted) {
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
            $Worker.Cancellation.Cancel()
            throw ('Worker exceeded {0} seconds.' -f $TimeoutSeconds)
        }
        $ticks++
        Start-Sleep -Milliseconds 10
    }
    $invocationError = $null
    try { [void]$Worker.Shell.EndInvoke($Worker.Handle) }
    catch { $invocationError = $_.Exception.Message }
    $messages = New-Object 'System.Collections.Generic.List[object]'
    $entry = $null
    while ($Worker.State.Messages.TryDequeue([ref]$entry)) { [void]$messages.Add($entry); $entry = $null }
    $outcome = $Worker.State.Outcome
    $errors = @($Worker.Shell.Streams.Error | ForEach-Object { $_.ToString() })
    $result = [pscustomobject]@{
        State = $Worker.State; Outcome = $outcome; Messages = $messages.ToArray()
        InvocationError = $invocationError; Errors = $errors; PollTicks = $ticks
        Milliseconds = $watch.ElapsedMilliseconds; StartMilliseconds = $Worker.RegressionStartMilliseconds
    }
    $Worker.Shell.Dispose()
    if ($Worker.PSObject.Properties['Runspace']) { $Worker.Runspace.Dispose() }
    $Worker.Cancellation.Dispose()
    [void]$script:LiveWorkers.Remove($Worker)
    if (-not $AllowFailure) {
        Assert-Regression ($null -eq $invocationError) ('Worker threw: ' + $invocationError)
        Assert-Regression ($errors.Count -eq 0) ('Worker error stream: ' + ($errors -join ' | '))
    }
    return $result
}

try {
    $parseTokens = $null
    $parseErrors = $null
    $appFull = (Resolve-Path -LiteralPath $AppPath).Path
    $appAst = [Management.Automation.Language.Parser]::ParseFile($appFull, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ('App parse failure: ' + ($parseErrors.Message -join '; ')) }
    $functionNodes = $appAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
    # Dot-source definitions in this script scope, without evaluating top-level commands.
    foreach ($functionNode in $functionNodes) { . ([scriptblock]::Create($functionNode.Extent.Text)) }
    $script:ScriptPath = $appFull
    $script:IsAdministrator = Test-IsAdministrator
    $script:ElevationIdentityMismatch = $false
    $script:CurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $script:WorkerState = $null
    $script:WorkerCancellation = $null
    $script:ProgressClock = [Diagnostics.Stopwatch]::StartNew()
    $script:LogBox = $null

    Invoke-RegressionCase 'Containment rejects equal root, drive root, sibling prefix and parent traversal' {
        $allowed = New-FixtureDirectory 'boundary\allowed'
        $target = New-FixtureDirectory 'boundary\allowed\cache'
        $sibling = New-FixtureDirectory 'boundary\allowed-other\cache'
        Assert-Regression (Test-IsPathBelowRoot -Path $target -AllowedRoot $allowed) 'Valid child rejected.'
        Assert-Regression (-not (Test-IsPathBelowRoot -Path $allowed -AllowedRoot $allowed)) 'Equal root accepted.'
        Assert-Regression (-not (Test-IsPathBelowRoot -Path $sibling -AllowedRoot $allowed)) 'Sibling prefix accepted.'
        Assert-Regression (-not (Test-IsPathBelowRoot -Path $target -AllowedRoot 'C:\')) 'Drive root accepted.'
        Assert-Regression (-not (Test-IsPathBelowRoot -Path (Join-Path $allowed '..\allowed-other\cache') -AllowedRoot $allowed)) 'Parent traversal accepted.'
        $sentinel = Join-Path $sibling 'sentinel.txt'
        [IO.File]::WriteAllText($sentinel, 'must-survive')
        $rejected = $false
        try { [void](Clear-VerifiedDirectoryContents -Target $sibling -AllowedRoot $allowed) }
        catch { $rejected = $true }
        Assert-Regression $rejected 'Sibling cleanup did not reject request.'
        Assert-Regression ([IO.File]::ReadAllText($sentinel) -eq 'must-survive') 'Sibling sentinel altered.'
    }

    Invoke-RegressionCase 'Literal Unicode, bracket, read-only and locked files; root retained' {
        $allowed = New-FixtureDirectory 'files\allowed'
        $target = New-FixtureDirectory 'files\allowed\cache [测试]'
        $nested = New-FixtureDirectory 'files\allowed\cache [测试]\嵌套 [1]'
        $normal = Join-Path $target 'data[1].bin'
        $unicode = Join-Path $nested '中文缓存.txt'
        $readOnly = Join-Path $target 'readonly.bin'
        $locked = Join-Path $target 'locked.bin'
        [IO.File]::WriteAllText($normal, 'normal')
        [IO.File]::WriteAllText($unicode, 'unicode')
        [IO.File]::WriteAllText($readOnly, 'readonly')
        [IO.File]::SetAttributes($readOnly, [IO.FileAttributes]::ReadOnly)
        [IO.File]::WriteAllText($locked, 'locked')
        $handle = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $result = Clear-VerifiedDirectoryContents -Target $target -AllowedRoot $allowed
            Assert-Regression ([IO.Directory]::Exists($target)) 'Cache root was deleted.'
            Assert-Regression (-not [IO.File]::Exists($normal)) 'Literal bracket file survived.'
            Assert-Regression (-not [IO.File]::Exists($unicode)) 'Unicode file survived.'
            Assert-Regression (-not [IO.File]::Exists($readOnly)) 'Read-only file survived.'
            Assert-Regression ([IO.File]::Exists($locked)) 'Locked file was unexpectedly removed.'
            Assert-Regression ($result.Failed -ge 1) 'Locked file failure was not counted.'
            Assert-Regression ($result.Deleted -ge 3) 'Successful deletions were not counted.'
            'deleted={0}, failed={1}' -f $result.Deleted, $result.Failed
        }
        finally { $handle.Dispose() }
        [void](Clear-VerifiedDirectoryContents -Target $target -AllowedRoot $allowed)
        Assert-Regression (-not [IO.File]::Exists($locked)) 'Unlocked file cannot be cleaned.'
    }

    Invoke-RegressionCase 'Internal junction skipped without deleting retained parent or outside sentinel' {
        $allowed = New-FixtureDirectory 'junction\allowed'
        $target = New-FixtureDirectory 'junction\allowed\cache'
        $parent = New-FixtureDirectory 'junction\allowed\cache\retained'
        $outside = New-FixtureDirectory 'junction\outside'
        $junction = Join-Path $parent 'outside-link'
        $sentinel = Join-Path $outside 'sentinel.txt'
        [IO.File]::WriteAllText($sentinel, 'must-survive')
        [IO.File]::WriteAllText((Join-Path $parent 'ordinary.tmp'), 'remove-me')
        [void](New-Item -ItemType Junction -Path $junction -Target $outside)
        [void]$script:FixtureJunctions.Add($junction)
        $result = Clear-VerifiedDirectoryContents -Target $target -AllowedRoot $allowed
        Assert-Regression ([IO.File]::ReadAllText($sentinel) -eq 'must-survive') 'Outside sentinel altered.'
        Assert-Regression ([IO.Directory]::Exists($target)) 'Target directory deleted.'
        Assert-Regression ([IO.Directory]::Exists($parent)) 'Junction parent deleted.'
        Assert-Regression ([IO.Directory]::Exists($junction)) 'Junction deleted instead of skipped.'
        Assert-Regression (-not [IO.File]::Exists((Join-Path $parent 'ordinary.tmp'))) 'Ordinary file survived.'
        Assert-Regression ($result.Skipped -ge 1) 'Junction skip was not reported.'
        'skipped={0}, failed={1}' -f $result.Skipped, $result.Failed
    }

    Invoke-RegressionCase 'Ancestor junction rejected; destination sentinel retained' {
        $allowed = New-FixtureDirectory 'ancestor\allowed'
        $outside = New-FixtureDirectory 'ancestor\outside'
        $outsideCache = New-FixtureDirectory 'ancestor\outside\cache'
        $sentinel = Join-Path $outsideCache 'sentinel.txt'
        [IO.File]::WriteAllText($sentinel, 'must-survive')
        $junction = Join-Path $allowed 'link'
        [void](New-Item -ItemType Junction -Path $junction -Target $outside)
        [void]$script:FixtureJunctions.Add($junction)
        $rejected = $false
        try { [void](Clear-VerifiedDirectoryContents -Target (Join-Path $junction 'cache') -AllowedRoot $allowed) }
        catch { $rejected = $true }
        Assert-Regression $rejected 'Ancestor junction cleanup was accepted.'
        Assert-Regression ([IO.File]::ReadAllText($sentinel) -eq 'must-survive') 'Ancestor destination sentinel altered.'
    }


    $script:LogKeepDays = 7

    function Write-AgedFixture {
        param([string]$Path, [double]$Days, [int]$Size = 65536)
        Assert-Regression ([IO.Path]::GetFullPath($Path).StartsWith($fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase)) 'File escaped fixture root.'
        $data = New-Object byte[] $Size
        (New-Object Random 8742).NextBytes($data)
        [IO.File]::WriteAllBytes($Path, $data)
        [IO.File]::SetLastWriteTimeUtc($Path, [DateTime]::UtcNow.AddDays(-$Days))
        return $Path
    }

    Invoke-RegressionCase 'Exact UTC retention boundary is excluded consistently in filter, scan and deletion' {
        $cutoff = [DateTime]::SpecifyKind([DateTime]'2026-01-02T12:00:00', [DateTimeKind]::Utc)
        Assert-Regression (-not (Test-FileEligible -Name 'boundary.log' -LastWriteUtc $cutoff -CutoffUtc $cutoff -FilePatterns @('*.log'))) 'Exact cutoff was eligible.'
        Assert-Regression (Test-FileEligible -Name 'older.log' -LastWriteUtc $cutoff.AddTicks(-1) -CutoffUtc $cutoff -FilePatterns @('*.log')) 'One tick before cutoff was excluded.'
        Assert-Regression (-not (Test-FileEligible -Name 'newer.log' -LastWriteUtc $cutoff.AddTicks(1) -CutoffUtc $cutoff -FilePatterns @('*.log'))) 'One tick after cutoff was eligible.'
        Assert-Regression (-not (Test-FileEligible -Name 'message.log.db' -LastWriteUtc $cutoff.AddDays(-1) -CutoffUtc $cutoff -FilePatterns @('*.log'))) 'Extension prefix bypassed whitelist.'
        $allowed = New-FixtureDirectory 'exact\allowed'
        $target = New-FixtureDirectory 'exact\allowed\logs'
        $reference = New-FixtureDirectory 'exact\reference'
        $boundary = Write-AgedFixture (Join-Path $target 'boundary.log') 40
        $old = Write-AgedFixture (Join-Path $target 'older.log') 40
        [IO.File]::SetLastWriteTimeUtc($boundary, $cutoff)
        [IO.File]::SetLastWriteTimeUtc($old, $cutoff.AddSeconds(-1))
        [void](Write-AgedFixture (Join-Path $reference 'one.log') 40)
        $expected = Get-DirectoryBytes -Path $reference
        $actual = Get-DirectoryBytes -Path $target -FilePatterns @('*.log') -CutoffUtc $cutoff
        Assert-Regression ($actual -eq $expected) 'Exact-cutoff scan counted boundary file.'
        [void](Clear-VerifiedDirectoryContents -Target $target -AllowedRoot $allowed -FilePatterns @('*.log') -CutoffUtc $cutoff)
        Assert-Regression ([IO.File]::Exists($boundary) -and -not [IO.File]::Exists($old)) 'Exact-cutoff deletion disagreed with scan.'
    }

    Invoke-RegressionCase 'Extended item fields retain defaults and manual action is unselected' {
        $list = New-Object Collections.ArrayList
        Add-CleanupItem -List $list -Id 'old' -Name 'Legacy fixture' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action Paths
        Add-CleanupItem -List $list -Id 'new' -Name 'Extended fixture' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action Paths -MinAgeDays 30 -UseLogRetention $true -FilePatterns @('*.log', '*.etl') -SetupGuard $true
        Add-CleanupItem -List $list -Id 'manual' -Name 'Manual fixture' -Risk '高' -DefaultSelected $false -RequiresAdmin $false -Action Manage -ManageUri 'ms-settings:storagesense'
        Assert-Regression ($list[0].MinAgeDays -eq 0 -and -not $list[0].UseLogRetention) 'Legacy default policy changed.'
        Assert-Regression ($list[0].FilePatterns.Count -eq 1 -and $list[0].FilePatterns[0] -eq '*') 'Legacy wildcard not preserved.'
        Assert-Regression ($list[1].MinAgeDays -eq 30 -and $list[1].UseLogRetention -and $list[1].SetupGuard) 'Extended policy fields missing.'
        Assert-Regression ($list[2].Action -eq 'Manage' -and -not $list[2].DefaultSelected) 'Manual item unexpectedly selected.'
    }

    Invoke-RegressionCase 'Read-only catalog audit limits automatic cleanup to explicit cache or log leaves' {
        # Discovery may read existing directory names; no catalog action is dispatched.
        $list = New-Object Collections.ArrayList
        Add-ExtendedCleanupItems -List $list
        $approvedLeaves = @{
            'panther-monitor-logs' = '\\Windows\\Panther\\monitor$'
            'codex-ordinary-cache' = '\\(Cache|Code Cache|GPUCache)$'
            'claude-ordinary-cache' = '\\(Cache|Code Cache|GPUCache)$'
            'lark-ordinary-cache' = '\\(Cache|Code Cache|GPUCache)$'
            'codex-offline-cache' = '\\Service Worker\\CacheStorage$'
            'lark-offline-cache' = '\\Service Worker\\CacheStorage$'
            'wechat-old-logs' = '\\Tencent\\(xwechat|WeChat)\\log$'
            'trae-old-logs' = '\\(Trae|TRAE CN|TRAE SOLO|TRAE SOLO CN)\\logs$'
            'wolfram-old-logs' = '\\Wolfram\\Logs$'
            'codex-old-logs' = '\\Codex\\Logs$'
            'clash-old-logs' = '\\io\.github\.clash-verge-rev\.clash-verge-rev\\logs$'
            'nuitka-cache' = '\\Nuitka\\Nuitka\\Cache$'
            'cpp-intellisense-cache' = '\\Microsoft\\vscode-cpptools\\ipch$'
            'node-gyp-cache' = '\\node-gyp\\Cache$'
            'chrome-crash-reports' = '\\Google\\Chrome\\User Data\\Crashpad\\reports$'
            'edge-crash-reports' = '\\Microsoft\\Edge\\User Data\\Crashpad\\reports$'
        }
        $manualIds = @('manage-wechat-files', 'manage-downloads', 'manage-wechat-updates', 'manage-nvidia-updates', 'manage-app-updaters', 'manage-playwright', 'manage-jianying', 'manage-uv-cache', 'manage-windows-storage', 'manage-installed-apps')
        foreach ($item in $list) {
            Assert-Regression (-not $item.DefaultSelected) ('New item unexpectedly default selected: ' + $item.Id)
            if ($approvedLeaves.ContainsKey($item.Id)) {
                Assert-Regression ($item.Action -eq 'Paths') ('Automatic leaf action changed: ' + $item.Id)
                foreach ($spec in @($item.PathSpecs)) {
                    Assert-Regression ($spec.Path -match $approvedLeaves[$item.Id]) ('Unapproved path for ' + $item.Id + ': ' + $spec.Path)
                    Assert-Regression (Test-IsPathBelowRoot -Path $spec.Path -AllowedRoot $spec.AllowedRoot) ('Unbounded path for ' + $item.Id)
                }
                if ($item.UseLogRetention -or $item.Id -eq 'panther-monitor-logs') {
                    foreach ($name in @('messages.db', 'messages.log.db', 'messages.log.mmap', 'chat.sqlite', 'disk.vhdx')) {
                        Assert-Regression (-not (Test-FileEligible -Name $name -LastWriteUtc ([DateTime]::UtcNow.AddYears(-1)) -CutoffUtc ([DateTime]::UtcNow) -FilePatterns $item.FilePatterns)) ('Log whitelist admits protected type ' + $name + ' for ' + $item.Id)
                    }
                }
                if ($item.Id -like '*-offline-cache') { Assert-Regression ($item.Risk -ne '低' -and $item.Description -match '离线' -and $item.ProcessNames.Count -gt 0) 'Offline content lacks risk/process guard.' }
            }
            else {
                Assert-Regression ($manualIds -contains $item.Id) ('Unreviewed new item: ' + $item.Id)
                Assert-Regression ($item.Action -eq 'Manage') ('Sensitive data item permits automatic deletion: ' + $item.Id)
            }
        }
        Assert-Regression ($list.Count -eq ($approvedLeaves.Count + $manualIds.Count)) 'Catalog has missing or duplicate entries.'
        'read-only rows={0}, bounded automatic={1}, manual={2}' -f $list.Count, $approvedLeaves.Count, $manualIds.Count
    }

    Invoke-RegressionCase 'Old log whitelist excludes recent files, databases, extension prefixes and nested retained files' {
        $allowed = New-FixtureDirectory 'retention\allowed'
        $target = New-FixtureDirectory 'retention\allowed\logs'
        $nested = New-FixtureDirectory 'retention\allowed\logs\nested'
        $reference = New-FixtureDirectory 'retention\reference'
        $old = Write-AgedFixture (Join-Path $target 'old.LOG') 40
        $oldEtl = Write-AgedFixture (Join-Path $nested 'old.etl') 40
        $recent = Write-AgedFixture (Join-Path $target 'current.log') 1
        $unmatched = Write-AgedFixture (Join-Path $nested 'messages.db') 40
        $prefix = Write-AgedFixture (Join-Path $nested 'messages.log.db') 40
        [void](Write-AgedFixture (Join-Path $reference 'a.LOG') 40)
        [void](Write-AgedFixture (Join-Path $reference 'b.etl') 40)
        $expected = Get-DirectoryBytes -Path $reference
        $measured = Get-DirectoryBytes -Path $target -MinAgeDays 7 -FilePatterns @('*.log', '*.etl')
        Assert-Regression ($measured -eq $expected -and $measured -gt 0) ('Filtered estimate differs from eligible-file reference: ' + $measured + '/' + $expected)
        $result = Clear-VerifiedDirectoryContents -Target $target -AllowedRoot $allowed -MinAgeDays 7 -FilePatterns @('*.log', '*.etl')
        Assert-Regression (-not [IO.File]::Exists($old) -and -not [IO.File]::Exists($oldEtl)) 'Old eligible logs survived.'
        foreach ($keep in @($recent, $unmatched, $prefix)) { Assert-Regression ([IO.File]::Exists($keep)) ('Protected fixture removed: ' + $keep) }
        Assert-Regression ([IO.Directory]::Exists($target) -and [IO.Directory]::Exists($nested)) 'Directory containing retained data removed.'
        Assert-Regression ($result.Failed -eq 0) 'Expected retained files were incorrectly counted as deletion failures.'
        Assert-Regression ((Get-DirectoryBytes -Path $target -MinAgeDays 7 -FilePatterns @('*.log', '*.etl')) -eq 0) 'Post-clean estimate includes ineligible files.'
        'eligible bytes={0}, deleted={1}, failed={2}' -f $measured, $result.Deleted, $result.Failed
    }

    Invoke-RegressionCase 'Modification after scan is rechecked before deletion' {
        $allowed = New-FixtureDirectory 'mtime\allowed'
        $target = New-FixtureDirectory 'mtime\allowed\logs'
        $file = Write-AgedFixture (Join-Path $target 'changed.log') 40
        Assert-Regression ((Get-DirectoryBytes -Path $target -MinAgeDays 7 -FilePatterns @('*.log')) -gt 0) 'Old file was not eligible before change.'
        [IO.File]::SetLastWriteTimeUtc($file, [DateTime]::UtcNow)
        $result = Clear-VerifiedDirectoryContents -Target $target -AllowedRoot $allowed -MinAgeDays 7 -FilePatterns @('*.log')
        Assert-Regression ([IO.File]::Exists($file)) 'File updated after scan was removed.'
        Assert-Regression ($result.Failed -eq 0) 'Retained recently updated file counted as failure.'
    }

    Invoke-RegressionCase 'Minimum age 30 days protects 10-day files independently of log switch' {
        $allowed = New-FixtureDirectory 'minage\allowed'
        $target = New-FixtureDirectory 'minage\allowed\logs'
        $old = Write-AgedFixture (Join-Path $target 'old.log') 40
        $middle = Write-AgedFixture (Join-Path $target 'middle.log') 10
        [void](Clear-VerifiedDirectoryContents -Target $target -AllowedRoot $allowed -MinAgeDays 30 -FilePatterns @('*.log'))
        Assert-Regression (-not [IO.File]::Exists($old)) '40-day file survived 30-day retention.'
        Assert-Regression ([IO.File]::Exists($middle)) '10-day file removed with 30-day retention.'
    }

    Invoke-RegressionCase 'Manual manage dispatch cannot delete even with a valid synthetic path' {
        $allowed = New-FixtureDirectory 'manage\allowed'
        $target = New-FixtureDirectory 'manage\allowed\manual'
        $file = Write-AgedFixture (Join-Path $target 'sentinel.db') 40
        $item = New-SyntheticItem -Id 'manual-only' -Target $target -AllowedRoot $allowed
        $item.Action = 'Manage'
        $rejected = $false
        try { [void](Invoke-CleanupAction -Item $item) } catch { $rejected = $true }
        Assert-Regression $rejected 'Manage dispatch accepted an automatic clean request.'
        Assert-Regression ([IO.File]::Exists($file)) 'Manage dispatch deleted a file.'
    }

    Invoke-RegressionCase 'Windows setup guard blocks both measurement and deletion before reading fixture contents' {
        $allowed = New-FixtureDirectory 'setupguard\allowed'
        $target = New-FixtureDirectory 'setupguard\allowed\logs'
        $file = Write-AgedFixture (Join-Path $target 'old.log') 40
        $item = New-SyntheticItem -Id 'guarded-install-log' -Target $target -AllowedRoot $allowed
        $item.SetupGuard = $true
        $previousSetupGuard = ${function:Assert-WindowsSetupIdle}
        try {
            Set-Item -Path Function:script:Assert-WindowsSetupIdle -Value { throw 'SYNTHETIC_SETUP_BUSY' }
            $scanRejected = $false; $deleteRejected = $false
            try { [void](Measure-CleanupItem -Item $item) } catch { $scanRejected = $_.Exception.Message -match 'SYNTHETIC_SETUP_BUSY' }
            try { [void](Invoke-CleanupAction -Item $item) } catch { $deleteRejected = $_.Exception.Message -match 'SYNTHETIC_SETUP_BUSY' }
            Assert-Regression ($scanRejected -and $deleteRejected) 'Setup guard did not reject both scan and cleanup.'
            Assert-Regression ([IO.File]::Exists($file)) 'Setup-busy guard allowed deletion.'
        }
        finally { Set-Item -Path Function:script:Assert-WindowsSetupIdle -Value $previousSetupGuard }
    }

    Invoke-RegressionCase 'Process, administrator and Windows identity guards each retain fixtures' {
        $allowed = New-FixtureDirectory 'guards\allowed'
        $target = New-FixtureDirectory 'guards\allowed\cache'
        $file = Write-AgedFixture (Join-Path $target 'sentinel.bin') 40
        $item = New-SyntheticItem -Id 'guarded-cache' -Target $target -AllowedRoot $allowed
        $priorAdmin = $script:IsAdministrator
        try {
            $item.ProcessNames = @([Diagnostics.Process]::GetCurrentProcess().ProcessName)
            $rejected = $false
            try { [void](Invoke-CleanupAction -Item $item) } catch { $rejected = $true }
            Assert-Regression ($rejected -and [IO.File]::Exists($file)) 'Running-process guard failed.'
            $item.ProcessNames = @(); $item.RequiresAdmin = $true; $script:IsAdministrator = $false
            $rejected = $false
            try { [void](Invoke-CleanupAction -Item $item) } catch { $rejected = $true }
            Assert-Regression ($rejected -and [IO.File]::Exists($file)) 'Administrator guard failed.'
            $item.RequiresAdmin = $false; $item.IdentityBlocked = $true
            $rejected = $false
            try { [void](Invoke-CleanupAction -Item $item) } catch { $rejected = $true }
            Assert-Regression ($rejected -and [IO.File]::Exists($file)) 'Windows identity guard failed.'
        }
        finally { $script:IsAdministrator = $priorAdmin }
    }

    Invoke-RegressionCase 'Duplicate and overlapping paths do not double-count physical allocations' {
        $allowed = New-FixtureDirectory 'dedup\allowed'
        $target = New-FixtureDirectory 'dedup\allowed\cache'
        $nested = New-FixtureDirectory 'dedup\allowed\cache\nested'
        [void](Write-AgedFixture (Join-Path $target 'outer.bin') 40)
        [void](Write-AgedFixture (Join-Path $nested 'inner.bin') 40)
        $expected = Get-DirectoryBytes -Path $target
        $item = New-SyntheticItem -Id 'overlap' -Target $target -AllowedRoot $allowed
        $item.PathSpecs = @($item.PathSpecs[0], $item.PathSpecs[0], [pscustomobject]@{Path = $nested; AllowedRoot = $allowed})
        $actual = Measure-CleanupItem -Item $item
        Assert-Regression ($actual -eq $expected) ('Overlapping specs inflated bytes: ' + $actual + '/' + $expected)
    }

    Invoke-RegressionCase 'Hardlinks use a conservative estimate and retain external link contents' {
        $allowed = New-FixtureDirectory 'hardlinks\allowed'
        $target = New-FixtureDirectory 'hardlinks\allowed\cache'
        $outside = New-FixtureDirectory 'hardlinks\other'
        $file = Write-AgedFixture (Join-Path $target 'source.bin') 40
        $soloBytes = Get-DirectoryBytes -Path $target
        $link = Join-Path $target 'same-data.bin'
        $external = Join-Path $outside 'retained.bin'
        [void](New-Item -ItemType HardLink -Path $link -Target $file)
        [void](New-Item -ItemType HardLink -Path $external -Target $file)
        $measured = Get-DirectoryBytes -Path $target
        Assert-Regression ($measured -eq 0) ('Hardlink estimate assumed shared data releasable: ' + $measured + '/' + $soloBytes)
        [void](Clear-VerifiedDirectoryContents -Target $target -AllowedRoot $allowed)
        Assert-Regression ([IO.File]::Exists($file) -and [IO.File]::Exists($link)) 'Shared hardlinks were not protected during cleanup.'
        Assert-Regression ([IO.File]::Exists($external)) 'External hardlink removed.'
        Assert-Regression ((New-Object IO.FileInfo($external)).Length -eq 65536) 'External hardlink data altered.'
        'single bytes={0}, hardlink candidate bytes={1}' -f $soloBytes, $measured
    }

    Invoke-RegressionCase 'Precancelled filtered deletion retains all fixtures' {
        $allowed = New-FixtureDirectory 'cancel\allowed'
        $target = New-FixtureDirectory 'cancel\allowed\logs'
        $file = Write-AgedFixture (Join-Path $target 'eligible.log') 40
        $script:WorkerCancellation = New-Object Threading.CancellationTokenSource
        $script:WorkerCancellation.Cancel()
        $rejected = $false
        try { [void](Clear-VerifiedDirectoryContents -Target $target -AllowedRoot $allowed -MinAgeDays 7 -FilePatterns @('*.log')) } catch { $rejected = $true }
        finally { $script:WorkerCancellation.Dispose(); $script:WorkerCancellation = $null }
        Assert-Regression $rejected 'Cancellation did not interrupt cleanup.'
        Assert-Regression ([IO.File]::Exists($file)) 'Cancelled cleanup deleted data.'
    }

    Invoke-RegressionCase 'Compressed file estimate reflects stored bytes' {
        $target = New-FixtureDirectory 'compressed\cache'
        $file = Join-Path $target 'compressible.bin'
        [IO.File]::WriteAllBytes($file, (New-Object byte[] 1048576))
        $compact = Join-Path $env:SystemRoot 'System32\compact.exe'
        $output = @(& $compact /C /I /Q $file 2>&1)
        if ($LASTEXITCODE -ne 0 -or (([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::Compressed) -eq 0)) { 'SKIP: NTFS compression unavailable: ' + ($output -join ' '); return }
        $stored = Get-DirectoryBytes -Path $target
        Assert-Regression ($stored -ge 0 -and $stored -lt 262144) ('Compressed 1 MiB zero-file measured as logical size: ' + $stored)
        'logical=1048576, stored={0}' -f $stored
    }

    Invoke-RegressionCase 'Eight GiB sparse file is measured by allocation and deleted without allocating contents' {
        $allowed = New-FixtureDirectory 'sparse\allowed'
        $target = New-FixtureDirectory 'sparse\allowed\cache'
        $file = Join-Path $target 'large [8GiB].bin'
        [IO.File]::WriteAllBytes($file, (New-Object byte[] 0))
        $fsutil = Join-Path $env:SystemRoot 'System32\fsutil.exe'
        $output = @(& $fsutil sparse setflag $file 2>&1)
        if ($LASTEXITCODE -ne 0) { 'SKIP: sparse flag unavailable; large allocation not attempted.'; return }
        Assert-Regression (([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::SparseFile) -ne 0) 'Sparse flag absent; refusing large allocation.'
        $stream = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.SetLength([int64]8GB) } finally { $stream.Dispose() }
        $stored = Get-DirectoryBytes -Path $target
        Assert-Regression ($stored -ge 0 -and $stored -lt 1048576) ('Sparse allocation incorrectly estimated: ' + $stored)
        [void](Clear-VerifiedDirectoryContents -Target $target -AllowedRoot $allowed)
        Assert-Regression (-not [IO.File]::Exists($file)) 'Sparse file was not removed.'
        Assert-Regression ([IO.Directory]::Exists($target)) 'Sparse file root removed.'
        'logical=8589934592, stored={0}' -f $stored
    }

    if (-not $SkipWorker) {
        Invoke-RegressionCase 'Worker retention 30 days applies to scan and deletion; 7-day switch then exposes middle-aged log' {
            $allowed = New-FixtureDirectory 'worker-retention\allowed'
            $target = New-FixtureDirectory 'worker-retention\allowed\logs'
            $reference = New-FixtureDirectory 'worker-retention\reference'
            $old = Write-AgedFixture (Join-Path $target 'old.log') 40
            $middle = Write-AgedFixture (Join-Path $target 'middle.log') 10
            $recent = Write-AgedFixture (Join-Path $target 'current.log') 1
            $database = Write-AgedFixture (Join-Path $target 'messages.db') 40
            [void](Write-AgedFixture (Join-Path $reference 'one.log') 40)
            $expected = Get-DirectoryBytes -Path $reference
            $item = New-SyntheticItem -Id 'retention-worker' -Target $target -AllowedRoot $allowed
            $item.MinAgeDays = 7; $item.UseLogRetention = $true; $item.FilePatterns = @('*.log')
            $worker = Start-FixtureWorker -Mode Scan -Items @($item) -LogKeepDays 30
            $scan = Complete-FixtureWorker $worker
            $scanned = @($scan.Messages | Where-Object { $_.Kind -eq 'Scanned' })
            Assert-Regression ($scanned.Count -eq 1 -and $scanned[0].Item.EstimatedBytes -eq $expected) 'Worker 30-day scan disagrees with filter.'
            $worker = Start-FixtureWorker -Mode Clean -Items @($item) -LogKeepDays 30
            $clean = Complete-FixtureWorker $worker
            Assert-Regression (-not [IO.File]::Exists($old)) 'Worker 30-day cleanup left old log.'
            foreach ($keep in @($middle, $recent, $database)) { Assert-Regression ([IO.File]::Exists($keep)) 'Worker 30-day cleanup removed protected file.' }
            $worker = Start-FixtureWorker -Mode Scan -Items @($item) -LogKeepDays 7
            $scan7 = Complete-FixtureWorker $worker
            $scanned7 = @($scan7.Messages | Where-Object { $_.Kind -eq 'Scanned' })
            Assert-Regression ($scanned7.Count -eq 1 -and $scanned7[0].Item.EstimatedBytes -eq $expected) 'Worker 7-day retention failed to expose middle-aged log.'
            Assert-Regression ($scan.StartMilliseconds -lt 3000 -and $clean.StartMilliseconds -lt 3000) 'Worker startup blocked caller.'
            'scan30={0} ms, clean30={1} ms, scan7={2} ms' -f $scan.Milliseconds, $clean.Milliseconds, $scan7.Milliseconds
        }

        Invoke-RegressionCase 'Worker uses maximum of per-item age and user log retention' {
            $allowed = New-FixtureDirectory 'worker-max\allowed'
            $target = New-FixtureDirectory 'worker-max\allowed\logs'
            $old = Write-AgedFixture (Join-Path $target 'old.log') 40
            $middle = Write-AgedFixture (Join-Path $target 'middle.log') 10
            $item = New-SyntheticItem -Id 'minimum-thirty' -Target $target -AllowedRoot $allowed
            $item.MinAgeDays = 30; $item.UseLogRetention = $true; $item.FilePatterns = @('*.log')
            $worker = Start-FixtureWorker -Mode Clean -Items @($item) -LogKeepDays 7
            [void](Complete-FixtureWorker $worker)
            Assert-Regression (-not [IO.File]::Exists($old) -and [IO.File]::Exists($middle)) '7-day request overrode stricter per-item retention.'
        }
    }

}
finally {
    foreach ($worker in @($script:LiveWorkers.ToArray())) {
        try { $worker.Cancellation.Cancel() } catch {}
        try { $worker.Shell.Stop(); $worker.Shell.Dispose() } catch {}
        try { $worker.Cancellation.Dispose() } catch {}
    }
    # Resolve and verify every target before deleting any fixture junction.
    foreach ($junction in $script:FixtureJunctions) {
        $full = [IO.Path]::GetFullPath($junction)
        if (-not $full.StartsWith($fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Junction cleanup containment failed.' }
        if ([IO.Directory]::Exists($full)) {
            $attributes = [IO.File]::GetAttributes($full)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { throw 'Expected fixture junction changed type; cleanup refused.' }
            [IO.Directory]::Delete($full)
        }
    }
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')
    if ([IO.Path]::GetPathRoot($resolvedFixture) -ne 'C:\' -or
        -not $resolvedFixture.StartsWith($workRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        ((Split-Path $resolvedFixture -Leaf) -notmatch '^CDriveCleanerExtended_[0-9a-f]{32}$')) {
        throw 'Final recursive cleanup containment failed.'
    }
    if (Test-Path -LiteralPath $resolvedFixture) {
        $remainingReparsePoints = @(Get-ChildItem -LiteralPath $resolvedFixture -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
        if ($remainingReparsePoints.Count -gt 0) { throw 'Unexpected reparse point remains; fixture cleanup refused.' }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
    $report = [pscustomobject]@{
        AppPath = $AppPath; PowerShell = $PSVersionTable.PSVersion.ToString(); Timestamp = [DateTime]::Now.ToString('o')
        Passed = @($script:RegressionResults | Where-Object { $_.Passed -and (-not $_.Skipped) }).Count
        Failed = @($script:RegressionResults | Where-Object { -not $_.Passed }).Count
        Skipped = @($script:RegressionResults | Where-Object Skipped).Count
        Cases = $script:RegressionResults.ToArray()
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
}
Write-Host ('TOTAL: {0} passed, {1} failed, {2} skipped' -f $report.Passed, $report.Failed, $report.Skipped)
if ($report.Failed -gt 0) { exit 1 }
