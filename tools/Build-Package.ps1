# ============================================================================
#  Build-Package.ps1 -- 打成可分发压缩包
#
#  产物（输出到 <工具根>\dist\）：
#    TouhouRuntimeDoctor-<版本>-lite.zip    仅工具本体，约 1 MB，需联网抓载荷
#    TouhouRuntimeDoctor-<版本>-full.zip    含离线载荷，约 200 MB，拷过去即可用
#    SHA256SUMS.txt                         两个包的校验值
#    dist\staging\                          打包用的暂存目录（可删）
#
#  刻意排除的内容：
#    backup\    -- 每次运行的备份与回滚日志，属于本机历史，不该发出去
#    报告\      -- 本机采集到的设备信息，含序列号等隐私信息
#    dist\      -- 打包产物自身，避免递归
#    *.log      -- 运行日志
#
#  用法：
#    pwsh -File tools\Build-Package.ps1                 生成 full + lite
#    pwsh -File tools\Build-Package.ps1 -LiteOnly       只生成 lite
#    pwsh -File tools\Build-Package.ps1 -FullOnly       只生成 full
#    pwsh -File tools\Build-Package.ps1 -KeepStaging    保留暂存目录便于检查
# ============================================================================
[CmdletBinding()]
param(
    [string]$ToolRoot,
    [switch]$LiteOnly,
    [switch]$FullOnly,
    [switch]$KeepStaging,
    [switch]$NoZip
)

$ErrorActionPreference = 'Stop'

if (-not $ToolRoot) {
    if ($PSScriptRoot) { $ToolRoot = Split-Path -Parent $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { $ToolRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
    else { $ToolRoot = (Get-Location).Path }
}
$ToolRoot = (Resolve-Path -LiteralPath $ToolRoot).Path

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
}
function Write-Item {
    param([string]$Mark, [string]$Text, [string]$Color = 'Gray')
    Write-Host ("  [{0}] {1}" -f $Mark, $Text) -ForegroundColor $Color
}

# ---------------------------------------------------------------------------
#  版本号
# ---------------------------------------------------------------------------
$version = '0.0.0'
$vf = Join-Path $ToolRoot 'VERSION.txt'
if (Test-Path -LiteralPath $vf) {
    $version = ([System.IO.File]::ReadAllText($vf, [System.Text.Encoding]::UTF8)).Trim()
}
$stamp = Get-Date -Format 'yyyyMMdd'
$pkgName = "TouhouRuntimeDoctor-$version"

Write-Head 'Touhou Runtime Doctor - 打包'
Write-Item '..' "工具根目录: $ToolRoot"
Write-Item '..' "版本: $version    日期: $stamp"

$distRoot = Join-Path $ToolRoot 'dist'
$stageRoot = Join-Path $distRoot 'staging'
$outDir = Join-Path $stageRoot $pkgName

# 排除规则：路径中出现这些片段就跳过
$excludeParts = @(
    '\backup\', '\dist\', '\报告\', '\__pycache__\', '\.git\', '\.vs\', '\node_modules\'
)

function Test-Excluded {
    param([string]$FullPath)
    foreach ($p in $excludeParts) {
        if ($FullPath -like "*$p*") { return $true }
    }
    $leaf = Split-Path -Leaf $FullPath
    if ($leaf -like '*.log') { return $true }
    if ($leaf -eq '修复报告.txt' -or $leaf -eq '修复报告.html') { return $true }
    return $false
}

function Copy-ToolTree {
    <#
    .SYNOPSIS
        把工具目录复制成一份干净的发布树。
    .PARAMETER IncludePayload
        是否包含 offline\ 下的实际载荷文件（约 196 MB）。
        lite 包只保留 offline\packages.json 与说明文件，让目录结构完整但体积很小。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$IncludePayload
    )

    # 这里必须与代码实际使用的载荷目录保持一致。
    # DxComponents.ps1 的 Get-TrdDxPayloadSource 找的是 offline\DX_DLL\x86|x64，
    # 而这份清单早期只写了 offline\DirectX —— 两者不一致的后果很严重：
    # lite 包会把将近 190 MB 的 DirectX DLL 一起打进去，完全违背
    # "lite = 仅工具本体"的约定，而体积异常又很容易被忽略。
    $payloadDirs = @(
        (Join-Path $ToolRoot 'offline\DX_DLL'),
        (Join-Path $ToolRoot 'offline\DirectX'),
        (Join-Path $ToolRoot 'offline\VCRedist'),
        (Join-Path $ToolRoot 'offline\Tools'),
        (Join-Path $ToolRoot 'offline\DLL'),
        (Join-Path $ToolRoot 'offline\Fonts'),
        (Join-Path $ToolRoot 'offline\Patches')
    )

    $files = @(Get-ChildItem -LiteralPath $ToolRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
    $copied = 0; $skipped = 0; $payloadSkipped = 0

    foreach ($f in $files) {
        if (Test-Excluded -FullPath $f.FullName) { $skipped++; continue }

        if (-not $IncludePayload) {
            $isPayload = $false
            foreach ($pd in $payloadDirs) {
                if ($f.FullName.StartsWith($pd, [StringComparison]::OrdinalIgnoreCase)) { $isPayload = $true; break }
            }
            if ($isPayload) { $payloadSkipped++; continue }
        }

        $rel = $f.FullName.Substring($ToolRoot.Length).TrimStart('\')
        $target = Join-Path $Destination $rel
        $tdir = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $tdir)) { $null = New-Item -ItemType Directory -Path $tdir -Force }
        Copy-Item -LiteralPath $f.FullName -Destination $target -Force
        $copied++
    }

    return [PSCustomObject]@{ Copied = $copied; Skipped = $skipped; PayloadSkipped = $payloadSkipped }
}

