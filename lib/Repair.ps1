# ============================================================================
#  Repair.ps1 -- 修复引擎
#
#  设计原则：
#   1. 先备份，后动手。所有文件改动与注册表写入都记入 journal.json，可整体回滚。
#   2. 每个动作执行后必须验证。装完运行库要重新解析依赖确认真的解决了，
#      而不是"命令返回 0 就当成功"。
#   3. 载荷先自检再用。第三方工具（Locale Emulator / dgVoodoo2）解包后必须
#      证明它真的能跑，否则明确报告"载荷不完整"，绝不生成跑不通的启动器。
#   4. 危险或改变系统行为的动作默认不自动执行，需要显式开关。
# ============================================================================
Set-StrictMode -Version 2.0

# 需要管理员权限的修复动作
$script:TRD_ADMIN_FIXES = @(
    'FIX_INSTALL_PACKAGE', 'FIX_INSTALL_VC_NEEDED', 'FIX_INSTALL_VC_ALL',
    'FIX_GRANT_WRITE', 'FIX_DEFENDER_EXCLUDE', 'FIX_INSTALL_FONT',
    'FIX_ENABLE_MSI_SERVICE', 'FIX_START_AUDIO_SERVICE', 'FIX_DEPLOY_DX_SYSTEM'
)

# 会改变渲染/区域行为、需要用户显式同意的动作
$script:TRD_RISKY_FIXES = @(
    'FIX_DEPLOY_DGVOODOO', 'FIX_MIGRATE_ASCII_PATH', 'FIX_DEPLOY_LOCALE_EMULATOR'
)

# ---------------------------------------------------------------------------
#  计划构建
# ---------------------------------------------------------------------------
function New-TrdRepairPlan {
    <#
    .SYNOPSIS
        把体检结论翻译成有序的修复计划。
    .DESCRIPTION
        顺序很重要：
          1) 先排除障碍（隔离位数错误的 DLL、解除文件锁定标记）
          2) 再补齐运行库（DirectX / VC）
          3) 然后调环境（兼容性标记、目录权限、显示配置）
          4) 最后生成启动入口
        因为前一类的失败会让后一类的验证结果失真。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Diagnosis,
        [switch]$IncludeRisky,
        [switch]$IncludeOptional,
        [string[]]$OnlyFixIds = @()
    )

    $order = @{
        # 先修"能不能修"的前提，再修游戏本身。
        # 音频服务/安装服务属于环境前提：音频服务没起来游戏直接退，
        # 安装服务被禁用则后面所有运行库安装都会静默失败。
        'FIX_ENABLE_DX_ACCELERATION'    = 4
        'FIX_DISABLE_ACCESSIBILITY'     = 7
        'FIX_ADD_ENGLISH_LAYOUT'        = 8
        'FIX_RESET_DINPUT'              = 9
        'FIX_ENABLE_MSI_SERVICE'        = 5
        'FIX_START_AUDIO_SERVICE'       = 6
        'FIX_QUARANTINE_WRONG_BITNESS'  = 10
        'FIX_UNBLOCK_FILES'             = 15
        'FIX_INSTALL_PACKAGE'           = 20
        'FIX_INSTALL_VC_NEEDED'         = 21
        'FIX_DEPLOY_DLL_LOCAL'          = 25
        'FIX_INSTALL_VC_ALL'            = 30
        'FIX_DEPLOY_DX_SYSTEM'          = 32
        'FIX_GRANT_WRITE'               = 40
        'FIX_RESET_CFG'                 = 45
        'FIX_SET_COMPAT_FLAGS'          = 50
        'FIX_REMOVE_SCANCODE_MAP'       = 33
        'FIX_QUARANTINE_SHADOWED'       = 55
        'FIX_GRANT_WRITE_RECHECK'       = 56
        'FIX_MIGRATE_ASCII_PATH'        = 60
        'FIX_DEPLOY_DGVOODOO'           = 70
        'FIX_DEPLOY_LOCALE_EMULATOR'    = 71
        'FIX_INSTALL_FONT'              = 75
        'FIX_DEFENDER_EXCLUDE'          = 80
        'FIX_CREATE_LAUNCHER'           = 90
    }

    # 这些 FixId 属于"可选增强"，只有显式要求才纳入
    $optionalFixes = @('FIX_INSTALL_VC_ALL', 'FIX_DEFENDER_EXCLUDE', 'FIX_DEPLOY_DGVOODOO', 'FIX_MIGRATE_ASCII_PATH')

    # 这些 FixId 会改动系统服务/策略，需要管理员权限
    $script:TRD_STEP_ADMIN = @('FIX_ENABLE_MSI_SERVICE', 'FIX_START_AUDIO_SERVICE')

    $steps = New-Object System.Collections.ArrayList
    $seen = @{}

    foreach ($f in $Diagnosis.Findings) {
        if ($f.Severity -eq 'Pass') { continue }
        if (-not $f.FixId) { continue }
        if ($OnlyFixIds.Count -gt 0 -and $OnlyFixIds -notcontains $f.FixId) { continue }
        if ($optionalFixes -contains $f.FixId -and -not $IncludeOptional) { continue }
        if ($script:TRD_RISKY_FIXES -contains $f.FixId -and -not $IncludeRisky) { continue }

        # 同一 FixId 多个 finding 时合并，保留最严重的
        if ($seen.ContainsKey($f.FixId)) {
            $existing = $seen[$f.FixId]
            if ((Get-TrdSeverityRank -Severity $f.Severity) -lt (Get-TrdSeverityRank -Severity $existing.Severity)) {
                $existing.Severity = $f.Severity
            }
            $null = $existing.Findings.Add($f)
            continue
        }

        $step = [PSCustomObject]@{
            FixId      = $f.FixId
            Category   = $f.Category
            Title      = $f.Title
            Severity   = $f.Severity
            FixHint    = $f.FixHint
            NeedsPkg   = $f.NeedsPackage
            Findings   = (New-Object System.Collections.ArrayList)
            Order      = $(if ($order.ContainsKey($f.FixId)) { $order[$f.FixId] } else { 99 })
            NeedsAdmin = ($script:TRD_ADMIN_FIXES -contains $f.FixId)
            Status     = 'Pending'
            Result     = $null
        }
        $null = $step.Findings.Add($f)
        $seen[$f.FixId] = $step
        $null = $steps.Add($step)
    }

    return @($steps | Sort-Object Order)
}

# ---------------------------------------------------------------------------
#  离线包安装
# ---------------------------------------------------------------------------
function Expand-TrdRedistCabs {
    <#
    .SYNOPSIS
        把 DirectX 自解压包解包到临时目录，返回含 dxsetup.exe 的目录。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SelfExtractor,
        [Parameter(Mandatory = $true)][string]$DestDir
    )

    if (Test-Path -LiteralPath $DestDir) { Remove-Item -LiteralPath $DestDir -Recurse -Force -ErrorAction SilentlyContinue }
    $null = New-Item -ItemType Directory -Path $DestDir -Force

    Write-TrdLog "解包 $([System.IO.Path]::GetFileName($SelfExtractor)) ..." 'Step'
    # 自解压包的 /T: 目标路径若含空格必须整体加引号，否则会被截断
    $argLine = ConvertTo-TrdArgString @('/Q', "/T:$DestDir")
    $p = Start-Process -FilePath $SelfExtractor -ArgumentList $argLine -Wait -PassThru -NoNewWindow
    Write-TrdLog "解包进程退出码: $($p.ExitCode)" 'Detail'

    $setup = Get-ChildItem -LiteralPath $DestDir -Recurse -Filter 'DXSETUP.exe' -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($setup) { return $setup.DirectoryName }
    return $null
}

