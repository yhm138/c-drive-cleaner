#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$ScanOnly,
    [switch]$UiSmokeTest,
    [switch]$SelfTest,
    [string]$PresetSelection = '',
    [int]$PresetGoalGB = 30,
    [ValidateSet('true', 'false')][string]$PresetStopAtGoal = 'true',
    [string]$OriginalSid = '',
    [ValidateSet(7, 30)][int]$PresetLogKeepDays = 7,
    [switch]$AnalyzeOnly,
    [string]$AnalyzeRoot = 'C:\',
    [switch]$ScheduledClean,
    [string]$ScheduleConfigPath = '',
    [hashtable]$WorkerRequest,
    [hashtable]$WorkerState,
    [System.Threading.CancellationTokenSource]$WorkerCancellation
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AppVersion = '2.2.0'
$script:ScriptPath = $MyInvocation.MyCommand.Path
$script:ScheduleConfigOverride = $ScheduleConfigPath
$script:IsAdministrator = $false
$script:Items = @()
$script:RowsById = @{}
$script:Busy = $false
$script:Worker = $null
$script:WorkerState = $WorkerState
$script:WorkerCancellation = $WorkerCancellation
$script:CloseWhenIdle = $false
$script:DriveInfo = $null
$script:LogKeepDays = $PresetLogKeepDays
$script:ProgressClock = [Diagnostics.Stopwatch]::StartNew()
$script:LogBox = $null
$script:CurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:ElevationIdentityMismatch = (-not [string]::IsNullOrWhiteSpace($OriginalSid)) -and ($OriginalSid -ne $script:CurrentSid)

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-ByteSize {
    param([Int64]$Bytes)

    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Get-CDriveInfo {
    $drive = New-Object IO.DriveInfo('C:\')
    return [pscustomobject]@{
        Size = [Int64]$drive.TotalSize
        Free = [Int64]$drive.AvailableFreeSpace
        Used = [Int64]($drive.TotalSize - $drive.AvailableFreeSpace)
    }
}

function New-PathSpec {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AllowedRoot
    )

    return [pscustomobject]@{
        Path = [Environment]::ExpandEnvironmentVariables($Path)
        AllowedRoot = [Environment]::ExpandEnvironmentVariables($AllowedRoot)
    }
}

function Add-CleanupItem {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.ArrayList]$List,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('低', '中', '高')][string]$Risk,
        [Parameter(Mandatory = $true)][bool]$DefaultSelected,
        [Parameter(Mandatory = $true)][bool]$RequiresAdmin,
        [Parameter(Mandatory = $true)][ValidateSet('Paths', 'RecycleBin', 'Hibernate', 'Manage')][string]$Action,
        [object[]]$PathSpecs = @(),
        [string[]]$ProcessNames = @(),
        [string]$Description = '',
        [ValidateRange(0, 3650)][int]$MinAgeDays = 0,
        [bool]$UseLogRetention = $false,
        [string[]]$FilePatterns = @('*'),
        [bool]$SetupGuard = $false,
        [string]$ManageUri = '',
        [bool]$ScheduleSafe = $false
    )

    [void]$List.Add([pscustomobject]@{
        Id = $Id
        Name = $Name
        Risk = $Risk
        DefaultSelected = $DefaultSelected
        RequiresAdmin = $RequiresAdmin
        Action = $Action
        PathSpecs = @($PathSpecs)
        ProcessNames = @($ProcessNames)
        Description = $Description
        MinAgeDays = $MinAgeDays
        UseLogRetention = $UseLogRetention
        FilePatterns = @($FilePatterns)
        SetupGuard = $SetupGuard
        ManageUri = $ManageUri
        ScheduleSafe = $ScheduleSafe
        ScanIssues = 0
        EstimatedBytes = [Int64]0
        ScanStatus = '未扫描'
        InUse = $false
        IdentityBlocked = $false
    })
}

function Get-BrowserPathSpecs {
    param(
        [Parameter(Mandatory = $true)][string]$UserDataRoot,
        [Parameter(Mandatory = $true)][ValidateSet('Normal', 'ServiceWorker')][string]$Kind
    )

    $result = @()
    if (-not (Test-Path -LiteralPath $UserDataRoot -PathType Container)) {
        return $result
    }

    $profiles = @(Get-ChildItem -LiteralPath $UserDataRoot -Force -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq 'Default' -or $_.Name -eq 'Guest Profile' -or $_.Name -like 'Profile *'
    })

    foreach ($profile in $profiles) {
        if ($Kind -eq 'Normal') {
            foreach ($relative in @('Cache', 'Code Cache', 'GPUCache')) {
                $result += New-PathSpec -Path (Join-Path $profile.FullName $relative) -AllowedRoot $UserDataRoot
            }
        }
        else {
            $result += New-PathSpec -Path (Join-Path $profile.FullName 'Service Worker\CacheStorage') -AllowedRoot $UserDataRoot
        }
    }

    return $result
}

function Get-JetBrainsPathSpecs {
    $result = @()
    $jetBrainsRoot = Join-Path $env:LOCALAPPDATA 'JetBrains'
    if (-not (Test-Path -LiteralPath $jetBrainsRoot -PathType Container)) {
        return $result
    }

    $productPattern = '^(PyCharm|IntelliJIdea|IdeaIC|Rider|WebStorm|CLion|GoLand|DataGrip|PhpStorm|RubyMine|RustRover|AndroidStudio)'
    $cacheNames = @('index', 'caches', 'python_stubs', 'full-line', 'jcef_cache', 'cpython-cache', 'vcs-log', 'icon-cache', 'log', 'tmp')
    $products = @(Get-ChildItem -LiteralPath $jetBrainsRoot -Force -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $productPattern })

    foreach ($product in $products) {
        foreach ($cacheName in $cacheNames) {
            $result += New-PathSpec -Path (Join-Path $product.FullName $cacheName) -AllowedRoot $product.FullName
        }
    }

    return $result
}

# Catalog extensions: bounded, literal discovery only. This fragment is inserted before Get-CleanupCatalog.
function Test-ExtendedSafeDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        if (-not ([IO.Path]::GetPathRoot($full)).Equals('C:\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { return $false }
        Assert-NoReparsePointInPathChain -Path $full
        return $true
    } catch { return $false }
}

function Get-ExtendedSafeChildDirectories {
    param([string]$Path, [string]$NamePattern = '*')
    if (-not (Test-ExtendedSafeDirectory -Path $Path)) { return }
    # Enumerate one known directory level; never recurse to search for names such as Cache.
    foreach ($directory in @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($directory.Name -like $NamePattern -and (Test-ExtendedSafeDirectory -Path $directory.FullName)) {
            $directory.FullName
        }
    }
}

function Get-ExtendedAppRoots {
    param([string]$PackagePattern, [string]$PackageRelativePath, [string[]]$FallbackPaths)
    $packageRoots = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($PackagePattern)) {
        $packages = Join-Path $env:LOCALAPPDATA 'Packages'
        foreach ($package in @(Get-ExtendedSafeChildDirectories -Path $packages -NamePattern $PackagePattern)) {
            $candidate = Join-Path $package $PackageRelativePath
            if (Test-ExtendedSafeDirectory -Path $candidate) { [void]$packageRoots.Add($candidate) }
        }
    }
    # MSIX app-data virtualization can expose the same files through the ordinary path.
    # Prefer the package roots as a group, rather than count both aliases.
    if ($packageRoots.Count -gt 0) { $packageRoots.ToArray(); return }
    foreach ($candidate in @($FallbackPaths)) {
        if (Test-ExtendedSafeDirectory -Path $candidate) { $candidate }
    }
}

function Get-ExtendedElectronProfileRoots {
    param([string[]]$Roots, [switch]$CodexWeb)
    $seen = @{}
    foreach ($root in @($Roots)) {
        $profiles = New-Object System.Collections.ArrayList
        [void]$profiles.Add($root)
        if ($CodexWeb) {
            foreach ($relative in @('web\Codex\Default', 'web\Codex\codex-browser-app')) {
                $profile = Join-Path $root $relative
                if (Test-ExtendedSafeDirectory -Path $profile) { [void]$profiles.Add($profile) }
            }
        }
        foreach ($profile in @($profiles.ToArray())) {
            if ((Test-ExtendedSafeDirectory -Path $profile) -and -not $seen.ContainsKey($profile)) {
                $seen[$profile] = $true
                $profile
            }
            foreach ($partition in @(Get-ExtendedSafeChildDirectories -Path (Join-Path $profile 'Partitions'))) {
                if (-not $seen.ContainsKey($partition)) { $seen[$partition] = $true; $partition }
            }
        }
    }
}

function Get-ExtendedLarkProfileRoots {
    $usersRoot = Join-Path $env:APPDATA 'LarkShell\aha\users'
    foreach ($account in @(Get-ExtendedSafeChildDirectories -Path $usersRoot)) {
        foreach ($profileName in @('profile_main', 'profile_explorer', 'profile_global')) {
            $profile = Join-Path $account $profileName
            if (Test-ExtendedSafeDirectory -Path $profile) {
                Get-ExtendedElectronProfileRoots -Roots @($profile)
            }
        }
    }
}

function Get-ExtendedLiteralPathSpecs {
    param([string[]]$Paths)
    $seen = @{}
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if ((Test-ExtendedSafeDirectory -Path $path) -and -not $seen.ContainsKey($path)) {
            $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
            $parent = [IO.Path]::GetDirectoryName($full)
            if (Test-IsPathBelowRoot -Path $full -AllowedRoot $parent) {
                $seen[$path] = $true
                New-PathSpec -Path $full -AllowedRoot $parent
            }
        }
    }
}

function Get-ExtendedElectronPathSpecs {
    param([string[]]$ProfileRoots, [switch]$Offline)
    $paths = New-Object System.Collections.ArrayList
    foreach ($profile in @($ProfileRoots)) {
        $children = @('Cache', 'Code Cache', 'GPUCache')
        if ($Offline) { $children = @('Service Worker\CacheStorage') }
        foreach ($child in $children) { [void]$paths.Add((Join-Path $profile $child)) }
    }
    Get-ExtendedLiteralPathSpecs -Paths @($paths.ToArray())
}

function Add-ExtendedCleanupItems {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.ArrayList]$List)

    Add-CleanupItem -List $List -Id 'panther-monitor-logs' -Name 'Windows 旧安装监控日志（30 天前）' -Risk '中' -DefaultSelected $false -RequiresAdmin $true -Action 'Paths' `
        -PathSpecs @(New-PathSpec -Path (Join-Path $env:WINDIR 'Panther\monitor') -AllowedRoot (Join-Path $env:WINDIR 'Panther')) `
        -MinAgeDays 30 -FilePatterns @('*.log') -SetupGuard $true `
        -Description '仅处理 Panther\monitor 中最后修改于 30 天前的 .log；安装、升级或等待重启时禁止清理。正在排查 Windows 升级问题时请保留。'

    $codexRoots = @(Get-ExtendedAppRoots -PackagePattern 'OpenAI.Codex_*' -PackageRelativePath 'LocalCache\Roaming\Codex' -FallbackPaths @((Join-Path $env:APPDATA 'Codex')))
    $claudeRoots = @(Get-ExtendedAppRoots -PackagePattern 'Claude_*' -PackageRelativePath 'LocalCache\Roaming\Claude' -FallbackPaths @((Join-Path $env:APPDATA 'Claude')))
    $codexProfiles = @(Get-ExtendedElectronProfileRoots -Roots $codexRoots -CodexWeb)
    $claudeProfiles = @(Get-ExtendedElectronProfileRoots -Roots $claudeRoots)
    $larkProfiles = @(Get-ExtendedLarkProfileRoots)
    Add-CleanupItem -List $List -Id 'codex-ordinary-cache' -Name 'Codex 普通网页缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedElectronPathSpecs -ProfileRoots $codexProfiles) -ProcessNames @('Codex') `
        -Description '关闭 Codex 后清理网页、代码与图形缓存；后续打开页面时会重建。范围不包括任务历史、数据库、登录数据及离线站点缓存。'
    Add-CleanupItem -List $List -Id 'claude-ordinary-cache' -Name 'Claude 普通网页缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedElectronPathSpecs -ProfileRoots $claudeProfiles) -ProcessNames @('Claude') `
        -Description '关闭 Claude 后清理网页、代码与图形缓存；不涉及 Claude Code 配置、会话、Cowork 虚拟机及用户文档。'
    Add-CleanupItem -List $List -Id 'lark-ordinary-cache' -Name '飞书普通网页缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedElectronPathSpecs -ProfileRoots $larkProfiles) -ProcessNames @('Lark', 'Feishu', 'LarkShell') `
        -Description '关闭飞书后清理各账户已识别网页配置中的普通缓存；不包含聊天附件、数据库、登录数据或离线站点缓存。'
    Add-CleanupItem -List $List -Id 'codex-offline-cache' -Name 'Codex 离线站点缓存' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedElectronPathSpecs -ProfileRoots $codexProfiles -Offline) -ProcessNames @('Codex') `
        -Description '会丢失 Codex 内嵌网页已缓存的离线内容；需要联网重新加载，部分内容可能无法恢复离线可用。关闭 Codex 后手动选择，仅处理 Service Worker\CacheStorage。'
    Add-CleanupItem -List $List -Id 'lark-offline-cache' -Name '飞书离线站点缓存' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedElectronPathSpecs -ProfileRoots $larkProfiles -Offline) -ProcessNames @('Lark', 'Feishu', 'LarkShell') `
        -Description '会丢失已缓存的离线网页或文档内容；需要联网重新加载，部分内容可能无法恢复离线可用。优先在飞书内管理，关闭飞书后再手动选择。'

    Add-CleanupItem -List $List -Id 'wechat-old-logs' -ScheduleSafe $true -Name '微信旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:APPDATA 'Tencent\xwechat\log'), (Join-Path $env:APPDATA 'Tencent\WeChat\log'))) `
        -UseLogRetention $true -FilePatterns @('*.xlog', '*.log') -ProcessNames @('WeChat', 'Weixin', 'WeChatAppEx') `
        -Description '按上方日志保留天数清理旧 .xlog/.log；保留近期文件及日志内存映射文件，不涉及聊天记录、附件和账户数据库。先退出微信。'
    Add-CleanupItem -List $List -Id 'trae-old-logs' -ScheduleSafe $true -Name 'TRAE 旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:APPDATA 'Trae\logs'), (Join-Path $env:APPDATA 'TRAE CN\logs'), (Join-Path $env:APPDATA 'TRAE SOLO\logs'), (Join-Path $env:APPDATA 'TRAE SOLO CN\logs'))) `
        -UseLogRetention $true -FilePatterns @('*.log') -ProcessNames @('Trae', 'Trae CN', 'TRAE SOLO', 'TRAE SOLO CN') `
        -Description '仅在各 TRAE 配置的 logs 目录按保留天数清理旧日志；保留项目、会话、扩展及运行工具。先关闭 TRAE。'
    Add-CleanupItem -List $List -Id 'wolfram-old-logs' -ScheduleSafe $true -Name 'Wolfram 旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:LOCALAPPDATA 'Wolfram\Logs'))) `
        -UseLogRetention $true -FilePatterns @('*.log') -ProcessNames @('Mathematica', 'WolframKernel', 'wolframscript', 'Wolfram') `
        -Description '按保留天数清理 Wolfram\Logs 中的旧日志；不涉及 Paclet、笔记本及安装组件。先退出 Wolfram 程序。'
    $codexLogRoots = @(Get-ExtendedAppRoots -PackagePattern 'OpenAI.Codex_*' -PackageRelativePath 'LocalCache\Local\Codex\Logs' -FallbackPaths @((Join-Path $env:LOCALAPPDATA 'Codex\Logs')))
    Add-CleanupItem -List $List -Id 'codex-old-logs' -ScheduleSafe $true -Name 'Codex 旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths $codexLogRoots) -UseLogRetention $true -FilePatterns @('*.log') -ProcessNames @('Codex') `
        -Description '按保留天数清理桌面应用 Logs 目录中的旧日志；保留 .codex 中的任务历史、数据库和所有工作文件。先关闭 Codex。'
    Add-CleanupItem -List $List -Id 'clash-old-logs' -ScheduleSafe $true -Name 'Clash Verge 旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\logs'))) `
        -UseLogRetention $true -FilePatterns @('*.log') -ProcessNames @('clash-verge', 'verge-mihomo', 'mihomo') `
        -Description '按保留天数清理已识别 logs 目录中的旧日志；近期增长的日志不会清理。保留订阅和规则配置，先退出 Clash Verge。'

    Add-CleanupItem -List $List -Id 'nuitka-cache' -Name 'Nuitka 编译与下载缓存' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:LOCALAPPDATA 'Nuitka\Nuitka\Cache'))) -ProcessNames @('python', 'pythonw', 'nuitka', 'scons', 'gcc', 'g++', 'cl', 'link') `
        -Description '包含下载及展开的编译工具和构建缓存，清理后编译可能重新下载较大资源并变慢。停止相关 Python/Nuitka 构建后手动选择。'
    Add-CleanupItem -List $List -Id 'cpp-intellisense-cache' -Name 'VS Code C++ 分析缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:LOCALAPPDATA 'Microsoft\vscode-cpptools\ipch'))) -ProcessNames @('Code', 'Code - Insiders', 'cpptools', 'cpptools-srv') `
        -Description '清理 C++ 预编译分析缓存；后续代码分析会重建，初次分析会变慢。先关闭 VS Code。'
    Add-CleanupItem -List $List -Id 'node-gyp-cache' -Name 'node-gyp 编译头文件缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:LOCALAPPDATA 'node-gyp\Cache'))) -ProcessNames @('node', 'msbuild', 'cl') `
        -Description '原生 Node 模块编译用的头文件缓存；后续构建需要时重新下载。停止相关 Node 构建后处理。'
    Add-CleanupItem -List $List -Id 'chrome-crash-reports' -Name 'Chrome 崩溃报告' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Crashpad\reports'))) -ProcessNames @('chrome') `
        -Description '仅清理 Crashpad\reports 中的崩溃报告；正在排查 Chrome 崩溃时请保留。先关闭 Chrome。'
    Add-CleanupItem -List $List -Id 'edge-crash-reports' -Name 'Edge 崩溃报告' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Crashpad\reports'))) -ProcessNames @('msedge') `
        -Description '仅清理 Crashpad\reports 中的崩溃报告；正在排查 Edge 崩溃时请保留。先关闭 Edge。'

    $documents = [Environment]::GetFolderPath('MyDocuments')
    $chatPaths = @((Join-Path $env:USERPROFILE 'xwechat_files'))
    if (-not [string]::IsNullOrWhiteSpace($documents)) { $chatPaths += @((Join-Path $documents 'xwechat_files'), (Join-Path $documents 'WeChat Files')) }
    Add-CleanupItem -List $List -Id 'manage-wechat-files' -Name '手动管理：微信聊天文件' -Risk '高' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths $chatPaths) `
        -Description '查看聊天文件目录，不参加清理。请在微信“设置 → 存储空间”中选择附件；目录包含聊天记录、数据库和迁移文件，不能整体清空。自定义存储位置请在微信中查看。'
    $downloadPath = Join-Path $env:USERPROFILE 'Downloads'
    try {
        $shellFolders = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop
        $downloadProperty = $shellFolders.PSObject.Properties['{374DE290-123F-4565-9164-39C4925E467B}']
        if ($null -ne $downloadProperty -and -not [string]::IsNullOrWhiteSpace([string]$downloadProperty.Value)) { $downloadPath = [Environment]::ExpandEnvironmentVariables([string]$downloadProperty.Value) }
    } catch { }
    Add-CleanupItem -List $List -Id 'manage-downloads' -Name '手动管理：下载文件夹' -Risk '高' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @($downloadPath)) `
        -Description '查看下载目录，不参加清理。打开目录后按大小或日期排序，由你选择已经不需要的文件；下载目录迁移到其他盘时不计入 C 盘。'
    Add-CleanupItem -List $List -Id 'manage-wechat-updates' -Name '手动管理：微信更新包' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:APPDATA 'Tencent\xwechat\update'))) `
        -Description '更新目录总大小不等于可删除的旧包大小。仅提供查看；先确认微信更新完成，再自行核实旧版本文件，不自动删除待安装包。'
    Add-CleanupItem -List $List -Id 'manage-nvidia-updates' -Name '手动管理：NVIDIA App 更新资源' -Risk '中' -DefaultSelected $false -RequiresAdmin $true -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:ProgramData 'NVIDIA Corporation\NVIDIA App\UpdateFramework'))) `
        -Description '新版 NVIDIA App 更新资源可能包含待安装和处理中内容，仅提供查看。先在 NVIDIA App 中确认更新完成，不整目录自动删除。'
    Add-CleanupItem -List $List -Id 'manage-app-updaters' -Name '手动管理：其他应用更新下载' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:LOCALAPPDATA 'antigravity-updater'), (Join-Path $env:LOCALAPPDATA 'xmind-updater'), (Join-Path $env:LOCALAPPDATA '@opencode-aidesktop-updater'))) `
        -Description '查看 Antigravity、XMind、OpenCode 的已知更新目录；pending 等内容可能尚待安装，需先确认更新完成。此项不自动清理。'
    Add-CleanupItem -List $List -Id 'manage-playwright' -Name '手动管理：Playwright 浏览器' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:LOCALAPPDATA 'ms-playwright'))) `
        -Description '浏览器运行依赖由 Playwright 按使用者与版本管理；Chromium 与 headless shell 不一定重复。仅显示目录，不自动删除，使用相应项目的 Playwright 管理功能回收不用的版本。'
    Add-CleanupItem -List $List -Id 'manage-jianying' -Name '手动管理：剪映资源缓存' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:LOCALAPPDATA 'JianyingPro\User Data\Cache'))) `
        -Description '含特效、模型与编辑资源，优先用剪映设置中的缓存管理；仅提供查看，不自动清理，不包含草稿和安装组件目录。'
    Add-CleanupItem -List $List -Id 'manage-uv-cache' -Name '手动管理：uv 缓存' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:LOCALAPPDATA 'uv\cache'))) `
        -Description '由 uv 自带缓存管理功能处理，不直接删除内部文件。可先用 uv cache dir 确认实际位置，再用 uv cache prune 回收过期内容；使用符号链接安装模式时需先检查环境依赖。'
    Add-CleanupItem -List $List -Id 'manage-windows-storage' -Name '系统管理：Windows 存储设置' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -ManageUri 'ms-settings:storagesense' `
        -Description '打开 Windows 存储设置，使用系统支持的临时文件和清理建议。此项不直接删除 Windows 组件、安装器缓存、驱动仓库或分页文件。'
    Add-CleanupItem -List $List -Id 'manage-installed-apps' -Name '系统管理：已安装应用' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -ManageUri 'ms-settings:appsfeatures' `
        -Description '打开已安装应用，按使用情况卸载或修改大型软件。工具链、虚拟机和已安装组件需通过所属程序管理，不作为普通缓存清空。'
}

function Get-AppLeafPathSpecs {
    param([string[]]$Roots, [string[]]$Leaves)
    # Only known leaf names under recognised application roots; nothing is searched recursively.
    $paths = New-Object System.Collections.ArrayList
    foreach ($root in @($Roots)) {
        if (-not (Test-ExtendedSafeDirectory -Path $root)) { continue }
        foreach ($leaf in @($Leaves)) { [void]$paths.Add((Join-Path $root $leaf)) }
    }
    Get-ExtendedLiteralPathSpecs -Paths @($paths.ToArray())
}