function New-ZipPackage {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [ValidateSet('Optimal', 'Fastest', 'NoCompression')][string]$Level = 'Optimal'
    )

    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $lvl = [System.IO.Compression.CompressionLevel]::$Level
        [System.IO.Compression.ZipFile]::CreateFromDirectory($SourceDir, $ZipPath, $lvl, $false)
    } catch {
        # 兜底：PS5 的 Compress-Archive
        $ea = Get-Command -Name 'Compress-Archive' -ErrorAction SilentlyContinue
        if (-not $ea) { throw "无法创建压缩包（既没有 .NET Compression 也没有 Compress-Archive）: $($_.Exception.Message)" }
        Compress-Archive -Path (Join-Path $SourceDir '*') -DestinationPath $ZipPath -Force
    }

    return (Get-Item -LiteralPath $ZipPath)
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { $bytes = $sha.ComputeHash($fs) } finally { $fs.Close(); $fs.Dispose(); $sha.Dispose() }
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) { $null = $sb.Append($b.ToString('X2')) }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
#  准备输出目录
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $distRoot)) { $null = New-Item -ItemType Directory -Path $distRoot -Force }
if (Test-Path -LiteralPath $stageRoot) {
    Write-Item '..' '清理旧的暂存目录 ...'
    Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$null = New-Item -ItemType Directory -Path $outDir -Force

# ---------------------------------------------------------------------------
#  打包说明
# ---------------------------------------------------------------------------
Write-Head '写入打包信息'

$readmeLines = @(
    '================================================================================',
    "  Touhou Runtime Doctor  $version",
    '  东方 Project 运行环境一键体检修复工具 + 设备信息采集',
    "  打包日期：$stamp",
    '================================================================================',
    '',
    '【两种包的区别】',
    '',
    "  $pkgName-lite.zip",
    '      仅工具本体（约 1 MB）。',
    '      用于：当前机器能联网，或你已另有一份 offline 载荷。',
    '      首次使用前先跑 tools\Fetch-OfflinePack.ps1 把运行库抓下来。',
    '',
    "  $pkgName-full.zip",
    '      含离线载荷（约 520 MB）：',
    '        - VC++ 2005~2022 的 x86/x64 安装包 12 个',
    '        - DirectX 组件 DLL 的 x86 与 x64 两套（各 92 个）',
    '        - DirectX 9.0c 官方运行库（2010 年 6 月）及已解包内容',
    '        - dgVoodoo2、Locale Emulator',
    '      用于：目标机器完全离线。拷过去解压就能修，全程不联网。',
    '',
    '【与 GitHub 公开版的区别】',
    '',
    '  公开仓库 https://github.com/rinttt233/Touhou-Runtime-Doctor 收录【完整源码】，',
    '  包括抓取脚本 tools\Fetch-OfflinePack.ps1，但【不含 offline\ 里的载荷】——',
    '  各类运行库、DirectX DLL、第三方工具包体积大且属可再分发组件，不放进 Git。',
    '  本目录下的 lite/full 压缩包是【本地构建产物】：',
    '    lite  仅工具本体（含抓取脚本），首次使用前跑一次抓取即可补齐载荷；',
    '    full  另含上面那份 offline\ 载荷，可拷到完全离线的机器上直接用，',
    '          连抓取这一步都不需要。',
    '  也就是说两条路都通：从仓库 clone 出来先抓载荷，或者直接用 full 包。',
    '',
    '【怎么用】',
    '',
    '  1) 解压到任意目录（路径尽量纯英文，避免中文与空格）。',
    '',
    '  2) 先双击「自检.bat」',
    '     它会实测工具在本机所需的每一项能力（注册表读写、哈希、解压、WMI、',
    '     PE 解析、备份还原等），直接告诉你这台机器能不能用。',
    '     Windows 7 出厂只有 PowerShell 2.0，自检会明确提示需要装什么。',
    '',
    '  3) 双击「一键修复.bat」',
    '     自动请求管理员权限 → 体检 → 修复 → 真机启动验证 → 出报告。',
    '',
    '  4) 想单独看设备情况：双击「设备信息.bat」',
    '     只读采集，输出四种格式到「报告」文件夹：',
    '       设备信息.txt        完整文本（GBK，记事本直接可读）',
    '       设备信息-精简.txt    一屏摘要，适合发到论坛求助',
    '       设备信息.html       带表格与配色，适合快速扫读',
    '       设备信息.json       结构化数据，适合跨机器对比',
    '',
    '  5) 想撤销修复：双击「回滚.bat」',
    '',
    '【四个入口】',
    '',
    '  一键修复.bat   体检 + 修复 + 启动验证（需要管理员权限）',
    '  仅体检.bat     只读体检，不改动任何东西',
    '  自检.bat       实测工具自身能力，回答"这台机器能不能用"',
    '  设备信息.bat   只读采集全机设备与系统信息',
    '  回滚.bat       撤销最近一次修复的全部改动',
    '',
    '【详细说明】',
    '',
    '  完整文档见「使用说明.txt」。',
    '  离线载荷的目录用途见「offline\README.txt」。',
    '',
    '【安全说明】',
    '',
    '  * 本工具所有修改动作都会先备份，改动记入 backup\<时间戳>\journal.json，',
    '    可用「回滚.bat」整体撤销。',
    '  * 注册表改动采用逐值记录修改前状态，能正确删除"修复时新增的值"，',
    '    而不是只做整体导入（那样删不掉新增项，回滚会留残留）。',
    '  * 「设备信息.bat」「仅体检.bat」「自检.bat」为纯只读，可放心运行。',
    '  * 离线载荷全部来自微软官方或开源项目官方地址，下载时已校验 SHA256，',
    '    对微软来源的文件还校验了数字签名。',
    '',
    '================================================================================'
)
$readmePath = Join-Path $outDir '打包说明.txt'
[System.IO.File]::WriteAllText($readmePath, ($readmeLines -join "`r`n"), [System.Text.Encoding]::GetEncoding(936))
Write-Item 'OK' "打包说明.txt"

# ---------------------------------------------------------------------------
#  生成两个包
# ---------------------------------------------------------------------------
$built = New-Object System.Collections.ArrayList
$doFull = -not $LiteOnly
$doLite = -not $FullOnly

if ($doLite) {
    Write-Head '生成 lite 包（不含离线载荷）'
    $liteStage = Join-Path $stageRoot "$pkgName-lite"
    if (Test-Path -LiteralPath $liteStage) { Remove-Item -LiteralPath $liteStage -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $liteStage -Force

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stat = Copy-ToolTree -Destination $liteStage
    $sw.Stop()
    Write-Item 'OK' ("复制 {0} 个文件（跳过隐私/历史 {1} 个，跳过载荷 {2} 个），用时 {3:N1} 秒" -f `
        $stat.Copied, $stat.Skipped, $stat.PayloadSkipped, $sw.Elapsed.TotalSeconds) 'Green'

    Copy-Item -LiteralPath $readmePath -Destination (Join-Path $liteStage '打包说明.txt') -Force

    if (-not $NoZip) {
        $zipPath = Join-Path $distRoot "$pkgName-lite.zip"
        Write-Item '..' "压缩中 ..."
        $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
        $zi = New-ZipPackage -SourceDir $liteStage -ZipPath $zipPath -Level Optimal
        $sw2.Stop()
        $null = $built.Add([PSCustomObject]@{ Kind = 'lite'; Path = $zipPath; SizeMB = [Math]::Round($zi.Length / 1MB, 2); Sha256 = (Get-Sha256 -Path $zipPath) })
        Write-Item 'OK' ("{0}  {1} MB  用时 {2:N1} 秒" -f $zi.Name, [Math]::Round($zi.Length / 1MB, 2), $sw2.Elapsed.TotalSeconds) 'Green'
    }
}

if ($doFull) {
    Write-Head '生成 full 包（含离线载荷，约 200 MB）'
    $fullStage = Join-Path $stageRoot "$pkgName-full"
    if (Test-Path -LiteralPath $fullStage) { Remove-Item -LiteralPath $fullStage -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $fullStage -Force

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stat = Copy-ToolTree -Destination $fullStage -IncludePayload
    $sw.Stop()
    Write-Item 'OK' ("复制 {0} 个文件（跳过隐私/历史 {1} 个），用时 {2:N1} 秒" -f `
        $stat.Copied, $stat.Skipped, $sw.Elapsed.TotalSeconds) 'Green'

    Copy-Item -LiteralPath $readmePath -Destination (Join-Path $fullStage '打包说明.txt') -Force

    # 载荷已经是压缩过的安装包，再"最优压缩"几乎不省空间却要多花十几倍时间，
    # 因此 full 包用 Fastest。
    if (-not $NoZip) {
        $zipPath = Join-Path $distRoot "$pkgName-full.zip"
        Write-Item '..' "压缩中（大包，请稍候）..."
        $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
        $zi = New-ZipPackage -SourceDir $fullStage -ZipPath $zipPath -Level Fastest
        $sw2.Stop()
        $null = $built.Add([PSCustomObject]@{ Kind = 'full'; Path = $zipPath; SizeMB = [Math]::Round($zi.Length / 1MB, 2); Sha256 = (Get-Sha256 -Path $zipPath) })
        Write-Item 'OK' ("{0}  {1} MB  用时 {2:N1} 秒" -f $zi.Name, [Math]::Round($zi.Length / 1MB, 2), $sw2.Elapsed.TotalSeconds) 'Green'
    }
}

# ---------------------------------------------------------------------------
#  校验值
# ---------------------------------------------------------------------------
if ($built.Count -gt 0) {
    Write-Head '生成校验值'
    $sumFile = Join-Path $distRoot 'SHA256SUMS.txt'
    $lines = New-Object System.Collections.ArrayList
    $null = $lines.Add("# Touhou Runtime Doctor $version  打包于 $stamp")
    $null = $lines.Add('# 校验方式：  certutil -hashfile <文件> SHA256')
    $null = $lines.Add('#       或：  Get-FileHash <文件> -Algorithm SHA256')
    $null = $lines.Add('')

    # 扫描 dist 下**全部** zip 来生成校验值，而不是只写本次构建的那些。
    # 否则单独构建一次（例如只 -LiteOnly）会把另一个包的校验值覆盖掉，
    # 校验文件与实际产物就不一致了。
    $allZips = @(Get-ChildItem -LiteralPath $distRoot -File -Filter '*.zip' -ErrorAction SilentlyContinue |
                 Sort-Object Name)
    if ($allZips.Count -gt 0) {
        foreach ($z in $allZips) {
            $h = Get-Sha256 -Path $z.FullName
            $null = $lines.Add(("{0}  {1}" -f $h, $z.Name))
            if (-not @($built | Where-Object { $_.Path -eq $z.FullName }).Count) {
                $null = $built.Add([PSCustomObject]@{
                    Kind = $(if ($z.Name -like '*-full.zip') { 'full' } else { 'lite' })
                    Path = $z.FullName
                    SizeMB = [Math]::Round($z.Length / 1MB, 2)
                    Sha256 = $h
                })
            }
        }
    }
    [System.IO.File]::WriteAllText($sumFile, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Item 'OK' "SHA256SUMS.txt（含 dist 下全部 $($allZips.Count) 个压缩包）"

    Write-Host ''
    # 注意必须用括号包住 -f 表达式：在命令参数模式下 Write-Host 会把 -f
    # 当成自己的参数去解析，报 "Cannot bind parameter 'ForegroundColor'"。
    Write-Host ('  {0,-8} {1,-46} {2,10}  {3}' -f '类型', '文件', '大小', 'SHA256(前16位)') -ForegroundColor DarkGray
    Write-Host ('  ' + ('-' * 96)) -ForegroundColor DarkGray
    foreach ($b in ($built | Sort-Object Kind)) {
        Write-Host ('  {0,-8} {1,-46} {2,8} MB  {3}...' -f $b.Kind, (Split-Path -Leaf $b.Path), $b.SizeMB, $b.Sha256.Substring(0, 16)) -ForegroundColor White
    }
}

# ---------------------------------------------------------------------------
#  清理暂存
# ---------------------------------------------------------------------------
if (-not $KeepStaging) {
    Write-Host ''
    Write-Item '..' '清理暂存目录 ...'
    Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Item 'OK' '已清理（需要检查内容时加 -KeepStaging）'
} else {
    Write-Host ''
    Write-Item 'OK' "暂存目录保留在: $stageRoot"
}

Write-Head '打包完成'
Write-Host ''
Write-Item 'OK' "输出目录: $distRoot" 'Green'
Write-Host ''
Write-Host '  lite 包给能联网的机器用；full 包给完全离线的机器用。' -ForegroundColor Gray
Write-Host '  full 包拷到目标机器解压后，双击「自检.bat」确认环境，再双击「一键修复.bat」。' -ForegroundColor Gray
Write-Host ''

exit 0