function Get-TrdDllFromRedist {
    <#
    .SYNOPSIS
        用系统自带 expand.exe 从解包后的 DirectX cab 中提取指定 DLL。
    .DESCRIPTION
        这条路径的意义：系统目录里的旧版 DirectX 组件受 Windows 文件保护，
        直接覆盖会被拒绝。改为把 DLL 放到游戏目录（exe 同级目录优先级最高），
        既绕开系统文件保护，又能精确回滚，且只影响这一个游戏。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CabRoot,
        [Parameter(Mandatory = $true)][string]$DllName,
        [Parameter(Mandatory = $true)][string]$OutDir
    )

    $expand = Join-Path $env:windir 'System32\expand.exe'
    if (-not (Test-Path -LiteralPath $expand)) {
        return [PSCustomObject]@{ Ok = $false; Path = $null; Reason = '系统缺少 expand.exe' }
    }
    if (-not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }

    # 目标文件已解出过就直接复用
    $existing = Get-ChildItem -LiteralPath $OutDir -Recurse -Filter $DllName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing) { return [PSCustomObject]@{ Ok = $true; Path = $existing.FullName; Reason = $null } }

    $cabs = @(Get-ChildItem -LiteralPath $CabRoot -Recurse -Filter '*.cab' -ErrorAction SilentlyContinue)
    if ($cabs.Count -eq 0) {
        return [PSCustomObject]@{ Ok = $false; Path = $null; Reason = '解包目录中没有 cab 文件' }
    }

    Write-TrdLog "在 $($cabs.Count) 个 cab 中查找 $DllName ..." 'Step'
    foreach ($cab in $cabs) {
        # 必须显式加引号：expand.exe 的路径参数含空格时，数组形式的 -ArgumentList
        # 会被 PowerShell 直接用空格拼接而不加引号，导致参数被截断。
        $argLine = ConvertTo-TrdArgString @($cab.FullName, "-F:$DllName", $OutDir)
        $p = Start-Process -FilePath $expand -ArgumentList $argLine `
             -Wait -PassThru -NoNewWindow -ErrorAction SilentlyContinue
        if ($p.ExitCode -eq 0) {
            $hit = Get-ChildItem -LiteralPath $OutDir -Recurse -Filter $DllName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) {
                Write-TrdLog "已从 $($cab.Name) 提取 $DllName" 'OK'
                return [PSCustomObject]@{ Ok = $true; Path = $hit.FullName; Reason = $null }
            }
        }
    }
    return [PSCustomObject]@{ Ok = $false; Path = $null; Reason = "所有 cab 中均未找到 $DllName" }
}

function Install-TrdPackage {
    <#
    .SYNOPSIS
        按载荷清单安装一个离线修复包，并在安装后做验证。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackageId,
        [string]$OfflineRoot,
        [switch]$AllowDownload
    )

    $manifest = Get-TrdOfflineManifest -OfflineRoot $OfflineRoot
    $pkg = $manifest.Packages | Where-Object { $_.Id -eq $PackageId } | Select-Object -First 1
    if (-not $pkg) {
        return [PSCustomObject]@{ Ok = $false; Message = "载荷清单里没有 [$PackageId] 这个包" }
    }

    Write-TrdLog "=== 安装修复包: $($pkg.Title) ===" 'Step'

    $found = Find-TrdOfflinePackage -Package $pkg -OfflineRoot $OfflineRoot
    if (-not $found.Found) {
        $urls = @()
        if (Test-TrdHasProp -Object $pkg -Name 'Url') { $urls = @($pkg.Url) }
        return [PSCustomObject]@{
            Ok      = $false
            Message = "离线载荷中缺少该文件: $(($pkg.Files) -join ' 或 ')"
            Hint    = (Get-TrdOfflineHint) +
                      $(if ($urls.Count -gt 0) { " 官方下载地址: $($urls[0])" } else { '' })
        }
    }
    if ($found.HashOk -eq $false) {
        Write-TrdLog "SHA256 校验不通过！文件可能已损坏或被篡改。" 'Warn'
        return [PSCustomObject]@{ Ok = $false; Message = '载荷文件 SHA256 与清单不符，已中止安装以确保安全。' }
    }
    Write-TrdLog "载荷文件: $($found.Path) ($($found.SizeMB) MB)" 'Detail'

    $kind = if (Test-TrdHasProp -Object $pkg -Name 'InstallKind') { $pkg.InstallKind } else { 'vcredist_exe' }
    $silent = if (Test-TrdHasProp -Object $pkg -Name 'SilentArgs') { $pkg.SilentArgs } else { '' }

    if ($script:TRD.DryRun) {
        Write-TrdLog "[演练] 将执行安装: $kind / $($found.Path) $silent" 'Info'
        return [PSCustomObject]@{ Ok = $true; Message = '演练模式，未实际安装' }
    }

    try {
        switch ($kind) {
            'dxsetup_selfextract' {
                # 优先用已经解包好的 dxsetup.exe，否则现解包
                $dxDir = $null
                $pre = @($pkg.Files | Where-Object { $_ -like '*dxsetup.exe' })
                foreach ($rel in $pre) {
                    $cand = Join-Path $OfflineRoot $rel
                    if (Test-Path -LiteralPath $cand) { $dxDir = Split-Path -Parent $cand; break }
                }
                if (-not $dxDir) {
                    $tmp = Join-Path $env:TEMP ('trd_dx_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
                    $dxDir = Expand-TrdRedistCabs -SelfExtractor $found.Path -DestDir $tmp
                }
                if (-not $dxDir) {
                    return [PSCustomObject]@{ Ok = $false; Message = '解包 DirectX 运行库失败（未找到 DXSETUP.exe）' }
                }

                $setup = Join-Path $dxDir 'DXSETUP.exe'
                Write-TrdLog "运行 DXSETUP.exe $silent（静默安装，可能需要 1-3 分钟）..." 'Step'
                $p = Start-Process -FilePath $setup -ArgumentList $silent -WorkingDirectory $dxDir -Wait -PassThru
                Write-TrdLog "DXSETUP 退出码: $($p.ExitCode)" 'Detail'

                # 记录解包目录，供后续"提取单个 DLL 部署到游戏目录"使用
                $null = $script:TRD.Journal.Add([PSCustomObject]@{
                    Kind = 'Note'; Target = 'DX_EXTRACT_DIR'; Backup = $dxDir; Existed = $true
                })
                $script:TRD_DX_EXTRACT_DIR = $dxDir

                return [PSCustomObject]@{
                    Ok = ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010)
                    Message = "DXSETUP 退出码 $($p.ExitCode)（3010 表示需要重启才能完全生效）"
                    Reboot = ($p.ExitCode -eq 3010)
                }
            }

            'vcredist_exe' {
                Write-TrdLog "运行 $(Split-Path -Leaf $found.Path) $silent ..." 'Step'
                $p = Start-Process -FilePath $found.Path -ArgumentList $silent -Wait -PassThru
                $ok = ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010 -or $p.ExitCode -eq 1638)
                $msg = switch ($p.ExitCode) {
                    0     { '安装成功' }
                    3010  { '安装成功，需要重启才能完全生效' }
                    1638  { '系统已存在更新版本，无需安装' }
                    5100  { '系统不满足安装条件（通常是没有管理员权限）' }
                    default { "安装程序返回退出码 $($p.ExitCode)" }
                }
                return [PSCustomObject]@{ Ok = $ok; Message = $msg; Reboot = ($p.ExitCode -eq 3010) }
            }

            'zip_tool' {
                $dest = Join-Path $OfflineRoot ('Tools\' + $PackageId)
                $null = New-Item -ItemType Directory -Path $dest -Force
                Write-TrdLog "解压到 $dest ..." 'Step'
                # 走 Expand-TrdArchive 而不是直接用 Expand-Archive：
                # 后者是 PowerShell 5.0 才有的，Win7 默认环境上不存在。
                $null = Expand-TrdArchive -ZipPath $found.Path -Destination $dest
                return [PSCustomObject]@{ Ok = $true; Message = "已解压到 $dest"; Dest = $dest }
            }

            default {
                return [PSCustomObject]@{ Ok = $false; Message = "未知的安装类型: $kind" }
            }
        }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Message = "安装过程出错: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------
#  各修复动作
# ---------------------------------------------------------------------------
function Invoke-TrdQuarantineWrongBitness {
    param([Parameter(Mandatory = $true)]$Diagnosis)

    $items = @($Diagnosis.Deps.WrongBitness)
    if ($items.Count -eq 0) { return [PSCustomObject]@{ Ok = $true; Message = '没有需要隔离的文件' } }

    $okCount = 0
    foreach ($it in $items) {
        if ($script:TRD.DryRun) {
            Write-TrdLog "[演练] 将隔离位数错误的 DLL: $($it.Name)" 'Info'; $okCount++; continue
        }
        $qDir = Join-Path $script:TRD.SessionDir 'quarantine_wrong_bitness'
        $null = New-Item -ItemType Directory -Path $qDir -Force
        $dest = Join-Path $qDir $it.Name
        try {
            Copy-Item -LiteralPath $it.Path -Destination $dest -Force -ErrorAction Stop
            $null = $script:TRD.Journal.Add([PSCustomObject]@{
                Kind = 'File'; Target = $it.Path; Backup = $dest; Existed = $true
            })
            Remove-Item -LiteralPath $it.Path -Force -ErrorAction Stop
            Write-TrdLog "已隔离: $($it.Name)（$($it.Arch) 位，应为 $($it.Expected) 位）" 'OK'
            $okCount++
        } catch {
            Write-TrdLog "隔离失败 $($it.Name): $($_.Exception.Message)" 'Error'
        }
    }
    return [PSCustomObject]@{ Ok = ($okCount -eq $items.Count); Message = "已隔离 $okCount/$($items.Count) 个文件（原文件已备份，可用 -Rollback 还原）" }
}

function Invoke-TrdQuarantineShadowed {
    param([Parameter(Mandatory = $true)]$Diagnosis)

    $items = @($Diagnosis.Deps.Shadowed)
    if ($items.Count -eq 0) { return [PSCustomObject]@{ Ok = $true; Message = '没有需要处理的文件' } }

    $okCount = 0
    foreach ($it in $items) {
        if ($script:TRD.DryRun) { Write-TrdLog "[演练] 将隔离旧版 DLL: $($it.Dll)" 'Info'; $okCount++; continue }
        $qDir = Join-Path $script:TRD.SessionDir 'quarantine_shadowed'
        $null = New-Item -ItemType Directory -Path $qDir -Force
        $dest = Join-Path $qDir $it.Dll
        try {
            Copy-Item -LiteralPath $it.Local -Destination $dest -Force -ErrorAction Stop
            $null = $script:TRD.Journal.Add([PSCustomObject]@{
                Kind = 'File'; Target = $it.Local; Backup = $dest; Existed = $true
            })
            Remove-Item -LiteralPath $it.Local -Force -ErrorAction Stop
            Write-TrdLog "已隔离旧版: $($it.Dll)（本地 $($it.LocalVer) → 改用系统 $($it.SystemVer)）" 'OK'
            $okCount++
        } catch {
            Write-TrdLog "隔离失败 $($it.Dll): $($_.Exception.Message)" 'Error'
        }
    }
    return [PSCustomObject]@{ Ok = ($okCount -eq $items.Count); Message = "已隔离 $okCount/$($items.Count) 个文件" }
}

function Invoke-TrdUnblockFiles {
    param([Parameter(Mandatory = $true)]$Diagnosis)

    $folder = $Diagnosis.Game.Folder
    $count = 0
    $targets = @(Get-ChildItem -LiteralPath $folder -Recurse -File -ErrorAction SilentlyContinue)
    foreach ($t in $targets) {
        if ($script:TRD.DryRun) { continue }
        try {
            $streams = Get-Item -LiteralPath $t.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue
            if ($streams) {
                Unblock-File -LiteralPath $t.FullName -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $t.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue
                $count++
            }
        } catch { }
    }
    if ($script:TRD.DryRun) {
        $motw = @($targets | Where-Object { Test-TrdMotW -Path $_.FullName }).Count
        Write-TrdLog "[演练] 将解除 $motw 个文件的 Internet 标记" 'Info'
        return [PSCustomObject]@{ Ok = $true; Message = "演练：$motw 个文件待解除" }
    }
    return [PSCustomObject]@{ Ok = $true; Message = "已解除 $count 个文件的 Internet 标记" }
}

function Invoke-TrdSetCompatFlags {
    <#
    .SYNOPSIS
        为游戏目录内全部 exe 写入兼容性标记。
    .DESCRIPTION
        要点：必须覆盖目录内【所有】可执行文件，而不只是 th08.exe。
        因为实际启动器是 vpatch.exe，兼容性标记是按镜像路径生效的，
        只标 th08.exe 会导致通过 vpatch 启动时 DPI 修正不生效。
    #>
    param(
        [Parameter(Mandatory = $true)]$Diagnosis,
        [switch]$IncludeFullscreenOpt
    )

    $key = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
    $folder = $Diagnosis.Game.Folder

    $exes = @($Diagnosis.Deps.Exes | Where-Object { $_.Ok -and $_.Name -match '\.exe$' } | ForEach-Object { $_.Path })
    if ($Diagnosis.Game.LauncherExe) { $exes += $Diagnosis.Game.LauncherExe }
    $exes = @($exes | Sort-Object -Unique)

    if ($exes.Count -eq 0) { return [PSCustomObject]@{ Ok = $false; Message = '没有找到可执行文件' } }

    $flagSet = @('HIGHDPIAWARE')
    if ($IncludeFullscreenOpt) {
        # 渲染相关的兼容标记必须按操作系统世代选： Win7 用 DISABLEDWM（关桌面组合），
        # Win8+ 用 DISABLEDXMAXIMIZEDWINDOWEDMODE（关全屏优化）。
        # 在 Win7 上写全屏优化的标记是无效的，写了也不会生效。
        $osInfo = Get-TrdWindowsBuild
        if ($osInfo.IsWin7) {
            $flagSet += 'DISABLEDWM'
        } elseif ($osInfo.IsWin8OrNewer) {
            $flagSet += 'DISABLEDXMAXIMIZEDWINDOWEDMODE'
        }
    }

    if (-not $script:TRD.DryRun) {
        if (-not (Test-Path -LiteralPath $key)) { $null = New-Item -Path $key -Force }
        $null = Backup-TrdRegKey -RegPath 'HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers' -Tag 'appcompat'
    }

    $okCount = 0
    foreach ($exe in $exes) {
        $existing = [string](Get-TrdRegValue -RegPath $key -Name $exe)
        $flags = New-Object System.Collections.ArrayList
        foreach ($f in ($existing -replace '^\s*~\s*', '') -split '\s+') {
            if ($f) { $null = $flags.Add($f) }
        }
        foreach ($f in $flagSet) {
            if ($flags -notcontains $f) { $null = $flags.Add($f) }
        }
        $value = '~ ' + ($flags -join ' ')

        if ($script:TRD.DryRun) {
            Write-TrdLog "[演练] 将设置 $([System.IO.Path]::GetFileName($exe)) => $value" 'Info'; $okCount++; continue
        }
        if (Set-TrdRegValue -RegPath $key -Name $exe -Value $value -Type String -BackupTag 'appcompat') {
            Write-TrdLog "兼容性标记: $([System.IO.Path]::GetFileName($exe)) => $value" 'OK'
            $okCount++
        }
    }
    return [PSCustomObject]@{ Ok = ($okCount -eq $exes.Count); Message = "已为 $okCount/$($exes.Count) 个程序写入兼容性标记：$($value)" }
}

function Invoke-TrdResetCfg {
    param([Parameter(Mandatory = $true)]$Diagnosis)

    $cfg = Join-Path $Diagnosis.Game.Folder ("{0}.cfg" -f $Diagnosis.Game.Id)
    if (-not (Test-Path -LiteralPath $cfg)) {
        return [PSCustomObject]@{ Ok = $true; Message = '配置文件不存在，无需重置' }
    }
    if ($script:TRD.DryRun) {
        Write-TrdLog "[演练] 将备份并重置 $([System.IO.Path]::GetFileName($cfg))" 'Info'
        return [PSCustomObject]@{ Ok = $true; Message = '演练模式' }
    }

    $bk = Backup-TrdFile -Path $cfg -Tag 'cfg'
    if (-not $bk) { return [PSCustomObject]@{ Ok = $false; Message = '备份配置文件失败，已中止重置以免丢失原设置' } }
    try {
        Remove-Item -LiteralPath $cfg -Force -ErrorAction Stop
        Write-TrdLog "已备份并重置显示配置: $([System.IO.Path]::GetFileName($cfg))（游戏下次启动会生成默认配置）" 'OK'
        return [PSCustomObject]@{ Ok = $true; Message = "原配置已备份到 $bk，游戏将重新生成默认配置（窗口 640x480）" }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Message = "重置失败: $($_.Exception.Message)" }
    }
}

function Invoke-TrdGrantWrite {
    param([Parameter(Mandatory = $true)]$Diagnosis)

    $folder = $Diagnosis.Game.Folder
    if ($script:TRD.DryRun) {
        Write-TrdLog "[演练] 将授予当前用户对 $folder 的修改权限" 'Info'
        return [PSCustomObject]@{ Ok = $true; Message = '演练模式' }
    }

    $user = "$env:USERDOMAIN\$env:USERNAME"
    try {
        # 游戏目录名常含空格与方括号（如 "[th08] 东方永夜抄 (汉)"），必须加引号
        $argLine = ConvertTo-TrdArgString @($folder, '/grant', "${user}:(OI)(CI)M", '/T', '/C', '/Q')
        $p = Start-Process -FilePath "$env:windir\System32\icacls.exe" `
             -ArgumentList $argLine -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -eq 0) {
            $w = Test-TrdWritable -Dir $folder
            Write-TrdLog "已授予 $user 修改权限（写测试: $w）" 'OK'
            return [PSCustomObject]@{ Ok = $w; Message = "已授予 $user 修改权限" }
        }
        return [PSCustomObject]@{ Ok = $false; Message = "icacls 返回退出码 $($p.ExitCode)" }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Message = "授权失败: $($_.Exception.Message)" }
    }
}