function Add-AppDataCleanupItems {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.ArrayList]$List)
    $logPatterns = @('*.log', '*.xlog')

    # QQ (QQNT is an Electron app; chat records live under Documents\Tencent Files and are never cleaned).
    $qqRoots = @((Join-Path $env:APPDATA 'QQ'), (Join-Path $env:APPDATA 'Tencent\QQNT'))
    $qqProfiles = @(Get-ExtendedElectronProfileRoots -Roots @($qqRoots | Where-Object { Test-ExtendedSafeDirectory -Path $_ }))
    Add-CleanupItem -List $List -Id 'qq-ordinary-cache' -Name 'QQ 普通网页缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedElectronPathSpecs -ProfileRoots $qqProfiles) -ProcessNames @('QQ', 'QQNT') `
        -Description '关闭 QQ 后清理客户端界面的网页、代码与图形缓存，打开时自动重建；不涉及聊天记录、数据库、图片视频和接收的文件。'
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $qqLogPaths = @((Join-Path $env:APPDATA 'Tencent\Logs'), (Join-Path $env:APPDATA 'QQ\logs'), (Join-Path $env:APPDATA 'Tencent\QQNT\logs'))
    $tencentFiles = @()
    if (-not [string]::IsNullOrWhiteSpace($documents)) { $tencentFiles = @((Join-Path $documents 'Tencent Files')) }
    foreach ($root in $tencentFiles) {
        foreach ($account in @(Get-ExtendedSafeChildDirectories -Path $root)) { $qqLogPaths += Join-Path $account 'nt_qq\nt_data\log' }
    }
    Add-CleanupItem -List $List -Id 'qq-old-logs' -Name 'QQ 旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths $qqLogPaths) -UseLogRetention $true -FilePatterns $logPatterns -ProcessNames @('QQ', 'QQNT') -ScheduleSafe $true `
        -Description '按保留天数清理 QQ 与各账号 nt_data\log 中的旧 .log/.xlog；不涉及聊天数据库、图片视频和接收的文件。先退出 QQ。'
    Add-CleanupItem -List $List -Id 'manage-qq-files' -Name '手动管理：QQ 聊天文件与缓存' -Risk '高' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths (@($tencentFiles) + @((Join-Path $env:APPDATA 'Tencent\QQNT')))) `
        -Description '查看 QQ 的聊天记录、图片视频和接收文件目录，不参加清理。请在 QQ“设置 → 存储管理”中清理缓存或迁移存储位置；目录内含聊天数据库，不能整体删除。'

    # 豆包 Doubao (Electron). Only ordinary caches and log files; models and downloads are managed in the app.
    $doubaoRoots = @((Join-Path $env:APPDATA 'Doubao'), (Join-Path $env:LOCALAPPDATA 'Doubao'), (Join-Path $env:LOCALAPPDATA 'Doubao\User Data'), (Join-Path $env:LOCALAPPDATA 'Doubao\User Data\Default'))
    $doubaoProfiles = @(Get-ExtendedElectronProfileRoots -Roots @($doubaoRoots | Where-Object { Test-ExtendedSafeDirectory -Path $_ }))
    Add-CleanupItem -List $List -Id 'doubao-ordinary-cache' -Name '豆包 普通网页缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedElectronPathSpecs -ProfileRoots $doubaoProfiles) -ProcessNames @('Doubao', 'doubao') `
        -Description '关闭豆包后清理网页、代码与图形缓存，打开时自动重建；不涉及登录状态、对话、下载的模型和生成的图片视频。'
    Add-CleanupItem -List $List -Id 'doubao-old-logs' -Name '豆包 旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-AppLeafPathSpecs -Roots $doubaoRoots -Leaves @('logs', 'log')) -UseLogRetention $true -FilePatterns $logPatterns -ProcessNames @('Doubao', 'doubao') -ScheduleSafe $true `
        -Description '按保留天数清理豆包 logs 目录中的旧日志文件；近期日志保留。先退出豆包。'
    Add-CleanupItem -List $List -Id 'manage-doubao-data' -Name '手动管理：豆包模型与生成内容' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-AppLeafPathSpecs -Roots @((Join-Path $env:APPDATA 'Doubao'), (Join-Path $env:LOCALAPPDATA 'Doubao')) -Leaves @('Models', 'models', 'Download', 'Downloads')) `
        -Description '查看豆包下载的本地模型、生成或下载的内容，不参加清理。请在豆包设置中管理；删除模型后相关功能需要重新下载。'

    # TRAE (VS Code fork): logs are handled by trae-old-logs; these are rebuildable caches.
    $traeRoots = @('Trae', 'TRAE CN', 'Trae CN', 'TRAE SOLO', 'TRAE SOLO CN') | ForEach-Object { Join-Path $env:APPDATA $_ }
    $codeForkLeaves = @('Cache', 'CachedData', 'Code Cache', 'GPUCache', 'CachedExtensionVSIXs')
    Add-CleanupItem -List $List -Id 'trae-cache' -Name 'TRAE 缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-AppLeafPathSpecs -Roots $traeRoots -Leaves $codeForkLeaves) -ProcessNames @('Trae', 'Trae CN', 'TRAE SOLO', 'TRAE SOLO CN') `
        -Description '关闭 TRAE 后清理网页、编译代码、图形和扩展安装包缓存，打开时重建；不涉及项目、会话记录、设置、扩展和 workspaceStorage。'

    # Google Antigravity (VS Code fork).
    $antigravityRoots = @((Join-Path $env:APPDATA 'Antigravity'), (Join-Path $env:APPDATA 'Antigravity IDE'))
    $antigravityProcesses = @('Antigravity', 'Antigravity IDE', 'antigravity')
    Add-CleanupItem -List $List -Id 'antigravity-cache' -Name 'Antigravity 缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-AppLeafPathSpecs -Roots $antigravityRoots -Leaves $codeForkLeaves) -ProcessNames $antigravityProcesses `
        -Description '关闭 Antigravity 后清理网页、编译代码、图形和扩展安装包缓存；不涉及对话、brain 计划与产出、设置和扩展。'
    Add-CleanupItem -List $List -Id 'antigravity-old-logs' -Name 'Antigravity 旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-AppLeafPathSpecs -Roots $antigravityRoots -Leaves @('logs')) -UseLogRetention $true -FilePatterns @('*.log') -ProcessNames $antigravityProcesses -ScheduleSafe $true `
        -Description '按保留天数清理 Antigravity logs 中的旧 .log，近期日志保留。先关闭 Antigravity。'
    Add-CleanupItem -List $List -Id 'manage-antigravity-data' -Name '手动管理：Antigravity 对话与产出' -Risk '高' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:USERPROFILE '.gemini\antigravity'))) `
        -Description '查看 ~/.gemini/antigravity（conversations 对话、brain 中的计划与产出、浏览器录制等），不参加清理。请在 Antigravity 中删除不需要的对话；直接删除文件会让历史记录无法打开。'

    # OpenAI Codex CLI. The desktop app's logs are covered by codex-old-logs.
    Add-CleanupItem -List $List -Id 'codex-cli-logs' -Name 'Codex CLI 旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:USERPROFILE '.codex\log'))) -UseLogRetention $true -FilePatterns @('*.log') -ProcessNames @('codex') -ScheduleSafe $true `
        -Description '按保留天数清理 ~/.codex/log 中的旧 .log（如 codex-tui.log）；正在写入的近期日志保留。不涉及 sessions 任务记录、配置和登录信息。'
    Add-CleanupItem -List $List -Id 'manage-codex-sessions' -Name '手动管理：Codex 任务记录' -Risk '高' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:USERPROFILE '.codex\sessions'), (Join-Path $env:USERPROFILE '.codex\archived_sessions'))) `
        -Description '查看 Codex 的会话记录（rollout 文件），不参加清理。删除后无法恢复或继续这些会话；如需回收空间，只删除确认不再需要的旧日期目录。'

    # Claude desktop app and Claude Code.
    $claudeRoots = @(Get-ExtendedAppRoots -PackagePattern 'Claude_*' -PackageRelativePath 'LocalCache\Roaming\Claude' -FallbackPaths @((Join-Path $env:APPDATA 'Claude')))
    Add-CleanupItem -List $List -Id 'claude-old-logs' -Name 'Claude 桌面版旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-AppLeafPathSpecs -Roots $claudeRoots -Leaves @('logs')) -UseLogRetention $true -FilePatterns @('*.log') -ProcessNames @('Claude') -ScheduleSafe $true `
        -Description '按保留天数清理 Claude 桌面版 logs 中的旧 .log（含 MCP 服务日志），近期日志保留。不涉及对话、配置和扩展。先退出 Claude。'
    Add-CleanupItem -List $List -Id 'claude-code-debug-logs' -Name 'Claude Code 旧调试日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:USERPROFILE '.claude\debug'))) -UseLogRetention $true -FilePatterns @('*.txt', '*.log') -ProcessNames @('claude') -ScheduleSafe $true `
        -Description '按保留天数清理 ~/.claude/debug 中的旧调试日志；不涉及 projects 会话记录、设置、记忆和插件。'
    Add-CleanupItem -List $List -Id 'manage-claude-code-history' -Name '手动管理：Claude Code 会话记录' -Risk '高' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:USERPROFILE '.claude\projects'), (Join-Path $env:USERPROFILE '.claude\file-history'))) `
        -Description '查看 Claude Code 的会话记录与文件历史，不参加清理。Claude Code 会按 settings.json 中的 cleanupPeriodDays（默认 30 天）自动删除旧会话，可调小该值；手动删除后无法 --resume 这些会话。'
}

function Add-InstalledAppCleanupItems {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.ArrayList]$List)
    $electronLeaves = @('Cache', 'Code Cache', 'GPUCache')

    # Microsoft Teams (new): only the WebView2 cache leaves, not sign-in or settings data.
    $teamsWebView = @(Get-ExtendedAppRoots -PackagePattern 'MSTeams_*' -PackageRelativePath 'LocalCache\Microsoft\MSTeams\EBWebView' -FallbackPaths @())
    # Classic Teams (Teams Machine-Wide Installer) is an Electron app under %APPDATA%\Microsoft\Teams.
    $teamsRoots = @(@($teamsWebView) + @($teamsWebView | ForEach-Object { Join-Path $_ 'Default' }) + @((Join-Path $env:APPDATA 'Microsoft\Teams')))
    $teamsProfiles = @(Get-ExtendedElectronProfileRoots -Roots @($teamsRoots | Where-Object { Test-ExtendedSafeDirectory -Path $_ }))
    Add-CleanupItem -List $List -Id 'teams-cache' -Name 'Microsoft Teams 普通网页缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedElectronPathSpecs -ProfileRoots $teamsProfiles) -ProcessNames @('ms-teams', 'msteams', 'Teams') `
        -Description '退出 Teams（新版及经典版）后清理内嵌网页的普通缓存；不涉及登录状态、聊天记录和设置。'

    Add-CleanupItem -List $List -Id 'adrive-cache' -Name '阿里云盘 缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-AppLeafPathSpecs -Roots @((Join-Path $env:APPDATA 'aDrive')) -Leaves $electronLeaves) -ProcessNames @('aDrive') `
        -Description '退出阿里云盘后清理客户端缓存（大量下载后可能很大）；未完成的下载需要重新开始，不涉及已下载到本地的文件和登录信息。'
    Add-CleanupItem -List $List -Id 'typora-cache' -Name 'Typora 普通网页缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-AppLeafPathSpecs -Roots @((Join-Path $env:APPDATA 'Typora')) -Leaves $electronLeaves) -ProcessNames @('Typora') `
        -Description '退出 Typora 后清理界面缓存；不涉及文档、草稿恢复目录、主题和设置。'

    # Developer tools found on this machine type.
    $vsRoots = New-Object System.Collections.ArrayList
    foreach ($pattern in @('17.0_*', '16.0_*', '15.0_*')) {
        foreach ($instance in @(Get-ExtendedSafeChildDirectories -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\VisualStudio') -NamePattern $pattern)) { [void]$vsRoots.Add($instance) }
    }
    Add-CleanupItem -List $List -Id 'visualstudio-cache' -Name 'Visual Studio 组件与设计器缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-AppLeafPathSpecs -Roots @($vsRoots.ToArray()) -Leaves @('ComponentModelCache', 'Designer\ShadowCache')) -ProcessNames @('devenv', 'Blend') `
        -Description '关闭 Visual Studio 后清理 MEF 组件缓存和设计器影子副本，下次启动自动重建（首次启动稍慢），也常用于修复扩展加载异常；不涉及设置、扩展和项目。'
    Add-CleanupItem -List $List -Id 'rustup-temp' -Name 'rustup 下载与临时文件' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-AppLeafPathSpecs -Roots @((Join-Path $env:USERPROFILE '.rustup')) -Leaves @('downloads', 'tmp')) -ProcessNames @('rustup', 'cargo', 'rustc') `
        -Description '清理 rustup 安装和更新留下的下载包与临时文件；不涉及已安装的工具链。先结束 rustup/cargo。'
    $texliveHomes = @(Get-ExtendedSafeChildDirectories -Path $env:USERPROFILE -NamePattern '.texlive*')
    Add-CleanupItem -List $List -Id 'texlive-luatex-cache' -Name 'TeX Live LuaTeX 字体缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-AppLeafPathSpecs -Roots $texliveHomes -Leaves @('texmf-var\luatex-cache')) -ProcessNames @('lualatex', 'luatex', 'luahbtex', 'latexmk', 'texworks') `
        -Description '清理各年份 TeX Live 的 LuaTeX 字体缓存；下次用 LuaLaTeX 编译时自动重建，首次编译会变慢。不涉及宏包和文档。'
    Add-CleanupItem -List $List -Id 'java-deployment-cache' -Name 'Java 部署缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:USERPROFILE 'AppData\LocalLow\Sun\Java\Deployment\cache'))) -ProcessNames @('javaw', 'javaws', 'jp2launcher') `
        -Description 'Java Web Start 与小程序下载的临时缓存，需要时重新下载；不涉及 JDK/JRE 和 Java 程序本身。'
    Add-CleanupItem -List $List -Id 'user-error-reports' -Name '用户级 Windows 错误报告' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-AppLeafPathSpecs -Roots @((Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER')) -Leaves @('ReportArchive', 'ReportQueue')) `
        -Description '删除当前用户的应用崩溃与错误报告（含附带的转储）；正在排查程序崩溃时请保留。'

    # Old logs; all have a retention guard and may run on the daily schedule.
    Add-CleanupItem -List $List -Id 'wemeet-old-logs' -Name '腾讯会议 旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:APPDATA 'Tencent\WeMeet\Global\Logs'), (Join-Path $env:APPDATA 'Tencent\WeMeet\Logs'))) `
        -UseLogRetention $true -FilePatterns @('*.log', '*.xlog') -ProcessNames @('wemeetapp', 'WeMeet', 'wemeet') -ScheduleSafe $true `
        -Description '按保留天数清理腾讯会议 Logs 中的旧 .log/.xlog（长期使用后可能达到数 GB）；不涉及会议录制文件和账号数据。先退出腾讯会议。'
    Add-CleanupItem -List $List -Id 'obs-old-logs' -Name 'OBS Studio 旧日志与崩溃报告' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-AppLeafPathSpecs -Roots @((Join-Path $env:APPDATA 'obs-studio')) -Leaves @('logs', 'crashes')) `
        -UseLogRetention $true -FilePatterns @('*.txt', '*.log') -ProcessNames @('obs64', 'obs32', 'obs') -ScheduleSafe $true `
        -Description '按保留天数清理 OBS 的 logs 与 crashes 中的旧文本日志；不涉及录像、场景和配置。先退出 OBS。'
    Add-CleanupItem -List $List -Id 'opencode-old-logs' -Name 'OpenCode 旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:USERPROFILE '.local\share\opencode\log'))) `
        -UseLogRetention $true -FilePatterns @('*.log') -ProcessNames @('opencode', 'OpenCode') -ScheduleSafe $true `
        -Description '按保留天数清理 ~/.local/share/opencode/log 中的旧日志；不涉及会话、项目数据和配置。'
    Add-CleanupItem -List $List -Id 'cfw-old-logs' -Name 'Clash for Windows 旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:USERPROFILE '.config\clash\logs'))) `
        -UseLogRetention $true -FilePatterns @('*.log') -ProcessNames @('Clash for Windows', 'clash-win64', 'clash') -ScheduleSafe $true `
        -Description '按保留天数清理 ~/.config/clash/logs 中的旧日志；不涉及订阅配置和规则。先退出 Clash for Windows。'

    # Large data that only its owning program should manage.
    $wslPaths = New-Object System.Collections.ArrayList
    foreach ($pattern in @('CanonicalGroupLimited.*', 'TheDebianProject.*', '*openSUSE*', 'KaliLinux.*', 'WhitewaterFoundryLtd.*')) {
        foreach ($package in @(Get-ExtendedSafeChildDirectories -Path (Join-Path $env:LOCALAPPDATA 'Packages') -NamePattern $pattern)) { [void]$wslPaths.Add((Join-Path $package 'LocalState')) }
    }
    [void]$wslPaths.Add((Join-Path $env:LOCALAPPDATA 'wsl'))
    Add-CleanupItem -List $List -Id 'manage-wsl-disks' -Name '手动管理：WSL 虚拟磁盘' -Risk '高' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @($wslPaths.ToArray())) `
        -Description '查看 WSL 发行版的 ext4.vhdx，不参加清理。先在 Linux 内删除不需要的文件，再运行 wsl --shutdown 和 wsl --manage <发行版> --set-sparse true 让磁盘自动收缩；也可用 wsl --manage <发行版> --move 迁移到其他盘。直接删除 vhdx 会丢失整个发行版。'
    Add-CleanupItem -List $List -Id 'manage-iphone-backups' -Name '手动管理：iPhone/iPad 备份' -Risk '高' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:APPDATA 'Apple Computer\MobileSync\Backup'), (Join-Path $env:USERPROFILE 'Apple\MobileSync\Backup'))) `
        -Description '查看 iTunes/Apple 设备的本地备份，单个备份可达数十 GB，不参加清理。请在 Apple Devices 或 iTunes 的“管理备份”中删除旧设备的备份。'
    Add-CleanupItem -List $List -Id 'manage-texlive' -Name '手动管理：TeX Live 安装' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @('C:\texlive')) `
        -Description '查看 TeX Live 各年份目录，不参加清理。只保留正在使用的年份，旧年份通过其卸载程序移除；可用 tlmgr 选项不安装文档和源码（tlmgr option docfiles 0 / srcfiles 0）来缩小体积。'
    Add-CleanupItem -List $List -Id 'manage-vs-installer-cache' -Name '手动管理：Visual Studio 安装包缓存' -Risk '中' -DefaultSelected $false -RequiresAdmin $true -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:ProgramData 'Microsoft\VisualStudio\Packages'))) `
        -Description '查看 Visual Studio Installer 的下载缓存，不参加清理。可在 Visual Studio Installer 中关闭“保留下载缓存”，或运行 vs_installer 时加 --nocache；手动删除后修复和修改工作负载需要重新下载。'
    Add-CleanupItem -List $List -Id 'manage-mysql-data' -Name '手动管理：MySQL 数据与二进制日志' -Risk '高' -DefaultSelected $false -RequiresAdmin $true -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:ProgramData 'MySQL'))) `
        -Description '查看 MySQL 数据目录，不参加清理。binlog 可能占用大量空间：在 MySQL 中执行 PURGE BINARY LOGS BEFORE NOW() - INTERVAL 7 DAY，或设置 binlog_expire_logs_seconds；切勿直接删除数据目录中的文件。'
    Add-CleanupItem -List $List -Id 'manage-capcut' -Name '手动管理：CapCut 资源缓存' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:LOCALAPPDATA 'CapCut\User Data\Cache'))) `
        -Description '含特效、素材与模型缓存，优先在 CapCut 设置中清理缓存；仅提供查看，不包含草稿。'
    Add-CleanupItem -List $List -Id 'manage-wechat-devtools' -Name '手动管理：微信开发者工具数据' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:LOCALAPPDATA '微信开发者工具\User Data'))) `
        -Description '查看微信开发者工具的用户数据，不参加清理。请在工具菜单“设置 → 清除缓存”中按类型清理（文件缓存、编译缓存、网络缓存等），避免误删登录态和项目配置。'
}

function Add-DeveloperAndMediaCleanupItems {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.ArrayList]$List)
    $electronLeaves = @('Cache', 'Code Cache', 'GPUCache')

    # Language toolchain caches; every one is regenerated by the tool that owns it.
    Add-CleanupItem -List $List -Id 'go-build-cache' -Name 'Go 编译缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:LOCALAPPDATA 'go-build'))) -ProcessNames @('go', 'gopls') `
        -Description '等同于 go clean -cache：清理编译结果缓存，下次构建会重新编译；不涉及模块下载缓存和源码。'
    Add-CleanupItem -List $List -Id 'julia-compiled-cache' -Name 'Julia 预编译缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:USERPROFILE '.julia\compiled'))) -ProcessNames @('julia') `
        -Description '清理 ~/.julia/compiled 中各版本的包预编译结果，下次 using 时重新预编译（首次加载会变慢）；不涉及已安装的包和环境。'
    Add-CleanupItem -List $List -Id 'scala-dependency-cache' -Name 'sbt / Coursier 依赖缓存' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:USERPROFILE '.ivy2\cache'), (Join-Path $env:LOCALAPPDATA 'Coursier\Cache'), (Join-Path $env:USERPROFILE '.cache\coursier'))) -ProcessNames @('sbt', 'java', 'cs', 'metals') `
        -Description 'Scala 构建下载的依赖缓存，与 Maven 仓库类似：可重新下载，但首次构建需要网络和时间；ivy 本地发布（publishLocal）的构件不在此目录。'
    Add-CleanupItem -List $List -Id 'yarn-cache' -Name 'Yarn 包缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:LOCALAPPDATA 'Yarn\Cache'))) -ProcessNames @('node', 'yarn') `
        -Description '等同于 yarn cache clean：需要时重新下载；不影响项目中已安装的 node_modules。'
    Add-CleanupItem -List $List -Id 'cpanm-work' -Name 'cpanm 构建目录' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:USERPROFILE '.cpanm\work'))) -ProcessNames @('cpanm', 'perl') `
        -Description 'Strawberry Perl 用 cpanm 安装模块时留下的解压和构建目录与构建日志；不涉及已安装的模块。'

    # Desktop apps.
    Add-CleanupItem -List $List -Id 'qq-legacy-temp' -Name 'QQ（旧版）临时文件' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:APPDATA 'Tencent\QQ\Temp'))) -ProcessNames @('QQ', 'QQProtect', 'TXPlatform') `
        -Description '旧版 QQ 9 的临时目录（发送与预览的临时副本）；不涉及聊天记录、图片和接收的文件。先退出 QQ。'
    Add-CleanupItem -List $List -Id 'lx-music-cache' -Name '洛雪音乐 缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-AppLeafPathSpecs -Roots @((Join-Path $env:APPDATA 'lx-music-desktop')) -Leaves $electronLeaves) -ProcessNames @('lx-music-desktop') `
        -Description '退出洛雪音乐后清理界面与播放缓存；不涉及歌单、设置和下载的歌曲。'
    Add-CleanupItem -List $List -Id 'motrix-cache' -Name 'Motrix 普通网页缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-AppLeafPathSpecs -Roots @((Join-Path $env:APPDATA 'Motrix')) -Leaves $electronLeaves) -ProcessNames @('Motrix', 'aria2c') `
        -Description '退出 Motrix 后清理界面缓存；不涉及下载任务、会话文件和已下载内容。'
    Add-CleanupItem -List $List -Id 'mathpix-cache' -Name 'Mathpix 普通网页缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-AppLeafPathSpecs -Roots @((Join-Path $env:APPDATA 'Mathpix Snipping Tool'), (Join-Path $env:APPDATA 'mathpix-snipping-tool')) -Leaves $electronLeaves) -ProcessNames @('Mathpix Snipping Tool', 'mathpix-snipping-tool') `
        -Description '退出 Mathpix 后清理界面缓存；识别历史保存在云端账号中，不受影响。'

    # Large data managed by its owner.
    Add-CleanupItem -List $List -Id 'manage-go-modules' -Name '手动管理：Go 模块下载缓存' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:USERPROFILE 'go\pkg\mod'))) `
        -Description '查看 Go 模块缓存，不参加清理（文件为只读，直接删除容易残留）。请运行 go clean -modcache，之后构建会重新下载依赖。'
    Add-CleanupItem -List $List -Id 'manage-bluestacks' -Name '手动管理：BlueStacks 模拟器数据' -Risk '高' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:ProgramData 'BlueStacks_nxt'), (Join-Path $env:ProgramData 'BlueStacks'))) `
        -Description '查看 BlueStacks 的虚拟机磁盘与引擎目录，不参加清理。请用 BlueStacks 多开管理器删除不用的实例，或在设置中执行“磁盘清理”；卸载后此目录可能残留，需要确认后手动删除。'
    Add-CleanupItem -List $List -Id 'manage-idm-temp' -Name '手动管理：IDM 下载临时文件' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Manage' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:APPDATA 'IDM\DwnlData'))) `
        -Description '查看 Internet Download Manager 未完成或已完成任务的分段临时文件，不参加清理。先在 IDM 中删除不需要的任务，再清理对应子目录；删除后无法续传。可在 IDM“选项 → 保存到”中把临时目录改到其他盘。'
}


