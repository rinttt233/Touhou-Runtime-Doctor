# ============================================================================
#  TouhouRuntimeDoctor.ps1 -- 主引擎
#
#  东方 Project 运行环境一键体检 / 修复 / 验证工具
#
#  一键用法：双击「一键修复.bat」，或
#            powershell -ExecutionPolicy Bypass -File TouhouRuntimeDoctor.ps1 -All
#
#  设计立场：
#   * 依赖判断来自 PE 导入表解析，不硬编码"东方需要 d3dx9_36.dll"这类猜测。
#     th06~th09 是 DirectX 8 作品（导入 d3d8.dll），装 DX9 对它们无效。
#   * 任何修改前先备份，全程记入 journal.json，支持整体回滚。
#   * 修复完必须做真机启动验证，用 NTSTATUS 退出码精确定位病因。
#   * 库文件一律用显式 UTF-8 读取后执行，不依赖 BOM —— 见 Import-TrdLibrary。
# ============================================================================
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Detect', 'Repair', 'Verify', 'Rollback', 'ListGames', 'SelfTest',
                 'SysInfo', 'SysInfoBrief', 'SysInfoJson')]
    [string]$Mode = 'Auto',

    [string]$OutDir,
    [switch]$OpenReport,
    [string]$GamePath,
    [string]$GameId,
    [string]$ToolRoot,
    [string]$OfflineRoot,
    [string]$BackupRoot,
    [string]$MigrateTargetRoot = 'D:\TouhouGames',
    # DirectX Repair 的 Data 目录（可选）。指定后可直接复用它的 DLL 库作为部署来源。
    [string]$DirectXRepairDataRoot,

    # 只在这些目录里搜索游戏。不给就会询问用户（见 -NoScanPrompt）。
    # 整盘遍历是本工具最慢的一步，显式指定能省掉大量时间。
    [string[]]$ScanRoot,
    [switch]$NoScanPrompt,           # 不问，直接按默认范围（常见位置）搜索
    [int]$ScanDepth = 3,             # 搜索深度

    [switch]$All,                    # 等价于 Mode=Auto
    [switch]$IncludeOptional,        # 一并补齐整机缺失的 VC 运行库、加 Defender 排除
    [switch]$IncludeRisky,           # 允许执行改变渲染/区域/路径的动作
    [switch]$DryRun,                 # 演练：只报告将要做什么
    [switch]$SkipSmokeTest,          # 跳过启动验证
    [switch]$KeepRunning,            # 验证通过后不关闭游戏
    [int]$SmokeSeconds = 10,
    [int]$RollbackSession = 0,       # 0 = 最近一次
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
#  库加载：显式 UTF-8 + ScriptBlock
#  这样即使 .ps1 文件丢失了 BOM（PowerShell 5.1 在中文系统上会按 GBK 解析，
#  导致中文乱码并破坏语法），工具依然能正确运行。
# ---------------------------------------------------------------------------
#  库加载：显式 UTF-8 读取 + 在【脚本顶层】dot-source
#
#  两个必须踩对的点：
#   1) 用 ReadAllText(..., UTF8) 显式解码，不依赖文件是否带 BOM。
#      PowerShell 5.1 在中文系统上会把无 BOM 的 UTF-8 按 GBK 解析，
#      中文会变乱码并直接破坏语法。
#   2) dot-source 必须发生在脚本作用域。若把它包在一个函数里执行，
#      函数内的 . $sb 只会把函数定义写进【函数作用域】，函数一返回就全没了，
#      后续调用就会报 "not recognized as the name of a cmdlet"。
#      所以这里让函数只负责"返回 ScriptBlock"，由顶层循环去 dot-source。
# ---------------------------------------------------------------------------
function Get-TrdLibraryBlock {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "缺少库文件: $Path" }
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return [ScriptBlock]::Create($text)
}