function Invoke-TrdCreateLauncher {
    <#
    .SYNOPSIS
        生成正确的启动入口。
    .DESCRIPTION
        存在 vpatch 时必须通过 vpatch.exe 启动，否则绕过帧率补丁与汉化补丁。
        同时生成一个纯 ASCII 文件名的启动器，便于在任何区域设置下双击。
    #>
    param([Parameter(Mandatory = $true)]$Diagnosis)

    $game = $Diagnosis.Game
    $folder = $game.Folder
    $launcherName = "启动-$($game.Id).bat"
    $launcherPath = Join-Path $folder $launcherName

    $target = if ($game.LauncherExe) { Split-Path -Leaf $game.LauncherExe } else { Split-Path -Leaf $game.MainExe }

    $lines = @(
        '@echo off',
        'rem ===================================================================',
        "rem  $($game.DisplayName)",
        'rem  由 Touhou Runtime Doctor 自动生成。',
        'rem ===================================================================',
        'chcp 936 >nul 2>nul',
        'cd /d "%~dp0"',
        "start `"`" `"$target`"",
        'exit /b 0'
    )

    if ($script:TRD.DryRun) {
        Write-TrdLog "[演练] 将生成启动器 $launcherName（目标: $target）" 'Info'
        return [PSCustomObject]@{ Ok = $true; Message = '演练模式' }
    }

    try {
        # 批处理必须用系统 ANSI 代码页保存，cmd.exe 不认 UTF-8 BOM
        $enc = [System.Text.Encoding]::GetEncoding(936)
        [System.IO.File]::WriteAllText($launcherPath, ($lines -join "`r`n"), $enc)
        Write-TrdLog "已生成启动器: $launcherPath （通过 $target 启动）" 'OK'
        return [PSCustomObject]@{ Ok = $true; Message = "启动器已生成：$launcherName" }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Message = "生成启动器失败: $($_.Exception.Message)" }
    }
}

