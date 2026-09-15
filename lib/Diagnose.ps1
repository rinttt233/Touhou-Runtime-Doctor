# ============================================================================
#  Diagnose.ps1 -- 判定层
#  把 Detect 采集到的原始事实，翻译成"问题 + 严重级别 + 修复动作"的结论集。
#  原则：不臆断。每条结论都携带 Evidence，报告里可逐条复核。
# ============================================================================
Set-StrictMode -Version 2.0

$script:TRD_SEVERITY_ORDER = @{ 'Blocker' = 0; 'High' = 1; 'Medium' = 2; 'Low' = 3; 'Pass' = 4 }

function Get-TrdSeverityRank {
    param([string]$Severity)
    if ($script:TRD_SEVERITY_ORDER.ContainsKey($Severity)) { return $script:TRD_SEVERITY_ORDER[$Severity] }
    return 9
}

function Get-TrdRequiredVcFromImports {
    <#
    .SYNOPSIS
        从 PE 导入清单反推"这台机器真正需要的" VC 运行库版本与位数。
    .DESCRIPTION
        比"把 VC2005~2022 全装一遍"精确得多：只装游戏实际链接的版本。
    #>
    param(
        [Parameter(Mandatory = $true)]$Deps,
        [Parameter(Mandatory = $true)][string]$MainArch
    )

    $need = New-Object System.Collections.ArrayList
    $all = New-Object System.Collections.ArrayList
    foreach ($e in $Deps.Exes) {
        if (-not $e.Ok) { continue }
        foreach ($d in $e.Imports) { $null = $all.Add($d.ToLower()) }
    }

    $seen = @{}
    foreach ($dll in ($all | Sort-Object -Unique)) {
        if (-not $script:DLL_PROVIDER.ContainsKey($dll)) { continue }
        $p = $script:DLL_PROVIDER[$dll]
        if (-not $p.Cap) { continue }
        if ($p.Cap -notmatch '^vc|^msvc|^ucrt') { continue }
        $key = "$($p.Cap)|$MainArch"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $null = $need.Add([PSCustomObject]@{
            Dll      = $dll
            Cap      = $p.Cap
            Arch     = $MainArch
            Why      = $p.Why
            PkgId    = $(if ($p.Pkg) {
                            if ($MainArch -eq 'x86') { $p.Pkg }
                            else { $p.Pkg -replace '_X86$', '_X64' }
                        } else { $null })
        })
    }

    return @($need)
}

