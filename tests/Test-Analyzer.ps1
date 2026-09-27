#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$AppPath = '',
    [string]$ReportPath = '',
    # Registers and removes the real daily task. Only enable on disposable machines such as CI runners.
    [switch]$IncludeTaskRegistration
)

# Space analysis and scheduled cleanup regression tests. Analysis is read-only; every
# cleanup call targets fixtures created by this invocation under the user TEMP on C:.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($AppPath)) { $AppPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'CDriveCleaner.ps1' }
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $PSScriptRoot 'TestResults\analyzer.json' }
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ReportPath))
$script:Results = New-Object 'System.Collections.Generic.List[object]'

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
if ([IO.Path]::GetPathRoot($tempRoot) -ne 'C:\' -or $tempRoot -eq 'C:') { throw 'These tests require the user TEMP directory on C:.' }
$workRoot = Join-Path $tempRoot 'CDriveCleanerTests'
[void][IO.Directory]::CreateDirectory($workRoot)
$fixtureRoot = Join-Path $workRoot ('CDriveCleanerAnalyzer_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$outsideRoot = Join-Path $workRoot ('CDriveCleanerAnalyzerOutside_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($outsideRoot)
$junctionPath = $null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $detail = @(& $Body)
        $skipped = ($detail.Count -gt 0) -and ([string]$detail[0] -like 'SKIP:*')
        [void]$script:Results.Add([pscustomobject]@{ Name = $Name; Passed = $true; Skipped = $skipped; Milliseconds = $watch.ElapsedMilliseconds; Detail = ($detail -join '; ') })
        Write-Host ('{0}  {1} ({2} ms) {3}' -f $(if ($skipped) { 'SKIP' } else { 'PASS' }), $Name, $watch.ElapsedMilliseconds, ($detail -join '; '))
    }
    catch {
        [void]$script:Results.Add([pscustomobject]@{ Name = $Name; Passed = $false; Skipped = $false; Milliseconds = $watch.ElapsedMilliseconds; Detail = $_.Exception.Message })
        Write-Host ('FAIL  {0}: {1}' -f $Name, $_.Exception.Message)
    }
}

function New-SizedFile {
    param([string]$Path, [Int64]$Bytes, [int]$AgeDays = 0)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $stream = [IO.File]::Open($Path, 'Create', 'Write', 'None')
    try {
        # Write real data (not a sparse extension) so allocation matches the logical size.
        $block = New-Object byte[] (1MB)
        (New-Object Random 7).NextBytes($block)
        [Int64]$left = $Bytes
        while ($left -gt 0) { $n = [int][Math]::Min($left, $block.Length); $stream.Write($block, 0, $n); $left -= $n }
    }
    finally { $stream.Dispose() }
    if ($AgeDays -gt 0) { [IO.File]::SetLastWriteTimeUtc($Path, [DateTime]::UtcNow.AddDays(-$AgeDays)) }
    return $Path
}