function Invoke-TrdDeployDgVoodoo {
    <#
    .SYNOPSIS
        把 dgVoodoo2 的包装 DLL 部署到游戏目录。
    .DESCRIPTION
        这是"最后手段"：当所有运行库都齐全、但画面仍然黑屏/花屏/崩溃时使用。
        原理是把 d3d8.dll / ddraw.dll 换成转发到现代 DirectX 11 的包装器。
        仅部署到游戏目录，不影响系统，回滚只需删除文件。
    #>
    param(
        [Parameter(Mandatory = $true)]$Diagnosis,
        [string]$OfflineRoot
    )

    $pkgId = 'TOOL_DGVOODOO2'
    $dest = Join-Path $OfflineRoot ('Tools\' + $pkgId)

    if (-not (Test-Path -LiteralPath $dest)) {
        $install = Install-TrdPackage -PackageId $pkgId -OfflineRoot $OfflineRoot
        if (-not $install.Ok) { return $install }
    }

    # dgVoodoo2 压缩包解压后会有一层版本目录，找到 MS\x86 真正所在
    $srcDir = Get-ChildItem -LiteralPath $dest -Recurse -Directory -Filter 'x86' -ErrorAction SilentlyContinue |
              Where-Object { $_.Parent.Name -eq 'MS' } | Select-Object -First 1
    if (-not $srcDir) {
        $srcDir = Get-ChildItem -LiteralPath $dest -Recurse -Directory -Filter 'x86' -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $srcDir) {
        return [PSCustomObject]@{ Ok = $false; Message = "dgVoodoo2 载荷结构异常：找不到 MS\x86 目录（$dest）" }
    }

    $folder = $Diagnosis.Game.Folder
    $map = @{
        'D3D8.dll'       = 'D3D8.dll'
        'D3DImm.dll'     = 'D3DImm.dll'
        'DDraw.dll'      = 'DDraw.dll'
        'dgVoodoo.conf'  = 'dgVoodoo.conf'
        'dgVoodooCpl.exe'= 'dgVoodooCpl.exe'
    }

    $okCount = 0
    foreach ($src in $map.Keys) {
        $s = Join-Path $srcDir.FullName $src
        if (-not (Test-Path -LiteralPath $s)) { continue }
        $d = Join-Path $folder $map[$src]
        if ($script:TRD.DryRun) { Write-TrdLog "[演练] 将部署 $($map[$src])" 'Info'; $okCount++; continue }
        try {
            if (Test-Path -LiteralPath $d) { $null = Backup-TrdFile -Path $d -Tag 'dgvoodoo_overwrite' }
            Copy-Item -LiteralPath $s -Destination $d -Force -ErrorAction Stop
            Write-TrdLog "已部署 $($map[$src]) → 游戏目录" 'OK'
            $okCount++
        } catch {
            Write-TrdLog "部署 $($map[$src]) 失败: $($_.Exception.Message)" 'Error'
        }
    }

    if ($okCount -eq 0) {
        return [PSCustomObject]@{ Ok = $false; Message = '没有成功部署任何文件' }
    }
    return [PSCustomObject]@{
        Ok      = $true
        Message = "已部署 $okCount 个兼容层文件到游戏目录。注意：这会改变渲染方式；如果画面变得异常，删除游戏目录下的 D3D8.dll / DDraw.dll / D3DImm.dll 即可恢复。"
    }
}

function Invoke-TrdDeployLocaleEmulator {
    <#
    .SYNOPSIS
        部署区域模拟启动器，并生成对应代码页的启动入口。
    .DESCRIPTION
        关键设计：部署后必须做一次【可执行性自检】。
        实测 GitHub 上 Locale Emulator v2.5.0.1 的发布包缺少 LECommonLibrary.dll，
        直接调用 LEProc.exe 会抛 FileNotFoundException。如果不自检就生成启动器，
        用户会拿到一个"点了没反应"的 bat，这比不修还糟糕。
        自检失败时明确报告载荷不完整，并改走"修改系统区域"的可靠方案。
    #>
    param(
        [Parameter(Mandatory = $true)]$Diagnosis,
        [string]$OfflineRoot,
        [int]$CodePage = 932
    )

    $pkgId = 'TOOL_LOCALE_EMULATOR'
    $dest = Join-Path $OfflineRoot ('Tools\' + $pkgId)

    if (-not (Test-Path -LiteralPath (Join-Path $dest 'LEProc.exe'))) {
        $install = Install-TrdPackage -PackageId $pkgId -OfflineRoot $OfflineRoot
        if (-not $install.Ok) { return $install }
        $dest = if ($install.Dest) { $install.Dest } else { $dest }
    }

    # 压缩包内可能还有一层目录
    $leProc = Get-ChildItem -LiteralPath $dest -Recurse -Filter 'LEProc.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $leProc) {
        return [PSCustomObject]@{ Ok = $false; Message = "载荷中找不到 LEProc.exe（$dest）" }
    }
    $leDir = $leProc.DirectoryName

    # ---------- 可执行性自检 ----------
    Write-TrdLog '对 Locale Emulator 做可执行性自检 ...' 'Step'
    $selfTestOk = $false
    $selfTestMsg = ''
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $leProc.FullName
        $psi.Arguments = '-run "C:\Windows\System32\cmd.exe"'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit(15000)) { try { $proc.Kill() } catch { } }
        $errText = $proc.StandardError.ReadToEnd()
        $outText = $proc.StandardOutput.ReadToEnd()
        $combined = "$errText $outText"

        if ($combined -match 'FileNotFoundException|Could not load file or assembly|未能加载文件或程序集|找不到文件') {
            $selfTestOk = $false
            $selfTestMsg = 'LEProc.exe 报告缺少依赖程序集（LECommonLibrary 等）'
        } elseif ($combined -match 'Usage:|Unhandled Exception') {
            $selfTestOk = $false
            $selfTestMsg = 'LEProc.exe 拒绝执行，参数或依赖异常'
        } else {
            $selfTestOk = $true
        }
    } catch {
        $selfTestOk = $false
        $selfTestMsg = "自检无法执行: $($_.Exception.Message)"
    }

    if (-not $selfTestOk) {
        Write-TrdLog "Locale Emulator 自检未通过：$selfTestMsg" 'Warn'
        Write-TrdLog '为避免生成一个点了没反应的启动器，本次不部署区域模拟方案。' 'Warn'
        return [PSCustomObject]@{
            Ok      = $false
            Message = "Locale Emulator 载荷不完整或无法运行（$selfTestMsg）。请改用手动方案（见报告中的『区域与编码』条目）。"
        }
    }

    Write-TrdLog 'Locale Emulator 自检通过。' 'OK'

    # ---------- 写 LEConfig.xml 并生成启动器 ----------
    $guid = '{3E9F1C42-7A5B-4D18-9C6E-2B8A4F1D0E73}'
    $locName = if ($CodePage -eq 932) { 'ja-JP' } elseif ($CodePage -eq 936) { 'zh-CN' } else { 'ja-JP' }
    $tzName  = if ($CodePage -eq 932) { 'Tokyo Standard Time' } else { 'China Standard Time' }

    $cfgPath = Join-Path $leDir 'LEConfig.xml'
    if (-not $script:TRD.DryRun) {
        if (Test-Path -LiteralPath $cfgPath) { $null = Backup-TrdFile -Path $cfgPath -Tag 'leconfig' }
        $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<LEConfig>
  <Profiles>
    <LEProfile Name="TRD Auto Profile" Guid="$guid">
      <Location>$locName</Location>
      <Timezone>$tzName</Timezone>
      <RunAsAdmin>false</RunAsAdmin>
      <RedirectRegistry>false</RedirectRegistry>
      <IsAdvancedRedirection>false</IsAdvancedRedirection>
      <RunWithSuspend>false</RunWithSuspend>
    </LEProfile>
  </Profiles>
</LEConfig>
"@
        [System.IO.File]::WriteAllText($cfgPath, $xml, (New-Object System.Text.UTF8Encoding($false)))
    }

    $game = $Diagnosis.Game
    $target = if ($game.LauncherExe) { $game.LauncherExe } else { $game.MainExe }
    $batName = "以日文区域启动-$($game.Id).bat"
    $batPath = Join-Path $game.Folder $batName
    $batLines = @(
        '@echo off',
        'rem 由 Touhou Runtime Doctor 生成：以指定区域/代码页启动游戏',
        'chcp 936 >nul 2>nul',
        'cd /d "%~dp0"',
        "start `"`" `"$($leProc.FullName)`" -runas $guid `"$target`"",
        'exit /b 0'
    )
    if ($script:TRD.DryRun) {
        Write-TrdLog "[演练] 将生成区域模拟启动器 $batName" 'Info'
        return [PSCustomObject]@{ Ok = $true; Message = '演练模式' }
    }
    [System.IO.File]::WriteAllText($batPath, ($batLines -join "`r`n"), [System.Text.Encoding]::GetEncoding(936))
    Write-TrdLog "已生成区域模拟启动器: $batPath" 'OK'
    return [PSCustomObject]@{ Ok = $true; Message = "已部署 Locale Emulator 并生成启动器 $batName（代码页 $CodePage）" }
}

