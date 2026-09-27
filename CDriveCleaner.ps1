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
    [hashtable]$WorkerRequest,
    [hashtable]$WorkerState,
    [System.Threading.CancellationTokenSource]$WorkerCancellation
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ScriptPath = $MyInvocation.MyCommand.Path
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
        [string]$ManageUri = ''
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

    $productPattern = '^(PyCharm|IntelliJIdea|Rider|WebStorm|CLion|GoLand|DataGrip|PhpStorm|RubyMine|RustRover)'
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

    Add-CleanupItem -List $List -Id 'wechat-old-logs' -Name '微信旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:APPDATA 'Tencent\xwechat\log'), (Join-Path $env:APPDATA 'Tencent\WeChat\log'))) `
        -UseLogRetention $true -FilePatterns @('*.xlog', '*.log') -ProcessNames @('WeChat', 'Weixin', 'WeChatAppEx') `
        -Description '按上方日志保留天数清理旧 .xlog/.log；保留近期文件及日志内存映射文件，不涉及聊天记录、附件和账户数据库。先退出微信。'
    Add-CleanupItem -List $List -Id 'trae-old-logs' -Name 'TRAE 旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:APPDATA 'Trae\logs'), (Join-Path $env:APPDATA 'TRAE CN\logs'), (Join-Path $env:APPDATA 'TRAE SOLO\logs'), (Join-Path $env:APPDATA 'TRAE SOLO CN\logs'))) `
        -UseLogRetention $true -FilePatterns @('*.log') -ProcessNames @('Trae', 'Trae CN', 'TRAE SOLO', 'TRAE SOLO CN') `
        -Description '仅在各 TRAE 配置的 logs 目录按保留天数清理旧日志；保留项目、会话、扩展及运行工具。先关闭 TRAE。'
    Add-CleanupItem -List $List -Id 'wolfram-old-logs' -Name 'Wolfram 旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths @((Join-Path $env:LOCALAPPDATA 'Wolfram\Logs'))) `
        -UseLogRetention $true -FilePatterns @('*.log') -ProcessNames @('Mathematica', 'WolframKernel', 'wolframscript', 'Wolfram') `
        -Description '按保留天数清理 Wolfram\Logs 中的旧日志；不涉及 Paclet、笔记本及安装组件。先退出 Wolfram 程序。'
    $codexLogRoots = @(Get-ExtendedAppRoots -PackagePattern 'OpenAI.Codex_*' -PackageRelativePath 'LocalCache\Local\Codex\Logs' -FallbackPaths @((Join-Path $env:LOCALAPPDATA 'Codex\Logs')))
    Add-CleanupItem -List $List -Id 'codex-old-logs' -Name 'Codex 旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(Get-ExtendedLiteralPathSpecs -Paths $codexLogRoots) -UseLogRetention $true -FilePatterns @('*.log') -ProcessNames @('Codex') `
        -Description '按保留天数清理桌面应用 Logs 目录中的旧日志；保留 .codex 中的任务历史、数据库和所有工作文件。先关闭 Codex。'
    Add-CleanupItem -List $List -Id 'clash-old-logs' -Name 'Clash Verge 旧运行日志' -Risk '低' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
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


function Get-CleanupCatalog {
    $list = New-Object System.Collections.ArrayList

    Add-CleanupItem -List $list -Id 'user-temp' -Name '用户临时文件' -Risk '中' -DefaultSelected $false -RequiresAdmin $false -Action 'Paths' `
        -PathSpecs @(New-PathSpec -Path (Join-Path $env:LOCALAPPDATA 'Temp') -AllowedRoot $env:LOCALAPPDATA) `
        -Description '清除当前用户临时目录中所有未被占用的内容；正在使用的文件会跳过。可能影响等待重启的安装程序，需手动选择。'

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
$form.Text = 'C 盘清理助手 · 扩展版'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(1180, 780)
$form.MinimumSize = New-Object Drawing.Size(1120, 650)
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$form.BackColor = [Drawing.Color]::White

$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.ColumnCount = 1
$layout.RowCount = 5
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 92)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 86)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 148)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 28)))
$form.Controls.Add($layout)

$header = New-Object Windows.Forms.Panel
$header.Dock = 'Fill'
$header.BackColor = [Drawing.Color]::FromArgb(245, 248, 252)
$layout.Controls.Add($header, 0, 0)

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
$layout.Controls.Add($toolbar, 0, 1)

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
$layout.Controls.Add($grid, 0, 2)

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
$layout.Controls.Add($logGroup, 0, 3)

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
$layout.Controls.Add($statusStrip, 0, 4)

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
    $message = "微信、TRAE、Wolfram、Codex、Clash 旧日志项目保留最近 $script:LogKeepDays 天；Windows 安装监控日志保留至少 30 天。`r`n`r`n将清理以下项目：`r`n`r`n" + ($nameLines -join "`r`n") + "`r`n`r`n预计释放（存储大小估算）：" + (Format-ByteSize $estimated) + "`r`n实际结果可能因占用、共享文件和应用重新写入而不同。删除的缓存无法直接撤销，是否继续？"
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

$form.Add_FormClosing({
    param($sender, $eventArgs)
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
    Write-Output ('UI 构造成功：{0} 个清理项目，{1} 行；目标 {2} GB；按项目停止={3}；账户不一致保护={4}。' -f $script:Items.Count, $grid.Rows.Count, $goalBox.Value, $stopAtGoalCheck.Checked, $script:ElevationIdentityMismatch)
    $workerTimer.Dispose()
    $form.Dispose()
    exit 0
}

try { [void][Windows.Forms.Application]::Run($form) }
finally { $workerTimer.Dispose(); $form.Dispose() }