function Get-CleanupCatalog {
    $list = New-Object System.Collections.ArrayList

    Add-CleanupItem -List $list -Id 'user-temp' -Name '用户临时文件' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(New-PathSpec -Path (Join-Path $env:LOCALAPPDATA 'Temp') -AllowedRoot $env:LOCALAPPDATA) `
        -Description '清除当前用户临时目录中所有未被占用的内容；正在使用的文件会跳过。可能影响等待重启的安装程序，需手动选择。'

    Add-CleanupItem -List $list -Id 'user-temp-old' -Name '用户临时文件（7 天前）' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(New-PathSpec -Path (Join-Path $env:LOCALAPPDATA 'Temp') -AllowedRoot $env:LOCALAPPDATA) -MinAgeDays 7 -ScheduleSafe $true `
        -Description '只删除临时目录中 7 天内未修改的文件，保留目录结构和近期文件；正在使用的文件会跳过。与 Windows 存储感知的临时文件清理规则相近，可加入定时清理。'

    Add-CleanupItem -List $list -Id 'pip-cache' -Name 'pip 下载缓存' -Risk '低' -DefaultSelected $true -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(New-PathSpec -Path (Join-Path $env:LOCALAPPDATA 'pip\Cache') -AllowedRoot (Join-Path $env:LOCALAPPDATA 'pip')) `
        -Description 'Python 包下载缓存。清理后需要时会重新下载，不会卸载已安装的包。'

    Add-CleanupItem -List $list -Id 'npm-cache' -Name 'npm / npx 缓存' -Risk '低' -DefaultSelected $true -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(New-PathSpec -Path (Join-Path $env:LOCALAPPDATA 'npm-cache') -AllowedRoot $env:LOCALAPPDATA) `
        -Description 'npm 包与 npx 临时缓存。清理后需要时会重新下载。'

    Add-CleanupItem -List $list -Id 'cargo-download-cache' -Name 'Cargo crates 下载缓存' -Risk '低' -DefaultSelected $true -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(New-PathSpec -Path (Join-Path $env:USERPROFILE '.cargo\registry\cache') -AllowedRoot (Join-Path $env:USERPROFILE '.cargo\registry')) `
        -Description 'Rust crates 压缩包下载缓存；不会删除工具链或已编译程序。'

    $cargoExpandedSpecs = @(
        (New-PathSpec -Path (Join-Path $env:USERPROFILE '.cargo\registry\src') -AllowedRoot (Join-Path $env:USERPROFILE '.cargo\registry')),
        (New-PathSpec -Path (Join-Path $env:USERPROFILE '.cargo\registry\index') -AllowedRoot (Join-Path $env:USERPROFILE '.cargo\registry')),
        (New-PathSpec -Path (Join-Path $env:USERPROFILE '.cargo\git') -AllowedRoot (Join-Path $env:USERPROFILE '.cargo'))
    )
    Add-CleanupItem -List $list -Id 'cargo-expanded-cache' -Name 'Cargo 源码与 Git 缓存' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs $cargoExpandedSpecs `
        -Description '解压源码、索引和 Git 依赖缓存；可重建，但后续构建可能需要较长时间和网络。'

    Add-CleanupItem -List $list -Id 'nuget-cache' -Name 'NuGet v3 缓存' -Risk '低' -DefaultSelected $true -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(New-PathSpec -Path (Join-Path $env:LOCALAPPDATA 'NuGet\v3-cache') -AllowedRoot (Join-Path $env:LOCALAPPDATA 'NuGet')) `
        -Description '.NET 包下载缓存；后续还原依赖时会重新下载。'

    Add-CleanupItem -List $list -Id 'gradle-cache' -Name 'Gradle 缓存' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(New-PathSpec -Path (Join-Path $env:USERPROFILE '.gradle\caches') -AllowedRoot (Join-Path $env:USERPROFILE '.gradle')) `
        -Description '包括 Gradle 依赖和构建缓存。可重建，但大型项目首次构建会明显变慢。'

    Add-CleanupItem -List $list -Id 'maven-repository' -Name 'Maven 本地仓库' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(New-PathSpec -Path (Join-Path $env:USERPROFILE '.m2\repository') -AllowedRoot (Join-Path $env:USERPROFILE '.m2')) `
        -Description '大多数依赖可重新下载；本地 mvn install 且未发布的构件可能无法恢复，请确认后再选。'

    $toolCacheSpecs = @()
    foreach ($name in @('huggingface', 'selenium', 'babeldoc', '.pwntools-cache-3.12', 'paddle', 'pdf2zh', 'tooling', 'yt-dlp')) {
        $toolCacheSpecs += New-PathSpec -Path (Join-Path (Join-Path $env:USERPROFILE '.cache') $name) -AllowedRoot (Join-Path $env:USERPROFILE '.cache')
    }
    Add-CleanupItem -List $list -Id 'tool-model-caches' -Name '模型与工具缓存' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs $toolCacheSpecs `
        -Description 'Hugging Face、Selenium、Babeldoc、pdf2zh 等缓存。可能需要重新下载较大的模型或浏览器驱动。'

    $codeRoot = Join-Path $env:APPDATA 'Code'
    $codeSpecs = @()
    foreach ($relative in @('Cache', 'CachedData', 'Code Cache', 'GPUCache', 'CachedExtensionVSIXs', 'logs', 'Crashpad\reports')) {
        $codeSpecs += New-PathSpec -Path (Join-Path $codeRoot $relative) -AllowedRoot $codeRoot
    }
    Add-CleanupItem -List $list -Id 'vscode-cache' -Name 'VS Code 缓存与日志' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs $codeSpecs `
        -ProcessNames @('Code') `
        -Description '不会删除扩展、设置或 workspaceStorage。关闭 VS Code 后清理更彻底。'

    Add-CleanupItem -List $list -Id 'jetbrains-cache' -Name 'JetBrains 索引与缓存' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-JetBrainsPathSpecs) `
        -ProcessNames @('idea64', 'pycharm64', 'rider64', 'webstorm64', 'clion64', 'goland64', 'datagrip64', 'phpstorm64', 'rubymine64', 'rustrover64') `
        -Description '仅清索引、日志和可重建缓存，不碰插件、项目、LocalHistory。下次打开 IDE 会重新索引。'

    $chromeRoot = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
    Add-CleanupItem -List $list -Id 'chrome-cache' -Name 'Chrome 普通缓存' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-BrowserPathSpecs -UserDataRoot $chromeRoot -Kind 'Normal') `
        -ProcessNames @('chrome') `
        -Description '清理各配置文件的 Cache、Code Cache、GPUCache；不删除 Cookie、密码或浏览记录。关闭 Chrome 后更彻底。'

    $edgeRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
    Add-CleanupItem -List $list -Id 'edge-cache' -Name 'Edge 普通缓存' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-BrowserPathSpecs -UserDataRoot $edgeRoot -Kind 'Normal') `
        -ProcessNames @('msedge') `
        -Description '清理各配置文件的 Cache、Code Cache、GPUCache；不删除 Cookie、密码或浏览记录。关闭 Edge 后更彻底。'

    Add-CleanupItem -List $list -Id 'chrome-service-worker' -Name 'Chrome 离线站点缓存' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-BrowserPathSpecs -UserDataRoot $chromeRoot -Kind 'ServiceWorker') `
        -ProcessNames @('chrome') `
        -Description '清除 Service Worker CacheStorage。网站离线内容会丢失，部分站点可能需要重新加载或登录。'

    Add-CleanupItem -List $list -Id 'edge-service-worker' -Name 'Edge 离线站点缓存' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-BrowserPathSpecs -UserDataRoot $edgeRoot -Kind 'ServiceWorker') `
        -ProcessNames @('msedge') `
        -Description '清除 Service Worker CacheStorage。网站离线内容会丢失，部分站点可能需要重新加载或登录。'

    Add-CleanupItem -List $list -Id 'crash-dumps' -Name '用户崩溃转储' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(New-PathSpec -Path (Join-Path $env:LOCALAPPDATA 'CrashDumps') -AllowedRoot $env:LOCALAPPDATA) `
        -Description '删除应用崩溃诊断文件；如果正在排查崩溃，请不要选择。'

    $graphicsSpecs = @(
        (New-PathSpec -Path (Join-Path $env:LOCALAPPDATA 'D3DSCache') -AllowedRoot $env:LOCALAPPDATA),
        (New-PathSpec -Path (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache') -AllowedRoot (Join-Path $env:LOCALAPPDATA 'NVIDIA')),
        (New-PathSpec -Path (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache') -AllowedRoot (Join-Path $env:LOCALAPPDATA 'NVIDIA')),
        (New-PathSpec -Path (Join-Path $env:USERPROFILE '.nv\ComputeCache') -AllowedRoot (Join-Path $env:USERPROFILE '.nv'))
    )
    Add-CleanupItem -List $list -Id 'graphics-cache' -Name '显卡与着色器缓存' -Risk '低' -DefaultSelected $true -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs $graphicsSpecs `
        -Description 'Direct3D、NVIDIA OpenGL/CUDA 缓存；首次运行游戏或计算任务时会重建。'

    Add-CleanupItem -List $list -Id 'nvidia-downloader' -Name 'NVIDIA 安装包下载缓存' -Risk '低' -DefaultSelected $false -RequiresAdmin $true -Action 'Paths' `
        -PathSpecs @(New-PathSpec -Path (Join-Path $env:PROGRAMDATA 'NVIDIA Corporation\Downloader') -AllowedRoot (Join-Path $env:PROGRAMDATA 'NVIDIA Corporation')) `
        -Description '旧显卡驱动安装包缓存。需要管理员权限；不会卸载当前驱动。'

    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $recycleRoot = 'C:\$Recycle.Bin'
    Add-CleanupItem -List $list -Id 'recycle-bin' -Name 'C 盘回收站' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'RecycleBin' `
        -PathSpecs @(New-PathSpec -Path (Join-Path $recycleRoot $sid) -AllowedRoot $recycleRoot) `
        -Description '永久清空当前用户的 C 盘回收站，之后无法从回收站恢复。'

    Add-CleanupItem -List $list -Id 'windows-temp' -Name 'Windows 系统临时文件' -Risk '中' -DefaultSelected $false -RequiresAdmin $true -Action 'Paths' `
        -PathSpecs @(New-PathSpec -Path (Join-Path $env:SystemRoot 'Temp') -AllowedRoot $env:SystemRoot) `
        -Description '清理 C:\Windows\Temp 中未被占用的内容，需要管理员权限。'

    $systemDumpSpecs = @(
        (New-PathSpec -Path (Join-Path $env:SystemRoot 'Minidump') -AllowedRoot $env:SystemRoot),
        (New-PathSpec -Path (Join-Path $env:SystemRoot 'LiveKernelReports') -AllowedRoot $env:SystemRoot)
    )
    Add-CleanupItem -List $list -Id 'system-dumps' -Name '系统与内核转储' -Risk '中' -DefaultSelected $false -RequiresAdmin $true -Action 'Paths' `
        -PathSpecs $systemDumpSpecs `
        -Description '删除蓝屏、驱动和内核故障诊断文件。正在排查系统问题时不要选择。'

    Add-CleanupItem -List $list -Id 'hibernate-file' -Name '关闭休眠并删除 hiberfil.sys' -Risk '高' -DefaultSelected $false -RequiresAdmin $true -Action 'Hibernate' `
        -Description '通常可释放大量空间，但会关闭休眠、快速启动及其他依赖休眠文件的功能。可稍后用 powercfg /hibernate on 恢复。'

    Add-ExtendedCleanupItems -List $list
    Add-AppDataCleanupItems -List $list
    Add-InstalledAppCleanupItems -List $list
    Add-DeveloperAndMediaCleanupItems -List $list
    return @($list)
}

function Assert-NoReparsePointInPathChain {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath)) { return }

    $current = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    while ($null -ne $current) {
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "为避免通过目录联接或符号链接越界，拒绝访问重解析路径：$($current.FullName)"
        }
        $current = $current.Parent
    }
}

function Test-WorkerCancellation {
    if ($null -ne $script:WorkerCancellation) {
        $script:WorkerCancellation.Token.ThrowIfCancellationRequested()
    }
}

function Set-WorkerPath {
    param([string]$Path, [switch]$Force)
    if ($null -ne $script:WorkerState -and ($Force -or $script:ProgressClock.ElapsedMilliseconds -ge 150)) {
        $script:WorkerState.CurrentPath = $Path
        $script:ProgressClock.Restart()
    }
}

function Initialize-FileMetadata {
    if ($null -ne ('CleanerFileMetadata' -as [type])) { return }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class CleanerEntry
{
    public string Key { get; internal set; }
    public long StoredBytes { get; internal set; }
    public long LogicalBytes { get; internal set; }
    public DateTime LastWriteUtc { get; internal set; }
    public FileAttributes Attributes { get; internal set; }
    public uint LinkCount { get; internal set; }
}

// Metadata only: does not read contents and opens the final reparse point itself.
// The caller must reject reparse points in ancestors and revalidate before deletion.
public static class CleanerFileMetadata
{
    private const uint ShareReadWriteDelete = 0x00000001 | 0x00000002 | 0x00000004;
    private const uint OpenExisting = 3;
    private const uint BackupSemanticsAndOpenReparsePoint = 0x02000000 | 0x00200000;
    private const int ErrorRetry = 1237;

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeFileTime
    {
        public uint Low;
        public uint High;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint Attributes;
        public NativeFileTime CreationTime;
        public NativeFileTime LastAccessTime;
        public NativeFileTime LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes,
        uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file, out ByHandleFileInformation information);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern uint GetCompressedFileSizeW(string fileName, out uint fileSizeHigh);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern void SetLastError(uint errorCode);

    private static string NativePath(string path)
    {
        if (String.IsNullOrEmpty(path))
            throw new ArgumentException("An absolute file path is required.", "path");

        // Never reinterpret an arbitrary device/UNC path as a C: path.
        if (path.StartsWith(@"\\?\C:\", StringComparison.OrdinalIgnoreCase))
            return path;
        if (path.Length >= 3 && (path[0] == 'C' || path[0] == 'c') &&
            path[1] == ':' && (path[2] == '\\' || path[2] == '/'))
        {
            string full = Path.GetFullPath(path);
            return @"\\?\" + full;
        }
        if (!Path.IsPathRooted(path) || (path.Length > 1 && path[1] == ':' &&
            (path.Length < 3 || (path[2] != '\\' && path[2] != '/'))))
            throw new ArgumentException("An absolute file path is required.", "path");
        return path;
    }

    private static ByHandleFileInformation ReadInfo(string path)
    {
        // Zero desired access is sufficient for metadata and works for read-only files.
        using (SafeFileHandle handle = CreateFileW(path, 0, ShareReadWriteDelete,
            IntPtr.Zero, OpenExisting, BackupSemanticsAndOpenReparsePoint, IntPtr.Zero))
        {
            if (handle.IsInvalid)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot open file metadata: " + path);
            ByHandleFileInformation info;
            if (!GetFileInformationByHandle(handle, out info))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot read file metadata: " + path);
            return info;
        }
    }

    private static long Join(uint high, uint low)
    {
        ulong value = ((ulong)high << 32) | low;
        if (value > Int64.MaxValue)
            throw new Win32Exception(534, "File size exceeds the supported signed 64-bit range.");
        return (long)value;
    }

    private static string Identity(ByHandleFileInformation info)
    {
        return info.VolumeSerialNumber.ToString("X8", CultureInfo.InvariantCulture) + ":" +
            info.FileIndexHigh.ToString("X8", CultureInfo.InvariantCulture) +
            info.FileIndexLow.ToString("X8", CultureInfo.InvariantCulture);
    }

    public static CleanerEntry Read(string path)
    {
        string nativePath = NativePath(path);
        ByHandleFileInformation info = ReadInfo(nativePath);
        FileAttributes attributes = (FileAttributes)info.Attributes;
        long storedBytes = 0;
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == 0)
        {
            uint high;
            // 0xFFFFFFFF is also a valid low DWORD, so clear and inspect last error.
            SetLastError(0);
            uint low = GetCompressedFileSizeW(nativePath, out high);
            int error = Marshal.GetLastWin32Error();
            if (low == UInt32.MaxValue && error != 0)
                throw new Win32Exception(error, "Cannot measure stored file bytes: " + path);
            storedBytes = Join(high, low);

            // The size API takes a path. Reject an observed replacement or modification
            // between that call and the metadata snapshot; a later delete needs its own check.
            ByHandleFileInformation after = ReadInfo(nativePath);
            if (Identity(info) != Identity(after) || info.Attributes != after.Attributes ||
                info.FileSizeHigh != after.FileSizeHigh || info.FileSizeLow != after.FileSizeLow ||
                info.LastWriteTime.High != after.LastWriteTime.High ||
                info.LastWriteTime.Low != after.LastWriteTime.Low ||
                info.NumberOfLinks != after.NumberOfLinks)
                throw new Win32Exception(ErrorRetry, "File changed during measurement; retry on the next scan: " + path);
        }

        CleanerEntry entry = new CleanerEntry();
        entry.Key = Identity(info);
        entry.StoredBytes = storedBytes;
        entry.LogicalBytes = Join(info.FileSizeHigh, info.FileSizeLow);
        entry.LastWriteUtc = DateTime.FromFileTimeUtc(Join(info.LastWriteTime.High, info.LastWriteTime.Low));
        entry.Attributes = attributes;
        entry.LinkCount = info.NumberOfLinks;
        return entry;
    }
}
'@ -ErrorAction Stop
    }
    catch { if ($null -eq ('CleanerFileMetadata' -as [type])) { throw } }
}

function Get-ItemOption {
    param($Item, [string]$Name, $Default)
    $property = $Item.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-CleanupPolicy {
    param($Item)
    $days = [int](Get-ItemOption $Item 'MinAgeDays' 0)
    if (Get-ItemOption $Item 'UseLogRetention' $false) {
        $setting = Get-Variable -Name LogKeepDays -Scope Script -ErrorAction SilentlyContinue
        $keep = if ($null -ne $setting -and $setting.Value -in @(7, 30)) { [int]$setting.Value } else { 7 }
        $days = [Math]::Max($days, $keep)
    }
    $referenceSetting = Get-Variable -Name PolicyReferenceUtc -Scope Script -ErrorAction SilentlyContinue
    $reference = if ($null -ne $referenceSetting) { [datetime]$referenceSetting.Value } else { [datetime]::UtcNow }
    $cutoff = if ($days -gt 0) { $reference.AddDays(-$days) } else { [datetime]::MaxValue }
    return @{ MinAgeDays = $days; FilePatterns = @(Get-ItemOption $Item 'FilePatterns' @('*')); CutoffUtc = $cutoff }
}

function Test-FileEligible {
    param([string]$Name, [datetime]$LastWriteUtc, [datetime]$CutoffUtc, [string[]]$FilePatterns = @('*'))
    if ($LastWriteUtc -ge $CutoffUtc) { return $false }
    foreach ($pattern in $FilePatterns) { if ($Name -like $pattern) { return $true } }
    return $false
}

function Assert-WindowsSetupIdle {
    foreach ($name in @('setup', 'setuphost', 'setupprep', 'WindowsUpdateBox')) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { throw '正在安装或升级 Windows，请完成后再清理安装日志。' }
    }
    $setup = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
    foreach ($name in @('SystemSetupInProgress', 'OOBEInProgress', 'SetupPhase')) {
        if ($null -ne $setup.PSObject.Properties[$name] -and [int]$setup.$name -ne 0) { throw 'Windows 安装尚未完成，暂不清理安装日志。' }
    }
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if (Test-Path -LiteralPath $key) { throw 'Windows 更新等待重启，请重启完成后再清理安装日志。' }
    }
}

function Get-DirectoryBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MinAgeDays = 0,
        [string[]]$FilePatterns = @('*'),
        [datetime]$CutoffUtc = [datetime]::MaxValue,
        [AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Seen,
        [hashtable]$Stats
    )
    Test-WorkerCancellation
    Set-WorkerPath -Path $Path -Force
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.Path]::GetPathRoot($full).Equals('C:\', [StringComparison]::OrdinalIgnoreCase)) { return [Int64]0 }
    try { $attributes = [IO.File]::GetAttributes($full) }
    catch {
        $cause = $_.Exception.GetBaseException()
        if ($cause -is [IO.FileNotFoundException] -or $cause -is [IO.DirectoryNotFoundException]) { return [Int64]0 }
        throw
    }
    if (($attributes -band [IO.FileAttributes]::Directory) -eq 0) { return [Int64]0 }
    Assert-NoReparsePointInPathChain -Path $full
    Initialize-FileMetadata
    if ($null -eq $Seen) { $Seen = New-Object 'System.Collections.Generic.HashSet[string]' }
    if ($null -eq $Stats) { $Stats = @{ Errors = 0; Shared = 0 } }
    if ($MinAgeDays -gt 0 -and $CutoffUtc -eq [datetime]::MaxValue) { $CutoffUtc = [datetime]::UtcNow.AddDays(-$MinAgeDays) }
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($full)
    [Int64]$bytes = 0
    while ($pending.Count -gt 0) {
        Test-WorkerCancellation
        $directory = $pending.Pop()
        $iterator = $null
        try {
            $metadata = [CleanerFileMetadata]::Read($directory)
            if (($metadata.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if (-not $Seen.Add($metadata.Key)) { continue }
            Set-WorkerPath -Path $directory
            $iterator = (New-Object IO.DirectoryInfo($directory)).EnumerateFileSystemInfos().GetEnumerator()
            while ($iterator.MoveNext()) {
                Test-WorkerCancellation
                $entry = $iterator.Current
                try {
                    $info = [CleanerFileMetadata]::Read($entry.FullName)
                    if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    if (($info.Attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Push($entry.FullName); continue }
                    if (-not (Test-FileEligible -Name $entry.Name -LastWriteUtc $info.LastWriteUtc -CutoffUtc $CutoffUtc -FilePatterns $FilePatterns)) { continue }
                    if (-not $Seen.Add($info.Key)) { continue }
                    # Shared hardlinks may still be needed outside this selection; do not promise their space.
                    if ($info.LinkCount -gt 1) { $Stats.Shared++; continue }
                    $bytes += $info.StoredBytes
                }
                catch { Test-WorkerCancellation; $Stats.Errors++ }
            }
        }
        catch { Test-WorkerCancellation; $Stats.Errors++ }
        finally { if ($null -ne $iterator) { $iterator.Dispose() } }
    }
    return $bytes
}

function Test-ItemProcessesRunning {
    param([Parameter(Mandatory = $true)]$Item)

    foreach ($processName in @($Item.ProcessNames)) {
        if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
            return $true
        }
    }
    return $false
}

function Measure-CleanupItem {
    param([Parameter(Mandatory = $true)]$Item)
    if ($Item.Action -eq 'Manage') { return [Int64]0 }
    if ($Item.Action -eq 'Hibernate') {
        $file = New-Object IO.FileInfo((Join-Path ([IO.Path]::GetPathRoot($env:SystemRoot)) 'hiberfil.sys'))
        if ($file.Exists) { return [Int64]$file.Length }
        return [Int64]0
    }
    if (Get-ItemOption $Item 'SetupGuard' $false) { Assert-WindowsSetupIdle }
    $policy = Get-CleanupPolicy $Item
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $stats = @{ Errors = 0; Shared = 0 }
    [Int64]$total = 0
    foreach ($spec in @($Item.PathSpecs)) {
        if ($null -eq $spec) { continue }
        $total += Get-DirectoryBytes -Path $spec.Path @policy -Seen $seen -Stats $stats
    }
    $Item | Add-Member -MemberType NoteProperty -Name ScanIssues -Value $stats.Errors -Force
    if ($stats.Errors -gt 0 -and $total -eq 0) { throw '部分目录或文件无法读取，空间未知。' }
    return $total
}

function Write-AppLog {
    param([string]$Message)

    if ($null -ne $script:LogBox) {
        if ($script:LogBox.TextLength -gt 100000) {
            $script:LogBox.Text = $script:LogBox.Text.Substring($script:LogBox.TextLength - 60000)
        }
        $script:LogBox.AppendText(('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) + [Environment]::NewLine)
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    }
}

function Test-IsPathBelowRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AllowedRoot
    )

    $pathFull = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $rootFull = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\')
    if ($rootFull -match '^[A-Za-z]:$') { return $false }
    $pathDrive = [IO.Path]::GetPathRoot($pathFull)
    $rootDrive = [IO.Path]::GetPathRoot($rootFull)
    if (-not $pathDrive.Equals('C:\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not $rootDrive.Equals('C:\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    return $pathFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Remove-SafeNode {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AllowedRoot,
        [Parameter(Mandatory = $true)][ref]$Deleted,
        [Parameter(Mandatory = $true)][ref]$Failed,
        [Parameter(Mandatory = $true)][ref]$SkippedReparse,
        [switch]$KeepRoot,
        [int]$MinAgeDays = 0,
        [string[]]$FilePatterns = @('*'),
        [datetime]$CutoffUtc = [datetime]::MaxValue
    )
    if (-not (Test-IsPathBelowRoot -Path $Path -AllowedRoot $AllowedRoot)) {
        throw "安全校验失败：$Path 不在允许目录 $AllowedRoot 内。"
    }
    Assert-NoReparsePointInPathChain -Path ([IO.Path]::GetDirectoryName($Path))
    Initialize-FileMetadata
    if ($MinAgeDays -gt 0 -and $CutoffUtc -eq [datetime]::MaxValue) { $CutoffUtc = [datetime]::UtcNow.AddDays(-$MinAgeDays) }
    $filtered = $MinAgeDays -gt 0 -or $CutoffUtc -ne [datetime]::MaxValue -or $FilePatterns.Count -ne 1 -or $FilePatterns[0] -ne '*'
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push(@{ Path = $Path; Iterator = $null; Opened = $false; Keep = [bool]$KeepRoot })
    try {
        while ($stack.Count -gt 0) {
            Test-WorkerCancellation
            $frame = $stack.Peek()
            Set-WorkerPath -Path $frame.Path
            try {
                if (-not $frame.Opened) {
                    if (-not (Test-IsPathBelowRoot -Path $frame.Path -AllowedRoot $AllowedRoot)) {
                        throw "安全校验失败：$($frame.Path)"
                    }
                    $attributes = [IO.File]::GetAttributes($frame.Path)
                    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $SkippedReparse.Value++
                        if ($null -ne $script:WorkerState) { $script:WorkerState.Skipped++ }
                        [void]$stack.Pop()
                        continue
                    }
                    if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                        Assert-NoReparsePointInPathChain -Path $frame.Path
                        $directory = New-Object IO.DirectoryInfo($frame.Path)
                        $frame.Iterator = $directory.EnumerateFileSystemInfos().GetEnumerator()
                        $frame.Opened = $true
                    }
                    else {
                        Test-WorkerCancellation
                        $info = [CleanerFileMetadata]::Read($frame.Path)
                        if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $info.LinkCount -gt 1) {
                            $SkippedReparse.Value++
                            if ($null -ne $script:WorkerState) { $script:WorkerState.Skipped++ }
                            [void]$stack.Pop()
                            continue
                        }
                        if (-not (Test-FileEligible -Name ([IO.Path]::GetFileName($frame.Path)) -LastWriteUtc $info.LastWriteUtc -CutoffUtc $CutoffUtc -FilePatterns $FilePatterns)) {
                            [void]$stack.Pop()
                            continue
                        }
                        # Recheck freshness immediately before deleting; log files can be updated after scanning.
                        if ([IO.File]::GetLastWriteTimeUtc($frame.Path) -ge $CutoffUtc) { [void]$stack.Pop(); continue }
                        if (($attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
                            [IO.File]::SetAttributes($frame.Path, ($attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
                        }
                        [IO.File]::Delete($frame.Path)
                        $Deleted.Value++
                        if ($null -ne $script:WorkerState) { $script:WorkerState.Deleted++ }
                        [void]$stack.Pop()
                        continue
                    }
                }
                if ($frame.Iterator.MoveNext()) {
                    $stack.Push(@{ Path = $frame.Iterator.Current.FullName; Iterator = $null; Opened = $false; Keep = $false })
                    continue
                }
                $frame.Iterator.Dispose()
                $frame.Iterator = $null
                Test-WorkerCancellation
                if (-not $frame.Keep -and (-not $filtered)) {
                    Assert-NoReparsePointInPathChain -Path $frame.Path
                    # Only remove an empty directory. Never prompt or recurse past skipped nodes.
                    $attributes = [IO.File]::GetAttributes($frame.Path)
                    if (($attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
                        [IO.File]::SetAttributes($frame.Path, ($attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
                    }
                    [IO.Directory]::Delete($frame.Path, $false)
                    $Deleted.Value++
                    if ($null -ne $script:WorkerState) { $script:WorkerState.Deleted++ }
                }
                [void]$stack.Pop()
            }
            catch {
                Test-WorkerCancellation
                $Failed.Value++
                if ($null -ne $script:WorkerState) { $script:WorkerState.Failed++ }
                if ($null -ne $frame.Iterator) { $frame.Iterator.Dispose(); $frame.Iterator = $null }
                [void]$stack.Pop()
            }
        }
    }
    finally {
        while ($stack.Count -gt 0) {
            $frame = $stack.Pop()
            if ($null -ne $frame.Iterator) { $frame.Iterator.Dispose() }
        }
    }
}

function Clear-VerifiedDirectoryContents {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$AllowedRoot,
        [int]$MinAgeDays = 0,
        [string[]]$FilePatterns = @('*'),
        [datetime]$CutoffUtc = [datetime]::MaxValue
    )

    $deleted = 0
    $failed = 0
    $skipped = 0

    if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
        return [pscustomobject]@{ Deleted = 0; Failed = 0; Skipped = 0 }
    }
    if (-not (Test-Path -LiteralPath $AllowedRoot -PathType Container)) {
        throw "允许目录不存在：$AllowedRoot"
    }

    Assert-NoReparsePointInPathChain -Path $AllowedRoot
    Assert-NoReparsePointInPathChain -Path $Target

    $rootResolved = (Resolve-Path -LiteralPath $AllowedRoot).Path.TrimEnd('\')
    $targetResolved = (Resolve-Path -LiteralPath $Target).Path.TrimEnd('\')
    Assert-NoReparsePointInPathChain -Path $rootResolved
    Assert-NoReparsePointInPathChain -Path $targetResolved
    if (-not (Test-IsPathBelowRoot -Path $targetResolved -AllowedRoot $rootResolved)) {
        throw "安全校验失败：$targetResolved 不在 $rootResolved 内。"
    }

    $targetItem = Get-Item -LiteralPath $targetResolved -Force
    if (($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "为避免跨目录误删，拒绝清理重解析点：$targetResolved"
    }

    Test-WorkerCancellation
    Remove-SafeNode -Path $targetResolved -AllowedRoot $rootResolved -Deleted ([ref]$deleted) -Failed ([ref]$failed) -SkippedReparse ([ref]$skipped) -KeepRoot -MinAgeDays $MinAgeDays -FilePatterns $FilePatterns -CutoffUtc $CutoffUtc

    return [pscustomobject]@{ Deleted = $deleted; Failed = $failed; Skipped = $skipped }
}

function Invoke-CleanupAction {
    param([Parameter(Mandatory = $true)]$Item)

    Test-WorkerCancellation
    if ($Item.Action -eq 'Manage') { throw '此项目只能查看或由对应应用管理，不能加入批量清理。' }
    if (Get-ItemOption $Item 'SetupGuard' $false) { Assert-WindowsSetupIdle }
    if ($Item.RequiresAdmin -and (-not $script:IsAdministrator)) { throw '此项目需要管理员权限。' }
    if ($Item.IdentityBlocked) {
        throw '提升使用了不同的 Windows 账户，为避免清理错误用户的数据，此项目已禁用。'
    }
    if (Test-ItemProcessesRunning -Item $Item) {
        throw '相关程序已在扫描后启动。请先关闭该程序并重新扫描。'
    }

    if ($Item.Action -eq 'Hibernate') {
        Set-WorkerPath -Path '正在执行系统休眠操作；停止将在本项返回后生效' -Force
        $powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
        $output = & $powercfg /hibernate off 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "关闭休眠失败：$output"
        }
        return [pscustomobject]@{ Failed = 0; Skipped = 0; Detail = '休眠已关闭' }
    }

    if ($Item.Action -eq 'RecycleBin') {
        $command = Get-Command Clear-RecycleBin -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            throw '当前 PowerShell 不提供 Clear-RecycleBin，未执行清空。'
        }
        Set-WorkerPath -Path '正在清空回收站；停止将在本项返回后生效' -Force
        Clear-RecycleBin -DriveLetter C -Force -Confirm:$false -ErrorAction Stop
        return [pscustomobject]@{ Failed = 0; Skipped = 0; Detail = '回收站已清空' }
    }

    $failed = 0
    $skipped = 0
    $deleted = 0
    $policy = Get-CleanupPolicy $Item
    foreach ($spec in @($Item.PathSpecs)) {
        Test-WorkerCancellation
        if (Test-ItemProcessesRunning -Item $Item) { throw '相关程序已启动，已停止本项。请关闭程序后重新扫描。' }
        if (Get-ItemOption $Item 'SetupGuard' $false) { Assert-WindowsSetupIdle }
        $result = Clear-VerifiedDirectoryContents -Target $spec.Path -AllowedRoot $spec.AllowedRoot @policy
        $failed += $result.Failed
        $skipped += $result.Skipped
        $deleted += $result.Deleted
    }
    return [pscustomobject]@{
        Failed = $failed
        Skipped = $skipped
        Detail = ('已删除 {0} 个文件/目录节点；保留未满足日期或类型条件的内容' -f $deleted)
    }
}


function Initialize-DiskAnalyzer {
    if ($null -ne ('DiskAnalyzer' -as [type])) { return }
    try {
        Add-Type -ReferencedAssemblies 'System.Core' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

// Read-only disk space analyzer. Two engines produce the same result model:
//  * NTFS MFT reader: reads the master file table of a volume sequentially (requires
//    administrator rights), which is how WizTree-class tools reach their speed.
//  * Enumeration: multi-threaded FindFirstFileEx walk that never follows reparse points.
// Nothing in this file writes to or deletes from the scanned volume.
public sealed class DiskDirNode
{
    public int Index;
    public int Parent = -1;
    public string Name;
    public long Alloc;
    public long Logical;
    public long Files;
    public long Dirs;
    public long DirectFiles;
    public long DirectAlloc;
    public long DirectLogical;
    public bool CacheTag;
    public bool VenvMarker;
    public List<int> Children;
}

public sealed class DiskFileEntry
{
    public int Parent;
    public string Name;
    public long Alloc;
    public long Logical;
    public DateTime LastWriteUtc;
    public string Path;
    public string Extension
    {
        get
        {
            int dot = Name.LastIndexOf('.');
            return dot <= 0 || dot == Name.Length - 1 ? "" : Name.Substring(dot + 1).ToLowerInvariant();
        }
    }
}

public sealed class DiskExtStat
{
    public string Extension;
    public long Count;
    public long Alloc;
    public long Logical;
}

public sealed class DiskDenseDir
{
    public int Node;
    public string Path;
    public long Files;
    public long Alloc;
    public long Logical;
    public long AverageBytes;
}

public sealed class DiskSuggestion
{
    public string Path;
    public bool IsDirectory;
    public string Category;
    public string Risk;
    public long Bytes;
    public string Advice;
    public bool CanRecycle;
    public string CatalogId;
}

public sealed class DiskAnalysisResult
{
    public string Root;
    public string Mode;
    public List<DiskDirNode> Nodes = new List<DiskDirNode>();
    public List<DiskFileEntry> TopFiles = new List<DiskFileEntry>();
    public List<DiskFileEntry> LargeFiles = new List<DiskFileEntry>();
    public List<DiskDenseDir> DenseDirs = new List<DiskDenseDir>();
    public List<DiskExtStat> Extensions = new List<DiskExtStat>();
    public List<DiskSuggestion> Suggestions = new List<DiskSuggestion>();
    public long TotalFiles;
    public long TotalDirs;
    public long TotalAlloc;
    public long TotalLogical;
    public long Errors;
    public double Seconds;
    public string FallbackReason = "";
    public string Timings = "";
    private string[] pathCache;

    public string GetPath(int index)
    {
        if (index < 0 || index >= Nodes.Count) return null;
        if (pathCache == null) pathCache = new string[Nodes.Count];
        if (pathCache[index] != null) return pathCache[index];
        List<int> chain = new List<int>();
        int current = index;
        int guard = 0;
        while (current > 0 && pathCache[current] == null && guard++ < 4096)
        {
            chain.Add(current);
            current = Nodes[current].Parent;
        }
        string basePath = current <= 0 ? Root.TrimEnd('\\') : pathCache[current];
        if (current == 0) pathCache[0] = Root;
        for (int i = chain.Count - 1; i >= 0; i--)
        {
            basePath = basePath.TrimEnd('\\') + "\\" + Nodes[chain[i]].Name;
            pathCache[chain[i]] = basePath;
        }
        return index == 0 ? Root : pathCache[index];
    }

    public int[] GetChildren(int index)
    {
        if (index < 0 || index >= Nodes.Count || Nodes[index].Children == null) return new int[0];
        List<int> children = new List<int>(Nodes[index].Children);
        children.Sort(delegate (int a, int b)
        {
            int c = Nodes[b].Alloc.CompareTo(Nodes[a].Alloc);
            return c != 0 ? c : String.Compare(Nodes[a].Name, Nodes[b].Name, StringComparison.OrdinalIgnoreCase);
        });
        return children.ToArray();
    }

    public int FindDirectory(string path)
    {
        if (String.IsNullOrEmpty(path) || Nodes.Count == 0) return -1;
        string full = path.Replace('/', '\\').TrimEnd('\\');
        string root = Root.TrimEnd('\\');
        if (full.Equals(root, StringComparison.OrdinalIgnoreCase)) return 0;
        if (!full.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase)) return -1;
        string[] parts = full.Substring(root.Length + 1).Split('\\');
        int node = 0;
        foreach (string part in parts)
        {
            if (part.Length == 0) continue;
            List<int> children = Nodes[node].Children;
            int next = -1;
            if (children != null)
            {
                foreach (int child in children)
                {
                    if (String.Equals(Nodes[child].Name, part, StringComparison.OrdinalIgnoreCase)) { next = child; break; }
                }
            }
            if (next < 0) return -1;
            node = next;
        }
        return node;
    }
}

public sealed class DiskAnalyzer
{
    public const int TopFileCount = 1000;
    public const long LargeFileThreshold = 16L * 1024 * 1024;
    public long MinDenseFiles = 5000;
    public long MaxDenseAverage = 128L * 1024;

    public volatile string Phase = "准备";
    public volatile string CurrentPath = "";
    public long FilesScanned;
    public long DirsScanned;
    public long BytesRead;
    public long TotalBytesToRead;

    private CancellationToken token;
    private readonly object sync = new object();
    private CancellationTokenSource background;
    public volatile bool Completed;
    public DiskAnalysisResult Result;
    public Exception Error;
    public DateTime StartedUtc;

    // Runs Analyze on a background thread; the caller polls Completed/Result/Error.
    public void Start(string root, bool preferMft)
    {
        if (background != null && !Completed) throw new InvalidOperationException("分析已在进行中");
        background = new CancellationTokenSource();
        Completed = false;
        Result = null;
        Error = null;
        StartedUtc = DateTime.UtcNow;
        CancellationToken local = background.Token;
        Thread thread = new Thread(delegate ()
        {
            try { Result = Analyze(root, preferMft, local); }
            catch (Exception ex) { Error = ex; }
            finally { Completed = true; }
        });
        thread.IsBackground = true;
        thread.Priority = ThreadPriority.BelowNormal;
        thread.Start();
    }

    public void Cancel()
    {
        if (background != null) background.Cancel();
    }

    // Accumulator shared by both engines.
    private List<DiskDirNode> nodes;
    private List<DiskFileEntry> heap;
    private List<DiskFileEntry> large;
    private Dictionary<string, DiskExtStat> extensions;
    private long errors;
    private long clusterSize = 4096;
    private System.Diagnostics.Stopwatch phaseClock = new System.Diagnostics.Stopwatch();
    private StringBuilder timings = new StringBuilder();

    private void MarkPhase(string next)
    {
        if (phaseClock.IsRunning)
        {
            if (timings.Length > 0) timings.Append("；");
            timings.Append(Phase).Append(' ').Append((phaseClock.ElapsedMilliseconds / 1000.0).ToString("0.0", CultureInfo.InvariantCulture)).Append('s');
        }
        Phase = next;
        phaseClock.Restart();
    }

    public DiskAnalysisResult Analyze(string root, bool preferMft, CancellationToken cancellation)
    {
        token = cancellation;
        DateTime started = DateTime.UtcNow;
        string full = System.IO.Path.GetFullPath(root);
        if (!full.EndsWith("\\")) full += "\\";
        if (!Directory.Exists(full)) throw new DirectoryNotFoundException(full);
        string volumeRoot = System.IO.Path.GetPathRoot(full);
        bool isVolumeRoot = volumeRoot.Length == 3 && full.Equals(volumeRoot, StringComparison.OrdinalIgnoreCase);
        DiskAnalysisResult result = null;
        string reason = "";
        clusterSize = QueryClusterSize(volumeRoot);
        if (preferMft && isVolumeRoot)
        {
            try
            {
                using (VolumeSource source = WindowsVolumeSource.Open(volumeRoot.Substring(0, 2)))
                {
                    result = AnalyzeMft(source, volumeRoot);
                }
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                reason = ex.Message;
                result = null;
            }
        }
        else if (preferMft) reason = "只有整个分区根目录支持 MFT 直读";
        if (result == null)
        {
            result = AnalyzeEnumeration(full);
            result.FallbackReason = reason;
        }
        result.Seconds = (DateTime.UtcNow - started).TotalSeconds;
        return result;
    }

    // Used by tests to parse an NTFS image file. The image is only opened for reading.
    public DiskAnalysisResult AnalyzeNtfsImage(string imagePath, string displayRoot, CancellationToken cancellation)
    {
        token = cancellation;
        DateTime started = DateTime.UtcNow;
        using (VolumeSource source = new StreamVolumeSource(new FileStream(imagePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)))
        {
            DiskAnalysisResult result = AnalyzeMft(source, displayRoot);
            result.Seconds = (DateTime.UtcNow - started).TotalSeconds;
            return result;
        }
    }

    private void Reset()
    {
        nodes = new List<DiskDirNode>();
        heap = new List<DiskFileEntry>();
        large = new List<DiskFileEntry>();
        extensions = new Dictionary<string, DiskExtStat>(StringComparer.OrdinalIgnoreCase);
        errors = 0;
        timings.Length = 0;
        phaseClock.Reset();
        FilesScanned = 0;
        DirsScanned = 0;
        BytesRead = 0;
        TotalBytesToRead = 0;
    }

    private static long QueryClusterSize(string volumeRoot)
    {
        try
        {
            uint sectorsPerCluster, bytesPerSector, freeClusters, totalClusters;
            if (NativeMethods.GetDiskFreeSpaceW(volumeRoot, out sectorsPerCluster, out bytesPerSector, out freeClusters, out totalClusters))
            {
                long size = (long)sectorsPerCluster * bytesPerSector;
                if (size > 0) return size;
            }
        }
        catch (Exception) { }
        return 4096;
    }

    // ---- shared accumulation helpers ----

    private void AddFile(int parent, string name, long alloc, long logical, DateTime lastWriteUtc,
        List<DiskFileEntry> localHeap, List<DiskFileEntry> localLarge, Dictionary<string, DiskExtStat> localExt)
    {
        DiskFileEntry entry = null;
        if (localHeap.Count < TopFileCount || alloc > localHeap[0].Alloc || logical >= LargeFileThreshold)
        {
            entry = new DiskFileEntry();
            entry.Parent = parent;
            entry.Name = name;
            entry.Alloc = alloc;
            entry.Logical = logical;
            entry.LastWriteUtc = lastWriteUtc;
            if (localHeap.Count < TopFileCount) HeapPush(localHeap, entry);
            else if (alloc > localHeap[0].Alloc) HeapReplaceTop(localHeap, entry);
            if (logical >= LargeFileThreshold || alloc >= LargeFileThreshold) localLarge.Add(entry);
        }
        int dot = name.LastIndexOf('.');
        string ext = dot <= 0 || dot == name.Length - 1 || name.Length - dot > 16 ? "" : name.Substring(dot + 1);
        DiskExtStat stat;
        if (!localExt.TryGetValue(ext, out stat))
        {
            stat = new DiskExtStat();
            stat.Extension = ext.ToLowerInvariant();
            localExt[ext] = stat;
        }
        stat.Count++;
        stat.Alloc += alloc;
        stat.Logical += logical;
    }

    private static void HeapPush(List<DiskFileEntry> h, DiskFileEntry e)
    {
        h.Add(e);
        int i = h.Count - 1;
        while (i > 0)
        {
            int p = (i - 1) / 2;
            if (h[p].Alloc <= h[i].Alloc) break;
            DiskFileEntry t = h[p]; h[p] = h[i]; h[i] = t;
            i = p;
        }
    }

    private static void HeapReplaceTop(List<DiskFileEntry> h, DiskFileEntry e)
    {
        h[0] = e;
        int i = 0;
        int n = h.Count;
        while (true)
        {
            int l = 2 * i + 1, r = l + 1, m = i;
            if (l < n && h[l].Alloc < h[m].Alloc) m = l;
            if (r < n && h[r].Alloc < h[m].Alloc) m = r;
            if (m == i) break;
            DiskFileEntry t = h[m]; h[m] = h[i]; h[i] = t;
            i = m;
        }
    }

    private static void MergeExt(Dictionary<string, DiskExtStat> target, Dictionary<string, DiskExtStat> source)
    {
        foreach (KeyValuePair<string, DiskExtStat> pair in source)
        {
            DiskExtStat stat;
            if (!target.TryGetValue(pair.Key, out stat)) { target[pair.Key] = pair.Value; continue; }
            stat.Count += pair.Value.Count;
            stat.Alloc += pair.Value.Alloc;
            stat.Logical += pair.Value.Logical;
        }
    }

    private static void MarkSpecialFile(DiskDirNode parent, string name)
    {
        if (name.Equals("CACHEDIR.TAG", StringComparison.OrdinalIgnoreCase)) parent.CacheTag = true;
        else if (name.Equals("pyvenv.cfg", StringComparison.OrdinalIgnoreCase)) parent.VenvMarker = true;
    }

    // ---- NTFS MFT engine ----

    // Attributes gathered from one MFT record. Records with an attribute list can spread
    // names and data over extension records; those parts are merged into the base record.
    private sealed class RecordInfo
    {
        public string Name;
        public int NameRank = -1;
        public long ParentRef = -1;
        public bool IsDirectory;
        public long Alloc;
        public long Logical;
        public bool HasData;
        public DateTime LastWriteUtc = DateTime.MinValue;

        public void Merge(RecordInfo other)
        {
            if (other.NameRank > NameRank) { Name = other.Name; NameRank = other.NameRank; ParentRef = other.ParentRef; }
            Alloc += other.Alloc;
            if (other.HasData) { Logical = other.Logical; HasData = true; }
            if (other.LastWriteUtc > LastWriteUtc) LastWriteUtc = other.LastWriteUtc;
        }
    }

    private DiskAnalysisResult AnalyzeMft(VolumeSource source, string rootDisplay)
    {
        Reset();
        MarkPhase("读取 NTFS 引导扇区");
        byte[] boot = new byte[512];
        source.ReadExact(0, boot, 512);
        if (Encoding.ASCII.GetString(boot, 3, 8) != "NTFS    ") throw new InvalidDataException("不是 NTFS 分区");
        int bytesPerSector = BitConverter.ToUInt16(boot, 0x0B);
        int sectorsPerCluster = boot[0x0D];
        if (sectorsPerCluster > 128) sectorsPerCluster = 1 << (256 - sectorsPerCluster);
        long cluster = (long)bytesPerSector * sectorsPerCluster;
        if (bytesPerSector < 512 || cluster <= 0) throw new InvalidDataException("NTFS 引导扇区无效");
        clusterSize = cluster;
        long mftLcn = BitConverter.ToInt64(boot, 0x30);
        sbyte clustersPerRecord = unchecked((sbyte)boot[0x40]);
        int recordSize = clustersPerRecord > 0 ? (int)(clustersPerRecord * cluster) : 1 << -clustersPerRecord;
        if (recordSize < 512 || recordSize > 65536) throw new InvalidDataException("MFT 记录大小无效");

        byte[] first = new byte[Math.Max(recordSize, (int)Math.Min(cluster, 65536))];
        int firstRead = (int)Math.Max(recordSize, cluster);
        if (firstRead > first.Length) first = new byte[firstRead];
        source.ReadExact(mftLcn * cluster, first, firstRead);
        if (!ApplyFixup(first, 0, recordSize)) throw new InvalidDataException("$MFT 记录校验失败");
        List<long[]> runs = null;
        long mftSize = 0;
        byte[] attributeList = null;
        List<long[]> attributeListRuns = null;
        long attributeListSize = 0;
        ForEachAttribute(first, 0, recordSize, delegate (int a, int type, int len)
        {
            if (type == 0x80 && first[a + 8] != 0 && first[a + 9] == 0 && BitConverter.ToInt64(first, a + 0x10) == 0)
            {
                runs = DecodeRuns(first, a + BitConverter.ToUInt16(first, a + 0x20), a + len);
                mftSize = BitConverter.ToInt64(first, a + 0x38);
            }
            else if (type == 0x20 && first[a + 8] == 0)
            {
                int valueLength = BitConverter.ToInt32(first, a + 0x10);
                int valueOffset = BitConverter.ToUInt16(first, a + 0x14);
                if (valueLength > 0 && a + valueOffset + valueLength <= a + len)
                {
                    attributeList = new byte[valueLength];
                    Buffer.BlockCopy(first, a + valueOffset, attributeList, 0, valueLength);
                }
            }
            else if (type == 0x20)
            {
                attributeListRuns = DecodeRuns(first, a + BitConverter.ToUInt16(first, a + 0x20), a + len);
                attributeListSize = BitConverter.ToInt64(first, a + 0x30);
            }
        });
        if (attributeListRuns != null && attributeListSize > 0 && attributeListSize < 16 * 1024 * 1024)
        {
            // Non-resident attribute list: read its clusters and trim to the data size.
            long total = 0;
            foreach (long[] run in attributeListRuns) total += run[1] * cluster;
            byte[] raw = new byte[total];
            long position = 0;
            foreach (long[] run in attributeListRuns)
            {
                int length = (int)(run[1] * cluster);
                if (run[2] == 0)
                {
                    byte[] part = new byte[length];
                    source.ReadExact(run[0] * cluster, part, length);
                    Buffer.BlockCopy(part, 0, raw, (int)position, length);
                }
                position += length;
            }
            attributeList = new byte[Math.Min(attributeListSize, total)];
            Buffer.BlockCopy(raw, 0, attributeList, 0, attributeList.Length);
        }
        if (runs == null || mftSize <= 0) throw new InvalidDataException("无法定位 $MFT 数据");
        if (attributeList != null) runs = AppendMftExtents(source, attributeList, runs, cluster, recordSize);
        long recordCount = mftSize / recordSize;
        if (recordCount > int.MaxValue) throw new InvalidDataException("MFT 过大");
        TotalBytesToRead = mftSize;

        Dictionary<long, int> dirIndex = new Dictionary<long, int>();
        List<long> dirParentRefs = new List<long>();
        List<KeyValuePair<long, DiskFileEntry>> pendingEmit = new List<KeyValuePair<long, DiskFileEntry>>();
        Dictionary<long, RecordInfo> partial = new Dictionary<long, RecordInfo>();
        Dictionary<long, RecordInfo> extensionParts = new Dictionary<long, RecordInfo>();

        // Files reference their parent directory by record number; the directory may appear
        // later in the table, so per-directory totals are kept by record number first.
        Dictionary<long, long[]> direct = new Dictionary<long, long[]>();
        Dictionary<long, byte> markers = new Dictionary<long, byte>();

        DiskDirNode rootNode = new DiskDirNode();
        rootNode.Index = 0;
        rootNode.Name = rootDisplay;
        rootNode.Children = new List<int>();
        nodes.Add(rootNode);
        dirIndex[5] = 0;
        dirParentRefs.Add(5);

        MarkPhase("读取 MFT");
        int chunkBytes = (int)Math.Max(cluster, (4 * 1024 * 1024 / cluster) * cluster);
        chunkBytes -= chunkBytes % recordSize;
        if (chunkBytes <= 0) chunkBytes = recordSize;
        byte[] buffer = new byte[chunkBytes];
        long vcnBytes = 0;
        long processedRecords = 0;
        foreach (long[] run in runs)
        {
            long runBytes = run[1] * cluster;
            long runStartByte = run[0] * cluster;
            long offsetInRun = 0;
            while (offsetInRun < runBytes && processedRecords < recordCount)
            {
                token.ThrowIfCancellationRequested();
                int want = (int)Math.Min(chunkBytes, runBytes - offsetInRun);
                long remainingRecordBytes = (recordCount - processedRecords) * recordSize;
                if (want > remainingRecordBytes)
                {
                    want = (int)remainingRecordBytes;
                    // Keep volume reads aligned to the sector size.
                    int aligned = (int)(((want + bytesPerSector - 1) / bytesPerSector) * bytesPerSector);
                    want = Math.Min(aligned, (int)Math.Min(chunkBytes, runBytes - offsetInRun));
                }
                if (run[2] == 0) source.ReadExact(runStartByte + offsetInRun, buffer, want);
                else Array.Clear(buffer, 0, want);
                BytesRead += want;
                long firstRecord = (vcnBytes + offsetInRun) / recordSize;
                int count = want / recordSize;
                for (int i = 0; i < count && firstRecord + i < recordCount; i++)
                {
                    long recordNumber = firstRecord + i;
                    ParseRecord(buffer, i * recordSize, recordSize, recordNumber, dirIndex, dirParentRefs,
                        markers, partial, extensionParts, pendingEmit);
                    processedRecords++;
                }
                offsetInRun += want;
            }
            vcnBytes += runBytes;
        }

        MarkPhase("整理目录结构");
        // Complete records whose attributes continue in extension records.
        foreach (KeyValuePair<long, RecordInfo> pair in partial)
        {
            RecordInfo extra;
            if (extensionParts.TryGetValue(pair.Key, out extra)) pair.Value.Merge(extra);
            EmitRecord(pair.Key, pair.Value, dirIndex, dirParentRefs, markers, pendingEmit);
        }
        foreach (KeyValuePair<long, DiskFileEntry> pair in pendingEmit)
        {
            DiskFileEntry e = pair.Value;
            long[] agg;
            if (!direct.TryGetValue(pair.Key, out agg)) { agg = new long[3]; direct[pair.Key] = agg; }
            agg[0]++;
            agg[1] += e.Alloc;
            agg[2] += e.Logical;
            AddFileToCollections(pair.Key, e);
        }

        // Link directories into a tree. Unknown or cyclic parents fall back to the root.
        for (int i = 1; i < nodes.Count; i++)
        {
            long parentRecord = dirParentRefs[i];
            int parent;
            if (!dirIndex.TryGetValue(parentRecord, out parent) || parent == i) parent = 0;
            nodes[i].Parent = parent;
        }
        BreakCycles();
        for (int i = 1; i < nodes.Count; i++)
        {
            DiskDirNode parentNode = nodes[nodes[i].Parent];
            if (parentNode.Children == null) parentNode.Children = new List<int>();
            parentNode.Children.Add(i);
        }
        foreach (KeyValuePair<long, long[]> pair in direct)
        {
            int index;
            if (!dirIndex.TryGetValue(pair.Key, out index)) index = 0;
            nodes[index].DirectFiles += pair.Value[0];
            nodes[index].DirectAlloc += pair.Value[1];
            nodes[index].DirectLogical += pair.Value[2];
        }
        foreach (KeyValuePair<long, byte> pair in markers)
        {
            int index;
            if (!dirIndex.TryGetValue(pair.Key, out index)) continue;
            if ((pair.Value & 1) != 0) nodes[index].CacheTag = true;
            if ((pair.Value & 2) != 0) nodes[index].VenvMarker = true;
        }
        // Parent records of retained file entries become node indexes.
        foreach (DiskFileEntry e in large) ResolveParent(e, dirIndex);
        foreach (DiskFileEntry e in heap) ResolveParent(e, dirIndex);
        DiskAnalysisResult result = Finish(rootDisplay, "NTFS MFT 直读");
        return result;
    }

    // A fragmented $MFT keeps later $DATA extents in extension records listed by its
    // $ATTRIBUTE_LIST. Those records sit in the first extent, which is already mapped.
    private static List<long[]> AppendMftExtents(VolumeSource source, byte[] list, List<long[]> firstRuns, long cluster, int recordSize)
    {
        SortedDictionary<long, List<long[]>> extents = new SortedDictionary<long, List<long[]>>();
        extents[0] = firstRuns;
        HashSet<long> visited = new HashSet<long>();
        int p = 0;
        while (p + 0x1A <= list.Length)
        {
            int type = BitConverter.ToInt32(list, p);
            int entryLength = BitConverter.ToUInt16(list, p + 4);
            if (entryLength < 0x1A || p + entryLength > list.Length) break;
            int nameLength = list[p + 6];
            long startVcn = BitConverter.ToInt64(list, p + 8);
            long record = BitConverter.ToInt64(list, p + 0x10) & 0x0000FFFFFFFFFFFFL;
            p += entryLength;
            if (type != 0x80 || nameLength != 0 || startVcn == 0 || record == 0 || !visited.Add(record)) continue;
            long byteOffset = record * recordSize;
            long lcnByte = MapVcn(firstRuns, byteOffset, cluster);
            if (lcnByte < 0) throw new InvalidDataException("$MFT 扩展记录不在首个区段内");
            long alignedStart = lcnByte - (lcnByte % cluster);
            long needed = (lcnByte - alignedStart) + recordSize;
            byte[] data = new byte[(int)((needed + cluster - 1) / cluster * cluster)];
            source.ReadExact(alignedStart, data, data.Length);
            int offset = (int)(lcnByte - alignedStart);
            byte[] rec = new byte[recordSize];
            Buffer.BlockCopy(data, offset, rec, 0, recordSize);
            if (!ApplyFixup(rec, 0, recordSize)) throw new InvalidDataException("$MFT 扩展记录校验失败");
            ForEachAttribute(rec, 0, recordSize, delegate (int a, int t, int len)
            {
                if (t == 0x80 && rec[a + 8] != 0 && rec[a + 9] == 0)
                {
                    long vcn = BitConverter.ToInt64(rec, a + 0x10);
                    if (vcn > 0 && !extents.ContainsKey(vcn)) extents[vcn] = DecodeRuns(rec, a + BitConverter.ToUInt16(rec, a + 0x20), a + len);
                }
            });
        }
        List<long[]> all = new List<long[]>();
        long expectedVcn = 0;
        foreach (KeyValuePair<long, List<long[]>> pair in extents)
        {
            if (pair.Key != expectedVcn) throw new InvalidDataException("$MFT 区段不连续");
            foreach (long[] run in pair.Value) { all.Add(run); expectedVcn += run[1]; }
        }
        return all;
    }

    private static long MapVcn(List<long[]> runs, long byteOffset, long cluster)
    {
        long vcn = byteOffset / cluster;
        long start = 0;
        foreach (long[] run in runs)
        {
            if (vcn < start + run[1]) return run[2] != 0 ? -1 : (run[0] + (vcn - start)) * cluster + byteOffset % cluster;
            start += run[1];
        }
        return -1;
    }

    private void ResolveParent(DiskFileEntry e, Dictionary<long, int> dirIndex)
    {
        if (e.Parent >= 0 && e.Path != null) return;
        long parentRecord = e.Parent >= 0 ? e.Parent : -1;
        int idx;
        if (parentRecord < 0 || !dirIndex.TryGetValue(parentRecord, out idx)) idx = 0;
        e.Parent = idx;
        e.Path = "";
    }

    private void AddFileToCollections(long parentRecord, DiskFileEntry e)
    {
        // Parent holds the record number until the tree is linked (see ResolveParent).
        AddFile(parentRecord > int.MaxValue ? -1 : (int)parentRecord, e.Name, e.Alloc, e.Logical, e.LastWriteUtc, heap, large, extensions);
    }

    private delegate void AttributeVisitor(int attributeOffset, int type, int length);

    private static void ForEachAttribute(byte[] data, int offset, int recordSize, AttributeVisitor visit)
    {
        int a = offset + BitConverter.ToUInt16(data, offset + 0x14);
        int end = offset + Math.Min(recordSize, (int)BitConverter.ToUInt32(data, offset + 0x18));
        if (end <= offset || end > offset + recordSize) end = offset + recordSize;
        while (a + 8 <= end)
        {
            int type = BitConverter.ToInt32(data, a);
            if (type == -1) break;
            int len = BitConverter.ToInt32(data, a + 4);
            if (len < 0x18 || a + len > end) break;
            visit(a, type, len);
            a += len;
        }
    }

    private static bool ApplyFixup(byte[] data, int offset, int recordSize)
    {
        if (data[offset] != (byte)'F' || data[offset + 1] != (byte)'I' || data[offset + 2] != (byte)'L' || data[offset + 3] != (byte)'E') return false;
        int usaOffset = BitConverter.ToUInt16(data, offset + 4);
        int usaCount = BitConverter.ToUInt16(data, offset + 6);
        if (usaCount < 2 || usaOffset + usaCount * 2 > recordSize || (usaCount - 1) * 512 > recordSize) return false;
        byte u0 = data[offset + usaOffset], u1 = data[offset + usaOffset + 1];
        for (int i = 1; i < usaCount; i++)
        {
            int pos = offset + i * 512 - 2;
            if (data[pos] != u0 || data[pos + 1] != u1) return false;
            data[pos] = data[offset + usaOffset + i * 2];
            data[pos + 1] = data[offset + usaOffset + i * 2 + 1];
        }
        return true;
    }

    private static List<long[]> DecodeRuns(byte[] data, int start, int end)
    {
        // Each element: { lcn, clusterCount, sparse(0/1) }.
        List<long[]> runs = new List<long[]>();
        int p = start;
        long lcn = 0;
        while (p < end)
        {
            byte header = data[p++];
            if (header == 0) break;
            int lenBytes = header & 0x0F;
            int offBytes = header >> 4;
            if (lenBytes == 0 || lenBytes > 8 || offBytes > 8 || p + lenBytes + offBytes > end) break;
            long length = 0;
            for (int i = 0; i < lenBytes; i++) length |= (long)data[p + i] << (8 * i);
            p += lenBytes;
            if (offBytes == 0)
            {
                runs.Add(new long[] { 0, length, 1 });
                continue;
            }
            long delta = 0;
            for (int i = 0; i < offBytes; i++) delta |= (long)data[p + i] << (8 * i);
            if ((data[p + offBytes - 1] & 0x80) != 0 && offBytes < 8) delta |= -1L << (8 * offBytes);
            p += offBytes;
            lcn += delta;
            runs.Add(new long[] { lcn, length, 0 });
        }
        return runs;
    }

    private void ParseRecord(byte[] data, int offset, int recordSize, long recordNumber,
        Dictionary<long, int> dirIndex, List<long> dirParentRefs, Dictionary<long, byte> markers,
        Dictionary<long, RecordInfo> partial, Dictionary<long, RecordInfo> extensionParts,
        List<KeyValuePair<long, DiskFileEntry>> emit)
    {
        if (!ApplyFixup(data, offset, recordSize)) return;
        // $BadClus:$Bad is a sparse stream as large as the volume; it holds no real data.
        if (recordNumber == 8) return;
        int flags = BitConverter.ToUInt16(data, offset + 0x16);
        if ((flags & 1) == 0) return;
        bool isDirectory = (flags & 2) != 0;
        long baseRef = BitConverter.ToInt64(data, offset + 0x20) & 0x0000FFFFFFFFFFFFL;

        string bestName = null;
        int bestNamespace = -1;
        long parentRef = -1;
        long alloc = 0, logical = 0;
        bool hasData = false;
        bool hasList = false;
        DateTime lastWrite = DateTime.MinValue;
        int a = offset + BitConverter.ToUInt16(data, offset + 0x14);
        int end = offset + recordSize;
        int used = (int)BitConverter.ToUInt32(data, offset + 0x18);
        if (used > 0 && used <= recordSize) end = offset + used;
        while (a + 8 <= end)
        {
            int type = BitConverter.ToInt32(data, a);
            if (type == -1) break;
            int len = BitConverter.ToInt32(data, a + 4);
            if (len < 0x18 || a + len > end) break;
            bool nonResident = data[a + 8] != 0;
            int nameLength = data[a + 9];
            if (type == 0x10 && !nonResident)
            {
                int v = a + BitConverter.ToUInt16(data, a + 0x14);
                if (v + 0x10 <= a + len)
                {
                    long ft = BitConverter.ToInt64(data, v + 0x08);
                    try { lastWrite = DateTime.FromFileTimeUtc(ft); } catch (ArgumentOutOfRangeException) { }
                }
            }
            else if (type == 0x20)
            {
                hasList = true;
            }
            else if (type == 0x30 && !nonResident)
            {
                int v = a + BitConverter.ToUInt16(data, a + 0x14);
                if (v + 0x42 <= a + len)
                {
                    int nlen = data[v + 0x40];
                    int ns = data[v + 0x41];
                    if (v + 0x42 + nlen * 2 <= a + len && ns != 2)
                    {
                        // Prefer Win32 names (1, 3) over POSIX (0); DOS-only 8.3 aliases are ignored.
                        int rank = ns == 0 ? 1 : 2;
                        if (rank > bestNamespace)
                        {
                            bestNamespace = rank;
                            bestName = Encoding.Unicode.GetString(data, v + 0x42, nlen * 2);
                            parentRef = BitConverter.ToInt64(data, v) & 0x0000FFFFFFFFFFFFL;
                        }
                    }
                }
            }
            else if (type == 0x80)
            {
                if (nonResident)
                {
                    long startVcn = BitConverter.ToInt64(data, a + 0x10);
                    if (startVcn == 0)
                    {
                        int attrFlags = BitConverter.ToUInt16(data, a + 0x0C);
                        long allocated = BitConverter.ToInt64(data, a + 0x28);
                        if ((attrFlags & 0x8001) != 0 && len >= 0x48) allocated = BitConverter.ToInt64(data, a + 0x40);
                        alloc += allocated;
                        if (nameLength == 0) { logical = BitConverter.ToInt64(data, a + 0x30); hasData = true; }
                    }
                }
                else
                {
                    if (nameLength == 0) { logical = BitConverter.ToUInt32(data, a + 0x10); hasData = true; }
                }
            }
            a += len;
        }

        RecordInfo info = new RecordInfo();
        info.Name = bestName;
        info.NameRank = bestNamespace;
        info.ParentRef = parentRef;
        info.IsDirectory = isDirectory;
        info.Alloc = alloc;
        info.Logical = logical;
        info.HasData = hasData;
        info.LastWriteUtc = lastWrite;
        if (baseRef != 0)
        {
            RecordInfo existing;
            if (extensionParts.TryGetValue(baseRef, out existing)) existing.Merge(info);
            else extensionParts[baseRef] = info;
            return;
        }
        if (hasList) { partial[recordNumber] = info; return; }
        EmitRecord(recordNumber, info, dirIndex, dirParentRefs, markers, emit);
    }

    private void EmitRecord(long recordNumber, RecordInfo info, Dictionary<long, int> dirIndex, List<long> dirParentRefs,
        Dictionary<long, byte> markers, List<KeyValuePair<long, DiskFileEntry>> emit)
    {
        if (info.Name == null) return;
        if (info.IsDirectory)
        {
            if (recordNumber == 5) return;
            DiskDirNode node = new DiskDirNode();
            node.Index = nodes.Count;
            node.Name = info.Name;
            nodes.Add(node);
            dirIndex[recordNumber] = node.Index;
            dirParentRefs.Add(info.ParentRef);
            DirsScanned++;
            return;
        }
        if (info.Name.Equals("CACHEDIR.TAG", StringComparison.OrdinalIgnoreCase) || info.Name.Equals("pyvenv.cfg", StringComparison.OrdinalIgnoreCase))
        {
            byte bit = (byte)(info.Name.Length == 12 ? 1 : 2);
            byte existing;
            markers.TryGetValue(info.ParentRef, out existing);
            markers[info.ParentRef] = (byte)(existing | bit);
        }
        DiskFileEntry entry = new DiskFileEntry();
        entry.Name = info.Name;
        entry.Alloc = info.Alloc;
        entry.Logical = info.Logical;
        entry.LastWriteUtc = info.LastWriteUtc;
        emit.Add(new KeyValuePair<long, DiskFileEntry>(info.ParentRef, entry));
        FilesScanned++;
        if ((emit.Count & 0xFFFF) == 0) CurrentPath = info.Name;
    }

    private void BreakCycles()
    {
        // Any node whose parent chain does not reach the root within the node count is re-parented.
        int[] state = new int[nodes.Count];
        state[0] = 2;
        for (int i = 1; i < nodes.Count; i++)
        {
            if (state[i] == 2) continue;
            List<int> path = new List<int>();
            int current = i;
            while (state[current] == 0)
            {
                state[current] = 1;
                path.Add(current);
                current = nodes[current].Parent;
            }
            if (state[current] == 1)
            {
                // Cycle detected; attach the node where the loop closed to the root.
                nodes[current].Parent = 0;
            }
            foreach (int n in path) state[n] = 2;
        }
    }

    // ---- Enumeration engine ----

    private DiskAnalysisResult AnalyzeEnumeration(string root)
    {
        Reset();
        MarkPhase("多线程枚举目录");
        DiskDirNode rootNode = new DiskDirNode();
        rootNode.Index = 0;
        rootNode.Name = root;
        rootNode.Children = new List<int>();
        nodes.Add(rootNode);
        System.Collections.Concurrent.ConcurrentStack<KeyValuePair<int, string>> work = new System.Collections.Concurrent.ConcurrentStack<KeyValuePair<int, string>>();
        work.Push(new KeyValuePair<int, string>(0, root.TrimEnd('\\')));
        long pendingCount = 1;
        int threadCount = Math.Max(4, Math.Min(16, Environment.ProcessorCount * 2));
        Thread[] threads = new Thread[threadCount];
        List<DiskFileEntry>[] heaps = new List<DiskFileEntry>[threadCount];
        List<DiskFileEntry>[] larges = new List<DiskFileEntry>[threadCount];
        Dictionary<string, DiskExtStat>[] exts = new Dictionary<string, DiskExtStat>[threadCount];
        Exception failure = null;
        for (int t = 0; t < threadCount; t++)
        {
            int slot = t;
            heaps[slot] = new List<DiskFileEntry>();
            larges[slot] = new List<DiskFileEntry>();
            exts[slot] = new Dictionary<string, DiskExtStat>(StringComparer.OrdinalIgnoreCase);
            threads[slot] = new Thread(delegate ()
            {
                try
                {
                    while (Interlocked.Read(ref pendingCount) > 0)
                    {
                        if (token.IsCancellationRequested) return;
                        KeyValuePair<int, string> item;
                        if (!work.TryPop(out item)) { Thread.Sleep(1); continue; }
                        try { EnumerateDirectory(item.Key, item.Value, work, ref pendingCount, heaps[slot], larges[slot], exts[slot]); }
                        catch (Exception) { Interlocked.Increment(ref errors); }
                        finally { Interlocked.Decrement(ref pendingCount); }
                    }
                }
                catch (Exception ex) { failure = ex; }
            });
            threads[slot].IsBackground = true;
            threads[slot].Start();
        }
        foreach (Thread thread in threads) thread.Join();
        token.ThrowIfCancellationRequested();
        if (failure != null) throw failure;
        for (int t = 0; t < threadCount; t++)
        {
            foreach (DiskFileEntry e in heaps[t])
            {
                if (heap.Count < TopFileCount) HeapPush(heap, e);
                else if (e.Alloc > heap[0].Alloc) HeapReplaceTop(heap, e);
            }
            large.AddRange(larges[t]);
            MergeExt(extensions, exts[t]);
        }
        foreach (DiskFileEntry e in heap) e.Path = "";
        foreach (DiskFileEntry e in large) e.Path = "";
        return Finish(root, "多线程目录枚举");
    }

    private void EnumerateDirectory(int nodeIndex, string path, System.Collections.Concurrent.ConcurrentStack<KeyValuePair<int, string>> work,
        ref long pendingCount, List<DiskFileEntry> localHeap, List<DiskFileEntry> localLarge, Dictionary<string, DiskExtStat> localExt)
    {
        DiskDirNode node;
        lock (sync) { node = nodes[nodeIndex]; }
        string search = (path.StartsWith("\\\\") ? path : "\\\\?\\" + path) + "\\*";
        NativeMethods.WIN32_FIND_DATAW data;
        using (SafeFindHandle handle = NativeMethods.FindFirstFileExW(search, 1, out data, 0, IntPtr.Zero, 2))
        {
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                if (error != 2 && error != 18) Interlocked.Increment(ref errors);
                return;
            }
            long files = 0;
            do
            {
                string name = data.cFileName;
                if (name == "." || name == "..") continue;
                FileAttributes attributes = (FileAttributes)data.dwFileAttributes;
                if ((attributes & FileAttributes.Directory) != 0)
                {
                    if ((attributes & FileAttributes.ReparsePoint) != 0) continue;
                    DiskDirNode child = new DiskDirNode();
                    child.Name = name;
                    child.Parent = nodeIndex;
                    lock (sync)
                    {
                        child.Index = nodes.Count;
                        nodes.Add(child);
                    }
                    if (node.Children == null) node.Children = new List<int>();
                    node.Children.Add(child.Index);
                    Interlocked.Increment(ref pendingCount);
                    work.Push(new KeyValuePair<int, string>(child.Index, path + "\\" + name));
                    Interlocked.Increment(ref DirsScanned);
                    continue;
                }
                long logical = ((long)data.nFileSizeHigh << 32) | data.nFileSizeLow;
                long alloc;
                // Cloud placeholders and offline files do not occupy local clusters.
                if (((uint)attributes & (0x00400000u | 0x00001000u)) != 0) alloc = 0;
                else alloc = (logical + clusterSize - 1) / clusterSize * clusterSize;
                DateTime lastWrite = DateTime.MinValue;
                try { lastWrite = DateTime.FromFileTimeUtc(((long)data.ftLastWriteTimeHigh << 32) | data.ftLastWriteTimeLow); } catch (ArgumentOutOfRangeException) { }
                node.DirectFiles++;
                node.DirectAlloc += alloc;
                node.DirectLogical += logical;
                MarkSpecialFile(node, name);
                AddFile(nodeIndex, name, alloc, logical, lastWrite, localHeap, localLarge, localExt);
                files++;
            }
            while (NativeMethods.FindNextFileW(handle, out data));
            Interlocked.Add(ref FilesScanned, files);
        }
        CurrentPath = path;
    }

    // ---- post-processing ----

    private DiskAnalysisResult Finish(string root, string mode)
    {
        token.ThrowIfCancellationRequested();
        MarkPhase("汇总与生成建议");
        DiskAnalysisResult result = new DiskAnalysisResult();
        result.Root = root.EndsWith("\\") ? root : root + "\\";
        result.Mode = mode;
        result.Nodes = nodes;
        nodes[0].Name = result.Root;

        // Post-order totals without recursion.
        int count = nodes.Count;
        int[] order = new int[count];
        int orderCount = 0;
        Stack<int> stack = new Stack<int>();
        stack.Push(0);
        bool[] visited = new bool[count];
        while (stack.Count > 0)
        {
            int n = stack.Pop();
            if (visited[n]) continue;
            visited[n] = true;
            order[orderCount++] = n;
            List<int> children = nodes[n].Children;
            if (children != null) foreach (int c in children) if (!visited[c]) stack.Push(c);
        }
        long[] denseChildFiles = new long[count];
        bool[] dense = new bool[count];
        for (int i = orderCount - 1; i >= 0; i--)
        {
            DiskDirNode n = nodes[order[i]];
            n.Alloc += n.DirectAlloc;
            n.Logical += n.DirectLogical;
            n.Files += n.DirectFiles;
            bool qualifies = n.Files >= MinDenseFiles && Math.Max(n.Alloc, n.Logical) / Math.Max(1, n.Files) <= MaxDenseAverage;
            // Report the most specific directory: skip ancestors whose small files mostly sit in reported children.
            if (qualifies && denseChildFiles[n.Index] * 2 < n.Files) dense[n.Index] = true;
            if (n.Parent >= 0 && n.Index != 0)
            {
                DiskDirNode p = nodes[n.Parent];
                p.Alloc += n.Alloc;
                p.Logical += n.Logical;
                p.Files += n.Files;
                p.Dirs += n.Dirs + 1;
                if (qualifies) denseChildFiles[p.Index] += n.Files;
            }
        }
        result.TotalFiles = nodes[0].Files;
        result.TotalDirs = nodes[0].Dirs;
        result.TotalAlloc = nodes[0].Alloc;
        result.TotalLogical = nodes[0].Logical;
        result.Errors = errors;

        for (int i = 0; i < count; i++)
        {
            if (!dense[i] || !visited[i]) continue;
            DiskDenseDir d = new DiskDenseDir();
            d.Node = i;
            d.Files = nodes[i].Files;
            d.Alloc = nodes[i].Alloc;
            d.Logical = nodes[i].Logical;
            d.AverageBytes = Math.Max(nodes[i].Alloc, nodes[i].Logical) / Math.Max(1, nodes[i].Files);
            result.DenseDirs.Add(d);
        }
        result.DenseDirs.Sort(delegate (DiskDenseDir x, DiskDenseDir y) { return y.Files.CompareTo(x.Files); });
        if (result.DenseDirs.Count > 300) result.DenseDirs.RemoveRange(300, result.DenseDirs.Count - 300);
        foreach (DiskDenseDir d in result.DenseDirs) d.Path = result.GetPath(d.Node);

        heap.Sort(delegate (DiskFileEntry x, DiskFileEntry y) { int c = y.Alloc.CompareTo(x.Alloc); return c != 0 ? c : y.Logical.CompareTo(x.Logical); });
        result.TopFiles = heap;
        large.Sort(delegate (DiskFileEntry x, DiskFileEntry y) { return y.Alloc.CompareTo(x.Alloc); });
        result.LargeFiles = large;
        foreach (DiskFileEntry e in heap) e.Path = BuildFilePath(result, e);
        foreach (DiskFileEntry e in large) if (String.IsNullOrEmpty(e.Path)) e.Path = BuildFilePath(result, e);

        List<DiskExtStat> ext = new List<DiskExtStat>(extensions.Values);
        ext.Sort(delegate (DiskExtStat x, DiskExtStat y) { return y.Alloc.CompareTo(x.Alloc); });
        result.Extensions = ext;
        DiskSuggestionRules.Build(result);
        MarkPhase("完成");
        result.Timings = timings.ToString();
        return result;
    }

    private static string BuildFilePath(DiskAnalysisResult result, DiskFileEntry e)
    {
        int parent = e.Parent >= 0 && e.Parent < result.Nodes.Count ? e.Parent : 0;
        string dir = result.GetPath(parent);
        return dir.TrimEnd('\\') + "\\" + e.Name;
    }
}

public static class DiskSuggestionRules
{
    private sealed class KnownPath
    {
        public string Path;
        public string Category;
        public string Risk;
        public string Advice;
        public long MinBytes;
        public bool CanRecycle;
        public string CatalogId;
    }

    private static string Env(Environment.SpecialFolder folder)
    {
        try { return Environment.GetFolderPath(folder); } catch (Exception) { return ""; }
    }

    private static List<KnownPath> KnownPaths(string root)
    {
        string windows = Env(Environment.SpecialFolder.Windows);
        if (String.IsNullOrEmpty(windows)) windows = System.IO.Path.Combine(root, "Windows");
        string local = Env(Environment.SpecialFolder.LocalApplicationData);
        string programData = Env(Environment.SpecialFolder.CommonApplicationData);
        string profile = Env(Environment.SpecialFolder.UserProfile);
        string temp = System.IO.Path.GetTempPath();
        List<KnownPath> list = new List<KnownPath>();
        Action<string, string, string, string, long, bool, string> add = delegate (string p, string c, string r, string a, long min, bool recycle, string catalog)
        {
            if (String.IsNullOrEmpty(p)) return;
            KnownPath k = new KnownPath();
            k.Path = p.TrimEnd('\\'); k.Category = c; k.Risk = r; k.Advice = a; k.MinBytes = min; k.CanRecycle = recycle; k.CatalogId = catalog;
            list.Add(k);
        };
        const long MB = 1024L * 1024;
        add(System.IO.Path.Combine(windows, "SoftwareDistribution\\Download"), "Windows 更新下载缓存", "低", "在“设置 → 系统 → 存储 → 临时文件”中勾选“Windows 更新清理”；不要在更新安装过程中手动删除。", 200 * MB, false, "manage-windows-storage");
        add(System.IO.Path.Combine(windows, "SoftwareDistribution\\DeliveryOptimization"), "传递优化文件", "低", "在“存储 → 临时文件”中勾选“传递优化文件”。", 200 * MB, false, "manage-windows-storage");
        add(System.IO.Path.Combine(root, "Windows.old"), "以前的 Windows 安装", "中", "确认新系统工作正常且不需要回退后，在“存储 → 临时文件”中勾选“以前的 Windows 安装”。", 100 * MB, false, "manage-windows-storage");
        add(System.IO.Path.Combine(root, "$WINDOWS.~BT"), "Windows 升级临时文件", "中", "升级完成后，在“存储 → 临时文件”中勾选“临时 Windows 安装文件”。", 100 * MB, false, "manage-windows-storage");
        add(System.IO.Path.Combine(root, "$WINDOWS.~WS"), "Windows 升级临时文件", "中", "升级完成后，在“存储 → 临时文件”中勾选“临时 Windows 安装文件”。", 100 * MB, false, "manage-windows-storage");
        add(System.IO.Path.Combine(root, "ESD"), "Windows 升级安装镜像", "中", "升级完成后可用“存储 → 临时文件”或磁盘清理删除。", 100 * MB, false, "manage-windows-storage");
        add(System.IO.Path.Combine(windows, "WinSxS"), "组件存储 WinSxS", "中", "不要手动删除。可以管理员运行 DISM /Online /Cleanup-Image /StartComponentCleanup 回收被替换的组件；显示大小包含大量硬链接，实际占用更小。", 5L * 1024 * MB, false, null);
        add(System.IO.Path.Combine(windows, "Installer"), "Windows Installer 缓存", "高", "卸载和修复程序需要这些文件，不要手动删除。请通过“已安装应用”卸载不用的软件。", 1024 * MB, false, "manage-installed-apps");
        add(System.IO.Path.Combine(windows, "System32\\DriverStore\\FileRepository"), "驱动仓库", "高", "不要手动删除。可管理员运行 pnputil /enum-drivers 查看，并用 pnputil /delete-driver 删除确认不用的旧版驱动。", 3L * 1024 * MB, false, null);
        add(System.IO.Path.Combine(windows, "Logs\\CBS"), "组件服务日志", "中", "可在“存储 → 临时文件”中清理；排查更新问题时请保留。", 300 * MB, false, "manage-windows-storage");
        add(System.IO.Path.Combine(windows, "Temp"), "Windows 系统临时文件", "中", "可在“清理项目”中勾选“Windows 系统临时文件”（需管理员）。", 100 * MB, false, "windows-temp");
        add(System.IO.Path.Combine(windows, "Minidump"), "系统崩溃转储", "中", "可在“清理项目”中勾选“系统与内核转储”（需管理员）。", 50 * MB, false, "system-dumps");
        add(System.IO.Path.Combine(windows, "LiveKernelReports"), "内核实时报告", "中", "可在“清理项目”中勾选“系统与内核转储”（需管理员）。", 50 * MB, false, "system-dumps");
        add(System.IO.Path.Combine(windows, "MEMORY.DMP"), "完整内存转储", "中", "不排查蓝屏时可在“存储 → 临时文件”中删除“系统错误内存转储文件”。", 100 * MB, false, "manage-windows-storage");
        add(System.IO.Path.Combine(programData, "Microsoft\\Windows\\WER"), "Windows 错误报告", "低", "可在“存储 → 临时文件”中勾选“Windows 错误报告和反馈诊断”。", 100 * MB, false, "manage-windows-storage");
        add(System.IO.Path.Combine(programData, "Package Cache"), "安装包缓存", "高", "Visual Studio 等程序修复和卸载依赖这些文件，不建议删除；通过“已安装应用”卸载不用的软件。", 1024 * MB, false, "manage-installed-apps");
        add(System.IO.Path.Combine(root, "hiberfil.sys"), "休眠文件", "高", "不使用休眠和快速启动时，可在“清理项目”中选择“关闭休眠并删除 hiberfil.sys”。", 1024 * MB, false, "hibernate-file");
        add(System.IO.Path.Combine(root, "pagefile.sys"), "虚拟内存分页文件", "高", "不要删除。内存充足时可在“系统 → 高级系统设置 → 性能 → 虚拟内存”调小或改到其他盘。", 4L * 1024 * MB, false, null);
        add(System.IO.Path.Combine(root, "swapfile.sys"), "应用交换文件", "高", "由系统管理，不要删除。", 1024 * MB, false, null);
        add(System.IO.Path.Combine(root, "$Recycle.Bin"), "回收站", "中", "确认回收站中的文件都不需要后清空；当前用户的回收站可在“清理项目”中清空。", 100 * MB, false, "recycle-bin");
        if (!String.IsNullOrEmpty(temp)) add(temp, "用户临时文件", "中", "可在“清理项目”中勾选“用户临时文件”，或开启定时清理 7 天前的临时文件。", 200 * MB, false, "user-temp");
        if (!String.IsNullOrEmpty(local))
        {
            add(System.IO.Path.Combine(local, "CrashDumps"), "应用崩溃转储", "中", "可在“清理项目”中勾选“用户崩溃转储”。", 50 * MB, false, "crash-dumps");
            add(System.IO.Path.Combine(local, "Docker\\wsl"), "Docker Desktop 虚拟磁盘", "高", "在 Docker Desktop 中清理镜像和卷（docker system prune），不要直接删除 vhdx。", 1024 * MB, false, null);
            add(System.IO.Path.Combine(local, "Packages\\Microsoft.WindowsTerminal_8wekyb3d8bbwe\\LocalState"), "终端状态", "低", "通常较小；异常增大时检查终端设置导出的缓冲区。", 500 * MB, false, null);
        }
        if (!String.IsNullOrEmpty(profile))
        {
            add(System.IO.Path.Combine(profile, ".cache"), "用户工具缓存目录", "中", "包含模型、浏览器驱动等下载缓存；在“清理项目”中查看“模型与工具缓存”，或逐个确认后删除子目录。", 1024 * MB, false, "tool-model-caches");
            add(System.IO.Path.Combine(profile, ".gradle\\caches"), "Gradle 缓存", "中", "可在“清理项目”中勾选“Gradle 缓存”。", 500 * MB, false, "gradle-cache");
            add(System.IO.Path.Combine(profile, ".m2\\repository"), "Maven 本地仓库", "中", "可在“清理项目”中勾选“Maven 本地仓库”。", 500 * MB, false, "maven-repository");
            add(System.IO.Path.Combine(profile, ".nuget\\packages"), "NuGet 全局包目录", "中", "可运行 dotnet nuget locals global-packages --clear；之后还原依赖时重新下载。", 1024 * MB, false, null);
            add(System.IO.Path.Combine(profile, ".cargo\\registry"), "Cargo 注册表缓存", "中", "可在“清理项目”中勾选 Cargo 相关缓存。", 500 * MB, false, "cargo-download-cache");
            add(System.IO.Path.Combine(profile, "scoop\\cache"), "Scoop 安装包缓存", "低", "运行 scoop cache rm * 清理。", 200 * MB, false, null);
            add(System.IO.Path.Combine(profile, "go\\pkg\\mod"), "Go 模块缓存", "中", "运行 go clean -modcache 清理，之后构建会重新下载。", 1024 * MB, false, null);
            add(System.IO.Path.Combine(profile, ".conda\\pkgs"), "Conda 包缓存", "低", "运行 conda clean --all 清理。", 500 * MB, false, null);
            add(System.IO.Path.Combine(profile, "anaconda3\\pkgs"), "Conda 包缓存", "低", "运行 conda clean --all 清理。", 500 * MB, false, null);
            add(System.IO.Path.Combine(profile, "miniconda3\\pkgs"), "Conda 包缓存", "低", "运行 conda clean --all 清理。", 500 * MB, false, null);
        }
        return list;
    }

    public static bool IsProtectedPath(string path)
    {
        if (String.IsNullOrEmpty(path)) return true;
        string full;
        try { full = System.IO.Path.GetFullPath(path).TrimEnd('\\'); } catch (Exception) { return true; }
        string root = System.IO.Path.GetPathRoot(full).TrimEnd('\\');
        if (full.Length <= root.Length) return true;
        string[] protectedRoots = new string[]
        {
            Env(Environment.SpecialFolder.Windows),
            Env(Environment.SpecialFolder.ProgramFiles),
            Env(Environment.SpecialFolder.ProgramFilesX86),
            System.IO.Path.Combine(Env(Environment.SpecialFolder.CommonApplicationData), "Microsoft"),
            System.IO.Path.Combine(root + "\\", "$Recycle.Bin"),
            System.IO.Path.Combine(root + "\\", "System Volume Information"),
            System.IO.Path.Combine(root + "\\", "Recovery"),
            System.IO.Path.Combine(root + "\\", "Boot"),
        };
        foreach (string p in protectedRoots)
        {
            if (String.IsNullOrEmpty(p)) continue;
            string pr = p.TrimEnd('\\');
            if (full.Equals(pr, StringComparison.OrdinalIgnoreCase) || full.StartsWith(pr + "\\", StringComparison.OrdinalIgnoreCase)) return true;
        }
        string parent = System.IO.Path.GetDirectoryName(full);
        if (parent != null && parent.TrimEnd('\\').Equals(root, StringComparison.OrdinalIgnoreCase))
        {
            string leaf = System.IO.Path.GetFileName(full);
            // Top-level folders such as Users, Program Files and system files are never recycled as a whole.
            if (leaf.StartsWith("$") || leaf.EndsWith(".sys", StringComparison.OrdinalIgnoreCase) ||
                leaf.Equals("Users", StringComparison.OrdinalIgnoreCase) || leaf.Equals("ProgramData", StringComparison.OrdinalIgnoreCase) ||
                leaf.Equals("bootmgr", StringComparison.OrdinalIgnoreCase)) return true;
        }
        string profile = Env(Environment.SpecialFolder.UserProfile);
        if (!String.IsNullOrEmpty(profile))
        {
            string pf = profile.TrimEnd('\\');
            if (full.Equals(pf, StringComparison.OrdinalIgnoreCase)) return true;
            string usersRoot = System.IO.Path.GetDirectoryName(pf);
            if (usersRoot != null && System.IO.Path.GetDirectoryName(full) != null &&
                System.IO.Path.GetDirectoryName(full).TrimEnd('\\').Equals(usersRoot.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) return true;
            foreach (string leaf in new string[] { "AppData", "AppData\\Local", "AppData\\Roaming", "AppData\\LocalLow", "Documents", "Desktop", "Downloads", "Pictures", "Videos", "Music", "OneDrive" })
            {
                if (full.Equals(System.IO.Path.Combine(pf, leaf), StringComparison.OrdinalIgnoreCase)) return true;
            }
        }
        return false;
    }

    private static bool Under(string path, string root)
    {
        if (String.IsNullOrEmpty(root)) return false;
        string r = root.TrimEnd('\\');
        return path.StartsWith(r + "\\", StringComparison.OrdinalIgnoreCase);
    }

    public static void Build(DiskAnalysisResult result)
    {
        const long MB = 1024L * 1024;
        List<DiskSuggestion> list = new List<DiskSuggestion>();
        HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string root = result.Root;

        foreach (KnownPath known in KnownPaths(root))
        {
            long bytes = -1;
            bool isDir = true;
            int node = result.FindDirectory(known.Path);
            if (node >= 0) bytes = result.Nodes[node].Alloc;
            else
            {
                foreach (DiskFileEntry f in result.LargeFiles)
                {
                    if (f.Path != null && f.Path.Equals(known.Path, StringComparison.OrdinalIgnoreCase)) { bytes = Math.Max(f.Alloc, f.Logical); isDir = false; break; }
                }
            }
            if (bytes < known.MinBytes || !seen.Add(known.Path)) continue;
            DiskSuggestion s = new DiskSuggestion();
            s.Path = known.Path; s.IsDirectory = isDir; s.Category = known.Category; s.Risk = known.Risk;
            s.Bytes = bytes; s.Advice = known.Advice; s.CanRecycle = known.CanRecycle; s.CatalogId = known.CatalogId;
            list.Add(s);
        }

        // Directory patterns: dependency folders and build caches.
        for (int i = 1; i < result.Nodes.Count; i++)
        {
            DiskDirNode n = result.Nodes[i];
            if (n.Alloc < 100 * MB) continue;
            string category = null, advice = null, risk = "中";
            if (n.Name.Equals("node_modules", StringComparison.OrdinalIgnoreCase))
            {
                // Only the outermost node_modules of a project.
                bool nested = false;
                int p = n.Parent;
                int guard = 0;
                while (p > 0 && guard++ < 512)
                {
                    if (result.Nodes[p].Name.Equals("node_modules", StringComparison.OrdinalIgnoreCase)) { nested = true; break; }
                    p = result.Nodes[p].Parent;
                }
                if (nested) continue;
                category = "Node.js 依赖目录";
                advice = "不再活跃的项目可删除 node_modules，需要时在项目目录运行 npm install / pnpm install 重建。";
            }
            else if (n.CacheTag)
            {
                category = "构建缓存目录（CACHEDIR.TAG）";
                advice = "目录声明自己是可重建的缓存（例如 Rust target、Cargo/pip 缓存）；删除后重新构建会变慢。";
                risk = "低";
            }
            else if (n.VenvMarker && n.Alloc >= 300 * MB)
            {
                category = "Python 虚拟环境";
                advice = "不再使用的项目可删除虚拟环境，需要时按 requirements / pyproject 重新创建。";
            }
            if (category == null) continue;
            string path = result.GetPath(i);
            if (!seen.Add(path)) continue;
            DiskSuggestion s = new DiskSuggestion();
            s.Path = path; s.IsDirectory = true; s.Category = category; s.Risk = risk; s.Bytes = n.Alloc; s.Advice = advice;
            s.CanRecycle = !IsProtectedPath(path);
            list.Add(s);
        }

        string profile = Env(Environment.SpecialFolder.UserProfile);
        string downloads = String.IsNullOrEmpty(profile) ? "" : System.IO.Path.Combine(profile, "Downloads");
        string desktop = Env(Environment.SpecialFolder.DesktopDirectory);
        string documents = Env(Environment.SpecialFolder.MyDocuments);
        string windows = Env(Environment.SpecialFolder.Windows);
        DateTime now = DateTime.UtcNow;
        foreach (DiskFileEntry f in result.LargeFiles)
        {
            if (f.Path == null || seen.Contains(f.Path)) continue;
            string ext = f.Extension;
            long size = Math.Max(f.Alloc, f.Logical);
            double ageDays = f.LastWriteUtc == DateTime.MinValue ? 0 : (now - f.LastWriteUtc).TotalDays;
            bool inWindows = Under(f.Path, windows);
            string category = null, advice = null, risk = "中";
            bool recyclable = true;
            if (ext == "dmp" && size >= 16 * MB)
            {
                category = "崩溃转储文件";
                advice = "不再排查对应程序崩溃时可删除。";
            }
            else if ((ext == "log" || ext == "etl" || ext == "trace") && size >= 100 * MB && !inWindows)
            {
                category = "超大日志文件";
                advice = "确认对应程序已关闭且无需排查问题后可删除；若持续增长，请调整该程序的日志设置。";
            }
            else if ((ext == "iso" || ext == "msi" || ext == "exe" || ext == "zip" || ext == "7z" || ext == "rar" || ext == "msix" || ext == "appx" || ext == "img") &&
                size >= 100 * MB && ageDays >= 30 && (Under(f.Path, downloads) || Under(f.Path, desktop) || Under(f.Path, documents)))
            {
                category = "旧安装包或压缩包";
                advice = "下载超过 30 天的安装镜像或压缩包；确认已安装或已解压后可删除，或移到其他盘保存。";
            }
            else if ((ext == "tmp" || ext == "bak" || ext == "old" || ext == "temp") && size >= 50 * MB && !inWindows)
            {
                category = "临时或备份文件";
                advice = "通常由程序中断或升级留下；确认对应程序没有在使用后可删除。";
            }
            else if ((ext == "vhdx" || ext == "vhd" || ext == "vmdk" || ext == "qcow2") && size >= 1024 * MB)
            {
                category = "虚拟磁盘文件";
                advice = "属于 WSL、Docker 或虚拟机，不要直接删除。可在对应程序内清理，或用 wsl --manage <发行版> --set-sparse true / Optimize-VHD 压缩。";
                risk = "高";
                recyclable = false;
            }
            else if (size >= 1024 * MB && ageDays >= 180 && Under(f.Path, profile) && !inWindows)
            {
                category = "长期未修改的大文件";
                advice = "超过 180 天未修改；确认不再需要后删除，或移到其他盘或网盘。";
            }
            if (category == null) continue;
            seen.Add(f.Path);
            DiskSuggestion s = new DiskSuggestion();
            s.Path = f.Path; s.IsDirectory = false; s.Category = category; s.Risk = risk; s.Bytes = size; s.Advice = advice;
            s.CanRecycle = recyclable && !IsProtectedPath(f.Path);
            list.Add(s);
        }
        list.Sort(delegate (DiskSuggestion x, DiskSuggestion y) { return y.Bytes.CompareTo(x.Bytes); });
        if (list.Count > 500) list.RemoveRange(500, list.Count - 500);
        result.Suggestions = list;
    }
}

public abstract class VolumeSource : IDisposable
{
    public abstract int ReadAt(long offset, byte[] buffer, int count);
    public void ReadExact(long offset, byte[] buffer, int count)
    {
        int done = 0;
        byte[] scratch = null;
        while (done < count)
        {
            int read;
            if (done == 0) read = ReadAt(offset, buffer, count);
            else
            {
                if (scratch == null) scratch = new byte[count];
                read = ReadAt(offset + done, scratch, count - done);
                if (read > 0) Buffer.BlockCopy(scratch, 0, buffer, done, read);
            }
            if (read <= 0) throw new EndOfStreamException("分区读取提前结束");
            done += read;
        }
    }
    public abstract void Dispose();
}

public sealed class StreamVolumeSource : VolumeSource
{
    private readonly Stream stream;
    public StreamVolumeSource(Stream stream) { this.stream = stream; }
    public override int ReadAt(long offset, byte[] buffer, int count)
    {
        stream.Position = offset;
        return stream.Read(buffer, 0, count);
    }
    public override void Dispose() { stream.Dispose(); }
}

public sealed class WindowsVolumeSource : VolumeSource
{
    private readonly SafeFileHandle handle;
    private WindowsVolumeSource(SafeFileHandle handle) { this.handle = handle; }

    public static WindowsVolumeSource Open(string drive)
    {
        string device = "\\\\.\\" + drive.TrimEnd('\\');
        // Commit dirty metadata first so the table reflects recent changes; failure is harmless.
        using (SafeFileHandle flush = NativeMethods.CreateFileW(device, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero))
        {
            if (!flush.IsInvalid) NativeMethods.FlushFileBuffers(flush);
        }
        SafeFileHandle h = NativeMethods.CreateFileW(device, 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            h.Dispose();
            throw new Win32Exception(error, error == 5 ? "需要管理员权限才能直接读取 MFT" : "无法打开分区 " + device);
        }
        return new WindowsVolumeSource(h);
    }

    public override int ReadAt(long offset, byte[] buffer, int count)
    {
        long newPosition;
        if (!NativeMethods.SetFilePointerEx(handle, offset, out newPosition, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        int read;
        if (!NativeMethods.ReadFile(handle, buffer, count, out read, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return read;
    }

    public override void Dispose() { handle.Dispose(); }
}

public sealed class SafeFindHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public SafeFindHandle() : base(true) { }
    protected override bool ReleaseHandle() { return NativeMethods.FindClose(handle); }
}

internal static class NativeMethods
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WIN32_FIND_DATAW
    {
        public uint dwFileAttributes;
        public uint ftCreationTimeLow;
        public uint ftCreationTimeHigh;
        public uint ftLastAccessTimeLow;
        public uint ftLastAccessTimeHigh;
        public uint ftLastWriteTimeLow;
        public uint ftLastWriteTimeHigh;
        public uint nFileSizeHigh;
        public uint nFileSizeLow;
        public uint dwReserved0;
        public uint dwReserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string cFileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string cAlternateFileName;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern SafeFindHandle FindFirstFileExW(string fileName, int infoLevel, out WIN32_FIND_DATAW data, int searchOp, IntPtr filter, int flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FindNextFileW(SafeFindHandle handle, out WIN32_FIND_DATAW data);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FindClose(IntPtr handle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern SafeFileHandle CreateFileW(string fileName, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ReadFile(SafeFileHandle handle, byte[] buffer, int count, out int read, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetFilePointerEx(SafeFileHandle handle, long distance, out long newPosition, uint method);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FlushFileBuffers(SafeFileHandle handle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetDiskFreeSpaceW(string root, out uint sectorsPerCluster, out uint bytesPerSector, out uint freeClusters, out uint totalClusters);
}
'@ -ErrorAction Stop
    }
    catch { if ($null -eq ('DiskAnalyzer' -as [type])) { throw } }
}

function Invoke-DiskAnalysis {
    param([string]$Root = 'C:\', [bool]$PreferMft = $true)
    Initialize-DiskAnalyzer
    $analyzer = New-Object DiskAnalyzer
    $cancellation = New-Object Threading.CancellationTokenSource
    try { return $analyzer.Analyze($Root, $PreferMft, $cancellation.Token) }
    finally { $cancellation.Dispose() }
}

function Get-CatalogSuggestions {
    param([object[]]$Items, [Int64]$MinBytes = 50MB)
    # Scanned cleanup items are the safest suggestions: explicit directories with their own guards.
    foreach ($item in @($Items)) {
        if ($item.Action -eq 'Manage' -or $item.IdentityBlocked -or [Int64]$item.EstimatedBytes -lt $MinBytes) { continue }
        $first = @($item.PathSpecs | Where-Object { $null -ne $_ } | Select-Object -First 1)
        $suggestion = New-Object DiskSuggestion
        $suggestion.Path = if ($first.Count -gt 0) { [string]$first[0].Path } else { '' }
        $suggestion.IsDirectory = $true
        $suggestion.Category = '清理项目：' + $item.Name
        $suggestion.Risk = $item.Risk
        $suggestion.Bytes = [Int64]$item.EstimatedBytes
        $suggestion.Advice = '在“清理项目”页勾选此项，由程序按保留期、类型和运行状态保护执行。' + $item.Description
        $suggestion.CanRecycle = $false
        $suggestion.CatalogId = $item.Id
        $suggestion
    }
}

function Write-AnalysisReport {
    param([Parameter(Mandatory = $true)]$Result, [int]$Top = 15)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('分析完成：{0}，模式 {1}，{2:N0} 个文件，{3:N0} 个文件夹，占用 {4}，用时 {5:N1} 秒，无法读取 {6} 项' -f $Result.Root, $Result.Mode, $Result.TotalFiles, $Result.TotalDirs, (Format-ByteSize $Result.TotalAlloc), $Result.Seconds, $Result.Errors))
    if (-not [string]::IsNullOrWhiteSpace($Result.FallbackReason)) { $lines.Add('未使用 MFT 直读：' + $Result.FallbackReason) }
    if (-not [string]::IsNullOrWhiteSpace($Result.Timings)) { $lines.Add('各阶段用时：' + $Result.Timings) }
    $lines.Add('')
    $lines.Add('[最大的文件夹]')
    foreach ($child in @($Result.GetChildren(0) | Select-Object -First $Top)) {
        $node = $Result.Nodes[$child]
        $lines.Add(('{0,12}  {1,10:N0} 个文件  {2}' -f (Format-ByteSize $node.Alloc), $node.Files, $Result.GetPath($child)))
    }
    $lines.Add('')
    $lines.Add('[最大的文件]')
    foreach ($file in @($Result.TopFiles | Select-Object -First $Top)) {
        $lines.Add(('{0,12}  {1}' -f (Format-ByteSize ([Math]::Max($file.Alloc, $file.Logical))), $file.Path))
    }
    $lines.Add('')
    $lines.Add('[大量小文件的文件夹]')
    foreach ($dense in @($Result.DenseDirs | Select-Object -First $Top)) {
        $lines.Add(('{0,10:N0} 个文件  平均 {1,9}  {2}' -f $dense.Files, (Format-ByteSize $dense.AverageBytes), $dense.Path))
    }
    $lines.Add('')
    $lines.Add('[删除建议]')
    foreach ($suggestion in @($Result.Suggestions | Select-Object -First $Top)) {
        $lines.Add(('{0,12}  [{1}] {2}  {3}' -f (Format-ByteSize $suggestion.Bytes), $suggestion.Risk, $suggestion.Category, $suggestion.Path))
    }
    return $lines
}

function Test-RecyclablePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    Initialize-DiskAnalyzer
    if ([DiskSuggestionRules]::IsProtectedPath($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try { Assert-NoReparsePointInPathChain -Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))) } catch { return $false }
    return $true
}

function Move-PathToRecycleBin {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-RecyclablePath -Path $Path)) { throw "此路径受保护或已不存在，未执行：$Path" }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $ui = [Microsoft.VisualBasic.FileIO.UIOption]::AllDialogs
    $recycle = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
    $cancel = [Microsoft.VisualBasic.FileIO.UICancelOption]::DoNothing
    if (Test-Path -LiteralPath $Path -PathType Container) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, $ui, $recycle, $cancel) }
    else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, $ui, $recycle, $cancel) }
    return -not (Test-Path -LiteralPath $Path)
}

# ---- Daily scheduled cleanup (only items marked ScheduleSafe; never admin, never manual) ----

function Get-ScheduleDirectory {
    return (Join-Path $env:LOCALAPPDATA 'CDriveCleaner')
}

function Get-ScheduleConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($script:ScheduleConfigOverride)) { return $script:ScheduleConfigOverride }
    return (Join-Path (Get-ScheduleDirectory) 'schedule.json')
}

function Get-ScheduleConfig {
    $default = [pscustomobject]@{ Enabled = $false; Time = '12:30'; LogKeepDays = 7; ItemIds = @() }
    $path = Get-ScheduleConfigPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $default }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $time = [string]$raw.Time
        if ($time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { $time = $default.Time }
        $keep = if ([int]$raw.LogKeepDays -in @(7, 30)) { [int]$raw.LogKeepDays } else { 7 }
        return [pscustomobject]@{ Enabled = [bool]$raw.Enabled; Time = $time; LogKeepDays = $keep; ItemIds = @($raw.ItemIds | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^[a-z0-9-]+$' }) }
    }
    catch { return $default }
}

function Save-ScheduleConfig {
    param([Parameter(Mandatory = $true)]$Config)
    $path = Get-ScheduleConfigPath
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    $json = [pscustomobject]@{ Enabled = [bool]$Config.Enabled; Time = [string]$Config.Time; LogKeepDays = [int]$Config.LogKeepDays; ItemIds = @($Config.ItemIds) } | ConvertTo-Json
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Test-ScheduleSafeItem {
    param($Item)
    # Defence in depth: the flag alone is not enough; automatic runs must also be unattended-safe.
    return ((Get-ItemOption $Item 'ScheduleSafe' $false) -eq $true) -and $Item.Action -eq 'Paths' -and (-not $Item.RequiresAdmin) -and $Item.Risk -eq '低' -and (-not (Get-ItemOption $Item 'IdentityBlocked' $false))
}

function Get-ScheduleEligibleItems {
    param([object[]]$Items)
    return @($Items | Where-Object { Test-ScheduleSafeItem $_ })
}

function Write-ScheduleLog {
    param([string]$Path, [string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    [IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}

function Invoke-ScheduledCleanup {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($LogPath))
    $script:LogKeepDays = if ([int]$Config.LogKeepDays -in @(7, 30)) { [int]$Config.LogKeepDays } else { 7 }
    $script:PolicyReferenceUtc = [datetime]::UtcNow
    $wanted = @{}
    foreach ($id in @($Config.ItemIds)) { $wanted[[string]$id] = $true }
    $summary = [pscustomobject]@{ Ran = 0; Skipped = 0; Failed = 0; Released = [Int64]0; Deleted = 0 }
    $before = (Get-CDriveInfo).Free
    Write-ScheduleLog $LogPath ('开始定时清理：{0} 个已选项目，日志保留 {1} 天。' -f $wanted.Count, $script:LogKeepDays)
    foreach ($item in @($Items)) {
        if (-not $wanted.ContainsKey($item.Id)) { continue }
        if (-not (Test-ScheduleSafeItem $item)) {
            $summary.Skipped++
            Write-ScheduleLog $LogPath ('跳过：{0} 不在无风险定时清理范围内。' -f $item.Name)
            continue
        }
        if (Test-ItemProcessesRunning -Item $item) {
            $summary.Skipped++
            Write-ScheduleLog $LogPath ('跳过：{0} 的相关程序正在运行。' -f $item.Name)
            continue
        }
        try {
            $result = Invoke-CleanupAction -Item $item
            $summary.Ran++
            Write-ScheduleLog $LogPath ('完成：{0}；失败 {1}，跳过链接或共享文件 {2}。{3}' -f $item.Name, $result.Failed, $result.Skipped, $result.Detail)
        }
        catch {
            $summary.Failed++
            Write-ScheduleLog $LogPath ('失败：{0} — {1}' -f $item.Name, $_.Exception.Message)
        }
    }
    $summary.Released = [Math]::Max([Int64]0, (Get-CDriveInfo).Free - $before)
    Write-ScheduleLog $LogPath ('结束：执行 {0} 项，跳过 {1} 项，失败 {2} 项，可用空间增加 {3}。' -f $summary.Ran, $summary.Skipped, $summary.Failed, (Format-ByteSize $summary.Released))
    return $summary
}

function Remove-OldScheduleLogs {
    param([string]$Directory, [int]$KeepDays = 30)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    $cutoff = (Get-Date).AddDays(-$KeepDays)
    # Only this tool's own daily log files are pruned.
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -File -Filter 'scheduled-*.log' -ErrorAction SilentlyContinue)) {
        if ($file.Name -match '^scheduled-\d{8}\.log$' -and $file.LastWriteTime -lt $cutoff) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
    }
}




function Get-InstalledScriptPath {
    return (Join-Path (Get-ScheduleDirectory) 'CDriveCleaner.ps1')
}

function Register-DailyCleanupTask {
    param([Parameter(Mandatory = $true)]$Config)
    if ($Config.Time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw '时间格式无效。' }
    $directory = Get-ScheduleDirectory
    [void][IO.Directory]::CreateDirectory($directory)
    # The task runs a stable copy, so moving or deleting the downloaded folder does not break it.
    $installed = Get-InstalledScriptPath
    if (-not [IO.Path]::GetFullPath($script:ScriptPath).Equals([IO.Path]::GetFullPath($installed), [StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $script:ScriptPath -Destination $installed -Force
    }
    Save-ScheduleConfig -Config $Config
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ScheduledClean' -f $installed
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $directory
    $at = [datetime]::ParseExact($Config.Time, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $trigger = New-ScheduledTaskTrigger -Daily -At $at
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
    $description = 'C 盘清理助手：每日清理已选的无风险项目（旧运行日志、7 天前临时文件等）。在清理助手的“定时清理”页修改或停用。'
    [void](Register-ScheduledTask -TaskPath '\CDriveCleaner\' -TaskName 'DailySafeCleanup' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $description -Force)
}

function Unregister-DailyCleanupTask {
    $task = Get-ScheduledTask -TaskPath '\CDriveCleaner\' -TaskName 'DailySafeCleanup' -ErrorAction SilentlyContinue
    if ($null -ne $task) { Unregister-ScheduledTask -TaskPath '\CDriveCleaner\' -TaskName 'DailySafeCleanup' -Confirm:$false }
    $config = Get-ScheduleConfig
    $config.Enabled = $false
    Save-ScheduleConfig -Config $config
}

function Get-DailyCleanupTaskState {
    try {
        $task = Get-ScheduledTask -TaskPath '\CDriveCleaner\' -TaskName 'DailySafeCleanup' -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -InputObject $task -ErrorAction SilentlyContinue
        $last = if ($null -ne $info -and $info.LastRunTime -gt [datetime]'2000-01-01') { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') } else { '尚未运行' }
        $next = if ($null -ne $info -and $null -ne $info.NextRunTime -and $info.NextRunTime -gt [datetime]'2000-01-01') { $info.NextRunTime.ToString('yyyy-MM-dd HH:mm') } else { '—' }
        return ('已启用（{0}）；上次运行：{1}；下次运行：{2}' -f $task.State, $last, $next)
    }
    catch { return '未启用' }
}


function Invoke-BackgroundWork {
    param([hashtable]$Request)
    $state = $script:WorkerState
    $script:PolicyReferenceUtc = [datetime]::UtcNow
    if ($Request.ContainsKey('LogKeepDays') -and $Request.LogKeepDays -in @(7, 30)) { $script:LogKeepDays = [int]$Request.LogKeepDays }
    $items = @([Management.Automation.PSSerializer]::Deserialize($Request.ItemsXml))
    $state.Total = $items.Count
    $state.Phase = if ($Request.Mode -eq 'Scan') { '扫描' } else { '清理' }
    $before = [Int64]0
    $haveBefore = $false
    $cancelled = $false
    $fatal = ''
    $goalReached = $false
    try {
        Test-WorkerCancellation
        $state.DriveInfo = Get-CDriveInfo
        $before = $state.DriveInfo.Free
        $haveBefore = $true
        foreach ($item in $items) {
            Test-WorkerCancellation
            $state.CurrentName = $item.Name
            $state.CurrentPath = ''
            $state.Messages.Enqueue([pscustomobject]@{ Kind = 'Start'; Id = $item.Id; Status = ($state.Phase + '中') })
            if ($Request.Mode -eq 'Scan') {
                try {
                    if ($item.IdentityBlocked) { throw '账户不一致，已禁用' }
                    $item.EstimatedBytes = Measure-CleanupItem -Item $item
                    Test-WorkerCancellation
                    $item.InUse = ($item.Action -ne 'Manage') -and (Test-ItemProcessesRunning -Item $item)
                    if ($item.Action -eq 'Manage') { $item.ScanStatus = '手动管理' }
                    elseif ((Get-ItemOption $item 'ScanIssues' 0) -gt 0) { $item.ScanStatus = '部分可扫描' }
                    elseif ($item.InUse) { $item.ScanStatus = '请先关闭程序' }
                    elseif ($item.EstimatedBytes -gt 0) { $item.ScanStatus = '可清理' }
                    elseif ($item.Action -eq 'Hibernate') { $item.ScanStatus = '休眠已关闭' }
                    else { $item.ScanStatus = '无内容' }
                }
                catch {
                    Test-WorkerCancellation
                    $item.EstimatedBytes = 0
                    if ($item.IdentityBlocked) { $item.ScanStatus = '账户不一致，已禁用' }
                    elseif ($item.RequiresAdmin -and (-not $script:IsAdministrator)) { $item.ScanStatus = '需管理员扫描' }
                    else { $item.ScanStatus = '扫描失败' }
                    $state.Messages.Enqueue([pscustomobject]@{ Kind = 'Log'; Text = ('扫描失败：{0} — {1}' -f $item.Name, $_.Exception.Message) })
                }
                $state.Messages.Enqueue([pscustomobject]@{ Kind = 'Scanned'; Item = $item })
            }
            else {
                $state.DriveInfo = Get-CDriveInfo
                if ($Request.StopAtGoal -and $state.DriveInfo.Free -ge $Request.GoalBytes) {
                    $goalReached = $true
                    $state.Messages.Enqueue([pscustomobject]@{ Kind = 'Cleaned'; Id = $item.Id; Status = '达到目标，未执行'; Text = '已达到目标，停止后续清理。' })
                    break
                }
                $itemBefore = $state.DriveInfo.Free
                try {
                    $result = Invoke-CleanupAction -Item $item
                    $state.DriveInfo = Get-CDriveInfo
                    $released = [Math]::Max([Int64]0, $state.DriveInfo.Free - $itemBefore)
                    $status = if ($result.Failed -gt 0 -or $result.Skipped -gt 0) { '部分完成' } else { '已完成' }
                    $detail = '{0}：{1}；可用空间增加 {2}；失败 {3}，跳过链接或共享文件 {4}。{5}' -f $status, $item.Name, (Format-ByteSize $released), $result.Failed, $result.Skipped, $result.Detail
                }
                catch {
                    Test-WorkerCancellation
                    $status = '失败'
                    $detail = '清理失败：{0} — {1}' -f $item.Name, $_.Exception.Message
                }
                $state.Messages.Enqueue([pscustomobject]@{ Kind = 'Cleaned'; Id = $item.Id; Status = $status; Text = $detail })
            }
            $state.Completed++
        }
        Test-WorkerCancellation
    }
    catch {
        if ($script:WorkerCancellation.IsCancellationRequested) { $cancelled = $true }
        else { $fatal = $_.Exception.Message }
    }
    finally {
        $released = [Int64]0
        try {
            $state.DriveInfo = Get-CDriveInfo
            if ($haveBefore) { $released = [Math]::Max([Int64]0, $state.DriveInfo.Free - $before) }
        }
        catch { $state.Messages.Enqueue([pscustomobject]@{ Kind = 'Log'; Text = ('空间刷新失败：' + $_.Exception.Message) }) }
        $state.Outcome = [pscustomobject]@{ Mode = $Request.Mode; Cancelled = $cancelled; Error = $fatal; Released = $released; GoalReached = $goalReached }
    }
}

function New-CleanupWorker {
    param([Parameter(Mandatory = $true)][hashtable]$Request)
    $state = [hashtable]::Synchronized(@{
        Messages = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')
        Phase = '准备'; CurrentName = ''; CurrentPath = ''; Completed = 0; Total = 1
        Deleted = 0; Failed = 0; Skipped = 0; DriveInfo = $null; Outcome = $null
    })
    $cancellation = New-Object Threading.CancellationTokenSource
    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.ThreadOptions = 'ReuseThread'
    $shell = [PowerShell]::Create()
    try {
        $runspace.Open()
        $shell.Runspace = $runspace
        [void]$shell.AddScript({
            param($path, $request, $state, $cancellation)
            & $path -WorkerRequest $request -WorkerState $state -WorkerCancellation $cancellation
        }.ToString()).AddArgument($script:ScriptPath).AddArgument($Request).AddArgument($state).AddArgument($cancellation)
        $handle = $shell.BeginInvoke()
        return [pscustomobject]@{ Shell = $shell; Handle = $handle; State = $state; Cancellation = $cancellation; Runspace = $runspace }
    }
    catch {
        $shell.Dispose()
        $runspace.Dispose()
        $cancellation.Dispose()
        throw
    }
}

if ($null -ne $WorkerRequest) {
    $script:IsAdministrator = Test-IsAdministrator
    Invoke-BackgroundWork -Request $WorkerRequest
    return
}

$script:IsAdministrator = Test-IsAdministrator
$script:Items = @(Get-CleanupCatalog)
if ($script:ElevationIdentityMismatch) {
    foreach ($catalogItem in $script:Items) {
        if (-not $catalogItem.RequiresAdmin) { $catalogItem.IdentityBlocked = $true }
    }
}

if ($ScheduledClean) {
    $mutex = New-Object Threading.Mutex($false, 'Local\CDriveCleanerScheduledClean')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { exit 0 }
        $logDirectory = Join-Path (Get-ScheduleDirectory) 'logs'
        $logPath = Join-Path $logDirectory ('scheduled-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        Remove-OldScheduleLogs -Directory $logDirectory
        $summary = Invoke-ScheduledCleanup -Config (Get-ScheduleConfig) -Items $script:Items -LogPath $logPath
        Write-Output ('定时清理结束：执行 {0}，跳过 {1}，失败 {2}，释放 {3}。' -f $summary.Ran, $summary.Skipped, $summary.Failed, (Format-ByteSize $summary.Released))
    }
    finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    exit 0
}

if ($AnalyzeOnly) {
    $analysis = Invoke-DiskAnalysis -Root $AnalyzeRoot -PreferMft $true
    Write-AnalysisReport -Result $analysis
    exit 0
}

if ($SelfTest) {
    $testBase = Join-Path $env:TEMP ('CDriveCleanerSelfTest_' + [Guid]::NewGuid().ToString('N'))
    $allowedRoot = Join-Path $testBase 'allowed'
    $target = Join-Path $allowedRoot 'cache'
    $outside = Join-Path $testBase 'outside'
    $junction = Join-Path $target 'escape'
    $ancestorSource = Join-Path $testBase 'ancestor-source'
    $ancestorJunction = Join-Path $allowedRoot 'ancestor-link'
    try {
        if (-not (Test-IsPathBelowRoot -Path $testBase -AllowedRoot $env:TEMP)) {
            throw '自测目录安全校验失败。'
        }
        [void](New-Item -ItemType Directory -Path (Join-Path $target 'nested') -Force)
        [void](New-Item -ItemType Directory -Path $outside -Force)
        [IO.File]::WriteAllText((Join-Path $target 'cache.bin'), 'cache')
        [IO.File]::WriteAllText((Join-Path $target 'nested\cache2.bin'), 'cache2')
        [IO.File]::WriteAllText((Join-Path $outside 'sentinel.txt'), 'must-survive')
        [void](New-Item -ItemType Junction -Path $junction -Target $outside)

        $testResult = Clear-VerifiedDirectoryContents -Target $target -AllowedRoot $allowedRoot
        if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw '自测失败：目标根目录被删除。' }
        if (-not (Test-Path -LiteralPath (Join-Path $outside 'sentinel.txt') -PathType Leaf)) { throw '自测失败：越界哨兵文件被删除。' }
        if (Test-Path -LiteralPath (Join-Path $target 'cache.bin')) { throw '自测失败：普通缓存文件仍存在。' }
        if ($testResult.Skipped -lt 1) { throw '自测失败：未报告跳过重解析点。' }

        [void](New-Item -ItemType Directory -Path (Join-Path $ancestorSource 'cache') -Force)
        [IO.File]::WriteAllText((Join-Path $ancestorSource 'cache\ancestor-sentinel.txt'), 'must-survive')
        [void](New-Item -ItemType Junction -Path $ancestorJunction -Target $ancestorSource)
        $ancestorRejected = $false
        try {
            [void](Clear-VerifiedDirectoryContents -Target (Join-Path $ancestorJunction 'cache') -AllowedRoot $allowedRoot)
        }
        catch {
            $ancestorRejected = $true
        }
        if (-not $ancestorRejected) { throw '自测失败：祖先目录联接未被拒绝。' }
        if (-not (Test-Path -LiteralPath (Join-Path $ancestorSource 'cache\ancestor-sentinel.txt') -PathType Leaf)) { throw '自测失败：祖先联接后的哨兵被删除。' }

        Write-Output ('安全自测通过：删除节点 {0}，跳过内部重解析点 {1}，祖先联接已拒绝，越界哨兵完整。' -f $testResult.Deleted, $testResult.Skipped)
    }
    finally {
        if (Test-Path -LiteralPath $junction) {
            [IO.Directory]::Delete($junction)
        }
        if (Test-Path -LiteralPath $ancestorJunction) {
            [IO.Directory]::Delete($ancestorJunction)
        }
        if ((Test-Path -LiteralPath $testBase) -and (Test-IsPathBelowRoot -Path $testBase -AllowedRoot $env:TEMP)) {
            Remove-Item -LiteralPath $testBase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    exit 0
}

if ($ScanOnly) {
    foreach ($item in $script:Items) {
        try {
            $item.EstimatedBytes = Measure-CleanupItem -Item $item
            $item.InUse = ($item.Action -ne 'Manage') -and (Test-ItemProcessesRunning -Item $item)
            if ($item.Action -eq 'Manage') { $item.ScanStatus = '手动管理' }
            elseif ($item.IdentityBlocked) { $item.ScanStatus = '账户不一致，已禁用' }
            elseif ((Get-ItemOption $item 'ScanIssues' 0) -gt 0) { $item.ScanStatus = '部分可扫描' }
            elseif ($item.InUse) { $item.ScanStatus = '请先关闭程序' }
            else { $item.ScanStatus = if ($item.EstimatedBytes -gt 0) { '可清理' } else { '无内容' } }
        }
        catch {
            if ($item.RequiresAdmin -and (-not $script:IsAdministrator)) { $item.ScanStatus = '需管理员扫描' }
            else { $item.ScanStatus = '扫描失败' }
        }
    }
    $driveInfo = Get-CDriveInfo
    Write-Output ('C 盘可用：{0} / {1}；管理员：{2}' -f (Format-ByteSize $driveInfo.Free), (Format-ByteSize $driveInfo.Size), $script:IsAdministrator)
    $script:Items | Select-Object Name, Risk, RequiresAdmin, @{Name = 'Estimated'; Expression = { Format-ByteSize $_.EstimatedBytes }}, ScanStatus | Format-Table -AutoSize
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
[Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$form = New-Object Windows.Forms.Form
$form.Text = 'C 盘清理助手 v' + $script:AppVersion
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(1200, 820)
$form.MinimumSize = New-Object Drawing.Size(1120, 650)
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$form.BackColor = [Drawing.Color]::White

$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.ColumnCount = 1
$layout.RowCount = 3
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 92)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 28)))
$form.Controls.Add($layout)

$header = New-Object Windows.Forms.Panel
$header.Dock = 'Fill'
$header.BackColor = [Drawing.Color]::FromArgb(245, 248, 252)
$layout.Controls.Add($header, 0, 0)

$mainTabs = New-Object Windows.Forms.TabControl
$mainTabs.Dock = 'Fill'
$mainTabs.Padding = New-Object Drawing.Point(14, 5)
$layout.Controls.Add($mainTabs, 0, 1)
$cleanTab = New-Object Windows.Forms.TabPage
$cleanTab.Text = '清理项目'
$analysisTab = New-Object Windows.Forms.TabPage
$analysisTab.Text = '空间分析'
$scheduleTab = New-Object Windows.Forms.TabPage
$scheduleTab.Text = '定时清理'
$mainTabs.TabPages.AddRange(@($cleanTab, $analysisTab, $scheduleTab))

$cleanLayout = New-Object Windows.Forms.TableLayoutPanel
$cleanLayout.Dock = 'Fill'
$cleanLayout.ColumnCount = 1
$cleanLayout.RowCount = 3
[void]$cleanLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 86)))
[void]$cleanLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$cleanLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 148)))
$cleanTab.Controls.Add($cleanLayout)

$title = New-Object Windows.Forms.Label
$title.Text = 'C 盘清理助手'
$title.Font = New-Object Drawing.Font('Microsoft YaHei UI', 18, [Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(18, 10)
$header.Controls.Add($title)

$diskLabel = New-Object Windows.Forms.Label
$diskLabel.Text = '正在读取 C 盘空间…'
$diskLabel.AutoSize = $true
$diskLabel.Location = New-Object Drawing.Point(21, 54)
$header.Controls.Add($diskLabel)

$selectedLabel = New-Object Windows.Forms.Label
$selectedLabel.Text = '已选预计：0 B'
$selectedLabel.AutoSize = $true
$selectedLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10, [Drawing.FontStyle]::Bold)
$selectedLabel.Location = New-Object Drawing.Point(570, 52)
$header.Controls.Add($selectedLabel)

$goalLabel = New-Object Windows.Forms.Label
$goalLabel.Text = '目标可用空间：'
$goalLabel.AutoSize = $true
$goalLabel.Anchor = 'Top,Right'
$goalLabel.Location = New-Object Drawing.Point(935, 54)
$header.Controls.Add($goalLabel)

$goalBox = New-Object Windows.Forms.NumericUpDown
$goalBox.Minimum = 1
$goalBox.Maximum = 1000
$goalBox.Value = [Math]::Min(1000, [Math]::Max(1, $PresetGoalGB))
$goalBox.DecimalPlaces = 0
$goalBox.Width = 72
$goalBox.Anchor = 'Top,Right'
$goalBox.Location = New-Object Drawing.Point(1040, 50)
$header.Controls.Add($goalBox)

$goalUnit = New-Object Windows.Forms.Label
$goalUnit.Text = 'GB'
$goalUnit.AutoSize = $true
$goalUnit.Anchor = 'Top,Right'
$goalUnit.Location = New-Object Drawing.Point(1116, 54)
$header.Controls.Add($goalUnit)

$toolbar = New-Object Windows.Forms.FlowLayoutPanel
$toolbar.Dock = 'Fill'
$toolbar.FlowDirection = 'LeftToRight'
$toolbar.Padding = New-Object Windows.Forms.Padding(12, 8, 8, 5)
$toolbar.WrapContents = $true
$toolbar.BackColor = [Drawing.Color]::White
$cleanLayout.Controls.Add($toolbar, 0, 0)

function New-ToolbarButton {
    param([string]$Text, [int]$Width = 112)
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.Width = $Width
    $button.Height = 32
    $button.FlatStyle = 'System'
    return $button
}

$scanButton = New-ToolbarButton -Text '重新扫描' -Width 105
$safeButton = New-ToolbarButton -Text '勾选低风险项' -Width 125
$noneButton = New-ToolbarButton -Text '取消全选' -Width 105
$cleanButton = New-ToolbarButton -Text '清理已选项目' -Width 135
$adminButton = New-ToolbarButton -Text '以管理员身份重启' -Width 155
$cancelButton = New-ToolbarButton -Text '停止' -Width 85
$cancelButton.Enabled = $false
$toolbar.Controls.AddRange(@($scanButton, $safeButton, $noneButton, $cleanButton, $adminButton, $cancelButton))
$toolbar.SetFlowBreak($cancelButton, $true)

$stopAtGoalCheck = New-Object Windows.Forms.CheckBox
$stopAtGoalCheck.Text = '每项完成后，达到目标则停止'
$stopAtGoalCheck.Checked = ($PresetStopAtGoal -eq 'true')
$stopAtGoalCheck.AutoSize = $true
$stopAtGoalCheck.Margin = New-Object Windows.Forms.Padding(14, 8, 0, 0)
$toolbar.Controls.Add($stopAtGoalCheck)

$adminStateLabel = New-Object Windows.Forms.Label
$adminStateLabel.AutoSize = $true
$adminStateLabel.Margin = New-Object Windows.Forms.Padding(14, 8, 0, 0)
$adminStateLabel.Text = if ($script:ElevationIdentityMismatch) { '管理员账户与原账户不同' } elseif ($script:IsAdministrator) { '当前：管理员模式' } else { '当前：普通模式' }
$adminStateLabel.ForeColor = if ($script:ElevationIdentityMismatch) { [Drawing.Color]::Firebrick } elseif ($script:IsAdministrator) { [Drawing.Color]::FromArgb(20, 125, 65) } else { [Drawing.Color]::DimGray }
$toolbar.Controls.Add($adminStateLabel)
$retentionLabel = New-Object Windows.Forms.Label
$retentionLabel.Text = '旧日志项保留：'
$retentionLabel.AutoSize = $true
$retentionLabel.Margin = New-Object Windows.Forms.Padding(24, 8, 0, 0)
$toolbar.Controls.Add($retentionLabel)
$retentionBox = New-Object Windows.Forms.ComboBox
$retentionBox.DropDownStyle = 'DropDownList'
$retentionBox.Width = 80
$retentionBox.Margin = New-Object Windows.Forms.Padding(2, 4, 10, 0)
[void]$retentionBox.Items.Add('7 天')
[void]$retentionBox.Items.Add('30 天')
$retentionBox.SelectedIndex = if ($PresetLogKeepDays -eq 30) { 1 } else { 0 }
$toolbar.Controls.Add($retentionBox)
$filterBox = New-Object Windows.Forms.ComboBox
$filterBox.DropDownStyle = 'DropDownList'
$filterBox.Width = 120
$filterBox.Margin = New-Object Windows.Forms.Padding(10, 4, 0, 0)
$filterBox.Items.AddRange(@('全部项目', '清理项目', '手动管理'))
$filterBox.SelectedIndex = 0
$toolbar.Controls.Add($filterBox)

$grid = New-Object Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false
$grid.MultiSelect = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.AutoSizeRowsMode = 'AllCells'
$grid.BackgroundColor = [Drawing.Color]::White
$grid.BorderStyle = 'Fixed3D'
$grid.EditMode = 'EditOnEnter'
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(230, 236, 244)
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Bold)
$grid.ColumnHeadersHeight = 32
$grid.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(218, 234, 250)
$grid.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::Black
$cleanLayout.Controls.Add($grid, 0, 1)

$selectColumn = New-Object Windows.Forms.DataGridViewCheckBoxColumn
$selectColumn.Name = 'Selected'
$selectColumn.HeaderText = '选择'
$selectColumn.Width = 55
[void]$grid.Columns.Add($selectColumn)

$nameColumn = New-Object Windows.Forms.DataGridViewTextBoxColumn
$nameColumn.Name = 'ItemName'
$nameColumn.HeaderText = '项目'
$nameColumn.Width = 195
$nameColumn.ReadOnly = $true
[void]$grid.Columns.Add($nameColumn)

$sizeColumn = New-Object Windows.Forms.DataGridViewTextBoxColumn
$sizeColumn.Name = 'Estimated'
$sizeColumn.HeaderText = '预计可释放'
$sizeColumn.Width = 105
$sizeColumn.ReadOnly = $true
$sizeColumn.SortMode = 'Automatic'
$sizeColumn.DefaultCellStyle.Alignment = 'MiddleRight'
[void]$grid.Columns.Add($sizeColumn)

$riskColumn = New-Object Windows.Forms.DataGridViewTextBoxColumn
$riskColumn.Name = 'Risk'
$riskColumn.HeaderText = '风险'
$riskColumn.Width = 62
$riskColumn.ReadOnly = $true
$riskColumn.DefaultCellStyle.Alignment = 'MiddleCenter'
[void]$grid.Columns.Add($riskColumn)

$adminColumn = New-Object Windows.Forms.DataGridViewTextBoxColumn
$adminColumn.Name = 'Admin'
$adminColumn.HeaderText = '管理员'
$adminColumn.Width = 72
$adminColumn.ReadOnly = $true
$adminColumn.DefaultCellStyle.Alignment = 'MiddleCenter'
[void]$grid.Columns.Add($adminColumn)

$statusColumn = New-Object Windows.Forms.DataGridViewTextBoxColumn
$statusColumn.Name = 'Status'
$statusColumn.HeaderText = '状态'
$statusColumn.Width = 140
$statusColumn.ReadOnly = $true
[void]$grid.Columns.Add($statusColumn)

$descriptionColumn = New-Object Windows.Forms.DataGridViewTextBoxColumn
$descriptionColumn.Name = 'Description'
$descriptionColumn.HeaderText = '说明'
$descriptionColumn.AutoSizeMode = 'Fill'
$descriptionColumn.MinimumWidth = 220
$descriptionColumn.ReadOnly = $true
$descriptionColumn.DefaultCellStyle.WrapMode = 'True'
[void]$grid.Columns.Add($descriptionColumn)
$detailsColumn = New-Object Windows.Forms.DataGridViewButtonColumn
$detailsColumn.Name = 'Details'
$detailsColumn.HeaderText = '查看 / 管理'
$detailsColumn.Width = 98
$detailsColumn.ReadOnly = $true
[void]$grid.Columns.Add($detailsColumn)

$logGroup = New-Object Windows.Forms.GroupBox
$logGroup.Text = '扫描与清理日志'
$logGroup.Dock = 'Fill'
$logGroup.Padding = New-Object Windows.Forms.Padding(9)
$cleanLayout.Controls.Add($logGroup, 0, 2)

$logBox = New-Object Windows.Forms.TextBox
$logBox.Dock = 'Fill'
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.BackColor = [Drawing.Color]::FromArgb(250, 250, 250)
$logBox.Font = New-Object Drawing.Font('Consolas', 9)
$logGroup.Controls.Add($logBox)
$script:LogBox = $logBox

$statusStrip = New-Object Windows.Forms.StatusStrip
$statusStrip.Dock = 'Fill'
$statusLabel = New-Object Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = '就绪'
$statusLabel.Spring = $true
$statusLabel.TextAlign = 'MiddleLeft'
$statusLabel.AutoToolTip = $true
$progress = New-Object Windows.Forms.ToolStripProgressBar
$progress.Width = 220
$progress.Minimum = 0
$progress.Maximum = [Math]::Max(1, $script:Items.Count)
[void]$statusStrip.Items.Add($statusLabel)
[void]$statusStrip.Items.Add($progress)
$layout.Controls.Add($statusStrip, 0, 2)

$presetIds = @{}
if (-not [string]::IsNullOrWhiteSpace($PresetSelection)) {
    foreach ($id in $PresetSelection.Split(',')) {
        if (-not [string]::IsNullOrWhiteSpace($id)) { $presetIds[$id.Trim()] = $true }
    }
}

foreach ($item in $script:Items) {
    $rowIndex = $grid.Rows.Add($false, $item.Name, '未扫描', $item.Risk, $(if ($item.RequiresAdmin) { '是' } else { '否' }), '未扫描', $item.Description, $(if ($item.Action -eq 'Manage') { '打开管理' } else { '查看路径' }))
    $row = $grid.Rows[$rowIndex]
    $row.Tag = $item
    $script:RowsById[$item.Id] = $row
}

function Get-SelectedRows {
    [void]$grid.EndEdit()
    $rows = @()
    foreach ($row in $grid.Rows) {
        if ($row.Cells['Selected'].Value -eq $true -and $row.Tag.Action -ne 'Manage') { $rows += $row }
    }
    return $rows
}

function Update-Summary {
    try {
        $driveInfo = $script:DriveInfo
        if ($null -eq $driveInfo) { return }
        $goalBytes = [Int64]([decimal]$goalBox.Value * 1GB)
        $needed = [Math]::Max([Int64]0, $goalBytes - $driveInfo.Free)
        if ($needed -eq 0) {
            $diskLabel.Text = 'C 盘：可用 {0} / 总计 {1}　✓ 已达到 {2} GB 目标' -f (Format-ByteSize $driveInfo.Free), (Format-ByteSize $driveInfo.Size), $goalBox.Value
            $diskLabel.ForeColor = [Drawing.Color]::FromArgb(20, 125, 65)
        }
        else {
            $diskLabel.Text = 'C 盘：可用 {0} / 总计 {1}　距 {2} GB 目标还差 {3}' -f (Format-ByteSize $driveInfo.Free), (Format-ByteSize $driveInfo.Size), $goalBox.Value, (Format-ByteSize $needed)
            $diskLabel.ForeColor = [Drawing.Color]::FromArgb(180, 75, 30)
        }

        [Int64]$selectedBytes = 0
        foreach ($row in @(Get-SelectedRows)) {
            $selectedBytes += [Int64]$row.Tag.EstimatedBytes
        }
        $projected = [Math]::Min($driveInfo.Size, $driveInfo.Free + $selectedBytes)
        $selectedLabel.Text = '已选预计：{0}　预计清理后：{1}' -f (Format-ByteSize $selectedBytes), (Format-ByteSize $projected)
    }
    catch {
        $diskLabel.Text = '无法读取 C 盘空间：' + $_.Exception.Message
        $diskLabel.ForeColor = [Drawing.Color]::Firebrick
    }
}

function Set-BusyState {
    param([bool]$Busy, [string]$Text)
    $script:Busy = $Busy
    $scanButton.Enabled = -not $Busy
    $safeButton.Enabled = -not $Busy
    $noneButton.Enabled = -not $Busy
    $cleanButton.Enabled = -not $Busy
    $adminButton.Enabled = (-not $Busy) -and (-not $script:IsAdministrator)
    $goalBox.Enabled = -not $Busy
    $stopAtGoalCheck.Enabled = -not $Busy
    $retentionBox.Enabled = -not $Busy
    foreach ($row in $grid.Rows) {
        $row.Cells['Selected'].ReadOnly = $Busy -or $row.Tag.Action -eq 'Manage' -or $row.Tag.InUse -or $row.Tag.IdentityBlocked -or ($row.Tag.EstimatedBytes -le 0)
    }
    $cancelButton.Enabled = $Busy
    $statusLabel.Text = $Text
    $form.UseWaitCursor = $false
    if ($Busy) { $progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 35 }
    else { $progress.Style = 'Blocks'; $progress.Value = 0 }
}

function Start-UiWork {
    param([string]$Mode, [object[]]$Items, [bool]$ApplyDefaults = $false)
    if ($script:Busy) { return }
    $request = @{
        Mode = $Mode; ItemsXml = [Management.Automation.PSSerializer]::Serialize(@($Items), 10)
        GoalBytes = [Int64]([decimal]$goalBox.Value * 1GB); StopAtGoal = $stopAtGoalCheck.Checked
        LogKeepDays = $script:LogKeepDays
    }
    Set-BusyState -Busy $true -Text '正在启动后台任务…'
    try {
        $script:ApplyScanDefaults = $ApplyDefaults
        $script:WorkMode = $Mode
        $script:WorkClock = [Diagnostics.Stopwatch]::StartNew()
        $script:Worker = New-CleanupWorker -Request $request
        foreach ($item in $Items) {
            $row = $script:RowsById[$item.Id]
            $row.Cells['Status'].Value = if ($Mode -eq 'Scan') { '等待扫描' } else { '等待清理' }
        }
        Write-AppLog $(if ($Mode -eq 'Scan') { '开始后台只读扫描，可随时停止。' } else { '开始后台清理；停止会保留已经完成的删除。' })
        $workerTimer.Start()
    }
    catch {
        Set-BusyState -Busy $false -Text '后台任务启动失败'
        Write-AppLog ('启动失败：' + $_.Exception.Message)
    }
}

function Invoke-CatalogScan {
    param([bool]$ApplyDefaults)
    Start-UiWork -Mode 'Scan' -Items $script:Items -ApplyDefaults $ApplyDefaults
}

function Request-WorkCancellation {
    if ($null -eq $script:Worker) { return }
    $script:Worker.Cancellation.Cancel()
    $cancelButton.Enabled = $false
    $statusLabel.Text = '正在停止，等待当前文件或系统操作返回…'
}

function Receive-WorkerMessages {
    $message = $null
    $count = 0
    while ($count -lt 100 -and $script:Worker.State.Messages.TryDequeue([ref]$message)) {
        $count++
        switch ($message.Kind) {
            'Log' { Write-AppLog $message.Text }
            'Start' { $script:RowsById[$message.Id].Cells['Status'].Value = $message.Status }
            'Scanned' {
                $result = $message.Item
                $row = $script:RowsById[$result.Id]
                $item = $row.Tag
                $item.EstimatedBytes = $result.EstimatedBytes
                $item.ScanStatus = $result.ScanStatus
                $item.InUse = $result.InUse
                $item | Add-Member -MemberType NoteProperty -Name ScanIssues -Value (Get-ItemOption $result 'ScanIssues' 0) -Force
                $row.Cells['Estimated'].Value = if ($item.Action -eq 'Manage') { '仅管理' } elseif ($result.ScanStatus -in @('扫描失败', '需管理员扫描', '账户不一致，已禁用')) { '未知' } else { Format-ByteSize $item.EstimatedBytes }
                $row.Cells['Status'].Value = $item.ScanStatus
                $blocked = $item.Action -eq 'Manage' -or $item.InUse -or $item.IdentityBlocked -or ($item.EstimatedBytes -le 0)
                $row.Cells['Selected'].ReadOnly = $script:Busy -or $blocked
                $row.DefaultCellStyle.BackColor = if ($blocked) { [Drawing.Color]::FromArgb(245, 245, 245) } else { [Drawing.Color]::White }
                if ($blocked) { $row.Cells['Selected'].Value = $false }
                elseif ($script:ApplyScanDefaults) {
                    $row.Cells['Selected'].Value = if ($presetIds.Count -gt 0) { $presetIds.ContainsKey($item.Id) } else { $item.DefaultSelected -and (-not $item.RequiresAdmin) }
                }
            }
            'Cleaned' {
                $row = $script:RowsById[$message.Id]
                $row.Cells['Status'].Value = $message.Status
                if ($message.Status -ne '达到目标，未执行') {
                    $row.Tag.EstimatedBytes = 0
                    $row.Cells['Estimated'].Value = '待重新扫描'
                    $row.Cells['Selected'].Value = $false
                    $row.Cells['Selected'].ReadOnly = $true
                }
                Write-AppLog $message.Text
            }
        }
    }
}

function Update-BackgroundWork {
    if ($null -eq $script:Worker) { return }
    Receive-WorkerMessages
    $state = $script:Worker.State
    if ($null -ne $state.DriveInfo) { $script:DriveInfo = $state.DriveInfo }
    $seconds = [int]$script:WorkClock.Elapsed.TotalSeconds
    $prefix = if ($script:Worker.Cancellation.IsCancellationRequested) { '正在停止，等待当前操作返回' } else { '正在' + $state.Phase }
    $statusLabel.Text = '{0}：{1} | {2}/{3} 项 | {4} 秒' -f $prefix, $state.CurrentName, $state.Completed, $state.Total, $seconds
    if ($script:WorkMode -eq 'Clean') { $statusLabel.Text += ' | 已删 {0}，失败 {1}，跳过 {2}' -f $state.Deleted, $state.Failed, $state.Skipped }
    $statusLabel.ToolTipText = $state.CurrentPath
    $logGroup.Text = '扫描与清理日志 — ' + $state.CurrentPath
    Update-Summary
    if (-not $script:Worker.Handle.IsCompleted) { return }

    $workerTimer.Stop()
    $outcome = $state.Outcome
    $pipelineError = ''
    try {
        [void]$script:Worker.Shell.EndInvoke($script:Worker.Handle)
        if ($script:Worker.Shell.Streams.Error.Count -gt 0) { $pipelineError = [string]$script:Worker.Shell.Streams.Error[0] }
        Receive-WorkerMessages
    }
    catch { $pipelineError = $_.Exception.Message }
    finally {
        $script:Worker.Shell.Dispose()
        $script:Worker.Runspace.Dispose()
        $script:Worker.Cancellation.Dispose()
        $script:Worker = $null
    }
    if ($null -eq $outcome) {
        $outcome = [pscustomobject]@{ Mode = $script:WorkMode; Cancelled = $false; Error = ('后台任务异常退出。' + $pipelineError); Released = 0; GoalReached = $false }
    }
    elseif ($pipelineError) { $outcome.Error = $pipelineError }
    foreach ($row in $grid.Rows) {
        if ($row.Cells['Status'].Value -in @('扫描中', '等待扫描', '清理中', '等待清理')) {
            $row.Cells['Status'].Value = if ($outcome.GoalReached) { '达到目标，未执行' } else { '已停止，需重扫' }
            $row.Cells['Selected'].Value = $false
            $row.Cells['Selected'].ReadOnly = $true
            $row.Tag.EstimatedBytes = 0
            $row.Cells['Estimated'].Value = '待重新扫描'
        }
    }
    $text = if ($outcome.Cancelled) { '已停止' } elseif ($outcome.Error) { '操作异常结束' } else { $state.Phase + '结束' }
    if ($outcome.Mode -eq 'Clean') { $text += '，本轮可用空间增加 ' + (Format-ByteSize $outcome.Released) }
    Set-BusyState -Busy $false -Text $text
    $logGroup.Text = '扫描与清理日志'
    Write-AppLog $text
    if ($outcome.Error) { Write-AppLog $outcome.Error }
    if ($outcome.Cancelled -and $outcome.Mode -eq 'Clean') { Write-AppLog '已完成的删除仍然有效。需要继续清理时，请先重新扫描。' }
    Update-Summary
    if ($grid.SortedColumn -eq $sizeColumn -and $grid.SortOrder -ne [Windows.Forms.SortOrder]::None) {
        $direction = if ($grid.SortOrder -eq [Windows.Forms.SortOrder]::Descending) { [ComponentModel.ListSortDirection]::Descending } else { [ComponentModel.ListSortDirection]::Ascending }
        $grid.Sort($sizeColumn, $direction)
    }
    if ($script:CloseWhenIdle) { $form.Close(); return }
    if ($outcome.Mode -eq 'Clean' -and (-not $outcome.Cancelled)) {
        Invoke-CatalogScan -ApplyDefaults $false
    }
}

function Restart-AsAdministrator {
    $selectedIds = @()
    foreach ($row in @(Get-SelectedRows)) { $selectedIds += $row.Tag.Id }
    $selectionArg = $selectedIds -join ','
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $script:ScriptPath
    if (-not [string]::IsNullOrWhiteSpace($selectionArg)) {
        $arguments += ' -PresetSelection "{0}"' -f $selectionArg
    }
    $arguments += ' -PresetGoalGB {0}' -f [int]$goalBox.Value
    $arguments += ' -PresetStopAtGoal "{0}"' -f $stopAtGoalCheck.Checked.ToString().ToLowerInvariant()
    $arguments += ' -PresetLogKeepDays {0}' -f $script:LogKeepDays
    $arguments += ' -OriginalSid "{0}"' -f $script:CurrentSid

    try {
        Start-Process -FilePath $powershell -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments | Out-Null
        $form.Close()
    }
    catch {
        [Windows.Forms.MessageBox]::Show('未能以管理员身份重启：' + $_.Exception.Message, 'C 盘清理助手', 'OK', 'Error') | Out-Null
    }
}

function Invoke-SelectedCleanup {
    $riskOrder = @{ '低' = 0; '中' = 1; '高' = 2 }
    $selectedRows = @(Get-SelectedRows | Sort-Object @{ Expression = { $riskOrder[$_.Tag.Risk] } })
    if ($selectedRows.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show('请先勾选至少一个有内容的项目。', 'C 盘清理助手', 'OK', 'Information') | Out-Null
        return
    }

    $needsAdmin = @($selectedRows | Where-Object { $_.Tag.RequiresAdmin }).Count -gt 0
    if ($needsAdmin -and (-not $script:IsAdministrator)) {
        $answer = [Windows.Forms.MessageBox]::Show('所选项目中包含需要管理员权限的项目。是否保留当前选择并以管理员身份重启？', '需要管理员权限', 'YesNo', 'Question')
        if ($answer -eq [Windows.Forms.DialogResult]::Yes) { Restart-AsAdministrator }
        return
    }

    $highRisk = @($selectedRows | Where-Object { $_.Tag.Risk -eq '高' }).Count -gt 0
    if ($highRisk) {
        $answer = [Windows.Forms.MessageBox]::Show('所选项目包含高风险操作。关闭休眠会同时影响快速启动及其他依赖休眠文件的功能。请确认你已阅读说明。继续吗？', '高风险操作确认', 'YesNo', 'Warning')
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    }

    [Int64]$estimated = 0
    $nameLines = @()
    foreach ($row in $selectedRows) {
        $estimated += [Int64]$row.Tag.EstimatedBytes
        $nameLines += '• ' + $row.Tag.Name
    }
    $message = "所有旧运行日志项目保留最近 $script:LogKeepDays 天；Windows 安装监控日志保留至少 30 天。`r`n`r`n将清理以下项目：`r`n`r`n" + ($nameLines -join "`r`n") + "`r`n`r`n预计释放（存储大小估算）：" + (Format-ByteSize $estimated) + "`r`n实际结果可能因占用、共享文件和应用重新写入而不同。删除的缓存无法直接撤销，是否继续？"
    $confirm = [Windows.Forms.MessageBox]::Show($message, '确认清理', 'YesNo', 'Warning')
    if ($confirm -ne [Windows.Forms.DialogResult]::Yes) { return }

    Start-UiWork -Mode 'Clean' -Items @($selectedRows | ForEach-Object { $_.Tag })
}

$workerTimer = New-Object Windows.Forms.Timer
$workerTimer.Interval = 150
$workerTimer.Add_Tick({
    try { Update-BackgroundWork }
    catch {
        Write-AppLog ('界面刷新失败：' + $_.Exception.Message)
        Request-WorkCancellation
    }
})
$cancelButton.Add_Click({ Request-WorkCancellation })

$grid.Add_CurrentCellDirtyStateChanged({
    if ($grid.IsCurrentCellDirty) { $grid.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
})
$grid.Add_CellValueChanged({
    param($sender, $eventArgs)
    if (-not $script:Busy -and $eventArgs.RowIndex -ge 0 -and $eventArgs.ColumnIndex -eq $grid.Columns['Selected'].Index) { Update-Summary }
})

$grid.Add_SortCompare({
    param($sender, $eventArgs)
    if ($eventArgs.Column.Name -ne 'Estimated') { return }
    $left = $sender.Rows[$eventArgs.RowIndex1].Tag
    $right = $sender.Rows[$eventArgs.RowIndex2].Tag
    $missingValues = @('', '未扫描', '未知', '待重新扫描', '仅管理')
    $leftMissing = $left.Action -eq 'Manage' -or ([string]$eventArgs.CellValue1 -in $missingValues)
    $rightMissing = $right.Action -eq 'Manage' -or ([string]$eventArgs.CellValue2 -in $missingValues)
    if ($leftMissing -ne $rightMissing) {
        $comparison = if ($leftMissing) { 1 } else { -1 }
        # DataGridView reverses the comparator for descending order; keep unavailable sizes last.
        if ($sender.SortOrder -eq [Windows.Forms.SortOrder]::Descending) { $comparison = -$comparison }
    }
    else {
        $comparison = if ($leftMissing) { 0 } else { ([Int64]$left.EstimatedBytes).CompareTo([Int64]$right.EstimatedBytes) }
        if ($comparison -eq 0) { $comparison = [StringComparer]::Ordinal.Compare([string]$left.Id, [string]$right.Id) }
    }
    $eventArgs.SortResult = $comparison
    $eventArgs.Handled = $true
})

$grid.Add_CellFormatting({
    param($sender, $eventArgs)
    if ($eventArgs.RowIndex -lt 0) { return }
    $row = $grid.Rows[$eventArgs.RowIndex]
    $risk = [string]$row.Cells['Risk'].Value
    if ($risk -eq '低') { $row.Cells['Risk'].Style.ForeColor = [Drawing.Color]::FromArgb(20, 125, 65) }
    elseif ($risk -eq '中') { $row.Cells['Risk'].Style.ForeColor = [Drawing.Color]::FromArgb(190, 105, 0) }
    elseif ($risk -eq '高') { $row.Cells['Risk'].Style.ForeColor = [Drawing.Color]::Firebrick }
})

$scanButton.Add_Click({ if (-not $script:Busy) { Invoke-CatalogScan -ApplyDefaults $false } })
$safeButton.Add_Click({
    foreach ($row in $grid.Rows) {
        $item = $row.Tag
        $row.Cells['Selected'].Value = ($item.Action -ne 'Manage') -and ($item.Risk -eq '低') -and (-not $item.RequiresAdmin) -and ($item.EstimatedBytes -gt 0) -and (-not $item.InUse) -and (-not $item.IdentityBlocked)
    }
    Update-Summary
})
$noneButton.Add_Click({
    foreach ($row in $grid.Rows) { $row.Cells['Selected'].Value = $false }
    Update-Summary
})
$cleanButton.Add_Click({ if (-not $script:Busy) { Invoke-SelectedCleanup } })
$adminButton.Add_Click({ if (-not $script:IsAdministrator) { Restart-AsAdministrator } })
$goalBox.Add_ValueChanged({ Update-Summary })


function Get-ItemManagementTargets {
    param($Item)
    if ($Item.IdentityBlocked) { throw '当前管理员与原账户不同，无法打开原账户的数据目录。' }
    $result = New-Object System.Collections.ArrayList
    foreach ($spec in @($Item.PathSpecs)) {
        if ($null -eq $spec -or (-not (Test-IsPathBelowRoot -Path $spec.Path -AllowedRoot $spec.AllowedRoot))) { continue }
        [void]$result.Add([IO.Path]::GetFullPath($spec.Path))
    }
    return @($result | Select-Object -Unique)
}

function Show-ItemDetails {
    param($Item)
    try { $paths = @(Get-ItemManagementTargets $Item) }
    catch { Write-AppLog $_.Exception.Message; return }
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = $Item.Name
    $dialog.Size = New-Object Drawing.Size(850, 420)
    $dialog.MinimumSize = New-Object Drawing.Size(700, 360)
    $dialog.StartPosition = 'CenterParent'
    $dialog.Font = $form.Font
    $panel = New-Object Windows.Forms.TableLayoutPanel
    $panel.Dock = 'Fill'
    $panel.Padding = New-Object Windows.Forms.Padding(12)
    $panel.RowCount = 3
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 100)))
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 44)))
    $dialog.Controls.Add($panel)
    $description = New-Object Windows.Forms.Label
    $description.Dock = 'Fill'
    $description.Text = $Item.Description
    if ($Item.Action -ne 'Manage') {
        $policy = Get-CleanupPolicy $Item
        $description.Text += [Environment]::NewLine + ('保留天数：{0}；文件类型：{1}' -f $policy.MinAgeDays, ($policy.FilePatterns -join '、'))
    }
    else { $description.Text += [Environment]::NewLine + '此项由你在文件夹、系统设置或对应应用中管理。' }
    $panel.Controls.Add($description, 0, 0)
    $pathList = New-Object Windows.Forms.ListBox
    $pathList.Dock = 'Fill'
    $pathList.HorizontalScrollbar = $true
    foreach ($path in $paths) { [void]$pathList.Items.Add($path) }
    if ($pathList.Items.Count -gt 0) { $pathList.SelectedIndex = 0 }
    $panel.Controls.Add($pathList, 0, 1)
    $actions = New-Object Windows.Forms.FlowLayoutPanel
    $actions.Dock = 'Fill'
    $panel.Controls.Add($actions, 0, 2)
    $openFolder = New-ToolbarButton -Text '打开选中目录' -Width 130
    $openFolder.Enabled = $pathList.Items.Count -gt 0
    $openFolder.Add_Click({
        try {
            $path = [string]$pathList.SelectedItem
            Assert-NoReparsePointInPathChain -Path $path
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw '当前电脑没有此目录，或目录已被清理。' }
            Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"{0}"' -f $path) | Out-Null
        }
        catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法打开目录', 'OK', 'Information') }
    })
    $actions.Controls.Add($openFolder)
    $uri = [string](Get-ItemOption $Item 'ManageUri' '')
    if ($uri -in @('ms-settings:storagesense', 'ms-settings:appsfeatures', 'ms-settings:storagepolicies')) {
        $openSettings = New-ToolbarButton -Text '打开系统管理' -Width 130
        $openSettings.Add_Click({ Start-Process -FilePath $uri | Out-Null })
        $actions.Controls.Add($openSettings)
    }
    try { [void]$dialog.ShowDialog($form) }
    finally { $dialog.Dispose() }
}

$grid.Add_CellContentClick({
    param($sender, $eventArgs)
    if ($eventArgs.RowIndex -ge 0 -and $eventArgs.ColumnIndex -eq $grid.Columns['Details'].Index -and (-not $script:Busy)) {
        Show-ItemDetails $grid.Rows[$eventArgs.RowIndex].Tag
    }
})
$filterBox.Add_SelectedIndexChanged({
    $grid.CurrentCell = $null
    foreach ($row in $grid.Rows) {
        $row.Visible = ($filterBox.SelectedIndex -eq 0) -or ($filterBox.SelectedIndex -eq 1 -and $row.Tag.Action -ne 'Manage') -or ($filterBox.SelectedIndex -eq 2 -and $row.Tag.Action -eq 'Manage')
    }
})
$retentionBox.Add_SelectedIndexChanged({
    if ($script:Busy) { return }
    $script:LogKeepDays = if ($retentionBox.SelectedIndex -eq 1) { 30 } else { 7 }
    foreach ($row in $grid.Rows) {
        if (Get-ItemOption $row.Tag 'UseLogRetention' $false) {
            $row.Tag.EstimatedBytes = 0
            $row.Cells['Selected'].Value = $false
            $row.Cells['Selected'].ReadOnly = $true
        }
    }
    Invoke-CatalogScan -ApplyDefaults $false
})


# ---- 空间分析页：类似 WizTree 的整盘结构、最大文件、小文件密集目录与删除建议 ----

$script:Analyzer = $null
$script:AnalysisResult = $null
$script:AnalysisFocus = 'List'

$analysisLayout = New-Object Windows.Forms.TableLayoutPanel
$analysisLayout.Dock = 'Fill'
$analysisLayout.ColumnCount = 1
$analysisLayout.RowCount = 2
[void]$analysisLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 46)))
[void]$analysisLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
$analysisTab.Controls.Add($analysisLayout)

$analysisBar = New-Object Windows.Forms.FlowLayoutPanel
$analysisBar.Dock = 'Fill'
$analysisBar.Padding = New-Object Windows.Forms.Padding(8, 6, 8, 2)
$analysisBar.WrapContents = $false
$analysisLayout.Controls.Add($analysisBar, 0, 0)

$analysisRootLabel = New-Object Windows.Forms.Label
$analysisRootLabel.Text = '分析位置：'
$analysisRootLabel.AutoSize = $true
$analysisRootLabel.Margin = New-Object Windows.Forms.Padding(0, 9, 0, 0)
$analysisRootBox = New-Object Windows.Forms.TextBox
$analysisRootBox.Text = 'C:\'
$analysisRootBox.Width = 230
$analysisRootBox.Margin = New-Object Windows.Forms.Padding(2, 6, 4, 0)
$analysisBrowseButton = New-ToolbarButton -Text '选择文件夹…' -Width 105
$analysisStartButton = New-ToolbarButton -Text '开始分析' -Width 100
$analysisStopButton = New-ToolbarButton -Text '停止' -Width 70
$analysisStopButton.Enabled = $false
$analysisInfo = New-Object Windows.Forms.Label
$analysisInfo.AutoSize = $true
$analysisInfo.Margin = New-Object Windows.Forms.Padding(12, 9, 0, 0)
$analysisInfo.Text = if ($script:IsAdministrator) { '管理员模式：分析整个分区时直接读取 NTFS 主文件表（MFT），速度最快。' } else { '普通模式：使用多线程目录枚举；以管理员身份重启后可直接读取 MFT，速度更快。' }
$analysisBar.Controls.AddRange(@($analysisRootLabel, $analysisRootBox, $analysisBrowseButton, $analysisStartButton, $analysisStopButton, $analysisInfo))

$analysisSplit = New-Object Windows.Forms.SplitContainer
$analysisSplit.Dock = 'Fill'
$analysisSplit.Orientation = 'Vertical'
$analysisSplit.SplitterDistance = 440
$analysisLayout.Controls.Add($analysisSplit, 0, 1)

$dirTree = New-Object Windows.Forms.TreeView
$dirTree.Dock = 'Fill'
$dirTree.HideSelection = $false
$dirTree.ShowNodeToolTips = $true
$dirTree.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$analysisSplit.Panel1.Controls.Add($dirTree)

$analysisRight = New-Object Windows.Forms.TableLayoutPanel
$analysisRight.Dock = 'Fill'
$analysisRight.ColumnCount = 1
$analysisRight.RowCount = 3
[void]$analysisRight.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$analysisRight.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 54)))
[void]$analysisRight.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 42)))
$analysisSplit.Panel2.Controls.Add($analysisRight)

$analysisTabs = New-Object Windows.Forms.TabControl
$analysisTabs.Dock = 'Fill'
$analysisRight.Controls.Add($analysisTabs, 0, 0)

$analysisAdvice = New-Object Windows.Forms.Label
$analysisAdvice.Dock = 'Fill'
$analysisAdvice.Padding = New-Object Windows.Forms.Padding(4, 4, 4, 0)
$analysisAdvice.AutoEllipsis = $true
$analysisAdvice.Text = '分析只读取文件信息，不修改任何文件。选中一行可查看建议；删除操作只会移到回收站，并在执行前再次确认。'
$analysisRight.Controls.Add($analysisAdvice, 0, 1)

$analysisActions = New-Object Windows.Forms.FlowLayoutPanel
$analysisActions.Dock = 'Fill'
$analysisRight.Controls.Add($analysisActions, 0, 2)
$openLocationButton = New-ToolbarButton -Text '打开所在位置' -Width 118
$copyPathButton = New-ToolbarButton -Text '复制路径' -Width 90
$recycleButton = New-ToolbarButton -Text '移到回收站…' -Width 110
$gotoItemButton = New-ToolbarButton -Text '转到清理项目' -Width 118
$exportButton = New-ToolbarButton -Text '导出报告…' -Width 100
$analysisActions.Controls.AddRange(@($openLocationButton, $copyPathButton, $recycleButton, $gotoItemButton, $exportButton))

function New-AnalysisList {
    param([string]$Title, [object[]]$Columns, [string]$Kind)
    $page = New-Object Windows.Forms.TabPage
    $page.Text = $Title
    $list = New-Object Windows.Forms.ListView
    $list.Dock = 'Fill'
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.HideSelection = $false
    $list.MultiSelect = $false
    $list.GridLines = $true
    foreach ($column in $Columns) {
        $header = $list.Columns.Add([string]$column[0], [int]$column[1])
        if ($column.Count -gt 2 -and $column[2] -eq 'Right') { $header.TextAlign = 'Right' }
    }
    $list.Tag = @{ Kind = $Kind; Data = @(); Keys = @($Columns | ForEach-Object { $_[3] }); SortColumn = -1; Descending = $true }
    $page.Controls.Add($list)
    [void]$analysisTabs.TabPages.Add($page)
    return $list
}

$suggestionList = New-AnalysisList -Title '删除建议' -Kind 'Suggestion' -Columns @(
    @('大小', 90, 'Right', { $_.Bytes }), @('风险', 50, 'Left', { $_.Risk }), @('类别', 190, 'Left', { $_.Category }), @('路径', 420, 'Left', { $_.Path }))
$largeFileList = New-AnalysisList -Title '最大文件' -Kind 'File' -Columns @(
    @('大小', 90, 'Right', { $_.Logical }), @('占用', 90, 'Right', { $_.Alloc }), @('修改时间', 130, 'Left', { $_.LastWriteUtc }), @('路径', 460, 'Left', { $_.Path }))
$denseList = New-AnalysisList -Title '大量小文件' -Kind 'Dense' -Columns @(
    @('文件数', 90, 'Right', { $_.Files }), @('占用', 90, 'Right', { $_.Alloc }), @('平均大小', 90, 'Right', { $_.AverageBytes }), @('路径', 480, 'Left', { $_.Path }))
$extensionList = New-AnalysisList -Title '文件类型' -Kind 'Extension' -Columns @(
    @('扩展名', 110, 'Left', { $_.Extension }), @('文件数', 100, 'Right', { $_.Count }), @('占用', 110, 'Right', { $_.Alloc }), @('大小', 110, 'Right', { $_.Logical }))
$script:AnalysisLists = @($suggestionList, $largeFileList, $denseList, $extensionList)

function Get-AnalysisRowTexts {
    param([string]$Kind, $Data)
    switch ($Kind) {
        'Suggestion' { return @((Format-ByteSize $Data.Bytes), $Data.Risk, $Data.Category, $Data.Path) }
        'File' {
            $time = if ($Data.LastWriteUtc -gt [datetime]'1980-01-01') { $Data.LastWriteUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '' }
            return @((Format-ByteSize $Data.Logical), (Format-ByteSize $Data.Alloc), $time, $Data.Path)
        }
        'Dense' { return @(('{0:N0}' -f $Data.Files), (Format-ByteSize $Data.Alloc), (Format-ByteSize $Data.AverageBytes), $Data.Path) }
        'Extension' {
            $name = if ([string]::IsNullOrEmpty($Data.Extension)) { '（无扩展名）' } else { '.' + $Data.Extension }
            return @($name, ('{0:N0}' -f $Data.Count), (Format-ByteSize $Data.Alloc), (Format-ByteSize $Data.Logical))
        }
    }
}

function Set-AnalysisListData {
    param([Windows.Forms.ListView]$List, [object[]]$Data)
    $state = $List.Tag
    $state.Data = @($Data)
    $List.BeginUpdate()
    try {
        $List.Items.Clear()
        $rows = New-Object System.Collections.Generic.List[Windows.Forms.ListViewItem]
        foreach ($entry in $state.Data) {
            $texts = @(Get-AnalysisRowTexts -Kind $state.Kind -Data $entry)
            $row = New-Object Windows.Forms.ListViewItem([string]$texts[0])
            for ($i = 1; $i -lt $texts.Count; $i++) { [void]$row.SubItems.Add([string]$texts[$i]) }
            $row.Tag = $entry
            if ($state.Kind -eq 'Suggestion') {
                if ($entry.Risk -eq '高') { $row.ForeColor = [Drawing.Color]::Firebrick }
                elseif ($entry.Risk -eq '低') { $row.ForeColor = [Drawing.Color]::FromArgb(20, 125, 65) }
            }
            $rows.Add($row)
        }
        $List.Items.AddRange($rows.ToArray())
    }
    finally { $List.EndUpdate() }
}

function Sort-AnalysisList {
    param([Windows.Forms.ListView]$List, [int]$Column)
    # Sorts the underlying values (bytes, counts, dates), not the formatted text.
    $state = $List.Tag
    if ($state.SortColumn -eq $Column) { $state.Descending = -not $state.Descending }
    else { $state.SortColumn = $Column; $state.Descending = $true }
    $key = $state.Keys[$Column]
    $sorted = @($state.Data | Sort-Object -Property @{ Expression = $key; Descending = $state.Descending })
    Set-AnalysisListData -List $List -Data $sorted
}

foreach ($analysisList in $script:AnalysisLists) {
    $analysisList.Add_ColumnClick({ param($sender, $eventArgs) Sort-AnalysisList -List $sender -Column $eventArgs.Column })
    $analysisList.Add_SelectedIndexChanged({ $script:AnalysisFocus = 'List'; Update-AnalysisSelection })
    $analysisList.Add_DoubleClick({ $script:AnalysisFocus = 'List'; Open-AnalysisLocation })
}

function Get-SelectedAnalysisEntry {
    $page = $analysisTabs.SelectedTab
    if ($null -ne $page -and $page.Controls.Count -gt 0) {
        $list = $page.Controls[0]
        if ($list.SelectedItems.Count -gt 0) {
            $entry = $list.SelectedItems[0].Tag
            if ($list.Tag.Kind -eq 'Extension') { return $null }
            return [pscustomobject]@{ Path = [string]$entry.Path; Entry = $entry; Kind = $list.Tag.Kind; Row = $list.SelectedItems[0] }
        }
    }
    return $null
}

function Get-SelectedTreeEntry {
    $node = $dirTree.SelectedNode
    if ($null -eq $node -or $null -eq $script:AnalysisResult -or $node.Tag -isnot [int]) { return $null }
    return [pscustomobject]@{ Path = $script:AnalysisResult.GetPath([int]$node.Tag); Entry = $null; Kind = 'Tree'; Row = $null; Node = $node }
}

function Update-AnalysisSelection {
    $selected = Get-SelectedAnalysisEntry
    $gotoItemButton.Enabled = $false
    if ($null -eq $selected) { return }
    if ($selected.Kind -eq 'Suggestion') {
        $analysisAdvice.Text = '建议：' + $selected.Entry.Advice
        $gotoItemButton.Enabled = -not [string]::IsNullOrEmpty($selected.Entry.CatalogId) -and $script:RowsById.ContainsKey($selected.Entry.CatalogId)
        $recycleButton.Enabled = $selected.Entry.CanRecycle
    }
    else {
        $analysisAdvice.Text = $selected.Path
        $recycleButton.Enabled = $true
    }
}

function Get-ActiveAnalysisEntry {
    if ($script:AnalysisFocus -eq 'Tree') { return (Get-SelectedTreeEntry) }
    $entry = Get-SelectedAnalysisEntry
    if ($null -ne $entry) { return $entry }
    return (Get-SelectedTreeEntry)
}

function Open-AnalysisLocation {
    $entry = Get-ActiveAnalysisEntry
    if ($null -eq $entry -or [string]::IsNullOrWhiteSpace($entry.Path)) { return }
    $explorer = Join-Path $env:SystemRoot 'explorer.exe'
    if (Test-Path -LiteralPath $entry.Path -PathType Container) { Start-Process -FilePath $explorer -ArgumentList ('"{0}"' -f $entry.Path) | Out-Null }
    elseif (Test-Path -LiteralPath $entry.Path) { Start-Process -FilePath $explorer -ArgumentList ('/select,"{0}"' -f $entry.Path) | Out-Null }
    else { [void][Windows.Forms.MessageBox]::Show('此路径已不存在。', '空间分析', 'OK', 'Information') }
}

function Format-TreeNodeText {
    param($Result, [int]$Index, [Int64]$ParentBytes)
    $node = $Result.Nodes[$Index]
    $percent = if ($ParentBytes -gt 0) { 100.0 * $node.Alloc / $ParentBytes } else { 100.0 }
    $name = if ($Index -eq 0) { $Result.Root } else { $node.Name }
    return ('{0}    {1}  ({2:N1}%)  · {3:N0} 个文件' -f $name, (Format-ByteSize $node.Alloc), $percent, $node.Files)
}

function New-DirectoryTreeNode {
    param($Result, [int]$Index, [Int64]$ParentBytes)
    $treeNode = New-Object Windows.Forms.TreeNode(Format-TreeNodeText -Result $Result -Index $Index -ParentBytes $ParentBytes)
    $treeNode.Tag = $Index
    $treeNode.ToolTipText = $Result.GetPath($Index)
    $node = $Result.Nodes[$Index]
    if (($null -ne $node.Children -and $node.Children.Count -gt 0) -or $node.DirectFiles -gt 0) {
        $placeholder = New-Object Windows.Forms.TreeNode('…')
        $placeholder.Tag = 'placeholder'
        [void]$treeNode.Nodes.Add($placeholder)
    }
    if ($ParentBytes -gt 0 -and $node.Alloc * 5 -ge $ParentBytes) { $treeNode.ForeColor = [Drawing.Color]::FromArgb(170, 60, 20) }
    return $treeNode
}

function Expand-DirectoryTreeNode {
    param([Windows.Forms.TreeNode]$TreeNode)
    $result = $script:AnalysisResult
    if ($null -eq $result -or $TreeNode.Tag -isnot [int]) { return }
    if ($TreeNode.Nodes.Count -ne 1 -or [string]$TreeNode.Nodes[0].Tag -ne 'placeholder') { return }
    $index = [int]$TreeNode.Tag
    $node = $result.Nodes[$index]
    $children = @($result.GetChildren($index))
    $dirTree.BeginUpdate()
    try {
        $TreeNode.Nodes.Clear()
        $shown = [Math]::Min($children.Count, 300)
        for ($i = 0; $i -lt $shown; $i++) { [void]$TreeNode.Nodes.Add((New-DirectoryTreeNode -Result $result -Index $children[$i] -ParentBytes $node.Alloc)) }
        if ($children.Count -gt $shown) {
            [Int64]$rest = 0
            for ($i = $shown; $i -lt $children.Count; $i++) { $rest += $result.Nodes[$children[$i]].Alloc }
            $more = New-Object Windows.Forms.TreeNode(('… 其余 {0:N0} 个文件夹，共 {1}' -f ($children.Count - $shown), (Format-ByteSize $rest)))
            $more.ForeColor = [Drawing.Color]::DimGray
            [void]$TreeNode.Nodes.Add($more)
        }
        if ($node.DirectFiles -gt 0) {
            $files = New-Object Windows.Forms.TreeNode(('〈此文件夹中的文件〉    {0}  · {1:N0} 个文件' -f (Format-ByteSize $node.DirectAlloc), $node.DirectFiles))
            $files.ForeColor = [Drawing.Color]::DimGray
            [void]$TreeNode.Nodes.Add($files)
        }
    }
    finally { $dirTree.EndUpdate() }
}

$dirTree.Add_BeforeExpand({ param($sender, $eventArgs) Expand-DirectoryTreeNode -TreeNode $eventArgs.Node })
$dirTree.Add_AfterSelect({
    $script:AnalysisFocus = 'Tree'
    $entry = Get-SelectedTreeEntry
    if ($null -ne $entry) { $analysisAdvice.Text = $entry.Path; $recycleButton.Enabled = Test-RecyclablePath -Path $entry.Path }
})
$dirTree.Add_NodeMouseDoubleClick({ $script:AnalysisFocus = 'Tree'; Open-AnalysisLocation })

function Show-AnalysisResult {
    param($Result)
    $script:AnalysisResult = $Result
    $dirTree.BeginUpdate()
    try {
        $dirTree.Nodes.Clear()
        $rootNode = New-DirectoryTreeNode -Result $Result -Index 0 -ParentBytes 0
        [void]$dirTree.Nodes.Add($rootNode)
        Expand-DirectoryTreeNode -TreeNode $rootNode
        $rootNode.Expand()
    }
    finally { $dirTree.EndUpdate() }
    $suggestions = New-Object System.Collections.Generic.List[object]
    $catalogIds = @{}
    foreach ($suggestion in $Result.Suggestions) { $suggestions.Add($suggestion); if ($suggestion.CatalogId) { $catalogIds[$suggestion.CatalogId] = $true } }
    if ($Result.Root.Equals('C:\', [StringComparison]::OrdinalIgnoreCase)) {
        foreach ($suggestion in @(Get-CatalogSuggestions -Items $script:Items)) {
            if (-not $catalogIds.ContainsKey($suggestion.CatalogId)) { $suggestions.Add($suggestion) }
        }
    }
    Set-AnalysisListData -List $suggestionList -Data @($suggestions | Sort-Object -Property Bytes -Descending)
    Set-AnalysisListData -List $largeFileList -Data @($Result.TopFiles)
    Set-AnalysisListData -List $denseList -Data @($Result.DenseDirs)
    Set-AnalysisListData -List $extensionList -Data @($Result.Extensions | Select-Object -First 500)
    $suggestionList.Tag.SortColumn = 0
    $analysisInfo.Text = '{0}：{1:N0} 个文件，{2:N0} 个文件夹，占用 {3}，用时 {4:N1} 秒{5}' -f $Result.Mode, $Result.TotalFiles, $Result.TotalDirs, (Format-ByteSize $Result.TotalAlloc), $Result.Seconds, $(if ($Result.Errors -gt 0) { '，{0:N0} 个位置无权限读取' -f $Result.Errors } else { '' })
    if (-not [string]::IsNullOrWhiteSpace($Result.FallbackReason)) { $analysisInfo.Text += '（未使用 MFT：' + $Result.FallbackReason + '）' }
    Write-AppLog ('空间分析完成：' + $analysisInfo.Text)
    if (-not [string]::IsNullOrWhiteSpace($Result.Timings)) { Write-AppLog ('各阶段用时：' + $Result.Timings) }
}

$analysisTimer = New-Object Windows.Forms.Timer
$analysisTimer.Interval = 200
$analysisTimer.Add_Tick({
    $analyzer = $script:Analyzer
    if ($null -eq $analyzer) { $analysisTimer.Stop(); return }
    $seconds = ([datetime]::UtcNow - $analyzer.StartedUtc).TotalSeconds
    if (-not $analyzer.Completed) {
        $progressText = if ($analyzer.TotalBytesToRead -gt 0) { '，已读取 {0:N0}%' -f (100.0 * $analyzer.BytesRead / [Math]::Max(1, $analyzer.TotalBytesToRead)) } else { '' }
        $analysisInfo.Text = '{0}：{1:N0} 个文件，{2:N0} 个文件夹{3}，{4:N0} 秒' -f $analyzer.Phase, $analyzer.FilesScanned, $analyzer.DirsScanned, $progressText, $seconds
        return
    }
    $analysisTimer.Stop()
    $script:Analyzer = $null
    $analysisStartButton.Enabled = $true
    $analysisStopButton.Enabled = $false
    $analysisBrowseButton.Enabled = $true
    if ($null -ne $analyzer.Error) {
        $cause = $analyzer.Error
        if ($cause -is [OperationCanceledException]) { $analysisInfo.Text = '分析已停止。' }
        else { $analysisInfo.Text = '分析失败：' + $cause.Message; Write-AppLog $analysisInfo.Text }
        return
    }
    try { Show-AnalysisResult -Result $analyzer.Result }
    catch { $analysisInfo.Text = '显示结果失败：' + $_.Exception.Message }
})

function Start-SpaceAnalysis {
    if ($null -ne $script:Analyzer) { return }
    $root = $analysisRootBox.Text.Trim()
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        [void][Windows.Forms.MessageBox]::Show('请选择存在的文件夹或分区。', '空间分析', 'OK', 'Information')
        return
    }
    try {
        Initialize-DiskAnalyzer
        $analyzer = New-Object DiskAnalyzer
        $analyzer.Start([IO.Path]::GetFullPath($root), $true)
        $script:Analyzer = $analyzer
        $analysisStartButton.Enabled = $false
        $analysisStopButton.Enabled = $true
        $analysisBrowseButton.Enabled = $false
        $analysisInfo.Text = '正在准备分析…'
        $analysisTimer.Start()
    }
    catch { $analysisInfo.Text = '无法开始分析：' + $_.Exception.Message }
}

$analysisStartButton.Add_Click({ Start-SpaceAnalysis })
$analysisStopButton.Add_Click({ if ($null -ne $script:Analyzer) { $script:Analyzer.Cancel(); $analysisInfo.Text = '正在停止…' } })
$analysisBrowseButton.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = '选择要分析的分区或文件夹'
    $dialog.SelectedPath = $analysisRootBox.Text
    try { if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) { $analysisRootBox.Text = $dialog.SelectedPath } }
    finally { $dialog.Dispose() }
})
$openLocationButton.Add_Click({ Open-AnalysisLocation })
$copyPathButton.Add_Click({
    $entry = Get-ActiveAnalysisEntry
    if ($null -ne $entry -and -not [string]::IsNullOrWhiteSpace($entry.Path)) { [Windows.Forms.Clipboard]::SetText($entry.Path) }
})
$recycleButton.Add_Click({
    $entry = Get-ActiveAnalysisEntry
    if ($null -eq $entry -or [string]::IsNullOrWhiteSpace($entry.Path)) { return }
    if ($entry.Kind -eq 'Suggestion' -and -not $entry.Entry.CanRecycle) {
        [void][Windows.Forms.MessageBox]::Show('此建议需要按说明在系统设置或对应程序中处理，不能直接删除。', '空间分析', 'OK', 'Information')
        return
    }
    if (-not (Test-RecyclablePath -Path $entry.Path)) {
        [void][Windows.Forms.MessageBox]::Show('此路径属于系统、程序或用户根目录，或已不存在，为安全起见不提供删除。', '受保护的位置', 'OK', 'Warning')
        return
    }
    $answer = [Windows.Forms.MessageBox]::Show(('将以下内容移到回收站：' + [Environment]::NewLine + [Environment]::NewLine + $entry.Path + [Environment]::NewLine + [Environment]::NewLine + '请确认它不再需要，且相关程序已关闭。回收站仍占用 C 盘空间，确认无误后再清空回收站。继续吗？'), '移到回收站', 'YesNo', 'Warning')
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    try {
        if (Move-PathToRecycleBin -Path $entry.Path) {
            Write-AppLog ('已移到回收站：' + $entry.Path)
            if ($null -ne $entry.Row) { $entry.Row.ForeColor = [Drawing.Color]::Gray; $entry.Row.Text = '已移除' }
            if ($entry.Kind -eq 'Tree' -and $null -ne $entry.Node) { $entry.Node.Text = '〈已移到回收站〉 ' + $entry.Node.Text; $entry.Node.ForeColor = [Drawing.Color]::Gray }
        }
    }
    catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, '未能移到回收站', 'OK', 'Error') }
})
$gotoItemButton.Enabled = $false
$gotoItemButton.Add_Click({
    $entry = Get-SelectedAnalysisEntry
    if ($null -eq $entry -or $entry.Kind -ne 'Suggestion' -or -not $script:RowsById.ContainsKey($entry.Entry.CatalogId)) { return }
    $row = $script:RowsById[$entry.Entry.CatalogId]
    $filterBox.SelectedIndex = 0
    $mainTabs.SelectedTab = $cleanTab
    $grid.ClearSelection()
    $row.Selected = $true
    $grid.FirstDisplayedScrollingRowIndex = $row.Index
    if ($row.Tag.Action -eq 'Manage') { Show-ItemDetails $row.Tag }
})
$exportButton.Add_Click({
    if ($null -eq $script:AnalysisResult) { return }
    $dialog = New-Object Windows.Forms.SaveFileDialog
    $dialog.Filter = '文本文件 (*.txt)|*.txt'
    $dialog.FileName = 'C盘空间分析-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmm')
    try {
        if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
            $lines = Write-AnalysisReport -Result $script:AnalysisResult -Top 100
            [IO.File]::WriteAllLines($dialog.FileName, [string[]]@($lines), (New-Object Text.UTF8Encoding($true)))
        }
    }
    finally { $dialog.Dispose() }
})

# ---- 定时清理页：只允许完全可重建、无需管理员的低风险项目 ----

$scheduleLayout = New-Object Windows.Forms.TableLayoutPanel
$scheduleLayout.Dock = 'Fill'
$scheduleLayout.ColumnCount = 1
$scheduleLayout.RowCount = 5
$scheduleLayout.Padding = New-Object Windows.Forms.Padding(10)
[void]$scheduleLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 74)))
[void]$scheduleLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$scheduleLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 40)))
[void]$scheduleLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 44)))
[void]$scheduleLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 30)))
$scheduleTab.Controls.Add($scheduleLayout)

$scheduleIntro = New-Object Windows.Forms.Label
$scheduleIntro.Dock = 'Fill'
$scheduleIntro.Text = '每天在指定时间自动清理下列无风险项目：只包含可自动重建、不含个人数据、也不需要管理员权限的旧运行日志和过期临时文件。' + [Environment]::NewLine +
    '每次执行前都会检查相关程序是否在运行，运行中的项目会跳过；错过时间（例如关机）会在下次开机后补跑。结果写入日志目录，保留 30 天。'
$scheduleLayout.Controls.Add($scheduleIntro, 0, 0)

$scheduleList = New-Object Windows.Forms.CheckedListBox
$scheduleList.Dock = 'Fill'
$scheduleList.CheckOnClick = $true
$scheduleList.HorizontalScrollbar = $true
$scheduleLayout.Controls.Add($scheduleList, 0, 1)
$script:ScheduleItemIds = New-Object System.Collections.Generic.List[string]
$scheduleConfig = Get-ScheduleConfig
$scheduleHasSaved = Test-Path -LiteralPath (Get-ScheduleConfigPath) -PathType Leaf
foreach ($eligible in @(Get-ScheduleEligibleItems -Items $script:Items)) {
    $index = $scheduleList.Items.Add(('{0} — {1}' -f $eligible.Name, $eligible.Description))
    $script:ScheduleItemIds.Add($eligible.Id)
    $checked = if ($scheduleHasSaved) { $scheduleConfig.ItemIds -contains $eligible.Id } else { $eligible.Id -ne 'user-temp-old' }
    $scheduleList.SetItemChecked($index, $checked)
}

$scheduleSettings = New-Object Windows.Forms.FlowLayoutPanel
$scheduleSettings.Dock = 'Fill'
$scheduleLayout.Controls.Add($scheduleSettings, 0, 2)
$scheduleTimeLabel = New-Object Windows.Forms.Label
$scheduleTimeLabel.Text = '每天运行时间：'
$scheduleTimeLabel.AutoSize = $true
$scheduleTimeLabel.Margin = New-Object Windows.Forms.Padding(0, 8, 0, 0)
$scheduleTime = New-Object Windows.Forms.DateTimePicker
$scheduleTime.Format = 'Custom'
$scheduleTime.CustomFormat = 'HH:mm'
$scheduleTime.ShowUpDown = $true
$scheduleTime.Width = 70
$scheduleTime.Value = [datetime]::Today.Add([TimeSpan]::Parse($scheduleConfig.Time))
$scheduleKeepLabel = New-Object Windows.Forms.Label
$scheduleKeepLabel.Text = '旧日志保留：'
$scheduleKeepLabel.AutoSize = $true
$scheduleKeepLabel.Margin = New-Object Windows.Forms.Padding(24, 8, 0, 0)
$scheduleKeep = New-Object Windows.Forms.ComboBox
$scheduleKeep.DropDownStyle = 'DropDownList'
$scheduleKeep.Width = 80
[void]$scheduleKeep.Items.Add('7 天')
[void]$scheduleKeep.Items.Add('30 天')
$scheduleKeep.SelectedIndex = if ($scheduleConfig.LogKeepDays -eq 30) { 1 } else { 0 }
$scheduleSettings.Controls.AddRange(@($scheduleTimeLabel, $scheduleTime, $scheduleKeepLabel, $scheduleKeep))

$scheduleButtons = New-Object Windows.Forms.FlowLayoutPanel
$scheduleButtons.Dock = 'Fill'
$scheduleLayout.Controls.Add($scheduleButtons, 0, 3)
$scheduleEnableButton = New-ToolbarButton -Text '保存并启用' -Width 110
$scheduleDisableButton = New-ToolbarButton -Text '停用' -Width 80
$scheduleRunButton = New-ToolbarButton -Text '立即运行一次' -Width 118
$scheduleLogButton = New-ToolbarButton -Text '打开日志目录' -Width 118
$scheduleButtons.Controls.AddRange(@($scheduleEnableButton, $scheduleDisableButton, $scheduleRunButton, $scheduleLogButton))

$scheduleState = New-Object Windows.Forms.Label
$scheduleState.Dock = 'Fill'
$scheduleLayout.Controls.Add($scheduleState, 0, 4)

function Get-ScheduleConfigFromUi {
    $ids = @()
    for ($i = 0; $i -lt $scheduleList.Items.Count; $i++) { if ($scheduleList.GetItemChecked($i)) { $ids += $script:ScheduleItemIds[$i] } }
    return [pscustomobject]@{ Enabled = $true; Time = $scheduleTime.Value.ToString('HH:mm'); LogKeepDays = $(if ($scheduleKeep.SelectedIndex -eq 1) { 30 } else { 7 }); ItemIds = $ids }
}

function Update-ScheduleState {
    try { $scheduleState.Text = '当前状态：' + (Get-DailyCleanupTaskState) }
    catch { $scheduleState.Text = '当前状态：无法读取计划任务 — ' + $_.Exception.Message }
}

$scheduleEnableButton.Add_Click({
    $config = Get-ScheduleConfigFromUi
    if (@($config.ItemIds).Count -eq 0) { [void][Windows.Forms.MessageBox]::Show('请至少勾选一个项目。', '定时清理', 'OK', 'Information'); return }
    if ($script:ElevationIdentityMismatch) { [void][Windows.Forms.MessageBox]::Show('当前管理员账户与原账户不同，请在原账户的普通窗口中设置定时清理。', '定时清理', 'OK', 'Warning'); return }
    try {
        Register-DailyCleanupTask -Config $config
        Write-AppLog ('已启用每日定时清理：{0}，{1} 个项目。' -f $config.Time, @($config.ItemIds).Count)
    }
    catch { [void][Windows.Forms.MessageBox]::Show('无法创建计划任务：' + $_.Exception.Message, '定时清理', 'OK', 'Error') }
    Update-ScheduleState
})
$scheduleDisableButton.Add_Click({
    try { Unregister-DailyCleanupTask; Write-AppLog '已停用每日定时清理。' }
    catch { [void][Windows.Forms.MessageBox]::Show('无法停用计划任务：' + $_.Exception.Message, '定时清理', 'OK', 'Error') }
    Update-ScheduleState
})
$scheduleRunButton.Add_Click({
    $config = Get-ScheduleConfigFromUi
    if (@($config.ItemIds).Count -eq 0) { [void][Windows.Forms.MessageBox]::Show('请至少勾选一个项目。', '定时清理', 'OK', 'Information'); return }
    try {
        $config.Enabled = (Get-ScheduleConfig).Enabled
        Save-ScheduleConfig -Config $config
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $powershell -WindowStyle Hidden -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ScheduledClean' -f $script:ScriptPath) | Out-Null
        Write-AppLog '定时清理已在后台运行一次，结果写入日志目录。'
        [void][Windows.Forms.MessageBox]::Show('已在后台开始清理已勾选的项目。完成后可点击“打开日志目录”查看结果。', '定时清理', 'OK', 'Information')
    }
    catch { [void][Windows.Forms.MessageBox]::Show('无法启动：' + $_.Exception.Message, '定时清理', 'OK', 'Error') }
})
$scheduleLogButton.Add_Click({
    $logDirectory = Join-Path (Get-ScheduleDirectory) 'logs'
    [void][IO.Directory]::CreateDirectory($logDirectory)
    Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"{0}"' -f $logDirectory) | Out-Null
})
$script:AnalysisSplitSized = $false
$mainTabs.Add_SelectedIndexChanged({
    if ($mainTabs.SelectedTab -eq $scheduleTab) { Update-ScheduleState }
    # The page has no real size until first shown; give the lists (paths, advice) the larger share.
    if ($mainTabs.SelectedTab -eq $analysisTab -and -not $script:AnalysisSplitSized -and $analysisSplit.Width -gt 600) {
        $analysisSplit.SplitterDistance = [int]($analysisSplit.Width * 0.38)
        $script:AnalysisSplitSized = $true
    }
})

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($null -ne $script:Analyzer) { $script:Analyzer.Cancel() }
    if ($script:Busy) {
        $eventArgs.Cancel = $true
        $script:CloseWhenIdle = $true
        Request-WorkCancellation
        Write-AppLog '正在停止后台任务，结束后窗口会自动关闭。'
    }
})

$form.Add_Shown({
    Write-AppLog '按明确目录和保留期扫描。手动管理项目不会进入批量清理；查看路径按钮可检查每项范围。'
    Write-AppLog '空间按文件存储大小估算；重复映射不重复计量，共享硬链接文件跳过。'
    if ($script:ElevationIdentityMismatch) {
        Write-AppLog '警告：UAC 使用了不同的 Windows 账户；所有用户级项目已禁用，只允许系统级管理员项目。'
        [Windows.Forms.MessageBox]::Show('UAC 使用了与原窗口不同的 Windows 账户。为防止清理错误用户的数据，所有用户级项目已自动禁用；只能执行系统级管理员项目。', '账户不一致保护', 'OK', 'Warning') | Out-Null
    }
    Invoke-CatalogScan -ApplyDefaults $true
})

if ($UiSmokeTest) {
    Write-Output ('UI 构造成功：{0} 个清理项目，{1} 行；目标 {2} GB；按项目停止={3}；账户不一致保护={4}；页面 {5} 个；定时可选 {6} 项。' -f $script:Items.Count, $grid.Rows.Count, $goalBox.Value, $stopAtGoalCheck.Checked, $script:ElevationIdentityMismatch, $mainTabs.TabPages.Count, $scheduleList.Items.Count)
    $workerTimer.Dispose()
    $analysisTimer.Dispose()
    $form.Dispose()
    exit 0
}

try { [void][Windows.Forms.Application]::Run($form) }
finally { $workerTimer.Dispose(); $analysisTimer.Dispose(); $form.Dispose() }