function Invoke-TrdStartAudioService {
    <#
    .SYNOPSIS
        把 Windows Audio 服务恢复为自动启动并立即启动它。
    .DESCRIPTION
        被"系统优化"工具关停音频服务是很常见的环境问题，而东方系列
        在 DirectSound 初始化失败时会直接退出，用户看到的是"点了没反应"，
        极难联想到音频服务。
        注意只改 Audiosrv（音频服务本身），AudioEndpointBuilder 是它的
        依赖服务，一并确保可用；这两个改回去是安全的、可逆的常规配置。
    #>
    param([Parameter(Mandatory = $true)]$Diagnosis)

    if ($script:TRD.DryRun) {
        Write-TrdLog '[演练] 将把 Windows Audio 服务设为自动并启动' 'Info'
        return [PSCustomObject]@{ Ok = $true; Message = '演练模式' }
    }

    $results = New-Object System.Collections.ArrayList
    foreach ($name in @('AudioEndpointBuilder', 'Audiosrv')) {
        try {
            $s = Get-Service -Name $name -ErrorAction Stop

            # 先备份当前配置，便于回滚
            $null = Set-TrdRegValue -RegPath "HKLM:\SYSTEM\CurrentControlSet\Services\$name" `
                    -Name 'Start' -Value ([int]$s.StartType) -Type DWord -BackupTag 'services' 2>$null

            if ($s.StartType -ne 'Automatic') {
                Set-Service -Name $name -StartupType Automatic -ErrorAction Stop
            }
            if ($s.Status -ne 'Running') {
                Start-Service -Name $name -ErrorAction Stop
            }
            $after = Get-Service -Name $name
            $null = $results.Add([PSCustomObject]@{ Name = $name; Ok = ($after.Status -eq 'Running'); Status = $after.Status })
            Write-TrdLog "服务 $name -> $($after.Status)（启动类型 $($after.StartType)）" 'OK'
        } catch {
            $null = $results.Add([PSCustomObject]@{ Name = $name; Ok = $false; Status = $_.Exception.Message })
            Write-TrdLog "处理服务 $name 失败: $($_.Exception.Message)" 'Error'
        }
    }

    $okCount = @($results | Where-Object { $_.Ok }).Count
    return [PSCustomObject]@{
        Ok      = ($okCount -eq $results.Count)
        Message = "音频服务处理完成：$okCount/$($results.Count) 正常运行 —— " + (@($results | ForEach-Object { "$($_.Name):$($_.Status)" }) -join '; ')
    }
}

function Invoke-TrdEnableMsiService {
    <#
    .SYNOPSIS
        把 Windows Installer 服务的启动类型改回"手动"（并启动一次做验证）。
    .DESCRIPTION
        这个服务被禁用时，VC++ / DirectX 运行库的安装会静默失败，
        表现为"修复流程跑完了但什么都没变"。
        恢复成"手动"是 Windows 的默认配置：服务按需由安装程序拉起，
        不需要常驻，也不该被设为禁用。
    #>
    param([Parameter(Mandatory = $true)]$Diagnosis)

    if ($script:TRD.DryRun) {
        Write-TrdLog '[演练] 将把 Windows Installer 服务启动类型改回"手动"' 'Info'
        return [PSCustomObject]@{ Ok = $true; Message = '演练模式' }
    }

    try {
        $s = Get-Service -Name 'msiserver' -ErrorAction Stop

        # 备份原来的启动类型（注册表 Start 值：2=自动 3=手动 4=禁用）
        $null = Set-TrdRegValue -RegPath 'HKLM:\SYSTEM\CurrentControlSet\Services\msiserver' `
                -Name 'Start' -Value ([int]$s.StartType) -Type DWord -BackupTag 'services' 2>$null

        if ($s.StartType -eq 'Disabled') {
            Set-Service -Name 'msiserver' -StartupType Manual -ErrorAction Stop
            Write-TrdLog 'Windows Installer 服务的启动类型已从"禁用"改回"手动"' 'OK'
        } else {
            Write-TrdLog "Windows Installer 服务启动类型为 $($s.StartType)，无需修改（处于已停止是正常的）" 'Info'
        }

        # 真实验证：启动一次，确认服务确实能起来
        try {
            Start-Service -Name 'msiserver' -ErrorAction Stop
            $after = Get-Service -Name 'msiserver'
            return [PSCustomObject]@{ Ok = $true; Message = "验证通过：服务可正常启动（当前 $($after.Status)，启动类型 $($after.StartType)）" }
        } catch {
            return [PSCustomObject]@{ Ok = $false; Message = "启动类型已修正，但服务仍无法启动: $($_.Exception.Message)。运行库安装可能仍会失败。" }
        }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Message = "处理 Windows Installer 服务失败: $($_.Exception.Message)" }
    }
}