function Invoke-TrdDiagnosis {
    <#
    .SYNOPSIS
        对一台机器 + 一个游戏目录做完整体检。
    .OUTPUTS
        PSCustomObject: Game, Findings[], Deps, Vc, Dx, Env, Summary
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Game,
        [switch]$IncludePass
    )

    $findings = New-Object System.Collections.ArrayList
    $add = { param($f) $null = $findings.Add($f) }

    # =======================================================================
    #  1. 操作系统与 32 位运行能力
    #    这里必须区分"64 位系统缺 WOW64"（真故障）与"本来就是 32 位系统"
    #    （正常，32 位程序原生运行）。早期版本只看 SysWOW64 是否存在，
    #    会把每一台 32 位 Windows 都判成"严重：32 位子系统被移除"。
    # =======================================================================
    $os = Get-TrdWindowsBuild
    $is64Os = [bool]$os.Is64OS

    & $add (New-TrdFinding -Id 'ENV_OS' -Category '运行环境' -Severity 'Pass' `
        -Title "操作系统: $($os.Caption) (Build $($os.Build), $($os.Arch))" `
        -Detail "Windows 版本检测通过。PowerShell $($script:TRD.PSMajor).$($script:TRD.PSMinor)。" `
        -Evidence (@("ProductName: $($os.ProductName)", "Version: $($os.Version)", "Build: $($os.BuildNumber)") +
                   @("系统类型: $(if ($is64Os) { '64 位' } else { '32 位' })",
                     "32 位程序运行目录: $($script:TRD.SystemDirX86)",
                     "64 位程序运行目录: $(if ($script:TRD.SystemDirX64Display) { $script:TRD.SystemDirX64Display } else { '不适用（32 位系统）' })",
                     "PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))")))

    if (-not $is64Os) {
        & $add (New-TrdFinding -Id 'ENV_X86_OS' -Category '运行环境' -Severity 'Pass' `
            -Title '32 位 Windows：东方系列可原生运行' `
            -Detail '东方 Project 全系列都是 32 位程序。在 32 位系统上它们直接在 System32 加载运行，不存在 WOW64 转换层，反而少了一层兼容性风险。' `
            -Evidence @('系统为 32 位，不存在也不需要 SysWOW64', "32 位系统目录: $($script:TRD.SystemDirX86)"))
    } elseif (-not $script:TRD.HasWow64) {
        & $add (New-TrdFinding -Id 'ENV_NO_WOW64' -Category '运行环境' -Severity 'Blocker' `
            -Title '64 位系统上缺少 32 位子系统 (SysWOW64)' `
            -Detail '东方 Project 全系列都是 32 位程序，需要 WOW64 转换层。本机是 64 位系统却没有 SysWOW64 目录，说明 32 位子系统被移除（常见于 Server Core 或"精简版"系统）。这不是装运行库能解决的。' `
            -Evidence @("系统类型: 64 位", "缺少目录: $(Join-Path $env:windir 'SysWOW64')", '需要安装完整版 Windows 或启用 WoW64 组件') `
            -FixId $null -FixHint '需要更换/重装为完整版 Windows，本工具无法离线修复此项。')
    } else {
        & $add (New-TrdFinding -Id 'ENV_WOW64' -Category '运行环境' -Severity 'Pass' `
            -Title '32 位子系统正常（64 位系统 + SysWOW64）' `
            -Detail '可以运行 32 位程序，符合东方系列的要求。' `
            -Evidence @("SysWOW64: $(Join-Path $env:windir 'SysWOW64')"))
    }

    # --- Windows 7 专项：SP1 与桌面组合 ---
    if ($os.IsWin7) {
        if (-not $os.IsWin7Sp1) {
            & $add (New-TrdFinding -Id 'ENV_WIN7_NO_SP1' -Category '运行环境' -Severity 'High' `
                -Title 'Windows 7 未安装 SP1' `
                -Detail '未打 SP1 的 Windows 7 缺少大量运行时与 API 更新，DirectX / VC++ 运行库安装包会直接拒绝安装，且 .NET 4.5 以上无法安装。这是后续所有修复的前置条件。' `
                -Evidence @("Build $($os.Build)（SP1 应为 7601）", "Service Pack: $($os.ServicePack)") `
                -FixId $null -FixHint '先安装 Windows 7 Service Pack 1（KB976932），再安装 .NET Framework 4.5.2+ 与 WMF 5.1，然后重跑本工具。')
        } else {
            & $add (New-TrdFinding -Id 'ENV_WIN7_SP1' -Category '运行环境' -Severity 'Pass' `
                -Title 'Windows 7 SP1 已安装' `
                -Detail '满足 DirectX 9.0c 运行库与现代 .NET 的安装前提。' `
                -Evidence @("Build $($os.Build)"))
        }
    }

    if (-not $script:TRD.WmfUpToDate) {
        & $add (New-TrdFinding -Id 'ENV_PS_OLD' -Category '运行环境' -Severity 'Low' `
            -Title "PowerShell 版本偏旧（$($script:TRD.PSMajor).$($script:TRD.PSMinor)，建议 5.1）" `
            -Detail '本工具已内置降级实现（文件哈希、zip 解压、目录深度遍历都有兜底），当前版本可以正常使用。装 WMF 5.1 后会更稳，并且能启用额外的完整性校验能力。' `
            -Evidence @("PSVersion: $($PSVersionTable.PSVersion)", 'WMF 5.1 需要 .NET Framework 4.5.2+ 与 Windows 7 SP1 以上') `
            -FixId $null -FixHint '可选：安装 Windows Management Framework 5.1。不影响本工具的基本功能。')
    }

    # =======================================================================
    #  2. 系统区域代码页 vs 游戏文本编码
    # =======================================================================
    $loc = Get-TrdSystemLocale
    $isChinesePatch = ($Game.FolderName -match '汉|汉化|中文') -or (Test-Path -LiteralPath (Join-Path $Game.Folder '附带文档\汉化组的自述文档.txt'))
    $isJapaneseOriginal = -not $isChinesePatch

    $needCp = if ($isChinesePatch) { 936 } else { 932 }
    $needCpName = if ($isChinesePatch) { '简体中文 GBK (936)' } else { '日语 Shift-JIS (932)' }

    if ($loc.ACP -eq $needCp) {
        & $add (New-TrdFinding -Id 'ENV_LOCALE' -Category '区域与编码' -Severity 'Pass' `
            -Title "系统区域与游戏文本编码一致 ($($loc.Name))" `
            -Detail "该作品为$($(if ($isChinesePatch) { '汉化版' } else { '日文原版' }))，需要 $needCpName，当前系统正好匹配。" `
            -Evidence @("ACP = $($loc.ACP)", "OEMCP = $($loc.OEMCP)", "判定: $(if ($isChinesePatch) { '汉化版' } else { '日文原版' })"))
    } else {
        & $add (New-TrdFinding -Id 'ENV_LOCALE_MISMATCH' -Category '区域与编码' -Severity 'High' `
            -Title "系统区域与游戏文本编码不匹配（当前 $($loc.Name)，需要 $needCpName）" `
            -Detail "该作品判定为$(if ($isChinesePatch) { '汉化版' } else { '日文原版' })。在代码页不匹配的系统上，老引擎会出现菜单文字乱码、找不到资源文件、甚至启动即黑屏。推荐用区域模拟启动器（Locale Emulator）单独为这个游戏指定代码页，而不是改整个系统的区域设置（改系统区域需要重启且会影响其他软件）。" `
            -Evidence @("当前 ACP = $($loc.ACP) ($($loc.Name))", "需要 ACP = $needCp ($needCpName)") `
            -FixId 'FIX_DEPLOY_LOCALE_EMULATOR' -NeedsPackage 'TOOL_LOCALE_EMULATOR' `
            -FixHint "部署 Locale Emulator 并生成以 $needCpName 运行的启动器")
    }

    if ($loc.Utf8Beta) {
        & $add (New-TrdFinding -Id 'ENV_UTF8_BETA' -Category '区域与编码' -Severity 'High' `
            -Title '系统启用了 UTF-8 全球语言支持 (Beta)' `
            -Detail '"使用 Unicode UTF-8 提供全球语言支持"会改变 ANSI 代码页为 65001，这是导致大量日文/中文老游戏乱码与崩溃的头号原因。建议关闭。' `
            -Evidence @('ACP = 65001') -FixId $null `
            -FixHint '控制面板 → 区域 → 管理 → 更改系统区域设置 → 取消勾选"Beta: 使用 Unicode UTF-8..."，然后重启。')
    }

    # =======================================================================
    #  3. PE 依赖解析（核心）
    # =======================================================================
    $deps = Resolve-TrdGameDependencies -GameFolder $Game.Folder

    $badPe = @($deps.Exes | Where-Object { -not $_.Ok })
    if ($badPe.Count -gt 0) {
        & $add (New-TrdFinding -Id 'DEP_PE_UNREADABLE' -Category '程序完整性' -Severity 'Medium' `
            -Title "有 $($badPe.Count) 个可执行文件无法解析" `
            -Detail '这些文件可能已损坏、被反病毒软件改写、或不是有效的 PE 文件。' `
            -Evidence @($badPe | ForEach-Object { "$($_.Name): $($_.Error)" }))
    }

    # 3a. 缺失依赖
    #     分级依据"这个依赖是怎么被发现的"：
    #       静态导入表 -> 加载器必然解析 -> Blocker
    #       二进制字符串 -> 只是启发式线索 -> Low（可能根本不会被加载）
    $staticMissing = @($deps.Missing | Where-Object { $_.Source -eq 'Static' })
    $stringMissing = @($deps.Missing | Where-Object { $_.Source -ne 'Static' })

    if ($deps.Missing.Count -eq 0) {
        & $add (New-TrdFinding -Id 'DEP_ALL_PRESENT' -Category '依赖完整性' -Severity 'Pass' `
            -Title "全部 $($deps.TotalDeps) 项依赖均已解析成功" `
            -Detail "对游戏目录内 $($deps.Exes.Count) 个可执行文件做了 PE 导入表解析，未发现缺失的 DLL。" `
            -Evidence @("主程序位数: $($deps.MainArch)", "解析文件: " + (($deps.Exes | ForEach-Object { $_.Name }) -join ', ')))
    } else {
        if ($staticMissing.Count -gt 0) {
            # 按"提供者"聚合，避免同一个包重复报
            $byPkg = @{}
            foreach ($m in $staticMissing) {
                $key = if ($m.Provider -and $m.Provider.Pkg) { $m.Provider.Pkg } else { '(未知来源)' }
                if (-not $byPkg.ContainsKey($key)) { $byPkg[$key] = New-Object System.Collections.ArrayList }
                $null = $byPkg[$key].Add($m)
            }

            foreach ($pkgId in $byPkg.Keys) {
                $items = $byPkg[$pkgId]
                $dllList = @($items | ForEach-Object { $_.Dll } | Sort-Object -Unique)
                $ev = @($items | ForEach-Object {
                    $why = if ($_.Provider) { " — $($_.Provider.Why)" } else { '' }
                    "$($_.Dll)  (被 $($_.NeededBy) 的导入表引用)$why"
                })
                $fixHint = if ($pkgId -eq '(未知来源)') {
                    '这些 DLL 不在本工具的内置映射表中。请把对应 DLL 放入 offline/DLL/x86/ 后重跑，或手动确认来源。'
                } else {
                    "安装修复包 [$pkgId] 后即可解决"
                }

                & $add (New-TrdFinding -Id "DEP_MISSING_$pkgId" -Category '依赖完整性' -Severity 'Blocker' `
                    -Title "缺少 $($dllList.Count) 个必需的 DLL: $($dllList -join ', ')" `
                    -Detail "这些 DLL 出现在程序 PE 导入表里，加载器在进程启动阶段就一定会去解析它们。找不到时游戏会在启动瞬间以 0xC0000135 (STATUS_DLL_NOT_FOUND) 退出。" `
                    -Evidence $ev `
                    -FixId 'FIX_INSTALL_PACKAGE' -NeedsPackage $(if ($pkgId -eq '(未知来源)') { $null } else { $pkgId }) `
                    -FixHint $fixHint)
            }
        } else {
            & $add (New-TrdFinding -Id 'DEP_STATIC_OK' -Category '依赖完整性' -Severity 'Pass' `
                -Title "导入表中的 $($deps.TotalDeps) 项依赖全部解析成功" `
                -Detail '静态导入表是加载器的权威依据，其中没有任何缺失项。' `
                -Evidence @("主程序位数: $($deps.MainArch)"))
        }

        if ($stringMissing.Count -gt 0) {
            & $add (New-TrdFinding -Id 'DEP_STRING_ONLY' -Category '依赖完整性' -Severity 'Low' `
                -Title "有 $($stringMissing.Count) 个 DLL 名只出现在二进制字符串中且无法解析" `
                -Detail '这些名字是从文件内容里扫出来的，并不在导入表中，因此不能证明程序运行时真的会加载它们（很多是编译期残留的调试版名字或可选功能的探测名）。仅作为线索列出，供排查疑难问题时参考。' `
                -Evidence @($stringMissing | ForEach-Object { "$($_.Dll)  (出现在 $($_.NeededBy) 的字符串中)" }) `
                -FixId $null `
                -FixHint '一般无需处理。如果游戏确实在启动时报缺少这个文件，再把它补进 offline/DLL/x86/。')
        }
    }

    # 3b. 游戏目录内位数错误的 DLL —— 0xC000007B 的头号元凶
    if ($deps.WrongBitness.Count -gt 0) {
        & $add (New-TrdFinding -Id 'DEP_WRONG_BITNESS' -Category '依赖完整性' -Severity 'Blocker' `
            -Title "游戏目录里混进了 $($deps.WrongBitness.Count) 个位数不符的 DLL" `
            -Detail "游戏主程序是 $($deps.MainArch) 位，但下列同级 DLL 是 64 位。Windows 加载器会优先使用 exe 同目录的 DLL，位数不符会导致进程直接以 0xC000007B (STATUS_INVALID_IMAGE_FORMAT) 退出，且不会给出任何提示。这是"修复失败"最常见的原因之一。" `
            -Evidence @($deps.WrongBitness | ForEach-Object { "$($_.Name): 实际 $($_.Arch)，应为 $($_.Expected)" }) `
            -FixId 'FIX_QUARANTINE_WRONG_BITNESS' `
            -FixHint '把位数不符的 DLL 移动到 backup 隔离目录（不删除，可回滚）')
    } else {
        & $add (New-TrdFinding -Id 'DEP_BITNESS_OK' -Category '依赖完整性' -Severity 'Pass' `
            -Title '游戏目录内 DLL 位数全部匹配' `
            -Detail "主程序为 $($deps.MainArch) 位，目录内未发现位数冲突的 DLL。" `
            -Evidence @("主程序: $(Split-Path -Leaf $deps.MainExe)"))
    }

    # 3c. 目录内旧 DLL 遮蔽系统新 DLL
    if ($deps.Shadowed.Count -gt 0) {
        & $add (New-TrdFinding -Id 'DEP_SHADOWED' -Category '依赖完整性' -Severity 'Low' `
            -Title "游戏目录内有 $($deps.Shadowed.Count) 个 DLL 与系统版本不一致" `
            -Detail "exe 同目录的 DLL 优先级最高，会遮蔽系统目录里的同名文件。如果这些是旧版本的运行库，可能引发难以排查的崩溃。通常无害，但如果游戏不稳定，建议一并隔离。" `
            -Evidence @($deps.Shadowed | ForEach-Object { "$($_.Dll): 本地 $($_.LocalVer) vs 系统 $($_.SystemVer)" }) `
            -FixId 'FIX_QUARANTINE_SHADOWED' `
            -FixHint '把本地旧 DLL 隔离到 backup，让游戏使用系统版本')
    }

    # =======================================================================
    #  4. DirectX
    # =======================================================================
    $dx = Get-TrdDirectXState
    $engine = $Game.Engine

    $dxEv = @()
    if ($dx.RegVersion) { $dxEv += "HKLM\SOFTWARE\Microsoft\DirectX\Version = $($dx.RegVersion)" }
    if ($dx.InstalledMajor) { $dxEv += "WOW6432Node InstalledVersion 主版本 = $($dx.InstalledMajor)" }
    $dxEv += "32 位组件目录: $($dx.X86Dir)"
    $dxEv += "该目录下存在的组件: $($dx.Present.Count) 项"
    if ($dx.Missing.Count -gt 0) { $dxEv += "该目录下缺失的组件: $($dx.Missing -join ', ')" }
    if ($dx.X64Dir) { $dxEv += "64 位组件目录: $(ConvertTo-TrdDisplayPath -Text $dx.X64Dir)（东方系列为 32 位程序，不涉及此目录）" }
    else { $dxEv += '本机为 32 位系统，不存在 64 位组件目录' }

    if ($engine -eq 'dx8') {
        # DirectX 8 时代作品：只看 d3d8 / ddraw 这组
        $dx8Needed = @('d3d8.dll', 'd3d8thk.dll')
        $dx8Missing = @($dx8Needed | Where-Object { -not $dx.X86[$_] })
        if ($dx8Missing.Count -gt 0) {
            & $add (New-TrdFinding -Id 'DX_DX8_MISSING' -Category 'DirectX' -Severity 'Blocker' `
                -Title "缺少 DirectX 8 组件: $($dx8Missing -join ', ')" `
                -Detail "$($Game.DisplayName) 属于 DirectX 8 世代作品，直接链接 d3d8.dll。DirectX 8 运行时不在任何现代 Windows 的默认组件里，而「装个 DirectX 9」并不能解决——DX9 不会再分发 DX8 的独立运行时。需要用完整版 DirectX 运行库包补齐。" `
                -Evidence $dxEv -FixId 'FIX_INSTALL_PACKAGE' -NeedsPackage 'DX9_REDIST_JUN2010' `
                -FixHint '安装 DirectX 2010 年 6 月完整运行库（内含 DX8 兼容组件），必要时再从包内提取 d3d8.dll 部署到游戏目录')
        } else {
            & $add (New-TrdFinding -Id 'DX_DX8_OK' -Category 'DirectX' -Severity 'Pass' `
                -Title 'DirectX 8 组件齐全 (d3d8.dll / d3d8thk.dll)' `
                -Detail '系统已具备该作品所需的 DirectX 8 运行时。' -Evidence $dxEv)
        }

        # th06 特有：16 位色彩模式依赖 DirectDraw
        if ($Game.Id -eq 'th06') {
            if (-not $dx.X86['ddraw.dll']) {
                & $add (New-TrdFinding -Id 'DX_DDRAW_MISSING' -Category 'DirectX' -Severity 'Blocker' `
                    -Title '缺少 DirectDraw (ddraw.dll) —— th06 红魔乡专有问题' `
                    -Detail '东方红魔乡只支持 16 位色彩模式，通过 DirectDraw 建立显示模式。缺少 ddraw.dll 会直接黑屏退出。' `
                    -Evidence $dxEv -FixId 'FIX_INSTALL_PACKAGE' -NeedsPackage 'DX9_REDIST_JUN2010')
            }
        }
    }

    if ($engine -eq 'dx9') {
        $d3dx = @($dx.Missing | Where-Object { $_ -match '^d3dx9_|^D3DX9_|^D3DCompiler_' })
        if ($d3dx.Count -gt 0) {
            & $add (New-TrdFinding -Id 'DX_D3DX9_MISSING' -Category 'DirectX' -Severity 'High' `
                -Title "缺少 DirectX 9 扩展库: $($d3dx -join ', ')" `
                -Detail "$($Game.DisplayName) 属于 DirectX 9 世代作品，用到 D3DX9 辅助库。这些 DLL 从 Windows 8 起就不再随系统分发，必须单独安装 DirectX 9.0c 运行库。缺失时典型报错是「计算机中丢失 d3dx9_XX.dll」。" `
                -Evidence $dxEv -FixId 'FIX_INSTALL_PACKAGE' -NeedsPackage 'DX9_REDIST_JUN2010' `
                -FixHint '安装 DirectX 2010 年 6 月完整运行库')
        } else {
            & $add (New-TrdFinding -Id 'DX_D3DX9_OK' -Category 'DirectX' -Severity 'Pass' `
                -Title 'DirectX 9 扩展库齐全' `
                -Detail "d3dx9_* / D3DCompiler_* 均在位。" -Evidence $dxEv)
        }
    }

    # --- Direct3D / DirectDraw 硬件加速开关（来自 DirectX Repair 的能力）---
    # 被误设为"仅软件渲染"时，依赖检查全过但游戏极慢或起不来，
    # 从运行库角度完全看不出问题，必须单独查。
    $accel = Get-TrdDxAccelerationState
    if ($accel.D3DDisabled -or $accel.DDDisabled) {
        $what = @()
        if ($accel.D3DDisabled) { $what += 'Direct3D' }
        if ($accel.DDDisabled) { $what += 'DirectDraw' }
        & $add (New-TrdFinding -Id 'DX_ACCEL_DISABLED' -Category 'DirectX' -Severity 'Blocker' `
            -Title "硬件加速被注册表关闭：$($what -join ' 与 ')" `
            -Detail ("系统被设置为强制软件渲染（$($what -join '/')）。此时运行库检查会全部通过，" +
                     "但 3D 游戏要么极慢要么直接起不来 —— 从依赖角度完全查不出问题。" +
                     "常见来源是旧版 DirectX 诊断工具或某些「优化」软件误设。") `
            -Evidence @($accel.Entries | ForEach-Object { "$($_.Key)\$($_.ValueName) = $($_.Value)" }) `
            -FixId 'FIX_ENABLE_DX_ACCELERATION' `
            -FixHint '把 SoftwareOnly / EmulationOnly 改回 0，恢复硬件加速')
    } else {
        & $add (New-TrdFinding -Id 'DX_ACCEL_OK' -Category 'DirectX' -Severity 'Pass' `
            -Title 'Direct3D / DirectDraw 硬件加速已启用' `
            -Detail '未发现强制软件渲染的注册表开关。' `
            -Evidence @($(if ($accel.Entries.Count -eq 0) { 'SoftwareOnly / EmulationOnly 均未设置（默认即启用）' } else { $accel.Entries | ForEach-Object { "$($_.ValueName) = $($_.Value)" } })))
    }

    # --- 完整组件清单（比原来的 36 项 watch 列表全面得多）---
    $inv = Get-TrdDxComponentInventory
    $keyMissing = @($inv.Missing32 | Where-Object { $_.IsKey })
    if ($keyMissing.Count -gt 0) {
        & $add (New-TrdFinding -Id 'DX_KEY_COMPONENTS_MISSING' -Category 'DirectX' -Severity 'High' `
            -Title "缺少 $($keyMissing.Count) 个关键 DirectX 组件" `
            -Detail ("这些是大量游戏都会依赖的组件（含 xinput 手柄支持、XAudio2 音频、D3DX9 扩展库等）。" +
                     "缺少时表现为「游戏提示丢失 XXX.dll」或手柄/音频不可用。") `
            -Evidence @($keyMissing | ForEach-Object { "$($_.Name)  [$($_.Category)]  期望位置: $($_.Path32)" }) `
            -FixId 'FIX_DEPLOY_DX_SYSTEM' `
            -FixHint '安装 DirectX 完整运行库；或从离线载荷把缺失组件部署到系统目录（逐文件备份，可回滚）')
    } else {
        & $add (New-TrdFinding -Id 'DX_KEY_COMPONENTS_OK' -Category 'DirectX' -Severity 'Pass' `
            -Title '关键 DirectX 组件齐全' `
            -Detail "组件目录共 $($inv.Total) 项，32 位侧已具备 $($inv.Present32) 项，关键组件无缺失。" `
            -Evidence @("32 位组件目录: $($inv.DirX86)", "组件目录条目数: $($inv.Total)", "非关键组件缺失: $(@($inv.Missing32 | Where-Object { -not $_.IsKey }).Count) 项（通常不影响运行）"))
    }
    if ($engine -eq 'unknown') {
        & $add (New-TrdFinding -Id 'DX_ENGINE_UNKNOWN' -Category 'DirectX' -Severity 'Low' `
            -Title "无法识别作品代号，按通用规则体检" `
            -Detail "目录名或主程序名不匹配已知的 th06~th19 命名。已按 PE 导入表实际内容判断依赖，结论仍然有效。" `
            -Evidence @("目录: $($Game.Folder)", "主程序: $(Split-Path -Leaf $Game.MainExe)"))
    }

    # =======================================================================
    #  5. VC 运行库
    # =======================================================================
    $vc = Get-TrdVcRuntimeState
    # 必须用 @() 包住：PowerShell 在函数返回时会展开单元素数组，
    # 直接赋值会退化成标量对象，后续的 .Count 就会抛 PropertyNotFound。
    $vcNeeded = @(Get-TrdRequiredVcFromImports -Deps $deps -MainArch $deps.MainArch)

    $vcNeedRows = New-Object System.Collections.ArrayList
    foreach ($n in $vcNeeded) {
        # 把 cap（如 vc2010-x86）翻译成 VC_DEFS 的 Ver
        $verKey = switch -Regex ($n.Cap) {
            '^vc2005' { '2005' } '^vc2008' { '2008' } '^vc2010' { '2010' }
            '^vc2012' { '2012' } '^vc2013' { '2013' } '^vc140|^vc2015' { '2015+' }
            default { $null }
        }
        if (-not $verKey) { continue }
        $row = $vc | Where-Object { $_.Version -eq $verKey -and $_.Arch -eq $n.Arch -and $_.Applicable } | Select-Object -First 1
        $null = $vcNeedRows.Add([PSCustomObject]@{
            Dll        = $n.Dll
            VcVersion  = $verKey
            Arch       = $n.Arch
            Installed  = $(if ($row) { $row.Installed } else { $null })
            Source     = $(if ($row) { $row.Source } else { '' })
            PkgId      = $n.PkgId
            Why        = $n.Why
        })
    }

    $vcMissingNeeded = @($vcNeedRows | Where-Object { $_.Installed -eq $false })
    if ($vcNeeded.Count -eq 0) {
        & $add (New-TrdFinding -Id 'VC_NOT_REQUIRED' -Category 'VC 运行库' -Severity 'Pass' `
            -Title '游戏本体不依赖任何 VC++ 运行库' `
            -Detail "PE 导入表里没有出现 msvcr*/msvcp*/vcruntime* 系列。该作品用较老的编译器（或静态链接）构建，本体不需要 VC 运行库。但辅助工具（Locale Emulator、部分汉化补丁、dgVoodoo2 控制面板）仍可能需要，因此工具仍会给出整机 VC 状态表。" `
            -Evidence @("已解析 $(($deps.Exes | Where-Object { $_.Ok }).Count) 个 PE 文件") )
    } elseif ($vcMissingNeeded.Count -eq 0) {
        & $add (New-TrdFinding -Id 'VC_OK' -Category 'VC 运行库' -Severity 'Pass' `
            -Title "游戏所需的 $($vcNeeded.Count) 项 VC 运行库均已安装" `
            -Detail '按 PE 导入表反推的 VC 依赖全部满足。' `
            -Evidence @($vcNeedRows | ForEach-Object { "$($_.Dll) → $($_.VcVersion) $($_.Arch)：已安装 ($($_.Source))" }))
    } else {
        & $add (New-TrdFinding -Id 'VC_MISSING' -Category 'VC 运行库' -Severity 'Blocker' `
            -Title ("缺少游戏实际链接的 VC 运行库: " + (@($vcMissingNeeded | ForEach-Object { "$($_.VcVersion) $($_.Arch)" } | Sort-Object -Unique) -join ', ')) `
            -Detail '这些版本是由 PE 导入表反推出来的，不是"全都装一遍"。缺失会导致 0xC0000135（找不到 DLL）或 0xc000007b。' `
            -Evidence @($vcMissingNeeded | ForEach-Object { "$($_.Dll) → 需要 $($_.VcVersion) $($_.Arch) 运行库 ($($_.Why))；当前未检测到" }) `
            -FixId 'FIX_INSTALL_VC_NEEDED' `
            -FixHint ('需要安装: ' + (@($vcMissingNeeded | ForEach-Object { $_.PkgId } | Where-Object { $_ } | Sort-Object -Unique) -join ', ')))
    }

    # 整机 VC 覆盖情况（即使游戏不需要，也告知，因为汉化工具链常需要）
    $vcGaps = @($vc | Where-Object { $_.Applicable -and -not $_.Installed })
    if ($vcGaps.Count -gt 0) {
        & $add (New-TrdFinding -Id 'VC_SYSTEM_GAPS' -Category 'VC 运行库' -Severity 'Low' `
            -Title "整机有 $($vcGaps.Count) 项 VC 运行库缺失（当前游戏未直接用到）" `
            -Detail '本次游戏本体不需要它们，但其他游戏、汉化补丁、Locale Emulator 等辅助工具可能需要。可选择一并补齐，做一次到位的环境建设。' `
            -Evidence @($vcGaps | ForEach-Object { "$($_.Display) $($_.Arch)：未安装" }) `
            -FixId 'FIX_INSTALL_VC_ALL' -FixHint '一键补齐全部缺失的 VC 运行库 (x86 + x64)')
    }

    # =======================================================================
    #  6. 路径与目录
    # =======================================================================
    if (Test-TrdPathIsAscii -Path $Game.Folder) {
        & $add (New-TrdFinding -Id 'PATH_ASCII' -Category '路径与目录' -Severity 'Pass' `
            -Title '游戏路径全部为 ASCII 字符' `
            -Detail '老引擎按 ANSI 代码页解析路径，纯 ASCII 路径最安全。' -Evidence @($Game.Folder))
    } else {
        & $add (New-TrdFinding -Id 'PATH_NON_ASCII' -Category '路径与目录' -Severity 'Medium' `
            -Title '游戏路径包含非 ASCII 字符（中文/日文/方括号）' `
            -Detail "该作品是 2004 年前后的老引擎，按系统 ANSI 代码页解析路径。当系统区域与路径编码不一致时，会出现黑屏、找不到 th08.dat、存档失败等问题。" `
            -Evidence @("路径: $($Game.Folder)", '含非 ASCII 字符') `
            -FixId 'FIX_MIGRATE_ASCII_PATH' `
            -FixHint '迁移到纯 ASCII 路径（例如 D:\Games\th08），原目录保留不动')
    }

    $writable = Test-TrdWritable -Dir $Game.Folder
    if ($writable) {
        & $add (New-TrdFinding -Id 'PATH_WRITABLE' -Category '路径与目录' -Severity 'Pass' `
            -Title '游戏目录可写' `
            -Detail '游戏需要在本目录写 score.dat / th08.cfg / log.txt，权限正常。' -Evidence @($Game.Folder))
    } else {
        & $add (New-TrdFinding -Id 'PATH_READONLY' -Category '路径与目录' -Severity 'Blocker' `
            -Title '游戏目录不可写' `
            -Detail '游戏会把自己目录当作工作目录写入存档与配置。目录只读会导致启动失败或无法存档。放在 Program Files 下时尤其常见（UAC 虚拟化重定向）。' `
            -Evidence @("目录: $($Game.Folder)", '写入探测失败') `
            -FixId 'FIX_GRANT_WRITE' -FixHint '为当前用户授予该目录的修改权限')
    }

    if ($Game.Folder.Length -gt 180) {
        & $add (New-TrdFinding -Id 'PATH_TOO_LONG' -Category '路径与目录' -Severity 'Medium' `
            -Title "路径过长 ($($Game.Folder.Length) 字符)" `
            -Detail '老引擎使用 MAX_PATH(260) 缓冲区拼接路径。过长的路径会导致资源文件打开失败，且难以定位。' `
            -Evidence @($Game.Folder) -FixId 'FIX_MIGRATE_ASCII_PATH' `
            -FixHint '迁移到更短的路径（例如 D:\Games\th08）')
    }

    $free = Get-TrdFreeSpaceMB -Path $Game.Folder
    if ($null -ne $free -and $free -lt 500) {
        & $add (New-TrdFinding -Id 'DISK_LOW' -Category '路径与目录' -Severity 'Low' `
            -Title ("所在磁盘剩余空间不足 ({0} MB)" -f $free) `
            -Detail '游戏本体与 thbgm.dat 体积较大，且修复过程需要备份。建议保留至少 500 MB。' -Evidence @("剩余: $free MB"))
    }

    # =======================================================================
    #  7. 启动方式
    # =======================================================================
    $vpExe = Join-Path $Game.Folder 'vpatch.exe'
    $vpDll = Join-Path $Game.Folder ('vpatch_{0}.dll' -f $Game.Id)
    $hasVpatch = (Test-Path -LiteralPath $vpExe)

    if ($hasVpatch) {
        $vpDllOk = Test-Path -LiteralPath $vpDll
        $ev = @("找到 $vpExe")
        if ($vpDllOk) { $ev += "找到配套注入模块 $vpDll" } else { $ev += "未找到预期模块 $vpDll（可能命名不同）" }
        & $add (New-TrdFinding -Id 'LAUNCH_VPATCH' -Category '启动方式' -Severity 'Pass' `
            -Title '检测到 vsync 补丁 (vpatch)，建议通过它启动' `
            -Detail 'vpatch 负责修正老引擎的帧率与画面撕裂问题，并且是汉化补丁的载体。直接双击 th08.exe 会绕过补丁，导致帧率异常、掉帧、输入延迟。' `
            -Evidence $ev -FixId 'FIX_CREATE_LAUNCHER' `
            -FixHint '生成一个以 vpatch.exe 启动的"启动东方永夜抄.bat"快捷入口')
    }

    # =======================================================================
    #  8. 显示与兼容性设置
    # =======================================================================
    $scaling = Get-TrdDisplayScaling
    $exePaths = @($deps.Exes | Where-Object { $_.Ok -and $_.Name -match '\.exe$' } | ForEach-Object { $_.Path })
    if ($hasVpatch) { $exePaths += $vpExe }
    $exePaths = @($exePaths | Sort-Object -Unique)

    $flags = Get-TrdCompatFlags -ExePaths $exePaths

    if ($scaling.Percent -gt 100) {
        $noFlag = @($exePaths | Where-Object {
            $v = $flags[$_]
            -not $v -or ($v -notmatch 'HIGHDPIAWARE')
        })
        if ($noFlag.Count -gt 0) {
            & $add (New-TrdFinding -Id 'DPI_SCALING' -Category '显示与兼容性' -Severity 'Medium' `
                -Title "显示缩放为 $($scaling.Percent)%，但有 $($noFlag.Count) 个程序未声明 DPI 感知" `
                -Detail '该作品使用固定的 640×480 全屏/窗口模式。未声明 DPI 感知时，Windows 会对画面做位图拉伸，导致画面模糊、鼠标坐标偏移（点击位置与画面不符）。' `
                -Evidence (@("当前 DPI: $($scaling.Dpi) ($($scaling.Percent)%)") + @($noFlag | ForEach-Object { "缺少 HIGHDPIAWARE: $_" })) `
                -FixId 'FIX_SET_COMPAT_FLAGS' -FixHint '为游戏目录内全部 exe 写入 HIGHDPIAWARE 兼容性标记')
        } else {
            & $add (New-TrdFinding -Id 'DPI_OK' -Category '显示与兼容性' -Severity 'Pass' `
                -Title "显示缩放 $($scaling.Percent)% 已正确处理" `
                -Detail '全部可执行文件均已声明 DPI 感知。' `
                -Evidence @($exePaths | ForEach-Object { "$_ => $($flags[$_])" }))
        }
    } else {
        & $add (New-TrdFinding -Id 'DPI_NONE' -Category '显示与兼容性' -Severity 'Pass' `
            -Title '显示缩放为 100%，无 DPI 问题' `
            -Detail '当前不需要 DPI 兼容性修正。' -Evidence @("DPI: $($scaling.Dpi)"))
    }

    # 渲染兼容标记：不同 Windows 世代的正确标记不一样
    #   Win8+  : DISABLEDXMAXIMIZEDWINDOWEDMODE —— 关掉"全屏优化"
    #   Win7   : DISABLEDWM                     —— 关掉桌面窗口管理器(DWM)组合
    #            Win7 没有"全屏优化"这个机制，写 DISABLEDXMAXIMIZEDWINDOWEDMODE
    #            是无效的；而 Win7 的 Aero/DWM 会把独占全屏变成合成渲染，
    #            对 640x480 的老弹幕游戏同样造成掉帧与输入延迟。
    $osForFlags = Get-TrdWindowsBuild
    if ($osForFlags.IsWin7) {
        $desiredFlag = 'DISABLEDWM'
        $flagReason = 'Windows 7 的桌面窗口管理器 (DWM) 会把独占全屏变成合成渲染，对 640×480 的老弹幕游戏造成掉帧与输入延迟。'
        $flagTitle = '未禁用桌面组合 (Disable desktop composition)'
    } elseif ($osForFlags.IsWin8OrNewer) {
        $desiredFlag = 'DISABLEDXMAXIMIZEDWINDOWEDMODE'
        $flagReason = 'Windows 8 以上的"全屏优化"会把独占全屏偷偷改成无边框窗口，叠加 DWM 合成。对固定 60fps 的老弹幕游戏会造成掉帧、输入延迟、画面撕裂。'
        $flagTitle = '未禁用"全屏优化"(Fullscreen Optimizations)'
    } else {
        $desiredFlag = $null
        $flagReason = ''
        $flagTitle = ''
    }

    $missingFlags = @()
    if ($desiredFlag) {
        foreach ($e in $exePaths) {
            $v = [string]$flags[$e]
            if ($v -notmatch [regex]::Escape($desiredFlag)) { $missingFlags += $e }
        }
    }
    if ($missingFlags.Count -gt 0) {
        & $add (New-TrdFinding -Id 'COMPAT_FULLSCREEN_OPT' -Category '显示与兼容性' -Severity 'Low' `
            -Title $flagTitle `
            -Detail $flagReason `
            -Evidence @($missingFlags | ForEach-Object { "缺少 $desiredFlag : $_" }) `
            -FixId 'FIX_SET_COMPAT_FLAGS' -FixHint "写入 $desiredFlag 兼容性标记")
    }

    # =======================================================================
    #  9. 文件来源标记 (Mark of the Web)
    # =======================================================================
    $motw = New-Object System.Collections.ArrayList
    foreach ($e in $exePaths) { if (Test-TrdMotW -Path $e) { $null = $motw.Add($e) } }
    if ($motw.Count -gt 0) {
        & $add (New-TrdFinding -Id 'FILE_MOTW' -Category '文件安全标记' -Severity 'High' `
            -Title "有 $($motw.Count) 个程序带「来自 Internet」标记，会被 SmartScreen 拦截" `
            -Detail '从压缩包解出的汉化版 exe 常带 Zone.Identifier 数据流。运行时会弹出"Windows 已保护你的电脑"，部分情况下会静默阻止游戏读取被标记的数据文件。' `
            -Evidence @($motw) -FixId 'FIX_UNBLOCK_FILES' -FixHint "递归解除游戏目录内全部文件的 Internet 标记")
    } else {
        & $add (New-TrdFinding -Id 'FILE_MOTW_OK' -Category '文件安全标记' -Severity 'Pass' `
            -Title '未发现"来自 Internet"文件标记' `
            -Detail '可执行文件不会被 SmartScreen 拦截。' -Evidence @("已检查 $($exePaths.Count) 个 exe"))
    }

    $def = Get-TrdDefenderState
    if ($def.Available -and $def.RealTimeOn) {
        $folderExcluded = @($def.Excluded | Where-Object { $_ -and $Game.Folder.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if (-not $folderExcluded) {
            & $add (New-TrdFinding -Id 'DEFENDER_NO_EXCLUSION' -Category '文件安全标记' -Severity 'Low' `
                -Title '游戏的修改行为可能触发 Defender 实时扫描导致卡顿' `
                -Detail '老游戏运行时会频繁读写自身目录，实时防护的逐文件扫描会造成周期性卡顿（表现为规律性的掉帧）。同时汉化版 exe 有被误报隔离的风险。' `
                -Evidence @("实时防护: 开启", "已排除路径: $(if ($def.Excluded.Count) { $def.Excluded -join '; ' } else { '（无）' })") `
                -FixId 'FIX_DEFENDER_EXCLUDE' -FixHint "把游戏目录加入 Defender 排除项（可选，需管理员权限）")
        }
    }

    # =======================================================================
    #  10. 配置文件
    # =======================================================================
    $cfg = Join-Path $Game.Folder ("{0}.cfg" -f $Game.Id)
    if (Test-Path -LiteralPath $cfg) {
        $sz = (Get-Item -LiteralPath $cfg).Length
        if ($sz -lt 40 -or $sz -gt 4096) {
            & $add (New-TrdFinding -Id 'CFG_ABNORMAL' -Category '游戏配置' -Severity 'High' `
                -Title "$($Game.Id).cfg 大小异常 ($sz 字节)" `
                -Detail '显示模式配置损坏会导致游戏启动时崩溃或黑屏。本工具会备份原文件后删除，让游戏重新生成默认配置（窗口 640×480）。' `
                -Evidence @("文件: $cfg", "大小: $sz 字节（预期 60 字节左右）") `
                -FixId 'FIX_RESET_CFG' -FixHint '备份并重置显示配置为安全默认值')
        } else {
            & $add (New-TrdFinding -Id 'CFG_OK' -Category '游戏配置' -Severity 'Pass' `
                -Title "$($Game.Id).cfg 正常 ($sz 字节)" `
                -Detail '显示模式配置文件结构正常。' -Evidence @("文件: $cfg"))
        }
    } else {
        & $add (New-TrdFinding -Id 'CFG_MISSING' -Category '游戏配置' -Severity 'Low' `
            -Title "未找到 $($Game.Id).cfg（首次运行会自动生成）" `
            -Detail '配置缺失不是错误，游戏会用默认窗口模式启动并生成它。如果启动后没有生成，说明进程在更早的阶段就失败了。' `
            -Evidence @("预期位置: $cfg"))
    }

    # =======================================================================
    #  11. 字体与 .NET
    # =======================================================================
    $fonts = Get-TrdFontState
    if (-not $isChinesePatch) {
        if (-not $fonts.HasGothic) {
            & $add (New-TrdFinding -Id 'FONT_JP_MISSING' -Category '字体' -Severity 'Medium' `
                -Title '缺少日文字体 (MS Gothic / ゴシック)' `
                -Detail '日文原版作品用日文字体渲染界面文字。缺少时表现为方块、乱码或文字完全不显示。' `
                -Evidence @("已注册字体总数: $($fonts.Count)", '未找到 Gothic 系列') `
                -FixId 'FIX_INSTALL_FONT' -NeedsPackage 'FONT_JP_MANUAL' `
                -FixHint '通过 Windows 语言可选功能离线添加日语补充字体，或把字体文件放入 offline/Fonts/')
        } else {
            & $add (New-TrdFinding -Id 'FONT_JP_OK' -Category '字体' -Severity 'Pass' `
                -Title '日文字体可用' -Detail '已找到 MS Gothic 系列字体。' `
                -Evidence @("Gothic: $($fonts.HasGothic)", "Mincho: $($fonts.HasMincho)"))
        }
    }

    $net = Get-TrdDotNetState
    if (-not $net.Has4x) {
        & $add (New-TrdFinding -Id 'DOTNET4_MISSING' -Category '辅助组件' -Severity 'Medium' `
            -Title '缺少 .NET Framework 4.x' `
            -Detail 'Locale Emulator（区域模拟启动器）依赖 .NET Framework 4.x。缺少它时无法用区域模拟方式解决编码问题。Windows 10 1903 及以上版本通常已内置。' `
            -Evidence @("NDP\v4\Full 未找到") -FixId $null `
            -FixHint '通过"启用或关闭 Windows 功能"离线启用 .NET Framework 4.x')
    }

    # =======================================================================
    #  12. 显卡与驱动
    #
    #  "运行库全装对了还是跑不起来"最常见的两个原因就在这里：
    #  显卡驱动根本没装（跑在通用显示适配器上），以及驱动不再提供
    #  640x480 这类老游戏必需的低分辨率模式。
    # =======================================================================
    $gpus = @(Get-TrdGpuState)
    $gpuHealthy = $false

    if ($gpus.Count -eq 0) {
        & $add (New-TrdFinding -Id 'GPU_NONE' -Category '显卡与驱动' -Severity 'Blocker' `
            -Title '系统没有检测到任何显示适配器' `
            -Detail '无法枚举到显卡设备，3D 渲染无从建立，游戏不可能运行。虚拟机或驱动安装异常的机器上会出现这种情况。' `
            -Evidence @('Win32_VideoController 返回空') -FixId $null `
            -FixHint '安装/修复显卡驱动；虚拟机请确认已启用 3D 加速。')
    }

    foreach ($g in $gpus) {
        $gEv = @(
            "驱动版本: $($g.DriverVersion)",
            "驱动日期: $(if ($g.DriverDate) { $g.DriverDate.ToString('yyyy-MM-dd') } else { '未知' })",
            "设备状态: $($g.Status)（ConfigManagerErrorCode=$($g.ErrorCode)）",
            "显存: $(if ($null -ne $g.AdapterRAM_MB) { "$($g.AdapterRAM_MB) MB" } else { '未知' })",
            "当前显示模式: $($g.CurWidth)x$($g.CurHeight) @ $($g.CurRefresh)Hz"
        )

        if ($g.IsBasicAdapter) {
            & $add (New-TrdFinding -Id 'GPU_NO_DRIVER' -Category '显卡与驱动' -Severity 'Blocker' `
                -Title "显卡跑在通用显示适配器上：$($g.Name)" `
                -Detail '当前使用的是 Windows 自带的兜底显示驱动（Microsoft 基本显示适配器 / 标准 VGA）。它只能做最基本的 2D 画面输出，没有任何厂商 3D 加速能力，Direct3D 设备无法建立，游戏一定跑不起来。这不是运行库问题，装再多 DirectX 也没用。' `
                -Evidence $gEv -FixId $null `
                -FixHint '安装对应显卡型号的官方驱动（NVIDIA / AMD / Intel 官网，或笔记本厂商提供的版本）。装完重启再体检。')
        } elseif ($g.ErrorCode -ne 0) {
            & $add (New-TrdFinding -Id 'GPU_DRIVER_ERROR' -Category '显卡与驱动' -Severity 'Blocker' `
                -Title "显卡驱动异常（错误码 $($g.ErrorCode)）：$($g.Name)" `
                -Detail '设备管理器报告该显示适配器处于故障状态（驱动未安装 / 已停止 / 资源冲突）。这种情况下 3D 加速不可用，游戏会黑屏或直接退出。' `
                -Evidence $gEv -FixId $null `
                -FixHint '在设备管理器中查看该设备的错误详情，重装或回滚显卡驱动后重启再体检。')
        } elseif ($g.Status -and $g.Status -ne 'OK') {
            & $add (New-TrdFinding -Id 'GPU_STATUS_BAD' -Category '显卡与驱动' -Severity 'High' `
                -Title "显卡设备状态异常（$($g.Status)）：$($g.Name)" `
                -Detail '设备没有报告 OK 状态，3D 功能可能部分或完全不可用。' `
                -Evidence $gEv -FixId $null -FixHint '重装显卡驱动后重启再体检。')
        } else {
            $gpuHealthy = $true
            & $add (New-TrdFinding -Id 'GPU_OK' -Category '显卡与驱动' -Severity 'Pass' `
                -Title "显卡驱动正常：$($g.Name)" `
                -Detail '设备状态正常，具备 3D 加速能力。DirectX 8 时代作品在新驱动上偶发花屏/崩溃，若修复后画面仍异常，可部署 dgVoodoo2 兼容层。' `
                -Evidence $gEv -FixId 'FIX_DEPLOY_DGVOODOO' -NeedsPackage 'TOOL_DGVOODOO2' `
                -FixHint '（仅在其他修复都完成后仍有画面问题时使用）部署 dgVoodoo2 到游戏目录')
        }

        if ($g.DriverAgeYears -and $g.DriverAgeYears -ge 4) {
            & $add (New-TrdFinding -Id 'GPU_DRIVER_OLD' -Category '显卡与驱动' -Severity 'Low' `
                -Title ("显卡驱动较旧（约 {0} 年前）" -f $g.DriverAgeYears) `
                -Detail '老驱动对 DirectX 8/9 的兼容性通常是加分项，但也可能存在已知的稳定性问题。如果游戏出现花屏或随机崩溃，升级到较新的稳定版驱动值得一试。' `
                -Evidence $gEv -FixId $null -FixHint '可选：升级显卡驱动。若游戏当前运行正常则不必折腾。')
        }
    }

    # --- 低分辨率显示模式：老游戏全屏初始化依赖它 ---
    if ($gpuHealthy) {
        $modes = Get-TrdDisplayModes
        if (-not $modes.Detected) {
            & $add (New-TrdFinding -Id 'DISPLAY_MODES_UNKNOWN' -Category '显卡与驱动' -Severity 'Pass' `
                -Title '未能枚举显示模式（不影响使用）' `
                -Detail '当前环境不允许临时编译探测代码（可能处于受限语言模式），因此跳过了低分辨率模式检查。启动验证仍然会真实拉起游戏来确认。' `
                -Evidence @("原因: $($modes.Reason)") -FixId $null)
        } elseif ($modes.ModeCount -eq 0) {
            & $add (New-TrdFinding -Id 'DISPLAY_MODES_EMPTY' -Category '显卡与驱动' -Severity 'Medium' `
                -Title '显卡驱动没有报告任何显示模式' `
                -Detail 'EnumDisplaySettings 枚举不到任何模式，这通常意味着驱动状态异常。' `
                -Evidence @('枚举结果为空') -FixId $null -FixHint '重装显卡驱动。')
        } elseif ($modes.Has640x480 -eq $false) {
            & $add (New-TrdFinding -Id 'DISPLAY_NO_640x480' -Category '显卡与驱动' -Severity 'Medium' `
                -Title '显卡驱动未提供 640×480 显示模式（该游戏的全屏默认分辨率）' `
                -Detail ("$($Game.DisplayName) 默认以 640×480 全屏启动。当前驱动列出的最小模式是 " +
                         "$($modes.MinWidth)×$($modes.MinHeight)，不含 640×480 与 800×600。" +
                         "部分较新的驱动已经不再列出这些老模式，全屏初始化可能失败。" +
                         "多数情况下改用窗口模式或让显卡做缩放即可正常。") `
                -Evidence (@("枚举到 $($modes.ModeCount) 个显示模式",
                             "最小模式: $($modes.MinWidth)x$($modes.MinHeight)",
                             "是否含 640x480: $($modes.Has640x480)",
                             "是否含 800x600: $($modes.Has800x600)") +
                           @("模式样例: " + (($modes.SampleModes) -join ', '))) `
                -FixId 'FIX_RESET_CFG' `
                -FixHint '把游戏重置为窗口模式启动（重置显示配置后游戏会用默认窗口模式），或在 custom.exe 里指定一个驱动支持的分辨率')
        } elseif ($modes.Has640x480 -eq $true) {
            & $add (New-TrdFinding -Id 'DISPLAY_640x480_OK' -Category '显卡与驱动' -Severity 'Pass' `
                -Title '显卡驱动提供 640×480 模式' `
                -Detail '该游戏的全屏默认分辨率可用，不存在因低分辨率缺失导致的全屏失败。' `
                -Evidence @("枚举到 $($modes.ModeCount) 个显示模式", "最小模式: $($modes.MinWidth)x$($modes.MinHeight)"))
        }
    }

    # =======================================================================
    #  13. 音频
    # =======================================================================
    $audio = Get-TrdAudioState
    $audioEv = @(
        "音频设备数: $($audio.DeviceCount)",
        "Windows Audio 服务: $(if ($audio.ServiceStatus) { "$($audio.ServiceStatus)（启动类型 $($audio.ServiceStart)）" } else { '查询失败' })"
    )
    if ($audio.DeviceCount -gt 0) {
        $audioEv += @($audio.Devices | Select-Object -First 5 | ForEach-Object { "设备: $($_.Name) [$($_.Status)]" })
    }

    if (-not $audio.ServiceRunning) {
        & $add (New-TrdFinding -Id 'AUDIO_SERVICE_STOPPED' -Category '音频' -Severity 'High' `
            -Title "Windows Audio 服务未运行（当前: $(if ($audio.ServiceStatus) { $audio.ServiceStatus } else { '未知' })）" `
            -Detail '东方系列通过 DirectSound 初始化音频。音频服务没有运行时，DirectSound 初始化会失败，游戏常在启动阶段就卡住或直接退出（表现是"点了没反应"）。被"系统优化"工具关掉是这个问题的常见来源。' `
            -Evidence $audioEv -FixId 'FIX_START_AUDIO_SERVICE' `
            -FixHint '把 Windows Audio 服务（Audiosrv）设为自动并启动')
    } elseif ($audio.DeviceCount -eq 0) {
        & $add (New-TrdFinding -Id 'AUDIO_NO_DEVICE' -Category '音频' -Severity 'High' `
            -Title '系统没有可用的音频输出设备' `
            -Detail '没有任何音频设备时 DirectSound 无法初始化。虚拟机上常见，也可能是声卡驱动缺失或被禁用。建议先在系统里插上耳机/音箱并确认设备管理器有声卡。' `
            -Evidence $audioEv -FixId $null `
            -FixHint '安装/启用声卡驱动，或接入一个音频输出设备。若确实无音频硬件，可尝试用 dgVoodoo2 附带的 WinMM 包装器绕过音频初始化。')
    } elseif ($audio.BadDevices.Count -gt 0) {
        & $add (New-TrdFinding -Id 'AUDIO_DEVICE_BAD' -Category '音频' -Severity 'Medium' `
            -Title "有 $($audio.BadDevices.Count) 个音频设备状态异常" `
            -Detail '设备管理器报告这些音频设备存在问题，可能导致 DirectSound 初始化到一半失败。' `
            -Evidence ($audioEv + @($audio.BadDevices | ForEach-Object { "异常设备: $($_.Name) [$($_.Status)] 错误码=$($_.ErrorCode)" })) `
            -FixId $null -FixHint '重装声卡驱动，或在设备管理器里禁用出问题的设备后重试。')
    } else {
        & $add (New-TrdFinding -Id 'AUDIO_OK' -Category '音频' -Severity 'Pass' `
            -Title "音频环境正常（$($audio.DeviceCount) 个设备，服务运行中）" `
            -Detail 'DirectSound 初始化所需的音频服务与设备均已就绪。' -Evidence $audioEv)
    }

    # =======================================================================
    #  14. 安装能力（还能不能补运行库）
    # =======================================================================
    $inst = Get-TrdInstallPolicyState
    $instEv = @(
        "Windows Installer 服务: $(if ($inst.MsiStatus) { "$($inst.MsiStatus)（启动类型 $($inst.MsiStartType)）" } else { '查询失败' })",
        "TrustedInstaller: $(if ($inst.TrustedInstallerStartType) { $inst.TrustedInstallerStartType } else { '未知' })"
    )
    if ($null -ne $inst.PolicyDisable) { $instEv += "组策略 DisableMSI = $($inst.PolicyDisable)" }

    if ($inst.MsiDisabled) {
        & $add (New-TrdFinding -Id 'SVC_MSI_DISABLED' -Category '系统服务与策略' -Severity 'High' `
            -Title 'Windows Installer 服务被禁用' `
            -Detail 'VC++ / DirectX 运行库都通过 MSI 安装包部署。安装服务被禁用时，安装程序会失败，表现出来就是"修复跑了但没生效"。注意：该服务处于"已停止"是正常的（手动触发），被"禁用"才是问题。' `
            -Evidence $instEv -FixId 'FIX_ENABLE_MSI_SERVICE' `
            -FixHint '把 Windows Installer 服务（msiserver）的启动类型改回"手动"或"自动"并启动')
    } elseif ($inst.PolicyBlocked) {
        & $add (New-TrdFinding -Id 'POLICY_MSI_BLOCKED' -Category '系统服务与策略' -Severity 'High' `
            -Title '组策略禁止了 Windows Installer 安装（DisableMSI = 2）' `
            -Detail '这是被组策略明确禁止安装 MSI 包的状态。运行库无法通过正常途径安装，需要先解除策略。' `
            -Evidence $instEv -FixId $null `
            -FixHint '在 gpedit.msc → 计算机配置 → 管理模板 → Windows 组件 → Windows Installer 中把"禁止 Windows Installer"设为"未配置"，或删除注册表 DisableMSI 值后重启。')
    } else {
        & $add (New-TrdFinding -Id 'INSTALL_OK' -Category '系统服务与策略' -Severity 'Pass' `
            -Title '具备安装运行库的能力' `
            -Detail 'Windows Installer 服务可用，未发现禁止安装的策略。' -Evidence $instEv)
    }

    # =======================================================================
    #  15. 可能与老游戏冲突的软件
    # =======================================================================
    $sec = Get-TrdSecurityProducts
    if ($sec.HasThirdParty) {
        # 这里刻意不给 FixId：
        # 第三方杀软的信任区设置方式千差万别（有的在托盘菜单、有的要输密码、
        # 有的根本不提供命令行接口），无法可靠自动化。若错误地指向
        # FIX_DEFENDER_EXCLUDE，用户会以为"点一下就好了"，
        # 而那个动作只改 Windows Defender，对 360/火绒等毫无作用。
        # 因此归入"需要手动完成"，由 FixHint 给出准确指引。
        & $add (New-TrdFinding -Id 'AV_THIRD_PARTY' -Category '冲突软件' -Severity 'Medium' `
            -Title "检测到第三方安全软件：$(($sec.ThirdPartyNames) -join '、')" `
            -Detail '汉化版 exe 被第三方杀软误报隔离是东方圈子里最常见的"游戏突然消失/打不开"原因。这类软件往往不会明确告诉你就把文件处理掉了。如果本工具查出数据文件缺失或体量异常，很可能是它干的。' `
            -Evidence @($sec.Products | ForEach-Object { "$($_.Name)（productState=$($_.ProductState)）" }) `
            -FixId $null `
            -FixHint '在该杀软的信任区/白名单里加入游戏目录，然后从原始压缩包重新解压一份完整的游戏文件（否则下次扫描还会被删）。')
    } else {
        & $add (New-TrdFinding -Id 'AV_OK' -Category '冲突软件' -Severity 'Pass' `
            -Title '未检测到第三方安全软件' `
            -Detail $(if ($sec.Products.Count -gt 0) { "仅检测到系统自带防护：" + (($sec.Products | ForEach-Object { $_.Name }) -join '、') } else { '未检测到已注册的安全软件。' }) `
            -Evidence @($sec.Products | ForEach-Object { "$($_.Name)（productState=$($_.ProductState)）" }))
    }

    $conflicts = @(Get-TrdConflictingProcesses)
    if ($conflicts.Count -gt 0) {
        $cats = @($conflicts | Group-Object Category | ForEach-Object { "$($_.Name): $(($_.Group | ForEach-Object { $_.Process }) -join ', ')" })
        $hasInject = @($conflicts | Where-Object { $_.Category -in '变速/修改工具', '画面覆盖层/录像/监控', '虚拟手柄驱动' }).Count -gt 0
        & $add (New-TrdFinding -Id 'CONFLICT_PROCESS' -Category '冲突软件' -Severity $(if ($hasInject) { 'High' } else { 'Low' }) `
            -Title "有 $($conflicts.Count) 个可能与老游戏冲突的常驻进程在运行" `
            -Detail $(if ($hasInject) {
                '变速/加速工具会向目标进程注入代码修改时钟，老引擎经常直接崩溃；画面覆盖层会挂 Direct3D/DirectDraw 钩子抢占渲染管线。这两类都是"游戏莫名闪退"的高频原因。请在启动游戏前退出它们。'
            } else {
                '检测到输入法进程。中文输入法在独占全屏下可能导致输入丢失或焦点异常，东方系列尤其明显。社区通行做法是启动游戏前按 Shift 或 Win+空格 切到英文输入状态。'
            }) `
            -Evidence $cats -FixId $null `
            -FixHint '启动游戏前退出上述程序；输入法问题切换到英文输入状态即可，无需卸载。')
    }

    # =======================================================================
    #  16. 游戏文件完整性
    # =======================================================================
    $data = Get-TrdGameDataState -GameFolder $Game.Folder
    if ($data.Missing.Count -gt 0) {
        & $add (New-TrdFinding -Id 'DATA_MISSING' -Category '游戏文件' -Severity 'Blocker' `
            -Title "缺少游戏本体数据文件：$($data.Missing -join '、')" `
            -Detail '游戏的可执行文件还在，但资源包不见了。这几乎总是被安全软件隔离/清除，或解压中断导致的。程序能启动但会在读取资源时立刻失败。' `
            -Evidence @("目录: $($Game.Folder)", "已找到的数据文件: $(if ($data.MainDat.Count + $data.BgmDat.Count -gt 0) { ($data.MainDat + $data.BgmDat) -join ', ' } else { '（无）' })") `
            -FixId $null -FixHint '检查杀软的隔离区并恢复文件；或从原始压缩包重新解压一份完整游戏（并先把游戏目录加入信任区，否则会再次被删）。')
    } elseif ($data.Suspect.Count -gt 0) {
        & $add (New-TrdFinding -Id 'DATA_SUSPECT' -Category '游戏文件' -Severity 'High' `
            -Title '游戏数据文件体量异常，疑似被截断或清空' `
            -Detail '文件还在但内容明显不完整。有些安全软件会把判定为威胁的文件"清除内容"而不是删除，文件大小骤降但文件名保留 —— 光看"文件是否存在"是查不出来的。这也可能是解压/复制过程被中断。' `
            -Evidence $data.Suspect -FixId $null `
            -FixHint '从原始压缩包重新解压游戏，并先把游戏目录加入杀软信任区。')
    } else {
        & $add (New-TrdFinding -Id 'DATA_OK' -Category '游戏文件' -Severity 'Pass' `
            -Title "游戏数据文件完整（共约 $($data.TotalDataMB) MB）" `
            -Detail '主数据包与音乐包均存在且体量正常。' `
            -Evidence @("主数据: $($data.MainDat -join ', ')（$($data.MainDatMB) MB）", "音乐数据: $(if ($data.BgmDat.Count -gt 0) { $data.BgmDat -join ', ' } else { '（无此文件）' })"))
    }

    $vs = Get-TrdVirtualStoreState -GameFolder $Game.Folder
    if ($vs.UnderProgramFiles) {
        & $add (New-TrdFinding -Id 'PATH_VIRTUALSTORE' -Category '游戏文件' -Severity $(if ($vs.VirtualStoreHit) { 'High' } else { 'Medium' }) `
            -Title '游戏位于 Program Files 目录下，写入会被 UAC 虚拟化重定向' `
            -Detail ("老游戏把存档和配置写在自身目录。在 Program Files 下且未以管理员运行时，" +
                     "Windows 会把写入悄悄重定向到 %LOCALAPPDATA%\VirtualStore，" +
                     "导致设置改了不生效、存档出现在意想不到的位置。" +
                     $(if ($vs.VirtualStoreHit) { '本机已经出现虚拟化写入，说明这个重定向正在实际发生。' } else { '' })) `
            -Evidence @("游戏目录: $($Game.Folder)", "虚拟化目标: $($vs.VirtualStorePath)", "该目录已存在: $($vs.VirtualStoreHit)") `
            -FixId 'FIX_MIGRATE_ASCII_PATH' `
            -FixHint '把游戏移到 Program Files 之外的目录（例如 D:\TouhouGames\th08），这是最干净的解法')
    }

    # =======================================================================
    #  17. 内存
    # =======================================================================
    $mem = Get-TrdMemoryState
    if ($mem.TotalMB -gt 0 -and $mem.FreeMB -lt 512) {
        & $add (New-TrdFinding -Id 'MEM_LOW' -Category '运行环境' -Severity 'Medium' `
            -Title "可用物理内存偏低（剩余 $($mem.FreeMB) MB / 共 $($mem.TotalMB) MB）" `
            -Detail '32 位程序需要一段连续的虚拟地址空间，物理内存过于紧张时，进程启动阶段的内存分配可能失败。老游戏本身占用很小，但系统整体吃紧时会受影响。' `
            -Evidence @("总内存: $($mem.TotalMB) MB", "可用: $($mem.FreeMB) MB") `
            -FixId $null -FixHint '关闭一些后台程序（浏览器、聊天软件）后重试。')
    }

    # =======================================================================
    #  18. 输入子系统（"键盘暴走"专项）
    #
    #  症状：游戏打开后持续不断的错误键值输入。
    #  这类问题不在依赖层面，必须按输入栈逐层查：IME / 辅助功能 / 重复率 /
    #  过滤驱动 / 重映射 / 设备枚举 / DirectInput 配置 / 注入软件 / 显示时序。
    # =======================================================================
    $inp = $null
    try { $inp = Get-TrdInputDiagnostics -GameFolder $Game.Folder } catch { }

    if ($inp) {
        # --- IME：最高发 ---
        if ($inp.Ime -and $inp.Ime.CannotSwitchToEnglish) {
            $layoutNames = @($inp.Ime.Layouts | ForEach-Object { "$($_.Name)($($_.Code))" })
            & $add (New-TrdFinding -Id 'INPUT_IME_NO_ENGLISH' -Category '输入子系统' -Severity 'High' `
                -Title '只装了中文输入法，没有英文键盘布局（键盘暴走的高危配置）' `
                -Detail ('该作品通过 DirectInput 读键盘。中文输入法处于活动状态时会参与按键处理并持续产生输入，' +
                         '在独占全屏下尤其明显 —— 这就是社区常说的"启动前先切英文输入法"。' +
                         '但本机【没有安装任何英文键盘布局】，按 Win+空格 或 Ctrl+Shift 根本切不出去，' +
                         '所以"切英文"这个通行解法在这里不成立，表现为怎么弄都暴走。' +
                         '需要先把英文键盘布局加进系统。') `
                -Evidence (@("已装布局: $($layoutNames -join '、')") +
                           @("IME 相关进程: $(if ($inp.Ime.ImeProcesses.Count) { $inp.Ime.ImeProcesses -join ', ' } else { '（无）' })") +
                           @('判断依据：存在 CJK 布局且不存在任何英文(00000?09)布局')) `
                -FixId 'FIX_ADD_ENGLISH_LAYOUT' `
                -FixHint '添加英文(美国)键盘布局，之后即可在启动游戏前用 Win+空格 切到英文输入状态')
        } elseif ($inp.Ime) {
            & $add (New-TrdFinding -Id 'INPUT_IME_OK' -Category '输入子系统' -Severity 'Pass' `
                -Title "键盘布局正常（$($inp.Ime.LayoutCount) 个，含英文）" `
                -Detail '可以在启动游戏前切换到英文输入状态，规避输入法与 DirectInput 的冲突。' `
                -Evidence @($inp.Ime.Layouts | ForEach-Object { "$($_.Name)($($_.Code))" }))
        }

        # --- 辅助功能 ---
        if ($inp.Accessibility -and $inp.Accessibility.AnyEnabled) {
            & $add (New-TrdFinding -Id 'INPUT_ACCESSIBILITY_ON' -Category '输入子系统' -Severity 'High' `
                -Title "辅助功能键已启用：$($inp.Accessibility.EnabledList -join '、')" `
                -Detail '这些功能会拦截并改写按键，是异常输入的常见来源。筛选键会把一次按键变成连续输入；粘滞键会让修饰键"粘住"；鼠标键会吞掉小键盘输入。' `
                -Evidence @($inp.Accessibility.Items | Where-Object { $_.Enabled } | ForEach-Object { "$($_.Name)：$($_.Effect)（Flags=$($_.Flags)，最低位=1）" }) `
                -FixId 'FIX_DISABLE_ACCESSIBILITY' `
                -FixHint '关闭这些辅助功能（把对应 Flags 的最低位清零）')
        } elseif ($inp.Accessibility) {
            & $add (New-TrdFinding -Id 'INPUT_ACCESSIBILITY_OK' -Category '输入子系统' -Severity 'Pass' `
                -Title '辅助功能键均未启用' `
                -Detail '粘滞键、筛选键、切换键、鼠标键都是关闭状态。' `
                -Evidence @($inp.Accessibility.Items | ForEach-Object { "$($_.Name): Flags=$($_.Flags) 最低位=$(if ($_.Enabled) { 1 } else { 0 })" }))
        }

        # --- 内核级键盘重映射 ---
        if ($inp.ScancodeMap -and $inp.ScancodeMap.Present) {
            & $add (New-TrdFinding -Id 'INPUT_SCANCODE_MAP' -Category '输入子系统' -Severity 'High' `
                -Title '存在内核级键盘重映射（Scancode Map）' `
                -Detail '这个注册表项能把任意物理按键映射成别的键，甚至禁用按键。被宏软件或手工写坏时，会出现"按 A 出 B"或"某个键一直处于按下状态"。' `
                -Evidence (@("字节数: $($inp.ScancodeMap.Bytes)", "原始数据: $($inp.ScancodeMap.Hex)") + @($inp.ScancodeMap.Entries)) `
                -FixId 'FIX_REMOVE_SCANCODE_MAP' `
                -FixHint '删除 Scancode Map 并重启，恢复键盘的物理按键定义')
        } else {
            & $add (New-TrdFinding -Id 'INPUT_SCANCODE_OK' -Category '输入子系统' -Severity 'Pass' `
                -Title '无键盘重映射（Scancode Map 不存在）' `
                -Detail '按键保持出厂定义，不存在被改写的情况。' -Evidence @('HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layout 下无 Scancode Map'))
        }

        # --- 键盘类过滤驱动 ---
        $badFilt = @($inp.FilterDrivers | Where-Object { -not $_.IsClean })
        if ($badFilt.Count -gt 0) {
            & $add (New-TrdFinding -Id 'INPUT_FILTER_DRIVER' -Category '输入子系统' -Severity 'High' `
                -Title '键盘/鼠标栈里挂了第三方过滤驱动' `
                -Detail '过滤驱动能看到并改写每一个按键，是幻影输入与按键错乱的高危来源。正常系统的键盘类只应有 kbdclass、鼠标类只应有 mouclass。' `
                -Evidence @($badFilt | ForEach-Object { $c = $_.Class; $_.ThirdParty | ForEach-Object { "$c 类 非微软驱动: $($_.Driver)（$($_.Reason)）文件: $($_.Path)" } }) `
                -FixId $null -FixHint '在设备管理器里卸载对应外设软件，或用其官方卸载程序移除后重启。')
        } else {
            & $add (New-TrdFinding -Id 'INPUT_FILTER_OK' -Category '输入子系统' -Severity 'Pass' `
                -Title '输入栈过滤驱动干净' `
                -Detail '键盘与鼠标类只有系统自带驱动。' `
                -Evidence @($inp.FilterDrivers | ForEach-Object { "$($_.Class)类: Upper=$($_.UpperFilters -join ',') Lower=$(if ($_.LowerFilters.Count) { $_.LowerFilters -join ',' } else { '（无）' })" }))
        }

        # --- 多个键盘设备 / 虚拟转换设备 ---
        if ($inp.Devices) {
            $virtualKb = @($inp.Devices.Keyboards | Where-Object { $_.DeviceID -match 'CONVERTEDDEVICE|BUTTONCONVERTER|ROOT\\' })
            $vkEv = @($inp.Devices.Keyboards | ForEach-Object { "$($_.Name)  [$($_.DeviceID)]  状态=$($_.Status)" })
            if ($virtualKb.Count -gt 0) {
                & $add (New-TrdFinding -Id 'INPUT_VIRTUAL_KEYBOARD' -Category '输入子系统' -Severity 'Medium' `
                    -Title "存在 $($virtualKb.Count) 个虚拟/转换键盘设备" `
                    -Detail ('这些不是物理键盘，而是由驱动程序（例如 Button Converter）生成的虚拟 HID 键盘。' +
                             '转换逻辑异常时，它们会不断向系统上报按键，表现为"没人碰键盘却一直在输入"。' +
                             '如果暴走只在插着某个外设时出现，优先怀疑这里。') `
                    -Evidence $vkEv -FixId $null `
                    -FixHint '在设备管理器里禁用/卸载对应的转换设备或其上游外设，然后重启观察。')
            } elseif ($inp.Devices.KeyboardCount -gt 1) {
                & $add (New-TrdFinding -Id 'INPUT_MULTI_KEYBOARD' -Category '输入子系统' -Severity 'Low' `
                    -Title "系统里有 $($inp.Devices.KeyboardCount) 个键盘类设备" `
                    -Detail '多个键盘本身正常（例如笔记本内置键盘 + 外接键盘），但其中任何一个存在按键卡住或无线连接不稳定时，都会造成持续输入。排查时可逐个断开观察。' `
                    -Evidence $vkEv -FixId $null -FixHint '逐个断开外接键盘/蓝牙键盘，观察暴走是否消失。')
            } else {
                & $add (New-TrdFinding -Id 'INPUT_KB_DEVICE_OK' -Category '输入子系统' -Severity 'Pass' `
                    -Title "键盘设备正常（$($inp.Devices.KeyboardCount) 个）" `
                    -Detail '未发现虚拟/转换键盘设备。' -Evidence $vkEv)
            }

            # --- 手柄（漂移的轴 = 持续输入）---
            if ($inp.Devices.GamepadCount -gt 0) {
                & $add (New-TrdFinding -Id 'INPUT_GAMEPAD_PRESENT' -Category '输入子系统' -Severity 'Medium' `
                    -Title "检测到 $($inp.Devices.GamepadCount) 个游戏手柄/控制器" `
                    -Detail ('很多"键盘暴走"其实是手柄在作怪：东方同时读键盘和手柄，摇杆漂移或按键卡住时，' +
                             '菜单会持续滚动、看起来就像键盘失灵。如果只在插着手柄时出现，基本可以确定。' +
                             '排查方法：拔掉手柄（或断开蓝牙）再进游戏看是否复现。') `
                    -Evidence @($inp.Devices.Gamepads | ForEach-Object { "$($_.Name)  [$($_.DeviceID)]  状态=$($_.Status)" }) `
                    -FixId $null -FixHint '拔掉手柄或断开蓝牙后进游戏验证；确认是手柄问题则校准摇杆或更换。')
            }

            # --- 蓝牙 HID ---
            if ($inp.Devices.BtCount -gt 0) {
                & $add (New-TrdFinding -Id 'INPUT_BT_HID' -Category '输入子系统' -Severity 'Low' `
                    -Title "存在 $($inp.Devices.BtCount) 个蓝牙 HID 设备" `
                    -Detail '蓝牙输入设备处于"已连接但无响应"的状态时会持续发送输入。如果暴走是间歇性的、且与蓝牙设备电量或距离有关，优先怀疑这里。' `
                    -Evidence @($inp.Devices.BluetoothHid | Select-Object -First 8 | ForEach-Object { "$($_.Name)  [$($_.DeviceID)]" }) `
                    -FixId $null -FixHint '在"蓝牙和其他设备"里移除不再使用的蓝牙输入设备。')
            }

            if ($inp.Devices.ProblemInput.Count -gt 0) {
                & $add (New-TrdFinding -Id 'INPUT_DEVICE_ERROR' -Category '输入子系统' -Severity 'High' `
                    -Title "有 $($inp.Devices.ProblemInput.Count) 个输入设备报告故障" `
                    -Detail '设备状态异常的输入设备可能持续上报错误数据。' `
                    -Evidence @($inp.Devices.ProblemInput | ForEach-Object { "$($_.Name) [$($_.Class)] 错误码 $($_.ErrorCode)" }) `
                    -FixId $null -FixHint '在设备管理器里重装或禁用该设备后重启。')
            }
        }

        # --- 键盘重复率 ---
        if ($inp.KeyboardRepeat -and $inp.KeyboardRepeat.IsFastest) {
            & $add (New-TrdFinding -Id 'INPUT_REPEAT_FAST' -Category '输入子系统' -Severity 'Low' `
                -Title "键盘重复率已设为最快（速度 $($inp.KeyboardRepeat.Speed)、延迟 $($inp.KeyboardRepeat.Delay)）" `
                -Detail '这本身不是故障，但会把"某个键卡住"放大成输入洪水：一次误触会瞬间产生几十次按键。排查暴走问题时先把它调回中间值，便于观察。' `
                -Evidence @("KeyboardSpeed = $($inp.KeyboardRepeat.Speed)（最大 31）", "KeyboardDelay = $($inp.KeyboardRepeat.Delay)（最小 0）") `
                -FixId $null -FixHint '控制面板 → 键盘 → 把"重复速度"调慢一档再测试。')
        }

        # --- DirectInput 动作映射器 ---
        if ($inp.DirectInput -and $inp.DirectInput.MapperEnabled.Count -gt 0) {
            & $add (New-TrdFinding -Id 'INPUT_DINPUT_MAPPER' -Category '输入子系统' -Severity 'Medium' `
                -Title "有 $($inp.DirectInput.MapperEnabled.Count) 个程序启用了 DirectInput 动作映射器" `
                -Detail '启用映射器时，DINPUT 会按用户配置改写按键含义。那份映射被改坏时，表现就是"按键完全不对"。' `
                -Evidence @($inp.DirectInput.MapperEnabled) `
                -FixId 'FIX_RESET_DINPUT' -FixHint '清除 DirectInput 的按程序配置，强制重新枚举设备')
        } else {
            & $add (New-TrdFinding -Id 'INPUT_DINPUT_OK' -Category '输入子系统' -Severity 'Pass' `
                -Title 'DirectInput 配置正常' `
                -Detail "已记录 $($inp.DirectInput.AppCount) 个程序的 DInput 配置，均未启用动作映射器。" `
                -Evidence @("最近使用 DInput 的程序: $(if ($inp.DirectInput.MostRecent) { $inp.DirectInput.MostRecent.Name } else { '（无记录）' })"))
        }

        # --- 干扰软件 ---
        if ($inp.Interference.Count -gt 0) {
            $hasInject = @($inp.Interference | Where-Object { $_.Category -in '宏 / 按键工具', '虚拟手柄', '远程控制', '外设驱动套件' }).Count -gt 0
            & $add (New-TrdFinding -Id 'INPUT_INTERFERENCE' -Category '输入子系统' -Severity $(if ($hasInject) { 'High' } else { 'Low' }) `
                -Title "有 $($inp.Interference.Count) 个可能改写输入的常驻程序在运行" `
                -Detail $(if ($hasInject) {
                    '宏工具会直接注入按键；虚拟手柄的漂移轴等同于持续按键；远程控制软件在连接残留时会产生幻影输入；外设驱动套件会挂全局钩子改写按键。这几类都是"键盘暴走"的直接来源，排查时先全部退出。'
                } else {
                    '画面/音频注入类软件会挂 D3D 钩子改变线程时序，间接影响输入采样节奏。'
                }) `
                -Evidence @($inp.Interference | Group-Object Category | ForEach-Object { "$($_.Name): $(($_.Group | ForEach-Object { $_.Process }) -join ', ')" }) `
                -FixId $null -FixHint '启动游戏前退出上述程序，尤其是宏工具与虚拟手柄。')
        }

        # --- 显示时序（帧率失控会导致输入被重复采样）---
        if ($inp.Timing -and $inp.Timing.HighRefresh) {
            $fpsNote = if ($inp.Timing.VpatchGameFPS) { "vpatch 已设置 GameFPS = $($inp.Timing.VpatchGameFPS)（正常）" } else { '未检测到 vpatch 的帧率设置' }
            if ($inp.Timing.FpsMismatch) {
                & $add (New-TrdFinding -Id 'INPUT_FPS_MISMATCH' -Category '输入子系统' -Severity 'Medium' `
                    -Title "显示器为 $($inp.Timing.RefreshHz)Hz，且未检测到帧率限制设置" `
                    -Detail '老引擎按帧采样输入。若帧率失控（高刷显示器上没有正确限帧），一次按键会被多帧重复采样，表现为菜单滚动飞快、像按键连发。vpatch 正是为修这个而存在。' `
                    -Evidence @("刷新率: $($inp.Timing.RefreshHz)Hz", "分辨率: $($inp.Timing.Width)x$($inp.Timing.Height)", 'vpatch.ini: 未找到或无 GameFPS') `
                    -FixId 'FIX_CREATE_LAUNCHER' -FixHint '确保通过 vpatch.exe 启动（本工具会生成对应启动器）')
            } else {
                & $add (New-TrdFinding -Id 'INPUT_FPS_OK' -Category '输入子系统' -Severity 'Pass' `
                    -Title "高刷显示器（$($inp.Timing.RefreshHz)Hz）的帧率限制已正确配置" `
                    -Detail '已检测到帧率限制设置，输入不会被重复采样。' `
                    -Evidence @("刷新率: $($inp.Timing.RefreshHz)Hz", $fpsNote, "Vsync=$($inp.Timing.VpatchVsync) SleepType=$($inp.Timing.VpatchSleep)"))
            }
        }
    }

    # =======================================================================
    #  汇总
    # =======================================================================
    $blockers = @($findings | Where-Object { $_.Severity -eq 'Blocker' })
    $highs    = @($findings | Where-Object { $_.Severity -eq 'High' })
    $mediums  = @($findings | Where-Object { $_.Severity -eq 'Medium' })
    $lows     = @($findings | Where-Object { $_.Severity -eq 'Low' })
    $passes   = @($findings | Where-Object { $_.Severity -eq 'Pass' })

    $summary = [PSCustomObject]@{
        Blocker = $blockers.Count
        High    = $highs.Count
        Medium  = $mediums.Count
        Low     = $lows.Count
        Pass    = $passes.Count
        Total   = $findings.Count
        Verdict = $(if ($blockers.Count -gt 0) { 'REPAIR_NEEDED' }
                    elseif ($highs.Count -gt 0) { 'REPAIR_RECOMMENDED' }
                    elseif ($mediums.Count -gt 0) { 'MINOR_ISSUES' }
                    else { 'HEALTHY' })
    }

    $sorted = @($findings | Sort-Object @{ Expression = { Get-TrdSeverityRank -Severity $_.Severity } }, Category, Title)

    return [PSCustomObject]@{
        Game     = $Game
        Findings = $sorted
        Deps     = $deps
        Vc       = $vc
        VcNeeded = $vcNeeded
        Dx       = $dx
        Os       = $os
        Locale   = $loc
        Scaling  = $scaling
        Summary  = $summary
    }
}