# ---------------------------------------------------------------------------
#  定位工具根目录
# ---------------------------------------------------------------------------
if (-not $ToolRoot) {
    if ($PSScriptRoot) { $ToolRoot = $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { $ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { $ToolRoot = (Get-Location).Path }
}
if (-not (Test-Path -LiteralPath $ToolRoot)) { throw "工具根目录不存在: $ToolRoot" }
$ToolRoot = (Resolve-Path -LiteralPath $ToolRoot).Path

if ($All) { $Mode = 'Auto' }

# --- 加载库（在脚本作用域 dot-source，见上方注释）---
foreach ($lib in @('Common.ps1', 'PeInspector.ps1', 'Detect.ps1', 'Diagnose.ps1',
                   'Repair.ps1', 'SmokeTest.ps1', 'Report.ps1',
                   'SysInfo.ps1', 'SysInfoReport.ps1', 'DxComponents.ps1', 'InputDiag.ps1')) {
    $libBlock = Get-TrdLibraryBlock -Path (Join-Path $ToolRoot "lib\$lib")
    . $libBlock
}

Initialize-TrdEnvironment -ToolRoot $ToolRoot -OfflineRoot $OfflineRoot -BackupRoot $BackupRoot -DryRun:$DryRun

# 全局开关（供 Repair 使用）
$script:TRD.DryRun = [bool]$DryRun

# ---------------------------------------------------------------------------
#  前置运行时检查
#  没有这一层，Windows 7（出厂只有 PowerShell 2.0）用户看到的是
#  "找不到与参数名称 Depth 匹配的参数" 之类无从下手的报错。
# ---------------------------------------------------------------------------
$prereq = @(Test-TrdRuntimePrerequisites)
$prereqFatal = @($prereq | Where-Object { $_.Level -eq 'Fatal' })
if ($prereqFatal.Count -gt 0) {
    Write-TrdBanner '无法启动'
    foreach ($p in $prereqFatal) {
        Write-TrdLog ''
        Write-TrdLog $p.Title 'Error'
        Write-TrdLog $p.Detail 'Info'
    }
    Write-TrdLog ''
    Write-TrdLog '检测到的环境：' 'Step'
    Write-TrdLog "  Windows     : $((Get-TrdWindowsBuild).Caption)" 'Detail'
    Write-TrdLog "  PowerShell  : $($PSVersionTable.PSVersion)" 'Detail'
    Write-TrdLog "  系统位数    : $(if ($script:TRD.Is64OS) { '64 位' } else { '32 位' })" 'Detail'
    if (-not $NoPause) { Write-Host ''; Write-Host '按回车键退出 ...' -ForegroundColor DarkGray; [void](Read-Host) }
    exit 4
}

# ---------------------------------------------------------------------------
#  设备信息模式：全面采集本机硬件与系统信息，不改动任何东西
#
#  三个子模式共用一个采集流程，只是输出侧重不同：
#    SysInfo      -> 完整四件套（txt / html / json / 精简）
#    SysInfoBrief -> 打印并只产出精简摘要
#    SysInfoJson  -> 打印并只产出 JSON
# ---------------------------------------------------------------------------
if ($Mode -in 'SysInfo', 'SysInfoBrief', 'SysInfoJson') {
    Write-TrdBanner "设备信息采集（工具版本 $($script:TRD.ToolVersion)）"
    Write-TrdLog ''
    Write-TrdLog '本模式为只读采集：不修改任何系统设置、不安装任何东西、不启动游戏。' 'Info'
    Write-TrdLog '管理员权限下能取到更完整的信息（显示器 EDID、部分磁盘健康状态等）。' 'Detail'
    if (-not $script:TRD.IsAdmin) {
        Write-TrdLog '当前为普通权限，若发现某些字段为空，可右键「设备信息.bat」以管理员身份重跑。' 'Warn'
    }
    Write-TrdLog ''

    $stepNo = 0
    $progress = {
        param([int]$i, [int]$total, [string]$msg)
        $pct = [int](($i / [double]$total) * 100)
        Write-TrdLog ("[{0,3}%] 正在采集: {1}" -f $pct, $msg) 'Step'
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $info = Get-TrdDeviceInfo -OnProgress $progress
    $sw.Stop()

    Write-TrdLog ''
    Write-TrdLog ("采集完成，用时 {0:N1} 秒。" -f $sw.Elapsed.TotalSeconds) 'OK'

    # 输出目录：默认放到工具目录下的“报告”文件夹，便于打包时一并带走
    if (-not $OutDir) { $OutDir = Join-Path $ToolRoot '报告' }
    if (-not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }

    $paths = Save-TrdSysInfoReports -Info $info -OutDir $OutDir

    Write-TrdLog ''
    Write-TrdLog '══ 采集结果摘要 ══' 'Step'
    Write-TrdLog ''
    foreach ($l in ((New-TrdSysInfoBrief -Info $info) -split "`r?`n")) {
        Write-TrdLog $l 'Detail'
    }

    Write-TrdLog ''
    Write-TrdLog '══ 生成的报告 ══' 'Step'
    if ($Mode -ne 'SysInfoJson') { Write-TrdLog "文本报告(完整): $($paths.Txt)"   'OK' }
    if ($Mode -ne 'SysInfoJson') { Write-TrdLog "文本报告(精简): $($paths.Brief)" 'OK' }
    if ($Mode -ne 'SysInfoJson') { Write-TrdLog "网页报告      : $($paths.Html)"  'OK' }
    Write-TrdLog "结构化数据    : $($paths.Json)" 'OK'

    # 提醒真正值得注意的项
    Write-TrdLog ''
    $alerts = New-Object System.Collections.ArrayList
    if ($info.ProblemDevices.Count -gt 0) {
        $null = $alerts.Add("有 $($info.ProblemDevices.Count) 个设备报告驱动异常（详见报告中的『有问题的设备』）")
    }
    foreach ($g in $info.Graphics) {
        if ($g.IsBasicAdapter) { $null = $alerts.Add("显卡 $($g.Name) 使用的是通用兜底驱动，没有 3D 加速能力") }
        elseif ($g.ErrorCode -ne 0) { $null = $alerts.Add("显卡 $($g.Name) 驱动异常（错误码 $($g.ErrorCode)）") }
    }
    if ($info.Audio -and -not $info.Audio.ServiceRunning) { $null = $alerts.Add('Windows Audio 服务未运行，可能导致游戏启动失败') }
    if ($info.DisplayModes -and $info.DisplayModes.Detected -and $info.DisplayModes.Has640x480 -eq $false) {
        $null = $alerts.Add('显卡驱动未提供 640×480 显示模式，老游戏全屏可能失败')
    }
    foreach ($s in @($info.Services | Where-Object { $_.Problem -eq $true })) {
        $null = $alerts.Add("关键服务异常: $($s.Name)（$($s.Status)/$($s.StartType)）")
    }
    if ($info.Security -and $info.Security.HasThirdParty) {
        $null = $alerts.Add("检测到第三方安全软件：$(($info.Security.ThirdPartyNames) -join '、')")
    }
    if ($info.Storage) {
        foreach ($v in @($info.Storage.Volumes | Where-Object { $_.DriveType -eq '本地磁盘' -and $_.UsedPercent -ge 90 })) {
            $null = $alerts.Add("$($v.Drive) 已用 $($v.UsedPercent)%，空间紧张")
        }
    }

    if ($alerts.Count -gt 0) {
        Write-TrdLog "需要留意的 $($alerts.Count) 项：" 'Warn'
        foreach ($a in $alerts) { Write-TrdLog "  * $a" 'Warn' }
    } else {
        Write-TrdLog '未发现需要特别注意的项。' 'OK'
    }

    if ($OpenReport -and (Test-Path -LiteralPath $paths.Html)) {
        try { Start-Process -FilePath $paths.Html | Out-Null } catch { }
    }

    if (-not $NoPause) { Write-Host ''; Write-Host '按回车键退出 ...' -ForegroundColor DarkGray; [void](Read-Host) }
    exit 0
}

# ---------------------------------------------------------------------------
#  自检模式：不碰游戏、不改系统，只回答"这台机器上工具能不能用"
# ---------------------------------------------------------------------------
if ($Mode -eq 'SelfTest') {
    Write-TrdBanner '环境自检模式'
    Write-TrdLog ''
    Write-TrdLog '本模式不读取、不修改任何游戏文件与系统设置，只实测工具自身各项能力。' 'Info'
    Write-TrdLog ''

    $results = @(Invoke-TrdSelfTest)
    $failCritical = 0
    $failOptional = 0

    foreach ($r in $results) {
        if ($r.Ok) {
            Write-TrdLog ("[通过] {0}" -f $r.Name) 'OK'
        } elseif ($r.Critical) {
            Write-TrdLog ("[失败] {0}" -f $r.Name) 'Error'
            $failCritical++
        } else {
            Write-TrdLog ("[降级] {0}" -f $r.Name) 'Warn'
            $failOptional++
        }
        Write-TrdLog ("       {0}" -f $r.Detail) 'Detail'
    }

    Write-TrdLog ''
    Write-TrdLog ('=' * 74) 'Title'
    if ($failCritical -eq 0) {
        Write-TrdLog '  结论：本机环境完全满足要求，工具可以正常使用。' 'OK'
    } else {
        Write-TrdLog "  结论：有 $failCritical 项关键能力不可用，工具在本机无法正常工作。" 'Error'
        Write-TrdLog '        请按上面每一项的说明处理后重试。' 'Warn'
    }
    if ($failOptional -gt 0) {
        Write-TrdLog "  另有 $failOptional 项非关键能力降级，不影响基本使用。" 'Warn'
    }
    Write-TrdLog ('=' * 74) 'Title'

    if (-not $NoPause) { Write-Host ''; Write-Host '按回车键退出 ...' -ForegroundColor DarkGray; [void](Read-Host) }
    exit $(if ($failCritical -eq 0) { 0 } else { 5 })
}

# ---------------------------------------------------------------------------
#  回滚模式：独立分支，不做其他事
# ---------------------------------------------------------------------------
if ($Mode -eq 'Rollback') {
    Write-TrdBanner '回滚模式'
    # 只考虑"确实产生过改动"的会话：只读体检与演练运行不会留下 journal，
    # 若把它们当成最近回滚点，用户会看到"什么都没发生"而不知为何。
    Invoke-TrdRollback -Skip ([Math]::Max(0, $RollbackSession - 1))
    if (-not $NoPause) { Write-Host ''; Write-Host '按回车键退出 ...' -ForegroundColor DarkGray; [void](Read-Host) }
    exit 0
}

# ---------------------------------------------------------------------------
#  选定目标
# ---------------------------------------------------------------------------
$modeLabel = switch ($Mode) {
    'Detect'    { '体检模式（只读，不做任何修改）' }
    'Repair'    { '修复模式（体检 + 修复）' }
    'Verify'    { '验证模式（只做启动验证）' }
    'ListGames' { '游戏列表模式' }
    default     { '一键模式（体检 + 修复 + 启动验证）' }
}

Write-TrdBanner $modeLabel

if ($DryRun) { Write-TrdLog '演练模式已开启：只显示将要执行的操作，不会真正修改系统。' 'Warn' }

Write-TrdLog ''
Write-TrdLog "管理员权限: $(if ($script:TRD.IsAdmin) { '已获得' } else { '未获得（需要管理员权限的修复会被跳过）' })" `
    $(if ($script:TRD.IsAdmin) { 'OK' } else { 'Warn' })
Write-TrdLog "离线载荷  : $(if (Test-TrdOfflineAvailable) { '已就绪' } else { '未找到（离线修复需要它；' + (Get-TrdOfflineHint -Short) + '）' })" `
    $(if (Test-TrdOfflineAvailable) { 'OK' } else { 'Warn' })

# ---------------------------------------------------------------------------
#  查找游戏
#
#  整盘遍历是本工具最慢的一步，而绝大多数机器上完全没必要 —— 真正存游戏的
#  往往只有一两个目录。所以默认先问用户要扫哪几个目录，并把选择记住；
#  只有用户明确选择"全部"时才整盘扫描。非交互环境则走便宜的那条路。
# ---------------------------------------------------------------------------
$searchRoots     = @()
$useDefaultRoots = $false
$scanAllDrives   = $false
$skipSearch      = $false

# -ScanRoot 在不同入口下会以数组或"空格拼起来的单个字符串"到达，
# 这里统一解析成真实存在的目录；一个都解析不出来时给出警告并退回默认范围，
# 免得用户以为"我明明指定了目录"，工具却什么都没扫。
$givenRoots = @(ConvertTo-TrdScanRootList -Value $ScanRoot)
if ($ScanRoot -and @($ScanRoot).Count -gt 0 -and @($givenRoots).Count -eq 0) {
    Write-TrdLog '警告：-ScanRoot 里没有一个是有效目录，将改用默认范围搜索。' 'Warn'
}

if ($GamePath) {
    # 已经指明位置，不必再猜，也不必问
    $searchRoots = @($GamePath)
} elseif (@($givenRoots).Count -gt 0) {
    # 命令行显式指定（已经过容错解析，见 ConvertTo-TrdScanRootList）
    $searchRoots = @($givenRoots)
} elseif (-not $NoScanPrompt -and (Test-TrdCanPrompt)) {
    $pick = Select-TrdScanRoots -ToolRoot $script:TRD.ToolRoot
    switch ($pick.Action) {
        'roots'     { $searchRoots = @($pick.Roots) }
        'alldrives' { $scanAllDrives = $true }
        'none'      { $skipSearch = $true }
        default     { $useDefaultRoots = $true }
    }
    if ($pick.Remember -and @($pick.Roots).Count -gt 0) {
        if (Save-TrdScanRoots -Roots @($pick.Roots) -ToolRoot $script:TRD.ToolRoot) {
            Write-TrdLog '已记住这次的扫描目录，下次直接回车即可复用。' 'Detail'
        }
    }
} else {
    # 非交互环境（管道、计划任务、加了 -NoScanPrompt）：只扫常见位置，不整盘扫
    $useDefaultRoots = $true
}

if ($skipSearch) {
    $games = @()
    Write-TrdLog '已按你的选择跳过目录搜索。' 'Info'
} else {
    Write-TrdLog ''
    Write-TrdLog '正在搜索本机的东方 Project 游戏 ...' 'Step'
    $scan = Find-TrdTouhouGamesEx -Roots $searchRoots -MaxDepth $ScanDepth `
                -IncludeDefaultRoots:$useDefaultRoots -IncludeAllFixedDrives:$scanAllDrives
    $games = @($scan.Games)
    # 把"这次搜索花了多少代价"明确说出来：用户才能判断要不要缩小范围
    Write-TrdLog ("搜索完成：访问 $($scan.Visited) 个目录，按名字跳过 $($scan.Pruned) 个无关目录，" +
                  "用时 $([math]::Round($scan.ElapsedMs / 1000, 1)) 秒。") 'Detail'
    if ($scan.Truncated) { Write-TrdLog '已达本次访问上限，搜索结果可能不完整。' 'Warn' }
}

if ($games.Count -eq 0 -and $GamePath -and (Test-Path -LiteralPath (Join-Path $GamePath 'th08.exe'))) {
    # 用户直接指了个游戏目录但不符合命名规则，仍尝试按目录处理
    $games = @([PSCustomObject]@{
        Id = 'th08'; Folder = (Resolve-Path -LiteralPath $GamePath).Path
        MainExe = (Join-Path $GamePath 'th08.exe')
        LauncherExe = $(if (Test-Path -LiteralPath (Join-Path $GamePath 'vpatch.exe')) { Join-Path $GamePath 'vpatch.exe' } else { $null })
        Engine = 'dx8'; DisplayName = '东方永夜抄 ~ Imperishable Night'
        ExeCount = 1; FolderName = (Split-Path -Leaf $GamePath)
    })
}

# 用便宜范围没找到时不要直接放弃：问一句要不要整盘找一次。
# 否则用户按了回车（只扫常见位置）却没找到，只能自己重跑一遍 —— 那才是真浪费时间。
if ($games.Count -eq 0 -and -not $skipSearch -and -not $scanAllDrives -and -not $GamePath `
        -and -not $NoScanPrompt -and (Test-TrdCanPrompt)) {
    Write-Host ''
    Write-Host '  在常见位置里没有找到东方游戏。' -ForegroundColor Yellow
    $goAll = ''
    try { $goAll = [string](Read-Host '  要不要把所有磁盘整盘搜索一遍？会慢一些 (y/N)') } catch { $goAll = '' }
    if ($goAll -match '^(?i)y') {
        Write-TrdLog '正在整盘搜索，请稍候 ...' 'Step'
        $scan2 = Find-TrdTouhouGamesEx -IncludeDefaultRoots -IncludeAllFixedDrives -MaxDepth $ScanDepth
        $games = @($scan2.Games)
        Write-TrdLog ("整盘搜索完成：访问 $($scan2.Visited) 个目录，" +
                      "用时 $([math]::Round($scan2.ElapsedMs / 1000, 1)) 秒。") 'Detail'
    }
}

if ($games.Count -eq 0) {
    Write-TrdLog '没有找到任何东方 Project 游戏目录。' 'Error'
    Write-TrdLog '请用 -GamePath 显式指定游戏所在目录，例如：' 'Info'
    Write-TrdLog '  powershell -ExecutionPolicy Bypass -File TouhouRuntimeDoctor.ps1 -GamePath "D:\game\[th08] 东方永夜抄"' 'Info'
    Write-TrdLog '或者用 -ScanRoot 只在你指定的几个目录里找（比整盘快得多）：' 'Info'
    Write-TrdLog '  -ScanRoot "D:\game","E:\download\东方STG及工具合集"' 'Info'
    if (-not $NoPause) { Write-Host ''; Write-Host '按回车键退出 ...' -ForegroundColor DarkGray; [void](Read-Host) }
    exit 2
}

Write-TrdLog "找到 $($games.Count) 个东方游戏目录：" 'OK'
foreach ($g in $games) {
    $isLauncher = if ($g.LauncherExe) { 'vpatch' } else { '直接启动' }
    Write-TrdLog ("  {0,-7} {1,-42} [{2,-3}] {3}" -f $g.Id, $g.DisplayName, $g.Engine, $isLauncher) 'Detail'
    # 同一作品可能在本机存在多份安装（本次实测就有 th07/th11 各两份），
    # 不显示路径会让用户误以为工具重复报了同一个游戏。
    Write-TrdLog ("          {0}" -f $g.Folder) 'Detail'
}

if ($Mode -eq 'ListGames') {
    Write-Host ''
    Write-TrdLog '列表模式结束。' 'OK'
    if (-not $NoPause) { Write-Host '按回车键退出 ...' -ForegroundColor DarkGray; [void](Read-Host) }
    exit 0
}

# 选定目标：显式 GameId > 显式 GamePath > 优先 th08 > 第一个
$game = $null
if ($GameId) { $game = $games | Where-Object { $_.Id -eq $GameId } | Select-Object -First 1 }
if (-not $game -and $GamePath) { $game = $games | Where-Object { $_.Folder -eq (Resolve-Path -LiteralPath $GamePath).Path } | Select-Object -First 1 }
if (-not $game) { $game = $games | Where-Object { $_.Id -eq 'th08' } | Select-Object -First 1 }
if (-not $game) { $game = $games[0] }

Write-TrdLog ''
Write-TrdLog "本次目标: $($game.DisplayName)" 'OK'
Write-TrdLog "目录: $($game.Folder)" 'Detail'
if ($games.Count -gt 1 -and -not $GameId) {
    $otherIds = @($games | Where-Object { $_.Id -ne $game.Id } | ForEach-Object { $_.Id } | Sort-Object -Unique)
    $exampleId = if ($otherIds.Count -gt 0) { $otherIds[0] } else { $game.Id }
    Write-TrdLog "（本机共 $($games.Count) 个安装，可用 -GameId 指定其他作品，例如 -GameId $exampleId）" 'Info'
}

# ---------------------------------------------------------------------------
#  体检
# ---------------------------------------------------------------------------
Write-TrdLog ''
Write-TrdLog '══ 环境体检 ══' 'Step'

$diag = Invoke-TrdDiagnosis -Game $game

$sevIcon = @{ 'Blocker' = '[严重]'; 'High' = '[ 高 ]'; 'Medium' = '[ 中 ]'; 'Low' = '[ 低 ]'; 'Pass' = '[正常]' }
Write-TrdLog ''
foreach ($f in $diag.Findings) {
    if ($f.Severity -eq 'Pass') { continue }
    Write-TrdLog ("{0} {1}" -f $sevIcon[$f.Severity], $f.Title) $(if ($f.Severity -eq 'Blocker' -or $f.Severity -eq 'High') { 'Error' } elseif ($f.Severity -eq 'Medium') { 'Warn' } else { 'Info' })
    if ($f.FixHint) { Write-TrdLog ("       处理: {0}" -f $f.FixHint) 'Detail' }
}

Write-TrdLog ''
$verdictLine = switch ($diag.Summary.Verdict) {
    'REPAIR_NEEDED'      { '发现会导致游戏无法启动的问题，需要修复。' }
    'REPAIR_RECOMMENDED' { '存在高风险项，建议修复。' }
    'MINOR_ISSUES'       { '游戏可以运行，但有几处体验问题值得处理。' }
    'HEALTHY'            { '环境健康，未发现需要处理的问题。' }
    default              { '' }
}
Write-TrdLog ("体检结果: 严重 {0} / 高 {1} / 中 {2} / 低 {3} / 正常 {4}" -f `
    $diag.Summary.Blocker, $diag.Summary.High, $diag.Summary.Medium, $diag.Summary.Low, $diag.Summary.Pass) 'Info'
Write-TrdLog $verdictLine $(if ($diag.Summary.Blocker -gt 0) { 'Error' } elseif ($diag.Summary.High -gt 0) { 'Warn' } else { 'OK' })

# ---------------------------------------------------------------------------
#  修复
# ---------------------------------------------------------------------------
$repairLog = New-Object System.Collections.ArrayList
$manualSteps = New-Object System.Collections.ArrayList

if ($Mode -eq 'Repair' -or $Mode -eq 'Auto') {

    $plan = @(New-TrdRepairPlan -Diagnosis $diag -IncludeOptional:$IncludeOptional -IncludeRisky:$IncludeRisky)

    Write-TrdLog ''
    Write-TrdLog '══ 修复计划 ══' 'Step'

    if ($plan.Count -eq 0) {
        Write-TrdLog '没有需要自动修复的项目。' 'OK'
    } else {
        $i = 0
        foreach ($s in $plan) {
            $i++
            Write-TrdLog ("{0}. {1}" -f $i, $s.Title) 'Info'
            if ($s.FixHint) { Write-TrdLog ("   将执行: {0}" -f $s.FixHint) 'Detail' }
        }
        Write-TrdLog ''
        if (-not $script:TRD.IsAdmin -and @($plan | Where-Object { $_.NeedsAdmin }).Count -gt 0) {
            Write-TrdLog '注意：计划中有需要管理员权限的步骤，当前未以管理员运行，这些步骤会被跳过。' 'Warn'
            Write-TrdLog '     请关闭本窗口，右键「一键修复.bat」选择「以管理员身份运行」后重试。' 'Warn'
        }

        $i = 0
        foreach ($s in $plan) {
            $i++
            Write-TrdLog ''
            Write-TrdLog "── 步骤 $i/$($plan.Count) ──" 'Info'
            $r = Invoke-TrdRepairStep -Step $s -Diagnosis $diag -OfflineRoot $script:TRD.OfflineRoot `
                 -MigrateTargetRoot $MigrateTargetRoot -DirectXRepairDataRoot $DirectXRepairDataRoot
            $null = $repairLog.Add([PSCustomObject]@{
                Title = $s.Title; Ok = [bool]($r -and $r.Ok)
                Message = $(if ($r -and $r.Message) { $r.Message } else { '' })
                FixId = $s.FixId
            })
        }

        # 运行库安装后，仍有无法解析的依赖 -> 走"游戏目录本地部署"兜底
        Write-TrdLog ''
        Write-TrdLog '── 兜底检查：重新解析依赖 ──' 'Info'
        $reDeps = Resolve-TrdGameDependencies -GameFolder $game.Folder
        $stillMissing = @($reDeps.Missing | Where-Object { $_.Source -eq 'Static' } |
                          ForEach-Object { $_.Dll } | Sort-Object -Unique)
        if ($stillMissing.Count -eq 0) {
            Write-TrdLog "重新解析通过：全部 $($reDeps.TotalDeps) 项依赖均可解析。" 'OK'
            $null = $repairLog.Add([PSCustomObject]@{
                Title = '依赖复查'; Ok = $true
                Message = "全部 $($reDeps.TotalDeps) 项依赖解析成功"; FixId = 'RECHECK'
            })
        } else {
            Write-TrdLog "仍有 $($stillMissing.Count) 个 DLL 无法解析: $($stillMissing -join ', ')" 'Warn'
            Write-TrdLog '尝试把这几个 DLL 直接部署到游戏目录（不改系统目录，可精确回滚）...' 'Step'
            $fb = Install-TrdDllLocalFallback -Diagnosis $diag -OfflineRoot $script:TRD.OfflineRoot -DllNames $stillMissing
            $null = $repairLog.Add([PSCustomObject]@{
                Title = '依赖兜底部署'; Ok = [bool]$fb.Ok; Message = $fb.Message; FixId = 'FIX_DEPLOY_DLL_LOCAL'
            })
            if (-not $fb.Ok) {
                $null = $manualSteps.Add("仍有依赖无法补全：$($stillMissing -join ', ')。$(Get-TrdOfflineHint -Short)")
            }
        }
    }
}

# 收集无法自动处理的项
foreach ($f in $diag.Findings) {
    if ($f.Severity -eq 'Pass') { continue }
    if ($f.FixId) { continue }
    $text = if ($f.FixHint) { "$($f.Title) —— $($f.FixHint)" } else { $f.Title }
    $null = $manualSteps.Add($text)
}
foreach ($r in $repairLog) {
    if (-not $r.Ok) { $null = $manualSteps.Add("未能完成的修复：$($r.Title)（$($r.Message)）") }
}

# ---------------------------------------------------------------------------
#  启动验证
# ---------------------------------------------------------------------------
$smoke = $null
if ($Mode -eq 'Verify' -or $Mode -eq 'Auto') {
    if ($SkipSmokeTest) {
        Write-TrdLog ''
        Write-TrdLog '已按要求跳过启动验证（-SkipSmokeTest）。' 'Warn'
    } else {
        $smoke = Invoke-TrdSmokeTest -Game $game -SettleSeconds $SmokeSeconds -KeepRunning:$KeepRunning
    }
}

# ---------------------------------------------------------------------------
#  报告
# ---------------------------------------------------------------------------
Save-TrdJournal

# ---------------------------------------------------------------------------
#  输入子系统原始快照
#  报告只给结论，快照给的是原始数据。将来要做输入相关的改进
#  （换用 Raw Input 接管、按键录制回放、跨机器差异比对），这份快照是数据基础。
# ---------------------------------------------------------------------------
Write-TrdLog ''
Write-TrdLog '══ 采集输入子系统快照 ══' 'Step'
try {
    $inpDiag = Get-TrdInputDiagnostics -GameFolder $game.Folder
    $snapDir = Join-Path $script:TRD.SessionDir 'input'
    $snap = Export-TrdInputSnapshot -InputDiag $inpDiag -OutDir $snapDir
    Write-TrdLog "输入诊断快照: $snap" 'OK'
    # 同时放一份到工具目录，便于直接取用
    $pubDir = Join-Path $ToolRoot '报告'
    $null = Export-TrdInputSnapshot -InputDiag $inpDiag -OutDir $pubDir
    Write-TrdLog "（另存一份到 报告 目录，供后续分析/插件使用）" 'Detail'
} catch {
    Write-TrdLog "输入快照采集失败（不影响其他功能）: $($_.Exception.Message)" 'Warn'
}

Write-TrdLog ''
Write-TrdLog '══ 生成报告 ══' 'Step'
$paths = Save-TrdReports -Diagnosis $diag -RepairLog $repairLog -SmokeResult $smoke `
         -ToolRoot $ToolRoot -OfflineRoot $script:TRD.OfflineRoot -ManualSteps @($manualSteps)

Write-TrdLog "文本报告: $($paths.TxtPath)" 'OK'
Write-TrdLog "网页报告: $($paths.HtmlPath)" 'OK'
if ($script:TRD.Journal.Count -gt 0) {
    Write-TrdLog "回滚记录: $(Join-Path $script:TRD.SessionDir 'journal.json')" 'Info'
    Write-TrdLog '如需撤销本次全部修改，请双击运行同目录下的「回滚.bat」' 'Detail'
}

# ---------------------------------------------------------------------------
#  收尾
# ---------------------------------------------------------------------------
Write-TrdLog ''
Write-TrdLog ('=' * 74) 'Title'
if ($smoke) {
    switch ($smoke.Verdict) {
        'PASSED'  { Write-TrdLog '  结论：修复完成，游戏已成功启动。' 'OK' }
        'PARTIAL' { Write-TrdLog '  结论：游戏进程可以起来了，但没有检测到窗口，请手动确认一次。' 'Warn' }
        'FAILED'  { Write-TrdLog "  结论：游戏仍无法启动（$($smoke.ExitCodeHex)）。请把报告发给排查者，报告里有完整证据链。" 'Error' }
        default   { Write-TrdLog '  结论：验证结果不确定，请手动双击启动器确认。' 'Warn' }
    }
} else {
    Write-TrdLog '  结论：体检与修复已完成（未做启动验证）。' 'Info'
}
Write-TrdLog ('=' * 74) 'Title'

if ($manualSteps.Count -gt 0) {
    Write-TrdLog ''
    Write-TrdLog '需要你手动完成的步骤：' 'Warn'
    foreach ($s in $manualSteps) { Write-TrdLog "  * $s" 'Warn' }
}

Write-TrdLog ''
Write-TrdLog "报告已生成，可直接双击打开：修复报告.html" 'Info'

if (-not $NoPause) {
    Write-Host ''
    Write-Host '按回车键退出 ...' -ForegroundColor DarkGray
    [void](Read-Host)
}
exit 0