function Invoke-TrdDisableAccessibility {
    <#
    .SYNOPSIS
        关闭粘滞键 / 筛选键 / 切换键 / 鼠标键。
    .DESCRIPTION
        只清 Flags 的最低位（ON 标志），保留用户其他偏好设置位。
        直接清零整个 Flags 会连带丢掉快捷键、超时等个人设置。
    #>
    param([Parameter(Mandatory = $true)]$Diagnosis)
    if ($script:TRD.DryRun) {
        Write-TrdLog '[演练] 将关闭粘滞键/筛选键/切换键/鼠标键' 'Info'
        return [PSCustomObject]@{ Ok = $true; Message = '演练模式' }
    }
    $st = Get-TrdAccessibilityState
    $off = 0
    foreach ($it in @($st.Items | Where-Object { $_.Enabled })) {
        $newFlags = $it.Flags -band (-bnot 0x01)
        if (Set-TrdRegValue -RegPath $it.RegKey -Name 'Flags' -Value $newFlags -Type String -BackupTag 'a11y') {
            Write-TrdLog "$($it.Name) 已关闭（Flags $($it.Flags) -> $newFlags）" 'OK'
            $off++
        }
    }
    return [PSCustomObject]@{ Ok = $true; Message = "已关闭 $off 项辅助功能（需注销或重启后完全生效）" }
}

function Invoke-TrdAddEnglishLayout {
    <#
    .SYNOPSIS
        给系统加一个英文(美国)键盘布局，让用户能切出中文输入法。
    .DESCRIPTION
        东方系列"启动前切英文输入法"的前提是系统里真的有英文布局。
        只装中文键盘的系统切不出去，这条解法就失效了。
        这里在 HKCU\Keyboard Layout\Preload 里补一个 00000409 槽位；
        Win8+ 上再尝试通过 Set-WinUserLanguageList 正式登记。
        布局变更需要注销/重新登录才生效。
    #>
    param([Parameter(Mandatory = $true)]$Diagnosis)
    if ($script:TRD.DryRun) {
        Write-TrdLog '[演练] 将添加英文(美国)键盘布局' 'Info'
        return [PSCustomObject]@{ Ok = $true; Message = '演练模式' }
    }

    $key = 'HKCU:\Keyboard Layout\Preload'
    if (-not (Test-Path -LiteralPath $key)) { $null = New-Item -Path $key -Force }
    $null = Backup-TrdRegKey -RegPath 'HKCU\Keyboard Layout\Preload' -Tag 'layout'

    # 找下一个空闲槽位
    $used = @{}
    try {
        $cur = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        foreach ($pr in $cur.PSObject.Properties) {
            if ($pr.Name -notlike 'PS*') { $used[[int]$pr.Name] = [string]$pr.Value }
        }
    } catch { }

    if (@($used.Values) -contains '00000409') {
        return [PSCustomObject]@{ Ok = $true; Message = '英文(美国)布局已存在，无需添加' }
    }

    $slot = 1
    while ($used.ContainsKey($slot)) { $slot++ }
    if (Set-TrdRegValue -RegPath $key -Name ([string]$slot) -Value '00000409' -Type String -BackupTag 'layout') {
        Write-TrdLog "已在 Preload 槽位 $slot 添加英文(美国)键盘布局 00000409" 'OK'
    } else {
        return [PSCustomObject]@{ Ok = $false; Message = '写入 Preload 失败' }
    }

    # Win8+ 上同步登记到用户语言列表，否则部分系统会忽略 Preload 里的新槽位
    $extra = ''
    if (Get-Command -Name 'Set-WinUserLanguageList' -ErrorAction SilentlyContinue) {
        try {
            $list = @(Get-WinUserLanguageList)
            if (-not @($list | Where-Object { $_.LanguageTag -eq 'en-US' }).Count) {
                $list += (New-WinUserLanguageList 'en-US')
                Set-WinUserLanguageList -LanguageList $list -Force -ErrorAction Stop
                $extra = '；并已登记到用户语言列表'
            }
        } catch { $extra = '；用户语言列表登记失败（不影响 Preload 方式，注销后仍应出现）' }
    }

    return [PSCustomObject]@{
        Ok      = $true
        Message = "已添加英文(美国)键盘布局$extra。需要注销或重启后生效，" +
                  '之后即可在启动游戏前按 Win+空格 切到英文输入状态。'
    }
}

function Invoke-TrdRemoveScancodeMap {
    <#
    .SYNOPSIS
        删除内核级键盘重映射（Scancode Map）。
    .DESCRIPTION
        该值能把物理按键映射成别的键。写坏时表现为按 A 出 B 或某键一直按下。
        删除前先导出整个 Keyboard Layout 键，可回滚。
        删除后需要重启才生效。
    #>
    param([Parameter(Mandatory = $true)]$Diagnosis)
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout'
    $sm = Get-TrdScancodeMap
    if (-not $sm.Present) { return [PSCustomObject]@{ Ok = $true; Message = '不存在 Scancode Map，无需处理' } }
    if ($script:TRD.DryRun) {
        Write-TrdLog '[演练] 将删除 Scancode Map' 'Info'
        return [PSCustomObject]@{ Ok = $true; Message = '演练模式' }
    }
    $null = Backup-TrdRegKey -RegPath 'HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Tag 'scancodemap'
    try {
        Remove-ItemProperty -LiteralPath $key -Name 'Scancode Map' -Force -ErrorAction Stop
        Write-TrdLog "已删除 Scancode Map（原有 $($sm.Bytes) 字节：$($sm.Hex)）" 'OK'
        return [PSCustomObject]@{ Ok = $true; Message = 'Scancode Map 已删除，需要重启后恢复物理按键定义。原值已备份，可用「回滚.bat」还原。' }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Message = "删除失败（需管理员权限）: $($_.Exception.Message)" }
    }
}

function Invoke-TrdResetDirectInput {
    <#
    .SYNOPSIS
        清除 DirectInput 为游戏保存的按程序配置，强制它重新枚举设备。
    .DESCRIPTION
        键位于 HKCU\Software\Microsoft\DirectInput\<程序>.EXE<哈希>。
        只删与当前游戏主程序同名的条目，不动其他程序的记录。
    #>
    param([Parameter(Mandatory = $true)]$Diagnosis)
    $exe = [System.IO.Path]::GetFileName($Diagnosis.Game.MainExe)
    $launcher = if ($Diagnosis.Game.LauncherExe) { [System.IO.Path]::GetFileName($Diagnosis.Game.LauncherExe) } else { $null }
    $names = @($exe) + @($launcher) | Where-Object { $_ } | ForEach-Object { $_.ToLower() }

    $base = 'HKCU:\Software\Microsoft\DirectInput'
    if (-not (Test-Path -LiteralPath $base)) { return [PSCustomObject]@{ Ok = $true; Message = '没有 DirectInput 配置记录' } }

    $removed = 0
    foreach ($k in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
        $nm = $k.PSChildName
        $match = $false
        foreach ($w in $names) { if ($nm.ToLower().StartsWith($w)) { $match = $true; break } }
        if (-not $match) { continue }
        if ($script:TRD.DryRun) { Write-TrdLog "[演练] 将删除 DirectInput 配置 $nm" 'Info'; $removed++; continue }
        try {
            Remove-Item -LiteralPath $k.PSPath -Recurse -Force -ErrorAction Stop
            Write-TrdLog "已清除 DirectInput 配置: $nm" 'OK'
            $removed++
        } catch { Write-TrdLog "清除 $nm 失败: $($_.Exception.Message)" 'Warn' }
    }

    if ($removed -eq 0) { return [PSCustomObject]@{ Ok = $true; Message = '没有找到该游戏的 DirectInput 配置记录' } }
    return [PSCustomObject]@{ Ok = $true; Message = "已清除 $removed 条 DirectInput 配置，下次启动会重新枚举输入设备" }
}
function Invoke-TrdEnableDxAcceleration {
    <#
    .SYNOPSIS
        恢复 Direct3D / DirectDraw 硬件加速（等价于 DirectX Repair 的
        /enabledirectdraw）。
    .DESCRIPTION
        只操作 32 位视图（WOW6432Node\Microsoft\Direct3D\Drivers 与
        ...\DirectDraw）：出问题的老游戏都是 32 位程序，读的就是这两个位置。
        不动 64 位视图，避免影响 64 位程序的显示行为。
        写前记录旧值，可用「回滚.bat」还原。
    #>
    param([Parameter(Mandatory = $true)]$Diagnosis)
    if ($script:TRD.DryRun) {
        Write-TrdLog '[演练] 将把 SoftwareOnly / EmulationOnly 改回 0，恢复硬件加速' 'Info'
        return [PSCustomObject]@{ Ok = $true; Message = '演练模式' }
    }
    $r = Set-TrdDxAcceleration -Action Enable -Target Both
    if ($r.Ok) {
        Write-TrdLog 'Direct3D / DirectDraw 硬件加速已恢复（需重启或重开游戏生效）' 'OK'
    }
    return $r
}