try {
    $parseTokens = $null
    $parseErrors = $null
    $appFull = (Resolve-Path -LiteralPath $AppPath).Path
    $appAst = [Management.Automation.Language.Parser]::ParseFile($appFull, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ('App parse failure: ' + ($parseErrors.Message -join '; ')) }
    foreach ($functionNode in $appAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($functionNode.Extent.Text))
    }
    $script:ScriptPath = $appFull
    $script:IsAdministrator = Test-IsAdministrator
    $script:WorkerState = $null
    $script:WorkerCancellation = $null
    $script:ProgressClock = [Diagnostics.Stopwatch]::StartNew()
    $script:LogBox = $null
    $script:ScheduleConfigOverride = Join-Path $fixtureRoot 'config\schedule.json'

    # ---- fixture tree ----
    $expectedFiles = 0
    [Int64]$expectedBytes = 0
    New-SizedFile (Join-Path $fixtureRoot 'big\large.iso') 40MB | Out-Null; $expectedFiles++; $expectedBytes += 40MB
    New-SizedFile (Join-Path $fixtureRoot 'big\nested\深层 目录\中文文件.bin') 3MB | Out-Null; $expectedFiles++; $expectedBytes += 3MB
    New-SizedFile (Join-Path $fixtureRoot 'web\node_modules\pkg\bundle.js') 105MB | Out-Null; $expectedFiles++; $expectedBytes += 105MB
    New-SizedFile (Join-Path $fixtureRoot 'web\node_modules\pkg\node_modules\inner\index.js') 1KB | Out-Null; $expectedFiles++; $expectedBytes += 1KB
    New-SizedFile (Join-Path $fixtureRoot 'rust\target\debug\app.rlib') 102MB | Out-Null; $expectedFiles++; $expectedBytes += 102MB
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'rust\target\CACHEDIR.TAG'), 'Signature: 8a477f597d28d172789f06886806bc55'); $expectedFiles++; $expectedBytes += 43
    New-SizedFile (Join-Path $fixtureRoot 'crash\app.dmp') 20MB | Out-Null; $expectedFiles++; $expectedBytes += 20MB
    $denseDir = Join-Path $fixtureRoot 'many\small'
    [void][IO.Directory]::CreateDirectory($denseDir)
    $payload = [Text.Encoding]::ASCII.GetBytes('x' * 100)
    for ($i = 0; $i -lt 5200; $i++) { [IO.File]::WriteAllBytes((Join-Path $denseDir ('f{0:D5}.txt' -f $i)), $payload) }
    $expectedFiles += 5200; $expectedBytes += 5200 * 100
    New-SizedFile (Join-Path $outsideRoot 'must-not-count.bin') 30MB | Out-Null
    $junctionPath = Join-Path $fixtureRoot 'link-outside'
    [void](New-Item -ItemType Junction -Path $junctionPath -Target $outsideRoot)

    Invoke-Case 'Analyzer compiles under Windows PowerShell' {
        Initialize-DiskAnalyzer
        Assert-True ($null -ne ('DiskAnalyzer' -as [type])) 'DiskAnalyzer type missing.'
        'compiled'
    }

    $enumResult = $null
    Invoke-Case 'Enumeration engine counts files, sizes and skips junctions' {
        $script:enumResult = Invoke-DiskAnalysis -Root $fixtureRoot -PreferMft $false
        $r = $script:enumResult
        Assert-True ($r.Mode -like '*枚举*') ('Unexpected mode ' + $r.Mode)
        Assert-True ($r.TotalFiles -eq $expectedFiles) ('File count {0} expected {1}' -f $r.TotalFiles, $expectedFiles)
        Assert-True ($r.TotalLogical -eq $expectedBytes) ('Logical bytes {0} expected {1}' -f $r.TotalLogical, $expectedBytes)
        Assert-True ($r.FindDirectory($junctionPath) -lt 0) 'Junction was traversed as a directory.'
        Assert-True ($r.TopFiles[0].Path -eq (Join-Path $fixtureRoot 'web\node_modules\pkg\bundle.js')) ('Largest file wrong: ' + $r.TopFiles[0].Path)
        $children = @($r.GetChildren(0))
        for ($i = 1; $i -lt $children.Count; $i++) { Assert-True ($r.Nodes[$children[$i - 1]].Alloc -ge $r.Nodes[$children[$i]].Alloc) 'Children not sorted by size.' }
        $chinese = $r.FindDirectory((Join-Path $fixtureRoot 'big\nested\深层 目录'))
        Assert-True ($chinese -gt 0 -and $r.Nodes[$chinese].Files -eq 1) 'Unicode directory lookup failed.'
        'files={0}, dirs={1}, {2:N2}s' -f $r.TotalFiles, $r.TotalDirs, $r.Seconds
    }

    Invoke-Case 'Dense small-file folder and deletion suggestions are detected' {
        $r = $script:enumResult
        $dense = @($r.DenseDirs | Where-Object { $_.Path -eq $denseDir })
        Assert-True ($dense.Count -eq 1 -and $dense[0].Files -eq 5200) 'Dense directory not reported.'
        Assert-True (@($r.DenseDirs | Where-Object { $_.Path -eq $fixtureRoot }).Count -eq 0) 'Ancestor of dense directory also reported.'
        $categories = @{}
        foreach ($s in $r.Suggestions) { $categories[$s.Path] = $s }
        $nodeModules = Join-Path $fixtureRoot 'web\node_modules'
        Assert-True ($categories.ContainsKey($nodeModules) -and $categories[$nodeModules].CanRecycle) 'node_modules suggestion missing.'
        Assert-True (-not $categories.ContainsKey((Join-Path $fixtureRoot 'web\node_modules\pkg\node_modules'))) 'Nested node_modules reported separately.'
        Assert-True ($categories.ContainsKey((Join-Path $fixtureRoot 'rust\target'))) 'CACHEDIR.TAG build cache missing.'
        Assert-True ($categories.ContainsKey((Join-Path $fixtureRoot 'crash\app.dmp'))) 'Dump file suggestion missing.'
        $ext = @($r.Extensions | Where-Object { $_.Extension -eq 'txt' })
        Assert-True ($ext.Count -eq 1 -and $ext[0].Count -eq 5200) 'Extension statistics wrong.'
        'suggestions={0}, dense={1}' -f $r.Suggestions.Count, $r.DenseDirs.Count
    }

    Invoke-Case 'MFT engine reads the whole C: volume and matches the fixture exactly' {
        if (-not $script:IsAdministrator) { return 'SKIP: MFT reading requires administrator rights' }
        $r = Invoke-DiskAnalysis -Root 'C:\' -PreferMft $true
        Assert-True ($r.Mode -like '*MFT*') ('MFT engine not used: ' + $r.FallbackReason)
        $node = $r.FindDirectory($fixtureRoot)
        Assert-True ($node -gt 0) 'Fixture directory not found in MFT tree.'
        Assert-True ($r.Nodes[$node].Files -eq $expectedFiles) ('MFT file count {0} expected {1}' -f $r.Nodes[$node].Files, $expectedFiles)
        Assert-True ($r.Nodes[$node].Logical -eq $expectedBytes) ('MFT logical bytes {0} expected {1}' -f $r.Nodes[$node].Logical, $expectedBytes)
        Assert-True ($r.FindDirectory($junctionPath) -lt 0 -or $r.Nodes[$r.FindDirectory($junctionPath)].Files -eq 0) 'Junction contents counted.'
        $windows = $r.FindDirectory($env:SystemRoot)
        Assert-True ($windows -gt 0 -and $r.Nodes[$windows].Files -gt 10000) 'Windows directory missing from MFT tree.'
        $drive = New-Object IO.DriveInfo('C:\')
        $used = $drive.TotalSize - $drive.TotalFreeSpace
        # Allocation from the table should be in the same range as the volume's used space.
        Assert-True ($r.TotalAlloc -gt $used * 0.5 -and $r.TotalAlloc -lt $used * 1.3) ('MFT allocation {0} far from used space {1}' -f $r.TotalAlloc, $used)
        'files={0:N0}, dirs={1:N0}, alloc={2}, used={3}, {4:N1}s' -f $r.TotalFiles, $r.TotalDirs, (Format-ByteSize $r.TotalAlloc), (Format-ByteSize $used), $r.Seconds
    }

    Invoke-Case 'Background analysis can be cancelled' {
        Initialize-DiskAnalyzer
        $analyzer = New-Object DiskAnalyzer
        $analyzer.Start('C:\', $false)
        Start-Sleep -Milliseconds 300
        $analyzer.Cancel()
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $analyzer.Completed -and $watch.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 50 }
        Assert-True $analyzer.Completed 'Cancellation did not stop analysis.'
        Assert-True ($analyzer.Error -is [OperationCanceledException] -or $null -ne $analyzer.Result) ('Unexpected error: ' + $analyzer.Error)
        'stopped after {0} ms' -f $watch.ElapsedMilliseconds
    }

    Invoke-Case 'Protected locations are never offered for recycling' {
        foreach ($path in @($env:SystemRoot, (Join-Path $env:SystemRoot 'System32'), $env:ProgramFiles, 'C:\Users', $env:USERPROFILE, (Join-Path $env:USERPROFILE 'Downloads'), (Join-Path $env:USERPROFILE 'AppData\Local'), 'C:\', 'C:\pagefile.sys', 'C:\$Recycle.Bin')) {
            Assert-True ([DiskSuggestionRules]::IsProtectedPath($path)) ('Not protected: ' + $path)
        }
        Assert-True (-not [DiskSuggestionRules]::IsProtectedPath((Join-Path $fixtureRoot 'web\node_modules'))) 'Fixture wrongly protected.'
        Assert-True (-not (Test-RecyclablePath -Path (Join-Path $fixtureRoot 'missing.bin'))) 'Missing path reported recyclable.'
        Assert-True (-not (Test-RecyclablePath -Path (Join-Path $junctionPath 'must-not-count.bin'))) 'Path through junction reported recyclable.'
        Assert-True (Test-RecyclablePath -Path (Join-Path $fixtureRoot 'crash\app.dmp')) 'Ordinary fixture file not recyclable.'
        'protected checks ok'
    }

    Invoke-Case 'Catalog schedule-safe items are low-risk, user-level and age-limited' {
        $catalog = @(Get-CleanupCatalog)
        $eligible = @(Get-ScheduleEligibleItems -Items $catalog)
        Assert-True ($eligible.Count -ge 5) 'Too few schedule-safe items.'
        foreach ($item in $eligible) {
            Assert-True ($item.Risk -eq '低' -and -not $item.RequiresAdmin -and $item.Action -eq 'Paths') ('Unsafe schedule item ' + $item.Id)
            $policy = Get-CleanupPolicy $item
            Assert-True ($policy.MinAgeDays -ge 7) ('Schedule item without age protection: ' + $item.Id)
            Assert-True (@($item.FilePatterns) -notcontains '*' -or $item.Id -eq 'user-temp-old') ('Schedule item deletes every file type: ' + $item.Id)
        }
        foreach ($item in $catalog) {
            if ($item.Risk -ne '低' -or $item.RequiresAdmin -or $item.Action -ne 'Paths') { Assert-True (-not (Test-ScheduleSafeItem $item)) ('Risky item eligible: ' + $item.Id) }
        }
        'eligible: ' + (($eligible | ForEach-Object { $_.Id }) -join ', ')
    }

    Invoke-Case 'Schedule configuration round-trips and sanitises input' {
        Save-ScheduleConfig -Config ([pscustomobject]@{ Enabled = $true; Time = '07:45'; LogKeepDays = 30; ItemIds = @('trae-old-logs', 'bad id;rm') })
        $config = Get-ScheduleConfig
        Assert-True ($config.Enabled -and $config.Time -eq '07:45' -and $config.LogKeepDays -eq 30) 'Config values lost.'
        Assert-True (@($config.ItemIds).Count -eq 1 -and $config.ItemIds[0] -eq 'trae-old-logs') 'Invalid item id accepted.'
        [IO.File]::WriteAllText($script:ScheduleConfigOverride, '{"Enabled":true,"Time":"25:99","LogKeepDays":3,"ItemIds":[]}')
        $config = Get-ScheduleConfig
        Assert-True ($config.Time -eq '12:30' -and $config.LogKeepDays -eq 7) 'Invalid time or retention accepted.'
        [IO.File]::WriteAllText($script:ScheduleConfigOverride, 'not json')
        Assert-True (-not (Get-ScheduleConfig).Enabled) 'Corrupt config not handled.'
        'ok'
    }

    Invoke-Case 'Scheduled cleanup deletes only old logs of eligible items and skips the rest' {
        $allowed = Join-Path $fixtureRoot 'schedule'
        $logs = Join-Path $allowed 'logs'
        $old = New-SizedFile (Join-Path $logs 'old.log') 1KB -AgeDays 40
        $recent = New-SizedFile (Join-Path $logs 'recent.log') 1KB -AgeDays 1
        $oldDb = New-SizedFile (Join-Path $logs 'data.db') 1KB -AgeDays 40
        $riskyTarget = Join-Path $allowed 'risky'
        $riskyFile = New-SizedFile (Join-Path $riskyTarget 'old.log') 1KB -AgeDays 40
        $busyTarget = Join-Path $allowed 'busy'
        $busyFile = New-SizedFile (Join-Path $busyTarget 'old.log') 1KB -AgeDays 40
        $base = @{ DefaultSelected = $false; RequiresAdmin = $false; Action = 'Paths'; Description = 'fixture'; EstimatedBytes = [Int64]0; ScanStatus = ''; InUse = $false; IdentityBlocked = $false; MinAgeDays = 0; UseLogRetention = $true; FilePatterns = @('*.log'); SetupGuard = $false; ManageUri = '' }
        $safe = [pscustomobject]($base + @{ Id = 'fixture-safe'; Name = 'safe'; Risk = '低'; ScheduleSafe = $true; ProcessNames = @(); PathSpecs = @([pscustomobject]@{ Path = $logs; AllowedRoot = $allowed }) })
        $risky = [pscustomobject]($base + @{ Id = 'fixture-risky'; Name = 'risky'; Risk = '中'; ScheduleSafe = $true; ProcessNames = @(); PathSpecs = @([pscustomobject]@{ Path = $riskyTarget; AllowedRoot = $allowed }) })
        $busy = [pscustomobject]($base + @{ Id = 'fixture-busy'; Name = 'busy'; Risk = '低'; ScheduleSafe = $true; ProcessNames = @((Get-Process -Id $PID).ProcessName); PathSpecs = @([pscustomobject]@{ Path = $busyTarget; AllowedRoot = $allowed }) })
        $unselected = [pscustomobject]($base + @{ Id = 'fixture-unselected'; Name = 'unselected'; Risk = '低'; ScheduleSafe = $true; ProcessNames = @(); PathSpecs = @([pscustomobject]@{ Path = $riskyTarget; AllowedRoot = $allowed }) })
        $config = [pscustomobject]@{ Enabled = $true; Time = '12:30'; LogKeepDays = 7; ItemIds = @('fixture-safe', 'fixture-risky', 'fixture-busy') }
        $logPath = Join-Path $fixtureRoot 'schedule-logs\scheduled-20260101.log'
        $summary = Invoke-ScheduledCleanup -Config $config -Items @($safe, $risky, $busy, $unselected) -LogPath $logPath
        Assert-True (-not (Test-Path -LiteralPath $old)) 'Old log was not deleted.'
        Assert-True (Test-Path -LiteralPath $recent) 'Recent log was deleted.'
        Assert-True (Test-Path -LiteralPath $oldDb) 'Non-log file was deleted.'
        Assert-True (Test-Path -LiteralPath $riskyFile) 'Medium-risk item ran on schedule.'
        Assert-True (Test-Path -LiteralPath $busyFile) 'Item with running process was cleaned.'
        Assert-True ($summary.Ran -eq 1 -and $summary.Skipped -eq 2) ('Unexpected summary ran={0} skipped={1}' -f $summary.Ran, $summary.Skipped)
        $logText = [IO.File]::ReadAllText($logPath)
        Assert-True ($logText -match '完成：safe' -and $logText -match '跳过：risky' -and $logText -match '跳过：busy') 'Schedule log incomplete.'
        'ran={0}, skipped={1}' -f $summary.Ran, $summary.Skipped
    }

    Invoke-Case 'Old schedule logs are pruned by name and age only' {
        $dir = Join-Path $fixtureRoot 'prune'
        $oldLog = New-SizedFile (Join-Path $dir 'scheduled-20200101.log') 10 -AgeDays 60
        $newLog = New-SizedFile (Join-Path $dir 'scheduled-20260101.log') 10 -AgeDays 1
        $other = New-SizedFile (Join-Path $dir 'notes.log') 10 -AgeDays 60
        Remove-OldScheduleLogs -Directory $dir -KeepDays 30
        Assert-True (-not (Test-Path -LiteralPath $oldLog) -and (Test-Path -LiteralPath $newLog) -and (Test-Path -LiteralPath $other)) 'Log pruning removed the wrong files.'
        'ok'
    }

    Invoke-Case 'Daily task registers, reports state and unregisters' {
        if (-not $IncludeTaskRegistration) { return 'SKIP: pass -IncludeTaskRegistration on a disposable machine' }
        $config = [pscustomobject]@{ Enabled = $true; Time = '12:30'; LogKeepDays = 7; ItemIds = @('trae-old-logs') }
        Register-DailyCleanupTask -Config $config
        $task = Get-ScheduledTask -TaskPath '\CDriveCleaner\' -TaskName 'DailySafeCleanup'
        Assert-True ($null -ne $task) 'Task missing.'
        Assert-True ($task.Actions[0].Arguments -match '-ScheduledClean') 'Task arguments wrong.'
        Assert-True ($task.Principal.RunLevel -eq 'Limited') 'Task must not run elevated.'
        Assert-True (Test-Path -LiteralPath (Get-InstalledScriptPath)) 'Installed script copy missing.'
        Assert-True ((Get-DailyCleanupTaskState) -like '已启用*') 'Task state wrong.'
        Unregister-DailyCleanupTask
        Assert-True ($null -eq (Get-ScheduledTask -TaskPath '\CDriveCleaner\' -TaskName 'DailySafeCleanup' -ErrorAction SilentlyContinue)) 'Task still registered.'
        Assert-True (-not (Get-ScheduleConfig).Enabled) 'Config still enabled after unregister.'
        'registered and removed'
    }

    Invoke-Case 'Headless scheduled run and analysis report work from the command line' {
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $emptyConfig = Join-Path $fixtureRoot 'config\empty.json'
        [IO.File]::WriteAllText($emptyConfig, '{"Enabled":true,"Time":"12:30","LogKeepDays":7,"ItemIds":[]}')
        $output = & $powershell -NoProfile -ExecutionPolicy Bypass -File $appFull -ScheduledClean -ScheduleConfigPath $emptyConfig 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) ('Scheduled run failed: ' + $output)
        $report = & $powershell -NoProfile -ExecutionPolicy Bypass -File $appFull -AnalyzeOnly -AnalyzeRoot $fixtureRoot 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0 -and $report -match 'node_modules' -and $report -match '5,200') ('Analyze report wrong: ' + $report)
        'cli ok'
    }
}
finally {
    if ($null -ne $junctionPath -and [IO.Directory]::Exists($junctionPath)) { [IO.Directory]::Delete($junctionPath) }
    foreach ($dir in @($fixtureRoot, $outsideRoot)) {
        $full = [IO.Path]::GetFullPath($dir).TrimEnd('\')
        if ($full.StartsWith($workRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $full -Leaf) -match '^CDriveCleanerAnalyzer(Outside)?_[0-9a-f]{32}$' -and (Test-Path -LiteralPath $full)) {
            $reparse = @(Get-ChildItem -LiteralPath $full -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
            if ($reparse.Count -eq 0) { Remove-Item -LiteralPath $full -Recurse -Force }
        }
    }
    $report = [pscustomobject]@{
        PowerShell = $PSVersionTable.PSVersion.ToString(); Timestamp = [DateTime]::Now.ToString('o')
        Passed = @($script:Results | Where-Object { $_.Passed -and (-not $_.Skipped) }).Count
        Failed = @($script:Results | Where-Object { -not $_.Passed }).Count
        Skipped = @($script:Results | Where-Object Skipped).Count
        Cases = $script:Results.ToArray()
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
}
Write-Host ('TOTAL: {0} passed, {1} failed, {2} skipped' -f $report.Passed, $report.Failed, $report.Skipped)
if ($report.Failed -gt 0) { exit 1 }