function Invoke-TrdDeployDxSystem {
    <#
    .SYNOPSIS
        把缺失的关键 DirectX 组件部署到系统目录。
    .DESCRIPTION
        这是 DirectX Repair 的核心做法，本工具原本刻意回避（只部署到游戏目录）。
        现在作为显式动作提供，并加了四道保险：
        位数校验、签名校验、逐文件备份、只覆盖更旧的版本。
        如果系统文件保护拒绝覆盖，会如实报告并建议改用游戏目录部署。
    #>
    param(
        [Parameter(Mandatory = $true)]$Diagnosis,
        [string]$DirectXRepairDataRoot
    )
    try {
        $inv = Get-TrdDxComponentInventory
        $r = Install-TrdDxComponentToSystem -Inventory $inv -DirectXRepairDataRoot $DirectXRepairDataRoot
        if ($r.Skipped -and @($r.Skipped).Count -gt 0) {
            foreach ($s in @($r.Skipped | Select-Object -First 5)) { Write-TrdLog $s 'Detail' }
        }
        if ($r.Failed -and @($r.Failed).Count -gt 0) {
            foreach ($f in @($r.Failed | Select-Object -First 8)) { Write-TrdLog $f 'Warn' }
        }
        return $r
    } catch {
        return [PSCustomObject]@{ Ok = $false; Message = "系统目录部署出错: $($_.Exception.Message)" }
    }
}
function Invoke-TrdDefenderExclude {
    param([Parameter(Mandatory = $true)]$Diagnosis)
    if ($script:TRD.DryRun) {
        Write-TrdLog "[演练] 将把游戏目录加入 Defender 排除项" 'Info'
        return [PSCustomObject]@{ Ok = $true; Message = '演练模式' }
    }
    try {
        Add-MpPreference -ExclusionPath $Diagnosis.Game.Folder -ErrorAction Stop
        Write-TrdLog "已加入 Defender 排除项: $($Diagnosis.Game.Folder)" 'OK'
        return [PSCustomObject]@{ Ok = $true; Message = '已加入 Defender 排除项（可在 Windows 安全中心移除）' }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Message = "添加排除项失败: $($_.Exception.Message)" }
    }
}

function Invoke-TrdInstallFont {
    param(
        [Parameter(Mandatory = $true)]$Diagnosis,
        [string]$OfflineRoot
    )
    $fontDir = Join-Path $OfflineRoot 'Fonts'
    if (-not (Test-Path -LiteralPath $fontDir)) {
        return [PSCustomObject]@{ Ok = $false; Message = "载荷目录不存在: $fontDir" }
    }
    # -Include 与 -LiteralPath 组合不可靠，显式按扩展名过滤
    $fonts = @(Get-ChildItem -LiteralPath $fontDir -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -in '.ttf', '.ttc', '.otf' })
    if ($fonts.Count -eq 0) {
        return [PSCustomObject]@{
            Ok      = $false
            Message = 'offline\Fonts\ 中没有字体文件。微软字体受许可限制，本工具不分发；请通过「设置 → 时间和语言 → 语言 → 日语 → 可选功能」离线添加，或手工放入字体文件后重试。'
        }
    }
    $okCount = 0
    foreach ($f in $fonts) {
        if ($script:TRD.DryRun) { Write-TrdLog "[演练] 将安装字体 $($f.Name)" 'Info'; $okCount++; continue }
        try {
            $dest = Join-Path $env:windir ('Fonts\' + $f.Name)
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction Stop
            $null = Set-TrdRegValue -RegPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' `
                    -Name $f.BaseName -Value $f.Name -Type String -BackupTag 'fonts'
            Write-TrdLog "已安装字体: $($f.Name)" 'OK'
            $okCount++
        } catch {
            Write-TrdLog "安装字体失败 $($f.Name): $($_.Exception.Message)" 'Error'
        }
    }
    return [PSCustomObject]@{ Ok = ($okCount -gt 0); Message = "已安装 $okCount 个字体" }
}

function Invoke-TrdMigrateAsciiPath {
    <#
    .SYNOPSIS
        把游戏迁移到纯 ASCII 路径。
    .DESCRIPTION
        用 robocopy 完整镜像，不做移动（原目录保持不动，零风险）。
        迁移后生成新路径的启动器，并提示用户原目录可自行删除。
    #>
    param(
        [Parameter(Mandatory = $true)]$Diagnosis,
        [string]$TargetRoot = 'D:\TouhouGames'
    )

    $game = $Diagnosis.Game
    $newFolder = Join-Path $TargetRoot $game.Id

    if ($script:TRD.DryRun) {
        Write-TrdLog "[演练] 将把游戏复制到 $newFolder" 'Info'
        return [PSCustomObject]@{ Ok = $true; Message = '演练模式' }
    }

    $free = Get-TrdFreeSpaceMB -Path $TargetRoot
    $need = [Math]::Round((Get-ChildItem -LiteralPath $game.Folder -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 0)
    if ($null -ne $free -and $free -lt ($need + 100)) {
        return [PSCustomObject]@{ Ok = $false; Message = "目标磁盘空间不足：需要约 $need MB，剩余 $free MB" }
    }

    Write-TrdLog "复制游戏到 ASCII 路径 $newFolder （约 $need MB，请稍候）..." 'Step'
    try {
        # 源目录几乎一定含空格和中文，必须加引号，否则 robocopy 会把路径拆成两个参数
        $argLine = ConvertTo-TrdArgString @($game.Folder, $newFolder, '/E', '/COPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
        $p = Start-Process -FilePath "$env:windir\System32\robocopy.exe" `
             -ArgumentList $argLine -Wait -PassThru -NoNewWindow
        # robocopy 退出码 0-7 都算成功
        if ($p.ExitCode -ge 8) {
            return [PSCustomObject]@{ Ok = $false; Message = "robocopy 返回 $($p.ExitCode)，复制未完成" }
        }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Message = "复制失败: $($_.Exception.Message)" }
    }

    # 在新目录生成启动器
    $target = if (Test-Path -LiteralPath (Join-Path $newFolder 'vpatch.exe')) { 'vpatch.exe' } else { Split-Path -Leaf $game.MainExe }
    $batPath = Join-Path $newFolder ("启动-{0}.bat" -f $game.Id)
    $batLines = @(
        '@echo off', 'chcp 936 >nul 2>nul', 'cd /d "%~dp0"', "start `"`" `"$target`"", 'exit /b 0'
    )
    [System.IO.File]::WriteAllText($batPath, ($batLines -join "`r`n"), [System.Text.Encoding]::GetEncoding(936))

    Write-TrdLog "已迁移到: $newFolder" 'OK'
    return [PSCustomObject]@{
        Ok      = $true
        Message = "已复制到纯 ASCII 路径 $newFolder（原目录未改动，确认无误后可自行删除）。新启动器: $batPath"
        NewPath = $newFolder
    }
}

# ---------------------------------------------------------------------------
#  统一执行入口
# ---------------------------------------------------------------------------
function Invoke-TrdRepairStep {
    <#
    .SYNOPSIS
        执行一个修复步骤，并对其结果做验证。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Step,
        [Parameter(Mandatory = $true)]$Diagnosis,
        [string]$OfflineRoot,
        [string]$MigrateTargetRoot,
        [string]$DirectXRepairDataRoot
    )

    Write-TrdLog ''
    Write-TrdLog "── [$($Step.Category)] $($Step.Title)" 'Step'
    if ($Step.FixHint) { Write-TrdLog "   方案: $($Step.FixHint)" 'Detail' }

    if ($Step.NeedsAdmin -and -not $script:TRD.IsAdmin) {
        Write-TrdLog '该修复需要管理员权限。请右键「一键修复.bat」选择「以管理员身份运行」。' 'Warn'
        return [PSCustomObject]@{ Ok = $false; Message = '需要管理员权限' }
    }

    $res = switch ($Step.FixId) {
        'FIX_INSTALL_PACKAGE' {
            if ($Step.NeedsPkg) { Install-TrdPackage -PackageId $Step.NeedsPkg -OfflineRoot $OfflineRoot }
            else { [PSCustomObject]@{ Ok = $false; Message = '该依赖不在内置映射表中，请把对应 DLL 放入 offline\DLL\x86\ 后重试' } }
        }
        'FIX_INSTALL_VC_NEEDED' {
            $results = @()
            $pkgs = @($Diagnosis.VcNeeded | ForEach-Object { $_.PkgId } | Where-Object { $_ } | Sort-Object -Unique)
            foreach ($p in $pkgs) { $results += Install-TrdPackage -PackageId $p -OfflineRoot $OfflineRoot }
            $okAll = (@($results | Where-Object { -not $_.Ok }).Count -eq 0)
            [PSCustomObject]@{ Ok = $okAll; Message = (@($results | ForEach-Object { $_.Message }) -join '；') }
        }
        'FIX_INSTALL_VC_ALL' {
            $results = @()
            $pkgs = @($Diagnosis.Vc | Where-Object { $_.Applicable -and -not $_.Installed } |
                      ForEach-Object {
                          if ($_.Version -eq '2015+') { if ($_.Arch -eq 'x86') { 'VC2015_2022_X86' } else { 'VC2015_2022_X64' } }
                          else { "VC$($_.Version)_$(if ($_.Arch -eq 'x86') { 'X86' } else { 'X64' })" }
                      } | Sort-Object -Unique)
            foreach ($p in $pkgs) { $results += Install-TrdPackage -PackageId $p -OfflineRoot $OfflineRoot }
            [PSCustomObject]@{ Ok = (@($results | Where-Object { -not $_.Ok }).Count -eq 0); Message = (@($results | ForEach-Object { $_.Message }) -join '；') }
        }
        'FIX_QUARANTINE_WRONG_BITNESS' { Invoke-TrdQuarantineWrongBitness -Diagnosis $Diagnosis }
        'FIX_QUARANTINE_SHADOWED'      { Invoke-TrdQuarantineShadowed -Diagnosis $Diagnosis }
        'FIX_UNBLOCK_FILES'            { Invoke-TrdUnblockFiles -Diagnosis $Diagnosis }
        'FIX_SET_COMPAT_FLAGS'         { Invoke-TrdSetCompatFlags -Diagnosis $Diagnosis -IncludeFullscreenOpt }
        'FIX_RESET_CFG'                { Invoke-TrdResetCfg -Diagnosis $Diagnosis }
        'FIX_GRANT_WRITE'              { Invoke-TrdGrantWrite -Diagnosis $Diagnosis }
        'FIX_CREATE_LAUNCHER'          { Invoke-TrdCreateLauncher -Diagnosis $Diagnosis }
        'FIX_DEPLOY_DGVOODOO'          { Invoke-TrdDeployDgVoodoo -Diagnosis $Diagnosis -OfflineRoot $OfflineRoot }
        'FIX_DEPLOY_LOCALE_EMULATOR'   { Invoke-TrdDeployLocaleEmulator -Diagnosis $Diagnosis -OfflineRoot $OfflineRoot -CodePage 932 }
        'FIX_ENABLE_DX_ACCELERATION'   { Invoke-TrdEnableDxAcceleration -Diagnosis $Diagnosis }
        'FIX_DISABLE_ACCESSIBILITY'    { Invoke-TrdDisableAccessibility -Diagnosis $Diagnosis }
        'FIX_ADD_ENGLISH_LAYOUT'       { Invoke-TrdAddEnglishLayout -Diagnosis $Diagnosis }
        'FIX_REMOVE_SCANCODE_MAP'      { Invoke-TrdRemoveScancodeMap -Diagnosis $Diagnosis }
        'FIX_RESET_DINPUT'             { Invoke-TrdResetDirectInput -Diagnosis $Diagnosis }
        'FIX_DEPLOY_DX_SYSTEM'         { Invoke-TrdDeployDxSystem -Diagnosis $Diagnosis -DirectXRepairDataRoot $DirectXRepairDataRoot }
        'FIX_DEFENDER_EXCLUDE'         { Invoke-TrdDefenderExclude -Diagnosis $Diagnosis }
        'FIX_START_AUDIO_SERVICE'      { Invoke-TrdStartAudioService -Diagnosis $Diagnosis }
        'FIX_ENABLE_MSI_SERVICE'       { Invoke-TrdEnableMsiService -Diagnosis $Diagnosis }
        'FIX_INSTALL_FONT'             { Invoke-TrdInstallFont -Diagnosis $Diagnosis -OfflineRoot $OfflineRoot }
        'FIX_MIGRATE_ASCII_PATH'       { Invoke-TrdMigrateAsciiPath -Diagnosis $Diagnosis -TargetRoot $MigrateTargetRoot }
        default {
            [PSCustomObject]@{ Ok = $false; Message = "未实现的修复动作: $($Step.FixId)" }
        }
    }

    if ($res -and $res.Message) {
        Write-TrdLog $res.Message $(if ($res.Ok) { 'OK' } else { 'Error' })
    }
    return $res
}

function Install-TrdDllLocalFallback {
    <#
    .SYNOPSIS
        运行库安装后仍有 DLL 无法解析时的兜底：把 DLL 直接放到游戏目录。
    .DESCRIPTION
        优先顺序：
          1) offline\DLL\<arch>\<name>       （用户手工放置，最可靠）
          2) 从已解包的 DirectX cab 中提取   （系统自带 expand.exe，无需第三方工具）
        放到游戏目录而不是系统目录，好处：
          * 绕开 Windows 文件保护对系统 DLL 的覆盖限制
          * 只影响这一个游戏
          * 删除即回滚
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Diagnosis,
        [string]$OfflineRoot,
        [string[]]$DllNames
    )

    $arch = $Diagnosis.Deps.MainArch
    $folder = $Diagnosis.Game.Folder
    $dllDir = Join-Path $OfflineRoot ('DLL\' + $arch)
    $cabRoot = $script:TRD_DX_EXTRACT_DIR
    if (-not $cabRoot -or -not (Test-Path -LiteralPath $cabRoot)) {
        $cabRoot = Join-Path $OfflineRoot 'DirectX'
    }

    $results = New-Object System.Collections.ArrayList
    foreach ($name in $DllNames) {
        $lower = $name.ToLower()

        # 1) 用户手工放置的 DLL
        $manual = $null
        if (Test-Path -LiteralPath $dllDir) {
            $manual = Get-ChildItem -LiteralPath $dllDir -Recurse -Filter $name -ErrorAction SilentlyContinue | Select-Object -First 1
        }

        $src = $null
        if ($manual) {
            $src = $manual.FullName
            Write-TrdLog "使用手工放置的载荷: $src" 'Detail'
        } else {
            # 2) 从 DirectX cab 提取
            $ex = Get-TrdDllFromRedist -CabRoot $cabRoot -DllName $name -OutDir (Join-Path $script:TRD.SessionDir 'extracted_dll')
            if ($ex.Ok) { $src = $ex.Path }
            else { Write-TrdLog "无法获得 $name : $($ex.Reason)" 'Warn' }
        }

        if (-not $src) {
            $null = $results.Add([PSCustomObject]@{ Dll = $name; Ok = $false; Message = '载荷中找不到该 DLL' })
            continue
        }

        # 位数校验：必须与游戏主程序一致，否则会把 0xC0000135 变成更难查的 0xC000007B
        $info = Get-PeInfo -Path $src
        $want64 = ($arch -eq 'x64')
        if ($info.Ok -and $info.Is64 -ne $want64) {
            Write-TrdLog "拒绝部署 $name ：载荷是 $($info.Arch) 位，游戏需要 $arch 位。混放会导致 0xC000007B。" 'Error'
            $null = $results.Add([PSCustomObject]@{ Dll = $name; Ok = $false; Message = "位数不匹配（载荷 $($info.Arch)，需要 $arch）" })
            continue
        }

        if ($script:TRD.DryRun) {
            Write-TrdLog "[演练] 将部署 $name 到游戏目录" 'Info'
            $null = $results.Add([PSCustomObject]@{ Dll = $name; Ok = $true; Message = '演练模式' })
            continue
        }

        $dest = Join-Path $folder $name
        try {
            if (Test-Path -LiteralPath $dest) { $null = Backup-TrdFile -Path $dest -Tag 'dll_local' }
            Copy-Item -LiteralPath $src -Destination $dest -Force -ErrorAction Stop
            Write-TrdLog "已部署 $name → 游戏目录（$arch 位校验通过）" 'OK'
            $null = $results.Add([PSCustomObject]@{ Dll = $name; Ok = $true; Message = '已部署' })
        } catch {
            $null = $results.Add([PSCustomObject]@{ Dll = $name; Ok = $false; Message = $_.Exception.Message })
        }
    }

    $okCount = @($results | Where-Object { $_.Ok }).Count
    return [PSCustomObject]@{
        Ok      = ($okCount -eq $DllNames.Count)
        Message = "兜底部署: 成功 $okCount/$($DllNames.Count) —— " + (@($results | ForEach-Object { "$($_.Dll):$($_.Message)" }) -join '; ')
        Details = @($results)
    }
}
